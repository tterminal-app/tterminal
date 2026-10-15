// 反白選取:cell 座標模型 + 從 grid 抽取文字(copy-on-select 用)。
//
// 選取採 xterm 式「行式」範圍(非矩形):中間行選滿整行,
// 首行從 start.col 起、末行到 end.col 止。文字抽取規則:
//   * CJK 寬字元只取一次(跳過 wideCharSpacer 佔位格)
//   * codepoint 0(空 cell)視為空白
//   * 每行行尾空白剔除(補滿的 padding 不該進剪貼簿)
//   * 行與行之間以 '\n' 相接

import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'term_ffi.dart';

/// grid 上的一個 cell 位置(顯示中的 viewport 座標)。
@immutable
class CellPos implements Comparable<CellPos> {
  const CellPos(this.row, this.col);

  final int row;
  final int col;

  @override
  int compareTo(CellPos other) =>
      row != other.row ? row - other.row : col - other.col;

  @override
  bool operator ==(Object other) =>
      other is CellPos && other.row == row && other.col == col;

  @override
  int get hashCode => Object.hash(row, col);

  @override
  String toString() => '($row,$col)';
}

/// 單一列上一段連續的 cell(兩端都包含)。painter 用它畫網址底線。
@immutable
class CellSpan {
  const CellSpan(this.row, this.startCol, this.endCol);

  final int row;
  final int startCol;
  final int endCol;

  @override
  bool operator ==(Object other) =>
      other is CellSpan &&
      other.row == row &&
      other.startCol == startCol &&
      other.endCol == endCol;

  @override
  int get hashCode => Object.hash(row, startCol, endCol);

  @override
  String toString() => '($row,$startCol..$endCol)';
}

/// 一段選取範圍。anchor = 按下處、focus = 拖曳到的位置;兩端都包含在內。
@immutable
class TermSelection {
  const TermSelection(this.anchor, this.focus);

  final CellPos anchor;
  final CellPos focus;

  /// 正規化:start 一定不在 end 之後(反向拖曳也成立)。
  CellPos get start => anchor.compareTo(focus) <= 0 ? anchor : focus;
  CellPos get end => anchor.compareTo(focus) <= 0 ? focus : anchor;

  bool get isCollapsed => anchor == focus;

  /// 此 cell 是否在選取範圍內(行式範圍,painter 反白用)。
  bool contains(int row, int col) {
    final s = start;
    final e = end;
    if (row < s.row || row > e.row) return false;
    if (s.row == e.row) return col >= s.col && col <= e.col;
    if (row == s.row) return col >= s.col;
    if (row == e.row) return col <= e.col;
    return true;
  }
}

/// 從 grid buffer(每 cell 4×u32:cp/fg/bg/flags)抽出選取文字。
String extractSelectionText(
  Uint32List cells,
  int cols,
  int rows,
  TermSelection sel,
) {
  final s = sel.start;
  final e = sel.end;
  final out = StringBuffer();
  var firstLine = true;
  for (var row = s.row; row <= e.row; row++) {
    if (row < 0 || row >= rows) continue;
    final c0 = (row == s.row ? s.col : 0).clamp(0, cols - 1);
    final c1 = (row == e.row ? e.col : cols - 1).clamp(0, cols - 1);
    final line = StringBuffer();
    for (var col = c0; col <= c1; col++) {
      final base = (row * cols + col) * 4;
      final flags = cells[base + 3];
      if (flags & CellFlags.wideCharSpacer != 0) continue;
      final cp = cells[base];
      line.writeCharCode(cp == 0 ? 0x20 : cp);
    }
    if (!firstLine) out.write('\n');
    firstLine = false;
    out.write(line.toString().trimRight());
  }
  return out.toString();
}
