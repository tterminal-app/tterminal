//! SSH 端對端測試:in-process russh server(不需要 docker / 外部 sshd)。
//!
//! server 接受 password 與 pubkey 認證,shell 開啟後送 banner 並回聲(echo)
//! 收到的資料;client 用 tterm-ssh 連上、開 shell、送資料,經 TermEngine
//! 驗證畫面。另外驗證 host key 指紋:相符可連、不符拒絕。

use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use std::time::Duration;

use russh::keys::ssh_key;
use russh::server::{Auth, ChannelOpenHandle, Handler, Msg, Session};
use russh::{Channel, ChannelId};
use russh_sftp::protocol::{
    Attrs, Data, File, FileAttributes, Handle as SftpHandle, Name, Status, StatusCode,
};
use tokio::net::TcpListener;
use tterm_ssh::{connect, Auth as ClientAuth, HostKeyMismatch, ShellEvent, ShellInput, SshTarget};
use tterm_term::TermEngine;

const HOST_KEY: &str = "-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACAePoPUeGy1BYPUnU85k7BxEAFnLE22roHAmqT6Kr4nFQAAAJjx5SxT8eUs
UwAAAAtzc2gtZWQyNTUxOQAAACAePoPUeGy1BYPUnU85k7BxEAFnLE22roHAmqT6Kr4nFQ
AAAEC+aPxLIOpZaxHv96OGN9KaCoTDSRdmzLUOCfDDNmjm/x4+g9R4bLUFg9SdTzmTsHEQ
AWcsTbaugcCapPoqvicVAAAAD3R0ZXJtLXRlc3QtaG9zdAECAwQFBg==
-----END OPENSSH PRIVATE KEY-----";

const CLIENT_KEY: &str = "-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACDIp718vpBJKY29c3yUfoJN0/579j1NsFsVixO0d+LYwQAAAJiqVxnnqlcZ
5wAAAAtzc2gtZWQyNTUxOQAAACDIp718vpBJKY29c3yUfoJN0/579j1NsFsVixO0d+LYwQ
AAAECpV6fy6NeI2a2iSl39tYZbe4mYnPMCYDzMVkJ8q1r/C8invXy+kEkpjb1zfJR+gk3T
/nv2PU2wWxWLE7R34tjBAAAAEXR0ZXJtLXRlc3QtY2xpZW50AQIDBA==
-----END OPENSSH PRIVATE KEY-----";

const USER: &str = "tester";
const PASSWORD: &str = "secret-123";

// ---- in-process 測試用 SSH server ----

#[derive(Default)]
struct TestHandler {
    // exec "cat" 的 channel:回聲 stdin,收到 client eof 才收尾
    cat_channels: HashSet<ChannelId>,
}

impl Handler for TestHandler {
    type Error = russh::Error;

    async fn auth_password(&mut self, user: &str, password: &str) -> Result<Auth, Self::Error> {
        if user == USER && password == PASSWORD {
            Ok(Auth::Accept)
        } else {
            Ok(Auth::Reject {
                proceed_with_methods: None,
                partial_success: false,
            })
        }
    }

    async fn auth_publickey(
        &mut self,
        user: &str,
        _public_key: &ssh_key::PublicKey,
    ) -> Result<Auth, Self::Error> {
        // 測試 server 接受任何持有私鑰完成簽章的使用者(client key 已由簽章驗證)
        if user == USER {
            Ok(Auth::Accept)
        } else {
            Ok(Auth::Reject {
                proceed_with_methods: None,
                partial_success: false,
            })
        }
    }

    async fn channel_open_session(
        &mut self,
        _channel: Channel<Msg>,
        reply: ChannelOpenHandle,
        _session: &mut Session,
    ) -> Result<(), Self::Error> {
        reply.accept().await;
        Ok(())
    }

