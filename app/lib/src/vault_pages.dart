// Vaults 管理頁:Hosts / Keys 兩個分頁,CRUD 走 VaultService。
// 欄位 schema 見 docs/vault-sync-design.md §1.2。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'l10n.dart';
import 'term_ffi.dart';
import 'vault_service.dart';

class VaultsPage extends StatelessWidget {
  const VaultsPage({super.key, required this.service, this.onConnectHost});

  final VaultService service;

  /// 按 Host 的連線鈕時呼叫(null = 連線功能不可用,鈕會 disabled)。
  final void Function(VaultRecord host)? onConnectHost;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(l10n.vaults),
          bottom: TabBar(tabs: [
            Tab(text: l10n.hosts),
            Tab(text: l10n.keys),
          ]),
        ),
        body: TabBarView(children: [
          _HostsTab(service: service, onConnectHost: onConnectHost),
          _KeysTab(service: service),
        ]),
      ),
    );
  }
}

Future<bool> _confirmDelete(BuildContext context, String name) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(l10n.delete),
      content: Text(l10n.deleteConfirm(name)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          key: const Key('btn-confirm-delete'),
          onPressed: () => Navigator.pop(context, true),
          child: Text(l10n.delete),
        ),
      ],
    ),
  );
  return result ?? false;
}

// ---- Hosts ----

class _HostsTab extends StatefulWidget {
  const _HostsTab({required this.service, this.onConnectHost});

  final VaultService service;
  final void Function(VaultRecord host)? onConnectHost;

  @override
  State<_HostsTab> createState() => _HostsTabState();
}

class _HostsTabState extends State<_HostsTab> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _matches(VaultRecord host, String query) {
    if (query.isEmpty) return true;
    final data = host.data;
    return [
      host.name,
      data['address'] as String? ?? '',
      data['username'] as String? ?? '',
      data['note'] as String? ?? '',
    ].join('\n').toLowerCase().contains(query);
  }

  void _togglePin(VaultRecord host) {
    final data = Map<String, dynamic>.from(host.data);
    if (data['pinned'] == true) {
      data.remove('pinned');
    } else {
      data['pinned'] = true;
    }
    widget.service
        .upsert(id: host.id, kind: 'host', name: host.name, data: data);
  }

  @override
  Widget build(BuildContext context) {
    final service = widget.service;
    final onConnectHost = widget.onConnectHost;
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final all = service.hosts;
        final query = _search.text.trim().toLowerCase();
        bool pinned(VaultRecord h) => h.data['pinned'] == true;
        // 置頂的排前面;兩群各自維持 snapshot 的名稱排序。
        final hosts = [
          ...all.where((h) => pinned(h) && _matches(h, query)),
          ...all.where((h) => !pinned(h) && _matches(h, query)),
        ];
        return Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(children: [
              Expanded(
                child: TextField(
                  key: const Key('host-search'),
                  controller: _search,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: l10n.hostSearchHint,
                    prefixIcon: const Icon(Icons.search, size: 20),
                    isDense: true,
                    border: const OutlineInputBorder(),
                    suffixIcon: query.isEmpty
                        ? null
                        : IconButton(
                            key: const Key('btn-clear-host-search'),
                            tooltip: l10n.clear,
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () => setState(_search.clear),
                          ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                key: const Key('btn-add-host'),
                onPressed: () => _editHost(context, service),
                icon: const Icon(Icons.add, size: 18),
                label: Text(l10n.addHost),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Row(children: [
              Text(
                query.isEmpty
                    ? l10n.hostCount(all.length)
                    : l10n.hostCountFiltered(hosts.length, all.length),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ]),
          ),
          Expanded(
            child: all.isEmpty
                ? Center(child: Text(l10n.hostsEmpty))
                : hosts.isEmpty
                    ? Center(child: Text(l10n.hostsNoMatch))
                    : ListView.builder(
                        itemCount: hosts.length,
                        itemBuilder: (context, i) {
                          final host = hosts[i];
                          final data = host.data;
                          final auth =
                              (data['auth'] as Map?)?.cast<String, dynamic>();
                          final method =
                              auth?['method'] as String? ?? 'password';
                          final keyName = method == 'key'
                              ? (service
                                      .byId(auth?['keyId'] as String?)
                                      ?.name ??
                                  l10n.keyDeleted)
                              : null;
                          final isPinned = pinned(host);
                          return ListTile(
                            key: ValueKey('host-${host.id}'),
                            leading: const Icon(Icons.dns_outlined),
                            title: Text(host.name),
                            subtitle: Text(
                              '${data['username'] ?? ''}@${data['address']}:'
                              '${data['port'] ?? 22}'
                              '${keyName != null ? '  ·  ${l10n.hostKeyName(keyName)}' : ''}'
                              '${method == 'password' ? '  ·  ${l10n.password}' : ''}',
                            ),
                            onTap: () =>
                                _editHost(context, service, existing: host),
                            trailing:
                                Row(mainAxisSize: MainAxisSize.min, children: [
                              IconButton(
                                key: ValueKey('btn-pin-host-${host.id}'),
                                tooltip: isPinned ? l10n.unpin : l10n.pin,
                                icon: Icon(
                                  isPinned ? Icons.star : Icons.star_border,
                                  color: isPinned ? Colors.amber : null,
                                ),
                                onPressed: () => _togglePin(host),
                              ),
                              IconButton(
                                key: ValueKey('btn-connect-host-${host.id}'),
                                tooltip: l10n.sshConnect,
                                icon: const Icon(Icons.play_arrow_outlined),
                                onPressed: onConnectHost == null
                                    ? null
                                    : () => onConnectHost(host),
                              ),
                              IconButton(
                                key: ValueKey('btn-delete-host-${host.id}'),
                                tooltip: l10n.delete,
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () async {
                                  if (await _confirmDelete(
                                      context, host.name)) {
                                    service.deleteRecord(host.id);
                                  }
                                },
                              ),
                            ]),
                          );
                        },
                      ),
          ),
        ]);
      },
    );
  }
}

