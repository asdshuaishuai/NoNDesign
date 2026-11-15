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
  int _lastStreamLen = 0;
  int _lastThinkLen = 0;
  // 跟随滚动：流式增量只改文本不触发滚动，长输出落视口下不可见——
  // 跟随开启时每次长度变化贴底；用户上翻（手势门）即暂停并给出浮标。
  bool _follow = true;
  bool _userScrolling = false;
  bool _showJumpPill = false;
  // 首次挂载/切回 tab 的贴底是瞬时定位（IM 惯例），不走 180ms 动画——
  // 动画从顶部滑到底落点还取首帧估计。后续仍按现规则（离散行动画、流式 jump）。
  bool _firstFollow = true;
  static const double _followSlack = 80;

  @override
  void dispose() {
    _scroll.dispose();
    _input.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  bool _atBottomOf(ScrollMetrics metrics) =>
      metrics.maxScrollExtent - metrics.pixels <= _followSlack;

  /// animate=false 瞬时贴底（流式合帧 ~12.5Hz，动画会互相追尾）；true 走
  /// NonMotion.base（离散追加的时间线行）。动了 NonMotion 档位表别忘同步。
  void _followBottom({required bool animate}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final max = _scroll.position.maxScrollExtent;
      if (animate) {
        _scroll.animateTo(max, duration: NonMotion.base, curve: NonMotion.curve);
      } else {
        _scroll.jumpTo(max);
      }
    });
  }

  /// 用户手势门：UserScrollNotification 只在拖拽/惯性滚动时来，自身的
  /// jumpTo/animateTo 不经过它，不会自我打断。距底 ≤80 即恢复跟随。
  /// 返回 false 不拦截通知（通知链继续冒泡）。
  bool _onScrolled(UserScrollNotification n) {
    _userScrolling = n.direction != ScrollDirection.idle;
    _follow = _atBottomOf(n.metrics);
    final showPill = !_follow;
    if (showPill != _showJumpPill) setState(() => _showJumpPill = showPill);
    return false;
  }

  Future<void> _send(AppStore store) async {
    final text = _input.text.trim();
    if (text.isEmpty || store.agentBusy) return;
    _input.clear();
    // 新一轮消息直达视口下（时间线以 user 行开场），用户上翻过也重新贴上。
    _follow = true;
    _showJumpPill = false;
    _followBottom(animate: true);
    // 外部智能体（ACP）接管发送：模式芯片无意义，文本直达该 CLI。
    final external = store.settings.acpAgentId;
    if (external != null && external.isNotEmpty) {
      await store.runAcp(text);
      return;
    }
    if (_mode == 'plan') {
      await store.runPlan(text);
    } else if (_mode == 'build') {
      await store.runBuild(text);
    } else {
      await store.runRefine(text);
    }
  }

  Widget _buildStreamRow(BuildContext context, AppStore store, NonPalette p) {
    // 常规 agent 流式形态：无卡片容器——品牌小标 + 平铺正文。
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.auto_awesome, size: 10, color: p.accent),
            const SizedBox(width: 4),
            Text('NoN', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: p.accent)),
          ]),
          const SizedBox(height: 4),
          SelectableText(
            store.streamText.length > 4000 ? store.streamText.substring(store.streamText.length - 4000) : store.streamText,
            style: TextStyle(fontSize: 12, height: 1.55, color: p.ink2),
          ),
        ],
      ),
    );
  }

  Widget _buildThinkingTile(BuildContext context, AppStore store, NonPalette p) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 6),
        leading: Icon(Icons.psychology_outlined, size: 14, color: p.ink4),
        title: Text('思考过程', style: TextStyle(fontSize: 11, color: p.ink4)),
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.only(left: 8),
            decoration: BoxDecoration(
              border: Border(left: BorderSide(width: 2, color: p.ink4.withValues(alpha: 0.3))),
            ),
            child: Text(store.thinkingText,
                maxLines: 20,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10, height: 1.5, color: p.ink4)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final p = context.palette;
    final external = store.settings.acpAgentId?.isNotEmpty == true;
    final agentLabel = external
        ? (store.settings.acpAgentName ?? store.settings.acpAgentId!) + ' · ACP'
        : 'NoN 内置';
    if (!external && !_modeTouched) _mode = store.render.artboards.isEmpty ? 'build' : 'refine';
    // 三类长度比对：时间线行（离散追加，动画贴底）+ 流式文本/思考增量
    // （80ms 合帧只改文本不触发滚动——不比对就落视口下不可见）。
    final tlChanged = store.timeline.length != _lastCount;
    final streamChanged = store.streamText.length != _lastStreamLen;
    final thinkChanged = store.thinkingText.length != _lastThinkLen;
    if (tlChanged || streamChanged || thinkChanged) {
      _lastCount = store.timeline.length;
      _lastStreamLen = store.streamText.length;
      _lastThinkLen = store.thinkingText.length;
      // 手势拖拽进行中（_userScrolling）不贴底——与手指抢滚动条。
      if (_follow && !_userScrolling) {
        final first = _firstFollow;
        _firstFollow = false;
        _followBottom(animate: !first && tlChanged && !streamChanged && !thinkChanged);
      }
    }
    return Column(
      children: [
        Expanded(
          child: Stack(
            children: [
              GestureDetector(
                onTap: () => _inputFocus.requestFocus(),
                // builder 惰性构建：长运行时间线可达数百行，ListView(children:)
                // 会在每次合帧通知时重建全部行。
                child: NotificationListener<UserScrollNotification>(
                  onNotification: _onScrolled,
                  child: ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(12),
                    itemCount: (store.timeline.isEmpty && store.streamText.isEmpty && store.thinkingText.isEmpty ? 1 : 0) +
                        store.timeline.length +
                        (store.streamText.isNotEmpty ? 1 : 0) +
                        (store.thinkingText.isNotEmpty ? 1 : 0),
                    itemBuilder: (context, i) {
                      final intro = store.timeline.isEmpty && store.streamText.isEmpty && store.thinkingText.isEmpty;
                      if (intro) {
                        return _AgentIntro(onPick: (mode, text) {
                          setState(() {
                            _mode = mode;
                            _modeTouched = true;
                          });
                          _input.text = text;
                          _inputFocus.requestFocus();
                        });
                      }
                      var idx = i;
                      if (idx < store.timeline.length) {
                        return _TimelineRow(
                          entry: store.timeline[idx],
                          animate: idx >= store.timeline.length - 3, // 只给新行淡入，旧行免重播
                        );
                      }
                      idx -= store.timeline.length;
                      if (store.streamText.isNotEmpty) {
                        if (idx == 0) return _buildStreamRow(context, store, p);
                        idx -= 1;
                      }
                      return _buildThinkingTile(context, store, p);
                    },
                  ),
                ),
              ),
              if (_showJumpPill)
                Positioned(
                  right: 10,
                  bottom: 10,
                  // 条件挂载即入场：NonMotion.fast 淡入（离场瞬时，落底自然消失）。
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: 1),
                    duration: NonMotion.fast,
                    curve: NonMotion.curve,
                    builder: (context, t, child) => Opacity(opacity: t, child: child),
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: p.panel3,
                        foregroundColor: p.ink2,
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      ),
                      onPressed: () {
                        setState(() {
                          _follow = true;
                          _showJumpPill = false;
                        });
                        _followBottom(animate: true);
                      },
                      icon: const Icon(Icons.arrow_downward, size: 12),
                      label: const Text('回到底部', style: TextStyle(fontSize: 10)),
                    ),
                  ),
                ),
            ],
          ),
        ),
        Container(
          // 面板内容 padding 统一 12（与左栏/检查器同档，列间边缘对齐）。
          padding: const EdgeInsets.all(12),
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
                      style: TextStyle(fontSize: 13, height: 1.5, color: p.ink),
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
                        // 当前执行的 agent（用户点名展示）：内置/外部具名。
                        Tooltip(
                          message: external
                              ? '消息将发给外部智能体 $agentLabel（模式芯片不参与）；在设置 → 外部智能体 里切换'
                              : 'NoN 内置管线；可在设置 → 外部智能体 里切换',
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: external ? p.accentSoft : p.panel3,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                  color: external ? p.accent.withValues(alpha: 0.45) : p.line),
                            ),
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              Icon(external ? Icons.hub_outlined : Icons.auto_awesome,
                                  size: 10, color: external ? p.accent : p.ink3),
                              const SizedBox(width: 4),
                              Text(agentLabel,
                                  style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w600,
                                      color: external ? p.accent : p.ink3)),
                            ]),
                          ),
                        ),
                        if (!external) ...[
                          const SizedBox(width: 3),
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
                        ],
                        const Spacer(),
                        if (store.agentBusy)
                          FilledButton.icon(
                            style: FilledButton.styleFrom(backgroundColor: p.danger, padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7)),
                            onPressed: () => store.cancelAgent(),
                            icon: const Icon(Icons.stop_rounded, size: 12),
                            label: const Text('停止', style: TextStyle(fontSize: 11)),
                          )
                        else
                          // TextEditingController 本身是 Listenable：按钮行单独
                          // 监听输入文本，启用态随打字即时更新（此前只有 store
                          // 通知才刷新，打字后按钮滞留禁用态）。
                          ListenableBuilder(
                            listenable: _input,
                            builder: (_, __) => FilledButton.icon(
                              style: FilledButton.styleFrom(
                                backgroundColor: p.accent,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
                              ),
                              onPressed: _input.text.trim().isEmpty ? null : () => _send(store),
                              icon: const Icon(Icons.arrow_upward, size: 12),
                              label: const Text('发送', style: TextStyle(fontSize: 11)),
                            ),
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
                      style: TextStyle(fontSize: 10, color: p.ink4),
                    ),
                  ),
                  Text('${modCombo('⌘↵')} 发送', style: TextStyle(fontSize: 10, color: p.ink4)),
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
                fontSize: 11, fontWeight: FontWeight.w600, color: active ? p.ink : p.ink4)),
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
              borderRadius: BorderRadius.circular(12),
              gradient: LinearGradient(colors: [p.accent, p.accent2]),
              boxShadow: [BoxShadow(color: p.accent.withValues(alpha: 0.33), blurRadius: 22, offset: const Offset(0, 8))],
            ),
            child: const Icon(Icons.auto_awesome, size: 19, color: Colors.white),
          ),
          const SizedBox(height: 12),
          Text('嗨，我是 NoN', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: p.ink)),
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
              decoration: BoxDecoration(color: p.warn.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
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

/// 工具调用行（常规 agent 形态）：无卡片背景，单行「状态图标 + 工具名 ·
/// 参数摘要 + 耗时」，点击展开参数/结果详情（左侧竖线缩进的 mono 文本）。
class _ToolRow extends StatefulWidget {
  final TimelineEntry entry;
  const _ToolRow({required this.entry});

  @override
  State<_ToolRow> createState() => _ToolRowState();
}

class _ToolRowState extends State<_ToolRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final entry = widget.entry;
    final subtitle = _toolSubtitleText(entry);
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(4),
            onTap: (entry.preview == null && entry.error == null && entry.args == null)
                ? null
                : () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  Icon(
                    entry.running
                        ? Icons.hourglass_top_rounded
                        : entry.error != null
                            ? Icons.close_rounded
                            : Icons.check_rounded,
                    size: 12,
                    color: entry.running ? p.accent : entry.error != null ? p.danger : p.success,
                  ),
                  const SizedBox(width: 6),
                  Text(_toolLabel(entry.tool ?? ''),
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: p.ink2)),
                  if (subtitle != null) ...[
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(subtitle,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 10, fontFamily: 'Menlo', color: p.ink4)),
                    ),
                  ],
                  if (entry.ms != null) ...[
                    const SizedBox(width: 6),
                    Text('${entry.ms}ms',
                        style: TextStyle(fontSize: 10, fontFamily: 'Menlo', color: p.ink4)),
                  ],
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.only(left: 18, bottom: 4),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
                decoration: BoxDecoration(
                  border: Border(left: BorderSide(width: 2, color: p.accent.withValues(alpha: 0.35))),
                ),
                child: SelectableText(entry.error ?? entry.preview ?? '—',
                    style: TextStyle(fontSize: 10, fontFamily: 'Menlo', height: 1.45, color: p.ink4)),
              ),
            ),
        ],
      ),
    );
  }
}


