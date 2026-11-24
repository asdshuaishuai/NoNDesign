import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/keys.dart';
import '../plugins/registry.dart';
import 'portfolio_view.dart';
import '../core/store.dart';
import '../core/theme.dart';
import '../core/toast_service.dart';
import 'canvas_view.dart';
import 'command_palette.dart';
import 'common.dart';
import 'design_prototype_banner.dart';
import 'docs_view.dart';
import 'left_panel.dart';
import 'play_view.dart';
import 'rail.dart';
import 'workspace_inspector.dart';
import 'workspace_chrome.dart';
import 'settings_dialog.dart';
import 'status_bar.dart';
import 'title_bar.dart';

class Workspace extends StatefulWidget {
  /// 嵌入式宿主（聊天流常驻分栏 / 画中画浮窗，docs/plan-chat-stream-shell.md
  /// §2 S4）：跳过 TitleBar/StatusBar 与 play、portfolio、plugin 全屏早退，
  /// 面板断点收紧（左栏 <760 隐藏、右栏 <1100 走 sheet）——分栏本身已有
  /// chat 占宽，再按全屏断点摊三栏会把画布压到不可用宽度。嵌入时窄轨换
  /// [_EmbeddedRail]（只做面板局部导航）且画板条隐藏全局视图入口：宿主内
  /// 任何 setView 都会把聊天流整块换掉，触屏用户回不来（review pip-1）。
  final bool embedded;

  /// 是否渲染 Workspace 自带的 348 右栏（NaN/检查）。
  ///
  /// 桌面壳（批次 12）把右侧唯一窄栏交给 `ChatRail`（聊天/NaN/检查），
  /// 这里必须传 false——否则 348 的 RightPanel 与窄栏会形成双栏，把画布
  /// 压到不可用宽度。独立使用 Workspace（手机经典主面、测试）时保持默认 true。
  final bool showRightPanel;

  const Workspace({super.key, this.embedded = false, this.showRightPanel = true});

  @override
  State<Workspace> createState() => _WorkspaceState();
}

class _WorkspaceState extends State<Workspace> {
  final _focus = FocusNode(debugLabel: 'workspace');

  /// 嵌入宿主登记用的 store 引用：initState 取一次——dispose 时 context
  /// 已不能再做祖先查找，登记/注销必须持有引用做。
  AppStore? _store;

  @override
  void initState() {
    super.initState();
    _store = context.read<AppStore>();
    // 嵌入宿主登记（review pip-1/pip-4）：在场期间 store 的 run/打开项目/
    // 新建项目/建板一律不切 view，聊天宿主不会被整块替换。
    if (widget.embedded) _store!.enterEmbeddedHost();
  }

