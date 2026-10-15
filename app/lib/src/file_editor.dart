// 簡易檔案編輯器 pane:讀寫本地/遠端文字檔、原子存檔、外部變更偵測。
// 內嵌在 AppShell 最右側(檔案側窗右邊),不蓋掉終端機。
// 定位是快速改設定檔/腳本,不是 IDE(見 PLAN §2.4)。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'file_pane.dart' show fileBaseName;
import 'l10n.dart';
import 'markdown_view.dart';
import 'term_ffi.dart';
import 'url_open.dart';

const int _maxEditableBytes = 5 * 1024 * 1024; // >5MB 唯讀預覽

bool isMarkdownPath(String path) {
  final name = fileBaseName(path).toLowerCase();
  return name.endsWith('.md') || name.endsWith('.markdown');
}

class FileEditorPane extends StatefulWidget {
  const FileEditorPane({
    super.key,
    required this.path,
    this.remote,
    required this.onClose,
  });

  final String path;

  /// 非 null = 遠端檔案,經此 SSH session 的 SFTP 讀寫。
  final NativeSession? remote;

  /// 使用者要求關閉(X 按鈕 / Esc)。dirty 確認由外層負責。
  final VoidCallback onClose;

  @override
  State<FileEditorPane> createState() => FileEditorPaneState();
}

class FileEditorPaneState extends State<FileEditorPane> {
  final _controller = TextEditingController();
  String? _loadError;
  bool _readOnly = false;
  String _readOnlyReason = '';
  bool _dirty = false;
  bool _saving = false;
  DateTime? _loadedMtime;

  /// .md 開起來先顯示渲染後的預覽;要改內容再切原始碼(標題列的按鈕)。
  bool _preview = false;
  bool _binary = false;

  /// 二進位(hex dump)拿去渲染 markdown 沒有意義,那種檔不給預覽。
  bool get _canPreview =>
      isMarkdownPath(widget.path) && _loadError == null && !_binary;

  /// 最後載入/儲存的內容。controller 連游標移動都會 notify,
  /// 要跟這個比對,文字真的變了才算 dirty。
  String _cleanText = '';

  /// 有未存檔修改(外層在換檔/關閉前查詢)。
  bool get isDirty => _dirty;

  @override
  void initState() {
    super.initState();
    _preview = isMarkdownPath(widget.path);
    _load();
    _controller.addListener(() {
      if (_dirty || _readOnly) return;
      if (_controller.text != _cleanText) setState(() => _dirty = true);
    });
  }

