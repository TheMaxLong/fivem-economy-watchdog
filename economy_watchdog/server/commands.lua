-- The owner's commands: /wd status · /wd fine <id> · /wd exploit <id> · /wd legit <id>. Players need ACE
-- permission watchdog.admin (add_ace group.admin watchdog.admin allow); the server console always may.
local alerts = require('core.alerts')
local log = require('server.log')
local M = {}

local VERDICTS = { fine = 'legitimate: learned as normal', legit = 'legitimate: allowed from now on',
  exploit = 'an exploit: recorded' }

local function reply(src, text)
  if tonumber(src) == 0 then
    log.say(text)
  else
    TriggerClientEvent('chat:addMessage', src, { args = { 'watchdog', text } })
  end
end

-- Every line /wd status shows, in plain words.
function M.status_lines(ctx)
  local now = ctx.clock:now()
  local st = ctx.engine:status(now)
  local out = {}
  out[#out + 1] = st.learning and ('learning this server\'s normal: %d h left'):format(st.learning_left_h)
    or 'learning done'
  out[#out + 1] = ('hearing: framework %s · items %s · business accounts %s'):format(ctx.fw and ctx.fw.kind or 'NONE',
    ctx.inventory or 'not heard', ctx.bank or 'not counted')
  out[#out + 1] = ('last money change heard %d s ago · reasons learned %d · money changes refused %d%s'):format(
    math.floor(st.quiet_s), st.reasons_learned, ctx.money_refused or 0,
    ctx.last_money_refusal and (' (last: ' .. ctx.last_money_refusal .. ')') or '')
  local open = {}
  for i, inc in ipairs(st.open) do
    if i > 5 then
      open[#open + 1] = ('and %d more'):format(#st.open - 5)
      break
    end
    open[#open + 1] = ('#%d %s %s'):format(inc.id, inc.type, alerts.incident_amount(inc))
  end
  out[#out + 1] = 'open incidents: ' .. (#open > 0 and table.concat(open, ', ') or 'none')
  local db = ctx.db or {}
  out[#out + 1] = ('ledger: %d waiting, %d dropped, %d written · database failures %d%s'):format(st.queued_lines,
    st.dropped_lines, db.written or 0, db.failures or 0, db.last_failure and (' (last: ' .. db.last_failure .. ')') or '')
  local cs = ctx.count_stats or {}
  out[#out + 1] = ('counts: last took %s ms · %d refused%s · %d uncertain · %d unreadable rows'):format(
    tostring(cs.last_ms or '-'), st.refused_counts, st.last_refusal and (' (last: ' .. st.last_refusal .. ')') or '',
    st.uncertain_counts, (cs.unreadable or 0) + (db.skipped_rows or 0))
  if ctx.items_off then out[#out + 1] = ctx.items_off end
  if cs.last_failure then out[#out + 1] = 'last count left out: ' .. cs.last_failure end
  if cs.note then out[#out + 1] = 'note: ' .. cs.note end
  local d = ctx.discord
  if not d or not d.url then
    out[#out + 1] = 'Discord: not set (alerts go to the server console)'
  else
    out[#out + 1] = ('Discord: %d sent, %d dropped%s'):format(d.sent, d.dropped,
      d.last_error and (' (last error: ' .. d.last_error .. ')') or '')
  end
  if log.failures > 0 then out[#out + 1] = ('errors caught: %d (last: %s)'):format(log.failures, log.last_failure) end
  for _, w in ipairs(st.settings_warnings) do out[#out + 1] = 'setting: ' .. w end
  for _, w in ipairs(st.import_warnings) do out[#out + 1] = 'saved state: ' .. w end
  return out
end

-- ctx.on_answer is called after an answer is recorded (the app saves state then).
function M.start(ctx)
  RegisterCommand('wd', function(src, args)
    log.guard('/wd command', function()
      if tonumber(src) ~= 0 and not IsPlayerAceAllowed(src, 'watchdog.admin') then
        return reply(src, 'not allowed: needs ACE permission watchdog.admin')
      end
      local word, id = args[1], tonumber(args[2])
      if word == 'status' or word == nil then
        for _, line in ipairs(M.status_lines(ctx)) do reply(src, line) end
      elseif VERDICTS[word] then
        if not id then return reply(src, ('usage: /wd %s <incident number>'):format(word)) end
        local inc, why = ctx.engine:answer(id, word)
        if not inc then return reply(src, why) end
        local text = ('incident #%d marked %s'):format(inc.id, VERDICTS[word])
        local d = inc.detail or {}
        local labels = word == 'legit' and inc.type == 'appeared' and ctx.engine.reconcile.labels[d.kind]
        local allowed = labels and labels[d.key]
        if allowed then  -- say what the answer now allows, so a merged incident's size is seen
          local size = alerts.incident_amount({ type = 'appeared', amount = allowed, detail = d })
          text = text .. (', up to %s%s per count'):format(size, d.kind == 'money' and (' of ' .. d.key) or '')
        end
        reply(src, text)
        if ctx.on_answer then ctx.on_answer() end
      else
        reply(src, 'usage: /wd status | /wd fine <id> | /wd exploit <id> | /wd legit <id>')
      end
    end)
  end, false)
end

return M
