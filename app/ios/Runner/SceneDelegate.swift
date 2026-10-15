import Flutter
import UIKit

/// 自訂 scene delegate:掛上背景保活橋接(連線數 channel + 背景任務 +
/// Live Activity)與 iPhone Duo 摺痕橋接。其餘生命週期全部交給
/// FlutterSceneDelegate。
class SceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    if let controller = window?.rootViewController as? FlutterViewController {
      BackgroundBridge.shared.attach(messenger: controller.binaryMessenger)
      FoldBridge.shared.attach(messenger: controller.binaryMessenger)
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
