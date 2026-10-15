// 用 VS Code 開啟:參數組裝(本地/遠端、檔案/資料夾、路徑編碼)與啟動流程。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tterm_app/src/vscode_open.dart';

void main() {
  group('vscodeLocalArgs', () {
    test('本地路徑就是直接當引數', () {
      expect(vscodeLocalArgs(r'C:\Users\me\proj'), [r'C:\Users\me\proj']);
    });
  });

  group('vscodeRemoteArgs', () {
    test('資料夾走 --folder-uri', () {
      expect(
        vscodeRemoteArgs('me@1.2.3.4:22', '/home/me/proj', isDir: true),
        ['--folder-uri', 'vscode-remote://ssh-remote+me@1.2.3.4:22/home/me/proj'],
      );
    });

    test('檔案走 --file-uri', () {
      expect(
        vscodeRemoteArgs('me@host:2222', '/etc/hosts', isDir: false),
        ['--file-uri', 'vscode-remote://ssh-remote+me@host:2222/etc/hosts'],
      );
    });

    test('路徑含空白/特殊字元會 percent-encode(斜線保留)', () {
      final args =
          vscodeRemoteArgs('me@host:22', '/home/me/my proj/a b.txt', isDir: false);
      expect(
        args.last,
        'vscode-remote://ssh-remote+me@host:22/home/me/my%20proj/a%20b.txt',
      );
    });
  });

  group('launchVscode', () {
    test('用注入的 runner 啟動 code,回傳 0 視為成功', () async {
      String? gotExe;
      List<String>? gotArgs;
      bool? gotShell;
      await launchVscode(
        ['--file-uri', 'x'],
        runner: (exe, args, shell) async {
          gotExe = exe;
          gotArgs = args;
          gotShell = shell;
          return 0;
        },
      );
      expect(gotExe, 'code');
      expect(gotArgs, ['--file-uri', 'x']);
      expect(gotShell, Platform.isWindows); // Windows 的 code.cmd 要經 shell
    });

    test('結束碼非 0 丟 ProcessException(呼叫端才好提示)', () async {
      expect(
        () => launchVscode(['x'], runner: (_, _, _) async => 1),
        throwsA(isA<ProcessException>()),
      );
    });
  });
}
