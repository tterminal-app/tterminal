// 檔案側窗:列出目錄檔案、可導覽、跟隨 cwd(OSC 7)、開啟編輯、拖拉到檔案總管。
//
// 只用 dart:io 讀本地檔案系統(SSH 的 SFTP 之後再做)。

import 'dart:io';

import 'package:flutter/material.dart';

import 'l10n.dart';
import 'term_ffi.dart';

/// 一筆檔案/目錄。
class FileEntry {
  FileEntry({
    required this.path,
    required this.name,
    required this.isDir,
    required this.size,
    required this.modified,
  });

  final String path;
  final String name;
  final bool isDir;
  final int size;
  final DateTime? modified;
}

String fileBaseName(String path) {
  final norm = path.replaceAll('\\', '/');
  final trimmed =
      norm.length > 1 && norm.endsWith('/') ? norm.substring(0, norm.length - 1) : norm;
  final idx = trimmed.lastIndexOf('/');
  return idx < 0 || idx == trimmed.length - 1 ? trimmed : trimmed.substring(idx + 1);
}

bool _samePath(String a, String b) {
  String n(String s) {
    var x = s.replaceAll('\\', '/');
    if (x.length > 1 && x.endsWith('/')) x = x.substring(0, x.length - 1);
    return Platform.isWindows ? x.toLowerCase() : x;
  }

  return n(a) == n(b);
}

/// 檔案來源:本地(dart:io)或遠端(SSH SFTP)。
abstract class FileSource {
  bool get isRemote;

  /// 列出目錄;失敗丟例外(controller 捕捉成 error)。
  List<FileEntry> list(String path);
  String parentOf(String path);
  bool isRoot(String path);
}

class LocalFileSource implements FileSource {
  @override
  bool get isRemote => false;

  @override
  List<FileEntry> list(String path) {
    final es = <FileEntry>[];
    for (final e in Directory(path).listSync(followLinks: false)) {
      try {
        final stat = e.statSync();
        es.add(FileEntry(
          path: e.path,
          name: fileBaseName(e.path),
          isDir: stat.type == FileSystemEntityType.directory,
          size: stat.size,
          modified: stat.modified,
        ));
      } catch (_) {
        // 個別項目 stat 失敗(權限等)就跳過
      }
    }
    return es;
  }

  @override
  String parentOf(String path) => Directory(path).parent.path;

  @override
  bool isRoot(String path) => _samePath(Directory(path).parent.path, path);
}

/// 遠端(SFTP)檔案來源;透過 SSH session 的 FFI 列/讀檔(POSIX 路徑)。
class RemoteFileSource implements FileSource {
  RemoteFileSource(this.session);

  final NativeSession session;

  @override
  bool get isRemote => true;

  @override
  List<FileEntry> list(String path) {
    return [
      for (final e in session.sftpList(path))
        FileEntry(
          path: _join(path, e['name'] as String),
          name: e['name'] as String,
          isDir: e['isDir'] == true,
          size: (e['size'] as num?)?.toInt() ?? 0,
          modified: null,
        ),
    ];
  }

  @override
  String parentOf(String path) {
    if (path == '/' || path.isEmpty) return '/';
    final trimmed = path.endsWith('/') ? path.substring(0, path.length - 1) : path;
    final idx = trimmed.lastIndexOf('/');
    return idx <= 0 ? '/' : trimmed.substring(0, idx);
  }

  @override
  bool isRoot(String path) => path == '/' || path.isEmpty;

  static String _join(String dir, String name) =>
      dir.endsWith('/') ? '$dir$name' : '$dir/$name';
}

class FilePaneController extends ChangeNotifier {
  FilePaneController(String initialDir)
      : _source = LocalFileSource(),
        _path = initialDir {
    _load();
  }

  FileSource _source;
  String _path;
  List<FileEntry> entries = const [];
  String? error;
  bool followCwd = true;

  /// 目前反白的項目路徑(單擊選取;換目錄清掉)。
  String? selected;

  String get path => _path;
  bool get isRemote => _source.isRemote;
  bool get atRoot => _source.isRoot(_path);

  /// 切換來源(本地 ↔ 遠端)並重新載入。
  void setSource(FileSource source, String initialDir) {
    _source = source;
    _path = initialDir;
    selected = null;
    _load();
  }

  void _load() {
    try {
      final es = _source.list(_path)
        ..sort((a, b) {
          if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        });
      entries = es;
      error = null;
    } catch (e) {
      entries = const [];
      error = '$e';
    }
    notifyListeners();
  }

  void navigateTo(String dir) {
    _path = dir;
    selected = null;
    _load();
  }

