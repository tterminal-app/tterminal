// 接收 native 聽寫/口語轉文字工具送進來的文字,交給目前作用中的終端。
// - insert:UIA ValuePattern 直接插字(原樣 bytes)。
// - paste :聽寫工具(typeless)用 Ctrl+V 貼上,native 已同步讀好剪貼簿文字,
//           交給呼叫端做 bracketed-paste 編碼再送進終端。
// native 端見 windows/runner/text_input_provider.cpp。

import 'dart:convert';

import 'package:flutter/services.dart';

class Dictation {
  static const _channel = MethodChannel('tterminal/dictate');

  static void listen({
    required void Function(Uint8List bytes) onInsert,
    required void Function(String text) onPaste,
  }) {
    _channel.setMethodCallHandler((call) async {
      final text = call.arguments as String?;
      if (text == null || text.isEmpty) return null;
      if (call.method == 'insert') {
        onInsert(Uint8List.fromList(utf8.encode(text)));
      } else if (call.method == 'paste') {
        onPaste(text);
      }
      return null;
    });
  }

  static void stop() {
    _channel.setMethodCallHandler(null);
  }

  /// 回報「終端是否持有焦點」給 native:native 只在終端有焦點時攔 Ctrl+V,
  /// 焦點在一般文字框時交還 Flutter 的標準貼上。非 Windows / 測試環境沒有
  /// native handler,錯誤直接吞掉。
  static void setTerminalFocused(bool focused) {
    _channel
        .invokeMethod<void>('terminalFocus', focused)
        .then((_) {}, onError: (_) {});
  }
}
