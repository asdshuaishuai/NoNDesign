/// 桌面 / iPad 横屏壳：**工作区（或经典 Welcome）为主面 + 右侧唯一聊天窄栏**。
///
/// 与 [ChatPiPShell] 的分工是产品裁决（见 `core/layout.dart`）：
/// * 桌面（macOS / Windows / Linux）永远走本壳，窗口多窄都不降级成手机壳；
/// * iPad / Android 平板横屏也走本壳（1024×768、1194×834）；
/// * 无项目时主面是经典 Welcome（最近项目 / 一句话起步 / 工作台 / 作品集），
///   不是空工作区 pane；
/// * 窄栏宽 clamp(320,420)（默认 360），视口 <1100 默认折叠、
///   <700+320 强制折叠，折叠态是主面右侧的第二列 44px 条带（不叠在主面上，
///   顶栏设置/主题与状态栏右段永不被盖）；展开时保证主面 ≥700；
/// * 壳层消费软键盘 inset：iPad 横版键盘弹出时主面与窄栏一起缩到键盘之上；
/// * 内嵌 [Workspace] 传 `showRightPanel: false`——右侧只有一个窄栏，绝不
///   与 348 的 RightPanel 形成双栏。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/layout.dart';
import '../core/store.dart';
import '../core/theme.dart';
import 'chat_rail.dart';
import 'shell_host.dart';
import 'settings_dialog.dart';
import 'welcome.dart';
import 'workspace.dart';

class DesktopShell extends StatefulWidget {
  /// 分类结果（壳路由已判定为 [LayoutClass.desktop] / tabletLandscape）。
  final LayoutClass layout;

  const DesktopShell({super.key, required this.layout});

  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends State<DesktopShell> {
  /// 用户显式选择的窄栏展开态；null = 未存过，按视口宽度取默认。
  bool? _railExpandedPref;

  double _railWidth = kChatRailDefaultWidth;
  String _tab = kRailTabAgent;

  /// 最近一帧的布局视口宽（布局回调里更新）：折叠条/命令回调据此判断
  /// 当前宽度到底能不能展开窄栏。
  double _viewportWidth = double.infinity;

  /// 观察 `store.rightTab` 的显式切换（命令面板 / 「让 NaN 继续」等），
  /// 但**忽略**选中节点触发的 inspect 切换（防抢聊天）。
  String? _lastRightTab;
  String? _lastSelectedNode;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    final snap = await ShellStorage.load();
    if (!mounted) return;
    setState(() {
      _railExpandedPref = snap.railExpanded;
      _railWidth = (snap.railWidth ?? kChatRailDefaultWidth)
          .clamp(kChatRailMinWidth, kChatRailMaxWidth)
          .toDouble();
      final tab = snap.railTab;
      if (tab == kRailTabAgent || tab == kRailTabInspect) {
        _tab = tab!;
      } else if (tab == 'chat') {
        // 旧存档：独立「聊天」tab 已并入 NaN（用户实测 2026-11-18）。
        _tab = kRailTabAgent;
      }
    });
  }

  /// 视口是否放得下展开的窄栏（强制折叠阈值 = 主面最小宽 + 栏最小宽）。
  ///
  /// 注意与 [_expandedFor] 的区别：1020–1100 之间默认折叠，但**点开仍能
  /// 展开**——「默认折叠」不等于「放不下」。
  bool _canExpand(double viewport) => viewport >= kDesktopRailForceCollapseWidth;

  bool _expandedFor(double viewport) {
    if (!_canExpand(viewport)) return false;
    return _railExpandedPref ?? viewport >= kDesktopRailAutoExpandWidth;
  }

  /// 展开时主面至少 [kDesktopMainMinWidth]；[kDesktopRailForceCollapseWidth]
  /// （= 700 + 320 = 1020）以下已被强制折叠。
  double _maxRailWidthFor(double viewport) {
    final room = viewport - kDesktopMainMinWidth;
    return room.clamp(kChatRailMinWidth, kChatRailMaxWidth).toDouble();
  }

  void _collapse() {
    setState(() => _railExpandedPref = false);
    ShellStorage.saveRail(expanded: false);
  }

  /// 放不下的宽度上点了折叠条/收到展开命令：给人话提示，绝不静默无效。
  void _notifyRailBlocked() {
    context.read<AppStore>().toasts.warn(
          '窗口太窄，聊天栏展不开',
          '把窗口拉宽一些再试',
        );
  }

  void _openWithTab(String tab) {
    if (!_canExpand(_viewportWidth)) {
      setState(() => _tab = tab);
      _notifyRailBlocked();
      return;
    }
    setState(() {
      _railExpandedPref = true;
      _tab = tab;
    });
    context.read<AppStore>().setRightTab(tab);
    ShellStorage.saveRail(expanded: true, tab: tab);
  }

  void _setTab(String tab) {
    if (tab == _tab) return;
    setState(() => _tab = tab);
    context.read<AppStore>().setRightTab(tab);
    ShellStorage.saveRail(tab: tab);
  }

  void _onResize(double dx, double viewport) {
    final next = (_railWidth - dx)
        .clamp(kChatRailMinWidth, _maxRailWidthFor(viewport))
        .toDouble();
    if (next == _railWidth) return;
    setState(() => _railWidth = next);
  }

