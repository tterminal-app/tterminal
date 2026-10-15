// Markdown 預覽:自己解析 + 自己畫。編輯器 pane 開 .md 時預設顯示這個。
//
// 只做「在側邊 pane 看 README/筆記」需要的子集:ATX 標題、段落、粗體/斜體/
// 刪除線/行內程式碼、連結(含 autolink 與裸網址)、圍欄程式區塊、清單(巢狀
// 與 `- [ ]` 待辦)、引言、水平線、GFM 表格。
//
// 不引第三方套件:flutter_markdown 上游已停止維護,而整包 CommonMark parser
// 對一個側邊 pane 太重(這個 app 的相依只有 ffi)。相對的,以下刻意不支援:
// setext 標題(`===` 底線)、縮排式程式區塊、行內 HTML、參考式連結、註腳;
// 圖片只顯示替代文字(側窗窄,而且遠端/相對路徑抓不到)。

import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

// ---------------------------------------------------------------- 區塊模型

sealed class MdBlock {
  const MdBlock();
}

class MdHeading extends MdBlock {
  const MdHeading(this.level, this.text);
  final int level; // 1..6
  final String text;
}

class MdParagraph extends MdBlock {
  const MdParagraph(this.text);
  final String text;
}

class MdCode extends MdBlock {
  const MdCode(this.text, this.lang);
  final String text;
  final String lang;
}

class MdRule extends MdBlock {
  const MdRule();
}

class MdQuote extends MdBlock {
  const MdQuote(this.children);
  final List<MdBlock> children;
}

class MdListItem extends MdBlock {
  const MdListItem({
    required this.text,
    required this.depth,
    required this.ordered,
    this.number = 0,
    this.checked,
  });

  final String text;
  final int depth; // 巢狀層數,0 = 最外層
  final bool ordered;
  final int number;

  /// null = 不是待辦項;true/false = `- [x]` / `- [ ]`。
  final bool? checked;
}

class MdTable extends MdBlock {
  const MdTable(this.header, this.rows);
  final List<String> header;
  final List<List<String>> rows;
}

// ---------------------------------------------------------------- 區塊解析

final _headingRe = RegExp(r'^ {0,3}(#{1,6})\s+(.*)$');
final _ruleRe = RegExp(r'^ {0,3}([-*_])(\s*\1){2,}\s*$');
final _fenceRe = RegExp('^ {0,3}(`{3,}|~{3,})(.*)\$');
final _listRe = RegExp(r'^(\s*)(?:([-*+])|(\d{1,9})[.)])\s+(.*)$');
final _taskRe = RegExp(r'^\[([ xX])\]\s+(.*)$');

