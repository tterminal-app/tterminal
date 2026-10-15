// SSH 端對端(Dart → FFI → Rust → in-process sshd):
// 需要 TTERM_TEST_SSHD 指向 test_sshd 執行檔;未設定則整個 group skip。
//
// 另外測 TabsController.newAsyncTab 的成功/失敗流程(不需 server)。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tterm_app/src/tabs.dart';
import 'package:tterm_app/src/term_ffi.dart';

/// 啟動 test_sshd,回傳 (process, port)。
Future<(Process, int)> _startSshd(String exe) async {
  final proc = await Process.start(exe, const []);
  final portCompleter = Completer<int>();
  proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
    if (line.startsWith('PORT=') && !portCompleter.isCompleted) {
      portCompleter.complete(int.parse(line.substring(5).trim()));
    }
  });
  final port = await portCompleter.future.timeout(const Duration(seconds: 10));
  return (proc, port);
}

void main() {
  final sshd = Platform.environment['TTERM_TEST_SSHD'];

  group('SSH 端對端(需 TTERM_TEST_SSHD)', () {
    late Process proc;
    late int port;

    setUp(() async {
      (proc, port) = await _startSshd(sshd!);
    });

    tearDown(() {
      proc.kill();
    });

    test('密碼認證 → 開 shell → 送資料看到回聲 + 指紋', () async {
      final session = await NativeSession.connectSsh(
        config: {
          'host': '127.0.0.1',
          'port': port,
          'username': 'tester',
          'auth': {'method': 'password', 'password': 'secret-123'},
        },
        cols: 80,
        rows: 24,
      );
      addTearDown(session.dispose);

      expect(session.sshFingerprint, startsWith('SHA256:'));

      session.write(utf8.encode('DART-SSH-99\r'));
      // 等背景 reader thread 把回聲餵進引擎
      await Future<void>.delayed(const Duration(milliseconds: 700));
      session.takeDamage();
      final grid = session.copyGrid();
      final buf = StringBuffer();
      for (var row = 0; row < session.rows; row++) {
        for (var col = 0; col < session.cols; col++) {
          final cp = grid[(row * session.cols + col) * 4];
          buf.writeCharCode(cp == 0 ? 0x20 : cp);
        }
      }
      final screen = buf.toString();
      expect(screen, contains('TEST-SSHD-READY'));
      expect(screen, contains('DART-SSH-99'));
    });

    test('錯誤密碼 → SshConnectException', () async {
      await expectLater(
        NativeSession.connectSsh(
          config: {
            'host': '127.0.0.1',
            'port': port,
            'username': 'tester',
            'auth': {'method': 'password', 'password': 'wrong'},
          },
          cols: 80,
          rows: 24,
        ),
        throwsA(isA<SshConnectException>()),
      );
    });

    test('SFTP:遠端 home / list / read / write', () async {
      final session = await NativeSession.connectSsh(
        config: {
          'host': '127.0.0.1',
          'port': port,
          'username': 'tester',
          'auth': {'method': 'password', 'password': 'secret-123'},
        },
        cols: 80,
        rows: 24,
      );
      addTearDown(session.dispose);

      expect(session.isSsh, isTrue);
      expect(session.sftpHome(), '/home/tester');

      // 列 home:目錄在前、名稱排序由 UI 控制,這裡驗證內容
      final list = session.sftpList('/home/tester');
      final names = list.map((e) => e['name'] as String).toSet();
      expect(names, containsAll(['readme.txt', 'logs', 'config.toml']));
      final logs = list.firstWhere((e) => e['name'] == 'logs');
      expect(logs['isDir'], isTrue);
      final readme = list.firstWhere((e) => e['name'] == 'readme.txt');
      expect(readme['isDir'], isFalse);
      expect(readme['size'], 16); // "hello from sftp\n"

      // 讀檔
      expect(utf8.decode(session.sftpRead('/home/tester/readme.txt')),
          'hello from sftp\n');

      // 進子目錄
      final sub = session.sftpList('/home/tester/logs');
      expect(sub.map((e) => e['name']), contains('app.log'));

      // 寫檔(server 接受即成功)
      session.sftpWrite('/home/tester/new.txt', utf8.encode('hi'));
    });

    test('本地 shell session 不是 SSH', () {
      final local = NativeSession.headless(cols: 20, rows: 5);
      addTearDown(local.dispose);
      expect(local.isSsh, isFalse);
    });

    test('host key 不符 → 拒絕,帶著新舊指紋給錯誤畫面', () async {
      await expectLater(
        NativeSession.connectSsh(
          config: {
            'host': '127.0.0.1',
            'port': port,
            'username': 'tester',
            'auth': {'method': 'password', 'password': 'secret-123'},
            'knownFingerprint': 'SHA256:not-the-real-fingerprint',
          },
          cols: 80,
          rows: 24,
        ),
        throwsA(
          isA<HostKeyMismatchException>()
              .having(
                (e) => e.expected,
                'expected',
                'SHA256:not-the-real-fingerprint',
              )
              .having((e) => e.actual, 'actual', startsWith('SHA256:')),
        ),
      );
    });
  }, skip: sshd == null ? 'TTERM_TEST_SSHD 未設定' : false);

  group('TabsController.newAsyncTab', () {
    test('連線成功 → attach session、連線中狀態清除', () async {
      final tabs = TabsController(
        spawn: () => NativeSession.headless(cols: 40, rows: 12),
      );
      addTearDown(tabs.dispose);

      final completer = Completer<NativeSession>();
      final id = tabs.newAsyncTab('my-host', () => completer.future);
      final tab = tabs.tabs.firstWhere((t) => t.id == id);
      expect(tab.connecting, isTrue);
      expect(tab.displayTitle, contains('連線中'));

      completer.complete(NativeSession.headless(cols: 40, rows: 12));
      await Future<void>.delayed(Duration.zero);
      expect(tab.connecting, isFalse);
      expect(tab.session, isNotNull);
      expect(tab.displayTitle, 'my-host');
    });

    test('連線失敗 → 顯示錯誤', () async {
      final tabs = TabsController(
        spawn: () => NativeSession.headless(cols: 40, rows: 12),
      );
      addTearDown(tabs.dispose);

      final id = tabs.newAsyncTab(
        'bad-host',
        () => Future.error(SshConnectException('連不上')),
      );
      final tab = tabs.tabs.firstWhere((t) => t.id == id);
      await Future<void>.delayed(Duration.zero);
      expect(tab.connecting, isFalse);
      expect(tab.session, isNull);
      expect(tab.error, contains('連不上'));
    });
  });
}
