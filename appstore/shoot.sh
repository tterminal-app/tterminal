#!/usr/bin/env bash
# 在模擬器上自動拍 App Store 截圖(原始畫面,合成見 compose.py)。
#
#   appstore/shoot.sh <iphone|ipad|duo> <輸出目錄> [zh|en] [landscape]
#
# 只用專門建立的模擬器(名稱 tterm-shots-<機型>,沒有就自動建立),
# 絕不在平常開發用的模擬器上跑:flutter drive 跑完會解除安裝 app,
# 那台模擬器上 tterminal 的資料會跟著消失;流程也會寫入示範主機。
#
# 環境變數:FONT=18 終端字級;SCREEN=3 截哪個螢幕(iPhone Duo 內螢幕,見 simctl io <udid> enumerate)
#
# 會先備好:
#   * 示範 SSH 主機:docker 容器 tterm-demo(本機 127.0.0.1:22),tmux 場景見 demo-host/setup.sh
#   * homelab.local → 127.0.0.1(dns-sd 註冊 Bonjour 名稱,不動 /etc/hosts)
#   * 同步伺服器:server/ 的 tterm-server 跑在 127.0.0.1:8722
# 接著跑 integration_test/store_screenshots_test.dart,看到 TTERM_SCENE 就切 tmux 視窗、
# 看到 TTERM_SHOT 就用 simctl 截圖。每做完一步就在 127.0.0.1:8731 放一個確認檔,
# 測試等到確認才往下走:模擬器的日誌在機器忙的時候會晚好幾秒才到,只靠固定延遲
# 會拍到下一個畫面(甚至 app 已經結束)。
set -euo pipefail

profile=${1:?機型:iphone | ipad | duo}
out=${2:?輸出目錄}
locale=${3:-zh}
landscape=${4:-}

case "$profile" in
    iphone) devtype=com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max
            runtime=com.apple.CoreSimulator.SimRuntime.iOS-27-0 ;;
    ipad)   devtype=com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB
            runtime=com.apple.CoreSimulator.SimRuntime.iOS-27-0 ;;
    duo)    devtype=com.apple.CoreSimulator.SimDeviceType.iPhone-Duo
            runtime=com.apple.CoreSimulator.SimRuntime.iOS-27-1 ;;
    *) echo "不認得的機型:$profile" >&2; exit 1 ;;
esac

repo=$(cd "$(dirname "$0")/.." && pwd)
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode-27.1-RC.app/Contents/Developer}
if ! command -v flutter >/dev/null 2>&1 && [ -x "$HOME/flutter/bin/flutter" ]; then
    export PATH="$HOME/flutter/bin:$PATH"
fi
mkdir -p "$out"
out=$(cd "$out" && pwd)

step() { printf '\n\033[36m==> %s\033[0m\n' "$1"; }

step '示範 SSH 主機'
if ! docker inspect -f '{{.State.Running}}' tterm-demo 2>/dev/null | grep -q true; then
    docker rm -f tterm-demo >/dev/null 2>&1 || true
    docker run -d --name tterm-demo --hostname homelab -p 127.0.0.1:22:2222 \
        -e PASSWORD_ACCESS=true -e USER_NAME=dev -e USER_PASSWORD=tterm-test-123 \
        -e TZ=Asia/Taipei lscr.io/linuxserver/openssh-server >/dev/null
    sleep 6
    docker exec tterm-demo sh -c 'apk add --no-cache bash htop vim tmux git ncurses musl-locales >/dev/null'
fi
docker cp "$repo/appstore/demo-host/setup.sh" tterm-demo:/tmp/setup.sh
docker exec -e SHOT_LOCALE="$locale" tterm-demo sh /tmp/setup.sh

step 'homelab.local 與同步伺服器'
pids=()
if ! dscacheutil -q host -a name homelab.local | grep -q 127.0.0.1; then
    dns-sd -P homelab _ssh._tcp local 22 homelab.local 127.0.0.1 >/dev/null &
    pids+=($!)
    sleep 2
fi
if ! curl -fs http://127.0.0.1:8722/v1/health >/dev/null; then
    (cd "$repo/server" && cargo build --release -q)
    data=$(mktemp -d)
    "$repo/server/target/release/tterm-server" --listen 127.0.0.1:8722 --data "$data" >/dev/null 2>&1 &
    pids+=($!)
    sleep 1
