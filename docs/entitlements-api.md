# 通用名額權益 API（API major 1、revision 2）

此介面供其他 **dedicated server MOD** 販售永久額度與定期租用額度。Economy 管付款、權益、期限、授權與方案；使用額度的 MOD 決定額度代表什麼。VehicleManager 是第一個實際消費端；安全屋可用另一個來源／產品接入，本文件不代表安全屋已完成整合。

## 使用前提

伺服器先確認 `MinidoracatEconomy.v1` 的 `API_MAJOR == 1`、`API_REVISION >= 2`，以及 `CAPABILITIES.entitlements`、`CAPABILITIES.subscriptions`。既有 `post/credit/debit` 行為不變；舊 `CAPABILITIES.subscribe=false` 不改為新能力的別名。

Economy 是選用整合的消費端不必加 `require=MinidoracatEconomyFor42`。Economy 缺席、版本過舊或查詢失敗時，消費端必須明示付費服務不可用，不猜測可用額度。

權益按 **來源 MOD、帳號、產品** 分開。它屬於目前世界，不能當跨世界的永久訂閱。帳號用伺服器取得的 `getUsername()`，不是角色顯示名或 client 傳入的付款人。

## 註冊

在伺服器 Lua 全部載入後取得來源 handle，為每個產品註冊一次。來源 handle 用點號呼叫，不是冒號。

```lua
local E = MinidoracatEconomy and MinidoracatEconomy.v1
if not (E and E.API_MAJOR == 1 and E.API_REVISION >= 2
    and E.CAPABILITIES.entitlements and E.CAPABILITIES.subscriptions) then return end

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
        rentalEnabled = false, rentalCurrency = "survivor", rentalPrice = 250, rentalQuantity = 1,
        rentalDays = 7, graceHours = 24, reminderHours = 24, autoRenewAllowed = true,
    },
})
```

價格只是預設範例；兩種販售預設都關閉。翻譯鍵由產品的 MOD 提供。產品 ID 為 1–32 字元的小寫英文、數字或底線。重啟後需再次註冊；已保存的方案與權益不會被 defaults 重置。

可選 `validatePurchase(username, productId, kind, quantity, projected)` 回呼應回 `true` 或 `false, reason`，其中 projected 含 `permanent/rental/usable/pendingQuantity`。回呼失敗或丟出例外會拒絕付款。它適合檢查消費端目前能否提供服務，不應因「基本額度已用完」而拒絕加購額度。

## 伺服器 handle

| 方法 | 用途 |
|---|---|
| `registerProduct(spec)` | 登錄產品、初始方案、選用沙盒映射及購買驗證回呼 |
| `getEntitlement(username, productId)` | 唯讀權益、方案、餘額及近期訂單；不建立錢包 |
| `quote(username, productId, kind, quantity)` | 建立 120 秒有效的伺服器報價；kind 為 `permanent` 或 `rental` |
| `purchase(username, quoteId)` | 提交同一張報價；不讓客戶端指定價格或貨幣 |
| `getOrder(username, productId, orderId)` | 查同一筆訂單結果，不再次扣款 |
| `setAutoRenew(username, productId, enabled, expectedRevision, termsRevision)` | 明示同意或取消自動續費；帶權益與條款版本 |
| `refund(username, productId, orderId, opts)` | 對可查的原單退款並收回對應權益；opts 必填 reason，可帶 actor |
| `onEntitlementChanged(fn)` | 完整變更後呼叫 `fn(username, productId, snapshot)` |

一般結果為 `{ok, error?}`。查詢成功的 snapshot 包含：

- `sourceMod/productId/nameKey/available/plan`。
- `entitlement.revision/permanent/rental/usable/pendingQuantity/pendingOrderId/lastOrderId`。
- `entitlement.paidUntil/graceUntil/state/autoRenew/autoRenewState/termsRevision`。
- `entitlement.durable`（status、source、seq 等），以及可選的 `wait`、`notice`。
- `balances`（以貨幣 ID 索引的 available、reserved、rev）、最近最多 20 筆 `orders`。

**消費端只使用 `entitlement.usable` 作為可新增的付費額度。** 不自行將 pending 相加，不從歷史收據、餘額差或過去快取推測額度。

## 報價、付款與未知結果

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

