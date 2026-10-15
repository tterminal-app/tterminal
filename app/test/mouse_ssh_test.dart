// 滑鼠回報端對端(Dart TerminalView → FFI → SSH → test_sshd):
//
// 驗證使用者回報的 bug:「tmux mouse on 時點擊/拖曳/滾輪沒反應」。
// test_sshd 的 shell banner 會送 \x1b[?1002h\x1b[?1006h(等同 tmux mouse on),
// 讓引擎把滑鼠模式打開;然後在 TerminalView 上注入指標事件,server 端把收到的
// 控制字元以可見的 <xx> 回聲,於是我們能在 grid 上看到送出去的 SGR 滑鼠序列。
//
// 需要 TTERM_TEST_SSHD 指向 test_sshd 執行檔;未設定則整個 group skip。
//
// 注意:connectSsh 用 Isolate.run(真實 isolate),而 SSH reader 是獨立的原生
// thread——這些「真實非同步」在 testWidgets 的 FakeAsync 區裡不會前進,所以凡是
// 碰到真實非同步(連線、等 server 回聲)都必須包在 tester.runAsync 裡。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tterm_app/src/mouse.dart';
import 'package:tterm_app/src/term_ffi.dart';
import 'package:tterm_app/src/terminal_view.dart';

import 'support/fonts.dart';

/// 啟動 test_sshd,回傳 (process, port)。
Future<(Process, int)> _startSshd(String exe) async {
  final proc = await Process.start(exe, const []);
  final portCompleter = Completer<int>();
  proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
    if (line.startsWith('PORT=') && !portCompleter.isCompleted) {
      portCompleter.complete(int.parse(line.substring(5).trim()));
    }
  });
  final port = await portCompleter.future.timeout(const Duration(seconds: 10));
  return (proc, port);
}

/// 把 native grid 還原成一整片文字。
String screenText(NativeSession session) {
  final grid = session.copyGrid();
  final buf = StringBuffer();
  for (var row = 0; row < session.rows; row++) {
    for (var col = 0; col < session.cols; col++) {
      final base = (row * session.cols + col) * 4;
      final flags = grid[base + 3];
      if (flags & CellFlags.wideCharSpacer != 0) continue;
      final cp = grid[base];
      buf.writeCharCode(cp == 0 ? 0x20 : cp);
    }
    buf.write('\n');
  }
  return buf.toString();
}

/// 用真實時間輪詢直到條件成立(SSH reader 是獨立的原生 thread,要讓真實時間流動)。
Future<bool> _pumpUntil(
  WidgetTester tester,
  bool Function() done, {
  Duration timeout = const Duration(seconds: 8),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (done()) return true;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }
  return done();
}

void main() {
  final sshd = Platform.environment['TTERM_TEST_SSHD'];

  setUpAll(() async => loadTestFonts());

  group('滑鼠回報端對端(需 TTERM_TEST_SSHD)', () {
    late Process proc;
    late int port;

    setUp(() async {
      (proc, port) = await _startSshd(sshd!);
    });

    tearDown(() {
      proc.kill();
    });

    /// 連線(在真實 isolate 上)、掛好 dispose、pump 出 TerminalView、
    /// 等 banner 把滑鼠模式打開。回傳已就緒的 session。
    Future<NativeSession> ready(WidgetTester tester) async {
      final session = (await tester.runAsync(() => NativeSession.connectSsh(
                config: {
                  'host': '127.0.0.1',
                  'port': port,
                  'username': 'tester',
                  'auth': {'method': 'password', 'password': 'secret-123'},
                },
                cols: 80,
                rows: 24,
              )))!;
      addTearDown(() => tester.runAsync(() async => session.dispose()));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(
              session: session,
              style: testTerminalStyle(),
              autofocus: true,
            ),
          ),
        ),
      );
      await tester.pump();

      final gotMode =
          await _pumpUntil(tester, () => session.modes & TermModes.sgrMouse != 0);
      expect(gotMode, isTrue,
          reason: 'SSH banner 應把 1006 SGR 滑鼠模式打開,但 modes=${session.modes}');
      return session;
    }

    testWidgets('SSH 送 mouse-enable → 引擎打開滑鼠模式', (tester) async {
      final session = await ready(tester);
      expect(session.modes & TermModes.mouseDrag, isNot(0),
          reason: '1002 button-event tracking 應該打開');
      expect(session.modes & TermModes.sgrMouse, isNot(0),
          reason: '1006 SGR 編碼應該打開');
      expect(MouseEncoder.reportingEnabled(session.modes), isTrue);
    });

    testWidgets('點擊終端 → 送出 SGR 滑鼠回報(server 收到)', (tester) async {
      final session = await ready(tester);

      // 在終端某個 cell 上點一下(down+up)。tapAt 用左鍵。
      final origin = tester.getTopLeft(find.byType(TerminalView));
      final style = testTerminalStyle();
      await tester.tapAt(
          origin + Offset(style.cellWidth * 3 + 2, style.cellHeight * 2 + 2));
      await tester.pump();

      // server 把送進來的控制字元以 <xx> 回聲 → grid 應出現 SGR 左鍵回報。
      // ESC 變成 "<1b>",所以會看到像 "<1b>[<0;4;3M<1b>[<0;4;3m"。
      final saw =
          await _pumpUntil(tester, () => screenText(session).contains('[<0;'));
      final screen = screenText(session);
      expect(saw, isTrue,
          reason: '應看到 SGR 左鍵回報序列 CSI < 0 ;…:\n$screen');
      expect(screen, contains('M'), reason: '按下應以大寫 M 結尾');
    });

    testWidgets('滾輪 → 送出滾輪回報(button 64/65)', (tester) async {
      final session = await ready(tester);

      final center = tester.getCenter(find.byType(TerminalView));
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(pointer.hover(center));
      // 往下捲(scrollDelta.dy > 0)→ wheelDown = button 65
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 60)));
      await tester.pump();

      final saw =
          await _pumpUntil(tester, () => screenText(session).contains('[<65;'));
      final screen = screenText(session);
      expect(saw, isTrue,
          reason: '往下捲應送 wheelDown(button 65):\n$screen');
    });
  }, skip: sshd == null ? 'TTERM_TEST_SSHD 未設定' : false);
}
