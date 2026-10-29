-- Small numeric helpers shared by the learner.
local M = {}

-- sorted_of[list] = a sorted copy of that sample list, built on the first quantile and then kept in
-- step by push_capped, so a quantile is a lookup instead of a sort. The top-of-hour sweep closes
-- every player's hour, and each close reads the threshold and then pushes to the same list, so a
-- cache thrown away on every push would still sort once per close.
-- ponytail: the copy doubles the memory of every sample list the learner has read (worst case
-- 500 reasons x 2,900 samples); a streaming quantile sketch is the upgrade for thousands of reasons.
local sorted_of = setmetatable({}, { __mode = 'k' })

-- First position in sorted list s whose value is not below v.
local function lower_bound(s, v)
  local lo, hi = 1, #s + 1
  while lo < hi do
    local mid = math.floor((lo + hi) / 2)
    if s[mid] < v then lo = mid + 1 else hi = mid end
  end
  return lo
end

-- The sorted copy of list. Rebuilt if its length no longer matches, a cheap guard for a list that
-- was written directly (e.g. filled before its first look) instead of through push_capped.
local function sorted(list)
  local s = sorted_of[list]
  if not s or #s ~= #list then
    s = {}
    for i = 1, #list do s[i] = list[i] end
    table.sort(s)
    sorted_of[list] = s
  end
  return s
end

-- Value at quantile q (0..1) of a list, nearest-rank method. Nil for an empty list. Never reorders the input.
function M.quantile(list, q)
  local n = #list
  if n == 0 then return nil end
  local s = sorted(list)
  local rank = math.ceil(q * n)
  if rank < 1 then rank = 1 end
  if rank > n then rank = n end
  return s[rank]
end

-- In sorted list s, swap one copy of `old` for `new`, moving only the values between the two.
local function replace_sorted(s, old, new)
  if new == old then return end
  local i = lower_bound(s, old)  -- s[i] == old
  local j = lower_bound(s, new)
  if new > old then
    table.move(s, i + 1, j - 1, i)  -- values from old up to below new step down one place
    s[j - 1] = new
  else
    table.move(s, j, i - 1, j + 1)  -- values from new up to below old step up one place
    s[j] = new
  end
end

-- Append value, keeping only the newest `cap` values (and the sorted copy, if there is one, in step).
-- ponytail: table.remove(list, 1) is O(n); fine at cap 500, use a ring buffer if caps grow large.
function M.push_capped(list, value, cap)
  local s = sorted_of[list]
  if s and #s ~= #list then s = nil; sorted_of[list] = nil end
  list[#list + 1] = value
  if #list > cap then
    local old = table.remove(list, 1)
    if s then replace_sorted(s, old, value) end
  elseif s then
    table.insert(s, lower_bound(s, value), value)
  end
end

return M
