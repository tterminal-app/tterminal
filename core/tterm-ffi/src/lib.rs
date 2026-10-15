//! tterm-ffi:C ABI 熱路徑,給 dart:ffi 直接呼叫。
//!
//! 設計:
//! - Grid 以扁平 buffer(每 cell 4 個 u32:codepoint / fg / bg / flags)整份拷貝,
//!   120x40 grid ≈ 76 KiB,實測 <0.2ms,遠低於 frame 預算。
//! - handle = `Box<Session>` 的 raw pointer,`tterm_session_free` 負責回收。
//! - Session 內部自帶 Mutex,Rust 端的 PTY reader thread 與 Dart 端可並行;
//!   但同一個 handle 不可被多個 Dart isolate 同時呼叫。
//! - 所有函式對 null handle 都安全返回,避免 Dart 端誤用直接 crash。

use std::ffi::c_void;

use tterm_session::Session;
use tterm_term::Damage;

mod error;
#[cfg(any(target_os = "macos", target_os = "ios"))]
mod keychain;
pub mod vault_ffi;

use error::{error_json, message_json};

// 建立失敗時 Dart 端會拿到 null,再用 `tterm_last_error` 取錯誤 JSON(見 error.rs)。
thread_local! {
    static LAST_ERROR: std::cell::RefCell<String> = const { std::cell::RefCell::new(String::new()) };
}

/// 記下沒有 code 的錯誤(程式錯誤、參數錯誤)。
pub(crate) fn set_error(msg: impl std::fmt::Display) {
    let json = message_json(msg).to_string();
    LAST_ERROR.with(|e| *e.borrow_mut() = json);
}

/// 記下 anyhow 錯誤;認得的型別會帶 code 讓 Dart 翻譯。
pub(crate) fn set_error_from(err: &anyhow::Error) {
    let json = error_json(err).to_string();
    LAST_ERROR.with(|e| *e.borrow_mut() = json);
}

#[inline]
fn session<'a>(handle: *mut c_void) -> Option<&'a mut Session> {
    if handle.is_null() {
        None
    } else {
        Some(unsafe { &mut *(handle as *mut Session) })
    }
}

/// 無資料來源的 session(合成資料 / 效能驗證用)。
#[no_mangle]
pub extern "C" fn tterm_session_new_headless(
    cols: u32,
    rows: u32,
    scrollback: u32,
) -> *mut c_void {
    let s = Session::new_headless(cols as u16, rows as u16, scrollback);
    Box::into_raw(Box::new(s)) as *mut c_void
}

/// 開本地 shell。`program` 為 null 時使用平台預設 shell
/// (Unix:`$SHELL`;Windows:PowerShell)。
///
/// # Safety
/// `program` 若非 null 必須是有效的 NUL 結尾 UTF-8 字串。
#[no_mangle]
pub unsafe extern "C" fn tterm_session_spawn_shell(
    cols: u32,
    rows: u32,
    scrollback: u32,
    program: *const std::os::raw::c_char,
) -> *mut c_void {
    let prog = if program.is_null() {
        None
    } else {
        match unsafe { std::ffi::CStr::from_ptr(program) }.to_str() {
            Ok(s) => Some(s),
            Err(e) => {
                set_error(format!("program is not valid UTF-8: {e}"));
                return std::ptr::null_mut();
            }
        }
    };
    match Session::spawn_shell(cols as u16, rows as u16, scrollback, prog) {
        Ok(s) => Box::into_raw(Box::new(s)) as *mut c_void,
        Err(e) => {
            set_error_from(&e);
            std::ptr::null_mut()
        }
    }
}

