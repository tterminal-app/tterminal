// 滾輪失效的復原路徑(真實 PowerShell session + AppShell):
//
// 前景 TUI(claude code 的全螢幕畫面、vim…)被強制中斷時不會送復原序列,
// 終端就卡在 alt screen / 滑鼠回報模式——滾輪從此完全沒反應。這裡驗證兩條救援:
//   1. 前景還有程式在跑 → 不亂動,但狀態列要講明「滾輪由程式接管」+ 給重設鈕
//   2. 前景已經沒有程式 → TerminalView 的輪詢自動把模式收回來
//
// PTY reader 是獨立的原生 thread,所有等待都要包在 tester.runAsync 讓真實時間流動。

@TestOn('windows')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tterm_app/src/app_shell.dart';
import 'package:tterm_app/src/prefs.dart';
import 'package:tterm_app/src/tabs.dart';
import 'package:tterm_app/src/term_ffi.dart';
import 'package:tterm_app/src/vault_service.dart';

import 'support/fonts.dart';

/// claude code 進全螢幕畫面時送的那組:alt screen + 滑鼠回報。
const _enableSeq =
    r'[Console]::Write("$([char]27)[?1049h$([char]27)[?1000h$([char]27)[?1006h")';

void main() {
  setUpAll(() async => loadTestFonts());

  late Directory tmp;
  late TabsController tabs;
  late AppPrefs prefs;
  late VaultService vault;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tterm-stuck-modes');
    tabs = TabsController(
      spawn: () => NativeSession.spawnShell(
        cols: 80,
        rows: 24,
        program: 'powershell.exe',
      ),
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

  /// runAsync 讓真實時間流動(PTY reader 是原生 thread),pump(duration) 推動
  /// 測試裡的假時鐘——TerminalView 每 16ms、AppShell 每 500ms 的輪詢都靠它才會跑。
  Future<void> tick(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<bool> pumpUntil(
    WidgetTester tester,
    bool Function() done, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (done()) return true;
      await tick(tester);
    }
    return done();
  }

  Future<NativeSession> pumpShell(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: AppShell(tabs: tabs, prefs: prefs, vault: vault),
      ),
    );
    await tester.pump();
    return tabs.active!.session!;
  }

  testWidgets('TUI 被中斷後模式卡住 → 輪詢自動復原,滾輪回到 scrollback', (tester) async {
    final session = await pumpShell(tester);

    // 印完序列 PowerShell 就回到提示字元:沒有任何後代行程 = 設模式的程式死了
    session.write(Uint8List.fromList(utf8.encode('$_enableSeq\r\n')));
    expect(
      await pumpUntil(tester, () => session.modes & TermModes.wheelBlocking != 0),
      isTrue,
      reason: '引擎應先看到 alt screen + 滑鼠回報(mode bits ${session.modes})',
    );

    expect(
      await pumpUntil(tester, () => session.modes & TermModes.wheelBlocking == 0),
      isTrue,
      reason: '前景沒有程式了,輪詢應自動把模式收回來(mode bits ${session.modes})',
    );
  });

  testWidgets('前景程式還在 → 不自動清,狀態列給「重設終端」讓使用者自救', (tester) async {
    final session = await pumpShell(tester);

    // ping 會佔著前景約 30 秒 → shell 底下有後代行程 → 自動復原不該出手
    // (用會自己結束的指令,測試中斷時不會留下孤兒行程)
    session.write(
      Uint8List.fromList(
        utf8.encode('$_enableSeq; cmd /c ping -n 30 127.0.0.1\r\n'),
      ),
    );
    expect(
      await pumpUntil(
        tester,
        () => find.byKey(const Key('btn-reset-modes')).evaluate().isNotEmpty,
      ),
      isTrue,
      reason: '狀態列應出現「重設終端」(mode bits ${session.modes})',
    );
    expect(find.text('滾輪由程式接管'), findsOneWidget);

    // 前景程式還在,模式不該被自動清掉(讓輪詢跑過好幾輪再確認)
    for (var i = 0; i < 20; i++) {
      await tick(tester);
    }
    expect(
      session.modes & TermModes.wheelBlocking != 0,
      isTrue,
      reason: '前景程式還在跑時不能動它的滑鼠/畫面模式',
    );

    await tester.tap(find.byKey(const Key('btn-reset-modes')));
    await tester.pump();
    expect(
      session.modes & TermModes.wheelBlocking,
      0,
      reason: '按下重設終端後滾輪要立刻回到 scrollback',
    );
  });
}
