# 設計稿 B：玩家自建交易站（世界物件攤位／販賣機）

- 文件性質：產品與 server domain 設計提案
- 目標版本：Project Zomboid Build 42.20.4
- 執行環境：多人 dedicated server only；單人不在支援範圍
- Lua 執行契約：Kahlua；實作禁止呼叫缺失的 `next`／`assert`／`xpcall`，可格式化字串的字面 `%` 一律寫成 `%%`，參數只用 `%1`–`%9`。Kahlua `BaseLib` 的註冊清單見 `BaseLib.java:445-466`
- 決策狀態：設計候選；第 9、10 章的 blocking gate 通過前不得視為可實作定案
- 既有決策基線：`docs/economy-system-analysis.md`

## 1. 概要

本方案的產品目標是讓玩家在自己的基地或 SafeHouse 放置單格交易站物件，於現場設定固定價商品；其他玩家可透過全服商品目錄找到位置，再親自到交易站購買。賣家不必在線，成交款直接進中央錢包。matching 42.20.4 證據目前只提供 SafeHouse owner／member 關係，沒有「非 SafeHouse 自有基地」的權威 ownership；因此可執行的 v1 只允許 SafeHouse，獨立基地支援保留為 blocking 擴充。

本方案承接既有分析的 server-authoritative 契約：client 只送出意圖；server 擁有 actor、交易站、商品、價格、庫存、SafeHouse 權限、餘額、狀態轉移與稽核紀錄。所有 mutation 都必須有 `requestId`、`txId`、revision、防重送與有限輸入；未知 command、畸形資料或 stale revision 一律 fail closed。

### 1.1 核心決策

| 領域 | 決策 |
|---|---|
| 世界物件 | 只作現場互動錨點與位置證明，不保存權威 owner、價格、庫存或錢包資料 |
| 放置範圍 | v1 只允許 server 可證明 actor 為 owner／member 的 SafeHouse；非 SafeHouse 自有基地須先補齊 server-authoritative base binding |
| 商品庫存 | 採 server-only、bounded virtual escrow 作唯一真實來源；交易站物件沒有可被玩家拿空的商品容器。持久化必須使用真正 server-private backend，目前是 blocking 待查證項目 |
| 商品相容性 | v1 只接受通過 `ItemCodec` 無損 round-trip 的白名單物品；未知 subtype、巢狀容器或未允許的 `modData` 一律拒絕刊登 |
| 結算 | 只使用中央錢包的「交易幣」；實體貨幣物品與「社群幣」都不能直接支付交易站商品 |
| 離線寄賣 | 賣家離線不影響刊登或入帳；商品、退款與待領物均由 account-bound server state 持有 |
| 商品目錄 | 只負責 discovery，不提供遠端購買；每筆搜尋結果畫面只顯示位置與價格 |
| 現場購買 | server 必須重新解析世界物件，並驗證距離、同層、可及性、SafeHouse 政策、listing revision、庫存與餘額 |
| 搬移／破壞 | 正常 UI 層盡量設為不可搬、不可拆；不把這些 client／物件旗標當安全邊界。物件消失即停站，但 escrow 保留 |
| 支援範圍 | 只支援 dedicated MP；不保留 SP 直寫捷徑，也不設計 SP fallback |

### 1.2 為何不採實體世界容器作權威庫存

引擎確實會把世界物件的 `ItemContainer` 與物品完整狀態寫入 world save；`IsoObject` 保存／載入 container，`ItemContainer` 再走完整物品 codec。出處：`IsoObject.java:1203-1244`、`IsoObject.java:1446-1462`、`ItemContainer.java:2418-2444`、`InventoryItem.java:3376-3385`。

但這條路徑不符合交易 escrow 的安全契約：一般世界物件預設允許移除物品，普通 inventory transfer 的 server 路徑未提供交易站 owner、價格、距離或 SafeHouse gate，而且物件破壞路徑會把容器內容倒到世界上。出處：`IsoObject.java:5274-5279`、`RemoveInventoryItemFromContainerPacket.java:20-26`、`RemoveInventoryItemFromContainerPacket.java:99-116`、`IsoObject.java:5747-5761`。

因此 v1 選擇 virtual escrow 作為 no-loss/no-dupe 的必要 domain shape；但 server-private storage、賣家物品 capture 與 crash ordering 通過第 9、10 章 gate 前，仍不能宣稱已達成該保證。實體容器若未來能證明 server 端可完整拒絕一般拿取、搬動與破壞，才重新評估；不得同時保留「實體一份＋虛擬一份」形成雙重庫存真相。

### 1.3 v1 範圍與非目標

- 只做固定價、單件 offer；多件同款以多筆 offer 表示，不做 bundle 部分購買。
- 每個 square 最多一個交易站；交易站不自動跨位置重新綁定。
- v1 只支援 SafeHouse 內建站；非 SafeHouse 的自有基地 ownership 尚待查證，不以「先放先得」或 client 座標代替。
- 不做遠端購買、玩家直接轉帳、拍賣、實體貨幣存提或社群幣支付。
- 不保證任意第三方 MOD 物品都可刊登；相容性由 codec 白名單決定。
- 不複製 BONE > Bshop 的程式碼、視覺、素材、版面或文案；UI、命名與互動皆獨立設計。

## 2. 玩家流程

### 2.1 賣家放置與啟用

1. 玩家取得交易站 kit，選擇自己是 owner／member 的 SafeHouse 內一格位置。
2. client 送出 placement intent；payload 不得指定可信 owner、價格或 SafeHouse 身分。
3. server 依 event actor 與目標 square 驗證：帳號配額、該格無其他交易站、世界物件可建立，以及 square 確實位於 SafeHouse；無 SafeHouse 時以 `BASE_OWNERSHIP_UNVERIFIED` 拒絕。
4. server 從 actor 取得 username，再呼叫 `safehouse:playerAllowed(username)` 驗證 owner／member。String overload 只檢 owner／member；`playerAllowed(IsoPlayer)` 另含 `CanGoInsideSafehouses` capability，不能用作建站 ownership。出處：`IsoPlayer.java:6445-6447`、`SafeHouse.java:157-159`、`SafeHouse.java:282-289`。
5. server 建立 `PROVISIONING` station record 與世界錨點，兩者都成功後才消耗 kit；任一步失敗都不得留下半套站點或重複 kit。
6. 賣家選擇是否公開到全服目錄。SafeHouse 內的交易站公開時，UI 必須明示位置將可被全服搜尋到，但不會改寫 SafeHouse 的原生進入／互動規則。

### 2.2 上架商品

