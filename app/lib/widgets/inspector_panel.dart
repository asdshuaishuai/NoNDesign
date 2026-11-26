part of 'right_panel.dart';

/// part 文件不能自带 import：库头同时导入了 material_ui（其中 Flow 是布局
/// widget）与 models.dart（Flow 是画板连线），类型名撞车。memo 表只在边界
/// 处用本地运行时别名；源数据与过滤入口仍是 store.render.flows 的强类型结果，
/// 避免为一行类型名去改库头 import（本任务只改 5 个 widget 文件）。
typedef _BoardFlow = dynamic;

class Inspector extends StatefulWidget {
  const Inspector({super.key});
  @override
  State<Inspector> createState() => _InspectorState();
}

class _InspectorState extends State<Inspector> {
  Map<String, dynamic>? _critique;
  String? _flowTarget;
  String _theme = 'light';

  /// 主题下拉运行时数据源（engine list_themes，0.2 实返 13 项含 7 美学预设）：
  /// (id, 显示名)；失败/为空回落硬编码 6 项。
  List<(String, String)> _themes = const [];

  /// activeBoard → session_interactions 全量（按节点过滤在 build 侧做）
  final Map<String, List<Map<String, dynamic>>> _nodeInteractions = {};
  String _interactionsFor = '';

  // ---- build 期派生数据 memo ----
  // agent 流式事件会以 ~12.5Hz 通知 store；render 不变时没必要每次 build 都
  // 把 flows 全量 where().toList() 一遍。身份相等（render/画板/节点/交互表）
  // 就复用上一次结果，数据变了才重算。
  RenderEnvelope? _boardFlowsRender;
  String? _boardFlowsBoard;
  List<_BoardFlow> _boardFlowsMemo = const [];

  String? _nodeFlowsNode;
  List<_BoardFlow> _nodeFlowsSource = const [];
  List<_BoardFlow> _nodeFlowsMemo = const [];

  String? _interactionsCountBoard;
  String? _interactionsCountNode;
  List<Map<String, dynamic>>? _interactionsCountSource;
  int _interactionsCount = 0;

  List<_BoardFlow> _flowsForBoard(AppStore store) {
    final render = store.render;
    final board = store.activeBoard;
    if (identical(render, _boardFlowsRender) && board == _boardFlowsBoard) {
      return _boardFlowsMemo;
    }
    _boardFlowsRender = render;
    _boardFlowsBoard = board;
    return _boardFlowsMemo = render.flows
        .where((f) => f.from == board)
        .toList();
  }

  List<_BoardFlow> _nodeFlowsOf(String nodeId, List<_BoardFlow> boardFlows) {
    if (nodeId == _nodeFlowsNode && identical(boardFlows, _nodeFlowsSource)) {
      return _nodeFlowsMemo;
    }
    _nodeFlowsNode = nodeId;
    _nodeFlowsSource = boardFlows;
    return _nodeFlowsMemo = boardFlows
        .where((f) => f.nodeId == nodeId)
        .toList();
  }

  int _interactionsCountFor(String? board, String nodeId) {
    final source = _nodeInteractions[board] ?? const [];
    if (board == _interactionsCountBoard &&
        nodeId == _interactionsCountNode &&
        identical(source, _interactionsCountSource)) {
      return _interactionsCount;
    }
    _interactionsCountBoard = board;
    _interactionsCountNode = nodeId;
    _interactionsCountSource = source;
    return _interactionsCount = source
        .whereType<Map>()
        .where((m) => m['node']?.toString() == nodeId)
        .length;
  }

  @override
  void initState() {
    super.initState();
    final api = context.read<AppStore>().api;
    if (api == null) return;
    api
        .themes()
        .then((items) {
          if (!mounted) return;
          final themes = <(String, String)>[
            for (final t in items.whereType<Map>())
              if ((t['name'] ?? '').toString().isNotEmpty)
                (
                  (t['name'] ?? '').toString(),
                  (t['display_name'] ?? t['name'] ?? '').toString(),
                ),
          ];
          if (themes.isNotEmpty) setState(() => _themes = themes);
        })
        .catchError((_) {});
  }

  void _ensureNodeInteractions(AppStore store, String board) {
    if (_interactionsFor == board) return;
    _interactionsFor = board;
    final api = store.api;
    final mbt = store.mbt;
    if (api == null || mbt.isEmpty) return;
    api
        .session(mbt, 'session_interactions', board)
        .then((res) {
          if (!mounted) return;
          final items = (res['data'] as List?) ?? const [];
          _nodeInteractions[board] = items
              .whereType<Map>()
              .map((m) => Map<String, dynamic>.from(m))
              .toList();
          if (mounted) setState(() {});
        })
        .catchError((_) {
          if (mounted) _nodeInteractions[board] = const [];
        });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final store = context.read<AppStore>();
    final match = RegExp(
      r'^\s*theme:\s*(\S+)',
      multiLine: true,
    ).firstMatch(store.mbt);
    _theme = match?.group(1) ?? 'light';
  }

  /// 主题显示名：引擎给了人类可读名就用它；只回传内部 id 时才人性化已知主题
  /// （`copy_guard` 禁止把 `high_contrast` 这类代号直接摆到下拉里）。
  String _themeLabel(String id, String label) {
    if (label.isNotEmpty && label != id) return label;
    return switch (id) {
      'light' => '浅色',
      'dark' => '深色',
      'high_contrast' => '高对比',
      'sepia' => '护眼',
      'nord' => '北境',
      'sunset' => '日落',
      _ => label.isNotEmpty ? label : id,
    };
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final node = store.node;
    final board = store.board;
    if (board == null) {
      return EmptyHint(
        icon: Icons.crop_square,
        title: '没有画板',
        detail: '创建一个画板，或让 NaN 从一句话开始。',
      );
    }
    if (store.activeBoard != null) {
      _ensureNodeInteractions(store, store.activeBoard!);
    }
    final boardFlows = _flowsForBoard(store);
    // 面板是纵向长栈（节点检查 ~60 段 / 画板检查 ~25 段）：列表项改由
    // builder 惰性构建，滚出视口的段不再构造 Widget 树。
    final sections = node != null
        ? _nodeInspector(context, store, node, boardFlows)
        : _boardInspector(context, store, boardFlows);
    return ListView.builder(
      padding: const EdgeInsets.all(NonSpace.md),
      itemCount: sections.length,
      itemBuilder: (context, i) => sections[i](),
    );
  }

