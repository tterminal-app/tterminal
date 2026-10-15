// 試用與一次性解鎖(只有 iOS 版收費)。
//
// 收費模式:免費下載 + 14 天試用 + 一次性解鎖(App Store Connect 的設定見 appstore/iap.md)。
//   * 試用 = US$0 的非消耗型內購(審查準則 3.1.1),試用起點是那筆交易的
//     購買日,跟著 Apple 帳號走,重裝、換手機都不會重新計時
//   * 解鎖 = 一次性非消耗型內購
//   * 試用中或已解鎖:功能全開。試用到期又沒解鎖:只有「開新的 SSH 連線」
//     要先解鎖,主機、金鑰、Vaults、設定、同步都照常可用
//
// [PurchaseService] 是可注入的介面:iOS 用 [StoreKitPurchaseService]
// (ios/Runner/StoreBridge.swift),widget test 與商店截圖用
// [FakePurchaseService] 假造狀態。其他平台不建服務(null = 不收費)。

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;

import 'l10n.dart';

/// App Store Connect 上的產品 ID(appstore/iap.md、ios/Runner/StoreBridge.swift 同一組)。
const kTrialProductId = 'dev.tterm.ttermApp.trial14';
const kUnlockProductId = 'dev.tterm.ttermApp.unlock';

/// 試用長度。
const kTrialLength = Duration(days: 14);

/// `--dart-define=TTERM_IAP=false` = iOS 也不收費。只給 App Store Connect 還沒建好
/// 內購品項時的 TestFlight 內測用(不然讀不到價格、開不了試用,就完全不能連線);
/// 送審與上架的版本不要加。見 appstore/iap.md。
const kPurchasesEnabled = bool.fromEnvironment('TTERM_IAP', defaultValue: true);

/// 這個平台要用的購買服務;null = 不收費(iOS 以外的平台)。
PurchaseService? createPlatformPurchaseService() =>
    Platform.isIOS && kPurchasesEnabled ? StoreKitPurchaseService() : null;

/// StoreKit 裡讀到的權限(已驗證、沒被撤銷的交易)。
@immutable
class Entitlements {
  const Entitlements({this.trialStart, this.unlocked = false});

  /// 試用交易的購買日;null = 還沒開始試用。
  final DateTime? trialStart;
  final bool unlocked;

  /// native payload:`{unlocked: bool, trialStart: 毫秒 epoch | null}`。
  factory Entitlements.decode(Map<Object?, Object?>? raw) {
    final start = raw?['trialStart'];
    return Entitlements(
      unlocked: raw?['unlocked'] == true,
      trialStart: start is num
          ? DateTime.fromMillisecondsSinceEpoch(start.round())
          : null,
    );
  }
}

enum AccessKind {
  /// 還在向 StoreKit 讀權限。
  loading,

  /// 還沒開始試用,也沒買。
  notStarted,
  trial,
  expired,
  unlocked,
}

/// 目前能不能用,以及試用還剩多久。
@immutable
class AccessStatus {
  const AccessStatus._(this.kind, {this.trialEndsAt, this.daysLeft = 0});

  static const loading = AccessStatus._(AccessKind.loading);

  factory AccessStatus.of(Entitlements e, DateTime now) {
    if (e.unlocked) return const AccessStatus._(AccessKind.unlocked);
    final start = e.trialStart;
    if (start == null) return const AccessStatus._(AccessKind.notStarted);
    final end = start.add(kTrialLength);
    final left = end.difference(now);
    if (left <= Duration.zero) {
      return AccessStatus._(AccessKind.expired, trialEndsAt: end);
    }
    // 無條件進位:剛開始是 14 天,最後不到一天算 1 天。裝置時間被調到
    // 試用開始之前也不會超過 14 天。
    final days = (left.inSeconds / Duration.secondsPerDay).ceil();
    return AccessStatus._(
      AccessKind.trial,
      trialEndsAt: end,
      daysLeft: days.clamp(1, kTrialLength.inDays),
    );
  }

  final AccessKind kind;

  /// 試用結束的時間(試用中或已到期才有)。
  final DateTime? trialEndsAt;

  /// 試用還剩幾天(試用中才有意義,至少 1)。
  final int daysLeft;

  /// 可以開新的 SSH 連線。
  bool get canConnect => kind == AccessKind.trial || kind == AccessKind.unlocked;
}

enum PurchaseOutcome {
  success,

  /// 使用者自己取消(不用提示)。
  cancelled,

  /// 等家長核准(Ask to Buy)或付款還在處理,核准後 Transaction.updates 會通知。
  pending,
  failed,
}