Future<void> _editHost(
  BuildContext context,
  VaultService service, {
  VaultRecord? existing,
}) async {
  final data = existing?.data ?? const <String, dynamic>{};
  final auth = (data['auth'] as Map?)?.cast<String, dynamic>() ?? const {};
  final name = TextEditingController(text: existing?.name ?? '');
  final address = TextEditingController(text: data['address'] as String? ?? '');
  final port = TextEditingController(text: '${data['port'] ?? 22}');
  final username = TextEditingController(text: data['username'] as String? ?? '');
  final password = TextEditingController(text: auth['password'] as String? ?? '');
  final note = TextEditingController(text: data['note'] as String? ?? '');
  var method = auth['method'] as String? ?? 'password';
  String? keyId = auth['keyId'] as String?;
  // 記住的 host key 指紋(第一次連線時存的):可以手動清除;位址或 port 改了
  // 也一併清掉 —— 那是舊主機的指紋,留著只會讓下次連線報「主機金鑰不符」。
  final fingerprint = data['hostKeyFingerprint'] as String?;
  var clearFingerprint = false;
  bool endpointChanged() =>
      address.text.trim() != (data['address'] as String? ?? '') ||
      (int.tryParse(port.text.trim()) ?? 22).clamp(1, 65535) !=
          (data['port'] ?? 22);

  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        final keys = service.sshKeys;
        if (keyId != null && keys.every((k) => k.id != keyId)) keyId = null;
        return AlertDialog(
          title: Text(existing == null ? l10n.addHost : l10n.editHost),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(
                  key: const Key('host-name'),
                  controller: name,
                  decoration: InputDecoration(labelText: l10n.nameRequiredLabel),
                ),
                TextField(
                  key: const Key('host-address'),
                  controller: address,
                  decoration: InputDecoration(labelText: l10n.addressRequiredLabel),
                  onChanged: (_) => setState(() {}),
                ),
                Row(children: [
                  Expanded(
                    child: TextField(
                      key: const Key('host-port'),
                      controller: port,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(labelText: l10n.port),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      key: const Key('host-username'),
                      controller: username,
                      decoration: InputDecoration(labelText: l10n.username),
                    ),
                  ),
                ]),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  key: const Key('host-auth'),
                  initialValue: method,
                  decoration: InputDecoration(labelText: l10n.authMethod),
                  items: [
                    DropdownMenuItem(value: 'password', child: Text(l10n.password)),
                    DropdownMenuItem(value: 'key', child: Text(l10n.sshKey)),
                    DropdownMenuItem(value: 'none', child: Text(l10n.authNone)),
                  ],
                  onChanged: (v) => setState(() => method = v ?? 'password'),
                ),
                if (method == 'password')
                  TextField(
                    key: const Key('host-password'),
                    controller: password,
                    obscureText: true,
                    decoration: InputDecoration(labelText: l10n.password),
                  ),
                if (method == 'key')
                  DropdownButtonFormField<String>(
                    key: const Key('host-key'),
                    initialValue: keyId,
                    decoration: InputDecoration(labelText: l10n.key),
                    items: [
                      for (final k in keys)
                        DropdownMenuItem(value: k.id, child: Text(k.name)),
                    ],
                    onChanged: (v) => setState(() => keyId = v),
                  ),
                TextField(
                  key: const Key('host-note'),
                  controller: note,
                  decoration: InputDecoration(labelText: l10n.note),
                ),
                if (existing != null)
                  _HostFingerprintSection(
                    fingerprint: fingerprint,
                    cleared: clearFingerprint,
                    endpointChanged: endpointChanged(),
                    onClear: () => setState(() => clearFingerprint = true),
                    onUndo: () => setState(() => clearFingerprint = false),
                  ),
              ]),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              key: const Key('btn-save-host'),
              onPressed: () {
                final portNum = int.tryParse(port.text.trim()) ?? 22;
                if (name.text.trim().isEmpty || address.text.trim().isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(l10n.hostRequiredFields)),
                  );
                  return;
                }
                // 從既有 data 出發、只覆寫表單管的欄位——pinned 這類
                // 表單外的欄位不能掉;auth 裡沒在編的欄位也保留
                // (例:金鑰認證時保留舊密碼,之後切回密碼認證還在)。
                final newData =
                    Map<String, dynamic>.from(existing?.data ?? const {});
                final newAuth = Map<String, dynamic>.from(
                    (newData['auth'] as Map?)?.cast<String, dynamic>() ??
                        const {});
                newAuth['method'] = method;
                if (method == 'key' && keyId != null) {
                  newAuth['keyId'] = keyId;
                }
                if (method == 'password') {
                  if (password.text.isNotEmpty) {
                    newAuth['password'] = password.text;
                  } else {
                    // 欄位有預填舊密碼,清空 = 刻意移除
                    newAuth.remove('password');
                  }
                }
                newData['address'] = address.text.trim();
                newData['port'] = portNum.clamp(1, 65535);
                newData['username'] = username.text.trim();
                newData['auth'] = newAuth;
                if (note.text.trim().isNotEmpty) {
                  newData['note'] = note.text.trim();
                } else {
                  newData.remove('note');
                }
                // 下次連線重新記住(TOFU)
                if (clearFingerprint || endpointChanged()) {
                  newData.remove('hostKeyFingerprint');
                }
                service.upsert(
                  id: existing?.id,
                  kind: 'host',
                  name: name.text.trim(),
                  data: newData,
                );
                Navigator.pop(context);
              },
              child: Text(l10n.save),
            ),
          ],
        );
      },
    ),
  );
}

