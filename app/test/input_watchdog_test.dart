import 'package:flutter_test/flutter_test.dart';
import 'package:tterm_app/src/input_watchdog.dart';

void main() {
  // 假時鐘:偵測器同時看「字元數」與「持續多久」,不能真的等 30 秒
  late DateTime now;
  SpaceWatchdog make() => SpaceWatchdog(clock: () => now);

  setUp(() => now = DateTime(2026, 1, 1, 12));

  void type(SpaceWatchdog w, String text, {int times = 1, bool expectFire = false}) {
    var fired = false;
    for (var i = 0; i < times; i++) {
      now = now.add(const Duration(milliseconds: 500));
      if (w.observe(text)) fired = true;
    }
    expect(fired, expectFire);
  }

  group('SpaceWatchdog', () {
    test('正常打字(有空白)永遠不示警', () {
      final w = make();
      // 遠超過門檻的量,但每行都有空白
      type(w, 'git status --short ', times: 200);
      expect(w.fired, isFalse);
    });

    test('連續大量字元完全沒有空白 → 示警一次', () {
      final w = make();
      // 每次 10 個字元,250 門檻 → 第 25 次踩到;每次前進 2 秒,
      // 到那時已經過了 48 秒,30 秒的時間門檻也過得了
      var fired = 0;
      for (var i = 0; i < 40; i++) {
        now = now.add(const Duration(seconds: 2));
        if (w.observe('abcdefghij')) fired++;
      }
      expect(fired, 1, reason: '整個 session 只該提示一次');
      expect(w.fired, isTrue);
    });

    test('一瞬間貼一長串沒空白的東西不算(時間門檻擋掉)', () {
      final w = make();
      // 時間完全不前進:字元數夠了但不是「持續打了很久都沒空白」
      for (var i = 0; i < 40; i++) {
        expect(w.observe('0123456789abcdef'), isFalse);
      }
      expect(w.fired, isFalse);
    });

    test('中途出現空白就重新計數', () {
      final w = make();
      for (var i = 0; i < 20; i++) {
        now = now.add(const Duration(seconds: 1));
        expect(w.observe('abcdefghij'), isFalse);
      }
      now = now.add(const Duration(seconds: 1));
      expect(w.observe(' '), isFalse); // 空白 = 一切正常
      // 重新開始算,同樣的量不該再踩到門檻
      for (var i = 0; i < 20; i++) {
        now = now.add(const Duration(seconds: 1));
        expect(w.observe('abcdefghij'), isFalse);
      }
      expect(w.fired, isFalse);
    });

    test('全形空白也算空白(輸入法切全形不是這裡要抓的症狀)', () {
      final w = make();
      for (var i = 0; i < 40; i++) {
        now = now.add(const Duration(seconds: 1));
        expect(w.observe('abcdefghij　'), isFalse);
      }
      expect(w.fired, isFalse);
    });

    test('控制字元不計入字元數', () {
      final w = make();
      for (var i = 0; i < 60; i++) {
        now = now.add(const Duration(seconds: 1));
        expect(w.observe('\r\n\x1b\x7f'), isFalse);
      }
      expect(w.fired, isFalse);
    });
  });
}
