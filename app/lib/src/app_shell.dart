// AppShell:多分頁工作區。
//
// 分頁列兩種模式(設定頁切換):上方橫向 / 側邊垂直。
// 內容用 IndexedStack 保活——切走的 tab session 照常跑、回來畫面還在。
// 快捷鍵:Ctrl+Shift+T 新分頁、Ctrl+Shift+W 關閉、Ctrl(+Shift)+Tab 切換。

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'dictation.dart';
import 'file_drag.dart';
import 'file_drop.dart';
import 'file_editor.dart';
import 'file_pane.dart';
import 'input_watchdog.dart';
import 'keys.dart';
import 'l10n.dart';
import 'prefs.dart';
import 'settings_page.dart';
import 'ssh_connect.dart';
import 'tabs.dart';
import 'term_ffi.dart';
import 'term_painter.dart';
import 'terminal_view.dart';
import 'vault_pages.dart';
import 'vault_service.dart';
import 'vscode_open.dart';

String _homeDir() {
  if (Platform.isWindows) {
    return Platform.environment['USERPROFILE'] ?? 'C:\\';
  }
  return Platform.environment['HOME'] ?? '/';
}

/// 偵測遠端 shell 目前工作目錄的 POSIX sh 腳本。經 exec channel 以
/// `sh -s` 執行、腳本走 stdin——sshd 是用「使用者的登入 shell」跑 exec
/// 命令,腳本放在命令列遇到 zsh(預設不分詞)/fish/csh 就會爛掉。
///
/// 策略:OpenSSH 同一條連線的所有 channel(我們的互動 shell、這個 exec、
/// SFTP)都是**同一個** per-connection sshd(-session) 行程的子代。所以從
/// 自己($$)沿父行程鏈往上找到本連線的 sshd,互動 shell 就是它「另一個
/// 有 tty 的子行程」(排除自己的 exec 鏈;sftp-server 沒 tty 自然被濾掉)。
/// 不需要讀環境變數(macOS 的 ps -E 對他行程有限制)、不需要 SSH_CONNECTION。
///
/// 行程資訊:有 /proc(Linux/BSD procfs)直接讀(busybox 也通);沒有
/// (macOS)用 ps,cwd 用 lsof。shell 開著 tmux client 就改問 tmux 該
/// client 作用中 pane 的 cwd(shell 本身的 cwd 停在 attach 當下)。全部
/// 落空:有 attached tmux client 就用它;再不行輸出空字串,呼叫端 fallback
/// 到 home。
const _kRemoteCwdScript = r'''
have_proc=
[ -d /proc/self ] && have_proc=1

pp_of() {
  if [ -n "$have_proc" ]; then
    read -r l 2>/dev/null < "/proc/$1/stat" || return 1
    r=${l##*) }; set -- $r
    printf %s "$2"
  else
    ps -o ppid= -p "$1" 2>/dev/null | tr -d " "
  fi
}
cm_of() {
  if [ -n "$have_proc" ]; then
    read -r c 2>/dev/null < "/proc/$1/comm" && printf %s "$c"
  else
    ps -o comm= -p "$1" 2>/dev/null
  fi
}
kids_of() {
  want=$1
  if [ -n "$have_proc" ]; then
    for st in /proc/[0-9]*/stat; do
      read -r l 2>/dev/null < "$st" || continue
      k=${st#/proc/}; k=${k%/stat}
      r=${l##*) }; set -- $r
      [ "$2" = "$want" ] && printf "%s\n" "$k"
    done
  else
    ps -ax -o pid=,ppid= 2>/dev/null | awk -v s="$want" '$2==s {print $1}'
  fi
}
tty_ok() {
  if [ -n "$have_proc" ]; then
    read -r l 2>/dev/null < "/proc/$1/stat" || return 1
    r=${l##*) }; set -- $r
    [ "$5" != 0 ]
  else
    t=$(ps -o tty= -p "$1" 2>/dev/null | tr -d " ")
    [ -n "$t" ] && [ "$t" != "??" ] && [ "$t" != "?" ]
  fi
}

# 沿自己($$)往上找本連線的 sshd;a = 我們 exec 鏈在 sshd 底下的直接子代
p=$$; a=; s=; i=0
while [ "$i" -lt 10 ]; do
  pp=$(pp_of "$p") || break
  [ -n "$pp" ] && [ "$pp" != 0 ] && [ "$pp" != 1 ] || break
  case "$(cm_of "$pp")" in *sshd*) s=$pp; a=$p; break ;; esac
  p=$pp; i=$((i+1))
done

# 互動 shell = 同一個 sshd 的另一個「有 tty」子行程
# (排除自己的 exec 鏈;sftp-server 沒 tty 自然被濾掉)
sh_pid=
if [ -n "$s" ]; then
  for c in $(kids_of "$s"); do
    [ "$c" = "$a" ] && continue
    if tty_ok "$c"; then sh_pid=$c; break; fi
  done
fi

# shell 是 tmux client、或開著 tmux client 子行程 → 問 tmux 作用中 pane
tc=
if [ -n "$sh_pid" ]; then
  case "$(cm_of "$sh_pid")" in *tmux*) tc=$sh_pid ;; esac
  if [ -z "$tc" ]; then
    for c in $(kids_of "$sh_pid"); do
      case "$(cm_of "$c")" in *tmux*) tc=$c; break ;; esac
    done
  fi
fi
d=
if [ -n "$tc" ] && command -v tmux >/dev/null 2>&1; then
  ct=$(tmux list-clients -F "#{client_pid} #{client_tty}" 2>/dev/null | awk -v p="$tc" '$1==p{print $2; exit}')
  [ -n "$ct" ] && d=$(tmux display-message -p -c "$ct" -F "#{pane_current_path}" 2>/dev/null)
fi
# 不在 tmux → 直接讀 shell 的 cwd(/proc 或 lsof)
if [ -z "$d" ] && [ -n "$sh_pid" ]; then
  if [ -n "$have_proc" ]; then
    d=$(readlink "/proc/$sh_pid/cwd" 2>/dev/null)
  elif command -v lsof >/dev/null 2>&1; then
    d=$(lsof -a -p "$sh_pid" -d cwd -Fn 2>/dev/null | sed -n "s/^n//p" | head -n 1)
  fi
fi
# 全部落空:有 attached tmux client 就用它
if [ -z "$d" ] && command -v tmux >/dev/null 2>&1; then
  s2=$(tmux list-clients -F "#{session_name}" 2>/dev/null | head -n 1)
  [ -n "$s2" ] && d=$(tmux display-message -p -t "$s2" -F "#{pane_current_path}" 2>/dev/null)
fi
[ -n "$d" ] && [ -d "$d" ] && printf %s "$d"
''';

