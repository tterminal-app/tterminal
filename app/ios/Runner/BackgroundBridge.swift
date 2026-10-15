import ActivityKit
import Flutter
import UIKit

/// SSH 連線背景保活(Termius 慣例):
///   * Dart 端連線數變化 → MethodChannel 通知這裡
///   * 退到背景且有連線 → 申請背景執行時間(讓 keepalive 與未完成的寫入
///     跑完;之後 app 被掛起時 TCP socket 仍在核心層保留,回前台多半能續用)
///   * 同時起 Live Activity 在 Dynamic Island / 鎖定畫面顯示連線數,
///     使用者知道連線還掛著
final class BackgroundBridge: NSObject {
  static let shared = BackgroundBridge()

  private var connectionCount = 0
  private var bgTask: UIBackgroundTaskIdentifier = .invalid
  private var activity: Any?  // Activity<TtermActivityAttributes>(iOS 16.2+)

  func attach(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "tterm/background", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(nil) }
      if call.method == "setConnectionCount", let n = call.arguments as? Int {
        self.connectionCount = n
        // 背景中連線數變化(斷線)→ 同步更新 Live Activity
        if UIApplication.shared.applicationState == .background {
          if n > 0 { self.updateActivity(count: n) } else { self.endActivity() }
        }
        result(nil)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
  }

  func enteredBackground() {
    guard connectionCount > 0 else { return }
    beginBgTask()
    startActivity(count: connectionCount)
  }

  func enteringForeground() {
    endBgTask()
    endActivity()
  }

  // MARK: - 背景執行時間

  private func beginBgTask() {
    endBgTask()
    bgTask = UIApplication.shared.beginBackgroundTask(withName: "tterm-ssh") {
      [weak self] in self?.endBgTask()
    }
  }

  private func endBgTask() {
    if bgTask != .invalid {
      UIApplication.shared.endBackgroundTask(bgTask)
      bgTask = .invalid
    }
  }

  // MARK: - Live Activity

  private func startActivity(count: Int) {
    guard #available(iOS 16.2, *) else { return }
    guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
    let state = TtermActivityAttributes.ContentState(connections: count)
    if let existing = activity as? Activity<TtermActivityAttributes> {
      Task { await existing.update(ActivityContent(state: state, staleDate: nil)) }
      return
    }
    activity = try? Activity.request(
      attributes: TtermActivityAttributes(),
      content: ActivityContent(state: state, staleDate: nil))
  }

  private func updateActivity(count: Int) {
    guard #available(iOS 16.2, *),
      let current = activity as? Activity<TtermActivityAttributes>
    else { return }
    let state = TtermActivityAttributes.ContentState(connections: count)
    Task { await current.update(ActivityContent(state: state, staleDate: nil)) }
  }

  private func endActivity() {
    guard #available(iOS 16.2, *),
      let current = activity as? Activity<TtermActivityAttributes>
    else { return }
    activity = nil
    Task { await current.end(nil, dismissalPolicy: .immediate) }
  }
}
