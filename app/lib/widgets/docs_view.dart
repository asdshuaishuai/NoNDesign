import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:provider/provider.dart';

import '../core/models.dart';
import '../core/keys.dart';
import '../core/store.dart';
import '../core/theme.dart';
import 'common.dart';
import 'left_panel.dart' show ExtractCompareView, extractDesignData;

class DocsView extends StatefulWidget {
  const DocsView({super.key});
  @override
  State<DocsView> createState() => _DocsViewState();
}

class _DocsViewState extends State<DocsView> {
  final _brief = TextEditingController();
  final _editor = TextEditingController();
  bool _preview = true;
  String? _syncedFor;
  // 编辑器输入本地缓冲 + 300ms 防抖：每键一字 setDocs 会 new Docs +
  // notifyListeners 全树重建（数千字 PRD 打字延迟线性增长）。失焦/切
  // 标签立即 flush 补齐，不在视图间丢尾字。
  Timer? _commitTimer;
  String? _pendingKind;
  String? _pendingText;
  String? _lastTab;
  // 字数统计对 source 做同一性检查后再重算：打字期间 source 实例不变，
  // 免去每帧对全文跑 replaceAll(RegExp)。
  String? _countedSource;
  int _countedChars = 0;

  void _stageCommit(String kind, String text) {
    _pendingKind = kind;
    _pendingText = text;
    _commitTimer?.cancel();
    _commitTimer = Timer(const Duration(milliseconds: 300), _flushPending);
  }

  void _flushPending() {
    _commitTimer?.cancel();
    _commitTimer = null;
    final kind = _pendingKind;
    final text = _pendingText;
    _pendingKind = null;
    _pendingText = null;
    if (!mounted || kind == null) return;
    final store = context.read<AppStore>();
    if (kind == 'prd') {
      store.setDocs(prd: text);
    } else {
      store.setDocs(ui: text);
    }
  }

  String _charCountOf(String source) {
    if (!identical(_countedSource, source)) {
      _countedSource = source;
      _countedChars = source.replaceAll(RegExp(r'\s'), '').length;
    }
    return '$_countedChars 字';
  }

