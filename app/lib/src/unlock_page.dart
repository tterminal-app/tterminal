// 試用說明 / 解鎖畫面,和設定頁的「試用與解鎖」區塊(狀態見 purchases.dart)。
//
// 試用說明照審查準則 3.1.1:開始試用前先講清楚試用多久、到期後哪些功能不能用、
// 解鎖要付多少錢。價格一律用 StoreKit 給的在地字串,讀不到就不讓人開始試用。

import 'dart:async';

import 'package:flutter/material.dart';

import 'l10n.dart';
import 'purchases.dart';

/// 開新 SSH 連線前呼叫:試用中或已解鎖直接放行;不然跳解鎖畫面,在那邊開始
/// 試用或買完就回 true。[service] 是 null(不收費的平台)一律放行。
Future<bool> ensureCanConnect(
  BuildContext context,
  PurchaseService? service,
) async {
  if (service == null) return true;
  if (service.status.kind == AccessKind.loading) {
    await service.ready.timeout(const Duration(seconds: 5), onTimeout: () {});
    // StoreKit 讀權限通常一瞬間;真的讀不到就先放行,不讓付過錢的人被擋在外面
    if (service.status.kind == AccessKind.loading) return true;
  }
  if (service.status.canConnect) return true;
  if (!context.mounted) return false;
  return showUnlockPage(context, service);
}

/// 開解鎖畫面;關掉時已經可以連線就回 true。
Future<bool> showUnlockPage(BuildContext context, PurchaseService service) async {
  await Navigator.of(context).push<void>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => UnlockPage(service: service),
    ),
  );
  return service.status.canConnect;
}

/// 內容跟著狀態走:
///   * 還沒試用:試用說明 + 「開始 14 天試用」(也可以直接解鎖)
///   * 試用中(從設定頁進來):解鎖
///   * 試用已結束(開新連線時跳出來):解鎖
/// 開始試用、買到或恢復到可以連線的狀態,就自己關掉。
class UnlockPage extends StatefulWidget {
  const UnlockPage({super.key, required this.service});

  final PurchaseService service;

  @override
  State<UnlockPage> createState() => _UnlockPageState();
}

class _UnlockPageState extends State<UnlockPage> {
  bool _busy = false;
  bool _closed = false;

  PurchaseService get _service => widget.service;

  @override
  void initState() {
    super.initState();
    _service.addListener(_onServiceChanged);
    // 上次讀不到價格(例如離線開 app):打開這頁時再要一次
    if (_service.unlockPrice == null && !_service.productsLoading) {
      unawaited(_service.loadProducts());
    }
  }

  @override
  void dispose() {
    _service.removeListener(_onServiceChanged);
    super.dispose();
  }

