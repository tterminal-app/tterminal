# 內購項目(App Store Connect)

收費模式是「免費下載 + 14 天試用 + 一次性解鎖」。這份是在 App Store Connect 建兩個內購品項時要填的東西,照著貼就好。

App 端的程式:`app/lib/src/purchases.dart`(狀態與購買服務)、`app/lib/src/unlock_page.dart`(試用說明、解鎖畫面、設定頁那一區)、`app/ios/Runner/StoreBridge.swift`(StoreKit 2)。產品 ID 寫死在 Dart 和 Swift 兩邊,改的話三個地方要一起改(含這份文件與 `app/ios/Runner/tterminal.storekit`)。

## 建之前

1. 付費 App 協議(Paid Apps Agreement)要先生效,稅務和銀行資料都填完。沒生效之前,內購頁面建不了品項,沙盒也買不了。
2. 協議生效後馬上申請小型企業計畫(抽成 15%);核准後要過一個財政月才生效,別等上架才申請。
3. **第一批內購要跟一個新的 App 版本一起送審。** 品項建好、狀態變成「準備提交」後,到該版本頁面的「App 內購買項目和訂閱項目」區塊把兩個都加進去,再送審。

## 兩個品項

路徑:App Store Connect → 你的 App → 營利(Monetization)→ App 內購買項目 → ＋。兩個都選 **非消耗型項目(Non-Consumable)**。

| 欄位 | 試用 | 解鎖 |
|---|---|---|
| 類型 | 非消耗型 | 非消耗型 |
| 參考名稱(只有你看得到) | `14-day Trial` | `Unlock tterminal` |
| 產品 ID(建了就不能改) | `dev.tterm.ttermApp.trial14` | `dev.tterm.ttermApp.unlock` |
| 價格 | US$0(價格點選「免費」) | 基準地區選美國 US$14.99,存檔前確認台灣區自動換算是 NT$490 |
| 銷售範圍 | 跟 App 一樣(先不上法國、中國大陸) | 同左 |
| 家人共享 | 關 | 建議先關(見下面說明) |
| 稅務類別 | 沿用 App 的設定,不用改 | 同左 |
| 在 App Store 上推廣 | 不用 | 可以先不用 |

家人共享:Apple 的規定是非消耗型品項的家人共享**開了就不能再關**。試用一定要關,不然家人共享到的試用交易會讓試用起算日變得難以解釋。解鎖要不要開是商業決定:開了等於一份錢全家用;不確定就先關,之後想開隨時可以開,反過來不行。

### 在地化(顯示名稱上限 30 字、描述上限 45 字)

英文(美國)與繁體中文各一份。App 資訊頁設定的「主要語言」那一份一定要有,其他語言的使用者會看到主要語言的版本。

| | 語言 | 顯示名稱 | 描述 |
|---|---|---|---|
| 試用 | 英文(美國) | 14-day Trial | Try every feature free for 14 days. |
| 試用 | 繁體中文 | 14 天試用 | 所有功能免費試用 14 天。 |
| 解鎖 | 英文(美國) | Unlock tterminal | One-time unlock, includes all 1.x updates. |
| 解鎖 | 繁體中文 | 解鎖 tterminal | 一次買斷,包含之後所有 1.x 更新。 |

這些字會出現在 App Store 的購買確認框和購買紀錄裡。App 內畫面的文案是 `app/lib/l10n/*.arb`,不受這裡影響;價格則是 App 從 StoreKit 拿在地價格字串,沒有寫死在程式裡。

### 審查用截圖

每個品項要上傳一張「這個品項在 App 裡長什麼樣」的截圖,只給審查人員看,不會出現在商店頁。用模擬器截整個螢幕就可以,兩張都能自動拍(不需要 Docker 和示範主機):

```bash
SHOT_TEST=integration_test/iap_review_screenshots_test.dart SHOT_NO_HOST=1 \
  appstore/shoot.sh iphone appstore/raw/iap-review-en en
```

產出 `iap-trial.png` 與 `iap-unlock.png`(1320×2868)。價格是測試用的假字串 US$14.99,跟美國區定價一致。

- **試用**:第一次開 App 自動跳出的試用說明,標題「Try tterminal free for 14 days」,上面列著試用多久、到期後哪些不能用、解鎖價格,下面是「Start 14-day trial」按鈕。
- **解鎖**:開始試用後,設定 → Trial & unlock → Unlock 打開的「Unlock tterminal」畫面,有價格和「Unlock for $14.99」按鈕。(試用到期後點主機跳出來的「Your trial has ended」也可以,但要等 14 天才拍得到。)

建議用英文介面拍,審查人員比較好讀。

### 審查備註(每個品項各一欄)

試用:

> This is a $0 non-consumable that starts the 14-day free trial, as described in App Review Guideline 3.1.1. Before the user starts it, the app explains how long the trial lasts, what stops working afterwards (opening new SSH connections; hosts, keys and sync keep working), and the price of the one-time unlock. It's offered automatically on first launch and again in Settings → Trial & unlock.

解鎖:

