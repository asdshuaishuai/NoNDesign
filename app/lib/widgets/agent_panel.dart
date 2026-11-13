part of 'right_panel.dart';


class AgentPanel extends StatefulWidget {
  const AgentPanel({super.key});
  @override
  State<AgentPanel> createState() => _AgentPanelState();
}

class _AgentPanelState extends State<AgentPanel> {
  final _scroll = ScrollController();
  final _input = TextEditingController();
  final _inputFocus = FocusNode();
  String _mode = 'build';
  bool _modeTouched = false;
  int _lastCount = 0;

  @override
  void dispose() {
    _scroll.dispose();
    _input.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final max = _scroll.position.maxScrollExtent;
      if (max - _scroll.offset < 120) _scroll.animateTo(max, duration: const Duration(milliseconds: 160), curve: Curves.easeOut);
    });
  }

  Future<void> _send(AppStore store) async {
    final text = _input.text.trim();
    if (text.isEmpty || store.agentBusy) return;
    _input.clear();
    if (_mode == 'plan') {
      await store.runPlan(text);
    } else if (_mode == 'build') {
      await store.runBuild(text);
    } else {
      await store.runRefine(text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final p = context.palette;
    if (!_modeTouched) _mode = store.render.artboards.isEmpty ? 'build' : 'refine';
    if (store.timeline.length != _lastCount) {
      _lastCount = store.timeline.length;
      _scrollToEnd();
    }
    return Column(
      children: [
        Expanded(
          child: GestureDetector(
            onTap: () => _inputFocus.requestFocus(),
            child: ListView(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
              children: [
                if (store.timeline.isEmpty && store.streamText.isEmpty)
                  _AgentIntro(onPick: (mode, text) {
                    setState(() {
                      _mode = mode;
                      _modeTouched = true;
                    });
                    _input.text = text;
                    _inputFocus.requestFocus();
                  }),
                for (final entry in store.timeline) _TimelineRow(entry: entry),
                if (store.streamText.isNotEmpty)
                  Container(
                    margin: const EdgeInsets.only(top: 6),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: p.panel2.withValues(alpha: 0.45),
                      borderRadius: BorderRadius.circular(11),
                      border: Border.all(color: p.line),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Icon(Icons.auto_awesome, size: 10, color: p.accent),
                          const SizedBox(width: 4),
                          Text('NoN', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: p.accent)),
                        ]),
                        const SizedBox(height: 5),
                        SelectableText(
                          store.streamText.length > 4000
                              ? store.streamText.substring(store.streamText.length - 4000)
                              : store.streamText,
                          style: TextStyle(fontSize: 11.5, height: 1.55, color: p.ink2),
                        ),
                      ],
                    ),
                  ),
                if (store.thinkingText.isNotEmpty)
                  Theme(
                    data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                    child: ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      childrenPadding: const EdgeInsets.only(bottom: 6),
                      leading: Icon(Icons.psychology_outlined, size: 14, color: p.ink4),
                      title: Text('思考过程', style: TextStyle(fontSize: 10.5, color: p.ink4)),
                      children: [
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(color: p.panel2, borderRadius: BorderRadius.circular(8)),
                          child: Text(store.thinkingText,
                              maxLines: 20,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 10, height: 1.5, color: p.ink4)),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: p.line)),
            color: p.bgElevated.withValues(alpha: 0.95),
          ),
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: p.panel2.withValues(alpha: 0.65),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: p.line),
                ),
                child: Column(
                  children: [
                    TextField(
                      controller: _input,
                      focusNode: _inputFocus,
                      minLines: 2,
                      maxLines: 5,
                      style: TextStyle(fontSize: 12.5, height: 1.5, color: p.ink),
                      decoration: InputDecoration(
                        hintText: _mode == 'plan'
                            ? '描述产品目标，NoN 会写 PRD / UI 说明 / 设计规范…'
                            : _mode == 'build'
                                ? '描述要生成的原型，NoN 会先规划页面再逐屏生成…'
                                : '描述要改的地方，例如「把主按钮改成品牌色，圆角 10」…',
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        filled: false,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
                      ),
                      onSubmitted: (_) => _send(store),
                    ),
                    Row(
                      children: [
                        _ModeChip(
                          mode: 'build',
                          label: '生成',
                          current: _mode,
                          onTap: () => setState(() {
                            _mode = 'build';
                            _modeTouched = true;
                          }),
                        ),
                        const SizedBox(width: 3),
                        _ModeChip(
                          mode: 'refine',
                          label: '调整',
                          current: _mode,
                          onTap: () => setState(() {
                            _mode = 'refine';
                            _modeTouched = true;
                          }),
                        ),
                        const SizedBox(width: 3),
                        _ModeChip(
                          mode: 'plan',
                          label: '文档',
                          current: _mode,
                          onTap: () => setState(() {
                            _mode = 'plan';
                            _modeTouched = true;
                          }),
                        ),
                        const Spacer(),
                        if (store.agentBusy)
                          FilledButton.icon(
                            style: FilledButton.styleFrom(backgroundColor: p.danger, padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7)),
                            onPressed: () => store.cancelAgent(),
                            icon: const Icon(Icons.stop_rounded, size: 12),
                            label: const Text('停止', style: TextStyle(fontSize: 11)),
                          )
                        else
                          FilledButton.icon(
                            style: FilledButton.styleFrom(
                              backgroundColor: p.accent,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
                            ),
                            onPressed: _input.text.trim().isEmpty ? null : () => _send(store),
                            icon: const Icon(Icons.arrow_upward, size: 12),
                            label: const Text('发送', style: TextStyle(fontSize: 11)),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 5),
              Row(
                children: [
                  Icon(Icons.auto_awesome, size: 9, color: p.accent),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      '${store.model?.name ?? '未选择模型'} · ${formatTokens(store.model?.context)} ctx',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 9.5, color: p.ink4),
                    ),
                  ),
                  Text('${modCombo('⌘↵')} 发送', style: TextStyle(fontSize: 9, color: p.ink4)),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ModeChip extends StatelessWidget {
  final String mode;
  final String label;
  final String current;
  final VoidCallback onTap;
  const _ModeChip({required this.mode, required this.label, required this.current, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final active = mode == current;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: active ? p.panel3 : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 10.5, fontWeight: FontWeight.w600, color: active ? p.ink : p.ink4)),
      ),
    );
  }
}

