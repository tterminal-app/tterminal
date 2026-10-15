# Vault 與多裝置同步 — 設計文件

> 對應 PLAN.md §3(資料模型)、§4(同步協定)、§5(安全)、§6(自架 server)。
> 本文件是實作的依據;與 PLAN 的差異處會明確標註並說明理由。

## 0. 目標與取捨

- **Termius 式 Vault**:Hosts、SSH Keys 管理,之後可擴充 Identity / Snippet / Port Forward。
- **Self-host 優先**:同步 server 是自己架的單一 binary;沒有帳號系統、沒有註冊流程。
- **RustDesk 式配對**(與 PLAN §5.1 的 master-password 流程不同,是使用者明確要求):
  第一台 client 建立同步後產生一段**可複製的配對字串**,其他 client 貼上即完成設定。
  配對字串同時攜帶 server 位置、vault 識別、認證 token 與 **E2E 加密金鑰**。
- **Zero-knowledge 不變**:server 只存密文 blob 與同步用的最小 metadata,
  拿到 server 資料庫也解不開任何內容(金鑰只存在配對字串與各 client 本地)。
- **離線優先**:vault 完全本地可用;同步是可選的附加功能。

### 與 PLAN §5.1(master password / Argon2id)的關係

PLAN 的金鑰階層是「master password → Argon2id → master key → wrap vault key」。
本階段直接使用**隨機 256-bit vault key**,以配對字串傳遞——這正是 RustDesk 模式:
金鑰的安全性來自「配對字串只在你自己的裝置間流動」,不是來自密碼強度。

升級路徑(之後做 master password 時**不需要重新加密資料**):
master password 只是把 vault key **wrap 一層**存在 server(PLAN §5.1 本來就這樣設計),
新裝置可改用「輸入密碼解 wrapped key」取代「貼配對字串」。兩種上車方式可並存。

## 1. 資料模型

### 1.1 Record(同步的最小單位)

```
Record {
  id:      Uuid          # 明文(server 可見,同步定址用)
  hlc:     u64           # 明文(混合邏輯時鐘,LWW 排序用)
  device:  String        # 明文(產生此版本的裝置 id,HLC 平手時的決勝)
  deleted: bool          # 明文(tombstone)
  body:    {             # ← 以下全部在加密 blob 內,server 不可見
    kind:  "host" | "ssh_key" | ...
    name:  String
    data:  JSON          # 各 kind 自訂欄位,core 不解讀(UI 層的 schema)
  }
}
```

- 與 PLAN §3 的差異:PLAN 把 `type` 列為 server 可見的通用欄位;
  這裡**連 kind 都藏進密文**——server 只知道「有一筆 record 變了」,更嚴格且無代價。
- `data` 是自由 JSON,Rust core 不解讀。新增 entity 種類(Snippet、PortForward…)
  不需要動 core 與 server,只要 UI 認得新 kind。

### 1.2 目前 UI 使用的 kind schema

`host`:
```json
{ "address": "example.com", "port": 22, "username": "root",
  "auth": {"method": "password" | "key" | "none", "keyId": "<uuid>?", "password": "?"},
  "note": "", "pinned": true,
  "hostKeyFingerprint": "SHA256:...?" }
```

`hostKeyFingerprint` 是第一次連線時記下的 host key 指紋(TOFU),之後每次連線都比對,
不符就拒絕(core 回錯誤代碼 `host_key_mismatch`,帶新舊指紋)。要換掉它只有兩條路,
都要使用者明確動作:錯誤畫面上勾選「已核對新指紋」後改用新指紋,或在編輯 Host
手動清除(位址 / port 改了也會一併清除,那是舊主機的指紋);清除後下次連線重新記住。

`ssh_key`:
```json
{ "privateKey": "-----BEGIN OPENSSH PRIVATE KEY-----...",
  "passphrase": "", "note": "" }
```

(密碼與私鑰內容都在 record body 內,一律走加密 blob,server 永遠看不到。)

公鑰**不存**:UI 要顯示 / 複製時,由 `tterm_ssh_public_key` 從私鑰現算
(OpenSSH 私鑰的公鑰段是明文,設了 passphrase 也算得出來),存了反而要
跟私鑰保持同步。

在 app 內產生的金鑰(Keys →「產生金鑰」,`tterm_ssh_generate_key`:ed25519 或
RSA 4096)存的也是同一種 record:OpenSSH 格式私鑰,設了 passphrase 就以
aes256-ctr + bcrypt-pbkdf 加密(與 ssh-keygen 相同),passphrase 一併存在 `passphrase`。

### 1.3 HLC(混合邏輯時鐘)

`hlc = max(wall_clock_ms, last_hlc/1000 + 1) * 1000 + counter`,單調遞增;
比較順序:先比 `hlc`,平手比 `device`(字典序)。跨裝置時鐘漂移不會讓舊資料蓋新資料
(收到遠端 record 時,本地時鐘往前推進到不小於對方)。

## 2. 加密