/// 把 markdown 原始碼切成區塊。未支援的語法一律退化成純段落文字,
/// 寧可顯示原文也不要吞掉內容。
List<MdBlock> parseMarkdown(String src) {
  final lines = LineSplitter.split(src).toList();
  final out = <MdBlock>[];
  var i = 0;

  while (i < lines.length) {
    final line = lines[i];
    if (line.trim().isEmpty) {
      i++;
      continue;
    }

    // 圍欄程式區塊:沒有收尾就吃到檔尾(編輯到一半的檔案很常這樣)
    final fence = _fenceRe.firstMatch(line);
    if (fence != null) {
      final marker = fence[1]!;
      final lang = fence[2]!.trim();
      final buf = <String>[];
      i++;
      while (i < lines.length && !_closesFence(lines[i], marker)) {
        buf.add(lines[i]);
        i++;
      }
      if (i < lines.length) i++; // 吃掉收尾的 fence
      out.add(MdCode(buf.join('\n'), lang));
      continue;
    }

    if (_ruleRe.hasMatch(line)) {
      out.add(const MdRule());
      i++;
      continue;
    }

    final heading = _headingRe.firstMatch(line);
    if (heading != null) {
      out.add(MdHeading(heading[1]!.length, _stripClosingHashes(heading[2]!)));
      i++;
      continue;
    }

    if (_isQuote(line)) {
      final inner = <String>[];
      // `>` 開頭的行都算;後面沒有 `>` 的非空行是 lazy continuation
      while (i < lines.length &&
          (_isQuote(lines[i]) ||
              (inner.isNotEmpty && lines[i].trim().isNotEmpty))) {
        inner.add(_stripQuote(lines[i]));
        i++;
      }
      out.add(MdQuote(parseMarkdown(inner.join('\n'))));
      continue;
    }

    if (_listRe.hasMatch(line)) {
      i = _parseList(lines, i, out);
      continue;
    }

    if (i + 1 < lines.length &&
        line.contains('|') &&
        _isTableDelimiter(lines[i + 1])) {
      final header = _tableCells(line);
      final rows = <List<String>>[];
      i += 2;
      while (i < lines.length &&
          lines[i].contains('|') &&
          lines[i].trim().isNotEmpty) {
        rows.add(_tableCells(lines[i]));
        i++;
      }
      out.add(MdTable(header, rows));
      continue;
    }

    // 段落:吃到空行或下一個區塊開頭為止(第一行一定收,不然會空轉)
    final para = <String>[line];
    i++;
    while (i < lines.length &&
        lines[i].trim().isNotEmpty &&
        !_startsBlock(lines[i])) {
      para.add(lines[i]);
      i++;
    }
    out.add(MdParagraph(joinSoftBreaks(para)));
  }
  return out;
}

/// 一段連續的清單。回傳消化到的行號。
int _parseList(List<String> lines, int start, List<MdBlock> out) {
  var i = start;
  final indents = <int>[]; // 縮排堆疊 → 巢狀層數(2 或 4 空白縮排都算一層)
  while (i < lines.length) {
    final m = _listRe.firstMatch(lines[i]);
    if (m == null) {
      // 空行後面還接著清單項 → 同一串(loose list);否則結束
      if (lines[i].trim().isEmpty &&
          i + 1 < lines.length &&
          _listRe.hasMatch(lines[i + 1])) {
        i++;
        continue;
      }
      break;
    }
    final indent = m[1]!.length;
    while (indents.isNotEmpty && indent < indents.last) {
      indents.removeLast();
    }
    if (indents.isEmpty || indent > indents.last) indents.add(indent);
    final depth = indents.length - 1;

    final parts = <String>[m[4]!];
    i++;
    // 續行:比項目更縮排、又不是新項目的非空行
    while (i < lines.length &&
        lines[i].trim().isNotEmpty &&
        !_listRe.hasMatch(lines[i]) &&
        !_startsBlock(lines[i]) &&
        _indentOf(lines[i]) > indent) {
      parts.add(lines[i]);
      i++;
    }
    var text = joinSoftBreaks(parts);
    bool? checked;
    final task = _taskRe.firstMatch(text);
    if (task != null) {
      checked = task[1]! != ' ';
      text = task[2]!.trim();
    }
    out.add(MdListItem(
      text: text,
      depth: depth,
      ordered: m[3] != null,
      number: int.tryParse(m[3] ?? '') ?? 0,
      checked: checked,
    ));
  }
  return i;
}

