# 設計稿 A：中央交易中心＋拍賣場（純 UI 面板）

- 狀態：Draft
- 日期：2026-09-02
- 目標版本：Project Zomboid Build 42.20.4 multiplayer dedicated server
- 非目標：單人模式、玩家面對面交易、世界內交易 NPC／終端機、實體貨幣物品
- 決策依據：[economy-system-analysis.md](../economy-system-analysis.md)
- 證據原則：文中的服務、record 與狀態名稱是本專案 domain contract，不是 PZ API；PZ API 只在有原版 Lua 或指定 42.20.4 反編譯出處時列為已查證

## 1. 概要

本提案將「中央交易中心」設計成一個可在多人 dedicated server 內使用的純 UI 面板。玩家可瀏覽固定價商品、刊登單件物品、購買、進入獨立拍賣頁出價、從離線交付信箱領取物品，並在同一視窗查看錢包、簽到與生存里程碑。管理員另有 server 授權的管理頁。

核心契約如下：

| 領域 | 決策 |
|---|---|
| 權威 | client 只顯示 read-only snapshot 並送出意圖；錢包、物品、價格、費用、稅、權限、狀態轉移與持久化一律由 server 決定 |
| 雙貨幣 | 交易幣是玩家市場唯一報價與結算貨幣；社群幣由 Discord 積分兌換取得，維持 account-bound，不可直接 P2P、刊登或競標 |
| 市場分工 | 固定價與拍賣共用錢包、帳本、escrow、信箱與 UI 外殼，但頁面、command、service 與狀態機完全分離 |
| 物品交付 | 成交、流標、取消、過期與管理員移除產生的物品，一律先進 account-scoped 離線交付信箱，不依賴當事人在線或背包當下可用 |
| 金額 | 全部使用有上下限的整數；client 顯示的餘額、稅額與實收都只是預覽，commit 前由 server 重算 |
| 第一版範圍 | 單件刊登、單一 list view、server-side 分頁、固定價、基本拍賣、信箱、錢包與獎勵、管理頁、中文 IME 搜尋 |
| 延後 | bundle、部分購買、grid view、anti-sniping、自動議價、實體貨幣 deposit／withdraw、玩家檢舉 |

### 開啟位置裁決：任何地點

第一版選擇「玩家在任何地點開啟」，而不是限定在特定建築或世界物件附近。

| 方案 | 優點 | 代價 |
|---|---|---|
| **任何地點（採用）** | 符合純 UI 與非同步交易；不依賴地圖物件、固定座標、距離或可及性 API；不同地圖與存檔較容易相容；離線信箱與遠端競標的心智模型一致 | 交易旅程較少、沉浸感較弱、操作頻率可能較高 |
| **限定地點（不採用）** | 可形成玩家聚點與旅行風險，世界觀更具體 | 需要處理地圖相容性、入口被封鎖、玩家在確認期間移動離場、server 位置重驗與可及性；也會讓離線得標後的領取變得不一致 |

任何地點開窗不提供暫停、無敵、遠端背包寫入或 client 權威。面板開啟期間遊戲照常進行；所有 mutation 仍須經 server 驗證。提高的交易頻率以刊登費、刊登配額、價格上限、mailbox obligation slot、查詢成本上限與分層 rate limit 控制。

### 原創性邊界

本提案只採用一般性的 marketplace domain 概念，設計、文案與資訊架構均獨立建立。不得複製 BONE > Bshop 的程式碼、素材、翻譯、數值、黑市／骨頭／購物車意象、固定入口位置、視覺語言或 Workshop 文案。本介面採「中央帳本／交易所」的中性行政風格，使用頂部分頁與收據式資訊呈現。

## 2. 玩家流程

### 2.1 開啟、同步與關閉

1. 玩家在已進入 multiplayer 遊戲後，以可重綁快捷鍵或本 MOD 自有選單入口開啟視窗。第一版不固定占用 F2，也不放置仿購物車 launcher。
2. client 建立本次 UI session 的 query sequence，送出 protocol handshake、subscribe 與第一頁查詢。
3. server 從實際連線取得 actor，檢查 protocol 與帳號狀態後，回傳：
   - 交易幣 available／reserved；
   - 社群幣餘額；
   - 信箱未領件數；
   - 獎勵狀態；
   - 市場與設定 revision；
   - 當前頁的 bounded rows。
4. 讀取期間保留既有畫面並顯示「同步中」；不得把未完成載入誤畫成 0 餘額或空市場。
5. 關閉視窗時送 unsubscribe，清除 client page cache 與 debounce 工作。若 client 斷線未送出 unsubscribe，server 以 disconnect 或 heartbeat timeout 清除 ephemeral subscription。

帶 player 的 sendClientCommand 只有在 MP client 已進入 ingame 狀態後才走 dedicated 連線；正常由玩家開窗時已符合此條件。若日後做登入自動預抓，不能在 OnGameStart 直接送出，須延後到首個 OnTick。出處：LuaManager.java:8892-8925、IngameState.java:563-565、762-775、1529-1534。

### 2.2 固定價瀏覽與購買

1. 玩家進入「交易中心」，以搜尋、分類、排序與分頁取得 server-filtered 列表。
2. 選取一列後顯示 server snapshot：名稱、full type、賣家顯示名、可支援的狀態摘要、價格、到期時間與 listing revision。
3. 按「購買」後開啟確認對話框，明列支付總額、信箱目前使用量與「物品將送入信箱」。
4. client 送出 listingId、expectedRevision、requestId；不送可信價格、賣家、稅額或 item snapshot。
5. server 依序重查 listing、到期、賣家、買家不可相同、買家 available balance、mailbox slot、escrow 與目前 revision。
6. 成功時 buyer 支付標示價格，seller 取得扣除 sales tax 後的淨額，稅直接 burn，escrow 轉為 buyer 的 READY delivery；離線 seller 也直接由帳本入帳。
7. client 收到 success receipt 後更新錢包與信箱 badge。若是 stale／sold／expired，保留搜尋條件並刷新該頁，不自動改買其他商品。

第一版不做 bundle 與部分數量購買；每個 listing 對應一件 escrow item，能明確保證同一 listing revision 最多成交一次。

### 2.3 固定價刊登與取消

1. 玩家進入「刊登／我的刊登」，要求 server 回傳本次可刊登的 bounded item candidates。
2. client 只顯示 server 回傳的候選；已裝備、手持、非空容器、unsupported codec、被其他流程鎖住或不在 allowlist 的項目不可選。
3. 玩家選一件、輸入正整數價格並查看：
   - 刊登費；
   - 成交後 sales tax 與預估實收；
   - server 設定的到期時間；
   - 目前刊登配額與 mailbox return slot。
4. 確認後 client 送 item request ID、價格、expected inventory revision 與 requestId。item ID 只供本次 server 在該玩家 inventory 重新定位，不成為 durable listing ID。
5. server 重查 ownership、可移除性、item policy、snapshot bounds、價格、配額、刊登費餘額與退件 slot；全部通過後，才在同一 transaction 建立 escrow、扣除並 burn 刊登費、建立 listing。
6. 取消 active 固定價刊登時，刊登費不退，物品轉入 seller 信箱。到期亦同。

若任何一步無法保證物品與帳本的一致性，整筆失敗且不留下扣款或半套 listing。已進入 recovery 的項目不允許玩家重試建立另一筆。

### 2.4 拍賣刊登與出價

