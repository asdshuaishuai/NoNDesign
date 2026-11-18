import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:provider/provider.dart';

import '../core/dart_agent.dart' show toolLabel;
import '../core/models.dart';
import '../core/store.dart';
import '../core/theme.dart';
import 'a2ui_card.dart';
import 'common.dart';
import 'settings_dialog.dart';
import 'workspace.dart' show openProjectFlow, showNewProjectFlow;

/// 聊天流主面（docs/plan-chat-stream-shell.md §2 S1）。
///
/// 卡片类型：用户消息 / 进度卡（步骤+工具调用，复用时间线条目的分类经验）/
/// A2UI 交互卡（嵌 [A2uiCard] 静态路径——surface 消息随卡片持久化，恢复后
/// 照常渲染；动作经 onAction 回流 store.handleChatAction 续跑）/ 产物卡
/// （原型→工作区；热应用/视频/3D→对应工作台）。
///
/// 顶栏「工作区」由宿主注入动作（[onOpenWorkspace]）：手机/竖屏平板开画中画
/// 浮窗（承载壳见 widgets/chat_pip_shell.dart）；桌面壳的右侧窄栏用
/// [railMode] 隐藏该入口（工作区就是主面）。无宿主时回退原全屏路径。
/// 会话记录由 store 随 chat.json 落盘、重启恢复。
class ChatStreamView extends StatefulWidget {
  /// 设置入口回调；缺省用本视图 context 弹设置（视图在 Navigator 子树内）。
  final VoidCallback? onSettings;

  /// 顶栏「工作区」动作（宿主注入：桌面分栏折叠切换 / 移动开画中画）。
  /// 缺省回退 [AppStore.openWorkspace]——无宿主时仍是原全屏路径。
  final VoidCallback? onOpenWorkspace;

  /// 「确保工作区可见」动作（产物卡点开用）：与顶栏的折叠**切换**不同，
  /// 这里只展开不收起。宿主注入后产物卡不再 setView('design') 拆掉宿主
  /// （review pip-2）；缺省回退 [onOpenWorkspace]，再缺省走全屏路径。
  final VoidCallback? onRevealWorkspace;

  /// 右侧窄栏形态：更窄的顶栏（只有标题/主题/设置），没有「工作区」入口。
  final bool railMode;

  const ChatStreamView({
    super.key,
    this.onSettings,
    this.onOpenWorkspace,
    this.onRevealWorkspace,
    this.railMode = false,
  });

  @override
  State<ChatStreamView> createState() => _ChatStreamViewState();
}

