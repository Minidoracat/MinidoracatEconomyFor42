# 設計稿 C：混合式——系統商店（價格錨）＋玩家刊登＋拍賣＋貨幣回收

- 狀態：Draft
- 日期：2026-09-02
- 目標版本：Project Zomboid Build 42.20.4+，headless dedicated server 多人專用
- 證據基線：`docs/economy-system-analysis.md`
- 文件定位：產品與 server domain contract；不代表所列 PZ API、物品 round-trip 或外部橋接已完成實作驗證

## 1. 概要

### 1.1 方案定位

設計稿 C 採「共同入口、共同錢包、共同帳本，交易規則分離」：玩家從同一個「經濟中心」一鍵切換系統商店、玩家固定價刊登、拍賣與收件匣；三者共用交易幣餘額、社群幣餘額、交易收據與管理觀測，但各自保有獨立 command、service 與狀態機。玩家固定價刊登再分成「交易站世界容器」與「中央託管白名單」兩種 custody；這是同一個市場頁籤的兩種履約方式，不是兩套錢包。

系統商店由管理員維護 catalog，採無限庫存：系統不保存會被買空的實體庫存，只在成功交易後建立待交付物品。無限庫存不等於無限購買；每個 SKU 都必須有有限的每帳號每日限購，並受價格、數量、餘額及全域 hard cap 約束。

系統商店同時扮演兩個方向相反的經濟工具：

- 玩家向系統購買物品：交易幣直接 `burn`，物品進入世界，是物品水龍頭與貨幣回收口。
- 玩家把合格物品賣給系統：物品由系統銷毀，交易幣直接 `mint`，是受控貨幣水龍頭。

玩家刊登與拍賣只在玩家之間移轉既有交易幣，成交額本身不是 `mint`；刊登費、拍賣費與成交稅才是 `burn`。第一個玩家市場採交易站＋全服目錄：物品留在賣家的世界容器，保留原生完整狀態；中央託管及拍賣只接受已通過重建矩陣的物品白名單。安全屋與車輛維護費屬可選沉點，預設關閉，待資產識別與所有權 API 完成查證後才可啟用。

本方案繼承既有分析的雙貨幣決策：

- **交易幣（暫稱）**：系統商店、玩家刊登與拍賣的唯一報價及結算貨幣。
- **社群幣（暫稱）**：由 Discord 積分兌換而來，與交易幣顯示在同一錢包，但維持 account-bound，不可 P2P、不可直接參與玩家市場或拍賣，也不可反向換回 Discord 積分。

### 1.2 價格錨的精確語意

「買入價／賣出價」容易因系統與玩家視角相反而混淆，因此 domain 欄位固定為：

| Domain 欄位 | 管理員與玩家 UI 文案 | 資金效果 |
|---|---|---|
| `askPrice` | 系統售價／玩家「你支付」 | 玩家向系統購買；全額 `burn` |
| `bidPrice` | 系統收購價／玩家「你取得」 | 玩家把物品賣給系統；全額 `mint` |

雙向開放的同一 canonical SKU 必須符合：

```text
0 <= bidPrice < askPrice
askPrice - bidPrice >= 1
```

未開放收購要用 `sellToSystemEnabled=false`，不得以 `0`、負數或空值兼任狀態。價格錨是**配額內的條件式錨**：玩家仍有購買配額時，`askPrice` 才是同規格商品的可得價格上緣；玩家與全服仍有收購額度時，`bidPrice` 才是流動性下緣。配額耗盡後，玩家市場價格可以離開該區間，UI 不得宣稱絕對保價。

### 1.3 貨幣流分類

| 事件 | `mint` | `burn` | 玩家間 transfer |
|---|---:|---:|---:|
| 玩家向系統購買 | 0 | `askPrice × qty` | 0 |
| 系統收購玩家物品 | `bidPrice × acceptedQty` | 0 | 0 |
| 玩家固定價成交 | 0 | 成交稅 | 買家 → 賣家淨額 |
| 拍賣成交 | 0 | 拍賣成交稅 | 得標者 reserve → 賣家淨額 |
| 刊登費／拍賣費 | 0 | 費用 | 0 |
| 出價 reserve／release | 0 | 0 | `available` 與 `reserved` 間移動 |
| 安全屋／車輛維護費 | 0 | 實收費用 | 0 |
| Discord 社群幣轉交易幣 | 交易幣增加額 | 社群幣扣除額 | 跨幣別連結事件 |
| 管理員加款／扣款 | `ADMIN_CREDIT` | `ADMIN_DEBIT` | 0 |

所有 fee 與 tax 都直接退出流通，不建立可再支出的系統 treasury。補償不得刪除舊帳本紀錄；應新增連結原交易的 `COMPENSATION_MINT` 或 `COMPENSATION_BURN`。

### 1.4 目標與非目標

目標：

- 為常見物資提供管理員可控、玩家看得懂的價格參考。
- 用系統售出、費用及稅建立可量測的貨幣回收口。
- 用受限收購提供初始流動性，但保證任何 economic day 都不會因世界物資而無限 `mint`。
- 讓固定價與拍賣交易共用一份錢包、帳本、收件匣與客服收據。
- 讓管理員以 mint／burn／供給守恆儀表板調參，而不是只看玩家抱怨猜通膨。

非目標：

- 不做玩家自由轉帳、社群幣 P2P 或實體貨幣 deposit／withdraw。
- 不把系統商店 SKU 偽裝成特殊玩家 listing。
- 不在第一版做 bundle 部分購買、grid view、動態價格演算法或拍賣 anti-sniping。
- 不承諾所有 MOD 物品都可收購；未知狀態一律 fail closed。

## 2. 玩家流程

### 2.1 共同入口與錢包

1. 玩家從單一入口開啟「經濟中心」。
2. Header 同時顯示交易幣、社群幣、reserved 交易幣及待領取件數。
3. 玩家可一鍵切換「系統商店」「玩家刊登」「拍賣」「我的交易／收件匣」；切換頁籤不建立新的錢包或登入狀態。
4. 每筆 mutation 完成後顯示短交易碼、餘額變化、物品去向及目前狀態；逾時後重試要查原收據，不得直接再扣款。

### 2.2 從系統商店購買

1. 玩家搜尋 SKU，查看系統售價、玩家市場參考價、今日剩餘限購與標準物品狀態。
2. 玩家輸入數量；client 顯示「你支付」、交易後餘額及交付方式預覽。
3. server 依 `skuId`、`catalogRevision`、`economicDayKey` 重新計價與重查配額，不接受 client 回傳的價格或 item description。
4. 成功時，交易幣 `burn`、購買配額增加，並建立持久 `DeliveryClaim`；背包可接受時再完成實體交付。
5. 若設定已改、跨日、餘額不足、配額不足或 SKU 緊急停用，整筆拒絕且不扣款、不消耗配額。

第一版批次交易採全有或全無，不自動把數量縮到剩餘配額，以免玩家在舊報價下意外買到不同數量。

### 2.3 把物品賣給系統

1. 玩家從自己的物品中選擇候選品；client 只送 item ID 與意圖。
2. server 重新從請求者可接受的 inventory 範圍找到該實體，擷取 full type 與 bounded canonical state，再判斷是否符合 SKU 收購規則。
3. UI 顯示「你取得」、今日帳號／SKU／分類剩餘額度，以及「系統收購會銷毀物品」的明示文字。
4. server 必須先完成全部價格、配額、狀態及餘額上限檢查，才可碰玩家物品。
5. 成功時，在同一 server tick 內移除已重查的原物、建立交易幣 `mint` postings、提交配額計數與 Global ModData；不把任意物品做持久序列化。任一步驟失敗都不得留下 mint，且原物必須留在或恢復到原容器。

不合格物品只回傳可理解的 reason code，例如「內含物品」「狀態不符」「今日額度已滿」；不得把 server 的完整安全判定或內部資料送給 client。

### 2.4 玩家固定價刊登

1. 玩家選擇單件物品、輸入正整數價格，看到刊登費、預估成交稅、預估實收、系統價格錨及 custody 類型。
2. 第一版預設使用交易站 custody：物品留在本 MOD 註冊的世界容器，server 記錄 bounded `itemRef` 並把該物品鎖為不可由市場以外流程領走；全服目錄只公布安全的商品投影。買家須到場使容器可載入，成交前 server 依 item ID 重查同一實體與狀態。
3. 中央託管 custody 只接受「可重建物品白名單」；server 只擷取 type、condition、uses、fluid 與有限 ModData 等經實測可無損重建的欄位。未知類型、容器內容物或超出上限的狀態拒絕刊登。
4. server 重查物品、刊登配額、價格 hard cap 與費用餘額。刊登費不建立持久 reservation；custody 與 listing 能成立後，才在同一 transaction 以玩家 posting 與 `SYSTEM_BURN` posting 扣除固定整數費用。建立失敗不產生任何費用 posting。
5. 買家購買時，server 依固定順序處理 listing 與雙方錢包並重查 revision；買家支付 `price`，賣家取得 `price - tax`。第一版稅額為 `tax = max(minTax, ceilDivPositive(price * taxRateBps, 10000))`，全部使用有上限的非負整數；若 `tax >= price` 則拒絕成交。稅額直接進 `SYSTEM_BURN`。交易站模式在同一 server tick 移轉世界物品；中央託管模式建立 `DeliveryClaim`。
6. 玩家取消已啟用 listing 時刊登費不退；因系統錯誤或管理員非懲罰性移除而補償時，另寫補償 transaction，不改寫原帳。

