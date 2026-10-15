// Dictation:native 聽寫工具送的文字經 method channel → onInsert / onPaste。

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tterm_app/src/dictation.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('tterminal/dictate');

  tearDown(() => Dictation.stop());

  Future<void> fire(String method, String text) async {
    final data =
        const StandardMethodCodec().encodeMethodCall(MethodCall(method, text));
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(channel.name, data, (_) {});
  }

  test('insert 事件 → onInsert 收到 UTF-8 bytes', () async {
    final inserted = <String>[];
    final pasted = <String>[];
    Dictation.listen(
      onInsert: (bytes) => inserted.add(utf8.decode(bytes)),
      onPaste: pasted.add,
    );

    await fire('insert', 'echo hi');
    await fire('insert', '中文聽寫');
    expect(inserted, ['echo hi', '中文聽寫']);
    expect(pasted, isEmpty);
  });

  test('paste 事件 → onPaste 收到原字串(交給呼叫端做貼上編碼)', () async {
    final inserted = <String>[];
    final pasted = <String>[];
    Dictation.listen(
      onInsert: (bytes) => inserted.add(utf8.decode(bytes)),
      onPaste: pasted.add,
    );

    await fire('paste', '從剪貼簿貼上的內容');
    expect(pasted, ['從剪貼簿貼上的內容']);
    expect(inserted, isEmpty);
  });

  test('空字串不送', () async {
    final inserted = <Uint8List>[];
    final pasted = <String>[];
    Dictation.listen(onInsert: inserted.add, onPaste: pasted.add);
    await fire('insert', '');
    await fire('paste', '');
    expect(inserted, isEmpty);
    expect(pasted, isEmpty);
  });
}
