// 手機版 shell(Termius 式畫面流)。
//
// 桌面的「置頂分頁列 + 檔案側窗 + 編輯器」不適合小螢幕;手機改成:
//   * 首頁 = connection list:進行中的連線 + Vault hosts(星號置頂、可搜尋
//     的完整管理走 Vaults 頁),點主機直接全螢幕開終端
//   * 終端頁 = 全螢幕 TerminalView(功能鍵工具列由 TerminalView 自帶),
//     返回 = 連線保留在背景;首頁的進行中卡片可回來或斷線
//
// 本地 shell 在手機上不存在(iOS 禁 fork/exec),所以沒有「空白終端分頁」。
//
// 大螢幕與折疊螢幕(iPhone Duo 內螢幕、iPad、Android foldable)改成兩欄:
// 左邊連線列、右邊終端(首頁右邊是提示)。書本式半開時以摺痕為界,
// 桌上型半開時終端在上半、操作區與鍵盤在下半(見 fold.dart)。

import 'package:flutter/material.dart';

import 'background_bridge.dart';
import 'fold.dart';
import 'host_key_mismatch_view.dart';
import 'l10n.dart';
import 'prefs.dart';
import 'settings_page.dart';
import 'ssh_connect.dart';
import 'tabs.dart';
import 'term_painter.dart';
import 'terminal_view.dart';
import 'vault_pages.dart';
import 'vault_service.dart';

class MobileShell extends StatefulWidget {
  const MobileShell({
    super.key,
    required this.tabs,
    required this.prefs,
    required this.vault,
    this.vaultError,
  });

  final TabsController tabs;
  final AppPrefs prefs;
  final VaultService? vault;
  final String? vaultError;

  @override
  State<MobileShell> createState() => _MobileShellState();
}

class _MobileShellState extends State<MobileShell> {
  final _viewKeys = <int, GlobalKey<TerminalViewState>>{};
  TerminalStyle? _styleCache;
  int _reportedConnections = -1;

  @override
  void initState() {
    super.initState();
    widget.tabs.addListener(_reportConnections);
    _reportConnections();
  }

  @override
  void dispose() {
    widget.tabs.removeListener(_reportConnections);
    super.dispose();
  }

  /// 活躍連線數(連線中或已建立且未結束)→ native 背景保活 / Live Activity。
  void _reportConnections() {
    final n = widget.tabs.tabs
        .where((t) => t.connecting || (t.session != null && !t.exited))
        .length;
    if (n == _reportedConnections) return;
    _reportedConnections = n;
    BackgroundBridge.reportConnectionCount(n);
  }

