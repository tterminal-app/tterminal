//! Vault 的 C ABI(低頻操作,一律走 JSON 字串通道)。
//!
//! 慣例:
//! - 回傳 JSON 的函式:寫入 `out`(最多 `cap` bytes),**回傳完整所需長度**。
//! - **冪等讀取**(snapshot / build_push / export / transport):回傳值 > cap 時
//!   Dart 端加大 buffer 重呼叫。
//! - **變更操作**(upsert / sync_enable / import_pairing / apply_pull):
//!   回傳 JSON 保證有界(id / 摘要,遠小於 4KB)——呼叫端必須一次給足
//!   (≥4KB),**絕不可因 buffer 不足重呼叫**(重呼叫 = 重複執行變更)。
//! - 失敗時寫入錯誤 JSON `{"error":"...","code"?:...}`(同一條通道,Dart 檢查
//!   error 鍵;格式見 error.rs)。
//! - vault key 永不跨越此邊界;token 只經 `tterm_vault_sync_transport`
//!   提供給 Dart 做 HTTP Authorization(E2E key 與 token 分離,見設計文件)。
//!   Keychain 模式也一樣:Rust 自己呼叫 Security.framework(keychain.rs),
//!   Dart 只決定 service / account 名稱。

use std::ffi::{c_char, c_void, CStr};

use tterm_vault::VaultStore;
use uuid::Uuid;

use crate::error::{error_json, message_json};
use crate::{set_error, set_error_from};

#[inline]
fn vault<'a>(handle: *mut c_void) -> Option<&'a mut VaultStore> {
    if handle.is_null() {
        None
    } else {
        Some(unsafe { &mut *(handle as *mut VaultStore) })
    }
}

unsafe fn cstr<'a>(ptr: *const c_char) -> Result<&'a str, String> {
    if ptr.is_null() {
        return Err("string argument is null".into());
    }
    unsafe { CStr::from_ptr(ptr) }
        .to_str()
        .map_err(|e| format!("not valid UTF-8: {e}"))
}

/// 寫 JSON(或錯誤 JSON)到 caller buffer;回傳完整所需 bytes 長度。
fn write_json(value: &serde_json::Value, out: *mut u8, cap: usize) -> usize {
    let s = value.to_string();
    let bytes = s.as_bytes();
    if !out.is_null() && cap > 0 {
        let n = bytes.len().min(cap);
        unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), out, n) };
    }
    bytes.len()
}

/// 沒有 code 的錯誤(參數錯誤之類)。
fn write_err(msg: impl std::fmt::Display, out: *mut u8, cap: usize) -> usize {
    write_json(&message_json(msg), out, cap)
}

/// VaultStore 回的錯誤;認得的型別帶 code 讓 Dart 翻譯。
fn write_anyhow_err(e: &anyhow::Error, out: *mut u8, cap: usize) -> usize {
    write_json(&error_json(e), out, cap)
}

/// 開啟(或初始化)vault。失敗回 null,錯誤經 tterm_last_error。
///
/// # Safety
/// `dir` 必須是有效的 NUL 結尾 UTF-8 路徑。
#[no_mangle]
pub unsafe extern "C" fn tterm_vault_open(dir: *const c_char) -> *mut c_void {
    let dir = match unsafe { cstr(dir) } {
        Ok(s) => s,
        Err(e) => {
            set_error(e);
            return std::ptr::null_mut();
        }
    };
    match VaultStore::open(dir) {
        Ok(v) => Box::into_raw(Box::new(v)) as *mut c_void,
        Err(e) => {
            set_error_from(&e);
            std::ptr::null_mut()
        }
    }
}

