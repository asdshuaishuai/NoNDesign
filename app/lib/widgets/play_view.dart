import 'dart:async';
import 'package:flutter_svg/flutter_svg.dart';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/api.dart';
import '../core/models.dart';
import '../core/store.dart';
import '../core/theme.dart';
import 'canvas_view.dart';
import 'common.dart';

/// Demo mode is engine-driven: hotzone taps go through [NoNDesignApi.tap]
/// (session tap) and the engine-0.2 gesture face (long press / swipe / keys)
/// goes through [NoNDesignApi.event] (session event). Both return
/// the same envelope contract (probed against the real wasm):
///   {ok, changes[], current, mbt}
///   changes entries: `nav_push:<board>` + `artboard_changed:<board>` (flow /
///     navigate_to markers hit), `toast:"<msg>"`, `node_updated:<node>` (state
///     visual change). `current` is the artboard after navigation. `mbt` differs
///     from the sent text iff runtime state changed — re-render it locally.
/// Gesture spec vocabulary probed against the shipped engine artifact
/// (session_event): accepted — `long_press:<x>:<y>:<ms>` (the ms field is
/// required), `swipe_left|right|up|down` and `swipe_...:<x>:<y>` (the bare
/// direction token and the start-point form both parse), `key_enter`, and the
/// `key:up|down|left|right` form. Rejected as `unknown_event`: bare arrow
/// tokens like `key_up`, and `long_press` without the ms field.
/// Runtime state NEVER writes back to the project document: it lives in
/// [_live]/[_liveMbt] and dies with this widget (leaving play mode resets it).
/// Built-in back does not pop inside session_tap (probed), so the local
/// navigation stack stays authoritative for back hotzones and for the ← key —
/// arrowLeft is forwarded to the engine as `key:left` and falls back to the
/// local stack when the engine reports no effect.
class PlayView extends StatefulWidget {
  const PlayView({super.key});
  @override
  State<PlayView> createState() => _PlayViewState();
}

