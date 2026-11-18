import Flutter
import UIKit

/// 自訂 scene delegate:掛上背景保活橋接(連線數 channel + 背景任務 +
/// Live Activity)、iPhone Duo 摺痕橋接、內購橋接與開外部網址。其餘生命週期
/// 全部交給 FlutterSceneDelegate。
class SceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    SceneDisplayLink.scene = scene as? UIWindowScene
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    if let controller = window?.rootViewController as? FlutterViewController {
      BackgroundBridge.shared.attach(messenger: controller.binaryMessenger)
      FoldBridge.shared.attach(messenger: controller.binaryMessenger)
      StoreBridge.shared.attach(messenger: controller.binaryMessenger, scene: scene)
      Self.attachUrlOpener(messenger: controller.binaryMessenger)
    }
  }

  /// `tterm/url`:Dart 的 openUrl(lib/src/url_open.dart)在 iOS 不能 spawn
  /// 程序,改由這裡用系統瀏覽器開。Dart 端已經擋過 scheme,這裡再擋一次,
  /// 只放行 http/https。
  private static func attachUrlOpener(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "tterm/url", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "open" else { return result(FlutterMethodNotImplemented) }
      guard let text = call.arguments as? String, let url = URL(string: text),
        let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
      else { return result(false) }
      UIApplication.shared.open(url) { ok in result(ok) }
    }
  }

  override func sceneDidBecomeActive(_ scene: UIScene) {
    super.sceneDidBecomeActive(scene)
    if let windowScene = scene as? UIWindowScene {
      SceneDisplayLink.reportActive(windowScene)
    }
  }

  override func sceneDidEnterBackground(_ scene: UIScene) {
    super.sceneDidEnterBackground(scene)
    BackgroundBridge.shared.enteredBackground()
  }

  override func sceneWillEnterForeground(_ scene: UIScene) {
    super.sceneWillEnterForeground(scene)
    BackgroundBridge.shared.enteringForeground()
  }
}