拍賣刊登沿用相同 item candidate 與 escrow 檢查，但使用獨立的 auction command。賣家選擇 server allowlist 內的拍賣時長與起標價；第一版不讓 client 輸入任意時長。

出價流程：

1. bidder 選取 auction，UI 顯示目前最高價、最低有效下一標、自己的 available／reserved 與 server 到期時間。
2. bidder 輸入「新的總出價」，而不是增量；確認 dialog 顯示本次需要新增 reserve 的金額。
3. server 在 transaction lock 內先判斷 auction 是否已到期，再驗證 bidder 不是 seller、revision、整數範圍、最低加價、available balance 與 mailbox win slot。
4. 新 bidder 成為最高價時，server 先建立新 bidder 全額 reserve 與 win slot obligation，再在同一 transaction release 舊 bidder 的 reserve 與 slot。
5. 同一 bidder 自己加價時只從 available 轉入差額。
6. 被超標者立即收到 reserve release receipt；不需等待 auction 結束或重新上線。
7. client 倒數只供顯示。最後一刻送達的 bid 以 server lock 內的 expiresAtMs 判定，不以 client 畫面時間判定。

賣家只可在尚無有效出價時取消，刊登費不退。有有效 bid 後，僅管理員可帶 reason 強制取消，且必須在同一 transaction 退款最高 bidder 並把物品送回 seller 信箱。第一版不做 anti-sniping 自動延長。

### 2.5 離線交付信箱

信箱是 server-side delivery queue，不是角色身上的容器：

1. 所有得標、購買、取消、過期、流標與管理移除物品先成為 READY delivery。
2. 玩家可逐件領取；第一版不提供「全部領取」，避免一筆 request 造成無界工作與部分成功。
3. 領取時 server 重新取得目前連線角色，驗證 delivery owner、revision、item codec、背包接收能力與 transaction 狀態。
4. 背包容量不足屬 retryable failure：物品留在 READY，沒有掉地、刪除或改 owner。
5. codec／migration 或 crash reconciliation 無法證明結果時，delivery 進 QUARANTINED，UI 顯示不可重複嘗試的收據短碼，由管理員處理。
6. READY item delivery 不自動過期或刪除；只有無物品的歷史 receipt 可依 retention policy 清理。

為避免非同步退件使信箱超出 hard cap：

- 建立 listing 時即替 seller 預留一個 return slot；
- 固定價購買 commit 前 buyer 必須取得一個 delivery slot；
- auction 最高 bidder 必須持有一個 win slot，被超標時一併釋放；
- forced return 使用建立 listing 時已預留的 slot，不能因信箱已滿而遺失物品。
- obligation 變成物品時，reservation 必須在同一 transaction 標為 CONSUMED 並建立 READY delivery；義務消失則標為 RELEASED。兩者都不可停留在 HELD。

### 2.6 錢包與獎勵

「錢包與獎勵」分成兩頁：

- **錢包**
  - 交易幣 available；
  - 拍賣中的 reserved；
  - 社群幣；
  - 近期 ledger receipt：來源、變動、餘額、txId 短碼；
  - 不提供自由輸入對象的玩家轉帳。
- **獎勵**
  - 每日簽到狀態：尚未達最低有效遊玩時間／可領取／已領取／當日全服額度已滿；
  - 下一個 rewardDay；
  - 當前角色生存進度與下一個一次性 milestone；
  - 近期獎勵 receipt。

每日簽到需達 server 計算的最低有效遊玩時間後手動領取，不做連續簽到倍率。若全服 daily mint cap 已滿，拒絕發放但不消耗 claim，也不在日後追溯補發。生存 milestone 由 server 自動發放；同一 characterKey＋milestone 只能建立一個 correlation key。

### 2.7 管理面板

client 只有在 server 回覆具有管理資格時顯示「管理」tab；這只是 UX，真正授權在每個 server command 重新檢查。

管理流程包括：

- 依安全的 account lookup 查詢 available／reserved／community balance；
- 以 bounded delta 調整餘額，必填 reason，不能直接覆寫成任意 client 值；
- 凍結／解凍 economy account；
- 移除固定價 listing；
- 強制取消 auction，原子退款與退件；
- 重新排程、隔離或人工解決 delivery／escrow；
- 調整費用、稅、價格、配額、時長、獎勵與 feature flag，使用 expected configRevision；
- 依 txId／listingId／auctionId 查詢裁切後 audit；
- 查看總存量、mint、burn、reserved、成交、流標、delivery failure 與 protocol mismatch 的彙總。

所有管理 mutation 都需要 protocolVersion、requestId、expectedRevision、reason 與 server-derived actor；client 不可傳可信 admin flag。

### 2.8 中文 IME 搜尋

ISTextEntryBox 提供 getText()，vanilla 亦有 parent panel 在 prerender() 每 frame讀取文字、與 cached value 比較後才處理的先例：ISTextEntryBox.lua:40-61、ISServerSandboxOptionsUI.lua:69-86。指定來源未提供可靠的 IME composition callback，也不能假設中文組字送出一定觸發 onTextChange。

搜尋採以下規則：

1. onTextChange 只作輔助提示，不是唯一真相。
2. 僅在市場頁可見且搜尋框 enabled 時，由 parent prerender() 比對 getText() 與 lastObservedText。
3. 文字改變時增加 queryRevision、清除舊選取，等待短暫穩定期後才送一次 query；每 frame 不送網路 request。
4. server 對搜尋文字的 UTF-8 bytes、頁碼、排序與分類做 hard cap；空白查詢回第一頁。
5. response 帶 queryRevision；晚到的舊 response 直接丟棄，不覆蓋新搜尋。
6. 收到結果不得重設 entry 文字或游標，避免破壞正在進行的 IME composition。
7. 「清除」按鈕必須立刻取消 pending query 並送出新的空查詢。

## 3. UI wireframe（ASCII）

視覺語言採中性的「中央帳本／交易所」：深色資訊面板、紙本收據式明細、單一 accent 色表示可操作項目；不使用黑市、骨頭或購物車圖像。兩種貨幣同時顯示名稱與數字，不只靠顏色。

### 3.1 視窗外殼

~~~text
+--------------------------------------------------------------------------------------------------+
| 中央交易中心                                      同步：已更新 12:40       [最小化] [關閉]       |
| 交易幣 available 12,340 | reserved 800 | 社群幣 180 | 信箱 3 件                             |
+--------------------------------------------------------------------------------------------------+
| [交易中心] [拍賣場] [刊登／我的刊登] [信箱 3] [錢包] [獎勵] [管理*]                         |
+--------------------------------------------------------------------------------------------------+
|                                                                                                  |
|                                  目前分頁內容                                                    |
|                                                                                                  |
+--------------------------------------------------------------------------------------------------+
| 收據：購買成功 TX-4F2A                     市場 revision 381     [重新整理]                       |
+--------------------------------------------------------------------------------------------------+
* 管理 tab 只在 server 回覆可用時顯示；顯示不代表授權。
~~~

視窗為一般 top-level UI，不使用 alwaysOnTop。ESC 會隱藏既有 top-level UI；hidden element 仍可能執行 update，因此背景同步不得自行 setVisible(true)，且不可把交易視窗浮到 ESC、世界地圖或其他 modal 上方。出處：MainScreen.lua:1735-1769、ISUIHandler.lua:5-27、UIManager.java:811-814、UIElement.java:1661-1675、UIManager.java:545-555。

### 3.2 固定價交易中心

