//! TermEngine 行為測試:VT 解析、寬字元、色彩、捲動、damage、事件。

use tterm_term::{flags, ClipboardKind, Damage, EngineEvent, TermEngine};

fn text(engine: &TermEngine) -> Vec<String> {
    engine.visible_text()
}

#[test]
fn plain_lines() {
    let mut e = TermEngine::new(40, 10, 100);
    e.feed(b"hello\r\nworld");
    let t = text(&e);
    assert_eq!(t[0], "hello");
    assert_eq!(t[1], "world");
}

#[test]
fn osc7_current_directory() {
    let mut e = TermEngine::new(40, 10, 100);
    assert_eq!(e.current_directory(), None);

    // BEL 終止,Windows 風格 file URI(drive 前有斜線)
    e.feed(b"\x1b]7;file://host/C:/Users/alice\x07prompt$ ");
    assert_eq!(e.current_directory(), Some("C:/Users/alice"));

    // ST(ESC \)終止 + percent-encoding(%20 = 空白)
    e.feed(b"\x1b]7;file://host/C:/My%20Docs\x1b\\");
    assert_eq!(e.current_directory(), Some("C:/My Docs"));

    // Unix 風格路徑
    e.feed(b"\x1b]7;file://localhost/home/alice/proj\x07");
    assert_eq!(e.current_directory(), Some("/home/alice/proj"));
}

#[test]
fn mouse_mode_bits() {
    use tterm_term::modes;
    let mut e = TermEngine::new(40, 10, 100);
    assert_eq!(e.mode_bits() & modes::MOUSE_DRAG, 0);

    // tmux mouse on 常送:1002(button-event 協定)+ 1006(SGR 編碼)——可並存
    e.feed(b"\x1b[?1002h\x1b[?1006h");
    assert_ne!(e.mode_bits() & modes::MOUSE_DRAG, 0, "1002 應設 MOUSE_DRAG");
    assert_ne!(e.mode_bits() & modes::SGR_MOUSE, 0, "1006 應設 SGR_MOUSE");

    // 滑鼠「協定」互斥:1000 會取代 1002(但 SGR 編碼保留)
    e.feed(b"\x1b[?1000h");
    assert_ne!(e.mode_bits() & modes::MOUSE_REPORT_CLICK, 0);
    assert_eq!(e.mode_bits() & modes::MOUSE_DRAG, 0, "1000 取代 1002");
    assert_ne!(e.mode_bits() & modes::SGR_MOUSE, 0);

    // 1003(any-motion)取代 1000
    e.feed(b"\x1b[?1003h");
    assert_ne!(e.mode_bits() & modes::MOUSE_MOTION, 0);
    assert_eq!(e.mode_bits() & modes::MOUSE_REPORT_CLICK, 0);

    // 關閉
    e.feed(b"\x1b[?1003l\x1b[?1006l");
    assert_eq!(e.mode_bits() & modes::MOUSE_MOTION, 0);
    assert_eq!(e.mode_bits() & modes::SGR_MOUSE, 0);
}

/// TUI 被強制中斷(Ctrl+C / kill)不會送復原序列,終端就卡在 alt screen +
/// 滑鼠回報 → 滾輪完全失效。reset_input_modes 要把這些狀態全部收回來,
/// 而且原本主畫面的內容(scrollback)要還在。
#[test]
fn reset_input_modes_clears_wheel_blocking_state() {
    use tterm_term::modes;
    let mut e = TermEngine::new(40, 10, 100);
    e.feed(b"before\r\n");

    // claude code 進全螢幕畫面時送的那組(1049 alt screen + 1000/1006 滑鼠回報)
    e.feed(b"\x1b[?1049h\x1b[?1000h\x1b[?1006h\x1b[?25lTUI");
    assert_ne!(e.mode_bits() & modes::ALT_SCREEN, 0);
    assert_ne!(e.mode_bits() & modes::WHEEL_BLOCKING, 0);

    e.reset_input_modes();
    assert_eq!(
        e.mode_bits() & modes::WHEEL_BLOCKING,
        0,
        "alt screen 與滑鼠回報都要關掉,滾輪才會回到 scrollback"
    );
    assert_ne!(e.mode_bits() & modes::SHOW_CURSOR, 0, "游標要重新顯示");
    assert!(
        e.visible_text().iter().any(|l| l.contains("before")),
        "回到主畫面後原本的內容要還在,實得:{:?}",
        e.visible_text()
    );
}

#[test]
fn osc7_split_across_feeds() {
    let mut e = TermEngine::new(40, 10, 100);
    // OSC 序列被切成兩段(PTY reader 常見)
    e.feed(b"\x1b]7;file://host/C:/spl");
    e.feed(b"it/here\x07");
    assert_eq!(e.current_directory(), Some("C:/split/here"));
}

#[test]
fn line_wrap() {
    let mut e = TermEngine::new(10, 5, 100);
    e.feed(b"aaaaaaaaaabbbbb"); // 15 chars → wrap 到第二行
    let t = text(&e);
    assert_eq!(t[0], "aaaaaaaaaa");
    assert_eq!(t[1], "bbbbb");
}

