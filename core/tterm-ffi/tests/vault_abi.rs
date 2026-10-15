//! vault FFI 通道測試:透過 C ABI 走一遍 CRUD / 配對 / push-pull,
//! 確認 JSON 通道、buffer 擴充協定與錯誤通道行為。

use std::ffi::{c_void, CString};

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use tempfile::TempDir;
use tterm_ffi::vault_ffi::*;

/// 冪等讀取:模擬 Dart 端「不足就擴大重呼叫」,起手用很小的 buffer 逼出擴充路徑。
fn read_json(f: impl Fn(*mut u8, usize) -> usize) -> serde_json::Value {
    let mut cap = 8;
    loop {
        let mut buf = vec![0u8; cap];
        let need = f(buf.as_mut_ptr(), cap);
        if need <= cap {
            return serde_json::from_slice(&buf[..need]).expect("FFI 回傳必須是合法 JSON");
        }
        cap = need;
    }
}

/// 變更操作:一次給足(協定保證回傳有界),絕不重呼叫。
fn mutate_json(f: impl FnOnce(*mut u8, usize) -> usize) -> serde_json::Value {
    const CAP: usize = 4096;
    let mut buf = vec![0u8; CAP];
    let need = f(buf.as_mut_ptr(), CAP);
    assert!(need <= CAP, "變更操作回傳必須有界(<4KB),實際 {need}");
    serde_json::from_slice(&buf[..need]).expect("FFI 回傳必須是合法 JSON")
}

fn open(dir: &TempDir) -> *mut c_void {
    let c = CString::new(dir.path().to_str().unwrap()).unwrap();
    let h = unsafe { tterm_vault_open(c.as_ptr()) };
    assert!(!h.is_null());
    h
}

#[test]
fn crud_and_snapshot_roundtrip() {
    let dir = TempDir::new().unwrap();
    let h = open(&dir);

    let req = CString::new(
        r#"{"kind":"host","name":"web","data":{"address":"1.2.3.4","port":22}}"#,
    )
    .unwrap();
    let created = mutate_json(|out, cap| unsafe { tterm_vault_upsert(h, req.as_ptr(), out, cap) });
    let id = created["id"].as_str().expect("回傳 id").to_string();

    let snap = read_json(|out, cap| unsafe { tterm_vault_snapshot(h, out, cap) });
    assert_eq!(snap["records"].as_array().unwrap().len(), 1);
    assert_eq!(snap["records"][0]["name"], "web");
    assert_eq!(snap["records"][0]["data"]["port"], 22);

    let id_c = CString::new(id).unwrap();
    assert_eq!(unsafe { tterm_vault_delete(h, id_c.as_ptr()) }, 0);
    let snap = read_json(|out, cap| unsafe { tterm_vault_snapshot(h, out, cap) });
    assert_eq!(snap["records"].as_array().unwrap().len(), 0);

    tterm_vault_free(h);
}

