# tterminal — 跨平台 SSH Terminal 完整規劃

> 定位:類 Termius 的跨平台 terminal client(Windows / macOS / Linux / iOS / Android),
> 同步 hosts、帳號密碼、SSH keys、snippets 等資料,以**自架 server** 為同步後端,
> 全程 E2E 加密(zero-knowledge),UI 採 **GPU native render,不用 Electron / WebView**。
>
> 差異化功能:**pane 工作區**(terminal / 檔案樹 / 編輯器自由分割)、
> 檔案樹**自動跟隨遠端 cwd**、內建文字編輯器(SFTP 開檔直接改)、
> **tmux control mode 原生整合**(tmux windows/panes 映射為原生分頁/pane)。
>
> **平台優先序(2026-07-20 定案)**:client 主力 = **Windows x64**,
> 其次 Linux/macOS,再來 iOS/Android;server 只出 Linux。

---

## 1. 核心技術選型

### 1.1 總體架構:單一 Rust 核心 + Flutter UI

```
┌─────────────────────────────────────────────────┐
│                Flutter UI (Dart)                │
│   Impeller/Skia GPU 直繪 — 無 DOM、無 WebView   │
│   CustomPainter 繪製 terminal grid(字形 atlas)│
└─────────────────┬───────────────────────────────┘
                  │ flutter_rust_bridge (FFI, zero-copy)
┌─────────────────┴───────────────────────────────┐
│              tterm-core (Rust)                  │
│  ├ term:    VT emulation (alacritty_terminal)   │
│  ├ ssh:     russh(auth / channel / SFTP)      │
│  ├ vault:   加密儲存(Argon2id + XChaCha20)    │
│  ├ sync:    同步引擎(delta sync / conflict)   │
│  └ db:      SQLite(rusqlite,應用層加密)     │
└─────────────────┬───────────────────────────────┘
                  │ HTTPS / WebSocket(只傳密文)
┌─────────────────┴───────────────────────────────┐
│         tterm-server (Rust, axum)               │
│   單一 binary,SQLite(可選 Postgres)          │
│   zero-knowledge:只存加密 blob                 │
│   Docker / docker-compose 一鍵自架              │
└─────────────────────────────────────────────────┘
```

### 1.2 為什麼是 Flutter(而不是其他)

| 方案 | 評估 |
|---|---|
| **Flutter**(採用) | Impeller/Skia GPU 直繪,無 webview;一套 UI 覆蓋 5 平台;terminal 這種「自繪 canvas」型 UI 正好是 Flutter 強項;input latency 與原生接近 |
| 各平台原生 UI(SwiftUI / Compose / winui / gtk) | 效能最佳,但 4~5 套 UI codebase,工作量 3 倍以上;之後可針對單一平台再做 |
| Compose Multiplatform | iOS 支援 2025 才 stable,桌面走 JVM,啟動與記憶體不如 Flutter/原生 |
| Tauri | 本質是 WebView render,不符「不要 Electron 類」需求 |
| egui / Slint / gpui | 桌面可行,mobile 生態與 IME/無障礙支援太弱 |

**Terminal 渲染路徑**(效能關鍵):
- Rust 端(`alacritty_terminal`)維護 grid state + **damage tracking**(只回報變更的 cells/lines)。
- FFI 每 frame 只傳 dirty region(flutter_rust_bridge 支援 zero-copy buffer)。
- Flutter 端用 `CustomPainter` + 預先 rasterize 的**字形 atlas** 繪製;游標/選取/搜尋 highlight 走獨立 layer。
- 目標:輸入到上屏 latency < 20ms,`cat` 大檔案輸出時維持 60fps(帶 frame-skip 的 throttled repaint)。

### 1.3 關鍵 Rust 套件

