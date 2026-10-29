-- Learns what a normal hour of earning looks like, per reason (and per hour of day), and says
-- when a player's hour is far past it.
local stats = require('core.stats')
local M = {}
M.__index = M

local function hour_of(t) return math.floor(t / 3600) end
local function hod_of(t) return math.floor(t / 3600) % 24 end

function M.new(s)
  -- reasons[key] = { all = {hourly totals}, by_hod = { [0..23] = {hourly totals} }, floor = owner allowance }
  -- open[player .. '\0' .. key] = { hour, total, key, t }
  -- learning_until: hours starting before this are always learned (the engine sets it to the end of
  -- the learning period), so regular spikes such as a 09:00 payday become part of normal.
  -- dirty[key] = a change counter, bumped whenever that reason's record changes, so the FiveM layer
  -- saves only reasons that changed (see Engine:export / Engine:mark_saved).
  return setmetatable({ s = s, reasons = {}, reason_count = 0, open = {}, learning_until = 0, dirty = {} }, M)
end

function M:touch(key) self.dirty[key] = (self.dirty[key] or 0) + 1 end

-- The key reasons past max_reasons share, one per kind. It holds a control character, which the engine
-- strips from every reason and item name, so a script sending the reason "other" keeps its own record.
M.OVERFLOW = '\1other'

-- The reason's record, created on first sight. Past max_reasons, new reasons share one overflow key
-- per kind, so a count of items never sets the normal for dollars.
function M:slot(key)
  local r = self.reasons[key]
  if r then return r, key end
  if self.reason_count >= self.s.max_reasons then
    local kind = key:match('^(%a+):')
    key = kind and (kind .. ':' .. M.OVERFLOW) or M.OVERFLOW
    r = self.reasons[key]
    if r then return r, key end
  end
  r = { all = {}, by_hod = {}, floor = 0 }
  self.reasons[key] = r
  self.reason_count = self.reason_count + 1
  self:touch(key)
  return r, key
end

-- Hourly total above which this key is "far too fast" at time t, and the normal top (p99) it
-- came from. Nil while the key has fewer than min_samples hourly totals.
function M:threshold(key, t)
  local r = self.reasons[key]
  if not r then return nil end
  local list = r.by_hod[hod_of(t)]
  if not list or #list < self.s.min_samples then list = r.all end
  if #list < self.s.min_samples then return nil end
  local top = stats.quantile(list, self.s.fast_quantile)
  return math.max(top * self.s.fast_factor, r.floor), top
end

-- A finished hour becomes a sample. After the learning period, an hour that was itself far too
-- fast is never learned as normal.
function M:close(o)
  local r = self.reasons[o.key]
  if o.t >= self.learning_until then
    local limit = self:threshold(o.key, o.t)
    if limit and o.total > limit then return end
  end
  stats.push_capped(r.all, o.total, self.s.samples_per_reason)
  local hod = hod_of(o.t)
  r.by_hod[hod] = r.by_hod[hod] or {}
  stats.push_capped(r.by_hod[hod], o.total, self.s.samples_per_hour_of_day)
  self:touch(o.key)
end

-- Adds a gain. Returns the player's running total for this hour, the limit (or nil), the key
-- actually used, and the normal top.
function M:gain(player, key, amount, t)
  local _
  _, key = self:slot(key)
  local id = player .. '\0' .. key
  local o = self.open[id]
  if o and hour_of(t) > o.hour then
    self:close(o)
    o = nil
  end
  if not o then
    o = { hour = hour_of(t), total = 0, key = key, t = t }
    self.open[id] = o
  end
  -- an earlier timestamp (clock stepped back) still lands in the open hour
  o.total = o.total + amount
  local limit, top = self:threshold(key, t)
  return o.total, limit, key, top
end

-- Close every hour that has ended, so quiet players' hours are learned and memory is freed. Hours close
-- in sorted order, so the same notifications always build the same baselines.
function M:sweep(t)
  local h = hour_of(t)
  local ended = {}
  for id, o in pairs(self.open) do
    if o.hour < h then ended[#ended + 1] = id end
  end
  table.sort(ended)
  for _, id in ipairs(ended) do
    self:close(self.open[id])
    self.open[id] = nil
  end
end

-- The owner said "fine": this much in an hour is normal for this key from now on.
function M:allow(key, amount)
  local r, used = self:slot(key)
  local want = amount * self.s.label_margin
  if want > r.floor then
    r.floor = want
    self:touch(used)
  end
end

-- One reason's record as plain data that survives JSON: hour-of-day lists under 'h0'..'h23'.
function M:export_reason(key)
  local r = self.reasons[key]
  local by_hod = {}
  for h, list in pairs(r.by_hod) do by_hod['h' .. h] = list end
  return { all = r.all, by_hod = by_hod, floor = r.floor }
end

local function finite(n) return type(n) == 'number' and n == n and n ~= math.huge and n ~= -math.huge end

-- The newest `cap` finite numbers of a saved list, or nil if it isn't a list.
local function clean_list(list, cap)
  if type(list) ~= 'table' then return nil end
  local out = {}
  for _, v in ipairs(list) do
    if finite(v) then out[#out + 1] = v end
  end
  while #out > cap do table.remove(out, 1) end
  return out
end

-- Restores one saved reason. Returns true, or nil and why for data that can't be used.
function M:import_reason(key, data)
  if type(key) ~= 'string' or type(data) ~= 'table' then return nil, 'saved reason is not a table' end
  local all = clean_list(data.all, self.s.samples_per_reason)
  if not all then return nil, 'saved reason ' .. key .. ' has no sample list' end
  local by_hod = {}
  if type(data.by_hod) == 'table' then
    for name, list in pairs(data.by_hod) do
      local h = type(name) == 'string' and tonumber(name:match('^h(%d+)$'))
      local clean = h and h < 24 and clean_list(list, self.s.samples_per_hour_of_day)
      if clean then by_hod[h] = clean end
    end
  end
  if not self.reasons[key] then self.reason_count = self.reason_count + 1 end
  self.reasons[key] = { all = all, by_hod = by_hod, floor = finite(data.floor) and data.floor or 0 }
  return true
end

return M