~~~text
+--------------------------------------------------------------------------------------------------+
| 搜尋 [中文輸入測試________________] [清除]  分類 [全部 v]  排序 [最新 v]  每頁 [server cap]       |
+----------------------+------------------------------------------------------+--------------------+
| 分類                 | 商品                                                 | 詳情               |
| > 全部               | 名稱                 狀態摘要       賣家      價格   | [缺圖 placeholder] |
|   食物               | 消防斧               condition 78   玩家甲    450    | 消防斧             |
|   工具               | 罐頭                 未開封         玩家乙     35    | full type          |
|   醫療               | ...                                                  | server snapshot    |
|   其他               |                                                      | 到期時間           |
|                      |                                                      |                    |
|                      |                 [<] 第 2 / ? 頁 [>]                   | 支付：450 交易幣   |
|                      |                                                      | [購買]             |
+----------------------+------------------------------------------------------+--------------------+
| 若 revision 過期：保留搜尋條件、取消選取、刷新本頁；不可自動購買替代商品。                     |
+--------------------------------------------------------------------------------------------------+
~~~

第一版只有 list view。ISScrollingListBox 在 prerender 仍會遍歷整個 items，畫面外列到 draw 階段才早退，因此 client 只放入當頁 bounded rows，不把全市場塞進一個 list。出處：ISScrollingListBox.lua:304-310、475-538。

### 3.3 拍賣場與出價確認

~~~text
+--------------------------------------------------------------------------------------------------+
| [進行中] [我出價的] [我刊登的]   搜尋 [__________________]   排序 [即將到期 v]                   |
+-------------------------------------------------------------+------------------------------------+
| 項目                         目前最高價       server 到期     | 拍賣詳情                           |
| 發電機                       2,400            00:12:18        | 起標：1,800                         |
| 無線電                         620            01:04:03        | 目前：2,400                         |
| ...                                                         | 下一有效出價：2,450                 |
|                                                             | 我的 available：3,000               |
|                                                             | 我的 reserved：800                  |
|                                                             | 輸入總出價 [2450________] [出價]    |
+-------------------------------------------------------------+------------------------------------+
| client 倒數只供顯示；server 收到 command 後先判定是否到期。                                       |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------+
| 確認出價                                                     |
| 新總出價：2,450  | 本次新增 reserve：2,450                  |
| 得標物品將送入信箱；被超標時 reserve 自動釋放。             |
|                                      [取消] [確認出價]       |
+--------------------------------------------------------------+
~~~

### 3.4 刊登、我的刊登與信箱

~~~text
+--------------------------------------------------------------+
| 新增固定價刊登                                               |
| 可刊登物品 [消防斧 | condition 78 | full type________ v]     |
| 價格         [473________]（版面示意，非預設值）              |
| 刊登費       17（版面示意；成功建立 escrow 才 burn）          |
| 成交稅預覽   31（由 server 重算）                             |
| 預估實收     442                                              |
| 到期         由 server 設定                                  |
| 退件 slot    已預留                                           |
|                                      [取消] [確認刊登]       |
+--------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| 信箱 3 件                    類型             狀態             來源                   操作         |
| 消防斧                       購買             READY            固定價 TX-4F2A         [領取]       |
| 發電機                       得標             READY            拍賣 AU-18C0           [領取]       |
| 收音機                       退件             QUARANTINED      到期 LS-2D11           [查看收據]   |
+--------------------------------------------------------------------------------------------------+
| 背包容量不足：保留 READY。codec／migration 無法證明：不得重試複製，交由管理員處理。              |
+--------------------------------------------------------------------------------------------------+
~~~

### 3.5 錢包與獎勵

~~~text
+-----------------------------------------------+--------------------------------------------------+
| 錢包                                          | 獎勵                                             |
| 交易幣 available              12,340          | 每日簽到：可領取                                 |
| 拍賣 reserved                    800          | 有效遊玩：已達成                                 |
| 社群幣                            180          | 下一 reward day：server 顯示值                   |
|                                               | [領取每日獎勵]                                   |
| 最近帳本                                      |                                                  |
| +442  固定價售出  TX-81E0（版面示意）          | 生存 milestone                                   |
| -800  拍賣 reserve TX-22A1                    | 目前角色：6.4 日                                 |
| +180  Discord 兌換 EX-9C10                    | 下一個：7 日（自動發放）                         |
+-----------------------------------------------+--------------------------------------------------+
~~~

### 3.6 管理面板

~~~text
+--------------------------------------------------------------------------------------------------+
| 管理： [帳號] [刊登／拍賣] [交付／escrow] [經濟設定] [Audit] [統計]                              |
+--------------------------------------------------------------------------------------------------+
| 查詢 account [____________________] [搜尋]                                                        |
| 交易幣 available 8,200 | reserved 1,100 | 社群幣 40 | 狀態 ACTIVE                                 |
| 調整類型 [交易幣 v]  delta [+100____]  reason [____________________________] [套用]              |
|                                                                                                  |
| 設定變更：expected configRevision 42 -> server revalidate                                        |
| 強制取消拍賣：refund reserve + return escrow 必須同一 transaction                                |
+--------------------------------------------------------------------------------------------------+
| 一般 client 不顯示完整 account key、Discord identity、內部 security reason 或秘密。              |
+--------------------------------------------------------------------------------------------------+
~~~

## 4. server 規則與狀態機

### 4.1 Command 與 transaction envelope

所有 client request 都走 sendClientCommand，server 回覆指定玩家的 sendServerCommand；兩者的已查證出處見第 10 章。一般玩家也能送 ClientCommand transport，因此安全性不能依賴「一般玩家不會呼叫此 command」。

每個 mutation envelope 至少包含：

| 欄位 | 規則 |
|---|---|
| protocolVersion | 不相容即 fail closed，不做猜測式欄位補齊 |
| requestId | 同 account、同 command 唯一；重送回原 receipt，不重做 mutation |
| expectedRevision | listing／auction／delivery／config 的 optimistic concurrency gate |
| targetId | 只定位 domain record；server 重查 owner、狀態與關聯 |
| bounded input | 僅允許 action 所需的 ID、整數、enum 與短字串；未知欄位拒絕 |

actor、accountKey、sellerKey、admin permission、餘額、reserved、費用、稅、item snapshot、到期判定與 reward amount 都從 server state 推導。client 顯示資料不回寫為權威。

transaction 取得 lock 的固定順序為：config／account freeze -> market record -> escrow／delivery -> 按 accountKey 排序的 wallets -> ledger／audit。實際 Lua 是否需要 thread lock 仍待實作決定，但 domain 必須有 in-progress guard，避免 scheduler、admin 與 command 對同一 record 重入。

### 4.2 費用與結算

- listing fee：escrow 建立成功的同一 transaction 扣除並 burn；失敗不扣；取消、過期、流標不退。
- sales tax：只在成交／拍賣結算時從 seller gross proceeds 扣除並 burn。
- buyer 固定價支出：畫面標價，不另加隱藏費用。
- auction reserve：available 與 reserved 間移轉，不是 mint／burn；release 必須回到原 account。
- 所有金額是 bounded non-negative integer；計算順序與 rounding policy 由 server config 固定，不能使用 float 金額。
- 市場只接受交易幣；社群幣不能作第二種報價單位。

### 4.3 固定價 listing

~~~text
PENDING_ESCROW
  |-- validation / persistence fail --> ABORTED
  '-- commit -------------------------> ACTIVE

