// Terminal grid 繪製:cell buffer → Canvas。
//
// 繪製策略(Phase 0):
//   1. 背景 pass:同底色的連續 cells 合併成一個 rect。
//   2. 文字 pass:同樣式的連續 cells 合併成一個 paragraph;
//      **遇到寬字元(CJK)就斷開並單獨定位** —— 不能把中文和 ASCII 併進同一個
//      paragraph,否則字距由字型 advance 決定,會偏離 cell 網格。
//   3. 游標與 IME 組字(preedit)疊在最上層。
//
// Phase 1 會換成字形 atlas(預先 rasterize + drawAtlas),這裡先確保「正確」。

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'ime.dart';
import 'selection.dart';
import 'term_ffi.dart';

/// 等寬字型設定與量出來的 cell 尺寸。
class TerminalStyle {
  TerminalStyle({
    this.fontFamily,
    List<String>? fontFamilyFallback,
    this.fontSize = 14.0,
    this.lineHeight = 1.2,
  }) : fontFamilyFallback = fontFamilyFallback ?? defaultFallback {
    _measure();
  }

  /// 跨平台等寬字型候選:Windows / macOS / Linux 各挑得到一個,
  /// 後面接 CJK 字型,確保中文不會變成豆腐方塊。
  static const defaultFallback = <String>[
    'Cascadia Mono', // Windows 11 內建
    'Consolas', // Windows
    'SF Mono', // macOS
    'Menlo', // macOS
    'DejaVu Sans Mono', // Linux
    'Noto Sans Mono',
    'monospace',
    // CJK fallback
    'Microsoft JhengHei',
    'Microsoft YaHei',
    'PingFang TC',
    'Noto Sans Mono CJK TC',
    'Noto Sans CJK TC',
  ];

  final String? fontFamily;
  final List<String> fontFamilyFallback;
  final double fontSize;
  final double lineHeight;

  late final double cellWidth;
  late final double cellHeight;

  void _measure() {
    final tp = TextPainter(
      text: TextSpan(text: 'M', style: textStyle()),
      textDirection: TextDirection.ltr,
    )..layout();
    cellWidth = tp.width;
    cellHeight = tp.height;
  }

  TextStyle textStyle({
    Color color = const Color(0xFFD8D8D8),
    int flags = 0,
  }) => TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: fontSize,
    height: lineHeight,
    color: color,
    fontWeight: (flags & CellFlags.bold) != 0
        ? FontWeight.bold
        : FontWeight.normal,
    fontStyle: (flags & CellFlags.italic) != 0
        ? FontStyle.italic
        : FontStyle.normal,
    decoration: _decoration(flags),
    decorationColor: color,
  );

  static TextDecoration? _decoration(int flags) {
    final underline = (flags & CellFlags.underline) != 0;
    final strike = (flags & CellFlags.strikeout) != 0;
    if (underline && strike) {
      return TextDecoration.combine([
        TextDecoration.underline,
        TextDecoration.lineThrough,
      ]);
    }
    if (underline) return TextDecoration.underline;
    if (strike) return TextDecoration.lineThrough;
    return null;
  }
}

/// 一幀的繪製輸入。
class TermFrame {
  const TermFrame({
    required this.cells,
    required this.cols,
    required this.rows,
    required this.cursorRow,
    required this.cursorCol,
    required this.cursorVisible,
    required this.composing,
    required this.focused,
    this.selection,
    this.urlSpans = const [],
  });

  final Uint32List? cells;
  final int cols;
  final int rows;
  final int cursorRow;
  final int cursorCol;
  final bool cursorVisible;
  final ComposingState composing;
  final bool focused;

  /// 滑鼠反白選取範圍(null = 無選取)。
  final TermSelection? selection;

  /// 指標按著修飾鍵停在上面的那個網址所佔的 cell(空 = 不畫底線)。
  /// 折行的網址會有多段,一列一段。
  final List<CellSpan> urlSpans;
}

class TermPainter extends CustomPainter {
  TermPainter({
    required this.frame,
    required this.style,
    required Listenable repaint,
    this.background = const Color(0xFF181818),
    this.foreground = const Color(0xFFD8D8D8),
    this.cursorColor = const Color(0xFFD8D8D8),
    this.selectionColor = const Color(0xFF2E4F72),
    this.onPaintTime,
  }) : super(repaint: repaint);

  final TermFrame Function() frame;
  final TerminalStyle style;
  final Color background;
  final Color foreground;
  final Color cursorColor;
  final Color selectionColor;
  final void Function(double milliseconds)? onPaintTime;

  @override
  void paint(Canvas canvas, Size size) {
    final sw = Stopwatch()..start();
    canvas.drawRect(Offset.zero & size, Paint()..color = background);

    final f = frame();
    final grid = f.cells;
    if (grid == null) return;

    final cw = style.cellWidth;
    final ch = style.cellHeight;
    final bgDefault = background.toARGB32() & 0xFFFFFF;

    _paintBackgrounds(canvas, grid, f, cw, ch, bgDefault);
    _paintSelection(canvas, f, cw, ch);
    _paintText(canvas, grid, f, cw, ch);
    _paintUrlUnderline(canvas, f, cw, ch);
    _paintCursorAndComposing(canvas, f, cw, ch);

    onPaintTime?.call(sw.elapsedMicroseconds / 1000.0);
  }

