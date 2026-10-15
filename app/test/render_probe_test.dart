// 渲染驗證(headless):pump 真實 frame → RepaintBoundary.toImage → PNG。
//
// 與 golden test 同機制(flutter_tester 軟體 rasterizer),不依賴 X11/GL
// (Xvfb 下 GTK frame clock 不會動,截圖永遠是空的)。
// PNG 輸出目錄:環境變數 TTERM_DUMP_DIR(未設定則只驗證不落檔)。

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tterm_app/src/demo_page.dart';

import 'support/fonts.dart';

final _boundaryKey = GlobalKey();

Future<void> _dump(WidgetTester tester, String name) async {
  final boundary =
      _boundaryKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  late final ui.Image image;
  await tester.runAsync(() async {
    image = await boundary.toImage();
  });
  expect(image.width, greaterThan(1000), reason: '$name 影像尺寸異常');

  final dumpDir = Platform.environment['TTERM_DUMP_DIR'];
  if (dumpDir == null) return;
  await tester.runAsync(() async {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('$dumpDir/probe-$name.png');
    await file.writeAsBytes(data!.buffer.asUint8List(), flush: true);
    stdout.writeln('dumped ${file.path} (${data.lengthInBytes ~/ 1024} KiB)');
  });
}

void main() {
  setUpAll(() async => loadTestFonts());

  testWidgets('四種資料流都能經 FFI 引擎正確渲染', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      RepaintBoundary(
        key: _boundaryKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData.dark(useMaterial3: true),
          home: DemoPage(style: testTerminalStyle()),
        ),
      ),
    );

    // DemoPage 從 colored 開始,每 10 秒(fake time)輪換一次 scenario
    const scenarios = [
      'colored_scroll',
      'cjk_scroll',
      'cursor_paint',
      'plain_scroll',
    ];
    for (final name in scenarios) {
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await _dump(tester, name);
      await tester.pump(const Duration(seconds: 10));
    }
  });
}
