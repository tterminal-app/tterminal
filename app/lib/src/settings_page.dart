// 設定頁:分頁列位置 + 同步(建立/配對匯入匯出/立即同步/停用)。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'l10n.dart';
import 'prefs.dart';
import 'vault_service.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.service,
    required this.prefs,
    this.vaultError,
  });

  final VaultService? service;
  final AppPrefs prefs;
  final String? vaultError;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  static final bool _mobile = Platform.isIOS || Platform.isAndroid;

  final _serverCtl = TextEditingController(text: 'http://');
  bool _busy = false;

  @override
  void dispose() {
    _serverCtl.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(l10n.settings)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 手機版是 connection list 畫面流,沒有分頁列可以擺
          if (!_mobile) ...[
            _sectionTitle(context, l10n.tabBarPosition),
            ListenableBuilder(
              listenable: widget.prefs,
              builder: (context, _) => RadioGroup<TabBarPosition>(
                groupValue: widget.prefs.tabBarPosition,
                onChanged: (v) => widget.prefs.tabBarPosition = v!,
                child: Column(children: [
                  RadioListTile<TabBarPosition>(
                    key: const Key('radio-tabs-top'),
                    title: Text(l10n.tabBarTop),
                    value: TabBarPosition.top,
                  ),
                  RadioListTile<TabBarPosition>(
                    key: const Key('radio-tabs-side'),
                    title: Text(l10n.tabBarSide),
                    value: TabBarPosition.side,
                  ),
                ]),
              ),
            ),
            const Divider(height: 32),
          ],
          _sectionTitle(context, l10n.terminalFontSize),
          ListenableBuilder(
            listenable: widget.prefs,
            builder: (context, _) => _fontSizeSection(context),
          ),
          const Divider(height: 32),
          _sectionTitle(context, l10n.syncSection),
          if (widget.service == null)
            ListTile(
              leading: const Icon(Icons.error_outline, color: Colors.orange),
              title: Text(l10n.vaultOpenFailedTitle),
              subtitle: Text(widget.vaultError ?? l10n.unknownError),
            )
          else
            ListenableBuilder(
              listenable: widget.service!,
              builder: (context, _) => _syncSection(widget.service!),
            ),
        ],
      ),
    );
  }

  Widget _sectionTitle(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(text, style: Theme.of(context).textTheme.titleMedium),
  );

  Widget _fontSizeSection(BuildContext context) {
    final prefs = widget.prefs;
    final size = prefs.termFontSize;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        IconButton(
          key: const Key('btn-font-smaller'),
          tooltip: l10n.fontSmaller,
          icon: const Icon(Icons.remove, size: 18),
          onPressed: size <= kTermFontMinSize
              ? null
              : () => prefs.termFontSize = size - 1,
        ),
        Expanded(
          child: Slider(
            key: const Key('font-size-slider'),
            value: size,
            min: kTermFontMinSize,
            max: kTermFontMaxSize,
            divisions: (kTermFontMaxSize - kTermFontMinSize).round(),
            label: '${size.round()}',
            onChanged: (v) => prefs.termFontSize = v,
          ),
        ),
        IconButton(
          key: const Key('btn-font-bigger'),
          tooltip: l10n.fontLarger,
          icon: const Icon(Icons.add, size: 18),
          onPressed: size >= kTermFontMaxSize
              ? null
              : () => prefs.termFontSize = size + 1,
        ),
        SizedBox(
          width: 48,
          child: Text(
            '${size.round()} pt',
            key: const Key('font-size-label'),
            textAlign: TextAlign.end,
          ),
        ),
        const SizedBox(width: 8),
        TextButton(
          key: const Key('btn-font-reset'),
          onPressed: size == kTermFontDefaultSize
              ? null
              : () => prefs.termFontSize = kTermFontDefaultSize,
          child: Text(l10n.reset),
        ),
      ]),
      Padding(
        padding: const EdgeInsets.only(left: 12, top: 2),
        child: Text(
          l10n.fontSizeHint,
          style: const TextStyle(fontSize: 12, color: Color(0xFF9E9E9E)),
        ),
      ),
    ]);
  }

  Widget _syncSection(VaultService service) {
    if (!service.syncConfigured) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(l10n.syncNotConfigured),
        ),
        TextField(
          key: const Key('sync-server'),
          controller: _serverCtl,
          decoration: InputDecoration(
            labelText: l10n.syncServerLabel,
            hintText: 'http://192.168.1.10:8722',
          ),
        ),
        const SizedBox(height: 12),
        Row(children: [
          FilledButton.icon(
            key: const Key('btn-enable-sync'),
            onPressed: _busy
                ? null
                : () => _run(() => service.enableSync(_serverCtl.text)),
            icon: const Icon(Icons.cloud_upload_outlined, size: 18),
            label: Text(l10n.setUpSync),
          ),
          const SizedBox(width: 12),
          OutlinedButton.icon(
            key: const Key('btn-import-pairing'),
            onPressed: _busy ? null : () => _importPairingDialog(service),
            icon: const Icon(Icons.link, size: 18),
            label: Text(l10n.joinWithPairing),
          ),
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(left: 12),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
        ]),
      ]);
    }

    final status = service.syncing
        ? l10n.syncing
        : service.lastSyncError != null
            ? l10n.syncFailed(service.lastSyncError!)
            : service.lastSyncAt != null
                ? l10n.lastSynced(_fmtTime(service.lastSyncAt!))
                : l10n.notSyncedYet;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.cloud_done_outlined),
        title: Text(service.syncServer!),
        subtitle: Text(
          'Vault ${service.vaultId.substring(0, 8)}…  ·  '
          '$status'
          '${service.dirtyCount > 0 ? '  ·  ${l10n.pendingChanges(service.dirtyCount)}' : ''}',
          key: const Key('sync-status'),
        ),
      ),
      Wrap(spacing: 12, runSpacing: 8, children: [
        FilledButton.icon(
          key: const Key('btn-sync-now'),
          onPressed:
              service.syncing ? null : () => _run(() => service.syncNow()),
          icon: const Icon(Icons.sync, size: 18),
          label: Text(l10n.syncNow),
        ),
        OutlinedButton.icon(
          key: const Key('btn-export-pairing'),
          onPressed: () => _exportPairingDialog(service),
          icon: const Icon(Icons.ios_share, size: 18),
          label: Text(l10n.exportPairing),
        ),
        OutlinedButton.icon(
          key: const Key('btn-disable-sync'),
          onPressed: () => _disableSyncDialog(service),
          icon: const Icon(Icons.link_off, size: 18),
          label: Text(l10n.turnOffSync),
        ),
      ]),
    ]);
  }

  static String _fmtTime(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';

  Future<void> _importPairingDialog(VaultService service) async {
    final ctl = TextEditingController();
    final pairing = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.pastePairingTitle),
        content: SizedBox(
          width: 460,
          child: TextField(
            key: const Key('pairing-input'),
            controller: ctl,
            maxLines: 4,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            decoration: const InputDecoration(hintText: 'TTERMSYNC1:...'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            key: const Key('btn-confirm-import'),
            onPressed: () => Navigator.pop(context, ctl.text.trim()),
            child: Text(l10n.join),
          ),
        ],
      ),
    );
    if (pairing == null || pairing.isEmpty) return;
    await _run(() async {
      final summary = await service.importPairing(pairing);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
            l10n.joinedVault((summary['carried'] as num?)?.toInt() ?? 0),
          ),
        ));
      }
    });
  }

  Future<void> _exportPairingDialog(VaultService service) async {
    final String pairing;
    try {
      pairing = service.exportPairing();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      return;
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.pairingStringTitle),
        content: SizedBox(
          width: 460,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(l10n.pairingWarning),
            const SizedBox(height: 12),
            SelectableText(
              pairing,
              key: const Key('pairing-output'),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ]),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.close),
          ),
          FilledButton.icon(
            key: const Key('btn-copy-pairing'),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: pairing));
              if (context.mounted) Navigator.pop(context);
            },
            icon: const Icon(Icons.copy, size: 18),
            label: Text(l10n.copy),
          ),
        ],
      ),
    );
  }

  Future<void> _disableSyncDialog(VaultService service) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.turnOffSync),
        content: Text(l10n.turnOffSyncBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            key: const Key('btn-confirm-disable'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.turnOff),
          ),
        ],
      ),
    );
    if (ok == true) await _run(() => service.disableSync());
  }
}
