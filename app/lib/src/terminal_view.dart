// TerminalView:把 native session、鍵盤、IME、滾輪、尺寸變化接成一個可用的終端。

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

import 'dictation.dart';
import 'ime.dart';
import 'input_watchdog.dart';
import 'key_toolbar.dart';
import 'keys.dart';
import 'l10n.dart';
import 'mouse.dart';
import 'selection.dart';
import 'term_ffi.dart';
import 'term_painter.dart';
import 'touch_gestures.dart';
import 'url_open.dart';

class TerminalView extends StatefulWidget {
  const TerminalView({
    super.key,
    required this.session,
    this.style,
    this.autofocus = true,
    this.onTitleChanged,
    this.onExit,
    this.onPaintTime,
    this.onCwdChanged,
    this.onFontZoom,
    this.onSpaceMissing,
    this.mobileUI,
    this.foldGap,
  });

  final NativeSession session;
  final TerminalStyle? style;
  final bool autofocus;
  final void Function(String title)? onTitleChanged;
  final VoidCallback? onExit;
  final void Function(double ms)? onPaintTime;

  /// OSC 7 工作目錄變更(檔案側窗跟隨用)。
  final void Function(String? cwd)? onCwdChanged;

  /// Ctrl+滾輪縮放字體:+1 放大一級、-1 縮小一級(由外層改 prefs)。
  final void Function(int steps)? onFontZoom;

  /// 打了一大段字卻連一個空白都沒有 —— 空白鍵很可能被全域鍵盤 hook 吃掉了
  /// (見 input_watchdog.dart)。整個 session 只會呼叫一次。
  final VoidCallback? onSpaceMissing;

  /// 手機模式:功能鍵工具列 + 觸控手勢(長按拖曳=方向鍵、拖曳=捲動)。
  /// null = 依平台(iOS/Android 開啟);測試可強制指定。
  final bool? mobileUI;

  /// 手機模式下橫越本 widget 的橫向摺痕(桌上型姿勢),本地座標 (top, bottom)。
  /// 非 null 時終端只畫在摺痕上方,摺痕下方是操作區(工具列貼底、空白處
  /// 點一下叫鍵盤)——像筆電:上半看輸出、下半打字,文字不會壓在摺痕上。
  final ({double top, double bottom})? foldGap;

  @override
  State<TerminalView> createState() => TerminalViewState();
}

class TerminalViewState extends State<TerminalView> {
  late TerminalStyle _style = widget.style ?? TerminalStyle();
  late final FocusNode _focusNode = FocusNode(debugLabel: 'terminal');
  Timer? _pollTimer;
  late final TerminalTextInput _input;

  final _repaint = ValueNotifier<int>(0);

  /// 「一直打字卻完全沒有空白」= 空白鍵被系統層攔走了(見 input_watchdog.dart)。
  final _spaceWatchdog = SpaceWatchdog();

  Uint32List? _cells;
  (int, int, bool) _cursor = (0, 0, true);
  ComposingState _composing = const ComposingState();

  /// 組字開始時的游標位置(row, col);非組字時為 null。
  ///
  /// preedit 與候選字視窗都釘在這裡,不跟著 `_cursor` 跑:claude code / codex /
  /// vim 這類 TUI 每次重繪都把游標帶到畫面各處,而我們每 16ms 抓一次 grid,
  /// 抓到的中間位置每 frame 都不一樣——preedit 跟著跳就是一直閃爍。組字期間
  /// 使用者沒有在下指令,游標的即時位置對 preedit 沒有意義。
  (int, int)? _composeAnchor;
  String _lastTitle = '';
  String? _lastCwd;
  int _pollCounter = 0;
  bool _exited = false;
  Size? _lastViewport;

  /// 尺寸連續變化(軟鍵盤升降動畫、折疊/展開、分割畫面)時每個中間尺寸都
  /// resize 一次 = 每次都 reflow + SSH window_change + 全螢幕 TUI 整片重畫。
  /// 所以第一個變化照舊下一幀套用,接著的冷卻窗內只記最新的 cols/rows,
  /// 窗尾再套一次。字體變更是使用者明確動作,不受冷卻限制。
  static const _resizeCooldown = Duration(milliseconds: 120);
  Timer? _resizeCooldownTimer;
  (int, int)? _pendingGrid;
  bool _resizeNow = false;
  TermSelection? _selection;
  bool _selecting = false;
  // 滑鼠回報中被按住的按鈕(null = 沒在回報式拖曳);與最後回報的 cell。
  int? _mouseButton;
  CellPos? _lastMouseCell;

  /// 指標最後停的位置(本地座標);修飾鍵按下時要靠它重算網址 hover。
  Offset? _hoverPos;

  /// 目前按著修飾鍵停在上面的網址(非 null = 畫虛底線 + 手指游標)。
  UrlHit? _urlHover;

  /// 上一次看到的修飾鍵狀態,用來辨認「剛按下/剛放開」。
  bool _urlModifierWas = false;

