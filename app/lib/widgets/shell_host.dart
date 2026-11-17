import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/store.dart';
import '../core/theme.dart';
import 'chat_stream.dart';
import 'common.dart';
import 'pip_window.dart';
import 'workspace.dart';

/// 分栏分隔条宽度（拖动命中区；左右各一条 1px 分隔线，中间 4px 是拖动面）。
const double _splitBarWidth = 6;

/// 聊天流宿主（docs/plan-chat-stream-shell.md §2 / §5 S4）：
///
/// - 桌面（宽 ≥1100）：chat（左）+ workspace（右）常驻分栏，分隔条可拖
///   （`_splitFraction` 0.32–0.62，chat 不窄于 360），可折叠；
/// - 移动 / pad 竖屏（<1100）：chat 全屏，右缘右划或常驻胶囊拖出
///   workspace 画中画浮窗（可拖动/缩放/全屏/收回）；
/// - pad 横屏按宽度自适应：≥1100 自动落分栏，否则落浮窗模式。
///
/// 不改既有全屏工作区语义：view=design/docs/source/play/portfolio/plugin:*
/// 仍由 main.dart 与 Workspace 的早退分支各走各的；本宿主只接管 view==chat
/// 与 chatStreamHome 两个入口。
class ChatWorkspaceHost extends StatefulWidget {
  /// 设置入口回调（原样透传给聊天流顶栏；缺省由聊天流自行弹设置）。
  final VoidCallback? onSettings;

  const ChatWorkspaceHost({super.key, this.onSettings});

  @override
  State<ChatWorkspaceHost> createState() => _ChatWorkspaceHostState();
}

class _ChatWorkspaceHostState extends State<ChatWorkspaceHost> {
  /// 分栏比例（chat 占比），拖动分隔条时更新；钳在 0.32–0.62。
  double _splitFraction = 0.46;

  /// 分栏折叠（只剩 chat；右侧留一条可点开的窄轨）。
  bool _collapsed = false;

  /// 分栏「全屏」：工作区面板吃掉整个宿主。**不切 store.view**——切了就等于
  /// 把聊天宿主整块换掉，触屏用户从此没有回聊天流的入口（review pip-1）。
  bool _workspaceFull = false;

  /// 面板空态的失败提示（离线 api==null 时 store.newProject 静默返回 false，
  /// 空态必须自己给出反馈；review pip-3）。
  String? _paneHint;

  // ---- 画中画（窄屏）----
  bool _pipOpen = false;
  bool _pipMax = false;
  Rect? _pipRect;

  void _toggleCollapsed() => setState(() {
        _collapsed = !_collapsed;
        _workspaceFull = false;
      });

  /// 产物卡「打开工作区」：只展开不收起（顶栏按钮是折叠切换，语义不同）。
  void _revealWorkspace() => setState(() {
        _collapsed = false;
        _workspaceFull = false;
      });

  /// 面板内建空画板：走公有 `newProject(empty: true)`——**不能**用
  /// `store.openWorkspace()`（它会 setView('design')，把宿主整个拆掉）。
  /// newProject(empty:) 对非聊天 run 的调用方默认也把 view 切到 'design'，
  /// 这里在同一 microtask 链里恢复 'chat'（empty 路径无真实 IO，下一帧前
  /// 已完成），守住「面板内建板不离开聊天宿主」。
  Future<void> _createEmptyProject(AppStore store) async {
    // 离线（api==null，boot 降级路径）：newProject 直接返回 false 且不发
    // toast（store.dart 的入口门）——不预检就是静默无反应。
    if (store.api == null) {
      setState(() => _paneHint = '离线模式：新建画板需要连接 NoN 服务，连上后重试。');
      return;
    }
    setState(() => _paneHint = null);
    final ok = await store.newProject(empty: true);
    if (!ok || !mounted) return;
    if (store.view != 'chat') store.setView('chat');
  }

