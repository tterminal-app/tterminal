// 滑鼠事件 → PTY bytes(xterm 滑鼠回報協定)。
//
// 當應用程式(tmux/vim/htop…)開啟滑鼠回報模式(DECSET 1000/1002/1003,
// SGR 1006)時,終端要把點擊/拖曳/滾輪編碼成 escape 序列送進 PTY,而不是
// 拿去做本地反白。編碼有兩種:
//   * SGR(1006):`CSI < Cb ; col ; row (M|m)`,M=按下、m=放開;座標 1-based。
//   * 傳統(X10/normal):`CSI M` + 三個 byte(Cb+32、col+1+32、row+1+32),
//     放開一律用按鈕碼 3(傳統模式下按鈕號會遺失);col>223 會爆,所以才有 SGR。
//
// 按鈕碼:左=0 中=1 右=2;滾輪上=64 下=65;motion 額外 +32;
// 修飾鍵:Shift +4、Alt/Meta +8、Ctrl +16。

import 'dart:typed_data';

import 'term_ffi.dart' show TermModes;

abstract final class MouseButton {
  static const left = 0;
  static const middle = 1;
  static const right = 2;
  static const wheelUp = 64;
  static const wheelDown = 65;
  /// 傳統模式「放開」的按鈕碼(按鈕號遺失)。
  static const releaseLegacy = 3;
}

class MouseEncoder {
  /// 這些模式下是否有任何滑鼠回報開啟。
  static bool reportingEnabled(int modes) =>
      modes &
          (TermModes.mouseReportClick |
              TermModes.mouseDrag |
              TermModes.mouseMotion) !=
      0;

  /// 是否要回報「移動」事件:
  ///   * 1003(mouseMotion):任何移動都報。
  ///   * 1002(mouseDrag):只在有按鈕按著時報(呼叫端保證 buttonHeld)。
  static bool reportsMotion(int modes, {required bool buttonHeld}) {
    if (modes & TermModes.mouseMotion != 0) return true;
    if (modes & TermModes.mouseDrag != 0 && buttonHeld) return true;
    return false;
  }

  /// 編碼一個滑鼠事件。回傳要送進 PTY 的 bytes;null = 此事件不回報。
  ///
  /// [col]/[row] 是 0-based cell 座標。[press] 對放開事件為 false。
  /// [motion] 標示這是移動事件(會設 motion bit)。
  static Uint8List? encode({
    required int button,
    required int col,
    required int row,
    required bool press,
    required bool motion,
    required int modes,
    bool shift = false,
    bool alt = false,
    bool ctrl = false,
  }) {
    if (!reportingEnabled(modes)) return null;

    var cb = button;
    if (motion) cb += 32; // motion bit(0x20)
    if (shift) cb += 4;
    if (alt) cb += 8;
    if (ctrl) cb += 16;

    final sgr = modes & TermModes.sgrMouse != 0;
    if (sgr) {
      final finalChar = press ? 'M' : 'm';
      final s = '\x1b[<$cb;${col + 1};${row + 1}$finalChar';
      return Uint8List.fromList(s.codeUnits);
    }

    // 傳統 X10/normal:放開用按鈕碼 3(+ 保留 motion/modifier bits)。
    var legacyCb = cb;
    if (!press && button < MouseButton.wheelUp) {
      legacyCb = MouseButton.releaseLegacy + (cb - button); // 保留 motion/mod bits
    }
    // 座標 byte 上限 255(cell 值太大就夾住,避免送出無效 byte)
    int clampByte(int v) => v.clamp(0, 255 - 32) + 32 + 1;
    return Uint8List.fromList([
      0x1b,
      0x5b, // [
      0x4d, // M
      (legacyCb + 32).clamp(0, 255),
      clampByte(col),
      clampByte(row),
    ]);
  }
}