1. 賣家必須站在交易站同格或相鄰可及格，開啟「站主管理」。
2. client 只送選取項目參照、正整數價格、`requestId` 與 station revision。
3. server 只在 actor 的 root inventory 內，以固定 inspect budget 重新找物品；v1 不遞迴 nested containers。超過 budget、找不到，或來源容器不能證明屬於 actor 時拒絕，不能用 rate limit 代替單次掃描上限。client 顯示名稱、condition、價格預覽都不是權威。
4. `ItemCodec` 先執行 bounded encode、decode 與 canonical re-encode。結果不相等、欄位超限或物品型別未列入白名單時，完整拒絕。
5. server 建立 `PREPARED` listing intent。此 snapshot 是非 custody 暫存：原物品仍是唯一實體，不可進目錄、claim 或 materialize，也還不能稱為 escrow。
6. 只有在第 10 章的 seller capture gate 證明「正確 root container、未裝備／未穿戴／未附掛、權威移除、client sync、restart ordering」可恢復後，server 才能把 exact source item 轉入 virtual escrow 並令 offer 進入 `ACTIVE`。
7. 成功後回傳 receipt；一般驗證失敗時物品與錢包維持原狀。若 crash 後無法證明 custody，offer 必須 `QUARANTINED` 並停止相關 mutation，不得由 snapshot 自動重建商品；fault injection gate 通過前不得啟用上架功能。

### 2.3 全服搜尋與到場

1. 買家在商品目錄輸入商品名稱或選取 server 提供的 catalog key。
2. server 只查 in-memory catalog index，不掃世界或所有 containers。
3. 同一查詢下，每筆畫面只顯示「位置」與「價格」；不顯示 owner、seller、即時數量、condition、`modData`、交易歷史或 SafeHouse 成員。
4. 結果可複製座標；地圖標記只有在第 10 章相關 API 查證後才加入。
5. 目錄資料是 discovery snapshot。玩家抵達後仍須重新開啟世界物件，server 才回傳目前可購買的 bounded item detail。

### 2.4 現場購買

1. 買家對世界物件開啟交易站 UI。
2. client 送出 `Buy(stationId, offerId, requestId, expectedRevision)`；不送可信價格、seller、座標、物件 index 或 item snapshot。
3. server 以 station registry 取得權威座標，只掃該 square，重新確認唯一且符合預期形狀的錨點仍存在。
4. server 驗證 actor 仍在同層、距離內且可觸及，並套用 SafeHouse 購買政策。
5. server 重查 offer revision、virtual escrow、中央錢包餘額與 `requestId`。
6. 成交時，交易幣從買家錢包扣除；稅後淨額進賣家錢包；稅額直接 burn；escrow ownership 轉成買家 `CLAIMABLE`。賣家是否在線不影響這一步。
7. server 嘗試把商品 materialize 到買家 inventory。若交付尚未完成，成交 receipt 仍指向同一份 account-bound claim；重試不得再次扣款或建立第二件物品。

### 2.5 賣家離線、取消與領回

- `ACTIVE` offer 不依賴賣家角色或原 inventory 存在；離線成交直接寫中央帳本。
- 賣家取消未成交 offer 時，escrow 轉為 `RETURNABLE`，不立刻猜測要塞回哪個離線角色 inventory。
- 正常領回可在原交易站現場完成；若交易站遺失、SafeHouse 權限改變或物品進入 recovery，改由中央經濟 UI 的 account-bound recovery inbox 領回。
- 關站先進入 `CLOSING`，停止新購買，將所有未成交 offer 轉成待領回。所有 active transaction 與 claims 收斂後，才可移除世界物件並進入 `CLOSED`。

## 3. UI wireframe（ASCII）

### 3.1 全服商品目錄

```text
┌──────────────────────────────────────────────────────────────┐
│ 商品目錄                                   交易幣：12,340   │
├──────────────────────────────────────────────────────────────┤
│ 搜尋商品：[ 電池                                      ] 搜尋 │
│ 目前查詢：電池                         第 1 頁／共 3 頁     │
├──────────────────────────────────────┬───────────────────────┤
│ 位置                                 │ 價格                  │
├──────────────────────────────────────┼───────────────────────┤
│ West Point　座標 11842, 6902, 0      │ 120 交易幣            │
│ Riverside　座標 6478, 5317, 0        │ 135 交易幣            │
│ Muldraugh　座標 10621, 10014, 0      │ 150 交易幣            │
├──────────────────────────────────────┴───────────────────────┤
│ [上一頁] [下一頁]　目錄只供找位置，必須到現場才能購買      │
└──────────────────────────────────────────────────────────────┘
```

每列只顯示位置與價格。`stationId`、offer revision 與 pagination cursor 可存在於 read-only DTO，但不得呈現在畫面或被當成權威購買條件。搜尋結果不保證抵達時仍有貨；現場驗證才是最終結果。

### 3.2 現場購買

```text
┌──────────────────────────────────────────────────────────────┐
│ 現場交易站　位置已驗證                    交易幣：12,340   │
├───────────────────────────────┬──────────────────────────────┤
│ 商品                          │ 選取商品詳情                 │
│ ───────────────────────────── │ 電池                         │
│ 電池                    120   │ 狀態：server snapshot        │
│ 罐頭食品                85    │ 價格：120 交易幣             │
│ 手電筒                  200   │ 購買後餘額：12,220           │
│                               │                              │
│                               │ [確認購買]                   │
├───────────────────────────────┴──────────────────────────────┤
│ 收據／錯誤：等待 server 回應；重按不會重複扣款             │
└──────────────────────────────────────────────────────────────┘
```

### 3.3 站主管理

```text
┌──────────────────────────────────────────────────────────────┐
│ 我的交易站　狀態：ACTIVE　位置：11842, 6902, 0             │
├──────────────────────────────────────────────────────────────┤
│ 商品                 價格        狀態             操作       │
│ 電池                 120         ACTIVE           [取消]     │
│ 手電筒               200         RETURNABLE       [領回]     │
├──────────────────────────────────────────────────────────────┤
│ [上架商品] [公開到目錄：是] [暫停營業] [安全關站]          │
│ 預估實收、刊登費與交易稅由 server 回傳，不由 client 計算   │
└──────────────────────────────────────────────────────────────┘
```

UI 規則：搜尋框須支援中文 IME；視窗不使用 `alwaysOnTop`；ESC、世界地圖或 modal 出現時不得自行浮回前景。`alwaysOnTop` 元件會被 `UIManager` 移到繪製序列尾端，出處：`UIManager.java:545-559`。按鈕點擊只建立 intent，成功、失敗、餘額與 offer 狀態一律以 server receipt 為準。

## 4. server 規則與狀態機

### 4.1 Command 與回應契約

client mutation 固定走 `sendClientCommand(player, module, command, args)`；server 從連線與 player slot 取得 actor，再把該 actor 傳給 `OnClientCommand`。出處：`GameClient.java:1839-1855`、`GameServer.java:2247-2267`、`GameServer.java:2292-2298`。`ClientCommand` 只要求玩家已登入，不等於已完成任何交易授權；所有 schema、owner、距離、SafeHouse、價格與錢包檢查都由本 MOD 自行完成。出處：`PacketTypes.java:498`。

server 可用指定玩家版本的 `sendServerCommand` 回傳 receipt，client 由 `OnServerCommand` 接收。出處：`LuaManager.java:8928-8945`、`GameClient.java:1060-1068`。

