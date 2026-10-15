//! TermEngine:單一 terminal 的模擬核心。
//!
//! 職責:bytes 進(PTY / SSH 輸出)→ grid 狀態 + damage 出(給 renderer),
//! 並回傳引擎事件(要回寫 PTY 的 DA/DSR 回應、title 變更、bell 等)。
//! 不含鎖:呼叫端(FFI 層 / session 層)負責單執行緒存取或自行包 Mutex。

use std::sync::mpsc::{self, Receiver, Sender};

use alacritty_terminal::event::{Event, EventListener, WindowSize};
use alacritty_terminal::grid::{Dimensions, Scroll};
use alacritty_terminal::index::{Column, Line};
use alacritty_terminal::term::cell::Flags;
use alacritty_terminal::term::{ClipboardType, Config as AlacConfig, Term, TermDamage, TermMode};
use alacritty_terminal::vte::ansi::{Color as AnsiColor, Processor, Rgb};

use crate::palette;

/// Grid 尺寸(cells)。
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub struct GridSize {
    pub cols: usize,
    pub rows: usize,
}

impl Dimensions for GridSize {
    fn total_lines(&self) -> usize {
        self.rows
    }
    fn screen_lines(&self) -> usize {
        self.rows
    }
    fn columns(&self) -> usize {
        self.cols
    }
}

/// 引擎對外事件。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EngineEvent {
    /// 終端要求回寫 bytes 到 PTY(DA/DSR 回應等)。呼叫端「必須」轉送,
    /// 否則 vim/htop 這類會查詢終端能力的程式將卡住或降級。
    PtyWrite(Vec<u8>),
    Title(String),
    ResetTitle,
    Bell,
    ClipboardStore(ClipboardKind, String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ClipboardKind {
    Clipboard,
    Selection,
}

/// Renderer 需要重繪的範圍(viewport 座標)。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Damage {
    Full,
    Lines(Vec<LineDamage>),
}

/// 單行 damage,`left..=right` 為需要重繪的 column 範圍。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LineDamage {
    pub line: usize,
    pub left: usize,
    pub right: usize,
}

/// 單一 cell 快照。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CellSnap {
    pub ch: char,
    pub fg: (u8, u8, u8),
    pub bg: (u8, u8, u8),
    pub flags: u32,
}

/// 完整 viewport 快照(初版 renderer / bench 用;FFI 層之後會改共享 buffer)。
#[derive(Debug, Clone)]
pub struct GridSnapshot {
    pub cols: usize,
    pub rows: usize,
    /// row-major;wide char 佔兩格,第二格 flags 含 WIDE_CHAR_SPACER。
    pub cells: Vec<CellSnap>,
    pub cursor_row: usize,
    pub cursor_col: usize,
    pub cursor_visible: bool,
    pub display_offset: usize,
}

#[derive(Clone)]
struct EventProxy {
    tx: Sender<Event>,
}

impl EventListener for EventProxy {
    fn send_event(&self, event: Event) {
        let _ = self.tx.send(event);
    }
}

pub struct TermEngine {
    term: Term<EventProxy>,
    processor: Processor,
    events_rx: Receiver<Event>,
    size: GridSize,
    osc7: Osc7Scanner,
    current_dir: Option<String>,
}

/// OSC 7(current working directory)掃描器。
///
/// alacritty_terminal 不處理 OSC 7,所以我們在餵進去之前自己掃一遍。
/// 用小型狀態機處理跨 chunk 邊界(OSC 序列可能被 PTY 讀取切成兩半)。
/// 格式:`ESC ] 7 ; file://host/path (BEL | ESC \)`。
#[derive(Default)]
struct Osc7Scanner {
    in_osc: bool,
    esc: bool,     // OSC 外:上一個 byte 是 ESC
    osc_esc: bool, // OSC 內:看到 ESC(可能是 ST 終止符 ESC \)
    buf: Vec<u8>,
}

