import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/models.dart';
import '../core/keys.dart';
import '../core/store.dart';
import '../core/theme.dart';
import 'common.dart';
import 'workspace.dart' show openProjectFlow;

class LeftPanel extends StatelessWidget {
  const LeftPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final p = context.palette;
    return Container(
      width: 252,
      decoration: BoxDecoration(
        color: p.bgElevated.withValues(alpha: 0.82),
        border: Border(right: BorderSide(color: p.line)),
      ),
      child: switch (store.panel) {
        'docs' => const _DocsPanel(),
        'spec' => const _SpecPanel(),
        'history' => const _HistoryPanel(),
        _ => const _ProjectPanel(),
      },
    );
  }
}

class _PanelHead extends StatelessWidget {
  final String title;
  final List<Widget> actions;
  const _PanelHead(this.title, {this.actions = const []});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: p.line))),
      child: Row(
        children: [
          Text(title.toUpperCase(),
              style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1.2, color: p.ink3)),
          const Spacer(),
          ...actions,
        ],
      ),
    );
  }
}

class _ProjectPanel extends StatelessWidget {
  const _ProjectPanel();

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final p = context.palette;
    final board = store.board;
    // 行工厂惰性构建：画板/图层/流程/最近项目同列，ListView(children:)
    // 每次 ~12.5Hz 通知都全量建行；builder 只建可视行（行 widget 自身
    // 已各自 watch，构造闭包廉价）。
    final items = <Widget Function()>[
      for (final b in store.render.artboards) () => _BoardRow(board: b, active: b.id == store.activeBoard),
      if (store.render.artboards.isEmpty)
        () => Padding(
              padding: const EdgeInsets.all(12),
              child: Text('还没有画板——让 NoN 生成，或点面板顶部 ＋ 新建。',
                  style: TextStyle(fontSize: 11, height: 1.5, color: p.ink4)),
            ),
      if (board != null) ...[
        () => const SizedBox(height: 14),
        () => SectionLabel('图层 · ${board.nodes.length}'),
        () => const SizedBox(height: 6),
        for (final node in board.nodes.reversed) () => _LayerRow(node: node),
      ],
      if (store.render.flows.isNotEmpty) ...[
        () => const SizedBox(height: 14),
        () => SectionLabel('流程 · ${store.render.flows.length}'),
        () => const SizedBox(height: 6),
        for (final flow in store.render.flows.take(16))
          () => InkWell(
                onTap: () {
                  store.selectBoard(flow.from);
                  store.selectNode(flow.nodeId);
                },
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                  child: Row(
                    children: [
                      Icon(Icons.link, size: 11, color: p.ink4),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text('${flow.from} → ${flow.to}',
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11, color: p.ink3)),
                      ),
                    ],
                  ),
                ),
              ),
      ],
      if (store.recent.isNotEmpty) ...[
        () => const SizedBox(height: 16),
        () => SectionLabel('最近项目'),
        () => const SizedBox(height: 4),
        for (final r in store.recent.take(5))
          () => InkWell(
                // 与 welcome 的最近项目列表同一入口：带路径直接打开
                // （免对话框，需密码时 openProjectFlow 自行追问）。
                onTap: () => openProjectFlow(context, r['path']?.toString() ?? ''),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                  child: Text((r['name'] ?? '').toString(),
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: p.ink4)),
                ),
              ),
      ],
    ];
    return Column(
      children: [
        _PanelHead('画板', actions: [
          BoardTemplateMenu(
            store: store,
            offset: const Offset(0, 34),
            child: SizedBox(
              width: 26,
              height: 26,
              child: Icon(Icons.add, size: 17, color: p.ink3),
            ),
          ),
        ]),
        Expanded(
          child: ListView.builder(
            // 面板内容 padding 统一 12（四档 8/10/11/12 → 一档；底部 16 余量并入）。
            padding: const EdgeInsets.all(12),
            itemCount: items.length,
            itemBuilder: (context, i) => items[i](),
          ),
        ),
      ],
    );
  }
}

