# 通用名額權益 API（API major 1、revision 2；缺席凍結需要 revision 4）

此介面供其他 **dedicated server MOD** 販售買斷名額與定期租用名額。Economy 管錢包、幣別與收費流程（報價、扣款、退款、租約、自動續租、同意條款、即時生效）；**方案**（價格、幣別、上限、天數、開關）歸使用名額的 MOD，由它用 `setPlan` 交給 Economy 驗證保存；名額代表什麼也由它決定。VehicleManager 是第一個實際消費端；安全屋可用另一個來源／產品接入，本文件不代表安全屋已完成整合。

## 使用前提

伺服器先確認 `MinidoracatEconomy.v1` 的 `API_MAJOR == 1`、`API_REVISION >= 2`，以及 `CAPABILITIES.entitlements`、`CAPABILITIES.subscriptions`、`CAPABILITIES.rentals`、`CAPABILITIES.setPlan`。

- `rentals` 表示租用是**租約清單**：每筆新租用訂單是一張獨立租約，有自己的名額數、到期時間、續租與自動續租；沒有這個能力的 Economy 是舊的單一租約模型，參數與 snapshot 形狀都不同，消費端應視為不可用。
- `setPlan` 表示 handle 有 `setPlan`／`getPlan`／`setPlanSource`、`registerProduct` 接受 `instant`，而且沒有沙盒同步。沒有這個能力的 Economy 由舊的管理頁編輯方案並同步沙盒，消費端不能自己管方案。

既有 `post/credit/debit` 行為不變；舊 `CAPABILITIES.subscribe=false` 不改為新能力的別名。

要用「MOD 缺席時凍結租約」（`registerProduct{ freezeWhenAbsent = true }`）時，另外確認 `API_REVISION >= 4` 與 `CAPABILITIES.freeze`，見「缺席時凍結」。

Economy 是選用整合的消費端不必加 `require=MinidoracatEconomyFor42`。Economy 缺席、版本過舊或查詢失敗時，消費端必須明示付費服務不可用，不猜測可用名額。

權益按 **來源 MOD、帳號、產品** 分開。它屬於目前世界，不能當跨世界的永久訂閱。帳號用伺服器取得的 `getUsername()`，不是角色顯示名或 client 傳入的付款人。

## 註冊

在伺服器 Lua 全部載入後取得來源 handle，為每個產品註冊一次。來源 handle 用點號呼叫，不是冒號。

```lua
local E = MinidoracatEconomy and MinidoracatEconomy.v1
if not (E and E.API_MAJOR == 1 and E.API_REVISION >= 2 and E.CAPABILITIES.entitlements
    and E.CAPABILITIES.subscriptions and E.CAPABILITIES.rentals and E.CAPABILITIES.setPlan) then return end

local source, err = E.registerSource({
    modId = "MyMod",
    nameKey = "IGUI_MyMod_SourceName",   -- 選用：來源名稱的翻譯鍵，管理台優先用它
    displayName = { EN = "My Mod" },
    currencies = { "survivor", "cat" },
    reasonCodes = { "entitlement_purchase", "entitlement_renewal", "entitlement_refund" },
})
if not source then return end
local result = source.registerProduct({
    id = "claim_slot",
    nameKey = "IGUI_MyMod_ClaimSlot",
    instant = true,          -- 付款當下生效；省略＝等存檔確認（見「即時生效商品」）
    defaults = {
        permanentEnabled = false, permanentCurrency = "survivor", permanentPrice = 1000, permanentLimit = 10,
        rentalEnabled = false, rentalCurrency = "survivor", rentalPrice = 250, rentalLimit = 5,
        rentalDays = 7, graceHours = 24, reminderHours = 24, autoRenewAllowed = true,
    },
})
```

價格只是預設範例；兩種販售預設都關閉。翻譯鍵由產品的 MOD 提供。產品 ID 為 1–32 字元的小寫英文、數字或底線。重啟後需再次註冊。`defaults` 只在這個世界第一次看到該產品時建立方案；之後的方案與權益不會被 defaults 重置，要改方案用 `setPlan`。

`registerSource` 的 `nameKey` 選填，是來源名稱的翻譯鍵（`^[%w_]+$`、1–96 位元組，不合格回 `nil, "invalid_args"`）；管理台顯示來源名稱時先找這個翻譯，找不到才用 `displayName`，再沒有就用 modId。`G.sources()`（管理台來源頁）與 `plans` 列都帶 `sourceNameKey`。

