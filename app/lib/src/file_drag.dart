// 把本地檔案拖到系統的檔案管理員(Windows:native OLE SHDoDragDrop /
// CF_HDROP;macOS:NSDraggingSession + file URL)。其餘平台不支援拖出
// (回傳即結束)。

import 'dart:io';

import 'package:flutter/services.dart';

class FileDrag {
  static const _channel = MethodChannel('tterminal/filedrag');

  static bool get supported => Platform.isWindows || Platform.isMacOS;

  /// 開始把 [path] 拖出去。這個 future 要等使用者放開滑鼠、native 端把拖放
  /// 收尾才完成(Windows 是 modal 拖放迴圈,macOS 是 dragging session 結束)。
  static Future<void> start(String path) async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<void>('startDrag', {'path': path});
    } on PlatformException {
      // 拖放取消或失敗:忽略(使用者體感就是沒拖成功)
    } on MissingPluginException {
      // channel 未註冊(測試環境等):忽略
    }
  }

  /// 遠端檔案沒有本地路徑,先把 [bytes] 寫到暫存檔(檔名沿用 [name]),
  /// 再拖那個暫存檔。回傳暫存檔路徑;不支援的平台回 null。
  static Future<String?> startTempCopy(String name, List<int> bytes) async {
    if (!supported) return null;
    final sep = Platform.pathSeparator;
    final dir = Directory('${Directory.systemTemp.path}${sep}tterm-drag');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    // 去掉兩邊平台的路徑分隔與非法字元,避免跳出暫存資料夾或建不出檔。
    var safe = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_');
    if (safe.isEmpty || safe == '.' || safe == '..') safe = 'file';
    final file = File('${dir.path}$sep$safe');
    file.writeAsBytesSync(bytes);
    await start(file.path);
    return file.path;
  }
}