  /// 畫面開著時從別處解鎖了(Ask to Buy 核准、別台裝置買的):自己關掉。
  void _onServiceChanged() {
    if (_service.status.kind != AccessKind.unlocked) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _close());
  }

  void _close() {
    if (_closed || !mounted) return;
    _closed = true;
    Navigator.of(context).pop();
  }

  Future<void> _run(Future<PurchaseResult> Function() action) async {
    setState(() => _busy = true);
    final kindBefore = _service.status.kind;
    final PurchaseResult result;
    try {
      result = await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    void say(String text) =>
        messenger.showSnackBar(SnackBar(content: Text(text)));
    final status = _service.status;
    switch (result.outcome) {
      case PurchaseOutcome.success:
        if (status.kind == AccessKind.unlocked &&
            kindBefore != AccessKind.unlocked) {
          say(l10n.unlockedThanks);
        } else if (status.kind == AccessKind.trial &&
            kindBefore == AccessKind.notStarted) {
          say(l10n.trialStarted);
        }
      case PurchaseOutcome.pending:
        say(l10n.purchasePending);
      case PurchaseOutcome.failed:
        say(l10n.purchaseFailed(result.message ?? l10n.unknownError));
      case PurchaseOutcome.cancelled:
        break;
    }
    if (result.outcome == PurchaseOutcome.success &&
        status.kind != kindBefore &&
        status.canConnect) {
      _close();
    }
  }

  Future<void> _restore() async {
    setState(() => _busy = true);
    final PurchaseResult result;
    try {
      result = await _service.restore();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    switch (result.outcome) {
      case PurchaseOutcome.success:
        final unlocked = _service.status.kind == AccessKind.unlocked;
        messenger.showSnackBar(SnackBar(
          content: Text(
            unlocked ? l10n.restoreFoundUnlock : l10n.restoreNothing,
          ),
        ));
        // 恢復到解鎖,或在別台裝置開始過的試用還沒到期
        if (_service.status.canConnect) _close();
      case PurchaseOutcome.failed:
        messenger.showSnackBar(SnackBar(
          content: Text(l10n.restoreFailed(result.message ?? l10n.unknownError)),
        ));
      case PurchaseOutcome.cancelled || PurchaseOutcome.pending:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _service,
      builder: (context, _) {
        final status = _service.status;
        final theme = Theme.of(context);
        final price = _service.unlockPrice;
        final notStarted = status.kind == AccessKind.notStarted;
        return Scaffold(
          key: const Key('unlock-page'),
          appBar: AppBar(),
          // 說明可以捲,按鈕固定在底部:小螢幕也一眼看得到「開始試用」與「之後再說」
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Column(
                  children: [
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
                        children: [
                          Icon(
                            notStarted ? Icons.hourglass_top : Icons.lock_open,
                            size: 48,
                            color: theme.colorScheme.primary,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            switch (status.kind) {
                              AccessKind.notStarted => l10n.trialIntroTitle,
                              AccessKind.expired => l10n.trialEndedTitle,
                              _ => l10n.unlockTitle,
                            },
                            style: theme.textTheme.headlineSmall,
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 24),
                          ..._body(status, price),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: _buttons(status, price),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  List<Widget> _body(AccessStatus status, String? price) {
    final priceLine = price == null ? null : _priceText(status, price);
    return [
      if (status.kind == AccessKind.notStarted) ...[
        _Point(icon: Icons.schedule, text: l10n.trialIntroDuration),
        _Point(icon: Icons.lock_outline, text: l10n.trialIntroAfter),
      ] else if (status.kind == AccessKind.expired)
        _Point(icon: Icons.inventory_2_outlined, text: l10n.trialEndedKeepData)
      else if (status.kind == AccessKind.trial)
        _Point(icon: Icons.schedule, text: l10n.unlockTrialLeft(status.daysLeft)),
      if (priceLine != null)
        _Point(icon: Icons.sell_outlined, text: priceLine)
      else
        _PriceUnavailable(service: _service),
    ];
  }

  String _priceText(AccessStatus status, String price) =>
      switch (status.kind) {
        AccessKind.notStarted => l10n.trialIntroPrice(price),
        AccessKind.expired => l10n.trialEndedBody(price),
        _ => l10n.unlockBody(price),
      };

  List<Widget> _buttons(AccessStatus status, String? price) {
    // 價格讀不到 = 說明不完整,也買不了:購買按鈕都先停用
    final canBuy = !_busy && price != null;
    final unlockLabel = price == null
        ? l10n.unlockButton
        : l10n.unlockWithPrice(price);
    return [
      if (status.kind == AccessKind.notStarted) ...[
        FilledButton(
          key: const Key('btn-start-trial'),
          onPressed: canBuy ? () => _run(_service.startTrial) : null,
          child: Text(l10n.startTrialButton),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          key: const Key('btn-unlock'),
          onPressed: canBuy ? () => _run(_service.unlock) : null,
          child: Text(unlockLabel),
        ),
      ] else if (status.kind != AccessKind.unlocked)
        FilledButton(
          key: const Key('btn-unlock'),
          onPressed: canBuy ? () => _run(_service.unlock) : null,
          child: Text(unlockLabel),
        ),
      const SizedBox(height: 4),
      Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        children: [
          TextButton(
            key: const Key('btn-restore'),
            onPressed: _busy ? null : _restore,
            child: Text(l10n.restorePurchases),
          ),
          TextButton(
            key: const Key('btn-not-now'),
            onPressed: _busy ? null : _close,
            child: Text(l10n.notNow),
          ),
          if (_busy)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
        ],
      ),
    ];
  }
}

class _Point extends StatelessWidget {
  const _Point({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 22, color: Colors.grey.shade400),
        const SizedBox(width: 12),
        Expanded(child: Text(text, style: const TextStyle(height: 1.4))),
      ],
    ),
  );
}

class _PriceUnavailable extends StatelessWidget {
  const _PriceUnavailable({required this.service});

  final PurchaseService service;

  @override
  Widget build(BuildContext context) {
    if (service.productsLoading) {
      return _Point(icon: Icons.sell_outlined, text: l10n.priceLoading);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Point(icon: Icons.cloud_off, text: l10n.priceUnavailable),
        Padding(
          padding: const EdgeInsets.only(left: 34),
          child: OutlinedButton(
            key: const Key('btn-retry-price'),
            onPressed: service.loadProducts,
            child: Text(l10n.tryAgain),
          ),
        ),
      ],
    );
  }
}

/// 設定頁的「試用與解鎖」:目前狀態 + 解鎖 / 恢復購買。
class PurchaseSection extends StatefulWidget {
  const PurchaseSection({super.key, required this.service});

  final PurchaseService service;

  @override
  State<PurchaseSection> createState() => _PurchaseSectionState();
}

class _PurchaseSectionState extends State<PurchaseSection> {
  bool _restoring = false;

  Future<void> _restore() async {
    setState(() => _restoring = true);
    final PurchaseResult result;
    try {
      result = await widget.service.restore();
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
    if (!mounted) return;
    final text = switch (result.outcome) {
      PurchaseOutcome.success =>
        widget.service.status.kind == AccessKind.unlocked
            ? l10n.restoreFoundUnlock
            : l10n.restoreNothing,
      PurchaseOutcome.failed => l10n.restoreFailed(
        result.message ?? l10n.unknownError,
      ),
      _ => null,
    };
    if (text != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.service,
      builder: (context, _) {
        final status = widget.service.status;
        final (icon, title, hint) = switch (status.kind) {
          AccessKind.loading => (Icons.hourglass_empty, l10n.accessLoading, null),
          AccessKind.notStarted => (
            Icons.hourglass_top,
            l10n.accessNotStarted,
            l10n.accessNotStartedHint,
          ),
          AccessKind.trial => (
            Icons.schedule,
            l10n.accessTrial(status.daysLeft),
            l10n.accessTrialHint(
              MaterialLocalizations.of(context).formatMediumDate(
                status.trialEndsAt!,
              ),
            ),
          ),
          AccessKind.expired => (
            Icons.lock_outline,
            l10n.accessExpired,
            l10n.accessExpiredHint,
          ),
          AccessKind.unlocked => (
            Icons.verified_outlined,
            l10n.accessUnlocked,
            l10n.accessUnlockedHint,
          ),
        };
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(icon),
              title: Text(title, key: const Key('purchase-status')),
              subtitle: hint == null ? null : Text(hint),
            ),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                if (status.kind == AccessKind.notStarted ||
                    status.kind == AccessKind.trial ||
                    status.kind == AccessKind.expired)
                  FilledButton.icon(
                    key: const Key('btn-settings-unlock'),
                    onPressed: () =>
                        showUnlockPage(context, widget.service),
                    icon: const Icon(Icons.lock_open, size: 18),
                    label: Text(
                      status.kind == AccessKind.notStarted
                          ? l10n.startTrialButton
                          : l10n.unlockButton,
                    ),
                  ),
                OutlinedButton.icon(
                  key: const Key('btn-settings-restore'),
                  onPressed: _restoring ? null : _restore,
                  icon: const Icon(Icons.restore, size: 18),
                  label: Text(l10n.restorePurchases),
                ),
                if (_restoring)
                  const Padding(
                    padding: EdgeInsets.only(top: 10),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}
