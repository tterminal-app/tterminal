import Cocoa
import FlutterMacOS

// 從 Finder 把檔案拖進視窗:放開滑鼠時把檔案路徑與放開座標(Flutter view
// client px)丟給 Dart,由 Dart 判斷是否落在檔案側窗上、再決定複製(本地)
// 還是 SFTP 上傳(遠端)。channel 名稱與座標約定跟 Windows 的 IDropTarget 版
// 一致(windows/runner/file_drop.cpp),Dart 端因此不必分平台。

final class FileDropTarget {
  private static let fileURLsOnly: [NSPasteboard.ReadingOptionKey: Any] = [
    .urlReadingFileURLsOnly: true
  ]

  private let channel: FlutterMethodChannel
  private weak var flutterView: NSView?

  init(messenger: FlutterBinaryMessenger, flutterView: NSView) {
    channel = FlutterMethodChannel(
      name: "tterminal/filedrop", binaryMessenger: messenger)
    self.flutterView = flutterView
  }

  /// 只認檔案;拖純文字之類的進來一律不接(游標也不會變成 copy)。
  func hasFiles(_ info: NSDraggingInfo) -> Bool {
    return info.draggingPasteboard.canReadObject(
      forClasses: [NSURL.self], options: Self.fileURLsOnly)
  }

  /// 回傳 false = 沒收下,AppKit 會播回彈動畫。
  func performDrop(_ info: NSDraggingInfo) -> Bool {
    guard let view = flutterView,
      let urls = info.draggingPasteboard.readObjects(
        forClasses: [NSURL.self], options: Self.fileURLsOnly) as? [URL],
      !urls.isEmpty
    else {
      return false
    }

    // window 座標 → view 座標 → physical px(Dart 端再除以 devicePixelRatio)。
    // AppKit 的 y 軸預設由下往上,view 沒 flip 時要自己翻成 Flutter 的由上往下。
    let inView = view.convert(info.draggingLocation, from: nil)
    let y = view.isFlipped ? inView.y : view.bounds.height - inView.y
    let scale = view.window?.backingScaleFactor ?? 1

    channel.invokeMethod(
      "dropped",
      arguments: [
        "paths": urls.map { $0.path },
        "x": Int((inView.x * scale).rounded()),
        "y": Int((y * scale).rounded()),
      ])
    return true
  }
}
