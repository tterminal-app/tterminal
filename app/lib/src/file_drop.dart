// 從系統的檔案管理員把檔案拖進來(Windows:native OLE IDropTarget;macOS:
// window 層的 NSDraggingDestination → 都走這條 channel)。native 端在放開滑鼠
// 時送 {paths, x, y};x/y 是 Flutter view client 的 physical px,呼叫端要自己
// 除以 devicePixelRatio 再做 hit-test。
// 其餘平台不會有 native 端,listen 只是掛個永遠不被呼叫的 handler。

import 'dart:io';

import 'package:flutter/services.dart';

import 'l10n.dart';

class FileDrop {
  static const _channel = MethodChannel('tterminal/filedrop');

  static bool get supported => Platform.isWindows || Platform.isMacOS;

  /// 註冊放檔 callback。[paths] 是被拖進來的本地檔案路徑,[physicalPos] 是
  /// 放開位置(view client physical px)。
  static void listen(
      void Function(List<String> paths, Offset physicalPos) onDrop) {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'dropped') return null;
      final args = (call.arguments as Map).cast<String, Object?>();
      final rawPaths = (args['paths'] as List?) ?? const [];
      final paths = [for (final p in rawPaths) p as String];
      final x = (args['x'] as num?)?.toDouble() ?? 0;
      final y = (args['y'] as num?)?.toDouble() ?? 0;
      onDrop(paths, Offset(x, y));
      return null;
    });
  }

  static void stop() => _channel.setMethodCallHandler(null);
}

/// importDroppedFiles 的統計結果。
class DropResult {
  const DropResult(this.done, this.skipped);
  final int done;
  final List<String> skipped;
}

/// 逐一處理拖進來的本地檔案:跳過資料夾;遠端時跳過大於 [maxRemoteBytes] 的
/// 檔(同步讀檔會卡 UI)。通過的交給 [place] 實際落地——本地複製或 SFTP 上傳
/// 由呼叫端決定。回傳成功數與略過清單(附原因)。
DropResult importDroppedFiles(
  List<String> paths, {
  required bool remote,
  required void Function(String name, File file) place,
  int maxRemoteBytes = 32 * 1024 * 1024,
}) {
  var done = 0;
  final skipped = <String>[];
  for (final src in paths) {
    final name = dropBaseName(src);
    try {
      if (FileSystemEntity.typeSync(src) != FileSystemEntityType.file) {
        skipped.add(l10n.skippedFolder(name));
        continue;
      }
      final f = File(src);
      if (remote && f.lengthSync() > maxRemoteBytes) {
        skipped.add(l10n.skippedTooLarge(name));
        continue;
      }
      place(name, f);
      done++;
    } catch (e) {
      // 失敗原因要讓使用者看得到(例如 SFTP 權限不足),不能只列檔名
      skipped.add(l10n.skippedWithReason(name, _shortReason(e)));
    }
  }
  return DropResult(done, skipped);
}

/// 例外訊息壓成一行、截短,塞得進 SnackBar。
String _shortReason(Object e) {
  final line = '$e'.split('\n').first.trim();
  return line.length > 80 ? '${line.substring(0, 80)}…' : line;
}

String dropBaseName(String path) {
  final norm = path.replaceAll('\\', '/');
  final i = norm.lastIndexOf('/');
  return i < 0 ? norm : norm.substring(i + 1);
}
