-- Groups findings into incidents (one per player + reason per window) and records the owner's answers.
local M = {}
M.__index = M

local VERDICTS = { fine = true, exploit = true, legit = true }

function M.new(s)
  -- dirty[id] = a change counter, bumped whenever that incident changes (saved by the FiveM layer)
  return setmetatable({ s = s, next_id = 1, open = {}, by_id = {}, dirty = {} }, M)
end

function M:touch(id) self.dirty[id] = (self.dirty[id] or 0) + 1 end

-- f: { type, group, amount, mode = 'sum'|'latest', t, detail, window? }
-- Returns the incident and whether it is new. Within its window (f.window when the finding set one,
-- else incident_window_s) of its last update, the same group updates the open incident: 'sum' adds
-- the amount, 'latest' replaces it.
function M:add(f)
  local cur = self.open[f.group]
  if cur and f.t - cur.last_t <= (cur.window or self.s.incident_window_s) then
    if f.mode == 'sum' then cur.amount = cur.amount + f.amount else cur.amount = f.amount end
    cur.hits = cur.hits + 1
    cur.last_t = f.t
    cur.detail = f.detail
    self:touch(cur.id)
    return cur, false
  end
  local inc = { id = self.next_id, type = f.type, group = f.group, amount = f.amount, hits = 1,
    first_t = f.t, last_t = f.t, detail = f.detail, window = f.window }
  self.next_id = self.next_id + 1
  self.open[f.group] = inc
  self.by_id[inc.id] = inc
  self:touch(inc.id)
  return inc, true
end

function M:answer(id, verdict)
  local inc = self.by_id[tonumber(id)]
  if not inc then return nil, 'no incident #' .. tostring(id) end
  if not VERDICTS[verdict] then return nil, 'answer must be fine, exploit or legit' end
  inc.verdict = verdict
  if self.open[inc.group] == inc then self.open[inc.group] = nil end
  self:touch(inc.id)
  return inc
end

-- Close groups past their window; keep the newest 1000 incidents answerable.
function M:sweep(t)
  for g, inc in pairs(self.open) do
    if t - inc.last_t > (inc.window or self.s.incident_window_s) then
      self.open[g] = nil
      self:touch(inc.id)
    end
  end
  local cutoff = self.next_id - 1000
  for id in pairs(self.by_id) do
    if id < cutoff then self.by_id[id] = nil end
  end
end

-- One incident as plain data, with whether it is still open.
function M:export_incident(id)
  local inc = self.by_id[id]
  if not inc then return nil end
  return { id = inc.id, type = inc.type, group = inc.group, amount = inc.amount, hits = inc.hits,
    first_t = inc.first_t, last_t = inc.last_t, detail = inc.detail, window = inc.window,
    verdict = inc.verdict, open = self.open[inc.group] == inc }
end

local function finite(n) return type(n) == 'number' and n == n and n ~= math.huge and n ~= -math.huge end

-- A saved incident's detail, with every number the engine reads back from an open incident (merging a new
-- "appeared" finding into it, sizing a label from it) dropped unless it is a finite number, so a corrupt row
-- is never compared.
local function clean_detail(detail)
  if type(detail) ~= 'table' then return {} end
  for _, k in ipairs({ 'peak', 'window_start', 'window_s', 'gap' }) do
    if detail[k] ~= nil and not finite(detail[k]) then detail[k] = nil end
  end
  return detail
end

-- Restores one saved incident. Returns true, or nil and why.
function M:import_incident(d)
  if type(d) ~= 'table' or not finite(d.id) or d.id < 1 or math.floor(d.id) ~= d.id then
    return nil, 'saved incident has no whole-number id'
  end
  if type(d.type) ~= 'string' or type(d.group) ~= 'string' or not finite(d.amount) or not finite(d.last_t) then
    return nil, 'saved incident #' .. tostring(d.id) .. ' is missing its type, group, amount or time'
  end
  local inc = { id = math.tointeger(d.id), type = d.type, group = d.group, amount = d.amount,
    hits = finite(d.hits) and d.hits or 1, first_t = finite(d.first_t) and d.first_t or d.last_t,
    last_t = d.last_t, detail = clean_detail(d.detail),
    window = finite(d.window) and d.window or nil, verdict = VERDICTS[d.verdict] and d.verdict or nil }
  self.by_id[inc.id] = inc
  if d.open == true and not inc.verdict then self.open[inc.group] = inc end
  if inc.id >= self.next_id then self.next_id = inc.id + 1 end
  return true
end

return M