- 演算法:**XChaCha20-Poly1305**(RustCrypto `chacha20poly1305`,PLAN §1.3 選型)。
- **vault key**:隨機 32 bytes,第一次開 vault 時在本地產生。
- **Wire(同步)**:每筆 record 的 `body` 單獨加密:
  `blob = nonce(24B) || seal(key, nonce, plaintext=json(body), aad=record_id)`。
  AAD 綁 record id,防止 server 把 A 記錄的密文搬到 B 記錄上。
- **At rest(本地)**:整個 vault 狀態(records + 同步設定)序列化成 JSON 後整份加密
  存 `vault.tv`。vault key 由 `KeyStore`(tterm-vault `keystore.rs`)保管,`vault.tv`
  格式不變:
  - **iOS / macOS**:系統 Keychain 的 generic password
    (service `dev.tterm.tterminal.vault`、account `vault-key`)。Rust 直接呼叫
    Security.framework(tterm-ffi `keychain.rs`),key 不經過 Dart / Swift。
    - iOS accessibility = `kSecAttrAccessibleAfterFirstUnlock`:開機解鎖過一次後,
      鎖屏中背景開 vault 也讀得到;不加 ThisDeviceOnly,加密備份(iCloud 備份一律加密)
      還原到新手機時 key 跟著 `vault.tv` 一起回來。不同步到 iCloud 鑰匙圈。
    - macOS 存登入鑰匙圈(app 沒有 team 簽章,用不了 data protection keychain)。
  - **Windows / Linux**:暫時仍是旁邊的 `vault.key`(base64),之後接 DPAPI /
    Secret Service 時實作一個 `KeyStore` 即可。
  - **舊版升級**:開啟時把 `vault.key` 寫進 Keychain、讀回確認是同一把才刪檔;
    寫不進去就照舊用檔案開,下次再搬。Keychain 讀取失敗(鎖定、拒絕存取)直接報錯,
    絕不當成「沒有 key」。
  - **換 key**(貼配對字串):Keychain 先放「新、舊」兩把 → 新 key 寫 `vault.tv`
    (原子 rename)→ 只留新的。任何一步中斷,Keychain 都有一把解得開 `vault.tv`。
  - **沒有任何 key 解得開**(例:未加密備份還原到另一台,Keychain 沒跟過來):
    原檔改名 `vault.tv.unreadable-<ms>` 保留、開新 vault,使用者還能重新配對拿回同步資料。

## 3. 配對字串(RustDesk 式)

```
TTERMSYNC1:<base64url(json)>
json = {
  "v": 1,
  "server": "http://192.168.1.10:8722",   # 同步 server 位置
  "vault":  "<uuid>",                      # vault 識別
  "token":  "<base64 32B>",                # server 認證用 bearer token
  "key":    "<base64 32B>"                 # E2E vault key(server 無此值)
}
```

- 一段字串攜帶完整設定,**複製給其他 client 貼上即完成同步設定**。
- `token` 給 server 驗身分(server 只存 SHA-256(token));`key` 解密資料,兩者分離:
  拿到 server 資料庫(有 token hash)仍解不開 blob。
- 洩漏配對字串 = 洩漏整個 vault(與 RustDesk 的 ID+密碼同級)。UI 匯出時明確警示。
- 之後可加:QR code 顯示(mobile 掃描)、一次性配對碼(server 中繼、限時失效)。

## 4. Server API(tterm-server)

自架、單 binary、無帳號。資料存檔案系統(`data/<vault_id>/`),原子寫入。
JSON wire(PLAN §4 的 protobuf 之後在 proto/ 統一定義後切換;目前量小,JSON 可讀性優先)。

```
GET  /v1/health
     → 200 {"ok":true,"version":"..."}

POST /v1/vaults
     body {"vault_id":"<uuid>","auth":"<base64 sha256(token)>"}
     → 201 {}                # client 自產 vault_id 與 token;server 只存 hash
     → 409 已存在

以下都需要 Authorization: Bearer <token>(server 端 sha256 比對):

POST /v1/vaults/:id/records          # push(delta 上行)
     body [{"id","hlc","device","deleted","blob":"<b64>"}...]
     → 200 {"seq": <此批最後的 server seq>}
     規則:server 對每筆比較 hlc(+device 決勝),舊版本直接丟棄(回應中不報錯,
     幂等);接受的每筆 assign 遞增 seq。

GET  /v1/vaults/:id/records?since=<seq>   # pull(delta 下行)
     → 200 {"records":[...同上格式 + "seq"...], "next": <目前最大 seq>}
```

- `seq` 是 server 端單調遞增的變更序號(per vault):client 記住 `next` 當 cursor,
  下次只拉增量——即 PLAN §4 的 delta sync(`last_sync_cursor`)。
- **WebSocket push 之後再加**(PLAN §4 本來就標可選);目前「開 app 拉一次 +
  變更後推送 + 手動立即同步」已滿足單人多裝置場景。
- 建立 vault 預設開放(自己的 server);之後可加 `--require-admin-token` 關閉。

## 5. 同步流程(client 端)

