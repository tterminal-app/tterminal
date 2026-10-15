//! 合成 VT 資料流產生器(term_bench 與 FFI 渲染 demo 共用)。
//!
//! 有狀態:連續呼叫 `gen_chunk` 會延續行號/亂數序列,
//! 模擬持續輸出的長工作(`cat` 大檔、TUI 重繪)。

#[derive(Debug, Clone)]
pub struct DemoState {
    line: u64,
    rng: u64,
}

impl Default for DemoState {
    fn default() -> Self {
        Self { line: 0, rng: 42 }
    }
}

impl DemoState {
    fn next_rand(&mut self) -> u64 {
        self.rng = self
            .rng
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        self.rng >> 33
    }
}

pub const SCENARIO_PLAIN: u32 = 0;
pub const SCENARIO_COLORED: u32 = 1;
pub const SCENARIO_CJK: u32 = 2;
pub const SCENARIO_CURSOR_PAINT: u32 = 3;

pub fn scenario_name(scenario: u32) -> &'static str {
    match scenario {
        SCENARIO_PLAIN => "plain_scroll",
        SCENARIO_COLORED => "colored_scroll",
        SCENARIO_CJK => "cjk_scroll",
        SCENARIO_CURSOR_PAINT => "cursor_paint",
        _ => "unknown",
    }
}

/// 產生至少 `target` bytes 的資料(以「完整行 / 完整 frame」為單位,可能略超過)。
pub fn gen_chunk(
    scenario: u32,
    state: &mut DemoState,
    target: usize,
    cols: usize,
    rows: usize,
) -> Vec<u8> {
    match scenario {
        SCENARIO_COLORED => gen_colored(state, target),
        SCENARIO_CJK => gen_cjk(state, target),
        SCENARIO_CURSOR_PAINT => gen_cursor_paint(state, target, cols, rows),
        _ => gen_plain(state, target),
    }
}

fn gen_plain(state: &mut DemoState, target: usize) -> Vec<u8> {
    let mut out = Vec::with_capacity(target + 128);
    while out.len() < target {
        let i = state.line;
        out.extend_from_slice(
            format!("line {i:07} the quick brown fox jumps over the lazy dog 0123456789abcdef\r\n")
                .as_bytes(),
        );
        state.line += 1;
    }
    out
}

fn gen_colored(state: &mut DemoState, target: usize) -> Vec<u8> {
    let mut out = Vec::with_capacity(target + 256);
    while out.len() < target {
        let i = state.line;
        let c1 = state.next_rand() % 256;
        let c2 = state.next_rand() % 256;
        out.extend_from_slice(
            format!(
                "\x1b[38;5;{c1}mline {i:07}\x1b[0m \x1b[1;38;5;{c2}mbold-word\x1b[0m \x1b[4munderline\x1b[0m plain tail text\r\n"
            )
            .as_bytes(),
        );
        state.line += 1;
    }
    out
}

fn gen_cjk(state: &mut DemoState, target: usize) -> Vec<u8> {
    let mut out = Vec::with_capacity(target + 256);
    while out.len() < target {
        let i = state.line;
        out.extend_from_slice(
            format!("第{i:06}行 中文寬字元渲染效能測試 終端機模擬器 你好世界 混合 ascii tail\r\n")
                .as_bytes(),
        );
        state.line += 1;
    }
    out
}

fn gen_cursor_paint(state: &mut DemoState, target: usize, cols: usize, rows: usize) -> Vec<u8> {
    // 全螢幕 TUI 風格:逐 frame 以絕對定位重畫整個畫面,不捲動。
    const SEGS: [&str; 4] = ["████▓▓▒▒", "abcdefgh", "01234567", "▁▂▃▄▅▆▇█"];
    let mut out = Vec::with_capacity(target + 1024);
    while out.len() < target {
        for row in 1..=rows {
            out.extend_from_slice(format!("\x1b[{row};1H").as_bytes());
            let mut col = 0;
            while col < cols {
                let (r, g, b) = (
                    state.next_rand() % 256,
                    state.next_rand() % 256,
                    state.next_rand() % 256,
                );
                let seg = SEGS[(state.next_rand() % 4) as usize];
                out.extend_from_slice(format!("\x1b[38;2;{r};{g};{b}m{seg}").as_bytes());
                col += 8;
            }
        }
        out.extend_from_slice(b"\x1b[0m");
    }
    out
}
