// tterm-ffi 的 dart:ffi 綁定(熱路徑:terminal grid 與 session I/O)。
//
// Grid buffer 佈局:每 cell 4 個 u32 → [codepoint, fg 0xRRGGBB, bg 0xRRGGBB, flags]。
// flags / modes bits 與 Rust 端鎖定(core/tterm-term tests/engine.rs)。

import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'l10n.dart';
import 'native_error.dart';

const kExpectedAbiVersion = 15;

/// 與 alacritty_terminal cell flags 對齊(bits 由 Rust 測試鎖定)。
abstract final class CellFlags {
  static const inverse = 1 << 0;
  static const bold = 1 << 1;
  static const italic = 1 << 2;
  static const underline = 1 << 3;
  static const wrapline = 1 << 4;
  static const wideChar = 1 << 5;
  static const wideCharSpacer = 1 << 6;
  static const dim = 1 << 7;
  static const hidden = 1 << 8;
  static const strikeout = 1 << 9;
}

/// 終端模式 bits(tterm_term::modes)。
abstract final class TermModes {
  static const appCursor = 1 << 0;
  static const appKeypad = 1 << 1;
  static const bracketedPaste = 1 << 2;
  static const mouseReportClick = 1 << 3;
  static const mouseDrag = 1 << 4;
  static const mouseMotion = 1 << 5;
  static const sgrMouse = 1 << 6;
  static const altScreen = 1 << 7;
  static const showCursor = 1 << 8;

  /// 會讓滾輪捲不動 scrollback 的模式(對齊 tterm_term::modes::WHEEL_BLOCKING):
  /// 滑鼠回報開著時滾輪被送給程式,alt screen 則根本沒有 scrollback。
  static const wheelBlocking =
      mouseReportClick | mouseDrag | mouseMotion | altScreen;
}

abstract final class DemoScenario {
  static const plain = 0;
  static const colored = 1;
  static const cjk = 2;
  static const cursorPaint = 3;
  static const count = 4;

  static String name(int s) => switch (s) {
    plain => 'plain_scroll',
    colored => 'colored_scroll',
    cjk => 'cjk_scroll',
    cursorPaint => 'cursor_paint',
    _ => 'unknown',
  };
}

typedef NewHeadlessC =
    ffi.Pointer<ffi.Void> Function(ffi.Uint32, ffi.Uint32, ffi.Uint32);
typedef NewHeadlessD = ffi.Pointer<ffi.Void> Function(int, int, int);
typedef SpawnShellC =
    ffi.Pointer<ffi.Void> Function(
      ffi.Uint32,
      ffi.Uint32,
      ffi.Uint32,
      ffi.Pointer<Utf8>,
    );
typedef SpawnShellD =
    ffi.Pointer<ffi.Void> Function(int, int, int, ffi.Pointer<Utf8>);
typedef ConnectSshC = ffi.Pointer<ffi.Void> Function(ffi.Pointer<Utf8>);
typedef ConnectSshD = ffi.Pointer<ffi.Void> Function(ffi.Pointer<Utf8>);
typedef FreeC = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef FreeD = void Function(ffi.Pointer<ffi.Void>);
typedef WriteC =
    ffi.Uint32 Function(
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Uint8>,
      ffi.Size,
    );
typedef WriteD =
    int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint8>, int);
typedef ResizeC =
    ffi.Uint32 Function(ffi.Pointer<ffi.Void>, ffi.Uint32, ffi.Uint32);
typedef ResizeD = int Function(ffi.Pointer<ffi.Void>, int, int);
typedef U32FromHandleC = ffi.Uint32 Function(ffi.Pointer<ffi.Void>);
typedef U32FromHandleD = int Function(ffi.Pointer<ffi.Void>);
typedef VoidFromHandleC = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef VoidFromHandleD = void Function(ffi.Pointer<ffi.Void>);
typedef CopyGridC =
    ffi.Size Function(
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Uint32>,
      ffi.Size,
    );
typedef CopyGridD =
    int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint32>, int);
typedef CursorC =
    ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint32>);
typedef CursorD = void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint32>);
typedef ScrollC = ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Int32);
typedef ScrollD = void Function(ffi.Pointer<ffi.Void>, int);
typedef StrOutC =
    ffi.Size Function(
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Uint8>,
      ffi.Size,
    );
typedef StrOutD =
    int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint8>, int);
typedef LastErrorC = ffi.Size Function(ffi.Pointer<ffi.Uint8>, ffi.Size);
typedef LastErrorD = int Function(ffi.Pointer<ffi.Uint8>, int);
typedef DemoFeedC =
    ffi.Size Function(ffi.Pointer<ffi.Void>, ffi.Uint32, ffi.Size);
typedef DemoFeedD = int Function(ffi.Pointer<ffi.Void>, int, int);
typedef SshPublicKeyC =
    ffi.Size Function(
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<ffi.Uint8>,
      ffi.Size,
    );
