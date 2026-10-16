# 開發筆記

給想自己編譯或改程式的人。英文的快速入門在 [README](../README.md#build-from-source)。

## 結構

```
core/                Rust workspace
  tterm-term/        終端模擬引擎(alacritty_terminal 封裝 + damage + OSC)
  tterm-session/     PTY / SSH 來源 + 引擎 + reader thread
  tterm-ssh/         SSH session(russh)
  tterm-vault/       Vault 核心(XChaCha20 加密、HLC+LWW 合併、配對字串)
  tterm-ffi/         C ABI(terminal 熱路徑 + vault JSON 通道)
app/                 Flutter app(桌面 + 手機同一套 UI)
  lib/src/term_ffi.dart      FFI 綁定(ABI v3)
  lib/src/keys.dart          按鍵 → PTY bytes(xterm 相容)
  lib/src/ime.dart           IME 橋接(中文輸入核心)
  lib/src/term_painter.dart  grid 繪製(含選取反白)
  lib/src/terminal_view.dart terminal widget(選取複製、IME、捲動)
  lib/src/tabs.dart          分頁控制器
  lib/src/app_shell.dart     多分頁工作區(上方/側邊 tab list)
  lib/src/vault_*.dart       Vault FFI/Service 與 Hosts/Keys 管理頁
  lib/src/sync_client.dart   同步 HTTP 傳輸(只搬密文)
  lib/src/settings_page.dart 設定頁(分頁位置、同步/配對)
server/              tterm-server:自架同步伺服器(axum,zero-knowledge)
docs/vault-sync-design.md    Vault/同步/配對完整設計
```

## 架構要點

**Rust core / Flutter UI 分工**:終端模擬、SSH、PTY、加密都在 Rust,一份程式碼
跑五個平台;UI 用 Flutter(Impeller/Skia GPU 直繪,不是 WebView)。兩者以手寫
C ABI 相接,grid 以扁平 buffer(每 cell 4×u32)整份拷貝,120×40 只要 ~0.1ms。

**IME 是一等公民**:自繪 terminal 沒有 EditableText 可依附,輸入法要靠
`TextInputConnection` 隱形輸入框。關鍵設計是**可見字元(中英文一律)走 IME 路徑,
按鍵事件只處理控制鍵**——這樣中文組字時不會同時被當按鍵送出去(重複輸入的經典
bug)。組字內容畫在游標處,caret rect 回報給平台讓候選字視窗跟著游標跑。

## 開發

```sh
# Rust core
cd core
cargo test                             # 單元 + PTY 端對端測試
cargo run --release --bin term_bench   # 終端引擎吞吐量基準
cargo build --release -p tterm-ffi     # Flutter 用的 FFI 函式庫(先跑這個)

# 同步 server(self-host)
cd ../server
cargo test                             # API + 兩 client 收斂端對端
cargo run --release                    # 0.0.0.0:8722,資料存 ./data(見 server/README.md)

# SSH 端對端測試(需 docker)
docker run -d --name tterm-sshd -p 127.0.0.1:2222:2222 \
  -e PASSWORD_ACCESS=true -e USER_NAME=tester -e USER_PASSWORD=tterm-test-123 \
  lscr.io/linuxserver/openssh-server
TTERM_PROBE_USER=tester TTERM_PROBE_PASS=tterm-test-123 cargo run --bin ssh_probe

# Flutter app
cd ../app
flutter test                           # IME / 按鍵 / 渲染 / 真實 shell 端對端
flutter build linux --release          # bundle 會一併帶入 libtterm_ffi.so
./build/linux/*/release/bundle/tterminal   # 桌面環境執行(可打字的終端)
TTERM_DEMO=1 ./build/linux/*/release/bundle/tterminal   # 效能 HUD 畫面
```

測試可用的環境變數:`TTERM_FFI_LIB` 指定原生函式庫路徑、
`TTERM_DUMP_DIR` 讓渲染測試把畫面存成 PNG。

### Windows standalone exe

在 Windows 機器上一行指令產出單一檔案:

```powershell
.\scripts\build-windows.ps1     # → dist\tterminal.exe(免安裝,可直接複製)
```

沒有 Windows 機器的話,GitHub Actions 的 release workflow 會產出同樣的檔案(見 `.github/workflows/release.yml`)。

單一 exe 靠 `packaging/win-launcher` 自解壓啟動器達成:建置時把整份 Flutter
bundle 壓成 zip 嵌進執行檔,首次執行解壓到 `%LOCALAPPDATA%`,之後啟動跳過解壓
(實測 3 ms)。細節與前置需求見 [windows-build.md](windows-build.md)。

**Rust core 可以在 Linux 直接跨編譯**(需 `mingw-w64` 與 `nasm`),
但 Flutter 不支援跨 OS 編譯 desktop 目標,app 的 exe 必須在 Windows 上建置:

```sh
cd core && cargo build --release --target x86_64-pc-windows-gnu
```

`dist/tterm-selftest.exe` 就是這樣產出的——不需要 Flutter,複製到 Windows
直接執行就能驗證終端引擎與 **ConPTY**(Linux 開發機測不到的路徑)。

### macOS app

在 Mac 上一行指令產出 universal(arm64 + x86_64)的 .app:

```sh
./scripts/build-macos.sh        # → dist/tterminal.app + dist/tterminal-macos.zip
```

Rust 核心會 arm64 / x86_64 各編一份再 lipo 成 universal dylib,塞進 .app 的
`Contents/MacOS/` 後重新簽章。預設 ad-hoc 簽章(zip 複製到其他 Mac 首次開啟
需右鍵→打開);有 Developer ID 憑證時用 `TTERM_SIGN_IDENTITY` 換成正式簽章
(加上 hardened runtime),再用 `scripts/notarize-macos.sh <版本>` 公證並釘上票據。
CI(release.yml)讀 `scripts/set-macos-signing-secrets.sh` 設好的 secrets 做同樣的事。
App Sandbox 已停用——終端機要 spawn shell、讀寫任意路徑、連 SSH。

**rustc 要夠新**:macOS 26+ 的 dyld 會拒載舊 rustc(≤1.90)release 建置
strip 出來的 cdylib(`dlopen … mis-aligned LINKEDIT string pool`),
cargo 測試執行檔不受影響所以很難察覺;`rustup update` 即修(1.97 確認 OK)。

### iOS app

```sh
./scripts/build-ios.sh    # → 裝置版(未簽章)+ 模擬器版 Runner.app
```

iOS 不能 dlopen 隨附的 dylib,Rust 核心改以 **staticlib** 連進執行檔:
`ios/Flutter/*.xcconfig` 用 `-force_load` 連 `libtterm_ffi.a`,Release 另設
`EXPORTED_SYMBOLS_FILE`(`_tterm_*`)擋 dead-strip;Dart 端在 iOS 走
`DynamicLibrary.process()`。Debug 不能設 EXPORTED_SYMBOLS_FILE——Xcode 的
debug-dylib 殼要 dlsym 進入點,限縮 export 會啟動即 abort。

裝置部署需要簽章:`open app/ios/Runner.xcworkspace` 選 team 後跑到 iPhone。
模擬器上連本地 shell 都能動(sim 環境可 spawn);實機上本地 shell 不可行
(iOS 禁 fork/exec),主用途是 SSH client。

上架用 `flutter build ipa`(走 archive)。archive 會再 strip 一次,
所以 `Release.xcconfig` 設了 `STRIP_STYLE = non-global`,不然 IPA 裡的
`tterm_*` export 會被剝光、一開就查不到 FFI;`build-ios.sh` 的 export 檢查
只涵蓋非 archive 的建置,上架前請另外檢查 archive 裡的 Runner。

### App Store 素材

`appstore/` 放商店用的東西:icon 原始檔、商店文案(`listing.*.md`)、截圖流程。

```sh
appstore/shoot.sh iphone appstore/raw/iphone-zh zh        # 專用模擬器上自動拍原始畫面
FONT=22 appstore/shoot.sh ipad appstore/raw/ipad-zh zh
python3 appstore/compose.py zh                            # 合成商店尺寸 → appstore/screenshots/
```

`shoot.sh` 只用它自己建立的 `tterm-shots-*` 模擬器:`flutter drive` 跑完會解除安裝 app,
流程也會寫入示範主機,不要拿平常開發用的模擬器跑。示範 SSH 主機(docker)、
`homelab.local` 名稱與本機同步伺服器都由腳本自動準備。

### 同步伺服器開源版

`server/` 與 `core/tterm-vault/` 以 AGPL-3.0 公開在
[tterminal-app/tterminal-sync](https://github.com/tterminal-app/tterminal-sync)
(含 Docker image、使用說明與隱私權政策頁)。這個 repo 是原始碼來源,那邊的內容由腳本產生:

```sh
scripts/export-sync-oss.sh ../tterminal-sync   # 組出公開 repo 的內容,再到那邊 commit / push
```
