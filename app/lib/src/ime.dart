// IME / 文字輸入橋接 —— 自繪 terminal 支援中文輸入的核心。
//
// 為什麼需要這一層:terminal 是自繪 canvas,沒有 Flutter 的 EditableText,
// 平台輸入法(注音、拼音、日文、韓文…)無處可依附。作法是掛一個「隱形輸入框」
// (TextInputConnection),把 IME 的組字(composing / preedit)與確認(commit)
// 事件接過來:
//
//   * **組字中**的文字不送進 PTY,只交給 renderer 畫在游標處(帶底線),
//     使用者才看得到自己正在打什麼。
//   * **確認後**的文字才編碼成 bytes 寫入 PTY。
//   * 輸入框狀態要定期清空,避免文字在隱形輸入框裡越積越多——但桌面上
//     「不能」在每次確認後立刻清(會跟下一段組字競態,見 updateEditingValue),
//     改成輸入閒置後才清;手機維持立即清空(墊底字元要馬上補回)。
//
// 同時把游標的螢幕座標回報給平台(setCaretRect / setComposingRect),
// 候選字視窗才會出現在游標旁邊,而不是視窗左上角。
//
// 注意:可見字元(含英數)一律走這條路,不走 KeyEncoder,
// 這樣中文組字時不會同時被當成按鍵送出去(重複輸入的經典 bug)。

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// 組字狀態:renderer 用它在游標處畫 preedit。
@immutable
class ComposingState {
  const ComposingState({
    this.text = '',
    this.cursorOffset = 0,
    this.selectionLength = 0,
  });

  /// 目前組字中的文字(未確認)。空字串表示沒有在組字。
  final String text;

  /// IME 在組字文字內的游標位置(以 UTF-16 code unit 計)。
  /// 有選取範圍時指向範圍起點。
  final int cursorOffset;

  /// IME 選取範圍的長度(注音按 ←/→ 回頭改字時,輸入法會選住其中一個字)。
  /// 0 = 只有游標、沒有選取範圍。
  final int selectionLength;

  bool get isEmpty => text.isEmpty;
  bool get isNotEmpty => text.isNotEmpty;

  @override
  bool operator ==(Object other) =>
      other is ComposingState &&
      other.text == text &&
      other.cursorOffset == cursorOffset &&
      other.selectionLength == selectionLength;

  @override
  int get hashCode => Object.hash(text, cursorOffset, selectionLength);
}

/// 隱形輸入框:把平台 IME 事件轉成「組字中」與「已確認」兩種訊號。
class TerminalTextInput implements TextInputClient {
  TerminalTextInput({
    required this.onCommit,
    required this.onComposingChanged,
    bool? padBackspace,
    bool? deferReset,
  }) : _padBackspace =
           padBackspace ?? (Platform.isIOS || Platform.isAndroid),
       _deferReset = deferReset ?? !(Platform.isIOS || Platform.isAndroid);

  /// 使用者確認的文字(要送進 PTY)。
  final void Function(String text) onCommit;

  /// 組字狀態變化(要重繪 preedit)。
  final void Function(ComposingState state) onComposingChanged;

  static const _emptyValue = TextEditingValue.empty;

  /// 手機軟鍵盤的 backspace 沒有按鍵事件,只會對輸入框呼叫 deleteBackward,
  /// 而空欄位的 deleteBackward 是 no-op——backspace 就完全失效。
  /// 解法:欄位永遠墊一個零寬空白,刪掉它 → 收到「欄位變短」→ 轉成 DEL 補回。
  final bool _padBackspace;
  static const _pad = '\u200b';

  TextEditingValue get _baseValue => _padBackspace
      ? const TextEditingValue(
          text: _pad,
          selection: TextSelection.collapsed(offset: 1),
        )
      : _emptyValue;

  /// 桌面:確認後的輸入框重置改成「閒置後才做」(見 updateEditingValue)。
  /// 手機軟鍵盤依賴每次確認後立即清空(墊底字元也要馬上補回),維持原行為。
  final bool _deferReset;
  static const _resetIdleDelay = Duration(milliseconds: 900);
  Timer? _resetTimer;

