-- The bookkeeper's count: every money type and every item, totalled across the whole server. Live memory
-- is read first, then the database for everyone and everything not in memory, so a player logging out
-- mid-count is still counted once from memory rather than missed. A kind (money or items) with any
-- failed read is left out whole, never sent with keys missing (a missing key would read as zero).
local Store = require('server.store')
local Banking = require('server.banking')
local log = require('server.log')
local M = {}

-- Which item system runs here: the owner's setting, else whichever is started.
function M.detect_inventory(setting)
  if setting == 'ox' or setting == 'qb' then return setting end
  if setting == 'none' then return nil end
  if GetResourceState('ox_inventory') == 'started' then return 'ox' end
  if GetResourceState('qb-inventory') == 'started' then return 'qb' end
  return nil
end

local function finite(v)
  v = tonumber(v)
  if v and v == v and v ~= math.huge and v ~= -math.huge then return v end
  return nil
end

local function add(totals, key, v)
  v = finite(v)
  if v and type(key) == 'string' then totals[key] = (totals[key] or 0) + v end
end

-- ponytail: every count reads every character's money and inventory and every stash and vehicle row (a
-- full scan each count_every_s). Fine for the servers in the beta; the upgrade path is totals worked out
-- in SQL, or counting only what changed. The lab measures it on a seeded database (Plan 2B).
-- Gives the server a frame every 200 rows, so a big scan never stalls it. Only ever called after all
-- memory reads are done, so a pause can't let a change slip between two reads.
local function breathe(n)
  if n % 200 == 0 and coroutine.isyieldable() then Wait(0) end
end

-- JSON text from the database as a table, or nil (counted as an unreadable row).
local function decode(ctx, text)
  if text == nil then return {} end  -- an empty column holds nothing
  local ok, v = pcall(json.decode, text)
  if ok and type(v) == 'table' then return v end
  ctx.count_stats.unreadable = ctx.count_stats.unreadable + 1
  return nil
end

-- ox calls cash 'money'; every other account item keeps its name.
local function money_type(item)
  return item == 'money' and 'cash' or item
end