  TerminalStyle get _style {
    final size = widget.prefs.termFontSize;
    var s = _styleCache;
    if (s == null || s.fontSize != size) {
      s = _styleCache = TerminalStyle(fontSize: size);
    }
    return s;
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// 開一條 SSH 連線,回傳新分頁 id(失敗 null,錯誤已提示)。
  int? _connectTab(VaultRecord host) => connectSshHostTab(
    tabs: widget.tabs,
    vault: widget.vault,
    host: host,
    onError: _showError,
  );

  void _connect(VaultRecord host) {
    final id = _connectTab(host);
    if (id != null) _openTerminal(id);
  }

  void _openTerminal(int tabId) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _MobileTerminalPage(
          tabs: widget.tabs,
          prefs: widget.prefs,
          vault: widget.vault,
          vaultError: widget.vaultError,
          tabId: tabId,
          style: () => _style,
          viewKeyFor: (id) =>
              _viewKeys.putIfAbsent(id, () => GlobalKey<TerminalViewState>()),
          onFontZoom: (steps) =>
              widget.prefs.termFontSize = widget.prefs.termFontSize + steps,
          onConnectHost: _connectTab,
          onDisconnect: _disconnect,
        ),
      ),
    );
  }

  void _disconnect(int tabId) {
    _viewKeys.remove(tabId);
    widget.tabs.closeTab(tabId);
  }

  void _openVaults() {
    final vault = widget.vault;
    if (vault == null) {
      _showError(l10n.vaultOpenFailed(widget.vaultError ?? l10n.unknownError));
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => VaultsPage(
          service: vault,
          onConnectHost: (host) {
            Navigator.of(context).pop();
            _connect(host);
          },
        ),
      ),
    );
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsPage(
          service: widget.vault,
          prefs: widget.prefs,
          vaultError: widget.vaultError,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final vault = widget.vault;
    final list = ListenableBuilder(
      listenable: vault == null
          ? widget.tabs
          : Listenable.merge([widget.tabs, vault]),
      builder: (context, _) => _ConnectionList(
        tabs: widget.tabs,
        hosts: _sortedHosts(vault),
        vaultError: widget.vaultError,
        onOpen: _openTerminal,
        onClose: _disconnect,
        onConnect: _connect,
      ),
    );
    // body 橫跨整個視窗寬,直立摺痕的 x 可以直接比(橫向摺痕首頁不理)
    final panes = _TwoPane.layoutFor(
      context,
      Offset.zero & MediaQuery.sizeOf(context),
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('tterminal'),
        actions: [
          IconButton(
            key: const Key('btn-vaults'),
            tooltip: l10n.vaultsTooltipMobile,
            icon: const Icon(Icons.dns_outlined),
            onPressed: _openVaults,
          ),
          IconButton(
            key: const Key('btn-settings'),
            tooltip: l10n.settings,
            icon: const Icon(Icons.settings_outlined),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: panes == null
          ? SafeArea(child: list)
          : _TwoPane(
              layout: panes,
              leading: SafeArea(child: list),
              trailing: const _PickHint(),
            ),
    );
  }

  /// 與 Vaults 頁同慣例:星號置頂,其餘維持名稱排序。
  static List<VaultRecord> _sortedHosts(VaultService? vault) {
    if (vault == null) return const [];
    final all = vault.hosts;
    bool pinned(VaultRecord h) => h.data['pinned'] == true;
    return [...all.where(pinned), ...all.where((h) => !pinned(h))];
  }
}

/// 連線列:進行中的連線 + Vault hosts。首頁與終端頁的左欄共用。
class _ConnectionList extends StatelessWidget {
  const _ConnectionList({
    required this.tabs,
    required this.hosts,
    required this.vaultError,
    required this.onOpen,
    required this.onClose,
    required this.onConnect,
    this.selectedTabId,
  });

  final TabsController tabs;
  final List<VaultRecord> hosts;
  final String? vaultError;
  final void Function(int tabId) onOpen;
  final void Function(int tabId) onClose;
  final void Function(VaultRecord host) onConnect;

  /// 終端頁左欄:目前顯示中的連線反白。
  final int? selectedTabId;

  @override
  Widget build(BuildContext context) {
    final sessions = tabs.tabs;
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        if (sessions.isNotEmpty) ...[
          _SectionHeader(l10n.activeSessions),
          for (final tab in sessions)
            _SessionTile(
              key: ValueKey('session-${tab.id}'),
              tab: tab,
              selected: tab.id == selectedTabId,
              onOpen: () => onOpen(tab.id),
              onClose: () => onClose(tab.id),
            ),
          const SizedBox(height: 8),
        ],
        _SectionHeader(l10n.hosts),
        if (vaultError != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              l10n.vaultOpenFailed(vaultError!),
              style: const TextStyle(color: Color(0xFFFF6B6B)),
            ),
          )
        else if (hosts.isEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              l10n.mobileNoHosts,
              style: TextStyle(color: Colors.grey.shade500),
            ),
          )
        else
          for (final host in hosts)
            _HostTile(
              key: ValueKey('host-${host.id}'),
              host: host,
              onConnect: () => onConnect(host),
            ),
      ],
    );
  }
}

/// 左欄寬度與兩欄間隔(摺痕帶或分隔線);[fold] = 由書本式摺痕分欄。
typedef _PaneLayout = ({double leading, double gap, bool fold});

