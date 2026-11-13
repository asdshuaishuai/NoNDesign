import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/material.dart' hide Flow;
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/models.dart';
import '../core/keys.dart';
import '../core/store.dart';
import '../core/theme.dart';
import 'common.dart';

class CanvasView extends StatefulWidget {
  const CanvasView({super.key});

  @override
  State<CanvasView> createState() => _CanvasViewState();
}

class BoardLayout {
  final Map<String, Rect> positions;
  final Size total;
  final String key;
  const BoardLayout(this.positions, this.total, this.key);
}

BoardLayout layoutBoards(List<Artboard> boards) {
  const gap = 96.0;
  const labelH = 34.0;
  if (boards.isEmpty) return const BoardLayout({}, Size(800, 600), 'empty');
  final maxW = boards.map((b) => b.width).reduce(math.max);
  final maxH = boards.map((b) => b.height).reduce(math.max);
  final cols = math.min(4, math.max(1, math.sqrt(boards.length).ceil()));
  final rows = (boards.length / cols).ceil();
  final cellW = maxW + gap;
  final cellH = maxH + labelH + gap;
  final positions = <String, Rect>{};
  for (var i = 0; i < boards.length; i++) {
    final b = boards[i];
    final col = i % cols;
    final row = i ~/ cols;
    positions[b.id] = Rect.fromLTWH(
      col * cellW + (maxW - b.width) / 2,
      row * cellH + labelH,
      b.width,
      b.height,
    );
  }
  return BoardLayout(
    positions,
    Size(cols * cellW - gap, rows * cellH - gap + labelH),
    '${boards.length}:${boards.map((b) => '${b.id}-${b.width}x${b.height}').join(',')}',
  );
}

/// 引擎 image/avatar 组件的图片地址存放在 node.text。
/// 仅接受 http(s) URL；其余内容按普通文本走既有渲染路径。
String? _nodeImageUrl(CanvasNode node) {
  if (node.component != 'image' && node.component != 'avatar') return null;
  final url = node.text.trim();
  final lower = url.toLowerCase();
  if (lower.startsWith('http://') || lower.startsWith('https://')) return url;
  return null;
}

/// 画布图片内存缓存：nodeId → 已解码 ui.Image。
/// 网络加载只发生在 ensure()（widget 构建期幂等触发，异步完成），
/// ArtboardPainter 在 paint 里只读缓存，绝不发网络请求。
/// 加载/失败后 notifyListeners()，画布经 CustomPaint(repaint:) 重绘；
/// 加载中与失败一律回退到既有占位符。
/// 条目与 Flutter 框架 ImageCache 共享底层解码结果，因此从不主动
/// dispose ui.Image——淘汰只丢弃引用，交给 GC finalizer 回收。
class NodeImageCache extends ChangeNotifier {
  NodeImageCache._();
  static final NodeImageCache instance = NodeImageCache._();

  static const _maxEntries = 64;

  final Map<String, ui.Image> _images = {};
  final Map<String, String> _attempted = {}; // nodeId → 最近尝试的 URL（成功或失败都算）
  final Map<String, String> _pending = {};
  final Set<String> _failed = {};

  ui.Image? imageOf(String nodeId) => _images[nodeId];
  bool failed(String nodeId) => _failed.contains(nodeId);

  /// 对单个 image/avatar 节点发起异步预加载（幂等）。
  /// 同一 URL 不重复请求；URL 变更时丢弃旧图重载；失败不自动重试。
  void ensure(CanvasNode node) {
    final url = _nodeImageUrl(node);
    if (url == null) {
      _drop(node.id);
      return;
    }
    if (_attempted[node.id] == url && _pending[node.id] == null) return; // 已加载/已失败
    if (_pending[node.id] == url) return; // 加载中
    _drop(node.id); // URL 变更：丢旧图重载
    _pending[node.id] = url;
    final stream = NetworkImage(url).resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener((info, _) {
      stream.removeListener(listener);
      if (_pending[node.id] != url) return; // 加载期间 URL 又变了：丢弃过期结果
      _pending.remove(node.id);
      _attempted[node.id] = url;
      _images[node.id] = info.image;
      _failed.remove(node.id);
      _evictIfNeeded();
      notifyListeners();
    }, onError: (Object error, StackTrace? stackTrace) {
      stream.removeListener(listener);
      if (_pending[node.id] != url) return;
      _pending.remove(node.id);
      _attempted[node.id] = url;
      _failed.add(node.id);
      notifyListeners();
    });
    stream.addListener(listener);
  }

  void _drop(String id) {
    _pending.remove(id);
    _images.remove(id);
    _attempted.remove(id);
    _failed.remove(id);
  }

