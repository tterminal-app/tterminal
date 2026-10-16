#!/usr/bin/env bash
# 把 macOS 簽章與公證要用的東西存成 GitHub Actions secrets(.github/workflows/release.yml 會讀)。
# 自己在終端機跑:.p12 的密碼用提示輸入,不會留在指令列或 shell 歷史裡。
#
#   scripts/set-macos-signing-secrets.sh <Developer ID 的 .p12> <AuthKey_XXXX.p8> <Key ID> <Issuer ID> [owner/repo]
#
# 準備:
#   .p12  鑰匙圈存取 →「Developer ID Application: …」按右鍵 → 輸出 → 個人資訊交換(.p12),設一組密碼
#   .p8   App Store Connect → 使用者與存取權限 → 整合 → App Store Connect API → 團隊金鑰,
#         角色選「開發者」;.p8 只能下載一次,Key ID 與 Issuer ID 在同一頁
#
# 會設定:MACOS_CERT_P12、MACOS_CERT_PASSWORD、APPLE_API_KEY、APPLE_API_KEY_ID、APPLE_API_ISSUER
set -euo pipefail

p12=${1:?Developer ID 的 .p12 路徑}
p8=${2:?App Store Connect API 金鑰 .p8 路徑}
key_id=${3:?Key ID}
issuer=${4:?Issuer ID}
repo=${5:-tterminal-app/tterminal}

command -v gh >/dev/null || { echo "需要 gh(GitHub CLI)" >&2; exit 1; }
[ -f "$p12" ] || { echo "找不到 $p12" >&2; exit 1; }
[ -f "$p8" ] || { echo "找不到 $p8" >&2; exit 1; }

read -r -s -p ".p12 的密碼:" P12_PASSWORD
echo
export P12_PASSWORD
# 先確認密碼對、裡面是 Developer ID Application(不是 Apple Development)。
# 鑰匙圈匯出的 .p12 用舊式加密(RC2 / 3DES):系統內建的 LibreSSL 讀得了,
# Homebrew 的 OpenSSL 3 以上要加 -legacy 才讀得了
read_p12() {
    if [ -x /usr/bin/openssl ] && /usr/bin/openssl pkcs12 -in "$p12" -nokeys -passin env:P12_PASSWORD 2>"$err"; then
        return 0
    fi
    openssl pkcs12 -legacy -in "$p12" -nokeys -passin env:P12_PASSWORD 2>>"$err"
}
err=$(mktemp)
trap 'rm -f "$err"' EXIT
certs=$(read_p12) || true
if ! grep -q 'Developer ID Application' <<<"$certs"; then
    echo "打不開 $p12,或裡面不是 Developer ID Application 憑證。openssl 的訊息:" >&2
    sed 's/^/  /' "$err" >&2
    exit 1
fi

echo "設定 $repo 的 secrets…"
base64 -i "$p12" | gh secret set MACOS_CERT_P12 --repo "$repo"
printf '%s' "$P12_PASSWORD" | gh secret set MACOS_CERT_PASSWORD --repo "$repo"
base64 -i "$p8" | gh secret set APPLE_API_KEY --repo "$repo"
printf '%s' "$key_id" | gh secret set APPLE_API_KEY_ID --repo "$repo"
printf '%s' "$issuer" | gh secret set APPLE_API_ISSUER --repo "$repo"
gh secret list --repo "$repo"
