[h1]Minidoracat Economy for B42 42.22.2-0.26.0[/h1]
[i]2026-11-12[/i]

[b]English summary[/b]
[list]
[*] New for server hosts: edit the shop catalog file or the listing whitelist file on the server and it takes effect by itself within about half a minute. No restart, no Reload button.
[*] A file with a mistake leaves the current settings in place; the reason shows on the Shop or Listing whitelist page of Economy Administration when you reopen it.
[*] Orders sent from a screen that still shows the old prices are refused instead of going through at the new price.
[*] Fixed: a list written in the wrong format in either file could be read as "no items" or "no categories"; it is now refused.
[/list]

[h3]✨ 新增[/h3]
[list]
[*] [b]服主直接改伺服器上的商店目錄檔或上架白名單檔，不用重啟也不用按「重新載入」[/b]：改好存檔後，伺服器大約半分鐘內會自己套用，在線玩家的商店畫面跟著更新。管理台的「重新載入」按鈕照舊可用，按了立刻生效。
[*] 檔案內容有錯時，伺服器繼續用原本的設定；錯誤原因在重新打開管理台的商店頁或白名單頁時看得到，改好再存一次就會套用。
[*] 玩家畫面還停在舊價格時送出的購買或出售會被擋下，不會用新價格成交。
[/list]

[h3]🔧 修正[/h3]
[list]
[*] 手改檔案時把商品清單或分類清單寫錯格式，以前可能被讀成「沒有任何商品」或「沒有任何分類」；現在會被拒收並沿用原本的設定。
[*] 白名單檔存在但伺服器暫時讀不到時，不會再被預設內容蓋掉。
[/list]