class _BoardRow extends StatelessWidget {
  final Artboard board;
  final bool active;
  const _BoardRow({required this.board, required this.active});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final p = context.palette;
    return Material(
      color: active ? p.panel2 : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => store.selectBoard(board.id),
        child: Container(
          padding: const EdgeInsets.all(5),
          margin: const EdgeInsets.only(bottom: 2),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: active ? p.lineStrong : Colors.transparent),
          ),
          child: Row(
            children: [
              Container(
                width: 30,
                height: 42,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: p.line),
                ),
                clipBehavior: Clip.antiAlias,
                child: CustomPaint(painter: BoardMiniPainter(board)),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(board.name.isEmpty ? board.id : board.name,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: p.ink)),
                        ),
                        if (store.render.entry == board.id) Pill(label: '入口', color: p.accent, background: p.accentSoft),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text('${board.width.round()}×${board.height.round()} · ${board.nodes.length} 节点',
                        style: TextStyle(fontSize: 10, fontFamily: 'Menlo', color: p.ink4)),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                tooltip: '画板操作',
                padding: EdgeInsets.zero,
                icon: Icon(Icons.more_horiz, size: 15, color: p.ink4),
                color: p.panel,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: p.lineStrong)),
                onSelected: (v) {
                  if (v == 'dup') store.duplicateBoard(board.id);
                  if (v == 'del') store.deleteBoard(board.id);
                  if (v == 'responsive') _runResponsive(context, store, board.id);
                },
                itemBuilder: (context) => [
                  PopupMenuItem(value: 'dup', child: Text('复制画板', style: TextStyle(fontSize: 12, color: p.ink2))),
                  PopupMenuItem(value: 'responsive', child: Text('响应式适配', style: TextStyle(fontSize: 12, color: p.ink2))),
                  if (store.render.artboards.length > 1)
                    PopupMenuItem(value: 'del', child: Text('删除画板', style: TextStyle(fontSize: 12, color: p.danger))),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LayerRow extends StatelessWidget {
  final CanvasNode node;
  const _LayerRow({required this.node});

  // 组件名→图标匹配：静态编译一次。此前每行每次 build 现场编译 6 个
  // RegExp——agent 运行期 ~12.5Hz × 40 节点 ≈ 3000 次/秒。
  static final RegExp _iconText = RegExp(r'heading|body_text|link|kbd');
  static final RegExp _iconImage = RegExp(r'image|avatar|lightbox');
  static final RegExp _iconButton = RegExp(r'button|chip|tag|badge|fab');
  static final RegExp _iconInput = RegExp(r'input|search|textarea|select|checkbox|switch|radio');
  static final RegExp _iconRule = RegExp(r'divider|progress|meter|slider');
  static final RegExp _iconBar = RegExp(r'app_bar|navbar|bottom_nav|tab_bar|menu|pagination');

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final p = context.palette;
    final active = store.selectedNode == node.id;
    final depth = node.parent != 'root' ? 1 : 0;
    return InkWell(
      onTap: () => store.selectNode(node.id),
      borderRadius: BorderRadius.circular(6),
      child: Container(
        height: 27,
        margin: const EdgeInsets.only(bottom: 1),
        padding: EdgeInsets.only(left: 5 + depth * 12, right: 3),
        decoration: BoxDecoration(
          color: active ? p.accentSoft : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            Icon(_nodeIcon(node.component), size: 12, color: active ? p.accent : p.ink4),
            const SizedBox(width: 5),
            Expanded(
              child: Text(
                node.text.trim().isNotEmpty ? node.text.trim() : (node.name.isNotEmpty ? node.name : node.id),
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: active ? p.accent : p.ink2),
              ),
            ),
            IconButton(
              tooltip: node.style.visible ? '隐藏' : '显示',
              onPressed: () => store.updateNode(node.id, {'visible': !node.style.visible}),
              icon: Icon(node.style.visible ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 11),
              color: p.ink4,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
              padding: EdgeInsets.zero,
            ),
            IconButton(
              tooltip: '上移一层',
              onPressed: () => store.reorderNode(node.id, 'up'),
              icon: const Icon(Icons.arrow_upward, size: 11),
              color: p.ink4,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
              padding: EdgeInsets.zero,
            ),
            IconButton(
              tooltip: '下移一层',
              onPressed: () => store.reorderNode(node.id, 'down'),
              icon: const Icon(Icons.arrow_downward, size: 11),
              color: p.ink4,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
              padding: EdgeInsets.zero,
            ),
          ],
        ),
      ),
    );
  }

  IconData _nodeIcon(String component) {
    if (_iconText.hasMatch(component)) return Icons.text_fields;
    if (_iconImage.hasMatch(component)) return Icons.image_outlined;
    if (_iconButton.hasMatch(component)) return Icons.smart_button_outlined;
    if (_iconInput.hasMatch(component)) return Icons.input;
    if (_iconRule.hasMatch(component)) return Icons.horizontal_rule;
    if (_iconBar.hasMatch(component)) return Icons.layers_outlined;
    return Icons.crop_square;
  }
}