  List<Widget Function()> _nodeInspector(
    BuildContext context,
    AppStore store,
    CanvasNode node,
    List<_BoardFlow> boardFlows,
  ) {
    final p = context.palette;
    final flows = boardFlows;
    final nodeFlows = _nodeFlowsOf(node.id, flows);
    final nodeInteractionsCount = _interactionsCountFor(
      store.activeBoard,
      node.id,
    );
    return <Widget Function()>[
      if (store.selectedNodes.length >= 2) ...[
        () => Container(
          margin: const EdgeInsets.only(bottom: NonSpace.md),
          padding: const EdgeInsets.all(NonSpace.sm),
          decoration: BoxDecoration(
            color: p.accentSoft.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(NonRadius.md),
            border: Border.all(color: p.accent.withValues(alpha: 0.25)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '多选 · ${store.selectedNodes.length} 个节点',
                style: TextStyle(
                  fontSize: NonType.caption,
                  fontWeight: FontWeight.w600,
                  color: p.accent,
                ),
              ),
              const SizedBox(height: NonSpace.sm),
              Wrap(
                spacing: NonSpace.xs,
                runSpacing: NonSpace.xs,
                children: [
                  for (final (label, mode) in [
                    ('左对齐', 'left'),
                    ('右对齐', 'right'),
                    ('顶对齐', 'top'),
                    ('底对齐', 'bottom'),
                    ('水平居中', 'hcenter'),
                    ('垂直居中', 'vcenter'),
                  ])
                    _MiniButton(
                      label: label,
                      icon: Icons.border_inner,
                      onTap: () => store.alignNodes(store.selectedNodes, mode),
                    ),
                  const SizedBox(width: NonSpace.xs),
                  _MiniButton(
                    label: '编组',
                    icon: Icons.workspaces_outline,
                    onTap: () async {
                      final gid =
                          'grp_${DateTime.now().millisecondsSinceEpoch % 100000}';
                      if (await store.groupNodes(gid, store.selectedNodes)) {
                        store.selectNode(gid);
                      }
                    },
                  ),
                  _MiniButton(
                    label: '取消多选',
                    icon: Icons.clear,
                    onTap: () => store.clearNodeMultiSelection(),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
      () => Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: p.panel2,
              borderRadius: BorderRadius.circular(NonRadius.md),
            ),
            child: Icon(Icons.crop_square, size: 14, color: p.accent),
          ),
          const SizedBox(width: NonSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  node.text.trim().isEmpty ? node.id : node.text.trim(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: NonType.bodyStrong,
                    fontWeight: FontWeight.w600,
                    color: p.ink,
                  ),
                ),
                Text(
                  '${node.component.isEmpty ? node.kind : node.component} · ${node.id}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: NonType.micro,
                    fontFamily: 'Menlo',
                    color: p.ink4,
                  ),
                ),
              ],
            ),
          ),
          IconAction(
            icon: Icons.copy_outlined,
            tooltip: '复制',
            size: 24,
            onTap: () => store.duplicateNode(node.id),
          ),
          IconAction(
            icon: Icons.delete_outline,
            tooltip: '删除',
            size: 24,
            onTap: () => store.deleteNode(node.id),
          ),
        ],
      ),
      () => const SizedBox(height: NonSpace.lg),
      () => const SectionLabel('变换与层级'),
      () => const SizedBox(height: NonSpace.sm),
      () => Row(
        children: [
          _MiniButton(
            label: '上移',
            icon: Icons.arrow_upward,
            onTap: () => store.reorderNode(node.id, 'up'),
          ),
          const SizedBox(width: NonSpace.xs),
          _MiniButton(
            label: '下移',
            icon: Icons.arrow_downward,
            onTap: () => store.reorderNode(node.id, 'down'),
          ),
          const SizedBox(width: NonSpace.xs),
          _MiniButton(
            label: '置顶',
            icon: Icons.vertical_align_top,
            onTap: () => store.reorderNode(node.id, 'front'),
          ),
          const SizedBox(width: NonSpace.xs),
          _MiniButton(
            label: '置底',
            icon: Icons.vertical_align_bottom,
            onTap: () => store.reorderNode(node.id, 'back'),
          ),
        ],
      ),
      () => const SizedBox(height: NonSpace.xs),
      () => Row(
        children: [
          _MiniButton(
            label: '翻转 H',
            icon: Icons.flip,
            onTap: () => store.flipNode(node.id, 'h'),
          ),
          const SizedBox(width: NonSpace.xs),
          _MiniButton(
            label: '翻转 V',
            icon: Icons.flip,
            onTap: () => store.flipNode(node.id, 'v'),
          ),
          const Spacer(),
          _MiniButton(
            label: '让 NaN 改',
            icon: Icons.auto_awesome,
            accent: true,
            onTap: () {
              store.setRightTab('agent');
              store.toasts.info('已选中 ${node.id}', '在 NaN 的输入框里描述要怎么改。');
            },
          ),
        ],
      ),
      () => const SizedBox(height: NonSpace.lg),
      () => const SectionLabel('布局'),
      () => const SizedBox(height: NonSpace.sm),
      () => Row(
        children: [
          _NumField(
            label: 'X',
            value: node.x,
            onCommit: (v) => store.moveNode(node.id, v, node.y),
          ),
          const SizedBox(width: NonSpace.xs),
          _NumField(
            label: 'Y',
            value: node.y,
            onCommit: (v) => store.moveNode(node.id, node.x, v),
          ),
          const SizedBox(width: NonSpace.xs),
          _NumField(
            label: 'W',
            value: node.w,
            onCommit: (v) => store.updateNode(node.id, {'w': v}),
          ),
          const SizedBox(width: NonSpace.xs),
          _NumField(
            label: 'H',
            value: node.h,
            onCommit: (v) => store.updateNode(node.id, {'h': v}),
          ),
        ],
      ),
      () => const SizedBox(height: NonSpace.sm),
      () => Row(
        children: [
          IconAction(
            icon: Icons.format_align_left,
            tooltip: '左对齐',
            size: 24,
            onTap: () => store.updateNode(node.id, {'align': 'left'}),
          ),
          IconAction(
            icon: Icons.format_align_center,
            tooltip: '居中',
            size: 24,
            onTap: () => store.updateNode(node.id, {'align': 'center'}),
          ),
          IconAction(
            icon: Icons.format_align_right,
            tooltip: '右对齐',
            size: 24,
            onTap: () => store.updateNode(node.id, {'align': 'right'}),
          ),
          const Spacer(),
          Text(
            '可见',
            style: TextStyle(fontSize: NonType.caption, color: p.ink3),
          ),
          Switch(
            value: node.style.visible,
            onChanged: (v) => store.updateNode(node.id, {'visible': v}),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ],
      ),
      () => const SizedBox(height: NonSpace.md),
      () => SectionLabel(
        '布局意图',
        trailing: Pill(label: '整板生效', color: p.ink4),
      ),
      () => const SizedBox(height: NonSpace.sm),
      () => const _ConstrainBar(),
      () => const SizedBox(height: NonSpace.md),
      () => const SectionLabel('外观'),
      () => const SizedBox(height: NonSpace.sm),
      () => _ColorRow(
        label: '填充',
        value: node.style.fill,
        onCommit: (v) => store.updateNode(node.id, {'fill': v}),
      ),
      () => const SizedBox(height: NonSpace.xs),
      () => _ColorRow(
        label: '文字',
        value: node.style.textColor,
        onCommit: (v) => store.updateNode(node.id, {'text_color': v}),
      ),
      () => const SizedBox(height: NonSpace.xs),
      () => Row(
        children: [
          _NumField(
            label: '圆角',
            value: node.style.radius,
            onCommit: (v) => store.updateNode(node.id, {'radius': v}),
          ),
          const SizedBox(width: NonSpace.xs),
          _NumField(
            label: '字号',
            value: node.style.fontSize,
            onCommit: (v) => store.updateNode(node.id, {'font_size': v}),
          ),
        ],
      ),
      () => const SizedBox(height: NonSpace.xs),
      () => Row(
        children: [
          Text(
            '透明度',
            style: TextStyle(fontSize: NonType.caption, color: p.ink3),
          ),
          Expanded(
            child: _OpacitySlider(
              value: node.style.opacity,
              onCommit: (v) => store.updateNode(node.id, {'opacity': v}),
            ),
          ),
          Text(
            '${(node.style.opacity * 100).round()}%',
            style: TextStyle(
              fontSize: NonType.micro,
              fontFamily: 'Menlo',
              color: p.ink4,
            ),
          ),
        ],
      ),
      () => const SizedBox(height: NonSpace.xs),
      () => Row(
        children: [
          Expanded(
            child: _SelectField(
              label: '字重',
              value: node.style.weight,
              options: const ['normal', 'medium', 'semibold', 'bold'],
              onChanged: (v) => store.updateNode(node.id, {'weight': v}),
            ),
          ),
          const SizedBox(width: NonSpace.xs),
          Expanded(
            child: _SelectField(
              label: '对齐',
              value: node.style.align,
              options: const ['left', 'center', 'right'],
              onChanged: (v) => store.updateNode(node.id, {'align': v}),
            ),
          ),
        ],
      ),
      () => const SizedBox(height: NonSpace.xs),
      // 阴影档位（引擎 e1/e2/e3 三档海拔，原版同词表）。
      () => _SelectField(
        label: '阴影',
        value: node.style.shadow,
        options: const ['none', 'e1', 'e2', 'e3'],
        onChanged: (v) => store.updateNode(node.id, {'shadow': v}),
      ),
      () => const SizedBox(height: NonSpace.xs),
      () => Row(
        children: [
          _NumField(
            label: '描边宽',
            value: node.style.strokeWidth,
            onCommit: (v) => store.updateNode(node.id, {'stroke_width': v}),
          ),
          const SizedBox(width: NonSpace.xs),
          Expanded(
            child: _ColorRow(
              label: '描边色',
              value: node.style.stroke == 'none'
                  ? '#000000'
                  : node.style.stroke,
              onCommit: (v) => store.updateNode(node.id, {'stroke': v}),
            ),
          ),
        ],
      ),
      () => const SizedBox(height: NonSpace.xs),
      () => Row(
        children: [
          Expanded(
            child: _SelectField(
              label: '斜体',
              value: node.style.italic,
              options: const ['normal', 'italic'],
              onChanged: (v) => store.updateNode(node.id, {'italic': v}),
            ),
          ),
          const SizedBox(width: NonSpace.xs),
          Expanded(
            child: _SelectField(
              label: '线型',
              value: node.style.dash,
              options: const ['solid', 'dashed', 'dotted'],
              onChanged: (v) => store.updateNode(node.id, {'dash': v}),
            ),
          ),
        ],
      ),
      () => const SizedBox(height: NonSpace.md),
      () => const SectionLabel('布局'),
      () => const SizedBox(height: NonSpace.sm),
      () => Row(
        children: [
          Expanded(
            child: _SelectField(
              label: '宽模式',
              value: node.widthMode,
              options: const ['fixed', 'hug', 'fill'],
              onChanged: (v) {
                // 引擎 width_mode 只认 hug/fill（fixed 落 _ => () 无操作，
                // op 却「成功」零反馈）；回固定尺寸走 resizeNode 同款配方：
                // w= 写死当前渲染尺寸（只动本轴，不碰另一轴的模式）。
                if (v == 'fixed') {
                  store.updateNode(node.id, {
                    'width_mode': v,
                    'w': node.w.round(),
                  });
                } else {
                  store.updateNode(node.id, {'width_mode': v});
                }
              },
            ),
          ),
          const SizedBox(width: NonSpace.xs),
          Expanded(
            child: _SelectField(
              label: '高模式',
              value: node.heightMode,
              options: const ['fixed', 'hug', 'fill'],
              onChanged: (v) {
                if (v == 'fixed') {
                  store.updateNode(node.id, {
                    'height_mode': v,
                    'h': node.h.round(),
                  });
                } else {
                  store.updateNode(node.id, {'height_mode': v});
                }
              },
            ),
          ),
        ],
      ),
      () => const SizedBox(height: NonSpace.xs),
      () => Row(
        children: [
          Expanded(
            child: _SelectField(
              label: '容器布局',
              value: node.layoutDir,
              options: const ['none', 'vertical', 'horizontal'],
              onChanged: (v) => store.updateNode(node.id, {'layout': v}),
            ),
          ),
          const SizedBox(width: NonSpace.xs),
          Expanded(
            child: _SelectField(
              label: '对齐方式',
              value: node.layoutJustify,
              options: const ['start', 'center', 'end'],
              // 引擎 gap/justify/padding 在 layout=None 时全部静默忽略
              // （None => ()）；无布局方向就禁用 + 提示，杜绝静默丢输入。
              enabled: node.layoutDir != 'none',
              disabledHint: '先选容器布局方向',
              onChanged: (v) => store.updateNode(node.id, {'justify': v}),
            ),
          ),
        ],
      ),
      () => const SizedBox(height: NonSpace.xs),
      () => Row(
        children: [
          _NumField(
            label: '间距',
            value: node.layoutGap,
            enabled: node.layoutDir != 'none',
            disabledHint: '先选布局',
            onCommit: (v) => store.updateNode(node.id, {'gap': v}),
          ),
          const SizedBox(width: NonSpace.xs),
          _NumField(
            label: '内边距',
            value: node.layoutPadding,
            enabled: node.layoutDir != 'none',
            disabledHint: '先选布局',
            onCommit: (v) => store.updateNode(node.id, {'padding': v}),
          ),
        ],
      ),
      () => const SizedBox(height: NonSpace.md),
      () => const SectionLabel('内容'),
      () => const SizedBox(height: NonSpace.sm),
      () => _TextContentField(
        node: node,
        onCommit: (v) => store.updateNode(node.id, {'text': v}),
      ),
      () => const SizedBox(height: NonSpace.lg),
      () => _NodeStatesSection(
        key: ValueKey('states-${store.activeBoard}-${node.id}'),
        node: node,
        revision: store.render.revision,
      ),
      () => const SizedBox(height: NonSpace.lg),
      () => SectionLabel(
        '交互动作',
        trailing: Pill(
          label: '${nodeFlows.length + nodeInteractionsCount}',
          color: p.ink4,
        ),
      ),
      () => const SizedBox(height: NonSpace.xs),
      for (final flow in nodeFlows)
        () => Container(
          margin: const EdgeInsets.only(bottom: NonSpace.xs),
          padding: const EdgeInsets.symmetric(
            horizontal: NonSpace.sm,
            vertical: NonSpace.xs,
          ),
          decoration: BoxDecoration(
            color: p.panel2.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(NonRadius.md),
          ),
          child: Row(
            children: [
              Icon(Icons.link, size: 10, color: p.accent),
              const SizedBox(width: NonSpace.xs),
              Expanded(
                child: Text(
                  '→ ${flow.to}',
                  style: TextStyle(fontSize: NonType.caption, color: p.ink3),
                ),
              ),
              IconAction(
                icon: Icons.close,
                tooltip: '移除',
                size: 24,
                onTap: () => store.disconnectFlow(flow.to),
              ),
            ],
          ),
        ),
      () => Row(
        children: [
          Expanded(
            child: nonSelect<String>(
              context,
              value: _flowTarget,
              decoration: const InputDecoration(
                hintText: '连接到画板…',
                contentPadding: EdgeInsets.symmetric(
                  horizontal: NonSpace.sm,
                  vertical: NonSpace.sm,
                ),
              ),
              items: [
                for (final b in store.render.artboards.where(
                  (b) => b.id != store.activeBoard,
                ))
                  DropdownMenuItem(
                    value: b.id,
                    child: Text(
                      b.name.isEmpty ? b.id : b.name,
                      style: const TextStyle(fontSize: NonType.caption),
                    ),
                  ),
              ],
              onChanged: (v) => setState(() => _flowTarget = v),
            ),
          ),
          const SizedBox(width: NonSpace.xs),
          FilledButton(
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(
                horizontal: NonSpace.md,
                vertical: NonSpace.sm,
              ),
            ),
            onPressed: _flowTarget == null
                ? null
                : () async {
                    if (await store.connectFlow(_flowTarget!)) {
                      setState(() => _flowTarget = null);
                    }
                  },
            child: const Text(
              '连接',
              style: TextStyle(fontSize: NonType.caption),
            ),
          ),
        ],
      ),
      () => const SizedBox(height: NonSpace.md),
      () => _NodeInteractionsEditor(
        key: ValueKey('interact-${node.id}-${store.activeBoard}'),
        node: node,
      ),
      () => const SizedBox(height: NonSpace.lg),
      () => _PageHealthSection(
        key: ValueKey('health-${store.activeBoard ?? ''}'),
      ),
    ];
  }

  List<Widget Function()> _boardInspector(
    BuildContext context,
    AppStore store,
    List<_BoardFlow> boardFlows,
  ) {
    final p = context.palette;
    final board = store.board!;
    final flows = boardFlows;
    return <Widget Function()>[
      () => Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: p.panel2,
              borderRadius: BorderRadius.circular(NonRadius.md),
            ),
            child: Icon(Icons.layers_outlined, size: 14, color: p.accent),
          ),
          const SizedBox(width: NonSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        board.name.isEmpty ? board.id : board.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: NonType.bodyStrong,
                          fontWeight: FontWeight.w600,
                          color: p.ink,
                        ),
                      ),
                    ),
                    if (store.render.entry == board.id)
                      Padding(
                        padding: const EdgeInsets.only(left: NonSpace.xs),
                        child: Pill(
                          label: '入口',
                          color: p.accent,
                          background: p.accentSoft,
                        ),
                      ),
                  ],
                ),
                Text(
                  '${board.id} · ${board.width.round()}×${board.height.round()} · ${board.nodes.length} 节点',
                  style: TextStyle(
                    fontSize: NonType.micro,
                    fontFamily: 'Menlo',
                    color: p.ink4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      () => const SizedBox(height: NonSpace.md),
      () => const SectionLabel('画板'),
      () => const SizedBox(height: NonSpace.sm),
      () => Row(
        children: [
          _NumField(
            label: 'W',
            value: board.width,
            onCommit: (v) => store.applyOp(
              'resize-canvas ${board.id} ${v.round()} ${board.height.round()}',
            ),
          ),
          const SizedBox(width: NonSpace.xs),
          _NumField(
            label: 'H',
            value: board.height,
            onCommit: (v) => store.applyOp(
              'resize-canvas ${board.id} ${board.width.round()} ${v.round()}',
            ),
          ),
          const SizedBox(width: NonSpace.sm),
          Expanded(
            child: nonSelect<String>(
              context,
              value: _theme,
              decoration: const InputDecoration(
                contentPadding: EdgeInsets.symmetric(
                  horizontal: NonSpace.sm,
                  vertical: NonSpace.sm,
                ),
              ),
              // 运行时数据源（api.themes()，engine-0.2 的 13 项全量）；
              // 拉取失败/为空回落 6 项硬编码。frontmatter 解析出的越界
              // _theme（如 harmony）由此获得匹配项。
              items: _themes.isEmpty
                  ? const [
                      DropdownMenuItem(
                        value: 'light',
                        child: Text(
                          '浅色',
                          style: TextStyle(fontSize: NonType.caption),
                        ),
                      ),
                      DropdownMenuItem(
                        value: 'dark',
                        child: Text(
                          '深色',
                          style: TextStyle(fontSize: NonType.caption),
                        ),
                      ),
                      DropdownMenuItem(
                        value: 'high_contrast',
                        child: Text(
                          '高对比',
                          style: TextStyle(fontSize: NonType.caption),
                        ),
                      ),
                      DropdownMenuItem(
                        value: 'sepia',
                        child: Text(
                          '护眼',
                          style: TextStyle(fontSize: NonType.caption),
                        ),
                      ),
                      DropdownMenuItem(
                        value: 'nord',
                        child: Text(
                          '北境',
                          style: TextStyle(fontSize: NonType.caption),
                        ),
                      ),
                      DropdownMenuItem(
                        value: 'sunset',
                        child: Text(
                          '日落',
                          style: TextStyle(fontSize: NonType.caption),
                        ),
                      ),
                    ]
                  : [
                      for (final (id, label) in _themes)
                        DropdownMenuItem(
                          value: id,
                          child: Text(
                            _themeLabel(id, label),
                            style: const TextStyle(fontSize: NonType.caption),
                          ),
                        ),
                    ],
              onChanged: (v) async {
                if (v == null) return;
                setState(() => _theme = v);
                await store.setTheme(v);
              },
            ),
          ),
        ],
      ),
      () => const SizedBox(height: NonSpace.md),
      () => Row(
        children: [
          _MiniButton(
            label: '自动修复',
            icon: Icons.auto_fix_high,
            onTap: () => store.autoFix(),
          ),
          const SizedBox(width: NonSpace.xs),
          _MiniButton(
            label: '运行评审',
            icon: Icons.fact_check_outlined,
            onTap: () async {
              final result = await store.critique();
              setState(() => _critique = result);
            },
          ),
          const SizedBox(width: NonSpace.xs),
          _MiniButton(
            label: '让 NaN 继续',
            icon: Icons.auto_awesome,
            accent: true,
            onTap: () => store.setRightTab('agent'),
          ),
        ],
      ),
      if (_critique != null) ...[
        () => const SizedBox(height: NonSpace.lg),
        () => const SectionLabel('评审结果'),
        () => const SizedBox(height: NonSpace.xs),
        for (final result
            in (((_critique!['results'] as List?) ?? const [])
                .whereType<Map>()))
          () => Container(
            margin: const EdgeInsets.only(bottom: NonSpace.xs),
            padding: const EdgeInsets.all(NonSpace.sm),
            decoration: BoxDecoration(
              color: p.panel2.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(NonRadius.md),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        (result['principle'] ?? '').toString(),
                        style: TextStyle(
                          fontSize: NonType.caption,
                          fontWeight: FontWeight.w500,
                          color: p.ink2,
                        ),
                      ),
                    ),
                    Pill(
                      label: '${result['score']}/10',
                      color: (result['score'] as num? ?? 0) >= 8
                          ? p.success
                          : p.warn,
                    ),
                  ],
                ),
                const SizedBox(height: NonSpace.xs),
                Text(
                  (result['observation'] ?? '').toString(),
                  style: TextStyle(
                    fontSize: NonType.micro,
                    height: 1.45,
                    color: p.ink4,
                  ),
                ),
              ],
            ),
          ),
      ],
      () => const SizedBox(height: NonSpace.lg),
      () => SectionLabel(
        '本板交互',
        trailing: Pill(label: '${flows.length}', color: p.ink4),
      ),
      () => const SizedBox(height: NonSpace.xs),
      for (final flow in flows)
        () => Padding(
          padding: const EdgeInsets.only(bottom: NonSpace.xs),
          child: Row(
            children: [
              Icon(Icons.link, size: 10, color: p.accent),
              const SizedBox(width: NonSpace.xs),
              Expanded(
                child: Text(
                  '${flow.nodeId} → ${flow.to}',
                  style: TextStyle(fontSize: NonType.micro, color: p.ink3),
                ),
              ),
            ],
          ),
        ),

      // 板级能力（无需选中节点）：布局意图条 + 页面体检。
      () => const SizedBox(height: NonSpace.lg),
      () => const _ConstrainBar(),
      () => const SizedBox(height: NonSpace.md),
      () => _PageHealthSection(
        key: ValueKey('board-health-${store.activeBoard ?? ''}'),
      ),
    ];
  }
}