交易紀錄的原因：`entitlement_purchase`／`entitlement_renewal`／`entitlement_refund` 由 Economy 翻譯；來源自訂的其他 `reasonCodes` Economy 沒有譯文，管理台顯示成「其他模組的原因：<代碼>」（`Reason_custom`），代碼本身照原樣。

註冊帶 `sandbox` 欄位回 `{ ok = false, error = "invalid_args", field = "sandbox" }`：沙盒同步已移除，Economy 不讀寫任何沙盒選項。`instant` 不是 boolean 時回 `field = "instant"`；`freezeWhenAbsent` 不是 boolean 時回 `field = "freezeWhenAbsent"`（舊 Economy 不認得這個欄位、不會報錯，所以先看能力旗標）。

方案欄位：

| 欄位 | 意義 |
|---|---|
| `permanentPrice` | 每個名額的買斷價；一次買 k 個收 k 倍 |
| `permanentLimit` | 每個帳號最多買斷幾個名額，0–1000 |
| `rentalPrice` | 每個名額每期的租金；一張 n 個名額的租約每期收 n 倍 |
| `rentalLimit` | 每個帳號所有租約合計最多租幾個名額，1–1000；停止租用請關 `rentalEnabled` |
| `rentalDays`／`graceHours`／`reminderHours`／`autoRenewAllowed` | 每期天數、寬限、到期前提醒、是否允許自動續租 |

舊方案的 `rentalQuantity` 已刪除；驗證不過的舊方案列轉為 provisional（不可購買），等來源用 `setPlan` 取代。

可選 `validatePurchase(username, productId, kind, quantity, projected)` 回呼應回 `true` 或 `false, reason`，其中 projected 含 `permanent/rental/usable/pendingQuantity`。回呼失敗或丟出例外會拒絕付款。它適合檢查消費端目前能否提供服務，不應因「基本名額已用完」而拒絕加購名額。

## 伺服器 handle

| 方法 | 用途 |
|---|---|
| `registerProduct(spec)` | 登錄產品、初始方案、是否即時生效（`instant`）、缺席時是否凍結（`freezeWhenAbsent`，rev 4）及購買驗證回呼 |
| `setPlan(productId, values, opts)` | 交付完整方案，見「方案」 |
| `getPlan(productId)` | 讀目前生效的方案、最後修改與來源狀態 |
| `setPlanSource(productId, info)` | 告訴 Economy 方案從哪個檔案來、有沒有錯誤（只給管理台唯讀總覽顯示） |
| `getEntitlement(username, productId)` | 唯讀權益、方案、餘額及近期訂單；不建立錢包 |
| `quote(username, productId, kind, quantity, rental?)` | 建立 120 秒有效的伺服器報價，見下方「報價種類」 |
| `purchase(username, quoteId)` | 提交同一張報價；不讓客戶端指定價格或貨幣 |
| `getOrder(username, productId, orderId)` | 查同一筆訂單結果，不再次扣款；即時生效商品的回覆頂層帶 `instant = true` |
| `setAutoRenew(username, productId, enabled, expectedRevision, termsRevision, rental)` | 對某張租約明示同意或取消自動續租；帶權益與條款版本（過期的 termsRevision 仍會被拒，玩家必須看過目前方案），`rental` 必填。同意會記下當下方案的租金、幣別與每期天數 |
| `refund(username, productId, orderId, opts)` | 對可查的原單退款並收回對應權益；opts 必填 reason，可帶 actor |
| `onEntitlementChanged(fn)` | 完整變更後呼叫 `fn(username, productId, snapshot)` |

一般結果為 `{ok, error?}`。查詢成功的 snapshot 包含：