fi
# 給測試輪詢的確認檔(只聽本機)
ack=$(mktemp -d)
python3 -m http.server 8731 --bind 127.0.0.1 --directory "$ack" >/dev/null 2>&1 &
pids+=($!)
# 結束時把背景服務收掉,模擬器也關掉:多台模擬器一起開著會把記憶體吃光
cleanup() {
    [ ${#pids[@]} -eq 0 ] || kill "${pids[@]}" 2>/dev/null || true
    rm -rf "$ack"
    [ -z "${udid:-}" ] || xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
}
trap cleanup EXIT

step 'Rust 核心(模擬器 staticlib)'
# Xcode 只負責連結 libtterm_ffi.a,不會重編;Rust 改過沒重編,app 會拿到舊的 FFI
(cd "$repo/core" && cargo build --release -q -p tterm-ffi --target aarch64-apple-ios-sim)

step '模擬器'
name="tterm-shots-$profile"
udid=$(xcrun simctl list devices -j | python3 -c '
import json, sys
name = sys.argv[1]
for devs in json.load(sys.stdin)["devices"].values():
    for d in devs:
        if d["name"] == name and d.get("isAvailable", True):
            print(d["udid"]); raise SystemExit
' "$name")
if [ -z "$udid" ]; then
    udid=$(xcrun simctl create "$name" "$devtype" "$runtime")
    echo "建立模擬器 $name($udid)"
fi
xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl bootstatus "$udid" -b >/dev/null
# app 跟著系統語言;鍵盤沒另外設定時也跟著語言(繁中 → 注音)。語言有變才重開機
case "$locale" in
    en) want_lang=en-US; want_region=en_US ;;
    *)  want_lang=zh-Hant-TW; want_region=zh_TW ;;
esac
cur_lang=$(xcrun simctl spawn "$udid" defaults read -g AppleLanguages 2>/dev/null | tr -d ' ()"\n')
if [ "$cur_lang" != "$want_lang" ]; then
    xcrun simctl spawn "$udid" defaults write -g AppleLanguages -array "$want_lang"
    xcrun simctl spawn "$udid" defaults write -g AppleLocale -string "$want_region"
    xcrun simctl shutdown "$udid"
    xcrun simctl boot "$udid"
    xcrun simctl bootstatus "$udid" -b >/dev/null
fi
xcrun simctl ui "$udid" appearance dark
# 模擬器跟 Mac 共用剪貼簿,鍵盤建議列會秀出剪貼簿內容——先清掉
printf '' | xcrun simctl pbcopy "$udid"
xcrun simctl status_bar "$udid" override --time 9:41 --batteryState discharging \
    --batteryLevel 100 --cellularBars 4 --wifiBars 3 --dataNetwork wifi

tmux_in() { docker exec tterm-demo su dev -s /bin/sh -c "tmux $1"; }
scene() {
    case "$1" in
        htop)
            tmux_in "select-window -t main:htop"
            tmux_in "send-keys -t main:htop.1 'clear; uptime; df -h / | tail -1' Enter" ;;
        git)
            tmux_in "select-window -t main:git"
            tmux_in "send-keys -t main:git 'clear; cd ~/code/homelab && git --no-pager log --graph --oneline --decorate --color=always -n 14; echo; git -c color.status=always status -sb' Enter" ;;
        notes)
            tmux_in "select-window -t main:notes" ;;
    esac
}

step "跑截圖流程($locale${landscape:+,橫放})"
cd "$repo/app"
flutter drive \
    --driver test_driver/integration_test.dart \
    --target integration_test/store_screenshots_test.dart \
    -d "$udid" \
    --dart-define=SHOT_LOCALE="$locale" \
    ${landscape:+--dart-define=SHOT_LANDSCAPE=true} \
    ${FONT:+--dart-define=SHOT_FONT_SIZE=$FONT} 2>&1 |
while IFS= read -r line; do
    line=${line%$'\r'}
    echo "$line"
    case "$line" in
        *TTERM_SCENE\ *)
            name=${line##*TTERM_SCENE }
            scene "$name"
            touch "$ack/scene-$name" ;;
        *TTERM_SHOT\ *)
            name=${line##*TTERM_SHOT }
            xcrun simctl io "$udid" screenshot ${SCREEN:+--display="$SCREEN"} "$out/$name.png" >/dev/null 2>&1
            touch "$ack/shot-$name"
            echo "    📸 $out/$name.png" ;;
    esac
done

ls -1 "$out"
