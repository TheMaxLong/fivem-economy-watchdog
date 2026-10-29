-- The Discord sender. Every discord_every_s it sends the engine's waiting messages to the owner's
-- webhook, one at a time and in order: a new incident is posted and its message id kept, a grown one is
-- edited, and one that has grown to discord_regrow_factor times its last post is posted again, because
-- Discord edits notify nobody. No message can ping anyone, and none passes Discord's 2,000 characters.
-- The webhook comes from the server's own settings (set wd_webhook "..." in server.cfg), never a file.
local log = require('server.log')
local M = {}

local LIMIT = 2000  -- Discord counts characters; staying under 2,000 bytes keeps under 2,000 characters
local HEADERS = { ['Content-Type'] = 'application/json' }
local NO_REPLY_S = 90  -- a request with no reply by then is given up as an outage and sent again

-- text cut to fit one Discord message, never inside a character.
function M.fit(text)
  text = tostring(text)
  if #text <= LIMIT then return text end
  local cut = text:sub(1, LIMIT - 3)
  while not utf8.len(cut) do cut = cut:sub(1, -2) end
  return cut .. '…'
end

-- The request body. allowed_mentions is written out by hand so it is always an empty list, whatever a
-- JSON encoder does with an empty table: a player named "@everyone" must never ping anyone.
local function body(text)
  return '{"content":' .. json.encode(M.fit(text)) .. ',"allowed_mentions":{"parse":[]}}'
end

-- A webhook address the sender will use: https anywhere, plain http only on this machine (the lab's
-- stand-in Discord).
function M.usable(url)
  if type(url) ~= 'string' then return false end
  return url:match('^https://[%w%.%-]+/') ~= nil or url:match('^http://127%.0%.0%.1:%d+/') ~= nil
end

-- The address for a post (no id) or for an edit of message id. The owner's webhook may end in a slash or
-- carry a query (?thread_id=… posts into a forum thread): the path goes before the query, which rides
-- along on edits too, and wait=true joins it.
function M.address(url, id)
  local path, query = url:match('^([^?]*)%??(.*)$')
  path = path:gsub('/$', '')
  if id then return path .. '/messages/' .. id .. (query ~= '' and ('?' .. query) or '') end
  return path .. '?' .. (query ~= '' and (query .. '&') or '') .. 'wait=true'
end

function M.init(ctx)
  local url = GetConvar('wd_webhook', '')
  local d = { url = M.usable(url) and url or nil, ids = {}, posted = {}, queue = {}, busy = false,
    seq = 0, sent_at = 0, retry_at = 0, tries = 0, outage = 0, sent = 0, dropped = 0, last_error = nil }
  if url ~= '' and not d.url then log.say('wd_webhook is not an https address; alerts go to the console only') end
  ctx.discord = d
  return d
end

-- How long Discord asked us to wait, from a 429 reply's JSON. FiveM drops reply headers on non-200
-- replies and may pass the body as the fourth callback value instead, so both are tried.
local function retry_after(text, err)
  for i = 1, 2 do
    local s = i == 1 and text or err
    if type(s) == 'string' then
      local ok, v = pcall(json.decode, s:match('{.*}') or s)
      if ok and type(v) == 'table' and tonumber(v.retry_after) then return tonumber(v.retry_after) end
    end
  end
  return 2
end

-- Sends the message at the head of the queue. Returns at once; the reply finishes it.
local function send(ctx, m)
  local d = ctx.discord
  local id = m.incident_id and d.ids[m.incident_id]
  local grown = id and m.amount and d.posted[m.incident_id]
    and m.amount >= d.posted[m.incident_id] * ctx.settings.discord_regrow_factor
  local edit = m.op == 'edit' and id and not grown
  local url = M.address(d.url, edit and id or nil)
  d.seq = d.seq + 1
  local seq = d.seq
  d.busy, d.sent_at = true, ctx.clock:now()
  PerformHttpRequest(url, function(status, text, _, err)
    log.guard('Discord reply', function()
      if seq ~= d.seq then return end  -- the reply to a request given up on and already sent again
      d.busy = false
      local now = ctx.clock:now()
      local code = tonumber(status) or 0  -- 0 or nothing: no connection was made
      if code >= 200 and code < 300 then
        if not edit and m.incident_id then
          local ok, v = pcall(json.decode, text or '')
          if ok and type(v) == 'table' and v.id then d.ids[m.incident_id] = tostring(v.id) end
          d.posted[m.incident_id] = m.amount
        end
        table.remove(d.queue, 1)
        d.tries, d.outage, d.sent = 0, 0, d.sent + 1
      elseif code == 429 then
        d.retry_at = now + retry_after(text, err)
      elseif code == 404 and edit then
        d.ids[m.incident_id] = nil  -- the message was deleted: post it again
      elseif code ~= 0 and code < 500 then
        -- Discord refused the message itself (a revoked webhook, a bad request), or the address answered
        -- with something that is not Discord (a redirect): retrying can't help forever
        d.tries = d.tries + 1
        d.last_error = ('HTTP %s'):format(tostring(status))
        if d.tries > ctx.settings.discord_retries then
          table.remove(d.queue, 1)
          d.tries, d.dropped = 0, d.dropped + 1
          log.say('Discord message dropped after ' .. d.last_error)
        else
          d.retry_at = now + 2 ^ d.tries
        end
      else
        -- Discord or the network is down: keep the message and try again, at most a minute apart
        d.outage = (d.outage or 0) + 1
        d.last_error = ('HTTP %s'):format(tostring(status))
        d.retry_at = now + math.min(60, 2 ^ math.min(d.outage, 6))
      end
    end)
  end, edit and 'PATCH' or 'POST', body(m.text), HEADERS)
end

-- One round: take the engine's messages when the queue is empty, then send the next one if Discord is
-- free. Without a webhook every message goes to the server console instead.
function M.tick(ctx)
  local d, now = ctx.discord, ctx.clock:now()
  if #d.queue == 0 then
    for _, m in ipairs(ctx.engine:take_alerts(now) or {}) do d.queue[#d.queue + 1] = m end
  end
  if not d.url then
    for _, m in ipairs(d.queue) do log.say('alert: ' .. m.text) end
    d.queue = {}
    return
  end
  if d.busy and now - d.sent_at >= NO_REPLY_S then
    -- no reply came back, or the request never left: an outage like any other, so the message is sent again
    d.busy = false
    d.outage = d.outage + 1
    d.last_error = 'no reply'
  end
  if d.busy or now < d.retry_at or #d.queue == 0 then return end
  send(ctx, d.queue[1])
end

return M