  /// 超出容量时按插入序淘汰最旧的（不淘汰加载中的）。
  void _evictIfNeeded() {
    while (_images.length > _maxEntries) {
      String? oldest;
      for (final id in _images.keys) {
        if (!_pending.containsKey(id)) {
          oldest = id;
          break;
        }
      }
      if (oldest == null) break;
      _images.remove(oldest);
      _attempted.remove(oldest);
      _failed.remove(oldest);
    }
  }
}

enum _ResizeHandle { topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left }

SystemMouseCursor _resizeCursor(_ResizeHandle handle) => switch (handle) {
      _ResizeHandle.topLeft || _ResizeHandle.bottomRight => SystemMouseCursors.resizeUpLeftDownRight,
      _ResizeHandle.topRight || _ResizeHandle.bottomLeft => SystemMouseCursors.resizeUpRightDownLeft,
      _ResizeHandle.top => SystemMouseCursors.resizeUp,
      _ResizeHandle.bottom => SystemMouseCursors.resizeDown,
      _ResizeHandle.left => SystemMouseCursors.resizeLeft,
      _ResizeHandle.right => SystemMouseCursors.resizeRight,
    };

class _CanvasViewState extends State<CanvasView> {
  final TransformationController _controller = TransformationController();
  final FocusNode _canvasFocus = FocusNode(debugLabel: 'canvas');
  String? _draggingId;
  Offset _dragDelta = Offset.zero;
  bool _nodePressed = false;
  // 8 向缩放手势状态：拖手柄期间 painter 用 ghost 矩形实时绘制。
  String? _resizingId;
  _ResizeHandle? _resizeHandle;
  Rect _resizeStart = Rect.zero;
  Offset _resizeDelta = Offset.zero;
  bool _handlePressed = false;
  // 方向键微调串行链：连续按键逐个排队，每次从最新已提交位置计算，
  // 避免自动重复按键并发调用 applyOp 造成陈旧 mbt 丢失更新。
  Future<void> _nudgeChain = Future<void>.value();
  String _lastLayoutKey = '';
  int _lastFitEpoch = -1;

  bool get _resizing => _resizingId != null;

  @override
  void dispose() {
    _controller.dispose();
    _canvasFocus.dispose();
    super.dispose();
  }

  void _fit(Size viewport, BoardLayout layout) {
    if (layout.total.width <= 0 || layout.total.height <= 0) return;
    final scale = math.min(
      math.min((viewport.width - 120) / layout.total.width, (viewport.height - 120) / layout.total.height),
      1.0,
    ).clamp(0.08, 4.0);
    final dx = (viewport.width - layout.total.width * scale) / 2;
    final dy = (viewport.height - layout.total.height * scale) / 2;
    _controller.value = Matrix4.identity()
      ..translate(dx, dy)
      ..scale(scale);
  }

  void _scaleBy(double factor, Size viewport, Offset focal) {
    final current = _controller.value.getMaxScaleOnAxis();
    final target = (current * factor).clamp(0.08, 4.0);
    final scene = _controller.toScene(focal);
    _controller.value = Matrix4.identity()
      ..translate(focal.dx, focal.dy)
      ..scale(target)
      ..translate(-scene.dx, -scene.dy);
  }

  /// 画布焦点下的键盘处理：方向键微调选中节点，Esc 取消选择。
  /// 未绑定的按键一律 ignored，继续冒泡给上层 CallbackShortcuts。
  KeyEventResult _handleCanvasKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final store = context.read<AppStore>();
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (store.selectedNode != null) {
        store.selectNode(null);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (store.selectedNode == null) return KeyEventResult.ignored;
    if (store.agentBusy) return KeyEventResult.handled;
    final step = HardwareKeyboard.instance.isShiftPressed ? 8.0 : 1.0;
    final key = event.logicalKey;
    var dx = 0.0;
    var dy = 0.0;
    if (key == LogicalKeyboardKey.arrowLeft) {
      dx = -step;
    } else if (key == LogicalKeyboardKey.arrowRight) {
      dx = step;
    } else if (key == LogicalKeyboardKey.arrowUp) {
      dy = -step;
    } else if (key == LogicalKeyboardKey.arrowDown) {
      dy = step;
    } else {
      return KeyEventResult.ignored;
    }
    _enqueueNudge(store.selectedNode!, dx, dy);
    return KeyEventResult.handled;
  }

  void _enqueueNudge(String nodeId, double dx, double dy) {
    _nudgeChain = _nudgeChain
        .then((_) => _runNudge(nodeId, dx, dy))
        .catchError((Object error) {});
  }