- `sourceMod/productId/nameKey/available/plan`；即時生效商品另有 `instant = true`。
- `entitlement.revision/permanent/rental/usable/pendingQuantity/pendingOrderId/lastOrderId/state`：`rental` 是所有有效租約的名額總和；`pendingQuantity` 是待確認的買斷加上還沒生效、正在等付款確認的租約名額；`pendingOrderId` 只列玩家自己發起、還沒確認的最新訂單（自動續租產生的不算）；`state` 為 `active`（usable > 0）、`pending`（只有待確認）或 `none`。即時生效商品沒有待確認：`pendingQuantity = 0`，不出 `pendingOrderId`、`wait`。
- `entitlement.rentalCommitted`：計入 `rentalLimit` 的名額，即有效租約加上有待確認付款的租約。`entitlement.rentalsMax`：每個帳號最多幾張租約（伺服器固定 10）。
- `entitlement.rentals`：依建立順序的租約清單，每張 `{ id, quantity, state, paidUntil?, graceUntil?, terms?, autoRenew, autoRenewState, autoTerms?, termsRevision?, pendingOrderId?, autoPending? }`。`id` 是建立它的訂單 id；`state` 為 `pending/active/grace/expired/paused_terms/paused_system/frozen`（條款改變、租用合計超過 `rentalLimit` 或租用停售時為 `paused_terms`；`frozen` 只出現在 `freezeWhenAbsent` 商品缺席時，見「缺席時凍結」）；`autoRenewState` 為 `off/pending_on/on/pending_off/paused_terms/paused_system`，其中 `paused_terms` 表示目前方案的租金、幣別或每期天數和同意時記下的不同（或租用合計超過上限），要玩家重新同意；`autoPending=true` 表示這張的待確認付款是自動續租發起的。即時生效商品的租約不會是 `pending`，同意直接是 `on`。
- `rentals[i].terms = { price, amount, currency, days, graceHours }`：這張租約正在跑（或已付款待生效）的那一期的條款，`price` 是每個名額的租金、`amount` 是該期總額。`rentals[i].autoTerms = { price, currency, days }`：自動續租開啟時，玩家同意的條款。
- `entitlement.durable`（status、source、seq 等），以及可選的 `wait`、`notice`（`notice.rental` 指出是哪張租約）。
- `balances`（以貨幣 ID 索引的 available、reserved、rev）、最近最多 20 筆 `orders`；租用訂單帶 `rental`（所屬租約 id），排程自動續租的訂單帶 `auto=true`，已生效的訂單帶 `activatedAt`。每筆另帶付款交易 `txId` 與退款判斷（見「管理台」）：`refundable`、`refundEffect?`、`previousUntil?`、`rentalNo?`。

舊的頂層 `paidUntil/graceUntil/autoRenew/autoRenewState/termsRevision` 已刪除，改讀各租約的同名欄位。

**消費端只使用 `entitlement.usable` 作為可新增的付費名額。** 不自行將 pending 相加，不從歷史收據、餘額差或過去快取推測名額。

## 方案

方案歸來源 MOD：它決定方案從哪裡來（例如自己的設定檔與遊戲內設定視窗），每次變更把完整方案交給 Economy。Economy 驗證、保存（Global ModData）、記錄誰改的，並通知持有該產品的客戶端重新讀取；Economy 沒有方案編輯器，管理台「整合方案」頁是唯讀總覽。

### `setPlan(productId, values, opts)`

- `values`：完整 12 個方案欄位，不能多也不能少；幣別只能是該來源註冊的幣別。
- `opts = { actor?, origin?, reason?, expectedRevision? }`：`actor` 1–64 位元組、無控制字元（預設 `"source"`）；`origin` 為 `"file"`／`"admin"`／`"source"`（預設 `"source"`）；`reason` 選填字串（控制字元換成空白；最後修改紀錄存前 64 位元組，稽核存全文，上限同管理員原因）；`expectedRevision` 選填整數。
- 成功：`{ ok = true, updated = true, revision = <新版本>, changed = { "<欄位>", ... } }`。版本 +1，記下 `lastChange = { actor, origin, at, reason, revision }`，寫 `entitlement.plan` 事件與每個改動欄位一筆稽核，並廣播產品的公開更新訊號。
- 內容和目前方案相同（且目前方案不是 provisional）：`{ ok = true, updated = false, revision = <目前版本>, changed = {} }`，**不看 `expectedRevision`**，重送天然冪等。
- 判斷順序與錯誤：

| 順序 | 回覆 | 意義 |
|---|---|---|
| 1 | `{ ok = false, error = "not_ready" }` | 世界資料還沒載入，稍後再試 |
| 2 | `{ ok = false, error = "unknown_product" }` | 這個世界沒有該產品的方案（沒註冊過） |
| 3 | `{ ok = false, error = "invalid_args", field = "actor" \| "origin" \| "reason" \| "expectedRevision" \| "opts" }` | `opts` 不合格 |
| 4 | `{ ok = false, error = "invalid_plan" \| "unknown_fields", field = "<方案欄位>" }` | 欄位缺漏、型別或範圍不對、幣別不是該來源的，或多了不認識的欄位 |
| 5 | `{ ok = true, updated = false, ... }` | 內容相同 |
| 6 | `{ ok = false, error = "stale_revision" }` | 有給 `expectedRevision` 且不等於目前版本 |

