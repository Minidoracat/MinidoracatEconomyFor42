# 設計稿：玩家之間轉帳

- 狀態：Accepted（服主 2026-09-28 回覆第 7 節；伺服器端已實作，形狀見第 3 節）
- 日期：2026-09-28
- 目標版本：MinidoracatEconomyFor42 下一個次版本；Project Zomboid Build 42.20.4+，只支援 dedicated server
- 取代：`economy-system-analysis.md` 與設計稿 A／C 裡「不提供玩家轉帳」的第一版決策；每個幣別各自開關，建議只開倖存幣（見 2.1）

## 1. 為什麼要做

服主要求加入玩家之間轉帳。目前玩家要付錢給別人，只能透過市場：收款人上架一件物品、付款人用約好的價格買下。這要兩人都到終端、約好時間，還會被收刊登費（預設 2%）與成交稅（預設 5%），帳上看起來也是買賣而不是付款。

轉帳只解決「把錢付給某位玩家」這一件事。它同時是回收管道：手續費直接銷毀，不進任何人的口袋。

## 2. 規則

### 2.1 幣別

- 每個幣別各自開關，預設都關閉。註冊表已有 `directTransfer` 欄位（兩個幣別目前都是靜態的 `false`）；實作時比照 `enabled`／`balanceMax`，在貨幣設定加上 runtime 覆寫。
- 貓幣可用 Discord 積分換入。開放它轉帳，等於讓積分可以在玩家之間直接流通（代購、洗分）；市場雖然也能用貓幣成交，但要經過上架物品、刊登費與成交稅。建議只開倖存幣。

### 2.2 金額、手續費與上限

新沙盒選項（群組 `transfer`，設定頁可即時覆寫）：

| 鍵 | 預設 | 意義 |
|---|---|---|
| `TransferEnabled` | `false` | 總開關；關閉時整個轉帳按鈕不顯示 |
| `TransferRemote` | `false` | 允許在終端／ATM 以外送出轉帳（第 7 節決定 1） |
| `TransferFeePercent` | `5` | 手續費百分比（0–50），無條件進位，開啟時最少 1；由付款人另外支付並全額銷毀 |
| `TransferMin` | `1` | 單筆最少 |
| `TransferMaxPerTx` | `5000` | 單筆最多 |
| `TransferDailyPerAccount` | `10000` | 每個帳號每個獎勵日最多轉出（只算本金，不含手續費），`0`＝不限；日界沿用 `RewardDayResetHour`／`RewardTimezoneUTC` |
| `TransferMinAccountDays` | `3` | 新帳號門檻（0–365 現實天，`0`＝不限；第 7 節決定 3） |

不另設「每日收款上限」：收款人不需要同意也能收到錢，擋收款只會讓付款失敗、讓人猜得出對方餘額。收款仍受幣別的 `BalanceMax`，會超過時拒絕並告訴付款人「對方目前無法收這個金額」，不寫出對方餘額。

### 2.3 誰能轉給誰

- 付款人與收款人都不能是凍結帳號；不能轉給自己；收款人必須是經濟系統已知的玩家帳號（與統計、排行榜同一份名單：有錢包、領獎紀錄、凍結紀錄或目前在線），系統帳戶、`MOD:`、`EXTERNAL_` 帳戶一律拒絕。
- 帳號名稱精確比對（大小寫與空白都算），不做模糊匹配直接送出；確認步驟寫出伺服器比對到的完整帳號名。
- 寫入指令沿用現有規則：預設要站在已登錄終端或原版 ATM 的 2 格內（`RemoteReadOnly` 只決定能不能在終端外開視窗瀏覽）。`TransferRemote` 打開時，轉帳是唯一可以在任何地方送出的寫入，其餘檢查不變。
- 新帳號門檻：伺服器在 `hello` 記下每個帳號第一次出現的時間（`md.firstSeen[username]`），`readyAt = firstSeen + TransferMinAccountDays × 86400000`。沒有紀錄的帳號（沒送過 `hello`）視為還沒開始起算，跳過 `hello` 不能跳過等待。
- 既有帳號豁免：第一次載入含本功能的版本、`md.firstSeen` 還不存在時，把經濟系統當下已知的帳號（錢包、領獎紀錄、凍結紀錄；與 ECStats 同一份名單，系統帳戶除外）一律記成 `0`，升級不會把老玩家鎖住。回滾的互動：這份表隨世界存檔保存，崩潰回滾到「升級前」的存檔會再跑一次遷移，名單只會是那份存檔的帳號（相同或更少）；在被回滾的分支裡才出現的新帳號沒有紀錄，下次 `hello` 以較晚的時間重新起算。降版再升版時表還在、不會重跑，降版期間新建的帳號同樣從升版後第一次登入起算。所有路徑只會讓等待變長，不會變短。