typedef SshPublicKeyD =
    int Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>, ffi.Pointer<ffi.Uint8>, int);
typedef SshGenerateKeyC =
    ffi.Size Function(
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<ffi.Uint8>,
      ffi.Size,
    );
typedef SshGenerateKeyD =
    int Function(
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<ffi.Uint8>,
      int,
    );
typedef VersionC = ffi.Uint32 Function();
typedef VersionD = int Function();

// ---- SFTP(遠端檔案瀏覽;回傳 usize,-1 = 失敗)----
typedef SftpOutC =
    ffi.Size Function(ffi.Pointer<ffi.Void>, ffi.Pointer<Utf8>, ffi.Pointer<ffi.Uint8>, ffi.Size);
typedef SftpOutD =
    int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<Utf8>, ffi.Pointer<ffi.Uint8>, int);
typedef SftpHomeC =
    ffi.Size Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint8>, ffi.Size);
typedef SftpHomeD = int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint8>, int);
typedef SftpWriteC =
    ffi.Uint32 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<Utf8>, ffi.Pointer<ffi.Uint8>, ffi.Size);
typedef SftpWriteD =
    int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<Utf8>, ffi.Pointer<ffi.Uint8>, int);
typedef SshExecC =
    ffi.Size Function(
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<ffi.Uint8>,
      ffi.Size,
      ffi.Uint32,
      ffi.Pointer<ffi.Uint8>,
      ffi.Size,
    );
typedef SshExecD =
    int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<Utf8>, ffi.Pointer<ffi.Uint8>, int, int,
        ffi.Pointer<ffi.Uint8>, int);

// ---- vault(低頻 JSON 通道;協定見 core/tterm-ffi/src/vault_ffi.rs)----
typedef VaultOpenC = ffi.Pointer<ffi.Void> Function(ffi.Pointer<Utf8>);
typedef VaultOpenD = ffi.Pointer<ffi.Void> Function(ffi.Pointer<Utf8>);
// (dir, service, account)
typedef VaultOpenKeychainC =
    ffi.Pointer<ffi.Void> Function(
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
    );
typedef VaultOpenKeychainD = VaultOpenKeychainC;
typedef VaultJsonOutC =
    ffi.Size Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint8>, ffi.Size);
typedef VaultJsonOutD =
    int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint8>, int);
typedef VaultStrJsonOutC =
    ffi.Size Function(
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<ffi.Uint8>,
      ffi.Size,
    );
typedef VaultStrJsonOutD =
    int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<Utf8>, ffi.Pointer<ffi.Uint8>, int);
typedef VaultApplyPullC =
    ffi.Size Function(
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<Utf8>,
      ffi.Uint64,
      ffi.Pointer<ffi.Uint8>,
      ffi.Size,
    );
typedef VaultApplyPullD =
    int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<Utf8>, int, ffi.Pointer<ffi.Uint8>, int);
typedef VaultStrInC = ffi.Uint32 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<Utf8>);
typedef VaultStrInD = int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<Utf8>);
typedef VaultU64C = ffi.Uint64 Function(ffi.Pointer<ffi.Void>);
typedef VaultU64D = int Function(ffi.Pointer<ffi.Void>);

/// 已載入的原生函式庫。整個 app 共用一份。
class TermFfi {
  factory TermFfi() => _instance ??= TermFfi._(_openLibrary());

  /// iOS 不允許 dlopen 隨附的 dylib,Rust 核心以 staticlib 直接連結進
  /// 執行檔(ios/Flutter/*.xcconfig 的 -force_load),從主程序查符號。
  static ffi.DynamicLibrary _openLibrary() => Platform.isIOS
      ? ffi.DynamicLibrary.process()
      : ffi.DynamicLibrary.open(resolvedLibraryPath);

