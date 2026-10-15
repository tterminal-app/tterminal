// 多語系:語系解析、Rust 錯誤代碼的翻譯,以及「切成英文整個畫面都是英文」
// 的 smoke test(畫面上不能殘留任何中日韓字元)。
// 其他測試預設跑繁中(test/flutter_test_config.dart)。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tterm_app/main.dart';
import 'package:tterm_app/src/app_shell.dart';
import 'package:tterm_app/src/demo_page.dart';
import 'package:tterm_app/src/file_drop.dart';
import 'package:tterm_app/src/l10n.dart';
import 'package:tterm_app/src/mobile_shell.dart';
import 'package:tterm_app/src/native_error.dart';
import 'package:tterm_app/src/prefs.dart';
import 'package:tterm_app/src/sync_client.dart';
import 'package:tterm_app/src/tabs.dart';
import 'package:tterm_app/src/term_ffi.dart';
import 'package:tterm_app/src/vault_pages.dart';
import 'package:tterm_app/src/vault_service.dart';

/// 中日韓文字與全形標點(英文介面不該出現,使用者資料除外)。
final _cjk = RegExp(r'[　-〿㐀-鿿＀-￯]');

/// 畫面上所有字串:Text / RichText,加上 tooltip(滑過去才看得到,也要翻)。
List<String> _screenStrings(WidgetTester tester) => [
  for (final w in tester.allWidgets)
    if (w is Text)
      w.data ?? w.textSpan?.toPlainText() ?? ''
    else if (w is RichText)
      w.text.toPlainText()
    else if (w is Tooltip)
      w.message ?? '',
];

void _expectNoCjk(WidgetTester tester) {
  final leaked = _screenStrings(tester).where(_cjk.hasMatch).toList();
  expect(leaked, isEmpty, reason: '英文介面殘留中文:$leaked');
}

/// 跟 TtermApp 一樣的語系設定,home 換成要測的頁面。
Widget _app(Widget home) => MaterialApp(
  theme: ThemeData.dark(useMaterial3: true),
  locale: appLocale,
  supportedLocales: kAppSupportedLocales,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  home: home,
);

