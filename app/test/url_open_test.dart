// 終端畫面上的網址偵測(Cmd/Ctrl + click 開啟、hover 畫虛底線)。
//
// 重點在 grid 特性:長網址會被折成好幾列(WRAPLINE)、CJK 佔兩格、句尾標點
// 不屬於網址。spans 是底線畫在哪裡的依據,所以也要測。
// openUrl 這裡只測 scheme 白名單,真的去開瀏覽器不在測試範圍。

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tterm_app/src/selection.dart';
import 'package:tterm_app/src/term_ffi.dart';
import 'package:tterm_app/src/url_open.dart';

/// 把幾列文字塞成 grid buffer(每 cell 4×u32)。[wrapped] 裡的列會在最後一格
/// 帶上 WRAPLINE,表示它被折行、下一列是它的延續。
Uint32List gridOf(
  List<String> lines,
  int cols, {
  Set<int> wrapped = const {},
  Set<int> wideRows = const {},
}) {
  final rows = lines.length;
  final cells = Uint32List(rows * cols * 4);
  for (var r = 0; r < rows; r++) {
    final line = lines[r];
    for (var c = 0; c < cols; c++) {
      final base = (r * cols + c) * 4;
      cells[base] = c < line.length ? line.codeUnitAt(c) : 0;
    }
    if (wrapped.contains(r)) {
      // 終端是「寫滿最後一格才折行」,所以帶 WRAPLINE 的列一定是填滿的。
      // 測試資料留空格會讓網址中間多出空白,測到的就不是真實情況。
      assert(line.length == cols, '第 $r 列標了 WRAPLINE 卻沒填滿 $cols 欄');
      cells[(r * cols + cols - 1) * 4 + 3] |= CellFlags.wrapline;
    }
  }
  // wideRows:把該列第 0 格當成寬字元、第 1 格當成它的佔位格
  for (final r in wideRows) {
    cells[(r * cols + 1) * 4 + 3] |= CellFlags.wideCharSpacer;
  }
  return cells;
}

void main() {
  group('urlAt', () {
    test('點在網址上回傳網址,點在網址外回 null', () {
      const cols = 40;
      final cells = gridOf(['see https://example.com/a here'], cols);
      // "see " 佔 0..3,網址從 col 4 開始
      expect(urlAt(cells, cols, 1, 0, 4)?.url, 'https://example.com/a');
      expect(urlAt(cells, cols, 1, 0, 12)?.url, 'https://example.com/a');
      expect(urlAt(cells, cols, 1, 0, 24)?.url, 'https://example.com/a');
      expect(urlAt(cells, cols, 1, 0, 0), isNull, reason: '"see" 不是網址');
      expect(urlAt(cells, cols, 1, 0, 27), isNull, reason: '"here" 不是網址');
    });

    test('spans 標出網址佔到的 cell(hover 底線畫在這裡)', () {
      const cols = 40;
      final cells = gridOf(['see https://example.com/a here'], cols);
      // 網址是 col 4..24(含),長度 21
      expect(urlAt(cells, cols, 1, 0, 4)?.spans, [const CellSpan(0, 4, 24)]);
    });

    test('被折行的長網址要接回完整的一條(不能只抓到前半截)', () {
      // 19 欄剛好被第一段填滿 → 終端折行、第 0 列帶 WRAPLINE
      const cols = 19;
      final cells = gridOf([
        'https://example.com',
        '/very/long/path?a=1',
      ], cols, wrapped: {0});
      const want = 'https://example.com/very/long/path?a=1';
      expect(urlAt(cells, cols, 2, 0, 5)?.url, want, reason: '點在第一列');
      expect(urlAt(cells, cols, 2, 1, 5)?.url, want, reason: '點在折行後的第二列');
    });

    test('折行的網址 spans 一列一段(底線兩列都要畫)', () {
      const cols = 19;
      final cells = gridOf([
        'https://example.com',
        '/very/long/path?a=1',
      ], cols, wrapped: {0});
      expect(urlAt(cells, cols, 2, 0, 5)?.spans, [
        const CellSpan(0, 0, 18),
        const CellSpan(1, 0, 18),
      ]);
    });

    test('沒有 WRAPLINE 的相鄰兩列不會被接起來', () {
      const cols = 20;
      final cells = gridOf(['https://example.com', '/not/part/of/it'], cols);
      expect(urlAt(cells, cols, 2, 0, 5)?.url, 'https://example.com');
      expect(urlAt(cells, cols, 2, 1, 5), isNull);
    });

    test('句尾標點不算網址的一部分', () {
      const cols = 40;
      for (final tail in ['.', ',', '。', '!', '"']) {
        final cells = gridOf(['go https://example.com/a$tail'], cols);
        expect(
          urlAt(cells, cols, 1, 0, 10)?.url,
          'https://example.com/a',
          reason: '尾巴的 $tail 不該被吃進網址',
        );
      }
    });

    test('成對括號留著,包住網址的那個右括號剝掉', () {
      const cols = 46;
      final paired = gridOf(['x https://en.wikipedia.org/wiki/A_(B)'], cols);
      expect(
        urlAt(paired, cols, 1, 0, 10)?.url,
        'https://en.wikipedia.org/wiki/A_(B)',
      );

      final wrapping = gridOf(['x (https://example.com/a)'], cols);
      expect(urlAt(wrapping, cols, 1, 0, 10)?.url, 'https://example.com/a');
    });

    test('只認 http/https:file:// 之類不當成可點的網址', () {
      const cols = 40;
      for (final text in [
        'file:///etc/passwd',
        'smb://host/share',
        'javascript:alert(1)',
        'ftp://example.com/a',
      ]) {
        final cells = gridOf([text], cols);
        expect(urlAt(cells, cols, 1, 0, 3), isNull, reason: text);
      }
    });

    test('點在 CJK 寬字元的右半格上,不會錯位到別的字', () {
      const cols = 30;
      // 第 0 格是寬字元、第 1 格是它的佔位格,網址接在後面
      final cells = gridOf(['中 https://example.com/a'], cols, wideRows: {0});
      // 佔位格(col 1)往左退一格後仍不是網址
      expect(urlAt(cells, cols, 1, 0, 1), isNull);
      expect(urlAt(cells, cols, 1, 0, 5)?.url, 'https://example.com/a');
    });

    test('越界座標與空 grid 不會炸', () {
      const cols = 10;
      final cells = gridOf(['https://a.co'], cols);
      expect(urlAt(cells, cols, 1, -1, 0), isNull);
      expect(urlAt(cells, cols, 1, 0, -1), isNull);
      expect(urlAt(cells, cols, 1, 5, 0), isNull);
      expect(urlAt(cells, cols, 1, 0, 99), isNull);
      expect(urlAt(Uint32List(0), 0, 0, 0, 0), isNull);
    });
  });

  group('openUrl', () {
    test('非 http/https 一律拒絕(終端內容是不可信輸入)', () async {
      for (final url in [
        'file:///etc/passwd',
        'javascript:alert(1)',
        'smb://host/share',
        'ftp://example.com',
        'not a url',
        '',
      ]) {
        expect(await openUrl(url), isFalse, reason: url);
      }
    });
  });
}