/// 開啟 vault,vault key 存在 Apple Keychain(iOS / macOS)的 generic password
/// `service` / `account`。dir 裡舊版留下的 vault.key 會搬進 Keychain(確認寫入後才刪)。
/// 其他平台或失敗回 null,錯誤經 tterm_last_error。
///
/// # Safety
/// `dir`、`service`、`account` 必須是有效的 NUL 結尾 UTF-8。
#[no_mangle]
pub unsafe extern "C" fn tterm_vault_open_keychain(
    dir: *const c_char,
    service: *const c_char,
    account: *const c_char,
) -> *mut c_void {
    let args = unsafe { (cstr(dir), cstr(service), cstr(account)) };
    let (dir, service, account) = match args {
        (Ok(d), Ok(s), Ok(a)) => (d, s, a),
        (Err(e), _, _) | (_, Err(e), _) | (_, _, Err(e)) => {
            set_error(e);
            return std::ptr::null_mut();
        }
    };
    match open_keychain(dir, service, account) {
        Ok(v) => Box::into_raw(Box::new(v)) as *mut c_void,
        Err(e) => {
            set_error(format!("{e:#}"));
            std::ptr::null_mut()
        }
    }
}

#[cfg(any(target_os = "macos", target_os = "ios"))]
fn open_keychain(dir: &str, service: &str, account: &str) -> anyhow::Result<VaultStore> {
    let key_store = crate::keychain::KeychainKeyStore::new(service, account);
    VaultStore::open_with_key_store(dir, Box::new(key_store))
}

#[cfg(not(any(target_os = "macos", target_os = "ios")))]
fn open_keychain(_dir: &str, _service: &str, _account: &str) -> anyhow::Result<VaultStore> {
    anyhow::bail!("no Keychain on this platform; use tterm_vault_open")
}

#[no_mangle]
pub extern "C" fn tterm_vault_free(handle: *mut c_void) {
    if !handle.is_null() {
        drop(unsafe { Box::from_raw(handle as *mut VaultStore) });
    }
}

/// UI snapshot(明文 records;不含 key/token)。
///
/// # Safety
/// `out` 必須可寫入至少 `cap` bytes。
#[no_mangle]
pub unsafe extern "C" fn tterm_vault_snapshot(
    handle: *mut c_void,
    out: *mut u8,
    cap: usize,
) -> usize {
    let Some(v) = vault(handle) else {
        return write_err("handle is null", out, cap);
    };
    write_json(&v.snapshot_json(), out, cap)
}

/// 新增/修改 record。輸入 `{"id"?, "kind", "name", "data"}`,回傳 `{"id": ...}`。
///
/// # Safety
/// `json` 必須是有效的 NUL 結尾 UTF-8;`out` 可寫入至少 `cap` bytes。
#[no_mangle]
pub unsafe extern "C" fn tterm_vault_upsert(
    handle: *mut c_void,
    json: *const c_char,
    out: *mut u8,
    cap: usize,
) -> usize {
    let Some(v) = vault(handle) else {
        return write_err("handle is null", out, cap);
    };
    let raw = match unsafe { cstr(json) } {
        Ok(s) => s,
        Err(e) => return write_err(e, out, cap),
    };
    let parsed: serde_json::Value = match serde_json::from_str(raw) {
        Ok(p) => p,
        Err(e) => return write_err(format!("invalid JSON: {e}"), out, cap),
    };
    let id = match parsed.get("id").and_then(|x| x.as_str()) {
        Some(s) => match Uuid::parse_str(s) {
            Ok(u) => Some(u),
            Err(_) => return write_err("id is not a valid UUID", out, cap),
        },
        None => None,
    };
    let (Some(kind), Some(name)) = (
        parsed.get("kind").and_then(|x| x.as_str()),
        parsed.get("name").and_then(|x| x.as_str()),
    ) else {
        return write_err("missing kind or name", out, cap);
    };
    let data = parsed.get("data").cloned().unwrap_or(serde_json::json!({}));
    match v.upsert(id, kind, name, data) {
        Ok(r) => write_json(&serde_json::json!({"id": r.id}), out, cap),
        Err(e) => write_anyhow_err(&e, out, cap),
    }
}