| 領域 | 套件 | 理由 |
|---|---|---|
| VT emulation | `alacritty_terminal` | Alacritty 抽出的核心,VT100~xterm 相容性經過大量實戰 |
| SSH | `russh` + `russh-sftp` | Pure Rust、async、支援 password / pubkey / keyboard-interactive / agent、port forwarding |
| 密碼學 | RustCrypto(`argon2`, `chacha20poly1305`)或 `libsodium` binding | 稽核過的實作,不自己寫 crypto |
| 本地 DB | `rusqlite` | 單檔、跨平台;敏感欄位應用層加密(不依賴 SQLCipher 授權) |
| FFI | `flutter_rust_bridge` v2 | 自動生成 binding、支援 stream(terminal output 直接推流到 Dart) |
| Server | `axum` + `tokio` | 輕量、單 binary |

---

## 2. Pane 工作區、檔案樹、編輯器、tmux 整合

### 2.1 Pane 系統

- 每個視窗是一棵 **split tree**(水平/垂直遞迴分割),leaf 可以是三種 pane:
  **Terminal / 檔案樹(File Explorer)/ 編輯器(Editor)**。
- Pane 之間有「session 關聯」概念:同一個 SSH session 可同時掛 terminal pane、
  檔案樹 pane、多個 editor pane——**共用同一條 SSH 連線**(SSH 多 channel,
  SFTP 走獨立 channel),不重複認證、不重複連線。
- 快捷鍵:分割、關閉、焦點移動、pane 縮放全鍵盤可操作;layout 可存成
  per-host 預設(例如「這台 host 開啟時自動 terminal + 檔案樹」)。
- Mobile:小螢幕不做並排分割,改為 pane 間 swipe/tab 切換;平板支援真分割。

### 2.2 遠端 cwd 追蹤(檔案樹跟隨)

- **主要機制:shell integration**(和 WezTerm / iTerm2 同做法)——提供一段
  bash/zsh/fish snippet,讓 prompt 發出 `OSC 7`(cwd)與 `OSC 133`(prompt 標記)。
  Rust term 層解析後廣播 cwd 變更事件 → 檔案樹 pane 自動 `cd` 跟隨。
- 一鍵安裝:app 內建「安裝 shell integration 到這台 host」指令(append 到 rc 檔)。
- **Fallback**(未裝 integration 時):對 Linux host 用 SFTP 讀
  `/proc/<shell_pid>/cwd` symlink(shell pid 可從 SSH channel 環境推得或
  `$$` 查詢);再不行則檔案樹停留在手動模式。
- OSC 133 prompt 標記另有紅利:命令輸出區塊摺疊、上一命令跳轉、exit code 標記。

### 2.3 檔案樹 pane(File Explorer)

- 基於 `russh-sftp`,lazy-load 目錄、大目錄分頁載入、隱藏檔切換、
  依名稱/大小/mtime 排序。
- 操作:開啟(→ editor pane)、下載/上傳(拖放)、重新命名、chmod、刪除(確認)、
  新建檔案/目錄、複製路徑、「在 terminal cd 到此處」。
- 顯示 git 狀態(可選,透過執行 `git status --porcelain`)與檔案類型 icon。
- 跟隨模式可鎖定(pin 住某目錄不跟隨 cwd)。

### 2.4 編輯器 pane(Editor)

- 定位:**快速檢視與修改設定檔/腳本**,不是要取代 IDE。
- 開檔:SFTP 讀取 → 本地 buffer;存檔:寫 temp 檔 + rename 原子替換,
  保留原權限/owner(必要時 fallback 直接覆寫);外部變更偵測(mtime)提示 reload。
- 編輯核心:Rust 端 `ropey`(rope buffer)+ **tree-sitter** syntax highlighting
  (常見語言:sh/yaml/toml/json/nginx/systemd/python/js/rust…),
  Flutter 端只做渲染與輸入——與 terminal 共用字形 atlas 渲染管線。
- 功能範圍:行號、搜尋/取代、多游標(基本)、soft wrap、大檔(>10MB)唯讀串流預覽、
  binary 檔自動改 hex 預覽;**不做** LSP/補全(明確非目標)。
- 也可當本地編輯器用(local file)。

