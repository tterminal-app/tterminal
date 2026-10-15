// SyncClient:與 tterm-server 的 HTTP 傳輸(dart:io,無外部依賴)。
//
// 只搬運已加密的 wire payload;加解密都在 Rust 端(NativeVault)。
// API 見 docs/vault-sync-design.md §4。

import 'dart:convert';
import 'dart:io';

import 'l10n.dart';

class SyncHttpException implements Exception {
  SyncHttpException(this.status, this.message);
  final int status;

  /// server 回的 `error` 原文(server 端的語言,不一定是使用者的語系)。
  final String message;

  /// 常見狀態碼有明確意思,直接講人話;其他的附上 server 原文。
  @override
  String toString() => switch (status) {
    401 => l10n.syncUnauthorized,
    404 => l10n.syncVaultNotFound,
    409 => l10n.syncVaultConflict,
    _ => l10n.syncServerResponded(status, message),
  };
}

class SyncClient {
  SyncClient({Duration? timeout}) : _timeout = timeout ?? const Duration(seconds: 10);

  final Duration _timeout;

  Future<(int, Object?)> _request(
    String method,
    Uri url, {
    String? token,
    Object? body,
  }) async {
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final req = await client.openUrl(method, url).timeout(_timeout);
      req.headers.contentType = ContentType.json;
      if (token != null) {
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      if (body != null) {
        req.add(utf8.encode(jsonEncode(body)));
      }
      final resp = await req.close().timeout(_timeout);
      final text = await resp.transform(utf8.decoder).join().timeout(_timeout);
      final parsed = text.isEmpty ? null : jsonDecode(text);
      return (resp.statusCode, parsed);
    } finally {
      client.close(force: true);
    }
  }

  static String _err(Object? body) =>
      body is Map && body['error'] is String ? body['error'] as String : '$body';

  Future<bool> health(String server) async {
    try {
      final (status, body) = await _request('GET', Uri.parse('$server/v1/health'));
      return status == 200 && body is Map && body['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  /// 註冊 vault(建立同步時)。200/201 都算成功(幂等重註冊)。
  Future<void> register({
    required String server,
    required String vaultId,
    required String auth,
  }) async {
    final (status, body) = await _request(
      'POST',
      Uri.parse('$server/v1/vaults'),
      body: {'vault_id': vaultId, 'auth': auth},
    );
    if (status != 200 && status != 201) {
      throw SyncHttpException(status, _err(body));
    }
  }

  /// push 加密 records;回傳 server 最新 seq。
  Future<int> push({
    required String server,
    required String vaultId,
    required String token,
    required List<dynamic> records,
  }) async {
    final (status, body) = await _request(
      'POST',
      Uri.parse('$server/v1/vaults/$vaultId/records'),
      token: token,
      body: records,
    );
    if (status != 200) throw SyncHttpException(status, _err(body));
    return (body as Map)['seq'] as int;
  }

  /// pull seq > since 的變更;回傳 (records, next cursor)。
  Future<(List<dynamic>, int)> pull({
    required String server,
    required String vaultId,
    required String token,
    required int since,
  }) async {
    final (status, body) = await _request(
      'GET',
      Uri.parse('$server/v1/vaults/$vaultId/records?since=$since'),
      token: token,
    );
    if (status != 200) throw SyncHttpException(status, _err(body));
    final map = body as Map;
    return (map['records'] as List<dynamic>, map['next'] as int);
  }
}