class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.tabs,
    required this.prefs,
    required this.vault,
    this.vaultError,
    this.filePaneDir,
  });

  final TabsController tabs;
  final AppPrefs prefs;
  final VaultService? vault;
  final String? vaultError;

  /// 檔案側窗初始目錄(測試用;預設 home)。
  final String? filePaneDir;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  final _viewKeys = <int, GlobalKey<TerminalViewState>>{};

  /// 終端 style 跟著 prefs 的字體大小走;同大小重用同一個實例
  /// (TerminalView 用 identical 判斷要不要重算 cols/rows)。
  TerminalStyle? _styleCache;
  TerminalStyle get _style {
    final size = widget.prefs.termFontSize;
    var s = _styleCache;
    if (s == null || s.fontSize != size) {
      s = _styleCache = TerminalStyle(fontSize: size);
    }
    return s;
  }

  void _zoomFont(int steps) =>
      widget.prefs.termFontSize = widget.prefs.termFontSize + steps;

  /// 作用中分頁的終端是否持有鍵盤焦點。
  bool get _terminalFocused {
    final tab = widget.tabs.active;
    return tab != null && (_viewKeys[tab.id]?.currentState?.hasFocus ?? false);
  }
  late final FilePaneController _filePane =
      FilePaneController(widget.filePaneDir ?? _homeDir());

  /// 檔案側窗的外框,拖檔進來時用來判斷有沒有落在側窗上。
  final GlobalKey _filePaneKey = GlobalKey();

  /// 檔案側窗目前顯示的遠端 session(null = 本地)。
  NativeSession? _filePaneSession;

  /// 已經看過的 session(identity),用來分辨「新連上的」與「只是切分頁」。
  final Set<NativeSession> _seenSessions = {};

  /// 編輯器 pane 目前開的檔案(null = 沒開)與其遠端 session(null = 本地)。
  final _editorKey = GlobalKey<FileEditorPaneState>();
  String? _editorPath;
  NativeSession? _editorRemote;

  @override
  void initState() {
    super.initState();
    widget.tabs.ensureInitial();
    // 聽寫/口語轉文字 → 目前作用中終端。insert=UIA 直接插字;paste=聽寫工具
    // 按 Ctrl+V(native 已同步讀好剪貼簿),這裡做 bracketed-paste 編碼再送。
    // native 是在整個視窗層攔 Ctrl+V,不知道 Flutter 內部焦點在哪——焦點在
    // 設定頁/編輯器的文字框時,貼上屬於那個文字框,這裡必須丟棄不進 PTY。
    Dictation.listen(
      onInsert: (bytes) {
        if (!_terminalFocused) return;
        widget.tabs.active?.session?.write(bytes);
      },
      onPaste: (text) {
        if (!_terminalFocused) return;
        final s = widget.tabs.active?.session;
        if (s != null) s.write(KeyEncoder.encodePaste(text, s.modes));
      },
    );
    // 從系統檔案管理員拖檔案進來 → 落在檔案側窗上就複製/上傳到目前資料夾
    FileDrop.listen(_onFilesDropped);
    // SSH 新連上 / 分頁關掉時調整檔案側窗來源(單純切分頁不動側窗,見 _onTabsChanged)。
    // 開場就存在的 session 先記起來,不然第一次 notify 會被當成「新連上」。
    for (final t in widget.tabs.tabs) {
      if (t.session != null) _seenSessions.add(t.session!);
    }
    widget.tabs.addListener(_onTabsChanged);
    _modeTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _syncActiveModes(),
    );
  }

  @override
  void dispose() {
    widget.tabs.removeListener(_onTabsChanged);
    _modeTimer?.cancel();
    Dictation.stop();
    FileDrop.stop();
    _filePane.dispose();
    super.dispose();
  }

  /// 作用中分頁的終端模式(狀態列用)。滑鼠回報 / alt screen 這些模式是程式
  /// 送序列改的,沒有任何 Listenable 會通知我們,只能自己輪詢。
  int _activeModes = 0;
  Timer? _modeTimer;

  void _syncActiveModes() {
    final modes = widget.tabs.active?.session?.modes ?? 0;
    if (modes == _activeModes || !mounted) return;
    setState(() => _activeModes = modes);
  }

  void _toggleFilePane() {
    widget.prefs.filePaneVisible = !widget.prefs.filePaneVisible;
    if (widget.prefs.filePaneVisible) _syncFilePaneSource();
  }

  /// 偵測遠端 shell 目前的工作目錄(含 tmux 內的 pane);抓不到回 null。
  String? _detectRemoteCwd(NativeSession session) {
    try {
      final out = session.sshExec('sh -s', stdin: _kRemoteCwdScript).trim();
      // 只認絕對 POSIX 路徑,擋掉 Windows sshd 之類跑出來的雜訊
      if (out.isEmpty || !out.startsWith('/') || out.contains('\n')) return null;
      return out;
    } catch (_) {
      return null;
    }
  }

  /// 本地分頁目前的工作目錄:先用 OSC 7(預設的 Windows PowerShell 由 prompt
  /// hook 送);沒送的 shell(cmd.exe 等)退而直接讀 shell 子行程的 cwd。
  String? _localCwd(NativeSession session) {
    if (session.isSsh) return null;
    final d = session.currentDirectory ?? session.localDirectory;
    return d != null && Directory(d).existsSync() ? d : null;
  }

  String _sftpHomeOf(NativeSession session) {
    try {
      return session.sftpHome();
    } catch (_) {
      return '/';
    }
  }

  /// 側窗「跳至終端目前目錄」按鈕:把側窗同步到作用中分頁——需要的話先換來源
  /// (本地 ↔ 遠端),再跳到該分頁的 cwd。遠端走 exec 偵測(含 tmux);本地用
  /// OSC 7 / 讀子行程。不受「跟隨」開關影響。
  ///
  /// 切分頁不會自動做這件事(列目錄都是同步呼叫,遠端還是一個網路來回,放在
  /// 切換路徑上會直接卡住 UI),所以這顆按鈕就是「要跟上目前分頁」的入口。
  void _jumpToCwd() {
    final session = widget.tabs.active?.session;
    if (session == null) return;
    final remote = session.isSsh;
    final cwd = remote ? _detectRemoteCwd(session) : _localCwd(session);
    final sameSource =
        remote ? identical(session, _filePaneSession) : !_filePane.isRemote;
    if (!sameSource) {
      // 換來源時抓不到 cwd 就退回該分頁的家目錄,至少換到對的機器上
      _filePaneSession = remote ? session : null;
      _filePane.setSource(
        remote ? RemoteFileSource(session) : LocalFileSource(),
        cwd ?? (remote ? _sftpHomeOf(session) : _homeDir()),
      );
    } else if (cwd != null) {
      _filePane.navigateTo(cwd);
    }
    if (cwd == null) _snack(l10n.cwdNotFound);
  }

  /// 右鍵選單「用 VS Code 開啟」:本地路徑直接開;遠端(SSH)走 VS Code
  /// Remote-SSH 的 vscode-remote:// URI(權威取自該分頁的 connInfo)。
  Future<void> _openInVscode(FileEntry e) async {
    List<String> args;
    if (_filePane.isRemote) {
      final tab = widget.tabs.tabs
          .where((t) => identical(t.session, _filePaneSession))
          .firstOrNull;
      final authority = tab?.connInfo ?? '';
      if (authority.isEmpty) {
        _snack(l10n.vscodeNoRemoteInfo);
        return;
      }
      args = vscodeRemoteArgs(authority, e.path, isDir: e.isDir);
    } else {
      args = vscodeLocalArgs(e.path);
    }
    try {
      await launchVscode(args);
    } catch (_) {
      _snack(l10n.vscodeNotFound);
    }
  }

  /// 分頁列變動時的檔案側窗維護。**單純切分頁不重載側窗**:sftpHome /
  /// sftpList / listSync 全是同步呼叫(遠端還是一個網路來回),掛在切換路徑上
  /// 就是每切一次分頁卡一次。側窗停在原本的目錄,要跟上分頁請按「跳至終端
  /// 目前目錄」。這裡只做兩件不花在切換上的事:
  /// 1. 側窗指著的 session 沒了(關分頁 / 重新連線)→ 收回本地,免得之後
  ///    SFTP 打到已經 free 掉的 handle;
  /// 2. 有「新連上」的 SSH session 且它就是作用中分頁 → 側窗跟過去(使用者
  ///    剛開的連線,本來就在等網路,不是切分頁)。
  void _onTabsChanged() {
    final live = {
      for (final t in widget.tabs.tabs)
        if (t.session != null) t.session!,
    };
    final fresh = live.difference(_seenSessions);
    _seenSessions
      ..clear()
      ..addAll(live);

    final shown = _filePaneSession;
    if (shown != null && !live.contains(shown)) {
      _filePaneSession = null;
      _filePane.setSource(LocalFileSource(), _homeDir());
      return;
    }
    final active = widget.tabs.active?.session;
    if (active != null && fresh.contains(active)) _syncFilePaneSource();
  }

  /// 把檔案側窗切到作用中分頁的來源:SSH 分頁 → 遠端 SFTP(根目錄=遠端
  /// home);本地分頁 → 本地檔案系統。已在對的來源就不動作。遠端 cwd 偵測
  /// (exec)不在這裡跑,只在使用者按「跳至終端目前目錄」時(_jumpToCwd)。
  void _syncFilePaneSource() {
    if (!widget.prefs.filePaneVisible) return;
    final session = widget.tabs.active?.session;
    if (session != null && session.isSsh) {
      if (_filePaneSession == session) return;
      _filePaneSession = session;
      _filePane.setSource(RemoteFileSource(session), _sftpHomeOf(session));
    } else if (_filePane.isRemote) {
      _filePaneSession = null;
      _filePane.setSource(LocalFileSource(), _homeDir());
    }
  }

  /// 在右側編輯器 pane 開檔(取代目前檔案;dirty 先確認)。
  Future<void> _openFile(String path) async {
    final remote = _filePane.isRemote ? _filePaneSession : null;
    if (_editorPath == path && identical(_editorRemote, remote)) return;
    if (!await _confirmDiscardEdits() || !mounted) return;
    setState(() {
      _editorPath = path;
      _editorRemote = remote;
    });
  }

  /// 換檔/關閉前確認:沒開檔或沒未存檔修改 → true;dirty → 問使用者。
  Future<bool> _confirmDiscardEdits() async {
    final editor = _editorKey.currentState;
    if (editor == null || !editor.isDirty) return true;
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.discardEditsTitle),
        content: Text(l10n.discardEditsBody(fileBaseName(_editorPath!))),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            key: const Key('btn-discard-edits'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.discard),
          ),
        ],
      ),
    );
    return discard == true;
  }

  Future<void> _closeEditor() async {
    if (!await _confirmDiscardEdits() || !mounted) return;
    setState(() {
      _editorPath = null;
      _editorRemote = null;
    });
    _focusActive();
  }

  /// 把檔案側窗的檔案拖到系統檔案管理員(Windows 檔案總管 / macOS Finder)。
  /// 本地檔直接交給 native 拖;遠端(SFTP)檔沒有本地路徑,先把內容抓下來寫到
  /// 暫存檔再拖。太大的遠端檔擋掉,免得同步讀檔卡住 UI(可改用編輯器開啟另存)。
  /// 正在把檔案拖出去(native modal 拖放迴圈進行中)。期間收到的 drop
  /// 是自己拖的檔案又落回自己視窗——不是匯入,要忽略,否則會在目前
  /// 資料夾重複複製一份。
  bool _dragOutActive = false;

  void _dragFileOut(String path) {
    if (!_filePane.isRemote) {
      _dragOutActive = true;
      unawaited(
        FileDrag.start(path).whenComplete(() => _dragOutActive = false),
      );
      return;
    }
    final session = _filePaneSession;
    if (session == null) return;
    const maxRemoteDrag = 32 * 1024 * 1024;
    FileEntry? entry;
    for (final e in _filePane.entries) {
      if (e.path == path) {
        entry = e;
        break;
      }
    }
    if (entry != null && entry.size > maxRemoteDrag) {
      _snack(l10n.dragOutTooLarge);
      return;
    }
    try {
      final bytes = session.sftpRead(path);
      _dragOutActive = true;
      unawaited(
        FileDrag.startTempCopy(fileBaseName(path), bytes)
            .whenComplete(() => _dragOutActive = false),
      );
    } catch (e) {
      _snack(l10n.readRemoteFileFailed('$e'));
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 從系統檔案管理員放檔進來。native 給的是 view client 的 physical px,先換成
  /// logical、hit-test 檔案側窗;有落在側窗上才收(丟到終端機不處理)。
  void _onFilesDropped(List<String> paths, Offset physicalPos) {
    if (_dragOutActive) return; // 自己拖出的檔案落回自己視窗:不是匯入
    if (!widget.prefs.filePaneVisible || paths.isEmpty) return;
    final box = _filePaneKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final logical = physicalPos / dpr;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    if (!rect.contains(logical)) return; // 不是拖到側窗
    _importFiles(paths);
  }

  /// 把拖進來的本地檔案放到側窗目前的資料夾:本地複製,遠端走 SFTP 上傳。
  void _importFiles(List<String> paths) {
    final dir = _filePane.path;
    final remote = _filePane.isRemote ? _filePaneSession : null;
    final result = importDroppedFiles(
      paths,
      remote: remote != null,
      place: (name, f) {
        if (remote != null) {
          remote.sftpWrite(_remoteJoin(dir, name), f.readAsBytesSync());
        } else {
          f.copySync(_localJoin(dir, name));
        }
      },
    );
    _filePane.refresh();
    if (result.done == 0 && result.skipped.isEmpty) return;
    final skipped = result.skipped.join(', ');
    _snack(switch ((remote != null, result.skipped.isEmpty)) {
      (true, true) => l10n.filesUploaded(result.done, dir),
      (false, true) => l10n.filesCopied(result.done, dir),
      (true, false) => l10n.filesUploadedPartly(result.done, skipped),
      (false, false) => l10n.filesCopiedPartly(result.done, skipped),
    });
  }

  String _localJoin(String dir, String name) {
    final sep = Platform.pathSeparator;
    return dir.endsWith(sep) ? '$dir$name' : '$dir$sep$name';
  }

  String _remoteJoin(String dir, String name) =>
      dir.endsWith('/') ? '$dir$name' : '$dir/$name';

  /// 只跟隨「目前作用中分頁」的 cwd(其他分頁的 tick 忽略;遠端不跟 OSC7)。
  void _onCwd(int tabId, String? cwd) {
    if (widget.tabs.active?.id == tabId) _filePane.onCwdChanged(cwd);
  }

  void _focusActive() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final tab = widget.tabs.active;
      if (tab != null) _viewKeys[tab.id]?.currentState?.requestFocus();
    });
  }

  void _newTab() {
    widget.tabs.newTab();
    _focusActive();
  }

  Future<void> _closeTab(int id) async {
    if (!await _releaseEditorFor(id)) return;
    _viewKeys.remove(id);
    widget.tabs.closeTab(id);
    _focusActive();
  }

  /// 分頁的 session 即將被 dispose(關閉/重新連線)前,先放掉編輯器對它的
  /// 引用(不放的話之後 SFTP 讀寫會炸)。dirty 時先確認;回傳 false = 使用者
  /// 取消,呼叫端要中止動作。
  Future<bool> _releaseEditorFor(int id) async {
    if (_editorRemote == null) return true;
    final tab = widget.tabs.tabs.where((t) => t.id == id).firstOrNull;
    if (tab == null || !identical(tab.session, _editorRemote)) return true;
    if (!await _confirmDiscardEdits() || !mounted) return false;
    setState(() {
      _editorPath = null;
      _editorRemote = null;
    });
    return true;
  }

  /// 重新連線:已結束/失敗的分頁直接重連;還活著的(例如手動想重開的 SSH
  /// 分頁)先確認,免得誤觸把正在跑的連線砍掉。
  Future<void> _reconnectTab(int id) async {
    final tab = widget.tabs.tabs.where((t) => t.id == id).firstOrNull;
    if (tab == null || tab.connecting || tab.connectFn == null) return;
    final live = tab.session != null && !tab.exited && tab.error == null;
    if (live) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(l10n.reconnectTitle),
          content: Text(l10n.reconnectBody(tab.displayTitle)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(l10n.cancel),
            ),
            TextButton(
              key: const Key('btn-confirm-reconnect'),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(l10n.reconnect),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    if (!await _releaseEditorFor(id)) return;
    widget.tabs.reconnect(id);
    _focusActive();
  }

  /// 分頁拖移排序。
  ///
  /// ReorderableListView 的 newIndex 是「還沒把拖曳項移走」時的落點,而
  /// TabsController.reorder 是先 removeAt 再 insert(收到的是移除後的索引)。
  /// 往後拖時兩者差一格,不補正會多跳一個位置。
  void _reorderTabs(int oldIndex, int newIndex) {
    widget.tabs.reorder(oldIndex, oldIndex < newIndex ? newIndex - 1 : newIndex);
  }

  void _activate(int index) {
    widget.tabs.activate(index);
    _focusActive();
  }

  void _openVaults() {
    final vault = widget.vault;
    if (vault == null) {
      _showVaultError();
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => VaultsPage(
          service: vault,
          onConnectHost: (host) {
            Navigator.of(context).pop(); // 關掉 Vaults 頁,回到分頁工作區
            _connectSshHost(host);
          },
        ),
      ),
    );
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsPage(
          service: widget.vault,
          prefs: widget.prefs,
          vaultError: widget.vaultError,
        ),
      ),
    );
  }

  void _showVaultError() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          l10n.vaultOpenFailed(widget.vaultError ?? l10n.unknownError),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyT, control: true, shift: true):
            _newTab,
        const SingleActivator(LogicalKeyboardKey.keyW, control: true, shift: true):
            () {
          final tab = widget.tabs.active;
          if (tab != null) _closeTab(tab.id);
        },
        const SingleActivator(LogicalKeyboardKey.tab, control: true): () {
          widget.tabs.next();
          _focusActive();
        },
        const SingleActivator(LogicalKeyboardKey.tab, control: true, shift: true):
            () {
          widget.tabs.prev();
          _focusActive();
        },
        // 字體縮放:Ctrl +/-/0(= 鍵含 Shift 變 + 也收)、numpad 亦可
        const SingleActivator(LogicalKeyboardKey.equal, control: true): () =>
            _zoomFont(1),
        const SingleActivator(LogicalKeyboardKey.equal,
            control: true, shift: true): () => _zoomFont(1),
        const SingleActivator(LogicalKeyboardKey.numpadAdd, control: true):
            () => _zoomFont(1),
        const SingleActivator(LogicalKeyboardKey.minus, control: true): () =>
            _zoomFont(-1),
        const SingleActivator(LogicalKeyboardKey.numpadSubtract, control: true):
            () => _zoomFont(-1),
        const SingleActivator(LogicalKeyboardKey.digit0, control: true): () =>
            widget.prefs.termFontSize = kTermFontDefaultSize,
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF181818),
        // iOS 的 status bar / 瀏海 / home indicator 不能壓到內容;
        // 桌面平台沒有 inset,SafeArea 是 no-op。
        body: SafeArea(
          child: ListenableBuilder(
          listenable: Listenable.merge([widget.tabs, widget.prefs]),
          builder: (context, _) {
            final side = widget.prefs.tabBarPosition == TabBarPosition.side;
            final mainArea = Expanded(child: _buildMainArea());
            if (side) {
              return Row(children: [
                SizedBox(
                  width: widget.prefs.sideTabWidth,
                  child: _SideTabStrip(
                    tabs: widget.tabs,
                    onActivate: _activate,
                    onClose: _closeTab,
                    onReconnect: _reconnectTab,
                    onReorder: _reorderTabs,
                    onNewTab: _newTab,
                    onVaults: _openVaults,
                    onSettings: _openSettings,
                    onToggleFiles: _toggleFilePane,
                    filesVisible: widget.prefs.filePaneVisible,
                  ),
                ),
                _ResizeHandle(
                  key: const Key('side-resize-handle'),
                  onDelta: (dx) =>
                      widget.prefs.sideTabWidth = widget.prefs.sideTabWidth + dx,
                ),
                mainArea,
              ]);
            }
            return Column(children: [
              _TopTabStrip(
                tabs: widget.tabs,
                onActivate: _activate,
                onClose: _closeTab,
                onReconnect: _reconnectTab,
                onReorder: _reorderTabs,
                onNewTab: _newTab,
                onVaults: _openVaults,
                onSettings: _openSettings,
                onToggleFiles: _toggleFilePane,
                filesVisible: widget.prefs.filePaneVisible,
              ),
              mainArea,
            ]);
            },
          ),
        ),
      ),
    );
  }

  /// 終端內容 +(可選)檔案側窗 +(可選)編輯器 pane,編輯器永遠在最右。
  Widget _buildMainArea() {
    final children = <Widget>[Expanded(child: _buildContent())];
    if (widget.prefs.filePaneVisible) {
      children.add(_ResizeHandle(
        key: const Key('file-resize-handle'),
        onDelta: (dx) =>
            widget.prefs.filePaneWidth = widget.prefs.filePaneWidth - dx,
      ));
      children.add(SizedBox(
        key: _filePaneKey,
        width: widget.prefs.filePaneWidth,
        child: FilePane(
          controller: _filePane,
          onOpenFile: _openFile,
          onDragFileOut: FileDrag.supported ? _dragFileOut : null,
          onJumpToCwd: _jumpToCwd,
          onOpenInVscode: vscodeSupported ? _openInVscode : null,
        ),
      ));
    }
    if (_editorPath != null) {
      children.add(_ResizeHandle(
        key: const Key('editor-resize-handle'),
        onDelta: (dx) =>
            widget.prefs.editorPaneWidth = widget.prefs.editorPaneWidth - dx,
      ));
      children.add(SizedBox(
        key: const Key('editor-pane'),
        width: widget.prefs.editorPaneWidth,
        child: FileEditorPane(
          key: _editorKey,
          path: _editorPath!,
          remote: _editorRemote,
          onClose: _closeEditor,
        ),
      ));
    }
    return Row(children: children);
  }

  Widget _buildContent() {
    final tabs = widget.tabs.tabs;
    return Column(children: [
      Expanded(
        child: IndexedStack(
          index: widget.tabs.activeIndex,
          children: [for (final tab in tabs) _tabContent(tab)],
        ),
      ),
      _connStatusBar(),
    ]);
  }

  /// 終端下方的連線狀態列:目前分頁連到哪台(SSH:名稱 + user@host:port;
  /// 本地:本機終端機)與狀態(連線中/已結束)。
  Widget _connStatusBar() {
    final tab = widget.tabs.active;
    if (tab == null) return const SizedBox.shrink();
    final ssh = tab.connInfo.isNotEmpty;
    final String text;
    if (ssh) {
      final name = tab.label.isNotEmpty ? '${tab.label}  ·  ' : '';
      text = '$name${tab.connInfo}';
    } else if (tab.noLocalShell) {
      text = l10n.noLocalShell;
    } else {
      text = l10n.localTerminal;
    }
    final (Color stateColor, String? stateText) = tab.connecting
        ? (const Color(0xFFE0B24A), l10n.connecting)
        : tab.error != null
            ? (const Color(0xFFE57373), l10n.connectionFailed)
            : tab.exited
                ? (const Color(0xFFE57373), l10n.ended)
                : (const Color(0xFF6CBF6C), null);
    return Container(
      key: const Key('conn-status-bar'),
      height: 22,
      color: const Color(0xFF111111),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(children: [
        Icon(
          ssh ? Icons.cloud_outlined : Icons.computer_outlined,
          size: 13,
          color: stateColor,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11.5, color: Color(0xFFB8B8B8)),
          ),
        ),
        if (stateText != null)
          Text(
            stateText,
            style: TextStyle(fontSize: 11.5, color: stateColor),
          ),
        // 滾輪沒反應時,狀態列要講得出原因、也要給得出解法(見 _activeModes)
        if (_activeModes & TermModes.wheelBlocking != 0) ...[
          const SizedBox(width: 8),
          Tooltip(
            message: l10n.wheelCapturedTooltip,
            child: Text(
              l10n.wheelCaptured,
              style: const TextStyle(fontSize: 11.5, color: Color(0xFFE0B24A)),
            ),
          ),
          const SizedBox(width: 4),
          TextButton(
            key: const Key('btn-reset-modes'),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: () {
              tab.session?.resetModes();
              _syncActiveModes();
              _focusActive();
            },
            child: Text(
              l10n.resetTerminal,
              style: const TextStyle(fontSize: 11.5),
            ),
          ),
        ],
        // SSH 分頁即使還連著也給重連入口(斷線重上、換 session);本地分頁
        // 只在結束/失敗時出現,不然按了只是白白換掉正在跑的 shell。
        if (!tab.connecting &&
            (tab.exited || tab.error != null || ssh) &&
            tab.connectFn != null) ...[
          const SizedBox(width: 8),
          TextButton(
            key: const Key('btn-reconnect'),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: () => _reconnectTab(tab.id),
            child: Text(
              l10n.reconnect,
              style: const TextStyle(fontSize: 11.5),
            ),
          ),
        ],
      ]),
    );
  }

  Widget _tabContent(TermTab tab) {
    if (tab.connecting) {
      return Center(
        key: ValueKey('tab-connecting-${tab.id}'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(height: 16),
            Text(
              tab.label.isEmpty
                  ? l10n.restartingTerminal
                  : l10n.connectingTo(tab.label),
              style: const TextStyle(color: Color(0xFFB0B0B0)),
            ),
          ],
        ),
      );
    }
    if (tab.noLocalShell) {
      return Center(
        key: ValueKey('tab-nolocal-${tab.id}'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              l10n.localShellUnavailable,
              style: const TextStyle(color: Color(0xFFB0B0B0)),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _openVaults,
              icon: const Icon(Icons.dns),
              label: Text(l10n.openVaultsForSsh),
            ),
          ],
        ),
      );
    }
    if (tab.session == null) {
      return Center(
        key: ValueKey('tab-error-${tab.id}'),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                l10n.terminalStartFailed('${tab.error}'),
                style: const TextStyle(
                  fontFamily: 'monospace',
                  color: Color(0xFFFF6B6B),
                ),
              ),
              if (tab.connectFn != null) ...[
                const SizedBox(height: 16),
                FilledButton.icon(
                  key: ValueKey('btn-reconnect-${tab.id}'),
                  onPressed: () {
                    widget.tabs.reconnect(tab.id);
                    _focusActive();
                  },
                  icon: const Icon(Icons.refresh),
                  label: Text(l10n.reconnect),
                ),
              ],
            ],
          ),
        ),
      );
    }
    return Padding(
      key: ValueKey('tab-view-${tab.id}'),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: TerminalView(
        key: _viewKeys.putIfAbsent(
          tab.id,
          () => GlobalKey<TerminalViewState>(),
        ),
        session: tab.session!,
        style: _style,
        autofocus: tab.id == widget.tabs.active?.id,
        onTitleChanged: (t) => widget.tabs.setTitle(tab.id, t),
        onExit: () => widget.tabs.markExited(tab.id),
        onCwdChanged: (cwd) => _onCwd(tab.id, cwd),
        onFontZoom: _zoomFont,
        onSpaceMissing: _warnKeyHook,
      ),
    );
  }

  /// 空白鍵被系統層的全域鍵盤 hook 吃掉時的提示(見 input_watchdog.dart)。
  ///
  /// 這種狀況終端自己救不了——被 hook 壓掉的按鍵在使用者模式完全不存在,
  /// 連 Raw Input 都收不到。能做的就是別讓使用者以為是終端壞了。
  Future<void> _warnKeyHook() async {
    final tool = await detectSuspectInputTool();
    if (!mounted) return;
    final who = tool == null ? l10n.keyHookUnknownTool : l10n.keyHookTool(tool);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 20),
        content: Text(l10n.keyHookWarning(who)),
        action: SnackBarAction(label: l10n.gotIt, onPressed: () {}),
      ),
    );
  }

  /// 從 vault host 開一個 SSH 分頁(邏輯與手機版共用,見 ssh_connect.dart)。
  void _connectSshHost(VaultRecord host) {
    connectSshHostTab(
      tabs: widget.tabs,
      vault: widget.vault,
      host: host,
      onError: (message) => ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message))),
    );
    _focusActive();
  }
}