  // ---- 手機模式狀態 ----
  /// 黏著 Ctrl(工具列):下一個輸入變成 Ctrl 組合後自動解除。
  final ValueNotifier<bool> ctrlPending = ValueNotifier(false);
  Offset? _touchOrigin;
  Offset? _touchLast;
  Timer? _longPressTimer;
  ArrowJoystick? _joystick; // 非 null = 長按方向鍵搖桿模式
  Offset _joystickThumb = Offset.zero; // 相對原點、夾在半徑內(overlay 用)
  Timer? _arrowRepeat; // 方向鍵連發(速度依 _joystick.fast)
  TouchScrollTracker? _scrollTracker; // 非 null = 拖曳捲動模式

  // 滾輪/觸控板捲動的跨事件累積:macOS 平滑捲動每個事件的 delta 常常
  // 不到半行,逐事件 round() 會全部歸零被吃掉(tmux mouse on 時特別明顯)。
  TouchScrollTracker? _wheelTracker;

  bool get _mobileUI =>
      widget.mobileUI ?? (Platform.isIOS || Platform.isAndroid);

  NativeSession get session => widget.session;

  /// 分頁切換時由外部把焦點交回這個 terminal。
  void requestFocus() => _focusNode.requestFocus();

  /// 終端是否持有鍵盤焦點。dictation/native 貼上路徑靠這個判斷該不該送進
  /// 終端——焦點在設定頁或編輯器的文字框時,貼上屬於那個文字框,不能進 PTY。
  bool get hasFocus => _focusNode.hasFocus;

  @override
  void initState() {
    super.initState();
    _input = TerminalTextInput(
      onCommit: _commitText,
      // 手機軟鍵盤的 backspace 靠墊底字元偵測(桌面走 KeyEncoder 按鍵事件)
      padBackspace: _mobileUI,
      // 桌面:確認後延後重置,避免跟 IME 下一段組字競態(見 ime.dart)
      deferReset: !_mobileUI,
      onComposingChanged: (state) {
        // 第一次進組字時把位置釘住,整段組字期間都用它(見 _composeAnchor)
        if (state.isNotEmpty) {
          _composeAnchor ??= (_cursor.$1, _cursor.$2);
        } else {
          _composeAnchor = null;
        }
        _composing = state;
        _repaint.value++;
        _updateCaretGeometry();
      },
    );
    _focusNode.addListener(_onFocusChange);
    // 修飾鍵按下/放開時重算網址 hover(見 _onGlobalKey)
    HardwareKeyboard.instance.addHandler(_onGlobalKey);
    // 用 Timer 輪詢 damage 而不是 Ticker:常駐 Ticker 會強迫每個 vsync 都跑
    // 完整 frame pipeline,終端閒置時 app 仍以 60fps 空轉(手機耗電 + 卡頓);
    // Timer 只在真的有 damage 時 _repaint++ 觸發重繪,閒置時零 frame。
    _pollTimer = Timer.periodic(const Duration(milliseconds: 16), _onPoll);
    // 初次進場先畫一次,不必等 PTY 有輸出
    _refreshGrid();
  }

  @override
  void didUpdateWidget(TerminalView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 字體變更 → 換 style、重算 cols/rows(_lastViewport 清掉讓 _syncViewport 重跑)
    final style = widget.style;
    if (style != null && !identical(style, _style)) {
      _style = style;
      _lastViewport = null;
      _resizeNow = true;
      _repaint.value++;
      _updateCaretGeometry();
    }
  }

  @override
  void dispose() {
    if (_focusNode.hasFocus) Dictation.setTerminalFocused(false);
    _longPressTimer?.cancel();
    _arrowRepeat?.cancel();
    _resizeCooldownTimer?.cancel();
    ctrlPending.dispose();
    _pollTimer?.cancel();
    _input.detach();
    HardwareKeyboard.instance.removeHandler(_onGlobalKey);
    _focusNode
      ..removeListener(_onFocusChange)
      ..dispose();
    _repaint.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (_focusNode.hasFocus) {
      _input.attach(viewId: View.of(context).viewId);
      _caretGeometrySent = false;
      _updateCaretGeometry();
    } else {
      _input.detach();
    }
    // native 只在終端有焦點時攔 Ctrl+V(見 text_input_provider.cpp)
    Dictation.setTerminalFocused(_focusNode.hasFocus);
    _repaint.value++;
  }