### 2.5 tmux 整合(control mode)

策略:**tmux control mode(`tmux -CC`)原生整合**,iTerm2 同款做法,而非只是「畫得出 tmux 畫面」。

- 連線時偵測(或 per-host 設定)以 `tmux -CC new -A -s <session>` attach。
- Rust 端 `tterm-tmux` 模組解析 control mode 協定
  (`%begin/%end/%error`、`%output`、`%window-add`、`%layout-change`、
  `%session-changed`、`%pane-mode-changed`…)。
- **映射關係**:tmux window → app 分頁;tmux pane → app 原生 pane
  (進入 2.1 的同一棵 split tree);tmux 的 layout 變更雙向同步
  (app 內拖分割線 → 發 `resize-pane`)。
- scrollback 由 app 端保存(`%output` 全量進 app 的 grid),
  不依賴 tmux copy-mode——捲動、搜尋、複製都是原生體驗。
- **斷線復原**:重連後 `attach -t` 回到原 session,windows/panes/執行中程序全在。
  這是 mobile(iOS 背景殺連線)的主力對策,優先級高於 mosh。
- 非 control mode 的一般 tmux(用戶自己在遠端跑 `tmux`)維持正常渲染即可,
  另外辨識 `TMUX` 環境提示用戶可切換成原生整合。

---

## 3. 資料模型(Vault)

所有同步資料都是「vault record」,每筆獨立加密:

| Entity | 內容 |
|---|---|
| `Host` | 名稱、address、port、協定(ssh/mosh/telnet/serial)、關聯 identity、群組/標籤、per-host 設定(編碼、term type、啟動指令) |
| `Identity` | username + 認證方式(password / key 參照 / agent) |
| `SshKey` | 私鑰(加密)、公鑰、passphrase、類型(ed25519/rsa/ecdsa);可標記「僅本機,不同步」 |
| `KnownHost` | host key fingerprints(跨裝置同步,避免每台重新 TOFU) |
| `Snippet` | 常用指令片段、變數插值 |
| `PortForward` | local/remote/dynamic forwarding 規則 |
| `Group` | 巢狀群組,支援繼承 identity/設定 |
| `Settings` | 主題、字型、keybindings(可同步) |

Record 通用欄位:`id (uuid)`、`type`、`encrypted_blob`、`version`、`updated_at (HLC)`、`deleted (tombstone)`。
**Server 只看得到通用欄位 + 密文**,連 record 名稱都在 blob 內。

---

## 4. 同步協定

- **Delta sync**:client 帶 `last_sync_cursor` 上來,server 回傳其後所有變更;client 推送本地變更(密文)。
- **版本控制**:每 record 帶 HLC(Hybrid Logical Clock)timestamp + version;一般採 LWW。
- **衝突處理**:同一 record 兩端同時修改時,**不靜默覆蓋**(密碼/私鑰丟失不可接受)——保留兩個版本,UI 提示用戶選擇或合併。
- **刪除**:tombstone 保留(預設 90 天)後 GC。
- **即時性**:WebSocket push 通知其他裝置有新變更(可選;無 WS 時 fallback 輪詢/啟動時拉取)。
- **離線優先**:本地 SQLite 是 source of truth,無網路完全可用,連上後補同步。
- Wire format:protobuf(`proto/` 目錄統一定義,client/server 共用)。

---

## 5. 安全設計(zero-knowledge)

### 5.1 金鑰階層

```
master password
   │  Argon2id (m=64MB, t=3, p=4, per-user salt)
   ├──> auth hash    → 再經 server 端 Argon2 存儲(或升級為 OPAQUE)
   │                   僅用於登入,推不回 master key
   └──> master key   → 永不離開裝置
           │ 解包
           └──> vault key(隨機 256-bit)
                   │ XChaCha20-Poly1305
                   └──> 加密每筆 record blob
```