  @override
  void didUpdateWidget(Workspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.embedded != widget.embedded) {
      if (widget.embedded) {
        _store!.enterEmbeddedHost();
      } else {
        _store!.exitEmbeddedHost();
      }
    }
  }

  @override
  void dispose() {
    if (widget.embedded) _store?.exitEmbeddedHost();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final p = context.palette;
    // 全屏视图早退只在完整壳里生效：嵌入式宿主（聊天流分栏 / 画中画）里
    // store.view 恒为 'chat'，这些分支不适用。portfolio / play 由 main.dart
    // 先路由到全屏 Workspace（embedded=false）。
    // 插件工作台（`plugin:*`）**不再**在这里早退：四个工作台外壳统一（用户
    // 裁决 2026-11-20）——3D / 视频 / 热应用与设计共用同一套 TitleBar / 左侧
    // 图标轨 / 主区 / 状态栏，插件内容只占「设计画布」那块主区（见 _center
    // 与 workspace_chrome.dart）。桌面壳里它仍是左侧固定工作区、右侧 NaN
    // 常驻；手机聊天优先壳里由 ChatPiPShell 的 classic face 整屏渲染。
    if (!widget.embedded) {
      if (store.view == 'play') {
        return Scaffold(backgroundColor: p.bg, body: const SafeArea(child: PlayView()));
      }
      // 作品集：不进设计壳（无项目也可达）。仍包 Scaffold——
      // 视图内的 SnackBar 需要 ScaffoldMessenger 的 Scaffold 祖先
      // （旧实现早退裸视图，debug 断言、release 静默不显示）。
      // SafeArea：移动端状态栏 / Home 指示条不压顶栏与底部操作（真机实证）。
      if (store.view == 'portfolio') {
        return Scaffold(backgroundColor: p.bg, body: const SafeArea(child: PortfolioView()));
      }
    }
    // 插件视图在完整壳里进主区；嵌入宿主不路由插件视图（view 恒为 chat）。
    final pluginView = widget.embedded ? null : pluginWorkspaceFor(store.view);
    return CallbackShortcuts(
      bindings: {
      // ⌘N/⌘O/⌘S/⌘Z/⌘K 已上移 main.dart 根级 bindings：portfolio/play 全幅
      // 视图不挂载本壳，根级绑定是这些视图的唯一来源。插件工作台 2026-11-20
      // 起与设计共用本壳（外壳统一），这些壳内动作对四个工作台同样可达。
      // 保留的项是设计壳内部动作（设置/快捷键/文档直达原型/导出）。
      // ⇧⌘F：自动修复当前画板（规范/叠放/可读性一次清偿）——deepDesign 的
      // 常驻能力，迁移后一度只剩检查器里的两个小按钮，用户找不到入口。
      modKey(LogicalKeyboardKey.keyF, shift: true): () {
        if (store.hasProject) store.autoFix();
      },
      modKey(LogicalKeyboardKey.keyH, shift: true): () {
        // ⇧⌘H：导出 HTML 原型——标题栏菜单同项标注的快捷键，无项目时忽略。
        if (store.hasProject) store.exportHtml();
      },
      modKey(LogicalKeyboardKey.slash): _shortcuts,
      modKey(LogicalKeyboardKey.comma): _settings,
      modKey(LogicalKeyboardKey.enter): () {
        // ⌘↵ / Ctrl+↵：文档视图下若 PRD 就绪，一键生成原型。
        if (store.view == 'docs' &&
            store.docs.prd.trim().isNotEmpty &&
            !store.agentBusy) {
          store.setView('design');
          store.runBuild(
              '请根据 PRD 与 UI 说明生成完整可交互原型。先规划页面连接，再逐屏生成，最后连线并自检。');
        }
      },
    },
    child: Focus(
        focusNode: _focus,
        autofocus: true,
        child: Scaffold(
          backgroundColor: p.bg,
          // 三档断点：手机 <700（左右面板都折叠成底部 sheet）、平板
          // 700–1024（左栏常驻 + 右栏 sheet）、宽屏 ≥1024（三栏全开）。
          // 58 + 252 + 348 固定面板在手机宽度会把画布压到 0；平板竖屏
          // 保留左栏（项目/画板）同时让右栏走 sheet，画布仍有可用宽度。
          // SafeArea：iOS 状态栏 / Home 指示条不压标题栏与状态栏。
          body: SafeArea(
            child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              final phone = width < 700;
              // 插件视图不挂设计左栏（板/图层/文档/历史都是设计面的内容，
              // 插件工作台有自己的 46px 工具条管理项目）；左轨保留，四个
              // 工作台外壳因此一致，插件内容只占「设计画布」那块主区。
              final showLeft =
                  !phone && (!widget.embedded || width >= 760) && pluginView == null;
              final wide = width >= (widget.embedded ? 1100 : 1024);
              // 画中画可被缩到 280 高：Rail 是固定 224 的图标列，放不下时
              // 隐藏（画布优先），否则 RenderFlex 溢出。完整壳永不触发。
              final showRail = !(widget.embedded && constraints.maxHeight < 262);
              // 嵌入宿主内左栏只在「项目/历史」面板安全：docs/spec 面板的
              // 条目会 setView('docs')（left_panel.dart:416-417），点击即把
              // 聊天宿主整块换掉——面板与底部 sheet 入口一并收掉，等用户
              // 从嵌入窄轨切回 设计/历史 再恢复。
              final leftPaneSafe = !widget.embedded ||
                  (store.panel != 'docs' && store.panel != 'spec');
              // 窄屏折叠条：左栏收起时给「项目面板」sheet，右栏收起时给
              // 「NaN 面板」sheet。插件视图没有设计左栏，只保留右栏入口。
              final leftAsSheet = !showLeft && leftPaneSafe && pluginView == null;
              final rightAsSheet = widget.showRightPanel;
              return WorkspaceChrome(
                titleBar: widget.embedded
                    ? null
                    : TitleBar(
                        onCommand: _command,
                        onSettings: _settings,
                        onNewProject: _newProject,
                        onOpenProject: () => _openPath(''),
                        onShortcuts: _shortcuts,
                        onOpenRecent: (path) => _openPath(path),
                      ),
                rail: showRail
                    ? (widget.embedded
                        ? const _EmbeddedRail()
                        : Rail(
                            // 窄屏没有左栏：点「历史」用底部面板给出
                            // 可见结果，而不是只把图标点亮（nav-4）。
                            onHistory: showLeft ? null : () => _openLeftSheet(context),
                          ))
                    : null,
                leftPanel: showLeft && leftPaneSafe ? const LeftPanel() : null,
                main: _center(store, pluginView),
                rightPanel: wide && widget.showRightPanel ? const WorkspaceRightPanel() : null,
                narrowBar: !wide && (leftAsSheet || rightAsSheet)
                    ? _narrowBar(
                        context,
                        leftAsSheet: leftAsSheet,
                        rightAsSheet: rightAsSheet,
                      )
                    : null,
                statusBar: widget.embedded ? null : StatusBar(onCommand: _command),
              );
            },
            ),
          ),
        ),
      ),
    );
  }

  /// 窄屏（无左栏）时把当前面板放进底部面板。
  ///
  /// 左轨「历史」在手机上原本只把 panel 置成 history——左栏根本不渲染，
  /// 用户只看到图标高亮（审查 nav-4）。这里复用窄条「项目面板」的形态。
  void _openLeftSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: context.palette.panel,
      isScrollControlled: true,
      builder: (_) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.6,
          child: const LeftPanel(),
        ),
      ),
    );
  }

  /// 紧凑面板开关：折叠的面板以底部 sheet 打开（高度 60%）。
  /// 手机两端都折叠；平板只折叠右栏（左栏常驻）。
  Widget _narrowBar(BuildContext context, {required bool leftAsSheet, required bool rightAsSheet}) {
    final p = context.palette;
    Widget sheet(Widget child) => SafeArea(
          child: SizedBox(
            height: MediaQuery.of(context).size.height * 0.6,
            child: child,
          ),
        );
    return Container(
      height: 38,
      decoration: BoxDecoration(color: p.bgElevated, border: Border(top: BorderSide(color: p.line))),
      child: Row(children: [
        const Spacer(),
        if (leftAsSheet) ...[
          TextButton.icon(
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              backgroundColor: p.panel,
              isScrollControlled: true,
              builder: (_) => sheet(const LeftPanel()),
            ),
            icon: const Icon(Icons.view_sidebar_outlined, size: 16),
            label: const Text('项目面板', style: TextStyle(fontSize: 12)),
          ),
          const Spacer(),
        ],
        if (rightAsSheet) ...[
          TextButton.icon(
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              backgroundColor: p.panel,
              isScrollControlled: true,
              builder: (_) => sheet(const WorkspaceRightPanel()),
            ),
            icon: const Icon(Icons.auto_awesome, size: 16),
            label: const Text('NaN 面板', style: TextStyle(fontSize: 12)),
          ),
          const Spacer(),
        ],
      ]),
    );
  }

  Widget _center(AppStore store, Widget? pluginView) {
    // 视图切换过渡：fade + 8px 上滑（180ms）。KeyedSubtree 按 view 键控，
    // 同视图内 store 变化不会触发重播。
    return AnimatedSwitcher(
      duration: NonMotion.base,
      switchInCurve: NonMotion.curve,
      switchOutCurve: NonMotion.curve.flipped,
      transitionBuilder: (child, anim) => FadeTransition(
        opacity: anim,
        child: SlideTransition(
          position: Tween(begin: const Offset(0, 0.012), end: Offset.zero).animate(anim),
          child: child,
        ),
      ),
      child: KeyedSubtree(
        key: ValueKey(store.view),
        // 插件工作台就是主区内容：与设计画布共用同一个槽位（外壳由
        // workspace_chrome.dart 统一提供），不再整页替换 Scaffold。
        // 插件自己的 46px 工具条仍在内容顶部——那是模块自身的面，不重复
        // 标题栏/状态栏。
        child: pluginView ??
            switch (store.view) {
              'docs' => const DocsView(),
              'source' => const _SourceView(),
              _ => Column(
                  children: [
                    _BoardTabs(embedded: widget.embedded),
                    const DesignPrototypeBanner(),
                    Expanded(
                      // 嵌入宿主且无画板时不吃 CanvasView 的空态卡：那张卡带
                      // 「先写文档」= setView('docs')（canvas_view.dart:1590），
                      // 在宿主里点一下同样会把聊天流换掉（review pip-1 同类）。
                      // 画板条（＋ 新建）仍在，生成入口走聊天。
                      // 打开的项目没有可用画布（手机离线/预览失败）：不能把
                      // 空画布显示成「还没有画板」的空项目（审查 depython-1）。
                      child: store.canvasPreviewUnavailable
                          ? const _CanvasNeedsDesktopHint()
                          : widget.embedded && store.render.artboards.isEmpty
                              ? const _EmbeddedNoBoardHint()
                              : const CanvasView(),
                    ),
                  ],
                ),
            },
      ),
    );
  }

  Future<void> _command() async {
    await showCommandPalette(
      context,
      onNewProject: _newProject,
      onOpenPath: (path) => _openPath(path),
      onSettings: _settings,
      onShortcuts: _shortcuts,
    );
  }

  Future<void> _settings() async {
    await showSettingsDialog(context);
  }

  Future<void> _shortcuts() async {
    await showShortcutsDialog(context);
  }

  Future<void> _newProject() => showNewProjectFlow(context);

  Future<void> _openPath(String path) async {
    await openProjectFlow(context, path);
    if (mounted) _focus.requestFocus();
  }
}

