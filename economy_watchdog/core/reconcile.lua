-- The bookkeeper's judgement: did the totals change by exactly what the ledger recorded?
-- A gap must hold across two counts in a row, so money moving mid-count never looks like a gap.
local M = {}
M.__index = M

function M.new(s)
  return setmetatable({
    s = s,
    prev = nil,                          -- last snapshot
    pending = { money = {}, items = {} },  -- pending[kind][key] = { gap, dt } seen once, awaiting a second count
    labels = { money = {}, items = {} },   -- owner said legit: unexplained increases up to this per count are fine
    decreases = 0,                       -- unexplained money decreases (rent/offline scripts): digest only
    uncertain = 0,                       -- counts where some money type could not be judged (unseeded 'set' lines)
  }, M)
end

-- skip: keys that cannot be judged this count; their held gaps are dropped too.
function M:judge(kind, now, before, recorded, tolerance, dt, findings, skip)
  local keys = {}
  for k in pairs(now) do keys[k] = true end
  for k in pairs(before) do keys[k] = true end
  local pending, labels = self.pending[kind], self.labels[kind]
  for k in pairs(keys) do
    local gap = ((now[k] or 0) - (before[k] or 0)) - (recorded[k] or 0)
    local allowed = tolerance + (labels[k] or 0)
    local held = pending[k]
    pending[k] = nil
    if skip[k] then
      -- this key's change is unknown this count: it is neither judged nor held
    elseif held then
      -- settled against the previous count: a move caught mid-count cancels out in either order
      local total = held.gap + gap
      if total > allowed * 2 then
        -- gap is the two-count total; peak is the larger single count, which a label is sized from
        findings[#findings + 1] = { kind = kind, key = k, gap = total, peak = math.max(held.gap, gap),
          window_s = held.dt + dt }
      elseif total < 0 and kind == 'money' then
        self.decreases = self.decreases - total
      end
    elseif gap > allowed or (gap < 0 and kind == 'money') then  -- item decreases are ordinary use (no removal hook) and are never held
      pending[k] = { gap = gap, dt = dt }
    end
  end
end

-- snap: { t, money = { [type] = total, accounts = total? }, items = { [name] = total }, restarted = bool }
-- window: what the ledger recorded since the last count.
-- unseeded: set of money types with a 'set' line of unknown prior balance this window. Only those
-- types are skipped (and their held gaps dropped), since that line's change is unknown; the rest
-- are judged as usual.
-- Returns findings: { kind = 'money'|'items', key, gap (both counts), peak (larger single count), window_s }.
-- A kind (money or items) is judged only when this count and the last one both carry it; a kind
-- carried for the first time is a baseline. Inside a carried kind a missing key means ZERO: a key
-- the last count had and this one lacks is judged as falling to zero, and a key this count adds is
-- judged as rising from zero. So the bookkeeper must report every key it counted, and when a query
-- fails it leaves out the whole kind, never single keys; the engine refuses a count that leaves out a
-- kind the last count carried. Keys in neither count (e.g. 'accounts' on a server where accounts are
-- not counted) are never judged.
-- Item decreases are never judged: ox_inventory has no hook for item removal.
function M:count(snap, window, unseeded)
  local findings = {}
  if not self.prev or snap.restarted then
    self.prev = snap
    self.pending = { money = {}, items = {} }
    return findings
  end
  local prev = self.prev
  local dt = snap.t - prev.t
  unseeded = unseeded or {}
  if not (snap.money and prev.money) then
    self.pending.money = {}
  else
    if next(unseeded) ~= nil then self.uncertain = self.uncertain + 1 end
    self:judge('money', snap.money, prev.money, window.money or {}, self.s.money_tolerance, dt, findings, unseeded)
  end
  if snap.items and prev.items then
    self:judge('items', snap.items, prev.items, window.items or {}, self.s.item_tolerance, dt, findings, {})
  else
    self.pending.items = {}
  end
  self.prev = snap
  return findings
end

-- The owner said this gap is legitimate (e.g. a rent script writing to the database). `gap` is the
-- finding's peak: the larger single-count gap, since the allowance is applied per count.
-- ponytail: a label allows up to 1.5x that gap on the key every count, so a copy smaller than a
-- labelled script's payment hides under it; per-script attribution needs the script to call record().
function M:label(kind, key, gap)
  local want = gap * self.s.label_margin
  if want > (self.labels[kind][key] or 0) then self.labels[kind][key] = want end
end

return M
