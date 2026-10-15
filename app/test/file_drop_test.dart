// 從檔案總管拖檔進來後的挑檔/落地邏輯(importDroppedFiles)。
// native OLE 那段沒法在測試環境跑,這裡專測純邏輯:跳資料夾、遠端擋大檔、
// place 例外歸到 skipped、檔名擷取。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tterm_app/src/file_drop.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tterm-drop');
    File('${tmp.path}/a.txt').writeAsStringSync('hi');
    File('${tmp.path}/big.bin').writeAsBytesSync(List.filled(2000, 0));
    Directory('${tmp.path}/sub').createSync();
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('檔案交給 place、資料夾略過', () {
    final placed = <String>[];
    final r = importDroppedFiles(
      ['${tmp.path}/a.txt', '${tmp.path}/sub'],
      remote: false,
      place: (name, f) => placed.add(name),
    );
    expect(placed, ['a.txt']);
    expect(r.done, 1);
    expect(r.skipped.single, contains('資料夾'));
  });

  test('遠端:超過上限的檔案略過(太大)', () {
    final placed = <String>[];
    final r = importDroppedFiles(
      ['${tmp.path}/a.txt', '${tmp.path}/big.bin'],
      remote: true,
      maxRemoteBytes: 1000, // big.bin=2000 > 1000
      place: (name, f) => placed.add(name),
    );
    expect(placed, ['a.txt']);
    expect(r.done, 1);
    expect(r.skipped.single, contains('太大'));
  });

  test('上限只擋遠端,本地複製不受限', () {
    final placed = <String>[];
    final r = importDroppedFiles(
      ['${tmp.path}/big.bin'],
      remote: false,
      maxRemoteBytes: 1000,
      place: (name, f) => placed.add(name),
    );
    expect(placed, ['big.bin']);
    expect(r.done, 1);
    expect(r.skipped, isEmpty);
  });

  test('place 丟例外 → 記進 skipped,且附上原因', () {
    final r = importDroppedFiles(
      ['${tmp.path}/a.txt'],
      remote: false,
      place: (name, f) => throw Exception('boom'),
    );
    expect(r.done, 0);
    expect(r.skipped.single, contains('a.txt'));
    expect(r.skipped.single, contains('boom'), reason: '原因要讓使用者看得到');
  });

  test('dropBaseName:Windows 與 POSIX 路徑都取到檔名', () {
    expect(dropBaseName(r'C:\Users\alice\a.txt'), 'a.txt');
    expect(dropBaseName('/home/tester/readme.txt'), 'readme.txt');
  });
}