合約效果不必另外處理：改了租金、幣別或每期天數，以舊條款同意的自動續租自動暫停（改回原值恢復）；調低 `rentalLimit` 時超額的帳號照「租用與續租」的規則處理。任何方案變更都會讓舊報價失效。

### `getPlan(productId)`

`{ ok = true, plan = { <12 欄>, revision, provisional? }, lastChange = { actor, origin, at, reason, revision }, source = { file?, problem?, at } | nil }`；錯誤 `not_ready`、`unknown_product`。新世界的第一版 `lastChange.origin` 為 `"defaults"`。`source.problem` 是 `setPlanSource` 存的那張表的副本。

### `setPlanSource(productId, { file?, problem? })`

`{ ok = true }`。只存在記憶體、不進存檔，給唯讀總覽顯示「方案從哪個檔案來、設定檔有沒有錯誤」；Economy 自己記下時間 `at`。`file` 去掉控制字元後至多 160 位元組。

`problem` 省略表示沒有錯誤（清掉上一次的錯誤）；有錯誤時是一張表，讓管理台用讀者的語言組句，不顯示原始錯誤碼：

| 欄位 | 內容 |
|---|---|
| `key` | 必填，說明這個錯誤的翻譯鍵（`^[%w_]+$`、1–96 位元組），由來源 MOD 提供；管理台以 `getText(key, <欄位名稱>, <ref>)` 組句 |
| `field` | 選填，出錯方案欄位顯示名稱的翻譯鍵（同格式） |
| `ref` | 選填，原文資料（例如設定檔裡的鍵名），去掉控制字元後至多 64 位元組，照原樣顯示 |

字串形式的 `problem`、格式不合的 `key`／`field` 或過長的 `ref` 回 `invalid_args`、`field = "problem"`；產品沒註冊回 `unknown_product`；`file` 不合格回 `field = "file"`。

## 報價、付款與未知結果

### 報價種類

| 呼叫 | 意義 | 條件 | 價格 |
|---|---|---|---|
| `quote(u, p, "permanent", k)` | 買斷 k 個（1–100，預設 1） | 已買斷 + k ≤ `permanentLimit` | k × `permanentPrice` |
| `quote(u, p, "rental", n)` | 新租約 n 個（1–`rentalLimit`，預設 1） | `rentalCommitted` + n ≤ `rentalLimit`，且租約未滿 `rentalsMax` 張 | n × `rentalPrice` |
| `quote(u, p, "rental", nil, rentalId)` | 續租該張租約（quantity 省略或等於該張名額數） | 該張沒有待確認付款，且租用合計未超過 `rentalLimit` | 該張名額數 × `rentalPrice` |

- 新租約從生效時起算一整期：一般商品是存檔確認啟用時（等待存檔的時間不算在租期內），即時生效商品是付款時。
- 續租期中或寬限期的租約從原 `paidUntil` 延長一期；已過寬限的從生效時起算。續租不改名額數：要改數量就另租一張，讓舊的到期。
- 一次一筆玩家發起的待確認購買是**客戶端規則**：`pendingOrderId` 有值時不讓玩家再買。自動續租產生的待確認付款不擋玩家購買，只擋同一張租約再續租（`lease_pending`）。

報價回傳 `quote.id/orderId/kind/quantity/currency/amount/termsRevision/expiresAt`。付款前保存 `quote.orderId`；它與該報價的 id 相同，付款結果仍回同一 orderId。

送出付款後逾時只代表 **結果未知**。不得再建立新報價自動重付，也不能用 snapshot 最新的 lastOrderId 猜測是哪一筆。只能查保存的原 orderId。

`getOrder` 的 `known=false` 不是未付款證明。已知且 `paid=false, final=true` 的 `unsubmitted/declined/rolledback` 才是終局未付；已知 `paid/refunded` 一般商品還要區分保存待確認與 confirmed，回覆帶 `instant = true` 的即時生效商品付款或退款當下就已生效。超過近期訂單查詢／退款視窗時需人工核對，不藉由重送 debit 查結果。

判定 `unsubmitted/declined` 必須有該來源／帳號／產品的報價歸屬證據；失效報價證據有界保留，淘汰後返回 unknown。重啟後若該列沒有訂單，也返回 unknown；不能拿全域交易序號、舊啟動保存水位或「近期找不到」推論某帳號未付款。重連後可讀取目前權益與錢包，再由玩家明確發起新的購買；這不代表已判定舊單未付。