/// 連上 SSH server 並開 shell。config 為 JSON:
/// `{host, port, username, cols, rows, scrollback,
///   auth:{method:"password",password} | {method:"key",pem,passphrase?},
///   knownFingerprint?}`。失敗回 null,錯誤經 `tterm_last_error`。
///
/// # Safety
/// `config` 必須是有效的 NUL 結尾 UTF-8 字串。
#[no_mangle]
pub unsafe extern "C" fn tterm_session_connect_ssh(
    config: *const std::os::raw::c_char,
) -> *mut c_void {
    if config.is_null() {
        set_error("config is null");
        return std::ptr::null_mut();
    }
    let raw = match unsafe { std::ffi::CStr::from_ptr(config) }.to_str() {
        Ok(s) => s,
        Err(e) => {
            set_error(format!("config is not valid UTF-8: {e}"));
            return std::ptr::null_mut();
        }
    };
    match connect_ssh_from_json(raw) {
        Ok(session) => Box::into_raw(Box::new(session)) as *mut c_void,
        Err(e) => {
            set_error_from(&e);
            std::ptr::null_mut()
        }
    }
}

fn connect_ssh_from_json(raw: &str) -> anyhow::Result<Session> {
    use anyhow::{anyhow, Context};
    let cfg: serde_json::Value =
        serde_json::from_str(raw).context("invalid SSH config JSON")?;
    let host = cfg["host"].as_str().ok_or_else(|| anyhow!("missing host"))?;
    let username = cfg["username"]
        .as_str()
        .ok_or_else(|| anyhow!("missing username"))?;
    let port = cfg["port"].as_u64().unwrap_or(22) as u16;
    let cols = cfg["cols"].as_u64().unwrap_or(100) as u16;
    let rows = cfg["rows"].as_u64().unwrap_or(30) as u16;
    let scrollback = cfg["scrollback"].as_u64().unwrap_or(10000) as u32;
    let expected_fingerprint = cfg["knownFingerprint"].as_str().map(|s| s.to_string());

    let auth_obj = &cfg["auth"];
    let auth = match auth_obj["method"].as_str() {
        Some("password") => tterm_session::SshAuth::Password(
            auth_obj["password"].as_str().unwrap_or("").to_string(),
        ),
        Some("key") => {
            let pem = auth_obj["pem"]
                .as_str()
                .ok_or_else(|| anyhow!("key auth is missing pem"))?
                .to_string();
            let passphrase = auth_obj["passphrase"]
                .as_str()
                .filter(|s| !s.is_empty())
                .map(|s| s.to_string());
            tterm_session::SshAuth::KeyData { pem, passphrase }
        }
        other => return Err(anyhow!("unsupported auth method: {other:?}")),
    };

    let target = tterm_session::SshConnectTarget {
        host: host.to_string(),
        port,
        username: username.to_string(),
        auth,
        expected_fingerprint,
    };
    Session::connect_ssh(target, cols, rows, scrollback)
}

/// SSH host key 指紋(`SHA256:...`,UTF-8 寫入 `out`),回傳 bytes 數;
/// 本地 shell session 回 0。
///
/// # Safety
/// `out` 必須可寫入至少 `cap` bytes。
#[no_mangle]
pub unsafe extern "C" fn tterm_session_ssh_fingerprint(
    handle: *mut c_void,
    out: *mut u8,
    cap: usize,
) -> usize {
    let Some(s) = session(handle) else { return 0 };
    match s.ssh_fingerprint() {
        Some(fp) => write_str(fp, out, cap),
        None => 0,
    }
}

/// 這是不是 SSH session(檔案側窗決定走遠端 SFTP 還是本地)。
#[no_mangle]
pub extern "C" fn tterm_session_is_ssh(handle: *mut c_void) -> u32 {
    session(handle).map_or(0, |s| s.is_ssh() as u32)
}

/// 從私鑰算出公鑰(純計算、不連線;金鑰列表用來顯示與複製 authorized_keys
/// 那一行)。`passphrase` 可為 null —— OpenSSH 私鑰的公鑰段是明文,
/// 有 passphrase 也算得出來。
///
/// 回 JSON:`{"publicKey","algorithm","fingerprint","comment"}`,
/// 失敗為錯誤 JSON(見 error.rs);回傳「完整所需 bytes」,> `cap` 時加大 buffer
/// 重呼叫(冪等)。
///
/// # Safety
/// `pem` 必須是有效的 NUL 結尾 UTF-8 字串,`passphrase` 若非 null 亦同;
/// `out` 必須可寫入至少 `cap` bytes。
#[no_mangle]
pub unsafe extern "C" fn tterm_ssh_public_key(
    pem: *const std::os::raw::c_char,
    passphrase: *const std::os::raw::c_char,
    out: *mut u8,
    cap: usize,
) -> usize {
    let json = match unsafe { ssh_public_key_json(pem, passphrase) } {
        Ok(v) => v,
        Err(e) => error_json(&e),
    };
    write_bytes_full(json.to_string().as_bytes(), out, cap)
}