#[test]
fn cursor_absolute_move() {
    let mut e = TermEngine::new(40, 10, 100);
    e.feed(b"\x1b[3;5HX");
    let t = text(&e);
    assert_eq!(t[2], "    X");
    let (row, col) = e.cursor_position();
    assert_eq!(row, 2);
    assert_eq!(col, 5);
}

#[test]
fn cjk_wide_chars() {
    let mut e = TermEngine::new(20, 5, 100);
    e.feed("你好ab".as_bytes());
    let t = text(&e);
    assert_eq!(t[0], "你好ab");
    // 寬字元各佔 2 cells:cursor 應在 col 6
    let (_, col) = e.cursor_position();
    assert_eq!(col, 6);
    // snapshot 裡 spacer 格帶 WIDE_CHAR_SPACER flag
    let snap = e.snapshot();
    assert_ne!(snap.cells[0].flags & flags::WIDE_CHAR, 0);
    assert_ne!(snap.cells[1].flags & flags::WIDE_CHAR_SPACER, 0);
    assert_eq!(snap.cells[4].ch, 'a');
}

#[test]
fn sgr_named_color() {
    let mut e = TermEngine::new(20, 5, 100);
    e.feed(b"\x1b[31mR\x1b[0mN");
    let snap = e.snapshot();
    assert_eq!(snap.cells[0].fg, tterm_term::default_color(1)); // red
    assert_eq!(snap.cells[1].fg, tterm_term::default_color(256)); // 預設前景
}

#[test]
fn sgr_truecolor_and_bold() {
    let mut e = TermEngine::new(20, 5, 100);
    e.feed(b"\x1b[1;38;2;12;34;56mT");
    let snap = e.snapshot();
    assert_eq!(snap.cells[0].fg, (12, 34, 56));
    assert_ne!(snap.cells[0].flags & flags::BOLD, 0);
}

#[test]
fn sgr_indexed_color() {
    let mut e = TermEngine::new(20, 5, 100);
    e.feed(b"\x1b[38;5;196mX");
    let snap = e.snapshot();
    assert_eq!(snap.cells[0].fg, tterm_term::default_color(196));
}

#[test]
fn scrollback_and_scroll_display() {
    let mut e = TermEngine::new(20, 5, 100);
    for i in 1..=20 {
        e.feed(format!("line-{i:02}\r\n").as_bytes());
    }
    // 底部 viewport:應看得到 line-20(最後一行後仍有一次換行,行 0..4 = 16..20 之後)
    let joined = text(&e).join("\n");
    assert!(joined.contains("line-20"), "bottom view: {joined}");
    assert!(!joined.contains("line-10"));
    assert!(e.history_lines() > 0);

    e.scroll_display(10);
    let joined = text(&e).join("\n");
    assert!(joined.contains("line-10"), "scrolled view: {joined}");
    assert!(!joined.contains("line-20"));
    assert!(e.display_offset() >= 10);

    e.scroll_display(-100);
    assert_eq!(e.display_offset(), 0);
}

#[test]
fn alt_screen_roundtrip() {
    let mut e = TermEngine::new(20, 5, 100);
    e.feed(b"base\r\n");
    e.feed(b"\x1b[?1049h\x1b[HALT-SCREEN");
    let joined = text(&e).join("\n");
    assert!(joined.contains("ALT-SCREEN"));
    assert!(!joined.contains("base"));
    e.feed(b"\x1b[?1049l");
    let joined = text(&e).join("\n");
    assert!(joined.contains("base"));
    assert!(!joined.contains("ALT-SCREEN"));
}

#[test]
fn damage_reported_after_feed() {
    let mut e = TermEngine::new(40, 10, 100);
    let _ = e.take_damage(); // 清掉初始 full damage
    e.feed(b"x");
    match e.take_damage() {
        Damage::Full => {}
        Damage::Lines(lines) => assert!(!lines.is_empty(), "feed 後應有 damage"),
    }
}

#[test]
fn resize_reflow_no_panic() {
    let mut e = TermEngine::new(40, 10, 100);
    e.feed(b"some content that is fairly long and will reflow when resized\r\nrow2");
    e.resize(20, 6);
    e.resize(80, 30);
    e.feed(b"after resize");
    assert!(text(&e).join("\n").contains("after resize"));
}

#[test]
fn title_event() {
    let mut e = TermEngine::new(40, 10, 100);
    e.feed(b"\x1b]0;my-title\x07");
    let evs = e.drain_events();
    assert!(
        evs.contains(&EngineEvent::Title("my-title".to_string())),
        "events: {evs:?}"
    );
}

#[test]
fn bell_event() {
    let mut e = TermEngine::new(40, 10, 100);
    e.feed(b"\x07");
    assert!(e.drain_events().contains(&EngineEvent::Bell));
}