@immutable
class PurchaseResult {
  const PurchaseResult(this.outcome, [this.message]);

  final PurchaseOutcome outcome;

  /// 失敗原因(StoreKit 給的在地化訊息)。
  final String? message;
}

/// 試用 / 解鎖狀態與購買動作。
abstract class PurchaseService extends ChangeNotifier {
  PurchaseService({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  Entitlements? _entitlements;
  final _ready = Completer<void>();

  /// 每次讀都用現在時間算,試用在 app 開著時到期也不會漏。
  AccessStatus get status {
    final e = _entitlements;
    return e == null ? AccessStatus.loading : AccessStatus.of(e, _clock());
  }

  /// 第一次讀到權限(或確定讀不到)後完成。
  Future<void> get ready => _ready.future;

  /// 解鎖品項的在地價格字串(StoreKit 的 displayPrice,例如「NT$490」)。
  /// null = 還沒讀到或讀不到,看 [productsLoading]。
  String? get unlockPrice;
  bool get productsLoading;

  /// 重新向商店要品項與價格(第一次讀不到時,解鎖畫面的「再試一次」)。
  Future<void> loadProducts();

  /// 買 US$0 的試用品項。
  Future<PurchaseResult> startTrial();
  Future<PurchaseResult> unlock();

  /// 恢復購買(AppStore.sync)。
  Future<PurchaseResult> restore();

  @protected
  void setEntitlements(Entitlements e) {
    _entitlements = e;
    markReady();
    notifyListeners();
  }

  @protected
  void markReady() {
    if (!_ready.isCompleted) _ready.complete();
  }

  bool _disposed = false;

  /// StoreKit 的回應可能在 dispose 之後才到。
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// iOS:StoreKit 2,經 `tterm/store` channel 橋接 ios/Runner/StoreBridge.swift。
class StoreKitPurchaseService extends PurchaseService {
  StoreKitPurchaseService() {
    _channel.setMethodCallHandler((call) async {
      // 別台裝置買的、Ask to Buy 核准、退款撤銷……native 一收到就叫這裡重讀
      if (call.method == 'changed') await refresh();
    });
    // 回前台重讀一次:試用可能在背景時到期,畫面上的天數也要更新;
    // 剛開 app 時離線讀不到的價格也順便再要一次
    _lifecycle = AppLifecycleListener(
      onResume: () {
        unawaited(refresh());
        if (_unlockPrice == null) unawaited(loadProducts());
      },
    );
    unawaited(refresh());
    unawaited(loadProducts());
  }

  static const _channel = MethodChannel('tterm/store');

  late final AppLifecycleListener _lifecycle;
  String? _unlockPrice;
  bool _productsLoading = false;

  @override
  String? get unlockPrice => _unlockPrice;
  @override
  bool get productsLoading => _productsLoading;

  Future<void> refresh() async {
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
        'entitlements',
      );
      setEntitlements(Entitlements.decode(raw));
    } on MissingPluginException {
      // native 還沒接上;接上時會送 changed 過來
    } on PlatformException {
      // 讀不到就維持原狀;ready 照樣完成,開連線時不會一直卡著等
      markReady();
    }
  }

  @override
  Future<void> loadProducts() async {
    if (_productsLoading) return;
    _productsLoading = true;
    notifyListeners();
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
        'products',
      );
      final unlock = raw?[kUnlockProductId];
      final price = unlock is Map ? unlock['price'] : null;
      if (price is String) _unlockPrice = price;
    } on PlatformException {
      // 離線或商店還沒有這個品項:價格維持 null,畫面上可以再試一次
    } on MissingPluginException {
      // 同上
    } finally {
      _productsLoading = false;
      notifyListeners();
    }
  }

  @override
  Future<PurchaseResult> startTrial() => _purchase(kTrialProductId);

  @override
  Future<PurchaseResult> unlock() => _purchase(kUnlockProductId);

  Future<PurchaseResult> _purchase(String productId) async {
    try {
      final r = await _channel.invokeMethod<String>('purchase', productId);
      await refresh();
      return PurchaseResult(switch (r) {
        'success' => PurchaseOutcome.success,
        'pending' => PurchaseOutcome.pending,
        _ => PurchaseOutcome.cancelled,
      });
    } on PlatformException catch (e) {
      return PurchaseResult(PurchaseOutcome.failed, _errorText(e));
    } on MissingPluginException catch (e) {
      return PurchaseResult(PurchaseOutcome.failed, '$e');
    }
  }

  /// StoreBridge 自己的錯誤代碼在這裡翻;StoreKit 的錯誤訊息系統已經在地化了。
  static String _errorText(PlatformException e) => switch (e.code) {
    'not_found' => l10n.storeItemUnavailable,
    'unverified' => l10n.storeUnverified,
    _ => e.message ?? e.code,
  };

  @override
  Future<PurchaseResult> restore() async {
    try {
      await _channel.invokeMethod<void>('restore');
      await refresh();
      return const PurchaseResult(PurchaseOutcome.success);
    } on PlatformException catch (e) {
      if (e.code == 'cancelled') {
        return const PurchaseResult(PurchaseOutcome.cancelled);
      }
      return PurchaseResult(PurchaseOutcome.failed, _errorText(e));
    } on MissingPluginException catch (e) {
      return PurchaseResult(PurchaseOutcome.failed, '$e');
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _channel.setMethodCallHandler(null);
    super.dispose();
  }
}

