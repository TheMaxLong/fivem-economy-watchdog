-- Named copying patterns and the staff-money record.
local M = {}
M.__index = M

local CONTAINERS = { stash = true, trunk = true, glovebox = true }

function M.new(s)
  return setmetatable({
    s = s,
    recent = {},       -- recent[container .. '#' .. slot] = last withdrawal from that slot
    withdrawals = {},  -- withdrawals[item] = { {t, player, name, src, container}, ... } inside refill_window_s
    dropped = {},      -- dropped[player] = time the player disconnected
  }, M)
end

local function prune(list, cutoff)
  local kept = {}
  for _, w in ipairs(list) do
    if w.t >= cutoff then kept[#kept + 1] = w end
  end
  return kept
end

-- A player took items out of a shared container (line.from_container = 'stash:<id>' etc.).
-- `available` is how many the slot held before this withdrawal, or nil if unknown.
-- Returns a finding when the same slot paid out to two different players within stash_window_s
-- and together they took more than the slot held.
function M:withdrawal(line, available)
  local c = line.from_container
  if not c or not line.player then return nil end
  if not CONTAINERS[c:match('^(%w+):') or ''] then return nil end
  local list = self.withdrawals[line.key] or {}
  list[#list + 1] = { t = line.t, player = line.player, name = line.name, src = line.src, container = c }
  self.withdrawals[line.key] = prune(list, line.t - self.s.refill_window_s)
  if line.from_slot == nil or available == nil then return nil end
  local id = c .. '#' .. tostring(line.from_slot)
  local prev = self.recent[id]
  self.recent[id] = { t = line.t, player = line.player, name = line.name, src = line.src,
    count = line.count, available = available, item = line.key }
  if prev and prev.item == line.key and prev.player ~= line.player
      and math.abs(line.t - prev.t) <= self.s.stash_window_s
      and prev.count + line.count > prev.available then
    return { item = line.key, container = c, slot = line.from_slot, held = prev.available,
      gap_s = math.abs(line.t - prev.t), first = prev,
      second = { player = line.player, name = line.name, src = line.src, count = line.count } }
  end
  return nil
end

function M:player_dropped(player, t) self.dropped[player] = t end

-- For an "items appeared from nowhere" finding: players who took this item from a container and
-- then disconnected inside the lookback (the ox_inventory stash-rollback shape).
function M:refill_suspects(item, now)
  local out = {}
  for _, w in ipairs(self.withdrawals[item] or {}) do
    local d = self.dropped[w.player]
    if d and d >= w.t and now - w.t <= self.s.refill_window_s then
      out[#out + 1] = { player = w.player, name = w.name, src = w.src, container = w.container,
        left_after_s = d - w.t }
    end
  end
  return out
end

-- Money that came from a staff command, at or above staff_amount. A record, not a guess.
function M:staff(line)
  if line.kind ~= 'money' or line.delta <= 0 or line.delta < self.s.staff_amount then return nil end
  for _, word in ipairs(self.s.staff_reasons) do
    if line.reason_key:find(word, 1, true) then return line end
  end
  return nil
end

function M:sweep(t)
  local keep = math.max(60, self.s.stash_window_s)  -- a slot's last withdrawal is needed for the whole window
  for id, r in pairs(self.recent) do
    if t - r.t > keep then self.recent[id] = nil end
  end
  for p, d in pairs(self.dropped) do
    if t - d > self.s.refill_window_s then self.dropped[p] = nil end
  end
  for item, list in pairs(self.withdrawals) do
    local kept = prune(list, t - self.s.refill_window_s)
    if #kept > 0 then self.withdrawals[item] = kept else self.withdrawals[item] = nil end
  end
end

return M
