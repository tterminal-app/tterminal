//! SSH 走完整 C ABI 的端對端測試:tterm_session_connect_ssh → write → copy_grid。
//!
//! server 在獨立執行緒的 tokio runtime 上運作;測試主執行緒呼叫「同步」FFI
//! (connect_ssh 內部自建 runtime block_on),兩者 runtime 不巢套。

use std::ffi::{c_void, CString};
use std::sync::Arc;
use std::time::Duration;

use russh::server::{Auth, ChannelOpenHandle, Handler, Msg, Session as SrvSession};
use russh::{Channel, ChannelId};
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

struct H;

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
        _channel: Channel<Msg>,
        reply: ChannelOpenHandle,
        _session: &mut SrvSession,
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
        _session: &mut SrvSession,
    ) -> Result<(), Self::Error> {
        Ok(())
    }

    async fn shell_request(
        &mut self,
        channel: ChannelId,
        session: &mut SrvSession,
    ) -> Result<(), Self::Error> {
        session.data(channel, b"READY>".to_vec())?;
        Ok(())
    }

    async fn data(
        &mut self,
        channel: ChannelId,
        data: &[u8],
        session: &mut SrvSession,
    ) -> Result<(), Self::Error> {
        session.data(channel, data.to_vec())?;
        Ok(())
    }

    async fn exec_request(
        &mut self,
        channel: ChannelId,
        data: &[u8],
        session: &mut SrvSession,
    ) -> Result<(), Self::Error> {
        session.channel_success(channel)?;
        if data == b"hang" {
            // 永不回應也不關閉:模擬慢到讓 client 逾時的 server
            return Ok(());
        }
        session.data(channel, b"OK".to_vec())?;
        session.exit_status_request(channel, 0)?;
        session.eof(channel)?;
        session.close(channel)?;
        Ok(())
    }
}

/// 在專屬執行緒啟動 server,回傳埠。runtime 隨執行緒常駐至 process 結束。
fn start_server() -> u16 {
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let rt = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .unwrap();
        rt.block_on(async move {
            let key = russh::keys::decode_secret_key(HOST_KEY, None).unwrap();
            let config = Arc::new(russh::server::Config {
                auth_rejection_time: Duration::from_millis(1),
                keys: vec![key],
                ..Default::default()
            });
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            tx.send(listener.local_addr().unwrap().port()).unwrap();
            loop {
                let Ok((stream, _)) = listener.accept().await else {
                    break;
                };
                let config = config.clone();
                tokio::spawn(async move {
                    if let Ok(s) = russh::server::run_stream(config, stream, H).await {
                        let _ = s.await;
                    }
                });
            }
        });
    });
    rx.recv().unwrap()
}

// 直接透過 crate path 呼叫真正的 C ABI export(保證連結)
use tterm_ffi::{
    tterm_last_error, tterm_session_connect_ssh, tterm_session_copy_grid, tterm_session_free,
    tterm_session_ssh_exec, tterm_session_ssh_fingerprint, tterm_session_take_clipboard,
    tterm_session_write,
};

fn last_error() -> String {
    let mut buf = vec![0u8; 4096];
    let n = unsafe { tterm_last_error(buf.as_mut_ptr(), buf.len()) };
    String::from_utf8_lossy(&buf[..n]).to_string()
}

/// last_error 是錯誤 JSON(`{"error", "code"?, "args"?}`,見 src/error.rs)。
fn last_error_json() -> serde_json::Value {
    serde_json::from_str(&last_error()).expect("last_error 應是 JSON")
}

fn grid_text(handle: *mut c_void, cols: usize, rows: usize) -> String {
    let mut buf = vec![0u32; cols * rows * 4];
    unsafe { tterm_session_copy_grid(handle, buf.as_mut_ptr(), cols * rows) };
    let mut out = String::new();
    for row in 0..rows {
        for col in 0..cols {
            let cp = buf[(row * cols + col) * 4];
            out.push(if cp == 0 { ' ' } else { char::from_u32(cp).unwrap_or(' ') });
        }
        out.push('\n');
    }
    out
}

