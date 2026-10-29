-- QBCore's item reader: qb-inventory. Its listeners fire *after* a change (qb-inventory@dc3d07f
-- server/functions.lua:941-957 AddListener; :785 ItemAdded; :880 ItemRemoved; server/main.lua:539 and
-- :661-665 ItemMoved, only when the move succeeded), so every call is a change that happened. Unlike ox,
-- removals are heard: they are recorded, so totals match exactly. Listeners are called with
-- (filter, payload) (server/hooks.lua:25-37).
local log = require('server.log')
local Players = require('server.players')
local M = {}

-- qb-inventory's own inventory kinds (server/hooks.lua:167-177). Stashes are 'inventory'.
local CONTAINERS = { inventory = 'stash', trunk = 'trunk', glovebox = 'glovebox' }

-- A give between two players fires one ItemRemoved and one ItemAdded with these reasons (server/main.lua:519,
-- 525). The item moves; nothing is earned.
local GIVE = { '^Item given to ID #%d+$', '^Item given from ID #%d+$' }

local function given(reason)
  if type(reason) ~= 'string' then return false end
  for _, p in ipairs(GIVE) do
    if reason:find(p) then return true end
  end
  return false
end

-- An inventory's slot, whether the slot number crossed as a number or as text.
local function slot_of(inv, slot)
  local items = type(inv) == 'table' and type(inv.items) == 'table' and inv.items or {}
  local it = items[slot] or items[tostring(slot)]
  return type(it) == 'table' and it or nil
end

-- ctx: { engine, clock, fw, known }. Adds ctx.qb_seen: the stash, trunk and glovebox identifiers heard,
-- which the count reads from qb-inventory's memory.
function M.start(ctx)
  ctx.qb_seen = ctx.qb_seen or {}

  local function player(id, kind)
    local src = kind == 'player' and tonumber(id)
    if not src then return nil end
    local info = ctx.known and ctx.known[src]
    if not info and ctx.fw then info = Players.info(ctx.fw.get(src)) end
    return info
  end

  local function seen(id, kind)
    if CONTAINERS[kind] and type(id) == 'string' then ctx.qb_seen[id] = true end
  end

  local function line(t, who, item, count, reason, extra)
    local ev = { t = t, player = who and who.key, name = who and who.name, src = who and who.src, item = item,
      count = count, reason = reason }
    for k, v in pairs(extra or {}) do ev[k] = v end
    ctx.engine:item(ev)
  end

  -- Drops are not counted (qb-inventory keeps them only in memory, with no way to read them), so an
  -- item added to or removed from a drop is skipped, and moving one in or out of a drop changes the total.
  local function added(_, p)
    if type(p) ~= 'table' or p.toType == 'drop' then return end
    seen(p.toId, p.toType)
    local item = type(p.item) == 'table' and p.item.name
    if type(item) ~= 'string' then return end
    line(ctx.clock:now(), player(p.toId, p.toType), item, tonumber(p.amount),
      p.reason or ('added by ' .. tostring(p.resource)), { counts_toward_total = true, transfer = given(p.reason) })
  end

  local function removed(_, p)
    if type(p) ~= 'table' or p.fromType == 'drop' then return end
    seen(p.fromId, p.fromType)
    local item = type(p.item) == 'table' and p.item.name
    local amount = tonumber(p.amount)
    if type(item) ~= 'string' or not amount then return end
    line(ctx.clock:now(), player(p.fromId, p.fromType), item, -amount,
      p.reason or ('removed by ' .. tostring(p.resource)), { counts_toward_total = true, transfer = given(p.reason) })
  end

  -- One item moving from one inventory to another. held = how many its source slot had before. A pickup
  -- from a drop arrives only here (a move's own RemoveItem and AddItem pass isInternalMove, so no ItemAdded
  -- fires: server/main.lua:630-657): it counts, since drops are not counted, but it moves an item that
  -- already existed, so it is never judged as earning.
  local function one(t, item, amount, from_type, from_id, from_slot, to_type, to_id, held)
    if type(item) ~= 'string' or not amount then return end
    if from_type == 'drop' and to_type ~= 'drop' then
      line(t, player(to_id, to_type), item, amount, 'picked up from a drop', { counts_toward_total = true,
        transfer = true })
    elseif to_type == 'drop' and from_type ~= 'drop' then
      line(t, player(from_id, from_type), item, -amount, 'put in a drop', { counts_toward_total = true })
    elseif CONTAINERS[from_type] and to_type == 'player' then
      line(t, player(to_id, to_type), item, amount, 'taken from ' .. CONTAINERS[from_type], {
        from_container = CONTAINERS[from_type] .. ':' .. tostring(from_id), from_slot = from_slot,
        slot_available = held, to_container = 'player:' .. tostring(to_id) })
    end
  end

  -- The payload's inventories show the slots after the move: the moved item sits in toSlot; for a swap,
  -- the other item now sits in fromSlot.
  local function moved(kind, p)
    if kind == 'given' or type(p) ~= 'table' then return end  -- a give is also an ItemRemoved plus an ItemAdded
    seen(p.fromId, p.fromType)
    seen(p.toId, p.toType)
    local t, amount = ctx.clock:now(), tonumber(p.amount)
    local landed, left = slot_of(p.toInventory, p.toSlot), slot_of(p.fromInventory, p.fromSlot)
    local item = landed and landed.name
    if kind == 'swapped' then
      one(t, item, tonumber(landed and landed.amount), p.fromType, p.fromId, p.fromSlot, p.toType, p.toId,
        tonumber(landed and landed.amount))
      one(t, left and left.name, tonumber(left and left.amount), p.toType, p.toId, p.toSlot, p.fromType, p.fromId,
        tonumber(left and left.amount))
    else
      local still = (left and left.name == item and tonumber(left.amount)) or 0
      one(t, item, amount, p.fromType, p.fromId, p.fromSlot, p.toType, p.toId, amount and amount + still)
    end
  end

  local qb = exports['qb-inventory']
  qb:AddListener('ItemAdded', function(...) log.guard('qb ItemAdded', added, ...) end)
  qb:AddListener('ItemRemoved', function(...) log.guard('qb ItemRemoved', removed, ...) end)
  qb:AddListener('ItemMoved', function(...) log.guard('qb ItemMoved', moved, ...) end)
  return true
end

return M
