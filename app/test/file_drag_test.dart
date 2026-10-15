// FileDrag.startTempCopy:遠端檔案先寫暫存再拖(有 native 拖出的平台才作用,
// 目前是 Windows 與 macOS)。start() 內部會呼叫 native channel,在測試環境會吃到
// MissingPluginException 並被吞掉——所以這裡只驗證暫存檔的產生與檔名清理。

@TestOn('windows || mac-os')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tterm_app/src/file_drag.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('把 bytes 寫到暫存檔、檔名沿用、回傳路徑', () async {
    final bytes = [104, 105, 33]; // "hi!"
    final path = await FileDrag.startTempCopy('readme.txt', bytes);
    expect(path, isNotNull);
    final f = File(path!);
    addTearDown(() {
      if (f.existsSync()) f.deleteSync();
    });
    expect(f.existsSync(), isTrue);
    expect(f.readAsBytesSync(), bytes);
    expect(path, endsWith('readme.txt'));
  });

  test('檔名中的路徑分隔/非法字元會被清掉(不跳出暫存資料夾)', () async {
    final path = await FileDrag.startTempCopy('a/b\\c:d.txt', [1]);
    expect(path, isNotNull);
    final f = File(path!);
    addTearDown(() {
      if (f.existsSync()) f.deleteSync();
    });
    // 兩邊平台的分隔符都清成 '_',所以檔名本身不會再含任何分隔符
    final base = path.split(Platform.pathSeparator).last;
    expect(base, 'a_b_c_d.txt');
    expect(f.existsSync(), isTrue);
  });

  test('暫存檔放在系統暫存資料夾底下的 tterm-drag(不是硬編 Windows 路徑)', () async {
    final path = await FileDrag.startTempCopy('note.txt', [1]);
    expect(path, isNotNull);
    final f = File(path!);
    addTearDown(() {
      if (f.existsSync()) f.deleteSync();
    });
    final sep = Platform.pathSeparator;
    expect(path, startsWith('${Directory.systemTemp.path}${sep}tterm-drag$sep'));
  });
}
