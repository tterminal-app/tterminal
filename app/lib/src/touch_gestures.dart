// 手機觸控手勢的純換算邏輯(與 widget 分離,單元測試直接餵位移驗證輸出)。
//
//   * 長按終端後拖曳 → 方向鍵搖桿(Termius 慣例):ArrowJoystick
//   * 一般拖曳 → 捲動 scrollback:TouchScrollTracker

/// 長按方向鍵搖桿:把「相對長按原點的位移」換算成方向與速度檔。
/// Termius 慣例:位移超過 [deadZone] 以慢速連發、超過 [fastZone] 加速;
/// 方向取主軸(上下或左右),不做斜向。
class ArrowJoystick {
  ArrowJoystick({this.deadZone = 18, this.fastZone = 70});

  final double deadZone;
  final double fastZone;

  /// 目前方向(CSI final char:A=上、B=下、C=右、D=左);null = 死區內不送。
  String? direction;

  /// 快速檔(位移超過 fastZone)。
  bool fast = false;

  /// 餵「相對原點」的位移。回傳狀態是否改變
  /// (呼叫端據此重啟連發計時器與更新 UI)。
  bool update(double dx, double dy) {
    final adx = dx.abs();
    final ady = dy.abs();
    final mag = adx > ady ? adx : ady;
    String? dir;
    if (mag >= deadZone) {
      dir = adx >= ady ? (dx > 0 ? 'C' : 'D') : (dy > 0 ? 'B' : 'A');
    }
    final f = dir != null && mag >= fastZone;
    if (dir == direction && f == fast) return false;
    direction = dir;
    fast = f;
    return true;
  }
}

/// 拖曳捲動:位移累積滿一行才捲一行,剩餘保留給下一次。
/// 回傳行數,正值 = 手指往下拖 = 往歷史捲(內容跟著手指走)。
class TouchScrollTracker {
  TouchScrollTracker({required this.lineHeight});

  final double lineHeight;
  double _acc = 0;

  int feed(double dy) {
    _acc += dy;
    final lines = _acc ~/ lineHeight;
    _acc -= lines * lineHeight;
    return lines;
  }
}
