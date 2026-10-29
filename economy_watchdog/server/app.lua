-- Starts the watchdog and keeps it running. Everything happens in threads, so waiting for the framework
-- or the database never holds up the server:
--   1. find the framework (it may start after this resource), the item system and the bank
--   2. wait for the database, create the three wd_ tables, load what an earlier run saved
--   3. build the engine from the owner's settings, the bank's patterns and the saved state
--   4. start the listeners, the record export, the /wd commands and the Discord sender
--   5. run the timers: flush, housekeeping tick, Discord, the count (then a save), the daily trim
local Engine = require('core.engine')
local alerts = require('core.alerts')
local Clock = require('server.clock')
local Players = require('server.players')
local Money = require('server.money')
local ItemsOx = require('server.items_ox')
local ItemsQb = require('server.items_qb')
local Banking = require('server.banking')
local Store = require('server.store')
local Counter = require('server.counter')
local Discord = require('server.discord')
local Commands = require('server.commands')
local Export = require('server.export')
local log = require('server.log')
local M = {}

local FRAMEWORK_WAIT_S = 60  -- the framework may start after this resource; give it this long
local DATABASE_RETRY_S = 10  -- how often to try a database that is not answering at start
local STOPPED_AFTER = 3      -- failed counts in a row before the owner is told counting has stopped

-- The resource behind each item system, by the name onResourceStart reports.
local ITEM_RESOURCES = { ox = 'ox_inventory', qb = 'qb-inventory' }

-- Runs fn every `seconds` (read each time), protected, in its own thread.
local function every(what, seconds, fn)
  CreateThread(function()
    while true do
      Wait(math.floor(seconds() * 1000))
      log.guard(what, fn)
    end
  end)
end

-- A game event handler, protected: a failure is logged and counted in /wd status, never thrown at FiveM.
local function on(event, fn)
  AddEventHandler(event, function(...) log.guard(event, fn, ...) end)
end