#[test]
fn connect_ssh_via_ffi_and_echo() {
    let port = start_server();
    let cols = 80;
    let rows = 24;
    let config = format!(
        r#"{{"host":"127.0.0.1","port":{port},"username":"{USER}","cols":{cols},"rows":{rows},
            "auth":{{"method":"password","password":"{PASSWORD}"}}}}"#
    );
    let config_c = CString::new(config).unwrap();
    let handle = unsafe { tterm_session_connect_ssh(config_c.as_ptr()) };
    assert!(!handle.is_null(), "SSH 連線應成功;last_error={}", last_error());

    // host key 指紋應可取得
    let mut fp = vec![0u8; 128];
    let n = unsafe { tterm_session_ssh_fingerprint(handle, fp.as_mut_ptr(), fp.len()) };
    let fp = String::from_utf8_lossy(&fp[..n]).to_string();
    assert!(fp.starts_with("SHA256:"), "應取得指紋:{fp}");

    // 送資料 → server 回聲 → 引擎畫面應出現
    let msg = b"FFI-ECHO-77\r";
    assert_eq!(unsafe { tterm_session_write(handle, msg.as_ptr(), msg.len()) }, 0);
    std::thread::sleep(Duration::from_millis(600));
    let screen = grid_text(handle, cols, rows);
    assert!(screen.contains("READY>"), "應收到 shell banner:\n{screen}");
    assert!(screen.contains("FFI-ECHO-77"), "應看到回聲:\n{screen}");

    tterm_session_free(handle);
}

#[test]
fn exec_timeout_does_not_kill_connection() {
    let port = start_server();
    let cols = 80;
    let rows = 24;
    let config = format!(
        r#"{{"host":"127.0.0.1","port":{port},"username":"{USER}","cols":{cols},"rows":{rows},
            "auth":{{"method":"password","password":"{PASSWORD}"}}}}"#
    );
    let config_c = CString::new(config).unwrap();
    let handle = unsafe { tterm_session_connect_ssh(config_c.as_ptr()) };
    assert!(!handle.is_null(), "SSH 連線應成功;last_error={}", last_error());

    // server 不回應的 exec → 逾時錯誤(而不是卡死)
    let mut out = vec![0u8; 256];
    let hang = CString::new("hang").unwrap();
    let n = unsafe {
        tterm_session_ssh_exec(handle, hang.as_ptr(), std::ptr::null(), 0, 400, out.as_mut_ptr(), out.len())
    };
    assert_eq!(n, usize::MAX, "應回逾時錯誤");
    let err = last_error_json();
    assert_eq!(err["code"], "timeout", "錯誤應是逾時:{err}");
    assert_eq!(err["args"]["op"], "exec", "{err}");

    // 關鍵:逾時「放棄等待」不能弄壞連線——互動 shell 還要能用
    let msg = b"ALIVE-AFTER-TIMEOUT\r";
    assert_eq!(unsafe { tterm_session_write(handle, msg.as_ptr(), msg.len()) }, 0);
    std::thread::sleep(Duration::from_millis(600));
    let screen = grid_text(handle, cols, rows);
    assert!(
        screen.contains("ALIVE-AFTER-TIMEOUT"),
        "exec 逾時後連線應仍可用:\n{screen}"
    );

    // 之後的 exec 也要正常(新 channel 開得起來)
    let ok = CString::new("whatever").unwrap();
    let n2 = unsafe {
        tterm_session_ssh_exec(handle, ok.as_ptr(), std::ptr::null(), 0, 3000, out.as_mut_ptr(), out.len())
    };
    assert_eq!(&out[..n2], b"OK", "逾時後新的 exec 應正常");

    tterm_session_free(handle);
}

#[test]
fn osc52_clipboard_via_ffi() {
    let port = start_server();
    let config = format!(
        r#"{{"host":"127.0.0.1","port":{port},"username":"{USER}",
            "auth":{{"method":"password","password":"{PASSWORD}"}}}}"#
    );
    let config_c = CString::new(config).unwrap();
    let handle = unsafe { tterm_session_connect_ssh(config_c.as_ptr()) };
    assert!(!handle.is_null(), "SSH 連線應成功;last_error={}", last_error());

    // tmux/vim 反白複製會送 OSC 52;server 回聲 → 引擎解析 → take_clipboard
    // base64("hi") = aGk=
    let msg = b"\x1b]52;c;aGk=\x07";
    assert_eq!(unsafe { tterm_session_write(handle, msg.as_ptr(), msg.len()) }, 0);

    let mut buf = vec![0u8; 256];
    let mut got = 0usize;
    for _ in 0..30 {
        std::thread::sleep(Duration::from_millis(100));
        got = unsafe { tterm_session_take_clipboard(handle, buf.as_mut_ptr(), buf.len()) };
        if got > 0 {
            break;
        }
    }
    assert_eq!(&buf[..got], b"hi", "OSC 52 內容應進 clipboard");
    // 取走後再查 → 沒有新內容
    assert_eq!(
        unsafe { tterm_session_take_clipboard(handle, buf.as_mut_ptr(), buf.len()) },
        0
    );

    tterm_session_free(handle);
}