| Command | client 可送欄位 | server 必須重算／重查 |
|---|---|---|
| `PlaceStation` | `requestId`, placement intent | actor、square、kit、quota、SafeHouse owner/member、station ID、物件建立結果 |
| `ListItem` | `stationId`, item reference, positive integer price, `requestId`, revision | actor root inventory、inspect budget、裝備／穿戴／附掛狀態、完整 snapshot、owner、fee、station presence |
| `SearchCatalog` | normalized query, cursor, protocol version | 可公開結果、位置、價格、page cap |
| `OpenStation` | `stationId`, `requestId` | authoritative position、anchor、距離、可及性、SafeHouse、bounded detail |
| `Buy` | `stationId`, `offerId`, `requestId`, expected revision | actor、座標、價格、seller、stock、tax、wallet、delivery claim |
| `CancelOffer` | `stationId`, `offerId`, `requestId`, revision | station owner、SafeHouse、offer 狀態、return claim |
| `CloseStation` | `stationId`, `requestId`, revision | owner、pending transactions、claims、物件移除資格 |

### 4.2 每次現場 mutation 的固定驗證順序

1. 驗證 protocol、command、table schema、字串長度、正整數、rate limit 與 `requestId`。
2. 由 event actor 解析 account key；忽略 payload 內任何 identity。
3. 以 `stationId` 查 server-only registry，取得權威 `(x,y,z)`、owner、state 與 revision。
4. `getCell():getGridSquare(x,y,z)` 回 nil 時 fail closed。`getCell()` 的 Lua global exposure、dedicated server 的 square lookup 與未載入／無效 square 回 null 的出處：`LuaManager.java:5758-5764`、`IsoCell.java:3116-3124`、`ServerMap.java:629-647`。
5. 掃描該 square 的 `getObjects()` 時套用固定 inspect cap：超過 cap 立即轉 `SUSPENDED_CONFLICT`，只有在 list 未超限且掃描完成後，才能要求恰好一個符合交易站 class／sprite／name 形狀且仍存在世界中的物件。「只掃一格」本身不是成本上限。`getObjectIndex()` 只是當下 list index，不能當永久 ID。出處：`IsoGridSquare.java:9635-9637`、`IsoObject.java:4832-4834`、`IsoObject.java:5805-5807`、`media/lua/server/ClientCommands.lua:30-39`。
6. 驗證 actor square、同層、距離與 `canReachTo`。`DistToSquared(x,y)` 只算 XY，所以 Z 必須另外確認；`canReachTo` 限同層、相鄰格並檢查 window、door、wall 與 stair。出處：`IsoMovingObject.java:602-604`、`IsoGridSquare.java:841-862`。互動距離採原版近距離慣例的每軸不超過 1.6，再加 `canReachTo`；出處：`media/lua/shared/luautils.lua:138-142`。
7. 套用 SafeHouse policy，並確認目前 SafeHouse binding 未漂移。
8. 重查 station／offer revision、virtual escrow、seller、server price、tax 與買家餘額。
9. 依固定 lock order 取得 station、offer、buyer wallet、seller wallet、escrow claim；重查一次前置條件。
10. 執行 transaction，寫入 ledger 與 receipt，再回傳結果。任一步失敗都不得留下部分扣款或部分庫存移轉。

### 4.3 Station 狀態機

| 狀態 | 可購買 | 可管理 | 進入原因 | 離開條件 |
|---|---:|---:|---|---|
| `PROVISIONING` | 否 | 否 | 正在建立 registry 與世界錨點 | 全部成功後進 `ACTIVE`；失敗則 rollback |
| `ACTIVE` | 是 | 是 | 錨點、權限與 persistence 正常 | 暫停、權限漂移、錨點遺失、關站 |
| `PAUSED_OWNER` | 否 | 是 | owner 主動暫停 | owner 重新發布且所有 gate 通過 |
| `SUSPENDED_PERMISSION` | 否 | recovery only | SafeHouse binding 或 owner/member 權限不再符合 | 重新驗證後啟用，或轉 recovery／關站 |
| `SUSPENDED_OBJECT_MISSING` | 否 | recovery only | 權威位置找不到錨點 | 不自動綁到新位置；只允許 account owner recovery |
| `SUSPENDED_CONFLICT` | 否 | recovery only | 同格找到 0 個以外的歧義形狀或重複物件 | 人工排除衝突後重驗 |
| `RECOVERY_REQUIRED` | 否 | 領回 | codec、migration、delivery 或對帳失敗 | 所有 claims 被安全領回／補償 |
| `CLOSING` | 否 | 領回 | owner 安全關站 | transactions 與 claims 收斂後移除錨點 |
| `CLOSED` | 否 | 否 | 完成關站 | terminal；重新放置會取得新 `stationId` |

```text
PROVISIONING ──成功──> ACTIVE <──── owner 恢復 ──── PAUSED_OWNER
      │                  │  │
      └──失敗 rollback   │  ├── SafeHouse 漂移 ──> SUSPENDED_PERMISSION
                         │  ├── 錨點遺失 ────────> SUSPENDED_OBJECT_MISSING
                         │  ├── 物件歧義 ────────> SUSPENDED_CONFLICT
                         │  └── 安全關站 ────────> CLOSING ──收斂──> CLOSED
                         │
                         └── codec／migration／對帳失敗 ──> RECOVERY_REQUIRED
```

世界物件搬到別格時，舊位置會變成 missing；新位置的物件不會自動取得舊 `stationId`。重新綁定只允許明確的關站／重放流程，不能靠 object `modData` 或 client 座標認領。

### 4.4 Offer、claim 與 transaction 狀態

| Record | 狀態 | 意義 |
|---|---|---|
| Offer | `PREPARED` | 非 custody listing intent；source item 仍在賣家 inventory，不可搜尋、購買、claim 或 materialize |
| Offer | `CUSTODY_PENDING` | source capture 正在進行且不可購買；只有 seller capture gate 證明可恢復後才允許使用此狀態 |
| Offer | `ACTIVE` | 可被現場購買且存在唯一 escrow item |
| Offer | `BUYER_CLAIMABLE` | 已成交；escrow ownership 已轉買家，等待或重試 materialize |
| Offer | `SELLER_RETURNABLE` | 已取消／關站；escrow ownership 回賣家，等待領回 |
| Offer | `DELIVERED`／`RETURNED` | 實體物品已成功 materialize，terminal |
| Offer | `QUARANTINED` | codec、schema 或 type 失配；禁止重建，等待 recovery |
| Transaction | `PREPARED` | 已寫入非 custody 意圖與 before-state；不可視為 escrow ownership |
| Transaction | `COMMITTED` | wallet、ledger 與 escrow ownership 已完成同一 domain commit |
| Transaction | `MATERIALIZED` | 商品已放入目標 inventory；同一 claim 不可再次建立物品 |
| Transaction | `COMPENSATING` | 無法完成既定交付，使用新 ledger entry 補償，不改寫歷史 |

