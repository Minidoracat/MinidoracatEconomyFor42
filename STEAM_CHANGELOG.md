[h1]Minidoracat Economy for B42 42.22.2-0.25.0[/h1]
[i]2026-11-10[/i]

[b]English summary[/b]
[list]
[*] Confirmed working on game version 42.22.2; 42.20.4 and later are still supported.
[*] Fixed: hand-built radios, ham radios and walkie-talkies lost their own range, band, volume range and battery drain after going through the market, an auction or the mailbox. Ones already listed or sitting in a mailbox before this update still come back with stock values.
[*] Fixed: a radio's saved channels were replaced by a random new list after a trade.
[*] Fixed: brand-new radios and walkie-talkies could not be sold back to the shop or delivered to "New only" buy orders.
[*] Changed: radios are sold to the shop in lots with the same tuned and saved channels, and maps one area at a time. The sell window says how many more can be sold afterwards; new radios mostly go one by one.
[*] New for admins: custom shop categories ("Custom category..." in Economy Administration - Shop).
[/list]

[h3]✨ 新增[/h3]
[list]
[*] [b]商店商品可以自訂分類[/b]：管理員在「經濟管理台 → 商店」編輯商品時，分類下拉最後多了「自訂分類...」，打好名字按套用就行，批量編輯也一樣；以前要手改伺服器上的目錄檔。玩家商店的分類篩選會列出新分類；名字和內建分類相同時歸到內建分類。
[/list]

[h3]🔄 變更[/h3]
[list]
[*] [b]對應遊戲 42.22.2[/b]：已在 42.22.2 實機確認商店、市場、拍賣、求購單、信箱、轉帳、終端與交易站電台都正常，最低支援版本維持 42.20.4。遊戲 42.22 起，雙手搬著發電機這類重物時按攻擊會先把東西放到地上；這是原版的新規則，與本模組無關。
[/list]

[h3]🔧 修正[/h3]
[list]
[*] [b]自己組裝的收音機、業餘無線電、對講機，交易後變成普通的機器[/b]：手工機的發射距離、頻率範圍、音量範圍和耗電會依電子技能而不同。以前經過市場、拍賣或信箱後，這些數值會變回原版預設。現在數值跟著機器走，數值不同的不會合併，商品說明也會寫出來。更新前已經掛在市場、拍賣或信箱裡的手工機，領回時仍是預設值。
[*] [b]收音機存的頻道清單，交易後被換成另一份[/b]：以前收音機經過市場、拍賣或信箱後，存的頻道會換成隨機的新清單。現在會照伺服器上存的那份原樣回來。多人模式下遊戲只同步「拿在手上的收音機」，刪掉的頻道在伺服器上還留著，所以回來的清單可能比面板上看到的多幾筆；這是原版的行為。
[*] [b]全新的收音機、對講機賣不回系統商店，也交不了「只收全新」的求購單[/b]：以前沒動過的新機會被說和全新的不一樣，因為遊戲給每台新機各挑不同的頻道。現在判斷新舊時不看頻道；電量、電池、開關、音量不同的照樣不收，手工組裝的也不收，並會說明原因。
[*] [b]賣收音機、地圖給商店時要分批[/b]：一次賣的每一台，調到的頻道和存的頻道要相同，地圖要同一個區域。出售視窗的可賣數量只算這一批，其餘能賣的另外寫出件數，賣完這批再賣；新機多半各不相同，會是一台一台賣。
[*] [b]一般玩家的建造視窗可能顯示管理員專用的經濟終端[/b]：在物品上按右鍵選「顯示相關的建造配方」時，右邊的說明欄有時會選到它。伺服器一直都會拒絕，蓋不出來、材料也不扣。現在會改選清單上看得到的第一個配方。
[*] [b]經濟管理台商店頁的錯誤訊息，取消後還留在頁面底下[/b]：以前「套用變更」被擋下後按取消或改開別的商品，那行錯誤還在。現在離開或重新開始表單時會一起清掉。
[/list]