/// 連線列 + 內容的兩欄版面。
///
/// 每欄只保留自己那一側的 safe area:例如內螢幕橫放時狀態列在右緣,
/// 左欄不必跟著讓出那一塊。
class _TwoPane extends StatelessWidget {
  const _TwoPane({
    required this.layout,
    required this.leading,
    required this.trailing,
  });

  final _PaneLayout layout;
  final Widget leading;
  final Widget trailing;

  /// 寬螢幕(iPhone Duo 內螢幕攤平約 951pt、iPad)才分兩欄;
  /// 外螢幕、內螢幕直放(669pt)、分割畫面都維持單欄。
  static const wideBreakpoint = 840.0;
  static const sidebarWidth = 300.0;

  /// [area] 是本版面在視窗座標中的範圍。null = 單欄。
  ///
  /// 書本式半開(直立摺痕)時以摺痕為界——連列表文字都不壓在摺痕上;
  /// 攤平的寬螢幕則是固定寬的左欄。
  static _PaneLayout? layoutFor(BuildContext context, Rect area) {
    final book = FoldSplit.find(
      MediaQuery.displayFeaturesOf(context),
      area,
      only: Axis.vertical,
    );
    if (book != null) {
      return (leading: book.start, gap: book.end - book.start, fold: true);
    }
    if (area.width >= wideBreakpoint) {
      return (leading: sidebarWidth, gap: 1, fold: false);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: layout.leading,
          child: MediaQuery.removePadding(
            context: context,
            removeRight: true,
            child: leading,
          ),
        ),
        // 摺痕帶留空;寬螢幕時是 1px 分隔線
        Container(width: layout.gap, color: const Color(0xFF2A2A2A)),
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeLeft: true,
            child: trailing,
          ),
        ),
      ],
    );
  }
}

/// 首頁兩欄時右欄的提示。
class _PickHint extends StatelessWidget {
  const _PickHint();

  @override
  Widget build(BuildContext context) {
    final color = Colors.grey.shade600;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.terminal, size: 40, color: color),
          const SizedBox(height: 8),
          Text(l10n.pickConnectionHint, style: TextStyle(color: color)),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
    child: Text(
      title,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
        color: Colors.grey.shade400,
      ),
    ),
  );
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({
    super.key,
    required this.tab,
    required this.onOpen,
    required this.onClose,
    this.selected = false,
  });

  final TermTab tab;
  final VoidCallback onOpen;
  final VoidCallback onClose;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final subtitle = tab.connecting
        ? l10n.connecting
        : tab.error != null
        ? tab.error!
        : tab.exited
        ? l10n.ended
        : l10n.sessionConnected;
    return ListTile(
      selected: selected,
      leading: tab.connecting
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(
              tab.error != null || tab.exited
                  ? Icons.link_off
                  : Icons.terminal,
              color: tab.error != null ? const Color(0xFFFF6B6B) : null,
            ),
      title: Text(tab.displayTitle, overflow: TextOverflow.ellipsis),
      subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: IconButton(
        key: ValueKey('btn-close-${tab.id}'),
        tooltip: l10n.disconnectAndRemove,
        icon: const Icon(Icons.close),
        onPressed: onClose,
      ),
      onTap: onOpen,
    );
  }
}

class _HostTile extends StatelessWidget {
  const _HostTile({super.key, required this.host, required this.onConnect});

  final VaultRecord host;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    final data = host.data;
    final user = data['username'] as String? ?? '';
    final address = data['address'] as String? ?? '';
    final port = data['port'] ?? 22;
    final pinned = data['pinned'] == true;
    return ListTile(
      leading: Icon(
        pinned ? Icons.star : Icons.computer,
        color: pinned ? Colors.amber : null,
      ),
      title: Text(host.name, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        user.isEmpty ? '$address:$port' : '$user@$address:$port',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: onConnect,
    );
  }
}