啟動時先 migration，再對每筆非 terminal transaction 依 `txId`、before／after revision 與可證明的 inventory mutation receipt 對帳。source item 仍存在時只能 abort intent；只有能證明 server 已完成 exact removal 時才能建立 escrow custody。單憑「目前找不到 item」不是 removal 證據；結果歧義時轉 `QUARANTINED`、停止相關經濟 mutation，不能由 snapshot 重建、重置資料或猜測成功。

### 4.5 中央錢包結算

- 報價只用 bounded non-negative integer「交易幣」。
- 畫面價格就是買家總支出；成交後 `sellerNet = price - salesTax`，`salesTax` 直接 burn。
- 可選刊登費於 offer 進入 `ACTIVE` 時扣除並 burn；失敗的 `PREPARED` 不收費。
- 賣家離線時仍可依 account key credit；不要求角色 inventory 或世界物件在線。
- 同一 `requestId` 重送只回原 receipt；同一 offer revision 最多 commit 一次。
- 社群幣不進這條結算路徑。若玩家先完成 server-defined 社群幣轉交易幣，後續交易站只看到中央錢包的新交易幣餘額。

## 5. 防濫用與安全

### 5.1 必守 invariant

- 同一商品在任一時點只能位於「玩家 inventory」、「virtual escrow」或「已 materialize 的 claim」其中一個 custody state。`PREPARED` snapshot 只是非 custody intent，可與 source item 共存，但永遠不可搜尋、購買、claim 或 materialize。
- 世界交易站容器永遠不是商品 SSOT；v1 不把商品實體放進可被 client 尋址的 world container。
- station owner、offer price、stock、SafeHouse binding、wallet 與 revision 只存在 server-private authoritative state；不得存入 client 可 request 的 `GlobalModData`。
- object `modData` 被清空、改寫或不同步時，不得改變任何交易結果。
- 錢包永不為負、不超過 cap；每次 debit、credit、burn、refund 都有唯一 ledger entry。
- 未完成現場物件、距離、可及性與 SafeHouse 驗證前，不得 reserve 庫存或扣款。
- station 不在 `ACTIVE`、offer 不在 `ACTIVE`、revision 不一致或 square 未載入時，一律拒絕購買。
- 刪除／搬走／破壞錨點只能停站，不能刪除 escrow 或自動把商品掉到世界。
- schema migration 失敗時停止 mutation，保留原資料與 recovery 線索。

### 5.2 威脅與對策

| 威脅／故障 | 對策 | 失敗時狀態 |
|---|---|---|
| 偽造 actor、seller、權限、價格或座標 | actor 取自 `OnClientCommand`；其餘由 registry／wallet／offer 重算 | 拒絕且零 mutation |
| 遠端購買、跨樓層、隔牆或隔門操作 | server 權威座標、同層、近距離、`canReachTo`、SafeHouse gate | 拒絕且刷新 station revision |
| double click、重送或 stale UI | account-scoped `requestId` cache、offer revision、相同 receipt | 首次結果重播，不再扣款 |
| 兩名買家搶同一商品 | 固定 lock order＋commit 前重查 offer revision | 恰一筆 `COMMITTED`，另一筆 stale |
| client 改世界物件 `modData` | object `modData` 只作可重建 marker；權威欄位不放其中 | 忽略 marker，必要時重建 projection |
| 直接拿空實體容器 | 商品不在 world container；交易站可無 container 或保持空 | escrow 不受影響 |
| 物件被正常搬動／拆除 | sprite 不設 `IsMoveAble`，建物設為不可拆／不可 thump 作 UX 防線 | 即時事件或 fresh resolve 轉 suspended |
| 物件被破壞或繞過一般 UI 移除 | 每次交易 fresh resolve；移除事件與 chunk 對帳只負責偵測 | `SUSPENDED_OBJECT_MISSING`，escrow 保留 |
| padlock／client UI 看似上鎖 | 不把 padlock 當授權；所有管理與購買仍走 server registry | packet 繞過 UI 也不能碰 escrow |
| SafeHouse owner/member 變更 | 每次 mutation 重查當下 SafeHouse；binding 不符即停站 | `SUSPENDED_PERMISSION` |
| 價格、頁碼、字串、snapshot 或 `modData` 過大 | schema hard cap、白名單欄位、有限 page、有限 offer／station 配額 | 拒絕並記一筆聚合安全事件 |
| 自己買自己的 offer／同帳號繞轉 | buyer account 與 seller account 相同時拒絕 | 零 mutation |
| item type 在更新後消失 | 啟動 migration／codec preflight；不再 materialize 未知 type | `QUARANTINED`／`RECOVERY_REQUIRED` |
| crash 發生於 storage save 邊界 | `PREPARED`／`COMMITTED`／claim 狀態與啟動對帳 | 停止或補償，不猜測成功 |

### 5.3 世界物件鎖定的證據界線

原版 moveable 判定取決於 sprite 的 `IsMoveAble`，正常 pickup 也會檢查容器是否為空。出處：`media/lua/shared/Moveables/ISMoveableSpriteProps.lua:67-124`、`media/lua/shared/Moveables/ISMoveableSpriteProps.lua:1083-1110`。交易站 sprite 不設 `IsMoveAble`，並以建物設定關閉一般 dismantle／thump，能阻止正常玩家 UI 路徑；相關原版建立形狀見 `media/lua/server/BuildingObjects/ISBuildUtil.lua:361-393`。

但這些只算 defense-in-depth。`OnObjectAboutToBeRemoved` 在真正移除前觸發，沒有證據顯示回傳值可 veto；原版 `SGlobalObjectSystem` 也把它當移除通知，並在 chunk 載入時清理缺失物件。出處：`IsoGridSquare.java:6090-6163`、`media/lua/server/Map/SGlobalObjectSystem.lua:169-174`、`media/lua/server/Map/SGlobalObjectSystem.lua:203-217`。所以安全性來自「錨點不是庫存」與 server recovery，而不是宣稱物件絕對不可破壞。

Padlock 同樣只作一般玩法提示。`isLockedToCharacter` 與 vanilla inventory UI 的禁用行為已有出處，但一般 container mutation 不能因此視為已授權。出處：`IsoThumpable.java:2493-2503`、`media/lua/client/ISUI/ISInventoryPage.lua:1729-1753`。

### 5.4 SafeHouse 政策

- 放置、上架、取消、改價、暫停與關站：必須同時是 station registry owner，且以 `safehouse:playerAllowed(serverDerivedUsername)` 證明為當下 owner／member。不得使用會包含 `CanGoInsideSafehouses` capability 的 `playerAllowed(IsoPlayer)` overload 來認定 ownership；出處：`SafeHouse.java:282-289`。v1 不定義管理員繞過。
- 購買：先確認 actor、square、object 都非 nil，再呼叫 `SafeHouse.isSafehouseAllowLoot(square, actor)`；若不允許即拒絕，不建立「交易站可穿透 SafeHouse」的例外。該 API 在 server option 允許 loot 時會直接通過，否則回到 interact 規則。出處：`SafeHouse.java:245-264`。
- SafeHouse 內部實際無法進入時，MOD 不替買家開門、不傳送、不繞過 trespass；目錄只告知位置與價格。
- 建站後 SafeHouse 消失、換 owner 或範圍改變時，binding 變化一律先停站，再由 owner 明確重新發布；SafeHouse 消失後不降級成無 ownership 的普通基地站點。
- owner 已失去現場 SafeHouse 權限時，不能管理世界錨點，但仍可透過 account-bound recovery inbox 領回自己的 escrow，避免新 SafeHouse owner扣押舊商品。

