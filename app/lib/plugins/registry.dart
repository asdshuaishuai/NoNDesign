import 'package:material_ui/material_ui.dart';

import '../widgets/hotapp_workspace.dart';
import '../widgets/music_workspace.dart';
import '../widgets/three_workspace.dart';
import '../widgets/video_workspace.dart';

/// 插件工作台注册表——3D / 视频 / 未来插件各自的独立工作台界面，
/// 与「设计」板块（design/docs/source/play）完全解耦（用户裁决：
/// 插件不能挤设计板块的 UI）。
///
/// 扩展方式：新增一个 [PluginDef] 进 [pluginRegistry] 即自动获得
/// `plugin:<id>` 视图路由；入口**不**自动出现——设计工具条只挂热应用
/// （workspace.dart 按 id 过滤），其余工作台的入口（顶栏项目菜单 / 主页
/// 作品集）需要逐处接线。
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

/// 顶栏顺序即注册顺序（没有「工作台快捷键」：工作台跟着项目走）。
final List<PluginDef> pluginRegistry = [
  PluginDef(
    id: 'three',
    title: '3D 工作台',
    tooltip: '3D 工作台',
    icon: Icons.view_in_ar_outlined,
    builder: () => const ThreeWorkspace(),
  ),
  PluginDef(
    id: 'video',
    title: '视频工作台',
    tooltip: '视频工作台',
    icon: Icons.movie_outlined,
    builder: () => const VideoWorkspace(),
  ),
  PluginDef(
    id: 'music',
    title: '音乐工作台',
    tooltip: '音乐工作台',
    icon: Icons.library_music_outlined,
    builder: () => const MusicWorkspace(),
  ),
  PluginDef(
    id: 'hotapp',
    title: 'NaN 热应用',
    tooltip: 'NaN 热应用',
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