class _ChatStreamViewState extends State<ChatStreamView> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  int _lastCount = -1;

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _send(AppStore store) {
    final text = _input.text.trim();
    if (text.isEmpty || store.agentBusy) return;
    _input.clear();
    store.sendChat(text);
  }

  void _scheduleScrollToBottom(int count) {
    if (count == _lastCount) return;
    _lastCount = count;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  void _openArtifact(AppStore store, ChatMessage m) {
    switch (m.artifactKind) {
      case artifactPrototype:
        // 有宿主时只展开/打开工作区面板（review pip-2：不能 setView('design')
        // 把聊天宿主整块拆掉）；无宿主保留原「先建后用 + 全屏设计视图」。
        final reveal = widget.onRevealWorkspace ?? widget.onOpenWorkspace;
        if (reveal != null) {
          reveal();
        } else {
          store.openWorkspace();
        }
      case artifactHotapp:
        final name = (m.artifactName ?? '').trim();
        if (name.isNotEmpty) store.setHotApp(name);
        store.setView('plugin:hotapp');
      case artifactVideo:
        store.setView('plugin:video');
      case artifactThree:
        store.setView('plugin:three');
      default:
        store.setView('portfolio');
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final p = context.palette;
    final messages = store.chatMessages;
    _scheduleScrollToBottom(messages.length);
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(
          children: [
            _topBar(context, store, p),
            Expanded(
              child: messages.isEmpty
                  ? _emptyState(context, p)
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(18, 10, 18, 10),
                      itemCount: messages.length,
                      itemBuilder: (context, i) =>
                          _buildCard(context, store, messages[i], i),
                    ),
            ),
            _composer(context, store, p),
          ],
        ),
      ),
    );
  }

  Widget _topBar(BuildContext context, AppStore store, NonPalette p) {
    return Container(
      height: widget.railMode ? 48 : 60,
      padding: EdgeInsets.symmetric(horizontal: widget.railMode ? 12 : 20),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: p.line))),
      child: Row(
        children: [
          NonLogo(size: widget.railMode ? 22 : 26),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('NoNDesign',
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: p.ink)),
                if (!widget.railMode)
                  // 项目入口：项目名 + 未保存点 + 保存/另存/打开/新建。
                  // 聊天优先壳没有桌面 TitleBar/StatusBar，这里是手机上
                  // 唯一常驻的项目面（docs/design-system.md 可见入口纪律）。
                  const ChatProjectMenu(),
              ],
            ),
          ),
          if (!widget.railMode) ...[
            const SizedBox(width: 6),
            // 「工作区」入口：宿主在时交给宿主（手机/竖屏平板开画中画），
            // 无宿主时回退原全屏路径（无项目先建空项目——store.openWorkspace）。
            OutlinedButton.icon(
              key: const ValueKey('chat-open-workspace'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              ),
              onPressed: widget.onOpenWorkspace ?? store.openWorkspace,
              icon: Icon(Icons.space_dashboard_outlined, size: 14, color: p.ink2),
              label: Text('工作区', style: TextStyle(fontSize: 11, color: p.ink2)),
            ),
          ],
          const SizedBox(width: 4),
          IconAction(
            icon: store.settings.theme == 'light' ? Icons.dark_mode_outlined : Icons.light_mode_outlined,
            tooltip: '切换主题',
            onTap: () async {
              store.settings.theme = store.settings.theme == 'light' ? 'dark' : 'light';
              await store.saveSettings();
            },
          ),
          IconAction(
            icon: Icons.settings_outlined,
            tooltip: '设置',
            onTap: widget.onSettings ?? () => showSettingsDialog(context),
          ),
        ],
      ),
    );
  }

  Widget _emptyState(BuildContext context, NonPalette p) {
    final examples = ['做一个记账小应用，移动端优先', '给咖啡馆做一个点单原型', '设计一个团队周报工具'];
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.auto_awesome, size: 30, color: p.accent),
          const SizedBox(height: 12),
          Text('从一句话开始',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: p.ink, letterSpacing: -0.3)),
          const SizedBox(height: 8),
          Text('描述要解决的问题与受众——NaN 先写设计文档，再生成可交互原型。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, height: 1.6, color: p.ink3)),
          const SizedBox(height: 16),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            alignment: WrapAlignment.center,
            children: [
              for (final e in examples)
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => _input.text = e,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                    decoration: BoxDecoration(
                      color: p.panel2,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: p.line),
                    ),
                    child: Text(e, style: TextStyle(fontSize: 11, color: p.ink2)),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCard(BuildContext context, AppStore store, ChatMessage m, int index) {
    switch (m.kind) {
      case chatKindUser:
        return _userBubble(m, context.palette);
      case chatKindAssistant:
        return _assistantCard(m, context.palette);
      case chatKindProgress:
        return _progressCard(m, context.palette);
      case chatKindA2ui:
        return _a2uiCard(store, m, index, context.palette);
      case chatKindArtifact:
        return _artifactCard(store, m, context.palette);
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _userBubble(ChatMessage m, NonPalette p) {
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.only(left: 64, bottom: 10),
        padding: const EdgeInsets.all(10),
        constraints: const BoxConstraints(maxWidth: 560),
        decoration: BoxDecoration(
          color: p.accentSoft,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(12),
            topRight: Radius.circular(4),
            bottomLeft: Radius.circular(12),
            bottomRight: Radius.circular(12),
          ),
          border: Border.all(color: p.accent.withValues(alpha: 0.3)),
        ),
        child: Text(m.text,
            style: TextStyle(fontSize: 12.5, height: 1.55, color: p.ink)),
      ),
    );
  }

  Widget _assistantCard(ChatMessage m, NonPalette p) {
    return Container(
      margin: const EdgeInsets.only(right: 64, bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: MarkdownBody(
        data: m.text,
        softLineBreak: true,
        styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
          p: TextStyle(fontSize: 12.5, height: 1.6, color: p.ink2),
          h1: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: p.ink),
          h2: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: p.ink),
          code: TextStyle(fontSize: 11, fontFamily: 'Menlo', color: p.ink2, backgroundColor: p.panel2),
        ),
      ),
    );
  }

  Widget _progressCard(ChatMessage m, NonPalette p) {
    return Container(
      margin: const EdgeInsets.only(right: 40, bottom: 10),
      padding: const EdgeInsets.all(11),
      constraints: const BoxConstraints(maxWidth: 620),
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: m.running ? p.accent.withValues(alpha: 0.35) : p.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.auto_awesome, size: 13, color: p.accent),
              const SizedBox(width: 7),
              Expanded(
                child: Text(m.text,
                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: p.ink)),
              ),
              if (m.running)
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2, color: p.accent),
                )
              else
                Icon(
                  m.ok ? Icons.check_rounded : Icons.close_rounded,
                  size: 15,
                  color: m.ok ? p.success : p.danger,
                ),
            ],
          ),
          for (final s in m.steps)
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Row(
                children: [
                  Icon(
                    s.running
                        ? Icons.hourglass_top_rounded
                        : s.ok
                            ? Icons.check_rounded
                            : Icons.close_rounded,
                    size: 12,
                    color: s.running ? p.accent : s.ok ? p.success : p.danger,
                  ),
                  const SizedBox(width: 6),
                  Text(_stepLabel(s.label),
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: p.ink2)),
                  if (s.detail != null && s.detail!.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(s.detail!,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 10, fontFamily: 'Menlo', color: p.ink4)),
                    ),
                  ],
                  if (s.ms != null)
                    Text('${s.ms}ms',
                        style: TextStyle(fontSize: 10, fontFamily: 'Menlo', color: p.ink4)),
                ],
              ),
            ),
          if (!m.running && !m.ok && m.detail != null && m.detail!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(m.detail!,
                  style: TextStyle(fontSize: 11, height: 1.5, color: p.danger)),
            ),
        ],
      ),
    );
  }

  /// A2UI 交互卡：surface 消息随 ChatMessage 持久化，静态路径渲染（恢复后
  /// 照常可用）。a2ui 包类型不出封装边界——action 经推断型 lambda 适配后
  /// 交给 store.handleChatAction 回流续跑。
  Widget _a2uiCard(AppStore store, ChatMessage m, int index, NonPalette p) {
    final messages = m.a2uiMessages ?? const [];
    return Container(
      margin: const EdgeInsets.only(right: 40, bottom: 10),
      child: A2uiCard.messages(
        key: ValueKey('chat-a2ui-$index'),
        messages: messages,
        onAction: (action) {
          // action.context 已是 Map<String, dynamic>（a2ui_core 契约）。
          store.handleChatAction(action.name, action.context);
        },
        onError: (_) {},
      ),
    );
  }

  Widget _artifactCard(AppStore store, ChatMessage m, NonPalette p) {
    final (icon, label) = switch (m.artifactKind) {
      artifactPrototype => (Icons.design_services_outlined, '原型'),
      artifactHotapp => (Icons.auto_fix_high_outlined, '热应用'),
      artifactVideo => (Icons.movie_outlined, '视频'),
      artifactThree => (Icons.view_in_ar_outlined, '3D'),
      _ => (Icons.collections_bookmark_outlined, '作品'),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _openArtifact(store, m),
        child: Container(
          padding: const EdgeInsets.all(12),
          constraints: const BoxConstraints(maxWidth: 620),
          decoration: BoxDecoration(
            color: p.panel.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: p.lineStrong),
          ),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: p.accentSoft,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(icon, size: 18, color: p.accent),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: p.accent.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(label,
                              style: TextStyle(fontSize: 10, color: p.accent)),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(m.artifactName ?? '',
                              maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: p.ink)),
                        ),
                      ],
                    ),
                    if (m.text.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(m.text,
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 10, color: p.ink4)),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right, size: 16, color: p.ink4),
            ],
          ),
        ),
      ),
    );
  }

  /// 进度步骤里的工具调用一律经 [toolLabel]（术语表：design_op → 设计变更，
  /// inspect → 检查）；中文步骤（「撰写产品文档」「NaN 开始」「生成画板 home」）
  /// 原样保留。
  ///
  /// 判定不按「是否含下划线」——inspect / finish 这类工具没有下划线，曾以
  /// 英文代号原样上屏。这里以 [toolLabel] 的未知哨兵反查：返回
  /// 「智能体操作」说明原文不是已知工具名（是人话步骤或未知工具），原文
  /// 保留；已知工具一律用术语表译文。
  String _stepLabel(String raw) {
    final label = toolLabel(raw);
    return label == '智能体操作' ? raw : label;
  }

  Widget _composer(BuildContext context, AppStore store, NonPalette p) {
    final busy = store.agentBusy;
    return Container(
      decoration: BoxDecoration(border: Border(top: BorderSide(color: p.line))),
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              key: const ValueKey('chat-input'),
              controller: _input,
              minLines: 1,
              maxLines: 5,
              textInputAction: TextInputAction.send,
              enabled: !busy,
              style: TextStyle(fontSize: 13, height: 1.5, color: p.ink),
              decoration: InputDecoration(
                hintText: busy ? 'NaN 正在工作……' : '描述你要做的东西，回车发送',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onSubmitted: (_) => _send(store),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            key: const ValueKey('chat-send'),
            tooltip: '发送',
            style: IconButton.styleFrom(
              backgroundColor: p.accent,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.all(11),
            ),
            onPressed: busy ? null : () => _send(store),
            icon: busy
                ? SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.arrow_upward, size: 18),
          ),
        ],
      ),
    );
  }
}