  void _openPip() => setState(() => _pipOpen = true);

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final p = context.palette;
    return Material(
      color: p.bg,
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 1100;
            return wide ? _wideLayout(store, constraints) : _narrowLayout(store, constraints);
          },
        ),
      ),
    );
  }

  // ---------------- 桌面：常驻分栏 ----------------

  Widget _wideLayout(AppStore store, BoxConstraints constraints) {
    // 工作区铺满：只留面板（宿主内全屏——不换路由）。
    if (_workspaceFull) return _workspacePane(store, inPip: false);
    final avail = math.max(1.0, constraints.maxWidth - _splitBarWidth);
    final fraction = _splitFraction.clamp(0.32, 0.62);
    // chat 不窄于 360（窄于此聊天卡片与输入区不可用）；工作区按剩余分摊。
    final chatWidth = math.max(360.0, avail * fraction);
    final chatFlex = math.max(1, (chatWidth / avail * 1000).round());
    final paneFlex = math.max(1, 1000 - chatFlex);
    final chat = ChatStreamView(
      onSettings: widget.onSettings,
      onOpenWorkspace: _toggleCollapsed,
      onRevealWorkspace: _revealWorkspace,
    );
    return Row(
      children: [
        Expanded(
          flex: _collapsed ? 1 : chatFlex,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 360),
            child: chat,
          ),
        ),
        if (_collapsed)
          _CollapsedRail(onExpand: _toggleCollapsed)
        else ...[
          _SplitHandle(
            onDrag: (dx) => setState(() {
              _splitFraction = (_splitFraction + dx / avail).clamp(0.32, 0.62);
            }),
          ),
          Expanded(flex: paneFlex, child: _workspacePane(store, inPip: false)),
        ],
      ],
    );
  }

  // ---------------- 移动 / pad 竖屏：画中画 ----------------

  Widget _narrowLayout(AppStore store, BoxConstraints constraints) {
    final area = Size(constraints.maxWidth, constraints.maxHeight);
    _pipRect ??= _defaultPipRect(area);
    final effective = _pipMax ? (Offset.zero & area) : _clampPipRect(_pipRect!, area);
    return Stack(
      children: [
        Positioned.fill(
          child: ChatStreamView(
            onSettings: widget.onSettings,
            onOpenWorkspace: _openPip,
            onRevealWorkspace: _openPip,
          ),
        ),
        if (_pipOpen)
          Positioned.fromRect(
            rect: effective,
            child: PipWindow(
              key: const ValueKey('chat-pip-window'),
              title: '工作区',
              rect: effective,
              maximized: _pipMax,
              onRect: (r) => setState(() {
                _pipRect = _clampPipRect(r, area);
                if (_pipMax) _pipMax = false;
              }),
              onClose: () => setState(() => _pipOpen = false),
              onToggleMax: () => setState(() => _pipMax = !_pipMax),
              child: _workspacePane(store, inPip: true),
            ),
          ),
        if (!_pipOpen) Positioned.fill(child: PipEdgeHandle(onOpen: _openPip)),
      ],
    );
  }

  /// 初始浮窗：右下角，盖住部分聊天；尺寸按堆叠区比例钳（下限见
  /// [kPipMinSize]）。
  Rect _defaultPipRect(Size area) {
    final w = math.min(560.0, area.width * 0.86);
    final h = math.min(620.0, area.height * 0.82);
    return _clampPipRect(
      Rect.fromLTWH(area.width - w - 12, area.height - h - 12, w, h),
      area,
    );
  }

  /// 浮窗几何统一收口：不小于 [kPipMinSize]，且整体留在堆叠区内（含 8px
  /// 边距）——拖动/缩放都经这里，窗口不会被拖出可视面或缩到不可用。
  Rect _clampPipRect(Rect r, Size area) {
    final maxW = math.max(kPipMinSize.width, area.width - 16);
    final maxH = math.max(kPipMinSize.height, area.height - 16);
    final w = r.width.clamp(kPipMinSize.width, maxW).toDouble();
    final h = r.height.clamp(kPipMinSize.height, maxH).toDouble();
    final left = r.left.clamp(8.0, math.max(8.0, area.width - w - 8)).toDouble();
    final top = r.top.clamp(8.0, math.max(8.0, area.height - h - 8)).toDouble();
    return Rect.fromLTWH(left, top, w, h);
  }

  // ---------------- 工作区面板（分栏与浮窗共用） ----------------

  Widget _workspacePane(AppStore store, {required bool inPip}) {
    final full = inPip ? _pipMax : _workspaceFull;
    return Column(
      key: ValueKey(inPip ? 'chat-pip-workspace-pane' : 'chat-shell-workspace-pane'),
      children: [
        _SlimHeader(
          title: '工作区 · ${store.hasProject ? store.projectName : '未开始'}',
          actions: [
            IconAction(
              key: const ValueKey('chat-shell-collapse'),
              icon: Icons.keyboard_double_arrow_right,
              tooltip: inPip ? '收回浮窗' : '折叠工作区',
              onTap: inPip
                  ? () => setState(() => _pipOpen = false)
                  : () => setState(() {
                        _collapsed = true;
                        _workspaceFull = false;
                      }),
            ),
            IconAction(
              key: const ValueKey('chat-shell-fullscreen'),
              icon: full ? Icons.fullscreen_exit : Icons.open_in_full,
              tooltip: full ? '还原工作区' : '全屏工作区',
              // 宿主内全屏：分栏时工作区铺满宿主、浮窗时最大化窗口。
              // 绝不 setView('design')——那会把聊天宿主整块换掉（review pip-1）。
              onTap: inPip
                  ? () => setState(() => _pipMax = !_pipMax)
                  : () => setState(() => _workspaceFull = !_workspaceFull),
            ),
            IconAction(
              key: const ValueKey('chat-shell-close'),
              icon: Icons.close,
              tooltip: inPip ? '关闭浮窗' : '关闭工作区',
              onTap: inPip
                  ? () => setState(() => _pipOpen = false)
                  : () => setState(() {
                        _collapsed = true;
                        _workspaceFull = false;
                      }),
            ),
          ],
        ),
        Expanded(
          child: store.hasProject
              ? const Workspace(embedded: true)
              : _PaneEmpty(hint: _paneHint, onCreate: () => _createEmptyProject(store)),
        ),
      ],
    );
  }
}

