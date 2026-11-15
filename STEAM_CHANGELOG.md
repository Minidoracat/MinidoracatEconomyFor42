[h1]Minidoracat Economy for B42 42.22.2-0.28.0[/h1]
[i]2026-11-16[/i]

[b]English summary[/b]
[list]
[*] When the host changes a rental plan (rent, currency, days per period, stops rentals or turns auto-renew off), your auto-renew pauses and you now get a notice: when it pauses, before the end, when it is due, halfway through grace, and when the lease ends. While it stays paused you are also reminded at every login until you agree, renew by hand, turn auto-renew off or the lease ends. If the plan goes back to your terms you are told it resumed.
[*] A lease whose auto-renew stayed paused now ends when grace ends, even if you are offline, and the slot is freed. Nothing is charged later, even if the old terms come back. Rent again to keep using it.
[*] Players who were offline get the notice the next time they log in (within 30 days).
[*] Admins: the integration plans page shows how many auto-renewals are waiting for players to agree to changed terms.
[/list]

[h3]✨ 新增[/h3]
[list]
[*] [b]租用方案改了會通知你[/b]：服主改了租金、幣別或每期天數，或停售租用、關閉自動續租時，你的自動續租會暫停扣款，現在會跳出提示：暫停時、到期前提醒時、到期沒續租時、寬限過半與租約失效時各一次；自動續租還停著的期間，每次上線也會再提醒一次，直到你重新同意、手動續租、關掉自動續租或租約失效。方案改回你同意的條款時，也會告訴你已恢復。不在線的玩家上線後會看到當時的最新狀態。
[*] [b]要照新方案繼續租[/b]：到賣這個名額的 MOD（例如安全屋、車輛管理）重新同意；如果是伺服器停止了自動續租，請改用手動續租。
[*] [b]管理員[/b]：「整合方案」頁會顯示有幾張自動續租在等玩家重新同意；支援的 MOD 可以在存方案前先告訴管理員這次會暫停幾張。
[/list]

[h3]• 調整[/h3]
[list]
[*] [b]一直沒重新同意的租約，寬限結束就失效[/b]：以前會一直掛著「自動續租暫停」，服主之後把方案改回原本的條款時，系統會突然替你扣款續租。現在寬限結束就失效並移除，不在線的玩家也一樣，名額會釋出；30 天內上線會收到失效通知。之後方案怎麼改都不會再扣這張的錢，要繼續使用請重新租用。
[*] 更新後第一次上線時，如果你有在方案變更後就已經失效的舊租約，會收到一則「租約已失效」的提示，只會出現一次。
[/list]