/// 透明度滑块：拖动期间用本地值实时跟手（store 只在 op 提交后才更新，
/// onChanged 空转会让滑块冻结、松手后瞬跳终值）；松手 onChangeEnd 才发
/// 引擎 op——与 _NumField 的「本地编辑、提交回真源」同形态。
class _OpacitySlider extends StatefulWidget {
  final double value;
  final ValueChanged<double> onCommit;
  const _OpacitySlider({required this.value, required this.onCommit});

  @override
  State<_OpacitySlider> createState() => _OpacitySliderState();
}

class _OpacitySliderState extends State<_OpacitySlider> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    return Slider(
      value: _drag ?? widget.value.clamp(0.0, 1.0),
      onChanged: (v) => setState(() => _drag = v),
      onChangeEnd: (v) {
        setState(() => _drag = null);
        widget.onCommit(double.parse(v.toStringAsFixed(2)));
      },
    );
  }
}

class _MiniButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool accent;
  const _MiniButton({
    required this.label,
    required this.icon,
    required this.onTap,
    this.accent = false,
  });

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return InkWell(
      borderRadius: BorderRadius.circular(NonRadius.md),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: NonSpace.sm,
          vertical: NonSpace.xs,
        ),
        decoration: BoxDecoration(
          color: accent ? p.accentSoft : p.panel2,
          borderRadius: BorderRadius.circular(NonRadius.md),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 11, color: accent ? p.accent : p.ink3),
            const SizedBox(width: NonSpace.xs),
            Text(
              label,
              style: TextStyle(
                fontSize: NonType.micro,
                fontWeight: FontWeight.w500,
                color: accent ? p.accent : p.ink3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NumField extends StatefulWidget {
  final String label;
  final double value;
  final ValueChanged<double> onCommit;
  final bool enabled;
  final String? disabledHint;
  const _NumField({
    required this.label,
    required this.value,
    required this.onCommit,
    this.enabled = true,
    this.disabledHint,
  });

  @override
  State<_NumField> createState() => _NumFieldState();
}

class _NumFieldState extends State<_NumField> {
  late final TextEditingController _controller = TextEditingController(
    text: _format(widget.value),
  );

  String _format(double v) =>
      v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);

  @override
  void didUpdateWidget(covariant _NumField old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value &&
        _controller.text != _format(widget.value)) {
      _controller.text = _format(widget.value);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _commit() {
    final v = double.tryParse(_controller.text);
    if (v != null && v != widget.value) widget.onCommit(v);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Expanded(
      child: SizedBox(
        // 数值行高度随有效字号缩放：1.0 倍时仍是 29（视觉不变），1.3 倍时
        // 37.7，caption 11→14.3 的输入文本不会被固定高度压扁。
        height: scaledRowHeight(context, 29),
        child: TextField(
          controller: _controller,
          enabled: widget.enabled,
          style: TextStyle(
            fontSize: NonType.caption,
            fontFamily: 'Menlo',
            color: p.ink,
          ),
          decoration: InputDecoration(
            prefixText: '${widget.label} ',
            prefixStyle: TextStyle(
              fontSize: NonType.micro,
              fontFamily: 'Menlo',
              color: p.ink4,
            ),
            hintText: widget.enabled ? null : widget.disabledHint,
            hintStyle: TextStyle(fontSize: NonType.micro, color: p.ink4),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: NonSpace.sm,
              vertical: NonSpace.xs,
            ),
          ),
          onSubmitted: (_) => _commit(),
          onTapOutside: (_) => _commit(),
        ),
      ),
    );
  }
}

class _ColorRow extends StatefulWidget {
  final String label;
  final String value;
  final ValueChanged<String> onCommit;
  const _ColorRow({
    required this.label,
    required this.value,
    required this.onCommit,
  });

  @override
  State<_ColorRow> createState() => _ColorRowState();
}

class _ColorRowState extends State<_ColorRow> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.value,
  );

  @override
  void didUpdateWidget(covariant _ColorRow old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value) _controller.text = widget.value;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _commit() {
    final v = _controller.text.trim();
    if (v.isNotEmpty && v != widget.value) widget.onCommit(v);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Row(
      children: [
        SizedBox(
          width: 50,
          child: Text(
            widget.label,
            // 50px 的定宽标签位：1.3 倍字号下「描边色」这类三字标签已接近
            // 宽度上限，单行省略而不是撑破行。
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: NonType.caption, color: p.ink3),
          ),
        ),
        Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: parseHex(widget.value),
            borderRadius: BorderRadius.circular(NonRadius.sm),
            border: Border.all(color: p.lineStrong),
          ),
        ),
        const SizedBox(width: NonSpace.xs),
        Expanded(
          child: SizedBox(
            // 取色行与数值行同一硬度：高度随字号缩放（1.0 倍时 27 不变）。
            height: scaledRowHeight(context, 27),
            child: TextField(
              controller: _controller,
              style: TextStyle(
                fontSize: NonType.micro,
                fontFamily: 'Menlo',
                color: p.ink2,
              ),
              decoration: const InputDecoration(
                contentPadding: EdgeInsets.symmetric(
                  horizontal: NonSpace.sm,
                  vertical: NonSpace.xs,
                ),
                isDense: true,
              ),
              onSubmitted: (_) => _commit(),
              onTapOutside: (_) => _commit(),
            ),
          ),
        ),
      ],
    );
  }
}

