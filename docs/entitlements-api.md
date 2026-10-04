# 通用名額權益 API（API major 1、revision 2）

此介面供其他 **dedicated server MOD** 販售永久額度與定期租用額度。Economy 管付款、權益、期限、授權與方案；使用額度的 MOD 決定額度代表什麼。VehicleManager 是第一個實際消費端；安全屋可用另一個來源／產品接入，本文件不代表安全屋已完成整合。

## 使用前提

伺服器先確認 `MinidoracatEconomy.v1` 的 `API_MAJOR == 1`、`API_REVISION >= 2`，以及 `CAPABILITIES.entitlements`、`CAPABILITIES.subscriptions`、`CAPABILITIES.rentals`。`rentals` 表示租用是**租約清單**：每筆新租用訂單是一張獨立租約，有自己的名額數、到期時間、續租與自動續費；沒有這個能力的 Economy 是舊的單一租約模型，參數與 snapshot 形狀都不同，消費端應視為不可用。既有 `post/credit/debit` 行為不變；舊 `CAPABILITIES.subscribe=false` 不改為新能力的別名。

Economy 是選用整合的消費端不必加 `require=MinidoracatEconomyFor42`。Economy 缺席、版本過舊或查詢失敗時，消費端必須明示付費服務不可用，不猜測可用額度。

權益按 **來源 MOD、帳號、產品** 分開。它屬於目前世界，不能當跨世界的永久訂閱。帳號用伺服器取得的 `getUsername()`，不是角色顯示名或 client 傳入的付款人。

## 註冊

在伺服器 Lua 全部載入後取得來源 handle，為每個產品註冊一次。來源 handle 用點號呼叫，不是冒號。

```lua
local E = MinidoracatEconomy and MinidoracatEconomy.v1
if not (E and E.API_MAJOR == 1 and E.API_REVISION >= 2
    and E.CAPABILITIES.entitlements and E.CAPABILITIES.subscriptions and E.CAPABILITIES.rentals) then return end

local source, err = E.registerSource({
    modId = "MyMod",
    displayName = { EN = "My Mod" },
    currencies = { "survivor", "cat" },
    reasonCodes = { "entitlement_purchase", "entitlement_renewal", "entitlement_refund" },
})
if not source then return end
local result = source.registerProduct({
    id = "claim_slot",
    nameKey = "IGUI_MyMod_ClaimSlot",
    defaults = {
        permanentEnabled = false, permanentCurrency = "survivor", permanentPrice = 1000, permanentLimit = 10,
        rentalEnabled = false, rentalCurrency = "survivor", rentalPrice = 250, rentalLimit = 5,
        rentalDays = 7, graceHours = 24, reminderHours = 24, autoRenewAllowed = true,
    },
})
```

價格只是預設範例；兩種販售預設都關閉。翻譯鍵由產品的 MOD 提供。產品 ID 為 1–32 字元的小寫英文、數字或底線。重啟後需再次註冊；已保存的方案與權益不會被 defaults 重置。

方案欄位：

| 欄位 | 意義 |
|---|---|
| `permanentPrice` | 每個名額的買斷價；一次買 k 個收 k 倍 |
| `permanentLimit` | 每個帳號最多買斷幾個名額，0–1000 |
| `rentalPrice` | 每個名額每期的租金；一張 n 個名額的租約每期收 n 倍 |
| `rentalLimit` | 每個帳號所有租約合計最多租幾個名額，1–1000；停止租用請關 `rentalEnabled` |
| `rentalDays`／`graceHours`／`reminderHours`／`autoRenewAllowed` | 每期天數、寬限、到期前提醒、是否允許自動續費 |

舊方案的 `rentalQuantity` 已刪除；驗證不過的舊方案列轉為 provisional（不可購買），等沙盒值或管理員重新套用。

可選 `validatePurchase(username, productId, kind, quantity, projected)` 回呼應回 `true` 或 `false, reason`，其中 projected 含 `permanent/rental/usable/pendingQuantity`。回呼失敗或丟出例外會拒絕付款。它適合檢查消費端目前能否提供服務，不應因「基本額度已用完」而拒絕加購額度。

## 伺服器 handle

