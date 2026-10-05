<!-- Steam 討論區貼文稿源（英文）；簡介只放摘要，詳細內容以本串為準 -->
<!-- 討論串網址：https://steamcommunity.com/workshop/filedetails/discussion/3801482125/586187095760095779/ -->
<!-- 標題：📖 Economy Player Guide -->

[b]繁體中文版：[/b][url=https://steamcommunity.com/workshop/filedetails/discussion/3801482125/586187095760095761/]Economy 玩家說明[/url]

Server installation, permissions and external tools: [url=https://steamcommunity.com/workshop/filedetails/discussion/3801482125/586187095760095807/]Economy Server Setup & Administration[/url]

[h2]🚀 Quick start[/h2]
[olist]
[*] Open the [b]Economy Center[/b] with the "[" key (rebindable in Key Bindings) or the coin icon in the family toolbar; the icon shows a count when your Mailbox has items to claim
[*] Away from a terminal you can only browse; the top bar points to the nearest terminal or ATM, and [b]Guide me[/b] shows the way. To trade, list or claim items, walk up to a map ATM or an admin-built terminal and right-click [b]Use economy terminal[/b]
[*] Claim your daily online reward on the Rewards page to start earning Survivor Coins
[*] Buy and sell in the shop, market or auctions; items arrive in your Mailbox and can be claimed at any terminal
[/olist]

[h2]🧰 Features in detail[/h2]

[h3]Wallet[/h3]
[list]
[*] [b]Two currencies[/b]: Survivor Coin and Cat Coin show available and reserved amounts; the server can rename them and change icons.
[*] [b]Statement[/b]: one filter row (period, keyword, type, custom dates); click Time or Amount to sort. Fees and sales tax follow the note, and market and auction trades name the item ("Flashlight x1 · seller"). Click any line for its card: item, amount (green in, red out), time and balance after; the transaction ID sits under Technical info.
[*] [b]Balance details and This month[/b]: Balance details can be read and copied in full, with This month (income and spending by type) below. It counts the statement lines already loaded, on the available balance: a bid hold counts as spending, its refund as income.
[*] [b]Player ID[/b]: your login account (not your character name) sits at the bottom of the navigation rail, red while unverified; click it to copy it for an admin. Merged logins of one Steam account show "main account (login ...)" and share one wallet.
[/list]

[h3]Player transfers (server option)[/h3]
[list]
[*] When allowed, the wallet page has a gold Transfer button; by default it only works at a terminal or ATM.
[*] Before you confirm, the screen shows the fee (paid by the sender), the total, your balance afterwards and today's remaining limit.
[*] The recipient box lists online players and recent recipients; for offline players type the full account name, matching case.
[*] The recipient is notified. A resend never charges twice and [b]a sent transfer cannot be undone[/b]; limits and the new-account wait are set by the server.
[/list]

[h3]Economy terminals[/h3]
[list]
[*] [b]Map ATMs[/b]: vanilla floor and wall ATMs work within 2 tiles on the same floor, no registration needed (the server can turn this off).
[*] [b]Custom terminals[/b] (machine, catgirl or supported cabinets) are registered by an admin as an ATM or a trade station; only trade stations have the market radio.
[*] [b]One shared market[/b]: list at station A, someone buys at station B, you collect at station C.
[*] [b]Guide me[/b]: away from terminals the top bar shows the nearest terminal or ATM's direction and distance; Guide me shows a golden arrow that stops on arrival (or press Stop). Without remote opening, the hotkey or toolbar icon points the arrow instead.
[*] [b]On the map[/b]: the server remembers map ATMs in areas it has loaded. With MiniMap, the minimap and world map show terminals and known ATMs; without it, the target is circled on the vanilla maps.
[*] [b]Protection[/b]: machine and catgirl terminals cannot be destroyed; players cannot remove registered cabinets or supported map ATMs.
[/list]

[h3]System shop[/h3]
[list]
[*] Buy at fixed server prices, with per-player or server-wide daily limits. The title bar shows today's sell-back allowance and limit reset; use each row's own button. The buy window shows the total, your balance after and whether it fits your bag; more under Details and limits.
[*] When buyback is enabled you can sell items as good as new back to the server; food only needs to be uneaten (cooked, burnt, frozen or stale is fine). The sell window lists the other copies it won't take and why. An entry the admin took off sale but still buys back shows "Buyback only": you can sell it, not buy it.
[*] Survivor Coin and Cat Coin prices are set per entry; each trade uses the currency you choose, and [b]no quote never means free[/b].
[/list]

[h3]Player market[/h3]
[list]
[*] At a terminal, press List an item to sell from your bag at a fixed price; identical items can go in one lot. The Browse, My listings and History tabs let you search, filter, sort and buy.
[*] [b]Drag items in[/b]: drag an item from your bag, a container or the floor onto the market, auction or shop page of the Economy Center to open the listing, auction or sell window with that item already picked. While you drag, the window says what will happen or why it cannot take the item. Items outside the top level of your main inventory are moved there first with the vanilla action.
[*] [b]Item right-click "Economy"[/b]: "List on the market", "Start an auction", and "Sell to the shop" for items the shop buys back. Unavailable entries are greyed out and explain why on hover.
[*] [b]Heavy items[/b] such as generators can be listed, auctioned or sold while held in both hands; a standing generator's right-click menu has the same entries and picks it up with the vanilla action first.
[*] Rows show the item's key state (condition, blade head, sharpness, ammo, charge, freshness, clothing holes…); click a row for its card, with condition and sharpness as bars and the Buy or Cancel listing button on the card.
[*] [b]Market price[/b]: when you list or start an auction, the price step shows how many sold in the last 30 days, the median per piece and the lowest to highest price. The server works this out about 3 minutes after it starts and every 6 hours after; until then it reads "Market price data is being prepared" and asks again by itself.
[*] The seller pays the sales tax; listing fees are not refunded; unsold listings return to your mailbox.
[*] One search box finds items and suggests sellers (a removable "Seller: name" filter). Tax and fee sit beside the title; Rules has the full text.
[/list]

[h3]Auction house[/h3]
[list]
[*] Choose a starting price and duration (6-72 hours by default).
[*] Bids reserve funds and being outbid releases them. The winner gets the items, the seller gets the price after tax, and unsold items return. Every auction has a bid history; My auctions and My bids are listed separately.
[*] Click an auction for its card: whether you lead, time left, the next minimum bid and what you hold, with the Bid (or Raise) and History buttons on the card.
[/list]

[h3]Mailbox[/h3]
[list]
[*] Purchases, wins, cancellations and returns arrive here; claim one by one or with "Claim all". The title bar shows Waiting and Slots.
[*] If your bag cannot take a whole letter, the pieces that fit are handed over and the rest waits; the message says how much room you need.
[*] Heavy items skip the bag: one per claim, straight into both hands. If your hands already hold a heavy item, the letter waits until you put it down.
[*] Unclaimed items survive your character's death. Unclaimed mail plus your listings and auctions count towards the mailbox limit.
[/list]

[h3]Rewards, seasons and leaderboards[/h3]
[list]
[*] [b]Daily online rewards[/b]: unlock with connected time that day; collecting late never delays the next one. A progress bar shows today's minutes; a gold "Ready" beside Rewards means one can be claimed.
[*] [b]Survival milestones[/b]: paid once per milestone per account per season, from one character's survival; a track shows reached and next milestones.
[*] [b]Holdings board[/b]: ranked per currency, with your rank on top and "Go to my rank"; by default only your own amount is shown exactly.
[*] [b]Survival board[/b]: the longest single life this season; finished seasons can be browsed.
[/list]

[h3]Market radio (server option)[/h3]
[list]
[*] Trade stations can broadcast text market summaries, shown in your own game language.
[*] Turn on a radio, walkie-talkie, world radio or car radio, pick "Market Radio" from the presets and press tune.
[*] Voice pickup is [b]off by default[/b].
[/list]

[h3]Interface and controls[/h3]
[list]
[*] Clicking a row opens a floating card (movable, copyable, as tall as its content); the row itself never buys, cancels or bids, so use the buttons on the row or the card. Item codes and IDs sit under Technical info at the bottom of the card.
[*] Full rules sit under each page's Rules button, one short heading and one line per rule.
[*] Keyboard (Tab, arrows, Enter, Esc) and controller (A, B, LB/RB) work on every page.
[/list]

[h3]Paid slots for other mods[/h3]
Supporting mods (Vehicle Manager first) can sell permanent or rented extra slots for economy currency; auto-renewal is opt-in and cancellable.

[h2]❓ FAQ[/h2]
[list]
[*] [b]Why are the buttons greyed out?[/b] You are not at a terminal; press Guide me and walk within 2 tiles of a map ATM or registered terminal on the same floor.
[*] [b]Why can't I list my item?[/b] Listing needs the server whitelist plus supported item types and state checks, so [b]not every modded item can be traded[/b]. The picker shows each item's category and why it is refused; ask an admin to open a closed category. Maps and live animals can never be listed; neither can rotten food, equipped or broken items, bags or key rings with something inside, written or locked notes, poisoned food, fertilized eggs, mixed fluids or devices holding a disc.
[*] [b]Why won't the shop buy my item?[/b] It only buys items as good as new: full condition, unused, never repaired, not renamed, clothing without holes or dirt; food only needs to be uneaten and not rotten. The sell window lists what it won't take and why.
[*] [b]Can I list clothing, watches, bags, keys or furniture?[/b] Yes, once the server opens their categories (watches are Accessories; bags, keys, furniture and pocket watches are closed by default). Holes, patches, blood, dirt, colour, alarms, key IDs, a padlock's key count and a lamp's bulb and colour are kept; empty bags and key rings first. Take clothing off first: the picker marks "Wearing" and "In hand". A patch sewn over a hole cannot be kept: remove it, or at Tailoring 8+ remove it and repair the hole with the same fabric.
[*] [b]Does food spoil while listed?[/b] Yes. Home-canned jars keep their shelf life, and added spices and food-sickness relief go with the food. Dishes made with added ingredients can be listed too; the market shows their ingredients.
[*] [b]It says "Identity not verified".[/b] The server checks your SteamID; another Steam account on this name, or split-screen players 2-4, cannot use the economy. By default a Steam account uses the economy with one login only (the first); your other logins are told so and keep their wallets. If it is yours, give an admin your Player ID.
[*] [b]The system took an item out of my bag?[/b] After a crash an older save can bring back items already listed, auctioned or sold. Once the trade is in a world save, the copy is taken back at login with a notice and a line in My market history; worn, hotbar and non-empty bag items are left alone. If it looks wrong, give an admin your Player ID.
[*] [b]I can't hear the market radio.[/b] Check the device is on, volume is not 0, the band fits and you are in range; after picking "Market Radio" press tune.
[*] [b]Can I use radio voice as private chat?[/b] No; nearby or lower-floor devices may hear it.
[*] [b]Why can't I find older records?[/b] Search covers loaded records only (latest 20 statement entries, up to 200 per month or market lookup).
[*] [b]My trade was refused: source could not be confirmed.[/b] The message lists the items and the next step (something you can do, a world save to wait for, or an admin case with your Player ID).
[*] [b]I paid for a slot but it is not active yet.[/b] Vehicle Manager slots work as soon as you pay. Other mods may wait for a save: their rentals start once the payment is confirmed as saved. A timeout only re-checks the order, never charges again.
[/list]

[h2]💬 How to report[/h2]
[list]
[*] [url=https://github.com/Minidoracat/MinidoracatEconomyFor42/issues]GitHub Issues[/url]: say which page, what you did and what message you saw; screenshots help.
[*] [url=https://discord.gg/Gur2V67]Discord community[/url]
[/list]