impl Osc7Scanner {
    /// 掃描 bytes;若解析出完整的 OSC 7 cwd 就回傳(同一批多個時取最後一個)。
    fn scan(&mut self, bytes: &[u8]) -> Option<String> {
        let mut result = None;
        for &b in bytes {
            if !self.in_osc {
                if self.esc && b == b']' {
                    self.in_osc = true;
                    self.buf.clear();
                    self.esc = false;
                } else {
                    self.esc = b == 0x1b;
                }
            } else if b == 0x07 || (self.osc_esc && b == b'\\') {
                // BEL 或 ST 終止
                if let Some(cwd) = parse_osc7(&self.buf) {
                    result = Some(cwd);
                }
                self.in_osc = false;
                self.osc_esc = false;
                self.buf.clear();
            } else if b == 0x1b {
                self.osc_esc = true;
            } else {
                self.osc_esc = false;
                if self.buf.len() < 4096 {
                    self.buf.push(b);
                }
            }
        }
        result
    }
}

/// `7;file://host/path` → 本地路徑(Windows 去掉 drive 前的斜線、percent-decode)。
fn parse_osc7(buf: &[u8]) -> Option<String> {
    let s = std::str::from_utf8(buf).ok()?;
    let rest = s.strip_prefix("7;")?;
    let after_scheme = rest.strip_prefix("file://")?;
    // 跳過 host,取第一個 '/' 之後(含該斜線)當路徑
    let slash = after_scheme.find('/')?;
    let path = percent_decode(&after_scheme[slash..]);
    // Windows:`/C:/Users/...` → `C:/Users/...`
    let bytes = path.as_bytes();
    if bytes.len() >= 3 && bytes[0] == b'/' && bytes[2] == b':' {
        Some(path[1..].to_string())
    } else {
        Some(path)
    }
}

fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            let hi = (bytes[i + 1] as char).to_digit(16);
            let lo = (bytes[i + 2] as char).to_digit(16);
            if let (Some(hi), Some(lo)) = (hi, lo) {
                out.push((hi * 16 + lo) as u8);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

impl TermEngine {
    pub fn new(cols: usize, rows: usize, scrollback_lines: usize) -> Self {
        let (tx, rx) = mpsc::channel();
        let config = AlacConfig {
            scrolling_history: scrollback_lines,
            ..AlacConfig::default()
        };
        let size = GridSize { cols, rows };
        let term = Term::new(config, &size, EventProxy { tx });
        Self {
            term,
            processor: Processor::new(),
            events_rx: rx,
            size,
            osc7: Osc7Scanner::default(),
            current_dir: None,
        }
    }

    /// 餵入 PTY / SSH 端來的 bytes。
    pub fn feed(&mut self, bytes: &[u8]) {
        if let Some(cwd) = self.osc7.scan(bytes) {
            self.current_dir = Some(cwd);
        }
        self.processor.advance(&mut self.term, bytes);
    }

    /// 最近一次 OSC 7 回報的工作目錄(shell 有送才有值)。
    pub fn current_directory(&self) -> Option<&str> {
        self.current_dir.as_deref()
    }

    /// 回到「一般終端」狀態:離開 alt screen、關掉滑鼠回報、游標顯示。
    ///
    /// 前景 TUI(claude code / vim / htop…)被強制中斷時不會送復原序列,
    /// 終端就卡在 alt screen 或滑鼠回報模式——使用者看到的症狀是**滾輪完全
    /// 沒反應**(滾輪被編碼成滑鼠事件送給早就不在的程式,或 alt screen 根本
    /// 沒有 scrollback),而且 Windows 的 PowerShell 沒有 `reset` 可以自救。
    ///
    /// 走 parser 而不是直接改 alacritty 內部 bits:復原序列與真實程式送的
    /// 完全一樣,alt screen 的還原(游標、螢幕內容)也照 alacritty 的路徑走。
    pub fn reset_input_modes(&mut self) {
        self.feed(b"\x1b[?1049l\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l\x1b[?25h");
        // 這幾個序列不會產生 PtyWrite,但仍清掉事件佇列以免堆積。
        let _ = self.drain_events();
    }

    pub fn resize(&mut self, cols: usize, rows: usize) {
        self.size = GridSize { cols, rows };
        self.term.resize(self.size);
    }

    pub fn size(&self) -> GridSize {
        self.size
    }

    /// 取出並清空 damage。
    pub fn take_damage(&mut self) -> Damage {
        let damage = match self.term.damage() {
            TermDamage::Full => Damage::Full,
            TermDamage::Partial(iter) => Damage::Lines(
                iter.map(|b| LineDamage {
                    line: b.line,
                    left: b.left,
                    right: b.right,
                })
                .collect(),
            ),
        };
        self.term.reset_damage();
        damage
    }

    /// 取出引擎事件;其中 `PtyWrite` 必須被轉送回 PTY / SSH channel。
    pub fn drain_events(&mut self) -> Vec<EngineEvent> {
        let mut out = Vec::new();
        while let Ok(ev) = self.events_rx.try_recv() {
            match ev {
                Event::PtyWrite(s) => out.push(EngineEvent::PtyWrite(s.into_bytes())),
                Event::Title(t) => out.push(EngineEvent::Title(t)),
                Event::ResetTitle => out.push(EngineEvent::ResetTitle),
                Event::Bell => out.push(EngineEvent::Bell),
                Event::ClipboardStore(ty, data) => out.push(EngineEvent::ClipboardStore(
                    match ty {
                        ClipboardType::Clipboard => ClipboardKind::Clipboard,
                        ClipboardType::Selection => ClipboardKind::Selection,
                    },
                    data,
                )),
                // 查詢類事件:立即以預設值回應。
                // 注意:runtime 色盤覆寫(OSC 4)之後由 renderer 主題層接手,這裡先回預設值。
                Event::ClipboardLoad(_, fmt) => {
                    out.push(EngineEvent::PtyWrite(fmt("").into_bytes()));
                }
                Event::ColorRequest(idx, fmt) => {
                    let (r, g, b) = palette::default_color(idx);
                    out.push(EngineEvent::PtyWrite(fmt(Rgb { r, g, b }).into_bytes()));
                }
                Event::TextAreaSizeRequest(fmt) => {
                    let ws = WindowSize {
                        num_lines: self.size.rows as u16,
                        num_cols: self.size.cols as u16,
                        cell_width: 8,
                        cell_height: 16,
                    };
                    out.push(EngineEvent::PtyWrite(fmt(ws).into_bytes()));
                }
                _ => {}
            }
        }
        out
    }

    /// 捲動 viewport(正值 = 往歷史方向)。
    pub fn scroll_display(&mut self, delta: i32) {
        self.term.scroll_display(Scroll::Delta(delta));
    }

    /// 回到最新輸出(有輸入時應呼叫,與一般終端行為一致)。
    pub fn scroll_to_bottom(&mut self) {
        self.term.scroll_display(Scroll::Bottom);
    }

    /// 目前的終端模式(見 [`crate::modes`]);輸入編碼器需要它來決定
    /// 方向鍵送 CSI 還是 SS3、貼上是否加 bracketed paste 包覆。
    pub fn mode_bits(&self) -> u32 {
        let m = self.term.mode();
        let mut bits = 0;
        let map = [
            (TermMode::APP_CURSOR, crate::modes::APP_CURSOR),
            (TermMode::APP_KEYPAD, crate::modes::APP_KEYPAD),
            (TermMode::BRACKETED_PASTE, crate::modes::BRACKETED_PASTE),
            (TermMode::MOUSE_REPORT_CLICK, crate::modes::MOUSE_REPORT_CLICK),
            (TermMode::MOUSE_DRAG, crate::modes::MOUSE_DRAG),
            (TermMode::MOUSE_MOTION, crate::modes::MOUSE_MOTION),
            (TermMode::SGR_MOUSE, crate::modes::SGR_MOUSE),
            (TermMode::ALT_SCREEN, crate::modes::ALT_SCREEN),
            (TermMode::SHOW_CURSOR, crate::modes::SHOW_CURSOR),
        ];
        for (flag, bit) in map {
            if m.contains(flag) {
                bits |= bit;
            }
        }
        bits
    }

    pub fn display_offset(&self) -> usize {
        self.term.grid().display_offset()
    }

    pub fn history_lines(&self) -> usize {
        self.term.grid().history_size()
    }

    /// (row, col),viewport 座標。
    pub fn cursor_position(&self) -> (usize, usize) {
        let p = self.term.grid().cursor.point;
        (p.line.0.max(0) as usize, p.column.0)
    }

    pub fn cursor_visible(&self) -> bool {
        self.term.mode().contains(TermMode::SHOW_CURSOR)
    }

    /// 目前 viewport 的純文字(測試 / 搜尋用)。
    /// Wide char 佔位格會被跳過,行尾空白修剪。
    pub fn visible_text(&self) -> Vec<String> {
        let grid = self.term.grid();
        let offset = grid.display_offset() as i32;
        let mut out = Vec::with_capacity(self.size.rows);
        for row in 0..self.size.rows {
            let line = Line(row as i32 - offset);
            let mut s = String::with_capacity(self.size.cols);
            for col in 0..self.size.cols {
                let cell = &grid[line][Column(col)];
                if cell
                    .flags
                    .intersects(Flags::WIDE_CHAR_SPACER | Flags::LEADING_WIDE_CHAR_SPACER)
                {
                    continue;
                }
                s.push(cell.c);
                if let Some(zw) = cell.zerowidth() {
                    s.extend(zw.iter());
                }
            }
            out.push(s.trim_end().to_string());
        }
        out
    }

    /// 渲染熱路徑:把 viewport 直接寫進呼叫端 buffer(免配置)。
    ///
    /// 每 cell 4 個 u32:`[codepoint, fg 0xRRGGBB, bg 0xRRGGBB, flags]`。
    /// `out` 至少要有 `cols * rows * 4` 個元素;回傳實際寫入的 cell 數。
    /// 組合字元(如 U+0301)不在此傳遞——renderer 之後若要支援需另開 side channel。
    pub fn fill_grid_u32(&self, out: &mut [u32]) -> usize {
        let grid = self.term.grid();
        let colors = self.term.colors();
        let offset = grid.display_offset() as i32;
        let capacity = out.len() / 4;
        let mut written = 0;
        for row in 0..self.size.rows {
            let line = Line(row as i32 - offset);
            for col in 0..self.size.cols {
                if written >= capacity {
                    return written;
                }
                let cell = &grid[line][Column(col)];
                let base = written * 4;
                out[base] = cell.c as u32;
                out[base + 1] = pack_rgb(resolve_color(colors, cell.fg));
                out[base + 2] = pack_rgb(resolve_color(colors, cell.bg));
                out[base + 3] = cell.flags.bits() as u32;
                written += 1;
            }
        }
        written
    }

    /// 完整 viewport 快照。
    pub fn snapshot(&self) -> GridSnapshot {
        let grid = self.term.grid();
        let colors = self.term.colors();
        let offset = grid.display_offset() as i32;
        let mut cells = Vec::with_capacity(self.size.cols * self.size.rows);
        for row in 0..self.size.rows {
            let line = Line(row as i32 - offset);
            for col in 0..self.size.cols {
                let cell = &grid[line][Column(col)];
                cells.push(CellSnap {
                    ch: cell.c,
                    fg: resolve_color(colors, cell.fg),
                    bg: resolve_color(colors, cell.bg),
                    flags: cell.flags.bits() as u32,
                });
            }
        }
        let cursor = grid.cursor.point;
        GridSnapshot {
            cols: self.size.cols,
            rows: self.size.rows,
            cells,
            cursor_row: cursor.line.0.max(0) as usize,
            cursor_col: cursor.column.0,
            cursor_visible: self.term.mode().contains(TermMode::SHOW_CURSOR),
            display_offset: offset as usize,
        }
    }
}

#[inline]
fn pack_rgb((r, g, b): (u8, u8, u8)) -> u32 {
    ((r as u32) << 16) | ((g as u32) << 8) | (b as u32)
}

fn resolve_color(
    colors: &alacritty_terminal::term::color::Colors,
    color: AnsiColor,
) -> (u8, u8, u8) {
    match color {
        AnsiColor::Spec(rgb) => (rgb.r, rgb.g, rgb.b),
        AnsiColor::Named(named) => lookup(colors, named as usize),
        AnsiColor::Indexed(idx) => lookup(colors, idx as usize),
    }
}

fn lookup(colors: &alacritty_terminal::term::color::Colors, idx: usize) -> (u8, u8, u8) {
    match colors[idx] {
        Some(rgb) => (rgb.r, rgb.g, rgb.b),
        None => palette::default_color(idx),
    }
}