ACTIVE
  |-- purchase, lock acquired --------> SETTLING --> SOLD
  |-- seller cancel ------------------> RETURNING --> RETURNED
  |-- expiresAt reached --------------> RETURNING --> RETURNED
  '-- admin remove -------------------> RETURNING --> RETURNED

PENDING_ESCROW / SETTLING / RETURNING
  '-- result cannot be proven --------> QUARANTINED
~~~

規則：

- PENDING_ESCROW 不對其他玩家可見。
- ACTIVE 才能被搜尋、購買或 seller 取消。
- SOLD 代表 buyer delivery READY、seller net credit、tax burn 與 listing terminal state 已共同 commit。
- RETURNED 代表 seller delivery READY；endReason 分別記 SELLER_CANCEL、EXPIRED 或 ADMIN_REMOVE。
- 同一 listingId＋revision 最多成功成交一次。
- fixed listing 有 server 設定的 bounded lifetime，避免永久累積 stale records。
- ABORTED 不保留扣款與 escrow；只可保留 bounded failure receipt。
- QUARANTINED 凍結相關 escrow，不得用重建預設 item 的 fallback 自動猜測。

### 4.4 Auction

~~~text
PENDING_ESCROW --> ACTIVE_EMPTY

ACTIVE_EMPTY
  |-- first valid bid ----------------> ACTIVE_BIDDED
  |-- seller cancel ------------------> RETURNING --> RETURNED
  |-- expiry, no bid -----------------> RETURNING --> RETURNED (NO_BID)
  '-- admin cancel -------------------> CANCELLING --> RETURNED

ACTIVE_BIDDED
  |-- higher valid bid ---------------> ACTIVE_BIDDED (revision + 1)
  |-- expiry -------------------------> SETTLING --> SETTLED
  '-- admin cancel -------------------> CANCELLING --> RETURNED

PENDING_ESCROW / RETURNING / CANCELLING / SETTLING
  '-- result cannot be proven --------> QUARANTINED
~~~

bid transaction：

1. 鎖定 auction 與涉及的 wallets／mailbox reservations。
2. 若 nowMs 已達 expiresAtMs，先拒絕 bid 並排程 exactly-once settle。
3. 驗證 bidder、revision、最低有效總出價、available 與 mailbox win slot。
4. 新 bidder 先 reserve 全額並取得 win slot。
5. 同 transaction release 舊 bidder reserve 與 slot；同 bidder 加價只 reserve 差額。
6. 更新 highestBid、highestBidderKey、reserveId、revision 與 audit。

到期有 bid：

- consume winner reserve；
- credit seller gross minus tax；
- burn tax；
- escrow 轉 winner READY delivery；
- 將 auction 標為 SETTLED，correlation key 固定為 auctionId 的 settle key。

到期無 bid：使用 seller 預留 return slot 建立 READY delivery，標為 RETURNED／NO_BID。server 啟動 recovery 必須掃描已到期但未 terminal 的 auction；client 連線與否不影響 settle。

拍賣使用 server real wall clock epoch 作為產品語意，讓 server 離線期間也會跨越期限。getTimestampMs() 直接回 System.currentTimeMillis()，且原版 server Lua 有使用此 API；出處：LuaManager.java:9259-9273、forageServer.lua:213、225、303、456。實作仍須處理系統時鐘倒退或大幅跳動，並保存 lastSeenMs；這是演算法責任，不是 API 已保證。

### 4.5 Delivery／mailbox

~~~text
MailboxReservation

HELD
  |-- create READY delivery in same tx --> CONSUMED
  '-- obligation removed ---------------> RELEASED

Delivery

READY
  '-- claim request ------------------> CLAIMING
        |-- inventory commit proven --> CLAIMED
        |-- retryable capacity fail ---> READY
        '-- codec/recovery uncertain --> QUARANTINED

QUARANTINED
  '-- admin repair with proof --------> READY or CLAIMED
~~~

- HELD reservation 是 mailbox capacity obligation，不包含可領 item；CONSUMED 與 RELEASED 都是 terminal。
- HELD -> CONSUMED 必須與 READY delivery 建立在同一 transaction；HELD -> RELEASED 必須與對應義務消失在同一 transaction。
- READY 保存 immutable escrow reference 與裁切後 display snapshot。
- CLAIMING 必須先建立 durable claim intent，再變更 inventory；只有 server 能證明 inventory commit 才能清除 escrow snapshot。
- crash 後若無法判斷「已加入 inventory」或「尚未加入」，不可盲目重放 AddItem；轉 QUARANTINED。
- READY item 不自動過期；CLAIMED 後只保留 bounded receipt。
- 領取到目前 server-resolved character；mailbox owner 維持 account scope。

每種終局的 slot 轉移固定如下：

| 事件 | seller return slot | buyer／winner slot | 舊／現任 bidder slot |
|---|---|---|---|
| listing／auction 建立失敗 | HELD -> RELEASED | 不存在 | 不存在 |
| 固定價售出 | HELD -> RELEASED | HELD -> CONSUMED，同 tx 建 buyer READY delivery | 不適用 |
| 固定價取消／過期／admin remove | HELD -> CONSUMED，同 tx 建 seller READY delivery | 不存在 | 不適用 |
| 新 bidder 超標 | 不變，維持 HELD | 新 bidder HELD | 舊 bidder HELD -> RELEASED |
| 同 bidder 加價 | 不變，維持 HELD | 原 HELD slot 不重建 | 原 HELD slot 不釋放 |
| auction 有 bid 結算 | HELD -> RELEASED | winner HELD -> CONSUMED，同 tx 建 winner READY delivery | 同 winner slot |
| auction 無 bid 流標／無 bid 取消 | HELD -> CONSUMED，同 tx 建 seller READY delivery | 不存在 | 不存在 |
| admin cancel 有 bid auction | HELD -> CONSUMED，同 tx 建 seller READY delivery | 不建立 winner delivery | bidder HELD -> RELEASED，且同 tx release wallet reserve |

recovery 掃描到 terminal listing／auction 時，不得存在無主 HELD slot；每個 CONSUMED reservation 必須恰好對應一筆 READY／CLAIMING／CLAIMED delivery。

### 4.6 Reward

每日簽到 correlation key 為 accountKey＋rewardDayKey；生存 milestone key 為 characterKey＋milestone。兩者先查 durable correlation，再 grant：

- DAILY_LOCKED -> DAILY_ELIGIBLE -> DAILY_CLAIMED；
- daily cap 滿時維持 ELIGIBLE，不消耗 claim；
- MILESTONE_PENDING -> MILESTONE_GRANTED；
- 重複事件或 request 回既有 receipt。

server 時區、有效遊玩時間、characterKey 與生存進度的精確來源仍是第 10 章的待查證項目。未證明前不得以 client 時鐘、自報遊玩時間或 display name 決定獎勵。

### 4.7 Recovery 與 fail-closed

- state 有 schemaVersion、configRevision 與 lastAppliedTxSeq。
- mutation 先寫可恢復 intent，再套用 domain change，再標 committed；實際可用 persistence API 與 crash-safe replace 尚未證明，屬 production blocker。
- 啟動時先 recovery／migration，完成前所有 economy mutation 回 SERVICE_RECOVERING。
- migration 失敗時保留原資料並凍結寫入；不得重建空錢包、清除 escrow 或跳過未知 record。
- terminal record 不回到 active。
- audit／ledger 可證明才完成或 rollback；無法證明就 quarantine，不能依 client 狀態猜測。

## 5. 防濫用與安全