// ---- 上方橫向分頁列 ----

class _TopTabStrip extends StatelessWidget {
  const _TopTabStrip({
    required this.tabs,
    required this.onActivate,
    required this.onClose,
    required this.onReconnect,
    required this.onReorder,
    required this.onNewTab,
    required this.onVaults,
    required this.onSettings,
    required this.onToggleFiles,
    required this.filesVisible,
  });

  final TabsController tabs;
  final void Function(int index) onActivate;
  final void Function(int id) onClose;
  final void Function(int id) onReconnect;
  final void Function(int oldIndex, int newIndex) onReorder;
  final VoidCallback onNewTab;
  final VoidCallback onVaults;
  final VoidCallback onSettings;
  final VoidCallback onToggleFiles;
  final bool filesVisible;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('tab-strip-top'),
      height: 36,
      color: const Color(0xFF101010),
      child: Row(children: [
        Expanded(
          child: ReorderableListView(
            key: const Key('tab-list-top'),
            scrollDirection: Axis.horizontal,
            buildDefaultDragHandles: false,
            onReorder: onReorder,
            proxyDecorator: _dragProxy,
            children: [
              for (var i = 0; i < tabs.tabs.length; i++)
                ReorderableDragStartListener(
                  key: ValueKey('tab-slot-${tabs.tabs[i].id}'),
                  index: i,
                  child: _TabChip(
                    tab: tabs.tabs[i],
                    active: i == tabs.activeIndex,
                    onTap: () => onActivate(i),
                    onClose: () => onClose(tabs.tabs[i].id),
                    onReconnect: () => onReconnect(tabs.tabs[i].id),
                    width: 168,
                  ),
                ),
            ],
          ),
        ),
        IconButton(
          key: const Key('btn-new-tab'),
          tooltip: l10n.newTabTooltip,
          icon: const Icon(Icons.add, size: 18),
          onPressed: onNewTab,
        ),
        _FilesToggleButton(visible: filesVisible, onPressed: onToggleFiles),
        IconButton(
          key: const Key('btn-vaults'),
          tooltip: l10n.vaultsTooltip,
          icon: const Icon(Icons.dns_outlined, size: 18),
          onPressed: onVaults,
        ),
        IconButton(
          key: const Key('btn-settings'),
          tooltip: l10n.settings,
          icon: const Icon(Icons.settings_outlined, size: 18),
          onPressed: onSettings,
        ),
        const SizedBox(width: 4),
      ]),
    );
  }
}

