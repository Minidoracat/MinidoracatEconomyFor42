-- Economy Center window: lifecycle, controls, request state and cross-page coordination.
-- Rendering, reusable controls, filters, trade dialogs and preferences live in ECPanel* modules.
-- C.Panel remains the public entry used by the floating button and terminal menu.
require "ISUI/ISCollapsableWindow"
require "ISUI/ISLayoutManager"
require "MinidoracatEconomy/ECWidgets"
require "MinidoracatEconomy/ECKeyboard"
require "MinidoracatEconomy/ECDatePicker"
require "MinidoracatEconomy/ECNavigation"
require "MinidoracatEconomy/ECAdminPanel"
require "MinidoracatEconomy/ECAdminWindow"
require "MinidoracatEconomy/ECIconCache"
require "MinidoracatEconomy/ECPanelWidgets"
require "MinidoracatEconomy/ECRowActions"
require "MinidoracatEconomy/ECReadGate"
require "MinidoracatEconomy/ECPanelFilters"
require "MinidoracatEconomy/ECPanelDialogs"
require "MinidoracatEconomy/ECPanelPreferences"
require "MinidoracatEconomy/ECPanelLayout"
require "MinidoracatEconomy/ECDetailWindow"
require "MinidoracatEconomy/ECPlayerPicker"
require "MinidoracatEconomy/ECLeaderboard"

local EC = MinidoracatEconomy
local C = EC.Client
local U = C.UI
local DatePicker, Keys, Nav = C.DatePicker, C.Keyboard, C.Navigation
local W, FilterBar, R, ReadGate = C.PanelWidgets, C.PanelFilters, C.RowActions, C.ReadGate
local Dialogs, Preferences, Layout = C.PanelDialogs, C.PanelPreferences, C.PanelLayout
-- The one floating record window of the session: every read-only row of every page is spelled
-- out in it (ECDetailWindow), so no page keeps a preview band that eats its own table.
local Detail = C.DetailWindow
-- The one candidate box of the session, shared with the admin window: the market and the auction
-- browse pages each host one over the public market.sellers read.
local PlayerPicker = C.PlayerPicker
-- The public leaderboard is a page of its own module: this window is already at the debug
-- compiler's local ceiling, and a board that reads one public command needs none of its state.
local Leaderboard = C.Leaderboard
local P = {}
C.Panel = P

local LAYOUT_NAME = "MinidoracatEconomyPanel"
local MIN_WIDTH, MIN_HEIGHT = Layout.MIN_WIDTH, Layout.MIN_HEIGHT
local PAD, ROW, CHIP_H, T = U.PAD, U.ROW, U.CHIP_H, U.T
local fontH = U.fontH
local color, fill, text, textWidth = U.color, U.fill, U.text, U.textWidth
local stampText, durationText, amountText, signedText, hasBit, kindText = U.stampText, U.durationText, U.amountText, U.signedText, U.hasBit, U.kindText
local accountName, localOffsetMinutes, Button = U.accountName, U.localOffsetMinutes, U.Button
local entryText, setEntryText, itemTexture = U.entryText, U.setEntryText, U.itemTexture
local itemName = C.itemLabel
local iconButton = C.AdminWindow.iconButton
local BuyDialog, MarketDialog, AUCTION_MODES = Dialogs.BuyDialog, Dialogs.MarketDialog, Dialogs.AUCTION_MODES
local PrefsPopover, PREFS_W, opacityPercent = Preferences.PrefsPopover, Preferences.PREFS_W, Preferences.opacityPercent
local defaultSize = Layout.defaultSize
local TIMEOUT_MS = 8000
local SHOP_POLL_MS = 30000

local itemRowHeight, newEntry = W.itemRowHeight, W.newEntry
local newReader = U.newReader
local detailLine, setPlaceholder, itemBaseName, shopError = W.detailLine, W.setPlaceholder, W.itemBaseName, W.shopError
local marketError, listingRow, auctionRow = W.marketError, W.listingRow, W.auctionRow
local candidateRow, shopRow, ShopCell, MailCell = W.candidateRow, W.shopRow, W.ShopCell, W.MailCell
local StatementCell, ListingCell, historyRowHeight, historyRow = W.StatementCell, W.ListingCell, W.historyRowHeight, W.historyRow
local auctionHistoryRow, HistoryCell, drawBadge, newHeader = W.auctionHistoryRow, W.HistoryCell, W.drawBadge, W.newHeader
local newCombo, comboSelect, comboFill, sortKeysFor = W.newCombo, W.comboSelect, W.comboFill, W.sortKeysFor
local sortLabel, MARKET_SORTS, AUCTION_SORTS = W.sortLabel, W.MARKET_SORTS, W.AUCTION_SORTS
local currencyLabel, defaultCurrency = W.currencyLabel, W.defaultCurrency
local deliveryNote = C.deliveryText

-- One segment of a bulk claim. The server checks at most twenty envelopes (and two hundred
-- items) in one synchronous handler, so the client never asks it for more than that at once.
local MAIL_SEGMENT = 20

-- ---------- modal isolation ----------
local Panel = ISCollapsableWindow:derive("MinidoracatEconomyPanel")

-- Bind concrete implementations once; the window and all native callback identities stay intact.
Panel.layoutMarket = Layout.layoutMarket
Panel.layout = Layout.layout
Panel.headerTipName = Layout.headerTipName
Panel.updateHeaderTip = Layout.updateHeaderTip
Panel.onMouseMove = Layout.onMouseMove
Panel.onMouseMoveOutside = Layout.onMouseMoveOutside
Panel.drawHeader = Layout.drawHeader
Panel.drawWallet = Layout.drawWallet
Panel.drawRewards = Layout.drawRewards
Panel.drawShop = Layout.drawShop
Panel.drawMail = Layout.drawMail
Panel.drawMarketHistory = Layout.drawMarketHistory
Panel.drawMarket = Layout.drawMarket
Panel.drawAuctionHistory = Layout.drawAuctionHistory
Panel.drawAuction = Layout.drawAuction
Panel.drawFooter = Layout.drawFooter

-- Taller than vanilla (max(16, small font + 1)) so the Medium title fits; the vanilla
-- close/pin/collapse buttons and the drag region size themselves from this value.
function Panel:titleBarHeight()
    return math.max(28, fontH.medium + 8)
end

-- Title-bar chip, shown only while the size differs from the default: back to the default size,
-- centred. One setWidth/setHeight per axis (see RestoreLayout); ISLayoutManager saves the result.
function Panel:onResetSize()
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    local w, h = defaultSize()
    self:setWidth(w)
    self:setHeight(h)
    self:setX(math.floor((sw - w) / 2))
    self:setY(math.floor((sh - h) / 2))
    self:layout()
end

-- ---------- navigation entries ----------
-- The six pages, then the two utility entries. C.Navigation adopts these button instances and owns
-- their glyph, their label and their geometry from there on; the instances stay ours, so `internal`,
-- `active`, `fullTitle` and the callback are what the rest of this file reads. Nothing outside the
-- navigation module may setTitle/setWidth/setHeight on them again, and no test here reads `title`.
local NAV_ENTRIES = {
    { "Wallet" }, { "Rewards" }, { "Shop" }, { "Market" }, { "Auction" }, { "Mail" },
    { "Leaderboard" },
    { "Admin", true }, { "Settings", true },
}
local NAV_ICONS = {
    Wallet = "wallet", Rewards = "gift", Shop = "shop", Market = "market",
    Auction = "auction", Mail = "mail", Leaderboard = "chart", Admin = "users", Settings = "settings",
}