| 方法 | 用途 |
|---|---|
| `registerProduct(spec)` | 登錄產品、初始方案、選用沙盒映射及購買驗證回呼 |
| `getEntitlement(username, productId)` | 唯讀權益、方案、餘額及近期訂單；不建立錢包 |
| `quote(username, productId, kind, quantity, rental?)` | 建立 120 秒有效的伺服器報價，見下方「報價種類」 |
| `purchase(username, quoteId)` | 提交同一張報價；不讓客戶端指定價格或貨幣 |
| `getOrder(username, productId, orderId)` | 查同一筆訂單結果，不再次扣款 |
| `setAutoRenew(username, productId, enabled, expectedRevision, termsRevision, rental)` | 對某張租約明示同意或取消自動續費；帶權益與條款版本（過期的 termsRevision 仍會被拒，玩家必須看過目前方案），`rental` 必填。同意會記下當下方案的租金、幣別與每期天數 |
| `refund(username, productId, orderId, opts)` | 對可查的原單退款並收回對應權益；opts 必填 reason，可帶 actor |
| `onEntitlementChanged(fn)` | 完整變更後呼叫 `fn(username, productId, snapshot)` |

一般結果為 `{ok, error?}`。查詢成功的 snapshot 包含：

- `sourceMod/productId/nameKey/available/plan`。
- `entitlement.revision/permanent/rental/usable/pendingQuantity/pendingOrderId/lastOrderId/state`：`rental` 是所有有效租約的名額總和；`pendingQuantity` 是待確認的買斷加上還沒生效、正在等付款確認的租約名額；`pendingOrderId` 只列玩家自己發起、還沒確認的最新訂單（自動續費產生的不算）；`state` 為 `active`（usable > 0）、`pending`（只有待確認）或 `none`。
- `entitlement.rentalCommitted`：計入 `rentalLimit` 的名額，即有效租約加上有待確認付款的租約。`entitlement.rentalsMax`：每個帳號最多幾張租約（伺服器固定 10）。
- `entitlement.rentals`：依建立順序的租約清單，每張 `{ id, quantity, state, paidUntil?, graceUntil?, terms?, autoRenew, autoRenewState, autoTerms?, termsRevision?, pendingOrderId?, autoPending? }`。`id` 是建立它的訂單 id；`state` 為 `pending/active/grace/expired/paused_terms/paused_system`（條款改變、租用合計超過 `rentalLimit` 或租用停售時為 `paused_terms`）；`autoRenewState` 為 `off/pending_on/on/pending_off/paused_terms/paused_system`，其中 `paused_terms` 表示目前方案的租金、幣別或每期天數和同意時記下的不同（或租用合計超過上限），要玩家重新同意；`autoPending=true` 表示這張的待確認付款是自動續費發起的。
- `rentals[i].terms = { price, amount, currency, days, graceHours }`：這張租約正在跑（或已付款待生效）的那一期的條款，`price` 是每個名額的租金、`amount` 是該期總額。`rentals[i].autoTerms = { price, currency, days }`：自動續費開啟時，玩家同意的條款。
- `entitlement.durable`（status、source、seq 等），以及可選的 `wait`、`notice`（`notice.rental` 指出是哪張租約）。
- `balances`（以貨幣 ID 索引的 available、reserved、rev）、最近最多 20 筆 `orders`；租用訂單帶 `rental`（所屬租約 id），排程自動續費的訂單帶 `auto=true`。

舊的頂層 `paidUntil/graceUntil/autoRenew/autoRenewState/termsRevision` 已刪除，改讀各租約的同名欄位。

**消費端只使用 `entitlement.usable` 作為可新增的付費額度。** 不自行將 pending 相加，不從歷史收據、餘額差或過去快取推測額度。

## 報價、付款與未知結果

### 報價種類

| 呼叫 | 意義 | 條件 | 價格 |
|---|---|---|---|
| `quote(u, p, "permanent", k)` | 買斷 k 個（1–100，預設 1） | 已買斷 + k ≤ `permanentLimit` | k × `permanentPrice` |
| `quote(u, p, "rental", n)` | 新租約 n 個（1–`rentalLimit`，預設 1） | `rentalCommitted` + n ≤ `rentalLimit`，且租約未滿 `rentalsMax` 張 | n × `rentalPrice` |
| `quote(u, p, "rental", nil, rentalId)` | 續租該張租約（quantity 省略或等於該張名額數） | 該張沒有待確認付款，且租用合計未超過 `rentalLimit` | 該張名額數 × `rentalPrice` |

