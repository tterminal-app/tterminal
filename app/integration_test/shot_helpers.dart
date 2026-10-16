// 截圖用的 integration test 共用工具:由 appstore/shoot.sh 接手截圖。
//
// 測試印出 TTERM_SCENE / TTERM_SHOT,shoot.sh 看到就切示範主機的畫面或用 simctl 截圖,
// 做完在 127.0.0.1:8731 放一個確認檔,測試等到確認才往下走。

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tterm_app/src/app_dirs.dart';

/// 直接改 prefs.json(app 啟動時讀),其他設定原樣保留。
void updatePrefs(Map<String, Object?> values) {
  final file = File('${appBaseDir()}${Platform.pathSeparator}prefs.json');
  final json = file.existsSync()
      ? (jsonDecode(file.readAsStringSync()) as Map).cast<String, dynamic>()
      : <String, dynamic>{};
  json.addAll(values);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(jsonEncode(json));
}

NavigatorState navigator(WidgetTester tester) =>
    tester.state<NavigatorState>(find.byType(Navigator).first);

Future<void> pause(WidgetTester tester, int ms) async {
  await Future<void>.delayed(Duration(milliseconds: ms));
  await tester.pump();
}

Future<void> waitFor(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 60; i++) {
    if (finder.evaluate().isNotEmpty) return;
    await pause(tester, 500);
  }
  throw StateError('等不到 $finder');
}

/// [scene] 先請示範主機切畫面,等 tmux 重畫完再截。
///
/// 每一步都等 shoot.sh 確認做完才往下走:模擬器的日誌在機器忙的時候會晚好幾秒
/// 才送到 shoot.sh,只靠固定延遲會拍到下一個畫面。
Future<void> shot(WidgetTester tester, String name, {String? scene}) async {
  if (scene != null) {
    // ignore: avoid_print
    print('TTERM_SCENE $scene');
    await awaitAck(tester, 'scene-$scene');
    await pause(tester, 1500); // tmux 換視窗後的重畫
  }
  await pause(tester, 800);
  // ignore: avoid_print
  print('TTERM_SHOT $name');
  await awaitAck(tester, 'shot-$name');
}

/// 等 shoot.sh 在 127.0.0.1:8731 放好確認檔。
Future<void> awaitAck(WidgetTester tester, String key) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
  try {
    final deadline = DateTime.now().add(const Duration(minutes: 2));
    while (DateTime.now().isBefore(deadline)) {
      try {
        final req = await client.getUrl(Uri.parse('http://127.0.0.1:8731/$key'));
        final resp = await req.close();
        await resp.drain<void>();
        if (resp.statusCode == 200) return;
      } on IOException {
        // shoot.sh 的確認服務還沒起來,繼續等
      }
      await pause(tester, 300);
    }
    throw StateError('等不到 shoot.sh 確認 $key');
  } finally {
    client.close(force: true);
  }
}