```
sync():
  1. push:收集 dirty records(本地建立/修改/刪除過、尚未推送)
     → 加密 body → POST /records → 成功後清 dirty 標記
  2. pull:GET /records?since=<cursor>
     → 每筆解密後與本地做 LWW 合併 → cursor = next
  3. 任一步網路失敗:保留 dirty 與 cursor,下次重試(離線優先,永不丟資料)
```

觸發時機:app 啟動、vault 有變更(debounce 2s)、設定頁「立即同步」。

### 衝突規則(PLAN §4:「不靜默覆蓋」)

- 一般情況 LWW:hlc 新者勝。
- **雙方都改過同一筆**(收到的遠端版本 hlc 較新,但本地同筆還掛著 dirty 未推送):
  遠端版本成為正式版,**本地版本另存為衝突副本**
  (新 id、name 加註「(衝突副本 <device> <時間>)」、標 dirty 會被推上去)。
  加註的樣板由 UI 依語系給(`tterm_vault_set_conflict_name_template`),
  所以副本名稱是建立它那台裝置的語言。
  密碼/私鑰永不因同步而消失;使用者事後在列表裡自行取捨。
- 刪除:tombstone 參與同一套 LWW;GC(90 天)之後做。

### 加入既有 vault(貼配對字串)

- 本地 vault 是空的 → 直接採用配對字串的身分(vault_id/token/key),拉全量。
- 本地已有資料 → 本地 records **重新以新 key 加密、換新 id 標 dirty**,
  併入加入的 vault(下次 push 全部上傳)——兩邊資料合流,不丟任何一邊。

## 6. UI 流程

### 6.1 Vaults 管理

- 入口:app 工具列「Vaults」按鈕 → 全頁(Hosts / Keys 兩個分頁)。
- Hosts:列表(名稱、user@address:port)、新增/編輯 dialog(名稱、位址、port、
  使用者、認證方式:密碼/金鑰(下拉選 vault 內的 key)/無、備註)、刪除(確認)。
  「連線」按鈕預留(SSH 接入是 PLAN Phase 1 的下一步,先 disabled + tooltip)。
- Keys:列表(名稱、備註)、新增/編輯(名稱、私鑰貼上、passphrase、備註)、刪除。
- 所有變更立即寫入本地 vault 並標 dirty(觸發 debounced sync)。

### 6.2 設定頁

- **分頁列位置**:上方(橫向)/ 側邊(垂直)。存本地 prefs(裝置各自設定,不同步)。
- **同步**:
  - 未設定:server URL 輸入框 + 「建立同步」(在此 server 註冊本 vault)
    + 「貼上配對字串加入」。
  - 已設定:顯示 server / vault id / 上次同步結果;「匯出配對字串(複製)」(附警示)、
    「立即同步」、「停用同步」(只斷線,不動本地資料)。

### 6.3 多分頁(Tabs)

- 每個 tab 一個本地 shell session(SSH 之後接上後,tab 也可以是 SSH session)。
- Tab list 兩種模式(設定頁切換):**上方橫向**、**側邊垂直**(仿瀏覽器垂直分頁)。
- 操作:`+` 新分頁、每個 tab 的 ✕ 關閉、點擊切換;快捷鍵 Ctrl+Shift+T 新分頁、
  Ctrl+Shift+W 關閉目前分頁。標題跟隨 OSC title;程序結束顯示「已結束」。
- 內容用 IndexedStack 保活:切走的 tab session 照常跑、回來畫面還在。

## 7. 專案結構落點(對應 PLAN §7)

```
core/tterm-vault/      # 本文件 §1、§2、§3、§5 的核心實作(不含網路)
core/tterm-ffi/        # C ABI 擴充(ABI v3):vault 開啟/CRUD/配對/同步 payload
server/                # tterm-server(axum):§4
app/lib/src/vault/     # Vaults UI、Dart VaultService(FFI 包裝)
app/lib/src/sync/      # SyncClient(HTTP 傳輸在 Dart;加密永遠在 Rust)
app/lib/src/tabs/      # TabsController、tab bar(上/側)、AppShell
app/lib/src/settings/  # 設定頁 + 本地 prefs
```

分層原則:**金鑰與密文只存在 Rust**;Dart 只搬運已加密的 payload(HTTP)與
渲染明文 UI(經 FFI 取得的 snapshot)。Dart 端永遠拿不到 vault key 本體
(配對字串匯出是唯一出口,由使用者明確觸發)。

## 8. 測試策略

- `tterm-vault` 單元:persist/load roundtrip、加密竄改偵測、HLC 單調、LWW 與
  衝突副本、tombstone、配對字串編解碼、join 合流。
- `tterm-server` 整合(tower oneshot):註冊/重複註冊、auth 失敗、push/pull
  delta cursor、舊 hlc 不覆蓋。
- 端對端(Rust):兩個 VaultStore 透過真 server(隨機 port)互推互拉收斂一致。
- Flutter widget:tabs 上/側切換與開關、Hosts/Keys CRUD(真 FFI + 暫存目錄)、
  設定頁配對字串匯出/匯入 roundtrip。
```