  Future<void> _runNudge(String nodeId, double dx, double dy) async {
    if (!mounted) return;
    final store = context.read<AppStore>();
    if (store.agentBusy) return;
    final node = store.node;
    if (node == null || node.id != nodeId) return;
    await store.moveNode(nodeId, node.x + dx, node.y + dy);
  }

  Rect _applyHandle(Rect start, Offset delta, _ResizeHandle handle) {
    const minSide = 8.0;
    var left = start.left;
    var top = start.top;
    var right = start.right;
    var bottom = start.bottom;
    if (handle == _ResizeHandle.topLeft || handle == _ResizeHandle.left || handle == _ResizeHandle.bottomLeft) {
      left = math.min(left + delta.dx, right - minSide);
    }
    if (handle == _ResizeHandle.topRight || handle == _ResizeHandle.right || handle == _ResizeHandle.bottomRight) {
      right = math.max(right + delta.dx, left + minSide);
    }
    if (handle == _ResizeHandle.topLeft || handle == _ResizeHandle.top || handle == _ResizeHandle.topRight) {
      top = math.min(top + delta.dy, bottom - minSide);
    }
    if (handle == _ResizeHandle.bottomLeft || handle == _ResizeHandle.bottom || handle == _ResizeHandle.bottomRight) {
      bottom = math.max(bottom + delta.dy, top + minSide);
    }
    return Rect.fromLTRB(left, top, right, bottom);
  }

  Rect? get _resizeGhost =>
      _resizing ? _applyHandle(_resizeStart, _resizeDelta, _resizeHandle ?? _ResizeHandle.bottomRight) : null;