class _AgentIntro extends StatelessWidget {
  final void Function(String mode, String text) onPick;
  const _AgentIntro({required this.onPick});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.only(top: 26, left: 8, right: 8),
      child: Column(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              gradient: const LinearGradient(colors: [Color(0xFF7C8CFF), Color(0xFFB58CFF)]),
              boxShadow: const [BoxShadow(color: Color(0x557C8CFF), blurRadius: 22, offset: Offset(0, 8))],
            ),
            child: const Icon(Icons.auto_awesome, size: 19, color: Colors.white),
          ),
          const SizedBox(height: 12),
          Text('嗨，我是 NoN', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: p.ink)),
          const SizedBox(height: 4),
          Text('描述目标，我会先规划页面与交互，再把它们画到画布上。也可以让我修改选中节点。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, height: 1.55, color: p.ink3)),
          const SizedBox(height: 16),
          for (final item in [
            ('一套登录 + 首页 + 设置', 'build'),
            ('把当前页面改成深色主题', 'refine'),
            ('补一个空状态和错误态', 'refine'),
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => onPick(item.$2, item.$1),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    border: Border.all(color: p.line),
                    borderRadius: BorderRadius.circular(8),
                    color: p.panel2.withValues(alpha: 0.35),
                  ),
                  child: Row(
                    children: [
                      Expanded(child: Text(item.$1, style: TextStyle(fontSize: 11, color: p.ink3))),
                      Icon(Icons.arrow_outward, size: 11, color: p.ink4),
                    ],
                  ),
                ),
              ),
            ),
          if (!(context.watch<AppStore>().model?.toolCall ?? true))
            Container(
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(color: p.warn.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(7)),
              child: Row(
                children: [
                  Icon(Icons.warning_amber_rounded, size: 12, color: p.warn),
                  const SizedBox(width: 5),
                  Expanded(child: Text('当前模型不支持工具调用', style: TextStyle(fontSize: 10, color: p.warn))),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _TimelineRow extends StatelessWidget {
  final TimelineEntry entry;
  const _TimelineRow({required this.entry});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    switch (entry.kind) {
      case 'user':
        return Align(
          alignment: Alignment.centerRight,
          child: Container(
            margin: const EdgeInsets.only(left: 28, bottom: 7),
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              color: p.panel2.withValues(alpha: 0.75),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(11),
                topRight: Radius.circular(4),
                bottomLeft: Radius.circular(11),
                bottomRight: Radius.circular(11),
              ),
              border: Border.all(color: p.line),
            ),
            child: Text(entry.text, maxLines: 6, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, height: 1.5, color: p.ink2)),
          ),
        );
      case 'phase':
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1.4, color: p.accent)),
              const SizedBox(width: 6),
              Text(entry.text, style: TextStyle(fontSize: 10, color: p.ink4)),
            ],
          ),
        );
      case 'tool':
        return Container(
          margin: const EdgeInsets.only(bottom: 4),
          decoration: BoxDecoration(
            color: p.panel2.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: entry.error != null ? p.danger.withValues(alpha: 0.3) : p.line),
          ),
          child: Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: const EdgeInsets.symmetric(horizontal: 8),
              childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              shape: const Border(),
              collapsedShape: const Border(),
              minTileHeight: 30,
              leading: Icon(
                entry.running
                    ? Icons.hourglass_top_rounded
                    : entry.error != null
                        ? Icons.close_rounded
                        : Icons.check_rounded,
                size: 12,
                color: entry.running ? p.accent : entry.error != null ? p.danger : p.success,
              ),
              title: Text(_toolLabel(entry.tool ?? ''),
                  style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w500, color: p.ink2)),
              subtitle: _toolSubtitle(entry, p),
              trailing: Text(entry.ms != null ? '${entry.ms}ms' : '',
                  style: TextStyle(fontSize: 9, fontFamily: 'Menlo', color: p.ink4)),
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(color: p.bgElevated, borderRadius: BorderRadius.circular(6)),
                  child: SelectableText(entry.error ?? entry.preview ?? '—',
                      style: TextStyle(fontSize: 9, fontFamily: 'Menlo', height: 1.45, color: p.ink4)),
                ),
              ],
            ),
          ),
        );
      case 'note':
        return Container(
          margin: const EdgeInsets.only(bottom: 5),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: p.success.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: p.success.withValues(alpha: 0.2)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.bolt, size: 11, color: p.success),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  entry.text.isEmpty ? (entry.title ?? '') : '${entry.title} ${entry.text}',
                  style: TextStyle(fontSize: 10, height: 1.4, color: p.success),
                ),
              ),
            ],
          ),
        );
      case 'assistant':
        return Container(
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.all(9),
          decoration: BoxDecoration(
            color: p.panel2.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: p.line),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(Icons.auto_awesome, size: 10, color: p.accent),
                const SizedBox(width: 4),
                Text('NoN', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: p.accent)),
              ]),
              const SizedBox(height: 4),
              MarkdownBody(
                data: entry.text,
                styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
                  p: TextStyle(fontSize: 11.5, height: 1.55, color: p.ink2),
                ),
              ),
            ],
          ),
        );
      case 'finish':
        return Container(
          margin: const EdgeInsets.only(top: 4, bottom: 6),
          padding: const EdgeInsets.all(9),
          decoration: BoxDecoration(
            color: (entry.ok ? p.success : p.danger).withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: (entry.ok ? p.success : p.danger).withValues(alpha: 0.25)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(entry.ok ? Icons.check_circle_outline : Icons.error_outline,
                      size: 12, color: entry.ok ? p.success : p.danger),
                  const SizedBox(width: 5),
                  Text(entry.title ?? (entry.ok ? '完成' : '异常结束'),
                      style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: entry.ok ? p.success : p.danger)),
                  const Spacer(),
                  Text(formatTime(entry.ts), style: TextStyle(fontSize: 9, color: p.ink4)),
                ],
              ),
              if (entry.text.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(entry.text, style: TextStyle(fontSize: 10.5, height: 1.45, color: p.ink3)),
              ],
            ],
          ),
        );
      default:
        return const SizedBox.shrink();
    }
  }

  Widget? _toolSubtitle(TimelineEntry entry, NonPalette p) {
    final args = entry.args;
    if (args == null) return null;
    final text = switch (entry.tool) {
      'design_op' => args['op']?.toString(),
      'generate_page' => '${args['intent'] ?? ''}${args['name'] != null ? ' · ${args['name']}' : ''}',
      'inspect' => '${args['kind'] ?? ''}${args['artboard'] != null ? ' · ${args['artboard']}' : ''}',
      'write_doc' => '${args['kind'] ?? ''} · ${args['chars'] ?? 0} 字',
      _ => null,
    };
    if (text == null || text.isEmpty) return null;
    return Text(text, maxLines: 1, overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 9, fontFamily: 'Menlo', color: p.ink4));
  }

  String _toolLabel(String tool) => switch (tool) {
        'generate_page' => '生成页面',
        'design_op' => '设计操作',
        'read_mbt' => '读取文档',
        'inspect' => '检视引擎',
        'list_templates' => '查询模板',
        'list_components' => '查询组件',
        'read_docs' => '读取文档',
        'write_doc' => '写入文档',
        'write_design_spec' => '写入规范',
        'finish' => '收尾',
        _ => tool,
      };
}

