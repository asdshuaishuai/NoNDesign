/// 四工作台统一的「执行过程面」阶段模型（纯 Dart，不依赖 Flutter）。
///
/// 工作台 UI 只渲染这个模型；真实进度来源是各模块自己的执行链（设计验证 /
/// 3D plan→check / 视频剧本→渲染 / 音乐写谱→编译）。与聊天时间线分工：
/// chat 给逐事件轨迹，工作台给模块化阶段条（plan-creative-workbench §2.2）。
library;

/// 阶段状态。`running` 只有一个；`failed` 终止本次管线。
enum WorkspaceStageState { pending, running, done, failed }

/// 一个阶段（id 稳定，供测试/文案锚定）。
final class WorkspaceStage {
  const WorkspaceStage({
    required this.id,
    required this.label,
    this.detail = '',
    this.state = WorkspaceStageState.pending,
  });

  final String id;
  final String label;
  final String detail;
  final WorkspaceStageState state;

  WorkspaceStage copyWith({
    String? label,
    String? detail,
    WorkspaceStageState? state,
  }) =>
      WorkspaceStage(
        id: id,
        label: label ?? this.label,
        detail: detail ?? this.detail,
        state: state ?? this.state,
      );

  bool get isTerminal =>
      state == WorkspaceStageState.done || state == WorkspaceStageState.failed;
}
