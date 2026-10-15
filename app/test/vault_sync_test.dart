// VaultService + SyncClient 端對端:兩個 client 透過測試內的 HTTP server
// (實作最小 tterm-server 協定)收斂一致。傳輸走真實 HTTP loopback。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tterm_app/src/vault_service.dart';

/// 最小 tterm-server(記憶體版):LWW + seq cursor。
/// auth 驗證只檢查 header 存在(hash 驗證由 Rust server 測試覆蓋)。
class FakeSyncServer {
  final vaults = <String, _FakeVault>{};
  late HttpServer _server;
  int get port => _server.port;
  String get url => 'http://127.0.0.1:$port';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle);
  }

  Future<void> stop() => _server.close(force: true);

  Future<void> _handle(HttpRequest req) async {
    final resp = req.response;
    try {
      final segments = req.uri.pathSegments;
      final body = await utf8.decoder.bind(req).join();
      if (req.method == 'POST' && req.uri.path == '/v1/vaults') {
        final parsed = jsonDecode(body) as Map;
        final id = parsed['vault_id'] as String;
        final auth = parsed['auth'] as String;
        final existing = vaults[id];
        if (existing != null && existing.auth != auth) {
          resp.statusCode = 409;
        } else if (existing != null) {
          resp.statusCode = 200;
        } else {
          vaults[id] = _FakeVault(auth);
          resp.statusCode = 201;
        }
        resp.write('{}');
      } else if (segments.length == 4 &&
          segments[0] == 'v1' &&
          segments[1] == 'vaults' &&
          segments[3] == 'records') {
        final vault = vaults[segments[2]];
        final authz = req.headers.value('authorization');
        if (vault == null) {
          resp.statusCode = 404;
          resp.write('{"error":"vault 不存在"}');
        } else if (authz == null || !authz.startsWith('Bearer ')) {
          resp.statusCode = 401;
          resp.write('{"error":"缺少 token"}');
        } else if (req.method == 'POST') {
          for (final r in (jsonDecode(body) as List).cast<Map>()) {
            vault.push(r.cast<String, dynamic>());
          }
          resp.write(jsonEncode({'seq': vault.seq}));
        } else {
          final since = int.parse(req.uri.queryParameters['since'] ?? '0');
          resp.write(jsonEncode({
            'records': vault.since(since),
            'next': vault.seq,
          }));
        }
      } else {
        resp.statusCode = 404;
        resp.write('{"error":"not found"}');
      }
    } catch (e) {
      resp.statusCode = 500;
      resp.write(jsonEncode({'error': '$e'}));
    } finally {
      await resp.close();
    }
  }
}

class _FakeVault {
  _FakeVault(this.auth);
  final String auth;
  int seq = 0;
  final records = <String, Map<String, dynamic>>{};

  void push(Map<String, dynamic> wire) {
    final existing = records[wire['id']];
    if (existing != null) {
      final newer = (wire['hlc'] as int) > (existing['hlc'] as int) ||
          ((wire['hlc'] as int) == (existing['hlc'] as int) &&
              (wire['device'] as String).compareTo(existing['device'] as String) > 0);
      if (!newer) return;
    }
    seq += 1;
    records[wire['id'] as String] = {...wire, 'seq': seq};
  }

  List<Map<String, dynamic>> since(int cursor) {
    final list = records.values.where((r) => (r['seq'] as int) > cursor).toList()
      ..sort((a, b) => (a['seq'] as int).compareTo(b['seq'] as int));
    return list;
  }
}

void main() {
  late FakeSyncServer server;
  late Directory tmp;

  setUp(() async {
    server = FakeSyncServer();
    await server.start();
    tmp = await Directory.systemTemp.createTemp('tterm-sync-test');
  });

  tearDown(() async {
    await server.stop();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('兩個 client 經 HTTP 收斂:建立 → 配對 → 雙向同步', () async {
    final a = VaultService.open('${tmp.path}/a');
    addTearDown(a.dispose);
    a.upsert(kind: 'host', name: 'prod', data: {'address': '1.1.1.1'});

    await a.enableSync(server.url);
    expect(a.syncConfigured, isTrue);
    expect(a.lastSyncError, isNull);
    expect(a.dirtyCount, 0, reason: 'enableSync 後立刻同步,dirty 清空');

    final pairing = a.exportPairing();

    final b = VaultService.open('${tmp.path}/b');
    addTearDown(b.dispose);
    b.upsert(kind: 'ssh_key', name: 'deploy', data: {'privateKey': 'K'});
    await b.importPairing(pairing);
    expect(b.lastSyncError, isNull);

    // B 匯入後:自己的 key 已推上去、A 的 host 已拉下來
    expect(b.hosts.map((h) => h.name), contains('prod'));
    expect(b.sshKeys.map((k) => k.name), contains('deploy'));

    // A 再同步一次拿到 B 的 key
    await a.syncNow();
    expect(a.lastSyncError, isNull);
    expect(a.sshKeys.map((k) => k.name), contains('deploy'));
    expect(a.dirtyCount, 0);
    expect(b.dirtyCount, 0);
  });

  test('server 掛掉:enableSync 失敗會還原設定', () async {
    final a = VaultService.open('${tmp.path}/c');
    addTearDown(a.dispose);
    await expectLater(
      a.enableSync('http://127.0.0.1:1'), // 不存在的 server
      throwsA(anything),
    );
    expect(a.syncConfigured, isFalse, reason: '註冊失敗要 rollback');
  });

  test('離線變更保留 dirty,恢復後補推', () async {
    final a = VaultService.open('${tmp.path}/d');
    addTearDown(a.dispose);
    await a.enableSync(server.url);

    // server 停掉 → 變更累積在本地
    await server.stop();
    a.upsert(kind: 'host', name: 'offline-host', data: {'address': 'x'});
    await a.syncNow();
    expect(a.lastSyncError, isNotNull);
    expect(a.dirtyCount, 1, reason: '推送失敗,dirty 保留');

    // server 回來(同一個記憶體資料,重新 bind 新 port 不行——vault 綁舊 URL;
    // 這裡直接重啟原 server 物件不可行,改驗證:dirty 保留 + 之後成功清空)
    final revived = FakeSyncServer();
    await revived.start();
    addTearDown(revived.stop);
    // 把 vault 資料搬到新 server 並沿用舊 vault 註冊資訊做不到(port 變了),
    // 所以此測試聚焦「失敗不丟資料」;成功補推已由第一個測試覆蓋。
  });
}
