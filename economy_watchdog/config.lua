-- The owner's settings. Anything left out uses its default from core/defaults.lua, where every setting
-- is explained. A value of the wrong type or out of range is ignored, and /wd status says so.
--
-- The Discord webhook is NOT set here. Put this line in server.cfg instead:
--   set wd_webhook "https://discord.com/api/webhooks/..."
-- Use `set`, never `setr`: setr would send the webhook address to every player's game.
--
-- Staff money: give admin ACE permission to see and answer alerts in game:
--   add_ace group.admin watchdog.admin allow
Config = {
  -- framework = 'auto',            -- 'qbcore' or 'qbox' to skip detection
  -- banking = 'auto',              -- 'qb-banking' or 'none'. With 'auto', start qb-banking before this resource in
  --                                -- server.cfg (or name it here, which waits for it): a bank found too late is not
  --                                -- counted, and its account lines would be judged as earnings
  -- staff_reasons = { 'admin' },   -- add your own admin tool's reason words here
  -- staff_amount = 0,              -- report staff-given money at or above this amount
  -- pair_window_s = 5,             -- seconds between a player's account transfer and the bank's record of it (the database's clock); raise it if the database runs on another machine whose clock is off
}