/// 檔案側窗開關(高亮表示開啟)。
class _FilesToggleButton extends StatelessWidget {
  const _FilesToggleButton({required this.visible, required this.onPressed});

  final bool visible;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      key: const Key('btn-toggle-files'),
      tooltip: l10n.filesPanelTooltip,
      icon: Icon(
        Icons.folder_open_outlined,
        size: 18,
        color: visible ? const Color(0xFF4A90D9) : null,
      ),
      onPressed: onPressed,
    );
  }
}

// ---- 側邊垂直分頁列 ----

/// 拖拉握把:拖動調整相鄰面板寬度(側邊分頁列、檔案側窗共用)。
class _ResizeHandle extends StatefulWidget {
  const _ResizeHandle({super.key, required this.onDelta});

  final void Function(double dx) onDelta;

  @override
  State<_ResizeHandle> createState() => _ResizeHandleState();
}

class _ResizeHandleState extends State<_ResizeHandle> {
  bool _hovering = false;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final active = _hovering || _dragging;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragStart: (_) => setState(() => _dragging = true),
        onHorizontalDragUpdate: (d) => widget.onDelta(d.delta.dx),
        onHorizontalDragEnd: (_) => setState(() => _dragging = false),
        child: SizedBox(
          width: 6,
          child: Center(
            child: Container(
              width: active ? 2 : 1,
              color: active ? const Color(0xFF4A90D9) : const Color(0xFF2A2A2A),
            ),
          ),
        ),
      ),
    );
  }
}