  void _onPoll(Timer _) {
    if (session.takeDamage() != 0) _refreshGrid();

    // OSC 52:tmux/vim 反白複製 → 系統剪貼簿(每 tick 查,複製完馬上能貼)
    final osc52 = session.takeClipboard();
    if (osc52 != null && osc52.isNotEmpty) {
      unawaited(Clipboard.setData(ClipboardData(text: osc52)));
    }

    // 標題與存活狀態不必每 frame 查(要拿鎖 + 配置字串)
    if (++_pollCounter >= 30) {
      _pollCounter = 0;
      final title = session.title;
      if (title != _lastTitle) {
        _lastTitle = title;
        widget.onTitleChanged?.call(title);
      }
      if (widget.onCwdChanged != null) {
        final cwd = session.currentDirectory;
        if (cwd != _lastCwd) {
          _lastCwd = cwd;
          widget.onCwdChanged!(cwd);
        }
      }
      if (!_exited && !session.isAlive) {
        _exited = true;
        widget.onExit?.call();
      }
      // 前景 TUI(claude code / vim…)被 Ctrl+C / kill 掉時不會送復原序列,
      // 終端就卡在 alt screen 或滑鼠回報模式 —— 症狀是滾輪整個失效,而且
      // PowerShell 沒有 reset 可以自救。這裡在確認 shell 底下已經沒有任何
      // 行程後替它關掉(判斷與實際清理都在 native 端,見 recoverStuckModes)。
      if (session.modes & TermModes.wheelBlocking != 0 &&
          session.recoverStuckModes()) {
        _refreshGrid();
      }
    }
  }

  void _refreshGrid() {
    _cells = session.copyGrid();
    _cursor = session.cursor();
    _repaint.value++;
    _updateCaretGeometry();
  }

  /// 附掛後是否已回報過游標位置(避免每個 damage frame 都送 channel 訊息)。
  bool _caretGeometrySent = false;

  /// 把游標的螢幕座標回報給平台,讓 IME 候選字視窗跟著游標跑。
  ///
  /// 候選字視窗只在**組字中**需要定位;非組字時每次 damage 都送
  /// setEditableSizeAndTransform + setCaretRect + setComposingRect
  /// 三個 platform channel 訊息,快速輸出時在手機上是可感的卡頓來源。
  void _updateCaretGeometry() {
    if (!_input.attached) return;
    if (_composing.isEmpty && _caretGeometrySent) return;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    // 組字中用釘住的位置,候選字視窗才不會跟著 TUI 重繪滿場飛
    final row = _composeAnchor?.$1 ?? _cursor.$1;
    final col = _composeAnchor?.$2 ?? _cursor.$2;
    _input.updateCaretGeometry(
      caret: Rect.fromLTWH(
        col * _style.cellWidth,
        row * _style.cellHeight,
        _style.cellWidth,
        _style.cellHeight,
      ),
      editableSize: box.size,
      transform: box.getTransformTo(null),
    );
    _caretGeometrySent = true;
  }

  /// IME 確認的文字 → PTY。黏著 Ctrl 亮著時,單一字元轉成 Ctrl 組合。
  void _commitText(String text) {
    if (text.isEmpty) return;
    if (ctrlPending.value) {
      ctrlPending.value = false;
      if (text.length == 1) {
        final bytes = KeyEncoder.ctrlBytes(text);
        if (bytes != null) {
          _send(bytes);
          return;
        }
      }
    }
    _watchSpace(text);
    session.write(Uint8List.fromList(utf8.encode(text)));
  }

  /// 空白鍵被全域鍵盤 hook 吃掉的偵測(見 input_watchdog.dart)。
  /// 貼上不算數:貼進來的內容不是使用者敲的,沒有空白很正常。
  void _watchSpace(String text) {
    if (_spaceWatchdog.observe(text)) widget.onSpaceMissing?.call();
  }

  // ---- 手機工具列 ----

  void _onToolbarKey(LogicalKeyboardKey key) {
    final bytes = KeyEncoder.encode(
      key: key,
      ctrl: ctrlPending.value,
      modes: session.modes,
    );
    ctrlPending.value = false;
    if (bytes != null) _send(bytes);
  }

  void _onToolbarText(String text) => _commitText(text);

  /// 一鍵 Ctrl 組合:本身就是 Ctrl,順手把亮著的黏著 Ctrl 消掉。
  void _onToolbarCtrl(String char) {
    ctrlPending.value = false;
    final bytes = KeyEncoder.ctrlBytes(char);
    if (bytes != null) _send(bytes);
  }

  void _send(Uint8List bytes) => session.write(bytes);

  /// 讀系統剪貼簿貼進終端(bracketed paste 編碼)。
  /// 剪貼簿讀取是非同步的,回來時 widget 可能已經拆掉,所以要重查 mounted。
  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    _send(KeyEncoder.encodePaste(text, session.modes));
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;

    // 組字中:整串按鍵都屬於 IME,終端不能插手。
    //
    // 這裡「不能」回 ignored:ignored 會讓按鍵繼續往上冒泡到 MaterialApp 的
    // default shortcuts,方向鍵在那裡綁著 DirectionalFocusIntent,而
    // DirectionalFocusAction 永遠在 defaultActions 裡——注音打到一半按 ← 想回頭
    // 改前面那個音,焦點就被搬到隔壁能聚焦的東西上(分頁列按鈕、檔案側窗),
    // terminal 一失焦就 _input.detach(),整段組字蒸發。Tab 同理(NextFocusAction)。
    //
    // skipRemainingHandlers 停掉 framework 內的後續傳遞,但仍對平台回報「未處理」,
    // embedder 才會把按鍵接著交給 IME(macOS 是 NSTextInputContext)。
    if (_composing.isNotEmpty) return KeyEventResult.skipRemainingHandlers;

