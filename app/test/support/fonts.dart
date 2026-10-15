// 測試字型載入:flutter_test 預設字型是 Ahem(全部是方塊),
// 要驗證真實字形(尤其中文)必須把系統字型載進來,並固定 family 名稱,
// 讓測試不受各機器字型設定影響。

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:tterm_app/src/term_painter.dart';

const kTestMonoFamily = 'TestMono';
const kTestCjkFamily = 'TestCJK';

const _monoCandidates = [
  '/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf',
  '/usr/share/fonts/TTF/DejaVuSansMono.ttf',
  '/System/Library/Fonts/Menlo.ttc',
];

const _cjkCandidates = [
  '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
  '/usr/share/fonts/opentype/noto/NotoSansMonoCJKtc-Regular.otf',
  '/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc',
];

Future<void> _load(String family, List<String> candidates) async {
  for (final path in candidates) {
    final file = File(path);
    if (!file.existsSync()) continue;
    final bytes = await file.readAsBytes();
    await (FontLoader(family)
          ..addFont(Future.value(ByteData.view(bytes.buffer))))
        .load();
    return;
  }
}

/// 載入測試用字型。必須在 `tester.runAsync` 或 setUpAll 中呼叫(真實 I/O)。
Future<void> loadTestFonts() async {
  await _load(kTestMonoFamily, _monoCandidates);
  await _load(kTestCjkFamily, _cjkCandidates);
}

/// 固定字型的 TerminalStyle,讓渲染結果跨機器一致。
TerminalStyle testTerminalStyle({double fontSize = 14}) => TerminalStyle(
  fontFamily: kTestMonoFamily,
  fontFamilyFallback: const [kTestCjkFamily],
  fontSize: fontSize,
);
