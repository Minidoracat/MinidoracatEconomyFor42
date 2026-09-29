<!-- Steam 討論區貼文稿源（英文）；簡介只放摘要，詳細內容以本串為準 -->
<!-- 討論串網址：https://steamcommunity.com/workshop/filedetails/discussion/3801482125/586187095760095807/ -->
<!-- 標題：🛠️ Economy Server Setup & Administration -->

[b]繁體中文版：[/b][url=https://steamcommunity.com/workshop/filedetails/discussion/3801482125/586187095760095794/]Economy 服主安裝與管理[/url]

Player features and FAQ: [url=https://steamcommunity.com/workshop/filedetails/discussion/3801482125/586187095760095779/]Economy Player Guide[/url]

[b]Dedicated multiplayer servers only; single-player and Host / co-op are not supported.[/b]

[h2]🚀 Deployment checklist[/h2]
[olist]
[*] Enable [b]MinidoracatUIFor42[/b] (API rev 11+) and [b]MinidoracatEconomyFor42[/b], UI Library first (Workshop IDs 3789836701 / 3801482125)
[*] Keep server and clients on the same versions; fully restart both after each update
[*] Set a world save interval and always shut down normally
[*] Deploy companion on the server host (see below) so item transfers can settle
[*] In game, press Admin in the Economy Center to open [b]Economy Administration[/b] and review Settings and the role lists
[/olist]

[h2]⚙️ Server settings[/h2]
[list]
[*] Rewards, admin limits, currencies, shop, market, auctions, radio, transfers and seasons are changed live under Economy Administration - Settings, all audited.
[*] The shop catalog (catalog.json) and market whitelist (whitelist.json) are in the server data folder; panel changes are written back and pushed to players. After hand edits, press Reload on the page.
[*] The shop catalog and the market whitelist are separate: a new shop item does not widen what players may list.
[*] [b]Clothing listings[/b] are off by default: open the Clothing, ProtectiveGear and Accessory categories on the whitelist.
[*] Cat Coin buyback limits default to 0 (off); raise them to open Cat Coin buyback.
[/list]

[h2]💸 Player transfers[/h2]
[list]
[*] [b]Off by default.[/b] Settings - Player transfers holds the master switch, sending away from a terminal or ATM (off), the fee (5%, paid on top by the sender and burned), per-transfer minimum and maximum, a daily limit per player, and the days a new account waits before sending (3; accounts that existed before the update are exempt).
[*] Also enable each transferable currency under Currency settings; currencies that can be bought with Discord points show a warning.
[*] Other mods can transfer for players only if each mod is allowed on the Integrations page.
[/list]

[h2]🏧 Terminals and market radio[/h2]
[list]
[*] [b]Map ATMs[/b]: Settings - General has "Use map ATMs as terminals" (on) and "Allow players to remove map ATMs" (off). Fire, explosions and other mods are not covered, and removed ATMs are not restored.
[*] [b]Custom terminals[/b]: the machine and catgirl designs are in the build menu's Furniture category, visible to admins only. Right-click a placed one: "Register as ATM terminal (no radio)" or "Register as trade station (with market radio)". To switch type, remove the registration and register again.
[*] [b]Market summaries[/b]: trade stations broadcast text summaries on a timer; an interval of 0 stops only the summary. ATMs never broadcast.
[*] [b]Voice pickup[/b] (Settings - Market radio) is [b]off by default[/b]. Once on, server voice and players' push-to-talk settings still apply; nearby or lower-floor devices may hear it, so it is not private.
[*] [b]Before removing this mod[/b]: unregister every trade station while its area is loaded, check the speaker is gone, then save normally. Disabling the mod alone runs no cleanup.
[/list]

[h2]🔐 Permissions[/h2]
[list]
[*] Three role lists: write access (default admin), read-only (default moderator) and self-adjustment (default none), picked from the server's native roles, custom roles included.
[*] Balance adjustments need a reason and respect revision checks and limits (per transaction, per admin daily, server-wide daily), all audited.
[*] Changing role lists, admin limits or seasons also needs native role-management permission.
[*] Adjusting your own balance needs your role on both the write-access and self-adjustment lists.
[/list]

[h2]📅 Seasons and integration plans[/h2]
[list]
[*] [b]Seasons[/b]: Admin - Seasons shows current and past seasons. With native role-management permission you can set the length (real days, 0 = manual) or start the next season with a reason; results are archived, balances and characters are kept.
[*] [b]Integration plans[/b]: set prices, currency, slots and terms for other mods' paid slots with a change summary before applying; look up entitlements and refund orders.
[/list]

[h2]💾 World saves and companion[/h2]
Item transfers settle on the [b]world save[/b]. A save interval of 0 means no scheduled world saves; player saves do not replace them. This mod never rewrites server settings or forces saves; use your host's tools for backup and restore.

[b]companion[/b] is a Node 24 tool in the source that [b]does not run with a Workshop subscription[/b]. Deploy it on the server host: it reports stable world saves, which item transfers need to settle. Without it, unconfirmed records pile up and item movement pauses at the protection limit.
[olist]
[*] Put the companion folder from GitHub on the server host and install Node.js 24+
[*] Copy .env.example to .env and set ZOMBOID_DIR (the game server's data directory; empty = the current user's Zomboid folder) and SERVER_NAME
[*] Run npm install, then keep npm start running
[*] Check the save confirmation status in Economy Administration - System
[/olist]
[b]Read-only daily report[/b]: npm run report writes the previous day's cash-flow report (npm run report -- --date 2026-09-13 for a given day). It never edits balances. Reports contain accounts and admin reasons, so restrict access.

[h2]💰 Discord point deposits[/h2]
The interface and order flow exist, but this is [b]not subscribe-and-go[/b]: you need your own points system, Steam account linking and bridge. Basic trading does not need Discord.

[h2]🧾 Asset reconciliation[/h2]
[list]
[*] When source or save evidence is incomplete, the system keeps a pending entry instead of reissuing or deleting anything.
[*] Admin - Reconciliation has a server-wide overview: re-check everything, then resolve entries one by one or in batches (Ctrl/Shift), always with a reason and a fresh check. Read-only roles can only view.
[*] [b]Duplicates after a crash[/b]: if the world save is newer than a player save, the older save can bring back items already listed, auctioned or sold, even in someone else's hands. Once that trade is in a world save, the copy is taken back at the holder's login, with a notice and one SYSTEM Audit line per item (naming the original trader if different). Worn or hotbar items, non-empty bags and duplicate ids stay pending.
[*] [b]Restore[/b]: select that Audit line, press Restore and give a reason; the item is rebuilt as it was and mailed to the holder. Once per reclaim, latest 200 kept. The original still exists, so [b]restore only real mistakes[/b].
[*] Do not clear pending entries by hand; check companion, world saves and the System page first.
[/list]

[h2]❓ FAQ[/h2]
[list]
[*] [b]Players say the Economy Center won't open.[/b] Check the UI Library is current (API rev 11+) and server and clients match after a full restart.
[*] [b]A protection limit appeared and items cannot move.[/b] Usually companion is not running or no world save has happened yet. Start companion, wait for a normal save, then check the System page.
[*] [b]I added a shop item, but players still can't list it.[/b] The shop catalog and market whitelist are separate; allow it on the whitelist too. Containers, keys, furniture and similar classes can never be listed; clothing needs the clothing categories opened.
[*] [b]Is there a backup feature?[/b] No. Use your host's backup tools; economy data is saved with the world.
[/list]

[h2]💬 How to report[/h2]
[list]
[*] [url=https://github.com/Minidoracat/MinidoracatEconomyFor42/issues]GitHub Issues[/url]: include the mod version, steps to reproduce and the server log lines containing MinidoracatEconomyFor42.
[*] [url=https://discord.gg/Gur2V67]Discord community[/url]
[/list]
