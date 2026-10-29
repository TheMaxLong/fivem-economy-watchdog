-- Turns framework notifications into ledger lines, tracks balances, and holds lines until the
-- database confirms them. Also sums what was recorded since the last bookkeeper count.
local M = {}
M.__index = M

-- One key per kind of earning: lower case, digit runs collapsed to '#', at most 64 characters.
function M.reason_key(reason)
  local r = tostring(reason or 'unknown'):lower():gsub('%d+', '#'):gsub('^%s+', ''):gsub('%s+$', '')
  if r == '' then r = 'unknown' end
  return r:sub(1, 64)
end
local reason_key = M.reason_key

function M.new(cap)
  return setmetatable({
    cap = cap, buf = {}, head = 1, tail = 0, dropped = 0,
    balances = {},       -- balances[player][money_type] = last known amount
    unseeded = {},       -- unseeded[money_type] = true: a 'set' with no known prior balance since the last count
    window = { money = {}, items = {} },  -- recorded changes since the last count
  }, M)
end

function M:size() return self.tail - self.head + 1 end

function M:append(line)
  if self:size() >= self.cap then
    self.buf[self.head] = nil
    self.head = self.head + 1
    self.dropped = self.dropped + 1
  end
  self.tail = self.tail + 1
  self.buf[self.tail] = line
end

-- Up to n oldest lines and the index of the first; they stay queued until commit confirms them.
function M:peek(n)
  local out = {}
  local last = math.min(self.tail, self.head + n - 1)
  for i = self.head, last do out[#out + 1] = self.buf[i] end
  return out, self.head
end

-- Forget lines first .. first + count - 1 once the database has them. Safe if lines were
-- dropped in between: only lines still queued are removed.
function M:commit(first, count)
  local last = first + count - 1
  for i = math.max(self.head, first), last do self.buf[i] = nil end
  if last + 1 > self.head then self.head = last + 1 end
end

function M:seed(player, balances)
  local b = {}
  for k, v in pairs(balances or {}) do
    if type(v) == 'number' then b[k] = v end
  end
  self.balances[player] = b
end

function M:forget(player) self.balances[player] = nil end

-- Adds a recorded change to the current window without a ledger line (used for account transfers).
function M:note(kind, key, delta)
  local w = self.window[kind]
  w[key] = (w[key] or 0) + delta
end

-- ev: { t, player, name, src, money_type, action = 'add'|'remove'|'set', amount, reason, difference?, actor? }
-- Returns the ledger line, or nil and why. Never errors on junk input.
function M:money(ev)
  if type(ev) ~= 'table' or ev.player == nil or ev.money_type == nil then
    return nil, 'missing player or money type'
  end
  local amount = tonumber(ev.amount)
  if not amount then return nil, 'amount is not a number' end
  local bal = self.balances[ev.player]  -- created only when there is a balance to store (see below)
  local prior = bal and bal[ev.money_type]
  local delta
  if ev.action == 'add' then
    delta = amount
  elseif ev.action == 'remove' then
    delta = -amount
  elseif ev.action == 'set' then
    if tonumber(ev.difference) then
      delta = tonumber(ev.difference)
    elseif prior then
      delta = amount - prior
    else
      delta = 0
      self.unseeded[ev.money_type] = true
    end
  else
    return nil, 'unknown action'
  end
  if ev.action == 'set' then
    if not bal then
      bal = {}
      self.balances[ev.player] = bal
    end
    bal[ev.money_type] = amount
  elseif prior then
    bal[ev.money_type] = prior + delta
  end
  local line = { t = tonumber(ev.t) or 0, kind = 'money', player = ev.player, name = ev.name, src = ev.src,
    key = ev.money_type, delta = delta, reason = tostring(ev.reason or 'unknown'),
    reason_key = reason_key(ev.reason), actor = ev.actor }
  self:note('money', ev.money_type, delta)
  self:append(line)
  return line
end

-- ev: { t, player?, name?, src?, item, count, reason, counts_toward_total, from_container?, from_slot?, to_container? }
-- Only lines with counts_toward_total change the recorded item totals; moves between inventories do not.
function M:item(ev)
  if type(ev) ~= 'table' or ev.item == nil then return nil, 'missing item' end
  local count = tonumber(ev.count)
  if not count then return nil, 'count is not a number' end
  local delta = 0
  if ev.counts_toward_total then delta = count end
  local line = { t = tonumber(ev.t) or 0, kind = 'item', player = ev.player, name = ev.name, src = ev.src,
    key = ev.item, delta = delta, count = count, reason = tostring(ev.reason or 'unknown'),
    reason_key = reason_key(ev.reason), from_container = ev.from_container, from_slot = ev.from_slot,
    to_container = ev.to_container }
  if delta ~= 0 then self:note('items', ev.item, delta) end
  self:append(line)
  return line
end

-- What was recorded since the last count, and the set of money types that had a 'set' line with
-- no known prior balance (empty when there were none). Starts a fresh window.
function M:take_window()
  local w, unseeded = self.window, self.unseeded
  self.window = { money = {}, items = {} }
  self.unseeded = {}
  return w, unseeded
end

return M