    async fn pty_request(
        &mut self,
        _channel: ChannelId,
        _term: &str,
        _cw: u32,
        _ch: u32,
        _pw: u32,
        _ph: u32,
        _modes: &[(russh::Pty, u32)],
        _session: &mut Session,
    ) -> Result<(), Self::Error> {
        Ok(())
    }

    async fn shell_request(
        &mut self,
        channel: ChannelId,
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        // 開 shell → 送 banner
        session.data(channel, b"SSH-READY\r\n".to_vec())?;
        Ok(())
    }

    async fn data(
        &mut self,
        channel: ChannelId,
        data: &[u8],
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        // 回聲:把收到的 bytes 原樣送回,client 端會在畫面看到
        session.data(channel, data.to_vec())?;
        Ok(())
    }

    async fn exec_request(
        &mut self,
        channel: ChannelId,
        data: &[u8],
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        session.channel_success(channel)?;
        if data == b"cat" {
            // 模擬 cat:data() 回聲 stdin,等 client eof 才收尾
            self.cat_channels.insert(channel);
            return Ok(());
        }
        // 其他命令:回 "EXEC:<命令>" 後正常收尾(exit status → eof → close)
        let mut reply = b"EXEC:".to_vec();
        reply.extend_from_slice(data);
        session.data(channel, reply)?;
        session.exit_status_request(channel, 0)?;
        session.eof(channel)?;
        session.close(channel)?;
        Ok(())
    }

    async fn channel_eof(
        &mut self,
        channel: ChannelId,
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        if self.cat_channels.remove(&channel) {
            session.exit_status_request(channel, 0)?;
            session.eof(channel)?;
            session.close(channel)?;
        }
        Ok(())
    }
}

/// 啟動測試 server,回傳監聽埠。連線由背景 task 處理直到 process 結束。
async fn start_server() -> u16 {
    let key = russh::keys::decode_secret_key(HOST_KEY, None).expect("host key");
    let config = Arc::new(russh::server::Config {
        inactivity_timeout: Some(Duration::from_secs(30)),
        auth_rejection_time: Duration::from_millis(1),
        keys: vec![key],
        ..Default::default()
    });

    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let port = listener.local_addr().unwrap().port();

    tokio::spawn(async move {
        loop {
            let Ok((stream, _addr)) = listener.accept().await else {
                break;
            };
            let config = config.clone();
            tokio::spawn(async move {
                if let Ok(session) =
                    russh::server::run_stream(config, stream, TestHandler::default()).await
                {
                    let _ = session.await;
                }
            });
        }
    });

    port
}

/// 送資料進 shell、收 timeout 內的所有輸出、經引擎還原成畫面文字。
async fn run_shell(target: SshTarget, send: &[u8]) -> (String, Option<String>) {
    let client = connect(&target).await.expect("connect");
    let fingerprint = client.host_key_fingerprint().map(|s| s.to_string());
    let mut shell = client.open_shell(80, 24, "xterm-256color").await.expect("shell");
    let mut engine = TermEngine::new(80, 24, 1000);

    shell
        .input
        .send(ShellInput::Data(send.to_vec()))
        .await
        .expect("send");

    // 收 800ms 內的輸出
    let deadline = tokio::time::Instant::now() + Duration::from_millis(800);
    loop {
        match tokio::time::timeout_at(deadline, shell.events.recv()).await {
            Ok(Some(ShellEvent::Data(bytes))) => {
                engine.feed(&bytes);
                let _ = engine.drain_events();
            }
            Ok(Some(_)) | Err(_) => break,
            Ok(None) => break,
        }
    }
    let _ = shell.input.send(ShellInput::Close).await;
    (engine.visible_text().join("\n"), fingerprint)
}

// ---- in-process SFTP 測試 server ----

const SFTP_HOME: &str = "/home/tester";

/// 固定的記憶體樹:路徑 → [(名稱, 是否目錄, 內容)]。
type SftpTree = HashMap<&'static str, Vec<(&'static str, bool, &'static [u8])>>;

