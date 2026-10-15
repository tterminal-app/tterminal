//! 錯誤怎麼交給 Dart。
//!
//! 所有錯誤通道(`tterm_last_error`、vault / 公鑰的 JSON 回傳)都是同一種 JSON:
//! `{"error": "<英文訊息>", "code"?: "<代碼>", "args"?: {...}}`。
//!
//! core 的訊息一律英文。使用者實際會碰到、要翻成使用者語言的那幾種錯誤,
//! 在這裡依型別配上穩定的 code(Dart 端的對照:app/lib/src/native_error.dart):
//!
//! | code                          | args              | 來源                                 |
//! |-------------------------------|-------------------|--------------------------------------|
//! | `host_key_mismatch`           | expected, actual  | [`tterm_ssh::HostKeyMismatch`]       |
//! | `private_key_unreadable`      | reason            | [`tterm_ssh::UnreadablePrivateKey`]  |
//! | `timeout`                     | op                | [`tterm_session::Timeout`]           |
//! | `pairing_missing_prefix`      |                   | [`tterm_vault::PairingError`]        |
//! | `pairing_unsupported_version` | version           | 〃                                   |
//! | `pairing_malformed`           |                   | 〃                                   |
//! | `decrypt_failed`              |                   | [`tterm_vault::DecryptError`]        |
//!
//! 沒有 code 的錯誤(OS 錯誤、程式錯誤)Dart 照英文原文顯示。

use serde_json::{json, Value};
use tterm_vault::PairingError;

/// anyhow 錯誤 → 錯誤 JSON(認得的型別帶 code)。
pub(crate) fn error_json(e: &anyhow::Error) -> Value {
    let mut v = message_json(format!("{e:#}"));
    if let Some((code, args)) = classify(e) {
        v["code"] = code.into();
        v["args"] = args;
    }
    v
}

/// 純訊息 → 錯誤 JSON(沒有 code)。
pub(crate) fn message_json(msg: impl std::fmt::Display) -> Value {
    json!({ "error": msg.to_string() })
}

/// downcast 穿得過 `.context()` 包的層,錯誤在哪一層產生都認得到。
fn classify(e: &anyhow::Error) -> Option<(&'static str, Value)> {
    if let Some(m) = e.downcast_ref::<tterm_ssh::HostKeyMismatch>() {
        let args = json!({ "expected": m.expected, "actual": m.actual });
        return Some(("host_key_mismatch", args));
    }
    if let Some(k) = e.downcast_ref::<tterm_ssh::UnreadablePrivateKey>() {
        return Some(("private_key_unreadable", json!({ "reason": k.reason })));
    }
    if let Some(t) = e.downcast_ref::<tterm_session::Timeout>() {
        return Some(("timeout", json!({ "op": t.op })));
    }
    if let Some(p) = e.downcast_ref::<PairingError>() {
        return Some(match p {
            PairingError::MissingPrefix => ("pairing_missing_prefix", json!({})),
            PairingError::UnsupportedVersion(v) => {
                ("pairing_unsupported_version", json!({ "version": v }))
            }
            PairingError::Malformed(_) => ("pairing_malformed", json!({})),
        });
    }
    if e.downcast_ref::<tterm_vault::DecryptError>().is_some() {
        return Some(("decrypt_failed", json!({})));
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use anyhow::Context;

    #[test]
    fn coded_error_survives_context_layers() {
        let inner: anyhow::Result<()> = Err(tterm_session::Timeout { op: "read_file" }.into());
        let e = inner.context("outer").context("outermost").unwrap_err();
        let v = error_json(&e);
        assert_eq!(v["code"], "timeout");
        assert_eq!(v["args"]["op"], "read_file");
        let msg = v["error"].as_str().unwrap();
        assert!(msg.starts_with("outermost: outer: "), "英文訊息保留整條 context:{msg}");
    }

    #[test]
    fn plain_error_has_no_code() {
        let v = error_json(&anyhow::anyhow!("disk on fire"));
        assert_eq!(v, json!({ "error": "disk on fire" }));
    }
}