  void _paintBackgrounds(
    Canvas canvas,
    Uint32List grid,
    TermFrame f,
    double cw,
    double ch,
    int bgDefault,
  ) {
    final paint = Paint();
    for (var row = 0; row < f.rows; row++) {
      var runStart = 0;
      var runBg = -1;
      for (var col = 0; col <= f.cols; col++) {
        // col == cols 是哨兵,用來收掉最後一段 run
        final base = (row * f.cols + col) * 4;
        final inverse =
            col < f.cols && (grid[base + 3] & CellFlags.inverse) != 0;
        final bg = col < f.cols
            ? (inverse ? grid[base + 1] : grid[base + 2])
            : -1;
        if (bg != runBg) {
          if (runBg >= 0 && runBg != bgDefault) {
            paint.color = Color(0xFF000000 | runBg);
            canvas.drawRect(
              Rect.fromLTWH(runStart * cw, row * ch, (col - runStart) * cw, ch),
              paint,
            );
          }
          runStart = col;
          runBg = bg;
        }
      }
    }
  }

  /// 反白選取:畫在背景之上、文字之下,文字顏色不變仍可讀。
  void _paintSelection(Canvas canvas, TermFrame f, double cw, double ch) {
    final sel = f.selection;
    if (sel == null || sel.isCollapsed) return;
    final s = sel.start;
    final e = sel.end;
    final paint = Paint()..color = selectionColor;
    for (var row = s.row; row <= e.row; row++) {
      if (row < 0 || row >= f.rows) continue;
      final c0 = (row == s.row ? s.col : 0).clamp(0, f.cols - 1);
      final c1 = (row == e.row ? e.col : f.cols - 1).clamp(0, f.cols - 1);
      canvas.drawRect(
        Rect.fromLTWH(c0 * cw, row * ch, (c1 - c0 + 1) * cw, ch),
        paint,
      );
    }
  }

  void _paintText(
    Canvas canvas,
    Uint32List grid,
    TermFrame f,
    double cw,
    double ch,
  ) {
    final buffer = StringBuffer();
    for (var row = 0; row < f.rows; row++) {
      var runStartCol = 0;
      var runFg = -1;
      var runFlags = -1;

      void flush() {
        if (buffer.isEmpty) return;
        final text = buffer.toString();
        buffer.clear();
        if (runFg < 0 || text.trim().isEmpty) return;
        _drawRun(
          canvas,
          text,
          Offset(runStartCol * cw, row * ch),
          Color(0xFF000000 | runFg),
          runFlags,
        );
      }

      for (var col = 0; col < f.cols; col++) {
        final base = (row * f.cols + col) * 4;
        final flags = grid[base + 3];
        if (flags & CellFlags.wideCharSpacer != 0) continue; // 寬字元的第二格
        if (flags & CellFlags.hidden != 0) continue;

        final cp = grid[base];
        final inverse = (flags & CellFlags.inverse) != 0;
        final fg = inverse ? grid[base + 2] : grid[base + 1];

        // 寬字元單獨畫:併進 run 會讓後續字元偏離 cell 網格
        if (flags & CellFlags.wideChar != 0) {
          flush();
          if (cp != 0 && cp != 0x20) {
            canvas.drawParagraph(
              _cachedGlyph(cp, fg, flags),
              Offset(col * cw, row * ch),
            );
          }
          runFg = -1;
          runFlags = -1;
          continue;
        }

        if (fg != runFg || flags != runFlags) {
          flush();
          runStartCol = col;
          runFg = fg;
          runFlags = flags;
        }
        buffer.writeCharCode(cp == 0 ? 0x20 : cp);
      }
      flush();
    }
  }

  /// 單一寬字元的 paragraph 快取。
  ///
  /// CJK 文字每個字都得單獨 layout,一整面可能上千次;但實際出現的
  /// (字, 顏色, 樣式) 組合遠少於 cell 數,快取後重畫幾乎免費。
  /// 這是 Phase 1 字形 atlas 之前的過渡方案。
  static final _glyphCache = <(int, int, int), ui.Paragraph>{};
  static const _glyphCacheMax = 4096;

  ui.Paragraph _cachedGlyph(int codePoint, int fg, int flags) {
    final key = (codePoint, fg, flags);
    final hit = _glyphCache[key];
    if (hit != null) return hit;
    if (_glyphCache.length >= _glyphCacheMax) _glyphCache.clear();
    return _glyphCache[key] = _buildParagraph(
      String.fromCharCode(codePoint),
      Color(0xFF000000 | fg),
      flags,
    );
  }