### 5.1 信任邊界

MP 寫入固定走：

~~~text
client UI
  -> sendClientCommand(intent)
  -> server resolves player from connection
  -> protocol / schema / auth / ownership / state / limits
  -> transaction + durable receipt
  -> targeted sendServerCommand(read-only result)
~~~

server 的 OnClientCommand player 由 connection＋playerIndex 解析，不採信 args 內的 username、SteamID 或 onlineID：GameServer.java:2247-2271、2306-2317。ClientCommand transport 只需一般登入能力，故每個交易與管理 command 必須自行驗證：PacketTypes.java:290-299、498。

client 不可直接用 inventory sync 當交易 mutation。SyncItemDeletePacket 要求 Capability.EditItem；一般玩家走錯路徑可能觸發權限處理。出處：SyncItemDeletePacket.java:7-14。正確流程是 server handler mutation 後由 server 發 inventory sync。

### 5.2 物品信任風險

「server 找到該 item object」不等於所有 item fields 都可信。SyncItemFields 對登入玩家開放，server 會套用多種欄位並 wipe／覆蓋 item modData，而 consistency 主要驗證 container／item 存在：SyncItemFieldsPacket.java:39-45、513-570、602-604。

因此：

- item ID 只定位 server 目前 inventory 中的物件，不能當 durable listing ID；
- 不以 condition、custom name、fluid、charge 或 client-synced modData 自動 mint 貨幣；
- 第一版用 server allowlist 限制可交易 item 類型與可顯示欄位；
- 動態狀態只作 buyer 可見 snapshot，不作系統收購價；
- 未能證明 round-trip 的 item fail closed，不以 instanceItem(fullType) 猜測重建；
- snapshot 只保存有 byte／欄位上限的 allowlist，禁止無界複製整份 modData；
- non-empty container、遞迴 inventory、活體／特殊媒體／複合 fluid 等類型，在 codec 實測通過前不可刊登。

### 5.3 輸入、重放與競爭

- protocol 不相容、未知 command、未知欄位、非整數、負值、NaN、overflow、超長字串、非法 enum 一律拒絕。
- 價格、page size、頁碼、搜尋 bytes、刊登數、auction 數、mailbox obligation、snapshot bytes、receipt retention 與 audit preview 都有 server hard cap。
- rate limit 分 account、command class 與昂貴 query；read query 與 mutation 不共用單一額度。
- requestId result durable 到足以涵蓋 network retry 與 reconnect；同 ID 換 payload 視為衝突，不執行。
- listing／auction／delivery 使用 expectedRevision；stale request 回可理解錯誤與目前 revision。
- 禁止買自己的 listing、對自己的 auction 出價、在有 bid 後由 seller 取消。
- scheduler、admin 與玩家操作共用相同 transaction path，不設維護捷徑。
- mailbox slot 在義務產生時預留，不等交付時才發現已滿。
- account freeze 會拒絕新 mutation，但不得凍結已到期 auction 的必要退款／settle recovery。

### 5.4 管理與隱私

- client 的 tab visibility、admin flag 或 access level 字串不是授權。
- server 每次以 role／capability 重新檢查；目前沒有 economy-specific Capability，暫以既有高權限 capability 作候選仍須產品決策。
- 餘額調整使用 delta、reason、requestId 與 expected wallet revision；不提供「把餘額設成 client 傳來的值」。
- 一般 client 不取得完整 account key、Discord identity、其他玩家 wallet、internal reason、其他帳號的 link challenge、authProof、server secret 或完整 audit。owning client 可在請求後取得自己的一次性短效 link code，且不得寫入一般 log。
- GlobalModData 可被已登入 client 依 tag request 並收到整表，故不可把可猜 tag 的私人 wallet／mailbox／Discord secret 當作 client-invisible storage。出處：GlobalModDataRequestPacket.java:11-16、31-33、GlobalModData.java:171-198。
- 外部 token、認證材料與管理員內部備註不進 client payload、一般 log 或翻譯字串。

### 5.5 Kahlua 與文案安全

- production Lua 不使用 next、assert、xpcall；Kahlua BaseLib 暴露清單沒有這三者：BaseLib.java:445-461。
- table 判空使用 bounded pairs loop；不把每筆 listing 拆成大量無上限的小 table。
- rawget／rawset 使用全域函式形狀，不用 method call。
- 翻譯參數只使用 %1 至 %9；字面百分比寫安全的 %%；禁止裸 ASCII %。
- 錯誤文案使用 enum errorCode 映射本地翻譯，不把 server exception、內部路徑或 security reason 原樣送給 client。

### 5.6 Audit

- 每個 transaction 聚合寫一筆 audit，不逐 item field 寫 log。
- username／display text 寫 log 前移除 CR、LF、TAB 與方括號，避免偽造分欄。
- audit 包含 txId、actorKey 的安全表示、action、targetId、result、reasonCode、configRevision；不含秘密或完整外部身分。
- writeLog() 每行 flush，但 ZLogger 超過上限是同檔截斷式重開，不是可依賴的輪替；需限制事件量。出處：LuaManager.java:9171-9177、ZLogger.java:56-79、95-112。

## 6. 資料模型

以下是概念 record；儲存格式須服從第 10 章的 persistence 查證結果。

| Record | 主要欄位 | 規則 |
|---|---|---|
| Wallet | accountKey, tradeAvailable, tradeReserved, communityBalance, version | 三者皆 bounded non-negative integer；交易市場只讀 trade 欄位 |
| WalletReserve | reserveId, accountKey, auctionId, amount, status, version | 一個 ACTIVE reserve 恰對應一場 auction 的 current highest bid |
| LedgerEntry | txId, accountKey, asset, pocket, delta, reasonCode, correlationId, createdAtMs | available -> reserved 以同 tx 的兩筆 pocket delta 表示；correlation 唯一 |
| Listing | listingId, revision, sellerKey, status, unitPrice, expiresAtMs, escrowId, returnSlotId, endReason | 一件、一價、一 escrow；status 只能依狀態機轉移 |
| Auction | auctionId, revision, sellerKey, status, startPrice, highestBid, highestBidderKey, reserveId, sellerReturnSlotId, highestBidWinSlotId, expiresAtMs, escrowId | 最高價必須已有 ACTIVE wallet reserve 與 HELD win slot |
| EscrowItem | escrowId, originalOwnerKey, sourceType, sourceId, codecVersion, boundedSnapshot, status | immutable payload；只屬於一個 listing 或 auction |
| MailboxReservation | reservationId, accountKey, sourceType, sourceId, status | status 為 HELD／CONSUMED／RELEASED；代表未來 delivery obligation，不等於 READY item |
| Delivery | deliveryId, revision, accountKey, sourceType, sourceId, escrowId, status, failureCode, claimTxId | account-scoped；READY item 不自動過期 |
| RewardState | accountKey, rewardDayClaims, activePlayState, characterMilestones | daily 是 account scope；milestone 是 character scope |
| ExternalLink | linkId, accountKey, challengeDigest, externalIdentityRef, status, createdAtMs, expiresAtMs | 明文短效 code 只回 owning client 一次且不落一般 log；server 保存 digest 與私有 external reference |
| ExternalExchange | externalTxId, linkedAccountKey, pointsAmount, creditAmount, status, receiptTxId | externalTxId 最多 credit 一次 |
| IdempotencyRecord | accountKey, requestId, commandType, payloadDigest, receipt, expiresAtMs | 同 ID 不同 digest 拒絕；retention bounded |
| EconomyConfig | configRevision, caps, fees, tax, durations, rewardRules, featureFlags | runtime 變更有 actor、reason 與 audit |
| AuditEvent | txId, actorKey, action, targetId, reasonCode, result, createdAtMs | server-only；client 只看裁切 view |
| MarketSubscription | connectionRef, accountKey, sessionId, visiblePage, lastHeartbeatMs, lastRevision | ephemeral、bounded；不當永久 domain truth |

