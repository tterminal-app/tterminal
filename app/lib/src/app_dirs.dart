// App 資料目錄(vault、prefs 的共同落點)。
// TTERM_DATA_DIR 可覆寫(開發/測試用)。

import 'dart:io';

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
