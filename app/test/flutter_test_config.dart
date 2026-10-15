// 所有測試的共同設定(flutter_test 自動套用)。
//
// 字串預設用繁中:既有測試多半是拿畫面上的中文去找 widget,不該跟著跑測試
// 那台機器的系統語言變。要測英文的自己把 debugAppLocaleOverride 換掉、
// 結束時換回來(見 l10n_test.dart)。

import 'dart:async';

import 'package:tterm_app/src/l10n.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  debugAppLocaleOverride = kTraditionalChinese;
  await testMain();
}