    final keyboard = HardwareKeyboard.instance;
    final ctrl = keyboard.isControlPressed;
    final alt = keyboard.isAltPressed;
    final shift = keyboard.isShiftPressed;
    final meta = keyboard.isMetaPressed;
    final key = event.logicalKey;

    // App 保留快捷鍵(分頁管理、字體縮放)不進 PTY,回 ignored 讓上層 Shortcuts 接手
    final reserved =
        (ctrl && shift && key == LogicalKeyboardKey.keyT) ||
        (ctrl && shift && key == LogicalKeyboardKey.keyW) ||
        (ctrl && key == LogicalKeyboardKey.tab) ||
        (ctrl &&
            (key == LogicalKeyboardKey.equal ||
                key == LogicalKeyboardKey.minus ||
                key == LogicalKeyboardKey.digit0 ||
                key == LogicalKeyboardKey.numpadAdd ||
                key == LogicalKeyboardKey.numpadSubtract));
    if (reserved) return KeyEventResult.ignored;

    // 貼上。Windows 的 Ctrl+V 交給 native 處理(text_input_provider.cpp):它用
    // OS 真實鍵態偵測 + 同步讀剪貼簿,對聽寫工具(typeless)的合成按鍵也有效,
    // 並避開 Flutter HardwareKeyboard 對合成 Ctrl 修飾鍵失準的問題。那條路只吞
    // 掉按鍵、不自己貼,免得和 native 的貼上重複。
    //
    // 其餘組合 native 都沒接(它只認 Ctrl+'V'),得自己讀剪貼簿:macOS/Linux 的
    // Ctrl+V、macOS 的 Cmd+V,以及所有平台的 Shift+Insert。
    if (KeyEncoder.isPasteShortcut(
      key: key,
      ctrl: ctrl,
      shift: shift,
      meta: meta,
    )) {
      final nativePastes =
          Platform.isWindows && ctrl && key == LogicalKeyboardKey.keyV;
      if (!nativePastes) unawaited(_pasteFromClipboard());
      return KeyEventResult.handled;
    }

    final bytes = KeyEncoder.encode(
      key: key,
      character: event.character,
      ctrl: ctrl,
      alt: alt,
      shift: shift,
      meta: meta,
      modes: session.modes,
    );

    if (bytes != null) {
      _send(bytes);
      return KeyEventResult.handled;
    }

