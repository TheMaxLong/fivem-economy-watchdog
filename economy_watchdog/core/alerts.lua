-- Plain-words Discord text for each incident, and an outbox that keeps to Discord's pace.
-- Alerts name the character and in-game ID only: never IP addresses or account licences.
local M = {}

-- A count or ratio as whole-number text. ('%d' raises on any float without an integer
-- representation, such as 2.5 or 1e22; '%.0f' never does.)
local function whole(n)
  if type(n) ~= 'number' then return tostring(n) end
  local s = ('%.0f'):format(n)
  if s == '-0' then s = '0' end
  return s
end

function M.money(n)
  local digits = whole(math.abs(n))
  local grouped = digits:reverse():gsub('(%d%d%d)', '%1,'):reverse():gsub('^,', '')
  return (n < 0 and '-$' or '$') .. grouped
end
local money = M.money

local function who(p)
  return ('%s (ID %s)'):format(tostring(p.name or 'unknown'), tostring(p.src or '?'))
end

local function amount(n, unit, item)
  if unit == 'item' then return ('%s × %s'):format(whole(n), item) end
  return money(n)
end

local function minutes(s) return whole(s / 60) end

-- An incident's amount as its alert words it: a count of an item, or dollars.
function M.incident_amount(inc)
  local d = inc.detail or {}
  if inc.type == 'appeared' and d.kind == 'items' then return amount(inc.amount, 'item', d.key) end
  if inc.type == 'too_fast' then return amount(inc.amount, d.unit, d.reason) end
  if inc.type == 'same_slot_twice' then return amount(inc.amount, 'item', d.item) end
  return money(inc.amount)
end

function M.text(inc)
  local d = inc.detail
  if inc.type == 'appeared' then
    if d.kind == 'items' then
      local s = ('🔴 Items appeared from nowhere: %s × %s more than recorded changes explain (over %s min). Incident #%d.')
        :format(whole(inc.amount), d.key, minutes(d.window_s), inc.id)
      for _, p in ipairs(d.suspects or {}) do
        s = s .. ('\nPossible stash refill after disconnect: %s took %s from %s and left %s s later.')
          :format(who(p), d.key, p.container, whole(p.left_after_s))
      end
      return s .. ('\nIf a script adds these on purpose: /wd legit %d'):format(inc.id)
    elseif d.key == 'accounts' then
      return ("🔴 Account transfers don't add up: business and gang accounts hold %s more than the recorded deposits and withdrawals explain (over %s min). Incident #%d.\nIf a script pays accounts on purpose: /wd legit %d")
        :format(money(inc.amount), minutes(d.window_s), inc.id, inc.id)
    end
    return ('🔴 Money appeared from nowhere: %s money rose %s more than recorded changes explain (over %s min). Incident #%d.\nIf a script pays this on purpose: /wd legit %d')
      :format(d.key, money(inc.amount), minutes(d.window_s), inc.id, inc.id)
  elseif inc.type == 'too_fast' then
    return ("🟠 Earning far too fast: %s gained %s from \"%s\" this hour, %s× this server's normal top (%s). Incident #%d.\nAnswer: /wd fine %d or /wd exploit %d")
      :format(who(d), amount(inc.amount, d.unit, d.reason), d.reason, whole(inc.amount / d.normal_top),
        amount(d.normal_top, d.unit, d.reason), inc.id, inc.id, inc.id)
  elseif inc.type == 'same_slot_twice' then
    return ('🔴 Same stash slot paid out twice: %s and %s took %s from %s slot %s within %.1f s; the slot held %s. Incident #%d.')
      :format(who(d.first), who(d.second), d.item, d.container, tostring(d.slot), d.gap_s, whole(d.held), inc.id)
  elseif inc.type == 'staff_money' then
    local from = d.actor and (' from ' .. tostring(d.actor)) or ''
    return ('🟡 Staff money: %s received %s %s via a staff command ("%s")%s. Total this incident: %s. Incident #%d.')
      :format(who(d), money(d.delta), d.key, d.reason, from, money(inc.amount), inc.id)
  end
  return ('Incident #%d (%s)'):format(inc.id, tostring(inc.type))
