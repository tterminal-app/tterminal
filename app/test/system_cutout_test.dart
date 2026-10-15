// 貼邊的系統保留區(iPhone Duo 外螢幕右上的時間/Wi‑Fi 膠囊)不蓋到內容:
// FoldFeatures 在根部讓掉那一側,內層 MediaQuery 換成較窄視窗的座標。
// 外螢幕數值取自 iOS 27.1 Duo 模擬器實測;session 用 headless(真 FFI)。

import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tterm_app/src/fold.dart';
import 'package:tterm_app/src/mobile_shell.dart';
import 'package:tterm_app/src/prefs.dart';
import 'package:tterm_app/src/tabs.dart';
import 'package:tterm_app/src/term_ffi.dart';
import 'package:tterm_app/src/terminal_view.dart';
import 'package:tterm_app/src/vault_pages.dart';
import 'package:tterm_app/src/vault_service.dart';

/// Duo 外螢幕:safeAreaInsets 是 right 84 / bottom 34(right 就是膠囊那一條)。
const _outer = Size(466, 678);
const _outerPadding = FakeViewPadding(right: 84, bottom: 34);

/// 外螢幕的兩塊 occlusion:系統膠囊(貼頂也貼右)與它裡面的螢幕下鏡頭。
const _capsule = Rect.fromLTWH(382, 0, 84, 170);
const _camera = Rect.fromLTWH(399.67, 29.33, 37, 37);

/// 一般 iPhone(17 Pro)直放 / 橫放;動態島離邊緣還有一段距離。
const _phone = Size(402, 874);
const _phonePadding = FakeViewPadding(top: 62, bottom: 34);
const _island = Rect.fromLTWH(141, 11, 120, 37);
const _phoneLandscape = Size(874, 402);
const _phoneLandscapePadding = FakeViewPadding(left: 62, right: 62, bottom: 21);
const _islandLandscape = Rect.fromLTWH(11, 141, 37, 120);

DisplayFeature _cut(Rect r) => DisplayFeature(
  bounds: r,
  type: DisplayFeatureType.cutout,
  state: DisplayFeatureState.unknown,
);

/// 內螢幕書本式半開的摺痕帶。
final _bookFold = DisplayFeature(
  bounds: const Rect.fromLTWH(455, 0, 40, 669),
  type: DisplayFeatureType.fold,
  state: DisplayFeatureState.postureHalfOpened,
);

/// 模擬視窗與 FoldBridge 的 native 回報(iOS 上摺痕和 cutout 都從這裡來)。
void _setWindow(
  WidgetTester tester,
  Size size,
  FakeViewPadding padding, [
  List<DisplayFeature> native = const [],
]) {
  tester.view
    ..devicePixelRatio = 1
    ..physicalSize = size
    ..padding = padding
    ..viewPadding = padding;
  FoldBridge.features.value = native;
}

void _setDuoOuter(WidgetTester tester) =>
    _setWindow(tester, _outer, _outerPadding, [_cut(_capsule), _cut(_camera)]);

/// 跟 main.dart 一樣把 FoldFeatures 掛在 MaterialApp.builder。
Widget _app(Widget home, {bool foldFeatures = true}) => MaterialApp(
  theme: ThemeData.dark(useMaterial3: true),
  builder: foldFeatures
      ? (context, child) => FoldFeatures(child: child!)
      : null,
  home: home,
);

/// [finder] 找到的每個元件都不能壓到膠囊。
void _expectClearOfCapsule(WidgetTester tester, Finder finder) {
  final count = finder.evaluate().length;
  expect(count, greaterThan(0), reason: '$finder 沒找到東西,測試沒在驗');
  for (var i = 0; i < count; i++) {
    final rect = tester.getRect(finder.at(i));
    expect(
      rect.overlaps(_capsule),
      isFalse,
      reason: '${finder.at(i)} 在 $rect,壓到膠囊 $_capsule',
    );
  }
}

