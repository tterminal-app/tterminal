// 分頁模型與控制器:每個 tab 一個 terminal session。
// session 建立可注入(測試用 headless,正式用 spawnShell)。

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

import 'l10n.dart';
import 'term_ffi.dart';

class TermTab {
  TermTab(
    this.id, {
    this.session,
    this.error,
    this.connecting = false,
    this.noLocalShell = false,
    String? label,
    String? connInfo,
  })  : label = label ?? '',
        connInfo = connInfo ?? '';

  final int id;

  /// 本地 shell 立即建立;SSH session 連上後才 attach(在此之前為 null)。
  NativeSession? session;

  /// session 建立/連線失敗時的錯誤訊息(顯示在 tab 內容)。
  String? error;

  /// SSH 連線進行中(尚未 attach session)。
  bool connecting;

  /// 平台開不了本地 shell(iOS 禁 fork/exec)的導引分頁。
  final bool noLocalShell;

  /// 使用者可見的固定標籤(如 SSH host 名稱);OSC 標題會覆寫顯示。
  final String label;

  /// 連線資訊(SSH:`user@address:port`;本地為空字串)。狀態列顯示用。
  final String connInfo;

  /// 重新建立 session 的方法(本地=respawn shell、SSH=原設定重連);
  /// null = 不支援重連(iOS 無本地 shell 的導引分頁)。
  Future<NativeSession> Function()? connectFn;

  String title = '';
  bool exited = false;

  String get displayTitle {
    final base = title.isNotEmpty
        ? title
        : label.isNotEmpty
            ? label
            : l10n.tabTitleDefault(id);
    if (connecting) return l10n.tabTitleConnecting(base);
    return exited ? l10n.tabTitleEnded(base) : base;
  }
}

class TabsController extends ChangeNotifier {
  TabsController({NativeSession Function()? spawn, this.refillOnEmpty = true})
      : _spawn = spawn ?? _defaultSpawn;

  static NativeSession _defaultSpawn() =>
      NativeSession.spawnShell(cols: 100, rows: 30);

  final NativeSession Function() _spawn;

  /// 關掉最後一個分頁時是否自動補開(桌面工作區慣例);
  /// 手機的 connection list 沒有「空分頁」概念,設 false。
  final bool refillOnEmpty;
  final List<TermTab> tabs = [];
  int _active = 0;
  int _nextId = 1;
  bool _disposed = false;

  int get activeIndex => tabs.isEmpty ? 0 : _active.clamp(0, tabs.length - 1);
  TermTab? get active => tabs.isEmpty ? null : tabs[activeIndex];

  void ensureInitial() {
    if (tabs.isEmpty) newTab();
  }

  /// iOS 禁 fork/exec,openpty 直接 Operation not permitted;
  /// 分頁改顯示 SSH 導引(模擬器雖然開得起來,但行為跟實機一致才不誤導)。
  static final bool supportsLocalShell = !Platform.isIOS;

  TermTab newTab() {
    final id = _nextId++;
    TermTab tab;
    if (!supportsLocalShell) {
      tab = TermTab(id, noLocalShell: true);
    } else {
      try {
        tab = TermTab(id, session: _spawn());
      } catch (e) {
        tab = TermTab(id, error: '$e');
      }
      tab.connectFn = () async => _spawn();
    }
    tabs.add(tab);
    _active = tabs.length - 1;
    notifyListeners();
    return tab;
  }

  /// 開一個「連線中」的分頁,背景執行 [connect];成功 attach session,
  /// 失敗顯示錯誤。回傳分頁 id。
  int newAsyncTab(
    String label,
    Future<NativeSession> Function() connect, {
    String connInfo = '',
  }) {
    final id = _nextId++;
    final tab = TermTab(id, connecting: true, label: label, connInfo: connInfo);
    tab.connectFn = connect;
    tabs.add(tab);
    _active = tabs.length - 1;
    notifyListeners();
    _startConnect(tab);
    return id;
  }

  void _startConnect(TermTab tab) {
    final id = tab.id;
    tab.connectFn!().then((session) {
      final tab = _byId(id);
      if (tab == null) {
        session.dispose(); // 分頁在連線完成前被關掉了
        return;
      }
      tab.session = session;
      tab.connecting = false;
      notifyListeners();
    }).catchError((Object e) {
      final tab = _byId(id);
      if (tab == null) return;
      tab.error = '$e';
      tab.connecting = false;
      notifyListeners();
    });
  }

  /// 重新連線(已結束/連線失敗的分頁):丟掉舊 session,用原本的
  /// connectFn 重建(本地=respawn、SSH=原設定重連)。
  void reconnect(int id) {
    final tab = _byId(id);
    if (tab == null || tab.connecting || tab.connectFn == null) return;
    tab.session?.dispose();
    tab.session = null;
    tab.exited = false;
    tab.error = null;
    tab.title = '';
    tab.connecting = true;
    notifyListeners();
    _startConnect(tab);
  }

  TermTab? _byId(int id) => tabs.where((t) => t.id == id).firstOrNull;

  void closeTab(int id) {
    final index = tabs.indexWhere((t) => t.id == id);
    if (index < 0) return;
    final tab = tabs.removeAt(index);
    tab.session?.dispose();
    if (_active >= index && _active > 0) _active -= 1;
    if (tabs.isEmpty && refillOnEmpty) {
      // 桌面工作區:永遠保留至少一個分頁
      newTab();
      return;
    }
    notifyListeners();
  }

  void closeActive() {
    final tab = active;
    if (tab != null) closeTab(tab.id);
  }

  void activate(int index) {
    if (index < 0 || index >= tabs.length || index == _active) return;
    _active = index;
    notifyListeners();
  }

  /// 拖移重新排序:把第 [from] 個分頁移到第 [to] 個位置(移除後的索引,
  /// 不是 ReorderableListView 的插入點語意——呼叫端負責換算)。
  /// active 跟著原本那個分頁走,不會因為排序而換分頁。
  void reorder(int from, int to) {
    if (from < 0 || from >= tabs.length) return;
    final target = to.clamp(0, tabs.length - 1);
    if (target == from) return;
    final activeId = active?.id;
    tabs.insert(target, tabs.removeAt(from));
    if (activeId != null) {
      final i = tabs.indexWhere((t) => t.id == activeId);
      if (i >= 0) _active = i;
    }
    notifyListeners();
  }

  void next() => activate((activeIndex + 1) % tabs.length);
  void prev() => activate((activeIndex - 1 + tabs.length) % tabs.length);

  void setTitle(int id, String title) {
    final tab = tabs.where((t) => t.id == id).firstOrNull;
    if (tab == null || tab.title == title) return;
    tab.title = title;
    notifyListeners();
  }

  void markExited(int id) {
    final tab = tabs.where((t) => t.id == id).firstOrNull;
    if (tab == null || tab.exited) return;
    tab.exited = true;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final tab in tabs) {
      tab.session?.dispose();
    }
    tabs.clear();
    super.dispose();
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }
}
