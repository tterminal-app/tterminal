// 折疊螢幕(iPhone Duo 等)適配:摺痕模型、native payload 解碼、各姿勢版面、
// 折疊/展開時終端狀態保留與 resize 節流。
// 終端用 headless session(真 FFI),視窗尺寸與摺痕用 tester.view 模擬。

import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tterm_app/src/fold.dart';
import 'package:tterm_app/src/key_toolbar.dart';
import 'package:tterm_app/src/mobile_shell.dart';
import 'package:tterm_app/src/prefs.dart';
import 'package:tterm_app/src/tabs.dart';
import 'package:tterm_app/src/term_ffi.dart';
import 'package:tterm_app/src/term_painter.dart';
import 'package:tterm_app/src/terminal_view.dart';
import 'package:tterm_app/src/vault_service.dart';

/// iPhone Duo 量測值(邏輯像素):外螢幕、內螢幕橫放(書本)、內螢幕直放(桌上型)。
const _outer = Size(466, 678);
const _inner = Size(951, 669);
const _innerRotated = Size(669, 951);

DisplayFeature _fold(Rect bounds, {bool halfOpen = true}) => DisplayFeature(
  bounds: bounds,
  type: DisplayFeatureType.fold,
  state: halfOpen
      ? DisplayFeatureState.postureHalfOpened
      : DisplayFeatureState.postureFlat,
);

/// 書本式半開:內螢幕橫放,直立摺痕帶 x=455..495。
final _bookFold = _fold(const Rect.fromLTWH(455, 0, 40, 669));

/// 桌上型半開:內螢幕直放,橫向摺痕帶 y=455..495。
final _tableFold = _fold(const Rect.fromLTWH(0, 455, 669, 40));

