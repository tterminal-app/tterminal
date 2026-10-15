//! 從私鑰算公鑰(金鑰列表要顯示 / 複製 authorized_keys 那一行)。
//!
//! 期望值以 `ssh-keygen -y` / `ssh-keygen -lf` 產出,鎖住格式與 OpenSSH 一致。

use tterm_ssh::{public_key_of_private_key, UnreadablePrivateKey};

/// 未加密的 ed25519(與 test_sshd 的 host key 同一把)。
const PLAIN_ED25519: &str = "-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACAePoPUeGy1BYPUnU85k7BxEAFnLE22roHAmqT6Kr4nFQAAAJjx5SxT8eUs
UwAAAAtzc2gtZWQyNTUxOQAAACAePoPUeGy1BYPUnU85k7BxEAFnLE22roHAmqT6Kr4nFQ
AAAEC+aPxLIOpZaxHv96OGN9KaCoTDSRdmzLUOCfDDNmjm/x4+g9R4bLUFg9SdTzmTsHEQ
AWcsTbaugcCapPoqvicVAAAAD3R0ZXJtLXRlc3QtaG9zdAECAwQFBg==
-----END OPENSSH PRIVATE KEY-----";

/// 有 passphrase("hunter2")的 ed25519。
const ENCRYPTED_ED25519: &str = "-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABBvnYmabT
Ugt/xU8qv/O7tcAAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIJS1iQyqpUmsaybd
h4jSeo+WEpV5P60SujXMQj6HnxlTAAAAoLKMjFQKTbEKyPc+2iPemabjvEYrtMomqKgbfv
Aq1E/HudiudeI0T6/XqlVTApdkK1fhpPmfTyWFJ9stGz1poodoiXxTWVz682n3kO0LipLJ
TohhnWC8TEcoPCmHWyTv8TXXPArSinIRxMdo6YodLq1N61BR8//dXS+stYqz8FXKqePabm
WuMNVoKr80D4znyXzQUayVYR5sprIWnW5kQ2g=
-----END OPENSSH PRIVATE KEY-----";

#[test]
fn derives_openssh_line_and_fingerprint() {
    let info = public_key_of_private_key(PLAIN_ED25519, None).expect("derive");
    assert_eq!(
        info.openssh,
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB4+g9R4bLUFg9SdTzmTsHEQAWcsTbaugcCapPoqvicV \
         tterm-test-host"
    );
    assert_eq!(
        info.fingerprint,
        "SHA256:C2e8ILs2vZ7SvQxsU2QSoLr5dsCxeRgdbkWmO+LITpE"
    );
    assert_eq!(info.algorithm, "ssh-ed25519");
    assert_eq!(info.comment, "tterm-test-host");
}

/// OpenSSH 私鑰的公鑰段是明文 —— 沒 passphrase 也要算得出來,
/// 不然設了 passphrase 的金鑰在列表上就永遠複製不到公鑰。
#[test]
fn derives_from_encrypted_key_without_passphrase() {
    const B64: &str =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJS1iQyqpUmsaybdh4jSeo+WEpV5P60SujXMQj6HnxlT";
    // 沒 passphrase:公鑰算得出來,只是 comment 在加密段裡拿不到。
    let no_pass = public_key_of_private_key(ENCRYPTED_ED25519, None).expect("derive");
    assert_eq!(no_pass.openssh, B64);
    assert_eq!(no_pass.comment, "");
    // 有 passphrase:連 comment 一起還原,與 ssh-keygen -y 輸出相同。
    let with_pass =
        public_key_of_private_key(ENCRYPTED_ED25519, Some("hunter2")).expect("derive");
    assert_eq!(with_pass.openssh, format!("{B64} enc@tterm-test"));
    assert_eq!(with_pass.fingerprint, no_pass.fingerprint);
    // passphrase 打錯不該讓公鑰消失(頂多少了 comment)。
    let wrong = public_key_of_private_key(ENCRYPTED_ED25519, Some("nope")).expect("derive");
    assert_eq!(wrong.openssh, B64);
}

#[test]
fn rejects_garbage() {
    let err = public_key_of_private_key("not a key", None).unwrap_err();
    assert!(err.downcast_ref::<UnreadablePrivateKey>().is_some(), "{err}");
}