#[test]
fn error_channel_reports_json_error() {
    let dir = TempDir::new().unwrap();
    let h = open(&dir);
    let bad = CString::new(r#"{"name":"缺 kind"}"#).unwrap();
    let resp = mutate_json(|out, cap| unsafe { tterm_vault_upsert(h, bad.as_ptr(), out, cap) });
    assert!(resp["error"].as_str().unwrap().contains("kind"));

    // 未設定同步時匯出 → error
    let resp = read_json(|out, cap| unsafe { tterm_vault_export_pairing(h, out, cap) });
    assert!(resp["error"].is_string());
    tterm_vault_free(h);
}

/// 使用者貼錯配對字串:錯誤要帶 code,UI 才翻得成看得懂的提示。
#[test]
fn bad_pairing_reports_error_code() {
    let dir = TempDir::new().unwrap();
    let h = open(&dir);
    let import = |s: &str| {
        let c = CString::new(s).unwrap();
        mutate_json(|out, cap| unsafe { tterm_vault_import_pairing(h, c.as_ptr(), out, cap) })
    };
    assert_eq!(import("hello")["code"], "pairing_missing_prefix");
    assert_eq!(import("TTERMSYNC1:!!!")["code"], "pairing_malformed");
    // 版本號要帶出去(UI 顯示「版本 N 不支援」)
    let v2 = URL_SAFE_NO_PAD.encode(
        r#"{"v":2,"server":"http://s","vault":"00000000-0000-0000-0000-000000000000","token":"","key":""}"#,
    );
    let resp = import(&format!("TTERMSYNC1:{v2}"));
    assert_eq!(resp["code"], "pairing_unsupported_version", "{resp}");
    assert_eq!(resp["args"]["version"], 2);
    tterm_vault_free(h);
}

#[test]
fn conflict_name_template_is_settable() {
    let dir = TempDir::new().unwrap();
    let h = open(&dir);
    let t = CString::new("{name} (copy)").unwrap();
    assert_eq!(unsafe { tterm_vault_set_conflict_name_template(h, t.as_ptr()) }, 0);
    assert_eq!(
        unsafe { tterm_vault_set_conflict_name_template(h, std::ptr::null()) },
        1,
        "null 樣板要回錯誤而不是 crash"
    );
    tterm_vault_free(h);
}

#[test]
fn pairing_and_sync_channel_via_abi() {
    let dir_a = TempDir::new().unwrap();
    let dir_b = TempDir::new().unwrap();
    let a = open(&dir_a);
    let b = open(&dir_b);

    // A 建一筆 + 啟用同步
    let req = CString::new(r#"{"kind":"ssh_key","name":"k1","data":{"privateKey":"P"}}"#).unwrap();
    mutate_json(|out, cap| unsafe { tterm_vault_upsert(a, req.as_ptr(), out, cap) });
    let server = CString::new("http://127.0.0.1:9").unwrap();
    let enable =
        mutate_json(|out, cap| unsafe { tterm_vault_sync_enable(a, server.as_ptr(), out, cap) });
    assert!(enable["vaultId"].is_string());
    assert!(enable["auth"].is_string());

    let transport = read_json(|out, cap| unsafe { tterm_vault_sync_transport(a, out, cap) });
    assert_eq!(transport["server"], "http://127.0.0.1:9");
    assert!(transport["token"].is_string());

    // 匯出 → B 匯入
    let exported = read_json(|out, cap| unsafe { tterm_vault_export_pairing(a, out, cap) });
    let pairing = exported["pairing"].as_str().unwrap();
    assert!(pairing.starts_with("TTERMSYNC1:"));
    let pairing_c = CString::new(pairing).unwrap();
    let joined =
        mutate_json(|out, cap| unsafe { tterm_vault_import_pairing(b, pairing_c.as_ptr(), out, cap) });
    assert_eq!(joined["vault_id"], enable["vaultId"]);

    // A build_push → B apply_pull(手動接管道,模擬 server 轉發)
    let push = read_json(|out, cap| unsafe { tterm_vault_build_push(a, out, cap) });
    let arr = push.as_array().unwrap();
    assert_eq!(arr.len(), 1);
    let mut with_seq = push.clone();
    with_seq[0]["seq"] = serde_json::json!(1);
    let records_c = CString::new(with_seq.to_string()).unwrap();
    let summary =
        mutate_json(|out, cap| unsafe { tterm_vault_apply_pull(b, records_c.as_ptr(), 1, out, cap) });
    assert_eq!(summary["applied"], 1);
    assert_eq!(tterm_vault_cursor(b), 1);

    let snap_b = read_json(|out, cap| unsafe { tterm_vault_snapshot(b, out, cap) });
    assert_eq!(snap_b["records"][0]["name"], "k1");

    // A ack push
    let ids = serde_json::json!([arr[0]["id"]]).to_string();
    let ids_c = CString::new(ids).unwrap();
    assert_eq!(unsafe { tterm_vault_ack_push(a, ids_c.as_ptr()) }, 0);
    let push2 = read_json(|out, cap| unsafe { tterm_vault_build_push(a, out, cap) });
    assert_eq!(push2.as_array().unwrap().len(), 0);

    tterm_vault_free(a);
    tterm_vault_free(b);
}