  @override
  void dispose() {
    // 切视图/⌘↵ 直接生成前必须把 300ms 防抖内的编辑落进 store——
    // deepDesign 的 syncPrdFromEditor 教训：否则生成用的是旧 PRD。
    _flushPending();
    _commitTimer?.cancel();
    _brief.dispose();
    _editor.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final p = context.palette;
    final tab = store.docsTab;
    final source = tab == 'prd' ? store.docs.prd : tab == 'ui' ? store.docs.ui : '';
    // 切标签前先 flush 上一个标签的待写字，防止编辑器被新 source 覆盖丢字。
    // post-frame：build 期直接 setDocs 会 notifyListeners → build 期 markNeedsBuild 异常。
    if (tab != _lastTab) {
      if (_lastTab != null) {
        _commitTimer?.cancel();
        WidgetsBinding.instance.addPostFrameCallback((_) => _flushPending());
      }
      _lastTab = tab;
    }
    if (tab != 'spec' && _syncedFor != '${tab}:${source.hashCode}' && _editor.text != source) {
      _editor.text = source;
      _syncedFor = '${tab}:${source.hashCode}';
    }
    return Column(
      children: [
        Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: p.line))),
          child: LayoutBuilder(builder: (context, constraints) {
            // 窄屏（手机 390–410）：三个 tab + 「生成原型」按钮曾右溢 58px。
            // tab 收紧内边距、动作按钮改图标态，文字进度提示让位给 spinner。
            final narrow = constraints.maxWidth < 520;
            return Row(
              children: [
                _tab(context, store, 'prd', Icons.description_outlined, '产品需求', store.docs.prd.isNotEmpty, compact: narrow),
                const SizedBox(width: 2),
                _tab(context, store, 'ui', Icons.layers_outlined, 'UI 说明', store.docs.ui.isNotEmpty, compact: narrow),
                const SizedBox(width: 2),
                _tab(context, store, 'spec', Icons.palette_outlined, '设计规范', true, compact: narrow),
                const Spacer(),
                if (store.agentBusy) ...[
                  SizedBox(width: 11, height: 11, child: CircularProgressIndicator(strokeWidth: 1.5, color: p.accent)),
                  if (!narrow) ...[
                    const SizedBox(width: 6),
                    Text(store.agentPhase == 'planning' ? 'NaN 正在写文档…' : 'NaN 正在工作…',
                        style: TextStyle(fontSize: 10, color: p.accent)),
                    const SizedBox(width: 10),
                  ],
                ],
                if (narrow)
                  IconButton(
                    tooltip: '生成原型',
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    padding: EdgeInsets.zero,
                    icon: const Icon(Icons.auto_awesome, size: 16),
                    onPressed: store.agentBusy || store.docs.prd.trim().isEmpty
                        ? null
                        : () {
                            store.setView('design');
                            store.runBuild('请根据 PRD 与 UI 说明生成完整可交互原型。先规划页面连接，再逐屏生成，最后连线并自检。');
                          },
                  )
                else
                  OutlinedButton(
                    onPressed: store.agentBusy || store.docs.prd.trim().isEmpty
                        ? null
                        : () {
                            store.setView('design');
                            store.runBuild('请根据 PRD 与 UI 说明生成完整可交互原型。先规划页面连接，再逐屏生成，最后连线并自检。');
                          },
                    child: const Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.auto_awesome, size: 12),
                      SizedBox(width: 4),
                      Text('生成原型'),
                    ]),
                  ),
              ],
            );
          }),
        ),
        Expanded(
          child: tab == 'spec'
              ? const _SpecPreview()
              : source.trim().isEmpty && !store.agentBusy
                  ? _emptyDoc(context, store, tab)
                  : _docBody(context, store, tab, source),
        ),
      ],
    );
  }

  Widget _tab(BuildContext context, AppStore store, String id, IconData icon, String label, bool done,
      {bool compact = false}) {
    final p = context.palette;
    final active = store.docsTab == id;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => store.setDocsTab(id),
      child: Container(
        height: 28,
        padding: EdgeInsets.symmetric(horizontal: compact ? 5 : 9),
        decoration: BoxDecoration(
          color: active ? p.panel2 : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(icon, size: 12, color: active ? p.accent : p.ink4),
            SizedBox(width: compact ? 4 : 5),
            Text(label, style: TextStyle(fontSize: compact ? 11 : 12, fontWeight: FontWeight.w500, color: active ? p.ink : p.ink3)),
            if (done)
              Padding(
                padding: const EdgeInsets.only(left: 5),
                child: Container(width: 4, height: 4, decoration: BoxDecoration(color: p.success, shape: BoxShape.circle)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _emptyDoc(BuildContext context, AppStore store, String kind) {
    final p = context.palette;
    return Center(
      child: SizedBox(
        width: 620,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                gradient: LinearGradient(colors: [p.accent, p.accent2]),
              ),
              child: Icon(kind == 'prd' ? Icons.description_outlined : Icons.layers_outlined, color: Colors.white, size: 20),
            ),
            const SizedBox(height: 12),
            Text(kind == 'prd' ? '先定义产品，再画界面' : '逐屏写清 UI 约束',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: p.ink)),
            const SizedBox(height: 5),
            Text('描述目标用户、核心流程和页面范围。NaN 会写成可施工的${kind == 'prd' ? ' PRD' : ' UI 说明'}。',
                textAlign: TextAlign.center, style: TextStyle(fontSize: 12, height: 1.55, color: p.ink3)),
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: p.panel2.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: p.lineStrong),
              ),
              child: Column(
                children: [
                  TextField(
                    controller: _brief,
                    minLines: 3,
                    maxLines: 5,
                    style: TextStyle(fontSize: 13, height: 1.5, color: p.ink),
                    decoration: const InputDecoration(
                      hintText: '例如：一个面向独立设计师的项目管理工具，核心是项目列表、任务看板、成员与通知设置。',
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      filled: false,
                      contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    ),
                  ),
                  Row(
                    children: [
                      Text('${modCombo('⌘↵')} 生成', style: TextStyle(fontSize: 10, color: p.ink4)),
                      const Spacer(),
                      FilledButton(
                        style: FilledButton.styleFrom(backgroundColor: p.accent, foregroundColor: Colors.white),
                        onPressed: () {
                          final brief = _brief.text.trim();
                          if (brief.isNotEmpty) store.runPlan(brief);
                        },
                        child: const Text('让 NaN 撰写', style: TextStyle(fontSize: 12)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _docBody(BuildContext context, AppStore store, String kind, String source) {
    final p = context.palette;
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
          child: LayoutBuilder(builder: (context, constraints) {
            // 窄屏：Pill + 字数 + 预览/编辑 + 「让 NaN 完善」曾右溢 246px。
            // 窄屏下切换与完善按钮改图标态（带 tooltip），正文区不受挤压。
            final narrow = constraints.maxWidth < 560;
            return Row(
              children: [
                Pill(label: kind == 'prd' ? 'PRD' : 'UI SPEC', color: p.accent, background: p.accentSoft),
                const SizedBox(width: 8),
                Text(_charCountOf(source), style: TextStyle(fontSize: 10, color: p.ink4)),
                const Spacer(),
                _toggle(context, _preview, '预览', Icons.visibility_outlined, () => setState(() => _preview = true),
                    compact: narrow),
                const SizedBox(width: 2),
                _toggle(context, !_preview, '编辑', Icons.edit_outlined, () => setState(() => _preview = false),
                    compact: narrow),
                const SizedBox(width: 8),
                if (narrow)
                  IconButton(
                    tooltip: '让 NaN 完善',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.auto_fix_high, size: 16),
                    onPressed: store.agentBusy
                        ? null
                        : () => store.runPlan(
                            '请基于当前文档继续完善 ${kind == 'prd' ? 'PRD' : 'UI 说明'}。保留已有有效内容，补全缺失的边界、状态与验收标准。'),
                  )
                else
                  OutlinedButton(
                    onPressed: store.agentBusy
                        ? null
                        : () => store.runPlan(
                            '请基于当前文档继续完善 ${kind == 'prd' ? 'PRD' : 'UI 说明'}。保留已有有效内容，补全缺失的边界、状态与验收标准。'),
                    child: const Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.auto_fix_high, size: 12),
                      SizedBox(width: 4),
                      Text('让 NaN 完善'),
                    ]),
                  ),
              ],
            );
          }),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(28, 8, 28, 32),
            // PLAN 运行中的流式直播：write_doc 正文边写边推进（doc_delta 累积
            // 到 store.liveDocText），自动切渲染视图（原版同语义）；doc_written
            // 全量到达后清缓冲回落编辑态。
            child: (store.agentBusy && store.liveDocText.isNotEmpty)
                ? Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(26),
                    decoration: BoxDecoration(
                      color: p.panel.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: p.accent.withValues(alpha: 0.35)),
                    ),
                    child: MarkdownBody(
                      data: store.liveDocText,
                      styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
                        p: TextStyle(fontSize: 13, height: 1.7, color: p.ink2),
                        h1: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: p.ink),
                        h2: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: p.ink),
                        h3: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: p.ink),
                      ),
                    ),
                  )
                : _preview
                ? Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(26),
                    decoration: BoxDecoration(
                      color: p.panel.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: p.line),
                    ),
                    child: MarkdownBody(
                      data: source,
                      styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
                        p: TextStyle(fontSize: 13, height: 1.7, color: p.ink2),
                        h1: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: p.ink),
                        h2: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: p.ink),
                        h3: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: p.ink),
                      ),
                    ),
                  )
                : TextField(
                    controller: _editor,
                    minLines: 20,
                    maxLines: null,
                    style: TextStyle(fontSize: 13, height: 1.7, fontFamily: 'Menlo', color: p.ink2),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: p.panel.withValues(alpha: 0.5),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: p.line)),
                      contentPadding: const EdgeInsets.all(20),
                    ),
                    onChanged: (v) => _stageCommit(kind, v),
                    // 失焦立即 flush：防抖窗口内点别处，编辑内容也要落到真源。
                    onTapOutside: (_) => _flushPending(),
                  ),
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
          decoration: BoxDecoration(border: Border(top: BorderSide(color: p.line))),
          child: LayoutBuilder(builder: (context, constraints) {
            // 手机窄屏：长说明 + 快捷键提示曾右溢 246px。窄屏省略说明、隐藏
            // 键盘快捷键（手机没有键盘）。
            final narrow = constraints.maxWidth < 560;
            return Row(
              children: [
                Expanded(
                  child: Text('Markdown · 随项目文件一起保存，换设备打开也不丢',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 10, color: p.ink4)),
                ),
                if (!narrow) ...[
                  const SizedBox(width: 8),
                  Text('${modCombo('⌘↵')} 生成原型', style: TextStyle(fontSize: 10, color: p.ink4)),
                ],
              ],
            );
          }),
        ),
      ],
    );
  }

  Widget _toggle(BuildContext context, bool active, String label, IconData icon, VoidCallback onTap,
      {bool compact = false}) {
    final p = context.palette;
    final body = InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: compact ? 6 : 7, vertical: 4),
        decoration: BoxDecoration(
          color: active ? p.panel3 : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            Icon(icon, size: 11, color: active ? p.ink2 : p.ink4),
            if (!compact) ...[
              const SizedBox(width: 3),
              Text(label, style: TextStyle(fontSize: 11, color: active ? p.ink2 : p.ink4)),
            ],
          ],
        ),
      ),
    );
    return compact ? Tooltip(message: label, child: body) : body;
  }
}

