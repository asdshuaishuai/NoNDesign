import 'dart:io' show Platform;

import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter/widgets.dart' show SingleActivator;

/// 快捷键修饰键随平台：macOS 用 ⌘（meta），Windows / Linux 用 Ctrl。
/// 所有绑定与展示标签都从这里取，不要散落硬编码 ⌘。
bool get modIsMeta => Platform.isMacOS;

/// 平台自适应绑定：macOS=meta，Windows/Linux=control。
SingleActivator modKey(LogicalKeyboardKey key, {bool shift = false}) => SingleActivator(
      key,
      meta: modIsMeta,
      control: !modIsMeta,
      shift: shift,
    );

/// 展示用标签：macOS 显示 ⌘/⇧⌘ 原样，其余把 ⌘ 换成 Ctrl+、⇧⌘ 换成 Ctrl+Shift+。
String modCombo(String macKeys) {
  if (modIsMeta) return macKeys;
  return macKeys.replaceAll('⇧⌘', 'Ctrl+Shift+').replaceAll('⌘', 'Ctrl+');
}
