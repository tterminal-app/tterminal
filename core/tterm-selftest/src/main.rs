//! tterm-selftest:在目標機器上驗證 tterminal 核心。
//!
//! 這是一個獨立的 console 執行檔,不需要 Flutter、不需要安裝。
//! 主要用途是在 **Windows** 上驗證跨平台路徑(尤其 ConPTY 與 UTF-8 中文),
//! 因為那些是在 Linux 開發機上測不到的。
//!
//! 直接執行即可;`--no-pause` 可在 CI 中使用(不等待按鍵)。

use std::io::Write;
use std::time::{Duration, Instant};

use tterm_session::Session;
use tterm_term::{flags, TermEngine};

struct Report {
    passed: usize,
    failed: usize,
}

impl Report {
    fn check(&mut self, name: &str, result: Result<String, String>) {
        match result {
            Ok(detail) => {
                self.passed += 1;
                println!("  [PASS] {name}{}", fmt_detail(&detail));
            }
            Err(detail) => {
                self.failed += 1;
                println!("  [FAIL] {name}{}", fmt_detail(&detail));
            }
        }
        let _ = std::io::stdout().flush();
    }
}

fn fmt_detail(detail: &str) -> String {
    if detail.is_empty() {
        String::new()
    } else {
        format!("  —  {detail}")
    }
}

fn ok(detail: impl Into<String>) -> Result<String, String> {
    Ok(detail.into())
}

fn err(detail: impl Into<String>) -> Result<String, String> {
    Err(detail.into())
}

/// 等畫面出現預期文字。
fn wait_for(session: &Session, needle: &str, timeout: Duration) -> Result<String, String> {
    let deadline = Instant::now() + timeout;
    loop {
        let screen = session.visible_text().join("\n");
        if screen.contains(needle) {
            return Ok(screen);
        }
        if Instant::now() >= deadline {
            return Err(screen);
        }
        std::thread::sleep(Duration::from_millis(25));
    }
}

fn test_engine_basics(r: &mut Report) {
    let mut e = TermEngine::new(80, 24, 500);
    e.feed(b"hello\r\nworld");
    let screen = e.visible_text();
    r.check(
        "VT 解析與換行",
        if screen[0] == "hello" && screen[1] == "world" {
            ok("")
        } else {
            err(format!("got {:?}", &screen[..2]))
        },
    );

    let mut e = TermEngine::new(80, 24, 500);
    e.feed("你好世界 abc".as_bytes());
    let (_, col) = e.cursor_position();
    let snap = e.snapshot();
    let wide_ok = snap.cells[0].flags & flags::WIDE_CHAR != 0
        && snap.cells[1].flags & flags::WIDE_CHAR_SPACER != 0;
    // 4 個中文 = 8 格,空白 1 格,abc 3 格 → 游標應在 col 12
    r.check(
        "CJK 寬字元佔兩格",
        if col == 12 && wide_ok {
            ok(format!("游標在 col {col}"))
        } else {
            err(format!("col={col} wide_flags_ok={wide_ok}"))
        },
    );

    let mut e = TermEngine::new(80, 24, 500);
    e.feed(b"\x1b[1;38;2;12;34;56mX");
    let snap = e.snapshot();
    r.check(
        "truecolor 與粗體",
        if snap.cells[0].fg == (12, 34, 56) && snap.cells[0].flags & flags::BOLD != 0 {
            ok("")
        } else {
            err(format!("fg={:?} flags={}", snap.cells[0].fg, snap.cells[0].flags))
        },
    );

    let mut e = TermEngine::new(80, 24, 500);
    for i in 1..=100 {
        e.feed(format!("line-{i}\r\n").as_bytes());
    }
    e.scroll_display(50);
    let scrolled = e.visible_text().join("\n");
    e.scroll_to_bottom();
    let bottom = e.visible_text().join("\n");
    r.check(
        "scrollback 捲動",
        if scrolled.contains("line-50") && bottom.contains("line-100") {
            ok(format!("歷史 {} 行", e.history_lines()))
        } else {
            err("捲動後看到的內容不正確")
        },
    );
}