同帳號自買一律拒絕，避免污染 GMV 與價格中位數；但不得把此規則當作防洗交易主防線。玩家成交不產生額外獎勵，因此跨帳號洗交易只會消耗費用與稅，不會製造新幣。

### 2.5 拍賣

1. 賣家設定起標價與允許的時長，看到拍賣費及成交稅預覽。
2. 第一版拍賣只接受中央託管的可重建白名單；物品成功進 escrow 後才轉為 `ACTIVE`。交易站物品不進拍賣，避免到期時 chunk 未載入而無法履約。
3. 賣家不得對自己的拍賣出價。`minIncrement` 是 bounded 正整數；第一筆出價須 `newBid >= startPrice`，已有最高價後須 `newBid >= highestBid + minIncrement`，同價或較低價直接拒絕。出價者必須有足額 `availableBalance`；同一 bidder 加價只把 reserve 補到新價所需的正差額，不重複 reserve 全額，也不因較低輸入 release。
4. 不同 bidder 成為最高價時，新 bidder 的全額 reserve 與舊 bidder 的全額 release 必須在同一 transaction 內成立；兩個相同有效出價競爭同一舊 revision 時，以 server 單調序號先處理者勝，後處理者因不再滿足最小加價而拒絕。
5. 到期後 server 以持久 `expiresAt` 進入 `SETTLING`；有得標者則從 reserve 結算，無出價則進歸還流程。到期檢查由節流的 `OnTickEvenPaused` 執行，空服期間仍依 `getTimestampMs()` 前進。
6. restart 後補掃未完成拍賣；同一 `settle:<auctionId>` 最多成功一次。

第一版不做最後一刻自動延長。倒數只是 UI 投影，server timestamp 與持久狀態才是權威。

### 2.6 收件匣、離線與背包滿

系統商店購買、中央託管固定價成交、拍賣得標及中央託管歸還都先落為持久 `DeliveryClaim`。玩家離線、背包滿或 client 中斷時，物品留在收件匣，不以地面掉落補救。領取動作有自己的 request ID，重送只回既有結果。

交易站成交不建立重建型 claim：買家到場後由 server 從交易站容器把原物移轉到買家可接受的容器，賣家可離線收款。若目標容器不可用，整筆不成交。若中央託管的物品 round-trip 無法證明無損且同一 claim 不會重複產物，停用中央託管與拍賣，但不連帶關閉已通過世界容器轉移驗證的交易站市場。系統收購只銷毀已重查的原物，不以 snapshot 重建，因此另以「同一 tick 移除與 mint 不可分離」作 production gate。

### 2.7 可選維護費

管理員可啟用安全屋服務費或車輛服務費，但預設關閉：

- 每個資產與週期只建立一筆 assessment。
- UI 至少提前一個 grace period 顯示到期日、金額、付款帳號與不足額結果。
- 餘額不足不得變負數；狀態進入 `DELINQUENT`，再依設定進入 `GRACE`／`SUSPENDED`。
- 欠費只停用本 MOD 提供的額外經濟服務，不刪除、損壞或取消原生資產。
- 所有權轉移、資產消失與離線扣款語意在 API 未查證前不啟用自動收費。

## 3. UI wireframe（ASCII）

### 3.1 玩家經濟中心

```text
┌──────────────────────────────────────────────────────────────────────────────┐
│ 經濟中心   交易幣 12,340（可用 11,840／保留 500）  社群幣 180  [收件匣 2] [×] │
├──────────────┬──────────────────────────────────────────┬────────────────────┤
│ > 系統商店   │ 搜尋：[____________] 分類：[全部▼]       │ 物品詳情           │
│   玩家刊登   │ 今日：第 184 日  Catalog r27             │ 罐頭食品           │
│   拍賣       ├──────────────────────────────────────────┤ 狀態：標準／未開封 │
│   我的交易   │ 名稱       你支付   你取得   今日剩餘    │ 系統售價：40       │
│   收件匣 (2) │ 罐頭食品      40       18      買 3／賣 5 │ 系統收購：18       │
│   獎勵       │ 手電筒       120       --      買 1       │ 玩家中位價：37     │
│              │ 繃帶           8        3      買 8／賣 8 │                    │
│              │                                          │ 數量 [-] 1 [+]     │
│              │                                          │ 你支付：40         │
│              │                                          │ [向系統購買]       │
│              │                                          │ [把選取物賣給系統] │
├──────────────┴──────────────────────────────────────────┴────────────────────┤
│ 同步：已更新  Quote 到期：00:18  今日配額依 server 計算  最近收據：7F3A2C     │
└──────────────────────────────────────────────────────────────────────────────┘
```

頁籤切到「玩家刊登」時，中間欄改顯示賣家、價格、custody（交易站／中央託管）、到場需求、狀態與刊登時間；右側同時顯示 system bid／ask 作參考，但「購買玩家商品」仍走 `PlayerListingService`。建立刊登時預設選取已註冊交易站；只有白名單物品才顯示中央託管選項。切到「拍賣」時顯示目前最高價、已保留金額與 server 到期時間，不把拍賣 row 混進固定價清單。

### 3.2 管理員經濟儀表板

```text
┌──────────────────────────────────────────────────────────────────────────────┐
│ 經濟儀表板  [今日▼]  Config r27  Catalog r27  守恆差額：0  [緊急停止收購]     │
├─────────────────────┬─────────────────────┬──────────────────────────────────┤
│ 交易幣總供給        │ 今日流量            │ 價格錨／市場                     │
│ 可用      2,410,000 │ Mint       +84,200  │ 系統收購 mint   61,000           │
│ 保留         92,000 │ Burn       -73,900  │ 系統售出 burn   42,800           │
│ 合計      2,502,000 │ Net        +10,300  │ 玩家刊登 GMV    95,400（transfer）│
├─────────────────────┴─────────────────────┼──────────────────────────────────┤
│ Mint：收購／獎勵／Discord／管理／補償     │ 告警                             │
│ Burn：系統售出／刊登費／稅／維護／管理    │ [!] SKU 收購額度 82%             │
│ Quota：帳號／SKU／分類／全服使用率         │ [!] 最老 pending delivery 11 分  │
├───────────────────────────────────────────┴──────────────────────────────────┤
│ SKU        售出量  收購量  Mint  Burn  玩家中位價  錨區間  套利稽核狀態      │
│ 罐頭食品       87      31   558  3480      37       18–40   有效              │
└──────────────────────────────────────────────────────────────────────────────┘
```

### 3.3 UI 行為 contract

- 金額、幣別、狀態與警示不得只靠顏色區分；所有主要動作都顯示「你支付／你取得」。
- 搜尋框每次 `prerender` 比對目前文字，涵蓋中文 IME 組字、貼上與刪除，不只依賴 `onTextChange`；原版每幀讀文字用例見 `MapSpawnSelect.lua:661-665`。
- 經濟視窗不使用 `alwaysOnTop`；該層級每幀被移到繪製尾端：`UIManager.java:544-559`，會蓋住後開 modal。ESC、世界地圖及 modal 應自然顯示在其上方。
- 關窗即取消市場訂閱；隱藏狀態不做高頻清單更新。
- 必備狀態：loading、empty、stale quote、insufficient funds、quota exhausted、disabled、pending delivery、server recovery、protocol mismatch。
- 設定改變不在確認畫面靜默換價；server 回 `STALE_CATALOG` 後要求重新確認。
- 管理員 UI 修改設定必填 reason，顯示 before／after、預估近七日 mint／burn 影響及生效日。

## 4. Server 規則與狀態機

### 4.1 權威與命令封套

headless dedicated server 的 server Lua 是唯一寫入者；單人與 co-op host 不在支援範圍，也不得提供 client-side 或本機權威 fallback。client 只能提交：

```text
protocolVersion
requestId
operation
expectedRevision
payload（僅 ID、數量與玩家選項）
```

server 必須自行推導 actor、`accountKey`、role、價格、稅、配額、餘額、物品狀態與目前 revision。此部署的 `accountKey` 固定採 server-side `player:getUsername()`；不得接受 client 自報 username、SteamID 或 account。相同 `requestId` 搭配相同 payload 回同一 receipt；相同 `requestId` 搭配不同 payload 回 `IDEMPOTENCY_CONFLICT`。所有 idempotency result、request size、字串、數量、頁碼與頻率都有 hard cap。

