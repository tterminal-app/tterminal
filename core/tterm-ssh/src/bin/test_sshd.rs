//! test_sshd:給 Dart 端整合測試用的極簡 SSH server(非正式功能)。
//!
//! 綁 127.0.0.1:0,把實際埠印到 stdout(`PORT=<n>`),password auth
//! tester/secret-123。shell channel 送 banner 並回聲;SFTP subsystem 提供
//! 一棵固定的記憶體檔案樹(/home/tester)。

use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use std::time::Duration;

use russh::server::{Auth, ChannelOpenHandle, Handler, Msg, Session};
use russh::{Channel, ChannelId, ChannelMsg};
use russh_sftp::protocol::{
    Attrs, Data, File, FileAttributes, Handle as SftpHandle, Name, Status, StatusCode,
};
use tokio::net::TcpListener;

const HOST_KEY: &str = "-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACAePoPUeGy1BYPUnU85k7BxEAFnLE22roHAmqT6Kr4nFQAAAJjx5SxT8eUs
UwAAAAtzc2gtZWQyNTUxOQAAACAePoPUeGy1BYPUnU85k7BxEAFnLE22roHAmqT6Kr4nFQ
AAAEC+aPxLIOpZaxHv96OGN9KaCoTDSRdmzLUOCfDDNmjm/x4+g9R4bLUFg9SdTzmTsHEQ
AWcsTbaugcCapPoqvicVAAAAD3R0ZXJtLXRlc3QtaG9zdAECAwQFBg==
-----END OPENSSH PRIVATE KEY-----";

const USER: &str = "tester";
const PASSWORD: &str = "secret-123";
const SFTP_HOME: &str = "/home/tester";

/// 路徑 → [(名稱, 是否目錄, 內容)]
type SftpTree = HashMap<&'static str, Vec<(&'static str, bool, &'static [u8])>>;

fn sftp_tree() -> SftpTree {
    let mut m = HashMap::new();
    m.insert(
        "/home/tester",
        vec![
            ("readme.txt", false, &b"hello from sftp\n"[..]),
            ("logs", true, &b""[..]),
            ("config.toml", false, &b"key = 42\n"[..]),
        ],
    );
    m.insert("/home/tester/logs", vec![("app.log", false, &b"log line\n"[..])]);
    m
}

fn sftp_file(path: &str) -> Option<&'static [u8]> {
    match path {
        "/home/tester/readme.txt" => Some(b"hello from sftp\n"),
        "/home/tester/config.toml" => Some(b"key = 42\n"),
        "/home/tester/logs/app.log" => Some(b"log line\n"),
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
struct SftpHandler {
    handles: HashMap<String, String>,
    next: u64,
    dir_read: HashSet<String>,
}

impl SftpHandler {
    fn new_handle(&mut self, path: String, prefix: &str) -> String {
        self.next += 1;
        let h = format!("{prefix}{}", self.next);
        self.handles.insert(h.clone(), path);
        h
    }
}

impl russh_sftp::server::Handler for SftpHandler {
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
        let entries = sftp_tree().get(path.as_str()).cloned().ok_or(StatusCode::NoSuchFile)?;
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
        _pflags: russh_sftp::protocol::OpenFlags,
        _attrs: FileAttributes,
    ) -> Result<SftpHandle, StatusCode> {
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
        let content = sftp_file(&path).ok_or(StatusCode::NoSuchFile)?;
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
        _handle: String,
        _offset: u64,
        _data: Vec<u8>,
    ) -> Result<Status, StatusCode> {
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
        } else if let Some(c) = sftp_file(&path) {
            attrs.set_regular(true);
            attrs.size = Some(c.len() as u64);
        } else {
            return Err(StatusCode::NoSuchFile);
        }
        Ok(Attrs { id, attrs })
    }
}

#[derive(Default)]
struct H {
    channels: HashMap<ChannelId, Channel<Msg>>,
}

impl Handler for H {
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

    async fn shell_request(
        &mut self,
        channel_id: ChannelId,
        _session: &mut Session,
    ) -> Result<(), Self::Error> {
        // 自己驅動 channel:送 banner、回聲收到的資料
        if let Some(mut channel) = self.channels.remove(&channel_id) {
            tokio::spawn(async move {
                // 開啟滑鼠回報(1002 button-event + 1006 SGR),模擬 tmux mouse on
                let banner = b"\x1b[?1002h\x1b[?1006hTEST-SSHD-READY>";
                let _ = channel.data(&banner[..]).await;
                while let Some(msg) = channel.wait().await {
                    if let ChannelMsg::Data { data } = msg {
                        // 控制字元轉成可見的 <xx>,好讓測試看得到送進來的
                        // escape(例如滑鼠回報序列);可列印字元原樣回聲。
                        let mut out = Vec::new();
                        for &b in data.iter() {
                            if (0x20..=0x7e).contains(&b) {
                                out.push(b);
                            } else {
                                out.extend_from_slice(format!("<{b:02x}>").as_bytes());
                            }
                        }
                        if channel.data(&out[..]).await.is_err() {
                            break;
                        }
                    }
                }
            });
        }
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
                russh_sftp::server::run(channel.into_stream(), SftpHandler::default()).await;
            }
        }
        Ok(())
    }
}

#[tokio::main]
async fn main() {
    let key = russh::keys::decode_secret_key(HOST_KEY, None).expect("host key");
    let config = Arc::new(russh::server::Config {
        auth_rejection_time: Duration::from_millis(1),
        keys: vec![key],
        ..Default::default()
    });

    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let port = listener.local_addr().unwrap().port();
    println!("PORT={port}");
    use std::io::Write;
    let _ = std::io::stdout().flush();

    loop {
        let Ok((stream, _)) = listener.accept().await else {
            break;
        };
        let config = config.clone();
        tokio::spawn(async move {
            if let Ok(s) = russh::server::run_stream(config, stream, H::default()).await {
                let _ = s.await;
            }
        });
    }
}
