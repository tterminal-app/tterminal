// 本機偏好設定(裝置各自、不進同步):目前只有分頁列位置。
// 存 JSON 檔,同步讀寫(檔案極小,啟動時一次載入)。

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// 分頁列位置:上方橫向 / 側邊垂直。
enum TabBarPosition { top, side }

/// 側邊分頁列寬度的可拖拉範圍。
const double kSideTabMinWidth = 140;
const double kSideTabMaxWidth = 420;
const double kSideTabDefaultWidth = 208;

/// 檔案側窗寬度的可拖拉範圍。
const double kFilePaneMinWidth = 160;
const double kFilePaneMaxWidth = 560;
const double kFilePaneDefaultWidth = 260;

/// 編輯器 pane 寬度的可拖拉範圍。
const double kEditorPaneMinWidth = 240;
const double kEditorPaneMaxWidth = 800;
const double kEditorPaneDefaultWidth = 420;

/// 終端機字體大小的可調範圍。
const double kTermFontMinSize = 8;
const double kTermFontMaxSize = 40;
const double kTermFontDefaultSize = 14;

class AppPrefs extends ChangeNotifier {
  AppPrefs.loadSync(this._path) {
    try {
      final file = File(_path);
      if (file.existsSync()) {
        final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        _tabBarPosition = json['tabBarPosition'] == 'side'
            ? TabBarPosition.side
            : TabBarPosition.top;
        final w = (json['sideTabWidth'] as num?)?.toDouble();
        if (w != null) {
          _sideTabWidth = w.clamp(kSideTabMinWidth, kSideTabMaxWidth);
        }
        final fw = (json['filePaneWidth'] as num?)?.toDouble();
        if (fw != null) {
          _filePaneWidth = fw.clamp(kFilePaneMinWidth, kFilePaneMaxWidth);
        }
        final ew = (json['editorPaneWidth'] as num?)?.toDouble();
        if (ew != null) {
          _editorPaneWidth = ew.clamp(kEditorPaneMinWidth, kEditorPaneMaxWidth);
        }
        _filePaneVisible = json['filePaneVisible'] == true;
        _connectionListCollapsed = json['connectionListCollapsed'] == true;
        _trialIntroSeen = json['trialIntroSeen'] == true;
        final fs = (json['termFontSize'] as num?)?.toDouble();
        if (fs != null) {
          _termFontSize = fs.clamp(kTermFontMinSize, kTermFontMaxSize);
        }
      }
    } catch (_) {
      // 壞掉的 prefs 檔用預設值,不擋啟動
    }
  }

  final String _path;
  TabBarPosition _tabBarPosition = TabBarPosition.top;
  double _sideTabWidth = kSideTabDefaultWidth;
  double _filePaneWidth = kFilePaneDefaultWidth;
  double _editorPaneWidth = kEditorPaneDefaultWidth;
  bool _filePaneVisible = false;
  bool _connectionListCollapsed = false;
  bool _trialIntroSeen = false;
  double _termFontSize = kTermFontDefaultSize;

  TabBarPosition get tabBarPosition => _tabBarPosition;
  double get sideTabWidth => _sideTabWidth;
  double get filePaneWidth => _filePaneWidth;
  double get editorPaneWidth => _editorPaneWidth;
  bool get filePaneVisible => _filePaneVisible;

  /// 手機/平板寬螢幕終端頁的左側連線列收起來了(iPhone Duo 內螢幕攤平、iPad)。
  bool get connectionListCollapsed => _connectionListCollapsed;

  /// iOS 第一次開 app 自動跳出的試用說明已經看過了(之後只在開連線時才跳)。
  bool get trialIntroSeen => _trialIntroSeen;
  double get termFontSize => _termFontSize;

  set tabBarPosition(TabBarPosition value) {
    if (value == _tabBarPosition) return;
    _tabBarPosition = value;
    _save();
    notifyListeners();
  }

  set sideTabWidth(double value) {
    final clamped = value.clamp(kSideTabMinWidth, kSideTabMaxWidth);
    if (clamped == _sideTabWidth) return;
    _sideTabWidth = clamped;
    _save();
    notifyListeners();
  }

  set filePaneWidth(double value) {
    final clamped = value.clamp(kFilePaneMinWidth, kFilePaneMaxWidth);
    if (clamped == _filePaneWidth) return;
    _filePaneWidth = clamped;
    _save();
    notifyListeners();
  }

  set editorPaneWidth(double value) {
    final clamped = value.clamp(kEditorPaneMinWidth, kEditorPaneMaxWidth);
    if (clamped == _editorPaneWidth) return;
    _editorPaneWidth = clamped;
    _save();
    notifyListeners();
  }

  set filePaneVisible(bool value) {
    if (value == _filePaneVisible) return;
    _filePaneVisible = value;
    _save();
    notifyListeners();
  }

  set connectionListCollapsed(bool value) {
    if (value == _connectionListCollapsed) return;
    _connectionListCollapsed = value;
    _save();
    notifyListeners();
  }

  set trialIntroSeen(bool value) {
    if (value == _trialIntroSeen) return;
    _trialIntroSeen = value;
    _save();
    notifyListeners();
  }

  set termFontSize(double value) {
    final clamped = value.clamp(kTermFontMinSize, kTermFontMaxSize);
    if (clamped == _termFontSize) return;
    _termFontSize = clamped;
    _save();
    notifyListeners();
  }

  void _save() {
    try {
      final file = File(_path);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(jsonEncode({
        'tabBarPosition': _tabBarPosition == TabBarPosition.side ? 'side' : 'top',
        'sideTabWidth': _sideTabWidth,
        'filePaneWidth': _filePaneWidth,
        'editorPaneWidth': _editorPaneWidth,
        'filePaneVisible': _filePaneVisible,
        'connectionListCollapsed': _connectionListCollapsed,
        'trialIntroSeen': _trialIntroSeen,
        'termFontSize': _termFontSize,
      }));
    } catch (_) {
      // 寫入失敗不擋 UI(下次啟動回舊值)
    }
  }
}