/// 編輯 Host 對話框裡的主機指紋:顯示記住的指紋,可清除(儲存才生效)。
class _HostFingerprintSection extends StatelessWidget {
  const _HostFingerprintSection({
    required this.fingerprint,
    required this.cleared,
    required this.endpointChanged,
    required this.onClear,
    required this.onUndo,
  });

  /// null = 還沒記住(還沒連線過,或剛清掉)。
  final String? fingerprint;
  final bool cleared;

  /// 位址或 port 改了:存檔時指紋一定會清掉。
  final bool endpointChanged;
  final VoidCallback onClear;
  final VoidCallback onUndo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fingerprint = this.fingerprint;
    final willClear = cleared || endpointChanged;
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: Text(
                l10n.hostFingerprint,
                style: theme.textTheme.labelMedium,
              ),
            ),
            if (fingerprint != null && cleared)
              TextButton(
                key: const Key('btn-undo-clear-fingerprint'),
                onPressed: onUndo,
                child: Text(l10n.undo),
              )
            else if (fingerprint != null && !endpointChanged)
              TextButton.icon(
                key: const Key('btn-clear-fingerprint'),
                onPressed: onClear,
                icon: const Icon(Icons.delete_outline, size: 16),
                label: Text(l10n.clear),
              ),
          ]),
          if (fingerprint == null)
            Text(
              l10n.hostFingerprintNone,
              key: const Key('host-fingerprint-none'),
              style: theme.textTheme.bodySmall,
            )
          else ...[
            SelectableText(
              fingerprint,
              key: const Key('host-fingerprint'),
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                decoration: willClear ? TextDecoration.lineThrough : null,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              cleared
                  ? l10n.hostFingerprintWillClear
                  : endpointChanged
                  ? l10n.hostFingerprintAddressChanged
                  : l10n.hostFingerprintClearHint,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }
}