- 新租約從存檔確認啟用時起算一整期；等待存檔的時間不算在租期內。
- 續租期中或寬限期的租約從原 `paidUntil` 延長一期；已過寬限的從啟用時起算。續租不改名額數：要改數量就另租一張，讓舊的到期。
- 一次一筆玩家發起的待確認購買是**客戶端規則**：`pendingOrderId` 有值時不讓玩家再買。自動續費產生的待確認付款不擋玩家購買，只擋同一張租約再續租（`lease_pending`）。

報價回傳 `quote.id/orderId/kind/quantity/currency/amount/termsRevision/expiresAt`。付款前保存 `quote.orderId`；它與該報價的 id 相同，付款結果仍回同一 orderId。

送出付款後逾時只代表 **結果未知**。不得再建立新報價自動重付，也不能用 snapshot 最新的 lastOrderId 猜測是哪一筆。只能查保存的原 orderId。

`getOrder` 的 `known=false` 不是未付款證明。已知且 `paid=false, final=true` 的 `unsubmitted/declined/rolledback` 才是終局未付；已知 `paid/refunded` 還要區分保存待確認與 confirmed。超過近期訂單查詢／退款視窗時需人工核對，不藉由重送 debit 查結果。

判定 `unsubmitted/declined` 必須有該來源／帳號／產品的報價歸屬證據；失效報價證據有界保留，淘汰後返回 unknown。重啟後若該列沒有訂單，也返回 unknown；不能拿全域交易序號、舊啟動保存水位或「近期找不到」推論某帳號未付款。重連後可讀取目前權益與錢包，再由玩家明確發起新的購買；這不代表已判定舊單未付。

## 保存、啟用與崩潰界線

錢包與財務權益同存 Global ModData。同一筆提交先完成驗證及預配置，再一起更新；通知在完整提交後才發出。不過「函式成功」仍不是存檔已寫入的證明。

新付費額度須滿足下列其中一項才可用：

1. 既有 companion 解析真實、穩定的世界存檔，發布本次啟動且涵蓋該交易的保存水位。
2. 正常重啟後，該權益確實從世界存檔載入。

沒有 companion 時，畫面會說明需等重啟載入確認；不以經過幾秒、主控台存檔訊息或交易 JSON 代替證據。永久權益本體不依賴有限的啟動歷史，因此不會因啟動超過 20 次而被遺忘。

付款保存確認不等於租用已啟用：還須將該張租約的固定啟用時間寫進日誌並讀回核對。新租約與過寬限後的續租從該時間起算；連續續期沿前一期 `paidUntil` 延長。再次崩潰重啟沿用原啟用時間，不重算一整期。取消某張租約的自動續費立即停止本程序尚未執行的續費，但未保存前顯示 `pending_off`；重放以同一張租約、同一授權世代匹配，不能套到後來的新同意或別張租約。

日誌位於伺服器 `Lua/MinidoracatEconomy/entitlements-journal.json`，內容為逐行 JSON。取消寫入或讀回確認失敗時，回覆 `ok=false, error=journal_unavailable`；本程序先停止排程，但不能承諾崩潰後仍保持取消。畫面保留待確認狀態，修復日誌或確認 off 狀態真正保存後才能完成。

日誌不可讀、損毀、寫入驗證失敗或容量不足時，相關啟用／續費暫停並顯示原因；不改用當下時間猜測、不抹掉已確認權益。**日誌不能當付款耐久證明。**

這些保證針對可讀取已保存檔案的程序崩潰情境，不保證 OS 當機／斷電的 fsync、手動改檔或混搭不同時間的備份。備份還原須包含一致的世界存檔及經濟日誌。

## 租用與續費