/// 项目菜单：手机/iPad 竖屏聊天主面与画中画工作区共用的唯一项目入口。
///
/// 聊天优先壳里没有桌面 TitleBar/StatusBar；画中画渲染的
/// `Workspace(embedded: true)` 同样隐藏标题栏与状态栏。没有这个入口，
/// 手机用户既看不到项目名与未保存点，也无法把当前项目保存下来
/// （docs/design-system.md：所有操作都有可见入口）。
///
/// 保存/另存走 [AppStore.saveProject]：手机没有系统保存对话框，store 在
/// 应用文档目录分配默认路径；另存为落在同一项目库，可经「打开项目」找回。
class ChatProjectMenu extends StatelessWidget {
  const ChatProjectMenu({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final p = context.palette;
    final name = store.hasProject ? store.projectName : '还没有项目';
    return PopupMenuButton<String>(
      key: const ValueKey('chat-project-menu'),
      tooltip: '项目菜单',
      offset: const Offset(0, 22),
      constraints: const BoxConstraints(minWidth: 184, maxWidth: 260),
      color: p.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: p.lineStrong),
      ),
      onSelected: (value) => _onSelected(context, store, value),
      itemBuilder: (context) => [
        if (store.hasProject) ...[
          _item(context, 'save', Icons.save_outlined, '保存'),
          _item(context, 'save_as', Icons.save_as_outlined, '另存为…'),
          const PopupMenuDivider(),
        ],
        _item(context, 'open', Icons.folder_open_outlined, '打开项目…'),
        _item(context, 'new', Icons.add_box_outlined, '新建项目'),
        if (store.recent.isNotEmpty) ...[
          const PopupMenuDivider(),
          _section(context, '最近项目'),
          for (final r in store.recent.take(4))
            _item(
              context,
              'recent:${r['path']}',
              Icons.history,
              (r['name'] ?? '').toString(),
            ),
        ],
      ],
      child: Container(
        height: 22,
        padding: const EdgeInsets.only(left: 6, right: 3),
        decoration: BoxDecoration(
          color: p.panel2.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: p.line),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10.5, color: p.ink2),
              ),
            ),
            if (store.dirty)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Tooltip(
                  message: '有未保存的改动',
                  child: Container(
                    key: const ValueKey('chat-project-dirty'),
                    width: 5,
                    height: 5,
                    decoration: BoxDecoration(color: p.warn, shape: BoxShape.circle),
                  ),
                ),
              ),
            Icon(Icons.expand_more, size: 13, color: p.ink4),
          ],
        ),
      ),
    );
  }

  Future<void> _onSelected(BuildContext context, AppStore store, String value) async {
    switch (value) {
      case 'save':
        await store.saveProject();
      case 'save_as':
        await _saveProjectAs(context, store);
      case 'open':
        await openProjectFlow(context, '');
      case 'new':
        await showNewProjectFlow(context);
      default:
        if (value.startsWith('recent:')) {
          await openProjectFlow(context, value.substring('recent:'.length));
        }
    }
  }

  Future<void> _saveProjectAs(BuildContext context, AppStore store) async {
    final name = await showNonDialog<String>(
      context: context,
      builder: (_) => _SaveAsDialog(initial: store.projectName),
    );
    if (name == null || !context.mounted) return;
    await _saveProjectAsNamed(store, name);
  }

  /// 另存：与当前项目同目录（手机上即应用文档目录）新建一个不重名的文件；
  /// 还没落过盘时改个项目名直接走 store 的默认保存路径。
  Future<void> _saveProjectAsNamed(AppStore store, String rawName) async {
    final base = _safeFileBase(rawName);
    if (base.isEmpty) return;
    final current = store.projectPath;
    if (current != null && current.isNotEmpty) {
      final slash = current.lastIndexOf(RegExp(r'[\\/]'));
      if (slash > 0) {
        final dir = current.substring(0, slash);
        var candidate = '$dir/$base.ddp';
        var n = 2;
        while (File(candidate).existsSync()) {
          candidate = '$dir/$base-$n.ddp';
          n += 1;
        }
        await store.saveProject(path: candidate);
        return;
      }
    }
    final previous = store.projectName;
    store.projectName = base;
    final ok = await store.saveProject();
    if (!ok && store.projectPath == null) store.projectName = previous;
  }

  PopupMenuItem<String> _item(
      BuildContext context, String value, IconData icon, String label) {
    final p = context.palette;
    return PopupMenuItem<String>(
      value: value,
      height: 36,
      child: Row(
        children: [
          Icon(icon, size: 14, color: p.ink4),
          const SizedBox(width: 8),
          Expanded(
            child: Text(label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: p.ink2)),
          ),
        ],
      ),
    );
  }

  PopupMenuItem<String> _section(BuildContext context, String label) {
    final p = context.palette;
    return PopupMenuItem<String>(
      enabled: false,
      height: 24,
      child: Text(label,
          style: TextStyle(fontSize: 10, letterSpacing: 0.6, color: p.ink4)),
    );
  }
}

/// 文件名安全化（用户输入不包含路径分隔符；重名由调用侧追加序号）。
String _safeFileBase(String raw) {
  final cleaned = raw
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '-')
      .replaceAll(RegExp(r'^\.+'), '')
      .trim();
  return cleaned.length > 60 ? cleaned.substring(0, 60) : cleaned;
}

/// 另存为的命名对话框（手机上没有系统保存对话框，名称与落点都在应用内）。
class _SaveAsDialog extends StatefulWidget {
  final String initial;
  const _SaveAsDialog({required this.initial});

  @override
  State<_SaveAsDialog> createState() => _SaveAsDialogState();
}

class _SaveAsDialogState extends State<_SaveAsDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    Navigator.of(context).pop(text);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return AlertDialog(
      backgroundColor: p.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: p.lineStrong),
      ),
      title: const Text('另存为',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const ValueKey('chat-save-as-name'),
              controller: _controller,
              autofocus: true,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(
                labelText: '项目名称',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            Text('会保存到应用内项目库，之后可在「打开项目」里重新找到。',
                style: TextStyle(fontSize: 10.5, height: 1.5, color: p.ink4)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('保存')),
      ],
    );
  }
}
