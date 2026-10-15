// 開發用:印出 TTERM_DATA_DIR vault 的 snapshot(檢查 TOFU 指紋等)。
import 'dart:convert';

import 'dart:io';

import 'package:tterm_app/src/app_dirs.dart';
import 'package:tterm_app/src/vault_ffi.dart';

void main() {
  final dir = '${appBaseDir()}${Platform.pathSeparator}vault';
  final vault = NativeVault.open(dir);
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(vault.snapshot()));
  vault.dispose();
}