正常 UI 回應包含 `requestId`、typed result、最新 revision、餘額投影及短交易碼，並只定向送給原請求連線。這是最小揭露與頻寬規則，不是機密性保證：本方案選用的 Global ModData 可被任何已登入 client 以可猜 tag 主動要求整表，接受此取捨的條件見 §5.1 與 §6.1。

### 4.2 Transaction 邊界

Lua 主迴圈雖是單執行緒，domain 仍以固定讀寫順序避免回呼重入或日後模組拆分造成不一致：

```text
config/catalog revision
asset、SKU quota 或 custody record
listing/auction/maintenance object
wallet account keys（排序後）與 reservation
delivery claim、receipt、daily aggregate
```

驗證、`Transaction + Posting[]`、物品移轉、quota、reservation、receipt、daily aggregate、Global ModData 更新、`meta.seq` 遞增與同 `seq` 的 `pendingExport`，必須在同一個本 MOD mutation callback 內完成；任一前置條件失敗時不寫任何 domain 狀態。每種貨幣的 postings 必須在 commit 前先驗證總和為 0。commit 後 exporter 嘗試把該事件 append 為一行 NDJSON 內容；local append **永遠不視為 ACK**。`pendingExport` 只有在 companion 已 durable ingest 並回報最高連續 `exportAckSeq` 後才可清除；沒有 ACK 就保留並重送，重複行由 `seq` 去重。主迴圈不得等待 companion、資料庫或網路回覆。

Global ModData 是遊戲內權威，會在 dedicated 世界存檔流程中與 chunk／玩家資料同一輪但**依序**寫入；玩家資料另有獨立存檔時機，因此它不提供跨檔案或跨 PZ 與外部帳本的 ACID transaction。單執行緒 tick 只保證執行期沒有兩筆經濟 mutation 同時交錯，不能保證 crash 時錢包、世界容器與玩家背包一起落盤或一起回滾。server 重啟時發出 `server.started{loadedSeq}`，companion 將高於 `loadedSeq` 且未通過存檔水位的外部事件標為 `rolled_back`；另以 listing／claim／物品重現對帳偵測部分持久化，鎖入 `RECOVERY_LOCKED` 後人工補償。外部通知、Discord `fulfilled` 與其他不可逆副作用只能在事件通過存檔水位後執行。

拍賣到期、`economicDayKey` 日切、維護費 due queue 與 Discord inbox 輪詢一律以 `getTimestampMs()` 為時鐘，掛在節流的 `OnTickEvenPaused`；不能依賴空服時會停止的 `OnTick` 或 `EveryOneMinute`。

### 4.3 系統購買狀態機

```text
RECEIVED -> VALIDATED -> PREPARED -> COMMITTED -> DELIVERY_PENDING -> DELIVERED
     |          |           |
     +----------+-----------+-------------------------------> REJECTED
```

`COMMITTED` 的不變條件：同一筆 transaction 已完成 `burn`、購買 quota 計數、ledger 與持久 `DeliveryClaim`。實體背包交付可以重試，但不能再次扣款。緊急停用只阻擋尚未 `COMMITTED` 的 request；既有 claim 仍須可領。

### 4.4 系統收購狀態機

```text
RECEIVED -> VALIDATED -> PREPARED -> COMMITTING -> COMMITTED
     |          |           |
     +----------+-----------+-------------------------------> REJECTED
```

`PREPARED` 只持有該次回呼內的原物參照，不把任意物品序列化到中央 escrow。`COMMITTING` 在同一 server tick 內移除已重查的原物、建立 `SYSTEM_MINT` 對應 postings、占用 gross mint quota 並更新 Global ModData；物品移除失敗時不得產生 postings，後續 domain 寫入失敗時必須把同一物件恢復到原容器。全服 mint cap 已滿時在 `VALIDATED` 階段拒絕；burn 不會重新開放當日 mint 額度。第一版不做部分接受。

### 4.5 玩家刊登狀態機

```text
交易站：PREPARING -> STALL_BOUND -> ACTIVE -> MATCHING -> SETTLED
           |                         |          +-> MATCH_ABORTED -> ACTIVE
           |                         |          +-> RECOVERY_LOCKED
           |                         +-> CANCEL_PENDING -> CANCELLED
           |                         +-> EXPIRED
           +-> REJECTED

中央：  PREPARING -> ESCROWED -> ACTIVE -> MATCHING -> SETTLED
           |                       |          +-> MATCH_ABORTED -> ACTIVE
           |                       |          +-> RECOVERY_LOCKED
           |                       +-> CANCEL_PENDING -> RETURN_PENDING -> RETURNED
           |                       +-> EXPIRED -------> RETURN_PENDING -> RETURNED
           +-> REJECTED
```

交易站模式只有 server 已重查世界容器內原物、建立 `STALL_BOUND` 關聯、刊登費已 `burn` 且 listing 持久化後才可進 `ACTIVE`；取消或到期只解除關聯，不重建物品。中央託管模式則必須先通過重建白名單並完成 `ESCROWED`，取消或到期才走歸還 claim。同一 revision 最多成功成交一次；只有 `ACTIVE` 可接受取消或到期 transition。`MATCHING` 只能進 `SETTLED`、在確認沒有任何物品或 posting mutation 後經 `MATCH_ABORTED` 回 `ACTIVE`，或進 `RECOVERY_LOCKED`；絕不直接取消或歸還。任何無法判定物品或資金位置的狀態都阻擋後續 mutation，交由管理員查收據。

### 4.6 拍賣狀態機

```text
PREPARING -> ACTIVE -> SETTLING -> SETTLED
                  |          +-> RECOVERY_LOCKED -> ADMIN_RESOLVED
                  +-> EXPIRED_NO_BID -> RETURN_PENDING -> RETURNED
```

- 最高出價者永遠有等額 `reservedBalance`。
- 賣家不可出價；`minIncrement` 為 bounded 正整數；第一筆 `newBid >= startPrice`，後續 `newBid >= highestBid + minIncrement`；同一 bidder 加價只追加 reserve 正差額。
- 不同 bidder 超標時，新 reserve 與舊 reserve release 必須同一 transaction 成功或全部失敗；競爭同一 revision 時以 server `seq` 先到者勝，後到同價拒絕。
- 一旦進 `SETTLING` 不可回到 `ACTIVE`。
- `settle:<auctionId>` exactly once；可重試的暫時錯誤留在 `SETTLING`，不建立第二份結算。escrow、最高價或 reservation invariant 已損壞時改進 `RECOVERY_LOCKED`，不得無限自動重試。
- `RECOVERY_LOCKED` 只能由具權限管理員以 reason＋request ID 執行一次：完成原 settlement，或 release reserve＋歸還 escrow；缺錢／缺物時另做補償 transaction／claim。處理後進 `ADMIN_RESOLVED` 或 `SETTLED`，永久消耗原 settle key，不能回 `ACTIVE` 或再次結算。
- `OnTickEvenPaused` 依持久 `expiresAt` 補結算，server restart 後同樣適用，不依 client 倒數。

### 4.7 維護費狀態機

```text
NOT_DUE -> DUE -> CHARGED
                 |
                 +-> DELINQUENT -> GRACE -> SUSPENDED
```

correlation key 為 `maintenance:<kind>:<objectKey>:<periodKey>`。同一資產同一週期最多扣一次；不足額不部分扣款、不造成負餘額。所有權轉移或把餘額改為 reserved 不得抹除已成立 liability。資產識別、付款責任與原生效果尚未查證，所以此狀態機是 feature-gated domain contract，不是已確認可呼叫的 PZ 行為。

### 4.8 設定變更

- 一般價格、稅率與配額變更於下一個 `economicDayKey` 生效，避免日中改價造成爭議。
- `enabled=false`、全服收購 kill switch 與安全熔斷可立即生效。
- 設定以單一新 revision 原子套用，不能部分更新；所有修改必填 reason 並保留 before／after。
- 固定價 listing 與 auction 建立時 pin `configRevision`、固定刊登費、`minTax` 與 `taxRateBps`；跨日成交仍用該 revision，讓賣家預估實收不被追溯改寫。系統商店則在提交時重查當日 catalog revision。
- config 驗證 `0 <= taxRateBps < 10000`，固定費用與 `minTax` 都是 bounded 非負整數，且對允許的最低成交價必須保持 `tax < gross`；不合法 revision 整份拒絕。
- schema migration、供給守恆或 catalog 驗證失敗時，停止新的經濟 mutation，保留資料與查詢能力。

## 5. 防濫用與安全

### 5.1 信任邊界