fn test_engine_throughput(r: &mut Report) {
    use tterm_term::demo::{self, DemoState};

    let mut engine = TermEngine::new(120, 40, 10_000);
    let mut state = DemoState::default();
    let data = demo::gen_chunk(demo::SCENARIO_COLORED, &mut state, 8 * 1024 * 1024, 120, 40);
    let start = Instant::now();
    for chunk in data.chunks(64 * 1024) {
        engine.feed(chunk);
        let _ = engine.drain_events();
        let _ = engine.take_damage();
    }
    let elapsed = start.elapsed();
    let mibs = (data.len() as f64 / (1024.0 * 1024.0)) / elapsed.as_secs_f64();

    let mut buf = vec![0u32; 120 * 40 * 4];
    let t = Instant::now();
    for _ in 0..100 {
        engine.fill_grid_u32(&mut buf);
    }
    let per_snapshot = t.elapsed().as_secs_f64() * 1000.0 / 100.0;

    r.check(
        "引擎吞吐量",
        if mibs > 10.0 {
            ok(format!(
                "{mibs:.0} MiB/s,grid 拷貝 {per_snapshot:.2} ms/frame"
            ))
        } else {
            err(format!("只有 {mibs:.1} MiB/s,異常偏低"))
        },
    );
}

fn test_pty(r: &mut Report) {
    let session = match Session::spawn_shell(80, 24, 1000, None) {
        Ok(s) => s,
        Err(e) => {
            r.check("開啟系統 shell", err(format!("{e:#}")));
            return;
        }
    };
    r.check(
        if cfg!(windows) {
            "開啟系統 shell(ConPTY)"
        } else {
            "開啟系統 shell(PTY)"
        },
        ok(""),
    );

    // Windows 的 cmd.exe 與 Unix shell 都吃這個
    let cmd = if cfg!(windows) {
        b"echo PTY-CHECK-42\r\n".to_vec()
    } else {
        b"echo PTY-CHECK-42\n".to_vec()
    };
    if let Err(e) = session.write(&cmd) {
        r.check("寫入 shell", err(format!("{e:#}")));
        return;
    }
    r.check(
        "shell 執行指令並回傳輸出",
        match wait_for(&session, "PTY-CHECK-42", Duration::from_secs(15)) {
            Ok(_) => ok(""),
            Err(screen) => err(format!("畫面上找不到預期輸出:\n{}", screen.trim_end())),
        },
    );

    // 中文:確認 UTF-8 在這個平台的 shell 上正確往返
    let cjk = if cfg!(windows) {
        "chcp 65001 > nul && echo 中文-OK\r\n".to_string()
    } else {
        "echo 中文-OK\n".to_string()
    };
    let _ = session.write(cjk.as_bytes());
    r.check(
        "中文 UTF-8 往返",
        match wait_for(&session, "中文-OK", Duration::from_secs(15)) {
            Ok(_) => ok(""),
            Err(screen) => err(format!(
                "Windows 舊版 console 可能需要 UTF-8 代碼頁;畫面:\n{}",
                screen.trim_end()
            )),
        },
    );

    r.check(
        "調整視窗尺寸",
        match session.resize(100, 30) {
            Ok(()) => ok("80x24 → 100x30"),
            Err(e) => err(format!("{e:#}")),
        },
    );
}

fn main() {
    println!("tterminal 核心自我測試");
    println!(
        "  平台:{} / {}  |  版本:{}",
        std::env::consts::OS,
        std::env::consts::ARCH,
        env!("CARGO_PKG_VERSION")
    );
    println!();

    let mut report = Report {
        passed: 0,
        failed: 0,
    };

    println!("終端引擎:");
    test_engine_basics(&mut report);
    test_engine_throughput(&mut report);
    println!();
    println!("PTY / shell:");
    test_pty(&mut report);
    println!();

    let total = report.passed + report.failed;
    if report.failed == 0 {
        println!("全部通過({}/{})", report.passed, total);
    } else {
        println!("失敗 {} 項(共 {} 項)", report.failed, total);
    }

    let pause = !std::env::args().any(|a| a == "--no-pause");
    if pause {
        println!();
        println!("按 Enter 結束…");
        let mut line = String::new();
        let _ = std::io::stdin().read_line(&mut line);
    }
    std::process::exit(if report.failed == 0 { 0 } else { 1 });
}