## 6. 資料模型

以下是 domain contract，不是已確認可直接照抄的 Lua table schema。

### 6.1 Records

| Record | 最少欄位 | 核心限制 |
|---|---|---|
| `StationRecord` | `stationId`, `ownerAccountKey`, `x`, `y`, `z`, `anchorShape`, `safehouseBinding`, `state`, `revision`, `catalogVisible` | `stationId` 由 server 配發；一格一站；object index／modData 不作 ID |
| `ListingIntent` | `intentId`, `stationId`, `sellerAccountKey`, `sourceItemId`, `sourceFingerprint`, `snapshot`, `state` | `PREPARED` 時非 custody、不可 materialize；bounded retention |
| `Offer` | `offerId`, `stationId`, `sellerAccountKey`, `unitPrice`, `status`, `revision`, `escrowId`, `catalogKey` | v1 一筆一件；`ACTIVE` 才必須有 escrow；價格為 bounded positive integer |
| `EscrowItem` | `escrowId`, `codecVersion`, `itemType`, `payload`, `fingerprint`, `ownerAccountKey`, `claimState` | 只在 custody 已證明轉移後建立；payload 只含允許 primitive／nested table，且有 byte／欄位 cap |
| `Wallet` | `accountKey`, `tradeBalance`, `communityBalance`, `version` | bounded non-negative integer；兩種貨幣不可混用 |
| `LedgerEntry` | `txId`, `accountKey`, `currency`, `delta`, `reasonCode`, `correlationId` | append-only；每次 balance 變更恰有一筆原因 |
| `TransactionRecord` | `txId`, `requestKey`, `state`, `beforeRevisions`, `afterRevisions`, `buyer`, `seller`, `gross`, `tax`, `offerId` | 可在 restart 後確定 resume、complete 或 compensate |
| `DeliveryClaim` | `claimId`, `escrowId`, `beneficiaryAccountKey`, `stationId`, `state`, `materializedItemRef` | ownership 先 commit；materialize exactly once |
| `RequestReceipt` | `accountKey`, `requestId`, `command`, `resultCode`, `txId`, `expiresAt` | bounded retention；重送回相同結果 |
| `CatalogEntry` | `catalogKey`, `stationId`, `location`, `unitPrice`, `offerRevision` | client 畫面只 render 位置與價格；不含私有 item payload |

### 6.2 庫存方案比較

| 方案 | 優點 | blocking 問題 | 判定 |
|---|---|---|---|
| 實體 world `ItemContainer` | 引擎能完整保存各 subtype 與巢狀內容 | 一般拿取與移除路徑不是交易授權；破壞會倒出庫存 | v1 不採 |
| bounded virtual escrow | 錨點消失仍可保留商品；domain model 不把 escrow 暴露給 client | Lua 端完整任意物品 codec 與 server-private persistence backend 都未證實 | v1 採用，但 codec 與 storage 都是 blocking gate |
| 實體＋虛擬鏡像 | 無法提供額外權威價值 | 兩份 SSOT 造成 crash 複製／遺失 | 禁止 |

### 6.3 Virtual escrow 序列化

`GlobalModData` 已證實會隨 dedicated world save 保存 table；`ModData.getOrCreate`、load／save 與 dedicated save cycle 的出處為 `ModData.java:20-49`、`GlobalModData.java:51-55`、`GlobalModData.java:218-299`、`ServerMap.java:408-412`。但它不是 server-private storage：任何已登入 client 都可依 tag 送出 request，server 會把對應整張 table 回給 requester。出處：`GlobalModDataRequestPacket.java:11-17`、`GlobalModDataRequestPacket.java:31-33`、`GlobalModData.java:153-205`。server 主動 `transmit` 也會傳出整張 table；出處：`GlobalModData.java:112-147`。因此「不呼叫 `transmit`」或使用難猜 tag 都不是保密邊界，escrow、wallet、ledger、receipt 與 account mapping 一律不得放進 `GlobalModData`。

本設計以抽象的 server-private `EconomyStore` 表示持久化邊界；其 production backend 尚未查證，是上線 blocking gate。backend 必須與目前 world save 隔離正確、client 不可 request／enumerate、支援 bounded primitive schema、版本遷移、故障後可判定的寫入語意，以及啟動對帳。未通過第 9、10 章 gate 前，不得以 `GlobalModData`、物件 `modData` 或可接觸的實體容器代替。

Kahlua table 存檔只保留 String／Double／Boolean／巢狀 table 等支援型別；不支援的 userdata 會被略過，因此不能把 `InventoryItem` 物件直接塞進 `modData`。出處：`KahluaTableImpl.java:210-230`、`KahluaTableImpl.java:379-400`。

每次上架的 codec gate：

1. 只在 actor root inventory 的固定 inspect budget 內解析 exact source item，並拒絕 nested、已裝備、已穿戴、已附掛或來源 ownership 不明的項目。
2. 檢查 item type、subtype、巢狀內容與允許欄位；未知欄位不做猜測式 fallback。
3. 產生有 schema version、欄位數、字串長度與總 payload cap 的 canonical snapshot。
4. 建立暫存物品，decode snapshot，再 re-encode。
5. 原 snapshot 與 canonical re-encode 完全相等才可繼續。
6. 持久化非 custody 的 `PREPARED` listing intent；此時 source item 仍是唯一 custody，snapshot 不得成為 `EscrowItem`。
7. 只有 seller capture gate 已證明 exact root item 的 detach、remove、sync 與 restart ordering 可恢復時，才能進入 `CUSTODY_PENDING`；移除成功且 durable custody 可證明後，才建立 `EscrowItem` 並 commit `ACTIVE` offer。
8. restart 時，source item 仍可證明存在就 abort intent；只有 durable removal 證據成立才可 promote。單看 item 缺席或只有 snapshot 都不成立；歧義一律 `QUARANTINED`，不得 materialize。

已找到的候選 server mutation 形狀包含 root／recursive ID lookup、`ItemContainer.Remove`、`sendRemoveItemFromContainer` 與原版 lookup→remove→sync 用例；出處：`ItemContainer.java:2032-2047`、`ItemContainer.java:3065-3092`、`LuaManager.java:12342-12353`、`media/lua/server/ClientCommands.lua:180-188`。但 `ItemContainer.Remove` 只處理手持引用，PZ 的其他 transaction 另行移除 attached／worn 狀態；出處：`Transaction.java:191-194`、`Transaction.java:211-223`。這些證據仍不構成跨 `EconomyStore` 與 player inventory save 的原子性，故維持 blocking。