### 2.4 不可撤回

轉帳成功後不能取消或退款。收款人要退錢就再轉一筆回去（一樣付手續費）。管理員需要更正時用既有的調帳，會留下原因與稽核紀錄。

## 3. 伺服器

### 3.1 指令

```text
transfer.info { requestId }
  -> { requestId, ok, enabled, remote, atTerminal, feePercent, min, maxPerTx, dailyLimit, sentToday,
       remainingToday (不限時 nil), readyAt (ms；nil 或 <= now 代表可轉), currencies = { 現在可轉的幣別 } }
transfer.recipients { query, requestId }
  -> { requestId, query, items = { { username, online }, ... } }   -- 最多 20 筆
wallet.transfer { to, currency, amount, fee, memo?, requestId }
  -> { requestId, ok, error?, to, currency, amount, fee, total, txId?, balance?, sentToday?, remainingToday?,
       duplicate?, feeNow?, availableAt?, needed?, min?, max? }
wallet.transferReceived (推播給在線收款人) { from, currency, amount, memo?, txId, balance }
```

候選：名稱包含查詢字串（不分大小寫）的在線玩家、自己最近 10 個轉帳對象（雙向都算），以及大小寫完全相符的已知帳號；不列自己與系統帳戶，功能關閉時回空清單。

錯誤碼：`invalid_args`、`request_too_long`、`request_conflict`、`transfer_disabled`、`currency_not_transferable`、`unknown_recipient`（含系統帳戶）、`self_transfer`、`account_frozen`、`recipient_frozen`、`not_at_terminal`、`account_too_new`（附 `availableAt`）、`amount_range`（附 `min`／`max`）、`fee_changed`（附 `feeNow`）、`daily_limit`（附 `remainingToday`）、`recipient_cap`（不附對方餘額）、`insufficient_funds`（附 `needed`＝還差多少）、`not_ready`。玩家端另受每人每指令 500 ms 節流（逾越的請求不回覆）。

`fee` 是介面顯示給玩家確認的手續費。伺服器重算；兩者不同就回 `fee_changed` 並附上新手續費，不以玩家沒確認過的金額扣款（與商店的報價版本檢查同一個原則）。

檢查順序（任何一步失敗都不動帳）：形狀 → 冪等鍵 `transfer:<付款人>:<requestId>` 已有結果就原樣回覆（`duplicate=true`）、內容不同回 `request_conflict` → 功能與幣別開關 → 不是自己 → 收款人存在 → 雙方凍結 → 終端（`TransferRemote` 關閉時）→ 新帳號門檻 → 金額範圍 → 手續費一致 → 今日已轉出額度 → 收款人 `BalanceMax` → 付款人餘額（本金＋手續費）→ 記帳。

### 3.2 記帳

一筆交易三條分錄，`kind = "transfer"`：

| 帳戶 | 分錄 |
|---|---|
| 付款人 | −（本金＋手續費） |
| 收款人 | ＋本金 |
| `SYSTEM_BURN` | ＋手續費 |

`reasonCode = "player_transfer"`、`reasonText = 備註`、`payload = { from, to, memo }`。手續費為 0 時省略銷毀分錄。整筆在同一個 `L.post` 裡完成，和其他帳目一起存進世界存檔；沒有物品移動，所以崩潰回滾時雙方餘額一起回到上次存檔，不會出現一邊扣了、一邊沒收到的狀態。今日已轉出額度存在 `md.transferDaily[day][username]`，沿用商店每日桶的 31 天清理；最近對象存在 `md.transferRecent[username]`（最多 10 筆）。

### 3.3 紀錄與通知

- 雙方收據都記對方帳號與備註；錢包對帳單新增「轉出」「轉入」兩種類型，可用對方帳號或備註搜尋。
- 帳目沿用 `tx.committed{kind="transfer", payload}`，日報與管理頁金流自動涵蓋，不另設事件；金流頁的類型篩選多一個「轉帳」。
- 收款人在線時推送 `wallet.transferReceived` 與一般的 `wallet.changed`，介面據此顯示一則通知：「收到 花生 的轉帳 +1,500 倖存幣（車費）」。不在線就在下次登入時從對帳單看到。
- 備註比照整合 API 的 `reasonText`，最多 64 字、不可含控制字元；只給交易雙方與管理員看，不進公開排行榜或電台。

### 3.4 整合 API（第 7 節決定 4）