#[test]
fn connect_ssh_wrong_password_errors() {
    let port = start_server();
    let config = format!(
        r#"{{"host":"127.0.0.1","port":{port},"username":"{USER}",
            "auth":{{"method":"password","password":"nope"}}}}"#
    );
    let config_c = CString::new(config).unwrap();
    let handle = unsafe { tterm_session_connect_ssh(config_c.as_ptr()) };
    assert!(handle.is_null(), "錯誤密碼應回 null handle");
    assert!(!last_error().is_empty(), "應設定錯誤訊息");
}

#[test]
fn connect_ssh_host_key_mismatch_rejected() {
    let port = start_server();
    let config = format!(
        r#"{{"host":"127.0.0.1","port":{port},"username":"{USER}",
            "auth":{{"method":"password","password":"{PASSWORD}"}},
            "knownFingerprint":"SHA256:definitely-not-the-real-one"}}"#
    );
    let config_c = CString::new(config).unwrap();
    let handle = unsafe { tterm_session_connect_ssh(config_c.as_ptr()) };
    assert!(handle.is_null(), "host key 不符應拒絕");
    let err = last_error_json();
    assert_eq!(err["code"], "host_key_mismatch", "UI 要認得出來:{err}");
    assert_eq!(err["args"]["expected"], "SHA256:definitely-not-the-real-one");
    assert!(err["args"]["actual"].as_str().unwrap().starts_with("SHA256:"), "{err}");
    assert!(err["error"].as_str().unwrap().contains("host key"), "{err}");
}

/// 錯誤畫面「改用新指紋」存的是 args.actual:它必須是伺服器真正出示的那把
/// (= ssh-keygen -lf 看到的),改用之後就連得上。
#[test]
fn host_key_mismatch_actual_is_pinnable() {
    let port = start_server();
    let connect = |known: &str| {
        let config = format!(
            r#"{{"host":"127.0.0.1","port":{port},"username":"{USER}",
                "auth":{{"method":"password","password":"{PASSWORD}"}},
                "knownFingerprint":"{known}"}}"#
        );
        let config_c = CString::new(config).unwrap();
        unsafe { tterm_session_connect_ssh(config_c.as_ptr()) }
    };

    assert!(connect("SHA256:the-old-host-key").is_null());
    let err = last_error_json();
    let actual = err["args"]["actual"].as_str().unwrap().to_string();
    assert_eq!(actual, "SHA256:C2e8ILs2vZ7SvQxsU2QSoLr5dsCxeRgdbkWmO+LITpE");

    let handle = connect(&actual);
    assert!(!handle.is_null(), "改用新指紋後應連得上:{}", last_error_json());
    tterm_session_free(handle);
}

/// 金鑰列表要算公鑰:JSON 通道 + 「回傳完整長度、buffer 不夠就加大重呼叫」。
#[test]
fn ssh_public_key_via_ffi() {
    let pem = CString::new(HOST_KEY).unwrap();

    // 先給 0 cap 問長度(冪等讀取),再照長度取回。
    let need = unsafe {
        tterm_ffi::tterm_ssh_public_key(pem.as_ptr(), std::ptr::null(), std::ptr::null_mut(), 0)
    };
    assert!(need > 0, "應回報所需長度");
    let mut buf = vec![0u8; need];
    let n = unsafe {
        tterm_ffi::tterm_ssh_public_key(pem.as_ptr(), std::ptr::null(), buf.as_mut_ptr(), need)
    };
    assert_eq!(n, need);

    let v: serde_json::Value = serde_json::from_slice(&buf[..n]).expect("JSON");
    assert_eq!(
        v["publicKey"].as_str().unwrap(),
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB4+g9R4bLUFg9SdTzmTsHEQAWcsTbaugcCapPoqvicV \
         tterm-test-host"
    );
    assert_eq!(v["algorithm"].as_str().unwrap(), "ssh-ed25519");
    assert!(v["fingerprint"].as_str().unwrap().starts_with("SHA256:"));
}

