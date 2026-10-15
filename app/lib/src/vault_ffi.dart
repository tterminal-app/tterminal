// NativeVault:tterm_vault_* C ABI 的 Dart 包裝。
//
// 通道協定(與 core/tterm-ffi/src/vault_ffi.rs 鎖定):
//   * 冪等讀取(snapshot/buildPush/export/transport):回傳值 > cap 時
//     擴大 buffer 重呼叫。
//   * 變更操作(upsert/syncEnable/importPairing/applyPull):回傳保證
//     有界(<4KB),一次給足,**絕不重呼叫**(重呼叫=重複執行變更)。
//   * 失敗以 {"error": "...", "code"?: ...} 走同一條通道,這裡翻成使用者看的
//     訊息(native_error.dart)再包成 VaultException。

import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'l10n.dart';
import 'native_error.dart';
import 'term_ffi.dart';

class VaultException implements Exception {
  VaultException(this.message);

  /// 給使用者看的訊息(已依語系翻好)。
  final String message;

  @override
  String toString() => message;
}

/// 同步傳輸資訊(給 SyncClient 用;E2E key 永遠不會出現在 Dart)。
class SyncTransport {
  const SyncTransport({
    required this.server,
    required this.token,
    required this.vaultId,
  });

  final String server;
  final String token;
  final String vaultId;
}

/// vault key 存在 Apple Keychain 的哪個項目(generic password)。
/// 讀寫由 Rust 直接呼叫 Security.framework,key 本身不經過 Dart。
class VaultKeychain {
  const VaultKeychain({required this.service, required this.account});

  final String service;
  final String account;
}

class NativeVault {
  /// [keychain] 為 null:vault key 存在 [dir]/vault.key(Windows/Linux、測試)。
  /// 給了就存 Keychain,[dir] 裡舊版留下的 vault.key 會搬進去。
  NativeVault.open(String dir, {VaultKeychain? keychain}) : _ffi = TermFfi() {
    final dirC = dir.toNativeUtf8();
    final serviceC = keychain?.service.toNativeUtf8();
    final accountC = keychain?.account.toNativeUtf8();
    try {
      _handle = serviceC == null || accountC == null
          ? _ffi.vaultOpen(dirC)
          : _ffi.vaultOpenKeychain(dirC, serviceC, accountC);
    } finally {
      calloc.free(dirC);
      if (serviceC != null) calloc.free(serviceC);
      if (accountC != null) calloc.free(accountC);
    }
    if (_handle.address == 0) {
      // 不另加「無法開啟 vault」前綴:顯示的地方都會再包一層「Vault 無法開啟:」
      throw VaultException(_ffi.takeLastErrorMessage());
    }
  }

  final TermFfi _ffi;
  late final ffi.Pointer<ffi.Void> _handle;
  bool _disposed = false;

