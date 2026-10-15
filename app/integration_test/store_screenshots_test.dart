// App Store 截圖:在模擬器上把 app 走過一輪,每到一個畫面印出 marker,
// 由 appstore/shoot.sh 接手——TTERM_SCENE 讓示範主機切 tmux 視窗,
// TTERM_SHOT 用 simctl 截整個螢幕(含狀態列)。
//
// 需要 shoot.sh 先備好的環境:homelab.local 指到本機的示範 SSH 容器、
// 本機 8722 埠跑著 tterm-server。
//
//   --dart-define=SHOT_LOCALE=zh|en    主機名稱用哪一套
//   --dart-define=SHOT_LANDSCAPE=true  橫放(iPhone Duo 內螢幕攤平)
//   --dart-define=SHOT_FONT_SIZE=18    終端字級(iPad 這種大螢幕放大一點)

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tterm_app/main.dart';
import 'package:tterm_app/src/app_dirs.dart';
import 'package:tterm_app/src/fold.dart';
import 'package:tterm_app/src/purchases.dart';
import 'package:tterm_app/src/terminal_view.dart';
import 'package:tterm_app/src/vault_service.dart';

const _locale = String.fromEnvironment('SHOT_LOCALE', defaultValue: 'zh');
const _landscape = bool.fromEnvironment('SHOT_LANDSCAPE');
const _fontSize = String.fromEnvironment('SHOT_FONT_SIZE');

const _demoHost = 'homelab';
const _syncServer = 'http://homelab.local:8722';

/// (名稱, 使用者, 位址, 釘選)。只有 homelab 連得上,其他是列表上的擺設。
const _hosts = <(String, String, String, bool)>[
  (_demoHost, 'dev', 'homelab.local', true),
  ('nas', 'admin', 'nas.local', true),
  (_locale == 'zh' ? '客廳的 Pi' : 'living-room-pi', 'pi', 'raspberrypi.local', false),
  ('prod-web-01', 'deploy', '10.0.3.21', false),
  ('staging', 'ubuntu', 'staging.internal', false),
  (_locale == 'zh' ? '實驗室 GPU' : 'lab-gpu', 'ml', '192.168.1.42', false),
];

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('store screenshots', (tester) async {
    final demoId = await _seedVault();
    if (_fontSize.isNotEmpty) _setFontSize(double.parse(_fontSize));

    if (_landscape) {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
      ]);
    }
    FoldBridge.start();
    // 固定成「已解鎖」:模擬器上沒有 StoreKit 設定檔,截圖也不能出現試用說明或解鎖畫面
    await tester.pumpWidget(
      TtermApp(demoMode: false, purchases: FakePurchaseService.unlocked()),
    );
    await _pause(tester, 1500);

    // 連上示範主機
    await tester.tap(find.byKey(ValueKey('host-$demoId')).first);
    await _waitFor(tester, find.byType(TerminalView));
    await _pause(tester, 2000);

    // 前兩張收起鍵盤讓終端用滿;中文筆記那張再叫出鍵盤(注音 + 功能鍵列)
    FocusManager.instance.primaryFocus?.unfocus();
    await _pause(tester, 1000);
    await _shot(tester, '01-htop', scene: 'htop');
    await _shot(tester, '02-git', scene: 'git');
    tester.state<TerminalViewState>(find.byType(TerminalView)).requestFocus();
    await _pause(tester, 1000);
    await _shot(tester, '03-notes', scene: 'notes');
    FocusManager.instance.primaryFocus?.unfocus();

    // 回首頁:連線留在「進行中」
    _navigator(tester).pop();
    await _pause(tester, 1000);
    await _shot(tester, '04-home');

    await tester.tap(find.byKey(const Key('btn-settings')));
    await _pause(tester, 1000);
    await _shot(tester, '05-settings');
    _navigator(tester).pop();
    await _pause(tester, 800);

    await tester.tap(find.byKey(const Key('btn-vaults')));
    await _pause(tester, 1000);
    await _shot(tester, '06-vaults');
    _navigator(tester).pop();
    await _pause(tester, 800);
  }, timeout: const Timeout(Duration(minutes: 5)));
}

/// 把示範主機寫進 vault、接上本機的同步伺服器;回傳 homelab 的 record id。
Future<String> _seedVault() async {
  final vault = VaultService.open('${appBaseDir()}${Platform.pathSeparator}vault');
  try {
    // 保險:只在專用的截圖模擬器上跑。vault 裡有任何不是示範資料的東西,
    // 或同步接到別的 server,就一個字都不寫直接中止——不然示範主機會混進
    // 真實資料,還會被同步到使用者自己的 server。
    final demoNames = {for (final h in _hosts) h.$1};
    final foreign = [
      for (final r in vault.records)
        if (r.kind != 'host' || !demoNames.contains(r.name)) r.name,
    ];
    if (foreign.isNotEmpty ||
        (vault.syncConfigured && vault.syncServer != _syncServer)) {
      throw StateError(
        '這台模擬器上有真實資料(${foreign.length} 筆非示範紀錄,'
        '同步:${vault.syncServer}),拒絕寫入。請用 appstore/shoot.sh 建的 tterm-shots-* 模擬器。',
      );
    }
    final existing = {for (final h in vault.hosts) h.name: h.id};
    String? demoId = existing[_demoHost];
    for (final (name, user, address, pinned) in _hosts) {
      if (existing.containsKey(name)) continue;
      final id = vault.upsert(
        kind: 'host',
        name: name,
        data: {
          'address': address,
          'port': 22,
          'username': user,
          'auth': {
            'method': 'password',
            if (name == _demoHost) 'password': 'tterm-test-123',
          },
          if (pinned) 'pinned': true,
        },
      );
      if (name == _demoHost) demoId = id;
    }
    if (!vault.syncConfigured) {
      await vault.enableSync(_syncServer);
    }
    await vault.syncNow();
    return demoId!;
  } finally {
    vault.dispose();
  }
}

/// 直接改 prefs.json(app 啟動時讀),其他設定原樣保留。
void _setFontSize(double size) {
  final file = File('${appBaseDir()}${Platform.pathSeparator}prefs.json');
  final json = file.existsSync()
      ? (jsonDecode(file.readAsStringSync()) as Map).cast<String, dynamic>()
      : <String, dynamic>{};
  json['termFontSize'] = size;
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(jsonEncode(json));
}

NavigatorState _navigator(WidgetTester tester) =>
    tester.state<NavigatorState>(find.byType(Navigator).first);

Future<void> _pause(WidgetTester tester, int ms) async {
  await Future<void>.delayed(Duration(milliseconds: ms));
  await tester.pump();
}

Future<void> _waitFor(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 60; i++) {
    if (finder.evaluate().isNotEmpty) return;
    await _pause(tester, 500);
  }
  throw StateError('等不到 $finder');
}

/// [scene] 先請示範主機切畫面,等 tmux 重畫完再截。
Future<void> _shot(WidgetTester tester, String name, {String? scene}) async {
  if (scene != null) {
    // ignore: avoid_print
    print('TTERM_SCENE $scene');
    await _pause(tester, 3000);
  }
  await _pause(tester, 800);
  // ignore: avoid_print
  print('TTERM_SHOT $name');
  await _pause(tester, 2500);
}
