// vault key 保管處的選擇:哪些平台走 Keychain、TTERM_DATA_DIR 時 account 分開,
// 以及沒給 keychain 時照舊是檔案模式(測試、Windows/Linux)。
//
// 這裡不碰真的 Keychain;Keychain 本身的讀寫與遷移在 Rust 端測
// (core/tterm-vault/tests/keystore.rs、core/tterm-ffi/src/keychain.rs)。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tterm_app/src/app_dirs.dart';
import 'package:tterm_app/src/vault_ffi.dart';

void main() {
  test('Windows / Linux 不用 Keychain', () {
    expect(vaultKeychainFor(apple: false), isNull);
    expect(vaultKeychainFor(apple: false, dataDirOverride: '/tmp/x'), isNull);
  });

  test('iOS / macOS 正式資料目錄用固定 account', () {
    final k = vaultKeychainFor(apple: true)!;
    expect(k.service, 'dev.tterm.tterminal.vault');
    expect(k.account, 'vault-key');
    expect(vaultKeychainFor(apple: true, dataDirOverride: '')!.account,
        'vault-key');
  });

  test('TTERM_DATA_DIR 覆寫時 account 帶路徑,不跟正式 vault 搶同一個項目', () {
    final a = vaultKeychainFor(apple: true, dataDirOverride: '/tmp/a')!;
    final b = vaultKeychainFor(apple: true, dataDirOverride: '/tmp/b')!;
    expect(a.account, isNot('vault-key'));
    expect(a.account, isNot(b.account));
    expect(a.service, b.service);
  });

  test('沒給 keychain:檔案模式,key 在 vault 目錄裡', () async {
    final tmp = await Directory.systemTemp.createTemp('tterm-vault-keychain');
    addTearDown(() => tmp.delete(recursive: true));
    final v = NativeVault.open('${tmp.path}/v');
    v.dispose();
    expect(File('${tmp.path}/v/vault.key').existsSync(), isTrue);
    expect(File('${tmp.path}/v/vault.tv').existsSync(), isTrue);
  });
}