付款保存確認不等於租用已啟用：還須將固定啟用時間寫進日誌並讀回核對。首次／逾期重新啟用從該時間起算；連續續期沿前一期 `paidUntil` 延長。再次崩潰重啟沿用原啟用時間，不重算一整期。取消立即停止本程序尚未執行的續費，但未保存前顯示 `pending_off`；重放以同一授權世代匹配，不能套到後來的新同意。

日誌位於伺服器 `Lua/MinidoracatEconomy/entitlements-journal.json`，內容為逐行 JSON。取消寫入或讀回確認失敗時，回覆 `ok=false, error=journal_unavailable`；本程序先停止排程，但不能承諾崩潰後仍保持取消。畫面保留待確認狀態，修復日誌或確認 off 狀態真正保存後才能完成。

日誌不可讀、損毀、寫入驗證失敗或容量不足時，相關啟用／續費暫停並顯示原因；不改用當下時間猜測、不抹掉已確認權益。**日誌不能當付款耐久證明。**

這些保證針對可讀取已保存檔案的程序崩潰情境，不保證 OS 當機／斷電的 fsync、手動改檔或混搭不同時間的備份。備份還原須包含一致的世界存檔及經濟日誌。

## 租用與續費

- 一組租用提供方案的 rentalQuantity 個名額，不因續費多加一組。
- 自動續費預設關閉。玩家同意綁定當時的條款；同意未確認保存前不排程扣款。
- 啟用自動續費也會檢查帳戶未凍結、幣別啟用及來源貨幣白名單；取消不受這些付款限制阻擋，但仍驗證授權世代以免舊取消覆蓋新同意。
- 到期時才嘗試自動續費，事先依 reminderHours 提醒。餘額不足在寬限期間有限重試；系統不可用、凍結及來源停用會另外說明，不記成歷史欠債。
- 寬限時間內租用額度仍有效。寬限結束後不再增加可新增名額；VehicleManager 不會因此解除既有車的保護。
- 伺服器停機跨過多個周期，不補扣多期；重新開通只收一個明示周期。
- 改價不改寫已付本期的數量或到期日，舊自動續費同意會暫停。租約仍有效但方案數量改變時，要等當期結束後再用新數量租用。
- 退款綁原訂單、至多原額一次，與權益減少同時提交。租用只允許處理沒有後續周期依賴的最新一期。退款不放寬一般 credit 的發行額度。

## 方案管理與沙盒同步

Economy 管理頁「整合方案」集中顯示來源與產品。管理員修改草稿、查看差異和對既有租約的影響、填原因後明示確認；伺服器重新驗證權限、欄位與 revision。失敗保留草稿，版本衝突要求重新檢視，未知結果查同一 requestId，不自行再套用新版本。

產品可提供 `sandbox={planField="Namespace.Option",...,revision="Namespace.PlanRevision"}`。revision 映射是必要的防衝突欄位，由 Economy 管理，不應手動修改。

- 首次建立方案只採用驗證通過的沙盒值。無效值不被預設值覆蓋，方案顯示 provisional 且不可購買，待修正沙盒或由管理員明示套用合法方案。
- 同步版本相同且沙盒值改變：驗證後成為下一版方案。
- 沙盒版本較舊：視為原版整包設定的過期副本，保留現行方案並修正投影，不默默覆蓋新方案。
- 管理頁套用後會寫回伺服器沙盒檔，並以 MOD 同步訊息更新在線客戶端。
- 寫回失敗會明示 dirty／錯誤，不能把尚未保存的投影說成已同步。相同內容的套用不增加版本，也不會清除仍存在的寫回錯誤。

管理員可查帳號權益與退款，但不能替玩家開啟自動續費。

## 客戶端 API

能力探測位於 `MinidoracatEconomy.v1.Client`（不是客戶端的 `.v1.API_MAJOR`）。確認 major 1、rev >= 2、`CAPABILITIES.entitlements` 後取 `.Entitlements`：

`requestState/getState/quote/purchase/setAutoRenew/getOrder/onChanged` 對應上述用途；送出方法回 requestId，若回 `nil, reason` 代表本機未送出且不會呼叫 callback。逾時 callback 包含 unknown 與原付款識別。客戶端只保存投影，不自行授權。

`Client.openAdminPlans(sourceMod?, productId?)` 可開啟共用管理頁；讀寫權限仍由伺服器重新驗證。
