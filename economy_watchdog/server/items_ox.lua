-- Qbox's item reader: ox_inventory. ox calls a hook *before* a change, and the change can still fail
-- after every hook said yes (ox_inventory@172b391 modules/inventory/server.lua:1660, 1826, 1835, 1862,
-- 1885). About 50 ms later it fires each hook's id as an event, with whether the change happened
-- (modules/hooks/server.lua:34-55). So the hook notes what it needs from before the change, always says
-- yes, and the post-event records the change only if it happened.
-- ponytail: post-events are matched to hook calls first in, first out. That holds because ox fires
-- exactly one post-event per hook that ran, in order, on one fixed 50 ms timer; if ox ever reorders them
-- the notes misalign. Upgrade path: match on inventory, slot and count.
-- There is no hook for removals, so item decreases are never judged (the core already ignores them).
local log = require('server.log')
local Players = require('server.players')
local M = {}

local CONTAINERS = { stash = true, trunk = true, glovebox = true }

-- The count reads ox's loaded inventories through GetInventories. ox_inventory added that export after its
-- v2.47.9 release (overextended/ox_inventory 172b391; found in the box 1 lab). ox registers it while its own
-- scripts load (modules/bridge/server.lua:53 → modules/inventory/server.lua:276), so the reader waits for it
-- only when ox starts after the watchdog. Without it, items are not judged at all: counting stashes from their
-- saved rows, up to five minutes stale, would raise false "Items appeared" alarms.
local READY_WAIT_S = 60

local function inventories_readable()
  return (pcall(function() return exports.ox_inventory:GetInventories('player', false) end))
end

-- Resources whose cash items in a player's inventory are already judged or are not earnings.
-- ponytail: cash these three create is never judged here. qbx_core's own creations are mostly the echo of a
-- money change already judged through OnMoneyChange (qbx_core server/player.lua:1300), and ox's are moves, gives
-- and the login sync (bridge/qbx/server.lua:23). After a database wait inside ox, ox names oxmysql instead of
-- the caller (found in the lab), and the login sync runs right after one (bridge/qbx/server.lua:14-25). That
-- also skips cash paid through qbx_core's deprecated Player.Functions.AddItem('cash', n) (server/player.lua:
-- 896-898), through ox's own /additem or a crafting recipe that makes cash, and a payment made just after ox
-- waited on the database. Upgrade path: tell qbx_core's echo apart by the OnMoneyChange heard in the same call.
local NOT_EARNED = { qbx_core = true, ox_inventory = true, oxmysql = true }

-- ox calls cash 'money'; every other account item keeps its name (qbx_core server/player.lua toOxAccountName).
local function money_type(item)
  return item == 'money' and 'cash' or item
end

-- The item names that are money, not items: the server's inventory:accounts setting (ox init.lua:78).
function M.accounts()
  local ok, list = pcall(json.decode, GetConvar('inventory:accounts', '["money"]'))
  if not ok or type(list) ~= 'table' or #list == 0 then list = { 'money' } end
  local set = {}
  for _, name in ipairs(list) do
    if type(name) == 'string' then set[name] = true end
  end
  return set
end