// ---- Keys ----

class _KeysTab extends StatelessWidget {
  const _KeysTab({required this.service});

  final VaultService service;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final keys = service.sshKeys;
        return Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(children: [
              Text(l10n.keyCount(keys.length),
                  style: Theme.of(context).textTheme.bodySmall),
              const Spacer(),
              FilledButton.icon(
                key: const Key('btn-generate-key'),
                onPressed: () => _generateKey(context, service),
                icon: const Icon(Icons.auto_awesome_outlined, size: 18),
                label: Text(l10n.generateKey),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                key: const Key('btn-add-key'),
                onPressed: () => _editKey(context, service),
                icon: const Icon(Icons.add, size: 18),
                label: Text(l10n.addKey),
              ),
            ]),
          ),
          Expanded(
            child: keys.isEmpty
                ? Center(child: Text(l10n.keysEmpty))
                : ListView.builder(
                    itemCount: keys.length,
                    itemBuilder: (context, i) =>
                        _KeyTile(service: service, record: keys[i]),
                  ),
          ),
        ]);
      },
    );
  }
}

Future<void> _editKey(
  BuildContext context,
  VaultService service, {
  VaultRecord? existing,
}) async {
  final data = existing?.data ?? const <String, dynamic>{};
  final name = TextEditingController(text: existing?.name ?? '');
  final privateKey =
      TextEditingController(text: data['privateKey'] as String? ?? '');
  final passphrase =
      TextEditingController(text: data['passphrase'] as String? ?? '');
  final note = TextEditingController(text: data['note'] as String? ?? '');

  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(existing == null ? l10n.addSshKey : l10n.editSshKey),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              key: const Key('key-name'),
              controller: name,
              decoration: InputDecoration(labelText: l10n.nameRequiredLabel),
            ),
            TextField(
              key: const Key('key-private'),
              controller: privateKey,
              maxLines: 6,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: InputDecoration(
                labelText: l10n.privateKeyRequiredLabel,
              ),
            ),
            TextField(
              key: const Key('key-passphrase'),
              controller: passphrase,
              obscureText: true,
              decoration: InputDecoration(labelText: l10n.passphraseOptionalLabel),
            ),
            TextField(
              key: const Key('key-note'),
              controller: note,
              decoration: InputDecoration(labelText: l10n.note),
            ),
            _PublicKeyBox(privateKey: privateKey, passphrase: passphrase),
          ]),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          key: const Key('btn-save-key'),
          onPressed: () {
            if (name.text.trim().isEmpty || privateKey.text.trim().isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(l10n.keyRequiredFields)),
              );
              return;
            }
            service.upsert(
              id: existing?.id,
              kind: 'ssh_key',
              name: name.text.trim(),
              data: {
                'privateKey': privateKey.text,
                if (passphrase.text.isNotEmpty) 'passphrase': passphrase.text,
                if (note.text.trim().isNotEmpty) 'note': note.text.trim(),
              },
            );
            Navigator.pop(context);
          },
          child: Text(l10n.save),
        ),
      ],
    ),
  );
}

