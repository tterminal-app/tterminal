#!/usr/bin/env bash
# 在 macOS 上建置 tterminal 的 iOS app。
#
# iOS 不允許 dlopen 隨附的 dylib,所以 Rust 核心以 staticlib 連結進執行檔:
#   - ios/Flutter/*.xcconfig 用 -force_load 把 libtterm_ffi.a 連進 Runner
#   - Release 另設 EXPORTED_SYMBOLS_FILE(_tterm_*)擋 dead-strip 並讓
#     dart:ffi 的 DynamicLibrary.process() 查得到符號
#   - Dart 端(term_ffi.dart)在 iOS 走 DynamicLibrary.process()
#
# 流程:
#   1. cargo 建置 aarch64-apple-ios(裝置)+ aarch64-apple-ios-sim(模擬器)
#   2. flutter build ios --release --no-codesign → 未簽章裝置版
#   3. flutter build ios --simulator → 模擬器版
#
# 裝置部署要簽章:open app/ios/Runner.xcworkspace 用 Xcode 選 team 後
# 直接跑到接上的 iPhone(或 flutter run -d <device>)。
# 模擬器安裝:xcrun simctl install booted <模擬器版路徑>
#
# 注意:模擬器 .a 路徑寫死 aarch64-apple-ios-sim(Apple Silicon);
# Intel Mac 要另編 x86_64-apple-ios 並改 xcconfig。
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
core="$repo/core"
app="$repo/app"

step() { printf '\n\033[36m==> %s\033[0m\n' "$1"; }

step '檢查工具鏈'
if ! command -v flutter >/dev/null 2>&1 && [ -x "$HOME/flutter/bin/flutter" ]; then
    export PATH="$HOME/flutter/bin:$PATH"
fi
for tool in cargo flutter xcodebuild; do
    command -v "$tool" >/dev/null 2>&1 || { echo "找不到 $tool" >&2; exit 1; }
done

step '建置 Rust 核心(iOS staticlib × 2)'
cd "$core"
for target in aarch64-apple-ios aarch64-apple-ios-sim; do
    if ! rustup target list --installed | grep -q "$target"; then
        rustup target add "$target"
    fi
    cargo build --release -p tterm-ffi --target "$target"
done

step '建置 Flutter app(裝置 release,未簽章)'
cd "$app"
flutter build ios --release --no-codesign

step '建置 Flutter app(模擬器)'
flutter build ios --simulator

device_app="$app/build/ios/iphoneos/Runner.app"
sim_app="$app/build/ios/iphonesimulator/Runner.app"
exports=$(xcrun dyld_info -exports "$device_app/Runner" 2>/dev/null | grep -c tterm_ || true)
[ "$exports" -gt 0 ] || { echo "裝置版 Runner 沒有 tterm_* export,FFI 會掛" >&2; exit 1; }

printf '\n\033[32m  %s(裝置,未簽章,%s 個 FFI export)\033[0m\n' "$device_app" "$exports"
printf '\033[32m  %s(模擬器)\033[0m\n' "$sim_app"
echo
echo '裝置部署:open app/ios/Runner.xcworkspace 選 team 簽章後跑到 iPhone。'
echo '模擬器:xcrun simctl install booted '"$sim_app"' && xcrun simctl launch booted dev.tterm.ttermApp'