  TermFfi._(this._lib) {
    newHeadless = _lib.lookupFunction<NewHeadlessC, NewHeadlessD>(
      'tterm_session_new_headless',
    );
    spawnShell = _lib.lookupFunction<SpawnShellC, SpawnShellD>(
      'tterm_session_spawn_shell',
    );
    connectSsh = _lib.lookupFunction<ConnectSshC, ConnectSshD>(
      'tterm_session_connect_ssh',
    );
    sshFingerprint = _lib.lookupFunction<StrOutC, StrOutD>(
      'tterm_session_ssh_fingerprint',
    );
    sshPublicKey = _lib.lookupFunction<SshPublicKeyC, SshPublicKeyD>(
      'tterm_ssh_public_key',
    );
    sshGenerateKey = _lib.lookupFunction<SshGenerateKeyC, SshGenerateKeyD>(
      'tterm_ssh_generate_key',
    );
    free = _lib.lookupFunction<FreeC, FreeD>('tterm_session_free');
    write = _lib.lookupFunction<WriteC, WriteD>('tterm_session_write');
    resize = _lib.lookupFunction<ResizeC, ResizeD>('tterm_session_resize');
    takeDamage = _lib.lookupFunction<U32FromHandleC, U32FromHandleD>(
      'tterm_session_take_damage',
    );
    copyGrid = _lib.lookupFunction<CopyGridC, CopyGridD>(
      'tterm_session_copy_grid',
    );
    cursor = _lib.lookupFunction<CursorC, CursorD>('tterm_session_cursor');
    modes = _lib.lookupFunction<U32FromHandleC, U32FromHandleD>(
      'tterm_session_modes',
    );
    scroll = _lib.lookupFunction<ScrollC, ScrollD>('tterm_session_scroll');
    resetModes = _lib.lookupFunction<VoidFromHandleC, VoidFromHandleD>(
      'tterm_session_reset_modes',
    );
    recoverStuckModes = _lib.lookupFunction<U32FromHandleC, U32FromHandleD>(
      'tterm_session_recover_stuck_modes',
    );
    isAlive = _lib.lookupFunction<U32FromHandleC, U32FromHandleD>(
      'tterm_session_is_alive',
    );
    title = _lib.lookupFunction<StrOutC, StrOutD>('tterm_session_title');
    currentDir = _lib.lookupFunction<StrOutC, StrOutD>(
      'tterm_session_current_dir',
    );
    localCwd = _lib.lookupFunction<StrOutC, StrOutD>(
      'tterm_session_local_cwd',
    );
    takeClipboardFn = _lib.lookupFunction<StrOutC, StrOutD>(
      'tterm_session_take_clipboard',
    );
    isSsh = _lib.lookupFunction<U32FromHandleC, U32FromHandleD>(
      'tterm_session_is_ssh',
    );
    sftpHome = _lib.lookupFunction<SftpHomeC, SftpHomeD>(
      'tterm_session_sftp_home',
    );
    sftpList = _lib.lookupFunction<SftpOutC, SftpOutD>(
      'tterm_session_sftp_list',
    );
    sshExec = _lib.lookupFunction<SshExecC, SshExecD>(
      'tterm_session_ssh_exec',
    );
    sftpReadFn = _lib.lookupFunction<SftpOutC, SftpOutD>(
      'tterm_session_sftp_read',
    );
    sftpWrite = _lib.lookupFunction<SftpWriteC, SftpWriteD>(
      'tterm_session_sftp_write',
    );
    bellCount = _lib.lookupFunction<U32FromHandleC, U32FromHandleD>(
      'tterm_session_bell_count',
    );
    demoFeed = _lib.lookupFunction<DemoFeedC, DemoFeedD>(
      'tterm_session_demo_feed',
    );
    lastError = _lib.lookupFunction<LastErrorC, LastErrorD>(
      'tterm_last_error',
    );

    vaultOpen = _lib.lookupFunction<VaultOpenC, VaultOpenD>('tterm_vault_open');
    vaultOpenKeychain = _lib
        .lookupFunction<VaultOpenKeychainC, VaultOpenKeychainD>(
          'tterm_vault_open_keychain',
        );
    vaultFree = _lib.lookupFunction<FreeC, FreeD>('tterm_vault_free');
    vaultSnapshot = _lib.lookupFunction<VaultJsonOutC, VaultJsonOutD>(
      'tterm_vault_snapshot',
    );
    vaultUpsert = _lib.lookupFunction<VaultStrJsonOutC, VaultStrJsonOutD>(
      'tterm_vault_upsert',
    );
    vaultDelete = _lib.lookupFunction<VaultStrInC, VaultStrInD>(
      'tterm_vault_delete',
    );
    vaultSyncEnable = _lib.lookupFunction<VaultStrJsonOutC, VaultStrJsonOutD>(
      'tterm_vault_sync_enable',
    );
    vaultSyncDisable = _lib.lookupFunction<U32FromHandleC, U32FromHandleD>(
      'tterm_vault_sync_disable',
    );
    vaultSyncTransport = _lib.lookupFunction<VaultJsonOutC, VaultJsonOutD>(
      'tterm_vault_sync_transport',
    );
    vaultExportPairing = _lib.lookupFunction<VaultJsonOutC, VaultJsonOutD>(
      'tterm_vault_export_pairing',
    );
    vaultImportPairing = _lib.lookupFunction<VaultStrJsonOutC, VaultStrJsonOutD>(
      'tterm_vault_import_pairing',
    );
    vaultBuildPush = _lib.lookupFunction<VaultJsonOutC, VaultJsonOutD>(
      'tterm_vault_build_push',
    );
    vaultAckPush = _lib.lookupFunction<VaultStrInC, VaultStrInD>(
      'tterm_vault_ack_push',
    );
    vaultApplyPull = _lib.lookupFunction<VaultApplyPullC, VaultApplyPullD>(
      'tterm_vault_apply_pull',
    );
    vaultCursor = _lib.lookupFunction<VaultU64C, VaultU64D>(
      'tterm_vault_cursor',
    );
    vaultSetConflictNameTemplate = _lib.lookupFunction<VaultStrInC, VaultStrInD>(
      'tterm_vault_set_conflict_name_template',
    );

    final version = _lib.lookupFunction<VersionC, VersionD>(
      'tterm_ffi_version',
    )();
    if (version != kExpectedAbiVersion) {
      throw StateError(
        'tterm-ffi ABI mismatch: the native library reports $version, '
        'the Dart bindings expect $kExpectedAbiVersion (rebuild core)',
      );
    }
  }