unsafe fn ssh_public_key_json(
    pem: *const std::os::raw::c_char,
    passphrase: *const std::os::raw::c_char,
) -> anyhow::Result<serde_json::Value> {
    use anyhow::anyhow;
    if pem.is_null() {
        return Err(anyhow!("private key is null"));
    }
    let pem = unsafe { std::ffi::CStr::from_ptr(pem) }
        .to_str()
        .map_err(|e| anyhow!("private key is not valid UTF-8: {e}"))?;
    let pass = if passphrase.is_null() {
        None
    } else {
        unsafe { std::ffi::CStr::from_ptr(passphrase) }
            .to_str()
            .ok()
            .filter(|s| !s.is_empty())
    };
    let info = tterm_ssh::public_key_of_private_key(pem, pass)?;
    Ok(serde_json::json!({
        "publicKey": info.openssh,
        "algorithm": info.algorithm,
        "fingerprint": info.fingerprint,
        "comment": info.comment,
    }))
}

/// [`tterm_ssh_generate_key`] 回傳 JSON 的上限;呼叫端一次給這麼大的 buffer。
/// RSA 4096 加密私鑰 + 公鑰行也才約 5KB。
pub const SSH_GENERATE_KEY_MAX: usize = 16 * 1024;

/// 產生新的 SSH 金鑰對(Vaults → Keys「產生金鑰」;手機上沒有 ssh-keygen)。
///
/// `kind`:`"ed25519"` / `"rsa"`(RSA 4096)。`comment` 可為 null(= 空字串);
/// `passphrase` 為 null 或空字串 = 私鑰不加密。
///
/// 回 JSON:`{"privateKey","publicKey","algorithm","fingerprint","comment"}`,
/// 失敗為錯誤 JSON(見 error.rs)。
///
/// **不是冪等**:每次呼叫都是一把新金鑰,所以**不能**「buffer 不夠就加大重呼叫」
/// (重呼叫拿到的是另一把)。回傳 JSON 保證不超過 [`SSH_GENERATE_KEY_MAX`],
/// 呼叫端一次給足;回傳值 > `cap` 表示呼叫端違約,這次結果作廢。
///
/// # Safety
/// `kind` 必須是有效的 NUL 結尾 UTF-8 字串,`comment` / `passphrase` 若非 null
/// 亦同;`out` 必須可寫入至少 `cap` bytes。
#[no_mangle]
pub unsafe extern "C" fn tterm_ssh_generate_key(
    kind: *const std::os::raw::c_char,
    comment: *const std::os::raw::c_char,
    passphrase: *const std::os::raw::c_char,
    out: *mut u8,
    cap: usize,
) -> usize {
    let json = match unsafe { ssh_generate_key_json(kind, comment, passphrase) } {
        Ok(v) => v,
        Err(e) => error_json(&e),
    };
    write_bytes_full(json.to_string().as_bytes(), out, cap)
}