  void select(String path) {
    if (selected == path) return;
    selected = path;
    notifyListeners();
  }

  void enter(FileEntry e) {
    if (e.isDir) navigateTo(e.path);
  }

  void up() {
    if (!atRoot) navigateTo(_source.parentOf(_path));
  }

  void refresh() => _load();

  void toggleFollow() {
    followCwd = !followCwd;
    notifyListeners();
  }

  /// OSC 7 cwd 變更(僅本地來源跟隨)。
  void onCwdChanged(String? cwd) {
    if (!followCwd || _source.isRemote || cwd == null || cwd.isEmpty) return;
    if (_samePath(cwd, _path)) return;
    if (Directory(cwd).existsSync()) navigateTo(cwd);
  }
}

/// 檔案列:移動超過門檻就觸發拖出(交給 native 拖放)。tap 仍走 InkWell。
class _DraggableFileRow extends StatefulWidget {
  const _DraggableFileRow({
    required this.path,
    required this.onDrag,
    required this.child,
  });

  final String path;
  final void Function(String path) onDrag;
  final Widget child;

  @override
  State<_DraggableFileRow> createState() => _DraggableFileRowState();
}

class _DraggableFileRowState extends State<_DraggableFileRow> {
  Offset? _down;
  bool _started = false;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (e) {
        _down = e.position;
        _started = false;
      },
      onPointerMove: (e) {
        if (_started || _down == null) return;
        if ((e.position - _down!).distance > 8) {
          _started = true;
          widget.onDrag(widget.path);
        }
      },
      onPointerUp: (_) {
        _down = null;
        _started = false;
      },
      child: widget.child,
    );
  }
}

class FilePane extends StatefulWidget {
  const FilePane({
    super.key,
    required this.controller,
    required this.onOpenFile,
    this.onDragFileOut,
    this.onJumpToCwd,
    this.onOpenInVscode,
  });

  final FilePaneController controller;
  final void Function(String path) onOpenFile;

  /// 開始把檔案拖出去(到檔案總管);null = 不支援拖出。
  final void Function(String path)? onDragFileOut;

  /// 跳到終端目前的工作目錄(手動觸發偵測,必要時連來源一起換成作用中分頁
  /// 的本地/遠端);null = 不顯示按鈕。切分頁本身不會動側窗。
  final VoidCallback? onJumpToCwd;

  /// 右鍵選單「用 VS Code 開啟」選取的項目(檔案/資料夾皆可);
  /// null = 不顯示該選單項(如手機平台沒有 `code`)。
  final void Function(FileEntry entry)? onOpenInVscode;

  @override
  State<FilePane> createState() => _FilePaneState();
}

class _FilePaneState extends State<FilePane> {
  FilePaneController get controller => widget.controller;
  void Function(String path) get onOpenFile => widget.onOpenFile;
  void Function(String path)? get onDragFileOut => widget.onDragFileOut;
  VoidCallback? get onJumpToCwd => widget.onJumpToCwd;
  void Function(FileEntry entry)? get onOpenInVscode => widget.onOpenInVscode;

