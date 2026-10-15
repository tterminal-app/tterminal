// iOS 背景保活橋接:把「目前活躍的連線數」回報給 native
// (ios/Runner/BackgroundBridge.swift)。app 退到背景且有連線時,native 會
// 申請背景執行時間並起 Live Activity 在 Dynamic Island 顯示連線數。

import 'dart:io' show Platform;

import 'package:flutter/services.dart';

class BackgroundBridge {
  static const _channel = MethodChannel('tterm/background');

  /// 回報活躍連線數。非 iOS 或 native 端未就緒時靜默略過。
  static Future<void> reportConnectionCount(int count) async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod('setConnectionCount', count);
    } on PlatformException {
      // native 端沒起來(舊版 runner)不該影響 app
    } on MissingPluginException {
      // 測試環境沒有 native handler
    }
  }
}
