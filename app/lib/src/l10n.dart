// 多語系入口:全域的 [l10n]。widget 跟沒有 BuildContext 的地方(錯誤訊息、
// controller、例外的 toString)都用它,不必一路傳 context。
//
// 語系跟著系統:PlatformDispatcher.locales 依偏好順序比對 app 有的語言
// (en / zh),都不合就用英文。中文只有繁體一份,任何中文變體(zh-Hans、
// zh-HK…)都顯示繁中,Material 內建字串也跟著用繁中。

import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/widgets.dart';

import '../l10n/app_localizations.dart';

export '../l10n/app_localizations.dart';

/// 繁體中文。Material / Cupertino 內建字串只給 `zh` 會拿到簡體,要明講 Hant。
const kTraditionalChinese = Locale.fromSubtags(
  languageCode: 'zh',
  scriptCode: 'Hant',
);

/// MaterialApp.supportedLocales:WidgetsApp 會拿明確指定的 locale 再跟這份
/// 比對一次,所以中文要列 Hant,不然會被比回 `zh`(簡體)。
const kAppSupportedLocales = [Locale('en'), kTraditionalChinese];

/// 把系統偏好語言清單解析成 app 用的語系。
Locale resolveAppLocale(List<Locale> preferred) {
  final match = basicLocaleListResolution(
    preferred,
    AppLocalizations.supportedLocales,
  );
  return match.languageCode == 'zh' ? kTraditionalChinese : match;
}

/// 固定語系(null = 跟系統)。測試預設設成繁中,見 test/flutter_test_config.dart。
@visibleForTesting
Locale? debugAppLocaleOverride;

/// 目前的 app 語系(MaterialApp.locale 也用這個)。
Locale get appLocale => debugAppLocaleOverride ?? _systemLocale();

List<Locale>? _lastPreferred;
Locale _lastResolved = const Locale('en');

Locale _systemLocale() {
  // 系統語言變了 PlatformDispatcher 會換一份新的 list,同一份就不必重算
  final preferred = PlatformDispatcher.instance.locales;
  if (!identical(preferred, _lastPreferred)) {
    _lastPreferred = preferred;
    _lastResolved = resolveAppLocale(preferred);
  }
  return _lastResolved;
}

AppLocalizations? _strings;
Locale? _stringsLocale;

/// 目前語系的字串表。
AppLocalizations get l10n {
  final locale = appLocale;
  if (locale != _stringsLocale) {
    _strings = lookupAppLocalizations(locale);
    _stringsLocale = locale;
  }
  return _strings!;
}
