/// 工作台内容区的独立布局规格（纯 Dart，可测）。
///
/// 用户方向（2026-11-24）：四个工作台不再共用一套内容区布局，而是各自独立的
/// **交互姿态 + 面板/底栏策略**；共享的只有外层 `WorkspaceChrome`（标题栏/左轨/
/// 右侧 chat/状态栏）。本文件只做断点与策略解析，不渲染、不依赖 Flutter。
///
/// 施工顺序：设计 → 3D → 视频 → 音乐；**热应用暂不改动**。
library;

/// 工作台种类（与项目类型/视图一一对应）。
enum WorkbenchKind { design, three, video, music }

/// 侧栏呈现策略。`sheet` 表示折叠成底部面板入口（由外壳的窄条/手机形态承接）。
enum PanelPolicy { hidden, docked, sheet }

/// 每个工作台自己的断点与面板几何。
///
/// 这里刻意**不是一份全局常量**：3D/视频/音乐的左栏语义与设计面不同，宽度和
/// 折叠阈值可以各自决定；新增工作台必须显式给规格，不能落到设计面默认。
final class WorkbenchLayoutSpec {
  const WorkbenchLayoutSpec({
    required this.kind,
    required this.phoneMaxWidth,
    required this.leftDockMinWidth,
    required this.rightDockMinWidth,
    required this.leftWidth,
    required this.rightWidth,
    this.embeddedLeftDockMinWidth = 760,
    this.embeddedRightDockMinWidth = 1100,
    this.bottomBar = false,
    this.bottomBarHeight = 0,
  });

  final WorkbenchKind kind;

  /// 手机断点（低于它左右面板都走 sheet/隐藏；每个工作台可不同）。
  final double phoneMaxWidth;

  /// 左栏常驻最小宽度（设计=项目面板，3D=大纲，视频=剧本树，音乐=声部）。
  final double leftDockMinWidth;

  /// 右栏常驻最小宽度（各工作台的检查器语义不同）。
  final double rightDockMinWidth;
  final double leftWidth;
  final double rightWidth;

  /// 嵌入宿主（聊天分栏/画中画）里更严格的左右最小宽度。
  final double embeddedLeftDockMinWidth;
  final double embeddedRightDockMinWidth;

  /// 内容区是否自带底栏（3D 状态条/视频时间线/音乐运输条）。
  final bool bottomBar;
  final double bottomBarHeight;
}

/// 解析后的布局（widget 只读它，不再散落 252/348/700/1024 魔法数）。
final class WorkbenchLayout {
  const WorkbenchLayout({
    required this.kind,
    required this.left,
    required this.right,
    required this.rail,
    required this.bottomBar,
    required this.bottomBarHeight,
    required this.leftWidth,
    required this.rightWidth,
    required this.isPhone,
    required this.isWide,
  });

  final WorkbenchKind kind;
  final PanelPolicy left;
  final PanelPolicy right;
  final bool rail;
  final bool bottomBar;

  /// 自带底栏时的固定高度（0 = 没有底栏；widget 不另写字面量高度）。
  final double bottomBarHeight;

  final double leftWidth;
  final double rightWidth;
  final bool isPhone;
  final bool isWide;
}

/// 四工作台规格。顺序/默认值对应 2026-11-24 的独立适配计划。
const Map<WorkbenchKind, WorkbenchLayoutSpec> workbenchLayoutSpecs =
    <WorkbenchKind, WorkbenchLayoutSpec>{
      WorkbenchKind.design: WorkbenchLayoutSpec(
        kind: WorkbenchKind.design,
        phoneMaxWidth: 700,
        leftDockMinWidth: 700,
        rightDockMinWidth: 1024,
        leftWidth: 252,
        rightWidth: 348,
      ),
      WorkbenchKind.three: WorkbenchLayoutSpec(
        kind: WorkbenchKind.three,
        phoneMaxWidth: 720,
        leftDockMinWidth: 900,
        rightDockMinWidth: 1024,
        leftWidth: 236,
        rightWidth: 300,
        bottomBar: true,
        bottomBarHeight: 34,
      ),
      WorkbenchKind.video: WorkbenchLayoutSpec(
        kind: WorkbenchKind.video,
        phoneMaxWidth: 760,
        leftDockMinWidth: 980,
        rightDockMinWidth: 1024,
        leftWidth: 280,
        rightWidth: 320,
        bottomBar: true,
        bottomBarHeight: 148,
      ),
      WorkbenchKind.music: WorkbenchLayoutSpec(
        kind: WorkbenchKind.music,
        phoneMaxWidth: 800,
        leftDockMinWidth: 900,
        rightDockMinWidth: 1024,
        leftWidth: 220,
        rightWidth: 300,
        bottomBar: true,
        bottomBarHeight: 64,
      ),
    };

/// 解析指定工作台在给定视口下的布局。
///
/// 未知宽度/高度按手机下限处理（不放心地张开侧栏）；`embedded` 时左/右最小
/// 常驻宽度更严格（聊天分栏/画中画不能把画布压没）。
WorkbenchLayout resolveWorkbenchLayout({
  required WorkbenchKind kind,
  required double width,
  required double height,
  bool embedded = false,
}) {
  final WorkbenchLayoutSpec spec =
      workbenchLayoutSpecs[kind] ?? workbenchLayoutSpecs[WorkbenchKind.design]!;
  final bool phone = width < spec.phoneMaxWidth;
  final double leftMin = embedded
      ? spec.embeddedLeftDockMinWidth
      : spec.leftDockMinWidth;
  final double rightMin = embedded
      ? spec.embeddedRightDockMinWidth
      : spec.rightDockMinWidth;
  final PanelPolicy left;
  if (phone) {
    left = PanelPolicy.sheet;
  } else if (width >= leftMin) {
    left = PanelPolicy.docked;
  } else {
    left = PanelPolicy.hidden;
  }
  final PanelPolicy right = width >= rightMin
      ? PanelPolicy.docked
      : PanelPolicy.sheet;
  // 嵌入壳高度很小时隐藏左轨（画中画 280 高放不下固定图标列），与现状一致。
  final bool rail = !(embedded && height < 262);
  return WorkbenchLayout(
    kind: kind,
    left: left,
    right: right,
    rail: rail,
    bottomBar: spec.bottomBar,
    bottomBarHeight: spec.bottomBarHeight,
    leftWidth: spec.leftWidth,
    rightWidth: spec.rightWidth,
    isPhone: phone,
    isWide: right == PanelPolicy.docked,
  );
}

/// 视图名（`plugin:three` 等）→ 工作台种类；设计面 `docs/source` 也归设计。
///
/// `plugin:video3d`（3D 视频工作台）沿用视频导演台的内容区规格（时间线底栏、
/// 左项目/右检查器语义同族），不新增第五份规格、不改既有四工作台断点语义。
WorkbenchKind? workbenchKindForView(String view) => switch (view) {
  'plugin:three' => WorkbenchKind.three,
  'plugin:video' => WorkbenchKind.video,
  'plugin:video3d' => WorkbenchKind.video,
  'plugin:music' => WorkbenchKind.music,
  'plugin:hotapp' => null, // 热应用暂不改布局
  _ => WorkbenchKind.design,
};