## 保存、啟用與崩潰界線

錢包與財務權益同存 Global ModData。同一筆提交先完成驗證及預配置，再一起更新；通知在完整提交後才發出。不過「函式成功」仍不是存檔已寫入的證明。

一般商品（未設 `instant`）的新付費名額須滿足下列其中一項才可用：

1. 既有 companion 解析真實、穩定的世界存檔，發布本次啟動且涵蓋該交易的保存水位。
2. 正常重啟後，該權益確實從世界存檔載入。

沒有 companion 時，畫面會說明需等重啟載入確認；不以經過幾秒、主控台存檔訊息或交易 JSON 代替證據。買斷名額本體不依賴有限的啟動歷史，因此不會因啟動超過 20 次而被遺忘。

付款保存確認不等於租用已啟用：還須將該張租約的固定啟用時間寫進日誌並讀回核對。新租約與過寬限後的續租從該時間起算；連續續期沿前一期 `paidUntil` 延長。再次崩潰重啟沿用原啟用時間，不重算一整期。取消某張租約的自動續租立即停止本程序尚未執行的續租，但未保存前顯示 `pending_off`；重放以同一張租約、同一授權世代匹配，不能套到後來的新同意或別張租約。

日誌位於伺服器 `Lua/MinidoracatEconomy/entitlements-journal.json`，內容為逐行 JSON。取消寫入或讀回確認失敗時，回覆 `ok=false, error=journal_unavailable`；本程序先停止排程，但不能承諾崩潰後仍保持取消。畫面保留待確認狀態，修復日誌或確認 off 狀態真正保存後才能完成。

日誌不可讀、損毀、寫入驗證失敗或容量不足時，相關啟用／續租暫停並顯示原因；不改用當下時間猜測、不抹掉已確認權益。**日誌不能當付款耐久證明。**

這些保證針對可讀取已保存檔案的程序崩潰情境，不保證 OS 當機／斷電的 fsync、手動改檔或混搭不同時間的備份。備份還原須包含一致的世界存檔及經濟日誌。

### 即時生效商品（`instant = true`）

錢、名額與自動續租同意都在同一份 Global ModData，崩潰時一起回到上次存檔，不會有「錢扣了、名額沒了」或反過來的情況。所以即時生效商品不等存檔：

- 買斷、新租約、續租（玩家手動或排程自動續租）都在付款的同一筆提交生效：買斷名額直接計入、新租約從付款時起算、續租從原 `paidUntil` 延長（已過寬限從付款時起算）；不寫啟用日誌行。訂單記 `activatedAt`，照樣發 `entitlement.order` 與 `entitlement.activated` 事件。
- 自動續租的同意立即生效（`on`），排程到期就扣款，不要求同意已存檔。
- 取消自動續租照舊寫 `off` 日誌行，讀回後才是 `off`（避免崩潰後已取消的同意回來）；寫不進去時維持 `pending_off` 並回 `journal_unavailable`。
- 退款照「租用與續租」的規則，立即生效。
- 世界存檔之前的舊資料若還有等待確認的付款，照一般商品的路徑完成。

**限制：不能用在會把物品發到玩家背包、或在 ModData 以外留下效果的商品。** 物品與外部狀態不會跟著 ModData 一起回滾，崩潰後就會出現付款已退回、東西還在的複製。這類商品請用一般模式（等存檔確認）。

## 租用與續租

