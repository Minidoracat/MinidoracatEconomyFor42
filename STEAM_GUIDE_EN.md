<!-- 指南網址：https://steamcommunity.com/sharedfiles/filedetails/?id=3817846538 -->
<!-- Steam guide source (English): the full reference for this mod; the Workshop description only summarizes. Format and sync: pz-family-docs/release.md「完整說明：Steam 指南」 -->
<!-- 標題：📖 Economy Mod Guide: Player Features, Server Setup & Administration -->
<!-- 摘要：Illustrated guide to the Minidoracat Economy mod: wallet, transfers, terminals, shop, market, auctions, buy orders, mailbox, rewards and radio for players, plus deployment, the admin panel, server settings, permissions, player identity, companion and asset reconciliation for server owners. -->
=== 🚀 Quick start
[b]繁體中文版：[/b][url=https://steamcommunity.com/sharedfiles/filedetails/?id=3817846479]經濟系統 MOD 完整說明[/url]

The mod on Steam Workshop:
https://steamcommunity.com/sharedfiles/filedetails/?id=3801482125
[olist]
[*] [b]Open the Economy Center[/b] with the "[" key (rebindable in Key Bindings) or the coin icon in the family toolbar; the icon shows a count when your Mailbox has items to claim.
[*] [b]Find a terminal[/b]: away from a terminal you can only browse; the top bar shows the direction and distance of the nearest terminal or ATM, and [b]Guide me[/b] shows the way with a golden arrow.
[*] [b]Trade at a terminal[/b]: to trade, list or claim items, walk up to a map ATM or an admin-built terminal and right-click [b]Use economy terminal[/b].
[*] [b]Daily reward[/b]: claim your daily online reward on the Rewards page to start earning Survivor Coins.
[*] [b]Buy and sell[/b] in the shop, market or auctions; items arrive in your Mailbox and can be claimed at any terminal.
[/olist]
[b]Server owners[/b]: installation, permissions and external tools start at "⚙️ Deployment checklist".
=== 🧰 Wallet
{{img:01-economy-center-wallet-en.jpg}}
[list]
[*] [b]Two currencies[/b]: Survivor Coin and Cat Coin show available and reserved amounts; the server can rename them and change icons.
[*] [b]Player ID[/b]: your login account (not your character name) sits at the bottom of the navigation rail, red while unverified; click it to open the full account name and copy it, and give it to an admin when you need help.
[*] [b]Merged logins[/b]: logins of one Steam account that the server merged show "main account (login: current login)"; the wallet and records are one and the same.
[/list]
[h3]Statement[/h3]
[list]
[*] [b]Filters[/b]: one filter row (period, keyword, type, custom dates); click the Time or Amount column header to sort.
[*] [b]Notes[/b]: transfer fees and the sales tax taken on a sale follow the note; market and auction trades name the item ("Flashlight x1 · seller").
[*] [b]Card[/b]: click any line for its card: item, amount (green in, red out), time and balance after; the transaction ID sits under Technical info.
[*] [b]Slot payments[/b]: read "Entitlement purchase/renewal/refund" with the product name.
[/list]
[h3]Balance details and This month[/h3]
[list]
[*] [b]Balance details[/b]: can be read and copied in full.
[*] [b]This month[/b]: below it, this month's income and spending by type, with totals and shares.
[*] [b]How it counts[/b]: only this month's statement lines already loaded, on the available balance: a bid hold counts as spending, its refund when outbid as income.
[/list]
[h3]Slots[/h3]
[list]
[*] [b]Switch[/b]: the top of the wallet switches between Statement and Slots.
[*] [b]What it lists[/b]: the slots you bought or rent in other mods: how many you can use per product, how many are bought and rented, each lease's end and auto-renew.
[*] [b]History[/b]: the last 20 purchases, renewals and refunds; click one for its card.
[/list]
=== 🧰 Player transfers
A server option; it only appears once the server allows it.
[list]
[*] [b]Transfer button[/b]: the wallet page has a gold Transfer button that sends an enabled currency straight to another player.
[*] [b]At a terminal[/b]: by default it only works at a terminal or ATM; elsewhere the button is disabled and says where the nearest terminal is.
[*] [b]Before you confirm[/b]: after you fill in the recipient, amount and note, the screen shows the fee, the total charged, your balance afterwards and today's remaining limit; the confirm button spells out who gets how much.
[*] [b]Fee[/b]: paid by the sender on top of the amount.
[*] [b]Recipient[/b]: the box lists online players and recent recipients; for offline players type the full account name, matching case.
[*] [b]After sending[/b]: the recipient is notified, and the statement records it as Sent and Received. A resend never charges twice and [b]a sent transfer cannot be undone[/b].
[*] [b]Limits[/b]: per-transfer and daily limits, and how many days a new account waits before sending, are set by the server.
[/list]
=== 🧰 Economy terminals
[list]
[*] [b]Map ATMs[/b]: vanilla floor and wall ATMs work within 2 tiles on the same floor, no registration needed (the server can turn this off).
[*] [b]Custom terminals[/b] (machine, catgirl or supported cabinets): registered by an admin as an ATM or a trade station; only trade stations have the market radio.
[*] [b]One shared market[/b]: list at station A, someone buys at station B, you collect at station C. The server sets the rules for remote use.
[/list]
[h3]Guide me[/h3]
{{img:07-nearest-terminal-en.jpg}}
[list]
[*] [b]Direction and distance[/b]: away from terminals the top bar shows the nearest terminal or ATM's direction and distance (and whether it is upstairs or downstairs).
[*] [b]Guide me[/b]: shows a golden arrow that stops on arrival (or press Stop).
[*] [b]Without remote opening[/b]: the hotkey or toolbar icon outside a terminal points the arrow at the nearest one instead.
[*] [b]Trade blocked[/b]: a "not at a terminal" message also gives the nearest terminal's direction.
[/list]
[h3]Terminals and ATMs on the map[/h3]
[list]
[*] [b]Known ATMs[/b]: the server remembers map ATMs in areas it has loaded and counts them among the nearest places; the more ground players cover, the more ATMs it knows.
[*] [b]With MiniMap[/b]: the minimap and world map show registered terminals and known ATMs, with the guide target highlighted.
[*] [b]Without MiniMap[/b]: the guide target is circled on the vanilla world map and minimap.
[*] [b]Map icon settings[/b]: with the latest MiniMap, the minimap gear's [b]Map Display Settings[/b] has an [b]Economy Center[/b] category under Add-ons: turn terminal and ATM icons on or off separately for the minimap and the world map, and change their size.
[*] [b]Guide target[/b]: not affected by these settings; it is always drawn.
[/list]
[h3]Protection[/h3]
[list]
[*] [b]Machine and catgirl terminals[/b]: cannot be destroyed by zombies, weapons, animals or fire.
[*] [b]Cabinets and map ATMs[/b]: players cannot remove registered cabinets or supported map ATMs; only admins can.
[*] [b]Not covered[/b]: map ATMs are not protected from fire, explosions or removal by other mods, and ATMs already removed are not put back.
[/list]
=== 🧰 System shop
{{img:02-shop-buy-dialog-en.jpg}}
[list]
[*] [b]Fixed prices[/b]: buy at fixed server prices, with per-player or server-wide daily limits.
[*] [b]Title bar[/b]: shows today's sell-back allowance and the countdown to the limit reset.
[*] [b]Buying and selling[/b]: use each row's own button; entries that ran out show "Sold out".
[*] [b]Buy window[/b]: shows only the quantity, total, your balance after and whether it fits your bag; specs and limits are under Details and limits.
[*] [b]Currencies[/b]: Survivor Coin and Cat Coin sell and buyback prices are set per entry; each trade uses the currency you choose, and [b]no quote never means free[/b].
[/list]
[h3]Selling back (buyback)[/h3]
[list]
[*] [b]As good as new[/b]: when buyback is enabled you can sell items as good as new back to the server.
[*] [b]Food[/b]: only needs to be uneaten (cooked, burnt, frozen or stale is fine).
[*] [b]Sell window[/b]: lists how many other copies in your bag it won't take and why.
[*] [b]Buyback only[/b]: an entry the admin took off sale but still buys back shows "Buyback only" with its buyback price: you can sell it, not buy it.
[/list]
[h3]Name on delivery[/h3]
[list]
[*] Some entries have a name set by the server (for example a loot box renamed by another mod).
[*] The row shows that name first with the item's own name below.
[*] The item you get carries it, and it sells back to the same entry.
[/list]
=== 🧰 Player market
{{img:03-market-browse-en.jpg}}
[h3]Listing and browsing[/h3]
[list]
[*] [b]List[/b]: at a terminal, press List an item (top right) to sell from your bag at a fixed price; identical items can go in one lot.
[*] [b]Tabs[/b]: Browse, My listings and History let you browse, search, filter, sort and buy every listing on the server.
[*] [b]Rows[/b]: show the item's key state (condition, blade head, sharpness, ammo, charge, freshness, clothing holes…).
[*] [b]Card[/b]: click a row for its card, with condition and sharpness as bars and the Buy or Cancel listing button on the card.
[*] [b]Search[/b]: one search box finds items and sellers; item names work in your game language or in English.
[*] [b]One seller only[/b]: sellers are suggested as you type; pick one for a removable "Seller: name" filter. The same goes for auction, auction history and buy-order search.
[*] [b]Fees[/b]: the seller pays the sales tax; listing fees are not refunded; unsold listings return to your mailbox when they expire.
[*] [b]Rules[/b]: tax and fee sit beside the market title; the Rules button (top right) has the full text.
[/list]
[h3]Drag in or right-click[/h3]
[list]
[*] [b]Drag items in[/b]: drag an item from your bag, a bag you carry, a container or the floor onto the market, auction or shop page of the Economy Center to open the listing, auction or sell window with that item already picked.
[*] [b]While you drag[/b]: the window says what will happen or why it cannot take the item.
[*] [b]Items outside the top level of your main inventory[/b]: are moved there first with the vanilla action.
[*] [b]Item right-click "Economy"[/b]: "List on the market", "Start an auction", and "Sell to the shop" for items the shop buys back. Unavailable entries are greyed out and explain why on hover.
[*] [b]Heavy items[/b] such as generators can be listed, auctioned or sold while held in both hands; a standing generator's right-click menu has the same entries and picks it up with the vanilla action first.
[/list]
[h3]Market price[/h3]
[list]
[*] When you list or start an auction, the price step shows how many of the same item sold in the last 30 days, the median per piece and the lowest to highest price.
[*] The server works this out about 3 minutes after it starts and every 6 hours after.
[*] Until then it reads "Market price data is being prepared" and asks again by itself.
[/list]
[h3]Item names and special items[/h3]
[list]
[*] [b]Original names stay with the item[/b]: names the game gives an item (book titles, magazine and newspaper titles, photos, the name on a badge or dog tag, engraved rings and so on) are kept when listed; the row reads "Magazine (original title)" and the buyer gets that very copy.
[*] [b]Names given by other mods[/b] (such as loot box names): show as "Custom name: ...".
[*] [b]Row title[/b]: still the item's own name.
[*] [b]Kept out of the economy[/b]: some mods keep their items out; the picker says "This item can't be traded through the Economy (set by another mod)" and the item stays in your bag at no charge.
[*] [b]Every piece is different[/b] (such as a capsule holding a vehicle): these list on the market and at auction one per listing, the buyer gets that very piece with everything inside, and the row shows the mod's description. They can't be used in buy orders or sold to the shop.
[/list]
=== 🧰 Auction house
{{img:04-auction-en.jpg}}
[list]
[*] [b]Create[/b]: choose a starting price and duration (6-72 hours by default; the server can change the range).
[*] [b]Bids[/b]: reserve funds; being outbid releases them.
[*] [b]End[/b]: the winner gets the items, the seller gets the price after tax, and unsold items return.
[*] [b]Bid history[/b]: every auction has one.
[*] [b]My auctions and My bids[/b]: listed separately, each with a count.
[/list]
[h3]Auction card[/h3]
{{img:13-auction-card-en.jpg}}
[list]
[*] [b]It shows[/b]: whether you lead, time left, the next minimum bid and what you hold.
[*] [b]Buttons[/b]: Bid (or Raise) and History are on the card.
[/list]
=== 🧰 Buy orders
[h3]Creating a buy order[/h3]
[list]
[*] [b]Where[/b]: at a terminal open Buy orders, then Create buy order. Pick the item and quantity (up to 50).
[*] [b]Condition[/b]: Any condition, New only, or Durability at least a percentage; for tools with a head, such as axes, the lower of the body and the head counts.
[*] [b]Payment options[/b]: up to three: a price each in a currency, or one kind of item from your bag at so many per unit.
[*] [b]Held at creation[/b]: payment coins are held at once and payment items are taken from your main inventory.
[*] [b]Listing fee[/b]: each coin option pays the market listing fee once; item options are free.
[*] [b]Mailbox and limits[/b]: an open buy order takes one mailbox slot; how long it runs and how many you may have open depend on the server.
[/list]
[h3]Delivering[/h3]
[list]
[*] [b]Deliver[/b]: a seller opens an order on the Browse tab of Buy orders at a terminal, picks one payment option and delivers, in parts if they like.
[*] [b]Tax[/b]: coins pay the market sales tax; items do not.
[*] [b]Mailed[/b]: delivered goods are mailed to the buyer, even if the buyer is offline or their mailbox is full.
[/list]
[h3]Asks and raises[/h3]
[list]
[*] [b]Ask more[/b]: if the price is too low, a seller can press Ask more on a coin option with a price each, a quantity and a note (up to 64 characters); it costs nothing and holds no items.
[*] [b]Buyer's answer[/b]: the buyer is told and can Raise to this or Ignore.
[*] [b]Raise[/b]: only goes up, applies to every seller, tops up the held money, and the extra amount pays the listing fee rate.
[*] [b]Limit[/b]: at most 10 asks per order, one per seller.
[/list]
[h3]Closing and records[/h3]
[list]
[*] [b]Closing[/b]: an order ends when it is filled, cancelled or expired. Unused held money goes back to your wallet, payment items are mailed back, and the listing fee is not refunded.
[*] [b]Cancelling[/b]: asks you to confirm (Keep order / Cancel order).
[*] [b]Your own order[/b]: you cannot deliver or ask on it.
[*] [b]Records[/b]: the History tab, Market - History, the wallet statement (created, deal, raised, hold released) and the mailbox all show them.
[/list]
=== 🧰 Mailbox
{{img:10-mailbox-en.jpg}}
[list]
[*] [b]What arrives[/b]: purchases, wins, cancellations and returns; claim one by one or with "Claim all".
[*] [b]Bag too full[/b]: the pieces that fit are handed over and the rest waits in the letter until you make room; the message gives each piece's weight and how much room you need.
[*] [b]Heavy items[/b]: skip the bag: one per claim, straight into both hands. If your hands already hold a heavy item, the letter waits until you put it down.
[*] [b]Death[/b]: unclaimed items survive your character's death.
[*] [b]Limit[/b]: the mailbox has a slot limit; unclaimed mail plus your listings, auctions and open buy orders count towards it. The title bar shows Waiting and Slots, and turns red when full.
[/list]
=== 🧰 Rewards, seasons and leaderboards
{{img:05-rewards-milestones-en.jpg}}
[list]
[*] [b]Daily online rewards[/b]: unlock with connected time that day; how many and the thresholds are set by the server. Collecting late never delays the next one.
[*] [b]Progress[/b]: a progress bar shows today's online minutes and the threshold, and the claim button shows the amount; a gold "Ready" beside Rewards means one can be claimed.
[*] [b]Survival milestones[/b]: paid automatically, once per milestone per account per season, from one character's survival this season; a track shows reached milestones, the next one (days to go) and those after.
[/list]
[h3]Leaderboards[/h3]
{{img:11-leaderboard-en.jpg}}
[list]
[*] [b]Holdings board[/b]: ranked per currency; a card on top shows your rank and total holdings, with "Go to my rank".
[*] [b]Amounts[/b]: by default only your own amount is shown exactly; admins can make other players' amounts public.
[*] [b]Survival board[/b]: the longest single life this season, lives not added together; finished seasons can be browsed.
[/list]
=== 🧰 Market radio
A server option.
[list]
[*] [b]Broadcasts[/b]: trade stations can broadcast text market summaries (listings, sellers, newest items), shown in your own game language.
[*] [b]Listening[/b]: turn on a radio, walkie-talkie, world radio or car radio, pick "Market Radio" from the presets and press tune. It doesn't take one of your own presets.
[*] [b]Voice pickup[/b]: [b]off by default[/b]; the server has to turn it on.
[/list]
=== 🧰 Interface and controls
[list]
[*] [b]Cards[/b]: clicking a row opens a floating card (movable, copyable, as tall as its content).
[*] [b]No misclicks[/b]: the row itself never buys, cancels or bids, so use the buttons on the row or the card.
[*] [b]Technical info[/b]: item codes and IDs sit at the bottom of the card.
[*] [b]Rules[/b]: each page's description is one line; full rules (rates, limits, reset times, how things are calculated) sit under each page's Rules button (top right), one short heading and one line per rule.
[*] [b]Keyboard and controller[/b]: every page works with the keyboard (Tab switches areas, arrows pick rows, Enter opens details, Esc closes) and a controller (A confirms, B goes back, LB/RB switch tabs).
[*] [b]Remembered[/b]: window position, size and preferences are remembered.
[/list]
[h3]Hide the Economy Center button[/h3]
[list]
[*] [b]Shown by default[/b]: the button is the coin icon in the family toolbar, or a floating button without one.
[*] [b]Hide it[/b]: untick [b]Show Economy Center button[/b] under Options > MODS > Minidoracat Economy and apply: it disappears at once and stays hidden after respawning or rejoining; tick it again to bring it back.
[*] [b]While hidden[/b]: open the Economy Center with its hotkey, rebindable under Options > Key Bindings (default "[" key).
[/list]
=== 🧰 Paid slots for other mods
[list]
[*] [b]Buy or rent[/b]: supporting mods (Vehicle Manager first) let you buy permanent or rent periodic extra slots with economy currency.
[*] [b]Auto-renewal[/b]: off by default; it needs your consent and can be cancelled anytime.
[*] [b]Frozen[/b]: if the server removes the mod that provides your slots and that mod supports freezing, your rental shows as frozen and its time stops, with no rent charged; once the mod is back it continues from the time it had left.
[*] [b]Your slots[/b]: see Slots under "Wallet".
[/list]
=== ⚙️ Deployment checklist
[b]Dedicated multiplayer servers only; single-player and Host / co-op are not supported.[/b]
[olist]
[*] [b]Enable the mods[/b]: MinidoracatUIFor42 and MinidoracatEconomyFor42, UI Library first (Workshop IDs 3789836701 / 3801482125). UI Library needs API rev 11 or later; with an older one the economy interface won't open.
[*] [b]Same versions[/b]: keep server and all clients on the same versions; fully restart both after each update.
[*] [b]World saves[/b]: set a suitable world save interval and always shut down normally.
[*] [b]companion[/b]: deploy it on the server host (see "World saves and companion") so item transfers settle and player identities import automatically.
[*] [b]Review settings[/b]: in game, press Admin in the Economy Center to open [b]Economy Administration[/b] (it opens on Overview) and review each Settings tab and the authorized roles.
[/olist]
=== ⚙️ Admin overview
{{img:08-admin-overview-en.jpg}}
[h3]Needs attention[/h3]
[list]
[*] [b]Only problems[/b]: assets to reconcile, identity conflicts and new alerts, save confirmation, ledgers, shop catalog, whitelist, held listings and auctions, conservation gaps.
[*] [b]Straight to the fix[/b]: each has a button to the page that fixes it; otherwise it reads "Nothing needs attention right now".
[/list]
[h3]Sidebar[/h3]
[list]
[*] [b]Six groups[/b]: Overview, Players, Market and shop, Money and audit, Currencies & mods, Server.
[*] [b]Red counts[/b]: Reconciliation and Identity show how many items are waiting.
[/list]
[h3]Last 7 days and currencies[/h3]
[list]
[*] [b]Last 7 days[/b]: charts daily issuance (check-ins, milestones, buyback, other) and removal with a net line, with 7-day issuance, removal and net change on the right.
[*] [b]Scope[/b]: system issuance only (not integrations, Discord deposits or admin adjustments).
[*] [b]Click a day[/b] for that day's transactions, or Full report for Reports.
[*] [b]Currencies at a glance[/b]: each currency's player holdings, reserves, today's issuance, conservation gap and holders; the Full supply table has the rest.
[*] [b]Help[/b]: each page's long explanations are tucked under Help.
[/list]
=== ⚙️ Reports and transactions
{{img:12-admin-reports-en.jpg}}
[h3]Reports[/h3]
[list]
[*] [b]Where[/b]: Money and audit - Reports, read-only roles included.
[*] [b]Period and currency[/b]: 7 days, 30 days, this season or a custom range (up to 60 days, counted in reward days), plus a currency.
[*] [b]First[/b]: inflow, outflow, net change, player trade volume and active traders, each with a trend and a comparison with the previous period of the same length.
[*] [b]Then[/b]:
[list]
[*] daily inflow and outflow bars, coloured by source, with a net line
[*] money supply
[*] wealth distribution
[*] totals by source
[*] top items (trades, value, median per piece, price range, 14-day trend)
[*] shop sales (shares sold, revenue, days sold out, buyback cap used)
[/list]
[*] [b]Click a bar, a source or an item[/b] to open the matching transactions.
[/list]
[h3]Where the numbers come from[/h3]
[list]
[*] [b]Daily figures[/b]: share the existing daily issuance record (kept 60 days, anonymous numbers only).
[*] [b]Breakdown by type[/b]: starts with 0.10.0, so earlier days show only issuance and removal totals; today and incomplete days are hatched.
[*] [b]Top items, prices and active traders[/b]: the server works them out from the last 30 days of event files, about 3 minutes after it starts and every 6 hours after, or on Regenerate (at most once a minute). They live in memory and are rebuilt after a restart.
[*] [b]Players' market price[/b]: the 30-day price players see when listing only reads that result; nothing a player does makes the server recount.
[/list]
[h3]Transactions[/h3]
[list]
[*] [b]Totals row[/b]: covers every matching record (not just the 200 listed, rolled-back ones excluded).
[*] [b]Each line[/b]: amounts are coloured and signed by direction, and the second line reads "payer -> payee · fee or tax".
[*] [b]Record card[/b]: lists every posting with balances before and after, with shortcuts to one account's or one item's transactions. Admin record cards open with Technical info expanded.
[/list]
=== ⚙️ Server settings and buy orders
[list]
[*] [b]Live changes[/b]: rewards, admin limits, coins and deposits, system shop, market, auctions, market radio, player transfers, seasons and more are changed live under Economy Administration - Settings, and every change is audited.
[/list]
[h3]Buy orders[/h3]
[list]
[*] [b]Per player[/b]: Settings has "Max buy orders per player" (0-50, default 5, 0 = players cannot post).
[*] [b]Market options reused[/b]: duration, listing fee, sales tax and the price limits come straight from the market options; there are no separate ones.
[*] [b]Server limit[/b]: at most 500 buy orders at once; when full, players see "The server has no room for more buy orders".
[*] [b]Mailbox[/b]: each open buy order takes one mailbox slot of its owner.
[/list]
[h3]Admin "Buy orders" tab[/h3]
[list]
[*] [b]Where[/b]: Market and shop; search by item or buyer and see each order's payment options and held amounts.
[*] [b]Force cancel[/b]: needs a reason and leaves an audit entry; held money and items go back as usual and the buyer is notified.
[*] [b]Refund failed[/b]: the order stops taking deliveries, the server retries every minute, and Needs attention on the Overview reminds you.
[*] [b]Counter-offer notes[/b]: not kept in the world save; they live only in wanted-memos.json in the server data folder, so backing up that folder backs them up too.
[/list]
=== ⚙️ Shop entries
{{img:09-admin-shop-editor-en.jpg}}
[h3]Shop catalog and Listing whitelist[/h3]
[list]
[*] [b]Files[/b]: catalog.json (shop) and whitelist.json (Listing whitelist) are in the server data folder; panel edits are written back and pushed to online players.
[*] [b]Hand edits[/b]: press Reload on the matching page first.
[*] [b]Independent[/b]: adding a shop entry does not loosen the player market's listing rules.
[*] [b]Drag and right-click[/b]: drag an item from your bag onto the admin Shop page to create an entry, or onto the Listing whitelist page to pick it for a rule; the item right-click "Economy" menu has "Add as a shop item" and "Add a whitelist rule" too.
[/list]
[h3]Managing entries[/h3]
[list]
[*] [b]Delete[/b]: one at a time or several at once; entries leave the catalog only after you give a reason, and sent mail and transaction records are kept.
[*] [b]Re-adding[/b]: the same ID continues its purchase counts.
[*] [b]Delisting[/b]: only stops sales: also turn off buyback, or delete the entry, to retire it.
[*] [b]Entry cap[/b]: under Settings - System shop (default 200, up to 1000).
[*] [b]Buyback[/b]: takes only items as good as new; food only needs to be uneaten (cooked, burnt, frozen or stale is fine).
[*] [b]Cat Coin buyback limits[/b]: default to 0 (off); raise them explicitly to allow it.
[/list]
[h3]Name on delivery[/h3]
[list]
[*] [b]What it does[/b]: an entry can carry a name (up to 48 characters) that the bought item gets; the shop row shows it first with the item's own name below, and items with that name sell back to the entry. Leave it empty for the item's own name.
[*] [b]Filled in for you[/b]: dragging a renamed item (such as a loot box renamed by another mod) onto the Shop page, or adding it from its right-click menu, fills the name in.
[*] [b]Liquid containers[/b] (water bottles, gas cans): cannot have one; the game always shows the container and its liquid there.
[/list]
[h3]Shop drafts sent by other mods[/h3]
[list]
[*] [b]Source[/b]: supporting mods (such as the Map Watch mod) can hand their items to the Shop page.
[*] [b]One draft at a time[/b]: when an admin presses that mod's listing button, the admin panel opens on the Shop page and each item the shop does not sell yet becomes a new entry draft: fill in the price and press Apply changes to list it and open the next, or Cancel to skip it.
[*] [b]No duplicates[/b]: items already in the shop are skipped; the page lists what was skipped.
[*] [b]Drafts only[/b]: it never lists or prices anything by itself; players without admin rights get nothing.
[/list]
=== ⚙️ Listing whitelist
[h3]Categories closed by default[/h3]
[table]
[tr][th]Items[/th][th]Categories to open[/th][/tr]
[tr][td]Clothing[/td][td]Clothing, ProtectiveGear, Accessory[/td][/tr]
[tr][td]Bags[/td][td]Bag, Container[/td][/tr]
[tr][td]Keys[/td][td]Security[/td][/tr]
[tr][td]Picked-up furniture[/td][td]Furniture[/td][/tr]
[tr][td]Pocket watches[/td][td]Memento[/td][/tr]
[/table]
[list]
[*] [b]Open by default[/b]: the categories holding placed alarm clocks (Household), hollow books (Literature) and the few movables in Camping, Gardening and Material, so they become listable with 0.7.0; exclude them in the whitelist if you don't want that.
[*] [b]Never listable[/b]: maps and live animals, whatever the whitelist says.
[*] [b]Empty first[/b]: bags and key rings must be empty.
[/list]
[h3]Items marked by other mods[/h3]
[list]
[*] [b]Kept out of trading[/b]: a mod can keep its item types out of every player trade (listing, auction, buy orders, selling to the shop) regardless of the whitelist; shop deliveries and mail still work.
[*] [b]Every piece is different[/b]: a mod can also register such items (such as a capsule holding a vehicle): they trade one per listing on the market and at auction with their contents, ignore whitelist category rules, but types you exclude still can't be listed; buy orders and shop buyback always refuse them.
[*] [b]Mod not loaded[/b]: mail carrying such an item stays in the mailbox until it is.
[/list]
=== ⚙️ Player transfer settings
[list]
[*] [b]Off by default[/b]. Settings - Player transfers has:
[list]
[*] the master switch
[*] sending away from a terminal or ATM (off by default)
[*] the fee (default 5%, paid by the sender on top and burned in full)
[*] per-transfer minimum and maximum, and a daily sending limit per player
[*] the wait before new accounts can send (default 3 days; accounts that existed before the update are exempt)
[/list]
[*] [b]Currencies[/b]: besides the master switch, enable each transferable currency on the Currencies page; currencies that Discord points can be exchanged into show a reminder.
[*] [b]Other mods[/b]: other mods can transfer for players too, but each one must be allowed separately on the Integration sources page.
[/list]
=== ⚙️ Terminal and market radio settings
{{img:06-terminal-menu-en.jpg}}
[h3]Map ATMs[/h3]
[list]
[*] [b]Two settings[/b]: Settings - General has "Use map ATMs as terminals" (on by default) and "Allow players to remove map ATMs" (off by default); they are independent.
[*] [b]Protection scope[/b]: it does not cover fire, explosions or removal by other mods, and ATMs already removed are not put back.
[*] [b]Remembered ATMs[/b]: when on, the server remembers map ATMs in areas it has loaded; players' Guide me counts them among the nearest places and, with MiniMap, they show on the minimap and world map.
[*] [b]Removed ATMs[/b]: skipped when a player loads that square.
[/list]
[h3]Custom terminals[/h3]
[list]
[*] [b]Building[/b]: machine and catgirl styles sit in the build menu's Furniture category; only terminal admins (on an admin role list and with the native add-item permission) can see, build and remove them.
[*] [b]Indestructible[/b]: zombies, weapons, animals and fire cannot destroy them.
[*] [b]Registering[/b]: once placed, right-click "Register as economy terminal (ATM, no radio)" or "Register as economy terminal (trade station, with market radio)"; both trade the same, only the radio differs.
[*] [b]Switching[/b]: "Remove terminal registration" first, then register again; no need to rebuild.
[*] [b]Vanilla cabinets[/b]: once registered, players cannot remove, move or dismantle them, but they can still burn; for full protection use a custom terminal.
[/list]
[h3]Market radio[/h3]
[list]
[*] [b]Market summaries[/b]: trade stations broadcast them on a timer, each player seeing their own game language (the old "market radio language" setting is gone); interval 0 stops only the summary. ATMs never broadcast.
[*] [b]Voice pickup[/b]: "Trade station voice pickup" under Settings - Market radio is [b]off by default[/b].
[*] [b]Once on[/b]: it still needs server voice chat enabled and follows each player's push-to-talk or voice activation; nearby and lower-floor devices may hear it, so it is not private chat.
[*] [b]Not fully tested yet[/b]: general chat relay and the various distance cases.
[/list]
[h3]Before removing this mod[/h3]
[list]
[*] Unregister each trade station while its area is loaded, check its speaker is gone, then save normally.
[*] Just disabling the mod runs no cleanup.
[/list]
=== ⚙️ Permissions
Three separate role lists, picked from the server's native roles, custom roles included:
[table]
[tr][th]List[/th][th]Default[/th][/tr]
[tr][td]Write access[/td][td]admin[/td][/tr]
[tr][td]Read-only[/td][td]moderator[/td][/tr]
[tr][td]Self-adjustment[/td][td]none[/td][/tr]
[/table]
[list]
[*] [b]Adjustments[/b]: need a reason and respect version checks and limits (per transaction, per admin per day, server-wide per day), each one audited.
[*] [b]Role management needed[/b]: changing the role lists, admin limits and seasons also needs native role-management permission; economy write access alone is not enough.
[*] [b]Your own balance[/b]: not allowed by default; your role must be on both the write-access and self-adjustment lists.
[/list]
=== ⚙️ Player identity and merging
[h3]Identity check[/h3]
[list]
[*] [b]Steam servers[/b]: a name acts as its account only when its SteamID matches; otherwise it gets no wallet, trades or notices and sees "Identity not verified, please contact an administrator".
[*] [b]No-steam servers[/b]: only split-screen is blocked.
[*] [b]Split-screen[/b]: players 2-4 cannot use the economy; to keep split-screen off the server entirely, set AllowCoop=false in the server settings.
[/list]
[h3]Automatic binding[/h3]
[list]
[*] [b]When[/b]: at a player's first login and at character creation; a suspected impersonation is not bound and online admins are alerted at once.
[*] [b]With companion[/b]: the server whitelist is read in automatically, binding every account in one go.
[*] [b]Without companion[/b]: press Import identities on Admin - Identity.
[*] [b]Conflicts[/b]: a name bound to another SteamID becomes a conflict, never rebound automatically; only if the owner really changed Steam accounts, use Confirm rebinding on the Identity page with a reason.
[/list]
[h3]One economy account per Steam account[/h3]
[list]
[*] [b]Default[/b]: a Steam account can use one economy account; other logins are told so, their wallets and assets untouched.
[*] [b]Main account[/b]: the first login; after a whitelist import, the one that used the economy first.
[*] [b]Allow several[/b]: enable "Allow several economy accounts per Steam account" in Settings (role-management permission).
[*] [b]Multi-account list[/b]: the Identity page lists every login with its main account, whether it can use the economy and its merge state; searchable and filterable.
[/list]
[h3]Merging[/h3]
[list]
[*] [b]What merges[/b]: logins of one Steam account can merge into one economy account: money, today's claims, daily limits and unclaimed mail go to the main account.
[*] [b]Preview only by default[/b]: review the plan on the Identity page, then enable "Merge the login names of one Steam account" in Settings (role-management permission).
[*] [b]Waits until clear[/b]: a login that is online, frozen, or still has listings, auctions or mail in delivery is merged once that is settled.
[*] [b]Buy orders[/b]: a login with an open buy order cannot merge; cancel it or wait until it closes.
[/list]
=== ⚙️ Seasons and integration plans
[h3]Seasons[/h3]
[list]
[*] [b]View[/b]: Admin - Seasons shows current and past seasons.
[*] [b]Set up[/b]: with native role-management permission, set the season length (real days, 0 = manual) or start the next season with a reason.
[*] [b]New season[/b]: the old season's results are archived; balances and characters are kept.
[/list]
[h3]Integration plans[/h3]
[list]
[*] [b]Who sets prices[/b]: each mod sets the price, currency, limits and rental period of its own paid slots (Vehicle Manager: its settings file and in-game settings window).
[*] [b]Plans[/b]: read-only; shows each product's current terms, where they were last changed and any settings file error.
[*] [b]Accounts & refunds[/b]: lists every player's slot orders, newest first; click an order to see only that player.
[*] [b]Refunds[/b]: an order that can be refunded has its own Refund... button, and the confirmation says how much goes back to whom and what happens to the slots or rental.
[/list]
[h3]Removing a mod that provides slots[/h3]
[list]
[*] [b]Freeze when absent[/b]: a mod can register its slots this way. If such a product has not shown up about 1 minute after the server starts, its rentals stop where they are: no expiry, no rent charged, no reminders, and auto-renew consent is kept.
[*] [b]Where you see it[/b]: Accounts & refunds shows those rentals as frozen with the time left, and the Audit page records the freeze and the resume.
[*] [b]Mod back[/b]: each rental continues from the time it had left.
[*] [b]Mods that did not choose this[/b]: their rentals keep their original end time while the mod is gone, they are just not charged.
[*] [b]Crash rollback[/b]: freeze time since the last save can be undercounted.
[/list]
=== ⚙️ World saves and companion
[h3]World saves[/h3]
[list]
[*] [b]Transfers settle on the world save[/b]: with a save interval of 0 there are no regular world saves, and player saves do not replace them.
[*] [b]Server settings untouched[/b]: this mod never changes server settings by itself or forces extra saves; back up and restore with your host's tools.
[/list]
[h3]companion[/h3]
[list]
[*] [b]What it is[/b]: a Node 24 tool shipped with the source; it [b]does not run with a Workshop subscription[/b]. Deploy it on the server host.
[*] [b]Save confirmation[/b]: it reports stable world saves as "save confirmation", which item transfers need to settle.
[*] [b]Identity import[/b]: it exports the server whitelist to the economy so player identities import automatically.
[*] [b]Deploy and update together[/b]: run it for normal operation, and update it whenever you update this mod.
[*] [b]Without it[/b]: records waiting for confirmation pile up, and once the protection limit is hit new item movement pauses.
[/list]
[h3]Deploying[/h3]
[olist]
[*] Put the companion folder from the GitHub source on the server host and install Node.js 24 or later.
[*] Copy .env.example to .env and set:
[list]
[*] ZOMBOID_DIR: the same data folder as the game server (empty = the current user's Zomboid folder)
[*] SERVER_NAME: must match the server name; the identity export checks it
[/list]
[*] In the companion folder run npm install, then keep npm start running.
[*] Back in Economy Administration, check save confirmation on the System page and that the whitelist export was accepted on the Identity page.
[/olist]
[h3]Daily report[/h3]
[list]
[*] [b]npm run report[/b]: writes the previous day's cash-flow report (npm run report -- --date 2026-09-13 for a given date); run it by hand or from a host scheduler.
[*] [b]Read-only[/b]: it calls no AI and changes no accounts.
[*] [b]Access[/b]: the report contains player accounts and admin reasons, so restrict access to the file.
[/list]
=== ⚙️ Discord point deposits
[list]
[*] [b]Not subscribe-and-go[/b]: the game and companion provide the interface and order flow, but you need your own external points system, linking to Steam accounts, and your own bridge deployed.
[*] [b]Not needed for trading[/b]: basic in-game trading needs no Discord.
[/list]
=== ⚙️ Asset reconciliation
[list]
[*] [b]Pending, not guessed[/b]: with incomplete source or save evidence the system keeps a pending entry rather than reissuing or deleting.
[*] [b]Server-wide overview[/b]: Admin - Reconciliation can recheck the whole server and resolve one by one or in batches (Ctrl/Shift); each needs a reason and is re-verified. Read-only roles can only view.
[*] [b]Never clear by hand[/b]: check companion, world saves and the save confirmation status on the System page first.
[/list]
[h3]Crash duplicates[/h3]
[list]
[*] [b]How it happens[/b]: when the world save is newer than a player save, the older save can bring back items already listed, auctioned or sold to the system, possibly already passed to someone else.
[*] [b]Taken back[/b]: once the trade is in a world save, the copy is taken back at the holder's login with a notice, and each piece leaves a SYSTEM line in Audit (noting it when the original trader is not the holder).
[*] [b]Left pending[/b]: worn, hotbar and non-empty bag items, or two pieces with the same ID.
[/list]
[h3]Restore[/h3]
[list]
[*] [b]How[/b]: select that Audit line, press Restore and give a reason; a copy rebuilt as it was when reclaimed is mailed to the holder.
[*] [b]Limits[/b]: once per reclaim; only the latest 200 are kept.
[*] [b]Only real mistakes[/b]: the original still exists in the world, so [b]restore only real mistakes[/b], or there will be one extra.
[/list]
[h3]Crashes and buy orders[/h3]
[list]
[*] [b]Not rebuilt from player saves[/b]: items held in an order or in transit are mailed back to their owners, and money follows the world save.
[*] [b]Discard only[/b]: for held buy-order records, Reconciliation can only discard, not restore (same as system buyback).
[*] [b]Mailed back by itself[/b]: anything the system can prove.
[/list]
=== ⚠️ Known limits
[list]
[*] [b]Dedicated multiplayer servers only[/b]: single-player and Host / co-op are not supported.
[*] [b]Not every modded item can be traded[/b]: listing needs the server whitelist plus supported item types and state checks.
[*] [b]Protection has limits[/b]: map ATMs are not protected from fire, explosions or removal by other mods, and removed ATMs are not put back; registered vanilla cabinets can still burn.
[*] [b]Radio voice[/b]: not private chat; general chat relay and the various distance cases are not fully tested yet.
[*] [b]No backup feature[/b]: this mod never changes server settings by itself or forces extra saves; back up with your host's tools.
[*] [b]Disabling runs no cleanup[/b]: unregister trade stations first, see "Terminal and market radio settings".
[*] [b]Freeze time[/b]: after a crash rollback, freeze time since the last save can be undercounted.
[/list]
=== ❓ FAQ
[h3]Why are the buttons greyed out, browse only?[/h3]
[list]
[*] You are not at a terminal. The top of the Economy Center says where the nearest one is; press Guide me and follow the golden arrow.
[*] Within 2 tiles of a map ATM or registered terminal on the same floor, the window lets you trade.
[/list]
[h3]Why can't I list my item?[/h3]
[list]
[*] Listing needs the server whitelist plus supported item types and state checks, so [b]not every modded item can be traded[/b]. The picker shows each item's category and why it is refused; ask an admin to open a closed category.
[*] Maps and live animals can never be listed, whatever the whitelist; neither can rotten food, equipped or broken items, bags or key rings with something inside, written or locked notes and paper, poisonous or poisoned food, fertilized eggs, containers with more than one fluid, or devices holding a disc or tape.
[*] The listing picker's verdict is what counts; it explains why and what to do.
[/list]
[h3]Why won't the shop buy my item?[/h3]
[list]
[*] It only buys items as good as new: full condition, unused, never repaired, not renamed, clothing without holes or dirt; food only needs to be uneaten and not rotten.
[*] The sell window lists how many it won't take and why.
[/list]
[h3]Can I list clothing, watches, bags, keys or furniture?[/h3]
[list]
[*] Yes, once the server opens their categories in the whitelist (watches are Accessories; bags, keys, furniture and pocket watches are closed by default).
[*] Holes, patches, blood, dirt, wetness, colour, alarm settings, key IDs, a padlock's key count and a lamp's bulb and colour reach the buyer as they are; empty bags and key rings first.
[*] Take clothing off first: the picker marks "Wearing" and "In hand". A patch sewn over a hole cannot be kept: remove it, or at Tailoring 8+ remove it and repair the hole with the same fabric.
[/list]
[h3]Does food spoil while listed?[/h3]
[list]
[*] Yes. Perishable food keeps spoiling while held by the market.
[*] Home-canned jars keep their shelf life, and added spices and food-sickness relief go with the food.
[*] Dishes made with added ingredients can be listed too; the market shows their ingredients.
[/list]
[h3]It says "Identity not verified"?[/h3]
[list]
[*] The server checks your SteamID; another Steam account on this name, or split-screen players 2-4, cannot use the economy.
[*] By default a Steam account uses the economy with one login only (the first); your other logins see their own explanation and keep their wallets.
[*] If it really is your account, give an admin your Player ID.
[/list]
[h3]The system took an item out of my bag?[/h3]
[list]
[*] After a server crash an older save can bring back items already listed, auctioned or sold (even ones passed to someone else). Once the trade is in a world save, the copy is taken back at the holder's login with a notice and a line in My market history.
[*] Worn, hotbar and non-empty bag items are left alone for now.
[*] If it looks wrong, give an admin your Player ID; admins can restore it.
[/list]
[h3]I can't hear the market radio?[/h3]
[list]
[*] Check the device is on, volume is not 0, the band fits and you are in range.
[*] After picking "Market Radio" press tune to switch over.
[*] When the server changes the frequency the preset list updates, but the channel you are tuned to doesn't switch by itself.
[/list]
[h3]Can I use radio voice as private chat?[/h3]
[list]
[*] No. Voice follows vanilla radio limits: the server must enable voice, it sends by your push-to-talk or voice activation setting, and nearby and lower-floor devices may hear it.
[*] General chat relay and the various distance cases are not fully tested yet.
[/list]
[h3]Why can't I find older records?[/h3]
[list]
[*] Search covers loaded records only: the latest 20 statement entries, up to 200 per month lookup, and up to 200 market history records.
[*] The interface shows the range and never treats unloaded data as "no results".
[/list]
[h3]My trade was refused: source could not be confirmed?[/h3]
[list]
[*] The message lists the affected items and the next step, shown separately: something you can do (such as claiming first), a world save to wait for, or an admin check.
[*] If an admin is needed, give them the Player ID at the bottom of the navigation rail.
[/list]
[h3]I paid for a slot but it is not active yet?[/h3]
[list]
[*] Vehicle Manager slots work as soon as you pay.
[*] Other mods may wait for a save: the payment shows as accepted, waiting for save confirmation, or unknown, and the rental starts once the payment is confirmed as saved.
[*] A timeout only re-checks the original order, never charges again.
[/list]
[h3]Server owners: players say the Economy Center won't open?[/h3]
[list]
[*] Make sure UI Library is up to date (API rev 11 or later).
[*] Server and clients must be on the same version and fully restarted.
[/list]
[h3]Server owners: a protection limit appeared and items cannot move?[/h3]
[list]
[*] Usually companion is not running or no world save has happened yet.
[*] Start it, wait for a normal save and check Needs attention on Overview or the System page.
[/list]
[h3]Server owners: a player sees "Identity not verified"?[/h3]
[list]
[*] Check the conflict list and identity alerts on Admin - Identity; use Confirm rebinding only if the owner really changed Steam accounts.
[*] A second login of one Steam account cannot use the economy by default.
[*] Borrowed login names and split-screen players never can.
[/list]
[h3]Server owners: a new shop item still can't be listed?[/h3]
[list]
[*] Shop catalog and Listing whitelist are separate lists; allow it on the Listing whitelist page as well.
[*] Only maps and live animals never can; other items depend on whether their category is open, and the player's picker names each item's category and why it is refused.
[/list]
[h3]Server owners: is there a backup feature?[/h3]
[list]
[*] No. Use your host's backup tools; economy data is saved with the world save.
[/list]
=== 💬 Feedback
[list]
[*] [b][url=https://github.com/Minidoracat/MinidoracatEconomyFor42/issues]GitHub Issues[/url][/b]:
[list]
[*] Players: say which page, what you did and what message you saw; screenshots help.
[*] Server owners: include the mod version, steps to reproduce and the server log lines containing MinidoracatEconomyFor42.
[/list]
[*] [b][url=https://discord.gg/Gur2V67]Discord community[/url][/b]
[/list]