#[test]
fn primary_da_response() {
    let mut e = TermEngine::new(40, 10, 100);
    e.feed(b"\x1b[c"); // Primary Device Attributes 查詢
    let evs = e.drain_events();
    let pty_writes: Vec<&Vec<u8>> = evs
        .iter()
        .filter_map(|ev| match ev {
            EngineEvent::PtyWrite(b) => Some(b),
            _ => None,
        })
        .collect();
    assert!(
        pty_writes
            .iter()
            .any(|b| b.starts_with(b"\x1b[?") && b.ends_with(b"c")),
        "應回應 DA:{evs:?}"
    );
}

#[test]
fn osc52_clipboard_store() {
    let mut e = TermEngine::new(40, 10, 100);
    // OSC 52:base64("hi") = aGk=
    e.feed(b"\x1b]52;c;aGk=\x07");
    let evs = e.drain_events();
    assert!(
        evs.iter().any(|ev| matches!(
            ev,
            EngineEvent::ClipboardStore(ClipboardKind::Clipboard, s) if s == "hi"
        )),
        "events: {evs:?}"
    );
}

#[test]
fn zero_width_joiner_preserved() {
    let mut e = TermEngine::new(20, 5, 100);
    // é 以組合字元表示:e + U+0301
    e.feed("e\u{0301}x".as_bytes());
    let t = text(&e);
    assert!(t[0].starts_with("e\u{0301}"), "got: {:?}", t[0]);
}

#[test]
fn flag_bits_locked_for_dart_ffi() {
    // app/lib/src/term_ffi.dart 的 CellFlags 常數與此對齊;此測試防止兩邊漂移。
    assert_eq!(flags::INVERSE, 1 << 0);
    assert_eq!(flags::BOLD, 1 << 1);
    assert_eq!(flags::ITALIC, 1 << 2);
    assert_eq!(flags::UNDERLINE, 1 << 3);
    assert_eq!(flags::WRAPLINE, 1 << 4);
    assert_eq!(flags::WIDE_CHAR, 1 << 5);
    assert_eq!(flags::WIDE_CHAR_SPACER, 1 << 6);
    assert_eq!(flags::DIM, 1 << 7);
    assert_eq!(flags::HIDDEN, 1 << 8);
    assert_eq!(flags::STRIKEOUT, 1 << 9);
}

#[test]
fn modes_bits_locked_for_dart_ffi() {
    // app/lib/src/term_ffi.dart 的 TermModes 與此對齊。
    use tterm_term::modes;
    assert_eq!(modes::APP_CURSOR, 1 << 0);
    assert_eq!(modes::APP_KEYPAD, 1 << 1);
    assert_eq!(modes::BRACKETED_PASTE, 1 << 2);
    assert_eq!(modes::ALT_SCREEN, 1 << 7);
    assert_eq!(modes::SHOW_CURSOR, 1 << 8);

    let mut e = TermEngine::new(20, 5, 100);
    assert_ne!(e.mode_bits() & modes::SHOW_CURSOR, 0);
    assert_eq!(e.mode_bits() & modes::APP_CURSOR, 0);

    e.feed(b"\x1b[?1h"); // DECCKM:方向鍵改送 SS3
    assert_ne!(e.mode_bits() & modes::APP_CURSOR, 0);
    e.feed(b"\x1b[?2004h"); // bracketed paste
    assert_ne!(e.mode_bits() & modes::BRACKETED_PASTE, 0);
    e.feed(b"\x1b[?1049h"); // alt screen
    assert_ne!(e.mode_bits() & modes::ALT_SCREEN, 0);
    e.feed(b"\x1b[?25l"); // 隱藏游標
    assert_eq!(e.mode_bits() & modes::SHOW_CURSOR, 0);
}

#[test]
fn fill_grid_matches_snapshot() {
    let mut e = TermEngine::new(20, 5, 100);
    e.feed("\x1b[1;38;2;10;20;30m你好\x1b[0m ok".as_bytes());
    let snap = e.snapshot();
    let mut buf = vec![0u32; 20 * 5 * 4];
    let n = e.fill_grid_u32(&mut buf);
    assert_eq!(n, snap.cells.len());
    for (i, c) in snap.cells.iter().enumerate() {
        assert_eq!(buf[i * 4], c.ch as u32, "cell {i} char");
        let fg = ((c.fg.0 as u32) << 16) | ((c.fg.1 as u32) << 8) | c.fg.2 as u32;
        assert_eq!(buf[i * 4 + 1], fg, "cell {i} fg");
        assert_eq!(buf[i * 4 + 3], c.flags, "cell {i} flags");
    }
}

#[test]
fn scroll_to_bottom_returns_to_latest() {
    let mut e = TermEngine::new(20, 5, 100);
    for i in 1..=30 {
        e.feed(format!("row-{i:02}\r\n").as_bytes());
    }
    e.scroll_display(15);
    assert!(e.display_offset() > 0);
    e.scroll_to_bottom();
    assert_eq!(e.display_offset(), 0);
}