unsafe fn ssh_generate_key_json(
    kind: *const std::os::raw::c_char,
    comment: *const std::os::raw::c_char,
    passphrase: *const std::os::raw::c_char,
) -> anyhow::Result<serde_json::Value> {
    use anyhow::anyhow;
    let opt_str = |p: *const std::os::raw::c_char| -> anyhow::Result<&str> {
        if p.is_null() {
            return Ok("");
        }
        unsafe { std::ffi::CStr::from_ptr(p) }
            .to_str()
            .map_err(|e| anyhow!("argument is not valid UTF-8: {e}"))
    };
    let kind_name = opt_str(kind)?;
    let kind = tterm_ssh::KeyKind::from_name(kind_name)
        .ok_or_else(|| anyhow!("unsupported key type: {kind_name:?}"))?;
    let pass = opt_str(passphrase)?;
    let key = tterm_ssh::generate_key(kind, opt_str(comment)?, Some(pass))?;
    Ok(serde_json::json!({
        "privateKey": key.private_key,
        "publicKey": key.public.openssh,
        "algorithm": key.public.algorithm,
        "fingerprint": key.public.fingerprint,
        "comment": key.public.comment,
    }))
}

/// OSC 52 剪貼簿內容(tmux/vim 反白複製時經 escape sequence 回報)。
/// 回傳 bytes 數並**取走**;0 = 沒有新內容;> `cap` = buffer 不夠
/// (內容未取走,擴大重呼叫)。
///
/// # Safety
/// `out` 必須可寫入至少 `cap` bytes。
#[no_mangle]
pub unsafe extern "C" fn tterm_session_take_clipboard(
    handle: *mut c_void,
    out: *mut u8,
    cap: usize,
) -> usize {
    let Some(s) = session(handle) else { return 0 };
    match s.take_clipboard(cap) {
        Ok(None) => 0,
        Ok(Some(t)) => {
            unsafe { std::ptr::copy_nonoverlapping(t.as_ptr(), out, t.len()) };
            t.len()
        }
        Err(need) => need,
    }
}

/// SFTP 相關的回傳約定:回傳「完整所需 bytes 長度」(> cap 時 Dart 加大 buffer
/// 重呼叫,皆為讀取、可重試);`usize::MAX` = 失敗(訊息在 tterm_last_error)。
const SFTP_ERR: usize = usize::MAX;

fn write_bytes_full(bytes: &[u8], out: *mut u8, cap: usize) -> usize {
    if !out.is_null() && cap > 0 {
        let n = bytes.len().min(cap);
        unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), out, n) };
    }
    bytes.len()
}

/// 遠端 home 目錄。
///
/// # Safety
/// `out` 必須可寫入至少 `cap` bytes。
#[no_mangle]
pub unsafe extern "C" fn tterm_session_sftp_home(
    handle: *mut c_void,
    out: *mut u8,
    cap: usize,
) -> usize {
    let Some(s) = session(handle) else { return SFTP_ERR };
    match s.sftp_home() {
        Ok(p) => write_bytes_full(p.as_bytes(), out, cap),
        Err(e) => {
            set_error_from(&e);
            SFTP_ERR
        }
    }
}

/// 遠端目錄列表 → JSON `[{"name","isDir","size"}...]`。
///
/// # Safety
/// `path` 為有效 NUL 結尾 UTF-8;`out` 可寫入至少 `cap` bytes。
#[no_mangle]
pub unsafe extern "C" fn tterm_session_sftp_list(
    handle: *mut c_void,
    path: *const std::os::raw::c_char,
    out: *mut u8,
    cap: usize,
) -> usize {
    let Some(s) = session(handle) else { return SFTP_ERR };
    let path = match cstr_arg(path) {
        Ok(p) => p,
        Err(e) => {
            set_error(e);
            return SFTP_ERR;
        }
    };
    match s.sftp_list(&path) {
        Ok(entries) => {
            let arr: Vec<_> = entries
                .into_iter()
                .map(|e| {
                    serde_json::json!({"name": e.name, "isDir": e.is_dir, "size": e.size})
                })
                .collect();
            let json = serde_json::Value::Array(arr).to_string();
            write_bytes_full(json.as_bytes(), out, cap)
        }
        Err(e) => {
            set_error_from(&e);
            SFTP_ERR
        }
    }
}