// ---- 產生金鑰(手機上沒有 ssh-keygen)----
//
// 在 core 產生 OpenSSH 格式私鑰,存成跟「貼上匯入」一樣的 ssh_key record,
// 之後連線、算公鑰都走同一條路。產生完直接秀公鑰給使用者複製。

Future<void> _generateKey(BuildContext context, VaultService service) =>
    showDialog<void>(
      context: context,
      // 產生中別被點外面關掉;結果一出來就已經存進 vault
      barrierDismissible: false,
      builder: (context) => _GenerateKeyDialog(service: service),
    );

class _GenerateKeyDialog extends StatefulWidget {
  const _GenerateKeyDialog({required this.service});

  final VaultService service;

  @override
  State<_GenerateKeyDialog> createState() => _GenerateKeyDialogState();
}

class _GenerateKeyDialogState extends State<_GenerateKeyDialog> {
  static String _defaultName(String kind) => 'tterminal-$kind';

  var _kind = GeneratedSshKey.kinds.first;
  late final _name = TextEditingController(text: _defaultName(_kind));
  final _passphrase = TextEditingController();
  final _repeat = TextEditingController();

  /// 名稱沒動過就跟著類型換預設名稱。
  var _nameEdited = false;
  var _busy = false;
  String? _error;

  /// 產生並存好的金鑰(與存檔時的名稱);有值就換成結果畫面。
  ({GeneratedSshKey key, String name})? _result;

  @override
  void dispose() {
    _name.dispose();
    _passphrase.dispose();
    _repeat.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    final name = _name.text.trim();
    final passphrase = _passphrase.text;
    if (name.isEmpty) {
      setState(() => _error = l10n.keygenNameRequired);
      return;
    }
    if (passphrase.isNotEmpty && passphrase != _repeat.text) {
      setState(() => _error = l10n.passphraseMismatch);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // comment 用名稱:authorized_keys 裡看得出是哪把
      final key = await GeneratedSshKey.generate(
        kind: _kind,
        comment: name,
        passphrase: passphrase,
      );
      // 跟貼上匯入的金鑰同一種 record(見 _editKey)
      widget.service.upsert(
        kind: 'ssh_key',
        name: name,
        data: {
          'privateKey': key.privateKey,
          if (passphrase.isNotEmpty) 'passphrase': passphrase,
        },
      );
      // 列表不必再跑一次 KDF 算同一把公鑰
      _publicKeyCache['${key.privateKey} $passphrase'] = key.publicKey;
      if (!mounted) return;
      setState(() {
        _busy = false;
        _result = (key: key, name: name);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = l10n.keygenFailed('$e');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    if (result != null) return _buildResult(context, result.key, result.name);
    final theme = Theme.of(context);
    final error = _error;
    return AlertDialog(
      title: Text(l10n.generateSshKey),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              key: const Key('keygen-name'),
              controller: _name,
              enabled: !_busy,
              decoration: InputDecoration(labelText: l10n.nameRequiredLabel),
              onChanged: (_) => _nameEdited = true,
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              key: const Key('keygen-type'),
              initialValue: _kind,
              isExpanded: true,
              decoration: InputDecoration(labelText: l10n.keyType),
              items: [
                DropdownMenuItem(
                  value: 'ed25519',
                  child: Text(l10n.keyTypeEd25519),
                ),
                DropdownMenuItem(value: 'rsa', child: Text(l10n.keyTypeRsa)),
              ],
              onChanged: _busy
                  ? null
                  : (v) => setState(() {
                      _kind = v ?? _kind;
                      if (!_nameEdited) _name.text = _defaultName(_kind);
                    }),
            ),
            TextField(
              key: const Key('keygen-passphrase'),
              controller: _passphrase,
              obscureText: true,
              enabled: !_busy,
              decoration: InputDecoration(
                labelText: l10n.passphraseOptionalLabel,
                helperText: l10n.keygenPassphraseHint,
                helperMaxLines: 4,
              ),
              onChanged: (_) => setState(() {}),
            ),
            if (_passphrase.text.isNotEmpty)
              TextField(
                key: const Key('keygen-passphrase-repeat'),
                controller: _repeat,
                obscureText: true,
                enabled: !_busy,
                decoration: InputDecoration(
                  labelText: l10n.passphraseRepeatLabel,
                ),
              ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    error,
                    key: const Key('keygen-error'),
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
              ),
            if (_busy)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Row(children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 12),
                  Text(l10n.generatingKey),
                ]),
              ),
          ]),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          key: const Key('btn-confirm-generate-key'),
          onPressed: _busy ? null : _generate,
          child: Text(l10n.generate),
        ),
      ],
    );
  }

  Widget _buildResult(BuildContext context, GeneratedSshKey key, String name) {
    final theme = Theme.of(context);
    final info = key.publicKey;
    return AlertDialog(
      title: Text(l10n.keyGenerated),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.keyGeneratedBody(name)),
              const SizedBox(height: 12),
              Text(
                l10n.publicKeyWithFingerprint(info.fingerprint),
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 4),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: SelectableText(
                  info.openssh,
                  key: const Key('keygen-public'),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('btn-keygen-done'),
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.done),
        ),
        FilledButton.icon(
          key: const Key('btn-copy-generated-pubkey'),
          onPressed: () => _copyPublicKey(context, info),
          icon: const Icon(Icons.copy_outlined, size: 18),
          label: Text(l10n.copyPublicKey),
        ),
      ],
    );
  }
}

