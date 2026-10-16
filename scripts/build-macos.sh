#!/usr/bin/env bash
# 在 macOS 上把 tterminal 打包成可散佈的 .app。
#
# Flutter 的 macOS release 產物是 universal(arm64 + x86_64)的 .app bundle,
# 所以 Rust 核心兩個架構各編一份,再用 lipo 合成 universal dylib。流程:
#
#   1. cargo 建置 Rust 核心(host + 另一個架構)→ lipo 成 universal libtterm_ffi.dylib
#   2. flutter build macos --release → tterminal.app
#   3. 把 dylib 塞進 tterminal.app/Contents/MacOS/(term_ffi.dart 會在 exe 旁邊找)
#   4. 重新簽章(塞了 dylib 之後原本的 bundle 簽章已失效)
#   5. 產出 dist/tterminal.app + dist/tterminal-macos.zip + dist/tterm-selftest
#
# 用法:
#   scripts/build-macos.sh               # 完整流程(含 cargo test 與 flutter test)
#   scripts/build-macos.sh --skip-tests  # 只建置
#
# 預設 ad-hoc 簽章(其他機器首次開啟要右鍵→打開)。有 Developer ID 憑證時:
#   TTERM_SIGN_IDENTITY="Developer ID Application: ..." scripts/build-macos.sh
# 會加上 hardened runtime 與安全時間戳記(公證的必要條件),公證見 scripts/notarize-macos.sh。
set -euo pipefail

skip_tests=0
for arg in "$@"; do
    case "$arg" in
        --skip-tests) skip_tests=1 ;;
        *) echo "未知參數:$arg" >&2; exit 2 ;;
    esac
done

repo=$(cd "$(dirname "$0")/.." && pwd)
core="$repo/core"
app="$repo/app"
dist="$repo/dist"
build="$repo/build-tmp"
sign_identity="${TTERM_SIGN_IDENTITY:--}"

step() { printf '\n\033[36m==> %s\033[0m\n' "$1"; }

step '檢查工具鏈'
# flutter 常常沒加進 PATH,幫忙找一下預設安裝位置
if ! command -v flutter >/dev/null 2>&1 && [ -x "$HOME/flutter/bin/flutter" ]; then
    export PATH="$HOME/flutter/bin:$PATH"
fi
for tool in cargo flutter xcodebuild lipo codesign; do
    command -v "$tool" >/dev/null 2>&1 || { echo "找不到 $tool" >&2; exit 1; }
done
echo "  cargo   $(cargo --version)"
echo "  flutter $(flutter --version 2>/dev/null | head -1)"

# host 架構 + 交叉架構(在 Apple Silicon 上補 x86_64,在 Intel 上補 arm64)
host_arch=$(uname -m)   # arm64 或 x86_64
if [ "$host_arch" = arm64 ]; then
    cross_target=x86_64-apple-darwin
else
    cross_target=aarch64-apple-darwin
fi

step '建置 Rust 核心(universal libtterm_ffi.dylib)'
cd "$core"
if [ "$skip_tests" = 0 ]; then
    # 跟 Windows 腳本一樣只測 app 會用到的 crate(tterm-ssh 是 dev-dependency 路徑)
    cargo test --release -p tterm-term -p tterm-session -p tterm-ffi
fi
cargo build --release -p tterm-ffi -p tterm-selftest
if ! rustup target list --installed | grep -q "$cross_target"; then
    echo "  安裝 $cross_target target…"
    rustup target add "$cross_target"
fi
cargo build --release -p tterm-ffi --target "$cross_target"

mkdir -p "$build"
dylib="$build/libtterm_ffi.dylib"
lipo -create \
    "$core/target/release/libtterm_ffi.dylib" \
    "$core/target/$cross_target/release/libtterm_ffi.dylib" \
    -output "$dylib"
echo "  $dylib($(lipo -archs "$dylib"))"

step '建置 Flutter app(release)'
cd "$app"
if [ "$skip_tests" = 0 ]; then
    TTERM_FFI_LIB="$core/target/release/libtterm_ffi.dylib" flutter test
fi
flutter build macos --release

bundle="$app/build/macos/Build/Products/Release/tterminal.app"
[ -d "$bundle" ] || { echo "找不到 Flutter 產物:$bundle" >&2; exit 1; }

step '把 dylib 塞進 bundle 並重新簽章'
cp "$dylib" "$bundle/Contents/MacOS/libtterm_ffi.dylib"
sign_opts=()
if [ "$sign_identity" != "-" ]; then
    # 公證要求 hardened runtime 與安全時間戳記;ad-hoc 不需要(也拿不到時間戳記)
    sign_opts=(--options runtime --timestamp)
fi
sign() { codesign --force ${sign_opts[@]+"${sign_opts[@]}"} --sign "$sign_identity" "$@"; }
# 由內而外:Flutter 的 framework 原本是 ad-hoc 簽章,公證時每一層都要是同一個 Developer ID
for fw in "$bundle"/Contents/Frameworks/*.framework; do
    sign "$fw"
done
sign "$bundle/Contents/MacOS/libtterm_ffi.dylib"
sign --entitlements "$app/macos/Runner/Release.entitlements" "$bundle"
codesign --verify --deep --strict "$bundle"
echo "  簽章:$sign_identity(驗證通過)"

step '輸出'
mkdir -p "$dist"
rm -rf "$dist/tterminal.app"
ditto "$bundle" "$dist/tterminal.app"
rm -f "$dist/tterminal-macos.zip"
ditto -c -k --keepParent "$dist/tterminal.app" "$dist/tterminal-macos.zip"
cp "$core/target/release/tterm-selftest" "$dist/tterm-selftest"

app_mb=$(du -sm "$dist/tterminal.app" | cut -f1)
zip_mb=$(du -sm "$dist/tterminal-macos.zip" | cut -f1)
printf '\n\033[32m  %s(%s MB,%s)\033[0m\n' "$dist/tterminal.app" "$app_mb" \
    "$(lipo -archs "$dist/tterminal.app/Contents/MacOS/tterminal" 2>/dev/null || echo '?')"
printf '\033[32m  %s(%s MB)\033[0m\n' "$dist/tterminal-macos.zip" "$zip_mb"
printf '\033[32m  %s(核心自我測試,%s)\033[0m\n' "$dist/tterm-selftest" "$host_arch"
echo
echo '完成。tterminal.app 可直接執行;zip 可複製到其他 Mac(ad-hoc 簽章時首次開啟需右鍵→打開)。'