  static TermFfi? _instance;

  final ffi.DynamicLibrary _lib;

  late final NewHeadlessD newHeadless;
  late final SpawnShellD spawnShell;
  late final ConnectSshD connectSsh;
  late final StrOutD sshFingerprint;
  late final SshPublicKeyD sshPublicKey;
  late final SshGenerateKeyD sshGenerateKey;
  late final FreeD free;
  late final WriteD write;
  late final ResizeD resize;
  late final U32FromHandleD takeDamage;
  late final CopyGridD copyGrid;
  late final CursorD cursor;
  late final U32FromHandleD modes;
  late final ScrollD scroll;
  late final VoidFromHandleD resetModes;
  late final U32FromHandleD recoverStuckModes;
  late final U32FromHandleD isAlive;
  late final StrOutD title;
  late final StrOutD currentDir;
  late final StrOutD localCwd;
  late final StrOutD takeClipboardFn;
  late final U32FromHandleD isSsh;
  late final SftpHomeD sftpHome;
  late final SftpOutD sftpList;
  late final SshExecD sshExec;
  late final SftpOutD sftpReadFn;
  late final SftpWriteD sftpWrite;
  late final U32FromHandleD bellCount;
  late final DemoFeedD demoFeed;
  late final LastErrorD lastError;

  late final VaultOpenD vaultOpen;
  late final VaultOpenKeychainD vaultOpenKeychain;
  late final FreeD vaultFree;
  late final VaultJsonOutD vaultSnapshot;
  late final VaultStrJsonOutD vaultUpsert;
  late final VaultStrInD vaultDelete;
  late final VaultStrJsonOutD vaultSyncEnable;
  late final U32FromHandleD vaultSyncDisable;
  late final VaultJsonOutD vaultSyncTransport;
  late final VaultJsonOutD vaultExportPairing;
  late final VaultStrJsonOutD vaultImportPairing;
  late final VaultJsonOutD vaultBuildPush;
  late final VaultStrInD vaultAckPush;
  late final VaultApplyPullD vaultApplyPull;
  late final VaultU64D vaultCursor;
  late final VaultStrInD vaultSetConflictNameTemplate;

  /// 原文(錯誤 JSON,見 native_error.dart)。背景 isolate 只能拿原文,
  /// 帶回主 isolate 再用 [describeLastError] 翻。
  String takeLastError() {
    const cap = 4096;
    final buf = calloc<ffi.Uint8>(cap);
    try {
      final n = lastError(buf, cap);
      return utf8Decode(buf.asTypedList(n));
    } finally {
      calloc.free(buf);
    }
  }

  /// 給使用者看的錯誤訊息(依目前語系;只能在主 isolate 呼叫)。
  String takeLastErrorMessage() => describeLastError(takeLastError());

  /// 解析到的原生函式庫路徑(背景 isolate 用同一路徑載入)。
  static final String resolvedLibraryPath = _findLibrary();

  static String _findLibrary() {
    final name = Platform.isWindows
        ? 'tterm_ffi.dll'
        : Platform.isMacOS
        ? 'libtterm_ffi.dylib'
        : 'libtterm_ffi.so';
    final env = Platform.environment['TTERM_FFI_LIB'];
    if (env != null && File(env).existsSync()) return env;
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final cwd = Directory.current.path;
    for (final c in [
      '$exeDir/lib/$name',
      '$exeDir/$name',
      // dev loop:從 app/ 或 repo root 執行
      '$cwd/../core/target/release/$name',
      '$cwd/core/target/release/$name',
    ]) {
      if (File(c).existsSync()) return c;
    }
    return name; // 交給系統 loader
  }
}