### 核心 invariant

1. tradeAvailable、tradeReserved、communityBalance 永不為負且不超 cap。
2. 同一 committed 時點，一件 escrow item 恰存在於 player inventory、escrow、READY／CLAIMING delivery 或已證明交付的 inventory 其中一處。
3. 一個 escrowId 只關聯一個 listing／auction。
4. listing fee 與 sales tax 直接 burn，不進可被支出的 treasury。
5. 每個 committed wallet pocket delta 恰有 ledger entry；每個 correlation key 最多 commit 一次。
6. tradeReserved 等於該 account 所有 ACTIVE WalletReserve amount 總和。
7. auction 的 highestBid、highestBidderKey、reserveId 與 highestBidWinSlotId 必須同 transaction 更新；sellerReturnSlotId 從建立到售出／退件終局不得遺失。
8. mailbox 使用 account scope；領取時才選目前 server-resolved character。
9. item-bearing READY delivery 不因 retention 清理；只有 terminal receipt 可刪。
10. 一般玩家無法列舉完整 wallet、link、audit 或其他 account 的 mailbox records。
11. 每個 terminal listing／auction 都沒有無主 HELD reservation；每個 CONSUMED reservation 恰對應一筆 delivery。

### ID 與索引

- item getID() 依本產品政策只作本次 request locator，不升格為 listing／escrow domain ID。Java save／load 會保存該 ID，但其跨 transfer、rebuild、MOD migration 的全域唯一性與完整生命週期未證明；新 item ID 由 factory 產生。出處：InventoryItem.java:1663、1944、3590-3595、InventoryItemFactory.java:139-141。
- listingId、auctionId、escrowId、deliveryId、txId 與 requestId 使用 server 產生的 opaque ID；getRandomUUID() 已存在，但是否直接採用仍需衡量字串與儲存成本：LuaManager.java:2913-2918。
- server 至少維護 status＋expiresAt、sellerKey、highestBidderKey、account mailbox、correlationId 與 active subscription 的 bounded index。
- 搜尋欄位在 listing 建立時預先產生 normalizedSearchText；不在每次 query 對每個 item 重建。

### Persistence 邊界

GlobalModData 有 getOrCreate、save 與 load，dedicated server save pipeline 也會保存它：ModData.java:7-49、GlobalModData.java:218-304、ServerMap.java:400-412。Kahlua table persistence 的 key／value 白名單只涵蓋受支援的 primitive 與 nested KahluaTable，其他 userdata 會被排除，因此不能把 InventoryItem userdata 當 durable escrow：KahluaTableImpl.java:210-229、379-400。client 另可 request 已知 tag。

因此本提案只把它視為可行性研究對象，不預先定案為私人經濟資料庫。另一個已存在的私有 file reader／writer 也缺少已證實的 atomic replace、fsync 與 crash recovery。production storage 必須證明：

- server-private；
- versioned；
- bounded；
- 寫入失敗可偵測；
- crash 後能選出完整 snapshot／journal；
- 不會把 partially written balance 當新真相；
- 可備份、migration fail closed；
- 不寫進 Workshop MOD 內容。

## 7. 效能

### 7.1 Network 與訂閱

- 初次載入只傳錢包摘要、badge、config view 與第一頁，不傳全市場。
- 市場查詢由 server filter／sort／paginate；page size 有 hard cap。
- 只有 visible market session 是 active subscriber；關窗 unsubscribe，斷線／heartbeat timeout 清理。
- mutation 只推 revision invalidation 與必要 receipt；同一短窗口的 burst 合併成一次 page refresh 提示。
- server 回覆帶 sessionId、queryRevision 與 marketRevision；client 丟棄舊 session／舊 query response。
- item snapshot 傳 display allowlist，不傳 escrow 原始 payload、完整 modData 或其他玩家隱私。

### 7.2 搜尋與 UI

- IME 每 frame 只做短字串比較，不每 frame 查 server。
- debounce pending 只保留最新 query；切 tab、關窗、清除搜尋即取消。
- client list 只保留當頁 rows；不要把所有 listing 加入 ISScrollingListBox。
- 面板 hidden 後停止高頻 work；若保留 enabled 只允許低頻 visibility／session 收斂，不可自動 setVisible(true)。
- icon 缺失使用本 MOD 自有 placeholder；不得讓單一 icon error 中止整頁。安全取得 texture 的確切 API 尚待查證。

### 7.3 Server index 與 scheduler

- 建立 listing 時一次產生分類與搜尋 index 欄位。
- expiry 使用 earliest-due queue 或 time bucket；OnTick 僅在 nowMs 達 nextDueMs 時處理 bounded batch，不每 tick 全掃 auction。
- server 啟動後先處理 overdue records，再開放新 mutation。
- 同一 batch 有 work cap 與 continuation cursor，避免單次 tick 長時間阻塞。
- fixed listing 與 auction index 分離；查詢不需在每列判斷兩套規則。
- account 的 active listing／auction／mailbox obligation 本身有 quota，使最壞工作量受請求量控制。

### 7.4 Persistence、記憶體與 log

- dirty snapshot 合併寫入，但 pending transaction／ledger durability 不能只依一般延遲 save；實際 commit 策略需 storage 原型證明。
- idempotency、receipt、notification、search cache、admin preview 與 terminal record 都有 retention cap。
- 避免「每個 row 多個 Kahlua table」；相同欄位用緊湊 record，client DTO 只建當頁。
- audit 一 transaction 一行，通知以摘要呈現，不逐 item field 或逐市場 invalidation 寫 log。
- 觀測至少包含 query latency、page rows、active subscriptions、mutation count、save duration、overdue auctions、quarantined delivery 與 idempotency hit；一般 client 只看自己的同步狀態。

## 8. Discord 積分兌換介面

Discord 兌換是外部可信流程向 game server 提交「已完成的外部積分交易」，不是 client 告訴 server 自己有多少分。它先 credit account-bound 社群幣；是否允許社群幣單向換成交易幣，由 server feature flag、比率與每日上限控制。

### 8.1 玩家 UI

「錢包 > Discord」只顯示：

- 綁定狀態；
- owning client 剛申請時可見的一次性短效 link code、複製按鈕、狀態與到期；離開頁面後不保證再次顯示明文；
- 社群幣餘額；
- 最近 external exchange receipt；
- feature 啟用時的「社群幣 -> 交易幣」預覽、當日剩餘額度與確認。

不顯示完整 Discord identity、token、auth proof、companion 狀態細節或其他玩家資料。

### 8.2 綁定流程

~~~text
game account requests one-time link challenge
  -> server creates bounded, short-lived code and stores its digest
  -> owning client receives plaintext code once
  -> player copies the code into the Discord linking command
  -> trusted companion confirms challenge once
  -> server stores private external identity reference
  -> UI receives linked / expired / already-used receipt
~~~

