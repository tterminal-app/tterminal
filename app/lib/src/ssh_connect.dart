// 從 vault host 建立 SSH 分頁——桌面 AppShell 與手機 MobileShell 共用。
// 認證資料同步解析(錯誤即時回報),連線本身在背景 isolate 進行;
// 首次連線成功後把 host key 指紋存回 host(TOFU)。之後指紋不符就拒絕連線,
// 使用者確認主機確實換了金鑰後,可以從錯誤畫面改用新指紋(trustNewHostKey)。

import 'package:flutter/foundation.dart';

import 'l10n.dart';
import 'tabs.dart';
import 'term_ffi.dart';
import 'vault_service.dart';

/// 解析 [host] 的認證設定並開一個「連線中」分頁。
/// 回傳分頁 id;認證資料有問題(如金鑰已被刪)時回 null 並呼叫 [onError]。
/// [connect] 給測試換掉真的 SSH 連線(收到的是送給 core 的 config)。
int? connectSshHostTab({
  required TabsController tabs,
  required VaultService? vault,
  required VaultRecord host,
  required void Function(String message) onError,
  @visibleForTesting
  Future<NativeSession> Function(Map<String, dynamic> config)? connect,
}) {
  final data = host.data;
  final auth = (data['auth'] as Map?)?.cast<String, dynamic>() ?? const {};
  final method = auth['method'] as String? ?? 'password';

  Map<String, dynamic> authConfig;
  if (method == 'key') {
    final key = vault?.byId(auth['keyId'] as String?);
    if (key == null) {
      onError(l10n.sshKeyMissing);
      return null;
    }
    authConfig = {
      'method': 'key',
      'pem': key.data['privateKey'],
      'passphrase': key.data['passphrase'] ?? '',
    };
  } else {
    // password / none 都送 password(none 用空字串試)
    authConfig = {
      'method': 'password',
      'password': auth['password'] ?? '',
    };
  }

  final config = <String, dynamic>{
    'host': data['address'],
    'port': data['port'] ?? 22,
    'username': data['username'] ?? '',
    'auth': authConfig,
  };
  final doConnect =
      connect ??
      (Map<String, dynamic> config) =>
          NativeSession.connectSsh(config: config, cols: 100, rows: 30);

  final user = data['username'] as String? ?? '';
  final connInfo =
      '${user.isNotEmpty ? '$user@' : ''}${data['address']}:${data['port'] ?? 22}';
  return tabs.newAsyncTab(
    host.name,
    connInfo: connInfo,
    hostId: host.id,
    () async {
      // 指紋每次連線都從 vault 重讀:首次連線剛記下的、使用者剛改用的新指紋,
      // 按「重新連線」時才會生效,不會沿用開分頁當下的舊值。
      final known =
          (vault?.byId(host.id) ?? host).data['hostKeyFingerprint'] as String?;
      final session = await doConnect({...config, 'knownFingerprint': ?known});
      // 首次連線(TOFU):把看到的 host key 指紋存回 host,之後連線就會固定驗證。
      // 寫回 vault 目前的內容(分頁開著時 host 可能被編輯過;被刪了就不寫)。
      final fp = session.sshFingerprint;
      final latest = vault?.byId(host.id);
      if (fp != null && known == null && latest != null) {
        vault!.upsert(
          id: latest.id,
          kind: 'host',
          name: latest.name,
          data: {...latest.data, 'hostKeyFingerprint': fp},
        );
      }
      return session;
    },
  );
}

/// 使用者確認主機確實換了金鑰:把 host 記住的指紋換成 [fingerprint]。
/// 只動指紋,其他欄位照 vault 目前的內容。host 已被刪除時回 false。
bool trustNewHostKey({
  required VaultService vault,
  required String hostId,
  required String fingerprint,
}) {
  final host = vault.byId(hostId);
  if (host == null) return false;
  vault.upsert(
    id: host.id,
    kind: 'host',
    name: host.name,
    data: {...host.data, 'hostKeyFingerprint': fingerprint},
  );
  return true;
}

/// host key 不符的錯誤畫面上「改用新指紋」要做的事:換掉記住的指紋,再用
/// 原設定重新連線。不是 vault host 開的分頁、或 host 已經被刪掉時回 null
/// (畫面就不提供這個選項)。
VoidCallback? trustNewHostKeyAction({
  required TabsController tabs,
  required VaultService? vault,
  required TermTab tab,
}) {
  final hostId = tab.hostId;
  final mismatch = tab.hostKeyMismatch;
  if (vault == null || hostId == null || mismatch == null) return null;
  if (vault.byId(hostId) == null) return null;
  return () {
    if (trustNewHostKey(
      vault: vault,
      hostId: hostId,
      fingerprint: mismatch.actual,
    )) {
      tabs.reconnect(tab.id);
    }
  };
}