class _TextContentField extends StatefulWidget {
  final CanvasNode node;
  final ValueChanged<String> onCommit;
  const _TextContentField({required this.node, required this.onCommit});

  @override
  State<_TextContentField> createState() => _TextContentFieldState();
}

class _TextContentFieldState extends State<_TextContentField> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.node.text,
  );

  @override
  void didUpdateWidget(covariant _TextContentField old) {
    super.didUpdateWidget(old);
    if (old.node.id != widget.node.id ||
        (old.node.text != widget.node.text &&
            _controller.text != widget.node.text)) {
      _controller.text = widget.node.text;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return TextField(
      controller: _controller,
      minLines: 2,
      maxLines: 4,
      style: TextStyle(fontSize: NonType.body, height: 1.5, color: p.ink2),
      decoration: const InputDecoration(
        hintText: '节点文本',
        contentPadding: EdgeInsets.symmetric(
          horizontal: NonSpace.sm,
          vertical: NonSpace.sm,
        ),
      ),
      onSubmitted: (v) {
        if (v != widget.node.text) widget.onCommit(v);
      },
      onTapOutside: (_) {
        final v = _controller.text;
        if (v != widget.node.text) widget.onCommit(v);
      },
    );
  }
}

class _SelectField extends StatelessWidget {
  final String label;
  final String value;
  final List<String> options;
  final ValueChanged<String> onChanged;
  final bool enabled;

