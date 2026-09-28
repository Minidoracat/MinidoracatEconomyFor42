<!-- Steam 討論區貼文稿源（英文）；簡介只放摘要，詳細內容以本串為準 -->
<!-- 討論串網址：https://steamcommunity.com/workshop/filedetails/discussion/3801482125/586187095760095779/ -->
<!-- 標題：📖 Economy Player Guide -->

[b]繁體中文版：[/b][url=https://steamcommunity.com/workshop/filedetails/discussion/3801482125/586187095760095761/]Economy 玩家說明[/url]

Server installation, permissions and external tools: [url=https://steamcommunity.com/workshop/filedetails/discussion/3801482125/586187095760095807/]Economy Server Setup & Administration[/url]

[h2]🚀 Quick start[/h2]
[olist]
[*] Press "[" (rebindable in Key Bindings) or click the floating button to open the [b]Economy Center[/b]
[*] Away from a terminal you can only browse. To trade, list or claim items, walk up to a map ATM or an admin-built terminal and right-click [b]Use economy terminal[/b]
[*] Claim your daily online reward on the Rewards page to start earning Survivor Coins
[*] Buy and sell in the shop, market or auctions; items arrive in your Mailbox and can be claimed at any terminal
[/olist]

[h2]🧰 Features in detail[/h2]

[h3]Wallet[/h3]
[list]
[*] [b]Two currencies[/b]: Survivor Coin and Cat Coin show available and reserved amounts separately; the server can rename them and replace their icons.
[*] [b]Statement[/b]: search the loaded records by type, date and keyword; Balance details can be read in full and copied.
[*] [b]Player ID[/b]: your login account (not your character name) is shown at the top of every page; click it to copy it for an admin.
[/list]

[h3]Economy terminals[/h3]
[list]
[*] [b]Map ATMs[/b]: vanilla floor-standing and wall-mounted ATMs work directly within 2 tiles on the same floor, without registration (the server can turn this off).
[*] [b]Custom terminals[/b]: the machine and catgirl designs, and supported terminal cabinets, are registered by an admin as an ATM or a trade station; only trade stations provide the market radio.
[*] [b]One shared market[/b]: list at station A, someone buys at station B, you collect at station C. Remote access rules are set by the server owner.
[*] [b]Map ATM protection[/b]: ordinary players cannot remove supported vanilla ATMs with a sledgehammer or furniture disassembly; admins still can. This does not cover fire, explosions or direct removal by other mods, and does not restore ATMs already removed.
[/list]

[h3]System shop[/h3]
[list]
[*] Buy at the fixed prices the server sets, with per-player or server-wide daily limits.
[*] When buyback is enabled you can sell qualifying items back to the server.
[*] Each entry can carry its own Survivor Coin and Cat Coin sell and buyback price; each trade uses only the currency you choose, and [b]no quote never means free[/b].
[/list]

[h3]Player market[/h3]
[list]
[*] List items from your bag at a fixed price at a terminal; browse, search, filter and sort every listing on the server and buy.
[*] The seller pays the sales tax and listing fees are not refunded; unsold listings return to your mailbox when they expire.
[*] Type part of a name to pick an exact account from the seller list and filter by that seller.
[*] The current tax and listing fee are shown under the market title; "Fees and rules" opens the full text.
[/list]

[h3]Auction house[/h3]
[list]
[*] Choose a starting price and duration (6-72 hours by default, configurable by the server owner).
[*] Bids reserve funds and being outbid releases them. The winner receives the items, the seller receives payment after tax, and auctions without bids return the items.
[*] Every auction has a bid history.
[/list]

[h3]Mailbox[/h3]
[list]
[*] Purchases, auction wins, cancellations and returns all arrive here; claim them one by one or with "Claim all".
[*] Unclaimed items survive your character's death.
[*] The mailbox has a slot limit. Unclaimed mail plus your own listings and auctions all count towards it, and the interface shows each part.
[/list]

[h3]Rewards, seasons and leaderboards[/h3]
[list]
[*] [b]Daily online rewards[/b]: unlock with your total connected time that day, using server-set counts and thresholds; collecting late never delays the next one.
[*] [b]Survival milestones[/b]: paid automatically from one character's survival progress this season, once per milestone per account per season.
[*] [b]Holdings board[/b]: ranked per currency. By default you only see your own exact amount; showing other players' amounts is an admin option.
[*] [b]Survival board[/b]: records the longest single life this season without adding lives together; finished seasons can be browsed.
[/list]

[h3]Market radio (server option)[/h3]
[list]
[*] Trade stations can broadcast text market summaries (listing count, sellers, newest listings).
[*] To listen: turn on a radio, walkie-talkie, world radio or car radio, pick "Market Radio" from the presets and press tune. It does not use one of your own preset slots.
[*] Voice pickup is [b]off by default[/b] and must be enabled by the server owner.
[/list]

[h3]Interface and controls[/h3]
[list]
[*] The Economy Center separates reading from acting: clicking a row only opens a floating detail view (movable, resizable, copyable) and never buys, cancels or bids.
[*] Every page supports keyboard (Tab between areas, arrows to pick rows, Enter for details, Esc to close) and controller (A confirm, B back, LB/RB switch pages).
[*] Window position, size and preferences are remembered.
[/list]

[h3]Paid slots for other mods[/h3]
Supporting mods can let you buy permanent or rented extra slots with economy currency (Vehicle Manager first). Auto-renewal is opt-in and can be cancelled anytime.

[h2]❓ FAQ[/h2]
[list]
[*] [b]Why are the buttons greyed out?[/b] You are not at a terminal. Walk within 2 tiles, on the same floor, of a map ATM or a registered terminal and the window becomes tradable.
[*] [b]Why can't I list my item?[/b] Listing needs the server whitelist plus the system's supported item types and state checks, so [b]not every modded item can be traded[/b]. Containers, clothing, keys, furniture, maps, animals, rotten food and equipped or broken items can never be listed; neither can notes or paper with writing or a lock, poisonous or poisoned food, dishes made with added ingredients or fertilized eggs. The listing picker has the final say.
[*] [b]Does food spoil while listed?[/b] Yes. Perishable food keeps ageing while it is listed.
[*] [b]I can't hear the market radio.[/b] Check that the device is on, the volume is not 0, the band is supported and you are in range; after picking "Market Radio" you still need to press tune. When the server changes the frequency the list updates, but your current channel does not switch by itself.
[*] [b]Can I use the radio voice as private chat?[/b] No. Voice keeps the native radio limits: the server must enable voice, your push-to-talk or voice activation settings apply, and nearby or lower-floor devices may hear it. General chat relay and all range scenarios have not been fully tested yet.
[*] [b]Why can't I find older records?[/b] Search only covers loaded records: the latest 20 statement entries, up to 200 for a month lookup, and up to 200 market records. The interface states the scope instead of treating unloaded data as "no results".
[*] [b]My trade was refused: source could not be confirmed.[/b] The confirmation lists the affected items and the next step: something you can do yourself (such as claiming first), waiting for a world save confirmation, or a case for an admin. For an admin, include the player ID from the top of the page.
[*] [b]I paid for a slot but it is not active yet.[/b] Payments show as accepted, waiting for save confirmation or unknown; a rental starts only after the payment is confirmed as saved. A timeout only re-checks the original order and never charges you again.
[/list]

[h2]💬 How to report[/h2]
[list]
[*] [url=https://github.com/Minidoracat/MinidoracatEconomyFor42/issues]GitHub Issues[/url]: say which page, what you did and what message you saw; screenshots help.
[*] [url=https://discord.gg/Gur2V67]Discord community[/url]
[/list]
