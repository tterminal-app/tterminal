//! tterm-ssh:SSH session 層。
//!
//! API:`connect(target)` → `SshClient` → `open_shell()` → `Shell`
//! (input/events 兩條 channel,呼叫端把 events 餵給 TermEngine、
//!  把使用者輸入與 engine 的 PtyWrite 送回 input)。
//!
//! Host key 驗證(TOFU + 指紋固定):
//!   * `expected_fingerprint = None` → 首次連線,接受並記錄實際指紋
//!     (呼叫端取 `host_key_fingerprint()` 存進 vault)。
//!   * `expected_fingerprint = Some(fp)` → 比對;不符直接拒絕交握
//!     (視為可能的中間人攻擊,connect 回明確錯誤),**絕不靜默接受**。

use std::sync::{Arc, Mutex};

use anyhow::{anyhow, bail, Context, Result};
use russh::client::{self};
use russh::keys::{HashAlg, PrivateKeyWithHashAlg};
use russh::{ChannelMsg, Disconnect};
use tokio::sync::mpsc;

#[derive(Clone, Debug)]
pub struct SshTarget {
    pub host: String,
    pub port: u16,
    pub username: String,
    pub auth: Auth,
    /// 已知的 host key 指紋(`SHA256:...`);None = 首次連線(TOFU)。
    pub expected_fingerprint: Option<String>,
}

#[derive(Clone, Debug)]
pub enum Auth {
    Password(String),
    /// 私鑰檔路徑。
    KeyFile {
        path: std::path::PathBuf,
        passphrase: Option<String>,
    },
    /// 記憶體中的私鑰內容(vault 存的是私鑰文字,不是檔案路徑)。
    KeyData {
        pem: String,
        passphrase: Option<String>,
    },
}

/// Shell → 呼叫端 的事件。
#[derive(Debug)]
pub enum ShellEvent {
    Data(Vec<u8>),
    ExitStatus(u32),
    Closed,
}

/// 呼叫端 → Shell 的輸入。
#[derive(Debug)]
pub enum ShellInput {
    Data(Vec<u8>),
    Resize { cols: u16, rows: u16 },
    Close,
}

pub struct Shell {
    pub input: mpsc::Sender<ShellInput>,
    pub events: mpsc::Receiver<ShellEvent>,
}

/// 伺服器出示的 host key 和記下的指紋不符,交握已中止。UI 會給使用者看
/// (見 tterm-ffi 的 error.rs),不能只是一串字。
#[derive(Debug, thiserror::Error)]
#[error(
    "host key mismatch: expected {expected}, got {actual}; connection aborted \
     (possible man-in-the-middle attack, or the server's host key was changed)"
)]
pub struct HostKeyMismatch {
    pub expected: String,
    pub actual: String,
}

/// 私鑰讀不出來(格式不認得,或舊式 PEM 少了 passphrase)。
#[derive(Debug, thiserror::Error)]
#[error("can't read private key: {reason}")]
pub struct UnreadablePrivateKey {
    pub reason: String,
}

/// host key 驗證器:記錄實際指紋,並在有期望值時比對。
struct HostKeyVerifier {
    expected: Option<String>,
    seen: Arc<Mutex<Option<String>>>,
}

impl client::Handler for HostKeyVerifier {
    type Error = russh::Error;

    async fn check_server_key(
        &mut self,
        key: &russh::keys::ssh_key::PublicKey,
    ) -> Result<bool, Self::Error> {
        let fp = key.fingerprint(HashAlg::Sha256).to_string();
        *self.seen.lock().unwrap() = Some(fp.clone());
        match &self.expected {
            // 有期望指紋且不符 → 拒絕交握(可能是中間人攻擊)
            Some(expected) if expected != &fp => Ok(false),
            // 首次連線(TOFU)或指紋相符 → 接受
            _ => Ok(true),
        }
    }
}

pub struct SshClient {
    handle: client::Handle<HostKeyVerifier>,
    fingerprint: Option<String>,
}

pub async fn connect(target: &SshTarget) -> Result<SshClient> {
    let config = Arc::new(client::Config::default());
    let seen = Arc::new(Mutex::new(None));
    let verifier = HostKeyVerifier {
        expected: target.expected_fingerprint.clone(),
        seen: seen.clone(),
    };

    let mut handle = match client::connect(
        config,
        (target.host.as_str(), target.port),
        verifier,
    )
    .await
    {
        Ok(h) => h,
        Err(e) => {
            // 交握失敗且我們原本有期望指紋、對方指紋和它不符 → 明確報 host key 不符
            let actual = seen.lock().unwrap().clone();
            if let (Some(expected), Some(actual)) =
                (target.expected_fingerprint.as_ref(), actual.as_ref())
            {
                if expected != actual {
                    return Err(HostKeyMismatch {
                        expected: expected.clone(),
                        actual: actual.clone(),
                    }
                    .into());
                }
            }
            return Err(e).with_context(|| {
                format!("connect {}:{}", target.host, target.port)
            });
        }
    };

    let fingerprint = seen.lock().unwrap().clone();

    let authed = match &target.auth {
        Auth::Password(password) => handle
            .authenticate_password(&target.username, password)
            .await
            .context("authenticate_password")?,
        Auth::KeyFile { path, passphrase } => {
            let key = russh::keys::load_secret_key(path, passphrase.as_deref())
                .with_context(|| format!("load key {}", path.display()))?;
            authenticate_key(&mut handle, &target.username, key).await?
        }
        Auth::KeyData { pem, passphrase } => {
            let key = russh::keys::decode_secret_key(pem, passphrase.as_deref())
                .context("decode private key")?;
            authenticate_key(&mut handle, &target.username, key).await?
        }
    };
    if !authed.success() {
        bail!("authentication failed for {}", target.username);
    }
    Ok(SshClient {
        handle,
        fingerprint,
    })
}