/// 讀遠端檔案(raw bytes)。
///
/// # Safety
/// `path` 為有效 NUL 結尾 UTF-8;`out` 可寫入至少 `cap` bytes。
#[no_mangle]
pub unsafe extern "C" fn tterm_session_sftp_read(
    handle: *mut c_void,
    path: *const std::os::raw::c_char,
    out: *mut u8,
    cap: usize,
) -> usize {
    let Some(s) = session(handle) else { return SFTP_ERR };
    let path = match cstr_arg(path) {
        Ok(p) => p,
        Err(e) => {
            set_error(e);
            return SFTP_ERR;
        }
    };
    match s.sftp_read(&path) {
        Ok(bytes) => write_bytes_full(&bytes, out, cap),
        Err(e) => {
            set_error_from(&e);
            SFTP_ERR
        }
    }
}

/// 寫遠端檔案(覆寫)。回傳 0 成功、1 失敗。
///
/// # Safety
/// `path` 為有效 NUL 結尾 UTF-8;`data` 指向至少 `len` bytes。
#[no_mangle]
pub unsafe extern "C" fn tterm_session_sftp_write(
    handle: *mut c_void,
    path: *const std::os::raw::c_char,
    data: *const u8,
    len: usize,
) -> u32 {
    let Some(s) = session(handle) else { return 1 };
    let path = match cstr_arg(path) {
        Ok(p) => p,
        Err(e) => {
            set_error(e);
            return 1;
        }
    };
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    match s.sftp_write(&path, bytes) {
        Ok(()) => 0,
        Err(e) => {
            set_error_from(&e);
            1
        }
    }
}

/// 在遠端執行命令(獨立 exec channel),`stdin_data` 送入後關閉輸入端,
/// stdout 寫入 `out`。回傳寫入的 bytes 數(輸出超過 `cap` 時截斷——exec
/// 不可重跑,不用「擴大重呼叫」協定);`usize::MAX` = 失敗(訊息在
/// tterm_last_error)。
///
/// # Safety
/// `cmd` 為有效 NUL 結尾 UTF-8;`stdin_data` 指向至少 `stdin_len` bytes
/// (len 為 0 時可為 null);`out` 可寫入至少 `cap` bytes。
#[no_mangle]
pub unsafe extern "C" fn tterm_session_ssh_exec(
    handle: *mut c_void,
    cmd: *const std::os::raw::c_char,
    stdin_data: *const u8,
    stdin_len: usize,
    timeout_ms: u32,
    out: *mut u8,
    cap: usize,
) -> usize {
    let Some(s) = session(handle) else { return SFTP_ERR };
    let cmd = match cstr_arg(cmd) {
        Ok(c) => c,
        Err(e) => {
            set_error(e);
            return SFTP_ERR;
        }
    };
    let stdin = if stdin_data.is_null() || stdin_len == 0 {
        &[][..]
    } else {
        unsafe { std::slice::from_raw_parts(stdin_data, stdin_len) }
    };
    match s.ssh_exec(&cmd, stdin, std::time::Duration::from_millis(timeout_ms as u64)) {
        Ok(bytes) => {
            let n = bytes.len().min(cap);
            if !out.is_null() && n > 0 {
                unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), out, n) };
            }
            n
        }
        Err(e) => {
            set_error_from(&e);
            SFTP_ERR
        }
    }
}

unsafe fn cstr_arg(ptr: *const std::os::raw::c_char) -> Result<String, String> {
    if ptr.is_null() {
        return Err("path is null".into());
    }
    unsafe { std::ffi::CStr::from_ptr(ptr) }
        .to_str()
        .map(|s| s.to_string())
        .map_err(|e| format!("path is not valid UTF-8: {e}"))
}

/// 取最近一次錯誤(錯誤 JSON,格式見 error.rs;UTF-8 寫入 `out`),回傳寫入的
/// bytes 數。
///
/// # Safety
/// `out` 必須可寫入至少 `cap` bytes。
#[no_mangle]
pub unsafe extern "C" fn tterm_last_error(out: *mut u8, cap: usize) -> usize {
    LAST_ERROR.with(|e| write_str(&e.borrow(), out, cap))
}

#[no_mangle]
pub extern "C" fn tterm_session_free(handle: *mut c_void) {
    if !handle.is_null() {
        drop(unsafe { Box::from_raw(handle as *mut Session) });
    }
}

