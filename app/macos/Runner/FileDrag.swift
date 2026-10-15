import Cocoa
import FlutterMacOS

// 把檔案側窗的本地檔案拖出去給 Finder,對應 Windows 的 SHDoDragDrop
// (windows/runner/file_drag.cpp),共用 channel "tterminal/filedrag"。
//
// 開一個 NSDraggingSession 需要「觸發這次拖曳的滑鼠事件」。Dart 端是在指標移動
// 超過門檻時才呼叫 startDrag,這時 NSApp.currentEvent 通常就是那個
// leftMouseDragged;萬一不是(事件已被換掉)就用目前指標位置合成一個,否則
// 拖曳根本開不起來。
//
// Windows 的 SHDoDragDrop 是 modal、拖放結束才返回;beginDraggingSession 相反,
// 呼叫後立刻返回。為了讓 Dart 端 _dragOutActive(拖出期間落回自己視窗的 drop
// 要忽略)的存活期跟 Windows 一致,result 押到 session 結束才回。

final class FileDragSource: NSObject, NSDraggingSource {
  private static let mouseTypes: Set<NSEvent.EventType> = [
    .leftMouseDown, .leftMouseDragged, .rightMouseDown, .rightMouseDragged,
    .otherMouseDown, .otherMouseDragged,
  ]

  private let channel: FlutterMethodChannel
  private weak var flutterView: NSView?
  /// 進行中 session 的 Dart result;session 收尾才回覆(見檔頭註解)。
  private var pending: FlutterResult?

  init(messenger: FlutterBinaryMessenger, flutterView: NSView) {
    channel = FlutterMethodChannel(
      name: "tterminal/filedrag", binaryMessenger: messenger)
    self.flutterView = flutterView
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterMethodNotImplemented)
        return
      }
      self.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "startDrag" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard let args = call.arguments as? [String: Any] else {
      result(FlutterError(code: "bad_args", message: "expected map", details: nil))
      return
    }
    guard let path = args["path"] as? String else {
      result(FlutterError(code: "bad_args", message: "missing path", details: nil))
      return
    }
    guard let view = flutterView, let window = view.window else {
      result(FlutterError(code: "no_view", message: "no flutter view", details: nil))
      return
    }
    guard FileManager.default.fileExists(atPath: path) else {
      result(FlutterError(code: "no_file", message: "not found: \(path)", details: nil))
      return
    }
    guard let event = dragEvent(in: window) else {
      result(FlutterError(code: "no_event", message: "no mouse event", details: nil))
      return
    }

    // 前一個 session 還沒收尾就又拖一次:先把舊的 future 完成,不然 Dart 端的
    // _dragOutActive 永遠清不掉,之後拖進來的檔案會全被當成自己拖出的而忽略。
    pending?(nil)
    pending = result

    let item = NSDraggingItem(pasteboardWriter: URL(fileURLWithPath: path) as NSURL)
    // 跟著游標的縮圖:用 Finder 給這個檔案的圖示,置中在指標上。
    let origin = view.convert(event.locationInWindow, from: nil)
    let size = NSSize(width: 48, height: 48)
    item.setDraggingFrame(
      NSRect(
        x: origin.x - size.width / 2, y: origin.y - size.height / 2,
        width: size.width, height: size.height),
      contents: NSWorkspace.shared.icon(forFile: path))

    let session = view.beginDraggingSession(with: [item], event: event, source: self)
    session.animatesToStartingPositionsOnCancelOrFail = true
  }

  /// 拖放 session 的起點事件;currentEvent 不是這個視窗的滑鼠事件就自己合成。
  private func dragEvent(in window: NSWindow) -> NSEvent? {
    if let current = NSApp.currentEvent, Self.mouseTypes.contains(current.type),
      current.window === window
    {
      return current
    }
    return NSEvent.mouseEvent(
      with: .leftMouseDragged,
      location: window.convertPoint(fromScreen: NSEvent.mouseLocation),
      modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window.windowNumber,
      context: nil,
      eventNumber: 0,
      clickCount: 1,
      pressure: 1)
  }

  // MARK: NSDraggingSource

  func draggingSession(
    _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
  ) -> NSDragOperation {
    // 只給 .copy,不要加 .link:拖出去要的是檔案本身。Windows 那邊給的是
    // COPY|LINK 而 Explorer 對這組合預設選 COPY,但 Finder 會選 link,結果拖出
    // 來的是替身(遠端檔案更糟——替身指向暫存檔)。
    // app 內部回空集合:拖出去又拖回自己視窗時 AppKit 不會 drop,不會在目前
    // 資料夾重複複製一份。
    return context == .outsideApplication ? .copy : []
  }

  func draggingSession(
    _ session: NSDraggingSession, endedAt screenPoint: NSPoint,
    operation: NSDragOperation
  ) {
    pending?(nil)
    pending = nil
  }
}