- challenge code 是短效 bearer credential：一次性、與 accountKey 綁定，只回 owning client，不寫一般 log、audit 明文或 GlobalModData client-readable tag。
- UI 提供明確「複製代碼」與到期倒數；不顯示任何 server URL、token 或 authProof。
- client 不可指定最後 linkedAccountKey。
- external identity 只存 server-private representation；解除綁定與重新綁定需 cooldown、audit 與明確 ownership policy。
- transport 與 authentication 尚未查證；本文件不假設 Workshop Lua 能開 inbound HTTP listener。

### 8.3 兌換 request contract

外部 companion 提交的邏輯 envelope：

| 欄位 | 用途 |
|---|---|
| protocolVersion | 外部介面版本 |
| externalTxId | 全域唯一 idempotency key |
| externalIdentityRef | server 已綁定身分的私有 reference |
| pointsAmount | 外部已扣／授權的積分整數 |
| issuedAtMs／expiresAtMs | replay window |
| authProof | transport-specific proof；格式待查證 |

game server：

1. 驗證 transport、authProof、時效、externalTxId、link status 與整數 bounds。
2. 依 server config 計算 creditAmount；不接受 client 或 companion 指定任意交易幣入帳。
3. 以 discord＋externalTxId correlation 建立 ledger credit。
4. 第一次成功回 CREDITED receipt；重放同一 payload 回相同 receipt，不再次 credit。
5. 同 externalTxId 換 payload 視為衝突並隔離。

### 8.4 外部狀態機與補償

~~~text
RECEIVED
  |-- invalid / expired / unlinked --> REJECTED
  '-- validated --------------------> CREDIT_PENDING
                                         |-- ledger commit --> CREDITED
                                         '-- uncertain -----> RECONCILE

RECONCILE
  |-- committed proof -------------> CREDITED
  '-- no commit proof -------------> CREDIT_PENDING
~~~

若 Discord points 已扣但遊戲 credit 暫時失敗，companion 必須以相同 externalTxId 重試；不得產生新 ID。若撤銷／退款政策需要反向 ledger entry，必須是另一個具關聯 ID 的管理流程，不刪除原始 CREDITED entry。

社群幣：

- 不可玩家互轉；
- 不可直接購買 listing 或出價；
- 不可反向換回 Discord points；
- 若開放換交易幣，只能單向、bounded、server 計價、exactly once 並寫 audit；
- 沒有安全的社群幣 sink／轉換政策前，Discord feature 維持 disabled。

## 9. 實作複雜度與風險

### 9.1 複雜度估計

| 子系統 | 複雜度 | 主要原因 |
|---|---|---|
| UI 外殼、tab、當頁 list | M | vanilla 元件可用，但需解析度、ESC、modal、stale response 與 IME |
| Wallet／ledger／idempotency | L | 整數 invariant、reserved pocket、durability、migration、receipt |
| 獎勵頁 | M-L | daily 與 milestone 狀態清楚，但 account／character identity、時間來源待證明 |
| Escrow／ItemCodec | XL／Critical | 任意 MOD item、bounded snapshot、重啟 round-trip、client-synced fields |
| 固定價市場 | L | escrow、race、稅、到期、offline seller、mailbox slots |
| 拍賣 | XL | reserve、outbid release、real-time expiry、restart settle、admin cancel |
| Delivery／mailbox | XL／Critical | claim crash window、背包容量、exactly-once item placement |
| Persistence | XL／Critical | server-private、atomic replacement、journal／snapshot、failure recovery |
| 管理面板 | L | capability、reason、config revision、敏感資料裁切與 audit |
| Discord adapter | XL | link、auth、external idempotency、reconcile、外部 transport |

### 9.2 主要風險與處置

| Severity | 風險 | 設計處置／停止條件 |
|---|---|---|
| Critical | 純 Lua 尚未證明可把 arbitrary InventoryItem blob encode／decode | 先做 item round-trip 原型；未通過時只允許經實測可重建的簡單 allowlist，或不上線玩家市場 |
| Critical | claim 在「已加 item、未標 CLAIMED」之間 crash，可能複製或遺失 | 必須證明 durable claim intent 與可辨識 inventory commit；無法證明就 quarantine，市場不上 production |
| Critical | persistence 非 atomic 或私人資料可被 client request | 不以可猜 GlobalModData tag 保存私人經濟真相；storage 原型未通過 crash／privacy test 前不開 mutation |
| High | SteamID、username、onlineID 各有不同 identity 語意 | accountKey 政策與 rename／多帳號 migration 未定前不發幣、不建 mailbox |
| High | client 可同步修改部分 item fields | 不以動態欄位 mint；strict allowlist、snapshot bounds、異常值拒絕；高價值 stateful items 延後 |
| High | auction restart／clock jump／競標 race | persisted expiresAtMs、lastSeenMs clamp、single settle correlation、overdue recovery |
| High | Discord 外部扣分與遊戲 credit 分離 | externalTxId exactly once、RECONCILE、feature flag；transport 未驗證只阻擋 Discord |
| Medium | mailbox obligation cap 在非同步退件時失守 | listing／highest bid 階段預留 slot；READY item 不因 cap 被刪 |
| Medium | hidden UI 仍 update 或覆蓋 ESC／modal | 主視窗不 AOT；visible gate；關窗清 subscription；不得 background setVisible(true) |
| Medium | 中文 IME 觸發不完整或每 frame 查詢 | prerender getText 比對＋debounce＋queryRevision |
| Medium | 管理員誤操作 | delta、reason、expectedRevision、preview、audit、不可 client-side bypass |

### 9.3 建議交付順序

1. **Gate 0：身份、storage、ItemCodec 原型**
   - accountKey／characterKey；
   - server-private crash recovery；
   - simple item 與 representative MOD item 的 escrow -> save -> restart -> return／claim；
   - claim crash window。
2. **Gate 1：wallet、ledger、idempotency、reward、admin audit**
   - 還沒有玩家市場 mutation；
   - 驗證 reconnect、重送與 migration fail closed。
3. **Gate 2：單件固定價＋mailbox**
   - 兩買家競爭、offline seller、取消、到期、信箱滿、背包滿、quarantine。
4. **Gate 3：拍賣**
   - reserve、outbid、同 bidder 加價、無 bid、server 離線跨越期限、admin cancel。
5. **Gate 4：Discord**
   - link、authenticated transport、externalTxId replay、外部扣分後 reconcile。

### 9.4 Production gates

- account identity 未證明：不上線 wallet、reward、market。
- escrow -> restart -> return／claim 未無損證明：不上線 market。
- private persistence、migration、partial-write recovery 未證明：不上線任何 economy mutation。
- auction server time、clock jump 與 overdue exactly-once 未證明：固定價可留測試，拍賣關閉。
- Discord authenticated replay test 未完成：只關閉 Discord feature，不阻擋固定價。
- 中文 IME、ESC、world map、modal、缺 icon、不同解析度未驗證：不宣稱 UI 完成。

## 10. 待查證 API 清單

本章分為「已查證可作設計依據」、「只有部分證據，不等於可直接實作」與「待查證」。所有 WalletService、Listing、Auction、Delivery 等名稱都是本專案 domain 名稱，不是 PZ API。

### 10.1 已查證可作設計依據

