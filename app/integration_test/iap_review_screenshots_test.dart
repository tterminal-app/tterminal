// App 內購買項目的審查截圖(只給 App Review 看,不上商店頁),由 appstore/shoot.sh 接手截圖:
//
//   SHOT_TEST=integration_test/iap_review_screenshots_test.dart SHOT_NO_HOST=1 \
//     appstore/shoot.sh iphone appstore/raw/iap-review-en en
//
//   iap-trial   第一次開 app 自動跳出的試用說明(dev.tterm.ttermApp.trial14)
//   iap-unlock  試用中從設定 → Trial & unlock → Unlock 打開的解鎖畫面(dev.tterm.ttermApp.unlock)
//
// 價格是 FakePurchaseService 的預設字串,實際上架時由 StoreKit 給在地價格。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tterm_app/main.dart';
import 'package:tterm_app/src/purchases.dart';

import 'shot_helpers.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('iap review screenshots', (tester) async {
    // 試用說明只在第一次開 app、還沒開始試用時自動跳一次
    updatePrefs({'trialIntroSeen': false});
    await tester.pumpWidget(
      TtermApp(demoMode: false, purchases: FakePurchaseService.notStarted()),
    );
    await waitFor(tester, find.byKey(const Key('btn-start-trial')));
    await pause(tester, 1000);
    await shot(tester, 'iap-trial');

    // 換成試用中:設定頁的「Trial & unlock」才有解鎖按鈕。
    // 換 key 才會整棵重建,不然會沿用上一個 app 的狀態(試用說明還開著、購買服務也是舊的)
    await tester.pumpWidget(
      TtermApp(
        key: const ValueKey('trial'),
        demoMode: false,
        purchases: FakePurchaseService.trial(),
      ),
    );
    await pause(tester, 1500);
    await tester.tap(find.byKey(const Key('btn-settings')));
    await pause(tester, 1000);
    final unlock = find.byKey(const Key('btn-settings-unlock'));
    await waitFor(tester, unlock);
    await tester.ensureVisible(unlock);
    await pause(tester, 500);
    await tester.tap(unlock);
    await waitFor(tester, find.byKey(const Key('unlock-page')));
    await pause(tester, 1000);
    await shot(tester, 'iap-unlock');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
