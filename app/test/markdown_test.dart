// Markdown 預覽:區塊/行內解析,與 MarkdownView 畫出來的結果。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tterm_app/src/markdown_view.dart';

/// 取出解析結果裡第 [i] 個區塊,型別不對就直接失敗(測試讀起來短一點)。
T blockAt<T extends MdBlock>(List<MdBlock> bs, int i) {
  expect(bs[i], isA<T>(), reason: '第 $i 個區塊型別不對:${bs[i]}');
  return bs[i] as T;
}

void main() {
  group('區塊解析', () {
    test('標題:# 數量 = 層級,收尾的 # 去掉', () {
      final bs = parseMarkdown('# 一\n\n### 三 ###\n');
      expect(bs.length, 2);
      expect(blockAt<MdHeading>(bs, 0).level, 1);
      expect(blockAt<MdHeading>(bs, 0).text, '一');
      expect(blockAt<MdHeading>(bs, 1).level, 3);
      expect(blockAt<MdHeading>(bs, 1).text, '三');
    });

    test('段落:連續行併成一段,空行分段', () {
      final bs = parseMarkdown('第一行\n第二行\n\n另一段');
      expect(bs.length, 2);
      expect(blockAt<MdParagraph>(bs, 0).text, '第一行第二行');
      expect(blockAt<MdParagraph>(bs, 1).text, '另一段');
    });

    test('軟換行:英文補空白、中文不補、行尾兩空白才真的換行', () {
      // 原始碼硬折到 80 欄的段落要能還原成一段
      expect(
        blockAt<MdParagraph>(parseMarkdown('hello\nworld'), 0).text,
        'hello world',
      );
      expect(
        blockAt<MdParagraph>(parseMarkdown('中文\n接續'), 0).text,
        '中文接續',
      );
      expect(
        blockAt<MdParagraph>(parseMarkdown('中文 mixed\nnext 行'), 0).text,
        '中文 mixed next 行',
      );
      expect(
        blockAt<MdParagraph>(parseMarkdown('第一行  \n第二行'), 0).text,
        '第一行\n第二行',
      );
      expect(
        blockAt<MdParagraph>(parseMarkdown('第一行\\\n第二行'), 0).text,
        '第一行\n第二行',
      );
    });

    test('圍欄程式區塊:保留原樣、帶語言,內容不被當語法', () {
      final bs = parseMarkdown('```dart\nvoid main() {}\n# 不是標題\n```\n後面');
      final code = blockAt<MdCode>(bs, 0);
      expect(code.lang, 'dart');
      expect(code.text, 'void main() {}\n# 不是標題');
      expect(blockAt<MdParagraph>(bs, 1).text, '後面');
    });

    test('圍欄沒收尾:吃到檔尾(編輯到一半的檔案)', () {
      final bs = parseMarkdown('```\nabc\ndef');
      expect(bs.length, 1);
      expect(blockAt<MdCode>(bs, 0).text, 'abc\ndef');
    });

    test('清單:巢狀層數、有序編號、待辦勾選', () {
      final bs = parseMarkdown(
        '- 外層\n  - 內層\n- 回外層\n\n1. 一\n2. 二\n\n- [ ] 待辦\n- [x] 完成',
      );
      expect(blockAt<MdListItem>(bs, 0).depth, 0);
      expect(blockAt<MdListItem>(bs, 1).depth, 1);
      expect(blockAt<MdListItem>(bs, 1).text, '內層');
      expect(blockAt<MdListItem>(bs, 2).depth, 0);

      final ordered = blockAt<MdListItem>(bs, 3);
      expect(ordered.ordered, isTrue);
      expect(ordered.number, 1);

      expect(blockAt<MdListItem>(bs, 5).checked, isFalse);
      expect(blockAt<MdListItem>(bs, 5).text, '待辦');
      expect(blockAt<MdListItem>(bs, 6).checked, isTrue);
    });

    test('清單項續行併進同一項', () {
      final bs = parseMarkdown('- 第一項\n  接下去的說明\n- 第二項');
      expect(blockAt<MdListItem>(bs, 0).text, '第一項接下去的說明');
      expect(blockAt<MdListItem>(bs, 1).text, '第二項');
      final en = parseMarkdown('- first\n  more words');
      expect(blockAt<MdListItem>(en, 0).text, 'first more words');
    });

    test('引言:內容再解析一次(裡面的標題還是標題)', () {
      final bs = parseMarkdown('> ## 注意\n> 內文');
      final quote = blockAt<MdQuote>(bs, 0);
      expect(blockAt<MdHeading>(quote.children, 0).text, '注意');
      expect(blockAt<MdParagraph>(quote.children, 1).text, '內文');
    });

    test('水平線 vs 清單:--- 是線,- 是項目', () {
      final bs = parseMarkdown('---\n\n- 項目\n\n***');
      expect(bs[0], isA<MdRule>());
      expect(bs[1], isA<MdListItem>());
      expect(bs[2], isA<MdRule>());
    });

    test('表格:第一列是表頭,分隔列不算資料', () {
      final bs = parseMarkdown('| a | b |\n| --- | ---: |\n| 1 | 2 |\n| 3 | 4 |');
      final t = blockAt<MdTable>(bs, 0);
      expect(t.header, ['a', 'b']);
      expect(t.rows, [
        ['1', '2'],
        ['3', '4'],
      ]);
    });

    test('沒支援的語法退化成文字,不會被吞掉', () {
      final bs = parseMarkdown('底線標題\n=======');
      expect(bs.whereType<MdParagraph>().length, 1);
      expect(blockAt<MdParagraph>(bs, 0).text, contains('底線標題'));
    });
  });

  group('行內解析', () {
    List<MdSpan> spans(String src) => parseInline(src);
    MdSpan spanOf(String src, String text) =>
        spans(src).firstWhere((s) => s.text == text);

    test('粗體/斜體/粗斜體', () {
      expect(spanOf('這是 **粗** 字', '粗').bold, isTrue);
      expect(spanOf('這是 *斜* 字', '斜').italic, isTrue);
      final both = spanOf('***都要***', '都要');
      expect(both.bold, isTrue);
      expect(both.italic, isTrue);
    });

    test('行內程式碼不再解析裡面的符號', () {
      final s = spanOf('用 `a * b` 相乘', 'a * b');
      expect(s.code, isTrue);
      expect(s.italic, isFalse);
    });

    test('刪除線', () {
      expect(spanOf('~~刪掉~~', '刪掉').strike, isTrue);
    });

    test('連結:文字可點,網址帶著走', () {
      final s = spanOf('看 [官網](https://example.com) 說明', '官網');
      expect(s.link, 'https://example.com');
      // 其他文字不會變成連結
      expect(spanOf('看 [官網](https://example.com) 說明', ' 說明').link, isNull);
    });

    test('autolink 與裸網址都變連結', () {
      expect(spanOf('<https://a.dev>', 'https://a.dev').link, 'https://a.dev');
      final bare = spans('去 https://b.dev/x?y=1 看看');
      expect(bare.any((s) => s.link == 'https://b.dev/x?y=1'), isTrue);
    });

    test('裸網址結尾的句號不算網址的一部分', () {
      final s = spans('見 https://a.dev/x.').firstWhere((s) => s.link != null);
      expect(s.link, 'https://a.dev/x');
    });

    test('snake_case 不會被當成斜體', () {
      final s = parseInline('some_long_name 照原樣');
      expect(s.every((x) => !x.italic), isTrue);
      expect(s.map((x) => x.text).join(), 'some_long_name 照原樣');
    });

    test('落單的符號當普通字元,內容不會被吃掉', () {
      expect(parseInline('2 * 3 = 6').map((s) => s.text).join(), '2 * 3 = 6');
      expect(parseInline('未閉合的 **粗體').map((s) => s.text).join(), '未閉合的 **粗體');
    });

    test('反斜線轉義', () {
      final s = parseInline(r'\*不是斜體\*');
      expect(s.map((x) => x.text).join(), '*不是斜體*');
      expect(s.every((x) => !x.italic), isTrue);
    });

    test('圖片只留替代文字', () {
      final s = parseInline('![截圖](a.png)');
      expect(s.single.text, contains('截圖'));
      expect(s.single.link, isNull);
    });
  });

  group('MarkdownView', () {
    Future<void> pump(WidgetTester tester, String src,
        {void Function(String)? onTapLink}) async {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
          body: MarkdownView(source: src, onTapLink: onTapLink),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('畫出標題、清單、程式碼,markdown 符號本身不出現', (tester) async {
      await pump(tester, '# 標題\n\n- 項目\n\n```\ncode();\n```');
      expect(find.textContaining('標題'), findsWidgets);
      expect(find.textContaining('code();'), findsOneWidget);
      // 內文不該還留著 '# '
      expect(find.textContaining('# 標題'), findsNothing);
    });

    testWidgets('點連結呼叫 onTapLink', (tester) async {
      String? tapped;
      await pump(tester, '[官網](https://example.com)',
          onTapLink: (u) => tapped = u);
      // Text 的框是整行寬,文字只佔左邊一小段 → 點框中心會落在空白處
      final origin = tester.getTopLeft(find.textContaining('官網'));
      await tester.tapAt(origin + const Offset(6, 8));
      await tester.pump();
      expect(tapped, 'https://example.com');
    });

    testWidgets('換 source 會重畫', (tester) async {
      await pump(tester, '# 舊');
      expect(find.textContaining('舊'), findsWidgets);
      await pump(tester, '# 新');
      expect(find.textContaining('新'), findsWidgets);
      expect(find.textContaining('舊'), findsNothing);
    });
  });
}
