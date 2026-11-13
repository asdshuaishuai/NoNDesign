import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/api.dart';
import '../core/models.dart';
import '../core/store.dart';
import '../core/theme.dart';
import 'canvas_view.dart';
import 'common.dart';

/// Demo mode is engine-driven: hotzone taps go through POST /engine/tap
/// (session_tap) and the engine-0.2 gesture face (long press / swipe / keys)
/// goes through api.event → POST /engine/event (session_event). Both return
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

class _PlayViewState extends State<PlayView> {
  final List<String> _stack = [];
  RenderEnvelope? _live;
  String? _liveMbt;
  String? _activeBoard;
  bool _tapping = false;
  String? _toast;
  Timer? _toastTimer;
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
  void dispose() {
    _toastTimer?.cancel();
    _badgeTimer?.cancel();
    _longPressTimer?.cancel();
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
    _ensureInteractions(board);

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () => store.setView('design'),
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
                decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0x14FFFFFF)))),
                child: Row(
                  children: [
                    IconAction(icon: Icons.close, tooltip: '退出演示 Esc', size: 28, onTap: () => store.setView('design')),
                    const SizedBox(width: 6),
                    Pill(label: '演示模式', color: p.accent, background: p.accent.withValues(alpha: 0.14)),
                    const SizedBox(width: 8),
                    Text(board.name.isEmpty ? board.id : board.name,
                        style: const TextStyle(fontSize: 12, color: Color(0xFFA6ADBD))),
                    const SizedBox(width: 6),
                    Text('${render.artboards.indexWhere((b) => b.id == board.id) + 1} / ${render.artboards.length}',
                        style: const TextStyle(fontSize: 10, fontFamily: 'Menlo', color: Color(0xFF737B8D))),
                    const Spacer(),
                    IconAction(icon: Icons.chevron_left, tooltip: '返回上一页 ←', size: 28, onTap: _goBack),
                    IconAction(
                      icon: Icons.restart_alt,
                      tooltip: '重新开始',
                      size: 28,
                      onTap: _restart,
                    ),
                  ],
                ),
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
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(8),
                              boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.55), blurRadius: 60, offset: const Offset(0, 30))],
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: Stack(
                              children: [
                                Positioned.fill(
                                  child: CustomPaint(painter: ArtboardPainter(nodes: board.nodes, accent: p.accent)),
                                ),
                                for (final zone in hotzones)
                                  Positioned(
                                    left: zone.node.x * scale,
                                    top: zone.node.y * scale,
                                    width: math.max(4, zone.node.w * scale),
                                    height: math.max(4, zone.node.h * scale),
                                    child: _Hotspot(
                                      label: _zoneLabel(zone),
                                      onTap: () => _onZoneTap(zone, board.id),
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
                              ],
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
                decoration: const BoxDecoration(border: Border(top: BorderSide(color: Color(0x14FFFFFF)))),
                child: Text('Esc 退出 · ← 返回 · 点按/长按/滑动/按键均由引擎驱动',
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
        list.add(_EngineInteraction(node: node, kind: kind, message: message, source: source));
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

  String _zoneLabel(_Hotzone zone) {
    switch (zone.kind) {
      case _ZoneKind.flow:
        return '→ ${zone.target}';
      case _ZoneKind.back:
        return '返回';
      case _ZoneKind.interact:
        final marker = _markerActionRe.firstMatch(zone.node.name);
        return marker?.group(1) ?? '交互';
    }
  }

  void _onZoneTap(_Hotzone zone, String boardId) {
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
  /// POST /engine/tap. Navigation (flow / navigate_to) follows `current`; a
  /// changed `mbt` is re-rendered into the local [_live] overlay; toast text in
  /// `changes` floats at the frame bottom for 1.5s. If the call fails, a flow
  /// zone still navigates locally so the demo never dead-ends.
  Future<void> _engineTap(_Hotzone zone, String boardId) async {
    if (_tapping) return;
    final store = context.read<AppStore>();
    final api = store.api;
    if (api == null) return;
    final sentMbt = _liveMbt ?? store.mbt;
    final node = zone.node;
    setState(() => _tapping = true);
    Map<String, dynamic> env;
    try {
      env = await api.postJson('/engine/tap', {
        'mbt': sentMbt,
        'artboard': boardId,
        'x': node.x + node.w / 2,
        'y': node.y + node.h / 2,
      });
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

  /// Shared envelope consumption for /engine/tap and /engine/event. Navigation
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
    }
    final current = (env['current'] ?? '').toString();
    if (current.isNotEmpty && current != boardId) {
      _navigateTo(current, from: boardId);
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

  /// 画板坐标取整并钳制在画板范围内（引擎事件坐标是整数像素语义）。
  int _boardCoord(double px, double max) {
    final v = px.isFinite ? px.round() : 0;
    final m = max.round();
    if (v < 0) return 0;
    if (v > m) return m;
    return v;
  }

  void _navigateTo(String target, {required String from}) {
    setState(() {
      _stack.add(from);
      _activeBoard = target;
    });
  }

  void _restart() {
    _toastTimer?.cancel();
    _badgeTimer?.cancel();
    _longPressTimer?.cancel();
    setState(() {
      _stack.clear();
      _activeBoard = null;
      _live = null;
      _liveMbt = null;
      _toast = null;
      _badge = null;
    });
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

  void _goBack() {
    final store = context.read<AppStore>();
    if (_stack.isEmpty) {
      store.setView('design');
      return;
    }
    final prev = _stack.removeLast();
    _toastTimer?.cancel();
    setState(() {
      _activeBoard = prev;
      _toast = null;
    });
  }
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
  const _EngineInteraction({required this.node, required this.kind, required this.message, required this.source});
}

class _Hotzone {
  final CanvasNode node;
  final _ZoneKind kind;
  final String? target;
  _Hotzone(this.node, this.kind, this.target);
}

class _Hotspot extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  const _Hotspot({required this.label, required this.onTap});

  @override
  State<_Hotspot> createState() => _HotspotState();
}

class _HotspotState extends State<_Hotspot> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: _hover ? p.accent.withValues(alpha: 0.70) : Colors.transparent, width: 2),
            borderRadius: BorderRadius.circular(3),
            color: _hover ? p.accent.withValues(alpha: 0.10) : Colors.transparent,
          ),
          child: _hover
              ? Align(
                  alignment: Alignment.bottomCenter,
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 2),
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.8), borderRadius: BorderRadius.circular(3)),
                    child: Text(widget.label, style: const TextStyle(fontSize: 10, color: Colors.white)),
                  ),
                )
              : null,
        ),
      ),
    );
  }
}