/// SSH 連線失敗(認證錯誤、host key 不符、網路不通…)。
class SshConnectException implements Exception {
  SshConnectException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 伺服器出示的 host key 跟記住的指紋不符,連線已中止(Rust 錯誤代碼
/// `host_key_mismatch`)。錯誤畫面要拿新舊指紋給使用者比對、決定要不要
/// 改用新指紋,所以帶著兩個指紋,不只是一串訊息。
class HostKeyMismatchException extends SshConnectException {
  HostKeyMismatchException({required this.expected, required this.actual})
    : super(l10n.hostKeyChangedTitle);

  /// 記住的指紋(`SHA256:...`)。
  final String expected;

  /// 這次伺服器出示的指紋。
  final String actual;

  /// 從 `tterm_last_error` 的原文(錯誤 JSON)認出 host key 不符;不是就回 null。
  static HostKeyMismatchException? tryParse(String raw) {
    try {
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic> || json['code'] != 'host_key_mismatch') {
        return null;
      }
      final args = (json['args'] as Map?)?.cast<String, dynamic>() ?? const {};
      final expected = args['expected'];
      final actual = args['actual'];
      if (expected is! String || actual is! String) return null;
      return HostKeyMismatchException(expected: expected, actual: actual);
    } on FormatException {
      return null;
    }
  }
}

/// 私鑰算不出公鑰(格式不認得、舊式 PEM 少了 passphrase…)。
class SshKeyException implements Exception {
  SshKeyException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 從私鑰算出來的公鑰資訊(純計算,不連線)。
class SshPublicKeyInfo {
  const SshPublicKeyInfo({
    required this.openssh,
    required this.algorithm,
    required this.fingerprint,
    required this.comment,
  });

  /// authorized_keys 那一行:`ssh-ed25519 AAAA... comment`。
  final String openssh;

  /// `ssh-ed25519` / `rsa-sha2-256` …
  final String algorithm;

  /// `SHA256:...`(與 ssh-keygen -lf 一致)。
  final String fingerprint;

  /// 私鑰帶的註解(常是 user@host),沒有就是空字串。
  final String comment;

  /// 算公鑰。OpenSSH 私鑰的公鑰段是明文,**有 passphrase 也算得出來**
  /// (只是 comment 要解得開才有);舊式 PEM 才非要 passphrase 不可。
  /// 解密的 KDF 要跑上幾十毫秒,整段丟背景 isolate 以免卡 UI。
  static Future<SshPublicKeyInfo> derive(
    String privateKey, {
    String? passphrase,
  }) async {
    final pass = passphrase ?? '';
    final json = await Isolate.run(() {
      final ffiLib = TermFfi();
      final pemC = privateKey.toNativeUtf8();
      final passC = pass.toNativeUtf8();
      try {
        var cap = 4096;
        for (;;) {
          final buf = calloc<ffi.Uint8>(cap);
          try {
            final need = ffiLib.sshPublicKey(pemC, passC, buf, cap);
            if (need <= cap) return utf8Decode(buf.asTypedList(need));
            cap = need; // 純計算、可重試:buffer 不夠就加大重呼叫
          } finally {
            calloc.free(buf);
          }
        }
      } finally {
        calloc.free(pemC);
        calloc.free(passC);
      }
    });
    final map = jsonDecode(json) as Map<String, dynamic>;
    if (map['error'] != null) throw SshKeyException(describeNativeError(map));
    return SshPublicKeyInfo(
      openssh: map['publicKey'] as String? ?? '',
      algorithm: map['algorithm'] as String? ?? '',
      fingerprint: map['fingerprint'] as String? ?? '',
      comment: map['comment'] as String? ?? '',
    );
  }
}

/// 在 app 內產生的 SSH 金鑰對(手機上沒有 ssh-keygen)。
class GeneratedSshKey {
  const GeneratedSshKey({required this.privateKey, required this.publicKey});

  /// OpenSSH 格式私鑰(與 ssh-keygen 相同);有 passphrase 時已加密。
  final String privateKey;

  final SshPublicKeyInfo publicKey;

  /// 可選的種類(同 `ssh-keygen -t`):ed25519(預設)、rsa(4096 bits)。
  static const kinds = ['ed25519', 'rsa'];

  /// 與 core 的 SSH_GENERATE_KEY_MAX 一致:產生金鑰不是冪等的(重呼叫就是
  /// 另一把),buffer 一次給足、絕不「不夠再重呼叫」。
  static const _cap = 16 * 1024;