void main() {
  group('resolveAppLocale', () {
    const zhHant = kTraditionalChinese;
    test('英文與不支援的語言 → 英文', () {
      expect(resolveAppLocale([const Locale('en', 'US')]), const Locale('en'));
      expect(resolveAppLocale([const Locale('fr', 'FR')]), const Locale('en'));
      expect(resolveAppLocale(const []), const Locale('en'));
    });

    test('任何中文變體都用繁中(簡中暫時也看繁中)', () {
      expect(resolveAppLocale([const Locale('zh', 'TW')]), zhHant);
      expect(resolveAppLocale([const Locale('zh', 'HK')]), zhHant);
      expect(
        resolveAppLocale([
          const Locale.fromSubtags(
            languageCode: 'zh',
            scriptCode: 'Hans',
            countryCode: 'CN',
          ),
        ]),
        zhHant,
      );
    });

    test('依偏好順序找第一個支援的語言', () {
      expect(
        resolveAppLocale([const Locale('ja', 'JP'), const Locale('zh', 'TW')]),
        zhHant,
      );
      expect(
        resolveAppLocale([const Locale('en', 'GB'), const Locale('zh', 'TW')]),
        const Locale('en'),
      );
    });
  });

  group('Rust 錯誤代碼翻譯', () {
    tearDown(() => debugAppLocaleOverride = kTraditionalChinese);

    final hostKey = {
      'error': 'host key mismatch: expected SHA256:a, got SHA256:b; ...',
      'code': 'host_key_mismatch',
      'args': {'expected': 'SHA256:a', 'actual': 'SHA256:b'},
    };
    final readTimeout = {
      'error': 'outer: read_file timed out (the connection may be down)',
      'code': 'timeout',
      'args': {'op': 'read_file'},
    };

    test('繁中:跟原本 Rust 端的中文訊息一致', () {
      expect(
        describeNativeError(hostKey),
        'host key 不符!預期 SHA256:a,實際 SHA256:b。'
        '連線已中止(可能遭中間人攻擊,或伺服器主機金鑰已更換)。',
      );
      expect(describeNativeError(readTimeout), 'SFTP 讀檔 逾時(連線可能已中斷)');
      expect(
        describeNativeError({
          'error': 'x',
          'code': 'pairing_unsupported_version',
          'args': {'version': 2},
        }),
        '配對字串版本 2 不支援(此版本只支援 v1)',
      );
    });

    test('英文', () {
      debugAppLocaleOverride = const Locale('en');
      expect(describeNativeError(hostKey), startsWith('Host key mismatch!'));
      expect(describeNativeError(hostKey), contains('SHA256:b'));
      expect(
        describeNativeError(readTimeout),
        startsWith('Reading the file over SFTP timed out'),
      );
      expect(
        describeNativeError({'error': 'x', 'code': 'decrypt_failed'}),
        startsWith("Couldn't decrypt"),
      );
    });

    test('沒有 code / 不認得的 code / 不是 JSON → 原文', () {
      expect(describeNativeError({'error': 'disk on fire'}), 'disk on fire');
      expect(
        describeNativeError({'error': 'new thing', 'code': 'from_the_future'}),
        'new thing',
      );
      expect(describeLastError('{"error":"plain"}'), 'plain');
      expect(describeLastError('truncated {"err'), 'truncated {"err');
    });

    test('同步伺服器的錯誤:常見狀態碼講人話,其他附原文', () {
      debugAppLocaleOverride = const Locale('en');
      // server 回的是它自己的語言;英文介面不能直接把它秀出來
      expect('${SyncHttpException(401, 'token 不正確')}', l10n.syncUnauthorized);
      expect('${SyncHttpException(500, 'boom')}', 'Server responded 500: boom');
    });
  });

  group('英文介面', () {
    late Directory tmp;
    late TabsController tabs;
    late AppPrefs prefs;
    late VaultService vault;

    setUp(() async {
      debugAppLocaleOverride = const Locale('en');
      tmp = await Directory.systemTemp.createTemp('tterm-l10n-test');
      prefs = AppPrefs.loadSync('${tmp.path}/prefs.json');
      vault = VaultService.open('${tmp.path}/vault');
    });

    tearDown(() async {
      debugAppLocaleOverride = kTraditionalChinese;
      tabs.dispose();
      vault.dispose();
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });

    testWidgets('桌面:工作區、設定頁、Vaults 頁、新增 Host 對話框', (tester) async {
      tabs = TabsController(
        spawn: () => NativeSession.headless(cols: 60, rows: 16),
      );
      await tester.pumpWidget(
        _app(AppShell(tabs: tabs, prefs: prefs, vault: vault)),
      );
      await tester.pump();
      expect(find.text('Local terminal'), findsOneWidget);
      expect(find.byTooltip('New tab (Ctrl+Shift+T)'), findsOneWidget);
      expect(find.text('Terminal 1'), findsOneWidget);
      _expectNoCjk(tester);

      await tester.tap(find.byKey(const Key('btn-settings')));
      await tester.pumpAndSettle();
      expect(find.text('Tab bar position'), findsOneWidget);
      expect(find.text('Sync (self-hosted server)'), findsOneWidget);
      _expectNoCjk(tester);
      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('btn-vaults')));
      await tester.pumpAndSettle();
      expect(find.text('No hosts yet. Hit “Add Host” to get started.'), findsOneWidget);
      expect(find.text('0 hosts'), findsOneWidget);
      _expectNoCjk(tester);

      await tester.tap(find.byKey(const Key('btn-add-host')));
      await tester.pumpAndSettle();
      expect(find.text('Address *'), findsOneWidget);
      _expectNoCjk(tester);
    });

    testWidgets('手機:連線列表(複數、空狀態)', (tester) async {
      tabs = TabsController(refillOnEmpty: false);
      await tester.pumpWidget(
        _app(MobileShell(tabs: tabs, prefs: prefs, vault: vault)),
      );
      await tester.pump();
      expect(find.textContaining('No hosts yet.'), findsOneWidget);
      _expectNoCjk(tester);

      vault.upsert(kind: 'host', name: 'web', data: {'address': 'w.example.com'});
      await tester.pump();
      expect(find.text('web'), findsOneWidget);
      expect(find.text('Hosts'), findsOneWidget);
      _expectNoCjk(tester);
    });

    testWidgets('Vaults:編輯 Host 的指紋區、產生金鑰對話框', (tester) async {
      tabs = TabsController(refillOnEmpty: false);
      vault.upsert(
        kind: 'host',
        name: 'web',
        data: {'address': 'w.example.com', 'hostKeyFingerprint': 'SHA256:abc'},
      );
      await tester.pumpWidget(_app(VaultsPage(service: vault)));
      await tester.pump();

      await tester.tap(find.text('web'));
      await tester.pumpAndSettle();
      expect(find.text('Host key fingerprint'), findsOneWidget);
      _expectNoCjk(tester);
      await tester.ensureVisible(find.byKey(const Key('btn-clear-fingerprint')));
      await tester.tap(find.byKey(const Key('btn-clear-fingerprint')));
      await tester.pump();
      expect(find.textContaining('Will be cleared when you save'), findsOneWidget);
      _expectNoCjk(tester);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Keys'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Hit “Generate Key”'), findsOneWidget);
      _expectNoCjk(tester);
      await tester.tap(find.byKey(const Key('btn-generate-key')));
      await tester.pumpAndSettle();
      expect(find.text('Generate SSH Key'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('keygen-passphrase')), 'x');
      await tester.pump();
      expect(find.text('Repeat passphrase'), findsOneWidget);
      _expectNoCjk(tester);
    });

    testWidgets('手機:host key 不符的畫面與確認對話框', (tester) async {
      tabs = TabsController(refillOnEmpty: false);
      final hostId = vault.upsert(
        kind: 'host',
        name: 'web',
        data: {'address': 'w.example.com', 'hostKeyFingerprint': 'SHA256:old'},
      );
      final id = tabs.newAsyncTab(
        'web',
        () => Future.error(
          HostKeyMismatchException(expected: 'SHA256:old', actual: 'SHA256:new'),
        ),
        hostId: hostId,
      );
      await tester.pumpWidget(
        _app(MobileShell(tabs: tabs, prefs: prefs, vault: vault)),
      );
      await tester.pump();
      expect(find.text('The host key has changed'), findsOneWidget, reason: '連線列表的錯誤摘要');
      _expectNoCjk(tester);

      await tester.tap(find.byKey(ValueKey('session-$id')));
      await tester.pumpAndSettle();
      expect(find.text('Fingerprint presented this time'), findsOneWidget);
      _expectNoCjk(tester);

      await tester.ensureVisible(find.byKey(ValueKey('btn-trust-hostkey-$id')));
      await tester.tap(find.byKey(ValueKey('btn-trust-hostkey-$id')));
      await tester.pumpAndSettle();
      expect(find.text('Use the new host key?'), findsOneWidget);
      _expectNoCjk(tester);
    });

    test('拖檔略過原因', () {
      tabs = TabsController(refillOnEmpty: false);
      final r = importDroppedFiles([tmp.path], remote: false, place: (_, _) {});
      expect(r.skipped.single, endsWith(' (folder)'));
    });
  });

  group('Material 內建字串跟著語系(TtermApp 的設定)', () {
    tearDown(() => debugAppLocaleOverride = kTraditionalChinese);

    Future<MaterialLocalizations> pumpApp(WidgetTester tester) async {
      await tester.pumpWidget(const TtermApp(demoMode: true));
      final context = tester.element(find.byType(DemoPage));
      final strings = MaterialLocalizations.of(context);
      // 卸掉 demo 頁(它有 ticker 和 timer)
      await tester.pumpWidget(const SizedBox.shrink());
      return strings;
    }

    testWidgets('繁中拿到繁體,不是簡體', (tester) async {
      final strings = await pumpApp(tester);
      expect(strings.copyButtonLabel, '複製');
      expect(strings.pasteButtonLabel, '貼上');
    });

    testWidgets('英文', (tester) async {
      debugAppLocaleOverride = const Locale('en');
      final strings = await pumpApp(tester);
      expect(strings.copyButtonLabel, 'Copy');
    });
  });
}
