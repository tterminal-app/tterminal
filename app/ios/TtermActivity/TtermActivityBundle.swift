import ActivityKit
import SwiftUI
import WidgetKit

/// Live Activity extension:在 Dynamic Island 與鎖定畫面顯示
/// 「保持中的 SSH 連線數」(app 退到背景時由 BackgroundBridge 啟動)。
/// 字串在 Localizable.xcstrings(英文是 key,繁中與英文單複數在裡面)。
@main
struct TtermActivityBundle: WidgetBundle {
  var body: some Widget {
    TtermLiveActivity()
  }
}

struct TtermLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: TtermActivityAttributes.self) { context in
      // 鎖定畫面 / 橫幅
      HStack(spacing: 10) {
        Image(systemName: "terminal.fill")
          .foregroundStyle(.green)
        Text("Keeping \(context.state.connections) SSH connections alive")
          .font(.callout)
        Spacer()
      }
      .padding(14)
      .activityBackgroundTint(Color(red: 0.09, green: 0.09, blue: 0.09))
      .activitySystemActionForegroundColor(.green)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Image(systemName: "terminal.fill")
            .foregroundStyle(.green)
            .padding(.leading, 6)
        }
        DynamicIslandExpandedRegion(.trailing) {
          Text("\(context.state.connections)")
            .font(.title2.monospacedDigit())
            .foregroundStyle(.green)
            .padding(.trailing, 6)
        }
        DynamicIslandExpandedRegion(.bottom) {
          Text("Staying connected over SSH")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      } compactLeading: {
        Image(systemName: "terminal.fill").foregroundStyle(.green)
      } compactTrailing: {
        Text("\(context.state.connections)")
          .font(.body.monospacedDigit())
          .foregroundStyle(.green)
      } minimal: {
        Image(systemName: "terminal.fill").foregroundStyle(.green)
      }
    }
  }
}