/// 快捷键说明弹窗（根级 ⌘K 命令面板也要用——从 Workspace 私有方法提为
/// 顶层入口）。
Future<void> showShortcutsDialog(BuildContext context) {
  return showNonDialog(context: context, builder: (context) => const _ShortcutsDialog());
}

/// ⌘Z / ⇧⌘Z 分流（根级绑定）：焦点在文本编辑框（MBT 源码编辑 / PRD
/// 编辑器）内时执行文本撤销，否则画布撤销。CallbackShortcuts 命中绑定即
/// 消费按键（Shortcuts.handleKeypress 对已启用的 VoidCallbackAction 一律
/// 返回 handled）——「守卫不作为等事件穿透」不可行，故在文本场景显式
/// invoke UndoTextIntent/RedoTextIntent（DefaultTextEditingShortcuts 同款
/// 意图），行为与按键穿透等效。
void undoRedoShortcut(AppStore store, {required bool redo}) {
  final fctx = FocusManager.instance.primaryFocus?.context;
  if (_focusInEditable(fctx)) {
    final intent = redo
        ? const RedoTextIntent(SelectionChangedCause.keyboard)
        : const UndoTextIntent(SelectionChangedCause.keyboard);
    final action = Actions.maybeFind<Intent>(fctx!, intent: intent);
    if (action != null) {
      Actions.of(fctx).invokeAction(action, intent, fctx);
    }
    return; // 编辑框内即使找不到文本撤销动作，也不回退画布历史
  }
  redo ? store.redo() : store.undo();
}

