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
[*] Deploy companion on the server host (see below) so item transfers settle and player identities import automatically
[*] In game, press Admin in the Economy Center to open [b]Economy Administration[/b] and review Settings and the role lists
[/olist]

[h2]⚙️ Server settings[/h2]
[list]
[*] All options are changed live under Economy Administration - Settings, and audited.
[*] catalog.json (shop) and whitelist.json (market) are in the server data folder; panel edits are written back. Press Reload after hand edits.
[*] [b]Shop entries[/b] can be deleted one at a time or several at once, with a required reason; sent mail and transaction records are kept, and re-adding the same ID continues its purchase counts. Delisting only stops sales: also turn off buyback, or delete the entry, to retire it. The entry cap is under Settings - System shop (default 200, up to 1000).
[*] Drag an item from your bag onto the admin shop page to create an entry, or onto the whitelist page to pick it for a rule; the item right-click "Economy" menu has "Add as a shop item" and "Add a whitelist rule" too.
[*] [b]Clothing listings[/b] are off by default: open the Clothing, ProtectiveGear and Accessory categories on the whitelist.
[*] Cat Coin buyback limits default to 0 (off).
[/list]

[h2]💸 Player transfers[/h2]
[list]
[*] [b]Off by default.[/b] Settings - Player transfers: master switch, sending away from a terminal or ATM (off), fee (5%, paid by the sender and burned), per-transfer and daily limits, and the wait for new accounts (3 days; accounts older than the update are exempt).
[*] Also enable each transferable currency under Currency settings, and each other mod that may transfer on the Integrations page.
[/list]

[h2]🏧 Terminals and market radio[/h2]
[list]
[*] [b]Map ATMs[/b]: Settings - General has "Use map ATMs as terminals" (on) and "Allow players to remove map ATMs" (off).
[*] [b]Custom terminals[/b] (machine or catgirl, build menu - Furniture) cannot be destroyed; only admins build or remove them. Right-click to register as an economy terminal: ATM (no radio) or trade station (market radio); to switch, unregister first. Registered cabinets are locked too.
[*] [b]Market summaries[/b]: trade stations broadcast them on a timer in each player's language; interval 0 stops only the summary. ATMs never broadcast.
[*] [b]Voice pickup[/b] (Settings - Market radio) is [b]off by default[/b]; it follows server voice settings, and nearby or lower-floor devices may hear it.
[*] [b]Before removing this mod[/b], unregister each trade station while its area is loaded and save normally; disabling the mod runs no cleanup.
[/list]

[h2]🔐 Permissions[/h2]
[list]
[*] Three role lists from the server's native roles: write access (default admin), read-only (default moderator), self-adjustment (default none).
[*] Adjustments need a reason and respect per-transaction, per-admin and server-wide daily limits, all audited.
[*] Role lists, admin limits and seasons also need native role-management permission; adjusting your own balance needs your role on both the write-access and self-adjustment lists.
[/list]

[h2]🪪 Player identity, one account per Steam account, merging[/h2]
[list]
[*] On Steam servers a name acts as its account only when its SteamID matches; otherwise it gets no wallet, trades or notices and sees "Identity not verified". Split-screen players 2-4 never can; AllowCoop=false keeps split-screen off the server.
[*] [b]Binding is automatic[/b]: at first login and character creation (suspected impersonation alerts online admins), and companion imports the whole whitelist. Without companion, press Import identities on Admin - Identity.
[*] [b]One economy account per Steam account by default[/b]: other logins are told so, their assets untouched. The first login is the main one; after an import, the one that used the economy first. To allow several, enable "Allow several economy accounts per Steam account" (role-management permission).
[*] A name bound to another SteamID becomes a conflict, never rebound automatically; confirm it with a reason only if the owner really changed Steam accounts.
[*] [b]Logins of one Steam account[/b] can also merge into the main account (money, today's claims, daily limits, unclaimed mail). [b]Preview only by default[/b]: review the plan on the Identity page, then enable "Merge the login names of one Steam account".
[/list]

[h2]📅 Seasons and integration plans[/h2]
[list]
[*] [b]Seasons[/b]: Admin - Seasons shows current and past seasons. With role-management permission set the length (real days, 0 = manual) or start the next season; balances and characters are kept.
[*] [b]Integration plans[/b]: price other mods' paid slots with a change summary before applying; look up entitlements and refund orders.
[/list]

[h2]💾 World saves and companion[/h2]
Item transfers settle on the [b]world save[/b]; with a save interval of 0 there are none, and player saves do not replace them. This mod never forces saves; back up with your host's tools.

[b]companion[/b] (Node 24, in the source) [b]does not run with a Workshop subscription[/b]; deploy it on the server host and update it with the mod. It confirms world saves, which transfers need, and exports the whitelist. Without it, unconfirmed records pile up until item movement pauses.
[olist]
[*] Put the companion folder from GitHub on the server host and install Node.js 24+
[*] Copy .env.example to .env and set ZOMBOID_DIR (server data folder; empty = your Zomboid folder) and SERVER_NAME (must match the server name)
[*] Run npm install, then keep npm start running
[*] Check save confirmation on the System page and the whitelist export on the Identity page
[/olist]
[b]Daily report[/b]: npm run report writes the previous day's read-only cash-flow report; it contains accounts and admin reasons, so restrict access.

[h2]💰 Discord point deposits[/h2]
The interface and order flow exist, but it is [b]not subscribe-and-go[/b]: you need your own points system, Steam linking and bridge. Basic trading needs no Discord.

[h2]🧾 Asset reconciliation[/h2]
[list]
[*] With incomplete source or save evidence the system keeps a pending entry rather than reissuing or deleting. Admin - Reconciliation lists them server-wide; resolve one by one or in batches (Ctrl/Shift), each with a reason. Read-only roles can only view.
[*] [b]Crash duplicates[/b]: an older player save can bring back items already listed, auctioned or sold. Once the trade is in a world save, the copy is taken back at the holder's login (notice and SYSTEM Audit line); worn, hotbar and non-empty bag items stay pending.
[*] [b]Restore[/b]: select that Audit line, press Restore and give a reason to mail a rebuilt copy to the holder, once per reclaim (latest 200 kept). The original still exists, so [b]restore only real mistakes[/b].
[*] Never clear pending entries by hand; check companion and world saves.
[/list]

[h2]❓ FAQ[/h2]
[list]
[*] [b]A protection limit appeared and items cannot move.[/b] Usually companion is not running or no world save has happened yet; start it, wait for a normal save and check the System page.
[*] [b]A player sees "Identity not verified".[/b] Check conflicts and alerts on the Identity page. A second login of one Steam account is refused by default; borrowed login names and split-screen players never can.
[*] [b]A new shop item still can't be listed.[/b] Shop catalog and market whitelist are separate; allow it on the whitelist. Containers, keys and furniture never can; clothing needs its categories opened.
[/list]

[h2]💬 How to report[/h2]
[list]
[*] [url=https://github.com/Minidoracat/MinidoracatEconomyFor42/issues]GitHub Issues[/url]: include the mod version, steps to reproduce and the server log lines containing MinidoracatEconomyFor42.
[*] [url=https://discord.gg/Gur2V67]Discord community[/url]
[/list]
