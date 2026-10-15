// NativeVault(FFI JSON 通道)整合測試:CRUD、buffer 擴充、配對 roundtrip。
// 需要 TTERM_FFI_LIB 指向 ABI v3 的原生函式庫。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tterm_app/src/vault_ffi.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tterm-vault-test');
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('CRUD 與 snapshot roundtrip', () {
    final v = NativeVault.open('${tmp.path}/v1');
    addTearDown(v.dispose);

    final id = v.upsert(
      kind: 'host',
      name: 'web',
      data: {'address': '10.0.0.1', 'port': 22, 'username': 'root'},
    );
    var snap = v.snapshot();
    expect((snap['records'] as List).length, 1);
    expect(snap['records'][0]['name'], 'web');
    expect(snap['records'][0]['data']['username'], 'root');

    // 帶 id 更新(不是新增)
    v.upsert(id: id, kind: 'host', name: 'web-2', data: {'address': 'x'});
    snap = v.snapshot();
    expect((snap['records'] as List).length, 1);
    expect(snap['records'][0]['name'], 'web-2');

    v.delete(id);
    expect((v.snapshot()['records'] as List).length, 0);
  });

  test('大 payload 走 buffer 擴充路徑(>64KB snapshot)', () {
    final v = NativeVault.open('${tmp.path}/v2');
    addTearDown(v.dispose);
    final big = 'x' * 200000;
    v.upsert(kind: 'ssh_key', name: 'big', data: {'privateKey': big});
    final snap = v.snapshot();
    expect(snap['records'][0]['data']['privateKey'], big);
  });

  test('錯誤走 VaultException(未設定同步就匯出)', () {
    final v = NativeVault.open('${tmp.path}/v3');
    addTearDown(v.dispose);
    expect(() => v.exportPairing(), throwsA(isA<VaultException>()));
    expect(v.syncTransport(), isNull);
  });

  test('配對字串:A 匯出 → B 匯入,身分一致、本地資料合流', () {
    final a = NativeVault.open('${tmp.path}/a');
    final b = NativeVault.open('${tmp.path}/b');
    addTearDown(a.dispose);
    addTearDown(b.dispose);

    a.upsert(kind: 'host', name: 'prod', data: {'address': '1.1.1.1'});
    final enable = a.syncEnable('http://127.0.0.1:1');
    expect(enable.auth, isNotEmpty);

    final pairing = a.exportPairing();
    expect(pairing, startsWith('TTERMSYNC1:'));

    b.upsert(kind: 'ssh_key', name: 'deploy', data: {'privateKey': 'K'});
    final summary = b.importPairing(pairing);
    expect(summary['vault_id'], enable.vaultId);
    expect(summary['carried'], 1);

    final ta = a.syncTransport()!;
    final tb = b.syncTransport()!;
    expect(tb.vaultId, ta.vaultId);
    expect(tb.token, ta.token);
    expect(tb.server, ta.server);

    // 手動接 wire:B 的 push 可被 A 解密套用(同一把 E2E key)
    final push = b.buildPush();
    expect(push.length, 1);
    final withSeq = [
      for (var i = 0; i < push.length; i++)
        {...(push[i] as Map).cast<String, dynamic>(), 'seq': i + 1},
    ];
    final applied = a.applyPull(withSeq, push.length);
    expect(applied['applied'], 1);
    expect(
      (a.snapshot()['records'] as List).map((r) => r['name']),
      containsAll(['prod', 'deploy']),
    );
  });
}