-- Adds an inventory's slots to items. Account items (cash held as an item) go to `cash` instead, or are
-- skipped when cash is nil (a player's own cash item only mirrors their cash balance). ox slots carry
-- count, qb-inventory slots carry amount.
local function add_slots(items, slots, accounts, cash)
  for _, slot in pairs(type(slots) == 'table' and slots or {}) do
    if type(slot) == 'table' and type(slot.name) == 'string' then
      local n = slot.count or slot.amount
      if accounts and accounts[slot.name] then
        if cash then add(cash, money_type(slot.name), n) end
      else
        add(items, slot.name, n)
      end
    end
  end
end

-- Money from online players (live) and offline players (the database).
local function count_money(ctx, online)
  local money, here = {}, {}
  for _, p in ipairs(online) do
    here[p.key] = true
    for k, v in pairs(p.money) do add(money, k, v) end
  end
  local rows, why = Store.run('offline_money')
  if not rows then return nil, why end
  for i, r in ipairs(rows) do
    breathe(i)
    if not here[tostring(r.citizenid)] then
      local m = decode(ctx, r.money)
      for k, v in pairs(m or {}) do add(money, k, v) end
    end
  end
  return money
end

-- Every loaded ox inventory, read before any database query. Returns { [type] = { inventories } }.
local function ox_live()
  local live = {}
  -- every type ox creates (modules/inventory/server.lua Inventory.Create callers; server.lua:216-240)
  for _, kind in ipairs({ 'player', 'stash', 'trunk', 'glovebox', 'drop', 'container', 'temp', 'dumpster',
    'policeevidence' }) do
    live[kind] = exports.ox_inventory:GetInventories(kind, true) or {}
  end
  return live
end

-- Items on an ox_inventory server (Qbox): loaded inventories from memory, the rest from the database
-- (ox saves loaded ones every 5 minutes: modules/inventory/server.lua:2463). A loaded player inventory's
-- owner is the citizenid (ox server.lua:61-62; bridge/qbx/server.lua:15). Every inventory that is not a
-- player's, trunk or glovebox is saved as a stash row under (owner or '', dbId), containers and evidence
-- lockers included (modules/inventory/server.lua:631-637, 725-756; modules/mysql/server.lua:134-136), so a
-- loaded one's row is skipped. Drops, temporary stashes and dumpsters live only in memory
-- (modules/inventory/server.lua:631-632). Returns items and the cash held as items in every inventory that
-- is not a player's.
local function count_ox(ctx, live)
  local items, cash, accounts = {}, {}, ctx.ox_accounts or { money = true }
  local here, stash_loaded, trunk_loaded, glove_loaded = {}, {}, {}, {}
  for _, inv in ipairs(live.player) do
    here[tostring(inv.owner)] = true
    add_slots(items, inv.items, accounts, nil)
  end
  for kind, list in pairs(live) do
    if kind ~= 'player' then
      for _, inv in ipairs(list) do add_slots(items, inv.items, accounts, cash) end
    end
  end
  for kind, list in pairs(live) do
    if kind ~= 'player' and kind ~= 'trunk' and kind ~= 'glovebox' then
      for _, inv in ipairs(list) do stash_loaded[tostring(inv.owner or '') .. '\0' .. tostring(inv.dbId)] = true end
    end
  end
  for _, inv in ipairs(live.trunk) do trunk_loaded[tostring(inv.dbId)] = true end
  for _, inv in ipairs(live.glovebox) do glove_loaded[tostring(inv.dbId)] = true end

  local players, why = Store.run('offline_items')
  if not players then return nil, nil, why end
  for i, r in ipairs(players) do
    breathe(i)
    if not here[tostring(r.citizenid)] then add_slots(items, decode(ctx, r.inventory), accounts, nil) end
  end
  local stashes, why2 = Store.run('ox_stashes')
  if not stashes then return nil, nil, why2 end
  for i, r in ipairs(stashes) do
    breathe(i)
    if not stash_loaded[tostring(r.owner or '') .. '\0' .. tostring(r.name)] then
      add_slots(items, decode(ctx, r.data), accounts, cash)
    end
  end
  local vehicles, why3 = Store.run('ox_vehicles')
  if not vehicles and tostring(why3):find("doesn't exist", 1, true) then
    -- no vehicles add-on (qbx_vehicles) installed: there are no owned vehicles to hold anything
    vehicles = {}
    ctx.count_stats.note = 'no player_vehicles table: vehicles hold nothing'
  end
  if not vehicles then return nil, nil, why3 end
  for i, r in ipairs(vehicles) do
    breathe(i)
    if not trunk_loaded[tostring(r.id)] then add_slots(items, decode(ctx, r.trunk), accounts, cash) end
    if not glove_loaded[tostring(r.id)] then add_slots(items, decode(ctx, r.glovebox), accounts, cash) end
  end
  return items, cash
end

-- Every qb-inventory stash, trunk and glovebox, read from qb-inventory's memory (it loads every saved one
-- at start: server/main.lua:16-29). ids: the identifiers in its table, asked for before any memory read;
-- plus those heard since start. Returns { [id] = items | false (not in memory) }.
local function qb_live(ctx, ids)
  local live = {}
  local function read(id)
    local inv = exports['qb-inventory']:GetInventory(id)
    live[id] = type(inv) == 'table' and type(inv.items) == 'table' and inv.items or false
  end
  for _, r in ipairs(ids) do read(r.identifier) end
  for id in pairs(ctx.qb_seen or {}) do
    if live[id] == nil then read(id) end
  end
  return live
end