class _PlayViewState extends State<PlayView> with SingleTickerProviderStateMixin {
  final List<String> _stack = [];
  /// 与 [_stack] 平行的「前进时过渡」记录：返回时推导反向语义
  /// （modal_present→modal_dismiss，其余统一 pop）。
  final List<String> _stackT = [];
  RenderEnvelope? _live;
  String? _liveMbt;
  String? _activeBoard;
  bool _tapping = false;
  String? _toast;
  Timer? _toastTimer;
  /// 换板入场进度（0→1，~250ms easeOutCubic）：motion=fade_in 节点整体淡入。
  late final AnimationController _entranceCtl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 250),
  );
  late final Animation<double> _entrance =
      CurvedAnimation(parent: _entranceCtl, curve: NonMotion.curve);
  /// 标注（批注）模式：活动板上自由圈画；开启时热区点击短路（标注优先）。
  /// 墨迹存 store.demoInks 并随项目文档持久（保存注入 nondesign:ink 块、
  /// 打开恢复）——退出演示/重启不再丢。
  bool _inkMode = false;
  Map<String, List<List<Offset>>> get _inks => context.read<AppStore>().demoInks;
  /// 热区常亮开关（给干系人演示时切真实成品观感，交互不受影响）。
  bool _hotspotsVisible = true;
  /// hover 热区标签：画板外底部浮动提示条的唯一数据源（null = 无）。
  /// 用 ValueNotifier 而非 setState：鼠标掠过时只重建提示条，不重建内容层 SVG。
  final ValueNotifier<String?> _hoverLabel = ValueNotifier<String?>(null);
  /// boardId → session_interactions 结果（null = 加载中/失败，走正则兜底）。
  final Map<String, List<_EngineInteraction>?> _interactions = {};

  // ---- engine-0.2 gesture face（长按 / 滑动 / 按键）----
  String? _badge;
  Timer? _badgeTimer;
  Timer? _longPressTimer;
  int? _pressPointer;
  Offset? _pressBoard; // 按压起点（画板坐标）
  DateTime? _pressAt;
  bool _pressMoved = false;
  bool _longPressSent = false;
  DateTime? _tapSuppressedUntil;
  double _scale = 1.0; // 当前画板缩放，LayoutBuilder 每帧回填
  /// 进入演示模式后的手势引导条（按当前板可用触发聚合，4s 淡出）。
  bool _guideVisible = true;
  Timer? _guideTimer;
  /// 最近一次导航的过渡语义（push/modal 滑入，其余淡入）。
  String _lastTransition = '';

  /// 长按判定：位移超过该值即取消（屏幕像素）。
  static const double _pressSlop = 12;
  /// 滑动判定：总位移与时长双阈值（屏幕像素 / 毫秒）。
  static const double _swipeMinDistance = 56;
  static const Duration _swipeMaxDuration = Duration(milliseconds: 600);
  /// 引擎 0.2 长按事件固定 500ms。
  static const int _longPressMs = 500;

  static final RegExp _backRe =
      RegExp(r'(^|[_\-\s])(back|prev|return)([_\-\s]|$)|返回|后退|上一步|←|‹|«', caseSensitive: false);
  static final RegExp _markerActionRe = RegExp(r'⚡\S*→([A-Za-z_]+)');

  @override
  void initState() {
    super.initState();
    _guideTimer = Timer(const Duration(milliseconds: 4000), () {
      if (mounted) setState(() => _guideVisible = false);
    });
    // 起始板 = 交互根（deepDesign demoStartBoard 语义）：entry 存在且无入边
    // 才直接用 entry；否则取无入边的交互根集合（含 entry 则 entry 优先，否则
    // 第一个根）；全互链无根（tab 成环）才回落「出边最多枢纽页」兜底。
    // 弱模型把 entry 写成细节页时，演示不再从中间页开始。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _activeBoard != null) return;
      final store = context.read<AppStore>();
      final render = store.render;
      if (render.artboards.isEmpty) return;
      final ids = render.artboards.map((b) => b.id).toSet();
      final inn = <String>{};
      for (final f in render.flows) {
        if (!ids.contains(f.from) || !ids.contains(f.to)) continue;
        if (!f.trigger.startsWith('tap:')) continue; // 手势边不算导航入边
        if (f.from != f.to) inn.add(f.to); // 自环不计
      }
      final entryExists = ids.contains(render.entry);
      String best;
      if (entryExists && !inn.contains(render.entry)) {
        best = render.entry;
      } else {
        final roots = render.artboards.where((b) => !inn.contains(b.id)).map((b) => b.id).toList();
        if (roots.isNotEmpty) {
          best = entryExists && roots.contains(render.entry) ? render.entry : roots.first;
        } else {
          int edges(String id) => render.flows.where((f) => f.from == id).length;
          best = render.artboards.first.id;
          var bestEdges = edges(best);
          for (final b in render.artboards) {
            final n = edges(b.id);
            if (n > bestEdges) {
              bestEdges = n;
              best = b.id;
            }
          }
        }
      }
      final cur = store.activeBoard;
      if (best != cur) setState(() => _activeBoard = best);
      // 进入演示的首板也做一次入场呼吸（controller 初始 0，不 kick 则
      // fade_in 节点在首次导航前不可见）。
      _entranceCtl.forward(from: 0);
    });
  }

  @override
  void dispose() {
    _toastTimer?.cancel();
    _badgeTimer?.cancel();
    _longPressTimer?.cancel();
    _guideTimer?.cancel();
    _hoverLabel.dispose();
    _entranceCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final p = context.palette;
    final render = _live ?? store.render;
    final board = render.board(_activeBoard ?? store.activeBoard);
    if (board == null) {
      return Scaffold(
        backgroundColor: context.palette.bg, // 主题背景色——演示模式不再是黑幕
        body: EmptyHint(
          icon: Icons.play_disabled_outlined,
          title: '没有可演示的画板',
          detail: '先生成一个原型，再进入演示模式。',
          action: FilledButton(onPressed: () => store.setView('design'), child: const Text('返回画布')),
        ),
      );
    }
    final hotzones = _hotzonesFor(board);
    // 每个热区的展示数据：标签只进画板外提示条；嵌套热区只画最外层外框
    // （内层点击语义不变），避免一叠色框糊住内容。
    final zoneViews = [
      for (final zone in hotzones)
        (zone: zone, label: _zoneLabel(zone), frame: _isOuterFrame(zone, hotzones)),
    ];
    _ensureInteractions(board);

    return CallbackShortcuts(
      bindings: {
        // Esc 优先退出标注模式（deepDesign 同语义），无标注才退出演示。
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_inkMode) {
            setState(() => _inkMode = false);
          } else {
            store.setView('design');
          }
        },
      },
      child: Focus(
        autofocus: true,
        onKeyEvent: _onKeyEvent,
        child: Scaffold(
          backgroundColor: context.palette.bg, // 主题背景色——演示模式不再是黑幕
          body: Column(
            children: [
              Container(
                height: 48,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                // NonPalette 令牌：此前逐字节硬编码深色主题值，浅色下 ≈2:1 不可读。
                decoration: BoxDecoration(border: Border(bottom: BorderSide(color: p.line))),
                child: Row(
                  children: [
                    IconAction(icon: Icons.close, tooltip: '退出演示 Esc', size: 26, onTap: () => store.setView('design')),
                    const SizedBox(width: 6),
                    Pill(label: '演示模式', color: p.accent, background: p.accent.withValues(alpha: 0.14)),
                    const SizedBox(width: 8),
                    Text(board.name.isEmpty ? board.id : board.name,
                        style: TextStyle(fontSize: 12, color: p.ink2)),
                    const SizedBox(width: 6),
                    Text('${render.artboards.indexWhere((b) => b.id == board.id) + 1} / ${render.artboards.length}',
                        style: TextStyle(fontSize: 10, fontFamily: 'Menlo', color: p.ink3)),
                    const Spacer(),
                    // 标注模式：开启时热区点击短路，Esc/再点 ✏ 退出（deepDesign 同语义）。
                    IconAction(
                      icon: Icons.edit_outlined,
                      tooltip: _inkMode ? '结束标注（Esc）' : '标注模式：在原型上圈画',
                      size: 26,
                      active: _inkMode,
                      onTap: () {
                        setState(() => _inkMode = !_inkMode);
                        if (_inkMode) _showToast('标注模式：按住拖动圈画 · Esc 结束标注');
                      },
                    ),
                    if (_inkMode) ...[
                      const SizedBox(width: 4),
                      IconAction(
                        icon: Icons.cleaning_services_outlined,
                        tooltip: '清除本板标注',
                        size: 26,
                        onTap: () => setState(() => context.read<AppStore>().demoInks.remove(_activeBoard ?? board.id)),
                      ),
                    ],
                    const SizedBox(width: 4),
                    // 热区显隐（原版 toggleHotZones 同语义）：隐藏后是真实成品观感，点击交互不受影响。
                    IconAction(
                      icon: _hotspotsVisible ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                      tooltip: _hotspotsVisible ? '隐藏热区（真实成品观感）' : '显示热区',
                      size: 26,
                      active: _hotspotsVisible,
                      onTap: () => setState(() => _hotspotsVisible = !_hotspotsVisible),
                    ),
                    const SizedBox(width: 4),
                    // 总返回已移除（用户定案）：返回由原型内 back 节点/热区负责（引擎内置 back）；Esc 退出演示。
                    IconAction(
                      icon: Icons.restart_alt,
                      tooltip: '重新开始',
                      size: 26,
                      onTap: _restart,
                    ),
                  ],
                ),
              ),
              // 手势引导条：聚合当前板全部触发方式，告诉用户「怎么演示」。
              AnimatedSwitcher(
                duration: NonMotion.base,
                child: _guideVisible
                    ? Container(
                        key: const ValueKey('guide'),
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                        color: p.accent.withValues(alpha: 0.08),
                        child: Row(children: [
                          Icon(Icons.touch_app_outlined, size: 11, color: p.accent),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(_guideText(board),
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 10, color: p.ink3)),
                          ),
                          InkWell(
                            onTap: () => setState(() => _guideVisible = false),
                            child: Icon(Icons.close, size: 11, color: p.ink4),
                          ),
                        ]),
                      )
                    : const SizedBox(width: double.infinity, height: 0),
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final scale = math.min(
                      math.min((constraints.maxWidth - 120) / board.width, (constraints.maxHeight - 110) / board.height),
                      1.0,
                    );
                    _scale = scale;
                    return Stack(
                      alignment: Alignment.center,
                      children: [
                        // 演示模式无背景色：留白即可，不再铺黑色渐变。
                        Listener(
                          // 整板原始指针监听（含热区上方）：只做长按/滑动识别，
                          // 不参与手势竞技场，热区 tap 不受影响。
                          behavior: HitTestBehavior.opaque,
                          onPointerDown: (e) => _onBoardPointerDown(e, board),
                          onPointerMove: _onBoardPointerMove,
                          onPointerUp: (e) => _onBoardPointerUp(e, board),
                          onPointerCancel: _onBoardPointerCancel,
                          child: Container(
                            width: board.width * scale,
                            height: board.height * scale,
                            decoration: BoxDecoration(
                              // 板底色跟随引擎主题（server 从 svg 背景 rect 提取），
                              // 无值才回落白底。
                              color: board.background.isEmpty ? Colors.white : parseHex(board.background),
                              borderRadius: BorderRadius.circular(8),
                              boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.55), blurRadius: 60, offset: const Offset(0, 30))],
                            ),
                            // 不裁剪：节点轻微超板界在编辑画布不裁可见，演示裁了就是「显示不全」（图1/图2 实证）。
                            // 换板过渡：消费引擎 0.2 全词表（push/pop/modal_present/
                            // modal_dismiss/sheet_present/fade/none），返回反向（_goBack 置反）。
                            child: AnimatedSwitcher(
                              duration: _lastTransition == 'none' ? Duration.zero : NonMotion.base,
                              switchInCurve: NonMotion.curve,
                              transitionBuilder: (child, anim) {
                                switch (_lastTransition) {
                                  case 'none':
                                    return child; // duration 已置零：瞬时直切
                                  case 'fade':
                                    return FadeTransition(opacity: anim, child: child);
                                }
                                final begin = switch (_lastTransition) {
                                  'sheet_present' => const Offset(0, 0.25), // 自底部滑入
                                  'modal_dismiss' => const Offset(-0.25, 0), // 反向同族滑出
                                  _ => const Offset(0.25, 0), // push/pop/modal_present 水平位移
                                };
                                return FadeTransition(
                                  opacity: anim,
                                  child: SlideTransition(
                                    position: Tween(begin: begin, end: Offset.zero).animate(anim),
                                    child: child,
                                  ),
                                );
                              },
                              child: Stack(
                                key: ValueKey(board.id),
                                children: [
                                Positioned.fill(
                                  // 内容层 = 引擎自渲染 SVG（唯一真源），入场
                                  // 呼吸改为对整层 FadeTransition（svg 是整板
                                  // 光栅，节点级 motion 由引擎导出面承载）。
                                  // 上屏前经 EngineSvgPrep 兼容预处理，同画布。
                                  child: board.svg.isNotEmpty
                                      ? FadeTransition(
                                          opacity: _entrance,
                                          child: ListenableBuilder(
                                            listenable: EngineSvgPrep.instance,
                                            builder: (_, _) => SvgPicture.string(
                                              EngineSvgPrep.instance.prepared(board.svg),
                                              fit: BoxFit.fill,
                                            ),
                                          ),
                                        )
                                      : CustomPaint(
                                          painter: ArtboardPainter(
                                            nodes: board.nodes,
                                            accent: p.accent,
                                            entrance: _entrance,
                                            repaint: _entrance,
                                          ),
                                        ),
                                ),
                                for (final view in zoneViews)
                                  Positioned(
                                    left: view.zone.node.x * scale,
                                    top: view.zone.node.y * scale,
                                    width: math.max(4, view.zone.node.w * scale),
                                    height: math.max(4, view.zone.node.h * scale),
                                    child: _Hotspot(
                                      visible: _hotspotsVisible,
                                      showFrame: view.frame,
                                      onHover: (hovering) => _onHotspotHover(view.label, hovering),
                                      onTap: () => _onZoneTap(view.zone, board.id),
                                    ),
                                  ),
                                // toast：淡入 + 上滑入场，切换文案平滑过渡。
                                Positioned(
                                  left: 0,
                                  right: 0,
                                  bottom: 16,
                                  child: AnimatedSwitcher(
                                    duration: NonMotion.base,
                                    switchInCurve: NonMotion.curve,
                                    switchOutCurve: NonMotion.curve.flipped,
                                    transitionBuilder: (child, anim) => FadeTransition(
                                      opacity: anim,
                                      child: SlideTransition(
                                        position: Tween(begin: const Offset(0, 0.4), end: Offset.zero).animate(anim),
                                        child: child,
                                      ),
                                    ),
                                    child: _toast == null
                                        ? const SizedBox(height: 0)
                                        : Container(
                                            key: ValueKey(_toast),
                                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                            decoration: BoxDecoration(
                                              color: Colors.black.withValues(alpha: 0.82),
                                              borderRadius: BorderRadius.circular(8),
                                            ),
                                            child: Text(
                                              _toast!,
                                              style: const TextStyle(fontSize: 12, color: Colors.white),
                                            ),
                                          ),
                                  ),
                                ),
                                // 手势徽标：下落 + 淡入。
                                Positioned(
                                  left: 0,
                                  right: 0,
                                  top: 16,
                                  child: AnimatedSwitcher(
                                    duration: NonMotion.fast,
                                    switchInCurve: NonMotion.curve,
                                    switchOutCurve: NonMotion.curve.flipped,
                                    transitionBuilder: (child, anim) => FadeTransition(
                                      opacity: anim,
                                      child: SlideTransition(
                                        position: Tween(begin: const Offset(0, -0.5), end: Offset.zero).animate(anim),
                                        child: child,
                                      ),
                                    ),
                                    child: _badge == null
                                        ? const SizedBox(height: 0)
                                        : Container(
                                            key: ValueKey(_badge),
                                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                                            decoration: BoxDecoration(
                                              color: p.accent.withValues(alpha: 0.85),
                                              borderRadius: BorderRadius.circular(999),
                                            ),
                                            child: Text(
                                              _badge!,
                                              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.white),
                                            ),
                                          ),
                                  ),
                                ),
                                // 标注层：栈顶盖住热区，只在标注模式吃指针；
                                // 墨迹归一化存（换板/缩放不糊），中点贝塞尔平滑。
                                Positioned.fill(
                                  child: IgnorePointer(
                                    ignoring: !_inkMode,
                                    child: _InkLayer(
                                      strokes: _inks[board.id] ?? const [],
                                      onCommit: (stroke) => setState(() {
                                        (_inks[board.id] ??= []).add(stroke);
                                      }),
                                      color: p.accent,
                                      strokeWidth: 2 / scale,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            ),
                          ),
                        ),
                        // 热区 hover 提示条：画板**外**的浮动黑 pill（底部留白区），
                        // 不再贴在热区里压住文字/图标；文案仍是 _zoneLabel。
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 8,
                          child: IgnorePointer(
                            child: ValueListenableBuilder<String?>(
                              valueListenable: _hoverLabel,
                              builder: (context, label, _) {
                                return AnimatedSwitcher(
                                  duration: NonMotion.fast,
                                  switchInCurve: NonMotion.curve,
                                  switchOutCurve: NonMotion.curve.flipped,
                                  child: (label == null || label.isEmpty)
                                      ? const SizedBox(height: 0)
                                      : Center(
                                          child: Container(
                                            key: ValueKey(label),
                                            constraints: const BoxConstraints(maxWidth: 360),
                                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                            decoration: BoxDecoration(
                                              color: Colors.black.withValues(alpha: 0.82),
                                              borderRadius: BorderRadius.circular(999),
                                            ),
                                            child: Text(
                                              label,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(fontSize: 10, color: Colors.white),
                                            ),
                                          ),
                                        ),
                                );
                              },
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
              Container(
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(border: Border(top: BorderSide(color: p.line))),
                child: Text('Esc 退出 · ← 返回 · 点按、长按、滑动都能用',
                    style: TextStyle(fontSize: 10, color: Colors.white.withValues(alpha: 0.35))),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Hotzone list = outbound flows ∪ interaction markers (engine-authoritative
  /// via session_interactions; covers marker + builtin back) ∪, only when the
  /// engine listing is unavailable, the local back heuristic as fallback.
  /// Flows win — the engine resolves flow → marker → back in that order.
  List<_Hotzone> _hotzonesFor(Artboard board) {
    final render = _live ?? context.read<AppStore>().render;
    final hotzones = <_Hotzone>[];
    for (final flow in render.flows.where((f) => f.from == board.id)) {
      CanvasNode? target;
      for (final node in board.nodes) {
        if (node.id == flow.nodeId) target = node;
      }
      if (target != null) hotzones.add(_Hotzone(target, _ZoneKind.flow, flow.to));
    }
    final engineActions = _interactions[board.id];
    for (final node in board.nodes) {
      if (hotzones.any((h) => h.node.id == node.id)) continue;
      final acts = engineActions?.where((a) => a.node == node.id).toList() ?? const [];
      if (acts.isNotEmpty) {
        final isBack = acts.any((a) => a.kind == 'back' || a.source == 'builtin');
        hotzones.add(_Hotzone(node, isBack ? _ZoneKind.back : _ZoneKind.interact, null));
        continue;
      }
      // Engine listing unavailable (loading/failed) → heuristic fallback so the
      // demo never loses its back buttons. A successful empty listing is
      // authoritative: the engine says this board has no markers.
      if (engineActions == null) {
        final marker = _markerActionRe.firstMatch(node.name);
        if (marker != null) {
          final action = marker.group(1)!;
          hotzones.add(_Hotzone(node, action == 'back' ? _ZoneKind.back : _ZoneKind.interact, null));
          continue;
        }
        if (_backRe.hasMatch('${node.id} ${node.text}')) {
          hotzones.add(_Hotzone(node, _ZoneKind.back, null));
        }
      }
    }
    return hotzones;
  }

  /// Fetch session_interactions once per board; the result decides hotzones
  /// authoritatively (marker + builtin back) until the board changes.
  void _ensureInteractions(Artboard board) {
    if (_interactions.containsKey(board.id)) return;
    _interactions[board.id] = null; // pending
    final store = context.read<AppStore>();
    final api = store.api;
    final mbt = _liveMbt ?? store.mbt;
    if (api == null) return;
    api.session(mbt, 'session_interactions', board.id).then((res) {
      if (!mounted) return;
      final items = (res['data'] as List?) ?? const [];
      final list = <_EngineInteraction>[];
      for (final item in items.whereType<Map>()) {
        final node = (item['node'] ?? '').toString();
        if (node.isEmpty) continue;
        final action = item['action'];
        final kind = action is Map ? (action['kind'] ?? '').toString() : '';
        final source = (item['source'] ?? '').toString();
        String message = '';
        if (action is Map && action['params'] is Map) {
          message = ((action['params'] as Map)['message'] ?? '').toString();
        }
        list.add(_EngineInteraction(
          node: node,
          kind: kind,
          message: message,
          source: source,
          trigger: item['trigger']?.toString(),
          transition: item['transition']?.toString() ?? (item['action'] is Map ? ((item['action'] as Map)['transition'] ?? '').toString() : ''),
        ));
      }
      setState(() => _interactions[board.id] = list);
    }).catchError((_) {
      if (mounted) setState(() => _interactions[board.id] = null);
    });
  }

  /// Engine-known toast copy for an interact zone (used when the tap envelope
  /// carries no toast entry).
  String? _interactionMessage(String boardId, String nodeId) {
    final acts = _interactions[boardId];
    if (acts == null) return null;
    for (final a in acts) {
      if (a.node == nodeId && a.message.isNotEmpty) return a.message;
    }
    return null;
  }

  /// 手势中文（热区角标与引导条共用）。
  static String _triggerLabel(String? trigger) => switch (trigger) {
        'long_press' => '长按',
        'swipe_left' => '左滑',
        'swipe_right' => '右滑',
        'swipe_up' => '上滑',
        'swipe_down' => '下滑',
        'scroll_end' => '滚到底',
        'key_enter' => 'Enter',
        'focus' => '聚焦',
        'blur' => '失焦',
        'tap' => '点按',
        _ => '点按',
      };

  String _zoneLabel(_Hotzone zone) {
    switch (zone.kind) {
      case _ZoneKind.flow:
        return '点按 → ${zone.target}';
      case _ZoneKind.back:
        return '点按 返回';
      case _ZoneKind.interact:
        final acts = _interactions[zone.node.id];
        final trigger = acts?.firstWhere((a) => a.node == zone.node.id,
            orElse: () => const _EngineInteraction(node: '', kind: '', message: '', source: '')).trigger;
        final marker = _markerActionRe.firstMatch(zone.node.name);
        final action = marker?.group(1);
        final target = action == 'navigate_to' ? ' → ${zone.target ?? ''}' : '';
        return '${_triggerLabel(trigger ?? 'tap')}$target';
    }
  }

  /// 热区 hover → 画板外浮动提示条。退场只清自己那条标签，避免相邻热区
  /// 交错进出时把别人的提示误清（同名标签天然共享一条）。
  void _onHotspotHover(String label, bool hovering) {
    if (hovering) {
      _hoverLabel.value = label;
    } else if (_hoverLabel.value == label) {
      _hoverLabel.value = null;
    }
  }

  /// 嵌套热区只画最外层外框：某个热区被另一个热区完全包含时，内层不画
  /// 默认外框/角标（悬停高亮与点击语义保留），避免一叠色框压住内容。
  /// 完全同形的重叠取清单里第一个（来源顺序：flow → marker）。
  static bool _isOuterFrame(_Hotzone zone, List<_Hotzone> all) {
    final n = zone.node;
    final index = all.indexOf(zone);
    for (var i = 0; i < all.length; i++) {
      if (i == index) continue;
      final o = all[i].node;
      final contains = o.x <= n.x + 0.5 &&
          o.y <= n.y + 0.5 &&
          o.x + o.w >= n.x + n.w - 0.5 &&
          o.y + o.h >= n.y + n.h - 0.5;
      if (!contains) continue;
      final same = (o.x - n.x).abs() < 0.5 &&
          (o.y - n.y).abs() < 0.5 &&
          (o.w - n.w).abs() < 0.5 &&
          (o.h - n.h).abs() < 0.5;
      if (same && i > index) continue; // 同形重叠：保留第一个
      return false;
    }
    return true;
  }

  void _onZoneTap(_Hotzone zone, String boardId) {
    // 标注模式：圈画优先，热区点击短路（deepDesign play-ink-mode 同语义）。
    if (_inkMode) return;
    // 长按命中后松手会同时满足热区 tap 的判定，短窗内忽略 tap 防双发。
    final suppressed = _tapSuppressedUntil;
    if (suppressed != null && DateTime.now().isBefore(suppressed)) return;
    switch (zone.kind) {
      case _ZoneKind.back:
        _goBack();
        break;
      case _ZoneKind.flow:
      case _ZoneKind.interact:
        _engineTap(zone, boardId);
        break;
    }
  }

  /// Route the tap through the engine: node center → artboard coordinates →
  /// [NoNDesignApi.tap]. Navigation (flow / navigate_to) follows `current`; a
  /// changed `mbt` is re-rendered into the local [_live] overlay; toast text in
  /// `changes` floats at the frame bottom for 1.5s. If the call fails, a flow
  /// zone still navigates locally so the demo never dead-ends.
  String _pendingTransition = '';

  Future<void> _engineTap(_Hotzone zone, String boardId) async {
    if (_tapping) return;
    // 命中条目的过渡语义（interaction 优先，flow 兜底）。
    final acts = _interactions[boardId];
    final hit = acts?.where((a) => a.node == zone.node.id).toList() ?? const [];
    _pendingTransition = hit.isNotEmpty ? (hit.first.transition ?? '') : '';
    if (_pendingTransition.isEmpty && zone.kind == _ZoneKind.flow) {
      final flow = (_live ?? context.read<AppStore>().render).flows
          .where((f) => f.from == boardId && f.nodeId == zone.node.id)
          .toList();
      if (flow.isNotEmpty) _pendingTransition = flow.first.transition;
    }
    final store = context.read<AppStore>();
    final api = store.api;
    if (api == null) return;
    final sentMbt = _liveMbt ?? store.mbt;
    final node = zone.node;
    setState(() => _tapping = true);
    Map<String, dynamic> env;
    try {
      env = await api.tap(
        sentMbt,
        boardId,
        node.x + node.w / 2,
        node.y + node.h / 2,
      );
    } catch (_) {
      env = {'ok': false};
    }
    if (!mounted) return;
    setState(() => _tapping = false);
    if (env['ok'] != true) {
      if (zone.kind == _ZoneKind.flow && zone.target != null) {
        _navigateTo(zone.target!, from: boardId);
      }
      return;
    }
    final effect = await _applyEnvelope(api, env, boardId, sentMbt);
    if (!mounted) return;
    if (!effect.toasted && zone.kind == _ZoneKind.interact) {
      final known = _interactionMessage(boardId, zone.node.id);
      if (known != null && known.isNotEmpty) _showToast(known);
    }
  }

  /// Send one engine-0.2 gesture (session_event via api.event). Envelope
  /// handling is shared with tap: navigation follows `current`, state follows a
  /// mutated `mbt` (local re-render), toast follows `changes`. A hit briefly
  /// shows the gesture-name badge. Returns whether the envelope carried any
  /// visible effect — the ← key falls back to the local stack on a miss.
  Future<bool> _sendGesture(String spec, {required String badge}) async {
    if (_tapping) return false;
    final store = context.read<AppStore>();
    final api = store.api;
    if (api == null) return false;
    final render = _live ?? store.render;
    final board = render.board(_activeBoard ?? store.activeBoard);
    if (board == null) return false;
    final sentMbt = _liveMbt ?? store.mbt;
    setState(() => _tapping = true);
    Map<String, dynamic> env;
    try {
      env = await api.event(sentMbt, board.id, spec);
    } catch (_) {
      env = {'ok': false};
    }
    if (!mounted) return false;
    setState(() => _tapping = false);
    if (env['ok'] != true) return false;
    _showBadge(badge);
    final effect = await _applyEnvelope(api, env, board.id, sentMbt);
    return effect.any;
  }

  /// Shared envelope consumption for [NoNDesignApi.tap] and
  /// [NoNDesignApi.event]. Navigation
  /// wins over state re-render (same precedence as the original tap path); a
  /// toast alone counts as an effect. Returns which faces the envelope touched.
  Future<_EnvEffect> _applyEnvelope(
    NoNDesignApi api,
    Map<String, dynamic> env,
    String boardId,
    String sentMbt,
  ) async {
    var toasted = false;
    for (final change in (env['changes'] as List? ?? const [])) {
      final text = change.toString();
      if (text.startsWith('toast:')) {
        _showToast(_unwrapQuoted(text.substring(6)));
        toasted = true;
        break;
      }
      // 纯 haptic 交互（无 toast 无导航）：node_updated 命中该节点的
      // haptic 交互定义即震动——「能定义、能感受」。
      if (text.startsWith('node_updated:')) {
        final nodeId = text.substring('node_updated:'.length);
        final acts = _interactions[boardId];
        if (acts != null && acts.any((a) => a.node == nodeId && a.kind == 'haptic')) {
          HapticFeedback.mediumImpact();
        }
      }
    }
    final current = (env['current'] ?? '').toString();
    if (current.isNotEmpty && current != boardId) {
      _navigateTo(current, from: boardId, transition: _pendingTransition);
      return _EnvEffect(toasted: toasted, navigated: true, mutated: false);
    }
    final newMbt = (env['mbt'] ?? '').toString();
    if (newMbt.isEmpty || newMbt == sentMbt) {
      return _EnvEffect(toasted: toasted, navigated: false, mutated: false);
    }
    try {
      final res = await api.render(newMbt);
      if (res['ok'] == true && mounted) {
        setState(() {
          _live = RenderEnvelope.fromJson(res);
          _liveMbt = newMbt;
        });
      }
    } catch (_) {
      // render failed — keep the current frame; the next event retries with the
      // mutated mbt anyway.
      _liveMbt = newMbt;
    }
    return _EnvEffect(toasted: toasted, navigated: false, mutated: true);
  }

  /// 键盘按键转发（engine-0.2 手势面）。Enter → `key_enter`；方向键 →
  /// `key:up|down|left|right`（探针实证：裸 token `key_up` 等被 unknown_event
  /// 拒绝，冒号形可用）。← 在引擎无效果时回退本地返回栈，保持「← 返回」可用。
  /// Esc 忽略并冒泡给外层 CallbackShortcuts 退出演示。
  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) return KeyEventResult.ignored;
    String? spec;
    var badge = '';
    var isBackKey = false;
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      spec = 'key_enter';
      badge = 'Enter';
    } else if (key == LogicalKeyboardKey.arrowUp) {
      spec = 'key:up';
      badge = '↑';
    } else if (key == LogicalKeyboardKey.arrowDown) {
      spec = 'key:down';
      badge = '↓';
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      spec = 'key:left';
      badge = '←';
      isBackKey = true;
    } else if (key == LogicalKeyboardKey.arrowRight) {
      spec = 'key:right';
      badge = '→';
    }
    if (spec == null) return KeyEventResult.ignored;
    unawaited(_sendGesture(spec, badge: badge).then((effect) {
      if (isBackKey && !effect && mounted) _goBack();
    }));
    return KeyEventResult.handled;
  }

  // ---- 整板指针手势：长按（500ms 未移动）/ 快速滑动 ----

  void _onBoardPointerDown(PointerDownEvent e, Artboard board) {
    // 标注模式下手绘优先：长按/滑动识别静默（墨迹层自己吃指针）。
    if (_inkMode) return;
    _longPressTimer?.cancel();
    if (_pressPointer != null) return; // 只跟踪第一根指针
    _pressPointer = e.pointer;
    _pressBoard = Offset(e.localPosition.dx / _scale, e.localPosition.dy / _scale);
    _pressAt = DateTime.now();
    _pressMoved = false;
    _longPressSent = false;
    _longPressTimer = Timer(const Duration(milliseconds: _longPressMs), () {
      if (!mounted || _pressPointer == null || _pressMoved || _pressBoard == null) return;
      final p = _pressBoard!;
      _longPressSent = true;
      _tapSuppressedUntil = DateTime.now().add(const Duration(milliseconds: 700));
      unawaited(_sendGesture(
        'long_press:${_boardCoord(p.dx, board.width)}:${_boardCoord(p.dy, board.height)}:$_longPressMs',
        badge: '长按',
      ));
    });
  }

  void _onBoardPointerMove(PointerMoveEvent e) {
    if (e.pointer != _pressPointer) return;
    if (_pressMoved) return;
    final start = _pressBoard;
    if (start == null) return;
    final now = Offset(e.localPosition.dx / _scale, e.localPosition.dy / _scale);
    if ((now - start).distance > _pressSlop) _pressMoved = true;
  }

  void _onBoardPointerUp(PointerUpEvent e, Artboard board) {
    if (e.pointer != _pressPointer) return;
    _longPressTimer?.cancel();
    final start = _pressBoard;
    final at = _pressAt;
    final longPressFired = _longPressSent;
    _pressPointer = null;
    _pressBoard = null;
    _pressAt = null;
    _pressMoved = false;
    _longPressSent = false;
    // 长按已在按下 500ms 时发出，松手不再重复触发；未移动的松手是普通 tap，
    // 交给热区 GestureDetector。
    if (longPressFired || start == null || at == null || !_pressMoved) return;
    final delta = Offset(e.localPosition.dx / _scale, e.localPosition.dy / _scale) - start;
    final elapsed = DateTime.now().difference(at);
    if (delta.distance < _swipeMinDistance || elapsed > _swipeMaxDuration) return;
    String spec;
    String badge;
    if (delta.dx.abs() >= delta.dy.abs()) {
      if (delta.dx < 0) {
        spec = 'swipe_left';
        badge = '左滑';
      } else {
        spec = 'swipe_right';
        badge = '右滑';
      }
    } else {
      if (delta.dy < 0) {
        spec = 'swipe_up';
        badge = '上滑';
      } else {
        spec = 'swipe_down';
        badge = '下滑';
      }
    }
    unawaited(_sendGesture(
      '$spec:${_boardCoord(start.dx, board.width)}:${_boardCoord(start.dy, board.height)}',
      badge: badge,
    ));
  }

  void _onBoardPointerCancel(PointerCancelEvent e) {
    if (e.pointer != _pressPointer) return;
    _longPressTimer?.cancel();
    _pressPointer = null;
    _pressBoard = null;
    _pressAt = null;
    _pressMoved = false;
    _longPressSent = false;
  }

  /// 当前板可用的演示手势集合 → 引导文案。
  String _guideText(Artboard board) {
    final triggers = <String>{'点按热区'};
    for (final zone in _hotzonesFor(board)) {
      final acts = _interactions[zone.node.id];
      final t = acts?.isNotEmpty == true ? acts!.first.trigger : null;
      if (t != null && t != 'tap') triggers.add(_triggerLabel(t));
    }
    return '${triggers.join(' · ')} · ← 返回 · Esc 退出';
  }

  /// 画板坐标取整并钳制在画板范围内（引擎事件坐标是整数像素语义）。
  int _boardCoord(double px, double max) {
    final v = px.isFinite ? px.round() : 0;
    final m = max.round();
    if (v < 0) return 0;
    if (v > m) return m;
    return v;
  }

  void _navigateTo(String target, {required String from, String transition = ''}) {
    setState(() {
      _stack.add(from);
      _stackT.add(transition);
      _activeBoard = target;
      _lastTransition = transition;
    });
    // 换板入场：motion=fade_in 节点重新呼吸一次（250ms）。
    _entranceCtl.forward(from: 0);
  }

  void _restart() {
    _toastTimer?.cancel();
    _badgeTimer?.cancel();
    _longPressTimer?.cancel();
    setState(() {
      _stack.clear();
      _stackT.clear();
      _activeBoard = null;
      _live = null;
      _liveMbt = null;
      _toast = null;
      _badge = null;
    });
    // 重启回到起始板：换板语义，入场呼吸重播。
    _entranceCtl.forward(from: 0);
  }

  void _showToast(String message) {
    if (message.isEmpty) return;
    _toastTimer?.cancel();
    setState(() => _toast = message);
    _toastTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _toast = null);
    });
  }

  void _showBadge(String label) {
    if (label.isEmpty) return;
    _badgeTimer?.cancel();
    setState(() => _badge = label);
    _badgeTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _badge = null);
    });
  }

  static String _unwrapQuoted(String value) {
    final v = value.trim();
    if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) {
      return v.substring(1, v.length - 1);
    }
    return v;
  }

  /// 返回（热区 back / ← 键兜底同源）。栈底铁律（deepDesign playBack 语义）：
  /// 先看交互图——当前板有入边（tap: 触发、自环不计）则回退到来源页
  /// （新栈仍为空：可继续沿图回退），真无入边才原地拦截提示；绝不退出演示。
  void _goBack() {
    final store = context.read<AppStore>();
    if (_stack.isEmpty) {
      final render = _live ?? store.render;
      final cur = _activeBoard ?? store.activeBoard;
      final inbound = render.flows
          .where((f) => f.to == cur && f.from != cur && f.trigger.startsWith('tap:'))
          .toList();
      if (inbound.isNotEmpty) {
        final source = inbound.last.from;
        _toastTimer?.cancel();
        setState(() {
          _activeBoard = source;
          _lastTransition = 'pop';
          _toast = null;
        });
        _entranceCtl.forward(from: 0);
        _showToast('按交互流回退');
      } else {
        _showToast('已是起始页 · 返回不可用');
      }
      return;
    }
    final prev = _stack.removeLast();
    // 返回方向感知：从前进时的过渡推导反向语义（modal_present→modal_dismiss，
    // 其余统一 pop），消除「返回复用前进滑入方向」。
    final forwardT = _stackT.isNotEmpty ? _stackT.removeLast() : '';
    _toastTimer?.cancel();
    setState(() {
      _activeBoard = prev;
      _lastTransition = forwardT == 'modal_present' ? 'modal_dismiss' : 'pop';
      _toast = null;
    });
    _entranceCtl.forward(from: 0);
  }
}