> One-time non-consumable that unlocks tterminal permanently, including all future 1.x updates. There is no subscription. During the trial it's available in Settings → Trial & unlock → Unlock. After the trial ends, it's shown when the user tries to open a new SSH connection. Restore purchases is on the same screens.

App 本身的審查備註(示範 SSH 主機、怎麼開始試用)在 listing.zh.md 最後一節。

## App 的行為(對照用)

- 第一次開 App、還沒開始試用:自動跳一次試用說明。按「開始 14 天試用」才會去買 US$0 的試用品項;按「之後再說」就關掉,之後只有點主機開連線時才會再跳。
- 試用起點 = 試用交易的購買日(StoreKit 的 `purchaseDate`,跟 `originalPurchaseDate` 取早的)。跟著 Apple 帳號走,重裝或換手機都不會重新計時;已經買過試用的人再按一次,StoreKit 回的還是原本那筆交易。
- 試用中或已解鎖:功能全開。
- 試用到期又沒解鎖:主機列表、Vaults、金鑰、設定、同步都照常可用,只有「開新的 SSH 連線」會跳解鎖畫面;已經開著的連線不會被中斷。在解鎖畫面買完就直接接著連。
- 交易有 `revocationDate`(退款、被撤銷)就不算,權限收回。`Transaction.updates` 一收到變動(別台裝置買的、Ask to Buy 核准、退款)就重讀。
- 讀不到價格(離線、品項還沒建)時,試用說明會顯示讀不到價格,「開始 14 天試用」按鈕停用,可以按「Try again」重讀。
- 只有 iOS 收費。macOS、Windows、Linux 桌面版沒有這些畫面。

### 品項建好之前的 TestFlight

這版 App 一裝起來就會向商店要品項。App Store Connect 上還沒有這兩個品項時,讀不到價格就開不了試用,也就完全不能連線。品項建好之前如果要發 TestFlight 給人測,build 時加:

```bash
flutter build ipa --dart-define=TTERM_IAP=false
```

這樣 iOS 也不收費,跟桌面版一樣。**送審和上架的 build 不要加。**

## 本機測試

### Xcode + StoreKit 設定檔(不用連 App Store)

`app/ios/Runner/tterminal.storekit` 放了這兩個品項(價格 US$0 與 US$14.99,美國店面,英文與繁中名稱)。用 Xcode 跑的時候選它,購買就走 Xcode 的本機測試商店,不需要付費 App 協議、也不需要沙盒帳號。

1. 先編 Rust 核心和 Flutter(Xcode 只負責連結,不會自己重編 Rust):

   ```bash
   cd core && cargo build --release -p tterm-ffi --target aarch64-apple-ios-sim
   ```

   ```bash
   cd app && DEVELOPER_DIR=/Applications/Xcode-27.1-RC.app/Contents/Developer flutter build ios --simulator --debug
   ```

2. 用 Xcode 開 `app/ios/Runner.xcworkspace`。
3. Product → Scheme → Edit Scheme… → Run → Options → **StoreKit Configuration** 選 `tterminal.storekit`。這個選項會寫進共用的 `Runner.xcscheme`,測完不想 commit 就把那個檔案還原。
4. 選一台專門拿來測的模擬器(不要用平常放資料的那台),按 Run。
5. 第一次開就會看到試用說明。按「開始 14 天試用」會跳 Xcode 的測試購買框,確認後就開始試用。
6. Debug → StoreKit → Manage Transactions… 可以看所有交易:
   - 刪掉試用那筆交易 = 回到「還沒開始試用」(要刪 prefs 才會再自動跳說明,或直接點主機)
   - 對解鎖那筆按 Refund = 測退款收回權限
   - 在 Xcode 打開 `tterminal.storekit`,選 Editor → Enable Ask To Buy = 測「等待核准」

模擬器的時間跟著 Mac 走,沒辦法快轉 14 天。試用到期的畫面請看 widget test(`app/test/purchases_test.dart`),或在實機上把日期調到 15 天後。

`flutter run` 和 `flutter drive` 不會用 scheme 裡的 StoreKit 設定。App Store 截圖的 integration test 直接把狀態設成「已解鎖」,不受影響。

### 沙盒與 TestFlight

- 品項在 App Store Connect 建好(狀態「準備提交」即可)而且付費 App 協議生效之後,沙盒和 TestFlight 就買得到,不會真的扣款。
- 非消耗型買了就一直在。要從頭測試用流程,用沙盒測試帳號,到 App Store Connect → 使用者與存取權限 → 沙盒 → 測試帳號,清除該帳號的購買紀錄。

## 自動化測試

`app/test/purchases_test.dart` 用 `FakePurchaseService` 假造四種狀態(未開始 / 試用中 / 試用到期 / 已解鎖),涵蓋:第一次開 App 的試用說明、到期後點主機跳解鎖畫面、Vaults 與同步照常可用、恢復購買、等待核准與失敗、英文介面沒有殘留中文。商店截圖的 `app/integration_test/store_screenshots_test.dart` 傳入 `FakePurchaseService.unlocked()`,畫面上不會出現試用說明或解鎖畫面。
