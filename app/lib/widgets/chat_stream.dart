import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:provider/provider.dart';

import '../core/models.dart';
import '../core/store.dart';
import '../core/theme.dart';
import 'a2ui_card.dart';
import 'common.dart';
import 'settings_dialog.dart';

/// 聊天流主面（docs/plan-chat-stream-shell.md §2 S1）。
///
/// 卡片类型：用户消息 / 进度卡（步骤+工具调用，复用时间线条目的分类经验）/
/// A2UI 交互卡（嵌 [A2uiCard] 静态路径——surface 消息随卡片持久化，恢复后
/// 照常渲染；动作经 onAction 回流 store.handleChatAction 续跑）/ 产物卡
/// （原型→工作区；热应用/视频/3D→对应工作台）。
///
/// 顶栏「工作区」由宿主注入动作（[onOpenWorkspace]）：桌面 ≥1100 切分栏
/// 折叠、移动/平板竖屏开画中画浮窗（S4，承载壳见 widgets/shell_host.dart
/// 的 ChatWorkspaceHost）；无宿主时回退原全屏路径。会话记录由 store 随
/// chat.json 落盘、重启恢复。
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

  const ChatStreamView({
    super.key,
    this.onSettings,
    this.onOpenWorkspace,
    this.onRevealWorkspace,
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
      height: 60,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: p.line))),
      child: Row(
        children: [
          const NonLogo(size: 26),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('NoNDesign',
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: p.ink)),
                Text('聊天流',
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10, letterSpacing: 1.6, color: p.ink4)),
              ],
            ),
          ),
          const SizedBox(width: 6),
          // 「工作区」入口：宿主在时交给宿主（桌面分栏切换 / 移动画中画），
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
          Text('描述要解决的问题与受众——NoN 先写设计文档，再生成可交互原型。',
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
                  Text(s.label,
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
                hintText: busy ? 'NoN 正在工作……' : '描述你要做的东西，回车发送',
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