fn sftp_tree() -> SftpTree {
    let mut m = HashMap::new();
    m.insert(
        "/home/tester",
        vec![
            ("readme.txt", false, &b"hello sftp\n"[..]),
            ("data", true, &b""[..]),
            ("notes.txt", false, &b"line1\nline2\n"[..]),
        ],
    );
    m.insert("/home/tester/data", vec![("a.bin", false, &b"AAA"[..])]);
    m
}

fn sftp_file(path: &str) -> Option<&'static [u8]> {
    match path {
        "/home/tester/readme.txt" => Some(b"hello sftp\n"),
        "/home/tester/notes.txt" => Some(b"line1\nline2\n"),
        "/home/tester/data/a.bin" => Some(b"AAA"),
        _ => None,
    }
}

fn ok_status(id: u32) -> Status {
    Status {
        id,
        status_code: StatusCode::Ok,
        error_message: "Ok".into(),
        language_tag: "en".into(),
    }
}

#[derive(Default)]
struct SftpTestHandler {
    // 每次 open/opendir 給一個唯一 handle → 真實路徑
    handles: HashMap<String, String>,
    next: u64,
    // 已回過內容的 dir handle(下次 readdir 回 EOF)
    dir_read: HashSet<String>,
    // 寫入落地(蓋過固定樹),同一條 SFTP session 內可讀回驗證
    written: HashMap<String, Vec<u8>>,
}

impl SftpTestHandler {
    fn new_handle(&mut self, path: String, prefix: &str) -> String {
        self.next += 1;
        let h = format!("{prefix}{}", self.next);
        self.handles.insert(h.clone(), path);
        h
    }
}

impl russh_sftp::server::Handler for SftpTestHandler {
    type Error = StatusCode;
    fn unimplemented(&self) -> StatusCode {
        StatusCode::OpUnsupported
    }

    async fn realpath(&mut self, id: u32, path: String) -> Result<Name, StatusCode> {
        let canon = if path == "." { SFTP_HOME.to_string() } else { path };
        Ok(Name {
            id,
            files: vec![File::dummy(canon)],
        })
    }

    async fn opendir(&mut self, id: u32, path: String) -> Result<SftpHandle, StatusCode> {
        if sftp_tree().contains_key(path.as_str()) {
            let handle = self.new_handle(path, "d");
            Ok(SftpHandle { id, handle })
        } else {
            Err(StatusCode::NoSuchFile)
        }
    }

    async fn readdir(&mut self, id: u32, handle: String) -> Result<Name, StatusCode> {
        if self.dir_read.contains(&handle) {
            return Err(StatusCode::Eof);
        }
        let path = self.handles.get(&handle).cloned().ok_or(StatusCode::Failure)?;
        self.dir_read.insert(handle.clone());
        let entries = sftp_tree()
            .get(path.as_str())
            .cloned()
            .ok_or(StatusCode::NoSuchFile)?;
        let files = entries
            .into_iter()
            .map(|(name, is_dir, content)| {
                let mut attrs = FileAttributes::default();
                attrs.set_dir(is_dir);
                if !is_dir {
                    attrs.set_regular(true);
                    attrs.size = Some(content.len() as u64);
                }
                File {
                    filename: name.to_string(),
                    longname: name.to_string(),
                    attrs,
                }
            })
            .collect();
        Ok(Name { id, files })
    }

