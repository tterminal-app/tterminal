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
//
// 同一條管道也帶 cutout(iOS 的 occlusion region);貼著左/右邊的(Duo 外螢幕
// 的系統膠囊)由 FoldFeatures 在根部整條讓掉,見下方說明。

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:flutter/foundation.dart' show listEquals, visibleForTesting;
import 'package:flutter/material.dart' show Theme;
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

/// 把 [FoldBridge] 的摺痕疊進 MediaQuery,並讓開貼邊的系統保留區
/// (掛在 MaterialApp.builder)。
///
/// 掛在 Navigator 之上,所以 showDialog / bottom sheet 內建的
/// DisplayFeatureSubScreen 也會自動避開摺痕。
///
/// 貼邊保留區:iPhone Duo 外螢幕右上角是系統的時間/Wi‑Fi 膠囊(occlusion
/// 382,0 84×170,貼頂也貼右),iOS 把它算成 safeAreaInsets.right 84。AppBar 與
/// 包了 SafeArea 的頁面會讓,但多數頁面的 body 不理左右 inset(Vaults 的新增鈕
/// 就被蓋掉),所以 cutout 貼著左/右邊時在這裡把那一側整條讓掉,各頁不用管。
/// 一般 iPhone 的動態島/瀏海離邊緣還有一段,不會觸發。
///
/// 讓掉之後內層看到的是較窄的視窗:size 與那側 padding 扣掉、displayFeatures
/// 平移到內層座標——摺痕分欄、DisplayFeatureSubScreen 都拿 size 和
/// displayFeatures 在同一個座標系比。
class FoldFeatures extends StatelessWidget {
  const FoldFeatures({super.key, required this.child});

  final Widget child;

  /// cutout 離邊緣多近算貼邊(native 座標常是 1/3 pt 的小數)。
  static const _edgeSlop = 1.0;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<DisplayFeature>>(
      valueListenable: FoldBridge.features,
      child: child,
      builder: (context, features, child) {
        var data = MediaQuery.of(context);
        // 平台(Android,或未來的 Flutter iOS)已經提供 → 不重複疊加
        if (features.isNotEmpty && data.displayFeatures.isEmpty) {
          data = data.copyWith(displayFeatures: features);
        }
        final side = _sideReserve(data);
        // 不論讓不讓都包同樣幾層,切換時 Navigator 以上的 element 不會換掉
        return ColoredBox(
          color: Theme.of(context).scaffoldBackgroundColor,
          child: Padding(
            padding: side,
            child: MediaQuery(data: _inset(data, side), child: child!),
          ),
        );
      },
    );
  }

  /// 貼著左/右邊的 cutout → 那一側要讓掉的寬度(cutout 與系統 padding 取大)。
  static EdgeInsets _sideReserve(MediaQueryData data) {
    final width = data.size.width;
    var left = 0.0, right = 0.0;
    for (final f in data.displayFeatures) {
      if (f.type != DisplayFeatureType.cutout) continue;
      final b = f.bounds;
      // 橫跨大半寬的是頂/底的帶狀區,交給上下 padding
      if (b.width * 2 >= width) continue;
      if (b.left <= _edgeSlop) {
        left = math.max(left, b.right);
      } else if (b.right >= width - _edgeSlop) {
        right = math.max(right, width - b.left);
      }
    }
    return EdgeInsets.only(
      left: left > 0 ? math.max(left, data.padding.left) : 0,
      right: right > 0 ? math.max(right, data.padding.right) : 0,
    );
  }

  /// 讓掉 [side] 之後,內層那個較窄視窗的 MediaQuery。
  static MediaQueryData _inset(MediaQueryData data, EdgeInsets side) {
    if (side == EdgeInsets.zero) return data;
    final shift = Offset(-side.left, 0);
    final inner =
        Offset.zero &
        Size(math.max(0, data.size.width - side.horizontal), data.size.height);
    EdgeInsets less(EdgeInsets e) => e.copyWith(
      left: math.max(0, e.left - side.left),
      right: math.max(0, e.right - side.right),
    );
    return data.copyWith(
      size: inner.size,
      padding: less(data.padding),
      viewPadding: less(data.viewPadding),
      viewInsets: less(data.viewInsets),
      systemGestureInsets: less(data.systemGestureInsets),
      displayFeatures: [
        for (final f in data.displayFeatures)
          // 落在讓掉那條裡的(膠囊本身)內層用不到
          if (f.bounds.shift(shift).overlaps(inner))
            DisplayFeature(
              bounds: f.bounds.shift(shift),
              type: f.type,
              state: f.state,
            ),
      ],
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
