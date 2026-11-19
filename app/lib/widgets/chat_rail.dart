/// 桌面 / iPad 横屏壳的**唯一右侧窄栏**。
///
/// 验收约束：
/// * 宽度 clamp(320,420)，默认 360（由壳传入，拖动左缘改宽并持久化）；
/// * 两个 tab：NaN / 检查——NaN 就是聊天与任务指令执行的窗口（AgentPanel），
///   不再保留独立的「聊天」tab（与 NaN 重复，用户实测 2026-11-18）；
/// * 窄栏里**没有工作区切换条**（用户裁决 2026-11-19）：一个项目只属于它自己
///   的工作台类型，工作台跟着项目走——切换入口在顶栏的项目下拉，不在聊天栏里
///   摆一排「主页/设计/3D/视频/热应用」；
/// * 折叠后是主面右侧的第二列 44px 条带（不叠在主面上，顶栏/状态栏右段不被
///   盖住），点任一 tab 图标即展开到该 tab；视口窄到放不下时由壳层给出提示；
/// * 选中画布节点会把 `store.rightTab` 切到 inspect，但**不抢** NaN：本窄栏
///   的 tab 是壳层局部状态，只有用户显式点击才切换。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/store.dart';
import '../core/theme.dart';
import 'common.dart';
// AgentPanel / Inspector 是 right_panel.dart 的 part——只能经库入口导入。
import 'right_panel.dart';
import 'workspace_inspector.dart';

/// 窄栏 tab 标识（`agent` / `inspect` 与 `store.rightTab` 同名，便于面板复用）。
const String kRailTabAgent = 'agent';
const String kRailTabInspect = 'inspect';

/// 窄栏 tab 条（随当前工作区变）：
/// * NaN 常驻；
/// * 「检查」的文案/图标跟着工作区走（设计=检查、3D=3D 检查、视频=视频检查、
///   热应用=应用检查、演示/作品集各用各的），但 tab id 恒为 `inspect`——
///   持久化值与 `store.rightTab` 语义不能变。
List<(String, IconData, String)> railTabsForView(String view) => [
      (kRailTabAgent, Icons.auto_awesome, 'NaN'),
      (kRailTabInspect, inspectTabIconForView(view), inspectTabLabelForView(view)),
    ];

/// 展开态窄栏：tab 条 + 内容（NaN 面板 / 检查器）。
class ChatRail extends StatelessWidget {
  final double width;
  final String tab;
  final ValueChanged<String> onTab;
  final VoidCallback onCollapse;

  /// 拖动左缘改宽（参数是水平增量 dx）。
  final ValueChanged<double>? onResize;

  /// 拖动结束（壳层据此持久化宽度，避免逐帧写盘）。
  final VoidCallback? onResizeEnd;

  const ChatRail({
    super.key,
    required this.width,
    required this.tab,
    required this.onTab,
    required this.onCollapse,
    this.onResize,
    this.onResizeEnd,
  });

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return SizedBox(
      width: width,
      child: Stack(
        children: [
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                color: p.bgElevated,
                border: Border(left: BorderSide(color: p.line)),
              ),
              child: Column(
                children: [
                  _header(context, p),
                  Expanded(child: _body()),
                ],
              ),
            ),
          ),
          if (onResize != null)
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: 6,
              child: MouseRegion(
                cursor: SystemMouseCursors.resizeColumn,
                child: GestureDetector(
                  key: const ValueKey('desktop-chat-rail-split'),
                  behavior: HitTestBehavior.opaque,
                  onHorizontalDragUpdate: (d) => onResize!(d.delta.dx),
                  onHorizontalDragEnd: (_) => onResizeEnd?.call(),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context, NonPalette p) {
    final tabs = railTabsForView(context.watch<AppStore>().view);
    return Container(
      height: 44,
      padding: const EdgeInsets.only(left: 8, right: 2),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: p.line))),
      child: Row(
        children: [
          for (final entry in tabs)
            _tab(context, entry.$1, entry.$2, entry.$3),
          const Spacer(),
          IconAction(
            key: const ValueKey('desktop-chat-rail-collapse'),
            icon: Icons.keyboard_double_arrow_right,
            tooltip: '折叠聊天栏',
            onTap: onCollapse,
          ),
        ],
      ),
    );
  }

  Widget _tab(BuildContext context, String id, IconData icon, String label) {
    final p = context.palette;
    final active = tab == id;
    return InkWell(
      key: ValueKey('desktop-chat-rail-tab-$id'),
      borderRadius: BorderRadius.circular(8),
      onTap: () => onTab(id),
      child: Container(
        height: 28,
        margin: const EdgeInsets.only(right: 2),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: active ? p.panel2 : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(icon, size: 12, color: active ? p.accent : p.ink4),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: active ? p.ink : p.ink3,
              ),
            ),
          ],
        ),
      ),
    );
  }


  Widget _body() {
    switch (tab) {
      case kRailTabInspect:
        // 检查面板按工作区分派（3D / 视频 / 热应用不渲染设计画板检查器）。
        return const WorkspaceInspector();
      default:
        // NaN 是聊天与任务指令执行的窗口：旧存档的 chat 值也归一到这里。
        return const AgentPanel();
    }
  }
}

/// 折叠态：右缘 44px 条带，是主面右侧的**第二列**（不叠加、不盖住主面
/// 顶栏/状态栏右段）；点图标即展开到对应 tab。
class ChatRailStrip extends StatelessWidget {
  final String tab;
  final ValueChanged<String> onTab;

  const ChatRailStrip({super.key, required this.tab, required this.onTab});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final tabs = railTabsForView(context.watch<AppStore>().view);
    return Container(
      width: 44,
      decoration: BoxDecoration(
        color: p.bgElevated,
        border: Border(left: BorderSide(color: p.line)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 6),
          for (final entry in tabs)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: IconAction(
                key: ValueKey('desktop-rail-strip-${entry.$1}'),
                icon: entry.$2,
                tooltip: entry.$3,
                size: 30,
                hitSize: 38,
                active: tab == entry.$1,
                onTap: () => onTab(entry.$1),
              ),
            ),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: IconAction(
              key: const ValueKey('desktop-rail-strip-expand'),
              icon: Icons.keyboard_double_arrow_left,
              tooltip: '展开聊天栏',
              size: 30,
              hitSize: 38,
              onTap: () => onTab(tab),
            ),
          ),
        ],
      ),
    );
  }
}