  /// 禁用态的占位提示（值一并隐藏，让提示可见——如 layout=none 时
  /// justify/gap/padding 被引擎静默忽略，禁用 + 提示杜绝静默丢输入）。
  final String? disabledHint;
  const _SelectField({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    this.enabled = true,
    this.disabledHint,
  });

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(fontSize: NonType.micro, color: p.ink4),
        ),
        const SizedBox(height: NonSpace.xxs),
        nonSelect<String>(
          context,
          value: enabled
              ? (options.contains(value) ? value : options.first)
              : null,
          enabled: enabled,
          hint: (!enabled && disabledHint != null) ? Text(disabledHint!) : null,
          decoration: const InputDecoration(
            contentPadding: EdgeInsets.symmetric(
              horizontal: NonSpace.sm,
              vertical: NonSpace.sm,
            ),
          ),
          items: [
            for (final o in options)
              DropdownMenuItem(
                value: o,
                child: Text(
                  o,
                  style: TextStyle(fontSize: NonType.caption, color: p.ink2),
                ),
              ),
          ],
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ],
    );
  }
}

/// Layout intent bar (session_constrain). Free-text intent like 居中 / 等宽 /
/// 网格 3, applied to the whole active artboard via store.constrainLayout.
/// On failure the same intent is re-parsed (a pure layout parse — nothing
/// commits twice) to tell cannot_parse apart from other errors: cannot_parse
/// renders the engine's intent vocabulary as tap-to-fill chips, anything else
/// shows the raw error.
class _ConstrainBar extends StatefulWidget {
  const _ConstrainBar();

  @override
  State<_ConstrainBar> createState() => _ConstrainBarState();
}

class _ConstrainBarState extends State<_ConstrainBar> {
  final _input = TextEditingController();
  bool _busy = false;
  String? _error;
  List<String> _vocab = const [];

  // Verified against the engine probe (session_constrain cannot_parse error
  // carries this vocabulary); used when the error text can't be parsed.
  static const _fallbackVocab = [
    '居中',
    '垂直居中',
    '垂直排列',
    '水平排列',
    '等宽',
    '等高',
    '等间距',
    '网格 N',
    '顶部',
    '底部',
    '放大 N',
    '缩小 N',
    '边距 N',
    '间距 N',
  ];

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  static List<String> _vocabFromError(String err) {
    final idx = err.lastIndexOf('：');
    if (idx >= 0 && idx + 1 < err.length) {
      final parts = err
          .substring(idx + 1)
          .split('|')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      if (parts.length >= 3) return parts;
    }
    return _fallbackVocab;
  }

  Future<void> _apply() async {
    final store = context.read<AppStore>();
    final ab = store.activeBoard;
    final intent = _input.text.trim();
    if (intent.isEmpty || ab == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _vocab = const [];
    });
    final ok = await store.constrainLayout(intent);
    if (!mounted) return;
    if (ok) {
      _input.clear();
      setState(() => _busy = false);
      return;
    }
    final api = store.api;
    if (store.agentBusy || api == null) {
      setState(() => _busy = false);
      return;
    }
    try {
      final probe = await api.constrainIntent(store.mbt, ab, intent);
      final err = probe['error']?.toString() ?? '';
      if (!mounted) return;
      setState(() {
        _busy = false;
        if (err.startsWith('cannot_parse')) {
          _vocab = _vocabFromError(err);
        } else {
          _error = _inspectorFailureMessage(err);
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '这次布局调整没有生效，可以换个说法再试。';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _input,
                style: TextStyle(fontSize: NonType.body, color: p.ink),
                decoration: const InputDecoration(
                  hintText: '如「居中」「等宽」「网格 3」',
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: NonSpace.sm,
                    vertical: NonSpace.sm,
                  ),
                ),
                onSubmitted: (_) => _apply(),
              ),
            ),
            const SizedBox(width: NonSpace.xs),
            _MiniButton(
              label: _busy ? '应用中…' : '应用',
              icon: Icons.auto_fix_high,
              onTap: _busy ? () {} : _apply,
            ),
          ],
        ),
        if (_vocab.isNotEmpty) ...[
          const SizedBox(height: NonSpace.sm),
          Text(
            '这句话没看懂，可以试试：',
            style: TextStyle(fontSize: NonType.micro, color: p.warn),
          ),
          const SizedBox(height: NonSpace.xs),
          Wrap(
            spacing: NonSpace.xs,
            runSpacing: NonSpace.xs,
            children: [
              for (final token in _vocab)
                InkWell(
                  borderRadius: BorderRadius.circular(NonRadius.sm),
                  onTap: () => _input.text = token.replaceAll('N', '3'),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: NonSpace.sm,
                      vertical: NonSpace.xs,
                    ),
                    decoration: BoxDecoration(
                      color: p.panel2,
                      borderRadius: BorderRadius.circular(NonRadius.sm),
                      border: Border.all(color: p.line),
                    ),
                    child: Text(
                      token,
                      style: TextStyle(fontSize: NonType.micro, color: p.ink2),
                    ),
                  ),
                ),
            ],
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: NonSpace.sm),
          Text(
            _error!,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: NonType.micro, color: p.danger),
          ),
        ],
      ],
    );
  }
}

/// Component states (session_states). Lists defined states of the selected
/// node with the current one highlighted;「切换到状态」toggles via
/// store.toggleNodeState;「定义状态」takes a state name plus an optional
/// k=v patch (fill / text_color / text / radius / font_size — engine-accepted
/// keys per store.setNodeState); an empty patch snapshots the node's current
/// look instead. Reloads whenever the document revision or the node changes,
/// and right after a successful define.
class _NodeStatesSection extends StatefulWidget {
  final CanvasNode node;
  final int revision;
  const _NodeStatesSection({
    super.key,
    required this.node,
    required this.revision,
  });

  @override
  State<_NodeStatesSection> createState() => _NodeStatesSectionState();
}

class _NodeStatesSectionState extends State<_NodeStatesSection> {
  final _name = TextEditingController();
  final _patch = TextEditingController();
  bool _loading = true;
  bool _busyDefining = false;
  String? _error;