    async fn open(
        &mut self,
        id: u32,
        filename: String,
        pflags: russh_sftp::protocol::OpenFlags,
        _attrs: FileAttributes,
    ) -> Result<SftpHandle, StatusCode> {
        use russh_sftp::protocol::OpenFlags;
        // 模擬真實 sshd:檔案不存在且沒帶 CREATE → NoSuchFile
        let exists =
            sftp_file(&filename).is_some() || self.written.contains_key(filename.as_str());
        if !exists && !pflags.contains(OpenFlags::CREATE) {
            return Err(StatusCode::NoSuchFile);
        }
        if pflags.contains(OpenFlags::TRUNCATE) || !exists {
            self.written.insert(filename.clone(), Vec::new());
        } else if pflags.contains(OpenFlags::WRITE) && !self.written.contains_key(&filename) {
            // 無 TRUNCATE 的覆寫:從原內容出發(舊尾巴會留著)
            if let Some(c) = sftp_file(&filename) {
                self.written.insert(filename.clone(), c.to_vec());
            }
        }
        let handle = self.new_handle(filename, "f");
        Ok(SftpHandle { id, handle })
    }

    async fn read(
        &mut self,
        id: u32,
        handle: String,
        offset: u64,
        len: u32,
    ) -> Result<Data, StatusCode> {
        let path = self.handles.get(&handle).cloned().ok_or(StatusCode::Failure)?;
        let written = self.written.get(&path).map(|v| v.as_slice());
        let content = written
            .or_else(|| sftp_file(&path))
            .ok_or(StatusCode::NoSuchFile)?;
        let start = offset as usize;
        if start >= content.len() {
            return Err(StatusCode::Eof);
        }
        let end = (start + len as usize).min(content.len());
        Ok(Data {
            id,
            data: content[start..end].to_vec(),
        })
    }

    async fn write(
        &mut self,
        id: u32,
        handle: String,
        offset: u64,
        data: Vec<u8>,
    ) -> Result<Status, StatusCode> {
        let path = self.handles.get(&handle).cloned().ok_or(StatusCode::Failure)?;
        let buf = self.written.entry(path).or_default();
        let end = offset as usize + data.len();
        if buf.len() < end {
            buf.resize(end, 0);
        }
        buf[offset as usize..end].copy_from_slice(&data);
        Ok(ok_status(id))
    }

    async fn close(&mut self, id: u32, handle: String) -> Result<Status, StatusCode> {
        self.handles.remove(&handle);
        self.dir_read.remove(&handle);
        Ok(ok_status(id))
    }

    async fn stat(&mut self, id: u32, path: String) -> Result<Attrs, StatusCode> {
        self.lstat(id, path).await
    }

    async fn lstat(&mut self, id: u32, path: String) -> Result<Attrs, StatusCode> {
        let mut attrs = FileAttributes::default();
        if sftp_tree().contains_key(path.as_str()) {
            attrs.set_dir(true);
        } else if let Some(c) = self.written.get(&path).map(|v| v.as_slice()).or_else(|| sftp_file(&path)) {
            attrs.set_regular(true);
            attrs.size = Some(c.len() as u64);
        } else {
            return Err(StatusCode::NoSuchFile);
        }
        Ok(Attrs { id, attrs })
    }
}

/// SSH server handler(SFTP 版):持有 channel,subsystem "sftp" 時交給 SFTP server。
#[derive(Default)]
struct SftpSshHandler {
    channels: HashMap<ChannelId, Channel<Msg>>,
}

impl Handler for SftpSshHandler {
    type Error = russh::Error;

    async fn auth_password(&mut self, user: &str, password: &str) -> Result<Auth, Self::Error> {
        if user == USER && password == PASSWORD {
            Ok(Auth::Accept)
        } else {
            Ok(Auth::Reject {
                proceed_with_methods: None,
                partial_success: false,
            })
        }
    }

    async fn channel_open_session(
        &mut self,
        channel: Channel<Msg>,
        reply: ChannelOpenHandle,
        _session: &mut Session,
    ) -> Result<(), Self::Error> {
        reply.accept().await;
        self.channels.insert(channel.id(), channel);
        Ok(())
    }

    async fn subsystem_request(
        &mut self,
        channel_id: ChannelId,
        name: &str,
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        if name == "sftp" {
            session.channel_success(channel_id)?;
            if let Some(channel) = self.channels.remove(&channel_id) {
                russh_sftp::server::run(channel.into_stream(), SftpTestHandler::default()).await;
            }
        }
        Ok(())
    }
}

