-- The watchdog's brain. Takes framework notifications and bookkeeper counts, returns Discord
-- messages. Makes no FiveM calls, so it runs the same in the game and in tests on the Mac.
local defaults = require('core.defaults')
local Ledger = require('core.ledger')
local Learner = require('core.learner')
local Reconcile = require('core.reconcile')
local Detectors = require('core.detectors')
local Incidents = require('core.incidents')
local alerts = require('core.alerts')

local M = {}
M.__index = M

local KINDS = { 'money', 'items' }  -- what a bookkeeper count carries

-- The smallest (and for some, largest) value each number may take. Below a floor a setting stops
-- making sense or breaks the core: min_samples 0 would read a quantile of an empty list on every gain.
local RANGES = {
  count_every_s = { 60 }, flush_every_s = { 1 }, ledger_cap = { 1 }, retention_days = { 1 },
  learning_hours = { 0 }, fast_factor = { 1 }, fast_quantile = { 0.5, 1 }, min_samples = { 1 },
  samples_per_reason = { 1 }, samples_per_hour_of_day = { 1 }, max_reasons = { 1 },
  incident_window_s = { 1 }, alerts_per_minute = { 1, 30 }, outbox_cap = { 1 }, health_quiet_s = { 60 },
  stash_window_s = { 0 }, refill_window_s = { 0 }, money_tolerance = { 0 }, item_tolerance = { 0 },
  label_margin = { 1 }, staff_amount = { 0 }, pair_window_s = { 0 },
  tick_every_s = { 10 }, discord_every_s = { 1 }, discord_regrow_factor = { 1.1 }, discord_retries = { 0, 10 },
  clock_drift_s = { 1 },  -- the clock anchors on a whole second, so up to 1 s off is normal, not drift
}

-- Word settings and the words each may be.
local CHOICES = {
  framework = { auto = true, qbcore = true, qbox = true },
  inventory = { auto = true, ox = true, qb = true, none = true },
  banking = { auto = true, ['qb-banking'] = true, none = true },
}

