// 終端畫面上的網址:Cmd(macOS)/ Ctrl + click 用系統瀏覽器開啟。
//
// 麻煩的是終端沒有「一行文字」這種東西,只有 grid。長網址會被折成好幾列,
// alacritty 把 WRAPLINE 設在**被折行那一列的最後一格**,所以要先把邏輯行接
// 回來才找得到完整網址,否則只會抓到前半截(然後開到一個不存在的頁面)。

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'selection.dart';
import 'term_ffi.dart';

/// 只認 http/https。終端內容是不可信的輸入——cat 一個檔案、遠端主機的輸出都會
/// 進到畫面上——file://、smb://、javascript: 之類交給系統開啟太危險。
///
/// 字元集排掉空白與 shell/引號類字元;`()` 有留著,維基百科之類的網址會用到,
/// 尾巴多出來的那個右括號由 [_trimTrailing] 處理。
final _urlPattern = RegExp(
  r'''https?://[^\s<>"'`\\^{}|\[\]]+''',
  caseSensitive: false,
);

/// 句子的標點常常緊貼在網址後面(「參考 https://a.com/b。」),那不屬於網址。
const _trailingPunctuation = '.,;:!?\'"、。,;:!?」』】〉》';

int _countChar(String s, String ch) {
  var n = 0;
  for (var i = 0; i < s.length; i++) {
    if (s[i] == ch) n++;
  }
  return n;
}

String _trimTrailing(String url) {
  var end = url.length;
  while (end > 0) {
    final ch = url[end - 1];
    if (_trailingPunctuation.contains(ch)) {
      end--;
      continue;
    }
    // 「(見 https://a.com/b)」的右括號要剝掉,但
    // 「https://x/wiki/A_(B)」的不能剝——看它前面有沒有落單的左括號在等配對
    // (比對的是不含這個 ')' 的部分,不然自己也被算進去,永遠是成對的)。
    if (ch == ')') {
      final body = url.substring(0, end - 1);
      if (_countChar(body, '(') <= _countChar(body, ')')) {
        end--;
        continue;
      }
    }
    break;
  }
  return url.substring(0, end);
}

bool _wrapsToNext(Uint32List cells, int cols, int row) =>
    cells[(row * cols + cols - 1) * 4 + 3] & CellFlags.wrapline != 0;

/// 畫面上一段可點的網址。
@immutable
class UrlHit {
  const UrlHit(this.url, this.spans);

  final String url;

  /// 網址覆蓋到的 cell。被折行時會有多段(一列一段),hover 底線要逐段畫。
  final List<CellSpan> spans;
}

/// grid 上 [row]/[col] 這個 cell 落在哪個網址裡?不在網址上回 null。
///
/// [cells] 是 `session.copyGrid()` 的 buffer(每 cell 4×u32:cp/fg/bg/flags)。
UrlHit? urlAt(Uint32List cells, int cols, int rows, int row, int col) {
  if (cols <= 0 || rows <= 0) return null;
  if (row < 0 || row >= rows || col < 0 || col >= cols) return null;
  if (cells.length < rows * cols * 4) return null;

  // 點在 CJK 寬字元的右半格上時,字元其實在左邊那一格
  var target = col;
  if (cells[(row * cols + col) * 4 + 3] & CellFlags.wideCharSpacer != 0 &&
      col > 0) {
    target = col - 1;
  }

  // 把被折行切開的邏輯行接回來
  var first = row;
  while (first > 0 && _wrapsToNext(cells, cols, first - 1)) {
    first--;
  }
  var last = row;
  while (last < rows - 1 && _wrapsToNext(cells, cols, last)) {
    last++;
  }

  // 逐 code unit 記下它來自哪個 cell:寬字元佔兩格、emoji 是 surrogate pair,
  // 兩邊都沒辦法從字串索引反算回 grid 座標。
  final text = StringBuffer();
  final rowOf = <int>[];
  final colOf = <int>[];
  for (var r = first; r <= last; r++) {
    for (var c = 0; c < cols; c++) {
      final base = (r * cols + c) * 4;
      if (cells[base + 3] & CellFlags.wideCharSpacer != 0) continue;
      final cp = cells[base];
      final ch = String.fromCharCode(cp == 0 ? 0x20 : cp);
      for (var i = 0; i < ch.length; i++) {
        rowOf.add(r);
        colOf.add(c);
      }
      text.write(ch);
    }
  }

  final line = text.toString();
  for (final m in _urlPattern.allMatches(line)) {
    final url = _trimTrailing(m.group(0)!);
    if (url.isEmpty) continue;
    final end = m.start + url.length;
    var onIt = false;
    for (var i = m.start; i < end; i++) {
      if (rowOf[i] == row && colOf[i] == target) {
        onIt = true;
        break;
      }
    }
    if (!onIt) continue;
    return UrlHit(url, _spansOf(rowOf, colOf, m.start, end));
  }
  return null;
}

/// 把 [start,end) 這段 code unit 佔到的 cell 收成「一列一段」,hover 底線用。
List<CellSpan> _spansOf(List<int> rowOf, List<int> colOf, int start, int end) {
  final spans = <CellSpan>[];
  var spanRow = rowOf[start];
  var spanStart = colOf[start];
  var spanEnd = colOf[start];
  for (var i = start + 1; i < end; i++) {
    if (rowOf[i] == spanRow) {
      spanEnd = colOf[i];
      continue;
    }
    spans.add(CellSpan(spanRow, spanStart, spanEnd));
    spanRow = rowOf[i];
    spanStart = colOf[i];
    spanEnd = colOf[i];
  }
  spans.add(CellSpan(spanRow, spanStart, spanEnd));
  return spans;
}

/// 用系統預設瀏覽器開啟 [url]。回傳是否成功交給系統(不代表頁面真的開起來)。
///
/// scheme 在這裡再擋一次:呼叫端可能不是 [urlAt](未來的右鍵選單之類),
/// 而放行 file://、javascript: 等於讓終端上的任意文字驅動系統。
Future<bool> openUrl(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasAuthority) return false;
  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return false;
  try {
    // 一律用參數陣列(不經 shell):網址裡的 &、?、" 才不會被再解釋一次。
    final (exe, args) = switch (Platform.operatingSystem) {
      'macos' => ('/usr/bin/open', [url]),
      // start 是 cmd 的內建指令,得經過 shell(引號規則很雷);rundll32 直接
      // 把網址當參數吃,不必擔心被 shell 再解析。
      'windows' => ('rundll32', ['url.dll,FileProtocolHandler', url]),
      _ => ('xdg-open', [url]),
    };
    final result = await Process.run(exe, args);
    return result.exitCode == 0;
  } catch (_) {
    // 系統上沒有 opener(裸 Linux 容器等):當作沒開成,呼叫端自己決定要不要提示
    return false;
  }
}