class _DocsPanel extends StatelessWidget {
  const _DocsPanel();

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final p = context.palette;
    final docs = store.docs;
    return Column(
      children: [
        const _PanelHead('设计文档'),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              _docCard(context, Icons.description_outlined, '产品需求 PRD',
                  docs.prd.trim().isEmpty ? '还没有生成——描述产品，NoN 会先写文档' : '${docs.prd.replaceAll(RegExp(r'\s'), '').length} 字 · 目标 / 流程 / 页面清单',
                  true, 'prd'),
              _docCard(context, Icons.layers_outlined, 'UI 说明',
                  docs.ui.trim().isEmpty ? '可选：逐屏布局 / 交互 / 状态' : '${docs.ui.replaceAll(RegExp(r'\s'), '').length} 字 · 逐屏约束',
                  false, 'ui'),
              _docCard(context, Icons.palette_outlined, '设计规范',
                  '配色 / 字体 / 间距 / 圆角 / 规则', true, 'spec'),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: p.panel2.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: p.line),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SectionLabel('概览', trailing: Pill(label: '${store.render.artboards.length} 屏', color: p.accent)),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        _stat(context, '画板', store.render.artboards.length.toString()),
                        _stat(context, '连线', store.render.flows.length.toString()),
                        _stat(context, '节点', store.render.artboards.fold<int>(0, (n, b) => n + b.nodes.length).toString()),
                      ],
                    ),
                    _BenchmarkStrip(mbt: store.mbt),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: p.panel2.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: p.line),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SectionLabel('调色板'),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final entry in docs.design.palette.entries)
                          Tooltip(
                            message: '${entry.key} ${entry.value}',
                            child: Container(
                              width: 24,
                              height: 24,
                              decoration: BoxDecoration(
                                color: parseHex(entry.value),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _docCard(BuildContext context, IconData icon, String title, String detail, bool active, String tab) {
    final store = context.read<AppStore>();
    final p = context.palette;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () {
        store.setDocsTab(tab);
        store.setView('docs');
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.all(9),
        decoration: BoxDecoration(
          color: p.panel2.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: p.line),
        ),
        child: Row(
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(color: p.panel3, borderRadius: BorderRadius.circular(8)),
              child: Icon(icon, size: 14, color: p.ink3),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(title, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: p.ink)),
                      if (active)
                        Padding(
                          padding: const EdgeInsets.only(left: 5),
                          child: Container(width: 5, height: 5, decoration: BoxDecoration(color: p.success, shape: BoxShape.circle)),
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(detail, maxLines: 2, overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 10, height: 1.35, color: p.ink4)),
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 14, color: p.ink4),
          ],
        ),
      ),
    );
  }

  Widget _stat(BuildContext context, String label, String value) {
    final p = context.palette;
    return Expanded(
      child: Container(
        margin: const EdgeInsets.only(right: 4),
        padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 6),
        decoration: BoxDecoration(color: p.panel3.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(8)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(value, style: TextStyle(fontSize: 13, fontFamily: 'Menlo', fontWeight: FontWeight.w600, color: p.ink)),
            Text(label, style: TextStyle(fontSize: 10, color: p.ink4)),
          ],
        ),
      ),
    );
  }
}

class _SpecPanel extends StatefulWidget {
  const _SpecPanel();

  @override
  State<_SpecPanel> createState() => _SpecPanelState();
}

class _SpecPanelState extends State<_SpecPanel> {
  Map<String, dynamic>? _extract;
  String? _extractAb;
  bool _extracting = false;

  Future<void> _runExtract() async {
    final store = context.read<AppStore>();
    final ab = store.activeBoard;
    if (ab == null || _extracting) return;
    setState(() => _extracting = true);
    final data = await extractDesignData(context, store, ab);
    if (!mounted) return;
    setState(() {
      _extracting = false;
      _extract = data;
      _extractAb = data != null ? ab : _extractAb;
    });
  }