-- ctx: { engine, clock, fw, known } (known comes from the money listener). Adds ctx.ox_accounts, and
-- ctx.ox_handlers, the post-event handlers. Called again when ox_inventory restarts: ox then numbers hook
-- ids afresh (modules/hooks/server.lua:118-148), so the new ids are the old ones, and a handler from the
-- last start would also hear the new post-events with notes left from before the restart. They are removed
-- first.
function M.start(ctx)
  ctx.ox_start = (ctx.ox_start or 0) + 1
  local mine = ctx.ox_start  -- two quick ox restarts: only the newer start registers hooks
  for _ = 1, READY_WAIT_S do
    if inventories_readable() or ctx.ox_start ~= mine then break end
    Wait(1000)
  end
  if ctx.ox_start ~= mine then return true end
  if not inventories_readable() then
    error('this ox_inventory has no GetInventories export (it came after v2.47.9): update ox_inventory', 0)
  end
  for _, h in ipairs(ctx.ox_handlers or {}) do RemoveEventHandler(h) end
  ctx.ox_handlers = {}
  local accounts = M.accounts()
  ctx.ox_accounts = accounts

  -- The player behind an ox player inventory (its id is the in-game ID), or nil.
  local function player(inv_id)
    if type(inv_id) ~= 'number' then return nil end
    local info = ctx.known and ctx.known[inv_id]
    if not info and ctx.fw then info = Players.info(ctx.fw.get(inv_id)) end
    return info
  end

  -- One item moving between two inventories. Totals don't change, except for cash held as an item:
  -- cash in a player's own inventory is their cash balance (the framework announces that side), so
  -- cash moving to or from a stash, trunk, glovebox or drop records the container's side here.
  local function move(t, item, count, from_id, from_type, to_id, to_type, slot, held)
    if type(item) ~= 'string' or not tonumber(count) then return end
    count = tonumber(count)
    if accounts[item] then
      local from_player, to_player = from_type == 'player', to_type == 'player'
      if from_player and not to_player then
        ctx.engine:container_cash({ t = t, money_type = money_type(item), delta = count })
      elseif to_player and not from_player then
        ctx.engine:container_cash({ t = t, money_type = money_type(item), delta = -count })
      end
      return
    end
    if CONTAINERS[from_type] and to_type == 'player' then
      local p = player(to_id)
      ctx.engine:item({ t = t, player = p and p.key, name = p and p.name, src = p and p.src, item = item,
        count = count, reason = 'taken from ' .. from_type, from_container = from_type .. ':' .. tostring(from_id),
        from_slot = slot, slot_available = held, to_container = 'player:' .. tostring(to_id) })
    end
  end

  -- A give runs the swapItems hooks with action 'give', then AddItem for the receiver, which runs the
  -- createItem hooks, all inside one call (modules/inventory/server.lua:2550-2563; modules/items/server.lua:
  -- 224-230). The item moves between two players and no hook hears the giver's side, so the receiver's
  -- creation is not recorded at all: the totals don't change. Count is not matched, because the creation's
  -- count is cut to 1 for containers and items that don't stack (modules/items/server.lua:197, 220-222).
  -- ponytail: a give is matched to its creation by item and receiving inventory within one call (and, for cash
  -- and other account items, which stack and are never split, by count too). ox runs the give's swapItems hooks,
  -- then AddItem and its createItem hooks, with no wait between them (modules/inventory/server.lua:2550-2563),
  -- and AddItem asks for the item's metadata once per slot it fills (:1168, :1177, :1195). So every creation of
  -- that item in that inventory before this resource's next tick belongs to the give. GetGameTimer can't mark
  -- the call: on FXServer it is wall-clock milliseconds, which move on mid-call. Ceilings:
  --   another script's creation of that item into that inventory in the same frame is taken for the give and
  --   goes unrecorded (an item then shows as appearing; cash of the same count goes unjudged);
  --   if another resource's hook waits during the give, this resource can tick first, and the give's creation
  --   is then recorded and judged as the receiver's gain.
  -- Upgrade path: hear the giver's removal too, if ox ever adds a removal hook.
  local give  -- { item, inv, count }: the give whose creation is still expected, until this resource's next tick

  -- What a swap looked like before it happened (the post-event's copy shows the slots afterwards).
  local function note_swap(p)
    local from = type(p.fromSlot) == 'table' and p.fromSlot or {}
    local to = type(p.toSlot) == 'table' and p.toSlot or {}
    if p.action == 'give' then
      local this = { item = from.name, inv = p.toInventory, count = tonumber(p.count) }
      give = this
      SetTimeout(0, function() if give == this then give = nil end end)  -- runs on this resource's next tick
    end
    return { t = ctx.clock:now(), action = p.action, count = p.count,
      from_id = p.fromInventory, from_type = p.fromType, from_name = from.name, from_slot = from.slot, held = from.count,
      to_id = p.toInventory, to_type = p.toType, to_name = to.name, to_slot = to.slot, to_held = to.count }
  end

  local function swapped(n)
    -- a swap moves whole slots (modules/inventory/server.lua:1852, 1864), whatever count was dragged
    local count = n.action == 'swap' and n.held or n.count
    move(n.t, n.from_name, count, n.from_id, n.from_type, n.to_id, n.to_type, n.from_slot, n.held)
    if n.action == 'swap' and n.to_name then  -- the other slot's item went the other way
      move(n.t, n.to_name, n.to_held, n.to_id, n.to_type, n.from_id, n.from_type, n.to_slot, n.to_held)
    end
  end

  local function note_create(p)
    local item = type(p.item) == 'table' and p.item.name or p.item
    if give and give.item == item and give.inv == p.inventoryId
        and (not accounts[item] or tonumber(p.count) == give.count) then
      return { given = true }  -- still queued, so the next post-event meets its own note
    end
    return { t = ctx.clock:now(), item = item, count = p.count, inv = p.inventoryId, resource = p.resource }
  end

  -- An item created in an inventory: the only way ox items enter the economy. Shop purchases and crafting
  -- create theirs through the same call (shops/server.lua:246, inventory/server.lua:1168), so each counts
  -- once. Its post-event's yes means "the hooks agreed", not "the item was placed": an add that then fails
  -- (a full inventory) is over-explained, which is the quiet direction.
  local function created(n)
    if n.given or type(n.item) ~= 'string' then return end
    local count = tonumber(n.count) or 1
    if accounts[n.item] then
      if type(n.inv) ~= 'number' then
        ctx.engine:container_cash({ t = n.t, money_type = money_type(n.item), delta = count })
      elseif not NOT_EARNED[n.resource] then
        -- Cash a script paid straight into a player's inventory. Qbox's bridge then records it as a 'Sync
        -- cash with inventory' set, a transfer that is never judged, so it is judged here by who paid it.
        local p = player(n.inv)
        ctx.engine:earned({ t = n.t, player = p and p.key, name = p and p.name, src = p and p.src,
          money_type = money_type(n.item), amount = count, reason = 'created by ' .. tostring(n.resource or 'unknown') })
      end
      return
    end
    local p = player(n.inv)
    ctx.engine:item({ t = n.t, player = p and p.key, name = p and p.name, src = p and p.src, item = n.item,
      count = count, reason = 'created by ' .. tostring(n.resource or 'unknown'), counts_toward_total = true })
  end

  local function hook(event, note, record)
    local queue = {}
    local id = exports.ox_inventory:registerHook(event, function(payload)
      queue[#queue + 1] = log.guard('ox ' .. event .. ' hook', note, payload) or false
      return true  -- never refuse: the watchdog only watches
    end)
    ctx.ox_handlers[#ctx.ox_handlers + 1] = AddEventHandler(id, function(success, _)
      local n = table.remove(queue, 1)
      if success and n then log.guard('ox ' .. event, record, n) end
    end)
  end

  hook('swapItems', note_swap, swapped)
  hook('createItem', note_create, created)
  return true
end

return M