    // 可見字元交給 IME(中英文同一條路)。
    // 保險:萬一平台沒給我們輸入連線,就直接送出,避免完全不能打字。
    if (!_input.attached) {
      final ch = event.character;
      if (ch != null && ch.isNotEmpty && ch.codeUnitAt(0) >= 0x20) {
        _watchSpace(ch);
        _send(Uint8List.fromList(utf8.encode(ch)));
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  // ---- 滑鼠反白選取(放開時自動複製,xterm 慣例)----

  CellPos _cellAt(Offset local) => CellPos(
    (local.dy / _style.cellHeight).floor().clamp(0, session.rows - 1),
    (local.dx / _style.cellWidth).floor().clamp(0, session.cols - 1),
  );

  /// 應用程式開了滑鼠回報、且沒按 Shift → 滑鼠事件送給程式(tmux/vim…),
  /// 不做本地反白。Shift 是 xterm 慣例:壓著可強制本地選取/複製。
  bool get _mouseReportingActive =>
      MouseEncoder.reportingEnabled(session.modes) &&
      !HardwareKeyboard.instance.isShiftPressed;

  int? _buttonFrom(int buttons) {
    if (buttons & kPrimaryButton != 0) return MouseButton.left;
    if (buttons & kMiddleMouseButton != 0) return MouseButton.middle;
    if (buttons & kSecondaryButton != 0) return MouseButton.right;
    return null;
  }

  void _sendMouse(int button, CellPos cell,
      {required bool press, required bool motion}) {
    final keyboard = HardwareKeyboard.instance;
    final bytes = MouseEncoder.encode(
      button: button,
      col: cell.col,
      row: cell.row,
      press: press,
      motion: motion,
      modes: session.modes,
      shift: keyboard.isShiftPressed,
      alt: keyboard.isAltPressed,
      ctrl: keyboard.isControlPressed,
    );
    if (bytes != null) _send(bytes);
  }

  // ---- 手機觸控手勢:點一下=叫鍵盤、長按拖曳=方向鍵、拖曳=捲動 ----

  static const _touchSlop = 18.0;

  bool _isTouch(PointerEvent event) =>
      _mobileUI && event.kind == PointerDeviceKind.touch;

  void _touchDown(PointerDownEvent event) {
    _summonKeyboard(); // 把使用者收起來的軟鍵盤叫回來
    _touchOrigin = _touchLast = event.localPosition;
    _joystick = null;
    _scrollTracker = null;
    _longPressTimer?.cancel();
    _longPressTimer = Timer(const Duration(milliseconds: 400), () {
      // 長按(還沒開始拖動)→ 進入方向鍵搖桿模式,震一下提示
      if (!mounted) return;
      setState(() {
        _joystick = ArrowJoystick();
        _joystickThumb = Offset.zero;
      });
      HapticFeedback.mediumImpact();
    });
  }

  void _touchMove(PointerMoveEvent event) {
    final origin = _touchOrigin;
    if (origin == null) return;
    final last = _touchLast ?? event.localPosition;
    final delta = event.localPosition - last;
    _touchLast = event.localPosition;

    final joy = _joystick;
    if (joy != null) {
      final off = event.localPosition - origin;
      // 拇指點夾在圓盤半徑內
      final dist = off.distance;
      const maxR = 40.0;
      setState(() {
        _joystickThumb = dist <= maxR ? off : off * (maxR / dist);
      });
      if (joy.update(off.dx, off.dy)) _restartArrowRepeat(joy);
      return;
    }
    if (_scrollTracker == null &&
        (event.localPosition - origin).distance > _touchSlop) {
      _longPressTimer?.cancel();
      _scrollTracker = TouchScrollTracker(lineHeight: _style.cellHeight);
    }
    final scroll = _scrollTracker;
    if (scroll != null) {
      final lines = scroll.feed(delta.dy);
      if (lines == 0) return;
      // 程式開了滑鼠回報(tmux mouse on、htop…)→ 拖曳轉滾輪事件,
      // tmux 收到 wheel-up 才會進 copy-mode 往上捲(送方向鍵只會翻 shell 歷史)
      if (MouseEncoder.reportingEnabled(session.modes)) {
        final cell = _cellAt(event.localPosition);
        // 手指往下拖(lines>0)= 看較舊的內容 = wheel up
        final button = lines > 0 ? MouseButton.wheelUp : MouseButton.wheelDown;
        for (var i = 0; i < lines.abs().clamp(1, 5); i++) {
          _sendMouse(button, cell, press: true, motion: false);
        }
        return;
      }
      if (session.modes & TermModes.altScreen != 0) {
        // vim/less 沒開滑鼠也沒有 scrollback:拖曳轉方向鍵(同滾輪慣例)
        for (var i = 0; i < lines.abs(); i++) {
          _sendArrow(lines > 0 ? 'A' : 'B');
        }
        return;
      }
      session.scroll(lines); // 正值 = 往歷史捲(內容跟著手指走)
      _refreshGrid();
    }
  }

  void _touchEnd() {
    _longPressTimer?.cancel();
    _longPressTimer = null;
    _arrowRepeat?.cancel();
    _arrowRepeat = null;
    _touchOrigin = null;
    _touchLast = null;
    _scrollTracker = null;
    if (_joystick != null && mounted) {
      setState(() => _joystick = null);
    } else {
      _joystick = null;
    }
  }

  /// 方向/速度檔改變 → 立即送一發並以對應速率連發。
  /// 慢速 150ms(≈6/s)、快速 50ms(≈20/s),Termius 手感。
  void _restartArrowRepeat(ArrowJoystick joy) {
    _arrowRepeat?.cancel();
    _arrowRepeat = null;
    final dir = joy.direction;
    if (dir == null) return;
    _sendArrow(dir);
    if (joy.fast) HapticFeedback.selectionClick();
    _arrowRepeat = Timer.periodic(
      Duration(milliseconds: joy.fast ? 50 : 150),
      (_) => _sendArrow(dir),
    );
  }

  void _sendArrow(String finalChar) {
    final appCursor = session.modes & TermModes.appCursor != 0;
    _send(
      Uint8List.fromList(
        utf8.encode(appCursor ? '\x1bO$finalChar' : '\x1b[$finalChar'),
      ),
    );
  }

  /// 開網址的修飾鍵。macOS 用 Cmd:那裡的 Ctrl+click 是系統的「當成右鍵」,
  /// 拿來開網址會跟 context menu 打架。其餘平台用 Ctrl。
  bool get _urlModifierHeld => Platform.isMacOS
      ? HardwareKeyboard.instance.isMetaPressed
      : HardwareKeyboard.instance.isControlPressed;

  /// 本地座標下的那個 cell 落在哪個網址裡;不在網址上回 null。
  UrlHit? _urlHitAt(Offset local) {
    final cells = _cells;
    if (cells == null) return null;
    final cell = _cellAt(local);
    return urlAt(cells, session.cols, session.rows, cell.row, cell.col);
  }

  void _onHover(PointerHoverEvent event) {
    _hoverPos = event.localPosition;
    _urlModifierWas = _urlModifierHeld;
    _refreshUrlHover();
  }

  /// 全域鍵盤 handler:只是偷看修飾鍵狀態,永遠回 false 不吃事件。
  ///
  /// 少了這條,虛底線與手指游標幾乎不會出現——使用者的動作順序通常是
  /// 「滑鼠停到網址上 → 按住 Cmd → 點」,按 Cmd 的那一刻沒有任何指標事件,
  /// 只靠 onHover 就得先移動滑鼠才亮得起來。
  bool _onGlobalKey(KeyEvent event) {
    if (_focusNode.hasFocus) {
      final held = _urlModifierHeld;
      if (held != _urlModifierWas) {
        _urlModifierWas = held;
        _refreshUrlHover();
      }
    }
    return false;
  }

  /// 重算指標下的網址。沒按修飾鍵就一律當作沒有(平常 hover 不掃 grid)。
  void _refreshUrlHover() {
    final pos = _hoverPos;
    final hit = (pos == null || !_urlModifierHeld) ? null : _urlHitAt(pos);
    if (hit?.url == _urlHover?.url &&
        listEquals(hit?.spans, _urlHover?.spans)) {
      return;
    }
    setState(() => _urlHover = hit);
    _repaint.value++; // painter 的 repaint listenable,底線要重畫
  }

  void _onPointerDown(PointerDownEvent event) {
    if (_isTouch(event)) {
      _touchDown(event);
      return;
    }
    _focusNode.requestFocus();
    // Cmd(macOS)/ Ctrl + 左鍵點在網址上 → 用系統瀏覽器開。要擺在滑鼠回報
    // 之前:修飾鍵點擊是終端本身的操作,不該送進 PTY(tmux/vim 會把它當一般
    // 點擊處理),行為跟 iTerm2 / Terminal.app 一致。
    if (event.buttons & kPrimaryButton != 0 && _urlModifierHeld) {
      final hit = _urlHitAt(event.localPosition);
      if (hit != null) {
        unawaited(openUrl(hit.url));
        return;
      }
    }
    if (_mouseReportingActive) {
      final button = _buttonFrom(event.buttons);
      if (button != null) {
        _clearSelection();
        final cell = _cellAt(event.localPosition);
        _mouseButton = button;
        _lastMouseCell = cell;
        _sendMouse(button, cell, press: true, motion: false);
      }
      return;
    }
    if (event.buttons & kPrimaryButton == 0) return;
    final cell = _cellAt(event.localPosition);
    _selecting = true;
    _selection = TermSelection(cell, cell);
    _repaint.value++;
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (_isTouch(event)) {
      _touchMove(event);
      return;
    }
    // 滑鼠回報中的拖曳
    if (_mouseButton != null) {
      if (!MouseEncoder.reportsMotion(session.modes, buttonHeld: true)) return;
      final cell = _cellAt(event.localPosition);
      if (cell == _lastMouseCell) return;
      _lastMouseCell = cell;
      _sendMouse(_mouseButton!, cell, press: true, motion: true);
      return;
    }
    if (!_selecting) return;
    final sel = _selection;
    if (sel == null) return;
    final cell = _cellAt(event.localPosition);
    if (cell == sel.focus) return;
    _selection = TermSelection(sel.anchor, cell);
    _repaint.value++;
  }

  void _onPointerUp(PointerUpEvent event) {
    if (_isTouch(event)) {
      _touchEnd();
      return;
    }
    // 滑鼠回報中:送放開事件
    if (_mouseButton != null) {
      final cell = _cellAt(event.localPosition);
      _sendMouse(_mouseButton!, cell, press: false, motion: false);
      _mouseButton = null;
      _lastMouseCell = null;
      return;
    }
    if (!_selecting) return;
    _selecting = false;
    final sel = _selection;
    if (sel == null) return;
    if (sel.isCollapsed) {
      // 單擊(沒拖曳):清掉選取
      _selection = null;
      _repaint.value++;
      return;
    }
    final cells = _cells;
    if (cells != null) {
      final text = extractSelectionText(
        cells,
        session.cols,
        session.rows,
        sel,
      );
      if (text.isNotEmpty) {
        // 反白完成即複製,不需要再按 Ctrl+C(那是 SIGINT)
        unawaited(Clipboard.setData(ClipboardData(text: text)));
      }
    }
    _repaint.value++;
  }

  void _clearSelection() {
    _selecting = false;
    if (_selection == null) return;
    _selection = null;
    _repaint.value++;
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;

    // Ctrl+滾輪 → 字體縮放(Windows Terminal 慣例,優先於滑鼠回報/捲動)
    if (widget.onFontZoom != null &&
        HardwareKeyboard.instance.isControlPressed) {
      if (event.scrollDelta.dy != 0) {
        widget.onFontZoom!(event.scrollDelta.dy < 0 ? 1 : -1);
      }
      return;
    }

    _wheelScroll(event.scrollDelta.dy, event.localPosition);
  }

  // macOS/Windows 觸控板兩指捲動走 pan-zoom 事件,不會進 onPointerSignal。
  void _onPanZoomStart(PointerPanZoomStartEvent event) {
    _wheelTracker = null; // 丟掉上次手勢的殘餘,避免起手就跳一行
  }

  void _onPanZoomUpdate(PointerPanZoomUpdateEvent event) {
    // panDelta 是手指移動方向(往下=正),與滾輪 scrollDelta 相反
    _wheelScroll(-event.panDelta.dy, event.localPosition);
  }

  /// 滾輪/觸控板捲動共同路徑。[dy] 同 PointerScrollEvent.scrollDelta.dy
  /// 慣例:正值 = 內容往後看(wheel down)。delta 跨事件累積,滿一行才動作。
  void _wheelScroll(double dy, Offset position) {
    var tracker = _wheelTracker;
    if (tracker == null || tracker.lineHeight != _style.cellHeight) {
      tracker = _wheelTracker = TouchScrollTracker(
        lineHeight: _style.cellHeight,
      );
    }
    final lines = tracker.feed(dy);
    if (lines == 0) return;

    // 應用程式開了滑鼠回報且沒按 Shift → 滾輪也編碼成滑鼠事件送給程式
    // (tmux mouse on 的捲動、less/htop 的滾輪都靠這個)。
    if (_mouseReportingActive) {
      final button = lines > 0 ? MouseButton.wheelDown : MouseButton.wheelUp;
      final cell = _cellAt(position);
      final count = lines.abs().clamp(1, 5);
      for (var i = 0; i < count; i++) {
        _sendMouse(button, cell, press: true, motion: false);
      }
      return;
    }

    // 捲動後畫面內容會位移,viewport 座標的選取不再對得上
    _clearSelection();
    final capped = lines.clamp(-10, 10);

    // 全螢幕程式(vim/less/htop)沒有 scrollback,滾輪應轉成方向鍵
    if (session.modes & TermModes.altScreen != 0) {
      final appCursor = session.modes & TermModes.appCursor != 0;
      final seq = capped > 0
          ? (appCursor ? '\x1bOB' : '\x1b[B')
          : (appCursor ? '\x1bOA' : '\x1b[A');
      final buf = StringBuffer();
      for (var i = 0; i < capped.abs(); i++) {
        buf.write(seq);
      }
      _send(Uint8List.fromList(utf8.encode(buf.toString())));
      return;
    }
    session.scroll(-capped); // 正值 = 往歷史捲
    _refreshGrid();
  }

  /// 依可用空間換算 cols/rows,並在下一幀套用到 native session
  /// (冷卻中則延到窗尾,見 [_resizeCooldown])。
  void _syncViewport(Size size) {
    if (_lastViewport == size) return;
    _lastViewport = size;
    // 版面位置/大小變了,IME 的 editable transform 要重送(候選字視窗定位)
    _caretGeometrySent = false;
    final cols = (size.width / _style.cellWidth).floor().clamp(20, 1000);
    final rows = (size.height / _style.cellHeight).floor().clamp(4, 500);
    _pendingGrid = (cols, rows);
    final now = _resizeNow;
    _resizeNow = false;
    if (_resizeCooldownTimer != null && !now) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _applyPendingResize());
  }

  void _applyPendingResize() {
    final grid = _pendingGrid;
    if (!mounted || grid == null) return;
    _pendingGrid = null;
    final (cols, rows) = grid;
    if (cols == session.cols && rows == session.rows) return;
    _clearSelection();
    session.resize(cols, rows);
    _refreshGrid();
    _resizeCooldownTimer?.cancel();
    _resizeCooldownTimer = Timer(_resizeCooldown, () {
      _resizeCooldownTimer = null;
      _applyPendingResize();
    });
  }

  TermFrame _frame() => TermFrame(
    cells: _cells,
    cols: session.cols,
    rows: session.rows,
    // 組字中畫的是釘住的位置(preedit 不能跟著 TUI 重繪跳);非組字時
    // _composeAnchor 是 null,就是真游標。
    cursorRow: _composeAnchor?.$1 ?? _cursor.$1,
    cursorCol: _composeAnchor?.$2 ?? _cursor.$2,
    cursorVisible: _cursor.$3 && (session.modes & TermModes.showCursor) != 0,
    composing: _composing,
    focused: _focusNode.hasFocus,
    selection: _selection,
    urlSpans: _urlHover?.spans ?? const [],
  );

  @override
  Widget build(BuildContext context) {
    final term = _buildTerminal();
    if (!_mobileUI) return term;
    final toolbar = ValueListenableBuilder<bool>(
      valueListenable: ctrlPending,
      builder: (_, ctrl, _) => KeyToolbar(
        ctrlActive: ctrl,
        onCtrlToggle: () => ctrlPending.value = !ctrlPending.value,
        onKey: _onToolbarKey,
        onText: _onToolbarText,
        onCtrl: _onToolbarCtrl,
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight;
        final gap = _usableFoldGap(height);
        // 終端固定是第一個 child、型別不變:姿勢切換時它的 element(含
        // Focus/IME 附掛)原地保留,鍵盤不會因為版面重排被收掉
        return Column(
          children: [
            SizedBox(
              height: gap?.top ?? math.max(0, height - KeyToolbar.height),
              child: term,
            ),
            if (gap != null) ...[
              SizedBox(height: gap.bottom - gap.top),
              Expanded(child: _FoldDeck(onTap: _summonKeyboard)),
            ],
            toolbar,
          ],
        );
      },
    );
  }

  /// [TerminalView.foldGap] 放得下才用:摺痕上方至少要有幾行終端、下方要
  /// 塞得下工具列(軟鍵盤比下半部還高時就放不下,退回一般版面)。
  ({double top, double bottom})? _usableFoldGap(double height) {
    final gap = widget.foldGap;
    if (gap == null) return null;
    if (gap.top < _style.cellHeight * 4) return null;
    if (height - gap.bottom < KeyToolbar.height) return null;
    return gap;
  }

  /// 取得焦點並叫出軟鍵盤(已附掛時 attach 只是 show())。
  void _summonKeyboard() {
    _focusNode.requestFocus();
    _input.attach(viewId: View.of(context).viewId);
  }

  Widget _buildTerminal() {
    return LayoutBuilder(
      builder: (context, constraints) {
        _syncViewport(constraints.biggest);
        return Focus(
          focusNode: _focusNode,
          autofocus: widget.autofocus,
          onKeyEvent: _onKeyEvent,
          child: Listener(
            onPointerSignal: _onPointerSignal,
            onPointerPanZoomStart: _onPanZoomStart,
            onPointerPanZoomUpdate: _onPanZoomUpdate,
            onPointerDown: _onPointerDown,
            onPointerMove: _onPointerMove,
            onPointerUp: _onPointerUp,
            onPointerCancel: (_) {
              _touchEnd();
              _mouseButton = null;
              _lastMouseCell = null;
              _clearSelection();
            },
            child: MouseRegion(
              onHover: _onHover,
              onExit: (_) {
                _hoverPos = null;
                _refreshUrlHover();
              },
              cursor: _urlHover != null
                  ? SystemMouseCursors.click
                  : SystemMouseCursors.text,
              child: ClipRect(
                child: Stack(
                  children: [
                    CustomPaint(
                      size: Size.infinite,
                      painter: TermPainter(
                        frame: _frame,
                        style: _style,
                        repaint: _repaint,
                        onPaintTime: widget.onPaintTime,
                      ),
                    ),
                    if (_joystick != null && _touchOrigin != null)
                      _ArrowPadOverlay(
                        origin: _touchOrigin!,
                        thumb: _joystickThumb,
                        direction: _joystick!.direction,
                        fast: _joystick!.fast,
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 長按方向鍵搖桿的視覺回饋(Termius 慣例):
/// 原點圓盤 + 跟著手指的拇指點 + 作用中方向的箭頭
/// (慢速單箭頭、快速雙箭頭並轉綠)。
class _ArrowPadOverlay extends StatelessWidget {
  const _ArrowPadOverlay({
    required this.origin,
    required this.thumb,
    required this.direction,
    required this.fast,
  });

  /// 長按原點(terminal 本地座標)。
  final Offset origin;

  /// 拇指點相對原點的位移(已夾在半徑內)。
  final Offset thumb;

  /// 作用中方向(A=上 B=下 C=右 D=左);null = 死區內。
  final String? direction;

  final bool fast;

  static const _radius = 56.0;

  static const _slowIcons = {
    'A': Icons.keyboard_arrow_up,
    'B': Icons.keyboard_arrow_down,
    'C': Icons.keyboard_arrow_right,
    'D': Icons.keyboard_arrow_left,
  };
  static const _fastIcons = {
    'A': Icons.keyboard_double_arrow_up,
    'B': Icons.keyboard_double_arrow_down,
    'C': Icons.keyboard_double_arrow_right,
    'D': Icons.keyboard_double_arrow_left,
  };
  static const _aligns = {
    'A': Alignment.topCenter,
    'B': Alignment.bottomCenter,
    'C': Alignment.centerRight,
    'D': Alignment.centerLeft,
  };

  @override
  Widget build(BuildContext context) {
    final active = direction;
    final activeColor = fast
        ? const Color(0xFF6BFF8A)
        : const Color(0xFFE0E0E0);
    return Positioned(
      left: origin.dx - _radius,
      top: origin.dy - _radius,
      width: _radius * 2,
      height: _radius * 2,
      child: IgnorePointer(
        child: Stack(
          alignment: Alignment.center,
          children: [
            // 圓盤
            Container(
              width: _radius * 2,
              height: _radius * 2,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: 0.06),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.25),
                ),
              ),
            ),
            // 四向提示(作用中方向亮起,快速檔用雙箭頭)
            for (final d in const ['A', 'B', 'C', 'D'])
              Align(
                alignment: _aligns[d]!,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(
                    d == active
                        ? (fast ? _fastIcons[d] : _slowIcons[d])
                        : _slowIcons[d],
                    size: d == active ? 26 : 18,
                    color: d == active
                        ? activeColor
                        : Colors.white.withValues(alpha: 0.35),
                  ),
                ),
              ),
            // 拇指點
            Transform.translate(
              offset: thumb,
              child: Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: active == null
                      ? Colors.white.withValues(alpha: 0.5)
                      : activeColor,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 桌上型姿勢摺痕下方的操作區:點一下叫出軟鍵盤(鍵盤本身也落在下半部)。
class _FoldDeck extends StatelessWidget {
  const _FoldDeck({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: const Key('fold-deck'),
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.keyboard_outlined, color: Colors.grey.shade700),
            const SizedBox(height: 4),
            Text(
              l10n.tapToType,
              style: TextStyle(color: Colors.grey.shade700, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