`MinidoracatEconomy.v1` 在 `ECTransfer` 載入後升為 `API_REVISION = 3`、`CAPABILITIES.transfer = true`：`src.transfer(from, to, currency, amount, opts)` 或頂層 `E.transfer(..., opts 含 modId)`。`opts` 與 credit／debit 相同（必填 `requestId`、`reasonCode`，選填 `reasonText`、`ref`、`meta`）。來源必須啟用，且服主在管理頁「整合」打開 `allowTransfer`（`admin.sources{action="set", modId, allowTransfer, reason}`，預設關、有稽核）；幣別也要在來源註冊的清單裡。其餘沿用玩家轉帳的全部檢查，只是不檢查終端、沒有備註；冪等鍵與同來源的 `post` 共用 `mod:<len>:<modId>:<requestId>`。回傳 `{ ok, txId, fee, duplicate }` 或 `{ ok=false, error }`（多了 `unknown_source`、`rate_limited`、`source_disabled`、`transfer_not_allowed`、`currency_not_allowed`）。帳目 `kind = "transfer"`、`reasonCode` 為來源自己的代碼、`payload.sourceMod = modId`。

## 4. 介面

入口放在錢包頁：「轉帳」按鈕（`TransferEnabled` 關閉或沒有可轉幣別時不顯示）。對話框分兩步：

1. **填寫**：收款人（候選清單列出在線玩家與最近的轉帳對象；離線的人要輸入完整帳號名，由伺服器精確比對）、幣別（只列可轉帳的幣別）、金額、備註（選填，佔位字例：「車費」）。下方即時預覽：手續費、合計扣款、轉帳後餘額、今日剩餘可轉出額度。
2. **確認**：主要按鈕寫出完整後果「轉給 花生 1,575 倖存幣」，次要按鈕「取消」。送出中鎖定按鈕，等伺服器回覆；逾時只查原請求，不自動重送。

錯誤放在對應欄位旁並說明怎麼處理，例如「餘額不足：還差 75 倖存幣」「今日可轉出額度剩 2,000」「找不到這個帳號：請確認完整帳號名，大小寫要相同」「手續費已調整為 80，請重新確認」。

鍵盤與手把沿用框架 `UI.Focus`：Tab／方向鍵依序走訪欄位，Enter 在確認步驟才會送出，Esc／B 關閉對話框。四語系與四種字級都要能顯示完整帳號名；帳號過長時截斷顯示，完整名稱在確認步驟完整寫出。

## 5. 管理

- 設定頁多一個「轉帳」群組（上表七項）；貨幣設定每個幣別多一個「允許玩家轉帳」開關（`admin.config{currency, field="directTransfer", value, reason}`，寫入權限、有稽核），貓幣旁註明積分代購的風險；整合頁每個來源多一個「允許轉帳」開關。
- 金流頁可篩選 `transfer`；單筆明細顯示雙方、手續費與備註。
- 異常處理沿用凍結帳號：凍結後立即不能轉出也不能收款。不提供管理員撤銷轉帳，更正一律用調帳。

## 6. 測試與驗收

- harness：成功轉帳的三條分錄與守恆、雙方收據與事件；冪等重送、`request_conflict`；自己、系統帳戶、不存在帳號、凍結的付款人或收款人、關閉的功能或幣別、金額邊界、手續費進位與最少 1、`fee_changed`、今日額度剛好用完與超過一元、換日歸零、收款人 `recipient_cap`、餘額剛好等於本金＋手續費、終端閘門與 `TransferRemote`、新帳號門檻與豁免遷移（含回滾重跑）、API 的 `allowTransfer`／停用來源／每 tick 上限、玩家端節流；每個拒絕都證明零變更。
- 介面離線情境：四語系 × 四字級的填寫與確認步驟、長帳號、錯誤列、鍵盤與手把走訪。
- 實機 E2E（`transfer-mp`）：單一客戶端經真網路送出成功轉帳與數種拒絕，收款人是 fixture 建立的離線帳號；雙客戶端的收款通知與兩側對帳單另行驗收。

## 7. 服主決定（2026-09-28）

1. **終端外轉帳**：做成選項 `TransferRemote`，預設關閉（維持終端限制，服主可自行打開）。
2. **預設值**：維持手續費 5%、單筆 5,000、每日 10,000；整個功能預設關閉（`TransferEnabled=false`），每個幣別的 `directTransfer` 也預設關閉。
3. **新帳號門檻**：做成選項 `TransferMinAccountDays`，預設 3 天，`0`＝不限；上線前已存在的帳號豁免（見 2.3）。
4. **其他 MOD 轉帳**：開放 API rev 3，但每個來源要由服主打開 `allowTransfer`，預設關閉（見 3.4）。