/// 使用者輸入 → PTY。回傳 0 成功、非 0 失敗。
///
/// # Safety
/// `ptr` 必須指向至少 `len` bytes 的有效記憶體。
#[no_mangle]
pub unsafe extern "C" fn tterm_session_write(
    handle: *mut c_void,
    ptr: *const u8,
    len: usize,
) -> u32 {
    let Some(s) = session(handle) else { return 1 };
    let bytes = unsafe { std::slice::from_raw_parts(ptr, len) };
    match s.write(bytes) {
        Ok(()) => 0,
        Err(e) => {
            set_error_from(&e);
            1
        }
    }
}

#[no_mangle]
pub extern "C" fn tterm_session_resize(handle: *mut c_void, cols: u32, rows: u32) -> u32 {
    let Some(s) = session(handle) else { return 1 };
    match s.resize(cols as u16, rows as u16) {
        Ok(()) => 0,
        Err(e) => {
            set_error_from(&e);
            1
        }
    }
}

/// 取出並清空 damage。回傳:0 = 無、1 = 部分、2 = 整面。
#[no_mangle]
pub extern "C" fn tterm_session_take_damage(handle: *mut c_void) -> u32 {
    let Some(s) = session(handle) else { return 0 };
    match s.take_damage() {
        Damage::Full => 2,
        Damage::Lines(lines) if !lines.is_empty() => 1,
        Damage::Lines(_) => 0,
    }
}

/// 將 viewport 拷貝進 `out`(每 cell 4 個 u32);回傳寫入的 cell 數。
///
/// # Safety
/// `out` 必須可寫入至少 `cap_cells * 4` 個 u32。
#[no_mangle]
pub unsafe extern "C" fn tterm_session_copy_grid(
    handle: *mut c_void,
    out: *mut u32,
    cap_cells: usize,
) -> usize {
    let Some(s) = session(handle) else { return 0 };
    let buf = unsafe { std::slice::from_raw_parts_mut(out, cap_cells * 4) };
    s.fill_grid_u32(buf)
}

/// 游標狀態寫入 `out[3]`:row、col、visible(0/1)。
///
/// # Safety
/// `out` 必須可寫入至少 3 個 u32。
#[no_mangle]
pub unsafe extern "C" fn tterm_session_cursor(handle: *mut c_void, out: *mut u32) {
    let Some(s) = session(handle) else { return };
    let (row, col, visible) = s.cursor();
    let out_slice = unsafe { std::slice::from_raw_parts_mut(out, 3) };
    out_slice[0] = row as u32;
    out_slice[1] = col as u32;
    out_slice[2] = visible as u32;
}

/// 終端模式 bits(見 tterm_term::modes):輸入編碼器用來決定方向鍵格式等。
#[no_mangle]
pub extern "C" fn tterm_session_modes(handle: *mut c_void) -> u32 {
    session(handle).map_or(0, |s| s.mode_bits())
}

/// 把終端拉回一般狀態(離開 alt screen、關滑鼠回報、顯示游標)。
/// UI 的「重設終端」用:TUI 被中斷後模式卡住,滾輪會完全失效。
#[no_mangle]
pub extern "C" fn tterm_session_reset_modes(handle: *mut c_void) {
    if let Some(s) = session(handle) {
        s.reset_input_modes();
    }
}

/// 自動復原卡住的終端模式(見 `Session::recover_stuck_modes`);1 = 有復原。
#[no_mangle]
pub extern "C" fn tterm_session_recover_stuck_modes(handle: *mut c_void) -> u32 {
    session(handle).map_or(0, |s| s.recover_stuck_modes() as u32)
}

#[no_mangle]
pub extern "C" fn tterm_session_scroll(handle: *mut c_void, delta: i32) {
    if let Some(s) = session(handle) {
        s.scroll_display(delta);
    }
}

/// 1 = 資料來源仍活著。
#[no_mangle]
pub extern "C" fn tterm_session_is_alive(handle: *mut c_void) -> u32 {
    session(handle).map_or(0, |s| s.is_alive() as u32)
}

