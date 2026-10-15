<#
.SYNOPSIS
    在 Windows 上把 tterminal 打包成單一 standalone exe。

.DESCRIPTION
    Flutter 的 Windows 產物是一個資料夾(exe + DLL + data/),而且**不能從
    Linux/macOS 交叉編譯**(需要 MSVC)。這個腳本在 Windows 上跑完整流程:

      1. cargo 建置 Rust 核心 → tterm_ffi.dll
      2. flutter build windows --release → bundle 資料夾
      3. 把 bundle 壓成 zip
      4. 建置自解壓啟動器,把 zip 嵌進去
      5. 產出 dist\tterminal.exe(單一檔案,免安裝)

    產出的 exe 第一次執行會解壓到 %LOCALAPPDATA%\tterminal\app-<hash>,
    之後啟動直接跳過解壓。

.PARAMETER Configuration
    Flutter 建置模式,預設 release。

.PARAMETER SkipTests
    略過 cargo test 與 flutter test。

.EXAMPLE
    .\scripts\build-windows.ps1
#>
[CmdletBinding()]
param(
    [ValidateSet('release', 'profile')]
    [string]$Configuration = 'release',
    [switch]$SkipTests
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
$core = Join-Path $repo 'core'
$app = Join-Path $repo 'app'
$launcher = Join-Path $repo 'packaging\win-launcher'
$dist = Join-Path $repo 'dist'
$build = Join-Path $repo 'build-tmp'

function Step($message) {
    Write-Host ''
    Write-Host "==> $message" -ForegroundColor Cyan
}

function Require($command, $hint) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "找不到 $command。$hint"
    }
}

Step '檢查工具鏈'
Require 'cargo' '請安裝 Rust:https://rustup.rs'
Require 'flutter' '請安裝 Flutter SDK 並加入 PATH'
Write-Host "  cargo   $(cargo --version)"
Write-Host "  flutter $((flutter --version | Select-Object -First 1))"

# Flutter 的 Windows desktop 需要 Visual Studio 的 C++ 桌面開發工作負載
$doctor = flutter doctor -v 2>&1 | Out-String
if ($doctor -notmatch 'Visual Studio') {
    Write-Warning 'flutter doctor 沒偵測到 Visual Studio;缺少 C++ 桌面開發工作負載會建置失敗。'
}

Step '建置 Rust 核心(tterm_ffi.dll)'
Push-Location $core
try {
    if (-not $SkipTests) {
        # 只測 app 會用到的 crate。tterm-ssh 走 aws-lc-rs,在 Windows 上要額外裝
        # NASM 與 CMake;SSH 尚未接進 app,不該讓它擋住打包。
        cargo test --release -p tterm-term -p tterm-session -p tterm-ffi
        if ($LASTEXITCODE -ne 0) { throw 'cargo test 失敗' }
    }
    cargo build --release -p tterm-ffi -p tterm-selftest
    if ($LASTEXITCODE -ne 0) { throw 'cargo build 失敗' }
}
finally { Pop-Location }

$dll = Join-Path $core 'target\release\tterm_ffi.dll'
if (-not (Test-Path $dll)) { throw "找不到 $dll" }
Write-Host "  $dll  ($([math]::Round((Get-Item $dll).Length / 1MB, 1)) MB)"

Step "建置 Flutter app($Configuration)"
Push-Location $app
try {
    if (-not $SkipTests) {
        $env:TTERM_FFI_LIB = $dll
        flutter test
        if ($LASTEXITCODE -ne 0) { throw 'flutter test 失敗' }
    }
    flutter build windows --$Configuration
    if ($LASTEXITCODE -ne 0) { throw 'flutter build windows 失敗' }
}
finally { Pop-Location }

$flavor = @{ release = 'Release'; profile = 'Profile' }[$Configuration]
# Flutter 依建置機的 CPU 放產物:x64 機器 → build\windows\x64、ARM64 機器 → build\windows\arm64
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
$bundle = Join-Path $app "build\windows\$arch\runner\$flavor"
if (-not (Test-Path $bundle)) { throw "找不到 Flutter 產物:$bundle" }

# CMake 的 install 規則應該已經帶進來了,這裡再確認一次
$bundledDll = Join-Path $bundle 'tterm_ffi.dll'
if (-not (Test-Path $bundledDll)) {
    Copy-Item $dll $bundledDll
    Write-Host '  已補上 tterm_ffi.dll'
}
$appExe = Join-Path $bundle 'tterm_app.exe'
if (-not (Test-Path $appExe)) { throw "找不到 $appExe" }

Step '壓縮 bundle'
New-Item -ItemType Directory -Force -Path $build | Out-Null
$zip = Join-Path $build 'bundle.zip'
Remove-Item $zip -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory(
    $bundle, $zip, [System.IO.Compression.CompressionLevel]::Optimal, $false)
Write-Host "  $zip  ($([math]::Round((Get-Item $zip).Length / 1MB, 1)) MB)"

Step '建置單檔啟動器'
Push-Location $launcher
try {
    $env:TTERM_PAYLOAD = $zip
    cargo build --release
    if ($LASTEXITCODE -ne 0) { throw '啟動器建置失敗' }
}
finally {
    Remove-Item Env:\TTERM_PAYLOAD -ErrorAction SilentlyContinue
    Pop-Location
}

Step '輸出'
New-Item -ItemType Directory -Force -Path $dist | Out-Null
$out = Join-Path $dist 'tterminal.exe'
Copy-Item (Join-Path $launcher 'target\release\tterminal.exe') $out -Force
Copy-Item (Join-Path $core 'target\release\tterm-selftest.exe') (Join-Path $dist 'tterm-selftest.exe') -Force
# 免安裝的資料夾版(zip),給不想用自解壓單檔的人
Copy-Item $zip (Join-Path $dist "tterminal-windows-$arch-portable.zip") -Force

$sizeMb = [math]::Round((Get-Item $out).Length / 1MB, 1)
Write-Host ''
Write-Host "  $out  ($sizeMb MB)" -ForegroundColor Green
Write-Host "  $(Join-Path $dist 'tterm-selftest.exe')  (核心自我測試)" -ForegroundColor Green
Write-Host ''
Write-Host '完成。tterminal.exe 是單一檔案,可直接複製到任何 Windows 機器執行。'
