[h1]Minidoracat Economy for B42 42.22.2-0.28.1[/h1]
[i]2026-11-25[/i]

[b]English summary[/b]
[list]
[*] A rental with less than two days left now shows the hours left (for example "36 hours") instead of "1 days".
[*] Polish: the days left now read "29 dni" instead of "Dni: 29".
[*] Hosts: a hand-edited catalog.json or whitelist.json saved as "UTF-8 with BOM" (Notepad, PowerShell) now loads instead of being refused as a JSON error.
[/list]

[h3]• 調整[/h3]
[list]
[*] [b]租約的剩餘時間不到兩天時改用小時顯示[/b]：以前剩 1 天多會寫成「1 天」，英文、德文、法文、西班牙文、葡萄牙文、波蘭文會出現「1 days」這類單複數不合的寫法；現在不到兩天時顯示小時數（例如「剩 36 小時」），兩天以上照舊顯示天數。其他 MOD 的租用名額視窗用同一種寫法時也會一起改
[*] [b]波蘭文的剩餘天數改成能放進句子的寫法[/b]：「Dni: 29」改為「29 dni」
[/list]

[h3]🔧 修正[/h3]
[list]
[*] [b]服主手改的商店目錄與白名單檔存成「UTF-8 含 BOM」時不再被當成格式錯誤[/b]：Windows 記事本、PowerShell 等工具存檔時常在檔案開頭加上這個看不見的標記。以前整份檔會被拒收：執行中改檔時照舊沿用原本的設定，開服時讀到則商店沒有商品、白名單沒有可交易的物品；管理台只顯示 JSON 錯誤，看不出是編碼造成的。現在檔案開頭有沒有這個標記都能正常套用
[/list]
