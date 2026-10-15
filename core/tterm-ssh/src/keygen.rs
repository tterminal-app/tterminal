//! 在 app 內產生 SSH 金鑰對 —— 手機上沒有 ssh-keygen 可用。
//!
//! 產出與 `ssh-keygen` 相同的 OpenSSH 私鑰格式(`-----BEGIN OPENSSH PRIVATE KEY-----`),
//! 設了 passphrase 時同樣用 aes256-ctr + bcrypt-pbkdf(16 rounds)加密,
//! 所以存進 vault 後走的是跟「貼上匯入」完全一樣的路。

use anyhow::{anyhow, Result};
use russh::keys::ssh_key::LineEnding;
use russh::keys::{Algorithm, HashAlg, PrivateKey};

use crate::PublicKeyInfo;

/// 可以產生的金鑰種類。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyKind {
    /// 預設:短、快、OpenSSH 6.5(2014)以後都支援。
    Ed25519,
    /// RSA 4096:給還不認得 ed25519 的舊伺服器 / 網路設備。
    Rsa,
}

impl KeyKind {
    /// FFI / UI 用的名稱(同 `ssh-keygen -t`)。
    pub fn from_name(name: &str) -> Option<Self> {
        match name {
            "ed25519" => Some(Self::Ed25519),
            "rsa" => Some(Self::Rsa),
            _ => None,
        }
    }
}

/// 產生的金鑰對。
pub struct GeneratedKey {
    /// OpenSSH 格式私鑰;有 passphrase 時已加密。
    pub private_key: String,
    /// 公鑰(authorized_keys 那一行、指紋……)。
    pub public: PublicKeyInfo,
}

/// 產生新的金鑰對。`comment` 會出現在公鑰行尾(authorized_keys 裡用來認是哪把);
/// `passphrase` 為 None 或空字串 = 不加密。
pub fn generate_key(
    kind: KeyKind,
    comment: &str,
    passphrase: Option<&str>,
) -> Result<GeneratedKey> {
    let algorithm = match kind {
        KeyKind::Ed25519 => Algorithm::Ed25519,
        // RSA 4096(ssh-key 的預設長度);簽章雜湊連線時再協商 rsa-sha2-*
        KeyKind::Rsa => Algorithm::Rsa { hash: None },
    };
    let mut rng = rand::rng();
    let mut key = PrivateKey::random(&mut rng, algorithm)
        .map_err(|e| anyhow!("failed to generate key: {e}"))?;
    key.set_comment(comment);

    let public = key.public_key();
    let public = PublicKeyInfo {
        openssh: public
            .to_openssh()
            .map_err(|e| anyhow!("failed to encode public key: {e}"))?,
        algorithm: public.algorithm().to_string(),
        fingerprint: public.fingerprint(HashAlg::Sha256).to_string(),
        comment: public.comment().as_str_lossy().to_string(),
    };

    let key = match passphrase.filter(|p| !p.is_empty()) {
        Some(p) => key
            .encrypt(&mut rng, p)
            .map_err(|e| anyhow!("failed to encrypt private key: {e}"))?,
        None => key,
    };
    let private_key = key
        .to_openssh(LineEnding::LF)
        .map_err(|e| anyhow!("failed to encode private key: {e}"))?
        .to_string();
    Ok(GeneratedKey {
        private_key,
        public,
    })
}
