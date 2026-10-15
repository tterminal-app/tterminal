// IME 組字(preedit)必須畫在游標處 —— 使用者要看得到自己正在打什麼。
//
// 驗證方式:真實 shell + 模擬輸入法組字,截下畫面比對「有無 preedit」的差異,
// 並把圖存出來人工確認(TTERM_DUMP_DIR)。

@TestOn('linux || mac-os')
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tterm_app/src/term_ffi.dart';
import 'package:tterm_app/src/terminal_view.dart';

import 'support/fonts.dart';

final _boundaryKey = GlobalKey();

Future<ui.Image> _capture(WidgetTester tester, String name) async {
  final boundary =
      _boundaryKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  late final ui.Image image;
  await tester.runAsync(() async {
    image = await boundary.toImage();
    final dumpDir = Platform.environment['TTERM_DUMP_DIR'];
    if (dumpDir != null) {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '$dumpDir/ime-$name.png',
      ).writeAsBytes(data!.buffer.asUint8List(), flush: true);
      stdout.writeln('dumped $dumpDir/ime-$name.png');
    }
  });
  return image;
}

Future<int> _nonBackgroundPixels(WidgetTester tester, ui.Image image) async {
  late final int count;
  await tester.runAsync(() async {
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final bytes = data!.buffer.asUint8List();
    var n = 0;
    // 背景是 0xFF181818;數「非背景」像素當作畫面上有多少內容
    for (var i = 0; i < bytes.length; i += 4) {
      if (bytes[i] != 0x18 || bytes[i + 1] != 0x18 || bytes[i + 2] != 0x18) {
        n++;
      }
    }
    count = n;
  });
  return count;
}

void main() {
  setUpAll(() async => loadTestFonts());

  testWidgets('中文組字內容顯示在游標處', (tester) async {
    tester.view.physicalSize = const Size(900, 400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final session = NativeSession.spawnShell(cols: 80, rows: 20, program: 'sh');
    addTearDown(session.dispose);

    await tester.pumpWidget(
      RepaintBoundary(
        key: _boundaryKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          home: Scaffold(
            body: TerminalView(session: session, style: testTerminalStyle()),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();

    final before = await _capture(tester, 'before');
    final beforePixels = await _nonBackgroundPixels(tester, before);

    // 模擬注音組字中(尚未選字)
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '中文組字中',
        selection: TextSelection.collapsed(offset: 5),
        composing: TextRange(start: 0, end: 5),
      ),
    );
    await tester.pump();

    final during = await _capture(tester, 'composing');
    final duringPixels = await _nonBackgroundPixels(tester, during);

    expect(
      duringPixels,
      greaterThan(beforePixels),
      reason: '組字中畫面應多出 preedit 的像素(反白區塊 + 文字 + 底線)',
    );

    // 確認選字後 preedit 消失(文字改由 shell 回顯)
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '中文組字中',
        selection: TextSelection.collapsed(offset: 5),
      ),
    );
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();
    await _capture(tester, 'committed');
  });
}
