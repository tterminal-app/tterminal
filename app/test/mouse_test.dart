// 滑鼠回報編碼(xterm 協定)測試。

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tterm_app/src/mouse.dart';
import 'package:tterm_app/src/term_ffi.dart';

String? enc({
  required int button,
  required int col,
  required int row,
  required bool press,
  bool motion = false,
  required int modes,
  bool shift = false,
  bool alt = false,
  bool ctrl = false,
}) {
  final b = MouseEncoder.encode(
    button: button,
    col: col,
    row: row,
    press: press,
    motion: motion,
    modes: modes,
    shift: shift,
    alt: alt,
    ctrl: ctrl,
  );
  return b == null ? null : latin1.decode(b);
}

void main() {
  const click = TermModes.mouseReportClick;
  const drag = TermModes.mouseDrag;
  const motionMode = TermModes.mouseMotion;
  const sgr = TermModes.sgrMouse;

  test('沒開任何滑鼠模式 → 不回報(null)', () {
    expect(enc(button: 0, col: 5, row: 3, press: true, modes: 0), isNull);
  });

  group('SGR(1006)編碼', () {
    test('左鍵按下:CSI < 0 ; col+1 ; row+1 M', () {
      // tmux 常見:1002 + 1006
      expect(
        enc(button: 0, col: 4, row: 2, press: true, modes: drag | sgr),
        '\x1b[<0;5;3M',
      );
    });

    test('放開用小寫 m,按鈕碼保留', () {
      expect(
        enc(button: 0, col: 4, row: 2, press: false, modes: drag | sgr),
        '\x1b[<0;5;3m',
      );
    });

    test('右鍵、中鍵', () {
      expect(enc(button: 2, col: 0, row: 0, press: true, modes: click | sgr), '\x1b[<2;1;1M');
      expect(enc(button: 1, col: 0, row: 0, press: true, modes: click | sgr), '\x1b[<1;1;1M');
    });

    test('拖曳(motion bit +32)', () {
      expect(
        enc(button: 0, col: 9, row: 5, press: true, motion: true, modes: drag | sgr),
        '\x1b[<32;10;6M', // 0 + 32
      );
    });

    test('滾輪上下(64/65)', () {
      expect(enc(button: 64, col: 3, row: 1, press: true, modes: click | sgr), '\x1b[<64;4;2M');
      expect(enc(button: 65, col: 3, row: 1, press: true, modes: click | sgr), '\x1b[<65;4;2M');
    });

    test('修飾鍵:Shift+4 / Alt+8 / Ctrl+16', () {
      expect(
        enc(button: 0, col: 0, row: 0, press: true, modes: click | sgr, ctrl: true),
        '\x1b[<16;1;1M',
      );
      expect(
        enc(button: 0, col: 0, row: 0, press: true, modes: click | sgr, shift: true, alt: true),
        '\x1b[<12;1;1M', // 4 + 8
      );
    });
  });

  group('傳統(X10)編碼', () {
    test('左鍵按下:CSI M + (Cb+32, col+33, row+33)', () {
      final s = enc(button: 0, col: 4, row: 2, press: true, modes: click);
      expect(s, isNotNull);
      final bytes = latin1.encode(s!);
      expect(bytes[0], 0x1b);
      expect(bytes[1], 0x5b); // [
      expect(bytes[2], 0x4d); // M
      expect(bytes[3], 0 + 32); // button 0 + 32
      expect(bytes[4], 4 + 1 + 32); // col
      expect(bytes[5], 2 + 1 + 32); // row
    });

    test('放開用按鈕碼 3', () {
      final bytes = latin1.encode(enc(button: 0, col: 4, row: 2, press: false, modes: click)!);
      expect(bytes[3], 3 + 32); // release button code
    });
  });

  group('reportsMotion', () {
    test('1003 任何移動都報', () {
      expect(MouseEncoder.reportsMotion(motionMode, buttonHeld: false), isTrue);
    });
    test('1002 只在按鈕按著時報', () {
      expect(MouseEncoder.reportsMotion(drag, buttonHeld: true), isTrue);
      expect(MouseEncoder.reportsMotion(drag, buttonHeld: false), isFalse);
    });
    test('只有 1000(click)不報移動', () {
      expect(MouseEncoder.reportsMotion(click, buttonHeld: true), isFalse);
    });
  });
}
