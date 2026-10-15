//! 預設色盤(renderer 未提供主題覆寫時的 fallback)。
//!
//! 0..=255 為標準 xterm 色盤;256..=268 對齊 alacritty `NamedColor` 的 usize 值
//! (Foreground / Background / Cursor / Dim* / BrightForeground / DimForeground)。

use std::sync::OnceLock;

pub const COUNT: usize = 269;

static PALETTE: OnceLock<[(u8, u8, u8); COUNT]> = OnceLock::new();

pub fn default_color(idx: usize) -> (u8, u8, u8) {
    let p = PALETTE.get_or_init(build);
    if idx < COUNT {
        p[idx]
    } else {
        p[256]
    }
}

fn build() -> [(u8, u8, u8); COUNT] {
    let mut p = [(0u8, 0u8, 0u8); COUNT];
    const BASE: [(u8, u8, u8); 16] = [
        (0x00, 0x00, 0x00),
        (0xcd, 0x00, 0x00),
        (0x00, 0xcd, 0x00),
        (0xcd, 0xcd, 0x00),
        (0x00, 0x00, 0xee),
        (0xcd, 0x00, 0xcd),
        (0x00, 0xcd, 0xcd),
        (0xe5, 0xe5, 0xe5),
        (0x7f, 0x7f, 0x7f),
        (0xff, 0x00, 0x00),
        (0x00, 0xff, 0x00),
        (0xff, 0xff, 0x00),
        (0x5c, 0x5c, 0xff),
        (0xff, 0x00, 0xff),
        (0x00, 0xff, 0xff),
        (0xff, 0xff, 0xff),
    ];
    p[..16].copy_from_slice(&BASE);

    const LEVELS: [u8; 6] = [0, 95, 135, 175, 215, 255];
    for r in 0..6 {
        for g in 0..6 {
            for b in 0..6 {
                p[16 + 36 * r + 6 * g + b] = (LEVELS[r], LEVELS[g], LEVELS[b]);
            }
        }
    }
    for i in 0..24 {
        let v = (8 + i * 10) as u8;
        p[232 + i] = (v, v, v);
    }

    p[256] = (0xd8, 0xd8, 0xd8); // Foreground
    p[257] = (0x18, 0x18, 0x18); // Background
    p[258] = (0xd8, 0xd8, 0xd8); // Cursor
    for i in 0..8 {
        // DimBlack..DimWhite:對應基本色的 2/3 亮度
        let (r, g, b) = p[i];
        p[259 + i] = (
            (r as u16 * 2 / 3) as u8,
            (g as u16 * 2 / 3) as u8,
            (b as u16 * 2 / 3) as u8,
        );
    }
    p[267] = (0xff, 0xff, 0xff); // BrightForeground
    p[268] = (0x90, 0x90, 0x90); // DimForeground
    p
}
