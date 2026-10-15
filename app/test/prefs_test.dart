// AppPrefs 測試:editorPaneWidth 預設值、clamp、落地重載。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tterm_app/src/prefs.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tterm-prefs-test');
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('termFontSize:預設值、clamp、落地重載', () {
    final path = '${tmp.path}/prefs.json';
    final prefs = AppPrefs.loadSync(path);
    expect(prefs.termFontSize, kTermFontDefaultSize);

    prefs.termFontSize = 100;
    expect(prefs.termFontSize, kTermFontMaxSize);

    prefs.termFontSize = 1;
    expect(prefs.termFontSize, kTermFontMinSize);

    prefs.termFontSize = 18;
    final reloaded = AppPrefs.loadSync(path);
    expect(reloaded.termFontSize, 18);
  });

  test('editorPaneWidth:預設值、clamp、落地重載', () {
    final path = '${tmp.path}/prefs.json';
    final prefs = AppPrefs.loadSync(path);
    expect(prefs.editorPaneWidth, kEditorPaneDefaultWidth);

    prefs.editorPaneWidth = 5000;
    expect(prefs.editorPaneWidth, kEditorPaneMaxWidth);

    prefs.editorPaneWidth = 10;
    expect(prefs.editorPaneWidth, kEditorPaneMinWidth);

    prefs.editorPaneWidth = 500;
    final reloaded = AppPrefs.loadSync(path);
    expect(reloaded.editorPaneWidth, 500);
  });
}
