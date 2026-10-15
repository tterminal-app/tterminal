// 按鍵 → PTY bytes 編碼(xterm 相容)。
//
// 分工原則(IME 正確性的關鍵):
//   * **可見字元一律不在這裡處理** —— 交給 IME/TextInput 路徑(見 ime.dart),
//     中文與英文走同一條路,不會出現「組字中同時被當按鍵送出」的重複輸入。
//   * 這裡只處理控制鍵:方向鍵、功能鍵、Enter/Tab/Backspace/Esc,
//     以及任何帶 Ctrl / Alt 的組合。
// `encode` 回傳 null = 不處理,讓事件流向 IME。

import 'dart:convert';

import 'package:flutter/services.dart';

import 'term_ffi.dart';

class KeyEncoder {
  /// xterm 修飾鍵參數:1 + shift(1) + alt(2) + ctrl(4)。
  static int _modParam({
    required bool shift,
    required bool alt,
    required bool ctrl,
  }) => 1 + (shift ? 1 : 0) + (alt ? 2 : 0) + (ctrl ? 4 : 0);

  static Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

  /// CSI 系列鍵(方向鍵、Home/End):無修飾時依 DECCKM 決定 CSI 或 SS3。
  static Uint8List _cursorKey(
    String finalChar, {
    required bool appCursor,
    required int mod,
  }) {
    if (mod == 1) {
      return _b(appCursor ? '\x1bO$finalChar' : '\x1b[$finalChar');
    }
    return _b('\x1b[1;$mod$finalChar');
  }

  /// `CSI n ~` 系列(PgUp/PgDn/Insert/Delete/F5+)。
  static Uint8List _tildeKey(int number, {required int mod}) =>
      mod == 1 ? _b('\x1b[$number~') : _b('\x1b[$number;$mod~');

  /// F1–F4 用 SS3;帶修飾時退回 CSI 1;mod P..S。
  static Uint8List _ss3Key(String finalChar, {required int mod}) =>
      mod == 1 ? _b('\x1bO$finalChar') : _b('\x1b[1;$mod$finalChar');

  static final _cursorKeys = <LogicalKeyboardKey, String>{
    LogicalKeyboardKey.arrowUp: 'A',
    LogicalKeyboardKey.arrowDown: 'B',
    LogicalKeyboardKey.arrowRight: 'C',
    LogicalKeyboardKey.arrowLeft: 'D',
    LogicalKeyboardKey.home: 'H',
    LogicalKeyboardKey.end: 'F',
  };

  static final _tildeKeys = <LogicalKeyboardKey, int>{
    LogicalKeyboardKey.insert: 2,
    LogicalKeyboardKey.delete: 3,
    LogicalKeyboardKey.pageUp: 5,
    LogicalKeyboardKey.pageDown: 6,
    LogicalKeyboardKey.f5: 15,
    LogicalKeyboardKey.f6: 17,
    LogicalKeyboardKey.f7: 18,
    LogicalKeyboardKey.f8: 19,
    LogicalKeyboardKey.f9: 20,
    LogicalKeyboardKey.f10: 21,
    LogicalKeyboardKey.f11: 23,
    LogicalKeyboardKey.f12: 24,
  };

  static final _ss3Keys = <LogicalKeyboardKey, String>{
    LogicalKeyboardKey.f1: 'P',
    LogicalKeyboardKey.f2: 'Q',
    LogicalKeyboardKey.f3: 'R',
    LogicalKeyboardKey.f4: 'S',
  };

  /// Ctrl + 符號 → C0 控制碼。
  static const _ctrlSymbols = <String, int>{
    '[': 0x1b,
    '\\': 0x1c,
    ']': 0x1d,
    '^': 0x1e,
    '_': 0x1f,
    '?': 0x7f,
    '@': 0x00,
    ' ': 0x00,
  };

  /// Ctrl+字元 → C0 控制碼 bytes;無對應時回 null。
  /// 實體鍵盤(encode)與手機工具列的黏著 Ctrl(terminal_view)共用。
  static Uint8List? ctrlBytes(String ch, {bool alt = false}) {
    final lower = ch.toLowerCase();
    final symbol = _ctrlSymbols[lower];
    int? code;
    if (symbol != null) {
      code = symbol;
    } else if (lower.length == 1) {
      final c = lower.codeUnitAt(0);
      if (c >= 0x61 && c <= 0x7a) {
        code = c - 0x60; // a–z → 0x01–0x1a
      } else if (c < 0x20 || c == 0x7f) {
        // macOS embedder 不濾控制字元(只濾 0xF700–0xF7FF 的功能鍵私用區),
        // 所以 Ctrl+C 拿到的 character 本來就是 0x03 —— 直接當結果用。
        code = c;
      }
    }
    if (code == null) return null;
    return alt ? Uint8List.fromList([0x1b, code]) : Uint8List.fromList([code]);
  }