/// 面板顶栏：36px 细条（分栏/浮窗共用；完整壳的 TitleBar 不进嵌入式）。
class _SlimHeader extends StatelessWidget {
  final String title;
  final List<Widget> actions;

  const _SlimHeader({required this.title, this.actions = const []});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      height: 36,
      padding: const EdgeInsets.only(left: 10, right: 4),
      decoration: BoxDecoration(
        color: p.bgElevated,
        border: Border(bottom: BorderSide(color: p.line)),
      ),
      child: Row(
        children: [
          Icon(Icons.space_dashboard_outlined, size: 14, color: p.ink4),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: p.ink2),
            ),
          ),
          ...actions,
        ],
      ),
    );
  }
}

/// 无项目空态：显式「新建空画板」（面板内建项目不再隐式跳全屏设计视图）。
class _PaneEmpty extends StatelessWidget {
  final VoidCallback onCreate;

  /// 失败提示（离线等）：空态不能对点击静默无反应。
  final String? hint;

  const _PaneEmpty({required this.onCreate, this.hint});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.space_dashboard_outlined, size: 26, color: p.ink4),
          const SizedBox(height: 10),
          Text('工作区 · 等待第一块画板',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: p.ink3)),
          const SizedBox(height: 4),
          Text('聊天里让 NoN 生成原型，或先建一块空画板。',
              style: TextStyle(fontSize: 10.5, color: p.ink4)),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            key: const ValueKey('chat-shell-create-board'),
            onPressed: onCreate,
            icon: Icon(Icons.add, size: 14, color: p.ink2),
            label: Text('新建空画板', style: TextStyle(fontSize: 11.5, color: p.ink2)),
          ),
          if (hint != null)
            Padding(
              padding: const EdgeInsets.only(top: 10, left: 16, right: 16),
              child: Text(
                hint!,
                key: const ValueKey('chat-shell-pane-hint'),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 10.5, height: 1.5, color: p.warn),
              ),
            ),
        ],
      ),
    );
  }
}

/// 分栏折叠后的右侧窄轨：点一下重新展开工作区。
class _CollapsedRail extends StatelessWidget {
  final VoidCallback onExpand;

  const _CollapsedRail({required this.onExpand});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Material(
      color: p.bgElevated,
      child: Container(
        width: 36,
        decoration: BoxDecoration(border: Border(left: BorderSide(color: p.line))),
        child: Column(
          children: [
            const SizedBox(height: 6),
            IconAction(
              key: const ValueKey('chat-shell-expand'),
              icon: Icons.space_dashboard_outlined,
              tooltip: '展开工作区',
              onTap: onExpand,
            ),
            const Spacer(),
          ],
        ),
      ),
    );
  }
}

/// 6px 可拖分隔条（横向拖动改 chat 占比）。
class _SplitHandle extends StatelessWidget {
  final ValueChanged<double> onDrag;

  const _SplitHandle({required this.onDrag});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        key: const ValueKey('chat-shell-split'),
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (d) => onDrag(d.delta.dx),
        child: Container(
          width: _splitBarWidth,
          decoration: BoxDecoration(
            color: p.bg,
            border: Border(
              left: BorderSide(color: p.line),
              right: BorderSide(color: p.line),
            ),
          ),
        ),
      ),
    );
  }
}
