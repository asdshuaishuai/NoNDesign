/// 3D 视口控制浮层（批次 15 第一批）：视角预设 / 网格开关 / 重置视角。
///
/// **纯 UI 组件**：不引用 WebView、不依赖 ThreeService，也不写事实源。真正的
/// 相机/网格命令由宿主（`three_workspace.dart`）经预览页的
/// `__non3d_view(preset)` / `__non3d_grid(visible)` 桥送出；组件只做三件事：
/// 把可用状态画出来、把点击翻成语义回调、禁用时给出可读原因（tooltip）。
///
/// 为什么是浮层而不是工具栏按钮：宽屏 3D 内容区是「大纲 | 视口 | 检查器」
/// 三栏，视口姿态属于视口本身；浮在预览面右上角离操作对象最近，也不占三栏
/// 几何（内容区布局规格不被这批交互改动）。
library;

import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';

/// 视口视角预设；[id] 与预览页 `window.__non3d_view(preset)` 的入参一一对应。
enum ThreeViewPreset {
  front('front', '前视'),
  top('top', '顶视'),
  iso('iso', '等轴');

  const ThreeViewPreset(this.id, this.label);

  /// 送进预览页的预设 id（不要翻译/改名，预览页按字面量匹配）。
  final String id;

  /// 用户可见标签。
  final String label;
}

/// 视口控制浮层：视角预设 + 网格显示开关 + 重置视角。
///
/// 组件不持有任何服务端状态：[gridVisible] 由宿主持有（网格开关是预览页
/// 状态，页面重挂后原生就复位），这里只按入参画激活态并回传点击。
class ThreeViewportControls extends StatelessWidget {
  const ThreeViewportControls({
    super.key,
    required this.enabled,
    required this.gridVisible,
    required this.onViewPreset,
    required this.onGridChanged,
    required this.onReset,
    this.disabledHint = '预览还没就绪，视角控制暂不可用',
  });

  /// 预览页是否真的能执行命令（未就绪 / 无控制器 / 设备不支持时为 false）。
  final bool enabled;

  /// 网格当前是否显示（宿主持有；组件不自行翻转）。
  final bool gridVisible;

  final ValueChanged<ThreeViewPreset> onViewPreset;
  final ValueChanged<bool> onGridChanged;
  final VoidCallback onReset;

  /// 禁用时每个入口的 tooltip 文案：说清为什么点不动，而不是一句通用话。
  final String disabledHint;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final color = enabled ? p.ink2 : p.ink4;
    return Material(
      key: const ValueKey('three-viewport-controls'),
      color: p.panel.withValues(alpha: 0.9),
      elevation: 3,
      shadowColor: Colors.black.withValues(alpha: 0.3),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: p.lineStrong),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const SizedBox(width: 5),
            Icon(Icons.open_with, size: 13, color: color),
            const SizedBox(width: 5),
            Text('视角', style: TextStyle(fontSize: 11, color: color)),
            const SizedBox(width: 2),
            for (final preset in ThreeViewPreset.values)
              _ViewportAction(
                buttonKey: ValueKey('three-view-${preset.id}'),
                label: preset.label,
                enabled: enabled,
                active: false,
                tooltip: enabled ? '切换到${preset.label}' : disabledHint,
                onTap: () => onViewPreset(preset),
              ),
            _divider(p),
            _ViewportAction(
              buttonKey: const ValueKey('three-view-grid'),
              icon: gridVisible ? Icons.grid_on : Icons.grid_4x4_outlined,
              label: '网格',
              enabled: enabled,
              active: gridVisible,
              tooltip: enabled ? (gridVisible ? '隐藏网格' : '显示网格') : disabledHint,
              onTap: () => onGridChanged(!gridVisible),
            ),
            _ViewportAction(
              buttonKey: const ValueKey('three-view-reset'),
              icon: Icons.refresh,
              label: '重置',
              enabled: enabled,
              active: false,
              tooltip: enabled ? '重置到初始视角' : disabledHint,
              onTap: onReset,
            ),
            const SizedBox(width: 3),
          ],
        ),
      ),
    );
  }

  Widget _divider(NonPalette p) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 3),
    child: Container(width: 1, height: 14, color: p.lineStrong),
  );
}

/// 浮层里的单个入口：紧凑按钮 + tooltip；[icon] 为空时只显示文字标签
/// （视角预设用文字比抽象图标更容易读）。
class _ViewportAction extends StatelessWidget {
  const _ViewportAction({
    required this.buttonKey,
    required this.label,
    required this.enabled,
    required this.active,
    required this.tooltip,
    required this.onTap,
    this.icon,
  });

  final Key buttonKey;
  final IconData? icon;
  final String label;
  final bool enabled;
  final bool active;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final color = !enabled ? p.ink4 : (active ? p.accent : p.ink2);
    return Tooltip(
      message: tooltip,
      child: TextButton(
        key: buttonKey,
        onPressed: enabled ? onTap : null,
        style: TextButton.styleFrom(
          visualDensity: VisualDensity.compact,
          minimumSize: const Size(0, 26),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          foregroundColor: color,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (icon != null) ...[
              Icon(icon, size: 13, color: color),
              const SizedBox(width: 4),
            ],
            Text(label, style: TextStyle(fontSize: 11, color: color)),
          ],
        ),
      ),
    );
  }
}
