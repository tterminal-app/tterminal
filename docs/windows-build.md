# Windows standalone exe

## 為什麼不能在 Linux 上直接產出

Rust 的部分沒問題 —— `tterm_ffi.dll`、`tterm-selftest.exe` 都可以用 mingw-w64
從 Linux 交叉編譯(本專案已驗證)。

但 **Flutter 不支援跨作業系統編譯 desktop 目標**:Windows embedder 需要 MSVC
(`cl.exe`)與 Windows SDK,官方沒有交叉編譯路徑,Wine 也不是可行方案。
所以 app 的 exe 一定要在 **Windows 機器或 CI 的 windows runner** 上建置。

## 方式一:自己的 Windows 機器(最快拿到 exe)

前置需求:

| 工具 | 說明 |
|---|---|
| [Rust](https://rustup.rs) | 預設 MSVC toolchain 即可 |
| [Flutter SDK](https://docs.flutter.dev/get-started/install/windows) | stable channel |
| Visual Studio 2022 Build Tools | 要勾 **使用 C++ 的桌面開發**(Flutter Windows embedder 需要) |

> **不需要 NASM / CMake。** app 用到的 `tterm-ffi` 只依賴終端引擎與 session,
> 不含 SSH。`tterm-ssh` 走 `aws-lc-rs`,在 Windows 上編譯才需要 NASM 與 CMake ——
> 打包腳本的測試步驟已刻意跳過它。等 Phase 1 把 SSH 接進 app 時,
> 可考慮改用 russh 的 `ring` 後端來免掉這個相依。

把整個 repo 複製到 Windows 機器後:

```powershell
.\scripts\build-windows.ps1
```

產出:

```
dist\tterminal.exe        ← 單一檔案,免安裝,可直接複製到任何 Windows 機器
dist\tterm-selftest.exe   ← 核心自我測試
```

想跳過測試加快建置:`.\scripts\build-windows.ps1 -SkipTests`

## 方式二:GitHub Actions(不需要自己的 Windows 機器)

`.github/workflows/build.yml` 的 `windows-exe` job 會跑同一支腳本,並把
`tterminal.exe` 當成 artifact 上傳。需要先把專案推上 GitHub(目前還不是 git repo):

```sh
git init && git add -A && git commit -m "initial"
gh repo create tterminal --private --source=. --push
```

之後每次 push 或手動觸發 workflow,都能在 Actions 頁面下載
`tterminal-windows-x64` artifact。

## 單一 exe 是怎麼做到的

Flutter 的 Windows 產物是一個資料夾(`tterm_app.exe` + `flutter_windows.dll` +
`tterm_ffi.dll` + `data/`),不是單一檔案。`packaging/win-launcher` 是一個自解壓
啟動器:

1. 建置時把整份 bundle 壓成 zip,用 `include_bytes!` 嵌進啟動器執行檔。
2. 執行時解壓到 `%LOCALAPPDATA%\tterminal\app-<payload 雜湊>`,
   寫入完成標記後啟動真正的 `tterm_app.exe`,命令列參數原樣傳遞。
3. 之後每次啟動看到標記就直接跳過解壓(實測第二次啟動 3 ms)。
4. payload 換版本 → 雜湊改變 → 解壓到新目錄,升級自動生效。

啟動器本身是 GUI subsystem(不會閃出主控台視窗),只依賴 Windows 系統 DLL,
並且擋掉了 zip slip(壓縮檔內的 `..` 路徑逃逸)。

## 先驗核心:tterm-selftest.exe

這支不需要 Flutter,已經交叉編譯好放在 `dist/`,可以現在就複製到 Windows 執行。
它驗證的是 Linux 開發機上測不到的東西:

- 終端引擎:VT 解析、CJK 寬字元、truecolor、scrollback、吞吐量
- **ConPTY**:開啟 `cmd.exe`、執行指令、讀回輸出、調整視窗尺寸
- **中文 UTF-8 往返**(Windows 舊版 console 代碼頁是常見地雷)

直接雙擊執行即可(結束前會等你按 Enter);CI 用 `--no-pause`。

### 實機結果(2026-07-20,windows / x86_64)

```
  [PASS] VT 解析與換行
  [PASS] CJK 寬字元佔兩格  —  游標在 col 12
  [PASS] truecolor 與粗體
  [PASS] scrollback 捲動  —  歷史 77 行
  [PASS] 引擎吞吐量  —  97 MiB/s,grid 拷貝 0.01 ms/frame
  [PASS] 開啟系統 shell(ConPTY)
  [PASS] shell 執行指令並回傳輸出
  [PASS] 中文 UTF-8 往返
  [PASS] 調整視窗尺寸  —  80x24 → 100x30
  全部通過(9/9)
```

97 MiB/s 遠超過實際需求(SSH 連線頻寬與人眼可辨識的輸出速度都低得多),
grid 拷貝 0.01 ms 對 16.6 ms 的 frame 預算幾乎沒有成本。
