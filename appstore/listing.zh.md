# App Store 商店資料(繁體中文)

貼到 App Store Connect 用。字數上限寫在標題後面。

## 名稱(30)

tterminal

## 副標題(30)

SSH 終端機,中文打得順

## 宣傳文字(170)

先免費用 14 天,喜歡再一次買斷,沒有訂閱。注音、倉頡、拼音都能好好打,htop、vim、tmux 照常跑;主機和金鑰可以透過你自己架的伺服器同步,全程端對端加密。

## 描述(4000)

手機上的終端機,打中文常常出包:組字到一半整段消失、同一個字被送兩次、中文檔名對不齊。tterminal 從一開始就把輸入法當成重點來做。

【中文終於好好打】
組字直接顯示在游標位置,選好字才送出去,不會打到一半跳掉,也不會重複輸入。注音、倉頡、拼音、日文都一樣。中文檔名、commit 訊息、全形標點,畫面上都對得整整齊齊。

【終端機該有的都有】
・密碼或金鑰登入。第一次連線會記下主機指紋,之後如果指紋變了會直接擋下來
・htop、vim、tmux、less 這些全螢幕程式照常跑,畫面用 GPU 畫,捲動很順
・鍵盤上方有一排功能鍵:esc、ctrl、tab、方向鍵,^C、^D 一鍵送出
・長按終端機再拖曳就是方向鍵搖桿,在 vim 裡移動游標很方便
・字體大小可以調

【切出去回來,連線還在】
切去回個訊息再回來,連線多半還掛著。退到背景時,動態島和鎖定畫面會顯示目前有幾條連線。(iOS 限制背景執行時間,離開太久還是會被系統暫停。)

【主機集中管理】
常用的主機可以釘選在最上面,也可以搜尋名稱、位址、使用者。

【同步走你自己的伺服器】
不用註冊帳號。想在 iPhone、iPad 之間同步主機和金鑰,就自己架一台同步伺服器,一行 docker 指令就能跑起來。建議放在家裡的 NAS 或小主機上,不對外開放,出門時用 VPN 連回去。資料在裝置上先加密(XChaCha20-Poly1305)才送出去,伺服器只存得到密文,我也看不到。伺服器程式碼以 AGPL-3.0 開源,要怎麼檢查都可以。

【大螢幕也好用】
iPad 和 iPhone Duo 展開時會變成兩欄:左邊連線列表,右邊終端機。Duo 半摺的時候,版面會對齊摺痕。

【先試用,再買一次】
下載免費,所有功能可以完整試用 14 天。喜歡的話一次買斷,之後的 1.x 更新都包含在內;沒有訂閱、沒有廣告,也不蒐集任何使用資料。試用結束沒買也沒關係,主機列表和同步都還在,只是不能開新的連線。

有問題或想要的功能,歡迎到 GitHub 開 issue。

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
- 價格:App 免費;內購兩項(都要先完成付費 App 協議):
  - `14-day Trial`:非消耗型,US$0(審查準則 3.1.1 規定的試用做法)
  - `Unlock tterminal`:非消耗型,US$14.99 / NT$490(基準地區設美國,確認台灣區換算是 NT$490)
- 銷售範圍:先不上法國(加密申報)、中國大陸(ICP 備案);歐盟其他國家要先處理 DSA trader 資料(地址電話會公開)

## 給審查人員的備註(App Review Information)

審查人員要能真的連上一台 SSH 主機才測得了。請在備註裡提供一台示範主機,例如在你的 VPS 上跑一個 `lscr.io/linuxserver/openssh-server` 容器,開一組只給審查用的帳號:

> tterminal is an SSH client. To try it, tap the server icon (top right) → Add Host and enter:
> Address: <示範主機位址>  Port: <埠>  Username: <帳號>  Password: <密碼>
> Then go back and tap the host to connect.
> The app is free to download with a 14-day free trial (a $0 non-consumable "14-day Trial" IAP, per guideline 3.1.1) and a one-time "Unlock tterminal" IAP. Both are offered on first launch and in Settings, along with Restore Purchases.
> Sync is optional and requires the user's own self-hosted server (open source: https://github.com/tterminal-app/tterminal-sync), so it isn't needed for review.