String? _toolSubtitleText(TimelineEntry entry) {
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
  return text;
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

class _TimelineRow extends StatelessWidget {
  final TimelineEntry entry;
  /// 只对尾部新行做淡入；旧行从 1 起始，避免惰性列表滚动回看时重播动画。
  final bool animate;
  const _TimelineRow({required this.entry, this.animate = true});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    // 新行淡入（180ms）——流式运行时时间线频繁追加，瞬显会闪。
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: animate ? 0 : 1, end: 1),
      duration: NonMotion.base,
      curve: NonMotion.curve,
      builder: (context, opacity, child) =>
          Opacity(opacity: opacity, child: child),
      child: _buildRow(context, p),
    );
  }

  Widget _buildRow(BuildContext context, NonPalette p) {
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
                topLeft: Radius.circular(12),
                topRight: Radius.circular(4),
                bottomLeft: Radius.circular(12),
                bottomRight: Radius.circular(12),
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
        return _ToolRow(entry: entry);
      case 'note':
        return Padding(
          padding: const EdgeInsets.only(bottom: 5),
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
        // 常规 agent 消息形态：无气泡无卡片，正文平铺（品牌标只在流式块）。
        return Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: MarkdownBody(
            data: entry.text,
            styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
              p: TextStyle(fontSize: 12, height: 1.55, color: p.ink2),
            ),
          ),
        );
      case 'finish':
        // 细分隔 + 单行状态（无底色框）——常规 agent 的收尾是一条轻结论。
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            Divider(height: 1, thickness: 0.5, color: p.line),
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(entry.ok ? Icons.check_circle_outline : Icons.error_outline,
                    size: 12, color: entry.ok ? p.success : p.danger),
                const SizedBox(width: 5),
                Text(entry.title ?? (entry.ok ? '完成' : '异常结束'),
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                        color: entry.ok ? p.success : p.danger)),
                const Spacer(),
                Text(formatTime(entry.ts), style: TextStyle(fontSize: 10, color: p.ink4)),
              ],
            ),
            if (entry.text.isNotEmpty) ...[
              const SizedBox(height: 3),
              Text(entry.text, style: TextStyle(fontSize: 11, height: 1.45, color: p.ink3)),
            ],
            const SizedBox(height: 6),
          ],
        );
      default:
        return const SizedBox.shrink();
    }
  }

}

