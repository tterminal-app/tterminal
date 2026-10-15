//! 預設 shell:Windows 要開 PowerShell(不是 cmd.exe)。

#![cfg(windows)]

use std::time::{Duration, Instant};

use tterm_session::{default_shell, Session};

/// 等畫面出現任一 needle(或逾時)。needle 要挑「只會出現在輸出、不會出現在
/// 回顯指令」的字串,否則指令一送出就立刻命中。
fn wait_for_any(session: &Session, needles: &[&str], timeout: Duration) -> String {
    let deadline = Instant::now() + timeout;
    loop {
        let screen = session.visible_text().join("\n");
        if needles.iter().any(|n| screen.contains(n)) || Instant::now() >= deadline {
            return screen;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn windows_default_shell_is_powershell() {
    let prog = default_shell().expect("Windows 應該找得到 PowerShell");
    let lower = prog.to_lowercase();
    assert!(
        lower.ends_with("pwsh.exe") || lower.ends_with("powershell.exe"),
        "預設 shell 應為 PowerShell,實際是 {prog}"
    );
}

/// PowerShell 的 Set-Location 不動行程 PEB,所以讀子行程 cwd 的那條路對它
/// 無效;預設 shell 要靠 prompt hook 送 OSC 7,「跳至終端目前目錄」才會動。
#[test]
fn default_shell_reports_cwd_via_osc7() {
    let session = Session::spawn_shell(100, 30, 1000, None).expect("spawn default shell");
    // TEMP 可能是 8.3 短檔名(GitHub runner 上是 C:\Users\RUNNER~1\...),
    // PowerShell 回報的是完整路徑;canonicalize 展開成完整路徑再比
    let tmp_dir = std::env::temp_dir();
    let tmp = std::fs::canonicalize(&tmp_dir)
        .unwrap_or(tmp_dir)
        .to_string_lossy()
        .replace("\\\\?\\", "");
    let want = tmp.replace('\\', "/").trim_end_matches('/').to_lowercase();

    // 提示符一畫出來就該有第一筆 OSC 7
    let deadline = Instant::now() + Duration::from_secs(30);
    while session.current_directory().is_none() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(50));
    }
    assert!(
        session.current_directory().is_some(),
        "預設 shell 應在提示符送 OSC 7,畫面:\n{}",
        session.visible_text().join("\n")
    );

    session
        .write(format!("Set-Location \"{tmp}\"\r\n").as_bytes())
        .expect("write");
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        let cwd = session.current_directory().unwrap_or_default().to_lowercase();
        if cwd.trim_end_matches('/') == want || Instant::now() >= deadline {
            assert_eq!(
                cwd.trim_end_matches('/'),
                want,
                "Set-Location 之後 OSC 7 應回報新目錄"
            );
            break;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

#[test]
fn spawned_default_shell_runs_powershell() {
    let session = Session::spawn_shell(100, 30, 1000, None).expect("spawn default shell");
    assert!(session.is_alive());

    // 只有 PowerShell 展得開 $PSVersionTable;cmd.exe 會把整行原樣印出來。
    // 等的是展開後的值(PSED-Core / PSED-Desktop),不是回顯的指令本身。
    session
        .write(b"Write-Output \"PSED-$($PSVersionTable.PSEdition)\"\r\n")
        .expect("write");
    let screen = wait_for_any(
        &session,
        &["PSED-Core", "PSED-Desktop"],
        Duration::from_secs(30),
    );
    assert!(
        screen.contains("PSED-Core") || screen.contains("PSED-Desktop"),
        "預設 shell 不像 PowerShell,畫面:\n{screen}"
    );
}
