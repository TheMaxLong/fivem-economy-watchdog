-- Every limit the owner can change, with the defaults from the approved spec (2026-09-30).
return {
  count_every_s = 600,            -- bookkeeper counts every 10 minutes
  flush_every_s = 5,              -- ledger lines are written to the database every 5 seconds
  ledger_cap = 50000,             -- lines held in memory while the database is down
  retention_days = 30,            -- ledger lines kept this long
  learning_hours = 72,            -- alarm 2 stays quiet while the server's normal is learned
  fast_factor = 10,               -- alarm 2: above 10x the normal top
  fast_quantile = 0.99,           -- "normal top" = the level only 1 in 100 normal hours goes above
  min_samples = 50,               -- hourly totals a reason needs before alarm 2 uses it
  samples_per_reason = 500,       -- rolling hourly totals kept per reason
  samples_per_hour_of_day = 100,  -- rolling hourly totals kept per reason per hour of day
  max_reasons = 500,              -- distinct learned reasons; the rest share 'other'
  incident_window_s = 900,        -- one incident per player + reason per 15 minutes
  alerts_per_minute = 20,         -- Discord messages per rolling minute (Discord allows about 30)
  outbox_cap = 200,               -- waiting Discord messages before the rest are folded into a summary
  health_quiet_s = 1800,          -- "can I hear this server?" after 30 minutes of silence with players on
  stash_window_s = 1,             -- alarm 3: same slot paid out twice within 1 second
  refill_window_s = 1800,         -- alarm 3: withdraw-then-disconnect lookback (covers two counts)
  money_tolerance = 0,            -- alarm 1: unexplained dollars allowed per money type per count
  item_tolerance = 0,             -- alarm 1: unexplained items allowed per item per count
  label_margin = 1.5,             -- /wd legit and /wd fine allow up to 1.5x what was seen
  staff_amount = 0,               -- alarm 4: report staff-given money at or above this (0 = all)
  staff_reasons = { 'admin' },    -- alarm 4: normalised reason contains any of these
  transfer_patterns = {},         -- whole-reason patterns for money moving, not earned (set by the banking reader)
  account_patterns = {},          -- transfer patterns to or from a business/gang account; first capture = account
  pair_window_s = 5,              -- a bank record within this many seconds of a player's transfer is the same move
  -- The FiveM layer's own settings (resource/economy_watchdog/server/):
  framework = 'auto',             -- 'auto', 'qbcore' or 'qbox'
  inventory = 'auto',             -- 'auto', 'ox' (ox_inventory), 'qb' (qb-inventory) or 'none'
  banking = 'auto',               -- 'auto', 'qb-banking' or 'none' (business/gang accounts not counted)
  tick_every_s = 60,              -- housekeeping: close learned hours, sweep incidents, "can I hear this server?"
  discord_every_s = 2,            -- how often waiting Discord messages are sent
  discord_regrow_factor = 2,      -- post an incident again once it has grown to this many times its last post
  discord_retries = 3,            -- tries for a Discord message that failed for a reason other than rate limiting
  clock_drift_s = 2,              -- re-anchor the sub-second clock when it drifts this far from the system clock
}
