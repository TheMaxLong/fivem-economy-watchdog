# Economy Watchdog

A server-only, read-only resource for QBCore and Qbox. It counts every player's money and items, compares
the totals against the changes the framework reported, and posts in your Discord when money or items show up
that nothing explains.

It never writes to your framework's tables and never touches a player. It keeps three tables of its own
(`wd_ledger`, `wd_baselines`, `wd_incidents`).

## What it catches

| Alert | When it fires |
|---|---|
| 🔴 Money appeared from nowhere | Cash or bank rose more than the recorded money changes explain: database edits, money added outside the framework |
| 🔴 Items appeared from nowhere | Item totals rose more than recorded creations explain: duplication |
| 🔴 Account transfers don't add up | Business or gang accounts hold more than their recorded deposits and withdrawals (qb-banking) |
| 🔴 Same stash slot paid out twice | Two players took the same stash slot within a second or two |
| 🟠 Earning far too fast | A player earned many times this server's normal top from one source in an hour (after 72 hours of learning) |
| 🟡 Staff money | Money given by a labelled staff command |
| ⚪ Health notices | Counting stopped or came back, money changes not heard, item counting off, database unreachable |

Admins answer an alert in chat or the console: `/wd fine <id>`, `/wd exploit <id>`, `/wd legit <id>`.
`/wd status` shows what it hears and how the last count went.

## Requirements

- QBCore with qb-inventory and qb-banking, **or** Qbox with ox_inventory
- oxmysql
- A Discord webhook

On ox_inventory v2.47.9 (the current release) items are not counted, because that version has no
`GetInventories` export. Money is. Items are counted on the next ox_inventory release. Renewed-Banking does not
record account changes, so business accounts are not counted on it. ESX is not supported.

## Install

1. Put the `economy_watchdog` folder in `resources`.
2. In `server.cfg`, below your framework, inventory and bank:

   ```
   set wd_webhook "https://discord.com/api/webhooks/..."
   ensure economy_watchdog
   add_ace group.admin watchdog.admin allow
   ```

   Use `set`, never `setr`: `setr` sends the webhook address to every player.
3. Restart. The console prints `[economy_watchdog] started: framework …, items …, business accounts …`.

It counts every 10 minutes and spends the first 72 hours learning your server's normal before the "earning far
too fast" alert can fire. The other alerts work from the first count. Every setting is explained in
`core/defaults.lua`; override them in `config.lua`.

## Removing it

Delete the folder and its `ensure` line. The three `wd_` tables are safe to drop.
