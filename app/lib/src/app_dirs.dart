// App 資料目錄(vault、prefs 的共同落點)。
// TTERM_DATA_DIR 可覆寫(開發/測試用)。

import 'dart:io';

import 'vault_ffi.dart';

String appBaseDir() {
  final override = Platform.environment['TTERM_DATA_DIR'];
  if (override != null && override.isNotEmpty) return override;
  if (Platform.isWindows) {
    final base = Platform.environment['APPDATA'] ??
        '${Platform.environment['USERPROFILE'] ?? '.'}\\AppData\\Roaming';
    return '$base\\tterminal';
  }
  if (Platform.isIOS) {
    // iOS 沙盒只有 Documents/Library/tmp 可寫,且 HOME 環境變數不可靠
    // (模擬器上沒設);TMPDIR 一定指向容器內的 tmp,反推容器根目錄。
    final container = Directory.systemTemp.parent.path;
    return '$container/Library/Application Support/tterminal';
  }
  final home = Platform.environment['HOME'] ?? '.';
  if (Platform.isMacOS) return '$home/Library/Application Support/tterminal';
  final xdg = Platform.environment['XDG_DATA_HOME'] ?? '$home/.local/share';
  return '$xdg/tterminal';
}

/// vault key 的保管處:iOS / macOS 存系統 Keychain;其他平台回 null,
/// 照舊是 vault 目錄裡的 vault.key(Windows DPAPI / Linux Secret Service 之後再做)。
VaultKeychain? vaultKeychain() => vaultKeychainFor(
  apple: Platform.isIOS || Platform.isMacOS,
  dataDirOverride: Platform.environment['TTERM_DATA_DIR'],
);

/// [vaultKeychain] 的判斷本體(拆出來給測試)。
///
/// TTERM_DATA_DIR 指到別處(開發/測試)時 account 帶上那個路徑:Keychain 是
/// 整個使用者共用的,不分開的話那份 vault 會跟正式的搶同一個項目。
VaultKeychain? vaultKeychainFor({required bool apple, String? dataDirOverride}) {
  if (!apple) return null;
  final override = dataDirOverride ?? '';
  return VaultKeychain(
    service: 'dev.tterm.tterminal.vault',
    account: override.isEmpty ? 'vault-key' : 'vault-key:$override',
  );
}
