/// 手机（竖/横）与 iPad 竖屏壳：**聊天全屏 + 工作区画中画**。
///
/// 这是产品裁决 C 的落地面（见 `core/layout.dart`）：3:4 平板放不下
/// 「工作区 + 320–420 聊天栏」，所以竖屏平板不进入桌面壳，而是保留聊天主面，
/// 工作区经右缘手势/胶囊拉出 [PipWindow] 浮窗（最小 320×280，可拖动/缩放/
/// 全屏/收回）。浮窗矩形经 [ShellStorage] 持久化，重启恢复。
///
/// `chatStreamHome` 在本壳里仍然有效：关闭后回到经典 Welcome/全屏工作区，
/// 右下角常驻「聊天」胶囊可随时切回（不会把用户锁死在没有聊天的界面）。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/layout.dart';
import '../core/store.dart';
import '../core/theme.dart';
import 'chat_stream.dart';
import 'pip_window.dart';
import 'settings_dialog.dart';
import 'shell_host.dart';
import 'welcome.dart';
import 'workspace.dart';

class ChatPiPShell extends StatefulWidget {
  /// 分类结果（壳路由已判定为 phone*/tabletPortrait）。
  final LayoutClass layout;

  const ChatPiPShell({super.key, required this.layout});

  @override
  State<ChatPiPShell> createState() => _ChatPiPShellState();
}

class _ChatPiPShellState extends State<ChatPiPShell> {
  bool _pipOpen = false;
  bool _pipMax = false;
  Rect? _pipRect;

  /// 面板空态的失败提示（离线/未连接时 store.newProject 静默返回 false，
  /// 空态必须自己给出反馈）。
  String? _paneHint;

  /// 自动拉起画中画的监听目标（didChangeDependencies 里接线）。
  AppStore? _observed;

  /// 本次 run 是否已经自动拉起过：一轮 run 只拉一次，不跟用户抢开关。
  bool _autoOpenedForRun = false;