  /// 回傳要送進 PTY 的 bytes;null 表示「不處理,交給 IME」。
  static Uint8List? encode({
    required LogicalKeyboardKey key,
    String? character,
    bool ctrl = false,
    bool alt = false,
    bool shift = false,
    bool meta = false,
    int modes = 0,
  }) {
    final appCursor = modes & TermModes.appCursor != 0;
    final mod = _modParam(shift: shift, alt: alt, ctrl: ctrl);

    // macOS 的 Cmd 一律留給選單快捷鍵,不進 PTY
    if (meta) return null;

    final cursorFinal = _cursorKeys[key];
    if (cursorFinal != null) {
      return _cursorKey(cursorFinal, appCursor: appCursor, mod: mod);
    }
    final tilde = _tildeKeys[key];
    if (tilde != null) return _tildeKey(tilde, mod: mod);
    final ss3 = _ss3Keys[key];
    if (ss3 != null) return _ss3Key(ss3, mod: mod);

    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      return alt ? _b('\x1b\r') : _b('\r');
    }
    if (key == LogicalKeyboardKey.tab) {
      if (shift) return _b('\x1b[Z');
      return alt ? _b('\x1b\t') : _b('\t');
    }
    if (key == LogicalKeyboardKey.backspace) {
      // 慣例:Backspace 送 DEL,Ctrl+Backspace 送 BS
      if (ctrl) return Uint8List.fromList([0x08]);
      return alt
          ? Uint8List.fromList([0x1b, 0x7f])
          : Uint8List.fromList([0x7f]);
    }
    if (key == LogicalKeyboardKey.escape) return _b('\x1b');

    if (!ctrl && !alt) return null; // 可見字元 → IME 路徑

    // 以下處理 Ctrl / Alt 組合。
    // Windows embedder 會把 Ctrl+字母 產生的 WM_CHAR(C0 控制碼,如 Ctrl+A=0x01)
    // 濾成非可列印 → event.character 變 null,Ctrl+A/C/E 全部收不到。
    // 此時退回用 logicalKey 的標籤還原按下的鍵(keyA→'A'、bracketLeft→'[')。
    final label = key.keyLabel;
    var ch = character;
    if ((ch == null || ch.isEmpty)) {
      if (label.length == 1) ch = label;
    }
    if (ch == null || ch.isEmpty) return null;

    if (ctrl) {
      // character 對不出控制碼時再用 logicalKey 標籤試一次:macOS 的
      // Ctrl+Alt+字母 會產生別的可列印字元(Ctrl+Alt+A → 'å'),只有標籤還原得回 'A'。
      final byChar = ctrlBytes(ch, alt: alt);
      if (byChar != null) return byChar;
      return label.length == 1 ? ctrlBytes(label, alt: alt) : null;
    }

    // 只有 Alt:ESC 前綴(meta 慣例)
    return Uint8List.fromList([0x1b, ...utf8.encode(ch)]);
  }

  /// 這個按鍵組合是否為「貼上」快捷鍵。
  ///
  /// Ctrl+V(含 Ctrl+Shift+V)一律算貼上,和 Windows Terminal 預設一致,
  /// 並讓聽寫/口語轉文字工具的剪貼簿 fallback(複製後送 Ctrl+V)能運作。
  /// Shift+Insert 與 macOS Cmd+V 也支援。
  static bool isPasteShortcut({
    required LogicalKeyboardKey key,
    required bool ctrl,
    required bool shift,
    required bool meta,
  }) {
    return (ctrl && key == LogicalKeyboardKey.keyV) ||
        (shift && key == LogicalKeyboardKey.insert) ||
        (meta && key == LogicalKeyboardKey.keyV);
  }

  /// 貼上:bracketed paste 模式下要包起來,讓 shell/vim 知道這是貼上而非逐字輸入。
  static Uint8List encodePaste(String text, int modes) {
    // 貼上內容裡的 CR 一律正規化成 CR(終端慣例),並移除會提前結束包覆的序列
    final sanitized = text
        .replaceAll('\r\n', '\r')
        .replaceAll('\n', '\r')
        .replaceAll('\x1b[201~', '');
    if (modes & TermModes.bracketedPaste != 0) {
      return _b('\x1b[200~$sanitized\x1b[201~');
    }
    return _b(sanitized);
  }
}