/// 演示标注层：Listener 收指针（归一化存点），CustomPaint 中点贝塞尔平滑
/// 连线绘制。线宽 2/scale 由调用方算好传入（缩放补偿）。
class _InkLayer extends StatefulWidget {
  final List<List<Offset>> strokes;
  final ValueChanged<List<Offset>> onCommit;
  final Color color;
  final double strokeWidth;
  const _InkLayer({
    required this.strokes,
    required this.onCommit,
    required this.color,
    required this.strokeWidth,
  });

  @override
  State<_InkLayer> createState() => _InkLayerState();
}

class _InkLayerState extends State<_InkLayer> {
  List<Offset>? _current;

  Offset _normalize(Offset local, Size size) => Offset(
        local.dx / math.max(1, size.width),
        local.dy / math.max(1, size.height),
      );

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (e) => _current = [_normalize(e.localPosition, size)],
          onPointerMove: (e) {
            final stroke = _current;
            if (stroke == null) return;
            final p = _normalize(e.localPosition, size);
            if ((p - stroke.last).distance < 0.002) return; // 归一化域抽稀
            stroke.add(p);
            setState(() {});
          },
          onPointerUp: (e) {
            final stroke = _current;
            _current = null;
            if (stroke != null && stroke.length >= 2) widget.onCommit(stroke);
            if (stroke != null) setState(() {});
          },
          onPointerCancel: (e) {
            _current = null;
            setState(() {});
          },
          child: CustomPaint(
            painter: _InkPainter(
              strokes: widget.strokes,
              current: _current,
              color: widget.color,
              strokeWidth: widget.strokeWidth,
            ),
          ),
        );
      },
    );
  }
}

