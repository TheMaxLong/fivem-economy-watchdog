-- Unix seconds with sub-second precision. os.time() counts whole seconds only, but the same-slot check
-- must tell 0.3 s from 1.2 s, so the time since the last whole second comes from the game timer
-- (milliseconds since the server started). Real clocks drift and get stepped by time sync: when the two
-- disagree by more than drift_s (settings.clock_drift_s, a calibration knob), the clock re-anchors.
local M = {}
M.__index = M

-- drift_s: allowed disagreement in seconds. epoch, timer: functions giving os.time() and GetGameTimer()
-- (the real ones unless a test passes its own).
function M.new(drift_s, epoch, timer)
  local c = setmetatable({ drift_s = drift_s, epoch = epoch or os.time, timer = timer or GetGameTimer,
    anchors = 0 }, M)
  c:anchor()
  return c
end

function M:anchor()
  self.base_s, self.base_ms = self.epoch(), self.timer()
  self.anchors = self.anchors + 1
end

function M:now()
  local t = self.base_s + (self.timer() - self.base_ms) / 1000
  if math.abs(t - self.epoch()) > self.drift_s then
    self:anchor()
    t = self.base_s
  end
  return t
end

-- The server's offset from UTC at time t, in seconds (negative west of Greenwich), so the daily digest
-- turns over at the server's own midnight.
function M.utc_offset(t)
  local here, utc = os.date('*t', math.floor(t)), os.date('!*t', math.floor(t))
  utc.isdst = here.isdst
  return os.time(here) - os.time(utc)
end

return M