/// 視窗標題(UTF-8 寫入 `out`),回傳寫入的 bytes 數。
///
/// # Safety
/// `out` 必須可寫入至少 `cap` bytes。
#[no_mangle]
pub unsafe extern "C" fn tterm_session_title(
    handle: *mut c_void,
    out: *mut u8,
    cap: usize,
) -> usize {
    let Some(s) = session(handle) else { return 0 };
    write_str(&s.title(), out, cap)
}

#[no_mangle]
pub extern "C" fn tterm_session_bell_count(handle: *mut c_void) -> u32 {
    session(handle).map_or(0, |s| s.bell_count())
}

/// OSC 7 工作目錄(UTF-8 寫入 `out`),回傳 bytes 數;無則回 0。
///
/// # Safety
/// `out` 必須可寫入至少 `cap` bytes。
#[no_mangle]
pub unsafe extern "C" fn tterm_session_current_dir(
    handle: *mut c_void,
    out: *mut u8,
    cap: usize,
) -> usize {
    let Some(s) = session(handle) else { return 0 };
    match s.current_directory() {
        Some(dir) => write_str(&dir, out, cap),
        None => 0,
    }
}

/// 本地 shell 目前工作目錄(直接讀子行程,不靠 OSC 7),UTF-8 寫入 `out`,
/// 回傳 bytes 數;抓不到 / SSH session 回 0。Windows cmd.exe / PowerShell 不送
/// OSC 7 時的「跳至終端目前目錄」靠這個。
///
/// # Safety
/// `out` 必須可寫入至少 `cap` bytes。
#[no_mangle]
pub unsafe extern "C" fn tterm_session_local_cwd(
    handle: *mut c_void,
    out: *mut u8,
    cap: usize,
) -> usize {
    let Some(s) = session(handle) else { return 0 };
    match s.local_cwd() {
        Some(dir) => write_str(&dir, out, cap),
        None => 0,
    }
}

/// 餵入合成資料流(效能驗證用,不經過資料來源)。回傳餵入的 bytes 數。
#[no_mangle]
pub extern "C" fn tterm_session_demo_feed(
    handle: *mut c_void,
    scenario: u32,
    nbytes: usize,
) -> usize {
    session(handle).map_or(0, |s| s.demo_feed(scenario, nbytes))
}

/// FFI ABI 版本;Dart 端啟動時檢查,不符表示 .so 與 Dart 綁定不同步。
/// v3:vault(tterm_vault_*)。v4:SSH。v5:OSC7 current_dir。v6:SFTP。
/// v7:ssh_exec(遠端 cwd 偵測)。v8:ssh_exec 加 stdin(腳本走 sh -s)。
/// v9:take_clipboard(OSC 52 → 系統剪貼簿)。
/// v10:local_cwd(本地 shell cwd,不靠 OSC 7)。
/// v11:reset_modes / recover_stuck_modes(TUI 被中斷後滾輪失效的復原)。
/// v12:tterm_ssh_public_key(金鑰列表從私鑰算出公鑰,不連線)。
/// v13:錯誤一律走 JSON(英文訊息 + 給 UI 翻譯的 code,見 error.rs);
///      tterm_vault_set_conflict_name_template(衝突副本名稱跟著 UI 語系)。
/// v14:tterm_vault_open_keychain(vault key 改存 Apple Keychain)。
/// v15:tterm_ssh_generate_key(在 app 內產生金鑰對)。
#[no_mangle]
pub extern "C" fn tterm_ffi_version() -> u32 {
    15
}

/// 寫 UTF-8 字串到 caller buffer,必要時在字元邊界截斷(不產生半個字)。
fn write_str(s: &str, out: *mut u8, cap: usize) -> usize {
    if out.is_null() || cap == 0 {
        return 0;
    }
    let mut end = s.len().min(cap);
    while end > 0 && !s.is_char_boundary(end) {
        end -= 1;
    }
    let bytes = &s.as_bytes()[..end];
    unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), out, bytes.len()) };
    bytes.len()
}