- 每張租約有自己的名額數、到期時間、寬限、續租與自動續費；綁定上限＝基本＋買斷＋所有有效租約名額。續費不改名額數，也不多加一張。
- 自動續費預設關閉，逐張開關。每張租約是一份契約：每一期記下自己的租金、幣別、天數與寬限（`terms`），同意自動續費時記下當下的租金、幣別與每期天數（`autoTerms`）；同意未確認保存前不排程扣款。到期時按記下的條款扣該張的租金。
- 啟用自動續費也會檢查帳戶未凍結、幣別啟用及來源貨幣白名單；取消不受這些付款限制阻擋，但仍驗證授權世代以免舊取消覆蓋新同意。
- 到期時才嘗試自動續費，事先依 reminderHours 提醒。餘額不足在寬限期間每小時重試，寬限結束關閉該張的自動續費；系統不可用、凍結及來源停用會另外說明，不記成歷史欠債。
- 寬限時間內租用額度仍有效。寬限結束後不再增加可新增名額；VehicleManager 不會因此解除既有車的保護。
- 伺服器停機跨過多個周期，不補扣多期；重新開通只收一個明示周期。
- **到期移除**：寬限結束、沒有待確認付款、自動續費已關閉且已存檔的租約，伺服器自動從清單移除。
- **改租金、幣別或每期天數**：不改寫已付期間。只要方案的 `rentalPrice`、`rentalCurrency`、`rentalDays` 與某張租約同意時記下的不同，那張的自動續費就暫停（`paused_terms`），玩家重新同意後才會再扣款（同意會記下當時的條款）；方案改回同意時的值，自動續費恢復。其他方案欄位（買斷欄位、`rentalLimit`、寬限、提醒等）的變更不會暫停已同意的自動續費；關閉 `autoRenewAllowed` 則另外停止自動續費。報價仍綁 termsRevision，任何方案變更都會讓舊報價失效。
- **調低 `rentalLimit`、低於玩家目前的租用合計**：現有租約照常用到到期，已付的續租照常啟用；合計超過上限時不能新租或續租（`limit_reached`），自動續費暫停；寬限期結束仍超過上限的那張關閉自動續費並到期。合計降回上限內後，其餘租約恢復續租。
- **退款**綁原訂單、至多原額一次，與權益減少同時提交，並關閉該張租約的自動續費：
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

## 方案管理與沙盒同步

Economy 管理頁「整合方案」集中顯示來源與產品。管理員修改草稿、查看差異和對既有租約的影響、填原因後明示確認；伺服器重新驗證權限、欄位與 revision。失敗保留草稿，版本衝突要求重新檢視，未知結果查同一 requestId，不自行再套用新版本。

產品可提供 `sandbox={planField="Namespace.Option",...,revision="Namespace.PlanRevision"}`。revision 映射是必要的防衝突欄位，由 Economy 管理，不應手動修改。

- 首次建立方案只採用驗證通過的沙盒值。無效值不被預設值覆蓋，方案顯示 provisional 且不可購買，待修正沙盒或由管理員明示套用合法方案。
- 同步版本相同且沙盒值改變：驗證後成為下一版方案。
- 沙盒版本較舊：視為原版整包設定的過期副本，保留現行方案並修正投影，不默默覆蓋新方案。
- 管理頁套用後會寫回伺服器沙盒檔，並以 MOD 同步訊息更新在線客戶端。
- 寫回失敗會明示 dirty／錯誤，不能把尚未保存的投影說成已同步。相同內容的套用不增加版本，也不會清除仍存在的寫回錯誤。

管理員可查帳號權益與退款（帳號頁逐張列出租約、各期條款、同意自動續費時的條款，並標出與目前方案不同之處），但不能替玩家開啟自動續費。

## 客戶端 API

能力探測位於 `MinidoracatEconomy.v1.Client`（不是客戶端的 `.v1.API_MAJOR`）。確認 major 1、rev >= 2、`CAPABILITIES.entitlements` 與 `CAPABILITIES.rentals` 後取 `.Entitlements`：

`requestState/getState/quote/purchase/setAutoRenew/getOrder/onChanged` 對應上述用途；送出方法回 requestId，若回 `nil, reason` 代表本機未送出且不會呼叫 callback。逾時 callback 包含 unknown 與原付款識別。客戶端只保存投影，不自行授權。

- `quote(sourceMod, productId, kind, quantity, cb, rental?)`：`rental` 省略為買斷或新租約，給租約 id 為續租該張；只有 `kind == "rental"` 能帶 `rental`。
- `setAutoRenew(sourceMod, productId, enabled, revision, termsRevision, cb, rental)`：`rental` 必填；同一產品一次只送一筆同意或取消，前一筆未回時回 `nil, "pending"`。
- 租約 id 與其他 id 同規則（1–96 字元字串、不含控制字元），不合格時本機回 `nil, "invalid_args"`。

`Client.openAdminPlans(sourceMod?, productId?)` 可開啟共用管理頁；讀寫權限仍由伺服器重新驗證。
