// 手機版功能鍵工具列(Termius 慣例):軟鍵盤沒有的 Esc/Ctrl/Tab/方向鍵等。
//
// Ctrl 是「黏著鍵」:點一下亮起,下一個輸入(軟鍵盤字元或工具列按鍵)
// 變成 Ctrl 組合後自動解除——手機沒有實體修飾鍵,只能這樣做組合鍵。
// 最常用的幾個組合(^C、^D…)另外做成一鍵直送,不用先點 Ctrl 再切軟鍵盤。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 工具列按鍵定義:控制鍵(走 KeyEncoder)或字面文字(走 IME commit 路徑)。
sealed class ToolbarKey {
  const ToolbarKey(this.label);
  final String label;
}

class ToolbarLogicalKey extends ToolbarKey {
  const ToolbarLogicalKey(super.label, this.key);
  final LogicalKeyboardKey key;
}

class ToolbarTextKey extends ToolbarKey {
  const ToolbarTextKey(super.label, this.text);
  final String text;
}

/// 一鍵 Ctrl 組合:[char] 是和 Ctrl 一起按的字元(走 KeyEncoder.ctrlBytes)。
class ToolbarCtrlKey extends ToolbarKey {
  const ToolbarCtrlKey(this.char) : super('^$char');
  final String char;
}

class KeyToolbar extends StatelessWidget {
  const KeyToolbar({
    super.key,
    required this.ctrlActive,
    required this.onCtrlToggle,
    required this.onKey,
    required this.onText,
    required this.onCtrl,
  });

  final bool ctrlActive;
  final VoidCallback onCtrlToggle;
  final void Function(LogicalKeyboardKey key) onKey;
  final void Function(String text) onText;
  final void Function(String char) onCtrl;

  static const height = 40.0;

  static const keys = <ToolbarKey>[
    ToolbarLogicalKey('esc', LogicalKeyboardKey.escape),
    // Ctrl 插在第二個位置(build 特殊處理)
    ToolbarLogicalKey('tab', LogicalKeyboardKey.tab),
    ToolbarCtrlKey('C'), // 中斷
    ToolbarCtrlKey('D'), // EOF / 登出
    ToolbarLogicalKey('←', LogicalKeyboardKey.arrowLeft),
    ToolbarLogicalKey('↓', LogicalKeyboardKey.arrowDown),
    ToolbarLogicalKey('↑', LogicalKeyboardKey.arrowUp),
    ToolbarLogicalKey('→', LogicalKeyboardKey.arrowRight),
    ToolbarCtrlKey('Z'), // 暫停到背景
    ToolbarCtrlKey('L'), // 清畫面
    ToolbarCtrlKey('R'), // 搜尋歷史指令
    ToolbarCtrlKey('A'), // 行首(screen 前綴)
    ToolbarCtrlKey('E'), // 行尾
    ToolbarCtrlKey('U'), // 刪到行首
    ToolbarCtrlKey('W'), // 刪前一個字
    ToolbarCtrlKey('B'), // tmux 前綴
    ToolbarTextKey('-', '-'),
    ToolbarTextKey('|', '|'),
    ToolbarTextKey('/', '/'),
    ToolbarTextKey('~', '~'),
    ToolbarLogicalKey('home', LogicalKeyboardKey.home),
    ToolbarLogicalKey('end', LogicalKeyboardKey.end),
    ToolbarLogicalKey('pgup', LogicalKeyboardKey.pageUp),
    ToolbarLogicalKey('pgdn', LogicalKeyboardKey.pageDown),
  ];

  Widget _button(
    String label, {
    required VoidCallback onTap,
    bool active = false,
    Key? key,
  }) {
    return Padding(
      key: key,
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: active ? const Color(0xFF4A6FD4) : const Color(0xFF2A2A2A),
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minWidth: 44),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(
              label,
              style: TextStyle(
                color: active ? Colors.white : const Color(0xFFCCCCCC),
                fontSize: 14,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[
      _button(
        keys[0].label,
        key: const Key('tk-esc'),
        onTap: () => onKey((keys[0] as ToolbarLogicalKey).key),
      ),
      _button(
        'ctrl',
        key: const Key('tk-ctrl'),
        active: ctrlActive,
        onTap: onCtrlToggle,
      ),
      for (final k in keys.skip(1))
        switch (k) {
          ToolbarLogicalKey() => _button(
              k.label,
              key: Key('tk-${k.label}'),
              onTap: () => onKey(k.key),
            ),
          ToolbarTextKey() => _button(
              k.label,
              key: Key('tk-${k.label}'),
              onTap: () => onText(k.text),
            ),
          ToolbarCtrlKey() => _button(
              k.label,
              key: Key('tk-${k.label}'),
              onTap: () => onCtrl(k.char),
            ),
        },
    ];
    return Container(
      height: height,
      color: const Color(0xFF1F1F1F),
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: children,
      ),
    );
  }
}
