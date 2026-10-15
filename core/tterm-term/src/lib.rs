//! tterm-term:tterminal 的終端模擬引擎。
//!
//! 封裝 alacritty_terminal:bytes in → grid 狀態 + damage out。
//! 上層(FFI / renderer)只依賴此 crate 的型別,不直接接觸 alacritty API,
//! 未來若替換底層實作(或下沉渲染)只動這一層。

pub mod demo;
mod engine;
mod palette;

pub use engine::{
    CellSnap, ClipboardKind, Damage, EngineEvent, GridSize, GridSnapshot, LineDamage, TermEngine,
};
pub use palette::default_color;

/// 終端模式 bits(見 [`TermEngine::mode_bits`])。
///
/// 這是 tterminal 自訂的穩定編碼(不是 alacritty 內部 bits),
/// Dart 端 `TermModes` 與此對齊,由 `modes_bits_locked_for_dart_ffi` 測試守住。
pub mod modes {
    pub const APP_CURSOR: u32 = 1 << 0;
    pub const APP_KEYPAD: u32 = 1 << 1;
    pub const BRACKETED_PASTE: u32 = 1 << 2;
    pub const MOUSE_REPORT_CLICK: u32 = 1 << 3;
    pub const MOUSE_DRAG: u32 = 1 << 4;
    pub const MOUSE_MOTION: u32 = 1 << 5;
    pub const SGR_MOUSE: u32 = 1 << 6;
    pub const ALT_SCREEN: u32 = 1 << 7;
    pub const SHOW_CURSOR: u32 = 1 << 8;

    /// 「會讓滾輪失效」的模式集合:滑鼠回報開著時滾輪被編碼成滑鼠事件送給
    /// 程式、alt screen 沒有 scrollback 可捲。前景 TUI 正常結束會自己關掉,
    /// 被強制中斷(Ctrl+C / crash / kill)就會留在這裡沒人收拾。
    pub const WHEEL_BLOCKING: u32 =
        MOUSE_REPORT_CLICK | MOUSE_DRAG | MOUSE_MOTION | ALT_SCREEN;
}

/// Cell 樣式 flags(與 `CellSnap.flags` 的 bits 對齊)。
pub mod flags {
    use alacritty_terminal::term::cell::Flags;

    pub const INVERSE: u32 = Flags::INVERSE.bits() as u32;
    pub const BOLD: u32 = Flags::BOLD.bits() as u32;
    pub const ITALIC: u32 = Flags::ITALIC.bits() as u32;
    pub const UNDERLINE: u32 = Flags::UNDERLINE.bits() as u32;
    pub const WRAPLINE: u32 = Flags::WRAPLINE.bits() as u32;
    pub const WIDE_CHAR: u32 = Flags::WIDE_CHAR.bits() as u32;
    pub const WIDE_CHAR_SPACER: u32 = Flags::WIDE_CHAR_SPACER.bits() as u32;
    pub const DIM: u32 = Flags::DIM.bits() as u32;
    pub const HIDDEN: u32 = Flags::HIDDEN.bits() as u32;
    pub const STRIKEOUT: u32 = Flags::STRIKEOUT.bits() as u32;
}
