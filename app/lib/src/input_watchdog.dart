// 偵測「按鍵被系統層的全域鍵盤 hook 吃掉」。
//
// 為什麼要用猜的:實測過三條路徑,`WH_KEYBOARD_LL` 的 hook 只要回傳 1,那個
// 按鍵在使用者模式就徹底消失——WM_KEYDOWN/WM_CHAR 沒有、Raw Input(WM_INPUT)
// 沒有、連 GetAsyncKeyState 的「按過」bit 都是 0。win32k 在派送給任何視窗
// 之前就攔掉了,應用程式沒有任何合法管道看得到它,更不可能把它撿回來
// (要撿只能自己也掛一個 hook 搶在人家前面,誰後掛誰先跑——那是軍備競賽,
// 而且會把使用者真正要用的熱鍵一起打壞)。
//
// 唯一還看得見的是**統計特徵**:空白佔正常輸入的一到兩成,連打好幾百個
// 字元一個空白都沒有,實務上不會發生。聽寫/巨集工具(Typeless、AutoHotkey、
// PowerToys Keyboard Manager…)的熱鍵只要含空白鍵,它的 hook 就必須攔下
// **每一個**空白、壓著等看後面有沒有跟到組合鍵才決定放不放行;它的「目前按著
// 哪些鍵」狀態一旦卡住(呼叫熱鍵時 keyup 在焦點切換中掉了是最常見的),
// 結果就是空白從此人間蒸發,其他鍵完全正常。
//
// 這裡**不做任何補償**:補送一個空白會跟人家真正的熱鍵打架(使用者真的在
// 呼叫聽寫時就會多吃一個空白)。只負責在使用者開始懷疑人生之前告訴他
// 發生什麼事、該去動哪個工具。

import 'dart:io' show Platform, Process;

/// 「一直打字卻完全沒有空白」偵測器。
///
/// 餵給它使用者實際送進 PTY 的可見文字即可;整個生命週期只會示警一次。
class SpaceWatchdog {
  SpaceWatchdog({
    this.charThreshold = 250,
    this.quietSpan = const Duration(seconds: 30),
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  /// 連續幾個可見字元沒出現空白就示警。
  /// 250 個字元大約是三、四行指令,正常打字不可能一個空白都沒有;
  /// 而最長的無空白 token(base64、長路徑)也很少超過這個量級。
  final int charThreshold;

  /// 同時要求「持續這麼久」才示警:貼一長串沒有空白的東西是一瞬間的事,
  /// 真的壞掉則是幾十秒、幾分鐘都生不出一個空白。
  final Duration quietSpan;

  final DateTime Function() _now;

  int _chars = 0;
  DateTime? _since;
  bool _fired = false;

  /// 已經示警過(呼叫端不必再問第二次)。
  bool get fired => _fired;

  /// 餵入一段剛送進 PTY 的文字。回 true = 這次踩到門檻,該提示使用者。
  bool observe(String text) {
    if (_fired) return false;
    var printable = 0;
    for (final rune in text.runes) {
      // 半形空白正常 = 一切安好;全形空白(輸入法切到全形)也算數,
      // 那種情況使用者看得到自己打出了東西,不是這裡要抓的症狀。
      if (rune == 0x20 || rune == 0x3000) {
        _chars = 0;
        _since = null;
        return false;
      }
      if (rune >= 0x20 && rune != 0x7f) printable++;
    }
    if (printable == 0) return false;

    final now = _now();
    _since ??= now;
    _chars += printable;
    if (_chars < charThreshold) return false;
    if (now.difference(_since!) < quietSpan) return false;

    _fired = true;
    return true;
  }
}

/// 猜是誰在掛全域鍵盤 hook,好在提示裡直接點名。
///
/// 沒有 API 可以列舉 hook(那是 win32k 內部狀態),只能比對已知會掛
/// 低階鍵盤 hook 的工具有沒有在跑。抓不到就回 null,提示照樣給得出來。
/// 只在真的要示警時呼叫一次——spawn 一個行程不便宜。
Future<String?> detectSuspectInputTool() async {
  if (!Platform.isWindows) return null;
  const suspects = <String, String>{
    'typeless.exe': 'Typeless',
    'autohotkey.exe': 'AutoHotkey',
    'autohotkey64.exe': 'AutoHotkey',
    'powertoys.keyboardmanagerengine.exe': 'PowerToys Keyboard Manager',
    'wisprflow.exe': 'Wispr Flow',
    'espanso.exe': 'espanso',
    'quicker.exe': 'Quicker',
  };
  try {
    final result = await Process.run('tasklist', ['/fo', 'csv', '/nh']);
    if (result.exitCode != 0) return null;
    final output = (result.stdout as String).toLowerCase();
    for (final suspect in suspects.entries) {
      if (output.contains(suspect.key)) return suspect.value;
    }
  } catch (_) {
    // tasklist 不在、被政策擋掉都無所謂,提示不靠它
  }
  return null;
}
