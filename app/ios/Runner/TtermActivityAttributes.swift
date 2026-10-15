import ActivityKit

/// Live Activity 的資料形狀。**同一個檔案同時編進 Runner 與
/// TtermActivity extension**(ActivityKit 以型別名稱與編碼形狀跨程序配對,
/// 兩邊必須一致)。
struct TtermActivityAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    /// 目前保持中的 SSH 連線數。
    var connections: Int
  }
}
