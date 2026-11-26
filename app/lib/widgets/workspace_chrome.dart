/// 四个工作台共用的外壳骨架（设计 / 3D / 视频 / 热应用）。
///
/// 用户裁决（2026-11-20）：四个工作台外壳完全一致——**设计工作台用什么壳，
/// 插件工作台（`plugin:*`）就用同一套壳**。插件内容不再整页替换 `Workspace`
/// 的 Scaffold，而是只占「设计画布」那块主区：标题栏（项目下拉/设置/主题）、
/// 左侧图标轨、右栏/窄条、底部状态栏全部由本骨架提供，插件自己的 46px 工具条
/// 保留在内容区顶部（那是各模块自己的面，不改语义）。
///
/// 材质语言（用户裁决 2026-11-26）：**浅色主题 = Aqua**。外壳在浅色下是
/// Aqua 的窗口面——主区/状态栏用细条纹（pinstripe）表面 + 深色软阴影；
/// **深色主题保持原样**（分支只按 `isAquaTheme` 取舍，几何不变）。
///
/// 分工：
/// * [WorkspaceChrome] 只做视觉骨架（Column/Row 组装），不做断点判断——断点
///   唯一来源仍是 `core/layout.dart` 与 `workspace.dart` 的 LayoutBuilder；
/// * [WorkspaceMainArea] 是设计画布与插件内容共用的「主区槽」：无额外外边距，
///   边界由相邻 chrome 的 1px 内线围合（TitleBar 底边 / Rail 右边 / 右栏左边 /
///   状态栏顶边），与设计画布完全一致；插件内部的 14px 留边属于模块自身。
library;

import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';
import 'aqua.dart';

/// 主区槽：设计画布 / 插件内容（3D / 视频 / 热应用）只在这里换人。
///
/// 测试锚点 `workspace-main-area`：四个工作台的「内容区」是同一个容器，
/// 插件内容必须落在它里面（而不是另起一套整页 Scaffold）。
class WorkspaceMainArea extends StatelessWidget {
  final Widget child;

  const WorkspaceMainArea({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    // 浅色 = Aqua：主区是细条纹窗口面（AquaWindowSurface 内自带 RepaintBoundary，
    // 条纹静态绘制，不产生动画帧）。内边距保持 0——主区仍贴边铺满，
    // 插件内容住的区域与设计画布完全一致。
    if (isAquaTheme(context)) {
      return AquaWindowSurface(
        key: const ValueKey('workspace-main-area'),
        padding: EdgeInsets.zero,
        child: child,
      );
    }
    // 深色不变：底色取设计画布同款（p.bg）；不加外边距/圆角——设计画布主区
    // 本来就是贴边铺满，插件内容用同一块区域才不会出现「另一种内边距/边框」。
    final p = context.palette;
    return Container(
      key: const ValueKey('workspace-main-area'),
      color: p.bg,
      child: child,
    );
  }
}

/// 外壳骨架：TitleBar（可选）/ Row[左轨, 左栏, 主区, 右栏] / 底部窄条（可选）/
/// 状态栏（可选）。
///
/// 所有槽位由 `Workspace` 按视口断点与产品裁决填：嵌入宿主（聊天分栏/画中画）
/// 不传 TitleBar/StatusBar；插件工作台照常传四个面，只是主区换成插件内容。
class WorkspaceChrome extends StatelessWidget {
  /// 顶部标题栏（项目下拉/设置/主题）；嵌入宿主为 null。
  final Widget? titleBar;

  /// 左侧图标轨（完整壳是 [Rail]，嵌入宿主是局部导航窄轨）。
  final Widget? rail;

  /// 左侧内容面板（设计壳的板/图层/文档/历史）；插件视图不传（插件有自己的面）。
  final Widget? leftPanel;

  /// 主区内容：设计画布或插件工作台。
  final Widget main;

  /// 右侧面板（独立 Workspace 的 348 栏）；桌面壳由 ChatRail 取代，传 null。
  final Widget? rightPanel;

  /// 窄屏折叠条（面板收进底部 sheet 的入口）；不适用时为 null。
  final Widget? narrowBar;

  /// 底部状态栏；嵌入宿主为 null。
  final Widget? statusBar;

  const WorkspaceChrome({
    super.key,
    this.titleBar,
    this.rail,
    this.leftPanel,
    required this.main,
    this.rightPanel,
    this.narrowBar,
    this.statusBar,
  });

  @override
  Widget build(BuildContext context) {
    final bool aqua = isAquaTheme(context);
    return Column(
      children: [
        // 静态头部隔离重绘：内容层动画/滚动不把标题栏一起重画。
        if (titleBar != null) ...[
          RepaintBoundary(child: titleBar!),
          // 浅色 = Aqua：标题栏下沿压一条软阴影（与状态栏上沿同一材质语言）。
          if (aqua) const _AquaSoftShadow(flip: true),
        ],
        Expanded(
          child: Row(
            children: [
              ?rail,
              ?leftPanel,
              Expanded(child: WorkspaceMainArea(child: main)),
              ?rightPanel,
            ],
          ),
        ),
        ?narrowBar,
        // 浅色 = Aqua：状态栏是窗底细条纹面，上方压一条深色软阴影（上升渐隐），
        // 让状态栏像 Aqua 里那种微微凸起的底条；深色主题保持原样。
        if (aqua && statusBar != null) ...[
          const _AquaSoftShadow(flip: false),
          RepaintBoundary(
            child: AquaWindowSurface(
              padding: EdgeInsets.zero,
              child: statusBar!,
            ),
          ),
        ],
        if (!aqua && statusBar != null) RepaintBoundary(child: statusBar!),
      ],
    );
  }
}

/// 浅色（Aqua）窗口的深色软阴影：一条渐隐窄带。
///
/// [flip] 为 false 时最深处落在底边（向上渐隐，用于状态栏上沿）；
/// 为 true 时最深处落在顶边（向下渐隐，用于标题栏下沿）。
/// 颜色取 palette 的深色内线（[NonPalette.lineStrong]）叠透明度，
/// 不硬编码黑色；静态绘制，包一层 [RepaintBoundary]。
class _AquaSoftShadow extends StatelessWidget {
  const _AquaSoftShadow({required this.flip});

  final bool flip;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final Color deep = p.lineStrong.withValues(alpha: 0.30);
    final Color clear = p.lineStrong.withValues(alpha: 0);
    return RepaintBoundary(
      child: IgnorePointer(
        child: Container(
          height: NonSpace.sm,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: flip ? Alignment.topCenter : Alignment.bottomCenter,
              end: flip ? Alignment.bottomCenter : Alignment.topCenter,
              colors: <Color>[deep, clear],
            ),
          ),
        ),
      ),
    );
  }
}
