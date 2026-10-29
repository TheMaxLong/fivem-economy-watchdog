-- Every SQL statement the watchdog runs, by name. No other file in the resource holds SQL (a test
-- enforces it), so a reviewer can read every query here. It writes only to its own three wd_ tables; the
-- rest only read. The box 1 lab runs each statement against a real MariaDB.
local M = {}

local LEDGER_ROW = '(?, ?, ?, ?, ?, ?, ?, ?)'
M.LEDGER_COLUMNS = 8

M.text = {
  -- The watchdog's own tables.
  create_ledger = [[CREATE TABLE IF NOT EXISTS wd_ledger (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    t DOUBLE NOT NULL,
    kind VARCHAR(8) NOT NULL,
    player VARCHAR(64) NOT NULL,
    name VARCHAR(64) NOT NULL,
    item_key VARCHAR(64) NOT NULL,
    delta DOUBLE NOT NULL,
    reason VARCHAR(120) NOT NULL,
    actor VARCHAR(80) NOT NULL,
    INDEX wd_ledger_t (t)
  ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
  create_baselines = [[CREATE TABLE IF NOT EXISTS wd_baselines (
    k VARCHAR(100) NOT NULL PRIMARY KEY,
    v LONGTEXT NOT NULL,
    updated DOUBLE NOT NULL
  ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
  create_incidents = [[CREATE TABLE IF NOT EXISTS wd_incidents (
    id INT UNSIGNED NOT NULL PRIMARY KEY,
    type VARCHAR(20) NOT NULL,
    is_open TINYINT NOT NULL,
    v LONGTEXT NOT NULL,
    updated DOUBLE NOT NULL
  ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
  trim_ledger = 'DELETE FROM wd_ledger WHERE t < ? LIMIT 5000',
  load_baselines = 'SELECT k, v FROM wd_baselines',
  save_baseline = 'INSERT INTO wd_baselines (k, v, updated) VALUES (?, ?, ?) '
    .. 'ON DUPLICATE KEY UPDATE v = VALUES(v), updated = VALUES(updated)',
  load_incidents = 'SELECT v FROM wd_incidents ORDER BY id DESC LIMIT 1000',
  save_incident = 'INSERT INTO wd_incidents (id, type, is_open, v, updated) VALUES (?, ?, ?, ?, ?) '
    .. 'ON DUPLICATE KEY UPDATE type = VALUES(type), is_open = VALUES(is_open), v = VALUES(v), updated = VALUES(updated)',

  -- Read only: what the count totals (framework and inventory tables).
  offline_money = 'SELECT citizenid, money FROM players',
  offline_items = 'SELECT citizenid, inventory FROM players',
  ox_stashes = 'SELECT owner, name, data FROM ox_inventory',
  ox_vehicles = 'SELECT id, trunk, glovebox FROM player_vehicles',
  qb_identifiers = 'SELECT identifier FROM inventories',
  qb_inventories = 'SELECT identifier, items FROM inventories',

  -- Read only: qb-banking's business and gang accounts and its own record of every account change
  -- (qb-banking@b2dee4e banking.sql; server.lua:95-137 writes a statement with no citizenid on each change).
  qb_accounts_total = 'SELECT COALESCE(SUM(account_balance), 0) AS total FROM bank_accounts',
  qb_statement_head = 'SELECT COALESCE(MAX(id), 0) AS id FROM bank_statements',
  qb_statements = 'SELECT id, account_name, amount, statement_type, UNIX_TIMESTAMP(date) AS t FROM bank_statements '
    .. 'WHERE id > ? AND citizenid IS NULL ORDER BY id LIMIT 5000',
}

-- The insert for n ledger lines at once (n rows of M.LEDGER_COLUMNS values).
function M.insert_ledger(n)
  local rows = {}
  for i = 1, n do rows[i] = LEDGER_ROW end
  return 'INSERT INTO wd_ledger (t, kind, player, name, item_key, delta, reason, actor) VALUES ' .. table.concat(rows, ', ')
end

return M
