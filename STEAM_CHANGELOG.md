[h1]Minidoracat Economy for B42 42.22.2-0.27.0[/h1]
[i]2026-11-15[/i]

[b]English summary[/b]
[list]
[*] New sandbox option for server hosts, "Old copies the server cannot verify": after a crash recovery, choose what happens to an old copy of an item that was already listed, auctioned or sold when it sits in another account's hands or the server cannot confirm it is the very item: leave it as an ordinary item (default), hold it for administrators, or take it back automatically.
[*] Behaviour change: 0.26.0 and earlier always took such copies back. After this update the default leaves them in place; set the option to "Take back automatically" to keep the old behaviour.
[*] An old copy of the very item the same account transferred is still taken back at login, as before.
[*] Stronger checks on delivered items and crash recovery.
[*] Fixed: the server log no longer shows an item sync error right after a player logs in. Items and money were never affected.
[/list]

[h3]✨ 新增[/h3]
[list]
[*] [b]服主可以選擇怎麼處理「伺服器無法確認的舊副本」[/b]：伺服器崩潰回復後，玩家身上偶爾會留著一件已經上架、拍賣或賣出的物品舊副本。舊副本在別的帳號手上，或伺服器無法確認就是轉出的那一件時，由新的沙盒選項決定，共三檔：
[list]
[*] [b]當成一般物品（預設）[/b]：不移除，物品照常使用與交易；只有伺服器的紀錄不足以判斷的副本會先列入待對帳。
[*] [b]交給管理員對帳[/b]：不移除，在管理員的待對帳清單留一筆紀錄，這件物品暫時不能再經由經濟系統轉出；管理員可以在那筆紀錄按「移除」逐件收回。
[*] [b]自動收回[/b]：伺服器直接收回。
[/list]
[*] 後兩檔收回的物品都會保留快照，管理員可以從稽核紀錄把它寄回。
[*] 這個選項也可以在遊戲內「經濟管理台 → 設定」直接改，不用重啟。
[/list]

[h3]🔄 變更[/h3]
[list]
[*] [b]升級後預設不再自動收回上面那類舊副本[/b]：0.26.0 和更早的版本一律自動收回；想維持原本的做法，請把選項改成「自動收回」。
[*] 更新前就已經轉出的物品，它們的舊副本在預設值下會先列入待對帳，不會自動收回。
[*] 同一個帳號轉出的同一件物品，舊副本照舊在登入時自動收回；穿在身上、掛在腰帶上或裝著東西的背包類物品不會被自動收回，改列入待對帳。
[*] 強化了交付物品來源與崩潰回復對帳的驗證。
[/list]

[h3]🔧 修正[/h3]
[list]
[*] 玩家剛登入時，伺服器紀錄檔偶爾出現一段物品同步失敗的錯誤。物品與錢都不受影響，現在不再出現。
[/list]