- client 提供的 actor、admin flag、價格、餘額、稅、物品名稱、狀態、snapshot、reward amount 一律不可信。
- server handler 從連線所屬 player 重新推導 account，依 item ID 在允許的 server-side 玩家 inventory 或已註冊交易站容器重查物品。
- 所有 mutating command 檢查 protocol、schema、request ID、payload hash、revision、權限、rate limit 與 domain state。
- **本方案明確接受 Global ModData 對所有已登入玩家可讀**，以換取它參與世界存檔輪次的優點；餘額、目前 listing／auction／quota 與白名單 escrow snapshot 都視為可能被讀取。若產品不能接受玩家餘額可被擷取，必須停在 prototype，改採 server-private journal＋snapshot 並重新設計 crash 一致性，不能假裝 tag 是秘密。
- Global ModData 不放 Discord／Steam 識別、權限憑證、管理員註記、完整交易歷史、任意 item ModData 或其他秘密；永久 exchange tombstone 只存不含個資的 opaque order token、payload hash 與結果。正常 client UI 仍只取得本人 bounded projection，但這只是介面與效能邊界。
- 本 MOD 不接受 client `transmit` 作經濟寫入，也不以 `OnReceiveGlobalModData` 覆寫權威表；每筆 mutation 前比對目前 table 與 server 持有的權威參照，發現被其他 handler 替換即回復參照、記錄安全事件並 fail closed。
- 持久表、每筆 snapshot 與公開索引皆有 hard cap；表大小接近 cap 時停止新刊登／拍賣，避免登入玩家反覆 request 大表形成序列化與頻寬放大。
- 管理員能力在 server 端驗證；只隱藏 client 按鈕不構成授權。

### 5.2 世界掠奪與無限套利規則

世界 loot、補貨、農業、覓食、殭屍掉落與其他 MOD 物資的邊際貨幣成本可能是 0。任何正數 `bidPrice` 都是刻意的 faucet，不能只靠 `bidPrice < askPrice` 宣稱安全。本方案的強保證是：**即使玩家能無限取得某個世界物資，任一帳號與全服在單一 economic day 可由系統收購 mint 的金額仍有有限上限。**

每個可收購 SKU 必須同時具備：

- exact full type 與 canonical item state allowlist；未知狀態拒絕。
- 每帳號／SKU 每日回收數量 cap。
- 每帳號／分類每日 payout cap。
- 每帳號全部收購每日 payout cap。
- 每 SKU／分類全服每日 payout cap。
- 全服系統收購每日 mint cap 與可立即啟用的 kill switch。

以上 cap 全是有限正整數，不允許 `0 = unlimited`。配額檢查、占用、原物移除、postings 與 payout 必須走同一交易邊界；不足時整筆拒絕且物品留在玩家端。

以下物品預設不可收購，直到個別 valuation、同步與 round-trip 測試通過：

- 內含物品的容器。
- fluid、fuel、drainable、battery 或其他可充填狀態。
- 可拆解、修理、充電、分割或合併後改變總估值的物品。
- 含未知或無界 ModData 的物品。
- 無法由 server 建立 canonical state 的第三方 MOD 物品。

每次 catalog 或已載入 MOD 集合改變，都使相關套利稽核失效；受影響 SKU 的 `sellToSystemEnabled` 必須自動關閉，直到重新審核。可靠取得載入 MOD 集合與產生穩定 fingerprint 的 PZ API 仍為「待查證」；未通過前以管理員明示 revision 變更觸發停收。

### 5.3 跨 SKU 轉換環路

至少審核：立即回售、拆解、副產品、返還容器、製作、修理、充填、充電、stack split／merge，以及可重複工具。規則分兩類，不能把世界 faucet 誤當成系統商店套利：

- **只要含任何系統商店投入、可重複閉合回貨幣的環路**：一律歸本類，即使同時含世界材料；世界共同投入的貨幣成本以 0 計。所有輸出回售後不得取得正收益。對每條已支援轉換 `c`：

```text
Σ bidPrice(所有輸出、副產品與返還物)
<=
Σ askPrice(所有真正被消耗的系統輸入) - safetyMargin
```

- **完全不含任何系統商店投入的純世界來源／轉換**：允許管理員刻意設定正 `bidPrice` 作為 faucet，但所有 payout 都計入 account／SKU／分類／全服的 gross daily mint cap；burn 不重開額度。它不能被宣稱為零收益，只能被宣稱為「單日總發行量有硬上限」。

可重複工具不能每次都算完整成本；應視為零邊際成本或只計實際耐久耗損。任何含系統商店投入的閉合環路若無法證明不為正，就關閉輸出物的系統收購；純世界來源則依 allowlist、估值與 gross cap 決定是否保留 faucet。

不得依賴以下弱防線：

- item origin stamp：轉手、重建或其他 MOD 可使 provenance 失真，且不應在 item ModData 寫入高基數交易 ID。
- 禁止自買／自投標：無法阻止分身、地面轉移或第三方帳號。
- 強迫玩家刊登價落在 bid／ask 內：只能改善提示，不能阻止世界物資 faucet。

### 5.4 財務 invariant

```text
circulatingSupply = Σ playerAvailable + Σ playerReserved
closingSupply = openingSupply + mint - burn
conservationGap = closingSupply - openingSupply - mint + burn = 0
```

- reserve／release 與玩家間 transfer 不改變總供給。
- 每筆 transaction 對每種貨幣的 `sum(postings.amount)` 必須為 0；mint 與 burn 只能透過 system account 表示。
- `SYSTEM_MINT`／`SYSTEM_BURN` 是不可支出、免玩家 wallet cap 的 control accounts，只供 postings 守恆與 gross flow 對帳，永遠排除於 circulating supply；只有歸屬玩家的 available／reserved bucket 計入供給。
- 餘額永不為負，也不超過 bounded cap。
- 所有金額、價格、費用、稅率 basis points、乘積與稅後實收都在精確整數範圍內。
- 有效成交須保持 `0 <= tax < gross`，賣家淨額至少為 1。
- 每筆 mint、burn、transfer、reserve、release 都有唯一 tx ID、reason code 與 correlation ID。
- 玩家市場與拍賣不得因成交量另發獎勵；wash trade 只能 burn，不能 mint。

### 5.5 費用、稅與維護沉點

- 核心沉點：玩家刊登費、拍賣刊登費、固定價成交稅、拍賣成交稅。
- 第一版兩種刊登費都是依 custody／市場類型設定的固定 bounded 整數，不使用百分比；只在交易站關聯或中央 escrow custody 成功且狀態進 `ACTIVE` 的同一 transaction 內 burn，建立失敗不得收費，也不建立持久 reservation。
- 固定價與拍賣成交稅共用 `tax = max(minTax, ceilDivPositive(gross * taxRateBps, 10000))`；`ceilDivPositive` 是正整數向上除法，乘積必須低於精確整數上限。只有 settlement 成功才 burn，且 `tax >= gross` 時整筆拒絕。
- 費率使用 listing／auction 建立時 pin 的 `configRevision`，取消時刊登費不退；管理員補償以新 transaction 表示。
- 安全屋／車輛維護費預設關閉；啟用前需 stable identity、owner、轉移、消失與離線語意證據。
- 欠費不直接傷害或刪除原生資產；只影響本 MOD 額外服務，且有 grace period 與管理員豁免／補償收據。

### 5.6 管理員與稽核

- catalog、費率、caps、feature flags 變更均需管理員 capability、request ID、reason 與 config revision。
- 正 `bidPrice` 若沒有帳號與全服 cap，拒絕儲存；雙向 SKU spread 不合法也拒絕儲存。
- 設定套用前顯示依近期流量估算的 mint／burn 影響；緊急停用不刪除既有交易。
- audit 一次 transaction 一筆彙總；玩家識別與外部身分不顯示在一般 client 或公開面板。
- 對外 log 文字由 server 產生並清理控制字元，不接受 client 提交任意 audit 內容。

## 6. 資料模型

以下是 domain contract，不是已確認可直接照抄的 Kahlua table schema。所有 collection、字串、snapshot、索引、cache 與 retention 都必須 bounded。

