/// 四工作台统一的「执行过程面」：阶段条（当前步实时态、失败人话、可取消）。
///
/// 只渲染 [WorkspaceStage] 模型；模块自己的执行链负责推进状态。与右侧 chat
/// 时间线分工见 plan-creative-workbench §2.2。
library;

import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';
import '../core/workspace_stage.dart';

/// 横向阶段条。窄屏可换行；不改变任何执行状态。
class WorkspaceProgress extends StatelessWidget {
  const WorkspaceProgress({
    super.key,
    required this.stages,
    this.errorMessage,
    this.onCancel,
  });

  final List<WorkspaceStage> stages;

  /// 失败时的人话一句（原始诊断只进折叠详情，不在这里）。
  final String? errorMessage;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    if (stages.isEmpty) return const SizedBox.shrink();
    final p = context.palette;
    return Container(
      key: const ValueKey('workspace-progress'),
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: p.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Wrap(
            spacing: 10,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              for (int i = 0; i < stages.length; i++)
                _StageChip(stage: stages[i], index: i),
              if (onCancel != null)
                TextButton.icon(
                  key: const ValueKey('workspace-progress-cancel'),
                  onPressed: onCancel,
                  icon: const Icon(Icons.stop_circle_outlined, size: 16),
                  label: const Text('取消', style: TextStyle(fontSize: 12)),
                ),
            ],
          ),
          if (errorMessage != null && errorMessage!.trim().isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              errorMessage!,
              key: const ValueKey('workspace-progress-error'),
              style: TextStyle(fontSize: 12, height: 1.4, color: p.warn),
            ),
          ],
        ],
      ),
    );
  }
}

class _StageChip extends StatelessWidget {
  const _StageChip({required this.stage, required this.index});

  final WorkspaceStage stage;
  final int index;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final (IconData icon, Color color) = switch (stage.state) {
      WorkspaceStageState.pending => (Icons.radio_button_unchecked, p.ink4),
      WorkspaceStageState.running => (Icons.autorenew, p.accent),
      WorkspaceStageState.done => (Icons.check_circle, p.success),
      WorkspaceStageState.failed => (Icons.error_outline, p.warn),
    };
    return Row(
      key: ValueKey('workspace-stage-${stage.id}'),
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(icon, size: 15, color: color),
        const SizedBox(width: 5),
        Text(
          stage.label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: stage.state == WorkspaceStageState.running ? FontWeight.w700 : FontWeight.w500,
            color: stage.state == WorkspaceStageState.failed ? p.warn : p.ink,
          ),
        ),
        if (stage.detail.trim().isNotEmpty) ...<Widget>[
          const SizedBox(width: 4),
          Text(stage.detail, style: TextStyle(fontSize: 11, color: p.ink4)),
        ],
        if (index < 0) const SizedBox.shrink(),
      ],
    );
  }
}
