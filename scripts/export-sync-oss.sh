#!/usr/bin/env bash
# 把同步伺服器 + tterm-vault 組成公開的開源 repo(tterminal-sync,AGPL-3.0)。
#
#   scripts/export-sync-oss.sh <目的目錄>
#
# monorepo 是唯一的原始碼來源;公開 repo 由這支腳本產生後再 commit/push。
# 目的目錄裡除了 .git 以外的東西都會被覆蓋。
#
# 版面:
#   server/  ← server/(去掉獨立的 [workspace],tterm-vault 改指 ../vault)
#   vault/   ← core/tterm-vault/
#   其餘     ← oss/sync/(README、LICENSE、Dockerfile、compose、CI、GitHub Pages 文件)
set -euo pipefail

dest=${1:?目的目錄}
repo=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$dest"
dest=$(cd "$dest" && pwd)

find "$dest" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +

cp -R "$repo/oss/sync/." "$dest/"
mkdir -p "$dest/server" "$dest/vault"
cp -R "$repo/server/src" "$repo/server/tests" "$dest/server/"
cp -R "$repo/core/tterm-vault/src" "$repo/core/tterm-vault/tests" "$dest/vault/"

python3 - "$repo" "$dest" <<'PY'
import re, sys
repo, dest = sys.argv[1], sys.argv[2]

server = open(f'{repo}/server/Cargo.toml').read()
server = re.sub(r'\n# 獨立於 core/ workspace[^\n]*\n\[workspace\]\n', '\n', server)
server = server.replace('path = "../core/tterm-vault"', 'path = "../vault"')
assert '[workspace]' not in server and '../vault' in server
if 'license =' not in server:
    server = server.replace('edition = "2021"\n', 'edition = "2021"\nlicense = "AGPL-3.0-only"\n', 1)
server = server.replace("\n\n\n", "\n\n")
open(f'{dest}/server/Cargo.toml', 'w').write(server)

vault = open(f'{repo}/core/tterm-vault/Cargo.toml').read()
vault = re.sub(r'^(#[^\n]*\n)+', '', vault)
if 'license =' not in vault:
    vault = vault.replace('edition = "2021"\n', 'edition = "2021"\nlicense = "AGPL-3.0-only"\n', 1)
open(f'{dest}/vault/Cargo.toml', 'w').write(vault)

open(f'{dest}/Cargo.toml', 'w').write('[workspace]\nresolver = "2"\nmembers = ["server", "vault"]\n')
open(f'{dest}/.gitignore', 'w').write('target/\ndata/\n')
PY

cd "$dest"
cargo generate-lockfile -q
echo "匯出到 $dest"