| Record | 核心欄位 | 主要 invariant |
|---|---|---|
| `WalletProjection` | `accountKey`, `available{currency}`, `reserved{currency}`, `version` | 由 postings 投影或重建；bounded non-negative integer；reserved 納入玩家持有供給 |
| `Transaction` | `txId`, `seq`, `ts`, `kind`, `correlationId`, `actor`, `postings[]`, `reversalOfTxId?` | append-only；同一交易內每種貨幣 `sum(postings.amount) = 0`；同一 `seq` 只對應一筆 committed mutation |
| `Posting` | `account`, `currency`, `amount`, `bucket`, `reasonCode` | 不可修改；玩家、`SYSTEM_MINT`、`SYSTEM_BURN` 與 `PLAYER_RESERVED` 都是帳戶，不以特殊 delta 繞過守恆 |
| `Reservation` | `reservationId`, `accountKey`, `currency`, `amount`, `auctionId`, `status` | 只供拍賣持久保留；同一 auction、同一 bidder 最多一個 active reservation；release／settle 必須與相對 postings 同一 transaction |
| `IdempotencyResult` | `accountKey`, `requestId`, `payloadHash`, `status`, `receipt`, `expiresAt` | 同 ID 不同 payload 拒絕；bounded retention |
| `EconomyConfigRevision` | `revision`, `effectiveDayKey`, `featureFlags`, `caps`, `fees`, `taxes`, `actor`, `reason` | 原子套用；保留 before／after；不可部分生效 |
| `SystemShopSku` | `skuId`, `fullType`, `canonicalState`, `askPrice`, `bidPrice`, direction flags, account/global caps, `arbitrageAuditHash` | 無庫存數；雙向 spread 合法；稽核過期即停收 |
| `EconomicQuota` | `economicDayKey`, `accountKey?`, `skuId?`, `category?`, buy qty, sell qty, payout, mint | commit 時占用；跨日與 revision 明確 |
| `PlayerListing` | `listingId`, `revision`, `sellerKey`, `status`, `price`, `custody`, `itemRef?`, `itemSnapshot?`, `configRevision`, timestamps | `custody` 只可為 `stall`／`escrow`；server-only transition；單件；同 revision 最多成交一次 |
| `Auction` | `auctionId`, `listingId`, `revision`, `sellerKey`, `status`, `startPrice`, `highestBid`, `highestBidder`, `reservationId`, `expiresAt` | 只接受 escrow 白名單；highest bid 恆有等額 reserve；禁止 self-bid；settle exactly once |
| `StationItemRef` | `stationKey`, `containerRef`, `itemId`, `fullType`, `stateHash`, `lastVerifiedAt` | 不序列化原物；成交時重新定位與比對；chunk 未載入或物品變更即不成交 |
| `EscrowItem` | `escrowId`, `ownerKey`, `sourceKind`, bounded allowlisted snapshot, `state`, `recoveryTxId` | 只保存可重建白名單；不在 active inventory 與 active listing 同時存在 |
| `DeliveryClaim` | `claimId`, `accountKey`, `sourceTxId`, bounded item spec, `status`, attempts | 財務 commit 前建立；實體交付 exactly once |
| `MaintenanceAssessment` | `kind`, `objectKey`, `payerKey`, `periodKey`, `amount`, `status`, grace timestamps | 同資產同週期最多一筆；不造成負餘額 |
| `ExchangeOrder` | `orderId`, `payloadHash`, `accountKey`, `currency`, `amount`, `status`, `creditSeq`, `expiresAt` | 永久 tombstone；同 ID 同 hash 回原結果，不同 hash 為 conflict；通過存檔水位後才可對外 fulfilled |
| `PendingExport` | `seq`, `eventType`, bounded event payload, `status`, attempts | 與 domain commit 同時進 Global ModData；只有 companion durable ACK 的連續 `exportAckSeq` 可清除，local append 不算成功證據；達 hard cap 時停止新 mutation |
| `EconomyDailyAggregate` | `dayKey`, currency, reason/SKU/category counters, opening/closing supply, mint, burn, GMV | 可由 ledger 重算；儀表板不掃永久 ledger |

Posting 符號固定：系統收購 100 單位時，玩家帳戶 `+100`、`SYSTEM_MINT -100`；玩家向商店支付 100 時，玩家帳戶 `-100`、`SYSTEM_BURN +100`。玩家成交 100、稅 5 時，買家 `-100`、賣家 `+95`、`SYSTEM_BURN +5`。Reserve 是玩家 `available` 子帳戶轉入 `PLAYER_RESERVED:<accountKey>`，不改變貨幣供給。管理員調整與退款也只能新增補償 transaction，不能改寫舊 posting。

### 6.1 資料分層

- **遊戲內權威狀態**：Global ModData 保存 `schemaVersion`、單調 `seq`、wallet projection、config revision、catalog、quota、listing、auction、reservation、allowlisted escrow／claim、maintenance、compact exchange tombstone、recent receipt、pending export 與 aggregate；只有 server Lua 的 domain path 可寫。引擎允許任何登入玩家依 tag 要求整表，所以這一層一律當作公開可讀，不放秘密或完整歷史，並以 serialized-size hard cap 控制 request 放大。
- **事件流**：每筆 committed mutation 產生一筆 bounded NDJSON 內容，至少含 `seq`、timestamp、type、correlation ID、actor、postings 與必要的 domain 摘要。實際檔名固定使用 `getFileWriter` 允許的 `.json` 副檔名；**不得**使用 `.ndjson` 副檔名。commit 同時把事件放入 bounded `pendingExport`；exporter 以 append 模式逐行寫出並 close。只有 writer 為 `nil` 可被 Lua 立即確認；底層 writer 未暴露 post-open error 查詢，故 write／close 回來也不能清 queue。companion durable ingest 後以 inbox ACK 回報最高連續 `exportAckSeq`，server 才清除該範圍；無 ACK 一律重送，companion 以 `seq` 去重。ACK/readback 未完成實測前，外部帳本與 Discord 都不能進 production。
- **外部帳本**：companion 依事件流寫 PostgreSQL，保存完整交易歷史、查詢投影、統計與 durable watermark；Lua 不直寫資料庫，tick 也不等待資料庫 commit。外部帳本是整合、對帳及災難復原來源，不是即時遊戲餘額的同步 SSOT。
- **短生命週期 server state**：locks、active subscriber、quote cache、rate-limit bucket、pending push。
- **client view**：只讀分頁、該玩家錢包投影、剩餘配額、公開商品資料、receipt 與 claim 摘要。

持久資料有 `schemaVersion`。migration 失敗時保留原資料、停止 mutation，不得自動重建空錢包。Item ModData 不寫 listing ID、tx ID、時間戳、帳號或來源標記；custody 關聯只存在 server state。companion 或 PostgreSQL 停機時，核心商店與市場照常以 Global ModData 運作、事件流持續累積；若 `pendingExport` 達 hard cap，新的 mutation 必須停用。Discord 兌換維持 pending，恢復後依 `seq` 補處理。

### 6.2 Quote 與 revision

每筆 quote 至少包含：

```text
skuId
canonicalStateHash
askPrice / bidPrice
catalogRevision
economicDayKey
remainingAccountQuota
requestExpiry
```

quote 只是顯示與確認資料，不保留價格權威。提交時 server 再讀 catalog；revision、day key 或 expiry 不一致就拒絕，不套用新價。

## 7. 效能

### 7.1 Runtime 策略

- Wallet、SKU、quota、idempotency 與 tx receipt 以 key lookup 為主，避免每筆交易掃描全部帳號或 catalog。
- 玩家刊登與拍賣採 bounded page size、server-side 索引與 revision；搜尋字串、排序欄位、頁碼及結果數皆有限制。
- 只對已開啟經濟中心的 active subscriber 推送市場 revision；關窗退訂，burst mutation 在短窗口合併。
- 正常 UI 的個人錢包、ledger 與 quota 使用定向 bounded response；但 Global ModData 仍視為已登入玩家可主動要求的公開資料，不以「未主動廣播」當隱私控制。
- auction、日切、inbox、claim、maintenance 與 recovery 採 due queue／bounded batch；`OnTickEvenPaused` 只在節流期限到時執行固定上限工作，不在約 10 Hz 的每個回呼全掃 record 或世界資產。
- 每筆 mutation 最多 append 一行有大小上限的 NDJSON 內容，檔名使用允許的 `.json` 副檔名並立即 close；writer 為 `nil` 時記告警，post-open I/O 成功與否不可由現有 Lua writer 證明，所以所有事件都保留到 companion durable ACK。不在主迴圈讀回事件流、查 PostgreSQL、等待 companion 或做同步網路 I/O。companion 以 checkpoint 續讀並可落後追趕。
- Global ModData 的 `seq` 與該表內 domain state 一起進入世界存檔輪次，但玩家背包／世界容器可能在其他步驟或時機落盤，並非 atomic；外部副作用等待 durable watermark。不得把 dirty flag、NDJSON 已寫出或外部資料庫已收到誤稱為遊戲內即時 durability。
- audit 一次 transaction 一行，不逐 item field 寫 log；永久 ledger 與短期 UI audit preview 分離。
- idempotency、recent receipt、notification、subscriber、quote 與 error sample 全部有 retention cap；Discord `orderId` tombstone 是防重放例外，必須永久保存 compact key＋hash＋結果。

### 7.2 經濟平衡儀表板

儀表板在 transaction commit 時增量更新 bounded daily aggregates；開啟面板時不得重掃永久 ledger。每種貨幣提供「今日／7 日／30 日」：