  TextInputConnection? _conn;
  late TextEditingValue _lastValue = _baseValue;
  ComposingState _composing = const ComposingState();

  ComposingState get composing => _composing;
  bool get attached => _conn?.attached ?? false;

  /// [viewId] 是這個 terminal 所在的 FlutterView(`View.of(context).viewId`)。
  /// Windows embedder(multi-view)沒有它會拒絕 setClient,
  /// 整條文字輸入路徑會靜默死掉(按鍵字元與 IME 事件全被丟棄)。
  void attach({int? viewId}) {
    if (attached) {
      _conn!.show();
      return;
    }
    _conn = TextInput.attach(
      this,
      TextInputConfiguration(
        viewId: viewId,
        // multiline:避免 IME 顯示「換行/完成」動作鍵並關閉自動大寫
        inputType: TextInputType.multiline,
        inputAction: TextInputAction.newline,
        autocorrect: false,
        enableSuggestions: false,
        // 終端內容常含機密(密碼、金鑰),不要餵給輸入法的個人化學習
        enableIMEPersonalizedLearning: false,
        enableDeltaModel: false,
        textCapitalization: TextCapitalization.none,
      ),
    );
    _lastValue = _baseValue;
    _conn!
      ..setEditingState(_baseValue)
      ..show();
  }

  void detach() {
    _resetTimer?.cancel();
    _resetTimer = null;
    _conn?.close();
    _conn = null;
    _lastValue = _emptyValue;
    _setComposing(const ComposingState());
  }

  /// 回報游標的螢幕位置,讓候選字視窗跟著游標跑。
  /// [caret] 與 [editableSize] 都是 terminal widget 的本地座標。
  void updateCaretGeometry({
    required Rect caret,
    required Size editableSize,
    required Matrix4 transform,
  }) {
    final conn = _conn;
    if (conn == null || !conn.attached) return;
    conn
      ..setEditableSizeAndTransform(editableSize, transform)
      ..setCaretRect(caret)
      ..setComposingRect(caret);
  }

  void _setComposing(ComposingState next) {
    if (next == _composing) return;
    _composing = next;
    onComposingChanged(next);
  }

