// 手機版功能鍵:Ctrl 組合編碼、長按拖曳→方向鍵換算、工具列 widget。

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tterm_app/src/ime.dart';
import 'package:tterm_app/src/key_toolbar.dart';
import 'package:tterm_app/src/keys.dart';
import 'package:tterm_app/src/term_ffi.dart';
import 'package:tterm_app/src/terminal_view.dart';
import 'package:tterm_app/src/touch_gestures.dart';

void main() {
  group('KeyEncoder.ctrlBytes', () {
    test('字母 → C0 控制碼(大小寫同義)', () {
      expect(KeyEncoder.ctrlBytes('c'), [0x03]);
      expect(KeyEncoder.ctrlBytes('C'), [0x03]);
      expect(KeyEncoder.ctrlBytes('a'), [0x01]);
      expect(KeyEncoder.ctrlBytes('z'), [0x1a]);
    });

    test('符號對應(Ctrl+[ = Esc)與無對應', () {
      expect(KeyEncoder.ctrlBytes('['), [0x1b]);
      expect(KeyEncoder.ctrlBytes(' '), [0x00]);
      expect(KeyEncoder.ctrlBytes('1'), isNull);
      expect(KeyEncoder.ctrlBytes('中'), isNull);
    });

    test('alt 前綴 ESC', () {
      expect(KeyEncoder.ctrlBytes('c', alt: true), [0x1b, 0x03]);
    });
  });

  group('ArrowJoystick', () {
    test('死區內不送;超過死區依主軸給方向', () {
      final j = ArrowJoystick(deadZone: 18, fastZone: 70);
      expect(j.update(10, 0), isFalse);
      expect(j.direction, isNull);

      expect(j.update(30, 0), isTrue); // 進慢速右
      expect(j.direction, 'C');
      expect(j.fast, isFalse);

      expect(j.update(35, 5), isFalse, reason: '同方向同速度檔不算變化');
    });

    test('超過 fastZone 進快速檔;縮回降回慢速', () {
      final j = ArrowJoystick(deadZone: 18, fastZone: 70);
      expect(j.update(0, -80), isTrue); // 快速上
      expect(j.direction, 'A');
      expect(j.fast, isTrue);

      expect(j.update(0, -40), isTrue); // 降回慢速
      expect(j.fast, isFalse);
      expect(j.direction, 'A');
    });

    test('方向切換與回到死區', () {
      final j = ArrowJoystick(deadZone: 18, fastZone: 70);
      j.update(50, 0);
      expect(j.direction, 'C');
      expect(j.update(0, 50), isTrue); // 右 → 下
      expect(j.direction, 'B');
      expect(j.update(5, 5), isTrue); // 回死區 → 停
      expect(j.direction, isNull);
    });

    test('斜向取主軸', () {
      final j = ArrowJoystick(deadZone: 18, fastZone: 70);
      j.update(50, 20);
      expect(j.direction, 'C');
      j.update(20, -50);
      expect(j.direction, 'A');
    });
  });

  group('TouchScrollTracker', () {
    test('滿一行才捲,餘量保留;往下拖為正(往歷史)', () {
      final t = TouchScrollTracker(lineHeight: 16);
      expect(t.feed(10), 0);
      expect(t.feed(10), 1); // 累積 20 → 1 行,餘 4
      expect(t.feed(12), 1); // 餘 4 + 12 = 16 → 1 行
      expect(t.feed(-33), -2); // 反向
    });
  });

  group('軟鍵盤 backspace(墊底字元)', () {
    const pad = '\u200b';
    late List<String> committed;
    late TerminalTextInput input;

    setUp(() {
      committed = [];
      input = TerminalTextInput(
        onCommit: committed.add,
        onComposingChanged: (_) {},
        padBackspace: true,
      );
    });

    TextEditingValue settled(String text) => TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );

    test('打字:墊底字元後的新增才送出', () {
      input.updateEditingValue(settled('${pad}a'));
      expect(committed, ['a']);
    });

    test('backspace 刪掉墊底字元 → 轉成 DEL(0x7f)', () {
      input.updateEditingValue(settled(''));
      expect(committed, ['\u007f']);
    });

    test('注音組字(墊底字元在前)不影響組字與確認', () {
      input.updateEditingValue(
        TextEditingValue(
          text: '$padㄋㄧ',
          selection: const TextSelection.collapsed(offset: 3),
          composing: const TextRange(start: 1, end: 3),
        ),
      );
      expect(committed, isEmpty, reason: '組字中不送出');
      expect(input.composing.text, 'ㄋㄧ');

      input.updateEditingValue(settled('$pad你'));
      expect(committed, ['你']);
      expect(input.composing.isEmpty, isTrue);
    });

    test('桌面模式(不墊)行為不變:空欄位、無 DEL 轉換', () {
      final desktop = TerminalTextInput(
        onCommit: committed.add,
        onComposingChanged: (_) {},
        padBackspace: false,
      );
      desktop.updateEditingValue(settled('a'));
      expect(committed, ['a']);
    });
  });

  group('KeyToolbar', () {
    testWidgets('按鍵觸發對應 callback', (tester) async {
      final keys = <LogicalKeyboardKey>[];
      final texts = <String>[];
      final ctrls = <String>[];
      var ctrlToggles = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: KeyToolbar(
              ctrlActive: false,
              onCtrlToggle: () => ctrlToggles++,
              onKey: keys.add,
              onText: texts.add,
              onCtrl: ctrls.add,
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('tk-esc')));
      await tester.tap(find.byKey(const Key('tk-↑')));
      await tester.tap(find.byKey(const Key('tk-ctrl')));
      await tester.tap(find.byKey(const Key('tk-^C')));
      await tester.tap(find.byKey(const Key('tk-^D')));
      // 後面的鍵在畫面外,要先橫向捲過去
      await tester.scrollUntilVisible(find.byKey(const Key('tk-|')), 100);
      await tester.tap(find.byKey(const Key('tk-|')));
      expect(keys, [LogicalKeyboardKey.escape, LogicalKeyboardKey.arrowUp]);
      expect(texts, ['|']);
      expect(ctrls, ['C', 'D']);
      expect(ctrlToggles, 1);
    });

    test('一鍵 Ctrl 組合都對得到控制碼', () {
      final ctrlKeys = KeyToolbar.keys.whereType<ToolbarCtrlKey>().toList();
      expect(
        ctrlKeys.map((k) => k.label),
        containsAll(['^C', '^D', '^Z', '^L', '^R']),
      );
      for (final k in ctrlKeys) {
        expect(KeyEncoder.ctrlBytes(k.char), isNotNull, reason: k.label);
      }
      expect(KeyEncoder.ctrlBytes('C'), [0x03]);
      expect(KeyEncoder.ctrlBytes('D'), [0x04]);
    });
  });

  group('TerminalView 手機模式', () {
    testWidgets('工具列顯示;Ctrl 黏著鍵點擊切換', (tester) async {
      final session = NativeSession.headless(cols: 40, rows: 12);
      addTearDown(session.dispose);
      final key = GlobalKey<TerminalViewState>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(key: key, session: session, mobileUI: true),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(KeyToolbar), findsOneWidget);

      await tester.tap(find.byKey(const Key('tk-ctrl')));
      await tester.pump();
      expect(key.currentState!.ctrlPending.value, isTrue);
      await tester.tap(find.byKey(const Key('tk-ctrl')));
      await tester.pump();
      expect(key.currentState!.ctrlPending.value, isFalse);

      // ^C 本身就是 Ctrl 組合:會把亮著的黏著 Ctrl 一起消掉
      await tester.tap(find.byKey(const Key('tk-ctrl')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('tk-^C')));
      await tester.pump();
      expect(key.currentState!.ctrlPending.value, isFalse);
    });

    testWidgets('桌面模式不顯示工具列', (tester) async {
      final session = NativeSession.headless(cols: 40, rows: 12);
      addTearDown(session.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(session: session, mobileUI: false),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(KeyToolbar), findsNothing);
    });

    testWidgets('長按後拖曳不會崩潰、也不產生反白選取', (tester) async {
      final session = NativeSession.headless(cols: 40, rows: 12);
      addTearDown(session.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(session: session, mobileUI: true),
          ),
        ),
      );
      await tester.pump();

      final center = tester.getCenter(find.byType(CustomPaint).first);
      final gesture = await tester.startGesture(
        center,
        kind: PointerDeviceKind.touch,
      );
      await tester.pump(const Duration(milliseconds: 500)); // 長按觸發
      await gesture.moveBy(const Offset(0, 40));
      await tester.pump();
      await gesture.up();
      await tester.pump();
      // 觸控路徑不該進入滑鼠反白(拖曳結束也不寫剪貼簿)——沒有例外即通過
    });
  });
}