/// 沿焦点祖先找 EditableText——焦点节点不一定挂在 EditableText 本身
/// （TextField/编辑器都包一层 Focus）。visitAncestorElements 从最近祖先
/// 向外走（不含自身），自身先单独查。
bool _focusInEditable(BuildContext? ctx) {
  if (ctx == null) return false;
  if (ctx is Element && ctx.widget is EditableText) return true;
  var found = false;
  ctx.visitAncestorElements((Element e) {
    if (e.widget is EditableText) {
      found = true;
      return false;
    }
    return true;
  });
  return found;
}

Future<void> showNewProjectFlow(BuildContext context) async {
  final result = await showNonDialog<NewProjectResult>(
    context: context,
    builder: (context) => const NewProjectDialog(),
  );
  if (result == null || !context.mounted) return;
  final store = context.read<AppStore>();
  final ok = await store.newProject(
    name: result.name,
    device: result.device,
    templateId: result.templateId,
  );
  if (ok && result.brief.trim().isNotEmpty && context.mounted) {
    final planned = await store.runPlan(result.brief.trim());
    if (planned) {
      await store.runBuild('请根据 PRD 与 UI 说明生成完整可交互原型。\n\nBRIEF:\n${result.brief.trim()}');
    }
  }
}

Future<void> openProjectFlow(BuildContext context, String path) async {
  final store = context.read<AppStore>();
  var target = path;
  if (target.isEmpty) {
    // Empty path = entry from the project menu「打开 DDP…」/ ⌘O / Welcome links:
    // offer the server-discovered projects (workspace + Desktop) first, with a
    // native file picker as the escape hatch.
    final picked = await showOpenProjectSheet(context);
    if (picked == null || !context.mounted) return;
    if (picked == '__file__') {
      const group = XTypeGroup(label: 'NaN 项目', extensions: ['ddp']);
      final file = await openFile(acceptedTypeGroups: const [group]);
      if (file == null) return;
      target = file.path;
    } else {
      target = picked;
    }
  }
  if (!context.mounted) return;
  var result = await store.openProjectPath(target);
  var attempt = 0;
  while (result == OpenResult.needPassword && attempt < 3) {
    if (!context.mounted) return;
    final pw = await showNonDialog<String>(
      context: context,
      builder: (context) => PasswordDialog(path: target, retry: attempt > 0),
    );
    if (pw == null) return;
    result = await store.openProjectPath(target, password: pw);
    attempt += 1;
  }
}

/// Sheet listing DDPs discovered through the connected desktop, grouped by
/// source (workspace dir from its health face, then ~/Desktop). Returns the
/// picked file path, '__file__' for the native picker, or null when cancelled.
Future<String?> showOpenProjectSheet(BuildContext context) async {
  context.read<AppStore>().refreshProjects();
  if (!context.mounted) return null;
  return showNonDialog<String>(
    context: context,
    builder: (context) => const _OpenProjectDialog(),
  );
}

