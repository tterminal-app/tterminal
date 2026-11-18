import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // 要在任何 Flutter 引擎建立前裝好,見 SceneDisplayLink.swift
    SceneDisplayLink.install()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// plugin 在 storyboard 的 FlutterViewController 建好引擎後才註冊。
  ///
  /// 不能在 didFinishLaunching 註冊:那時還沒有 scene,FlutterAppDelegate 會先
  /// 啟動一顆「launch engine」給 plugin 用,引擎的 CADisplayLink 就在沒有 scene
  /// 的時候建好、綁死在主顯示器(iPhone Duo 的外螢幕),內螢幕開 app 會卡在
  /// launch screen。
  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
