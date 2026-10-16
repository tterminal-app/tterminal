#!/usr/bin/env bash
# 公證 macOS 桌面版並釘上票據,別台 Mac 下載後直接雙擊就能開(不用右鍵→打開)。
#
#   scripts/notarize-macos.sh <版本號>
#
# 前提:dist/tterminal.app 已用 Developer ID 簽章
#   TTERM_SIGN_IDENTITY="Developer ID Application: ..." scripts/build-macos.sh
#
# 產出 dist/tterminal-<版本>-macos-universal.zip 與 .dmg,兩者都已公證:
#   1. app 壓成 zip 送公證 → 票據釘到 app 上(zip 本身不能釘;解壓出來的 app 離線也認得)
#   2. 用釘好的 app 重新壓 zip、做 DMG → DMG 簽章後再送一次公證 → 票據釘到 DMG 上
#
# 公證帳號(擇一):
#   TTERM_NOTARY_PROFILE=<名稱>
#       本機:先用 xcrun notarytool store-credentials <名稱> ... 存進鑰匙圈
#   APPLE_API_KEY_PATH、APPLE_API_KEY_ID、APPLE_API_ISSUER
#       CI:App Store Connect API 金鑰(.p8 的路徑、Key ID、Issuer ID)
set -euo pipefail

version=${1:?版本號,例如 1.0.0}
repo=$(cd "$(dirname "$0")/.." && pwd)
dist="$repo/dist"
app="$dist/tterminal.app"
identity=${TTERM_SIGN_IDENTITY:?需要 TTERM_SIGN_IDENTITY(跟建置時同一個 Developer ID)}

if [ -n "${TTERM_NOTARY_PROFILE:-}" ]; then
    auth=(--keychain-profile "$TTERM_NOTARY_PROFILE")
elif [ -n "${APPLE_API_KEY_PATH:-}" ]; then
    auth=(--key "$APPLE_API_KEY_PATH" --key-id "${APPLE_API_KEY_ID:?}" --issuer "${APPLE_API_ISSUER:?}")
else
    echo "沒有公證帳號:設 TTERM_NOTARY_PROFILE,或 APPLE_API_KEY_PATH / APPLE_API_KEY_ID / APPLE_API_ISSUER" >&2
    exit 1
fi

step() { printf '\n\033[36m==> %s\033[0m\n' "$1"; }

# 送公證並等結果;沒通過就把 Apple 的紀錄印出來(會寫是哪個檔案簽得不對)
notarize() {
    local out status id
    out=$(xcrun notarytool submit "$1" "${auth[@]}" --wait --output-format json) || true
    echo "$out"
    status=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("status",""))' "$out" 2>/dev/null || true)
    if [ "$status" != Accepted ]; then
        id=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("id",""))' "$out" 2>/dev/null || true)
        [ -z "$id" ] || xcrun notarytool log "$id" "${auth[@]}" || true
        echo "公證沒通過($status):$1" >&2
        exit 1
    fi
}

step '檢查簽章'
codesign --verify --deep --strict "$app"
# 先存起來再比對:直接接 grep -q 的話,grep 提早結束會讓 codesign 收到 SIGPIPE,
# 在 pipefail 下整條管線算失敗
sig=$(codesign -dv "$app" 2>&1)
if ! grep -q 'flags=.*runtime' <<<"$sig"; then
    echo "$app 沒有 hardened runtime:要用 Developer ID 重新建置(TTERM_SIGN_IDENTITY)" >&2
    exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

step '公證 app'
ditto -c -k --keepParent "$app" "$tmp/tterminal.zip"
notarize "$tmp/tterminal.zip"
xcrun stapler staple "$app"

step 'zip'
zip="$dist/tterminal-$version-macos-universal.zip"
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"

step 'DMG'
dmg="$dist/tterminal-$version-macos-universal.dmg"
mkdir "$tmp/dmg"
ditto "$app" "$tmp/dmg/tterminal.app"
ln -s /Applications "$tmp/dmg/Applications"
rm -f "$dmg"
hdiutil create -volname tterminal -srcfolder "$tmp/dmg" -ov -format UDZO "$dmg"
codesign --force --timestamp --sign "$identity" "$dmg"
notarize "$dmg"
xcrun stapler staple "$dmg"

step 'Gatekeeper 檢查'
spctl --assess -vv --type exec "$app"
spctl --assess -vv --type open --context context:primary-signature "$dmg"
xcrun stapler validate "$app"
xcrun stapler validate "$dmg"
printf '\n\033[32m  %s\n  %s\033[0m\n' "$zip" "$dmg"