| 能力／API | 證據與可安全主張的範圍 |
|---|---|
| client -> server command | sendClientCommand overload 與 MP ingame 分流：LuaManager.java:8892-8925；packet 帶 playerIndex／module／command／args：GameClient.java:1839-1861 |
| server OnClientCommand actor | 事件存在：LuaEventManager.java:729；server 依 connection＋playerIndex 取 player：GameServer.java:2247-2271、2306-2317；vanilla handler shape：ClientCommands.lua:1249-1260 |
| targeted server -> client receipt | sendServerCommand(player, module, command, args)：LuaManager.java:8942-8945；client OnServerCommand：GameClient.java:1052-1068、LuaEventManager.java:730 |
| MP 初次送 command 時序 | OnGameStart 早於 player connect：IngameState.java:762-775；ingame 在 UpdateStuff 設定：563-565；每幀先 UpdateStuff 再 OnTick：1529-1534、1624-1626 |
| server role／capability pattern | player:getRole():hasCapability(...) 的 server handler 用例：ClientCommands.lua:1231-1245；role 缺失 fail closed：Role.java:176-190；現成高權限候選 ChangeAndReloadServerOptions：Roles.java:448-477 |
| UI top-level／tabs／list | ISCollapsableWindow.lua:9-16、26-37、366-400；ISUIElement add/remove：ISUIElement.lua:1365-1379；ISTabPanel.lua:438-456、484-503；ISScrollingListBox.lua:141-151、340-345 |
| 文字輸入與 polling | ISTextEntryBox getText：ISTextEntryBox.lua:40-61；UITextBox2.java:389-395、847-850；vanilla parent prerender 比對：ISServerSandboxOptionsUI.lua:69-86 |
| ESC／visibility | MainScreen.lua:1728-1729、1735-1769、2182；ISUIHandler.lua:5-32；isReallyVisible：ISUIElement.lua:690-694、UIElement.java:1798-1804 |
| hidden UI update／AOT | hidden top-level 仍 update：UIManager.java:513-520、811-814、UIElement.java:1661-1675；AOT 每輪移到最上層：UIManager.java:545-555 |
| server wall clock | getTimestamp／getTimestampMs：LuaManager.java:9259-9273；server Lua 用例：forageServer.lua:213、225、303、456 |
| server events | OnTick、OnDisconnect、OnSave、OnGameTimeLoaded、OnServerStarted 存在：LuaEventManager.java:593、653、669、737、744；只證明事件存在，不等於 persistence transaction |
| inventory 當次 lookup | player root inventory 遞迴 item ID lookup：ItemContainer.java:3065-3080；recursive contains：ItemContainer.java:672-720；InventoryItem.getID：InventoryItem.java:3590-3595 |
| server inventory mutate＋sync 形狀 | Remove／AddItem：ItemContainer.java:458-493、2032-2063；sendAdd／sendRemove：LuaManager.java:12302-12319、12342-12353；vanilla server 配對用例：ClientCommands.lua:180-188 |
| persistent GlobalModData 基礎 | ModData facade：ModData.java:7-49；GlobalModData save／load：GlobalModData.java:218-304；dedicated save pipeline：ServerMap.java:400-412 |
| 私有文字檔基礎 | getFileReader：LuaManager.java:5933-5964；getFileWriter：6725-6759；允許副檔名：1032-1035；writer methods：12750-12769 |
| log | writeLog：LuaManager.java:9171-9177；ZLogger timestamp／flush／截斷行為：ZLogger.java:56-79、95-112 |
| Kahlua base globals | BaseLib 暴露清單：BaseLib.java:445-461；可確認其中沒有 next、assert、xpcall |

### 10.2 只有部分證據，尚不可當完成方案

| 項目 | 已找到 | 尚缺 |
|---|---|---|
| account identity | getUsername：IsoPlayer.java:6445-6475；getSteamID：6412-6417；getOnlineID：6488-6491 | username 可 rename：ServerWorldDatabase.java:188-201；同一 Steam ID 可有多個 username/account：1200-1229；onlineID 是當次連線 ID。仍需 accountKey 產品政策與 migration |
| character identity | server player slot／playerIndex 有資料：IsoPlayer.java:966-974、GameServer.java:2767-2771、2794；ServerPlayerDB 以 account/world/playerIndex 查角色：ServerPlayerDB.java:124-147、216-234 | 同 slot 死亡後新角色的 generation key、rename 與角色重建語意未證明，不能直接拿 playerIndex 當 milestone identity |
| InventoryItem serialization | Java save／loadItem／load 存在：InventoryItem.java:1660-1697、1872-1918、1943-1955、2019-2027 | 方法需要 ByteBuffer；原版 Lua 未找到可建立並完成 arbitrary item blob round-trip 的路徑 |
| instanceItem | 可由 full type 建立預設 item：LuaManager.java:5599-5627 | 不保留 condition、age、attachments、fluid、custom pages、modData；不能當 generic restore |
| GlobalModData privacy | request／transmit API 存在 | 已登入 client 可 request tag 並取得整表：GlobalModDataRequestPacket.java:11-16、31-33、GlobalModData.java:171-198；不適合作可猜 tag 的私人 wallet／mailbox／secret |
| private file storage | reader／writer 存在 | 只提供 write／writeln／close，未證明 atomic rename、fsync、error check、world save scope、雙檔 recovery |
| game time | getWorldAgeHours getter 存在：GameTime.java:901-908 | 目前引用只證明 getter，未充分證明 dedicated server 離線期間的推進語意；維持待實機查證，不作 real-time auction clock |
| admin capability | vanilla role/capability 可檢查 | 未找到 MOD 自訂 economy Capability 的 Lua 註冊 API；採哪個現有 capability 仍待決策 |

### 10.3 待查證

以下未取得足以承諾實作的指定來源證據，必須在寫 production Lua 前完成查證或原型：

1. dedicated server accountKey 的正式組成、Steam／non-Steam 政策、username rename migration 與多帳號語意。
2. characterKey 的世代識別、死亡／新角色事件、有效遊玩時間與生存天數的 server-authoritative 來源。
3. 純 Lua generic InventoryItem blob encode／decode bridge，以及 vanilla、fluid、drainable、battery、food、attachments、custom pages、有限 modData 與第三方 MOD item 的 round-trip。
4. escrow 實物若不使用 blob，跨 chunk unload、world save、server restart 與 MOD 缺失時的可靠保存方式。
5. item eligibility 的完整 API：裝備／手持、non-empty container、nested inventory、fluid、fuel、battery、media、favorite、world item 與其他特殊類型。
6. delivery claim 前的背包重量／容量／接收能力判定，以及「已成功加入 inventory」的 crash 後證明方法。
7. server-private persistence 的 atomic replace／fsync／partial-write detection／snapshot＋journal recovery；GlobalModData 或 file writer 單獨存在不等於通過。
8. server clock 倒退／大跳的處理、lastSeenMs 保存與拍賣 downtime policy 的實機驗證。
9. economy-specific admin capability；若沿用現有 capability，需確認 admin／moderator 的產品權限矩陣。
10. 自訂快捷鍵、rebind、與 vanilla 多個 OnKeyPressed handler 的順序／衝突處理。
11. 中文 IME composition callback 的實際行為；目前只採 getText polling workaround，仍需繁中輸入法實機測試。
12. 世界地圖與其他 modal 的完整 visibility／focus 行為，以及 setCapture 對各類輸入是否足夠；setCapture 本身不保證所有事件都被消耗。
13. 缺 icon 時安全取得本 MOD placeholder texture 的確切 API。
14. market DTO／KahluaTable packet 的 payload size 上限、超限錯誤與大量分頁壓測。
15. Discord companion inbound transport、authentication、link callback、externalTxId 重試與撤銷介面；不得預設 Workshop Lua 可開 HTTP listener。