#[test]
fn ssh_public_key_bad_pem_reports_error_json() {
    let pem = CString::new("這不是私鑰").unwrap();
    let mut buf = vec![0u8; 4096];
    let n = unsafe {
        tterm_ffi::tterm_ssh_public_key(
            pem.as_ptr(),
            std::ptr::null(),
            buf.as_mut_ptr(),
            buf.len(),
        )
    };
    let v: serde_json::Value = serde_json::from_slice(&buf[..n]).expect("JSON");
    assert!(v["error"].as_str().is_some(), "失敗應走 error 欄位:{v}");
    assert_eq!(v["code"], "private_key_unreadable", "{v}");
    assert!(v["args"]["reason"].as_str().is_some(), "{v}");
}

fn generate_key(kind: &str, comment: &str, passphrase: Option<&str>) -> serde_json::Value {
    let kind = CString::new(kind).unwrap();
    let comment = CString::new(comment).unwrap();
    let pass = passphrase.map(|p| CString::new(p).unwrap());
    // 非冪等:一次給足協定上限,不准「不夠再重呼叫」
    let mut buf = vec![0u8; tterm_ffi::SSH_GENERATE_KEY_MAX];
    let n = unsafe {
        tterm_ffi::tterm_ssh_generate_key(
            kind.as_ptr(),
            comment.as_ptr(),
            pass.as_ref().map_or(std::ptr::null(), |p| p.as_ptr()),
            buf.as_mut_ptr(),
            buf.len(),
        )
    };
    assert!(n <= buf.len(), "回傳超出協定上限:{n}");
    serde_json::from_slice(&buf[..n]).expect("JSON")
}

/// 產生的私鑰丟回 tterm_ssh_public_key(金鑰列表那條路)要算出同一把公鑰。
#[test]
fn ssh_generate_key_via_ffi() {
    let v = generate_key("ed25519", "phone", Some("pw"));
    assert!(v["error"].is_null(), "{v}");
    let private = v["privateKey"].as_str().unwrap();
    assert!(private.starts_with("-----BEGIN OPENSSH PRIVATE KEY-----"));
    assert_eq!(v["algorithm"], "ssh-ed25519");
    assert_eq!(v["comment"], "phone");
    let public = v["publicKey"].as_str().unwrap();
    assert!(public.starts_with("ssh-ed25519 ") && public.ends_with(" phone"), "{public}");

    let pem = CString::new(private).unwrap();
    let pass = CString::new("pw").unwrap();
    let mut buf = vec![0u8; 4096];
    let n = unsafe {
        tterm_ffi::tterm_ssh_public_key(pem.as_ptr(), pass.as_ptr(), buf.as_mut_ptr(), buf.len())
    };
    let derived: serde_json::Value = serde_json::from_slice(&buf[..n]).expect("JSON");
    assert_eq!(derived["publicKey"], v["publicKey"]);
    assert_eq!(derived["fingerprint"], v["fingerprint"]);

    // 有 passphrase → 私鑰是加密的,沒 passphrase 解不開
    assert!(russh::keys::decode_secret_key(private, None).is_err());
    assert!(russh::keys::decode_secret_key(private, Some("pw")).is_ok());
}

/// RSA 4096 加密私鑰是最大的產物,也要落在協定上限內。
#[test]
fn ssh_generate_rsa_key_fits_protocol_cap() {
    let v = generate_key("rsa", "a-fairly-long-comment@some-host.example.com", Some("pw"));
    assert_eq!(v["algorithm"], "ssh-rsa", "{v}");
    assert!(v.to_string().len() < tterm_ffi::SSH_GENERATE_KEY_MAX / 2);
}

#[test]
fn ssh_generate_key_rejects_unknown_type() {
    let v = generate_key("dsa", "", None);
    assert!(v["error"].as_str().unwrap().contains("dsa"), "{v}");
}