/// 刪除 record(tombstone)。回傳 0 成功(含本來就不存在)、1 失敗。
///
/// # Safety
/// `id` 必須是有效的 NUL 結尾 UTF-8。
#[no_mangle]
pub unsafe extern "C" fn tterm_vault_delete(handle: *mut c_void, id: *const c_char) -> u32 {
    let Some(v) = vault(handle) else { return 1 };
    let id = match unsafe { cstr(id) }.and_then(|s| {
        Uuid::parse_str(s).map_err(|_| "id is not a valid UUID".to_string())
    }) {
        Ok(u) => u,
        Err(e) => {
            set_error(e);
            return 1;
        }
    };
    match v.delete(id) {
        Ok(_) => 0,
        Err(e) => {
            set_error_from(&e);
            1
        }
    }
}

/// 啟用同步:產生 token,回傳 `{"vaultId","auth"}`(上層拿去 POST /v1/vaults)。
///
/// # Safety
/// `server` 必須是有效的 NUL 結尾 UTF-8;`out` 可寫入至少 `cap` bytes。
#[no_mangle]
pub unsafe extern "C" fn tterm_vault_sync_enable(
    handle: *mut c_void,
    server: *const c_char,
    out: *mut u8,
    cap: usize,
) -> usize {
    let Some(v) = vault(handle) else {
        return write_err("handle is null", out, cap);
    };
    let server = match unsafe { cstr(server) } {
        Ok(s) => s,
        Err(e) => return write_err(e, out, cap),
    };
    match v.sync_enable(server) {
        Ok((vault_id, auth)) => {
            write_json(&serde_json::json!({"vaultId": vault_id, "auth": auth}), out, cap)
        }
        Err(e) => write_anyhow_err(&e, out, cap),
    }
}

#[no_mangle]
pub extern "C" fn tterm_vault_sync_disable(handle: *mut c_void) -> u32 {
    let Some(v) = vault(handle) else { return 1 };
    match v.sync_disable() {
        Ok(()) => 0,
        Err(e) => {
            set_error_from(&e);
            1
        }
    }
}

/// HTTP 傳輸所需資訊:`{"server","token","vaultId"}`(token 是 bearer;
/// E2E key 永不經過這裡)。未設定同步 → `{"error":...}`。
///
/// # Safety
/// `out` 必須可寫入至少 `cap` bytes。
#[no_mangle]
pub unsafe extern "C" fn tterm_vault_sync_transport(
    handle: *mut c_void,
    out: *mut u8,
    cap: usize,
) -> usize {
    let Some(v) = vault(handle) else {
        return write_err("handle is null", out, cap);
    };
    match v.sync_config() {
        Some(c) => write_json(
            &serde_json::json!({
                "server": c.server,
                "token": c.token,
                "vaultId": v.vault_id(),
            }),
            out,
            cap,
        ),
        None => write_err("sync is not set up", out, cap),
    }
}

/// 匯出配對字串:`{"pairing":"TTERMSYNC1:..."}`。
///
/// # Safety
/// `out` 必須可寫入至少 `cap` bytes。
#[no_mangle]
pub unsafe extern "C" fn tterm_vault_export_pairing(
    handle: *mut c_void,
    out: *mut u8,
    cap: usize,
) -> usize {
    let Some(v) = vault(handle) else {
        return write_err("handle is null", out, cap);
    };
    match v.export_pairing() {
        Ok(s) => write_json(&serde_json::json!({"pairing": s}), out, cap),
        Err(e) => write_anyhow_err(&e, out, cap),
    }
}

/// 貼上配對字串加入 vault。回傳 JoinSummary JSON。
///
/// # Safety
/// `pairing` 必須是有效的 NUL 結尾 UTF-8;`out` 可寫入至少 `cap` bytes。
#[no_mangle]
pub unsafe extern "C" fn tterm_vault_import_pairing(
    handle: *mut c_void,
    pairing: *const c_char,
    out: *mut u8,
    cap: usize,
) -> usize {
    let Some(v) = vault(handle) else {
        return write_err("handle is null", out, cap);
    };
    let s = match unsafe { cstr(pairing) } {
        Ok(s) => s,
        Err(e) => return write_err(e, out, cap),
    };
    match v.import_pairing(s) {
        Ok(summary) => write_json(
            &serde_json::to_value(&summary).unwrap_or(serde_json::json!({})),
            out,
            cap,
        ),
        Err(e) => write_anyhow_err(&e, out, cap),
    }
}