  Future<void> _editText(AppStore store, CanvasNode node) async {
    final controller = TextEditingController(text: node.text);
    final value = await showNonDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('编辑文本', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        content: SizedBox(
          width: 360,
          child: TextField(
            controller: controller,
            autofocus: true,
            maxLines: 4,
            minLines: 1,
            decoration: const InputDecoration(hintText: '节点文本'),
            onSubmitted: (v) => Navigator.pop(context, v),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('应用'),
          ),
        ],
      ),
    );
    if (value != null && value != node.text) {
      await store.updateNode(node.id, {'text': value});
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final p = context.palette;
    final source = store.agentBusy && store.previewRender != null ? store.previewRender! : store.render;
    final boards = source.artboards;
    final layout = layoutBoards(boards);
    final activeBoard = store.activeBoard;

    return Focus(
      focusNode: _canvasFocus,
      autofocus: true,
      skipTraversal: true,
      onKeyEvent: _handleCanvasKey,
      child: LayoutBuilder(
      builder: (context, constraints) {
        final viewport = Size(constraints.maxWidth, constraints.maxHeight);
        if (layout.key != _lastLayoutKey || _lastFitEpoch != store.fitEpoch) {
          _lastLayoutKey = layout.key;
          _lastFitEpoch = store.fitEpoch;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _fit(viewport, layout);
          });
        }
        return Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                transformationController: _controller,
                constrained: false,
                boundaryMargin: const EdgeInsets.all(800),
                minScale: 0.08,
                maxScale: 4,
                panEnabled: !_nodePressed && !_handlePressed,
                trackpadScrollCausesScale: true,
                child: SizedBox(
                  width: layout.total.width + 160,
                  height: layout.total.height + 160,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        // RepaintBoundary：flow 连线层独立栅格化，板内重绘不连带。
                        child: RepaintBoundary(
                          child: CustomPaint(
                            painter: FlowPainter(
                            boards: boards,
                            positions: layout.positions,
                            flows: source.flows,
                            accent: p.accent,
                              zoom: _controller.value.getMaxScaleOnAxis(),
                            ),
                          ),
                        ),
                      ),
                      for (final b in boards)
                        _boardWidget(store, b, layout.positions[b.id]!.topLeft + const Offset(80, 80), activeBoard == b.id),
                    ],
                  ),
                ),
              ),
            ),
            if (boards.isEmpty) _EmptyCanvas(store: store),
            Positioned(
              left: 12,
              bottom: 12,
              child: _CanvasHud(
                controller: _controller,
                onZoomIn: () {
                  _canvasFocus.requestFocus();
                  _scaleBy(1.2, viewport, Offset(viewport.width / 2, viewport.height / 2));
                },
                onZoomOut: () {
                  _canvasFocus.requestFocus();
                  _scaleBy(1 / 1.2, viewport, Offset(viewport.width / 2, viewport.height / 2));
                },
                onFit: () {
                  _canvasFocus.requestFocus();
                  _fit(viewport, layout);
                },
                flows: store.settings.theme,
              ),
            ),
            Positioned(
              right: 12,
              bottom: 12,
              child: Row(
                children: [
                  if (store.agentBusy && store.previewRender != null)
                    Container(
                      margin: const EdgeInsets.only(right: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                      decoration: BoxDecoration(
                        color: p.accentSoft,
                        borderRadius: BorderRadius.circular(7),
                        border: Border.all(color: p.accent.withValues(alpha: 0.3)),
                      ),
                      child: Row(
                        children: [
                          Container(width: 5, height: 5, decoration: BoxDecoration(color: p.accent, shape: BoxShape.circle)),
                          const SizedBox(width: 5),
                          Text('LIVE · NoN 正在工作', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: p.accent)),
                        ],
                      ),
                    ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                    decoration: BoxDecoration(
                      color: p.bgElevated.withValues(alpha: 0.9),
                      borderRadius: BorderRadius.circular(7),
                      border: Border.all(color: p.line),
                    ),
                    child: Text(
                      '${boards.length} 画板 · space 拖动 · ${modCombo('⌘')}滚轮缩放',
                      style: TextStyle(fontSize: 10, color: p.ink4),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
      ),
    );
  }

  Widget _boardWidget(AppStore store, Artboard board, Offset pos, bool active) {
    final p = context.palette;
    // image/avatar 节点异步预加载：只触发缓存，painter 不发网络请求。
    for (final n in board.nodes) {
      if (!n.style.visible) continue;
      if (n.component == 'image' || n.component == 'avatar') NodeImageCache.instance.ensure(n);
    }
    return Positioned(
      left: pos.dx,
      top: pos.dy,
      width: board.width,
      height: board.height,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: 0,
            top: -24,
            child: Row(
              children: [
                Text(
                  board.name.isEmpty ? board.id : board.name,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                    color: active ? p.accent : p.ink3,
                  ),
                ),
                const SizedBox(width: 6),
                Text('${board.width.round()}×${board.height.round()}',
                    style: TextStyle(fontSize: 10, fontFamily: 'monospace', color: p.ink4)),
              ],
            ),
          ),
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                _canvasFocus.requestFocus();
                store.selectBoard(board.id);
                store.selectNode(null);
              },
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(3),
                  boxShadow: active
                      ? [BoxShadow(color: p.accent.withValues(alpha: 0.55), spreadRadius: 2, blurRadius: 0)]
                      : [BoxShadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 26, offset: const Offset(0, 14))],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: Stack(
                    children: [
                      Positioned.fill(
                        // RepaintBoundary：每板独立图层——Agent 预览/拖拽只重绘
                        // 活动板，其余板栅格缓存复用。
                        child: RepaintBoundary(
                          child: CustomPaint(
                            painter: ArtboardPainter(
                            nodes: board.nodes,
                            accent: p.accent,
                            selectedId: active ? store.selectedNode : null,
                            selectedIds: active ? store.selectedNodes : const [],
                            hoverId: null,
                            dragId: _draggingId,
                            dragDelta: _dragDelta,
                            resizeId: _resizingId,
                            resizeRect: _resizeGhost,
                            // 图片加载完成经此 listenable 触发画布重绘
                                repaint: NodeImageCache.instance,
                              ),
                            ),
                          ),
                        ),
                      for (final node in board.nodes)
                        if (node.style.visible)
                          Positioned(
                            left: node.x,
                            top: node.y,
                            width: math.max(4, node.w),
                            height: math.max(4, node.h),
                            child: MouseRegion(
                              cursor: store.agentBusy ? SystemMouseCursors.basic : SystemMouseCursors.move,
                              child: GestureDetector(
                                behavior: HitTestBehavior.translucent,
                                onTap: () {
                                  _canvasFocus.requestFocus();
                                  store.selectBoard(board.id);
                                  if (HardwareKeyboard.instance.isShiftPressed) {
                                    store.toggleNodeSelection(node.id);
                                  } else {
                                    store.clearNodeMultiSelection();
                                    store.selectNode(node.id);
                                  }
                                },
                                onSecondaryTapUp: (details) =>
                                    _nodeContextMenu(context, store, board, node, details.globalPosition),
                                onDoubleTap: () => _editText(store, node),
                                onPanDown: (_) {
                                  if (store.agentBusy) return;
                                  _nodePressed = true;
                                },
                                onPanCancel: () {
                                  _nodePressed = false;
                                  setState(() {
                                    _draggingId = null;
                                    _dragDelta = Offset.zero;
                                  });
                                },
                                onPanStart: (_) {
                                  if (store.agentBusy) return;
                                  store.selectBoard(board.id);
                                  store.selectNode(node.id);
                                  setState(() {
                                    _draggingId = node.id;
                                    _dragDelta = Offset.zero;
                                  });
                                },
                                onPanUpdate: (details) {
                                  if (_draggingId != node.id) return;
                                  setState(() => _dragDelta += details.delta);
                                },
                                onPanEnd: (_) async {
                                  _nodePressed = false;
                                  final delta = _dragDelta;
                                  setState(() {
                                    _draggingId = null;
                                    _dragDelta = Offset.zero;
                                  });
                                  if (delta.distance <= 0.5) return;
                                  final moving = store.selectedNodes.contains(node.id) && store.selectedNodes.length >= 2
                                      ? store.selectedNodes
                                      : <String>[node.id];
                                  for (final id in moving) {
                                    CanvasNode target = node;
                                    for (final n2 in board.nodes) {
                                      if (n2.id == id) target = n2;
                                    }
                                    await store.moveNode(id, target.x + delta.dx, target.y + delta.dy);
                                  }
                                },
                              ),
                            ),
                          ),
                    ],
                  ),
                ),
              ),
            ),
          ),
            if (active && !store.agentBusy) ..._selectionHandles(store, board),
          ],
        ),
      );
  }

  /// 选中节点的 8 向缩放手柄命中区（4 角 + 4 边中点）。
  /// 视觉手柄由 ArtboardPainter 绘制；这里只挂手势——拖动期间
  /// setState 更新 ghost 矩形（painter 实时绘制），松手按需提交
  /// moveNode + resizeNode（store 既有方法，不改 store）。
  List<Widget> _selectionHandles(AppStore store, Artboard board) {
    final id = store.selectedNode;
    if (id == null) return const [];
    CanvasNode? hit;
    for (final n in board.nodes) {
      if (n.id == id) {
        hit = n;
        break;
      }
    }
    if (hit == null || !hit.style.visible) return const [];
    final node = hit;
    final rect = Rect.fromLTWH(node.x, node.y, node.w, node.h);
    const grip = 14.0;
    final targets = <(Offset, _ResizeHandle)>[
      (rect.topLeft, _ResizeHandle.topLeft),
      (rect.topCenter, _ResizeHandle.top),
      (rect.topRight, _ResizeHandle.topRight),
      (rect.centerRight, _ResizeHandle.right),
      (rect.bottomRight, _ResizeHandle.bottomRight),
      (rect.bottomCenter, _ResizeHandle.bottom),
      (rect.bottomLeft, _ResizeHandle.bottomLeft),
      (rect.centerLeft, _ResizeHandle.left),
    ];
    return [
      for (final (point, handle) in targets)
        Positioned(
          left: point.dx - grip / 2,
          top: point.dy - grip / 2,
          width: grip,
          height: grip,
          child: MouseRegion(
            cursor: _resizeCursor(handle),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanDown: (_) {
                if (store.agentBusy) return;
                _handlePressed = true;
              },
              onPanCancel: () {
                _handlePressed = false;
                setState(() {
                  _resizingId = null;
                  _resizeHandle = null;
                  _resizeDelta = Offset.zero;
                });
              },
              onPanStart: (_) {
                if (store.agentBusy) return;
                _canvasFocus.requestFocus();
                setState(() {
                  _resizingId = node.id;
                  _resizeHandle = handle;
                  _resizeStart = rect;
                  _resizeDelta = Offset.zero;
                });
              },
              onPanUpdate: (details) {
                if (_resizingId != node.id) return;
                setState(() => _resizeDelta += details.delta);
              },
              onPanEnd: (_) async {
                _handlePressed = false;
                final startRect = _resizeStart;
                final which = _resizeHandle ?? _ResizeHandle.bottomRight;
                final ghost = _applyHandle(startRect, _resizeDelta, which);
                final target = node.id;
                setState(() {
                  _resizingId = null;
                  _resizeHandle = null;
                  _resizeDelta = Offset.zero;
                });
                final moved = (ghost.left - node.x).abs() > 0.5 || (ghost.top - node.y).abs() > 0.5;
                final resized = (ghost.width - node.w).abs() > 0.5 || (ghost.height - node.h).abs() > 0.5;
                if (!resized && !moved) return;
                // Size first, then position — and if the move is rejected, revert
                // the size so the node never lands in a half-applied state.
                final okSize = resized ? await store.resizeNode(target, ghost.width, ghost.height) : true;
                if (!okSize) return;
                if (moved) {
                  final okMove = await store.moveNode(target, ghost.left, ghost.top);
                  if (okMove == false && resized) {
                    await store.resizeNode(target, node.w, node.h);
                  }
                }
              },
            ),
          ),
        ),
    ];
  }

  /// 右键上下文菜单：复制 / 删除 / 置顶置底 / 多选编组 / 解组。
  Future<void> _nodeContextMenu(
    BuildContext context,
    AppStore store,
    Artboard board,
    CanvasNode node,
    Offset globalPosition,
  ) async {
    if (store.agentBusy) return;
    final multi = store.selectedNodes.length >= 2 && store.selectedNodes.contains(node.id);
    final parent = node.parent;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
          globalPosition.dx, globalPosition.dy, globalPosition.dx + 1, globalPosition.dy + 1),
      items: [
        const PopupMenuItem(value: 'dup', height: 36, child: Text('复制节点', style: TextStyle(fontSize: 12))),
        const PopupMenuItem(value: 'delete', height: 36, child: Text('删除节点', style: TextStyle(fontSize: 12))),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'front', height: 36, child: Text('置顶', style: TextStyle(fontSize: 12))),
        const PopupMenuItem(value: 'back', height: 36, child: Text('置底', style: TextStyle(fontSize: 12))),
        if (multi)
          const PopupMenuItem(value: 'group', height: 36, child: Text('编组选中节点', style: TextStyle(fontSize: 12))),
        if (parent != 'root')
          PopupMenuItem(
              value: 'ungroup',
              height: 36,
              child: Text('解组 $parent', style: TextStyle(fontSize: 12))),
      ],
    );
    if (action == null || !mounted) return;
    switch (action) {
      case 'dup':
        await store.duplicateNode(node.id);
      case 'delete':
        await store.deleteNode(node.id);
        store.clearNodeMultiSelection();
      case 'front':
        await store.reorderNode(node.id, 'front');
      case 'back':
        await store.reorderNode(node.id, 'back');
      case 'group':
        await store.groupNodes(
            'grp_${DateTime.now().millisecondsSinceEpoch % 100000}', store.selectedNodes);
      case 'ungroup':
        await store.ungroupNodes(parent);
    }
  }
}