  /// 產生新金鑰。[passphrase] 空字串 = 私鑰不加密。RSA 要找質數、加密要跑
  /// KDF,整段丟背景 isolate 以免卡 UI。
  static Future<GeneratedSshKey> generate({
    String kind = 'ed25519',
    String comment = '',
    String passphrase = '',
  }) async {
    final json = await Isolate.run(() {
      final ffiLib = TermFfi();
      final kindC = kind.toNativeUtf8();
      final commentC = comment.toNativeUtf8();
      final passC = passphrase.toNativeUtf8();
      final buf = calloc<ffi.Uint8>(_cap);
      try {
        final n = ffiLib.sshGenerateKey(kindC, commentC, passC, buf, _cap);
        if (n > _cap) {
          return jsonEncode({'error': 'generated key exceeds $_cap bytes'});
        }
        return utf8Decode(buf.asTypedList(n));
      } finally {
        // 私鑰別留在已釋放的記憶體裡
        buf.asTypedList(_cap).fillRange(0, _cap, 0);
        calloc.free(buf);
        calloc.free(kindC);
        calloc.free(commentC);
        calloc.free(passC);
      }
    });
    final map = jsonDecode(json) as Map<String, dynamic>;
    if (map['error'] != null) throw SshKeyException(describeNativeError(map));
    return GeneratedSshKey(
      privateKey: map['privateKey'] as String,
      publicKey: SshPublicKeyInfo(
        openssh: map['publicKey'] as String? ?? '',
        algorithm: map['algorithm'] as String? ?? '',
        fingerprint: map['fingerprint'] as String? ?? '',
        comment: map['comment'] as String? ?? '',
      ),
    );
  }
}

/// SFTP 操作失敗(權限、找不到檔案、連線斷…)。
class SftpException implements Exception {
  SftpException(this.message);
  final String message;
  @override
  String toString() => message;
}

String utf8Decode(Uint8List bytes) =>
    bytes.isEmpty ? '' : const Utf8Decoder(allowMalformed: true).convert(bytes);

/// 一個 terminal session(對應 Rust 端 `Session`)。
class NativeSession {
  NativeSession._(this._ffi, this._handle, this._cols, this._rows) {
    _allocGrid();
    _cursorBuf = calloc<ffi.Uint32>(3);
    _ioBuf = calloc<ffi.Uint8>(_ioCap);
  }

  /// 開本地 shell;失敗時丟出含原生錯誤訊息的 exception。
  factory NativeSession.spawnShell({
    required int cols,
    required int rows,
    int scrollback = 10000,
    String? program,
  }) {
    final ffiLib = TermFfi();
    final prog = program == null
        ? ffi.Pointer<Utf8>.fromAddress(0)
        : program.toNativeUtf8();
    try {
      final handle = ffiLib.spawnShell(cols, rows, scrollback, prog);
      if (handle.address == 0) {
        throw StateError(l10n.localShellFailed(ffiLib.takeLastErrorMessage()));
      }
      return NativeSession._(ffiLib, handle, cols, rows);
    } finally {
      if (program != null) calloc.free(prog);
    }
  }

  /// 無資料來源(合成資料 / 測試用)。
  factory NativeSession.headless({
    required int cols,
    required int rows,
    int scrollback = 10000,
  }) {
    final ffiLib = TermFfi();
    return NativeSession._(
      ffiLib,
      ffiLib.newHeadless(cols, rows, scrollback),
      cols,
      rows,
    );
  }

  /// 連上 SSH server 開 shell。連線是阻塞的網路操作,放到背景 isolate 執行
  /// 以免卡住 UI;handle 是 process-global 指標,可跨 isolate 使用。
  ///
  /// [config] 需含 host/port/username/auth(見 tterm_session_connect_ssh);
  /// cols/rows/scrollback 會併入 config。連線失敗丟 [SshConnectException]。
  static Future<NativeSession> connectSsh({
    required Map<String, dynamic> config,
    required int cols,
    required int rows,
    int scrollback = 10000,
  }) async {
    final fullConfig = {
      ...config,
      'cols': cols,
      'rows': rows,
      'scrollback': scrollback,
    };
    final result = await Isolate.run(() {
      final ffiLib = TermFfi();
      final cfgC = jsonEncode(fullConfig).toNativeUtf8();
      try {
        final handle = ffiLib.connectSsh(cfgC);
        if (handle.address == 0) {
          return <String, dynamic>{'error': ffiLib.takeLastError()};
        }
        const cap = 256;
        final buf = calloc<ffi.Uint8>(cap);
        try {
          final n = ffiLib.sshFingerprint(handle, buf, cap);
          return <String, dynamic>{
            'addr': handle.address,
            'fingerprint': utf8Decode(buf.asTypedList(n)),
          };
        } finally {
          calloc.free(buf);
        }
      } finally {
        calloc.free(cfgC);
      }
    });
    final error = result['error'] as String?;
    if (error != null) {
      if (error.isEmpty) throw SshConnectException(l10n.sshConnectFailed);
      throw HostKeyMismatchException.tryParse(error) ??
          SshConnectException(describeLastError(error));
    }
    final session = NativeSession._(
      TermFfi(),
      ffi.Pointer.fromAddress(result['addr'] as int),
      cols,
      rows,
    );
    session._fingerprint = result['fingerprint'] as String?;
    return session;
  }

  static const _ioCap = 1 << 20;

