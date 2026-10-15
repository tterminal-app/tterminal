//! 在 app 內產生 SSH 金鑰:產物要能被「貼上匯入」那條路原樣使用
//! (連線時 decode_secret_key、金鑰列表 public_key_of_private_key),
//! 且與 OpenSSH 的 ssh-keygen 互通。

use russh::keys::{decode_secret_key, PrivateKey};
use tterm_ssh::{generate_key, public_key_of_private_key, KeyKind};

#[test]
fn ed25519_without_passphrase_roundtrips() {
    let key = generate_key(KeyKind::Ed25519, "me@phone", None).expect("generate");
    assert!(
        key.private_key
            .starts_with("-----BEGIN OPENSSH PRIVATE KEY-----\n"),
        "要是 OpenSSH 格式:{}",
        key.private_key
    );
    assert!(!PrivateKey::from_openssh(&key.private_key)
        .unwrap()
        .is_encrypted());

    assert_eq!(key.public.algorithm, "ssh-ed25519");
    assert_eq!(key.public.comment, "me@phone");
    assert!(key.public.openssh.starts_with("ssh-ed25519 AAAA"));
    assert!(key.public.openssh.ends_with(" me@phone"));
    assert!(key.public.fingerprint.starts_with("SHA256:"));

    // 金鑰列表從私鑰算出的公鑰,要跟產生當下給使用者複製的一模一樣
    let derived = public_key_of_private_key(&key.private_key, None).expect("derive");
    assert_eq!(derived, key.public);

    // 連線時走的解碼路徑
    let decoded = decode_secret_key(&key.private_key, None).expect("decode");
    assert_eq!(
        decoded.public_key().to_openssh().unwrap(),
        key.public.openssh
    );
}

#[test]
fn passphrase_encrypts_private_key() {
    let key = generate_key(KeyKind::Ed25519, "enc", Some("hunter2")).expect("generate");
    assert!(PrivateKey::from_openssh(&key.private_key)
        .unwrap()
        .is_encrypted());

    assert!(
        decode_secret_key(&key.private_key, None).is_err(),
        "沒 passphrase 不該解得開"
    );
    assert!(
        decode_secret_key(&key.private_key, Some("nope")).is_err(),
        "錯的 passphrase 不該解得開"
    );
    let decoded = decode_secret_key(&key.private_key, Some("hunter2")).expect("decode");
    assert_eq!(
        decoded.public_key().to_openssh().unwrap(),
        key.public.openssh
    );

    // 列表沒 passphrase 也算得出公鑰(只差 comment 在加密段裡)
    let derived = public_key_of_private_key(&key.private_key, None).expect("derive");
    assert_eq!(derived.fingerprint, key.public.fingerprint);
    let derived = public_key_of_private_key(&key.private_key, Some("hunter2")).expect("derive");
    assert_eq!(derived, key.public);
}

#[test]
fn empty_passphrase_means_unencrypted() {
    let key = generate_key(KeyKind::Ed25519, "", Some("")).expect("generate");
    assert!(!PrivateKey::from_openssh(&key.private_key)
        .unwrap()
        .is_encrypted());
    assert_eq!(key.public.comment, "");
}

#[test]
fn every_call_makes_a_new_key() {
    let a = generate_key(KeyKind::Ed25519, "x", None).unwrap();
    let b = generate_key(KeyKind::Ed25519, "x", None).unwrap();
    assert_ne!(a.public.fingerprint, b.public.fingerprint);
}

#[test]
fn rsa_key_roundtrips() {
    let key = generate_key(KeyKind::Rsa, "old-server", Some("pw")).expect("generate");
    assert_eq!(key.public.algorithm, "ssh-rsa");
    assert!(key.public.openssh.starts_with("ssh-rsa AAAA"));
    let decoded = decode_secret_key(&key.private_key, Some("pw")).expect("decode");
    assert_eq!(
        decoded.public_key().to_openssh().unwrap(),
        key.public.openssh
    );
    let rsa = decoded.key_data().rsa().expect("rsa keypair");
    assert_eq!(rsa.key_size(), 4096);
}

#[test]
fn key_kind_names() {
    assert_eq!(KeyKind::from_name("ed25519"), Some(KeyKind::Ed25519));
    assert_eq!(KeyKind::from_name("rsa"), Some(KeyKind::Rsa));
    assert_eq!(KeyKind::from_name("dsa"), None);
}

/// 與 OpenSSH 互通:ssh-keygen 讀得懂我們產的私鑰(含加密的),算出同一行公鑰。
/// 機器上沒有 ssh-keygen 就跳過;Windows 版 ssh-keygen 要檔案 ACL 只限本人,
/// 暫存檔做不到,只在 unix 跑。
#[cfg(unix)]
#[test]
fn openssh_ssh_keygen_reads_generated_key() {
    use std::process::Command;

    if Command::new("ssh-keygen").arg("-?").output().is_err() {
        eprintln!("沒有 ssh-keygen,跳過");
        return;
    }
    let key = generate_key(KeyKind::Ed25519, "interop", Some("s3cret")).unwrap();
    let path = std::env::temp_dir().join(format!(
        "tterm-keygen-{}-{}",
        std::process::id(),
        key.public.fingerprint.len()
    ));
    std::fs::write(&path, &key.private_key).unwrap();
    // ssh-keygen 拒讀權限太寬的私鑰檔
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
    }
    let out = Command::new("ssh-keygen")
        .args(["-y", "-P", "s3cret", "-f"])
        .arg(&path)
        .output()
        .unwrap();
    std::fs::remove_file(&path).ok();
    assert!(
        out.status.success(),
        "ssh-keygen 讀不出來:{}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert_eq!(
        String::from_utf8(out.stdout).unwrap().trim(),
        key.public.openssh
    );
}
