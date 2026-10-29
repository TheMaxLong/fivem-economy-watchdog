fx_version 'cerulean'
game 'gta5'
lua54 'yes'
server_only 'yes'

name 'economy_watchdog'
description 'Watches the server economy and tells the owner on Discord when money or items appear that should not exist. Read-only.'
version '0.2.0'

dependency 'oxmysql'

-- Only these run. boot.lua reads core/ and server/ itself, so nothing is ever sent to a game client.
server_scripts {
  '@oxmysql/lib/MySQL.lua',
  'config.lua',
  'server/boot.lua',
}