/// 不接商店、狀態寫死:widget test 假造四種狀態,商店截圖固定成已解鎖。
/// 購買與恢復都立刻成功;[nextOutcome] 可以改成取消、等待核准或失敗。
class FakePurchaseService extends PurchaseService {
  FakePurchaseService._(
    Entitlements entitlements, {
    super.clock,
    this.unlockPrice = 'US\$14.99',
    this.restoreFindsUnlock = false,
  }) {
    setEntitlements(entitlements);
  }

  FakePurchaseService.notStarted({
    DateTime Function()? clock,
    String? unlockPrice = 'US\$14.99',
    bool restoreFindsUnlock = false,
  }) : this._(
         const Entitlements(),
         clock: clock,
         unlockPrice: unlockPrice,
         restoreFindsUnlock: restoreFindsUnlock,
       );

  /// 試用中,還剩 [daysLeft] 天。
  factory FakePurchaseService.trial({
    int daysLeft = 9,
    DateTime Function()? clock,
    bool restoreFindsUnlock = false,
  }) {
    final now = (clock ?? DateTime.now)();
    return FakePurchaseService._(
      Entitlements(
        trialStart: now.subtract(kTrialLength - Duration(days: daysLeft)),
      ),
      clock: clock,
      restoreFindsUnlock: restoreFindsUnlock,
    );
  }

  /// 試用在 [ago] 之前結束,沒有解鎖。
  factory FakePurchaseService.expired({
    Duration ago = const Duration(days: 3),
    DateTime Function()? clock,
    bool restoreFindsUnlock = false,
  }) {
    final now = (clock ?? DateTime.now)();
    return FakePurchaseService._(
      Entitlements(trialStart: now.subtract(kTrialLength + ago)),
      clock: clock,
      restoreFindsUnlock: restoreFindsUnlock,
    );
  }

  FakePurchaseService.unlocked({DateTime Function()? clock})
    : this._(const Entitlements(unlocked: true), clock: clock);

  @override
  final String? unlockPrice;
  @override
  bool get productsLoading => false;

  /// 恢復購買時是不是找得到解鎖紀錄。
  bool restoreFindsUnlock;

  /// 下一次購買的結果(用一次就回到 success)。
  PurchaseOutcome nextOutcome = PurchaseOutcome.success;

  /// 呼叫紀錄,測試拿來確認按了哪個鈕。
  final calls = <String>[];

  Entitlements get _current => _entitlements ?? const Entitlements();

  @override
  Future<void> loadProducts() async {}

  @override
  Future<PurchaseResult> startTrial() async {
    calls.add('startTrial');
    return _complete(
      () => Entitlements(
        // 已經試用過就沿用原本的起點(跟 StoreKit 重買非消耗型一樣)
        trialStart: _current.trialStart ?? _clock(),
        unlocked: _current.unlocked,
      ),
    );
  }

  @override
  Future<PurchaseResult> unlock() async {
    calls.add('unlock');
    return _complete(
      () => Entitlements(trialStart: _current.trialStart, unlocked: true),
    );
  }

  @override
  Future<PurchaseResult> restore() async {
    calls.add('restore');
    if (restoreFindsUnlock) {
      setEntitlements(
        Entitlements(trialStart: _current.trialStart, unlocked: true),
      );
    }
    return const PurchaseResult(PurchaseOutcome.success);
  }

  PurchaseResult _complete(Entitlements Function() next) {
    final outcome = nextOutcome;
    nextOutcome = PurchaseOutcome.success;
    if (outcome == PurchaseOutcome.success) setEntitlements(next());
    return PurchaseResult(
      outcome,
      outcome == PurchaseOutcome.failed ? 'fake failure' : null,
    );
  }
}
