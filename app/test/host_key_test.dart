// 主機金鑰(host key)換了之後的路:錯誤畫面講清楚、並列新舊指紋,
// 使用者勾選「已核對」才能改用新指紋並重連 —— 不必刪掉 host 重新新增。
// 連線用注入的假 connect(收得到送給 core 的 config),session 用 headless。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tterm_app/src/app_shell.dart';
import 'package:tterm_app/src/mobile_shell.dart';
import 'package:tterm_app/src/prefs.dart';
import 'package:tterm_app/src/ssh_connect.dart';
import 'package:tterm_app/src/tabs.dart';
import 'package:tterm_app/src/term_ffi.dart';
import 'package:tterm_app/src/vault_service.dart';

const _old = 'SHA256:C2e8ILs2vZ7SvQxsU2QSoLr5dsCxeRgdbkWmO+LITpE';
const _new = 'SHA256:Nn1Y2Zf3cH8xWwqvTqk0sJm9L7rUo4bEaPdGiK5yR6M';

void main() {
  late Directory tmp;
  late VaultService vault;
  late AppPrefs prefs;
  late String hostId;

  /// 假伺服器:現在出示的是 [_new];帶別的指紋就照 core 的行為回 host key 不符。
  late List<String?> seenKnown;
  Future<NativeSession> fakeServer(Map<String, dynamic> config) async {
    final known = config['knownFingerprint'] as String?;
    seenKnown.add(known);
    if (known != null && known != _new) {
      throw HostKeyMismatchException(expected: known, actual: _new);
    }
    return NativeSession.headless(cols: 40, rows: 12);
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tterm-hostkey');
    vault = VaultService.open('${tmp.path}/vault');
    prefs = AppPrefs.loadSync('${tmp.path}/prefs.json');
    seenKnown = [];
    hostId = vault.upsert(
      kind: 'host',
      name: 'web',
      data: {
        'address': 'web.example.com',
        'port': 22,
        'username': 'deploy',
        'auth': {'method': 'password', 'password': 'pw'},
        'pinned': true,
        'hostKeyFingerprint': _old,
      },
    );
  });

  tearDown(() async {
    vault.dispose();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  int connect(TabsController tabs) => connectSshHostTab(
    tabs: tabs,
    vault: vault,
    host: vault.byId(hostId)!,
    onError: (m) => fail('不該有認證設定錯誤:$m'),
    connect: fakeServer,
  )!;

  String selectableIn(WidgetTester tester, Key key) => tester
      .widget<SelectableText>(
        find.descendant(of: find.byKey(key), matching: find.byType(SelectableText)),
      )
      .data!;

  group('HostKeyMismatchException.tryParse(core 的錯誤 JSON)', () {
    test('認得 host_key_mismatch,帶出新舊指紋', () {
      final e = HostKeyMismatchException.tryParse(
        '{"error":"host key mismatch: ...","code":"host_key_mismatch",'
        '"args":{"expected":"$_old","actual":"$_new"}}',
      )!;
      expect(e.expected, _old);
      expect(e.actual, _new);
      expect(e, isA<SshConnectException>(), reason: '仍是連線失敗,舊的處理照樣接得住');
      expect('$e', '主機金鑰跟上次不一樣');
    });

    test('其他錯誤、缺欄位、不是 JSON → null', () {
      expect(
        HostKeyMismatchException.tryParse(
          '{"error":"x","code":"timeout","args":{"op":"exec"}}',
        ),
        isNull,
      );
      expect(
        HostKeyMismatchException.tryParse(
          '{"error":"x","code":"host_key_mismatch","args":{}}',
        ),
        isNull,
      );
      expect(HostKeyMismatchException.tryParse('authentication failed'), isNull);
    });
  });

  group('分頁與 vault', () {
    late TabsController tabs;
    setUp(() => tabs = TabsController(refillOnEmpty: false));
    tearDown(() => tabs.dispose());

    test('改用新指紋:只換指紋、重連時帶新指紋,連上後錯誤清掉', () async {
      final id = connect(tabs);
      await Future<void>.delayed(Duration.zero);
      final tab = tabs.tabs.single;
      expect(tab.hostId, hostId);
      expect(tab.session, isNull);
      expect(tab.hostKeyMismatch?.actual, _new);
      expect(seenKnown, [_old]);

      final trust = trustNewHostKeyAction(tabs: tabs, vault: vault, tab: tab);
      expect(trust, isNotNull);
      trust!();
      await Future<void>.delayed(Duration.zero);

      final host = vault.byId(hostId)!;
      expect(host.data['hostKeyFingerprint'], _new);
      expect(host.data['pinned'], isTrue, reason: '其他欄位不能掉');
      expect(host.data['auth']['password'], 'pw');
      // 重連沒有沿用開分頁當下的舊指紋
      expect(seenKnown, [_old, _new]);
      expect(tab.id, id);
      expect(tab.session, isNotNull);
      expect(tab.hostKeyMismatch, isNull);
      expect(tab.error, isNull);
    });

    test('host 已被刪掉 → 不提供改用新指紋', () async {
      connect(tabs);
      await Future<void>.delayed(Duration.zero);
      vault.deleteRecord(hostId);
      final tab = tabs.tabs.single;
      expect(trustNewHostKeyAction(tabs: tabs, vault: vault, tab: tab), isNull);
      expect(trustNewHostKey(vault: vault, hostId: hostId, fingerprint: _new), isFalse);
      expect(vault.byId(hostId), isNull, reason: '不能把刪掉的 host 又寫回來');
    });

    test('其他連線錯誤不算 host key 不符', () async {
      tabs.newAsyncTab(
        'x',
        () => Future.error(SshConnectException('auth failed')),
        hostId: hostId,
      );
      await Future<void>.delayed(Duration.zero);
      final tab = tabs.tabs.single;
      expect(tab.error, 'auth failed');
      expect(tab.hostKeyMismatch, isNull);
      expect(trustNewHostKeyAction(tabs: tabs, vault: vault, tab: tab), isNull);
    });
  });

  testWidgets('桌面:錯誤畫面並列新舊指紋,勾選「已核對」才能改用新指紋', (tester) async {
    final tabs = TabsController(
      spawn: () => NativeSession.headless(cols: 60, rows: 16),
    );
    addTearDown(tabs.dispose);
    final id = connect(tabs);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: AppShell(tabs: tabs, prefs: prefs, vault: vault),
      ),
    );
    await tester.pump();

    expect(find.text('主機金鑰跟上次不一樣'), findsOneWidget);
    expect(find.textContaining('「web」這次出示的主機金鑰'), findsOneWidget);
    expect(find.textContaining('中間人攻擊'), findsOneWidget);
    expect(selectableIn(tester, ValueKey('hostkey-expected-$id')), _old);
    expect(selectableIn(tester, ValueKey('hostkey-actual-$id')), _new);

    // 取消:什麼都不變
    await tester.tap(find.byKey(ValueKey('btn-trust-hostkey-$id')));
    await tester.pumpAndSettle();
    expect(find.text('改用新的主機金鑰?'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(vault.byId(hostId)!.data['hostKeyFingerprint'], _old);

    // 沒勾「已核對」按不下去
    await tester.tap(find.byKey(ValueKey('btn-trust-hostkey-$id')));
    await tester.pumpAndSettle();
    final confirm = find.byKey(const Key('btn-confirm-trust-hostkey'));
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
    await tester.tap(confirm, warnIfMissed: false);
    await tester.pump();
    expect(vault.byId(hostId)!.data['hostKeyFingerprint'], _old);

    await tester.tap(find.byKey(const Key('chk-hostkey-verified')));
    await tester.pump();
    expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
    await tester.tap(confirm);
    await tester.pumpAndSettle();

    expect(vault.byId(hostId)!.data['hostKeyFingerprint'], _new);
    expect(seenKnown, [_old, _new]);
    expect(tabs.tabs.firstWhere((t) => t.id == id).session, isNotNull);
    expect(find.text('主機金鑰跟上次不一樣'), findsNothing);
  });

  testWidgets('桌面:host 已刪 → 只說明、不給改用新指紋', (tester) async {
    final tabs = TabsController(
      spawn: () => NativeSession.headless(cols: 60, rows: 16),
    );
    addTearDown(tabs.dispose);
    final id = connect(tabs);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: AppShell(tabs: tabs, prefs: prefs, vault: vault),
      ),
    );
    await tester.pump();
    vault.deleteRecord(hostId);
    await tester.pump();

    expect(find.text('主機金鑰跟上次不一樣'), findsOneWidget);
    expect(find.byKey(ValueKey('btn-trust-hostkey-$id')), findsNothing);
    expect(find.textContaining('已經不在 Vaults 裡'), findsOneWidget);
  });

  testWidgets('手機:終端頁顯示同一個畫面,確認後改用新指紋並連上', (tester) async {
    final tabs = TabsController(refillOnEmpty: false);
    addTearDown(tabs.dispose);
    final id = connect(tabs);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: MobileShell(tabs: tabs, prefs: prefs, vault: vault),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(ValueKey('session-$id')));
    await tester.pumpAndSettle();

    expect(find.text('主機金鑰跟上次不一樣'), findsOneWidget);
    expect(selectableIn(tester, ValueKey('hostkey-actual-$id')), _new);

    await tester.ensureVisible(find.byKey(ValueKey('btn-trust-hostkey-$id')));
    await tester.tap(find.byKey(ValueKey('btn-trust-hostkey-$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('chk-hostkey-verified')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('btn-confirm-trust-hostkey')));
    await tester.pumpAndSettle();

    expect(vault.byId(hostId)!.data['hostKeyFingerprint'], _new);
    expect(tabs.tabs.single.session, isNotNull);
    expect(find.text('主機金鑰跟上次不一樣'), findsNothing);
  });
}