async fn authenticate_key(
    handle: &mut client::Handle<HostKeyVerifier>,
    username: &str,
    key: russh::keys::PrivateKey,
) -> Result<client::AuthResult> {
    let hash = handle.best_supported_rsa_hash().await?.flatten();
    handle
        .authenticate_publickey(
            username,
            PrivateKeyWithHashAlg::new(Arc::new(key), hash),
        )
        .await
        .context("authenticate_publickey")
}

impl SshClient {
    /// 這次連線看到的 host key 指紋(`SHA256:...`);呼叫端首次連線後存進 vault。
    pub fn host_key_fingerprint(&self) -> Option<&str> {
        self.fingerprint.as_deref()
    }

    /// 開互動 shell(PTY)。回傳的 `Shell` 由背景 task 驅動。
    pub async fn open_shell(&self, cols: u16, rows: u16, term: &str) -> Result<Shell> {
        let mut channel = self
            .handle
            .channel_open_session()
            .await
            .context("channel_open_session")?;
        channel
            .request_pty(false, term, cols as u32, rows as u32, 0, 0, &[])
            .await
            .context("request_pty")?;
        channel.request_shell(false).await.context("request_shell")?;

        let (in_tx, mut in_rx) = mpsc::channel::<ShellInput>(64);
        let (ev_tx, ev_rx) = mpsc::channel::<ShellEvent>(256);

        tokio::spawn(async move {
            loop {
                tokio::select! {
                    msg = channel.wait() => match msg {
                        Some(ChannelMsg::Data { ref data }) => {
                            if ev_tx.send(ShellEvent::Data(data.to_vec())).await.is_err() {
                                break;
                            }
                        }
                        Some(ChannelMsg::ExtendedData { ref data, .. }) => {
                            if ev_tx.send(ShellEvent::Data(data.to_vec())).await.is_err() {
                                break;
                            }
                        }
                        Some(ChannelMsg::ExitStatus { exit_status }) => {
                            let _ = ev_tx.send(ShellEvent::ExitStatus(exit_status)).await;
                        }
                        Some(ChannelMsg::Eof) => {}
                        Some(ChannelMsg::Close) | None => {
                            let _ = ev_tx.send(ShellEvent::Closed).await;
                            break;
                        }
                        Some(_) => {}
                    },
                    inp = in_rx.recv() => match inp {
                        Some(ShellInput::Data(bytes)) => {
                            if channel.data(&bytes[..]).await.is_err() {
                                let _ = ev_tx.send(ShellEvent::Closed).await;
                                break;
                            }
                        }
                        Some(ShellInput::Resize { cols, rows }) => {
                            let _ = channel.window_change(cols as u32, rows as u32, 0, 0).await;
                        }
                        Some(ShellInput::Close) | None => {
                            let _ = channel.eof().await;
                            let _ = channel.close().await;
                            let _ = ev_tx.send(ShellEvent::Closed).await;
                            break;
                        }
                    },
                }
            }
        });

        Ok(Shell {
            input: in_tx,
            events: ev_rx,
        })
    }

    /// 在遠端執行一個命令(獨立 exec channel,不動互動 shell),回傳 stdout。
    /// stderr 丟棄;不論 exit status 都回傳收到的輸出(呼叫端自行判斷內容)。
    ///
    /// `stdin` 送完會關閉輸入端。腳本類的東西要走 stdin + `sh -s`:
    /// sshd 是用「使用者的登入 shell」跑 exec 命令,直接把 POSIX 腳本塞進
    /// 命令列,遇到 zsh(不分詞)/fish/csh 就爛;`sh -s` 誰都跑得起來。
    pub async fn exec(&self, command: &str, stdin: &[u8]) -> Result<Vec<u8>> {
        let mut channel = self
            .handle
            .channel_open_session()
            .await
            .context("channel_open_session (exec)")?;
        channel.exec(true, command).await.context("exec")?;
        if !stdin.is_empty() {
            channel.data(stdin).await.context("exec stdin")?;
        }
        channel.eof().await.context("exec eof")?;
        let mut out = Vec::new();
        loop {
            match channel.wait().await {
                Some(ChannelMsg::Data { ref data }) => out.extend_from_slice(data),
                Some(ChannelMsg::ExtendedData { .. }) => {} // stderr 不收
                Some(ChannelMsg::Eof) | Some(ChannelMsg::Close) | None => break,
                Some(_) => {}
            }
        }
        // 明確關閉,不留半開 channel 佔 server 的 MaxSessions 名額
        let _ = channel.close().await;
        Ok(out)
    }