end

function M.cant_hear(players, quiet_min)
  return ("⚪ Can't hear money changes: %s players online and no money notifications for %s minutes. This server's framework may be a modified copy the watchdog does not understand yet.")
    :format(whole(players), whole(quiet_min))
end

-- The FiveM layer's plain notices: without them a count that keeps failing, or item counting turned off,
-- shows only in the console and /wd status, and the owner believes they are covered.
function M.counting_stopped(counts, why)
  return ('⚪ Counting has stopped: the last %s counts in a row failed (last: %s). Money and items that appear from nowhere are not caught until counting works again. /wd status shows more.')
    :format(whole(counts), tostring(why))
end

function M.counting_back()
  return '⚪ Counting is back: the last count worked, so money and items that appear from nowhere are caught again.'
end

function M.items_off(why)
  return ('⚪ Item counting is off: %s. Items are not counted or judged; money still is.'):format(tostring(why))
end

function M.dropped(lost, cap)
  return ('⚪ Database unreachable: %s ledger lines were dropped because the in-memory queue was full (%s).')
    :format(whole(lost), whole(cap))
end

-- info: { total, week_ago = number|nil, top = { {reason, amount}, ... }, decreases }
function M.digest(info)
  local s = ('📊 Daily economy: total money %s'):format(money(info.total))
  if info.week_ago and info.week_ago > 0 then
    s = s .. (' (%+.0f%% vs 7 days ago)'):format((info.total - info.week_ago) / info.week_ago * 100)
  end
  if #info.top > 0 then
    local parts = {}
    for i, r in ipairs(info.top) do parts[i] = ('"%s" %s'):format(r[1], money(r[2])) end
    s = s .. '\nTop sources yesterday: ' .. table.concat(parts, ', ')
  end
  if info.decreases > 0 then
    s = s .. ('\nUnexplained decreases: %s (rent or offline scripts; never alarmed).'):format(money(info.decreases))
  end
  return s
end

local Outbox = {}
Outbox.__index = Outbox
M.Outbox = Outbox

function Outbox.new(s)
  return setmetatable({ s = s, queue = {}, sent_at = {}, folded = 0 }, Outbox)
end

-- msg: { op = 'post'|'edit', incident_id = number|nil, text, amount = the incident's running total|nil }
-- A newer text for an incident still waiting replaces the waiting text (and amount). Past outbox_cap,
-- messages are counted and folded into one summary.
function Outbox:put(msg)
  if msg.incident_id then
    for _, q in ipairs(self.queue) do
      if q.incident_id == msg.incident_id then
        q.text = msg.text
        q.amount = msg.amount
        return
      end
    end
  end
  if #self.queue >= self.s.outbox_cap then
    self.folded = self.folded + 1
    return
  end
  self.queue[#self.queue + 1] = msg
end

-- Messages allowed out now: at most alerts_per_minute in any rolling 60 s, the summary included.
function Outbox:take(t)
  local recent = {}
  for _, at in ipairs(self.sent_at) do
    if t - at < 60 then recent[#recent + 1] = at end
  end
  self.sent_at = recent
  local out = {}
  local room = self.s.alerts_per_minute - #recent
  while room > 0 and #self.queue > 0 do
    out[#out + 1] = table.remove(self.queue, 1)
    self.sent_at[#self.sent_at + 1] = t
    room = room - 1
  end
  if room > 0 and self.folded > 0 then
    out[#out + 1] = { op = 'post', text = ('… and %d more alerts were folded while Discord was busy. /wd status shows every open incident.'):format(self.folded) }
    self.sent_at[#self.sent_at + 1] = t
    self.folded = 0
  end
  return out
end

return M
