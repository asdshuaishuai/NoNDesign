/// 响应式壳路由 + 壳层几何持久化。
///
/// **四个面各不相同，绝不统一**（裁决见 `core/layout.dart`）：
///
/// | 宿主形态                     | 壳                                        |
/// |------------------------------|-------------------------------------------|
/// | 手机竖屏 / 手机横屏          | [ChatPiPShell]：聊天全屏 + 工作区画中画     |
/// | iPad 竖屏（含 768×1024）     | [ChatPiPShell]（明确裁决 C）               |
/// | iPad 横屏                    | [DesktopShell]：工作区/Welcome + 聊天窄栏  |
/// | macOS / Windows / Linux      | [DesktopShell]                            |
///
/// `play` / `portfolio` 是整壳全幅视图，由 `main.dart` 先于本宿主路由；
/// `plugin:*`（3D / 视频 / 热应用）**留在壳里**：桌面壳右侧常驻 NaN 窄栏，
/// 左侧是固定工作区（用户裁决 2026-11-18）。这里保留兜底，方便单测直接
/// 泵 [ShellHost]。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/layout.dart';
import '../core/platform_capabilities.dart';
import '../core/store.dart';
import 'chat_pip_shell.dart';
import 'desktop_shell.dart';
import 'workspace.dart';

/// 聊天窄栏宽度下限（与 [LayoutSpec.chatRailMinWidth] 同源）。
const double kChatRailMinWidth = LayoutSpec.chatRailMinWidth;

/// 聊天窄栏宽度上限（与 [LayoutSpec.chatRailMaxWidth] 同源）。
const double kChatRailMaxWidth = LayoutSpec.chatRailMaxWidth;

/// 窄栏默认宽度（批次 12 验收：默认 360，而非视口比例）。
const double kChatRailDefaultWidth = 360;

/// 折叠后的条带宽度（44px 第二列，不叠在主面上——壳层 chrome 永不被盖）。
const double kChatRailCollapsedWidth = 44;

/// 桌面壳主面最小可用宽度：窄栏展开时主面不得窄于它（1024 窗 → 栏 324）。
const double kDesktopMainMinWidth = 700;

/// 视口窄于此值时窄栏强制折叠（44px 条带，不可展开）。
///
/// 由几何推导而非手写数字：主面最小宽 + 窄栏最小宽 = 700 + 320 = 1020。
/// 视口 ≥1020 时展开栏仍能给主面 700，所以 1023 宽的窗口必须可展开；
/// 低于它时折叠条上的 tab/展开命令改为给出人话提示（不静默无效）。
const double kDesktopRailForceCollapseWidth = kDesktopMainMinWidth + kChatRailMinWidth;

/// 视口窄于此值时窄栏默认折叠（1080×700 窄 PC → 44px 条带），
/// 用户点条带仍可展开（≥1020 放得下）。
const double kDesktopRailAutoExpandWidth = 1100;

/// 壳层持久化快照（重启恢复：窄栏折叠态/宽度/tab、画中画浮窗 rect）。
@immutable
class ShellSnapshot {
  final bool? railExpanded;
  final double? railWidth;
  final String? railTab;
  final Rect? pipRect;

  const ShellSnapshot({
    this.railExpanded,
    this.railWidth,
    this.railTab,
    this.pipRect,
  });
}

/// SharedPreferences 读写（测试可经 `setMockInitialValues` 预置）。
///
/// 写失败静默（缺插件/沙盒只读）：壳层几何是体验偏好，不是事实数据，绝不
/// 因为存不下而阻塞界面。
class ShellStorage {
  static const railExpandedKey = 'nondesign.shell.railExpanded';
  static const railWidthKey = 'nondesign.shell.railWidth';
  static const railTabKey = 'nondesign.shell.railTab';
  static const pipRectKey = 'nondesign.shell.pipRect';

  static Future<SharedPreferences?> _prefs() async {
    try {
      return await SharedPreferences.getInstance();
    } catch (_) {
      return null;
    }
  }

  static Future<ShellSnapshot> load() async {
    final prefs = await _prefs();
    if (prefs == null) return const ShellSnapshot();
    return ShellSnapshot(
      railExpanded: prefs.getBool(railExpandedKey),
      railWidth: prefs.getDouble(railWidthKey),
      railTab: prefs.getString(railTabKey),
      pipRect: _decodeRect(prefs.getString(pipRectKey)),
    );
  }

  static Future<void> saveRail({bool? expanded, double? width, String? tab}) async {
    final prefs = await _prefs();
    if (prefs == null) return;
    try {
      if (expanded != null) await prefs.setBool(railExpandedKey, expanded);
      if (width != null) await prefs.setDouble(railWidthKey, width);
      if (tab != null) await prefs.setString(railTabKey, tab);
    } catch (_) {}
  }

  static Future<void> savePipRect(Rect? rect) async {
    final prefs = await _prefs();
    if (prefs == null) return;
    try {
      if (rect == null) {
        await prefs.remove(pipRectKey);
        return;
      }
      await prefs.setString(
        pipRectKey,
        '${rect.left},${rect.top},${rect.width},${rect.height}',
      );
    } catch (_) {}
  }

  static Rect? _decodeRect(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final parts = raw.split(',');
    if (parts.length != 4) return null;
    final values = <double>[];
    for (final part in parts) {
      final v = double.tryParse(part);
      if (v == null || !v.isFinite) return null;
      values.add(v);
    }
    if (values[2] <= 0 || values[3] <= 0) return null;
    return Rect.fromLTWH(values[0], values[1], values[2], values[3]);
  }
}

/// 响应式壳入口：按宿主与视口选 [ChatPiPShell] 或 [DesktopShell]。
class ShellHost extends StatelessWidget {
  /// 测试可注入宿主画像（默认读当前平台）。
  final PlatformCapabilities? capabilities;

  const ShellHost({super.key, this.capabilities});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    // 整壳全幅视图：先于壳路由（与 main.dart 同序；这里是单测/防御兜底）。
    // plugin:* 不在这里早退——它们要带着右侧 NaN 窄栏进壳。
    if (store.view == 'play' || store.view == 'portfolio') {
      return const Workspace();
    }
    final caps = capabilities ?? PlatformCapabilities.current();
    return LayoutBuilder(
      builder: (context, constraints) {
        final layout = LayoutSpec.classifyHost(
          caps,
          width: constraints.maxWidth,
          height: constraints.maxHeight,
        );
        // 换壳时 KeyedSubtree 变更即重建 State：两个壳不共享布局状态。
        if (layout.usesChatFirstShell) {
          return ChatPiPShell(
            key: const ValueKey('shell-chat-pip'),
            layout: layout,
          );
        }
        return DesktopShell(
          key: const ValueKey('shell-desktop'),
          layout: layout,
        );
      },
    );
  }
}
