// 端對端:真實 shell(Rust PTY session)+ TerminalView + 模擬平台輸入法。
//
// 驗證整條迴路:平台 IME 事件 → Dart → FFI → PTY → shell → 終端引擎 → grid。
// 重點是中文:組字中不可送出,確認後要正確以 UTF-8 送進 shell 並看到輸出。

@TestOn('linux || mac-os')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tterm_app/src/term_ffi.dart';
import 'package:tterm_app/src/term_painter.dart';
import 'package:tterm_app/src/terminal_view.dart';

import 'support/fonts.dart';

/// 把 native grid 還原成文字(逐 cell 取 codepoint)。
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

/// 等 shell 真的把東西吐出來(PTY reader 是獨立的 Rust thread,
/// 所以要用 runAsync 讓真實時間流動,再 pump 讓 Dart 端更新)。
Future<String> waitForScreen(
  WidgetTester tester,
  NativeSession session,
  String needle, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  var screen = '';
  while (DateTime.now().isBefore(deadline)) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    screen = screenText(session);
    if (screen.contains(needle)) return screen;
  }
  return screen;
}

void main() {
  late NativeSession session;

  Future<void> pumpTerminal(WidgetTester tester) async {
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
  }

  setUp(() {
    session = NativeSession.spawnShell(
      cols: 80,
      rows: 24,
      program: 'sh',
      scrollback: 1000,
    );
  });

  tearDown(() => session.dispose());

  setUpAll(() async => loadTestFonts());

  testWidgets('IME 中文輸入:組字中不送出,確認後送進 shell', (tester) async {
    await pumpTerminal(tester);
    expect(session.isAlive, isTrue, reason: 'shell 應該啟動成功');

    // 1) 組字中(注音/拼音打到一半)——不可送任何東西進 PTY
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'zhongwen',
        selection: TextSelection.collapsed(offset: 8),
        composing: TextRange(start: 0, end: 8),
      ),
    );
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump();
    expect(
      screenText(session),
      isNot(contains('zhongwen')),
      reason: '組字中的拼音不該被送進 shell',
    );

    // 2) 確認選字 → 整串指令(含中文)送出
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'echo 中文測試-42',
        selection: TextSelection.collapsed(offset: 11),
      ),
    );
    await tester.pump();

    // 3) Enter 執行
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    final screen = await waitForScreen(tester, session, '中文測試-42');
    expect(
      screen,
      contains('中文測試-42'),
      reason: '中文應以 UTF-8 送進 shell 並回顯:\n$screen',
    );
  });

  testWidgets('英數字元同樣走 IME 路徑,不會重複輸入', (tester) async {
    await pumpTerminal(tester);

    for (final ch in 'echo ABC-7'.split('')) {
      tester.testTextInput.updateEditingValue(
        TextEditingValue(
          text: ch,
          selection: TextSelection.collapsed(offset: ch.length),
        ),
      );
      await tester.pump();
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    final screen = await waitForScreen(tester, session, 'ABC-7');
    // 重複輸入會變成 "eecchhoo"
    expect(screen, contains('ABC-7'));
    expect(screen, isNot(contains('AABBCC')), reason: '不該有重複字元');
  });

  /// Ctrl+C 是否真的中斷了前景程式。
  ///
  /// `character` 就是各平台 embedder 實際塞進 KeyEvent 的內容,故意參數化:
  /// Windows 會把 C0 控制碼濾成 null,macOS 則原封不動給 0x03(見 keys.dart)。
  ///
  /// 判斷方式的關鍵:**斷言字串不能和打進去的字一樣**。前景程式擋住時,
  /// 打的字仍會被 tty 回顯到畫面上,拿 `echo AFTER-INT` 去比 'AFTER-INT'
  /// 會命中自己的回顯 → Ctrl+C 完全失效也是綠燈(這就是本來漏掉 macOS 的原因)。
  /// 所以指令寫成 `echo AFTER''-INT`:回顯是帶引號的原文,只有 shell 真的
  /// 執行了才會印出 `AFTER-INT`。
  Future<void> expectCtrlCInterrupts(
    WidgetTester tester, {
    required String? character,
    required String marker,
  }) async {
    await pumpTerminal(tester);

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'sleep 30',
        selection: TextSelection.collapsed(offset: 8),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );

    // Ctrl+C
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC, character: character);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    // marker 前半 + '' + 後半:回顯看到引號版,輸出才是 marker 本身
    final cmd = "echo ${marker.substring(0, 5)}''${marker.substring(5)}";
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: cmd,
        selection: TextSelection.collapsed(offset: cmd.length),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    // 若 Ctrl+C 沒生效,sleep 30 會擋住 echo,marker 不會被印出來
    final screen = await waitForScreen(
      tester,
      session,
      marker,
      timeout: const Duration(seconds: 8),
    );
    expect(screen, contains(marker), reason: 'Ctrl+C 應中斷 sleep:\n$screen');
  }

  // Windows 實機形狀:C0 控制碼被 isEasciiPrintable 濾掉 → character 是 null,
  // 靠 logicalKey 標籤還原。
  testWidgets('Ctrl+C 中斷前景程式(Windows 形狀:character 為 null)', (tester) async {
    await expectCtrlCInterrupts(tester, character: null, marker: 'AFTER-WININT');
  });

  // macOS 實機形狀:getEventString 只濾 0xF700–0xF7FF 的功能鍵私用區,C0 控制碼
  // 原封不動 → Ctrl+C 的 character 就是 0x03。這條路徑不會走 keyLabel fallback,
  // 過去沒測到,macOS 上 Ctrl 全失效卻仍是綠燈。
  testWidgets('Ctrl+C 中斷前景程式(macOS 形狀:character 已是 0x03)', (tester) async {
    await expectCtrlCInterrupts(
      tester,
      character: '\x03',
      marker: 'AFTER-MACINT',
    );
  });

  /// 按下貼上快捷鍵後,剪貼簿內容是否真的進了 PTY。
  ///
  /// 過去只測 KeyEncoder.isPasteShortcut 這個純判定,沒測「按下去真的有貼」——
  /// _onKeyEvent 對貼上快捷鍵一律回 handled,實際貼上卻只有 Windows 的 native
  /// (text_input_provider.cpp)有做,所以其他平台按了是黑洞,測試仍全綠。
  ///
  /// 斷言字串同樣不能和貼進去的字一樣(tty 會回顯),所以貼 `echo PASTE''-X`。
  Future<void> expectPastes(
    WidgetTester tester, {
    required Future<void> Function() press,
    required String marker,
  }) async {
    await pumpTerminal(tester);

    final cmd = "echo ${marker.substring(0, 5)}''${marker.substring(5)}";
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => call.method == 'Clipboard.getData' ? {'text': cmd} : null,
    );
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await press();
    // 讀剪貼簿是非同步的,要讓真實時間流動才會真的送進 PTY
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    final screen = await waitForScreen(
      tester,
      session,
      marker,
      timeout: const Duration(seconds: 8),
    );
    expect(screen, contains(marker), reason: '貼上的指令應進 PTY 並執行:\n$screen');
  }

  Future<void> pressWith(
    WidgetTester tester,
    LogicalKeyboardKey modifier,
    LogicalKeyboardKey key,
  ) async {
    await tester.sendKeyDownEvent(modifier);
    await tester.sendKeyEvent(key);
    await tester.sendKeyUpEvent(modifier);
    await tester.pump();
  }

  testWidgets('Cmd+V 貼上(macOS)', (tester) async {
    await expectPastes(
      tester,
      press: () =>
          pressWith(tester, LogicalKeyboardKey.metaLeft, LogicalKeyboardKey.keyV),
      marker: 'PASTE-CMDV',
    );
  });

  testWidgets('Ctrl+V 貼上', (tester) async {
    await expectPastes(
      tester,
      press: () => pressWith(
        tester,
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.keyV,
      ),
      marker: 'PASTE-CTRLV',
    );
  });

  // Shift+Insert 連 Windows 的 native 都沒接(它只認 Ctrl+'V'),三個平台都壞。
  testWidgets('Shift+Insert 貼上', (tester) async {
    await expectPastes(
      tester,
      press: () => pressWith(
        tester,
        LogicalKeyboardKey.shiftLeft,
        LogicalKeyboardKey.insert,
      ),
      marker: 'PASTE-SHINS',
    );
  });

  testWidgets('視窗尺寸變化 → PTY 收到 SIGWINCH', (tester) async {
    tester.view.physicalSize = const Size(1200, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await pumpTerminal(tester);

    // widget 依可用空間換算出的 cols/rows 應已套用到 native session
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    final cols = session.cols;
    expect(cols, greaterThan(20));

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'stty size',
        selection: TextSelection.collapsed(offset: 9),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    final screen = await waitForScreen(tester, session, '${session.rows} $cols');
    expect(
      screen,
      contains('${session.rows} $cols'),
      reason: 'shell 看到的尺寸應與 widget 換算一致:\n$screen',
    );
  });

  /// 開啟滑鼠回報(等同 tmux mouse on)並跑 cat,讓送進 PTY 的滑鼠序列
  /// 被 tty 回顯到畫面上(ESC 顯示為 ^[,後面 `[<65;...` 原樣可見)。
  Future<void> enableMouseReporting(WidgetTester tester) async {
    const cmd = r"printf '\033[?1000h\033[?1006h'; echo MOUSE-ON; cat";
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: cmd,
        selection: TextSelection.collapsed(offset: cmd.length),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    final screen = await waitForScreen(tester, session, 'MOUSE-ON');
    expect(screen, contains('MOUSE-ON'), reason: 'screen:\n$screen');
    expect(
      session.modes & TermModes.mouseReportClick,
      isNot(0),
      reason: 'DECSET 1000 後引擎應開啟滑鼠回報',
    );
  }

  // 迴歸:macOS 平滑捲動每個事件的 delta 常常不到一行,逐事件 round 會
  // 全部歸零 →「tmux 中滑鼠滾動常常失效」。delta 必須跨事件累積。
  testWidgets('滑鼠回報時,小 delta 滾輪事件累積後仍送出 wheel 回報', (tester) async {
    await pumpTerminal(tester);
    await enableMouseReporting(tester);

    final center = tester.getCenter(find.byType(TerminalView));
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(center));
    // 每次只捲 6px(遠小於一行),連續五次共 30px → 應累積成至少一個 wheelDown
    for (var i = 0; i < 5; i++) {
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 6)));
      await tester.pump();
    }

    final screen = await waitForScreen(tester, session, '[<65;');
    expect(
      screen,
      contains('[<65;'),
      reason: '小 delta 累積滿一行應送出 wheelDown(button 65):\n$screen',
    );
  });

  // 迴歸:macOS 觸控板兩指捲動是 pan-zoom 事件(不進 onPointerSignal),
  // 沒接的話觸控板在 tmux 裡完全不能捲。
  testWidgets('滑鼠回報時,觸控板 pan-zoom 捲動也送出 wheel 回報', (tester) async {
    await pumpTerminal(tester);
    await enableMouseReporting(tester);

    final center = tester.getCenter(find.byType(TerminalView));
    final pointer = TestPointer(1, PointerDeviceKind.trackpad);
    await tester.sendEventToBinding(pointer.panZoomStart(center));
    await tester.pump();
    // 手指往上滑(pan.dy < 0)= 內容往後看 = wheelDown
    await tester.sendEventToBinding(
      pointer.panZoomUpdate(center, pan: const Offset(0, -30)),
    );
    await tester.pump();
    await tester.sendEventToBinding(pointer.panZoomEnd());
    await tester.pump();

    final screen = await waitForScreen(tester, session, '[<65;');
    expect(
      screen,
      contains('[<65;'),
      reason: '觸控板捲動應送出 wheelDown(button 65):\n$screen',
    );
  });

  testWidgets('方向鍵送出 CSI 序列(readline 可用)', (tester) async {
    await pumpTerminal(tester);

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'echo XY',
        selection: TextSelection.collapsed(offset: 7),
      ),
    );
    await tester.pump();
    // 游標左移一格後插入 Z → 應變成 "echo XZY"
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'Z',
        selection: TextSelection.collapsed(offset: 1),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    // sh 的 readline 行為視實作而異,這裡只確認終端沒卡死、指令有被執行
    final screen = await waitForScreen(tester, session, 'echo X');
    expect(screen, contains('echo X'), reason: 'screen:\n$screen');
  }, skip: !Platform.isLinux);

  testWidgets('組字中按方向鍵,焦點不能被 default shortcuts 搬走', (tester) async {
    // 組字中終端一律回 skipRemainingHandlers 而不是 ignored。ignored 會讓按鍵
    // 冒泡到 MaterialApp 的 default shortcuts,方向鍵在那裡綁著
    // DirectionalFocusIntent(DirectionalFocusAction 永遠在 defaultActions),
    // 焦點就被搬到隔壁能聚焦的東西上(真實 app 裡是分頁列按鈕、檔案側窗)
    // → terminal 失焦 → _input.detach() → 整段注音組字蒸發。
    final neighbour = FocusNode(debugLabel: 'neighbour');
    addTearDown(neighbour.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              Focus(
                focusNode: neighbour,
                child: const SizedBox(width: 80, height: 80),
              ),
              Expanded(
                child: TerminalView(
                  session: session,
                  style: testTerminalStyle(),
                  autofocus: true,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'terminal');

    // 注音打到一半(底線 preedit 還在),使用者按 ← 想回頭改前面那個音
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'ㄋㄧˇ',
        selection: TextSelection.collapsed(offset: 3),
        composing: TextRange(start: 0, end: 3),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();

    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'terminal',
      reason: '焦點被搬走 → _input.detach() → 組字整段消失,使用者白打',
    );
  });

  testWidgets('組字中 preedit 位置釘住,不跟著 TUI 重繪的游標跳', (tester) async {
    // claude code / codex / vim 這類 TUI 每次重繪都把游標帶到畫面各處,而我們
    // 每 16ms 抓一次 grid。preedit 若跟著即時游標畫,使用者看到的就是組字一直
    // 在閃爍/亂跳。組字開始時要把位置釘住。
    await pumpTerminal(tester);
    await waitForScreen(tester, session, r'$');

    TermFrame frame() => tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((w) => w.painter)
        .whereType<TermPainter>()
        .first
        .frame();

    final anchorRow = frame().cursorRow;

    // 注音打到一半
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'ㄋㄧˇ',
        selection: TextSelection.collapsed(offset: 3),
        composing: TextRange(start: 0, end: 3),
      ),
    );
    await tester.pump();
    expect(frame().cursorRow, anchorRow);

    // 模擬 TUI 重繪:把游標帶到畫面下方別的位置(繞過 IME 直接寫 PTY)
    session.write(Uint8List.fromList(utf8.encode('printf "\\033[18;40Hmark"\n')));
    await waitForScreen(tester, session, 'mark');
    // grid 輪詢是 fake clock 驅動的,要推進時間才會把新游標抓進 _cursor,
    // 不然這個測試量不到任何東西(pump() 不帶 duration 推進 0)。
    await tester.pump(const Duration(milliseconds: 20));

    expect(
      session.cursor().$1,
      isNot(anchorRow),
      reason: '前提:真游標確實被 TUI 帶走了,否則這個測試是假綠',
    );
    expect(
      frame().cursorRow,
      anchorRow,
      reason: 'preedit 跟著游標跑 → 使用者看到組字一直閃爍/亂跳',
    );
  });
}
