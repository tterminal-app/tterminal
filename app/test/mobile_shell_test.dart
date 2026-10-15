// 手機版 shell(connection list 畫面流)widget 測試。
// VaultService 用真 FFI + 暫存目錄;session 用 headless 注入。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tterm_app/src/mobile_shell.dart';
import 'package:tterm_app/src/prefs.dart';
import 'package:tterm_app/src/tabs.dart';
import 'package:tterm_app/src/term_ffi.dart';
import 'package:tterm_app/src/terminal_view.dart';
import 'package:tterm_app/src/vault_service.dart';

void main() {
  late Directory tmp;
  late VaultService service;
  late TabsController tabs;
  late AppPrefs prefs;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tterm-mobile-shell');
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

  Future<void> pumpShell(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: MobileShell(tabs: tabs, prefs: prefs, vault: service),
      ),
    );
    await tester.pump();
  }

  testWidgets('首頁:空 vault 顯示引導、有 host 顯示列表(星號置頂)', (tester) async {
    await pumpShell(tester);
    expect(find.textContaining('還沒有 host'), findsOneWidget);

    service.upsert(
      kind: 'host',
      name: 'zeta',
      data: {'address': 'z.example.com', 'port': 22, 'username': 'u'},
    );
    service.upsert(
      kind: 'host',
      name: 'alpha',
      data: {
        'address': 'a.example.com',
        'port': 2222,
        'username': 'root',
        'pinned': true,
      },
    );
    await tester.pump();

    expect(find.text('alpha'), findsOneWidget);
    expect(find.text('root@a.example.com:2222'), findsOneWidget);
    // 星號置頂:alpha(pinned)排在 zeta 前
    final alphaY = tester.getTopLeft(find.text('alpha')).dy;
    final zetaY = tester.getTopLeft(find.text('zeta')).dy;
    expect(alphaY, lessThan(zetaY));
  });

  testWidgets('進行中 session:列表顯示、點擊開全螢幕終端、返回保留連線', (tester) async {
    final session = NativeSession.headless(cols: 40, rows: 12);
    tabs.tabs.add(TermTab(1, session: session, label: 'myhost'));

    await pumpShell(tester);
    expect(find.text('進行中'), findsOneWidget);
    expect(find.text('myhost'), findsOneWidget);

    // 點開 → 全螢幕終端頁
    await tester.tap(find.text('myhost'));
    await tester.pumpAndSettle();
    expect(find.byType(TerminalView), findsOneWidget);

    // 返回 → 連線還在(headless session 會被標成已結束,標題帶後綴)
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.textContaining('myhost'), findsOneWidget);
    expect(tabs.tabs, hasLength(1));
    expect(identical(tabs.tabs.single.session, session), isTrue);
    expect(session.copyGrid(), isNotEmpty); // session 沒被 dispose,仍可讀
  });

  testWidgets('斷線鈕移除 session;refillOnEmpty=false 不自動補分頁', (tester) async {
    final session = NativeSession.headless(cols: 40, rows: 12);
    tabs.tabs.add(TermTab(1, session: session, label: 'myhost'));

    await pumpShell(tester);
    await tester.tap(find.byKey(const ValueKey('btn-close-1')));
    await tester.pump();

    expect(tabs.tabs, isEmpty, reason: '手機沒有「空分頁」概念,不該自動補開');
    expect(find.text('進行中'), findsNothing);
  });

  testWidgets('終端頁的斷線鈕:關閉連線並回到首頁', (tester) async {
    final session = NativeSession.headless(cols: 40, rows: 12);
    tabs.tabs.add(TermTab(1, session: session, label: 'myhost'));

    await pumpShell(tester);
    await tester.tap(find.text('myhost'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('btn-disconnect')));
    await tester.pumpAndSettle();

    expect(find.byType(TerminalView), findsNothing);
    expect(find.textContaining('還沒有 host'), findsOneWidget); // 回到首頁
    expect(tabs.tabs, isEmpty);
  });
}