class _OpenProjectDialog extends StatelessWidget {
  const _OpenProjectDialog();

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final p = context.palette;
    final workspace = store.serverProjects.where((s) => s['source'] != 'desktop').toList();
    final desktop = store.serverProjects.where((s) => s['source'] == 'desktop').toList();
    final empty = workspace.isEmpty && desktop.isEmpty;
    return AlertDialog(
      backgroundColor: p.panel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: p.lineStrong)),
      title: const Text('打开项目', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (empty && store.refreshingProjects)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 22),
                        child: Row(
                          children: [
                            SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 1.6, color: p.accent)),
                            const SizedBox(width: 9),
                            Text('正在扫描工作区与桌面…', style: TextStyle(fontSize: 12, color: p.ink3)),
                          ],
                        ),
                      )
                    else if (empty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 18),
                        child: Text('工作区与桌面还没有项目。', style: TextStyle(fontSize: 11, color: p.ink4)),
                      )
                    else ...[
                      _projectSection(context, '工作区', workspace),
                      _projectSection(context, '桌面', desktop),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => Navigator.pop(context, '__file__'),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 9),
                decoration: BoxDecoration(
                  color: p.panel2.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: p.line),
                ),
                child: Row(
                  children: [
                    Icon(Icons.folder_open_outlined, size: 15, color: p.ink4),
                    const SizedBox(width: 8),
                    Expanded(child: Text('从文件选择…', style: TextStyle(fontSize: 12, color: p.ink2))),
                    Icon(Icons.chevron_right, size: 13, color: p.ink4),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消'))],
    );
  }

  Widget _projectSection(BuildContext context, String label, List<Map<String, dynamic>> items) {
    if (items.isEmpty) return const SizedBox.shrink();
    final p = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 3),
          child: Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1.1, color: p.ink4)),
        ),
        for (final s in items)
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => Navigator.pop(context, s['path']?.toString() ?? ''),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
              child: Row(
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(color: p.panel2, borderRadius: BorderRadius.circular(8)),
                    child: Icon(Icons.layers_outlined, size: 14, color: p.ink4),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          s['name']?.toString() ?? '',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: p.ink2),
                        ),
                        Text(
                          relativeTime(s['modified'] is num ? (s['modified'] as num).toInt() * 1000 : null),
                          style: TextStyle(fontSize: 10, color: p.ink4),
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right, size: 14, color: p.ink4),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _BoardTabs extends StatelessWidget {
  /// 嵌入宿主（聊天分栏 / 画中画）：隐藏一切全局视图入口（源码/演示/
  /// 作品集/插件/文档）——它们都是 setView(...)，在宿主里点一下就把聊天流
  /// 整块换掉，触屏用户没有回聊天流的入口。画板切换与新建仍保留。
  final bool embedded;

  const _BoardTabs({this.embedded = false});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final p = context.palette;
    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: p.bgElevated.withValues(alpha: 0.7),
        border: Border(bottom: BorderSide(color: p.line)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final b in store.render.artboards)
                    Padding(
                      padding: const EdgeInsets.only(right: 2),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () => store.selectBoard(b.id),
                        child: Container(
                          height: 28,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          decoration: BoxDecoration(
                            color: store.activeBoard == b.id ? p.panel2 : Colors.transparent,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.crop_square,
                                  size: 11, color: store.activeBoard == b.id ? p.accent : p.ink4),
                              const SizedBox(width: 4),
                              ConstrainedBox(
                                constraints: const BoxConstraints(maxWidth: 140),
                                child: Text(
                                  b.name.isEmpty ? b.id : b.name,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                    color: store.activeBoard == b.id ? p.ink : p.ink3,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 4),
                              Text('${b.nodes.length}',
                                  style: TextStyle(fontSize: 10, fontFamily: 'Menlo', color: p.ink4)),
                            ],
                          ),
                        ),
                      ),
                    ),
                  BoardTemplateMenu(
                    store: store,
                    child: SizedBox(width: 28, height: 28, child: Icon(Icons.add, size: 16, color: p.ink3)),
                  ),
                ],
              ),
            ),
          ),
          if (!embedded) ...[
            IconAction(icon: Icons.code, tooltip: '源码 ${modCombo('⌘3')}', size: 26, onTap: () => store.setView('source')),
            IconAction(
              key: const ValueKey('design-auto-fix'),
              icon: Icons.auto_fix_high_outlined,
              tooltip: '自动修复当前画板 ${modCombo('⇧⌘F')}',
              size: 26,
              onTap: () => store.autoFix(),
            ),
            // 设计模块的项目内验证原型（不调模型；写进当前 .ddp）。
            IconAction(
              key: const ValueKey('design-verify-prototype'),
              icon: Icons.fact_check_outlined,
              tooltip: '验证原型',
              size: 26,
              onTap: store.designPrototypeBusy
                  ? null
                  : () => store.verifyDesignPrototype(),
            ),
            IconAction(icon: Icons.play_arrow_outlined, tooltip: '演示模式 ${modCombo('⌘4')}', size: 26, onTap: () => store.setView('play')),
            IconAction(icon: Icons.collections_bookmark_outlined, tooltip: '作品集', size: 26, onTap: () => store.setView('portfolio')),
            // 架构裁决：设计只与热应用相关（设计可生成热应用）；
            // 3D / 视频是独立模块，入口在主页工作台，不挂在设计工具条上。
            for (final def in pluginRegistry.where((d) => d.id == 'hotapp'))
              IconAction(icon: def.icon, tooltip: def.tooltip, size: 26, onTap: () => store.setView('plugin:${def.id}')),
            // 「由原型生成热应用」只有一个入口，放在热应用工作台顶栏（带进度与
            // 结果反馈）。设计工具条这里只保留进入热应用工作台的按钮，避免出现
            // 三个看起来一样、点了没动静的生成入口。
            const SizedBox(width: 4),
            TextButton.icon(
              onPressed: () => store.setView('docs'),
              icon: Icon(Icons.auto_awesome, size: 11, color: p.accent),
              label: const Text('文档', style: TextStyle(fontSize: 11)),
            ),
          ],
        ],
      ),
    );
  }
}