  @override
  void updateEditingValue(TextEditingValue value) {
    final range = value.composing;
    final isComposing = range.isValid && !range.isCollapsed;
    // Windows engine 在 WM_IME_STARTCOMPOSITION 會送出 *collapsed* 的
    // composing range(如 (0,0)),意思是「組字剛開始、還沒有內容」。
    // 這絕不能當成「組字結束」處理:若在此時把 setEditingState(空) 推回去,
    // 引擎端 TextInputModel 的 composing 旗標會被清掉(EndComposing),
    // 但 OS 輸入法其實還在組字——之後每個組字更新都會走非組字路徑
    // (AddText + UpdateComposingText 各插入一次,文字翻倍),且再也不會
    // 回報 composing,組字中間狀態被當成已確認文字逐鍵送進 PTY。
    // 症狀:注音符號直接噴出、重複、候選窗不出現(Windows 實測)。
    final isComposePending = range.isValid && range.isCollapsed;

    // 「已確認」= 組字區之前的文字;組字區本身還在編輯中不算數。
    final settled = (isComposing || isComposePending)
        ? value.text.substring(0, range.start)
        : value.text;
    final prevRange = _lastValue.composing;
    final prevSettled = prevRange.isValid && !prevRange.isCollapsed
        ? _lastValue.text.substring(0, prevRange.start)
        : _lastValue.text;

    // 只送出這次新增的部分(有些 IME 會邊確認邊繼續組下一個字)
    if (settled.startsWith(prevSettled)) {
      final delta = settled.substring(prevSettled.length);
      if (delta.isNotEmpty) onCommit(delta);
    } else if (!isComposing &&
        !isComposePending &&
        prevSettled.startsWith(settled)) {
      // 欄位變短 = 軟鍵盤 backspace(deleteBackward 刪掉墊底字元)→ DEL
      onCommit('\u007f' * (prevSettled.length - settled.length));
    } else if (settled.isNotEmpty) {
      // 內容整段被換掉(罕見):整段當新輸入送出
      onCommit(settled);
    }

    if (isComposing || isComposePending) {
      // 新的組字開始/進行中:待送的重置絕不能再送出去(見下)。
      _resetTimer?.cancel();
      _lastValue = value;
      // 把 IME 游標/選取換算成「組字文字內」的 offset。renderer 全靠這兩個值
      // 才畫得出使用者現在改到哪一個字——注音按 ←/→ 回頭選字時,整段組字看起來
      // 完全一樣,沒有游標就只能瞎猜。
      final span = range.end - range.start;
      final base = (value.selection.baseOffset - range.start).clamp(0, span);
      final extent = (value.selection.extentOffset - range.start).clamp(0, span);
      _setComposing(
        ComposingState(
          text: range.textInside(value.text),
          cursorOffset: base < extent ? base : extent,
          selectionLength: (extent - base).abs(),
        ),
      );
    } else if (!_deferReset) {
      // 手機:組字結束立刻重置(墊底字元要馬上補回,backspace 才有效)。
      _setComposing(const ComposingState());
      _lastValue = _baseValue;
      _conn?.setEditingState(_baseValue);
    } else {
      // 桌面:重置「不能」在每次確認後立刻做——會跟下一段組字競態。
      //
      // macOS engine 收到 composing 為 collapsed 的 setEditingState 時,若
      // 引擎端 model 正在組字,會呼叫 discardMarkedText 把 OS 的組字整段丟掉
      // (FlutterTextInputPlugin.mm)。而「確認→我們回推重置→重置抵達引擎」
      // 是非同步的:注音邊確認邊組下一段(同一鍵 insertText+setMarkedText)、
      // 或使用者確認後緊接著打下一段,重置抵達時引擎已經在組新的一段,
      // 整段未確認的注音就被 OS 丟掉(=使用者白打)。終端輸出重繪繁忙時
      // (tmux/claude code)訊息延遲更大,更容易中獎。
      //
      // 所以確認後保留實際值(delta 邏輯照常運作、不會重複送出),
      // 等輸入真正閒置一陣子才清空,避免文字在隱形輸入框裡無限累積。
      _setComposing(const ComposingState());
      _lastValue = value;
      _scheduleIdleReset();
    }
  }

  void _scheduleIdleReset() {
    _resetTimer?.cancel();
    _resetTimer = Timer(_resetIdleDelay, () {
      _resetTimer = null;
      if (_composing.isNotEmpty) return;
      _lastValue = _baseValue;
      _conn?.setEditingState(_baseValue);
    });
  }

  @override
  TextEditingValue? get currentTextEditingValue => _lastValue;

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void performAction(TextInputAction action) {
    // 桌面版 Enter 由 KeyEncoder 處理(按鍵事件先被消化),
    // 這條路徑主要是手機軟鍵盤的送出鍵。
    if (action == TextInputAction.newline || action == TextInputAction.done) {
      onCommit('\r');
    }
  }

  @override
  void connectionClosed() {
    _resetTimer?.cancel();
    _resetTimer = null;
    _conn = null;
    _lastValue = _emptyValue;
    _setComposing(const ComposingState());
  }

  // 以下是 TextInputClient 其餘介面,terminal 用不到。
  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}

  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  @override
  void insertTextPlaceholder(Size size) {}

  @override
  void removeTextPlaceholder() {}

  @override
  void showToolbar() {}

  @override
  void didChangeInputControl(
    TextInputControl? oldControl,
    TextInputControl? newControl,
  ) {}

  @override
  void performSelector(String selectorName) {}

  /// 平台把焦點交還給輸入框(Flutter master 新增)。
  /// terminal 沒有可選取的文字欄位,回 true 表示已接手。
  @override
  bool onFocusReceived() => true;

  @override
  void insertContent(KeyboardInsertedContent content) {}
}