/// 終端頁。版面依可用空間與摺痕:
///   * 一般(手機、外螢幕、內螢幕直放、分割畫面):全螢幕終端
///   * 寬螢幕(內螢幕攤平、iPad):左欄連線列 + 終端,左欄點一下就切連線;
///     連線列可以收起讓終端用滿(記在 prefs)
///   * 書本式半開(直立摺痕):摺痕左邊連線列、右邊終端
///   * 桌上型半開(橫向摺痕):終端在上半,操作區(工具列、叫鍵盤)在下半
/// 姿勢怎麼切,TerminalView 都掛同一把 GlobalKey → 狀態、焦點、IME 原地保留。
///
/// 返回 = 連線保留;斷線鈕 = 關閉這條連線(兩欄時切到另一條,沒有了才回首頁)。
class _MobileTerminalPage extends StatefulWidget {
  const _MobileTerminalPage({
    required this.tabs,
    required this.prefs,
    required this.vault,
    required this.vaultError,
    required this.tabId,
    required this.style,
    required this.viewKeyFor,
    required this.onFontZoom,
    required this.onConnectHost,
    required this.onDisconnect,
  });

  final TabsController tabs;
  final AppPrefs prefs;
  final VaultService? vault;
  final String? vaultError;
  final int tabId;
  final TerminalStyle Function() style;
  final GlobalKey<TerminalViewState> Function(int tabId) viewKeyFor;
  final void Function(int steps) onFontZoom;

  /// 回傳新分頁 id(失敗 null,錯誤已提示)。
  final int? Function(VaultRecord host) onConnectHost;
  final void Function(int tabId) onDisconnect;

  @override
  State<_MobileTerminalPage> createState() => _MobileTerminalPageState();
}

class _MobileTerminalPageState extends State<_MobileTerminalPage> {
  static const _background = Color(0xFF181818);
  static const _termPadding = EdgeInsets.symmetric(horizontal: 6, vertical: 4);

  late int _tabId = widget.tabId;

  /// 上一次版面是不是兩欄(目前的連線被關掉時決定切走還是回首頁)。
  bool _twoPane = false;

  TermTab? get _tab {
    for (final t in widget.tabs.tabs) {
      if (t.id == _tabId) return t;
    }
    return null;
  }

  void _select(int tabId) {
    if (tabId != _tabId) setState(() => _tabId = tabId);
  }

  void _connect(VaultRecord host) {
    final id = widget.onConnectHost(host);
    if (id != null) _select(id);
  }

