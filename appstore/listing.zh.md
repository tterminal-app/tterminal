# App Store 商店資料(繁體中文)

貼到 App Store Connect 用。字數上限寫在標題後面。

## 名稱(30)

tterminal

## 副標題(30)

打中文不出包的 SSH 終端機

## 宣傳文字(170)

下載免費,14 天內所有功能都能用,喜歡再一次買斷。用注音、倉頡打中文,不會打到一半整串不見。

## 描述(4000)

在手機上用 SSH 打中文,很容易遇到這些事:注音打到一半整串消失、同一個字被送出去兩次、中文檔名讓整個畫面排歪。tterminal 一開始就是為了解決這些問題做的。

組字會直接顯示在游標上,選好字才送出去。注音、倉頡、拼音、日文輸入法都能用。

其他終端機該有的也都有。htop、vim、tmux 這類全螢幕程式照常跑,捲動很順。鍵盤上方多一排 esc、ctrl、tab 和方向鍵,^C、^D 按一下就送出;長按畫面再拖曳,可以當方向鍵用。登入可以用密碼或金鑰,金鑰也能直接在 app 裡產生。第一次連線會記住主機指紋,之後對不上的話,會先停下來讓你看差在哪,確認了才連。

切出去回個訊息再回來,連線通常還在,app 在背景時,動態島也會顯示目前掛著幾條連線。不過 iOS 給背景的時間有限,離開太久還是會斷。

想讓 iPhone 和 iPad 用同一份主機清單,可以自己架同步伺服器,一個 docker 指令就能跑起來。資料在手機上就先加密才送出去,伺服器存的只有密文。比較建議放在家裡的 NAS 或小主機,不要開到外網,出門時用 VPN 連回去。伺服器的程式碼在 GitHub 上公開。

在 iPad 或展開的 iPhone Duo 上,畫面會分成兩欄:左邊是連線,右邊是終端機。

下載免費,14 天內什麼都能用。之後想繼續開新連線,買斷一次就好,1.x 的更新都包含在內,沒有訂閱也沒有廣告。就算沒買,主機清單和同步也都還在。app 不收集任何資料,也不用註冊帳號。

手機版目前還沒有檔案瀏覽(SFTP)和 mosh。想要什麼功能,歡迎到 GitHub 開 issue。

## 關鍵字(100,逗號分隔,不用重複名稱與副標題裡的字)

terminal,tmux,vim,linux,遠端連線,伺服器,主機,金鑰,shell,命令列,注音,倉頡,devops,raspberry pi

## 這個版本的新內容

第一版上架。

## 其他欄位

- 類別:開發者工具(主要)、工具程式(次要)
- 版權:© 2026 tterminal
- 年齡分級:問卷全部選「無」,應為 4+
- App 隱私權:不收集資料(Data Not Collected)
- 技術支援網址:https://tterminal-app.github.io/tterminal-sync/
- 英文技術支援網址:https://tterminal-app.github.io/tterminal-sync/en/
- 隱私權政策網址:https://tterminal-app.github.io/tterminal-sync/privacy.html
- 價格:App 免費;內購兩項(都要先完成付費 App 協議,每個欄位怎麼填見 [iap.md](iap.md)):
  - `14-day Trial`:非消耗型,US$0(審查準則 3.1.1 規定的試用做法)
  - `Unlock tterminal`:非消耗型,US$14.99 / NT$490(基準地區設美國,確認台灣區換算是 NT$490)
- 銷售範圍:先不上法國(加密申報)、中國大陸(ICP 備案);歐盟其他國家要先處理 DSA trader 資料(地址電話會公開)

## 給審查人員的備註(App Review Information)

審查人員要能真的連上一台 SSH 主機才測得了。請在備註裡提供一台示範主機,例如在你的 VPS 上跑一個 `lscr.io/linuxserver/openssh-server` 容器,開一組只給審查用的帳號。內購的設定與兩個品項各自的審查備註見 [iap.md](iap.md)。審查備註是整個 App 共用一份(不分語言),英文版商店資料那邊不用另外填。

> tterminal is an SSH client. On first launch it explains the free trial (how long it lasts, what stops working afterwards and the unlock price). Tap "Start 14-day trial" and confirm the $0 purchase. This is the "14-day Trial" non-consumable (dev.tterm.ttermApp.trial14), following guideline 3.1.1.
> To connect, tap the server icon (top right) → Add Host and enter:
> Address: <示範主機位址>  Port: <埠>  Username: <帳號>  Password: <密碼>
> Then go back and tap the host.
> Everything works during the trial. The one-time "Unlock tterminal" purchase (dev.tterm.ttermApp.unlock) is in Settings → Trial & unlock → Unlock, next to Restore purchases. If the trial ends without an unlock, hosts, keys, Vaults, Settings and sync keep working; only opening a new SSH connection shows the unlock screen.
> Sync is optional and requires the user's own self-hosted server (open source: https://github.com/tterminal-app/tterminal-sync), so it isn't needed for review.