class ArtboardPainter extends CustomPainter {
  final List<CanvasNode> nodes;
  /// 品牌强调色（palette.accent）——painter 无 BuildContext，由调用方传入。
  final Color accent;
  final String? selectedId;
  final List<String> selectedIds;
  final String? hoverId;
  final String? dragId;
  final Offset dragDelta;
  final String? resizeId;
  final Rect? resizeRect; // 缩放手势的 ghost 矩形（board 坐标，实时更新）

  ArtboardPainter({
    required this.nodes,
    required this.accent,
    this.selectedId,
    this.selectedIds = const [],
    this.hoverId,
    this.dragId,
    this.dragDelta = Offset.zero,
    this.resizeId,
    this.resizeRect,
    super.repaint, // NodeImageCache：图片异步加载完成后重绘画布
  });

  @override
  void paint(Canvas canvas, Size size) {
    for (final node in nodes) {
      if (!node.style.visible) continue;
      final isDragging = dragId == node.id;
      final isResizing = resizeId == node.id && resizeRect != null;
      final rect = isResizing
          ? resizeRect!
          : Rect.fromLTWH(
              node.x + (isDragging ? dragDelta.dx : 0.0),
              node.y + (isDragging ? dragDelta.dy : 0.0),
              node.w,
              node.h,
            );
      final radius = math.min(node.style.radius, rect.shortestSide / 2);
      final rrect = RRect.fromRectAndRadius(rect, Radius.circular(radius));
      final alpha = node.style.opacity.clamp(0.0, 1.0);

      if (node.style.shadow != 'none' && alpha > 0.05) {
        final shadow = Paint()
          ..color = Colors.black.withValues(alpha: 0.10 * alpha)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
        canvas.drawRRect(rrect.shift(const Offset(0, 4)), shadow);
      }

      final fill = parseHex(node.style.fill);
      if (fill != Colors.transparent && alpha > 0) {
        canvas.drawRRect(rrect, Paint()..color = fill.withValues(alpha: fill.a * alpha));
      }

      final stroke = parseHex(node.style.stroke);
      if (node.style.stroke != 'none' && stroke != Colors.transparent && node.style.strokeWidth > 0) {
        canvas.drawRRect(
          rrect,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = node.style.strokeWidth
            ..color = stroke.withValues(alpha: stroke.a * alpha),
        );
      }

      final imageUrl = _nodeImageUrl(node);
      if (imageUrl != null) {
        // 已解码画真图（cover 裁切）；加载中/失败保留占位符。
        final image = NodeImageCache.instance.imageOf(node.id);
        if (image != null) {
          _paintImageCover(canvas, rect, image, alpha, radius);
        } else {
          _paintImagePlaceholder(canvas, rect, alpha);
        }
      } else if (node.text.trim().isNotEmpty && alpha > 0.05) {
        _paintText(canvas, node, rect, alpha);
      } else if (node.component == 'image' || node.component == 'avatar') {
        _paintImagePlaceholder(canvas, rect, alpha);
      }

      if (node.id == selectedId) {
        canvas.drawRRect(
          rrect.inflate(1),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = accent,
        );
        final handle = Paint()..color = accent;
        // 8 个手柄点与 _selectionHandles 的命中区一一对应。
        for (final point in [
          rect.topLeft,
          rect.topCenter,
          rect.topRight,
          rect.centerRight,
          rect.bottomRight,
          rect.bottomCenter,
          rect.bottomLeft,
          rect.centerLeft,
        ]) {
          canvas.drawRect(Rect.fromCenter(center: point, width: 6, height: 6), handle);
        }
      } else if (selectedIds.contains(node.id)) {
        canvas.drawRRect(
          rrect.inflate(1),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = accent.withValues(alpha: 0.60),
        );
      } else if (node.id == hoverId) {
        canvas.drawRRect(
          rrect.inflate(0.5),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = accent.withValues(alpha: 0.53),
        );
      }
    }
  }

