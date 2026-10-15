// 效能量測畫面:以合成 VT 資料流灌爆終端引擎,量 feed / copy / paint / fps。
//
// 每 frame 餵 256 KiB(比真實 `cat 大檔` 更兇),每 10 秒輪換 scenario。
// 也是 headless 渲染驗證(test/render_probe_test.dart)的目標畫面。

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'term_ffi.dart';
import 'term_painter.dart';
import 'terminal_view.dart';

const kDemoCols = 120;
const kDemoRows = 40;
const kDemoBytesPerFrame = 256 * 1024;

class DemoPage extends StatefulWidget {
  const DemoPage({super.key, this.style});

  final TerminalStyle? style;

  @override
  State<DemoPage> createState() => _DemoPageState();
}

class _DemoPageState extends State<DemoPage>
    with SingleTickerProviderStateMixin {
  late final NativeSession _session = NativeSession.headless(
    cols: kDemoCols,
    rows: kDemoRows,
  );
  Timer? _scenarioTimer;
  late final Ticker _ticker;

  int _scenario = DemoScenario.colored;
  int _frames = 0;
  double _feedUs = 0;
  double _paintMs = 0;
  var _lastReport = DateTime.now();
  String _hud = 'warming up…';

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
    _scenarioTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _scenario = (_scenario + 1) % DemoScenario.count;
    });
  }

  void _onTick(Duration _) {
    final sw = Stopwatch()..start();
    _session.demoFeed(_scenario, kDemoBytesPerFrame);
    _feedUs += sw.elapsedMicroseconds;
    _frames++;

    final elapsed = DateTime.now().difference(_lastReport);
    if (elapsed.inMilliseconds >= 2000) {
      final fps = _frames * 1000 / elapsed.inMilliseconds;
      final throughput =
          (kDemoBytesPerFrame * _frames / (1024 * 1024)) /
          (elapsed.inMilliseconds / 1000);
      _hud =
          '${DemoScenario.name(_scenario)}  '
          'fps=${fps.toStringAsFixed(0)}  '
          'feed=${(_feedUs / _frames).toStringAsFixed(0)}µs  '
          'paint=${_paintMs.toStringAsFixed(1)}ms  '
          '${throughput.toStringAsFixed(0)}MiB/s  '
          'grid=${kDemoCols}x$kDemoRows';
      stdout.writeln('TTERM-STATS $_hud');
      setState(() {});
      _frames = 0;
      _feedUs = 0;
      _lastReport = DateTime.now();
    }
  }

  @override
  void dispose() {
    _scenarioTimer?.cancel();
    _ticker.dispose();
    _session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF181818),
      body: Stack(
        children: [
          Positioned.fill(
            child: TerminalView(
              session: _session,
              style: widget.style,
              autofocus: false,
              onPaintTime: (ms) => _paintMs = ms,
            ),
          ),
          Positioned(
            top: 8,
            left: 12,
            child: Text(
              _hud,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                color: Color(0xFF7CFC00),
                backgroundColor: Color(0xCC101010),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
