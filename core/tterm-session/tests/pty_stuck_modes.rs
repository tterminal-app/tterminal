//! 前景 TUI 被強制中斷後,終端卡在 alt screen / 滑鼠回報模式 → 滾輪失效。
//! 這裡用真的 ConPTY 重現:PowerShell 印出那組序列(印完就沒有前景程式了,
//! 等同 TUI 被砍掉沒送復原序列),接著 recover_stuck_modes 要把它救回來。

#![cfg(windows)]

use std::time::{Duration, Instant};

use tterm_session::Session;
use tterm_term::modes;

fn wait_until(timeout: Duration, mut cond: impl FnMut() -> bool) -> bool {
    let deadline = Instant::now() + timeout;
    loop {
        if cond() {
            return true;
        }
        if Instant::now() >= deadline {
            return false;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

#[test]
fn recovers_modes_left_behind_by_a_killed_tui() {
    let session =
        Session::spawn_shell(80, 24, 1000, Some("powershell.exe")).expect("spawn powershell");

    // claude code 進全螢幕畫面時送的那組:1049(alt screen)+ 1000/1006(滑鼠回報)。
    // 印完 PowerShell 就回到提示字元,沒有任何後代行程——正是「TUI 死了、模式
    // 沒人收拾」的狀態。
    session
        .write(
            b"[Console]::Write(\"$([char]27)[?1049h$([char]27)[?1000h$([char]27)[?1006h\")\r\n",
        )
        .expect("write");

    let stuck = wait_until(Duration::from_secs(20), || {
        session.mode_bits() & modes::WHEEL_BLOCKING != 0
    });
    assert!(
        stuck,
        "ConPTY 應把這組序列轉發給引擎(實得 mode bits {:#x})",
        session.mode_bits()
    );

    // UI 每 ~0.5s 問一次;要連續兩次判定卡住才動手,所以這裡也照樣輪詢。
    let recovered = wait_until(Duration::from_secs(20), || {
        session.recover_stuck_modes();
        session.mode_bits() & modes::WHEEL_BLOCKING == 0
    });
    assert!(
        recovered,
        "前景沒有行程了就該自動復原(實得 mode bits {:#x})",
        session.mode_bits()
    );
}