/// 嵌入宿主的空画布占位：只提示，不带任何全局视图入口（空态卡的
/// 「先写文档」是 setView('docs')，见 _center 的注释）。
class _EmbeddedNoBoardHint extends StatelessWidget {
  const _EmbeddedNoBoardHint();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.dashboard_customize_outlined, size: 24, color: p.ink4),
            const SizedBox(height: 8),
            Text(
              '还没有画板——让 NaN 生成，或点画板条 ＋ 新建。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, height: 1.5, color: p.ink4),
            ),
          ],
        ),
      ),
    );
  }
}

/// 项目已打开、但本机没有可用的画布运行时（手机离线 / 预览失败）。
///
/// 空画布不代表空项目：这里必须说清「内容都在，画布要连桌面」，
/// 而不是渲染 CanvasView 的「还没有画板」空态（审查 depython-1）。
class _CanvasNeedsDesktopHint extends StatelessWidget {
  const _CanvasNeedsDesktopHint();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.desktop_windows_outlined, size: 24, color: p.ink4),
            const SizedBox(height: 8),
            Text(
              '项目已打开，画布需要连接桌面后才能预览',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, height: 1.5, color: p.ink),
            ),
            const SizedBox(height: 6),
            Text(
              '文档与项目内容都已就绪，连接桌面后即可继续查看和编辑画布。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, height: 1.5, color: p.ink4),
            ),
          ],
        ),
      ),
    );
  }
}

