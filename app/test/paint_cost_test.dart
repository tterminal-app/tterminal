// 繪製成本量測:每 frame 在 Dart 端建 display list 的時間。
//
// 注意這量的是「錄製」成本(TermPainter.paint 內的工作),不含 GPU 光柵化;
// flutter_tester 是軟體渲染,真實 fps 要在實體桌面跑 app 看 HUD。
// 這裡的用途是防止渲染邏輯改動造成成本暴增(以及決定何時該上字形 atlas)。
// 標成 perf:機器忙的時候計時會超標,CI 用 --exclude-tags perf 跳過,本機照常跑。
@Tags(['perf'])
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tterm_app/src/demo_page.dart';
import 'package:tterm_app/src/term_ffi.dart';
import 'package:tterm_app/src/terminal_view.dart';

import 'support/fonts.dart';

void main() {
  setUpAll(() async => loadTestFonts());

  testWidgets('各 scenario 的 frame 錄製成本', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final results = <String, double>{};

    for (final scenario in [
      DemoScenario.plain,
      DemoScenario.colored,
      DemoScenario.cjk,
      DemoScenario.cursorPaint,
    ]) {
      final session = NativeSession.headless(cols: kDemoCols, rows: kDemoRows);
      addTearDown(session.dispose);

      final samples = <double>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(
              key: ValueKey(scenario),
              session: session,
              style: testTerminalStyle(),
              autofocus: false,
              onPaintTime: samples.add,
            ),
          ),
        ),
      );

      for (var i = 0; i < 20; i++) {
        session.demoFeed(scenario, kDemoBytesPerFrame);
        await tester.pump(const Duration(milliseconds: 16));
      }

      // 丟掉前幾筆(字型 shaping cache 尚未暖機)
      final warm = samples.length > 5 ? samples.sublist(5) : samples;
      final avg = warm.isEmpty
          ? 0.0
          : warm.reduce((a, b) => a + b) / warm.length;
      results[DemoScenario.name(scenario)] = avg;
    }

    stdout.writeln('\n=== TermPainter frame 錄製成本(120x40 grid)===');
    for (final e in results.entries) {
      stdout.writeln(
        '  ${e.key.padRight(16)} ${e.value.toStringAsFixed(2)} ms/frame',
      );
    }
    stdout.writeln(
      '  (16.6ms = 60fps 預算;此值不含 GPU 光柵化)\n',
    );

    for (final e in results.entries) {
      expect(
        e.value,
        lessThan(16.6),
        reason: '${e.key} 的錄製成本已吃掉整個 frame 預算,需要上字形 atlas',
      );
    }
  });
}