  /// cover 裁切绘制：源矩形取与目标矩形同宽高比的最大居中区域，
  /// 圆角经 clipRRect 落在节点自身样式上。
  void _paintImageCover(Canvas canvas, Rect rect, ui.Image image, double alpha, double radius) {
    if (rect.width < 1 || rect.height < 1 || image.width <= 0 || image.height <= 0) return;
    final srcW = image.width.toDouble();
    final srcH = image.height.toDouble();
    final dstAspect = rect.width / rect.height;
    final srcAspect = srcW / srcH;
    final Rect src;
    if (srcAspect > dstAspect) {
      final w = srcH * dstAspect;
      src = Rect.fromLTWH((srcW - w) / 2, 0, w, srcH);
    } else {
      final h = srcW / dstAspect;
      src = Rect.fromLTWH(0, (srcH - h) / 2, srcW, h);
    }
    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(rect, Radius.circular(radius)));
    canvas.drawImageRect(
      image,
      src,
      rect,
      Paint()
        ..filterQuality = FilterQuality.medium
        ..color = Colors.white.withValues(alpha: alpha),
    );
    canvas.restore();
  }

  void _paintText(Canvas canvas, CanvasNode node, Rect rect, double alpha) {
    final color = parseHex(node.style.textColor, fallback: const Color(0xFF111827));
    final weight = switch (node.style.weight) {
      'medium' => FontWeight.w500,
      'semibold' => FontWeight.w600,
      'bold' => FontWeight.w700,
      _ => FontWeight.w400,
    };
    final align = switch (node.style.align) {
      'center' => TextAlign.center,
      'right' => TextAlign.right,
      _ => TextAlign.left,
    };
    final painter = TextPainter(
      text: TextSpan(
        text: node.text,
        style: TextStyle(
          fontSize: node.style.fontSize,
          fontWeight: weight,
          color: color.withValues(alpha: color.a * alpha),
          height: 1.28,
        ),
      ),
      textAlign: align,
      textDirection: TextDirection.ltr,
      maxLines: 6,
      ellipsis: '…',
    )..layout(maxWidth: math.max(4, rect.width - 8));
    final x = rect.left + 4;
    final y = rect.top + math.max(2, (rect.height - painter.height) / 2);
    painter.paint(canvas, Offset(x, y));
  }

  void _paintImagePlaceholder(Canvas canvas, Rect rect, double alpha) {
    final color = const Color(0xFFD7DAE2).withValues(alpha: 0.9 * alpha);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    final iconRect = Rect.fromCenter(
      center: rect.center,
      width: math.min(rect.width * 0.32, 28),
      height: math.min(rect.height * 0.32, 28),
    );
    canvas.drawCircle(iconRect.center.translate(-iconRect.width * 0.18, -iconRect.height * 0.18), iconRect.width * 0.12, paint);
    final path = Path()
      ..moveTo(iconRect.left, iconRect.bottom)
      ..lineTo(iconRect.left + iconRect.width * 0.38, iconRect.top + iconRect.height * 0.45)
      ..lineTo(iconRect.left + iconRect.width * 0.62, iconRect.bottom - iconRect.height * 0.2)
      ..lineTo(iconRect.left + iconRect.width * 0.8, iconRect.top + iconRect.height * 0.55)
      ..lineTo(iconRect.right, iconRect.bottom);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant ArtboardPainter old) =>
      old.nodes != nodes ||
      old.selectedId != selectedId ||
      !identical(old.selectedIds, selectedIds) ||
      old.hoverId != hoverId ||
      old.dragId != dragId ||
      old.dragDelta != dragDelta ||
      old.resizeId != resizeId ||
      old.resizeRect != resizeRect;
}