  bool _wasAgentBusy = false;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final s = context.read<AppStore>();
    if (!identical(s, _observed)) {
      _observed?.removeListener(_onStoreChanged);
      _observed = s..addListener(_onStoreChanged);
    }
  }

  /// 移动适配裁决（2026-11-19）：手机/竖屏平板「运行 chat agent 时直接
  /// 预览工作区实况」——首轮实况帧就绪（previewRender 从空到有）且浮窗
  /// 未开时自动拉起画中画；一轮只拉一次，用户手动关掉后不再抢回。
  void _onStoreChanged() {
    final s = _observed;
    if (s == null || !mounted) return;
    if (s.agentBusy && !_wasAgentBusy) {
      _autoOpenedForRun = false; // 新一轮 run 开始：重置本轮自动拉起标记。
    }
    _wasAgentBusy = s.agentBusy;
    if (_autoOpenedForRun || !s.agentBusy) return;
    if (s.previewRender == null) return;
    _autoOpenedForRun = true;
    if (!_pipOpen) _openPip();
  }

  Future<void> _restore() async {
    final snap = await ShellStorage.load();
    if (!mounted || snap.pipRect == null) return;
    setState(() => _pipRect = snap.pipRect);
  }

  @override
  void dispose() {
    _observed?.removeListener(_onStoreChanged);
    final rect = _pipRect;
    if (rect != null) ShellStorage.savePipRect(rect);
    super.dispose();
  }

  void _persistPipRect() {
    final rect = _pipRect;
    if (rect != null && !_pipMax) ShellStorage.savePipRect(rect);
  }

  /// 开浮窗：复位最大化态（关闭后重开回到上次浮窗尺寸）。
  void _openPip() => setState(() {
        _pipOpen = true;
        _pipMax = false;
      });

  /// 关浮窗的唯一收口（✕/面板内关闭两条路径都走这里）：保留 rect 供重开。
  void _closePip() {
    setState(() {
      _pipOpen = false;
      _pipMax = false;
    });
    _persistPipRect();
  }

  void _togglePipMax() {
    setState(() => _pipMax = !_pipMax);
    _persistPipRect();
  }

  /// 面板内建空画板：走公有 `newProject(empty: true)`，**不**用
  /// `store.openWorkspace()`（那会 setView('design') 把聊天主面换掉）。
  Future<void> _createEmptyProject(AppStore store) async {
    if (store.api == null) {
      setState(() => _paneHint = '离线预览：先连接桌面，或打开已有项目再继续。');
      return;
    }
    setState(() => _paneHint = null);
    final ok = await store.newProject(empty: true);
    if (!ok || !mounted) return;
    if (store.view != 'chat') store.setView('chat');
  }

  /// 经典主面（chatStreamHome 关闭）：全屏工作区 / Welcome + 常驻聊天胶囊。
  void _enableChatHome() {
    final store = context.read<AppStore>();
    store.settings.chatStreamHome = true;
    store.saveSettings();
    store.setView('chat');
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final p = context.palette;
    return Material(
      color: p.bg,
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            // 经典主面（chatStreamHome 关闭）下按 Esc 只会把 store.view 置回
            // 'chat'（根级快捷键不持有壳偏好）——壳必须消费它，否则按键只改了
            // 隐藏状态、界面还停在经典工作区，看起来像失灵。这里让
            // view=='chat' 与 chatStreamHome 同等地落聊天主面，但不改写用户
            // 显式选择的「启动主面」偏好。
            // 插件工作台（3D / 视频 / 热应用）在聊天优先壳里是整屏工作区：
            // 它们不是聊天流的一部分，塞进画中画会把工作台压成指甲盖。
            final fullBleedWorkspace = store.view.startsWith('plugin:');
            final chatHome = (store.settings.chatStreamHome || store.view == 'chat') &&
                !fullBleedWorkspace;
            if (!chatHome) {
              return _classicFace(store);
            }
            return _chatFace(store, Size(constraints.maxWidth, constraints.maxHeight));
          },
        ),
      ),
    );
  }

  Widget _chatFace(AppStore store, Size area) {
    final rect = _pipMax
        ? (Offset.zero & area)
        : _clampPipRect(_pipRect ??= _defaultPipRect(area), area);
    return Stack(
      children: [
        Positioned.fill(
          child: ChatStreamView(
            onOpenWorkspace: _openPip,
            onRevealWorkspace: _openPip,
          ),
        ),
        if (_pipOpen)
          Positioned.fromRect(
            rect: rect,
            child: PipWindow(
              key: const ValueKey('chat-pip-window'),
              title: '工作区',
              rect: rect,
              maximized: _pipMax,
              onRect: (r) => setState(() {
                _pipRect = _clampPipRect(r, area);
                if (_pipMax) _pipMax = false;
              }),
              onInteractEnd: _persistPipRect,
              onClose: _closePip,
              onToggleMax: _togglePipMax,
              child: _workspacePane(store),
            ),
          ),
        if (!_pipOpen) Positioned.fill(child: PipEdgeHandle(onOpen: _openPip)),
      ],
    );
  }

  Widget _classicFace(AppStore store) {
    return Stack(
      children: [
        Positioned.fill(
          // 插件工作台不依赖项目：NaN 在聊天面接下的 3D / 视频 / 热应用任务
          // 会把它切到主面，此时哪怕还没有项目也必须渲染出工作区。
          child: (store.hasProject || store.view.startsWith('plugin:')) && store.view != 'home'
              ? const Workspace()
              : Welcome(
                  onNewProject: () => showNewProjectFlow(context),
                  onOpenPath: (path) => openProjectFlow(context, path),
                  onSettings: () => showSettingsDialog(context),
                  onOpenChat: _enableChatHome,
                ),
        ),
        Positioned(
          right: 16,
          bottom: 16,
          child: FloatingActionButton.extended(
            key: const ValueKey('chat-first-fab'),
            heroTag: 'chat-first-fab',
            backgroundColor: context.palette.accent,
            foregroundColor: Colors.white,
            icon: const Icon(Icons.forum_outlined, size: 18),
            label: const Text('聊天', style: TextStyle(fontSize: 12)),
            onPressed: _enableChatHome,
          ),
        ),
      ],
    );
  }

  /// 初始浮窗：右下角，盖住部分聊天；尺寸按比例钳（下限见 [kPipMinSize]）。
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

  /// 画中画里的工作区面板：顶部常驻项目条（项目名/未保存点/保存/另存/
  /// 打开/新建）。嵌入的 [Workspace] 隐藏了 TitleBar/StatusBar，浮窗最大化
  /// 时聊天主面的顶栏也被整个盖住——项目入口必须活在这里，触屏用户才存得下
  /// 当前项目（docs/design-system.md「所有操作都有可见入口」）。
  Widget _workspacePane(AppStore store) {
    final p = context.palette;
    return Column(
      children: [
        Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: p.line)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: ChatProjectMenu(
                    key: const ValueKey('pip-project-menu'),
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: store.hasProject
              ? const Workspace(embedded: true)
              : _PaneEmpty(
                  hint: _paneHint,
                  onCreate: () => _createEmptyProject(store),
                ),
        ),
      ],
    );
  }
}

/// 无项目空态：显式「新建空画板」（面板内建项目不离开聊天主面）。
class _PaneEmpty extends StatelessWidget {
  final VoidCallback onCreate;

  /// 失败提示（离线等）：空态不能对点击静默无反应。
  final String? hint;

  const _PaneEmpty({required this.onCreate, this.hint});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.space_dashboard_outlined, size: 26, color: p.ink4),
            const SizedBox(height: 10),
            Text('工作区 · 等待第一块画板',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: p.ink3)),
            const SizedBox(height: 4),
            Text('聊天里让 NaN 生成原型，或先建一块空画板。',
                textAlign: TextAlign.center,
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
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  hint!,
                  key: const ValueKey('chat-shell-pane-hint'),
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 10.5, height: 1.5, color: p.warn),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
