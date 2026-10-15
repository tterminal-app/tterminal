// IME 組字/確認邏輯測試(中文輸入的核心正確性)。
//
// 這裡測的是純邏輯:模擬平台輸入法送來的 TextEditingValue 序列,
// 驗證「組字中不送出、確認後只送一次、不重複也不遺漏」。

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tterm_app/src/ime.dart';

void main() {
  late List<String> committed;
  late List<String> composingLog;
  late TerminalTextInput input;

  setUp(() {
    committed = [];
    composingLog = [];
    input = TerminalTextInput(
      onCommit: committed.add,
      onComposingChanged: (s) => composingLog.add(s.text),
    );
  });

  TextEditingValue composing(String text, int start, int end) =>
      TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: end),
        composing: TextRange(start: start, end: end),
      );

  TextEditingValue settled(String text) => TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: text.length),
  );

  test('注音/拼音組字期間不送出任何 bytes', () {
    input.updateEditingValue(composing('ni', 0, 2));
    expect(committed, isEmpty, reason: '組字中不可送進 PTY');
    expect(input.composing.text, 'ni');

    input.updateEditingValue(composing('nihao', 0, 5));
    expect(committed, isEmpty);
    expect(input.composing.text, 'nihao');
  });

  test('選字確認後送出中文,且組字狀態清空', () {
    input
      ..updateEditingValue(composing('nihao', 0, 5))
      ..updateEditingValue(settled('你好'));

    expect(committed, ['你好']);
    expect(input.composing.isEmpty, isTrue, reason: '確認後不該還留著 preedit');
  });

  test('確認後接著再組字:已確認的部分不重複送出', () {
    // 部分 IME 會一次送「已確認 + 還在組字」的混合值
    input.updateEditingValue(composing('你好ma', 2, 4));
    expect(committed, ['你好'], reason: '組字區之前的文字算已確認');
    expect(input.composing.text, 'ma');

    input.updateEditingValue(settled('你好嗎'));
    expect(committed, ['你好', '嗎'], reason: '只送新增的部分,不可重送「你好」');
  });

  test('取消組字(按 Esc 清掉候選)不會誤送文字', () {
    input
      ..updateEditingValue(composing('nihao', 0, 5))
      ..updateEditingValue(const TextEditingValue());

    expect(committed, isEmpty);
    expect(input.composing.isEmpty, isTrue);
  });

  test('直接輸入英文字元(無組字)逐字送出', () {
    input
      ..updateEditingValue(settled('a'))
      ..updateEditingValue(settled('b'));
    expect(committed, ['a', 'b'], reason: '每次確認後狀態清空,不該累積成 ab');
  });

  test('連續中文輸入不會殘留前一次的內容', () {
    input
      ..updateEditingValue(composing('zhong', 0, 5))
      ..updateEditingValue(settled('中'))
      ..updateEditingValue(composing('wen', 0, 3))
      ..updateEditingValue(settled('文'));
    expect(committed, ['中', '文']);
  });

  test('emoji / 多 code unit 字元完整送出', () {
    input.updateEditingValue(settled('🎉'));
    expect(committed, ['🎉']);
  });

  test('組字游標位置被夾在組字範圍內', () {
    input.updateEditingValue(
      const TextEditingValue(
        text: 'nihao',
        selection: TextSelection.collapsed(offset: 3),
        composing: TextRange(start: 0, end: 5),
      ),
    );
    expect(input.composing.cursorOffset, 3);
    expect(input.composing.selectionLength, 0, reason: '沒有選取範圍');
  });

  test('輸入法選住其中一個字 → 起點與長度都要出得來(renderer 靠這個標示)', () {
    input.updateEditingValue(
      const TextEditingValue(
        text: '注音組字中',
        selection: TextSelection(baseOffset: 2, extentOffset: 3),
        composing: TextRange(start: 0, end: 5),
      ),
    );
    expect(input.composing.cursorOffset, 2);
    expect(input.composing.selectionLength, 1);
  });

  test('反向選取(base > extent)正規化成起點 + 長度', () {
    input.updateEditingValue(
      const TextEditingValue(
        text: '注音組字中',
        selection: TextSelection(baseOffset: 4, extentOffset: 1),
        composing: TextRange(start: 0, end: 5),
      ),
    );
    expect(input.composing.cursorOffset, 1);
    expect(input.composing.selectionLength, 3);
  });

  test('組字區前面有已確認文字時,offset 是相對組字區而不是整個欄位', () {
    input.updateEditingValue(
      const TextEditingValue(
        text: 'abc注音',
        selection: TextSelection.collapsed(offset: 4),
        composing: TextRange(start: 3, end: 5),
      ),
    );
    expect(input.composing.text, '注音');
    expect(input.composing.cursorOffset, 1, reason: '相對組字區第 1 個 code unit');
  });

  test('軟鍵盤送出鍵 → CR', () {
    input.performAction(TextInputAction.newline);
    expect(committed, ['\r']);
  });

  test('連線關閉時清除組字狀態', () {
    input
      ..updateEditingValue(composing('ni', 0, 2))
      ..connectionClosed();
    expect(input.composing.isEmpty, isTrue);
    expect(composingLog.last, isEmpty);
  });

  // ---- 桌面延後重置:確認後立刻 setEditingState(空) 會跟下一段組字競態 ----
  //
  // macOS engine 收到 composing 為 collapsed 的 setEditingState 時,若引擎端
  // 正在組字會 discardMarkedText,把使用者還沒確認的注音整段丟掉(白打)。
  // 注音「邊確認邊組下一段」與「確認後緊接著打下一段」都會踩到,
  // 終端輸出重繪繁忙(tmux/claude code)時訊息延遲更大、更常發生。

  group('桌面延後重置(IME 組字競態)', () {
    test('注音邊確認邊組下一段:前綴只送一次、新組字保留', () {
      // 引擎對同一鍵送出兩則更新:先 insertText(確認前綴)再 setMarkedText
      input
        ..updateEditingValue(composing('ㄊㄞˊ', 0, 3))
        ..updateEditingValue(settled('台'))
        ..updateEditingValue(composing('台ㄨ', 1, 2));
      expect(committed, ['台'], reason: '舊行為重置後 delta 歸零,「台」會重複送出');
      expect(input.composing.text, 'ㄨ', reason: '下一段組字必須保留');
    });

    testWidgets('確認後不立刻推送清空;輸入閒置後才清', (tester) async {
      final input = TerminalTextInput(
        onCommit: committed.add,
        onComposingChanged: (_) {},
        padBackspace: false,
        deferReset: true,
      );
      input.attach(viewId: tester.view.viewId);
      final log = tester.binding.testTextInput.log;
      log.clear();

      input
        ..updateEditingValue(composing('ㄊㄞˊ', 0, 3))
        ..updateEditingValue(settled('台'));
      expect(
        log.where((c) => c.method == 'TextInput.setEditingState'),
        isEmpty,
        reason: '確認後立刻清空會把使用者的下一段組字整段丟掉',
      );

      await tester.pump(const Duration(seconds: 1));
      expect(
        log.where((c) => c.method == 'TextInput.setEditingState'),
        hasLength(1),
        reason: '閒置後要清空一次,避免隱形輸入框無限累積',
      );
      expect(input.currentTextEditingValue, TextEditingValue.empty);
      input.detach();
    });

    testWidgets('確認後緊接著組字:待送的清空被取消', (tester) async {
      final input = TerminalTextInput(
        onCommit: committed.add,
        onComposingChanged: (_) {},
        padBackspace: false,
        deferReset: true,
      );
      input.attach(viewId: tester.view.viewId);
      final log = tester.binding.testTextInput.log;
      log.clear();

      input
        ..updateEditingValue(settled('台'))
        ..updateEditingValue(composing('台ㄨ', 1, 2));
      await tester.pump(const Duration(seconds: 2));
      expect(
        log.where((c) => c.method == 'TextInput.setEditingState'),
        isEmpty,
        reason: '組字中清空 = 引擎 discardMarkedText = 白打',
      );
      expect(input.composing.text, 'ㄨ');
      input.detach();
    });

    test('手機(立即重置)維持原行為:確認後馬上清空', () {
      final input = TerminalTextInput(
        onCommit: committed.add,
        onComposingChanged: (_) {},
        padBackspace: true,
        deferReset: false,
      );
      input.updateEditingValue(
        const TextEditingValue(
          text: '​你好',
          selection: TextSelection.collapsed(offset: 3),
        ),
      );
      expect(committed, ['你好']);
      expect(
        input.currentTextEditingValue!.text,
        '​',
        reason: '墊底字元要立刻補回,軟鍵盤 backspace 才有效',
      );
    });
  });
}