class _SideTabStrip extends StatelessWidget {
  const _SideTabStrip({
    required this.tabs,
    required this.onActivate,
    required this.onClose,
    required this.onReconnect,
    required this.onReorder,
    required this.onNewTab,
    required this.onVaults,
    required this.onSettings,
    required this.onToggleFiles,
    required this.filesVisible,
  });

  final TabsController tabs;
  final void Function(int index) onActivate;
  final void Function(int id) onClose;
  final void Function(int id) onReconnect;
  final void Function(int oldIndex, int newIndex) onReorder;
  final VoidCallback onNewTab;
  final VoidCallback onVaults;
  final VoidCallback onSettings;
  final VoidCallback onToggleFiles;
  final bool filesVisible;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('tab-strip-side'),
      color: const Color(0xFF101010),
      child: Column(children: [
        Expanded(
          child: ReorderableListView(
            key: const Key('tab-list-side'),
            buildDefaultDragHandles: false,
            onReorder: onReorder,
            proxyDecorator: _dragProxy,
            children: [
              for (var i = 0; i < tabs.tabs.length; i++)
                ReorderableDragStartListener(
                  key: ValueKey('tab-slot-${tabs.tabs[i].id}'),
                  index: i,
                  child: _TabChip(
                    tab: tabs.tabs[i],
                    active: i == tabs.activeIndex,
                    onTap: () => onActivate(i),
                    onClose: () => onClose(tabs.tabs[i].id),
                    onReconnect: () => onReconnect(tabs.tabs[i].id),
                  ),
                ),
            ],
          ),
        ),
        const Divider(height: 1, color: Color(0xFF2A2A2A)),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            IconButton(
              key: const Key('btn-new-tab'),
              tooltip: l10n.newTabTooltip,
              icon: const Icon(Icons.add, size: 18),
              onPressed: onNewTab,
            ),
            _FilesToggleButton(visible: filesVisible, onPressed: onToggleFiles),
            IconButton(
              key: const Key('btn-vaults'),
              tooltip: l10n.vaultsTooltip,
              icon: const Icon(Icons.dns_outlined, size: 18),
              onPressed: onVaults,
            ),
            IconButton(
              key: const Key('btn-settings'),
              tooltip: l10n.settings,
              icon: const Icon(Icons.settings_outlined, size: 18),
              onPressed: onSettings,
            ),
          ],
        ),
      ]),
    );
  }
}

