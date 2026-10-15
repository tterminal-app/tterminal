// 開發用:在 TTERM_DATA_DIR 的 vault 裡種一筆 SSH host,方便手動/冒煙測試。
// 只依賴 NativeVault(不含 flutter),可用純 dart 執行:
//   TTERM_FFI_LIB=... TTERM_DATA_DIR=... dart run tool/seed_vault.dart <host> <port>

import 'dart:io';

import 'package:tterm_app/src/app_dirs.dart';
import 'package:tterm_app/src/vault_ffi.dart';

void main(List<String> args) {
  final host = args.isNotEmpty ? args[0] : '127.0.0.1';
  final port = args.length > 1 ? int.parse(args[1]) : 22;
  final dir = '${appBaseDir()}${Platform.pathSeparator}vault';
  final vault = NativeVault.open(dir);
  vault.upsert(
    kind: 'host',
    name: 'test-sshd',
    data: {
      'address': host,
      'port': port,
      'username': 'tester',
      'auth': {'method': 'password', 'password': 'secret-123'},
    },
  );
  stdout.writeln('seeded host test-sshd @ $host:$port into $dir');
  vault.dispose();
}