-- Why an override can't replace its default, or nil if it can: it must be the default's type, a
-- number must be finite and inside its range, and a list of words must hold only strings.
local function bad_setting(name, v, default)
  if type(v) ~= type(default) then return ('expected a %s, got %s'):format(type(default), type(v)) end
  if type(v) == 'number' then
    if v ~= v or v == math.huge or v == -math.huge then return 'expected a finite number' end
    local r = RANGES[name]
    if r and v < r[1] then return ('must be at least %s'):format(tostring(r[1])) end
    if r and r[2] and v > r[2] then return ('must be at most %s'):format(tostring(r[2])) end
  end
  if type(v) == 'table' then
    for _, w in pairs(v) do
      if type(w) ~= 'string' then return 'expected a list of strings' end
    end
  end
  if CHOICES[name] and not CHOICES[name][v] then
    local words = {}
    for w in pairs(CHOICES[name]) do words[#words + 1] = w end
    table.sort(words)
    return 'must be one of ' .. table.concat(words, ', ')
  end
  return nil
end

-- Defaults with the owner's overrides. An override of the wrong type keeps the default and is
-- reported in warnings. A key with no default is reported too (most likely a misspelling), and passes
-- through untouched.
local function merge(over)
  local s, warnings = {}, {}
  for k, v in pairs(defaults) do s[k] = v end
  if type(over) ~= 'table' then over = {} end
  local keys = {}
  for k in pairs(over) do
    if type(k) == 'string' then keys[#keys + 1] = k end
  end
  table.sort(keys)
  for _, name in ipairs(keys) do
    local v = over[name]
    local why = defaults[name] ~= nil and bad_setting(name, v, defaults[name])
    if defaults[name] == nil then
      warnings[#warnings + 1] = ('setting %s is not a known setting (misspelled?); it does nothing'):format(name)
    end
    if why then
      warnings[#warnings + 1] = ('setting %s ignored (%s); using the default'):format(name, why)
    elseif v ~= nil then
      s[name] = v
    end
  end
  return s, warnings
end

-- The engine is the trust boundary: FiveM-layer input is checked here, so every module behind it may
-- assume ids are strings or finite numbers and numbers are finite.
local function finite(n)
  return type(n) == 'number' and n == n and n ~= math.huge and n ~= -math.huge
end

local function is_id(v)
  return type(v) == 'string' or finite(v)
end

-- Snapshot totals: string keys (money types, item names) and finite numbers only.
local function all_finite(tbl)
  for k, v in pairs(tbl) do
    if type(k) ~= 'string' or not finite(v) then return false end
  end
  return true
end

-- Every string a notification carries is stored in each queued line and may be printed in alerts:
-- cap them so one script's 20 KB reason can neither fill memory at the ledger cap nor push an alert
-- past Discord's 2,000 characters. Control characters become spaces, so a name can't start a new
-- line in Discord.
local CAPS = { reason = 120, name = 64, item = 64, actor = 80, money_type = 32, from_container = 100,
  to_container = 100, account = 50, player = 64 }

-- s cut to at most n bytes, never inside a UTF-8 character.
local function cut(s, n)
  s = s:sub(1, n)
  for _ = 1, 3 do
    if utf8.len(s) then break end
    s = s:sub(1, -2)
  end
  return s
end

-- v as text with control characters replaced and cut to n bytes.
local function clean(v, n)
  local s = (tostring(v):gsub('%c', ' '))
  if #s > n then s = cut(s, n) end
  return s
end

-- A player key as every entry point stores it: text cleaned and cut like the other strings, an in-game ID
-- sent as a number left a number.
local function player_key(p)
  if type(p) == 'string' then return clean(p, CAPS.player) end
  return p
end

-- The notification with every string field cleaned and capped: a copy when anything changed, so the
-- caller's table is left alone.
local function capped(ev)
  local c
  for field, n in pairs(CAPS) do
    local v = ev[field]
    if v ~= nil and (field ~= 'player' or type(v) == 'string') then
      local s = clean(v, n)
      if s ~= v then
        if not c then
          c = {}
          for k, x in pairs(ev) do c[k] = x end
        end
        c[field] = s
      end
    end
  end
  return c or ev
end

-- A snapshot's totals re-keyed the way notifications are, so a long item name counted by the
-- bookkeeper meets the same capped name in the ledger. Keys that collide after cutting are summed.
local function clean_keys(tbl, n)
  local out = {}
  for k, v in pairs(tbl) do
    local key = clean(k, n)
    out[key] = (out[key] or 0) + v
  end
  return out
end

-- The first pattern in self.s[name] that matches text, and what it captured (the whole match when the
-- pattern has no capture). Some typos only show while matching ('x%', an unfinished capture), so a pattern
-- that errors is dropped and reported then: it can never raise inside a notification.
function M:first_match(text, name)
  local list = self.s[name]
  local i = 1
  while i <= #list do
    local ok, got = pcall(string.match, text, list[i])
    if not ok then
      self.settings_warnings[#self.settings_warnings + 1] =
        ('setting %s: pattern %q dropped (%s)'):format(name, list[i], tostring(got))
      table.remove(list, i)
    elseif got then
      return list[i], got
    else
      i = i + 1
    end
  end
  return nil
end

-- The patterns that compile, plus a warning for each one that doesn't, so a typo in an owner's
-- pattern list can never raise inside a money notification.
local function usable_patterns(name, list, warnings)
  local ok_list = {}
  for _, p in ipairs(list) do
    if pcall(string.find, '', p) then
      ok_list[#ok_list + 1] = p
    else
      warnings[#warnings + 1] = ('setting %s: pattern %q ignored (not a valid pattern)'):format(name, p)
    end
  end
  return ok_list
end

-- The settings an engine would run with: the defaults, the owner's usable overrides, and a warning
-- for each override that was refused. The FiveM layer reads its own settings through this too.
function M.read_settings(over)
  local s, warnings = merge(over)
  s.transfer_patterns = usable_patterns('transfer_patterns', s.transfer_patterns, warnings)
  s.account_patterns = usable_patterns('account_patterns', s.account_patterns, warnings)
  return s, warnings
end

-- settings: owner overrides of core/defaults.lua.
-- clock: { first_start = when the watchdog first ever ran (persisted), now = this start,
--          day_offset_s = the server's offset from UTC in seconds, so digest days are local (default 0) }.
-- saved: what an earlier Engine:export() produced (read back from the database), or nil on a first start.
function M.new(settings, clock, saved)
  local s, warnings = M.read_settings(settings)
  local e = setmetatable({
    s = s,
    settings_warnings = warnings,  -- overrides refused for the wrong type, shown by /wd status
    first_start = clock.first_start,
    ledger = Ledger.new(s.ledger_cap),
    learner = Learner.new(s),
    reconcile = Reconcile.new(s),
    detectors = Detectors.new(s),
    incidents = Incidents.new(s),
    outbox = alerts.Outbox.new(s),
    last_money_t = clock.now,
    cant_hear_sent = false,
    dropped_reported = 0,
    day = { key = nil, sources = {}, totals = {} },
    day_offset_s = finite(clock.day_offset_s) and clock.day_offset_s or 0,
    carried = {},  -- carried[kind] = true once an accepted count has carried that kind
    pairs = {},    -- pairs[account] = { {t, delta, used}, ... }: player transfers awaiting the bank's record
    records = {},  -- records[account] = { {t, delta, used}, ... }: bank records not yet matched to a player
    refused = 0,   -- counts refused as malformed, shown by /wd status
  }, M)
  e.learner.learning_until = clock.first_start + s.learning_hours * 3600
  e.import_warnings = {}
  if saved ~= nil then e:import(saved) end
  return e
end

-- Whatever the database held is untrusted: anything unusable is skipped and reported, never raised.
function M:import(saved)
  local warn = self.import_warnings
  if type(saved) ~= 'table' then
    warn[#warn + 1] = 'saved state is not a table; starting fresh'
    return
  end
  for _, part in ipairs({ 'meta', 'reasons', 'incidents' }) do
    if saved[part] ~= nil and type(saved[part]) ~= 'table' then
      warn[#warn + 1] = ('saved %s is not a table; skipped'):format(part)
    end
  end
  local meta = type(saved.meta) == 'table' and saved.meta or {}
  if finite(meta.next_id) and meta.next_id > self.incidents.next_id then
    self.incidents.next_id = math.floor(meta.next_id)
  end
  if type(meta.labels) == 'table' then
    for _, kind in ipairs({ 'money', 'items' }) do
      for key, v in pairs(type(meta.labels[kind]) == 'table' and meta.labels[kind] or {}) do
        if type(key) == 'string' and finite(v) then self.reconcile.labels[kind][key] = v end
      end
    end
  end
  local day = type(meta.day) == 'table' and meta.day or {}
  if finite(day.key) then self.day.key = day.key end
  for reason, v in pairs(type(day.sources) == 'table' and day.sources or {}) do
    if type(reason) == 'string' and finite(v) then self.day.sources[reason] = v end
  end
  for _, pair in ipairs(type(day.totals) == 'table' and day.totals or {}) do
    if type(pair) == 'table' and finite(pair[1]) and finite(pair[2]) then self.day.totals[pair[1]] = pair[2] end
  end
  for key, data in pairs(type(saved.reasons) == 'table' and saved.reasons or {}) do
    local ok, why = self.learner:import_reason(key, data)
    if not ok then warn[#warn + 1] = why end
  end
  for _, d in ipairs(type(saved.incidents) == 'table' and saved.incidents or {}) do
    local ok, why = self.incidents:import_incident(d)
    if not ok then warn[#warn + 1] = why end
  end
  while #warn > 20 do table.remove(warn) end
end

-- State to save, as plain data that survives JSON: { meta, reasons = { [key] = data }, incidents = { ... } },
-- plus a token to hand back to mark_saved once the database has it. With changed_only, only reasons and
-- incidents that changed since their last confirmed save are included; meta is always whole.
function M:export(changed_only)
  local totals = {}
  for d, total in pairs(self.day.totals) do totals[#totals + 1] = { d, total } end
  table.sort(totals, function(a, b) return a[1] < b[1] end)
  local data = {
    meta = { version = 1, first_start = self.first_start, next_id = self.incidents.next_id,
      labels = self.reconcile.labels,
      day = { key = self.day.key, sources = self.day.sources, totals = totals } },
    reasons = {}, incidents = {},
  }
  local token = { reasons = {}, incidents = {} }
  local l, inc = self.learner, self.incidents
  for key in pairs(changed_only and l.dirty or l.reasons) do
    if l.reasons[key] then
      data.reasons[key] = l:export_reason(key)
      token.reasons[key] = l.dirty[key] or 0
    end
  end
  local ids = {}
  for id in pairs(changed_only and inc.dirty or inc.by_id) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local d = inc:export_incident(id)
    if d then data.incidents[#data.incidents + 1] = d end
    token.incidents[id] = inc.dirty[id] or 0
  end
  return data, token
end

-- The database confirmed an export: forget its changes, except any made since it was taken.
function M:mark_saved(token)
  if type(token) ~= 'table' then return nil, 'token must be what export returned' end
  for _, part in ipairs({ { 'reasons', self.learner.dirty }, { 'incidents', self.incidents.dirty } }) do
    for key, v in pairs(type(token[part[1]]) == 'table' and token[part[1]] or {}) do
      if part[2][key] == v then part[2][key] = nil end
    end
  end
  return true
end

function M:learning(t) return t < self.first_start + self.s.learning_hours * 3600 end

function M:raise(f)
  local inc, is_new = self.incidents:add(f)
  self.outbox:put({ op = is_new and 'post' or 'edit', incident_id = inc.id, text = alerts.text(inc),
    amount = inc.amount })
  return inc
end

function M:player_loaded(player, balances)
  if not is_id(player) then return nil, 'player must be a string or number' end
  if balances ~= nil and type(balances) ~= 'table' then return nil, 'balances must be a table' end
  local clean = {}
  for k, v in pairs(balances or {}) do
    if type(k) == 'string' and finite(v) then clean[k] = v end
  end
  self.ledger:seed(player_key(player), clean)
  return true
end

function M:player_dropped(player, t)
  if not is_id(player) or not finite(t) then return nil, 'player and a finite t are required' end
  player = player_key(player)
  self.detectors:player_dropped(player, t)
  self.ledger:forget(player)
  return true
end

-- A gain judged against what is normal for its key; raises alarm 2 outside the learning period.
function M:judge_gain(line, key, unit, label)
  local total, limit, used, top = self.learner:gain(line.player, key, line.delta, line.t)
  if limit and total > limit and not self:learning(line.t) then
    self:raise({ type = 'too_fast', group = 'fast|' .. tostring(line.player) .. '|' .. used, amount = total,
      mode = 'latest', t = line.t,
      detail = { name = line.name, src = line.src, reason = label, unit = unit, normal_top = top, key = used } })
  end
end

-- ev: see Ledger:money. Returns the ledger line, or nil and why.
function M:money(ev)
  if type(ev) ~= 'table' then return nil, 'notification must be a table' end
  if not is_id(ev.player) then return nil, 'player must be a string or number' end
  if type(ev.money_type) ~= 'string' then return nil, 'money_type must be a string' end
  if not finite(tonumber(ev.t)) then return nil, 't must be a finite number' end  -- a missing t would read as 1970
  if not finite(tonumber(ev.amount)) then return nil, 'amount must be a finite number' end
  if ev.difference ~= nil and not finite(tonumber(ev.difference)) then return nil, 'difference must be a finite number' end
  local line, why = self.ledger:money(capped(ev))
  if not line then return nil, why end
  self.last_money_t = line.t
  self.cant_hear_sent = false
  local said = line.reason:lower()
  local account_p, account = self:first_match(said, 'account_patterns')
  if account_p then self:transfer_to_account(clean(account, CAPS.account), line) end
  -- a transfer moves money that already exists: recorded for the count, never judged as earning
  if account_p or self:first_match(said, 'transfer_patterns') then return line end
  if line.delta > 0 then self:judge_money(line) end
  return line
end

-- A money gain judged: it joins the day's top sources, staff money is reported, and alarm 2 weighs it.
function M:judge_money(line)
  local src = self.day.sources
  src[line.reason_key] = (src[line.reason_key] or 0) + line.delta
  if self.detectors:staff(line) then
    self:raise({ type = 'staff_money', group = 'staff|' .. tostring(line.player) .. '|' .. line.reason_key,
      amount = line.delta, mode = 'sum', t = line.t, detail = line })
  end
  self:judge_gain(line, 'money:' .. line.reason_key, 'money', line.reason)
end

-- Money a script paid as an account item, cash held as an item (ev: { t, player, name, src, money_type,
-- amount, reason }). The framework already records the money, as a sync 'set' that is a transfer, so
-- nothing is added to the ledger: the gain is only judged, as a money add is. Returns the judged line, or
-- nil and why.
function M:earned(ev)
  if type(ev) ~= 'table' then return nil, 'earned needs a table' end
  if not is_id(ev.player) then return nil, 'player must be a string or number' end
  if type(ev.money_type) ~= 'string' then return nil, 'money_type must be a string' end
  if not finite(ev.t) then return nil, 't must be a finite number' end
  if not finite(ev.amount) then return nil, 'amount must be a finite number' end
  local c = capped(ev)
  local reason = tostring(c.reason or 'unknown')
  local line = { t = c.t, kind = 'money', player = c.player, name = c.name, src = c.src, key = c.money_type,
    delta = c.amount, reason = reason, reason_key = Ledger.reason_key(reason) }
  if line.delta > 0 then self:judge_money(line) end
  return line
end

-- ev: see Ledger:item, plus slot_available = how many the source slot held before a withdrawal, and
-- transfer = true for an item that moves rather than enters the economy (a give between two players, a
-- pickup from an uncounted drop): it counts toward the totals as usual but is never judged as earning,
-- like a money transfer.
function M:item(ev)
  if type(ev) ~= 'table' then return nil, 'notification must be a table' end
  if ev.from_container ~= nil and type(ev.from_container) ~= 'string' then
    return nil, 'from_container must be a string'
  end
  if type(ev.item) ~= 'string' then return nil, 'item must be a string' end
  if ev.player ~= nil and not is_id(ev.player) then return nil, 'player must be a string or number' end
  if not finite(tonumber(ev.t)) then return nil, 't must be a finite number' end
  if not finite(tonumber(ev.count)) then return nil, 'count must be a finite number' end
  local line, why = self.ledger:item(capped(ev))
  if not line then return nil, why end
  local slot = self.detectors:withdrawal(line, tonumber(ev.slot_available))
  if slot then
    self:raise({ type = 'same_slot_twice', group = 'slot|' .. slot.container .. '#' .. tostring(slot.slot),
      amount = slot.first.count + slot.second.count, mode = 'latest', t = line.t, detail = slot })
  end
  if line.delta > 0 and line.player and not ev.transfer then
    self:judge_gain(line, 'item:' .. line.key, 'item', line.key)
  end
  return line
end

-- A player's money moving to or from a business/gang account (the account name already cleaned and cut
-- like account_change's): the account side moves the opposite way. Usually the bank's own record of the
-- move is read later and pairs with this; a count can land between the two, so a record already read for
-- this move counts it instead.
function M:transfer_to_account(account, line)
  local delta = -line.delta
  for _, r in ipairs(self.records[account] or {}) do
    if not r.used and math.abs(r.delta - delta) < 0.005 and math.abs(r.t - line.t) <= self.s.pair_window_s then
      r.used = true
      return
    end
  end
  self.ledger:note('money', 'accounts', delta)
  local list = self.pairs[account] or {}
  list[#list + 1] = { t = line.t, delta = delta }
  self.pairs[account] = list
end

-- The bank's own record of a business/gang account change (ev: { t, account, delta }). A record that
-- pairs with a player's transfer is already counted; one that doesn't is a script paying the account
-- and is recorded (and kept, in case the player's side of it arrives just after); a second record for a
-- transfer that already paired is held back, so a bank that credits one deposit twice shows up as money
-- appearing. Returns 'paired', 'recorded' or 'held back'.
function M:account_change(ev)
  if type(ev) ~= 'table' or not finite(ev.t) or not finite(ev.delta) then
    return nil, 'account change needs a finite t and delta'
  end
  if type(ev.account) ~= 'string' then return nil, 'account must be a string' end
  local account = clean(ev.account, CAPS.account):lower()
  local w = self.s.pair_window_s
  local held_back = false
  for _, p in ipairs(self.pairs[account] or {}) do
    if math.abs(p.delta - ev.delta) < 0.005 and math.abs(p.t - ev.t) <= w then
      if not p.used then
        p.used = true
        return 'paired'
      end
      held_back = true
    end
  end
  if held_back then return 'held back' end
  self.ledger:note('money', 'accounts', ev.delta)
  local recs = self.records[account] or {}
  recs[#recs + 1] = { t = ev.t, delta = ev.delta }
  self.records[account] = recs
  return 'recorded'
end

-- Cash held as an item moved into or out of a stash, trunk, glovebox or drop (ev: { t, money_type, delta }).
-- The player's side arrives as its own money notification; this records the container's side.
function M:container_cash(ev)
  if type(ev) ~= 'table' or not finite(ev.t) or not finite(ev.delta) then
    return nil, 'container cash needs a finite t and delta'
  end
  if type(ev.money_type) ~= 'string' then return nil, 'money_type must be a string' end
  self.ledger:note('money', clean(ev.money_type, CAPS.money_type), ev.delta)
  return true
end

-- Other scripts declaring their own changes (exports.economy_watchdog:record). Same rules apply.
function M:record(ev)
  if type(ev) == 'table' and ev.kind == 'item' then return self:item(ev) end
  return self:money(ev)
end

-- Dollars in circulation: crypto is a different currency and is never added in.
local function money_total(m)
  local sum = 0
  for k, v in pairs(m or {}) do
    if k ~= 'crypto' then sum = sum + v end
  end
  return sum
end

-- Daily digest (alarm 5) at the first count of a new day, on the server's own clock.
function M:track_supply(snap)
  local d = math.floor((snap.t + self.day_offset_s) / 86400)
  local total = money_total(snap.money)
  local day = self.day
  if day.key and d > day.key then
    local top = {}
    for reason, amount in pairs(day.sources) do top[#top + 1] = { reason, amount } end
    table.sort(top, function(a, b) return a[2] > b[2] end)
    while #top > 3 do table.remove(top) end
    self.outbox:put({ op = 'post', text = alerts.digest({ total = total, week_ago = day.totals[d - 7],
      top = top, decreases = self.reconcile.decreases }) })
    self.reconcile.decreases = 0
    day.sources = {}
  end
  day.key = d
  if not day.totals[d] then day.totals[d] = total end
  for k in pairs(day.totals) do
    if k < d - 8 then day.totals[k] = nil end
  end
end

-- snap: { t, money = { cash, bank, crypto, accounts? }, items = { [name] = total }, restarted = bool }
-- Returns the findings, or nil and why for a malformed snapshot (the recorded window is kept for the next
-- count). Refusals are counted for /wd status, with the last reason.
function M:count(snap)
  local findings, why = self:judge_count(snap)
  if not findings then
    self.refused = self.refused + 1
    self.last_refusal = why
  end
  return findings, why
end

function M:judge_count(snap)
  if type(snap) ~= 'table' or not finite(snap.t) then return nil, 'snapshot needs a table with a number t' end
  if snap.money ~= nil and (type(snap.money) ~= 'table' or not all_finite(snap.money)) then
    return nil, 'snapshot money must be a table of finite numbers'
  end
  if snap.items ~= nil and (type(snap.items) ~= 'table' or not all_finite(snap.items)) then
    return nil, 'snapshot items must be a table of finite numbers'
  end
  -- A kind the last count carried but this one leaves out (its query failed) would read as every
  -- total falling to zero and then, at the next full count, rising from zero: refuse it instead.
  for _, kind in ipairs(KINDS) do
    if self.carried[kind] and snap[kind] == nil then
      return nil, ('snapshot left out %s, which the last count carried'):format(kind)
    end
  end
  for _, kind in ipairs(KINDS) do
    if snap[kind] ~= nil then self.carried[kind] = true end
  end
  snap = { t = snap.t, restarted = snap.restarted,
    money = snap.money and clean_keys(snap.money, CAPS.money_type),
    items = snap.items and clean_keys(snap.items, CAPS.item) }
  local window, unseeded = self.ledger:take_window()
  local findings = self.reconcile:count(snap, window, unseeded)
  -- A steady leak finds a gap every second count, so an "appeared" incident stays open across two
  -- counts (plus a minute of slack) instead of the 15 minutes other incidents use.
  local appeared_window = math.max(self.s.incident_window_s, 2 * self.s.count_every_s + 60)
  for _, f in ipairs(findings) do
    local group = 'appeared|' .. f.kind .. '|' .. f.key
    local detail = { kind = f.kind, key = f.key, window_s = f.window_s, gap = f.gap, peak = f.peak }
    if f.kind == 'items' then detail.suspects = self.detectors:refill_suspects(f.key, snap.t) end
    detail.window_start = snap.t - f.window_s
    local open = self.incidents.open[group]
    local open_peak = open and open.detail.peak
    local open_start = open and open.detail.window_start
    local inc = self:raise({ type = 'appeared', group = group, amount = f.gap, mode = 'sum', t = snap.t,
      window = appeared_window, detail = detail })
    if inc == open then
      -- merged: keep the largest per-count gap the incident has seen, since /wd legit is sized from it,
      -- and report the whole span since the incident's first finding, not just the latest one
      if open_peak and open_peak > inc.detail.peak then inc.detail.peak = open_peak end
      if open_start and open_start < inc.detail.window_start then
        inc.detail.window_start = open_start
        inc.detail.window_s = snap.t - open_start
        self.outbox:put({ op = 'edit', incident_id = inc.id, text = alerts.text(inc), amount = inc.amount })
      end
    end
  end
  self:track_supply(snap)
  return findings
end

-- Called about once a minute by the FiveM layer.
function M:tick(t, players_online)
  if not finite(t) or not finite(players_online) then return nil, 'tick needs a finite t and player count' end
  -- a transfer's bank record arrives with the next count at the latest: keep two counts' worth of both
  -- sides waiting for each other
  local keep = 2 * self.s.count_every_s + 60
  for _, side in ipairs({ self.pairs, self.records }) do
    for account, list in pairs(side) do
      local kept = {}
      for _, p in ipairs(list) do
        if t - p.t <= keep then kept[#kept + 1] = p end
      end
      side[account] = #kept > 0 and kept or nil
    end
  end
  self.learner:sweep(t)
  self.detectors:sweep(t)
  self.incidents:sweep(t)
  if players_online == 0 then
    self.last_money_t = t  -- silence only counts while someone could be earning
  elseif not self.cant_hear_sent and t - self.last_money_t >= self.s.health_quiet_s then
    self.cant_hear_sent = true
    self.outbox:put({ op = 'post', text = alerts.cant_hear(players_online, math.floor((t - self.last_money_t) / 60)) })
  end
  if self.ledger.dropped > self.dropped_reported then
    self.outbox:put({ op = 'post', text = alerts.dropped(self.ledger.dropped - self.dropped_reported, self.s.ledger_cap) })
    self.dropped_reported = self.ledger.dropped
  end
  return true
end

-- The owner's answer from /wd fine|exploit|legit <id>. "fine" and "legit" mean the same thing:
-- for alarm 2 the amount becomes normal, for alarm 1 the gap becomes an allowance.
function M:answer(id, verdict)
  local inc, why = self.incidents:answer(id, verdict)
  if not inc then return nil, why end
  local d = inc.detail
  if verdict ~= 'exploit' and type(d.key) == 'string' then
    if inc.type == 'too_fast' then
      self.learner:allow(d.key, inc.amount)
    elseif inc.type == 'appeared' and (d.kind == 'money' or d.kind == 'items') then
      -- per count, not the two-count gap; an incident restored without its peak falls back to its total
      self.reconcile:label(d.kind, d.key, finite(d.peak) and d.peak or inc.amount)
    end
  end
  return inc
end

function M:status(t)
  if not finite(t) then return nil, 't must be a finite number' end
  local open = {}  -- every open incident, oldest first, for /wd status
  for _, inc in pairs(self.incidents.open) do
    open[#open + 1] = { id = inc.id, type = inc.type, amount = inc.amount, detail = inc.detail }
  end
  table.sort(open, function(a, b) return a.id < b.id end)
  return {
    learning = self:learning(t),
    learning_left_h = math.max(0, math.ceil((self.first_start + self.s.learning_hours * 3600 - t) / 3600)),
    reasons_learned = self.learner.reason_count,
    open_incidents = #open,
    open = open,
    queued_lines = self.ledger:size(),
    dropped_lines = self.ledger.dropped,
    uncertain_counts = self.reconcile.uncertain,
    refused_counts = self.refused,
    last_refusal = self.last_refusal,
    quiet_s = t - self.last_money_t,
    settings_warnings = self.settings_warnings,
    import_warnings = self.import_warnings,
  }
end

-- The layer stopped counting a kind on purpose (its item system can't be heard): counts may leave it out from
-- now on without being refused. Its held gaps go too.
function M:forget_kind(kind)
  if kind ~= 'money' and kind ~= 'items' then return nil, 'kind must be money or items' end
  self.carried[kind] = nil
  self.reconcile.pending[kind] = {}
  return true
end

-- A plain notice from the FiveM layer (counting stopped, item counting off), posted as it is.
function M:notice(text)
  if type(text) ~= 'string' or text == '' then return nil, 'notice needs a non-empty string' end
  self.outbox:put({ op = 'post', text = text })
  return true
end

function M:take_alerts(t)
  if not finite(t) then return nil, 't must be a finite number' end
  return self.outbox:take(t)
end

function M:peek_ledger(n)
  if not finite(n) or n < 0 then return nil, 'n must be a finite number' end
  return self.ledger:peek(n)
end

-- Only lines a peek could have returned can be committed: a pair that starts past the queue head or
-- runs past its end is refused, so a bad pair can never move the head past unwritten lines. (A first
-- below the head is fine: lines dropped while the write was in flight are already gone.)
function M:commit_ledger(first, count)
  if not finite(first) or not finite(count) or count < 0 then return nil, 'first and count must be finite numbers' end
  first, count = math.tointeger(first), math.tointeger(count)  -- 3.0 becomes 3; 2.5 and 1e300 become nil
  if not first or not count then return nil, 'first and count must be whole numbers' end
  if first < 1 then return nil, 'first must be at least 1' end
  if first + count - 1 > self.ledger.tail then return nil, 'commit past the end of the queue' end
  if first > self.ledger.head then return nil, 'commit starts past the queue head' end
  self.ledger:commit(first, count)
  return true
end

return M