    /// 開一條 SFTP subsystem channel(和 shell 共用同一條 SSH 連線)。
    pub async fn open_sftp(&self) -> Result<russh_sftp::client::SftpSession> {
        let channel = self
            .handle
            .channel_open_session()
            .await
            .context("channel_open_session (sftp)")?;
        channel
            .request_subsystem(true, "sftp")
            .await
            .context("request sftp subsystem")?;
        let sftp = russh_sftp::client::SftpSession::new(channel.into_stream())
            .await
            .context("start sftp session")?;
        Ok(sftp)
    }

    pub async fn disconnect(self) -> Result<()> {
        let _ = self
            .handle
            .disconnect(Disconnect::ByApplication, "bye", "en")
            .await;
        Ok(())
    }
}

/// 覆寫遠端檔案。russh_sftp 的 `SftpSession::write` 只帶 `WRITE` flag:
/// 真實 sshd 對不存在的檔會回 NoSuchFile(上傳新檔必失敗),覆寫較短內容
/// 也不截斷(留舊尾巴)。這裡明確用 CREATE|TRUNCATE|WRITE。
pub async fn sftp_write_all(
    sftp: &russh_sftp::client::SftpSession,
    path: &str,
    data: &[u8],
) -> Result<()> {
    use russh_sftp::protocol::OpenFlags;
    use tokio::io::AsyncWriteExt;
    let mut f = sftp
        .open_with_flags(
            path,
            OpenFlags::CREATE | OpenFlags::TRUNCATE | OpenFlags::WRITE,
        )
        .await
        .context("sftp open (create|truncate|write)")?;
    f.write_all(data).await.context("sftp write")?;
    // shutdown = flush 所有 write ack + close 遠端 handle
    f.shutdown().await.context("sftp close")?;
    Ok(())
}

/// 遠端目錄一筆項目(SFTP)。
#[derive(Debug, Clone)]
pub struct SftpEntry {
    pub name: String,
    pub is_dir: bool,
    pub size: u64,
}

/// 私鑰導出的公開資訊 —— 給 UI 顯示與複製(貼到遠端 authorized_keys)。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PublicKeyInfo {
    /// authorized_keys 一行:`ssh-ed25519 AAAA... comment`。
    pub openssh: String,
    /// 演算法名(`ssh-ed25519` / `rsa-sha2-256` ...)。
    pub algorithm: String,
    /// `SHA256:...`(與 ssh-keygen -lf 一致)。
    pub fingerprint: String,
    /// 私鑰裡帶的註解(常是 user@host),沒有就是空字串。
    pub comment: String,
}

/// 從私鑰(記憶體 PEM)算出公鑰 —— 不需連線。
///
/// OpenSSH 私鑰格式把公鑰段放在明文區,所以**有 passphrase 也算得出來**、
/// 不必解密;只有舊式 PEM / PuTTY 要 passphrase 才解得出金鑰對。
pub fn public_key_of_private_key(pem: &str, passphrase: Option<&str>) -> Result<PublicKeyInfo> {
    let key = match russh::keys::PrivateKey::from_openssh(pem) {
        // comment 藏在加密段裡,解得開就解一下,讓 UI 顯示 user@host。
        Ok(k) if k.is_encrypted() => match passphrase {
            Some(p) => k.decrypt(p).unwrap_or(k),
            None => k,
        },
        Ok(k) => k,
        // 不是 OpenSSH 格式(PEM / PKCS#8 / PuTTY),走要解密的那條路。
        Err(_) => russh::keys::decode_secret_key(pem, passphrase).map_err(|e| {
            UnreadablePrivateKey {
                reason: e.to_string(),
            }
        })?,
    };
    let public = key.public_key();
    Ok(PublicKeyInfo {
        openssh: public
            .to_openssh()
            .map_err(|e| anyhow!("failed to encode public key: {e}"))?,
        algorithm: public.algorithm().to_string(),
        fingerprint: public.fingerprint(HashAlg::Sha256).to_string(),
        comment: public.comment().as_str_lossy().to_string(),
    })
}

/// 從私鑰(記憶體 PEM)導出公開指紋 —— 供 UI 顯示,不需連線。
pub fn fingerprint_of_private_key(pem: &str, passphrase: Option<&str>) -> Result<String> {
    Ok(public_key_of_private_key(pem, passphrase)?.fingerprint)
}