初始白名單應從 actor root inventory 中狀態單純、未裝備／未穿戴／未附掛、非食物、非武器、非流體、非 drainable、非巢狀容器物品開始。每新增一種 subtype，都必須有 encode／decode／restart／cancel／purchase round-trip 證據後才開放。

### 6.4 世界錨點與 server projection

- `StationRecord` 才是 owner、位置與狀態 SSOT；世界物件的 name／sprite／`modData` 只是 projection。
- `stationId` 不放進需要 client 信任的 object `modData`。`ObjectModDataPacket` 只要求已登入，server 會載入收到的 table；因此 object `modData` 不可持有 owner、價格、stock、wallet、status 或 revision。出處：`ObjectModDataPacket.java:21-27`、`ObjectModDataPacket.java:50-72`、`ObjectModDataPacket.java:94-96`。
- server 以 registry 座標與固定 anchor shape 重解析；v1 限制一格一站，避免缺少穩定 engine GUID 時產生歧義。
- 可使用 `SGlobalObjectSystem` 的物件事件與 chunk liveness 機制作 projection，但不能沿用「錨點消失就刪 record」的預設行為保存 escrow；出處：`media/lua/server/Map/SGlobalObjectSystem.lua:169-174`、`media/lua/server/Map/SGlobalObjectSystem.lua:203-217`。

## 7. 效能

### 7.1 查詢與同步

- 以 `catalogKey -> price-sorted station references` 建立 in-memory inverted index；上架、售出、取消、停站才增量更新。
- 不掃全世界 square、world objects、containers 或所有 item snapshot 來回答搜尋。
- 搜尋只接受 bounded query 與 cursor；server 限制 page size、每玩家查詢頻率與同時 pending request。
- 搜尋結果只回 location、unit price、必要的 opaque IDs／revision，避免傳輸完整 item payload。
- 現場 UI 只訂閱該 station revision；視窗關閉、離開距離或 heartbeat timeout 即退訂。
- mutation burst 合併成單次 catalog revision push；交易 receipt 不等待全域 catalog 重建。

### 7.2 世界物件與權限檢查

- 每次現場 mutation 只查 registry 指定的一格，不做半徑或全地圖搜尋；但該格 `getObjects()` 沒有已證實的 hard cap，所以逐物件檢查另有 `MAX_ANCHOR_OBJECTS_INSPECTED`。到達 cap 尚未完成掃描時即拒絕並轉 `SUSPENDED_CONFLICT`。
- `ListItem` 只掃 actor root inventory，且每個 request 受 `MAX_SOURCE_ITEMS_INSPECTED` 約束；v1 不遞迴 nested containers。`getItemWithID`／`getItemWithIDRecursiv` 都是線性掃描，而 `ItemNumbersLimitPerContainer` 可為 0，不能假設 inventory 天然有界。出處：`ItemContainer.java:3065-3092`、`ServerOptions.java:165-167`。
- rate limit、pending request cap 與 inspect budget 同時存在：前兩者限制請求數，inspect budget 限制單一惡意不存在 ID 或異常 square 的成本。
- `OnObjectAboutToBeRemoved`／chunk load 只更新受影響 station；不建立全服每 tick scanner。
- SafeHouse 權限在所有 mutation fresh-check；背景漂移稽核採 bounded batch，不能每 tick 掃全部站點。
- catalog 可短暫保留 stale discovery entry，但到場交易永遠 fresh-check；安全不依賴背景掃描即時性。

### 7.3 記憶體、存檔與 log

- account、station、offer、snapshot bytes、nested depth、字串長度、idempotency receipt、ledger preview、subscriber 與 recovery queue 全部有 hard cap。
- virtual escrow 不保存任意整份 `modData`；只保存 codec allowlist 欄位。
- dirty state 可 coalesce，但已進 `PREPARED`／`COMMITTED` 的 transaction 有更高保存優先；確切 flush／crash semantics 仍是第 10 章 gate。
- escrow、wallet、ledger、receipt 與 account mapping 不進入 `GlobalModData` 或其他 client 可 request 的 table；catalog 與 receipt 只透過 server command 回傳裁切 DTO。
- audit 採一筆 transaction 一行的聚合事件，不逐 item field 或每 frame 寫 log。
- server 達到 station／offer／snapshot cap 時拒絕新上架，不以無界 Kahlua table 換取可用性。

## 8. Discord 積分兌換介面

Discord 積分兌換與交易站是兩條信任方向不同的流程。交易站只讀中央錢包的交易幣；外部系統不能直接指定 offer、seller、station、商品交付或交易幣餘額。

### 8.1 Inbound domain 介面

外部 adapter 只提交已驗證、可重放的兌換事件；實際 transport 與 authentication mechanism 尚待查證。建議 domain payload：

| 欄位 | 語意 | 限制 |
|---|---|---|
| `protocolVersion` | adapter contract 版本 | 未知版本拒絕 |
| `externalTxId` | 外部扣點交易唯一 ID | exactly-once key；不可重用 |
| `linkRef` | 已完成綁定的外部 identity reference | 不接受 client 自報遊戲帳號 |
| `pointsDebited` | 外部已扣除的正整數積分 | bounded；只供 server 套用自己的兌換規則 |
| `occurredAt` | 外部事件時間 | 只供 expiry／audit，不作唯一性依據 |

流程：

1. 外部系統先完成積分扣除，產生唯一 `externalTxId`。
2. adapter 將 authenticated event 送入 server-side `DiscordExchangeAdapter`。
3. game server 驗證 protocol、identity link、expiry、每日上限與 `externalTxId` 是否已處理。
4. game server 依自己的比率 credit「社群幣」，寫 `discord:<externalTxId>` ledger correlation key。
5. 重送相同事件只回原 receipt，不再加幣。
6. 玩家若要取得交易幣，另走遊戲內 server-defined、單向、限額的 `CommunityToTrade` command；完成後交易站仍只結算交易幣。

### 8.2 回應狀態

| 狀態 | 意義 |
|---|---|
| `CREDITED` | 第一次成功 credit，回傳 game `txId` |
| `DUPLICATE` | `externalTxId` 已處理，回傳相同結果 |
| `REJECTED_LINK` | identity link 不存在或不一致，零 mutation |
| `REJECTED_LIMIT` | 超過 server cap，零 mutation；外部補償政策由 adapter contract 決定 |
| `PENDING_RETRY` | game server 尚未 commit，可安全以同一 ID 重試 |
| `QUARANTINED` | payload／版本／對帳異常，需人工處理 |

社群幣保持 account-bound，不可在玩家交易站報價、轉給其他玩家或反向兌回 Discord 積分。Optional Discord sale notification 是 outbound 功能，不能和 inbound credit 共用模糊的信任邏輯，也不阻擋交易站核心上線。

## 9. 實作複雜度與風險

### 9.1 複雜度

整體複雜度為高，真正的 blocking work 是「server-private persistence、無損 item round-trip、跨 crash transaction recovery、世界錨點不可信時的 custody 分離」，不是 UI。

