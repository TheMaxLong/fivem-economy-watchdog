-- Loads the watchdog's modules from its own folder and starts it. FiveM runs only this file (see
-- fxmanifest.lua); every other file is read through the loader below, so none is ever sent to a game
-- client, and nothing from outside the folder is ever loaded.
local RESOURCE = GetCurrentResourceName()
local loaded, loading = {}, {}

-- require for this resource's own files: 'core.engine' reads core/engine.lua. A name with no file in the
-- folder is an error, and so is a module that requires itself (it would otherwise recurse forever).
function require(name)
  local hit = loaded[name]
  if hit ~= nil then return hit end
  if loading[name] then error(('module %s requires itself (a circular require)'):format(name), 2) end
  local path = name:gsub('%.', '/') .. '.lua'
  local src = LoadResourceFile(RESOURCE, path)
  if not src then error(('module %s not found (%s)'):format(name, path), 2) end
  loading[name] = true
  local ok, m = pcall(assert(load(src, '@@' .. RESOURCE .. '/' .. path)), name)
  loading[name] = nil
  if not ok then error(m, 0) end
  if m == nil then m = true end
  loaded[name] = m
  return m
end

require('server.app').start(Config or {})