  void _persistWidth() => ShellStorage.saveRail(width: _railWidth);

  /// 跟随显式的右栏命令（命令面板 / 画布「让 NaN 继续」/ 检查器按钮），
  /// 但节点选中带来的 inspect 切换不抢聊天（批次 12 风险项）。
  ///
  /// 视口放不下展开栏时也**不能静默**：条带高亮到请求的 tab，并给出人话提示。
  ///
  /// 已知边界：`setRightTab` 对同值也会通知，但这里只能看到「值变了」这一个
  /// 信号——命令把右栏指向**已经选中**的 tab 时无值变化可辨（展开态无影响；
  /// 折叠态下的可点入口是常驻条带）。要覆盖这一格需要命令侧带显式意图。
  void _observeRightTab(AppStore store, double viewport) {
    final rightTab = store.rightTab;
    final selected = store.selectedNode;
    final rightChanged = _lastRightTab != null && rightTab != _lastRightTab;
    final selectionChanged = _lastSelectedNode != null && selected != _lastSelectedNode;
    _lastRightTab = rightTab;
    _lastSelectedNode = selected;
    if (!rightChanged) return;
    if (rightTab != kRailTabAgent && rightTab != kRailTabInspect) return;
    if (rightTab == kRailTabInspect && selectionChanged) return;
    final blocked = !_canExpand(viewport);
    if (!blocked && _tab == rightTab) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 用最新一帧的视口：命令与回调之间用户可能已经改过窗口宽度。
      if (!_canExpand(_viewportWidth)) {
        // 显式命令在窄到放不下时：高亮请求的 tab，并明确告知为什么没开。
        setState(() => _tab = store.rightTab);
        _notifyRailBlocked();
        return;
      }
      if (_tab == store.rightTab) return;
      setState(() {
        _tab = store.rightTab;
        // 显式命令（命令面板 / 「让 NaN 继续」/ 标题栏按钮）也要让窄栏可见，
        // 否则命令生效在 UI 上等于没反应。
        _railExpandedPref = true;
      });
      ShellStorage.saveRail(expanded: true, tab: store.rightTab);
    });
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final p = context.palette;
    // Scaffold 的 resizeToAvoidBottomInset（默认 true）让 iPad 横版的软键盘
    // 把整壳（主面 + 右侧窄栏）一起缩到键盘之上——此前窄栏输入框留在键盘
    // 底下；Scaffold 同时把底部 viewInsets 从 body 的 MediaQuery 移除，
    // Workspace 内层 Scaffold 不会二次收缩。
    return Scaffold(
      backgroundColor: p.bg,
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final viewport = constraints.maxWidth;
            _viewportWidth = viewport;
            _observeRightTab(store, viewport);
            final main = _mainFace(store);
            // 主页（无项目）全宽：右侧栏只在工作区出现。用户实测 2026-11-18：
            // 冷启动 Welcome 右侧常驻聊天栏，主页会被误读成「聊天 + 工作台」双面。
            if (_isHome(store)) return main;
            final expanded = _expandedFor(viewport);
            if (!expanded) {
              // 折叠态：44px 条带是 Row 的第二列，不再用 Stack 叠在主面右缘
              // ——顶栏最右侧的「设置 ⌘,」「切换主题」与状态栏右段（版本/
              // 画板/节点/模型/上下文）在任何宽度下都完整可见可点。
              return Row(
                children: [
                  Expanded(child: main),
                  ChatRailStrip(
                    key: const ValueKey('desktop-chat-rail-strip'),
                    tab: _tab,
                    onTab: _openWithTab,
                  ),
                ],
              );
            }
            final railWidth = _railWidth
                .clamp(kChatRailMinWidth, _maxRailWidthFor(viewport))
                .toDouble();
            return Row(
              children: [
                Expanded(child: main),
                ChatRail(
                  key: const ValueKey('desktop-chat-rail'),
                  width: railWidth,
                  tab: _tab,
                  onTab: _setTab,
                  onCollapse: _collapse,
                  onResize: (dx) => _onResize(dx, viewport),
                  onResizeEnd: _persistWidth,
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// 主页 = 无项目且没有离线/导入文档可看。桌面主页不挂右侧栏。
  bool _isHome(AppStore store) {
    // 离线恢复/导入的文档没有项目也要可见（旧路由的 api==null && docs 语义）。
    final docsVisible = store.view == 'docs' &&
        (store.docs.prd.trim().isNotEmpty || store.docs.ui.trim().isNotEmpty);
    return !store.hasProject && !docsVisible;
  }

  Widget _mainFace(AppStore store) {
    if (_isHome(store)) {
      return Welcome(
        onNewProject: () => showNewProjectFlow(context),
        onOpenPath: (path) => openProjectFlow(context, path),
        onSettings: () => showSettingsDialog(context),
        // 主页没有右侧栏：聊天入口不再假装能开栏，主面用一句话起步输入框。
        showChatEntry: false,
      );
    }
    // 右侧只有一个窄栏：Workspace 自己的 348 右栏必须关掉。
    return const Workspace(showRightPanel: false);
  }
}
