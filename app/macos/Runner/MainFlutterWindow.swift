import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow, NSDraggingDestination {
  // channel handler 掛在這兩個身上,要活到視窗關閉
  private var fileDrag: FileDragSource?
  private var fileDrop: FileDropTarget?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let messenger = flutterViewController.engine.binaryMessenger
    // 檔案側窗 → Finder(NSDraggingSession)
    fileDrag = FileDragSource(
      messenger: messenger, flutterView: flutterViewController.view)
    // Finder → 檔案側窗。dragging destination 註冊在 window 而不是 Flutter 的
    // view 上:Flutter 的 view 自己沒接拖放,AppKit 在 view 階層找不到
    // destination 就會把訊息送到 window。這樣不必為了插一層 destination 去動
    // view 階層(動了會牽扯 first responder,鍵盤與 IME 都在上面)。
    fileDrop = FileDropTarget(
      messenger: messenger, flutterView: flutterViewController.view)
    registerForDraggedTypes([.fileURL])

    super.awakeFromNib()
  }

  // MARK: NSDraggingDestination
  // NSWindow 對這些訊息的預設實作是轉給 window.delegate;這裡直接在 window
  // 子類別上接,不去動 delegate(Flutter 之後若要用得到它)。

  func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    return dragOperation(sender)
  }

  func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    return dragOperation(sender)
  }

  func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    return fileDrop?.performDrop(sender) ?? false
  }

  /// 落點是否收得下由 Dart 端 hit-test 檔案側窗決定,native 只看有沒有檔案。
  private func dragOperation(_ sender: NSDraggingInfo) -> NSDragOperation {
    return fileDrop?.hasFiles(sender) == true ? .copy : []
  }
}