/// 收集 dirty records 的加密 push payload(wire JSON 陣列)。
///
/// # Safety
/// `out` 必須可寫入至少 `cap` bytes。
#[no_mangle]
pub unsafe extern "C" fn tterm_vault_build_push(
    handle: *mut c_void,
    out: *mut u8,
    cap: usize,
) -> usize {
    let Some(v) = vault(handle) else {
        return write_err("handle is null", out, cap);
    };
    match v.build_push() {
        Ok(wire) => write_json(
            &serde_json::to_value(&wire).unwrap_or(serde_json::json!([])),
            out,
            cap,
        ),
        Err(e) => write_anyhow_err(&e, out, cap),
    }
}

/// push 成功後清 dirty。輸入 `["<uuid>", ...]`。回傳 0 成功。
///
/// # Safety
/// `ids_json` 必須是有效的 NUL 結尾 UTF-8。
#[no_mangle]
pub unsafe extern "C" fn tterm_vault_ack_push(
    handle: *mut c_void,
    ids_json: *const c_char,
) -> u32 {
    let Some(v) = vault(handle) else { return 1 };
    let raw = match unsafe { cstr(ids_json) } {
        Ok(s) => s,
        Err(e) => {
            set_error(e);
            return 1;
        }
    };
    let ids: Vec<Uuid> = match serde_json::from_str(raw) {
        Ok(ids) => ids,
        Err(e) => {
            set_error(format!("invalid ids JSON: {e}"));
            return 1;
        }
    };
    match v.ack_push(&ids) {
        Ok(()) => 0,
        Err(e) => {
            set_error_from(&e);
            1
        }
    }
}

/// 套用 pull 下來的 wire records。回傳 ApplySummary JSON。
///
/// # Safety
/// `records_json` 必須是有效的 NUL 結尾 UTF-8;`out` 可寫入至少 `cap` bytes。
#[no_mangle]
pub unsafe extern "C" fn tterm_vault_apply_pull(
    handle: *mut c_void,
    records_json: *const c_char,
    next_cursor: u64,
    out: *mut u8,
    cap: usize,
) -> usize {
    let Some(v) = vault(handle) else {
        return write_err("handle is null", out, cap);
    };
    let raw = match unsafe { cstr(records_json) } {
        Ok(s) => s,
        Err(e) => return write_err(e, out, cap),
    };
    let records: Vec<tterm_vault::WireRecord> = match serde_json::from_str(raw) {
        Ok(r) => r,
        Err(e) => return write_err(format!("invalid records JSON: {e}"), out, cap),
    };
    match v.apply_pull(&records, next_cursor) {
        Ok(summary) => write_json(
            &serde_json::to_value(&summary).unwrap_or(serde_json::json!({})),
            out,
            cap,
        ),
        Err(e) => write_anyhow_err(&e, out, cap),
    }
}

/// 目前的 pull cursor(server seq)。
#[no_mangle]
pub extern "C" fn tterm_vault_cursor(handle: *mut c_void) -> u64 {
    vault(handle).map_or(0, |v| v.cursor())
}

/// 同步衝突時本地版本另存副本的名稱樣板(`{name}` / `{device}` / `{time}`)。
/// UI 依自己的語系設定;沒設過就是英文預設。回傳 0 成功。
///
/// # Safety
/// `template` 必須是有效的 NUL 結尾 UTF-8。
#[no_mangle]
pub unsafe extern "C" fn tterm_vault_set_conflict_name_template(
    handle: *mut c_void,
    template: *const c_char,
) -> u32 {
    let Some(v) = vault(handle) else { return 1 };
    match unsafe { cstr(template) } {
        Ok(t) => {
            v.set_conflict_name_template(t);
            0
        }
        Err(e) => {
            set_error(e);
            1
        }
    }
}