// ---- 公鑰(從私鑰算出來,不另外存)----
//
// 公鑰不進 vault:存了就要跟私鑰保持同步,而算一次很便宜。但有 passphrase 的
// 金鑰要跑 KDF(幾十毫秒),所以算過的結果留在這裡,列表 rebuild 不重算。
// 只快取成功的結果 —— 失敗的通常是 passphrase 還沒填,改完要能重算。
final _publicKeyCache = <String, SshPublicKeyInfo>{};
final _publicKeyPending = <String, Future<SshPublicKeyInfo>>{};

String _keyMaterial(VaultRecord k) =>
    '${k.data['privateKey'] ?? ''} ${k.data['passphrase'] ?? ''}';

Future<SshPublicKeyInfo> _publicKeyOf(String privateKey, String passphrase) {
  final cacheKey = '$privateKey $passphrase';
  final done = _publicKeyCache[cacheKey];
  if (done != null) return Future.value(done);
  return _publicKeyPending.putIfAbsent(cacheKey, () async {
    try {
      return _publicKeyCache[cacheKey] =
          await SshPublicKeyInfo.derive(privateKey, passphrase: passphrase);
    } finally {
      _publicKeyPending.remove(cacheKey);
    }
  });
}

Future<SshPublicKeyInfo> _publicKeyOfRecord(VaultRecord k) => _publicKeyOf(
      k.data['privateKey'] as String? ?? '',
      k.data['passphrase'] as String? ?? '',
    );

Future<void> _copyPublicKey(BuildContext context, SshPublicKeyInfo info) async {
  await Clipboard.setData(ClipboardData(text: info.openssh));
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(l10n.publicKeyCopied)),
  );
}

/// 金鑰列表的一列:顯示指紋,並可一鍵複製公鑰。
///
/// 公鑰只在私鑰內容變動時重算(future 存在 state 裡),不然算失敗的金鑰會
/// 每次 rebuild 都重跑一次 isolate。
class _KeyTile extends StatefulWidget {
  const _KeyTile({required this.service, required this.record});

  final VaultService service;
  final VaultRecord record;

  @override
  State<_KeyTile> createState() => _KeyTileState();
}

class _KeyTileState extends State<_KeyTile> {
  late Future<SshPublicKeyInfo> _publicKey;

  @override
  void initState() {
    super.initState();
    _publicKey = _publicKeyOfRecord(widget.record);
  }

