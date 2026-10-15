import Flutter
import UIKit

/// iPhone Duo 摺痕 → Dart(`tterm/fold` channel,Dart 端見 lib/src/fold.dart)。
///
/// Flutter 在 iOS 還不填 MediaQuery.displayFeatures,所以自己量 FlutterView 上
/// iOS 27.1 的 reserved regions:
///   * `.division`:半開時切開內螢幕的摺痕帶 → `fold`。攤平時 inactive,
///     Apple 要求當一整塊螢幕用,所以不回報
///   * `.occlusion`:螢幕下鏡頭啟用時的遮擋區 → `cutout`
/// 座標取 FlutterView 自己的 point,剛好就是 Flutter 的邏輯像素。
///
/// reserved regions 沒有變更通知;UIKit 在它變動時會重跑 layout,所以每次
/// viewDidLayoutSubviews 重讀。另外掛 UIHingeInteraction,鉸鏈一動就再補讀
/// 幾次——摺起時 region 會比鉸鏈狀態晚約一秒才更新。
///
/// 這些 API 只在 iOS 27.1 SDK(Xcode 27.1+)裡,舊 SDK 編譯時整段略過、永遠回報
/// 沒有摺痕。Swift 沒有 SDK 版本巨集,用 UIKit 的 module 版本判斷:
/// iOS 27.0 SDK 是 9127.0.84、27.1 是 9127.0.85。
final class FoldBridge: NSObject {
  static let shared = FoldBridge()

  private struct Region: Equatable {
    let frame: CGRect
    let type: String
  }

  private var channel: FlutterMethodChannel?
  private weak var view: UIView?
  private var current: [Region] = []

  func attach(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "tterm/fold", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(nil) }
      if call.method == "get" {
        self.refresh()
        result(Self.encode(self.current))
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
    self.channel = channel
  }

  /// 根 view controller 載入 view 後呼叫:記住要量的 view、掛鉸鏈監聽。
  func track(view: UIView) {
    self.view = view
    #if canImport(UIKit, _version: 9127.0.85)
      if #available(iOS 27.1, *) {
        view.addInteraction(
          UIHingeInteraction { [weak self] _, _ in self?.hingeMoved() })
      }
    #endif
  }

  /// 重量一次,有變才通知 Dart。
  func refresh() {
    guard let view else { return }
    let next = Self.measure(view)
    guard next != current else { return }
    current = next
    channel?.invokeMethod("update", arguments: Self.encode(next))
  }

  private func hingeMoved() {
    refresh()
    for delay in [0.3, 1.2] {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
        self?.refresh()
      }
    }
  }

  private static func measure(_ view: UIView) -> [Region] {
    #if canImport(UIKit, _version: 9127.0.85)
      guard #available(iOS 27.1, *) else { return [] }
      let kinds: [(UIView.ReservedRegion.Kind, String)] = [
        (.division, "fold"), (.occlusion, "cutout"),
      ]
      return kinds.flatMap { kind, type in
        view.reservedRegions(kind: kind)
          .filter { $0.isActive }
          .map { Region(frame: $0.frame, type: type) }
      }
    #else
      return []
    #endif
  }

  private static func encode(_ regions: [Region]) -> [[String: Any]] {
    regions.map {
      [
        "x": $0.frame.minX, "y": $0.frame.minY,
        "w": $0.frame.width, "h": $0.frame.height,
        "type": $0.type,
      ]
    }
  }
}

/// Main.storyboard 的根 view controller:每次 layout 完重讀摺痕。
final class FoldAwareFlutterViewController: FlutterViewController {
  override func viewDidLoad() {
    super.viewDidLoad()
    FoldBridge.shared.track(view: view)
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    FoldBridge.shared.refresh()
  }
}