  /// 右鍵:先反白該項,再在指標處開 context menu。
  Future<void> _showContextMenu(
    BuildContext context,
    FileEntry e,
    Offset globalPos,
  ) async {
    if (onOpenInVscode == null) return;
    controller.select(e.path);
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        globalPos & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(
          value: 'vscode',
          height: 36,
          child: Text(l10n.openInVscode, style: const TextStyle(fontSize: 13)),
        ),
      ],
    );
    if (selected == 'vscode') onOpenInVscode?.call(e);
  }

  // 手動偵測雙擊(不用 GestureDetector 的 onDoubleTap:那會讓單擊
  // 延遲 ~300ms 等消歧,反白會頓)。單擊=選取,雙擊=開啟/進入。
  String? _lastTapPath;
  DateTime _lastTapAt = DateTime.fromMillisecondsSinceEpoch(0);

  void _tapEntry(FileEntry e) {
    final now = DateTime.now();
    final isDouble = _lastTapPath == e.path &&
        now.difference(_lastTapAt) < const Duration(milliseconds: 400);
    if (isDouble) {
      _lastTapPath = null; // 用掉:第三擊重新計
      if (e.isDir) {
        controller.enter(e);
      } else {
        onOpenFile(e.path);
      }
      return;
    }
    _lastTapPath = e.path;
    _lastTapAt = now;
    controller.select(e.path);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF141414),
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          return Column(children: [
            _header(context),
            const Divider(height: 1, color: Color(0xFF2A2A2A)),
            Expanded(child: _body(context)),
            const Divider(height: 1, color: Color(0xFF2A2A2A)),
            _pathBar(),
          ]);
        },
      ),
    );
  }

  Widget _header(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
      child: Row(children: [
        IconButton(
          key: const Key('file-up'),
          tooltip: l10n.parentFolder,
          icon: const Icon(Icons.arrow_upward, size: 16),
          visualDensity: VisualDensity.compact,
          onPressed: controller.atRoot ? null : controller.up,
        ),
        if (controller.isRemote)
          const Padding(
            padding: EdgeInsets.only(right: 4),
            child: Icon(Icons.cloud_outlined, size: 14, color: Color(0xFF4A90D9)),
          ),
        Expanded(
          child: Tooltip(
            message: controller.isRemote
                ? l10n.remotePath(controller.path)
                : controller.path,
            child: Text(
              controller.path == '/' ? '/' : fileBaseName(controller.path),
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Color(0xFFCFCFCF)),
            ),
          ),
        ),
        IconButton(
          key: const Key('file-refresh'),
          tooltip: l10n.refresh,
          icon: const Icon(Icons.refresh, size: 16),
          visualDensity: VisualDensity.compact,
          onPressed: controller.refresh,
        ),
        if (onJumpToCwd != null)
          IconButton(
            key: const Key('file-goto-cwd'),
            tooltip: l10n.jumpToCwd,
            icon: const Icon(Icons.my_location, size: 16),
            visualDensity: VisualDensity.compact,
            onPressed: onJumpToCwd,
          ),
        IconButton(
          key: const Key('file-follow'),
          tooltip: controller.followCwd ? l10n.followCwdOn : l10n.followCwdOff,
          icon: Icon(
            controller.followCwd ? Icons.link : Icons.link_off,
            size: 16,
            color: controller.followCwd ? const Color(0xFF4A90D9) : null,
          ),
          visualDensity: VisualDensity.compact,
          onPressed: controller.toggleFollow,
        ),
      ]),
    );
  }

  /// 底部路徑列:完整路徑,太長時停在尾端(目前所在目錄最重要),可往回捲;
  /// 文字可反白複製(滑鼠拖選,scroll view 只吃滾輪不搶拖曳)。
  Widget _pathBar() {
    return Container(
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: Alignment.centerLeft,
      child: Tooltip(
        message: controller.isRemote
            ? l10n.remotePath(controller.path)
            : controller.path,
        child: SingleChildScrollView(
          key: const Key('file-path-bar'),
          scrollDirection: Axis.horizontal,
          reverse: true,
          child: SelectableText(
            controller.path,
            maxLines: 1,
            style: const TextStyle(fontSize: 11, color: Color(0xFF8A8A8A)),
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    if (controller.error != null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          l10n.listDirFailed('${controller.error}'),
          style: const TextStyle(color: Color(0xFFFF8A65), fontSize: 12),
        ),
      );
    }
    if (controller.entries.isEmpty) {
      return Center(
        child: Text(
          l10n.emptyFolder,
          style: const TextStyle(color: Color(0xFF808080)),
        ),
      );
    }
    return ListView.builder(
      key: const Key('file-list'),
      itemCount: controller.entries.length,
      itemExtent: 28,
      itemBuilder: (context, i) {
        final e = controller.entries[i];
        final selected = controller.selected == e.path;
        final row = InkWell(
          key: ValueKey('file-entry-${e.name}'),
          onTap: () => _tapEntry(e),
          child: Container(
            color: selected ? const Color(0xFF264F78) : null,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(children: [
              Icon(
                e.isDir ? Icons.folder : Icons.insert_drive_file_outlined,
                size: 15,
                color: e.isDir ? const Color(0xFFE0B24A) : const Color(0xFF9AA0A6),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  e.name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5, color: Color(0xFFD8D8D8)),
                ),
              ),
            ]),
          ),
        );
        // 檔案(非目錄)可拖出到系統檔案管理員。遠端檔案由上層先下載到暫存再拖
        // (native 拖放要的是真的本地路徑)。用 Listener 手動偵測拖曳門檻:
        // 不進手勢競技場,不被 ListView 捲動搶走。
        Widget item = row;
        if (!e.isDir && onDragFileOut != null) {
          item = _DraggableFileRow(
            path: e.path,
            onDrag: onDragFileOut!,
            child: row,
          );
        }
        // 右鍵 context menu(反白 + 用 VS Code 開啟)。右鍵不干擾左鍵單/雙擊
        // 與拖出。
        if (onOpenInVscode != null) {
          item = GestureDetector(
            behavior: HitTestBehavior.translucent,
            onSecondaryTapDown: (d) =>
                _showContextMenu(context, e, d.globalPosition),
            child: item,
          );
        }
        return item;
      },
    );
  }
}
