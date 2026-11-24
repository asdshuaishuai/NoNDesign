/// 设计画布的选区浮动工具条（画布优先姿态的专属交互）。
///
/// 2026-11-24 工作台独立适配（UI-1 收尾）：选中单个节点时在节点上方浮出常用动作
/// （复制/删除），不再要求用户去侧栏找按钮；不改变事实源，所有动作仍走 store op。
library;

import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';

class DesignSelectionToolbar extends StatelessWidget {
  const DesignSelectionToolbar({
    super.key,
    required this.onDuplicate,
    required this.onDelete,
    this.onDismiss,
  });

  final VoidCallback onDuplicate;
  final VoidCallback onDelete;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Material(
      key: const ValueKey('design-selection-toolbar'),
      color: p.panel,
      elevation: 6,
      shadowColor: Colors.black.withValues(alpha: 0.35),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: p.lineStrong),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _action(
              context,
              key: const ValueKey('design-selection-duplicate'),
              icon: Icons.copy_all_outlined,
              tooltip: '复制节点',
              onTap: onDuplicate,
            ),
            _action(
              context,
              key: const ValueKey('design-selection-delete'),
              icon: Icons.delete_outline,
              tooltip: '删除节点',
              color: p.warn,
              onTap: onDelete,
            ),
            if (onDismiss != null) ...<Widget>[
              Container(width: 1, height: 18, color: p.line),
              _action(
                context,
                key: const ValueKey('design-selection-dismiss'),
                icon: Icons.close,
                tooltip: '取消选中',
                onTap: onDismiss!,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _action(
    BuildContext context, {
    required Key key,
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    Color? color,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        key: key,
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon, size: 15, color: color ?? context.palette.ink2),
        ),
      ),
    );
  }
}