  final TermFfi _ffi;
  final ffi.Pointer<ffi.Void> _handle;
  int _cols;
  int _rows;
  late ffi.Pointer<ffi.Uint32> _grid;
  late ffi.Pointer<ffi.Uint32> _cursorBuf;
  late ffi.Pointer<ffi.Uint8> _ioBuf;
  Uint32List? _gridSnapshot; // copyGrid 的 Dart 自有快照(見 copyGrid)
  bool _disposed = false;
  String? _fingerprint;

  int get cols => _cols;
  int get rows => _rows;

  /// SSH host key 指紋(`SHA256:...`);本地 shell session 為 null。
  String? get sshFingerprint => _fingerprint;

  void _allocGrid() => _grid = calloc<ffi.Uint32>(_cols * _rows * 4);

  void write(Uint8List bytes) {
    if (_disposed || bytes.isEmpty) return;
    var offset = 0;
    while (offset < bytes.length) {
      final n = (bytes.length - offset).clamp(0, _ioCap);
      _ioBuf.asTypedList(_ioCap).setRange(0, n, bytes, offset);
      _ffi.write(_handle, _ioBuf, n);
      offset += n;
    }
  }

  void resize(int cols, int rows) {
    if (_disposed || (cols == _cols && rows == _rows)) return;
    if (cols <= 0 || rows <= 0) return;
    _ffi.resize(_handle, cols, rows);
    _cols = cols;
    _rows = rows;
    calloc.free(_grid);
    _allocGrid();
  }

  /// 0 = 無變更、1 = 部分、2 = 整面。
  int takeDamage() => _disposed ? 0 : _ffi.takeDamage(_handle);

  /// 回傳 Dart 自有的快照 buffer(下次呼叫會覆寫,勿長期持有)。
  ///
  /// 不能直接回傳 native buffer 的 view:dispose/resize 會 free 掉 `_grid`,
  /// 持有 view 的一方(TerminalView._cells)會變 dangling——重新連線時
  /// 舊畫面淡出還在 paint,就讀到已釋放記憶體的垃圾 codepoint 而崩潰。
  /// dispose 後回傳最後一次快照(淡出期間仍顯示最後的畫面)。
  Uint32List copyGrid() {
    final len = _cols * _rows * 4;
    var snap = _gridSnapshot;
    if (snap == null || snap.length != len) {
      snap = _gridSnapshot = Uint32List(len);
    }
    if (!_disposed) {
      _ffi.copyGrid(_handle, _grid, _cols * _rows);
      snap.setAll(0, _grid.asTypedList(len));
    }
    return snap;
  }

  (int, int, bool) cursor() {
    if (_disposed) return (0, 0, false);
    _ffi.cursor(_handle, _cursorBuf);
    final v = _cursorBuf.asTypedList(3);
    return (v[0], v[1], v[2] != 0);
  }

  int get modes => _disposed ? 0 : _ffi.modes(_handle);

  bool get isAlive => !_disposed && _ffi.isAlive(_handle) != 0;

  void scroll(int delta) {
    if (!_disposed) _ffi.scroll(_handle, delta);
  }

  /// 把終端拉回一般狀態:離開 alt screen、關掉滑鼠回報、顯示游標。
  /// 前景 TUI 被強制中斷時不會送復原序列,終端卡在這些模式下滾輪會完全失效。
  void resetModes() {
    if (!_disposed) _ffi.resetModes(_handle);
  }

  /// 自動復原卡住的模式:本地 shell 底下已經沒有任何行程,卻還留著
  /// alt screen / 滑鼠回報 → 設它的程式早就死了,替它關掉。回傳是否有復原。
  bool recoverStuckModes() =>
      !_disposed && _ffi.recoverStuckModes(_handle) != 0;

  String get title {
    if (_disposed) return '';
    final n = _ffi.title(_handle, _ioBuf, 4096);
    return utf8Decode(_ioBuf.asTypedList(n));
  }

  /// 取走 OSC 52 設定的剪貼簿內容(tmux/vim 反白複製);沒有新內容回 null。
  String? takeClipboard() {
    if (_disposed) return null;
    final n = _ffi.takeClipboardFn(_handle, _ioBuf, 4096);
    if (n == 0) return null;
    if (n <= 4096) return utf8Decode(_ioBuf.asTypedList(n));
    // 超過共用 buffer:擴大重呼叫(> cap 時內容沒被取走)
    final buf = calloc<ffi.Uint8>(n);
    try {
      final m = _ffi.takeClipboardFn(_handle, buf, n);
      if (m == 0 || m > n) return null; // 又變了就等下一輪
      return utf8Decode(buf.asTypedList(m));
    } finally {
      calloc.free(buf);
    }
  }

  /// OSC 7 工作目錄;shell 沒送則回 null。
  String? get currentDirectory {
    if (_disposed) return null;
    final n = _ffi.currentDir(_handle, _ioBuf, 4096);
    if (n == 0) return null;
    return utf8Decode(_ioBuf.asTypedList(n));
  }