function Panel:createChildren()
    ISCollapsableWindow.createChildren(self)
    -- ----- navigation -----
    self.tabButtons = {}
    for _, entry in ipairs(NAV_ENTRIES) do
        local title = getText(T .. "Tab_" .. entry[1])
        local b = Button.create(0, 0, 140, ROW, title, self, Panel.onTab)
        b.internal = entry[1]
        b.fullTitle = title
        b.navUtility = entry[2]
        self:addChild(b)
        self.tabButtons[#self.tabButtons + 1] = b
        if entry[1] == "Mail" then self.mailTabButton = b end
        if entry[1] == "Admin" then self.adminNavButton = b end
    end
    self.nav = Nav.create(self, self.tabButtons, NAV_ICONS, "player")
    self:addChild(self.nav)
    -- the toggle goes in the title row, outside the rail: reachable whether the rail is open or
    -- shut, and it never spends one of the vertical rows
    self.navToggle = self.nav.toggleButton
    self:addChild(self.navToggle)

    -- ----- the fixed header identity -----
    -- The login account of this client, under the page title on every tab: the one thing in this
    -- window that does not belong to a page, so a screenshot of any of them names whose economy
    -- it is. It is a chip rather than a painted line because a header row can only ever show what
    -- fits, and an account name is exactly the kind of value that does not: pressing it (or Enter
    -- on it) spells the whole thing out in the session's record window, which copies it as well.
    local idLabel = getText(T .. "Player_IdentityUnknown")
    self.identityButton = Button.create(0, 0, textWidth(idLabel) + 20, ROW, idLabel,
        self, Panel.onIdentity, "chip")
    self:addChild(self.identityButton)

    -- ----- wallet -----
    self.periodButtons = {}
    for _, f in ipairs({ "Recent", "ThisMonth", "LastMonth" }) do
        local title = getText(T .. "Wallet_" .. f)
        local b = Button.create(0, 0, textWidth(title) + 22, CHIP_H, title, self, Panel.onPeriod, "chip")
        b.internal = f
        self:addChild(b)
        self.periodButtons[#self.periodButtons + 1] = b
    end
    -- The detailed balances are a separate reading view, not a second table competing for width.
    local fold = getText(T .. "Wallet_Details")
    self.walletDetailsButton = Button.create(0, 0, textWidth(fold) + 22, CHIP_H, fold, self,
        Panel.onWalletDetails, "chip")
    self:addChild(self.walletDetailsButton)
    local filters = getText(T .. "Admin_Tx_Filters")
    self.walletFilterButton = Button.create(0, 0, textWidth(filters) + 22, CHIP_H, filters, self, Panel.onWalletFilters, "chip")
    self:addChild(self.walletFilterButton)
    self.list = U.newTable(StatementCell, math.max(ROW, fontH.small + 8))
    -- picking a row reads it: the record opens as the session's own floating window (Detail)
    self.list.onSelect = function(_, item) self:onDetailRow("statement", item) end
    self:addChild(self.list)
    -- the statement is paged on the client (the reply is the whole month): a keyword box, kind
    -- chips, a day range, a time/amount sort and the pager, all local
    self.walletBar = FilterBar.new(self, kindText, "amount", Panel.rebuildList, "Wallet_SearchHint")

    -- ----- the whole-page reader -----
    -- Two pages *are* a reading surface and have no table of their own: the wallet's balance
    -- view (every currency with its reserve, its ceiling and this month's totals) and the
    -- Rewards page (the daily state and every configured milestone). Both scroll, neither may
    -- truncate, and the copy chip beside them hands the untruncated text to the clipboard.
    -- A picked *row* is not read here any more: it opens the floating record window, so no
    -- table ever gives up its height to a preview band (see Panel:onDetailRow).
    self.detailBox = newReader(self, 240, fontH.small * 2 + 12)
    local copyLabel = getText(T .. "Market_Detail_Copy")
    self.detailCopyButton = Button.create(0, 0, textWidth(copyLabel) + 22, CHIP_H, copyLabel,
        self, Panel.onDetailCopy, "chip")
    self:addChild(self.detailCopyButton)
    -- One retry chip for the three history reads (statement / market ring / auction record): the
    -- read that failed is the one on screen, and nothing in this window ever retries on its own.
    local retryLabel = getText(T .. "History_Retry")
    self.historyRetryButton = Button.create(0, 0, textWidth(retryLabel) + 22, CHIP_H, retryLabel,
        self, Panel.onHistoryRetry, "chip")
    self:addChild(self.historyRetryButton)

    -- ----- shop -----
    self.shopEntry = newEntry(200, math.max(26, fontH.small + 12), getText(T .. "Shop_Search"))
    self.shopEntry.target = self
    self.shopEntry.onTextChangeFunction = Panel.onShopSearch
    self:addChild(self.shopEntry)
    self.shopCatCombo = newCombo(self, 140, Panel.onShopCat)
    self.shopCatCombo:addOptionWithData(getText(T .. "Shop_All"), "")
    -- The currency this page trades in. One choice, made explicitly: a catalog quotes a price
    -- per currency, and the player picks which of them this visit spends.
    self.shopCurCombo = newCombo(self, 140, Panel.onShopCurrency)
    -- filled with the registered set by Panel:syncCurrencyCombos, together with the two browse
    -- filters: one place decides what every currency box offers
    self.shopList = U.newTable(ShopCell, itemRowHeight())
    -- A row is a read: it selects the sku and spells it out in the reader. Buying and selling
    -- are the row's own two buttons (ECRowActions), which is also the keyboard's way in - the
    -- toolbar pair below acts on the picked row for the same reason it always did.
    self.shopList.onSelect = function(_, item) self:onDetailRow("shop", item) end
    self.shopList.onRowAction = function(_, row, actionId) self:onShopAction(row, actionId) end
    self:addChild(self.shopList)
    for _, spec in ipairs({ { "Buy", "Shop_Buy", Panel.onShopBuy },
        { "Sell", "Shop_SellConfirm", Panel.onShopSell } }) do
        local title = getText(T .. spec[2])
        local b = Button.create(0, 0, textWidth(title) + 22, CHIP_H, title, self, spec[3], "chip")
        self:addChild(b)
        self["shop" .. spec[1] .. "Button"] = b
    end

    -- ----- mailbox -----
    -- A row is a read (onDetailRow opens the reader and does nothing else). Claiming one
    -- letter is that row's own button; the chip above claims every letter that is ready, in
    -- segments, without ever splitting an envelope.
    self.mailList = U.newTable(MailCell, itemRowHeight())
    self.mailList.onSelect = function(_, item) self:onDetailRow("mail", item) end
    self.mailList.onRowAction = function(_, row, actionId) self:onMailAction(row, actionId) end
    self:addChild(self.mailList)
    local claimLabel = getText(T .. "Mail_ClaimAll")
    self.mailClaimAllButton = Button.create(0, 0, textWidth(claimLabel) + 22, CHIP_H, claimLabel,
        self, Panel.onMailClaimAll, "chip")
    self:addChild(self.mailClaimAllButton)

    -- ----- market -----
    -- the mode bar over either the browse table (search / category / sort above it) or the single
    -- "my listings" / "history" card, all of them the whole workspace wide
    local MODE_KEYS = { browse = "Browse", mine = "Mine", history = "History" }
    self.marketModeButtons = {}
    for _, mode in ipairs({ "browse", "mine", "history" }) do
        local title = getText(T .. "Market_" .. MODE_KEYS[mode])
        local b = Button.create(0, 0, textWidth(title) + 22, CHIP_H, title, self, Panel.onMarketMode, "chip")
        b.internal = mode
        b.active = mode == self.marketMode
        self:addChild(b)
        self.marketModeButtons[#self.marketModeButtons + 1] = b
        if mode == "mine" then self.marketMineButton = b end
    end
    self.marketEntry = newEntry(200, math.max(26, fontH.small + 12), getText(T .. "Market_Search"))
    self.marketEntry.target = self
    self.marketEntry.onTextChangeFunction = Panel.onMarketSearch
    self:addChild(self.marketEntry)
    self.marketCatCombo = newCombo(self, 140, Panel.onMarketCat)
    self.marketCatCombo:addOptionWithData(getText(T .. "Shop_All"), "")
    -- the currency filter: "all" is the default, and it is also the one state in which a price
    -- sort is meaningless (prices of two currencies do not compare)
    self.marketCurCombo = newCombo(self, 140, Panel.onMarketCurrency)
    self.marketSortCombo = newCombo(self, 160, Panel.onMarketSort)
    comboFill(self.marketSortCombo, sortKeysFor(MARKET_SORTS, self.marketCur ~= nil),
        sortLabel(MARKET_SORTS), self.marketSort)
    self.marketList = U.newTable(ListingCell, itemRowHeight())
    -- a listing row reads; buying it (or pulling an own one back) is the row's own button
    self.marketList.onSelect = function(_, item) self:onDetailRow("market", item) end
    self.marketList.onRowAction = function(_, row, actionId) self:onMarketAction(row, actionId) end
    self:addChild(self.marketList)
    self.marketHistoryList = U.newTable(HistoryCell, historyRowHeight())
    self.marketHistoryList.onSelect = function(_, item) self:onDetailRow("history", item) end
    self:addChild(self.marketHistoryList)
    self.marketHeader = newHeader(self, "marketSort", "marketHeaderHits",
        function(panel) return panel.marketMode == "browse" and not panel.browseBusy end,
        Panel.onMarketHeader)
    self:addChild(self.marketHeader)
    self.historyBar = FilterBar.new(self,
        function(kind) return getTextOrNull(T .. "Market_Kind_" .. kind) or kind end,
        "amount", Panel.rebuildMarketHistory, "Market_History_SearchHint")
    for _, spec in ipairs({ { "Refresh", Panel.onMarketRefresh }, { "List", Panel.onMarketList },
        { "Prev", Panel.onMarketPage }, { "Next", Panel.onMarketPage } }) do
        local title = getText(T .. "Market_" .. spec[1])
        local b = Button.create(0, 0, textWidth(title) + 22, CHIP_H, title, self, spec[2], "chip")
        self:addChild(b)
        self["market" .. spec[1] .. "Button"] = b
    end
    self.marketPrevButton.internal = -1
    self.marketNextButton.internal = 1
    self:updateMarketInfo()
    local sellerClear = getText(T .. "Admin_Mkt_SellerClear")
    self.marketSellerClearButton = Button.create(0, 0, textWidth(sellerClear) + 22, CHIP_H,
        sellerClear, self, Panel.onMarketSellerClear, "chip")
    self:addChild(self.marketSellerClearButton)

    -- ----- auction -----
    -- the same mode bar, one full-workspace card, and the browse/mine tables built from the very
    -- same ListingCell. Every auction row carries its own record button, so the record page is
    -- reached from the row it belongs to instead of a toolbar chip that had to guess.
    self.auctionModeButtons = {}
    for _, spec in ipairs({ { "browse", "Auction_Browse" }, { "mine", "Auction_Mine" },
        { "history", "Auction_History" } }) do
        local title = getText(T .. spec[2], "0", "0")
        local b = Button.create(0, 0, textWidth(title) + 22, CHIP_H, title, self, Panel.onAuctionMode, "chip")
        b.internal = spec[1]
        b.active = spec[1] == self.auctionMode
        self:addChild(b)
        self.auctionModeButtons[#self.auctionModeButtons + 1] = b
        if spec[1] == "mine" then self.auctionMineButton = b end
    end
    self.auctionEntry = newEntry(200, math.max(26, fontH.small + 12), getText(T .. "Market_Search"))
    self.auctionEntry.target = self
    self.auctionEntry.onTextChangeFunction = Panel.onAuctionSearch
    self:addChild(self.auctionEntry)
    -- the sort box is the keyboard's equivalent of the sortable header (a header is a click
    -- target and nothing else), and it offers exactly the keys that header can produce
    self.auctionSortCombo = newCombo(self, 160, Panel.onAuctionSort)
    self.auctionCurCombo = newCombo(self, 140, Panel.onAuctionCurrency)
    comboFill(self.auctionSortCombo, sortKeysFor(AUCTION_SORTS, self.auctionCur ~= nil),
        sortLabel(AUCTION_SORTS), self.auctionSort)
    for _, spec in ipairs({ { "auctionList", "browse" }, { "auctionSellList", "selling" },
        { "auctionBidList", "bidding" } }) do
        local context = spec[2]
        local list = U.newTable(ListingCell, itemRowHeight())
        list.onSelect = function(_, item) self:onDetailRow("auction", item) end
        list.onRowAction = function(_, row, actionId) self:onAuctionAction(row, actionId, context) end
        self:addChild(list)
        self[spec[1]] = list
    end
    -- the three tables are always the same width, so they read one column set (Panel:layout
    -- fills the browse table's own; the identity is what keeps them in step)
    self.auctionSellList.cols = self.auctionList.cols
    self.auctionBidList.cols = self.auctionList.cols
    self.auctionHeader = newHeader(self, "auctionSort", "auctionHeaderHits",
        function(panel) return panel.auctionMode == "browse" and not panel.auctionBusy end,
        Panel.onAuctionHeader)
    self:addChild(self.auctionHeader)
    -- the record page: the same two-line cell and the same client-side filter bar the market
    -- ring uses, over the snapshot the server filtered for this player (or for one auction)
    self.auctionHistoryList = U.newTable(HistoryCell, historyRowHeight())
    self.auctionHistoryList.onSelect = function(_, item) self:onDetailRow("history", item) end
    self:addChild(self.auctionHistoryList)
    self.auctionHistoryBar = FilterBar.new(self,
        function(kind) return getTextOrNull(T .. "Market_Kind_" .. kind) or kind end,
        "amount", Panel.rebuildAuctionHistory)
    for _, spec in ipairs({ { "Refresh", "Market_Refresh", Panel.onAuctionRefresh },
        { "Create", "Auction_Create", Panel.onAuctionCreate },
        { "Prev", "Market_Prev", Panel.onAuctionPage }, { "Next", "Market_Next", Panel.onAuctionPage } }) do
        local title = getText(T .. spec[2])
        local b = Button.create(0, 0, textWidth(title) + 22, CHIP_H, title, self, spec[3], "chip")
        self:addChild(b)
        self["auction" .. spec[1] .. "Button"] = b
    end
    self.auctionPrevButton.internal = -1
    self.auctionNextButton.internal = 1
    self:updateAuctionInfo()
    self.auctionSellerClearButton = Button.create(0, 0, textWidth(sellerClear) + 22, CHIP_H,
        sellerClear, self, Panel.onAuctionSellerClear, "chip")
    self:addChild(self.auctionSellerClearButton)

    -- ----- rewards / window chrome -----
    self.claimButton = Button.create(0, 0, 200, 40, "", self, Panel.onClaim, "primary")
    self.claimButton.font = UIFont.Medium
    self:addChild(self.claimButton)

    local more = getText(T .. "Wallet_MoreHistory")
    self.moreButton = Button.create(0, 0, textWidth(more) + 24, CHIP_H, more, self, Panel.onMore, "chip")
    self:addChild(self.moreButton)

    local reset = getText(T .. "Window_ResetSize")
    self.resetSizeButton = Button.create(0, 0, textWidth(reset) + 20, self:titleBarHeight() - 8, reset, self, Panel.onResetSize, "chip")
    self:addChild(self.resetSizeButton)
    self.feeInfoButton = Button.create(0, 0, 120, math.max(CHIP_H, fontH.small + 8),
        getText(T .. "Trade_FeeDetails"), self, Panel.onFeeDetails, "chip")
    self.feeInfoButton:setVisible(false)
    self:addChild(self.feeInfoButton)

    -- the vanilla title buttons wear the framework icons: close, and lock/unlock for the pin
    -- state (collapseButton shows while pinned, pinButton while not - ISCollapsableWindow.pin/collapse)
    iconButton(self.closeButton, "close")
    iconButton(self.collapseButton, "lock")
    iconButton(self.pinButton, "unlock")

    -- the backdrop every modal of this window sits on (see ModalGuard): added before the
    -- popover, raised under whichever modal is up
    self.modalGuard = U.newModalGuard(self)

    -- preferences: the navigation's Settings entry opens this popover, which is where the chrome
    -- opacity lives now (the title row is the window's, not a control panel)
    self.prefsPopover = ISPanel:new(0, 0, PREFS_W, 100)
    setmetatable(self.prefsPopover, PrefsPopover)
    self.prefsPopover.background = false
    self.prefsPopover.panel = self
    self.prefsPopover:initialise()
    self.prefsPopover:instantiate()
    self.prefsPopover:setVisible(false)
    self:addChild(self.prefsPopover)

    -- The two seller boxes, built last: each adds its candidate list as the owner's last child,
    -- which is what puts it over the table it drops across without a per-frame bringToTop. They
    -- share one in-flight market.sellers slot (Panel:sellersSend) and answer only to their own
    -- context and requestId. Typing lists candidates; only picking a whole one pins an exact
    -- seller, so the keyword box above keeps whatever it holds.
    self.marketSellerPicker = PlayerPicker.create(self,
        function(command, args) return self:sellersSend(command, args) end,
        function() return self.sellersPendingAt ~= nil end,
        C.newRequestId,
        function(entry) self:onMarketSellerPicked(entry) end, "market", "market.sellers")
    self.auctionSellerPicker = PlayerPicker.create(self,
        function(command, args) return self:sellersSend(command, args) end,
        function() return self.sellersPendingAt ~= nil end,
        C.newRequestId,
        function(entry) self:onAuctionSellerPicked(entry) end, "auction", "market.sellers")

    -- the public board: its own controls, its own geometry, its own single read
    self.leaderboard = Leaderboard.create(self)

    self:syncCurrencyCombos()

    self:setTab("Wallet")
end

-- What the three currency boxes offer: the catalog page trades in exactly one registered
-- currency, the two browse filters offer the same set plus "every currency" in first place.
-- Refilled only when the registered set really changes (a config push from the server), so a
-- currency an admin switched off stops being offered without the page rebuilding per frame.
-- A choice that is no longer registered falls back: the catalog to the default, a filter to
-- "every currency".
function Panel:syncCurrencyCombos()
    local ids = W.currencyIds()
    -- The signature is the set *and* what each of them is called: an admin renaming a currency
    -- at runtime has to reach every box, not just an added or removed one. Built only when the
    -- server pushed a new registry (prerender compares the table identity), never per frame,
    -- and the selected id -- with every price, revision and quote already on screen -- is kept.
    local parts = {}
    for i, id in ipairs(ids) do parts[i] = id .. "=" .. currencyLabel(id) end
    local sig = table.concat(parts, ",")
    if sig == self.currencySig then return end
    self.currencySig = sig
    local known = {}
    for _, id in ipairs(ids) do known[id] = true end
    if not known[self.shopCur] then self.shopCur = defaultCurrency() end
    -- a filter that lost its currency falls back to "every currency", and there a price order
    -- does not exist: the sort box loses those keys with it, exactly as if the player had
    -- chosen "every currency" by hand
    if self.marketCur ~= nil and not known[self.marketCur] then
        self.marketCur = nil
        if W.isPriceSort(self.marketSort) then self.marketSort = "time" end
        comboFill(self.marketSortCombo, sortKeysFor(MARKET_SORTS, false),
            sortLabel(MARKET_SORTS), self.marketSort)
    end
    if self.auctionCur ~= nil and not known[self.auctionCur] then
        self.auctionCur = nil
        if W.isPriceSort(self.auctionSort) then self.auctionSort = "ending" end
        comboFill(self.auctionSortCombo, sortKeysFor(AUCTION_SORTS, false),
            sortLabel(AUCTION_SORTS), self.auctionSort)
    end
    comboFill(self.shopCurCombo, ids, currencyLabel, self.shopCur)
    local browse = { "" }
    for i = 1, #ids do browse[i + 1] = ids[i] end
    local label = function(id)
        if id == "" then return getText(T .. "Market_CurrencyAll") end
        return currencyLabel(id)
    end
    comboFill(self.marketCurCombo, browse, label, self.marketCur or "")
    comboFill(self.auctionCurCombo, browse, label, self.auctionCur or "")
    -- a currency that left the registry also leaves the rows: repaint both browse lists against
    -- the filter that is really in force now (the shop page is rebuilt by its own snapshot)
    if self.marketRows ~= nil then self:rebuildMarket() end
    if self.auctionRows ~= nil then self:rebuildAuctions() end
end

-- The backdrop follows the modal state, and is raised between the page and the modal that owns
-- it. Called by everything that opens or closes one, and by the layout (the window may have
-- been resized or collapsed under an open dialog).
function Panel:updateModalGuard()
    local guard = self.modalGuard
    if guard == nil then return end
    local top = self.marketDialog or self.buyDialog
    if top == nil and self.prefsPopover ~= nil and self.prefsPopover:getIsVisible() then
        top = self.prefsPopover
    end
    if top == nil or self.isCollapsed then
        if guard:getIsVisible() then guard:setVisible(false) end
        return
    end
    local th = self:titleBarHeight()
    local h = math.max(1, self.height - th - (self.resizable and self:resizeWidgetHeight() or 0))
    guard:setX(0)
    guard:setY(th)
    if guard.width ~= self.width then guard:setWidth(self.width) end
    if guard.height ~= h then guard:setHeight(h) end
    guard:setVisible(true)
    guard:raise(top)
end

function Panel:showPrefs(show)
    local pop = self.prefsPopover
    if not pop then return end
    pop:setVisible(show == true and not self.isCollapsed)
    if pop:getIsVisible() then
        Keys.blurInputs(self)
        self:closeCombos()
    end
    self:updateModalGuard()
    -- the popover owns the window while it is up: the ring moves into it (its two step chips are
    -- what a keyboard user presses instead of dragging a track) and comes back out on close
    Keys.invalidate(self)
end

-- The text boxes that only exist on one page: a hidden one must not keep the keyboard.
function Panel:unfocusEntries()
    for _, e in ipairs({ self.shopEntry, self.marketEntry, self.auctionEntry,
        self.walletBar.searchEntry, self.walletBar.fromEntry, self.walletBar.toEntry,
        self.historyBar.searchEntry, self.historyBar.fromEntry, self.historyBar.toEntry,
        self.auctionHistoryBar.fromEntry, self.auctionHistoryBar.toEntry }) do
        pcall(function() e:unfocus() end)
    end
end

-- A page switch, a hide or a collapse takes every open dropdown with it: an ISComboBox popup is
-- added to the UIManager (ISComboBox.lua:200-215), so it would float over the page that replaced
-- it. Same three lines ECKeyboard uses when the ring leaves a combo.
function Panel:closeCombos()
    for _, combo in ipairs({ self.shopCatCombo, self.shopCurCombo, self.marketCatCombo,
        self.marketSortCombo, self.marketCurCombo, self.auctionSortCombo, self.auctionCurCombo }) do
        if combo ~= nil and combo.expanded == true then
            combo.expanded = false
            local popup = combo.popup
            if popup ~= nil and popup.parentCombo == combo and combo.hidePopup ~= nil then
                pcall(combo.hidePopup, combo)
            end
        end
    end
    self.leaderboard:closeCombos()
    -- the seller candidate list is a dropdown too, and the box under it must not keep the
    -- keyboard behind a page that is gone (or behind a confirmation this just put up)
    for _, picker in ipairs({ self.marketSellerPicker, self.auctionSellerPicker }) do
        picker:close()
        pcall(picker.entry.unfocus, picker.entry)
    end
end

-- ----- keyboard -----
-- The ordered targets ECKeyboard walks (Tab / Shift+Tab). The navigation hands over its own two
-- descriptors first (the rail toggle, then the entries in visual order), then the page adds
-- everything it really has -- and nothing it has not: ECKeyboard drops a descriptor whose controls
-- are all unreachable, so a control the current mode does not paint simply is not in the walk.
--
-- Every mouse action on every page has an entry here. Where a row carries a chip the mouse can hit
-- directly (the shop's sell chip, the auction's record chip) the toolbar carries the same call for
-- the picked row, because a keyboard Enter on a list has no x to hit a chip with.
--
-- nil means "no keyboard right now": one of this window's own modal dialogs (buy / list / bid) owns
-- it, and a background hotkey pressing a chip behind it would be a trap. The preference popover is
-- modal too, but it answers with its own targets instead of nil: its sliders have to be reachable.
function Panel:keyboardTargets()
    if not self.shown or self.isCollapsed then return nil end
    if self.marketDialog then return self.marketDialog:keyboardTargets() end
    if self.buyDialog then return self.buyDialog:keyboardTargets() end
    if self.prefsPopover and self.prefsPopover:getIsVisible() then
        return self.prefsPopover:keyboardTargets()
    end
    -- copied, never appended to: the navigation owns whatever table it returns
    local out = {}
    for _, desc in ipairs(self.nav:keyboardTargets() or {}) do out[#out + 1] = desc end
    out[#out + 1] = { kind = "button", control = self.resetSizeButton,
        label = getText(T .. "Window_ResetSize") }
    -- the header identity belongs to the window, not to a page: it is in the walk on every tab,
    -- right where the eye finds it. While no account can be read the chip is disabled, so
    -- ECKeyboard steps over it instead of offering a press that could only answer nothing.
    out[#out + 1] = { kind = "button", control = self.identityButton,
        label = self.identityButton.fullTitle or getText(T .. "Player_IdentityTitle") }
    local tab = self.tab
    if tab == "Wallet" then self:walletTargets(out)
    elseif tab == "Rewards" then self:rewardsTargets(out)
    elseif tab == "Shop" then self:shopTargets(out)
    elseif tab == "Market" then self:marketTargets(out)
    elseif tab == "Auction" then self:auctionTargets(out)
    elseif tab == "Mail" then self:mailTargets(out)
    elseif tab == "Leaderboard" then self.leaderboard:keyboardTargets(out)
    end
    out[#out + 1] = { kind = "button", control = self.feeInfoButton, label = getText(T .. "Trade_FeeDetails") }
    self:detailTargets(out)
    return out
end

-- The filter bar of a client-paged list (the statement, the market ring, the auction record): the
-- kind chips, the two day boxes with their calendar glyphs, the sort pair. One implementation, so
-- every paged list is walked the same way.
function Panel:filterTargets(out, bar)
    if bar.filterButton then
        out[#out + 1] = { kind = "button", control = bar.filterButton, label = bar.filterButton.fullTitle }
    end
    -- the page's own keyword box, where it has one (the auction record is searched by the server)
    if bar.searchEntry then
        out[#out + 1] = { kind = "entry", control = bar.searchEntry, label = getText(T .. "Filter_Search") }
    end
    if #bar.kindButtons > 0 then
        local controls = { bar.kindPrevButton }
        for _, button in ipairs(bar.kindButtons) do controls[#controls + 1] = button end
        controls[#controls + 1] = bar.kindNextButton
        out[#out + 1] = { kind = "group", controls = controls, label = getText(T .. "Filter_Kind") }
    end
    for _, spec in ipairs({ { "fromEntry", "Filter_From" }, { "toEntry", "Filter_To" } }) do
        local e = bar[spec[1]]
        out[#out + 1] = { kind = "entry", control = e, label = getText(T .. spec[2]) }
        if e.calendarButton then
            out[#out + 1] = { kind = "button", control = e.calendarButton, label = getText(T .. "Filter_Calendar") }
        end
    end
    out[#out + 1] = { kind = "group", controls = bar.sortButtons, label = getText(T .. "Filter_Sort") }
end

function Panel:pagerTargets(out, bar)
    out[#out + 1] = { kind = "group", controls = { bar.prevButton, bar.nextButton },
        label = getText(T .. "Filter_PageNav") }
end

-- The page reader is read-only and never focusable (Core.updateKeyboard wants isEditable while
-- GameKeyboard only tests isDoingTextEntry: a focused read-only box swallows every key), so the
-- keyboard scrolls it and Ctrl+C is routed to the copy chip -- the page's own single copy path.
-- A picked row is not read here: it has its own window, which carries its own copy entry.
function Panel:detailTargets(out)
    -- the retry chip only exists while a history read failed, and the reader only on the two
    -- pages that are one: ECKeyboard drops a descriptor whose controls are all unreachable, so
    -- neither has to be filtered here
    out[#out + 1] = { kind = "button", control = self.historyRetryButton,
        label = getText(T .. "History_Retry") }
    out[#out + 1] = { kind = "scroll", control = self.detailBox, focusable = false,
        copyAll = self.detailCopyButton, label = getText(T .. "Kb_Detail") }
    out[#out + 1] = { kind = "button", control = self.detailCopyButton,
        label = getText(T .. "Market_Detail_Copy") }
end

function Panel:walletTargets(out)
    out[#out + 1] = { kind = "button", control = self.walletDetailsButton,
        label = getText(T .. "Wallet_Details") }
    out[#out + 1] = { kind = "button", control = self.walletFilterButton, label = self.walletFilterButton.fullTitle }
    out[#out + 1] = { kind = "group", controls = self.periodButtons, label = getText(T .. "Wallet_Period") }
    self:filterTargets(out, self.walletBar)
    out[#out + 1] = { kind = "list", control = self.list, label = getText(T .. "Wallet_Statement") }
    self:pagerTargets(out, self.walletBar)
end

function Panel:rewardsTargets(out)
    out[#out + 1] = { kind = "group", controls = { self.claimButton, self.moreButton },
        label = getText(T .. "Rewards_Daily") }
end

-- The action buttons of the row a table has picked, as one group right behind that table: they
-- are real buttons inside the row, so the keyboard reaches exactly what the mouse presses.
-- R.targets answers an empty table when nothing is picked (or the picked row scrolled out of
-- sight), and ECKeyboard drops a descriptor with nothing reachable in it.
function Panel:rowActionTargets(out, list)
    out[#out + 1] = { kind = "group", controls = R.targets(list),
        label = getText(T .. "Kb_Row_Actions") }
end

function Panel:shopTargets(out)
    out[#out + 1] = { kind = "entry", control = self.shopEntry, label = getText(T .. "Shop_Search") }
    out[#out + 1] = { kind = "combo", control = self.shopCatCombo, label = getText(T .. "Shop_Category") }
    out[#out + 1] = { kind = "combo", control = self.shopCurCombo, label = getText(T .. "Trade_Currency") }
    out[#out + 1] = { kind = "group", controls = { self.shopBuyButton, self.shopSellButton },
        label = getText(T .. "Kb_Shop_Actions") }
    out[#out + 1] = { kind = "list", control = self.shopList, label = getText(T .. "Shop_Title") }
    self:rowActionTargets(out, self.shopList)
end

-- Every descriptor of the market page, in reading order. Nothing is filtered by mode here: a
-- control the current mode does not paint is invisible, and ECKeyboard drops a descriptor whose
-- controls are all unreachable.
function Panel:marketTargets(out)
    local modes = {}
    for _, b in ipairs(self.marketModeButtons) do modes[#modes + 1] = b end
    modes[#modes + 1] = self.marketListButton
    modes[#modes + 1] = self.marketRefreshButton
    out[#out + 1] = { kind = "group", controls = modes, label = getText(T .. "Kb_Market_Modes") }
    out[#out + 1] = { kind = "entry", control = self.marketEntry, label = getText(T .. "Kb_Market_Search") }
    for _, desc in ipairs(self.marketSellerPicker:keyboardTargets()) do out[#out + 1] = desc end
    out[#out + 1] = { kind = "button", control = self.marketSellerClearButton,
        label = getText(T .. "Admin_Mkt_SellerClear") }
    out[#out + 1] = { kind = "combo", control = self.marketCatCombo, label = getText(T .. "Kb_Market_Cats") }
    out[#out + 1] = { kind = "combo", control = self.marketCurCombo, label = getText(T .. "Trade_Currency") }
    out[#out + 1] = { kind = "combo", control = self.marketSortCombo, label = getText(T .. "Kb_Market_Sort") }
    out[#out + 1] = { kind = "list", control = self.marketList, label = getText(T .. "Kb_Market_List") }
    self:rowActionTargets(out, self.marketList)
    self:filterTargets(out, self.historyBar)
    out[#out + 1] = { kind = "list", control = self.marketHistoryList, label = getText(T .. "Kb_Market_History") }
    self:pagerTargets(out, self.historyBar)
    out[#out + 1] = { kind = "group", controls = { self.marketPrevButton, self.marketNextButton },
        label = getText(T .. "Kb_Market_Pager") }
end

function Panel:auctionTargets(out)
    local modes = {}
    for _, b in ipairs(self.auctionModeButtons) do modes[#modes + 1] = b end
    modes[#modes + 1] = self.auctionCreateButton
    modes[#modes + 1] = self.auctionRefreshButton
    out[#out + 1] = { kind = "group", controls = modes, label = getText(T .. "Kb_Auction_Modes") }
    out[#out + 1] = { kind = "entry", control = self.auctionEntry, label = getText(T .. "Kb_Auction_Search") }
    for _, desc in ipairs(self.auctionSellerPicker:keyboardTargets()) do out[#out + 1] = desc end
    out[#out + 1] = { kind = "button", control = self.auctionSellerClearButton,
        label = getText(T .. "Admin_Mkt_SellerClear") }
    out[#out + 1] = { kind = "combo", control = self.auctionSortCombo, label = getText(T .. "Kb_Auction_Sort") }
    out[#out + 1] = { kind = "combo", control = self.auctionCurCombo, label = getText(T .. "Trade_Currency") }
    for _, spec in ipairs({ { self.auctionList, "Kb_Auction_List" },
        { self.auctionSellList, "Kb_Auction_Selling" }, { self.auctionBidList, "Kb_Auction_Bidding" } }) do
        out[#out + 1] = { kind = "list", control = spec[1], label = getText(T .. spec[2]) }
        self:rowActionTargets(out, spec[1])
    end
    self:filterTargets(out, self.auctionHistoryBar)
    out[#out + 1] = { kind = "list", control = self.auctionHistoryList, label = getText(T .. "Kb_Auction_History") }
    self:pagerTargets(out, self.auctionHistoryBar)
    out[#out + 1] = { kind = "group", controls = { self.auctionPrevButton, self.auctionNextButton },
        label = getText(T .. "Kb_Market_Pager") }
end

function Panel:mailTargets(out)
    out[#out + 1] = { kind = "button", control = self.mailClaimAllButton,
        label = getText(T .. "Mail_ClaimAll") }
    out[#out + 1] = { kind = "list", control = self.mailList, label = getText(T .. "Mail_Title") }
    self:rowActionTargets(out, self.mailList)
end

-- UIManager offers key events to top-level UI only, and asks isKeyConsumed *after* the handler ran
-- (UIElement.java:2185-2214): all four hooks go to the one engine, which keeps the ledger.
function Panel:onKeyPress(key) Keys.onKeyPress(self, key) end
function Panel:onKeyRepeat(key) Keys.onKeyRepeat(self, key) end
function Panel:onKeyRelease(key) Keys.onKeyRelease(self, key) end
function Panel:isKeyConsumed(key) return Keys.isKeyConsumed(self, key) end
function Panel:onFocus() Keys.onFocus(self) end

function Panel:isModal()
    return self.marketDialog ~= nil or self.buyDialog ~= nil
        or (self.prefsPopover and self.prefsPopover:getIsVisible())
end

function Panel:onEscape()
    if self.marketDialog then self:closeMarketDialog(); return true end
    if self.buyDialog then self:closeBuy(); return true end
    if self.prefsPopover and self.prefsPopover:getIsVisible() then self:showPrefs(false); return true end
    -- the candidate list folds first: Escape walks back out of what it opened, and the page
    -- behind it is left alone
    if self.marketSellerPicker:isOpen() then self.marketSellerPicker:close(); return true end
    if self.auctionSellerPicker:isOpen() then self.auctionSellerPicker:close(); return true end
    -- the record window closes before the keyboard is given back: Escape walks back out of what
    -- it opened, and it is this window's own child in spirit even though it floats on its own
    if Detail.isOpen(self) then Detail.close(self); return true end
    return false
end

-- ----- actions -----

function Panel:onTab(button)
    local id = button.internal
    -- The Admin entry is not a page of this window: it opens (or focuses) the administration
    -- window, which owns the one admin panel of the session. Settings is not a page either -- it
    -- is the preference popover, which is where the opacity slider lives now.
    if id == "Admin" then
        C.AdminWindow.open()
        return
    end
    if id == "Settings" then
        self:showPrefs(not self.prefsPopover:getIsVisible())
        return
    end
    self:setTab(id)
end

function Panel:setTab(tab)
    if tab ~= self.tab then
        DatePicker.close(self)   -- this window's calendar only; another window keeps its own
        self:closeCombos()
        self:closeBuy()
        self:closeMarketDialog()
        self:unfocusEntries()
        self:cancelAuctionHistory()
        self:showPrefs(false)
        Detail.close(self)       -- the record belonged to the page that is being left
        self.leaderboard:leave()   -- a queued public read belongs to the page being left
    end
    self.tab = tab
    for _, b in ipairs(self.tabButtons) do b.active = b.internal == tab end
    self:layout()
    -- the page under the ring changed: the navigation survives it, everything the old page offered
    -- does not, so the focus is revalidated instead of pointing at a hidden control
    Keys.invalidate(self)
    if self.shown then self:refresh() end
end

-- The server view a page reads, or nil (Rewards has one of its own poll). views.changed names
-- these scopes, and the page that is on screen is the only one that asks again.
function Panel:tabScope()
    local tab = self.tab
    if tab == "Wallet" then return "wallet" end
    if tab == "Shop" then return "shop" end
    if tab == "Mail" then return "mail" end
    if tab == "Market" then return "market" end
    if tab == "Auction" then return "auction" end
    return nil
end

-- The server said the data behind a scope moved (a write of this player's own, or anything else
-- that reached their view). A page that is not on screen only records it; the page the player is
-- looking at asks again through its own request path. That path is the one gate the command
-- itself has (ECClient's snapshot gates): the 650 ms window, one read in flight and the newest
-- wish kept, so a second notice inside the window is never dropped without a reply -- it goes
-- out as soon as the first read is answered. That is why the flag may be spent here.
-- The snapshot is never cleared: a notice is not a fresh answer.
function Panel:onViewChanged(scope)
    if type(scope) ~= "string" then return end
    self.viewDirty[scope] = true
    self:pumpViews()
end

function Panel:pumpViews()
    if not self.shown or self.isCollapsed then return end
    local scope = self:tabScope()
    if scope == nil or not self.viewDirty[scope] then return end
    self.viewDirty[scope] = nil
    if scope == "wallet" then
        C.requestWallet()
        self:loadHistory()
    elseif scope == "shop" then
        self.shopAt = EC.now()
        C.requestShop()
    elseif scope == "mail" then
        C.requestMail()
    elseif scope == "market" then
        self:requestMarketMode()
    else
        self:requestAuctionMode()
    end
end


function Panel:refresh()
    if self.tab == "Wallet" then
        C.requestWallet()
        if not self.history then self:loadHistory() end
    elseif self.tab == "Rewards" then
        self.rewardsPolledMs = EC.now()
        C.requestRewards()
        if not C.wallet then C.requestWallet() end
    elseif self.tab == "Shop" then
        -- the catalog only changes when an admin edits it (and every purchase reply is followed
        -- by a fresh list from ECClient), so a recent snapshot is reused as it is
        if not C.shop or EC.now() - (self.shopAt or 0) > SHOP_POLL_MS then
            self.shopAt = EC.now()
            C.requestShop()
        end
        if not C.wallet then C.requestWallet() end
    elseif self.tab == "Market" then
        -- the browse page is a live market: a snapshot older than the shop's window is refetched,
        -- and the own-listings page is always asked for (it is short and it is the write side)
        if self.marketMode == "mine" then
            C.requestMyListings()
        elseif self.marketMode == "history" then
            self:requestMarketHistory()
        elseif not C.market or EC.now() - (self.marketAt or 0) > SHOP_POLL_MS then
            self:requestBrowse(1)
        end
        if not C.wallet then C.requestWallet() end
    elseif self.tab == "Auction" then
        -- an auction is a countdown: the page is always asked for again, both modes are short
        self:requestAuctionMode()
        if not C.wallet then C.requestWallet() end
    elseif self.tab == "Mail" then
        C.requestMail()
    elseif self.tab == "Leaderboard" then
        -- a public board moves whenever anybody trades: the page asks again every time it is
        -- opened, through the transport's own read gate
        self.leaderboard:fillCurrencies()
        self.leaderboard:request(self.leaderboard.page)
    end
end

function Panel:onPeriod(button)
    self.period = button.internal
    for _, b in ipairs(self.periodButtons) do b.active = b.internal == self.period end
    self.walletBar.page = 1        -- another month starts on its own first page
    self.history = nil
    self.historyError = nil
    self:loadHistory()
    self:rebuildList()
end

-- Whether the page this read belongs to is really on screen. A hidden page owes its read and
-- sends nothing: the gate keeps the wish until the player looks at it again.
function Panel:pageVisible(tab, mode)
    if not self.shown or self.isCollapsed or self.tab ~= tab then return false end
    if tab == "Market" then return self.marketMode == mode end
    if tab == "Auction" then return self.auctionMode == mode end
    return true
end

-- Switch readers without changing statement filters, selection or list scroll.
function Panel:onWalletDetails()
    self.walletFiltersOpen = false
    DatePicker.close(self)
    self:unfocusEntries()
    self.walletDetails = not self.walletDetails
    self:layout()
    Keys.invalidate(self)
end

function Panel:onWalletFilters()
    DatePicker.close(self)
    self:unfocusEntries()
    self.walletFiltersOpen = not self.walletFiltersOpen
    self:layout()
    Keys.invalidate(self)
end

function Panel:onMore()
    self:setTab("Wallet")
end

-- One claim, and only while the server's own state says it may be taken. The request carries
-- the day and the reward number the state named, so a stale page cannot claim twice.
function Panel:onClaim()
    local st = C.rewards
    if st == nil or st.canClaim ~= true or self.claimPending then return end
    self.claimButton:setEnable(false)
    -- one claim in flight, and it is stamped: every reply clears it (onRewards), and a server
    -- that never answers is given up on in prerender instead of locking the button for the
    -- rest of the session
    self.claimPending = true
    self.claimPendingAt = EC.now()
    self.message = nil
    C.checkin()
end

function Panel:periodMonth()
    local ms = EC.now()
    if self.period == "Recent" then return "recent" end   -- server: previous + current month files
    if self.period == "LastMonth" then
        -- first day of this month minus one day, in UTC (receipt files are keyed by UTC month)
        local firstOfMonth = ms - ((tonumber(EC.dayKey(ms)) % 100) - 1) * 86400000
        return EC.monthKey(firstOfMonth - 86400000)
    end
    return EC.monthKey(ms)
end

-- The three history reads, each through the one gate they share (ECReadGate): the month of the
-- statement, the market ring, the auction record. The gate holds the 650 ms window, the single
-- read in flight, the wish of a page that is not on screen and the question every reply is
-- matched against; the page keeps its own data and its own error.
function Panel:loadHistory()
    self.historyError = nil
    self.walletGate:want(self:periodMonth(), self:pageVisible("Wallet"))
end

function Panel:requestMarketHistory()
    self.marketGate:want("ring", self:pageVisible("Market", "history"))
end

-- ----- data -----

local function normalize(e, offsetMin)
    local amount = tonumber(e.amount or e.delta) or 0
    local cp = e.counterparty
    local cpClass = type(cp) == "string" and EC.accountClass(cp) or nil
    local desc = "-"
    if cpClass == "player" then
        desc = cp
    elseif cpClass == "discord" then
        desc = accountName(cp)
    elseif e.sourceMod then
        -- integration postings (spec 21.3): the mod's own account plus its own wording when it gave one
        desc = accountName("MOD:" .. tostring(e.sourceMod))
        if type(e.reasonText) == "string" and e.reasonText ~= "" then desc = desc .. " - " .. e.reasonText end
    elseif type(e.item) == "string" then
        -- shop purchases carry the item and count (ring and receipt files alike)
        desc = itemName(e.item) .. " x" .. tostring(math.floor(tonumber(e.qty) or 1))
    elseif cpClass ~= nil then
        -- the faucet, the burn drain, a Discord deposit: name what moved the money, not a dash
        desc = accountName(cp)
    end
    local kind = e.kind or e.type
    local valueText = signedText(amount)
    local label = kindText(kind)
    local item = type(e.item) == "string" and e.item or nil
    return {
        recordKey = U.recordKey(e),
        ts = e.ts, txId = e.txId, kind = kind, currency = e.currency, amount = amount,
        after = e.after or e.availableAfter, rolledBack = e.rolledBack == true,
        time = stampText(e.ts, offsetMin), kindText = label, desc = desc,
        reasonText = type(e.reasonText) == "string" and e.reasonText or nil,
        valueText = valueText, amountText = valueText .. " " .. C.currencyName(e.currency),
        -- what the statement's keyword box searches: the note (which already names the
        -- counterparty or the item), the raw account key, the item's own fullType and localised
        -- name, the kind, and the transaction id an admin or a bug report quotes
        searchText = string.lower(table.concat({ desc, tostring(cp or ""), item or "",
            item and itemName(item) or "", label, tostring(e.txId or "") }, " ")),
    }
end

local function newestFirst(src, offsetMin)
    local out = {}
    for i = #src, 1, -1 do out[#out + 1] = normalize(src[i], offsetMin) end
    return out
end

-- self.rows = the visible statement page, self.allRows = the whole period (the filter bar
-- filters/sorts/pages it locally), self.recentRows = the server receipt ring the "Recent" period
-- falls back to until the file reply lands. All rebuilt only when data or a filter changes, never
-- per frame. "Recent" is the newest RECENT_ROWS lines of the receipt files (they keep what a crash
-- rolled back).
local RECENT_ROWS = 20

-- One row per currency for the wallet detail table: everything the compact header had no room for.
-- The ceiling is the currency's own (config.currencies[id].balanceMax, ECConfig.currency merges the
-- sandbox default into it); a build that sends none says so instead of printing a zero.
function Panel:rebuildBalances()
    self.balanceCurrencies = C.currencies
    local lines = {}
    for _, id in ipairs(self:currencies()) do
        local bal = C.wallet and C.wallet.balances and C.wallet.balances[id]
        local def = U.currencyDef(id)
        local cap = def and tonumber(def.balanceMax) or nil
        local t = self.monthTotals and self.monthTotals[id]
        local row = {
            id = id, name = C.currencyName(id), enabled = def == nil or def.enabled ~= false,
            availableText = amountText(bal and bal.available or 0),
            reservedText = amountText(bal and bal.reserved or 0),
            capText = cap and amountText(cap) or getText(T .. "Wallet_CapNone"),
            monthText = "-" .. amountText(t and t.out or 0) .. " / +" .. amountText(t and t.inn or 0),
        }
        if #lines > 0 then lines[#lines + 1] = "" end
        for _, line in ipairs(self:detailText("balance", row)) do lines[#lines + 1] = line end
    end
    self.balanceText = table.concat(lines, "\n")
    self:updateDetail()
end

function Panel:rebuildList()
    self.recentRows = newestFirst(C.wallet and C.wallet.receipts or {}, self.offsetMin)
    if self.period == "Recent" then
        if self.history then
            local all = newestFirst(self.history.entries or {}, self.offsetMin)
            local rows = {}
            for i = 1, math.min(#all, RECENT_ROWS) do rows[i] = all[i] end
            self.allRows = rows
        else
            self.allRows = self.recentRows
        end
    else
        self.allRows = newestFirst(self.history and self.history.entries or {}, self.offsetMin)
    end
    local bar = self.walletBar
    bar:syncKinds(self.allRows)
    -- the keyword narrows the rows this page has loaded; the chips, the days, the sort and the
    -- pager then count exactly what it left
    local rows, page, pages, total = EC.filterPage(bar:search(self.allRows), bar:opts("ts"))
    bar:setPage(page, pages, total)
    self.rows = rows
    self.statementAmountW = textWidth(getText(T .. "Wallet_Col_Amount")) + PAD * 2
    self.statementValueW = 0
    for _, row in ipairs(rows) do
        self.statementAmountW = math.max(self.statementAmountW, textWidth(row.amountText) + PAD * 2)
        self.statementValueW = math.max(self.statementValueW, textWidth(row.valueText))
    end
    self.list:setItems(rows)
    self:rebuildBalances()
    if self.g then self:layout() end
end

-- Month in/out per currency from this month's receipt file (design: balance card "this month").
function Panel:updateMonthTotals(history)
    local month = EC.monthKey(EC.now())
    if history.month ~= month and history.month ~= "recent" then return end
    local totals = {}
    for _, e in ipairs(history.entries or {}) do
        -- the recent window spans two months: only this month's lines count
        if e.rolledBack ~= true and EC.monthKey(tonumber(e.ts) or 0) == month then
            local t = totals[e.currency]
            if not t then t = { inn = 0, out = 0 }; totals[e.currency] = t end
            local d = tonumber(e.delta) or 0
            if d >= 0 then t.inn = t.inn + d else t.out = t.out - d end
        end
    end
    self.monthTotals = totals
end

function Panel:onWallet(kind, args)
    if kind == "state" then
        self:rebuildList()
    elseif kind == "changed" then
        self:rebuildBalances()
        self:loadHistory()
    elseif kind == "history" then
        -- the month the answer itself names is the question it answers: another month is a read
        -- the player has already moved past, and an older read of the month still in force is
        -- shown at once (a newer one is on its way and will replace it)
        if self.walletGate:accept(args, args.month) == "stale" then return end
        if args.error then
            self.historyError = args.error
        else
            self.historyError = nil
            self.history = args
            self:updateMonthTotals(args)
        end
        self:rebuildList()
    end
end

-- The reward page. A claim reply carries the fresh state whether it succeeded or not, and so does
-- the push the server sends after a season's deadline moved, so nothing here asks for a second
-- read just to repaint - and the moment the next claim becomes due is remembered, so the page
-- picks the new eligibility up then instead of polling for it every frame.
function Panel:onRewards(kind, args)
    -- Only the answer to the claim that is in flight ends it, granted or refused. A season
    -- change arrives as two pushes nobody on this side asked for (seasons.changed, then the
    -- rewards.state that follows it for every player): freeing the slot on those would let a
    -- second claim go out while the first one is still unanswered, and the server would then
    -- have to refuse a request the player never meant to make.
    if kind == "checkin" then
        self.claimPending = false
        self.claimPendingAt = nil
    end
    if type(args.state) == "table" then C.rewards = args.state end
    if kind == "checkin" then
        if args.ok then
            self.message = { text = getText(T .. "Rewards_GrantedCount",
                W.moneyText(args.amount, args.currency), tostring(tonumber(args.rewardIndex) or 1),
                tostring(tonumber(args.dailyLimit) or 1)) }
        else
            local key = T .. "Rewards_Error_" .. tostring(args.error)
            self.message = { text = getTextOrNull(key) or getText(T .. "Rewards_Error_generic", tostring(args.error)), error = true }
        end
        if type(args.state) ~= "table" then C.requestRewards() end
    end
    if kind == "error" then
        self.message = { text = getTextOrNull(T .. "Rewards_Error_" .. tostring(args.error))
            or getText(T .. "Rewards_Error_generic", tostring(args.error)), error = true }
    end
    local st = C.rewards
    local short = st and math.max(0, tonumber(st.remainingOnlineMs) or 0) or 0
    -- a claim that is only waiting on online time becomes possible at a known moment: ask the
    -- server again then (and never sooner - this client's clock decides nothing)
    self.rewardsDueMs = (st ~= nil and short > 0 and st.canClaim ~= true)
        and (EC.now() + short) or nil
    self:updateDetail()
end

-- ----- shop / mailbox -----

-- The mailbox tab carries the pending count: a purchase that did not fit in the backpack is
-- otherwise invisible until the player opens the page. Every reply that knows the number
-- (shop.list, shop.buy, mail.list, mail.claim, market.buy/cancel/notice) passes it here; the
-- number itself is painted as a corner bubble in prerender, so the tab keeps its width.
function Panel:updateMailTab(unclaimed)
    local n = tonumber(unclaimed)
    if not n then return end
    self.unclaimedCount = math.max(0, math.floor(n))
    C.unclaimed = self.unclaimedCount
end

-- The category box offers the categories the snapshot actually uses (plus "all"), so a server that
-- ships two categories does not offer five empty filters. Refilled only when that set changes (a
-- snapshot lands every 30 s at most, a catalog edit is rarer still).
function Panel:rebuildCategories()
    local seen, cats, sig = {}, { "" }, ""
    for _, it in ipairs(C.shop and C.shop.items or {}) do
        local cat = it.category
        if it.enabled ~= false and type(cat) == "string" and cat ~= "" and not seen[cat] then
            seen[cat] = true
            cats[#cats + 1] = cat
            sig = sig .. cat .. ","
        end
    end
    if self.shopCat and not seen[self.shopCat] then self.shopCat = nil end
    if sig == self.catSig then return end
    self.catSig = sig
    comboFill(self.shopCatCombo, cats, function(cat)
        if cat == "" then return getText(T .. "Shop_All") end
        return U.categoryText(cat)
    end, self.shopCat or "")
end

-- Rows for the selected category, currency and search text. A disabled sku is not a row at all:
-- a player must not see what an admin took off the shelf. A sku the selected currency does not
-- quote is still a row -- it says it has no price in this currency, which is what the player
-- needs to know before switching -- but nothing can be bought or sold on it.
function Panel:rebuildShop()
    local shop = C.shop
    local query = self.shopQuery
    local currency = self:shopCurrency()
    local rows = {}
    self.shopHasBuyback = false
    for _, it in ipairs(shop and shop.items or {}) do
        local q = it.enabled ~= false and W.quoteOf(it, currency) or nil
        if q ~= nil and q.buyback == true then self.shopHasBuyback = true end
        if it.enabled ~= false and (self.shopCat == nil or it.category == self.shopCat) then
            local row = shopRow(it, currency, shop.buyback)
            if query == nil or string.find(string.lower(row.name), query, 1, true)
                or (row.altName and string.find(string.lower(row.altName), query, 1, true))
                or string.find(string.lower(tostring(row.id)), query, 1, true)
                or string.find(string.lower(tostring(row.item)), query, 1, true) then
                rows[#rows + 1] = row
            end
        end
    end
    self.shopRows = rows
    self.shopList:setItems(rows)
end

-- The currency the catalog page is trading in. Explicit from the first frame (the registered
-- default, survivor while it exists) and never inferred from whatever a sku happens to quote.
function Panel:shopCurrency()
    local id = self.shopCur
    if type(id) ~= "string" or id == "" then
        id = defaultCurrency()
        self.shopCur = id
    end
    return id
end

-- One mailbox row. Every letter the server lists is claimable: a hand-over either delivers the
-- letter, leaves it exactly where it was, or settles the part it could confirm into a claimed
-- child of its own and leaves the rest here with a smaller count. `claimable` still comes from
-- the server's own view - the row never decides that for itself.
function Panel:rebuildMail()
    local rows = {}
    -- The account on the other side of the trade, when the server's own record of the deal names
    -- one. A shop purchase, a return and every letter written before the field carry none, and
    -- the row then says exactly what it always said.
    local buyFrom = T .. "Market_BuyFrom"
    local claimLabel = getText(T .. "Mail_Claim")
    for _, e in ipairs(C.mail and C.mail.entries or {}) do
        local qty = tonumber(e.qty) or 1
        local name = itemName(e.item)
        local seller = type(e.seller) == "string" and e.seller ~= "" and e.seller or nil
        local from = getTextOrNull(T .. "Mail_From_" .. tostring(e.kind)) or tostring(e.kind)
        if seller then from = from .. " - " .. getText(buyFrom, seller) end
        rows[#rows + 1] = {
            id = e.id, item = e.item, qty = qty, name = name, altName = itemBaseName(e.item),
            texture = itemTexture(e.item),
            -- a letter that carries money names the currency it was written in; one that
            -- carries none says nothing at all instead of quoting a zero
            price = tonumber(e.price), currency = e.currency, seller = seller,
            nameText = name .. " x" .. tostring(qty),
            fromText = from,
            claimable = e.claimable ~= false,
            claimLabel = claimLabel,
            timeText = stampText(tonumber(e.at) or 0, self.offsetMin),
        }
    end
    self.mailRows = rows
    self.mailList:setItems(rows)
end

function Panel:onShopCat(combo)
    local cat = combo:getOptionData(combo.selected)
    self.shopCat = (type(cat) == "string" and cat ~= "") and cat or nil
    self:rebuildShop()
end

-- Another currency is another set of prices: the rows are rebuilt, and an open trade dialog is
-- left alone (it carries its own currency chips and its own confirmed quote).
function Panel:onShopCurrency(combo)
    local id = combo:getOptionData(combo.selected)
    if type(id) ~= "string" or id == "" or id == self.shopCur then return end
    self.shopCur = id
    self:rebuildShop()
    self:layout()
end

function Panel:onShopSearch()
    local query = string.lower(string.match(entryText(self.shopEntry), "^%s*(.-)%s*$"))
    self.shopQuery = query ~= "" and query or nil
    self:rebuildShop()
end

-- Mirror the server's write gate: a registered terminal or a nearby vanilla ATM.
function Panel:tradeAllowed()
    if C.wallet and C.wallet.frozen then return false end
    return C.nearTerminal()
end

-- The two writes of the catalog page. They act on the row the table has picked, which is what
-- the row's own buttons select before they report (ECRowActions) and what the toolbar pair acts
-- on for a keyboard user; every validation stays exactly where it was.
function Panel:onShopBuy()
    local row = self.shopList:getSelectedItem()
    if not row or row.soldOut or row.hasQuote ~= true then return end
    if self.buyDialog or self.buyPending or not self:tradeAllowed() then return end
    self:openBuy(row)
end

function Panel:onShopSell()
    local row = self.shopList:getSelectedItem()
    if not row or row.buyback ~= true or row.buybackOpen ~= true or row.buybackRemaining == 0 then return end
    if self.buyDialog or self.buyPending or not self:tradeAllowed() then return end
    self:openBuy(row, true)
end

function Panel:onShopAction(row, actionId)
    if row == nil then return end
    if actionId == "sell" then self:onShopSell() else self:onShopBuy() end
end

-- sell = the buyback dialog: same panel, count in SKU units, the candidates come from the server
function Panel:openBuy(row, sell)
    local trigger = Keys.focused()
    local keyboard = Keys.isKeyboardFocused(trigger)
    self:closeBuy()
    local dlg = ISPanel:new(0, 0, 360, 200)
    setmetatable(dlg, BuyDialog)
    dlg.background = false
    dlg.panel = self
    dlg.returnFocus = keyboard and trigger or nil
    dlg.row = row
    dlg.sell = sell == true
    dlg.cand = nil
    dlg.count = 1
    dlg.message = nil
    -- the order starts in the currency the page is on; the dialog's own chips move it from there
    dlg.currency = self:shopCurrency()
    -- Every number this dialog shows belongs to one catalog revision, and that is the revision
    -- the order is submitted with. A sale also needs the candidate quote of that same revision
    -- (the server prices the backpack per catalog), so the two are never mixed.
    dlg.quoteRevision = C.shop and C.shop.revision or nil
    dlg:initialise()
    self:addChild(dlg)      -- the buttons exist from here on (instantiate -> createChildren)
    self.buyDialog = dlg
    for _, b in ipairs(dlg.currencyButtons) do b.active = b.internal == dlg.currency end
    -- a native combo popup is added to the UIManager (ISComboBox.lua:200-215), so an open
    -- dropdown would float over this dialog; and the page underneath must not keep taking the
    -- clicks that land beside it
    self:closeCombos()
    self:updateModalGuard()
    self:layoutBuy()
    Keys.focusControl(dlg.cancelButton, keyboard)
    if dlg.sell then self:sendSellCandidates(dlg) end
end

-- What the backpack is worth is quoted per currency, so the question carries one. Changing the
-- chips asks it again; closing the dialog drops whatever has not gone out yet.
function Panel:sendSellCandidates(dlg)
    C.requestSellCandidates(dlg.row.id, dlg.currency)
end

-- The band a modal owns: under the title bar, above the resize corner. Every dialog sizes
-- itself to this height, so the summary, the fields and the buttons are inside the window at
-- every UI font -- a 1000x560 window at 38/45 has no room for a dialog that stacks its lines.
function Panel:modalBand()
    local top = self:titleBarHeight() + PAD
    local bottom = self.height - (self.resizable and self:resizeWidgetHeight() or 0) - PAD
    return top, math.max(120, bottom - top)
end

-- One placement for both dialogs: laid out against the band, then centred in it.
function Panel:layoutDialog(dlg)
    if not dlg then return end
    local top, band = self:modalBand()
    dlg:layoutInside(math.max(320, self.width - PAD * 4), band)
    dlg:setX(math.max(0, math.floor((self.width - dlg.width) / 2)))
    dlg:setY(math.max(0, math.min(top + math.floor((band - dlg.height) / 2), self.height - dlg.height)))
end

function Panel:layoutBuy() self:layoutDialog(self.buyDialog) end

function Panel:closeBuy()
    local dlg = self.buyDialog
    if not dlg then return end
    self.buyDialog = nil
    dlg:setVisible(false)
    self:removeChild(dlg)
    C.cancelSellCandidates()   -- a question nobody is left to read the answer of
    Keys.invalidate(self)
    self:updateModalGuard()
    self.buyReturnFocus = dlg.returnFocus
end

-- An error belongs in the dialog that caused it; without one (a timeout after the player closed
-- it) the toast is the only place left.
function Panel:buyMessage(str)
    if self.buyDialog then
        self.buyDialog.message = str
    else
        C.toast(str)
    end
end

-- A quote that moved under an open dialog is never spent silently: the dialog shows the fresh
-- one, says so, and the next press of the confirm is only the acknowledgement. One more press
-- after that is the order. Same rule as the mailbox consent, and the two are independent.
function Panel:requoteHeld(dlg)
    if dlg.requoteRequired ~= true then return false end
    dlg.requoteRequired = nil
    dlg.message = nil
    return true
end

-- A purchase that does not fit is parked in the mailbox, and that is the player's own decision:
-- while the estimate says so (or the server said so after re-checking), the confirm has to be
-- pressed once more and only then does `acceptMail` go out. Nothing here ever sends the consent
-- on the player's behalf, and the server debits nothing until it has it.
function Panel:submitBuy(dlg)
    local shop = C.shop
    if not shop or self.buyPending then return end
    if not self:tradeAllowed() then
        self:buyMessage(shopError("not_at_terminal"))
        return
    end
    -- Recheck allowance on submit; a reduced order still requires confirmation.
    local allowed = dlg:maxCount()
    if allowed < 1 then
        dlg.message = shopError(dlg.row.dailyCapScope == "lifetime" and "lifetime_cap" or "daily_cap")
        return
    end
    if dlg.count > allowed then
        dlg:clampCount()
        return
    end
    if self:requoteHeld(dlg) then return end
    -- a currency this sku is not quoted in is not an order at all
    if dlg:unitPrice() == nil then
        dlg.message = shopError("currency_not_offered")
        return
    end
    local preview = dlg.preview
    if dlg.mailRequired ~= true and preview ~= nil and preview.willMail == true then
        dlg.mailRequired = true
        dlg.message = getText(T .. "Delivery_ConfirmMail")
        return
    end
    -- the revision the player actually read, not whatever the newest snapshot happens to be:
    -- the server refuses a stale one (catalog_changed) instead of filling it at a new price
    if dlg.quoteRevision == nil then
        dlg.message = shopError("catalog_changed")
        return
    end
    dlg.message = nil
    self.buyPending = { requestId = C.newRequestId(), at = EC.now(), name = dlg.row.name,
        currency = dlg.currency }
    C.buy(dlg.row.id, dlg.count, dlg.currency, dlg.quoteRevision, self.buyPending.requestId,
        dlg.mailRequired == true)
end

function Panel:submitSell(dlg)
    local c = dlg.cand
    if not C.shop or not c or self.buyPending then return end
    if not self:tradeAllowed() then
        self:buyMessage(shopError("not_at_terminal"))
        return
    end
    if self:requoteHeld(dlg) then return end
    -- the candidates have to be the ones quoted for the currency this sale is paid in
    if c.currency ~= dlg.currency or dlg:unitBid() == nil then
        dlg.message = shopError("currency_not_offered")
        return
    end
    -- and for the catalog the player is looking at: the row's price, the backpack price and the
    -- revision this is sent with are one quote or none at all
    local revision = dlg.quoteRevision
    if revision == nil or (c.revision ~= nil and c.revision ~= revision) then
        dlg.requoteRequired = true
        dlg.message = getText(T .. "Trade_Requote")
        self:sendSellCandidates(dlg)
        return
    end
    local unitQty = math.max(1, math.floor(tonumber(c.unitQty) or 1))
    local n = dlg.count * unitQty
    local ids = {}
    for i = 1, n do ids[i] = c.itemIds[i] end
    if #ids < 1 or #ids ~= n then return end
    dlg.message = nil
    self.buyPending = { requestId = C.newRequestId(), at = EC.now(), name = dlg.row.name,
        sell = true, currency = dlg.currency }
    C.sell(dlg.row.id, ids, dlg.currency, revision, self.buyPending.requestId)
end

function Panel:onMailAction(row, actionId)
    if actionId == "claim" then self:claimMailRow(row) end
end

-- One letter: the row's own claim button. The terminal/freeze gate the server re-checks anyway,
-- and the one write in flight the mailbox has always had - a bulk claim holds the very same
-- `mailPending`, so the two can never overlap.
function Panel:claimMailRow(row)
    if row == nil or row.claimable ~= true then return end
    if self.mailPending or self.mailBatch or not self:tradeAllowed() then return end
    self.mailPending = { requestId = C.newRequestId(), at = EC.now(), name = row.name }
    C.claimMail(row.id, self.mailPending.requestId)
end

-- Every letter that is ready, in segments. The ids are fixed the moment the player presses:
-- mail that arrives while the batch runs belongs to the next press, never to this one, so a
-- resend of the same segment can only ever answer `already_claimed`. A normal claim takes whole
-- envelopes; only the delivery exception splits one, and then the tally says so in items.
function Panel:onMailClaimAll()
    if self.mailPending or self.mailBatch or not self:tradeAllowed() then return end
    local ids = {}
    for _, row in ipairs(self.mailRows or {}) do
        if row.claimable == true then ids[#ids + 1] = row.id end
    end
    if #ids == 0 then return end
    self.mailBatch = { ids = ids, total = #ids, claimed = 0, kept = 0, failed = 0,
        partial = 0, partDone = 0, partLeft = 0 }
    self:sendMailBatch()
end

-- One segment of at most MAIL_SEGMENT untried ids. The reply names what it really tried and
-- those ids leave the queue, whether they were claimed, kept for want of room or refused;
-- nothing is retried inside one batch.
function Panel:sendMailBatch()
    local batch = self.mailBatch
    if batch == nil or self.mailPending then return end
    local segment = {}
    for i = 1, math.min(MAIL_SEGMENT, #batch.ids) do segment[i] = batch.ids[i] end
    if #segment == 0 then return self:finishMailBatch(nil) end
    batch.nextAt = nil
    batch.sent = #segment
    self.mailPending = { requestId = C.newRequestId(), at = EC.now(), batch = true }
    C.claimMailBatch(segment, self.mailPending.requestId)
end

-- The batch is over: what was claimed, what stayed in the mailbox for want of room, what was
-- refused, and - on its own line - the letters that only handed over part of themselves, in
-- items. Only a bucket that really happened is worded: a batch where every letter came through
-- says so and nothing else, instead of also claiming "0 failed" (a zero read as a result is how
-- a clean run came to look like a broken one). A letter that failed, one that stayed behind and
-- one that split are each still spelled out in full, so no partial run can read as a whole one.
-- `code` is a refusal of the command itself (or a read that never came back), and it is reported
-- next to the tally, never instead of it.
local BATCH_PARTS = { { "claimed", "Mail_BatchClaimed" }, { "kept", "Mail_BatchKept" },
    { "failed", "Mail_BatchFailed" } }

function Panel:finishMailBatch(code)
    local batch = self.mailBatch
    self.mailBatch = nil
    if batch == nil then return end
    local parts = {}
    for _, spec in ipairs(BATCH_PARTS) do
        local n = batch[spec[1]]
        if n > 0 then parts[#parts + 1] = getText(T .. spec[2], tostring(n)) end
    end
    if #parts > 0 then C.toast(table.concat(parts, "  ")) end
    if batch.partial > 0 then
        C.toast(getText(T .. "Mail_BatchPartial", tostring(batch.partial),
            tostring(batch.partDone), tostring(batch.partLeft)))
    end
    if batch.lastError ~= nil then C.toast(shopError(batch.lastError)) end
    if code ~= nil then C.toast(shopError(code)) end
end

-- One reply of the bulk claim. Every id the server named is out of the queue; a segment that
-- named none is a dead end and stops the batch instead of asking again forever.
function Panel:onMailBatchReply(args)
    local batch = self.mailBatch
    self.mailPending = nil
    if batch == nil then return end
    local results = args.results
    if type(results) ~= "table" or #results == 0 then
        -- the command itself was refused (not at a terminal, frozen, malformed): nothing tried
        self:finishMailBatch(args.error or "unknown")
        return
    end
    local tried = {}
    for _, r in ipairs(results) do
        tried[r.mailId] = true
        if r.ok == true then
            batch.claimed = batch.claimed + 1
        elseif r.error == "backpack_full" then
            batch.kept = batch.kept + 1
        elseif r.error == "delivery_partial" then
            -- the letter is still there with fewer items: its own line of the tally, in items
            batch.partial = batch.partial + 1
            batch.partDone = batch.partDone + math.max(0, math.floor(tonumber(r.deliveredQty) or 0))
            batch.partLeft = batch.partLeft + math.max(0, math.floor(tonumber(r.remainingQty) or 0))
        else
            batch.failed = batch.failed + 1
            batch.lastError = r.error
        end
    end
    local left, removed = {}, 0
    for _, id in ipairs(batch.ids) do
        if tried[id] then removed = removed + 1 else left[#left + 1] = id end
    end
    batch.ids = left
    if removed == 0 then
        self:finishMailBatch("unknown")
        return
    end
    if #left == 0 then
        self:finishMailBatch(nil)
        return
    end
    -- the next segment waits out the server's own command window
    batch.nextAt = EC.now() + ReadGate.MIN_MS
end

-- A fresh catalog row for an open dialog, in the currency that dialog is trading in. The whole
-- displayed quote moves together: the row, the revision it belongs to and -- for a sale -- the
-- candidate prices, which are dropped and asked for again because the ones on screen were
-- quoted against the catalog that just went away. A moved quote is shown at once and held: the
-- confirm becomes an acknowledgement first (Panel:requoteHeld), so a snapshot can never turn a
-- confirmed price into a different one behind the press.
function Panel:refreshBuyRow(dlg, items, buyback, revision)
    -- An order already on the wire owns this dialog: the row, the count and the revision it
    -- was sent with may not move before the reply, or the answer would be read against numbers
    -- the player never confirmed. The catalog is noted and read again once the write settles.
    if self.buyPending ~= nil then
        dlg.catalogDirty = true
        return dlg.row
    end
    local fresh = nil
    for _, it in ipairs(items or {}) do
        if it.id == dlg.row.id and it.enabled ~= false then fresh = shopRow(it, dlg.currency, buyback) end
    end
    if fresh == nil then return nil end
    local was = dlg.row
    local moved = was.price ~= fresh.price or was.bidPrice ~= fresh.bidPrice
        or (revision ~= nil and dlg.quoteRevision ~= nil and revision ~= dlg.quoteRevision)
    dlg.row = fresh
    if revision ~= nil then dlg.quoteRevision = revision end
    if moved then
        dlg.requoteRequired = true
        dlg.message = getText(T .. "Trade_Requote")
        if dlg.sell then
            -- the candidate prices belonged to the catalog that just moved: they may not
            -- price this sale. The count the player asked for is kept -- what the new catalog
            -- allows is only known once the fresh candidates answer, and it is clamped there.
            dlg.cand = nil
            self:sendSellCandidates(dlg)
        end
    end
    return fresh
end

-- The write that owned the dialog has answered (or been given up on). Whatever the catalog did
-- meanwhile was held back; it is read now, through the same snapshot gate every page uses, and
-- a sale asks for the backpack prices of that catalog again. Nothing is patched in from memory:
-- the fresh reply is what moves the dialog, and it moves it through the requote hold.
function Panel:resumeBuyDialog()
    local dlg = self.buyDialog
    if dlg == nil or dlg.catalogDirty ~= true then return end
    dlg.catalogDirty = nil
    C.requestShop()
    if dlg.sell then self:sendSellCandidates(dlg) end
end

function Panel:onShop(kind, args)
    self:updateMailTab(args.unclaimed)
    if kind == "list" then
        self:rebuildCategories()
        self:rebuildShop()
        self:layout()   -- the chip row (and with it the search box below it) may have moved
        -- keep an open dialog on the fresh price/remaining, or drop it if the sku is gone
        local dlg = self.buyDialog
        if dlg then
            local fresh = self:refreshBuyRow(dlg, args.items, args.buyback, args.revision)
            if fresh and (not dlg.sell or (fresh.buyback and fresh.buybackOpen)) then
                self:layoutBuy()
            else
                self:closeBuy()
                C.toast(shopError(dlg.sell and "buyback_disabled" or "unknown_sku"))
            end
        end
        return
    end
    -- One sku's remaining share moved because somebody else bought it (a server-wide daily cap).
    -- ECClient already put the number on the snapshot; this only repaints the rows. A delta for
    -- a catalog this client does not hold is not patched into the one it does: the page asks for
    -- the whole list instead of showing a number from another revision.
    if kind == "stock" then
        if args.revision ~= nil and C.shop ~= nil and args.revision ~= C.shop.revision then
            self.viewDirty["shop"] = true
            self:pumpViews()
            return
        end
        self:rebuildShop()
        -- an open buy dialog reads the sku's own numbers: it takes the whole fresh row, so the
        -- count it allows and the text it spells out can never come from two different reads
        local dlg = self.buyDialog
        local shop = C.shop
        if dlg and not dlg.sell and shop and dlg.row.id == args.id then
            self:refreshBuyRow(dlg, shop.items, shop.buyback, shop.revision)
            self:layoutBuy()
        end
        return
    end
    if kind == "candidates" then
        local dlg = self.buyDialog
        -- the reply echoes the sku and the currency it was asked about: an answer for the
        -- currency the player has already switched away from is not this dialog's answer
        if dlg and dlg.sell and args.id == dlg.row.id and args.currency == dlg.currency then
            -- a sale already on the wire keeps the quote it was sent with: a candidate reply
            -- that lands meanwhile is noted and asked for again once the write has answered
            if self.buyPending ~= nil then
                dlg.catalogDirty = true
                return
            end
            -- and neither is an answer quoted against another catalog: the row on screen and
            -- the backpack price have to come from one and the same revision, so a reply from
            -- a different one is dropped and the catalog itself is asked for instead
            if args.revision ~= nil and dlg.quoteRevision ~= nil
                and args.revision ~= dlg.quoteRevision then
                dlg.cand = nil
                dlg.requoteRequired = true
                dlg.message = getText(T .. "Trade_Requote")
                C.requestShop()
                self:layoutBuy()
                return
            end
            local was = dlg.cand
            dlg.cand = args.ok ~= false and args
                or { count = 0, itemIds = {}, unitQty = 1, currency = dlg.currency,
                     revision = dlg.quoteRevision, bidPrice = dlg.row.bidPrice, buyback = args.buyback }
            -- a backpack price that moved under an open dialog is a new quote, not a repaint
            if was ~= nil and tonumber(was.bidPrice) ~= tonumber(dlg.cand.bidPrice) then
                dlg.requoteRequired = true
                dlg.message = getText(T .. "Trade_Requote")
            elseif args.ok == false then
                dlg.message = shopError(args.error, args.recovery, args.recoveryDetail)
            end
            -- the answer carries this currency's own allowances: a count they cannot cover is
            -- cut now, and the cut says so instead of happening under the player
            dlg:clampCount()
            self:layoutBuy()
        end
        return
    end
    -- shop.buy / shop.sell: only the reply this page is waiting for (the server echoes the requestId)
    local pending = self.buyPending
    if pending and args.requestId ~= nil and args.requestId ~= pending.requestId then return end
    self.buyPending = nil
    -- the write is over: a catalog that landed while it was out is read now, and a sale asks
    -- for the backpack prices of that catalog again
    self:resumeBuyDialog()
    if args.ok then
        local name = (args.item and itemName(args.item)) or (pending and pending.name) or ""
        self:closeBuy()
        if kind == "sell" then
            C.toast(getText(T .. "Shop_Sold", name, tostring(tonumber(args.qty) or 0),
                W.moneyText(args.total, args.currency)))
            return
        end
        -- the receipt is the server's own: what it really debited, in the currency it debited
        -- it from -- never the numbers the dialog happened to be showing
        C.toast(getText(T .. "Shop_Bought", name, tostring(tonumber(args.qty) or 0),
            W.moneyText(args.total, args.currency)))
        local note = deliveryNote(args)
        if note then C.toast(note) end
        return
    end
    if args.error == "catalog_changed" then C.requestShop() end
    -- The server re-checked the room before it debited anything and found the purchase would
    -- have to be parked: no money moved, no letter was written, and the dialog stays up saying
    -- so until the player presses confirm a second time.
    if args.error == "mail_confirmation_required" then
        local dlg = self.buyDialog
        if dlg then
            dlg.mailRequired = true
            dlg.message = getText(T .. "Delivery_ConfirmMail")
            return
        end
        C.toast(getText(T .. "Delivery_ConfirmMail"))
        return
    end
    -- the buyback cap refusals carry how much room is left today
    local code = tostring(args.error or "unknown")
    if args.remaining ~= nil and getTextOrNull(T .. "Shop_Error_" .. code) then
        self:buyMessage(getText(T .. "Shop_Error_" .. code, tostring(math.floor(tonumber(args.remaining) or 0))))
    else
        self:buyMessage(shopError(args.error, args.recovery, args.recoveryDetail))
    end
end

function Panel:onMail(kind, args)
    self:updateMailTab(args.unclaimed)
    self:rebuildMail()
    if kind == "list" then
        -- the capacity row under the card title exists only while the server sends its usage
        if self.shown and self.g then self:layout() end
        return
    end
    local pending = self.mailPending
    if pending and args.requestId ~= nil and args.requestId ~= pending.requestId then return end
    if kind == "claimAll" then return self:onMailBatchReply(args) end
    self.mailPending = nil
    if args.ok then
        local name = (args.item and itemName(args.item)) or (pending and pending.name) or ""
        C.toast(getText(T .. "Mail_Claimed", name, tostring(tonumber(args.qty) or 0)))
        local note = deliveryNote(args)
        if note then C.toast(note) end
    else
        -- a refusal of the claim (not at a terminal, already claimed) is one message; a
        -- hand-over that only settled part of the letter is another, and it says how many items
        -- went into the backpack and how many letters are still waiting
        C.toast(deliveryNote(args) or shopError(args.error, args.recovery, args.recoveryDetail))
    end
end

-- ----- the header identity -----

-- The whole account, in the session's own record window: the header chip shows what fits in a
-- row, and this is where a long or a CJK name is read complete and handed to the clipboard by
-- the window's own CopyAll. Pressing the chip again closes it, the way every other note chip in
-- this mod behaves; with no account to name there is nothing to open and nothing is opened.
function Panel:onIdentity()
    local account = self:username()
    if account == nil then return end
    if Detail.isOpen(self, "identity") then Detail.close(self); return end
    Detail.open(self, "identity", getText(T .. "Player_IdentityTitle"), account)
end

-- ----- market -----

-- The player's own account name: an own listing must not be sold back to them, and the server
-- says so too (own_listing) — this only keeps the chip from lying. The fixed header identity
-- reads this very value. Only a real name is ever remembered: in the frames before the player
-- object exists the answer is "not yet", never a "there is none" that would outlive the world's
-- own start-up and leave the header reading "loading" for the rest of the session.
function Panel:username()
    local cached = self.playerName
    if type(cached) == "string" then return cached end
    local ok, value = pcall(function() return getPlayer():getUsername() end)
    if not ok or type(value) ~= "string" or value == "" then return nil end
    self.playerName = value
    return value
end

-- The market numbers live in three snapshots (browse, own listings, backpack candidates) and
-- every page needs a bit of each. One table, refilled in place: prerender reads it every frame.
function Panel:updateMarketInfo()
    local m, cand, mine = C.market, C.candidates, C.myListings
    local info = self.marketInfo or {}
    info.feePercent = tonumber(cand and cand.feePercent) or tonumber(m and m.feePercent) or 0
    info.taxPercent = tonumber(cand and cand.taxPercent) or tonumber(m and m.taxPercent) or 0
    info.priceMin = tonumber(cand and cand.priceMin) or tonumber(m and m.priceMin) or 1
    info.priceMax = tonumber(cand and cand.priceMax) or tonumber(m and m.priceMax) or 0
    info.pages = math.max(1, tonumber(m and m.pages) or 1)
    info.total = tonumber(m and m.total) or 0
    info.mine = (mine and mine.items and #mine.items)
        or tonumber(m and m.mine) or tonumber(cand and cand.mine) or 0
    info.maxListings = tonumber(mine and mine.maxListings) or tonumber(m and m.maxListings)
        or tonumber(cand and cand.maxListings) or 0
    -- Mailbox slots (candidates reply): a listing needs one. `used` is the total the server
    -- itself counts over all three kinds (letters waiting, listings parked, auctions running),
    -- so this side never adds two of them up and calls it the whole.
    local usage = cand and cand.usage or nil
    if type(usage) == "table" and tonumber(usage.capacity) then
        info.mailUsed = tonumber(usage.used) or 0
        info.mailCapacity = tonumber(usage.capacity) or 0
    else
        info.mailUsed, info.mailCapacity = nil, nil   -- an older server: no gate on this side
    end
    self.marketInfo = info
    local b = self.marketMineButton
    if b then
        local title = getText(T .. "Market_MineCount", tostring(info.mine), tostring(info.maxListings))
        if b.fullTitle ~= title then
            b:setWidth(textWidth(title) + 22)
            U.setButtonTitle(b, title)
        end
    end
end

-- The server drops a second market.browse from the same player inside its 500 ms command
-- window without answering it (ECServer COMMAND_COOLDOWN_MS), so flipping two sort chips in a
-- row used to lose the second one for good. Every request goes through this gate: inside the
-- window nothing is sent, the wish is remembered, and prerender sends the *current* chip state
-- once the window is over (only the newest state can ever be wanted).
--
-- On top of that the page is `browseBusy` from the moment a request is wanted until the answer
-- lands (or BROWSE_TIMEOUT_MS passes): the sort chips, the sortable header and the pager are
-- disabled, so the player cannot queue a wish they can no longer see the state of.
local BROWSE_MIN_MS = 650
local BROWSE_TIMEOUT_MS = 5000
local SELLERS_TIMEOUT_MS = 8000

function Panel:sendBrowse()
    self.browseWanted = nil
    self.browseSentAt = EC.now()
    self.marketAt = self.browseSentAt
    -- nil currency is "every currency": the server answers with `all` and refuses a price sort
    -- there, which is exactly the state the sort box is filtered for
    C.requestMarket({ category = self.marketCat, query = self.marketQuery,
        sort = self.marketSort, page = self.marketPage, seller = self.marketSeller,
        currency = self.marketCur or "all" })
end

-- The currency filter of a browse page, and with it which sorts exist at all. Changing it is a
-- new question: back to page one, and a price sort that can no longer be honoured falls back
-- to the page default instead of being sent and refused.
function Panel:setBrowseCurrency(id)
    self.marketCur = id
    if id == nil and W.isPriceSort(self.marketSort) then self.marketSort = "time" end
    comboFill(self.marketSortCombo, sortKeysFor(MARKET_SORTS, id ~= nil),
        sortLabel(MARKET_SORTS), self.marketSort)
    -- the page is repainted against the new filter at once: the snapshot on screen belongs to
    -- the old one, and its rows of another currency must not sit there until the answer lands
    self:rebuildMarket()
    self:requestBrowse(1)
end

function Panel:onMarketCurrency(combo)
    local id = combo:getOptionData(combo.selected)
    id = (type(id) == "string" and id ~= "") and id or nil
    if id == self.marketCur then return end
    if self.browseBusy then
        comboSelect(combo, self.marketCur or "")   -- the page is waiting: put the box back
        return
    end
    self:setBrowseCurrency(id)
end

function Panel:requestBrowse(page)
    self.marketPage = math.max(1, tonumber(page) or 1)
    self.marketQueryAt = nil
    self.browseBusy = true
    self.browseBusyAt = EC.now()
    if self.browseSentAt and EC.now() - self.browseSentAt < BROWSE_MIN_MS then
        self.browseWanted = true
        return
    end
    self:sendBrowse()
end

-- ----- the seller candidate read (market.sellers) -----
--
-- A public read, so the two browse pages own it the way the admin window owns its own commands:
-- one request in flight, the same 650 ms client window that covers the server's 500 ms one, and
-- a timeout that frees the slot again. Both boxes share that single slot -- only one of the two
-- pages is ever on screen -- and each still matches an answer against its own context and
-- requestId, so a reply that crossed a page switch is dropped instead of being shown as the
-- candidates of the page that is up now. A refused send leaves the box's debounce armed: it
-- asks again on the next frame the window allows, so a keystroke is never silently lost.
function Panel:sellersSend(command, args)
    if command ~= "market.sellers" or getPlayer() == nil then return false end
    local now = EC.now()
    if self.sellersPendingAt ~= nil then return false end
    if self.sellersSentAt and now - self.sellersSentAt < BROWSE_MIN_MS then return false end
    self.sellersPendingAt = now
    self.sellersSentAt = now
    self.sellersRequestId = args.requestId
    C.requestSellers(args.query, args.context, args.requestId)
    return true
end

-- A whole candidate was picked: that -- and only that -- pins the exact seller the server
-- compares byte for byte. Back to page 1, because the page the player was on counted the whole
-- board; the keyword, the category and the sort stay exactly as they are.
function Panel:onMarketSellerPicked(entry)
    if entry.username == self.marketSeller then return end
    self.marketSeller = entry.username
    self:requestBrowse(1)
end

function Panel:onMarketSellerClear()
    self.marketSellerPicker:setText("")
    self.marketSellerPicker:close()
    if self.marketSeller == nil then return end
    self.marketSeller = nil
    self:requestBrowse(1)
end

function Panel:onAuctionSellerPicked(entry)
    if entry.username == self.auctionSeller then return end
    self.auctionSeller = entry.username
    self:requestAuctionBrowse(1)
end

function Panel:onAuctionSellerClear()
    self.auctionSellerPicker:setText("")
    self.auctionSellerPicker:close()
    if self.auctionSeller == nil then return end
    self.auctionSeller = nil
    self:requestAuctionBrowse(1)
end

-- The category box offers the categories the current page actually carries (plus "all"), the same
-- rule the shop follows; the server names them, the client only translates.
function Panel:rebuildMarketCategories()
    local seen, cats, sig = {}, { "" }, ""
    for _, cat in ipairs(C.market and C.market.categories or {}) do
        if type(cat) == "string" and cat ~= "" and not seen[cat] then
            seen[cat] = true
            cats[#cats + 1] = cat
            sig = sig .. cat .. ","
        end
    end
    if self.marketCat and not seen[self.marketCat] then self.marketCat = nil end
    if sig == self.marketCatSig then return end
    self.marketCatSig = sig
    comboFill(self.marketCatCombo, cats, function(cat)
        -- DisplayCategory names come from the item scripts: vanilla translates them under
        -- IGUI_ItemCat_<cat> (ISInventoryPane.lua:2533), an unknown one shows the raw name
        if cat == "" then return getText(T .. "Shop_All") end
        return getTextOrNull("IGUI_ItemCat_" .. cat) or cat
    end, self.marketCat or "")
end

-- The server paged and sorted this list already; the only thing it could not match is the
-- translated name (it never sees the player's language), so the search text runs over the page
-- once more here — that is also why an empty result says "no match" and not "empty market".
function Panel:rebuildMarket()
    local mine = self.marketMode == "mine"
    local snap = mine and C.myListings or C.market
    local src = (snap and snap.items) or {}
    local query = (not mine) and self.marketQuery or nil
    -- the filter in force, applied to whatever snapshot is on screen: between choosing a
    -- currency and its answer landing, the old page must not keep showing rows of the currency
    -- the player just filtered out
    local currency = (not mine) and self.marketCur or nil
    local username = self:username()
    local rows = {}
    for _, it in ipairs(src) do
        -- the currency is the listing's own, never the page's: a mixed page quotes each row in
        -- what its seller set, and a row that carries none says so instead of borrowing one
        local row = listingRow(it, username, self.offsetMin, mine)
        if (currency == nil or row.currency == currency)
            and (query == nil or string.find(string.lower(row.name), query, 1, true)
            or (row.altName and string.find(string.lower(row.altName), query, 1, true))
            or string.find(string.lower(tostring(row.item)), query, 1, true)
            or string.find(string.lower(row.seller), query, 1, true)) then
            rows[#rows + 1] = row
        end
    end
    self.marketNoMatch = #rows == 0 and #src > 0
    self.marketRows = rows
    self.marketList:setItems(rows)
end

function Panel:rebuildCandidates()
    local rows = {}
    for _, it in ipairs(C.candidates and C.candidates.items or {}) do
        rows[#rows + 1] = candidateRow(it)
    end
    self.candidateRows = rows
    local dlg = self.marketDialog
    if dlg and dlg.mode == "pick" then
        dlg.pickNote = nil     -- a fresh backpack: the refusal on the status line may be stale
        dlg:rebuildGrid()
    end
end

-- The server keeps the ring oldest first (it appends); the filter bar sorts, filters and pages
-- it (newest first by default). The whole ring stays in marketHistoryAll: every chip and every
-- date keystroke re-pages that list without another round trip.
function Panel:rebuildMarketHistory()
    local snap = C.marketHistory
    local src = (snap and snap.entries) or {}
    local rows = {}
    for i = #src, 1, -1 do
        rows[#rows + 1] = historyRow(src[i], self.offsetMin)
    end
    self.marketHistoryAll = rows
    local bar = self.historyBar
    if bar:syncKinds(rows) and self.g then self:layout() end
    local page, pages, total
    rows, page, pages, total = EC.filterPage(bar:search(rows), bar:opts("ts"))
    bar:setPage(page, pages, total)
    self.marketHistoryRows = rows
    self.marketHistoryList:setItems(rows)
end

-- Whatever the visible mode wants from the server (mode chips, refresh chip, seller notice).
function Panel:requestMarketMode()
    if self.marketMode == "mine" then
        C.requestMyListings()
    elseif self.marketMode == "history" then
        self:requestMarketHistory()
    else
        self:requestBrowse(self.marketPage)
    end
end

function Panel:onMarketMode(button)
    if self.marketMode == button.internal then return end
    self.marketMode = button.internal
    Detail.close(self)          -- the record belongs to the page that is being left
    for _, b in ipairs(self.marketModeButtons) do b.active = b.internal == self.marketMode end
    self:closeMarketDialog()
    self:closeCombos()
    self:rebuildMarket()
    self:rebuildMarketHistory()
    self:layout()
    self:requestMarketMode()
end

function Panel:onMarketSort(combo)
    local key = combo:getOptionData(combo.selected)
    if self.browseBusy then
        comboSelect(combo, self.marketSort)   -- the page is waiting: put the box back
        return
    end
    if type(key) ~= "string" or key == self.marketSort then return end
    self.marketSort = key
    self:requestBrowse(1)
end

-- A click on the table header: the same column again flips the direction, a new one starts
-- ascending. Anything that is not a column (the icon column left of the item name, the gaps
-- between two columns) is the plain default sort, newest listing first. Every key the header can
-- produce is one the sort box also offers, so the two never disagree -- and a key the server does
-- not accept would be answered with the default page, which the throttle would then re-ask for.
function Panel:onMarketHeader(x)
    if self.marketMode ~= "browse" or self.browseBusy then return end
    local key = "time"
    for _, c in ipairs(self.marketHeaderHits or {}) do
        -- a caption column (the own-listings table sorts by nothing) is not a hit target
        if c.sortable ~= false and x >= c.x and x < c.x + c.w then key = c.key end
    end
    -- prices of two currencies do not compare, and the server says so (currency_required):
    -- the click is answered here instead of being sent and refused
    if W.isPriceSort(key) and self.marketCur == nil then
        C.toast(getText(T .. "Market_CurrencyRequired"))
        return
    end
    if key ~= "time" and self.marketSort == key then key = key .. "_desc" end
    if key == self.marketSort then return end
    self.marketSort = key
    comboSelect(self.marketSortCombo, key)
    self:requestBrowse(1)
end

function Panel:onMarketCat(combo)
    if self.browseBusy then
        comboSelect(combo, self.marketCat or "")
        return
    end
    local cat = combo:getOptionData(combo.selected)
    cat = (type(cat) == "string" and cat ~= "") and cat or nil
    if cat == self.marketCat then return end
    self.marketCat = cat
    self:requestBrowse(1)
end

-- Typing filters the page at once; the server hears about it when the typing stops (a command
-- per keystroke would be dropped by the 500 ms throttle anyway).
function Panel:onMarketSearch()
    local query = string.lower(string.match(entryText(self.marketEntry), "^%s*(.-)%s*$"))
    self.marketQuery = query ~= "" and query or nil
    self.marketQueryAt = EC.now() + 500
    self:rebuildMarket()
end

function Panel:onMarketRefresh()
    self.marketHistoryError = nil
    self:requestMarketMode()
end

function Panel:onMarketPage(button)
    if self.browseBusy then return end
    local page = self.marketPage + button.internal
    if page < 1 or page > self.marketInfo.pages then return end
    self:requestBrowse(page)
end

function Panel:onMarketAction(row, actionId)
    if row == nil then return end
    if self.marketDialog or self.marketPending or not self:tradeAllowed() then return end
    if actionId == "cancel" then
        if row.mine then self:openMarketDialog("cancel", row) end
        return
    end
    -- a record the server is holding (its currency cannot be proven) is not bought from here
    if row.blocked ~= nil then
        C.toast(marketError({ error = row.blocked }))
        return
    end
    if not row.own then self:openMarketDialog("buy", row) end
end

-- ----- the record of one row -----
-- A table cuts a long name to its column; the whole record is read in the session's own floating
-- window (ECDetailWindow), which scrolls, copies its untruncated text and closes on its own X or
-- on Escape. One implementation for every page, built when a row is opened or refreshed and
-- never per frame.

-- Every string one row of one table has to spell out, in reading order.
function Panel:detailText(kind, e)
    local out = {}
    if kind == "statement" then
        out[1] = detailLine("Wallet_Col_Time", e.time)
        out[2] = detailLine("Wallet_Col_Kind", e.kindText)
        out[3] = detailLine("Wallet_Col_Desc", e.desc)
        out[4] = detailLine("Wallet_Col_Amount", e.amountText)
        out[5] = detailLine("Wallet_Col_Balance", amountText(e.after))
        if e.rolledBack then out[#out + 1] = getText(T .. "Wallet_RolledBack") end
        if e.txId then out[#out + 1] = detailLine("Detail_TxId", e.txId) end
        if e.reasonText and e.reasonText ~= "" then out[#out + 1] = detailLine("Admin_Tx_Field_Reason", e.reasonText) end
        return out
    end
    if kind == "balance" then
        out[1] = e.name
        out[2] = detailLine("Wallet_Available", e.availableText)
        out[3] = detailLine("Wallet_Reserved", e.reservedText)
        out[4] = detailLine("Wallet_Cap", e.capText)
        out[5] = detailLine("Wallet_ThisMonth", e.monthText)
        if not e.enabled then out[#out + 1] = getText(T .. "Wallet_CurrencyOff") end
        return out
    end
    if kind == "history" then
        out[1] = e.nameText
        out[2] = detailLine("Filter_Kind", e.kindText)
        out[3] = detailLine("Wallet_Col_Amount", e.amountText)
        out[4] = e.detailText
        if e.rolledBack then out[#out + 1] = getText(T .. "Wallet_RolledBack") end
        return out
    end
    -- every item row (shop, market, auction, mailbox): the localised name, the script's own name
    -- and the fullType a command or a file edit needs, then that table's own columns
    out[1] = e.name or e.nameText
    if e.altName and e.altName ~= out[1] then out[#out + 1] = e.altName end
    out[#out + 1] = tostring(e.item)
    if e.statusText and e.statusText ~= "" then out[#out + 1] = e.statusText end
    if kind == "shop" then
        out[#out + 1] = e.qtyText
        out[#out + 1] = detailLine("Trade_Currency", e.currencyText)
        out[#out + 1] = detailLine("Shop_Col_Price", W.moneyText(e.price, e.currency))
        out[#out + 1] = detailLine("Shop_Col_Remaining", e.remainText)
        -- whose share the cap counts (this account per day, the whole server per day, or this
        -- account for good) and how much of it is already spent. The row cannot say either in
        -- its column, and "per player per day" is not a fact for every sku.
        if e.dailyCap > 0 then
            out[#out + 1] = detailLine("Shop_CapScope", e.capScopeText)
            out[#out + 1] = detailLine("Shop_Used", e.usedText)
        end
        if e.buyback then out[#out + 1] = detailLine("Shop_Col_Bid", W.moneyText(e.bidPrice, e.currency)) end
        -- every currency this sku is quoted in, so the record says what switching would cost
        for _, q in ipairs(e.quotes or {}) do
            out[#out + 1] = W.currencyLabel(q.currency) .. "  "
                .. detailLine("Shop_Col_Price", W.moneyText(q.enabled and q.price or nil, q.currency))
        end
    elseif kind == "market" then
        out[#out + 1] = detailLine("Market_Col_Qty", tostring(e.qty))
        out[#out + 1] = detailLine("Trade_Currency", e.currencyText)
        out[#out + 1] = detailLine("Market_Col_LotPrice", W.moneyText(e.price, e.currency))
        out[#out + 1] = detailLine("Market_Col_Expires", e.expiresText)
        if not e.mine then out[#out + 1] = detailLine("Market_Col_Seller", e.seller) end
    elseif kind == "auction" then
        out[#out + 1] = detailLine("Market_Col_Qty", tostring(e.qty))
        out[#out + 1] = detailLine("Trade_Currency", e.currencyText)
        out[#out + 1] = detailLine("Auction_Col_Bid", e.priceText .. " " .. e.currencyText)
        out[#out + 1] = detailLine("Auction_Col_Bids", e.bidsText)
        out[#out + 1] = detailLine("Auction_Col_Ends", e.expiresText)
        out[#out + 1] = detailLine("Market_Col_Seller", e.seller)
        -- the plain column name, never Auction_History_Id: that one is a "%1" template
        out[#out + 1] = detailLine("Auction_Col_Id", tostring(e.id))
    elseif kind == "mail" then
        out[#out + 1] = detailLine("Market_Col_Qty", tostring(e.qty))
        -- a letter that carries money names it; one that carries none says nothing
        if e.price ~= nil then
            out[#out + 1] = detailLine("Market_Col_LotPrice", W.moneyText(e.price, e.currency))
        end
        out[#out + 1] = detailLine("Mail_Col_From", e.fromText)
        -- the record spells the counterparty out under its own column name; a letter with no
        -- third party (a shop purchase, a return, an old one) has no such line at all
        if e.seller ~= nil then out[#out + 1] = detailLine("Market_Col_Seller", e.seller) end
        out[#out + 1] = detailLine("Wallet_Col_Time", e.timeText)
    end
    return out
end

-- Immutable history records have a content key; mutable listings and letters have an id.
local function detailKey(kind, e)
    if kind == "statement" or kind == "history" then return kind .. ":" .. e.recordKey end
    return kind .. ":" .. tostring(e.id)
end

-- What the record window is titled: the page the row came from, so it says what it is reading
-- without needing a caption of its own.
function Panel:detailTitle(kind)
    if kind == "statement" then return getText(T .. "Wallet_Statement") end
    if kind == "history" then
        return getText(T .. (self.tab == "Auction" and "Auction_History_Title" or "Market_History_Title"))
    end
    if kind == "shop" then return getText(T .. "Shop_Title") end
    if kind == "market" then return getText(T .. "Market_Title") end
    if kind == "auction" then return getText(T .. "Auction_Title") end
    return getText(T .. "Mail_Title")
end

-- Only a click or Enter opens a record. Remember its source list so another highlight or
-- another table's refresh cannot replace it.
function Panel:showDetail(kind, item, explicit)
    if item == nil then return end
    local key = detailKey(kind, item)
    local title = self:detailTitle(kind)
    local body = table.concat(self:detailText(kind, item), "\n")
    if explicit then
        self.detailList = nil
        for _, spec in ipairs(self.detailWatch or {}) do
            if spec.kind == kind and spec.list:getSelectedItem() == item then self.detailList = spec.list; break end
        end
        Detail.open(self, key, title, body)
    else
        Detail.update(self, key, title, body)
    end
end

-- The season's real-world deadline, as this client may honestly state it. C.seasonState is the
-- server's own complete metadata and the only thing allowed to answer here: its currentId has to
-- be the very season the reward state was built for, or the two are describing different seasons
-- and neither may be quoted against the other. Everything else says what it is -- an unread
-- deadline is not "manual" and never zero days, and a deadline that has already passed says the
-- server has not rotated yet instead of counting backwards or announcing a season nobody started.
-- This is real calendar time and labelled so: the survival figures below it are game time.
function Panel:seasonDeadlineLines(st, lines)
    local season = C.seasonState
    local current = type(season) == "table" and season.currentId or nil
    local meta = nil
    if current ~= nil and st.season ~= nil and current == st.season then
        for _, entry in ipairs(type(season.seasons) == "table" and season.seasons or {}) do
            if entry.id == current then meta = entry; break end
        end
    end
    local endsAt = meta ~= nil and tonumber(meta.endsAt) or nil
    if type(endsAt) == "number" and endsAt == endsAt and endsAt > -math.huge and endsAt < math.huge then
        local left = endsAt - EC.now()
        lines[#lines + 1] = (left > 0)
            and getText(T .. "Rewards_SeasonRemaining", U.realDurationText(left))
            or getText(T .. "Rewards_SeasonPending")
        lines[#lines + 1] = getText(T .. "Rewards_SeasonDeadline", stampText(endsAt, self.offsetMin))
    elseif meta ~= nil and meta.durationDays == 0 and meta.endsAt == nil then
        lines[#lines + 1] = getText(T .. "Rewards_SeasonManual")
    else
        lines[#lines + 1] = getText(T .. "Rewards_SeasonUnknown")
    end
end

-- The daily reward, worded from the server's own state. Nothing here recomputes eligibility:
-- how many claims today, how much online time this next one needs and whether it may be taken
-- at all are the server's answer, and a claim it refuses says which rule refused it instead of
-- leaving a grey button with no reason beside it. Online time is real connected time; this
-- side only formats the two numbers it is given.
function Panel:rewardLines(st)
    local claimed = math.max(0, math.floor(tonumber(st.claimedCount) or 0))
    local limit = math.max(1, math.floor(tonumber(st.dailyLimit) or 1))
    local left = math.max(0, math.floor(tonumber(st.remainingClaims) or 0))
    local played = math.max(0, tonumber(st.playedMs) or 0)
    local need = math.max(0, tonumber(st.requiredOnlineMs) or 0)
    local short = math.max(0, tonumber(st.remainingOnlineMs) or 0)
    local nextReset = tonumber(st.nextResetMs) or 0
    -- The daily check-in switched off by an admin (CheckinAmount = 0) is not "claim +0": the
    -- block says the server turned it off, and the milestones below are unaffected.
    local off = st.blockedReason == "checkin_disabled"
    local lines = {}
    if off then
        lines[1] = getText(T .. "Rewards_Error_checkin_disabled")
    else
        lines[1] = getText(T .. "Rewards_Claims", tostring(claimed), tostring(limit))
        lines[2] = getText(T .. "Rewards_ClaimsLeft", tostring(left))
        lines[3] = getText(T .. "Rewards_Amount", amountText(st.amount), C.currencyName(st.currency))
        lines[4] = getText(T .. "Rewards_OnlineProgress", tostring(math.floor(played / 60000)),
            tostring(math.floor(need / 60000)))
        if short > 0 then
            lines[#lines + 1] = getText(T .. "Rewards_NextClaimIn", durationText(short))
        elseif left > 0 and st.canClaim == true then
            lines[#lines + 1] = getText(T .. "Rewards_Ready")
        end
    end
    if not off and st.canClaim ~= true and st.blockedReason ~= nil then
        local code = tostring(st.blockedReason)
        lines[#lines + 1] = getTextOrNull(T .. "Rewards_Error_" .. code)
            or getText(T .. "Rewards_Blocked_generic", code)
    end
    lines[#lines + 1] = getText(T .. "Rewards_NextDay", stampText(nextReset, self.offsetMin),
        durationText(math.max(0, nextReset - EC.now())))
    if self.message then lines[#lines + 1] = self.message.text end
    lines[#lines + 1] = ""
    -- The season band: which season this is, when it ends on the real calendar, and only then
    -- the survival figures, which are game time. The deadline is stated even when the survival
    -- record could not be read -- how long this season still has to run does not depend on it.
    lines[#lines + 1] = getText(T .. "Rewards_Milestones", tostring(st.seasonNumber or "-"))
    self:seasonDeadlineLines(st, lines)
    if st.survivalError ~= nil then
        lines[#lines + 1] = getText(T .. "Season_SurvivalFailed", tostring(st.survivalError))
        return lines
    end
    if st.survivalKnown == true and type(st.survivalHours) == "number" then
        lines[#lines + 1] = getText(T .. "Rewards_SeasonSurvived", C.UI.survivalText(st.survivalHours * 60))
    else
        lines[#lines + 1] = getText(T .. "Season_SurvivalUnknown")
    end
    if type(st.bestSurvivalHours) == "number" then
        lines[#lines + 1] = getText(T .. "Rewards_SeasonBest", C.UI.survivalText(st.bestSurvivalHours * 60))
    end
    if st.survivalIncomplete == true then lines[#lines + 1] = getText(T .. "Season_Incomplete") end
    local nextM
    for _, m in ipairs(st.milestoneList or {}) do
        if not hasBit(st.milestones, m.index) then nextM = m; break end
    end
    lines[#lines + 1] = nextM and getText(T .. "Rewards_NextMilestone", tostring(nextM.days))
        or getText(T .. "Rewards_AllMilestones")
    for _, m in ipairs(st.milestoneList or {}) do
        lines[#lines + 1] = ""
        lines[#lines + 1] = getText(T .. "Rewards_MilestoneRow", tostring(m.days))
            .. "  " .. W.moneyText(m.amount, st.currency)
        lines[#lines + 1] = getText(T .. (hasBit(st.milestones, m.index) and "Rewards_Achieved" or "Rewards_Pending"))
    end
    return lines
end

-- The wrap follows the box width (U.setWrappedText keeps the unwrapped value on the box for the
-- copy chip). Called when the page's own data changes and when the layout resized the box; never
-- per frame. Only the two reading pages have a body here -- a row's record lives in its window.
function Panel:updateDetail()
    local box = self.detailBox
    if not box then return end
    local body = ""
    local balanceView = self.tab == "Wallet" and self.walletDetails
    local rewardsView = self.tab == "Rewards"
    local scroll = rewardsView and self.detailRewardsVisible and box:getYScroll() or nil
    if balanceView then
        body = self.balanceText or ""
    elseif rewardsView then
        local st = C.rewards
        if not st then scroll = 0 end
        self.detailRewards, self.detailRewardsSecond = st, math.floor(EC.now() / 1000)
        if st then
            body = table.concat(self:rewardLines(st), "\n")
        elseif C.rewardsError then
            body = getTextOrNull(T .. "Rewards_Error_" .. tostring(C.rewardsError))
                or getText(T .. "Rewards_Error_generic", tostring(C.rewardsError))
        else
            body = getText(T .. "Wallet_Loading")
        end
    end
    U.setWrappedText(box, body, box.width)
    if scroll then box:setYScroll(scroll) end
    self.detailRewardsVisible = rewardsView
    self.detailCopyButton:setEnable(body ~= "")
end

-- A changed highlight only updates the keyboard ring. On a source snapshot replacement,
-- refresh the explicitly opened record by identity, not by the list's current selection.
function Panel:syncDetail()
    local moved = false
    for _, spec in ipairs(self.detailWatch or {}) do
        local list = spec.list
        if list:getIsVisible() then
            local item, revision = list:getSelectedItem(), list.revision
            if item ~= spec.last or revision ~= spec.revision then
                if revision ~= spec.revision and self.detailList == list and Detail.isOpen(self) then
                    local found = false
                    for _, row in ipairs(list:getItems()) do
                        if Detail.isOpen(self, detailKey(spec.kind, row)) then
                            self:showDetail(spec.kind, row, false)
                            found = true
                            break
                        end
                    end
                    if not found then Detail.close(self); self.detailList = nil end
                end
                spec.last, spec.revision = item, revision
                moved = true
            end
        end
    end
    if moved then Keys.invalidate(self) end
end

function Panel:onFeeDetails()
    if self:isModal() or not self.feeInfoButton:getIsVisible() then return end
    self.detailList = nil
    Detail.open(self, "fees:" .. self.tab, getText(T .. "Trade_FeeDetails"), self.feeInfoButton.note)
end

-- What is copied is the untruncated value the box kept, so it is exactly what the player reads.
function Panel:onDetailCopy()
    local box = self.detailBox
    local value = self.detailCopyButton.enable and box and box.ecRawText or nil
    if type(value) ~= "string" or value == "" then return end
    local copied = Clipboard ~= nil and Clipboard.setClipboard ~= nil
        and pcall(Clipboard.setClipboard, value)
    C.toast(getText(T .. (copied and "Kb_Copied" or "Kb_CopyFailed")))
end

-- A row of any reading table: its whole record opens as the floating window, the row stays
-- picked, the list keeps its filters, its page and its scroll, and nothing is bought, claimed or
-- cancelled here. The keyboard arrives through the same call (Enter is what runs onSelect), and
-- pressing the same row again after the window was closed opens it again -- VirtualList reports
-- every click on a row, not only a changed selection.
function Panel:onDetailRow(kind, item)
    if item == nil then return end
    self:showDetail(kind, item, true)
    Keys.invalidate(self)
end

-- The history read of the page on screen that failed, as the server's own code, or nil. One
-- answer for the three reads: the retry chip and the note line both read it.
function Panel:historyFault()
    if self.tab == "Wallet" then return self.historyError end
    if self.tab == "Market" and self.marketMode == "history" then return self.marketHistoryError end
    if self.tab == "Auction" and self.auctionMode == "history" then return self.auctionHistoryError end
    return nil
end

-- The retry chip: the player asking for that read again, once. It goes through the same gate the
-- page always uses (the 650 ms window, one read in flight), so pressing it twice cannot pile a
-- second job on the command, and nothing here ever retries on its own.
function Panel:onHistoryRetry()
    if self:historyFault() == nil then return end
    if self.tab == "Wallet" then
        self:loadHistory()
    elseif self.tab == "Market" then
        self.marketHistoryError = nil
        self:requestMarketHistory()
    elseif self.tab == "Auction" then
        self.auctionHistoryError = nil
        self:requestAuctionHistory()
    end
    self:layout()
    Keys.invalidate(self)
end

function Panel:onMarketList()
    if self.marketDialog or self.marketPending or not self:tradeAllowed() then return end
    local info = self.marketInfo
    if info.maxListings > 0 and info.mine >= info.maxListings then return end
    self:openMarketDialog("pick")
end

function Panel:onCandidate(cand)
    local dlg = self.marketDialog
    if not dlg or dlg.mode ~= "pick" or not cand then return end
    local info = self.marketInfo or {}
    if info.mailCapacity and (info.mailUsed or 0) >= info.mailCapacity then return end   -- no slot for the listing
    if not cand.ok then
        dlg.pickNote = cand.detailText   -- the refusal belongs on the status line, not in a step
        return
    end
    -- the picker is shared: which page opened it decides the step it hands over to
    dlg.mode = dlg.forAuction and "auction" or "price"
    if dlg.forAuction then
        local info = self.auctionInfo
        dlg:setHourRange(info.minHours, info.maxHours)
    end
    dlg.cand = cand
    dlg.message = nil
    dlg.pickNote = nil
    setEntryText(dlg.priceEntry, "")
    setEntryText(dlg.qtyEntry, tostring(cand.count or 1))   -- the whole lot by default
    self:layoutMarketDialog()
    Keys.focusControl(dlg.priceEntry, Keys.isKeyboardFocused(dlg.pickList))
end

-- `forAuction` marks the picker (and the step it hands over to) as the auction page's own; the
-- auction steps ("bid", "auction", "acancel") set it too, so the dialog never has to guess.
function Panel:openMarketDialog(mode, row, forAuction)
    local trigger = Keys.focused()
    local keyboard = Keys.isKeyboardFocused(trigger)
    self:closeMarketDialog()
    local dlg = ISPanel:new(0, 0, 360, 200)
    setmetatable(dlg, MarketDialog)
    dlg.background = false
    dlg.panel = self
    dlg.mode = mode
    dlg.row = row
    dlg.forAuction = forAuction == true or AUCTION_MODES[mode] == true
    dlg.message = nil
    dlg.returnFocus = keyboard and trigger or nil
    -- The currency a new listing or auction will be fixed in. It starts on the page's own
    -- filter when one is chosen, else on the registered default - never on "whatever the last
    -- listing on the page happened to use".
    dlg.currency = (forAuction == true and self.auctionCur or self.marketCur) or defaultCurrency()
    dlg:initialise()
    self:addChild(dlg)      -- the buttons exist from here on (instantiate -> createChildren)
    self.marketDialog = dlg
    -- the same two rules the buy dialog follows: no native dropdown left floating over this
    -- panel, and no click beside it reaching the page (the backpack picker is one of its steps)
    self:closeCombos()
    self:updateModalGuard()
    for _, b in ipairs(dlg.currencyButtons) do b.active = b.internal == dlg.currency end
    if mode == "pick" then
        dlg:rebuildGrid()
        C.requestCandidates()
    end
    self:layoutMarketDialog()
    Keys.focusControl(mode == "pick" and dlg.pickList or dlg.cancelButton, keyboard)
    return dlg
end

function Panel:layoutMarketDialog() self:layoutDialog(self.marketDialog) end

function Panel:closeMarketDialog()
    local dlg = self.marketDialog
    if not dlg then return end
    self.marketDialog = nil
    pcall(function() dlg.priceEntry:unfocus() end)
    pcall(function() dlg.qtyEntry:unfocus() end)
    dlg:setVisible(false)
    self:removeChild(dlg)
    Keys.invalidate(self)
    self:updateModalGuard()
    self.marketReturnFocus = dlg.returnFocus
end

function Panel:marketMessage(str)
    if self.marketDialog then
        self.marketDialog.message = str
    else
        C.toast(str)
    end
end

-- One write in flight for the whole page (buy, list, cancel): the server answers with the
-- requestId, and prerender gives up on it after TIMEOUT_MS.
function Panel:submitMarket(dlg)
    if self.marketPending then return end
    if not self:tradeAllowed() then
        dlg.message = marketError({ error = "not_at_terminal" })
        return
    end
    local mode, price, itemIds, qty, listingId, name = dlg.mode, nil, nil, 1, nil, nil
    -- the currency of this write: the seller's choice when they are creating, the record's own
    -- when they are buying it. A step that moves money and has none is refused here; pulling
    -- an own listing back moves none at all, so it is allowed to go out without one.
    local currency = dlg:activeCurrency()
    if currency == nil and mode ~= "cancel" then
        dlg.message = marketError({ error = "currency_required" })
        return
    end
    if mode == "price" then
        local info = self.marketInfo
        price = dlg:priceValue()
        if price == nil or price < info.priceMin or (info.priceMax > 0 and price > info.priceMax) then
            dlg.message = getText(T .. "Market_Error_price_range", amountText(info.priceMin), amountText(info.priceMax))
            return
        end
        local count = dlg:lotCount()
        qty = dlg:qtyValue()
        if qty == nil then
            dlg.message = getText(T .. "Market_QtyHint", tostring(count), tostring(count))
            return
        end
        -- the lot the player asked for, taken off the front of the server's own id list
        itemIds, name = {}, dlg.cand.name
        for i = 1, qty do itemIds[i] = dlg.cand.itemIds[i] end
    else
        listingId, price, name = dlg.row.id, dlg.row.price, dlg.row.name
        -- a lot that does not fit is parked in the mailbox: the estimate says so, and the
        -- confirm has to be pressed a second time before that consent leaves this client
        local preview = dlg.preview
        if mode == "buy" and dlg.mailRequired ~= true and preview ~= nil and preview.willMail == true then
            dlg.mailRequired = true
            dlg.message = getText(T .. "Delivery_ConfirmMail")
            return
        end
    end
    dlg.message = nil
    self.marketPending = { requestId = C.newRequestId(), at = EC.now(), kind = mode, name = name,
        qty = qty, currency = currency }
    if mode == "buy" then
        -- the currency travels with the offer only so the server can check the two agree: it
        -- settles in the listing's own, never in one this client picked
        C.buyListing(listingId, price, currency, self.marketPending.requestId, dlg.mailRequired == true)
    elseif mode == "cancel" then
        C.cancelListing(listingId, self.marketPending.requestId)
    else
        C.listItem(itemIds, price, currency, self.marketPending.requestId)
    end
end

function Panel:onMarket(kind, args)
    -- the auction pages ride this listener: their kinds carry the "auction." prefix
    local auctionKind = string.match(kind, "^auction%.(.+)$")
    if auctionKind then return self:onAuction(auctionKind, args) end
    if kind == "notice" then
        -- the server told an online seller their listing left the market (or moved an auction
        -- under its bidders): the page it is on is now out of date, and ECClient already
        -- raised the toast
        self:updateMailTab(args.unclaimed)
        if not self.shown or self.isCollapsed then return end
        if self.tab == "Market" then self:requestMarketMode()
        elseif self.tab == "Auction" then self:requestAuctionMode() end
        return
    end
    if kind == "whitelist" then
        local open = self.marketDialog
        if open and open.mode == "pick" then C.requestCandidates() end
        return
    end
    -- The shared slot is released by the very read that reserved it, matched on that read's own
    -- requestId: a stale answer can never free a slot a newer read owns, and a box that was
    -- folded away by a page switch does not hold the slot for the whole timeout either. Which
    -- box (if any) still wants the candidates is a separate question, and each answers it for
    -- itself.
    if kind == "sellers" then
        if args.requestId ~= nil and args.requestId == self.sellersRequestId then
            self.sellersPendingAt, self.sellersRequestId = nil, nil
        end
        if not self.marketSellerPicker:onReply(args) then self.auctionSellerPicker:onReply(args) end
        return
    end
    if kind == "history" then
        -- the ring takes no parameters, so only the read this page is waiting for can answer it;
        -- the code itself is kept, because historyError() words it as the read it was (never a
        -- claim) and the page pairs it with historyRetryButton
        if self.marketGate:accept(args, "ring") == "stale" then return end
        if args.error then
            self.marketHistoryError = tostring(args.error)
        else
            -- accepted, and it carries real data: this answer *is* the page's ring now. The
            -- gate already dropped every reply for another read, so nothing older lands here.
            self.marketHistoryError = nil
            C.marketHistory = args
        end
        self:rebuildMarketHistory()
        self:layout()   -- the kind chips of the bar (and with them the table) may have moved
        return
    end
    if kind == "browse" or kind == "mine" or kind == "candidates" then
        if kind == "browse" then
            self.marketAt = EC.now()
            self.browseBusy = nil
            -- an answer to a request the player has already moved past (the throttle window
            -- swallowed the newer one): keep the chips as they are and ask again
            local page = tonumber(args.page)
            if (args.sort ~= nil and args.sort ~= self.marketSort)
                or ((args.category or "") ~= (self.marketCat or ""))
                or ((args.seller or "") ~= (self.marketSeller or ""))
                or ((args.currency or "all") ~= (self.marketCur or "all"))
                or (page ~= nil and page ~= self.marketPage) then
                self.browseWanted = true
                return
            else
                self.marketPage = math.max(1, page or self.marketPage)
                C.market = args
            end
            self:rebuildMarketCategories()
        end
        self:updateMarketInfo()
        if kind == "candidates" then self:rebuildCandidates() else self:rebuildMarket() end
        self:layout()   -- the chip rows (and the mine counter's own width) may have moved
        return
    end
    -- a write answer: only the one this page is waiting for
    self:updateMailTab(args.unclaimed)
    local pending = self.marketPending
    if pending and args.requestId ~= nil and args.requestId ~= pending.requestId then return end
    self.marketPending = nil
    self:updateMarketInfo()
    self:rebuildMarket()      -- market.list / market.cancel bring the fresh own listings with them
    if args.ok then
        local name = (pending and pending.name) or (args.item and itemName(args.item)) or ""
        self:closeMarketDialog()
        if kind == "buy" then
            C.toast(getText(T .. "Market_Bought", name, W.moneyText(args.price, args.currency)))
        elseif kind == "list" then
            local listed = math.max(1, math.floor(tonumber(args.qty) or (pending and pending.qty) or 1))
            local fee = W.moneyText(args.fee, args.currency or (pending and pending.currency))
            if listed > 1 then
                C.toast(getText(T .. "Market_ListedQty", name, tostring(listed), fee))
            else
                C.toast(getText(T .. "Market_Listed", name, fee))
            end
        else
            -- a cancelled listing goes through the mailbox and is handed straight back when
            -- there is room: the result is one message, and a hand-over that failed is another
            C.toast(getText(T .. "Market_Cancelled"))
        end
        local note = deliveryNote(args)
        if note then C.toast(note) end
        if kind == "buy" then self:requestBrowse(self.marketPage)
        elseif kind == "list" then
            C.requestMyListings()
            if self.marketMode ~= "mine" then self:requestBrowse(self.marketPage) end   -- the new row belongs on the browse page too
        end
        self:layout()
        return
    end
    -- the price moved under the player: show why, and put the current page back on screen
    if kind == "buy" and args.error == "price_changed" then self:requestBrowse(self.marketPage) end
    if kind == "buy" and args.error == "mail_confirmation_required" then
        -- the server re-checked the room before it debited anything: nothing moved, and the
        -- dialog stays up until the player confirms the mailbox a second time
        local dlg = self.marketDialog
        if dlg then
            dlg.mailRequired = true
            dlg.message = getText(T .. "Delivery_ConfirmMail")
            return
        end
        C.toast(getText(T .. "Delivery_ConfirmMail"))
        return
    end
    -- The offer named a currency the record does not settle in. The step is not patched in
    -- place: a currency swapped under an open confirmation would have the player pressing a
    -- price they never read. The step is closed, the page's own listing is read again in full,
    -- and the trade starts over from that fresh quote.
    if args.error == "currency_mismatch" then
        self:closeMarketDialog()
        C.toast(marketError(args))
        self:requestMarketMode()
        return
    end
    self:marketMessage(marketError(args))
end

-- A terminal was registered or removed: the shop/mail snapshots carry the server's own
-- atTerminal flag, so the visible page asks again instead of trusting a stale gate.
function Panel:onTerminals()
    if not self.shown or self.isCollapsed then return end
    if self.tab == "Shop" then
        self.shopAt = EC.now()
        C.requestShop()
    elseif self.tab == "Mail" then
        C.requestMail()
    elseif self.tab == "Market" then
        self:onMarketRefresh()
    elseif self.tab == "Auction" then
        self:onAuctionRefresh()
    end
end

-- ----- auction -----
-- The auction page mirrors the market one: a throttled browse (the server drops a second
-- command inside its 500 ms window), a busy flag that closes the header and the pager until
-- the answer lands, and one write in flight at a time (the market's `marketPending`, shared:
-- one window can only ever hold one dialog).

function Panel:updateAuctionInfo()
    local a, mine = C.auction, C.myAuctions
    local info = self.auctionInfo or {}
    info.taxPercent = tonumber(a and a.taxPercent) or 0
    info.feePercent = tonumber(a and a.feePercent) or 0
    info.minHours = math.max(1, tonumber(a and a.minHours) or 1)
    info.maxHours = math.max(info.minHours, tonumber(a and a.maxHours) or info.minHours)
    info.pages = math.max(1, tonumber(a and a.pages) or 1)
    info.total = tonumber(a and a.total) or 0
    info.maxAuctions = tonumber(mine and mine.maxAuctions) or tonumber(a and a.maxAuctions) or 0
    info.mine = (mine and mine.selling and #mine.selling) or tonumber(a and a.mine) or 0
    self.auctionInfo = info
    local b = self.auctionMineButton
    if b then
        local title = getText(T .. "Auction_Mine", tostring(info.mine), tostring(info.maxAuctions))
        if b.fullTitle ~= title then
            b:setWidth(textWidth(title) + 22)
            U.setButtonTitle(b, title)
        end
    end
end

function Panel:sendAuctionBrowse()
    self.auctionWanted = nil
    self.auctionSentAt = EC.now()
    C.requestAuctions({ query = self.auctionQuery, sort = self.auctionSort,
        page = self.auctionPage, seller = self.auctionSeller,
        currency = self.auctionCur or "all" })
end

-- Same rule as the market's filter: "every currency" has no price order, so those keys are not
-- offered there at all.
function Panel:setAuctionCurrency(id)
    self.auctionCur = id
    if id == nil and W.isPriceSort(self.auctionSort) then self.auctionSort = "ending" end
    comboFill(self.auctionSortCombo, sortKeysFor(AUCTION_SORTS, id ~= nil),
        sortLabel(AUCTION_SORTS), self.auctionSort)
    self:rebuildAuctions()
    self:requestAuctionBrowse(1)
end

function Panel:onAuctionCurrency(combo)
    local id = combo:getOptionData(combo.selected)
    id = (type(id) == "string" and id ~= "") and id or nil
    if id == self.auctionCur then return end
    if self.auctionBusy then
        comboSelect(combo, self.auctionCur or "")
        return
    end
    self:setAuctionCurrency(id)
end

function Panel:requestAuctionBrowse(page)
    self.auctionPage = math.max(1, tonumber(page) or 1)
    self.auctionQueryAt = nil
    self.auctionBusy = true
    self.auctionBusyAt = EC.now()
    if self.auctionSentAt and EC.now() - self.auctionSentAt < BROWSE_MIN_MS then
        self.auctionWanted = true
        return
    end
    self:sendAuctionBrowse()
end

-- ----- auction record -----
-- The typed query is debounced here (a keystroke per command would be dropped by the server's
-- own window anyway); everything after that - the window, the one read in flight, the wish of a
-- page that is not on screen - is the gate all three history reads share.
local HISTORY_DEBOUNCE_MS = 650

-- The question this page is asking, as one comparable string: a pinned auction is an exact
-- lookup, everything else is the search text (empty for the whole record). A reply is matched
-- against it, so an answer to a question the player has already typed past is never applied.
local function auctionQueryKey(auctionId, query)
    if auctionId ~= nil then return "id:" .. tostring(auctionId) end
    return "q:" .. tostring(query or "")
end

function Panel:requestAuctionHistory()
    self.auctionHistoryQueryAt = nil
    self.auctionGate:want(auctionQueryKey(self.auctionHistoryId, self.auctionHistoryQuery),
        self:pageVisible("Auction", "history"))
end

-- Drop queued work when leaving, but remember the real in-flight reader until its reply or
-- timeout. Reopening must not submit a second job while that reader still owns the command.
function Panel:cancelAuctionHistory()
    self.auctionHistoryQueryAt = nil
    self.auctionGate:clear()
end

-- The reply is oldest first (the server appends); the filter bar sorts, filters and pages it
-- newest first, exactly the way the market ring is paged, and the whole snapshot stays in
-- auctionHistoryAll so a chip or a date keystroke costs no round trip.
function Panel:rebuildAuctionHistory()
    local snap = C.auctionHistory
    local src = (snap and snap.entries) or {}
    local rows = {}
    for i = #src, 1, -1 do
        rows[#rows + 1] = auctionHistoryRow(src[i], self.offsetMin)
    end
    self.auctionHistoryAll = rows
    local bar = self.auctionHistoryBar
    if bar:syncKinds(rows) and self.g then self:layout() end
    local page, pages, total
    rows, page, pages, total = EC.filterPage(rows, bar:opts("ts"))
    bar:setPage(page, pages, total)
    self.auctionHistoryRows = rows
    self.auctionHistoryList:setItems(rows)
end

-- Both the mode chips and a row's record chip land here: the mode, its chips, the open dialog
-- and the tables - never the search box, because the caller owns what the box asks next.
function Panel:switchAuctionMode(mode)
    self.auctionMode = mode
    for _, b in ipairs(self.auctionModeButtons) do b.active = b.internal == mode end
    self:closeMarketDialog()
    self:closeCombos()
    Detail.close(self)           -- the record belongs to the mode that is being left
    self:rebuildAuctions()
    if mode == "history" then self:rebuildAuctionHistory() end
    self:layout()
end

-- The record chip of one row: the page switches to the record mode and asks for that auction's
-- own timeline (a read: no terminal, no dialog and no cancel needed to look at it). The box
-- shows the pinned id, so the player sees what is pinned and drops it by typing over it.
function Panel:openAuctionHistory(auctionId)
    if auctionId == nil then return end
    self.auctionMode = "history"         -- set first: the box change below routes on the mode
    self.auctionQuery, self.auctionQueryAt = nil, nil
    self.auctionHistoryId = tostring(auctionId)
    self.auctionHistoryQuery = nil
    setPlaceholder(self.auctionEntry, getText(T .. "Auction_History_Search"))
    setEntryText(self.auctionEntry, self.auctionHistoryId)
    self.auctionHistoryQueryAt = nil     -- the box change must not queue a second, unpinned read
    self:switchAuctionMode("history")
    self:requestAuctionHistory()
end

function Panel:requestAuctionMode()
    if self.auctionMode == "mine" then
        C.requestMyAuctions()
    elseif self.auctionMode == "history" then
        self:requestAuctionHistory()
    else
        self:requestAuctionBrowse(self.auctionPage)
    end
end

-- The server matched the untranslated name; the localised one is the client's own job, the
-- way the market page filters its page a second time.
local function auctionMatch(row, query)
    if query == nil then return true end
    return string.find(string.lower(row.name), query, 1, true) ~= nil
        or (row.altName ~= nil and string.find(string.lower(row.altName), query, 1, true) ~= nil)
        or string.find(string.lower(tostring(row.item)), query, 1, true) ~= nil
        or string.find(string.lower(row.seller), query, 1, true) ~= nil
end

function Panel:rebuildAuctions()
    local src = (C.auction and C.auction.items) or {}
    local query = self.auctionQuery
    -- the filter in force: a browse page never keeps rows of a currency the player filtered
    -- out, not even in the gap before the new answer lands
    local currency = self.auctionCur
    local rows = {}
    for _, it in ipairs(src) do
        -- each auction quotes the currency its seller fixed on it
        local row = auctionRow(it, "browse")
        if (currency == nil or row.currency == currency) and auctionMatch(row, query) then
            rows[#rows + 1] = row
        end
    end
    self.auctionNoMatch = #rows == 0 and #src > 0
    self.auctionRows = rows
    self.auctionList:setItems(rows)
    local selling, bidding = {}, {}
    for _, it in ipairs(C.myAuctions and C.myAuctions.selling or {}) do
        selling[#selling + 1] = auctionRow(it, "selling")
    end
    for _, it in ipairs(C.myAuctions and C.myAuctions.bidding or {}) do
        bidding[#bidding + 1] = auctionRow(it, "bidding")
    end
    self.auctionSellRows, self.auctionBidRows = selling, bidding
    self.auctionSellList:setItems(selling)
    self.auctionBidList:setItems(bidding)
end

-- The search box is shared by the browse and the record pages, so a mode change starts it empty
-- (and drops whatever the other page had queued): one box may only ever ask one question.
function Panel:onAuctionMode(button)
    if self.auctionMode == button.internal then return end
    self.auctionMode = button.internal   -- set first: the box change below routes on the mode
    self.auctionQuery, self.auctionHistoryQuery, self.auctionHistoryId = nil, nil, nil
    setPlaceholder(self.auctionEntry, getText(T .. (self.auctionMode == "history"
        and "Auction_History_Search" or "Market_Search")))
    setEntryText(self.auctionEntry, "")
    self.auctionQueryAt, self.auctionHistoryQueryAt = nil, nil
    self.auctionGate:clear()
    self:switchAuctionMode(button.internal)
    self:requestAuctionMode()
end

-- A click on the auction table header: the same column again flips the direction, a new one starts
-- ascending. Anything that is not a column falls back to the page default (the auctions closest to
-- their end first) - that is `ending`, not the market's `time`. Every key here is one the sort box
-- offers and one ECAuction.SORTS accepts.
function Panel:onAuctionHeader(x)
    if self.auctionMode ~= "browse" or self.auctionBusy then return end
    local key = "ending"
    for _, c in ipairs(self.auctionHeaderHits or {}) do
        if x >= c.x and x < c.x + c.w then key = c.key end
    end
    if W.isPriceSort(key) and self.auctionCur == nil then
        C.toast(getText(T .. "Market_CurrencyRequired"))
        return
    end
    if self.auctionSort == key then key = key .. "_desc" end
    if key == self.auctionSort then return end
    self.auctionSort = key
    comboSelect(self.auctionSortCombo, key)
    self:requestAuctionBrowse(1)
end

function Panel:onAuctionSort(combo)
    local key = combo:getOptionData(combo.selected)
    if self.auctionBusy then
        comboSelect(combo, self.auctionSort)   -- the page is waiting: put the box back
        return
    end
    if type(key) ~= "string" or key == self.auctionSort then return end
    self.auctionSort = key
    self:requestAuctionBrowse(1)
end

function Panel:onAuctionSearch()
    local raw = string.match(entryText(self.auctionEntry), "^%s*(.-)%s*$")
    if self.auctionMode == "history" then
        -- the pinned auction stays pinned only while the box still holds its id: the first
        -- keystroke that changes the text turns the lookup back into a free search
        if self.auctionHistoryId ~= nil and raw ~= self.auctionHistoryId then
            self.auctionHistoryId = nil
        end
        self.auctionHistoryQuery = raw ~= "" and raw or nil     -- the server matches it, not us
        self.auctionHistoryQueryAt = EC.now() + HISTORY_DEBOUNCE_MS
        return
    end
    local query = string.lower(raw)
    self.auctionQuery = query ~= "" and query or nil
    self.auctionQueryAt = EC.now() + 600
    self:rebuildAuctions()
end

function Panel:onAuctionRefresh()
    self:requestAuctionMode()
end

function Panel:onAuctionPage(button)
    if self.auctionBusy then return end
    local page = self.auctionPage + button.internal
    if page < 1 or page > self.auctionInfo.pages then return end
    self:requestAuctionBrowse(page)
end

-- A button inside an auction row. The record button is a read, so it answers before any of the
-- trade gates; the bid button opens the bid step (a raise on the "bidding on" list is the same
-- step), and an own auction may be pulled back only while nobody has bid on it - the server
-- refuses `has_bids` too, this only keeps the button from lying.
function Panel:onAuctionAction(row, actionId, context)
    if row == nil then return end
    if actionId == "history" then
        if row.id ~= nil then self:openAuctionHistory(row.id) end
        return
    end
    if self.marketDialog or self.marketPending or not self:tradeAllowed() then return end
    if actionId == "acancel" then
        if row.bids == 0 then self:openMarketDialog("acancel", row) end
        return
    end
    if row.blocked ~= nil then
        C.toast(marketError({ error = row.blocked }))
        return
    end
    if row.canBid then
        local dlg = self:openMarketDialog("bid", row)
        setEntryText(dlg.priceEntry, tostring(row.minNext))
    end
end

function Panel:onAuctionCreate()
    if self.marketDialog or self.marketPending or not self:tradeAllowed() then return end
    local info = self.auctionInfo
    if info.maxAuctions > 0 and info.mine >= info.maxAuctions then return end
    self:openMarketDialog("pick", nil, true)
end

function Panel:submitAuction(dlg)
    if self.marketPending then return end
    if not self:tradeAllowed() then
        dlg.message = marketError({ error = "not_at_terminal" })
        return
    end
    local mode = dlg.mode
    local currency = dlg:activeCurrency()
    if currency == nil and mode ~= "acancel" then
        dlg.message = marketError({ error = "currency_required" })
        return
    end
    local pending = { requestId = C.newRequestId(), at = EC.now(), kind = mode, currency = currency }
    if mode == "bid" then
        local amount = dlg:priceValue()
        if amount == nil or amount < dlg.row.minNext then
            dlg.message = marketError({ error = "bid_too_low", min = dlg.row.minNext })
            return
        end
        dlg.message = nil
        pending.name, pending.amount = dlg.row.name, amount
        self.marketPending = pending
        -- the bid is quoted in the auction's own currency; the server checks the two agree
        C.bidAuction(dlg.row.id, amount, currency, pending.requestId)
        return
    end
    if mode == "acancel" then
        dlg.message = nil
        pending.name = dlg.row.name
        self.marketPending = pending
        C.cancelAuction(dlg.row.id, pending.requestId)
        return
    end
    -- the create step: the price bounds are the picker's own (market.candidates quotes them)
    local info, aInfo = self.marketInfo, self.auctionInfo
    local price = dlg:priceValue()
    if price == nil or price < info.priceMin or (info.priceMax > 0 and price > info.priceMax) then
        dlg.message = getText(T .. "Market_Error_price_range", amountText(info.priceMin), amountText(info.priceMax))
        return
    end
    local hours = dlg.hours
    if hours == nil or hours < aInfo.minHours or hours > aInfo.maxHours then
        dlg.message = marketError({ error = "hours_range", min = aInfo.minHours, max = aInfo.maxHours })
        return
    end
    local count = dlg:lotCount()
    local qty = dlg:qtyValue()
    if qty == nil then
        dlg.message = getText(T .. "Market_QtyHint", tostring(count), tostring(count))
        return
    end
    local itemIds = {}
    for i = 1, qty do itemIds[i] = dlg.cand.itemIds[i] end
    dlg.message = nil
    pending.name, pending.qty, pending.price = dlg.cand.name, qty, price
    self.marketPending = pending
    C.createAuction(itemIds, price, hours, currency, pending.requestId)
end

function Panel:onAuction(kind, args)
    if kind == "browse" or kind == "mine" then
        if kind == "browse" then
            self.auctionBusy = nil
            -- an answer to a request the player has already moved past (the throttle window
            -- swallowed the newer one): keep the state as it is and ask again
            local page = tonumber(args.page)
            if (args.sort ~= nil and args.sort ~= self.auctionSort)
                or ((args.seller or "") ~= (self.auctionSeller or ""))
                or ((args.currency or "all") ~= (self.auctionCur or "all"))
                or (page ~= nil and page ~= self.auctionPage) then
                self.auctionWanted = true
                return
            else
                self.auctionPage = math.max(1, page or self.auctionPage)
                C.auction = args
            end
        end
        self:updateAuctionInfo()
        self:rebuildAuctions()
        self:layout()   -- the mine counter's own width may have moved
        return
    end
    -- The record page: a read, never a write. The gate matches the reply to the question it
    -- answers (the pinned auction, or the search text the player last stopped typing): another
    -- question is dropped because the read for the current one is still coming, an older read of
    -- the current question is shown at once, a refusal keeps the snapshot on screen instead of
    -- pretending the record is empty, and a reply after its own timeout still repairs the page.
    if kind == "history" then
        if self.auctionGate:accept(args, auctionQueryKey(args.auctionId, args.query)) == "stale" then
            return
        end
        if args.error then
            -- the code itself is kept: historyError() words it as the read it was (never a claim),
            -- and the page pairs it with historyRetryButton
            self.auctionHistoryError = tostring(args.error)
        else
            self.auctionHistoryError = nil
            self.auctionHistoryTruncated = args.truncated == true
            C.auctionHistory = args
            self:rebuildAuctionHistory()
        end
        self:layout()   -- the kind chips of the bar (and with them the table) may have moved
        return
    end
    -- a write answer: only the one this page is waiting for
    self:updateMailTab(args.unclaimed)
    local pending = self.marketPending
    if pending and args.requestId ~= nil and args.requestId ~= pending.requestId then return end
    self.marketPending = nil
    self:updateAuctionInfo()
    self:rebuildAuctions()
    if args.ok then
        local name = (pending and pending.name) or ""
        self:closeMarketDialog()
        if kind == "bid" then
            C.toast(getText(T .. "Auction_Placed",
                W.moneyText(args.amount, args.currency or (pending and pending.currency)), name))
            self:requestAuctionMode()
        elseif kind == "create" then
            local cur = args.currency or (pending and pending.currency)
            C.toast(getText(T .. "Auction_Created", name,
                W.moneyText(pending and pending.price, cur), W.moneyText(args.fee, cur)))
            self:setAuctionMode("mine")
        else
            -- a cancelled auction goes back through the mailbox and is handed straight over
            -- when there is room: the result is one message, a failed hand-over another
            C.toast(getText(T .. "Auction_Cancelled"))
            local note = deliveryNote(args)
            if note then C.toast(note) end
        end
        self:layout()
        return
    end
    -- same rule as the market: a bid whose currency the auction does not settle in closes the
    -- step and re-reads the auction, instead of confirming against a currency swapped in here
    if args.error == "currency_mismatch" then
        self:closeMarketDialog()
        -- the auction has wording of its own for this refusal; the market codes are the fallback
        C.toast(getTextOrNull(T .. "Auction_Error_currency_mismatch") or marketError(args))
        self:requestAuctionMode()
        return
    end
    self:marketMessage(marketError(args))
end

-- The create step lands the player on their own auctions: the row they just made is there.
function Panel:setAuctionMode(mode)
    if self.auctionMode ~= mode then
        self.auctionMode = mode
        for _, b in ipairs(self.auctionModeButtons) do b.active = b.internal == mode end
    end
    self:requestAuctionMode()
end

-- ----- geometry -----

function Panel:remoteReadOnly()
    return C.session ~= nil and C.session.remoteReadOnly == true
end

function Panel:currencies()
    return (C.wallet and C.wallet.currencies) or EC.CURRENCY_ORDER
end

-- The status band, most restrictive first: a frozen account outranks everything (nothing moves
-- until an admin unfreezes it), then the remote gate — no terminal registered at all, the player
-- standing at one, or the plain "walk to a terminal". nil = nothing to say, and only then does the
-- band cost the workspace a row. Read by layout() (it decides where the content starts) and by
-- prerender (it paints it), so the two can never disagree about whether the row is there.
function Panel:statusBand()
    if C.wallet and C.wallet.frozen then return "Band_Frozen", "errorText" end
    if not self:remoteReadOnly() then return nil end
    if C.nearTerminal() then return "Band_AtTerminal", "positive" end
    if #(C.terminals or {}) == 0 then return "Band_NoTerminals", "warn" end
    return "Band_RemoteReadOnly", "warn"
end


-- prerender/render replace the parent versions (rounded surfaces; see NBPanel.lua:1826-1897)
function Panel:prerender()
    self:syncDetail()
    -- the Admin entry appears and disappears with the right; the window it opens looks after itself
    if self.adminAccess ~= C.AdminPanel.canRead() then self:layout() end
    -- the account is not readable in the very first frames of a world: the header picks the real
    -- name up the moment it exists, instead of keeping "loading" until something else resizes
    if self.identityName ~= self:username() then self:layout() end
    if self.balanceCurrencies ~= C.currencies then
        -- the server pushed a new currency registry: the wallet reader and every currency box
        -- follow it (the box refill is a no-op while the set itself is unchanged)
        self:syncCurrencyCombos()
        -- the board keeps its own box, and a board already on screen has to follow the push
        -- as well: a rename must never leave the old name in a selector the player is looking at
        self.leaderboard:fillCurrencies()
        self:rebuildList()
    end
    local band, bandToken = self:statusBand()
    if self.width ~= self.layoutW or self.height ~= self.layoutH
        or self.layoutCollapsed ~= self.isCollapsed or (C.rewards ~= nil) ~= self.hadRewards
        or self.layoutBand ~= band then
        self.hadRewards = C.rewards ~= nil
        self:layout()
    end
    -- Rewards state is a snapshot (online time accrues server-side, sandbox thresholds can
    -- change live): re-requested on the same 30 s beat while the tab is open, plus once at the
    -- exact moment the server said the next claim becomes due -- so a player who waited out the
    -- interval gets the fresh eligibility then, without a request per frame.
    if self.tab == "Rewards" and not self.isCollapsed then
        local now = EC.now()
        local due = self.rewardsDueMs ~= nil and now >= self.rewardsDueMs
        if due or not self.rewardsPolledMs or now - self.rewardsPolledMs > 30000 then
            self.rewardsPolledMs = now
            self.rewardsDueMs = nil
            C.requestRewards()
        end
    end
    -- One write in flight per page: a server that never answers must not leave the buy dialog
    -- disabled forever (the admin pages use the same window).
    if self.buyPending and EC.now() - self.buyPending.at > TIMEOUT_MS then
        self.buyPending = nil
        self:resumeBuyDialog()
        self:buyMessage(shopError("timeout"))
    end
    -- the daily claim is a write like any other: a server that never answers must not leave the
    -- button dead for the rest of the session. The state is asked for again, so whether the
    -- claim actually landed is read back from the server and never assumed here.
    if self.claimPending and EC.now() - (self.claimPendingAt or 0) > TIMEOUT_MS then
        self.claimPending = false
        self.claimPendingAt = nil
        self.message = { text = shopError("timeout"), error = true }
        C.requestRewards()
        self:updateDetail()
    end
    if self.mailPending and EC.now() - self.mailPending.at > TIMEOUT_MS then
        local batch = self.mailBatch
        self.mailPending = nil
        if batch ~= nil then
            -- a bulk claim whose segment never answered: what it did get through is reported,
            -- and the untried letters stay in the mailbox for the player to press again
            self:finishMailBatch("timeout")
        else
            C.toast(shopError("timeout"))
        end
    end
    -- The next segment of a bulk claim, once the server's own command window is over. One write
    -- in flight (mailPending) is what keeps a single claim and a bulk claim apart.
    local batch = self.mailBatch
    if batch ~= nil and batch.nextAt ~= nil and self.mailPending == nil
        and EC.now() >= batch.nextAt then
        if self:tradeAllowed() then
            self:sendMailBatch()
        else
            self:finishMailBatch("not_at_terminal")
        end
    end
    if self.marketPending and EC.now() - self.marketPending.at > TIMEOUT_MS then
        self.marketPending = nil
        self:marketMessage(shopError("timeout"))
    end
    -- the search box filters the page as it is typed; the server hears the text once the
    -- player stops (its own throttle would drop a command per keystroke anyway)
    if self.marketQueryAt and EC.now() >= self.marketQueryAt and self.tab == "Market" then
        self:requestBrowse(1)
    end
    -- the two keyword boxes (the statement and the market ring): the text is read back from the
    -- box every frame, because an IME commit can land in it without the text-change callback ever
    -- firing. One guard inside pollSearch, so nothing is rebuilt while the text stands still.
    self.walletBar:pollSearch()
    self.historyBar:pollSearch()
    -- the two seller boxes: the debounce clock, the IME read-back and the list's own geometry.
    -- A box whose page is not up was hidden by the layout and answers tick with nothing.
    local sellerNow = EC.now()
    self.marketSellerPicker:tick(sellerNow)
    self.auctionSellerPicker:tick(sellerNow)
    -- a candidate read that never came back: the slot is freed and the same text may be asked
    -- for again by whichever box was waiting for it
    if self.sellersPendingAt and sellerNow - self.sellersPendingAt > SELLERS_TIMEOUT_MS then
        self.sellersPendingAt, self.sellersRequestId = nil, nil
        self.marketSellerPicker:onTimeout()
        self.auctionSellerPicker:onTimeout()
    end
    -- a browse the 500 ms server throttle would have eaten: send the newest chip state now
    if self.browseWanted and EC.now() - (self.browseSentAt or 0) >= BROWSE_MIN_MS then
        self:sendBrowse()
    end
    -- a browse whose answer never came: the sort box, the header and the pager come back
    if self.browseBusy and EC.now() - (self.browseBusyAt or 0) > BROWSE_TIMEOUT_MS then
        self.browseBusy = nil
    end
    -- the auction page runs the same three gates on its own state
    if self.auctionQueryAt and EC.now() >= self.auctionQueryAt and self.tab == "Auction" then
        self:requestAuctionBrowse(1)
    end
    if self.auctionWanted and EC.now() - (self.auctionSentAt or 0) >= BROWSE_MIN_MS then
        self:sendAuctionBrowse()
    end
    if self.auctionBusy and EC.now() - (self.auctionBusyAt or 0) > BROWSE_TIMEOUT_MS then
        self.auctionBusy = nil
    end
    -- The record page's typed query goes out once the player stops; from there the three history
    -- reads run on the gate they share. Pumped whether or not this page is on screen: a read
    -- that never came back has to free the gate wherever the player is, and a page that just
    -- came back into view sends the read it owed.
    if self.auctionHistoryQueryAt and EC.now() >= self.auctionHistoryQueryAt
        and self.tab == "Auction" and self.auctionMode == "history" then
        self:requestAuctionHistory()
    end
    self.walletGate:pump(self:pageVisible("Wallet"))
    self.marketGate:pump(self:pageVisible("Market", "history"))
    self.auctionGate:pump(self:pageVisible("Auction", "history"))
    -- A read that never came back is the page's own timeout note, and the manual retry chip
    -- next to it only appears when the layout is run again: one pass for all three.
    local expired = false
    if self.walletGate:expired() then self.historyError, expired = "timeout", true end
    if self.marketGate:expired() then self.marketHistoryError, expired = "timeout", true end
    if self.auctionGate:expired() then self.auctionHistoryError, expired = "timeout", true end
    if expired then
        self:layout()
        Keys.invalidate(self)
    end
    -- a scope views.changed named while its page was hidden: read it now that it is not
    self:pumpViews()
    local w = self:getWidth()
    local h = self:getHeight()
    local th = self:titleBarHeight()
    if self.isCollapsed then h = th end
    fill(self, 0, 0, w, h, "surface")
    fill(self, 0, 0, w, th, "surfaceTitle", not self.isCollapsed)
    if not self.isCollapsed then
        local c = color("border")
        self:drawRect(0, th - 1, w, 1, c.a, c.r, c.g, c.b)
    end
    if self.clearStentil then
        self:setStencilRect(0, 0, self.width, h)
    end
    if self.title then
        text(self, self.title, self.g.titleX, math.floor((th - fontH.medium) / 2), "text", UIFont.Medium)
    end
    -- the header tooltip follows the pointer, and is taken down again by the same call the moment
    -- the pointer leaves the strip, the window collapses or it hides
    self:updateHeaderTip()
    if self.isCollapsed then return end

    local g = self.g
    -- The status band is a row of words, never an icon: a player who cannot spend has to be able
    -- to read why. It only exists while there is something to read (see Panel:statusBand).
    if band then
        U.Skin.dot(self, PAD * 2, g.statusY + math.floor((g.statusH - 8) / 2), 8, color(bandToken))
        text(self, getText(T .. band), PAD * 2 + 14, g.statusY + math.floor((g.statusH - fontH.small) / 2), bandToken)
    end
    self:drawHeader()
    local gateClosed = not self:tradeAllowed()
    self.shopList.buyDisabled = gateClosed or self.buyPending ~= nil
    -- one write in flight for the mailbox, whether it is one letter or the whole batch, and the
    -- batch chip needs at least one letter that is really ready
    local mailBusy = gateClosed or self.mailPending ~= nil or self.mailBatch ~= nil
    self.mailList.actionDisabled = mailBusy
    local mailReady = false
    for _, row in ipairs(self.mailRows or {}) do
        if row.claimable == true then mailReady = true; break end
    end
    self.mailClaimAllButton:setEnable(not mailBusy and mailReady)
    local writeOpen = not gateClosed and self.buyPending == nil and self.buyDialog == nil
    local shopPick = self.shopList:getSelectedItem()
    self.shopBuyButton:setEnable(writeOpen and shopPick ~= nil and not shopPick.soldOut)
    self.shopSellButton:setEnable(writeOpen and shopPick ~= nil and shopPick.buyback == true
        and shopPick.buybackOpen == true and shopPick.buybackRemaining ~= 0)
    local info = self.marketInfo
    self.marketList.actionDisabled = gateClosed or self.marketPending ~= nil
    self.marketListButton:setEnable(not gateClosed and self.marketPending == nil and self.marketDialog == nil
        and (info.maxListings <= 0 or info.mine < info.maxListings))
    local browseBusy = self.browseBusy == true
    self.marketSortCombo:setEnabled(not browseBusy)
    self.marketCatCombo:setEnabled(not browseBusy)
    self.marketPrevButton:setEnable(self.marketPage > 1 and not browseBusy)
    self.marketNextButton:setEnable(self.marketPage < info.pages and not browseBusy)
    local aucInfo = self.auctionInfo
    local aucBusy = self.auctionBusy == true
    for _, l in ipairs({ self.auctionList, self.auctionSellList, self.auctionBidList }) do
        l.actionDisabled = gateClosed or self.marketPending ~= nil
    end
    self.auctionCreateButton:setEnable(not gateClosed and self.marketPending == nil and self.marketDialog == nil
        and (aucInfo.maxAuctions <= 0 or aucInfo.mine < aucInfo.maxAuctions))
    self.auctionSortCombo:setEnabled(not aucBusy)
    self.auctionPrevButton:setEnable(self.auctionPage > 1 and not aucBusy)
    self.auctionNextButton:setEnable(self.auctionPage < aucInfo.pages and not aucBusy)
    if self.marketReturnFocus then
        local target = self.marketReturnFocus
        self.marketReturnFocus = nil
        if Keys.activeRoot == self then Keys.focusControl(target, true) end
    end
    if self.buyReturnFocus then
        local target = self.buyReturnFocus
        self.buyReturnFocus = nil
        if Keys.activeRoot == self then Keys.focusControl(target, true) end
    end
    if self.tab == "Wallet" then
        self:drawWallet()
    elseif self.tab == "Rewards" then
        self:drawRewards()
    elseif self.tab == "Shop" then
        self:drawShop()
    elseif self.tab == "Market" then
        self:drawMarket()
    elseif self.tab == "Auction" then
        self:drawAuction()
    elseif self.tab == "Mail" then
        self:drawMail()
    elseif self.tab == "Leaderboard" then
        self.leaderboard:sync()
        self.leaderboard:draw(self)
    end
    self:drawFooter()
end

function Panel:render()
    local w = self:getWidth()
    local h = self:getHeight()
    local th = self:titleBarHeight()
    if self.isCollapsed then h = th end
    -- Pending mailbox count as a corner bubble on the Mail entry of the navigation: painted here,
    -- after the buttons had their own render pass, so a hover fill cannot cover it. The entry is a
    -- child of the rail now, so its own x/y are rail-relative. A modal is the one thing it gives
    -- way to: children are rendered between prerender and this call (UIElement.java:1626-1634),
    -- so a bubble painted now would sit on top of the dialog the player is reading - and a count
    -- is never worth covering a confirm with.
    local mailTab = self.mailTabButton
    local unclaimed = math.floor(tonumber(C.unclaimed) or 0)
    if not self.isCollapsed and not self:isModal() and mailTab and unclaimed > 0
        and mailTab:getIsVisible() and self.nav:getIsVisible() then
        drawBadge(self, self.nav.x + mailTab.x + mailTab.width - 2, self.nav.y + mailTab.y + 2, unclaimed)
    end
    if not self.isCollapsed and self.resizable and self.resizeWidget:getIsVisible() then
        local rh = self:resizeWidgetHeight()
        local c = color("border")
        self:drawRect(0, h - rh, w, 1, c.a, c.r, c.g, c.b)
        self:drawTextureScaled(self.resizeimage, w - rh + 1, h - rh + 1, rh - 4, rh - 4, 1, 1, 1, 1)
    end
    if self.clearStentil then
        self:clearStencilRect()
    end
    U.Skin.border(self, 0, 0, w, h, color("border"))
    -- last, and after the stencil was cleared: the children were rendered between prerender and
    -- this call (UIElement.java:1626-1634), so the ring is painted over the control it marks
    Keys.render(self)
end

function Panel:close()
    Keys.close(self)
end

function Panel:setVisible(visible)
    ISCollapsableWindow.setVisible(self, visible)
    self.shown = visible == true
    if not visible then
        self:showPrefs(false)
        DatePicker.close(self)   -- this window's calendar only; the admin window keeps its own
        self:closeCombos()       -- a dropdown popup lives in the UIManager, not in this window
        self:closeBuy()
        self:closeMarketDialog()
        Detail.close(self)       -- a record of a window that is gone is not a record
        self:unfocusEntries()
        self:cancelAuctionHistory()   -- a closed window asks the server for nothing
        self.walletGate:clear()
        self.marketGate:clear()
        self.leaderboard:leave()
        Keys.clear(self)              -- no ring waiting behind a closed window
    end
    if visible then
        self.offsetMin = localOffsetMinutes()
        U.setAlpha(opacityPercent() / 100)   -- ModOptions may have changed it since the last open
        Keys.onFocus(self)
        self:layout()
        self:refresh()
    end
end

-- ISLayoutManager: keep position/size, never auto-show on login.
-- The saved numbers are clamped *before* the parent applies them: UIElement.setWidth/setHeight only
-- record lastwidth/lastheight (UIElement.java:1772-1779, 1813-1820) and the anchored children
-- (resize grips, pin button) are moved by width - lastwidth at the next update (:1411-1430), so a
-- second setWidth in the same frame would drop the first delta and leave the grip off the window.
function Panel:RestoreLayout(name, layout)
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    self.minimumWidth, self.minimumHeight = math.min(MIN_WIDTH, sw), math.min(MIN_HEIGHT, sh)
    local w = math.min(sw, math.max(MIN_WIDTH, tonumber(layout.width) or self.width))
    local h = math.min(sh, math.max(MIN_HEIGHT, tonumber(layout.height) or self.height))
    layout.width, layout.height = w, h
    layout.x = math.max(0, math.min(tonumber(layout.x) or self.x, sw - w))
    layout.y = math.max(0, math.min(tonumber(layout.y) or self.y, sh - h))
    local visible = layout.visible
    layout.visible = nil
    ISCollapsableWindow.RestoreLayout(self, name, layout)
    layout.visible = visible
    self:setVisible(false)
end

function Panel.create()
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    local w, h = defaultSize()
    local o = ISCollapsableWindow:new(math.floor((sw - w) / 2), math.floor((sh - h) / 2), w, h)
    setmetatable(o, Panel)
    o.title = getText(T .. "Toast_Title")
    o.resizable = true
    o.minimumWidth = math.min(MIN_WIDTH, sw)
    o.minimumHeight = math.min(MIN_HEIGHT, sh)
    o.period = "ThisMonth"
    o.offsetMin = localOffsetMinutes()
    o.monthTotals = nil
    o.walletDetails = false
    o.walletFiltersOpen = false
    o.detailWatch = {}
    o.viewDirty = {}
    -- The three history reads share one gate implementation (ECReadGate): the window, the single
    -- read in flight, the wish a hidden page owes and the question every reply is matched
    -- against. Each page keeps its own data, its own filters and its own error.
    o.walletGate = ReadGate.create(function(month, requestId) C.requestHistory(month, requestId) end)
    o.marketGate = ReadGate.create(function(_, requestId) C.requestMarketHistory(requestId) end)
    o.auctionGate = ReadGate.create(function(_, requestId)
        -- a pinned auction is an exact lookup: the box only holds its id so the player sees it
        local pinned = o.auctionHistoryId
        C.requestAuctionHistory({ auctionId = pinned,
            query = (pinned == nil) and o.auctionHistoryQuery or nil, requestId = requestId })
    end)
    o.marketMode = "browse"
    o.marketSort = "time"
    o.marketPage = 1
    o.auctionMode = "browse"
    o.auctionSort = "ending"    -- the auctions closest to their end are the ones that matter
    o.auctionPage = 1
    -- The trade pages start on an explicit currency: the catalog on the registered default
    -- (survivor while it exists), the two browse filters on "every currency" -- which is also
    -- the one state where a price sort does not exist.
    o.shopCur = defaultCurrency()
    o.marketCur = nil
    o.auctionCur = nil
    o:initialise()
    -- UIManager offers key events to top-level UI that asked for them (UIManager.java:1435-1466);
    -- without this the window's four key hooks are never called
    o:setWantKeyEvents(true)
    o:addToUIManager()
    for _, b in ipairs(o.periodButtons) do b.active = b.internal == o.period end
    o:setVisible(false)
    ISLayoutManager.RegisterWindow(LAYOUT_NAME, Panel, o)
    return o
end

-- ---------- module API ----------

function P.instance()
    if P.window then return P.window end
    if not U.init() then return nil end
    P.window = Panel.create()
    if not P.listening then
        P.listening = true
        C.onWallet(function(kind, args) if P.window then P.window:onWallet(kind, args) end end)
        C.onRewards(function(kind, args) if P.window then P.window:onRewards(kind, args) end end)
        C.onShop(function(kind, args) if P.window then P.window:onShop(kind, args) end end)
        C.onMail(function(kind, args) if P.window then P.window:onMail(kind, args) end end)
        C.onMarket(function(kind, args) if P.window then P.window:onMarket(kind, args) end end)
        C.onTerminals(function() if P.window then P.window:onTerminals() end end)
        -- the public board: one read, one snapshot, and a note when the server's public rules
        -- moved under the page
        C.onLeaderboard(function(kind, args)
            if P.window then P.window.leaderboard:onReply(kind, args) end
        end)
        -- views.changed: the server says the data behind a scope moved. Only the page on screen
        -- reads again; every other page records it and asks when it is looked at.
        C.onViews(function(scope) if P.window then P.window:onViewChanged(scope) end end)
    end
    return P.window
end

-- Hotkey / floating button. With the sandbox option RemoteReadOnly off the window may only be
-- opened next to a terminal (the terminal's own right-click entry goes through P.instance).
function P.toggle()
    if not getPlayer() then return end
    local win = P.instance()
    if not win then return end
    if not win:getIsVisible() and C.session and C.session.remoteReadOnly == false and not C.nearTerminal() then
        C.toast(getText(T .. "Toast_NeedTerminal"))
        return
    end
    win:setVisible(not win:getIsVisible())
end

-- Hotkey: [ (Keyboard.KEY_LBRACKET = 26, org/lwjglx/input/Keyboard.java); vanilla binds ] for
-- "Toggle Moveable Panel Mode" (keyBinding.lua:178-179) and leaves [ free. Rebindable in
-- Options -> Key Bindings -> [MinidoracatEconomy].
local function initBinds()
    table.insert(keyBinding, { value = "[MinidoracatEconomy]" })
    table.insert(keyBinding, { value = "MinidoracatEconomy_Toggle", key = Keyboard.KEY_LBRACKET })
end
Events.OnGameBoot.Add(initBinds)

local function onKeyPressed(key)
    if key ~= 0 and key == getCore():getKey("MinidoracatEconomy_Toggle") and isClient() then
        P.toggle()
    end
end
Events.OnKeyPressed.Add(onKeyPressed)

-- Reset per world (UIManager elements survive a return to the main menu; a new session must
-- rebuild against the new server state).
local function onGameStart()
    DatePicker.close()
    C.AdminWindow.reset()   -- the admin page is disposed for real here, and nowhere else
    if P.window then
        Detail.close(P.window)   -- the record window outlives a world otherwise
        P.window:removeFromUIManager()
        P.window = nil
    end
end
Events.OnGameStart.Add(onGameStart)
-- A resolution change (or window-mode switch) must not leave the panel off-screen or larger
-- than the screen; the size the player chose is otherwise kept.
Events.OnResolutionChange.Add(function()
    C.AdminWindow.clampToScreen()
    local win = P.window
    if not win then return end
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    win.minimumWidth, win.minimumHeight = math.min(MIN_WIDTH, sw), math.min(MIN_HEIGHT, sh)
    local width = math.min(sw, math.max(MIN_WIDTH, win.width))
    local height = math.min(sh, math.max(MIN_HEIGHT, win.height))
    if width ~= win.width then win:setWidth(width) end
    if height ~= win.height then win:setHeight(height) end
    win:setX(math.max(0, math.min(win.x, sw - win.width)))
    win:setY(math.max(0, math.min(win.y, sh - win.height)))
    win:layout()
end)

return P
