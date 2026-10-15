# tterm-server — 自架同步伺服器

zero-knowledge:server 只存加密 blob 與同步 metadata(record id / hlc / device /
deleted / seq),認證只存 token 的 SHA-256。拿到整個 data 目錄也解不開任何內容
(E2E 金鑰只存在各 client 的配對字串裡)。協定見
[docs/vault-sync-design.md](../docs/vault-sync-design.md)。

## 跑起來

```sh
cargo run --release            # 預設 0.0.0.0:8722,資料存 ./data
tterm-server --listen 0.0.0.0:8722 --data /var/lib/tterm
```

Docker(在 repo 根目錄建置,需要 core/tterm-vault 供測試依賴解析):

```sh
docker build -f server/Dockerfile -t tterm-server .
docker run -d --name tterm-sync -p 8722:8722 -v tterm-data:/data tterm-server
```

或用 docker compose(`restart: always`,docker 服務 enabled 時開機自動啟動):

```sh
cd server && docker compose up -d --build
```

部署只需要 `server/` 與 `core/tterm-vault/` 兩個目錄(tterm-vault 的 manifest
是自包含的,不依賴 core workspace 根)。

備份 = 複製 data 目錄(每個 vault 一個 JSON 檔,原子寫入)。

## TLS

server 本身只講 HTTP。要上公網請放在 reverse proxy 後面(Caddy 兩行搞定):

```
sync.example.com {
    reverse_proxy 127.0.0.1:8722
}
```

內網/LAN 直接用 `http://<ip>:8722` 即可(E2E 加密不依賴傳輸層,
但 token 走明文 HTTP 會暴露——內網自行衡量,公網一律上 TLS)。

## Client 設定流程

1. 第一台 client:設定頁 → 輸入 server URL → 「建立同步」。
2. 「匯出配對字串」複製(`TTERMSYNC1:...`,含 server 位置 + token + E2E key)。
3. 其他 client:設定頁 → 「貼上配對字串加入」→ 完成,自動同步。