class _InkPainter extends CustomPainter {
  final List<List<Offset>> strokes;
  final List<Offset>? current;
  final Color color;
  final double strokeWidth;
  const _InkPainter({
    required this.strokes,
    required this.current,
    required this.color,
    required this.strokeWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    Offset px(Offset p) => Offset(p.dx * size.width, p.dy * size.height);
    void drawStroke(List<Offset> stroke) {
      if (stroke.length < 2) {
        if (stroke.isNotEmpty) canvas.drawCircle(px(stroke.first), strokeWidth / 2, paint);
        return;
      }
      final path = Path()..moveTo(px(stroke.first).dx, px(stroke.first).dy);
      // 中点二次贝塞尔平滑（手绘圆头笔感）。
      for (var i = 1; i < stroke.length - 1; i++) {
        final mid = (px(stroke[i]) + px(stroke[i + 1])) / 2;
        path.quadraticBezierTo(px(stroke[i]).dx, px(stroke[i]).dy, mid.dx, mid.dy);
      }
      final last = px(stroke.last);
      path.lineTo(last.dx, last.dy);
      canvas.drawPath(path, paint);
    }

    for (final stroke in strokes) {
      drawStroke(stroke);
    }
    final live = current;
    if (live != null) drawStroke(live);
  }

  @override
  bool shouldRepaint(covariant _InkPainter old) =>
      old.strokes != strokes || old.current != current || old.color != color || old.strokeWidth != strokeWidth;
}

enum _ZoneKind { flow, back, interact }

/// Which faces an engine envelope (tap / event) touched. `any` decides the
/// key:left → local-stack fallback.
class _EnvEffect {
  final bool toasted;
  final bool navigated;
  final bool mutated;
  const _EnvEffect({required this.toasted, required this.navigated, required this.mutated});
  bool get any => toasted || navigated || mutated;
}

/// One session_interactions record, normalized: node id + action kind + toast
/// copy + source ("marker" for interact markers, "builtin" for engine back).
class _EngineInteraction {
  final String node;
  final String kind;
  final String message;
  final String source;
  /// 触发方式（tap/long_press/swipe_left…）与过渡（push/fade…）——热区
  /// 角标与引导条的直接数据源（engine-0.2 session_interactions 提供）。
  final String? trigger;
  final String? transition;
  const _EngineInteraction({required this.node, required this.kind, required this.message, required this.source, this.trigger, this.transition});
}

class _Hotzone {
  final CanvasNode node;
  final _ZoneKind kind;
  final String? target;
  _Hotzone(this.node, this.kind, this.target);
}

class _Hotspot extends StatefulWidget {
  final VoidCallback onTap;
  const _Hotspot({
    required this.onTap,
    this.visible = true,
    this.showFrame = true,
    this.onHover,
  });