| 工作包 | 相對複雜度 | 主要產物 |
|---|---:|---|
| Server-private `EconomyStore` | XL | world-scoped persistence、migration、fault recovery、client isolation |
| 中央錢包／ledger／idempotency | L | 整數帳本、receipt、lock order、reconciliation |
| 世界錨點與 SafeHouse lifecycle | L | placement、fresh resolve、suspended／recovery states |
| `ItemCodec` 白名單 | XL | 每 subtype round-trip、migration、payload cap |
| Virtual escrow／delivery claim | XL | no-loss/no-dupe、offline return、exactly-once materialize |
| 全服目錄與現場 UI | M | location／price index、local detail、owner UI |
| 觀測與管理 recovery | L | audit、quarantine、人工補償與領回 |
| Discord inbound adapter | XL；獨立階段 | identity link、external id、transport、重放測試 |

### 9.2 主要風險與 gate

| 風險 | 等級 | 緩解 | 上線 gate |
|---|---|---|---|
| 尚無已證實的 server-private persistence backend | Blocking | `GlobalModData` 明確排除私密資料；先查證 `EconomyStore` backend | 已登入 client 無法 request／enumerate 私密 table，且 world 隔離、restart、migration 全綠 |
| Seller inventory capture 與 storage commit 無原子／可恢復證據 | Blocking | `PREPARED` 僅作非 custody intent；root-only、未裝備項目、`CUSTODY_PENDING`、歧義 quarantine | detach／remove／sync／restart fault injection 後恰有一個 custody owner，無遺失、無重建複製 |
| Lua 無法使用完整引擎 item codec | Blocking | v1 白名單手動 codec；未知型別拒絕 | 每個開放 subtype 的 round-trip／restart／cancel／buy 全綠 |
| engine save 分層、無跨區 crash atomicity 證據 | Blocking | `PREPARED`／`COMMITTED`／compensation＋啟動對帳 | fault injection 後無負餘額、無雙份 item、無遺失 claim |
| 世界物件可被搬走／破壞／移除 | High | 錨點與 custody 分離、fresh resolve、events、recovery | 物件消失只停站，escrow 可完整領回 |
| SafeHouse owner/member／範圍漂移 | High | binding＋每次 mutation 重查＋bounded audit | 權限變更後無新成交，舊 owner 可 recovery |
| buyer delivery／seller return／recovery materialize 失敗或重送 | High | account-bound beneficiary claim、exactly-once receipt | 斷線／重連／背包滿／重送仍只建立一件，且所有 beneficiary 路徑一致 |
| MOD 更新使 item type／欄位失配 | High | codec version、migration、quarantine | 未知 type 不自動 fallback 成新物品 |
| 全服搜尋造成 CPU／記憶體壓力 | Medium | inverted index、pagination、配額、rate limit | 大量站點下查詢成本不隨世界物件總量掃描 |
| 單次 item／square re-resolution 掃描放大 | High | root-only source、inventory／object inspect caps、超限 fail closed | 不存在 ID、超量 inventory／square 下單次成本仍受硬上限約束 |
| 公開 SafeHouse 位置引發騷擾 | Medium | 預設不公開、明確 opt-in、可隨時停站 | 未 opt-in 的站點不出現在目錄 |
| Discord transport／identity link 不成熟 | High，但不阻擋交易站核心 | feature flag、獨立 adapter、exactly-once | 未完成前保持兌換關閉 |

### 9.3 建議實作順序

1. 先查證 dedicated MP 的穩定 account identity 與 server-private `EconomyStore`；未通過前不實作可上線的中央錢包或 escrow。
2. 原型化單格世界錨點：放置、正常關站、強制移除、SafeHouse 漂移與 chunk reload。
3. 在選定 backend 上完成中央錢包、ledger、request id 與 restart reconciliation。
4. 完成最小白名單 `ItemCodec` 與 virtual escrow；不先做 UI 美化。
5. 完成 seller offline sale、buyer claim、seller return、anchor missing recovery。
6. 加入全服 location／price index 與現場 UI。
7. 以兩名買家競爭、重送、斷線、server restart、物件消失、權限變更、codec mismatch 做 adversarial MP 驗證。
8. 核心穩定後才啟用 Discord exchange；拍賣、bundle 與更多 item subtype 另案處理。

## 10. 待查證 API 清單

本章同時列出已找到的 API 證據與真正的「待查證」項目，避免後續實作者把設計概念誤當成可直接呼叫的 PZ API。

### 10.1 已查證，可作設計依據

| 能力／行為 | 證據 | 設計限制 |
|---|---|---|
| client command 與 server-derived actor | `GameClient.java:1839-1855`、`GameServer.java:2247-2267`、`GameServer.java:2292-2298` | actor 取 event player；payload identity 不可信 |
| server 對指定玩家回傳 command | `LuaManager.java:8928-8945`、`GameClient.java:1060-1068` | 只回 bounded DTO／receipt |
| dedicated square lookup | `LuaManager.java:5758-5764`、`IsoCell.java:3116-3124`、`ServerMap.java:629-647` | nil／未載入即 fail closed |
| square object 掃描與 object existence | `IsoGridSquare.java:9635-9637`、`IsoObject.java:5805-5807` | 只掃 registry 指定的一格仍須自設 inspect cap，未證實 list 有硬上限 |
| object index 不穩定 | `IsoObject.java:4832-4834`、`media/lua/server/ClientCommands.lua:30-39` | 不作持久 `stationId` |
| XY 距離與相鄰可及性 | `IsoMovingObject.java:602-604`、`IsoGridSquare.java:841-862`、`media/lua/shared/luautils.lua:138-142` | 另驗 Z；v1 限同格／相鄰格 |
| SafeHouse 查詢、owner／member 與 loot gate | `IsoPlayer.java:6445-6447`、`SafeHouse.java:157-159`、`SafeHouse.java:245-264`、`SafeHouse.java:282-289`、`SafeHouse.java:665-670` | owner/member 用 String overload；IsoPlayer overload 另含 capability；loot gate 不等於 station owner |
| 建立世界物件的原版形狀 | `media/lua/server/Camping/SCampfireGlobalObject.lua:69-76`、`media/lua/server/BuildingObjects/ISWoodenContainer.lua:3-25` | 可作 prototype，最終 station placement 流程仍需實機驗證 |
| moveable／一般拆解 UX 設定 | `media/lua/shared/Moveables/ISMoveableSpriteProps.lua:67-124`、`media/lua/server/BuildingObjects/ISBuildUtil.lua:361-393` | 只算 defense-in-depth，不是 server authorization |
| 移除與 chunk liveness 通知 | `IsoGridSquare.java:6090-6163`、`media/lua/server/Map/SGlobalObjectSystem.lua:160-174`、`media/lua/server/Map/SGlobalObjectSystem.lua:203-217` | 可偵測，不宣稱可 veto；不可連帶刪 escrow |
| object `modData` 可被 client 更新 | `ObjectModDataPacket.java:21-27`、`ObjectModDataPacket.java:50-72`、`ObjectModDataPacket.java:94-96` | owner、價格、庫存、權限不可放其中 |
| world container 完整保存 | `IsoObject.java:1203-1244`、`IsoObject.java:1446-1462`、`ItemContainer.java:2418-2444`、`InventoryItem.java:3376-3385` | fidelity 高，但不是安全 escrow |
| 一般 world container 不是交易授權邊界 | `IsoObject.java:5274-5279`、`RemoveInventoryItemFromContainerPacket.java:20-26`、`RemoveInventoryItemFromContainerPacket.java:99-116`、`IsoObject.java:5747-5761` | v1 world container 保持空／不存在 |
| `GlobalModData` 會隨 world save 保存 | `ModData.java:20-49`、`GlobalModData.java:51-55`、`GlobalModData.java:218-299`、`ServerMap.java:408-412` | 只證明 persistence，不代表 server-private |
| 已登入 client 可 request `GlobalModData` 整張 table | `GlobalModDataRequestPacket.java:11-17`、`GlobalModDataRequestPacket.java:31-33`、`GlobalModData.java:153-205` | escrow、wallet、ledger、receipt、account mapping 禁止存入 |
| `GlobalModData.transmit` 會廣播 table | `GlobalModData.java:112-147` | 不主動 transmit 仍擋不住 client request |
| Kahlua table 可保存型別有限 | `KahluaTableImpl.java:210-230`、`KahluaTableImpl.java:379-400` | `InventoryItem` userdata 不能直接持久化 |
| Java 內部完整 item codec 存在 | `InventoryItem.java:1660-1869`、`InventoryItem.java:1872-1940`、`InventoryItem.java:3376-3385` | 不能因此推論 Lua 可完成 ByteBuffer round-trip |
| `instanceItem` 只建立新 item | `LuaManager.java:5598-5628`、`InventoryItemFactory.java:26-209` | 不足以證明完整狀態還原 |
| player inventory ID lookup／remove／sync 候選形狀 | `ItemContainer.java:2032-2047`、`ItemContainer.java:3065-3092`、`LuaManager.java:12342-12353`、`media/lua/server/ClientCommands.lua:180-188`、`Transaction.java:191-194`、`Transaction.java:211-223` | lookup 為線性；Remove 不完整處理 worn／attached；不證明 storage crash atomicity |
| container item count 可無限制 | `ServerOptions.java:165-167` | rate limit 不能替代每 request inspect budget |