| 指標 | 用途 |
|---|---|
| opening／closing supply、available／reserved | 供給基線與拍賣負債 |
| gross mint、gross burn、net issuance | 同時看見大額流入與流出，不被淨額掩蓋 |
| mint by reason | 系統收購、獎勵、Discord、管理、補償 |
| burn by reason | 系統售出、刊登費、拍賣費、稅、維護、管理 |
| system buyback mint／store sale burn by SKU | 找到失衡品項與世界 loot faucet |
| 玩家刊登／拍賣 GMV | 市場活性；明確標為 transfer，不算 mint |
| 玩家成交中位價相對 bid／ask | 檢查價格錨是否有效或配額是否太緊 |
| quota 使用率與拒絕數 | 帳號、SKU、分類與全服 cap 是否成為瓶頸 |
| top 1%／5% 餘額與收購 payout 集中度 | 偵測財富與 faucet 集中，不公開玩家識別 |
| active escrow、reserved bid、pending delivery／return、oldest age | 找卡單與 recovery 壓力 |
| conservation gap | 必須為 0；非 0 立即 fail closed |
| stale quote、idempotency conflict、rate-limit、malformed request | 安全與 UX 診斷 |
| config/catalog revision 與套利稽核狀態 | 將數值變化連回管理員調參 |

立即告警至少包含：

- `conservationGap != 0`。
- 全服系統收購 mint cap 達預警門檻或用盡。
- 近期 `burn / mint` 低於管理員設定門檻。
- pending／settling／return age 超限。
- 單一 SKU 或少數帳號占收購 payout 比例異常。
- catalog 或 MOD 集合變更使 `arbitrageAuditHash` 過期。

### 7.3 驗證負載

效能驗證至少涵蓋：大量 catalog、達刊登 hard cap、拍賣同時到期、所有 active subscriber 同時開窗、收購 cap 熱點、receipt cache 滿載、空服 `OnTickEvenPaused`、事件流 backlog 與 restart recovery。驗收看每 tick 工作上限、單次 payload bytes、Global ModData 體積、每行事件 bytes、合併推送次數及最老 pending age，不只看平均延遲。

## 8. Discord 積分兌換介面

### 8.1 信任方向

Discord 積分系統是外部來源，不擁有遊戲錢包。companion 從外部兌換訂單取得精確的 SteamID64 字串，並以 whitelist 資料庫確認候選 PZ username；server Lua 不把 `getSteamID()` 的 Kahlua number 當身分鍵。**whitelist 不是唯一帳號綁定**：同一 SteamID64 可對應多個 username，因此第一版另維護經使用者或管理員明示確認的 `realm + SteamID64 -> accountKey(username)` 單一 active binding；沒有 binding、多筆 active binding、候選不再存在或發生改名時一律 fail closed，不自行猜選錢包。companion 只能提交「積分已扣除或保留、仍為 pending」的兌換事件；game server 重新驗證 schema、帳戶、金額、期限、限額與冪等狀態後，仍透過同一 `TransactionCoordinator` credit 社群幣。

入站 transport 已定為 companion 寫本機 inbox 檔、server Lua 以節流的 `OnTickEvenPaused` 輪詢；不使用 HTTP listener 或 RCON 直接呼叫 Lua。companion 是 Discord 兌換與外部帳本的必要元件，但不是核心市場的同步依賴：它停機時市場照常運作，兌換維持 pending。檔案 API 在目標 dedicated 環境的權限、效能與故障行為仍是「待查證」production gate。

### 8.2 外部事件封套

| 欄位 | 規則 |
|---|---|
| `protocolVersion` | 未知版本 fail closed |
| `orderId` | 全域唯一；永久 tombstone 與 `discord:<orderId>` correlation key |
| `payloadHash` | 對 canonical payload 計算；相同 `orderId` 不同 hash 永久拒絕為 conflict |
| `accountKey` | companion 由已確認的單一 active binding 取得 username，並再次確認仍存在於 whitelist；不接受遊戲 client 自報，也不在多個候選中猜測 |
| `attemptId` | 每次傳輸嘗試的可選追蹤 ID；不參與入帳冪等判定 |
| `sourcePoints` | 外部扣除／保留的正整數積分 |
| `currency`／`amount` | 第一版只允許 server 設定的社群幣與正整數；匯率、單筆與每日 cap 由 server 重算或驗證 |
| `issuedAt`／`expiresAt` | 過期事件拒絕；時間來源與容忍窗由 server 設定 |
| `metadataVersion` | bounded allowlist；不接收任意 nested payload |

### 8.3 兌換狀態機

```text
外部：PENDING -> INBOX_WRITTEN -> CREDIT_OBSERVED -> DURABLE -> FULFILLED
          |               |
          |               +---- timeout / restart ----> PENDING（同 orderId 重送）
          +-------------------------------------------> FAILED -> REFUNDED

遊戲：RECEIVED -> VALIDATED -> CREDITED_PENDING_SAVE
          |            |
          +------------+------------------------------> REJECTED
          +-- same orderId, different payloadHash ---> CONFLICT
```

game server credit、永久 tombstone、`creditSeq` 與 `exchange.fulfilled` 事件在同一 transaction 建立；相同 `orderId`＋hash 重送回原 receipt，不再次 credit。companion 觀察到事件後仍不得立刻把外部訂單標為 fulfilled，必須等 `creditSeq` 通過存檔水位。若 server 崩潰回到較低 `loadedSeq`，companion 將較新的未 durable 事件標為 rolled back，訂單回到 pending 並以同一 `orderId` 重送。

逾時、ACK 遺失或 companion restart 一律維持 pending，不能推定失敗或換新 `orderId`。只有 server 明確拒絕的訂單才進 failed／refund。已 fulfilled 訂單的取消或退款必須先在遊戲內完成連結原 transaction 的反向補償 posting；餘額不足、`cancel`／`reverse` 的期限與人工處理規則仍是產品 contract「待查證／待定義」，不得直接在外部改狀態造成雙邊分岔。

### 8.4 與交易幣的關係

- Discord 兌換預設只增加社群幣。
- 沒有明確社群幣消費 catalog 前，不對玩家開放正式兌換。
- 若啟用社群幣 → 交易幣，使用獨立 server-side operation：同一 transaction `burn` 社群幣、`mint` 交易幣，套用每帳號每日、全服每日、匯率與餘額 cap。
- 不允許交易幣或社群幣反向換回 Discord 積分，也不允許社群幣進玩家刊登或拍賣。
- 儀表板將 Discord credit 與跨幣別 conversion 分開列示，不與玩家 GMV 混合。

### 8.5 隱私與管理

一般 client 只看到自己的 link 狀態、金額、短交易碼與結果；不顯示完整 Discord 識別、SteamID64、payload hash、認證資訊或其他帳號。綁定建立、改名、撤銷與帳號合併流程在 production 前必須定義並實測；未完成時 Discord credit 保持關閉。管理員可依 tx ID／order ID 查 server receipt、停用新兌換及做有 reason 的補償，但不能改寫或刪除原始 external transaction 歷史。companion 與 PostgreSQL 只能讀取必要欄位；事件流與一般 log 不輸出 Discord 顯示名稱或其他非必要個資。

## 9. 實作複雜度與風險

### 9.1 分階段實作

| 階段 | 範圍 | 退出 gate |
|---|---|---|
| 0. Dedicated 可行性原型 | username account key、首幀 command、`OnTickEvenPaused`、Global ModData＋`seq`、NDJSON、交易站原物移轉、白名單重建、inbox 輪詢 | headless dedicated＋兩個獨立遠端 client、空服、restart、背包滿、chunk 未載入與第三方物品矩陣有可重現證據 |
| 1. 錢包與帳本 | 雙貨幣、available／reserved、`Transaction + Posting[]`、system accounts、idempotency、config、daily aggregate、儀表板 | 每筆每種貨幣 postings 總和為 0；可由帳本重建 projection；retry、回滾對帳與 migration fail closed |
| 2. 系統售出 | 無限庫存 catalog、ask、每日限購、DeliveryClaim、burn | 不重複扣款／交付；stale catalog 完整拒絕 |
| 3. 系統收購 | bid、canonical allowlist、同 tick 原物銷毀、分層 gross mint cap、套利稽核、faucet kill switch | 世界 loot 壓測無法突破 daily hard cap；所有拒絕先於移除物品；burn 不重開 mint cap |
| 4. 玩家交易站 | 世界容器 custody、全服目錄、單件 fixed listing、fee、tax、到場成交、離線賣家收款 | 兩名買家競爭、容器／物品變更、chunk 未載入、cancel、expiry、restart 全部 fail closed 且原物不複製 |
| 5. 中央託管刊登 | 可重建物品白名單、bounded snapshot、DeliveryClaim、離線買家 | condition／uses／fluid／有限 ModData 重建矩陣無損；未知類型全拒絕 |
| 6. 拍賣 | escrow 白名單、bid reserve、self-bid 拒絕、outbid release、空服到期結算、無人出價歸還 | concurrent bid、同 bidder 加價與 restart settle exactly once |
| 7. 可選維護費 | 安全屋／車輛 registration、assessment、grace、suspension | stable object／owner API 與轉移、消失、離線情境均已查證 |
| 8. Discord | whitelist 候選驗證、單一 active account binding、inbox、永久 tombstone、社群幣 credit、durable watermark、受控 conversion | 多 username、改名、撤銷、檔案 transport、重放、逾時、rollback、退款／reverse 與 readback 實測完成 |