  /// false = 隐藏热区视觉（真实成品观感），点击交互保留（原版 toggleHotZones 语义）。
  final bool visible;

  /// 嵌套热区只画最外层外框：内层不画默认框/角标，但点击与悬停反馈保留。
  final bool showFrame;

  /// hover 起落交给画板外的浮动提示条（标签不再压在内容上）。
  final ValueChanged<bool>? onHover;

  @override
  State<_Hotspot> createState() => _HotspotState();
}

class _HotspotState extends State<_Hotspot> {
  bool _hover = false;

  void _setHover(bool value) {
    if (_hover == value) return;
    setState(() => _hover = value);
    widget.onHover?.call(value);
  }

  @override
  void dispose() {
    // 换板/隐藏热区时热区被重建：清掉画板外提示条，避免残留上一块板的旧标签。
    if (_hover) widget.onHover?.call(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    // 默认态**不铺色块**（旧版 0.07 填充 + 1.4px 0.38 边框整片糊住头像/文字/
    // 图标）：只留 1px ≤0.22 alpha 的轻外框 + 右上角 5px 可点小圆点；hover 才
    // 增强外框并给 ≤0.06 alpha 的极浅填充。visible=false 时默认完全无视觉
    // （真实成品观感），悬停仍有提示（可发现性），点击语义全程不变。
    final showOutline = widget.visible && widget.showFrame;
    final showDot = widget.visible && widget.showFrame && !_hover;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => _setHover(true),
      onExit: (_) => _setHover(false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Stack(
          children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  border: (_hover || showOutline)
                      ? Border.all(
                          color: p.accent.withValues(alpha: _hover ? 0.70 : 0.22),
                          width: _hover ? 1.5 : 1,
                        )
                      : null,
                  color: _hover ? p.accent.withValues(alpha: 0.06) : Colors.transparent,
                ),
              ),
            ),
            if (showDot)
              Positioned(
                right: 2,
                top: 2,
                child: IgnorePointer(
                  child: Container(
                    width: 5,
                    height: 5,
                    decoration: BoxDecoration(
                      color: p.accent.withValues(alpha: 0.55),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