/// 拖移中的分頁:抬起來一點(陰影)但不變形,讓落點看得出來。
Widget _dragProxy(Widget child, int index, Animation<double> animation) {
  return Material(
    color: const Color(0xFF202020),
    elevation: 6,
    child: child,
  );
}

class _TabChip extends StatelessWidget {
  const _TabChip({
    required this.tab,
    required this.active,
    required this.onTap,
    required this.onClose,
    required this.onReconnect,
    this.width,
  });

  final TermTab tab;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onClose;
  final VoidCallback onReconnect;
  final double? width;

  /// 右鍵選單:重新連線 / 關閉。連線中的分頁不能重連(重連本身在進行中)。
  Future<void> _showMenu(BuildContext context, Offset globalPosition) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        globalPosition & Size.zero,
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem<String>(
          key: ValueKey('tab-menu-reconnect-${tab.id}'),
          value: 'reconnect',
          enabled: tab.connectFn != null && !tab.connecting,
          child: Text(l10n.reconnect),
        ),
        PopupMenuItem<String>(
          key: ValueKey('tab-menu-close-${tab.id}'),
          value: 'close',
          child: Text(l10n.closeTab),
        ),
      ],
    );
    if (selected == 'reconnect') {
      onReconnect();
    } else if (selected == 'close') {
      onClose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = tab.exited
        ? const Color(0xFFFF8A65)
        : active
            ? const Color(0xFFE0E0E0)
            : const Color(0xFF9E9E9E);
    return InkWell(
      key: ValueKey('tab-chip-${tab.id}'),
      onTap: onTap,
      onSecondaryTapDown: (d) => _showMenu(context, d.globalPosition),
      child: Container(
        width: width,
        height: 36,
        padding: const EdgeInsets.only(left: 12, right: 4),
        decoration: BoxDecoration(
          color: active ? const Color(0xFF181818) : null,
          border: active
              ? const Border(
                  top: BorderSide(color: Color(0xFF4A90D9), width: 2),
                )
              : null,
        ),
        child: Row(children: [
          Expanded(
            child: Text(
              tab.displayTitle,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: color),
            ),
          ),
          IconButton(
            key: ValueKey('tab-close-${tab.id}'),
            tooltip: l10n.closeTabTooltip,
            icon: const Icon(Icons.close, size: 14),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
            onPressed: onClose,
          ),
        ]),
      ),
    );
  }
}
