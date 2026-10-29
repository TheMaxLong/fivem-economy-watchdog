-- exports.economy_watchdog:record(ev): another script declares a change it made itself, such as a rent
-- script writing to the database. ev is a money notification ({ player = citizenid, money_type, action,
-- amount, reason }) or, with kind = 'item', an item one. The time is always stamped here, because the
-- engine refuses a notification without one.
local log = require('server.log')
local M = {}

function M.start(ctx)
  exports('record', function(ev)
    return log.guard('record export', function()
      if type(ev) ~= 'table' then return nil, 'record needs a table' end
      local copy = {}
      for k, v in pairs(ev) do copy[k] = v end
      copy.t = ctx.clock:now()
      if copy.reason == nil or copy.reason == '' then copy.reason = GetInvokingResource() end  -- name the script
      if copy.name == nil and copy.player ~= nil then
        -- an online character's name and in-game ID, so the alert names them like any other notification
        for _, info in pairs(ctx.known or {}) do
          if info.key == tostring(copy.player) then
            copy.name, copy.src = info.name, info.src
            break
          end
        end
      end
      local line, why = ctx.engine:record(copy)
      if not line then return nil, why end
      return true
    end)
  end)
end

return M
