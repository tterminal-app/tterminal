// host key 跟記住的指紋不符時,分頁內容改顯示這個畫面(桌面與手機共用):
// 講清楚發生什麼事、並列新舊指紋,給一條「確認主機換過了 → 改用新指紋」的路,
// 不必刪掉 host 重新新增。改用新指紋要再經過確認對話框、勾選「已核對」才按得
// 下去 —— 這是擋中間人攻擊的最後一道,不能一鍵就過。

import 'package:flutter/material.dart';

import 'l10n.dart';
import 'ssh_connect.dart';
import 'tabs.dart';
import 'vault_service.dart';

/// [tab] 必須是 host key 不符而失敗的分頁(`tab.hostKeyMismatch` 有值)。
class HostKeyMismatchView extends StatelessWidget {
  const HostKeyMismatchView({
    super.key,
    required this.tab,
    required this.tabs,
    required this.vault,
    this.onReconnect,
  });

  final TermTab tab;
  final TabsController tabs;
  final VaultService? vault;

  /// 照舊設定再試一次(例如懷疑是一時連到不對的網路)。
  final VoidCallback? onReconnect;

  @override
  Widget build(BuildContext context) {
    final vault = this.vault;
    // host 可能在畫面開著時被刪掉(或同步進來),「改用新指紋」要跟著消失
    return vault == null
        ? _build(context)
        : ListenableBuilder(
            listenable: vault,
            builder: (context, _) => _build(context),
          );
  }

  Widget _build(BuildContext context) {
    final theme = Theme.of(context);
    final warn = theme.colorScheme.error;
    final tabId = tab.id;
    final hostName = tab.label;
    final mismatch = tab.hostKeyMismatch;
    // 重連一開始就清掉;父層下一個 frame 會換成連線中畫面
    if (mismatch == null) return const SizedBox.shrink();
    final onTrust = trustNewHostKeyAction(tabs: tabs, vault: vault, tab: tab);

    Future<void> trust() async {
      final ok = await confirmTrustNewHostKey(
        context,
        hostName: hostName,
        fingerprint: mismatch.actual,
      );
      if (ok) onTrust?.call();
    }

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.gpp_maybe_outlined, color: warn, size: 28),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      l10n.hostKeyChangedTitle,
                      style: theme.textTheme.titleLarge?.copyWith(color: warn),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(l10n.hostKeyChangedBody(hostName)),
              const SizedBox(height: 20),
              _Fingerprint(
                key: ValueKey('hostkey-expected-$tabId'),
                label: l10n.hostKeyRemembered,
                value: mismatch.expected,
              ),
              const SizedBox(height: 12),
              _Fingerprint(
                key: ValueKey('hostkey-actual-$tabId'),
                label: l10n.hostKeyPresented,
                value: mismatch.actual,
                highlight: true,
              ),
              const SizedBox(height: 16),
              Text(l10n.hostKeyHowToVerify, style: theme.textTheme.bodySmall),
              const SizedBox(height: 24),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  if (onReconnect != null)
                    FilledButton.tonalIcon(
                      key: ValueKey('btn-reconnect-$tabId'),
                      onPressed: onReconnect,
                      icon: const Icon(Icons.refresh),
                      label: Text(l10n.reconnect),
                    ),
                  if (onTrust != null)
                    OutlinedButton.icon(
                      key: ValueKey('btn-trust-hostkey-$tabId'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: warn,
                        side: BorderSide(color: warn),
                      ),
                      onPressed: trust,
                      icon: const Icon(Icons.key_outlined),
                      label: Text(l10n.hostKeyTrustNew),
                    ),
                ],
              ),
              if (onTrust == null) ...[
                const SizedBox(height: 12),
                Text(l10n.hostKeyNotInVault, style: theme.textTheme.bodySmall),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 「改用新指紋」的確認:講清楚風險、再秀一次新指紋,勾了「已核對」才按得下去。
/// 回傳使用者是否確定改用。
Future<bool> confirmTrustNewHostKey(
  BuildContext context, {
  required String hostName,
  required String fingerprint,
}) async {
  var verified = false;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        final theme = Theme.of(context);
        final warn = theme.colorScheme.error;
        return AlertDialog(
          icon: Icon(Icons.warning_amber_rounded, color: warn),
          title: Text(l10n.hostKeyTrustTitle),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l10n.hostKeyTrustBody(hostName)),
                  const SizedBox(height: 16),
                  _Fingerprint(
                    label: l10n.hostKeyPresented,
                    value: fingerprint,
                    highlight: true,
                  ),
                  const SizedBox(height: 8),
                  CheckboxListTile(
                    key: const Key('chk-hostkey-verified'),
                    value: verified,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Text(l10n.hostKeyTrustCheckbox),
                    onChanged: (v) => setState(() => verified = v ?? false),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              key: const Key('btn-confirm-trust-hostkey'),
              style: FilledButton.styleFrom(
                backgroundColor: warn,
                foregroundColor: theme.colorScheme.onError,
              ),
              onPressed: verified ? () => Navigator.pop(context, true) : null,
              child: Text(l10n.hostKeyTrustConfirm),
            ),
          ],
        );
      },
    ),
  );
  return ok ?? false;
}

/// 標題 + 可選取的指紋(要能複製下來跟伺服器上的比對)。
class _Fingerprint extends StatelessWidget {
  const _Fingerprint({
    super.key,
    required this.label,
    required this.value,
    this.highlight = false,
  });

  final String label;
  final String value;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.textTheme.labelMedium),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(4),
            border: highlight
                ? Border.all(color: theme.colorScheme.error.withAlpha(160))
                : null,
          ),
          child: SelectableText(
            value,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          ),
        ),
      ],
    );
  }
}
