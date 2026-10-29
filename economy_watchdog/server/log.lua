-- One place every layer message goes, so the console shows one prefix and tests can read them. guard()
-- runs a handler so that its failure is reported and counted and never reaches the game.
local M = { failures = 0, last_failure = nil }

function M.say(msg)
  print(('[economy_watchdog] %s'):format(tostring(msg)))
end

-- Runs fn(...) protected. Returns what fn returned, or nil after reporting the error.
function M.guard(what, fn, ...)
  local out = table.pack(pcall(fn, ...))
  if out[1] then return table.unpack(out, 2, out.n) end
  M.failures = M.failures + 1
  M.last_failure = ('%s: %s'):format(what, tostring(out[2]))
  M.say('error in ' .. M.last_failure)
  return nil
end

return M