/// 段落內的軟換行照 markdown 併成一行(原始碼硬折到 80 欄的檔案才不會
/// 被斷得亂七八糟)。兩邊都是中日韓字時不補空白——補了會多一個字寬的洞。
/// 行尾兩個空白或反斜線才是真的換行。
String joinSoftBreaks(List<String> raw) {
  final buf = StringBuffer();
  var hardBreak = false;
  var last = '';
  for (final rawLine in raw) {
    final hard =
        rawLine.endsWith('  ') || rawLine.trimRight().endsWith(r'\');
    var line = rawLine.trim();
    if (hard && line.endsWith(r'\')) {
      line = line.substring(0, line.length - 1).trimRight();
    }
    if (line.isEmpty) continue;
    if (buf.isNotEmpty) {
      if (hardBreak) {
        buf.write('\n');
      } else if (!_isCjk(last) || !_isCjk(line[0])) {
        buf.write(' ');
      }
    }
    buf.write(line);
    last = line[line.length - 1];
    hardBreak = hard;
  }
  return buf.toString();
}

/// 中日韓文字(含全形標點):判斷軟換行要不要補空白用。
bool _isCjk(String ch) {
  if (ch.isEmpty) return false;
  final c = ch.codeUnitAt(0);
  return (c >= 0x2E80 && c <= 0x9FFF) || // 部首 ~ 統一表意文字
      (c >= 0xAC00 && c <= 0xD7AF) || // 諺文
      (c >= 0xF900 && c <= 0xFAFF) || // 相容表意文字
      (c >= 0xFE30 && c <= 0xFE4F) || // 相容形式
      (c >= 0xFF00 && c <= 0xFF60); // 全形
}

bool _closesFence(String line, String marker) {
  final t = line.trim();
  return t.startsWith(marker[0] * 3) && t.replaceAll(marker[0], '').isEmpty;
}

bool _isQuote(String line) => RegExp(r'^ {0,3}>').hasMatch(line);

String _stripQuote(String line) {
  final t = line.replaceFirst(RegExp(r'^ {0,3}>'), '');
  return t.startsWith(' ') ? t.substring(1) : t;
}

String _stripClosingHashes(String s) =>
    s.replaceFirst(RegExp(r'\s+#+\s*$'), '').trim();

int _indentOf(String line) => line.length - line.trimLeft().length;

bool _startsBlock(String line) =>
    _fenceRe.hasMatch(line) ||
    _ruleRe.hasMatch(line) ||
    _headingRe.hasMatch(line) ||
    _isQuote(line) ||
    _listRe.hasMatch(line);

bool _isTableDelimiter(String line) {
  if (!line.contains('-') || !line.contains('|')) return false;
  final cells = _tableCells(line);
  return cells.isNotEmpty &&
      cells.every((c) => RegExp(r'^:?-{1,}:?$').hasMatch(c));
}

List<String> _tableCells(String line) {
  var s = line.trim();
  if (s.startsWith('|')) s = s.substring(1);
  if (s.endsWith('|')) s = s.substring(0, s.length - 1);
  return [for (final c in s.split('|')) c.trim()];
}

// ---------------------------------------------------------------- 行內解析

/// 一段樣式相同的文字。[link] 非 null = 可點的連結。
class MdSpan {
  const MdSpan(
    this.text, {
    this.bold = false,
    this.italic = false,
    this.code = false,
    this.strike = false,
    this.link,
  });

  final String text;
  final bool bold;
  final bool italic;
  final bool code;
  final bool strike;
  final String? link;

  MdSpan _with(String text) => MdSpan(
        text,
        bold: bold,
        italic: italic,
        code: code,
        strike: strike,
        link: link,
      );

  MdSpan _copy({
    bool? bold,
    bool? italic,
    bool? code,
    bool? strike,
    String? link,
  }) =>
      MdSpan(
        text,
        bold: bold ?? this.bold,
        italic: italic ?? this.italic,
        code: code ?? this.code,
        strike: strike ?? this.strike,
        link: link ?? this.link,
      );
}

const _escapable = r'\`*_{}[]()#+-.!|~>';
final _autolinkRe = RegExp(r'<(https?://[^>\s]+)>');
final _bareUrlRe = RegExp(r'https?://[^\s<>()\[\]{}"' "'" r'`]+');
final _linkRe = RegExp(r'\[([^\]]*)\]\(([^)\s]*)(?:\s+"[^"]*")?\)');

/// 把一行(或一段)文字拆成帶樣式的片段。無法配對的符號一律當普通字元,
/// 不會吃掉內容。
List<MdSpan> parseInline(String src) {
  final out = <MdSpan>[];
  _inline(src, const MdSpan(''), out);
  return out;
}

void _inline(String src, MdSpan style, List<MdSpan> out) {
  final buf = StringBuffer();
  void flush() {
    if (buf.isEmpty) return;
    out.add(style._with(buf.toString()));
    buf.clear();
  }

  var i = 0;
  while (i < src.length) {
    final c = src[i];

    if (c == r'\' && i + 1 < src.length && _escapable.contains(src[i + 1])) {
      buf.write(src[i + 1]);
      i += 2;
      continue;
    }

    // 行內程式碼:內容不再解析樣式
    if (c == '`') {
      final run = _runLength(src, i, '`');
      final close = src.indexOf('`' * run, i + run);
      if (close > 0) {
        flush();
        out.add(style._copy(code: true)._with(src.substring(i + run, close)));
        i = close + run;
        continue;
      }
    }

    // 圖片:側窗不畫圖,只留替代文字
    if (c == '!' && i + 1 < src.length && src[i + 1] == '[') {
      final m = _linkRe.matchAsPrefix(src, i + 1);
      if (m != null) {
        flush();
        final alt = m[1]!.isEmpty ? m[2]! : m[1]!;
        out.add(style._with('🖼 $alt'));
        i = m.end;
        continue;
      }
    }

    if (c == '[' && style.link == null) {
      final m = _linkRe.matchAsPrefix(src, i);
      if (m != null) {
        flush();
        final url = m[2]!;
        final text = m[1]!.isEmpty ? url : m[1]!;
        _inline(text, style._copy(link: url), out);
        i = m.end;
        continue;
      }
    }

    if (c == '<') {
      final m = _autolinkRe.matchAsPrefix(src, i);
      if (m != null) {
        flush();
        out.add(style._copy(link: m[1])._with(m[1]!));
        i = m.end;
        continue;
      }
    }

    if (c == 'h' && style.link == null) {
      final m = _bareUrlRe.matchAsPrefix(src, i);
      if (m != null) {
        // 網址後面的句讀不算網址的一部分
        var url = m[0]!;
        while (url.length > 1 && '.,;:!?'.contains(url[url.length - 1])) {
          url = url.substring(0, url.length - 1);
        }
        flush();
        out.add(style._copy(link: url)._with(url));
        i += url.length;
        continue;
      }
    }

    if (c == '~' && src.startsWith('~~', i)) {
      final close = src.indexOf('~~', i + 2);
      if (close > i + 2) {
        flush();
        _inline(src.substring(i + 2, close), style._copy(strike: true), out);
        i = close + 2;
        continue;
      }
    }

    if (c == '*' || c == '_') {
      final run = _runLength(src, i, c).clamp(1, 3);
      // `_` 在字中間不算強調,不然 snake_case_name 會被吃掉
      final okOpen = c == '*' || !_isWordChar(src, i - 1);
      final close = run == 1
          ? _findSingle(src, i + 1, c)
          : src.indexOf(c * run, i + run);
      final okClose = close > i + run &&
          (c == '*' || !_isWordChar(src, close + (run == 1 ? 1 : run)));
      if (okOpen && okClose) {
        flush();
        final inner = src.substring(i + run, close);
        final st = switch (run) {
          3 => style._copy(bold: true, italic: true),
          2 => style._copy(bold: true),
          _ => style._copy(italic: true),
        };
        _inline(inner, st, out);
        i = close + run;
        continue;
      }
    }

    buf.write(c);
    i++;
  }
  flush();
}

int _runLength(String src, int i, String ch) {
  var n = 0;
  while (i + n < src.length && src[i + n] == ch) {
    n++;
  }
  return n;
}

/// 找下一個「單獨」的 [ch](跳過 `**` 這種成對的),找不到回 -1。
int _findSingle(String src, int from, String ch) {
  var j = from;
  while (j < src.length) {
    if (src[j] != ch) {
      j++;
      continue;
    }
    if (j + 1 < src.length && src[j + 1] == ch) {
      j += 2; // 這是 `**`,跳過
      continue;
    }
    if (j > 0 && src[j - 1] == ch) {
      j++;
      continue;
    }
    return j;
  }
  return -1;
}

bool _isWordChar(String src, int i) {
  if (i < 0 || i >= src.length) return false;
  return RegExp(r'[0-9A-Za-z]').hasMatch(src[i]);
}

// ---------------------------------------------------------------- 畫面

class MarkdownStyle {
  const MarkdownStyle();

  static const bg = Color(0xFF141414);
  static const text = Color(0xFFD0D0D0);
  static const heading = Color(0xFFEDEDED);
  static const dim = Color(0xFF9AA0A6);
  static const link = Color(0xFF6FB3F2);
  static const codeBg = Color(0xFF1D1D1D);
  static const codeText = Color(0xFFE0B24A);
  static const border = Color(0xFF2A2A2A);

  static const headingSizes = [19.5, 17.0, 15.0, 14.0, 13.5, 13.0];
}

/// 只讀的 markdown 預覽。[onTapLink] 為 null 時連結只是變色不可點。
class MarkdownView extends StatefulWidget {
  const MarkdownView({super.key, required this.source, this.onTapLink});

  final String source;
  final void Function(String url)? onTapLink;

  @override
  State<MarkdownView> createState() => _MarkdownViewState();
}

class _MarkdownViewState extends State<MarkdownView> {
  late List<MdBlock> _blocks = parseMarkdown(widget.source);

  /// TextSpan 上的手勢辨識器要自己回收,重建/dispose 前一起清掉。
  final _recognizers = <TapGestureRecognizer>[];

  @override
  void didUpdateWidget(MarkdownView old) {
    super.didUpdateWidget(old);
    if (old.source != widget.source) {
      _blocks = parseMarkdown(widget.source);
    }
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    return SelectionArea(
      child: ListView.builder(
        key: const Key('md-preview'),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
        itemCount: _blocks.length,
        itemBuilder: (context, i) => _block(_blocks[i]),
      ),
    );
  }

  Widget _block(MdBlock b) {
    return switch (b) {
      MdHeading() => _heading(b),
      MdParagraph() => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: _rich(b.text, const TextStyle(fontSize: 13, height: 1.55)),
        ),
      MdCode() => _code(b),
      MdRule() => const Padding(
          padding: EdgeInsets.symmetric(vertical: 10),
          child: Divider(height: 1, color: MarkdownStyle.border),
        ),
      MdQuote() => Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.only(left: 10),
          decoration: const BoxDecoration(
            border: Border(
              left: BorderSide(color: Color(0xFF4A4A4A), width: 3),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [for (final c in b.children) _block(c)],
          ),
        ),
      MdListItem() => _listItem(b),
      MdTable() => _table(b),
    };
  }

  Widget _heading(MdHeading h) {
    final size = MarkdownStyle.headingSizes[h.level - 1];
    final line = h.level <= 2;
    return Padding(
      padding: EdgeInsets.only(top: h.level <= 2 ? 14 : 10, bottom: 4),
      child: Container(
        padding: EdgeInsets.only(bottom: line ? 4 : 0),
        decoration: line
            ? const BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: MarkdownStyle.border),
                ),
              )
            : null,
        child: _rich(
          h.text,
          TextStyle(
            fontSize: size,
            height: 1.3,
            fontWeight: FontWeight.w600,
            color: MarkdownStyle.heading,
          ),
        ),
      ),
    );
  }

  Widget _code(MdCode c) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: MarkdownStyle.codeBg,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: MarkdownStyle.border),
        ),
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (c.lang.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  c.lang,
                  style: const TextStyle(
                    fontSize: 10,
                    color: MarkdownStyle.dim,
                  ),
                ),
              ),
            // 程式碼不折行:太長就自己橫捲(折行會把縮排看成另一個結構)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Text(
                c.text,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  height: 1.4,
                  color: Color(0xFFD8D8D8),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _listItem(MdListItem li) {
    // 只用幾乎每套字型都有的符號:冷門的 ◦/▪ 在某些中文字型是空白框
    const bullets = ['•', '·', '-'];
    Widget marker;
    if (li.checked != null) {
      marker = Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Icon(
          li.checked! ? Icons.check_box_outlined : Icons.check_box_outline_blank,
          size: 14,
          color: li.checked! ? const Color(0xFF6FBF73) : MarkdownStyle.dim,
        ),
      );
    } else {
      marker = Text(
        li.ordered ? '${li.number}.' : bullets[li.depth % bullets.length],
        style: const TextStyle(fontSize: 13, color: MarkdownStyle.dim),
      );
    }
    return Padding(
      padding: EdgeInsets.only(left: 4.0 + li.depth * 14, top: 2, bottom: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 20, child: marker),
          Expanded(
            child: _rich(
              li.text,
              const TextStyle(fontSize: 13, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _table(MdTable t) {
    final cols = [
      t.header.length,
      for (final r in t.rows) r.length,
    ].reduce((a, b) => a > b ? a : b);

    List<Widget> row(List<String> cells, {required bool header}) => [
          for (var i = 0; i < cols; i++)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: _rich(
                i < cells.length ? cells[i] : '',
                TextStyle(
                  fontSize: 12,
                  height: 1.4,
                  fontWeight: header ? FontWeight.w600 : null,
                  color: header ? MarkdownStyle.heading : MarkdownStyle.text,
                ),
              ),
            ),
        ];

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Table(
        border: TableBorder.all(color: MarkdownStyle.border),
        defaultVerticalAlignment: TableCellVerticalAlignment.top,
        children: [
          TableRow(
            decoration: const BoxDecoration(color: Color(0xFF1B1B1B)),
            children: row(t.header, header: true),
          ),
          for (final r in t.rows) TableRow(children: row(r, header: false)),
        ],
      ),
    );
  }

  /// 把行內語法畫成 RichText。基底樣式由呼叫端給(標題/表格各自不同)。
  Widget _rich(String source, TextStyle base) {
    final style = base.copyWith(color: base.color ?? MarkdownStyle.text);
    return Text.rich(
      TextSpan(
        children: [
          for (final s in parseInline(source)) _span(s, style),
        ],
      ),
    );
  }

  TextSpan _span(MdSpan s, TextStyle base) {
    var style = base;
    if (s.bold) style = style.copyWith(fontWeight: FontWeight.w700);
    if (s.italic) style = style.copyWith(fontStyle: FontStyle.italic);
    if (s.strike) {
      style = style.copyWith(
        decoration: TextDecoration.lineThrough,
        color: MarkdownStyle.dim,
      );
    }
    if (s.code) {
      style = style.copyWith(
        fontFamily: 'monospace',
        fontSize: (base.fontSize ?? 13) - 0.5,
        color: MarkdownStyle.codeText,
        backgroundColor: MarkdownStyle.codeBg,
      );
    }
    if (s.link == null) return TextSpan(text: s.text, style: style);

    style = style.copyWith(
      color: MarkdownStyle.link,
      decoration: TextDecoration.underline,
      decorationColor: MarkdownStyle.link.withValues(alpha: 0.5),
    );
    final onTap = widget.onTapLink;
    if (onTap == null) return TextSpan(text: s.text, style: style);
    final recognizer = TapGestureRecognizer()..onTap = () => onTap(s.link!);
    _recognizers.add(recognizer);
    return TextSpan(
      text: s.text,
      style: style,
      recognizer: recognizer,
      mouseCursor: SystemMouseCursors.click,
    );
  }
}