- 每張租約有自己的名額數、到期時間、寬限、續租與自動續租；綁定上限＝基本＋買斷＋所有有效租約名額。續租不改名額數，也不多加一張。
- 自動續租預設關閉，逐張開關。每張租約是一份契約：每一期記下自己的租金、幣別、天數與寬限（`terms`），同意自動續租時記下當下的租金、幣別與每期天數（`autoTerms`）；一般商品的同意未確認保存前不排程扣款。到期時按記下的條款扣該張的租金。
- 啟用自動續租也會檢查帳戶未凍結、幣別啟用及來源貨幣白名單；取消不受這些付款限制阻擋，但仍驗證授權世代以免舊取消覆蓋新同意。
- 到期時才嘗試自動續租，事先依 reminderHours 提醒。餘額不足在寬限期間每小時重試，寬限結束關閉該張的自動續租；系統不可用、凍結及來源停用會另外說明，不記成歷史欠債。
- 寬限時間內租用名額仍有效（`usable` 照算）。寬限結束後不再計入。消費端可另讀 `rentals[i].state` 決定自己的到期處理：VehicleManager 在寬限中不讓這些名額綁新車、把超出名額的車由新到舊鎖定，寬限結束且租約從清單移除後才解除仍超額的車；讀取失敗時不動任何車。
- 伺服器停機跨過多個周期，不補扣多期；重新開通只收一個明示周期。
- **到期移除**：寬限結束、沒有待確認付款、自動續租已關閉且已存檔的租約，伺服器自動從清單移除；即時生效商品不必等存檔，關閉的 `off` 日誌行寫入後就移除。
- **改租金、幣別或每期天數**：不改寫已付期間。只要方案的 `rentalPrice`、`rentalCurrency`、`rentalDays` 與某張租約同意時記下的不同，那張的自動續租就暫停（`paused_terms`），玩家重新同意後才會再扣款（同意會記下當時的條款）；方案改回同意時的值，自動續租恢復。其他方案欄位（買斷欄位、`rentalLimit`、寬限、提醒等）的變更不會暫停已同意的自動續租；關閉 `autoRenewAllowed` 則另外停止自動續租。報價仍綁 termsRevision，任何方案變更都會讓舊報價失效。
- **調低 `rentalLimit`、低於玩家目前的租用合計**：現有租約照常用到到期，已付的續租照常啟用；合計超過上限時不能新租或續租（`limit_reached`），自動續租暫停；寬限期結束仍超過上限的那張關閉自動續租並到期。合計降回上限內後，其餘租約恢復續租。
- **退款**綁原訂單、至多原額一次，與權益減少同時提交，並關閉該張租約的自動續租：
  - 待確認的新租約：連同租約一起取消。
  - 某張租約的最新一期：回到上一期；沒有上一期就移除租約。
  - 租約已被移除：只要是該張的最新訂單，就只退款，不動任何權益。
  - 其他情況回 `refund_not_latest`。退款不放寬一般 credit 的發行額度。

### 錯誤碼（租用相關）

| 錯誤 | 意義 |
|---|---|
| `limit_reached` | 買斷超過 `permanentLimit`，或租用合計會超過 `rentalLimit`（含已超過時續租） |
| `rental_count_limit` | 已有 `rentalsMax` 張租約 |
| `rental_unknown` | 指定的租約不存在（可能已到期移除） |
| `lease_pending` | 該張租約已有待確認付款 |
| `no_lease` | 沒有可續租的租約 |

`lease_quantity_changed` 已刪除。

## 缺席時凍結（revision 4，`CAPABILITIES.freeze`）

提供名額的 MOD 可能被服主移除（例如地圖錶第三方槽位的 MOD）。註冊時帶 `freezeWhenAbsent = true` 的商品，在 MOD 缺席期間租約凍結：不扣租金、不退費，MOD 裝回來後租約接著算。

```lua
local E = MinidoracatEconomy and MinidoracatEconomy.v1
local canFreeze = E and E.API_MAJOR == 1 and E.API_REVISION >= 4 and E.CAPABILITIES.freeze == true
local result = source.registerProduct({
    id = "watch_slot_acme", nameKey = "IGUI_MyMod_Slot", instant = true, defaults = defaults,
    freezeWhenAbsent = canFreeze or nil,     -- 舊 Economy：省略，租約照絕對時間走
})
```