  Future<void> _runResponsive() async {
    final store = context.read<AppStore>();
    final ab = store.activeBoard;
    if (ab == null) return;
    final ok = await store.responsiveBoard();
    if (ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('响应式适配完成 · $ab 已生成平板/桌面变体'), behavior: SnackBarBehavior.floating),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final p = context.palette;
    final design = store.docs.design;
    return Column(
      children: [
        _PanelHead('设计规范', actions: [
          IconAction(
            icon: Icons.colorize,
            tooltip: '从画布提取设计规范',
            size: 26,
            onTap: store.activeBoard == null || _extracting ? null : _runExtract,
          ),
          IconAction(
            icon: Icons.auto_fix_high,
            tooltip: '把调色板写入画布 token',
            size: 26,
            onTap: () async {
              var ok = 0;
              const mapping = {
                'primary': 'primary',
                'background': 'background',
                'surface': 'surface',
                'text': 'text_primary',
                'muted': 'text_secondary',
                'danger': 'error',
                'success': 'success',
              };
              for (final entry in mapping.entries) {
                final color = design.palette[entry.key];
                if (color != null && await store.setToken(entry.value, color)) ok += 1;
              }
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(ok > 0 ? '已应用 $ok 个颜色令牌' : '画布颜色未变'), behavior: SnackBarBehavior.floating),
                );
              }
            },
          ),
        ]),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              const SectionLabel('调色板'),
              const SizedBox(height: 6),
              for (final entry in design.palette.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 5),
                  child: Row(
                    children: [
                      Container(
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          color: parseHex(entry.value),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
                        ),
                      ),
                      const SizedBox(width: 6),
                      SizedBox(
                        width: 70,
                        child: Text(entry.key, style: TextStyle(fontSize: 11, color: p.ink3)),
                      ),
                      Expanded(
                        child: _CommitField(
                          value: entry.value,
                          monospace: true,
                          onSubmit: (v) {
                            final palette = Map<String, String>.from(design.palette)..[entry.key] = v;
                            store.setDocs(
                              design: DesignSpec(
                                palette: palette,
                                h1: design.h1,
                                h2: design.h2,
                                body: design.body,
                                spacing: design.spacing,
                                radiusSm: design.radiusSm,
                                radiusMd: design.radiusMd,
                                radiusLg: design.radiusLg,
                                rules: design.rules,
                                notes: design.notes,
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              if (_extracting) ...[
                const SizedBox(height: 12),
                const SectionLabel('引擎提取'),
                const SizedBox(height: 6),
                Text('正在从 ${store.activeBoard ?? '画板'} 提取…',
                    style: TextStyle(fontSize: 10, height: 1.4, color: p.ink4)),
              ],
              if (_extract != null) ...[
                const SizedBox(height: 12),
                SectionLabel(
                  '引擎提取 · ${_extractAb ?? ''}',
                  trailing: IconAction(
                    icon: Icons.close,
                    tooltip: '收起',
                    size: 20,
                    onTap: () => setState(() {
                      _extract = null;
                      _extractAb = null;
                    }),
                  ),
                ),
                const SizedBox(height: 6),
                ExtractCompareView(data: _extract!),
              ],
              const SizedBox(height: 12),
              SectionLabel('画板', trailing: Text(store.activeBoard ?? '—',
                  style: TextStyle(fontSize: 10, fontFamily: 'Menlo', color: p.ink4))),
              const SizedBox(height: 6),
              _PanelActionButton(
                icon: Icons.devices_outlined,
                label: '响应式适配',
                enabled: store.activeBoard != null && !store.agentBusy,
                onTap: _runResponsive,
              ),
              const SizedBox(height: 12),
              const SectionLabel('字体层级'),
              const SizedBox(height: 6),
              Row(
                children: [
                  for (final item in [('H1', design.h1), ('H2', design.h2), ('BODY', design.body)])
                    Expanded(
                      child: Container(
                        margin: const EdgeInsets.only(right: 4),
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(color: p.panel2, borderRadius: BorderRadius.circular(8)),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(item.$1, style: TextStyle(fontSize: 10, color: p.ink4)),
                            _CommitField(
                              value: item.$2.round().toString(),
                              monospace: true,
                              onSubmit: (v) {
                                final n = double.tryParse(v) ?? item.$2;
                                store.setDocs(
                                  design: DesignSpec(
                                    palette: design.palette,
                                    h1: item.$1 == 'H1' ? n : design.h1,
                                    h2: item.$1 == 'H2' ? n : design.h2,
                                    body: item.$1 == 'BODY' ? n : design.body,
                                    spacing: design.spacing,
                                    radiusSm: design.radiusSm,
                                    radiusMd: design.radiusMd,
                                    radiusLg: design.radiusLg,
                                    rules: design.rules,
                                    notes: design.notes,
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              const SectionLabel('间距 / 圆角'),
              const SizedBox(height: 6),
              Wrap(
                spacing: 5,
                runSpacing: 5,
                children: [
                  for (final s in design.spacing)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                      decoration: BoxDecoration(color: p.panel2, borderRadius: BorderRadius.circular(4)),
                      child: Text(s.round().toString(), style: TextStyle(fontSize: 10, fontFamily: 'Menlo', color: p.ink3)),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              const SectionLabel('规则'),
              const SizedBox(height: 6),
              for (final rule in design.rules)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    children: [
                      Icon(Icons.check, size: 10, color: p.success),
                      const SizedBox(width: 5),
                      Expanded(child: Text(rule, style: TextStyle(fontSize: 11, height: 1.4, color: p.ink3))),
                    ],
                  ),
                ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: p.accentSoft.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: p.accent.withValues(alpha: 0.2)),
                ),
                child: Text('规范随每次 Agent run 注入上下文，保持全局视觉一致。',
                    style: TextStyle(fontSize: 10, height: 1.5, color: p.ink3)),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _HistoryPanel extends StatefulWidget {
  const _HistoryPanel();

  @override
  State<_HistoryPanel> createState() => _HistoryPanelState();
}

class _HistoryPanelState extends State<_HistoryPanel> {
  bool _engineMode = false;
  bool _engineBusy = false;
  String _engineOutput = '';
  String _initializedBoard = '';

  Future<void> _runEngine(String command) async {
    final store = context.read<AppStore>();
    final board = store.activeBoard;
    if (command == 'init' && (board == null || board.isEmpty)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('先选择一个画板再初始化引擎版本'), behavior: SnackBarBehavior.floating),
      );
      return;
    }
    final full = command == 'init' ? 'init $board' : command;
    setState(() => _engineBusy = true);
    final res = await store.engineHistory(full);
    if (!mounted) return;
    final data = res['data']?.toString() ?? '';
    final canonical = res['mbt']?.toString() ?? '';
    setState(() {
      _engineBusy = false;
      _engineOutput = [
        if (res['ok'] != true && res['error'] != null) '✗ ${res['error']}',
        if (data.isNotEmpty) data,
        if (canonical.isNotEmpty) '[canonical 已更新，${canonical.length} 字符]',
      ].join('\n').trim();
      if (command == 'init' && res['ok'] == true) _initializedBoard = board ?? '';
      if (_engineOutput.isEmpty) _engineOutput = res['ok'] == true ? 'ok' : '命令失败';
    });
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final p = context.palette;
    return Column(
      children: [
        _PanelHead('历史', actions: [
          IconAction(icon: Icons.undo, tooltip: '撤销 ${modCombo('⌘Z')}（本地快照）', size: 26, onTap: store.undo),
          IconAction(icon: Icons.redo, tooltip: '重做 ${modCombo('⇧⌘Z')}（本地快照）', size: 26, onTap: store.redo),
        ]),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
          child: Row(
            children: [
              _seg(context, '本地快照', !_engineMode, () => setState(() => _engineMode = false)),
              const SizedBox(width: 4),
              _seg(context, '引擎版本', _engineMode, () => setState(() => _engineMode = true)),
            ],
          ),
        ),
        if (!_engineMode)
          Expanded(
            child: ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: store.history.length,
            itemBuilder: (context, i) {
              final index = store.history.length - 1 - i;
              final active = index == store.historyIndex;
              final mbt = store.history[index];
              final boards = RegExp(r'<!-- moonviz:artboard').allMatches(mbt).length;
              return InkWell(
                onTap: () => store.jumpHistory(index),
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 7),
                  margin: const EdgeInsets.only(bottom: 2),
                  decoration: BoxDecoration(
                    color: active ? p.accentSoft : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 5,
                        height: 5,
                        decoration: BoxDecoration(color: active ? p.accent : p.ink4, shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(active ? '当前版本' : '版本 ${index + 1}',
                                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: active ? p.accent : p.ink3)),
                            Text('$boards 板 · ${(() { final cleaned = mbt.replaceAll(RegExp(r'\s+'), ' '); return cleaned.length > 40 ? cleaned.substring(0, 40) : cleaned; })()}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 10, fontFamily: 'Menlo', color: p.ink4)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        )
        else
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    '目标画板：${store.activeBoard ?? '（未选择）'} · ${_initializedBoard.isEmpty ? '未初始化' : '已初始化 $_initializedBoard'}',
                    style: TextStyle(fontSize: 10, fontFamily: 'Menlo', color: p.ink4),
                  ),
                ),
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      for (final cmd in const ['init', 'commit', 'log', 'undo', 'redo', 'diff'])
                        ActionChip(
                          label: Text(cmd,
                              style: TextStyle(fontSize: 10, fontFamily: 'Menlo', color: _engineBusy ? p.ink4 : p.ink2)),
                          onPressed: _engineBusy
                              ? null
                              : () async {
                                  await _runEngine(cmd);
                                  if (mounted) setState(() {});
                                },
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                Expanded(
                  child: Container(
                    margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: p.bgElevated,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: p.line),
                    ),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        _engineOutput.isEmpty
                            ? '选画板 → init → 改画布 → commit → log 查看引擎版本历史。\nundo / redo / diff 均由引擎 session_history 驱动。'
                            : _engineOutput,
                        style: TextStyle(fontSize: 10, fontFamily: 'Menlo', height: 1.5, color: p.ink3),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _seg(BuildContext context, String label, bool active, VoidCallback onTap) {
    final p = context.palette;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: active ? p.accentSoft : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 11, fontWeight: FontWeight.w600, color: active ? p.accent : p.ink3)),
      ),
    );
  }
}

class _CommitField extends StatefulWidget {
  final String value;
  final bool monospace;
  final ValueChanged<String> onSubmit;
  const _CommitField({required this.value, required this.onSubmit, this.monospace = false});

  @override
  State<_CommitField> createState() => _CommitFieldState();
}

class _CommitFieldState extends State<_CommitField> {
  late final TextEditingController _controller = TextEditingController(text: widget.value);

  @override
  void didUpdateWidget(covariant _CommitField old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value && _controller.text != widget.value) {
      _controller.text = widget.value;
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
    return SizedBox(
      height: 28,
      child: TextField(
        controller: _controller,
        style: TextStyle(fontSize: widget.monospace ? 10.5 : 12, fontFamily: widget.monospace ? 'Menlo' : null, color: p.ink2),
        decoration: const InputDecoration(
          contentPadding: EdgeInsets.symmetric(horizontal: 7, vertical: 4),
          isDense: true,
        ),
        onSubmitted: widget.onSubmit,
        onTapOutside: (_) => widget.onSubmit(_controller.text),
      ),
    );
  }
}

/// Board-row 「响应式适配」: generate responsive variants for [boardId] (engine
/// op `responsive <ab>`). Uses the row's own id, not the active board — the
/// popup is per-board. applyOp already toasts rejections; only confirm success.
Future<void> _runResponsive(BuildContext context, AppStore store, String boardId) async {
  final ok = await store.applyOp('responsive $boardId');
  if (ok && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('响应式适配完成 · $boardId 已生成平板/桌面变体'), behavior: SnackBarBehavior.floating),
    );
  }
}

/// Fetch session_extract_design_system for [ab] via [AppStore.extractDesignSystem]
/// and return the displayable data map ({summary, color_tokens, components}),
/// or null on failure (the error is snackbar'd here so both hosts stay thin).
/// Shared by the left spec panel and the docs spec page (docs_view.dart).
Future<Map<String, dynamic>?> extractDesignData(BuildContext context, AppStore store, String ab) async {
  final res = await store.extractDesignSystem(ab);
  final hasData = res != null && (res['color_tokens'] is List || res['summary'] is Map);
  if (!hasData && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(res?['error']?.toString() ?? '提取失败'), behavior: SnackBarBehavior.floating),
    );
  }
  return hasData ? res : null;
}

/// Compare engine-extracted color tokens against the current DESIGN.md palette
/// and merge engine suggestions into store.setDocs with one tap. Shared by the
/// left spec panel and the docs spec page. Data shape (engine probed): {summary:
/// {total_nodes, total_colors, total_sizes}, color_tokens: [{name, value,
/// usage, confidence}], components: []} — token names are engine-side
/// (primary/surface/on_primary…), duplicates possible with different values;
/// display keeps every row, merge upserts in usage-descending order so the
/// most-used value wins per name.
class ExtractCompareView extends StatelessWidget {
  final Map<String, dynamic> data;
  const ExtractCompareView({super.key, required this.data});

  static List<Map<String, dynamic>> tokensOf(Map<String, dynamic> data) {
    final raw = data['color_tokens'];
    if (raw is! List) return const [];
    return raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  }

  static bool _sameValue(String? a, String? b) =>
      a != null && b != null && a.trim().toUpperCase() == b.trim().toUpperCase();

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final p = context.palette;
    final design = store.docs.design;
    final tokens = tokensOf(data)
      ..sort((a, b) {
        final ua = a['usage'] is num ? (a['usage'] as num).toInt() : 0;
        final ub = b['usage'] is num ? (b['usage'] as num).toInt() : 0;
        final byUsage = ub.compareTo(ua);
        if (byUsage != 0) return byUsage;
        return (a['name'] ?? '').toString().compareTo((b['name'] ?? '').toString());
      });
    final summary = data['summary'] is Map ? data['summary'] as Map : const {};
    final diffs = tokens
        .where((t) => !_sameValue(t['value']?.toString(), design.palette[t['name']?.toString()]))
        .length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '颜色 ${summary['total_colors'] ?? tokens.length} · 尺寸组 ${summary['total_sizes'] ?? '—'} · 节点 ${summary['total_nodes'] ?? '—'}',
          style: TextStyle(fontSize: 10, fontFamily: 'Menlo', color: p.ink4),
        ),
        const SizedBox(height: 7),
        if (tokens.isEmpty)
          Text('该画板没有提取到颜色 token。', style: TextStyle(fontSize: 11, color: p.ink4))
        else
          for (final t in tokens) _tokenRow(context, design, t),
        if (tokens.isNotEmpty) ...[
          const SizedBox(height: 6),
          _PanelActionButton(
            icon: Icons.merge_type,
            label: diffs > 0 ? '合并 $diffs 处引擎建议到规范' : '已与现规范一致',
            enabled: diffs > 0,
            onTap: () => _merge(context, tokens),
          ),
        ],
      ],
    );
  }

  Widget _tokenRow(BuildContext context, DesignSpec design, Map<String, dynamic> t) {
    final p = context.palette;
    final name = t['name']?.toString() ?? '';
    final value = t['value']?.toString() ?? '';
    final usage = t['usage'] is num ? (t['usage'] as num).toInt() : null;
    final confidence = t['confidence'] is num ? ((t['confidence'] as num) * 100).round() : null;
    final current = design.palette[name];
    final same = _sameValue(value, current);
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        children: [
          Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              color: parseHex(value),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name.isEmpty ? '—' : name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10, color: p.ink3)),
                Text(same ? value : '$value → ${current ?? '新增'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10, fontFamily: 'Menlo', color: same ? p.ink4 : p.ink2)),
              ],
            ),
          ),
          Icon(same ? Icons.check : Icons.swap_horiz, size: 11, color: same ? p.success : p.accent),
          const SizedBox(width: 6),
          SizedBox(
            width: 56,
            child: Text(
              '${usage != null ? '×$usage' : ''}${confidence != null ? ' · $confidence%' : ''}',
              textAlign: TextAlign.right,
              style: TextStyle(fontSize: 10, fontFamily: 'Menlo', color: p.ink4),
            ),
          ),
        ],
      ),
    );
  }

  void _merge(BuildContext context, List<Map<String, dynamic>> tokens) {
    final store = context.read<AppStore>();
    final design = store.docs.design;
    final palette = Map<String, String>.from(design.palette);
    var merged = 0;
    for (final t in tokens) {
      final name = t['name']?.toString() ?? '';
      final value = t['value']?.toString() ?? '';
      if (name.isEmpty || value.isEmpty) continue;
      final before = palette[name];
      palette[name] = value;
      if (!_sameValue(before, value)) merged += 1;
    }
    if (merged == 0) return;
    store.setDocs(
      design: DesignSpec(
        palette: palette,
        h1: design.h1,
        h2: design.h2,
        body: design.body,
        spacing: design.spacing,
        radiusSm: design.radiusSm,
        radiusMd: design.radiusMd,
        radiusLg: design.radiusLg,
        rules: design.rules,
        notes: design.notes,
      ),
    );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已合并 $merged 个颜色到设计规范'), behavior: SnackBarBehavior.floating),
    );
  }
}