class FlowPainter extends CustomPainter {
  final List<Artboard> boards;
  final Map<String, Rect> positions;
  final List<Flow> flows;
  final double zoom;

  FlowPainter({required this.boards, required this.positions, required this.flows, required this.zoom, required this.accent});
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    if (flows.isEmpty) return;
    final stroke = Paint()
      ..color = accent.withValues(alpha: 0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5 / math.max(0.2, zoom)
      ..strokeCap = StrokeCap.round;
    for (final flow in flows) {
      final from = positions[flow.from];
      final to = positions[flow.to];
      if (from == null || to == null) continue;
      final fc = from.center;
      final tc = to.center;
      Offset start;
      Offset end;
      Offset c1;
      Offset c2;
      if ((tc.dx - fc.dx).abs() >= (tc.dy - fc.dy).abs()) {
        final right = tc.dx > fc.dx;
        start = Offset(right ? from.right : from.left, fc.dy);
        end = Offset(right ? to.left : to.right, tc.dy);
        c1 = Offset(start.dx + (right ? 60 : -60), start.dy);
        c2 = Offset(end.dx + (right ? -60 : 60), end.dy);
      } else {
        final down = tc.dy > fc.dy;
        start = Offset(fc.dx, down ? from.bottom : from.top);
        end = Offset(tc.dx, down ? to.top : to.bottom);
        c1 = Offset(start.dx, start.dy + (down ? 60 : -60));
        c2 = Offset(end.dx, end.dy + (down ? -60 : 60));
      }
      final path = Path()
        ..moveTo(start.dx, start.dy)
        ..cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, end.dx, end.dy);
      canvas.drawPath(path, stroke);
      final dir = (end - c2);
      final angle = math.atan2(dir.dy, dir.dx);
      final arrow = Path();
      final len = 9 / math.max(0.3, zoom);
      arrow
        ..moveTo(end.dx, end.dy)
        ..lineTo(end.dx - len * math.cos(angle - 0.45), end.dy - len * math.sin(angle - 0.45))
        ..lineTo(end.dx - len * math.cos(angle + 0.45), end.dy - len * math.sin(angle + 0.45))
        ..close();
      canvas.drawPath(arrow, Paint()..color = accent.withValues(alpha: 0.8));
    }
  }

  @override
  bool shouldRepaint(covariant FlowPainter old) =>
      // positions 是字段级对比：layoutBoards 每次 build 新建 Map，恒等比较
      // 恒不等 → 流线整层跟着画布每次 rebuild 重绘，抵消 RepaintBoundary 隔离。
      // flows/zoom 保持引用比较（render 信封未变时为同实例）。
      old.flows != flows || !mapEquals(old.positions, positions) || old.zoom != zoom;
}