  /// 目前的連線不見了(斷線鈕、左欄的 ×、從別處關掉):兩欄且還有別的連線
  /// 就切過去,否則回首頁。
  void _onTabGone() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _tab != null) return;
      final rest = widget.tabs.tabs;
      if (_twoPane && rest.isNotEmpty) {
        setState(() => _tabId = rest.last.id);
      } else {
        Navigator.of(context).maybePop();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final vault = widget.vault;
    return ListenableBuilder(
      listenable: Listenable.merge([widget.tabs, widget.prefs, ?vault]),
      builder: (context, _) {
        final tab = _tab;
        if (tab == null) {
          _onTabGone();
          return const Scaffold(
            backgroundColor: _background,
            body: SizedBox.shrink(),
          );
        }
        // 沒有 Scaffold.appBar → body 從視窗原點開始,摺痕座標可以直接比
        return Scaffold(
          backgroundColor: _background,
          body: LayoutBuilder(
            builder: (context, constraints) =>
                _layout(context, tab, Offset.zero & constraints.biggest),
          ),
        );
      },
    );
  }

  Widget _layout(BuildContext context, TermTab tab, Rect area) {
    final prefs = widget.prefs;
    var panes = _TwoPane.layoutFor(context, area);
    // 攤平的寬螢幕可以收起連線列讓終端用滿;書本式半開是摺痕在分欄,
    // 收起來終端就壓在摺痕上,所以不給收
    final collapsible = panes != null && !panes.fold;
    if (collapsible && prefs.connectionListCollapsed) panes = null;
    _twoPane = panes != null;
    final table = FoldSplit.find(
      MediaQuery.displayFeaturesOf(context),
      area,
      only: Axis.horizontal,
    );
    final terminal = _terminalPane(
      tab,
      area,
      table,
      showBack: panes == null,
      onExpandList: collapsible && panes == null
          ? () => prefs.connectionListCollapsed = false
          : null,
    );
    if (panes == null) return terminal;
    final vault = widget.vault;
    return _TwoPane(
      layout: panes,
      leading: Column(
        children: [
          AppBar(
            title: Text(l10n.connections),
            actions: [
              if (collapsible)
                IconButton(
                  key: const Key('btn-collapse-list'),
                  tooltip: l10n.hideConnectionList,
                  icon: const Icon(Icons.menu_open),
                  onPressed: () => prefs.connectionListCollapsed = true,
                ),
            ],
          ),
          Expanded(
            child: SafeArea(
              top: false,
              child: _ConnectionList(
                tabs: widget.tabs,
                hosts: _MobileShellState._sortedHosts(vault),
                vaultError: widget.vaultError,
                selectedTabId: _tabId,
                onOpen: _select,
                onClose: widget.onDisconnect,
                onConnect: _connect,
              ),
            ),
          ),
        ],
      ),
      trailing: terminal,
    );
  }

  /// AppBar + 終端。[table] 是橫向摺痕(視窗座標),交給 TerminalView 分上下。
  /// [onExpandList] 非 null = 連線列收起中,返回鈕旁邊放展開鈕。
  Widget _terminalPane(
    TermTab tab,
    Rect area,
    FoldSplit? table, {
    required bool showBack,
    VoidCallback? onExpandList,
  }) {
    return Column(
      children: [
        AppBar(
          automaticallyImplyLeading: showBack,
          leadingWidth: onExpandList == null ? null : 96,
          leading: onExpandList == null
              ? null
              : Row(
                  children: [
                    const BackButton(),
                    IconButton(
                      key: const Key('btn-expand-list'),
                      tooltip: l10n.showConnectionList,
                      icon: const Icon(Icons.menu),
                      onPressed: onExpandList,
                    ),
                  ],
                ),
          title: Text(tab.displayTitle, overflow: TextOverflow.ellipsis),
          actions: [
            IconButton(
              key: const Key('btn-disconnect'),
              tooltip: l10n.disconnect,
              icon: const Icon(Icons.power_settings_new),
              onPressed: () => widget.onDisconnect(_tabId),
            ),
          ],
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              // 這欄貼著視窗頂、這塊在最底:由剩下的高度反推它在視窗的 y,
              // 把摺痕換成 TerminalView 的本地座標
              final top =
                  area.height - constraints.maxHeight + _termPadding.top;
              final gap = table == null
                  ? null
                  : (top: table.start - top, bottom: table.end - top);
              return SafeArea(top: false, child: _terminalBody(tab, gap));
            },
          ),
        ),
      ],
    );
  }

  Widget _terminalBody(TermTab tab, ({double top, double bottom})? foldGap) {
    if (tab.connecting) {
      return const Center(child: CircularProgressIndicator());
    }
    if (tab.session == null && tab.hostKeyMismatch != null) {
      return HostKeyMismatchView(
        key: ValueKey('tab-hostkey-mismatch-${tab.id}'),
        tab: tab,
        tabs: widget.tabs,
        vault: widget.vault,
        onReconnect: () => widget.tabs.reconnect(tab.id),
      );
    }
    if (tab.session == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            l10n.connectFailedBody('${tab.error}'),
            style: const TextStyle(
              fontFamily: 'monospace',
              color: Color(0xFFFF6B6B),
            ),
          ),
        ),
      );
    }
    final tabId = tab.id;
    return Padding(
      padding: _termPadding,
      child: TerminalView(
        key: widget.viewKeyFor(tabId),
        session: tab.session!,
        style: widget.style(),
        foldGap: foldGap,
        onTitleChanged: (t) => widget.tabs.setTitle(tabId, t),
        onExit: () => widget.tabs.markExited(tabId),
        onFontZoom: widget.onFontZoom,
      ),
    );
  }
}