/// Compact full-width action button for narrow left-panel sections.
class _PanelActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool enabled;
  final VoidCallback? onTap;
  const _PanelActionButton({required this.icon, required this.label, this.enabled = true, this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Material(
      color: enabled ? p.panel2 : p.panel2.withValues(alpha: 0.4),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: enabled ? onTap : null,
        child: Container(
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 9),
          child: Row(
            children: [
              Icon(icon, size: 13, color: enabled ? p.ink2 : p.ink4),
              const SizedBox(width: 7),
              Text(label,
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: enabled ? p.ink2 : p.ink4)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Engine render benchmark (session_benchmark via the generic /engine/session
/// endpoint, no arg). Refetches on mbt change; renders nothing while the
/// engine is unreachable or the document is empty, so the existing
/// artboard/flow/node stats stand alone.
class _BenchmarkStrip extends StatefulWidget {
  final String mbt;
  const _BenchmarkStrip({required this.mbt});

  @override
  State<_BenchmarkStrip> createState() => _BenchmarkStripState();
}

class _BenchmarkStripState extends State<_BenchmarkStrip> {
  Map<String, dynamic>? _data;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  @override
  void didUpdateWidget(covariant _BenchmarkStrip old) {
    super.didUpdateWidget(old);
    if (old.mbt != widget.mbt) _fetch();
  }

  Future<void> _fetch() async {
    final store = context.read<AppStore>();
    final api = store.api;
    if (api == null || store.agentBusy) return;
    if (store.mbt.trim().isEmpty) {
      if (_data != null) setState(() => _data = null);
      return;
    }
    final target = store.mbt;
    setState(() => _loading = true);
    Map<String, dynamic>? data;
    try {
      final res = await api.session(target, 'session_benchmark');
      final raw = res['data'];
      if (raw is Map) data = Map<String, dynamic>.from(raw);
    } catch (_) {
      data = null;
    }
    if (!mounted) return;
    // Apply only if the document hasn't moved on mid-flight; a newer fetch
    // (didUpdateWidget / manual refresh) owns the result.
    if (store.mbt != target) {
      setState(() => _loading = false);
      return;
    }
    setState(() {
      _loading = false;
      _data = data;
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final data = _data;
    if (_loading && data == null) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(
          children: [
            SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1.2, color: p.ink4)),
            const SizedBox(width: 6),
            Text('引擎基准测试…', style: TextStyle(fontSize: 10, color: p.ink4)),
          ],
        ),
      );
    }
    if (data == null) return const SizedBox.shrink();
    final grade = data['grade']?.toString() ?? '';
    final score = data['avg_score'] is num ? (data['avg_score'] as num).round() : null;
    final nodes = data['total_nodes'] is num ? (data['total_nodes'] as num).toInt() : null;
    final color = switch (grade) {
      'A' || 'B' => p.success,
      'C' => p.warn,
      _ => p.danger,
    };
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Pill(
            label: '基准 $grade${score != null ? ' · $score 分' : ''}',
            color: color,
            background: color.withValues(alpha: 0.14),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '${nodes ?? '—'} 节点 · ${_fmtBytes(data['total_memory'])}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10, fontFamily: 'Menlo', color: p.ink4),
            ),
          ),
          IconAction(icon: Icons.refresh, tooltip: '重跑引擎基准', size: 20, onTap: _fetch),
        ],
      ),
    );
  }
}

String _fmtBytes(dynamic v) {
  if (v is! num || v <= 0) return '—';
  if (v < 1024) return '${v.round()} B';
  return '${(v / 1024).toStringAsFixed(1)} KB';
}