  /// 本地 shell 目前工作目錄(直接讀子行程,不靠 OSC 7)。
  /// 給 Windows 的 cmd.exe / PowerShell 不送 OSC 7 時用;抓不到回 null。
  String? get localDirectory {
    if (_disposed) return null;
    final n = _ffi.localCwd(_handle, _ioBuf, 4096);
    if (n == 0) return null;
    return utf8Decode(_ioBuf.asTypedList(n));
  }

  /// 是不是 SSH session(檔案側窗決定走遠端 SFTP 還是本地)。
  bool get isSsh => !_disposed && _ffi.isSsh(_handle) != 0;

  /// SFTP 回傳約定:usize::MAX(Dart 端 = -1)= 失敗;>cap = buffer 不夠重試。
  Uint8List _sftpBytes(
    int Function(ffi.Pointer<ffi.Uint8> out, int cap) call, {
    int initialCap = 256 * 1024,
  }) {
    var cap = initialCap;
    for (;;) {
      final buf = calloc<ffi.Uint8>(cap);
      try {
        final n = call(buf, cap);
        if (n < 0) throw SftpException(_ffi.takeLastErrorMessage());
        if (n <= cap) return Uint8List.fromList(buf.asTypedList(n));
        cap = n; // 不夠大,擴大重讀(讀取冪等)
      } finally {
        calloc.free(buf);
      }
    }
  }

  /// 遠端 home 目錄。
  String sftpHome() =>
      utf8.decode(_sftpBytes((out, cap) => _ffi.sftpHome(_handle, out, cap), initialCap: 4096));

  /// 在遠端執行命令(獨立 exec channel),回傳 stdout 文字。
  /// [stdin] 送入後關閉輸入端——腳本要用 `sh -s` + stdin 送(sshd 用登入
  /// shell 跑 exec 命令,腳本放命令列遇到 zsh/fish 會爛)。
  /// 輸出超過 buffer 會截斷(exec 不可重跑,不走擴大重呼叫);失敗丟例外。
  String sshExec(
    String cmd, {
    String stdin = '',
    int timeoutMs = 3000,
    int cap = 64 * 1024,
  }) {
    final cmdC = cmd.toNativeUtf8();
    final stdinBytes = utf8.encode(stdin);
    final stdinPtr = calloc<ffi.Uint8>(stdinBytes.length + 1);
    final buf = calloc<ffi.Uint8>(cap);
    try {
      stdinPtr.asTypedList(stdinBytes.length + 1).setAll(0, stdinBytes);
      final n = _ffi.sshExec(
          _handle, cmdC, stdinPtr, stdinBytes.length, timeoutMs, buf, cap);
      if (n < 0) throw SftpException(_ffi.takeLastErrorMessage());
      return utf8Decode(buf.asTypedList(n.clamp(0, cap)));
    } finally {
      calloc.free(cmdC);
      calloc.free(stdinPtr);
      calloc.free(buf);
    }
  }

  /// 遠端目錄列表 → 每筆 {name, isDir, size}。
  List<Map<String, dynamic>> sftpList(String path) {
    final pathC = path.toNativeUtf8();
    try {
      final bytes =
          _sftpBytes((out, cap) => _ffi.sftpList(_handle, pathC, out, cap));
      final list = jsonDecode(utf8.decode(bytes)) as List<dynamic>;
      return [for (final e in list) (e as Map).cast<String, dynamic>()];
    } finally {
      calloc.free(pathC);
    }
  }

  /// 讀遠端檔案。
  Uint8List sftpRead(String path) {
    final pathC = path.toNativeUtf8();
    try {
      return _sftpBytes(
        (out, cap) => _ffi.sftpReadFn(_handle, pathC, out, cap),
        initialCap: 1 << 20,
      );
    } finally {
      calloc.free(pathC);
    }
  }

  /// 寫遠端檔案(覆寫)。
  void sftpWrite(String path, Uint8List data) {
    final pathC = path.toNativeUtf8();
    final dataPtr = calloc<ffi.Uint8>(data.length);
    try {
      dataPtr.asTypedList(data.length).setAll(0, data);
      if (_ffi.sftpWrite(_handle, pathC, dataPtr, data.length) != 0) {
        throw SftpException(_ffi.takeLastErrorMessage());
      }
    } finally {
      calloc.free(pathC);
      calloc.free(dataPtr);
    }
  }

  int get bellCount => _disposed ? 0 : _ffi.bellCount(_handle);

  int demoFeed(int scenario, int nbytes) =>
      _disposed ? 0 : _ffi.demoFeed(_handle, scenario, nbytes);

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _ffi.free(_handle);
    calloc.free(_grid);
    calloc.free(_cursorBuf);
    calloc.free(_ioBuf);
  }
}