  static const _mutateCap = 8192;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _ffi.vaultFree(_handle);
  }

  Map<String, dynamic> _decode(Uint8List bytes) {
    final value = jsonDecode(utf8.decode(bytes));
    if (value is Map<String, dynamic> && value['error'] != null) {
      throw VaultException(describeNativeError(value));
    }
    return value is Map<String, dynamic> ? value : {'value': value};
  }

  /// 冪等讀取:不足就擴大重呼叫。
  Object? _read(int Function(ffi.Pointer<ffi.Uint8> out, int cap) call) {
    var cap = 64 * 1024;
    for (;;) {
      final buf = calloc<ffi.Uint8>(cap);
      try {
        final need = call(buf, cap);
        if (need <= cap) {
          final value = jsonDecode(utf8.decode(buf.asTypedList(need)));
          if (value is Map<String, dynamic> && value['error'] != null) {
            throw VaultException(describeNativeError(value));
          }
          return value;
        }
        cap = need;
      } finally {
        calloc.free(buf);
      }
    }
  }

  /// 變更操作:一次給足,絕不重呼叫。
  Map<String, dynamic> _mutate(
    int Function(ffi.Pointer<ffi.Uint8> out, int cap) call,
  ) {
    final buf = calloc<ffi.Uint8>(_mutateCap);
    try {
      final need = call(buf, _mutateCap);
      if (need > _mutateCap) {
        throw VaultException(
          'FFI mutation response exceeded the protocol limit ($need bytes)',
        );
      }
      return _decode(Uint8List.fromList(buf.asTypedList(need)));
    } finally {
      calloc.free(buf);
    }
  }

  Map<String, dynamic> snapshot() =>
      _read((out, cap) => _ffi.vaultSnapshot(_handle, out, cap))
          as Map<String, dynamic>;

  /// 回傳 record id。
  String upsert({
    String? id,
    required String kind,
    required String name,
    required Map<String, dynamic> data,
  }) {
    final req = jsonEncode({
      'id': ?id,
      'kind': kind,
      'name': name,
      'data': data,
    });
    final reqC = req.toNativeUtf8();
    try {
      final resp =
          _mutate((out, cap) => _ffi.vaultUpsert(_handle, reqC, out, cap));
      return resp['id'] as String;
    } finally {
      calloc.free(reqC);
    }
  }

  void delete(String id) {
    final idC = id.toNativeUtf8();
    try {
      if (_ffi.vaultDelete(_handle, idC) != 0) {
        throw VaultException(l10n.deleteFailed(_ffi.takeLastErrorMessage()));
      }
    } finally {
      calloc.free(idC);
    }
  }

  /// 啟用同步;回傳 (vaultId, auth)——auth 是註冊 server 用的 token hash。
  ({String vaultId, String auth}) syncEnable(String server) {
    final serverC = server.toNativeUtf8();
    try {
      final resp = _mutate(
        (out, cap) => _ffi.vaultSyncEnable(_handle, serverC, out, cap),
      );
      return (
        vaultId: resp['vaultId'] as String,
        auth: resp['auth'] as String,
      );
    } finally {
      calloc.free(serverC);
    }
  }

  void syncDisable() {
    if (_ffi.vaultSyncDisable(_handle) != 0) {
      throw VaultException(
        l10n.turnOffSyncFailed(_ffi.takeLastErrorMessage()),
      );
    }
  }

  /// 未設定同步時回傳 null。
  SyncTransport? syncTransport() {
    try {
      final resp = _read(
        (out, cap) => _ffi.vaultSyncTransport(_handle, out, cap),
      ) as Map<String, dynamic>;
      return SyncTransport(
        server: resp['server'] as String,
        token: resp['token'] as String,
        vaultId: resp['vaultId'] as String,
      );
    } on VaultException {
      return null;
    }
  }

  String exportPairing() {
    final resp = _read(
      (out, cap) => _ffi.vaultExportPairing(_handle, out, cap),
    ) as Map<String, dynamic>;
    return resp['pairing'] as String;
  }

  Map<String, dynamic> importPairing(String pairing) {
    final pairingC = pairing.toNativeUtf8();
    try {
      return _mutate(
        (out, cap) => _ffi.vaultImportPairing(_handle, pairingC, out, cap),
      );
    } finally {
      calloc.free(pairingC);
    }
  }

  List<dynamic> buildPush() =>
      _read((out, cap) => _ffi.vaultBuildPush(_handle, out, cap))
          as List<dynamic>;

  void ackPush(List<String> ids) {
    final idsC = jsonEncode(ids).toNativeUtf8();
    try {
      if (_ffi.vaultAckPush(_handle, idsC) != 0) {
        throw VaultException('ack push failed: ${_ffi.takeLastErrorMessage()}');
      }
    } finally {
      calloc.free(idsC);
    }
  }

  Map<String, dynamic> applyPull(List<dynamic> records, int nextCursor) {
    final recordsC = jsonEncode(records).toNativeUtf8();
    try {
      return _mutate(
        (out, cap) =>
            _ffi.vaultApplyPull(_handle, recordsC, nextCursor, out, cap),
      );
    } finally {
      calloc.free(recordsC);
    }
  }

  int get cursor => _ffi.vaultCursor(_handle);

  /// 同步衝突時本地版本另存副本的名稱樣板(`{name}` `{device}` `{time}`
  /// 由 Rust 填)。名稱會同步到所有裝置,所以用建立副本那台的語系。
  void setConflictNameTemplate(String template) {
    final templateC = template.toNativeUtf8();
    try {
      _ffi.vaultSetConflictNameTemplate(_handle, templateC);
    } finally {
      calloc.free(templateC);
    }
  }
}