- **旗標持久化**：`freezeWhenAbsent` 存在該商品的方案列（Global ModData），下次開機商品沒註冊時 Economy 仍知道它要凍結。之後以不帶旗標的方式註冊會清掉旗標。
- **註冊窗口**：每次開機後 `E.FREEZE_WINDOW_MS`（60 秒）內註冊的商品不算缺席，不凍結；這段時間照常計入租期。窗口內還沒註冊的旗標商品，排程先不處理它的租約（不到期、不移除、不扣款）。
- **凍結**：窗口結束時仍沒註冊的旗標商品記 `frozenAt`＝本次開機時間（已凍結的保留原本的 `frozenAt`，重開多次也只凍結一次）。凍結期間：不到期、不進寬限、不發提醒、不扣自動續租、不啟用待確認的付款、不移除租約；自動續租同意保留（玩家仍可取消）。購買照舊回 `product_unavailable`；管理員退款仍可用。
- **snapshot**：凍結商品以 `frozenAt` 當時間算名額、上限與狀態；當時還沒結束的租約 `state = "frozen"`，`paidUntil`／`graceUntil` 以「現在解凍」換算（剩餘時間停在凍結時），已過寬限的維持 `expired`。`autoRenewState` 是 `paused_system`。客戶端 facade（`v1.Client`）rev 3 起帶 `CAPABILITIES.freeze`，`getState` 收到的就是這份投影。
- **解凍**：商品再次註冊（開機時或之後）時，該商品所有租約的 `paidUntil`（與 `start`、各訂單退款會退回的上一期）加上 `now - frozenAt`，清掉 `frozenAt`，排程恢復；每張租約剩下的時間與寬限和凍結時相同。時鐘倒退時不移動（位移以 0 計）。重複註冊不會再移動。
- **紀錄**：凍結與解凍各寫一行稽核（`entitlement.freeze`／`entitlement.thaw`，管理台稽核頁可見）、一筆事件與伺服器 log；解凍帶 `shiftMs`。
- **限制**：
  - 凍結以商品為單位，只看商品有沒有註冊；整個來源 MOD 缺席時它的旗標商品也一樣凍結。沒帶旗標的商品行為不變（缺席時照絕對時間到期，只是不扣款）。
  - 崩潰界線：`frozenAt` 在 Global ModData，崩潰回滾到上次存檔時，最多少凍結一段未存檔的時間（下次開機重新以開機時間凍結）。
  - Economy 本身缺席時沒有凍結（租約照絕對時間走）。
  - 買斷名額不會過期，本來就不受影響。

## 管理台

Economy 管理頁「整合方案」是唯讀總覽：`admin.entitlements action = "plans"`（讀取權）回 `plans[i] = { sourceMod, productId, nameKey, sourceNameKey?, sourceName?, loaded, instant, plan, lastChange, source }`，顯示各產品目前的條款、最後從哪裡修改、設定檔有沒有錯誤（`source` 是 `setPlanSource` 存的那份，沒有就省略；`sourceName` 是來源的 `displayName`，來源本次沒載入時兩個名稱欄位都省略）。方案編輯、`action = "apply"` 與沙盒同步已移除。

### 訂單清單 `action = "orders"`

讀取權（與 `plans`、`account` 同一道閘門；沒有權限回 `forbidden`，不附資料）。參數全部選填：`username`（完整帳號）、`sourceMod`、`productId`、`before = { at, id }`。沒有篩選就是所有帳號、所有商品的訂單（每個帳號每個商品仍只有近期 20 筆）。

- 排序：訂單時間新到舊，同一時間以訂單 id 字串由大到小。`before` 是上一頁最後一列的 `{ at = row.at, id = row.orderId }`，只回排在它之後的。每頁 50 筆（`E.ORDERS_PAGE`）。
- 回覆：`{ ok = true, orders = { Row, ... }, more = <還有下一頁>, filter = { username?, sourceMod?, productId? } }`。
- `Row = { username, sourceMod, productId, nameKey, instant, orderId, txId, kind, renewal?, auto?, quantity, amount, currency, status, at, rental?, rentalNo?, refundable, refundEffect?, previousUntil?, refund?, durable? }`：`kind` 為 `permanent`／`rental`；`status` 為 `paid`／`refunded`；`rentalNo` 是該帳號該商品目前租約清單的序號（1 起，租約已移除就省略）；`refund = { amount, at, txId, durable? }`；`durable = { status }` 是原付款的存檔狀態，`refund.durable = { status }` 是退款本身的存檔狀態，兩者都只有一般商品（非 instant）才帶。已退款的訂單看 `refund.durable`。
- 錯誤：`invalid_args`（帳號、來源、商品或 `before` 格式不合）、`not_ready`、`forbidden`；回覆超過封包上限時 `reply_too_large`。

`refundable` 與 `refundEffect` 和 `refund` 實際的判斷同一套：

| `refundEffect` | 退款後 |
|---|---|
| `units` | 收回這筆買斷的名額 |
| `cancel` | 還沒生效的新租約連同租約一起取消 |
| `previous` | 租約退回上一期，`previousUntil` 是退回後的到期時間；還沒生效的續租被退款時，租約維持目前這一期（`previousUntil` 是目前的到期時間） |
| `remove` | 只有一期的租約整張移除 |
| `money` | 租約已到期移除，只退回金額 |

不能退的訂單 `refundable = false`、沒有 `refundEffect`：已退款、買斷名額已不足、或不是該張租約的最新一期（之後還有續租）。

管理員可查帳號權益與退款（`action = "account"`、`action = "refund"`；帳號頁逐張列出租約、各期條款、同意自動續租時的條款，並標出與目前方案不同之處），但不能替玩家開啟自動續租。