async fn start_sftp_server() -> u16 {
    let key = russh::keys::decode_secret_key(HOST_KEY, None).expect("host key");
    let config = Arc::new(russh::server::Config {
        auth_rejection_time: Duration::from_millis(1),
        keys: vec![key],
        ..Default::default()
    });
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(async move {
        loop {
            let Ok((stream, _)) = listener.accept().await else {
                break;
            };
            let config = config.clone();
            tokio::spawn(async move {
                if let Ok(s) =
                    russh::server::run_stream(config, stream, SftpSshHandler::default()).await
                {
                    let _ = s.await;
                }
            });
        }
    });
    port
}

#[tokio::test(flavor = "multi_thread")]
async fn sftp_list_read() {
    let port = start_sftp_server().await;
    let client = connect(&target(port, ClientAuth::Password(PASSWORD.into()), None))
        .await
        .expect("connect");
    let sftp = client.open_sftp().await.expect("open sftp");

    // canonicalize "." → home
    let home = sftp.canonicalize(".").await.expect("canonicalize");
    assert_eq!(home, SFTP_HOME);

    // 列目錄
    let mut names: Vec<String> = sftp
        .read_dir(SFTP_HOME)
        .await
        .expect("read_dir")
        .map(|e| e.file_name())
        .collect();
    names.sort();
    assert_eq!(names, vec!["data", "notes.txt", "readme.txt"]);

    // 目錄旗標與檔案大小
    let entries: Vec<_> = sftp.read_dir(SFTP_HOME).await.unwrap().collect();
    let data_dir = entries.iter().find(|e| e.file_name() == "data").unwrap();
    assert!(data_dir.metadata().is_dir());
    let readme = entries.iter().find(|e| e.file_name() == "readme.txt").unwrap();
    assert!(!readme.metadata().is_dir());
    assert_eq!(readme.metadata().size, Some(11));

    // 讀檔
    let content = sftp.read("/home/tester/readme.txt").await.expect("read");
    assert_eq!(content, b"hello sftp\n");

    // 進子目錄
    let sub: Vec<String> = sftp
        .read_dir("/home/tester/data")
        .await
        .unwrap()
        .map(|e| e.file_name())
        .collect();
    assert_eq!(sub, vec!["a.bin"]);

    // russh_sftp 內建 write 只帶 WRITE flag:對不存在的檔要像真 sshd 一樣失敗
    // (這就是「拖新檔上傳整批被略過」的 bug 根源)
    assert!(
        sftp.write("/home/tester/new.txt", b"written").await.is_err(),
        "WRITE-only 開不存在的檔應失敗"
    );

    // 我們的 sftp_write_all(CREATE|TRUNCATE|WRITE):上傳新檔要成功、可讀回
    tterm_ssh::sftp_write_all(&sftp, "/home/tester/new.txt", b"written")
        .await
        .expect("sftp_write_all 新檔");
    assert_eq!(sftp.read("/home/tester/new.txt").await.unwrap(), b"written");

    // 覆寫較短內容要截斷,不能留舊尾巴
    tterm_ssh::sftp_write_all(&sftp, "/home/tester/notes.txt", b"x")
        .await
        .expect("sftp_write_all 覆寫");
    assert_eq!(sftp.read("/home/tester/notes.txt").await.unwrap(), b"x");
}

#[tokio::test]
async fn ssh_exec_returns_stdout() {
    let port = start_server().await;
    let client = connect(&target(port, ClientAuth::Password(PASSWORD.into()), None))
        .await
        .expect("connect");
    let out = client.exec("pwd", b"").await.expect("exec");
    assert_eq!(out, b"EXEC:pwd");
    // exec channel 是獨立的,連線還能繼續用
    let out2 = client.exec("echo hi", b"").await.expect("exec 2");
    assert_eq!(out2, b"EXEC:echo hi");
    // stdin 走 exec channel(cwd 偵測腳本靠這個經 `sh -s` 送進去)
    let out3 = client.exec("cat", b"stdin-payload").await.expect("exec cat");
    assert_eq!(out3, b"stdin-payload");
}