-- Saves and flushes in a thread of its own (handlers can't wait for the database themselves).
local function save_soon(app)
  CreateThread(function()
    log.guard('saving', function()
      Store.flush(app)
      Store.save(app, true)
    end)
  end)
end

-- config: the owner's Config table from config.lua. Returns the app table, filled in as start-up runs;
-- app.ready is true once everything runs. A start-up that fails says so in one logged line and never sets
-- app.ready.
function M.start(config)
  local app = { config = config, layer_state = {} }
  local settings = Engine.read_settings(config)
  app.settings = settings
  app.clock = Clock.new(settings.clock_drift_s)
  Store.init(app)
  Counter.init(app)
  CreateThread(function()
    log.guard('starting', function()
      -- A bank named in the settings is waited for too: one that starts after the watchdog would otherwise go
      -- uncounted, and its account lines would be judged as earnings.
      local function bank_ready() return settings.banking ~= 'qb-banking' or Banking.detect('qb-banking') end
      local kind = Players.detect(settings.framework)
      for _ = 1, FRAMEWORK_WAIT_S do
        if kind and bank_ready() then break end
        Wait(1000)
        kind = Players.detect(settings.framework)
      end
      app.inventory = Counter.detect_inventory(settings.inventory)
      app.bank = Banking.detect(settings.banking)

      local saved, layer
      while true do
        local ok = Store.prepare(app)
        if ok then saved, layer = Store.load(app) end
        -- a failed load returns nil and why: only a loaded layer table means the saved state was read
        if ok and type(layer) == 'table' then break end
        log.say(('waiting for the database (retrying in %d s)'):format(DATABASE_RETRY_S))
        Wait(DATABASE_RETRY_S * 1000)
      end
      app.layer_state = layer

      local now = app.clock:now()
      local first = saved and saved.meta and tonumber(saved.meta.first_start) or now
      app.engine = Engine.new(Banking.settings(config, app.bank, app.inventory),
        { first_start = first, now = now, day_offset_s = Clock.utc_offset(now) }, saved)
      for _, w in ipairs(app.engine.settings_warnings) do log.say('setting: ' .. w) end

      if kind then
        app.fw = Players.new(kind)
        log.guard('starting the money listener', Money.start, app)
      else
        log.say('no QBCore or Qbox found: money changes cannot be heard')
      end
      -- Items are judged only while their changes can be heard: a reader that can't start (an older
      -- qb-inventory without AddListener, say) turns item counting off instead of raising false alarms.
      local readers = { ox = ItemsOx, qb = ItemsQb }
      local function start_reader(what)
        if log.guard(what .. ' the ' .. app.inventory .. ' item reader', readers[app.inventory].start, app) then
          return
        end
        local why = ('the %s item reader could not start (%s)'):format(app.inventory, tostring(log.last_failure))
        app.items_off = why .. ', so items are not judged'
        log.say(app.items_off)
        app.engine:notice(alerts.items_off(why))
        app.engine:forget_kind('items')  -- so counts without items aren't refused for leaving them out
        app.inventory = nil
      end
      if readers[app.inventory] then start_reader('starting') end
      Export.start(app)
      Discord.init(app)
      app.on_answer = function() save_soon(app) end
      Commands.start(app)

      every('flushing the ledger', function() return settings.flush_every_s end, function() Store.flush(app) end)
      every('housekeeping', function() return settings.tick_every_s end,
        function() app.engine:tick(app.clock:now(), #GetPlayers()) end)
      every('sending to Discord', function() return settings.discord_every_s end, function() Discord.tick(app) end)
      app.last_trim = 0
      -- A refused count, or one that throws, reaches only the console and /wd status. After STOPPED_AFTER in
      -- a row the owner is told once, and once more when a count is accepted again. The reason is the
      -- engine's or the error's, never the database's own text (which can name its host).
      app.failed_counts, app.stopped_told = 0, false
      local function watch(accepted, why)
        if accepted then
          if app.stopped_told then app.engine:notice(alerts.counting_back()) end
          app.failed_counts, app.stopped_told = 0, false
          return
        end
        app.failed_counts = app.failed_counts + 1
        if app.failed_counts >= STOPPED_AFTER and not app.stopped_told then
          app.stopped_told = true
          app.engine:notice(alerts.counting_stopped(app.failed_counts, why))
        end
      end
      local function count()
        local findings, why = log.guard('counting', Counter.count, app)
        watch(findings ~= nil, why or log.last_failure)
        Store.save(app, true)
        if app.clock:now() - app.last_trim >= 86400 then
          Store.trim(app)
          app.last_trim = app.clock:now()
        end
      end
      CreateThread(function()
        log.guard('counting', count)  -- a first baseline straight away
        while true do
          Wait(math.floor(settings.count_every_s * 1000))
          log.guard('counting', count)
        end
      end)

      on('txAdmin:events:serverShuttingDown', function() save_soon(app) end)
      on('txAdmin:events:scheduledRestart', function(ev)
        local left = type(ev) == 'table' and tonumber(ev.secondsRemaining)
        if left and left <= 60 then save_soon(app) end
      end)
      on('onResourceStop', function(res)
        if res == GetCurrentResourceName() then save_soon(app) end  -- a last attempt; it may not finish
        -- changes made while the item system is away are never heard: the next count starts afresh
        if res == ITEM_RESOURCES[app.inventory] then Counter.restart(app) end
      end)
      -- A restarted item system has forgotten the watchdog (ox rebuilds its hook table, qb-inventory its
      -- listeners), so its reader starts again with fresh queues. A restarted qb-core hands out a new core
      -- object; the one held from before no longer works.
      on('onResourceStart', function(res)
        if res == ITEM_RESOURCES[app.inventory] then
          -- the reader may wait for the item system's exports; FiveM runs each event handler in a thread of its
          -- own, so the wait holds up nothing else. A reader that can't start turns items off, as at start-up.
          Counter.restart(app)
          start_reader('restarting')
        elseif kind and res == Players.RESOURCES[kind] then
          app.fw = Players.new(kind)
          Counter.restart(app)  -- players are counted from their saved rows until they load again
        end
      end)
      app.ready = true
      log.say(('started: framework %s, items %s, business accounts %s, learning %s'):format(kind or 'none',
        app.inventory or 'not heard', app.bank or 'not counted', saved and 'resumed' or 'from scratch'))
    end)
  end)
  return app
end

return M