void main() {
  tearDown(() => FoldBridge.features.value = const []);

  group('FoldFeatures 讓開貼邊的 cutout', () {
    late MediaQueryData seen;
    final home = Builder(
      builder: (context) {
        seen = MediaQuery.of(context);
        return const SizedBox.expand(key: Key('home'));
      },
    );

    testWidgets('Duo 外螢幕:右側整條讓掉,內層是較窄的視窗', (tester) async {
      addTearDown(tester.view.reset);
      _setDuoOuter(tester);
      await tester.pumpWidget(_app(home));

      expect(
        tester.getRect(find.byKey(const Key('home'))),
        const Rect.fromLTWH(0, 0, 382, 678),
      );
      expect(seen.size, const Size(382, 678));
      expect(seen.padding, const EdgeInsets.only(bottom: 34));
      expect(seen.viewPadding, const EdgeInsets.only(bottom: 34));
      // 膠囊和鏡頭都落在讓掉的那條裡,內層不用再管
      expect(seen.displayFeatures, isEmpty);
    });

    testWidgets('系統 padding 比 cutout 窄時,以 cutout 為準', (tester) async {
      addTearDown(tester.view.reset);
      _setWindow(tester, _outer, const FakeViewPadding(bottom: 34), [
        _cut(_capsule),
      ]);
      await tester.pumpWidget(_app(home));
      expect(seen.size.width, 382);
    });

    testWidgets('一般 iPhone:動態島沒貼邊,直放橫放都完全不動', (tester) async {
      addTearDown(tester.view.reset);
      _setWindow(tester, _phone, _phonePadding, [_cut(_island)]);
      await tester.pumpWidget(_app(home));
      expect(seen.size, _phone);
      expect(seen.padding, const EdgeInsets.only(top: 62, bottom: 34));
      expect(seen.displayFeatures.single.bounds, _island);

      _setWindow(tester, _phoneLandscape, _phoneLandscapePadding, [
        _cut(_islandLandscape),
      ]);
      await tester.pump();
      expect(seen.size, _phoneLandscape);
      expect(seen.padding.left, 62);
      expect(seen.padding.right, 62);
    });

    testWidgets('讓掉左側時,摺痕平移到內層座標', (tester) async {
      addTearDown(tester.view.reset);
      _setWindow(
        tester,
        const Size(951, 669),
        const FakeViewPadding(left: 40),
        [_bookFold, _cut(const Rect.fromLTWH(0, 0, 40, 120))],
      );
      await tester.pumpWidget(_app(home));
      expect(seen.size, const Size(911, 669));
      expect(seen.padding.left, 0);
      // cutout 落在讓掉的那條裡 → 丟掉;摺痕換成內層座標
      expect(seen.displayFeatures, [
        DisplayFeature(
          bounds: const Rect.fromLTWH(415, 0, 40, 669),
          type: DisplayFeatureType.fold,
          state: DisplayFeatureState.postureHalfOpened,
        ),
      ]);
    });
  });

  group('頁面不壓到膠囊', () {
    late Directory tmp;
    late VaultService service;
    late TabsController tabs;
    late AppPrefs prefs;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('tterm-cutout');
      service = VaultService.open('${tmp.path}/vault');
      tabs = TabsController(refillOnEmpty: false);
      prefs = AppPrefs.loadSync('${tmp.path}/prefs.json');
      service.upsert(
        kind: 'host',
        name: 'homelab',
        data: {
          'address': 'homelab.local',
          'port': 22,
          'username': 'dev',
          'pinned': true,
        },
      );
      service.upsert(
        kind: 'host',
        name: 'staging',
        data: {'address': 'staging.internal', 'port': 22, 'username': 'ubuntu'},
      );
    });

    tearDown(() async {
      tabs.dispose();
      service.dispose();
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });

    void addSession(int id, String label) => tabs.tabs.add(
      TermTab(
        id,
        session: NativeSession.headless(cols: 40, rows: 12),
        label: label,
      ),
    );

    Widget shell() => MobileShell(tabs: tabs, prefs: prefs, vault: service);

    testWidgets('Vaults:新增鈕、搜尋框、列上的按鈕、分頁籤', (tester) async {
      addTearDown(tester.view.reset);
      _setDuoOuter(tester);
      await tester.pumpWidget(
        _app(VaultsPage(service: service, onConnectHost: (_) {})),
      );
      await tester.pump();

      _expectClearOfCapsule(tester, find.byKey(const Key('btn-add-host')));
      _expectClearOfCapsule(tester, find.byKey(const Key('host-search')));
      _expectClearOfCapsule(tester, find.byType(IconButton));
      _expectClearOfCapsule(tester, find.byType(Tab));
    });

    testWidgets('首頁:連線列表(含 ×)與 AppBar 按鈕', (tester) async {
      addTearDown(tester.view.reset);
      _setDuoOuter(tester);
      addSession(1, 'homelab');
      await tester.pumpWidget(_app(shell()));
      await tester.pump();

      _expectClearOfCapsule(tester, find.byType(ListTile));
      _expectClearOfCapsule(tester, find.byKey(const ValueKey('btn-close-1')));
      _expectClearOfCapsule(tester, find.byType(IconButton));
    });

    testWidgets('終端頁:終端(含工具列)與 AppBar 都避開,且用滿膠囊左邊', (tester) async {
      addTearDown(tester.view.reset);
      _setDuoOuter(tester);
      addSession(1, 'one');
      await tester.pumpWidget(_app(shell()));
      await tester.tap(find.text('one'));
      await tester.pumpAndSettle();

      _expectClearOfCapsule(tester, find.byType(TerminalView));
      _expectClearOfCapsule(tester, find.byKey(const Key('btn-disconnect')));
      _expectClearOfCapsule(tester, find.byType(BackButton));
      // 只讓膠囊那條,終端左右各留 6 的內距
      final term = tester.getRect(find.byType(TerminalView));
      expect(term.left, 6);
      expect(term.right, 382 - 6);
    });

    testWidgets('一般 iPhone:終端大小跟沒掛 FoldFeatures 時一模一樣', (tester) async {
      addTearDown(tester.view.reset);
      addSession(1, 'one');

      Future<Rect> terminalRect({required bool foldFeatures}) async {
        await tester.pumpWidget(_app(shell(), foldFeatures: foldFeatures));
        await tester.tap(find.byKey(const ValueKey('session-1')));
        await tester.pumpAndSettle();
        final rect = tester.getRect(find.byType(TerminalView));
        await tester.pumpWidget(const SizedBox());
        return rect;
      }

      for (final (size, padding, island) in [
        (_phone, _phonePadding, _island),
        (_phoneLandscape, _phoneLandscapePadding, _islandLandscape),
      ]) {
        _setWindow(tester, size, padding, [_cut(island)]);
        expect(
          await terminalRect(foldFeatures: true),
          await terminalRect(foldFeatures: false),
          reason: '$size',
        );
      }
    });

    testWidgets('內螢幕書本式半開 + 左側讓位:分欄仍對齊實體摺痕', (tester) async {
      addTearDown(tester.view.reset);
      addSession(1, 'one');
      _setWindow(
        tester,
        const Size(951, 669),
        const FakeViewPadding(left: 40),
        [_bookFold, _cut(const Rect.fromLTWH(0, 0, 40, 120))],
      );
      await tester.pumpWidget(_app(shell()));
      await tester.tap(find.text('one'));
      await tester.pumpAndSettle();

      final sidebar = find.widgetWithText(AppBar, '連線');
      expect(tester.getRect(sidebar).left, 40);
      expect(tester.getRect(sidebar).right, 455);
      expect(
        tester.getTopLeft(find.byType(TerminalView)).dx,
        greaterThanOrEqualTo(495),
      );
    });
  });
}
