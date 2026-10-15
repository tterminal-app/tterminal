// VaultService:Vault 的應用層(CRUD + 同步排程 + 狀態),UI 監聽這裡。
//
// 責任分工:
//   NativeVault(Rust)= 儲存、加密、合併;
//   SyncClient       = HTTP 搬運密文;
//   VaultService     = 把兩者串成流程(變更 → debounce 推送;啟動/手動 → 同步)。

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'l10n.dart';
import 'sync_client.dart';
import 'vault_ffi.dart';

/// 一筆 UI 可見的 record(明文,來自 snapshot)。
class VaultRecord {
  VaultRecord({
    required this.id,
    required this.kind,
    required this.name,
    required this.data,
  });

  final String id;
  final String kind;
  final String name;
  final Map<String, dynamic> data;

  static VaultRecord fromJson(Map<String, dynamic> json) => VaultRecord(
    id: json['id'] as String,
    kind: json['kind'] as String,
    name: json['name'] as String,
    data: (json['data'] as Map).cast<String, dynamic>(),
  );
}

/// 預設 vault 目錄(per-user、per-machine)。
String defaultVaultDir() {
  if (Platform.isWindows) {
    final base = Platform.environment['APPDATA'] ??
        '${Platform.environment['USERPROFILE'] ?? '.'}\\AppData\\Roaming';
    return '$base\\tterminal\\vault';
  }
  final home = Platform.environment['HOME'] ?? '.';
  if (Platform.isMacOS) {
    return '$home/Library/Application Support/tterminal/vault';
  }
  final xdg = Platform.environment['XDG_DATA_HOME'] ?? '$home/.local/share';
  return '$xdg/tterminal/vault';
}

class VaultService extends ChangeNotifier {
  VaultService.open(String dir, {SyncClient? client})
      : _vault = NativeVault.open(dir),
        _client = client ?? SyncClient() {
    _refresh();
  }

  final NativeVault _vault;
  final SyncClient _client;

  Map<String, dynamic> _snap = const {'records': []};
  Timer? _debounce;
  bool _disposed = false;

  bool syncing = false;
  String? lastSyncError;
  DateTime? lastSyncAt;

  // ---- 查詢 ----

  String get vaultId => _snap['vaultId'] as String? ?? '';
  String get deviceId => _snap['deviceId'] as String? ?? '';
  int get dirtyCount => _snap['dirty'] as int? ?? 0;
  String? get syncServer =>
      (_snap['sync'] as Map<String, dynamic>?)?['server'] as String?;
  bool get syncConfigured => syncServer != null;

  List<VaultRecord> get records => [
    for (final r in (_snap['records'] as List<dynamic>? ?? const []))
      VaultRecord.fromJson((r as Map).cast<String, dynamic>()),
  ];

  List<VaultRecord> get hosts =>
      records.where((r) => r.kind == 'host').toList();
  List<VaultRecord> get sshKeys =>
      records.where((r) => r.kind == 'ssh_key').toList();

  VaultRecord? byId(String? id) {
    if (id == null) return null;
    for (final r in records) {
      if (r.id == id) return r;
    }
    return null;
  }

  // ---- CRUD ----

  void _refresh() {
    _snap = _vault.snapshot();
    if (!_disposed) notifyListeners();
  }

  String upsert({
    String? id,
    required String kind,
    required String name,
    required Map<String, dynamic> data,
  }) {
    final newId = _vault.upsert(id: id, kind: kind, name: name, data: data);
    _refresh();
    _scheduleSync();
    return newId;
  }

  void deleteRecord(String id) {
    _vault.delete(id);
    _refresh();
    _scheduleSync();
  }

  // ---- 同步 ----

  /// 在 server 上建立同步:產 token → 註冊;註冊失敗會還原(停用同步)。
  Future<void> enableSync(String server) async {
    final normalized = server.trim().replaceAll(RegExp(r'/+$'), '');
    if (normalized.isEmpty) {
      throw VaultException(l10n.serverAddressEmpty);
    }
    final (:vaultId, :auth) = _vault.syncEnable(normalized);
    try {
      await _client.register(server: normalized, vaultId: vaultId, auth: auth);
    } catch (e) {
      _vault.syncDisable();
      _refresh();
      rethrow;
    }
    _refresh();
    await syncNow();
  }

  Future<void> disableSync() async {
    _vault.syncDisable();
    lastSyncError = null;
    _refresh();
  }

  String exportPairing() => _vault.exportPairing();

  /// 貼上配對字串加入既有 vault,完成後立刻同步。
  Future<Map<String, dynamic>> importPairing(String pairing) async {
    final summary = _vault.importPairing(pairing);
    _refresh();
    await syncNow();
    return summary;
  }

  /// 變更後的延遲推送(避免每個鍵入都打 server)。
  void _scheduleSync() {
    if (!syncConfigured) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 2), () {
      unawaited(syncNow());
    });
  }

  /// push dirty → ack → pull since cursor → apply。任何失敗保留狀態下次重試。
  Future<void> syncNow() async {
    final transport = _vault.syncTransport();
    if (transport == null || syncing || _disposed) return;
    syncing = true;
    lastSyncError = null;
    notifyListeners();
    try {
      final push = _vault.buildPush();
      if (push.isNotEmpty) {
        await _client.push(
          server: transport.server,
          vaultId: transport.vaultId,
          token: transport.token,
          records: push,
        );
        _vault.ackPush([for (final r in push) (r as Map)['id'] as String]);
      }
      final (records, next) = await _client.pull(
        server: transport.server,
        vaultId: transport.vaultId,
        token: transport.token,
        since: _vault.cursor,
      );
      if (records.isNotEmpty || next != _vault.cursor) {
        _vault.setConflictNameTemplate(
          l10n.conflictCopyName('{name}', '{device}', '{time}'),
        );
        _vault.applyPull(records, next);
      }
      lastSyncAt = DateTime.now();
    } catch (e) {
      lastSyncError = '$e';
    } finally {
      syncing = false;
      if (!_disposed) {
        _snap = _vault.snapshot();
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    _vault.dispose();
    super.dispose();
  }
}