系統收購不得與系統售出同時作為第一個上線功能：先證明 burn 與 delivery，再單獨打開 faucet，較容易用儀表板看出供給變化。

### 9.2 主要風險

| 風險 | 嚴重度 | 緩解與 stop condition |
|---|---|---|
| Inventory 與錢包同 tick mutation／跨檔案存檔中途失敗 | Critical | 先驗證、固定 mutation 順序、原物參照 rollback、縮短存檔窗口、`seq`＋物品重現對帳與 `RECOVERY_LOCKED` 補償；同輪存檔不是 atomic，無 fail injection 證據即停止相關交易上線 |
| 第三方物品中央 round-trip | Critical | 交易站優先；中央只用 bounded codec／deny-by-default 白名單／實機矩陣；未知類型不託管、不拍賣 |
| 交易站 chunk 或原物不可用 | High | 成交前依 item ID＋state hash 重查；未載入、移動、變更或容器失效一律不扣款 |
| 世界 loot／crafting 正收益環路 | Critical | 多層 cap、全服 kill switch、轉換圖稽核；稽核 stale 即停收 |
| Username 改名或帳號合併 | High | `accountKey` 已定為 server username；改名 migration 與人工合併政策未定前不自動搬移錢包 |
| Discord 分散式 exactly-once | Critical | `orderId`＋hash 永久 tombstone、`creditSeq`、durable watermark、同 ID retry、明確 reverse；檔案流程未實測則 feature off |
| 一個 SteamID64 對應多個 PZ username | Critical | whitelist 只驗證候選；另建 realm-scoped 單一 active binding。缺少、重複、改名或失效時全部 fail closed，不自動選帳戶 |
| 拍賣 reserve／settle 競爭 | High | 固定 lock order、持久 state、重啟補結算、concurrent regression |
| Catalog 改價與舊 quote 競爭 | High | revision／day key／expiry 全重查；不靜默換價 |
| Global ModData 公開讀取與 request 放大 | High | 本方案明確接受餘額／目前狀態可讀；不放秘密或完整歷史、限制表與 snapshot bytes、逼近 cap 即停新增 record。若產品不接受此可見性則停止並改 private storage 架構 |
| 事件流缺行、重複或外部 backlog | High | 允許副檔名、`nil` writer 診斷、持久 `pendingExport`、companion durable ACK、`seq` gap／duplicate 偵測、bounded line、checkpoint；local write 不清 queue，gap 未修復時停外部副作用，queue 滿時停新 mutation |
| 維護費錯認資產或付款人 | High | 預設關閉、explicit registration、grace；不影響原生資產 |
| 經濟數值失衡 | High | reason-split dashboard、預估影響、分日生效、獨立 faucet kill switch |
| UI 資料密度與中文輸入 | Medium | 單一 list view、IME prerender 比對、typed states、解析度實測 |
| Kahlua table／索引記憶體成長 | High | 所有 record、cache、page、snapshot、audit、subscriber 有 hard cap |

### 9.3 必要測試矩陣

- 相同 request 重送、相同 ID 不同 payload、timeout 後 retry、斷線重連。
- headless dedicated server 與兩個獨立遠端 client；client 在 `OnGameStart` 不送 dedicated command，首個 `OnTick` 才送一次。
- 兩名買家搶同一交易站或中央 listing；多名 bidder 同時加價；賣家 self-bid；同 bidder 連續加價；到期瞬間 restart。
- wallet 已變但 claim 未建、交易站物品已移動、物品已移除但 mint 未完成、fee 已 burn 但 custody 未成立的故障注入。
- quote 跨 `economicDayKey`、管理員改價、緊急停用、cap 正好差 1。
- 直接回售、拆解、craft、副產品、返還容器、修理、充填、split／merge 套利環路。
- catalog／MOD 集合變更後套利稽核失效並自動停收。
- 交易站 chunk 未載入、原物被移動／修改、離線賣家、離線得標者、背包滿、claim 重複領取、歸還失敗。
- 每筆 postings 守恆、supply conservation、daily aggregate 重算、schema migration 失敗、資料保持不被清空。
- `PauseEmpty=true` 空服跨日、拍賣到期與 inbox 輪詢；全部由節流 `OnTickEvenPaused` 推進一次。
- server 崩潰回到較低 `loadedSeq`、事件流 duplicate／gap、companion／PostgreSQL 停機與恢復追趕；未 durable 的外部副作用不可成立。
- 在世界容器、玩家背包、Global ModData 各存檔步驟前後強制中止，驗證部分持久化會被對帳鎖住，不會靜默複製物品或重複付款。
- 登入 client 主動要求經濟 Global ModData tag，確認只暴露已接受的目前狀態；以 hard-cap 大小反覆 request 時，server 工作量與封包大小仍在上限內。
- writer 回 `nil`、無法觀測的 append／close 失敗、ACK 遺失、重啟後重送 `pendingExport`、queue 達 hard cap；local write 不清 queue，只有 companion durable ACK 可推進 `exportAckSeq`，不得遺失 seq，重複事件由 companion 去重，滿載後新 mutation fail closed。
- 同一 Discord `orderId` 重送、同 ID 不同 hash、ACK 遺失、credit 後存檔前崩潰、fulfilled 後 reverse。
- 同一 SteamID64 有零個／一個／多個 whitelist username、綁定帳號改名、撤銷後重送與候選消失；只有唯一有效 binding 可入帳。
- 儀表板在 catalog／listing／subscriber 上限下不全掃永久 ledger。

## 10. 待查證 API 清單

本章只列指定 vanilla Lua 與 42.20.4 decompiled snapshot 中可定位的證據。狀態「已找到入口」只代表 API／事件存在，不代表經濟 transaction、崩潰一致性或跨 MOD round-trip 已成立。

### 10.1 已找到入口

