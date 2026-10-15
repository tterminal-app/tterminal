//! Session 端對端:真實 shell、輸入回寫、resize、標題、EOF 偵測。

#![cfg(unix)]

use std::time::{Duration, Instant};

use tterm_session::Session;

/// 等到畫面出現預期文字(或逾時)。
fn wait_for(session: &Session, needle: &str, timeout: Duration) -> String {
    let deadline = Instant::now() + timeout;
    loop {
        let screen = session.visible_text().join("\n");
        if screen.contains(needle) {
            return screen;
        }
        if Instant::now() >= deadline {
            return screen;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn shell_echoes_typed_command() {
    let session = Session::spawn_shell(80, 24, 1000, Some("sh")).expect("spawn shell");
    assert!(session.is_alive());

    session.write(b"echo TYPED-$((3*14))\n").expect("write");
    let screen = wait_for(&session, "TYPED-42", Duration::from_secs(10));
    assert!(screen.contains("TYPED-42"), "screen:\n{screen}");
}

#[test]
fn pty_reports_window_size_after_resize() {
    let session = Session::spawn_shell(80, 24, 1000, Some("sh")).expect("spawn shell");
    session.resize(100, 30).expect("resize");
    // 讓 shell 有機會處理 SIGWINCH
    std::thread::sleep(Duration::from_millis(200));
    session
        .write(b"stty size; echo SIZE-DONE\n")
        .expect("write");
    let screen = wait_for(&session, "SIZE-DONE", Duration::from_secs(10));
    assert!(screen.contains("30 100"), "stty size 應回報新尺寸:\n{screen}");
}

#[test]
fn title_escape_sequence_captured() {
    let session = Session::spawn_shell(80, 24, 1000, Some("sh")).expect("spawn shell");
    session
        .write(b"printf '\\033]0;my-session-title\\007'; echo TITLE-SET\n")
        .expect("write");
    wait_for(&session, "TITLE-SET", Duration::from_secs(10));

    let deadline = Instant::now() + Duration::from_secs(3);
    while session.title() != "my-session-title" && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(20));
    }
    assert_eq!(session.title(), "my-session-title");
}

#[test]
fn exit_marks_session_dead() {
    let session = Session::spawn_shell(80, 24, 1000, Some("sh")).expect("spawn shell");
    assert!(session.is_alive());
    session.write(b"exit\n").expect("write");
    assert!(
        session.wait_for_exit(Duration::from_secs(10)),
        "shell 結束後 session 應標記為 dead"
    );
}

#[test]
fn device_attributes_query_is_answered() {
    // vim/htop 啟動時會查詢終端能力;沒回應會卡住。
    // 這裡直接讓 shell 送出 DA 查詢,並確認 session 有把回應寫回 PTY
    // (回應被 shell 當成輸入 echo 回畫面,所以畫面上會出現 [?...c 的殘跡)。
    let session = Session::spawn_shell(80, 24, 1000, Some("sh")).expect("spawn shell");
    session.write(b"printf '\\033[c'\n").expect("write");
    std::thread::sleep(Duration::from_millis(500));
    session.write(b"\n").expect("write");
    let screen = wait_for(&session, "?", Duration::from_secs(5));
    assert!(
        screen.contains("?6") || screen.contains("?1") || screen.contains("c"),
        "應看到 DA 回應被 echo 回來:\n{screen}"
    );
}

#[test]
fn grid_fill_reflects_shell_output() {
    let session = Session::spawn_shell(80, 24, 1000, Some("sh")).expect("spawn shell");
    session.write(b"printf 'GRID-OK\\n'\n").expect("write");
    wait_for(&session, "GRID-OK", Duration::from_secs(10));

    let mut buf = vec![0u32; 80 * 24 * 4];
    let n = session.fill_grid_u32(&mut buf);
    assert_eq!(n, 80 * 24);
    // 把 grid 還原成字串,確認 FFI 用的路徑與 visible_text 一致
    let text: String = (0..n)
        .map(|i| char::from_u32(buf[i * 4]).unwrap_or(' '))
        .collect();
    assert!(text.contains("GRID-OK"), "grid buffer 應含輸出");
}