  /// 原始诊断：只进折叠的「技术详情」，默认不展开。
  String _errorDetail = '';
  String? _defineError;
  String _current = 'default';
  List<String> _states = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _NodeStatesSection old) {
    super.didUpdateWidget(old);
    if (old.revision != widget.revision || old.node.id != widget.node.id) {
      _load();
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _patch.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final store = context.read<AppStore>();
    final api = store.api;
    final ab = store.activeBoard;
    if (api == null || ab == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final res = await api.session(store.mbt, 'session_states', ab);
      if (!mounted) return;
      final data = res['data'];
      if (res['ok'] != true || data is! List) {
        setState(() {
          _loading = false;
          _error = _inspectorFailureMessage(res['error']?.toString());
          _errorDetail = (res['error'] ?? '').toString();
        });
        return;
      }
      var current = 'default';
      var states = const <String>[];
      for (final entry in data.whereType<Map>()) {
        if ((entry['node'] ?? '').toString() == widget.node.id) {
          current = (entry['current'] ?? 'default').toString();
          states = ((entry['states'] as List?) ?? const [])
              .map((s) => s.toString())
              .toList();
          break;
        }
      }
      setState(() {
        _loading = false;
        _error = null;
        _errorDetail = '';
        _current = current;
        _states = states;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '状态读取失败，请重试';
        _errorDetail = e.toString();
      });
    }
  }

  /// Parses "k=v k=v" patch text (one space between pairs, values may contain
  /// spaces only when quoted by the engine's quoting rules — keep them single
  /// tokens here). Returns null on a malformed token or an empty result;
  /// radius/font_size are coerced to numbers so the op emits unquoted numerics.
  Map<String, dynamic>? _parsePatch(String text) {
    const numericKeys = {'radius', 'font_size'};
    final out = <String, dynamic>{};
    for (final token in text.split(RegExp(r'\s+'))) {
      if (token.isEmpty) continue;
      final i = token.indexOf('=');
      if (i <= 0 || i == token.length - 1) return null;
      final k = token.substring(0, i).trim();
      final raw = token.substring(i + 1).trim();
      if (k.isEmpty) return null;
      Object v = raw;
      if (numericKeys.contains(k)) {
        final n = double.tryParse(raw);
        if (n != null) v = n;
      }
      out[k] = v;
    }
    return out.isEmpty ? null : out;
  }

  Future<void> _define() async {
    final store = context.read<AppStore>();
    final name = _name.text.trim();
    if (name.isEmpty || store.agentBusy || _busyDefining) return;
    final node = widget.node;
    final patchText = _patch.text.trim();
    Map<String, dynamic> patch;
    if (patchText.isEmpty) {
      // No patch typed: snapshot the node's current look.
      patch = {
        'fill': node.style.fill,
        'text_color': node.style.textColor,
        'radius': node.style.radius,
        'font_size': node.style.fontSize,
      };
    } else {
      final parsed = _parsePatch(patchText);
      if (parsed == null) {
        setState(
          () => _defineError = '补丁格式不对：写成「键=值」，用空格分隔，例如 fill=#FF5722 radius=8。',
        );
        return;
      }
      patch = parsed;
    }
    setState(() {
      _defineError = null;
      _busyDefining = true;
    });
    final ok = await store.setNodeState(node.id, name, patch);
    if (!mounted) return;
    setState(() => _busyDefining = false);
    if (ok) {
      _name.clear();
      _patch.clear();
      await _load(); // refresh the state list now that the state is defined
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionLabel(
          '组件状态',
          trailing: _loading
              ? SizedBox(
                  width: 10,
                  height: 10,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.4,
                    color: p.ink4,
                  ),
                )
              : Pill(
                  label: '当前 $_current',
                  color: _current == 'default' ? p.ink4 : p.accent,
                ),
        ),
        const SizedBox(height: NonSpace.sm),
        if (_error != null)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _error!,
                style: TextStyle(fontSize: NonType.micro, color: p.danger),
              ),
              if (_errorDetail.isNotEmpty)
                _InspectorDetails(text: _errorDetail),
            ],
          )
        else ...[
          if (_states.isEmpty)
            Text(
              '未定义状态。定义后可一键切换节点外观。',
              style: TextStyle(fontSize: NonType.micro, color: p.ink4),
            )
          else
            for (final state in _states)
              Container(
                margin: const EdgeInsets.only(bottom: NonSpace.xs),
                padding: const EdgeInsets.symmetric(
                  horizontal: NonSpace.sm,
                  vertical: NonSpace.xs,
                ),
                decoration: BoxDecoration(
                  color: state == _current
                      ? p.accentSoft
                      : p.panel2.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(NonRadius.md),
                  border: Border.all(
                    color: state == _current
                        ? p.accent.withValues(alpha: 0.4)
                        : Colors.transparent,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.tune,
                      size: 10,
                      color: state == _current ? p.accent : p.ink4,
                    ),
                    const SizedBox(width: NonSpace.xs),
                    Expanded(
                      child: Text(
                        state,
                        style: TextStyle(
                          fontSize: NonType.caption,
                          fontFamily: 'Menlo',
                          color: state == _current ? p.accent : p.ink2,
                        ),
                      ),
                    ),
                    if (state == _current)
                      Pill(label: '当前', color: p.accent)
                    else
                      _MiniButton(
                        label: '切换到状态',
                        icon: Icons.swap_horiz,
                        onTap: () => context.read<AppStore>().toggleNodeState(
                          widget.node.id,
                          state,
                        ),
                      ),
                  ],
                ),
              ),
          const SizedBox(height: NonSpace.xs),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _name,
                  style: TextStyle(
                    fontSize: NonType.caption,
                    fontFamily: 'Menlo',
                    color: p.ink,
                  ),
                  decoration: const InputDecoration(
                    hintText: '状态名，如 pressed / disabled',
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: NonSpace.sm,
                      vertical: NonSpace.sm,
                    ),
                  ),
                  onSubmitted: (_) => _define(),
                ),
              ),
              const SizedBox(width: NonSpace.xs),
              _MiniButton(
                label: _busyDefining ? '定义中…' : '定义状态',
                icon: Icons.add_circle_outline,
                onTap: _busyDefining ? () {} : _define,
              ),
            ],
          ),
          const SizedBox(height: NonSpace.xs),
          TextField(
            controller: _patch,
            enabled: !_busyDefining,
            style: TextStyle(
              fontSize: NonType.caption,
              fontFamily: 'Menlo',
              color: p.ink,
            ),
            decoration: const InputDecoration(
              hintText: '外观补丁，如 fill=#FF5722 radius=8（留空则记录当前外观）',
              contentPadding: EdgeInsets.symmetric(
                horizontal: NonSpace.sm,
                vertical: NonSpace.sm,
              ),
            ),
            onSubmitted: (_) => _define(),
          ),
          const SizedBox(height: NonSpace.xs),
          Text(
            '可用键：填充（fill）、文字色（text_color）、文本（text）、圆角（radius）、字号（font_size）；补丁留空时记录节点当前外观。',
            style: TextStyle(
              fontSize: NonType.micro,
              height: 1.4,
              color: p.ink4,
            ),
          ),
          if (_defineError != null) ...[
            const SizedBox(height: NonSpace.xs),
            Text(
              _defineError!,
              style: TextStyle(fontSize: NonType.micro, color: p.danger),
            ),
          ],
        ],
      ],
    );
  }
}

/// Page health cards (session_infer_missing + session_infer_page_type), both
/// board-scoped. Results render as dark cards per the inspector style. The
/// current engine build returns signals (node-kind counts) rather than a
/// confidence number for page type — a confidence field is shown when present.
class _PageHealthSection extends StatefulWidget {
  const _PageHealthSection({super.key});

  @override
  State<_PageHealthSection> createState() => _PageHealthSectionState();
}

class _PageHealthSectionState extends State<_PageHealthSection> {
  Map<String, dynamic>? _missing;
  Map<String, dynamic>? _pageType;
  String? _missingError;
  String? _typeError;

  /// 原始诊断（只进折叠的「技术详情」）。
  String _missingDetail = '';
  String _typeDetail = '';
  bool _busyMissing = false;
  bool _busyType = false;
  bool _busyFill = false;