-- Items on a qb-inventory server (QBCore): online players from the framework's memory; stashes, trunks
-- and gloveboxes from qb-inventory's memory (read first, in qb_live), else from their database row.
-- Drops are not counted (see server/items_qb.lua).
local function count_qb(ctx, online, live)
  local items = {}
  local here = {}
  for _, p in ipairs(online) do
    here[p.key] = true
    add_slots(items, p.items, nil, nil)
  end
  for _, slots in pairs(live) do
    if slots then add_slots(items, slots, nil, nil) end
  end
  local players, why = Store.run('offline_items')
  if not players then return nil, why end
  local rows, why2 = Store.run('qb_inventories')
  if not rows then return nil, why2 end
  for i, r in ipairs(rows) do
    breathe(i)
    if not live[r.identifier] then add_slots(items, decode(ctx, r.items), nil, nil) end
  end
  for i, r in ipairs(players) do
    breathe(i)
    if not here[tostring(r.citizenid)] then add_slots(items, decode(ctx, r.inventory), nil, nil) end
  end
  return items
end

-- One count's snapshot for engine:count. ctx: { clock, fw, inventory = 'ox'|'qb'|nil, bank, layer_state,
-- ox_accounts, qb_seen, count_stats, restart_next }.
function M.snapshot(ctx)
  local t = ctx.clock:now()
  ctx.count_stats.last_failure, ctx.count_stats.note = nil, nil  -- each count reports its own problems
  -- qb-inventory's identifiers come from its table first, so every memory read below happens together
  -- with no database wait in between (a wait lets players move items between two reads).
  local qb_ids, qb_why
  if ctx.inventory == 'qb' then qb_ids, qb_why = Store.run('qb_identifiers') end
  local online = ctx.fw and ctx.fw:online() or {}
  local live = ctx.inventory == 'ox' and ox_live() or qb_ids and qb_live(ctx, qb_ids) or nil
  local snap = { t = t, restarted = ctx.restart_next }
  local money, why = count_money(ctx, online)
  if not money then ctx.count_stats.last_failure = 'money: ' .. tostring(why) end
  if ctx.inventory == 'ox' then
    local items, cash, why2 = count_ox(ctx, live)
    if items then
      snap.items = items
      for k, v in pairs(cash) do if money then add(money, k, v) end end
    else
      ctx.count_stats.last_failure = 'items: ' .. tostring(why2)
      money = nil  -- the cash held in stashes is unknown, so the money total is too
    end
  elseif ctx.inventory == 'qb' then
    local items, why2 = nil, qb_why
    if live then items, why2 = count_qb(ctx, online, live) end
    if items then snap.items = items else ctx.count_stats.last_failure = 'items: ' .. tostring(why2) end
  end
  if money and ctx.bank then
    local total, why3 = Banking.read(ctx, ctx.bank)
    if total then
      money.accounts = total
    else
      ctx.count_stats.last_failure = 'accounts: ' .. tostring(why3)
      money = nil
    end
  end
  snap.money = money
  return snap
end

-- Takes a snapshot and hands it to the engine. A refused count is logged, and the next one says
-- `restarted` so the engine starts a fresh baseline instead of comparing against a broken one. How long
-- the count took (database waits included) is kept for /wd status.
function M.count(ctx)
  local started = GetGameTimer()
  local gen = ctx.restart_gen
  local snap = M.snapshot(ctx)
  ctx.count_stats.last_ms = GetGameTimer() - started
  local findings, why = ctx.engine:count(snap)
  if findings then
    ctx.restart_next = ctx.restart_gen ~= gen  -- a restart heard while this count ran still applies
  else
    ctx.restart_next = true
    log.say('count refused: ' .. tostring(why))
  end
  return findings, why
end

-- Asks for the next count to be a fresh baseline (the item system or the framework restarted). Counted, so a
-- restart heard while a count runs isn't wiped when that count finishes.
function M.restart(ctx)
  ctx.restart_next = true
  ctx.restart_gen = ctx.restart_gen + 1
end

function M.init(ctx)
  ctx.count_stats = { unreadable = 0, last_failure = nil }
  ctx.restart_next = true  -- the first count after a start is a fresh baseline
  ctx.restart_gen = 0
end

return M
