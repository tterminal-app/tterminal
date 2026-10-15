// 反白選取:模型 / 文字抽取單元測試 + 「拖曳 → 放開自動複製」widget 測試。

import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tterm_app/src/selection.dart';
import 'package:tterm_app/src/term_ffi.dart';
import 'package:tterm_app/src/terminal_view.dart';

import 'support/fonts.dart';

Uint32List _grid(int cols, int rows) => Uint32List(cols * rows * 4);

void _put(
  Uint32List g,
  int cols,
  int row,
  int col,
  String text, {
  int flags = 0,
}) {
  var c = col;
  for (final cp in text.runes) {
    final base = (row * cols + c) * 4;
    g[base] = cp;
    g[base + 3] = flags;
    c++;
  }
}

/// 放一個 CJK 寬字元:本體 + 佔位格。
void _putWide(Uint32List g, int cols, int row, int col, String ch) {
  final base = (row * cols + col) * 4;
  g[base] = ch.runes.first;
  g[base + 3] = CellFlags.wideChar;
  final spacer = (row * cols + col + 1) * 4;
  g[spacer] = 0;
  g[spacer + 3] = CellFlags.wideCharSpacer;
}

void main() {
  // testWidgets 內是 FakeAsync,loadTestFonts 的真實檔案 I/O 會永遠卡住
  // (macOS 有 Menlo 必踩;Linux 常因路徑不存在而僥倖跳過),只能放 setUpAll。
  setUpAll(() async => loadTestFonts());

  group('TermSelection', () {
    test('反向拖曳:start/end 自動正規化', () {
      const sel = TermSelection(CellPos(3, 5), CellPos(1, 2));
      expect(sel.start, const CellPos(1, 2));
      expect(sel.end, const CellPos(3, 5));
      expect(sel.isCollapsed, isFalse);
    });

    test('contains:行式範圍,中間行整行都算', () {
      const sel = TermSelection(CellPos(1, 4), CellPos(3, 2));
      expect(sel.contains(0, 9), isFalse); // 範圍之前
      expect(sel.contains(1, 3), isFalse); // 首行、start 之前
      expect(sel.contains(1, 4), isTrue); // 首行 start
      expect(sel.contains(2, 0), isTrue); // 中間行整行
      expect(sel.contains(2, 99), isTrue);
      expect(sel.contains(3, 2), isTrue); // 末行 end
      expect(sel.contains(3, 3), isFalse); // 末行、end 之後
      expect(sel.contains(4, 0), isFalse); // 範圍之後
    });

    test('同一行選取只涵蓋 col 區間', () {
      const sel = TermSelection(CellPos(2, 3), CellPos(2, 6));
      expect(sel.contains(2, 2), isFalse);
      expect(sel.contains(2, 3), isTrue);
      expect(sel.contains(2, 6), isTrue);
      expect(sel.contains(2, 7), isFalse);
    });
  });

  group('extractSelectionText', () {
    test('單行:空 cell 當空白、行尾空白剔除', () {
      final g = _grid(10, 3);
      _put(g, 10, 0, 2, 'hi');
      const sel = TermSelection(CellPos(0, 0), CellPos(0, 9));
      expect(extractSelectionText(g, 10, 3, sel), '  hi');
    });

    test('跨行:中間行選滿、以換行相接', () {
      final g = _grid(8, 4);
      _put(g, 8, 0, 4, 'AB');
      _put(g, 8, 1, 0, 'middle');
      _put(g, 8, 2, 0, 'CD');
      const sel = TermSelection(CellPos(0, 4), CellPos(2, 1));
      expect(extractSelectionText(g, 8, 4, sel), 'AB\nmiddle\nCD');
    });

    test('CJK 寬字元只取一次(跳過佔位格)', () {
      final g = _grid(10, 2);
      _putWide(g, 10, 0, 0, '中');
      _putWide(g, 10, 0, 2, '文');
      _put(g, 10, 0, 4, 'ok');
      const sel = TermSelection(CellPos(0, 0), CellPos(0, 5));
      expect(extractSelectionText(g, 10, 2, sel), '中文ok');
    });

    test('反向拖曳抽取結果相同', () {
      final g = _grid(8, 2);
      _put(g, 8, 0, 0, 'abcd');
      const forward = TermSelection(CellPos(0, 1), CellPos(0, 2));
      const backward = TermSelection(CellPos(0, 2), CellPos(0, 1));
      expect(extractSelectionText(g, 8, 2, forward), 'bc');
      expect(extractSelectionText(g, 8, 2, backward), 'bc');
    });

    test('範圍越界自動夾住,不會丟例外', () {
      final g = _grid(4, 2);
      _put(g, 4, 1, 0, 'xy');
      const sel = TermSelection(CellPos(-1, -5), CellPos(9, 99));
      expect(extractSelectionText(g, 4, 2, sel), '\nxy');
    });
  });

  testWidgets('拖曳反白 → 放開自動寫入剪貼簿', (tester) async {
    final captured = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          captured.add((call.arguments as Map<Object?, Object?>)['text']! as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    final session = NativeSession.headless(cols: 40, rows: 12);
    addTearDown(session.dispose);
    final style = testTerminalStyle();

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: TerminalView(session: session, style: style),
        ),
      ),
    );
    await tester.pump(); // postFrame 的 viewport resize
    session.demoFeed(DemoScenario.plain, 20000);
    await tester.pump(const Duration(milliseconds: 32)); // ticker 撿 damage

    final origin = tester.getTopLeft(find.byType(TerminalView));
    Offset cellCenter(int row, int col) =>
        origin +
        Offset((col + 0.5) * style.cellWidth, (row + 0.5) * style.cellHeight);

    const from = CellPos(1, 1);
    const to = CellPos(2, 8);
    final gesture = await tester.startGesture(
      cellCenter(from.row, from.col),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await gesture.moveTo(cellCenter(to.row, to.col));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    final expected = extractSelectionText(
      session.copyGrid(),
      session.cols,
      session.rows,
      const TermSelection(from, to),
    );
    expect(expected, isNotEmpty, reason: 'demo feed 後選取範圍應該有內容');
    expect(captured, hasLength(1), reason: '放開滑鼠應該複製一次');
    expect(captured.single, expected);
    expect(captured.single, contains('\n'), reason: '跨行選取應含換行');

    // 單擊(無拖曳)清除選取且不再複製
    final tap = await tester.startGesture(
      cellCenter(0, 0),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await tap.up();
    await tester.pump();
    expect(captured, hasLength(1));
  });
}