class _EmptyCanvas extends StatelessWidget {
  final AppStore store;
  const _EmptyCanvas({required this.store});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Center(
      child: Container(
        width: 520,
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
          color: p.panel.withValues(alpha: 0.94),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: p.lineStrong),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 50, offset: const Offset(0, 20))],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(11),
                    gradient: LinearGradient(colors: [p.accent, p.accent2]),
                  ),
                  child: const Icon(Icons.auto_awesome, size: 17, color: Colors.white),
                ),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('从一句话开始', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: p.ink)),
                    Text('NoN 先写产品文档与设计规范，再把原型画到画布上。',
                        style: TextStyle(fontSize: 11, color: p.ink3)),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text('在右侧 NoN 面板描述你的产品；或先用文档页生成 PRD。',
                style: TextStyle(fontSize: 12, height: 1.6, color: p.ink3)),
            const SizedBox(height: 10),
            Row(
              children: [
                FilledButton(
                  onPressed: () => store.setRightTab('agent'),
                  child: const Text('打开 NoN'),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: () => store.setView('docs'),
                  child: const Text('先写文档'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CanvasHud extends StatelessWidget {
  final TransformationController controller;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onFit;
  final String flows;

  const _CanvasHud({
    required this.controller,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onFit,
    required this.flows,
  });

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final zoom = controller.value.getMaxScaleOnAxis();
        return Container(
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: p.panel.withValues(alpha: 0.94),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: p.line),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.25), blurRadius: 18, offset: const Offset(0, 6))],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconAction(icon: Icons.remove, tooltip: '缩小', size: 26, onTap: onZoomOut),
              SizedBox(
                width: 48,
                child: Text('${(zoom * 100).round()}%',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 11, fontFamily: 'monospace', color: p.ink2)),
              ),
              IconAction(icon: Icons.add, tooltip: '放大', size: 26, onTap: onZoomIn),
              Container(width: 1, height: 16, color: p.line),
              IconAction(icon: Icons.open_in_full, tooltip: '适配窗口 ${modCombo('⌘0')}', size: 26, onTap: onFit),
            ],
          ),
        );
      },
    );
  }
}