  /// 同一個 pane 換開另一個檔案 → 重置狀態、重新載入。
  /// (_load 內先設好 _readOnly 再塞 text、最後 _dirty = false,
  /// 所以 listener 不會把載入誤判成使用者修改。)
  @override
  void didUpdateWidget(FileEditorPane old) {
    super.didUpdateWidget(old);
    if (old.path == widget.path && identical(old.remote, widget.remote)) return;
    setState(() {
      _loadError = null;
      _readOnly = false;
      _readOnlyReason = '';
      _dirty = false;
      _saving = false;
      _loadedMtime = null;
      _binary = false;
      _preview = isMarkdownPath(widget.path);
    });
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _load() {
    if (widget.remote != null) {
      _loadRemote();
      return;
    }
    try {
      final file = File(widget.path);
      final stat = file.statSync();
      _loadedMtime = stat.modified;
      if (stat.size > _maxEditableBytes) {
        setState(() {
          _readOnly = true;
          _readOnlyReason = l10n.readOnlyTooLarge;
          _controller.text = utf8.decode(
            file.openSync().readSync(64 * 1024),
            allowMalformed: true,
          );
        });
        return;
      }
      final bytes = file.readAsBytesSync();
      if (bytes.contains(0)) {
        setState(() {
          _readOnly = true;
          _binary = true;
          _readOnlyReason = l10n.readOnlyBinary;
          _controller.text = _hexPreview(bytes);
        });
        return;
      }
      setState(() {
        _cleanText = utf8.decode(bytes, allowMalformed: true);
        _controller.text = _cleanText;
        _dirty = false;
      });
    } catch (e) {
      setState(() => _loadError = '$e');
    }
  }

  void _loadRemote() {
    try {
      final bytes = widget.remote!.sftpRead(widget.path);
      if (bytes.length > _maxEditableBytes) {
        setState(() {
          _readOnly = true;
          _readOnlyReason = l10n.readOnlyTooLarge;
          _controller.text =
              utf8.decode(bytes.sublist(0, 64 * 1024), allowMalformed: true);
        });
        return;
      }
      if (bytes.contains(0)) {
        setState(() {
          _readOnly = true;
          _binary = true;
          _readOnlyReason = l10n.readOnlyBinary;
          _controller.text = _hexPreview(bytes);
        });
        return;
      }
      setState(() {
        _cleanText = utf8.decode(bytes, allowMalformed: true);
        _controller.text = _cleanText;
        _dirty = false;
      });
    } catch (e) {
      setState(() => _loadError = '$e');
    }
  }

  static String _hexPreview(List<int> bytes) {
    final n = bytes.length < 2048 ? bytes.length : 2048;
    final sb = StringBuffer();
    for (var i = 0; i < n; i += 16) {
      sb.write(i.toRadixString(16).padLeft(8, '0'));
      sb.write('  ');
      for (var j = i; j < i + 16 && j < n; j++) {
        sb.write(bytes[j].toRadixString(16).padLeft(2, '0'));
        sb.write(' ');
      }
      sb.write('\n');
    }
    return sb.toString();
  }

  Future<void> _save() async {
    if (_readOnly || _saving) return;
    setState(() => _saving = true);
    if (widget.remote != null) {
      try {
        widget.remote!.sftpWrite(widget.path, utf8.encode(_controller.text));
        if (mounted) {
          setState(() {
            _cleanText = _controller.text;
            _dirty = false;
            _saving = false;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.savedRemote), duration: const Duration(seconds: 1)),
          );
        }
      } catch (e) {
        if (mounted) {
          setState(() => _saving = false);
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(l10n.saveFailed('$e'))));
        }
      }
      return;
    }
    try {
      final file = File(widget.path);
      // 外部變更偵測:載入後檔案又被改過 → 先確認
      if (file.existsSync()) {
        final mtime = file.statSync().modified;
        if (_loadedMtime != null && mtime.isAfter(_loadedMtime!)) {
          final overwrite = await _confirmOverwrite();
          if (overwrite != true) {
            setState(() => _saving = false);
            return;
          }
        }
      }
      // 原子寫入:temp + rename(存檔失敗不會留半個檔)
      final tmp = File('${widget.path}.tterm-tmp');
      tmp.writeAsBytesSync(utf8.encode(_controller.text), flush: true);
      tmp.renameSync(widget.path);
      _loadedMtime = file.statSync().modified;
      if (mounted) {
        setState(() {
          _cleanText = _controller.text;
          _dirty = false;
          _saving = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.saved), duration: const Duration(seconds: 1)),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(l10n.saveFailed('$e'))));
      }
    }
  }

  /// 預覽裡點連結:只放行 http/https(openUrl 自己也會再擋一次),
  /// 相對路徑/錨點在這個 pane 沒有意義,直接提示不處理。
  Future<void> _openLink(String url) async {
    final ok = await openUrl(url);
    if (ok || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.linkOpenFailed(url))),
    );
  }

  Future<bool?> _confirmOverwrite() {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.fileChangedTitle),
        content: Text(l10n.fileChangedBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            key: const Key('btn-overwrite'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.overwrite),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save,
        const SingleActivator(LogicalKeyboardKey.escape): widget.onClose,
      },
      child: Container(
        color: const Color(0xFF141414),
        child: Column(children: [
          _header(context),
          const Divider(height: 1, color: Color(0xFF2A2A2A)),
          Expanded(child: _body(context)),
        ]),
      ),
    );
  }

  /// 標題列:檔名 + 未存檔「•」、遠端雲朵、唯讀原因/儲存、關閉。
  Widget _header(BuildContext context) {
    final name = fileBaseName(widget.path);
    return SizedBox(
      height: 36,
      child: Row(children: [
        const SizedBox(width: 8),
        if (widget.remote != null)
          const Padding(
            padding: EdgeInsets.only(right: 4),
            child: Icon(Icons.cloud_outlined, size: 14, color: Color(0xFF4A90D9)),
          ),
        Expanded(
          child: Tooltip(
            message: widget.remote != null
                ? l10n.remotePath(widget.path)
                : widget.path,
            child: Text(
              '$name${_dirty ? ' •' : ''}',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Color(0xFFCFCFCF)),
            ),
          ),
        ),
        if (_canPreview)
          IconButton(
            key: const Key('btn-toggle-md-preview'),
            tooltip: _preview ? l10n.showSource : l10n.previewMarkdown,
            visualDensity: VisualDensity.compact,
            icon: Icon(
              _preview ? Icons.code : Icons.visibility_outlined,
              size: 16,
              color: _preview ? const Color(0xFF4A90D9) : null,
            ),
            onPressed: () => setState(() => _preview = !_preview),
          ),
        if (_readOnly)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              _readOnlyReason,
              style: const TextStyle(color: Color(0xFFFF8A65), fontSize: 11),
            ),
          )
        else
          IconButton(
            key: const Key('btn-save-file'),
            tooltip: l10n.saveTooltip,
            visualDensity: VisualDensity.compact,
            icon: _saving
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined, size: 16),
            onPressed: _dirty ? _save : null,
          ),
        IconButton(
          key: const Key('btn-close-editor'),
          tooltip: l10n.closeEscTooltip,
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.close, size: 16),
          onPressed: widget.onClose,
        ),
        const SizedBox(width: 2),
      ]),
    );
  }

  Widget _body(BuildContext context) {
    if (_loadError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            l10n.fileOpenFailed('$_loadError'),
            style: const TextStyle(
              color: Color(0xFFFF6B6B),
              fontFamily: 'monospace',
              fontSize: 12,
            ),
          ),
        ),
      );
    }
    // Markdown 預覽。沒有 TextField 就沒有東西吃鍵盤,Ctrl+S / Esc 會落到
    // 終端機去,所以自己抓焦點。
    if (_canPreview && _preview) {
      return Focus(
        autofocus: true,
        child: MarkdownView(
          source: _controller.text,
          onTapLink: (url) => unawaited(_openLink(url)),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(8),
      child: TextField(
        key: const Key('editor-text'),
        controller: _controller,
        readOnly: _readOnly,
        autofocus: true,
        maxLines: null,
        expands: true,
        textAlignVertical: TextAlignVertical.top,
        style: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 13,
          color: Color(0xFFD8D8D8),
        ),
        decoration: const InputDecoration(
          border: InputBorder.none,
          isCollapsed: true,
        ),
      ),
    );
  }
}
