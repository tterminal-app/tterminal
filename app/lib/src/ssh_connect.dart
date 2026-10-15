// 從 vault host 建立 SSH 分頁——桌面 AppShell 與手機 MobileShell 共用。
// 認證資料同步解析(錯誤即時回報),連線本身在背景 isolate 進行;
// 首次連線成功後把 host key 指紋存回 host(TOFU)。

import 'l10n.dart';
import 'tabs.dart';
import 'term_ffi.dart';
import 'vault_service.dart';

/// 解析 [host] 的認證設定並開一個「連線中」分頁。
/// 回傳分頁 id;認證資料有問題(如金鑰已被刪)時回 null 並呼叫 [onError]。
int? connectSshHostTab({
  required TabsController tabs,
  required VaultService? vault,
  required VaultRecord host,
  required void Function(String message) onError,
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

  final storedFingerprint = data['hostKeyFingerprint'] as String?;
  final config = <String, dynamic>{
    'host': data['address'],
    'port': data['port'] ?? 22,
    'username': data['username'] ?? '',
    'auth': authConfig,
    'knownFingerprint': ?storedFingerprint,
  };

  final user = data['username'] as String? ?? '';
  final connInfo =
      '${user.isNotEmpty ? '$user@' : ''}${data['address']}:${data['port'] ?? 22}';
  return tabs.newAsyncTab(host.name, connInfo: connInfo, () async {
    final session = await NativeSession.connectSsh(
      config: config,
      cols: 100,
      rows: 30,
    );
    // 首次連線(TOFU):把看到的 host key 指紋存回 host,之後連線就會固定驗證
    final fp = session.sshFingerprint;
    if (fp != null && storedFingerprint == null && vault != null) {
      vault.upsert(
        id: host.id,
        kind: 'host',
        name: host.name,
        data: {...data, 'hostKeyFingerprint': fp},
      );
    }
    return session;
  });
}