  @override
  void didUpdateWidget(_KeyTile old) {
    super.didUpdateWidget(old);
    if (_keyMaterial(old.record) != _keyMaterial(widget.record)) {
      _publicKey = _publicKeyOfRecord(widget.record);
    }
  }

  @override
  Widget build(BuildContext context) {
    final record = widget.record;
    final note = record.data['note'] as String? ?? '';
    return FutureBuilder<SshPublicKeyInfo>(
      future: _publicKey,
      builder: (context, snap) {
        final info = snap.data;
        final lines = [
          if (note.isNotEmpty) note,
          if (info != null) '${info.algorithm}  ·  ${info.fingerprint}',
          if (snap.error != null) l10n.publicKeyFailed('${snap.error}'),
        ];
        return ListTile(
          key: ValueKey('key-${record.id}'),
          isThreeLine: lines.length > 1,
          leading: const Icon(Icons.vpn_key_outlined),
          title: Text(record.name),
          subtitle: lines.isEmpty
              ? null
              : Text(
                  lines.join('\n'),
                  style: snap.error == null
                      ? null
                      : TextStyle(color: Theme.of(context).colorScheme.error),
                ),
          onTap: () => _editKey(context, widget.service, existing: record),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(
              key: ValueKey('btn-copy-pubkey-${record.id}'),
              tooltip: info == null ? l10n.publicKeyPending : l10n.copyPublicKey,
              icon: const Icon(Icons.copy_outlined),
              onPressed:
                  info == null ? null : () => _copyPublicKey(context, info),
            ),
            IconButton(
              key: ValueKey('btn-delete-key-${record.id}'),
              tooltip: l10n.delete,
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                if (await _confirmDelete(context, record.name)) {
                  widget.service.deleteRecord(record.id);
                }
              },
            ),
          ]),
        );
      },
    );
  }
}

/// 編輯對話框裡的公鑰區:跟著私鑰 / passphrase 欄位重算,可整行複製。
class _PublicKeyBox extends StatefulWidget {
  const _PublicKeyBox({required this.privateKey, required this.passphrase});

  final TextEditingController privateKey;
  final TextEditingController passphrase;

  @override
  State<_PublicKeyBox> createState() => _PublicKeyBoxState();
}

class _PublicKeyBoxState extends State<_PublicKeyBox> {
  SshPublicKeyInfo? _info;
  String? _error;

  /// 每次重算配一個序號,只認最後一次的結果(打字會連續觸發)。
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    widget.privateKey.addListener(_recompute);
    widget.passphrase.addListener(_recompute);
    _recompute();
  }

  @override
  void dispose() {
    widget.privateKey.removeListener(_recompute);
    widget.passphrase.removeListener(_recompute);
    super.dispose();
  }

  Future<void> _recompute() async {
    final pem = widget.privateKey.text;
    final pass = widget.passphrase.text;
    final seq = ++_seq;
    SshPublicKeyInfo? info;
    String? error;
    if (pem.trim().isNotEmpty) {
      try {
        info = await _publicKeyOf(pem, pass);
      } catch (e) {
        error = '$e';
      }
    }
    if (!mounted || seq != _seq) return;
    if (info == _info && error == _error) return; // initState 期間別亂 setState
    setState(() {
      _info = info;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final error = _error;
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(l10n.publicKeyFailed(error),
              style: TextStyle(color: theme.colorScheme.error)),
        ),
      );
    }
    final info = _info;
    if (info == null) return const SizedBox(height: 12);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(l10n.publicKeyWithFingerprint(info.fingerprint),
                style: theme.textTheme.bodySmall),
          ),
          TextButton.icon(
            key: const Key('btn-copy-pubkey'),
            onPressed: () => _copyPublicKey(context, info),
            icon: const Icon(Icons.copy_outlined, size: 16),
            label: Text(l10n.copyPublicKey),
          ),
        ]),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(4),
          ),
          child: SelectableText(
            info.openssh,
            key: const Key('key-public'),
            maxLines: 3,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
          ),
        ),
      ]),
    );
  }
}