| 能力 | 狀態 | 出處與設計限制 |
|---|---|---|
| Client → server command | 已找到入口 | `sendClientCommand(player, ...)`：`LuaManager.java:8908-8924`；server 由 connection 與 player index 重取 actor：`GameServer.java:2247-2270`，再觸發 `OnClientCommand`：`GameServer.java:2292-2298`。經濟命令固定使用帶 player overload；handler 仍須自行完整驗證。 |
| Server → client 定向回應 | 已找到入口 | `sendServerCommand(player, ...)`：`LuaManager.java:8938-8945`、`GameServer.java:3525-3531`；client 觸發 `OnServerCommand`：`GameClient.java:1052-1068`。實際傳輸粒度是該 player 所在 connection；response 仍帶 `requestId` 與 account projection。 |
| Dedicated 帳戶鍵 | 已查證並採用 | `player:getUsername()`：`IsoPlayer.java:6445-6446`；server 在連線流程指派 username：`GameServer.java:2812`。本部署固定以 username 作 `accountKey`。`getSteamID()` 回 Java `long`，Kahlua 轉 Lua `double` 會失去 SteamID64 精度：`IsoPlayer.java:6411-6413`、`KahluaNumberConverter.java:106,140-142`，因此不得作 Lua 帳戶鍵或 Discord 對應。 |
| Server role capability | 已找到入口 | `Role.hasCapability`：`Role.java:176-186`。候選設定權限 `ChangeAndReloadServerOptions`、觀測權限 `GetStatistic`：`Capability.java:80-81,98-103`。不得用 client `isAdmin()` 作授權。 |
| Inventory item 重查／增刪 | 已找到 primitive | `getFullType`／`getID`：`InventoryItem.java:1654-1658,3590-3595`；`AddItem`／`Remove`／`getItemWithID`：`ItemContainer.java:458-532,2032-2093,3083-3092`；原版 server 用例：`ClientCommands.lua:1200-1217`。這些 primitive 不等於原子 escrow。 |
| 物品序列化方法 | 已找到 Java 方法；純 Lua 路徑待查證 | `InventoryItem.save/load` 需要 `ByteBuffer`：`InventoryItem.java:1660-1696,1872-1880,3379-3383`。指定來源尚未找到 Lua 可建立／操作該 `ByteBuffer` 的入口，因此 production 不採純 Lua 完整序列化；世界容器轉移與中央白名單重建仍各自受 §10.2 gate 約束。 |
| 建立物品 | 已找到入口 | `instanceItem(fullType)`：`LuaManager.java:5598-5627`。這只證明能建立基礎物品；canonical state、第三方物品與 exactly-once claim 仍是「待查證」。 |
| Global ModData 持久化與可讀性 | 已找到入口與限制 | `ModData.java:16-49`；init/load/save：`GlobalModData.java:51-55,218-304`；dedicated 存檔依序寫世界、玩家與 Global ModData：`ServerMap.java:373-428,504-515`，不是跨檔案 atomic commit。任何具 `LoginOnServer` 的 client 可依 tag 要求整表：`GlobalModDataRequestPacket.java:11-34`、`GlobalModData.java:153-205`。client `transmit` 的 server parse 會觸發接收事件：`GlobalModDataPacket.java:44-55`；本 MOD 不以該事件接受經濟寫入。 |
| NDJSON 內容／inbox 檔案 primitive | 已找到入口與限制 | `getFileWriter` 只允許 `ini/cfg/txt/log/json`：`LuaManager.java:1034,6729-6764`；`getFileReader`：`LuaManager.java:5933-5963`；writer 的 `write/writeln/close`：`LuaManager.java:12750-12769`。因此出站內容雖是 NDJSON，副檔名固定 `.json`。只有 writer 為 `nil` 可直接判定失敗；post-open error 沒有 `checkError()` 可讀，local write 不可作 ACK，必須保留到 companion durable ACK。 |
| RCON command dispatch | 已找到路徑；其他 inbound 入口待查證 | RCON bridge：`RCONServer.java:319-335`；`CommandBase` dispatch：`GameServer.java:1283-1327`。指定來源未找到可直接觸發本 MOD Lua handler 的既有 RCON command，也未完成所有可能 Java helper 的全域不存在證明；因此「無其他 inbound 通道」仍標記待查證，本設計不依賴該主張，固定使用 inbox 檔。 |
| 真實時間與空服事件 | 已找到入口 | `getTimestampMs()` 回傳系統時間：`LuaManager.java:9259-9272`；dedicated 建立並更新 `IngameState`：`GameServer.java:825-827,1003-1006`；`OnTickEvenPaused` 在 paused gate 前觸發：`IngameState.java:1318,1487-1492`。`OnTick` 與遊戲時間事件受 paused 流程影響：`GameTime.java:181-183,513-514,621-656`、`IngameState.java:1533-1534,1624-1625`。到期、日切與 inbox 採前一組合；節流成本與手動校時行為仍是「待查證」。 |
| Whitelist 身分候選 | 已找到結構；唯一綁定不成立 | whitelist 同時保存 username 與 SteamID 字串：`ServerWorldDatabase.java:57-80`；同一使用者可建立多個帳號：`ServerOptions.java:118`、`ServerWorldDatabase.java:1200-1261`。故 companion 只能用它驗證候選，不可自動假設 SteamID64 唯一對應一個 `accountKey`。 |
| Sandbox 啟動預設 | 已找到入口 | 自訂 sandbox option 載入：`CustomSandboxOptions.java:23-51`；映射 `SandboxVars.Namespace.Option`：`SandboxOptions.java:515-525,1372-1400`。適合 feature flag／啟動預設，不是 runtime catalog 或交易資料庫。 |
| 安全屋查詢 | 已找到部分 accessor | owner/list accessor：`SafeHouse.java:97-119,652-657`。stable object key、轉移與刪除事件仍待查證。 |
| 車輛持久 ID 候選 | 已找到候選 | `BaseVehicle.getSqlId()`：`BaseVehicle.java:455-457`。owner、未載入車輛列舉及轉移語意未找到，不能直接定為維護費資產 key。 |
| UI panel／tab／list／hotkey event | 已找到入口 | 原版 top-level tab panel：`ISItemsListViewer.lua:1-38,87-140`；列表：`ISItemsListTable.lua:70-86`；鍵盤事件：`ISChat.lua:1178`；`prerender` 讀文字：`MapSpawnSelect.lua:661-665`。正式可重綁按鍵 API 待查證。 |
| Audit log | 已找到入口 | `writeLog`：`LuaManager.java:9171-9177`。內容必須由 server 產生、彙總且清理，不接受 client audit 文字。 |

### 10.2 必須標記「待查證」的 production gate

| API／行為 | 狀態 | 未解問題與阻擋範圍 |
|---|---|---|
| Username 改名／帳號合併 migration | **待查證** | `accountKey = username` 已定案；仍未找到自動改名事件與安全合併契約。阻擋自動搬移錢包，不阻擋建立正式 username 錢包。 |
| 不可重用 `characterKey` | **待查證** | 未找到角色生命週期 UUID。市場與錢包不依賴 character key；若做角色型功能，先改用 account-season 或完成角色序號原型。 |
| 純 Lua 完整物品序列化 | **待查證／目前禁用** | 已知 Java save/load 需要 `ByteBuffer`，但指定來源未找到 Lua 可建立相容 buffer 並涵蓋所有子類 override 的入口；不得以 absence 推論永久不可能，也不得在 production 宣稱可用。 |
| 交易站容器原物移轉 | **待查證** | chunk 載入條件、station stable key、container／item 被移動時的重查與網路同步尚未完成實機矩陣；阻擋交易站 production。 |
| 中央託管白名單 round-trip | **待查證** | condition、uses、fluid、drainable、battery、有限 ModData、腐壞與第三方子類逐類驗證；阻擋該類型的中央刊登、拍賣與 claim，不阻擋交易站。 |
| Inventory＋wallet 同 tick 失敗回復 | **待查證** | 未找到 PZ 提供的通用原子 commit／rollback API；需以故障注入證明固定順序與原物 rollback。阻擋系統收購、交易站成交及中央託管 production。 |
| Global ModData durability 邊界 | **待查證** | crash window、容量、nested table、損毀復原及 `seq` 與 state 同輪落盤需實機驗證；不得宣稱即時 durability。 |
| 存檔水位與 rollback 對帳 | **待查證** | dedicated Lua 沒有存檔完成事件；companion 對水位的判定、`server.started{loadedSeq}`、gap／duplicate 與復原流程需故障注入。阻擋所有外部不可逆副作用。 |
| NDJSON／inbox／ACK production 行為 | **待查證** | 檔案權限、append／close 成本、靜默 post-open error、部分行、輪替、backlog、同名 inbox 重送、companion durable ACK/readback 與空服輪詢需在目標 dedicated 環境實測；阻擋外部帳本與 Discord。 |
| Discord SteamID64 → username 綁定生命週期 | **待查證／待定義** | whitelist 可能有多個 username；需明確的單一 active binding 建立、證明、改名、撤銷與合併流程。未完成或候選不唯一時 Discord credit fail closed。 |
| 離線玩家中央交付／歸還 | **待查證** | 沒有在線 inventory 物件時如何安全保存、領取與 exactly-once 重建；阻擋中央託管與拍賣的離線 claim。交易站由世界容器保管原物，不共用此 gate。 |
| Economic day 與停機跨越語意 | **待查證** | 手動校時、長時間停機跨日、空服 CPU 成本與大量 auction 補結算需實測；阻擋正式每日 cap 與到期規則。 |
| 安全屋資產 key／owner lifecycle | **待查證** | 轉移、解散、刪除、多人付款責任與事件；阻擋安全屋維護費。 |
| 車輛 owner／未載入列舉 | **待查證** | 原生 ownership 契約、資產轉移與未載入車輛；阻擋自動車輛維護費，僅可評估 explicit registration。 |
| Craft／拆解／副產品完整圖 | **待查證** | 未找到可直接產生完整經濟轉換 closure 的 API；阻擋自動宣稱無套利，需離線 catalog audit 與人工核可。 |
| 不可偽造 item provenance | **待查證** | 未找到可作經濟安全邊界的 immutable origin；不得靠 item ID 或 ModData stamp 防套利。 |
| Runtime catalog／載入 MOD fingerprint | **待查證** | Sandbox 只適合作預設；catalog revision、before／after、原子套用、持久化與穩定的載入 MOD 集合 fingerprint 需 MOD 自建或另找已驗證入口。 |
| Discord cancel／reverse／退款閉環 | **待查證／待定義** | transport 已決定為 companion＋inbox；仍需完成 fulfilled 後反向補償、餘額不足、人工處理與外部 readback 契約。阻擋正式退款。 |
| 其他外部 inbound Lua 通道 | **待查證** | 已查 RCON 既有 dispatch，未對所有 Java helper／第三方橋接完成全域不存在證明；本設計不使用此假設作安全邊界，仍只允許 companion inbox。 |
| 經濟專屬自訂 capability | **待查證** | 未找到 Workshop MOD 建立新 `Capability` 的正式 API；第一版只能採既有 capability 或另定 server-side allowlist。 |
| 正式可重綁 hotkey API | **待查證** | 已找到 key event，未找到本需求的完整註冊／衝突／持久化契約；阻擋把可重綁宣稱為完成。 |

以上 gate 未完成時，文件中的狀態機仍是必須達成的 contract，不得以未查證的 PZ 呼叫或 client-side fallback 假裝完成。