### 10.2 待查證，未通過前不得宣稱可用

| 待查證項目 | 為何是 gate | 最小證據要求 |
|---|---|---|
| 待查證：dedicated／nosteam 下穩定 account key | wallet、owner、offline settlement 都依賴它 | matching Java 宣告＋實機重連／改名／重啟矩陣 |
| 待查證：真正 server-private、world-scoped 的 `EconomyStore` persistence backend | `GlobalModData` 可被已登入 client 依 tag 讀取，不能承載私密經濟狀態 | matching API／實作出處＋證明 client 無法 request／enumerate＋world 隔離、restart、migration、容量上限實測 |
| 待查證：非 SafeHouse「自有基地」的 server-authoritative ownership／base binding | B42 SafeHouse 證據不能證明一般世界位置屬於該玩家 | matching API 或獨立 server registry 契約＋重疊 claim、轉移、刪除、重啟與權限實測；未通過前 v1 拒絕 |
| 待查證：seller root inventory 的 authoritative re-resolution、detach、remove、sync 與 restart ordering | `PREPARED` snapshot 非 custody；沒有可證明 capture 結果就不能建立 virtual escrow | 正確 source container、root-only、未裝備／未穿戴／未附掛規則＋斷線、重送、crash fault injection；每次最終恰有一個 custody owner |
| 待查證：交易站 custom object 的完整 server placement／rollback／sync API | 原版形狀存在，但本 MOD 的 kit 消耗與 object 建立需一致 | 原版 Lua／Java 出處＋兩 client 實機同步 |
| 待查證：server 端 per-object 不可移動、不可拆解、不可破壞、不可移除的權威 gate | 現有 flag 只證明正常 UI 行為 | 找到 server 驗證點或證明不存在；不能以 UI 隱藏代替 |
| 待查證：`OnObjectAboutToBeRemoved` 是否有 veto 機制 | 目前證據只顯示通知後繼續移除 | matching Java 讀取回傳值的出處；找不到則維持偵測-only |
| 待查證：跨 reload 穩定的 engine world-object GUID | `getObjectIndex()` 不穩定 | matching API＋object list 重排／重啟實測；否則維持 registry ID＋座標形狀 |
| 待查證：SafeHouse 穩定 identity、owner/member／範圍變更事件 | binding drift 需要低成本即時更新 | Java event／revision 出處；找不到則每次 mutation 重查＋bounded audit |
| 待查證：dedicated server Lua 可用的 LOS API | `canReachTo` 已足夠 v1，相鄰外 LOS 不能憑記憶 | vanilla Lua 用例或明確 Lua exposure；不得用 client lighting 當授權 |
| 待查證：Lua 可呼叫完整 `InventoryItem.saveWithSize`／`loadItem` 的 ByteBuffer round-trip | 任意 MOD item fidelity 的 blocking gate | ByteBuffer 建立／讀寫 exposure＋vanilla 用例＋多 subtype 實測 |
| 待查證：各白名單 subtype 的完整 getter／setter 與保存欄位 | 手動 codec 不能漏 condition、uses、fluid、food、weapon 等狀態 | 每 subtype matching Java save/load＋Lua exposure＋canonical round-trip |
| 待查證：server-only、client 不可尋址但由引擎持久化的 `ItemContainer` | 可能是未來取代手動 codec 的候選 | 建立、保存、重載、不可被封包定位的完整證據 |
| 待查證：選定 `EconomyStore` 與 world save 的 flush、atomic replace 與 crash ordering | 目前沒有可用的 private backend，也沒有跨資料區 transaction atomic 證據 | 選定 backend 的 save 順序、檔案替換語意與故障注入結果 |
| 待查證：beneficiary inventory materialize 與同步的 exactly-once 序列 | 買家交付、賣家取消領回與 recovery claim commit 後都須安全建立並同步實體物品 | 所有 beneficiary 路徑的原版 server mutation／sync 出處＋斷線、重送、背包滿、restart 實測 |
| 待查證：世界地圖 marker／位置 label API | 目錄 wireframe 可先用文字座標，不得憑記憶加地圖整合 | matching vanilla Lua／Java 用例；查不到就不做 marker |
| 待查證：Discord identity link 與 authenticated inbound transport | 外部兌換 exactly-once 依賴，但不阻擋交易站核心 | 選定 transport 的官方／本機實作證據＋重放、過期、斷線測試 |

在上述 blocking 項未獲得 matching 42.20.4 證據前，設計中的 `EconomyStore`、seller capture、非 SafeHouse base binding、`ItemCodec`、crash recovery、placement rollback、map marker 與 Discord inbound 都只是 domain contract，不代表對應 PZ API 已存在。
