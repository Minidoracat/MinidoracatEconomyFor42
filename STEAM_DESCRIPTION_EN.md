[h1]💰 Minidoracat Economy for B42[/h1]
[h3]By Minidoracat[/h3]

[hr][/hr]

[h2]✨ What is this?[/h2]
An economy system for Build 42 [b]dedicated multiplayer servers[/b]: two currencies, a system shop, player market, auctions, mailbox storage, rewards, seasons, administration and reconciliation tools.
[b]Dedicated servers only - single-player and Host / co-op are not supported.[/b]

[h2]🧰 For players[/h2]
[list]
[*] [b]Two-currency wallet[/b]: Survivor Coin and Cat Coin show available and reserved amounts separately, and the server can rename them and replace their icons. The statement can be searched by type, date and keyword across the records already loaded, and full balance details can be read and copied.
[*] [b]Economy terminals[/b]: vanilla floor-standing and wall-mounted map ATMs work directly within 2 tiles on the same floor, without registration. Custom machine and catgirl terminals, and supported terminal cabinets, still require admin registration as an ATM or trade station; only trade stations provide the market radio. Transactions and claims require a nearby terminal; remote access rules are server-configurable.
[*] [b]Map ATM protection[/b]: ordinary players cannot remove supported vanilla ATMs with a sledgehammer or furniture disassembly; authorized admins can still remove them. This does not cover fire, explosions or direct removal by other mods, and does not restore ATMs already removed.
[*] [b]System shop[/b]: buy at the fixed prices the server sets, with per-player or server-wide daily limits. When buyback is enabled you can sell qualifying items back to the server. Every entry can carry its own Survivor Coin and Cat Coin sell and buyback price; each trade uses only the chosen currency, and no quote never means free.
[*] [b]Player market[/b]: list items from your bag at a fixed price at a terminal, then browse, search, filter and sort every listing on the server and buy. The sales tax is paid by the seller, listing fees are not refunded, and unsold listings return to your mailbox when they expire. A seller picker lets you filter by one exact account.
[*] [b]Auction house[/b]: choose a starting price and duration (6-72 hours by default, configurable by the server owner). Bids reserve funds; being outbid releases them. The winner receives the items, the seller receives payment after tax, and auctions without bids return the items. Bid history is available.
[*] [b]Mailbox[/b]: purchases, auction wins, cancellations and returns all arrive in the mailbox and can be claimed one by one or in bulk; unclaimed items survive your character's death. The mailbox has a slot limit, and unclaimed mail plus your own listings and auctions all count towards it.
[*] [b]Rewards and seasons[/b]: daily rewards count actual connected time, with server-configured limits and intervals. Survival milestones use single-life progress within the season. Holdings rank by currency; the survival board records each account's longest single life this season and retains finished survival seasons.
[*] [b]Market radio (optional)[/b]: trade stations can broadcast text market summaries. Native radio preset lists include "Market Radio"; select it and tune in. Reception still requires suitable frequency range, power, volume and distance. Voice pickup is [b]off by default[/b] and must be enabled by the server owner.
[*] [b]Interface[/b]: a standalone Economy Center window that separates reading from acting - clicking a row only opens a floating detail view and never triggers a trade - and that detail view can be moved, resized, scrolled and copied. Every page supports the keyboard, and window position, size and preferences are remembered.
[/list]

[h2]📋 Installation and deployment for server owners[/h2]
[list]
[*] [b]Required dependency[/b]: [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3789836701][b]MinidoracatUIFor42[/b][/url] (API rev 6 or newer). Both mods must be installed on the server and on every client at the same version; after an update restart both server and clients. Requires Build 42.20.4 or newer.
[*] [b]Server configuration[/b]: rewards, admin limits, currency and deposits, shop, market and radio options are all editable in-game under Economy Administration - Settings. The shop catalog (catalog.json) and the market whitelist (whitelist.json) live in the server folder; panel changes are written back and pushed to online players.
[*] [b]Permissions[/b]: economic write access, read-only access and self-adjustment have separate role lists. Adjustments require a reason, revision checks and limits, with an audit trail. Changing role lists, administration limits or seasons additionally requires native role-management permission.
[*] [b]World saves[/b]: item transfers are settled by the world save, so set a suitable save interval and shut the server down normally. This mod never rewrites your server settings and never forces an extra save.
[*] [b]companion (external tool, deploy it yourself)[/b]: a Node 24 tool shipped with the source that [b]does not run automatically with a Workshop subscription[/b] and must be deployed on the server host. Item transfers need it to report a stable world save as the save-confirmation watermark, so [b]deploy it for normal operation[/b]; it can also produce a read-only daily cash-flow report, run by hand or from your own scheduler, which never calls AI and never edits balances. Without it, records awaiting confirmation accumulate and new item movement pauses once the protection limit is reached.
[*] [b]Discord point deposits[/b]: the game side and companion expose the interface and order flow for an integration, but this is [b]not subscribe-and-go[/b] - you need your own external points system, your own Steam account linking, and you must deploy the bridge yourself.
[/list]

[h2]🚧 Limits and boundaries[/h2]
[list]
[*] Listing requires both the server whitelist and the system's supported item types and state checks. [b]Not every modded item can be traded[/b]; consult the listing picker for the actual decision.
[*] When source or save evidence is incomplete the system keeps a pending reconciliation entry rather than reissuing or deleting anything; admins can resolve entries individually or in batches from Asset Reconciliation, always with a reason and a fresh re-check.
[*] Radio voice keeps the native radio limits: the server must have voice enabled, player push-to-talk or voice activation settings apply, and nearby or lower-floor devices may hear it, so it is not private chat. General chat relay and the various range scenarios have not been fully tested yet.
[*] Searches and record lookups have explicit loaded-record and date-range limits; the interface states the scope instead of presenting data that was never loaded as "no results".
[/list]

[h2]💬 Feedback and community[/h2]
[list]
[*] [url=https://discord.gg/Gur2V67]Discord community[/url]
[/list]

[h2]☕ Support the author[/h2]
The mod is free and always will be. If you enjoy it, consider buying me a coffee - tips go straight into servers and mod development.
[url=https://ko-fi.com/minidoracat][img]https://raw.githubusercontent.com/Minidoracat/workshop-resources/refs/heads/main/badges/badge_kofi.png[/img][/url]

[b]#Minidoracat[/b]

[b]Workshop ID:[/b] 3801482125
[b]Mod ID:[/b] MinidoracatEconomyFor42