## 客戶端 API

能力探測位於 `MinidoracatEconomy.v1.Client`（不是客戶端的 `.v1.API_MAJOR`）。確認 major 1、rev >= 2、`CAPABILITIES.entitlements` 與 `CAPABILITIES.rentals` 後取 `.Entitlements`（rev 3 起另有 `CAPABILITIES.freeze`：租約可能是 `frozen`）：

`requestState/getState/quote/purchase/setAutoRenew/getOrder/onChanged` 對應上述用途；送出方法回 requestId，若回 `nil, reason` 代表本機未送出且不會呼叫 callback。逾時 callback 包含 unknown 與原付款識別。客戶端只保存投影，不自行授權。

- `quote(sourceMod, productId, kind, quantity, cb, rental?)`：`rental` 省略為買斷或新租約，給租約 id 為續租該張；只有 `kind == "rental"` 能帶 `rental`。
- `setAutoRenew(sourceMod, productId, enabled, revision, termsRevision, cb, rental)`：`rental` 必填；同一產品一次只送一筆同意或取消，前一筆未回時回 `nil, "pending"`。
- 租約 id 與其他 id 同規則（1–96 字元字串、不含控制字元），不合格時本機回 `nil, "invalid_args"`。

`Client.openAdminPlans(sourceMod?, productId?)` 開啟管理台的唯讀方案總覽並選到該產品；讀取權限仍由伺服器重新驗證。

### 到商店上架（客戶端 rev 4，`CAPABILITIES.shopAdd`）

提供物品的 MOD 可以在自己的介面放「到經濟中心上架」按鈕，把一批物品交給 Economy 管理視窗的商店頁變成草稿。只開草稿：價格、分類、每份件數、限購都由管理員填，按「套用變更」後才走商店既有流程寫 `catalog.json`；Economy 不會自動上架、不會自動定價。

```lua
local EC = MinidoracatEconomy and MinidoracatEconomy.v1 and MinidoracatEconomy.v1.Client
local canShop = EC and EC.API_MAJOR == 1 and (EC.API_REVISION or 0) >= 4
    and EC.CAPABILITIES and EC.CAPABILITIES.shopAdd == true
if canShop then
    local ok, err = EC.openAdminShop("MyMod", { "MyMod.Widget", "MyMod.WidgetPart", "Base.Battery" })
    if not ok then --[[ err: "invalid_args" / "forbidden" / "unavailable" ]] end
end
```

`Client.openAdminShop(sourceModId, items)` → `ok, err?`

| 參數 | 規則 |
|---|---|
| `sourceModId` | 呼叫端的 Mod ID，與伺服器 `registerSource` 同規則（1–64 字元，英數、底線、連字號）；只用來在商店頁標示「誰要求上架」，不寫進 `catalog.json`（商品列沒有來源欄位） |
| `items` | 完整物品類型的陣列（例如 `"MyMod.Widget"`），最多 64 個；重複、非字串、遊戲沒載入的類型與隱藏／淘汰的物品略過 |

| 回傳 | 意義 |
|---|---|
| `true` | 管理視窗已開到商店頁（有未套用的編輯時先問要不要放棄；選留下就不會排入） |
| `false, "invalid_args"` | Mod ID 不合規則、`items` 不是表，或超過 64 個 |
| `false, "forbidden"` | 本機玩家沒有 Economy 的管理寫入權（`AdminRoles`，與物品右鍵「新增商品」同一道檢查）；伺服器在每次套用時仍重新驗證 |
| `false, "unavailable"` | 管理視窗開不了（沒有 UI 框架） |

商店頁的行為：

- 讀到商品目錄後，目錄裡任何一列已經在賣的物品類型略過；其餘依傳入順序成為新商品草稿，一次開一筆。頁尾一行說明「建立了幾筆草稿、幾件已在商店」，草稿的提示列寫出來源 Mod ID、後面還有幾筆，以及略過的物品名稱。
- 套用成功（新增一列）就開下一筆；按「取消」略過這筆、開下一筆。點目錄裡的商品、批次編輯、自己用搜尋新增或返回列表，都會結束這份清單（剩下的不再開）。
- 新草稿的預設與手動新增相同：分類 `other`、每份 1 件、上架開關開、沒有任何貨幣報價、收購關閉；商品 ID 由物品類型產生，可在套用前修改。
- 目錄已達服主的商品上限（`ShopMaxItems`）時不開草稿，頁尾顯示上限說明。
- 再次呼叫會取代尚未開完的清單。
