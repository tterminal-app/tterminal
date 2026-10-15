// 檔案側窗:列表/導覽/cwd 跟隨,與編輯器讀寫/原子存檔。

import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tterm_app/src/file_editor.dart';
import 'package:tterm_app/src/file_pane.dart';

/// 假的遠端來源:不需要真的 SSH,單純回報 isRemote=true + 固定清單,
/// 用來驗證遠端檔案列也會掛上拖出手勢。
class _FakeRemoteSource implements FileSource {
  @override
  bool get isRemote => true;

  @override
  List<FileEntry> list(String path) => [
        FileEntry(
            path: '/home/readme.txt',
            name: 'readme.txt',
            isDir: false,
            size: 10,
            modified: null),
        FileEntry(
            path: '/home/logs', name: 'logs', isDir: true, size: 0, modified: null),
      ];

  @override
  String parentOf(String path) => '/';

  @override
  bool isRoot(String path) => path == '/';
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tterm-files');
    // 佈置:sub/ 目錄、a.txt、b.log
    Directory('${tmp.path}/sub').createSync();
    File('${tmp.path}/a.txt').writeAsStringSync('hello');
    File('${tmp.path}/b.log').writeAsStringSync('log');
    File('${tmp.path}/sub/nested.txt').writeAsStringSync('deep');
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  group('FilePaneController', () {
    test('列出目錄:目錄在前、名稱排序', () {
      final c = FilePaneController(tmp.path);
      expect(c.entries.map((e) => e.name), ['sub', 'a.txt', 'b.log']);
      expect(c.entries.first.isDir, isTrue);
    });

    test('進入子目錄、回上層', () {
      final c = FilePaneController(tmp.path);
      final sub = c.entries.firstWhere((e) => e.name == 'sub');
      c.enter(sub);
      expect(c.entries.map((e) => e.name), ['nested.txt']);
      c.up();
      expect(c.entries.map((e) => e.name), ['sub', 'a.txt', 'b.log']);
    });

    test('cwd 跟隨:follow 開啟時切換到新目錄', () {
      final c = FilePaneController(tmp.path);
      expect(c.followCwd, isTrue);
      c.onCwdChanged('${tmp.path}/sub');
      expect(c.path, endsWith('sub'));

      // 關閉 follow 後不再跟隨
      c.toggleFollow();
      c.onCwdChanged(tmp.path);
      expect(c.path, endsWith('sub'));
    });

    test('cwd 不存在或相同不動作', () {
      final c = FilePaneController(tmp.path);
      c.onCwdChanged('${tmp.path}/does-not-exist');
      expect(c.path, tmp.path);
      c.onCwdChanged(null);
      expect(c.path, tmp.path);
    });

    test('讀不到的目錄:error 有值、entries 空', () {
      final c = FilePaneController('${tmp.path}/nope-not-here');
      expect(c.error, isNotNull);
      expect(c.entries, isEmpty);
    });
  });