  Future<void> _runMissing() async {
    final store = context.read<AppStore>();
    final ab = store.activeBoard;
    if (ab == null || store.agentBusy || _busyMissing) return;
    setState(() {
      _busyMissing = true;
      _missingError = null;
      _missing = null;
    });
    try {
      final res = await store.inferMissing(ab);
      if (!mounted) return;
      if (res == null) {
        setState(() {
          _busyMissing = false;
          _missingError = _inspectorFailureMessage('engine_unavailable');
          _missingDetail = 'engine_unavailable';
        });
      } else if (res['ok'] == false) {
        setState(() {
          _busyMissing = false;
          _missingError = _inspectorFailureMessage(res['error']?.toString());
          _missingDetail = (res['error'] ?? '').toString();
        });
      } else {
        setState(() {
          _busyMissing = false;
          _missingError = null;
          _missingDetail = '';
          _missing = res;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busyMissing = false;
        _missingError = '缺失体检失败，请重试';
        _missingDetail = e.toString();
      });
    }
  }

  Future<void> _runPageType() async {
    final store = context.read<AppStore>();
    final ab = store.activeBoard;
    if (ab == null || store.agentBusy || _busyType) return;
    setState(() {
      _busyType = true;
      _typeError = null;
      _pageType = null;
    });
    try {
      final res = await store.inferPageType(ab);
      if (!mounted) return;
      if (res == null) {
        setState(() {
          _busyType = false;
          _typeError = _inspectorFailureMessage('engine_unavailable');
          _typeDetail = 'engine_unavailable';
        });
      } else if (res['ok'] == false) {
        setState(() {
          _busyType = false;
          _typeError = _inspectorFailureMessage(res['error']?.toString());
          _typeDetail = (res['error'] ?? '').toString();
        });
      } else {
        setState(() {
          _busyType = false;
          _typeError = null;
          _typeDetail = '';
          _pageType = res;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busyType = false;
        _typeError = '页型判定失败，请重试';
        _typeDetail = e.toString();
      });
    }
  }

  /// 页型档位 → 界面文案。未收录的类型不把 snake_case 代号摆上屏
  /// （单英文词照原样显示，那是引擎给的名字，不是错误码）。
  static String _pageTypeLabel(String raw) {
    switch (raw) {
      case '':
        return '';
      case 'list':
        return '列表页';
      case 'detail':
        return '详情页';
      case 'form':
        return '表单页';
      case 'dashboard':
        return '看板页';
      case 'landing':
        return '落地页';
      case 'settings':
        return '设置页';
      case 'empty':
        return '空状态页';
      case 'checkout':
        return '结算页';
      case 'profile':
        return '个人页';
    }
    return raw.contains('_') ? '其他页面' : raw;
  }

  /// Materialize the infer_missing report into real nodes via the engine's
  /// autofill op (verified on both human+agent gates; idempotent — the engine
  /// runs auto_fix afterwards to settle overlaps). Engine issue #25: only
  /// shells and placeholder copy are materialized; domain-semantic containers
  /// (mock_missing) still need NaN or manual content, ≥2 rows each.
  Future<void> _runFill() async {
    final store = context.read<AppStore>();
    final ab = store.activeBoard;
    if (ab == null || store.agentBusy || _busyFill) return;
    setState(() => _busyFill = true);
    try {
      final ok = await store.applyOp('autofill $ab');
      if (!mounted) return;
      if (ok) await _runMissing(); // refresh the report against real nodes
    } finally {
      if (mounted) setState(() => _busyFill = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final missing = _missing;
    final pageType = _pageType;
    final missingList = ((missing?['missing'] as List?) ?? const [])
        .whereType<Map>()
        .toList();
    final missingCount =
        (missing?['missing_count'] as num?)?.toInt() ?? missingList.length;
    final pageTypeName = _pageTypeLabel(
      (pageType?['page_type'] ?? '').toString(),
    );
    final signals = pageType?['signals'];
    final confidence = pageType?['confidence'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionLabel('页面体检'),
        const SizedBox(height: NonSpace.sm),
        Wrap(
          spacing: NonSpace.xs,
          runSpacing: NonSpace.xs,
          children: [
            _MiniButton(
              label: _busyMissing ? '体检中…' : '缺失体检',
              icon: Icons.rule,
              onTap: _busyMissing ? () {} : _runMissing,
            ),
            _MiniButton(
              label: _busyType ? '判定中…' : '页型判定',
              icon: Icons.category_outlined,
              onTap: _busyType ? () {} : _runPageType,
            ),
            _MiniButton(
              label: '自动修复',
              icon: Icons.auto_fix_high,
              onTap: () => context.read<AppStore>().autoFix(),
            ),
            _MiniButton(
              label: _busyFill ? '填充中…' : '一键内容填充',
              icon: Icons.format_color_fill,
              onTap: _busyFill ? () {} : _runFill,
            ),
          ],
        ),
        const SizedBox(height: NonSpace.xs),
        Text(
          '一键填充只补齐外壳与占位文字；具体业务内容（占位标记的容器）还要让 NaN 补或手动填，每个容器至少 2 条。',
          style: TextStyle(fontSize: NonType.micro, height: 1.4, color: p.ink4),
        ),
        if (_missingError != null) ...[
          const SizedBox(height: NonSpace.sm),
          Text(
            _missingError!,
            style: TextStyle(fontSize: NonType.micro, color: p.danger),
          ),
          if (_missingDetail.isNotEmpty)
            _InspectorDetails(text: _missingDetail),
        ],
        if (_typeError != null) ...[
          const SizedBox(height: NonSpace.sm),
          Text(
            _typeError!,
            style: TextStyle(fontSize: NonType.micro, color: p.danger),
          ),
          if (_typeDetail.isNotEmpty) _InspectorDetails(text: _typeDetail),
        ],
        if (missing != null) ...[
          const SizedBox(height: NonSpace.sm),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(NonSpace.sm),
            decoration: BoxDecoration(
              color: p.panel2.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(NonRadius.md),
              border: Border.all(
                color: missingCount > 0
                    ? p.warn.withValues(alpha: 0.25)
                    : p.success.withValues(alpha: 0.25),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      missingCount > 0
                          ? Icons.warning_amber_rounded
                          : Icons.check_circle_outline,
                      size: 12,
                      color: missingCount > 0 ? p.warn : p.success,
                    ),
                    const SizedBox(width: NonSpace.xs),
                    Text(
                      missingCount > 0 ? '缺失 $missingCount 项建议' : '未发现缺失',
                      style: TextStyle(
                        fontSize: NonType.caption,
                        fontWeight: FontWeight.w600,
                        color: missingCount > 0 ? p.warn : p.success,
                      ),
                    ),
                    const Spacer(),
                    if ((missing['page_type'] ?? '').toString().isNotEmpty)
                      Pill(
                        label:
                            '页型 ${_pageTypeLabel((missing['page_type'] ?? '').toString())}',
                        color: p.ink4,
                      ),
                  ],
                ),
                for (final item in missingList) ...[
                  const SizedBox(height: NonSpace.sm),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: NonSpace.xs,
                          vertical: NonSpace.xxs,
                        ),
                        decoration: BoxDecoration(
                          color: p.panel3,
                          borderRadius: BorderRadius.circular(NonRadius.sm),
                        ),
                        child: Text(
                          (item['element'] ?? '').toString(),
                          style: TextStyle(
                            fontSize: NonType.micro,
                            fontFamily: 'Menlo',
                            color: p.ink3,
                          ),
                        ),
                      ),
                      const SizedBox(width: NonSpace.sm),
                      Expanded(
                        child: Text(
                          (item['suggestion'] ?? '').toString(),
                          style: TextStyle(
                            fontSize: NonType.micro,
                            height: 1.4,
                            color: p.ink3,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
        if (pageType != null) ...[
          const SizedBox(height: NonSpace.sm),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(NonSpace.sm),
            decoration: BoxDecoration(
              color: p.panel2.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(NonRadius.md),
              border: Border.all(color: p.accent.withValues(alpha: 0.25)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.category, size: 12, color: p.accent),
                    const SizedBox(width: NonSpace.xs),
                    Text(
                      '页型判定',
                      style: TextStyle(
                        fontSize: NonType.caption,
                        fontWeight: FontWeight.w600,
                        color: p.ink2,
                      ),
                    ),
                    const Spacer(),
                    if (pageTypeName.isNotEmpty)
                      Pill(label: pageTypeName, color: p.accent),
                  ],
                ),
                if (confidence is num) ...[
                  const SizedBox(height: NonSpace.xs),
                  Text(
                    '置信度 ${(confidence * 100).toStringAsFixed(0)}%',
                    style: TextStyle(fontSize: NonType.micro, color: p.ink3),
                  ),
                ],
                if (signals is Map && signals.isNotEmpty)
                  _InspectorDetails(
                    text: signals.entries
                        .map((e) => '${e.key}: ${e.value}')
                        .join('\n'),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// 节点交互动作编辑器：列出该节点已有 interact 标记（引擎 session_interactions），
/// 并提供 trigger + action + 参数的添加表单（写引擎 `interact` op）。
class _NodeInteractionsEditor extends StatefulWidget {
  final CanvasNode node;
  const _NodeInteractionsEditor({super.key, required this.node});

  @override
  State<_NodeInteractionsEditor> createState() =>
      _NodeInteractionsEditorState();
}

class _NodeInteractionsEditorState extends State<_NodeInteractionsEditor> {
  String _trigger = 'tap';
  String _action = 'show_toast';
  final _message = TextEditingController();
  String? _targetBoard;
  String? _targetNode;
  final _extraText = TextEditingController();
  List<Map<String, dynamic>> _entries = [];
  // 最近一次 session_interactions 拉取失败的原因；失败保留旧 _entries，
  // 行内提示（不再让超时/网络错冒成未处理 async 异常）。
  String? _refreshError;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void didUpdateWidget(covariant _NodeInteractionsEditor old) {
    super.didUpdateWidget(old);
    if (old.node.id != widget.node.id) _refresh();
  }

  @override
  void dispose() {
    _message.dispose();
    _extraText.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final store = context.read<AppStore>();
    if (store.api == null || store.activeBoard == null) return;
    try {
      final res = await store.api!
          .session(store.mbt, 'session_interactions', store.activeBoard!)
          .timeout(const Duration(seconds: 15));
      if (!mounted) return;
      final items = (res['data'] as List?) ?? const [];
      setState(() {
        _entries = items
            .whereType<Map>()
            .where((m) => m['node']?.toString() == widget.node.id)
            .map((m) => Map<String, dynamic>.from(m))
            .toList();
        _refreshError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _refreshError = e.toString());
    }
  }

  Future<void> _add() async {
    final store = context.read<AppStore>();
    if (_busy) return;
    String spec;
    switch (_action) {
      case 'back':
      case 'haptic':
        spec = _action;
      case 'navigate_to':
        final t = _targetBoard;
        if (t == null || t.isEmpty) return;
        spec = 'navigate_to:$t';
      case 'show_toast':
        final t = _message.text.trim();
        if (t.isEmpty) return;
        spec = 'show_toast:$t';
      case 'set_text':
        final target = _extraText.text.trim();
        final t = _message.text.trim();
        if (target.isEmpty || t.isEmpty) return;
        spec = 'set_text:$target:$t';
      case 'set_state':
        final t = _message.text.trim();
        if (t.isEmpty) return;
        spec = 'set_state:${widget.node.id}:$t';
      case 'toggle_state':
        final t = _message.text.trim();
        if (t.isEmpty) return;
        spec = 'toggle_state:$t';
      case 'play_sound':
        final t = _message.text.trim();
        if (t.isEmpty) return;
        spec = 'play_sound:$t';
      default:
        return;
    }
    setState(() => _busy = true);
    final ok = await store.interactNode(widget.node.id, _trigger, spec);
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      _message.clear();
      _extraText.clear();
      await _refresh();
    } else {
      store.toasts.error('这次交互没有加上', '换个动作或检查一下参数再试。');
    }
  }

  /// 触发方式 -> 界面文案（引擎词表在括号里保留，方便对照文档）。
  static String _triggerLabel(String trigger) => switch (trigger) {
    'tap' => '轻点',
    'long_press' => '长按',
    'swipe_left' => '左滑',
    'swipe_right' => '右滑',
    'swipe_up' => '上滑',
    'swipe_down' => '下滑',
    'scroll_end' => '滚动到底',
    'key_enter' => '回车',
    'focus' => '获得焦点',
    'blur' => '失去焦点',
    _ => trigger,
  };

  static String _actionLabel(String kind) => switch (kind) {
    'show_toast' => '显示提示',
    'navigate_to' => '跳转画板',
    'set_text' => '改文字',
    'set_state' => '设状态',
    'toggle_state' => '切状态',
    'haptic' => '震动反馈',
    'play_sound' => '播放音效',
    'back' => '返回',
    _ => '交互动作',
  };

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final board = context.watch<AppStore>().board;
    final boards = context.watch<AppStore>().render.artboards;
    final isBack = _action == 'back';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 已有交互：session_interactions 拉回的本节点绑定（trigger → action），
        // 按触发方式分组展示，右侧「解绑」走 uninteract op（引擎按节点整体解绑，
        // 不支持按单条解绑——同节点多条绑定会一并移除，与引擎 op 语义一致）。
        if (_refreshError != null)
          Padding(
            padding: const EdgeInsets.only(bottom: NonSpace.xs),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '交互列表没有刷新出来，请重试',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: NonType.micro, color: p.warn),
                ),
                _InspectorDetails(text: _refreshError!),
              ],
            ),
          ),
        if (_entries.isNotEmpty) ...[
          for (final e in _entries)
            Padding(
              padding: const EdgeInsets.only(bottom: NonSpace.xs),
              child: Row(
                children: [
                  Icon(Icons.bolt, size: 11, color: p.accent),
                  const SizedBox(width: NonSpace.xs),
                  Expanded(
                    child: Text(
                      '${_triggerLabel((e['trigger'] ?? 'tap').toString())} → ${_actionLabel((e['action'] ?? '').toString())}',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: NonType.caption,
                        color: p.ink3,
                      ),
                    ),
                  ),
                  InkWell(
                    onTap: _busy
                        ? null
                        : () async {
                            setState(() => _busy = true);
                            await context.read<AppStore>().uninteractNode(
                              widget.node.id,
                            );
                            if (!mounted) return;
                            setState(() => _busy = false);
                            await _refresh();
                          },
                    child: Text(
                      '解绑',
                      style: TextStyle(
                        fontSize: NonType.micro,
                        color: p.danger,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: NonSpace.xs),
        ],
        Row(
          children: [
            SizedBox(
              width: 108,
              child: nonSelect<String>(
                context,
                value: _trigger,
                decoration: const InputDecoration(
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: NonSpace.sm,
                    vertical: NonSpace.sm,
                  ),
                ),
                items: [
                  for (final t in [
                    'tap',
                    'long_press',
                    'swipe_left',
                    'swipe_right',
                    'swipe_up',
                    'swipe_down',
                    'scroll_end',
                    'key_enter',
                    'focus',
                    'blur',
                  ])
                    DropdownMenuItem(
                      value: t,
                      child: Text(
                        _triggerLabel(t),
                        style: TextStyle(fontSize: NonType.caption),
                      ),
                    ),
                ],
                onChanged: (v) => setState(() => _trigger = v ?? 'tap'),
              ),
            ),
            const SizedBox(width: NonSpace.xs),
            Expanded(
              child: nonSelect<String>(
                context,
                value: _action,
                decoration: const InputDecoration(
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: NonSpace.sm,
                    vertical: NonSpace.sm,
                  ),
                ),
                items: [
                  for (final t in [
                    'show_toast',
                    'navigate_to',
                    'set_text',
                    'set_state',
                    'toggle_state',
                    'haptic',
                    'play_sound',
                    'back',
                  ])
                    DropdownMenuItem(
                      value: t,
                      child: Text(
                        _actionLabel(t),
                        style: const TextStyle(fontSize: NonType.caption),
                      ),
                    ),
                ],
                onChanged: (v) => setState(() => _action = v ?? 'show_toast'),
              ),
            ),
          ],
        ),
        if (_action == 'show_toast')
          Padding(
            padding: const EdgeInsets.only(top: NonSpace.xs),
            child: TextField(
              controller: _message,
              style: const TextStyle(fontSize: NonType.caption),
              decoration: const InputDecoration(
                hintText: '提示文案',
                contentPadding: EdgeInsets.symmetric(
                  horizontal: NonSpace.sm,
                  vertical: NonSpace.sm,
                ),
              ),
              onSubmitted: (_) => _add(),
            ),
          ),
        if (_action == 'set_text') ...[
          Padding(
            padding: const EdgeInsets.only(top: NonSpace.xs),
            child: nonSelect<String>(
              context,
              value: _targetNode,
              hint: const Text(
                '目标节点',
                style: TextStyle(fontSize: NonType.caption),
              ),
              items: [
                for (final n in (board?.nodes ?? const <CanvasNode>[]))
                  DropdownMenuItem(
                    value: n.id,
                    child: Text(
                      n.id,
                      style: const TextStyle(fontSize: NonType.caption),
                    ),
                  ),
              ],
              onChanged: (v) => setState(() => _targetNode = v),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: NonSpace.xs),
            child: TextField(
              controller: _extraText,
              style: const TextStyle(fontSize: NonType.caption),
              decoration: const InputDecoration(
                hintText: '新文字',
                contentPadding: EdgeInsets.symmetric(
                  horizontal: NonSpace.sm,
                  vertical: NonSpace.sm,
                ),
              ),
              onSubmitted: (_) => _add(),
            ),
          ),
        ],
        if (_action == 'set_state' || _action == 'toggle_state')
          Padding(
            padding: const EdgeInsets.only(top: NonSpace.xs),
            child: TextField(
              controller: _message,
              style: const TextStyle(fontSize: NonType.caption),
              decoration: const InputDecoration(
                hintText: '状态名',
                contentPadding: EdgeInsets.symmetric(
                  horizontal: NonSpace.sm,
                  vertical: NonSpace.sm,
                ),
              ),
              onSubmitted: (_) => _add(),
            ),
          ),
        if (_action == 'navigate_to')
          Padding(
            padding: const EdgeInsets.only(top: NonSpace.xs),
            // 画板下拉（nonSelect）：替代手输画板 id——boards/_targetBoard
            // 由这里消费，_add 的 navigate_to 分支取 _targetBoard。
            child: nonSelect<String>(
              context,
              value: _targetBoard,
              hint: const Text(
                '目标画板',
                style: TextStyle(fontSize: NonType.caption),
              ),
              items: [
                for (final b in boards)
                  DropdownMenuItem(
                    value: b.id,
                    child: Text(
                      b.name.isEmpty ? b.id : b.name,
                      style: const TextStyle(fontSize: NonType.caption),
                    ),
                  ),
              ],
              onChanged: (v) => setState(() => _targetBoard = v),
            ),
          ),
        if (_action == 'play_sound')
          Padding(
            padding: const EdgeInsets.only(top: NonSpace.xs),
            child: TextField(
              controller: _message,
              style: const TextStyle(fontSize: NonType.caption),
              decoration: const InputDecoration(
                hintText: '音效名',
                contentPadding: EdgeInsets.symmetric(
                  horizontal: NonSpace.sm,
                  vertical: NonSpace.sm,
                ),
              ),
              onSubmitted: (_) => _add(),
            ),
          ),
        const SizedBox(height: NonSpace.sm),
        // 统一提交入口：back / haptic 无参数框，此前没有任何提交控件，
        // 动作永远加不上——所有动作都可经此按钮提交。
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: _busy ? null : _add,
            child: const Text(
              '添加',
              style: TextStyle(fontSize: NonType.caption),
            ),
          ),
        ),
        if (isBack)
          Padding(
            padding: const EdgeInsets.only(bottom: NonSpace.xs),
            child: Text(
              '「返回」由应用内置处理，演示模式里点按即生效。',
              style: TextStyle(fontSize: NonType.micro, color: p.ink4),
            ),
          ),
      ],
    );
  }
}

/// 引擎失败码 → 一句人话（`docs/copy-glossary.md` §4 的子集）。
///
/// 检查器只调引擎的检视/变更接口，未在表内的码统一落到「这次操作没有成功，
/// 请重试」；原始码由调用方放进折叠的 [技术详情]。
String _inspectorFailureMessage(String? raw) {
  final code = (raw ?? '').trim().split(':').first.trim();
  return switch (code) {
    'engine_unavailable' => '设计服务暂时不可用，请稍后重试',
    'engine_timeout' => '这次操作耗时过长，已安全停止',
    'engine_trap' => '设计服务刚刚重启，请重试',
    'engine_fuel_exhausted' => '这次操作太大，已安全停止，可以拆小再试',
    'mbt_gate_block' || 'engine_gate_failed' => '这次改动未通过设计校验',
    'render_failed' => '预览生成失败',
    _ => '这次操作没有成功，请重试',
  };
}

/// 折叠的「技术详情」：原始诊断（引擎码、异常文本）只在这里出现，默认不展开。
class _InspectorDetails extends StatelessWidget {
  final String text;
  const _InspectorDetails({required this.text});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: NonSpace.sm),
        dense: true,
        title: Text(
          '技术详情',
          style: TextStyle(
            fontSize: NonType.micro,
            color: p.ink4,
            fontWeight: FontWeight.w600,
          ),
        ),
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(NonSpace.sm),
            decoration: BoxDecoration(
              color: p.panel2,
              borderRadius: BorderRadius.circular(NonRadius.sm),
            ),
            child: SelectableText(
              text,
              style: TextStyle(
                fontSize: NonType.micro,
                fontFamily: 'Menlo',
                color: p.ink4,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
