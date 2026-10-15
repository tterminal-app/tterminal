// Rust core 回報的錯誤 → 給使用者看的訊息。
//
// 錯誤通道(tterm_last_error 與 vault / 公鑰的 JSON 回傳)都是
// `{"error": 英文訊息, "code"?: ..., "args"?: {...}}`,格式與 code 清單見
// core/tterm-ffi/src/error.rs。core 的訊息一律英文;使用者常碰到的幾種另帶
// 穩定的 code,這裡依目前語系翻成完整句子。沒有 code 的多半是 OS 或程式
// 錯誤,照原文顯示。
//
// 一定要在主 isolate 翻:背景 isolate 拿不到系統語系(也沒有測試的覆寫)。

import 'dart:convert';

import 'l10n.dart';

/// 錯誤 JSON → 使用者看的訊息。
String describeNativeError(Map<String, dynamic> json) {
  final args = (json['args'] as Map?)?.cast<String, dynamic>() ?? const {};
  String arg(String name) => '${args[name] ?? ''}';
  final s = l10n;
  return switch (json['code']) {
    'host_key_mismatch' => s.errHostKeyMismatch(arg('expected'), arg('actual')),
    'timeout' => s.errTimeout(arg('op')),
    'private_key_unreadable' => s.errPrivateKeyUnreadable(arg('reason')),
    'pairing_missing_prefix' => s.errPairingMissingPrefix,
    'pairing_unsupported_version' => s.errPairingUnsupportedVersion(
      (args['version'] as num?)?.toInt() ?? 0,
    ),
    'pairing_malformed' => s.errPairingMalformed,
    'decrypt_failed' => s.errDecryptFailed,
    _ => json['error'] as String? ?? '',
  };
}

/// `tterm_last_error` 的內容(同一種 JSON;解不開就當純文字)。
String describeLastError(String raw) {
  try {
    final value = jsonDecode(raw);
    if (value is Map<String, dynamic>) return describeNativeError(value);
  } on FormatException {
    // 被截斷或不是 JSON:原文照登
  }
  return raw;
}