/// 嵌入宿主的窄轨（聊天流分栏 / 画中画）：**只做面板局部导航**（设计 /
/// 历史），绝不切 store.view——Rail 的「文档/规范」走 setPanel→setView('docs')，
/// 在设计壳里正确，在聊天宿主里点一下就把宿主整块换成全屏视图，触屏用户
/// 从此没有回聊天流的入口（无键盘 Esc / Welcome 的聊天门只在无项目时可路由）。
/// 文档/规范是全屏面：要它们在完整设计壳里走 ⌘2 / 桌面端 ⌘1 进入设计壳。
class _EmbeddedRail extends StatelessWidget {
  const _EmbeddedRail();

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final p = context.palette;
    final items = [
      ('project', Icons.dashboard_customize_outlined, '设计'),
      ('history', Icons.history, '历史'),
    ];
    return Container(
      key: const ValueKey('workspace-embedded-rail'),
      width: 58,
      decoration: BoxDecoration(
        color: p.bgElevated,
        border: Border(right: BorderSide(color: p.line)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      child: Column(
        children: [
          for (final item in items)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Material(
                color: store.panel == item.$1 ? p.accentSoft : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
                child: InkWell(
                  key: ValueKey('embedded-rail-${item.$1}'),
                  borderRadius: BorderRadius.circular(10),
                  // setPanel('project'|'history') 只改面板不动 view（store.dart
                  // 的 setPanel：只有 docs/spec 才会连带 setView('docs')）。
                  onTap: () => store.setPanel(item.$1),
                  child: SizedBox(
                    width: 42,
                    height: 46,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(item.$2, size: 17, color: store.panel == item.$1 ? p.accent : p.ink3),
                        const SizedBox(height: 4),
                        Text(item.$3,
                            style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w500,
                                color: store.panel == item.$1 ? p.accent : p.ink3)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          const Spacer(),
        ],
      ),
    );
  }
}

/// MBT 源码视图：展示 + 可编辑（deepDesign 对齐——源码模式支持整篇
/// 编辑后「应用并渲染」，走引擎 render 面，比 op 路径更严）。
class _SourceView extends StatefulWidget {
  const _SourceView();

  @override
  State<_SourceView> createState() => _SourceViewState();
}

class _SourceViewState extends State<_SourceView> {
  bool _editing = false;
  bool _applying = false;
  final _editController = TextEditingController();

  @override
  void dispose() {
    _editController.dispose();
    super.dispose();
  }

  Future<void> _apply() async {
    if (_applying) return;
    setState(() => _applying = true);
    final ok = await context.read<AppStore>().applySource(_editController.text);
    if (!mounted) return;
    setState(() {
      _applying = false;
      if (ok) _editing = false; // 成功后 mbt 已是 canonical，回展示态
    });
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final p = context.palette;
    final lines = store.mbt.split('\n');
    return Container(
      color: p.bg,
      child: Column(
        children: [
          Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: p.line))),
            child: Row(
              children: [
                TextButton.icon(
                  onPressed: () => store.setView('design'),
                  icon: const Icon(Icons.chevron_left, size: 14),
                  label: const Text('画布'),
                ),
                Text('源码', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: p.ink2)),
                const SizedBox(width: 6),
                Pill(label: '当前版本 · ${lines.length} 行'),
                const Spacer(),
                TextButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: store.mbt));
                    ToastService.instance.success('已复制全文');
                  },
                  icon: const Icon(Icons.copy, size: 12),
                  label: const Text('复制'),
                ),
                TextButton.icon(
                  onPressed: () async {
                    final res = await store.api?.validate(store.mbt);
                    if (res == null) {
                      ToastService.instance.warn('还没连接设计服务', '连上后再试一次校验');
                      return;
                    }
                    if (res['ok'] == true) {
                      ToastService.instance.success('校验通过');
                    } else {
                      // 原始错误码只进日志面（折叠的技术详情），不上通知。
                      ToastService.instance.error('这次改动没有通过校验', '可以查看源码里的提示后重试');
                    }
                  },
                  icon: const Icon(Icons.verified_outlined, size: 12),
                  label: const Text('校验'),
                ),
                if (!_editing)
                  TextButton.icon(
                    onPressed: () {
                      _editController.text = store.mbt;
                      setState(() => _editing = true);
                    },
                    icon: const Icon(Icons.edit_outlined, size: 12),
                    label: const Text('编辑'),
                  )
                else ...[
                  TextButton.icon(
                    onPressed: _applying ? null : () => setState(() => _editing = false),
                    icon: const Icon(Icons.close, size: 12),
                    label: const Text('取消'),
                  ),
                  const SizedBox(width: 4),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: p.accent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    ),
                    onPressed: _applying ? null : _apply,
                    icon: _applying
                        ? SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.4, color: Colors.white))
                        : const Icon(Icons.flash_on, size: 12),
                    label: const Text('应用并渲染'),
                  ),
                ],
              ],
            ),
          ),
          Expanded(
            child: _editing
                ? Padding(
                    padding: const EdgeInsets.all(14),
                    child: TextField(
                      controller: _editController,
                      maxLines: null,
                      expands: true,
                      textAlignVertical: TextAlignVertical.top,
                      style: TextStyle(fontSize: 11, height: 1.7, fontFamily: 'Menlo', color: p.ink),
                      decoration: InputDecoration(
                        filled: true,
                        fillColor: p.bgElevated,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: p.line)),
                        contentPadding: const EdgeInsets.all(12),
                      ),
                    ),
                  )
                : SingleChildScrollView(
                    padding: const EdgeInsets.all(14),
                    child: SelectableText(
                      lines.asMap().entries.map((e) => '${(e.key + 1).toString().padLeft(4)}  ${e.value}').join('\n'),
                      style: TextStyle(fontSize: 11, height: 1.7, fontFamily: 'Menlo', color: p.ink2),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class PasswordDialog extends StatefulWidget {
  final String path;
  final bool retry;
  const PasswordDialog({super.key, required this.path, required this.retry});

  @override
  State<PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<PasswordDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final name = widget.path.split(RegExp(r'[\\/]')).last;
    return AlertDialog(
      backgroundColor: p.panel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: p.lineStrong)),
      title: const Text('打开受保护的项目', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(name, style: TextStyle(fontSize: 11, fontFamily: 'Menlo', color: p.ink4)),
            const SizedBox(height: 10),
            TextField(
              controller: _controller,
              autofocus: true,
              obscureText: true,
              decoration: InputDecoration(hintText: '项目口令', errorText: widget.retry ? '口令不正确，或文件已损坏' : null),
              onSubmitted: (v) => Navigator.pop(context, v),
            ),
            const SizedBox(height: 8),
            Text('口令只在本机内存中使用。', style: TextStyle(fontSize: 10, color: p.ink4)),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(context, _controller.text), child: const Text('解锁')),
      ],
    );
  }
}

class NewProjectResult {
  final String name;
  final String device;
  final String? templateId;
  final String brief;
  NewProjectResult(this.name, this.device, this.templateId, this.brief);
}

class NewProjectDialog extends StatefulWidget {
  const NewProjectDialog({super.key});
  @override
  State<NewProjectDialog> createState() => _NewProjectDialogState();
}

