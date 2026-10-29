-- The watchdog's own three tables: creates them, flushes the ledger, saves and loads what it learned,
-- and trims old ledger lines. Every call is protected: a failure is counted and retried later, and never
-- reaches the game. Must run inside a thread: oxmysql's await pauses the thread until the reply.
local sql = require('server.sql')
local log = require('server.log')
local M = {}

local FLUSH_BATCH = 500  -- ledger lines per insert

-- ponytail: a query with no answer in QUERY_TIMEOUT_S counts as failed. oxmysql 2.14.1 never answers a query
-- sent while the database is down, not even once it is back (found in the box 1 lab), and one such query
-- would hold the flush or the count forever. Its thread is left waiting for good (oxmysql keeps the
-- callback), so after one goes unanswered nothing more is sent until RETRY_AFTER_S has passed, and then a
-- single query goes to see whether the database answers again: a flush sends one line as that probe. That
-- leaves about one thread an hour per two minutes of outage. If a given-up query does land later (a long
-- table lock, say), its batch is written again on each retry until then: history rows only, nothing reads
-- wd_ledger back, and an upsert landing out of order is put right by the next save. Upgrade path: a batch id
-- column with INSERT IGNORE.
local QUERY_TIMEOUT_S = 60  -- long enough for a big server's full-table reads (20,003 rows read in well under it)
local RETRY_AFTER_S = 60

-- When a query was last given up on, while no answer has come since (nil while the database answers), and
-- whether the one query allowed through to try again is still out.
local unanswered_at, probing = nil, false

local function waiting()
  return unanswered_at ~= nil and (probing or os.time() - unanswered_at < RETRY_AFTER_S)
end

-- oxmysql's await, given up on after QUERY_TIMEOUT_S. The Mac's tests call some steps outside a thread,
-- where nothing can wait; there the stand-in answers at once (on a server every call runs in a thread).
local function await(text, params)
  if not coroutine.isyieldable() then return MySQL.query.await(text, params) end
  if waiting() then
    error(('no answer from the database for %d s; trying again shortly'):format(os.time() - unanswered_at), 0)
  end
  if unanswered_at then probing = true end
  local p, done = promise.new(), false
  local function finish(ok, res)
    if done then return end
    done = true
    p:resolve({ ok, res })
  end
  CreateThread(function()
    local ok, res = pcall(function() return MySQL.query.await(text, params) end)
    unanswered_at, probing = nil, false  -- any answer, even one that comes after it was given up on
    finish(ok, res)
  end)
  SetTimeout(QUERY_TIMEOUT_S * 1000, function()
    if done then return end
    unanswered_at, probing = os.time(), false
    finish(false, ('no answer from the database in %d s'):format(QUERY_TIMEOUT_S))
  end)
  local r = Citizen.Await(p)
  p = nil  -- the timer still holds finish; let the result go now rather than when the timer fires
  if not r[1] then error(r[2], 0) end
  return r[2]
end

-- Runs SQL text and returns oxmysql's result, or nil and why. oxmysql may raise or return nil on a
-- failure; both become nil, why.
local function run(text, params)
  local ok, res = pcall(function() return await(text, params or {}) end)
  if not ok then return nil, tostring(res) end
  if res == nil then return nil, 'no reply from the database' end
  return res
end

-- Runs a named statement from server/sql.lua.
function M.run(name, params)
  local text = sql.text[name]
  if not text then return nil, 'no statement named ' .. tostring(name) end
  return run(text, params)
end

-- ctx gets ctx.db = { failures, last_failure, flushing, written }.
local function failed(ctx, what, why)
  ctx.db.failures = ctx.db.failures + 1
  ctx.db.last_failure = ('%s: %s'):format(what, tostring(why))
  log.say('database: ' .. ctx.db.last_failure)
  return nil, why
end

function M.init(ctx)
  ctx.db = { failures = 0, last_failure = nil, flushing = false, written = 0, skipped_rows = 0 }
  unanswered_at, probing = nil, false
end

function M.prepare(ctx)
  for _, name in ipairs({ 'create_ledger', 'create_baselines', 'create_incidents' }) do
    local ok, why = M.run(name)
    if not ok then return failed(ctx, 'creating tables', why) end
  end
  return true
end