fn target(port: u16, auth: ClientAuth, expected: Option<String>) -> SshTarget {
    SshTarget {
        host: "127.0.0.1".into(),
        port,
        username: USER.into(),
        auth,
        expected_fingerprint: expected,
    }
}

#[tokio::test]
async fn password_auth_shell_roundtrip() {
    let port = start_server().await;
    let (screen, fp) =
        run_shell(target(port, ClientAuth::Password(PASSWORD.into()), None), b"HELLO-42\r").await;
    assert!(screen.contains("SSH-READY"), "應收到 banner:\n{screen}");
    assert!(screen.contains("HELLO-42"), "應看到回聲:\n{screen}");
    assert!(
        fp.as_deref().unwrap_or("").starts_with("SHA256:"),
        "應取得 host key 指紋:{fp:?}"
    );
}

#[tokio::test]
async fn pubkey_auth_works() {
    let port = start_server().await;
    let (screen, _) = run_shell(
        target(
            port,
            ClientAuth::KeyData {
                pem: CLIENT_KEY.into(),
                passphrase: None,
            },
            None,
        ),
        b"KEYAUTH-OK\r",
    )
    .await;
    assert!(screen.contains("KEYAUTH-OK"), "pubkey 認證後回聲:\n{screen}");
}

/// app 內產生(帶 passphrase)的金鑰,原樣存、原樣拿來登入。
#[tokio::test]
async fn generated_key_authenticates() {
    let key = tterm_ssh::generate_key(tterm_ssh::KeyKind::Ed25519, "phone", Some("pw"))
        .expect("generate");
    let port = start_server().await;
    let (screen, _) = run_shell(
        target(
            port,
            ClientAuth::KeyData {
                pem: key.private_key,
                passphrase: Some("pw".into()),
            },
            None,
        ),
        b"GENKEY-OK\r",
    )
    .await;
    assert!(screen.contains("GENKEY-OK"), "產生的金鑰登入後回聲:\n{screen}");
}

#[tokio::test]
async fn wrong_password_rejected() {
    let port = start_server().await;
    let result = connect(&target(port, ClientAuth::Password("wrong".into()), None)).await;
    assert!(result.is_err(), "錯誤密碼應認證失敗");
}

#[tokio::test]
async fn host_key_pinning() {
    let port = start_server().await;
    // 首次連線(TOFU)取得指紋
    let (_, fp) =
        run_shell(target(port, ClientAuth::Password(PASSWORD.into()), None), b"\r").await;
    let fp = fp.expect("fingerprint");

    // 帶正確指紋 → 連得上
    let (screen, _) = run_shell(
        target(port, ClientAuth::Password(PASSWORD.into()), Some(fp.clone())),
        b"PINNED\r",
    )
    .await;
    assert!(screen.contains("PINNED"));

    // 帶錯誤指紋 → 拒絕(不靜默接受)
    let bad = "SHA256:0000000000000000000000000000000000000000000".to_string();
    let result =
        connect(&target(port, ClientAuth::Password(PASSWORD.into()), Some(bad))).await;
    assert!(result.is_err(), "host key 不符必須拒絕連線");
    // UI 靠型別認出這種錯誤(要講清楚可能遭中間人攻擊),不能只是一串字
    let err = result.err().unwrap();
    let mismatch = err.downcast_ref::<HostKeyMismatch>();
    assert!(mismatch.is_some(), "錯誤應是 HostKeyMismatch:{err:#}");
    assert_eq!(mismatch.unwrap().actual, fp, "應回報伺服器實際的指紋");
}