class _NewProjectDialogState extends State<NewProjectDialog> {
  final _name = TextEditingController(text: 'untitled');
  final _brief = TextEditingController();
  String _device = 'mobile';
  String? _template;

  @override
  void dispose() {
    _name.dispose();
    _brief.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final p = context.palette;
    return AlertDialog(
      backgroundColor: p.panel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: p.lineStrong)),
      title: const Text('新建项目', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('项目名', style: TextStyle(fontSize: 11, color: p.ink3)),
            const SizedBox(height: 4),
            TextField(controller: _name, decoration: const InputDecoration(hintText: '例如：invoice-studio')),
            const SizedBox(height: 12),
            Text('设备', style: TextStyle(fontSize: 11, color: p.ink3)),
            const SizedBox(height: 4),
            Row(
              children: [
                for (final item in [('mobile', '手机 390×844'), ('web', '网页 1280×800'), ('desktop', '桌面 1440×900')])
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text(item.$2, style: const TextStyle(fontSize: 11)),
                      selected: _device == item.$1,
                      onSelected: (_) => setState(() => _device = item.$1),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text('起始画板', style: TextStyle(fontSize: 11, color: p.ink3)),
            const SizedBox(height: 4),
            // nonSelect 统一下拉（M3 DropdownMenu，32px 菜单行 + panel2 配色）。
            // 空白画板条目 value=null：DropdownMenu initialSelection 按
            // entry.value == null 匹配到首条，选中态显示与旧 DropdownButton 一致；
            // onSelected(null) 原样透传，onChanged 语义不变。
            SizedBox(
              width: double.infinity,
              child: nonSelect<String?>(
                context,
                value: _template,
                items: [
                  const DropdownMenuItem<String?>(value: null, child: Text('空白画板', style: TextStyle(fontSize: 11))),
                  for (final t in store.templates.whereType<Map>())
                    DropdownMenuItem<String?>(
                      value: t['id']?.toString(),
                      child: Text('${t['name'] ?? t['id']} · ${t['id']}', style: const TextStyle(fontSize: 11)),
                    ),
                ],
                onChanged: (v) => setState(() => _template = v),
              ),
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: p.accentSoft.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: p.accent.withValues(alpha: 0.2)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(Icons.auto_awesome, size: 12, color: p.accent),
                    const SizedBox(width: 5),
                    Text('让 NaN 生成第一版（可选）', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: p.ink)),
                  ]),
                  const SizedBox(height: 6),
                  TextField(
                    controller: _brief,
                    minLines: 2,
                    maxLines: 4,
                    style: const TextStyle(fontSize: 12),
                    decoration: const InputDecoration(hintText: '描述产品目标与页面范围；留空则只创建项目。'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            NewProjectResult(
              _name.text.trim().isEmpty ? 'untitled' : _name.text.trim(),
              _device,
              _template,
              _brief.text.trim(),
            ),
          ),
          child: Text(_brief.text.trim().isEmpty ? '创建项目' : '创建并生成'),
        ),
      ],
    );
  }
}

class _ShortcutsDialog extends StatelessWidget {
  const _ShortcutsDialog();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final groups = {
      '全局': [
        ('命令面板', modCombo('⌘K')), ('设置', modCombo('⌘,')), ('保存', modCombo('⌘S')),
        ('新建 / 打开', modCombo('⌘N / ⌘O')), ('导出 HTML', modCombo('⇧⌘H')),
      ],
      '画布': [('撤销 / 重做', modCombo('⌘Z / ⇧⌘Z')), ('适配窗口', modCombo('⌘0')), ('缩放', modCombo('⌘滚轮')), ('平移', 'space + 拖动')],
      // 没有插件工作台的数字键（用户裁决 2026-11-19）：工作台类型跟着项目走，
      // 切换进顶栏项目菜单；设计面自己的四个视图仍保留 ⌘1–⌘4。
      '视图': [
        ('设计画布', modCombo('⌘1')), ('设计文档', modCombo('⌘2')), ('源码', modCombo('⌘3')), ('演示模式', modCombo('⌘4')),
      ],
      'Agent': [('发送', modCombo('⌘↵')), ('停止', '运行胶囊停止')],
    };
    return AlertDialog(
      backgroundColor: p.panel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: p.lineStrong)),
      title: const Text('快捷键与命令', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
      content: SizedBox(
        width: 560,
        child: Wrap(
          spacing: 32,
          runSpacing: 18,
          children: [
            for (final group in groups.entries)
              SizedBox(
                width: 230,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(group.key, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1, color: p.ink4)),
                    const SizedBox(height: 6),
                    for (final row in group.value)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 5),
                        child: Row(
                          children: [
                            Expanded(child: Text(row.$1, style: TextStyle(fontSize: 11, color: p.ink3))),
                            Text(row.$2, style: TextStyle(fontSize: 10, fontFamily: 'Menlo', color: p.ink4)),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('关闭'))],
    );
  }
}
