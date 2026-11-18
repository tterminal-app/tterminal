import QuartzCore
import UIKit
import os

/// 讓 Flutter 的 CADisplayLink 跟著 app 所在的 scene 走,而不是綁在「主顯示器」。
///
/// iPhone Duo 有兩塊螢幕:主顯示器是外螢幕(466×678),內螢幕(669×951)是第二個
/// 顯示器。`+[CADisplayLink displayLinkWithTarget:selector:]` 依 SDK 標頭說明是
/// 「for the main display」;攤開時外螢幕關掉,這種 display link 就再也不觸發。
/// Flutter(3.47 到目前的 master)的 VSyncClient 與 FlutterMetalLayer 都用這個
/// 方法建 display link,結果在內螢幕開 app 一幀都畫不出來,停在 launch screen。
///
/// iOS 27 新增 `UIWindowScene.displayLink(target:selector:)`(UIScreen 版本同時
/// deprecated),這裡把類別方法換成:有 window scene 就用 scene 的版本,其餘照舊。
/// 要在 Flutter 引擎建立之前裝好(AppDelegate 的 didFinishLaunching),而且引擎
/// 必須等 scene 連上才建立——見 AppDelegate 改用 FlutterImplicitEngineDelegate。
///
/// storyboard 的 FlutterViewController 比 `scene(_:willConnectTo:)` 更早被建立,
/// 那時只能從 `connectedScenes` 找到正在連上的 scene;SceneDelegate 連上後再記住它。
///
/// Flutter 上游改用 scene 的 display link 之後,這整個檔案就可以拿掉。
enum SceneDisplayLink {
  private static let log = Logger(subsystem: "dev.tterm.ttermApp", category: "display-link")
  private static var installed = false
  /// 正在呼叫 UIKit 的 scene 版本時為 true,避免 UIKit 內部再走回類別方法時遞迴。
  fileprivate static var routing = false
  /// 改道 / 退回主顯示器的次數(只在主執行緒更動),scene 第一次進前景時印出來。
  private static var routedCount = 0
  private static var fallbackCount = 0
  private static var reported = false

  /// SceneDelegate 連上 scene 後設定;沒有設定時從 connectedScenes 找。
  static weak var scene: UIWindowScene?

  static func install() {
    guard !installed else { return }
    installed = true
    #if canImport(UIKit, _version: 9127.0.84)
      guard #available(iOS 27.0, *) else { return }
      let cls: AnyClass = CADisplayLink.self
      guard
        let original = class_getClassMethod(
          cls, NSSelectorFromString("displayLinkWithTarget:selector:")),
        let replacement = class_getClassMethod(
          cls, #selector(CADisplayLink.tterm_displayLink(withTarget:selector:)))
      else {
        log.error("CADisplayLink class method not found; display link stays on main display")
        return
      }
      method_exchangeImplementations(original, replacement)
    #endif
  }

  /// 目前 app 的 window scene:前景中的優先。只在主執行緒呼叫。
  fileprivate static func currentScene() -> UIWindowScene? {
    if let scene, scene.activationState != .unattached { return scene }
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    return scenes.first { $0.activationState == .foregroundActive }
      ?? scenes.first { $0.activationState == .foregroundInactive }
      ?? scenes.first
  }

  fileprivate static func didRoute(to scene: UIWindowScene) {
    routedCount += 1
  }

  fileprivate static func didFallBack(_ reason: String) {
    fallbackCount += 1
    log.notice("CADisplayLink on main display: \(reason, privacy: .public)")
  }

  /// scene 第一次進前景時印一次狀態,實機驗證看這行。
  ///
  /// 不在建立 display link 當下印螢幕大小:那時 storyboard 還在載入、scene 還沒
  /// 定位到最終的顯示器,印出外螢幕的尺寸也不代表失敗(之後 UIKit 會跟著 scene
  /// 重新指向)。
  static func reportActive(_ scene: UIWindowScene) {
    guard !reported else { return }
    reported = true
    let size = scene.screen.bounds.size
    log.notice(
      "scene active on \(Int(size.width), privacy: .public)x\(Int(size.height), privacy: .public); CADisplayLink routed to scene: \(routedCount, privacy: .public), on main display: \(fallbackCount, privacy: .public)"
    )
  }
}

#if canImport(UIKit, _version: 9127.0.84)
  extension CADisplayLink {
    /// 與 `displayLinkWithTarget:selector:` 交換實作:交換後呼叫本方法 = 呼叫原本的。
    /// 一定要 `dynamic`:extension 裡的方法 Swift 預設直接呼叫,下面「呼叫原本的」
    /// 那行就會變成呼叫自己而無限遞迴。
    @objc dynamic class func tterm_displayLink(withTarget target: Any, selector sel: Selector)
      -> CADisplayLink
    {
      if #available(iOS 27.0, *), Thread.isMainThread, !SceneDisplayLink.routing {
        if let scene = SceneDisplayLink.currentScene() {
          SceneDisplayLink.routing = true
          defer { SceneDisplayLink.routing = false }
          if let link = scene.displayLink(target: target, selector: sel) {
            SceneDisplayLink.didRoute(to: scene)
            return link
          }
          SceneDisplayLink.didFallBack("scene returned no display link")
        } else {
          SceneDisplayLink.didFallBack("no window scene yet")
        }
      }
      return tterm_displayLink(withTarget: target, selector: sel)
    }
  }
#endif
