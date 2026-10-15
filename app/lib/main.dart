// tterminal — 多分頁工作區 + Vault(Hosts/Keys)+ self-host 同步。
//
// 設環境變數 TTERM_DEMO=1 可切換到合成資料流的效能量測畫面;
// TTERM_DATA_DIR 可覆寫資料目錄(vault 與偏好設定)。

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'src/app_dirs.dart';
import 'src/app_shell.dart';
import 'src/demo_page.dart';
import 'src/fold.dart';
import 'src/l10n.dart';
import 'src/mobile_shell.dart';
import 'src/prefs.dart';
import 'src/tabs.dart';
import 'src/vault_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  FoldBridge.start();
  runApp(const TtermApp());
}

class TtermApp extends StatefulWidget {
  const TtermApp({super.key, this.demoMode});

  /// null = 依環境變數決定。
  final bool? demoMode;

  @override
  State<TtermApp> createState() => _TtermAppState();
}

class _TtermAppState extends State<TtermApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 字串走全域 l10n、不依賴 Localizations,MaterialApp 換 locale 不會讓它們
  /// 重建。系統語言很少在執行中切換,切了就整棵樹重建一次(狀態都保留)。
  @override
  void didChangeLocales(List<Locale>? locales) {
    setState(() {});
    void rebuild(Element e) {
      e.markNeedsBuild();
      e.visitChildren(rebuild);
    }

    (context as Element).visitChildren(rebuild);
  }

  @override
  Widget build(BuildContext context) {
    final demo = widget.demoMode ?? Platform.environment['TTERM_DEMO'] == '1';
    return MaterialApp(
      title: 'tterminal',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      locale: appLocale,
      supportedLocales: kAppSupportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      // 折疊螢幕的摺痕(iOS 由 native 量)→ MediaQuery.displayFeatures
      builder: (context, child) => FoldFeatures(child: child!),
      home: demo ? const DemoPage() : const ShellRoot(),
    );
  }
}

/// 建立長生命週期的服務(prefs / vault / tabs)並掛上 AppShell。
class ShellRoot extends StatefulWidget {
  const ShellRoot({super.key});

  @override
  State<ShellRoot> createState() => _ShellRootState();
}

class _ShellRootState extends State<ShellRoot> {
  late final AppPrefs _prefs;
  late final TabsController _tabs;
  VaultService? _vault;
  String? _vaultError;

  /// 手機用獨立的 connection list 畫面流(Termius 式),桌面用分頁工作區。
  static final bool _mobile = Platform.isIOS || Platform.isAndroid;

  @override
  void initState() {
    super.initState();
    final base = appBaseDir();
    _prefs = AppPrefs.loadSync(
      '$base${Platform.pathSeparator}prefs.json',
    );
    try {
      _vault = VaultService.open('$base${Platform.pathSeparator}vault');
      // 啟動時背景同步一次(未設定同步時是 no-op)
      unawaited(_vault!.syncNow());
    } catch (e) {
      _vaultError = '$e';
    }
    _tabs = TabsController(refillOnEmpty: !_mobile);
  }

  @override
  void dispose() {
    _tabs.dispose();
    _vault?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_mobile) {
      return MobileShell(
        tabs: _tabs,
        prefs: _prefs,
        vault: _vault,
        vaultError: _vaultError,
      );
    }
    return AppShell(
      tabs: _tabs,
      prefs: _prefs,
      vault: _vault,
      vaultError: _vaultError,
    );
  }
}
