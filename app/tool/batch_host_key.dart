// 維運腳本:把 vault 中所有 host 的認證批量改成指定 SSH key。
// 預設 dry-run 只印計畫;加 --apply 才真的寫入。
//
// 用法(從 app/ 目錄,先把 TTERM_FFI_LIB 指到 tterm_ffi.dll):
//   dart run tool/batch_host_key.dart [--key WSL] [--dir <vaultDir>] [--apply]
//
// 注意:跑之前先關閉 tterminal app(store 是整檔覆寫,兩個行程同開會互相蓋)。

import 'dart:io';

import 'package:tterm_app/src/vault_ffi.dart';

void main(List<String> args) {
  final apply = args.contains('--apply');
  String argOf(String flag, String def) {
    final i = args.indexOf(flag);
    return (i >= 0 && i + 1 < args.length) ? args[i + 1] : def;
  }

  final keyQuery = argOf('--key', 'WSL');
  final dir = argOf(
    '--dir',
    '${Platform.environment['APPDATA']}\\tterminal\\vault',
  );

  final vault = NativeVault.open(dir);
  try {
    final snap = vault.snapshot();
    final records = [
      for (final r in snap['records'] as List)
        (r as Map).cast<String, dynamic>(),
    ];
    final keys = records.where((r) => r['kind'] == 'ssh_key').toList();
    final hosts = records.where((r) => r['kind'] == 'host').toList();

    stdout.writeln('vault:$dir');
    stdout.writeln('金鑰 ${keys.length} 把:');
    for (final k in keys) {
      stdout.writeln('  - ${k['name']}(${k['id']})');
    }

    final matches = keys
        .where((k) => (k['name'] as String)
            .toLowerCase()
            .contains(keyQuery.toLowerCase()))
        .toList();
    if (matches.length != 1) {
      stdout.writeln('\n比對「$keyQuery」找到 ${matches.length} 把金鑰,需要恰好 1 把,停止。');
      exitCode = 1;
      return;
    }
    final key = matches.single;
    final keyId = key['id'] as String;
    stdout.writeln('\n目標金鑰:${key['name']}($keyId)');
    stdout.writeln('主機 ${hosts.length} 台:');

    var changed = 0;
    for (final h in hosts) {
      final data = (h['data'] as Map).cast<String, dynamic>();
      final auth =
          (data['auth'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
      final before = auth['method'] == 'key'
          ? 'key:${auth['keyId']}'
          : '${auth['method'] ?? 'password'}';
      final already = auth['method'] == 'key' && auth['keyId'] == keyId;
      stdout.writeln(
          '  - ${h['name']}  $before${already ? '(已是目標,跳過)' : ' → key:${key['name']}'}');
      if (already) continue;
      changed++;
      if (!apply) continue;
      auth['method'] = 'key';
      auth['keyId'] = keyId;
      // 原 password 欄位保留不動:之後切回密碼認證時還在。
      data['auth'] = auth;
      vault.upsert(
        id: h['id'] as String,
        kind: 'host',
        name: h['name'] as String,
        data: data,
      );
    }
    stdout.writeln(apply
        ? '\n完成:已更新 $changed 台主機(標記 dirty,app 下次同步會推送)。'
        : '\n(dry-run;將更新 $changed 台,加 --apply 執行)');
  } finally {
    vault.dispose();
  }
}
