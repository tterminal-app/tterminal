// 按鍵 → PTY bytes 編碼測試(xterm 相容性)。

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tterm_app/src/keys.dart';
import 'package:tterm_app/src/term_ffi.dart';

String? enc(
  LogicalKeyboardKey key, {
  String? character,
  bool ctrl = false,
  bool alt = false,
  bool shift = false,
  bool meta = false,
  int modes = 0,
}) {
  final bytes = KeyEncoder.encode(
    key: key,
    character: character,
    ctrl: ctrl,
    alt: alt,
    shift: shift,
    meta: meta,
    modes: modes,
  );
  return bytes == null ? null : utf8.decode(bytes);
}

void main() {
  group('可見字元交給 IME', () {
    test('純字母不編碼(回 null)', () {
      expect(enc(LogicalKeyboardKey.keyA, character: 'a'), isNull);
      expect(enc(LogicalKeyboardKey.space, character: ' '), isNull);
      expect(
        enc(LogicalKeyboardKey.keyA, character: 'A', shift: true),
        isNull,
        reason: 'Shift+字母仍是可見字元,要走 IME',
      );
    });

    test('Cmd(meta)組合不進 PTY', () {
      expect(enc(LogicalKeyboardKey.keyC, character: 'c', meta: true), isNull);
    });
  });

  group('方向鍵', () {
    test('一般模式送 CSI', () {
      expect(enc(LogicalKeyboardKey.arrowUp), '\x1b[A');
      expect(enc(LogicalKeyboardKey.arrowDown), '\x1b[B');
      expect(enc(LogicalKeyboardKey.arrowRight), '\x1b[C');
      expect(enc(LogicalKeyboardKey.arrowLeft), '\x1b[D');
    });

    test('DECCKM(application cursor)模式送 SS3', () {
      // vim / less 會開這個模式,送錯方向鍵就會亂跳
      expect(
        enc(LogicalKeyboardKey.arrowUp, modes: TermModes.appCursor),
        '\x1bOA',
      );
      expect(
        enc(LogicalKeyboardKey.arrowLeft, modes: TermModes.appCursor),
        '\x1bOD',
      );
    });

    test('帶修飾鍵一律用 CSI 1;mod 形式', () {
      expect(enc(LogicalKeyboardKey.arrowRight, ctrl: true), '\x1b[1;5C');
      expect(enc(LogicalKeyboardKey.arrowLeft, shift: true), '\x1b[1;2D');
      expect(enc(LogicalKeyboardKey.arrowUp, alt: true), '\x1b[1;3A');
      expect(
        enc(LogicalKeyboardKey.arrowUp, ctrl: true, shift: true),
        '\x1b[1;6A',
      );
      expect(
        enc(
          LogicalKeyboardKey.arrowUp,
          ctrl: true,
          modes: TermModes.appCursor,
        ),
        '\x1b[1;5A',
        reason: '帶修飾鍵時即使 app cursor 模式也用 CSI',
      );
    });
  });

  group('功能鍵與導覽鍵', () {
    test('F1–F4 用 SS3、F5+ 用 CSI n~', () {
      expect(enc(LogicalKeyboardKey.f1), '\x1bOP');
      expect(enc(LogicalKeyboardKey.f4), '\x1bOS');
      expect(enc(LogicalKeyboardKey.f5), '\x1b[15~');
      expect(enc(LogicalKeyboardKey.f12), '\x1b[24~');
    });

    test('Home/End/PgUp/PgDn/Delete', () {
      expect(enc(LogicalKeyboardKey.home), '\x1b[H');
      expect(enc(LogicalKeyboardKey.end), '\x1b[F');
      expect(enc(LogicalKeyboardKey.pageUp), '\x1b[5~');
      expect(enc(LogicalKeyboardKey.pageDown), '\x1b[6~');
      expect(enc(LogicalKeyboardKey.delete), '\x1b[3~');
    });

    test('修飾鍵版本', () {
      expect(enc(LogicalKeyboardKey.f5, ctrl: true), '\x1b[15;5~');
      expect(enc(LogicalKeyboardKey.home, ctrl: true), '\x1b[1;5H');
    });
  });

  group('控制鍵', () {
    test('Enter/Tab/Esc/Backspace', () {
      expect(enc(LogicalKeyboardKey.enter), '\r');
      expect(enc(LogicalKeyboardKey.tab), '\t');
      expect(enc(LogicalKeyboardKey.escape), '\x1b');
      expect(
        KeyEncoder.encode(key: LogicalKeyboardKey.backspace),
        Uint8List.fromList([0x7f]),
      );
    });

    test('Shift+Tab 送 CSI Z(反向 tab)', () {
      expect(enc(LogicalKeyboardKey.tab, shift: true), '\x1b[Z');
    });

    test('Ctrl+Backspace 送 BS、Alt+Backspace 送 ESC DEL', () {
      expect(
        KeyEncoder.encode(key: LogicalKeyboardKey.backspace, ctrl: true),
        Uint8List.fromList([0x08]),
      );
      expect(
        KeyEncoder.encode(key: LogicalKeyboardKey.backspace, alt: true),
        Uint8List.fromList([0x1b, 0x7f]),
      );
    });
  });

  group('Ctrl 組合', () {
    test('Ctrl+C / Ctrl+D / Ctrl+Z 等對應 C0 控制碼', () {
      expect(
        KeyEncoder.encode(
          key: LogicalKeyboardKey.keyC,
          character: 'c',
          ctrl: true,
        ),
        Uint8List.fromList([0x03]),
      );
      expect(
        KeyEncoder.encode(
          key: LogicalKeyboardKey.keyD,
          character: 'd',
          ctrl: true,
        ),
        Uint8List.fromList([0x04]),
      );
      expect(
        KeyEncoder.encode(
          key: LogicalKeyboardKey.keyZ,
          character: 'z',
          ctrl: true,
        ),
        Uint8List.fromList([0x1a]),
      );
    });

    test('大小寫都對應同一個控制碼', () {
      expect(
        KeyEncoder.encode(
          key: LogicalKeyboardKey.keyC,
          character: 'C',
          ctrl: true,
          shift: true,
        ),
        Uint8List.fromList([0x03]),
      );
    });

    test('Ctrl+符號', () {
      expect(
        KeyEncoder.encode(
          key: LogicalKeyboardKey.bracketLeft,
          character: '[',
          ctrl: true,
        ),
        Uint8List.fromList([0x1b]),
      );
      expect(
        KeyEncoder.encode(
          key: LogicalKeyboardKey.space,
          character: ' ',
          ctrl: true,
        ),
        Uint8List.fromList([0x00]),
      );
    });

    test('Ctrl+Alt+字母 = ESC 前綴 + 控制碼', () {
      expect(
        KeyEncoder.encode(
          key: LogicalKeyboardKey.keyA,
          character: 'a',
          ctrl: true,
          alt: true,
        ),
        Uint8List.fromList([0x1b, 0x01]),
      );
    });

    // Windows 實機:Ctrl+字母 的 WM_CHAR 是 C0 控制碼,被 Flutter 濾成 null。
    // 這組測試鎖住「character 為 null 時用 logicalKey 還原」的 fallback。
    test('character 為 null 時仍能編碼(Windows Ctrl 路徑)', () {
      expect(
        KeyEncoder.encode(key: LogicalKeyboardKey.keyA, ctrl: true),
        Uint8List.fromList([0x01]),
        reason: 'Ctrl+A 應送 0x01(游標到行首)',
      );
      expect(
        KeyEncoder.encode(key: LogicalKeyboardKey.keyE, ctrl: true),
        Uint8List.fromList([0x05]),
        reason: 'Ctrl+E 應送 0x05(游標到行尾)',
      );
      expect(
        KeyEncoder.encode(key: LogicalKeyboardKey.keyC, ctrl: true),
        Uint8List.fromList([0x03]),
        reason: 'Ctrl+C 應送 0x03(SIGINT)',
      );
      expect(
        KeyEncoder.encode(key: LogicalKeyboardKey.keyU, ctrl: true),
        Uint8List.fromList([0x15]),
      );
      // 符號鍵同樣走 fallback:Ctrl+[ = ESC
      expect(
        KeyEncoder.encode(key: LogicalKeyboardKey.bracketLeft, ctrl: true),
        Uint8List.fromList([0x1b]),
      );
      // Ctrl+Alt+字母(character null)= ESC 前綴 + 控制碼
      expect(
        KeyEncoder.encode(
          key: LogicalKeyboardKey.keyA,
          ctrl: true,
          alt: true,
        ),
        Uint8List.fromList([0x1b, 0x01]),
      );
    });

    // macOS 實機:embedder 的 getEventString 只濾 0xF700–0xF7FF(功能鍵私用區),
    // C0 控制字元原封不動放過 → Ctrl+C 的 character 本來就是 '\x03'。
    // 這和 Windows 剛好相反(那邊被濾成 null),而 character 非空時不會走
    // keyLabel fallback,所以這條路徑必須自己認得控制碼,否則 Ctrl 全失效。
    test('character 已是控制碼時直接採用(macOS Ctrl 路徑)', () {
      expect(
        KeyEncoder.encode(
          key: LogicalKeyboardKey.keyC,
          character: '\x03',
          ctrl: true,
        ),
        Uint8List.fromList([0x03]),
        reason: 'Ctrl+C 應送 0x03(SIGINT)',
      );
      expect(
        KeyEncoder.encode(
          key: LogicalKeyboardKey.keyD,
          character: '\x04',
          ctrl: true,
        ),
        Uint8List.fromList([0x04]),
      );
      // Ctrl+[ 的 character 是 ESC 本身
      expect(
        KeyEncoder.encode(
          key: LogicalKeyboardKey.bracketLeft,
          character: '\x1b',
          ctrl: true,
        ),
        Uint8List.fromList([0x1b]),
      );
      // Ctrl+Alt+字母:macOS 仍給控制碼,前面補 ESC
      expect(
        KeyEncoder.encode(
          key: LogicalKeyboardKey.keyC,
          character: '\x03',
          ctrl: true,
          alt: true,
        ),
        Uint8List.fromList([0x1b, 0x03]),
      );
    });

    test('character 是別的可列印字元時退回 keyLabel(macOS Ctrl+Alt)', () {
      // macOS 上 Option 會改字:Ctrl+Alt+A 的 character 可能是 'å',
      // 'å' 對不出控制碼,要靠 logicalKey 還原成 'A' → 0x01。
      expect(
        KeyEncoder.encode(
          key: LogicalKeyboardKey.keyA,
          character: 'å',
          ctrl: true,
          alt: true,
        ),
        Uint8List.fromList([0x1b, 0x01]),
      );
    });

    test('非字元鍵不會被 fallback 誤判(keyLabel 多字元)', () {
      // Ctrl+F1 的 keyLabel 是 'F1'(長度>1),不該被當成可編碼字元
      expect(
        KeyEncoder.encode(key: LogicalKeyboardKey.f1, ctrl: true),
        Uint8List.fromList([0x1b, 0x5b, 0x31, 0x3b, 0x35, 0x50]),
        reason: 'F1 走 SS3/CSI 路徑,不進 Ctrl 字元 fallback',
      );
    });
  });

  group('Alt(meta)組合', () {
    test('Alt+字母送 ESC 前綴', () {
      expect(
        enc(LogicalKeyboardKey.keyF, character: 'f', alt: true),
        '\x1bf',
        reason: 'readline 的 Alt+f = 往前一個詞',
      );
    });
  });

  group('貼上快捷鍵判定(聽寫工具剪貼簿 fallback 需要 Ctrl+V)', () {
    bool paste(
      LogicalKeyboardKey key, {
      bool ctrl = false,
      bool shift = false,
      bool meta = false,
    }) => KeyEncoder.isPasteShortcut(key: key, ctrl: ctrl, shift: shift, meta: meta);

    test('Ctrl+V 貼上(Windows Terminal 預設 + 聽寫 fallback)', () {
      expect(paste(LogicalKeyboardKey.keyV, ctrl: true), isTrue);
    });
    test('Ctrl+Shift+V 也貼上', () {
      expect(paste(LogicalKeyboardKey.keyV, ctrl: true, shift: true), isTrue);
    });
    test('Shift+Insert 貼上', () {
      expect(paste(LogicalKeyboardKey.insert, shift: true), isTrue);
    });
    test('macOS Cmd+V 貼上', () {
      expect(paste(LogicalKeyboardKey.keyV, meta: true), isTrue);
    });
    test('無修飾 V、Ctrl+C 不是貼上', () {
      expect(paste(LogicalKeyboardKey.keyV), isFalse);
      expect(paste(LogicalKeyboardKey.keyC, ctrl: true), isFalse);
      expect(paste(LogicalKeyboardKey.insert), isFalse);
    });
  });

  group('貼上', () {
    test('bracketed paste 模式會包住內容', () {
      final out = utf8.decode(
        KeyEncoder.encodePaste('hello', TermModes.bracketedPaste),
      );
      expect(out, '\x1b[200~hello\x1b[201~');
    });

    test('未開啟時直接送出', () {
      expect(utf8.decode(KeyEncoder.encodePaste('hello', 0)), 'hello');
    });

    test('換行正規化成 CR', () {
      expect(utf8.decode(KeyEncoder.encodePaste('a\r\nb\nc', 0)), 'a\rb\rc');
    });

    test('移除內嵌的結束標記,避免被截斷後半段當成指令', () {
      final out = utf8.decode(
        KeyEncoder.encodePaste('evil\x1b[201~rm -rf /', TermModes.bracketedPaste),
      );
      expect(out, '\x1b[200~evilrm -rf /\x1b[201~');
    });

    test('中文貼上正常編碼', () {
      expect(utf8.decode(KeyEncoder.encodePaste('中文', 0)), '中文');
    });
  });
}