  testWidgets('FilePane:拖曳檔案觸發 onDragFileOut(帶正確路徑)', (tester) async {
    final c = FilePaneController(tmp.path);
    String? dragged;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FilePane(
          controller: c,
          onOpenFile: (_) {},
          onDragFileOut: (p) => dragged = p,
        ),
      ),
    ));
    await tester.pump();

    // 在檔案列上開始拖曳(非目錄才可拖出)
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('file-entry-a.txt'))),
    );
    await gesture.moveBy(const Offset(20, 20));
    await tester.pump();
    await gesture.up();
    expect(dragged, endsWith('a.txt'));
  });

  testWidgets('FilePane:遠端檔案也能拖出(onDragFileOut 會觸發)', (tester) async {
    final c = FilePaneController(tmp.path);
    c.setSource(_FakeRemoteSource(), '/home');
    String? dragged;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FilePane(
          controller: c,
          onOpenFile: (_) {},
          onDragFileOut: (p) => dragged = p,
        ),
      ),
    ));
    await tester.pump();
    expect(c.isRemote, isTrue);

    // 遠端檔案(readme.txt)開始拖曳 → 應觸發 onDragFileOut 帶遠端路徑
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('file-entry-readme.txt'))),
    );
    await gesture.moveBy(const Offset(20, 20));
    await tester.pump();
    await gesture.up();
    expect(dragged, '/home/readme.txt');
  });

  testWidgets('FilePane:單擊反白不開啟,雙擊才進目錄/開檔案', (tester) async {
    final c = FilePaneController(tmp.path);
    String? opened;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FilePane(controller: c, onOpenFile: (p) => opened = p),
      ),
    ));
    await tester.pump();

    // 單擊檔案 → 只反白,不開啟
    await tester.tap(find.byKey(const ValueKey('file-entry-a.txt')));
    await tester.pump();
    expect(opened, isNull);
    expect(c.selected, endsWith('a.txt'));
    final startPath = c.path;

    // 雙擊目錄 → 進入(換目錄後反白清掉)
    await tester.tap(find.byKey(const ValueKey('file-entry-sub')));
    await tester.tap(find.byKey(const ValueKey('file-entry-sub')));
    await tester.pump();
    expect(c.path, endsWith('sub'));
    expect(c.path, isNot(startPath));
    expect(c.selected, isNull);

    // 上一層,雙擊檔案 → onOpenFile
    await tester.tap(find.byKey(const Key('file-up')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('file-entry-a.txt')));
    await tester.tap(find.byKey(const ValueKey('file-entry-a.txt')));
    await tester.pump();
    expect(opened, endsWith('a.txt'));
  });

  testWidgets('FilePane:底部路徑列顯示目前路徑並跟著導覽更新', (tester) async {
    final c = FilePaneController(tmp.path);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FilePane(controller: c, onOpenFile: (_) {}),
      ),
    ));
    await tester.pump();

    expect(find.byKey(const Key('file-path-bar')), findsOneWidget);
    expect(find.text(c.path), findsOneWidget);

    // 進 sub → 路徑列跟著換
    await tester.tap(find.byKey(const ValueKey('file-entry-sub')));
    await tester.tap(find.byKey(const ValueKey('file-entry-sub')));
    await tester.pump();
    expect(c.path, endsWith('sub'));
    expect(find.text(c.path), findsOneWidget);
  });

  testWidgets('FilePane:跳至 CWD 按鈕觸發 callback;沒給 callback 不顯示', (tester) async {
    final c = FilePaneController(tmp.path);
    var jumped = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FilePane(
          controller: c,
          onOpenFile: (_) {},
          onJumpToCwd: () => jumped++,
        ),
      ),
    ));
    await tester.pump();
    await tester.tap(find.byKey(const Key('file-goto-cwd')));
    expect(jumped, 1);

    // 沒給 callback → 按鈕不出現
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FilePane(controller: c, onOpenFile: (_) {}),
      ),
    ));
    await tester.pump();
    expect(find.byKey(const Key('file-goto-cwd')), findsNothing);
  });

  testWidgets('FilePane:右鍵開 context menu →「用 VS Code 開啟」觸發 callback(帶反白)',
      (tester) async {
    final c = FilePaneController(tmp.path);
    FileEntry? opened;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FilePane(
          controller: c,
          onOpenFile: (_) {},
          onOpenInVscode: (e) => opened = e,
        ),
      ),
    ));
    await tester.pump();

    // 右鍵檔案 → 先反白、跳出選單
    await tester.tapAt(
      tester.getCenter(find.byKey(const ValueKey('file-entry-a.txt'))),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    expect(c.selected, endsWith('a.txt'));
    expect(find.text('用 VS Code 開啟'), findsOneWidget);

    // 點選單項 → callback 帶該項目
    await tester.tap(find.text('用 VS Code 開啟'));
    await tester.pumpAndSettle();
    expect(opened, isNotNull);
    expect(opened!.name, 'a.txt');
    expect(opened!.isDir, isFalse);
  });

  testWidgets('FilePane:資料夾也能右鍵用 VS Code 開啟(isDir=true)', (tester) async {
    final c = FilePaneController(tmp.path);
    FileEntry? opened;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FilePane(
          controller: c,
          onOpenFile: (_) {},
          onOpenInVscode: (e) => opened = e,
        ),
      ),
    ));
    await tester.pump();

    await tester.tapAt(
      tester.getCenter(find.byKey(const ValueKey('file-entry-sub'))),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('用 VS Code 開啟'));
    await tester.pumpAndSettle();
    expect(opened?.name, 'sub');
    expect(opened?.isDir, isTrue);
  });

  testWidgets('FilePane:沒給 onOpenInVscode → 右鍵不跳選單', (tester) async {
    final c = FilePaneController(tmp.path);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FilePane(controller: c, onOpenFile: (_) {}),
      ),
    ));
    await tester.pump();

    await tester.tapAt(
      tester.getCenter(find.byKey(const ValueKey('file-entry-a.txt'))),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    expect(find.text('用 VS Code 開啟'), findsNothing);
  });

  group('FileEditorPane', () {
    Future<void> pumpEditor(WidgetTester tester, String path,
        {VoidCallback? onClose}) async {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
          body: FileEditorPane(path: path, onClose: onClose ?? () {}),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('開檔顯示內容、編輯後儲存寫回', (tester) async {
      final path = '${tmp.path}/a.txt';
      await pumpEditor(tester, path);

      expect(find.text('hello'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('editor-text')), 'hello world');
      await tester.pump();
      await tester.tap(find.byKey(const Key('btn-save-file')));
      await tester.pumpAndSettle();

      expect(File(path).readAsStringSync(), 'hello world');
    });

    testWidgets('二進位檔:唯讀提示', (tester) async {
      final path = '${tmp.path}/bin.dat';
      File(path).writeAsBytesSync([0, 1, 2, 3, 255]);
      await pumpEditor(tester, path);
      expect(find.textContaining('二進位檔'), findsOneWidget);
      expect(find.byKey(const Key('btn-save-file')), findsNothing);
    });

    testWidgets('X 按鈕觸發 onClose', (tester) async {
      final path = '${tmp.path}/a.txt';
      var closed = false;
      await pumpEditor(tester, path, onClose: () => closed = true);
      await tester.tap(find.byKey(const Key('btn-close-editor')));
      expect(closed, isTrue);
    });

    testWidgets('.md 預設顯示預覽,可切原始碼再切回來', (tester) async {
      final path = '${tmp.path}/doc.md';
      File(path).writeAsStringSync('# 標題\n\n內文 **粗體**');
      await pumpEditor(tester, path);

      // 預覽:沒有輸入框,標題被渲染成文字(不含 '#')
      expect(find.byKey(const Key('md-preview')), findsOneWidget);
      expect(find.byKey(const Key('editor-text')), findsNothing);
      expect(find.textContaining('標題'), findsWidgets);
      expect(find.textContaining('# 標題'), findsNothing);

      // 切原始碼 → 看得到原文
      await tester.tap(find.byKey(const Key('btn-toggle-md-preview')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('editor-text')), findsOneWidget);
      expect(find.textContaining('# 標題'), findsOneWidget);

      // 切回預覽
      await tester.tap(find.byKey(const Key('btn-toggle-md-preview')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('md-preview')), findsOneWidget);
    });

    testWidgets('.md 改了內容,切回預覽看得到改的結果(存檔照舊)', (tester) async {
      final path = '${tmp.path}/doc.md';
      File(path).writeAsStringSync('# 舊標題');
      await pumpEditor(tester, path);

      await tester.tap(find.byKey(const Key('btn-toggle-md-preview')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('editor-text')), '# 新標題');
      await tester.pump();

      await tester.tap(find.byKey(const Key('btn-toggle-md-preview')));
      await tester.pumpAndSettle();
      expect(find.textContaining('新標題'), findsWidgets);

      // 預覽中仍可存檔(Ctrl+S / 標題列按鈕)
      await tester.tap(find.byKey(const Key('btn-save-file')));
      await tester.pumpAndSettle();
      expect(File(path).readAsStringSync(), '# 新標題');
    });

    testWidgets('非 .md 沒有預覽切換鈕', (tester) async {
      await pumpEditor(tester, '${tmp.path}/a.txt');
      expect(find.byKey(const Key('btn-toggle-md-preview')), findsNothing);
      expect(find.byKey(const Key('editor-text')), findsOneWidget);
    });

    testWidgets('換檔:同一個 pane 顯示新檔案,dirty 重置', (tester) async {
      final a = '${tmp.path}/a.txt';
      final b2 = '${tmp.path}/b2.txt';
      File(b2).writeAsStringSync('bee');

      Widget page(String path) => MaterialApp(
            theme: ThemeData.dark(useMaterial3: true),
            home: Scaffold(body: FileEditorPane(path: path, onClose: () {})),
          );

      await tester.pumpWidget(page(a));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('editor-text')), 'changed');
      await tester.pump();
      expect(find.textContaining('•'), findsOneWidget, reason: '標題出現未存檔點');

      await tester.pumpWidget(page(b2));
      await tester.pumpAndSettle();
      expect(find.text('bee'), findsOneWidget);
      expect(find.textContaining('•'), findsNothing, reason: '換檔後 dirty 重置');
    });
  });
}