void main() {
  group('FoldSplit.find', () {
    const area = Rect.fromLTWH(0, 0, 951, 669);

    test('半開的直立摺痕 → 左右切分,座標相對於區域', () {
      expect(
        FoldSplit.find([_bookFold], area),
        const FoldSplit(Axis.vertical, 455, 495),
      );
      // 區域不在原點:換成區域內座標
      expect(
        FoldSplit.find([_bookFold], const Rect.fromLTWH(100, 50, 851, 600)),
        const FoldSplit(Axis.vertical, 355, 395),
      );
    });

    test('攤平的 fold 不算(Apple:攤平當一整塊螢幕);hinge 一律算', () {
      expect(
        FoldSplit.find([
          _fold(const Rect.fromLTWH(455, 0, 40, 669), halfOpen: false),
        ], area),
        isNull,
      );
      final hinge = DisplayFeature(
        bounds: const Rect.fromLTWH(455, 0, 40, 669),
        type: DisplayFeatureType.hinge,
        state: DisplayFeatureState.unknown,
      );
      expect(FoldSplit.find([hinge], area)?.axis, Axis.vertical);
    });

    test('橫向摺痕 → 上下切分;only 過濾方向', () {
      const tall = Rect.fromLTWH(0, 0, 669, 951);
      expect(
        FoldSplit.find([_tableFold], tall),
        const FoldSplit(Axis.horizontal, 455, 495),
      );
      expect(FoldSplit.find([_tableFold], tall, only: Axis.vertical), isNull);
    });

    test('沒有把區域切成兩塊的不算(落在外面或貼邊)', () {
      // 兩欄版面的右欄:摺痕在它左邊
      expect(
        FoldSplit.find([_bookFold], const Rect.fromLTWH(495, 0, 456, 669)),
        isNull,
      );
      // 軟鍵盤把可用高度壓到摺痕以上
      expect(
        FoldSplit.find([_tableFold], const Rect.fromLTWH(0, 0, 669, 470)),
        isNull,
      );
      // 瀏海/鏡頭 cutout 不是摺痕
      final cutout = DisplayFeature(
        bounds: const Rect.fromLTWH(400, 0, 80, 30),
        type: DisplayFeatureType.cutout,
        state: DisplayFeatureState.unknown,
      );
      expect(FoldSplit.find([cutout], area), isNull);
    });
  });

  group('FoldBridge.decode(native payload)', () {
    test('fold → 半開 fold、cutout → cutout,壞資料略過', () {
      final features = FoldBridge.decode([
        {'x': 455, 'y': 0, 'w': 40.0, 'h': 669, 'type': 'fold'},
        {'x': 10, 'y': 0, 'w': 80, 'h': 30, 'type': 'cutout'},
        {'x': 1, 'y': 2, 'w': 3, 'h': 4, 'type': 'mystery'},
        {'x': 'bad', 'y': 0, 'w': 1, 'h': 1, 'type': 'fold'},
        'garbage',
      ]);
      expect(features, [
        _bookFold,
        const DisplayFeature(
          bounds: Rect.fromLTWH(10, 0, 80, 30),
          type: DisplayFeatureType.cutout,
          state: DisplayFeatureState.unknown,
        ),
      ]);
      expect(FoldBridge.decode(null), isEmpty);
    });
  });

  group('FoldFeatures', () {
    tearDown(() => FoldBridge.features.value = const []);

    Future<List<DisplayFeature>> seen(WidgetTester tester) async {
      late List<DisplayFeature> got;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => FoldFeatures(child: child!),
          home: Builder(
            builder: (context) {
              got = MediaQuery.displayFeaturesOf(context);
              return const SizedBox();
            },
          ),
        ),
      );
      return got;
    }

    testWidgets('native 回報的摺痕疊進 MediaQuery', (tester) async {
      FoldBridge.features.value = [_bookFold];
      expect(await seen(tester), [_bookFold]);
    });

    testWidgets('平台已提供 displayFeatures(Android)→ 不重複疊加', (tester) async {
      addTearDown(tester.view.reset);
      final platform = _fold(const Rect.fromLTWH(300, 0, 0, 600));
      tester.view.displayFeatures = [platform];
      FoldBridge.features.value = [_bookFold];
      expect(await seen(tester), [platform]);
    });
  });

  group('終端頁版面', () {
    late Directory tmp;
    late VaultService service;
    late TabsController tabs;
    late AppPrefs prefs;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('tterm-fold');
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

    void setWindow(
      WidgetTester tester,
      Size size, [
      List<DisplayFeature> features = const [],
    ]) {
      tester.view
        ..devicePixelRatio = 1
        ..physicalSize = size
        ..displayFeatures = features;
    }

    NativeSession addSession(int id, String label) {
      final session = NativeSession.headless(cols: 40, rows: 12);
      tabs.tabs.add(TermTab(id, session: session, label: label));
      return session;
    }

    Future<void> openTerminal(
      WidgetTester tester,
      Size size, [
      List<DisplayFeature> features = const [],
    ]) async {
      addTearDown(tester.view.reset);
      setWindow(tester, size, features);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: MobileShell(tabs: tabs, prefs: prefs, vault: service),
        ),
      );
      await tester.tap(find.text('one'));
      await tester.pumpAndSettle();
    }

    Finder sidebar() => find.widgetWithText(AppBar, '連線');

    testWidgets('外螢幕(窄):全螢幕終端、有返回鈕、沒有左欄', (tester) async {
      addSession(1, 'one');
      await openTerminal(tester, _outer);
      expect(find.byType(TerminalView), findsOneWidget);
      expect(sidebar(), findsNothing);
      expect(find.byType(BackButton), findsOneWidget);
    });

    testWidgets('內螢幕攤平(寬):左欄連線列,點另一條直接切換', (tester) async {
      addSession(1, 'one');
      final two = addSession(2, 'two');
      await openTerminal(tester, _inner);

      expect(sidebar(), findsOneWidget);
      expect(tester.getSize(sidebar()).width, 300);
      expect(tester.getTopLeft(find.byType(TerminalView)).dx, greaterThan(300));

      await tester.tap(
        find.descendant(of: find.byType(ListView), matching: find.text('two')),
      );
      await tester.pump();
      final view = tester.widget<TerminalView>(find.byType(TerminalView));
      expect(identical(view.session, two), isTrue);
    });

    testWidgets('書本式半開:左欄剛好到摺痕,終端從摺痕右側開始', (tester) async {
      addSession(1, 'one');
      await openTerminal(tester, _inner, [_bookFold]);
      expect(tester.getSize(sidebar()).width, 455);
      expect(
        tester.getTopLeft(find.byType(TerminalView)).dx,
        greaterThanOrEqualTo(495),
      );
    });

    testWidgets('桌上型半開:摺痕換成 TerminalView 本地座標交給它分上下', (tester) async {
      addSession(1, 'one');
      await openTerminal(tester, _innerRotated, [_tableFold]);
      expect(sidebar(), findsNothing, reason: '直放 669pt 不分兩欄');

      final finder = find.byType(TerminalView);
      final top = tester.getTopLeft(finder).dy;
      final gap = tester.widget<TerminalView>(finder).foldGap;
      expect(gap, isNotNull);
      expect(top + gap!.top, 455);
      expect(top + gap.bottom, 495);

      // 攤平 → 不再切分
      setWindow(tester, _innerRotated);
      await tester.pump();
      expect(tester.widget<TerminalView>(finder).foldGap, isNull);
    });

    testWidgets('展開/折起:TerminalView 狀態原地保留,cols 跟著螢幕變', (tester) async {
      final session = addSession(1, 'one');
      await openTerminal(tester, _outer);
      await tester.pump(const Duration(milliseconds: 200));
      final state = tester.state<TerminalViewState>(find.byType(TerminalView));
      final narrowCols = session.cols;

      // 展開 → 內螢幕兩欄(TerminalView 換了父節點,GlobalKey 讓 state 跟過去)
      setWindow(tester, _inner);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(identical(tester.state(find.byType(TerminalView)), state), isTrue);
      expect(session.cols, greaterThan(narrowCols));

      // 半開成書本式 → 終端只剩摺痕右半
      final wideCols = session.cols;
      setWindow(tester, _inner, [_bookFold]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(identical(tester.state(find.byType(TerminalView)), state), isTrue);
      expect(session.cols, lessThan(wideCols));

      // 折回外螢幕
      setWindow(tester, _outer);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(identical(tester.state(find.byType(TerminalView)), state), isTrue);
      expect(session.cols, narrowCols);
      expect(tabs.tabs, hasLength(1));
    });

    testWidgets('寬螢幕可收起連線列:終端用滿、狀態保留、記在 prefs', (tester) async {
      addSession(1, 'one');
      await openTerminal(tester, _inner);
      final state = tester.state(find.byType(TerminalView));
      final listWidth = tester.getSize(find.byType(TerminalView)).width;

      await tester.tap(find.byKey(const Key('btn-collapse-list')));
      await tester.pump();
      expect(sidebar(), findsNothing);
      expect(prefs.connectionListCollapsed, isTrue);
      expect(tester.getTopLeft(find.byType(TerminalView)).dx, lessThan(20));
      expect(
        tester.getSize(find.byType(TerminalView)).width,
        greaterThan(listWidth + 250),
      );
      expect(identical(tester.state(find.byType(TerminalView)), state), isTrue);
      expect(find.byType(BackButton), findsOneWidget, reason: '收起時返回鈕還在');

      await tester.tap(find.byKey(const Key('btn-expand-list')));
      await tester.pump();
      expect(sidebar(), findsOneWidget);
      expect(prefs.connectionListCollapsed, isFalse);
      expect(identical(tester.state(find.byType(TerminalView)), state), isTrue);
    });

    testWidgets('書本式半開不能收(收了終端會壓摺痕),收起偏好也不套用', (tester) async {
      prefs.connectionListCollapsed = true;
      addSession(1, 'one');
      await openTerminal(tester, _inner, [_bookFold]);
      expect(sidebar(), findsOneWidget);
      expect(find.byKey(const Key('btn-collapse-list')), findsNothing);
      expect(
        tester.getTopLeft(find.byType(TerminalView)).dx,
        greaterThanOrEqualTo(495),
      );

      // 攤平 → 回到收起狀態
      setWindow(tester, _inner);
      await tester.pump();
      expect(sidebar(), findsNothing);
      expect(find.byKey(const Key('btn-expand-list')), findsOneWidget);
    });

    testWidgets('兩欄時斷線:切到另一條連線,不回首頁', (tester) async {
      addSession(1, 'one');
      final two = addSession(2, 'two');
      await openTerminal(tester, _inner);

      await tester.tap(find.byKey(const Key('btn-disconnect')));
      await tester.pumpAndSettle();
      expect(tabs.tabs.map((t) => t.id), [2]);
      final view = tester.widget<TerminalView>(find.byType(TerminalView));
      expect(identical(view.session, two), isTrue);

      // 最後一條也斷 → 回首頁
      await tester.tap(find.byKey(const Key('btn-disconnect')));
      await tester.pumpAndSettle();
      expect(find.byType(TerminalView), findsNothing);
      expect(tabs.tabs, isEmpty);
    });

    testWidgets('首頁寬螢幕:左欄列表 + 右欄提示', (tester) async {
      addTearDown(tester.view.reset);
      setWindow(tester, _inner);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: MobileShell(tabs: tabs, prefs: prefs, vault: service),
        ),
      );
      expect(find.text('從左邊選一條連線或一台主機'), findsOneWidget);
      expect(
        tester.getTopRight(find.byType(ListView)).dx,
        lessThanOrEqualTo(300),
      );
    });
  });

  group('TerminalView 摺痕與 resize', () {
    Future<NativeSession> pumpView(
      WidgetTester tester, {
      required Size size,
      ({double top, double bottom})? foldGap,
    }) async {
      addTearDown(tester.view.reset);
      tester.view
        ..devicePixelRatio = 1
        ..physicalSize = const Size(1000, 1000);
      final session = NativeSession.headless(cols: 40, rows: 12);
      addTearDown(session.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: SizedBox.fromSize(
              size: size,
              child: TerminalView(
                session: session,
                mobileUI: true,
                foldGap: foldGap,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return session;
    }

    testWidgets('桌上型:終端只在摺痕上方,下方是操作區 + 貼底工具列', (tester) async {
      final session = await pumpView(
        tester,
        size: const Size(600, 800),
        foldGap: (top: 400, bottom: 440),
      );
      final style = TerminalStyle();
      expect(session.rows, (400 / style.cellHeight).floor());

      final deck = tester.getRect(find.byKey(const Key('fold-deck')));
      expect(deck.top, 440);
      final toolbar = tester.getRect(find.byType(KeyToolbar));
      expect(toolbar.bottom, 800);
      expect(deck.bottom, toolbar.top);
    });

    testWidgets('摺痕下放不下工具列(鍵盤太高)→ 退回一般版面', (tester) async {
      await pumpView(
        tester,
        size: const Size(600, 460),
        foldGap: (top: 400, bottom: 440),
      );
      expect(find.byKey(const Key('fold-deck')), findsNothing);
      expect(tester.getRect(find.byType(KeyToolbar)).bottom, 460);
    });

    testWidgets('連續尺寸變化只在冷卻窗尾套最後一個(不逐格 resize)', (tester) async {
      addTearDown(tester.view.reset);
      tester.view
        ..devicePixelRatio = 1
        ..physicalSize = const Size(800, 600);
      final session = NativeSession.headless(cols: 40, rows: 12);
      addTearDown(session.dispose);
      await tester.pumpWidget(
        MaterialApp(home: TerminalView(session: session, mobileUI: false)),
      );
      await tester.pump();
      final first = session.cols; // 第一次照舊下一幀就套用

      // 冷卻窗內連續變化(像鍵盤動畫、折疊過場)
      for (final w in [700.0, 650.0, 600.0]) {
        tester.view.physicalSize = Size(w, 600);
        await tester.pump();
        expect(session.cols, first, reason: '冷卻中不逐格 resize');
      }

      await tester.pump(const Duration(milliseconds: 150));
      final style = TerminalStyle();
      expect(session.cols, (600 / style.cellWidth).floor());
    });
  });
}
