import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/keys.dart';
import '../plugins/registry.dart';
import '../core/store.dart';
import '../core/theme.dart';
import 'canvas_view.dart';
import 'command_palette.dart';
import 'common.dart';
import 'docs_view.dart';
import 'left_panel.dart';
import 'play_view.dart';
import 'rail.dart';
import 'right_panel.dart';
import 'settings_dialog.dart';
import 'status_bar.dart';
import 'title_bar.dart';

/// 插件快捷键数字键池（⌘5 起）；池容量即同时可注册插件数上限。
/// 消费点在 main.dart 根级 bindings——workspace 级 CallbackShortcuts 在
/// 插件视图内不挂载（视图路由早退），插件入口键必须活在根级才能
/// 「进得去也出得来」。
const pluginDigitKeys = [
  LogicalKeyboardKey.digit5,
  LogicalKeyboardKey.digit6,
  LogicalKeyboardKey.digit7,
  LogicalKeyboardKey.digit8,
  LogicalKeyboardKey.digit9,
];

class Workspace extends StatefulWidget {
  const Workspace({super.key});
  @override
  State<Workspace> createState() => _WorkspaceState();
}

class _WorkspaceState extends State<Workspace> {
  final _focus = FocusNode(debugLabel: 'workspace');

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final p = context.palette;
    if (store.view == 'play') return const PlayView();
    // 插件工作台路由（plugin:<id>）：注册表驱动，与设计板块解耦。
    final pluginView = pluginWorkspaceFor(store.view);
    if (pluginView != null) return pluginView;
    return CallbackShortcuts(
      bindings: {
      modKey(LogicalKeyboardKey.keyK): _command,
      modKey(LogicalKeyboardKey.keyS): () => store.saveProject(),
      modKey(LogicalKeyboardKey.keyH, shift: true): () {
        // ⇧⌘H：导出 HTML 原型——标题栏菜单同项标注的快捷键，无项目时忽略。
        if (store.hasProject) store.exportHtml();
      },
      modKey(LogicalKeyboardKey.keyN): _newProject,
      modKey(LogicalKeyboardKey.keyO): () => _openPath(''),
      modKey(LogicalKeyboardKey.keyZ): () => _undoRedo(store, redo: false),
      modKey(LogicalKeyboardKey.keyZ, shift: true): () => _undoRedo(store, redo: true),
      modKey(LogicalKeyboardKey.digit1): () => store.setView('design'),
      modKey(LogicalKeyboardKey.digit2): () => store.setView('docs'),
      modKey(LogicalKeyboardKey.digit3): () => store.setView('source'),
      modKey(LogicalKeyboardKey.digit4): () => store.setView('play'),
      // 插件快捷键 ⌘5/⌘6/…已上移 main.dart 根级 bindings（插件视图内
      // 本 CallbackShortcuts 不挂载，workspace 级绑定在插件视图不可达）。
      modKey(LogicalKeyboardKey.digit0): () {
        store.setView('design');
        store.bumpFit();
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
          body: Column(
            children: [
              TitleBar(
                onCommand: _command,
                onSettings: _settings,
                onNewProject: _newProject,
                onOpenProject: () => _openPath(''),
                onShortcuts: _shortcuts,
                onOpenRecent: (path) => _openPath(path),
              ),
              Expanded(
                child: Row(
                  children: [
                    const Rail(),
                    const LeftPanel(),
                    Expanded(child: _center(store)),
                    const RightPanel(),
                  ],
                ),
              ),
              StatusBar(onCommand: _command),
            ],
          ),
        ),
      ),
    );
  }

  Widget _center(AppStore store) {
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
        child: switch (store.view) {
          'docs' => const DocsView(),
          'source' => const _SourceView(),
          _ => Column(
              children: [
                const _BoardTabs(),
                const Expanded(child: CanvasView()),
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
    await showNonDialog(context: context, builder: (context) => const _ShortcutsDialog());
  }

  Future<void> _newProject() => showNewProjectFlow(context);

  Future<void> _openPath(String path) async {
    await openProjectFlow(context, path);
    if (mounted) _focus.requestFocus();
  }

  /// ⌘Z / ⇧⌘Z 分流：焦点在文本编辑框（MBT 源码编辑 / PRD 编辑器）内时
  /// 执行文本撤销，否则画布撤销。CallbackShortcuts 命中绑定即消费按键
  /// （Shortcuts.handleKeypress 对已启用的 VoidCallbackAction 一律返回
  /// handled）——「守卫不作为等事件穿透」不可行，故在文本场景显式
  /// invoke UndoTextIntent/RedoTextIntent（DefaultTextEditingShortcuts
  /// 同款意图），行为与按键穿透等效。
  void _undoRedo(AppStore store, {required bool redo}) {
    final fctx = FocusManager.instance.primaryFocus?.context;
    if (fctx != null && _inEditable(fctx)) {
      final intent = redo
          ? const RedoTextIntent(SelectionChangedCause.keyboard)
          : const UndoTextIntent(SelectionChangedCause.keyboard);
      final action = Actions.maybeFind<Intent>(fctx, intent: intent);
      if (action != null) {
        Actions.of(fctx).invokeAction(action, intent, fctx);
      }
      return; // 编辑框内即使找不到文本撤销动作，也不回退画布历史
    }
    redo ? store.redo() : store.undo();
  }

  /// 沿焦点祖先找 EditableText——焦点节点不一定挂在 EditableText 本身
  /// （TextField/编辑器都包一层 Focus）。visitAncestorElements 从最近
  /// 祖先向外走（不含自身），自身先单独查。
  bool _inEditable(BuildContext? ctx) {
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
      const group = XTypeGroup(label: 'NoNDesign 项目', extensions: ['ddp']);
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
  while (result == OpenResult.needPassword && attempt < 3 && context.mounted) {
    final pw = await showNonDialog<String>(
      context: context,
      builder: (context) => PasswordDialog(path: target, retry: attempt > 0),
    );
    if (pw == null) return;
    result = await store.openProjectPath(target, password: pw);
    attempt += 1;
  }
}

/// Sheet listing DDPs discovered via /project/list, grouped by source
/// (workspace dir from /health, then ~/Desktop). Returns the picked file path,
/// '__file__' for the native picker, or null when cancelled.
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
                        child: Text('工作区与桌面暂无 .ddp 项目。', style: TextStyle(fontSize: 11, color: p.ink4)),
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
  const _BoardTabs();

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
          IconAction(icon: Icons.code, tooltip: 'MBT 源码 ${modCombo('⌘3')}', size: 26, onTap: () => store.setView('source')),
          IconAction(icon: Icons.play_arrow_outlined, tooltip: '演示模式 ${modCombo('⌘4')}', size: 26, onTap: () => store.setView('play')),
          for (final def in pluginRegistry)
            IconAction(icon: def.icon, tooltip: def.tooltip, size: 26, onTap: () => store.setView('plugin:${def.id}')),
          const SizedBox(width: 4),
          TextButton.icon(
            onPressed: () => store.setView('docs'),
            icon: Icon(Icons.auto_awesome, size: 11, color: p.accent),
            label: const Text('文档', style: TextStyle(fontSize: 11)),
          ),
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
                Text('MBT 源码', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: p.ink2)),
                const SizedBox(width: 6),
                Pill(label: 'canonical · ${lines.length} 行'),
                const Spacer(),
                TextButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: store.mbt));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('已复制全文'), behavior: SnackBarBehavior.floating),
                      );
                    }
                  },
                  icon: const Icon(Icons.copy, size: 12),
                  label: const Text('复制'),
                ),
                TextButton.icon(
                  onPressed: () async {
                    final res = await store.api?.validate(store.mbt);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        behavior: SnackBarBehavior.floating,
                        content: Text(res?['ok'] == true ? '校验通过' : '校验失败：${res?['error'] ?? ''}'),
                      ));
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
                    Text('让 NoN 生成第一版（可选）', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: p.ink)),
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
      '视图': [
        ('设计画布', modCombo('⌘1')), ('设计文档', modCombo('⌘2')), ('MBT 源码', modCombo('⌘3')), ('演示模式', modCombo('⌘4')),
        // 插件入口键（根级 bindings，注册表顺序派生）。
        for (var i = 0; i < pluginRegistry.length && i < pluginDigitKeys.length; i++)
          (pluginRegistry[i].title, modCombo('⌘${5 + i}')),
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
