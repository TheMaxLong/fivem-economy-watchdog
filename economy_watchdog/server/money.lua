-- Hears every money change the framework announces and hands it to the engine, stamped with the time.
-- Both QBCore and Qbox fire QBCore:Server:OnMoneyChange(source, moneyType, amount, action, reason)
-- (qb-core@9b3cddc server/player.lua:204, 237, 261; qbx_core@1825a3c server/player.lua:1291), and for a
-- 'set' both pass the new balance, so the engine works out the change from the last known balance.
-- Neither announces a change to an offline player: only the count can see those.
local log = require('server.log')
local Players = require('server.players')
local M = {}

-- ctx: { engine, clock, fw }. Adds ctx.known (in-game ID -> player info) and ctx.money_refused.
function M.start(ctx)
  local known = {}
  ctx.known = known
  ctx.money_refused = 0

  local function remember(player)
    local info = Players.info(player)
    if info and info.src then known[info.src] = info end
    return info
  end

  -- A character loading is authoritative: a different character already cached on the same in-game ID means
  -- its unload was missed, so that character has left.
  local function loaded(player)
    local info = Players.info(player)
    if not info then return end
    local before = info.src and known[info.src]
    if before and before.key ~= info.key then ctx.engine:player_dropped(before.key, ctx.clock:now()) end
    if info.src then known[info.src] = info end
    ctx.engine:player_loaded(info.key, info.money)
  end

  local function gone(src)
    local info = known[tonumber(src)]
    if not info then return end
    known[info.src] = nil
    ctx.engine:player_dropped(info.key, ctx.clock:now())
  end

  local function changed(src, money_type, amount, action, reason)
    src = tonumber(src)
    local info = src and (known[src] or remember(ctx.fw.get(src)))
    if not info then
      ctx.money_refused = ctx.money_refused + 1
      return
    end
    local ok, why = ctx.engine:money({ t = ctx.clock:now(), player = info.key, name = info.name, src = info.src,
      money_type = money_type, action = action, amount = amount, reason = reason })
    if not ok then
      ctx.money_refused = ctx.money_refused + 1
      ctx.last_money_refusal = why
    end
  end

  -- Players already online when the resource starts are seeded first, so their next 'set' has a
  -- known starting balance.
  for _, player in pairs(ctx.fw.all() or {}) do log.guard('seeding a player', loaded, player) end
  AddEventHandler('QBCore:Server:PlayerLoaded', function(player) log.guard('player loaded', loaded, player) end)
  AddEventHandler('QBCore:Server:OnPlayerUnload', function(src) log.guard('player unloaded', gone, src) end)
  AddEventHandler('playerDropped', function() log.guard('player dropped', gone, source) end)
  AddEventHandler('QBCore:Server:OnMoneyChange', function(...) log.guard('money change', changed, ...) end)
end

return M
