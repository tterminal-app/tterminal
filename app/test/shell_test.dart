// AppShell 測試:分頁開關/切換、上方與側邊 tab list、快捷鍵、prefs 持久化。
// session 用 headless(不開真實 shell)。

import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tterm_app/src/app_shell.dart';
import 'package:tterm_app/src/prefs.dart';
import 'package:tterm_app/src/tabs.dart';
import 'package:tterm_app/src/term_ffi.dart';
import 'package:tterm_app/src/terminal_view.dart';
import 'package:tterm_app/src/vault_service.dart';

import 'support/fonts.dart';

void main() {
  setUpAll(() async => loadTestFonts());

  late Directory tmp;
  late TabsController tabs;
  late AppPrefs prefs;
  late VaultService vault;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tterm-shell-test');
    tabs = TabsController(
      spawn: () => NativeSession.headless(cols: 60, rows: 16),
    );
    prefs = AppPrefs.loadSync('${tmp.path}/prefs.json');
    vault = VaultService.open('${tmp.path}/vault');
  });

  tearDown(() async {
    tabs.dispose();
    vault.dispose();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> pumpShell(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: AppShell(tabs: tabs, prefs: prefs, vault: vault),
      ),
    );
    await tester.pump();
  }

  testWidgets('狀態列顯示目前分頁的連線資訊,切分頁跟著換', (tester) async {
    await pumpShell(tester);
    expect(find.byKey(const Key('conn-status-bar')), findsOneWidget);
    expect(find.text('本機終端機'), findsOneWidget);

    // 模擬 SSH 分頁(connInfo 有值);connect 永不完成 → 停在連線中
    tabs.newAsyncTab('web1', connInfo: 'root@10.0.0.5:22',
        () => Completer<NativeSession>().future);
    await tester.pump();
    expect(find.text('web1  ·  root@10.0.0.5:22'), findsOneWidget);
    expect(find.text('連線中…'), findsOneWidget);
    expect(find.text('本機終端機'), findsNothing);

    // 切回本機分頁 → 狀態列跟著換
    tabs.activate(0);
    await tester.pump();
    expect(find.text('本機終端機'), findsOneWidget);
    expect(find.text('web1  ·  root@10.0.0.5:22'), findsNothing);
  });

  testWidgets('已結束的分頁:狀態列出現重新連線,按下去換新 session', (tester) async {
    await pumpShell(tester);
    final tab = tabs.tabs.first;
    final oldSession = tab.session;
    tabs.markExited(tab.id);
    await tester.pump();
    expect(find.text('已結束'), findsOneWidget);
    expect(find.byKey(const Key('btn-reconnect')), findsOneWidget);

    await tester.tap(find.byKey(const Key('btn-reconnect')));
    await tester.pump(); // connecting
    await tester.pump(); // connectFn 完成、attach 新 session
    expect(tab.exited, isFalse);
    expect(tab.session, isNotNull);
    expect(identical(tab.session, oldSession), isFalse,
        reason: '要是全新的 session');
    expect(find.text('已結束'), findsNothing);
    expect(find.byKey(const Key('btn-reconnect')), findsNothing);
  });

  testWidgets('預設一個分頁,+ 開新分頁,✕ 關閉', (tester) async {
    await pumpShell(tester);
    expect(tabs.tabs.length, 1);
    expect(find.byKey(const Key('tab-strip-top')), findsOneWidget);

    await tester.tap(find.byKey(const Key('btn-new-tab')));
    await tester.pump();
    expect(tabs.tabs.length, 2);
    expect(tabs.activeIndex, 1, reason: '新分頁自動成為 active');

    final firstId = tabs.tabs.first.id;
    await tester.tap(find.byKey(ValueKey('tab-close-$firstId')));
    await tester.pump();
    expect(tabs.tabs.length, 1);

    // 關掉最後一個分頁 → 自動補一個新的(永遠至少一個)
    final lastId = tabs.tabs.first.id;
    await tester.tap(find.byKey(ValueKey('tab-close-$lastId')));
    await tester.pump();
    expect(tabs.tabs.length, 1);
    expect(tabs.tabs.first.id, isNot(lastId));
  });

  testWidgets('SSH 分頁還連著也能重新連線(狀態列按鈕 → 確認 → 換新 session)',
      (tester) async {
    await pumpShell(tester);
    // 連上的 SSH 分頁:connectFn 立刻給 session
    NativeSession makeSession() => NativeSession.headless(cols: 60, rows: 16);
    tabs.newAsyncTab('web1', connInfo: 'root@10.0.0.5:22',
        () async => makeSession());
    await tester.pump(); // connecting
    await tester.pump(); // attach
    final tab = tabs.tabs.last;
    final oldSession = tab.session;
    expect(oldSession, isNotNull);
    expect(tab.exited, isFalse);

    // 還活著的 SSH 分頁也看得到重新連線(本地分頁沒斷線時不給)
    expect(find.byKey(const Key('btn-reconnect')), findsOneWidget);
    await tester.tap(find.byKey(const Key('btn-reconnect')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    // 活著的連線要先確認,免得誤觸砍掉正在跑的 session
    expect(find.byKey(const Key('btn-confirm-reconnect')), findsOneWidget);
    await tester.tap(find.byKey(const Key('btn-confirm-reconnect')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();

    expect(tab.session, isNotNull);
    expect(identical(tab.session, oldSession), isFalse, reason: '要是全新的 session');
  });

  testWidgets('本地分頁沒斷線時狀態列不給重新連線', (tester) async {
    await pumpShell(tester);
    expect(find.byKey(const Key('btn-reconnect')), findsNothing);
  });

  testWidgets('右鍵分頁:選單可重新連線 / 關閉', (tester) async {
    await pumpShell(tester);
    await tester.tap(find.byKey(const Key('btn-new-tab')));
    await tester.pump();
    final tab = tabs.tabs.first;
    final oldSession = tab.session;

    final gesture =
        await tester.startGesture(
      tester.getCenter(find.byKey(ValueKey('tab-chip-${tab.id}'))),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byKey(ValueKey('tab-menu-reconnect-${tab.id}')), findsOneWidget);

    await tester.tap(find.byKey(ValueKey('tab-menu-reconnect-${tab.id}')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    // 活著的 session → 先確認
    await tester.tap(find.byKey(const Key('btn-confirm-reconnect')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    expect(identical(tab.session, oldSession), isFalse);
  });

  testWidgets('點分頁切換 active,IndexedStack 保留所有分頁', (tester) async {
    await pumpShell(tester);
    await tester.tap(find.byKey(const Key('btn-new-tab')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('btn-new-tab')));
    await tester.pump();
    expect(tabs.tabs.length, 3);
    expect(tabs.activeIndex, 2);

    await tester.tap(find.byKey(ValueKey('tab-chip-${tabs.tabs[0].id}')));
    await tester.pump();
    expect(tabs.activeIndex, 0);

    final stack = tester.widget<IndexedStack>(find.byType(IndexedStack));
    expect(stack.children.length, 3, reason: '切走的分頁仍保活');
    expect(stack.index, 0);
  });

  // 拖移分頁:ReorderableDragStartListener 是「按下就能拖」,但要有幾次
  // 移動事件 reorder 才會跟著算落點。
  Future<void> dragTab(
    WidgetTester tester,
    int id,
    Offset total,
  ) async {
    final start = tester.getCenter(find.byKey(ValueKey('tab-chip-$id')));
    final gesture = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 50));
    for (var i = 1; i <= 8; i++) {
      await gesture.moveTo(start + total * (i / 8));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  testWidgets('水平 tabs:拖移重新排序,active 跟著原本的分頁', (tester) async {
    await pumpShell(tester);
    await tester.tap(find.byKey(const Key('btn-new-tab')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('btn-new-tab')));
    await tester.pump();
    final ids = [for (final t in tabs.tabs) t.id];
    expect(ids.length, 3);

    // 第一個往右拖過兩個 chip(chip 寬 168)→ 排到最後
    tabs.activate(0);
    await tester.pump();
    await dragTab(tester, ids[0], const Offset(360, 0));

    expect([for (final t in tabs.tabs) t.id], [ids[1], ids[2], ids[0]]);
    expect(tabs.active!.id, ids[0], reason: 'active 是分頁本身,不是位置');
  });

  // 既有的兩個拖移測試都是「拖到最尾端」,那個位置會被 TabsController.reorder
  // 的 clamp 夾住,索引語意就算差一格也看不出來。這裡補中間落點:分頁 0 只往右
  // 移一格,結果必須是 [1,0,2,3] 而不是 [1,2,0,3]。
  testWidgets('水平 tabs:往右移一格落在中間(不是被推到最後)', (tester) async {
    await pumpShell(tester);
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.byKey(const Key('btn-new-tab')));
      await tester.pump();
    }
    final ids = [for (final t in tabs.tabs) t.id];
    expect(ids.length, 4);

    tabs.activate(0);
    await tester.pump();
    // chip 寬 168:拖過一個 chip 多一點
    await dragTab(tester, ids[0], const Offset(180, 0));

    expect([for (final t in tabs.tabs) t.id], [ids[1], ids[0], ids[2], ids[3]]);
  });

  testWidgets('垂直 tabs:拖移重新排序', (tester) async {
    prefs.tabBarPosition = TabBarPosition.side;
    await pumpShell(tester);
    await tester.tap(find.byKey(const Key('btn-new-tab')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('btn-new-tab')));
    await tester.pump();
    final ids = [for (final t in tabs.tabs) t.id];
    expect(find.byKey(const Key('tab-list-side')), findsOneWidget);

    // 最後一個往上拖過兩列(列高 36)→ 排到最前
    await dragTab(tester, ids[2], const Offset(0, -80));
    expect([for (final t in tabs.tabs) t.id], [ids[2], ids[0], ids[1]]);
  });

  testWidgets('側邊模式:垂直 tab list + prefs 持久化', (tester) async {
    await pumpShell(tester);
    expect(find.byKey(const Key('tab-strip-top')), findsOneWidget);
    expect(find.byKey(const Key('tab-strip-side')), findsNothing);

    prefs.tabBarPosition = TabBarPosition.side;
    await tester.pump();
    expect(find.byKey(const Key('tab-strip-side')), findsOneWidget);
    expect(find.byKey(const Key('tab-strip-top')), findsNothing);

    // prefs 落地 + 重新載入還原
    final reloaded = AppPrefs.loadSync('${tmp.path}/prefs.json');
    expect(reloaded.tabBarPosition, TabBarPosition.side);
  });

  testWidgets('側邊模式:拖拉握把調整寬度並持久化', (tester) async {
    prefs.tabBarPosition = TabBarPosition.side;
    await pumpShell(tester);
    expect(find.byKey(const Key('side-resize-handle')), findsOneWidget);

    // 初始寬度 = 側欄 SizedBox 寬度
    double sideWidth() => tester
        .getSize(find.byKey(const Key('tab-strip-side')))
        .width;
    final before = sideWidth();
    expect(before, closeTo(kSideTabDefaultWidth, 0.5));

    // 往右拖 60px → 側欄變寬
    await tester.drag(
      find.byKey(const Key('side-resize-handle')),
      const Offset(60, 0),
    );
    await tester.pump();
    expect(prefs.sideTabWidth, closeTo(before + 60, 1));
    expect(sideWidth(), closeTo(before + 60, 1));

    // 超過上限會被 clamp
    await tester.drag(
      find.byKey(const Key('side-resize-handle')),
      const Offset(1000, 0),
    );
    await tester.pump();
    expect(prefs.sideTabWidth, kSideTabMaxWidth);

    // 落地 + 重新載入還原
    final reloaded = AppPrefs.loadSync('${tmp.path}/prefs.json');
    expect(reloaded.sideTabWidth, kSideTabMaxWidth);
  });

  testWidgets('快捷鍵:Ctrl+Shift+T 新分頁、Ctrl+Shift+W 關閉、Ctrl+Tab 切換',
      (tester) async {
    await pumpShell(tester);
    expect(tabs.tabs.length, 1);

    Future<void> combo(LogicalKeyboardKey key, {bool shift = false}) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyDownEvent(key);
      await tester.sendKeyUpEvent(key);
      if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
    }

    await combo(LogicalKeyboardKey.keyT, shift: true);
    expect(tabs.tabs.length, 2);

    await combo(LogicalKeyboardKey.tab);
    expect(tabs.activeIndex, 0, reason: 'Ctrl+Tab 循環切換');

    await combo(LogicalKeyboardKey.keyW, shift: true);
    expect(tabs.tabs.length, 1);
  });

  testWidgets('字體縮放:Ctrl+=/− 調大小、Ctrl+0 重設,終端 cols 跟著變', (tester) async {
    await pumpShell(tester);
    final session = tabs.tabs.first.session!;
    await tester.pump(); // post-frame resize 套用初始 cols/rows
    final colsBefore = session.cols;

    Future<void> combo(LogicalKeyboardKey key) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(key);
      await tester.sendKeyUpEvent(key);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      await tester.pump(); // 字體變更後的 post-frame resize
    }

    await combo(LogicalKeyboardKey.equal);
    expect(prefs.termFontSize, kTermFontDefaultSize + 1);
    expect(session.cols, lessThan(colsBefore), reason: '字變大 → 塞得下的欄數變少');

    await combo(LogicalKeyboardKey.minus);
    await combo(LogicalKeyboardKey.minus);
    expect(prefs.termFontSize, kTermFontDefaultSize - 1);
    expect(session.cols, greaterThan(colsBefore), reason: '字變小 → 欄數變多');

    await combo(LogicalKeyboardKey.digit0);
    expect(prefs.termFontSize, kTermFontDefaultSize);
    expect(session.cols, colsBefore);

    // Ctrl+滾輪:上=放大、下=縮小
    final center = tester.getCenter(find.byType(IndexedStack));
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(center));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, -120)));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(prefs.termFontSize, kTermFontDefaultSize + 1);

    // prefs 落地
    final reloaded = AppPrefs.loadSync('${tmp.path}/prefs.json');
    expect(reloaded.termFontSize, kTermFontDefaultSize + 1);
  });

  testWidgets('聽寫/貼上守門:焦點在設定頁文字框時不進終端', (tester) async {
    // 攔下 Dart→native 的 terminalFocus 回報(native 靠它決定要不要攔 Ctrl+V)
    final focusLog = <bool>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('tterminal/dictate'),
      (call) async {
        if (call.method == 'terminalFocus') focusLog.add(call.arguments as bool);
        return null;
      },
    );

    await pumpShell(tester);
    final termState =
        tester.state<TerminalViewState>(find.byType(TerminalView));
    expect(termState.hasFocus, isTrue, reason: '啟動後終端應持有焦點');
    expect(focusLog.isNotEmpty && focusLog.last, isTrue,
        reason: '終端取得焦點時應回報 native terminalFocus=true');

    // native 貼上事件(Ctrl+V)在終端有焦點時會被接受(守門條件成立)
    Future<void> firePaste(String text) async {
      final data = const StandardMethodCodec()
          .encodeMethodCall(MethodCall('paste', text));
      await tester.binding.defaultBinaryMessenger
          .handlePlatformMessage('tterminal/dictate', data, (_) {});
    }

    await firePaste('while-focused'); // 不炸即可(headless 沒有 IO)

    // 打開設定頁 → 焦點離開終端 → 守門條件變 false,貼上不進 PTY
    await tester.tap(find.byKey(const Key('btn-settings')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(termState.hasFocus, isFalse,
        reason: '設定頁開啟後終端不該持有焦點(貼上守門的依據)');
    expect(focusLog.last, isFalse,
        reason: '焦點離開終端要回報 native,native 才會放行 Ctrl+V 給文字框');

    // 點設定頁的文字框,焦點在文字框上
    await tester.tap(find.byKey(const Key('sync-server')));
    await tester.pump();
    expect(termState.hasFocus, isFalse);
    await firePaste('while-in-settings'); // 守門擋下,不進終端

    // 關閉設定頁 → 焦點回到終端,貼上恢復可用
    await tester.pageBack();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(termState.hasFocus, isTrue, reason: '回到工作區焦點應還給終端');
    expect(focusLog.last, isTrue, reason: '焦點回終端要回報 native 恢復攔截');
  });

  testWidgets('session 建立失敗:分頁顯示錯誤而不是 crash', (tester) async {
    final failing = TabsController(spawn: () => throw StateError('spawn 失敗'));
    addTearDown(failing.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: AppShell(tabs: failing, prefs: prefs, vault: vault),
      ),
    );
    await tester.pump();
    expect(find.textContaining('無法啟動終端'), findsOneWidget);
    expect(find.textContaining('spawn 失敗'), findsOneWidget);
  });

  group('檔案側窗與編輯器 pane', () {
    late Directory fdir;

    setUp(() async {
      fdir = await Directory.systemTemp.createTemp('tterm-shell-files');
      File('${fdir.path}/a.txt').writeAsStringSync('aaa');
      File('${fdir.path}/b.txt').writeAsStringSync('bbb');
      prefs.filePaneVisible = true;
    });

    tearDown(() async {
      try {
        await fdir.delete(recursive: true);
      } catch (_) {}
    });

    Future<void> pumpWithFiles(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: AppShell(
            tabs: tabs,
            prefs: prefs,
            vault: vault,
            filePaneDir: fdir.path,
          ),
        ),
      );
      await tester.pump();
    }

    // AppShell 下不能 pumpAndSettle:終端機會持續排 frame,永遠不會靜止。
    // 用兩次 pump(第二次帶時長走完 dialog 開關動畫)。
    Future<void> settle(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
    }

    // 檔案列表是「單擊反白、雙擊開啟」:開檔要點兩下
    Future<void> doubleTapEntry(WidgetTester tester, String name) async {
      final f = find.byKey(ValueKey('file-entry-$name'));
      await tester.tap(f);
      await tester.tap(f);
      await settle(tester);
    }

    Future<void> openA(WidgetTester tester) async {
      await doubleTapEntry(tester, 'a.txt');
    }

    // 列目錄是同步的(遠端還是一個 SFTP 網路來回),掛在切分頁上會卡住切換。
    // 用「側窗外面偷偷新增的檔案有沒有跑出來」當作有沒有重載的證據。
    testWidgets('切分頁不重載檔案側窗', (tester) async {
      await pumpWithFiles(tester);
      File('${fdir.path}/c.txt').writeAsStringSync('ccc');
      expect(find.byKey(const ValueKey('file-entry-c.txt')), findsNothing);

      tabs.newTab();
      await settle(tester);
      tabs.activate(0);
      await settle(tester);
      expect(find.byKey(const ValueKey('file-entry-c.txt')), findsNothing,
          reason: '切分頁不該重列目錄');

      // 使用者自己按重新整理才重列
      await tester.tap(find.byKey(const Key('file-refresh')));
      await settle(tester);
      expect(find.byKey(const ValueKey('file-entry-c.txt')), findsOneWidget);
    });

    testWidgets('點檔案 → 編輯器 pane 開在檔案側窗右邊,終端機沒被蓋掉',
        (tester) async {
      await pumpWithFiles(tester);
      expect(find.byKey(const Key('editor-pane')), findsNothing);

      await openA(tester);

      expect(find.byKey(const Key('editor-pane')), findsOneWidget);
      expect(find.text('aaa'), findsOneWidget);
      // 三個區塊同時在畫面上:終端機(IndexedStack)、檔案列表、編輯器
      expect(find.byType(IndexedStack), findsOneWidget);
      expect(find.byKey(const Key('file-list')), findsOneWidget);
      // 左→右順序:終端機 < 檔案列表 < 編輯器
      final termX = tester.getTopLeft(find.byType(IndexedStack)).dx;
      final filesX = tester.getTopLeft(find.byKey(const Key('file-list'))).dx;
      final editorX =
          tester.getTopLeft(find.byKey(const Key('editor-pane'))).dx;
      expect(filesX, greaterThan(termX));
      expect(editorX, greaterThan(filesX));
    });

    testWidgets('dirty 換檔 → 確認對話框;取消保留,捨棄換檔', (tester) async {
      await pumpWithFiles(tester);
      await openA(tester);

      await tester.enterText(find.byKey(const Key('editor-text')), 'changed');
      await tester.pump();

      // 雙擊另一個檔 → 出現確認
      await doubleTapEntry(tester, 'b.txt');
      expect(find.text('捨棄未存檔的修改?'), findsOneWidget);

      // 取消 → 還是 a 的內容
      await tester.tap(find.text('取消'));
      await settle(tester);
      expect(find.text('changed'), findsOneWidget);

      // 再雙擊 b → 捨棄 → 顯示 b 的內容
      await doubleTapEntry(tester, 'b.txt');
      await tester.tap(find.byKey(const Key('btn-discard-edits')));
      await settle(tester);
      expect(find.text('bbb'), findsOneWidget);
      expect(find.text('changed'), findsNothing);
    });

    testWidgets('X 關閉編輯器;寬度拖拉並持久化', (tester) async {
      await pumpWithFiles(tester);
      await openA(tester);

      final before =
          tester.getSize(find.byKey(const Key('editor-pane'))).width;
      expect(before, closeTo(kEditorPaneDefaultWidth, 0.5));

      // 握把往左拖 60px → 編輯器變寬
      await tester.drag(
        find.byKey(const Key('editor-resize-handle')),
        const Offset(-60, 0),
      );
      await tester.pump();
      expect(prefs.editorPaneWidth, closeTo(before + 60, 1));

      final reloaded = AppPrefs.loadSync('${tmp.path}/prefs.json');
      expect(reloaded.editorPaneWidth, closeTo(before + 60, 1));

      await tester.tap(find.byKey(const Key('btn-close-editor')));
      await settle(tester);
      expect(find.byKey(const Key('editor-pane')), findsNothing);
    });

    testWidgets('Esc 關閉編輯器', (tester) async {
      await pumpWithFiles(tester);
      await openA(tester);
      expect(find.byKey(const Key('editor-pane')), findsOneWidget);

      await tester.tap(find.byKey(const Key('editor-text')));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(find.byKey(const Key('editor-pane')), findsNothing);
    });

    testWidgets('檔案側窗收掉,編輯器留著', (tester) async {
      await pumpWithFiles(tester);
      await openA(tester);

      await tester.tap(find.byKey(const Key('btn-toggle-files')));
      await settle(tester);
      expect(find.byKey(const Key('file-list')), findsNothing);
      expect(find.byKey(const Key('editor-pane')), findsOneWidget,
          reason: '編輯器獨立於檔案側窗');
    });
  });
}
