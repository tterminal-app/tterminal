//! 真實 PTY 端對端測試:spawn shell → PTY 輸出 → TermEngine → 驗證畫面。

#![cfg(unix)]

use std::io::Read;
use std::sync::mpsc;
use std::time::{Duration, Instant};

use portable_pty::{native_pty_system, CommandBuilder, PtySize};
use tterm_term::TermEngine;

#[test]
fn pty_shell_roundtrip() {
    let pty = native_pty_system();
    let pair = pty
        .openpty(PtySize {
            rows: 24,
            cols: 80,
            pixel_width: 0,
            pixel_height: 0,
        })
        .expect("openpty");

    let mut cmd = CommandBuilder::new("sh");
    cmd.args([
        "-c",
        "printf 'PTY-SAYS-%s\\n' hello; printf '\\033[1;32mGREEN-WORD\\033[0m\\n'; printf '\\350\\265\\260 cjk-done\\n'",
    ]);
    cmd.env("TERM", "xterm-256color");

    let mut child = pair.slave.spawn_command(cmd).expect("spawn");
    drop(pair.slave);

    let mut reader = pair.master.try_clone_reader().expect("reader");
    let (tx, rx) = mpsc::channel::<Vec<u8>>();
    std::thread::spawn(move || {
        let mut buf = [0u8; 8192];
        loop {
            match reader.read(&mut buf) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    if tx.send(buf[..n].to_vec()).is_err() {
                        break;
                    }
                }
            }
        }
    });

    let mut engine = TermEngine::new(80, 24, 1000);
    let deadline = Instant::now() + Duration::from_secs(20);
    let mut exited_at: Option<Instant> = None;
    loop {
        match rx.recv_timeout(Duration::from_millis(100)) {
            Ok(chunk) => engine.feed(&chunk),
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
            Err(mpsc::RecvTimeoutError::Timeout) => {
                if let Some(t) = exited_at {
                    // 子行程結束後再等一小段收尾就收工
                    if t.elapsed() > Duration::from_millis(300) {
                        break;
                    }
                } else if let Ok(Some(_)) = child.try_wait() {
                    exited_at = Some(Instant::now());
                }
                assert!(Instant::now() < deadline, "PTY 測試逾時");
            }
        }
    }
    let _ = child.wait();

    let screen = engine.visible_text().join("\n");
    assert!(screen.contains("PTY-SAYS-hello"), "screen:\n{screen}");
    assert!(screen.contains("GREEN-WORD"), "screen:\n{screen}");
    assert!(screen.contains("走 cjk-done"), "screen:\n{screen}");
}
