#!/bin/sh
# 在示範用的 SSH 容器(lscr.io/linuxserver/openssh-server,使用者 dev,家目錄 /config)
# 裡布置截圖場景。由 appstore/shoot.sh 透過 docker exec 執行。
set -e
H=/config

cat > $H/.bash_profile <<'RC'
export LANG=C.UTF-8 LC_ALL=C.UTF-8 TERM=xterm-256color
export PS1='\[\e[1;32m\]dev@homelab\[\e[0m\]:\[\e[1;36m\]\w\[\e[0m\]$ '
alias ls='ls --color=auto'
cd ~
# SSH 登入直接接上預先開好的 tmux session
[ -z "$TMUX" ] && [ -n "$SSH_CONNECTION" ] && exec tmux -u attach -t main
RC
cp $H/.bash_profile $H/.bashrc

cat > $H/.tmux.conf <<'TM'
set -g default-terminal "screen-256color"
set -g default-shell /bin/bash
set -g default-command "bash --login"
set -g window-size latest
set -g status-style "bg=#1f2329,fg=#9aa4b2"
set -g status-left "#[fg=#111111,bg=#4ade80,bold] homelab #[default] "
set -g status-left-length 20
set -g status-right "#[fg=#6b7280]%H:%M "
set -g window-status-format " #I #W "
set -g window-status-current-format "#[fg=#4ade80,bold] #I #W "
set -g pane-border-style "fg=#2a2e36"
set -g pane-active-border-style "fg=#4ade80"
TM

cat > $H/.vimrc <<'VI'
syntax on
set number
set termguicolors
silent! colorscheme habamax
set laststatus=2
set encoding=utf-8
VI

mkdir -p $H/notes
rm -f $H/notes/*.md
if [ "${SHOT_LOCALE:-zh}" = en ]; then
NOTES=deploy-notes.md
cat > $H/notes/$NOTES <<'MD'
# homelab notes

## Sync server
- Runs in docker: `docker compose up -d`
- Data lives in /srv/tterm, backed up to the NAS at 3 a.m.
- Reached over Tailscale only, no open ports

## This week
- [x] Retire the old Raspberry Pi in the living room
- [x] Sync tmux config to every box
- [ ] Auto-shutdown on UPS power loss
- [ ] Move Grafana onto the nas

## Reminders
root on nas: keys only, no passwords.
MD
else
NOTES=部署筆記.md
cat > $H/notes/$NOTES <<'MD'
# homelab 部署筆記

## 同步伺服器
- 跑在 docker:`docker compose up -d`
- 資料放 /srv/tterm,每天凌晨三點備份到 NAS
- 只走 Tailscale 連回來,不開對外的 port

## 這週要做
- [x] 換掉客廳那台舊的 Raspberry Pi
- [x] tmux 設定同步到每台機器
- [ ] UPS 斷電時自動關機
- [ ] Grafana 搬到 nas 上

## 備忘
nas 的 root 不開密碼登入,只收金鑰。
MD
fi

# 一個示範 repo(commit 訊息跟著語系)
rm -rf $H/code/homelab && mkdir -p $H/code/homelab && cd $H/code/homelab
git init -q -b main
git config user.name "dev"; git config user.email "dev@homelab"
c() { echo "$1" >> "${3:-CHANGELOG}"; git add -A; GIT_AUTHOR_DATE="$2" GIT_COMMITTER_DATE="$2" git commit -qm "$1"; }
if [ "${SHOT_LOCALE:-zh}" = en ]; then
  m1="Initial homelab config"; m2="Add Caddy reverse proxy"; m3="Run the sync server with docker compose"
  m4="Nightly backup to the NAS at 3 a.m."; m5="Email me when a backup fails"; m6="Fix timezone in tmux status bar"
  m7="nas: keys only, disable password login"; m8="UPS auto-shutdown (WIP)"
else
  m1="初始化 homelab 設定"; m2="加上 Caddy 反向代理設定"; m3="同步伺服器改用 docker compose"
  m4="每天凌晨三點備份到 NAS"; m5="備份失敗時寄信通知"; m6="修正 tmux 狀態列時區"
  m7="nas 改成只收金鑰登入"; m8="UPS 斷電自動關機(進行中)"
fi
c "$m1" "2026-09-01T10:00:00+08:00"
c "$m2" "2026-09-04T21:12:00+08:00"
c "$m3" "2026-09-10T23:40:00+08:00"
git checkout -qb feature/backup
c "$m4" "2026-09-18T01:05:00+08:00" backup.sh
c "$m5" "2026-09-19T08:30:00+08:00" backup.sh
git checkout -q main
c "$m6" "2026-09-20T12:00:00+08:00"
GIT_AUTHOR_DATE="2026-09-21T09:00:00+08:00" GIT_COMMITTER_DATE="2026-09-21T09:00:00+08:00" git merge -q --no-ff feature/backup -m "Merge branch 'feature/backup'"
c "$m7" "2026-10-02T22:18:00+08:00"
c "$m8" "2026-10-14T20:45:00+08:00"
git tag v1.2.0 HEAD~1
echo "ups:" > ups.yml
chown -R 911:911 $H

# 預先開好 tmux session(以 dev 身分)
su dev -s /bin/sh -c "tmux kill-server 2>/dev/null; sleep 1; cd /config && tmux -u new-session -d -s main -n htop htop \\; split-window -v -l 30% \\; new-window -n git \\; new-window -n notes -c /config/notes 'vim $NOTES' \\; select-window -t main:htop"
echo setup-ok