-- Writes the oldest waiting ledger lines. Only one flush is ever in flight, and it always starts at the
-- queue head; lines are forgotten only once the database confirms them.
function M.flush(ctx)
  if ctx.db.flushing then return nil, 'a flush is already in flight' end
  if waiting() then return nil, 'waiting for the database to answer' end  -- quietly: the lines stay queued
  local lines, first = ctx.engine:peek_ledger(unanswered_at and 1 or FLUSH_BATCH)  -- one line as the probe
  if #lines == 0 then return true end
  ctx.db.flushing = true
  local params = {}
  for _, l in ipairs(lines) do
    local row = { l.t, l.kind, tostring(l.player or ''), tostring(l.name or ''), l.key, l.delta, l.reason,
      tostring(l.actor or '') }
    for _, v in ipairs(row) do params[#params + 1] = v end
  end
  local ok, why = run(sql.insert_ledger(#lines), params)
  ctx.db.flushing = false
  if not ok then return failed(ctx, 'writing the ledger', why) end
  ctx.engine:commit_ledger(first, #lines)
  ctx.db.written = ctx.db.written + #lines
  return true
end

local function encode(v)
  local ok, s = pcall(json.encode, v)
  if ok and type(s) == 'string' then return s end
  return nil
end

-- Saves the engine's state (only what changed, when changed_only) plus the layer's own small state.
-- The engine forgets its changes only when every row landed.
function M.save(ctx, changed_only)
  local data, token = ctx.engine:export(changed_only)
  local now = ctx.clock:now()
  local rows = { { 'meta', data.meta }, { 'layer', ctx.layer_state or {} } }
  for key, r in pairs(data.reasons) do rows[#rows + 1] = { 'reason:' .. key, r } end
  local all_ok = true
  for _, row in ipairs(rows) do
    local s = encode(row[2])
    if not s then
      ctx.db.skipped_rows = ctx.db.skipped_rows + 1
    else
      local ok, why = M.run('save_baseline', { row[1], s, now })
      if not ok then
        all_ok = false
        failed(ctx, 'saving ' .. row[1], why)
        break
      end
    end
  end
  for _, inc in ipairs(all_ok and data.incidents or {}) do
    local s = encode(inc)
    if s then
      local ok, why = M.run('save_incident', { inc.id, inc.type, inc.open and 1 or 0, s, now })
      if not ok then
        all_ok = false
        failed(ctx, 'saving incident #' .. tostring(inc.id), why)
        break
      end
    else
      ctx.db.skipped_rows = ctx.db.skipped_rows + 1
    end
  end
  if all_ok then ctx.engine:mark_saved(token) end
  return all_ok
end

-- What an earlier save left: the engine's saved state, the layer's state, and how many rows could not be
-- read. Returns nil and why when the database can't be read at all.
function M.load(ctx)
  local rows, why = M.run('load_baselines')
  if not rows then return failed(ctx, 'loading saved state', why) end
  local incidents, why2 = M.run('load_incidents')
  if not incidents then return failed(ctx, 'loading incidents', why2) end
  local saved, layer, bad = { reasons = {}, incidents = {} }, {}, 0
  for _, r in ipairs(rows) do
    local ok, v = pcall(json.decode, r.v)
    if not ok or type(v) ~= 'table' then
      bad = bad + 1
    elseif r.k == 'meta' then
      saved.meta = v
    elseif r.k == 'layer' then
      layer = v
    elseif type(r.k) == 'string' and r.k:sub(1, 7) == 'reason:' then
      saved.reasons[r.k:sub(8)] = v
    end
  end
  for i = #incidents, 1, -1 do  -- oldest first
    local ok, v = pcall(json.decode, incidents[i].v)
    if ok and type(v) == 'table' then saved.incidents[#saved.incidents + 1] = v else bad = bad + 1 end
  end
  ctx.db.skipped_rows = ctx.db.skipped_rows + bad
  if not saved.meta and next(saved.reasons) == nil and #saved.incidents == 0 then saved = nil end
  return saved, layer, bad
end

local TRIM_CHUNK = 5000  -- matches the LIMIT in server/sql.lua's trim_ledger

-- Removes ledger lines older than retention_days, a chunk at a time with a pause between chunks, until
-- a chunk comes back short.
function M.trim(ctx)
  local cutoff = ctx.clock:now() - ctx.settings.retention_days * 86400
  while true do
    local res, why = M.run('trim_ledger', { cutoff })
    if not res then return failed(ctx, 'trimming the ledger', why) end
    if (tonumber(res.affectedRows) or 0) < TRIM_CHUNK then return true end
    if coroutine.isyieldable() then Wait(100) end
  end
end

return M
