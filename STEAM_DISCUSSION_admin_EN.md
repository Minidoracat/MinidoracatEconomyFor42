<!-- Steam 討論區貼文稿源（英文）；簡介只放摘要，詳細內容以本串為準 -->
<!-- 討論串網址：https://steamcommunity.com/workshop/filedetails/discussion/3801482125/586187095760095807/ -->
<!-- 標題：🛠️ Economy Server Setup & Administration -->

[b]繁體中文版：[/b][url=https://steamcommunity.com/workshop/filedetails/discussion/3801482125/586187095760095794/]Economy 服主安裝與管理[/url]

Player features and FAQ: [url=https://steamcommunity.com/workshop/filedetails/discussion/3801482125/586187095760095779/]Economy Player Guide[/url]

[b]Dedicated multiplayer servers only; single-player and Host / co-op are not supported.[/b]

[h2]🚀 Deployment checklist[/h2]
[olist]
[*] Enable [b]MinidoracatUIFor42[/b] and [b]MinidoracatEconomyFor42[/b] on the server, with the UI Library loaded first (Workshop IDs 3789836701 / 3801482125). The UI Library must provide API rev 11 or newer, otherwise the economy interface will not open
[*] Keep the server and every client on the same versions; after each update, fully restart both the server and the clients
[*] Set a suitable world save interval and always shut the server down normally
[*] Deploy companion on the server host (see below) so item transfers can settle
[*] In game, press Admin in the Economy Center to open [b]Economy Administration[/b], then review every Settings page and the role lists
[/olist]

[h2]⚙️ Server settings[/h2]
[list]
[*] Rewards, admin limits, currency and deposits, system shop, market, auctions, market radio and seasons can all be changed live under Economy Administration - Settings, and every change is audited.
[*] The shop catalog (catalog.json) and the market whitelist (whitelist.json) live in the server data folder; panel changes are written back and pushed to online players. After editing a file by hand, press Reload on its page first.
[*] The shop catalog and the market whitelist are separate: adding a shop item does not widen what players may list on the market.
[*] Cat Coin buyback limits default to 0 (off); raise them explicitly to open Cat Coin buyback.
[/list]

[h2]🏧 Terminals and market radio[/h2]
[list]
[*] [b]Map ATMs[/b]: Settings - General has "Use map ATMs as terminals" (on by default) and "Allow players to remove map ATMs" (off by default); the two are independent. The protection does not cover fire, explosions or direct removal by other mods, and does not restore ATMs already removed.
[*] [b]Custom terminals[/b]: the machine and catgirl designs are in the Furniture category of the build menu, visible to admins only. After placing one, right-click "Register as ATM terminal (no radio)" or "Register as trade station (with market radio)". To turn an ATM into a trade station, remove the terminal registration first and register again; no rebuild is needed.
[*] [b]Market summaries[/b]: trade stations broadcast text market summaries on a timer; an interval of 0 stops only the summary. ATMs never broadcast.
[*] [b]Voice pickup[/b]: "Trade station voice pickup" under Settings - Market radio is [b]off by default[/b]. Once on, the server still needs voice enabled and each player's push-to-talk or voice activation settings apply; nearby or lower-floor devices may hear it, so it is not private chat. General chat relay and all range scenarios have not been fully tested yet.
[*] [b]Before removing this mod[/b]: unregister every trade station while its area is loaded, check that the speaker is gone, then save normally. Simply disabling the mod runs no cleanup.
[/list]

[h2]🔐 Permissions[/h2]
[list]
[*] Three role lists are set separately: write access (default admin), read-only (default moderator) and self-adjustment (default none). Pick roles from the server's native role list, custom roles included.
[*] Balance adjustments need a reason and follow revision checks and limits (per transaction, per admin daily, server-wide daily), all audited.
[*] Changing role lists, admin limits or seasons additionally requires native role-management permission; economic write access alone is not enough.
[*] Adjusting your own balance is off by default: your role must be on both the write-access and self-adjustment lists.
[/list]

[h2]📅 Seasons and integration plans[/h2]
[list]
[*] [b]Seasons[/b]: Admin - Seasons shows current and past seasons. Anyone with native role-management permission can set the length (real days, 0 = manual) or start the next season with a reason; this archives old results without clearing balances or characters.
[*] [b]Integration plans[/b]: paid slots for other mods are configured on the Integration plans page (prices, currency, slots and terms), with a change summary before applying; you can also look up account entitlements and refund the original order.
[/list]

[h2]💾 World saves and companion[/h2]
Item transfers are settled by the [b]world save[/b]. A save interval of 0 means no scheduled world saves, and player inventory saves cannot replace them. This mod never rewrites server settings or forces extra saves; use your host's existing tools for backup and restore.

[b]companion[/b] is a Node 24 tool shipped with the source. It [b]does not run automatically with a Workshop subscription[/b] and must be deployed on the server host. It reports stable world saves as the save confirmation that item transfers need to settle, so [b]deploy it for normal operation[/b]. Without it, records awaiting confirmation accumulate and new item movement pauses once the protection limit is reached.
[olist]
[*] Get the companion folder from the source on GitHub, put it on the server host and install Node.js 24 or newer
[*] Copy .env.example to .env and set ZOMBOID_DIR (the same data directory as the game server; empty = the current user's Zomboid folder) and SERVER_NAME
[*] Run npm install in the companion folder, then keep npm start running
[*] Back in Economy Administration - System, check the save confirmation status
[/olist]
[b]Read-only daily report[/b]: npm run report writes the previous day's cash-flow report (npm run report -- --date 2026-09-13 for a specific day); run it by hand or from your own scheduler. It never calls AI or edits balances. Reports contain player accounts and admin reasons, so restrict access to the files.

[h2]💰 Discord point deposits[/h2]
The game side and companion expose the interface and order flow for an integration, but this is [b]not subscribe-and-go[/b]: you need your own external points system, your own Steam account linking, and you must deploy the bridge yourself. Basic in-game trading does not need Discord.

[h2]🧾 Asset reconciliation[/h2]
[list]
[*] When source or save evidence is incomplete, the system keeps a pending reconciliation entry rather than reissuing or deleting anything.
[*] Admin - Reconciliation has a server-wide overview: re-check the whole server, then resolve entries one by one or in batches (Ctrl/Shift multi-select), always with a reason and a fresh re-check. Read-only roles can only view.
[*] Do not clear pending entries by hand; check companion, world saves and the save confirmation status on the System page first.
[/list]

[h2]❓ FAQ[/h2]
[list]
[*] [b]Players say the Economy Center won't open.[/b] Make sure the UI Library is current (API rev 11+) and server and clients match after a full restart.
[*] [b]A protection limit appeared and items cannot move.[/b] Usually companion is not running or there has been no world save yet. Start companion, wait for a normal save, then check the System page.
[*] [b]I added a shop item, but players still can't list it.[/b] The shop catalog and the market whitelist are two lists; allow it on the whitelist page as well. Some item classes (containers, clothing, keys and so on) can never be listed, whatever the whitelist says.
[*] [b]Is there a backup feature?[/b] No. Use your host's existing backup tools; economy data is saved with the world save.
[/list]

[h2]💬 How to report[/h2]
[list]
[*] [url=https://github.com/Minidoracat/MinidoracatEconomyFor42/issues]GitHub Issues[/url]: include the mod version, steps to reproduce and the related server log lines containing MinidoracatEconomyFor42.
[*] [url=https://discord.gg/Gur2V67]Discord community[/url]
[/list]