  ui.Paragraph _buildParagraph(String text, Color color, int flags) {
    final dim = (flags & CellFlags.dim) != 0;
    final effective = dim ? color.withValues(alpha: 0.65) : color;
    final builder =
        ui.ParagraphBuilder(
            ui.ParagraphStyle(
              textDirection: TextDirection.ltr,
              maxLines: 1,
              fontFamily: style.fontFamily,
              fontSize: style.fontSize,
              height: style.lineHeight,
            ),
          )
          ..pushStyle(
            style.textStyle(color: effective, flags: flags).getTextStyle(),
          )
          ..addText(text);
    return builder.build()
      ..layout(const ui.ParagraphConstraints(width: double.infinity));
  }

  void _drawRun(
    Canvas canvas,
    String text,
    Offset offset,
    Color color,
    int flags,
  ) => canvas.drawParagraph(_buildParagraph(text, color, flags), offset);

  /// 按著修飾鍵停在網址上時畫的虛底線,告訴使用者「這裡點得開」。
  /// 畫在文字之後、游標之前:蓋不到游標,也不會被文字覆蓋。
  void _paintUrlUnderline(Canvas canvas, TermFrame f, double cw, double ch) {
    if (f.urlSpans.isEmpty) return;
    final paint = Paint()..color = foreground;
    // 虛線:Canvas 沒有 dash pattern,自己一段一段畫
    const dash = 3.0;
    const gap = 2.0;
    for (final span in f.urlSpans) {
      final y = (span.row + 1) * ch - 2.0;
      final right = (span.endCol + 1) * cw;
      var x = span.startCol * cw;
      while (x < right) {
        final segEnd = x + dash < right ? x + dash : right;
        canvas.drawRect(Rect.fromLTRB(x, y, segEnd, y + 1.0), paint);
        x = segEnd + gap;
      }
    }
  }

  void _paintCursorAndComposing(
    Canvas canvas,
    TermFrame f,
    double cw,
    double ch,
  ) {
    final composing = f.composing;
    final cursorX = f.cursorCol * cw;
    final cursorY = f.cursorRow * ch;

    if (composing.isNotEmpty) {
      // IME 組字中:在游標處畫出未確認的文字(反白 + 底線),
      // 讓使用者看得到自己正在打什麼。
      final paragraph = _composingParagraph(composing.text);
      final width = paragraph.maxIntrinsicWidth;
      final rect = Rect.fromLTWH(cursorX, cursorY, width, ch);
      final caretX = _composingCaretX(
        paragraph,
        composing.text,
        composing.cursorOffset,
      );
      canvas
        ..drawRect(rect, Paint()..color = background)
        ..drawRect(
          rect,
          Paint()
            ..color = cursorColor.withValues(alpha: 0.25)
            ..style = PaintingStyle.fill,
        );
      // 輸入法選住的那個字(注音回頭改字)要比其他組字文字更明顯。底色得在
      // 文字之前畫,不然會把字蓋掉。
      if (composing.selectionLength > 0) {
        final selEnd = _composingCaretX(
          paragraph,
          composing.text,
          composing.cursorOffset + composing.selectionLength,
        );
        canvas.drawRect(
          Rect.fromLTRB(
            cursorX + caretX,
            cursorY,
            cursorX + selEnd,
            cursorY + ch,
          ),
          Paint()..color = cursorColor.withValues(alpha: 0.4),
        );
      }
      canvas
        ..drawParagraph(paragraph, Offset(cursorX, cursorY))
        ..drawRect(
          Rect.fromLTWH(cursorX, cursorY + ch - 1.5, width, 1.5),
          Paint()..color = cursorColor,
        )
        // 組字區內的 IME 游標。沒有它,注音按 ←/→ 回頭改字時整段組字看起來
        // 一模一樣,使用者看不出現在停在哪個字上。
        ..drawRect(
          Rect.fromLTWH(
            cursorX + (caretX >= width ? width - _caretWidth : caretX),
            cursorY,
            _caretWidth,
            ch,
          ),
          Paint()..color = cursorColor,
        );
      return;
    }

    if (!f.cursorVisible) return;
    final rect = Rect.fromLTWH(cursorX, cursorY, cw, ch);
    if (f.focused) {
      canvas.drawRect(rect, Paint()..color = cursorColor.withValues(alpha: 0.7));
    } else {
      // 失焦:空心游標(和主流終端一致)
      canvas.drawRect(
        rect.deflate(0.5),
        Paint()
          ..color = cursorColor.withValues(alpha: 0.7)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0,
      );
    }
  }

  ui.Paragraph _composingParagraph(String text) =>
      _buildParagraph(text, foreground, 0);

  static const _caretWidth = 2.0;

  /// 組字文字內第 [offset] 個 code unit 的左緣 x(相對 preedit 起點)。
  /// CJK 是全寬、注音符號半寬,不能用「offset × 字元寬」硬算,要問 paragraph。
  double _composingCaretX(ui.Paragraph paragraph, String text, int offset) {
    final safe = offset.clamp(0, text.length);
    if (safe <= 0) return 0;
    final boxes = paragraph.getBoxesForRange(0, safe);
    return boxes.isEmpty ? 0 : boxes.last.right;
  }

  @override
  bool shouldRepaint(covariant TermPainter oldDelegate) =>
      !identical(oldDelegate.style, style);
}
