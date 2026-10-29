-- Business and gang accounts. A bank is counted only when every change to its accounts can be read.
-- qb-banking: every AddMoney/RemoveMoney on an account writes a bank_statements row with no citizenid
-- (qb-banking@b2dee4e server.lua:95-137). Rows with a citizenid are history copies that change no balance
-- (CreateBankStatement, server.lua:68-92), so they are never read.
local Store = require('server.store')
local M = {}

-- The reason strings each bank gives a player's money when it moves rather than being earned
-- (qb-banking server.lua:221-262, and :363 for the deposit that opens a shared account, whose new balance
-- has no record of its own). account patterns capture the account's name.
M.PATTERNS = {
  ['qb-banking'] = {
    transfer = { '^bank deposit$', '^bank withdrawal$' },
    account = { '^bank account: (.+) deposit$', '^bank account: (.+) withdrawal$', '^opened account (.+)$' },
  },
}

-- Qbox's bridge announces every account item move (cash, black_money, ...) as a 'set' with the reason
-- 'Sync <account> with inventory' (ox_inventory@172b391 modules/bridge/qbx/server.lua:68).
M.CASH_ITEM_SYNC = '^sync .+ with inventory$'

local PAGE = 5000  -- matches the LIMIT in server/sql.lua's qb_statements

-- A bank is read only once its resource has started, whatever the setting says: a bank that never
-- started has no records to read, and every count would be refused.
function M.detect(setting)
  if setting == 'none' then return nil end
  if GetResourceState('qb-banking') == 'started' then return 'qb-banking' end
  return nil
end

-- The owner's settings with the patterns the bank and inventory need added to their own.
function M.settings(config, bank, inventory)
  local out = {}
  for k, v in pairs(config or {}) do out[k] = v end
  local transfer, account = {}, {}
  for _, p in ipairs(type(out.transfer_patterns) == 'table' and out.transfer_patterns or {}) do transfer[#transfer + 1] = p end
  for _, p in ipairs(type(out.account_patterns) == 'table' and out.account_patterns or {}) do account[#account + 1] = p end
  local own = M.PATTERNS[bank]
  for _, p in ipairs(own and own.transfer or {}) do transfer[#transfer + 1] = p end
  for _, p in ipairs(own and own.account or {}) do account[#account + 1] = p end
  if inventory == 'ox' then transfer[#transfer + 1] = M.CASH_ITEM_SYNC end
  out.transfer_patterns, out.account_patterns = transfer, account
  return out
end

-- Hands the bank's new records to the engine and returns the accounts total, or nil and why. The first
-- read starts at the newest record, so history before the watchdog started is never replayed.
-- ctx.layer_state.statement_id remembers the last record read (saved with the engine's state). A record
-- that can't be read (or that the engine refuses) is skipped and counted in /wd status.
-- ponytail: the last id read is a watermark, which assumes ids commit in order. A record whose id was
-- taken before a higher one but commits after that higher one was read is never seen, and its change
-- reads as unexplained. Upgrade path: re-read a short window of ids below the watermark each count and
-- skip the ones already handed over.
function M.read(ctx, bank)
  if bank ~= 'qb-banking' then return nil, 'no readable bank' end
  local state = ctx.layer_state
  if state.statement_id == nil then
    local head, why = Store.run('qb_statement_head')
    if not head then return nil, why end
    state.statement_id = tonumber(head[1] and head[1].id) or 0
  end
  local rows, why = Store.run('qb_statements', { state.statement_id })
  if not rows then return nil, why end
  local last = state.statement_id
  for _, r in ipairs(rows) do
    local amount = tonumber(r.amount)
    local ok = amount and type(r.account_name) == 'string' and ctx.engine:account_change({
      t = tonumber(r.t) or ctx.clock:now(), account = r.account_name,
      delta = r.statement_type == 'withdraw' and -amount or amount })
    if not ok then ctx.count_stats.unreadable = ctx.count_stats.unreadable + 1 end
    last = math.max(last, tonumber(r.id) or 0)
  end
  state.statement_id = last  -- these records are in the engine now: never hand them over twice
  -- A full page means more records wait. The total now would include changes not yet handed over, so
  -- this count leaves money out, and the next one starts a fresh baseline.
  if #rows >= PAGE then return nil, 'catching up' end
  local total, why2 = Store.run('qb_accounts_total')
  if not total then return nil, why2 end
  return tonumber(total[1] and total[1].total) or 0
end

return M
