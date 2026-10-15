// 折疊螢幕(iPhone Duo / Android foldable)的摺痕感知。
//
// 版面一律只讀 MediaQuery.displayFeaturesOf,平台無關:
//   * Android:Flutter 原生就會把 hinge/fold 填進 displayFeatures
//   * iOS:Flutter 還沒接 iOS 27.1 的 reservedRegions(flutter#193025 未合),
//     由 native(ios/Runner/FoldBridge.swift)量好摺痕區域經 channel 送來,
//     這裡包成同型別的 DisplayFeature 疊進 MediaQuery
// Flutter 哪天原生支援了,MediaQuery 本來就有 feature → FoldFeatures 自動讓位。
//
// 摺痕只在「半開」時算數:攤平時 Apple 要求整塊當一張螢幕用,native 也不回報;
// Android 攤平的 fold 是零寬線 + postureFlat,這裡同樣忽略。

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:flutter/foundation.dart' show listEquals, visibleForTesting;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// iOS native 摺痕回報(其他平台永遠是空清單)。
class FoldBridge {
  FoldBridge._();

  static const _channel = MethodChannel('tterm/fold');

  /// 目前有效的摺痕(視窗座標,邏輯像素)。
  static final ValueNotifier<List<DisplayFeature>> features = ValueNotifier(
    const [],
  );

  static bool _started = false;

  /// 開始接收 native 回報;native 只在 iOS 27.1+(且以 27.1 SDK 編譯)有資料。
  static void start() {
    if (_started || !Platform.isIOS) return;
    _started = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'update') _apply(call.arguments);
    });
    // native 可能在 handler 掛上前就量好了 → 主動要一次現況
    unawaited(
      _channel
          .invokeMethod<Object?>('get')
          .then(_apply)
          .catchError((Object _) {}),
    );
  }

  static void _apply(Object? args) {
    final next = decode(args);
    if (!listEquals(next, features.value)) features.value = next;
  }

  /// native payload:`[{x, y, w, h, type: 'fold' | 'cutout'}]`。
  @visibleForTesting
  static List<DisplayFeature> decode(Object? args) {
    if (args is! List) return const [];
    final out = <DisplayFeature>[];
    for (final item in args) {
      if (item is! Map) continue;
      final x = item['x'], y = item['y'], w = item['w'], h = item['h'];
      if (x is! num || y is! num || w is! num || h is! num) continue;
      final bounds = Rect.fromLTWH(
        x.toDouble(),
        y.toDouble(),
        w.toDouble(),
        h.toDouble(),
      );
      switch (item['type']) {
        case 'fold':
          // native 只回報 active 的 division region = 半開
          out.add(
            DisplayFeature(
              bounds: bounds,
              type: DisplayFeatureType.fold,
              state: DisplayFeatureState.postureHalfOpened,
            ),
          );
        case 'cutout':
          out.add(
            DisplayFeature(
              bounds: bounds,
              type: DisplayFeatureType.cutout,
              state: DisplayFeatureState.unknown,
            ),
          );
      }
    }
    return out;
  }
}

/// 把 [FoldBridge] 的摺痕疊進 MediaQuery(掛在 MaterialApp.builder)。
///
/// 掛在 Navigator 之上,所以 showDialog / bottom sheet 內建的
/// DisplayFeatureSubScreen 也會自動避開摺痕。
class FoldFeatures extends StatelessWidget {
  const FoldFeatures({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<DisplayFeature>>(
      valueListenable: FoldBridge.features,
      child: child,
      builder: (context, features, child) {
        final data = MediaQuery.of(context);
        // 平台(Android,或未來的 Flutter iOS)已經提供 → 不重複疊加
        if (features.isEmpty || data.displayFeatures.isNotEmpty) return child!;
        return MediaQuery(
          data: data.copyWith(displayFeatures: features),
          child: child!,
        );
      },
    );
  }
}

/// 一道把版面切成兩半的摺痕,座標相對於查詢時給的區域。
@immutable
class FoldSplit {
  const FoldSplit(this.axis, this.start, this.end);

  /// [Axis.vertical] = 直立摺痕,左右兩半(書本式);
  /// [Axis.horizontal] = 橫向摺痕,上下兩半(桌上型 / 筆電式)。
  final Axis axis;

  /// 摺痕在區域內沿切分方向的範圍:直立摺痕是 x、橫向摺痕是 y。
  final double start;
  final double end;

  /// 在 [area](視窗座標)內找出半開的摺痕;只看 [only] 方向時其餘忽略。
  ///
  /// 算數的:半開的 fold、任何 hinge(實體間隙,攤平也不能畫)。
  /// 摺痕要真的把區域切成兩塊才算——貼在邊上或落在區域外的不算。
  static FoldSplit? find(
    List<DisplayFeature> features,
    Rect area, {
    Axis? only,
  }) {
    for (final f in features) {
      final halfOpen =
          f.type == DisplayFeatureType.hinge ||
          (f.type == DisplayFeatureType.fold &&
              f.state == DisplayFeatureState.postureHalfOpened);
      if (!halfOpen) continue;
      final b = f.bounds;
      final axis = b.height >= b.width ? Axis.vertical : Axis.horizontal;
      if (only != null && axis != only) continue;
      final (lo, hi, areaLo, areaHi, crossOk) = axis == Axis.vertical
          ? (
              b.left,
              b.right,
              area.left,
              area.right,
              b.top < area.bottom && b.bottom > area.top,
            )
          : (
              b.top,
              b.bottom,
              area.top,
              area.bottom,
              b.left < area.right && b.right > area.left,
            );
      if (!crossOk || lo <= areaLo || hi >= areaHi) continue;
      return FoldSplit(axis, lo - areaLo, hi - areaLo);
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is FoldSplit &&
      other.axis == axis &&
      other.start == start &&
      other.end == end;

  @override
  int get hashCode => Object.hash(axis, start, end);

  @override
  String toString() => 'FoldSplit($axis, $start..$end)';
}