class _SpecPreview extends StatefulWidget {
  const _SpecPreview();

  @override
  State<_SpecPreview> createState() => _SpecPreviewState();
}

class _SpecPreviewState extends State<_SpecPreview> {
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
    // 提取结果自动落进 docs.design（此前只存本地预览态，规范正文永远
    // 显示默认值——用户反馈「设计规范为啥都是默认的」的根因）。
    if (data != null) store.mergeExtractedPalette(data);
    setState(() {
      _extracting = false;
      _extract = data;
      _extractAb = data != null ? ab : _extractAb;
    });
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final p = context.palette;
    final design = store.docs.design;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 窄屏（手机 390 / 手机横屏）此前标题 + 两个按钮挤在一行右溢 121px：
          // 窄屏让按钮换行，宽屏保持原来的「标题左、按钮右」布局。
          LayoutBuilder(builder: (context, constraints) {
            final title = Text('设计规范',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: p.ink, letterSpacing: -0.4));
            final badge = Pill(label: 'DESIGN.md', color: p.accent, background: p.accentSoft);
            final extract = OutlinedButton.icon(
              onPressed: store.activeBoard == null || _extracting ? null : _runExtract,
              icon: _extracting
                  ? SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5, color: p.accent))
                  : const Icon(Icons.colorize, size: 12),
              label: const Text('从画布提取设计规范'),
            );
            final edit = OutlinedButton.icon(
              onPressed: () => store.setPanel('spec'),
              icon: const Icon(Icons.edit_outlined, size: 12),
              label: const Text('编辑'),
            );
            if (constraints.maxWidth < 700) {
              return Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [title, badge, extract, edit],
              );
            }
            return Row(
              children: [title, const SizedBox(width: 8), badge, const Spacer(), extract, const SizedBox(width: 8), edit],
            );
          }),
          const SizedBox(height: 4),
          Text('配色、字体、间距与圆角从这份规范派生，约束每一块画板。',
              style: TextStyle(fontSize: 12, color: p.ink3)),
          const SizedBox(height: 22),
          _twoUp(
            context,
            _card(context, 'PALETTE', _palette(context, design)),
            _card(context, 'TYPE SCALE', _typeScale(context, design)),
          ),
          const SizedBox(height: 14),
          _twoUp(
            context,
            _card(context, 'SPACING', _spacing(context, design)),
            _card(context, 'RADIUS', _radius(context, design)),
          ),
          const SizedBox(height: 14),
          _card(context, 'RULES', Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final rule in design.rules)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(color: p.panel2, borderRadius: BorderRadius.circular(8)),
                  child: Text(rule, style: TextStyle(fontSize: 11, color: p.ink2)),
                ),
            ],
          )),
          if (_extract != null) ...[
            const SizedBox(height: 14),
            _card(context, '提取对比', Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text('从画板 ${_extractAb ?? ''} 提取的颜色使用统计，可与现规范对照。',
                          style: TextStyle(fontSize: 11, color: p.ink3)),
                    ),
                    IconAction(
                      icon: Icons.close,
                      tooltip: '收起',
                      onTap: () => setState(() {
                        _extract = null;
                        _extractAb = null;
                      }),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ExtractCompareView(data: _extract!),
              ],
            )),
          ],
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: p.accentSoft.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: p.accent.withValues(alpha: 0.2)),
            ),
            child: Row(
              children: [
                Icon(Icons.auto_awesome, size: 14, color: p.accent),
                const SizedBox(width: 8),
                Expanded(child: Text('每次生成都会带上这份规范，保持全局视觉一致。',
                    style: TextStyle(fontSize: 11, color: p.ink3))),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 规范页的「两张卡」布局：宽屏并排、窄屏上下堆叠（手机 390 下并排会把
  /// 色卡/间距条挤到右溢）。
  Widget _twoUp(BuildContext context, Widget a, Widget b) {
    return LayoutBuilder(builder: (context, constraints) {
      if (constraints.maxWidth < 560) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [a, const SizedBox(height: 14), b],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [Expanded(child: a), const SizedBox(width: 14), Expanded(child: b)],
      );
    });
  }

  Widget _card(BuildContext context, String title, Widget child) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: p.panel.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1.1, color: p.ink4)),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }

  Widget _palette(BuildContext context, DesignSpec design) {
    final p = context.palette;
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (final entry in design.palette.entries)
          SizedBox(
            width: 68,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  height: 42,
                  decoration: BoxDecoration(
                    color: parseHex(entry.value),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
                  ),
                ),
                const SizedBox(height: 4),
                Text(entry.key, style: TextStyle(fontSize: 10, color: p.ink3)),
                Text(entry.value, style: TextStyle(fontSize: 10, fontFamily: 'Menlo', color: p.ink4)),
              ],
            ),
          ),
      ],
    );
  }

  Widget _typeScale(BuildContext context, DesignSpec design) {
    final p = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('标题 H1', style: TextStyle(fontSize: design.h1, fontWeight: FontWeight.w600, color: p.ink, height: 1.2)),
        Text('标题 H2', style: TextStyle(fontSize: design.h2, fontWeight: FontWeight.w600, color: p.ink, height: 1.3)),
        Text('正文 body：真实文案、克制层级、清楚的对齐。',
            style: TextStyle(fontSize: design.body, color: p.ink2, height: 1.6)),
        const SizedBox(height: 6),
        Text('H1 ${design.h1.round()} · H2 ${design.h2.round()} · BODY ${design.body.round()}',
            style: TextStyle(fontSize: 10, fontFamily: 'Menlo', color: p.ink4)),
      ],
    );
  }

  Widget _spacing(BuildContext context, DesignSpec design) {
    final p = context.palette;
    // 不钉死行高：条高 + 标签在字号缩放（手机 +10%）下会超出 48px 盒子，
    // 生产界面会出现黄黑警示条。让 Row 按内容自然撑开即可。
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (final s in design.spacing)
          Padding(
            padding: const EdgeInsets.only(right: 7),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Container(
                  width: 14,
                  height: (s * 1.6).clamp(4, 44),
                  decoration: BoxDecoration(color: p.accent.withValues(alpha: 0.35), borderRadius: BorderRadius.circular(4)),
                ),
                const SizedBox(height: 3),
                Text(s.round().toString(), style: TextStyle(fontSize: 10, fontFamily: 'Menlo', color: p.ink4)),
              ],
            ),
          ),
      ],
    );
  }

  Widget _radius(BuildContext context, DesignSpec design) {
    final p = context.palette;
    return Row(
      children: [
        for (final item in [('sm', design.radiusSm), ('md', design.radiusMd), ('lg', design.radiusLg)])
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Column(
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: p.panel3,
                    borderRadius: BorderRadius.circular(item.$2),
                    border: Border.all(color: p.lineStrong),
                  ),
                ),
                const SizedBox(height: 4),
                Text('${item.$1} · ${item.$2.round()}', style: TextStyle(fontSize: 10, color: p.ink4)),
              ],
            ),
          ),
      ],
    );
  }
}

