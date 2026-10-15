//! 本地 shell cwd 偵測(不靠 OSC 7):Windows cmd.exe `cd` 後 local_cwd 要跟上。

#![cfg(windows)]

use std::time::{Duration, Instant};

use tterm_session::Session;

fn norm(s: &str) -> String {
    s.replace('\\', "/").trim_end_matches('/').to_lowercase()
}

/// 輪詢 local_cwd 直到含 needle(或逾時),回最後一次讀到的值。
fn wait_cwd(session: &Session, needle: &str, timeout: Duration) -> Option<String> {
    let deadline = Instant::now() + timeout;
    loop {
        let cwd = session.local_cwd();
        if let Some(ref c) = cwd {
            if norm(c).contains(&norm(needle)) {
                return cwd;
            }
        }
        if Instant::now() >= deadline {
            return cwd;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

#[test]
fn local_cwd_tracks_cd_in_cmd() {
    // spawn_shell 會把子 shell 的 cwd 設成本行程的 current_dir。
    let start = std::env::current_dir().expect("cwd");
    let session = Session::spawn_shell(80, 24, 1000, Some("cmd.exe")).expect("spawn cmd");

    // 一開始應讀得到起始目錄(cmd 剛起來,沒有更深的後代)。
    let initial = wait_cwd(&session, &start.to_string_lossy(), Duration::from_secs(10));
    assert_eq!(
        initial.as_deref().map(norm),
        Some(norm(&start.to_string_lossy())),
        "剛開 cmd 應讀到起始 cwd"
    );

    // cd 到暫存目錄後,local_cwd 要跟上。
    let tmp = std::env::temp_dir();
    let tmp_real = std::fs::canonicalize(&tmp).unwrap_or(tmp);
    let tmp_str = tmp_real.to_string_lossy().replace("\\\\?\\", "");
    session
        .write(format!("cd /d \"{tmp_str}\"\r\n").as_bytes())
        .expect("write cd");

    let after = wait_cwd(&session, &tmp_str, Duration::from_secs(10));
    assert_eq!(
        after.as_deref().map(norm),
        Some(norm(&tmp_str)),
        "cd 之後 local_cwd 應指向暫存目錄"
    );
}
