import 'package:flutter/material.dart';

import '../widgets/hotapp_workspace.dart';
import '../widgets/three_workspace.dart';
import '../widgets/video_workspace.dart';

/// 插件工作台注册表——3D / 视频 / 未来插件各自的独立工作台界面，
/// 与「设计」板块（design/docs/source/play）完全解耦（用户裁决：
/// 插件不能挤设计板块的 UI）。
///
/// 扩展方式：新增一个 [PluginDef] 进 [pluginRegistry] 即自动获得
/// 顶栏入口、⌘N 快捷键与 `plugin:<id>` 视图路由——零散落接线。
typedef PluginWorkspaceBuilder = Widget Function();

class PluginDef {
  const PluginDef({
    required this.id,
    required this.title,
    required this.tooltip,
    required this.icon,
    required this.builder,
  });

  /// 稳定 id：视图名 = `plugin:<id>`。
  final String id;
  final String title;
  final String tooltip;
  final IconData icon;
  final PluginWorkspaceBuilder builder;
}

/// 顶栏顺序即注册顺序；快捷键 ⌘5 起按序派生。
final List<PluginDef> pluginRegistry = [
  PluginDef(
    id: 'three',
    title: '3D 工作台',
    tooltip: '3D 工作台 ⌘5',
    icon: Icons.view_in_ar_outlined,
    builder: () => const ThreeWorkspace(),
  ),
  PluginDef(
    id: 'video',
    title: '视频工作台',
    tooltip: '视频工作台 ⌘6',
    icon: Icons.movie_outlined,
    builder: () => const VideoWorkspace(),
  ),
  PluginDef(
    id: 'hotapp',
    title: 'NaN 热应用',
    tooltip: 'NaN 热应用 ⌘7',
    icon: Icons.auto_fix_high_outlined,
    builder: () => const HotAppWorkspace(),
  ),
];

PluginDef? pluginById(String id) {
  for (final def in pluginRegistry) {
    if (def.id == id) return def;
  }
  return null;
}

/// workspace.dart 对 `plugin:<id>` 的路由入口；未知 id → null（调用方空态）。
Widget? pluginWorkspaceFor(String view) {
  if (!view.startsWith('plugin:')) return null;
  final def = pluginById(view.substring('plugin:'.length));
  return def?.builder();
}