- 改 master password 只需重新 wrap vault key,不用重加密全部資料。
- 新裝置登入:輸入 master password → 解 wrapped vault key(從 server 拉密文)。
- **Server 被攻破的最壞情況 = 拿到一堆 Argon2id 保護的密文**。

### 5.2 裝置端

- master key / vault key 快取於 OS 安全儲存:Keychain(macOS/iOS)、Keystore(Android)、DPAPI(Windows)、Secret Service(Linux)。
- 生物辨識(Face ID / 指紋)解鎖 app;閒置自動鎖定。
- 私鑰可設定「local-only」永不進同步管線。

### 5.3 其他

- 帳號 2FA(TOTP);session token 短效 + refresh 輪替;裝置清單管理與遠端登出。
- SSH host key 驗證嚴格模式(同步的 known_hosts + 變更警告)。
- Server 端 rate limiting、加密 blob 大小上限。
- Client/Server 全開源,可自行稽核(信任模型不依賴 server)。

---

## 6. 自架 Server 部署體驗

- 單一 static binary(musl build)或 Docker image。
- `docker compose up -d` 即完成:server + 自動 TLS(內建 ACME/Let's Encrypt,或文件說明放在 Caddy/nginx 後面)。
- SQLite 單檔資料庫 → 備份 = 複製一個檔案;大規模才需要切 Postgres。
- 首次啟動產生 admin token;可關閉公開註冊(私人 server 常態)。
- 提供 healthcheck endpoint 與 Prometheus metrics(可選)。

---

## 7. 專案結構(monorepo)

```
tterminal/
├── core/                  # Rust workspace
│   ├── tterm-term/        # VT emulation 封裝 + damage tracking + OSC 7/133
│   ├── tterm-ssh/         # SSH session 管理、SFTP、forwarding
│   ├── tterm-tmux/        # tmux control mode 協定解析與 session 映射
│   ├── tterm-edit/        # ropey buffer + tree-sitter highlighting
│   ├── tterm-vault/       # 加密、金鑰階層、本地 DB
│   ├── tterm-sync/        # 同步引擎(client 端)
│   └── tterm-ffi/         # flutter_rust_bridge 出口
├── app/                   # Flutter app(desktop + mobile 同一套)
│   ├── lib/workspace/     # pane split tree、layout 管理、分頁
│   ├── lib/terminal/      # grid renderer、字形 atlas、輸入處理
│   ├── lib/explorer/      # 檔案樹 pane(SFTP browser)
│   ├── lib/editor/        # 編輯器 pane(渲染層)
│   ├── lib/vault/         # hosts/keys 管理 UI
│   └── lib/sync/
├── server/                # tterm-server (axum)
├── proto/                 # 同步協定 protobuf 定義
└── docs/
```

---

## 8. 開發里程碑

### Phase 0 — 技術驗證(2–3 週)⚠️ 最重要

> **進度(2026-07-20)**:Rust core 已落地並驗證 ✅
> - `tterm-term`(alacritty_terminal 0.26 封裝):17 個測試全過
>   (VT/CJK 寬字元/組合字元/色彩/damage/scrollback/alt-screen/OSC52/DA 回應/真實 PTY 端對端)。
> - 吞吐量(120x40, aarch64 Cortex-X925, release):plain 86 MiB/s、
>   colored 127 MiB/s、CJK 108 MiB/s、TUI cursor_paint 314 MiB/s;
>   全 grid snapshot ~0.1ms → FFI 每 frame 全量拷貝都遠低於 16.6ms 預算。
> - `tterm-ssh`(russh 0.62):connect/auth/PTY shell → 引擎 → 畫面,
>   對 docker sshd 端對端 OK(`ssh_probe`)。
> - ⚠️ **開發機是 Linux ARM64**(NVIDIA GB10):Flutter 官方 SDK 無
>   linux-arm64 host build;社群建置(zhzhzhy/Flutter-SDK-ARM64,持續更新中)
>   可用,或在另一台 x64/macOS 機器做 UI 開發。見風險表。
>
> **進度(2026-07-20,第二輪)**:FFI + Flutter 渲染管線驗證 ✅
> - FFI 策略定案:**熱路徑(terminal grid)= 手寫 C ABI + 扁平 buffer**
>   (`tterm-ffi`,每 cell 4×u32,120x40 全量拷貝 <0.2ms);
>   vault/sync 等複雜 API 之後才用 flutter_rust_bridge。
> - Flutter 3.47(master)以社群 arm64 SDK 安裝,
>   Linux desktop build ✅;渲染驗證用 widget test(golden 同機制,免 X/GL)
>   pump 真實 FFI 引擎 + 載入真實字型 → CJK 寬字元對齊、256 色、truecolor、
>   粗體、底線全部正確(截圖:`docs/phase0/`)。
> - **Windows x64**:Rust core 以 mingw-w64 + NASM 跨編譯成功(含 russh/aws-lc);
>   Flutter Windows 打包需 Windows 機器或 CI(GitHub Actions)——Flutter 不支援
>   跨 OS 編譯 desktop 目標。
> **進度(2026-07-20,第三輪)**:可互動終端完成,IME 中文輸入驗證通過 ✅
> - `tterm-session`:PTY(Windows 走 ConPTY)+ 引擎 + reader thread 綁成一個單元;
>   DA/DSR 查詢自動回寫(vim/htop 不會卡)、SIGWINCH、標題、EOF 偵測,6 個端對端測試。
> - **IME 架構定案**:可見字元(中英文一律)走 `TextInputConnection` 路徑,
>   按鍵事件只處理控制鍵 —— 從根本避免「組字中同時被當按鍵送出」的重複輸入。
>   組字內容畫在游標處(反白+底線),並回報 caret rect 讓候選字視窗跟著游標。
>   驗證:模擬平台輸入法把中文打進真實 shell 並看到輸出(`test/terminal_e2e_test.dart`)。
> - 鍵盤:xterm 相容編碼(DECCKM 方向鍵、F1–F12、修飾鍵組合、Ctrl 控制碼、
>   bracketed paste),31 個單元測試。
> - **繪製成本**(120x40,錄製階段、不含 GPU):plain 1.8ms、colored 2.7ms、
>   **CJK 1.3ms**(加字形快取前是 10.3ms)、TUI truecolor 7.3ms。
> - Windows x64:`tterm_ffi.dll` 跨編譯成功並驗證 export 表;
>   Flutter Windows 打包走 CI(`.github/workflows/build.yml`)。
>
> **進度(2026-07-20,第四輪)**:Windows 單檔 exe 打包鏈完成
> - **限制確認**:Flutter 不支援跨 OS 編譯 desktop(需 MSVC),
>   app 的 exe 必須在 Windows 機器或 CI windows runner 上建置。Rust 端不受限。
> - `packaging/win-launcher`:自解壓啟動器,把整份 Flutter bundle 壓成 zip
>   嵌進單一 exe;首次執行解壓到 `%LOCALAPPDATA%\tterminal\app-<hash>`,
>   之後啟動 3ms(跳過解壓);payload 換版本自動用新目錄。
>   GUI subsystem 不閃主控台、只依賴系統 DLL、擋 zip slip。
>   解壓與啟動流程已在 Linux 上端對端驗證(含參數傳遞與權限)。
> - `scripts/build-windows.ps1`:一行指令產出 `dist\tterminal.exe`。
> - **`tterm-selftest.exe`**:不需要 Flutter 的核心自我測試,已交叉編譯放在
>   `dist/`,可立刻在 Windows 上驗證 **ConPTY** 與中文 UTF-8 往返
>   (Linux 開發機測不到的路徑)。細節見 `docs/windows-build.md`。
>
> **✅ Windows 實機驗證(2026-07-20,使用者於 windows/x86_64 執行)**:
> `tterm-selftest.exe` **9/9 全過** —— 包含 **ConPTY 開啟 shell、執行指令、
> 讀回輸出、resize**,以及**中文 UTF-8 往返**。引擎吞吐 97 MiB/s、
> grid 拷貝 0.01 ms/frame。**Windows 目標的核心風險解除**,
> 剩下的只是 Flutter app 的打包(需在 Windows 上跑 `scripts/build-windows.ps1`)。
> - 待辦(Phase 0 收尾):**真機 fps 量測**(Xvfb 軟渲染下 GTK frame clock 不動,
>   要在實體桌面跑 `app/build/linux/arm64/release/bundle/tterm_app` 看 HUD)、
>   滑鼠選取/複製、字形 atlas(TUI truecolor 場景的 7.3ms 是目前上限)。
- Rust core + flutter_rust_bridge 打通(desktop + 至少一個 mobile 平台)。
- `alacritty_terminal` grid → Flutter CustomPainter 渲染,跑 vttest。
- russh 連上真實 server,互動 shell 可用。
- **量測**:input latency、`yes`/`cat 大檔` 輸出 fps、冷啟動時間、記憶體。
- 驗證 CJK 寬字元、IME 中文輸入、emoji 渲染。
- ➡ 此階段若渲染或 FFI 效能不達標,調整方案(例如渲染下沉到 Rust 端出 texture)。

### Phase 1 — 桌面 MVP(5–7 週)
- Host 管理(本地、未加密同步前先本地儲存)。
- SSH:password / key auth、多分頁。
- **Pane split tree**:terminal pane 分割、鍵盤導航、layout 保存。
- Terminal 完整度:scrollback、複製貼上、搜尋、URL 偵測、256 色/truecolor、滑鼠模式。
- 字型設定、主題(內建 + 自訂)。

### Phase 2 — 檔案樹 + 編輯器 + shell integration(4–5 週)
- Shell integration(OSC 7/133)+ 一鍵安裝;cwd 追蹤事件管線。
- 檔案樹 pane:SFTP browser、跟隨 cwd、上傳下載、基本檔案操作。
- 編輯器 pane:ropey + tree-sitter、開檔/原子存檔、搜尋取代、大檔唯讀預覽。

> **進度(2026-07-21,第四輪)**:SFTP 遠端檔案側窗 + 聽寫正解 ✅
> - **SFTP**:tterm-ssh open_sftp(russh-sftp 2.3,和 shell 共用連線)、
>   Session/FFI(ABI 6)sftp home/list/read/write;Dart FileSource 抽象
>   (本地/遠端),SSH 分頁時檔案側窗自動切到遠端 SFTP 樹、編輯器可讀寫遠端檔。
>   in-process SFTP server(ssh_e2e + test_sshd)驗證;實機:連 SSH → 側窗列
>   遠端檔、開遠端檔進編輯器。
> - **聽寫輸入(正解)**:Flutter Windows stable 未開 native UIA(engine
>   #114547),改在 runner subclass FLUTTERVIEW 子視窗、攔 UIA WM_GETOBJECT
>   回傳自製 IValueProvider(Edit),SetValue → method channel → 終端。
>   用 UIA ValuePattern.SetValue(typeless 的機制)實機重現驗證。
> - 尚未做:遠端檔拖出(需先下載)、SFTP 上傳/刪除/新建、pane 分割、tmux。

> **進度(2026-07-21,第三輪)**:檔案側窗 + 聽寫輸入 ✅
> - **檔案側窗 pane**:引擎自寫 OSC 7 掃描器追蹤 cwd(alacritty 不處理);
>   Flutter 側窗列 cwd 檔案、可導覽、跟隨 cwd、可拖寬(prefs 持久化)。
> - **簡易編輯器**:讀寫本地文字檔、原子存檔、外部變更偵測、二進位/大檔唯讀;
>   內嵌右側 pane 開在檔案側窗右邊(終端機保持可見),寬度可拖拉持久化,
>   換檔/X/Esc/關 SSH 分頁前 dirty 確認。
> - **拖到檔案總管**:windows/runner 加 native OLE(SHDoDragDrop + shell
>   IDataObject / CF_HDROP),檔案列拖出即複製到 Explorer(實機自動化驗證通過)。
> - **聽寫輸入 bug 修正**:Ctrl+V 一律貼上(對齊 Windows Terminal),讓 typeless
>   等口語轉文字工具的剪貼簿 fallback 生效;SendInput 式注入原本就走 IME 路徑。
> - 測試:OSC7 2、file pane/editor/drag 10、Flutter 全 79;實機:側窗列檔/導覽/
>   開編輯器/拖檔到 Explorer 複製成功。

> **進度(2026-07-21,第二輪)**:SSH 連線接進 app ✅
> - `tterm-ssh` 改 ring 後端(Windows 免 NASM,Flutter 打包鏈直接帶入);
>   host key TOFU + 指紋固定(不符拒絕連線)、記憶體私鑰認證(vault 存的私鑰文字)。
> - `Session::connect_ssh`:背景 tokio task 橋接 SSH ↔ 引擎;FFI ABI v4
>   (`tterm_session_connect_ssh` JSON 設定 + `ssh_fingerprint`)。
> - Dart:`NativeSession.connectSsh`(阻塞連線放背景 isolate)、分頁「連線中」
>   狀態;Host 連線鈕 → SSH 分頁,首次連線把指紋存回 host。
> - 側邊 tab list 可拖拉調寬(持久化);修正 Windows Ctrl 組合鍵
>   (character 為 null 時用 logicalKey 還原,Ctrl+A/E/C 實機驗證)。
> - 測試:Rust SSH 7(ssh_e2e 4 + ssh_abi 3,內建 russh server)、Flutter 65;
>   **實機冒煙**:vault host → 連線 → server banner → 輸入回聲 → TOFU 指紋回存。
> - 尚未做:known_hosts 變更的 UI 提示流程、SFTP/檔案樹、pane 分割、tmux。

> **進度(2026-07-21)**:Vault + 同步先行落地(原 Phase 3/4 的核心子集)✅
> - `tterm-vault`:record 模型(body 整包密文、AAD 綁 id)、XChaCha20-Poly1305、
>   HLC+LWW、衝突副本、tombstone、**RustDesk 式配對字串**(server+token+E2E key
>   一段字串,複製到其他 client 即完成設定;與 §5.1 master password 可並存,
>   升級路徑見 docs/vault-sync-design.md)。
> - `tterm-server`(axum):zero-knowledge blob 存放、seq cursor delta sync、
>   LWW 防舊蓋新、token 只存 SHA-256;Dockerfile;Windows 實機冒煙通過。
> - Client:FFI ABI v3(vault JSON 通道)+ Dart VaultService(debounce 推送、
>   離線保留 dirty、註冊失敗 rollback)+ Hosts/Keys 管理 UI + 設定頁
>   (建立/配對匯入匯出/立即同步/停用)。
> - **多分頁**:上方橫向/側邊垂直 tab list(設定切換)、快捷鍵、IndexedStack 保活。
> - 測試:Rust 15(vault 8 + ffi 3 + server 4)+ Flutter 57 全過。
> - 尚未做(維持在原 Phase 排程):master password/OS keychain、known_hosts/
>   snippet、WS push、protobuf wire、衝突 UI(目前自動衝突副本)、QR 配對。

### Phase 3 — Vault 與本地加密(4 週)
- 金鑰階層實作、master password 流程、OS keychain 整合。
- Identity / SSH key 管理(生成、匯入、匯出)。
- known_hosts 管理、snippet。

### Phase 4 — Sync server 與多裝置同步(4–6 週)
- tterm-server:帳號、認證、blob 儲存、delta sync API、WS push。
- Client 同步引擎、衝突 UI、裝置管理。
- Docker 部署包裝 + 自架文件。

### Phase 5 — tmux control mode 整合(4–5 週)
- `tterm-tmux`:control mode 協定解析、window/pane ↔ 原生分頁/pane 映射。
- Layout 雙向同步、斷線 re-attach、scrollback 原生化。
- Per-host「自動用 tmux 連線」設定。

### Phase 6 — Mobile 完整化(4 週)
- 觸控:選取、長按選單、捏合縮放字級;pane 改 swipe 切換(平板真分割)。
- 螢幕特殊鍵列(Esc/Ctrl/Tab/方向鍵)、外接鍵盤支援。
- iOS 背景限制對策:tmux re-attach 為主力(見風險);Android 前景服務保持連線。

### Phase 7 — 進階功能(持續)
- port forwarding UI、mosh 支援、serial(桌面)、
  agent forwarding、jump host / ProxyJump、team 共享 vault(多人)。

---

## 9. 主要風險與對策

| 風險 | 對策 |
|---|---|
| **iOS 背景會殺 TCP 連線**(SSH 斷線) | 主力對策:**tmux control mode 自動 re-attach**(斷線後畫面/程序全數復原);輔以 mosh(UDP,Blink Shell 同款做法)與自動重連;誠實告知平台限制 |
| **tmux control mode 協定複雜**(iTerm2 磨了多年;版本間行為差異、`%` 通知順序邊界情況多) | 鎖定支援 tmux ≥ 3.2 並明示;建整合測試矩陣(docker 跑多版本 tmux);先做唯讀映射(渲染正確)再開雙向 layout 同步 |
| **cwd 追蹤依賴 shell integration**(用戶未安裝就失效) | 一鍵安裝流程做到極順;`/proc` fallback;未偵測到 integration 時 UI 明確顯示「手動模式」而非壞掉的樣子 |
| 遠端編輯的資料安全(存檔失敗/權限/併發修改) | 原子寫入(temp + rename)、mtime 衝突偵測、存檔失敗時本地保留 buffer 草稿絕不丟字 |
| **主開發機為 Linux ARM64**,Flutter 官方無 linux-arm64 host SDK | 選項:(a) 社群 SDK 建置(zhzhzhy/Flutter-SDK-ARM64,追著 stable 出)於本機開發;(b) UI 開發放另一台 x64/macOS 機器,本機專注 Rust core/server;Android SDK 在 arm64 linux host 同樣非官方支援,mobile 建置預期放 (b) 或 CI |
| Flutter 文字渲染細節(CJK 寬度、ligature、fallback 字型) | Phase 0 就驗證;必要時字形量測與繪製全部自己控制(atlas 方案本來就繞過 Flutter 文字排版) |
| FFI 高頻傳輸開銷 | Damage-based 更新 + 共享 buffer;備案:Rust 端直接渲染成 GPU texture 給 Flutter 外嵌 |
| russh 對老舊 SSH server 演算法相容性 | 整理相容性矩陣;必要時 fallback libssh2 binding |
| ~~IME(中文輸入)在自繪 terminal 上的整合~~ ✅ 已解決(Phase 0) | `TextInputClient` 隱形輸入框:**可見字元全部走 IME 路徑**(中英文同一條),按鍵事件只管控制鍵;preedit 畫在游標處;`setCaretRect`/`setComposingRect` 讓候選字視窗跟隨游標。真實 shell + 模擬輸入法的端對端測試守住(`app/test/ime_test.dart`、`terminal_e2e_test.dart`、`ime_render_test.dart`) |
| 自架 TLS 門檻勸退用戶 | 內建 ACME + 詳細 reverse proxy 文件 + docker-compose 範例 |
| 密碼學實作錯誤 | 只用現成稽核過的庫;金鑰流程寫成 spec 文件;上線前做第三方 review |

---

## 10. 先不做(明確排除範圍)

- Web 版 client(與 native render 目標衝突,且 E2E 金鑰在瀏覽器風險高)。
- 官方雲端同步服務(以自架為主;架構上不排除未來提供)。
- Telnet 以外的 legacy 協定、RDP/VNC。
- Windows local shell 深度整合(ConPTY 本地 terminal 可列 Phase 5+)。
