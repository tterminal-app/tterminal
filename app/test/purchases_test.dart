// 試用 / 解鎖(iOS 收費):狀態計算,以及手機版在「未開始 / 試用中 / 試用到期 /
// 已解鎖」四種狀態下的行為。購買狀態用 FakePurchaseService 假造,不碰 StoreKit。
//
// 「有沒有真的走到開連線那一步」用一台金鑰已被刪掉的主機判斷:放行的話
// connectSshHostTab 會馬上提示金鑰不存在,不用連網路;被擋下的話只會看到解鎖畫面。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tterm_app/src/l10n.dart';
import 'package:tterm_app/src/mobile_shell.dart';
import 'package:tterm_app/src/prefs.dart';
import 'package:tterm_app/src/purchases.dart';
import 'package:tterm_app/src/settings_page.dart';
import 'package:tterm_app/src/tabs.dart';
import 'package:tterm_app/src/unlock_page.dart';
import 'package:tterm_app/src/vault_pages.dart';
import 'package:tterm_app/src/vault_service.dart';

import 'vault_sync_test.dart' show FakeSyncServer;

/// 中日韓文字與全形標點(英文介面不該出現)。
final _cjk = RegExp(r'[　-〿㐀-鿿＀-￯]');

void main() {
  group('AccessStatus', () {
    final t0 = DateTime(2026, 10, 15, 9);

    test('沒有任何購買 → 未開始;解鎖優先於試用', () {
      expect(AccessStatus.of(const Entitlements(), t0).kind, AccessKind.notStarted);
      final unlocked = AccessStatus.of(
        Entitlements(trialStart: t0.subtract(const Duration(days: 90)), unlocked: true),
        t0,
      );
      expect(unlocked.kind, AccessKind.unlocked);
      expect(unlocked.canConnect, isTrue);
    });

    test('試用天數無條件進位,滿 14 天就到期', () {
      final e = Entitlements(trialStart: t0);
      AccessStatus at(Duration d) => AccessStatus.of(e, t0.add(d));

      expect(at(Duration.zero).daysLeft, 14);
      expect(at(const Duration(hours: 1)).daysLeft, 14);
      expect(at(const Duration(days: 13, hours: 1)).daysLeft, 1);
      expect(at(const Duration(days: 13, hours: 1)).canConnect, isTrue);
      expect(at(const Duration(days: 14)).kind, AccessKind.expired);
      expect(at(const Duration(days: 14)).canConnect, isFalse);
      expect(at(Duration.zero).trialEndsAt, t0.add(kTrialLength));
    });

    test('裝置時間被調到試用開始之前,也不會超過 14 天', () {
      final s = AccessStatus.of(
        Entitlements(trialStart: t0),
        t0.subtract(const Duration(days: 30)),
      );
      expect(s.kind, AccessKind.trial);
      expect(s.daysLeft, 14);
    });

    test('native payload 解碼', () {
      expect(Entitlements.decode(null).unlocked, isFalse);
      expect(Entitlements.decode(null).trialStart, isNull);
      final e = Entitlements.decode({
        'unlocked': true,
        'trialStart': t0.millisecondsSinceEpoch.toDouble(),
      });
      expect(e.unlocked, isTrue);
      expect(e.trialStart, t0);
    });

    test('服務每次讀狀態都用現在時間算:app 開著時試用到期也會生效', () {
      var now = t0;
      final fake = FakePurchaseService.trial(daysLeft: 1, clock: () => now);
      expect(fake.status.canConnect, isTrue);
      now = now.add(const Duration(days: 1));
      expect(fake.status.kind, AccessKind.expired);
    });
  });

  group('手機版', () {
    late Directory tmp;
    late VaultService service;
    late TabsController tabs;
    late AppPrefs prefs;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('tterm-purchases');
      service = VaultService.open('${tmp.path}/vault');
      tabs = TabsController(refillOnEmpty: false);
      prefs = AppPrefs.loadSync('${tmp.path}/prefs.json');
    });

    tearDown(() async {
      tabs.dispose();
      service.dispose();
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });

    /// 金鑰已被刪掉的主機:放行就會跳「金鑰不存在」。
    String addHost(String name) => service.upsert(
      kind: 'host',
      name: name,
      data: {
        'address': '$name.example.com',
        'port': 22,
        'username': 'u',
        'auth': {'method': 'key', 'keyId': 'deleted-key'},
      },
    );

    final unlockPage = find.byKey(const Key('unlock-page'));

    /// 把排隊中的 SnackBar 一則一則放完(同時只顯示一則,下一則要等前一則消失),
    /// 回傳出現過的文字。放完畫面底部也不會被 SnackBar 擋住。
    Future<List<String>> drainSnackBars(WidgetTester tester) async {
      final seen = <String>[];
      for (var i = 0; i < 10; i++) {
        final bars = find.byType(SnackBar);
        if (bars.evaluate().isEmpty) break;
        for (final e in find
            .descendant(of: bars, matching: find.byType(Text))
            .evaluate()) {
          seen.add((e.widget as Text).data ?? '');
        }
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle();
      }
      return seen;
    }

    /// 有沒有真的走到開連線那一步(見檔頭)。
    Future<bool> connectAttempted(WidgetTester tester) async =>
        (await drainSnackBars(tester)).contains(l10n.sshKeyMissing);

    Future<void> pumpShell(
      WidgetTester tester,
      PurchaseService? purchases, {
      // 手機尺寸(393×852 pt),跟 iPhone 直放差不多
      Size size = const Size(1179, 2556),
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: MobileShell(
            tabs: tabs,
            prefs: prefs,
            vault: service,
            purchases: purchases,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> tapHost(WidgetTester tester, String id) async {
      await tester.tap(find.byKey(ValueKey('host-$id')));
      await tester.pumpAndSettle();
    }

    Future<void> openSettings(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('btn-settings')));
      await tester.pumpAndSettle();
    }

    /// 設定頁很長,先捲到「試用與解鎖」那一區。
    Future<void> scrollToPurchases(WidgetTester tester) async {
      await tester.scrollUntilVisible(
        find.byKey(const Key('btn-settings-restore')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
    }

    testWidgets('未開始:第一次開 app 先講清楚試用,按「開始 14 天試用」才買試用品項', (
      tester,
    ) async {
      final id = addHost('web');
      final fake = FakePurchaseService.notStarted();
      await pumpShell(tester, fake);

      // 三件事:試用多久、到期後哪些不能用、解鎖多少錢(StoreKit 的價格字串)
      expect(unlockPage, findsOneWidget);
      expect(find.text(l10n.trialIntroTitle), findsOneWidget);
      expect(find.text(l10n.trialIntroDuration), findsOneWidget);
      expect(find.text(l10n.trialIntroAfter), findsOneWidget);
      expect(find.text(l10n.trialIntroPrice('US\$14.99')), findsOneWidget);
      expect(fake.calls, isEmpty, reason: '還沒按就不能開始試用');
      expect(prefs.trialIntroSeen, isTrue);

      await tester.tap(find.byKey(const Key('btn-start-trial')));
      await tester.pumpAndSettle();
      expect(fake.calls, ['startTrial']);
      expect(fake.status.kind, AccessKind.trial);
      expect(fake.status.daysLeft, 14);
      expect(unlockPage, findsNothing);
      expect(await drainSnackBars(tester), [l10n.trialStarted]);

      await tapHost(tester, id);
      expect(await connectAttempted(tester), isTrue);
    });

    testWidgets('未開始:說明只自動跳一次;之後點主機才再跳,關掉也不會自己開始試用', (
      tester,
    ) async {
      final id = addHost('web');
      final fake = FakePurchaseService.notStarted();
      await pumpShell(tester, fake);
      expect(unlockPage, findsOneWidget);
      await tester.tap(find.byKey(const Key('btn-not-now')));
      await tester.pumpAndSettle();
      expect(unlockPage, findsNothing);

      // 下次開 app:不再自動跳
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpShell(tester, fake);
      expect(unlockPage, findsNothing);

      await tapHost(tester, id);
      expect(unlockPage, findsOneWidget);
      expect(find.text(l10n.trialIntroTitle), findsOneWidget);
      await tester.tap(find.byKey(const Key('btn-not-now')));
      await tester.pumpAndSettle();
      expect(await connectAttempted(tester), isFalse);
      expect(fake.calls, isEmpty);
      expect(fake.status.kind, AccessKind.notStarted);
    });

    testWidgets('讀不到價格:說明不完整,先不能開始試用,可以再試一次', (tester) async {
      await pumpShell(tester, FakePurchaseService.notStarted(unlockPrice: null));
      expect(unlockPage, findsOneWidget);
      expect(find.text(l10n.priceUnavailable), findsOneWidget);
      expect(find.byKey(const Key('btn-retry-price')), findsOneWidget);
      final start = tester.widget<FilledButton>(
        find.byKey(const Key('btn-start-trial')),
      );
      expect(start.onPressed, isNull);
    });

    testWidgets('試用中:功能全開,設定頁顯示剩幾天,也可以提早解鎖', (tester) async {
      final id = addHost('web');
      final fake = FakePurchaseService.trial(daysLeft: 9);
      await pumpShell(tester, fake);
      expect(unlockPage, findsNothing, reason: '試用中不該自動跳說明');

      await tapHost(tester, id);
      expect(unlockPage, findsNothing);
      expect(await connectAttempted(tester), isTrue);

      await openSettings(tester);
      await scrollToPurchases(tester);
      expect(find.text(l10n.purchaseSection), findsOneWidget);
      expect(find.text(l10n.accessTrial(9)), findsOneWidget);

      await tester.tap(find.byKey(const Key('btn-settings-unlock')));
      await tester.pumpAndSettle();
      expect(find.text(l10n.unlockTitle), findsOneWidget);
      expect(find.text(l10n.unlockBody('US\$14.99')), findsOneWidget);
      await tester.tap(find.byKey(const Key('btn-unlock')));
      await tester.pumpAndSettle();
      expect(fake.calls, ['unlock']);
      expect(unlockPage, findsNothing);
      expect(find.text(l10n.accessUnlocked), findsOneWidget);
      expect(find.byKey(const Key('btn-settings-unlock')), findsNothing);
    });

    testWidgets('試用到期:點主機跳解鎖畫面;主機列表與 Vaults 照常可用', (tester) async {
      final id = addHost('web');
      final fake = FakePurchaseService.expired();
      await pumpShell(tester, fake);
      expect(unlockPage, findsNothing, reason: '開 app 不擋人,只有開新連線才跳');
      expect(find.text('web'), findsOneWidget);

      // 首頁點主機 → 解鎖畫面,不會開連線
      await tapHost(tester, id);
      expect(unlockPage, findsOneWidget);
      expect(find.text(l10n.trialEndedTitle), findsOneWidget);
      expect(find.text(l10n.trialEndedBody('US\$14.99')), findsOneWidget);
      expect(find.text(l10n.trialEndedKeepData), findsOneWidget);
      await tester.tap(find.byKey(const Key('btn-not-now')));
      await tester.pumpAndSettle();
      expect(await connectAttempted(tester), isFalse);
      expect(tabs.tabs, isEmpty);

      // Vaults:可以看、可以新增
      await tester.tap(find.byKey(const Key('btn-vaults')));
      await tester.pumpAndSettle();
      expect(find.byType(VaultsPage), findsOneWidget);
      await tester.tap(find.byKey(const Key('btn-add-host')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('host-name')), 'db');
      await tester.enterText(find.byKey(const Key('host-address')), '10.0.0.9');
      await tester.tap(find.byKey(const Key('btn-save-host')));
      await tester.pumpAndSettle();
      expect(service.hosts.map((h) => h.name), containsAll(['web', 'db']));
      expect(find.text('db'), findsOneWidget);

      // Vaults 裡的連線鈕:解鎖畫面疊在 Vaults 上,關掉還留在 Vaults
      await tester.tap(find.byKey(ValueKey('btn-connect-host-$id')));
      await tester.pumpAndSettle();
      expect(unlockPage, findsOneWidget);
      await tester.tap(find.byKey(const Key('btn-not-now')));
      await tester.pumpAndSettle();
      expect(find.byType(VaultsPage), findsOneWidget);
      expect(await connectAttempted(tester), isFalse);

      // 在解鎖畫面買完就接著連
      await tester.tap(find.byKey(ValueKey('btn-connect-host-$id')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('btn-unlock')));
      await tester.pumpAndSettle();
      expect(fake.calls, ['unlock']);
      expect(unlockPage, findsNothing);
      expect(find.byType(VaultsPage), findsNothing);
      expect(await connectAttempted(tester), isTrue);
    });

    testWidgets('試用到期:設定頁顯示狀態,同步照常可以設定與執行', (tester) async {
      addHost('web');
      // testWidgets 預設把 HttpClient 換成一律回 400 的假物件;這裡要真的連到
      // 本機的假同步伺服器
      final httpOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = httpOverrides);
      final server = FakeSyncServer();
      await tester.runAsync(server.start);
      addTearDown(server.stop);

      await pumpShell(tester, FakePurchaseService.expired());
      await openSettings(tester);

      await tester.enterText(find.byKey(const Key('sync-server')), server.url);
      await tester.tap(find.byKey(const Key('btn-enable-sync')));
      // 註冊與同步走真的 HTTP:runAsync 讓 I/O 前進,pump 讓畫面跟上
      for (var i = 0; i < 100 && service.lastSyncAt == null; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(service.syncConfigured, isTrue);
      expect(service.lastSyncError, isNull);
      expect(service.lastSyncAt, isNotNull);
      expect(server.vaults, hasLength(1));
      expect(find.byKey(const Key('btn-sync-now')), findsOneWidget);

      await scrollToPurchases(tester);
      expect(find.text(l10n.accessExpired), findsOneWidget);
      expect(find.text(l10n.accessExpiredHint), findsOneWidget);
      expect(find.byKey(const Key('btn-settings-unlock')), findsOneWidget);
    });

    testWidgets('已解鎖:沒有說明也沒有解鎖畫面,設定頁只留恢復購買', (tester) async {
      final id = addHost('web');
      await pumpShell(tester, FakePurchaseService.unlocked());
      expect(unlockPage, findsNothing);

      await tapHost(tester, id);
      expect(unlockPage, findsNothing);
      expect(await connectAttempted(tester), isTrue);

      await openSettings(tester);
      await scrollToPurchases(tester);
      expect(find.text(l10n.accessUnlocked), findsOneWidget);
      expect(find.byKey(const Key('btn-settings-unlock')), findsNothing);
      expect(find.byKey(const Key('btn-settings-restore')), findsOneWidget);
    });

    testWidgets('恢復購買:找到解鎖紀錄就解鎖,沒找到也講清楚', (tester) async {
      final fake = FakePurchaseService.expired();
      await pumpShell(tester, fake);
      await openSettings(tester);
      await scrollToPurchases(tester);

      await tester.tap(find.byKey(const Key('btn-settings-restore')));
      await tester.pumpAndSettle();
      expect(await drainSnackBars(tester), [l10n.restoreNothing]);
      expect(fake.status.kind, AccessKind.expired);

      fake.restoreFindsUnlock = true;
      await tester.tap(find.byKey(const Key('btn-settings-restore')));
      await tester.pumpAndSettle();
      expect(fake.calls, ['restore', 'restore']);
      expect(find.text(l10n.accessUnlocked), findsOneWidget);
    });

    testWidgets('解鎖畫面的恢復購買:恢復到解鎖就關掉並接著連', (tester) async {
      final id = addHost('web');
      final fake = FakePurchaseService.expired(restoreFindsUnlock: true);
      await pumpShell(tester, fake);
      await tapHost(tester, id);
      await tester.tap(find.byKey(const Key('btn-restore')));
      await tester.pumpAndSettle();
      expect(unlockPage, findsNothing);
      expect(
        await drainSnackBars(tester),
        [l10n.restoreFoundUnlock, l10n.sshKeyMissing],
      );
    });

    testWidgets('等待核准或購買失敗:畫面留著並提示,不會開連線', (tester) async {
      final id = addHost('web');
      final fake = FakePurchaseService.expired();
      await pumpShell(tester, fake);
      await tapHost(tester, id);

      fake.nextOutcome = PurchaseOutcome.pending;
      await tester.tap(find.byKey(const Key('btn-unlock')));
      await tester.pumpAndSettle();
      expect(unlockPage, findsOneWidget);
      expect(await drainSnackBars(tester), [l10n.purchasePending]);

      fake.nextOutcome = PurchaseOutcome.failed;
      await tester.tap(find.byKey(const Key('btn-unlock')));
      await tester.pumpAndSettle();
      expect(unlockPage, findsOneWidget);
      expect(await drainSnackBars(tester), [l10n.purchaseFailed('fake failure')]);

      await tester.tap(find.byKey(const Key('btn-not-now')));
      await tester.pumpAndSettle();
      expect(await connectAttempted(tester), isFalse);
    });

    testWidgets('解鎖畫面開著時從別處解鎖(Ask to Buy 核准):畫面自己關掉', (tester) async {
      final id = addHost('web');
      final fake = FakePurchaseService.expired(restoreFindsUnlock: true);
      await pumpShell(tester, fake);
      await tapHost(tester, id);
      expect(unlockPage, findsOneWidget);

      // 跟 Transaction.updates 進來時一樣:服務自己換了狀態
      await fake.restore();
      await tester.pumpAndSettle();
      expect(unlockPage, findsNothing);
      expect(await connectAttempted(tester), isTrue);
    });

    testWidgets('不收費的平台(purchases = null):不跳任何畫面,設定頁也沒有這一區', (
      tester,
    ) async {
      final id = addHost('web');
      await pumpShell(tester, null);
      expect(unlockPage, findsNothing);
      await tapHost(tester, id);
      expect(await connectAttempted(tester), isTrue);

      await tester.pumpWidget(
        MaterialApp(home: SettingsPage(service: service, prefs: prefs)),
      );
      await tester.pumpAndSettle();
      expect(find.text(l10n.purchaseSection), findsNothing);
      expect(find.byType(PurchaseSection), findsNothing);
    });

    group('英文', () {
      // 測試字型每個字母都是一個方塊,英文比真機寬很多;設定頁既有的「Set up sync /
      // Join with a pairing string」那一列在手機寬度會溢位,這裡用 800pt 寬的畫面
      const wide = Size(2400, 2556);
      setUp(() => debugAppLocaleOverride = const Locale('en'));
      tearDown(() => debugAppLocaleOverride = kTraditionalChinese);

      List<String> screenStrings(WidgetTester tester) => [
        for (final w in tester.allWidgets)
          if (w is Text) w.data ?? w.textSpan?.toPlainText() ?? '',
      ];

      testWidgets('試用說明、到期畫面、設定頁都沒有殘留中文', (tester) async {
        final id = addHost('web');
        final fake = FakePurchaseService.notStarted();
        await pumpShell(tester, fake, size: wide);
        expect(find.text('Try tterminal free for 14 days'), findsOneWidget);
        expect(screenStrings(tester).where(_cjk.hasMatch), isEmpty);
        await tester.tap(find.byKey(const Key('btn-not-now')));
        await tester.pumpAndSettle();

        await tester.pumpWidget(const SizedBox.shrink());
        await pumpShell(tester, FakePurchaseService.expired(), size: wide);
        await tapHost(tester, id);
        expect(find.text('Your trial has ended'), findsOneWidget);
        expect(find.text('Unlock for US\$14.99'), findsOneWidget);
        expect(screenStrings(tester).where(_cjk.hasMatch), isEmpty);
        await tester.tap(find.byKey(const Key('btn-not-now')));
        await tester.pumpAndSettle();

        await openSettings(tester);
        await scrollToPurchases(tester);
        expect(find.text('Trial & unlock'), findsOneWidget);
        expect(find.text('Trial ended'), findsOneWidget);
        expect(screenStrings(tester).where(_cjk.hasMatch), isEmpty);
      });

      testWidgets('剩 1 天用單數', (tester) async {
        await pumpShell(
          tester,
          FakePurchaseService.trial(daysLeft: 1),
          size: wide,
        );
        await openSettings(tester);
        await scrollToPurchases(tester);
        expect(find.text('Trial: 1 day left'), findsOneWidget);
      });
    });
  });
}
