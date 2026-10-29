-- The framework adapter: QBCore or Qbox. Both keep the same PlayerData (citizenid, source, charinfo,
-- money) and expose the same lookups: qb-core@9b3cddc server/functions.lua:46 GetPlayer, :126
-- GetQBPlayers; qbx_core@1825a3c server/functions.lua:94 and :147 export the same two.
local M = {}
M.__index = M

-- Each framework's resource, by its own name (qbx_core's provide 'qb-core' does not change the name
-- onResourceStart reports).
M.RESOURCES = { qbcore = 'qb-core', qbox = 'qbx_core' }

-- Which framework runs here: the owner's setting once its resource has started (until then nil, so the
-- start-up wait covers a framework that starts late), else whichever is started. Qbox comes first because
-- qbx_core also answers to the name qb-core (qbx_core fxmanifest.lua:72 provide 'qb-core').
function M.detect(setting)
  if M.RESOURCES[setting] then
    return GetResourceState(M.RESOURCES[setting]) == 'started' and setting or nil
  end
  if GetResourceState('qbx_core') == 'started' then return 'qbox' end
  if GetResourceState('qb-core') == 'started' then return 'qbcore' end
  return nil
end

function M.new(kind)
  local fw = setmetatable({ kind = kind }, M)
  if kind == 'qbcore' then
    local core = exports['qb-core']:GetCoreObject()
    fw.all = function() return core.Functions.GetQBPlayers() end
    fw.get = function(src) return core.Functions.GetPlayer(src) end
  elseif kind == 'qbox' then
    fw.all = function() return exports.qbx_core:GetQBPlayers() end
    fw.get = function(src) return exports.qbx_core:GetPlayer(src) end
  else
    error(('unknown framework %s'):format(tostring(kind)), 2)
  end
  return fw
end

-- What the watchdog needs from a framework player object, or nil if it isn't one:
-- { key = citizenid, name = 'First Last', src = in-game ID, money = { cash = .., bank = .., ... },
--   items = the player's inventory as the framework holds it (qb-inventory keeps it in PlayerData.items) }.
-- Alerts name the character and in-game ID only, never a licence.
function M.info(player)
  local pd = type(player) == 'table' and player.PlayerData
  if type(pd) ~= 'table' or pd.citizenid == nil then return nil end
  local ci = type(pd.charinfo) == 'table' and pd.charinfo or {}
  local name = (tostring(ci.firstname or '') .. ' ' .. tostring(ci.lastname or '')):match('^%s*(.-)%s*$')
  return { key = tostring(pd.citizenid), name = name ~= '' and name or ('ID ' .. tostring(pd.source)),
    src = tonumber(pd.source), money = type(pd.money) == 'table' and pd.money or {},
    items = type(pd.items) == 'table' and pd.items or {} }
end

-- Every online player's info, read from the framework's live memory.
function M:online()
  local out = {}
  for _, player in pairs(self.all() or {}) do
    local info = M.info(player)
    if info then out[#out + 1] = info end
  end
  table.sort(out, function(a, b) return a.key < b.key end)
  return out
end

return M
