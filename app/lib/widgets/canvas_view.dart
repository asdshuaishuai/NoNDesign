import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter_svg/flutter_svg.dart';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show ValueListenable, mapEquals, debugPrint;
import 'package:flutter/material.dart' hide Flow;
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
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
  // gap 150：流程线要在板间展示「节点→节点」全路径 + 目标标签，96 太挤
  // （用户反馈：连线太短太小，跳转关系看不清）。
  const gap = 150.0;
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
    // ResizeImage 解码上限：原图可能是 4000px 照片，节点展示只需数百 px——
    // 全分辨率解码一次就是几十 MB 位图。宽度钳到 1024，高度按比例。
    final stream = ResizeImage(NetworkImage(url), width: 1024, allowUpscaling: false)
        .resolve(ImageConfiguration.empty);
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

/// 引擎 svg → flutter_svg 兼容预处理（2026-11-16 缺陷修复）。
/// flutter_svg 2.4.0 / vector_graphics_compiler 1.3.6 渲染链两处静默降级
/// （pub-cache parser.dart 亲读实证）：
/// ① 滤镜白名单仅 feGaussianBlur/feOffset/feMerge（parser.dart:190），
///    其余基元令整个 filter 被丢弃（:253 hasUnsupportedPrimitive → return）
///    ——引擎 defs 三档 feDropShadow（e1/e2/e3，参数与 ArtboardPainter
///    海拔档位逐一对齐）全部不可见。按 SVG 规范等价式改写：
///    blur(SourceAlpha) → offset → merge(offset, SourceGraphic)；编译器
///    把 SourceAlpha 图层颜色置黑（resolver.dart:495 Color.fromARGB(a,0,0,0)），
///    恰为 feDropShadow 默认 flood-color 黑。flood-opacity 在三基元白名单内
///    无法表达，改写链不携带（阴影比引擎意图略重，可见性优先）。
/// ② <image> 仅接受 data: href（parser.dart:610），http(s) href 直接
///    return 丢弃（:649-652）——网络图整节点消失。这里把 http(s) href 按
///    NodeImageCache 同款管线语义（URL 幂等、失败不重试）预取原始字节，
///    改写为 data: URI（mime 按 Content-Type/扩展名收紧到 png/jpeg/webp/
///    gif/bmp；≤8MB——更大的原始位图转 data URI 只会拖垮 svg 字符串）。
///    未取到（离线/404/超时/超大）保留原 href：该 image 节点被 flutter_svg
///    丢弃，画布覆盖层占位与旧行为一致（fail-visible 不劣化）。
/// 结果按 svg 全文缓存（LRU 12 条）：feDropShadow 改写同步完成即时上屏，
/// 图片改写异步完成后 notifyListeners 触发重渲染；同一 svg 重复构建零开销。
class EngineSvgPrep extends ChangeNotifier {
  EngineSvgPrep._();
  static final EngineSvgPrep instance = EngineSvgPrep._();

  static const _maxEntries = 12;
  static const _maxImageBytes = 8 * 1024 * 1024;
  static final Duration _fetchTimeout = Duration(seconds: 15);

  static final _shadowRe = RegExp(r'<feDropShadow\b[^>]*/>');
  static final _imageTagRe = RegExp(r'<image\b[^>]*>');
  // 注意：正则含单引号（href 引号捕获组），单引号 raw string 里无法承载
  // ——用普通字符串写（\\s→\s、\\2→\2、\'→'）。
  static final _hrefRe =
      RegExp('((?:xlink:)?href\\s*=\\s*)(["\'])([^"\']+)\\2');

  final Map<String, String> _cache = {};
  final Set<String> _inflight = {};
  final Set<String> _failedUrls = {}; // 失败不重试（NodeImageCache 同语义）

  /// 同步入口：命中缓存返回成品；未命中先做同步部分（feDropShadow 改写）
  /// 立即返回，同时启动异步部分（网络图 data: 改写），完成后通知重建。
  String prepared(String svg) {
    if (!svg.contains('<feDropShadow') && !svg.contains('<image')) return svg;
    final hit = _cache[svg];
    if (hit != null) {
      _cache.remove(svg);
      _cache[svg] = hit; // LRU 触碰
      return hit;
    }
    final provisional = rewriteShadows(svg);
    _cache[svg] = provisional;
    _trim();
    if (_inflight.add(svg)) {
      _prepareImages(svg, provisional).whenComplete(() {
        _inflight.remove(svg);
        notifyListeners();
      });
    }
    return provisional;
  }

  /// 同步改写全部 feDropShadow（纯字符串，无 IO）。
  String rewriteShadows(String svg) {
    if (!svg.contains('<feDropShadow')) return svg;
    var i = 0;
    return svg.replaceAllMapped(_shadowRe, (m) {
      final tag = m[0]!;
      String? num(String name) {
        final raw = _attr(tag, name)?.trim();
        if (raw == null || raw.isEmpty) return null;
        final v = double.tryParse(raw.split(RegExp(r'[\s,]+')).first);
        return v == null ? null : v.toString();
      }

      final std = num('stdDeviation') ?? '0';
      final dx = num('dx') ?? '0';
      final dy = num('dy') ?? '0';
      final r = i++;
      return '<feGaussianBlur in="SourceAlpha" stdDeviation="$std" result="nsgb$r"/>'
          '<feOffset in="nsgb$r" dx="$dx" dy="$dy" result="nsof$r"/>'
          '<feMerge result="nsmg$r">'
          '<feMergeNode in="nsof$r"/><feMergeNode in="SourceGraphic"/>'
          '</feMerge>';
    });
  }

  Future<void> _prepareImages(String key, String provisional) async {
    var out = provisional;
    try {
      final urls = <String>{};
      for (final m in _imageTagRe.allMatches(provisional)) {
        final href = _hrefOf(m[0]!);
        if (href != null &&
            (href.startsWith('http://') || href.startsWith('https://'))) {
          urls.add(href);
        }
      }
      if (urls.isNotEmpty) {
        final resolved = <String, String>{};
        for (final url in urls) {
          if (_failedUrls.contains(url)) continue;
          final dataUri = await _fetchAsDataUri(url);
          if (dataUri != null) {
            resolved[url] = dataUri;
          } else {
            _failedUrls.add(url); // 与 NodeImageCache 一致：失败不自动重试
            debugPrint('[EngineSvgPrep] image prefetch failed: $url');
          }
        }
        if (resolved.isNotEmpty) {
          final tagRewrites = <String, String>{};
          for (final m in _imageTagRe.allMatches(provisional)) {
            final tag = m[0]!;
            if (tagRewrites.containsKey(tag)) continue;
            final href = _hrefOf(tag);
            final data = href == null ? null : resolved[href];
            if (data != null) {
              tagRewrites[tag] = tag.replaceFirstMapped(
                _hrefRe,
                (hm) => '${hm.group(1)}${hm.group(2)}$data${hm.group(2)}',
              );
            }
          }
          if (tagRewrites.isNotEmpty) {
            out = provisional.replaceAllMapped(
              _imageTagRe,
              (m) => tagRewrites[m[0]!] ?? m[0]!,
            );
          }
        }
      }
    } catch (_) {
      // 预处理失败不抛：provisional（阴影已改写）仍可上屏。
    }
    _cache[key] = out;
  }

  Future<String?> _fetchAsDataUri(String url) async {
    try {
      final res = await http.get(Uri.parse(url)).timeout(_fetchTimeout);
      if (res.statusCode != 200) return null;
      final bytes = res.bodyBytes;
      if (bytes.isEmpty || bytes.length > _maxImageBytes) return null;
      final mime = _mimeOf(res.headers['content-type'], url);
      if (mime == null) return null;
      return 'data:$mime;base64,${base64Encode(bytes)}';
    } catch (_) {
      return null;
    }
  }

  String? _mimeOf(String? contentType, String url) {
    const allowed = {'image/png', 'image/jpeg', 'image/webp', 'image/gif', 'image/bmp'};
    final ct = contentType?.split(';').first.trim().toLowerCase() ?? '';
    if (allowed.contains(ct)) return ct;
    // Content-Type 缺失/宽泛时按扩展名兜底。
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    const exts = {
      'png': 'image/png',
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'webp': 'image/webp',
      'gif': 'image/gif',
      'bmp': 'image/bmp',
    };
    for (final e in exts.entries) {
      if (path.endsWith('.${e.key}')) return e.value;
    }
    return null;
  }

  String? _hrefOf(String tag) => _hrefRe.firstMatch(tag)?.group(3);

  String? _attr(String tag, String name) =>
      RegExp('$name\\s*=\\s*["\']([^"\']*)["\']', caseSensitive: false)
          .firstMatch(tag)
          ?.group(1);

  void _trim() {
    while (_cache.length > _maxEntries) {
      _cache.remove(_cache.keys.first);
    }
  }
}

enum _ResizeHandle { topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left }

/// 手柄 delta 应用到起始矩形（8 向钳制最小边 8）。painter 与手势收尾共用。
Rect _applyResizeHandle(Rect start, Offset delta, _ResizeHandle handle) {
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
  // 手势 delta 走 ValueNotifier 直驱活动板 painter 重绘（repaint listenable），
  // 不再逐指针帧 setState 重建全部画板的覆盖层——变的只有 ghost 参数。
  final ValueNotifier<Offset> _dragDelta = ValueNotifier(Offset.zero);
  bool _nodePressed = false;
  // 8 向缩放手势状态：拖手柄期间 painter 用 ghost 矩形实时绘制。
  String? _resizingId;
  _ResizeHandle? _resizeHandle;
  Rect _resizeStart = Rect.zero;
  final ValueNotifier<Offset> _resizeDelta = ValueNotifier(Offset.zero);
  bool _handlePressed = false;
  // 悬停板：只有悬停板（及选中板/起始板）的跳转线保持高亮，其余连线淡出，
  // 避免一次全画时线互相穿插。指针经 Listener 探测，换板才 setState。
  String? _hoveredBoard;
  // 活动板手势期 painter 的 repaint：图片缓存 + 两个手势 delta 合并监听。
  late final Listenable _gestureRepaint =
      Listenable.merge([NodeImageCache.instance, _dragDelta, _resizeDelta]);
  // 方向键微调串行链：连续按键逐个排队，每次从最新已提交位置计算。
  // 陈旧 mbt 丢改动的根治在 store 级 applyOp 串行队列（store.dart
  // _opQueue——跨入口互斥，缩放松手两连发/inspector 编辑同样被串行化）；
  // 这条链只做同键自动重复的合帧排队，op 提交本身全部经 store 队列。
  Future<void> _nudgeChain = Future<void>.value();
  String _lastLayoutKey = '';
  int _lastFitEpoch = -1;

  @override
  void dispose() {
    _controller.dispose();
    _canvasFocus.dispose();
    _dragDelta.dispose();
    _resizeDelta.dispose();
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

  /// 悬停板探测：挂在画布最外层的 Listener 收指针事件（悬停事件沿命中链
  /// 上浮，板内节点/手势都拦不住；HUD/角标也算画布内，滑上去会清空悬停），
  /// 局部坐标就是视口坐标，经 toScene 换算回场景坐标后按板位 rect 判定。
  /// 只有换板才 setState。
  void _onCanvasHover(Offset viewportPosition) {
    if (!mounted) return;
    final layout = _layoutCache;
    final boards = _layoutSrc;
    if (layout == null || boards == null) return;
    final scene = _controller.toScene(viewportPosition);
    String? hit;
    for (final b in boards) {
      final r = layout.positions[b.id];
      if (r != null && r.shift(_canvasPad).contains(scene)) {
        hit = b.id;
        break;
      }
    }
    _setHoveredBoard(hit);
  }

  void _setHoveredBoard(String? id) {
    if (!mounted || _hoveredBoard == id) return;
    setState(() => _hoveredBoard = id);
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

  List<Artboard>? _layoutSrc;
  BoardLayout? _layoutCache;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final p = context.palette;
    final source = store.agentBusy && store.previewRender != null ? store.previewRender! : store.render;
    final boards = source.artboards;
    // 布局记忆化：boards 列表随 envelope 整体替换，引用不变即布局不变——
    // Agent 运行期间每帧 build 免去重复的网格计算。
    if (!identical(_layoutSrc, boards) || _layoutCache == null) {
      _layoutCache = layoutBoards(boards);
      _layoutSrc = boards;
    }
    final layout = _layoutCache!;
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
        return MouseRegion(
          // 指针离开画布（移出到侧栏/标题栏）时清除悬停高亮。
          onExit: (_) => _setHoveredBoard(null),
          child: Listener(
            // 悬停探测放在最外层：指针在画布内但不在板上（包括滑到 HUD/角标）
            // 也会清掉悬停板，不会再残留高亮；局部坐标仍是视口坐标。
            onPointerHover: (event) => _onCanvasHover(event.localPosition),
            child: Stack(
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
                    child: ExcludeSemantics(
                      // 画布是自绘 CustomPaint + 热区覆盖——语义树对它只有成本没有
                      // 价值（OS AX 层激活时 SEMANTICS 每帧走查全树）。
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
                                  controller: _controller,
                                  accent: p.accent,
                                  ink: p.ink,
                                  panel: p.panel,
                                  line: p.line,
                                  // 焦点板：选中板 / 悬停板 / 原型起始板。只有与它们
                                  // 相关的连线高亮，其余淡到背景层（全线同权 =
                                  // 互相穿插、标签压板，看不出跳转关系）。
                                  activeBoard: activeBoard,
                                  hoveredBoard: _hoveredBoard,
                                  entryBoard: source.entry,
                                  // 板位 rect 与板 widget 共用同一内边距（见 _canvasPad）。
                                  canvasPadding: _canvasPad,
                                ),
                              ),
                            ),
                          ),
                          for (final b in boards)
                            // 板位与 FlowPainter 共用 _canvasPad（连线坐标系对齐）。
                            _boardWidget(store, b, layout.positions[b.id]!.topLeft + _canvasPad, activeBoard == b.id),
                          ],
                        ),
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
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: p.accent.withValues(alpha: 0.3)),
                          ),
                          child: Row(
                            children: [
                              Container(width: 5, height: 5, decoration: BoxDecoration(color: p.accent, shape: BoxShape.circle)),
                              const SizedBox(width: 5),
                              Text('LIVE · NaN 正在工作', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: p.accent)),
                            ],
                          ),
                        ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                        decoration: BoxDecoration(
                          color: p.bgElevated.withValues(alpha: 0.9),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: p.line),
                        ),
                        child: Text(
                          MediaQuery.sizeOf(context).width < 700
                              ? '${boards.length} 画板'
                              : '${boards.length} 画板 · space 拖动 · ${modCombo('⌘')}滚轮缩放',
                          style: TextStyle(fontSize: 10, color: p.ink4),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
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
    // 手势只发生在持有被拖/被缩放节点的板上；其余板不吃手势帧重绘。
    final paintingGesture = (_draggingId != null && board.nodes.any((n) => n.id == _draggingId)) ||
        (_resizingId != null && board.nodes.any((n) => n.id == _resizingId));
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
                  // 板底色跟随引擎主题（server 从 svg 背景 rect 提取；dark #0F1114 等），
                  // 无值才回落白底。
                  color: board.background.isEmpty ? Colors.white : parseHex(board.background),
                  borderRadius: BorderRadius.circular(4),
                  boxShadow: active
                      ? [BoxShadow(color: p.accent.withValues(alpha: 0.55), spreadRadius: 2, blurRadius: 0)]
                      : [BoxShadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 26, offset: const Offset(0, 14))],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Stack(
                    children: [
                      // 内容层 = 引擎自渲染 SVG（唯一真源；阴影/字体/rotate/
                      // <image> 全由引擎携带，客户端不重复实现渲染）。
                      // 上屏前经 EngineSvgPrep 兼容预处理（feDropShadow→
                      // 白名单基元链、网络 <image>→data:），flutter_svg 才
                      // 不静默丢阴影/图片。
                      if (board.svg.isNotEmpty)
                        Positioned.fill(
                          child: ListenableBuilder(
                            listenable: EngineSvgPrep.instance,
                            builder: (_, __) => SvgPicture.string(
                              EngineSvgPrep.instance.prepared(board.svg),
                              fit: BoxFit.fill,
                            ),
                          ),
                        ),
                      Positioned.fill(
                        // 覆盖层：选区环/拖拽幽灵/缩放手柄（svg 在场时只画
                        // 覆盖，svg 缺席的旧信封回落整节点绘制）。
                        child: RepaintBoundary(
                          child: CustomPaint(
                            painter: ArtboardPainter(
                            nodes: board.nodes,
                            accent: p.accent,
                            overlayOnly: board.svg.isNotEmpty,
                            selectedId: active ? store.selectedNode : null,
                            selectedIds: active ? store.selectedNodes : const [],
                            hoverId: null,
                            dragId: _draggingId,
                            dragDelta: paintingGesture ? _dragDelta : null,
                            resizeId: _resizingId,
                            resizeStart: paintingGesture ? _resizeStart : null,
                            resizeHandle: paintingGesture ? _resizeHandle : null,
                            resizeDelta: paintingGesture ? _resizeDelta : null,
                            // 手势期合入两个 delta notifier（逐帧直驱重绘）；
                            // 平时仍只挂图片缓存。其余板不吃手势帧重绘。
                                repaint: paintingGesture ? _gestureRepaint : NodeImageCache.instance,
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
                                  _dragDelta.value = Offset.zero;
                                  setState(() => _draggingId = null);
                                },
                                onPanStart: (_) {
                                  if (store.agentBusy) return;
                                  store.selectBoard(board.id);
                                  store.selectNode(node.id);
                                  setState(() {
                                    _draggingId = node.id;
                                    _dragDelta.value = Offset.zero;
                                  });
                                },
                                onPanUpdate: (details) {
                                  if (_draggingId != node.id) return;
                                  // 仅手势帧重绘活动板 painter，不走全树 setState。
                                  _dragDelta.value += details.delta;
                                },
                                onPanEnd: (_) async {
                                  _nodePressed = false;
                                  final delta = _dragDelta.value;
                                  _dragDelta.value = Offset.zero;
                                  setState(() => _draggingId = null);
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
                _resizeDelta.value = Offset.zero;
                setState(() {
                  _resizingId = null;
                  _resizeHandle = null;
                });
              },
              onPanStart: (_) {
                if (store.agentBusy) return;
                _canvasFocus.requestFocus();
                setState(() {
                  _resizingId = node.id;
                  _resizeHandle = handle;
                  _resizeStart = rect;
                  _resizeDelta.value = Offset.zero;
                });
              },
              onPanUpdate: (details) {
                if (_resizingId != node.id) return;
                // 仅手势帧重绘活动板 painter，不走全树 setState。
                _resizeDelta.value += details.delta;
              },
              onPanEnd: (_) async {
                _handlePressed = false;
                final startRect = _resizeStart;
                final which = _resizeHandle ?? _ResizeHandle.bottomRight;
                final ghost = _applyResizeHandle(startRect, _resizeDelta.value, which);
                final target = node.id;
                _resizeDelta.value = Offset.zero;
                setState(() {
                  _resizingId = null;
                  _resizeHandle = null;
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
  /// 文本整形缓存：拖拽/缩放/Agent 预览每帧对同一文本+样式重复做
  /// SkParagraph 整形是 painter 内最重的分配。键 = 文本+字号+字重+对齐+
  /// 行宽(整型量化)+alpha(1/16 量化)+line/tracking/italic；文本/样式变更
  /// 自然换键，容量兜底整表清。
  static final Map<String, TextPainter> _textCache = {};

  /// style 色 hex 解析备忘：paint 每节点每帧 parseHex 同一字符串是纯重复
  /// 工作。painter 实例随 build 重建，实例字段无法跨帧——用静态表。
  static final Map<String, Color> _hexMemo = {};

  static Color _hex(String raw, {Color fallback = const Color(0xFF888888)}) =>
      _hexMemo[raw] ??= parseHex(raw, fallback: fallback);

  /// `linear-gradient(<deg>,#A,#B[,...])` 解析备忘（deg → 主方向单位向量，
  /// CSS 语义：0deg 朝上、顺时针增——135deg ≈ 左上→右下）。失败 = null，
  /// 调用方回落 _hex 灰色路径。
  static final Map<String, (List<Color>, Offset)?> _gradientMemo = {};
  static final RegExp _gradientRe = RegExp(
      r'linear-gradient\(\s*([+-]?\d+(?:\.\d+)?)deg\s*((?:\s*,\s*#[0-9A-Fa-f]{3,8})+)\s*\)');
  static final RegExp _hexListRe = RegExp(r'#[0-9A-Fa-f]{3,8}');

  static (List<Color>, Offset)? _gradientSpec(String raw) {
    if (_gradientMemo.containsKey(raw)) return _gradientMemo[raw];
    (List<Color>, Offset)? spec;
    final m = _gradientRe.firstMatch(raw.trim());
    if (m != null) {
      final colors = _hexListRe
          .allMatches(m.group(2)!)
          .map((c) => parseHex(c.group(0)!))
          .toList(growable: false);
      if (colors.length >= 2) {
        final deg = double.tryParse(m.group(1)!) ?? 135.0;
        final rad = deg * math.pi / 180.0;
        final dir = Offset(math.sin(rad), -math.cos(rad));
        spec = (colors, dir);
      }
    }
    _gradientMemo[raw] = spec;
    return spec;
  }

  final List<CanvasNode> nodes;
  /// 品牌强调色（palette.accent）——painter 无 BuildContext，由调用方传入。
  final Color accent;
  final String? selectedId;
  final List<String> selectedIds;
  final String? hoverId;
  final String? dragId;
  /// 拖拽/缩放 delta 以 ValueListenable 注入：paint 时现读、经 repaint
  /// listenable 逐帧驱动，painter 实例随 build 重建也不丢当前 delta。
  final ValueListenable<Offset>? dragDelta;
  final String? resizeId;
  final Rect? resizeStart; // 缩放手势的起始矩形（board 坐标）
  final _ResizeHandle? resizeHandle;
  final ValueListenable<Offset>? resizeDelta;
  /// 演示模式入场进度（0→1；仅演示传入，编辑画布 null = 静态设计稿语义）。
  /// style.motion=='fade_in' 的节点把整体 alpha 乘以该进度；经 repaint
  /// listenable（动画）逐帧驱动重绘。
  final Animation<double>? entrance;
  /// 引擎 SVG 在场时为 true：只画选区环/悬停/手柄，节点本体由 SvgPicture
  /// 层承载（引擎自渲染是内容层唯一真源，客户端不重复实现渲染）。
  final bool overlayOnly;

  ArtboardPainter({
    required this.nodes,
    required this.accent,
    this.overlayOnly = false,
    this.selectedId,
    this.selectedIds = const [],
    this.hoverId,
    this.dragId,
    this.dragDelta,
    this.resizeId,
    this.resizeStart,
    this.resizeHandle,
    this.resizeDelta,
    this.entrance,
    super.repaint, // NodeImageCache：图片异步加载完成后重绘画布
  });

  @override
  void paint(Canvas canvas, Size size) {
    final dragDelta = this.dragDelta?.value ?? Offset.zero;
    final resizeDelta = this.resizeDelta?.value ?? Offset.zero;
    final entrance = this.entrance?.value ?? 1.0;
    for (final node in nodes) {
      if (!node.style.visible) continue;
      final isDragging = dragId == node.id;
      final isResizing = resizeId == node.id && resizeStart != null;
      final rect = isResizing
          ? _applyResizeHandle(resizeStart!, resizeDelta, resizeHandle ?? _ResizeHandle.bottomRight)
          : Rect.fromLTWH(
              node.x + (isDragging ? dragDelta.dx : 0.0),
              node.y + (isDragging ? dragDelta.dy : 0.0),
              node.w,
              node.h,
            );
      final radius = math.min(node.style.radius, rect.shortestSide / 2);
      final rrect = RRect.fromRectAndRadius(rect, Radius.circular(radius));
      // motion=fade_in（引擎 0.2 节点级白名单唯一档）：整体 alpha 乘入场进度。
      final alpha = node.style.opacity.clamp(0.0, 1.0) *
          (node.style.motion == 'fade_in' ? entrance : 1.0);

      // 绕节点中心旋转（引擎 svg transform 语义）；绘制完 restore。
      final rot = node.style.rotate;
      if (rot != 0) {
        final c = rect.center;
        canvas.save();
        canvas.translate(c.dx, c.dy);
        canvas.rotate(rot * math.pi / 180.0);
        canvas.translate(-c.dx, -c.dy);
      }

      // 本体绘制段：overlayOnly（引擎 SVG 承载内容）时整体跳过——
      // 只留后面的选区/悬停环。旧信封（无 svg）仍走完整绘制。
      if (!overlayOnly) {
      // 阴影 = 海拔档位（引擎 defs 三档 feDropShadow 参数逐一对齐：
      // e1 dy2/std4/0.10、e2 dy6/std14/0.14、e3 dy16/std30/0.18）。
      final tier = node.style.shadow;
      if (tier != 'none' && alpha > 0.05) {
        final (opacity, std, dy) = switch (tier) {
          'e3' => (0.18, 30.0, 16.0),
          'e2' => (0.14, 14.0, 6.0),
          _ => (0.10, 4.0, 2.0), // e1；未知非 none 值回落 e1
        };
        final shadow = Paint()
          ..color = Colors.black.withValues(alpha: opacity * alpha)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, std);
        canvas.drawRRect(rrect.shift(Offset(0, dy)), shadow);
      }

      // blur>0：fill/stroke/text（含图片/占位符）包一层高斯模糊 saveLayer。
      final blur = node.style.blur;
      final blurred = blur > 0;
      if (blurred) {
        canvas.saveLayer(
          rect.inflate(blur * 3),
          Paint()..imageFilter = ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        );
      }

      final gradient = _gradientSpec(node.style.fill);
      if (gradient != null) {
        if (alpha > 0) {
          final (colors, dir) = gradient;
          final modulated = [
            for (final c in colors) c.withValues(alpha: c.a * alpha),
          ];
          canvas.drawRRect(
            rrect,
            Paint()
              ..shader = LinearGradient(
                begin: Alignment(-dir.dx, -dir.dy),
                end: Alignment(dir.dx, dir.dy),
                colors: modulated,
              ).createShader(rect),
          );
        }
      } else {
        final fill = _hex(node.style.fill);
        if (fill != Colors.transparent && alpha > 0) {
          canvas.drawRRect(rrect, Paint()..color = fill.withValues(alpha: fill.a * alpha));
        }
      }

      final stroke = _hex(node.style.stroke);
      if (node.style.stroke != 'none' && stroke != Colors.transparent && node.style.strokeWidth > 0) {
        final strokePaint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = node.style.strokeWidth
          ..color = stroke.withValues(alpha: stroke.a * alpha);
        if (node.style.dash == 'dashed' || node.style.dash == 'dotted') {
          _paintDashedStroke(canvas, rrect, strokePaint, node.style.dash,
              math.max(1.0, node.style.strokeWidth));
        } else {
          canvas.drawRRect(rrect, strokePaint);
        }
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

      if (blurred) canvas.restore();
      } // !overlayOnly

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

      // overlayOnly 下拖拽/缩放中的节点：svg 层静止，覆盖层画幽灵框跟随。
      if (overlayOnly && (isDragging || isResizing)) {
        canvas.drawRRect(
          rrect,
          Paint()
            ..color = accent.withValues(alpha: 0.12)
            ..strokeWidth = 1.2
            ..style = PaintingStyle.stroke,
        );
        canvas.drawRRect(rrect, Paint()..color = accent.withValues(alpha: 0.06));
      }

      if (rot != 0) canvas.restore();
    }
  }

  /// 虚线/点线描边：rrect 路径经 PathMetric 切段（dashed 交替段，
  /// dotted 沿路径布圆点）。
  void _paintDashedStroke(Canvas canvas, RRect rrect, Paint paint, String dash, double strokeWidth) {
    final metrics = Path()..addRRect(rrect);
    if (dash == 'dotted') {
      final r = math.max(1.0, strokeWidth / 2);
      final gap = math.max(4.0, strokeWidth * 3);
      final dot = Paint()..color = paint.color;
      for (final m in metrics.computeMetrics()) {
        var dist = 0.0;
        while (dist <= m.length) {
          final tangent = m.getTangentForOffset(dist);
          if (tangent != null) canvas.drawCircle(tangent.position, r, dot);
          dist += gap;
        }
      }
    } else {
      final on = math.max(6.0, strokeWidth * 3);
      final dashed = Path();
      for (final m in metrics.computeMetrics()) {
        var dist = 0.0;
        while (dist < m.length) {
          dashed.addPath(m.extractPath(dist, math.min(dist + on, m.length)), Offset.zero);
          dist += on * 2;
        }
      }
      canvas.drawPath(dashed, paint);
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
    final color = _hex(node.style.textColor, fallback: const Color(0xFF111827));
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
    // 引擎 svg 对齐口径：12px 文本内边距（list_item/card 实测），不截断
    // （超板如实可见，与演示模式「不裁剪」取向一致）。
    final width = math.max(4, rect.width - 24).round();
    final aq = (alpha * 16).round();
    final key = '${node.text}|${node.style.fontSize}|${weight.index}|${align.index}|$width|$aq'
        '|${node.style.line}|${node.style.tracking}|${node.style.italic}';
    var painter = _textCache[key];
    if (painter == null) {
      painter = TextPainter(
        text: TextSpan(
          text: node.text,
          style: TextStyle(
            fontSize: node.style.fontSize,
            fontWeight: weight,
            color: color.withValues(alpha: color.a * alpha),
            height: node.style.line > 0 ? node.style.line : 1.5,
            letterSpacing: node.style.tracking * node.style.fontSize,
            fontStyle: node.style.italic == 'italic' ? FontStyle.italic : FontStyle.normal,
          ),
        ),
        textAlign: align,
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: width.toDouble());
      // 容量兜底：整表清（一次 raster 开销换免 LRU 记账）。
      if (_textCache.length > 512) _textCache.clear();
      _textCache[key] = painter;
    }
    final x = rect.left + 12;
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
      // 字段级对比；delta 本体不在链上——它经 repaint listenable（ValueNotifier）
      // 逐帧直驱重绘，painter 重建只比监听器身份。entrance 同理：进度经
      // repaint（动画 listenable）驱动，链上只比动画身份。
      old.nodes != nodes ||
      old.selectedId != selectedId ||
      !identical(old.selectedIds, selectedIds) ||
      old.hoverId != hoverId ||
      old.dragId != dragId ||
      !identical(old.dragDelta, dragDelta) ||
      old.resizeId != resizeId ||
      old.resizeStart != resizeStart ||
      old.resizeHandle != resizeHandle ||
      !identical(old.resizeDelta, resizeDelta) ||
      old.entrance != entrance;
}

/// 画布内边距：layoutBoards 的板位 rect 以 0 起算，板上屏统一 +80/+80
/// （留出板名标签与阴影空间）。FlowPainter 必须使用同一坐标系，否则连线
/// 相对画板整体偏移 80px、箭头会扎进板里——「板位 rect 避让」也就无从谈起。
const Offset _canvasPad = Offset(80, 80);

/// 一条聚合后的跳转边：同一对 (from,to) 的多条 flow 合并成一条线，
/// count 用于中点 ×N 计数（避免平行线堆叠），points 是板边正交折线。
class _RoutedFlow {
  final String from;
  final String to;
  final String label;
  final int count;
  final List<Offset> points;

  const _RoutedFlow({
    required this.from,
    required this.to,
    required this.label,
    required this.count,
    required this.points,
  });
}

class FlowPainter extends CustomPainter {
  final List<Artboard> boards;
  final Map<String, Rect> positions;
  final List<Flow> flows;
  /// 缩放经 repaint listenable 实时注入：HUD/手势只改 _controller.value
  /// 不 setState，build 期快照的 zoom 对比拿不到新值——挂在 controller 上，
  /// paint 时现读，缩放中/后流线描边与箭头补偿即时跟随。
  final TransformationController controller;

  /// 配色取 context.palette（NonPalette 是唯一颜色源，painter 无 context
  /// 只能传值）：accent 高亮线、ink 标签字、panel 标签底、line 标签描边。
  final Color accent;
  final Color ink;
  final Color panel;
  final Color line;

  /// 焦点板：当前选中板 / 悬停板 / 原型起始板（entry）。只有与它们相关的
  /// 连线保持 accent 高亮并显示标签，其余降到很淡的背景层——所有线同等
  /// 强调时线会互相穿插、标签压板，反而看不出跳转关系（用户反馈）。
  final String? activeBoard;
  final String? hoveredBoard;
  final String? entryBoard;

  /// 板位 rect 的坐标系平移（见 _canvasPad）。
  final Offset canvasPadding;

  FlowPainter({
    required this.boards,
    required this.positions,
    required this.flows,
    required this.controller,
    required this.accent,
    required this.ink,
    required this.panel,
    required this.line,
    this.activeBoard,
    this.hoveredBoard,
    this.entryBoard,
    this.canvasPadding = _canvasPad,
  }) : super(repaint: controller);

  @override
  void paint(Canvas canvas, Size size) {
    if (flows.isEmpty || boards.isEmpty) return;
    final zoom = controller.value.getMaxScaleOnAxis();
    final k = 1 / math.max(0.2, zoom);

    // 板位 rect 平移到板 widget 同一坐标系；顺带记下板名（标签用）。
    final rects = <String, Rect>{};
    final names = <String, String>{};
    for (final b in boards) {
      final r = positions[b.id];
      if (r == null) continue;
      rects[b.id] = r.shift(canvasPadding);
      names[b.id] = b.name.isEmpty ? b.id : b.name;
    }
    if (rects.isEmpty) return;
    final obstacles = rects.values.toList(growable: false);

    // 同一对板之间的多条 flow 合并成一条（count 进标签），只留唯一一条线。
    final order = <String>[];
    final counts = <String, int>{};
    for (final f in flows) {
      if (f.from == f.to) continue; // 自跳转没有可读的板间路由
      if (!rects.containsKey(f.from) || !rects.containsKey(f.to)) continue;
      final key = '${f.from}\u0001${f.to}';
      if (!counts.containsKey(key)) order.add(key);
      counts[key] = (counts[key] ?? 0) + 1;
    }
    if (order.isEmpty) return;

    final focus = <String>{};
    for (final id in [activeBoard, hoveredBoard, entryBoard]) {
      if (id != null && id.isNotEmpty && rects.containsKey(id)) focus.add(id);
    }

    // 标签策略（「高亮线各标一个」与「只标焦点板」结合）：悬停优先——
    // 用户正在看这块板就只标它；否则标选中板；再退起始板。其余高亮线
    // 只亮线不带标签，配合下面的标签互斥避让，线多时也不糊。
    String? labelFocus;
    if (hoveredBoard != null && rects.containsKey(hoveredBoard)) {
      labelFocus = hoveredBoard;
    } else if (activeBoard != null && rects.containsKey(activeBoard)) {
      labelFocus = activeBoard;
    } else if (entryBoard != null && rects.containsKey(entryBoard)) {
      labelFocus = entryBoard;
    }

    // 先画全部淡线，再画高亮线（高亮永远压在最上层）。
    final faint = <List<Offset>>[];
    final lit = <_RoutedFlow>[];
    for (final key in order) {
      final sep = key.indexOf('\u0001');
      final fromId = key.substring(0, sep);
      final toId = key.substring(sep + 1);
      final from = rects[fromId]!;
      final to = rects[toId]!;
      final points = _route(from, to, obstacles);
      if (points.length < 2) continue;
      // 焦点为空是异常态（activeBoard 未就绪）：全部高亮，避免线整层消失。
      final highlight = focus.isEmpty || focus.contains(fromId) || focus.contains(toId);
      if (highlight) {
        lit.add(_RoutedFlow(
          from: fromId,
          to: toId,
          label: names[toId] ?? toId,
          count: counts[key] ?? 1,
          points: points,
        ));
      } else {
        faint.add(points);
      }
    }

    for (final points in faint) {
      _paintFlow(canvas, points, k, zoom, obstacles, highlight: false);
    }
    // 已放置的标签矩形：后画的标签必须避开它们（两个标签叠在一起比没有更乱）。
    final labelBoxes = <Rect>[];
    for (final routed in lit) {
      final allowLabel = labelFocus != null &&
          (routed.from == labelFocus || routed.to == labelFocus);
      // 标签永远指「对端」：出边标目标板，入边标来源板——否则焦点板的
      // 多条入边会挂一串一样的板名，等于没信息。
      final label = routed.to == labelFocus
          ? (names[routed.from] ?? routed.from)
          : routed.label;
      _paintFlow(canvas, routed.points, k, zoom, obstacles,
          highlight: true,
          label: label,
          count: routed.count,
          allowLabel: allowLabel,
          labelBoxes: labelBoxes);
    }
  }

  /// 板边正交路由：出口/入口都取板边缘中点，按两块板相对位置选边；
  /// 候选折线全部水平/垂直（2–4 段），用其余板的 rect 打分——穿过板数
  /// 最少优先，其次路径最短，同分取先生成（更符合相对位置的走向）。
  /// 布局是网格 + 150px 板间通道，所以「贴板外侧的通道 + 中段过渡」
  /// 几乎总能绕开中间板，包括同行隔板跳转与深对角跳转。
  List<Offset> _route(Rect from, Rect to, List<Rect> obstacles) {
    final dx = to.center.dx - from.center.dx;
    final dy = to.center.dy - from.center.dy;
    final hGap = math.max(to.left - from.right, from.left - to.right);
    final vGap = math.max(to.top - from.bottom, from.top - to.bottom);
    final preferHorizontal = (hGap > 0 && (vGap <= 0 || hGap >= vGap)) ||
        (hGap <= 0 && vGap <= 0 && dx.abs() >= dy.abs());
    // 两板之间的通道距离；绕行通道贴板外侧并多留一点标签位置。
    const margin = 26.0;
    const outside = 34.0;

    final hBetween = <List<Offset>>[];
    final vBetween = <List<Offset>>[];
    final mixed = <List<Offset>>[];
    final hOutside = <List<Offset>>[];
    final vOutside = <List<Offset>>[];

    if (hGap > 0) {
      // 横向有通道：出口/入口在左右边中点，中间竖一段过渡。
      final right = dx >= 0;
      final dir = right ? 1.0 : -1.0;
      final src = Offset(right ? from.right : from.left, from.center.dy);
      final dst = Offset(right ? to.left : to.right, to.center.dy);
      for (final cx in <double>[
        (src.dx + dst.dx) / 2,
        src.dx + dir * margin,
        dst.dx - dir * margin,
      ]) {
        // 通道必须在两锚点之间（不回折），且离两端留出圆角空间。
        if (right ? (cx <= src.dx + 6 || cx >= dst.dx - 6) : (cx >= src.dx - 6 || cx <= dst.dx + 6)) {
          continue;
        }
        hBetween.add(<Offset>[src, Offset(cx, src.dy), Offset(cx, dst.dy), dst]);
      }
    }
    if (vGap > 0) {
      // 纵向有通道：出口/入口在上下边中点，中间横一段过渡。
      final down = dy >= 0;
      final dir = down ? 1.0 : -1.0;
      final src = Offset(from.center.dx, down ? from.bottom : from.top);
      final dst = Offset(to.center.dx, down ? to.top : to.bottom);
      for (final cy in <double>[
        (src.dy + dst.dy) / 2,
        src.dy + dir * margin,
        dst.dy - dir * margin,
      ]) {
        if (down ? (cy <= src.dy + 6 || cy >= dst.dy - 6) : (cy >= src.dy - 6 || cy <= dst.dy + 6)) {
          continue;
        }
        vBetween.add(<Offset>[src, Offset(src.dx, cy), Offset(dst.dx, cy), dst]);
      }
    }
    if (hGap <= 0) {
      // 同列（横向无通道）：从列外侧绕 U 形，出口/入口同侧。
      for (final side in const <double>[1.0, -1.0]) {
        final edgeX = side > 0 ? math.max(from.right, to.right) : math.min(from.left, to.left);
        final cx = edgeX + side * outside;
        final src = Offset(side > 0 ? from.right : from.left, from.center.dy);
        final dst = Offset(side > 0 ? to.right : to.left, to.center.dy);
        hOutside.add(<Offset>[src, Offset(cx, src.dy), Offset(cx, dst.dy), dst]);
      }
    }
    if (vGap <= 0) {
      // 同行（纵向无通道）：从行外侧绕 U 形，典型是「同行隔板」的下穿。
      for (final side in const <double>[1.0, -1.0]) {
        final edgeY = side > 0 ? math.max(from.bottom, to.bottom) : math.min(from.top, to.top);
        final cy = edgeY + side * outside;
        final src = Offset(from.center.dx, side > 0 ? from.bottom : from.top);
        final dst = Offset(to.center.dx, side > 0 ? to.bottom : to.top);
        vOutside.add(<Offset>[src, Offset(src.dx, cy), Offset(dst.dx, cy), dst]);
      }
    }
    // 混合走向（一横一竖）：先出板到本板外侧通道，再贴目标板外侧进板，
    // 中间横/竖过渡——深对角跳转（跨两行/两列以上）靠它绕开中间板。
    if (preferHorizontal) {
      final dirE = dx >= 0 ? 1.0 : -1.0;
      final dirN = dy >= 0 ? 1.0 : -1.0;
      final src = Offset(dx >= 0 ? from.right : from.left, from.center.dy);
      final dst = Offset(to.center.dx, dy >= 0 ? to.top : to.bottom);
      // 出板通道要越过「本列」整列的边缘，否则会切到更宽的同列板。
      final bandX = dirE > 0 ? _bandRight(from, obstacles) + margin : _bandLeft(from, obstacles) - margin;
      for (final laneX in <double>[src.dx + dirE * margin, bandX, (src.dx + dst.dx) / 2]) {
        for (final laneY in <double>[dst.dy - dirN * margin, (src.dy + dst.dy) / 2]) {
          mixed.add(<Offset>[src, Offset(laneX, src.dy), Offset(laneX, laneY), Offset(dst.dx, laneY), dst]);
        }
      }
    } else {
      final dirE = dy >= 0 ? 1.0 : -1.0;
      final dirN = dx >= 0 ? 1.0 : -1.0;
      final src = Offset(from.center.dx, dy >= 0 ? from.bottom : from.top);
      final dst = Offset(dx >= 0 ? to.left : to.right, to.center.dy);
      // 出板通道要越过「本行」整行的边缘，否则会切到更高的同行板。
      final bandY = dirE > 0 ? _bandBottom(from, obstacles) + margin : _bandTop(from, obstacles) - margin;
      for (final laneY in <double>[src.dy + dirE * margin, bandY, (src.dy + dst.dy) / 2]) {
        for (final laneX in <double>[dst.dx - dirN * margin, (src.dx + dst.dx) / 2]) {
          mixed.add(<Offset>[src, Offset(src.dx, laneY), Offset(laneX, laneY), Offset(laneX, dst.dy), dst]);
        }
      }
    }
    final ordered = <List<Offset>>[];
    if (preferHorizontal) {
      ordered.addAll(hBetween);
      ordered.addAll(mixed);
      ordered.addAll(vBetween);
      ordered.addAll(hOutside);
      ordered.addAll(vOutside);
    } else {
      ordered.addAll(vBetween);
      ordered.addAll(mixed);
      ordered.addAll(hBetween);
      ordered.addAll(vOutside);
      ordered.addAll(hOutside);
    }
    if (ordered.isEmpty) {
      // 板重叠等异常布局的兜底：两段直角折线，两端仍落在板边中点。
      final src = Offset(dx >= 0 ? from.right : from.left, from.center.dy);
      ordered.add(<Offset>[
        src,
        Offset(dx >= 0 ? to.left : to.right, src.dy),
        Offset(dx >= 0 ? to.left : to.right, to.center.dy),
      ]);
    }

    List<Offset>? best;
    var bestScore = double.infinity;
    for (final candidate in ordered) {
      final pts = _simplifyPolyline(candidate);
      if (pts.length < 2) continue;
      var hits = 0;
      var length = 0.0;
      for (var i = 0; i + 1 < pts.length; i++) {
        length += (pts[i + 1] - pts[i]).distance;
        for (final r in obstacles) {
          if (identical(r, from) || identical(r, to)) continue;
          if (_segmentCrossesRect(pts[i], pts[i + 1], r)) hits++;
        }
      }
      final score = hits * 100000.0 + length;
      if (score < bestScore) {
        bestScore = score;
        best = pts;
      }
    }
    return best ?? const <Offset>[];
  }

  /// 与 from 同一行（纵向范围相交）的板下沿/上沿：混合路由的横通道必须
  /// 落在整行之外，否则会被同行更高的板挡住（板高不一致时 bottom 不齐）。
  double _bandBottom(Rect from, List<Rect> obstacles) {
    var bottom = from.bottom;
    for (final r in obstacles) {
      if (identical(r, from)) continue;
      if (r.top < from.bottom && r.bottom > from.top) bottom = math.max(bottom, r.bottom);
    }
    return bottom;
  }

  double _bandTop(Rect from, List<Rect> obstacles) {
    var top = from.top;
    for (final r in obstacles) {
      if (identical(r, from)) continue;
      if (r.top < from.bottom && r.bottom > from.top) top = math.min(top, r.top);
    }
    return top;
  }

  /// 与 from 同一列（横向范围相交）的板右沿/左沿（同上，列内板宽不一致）。
  double _bandRight(Rect from, List<Rect> obstacles) {
    var right = from.right;
    for (final r in obstacles) {
      if (identical(r, from)) continue;
      if (r.left < from.right && r.right > from.left) right = math.max(right, r.right);
    }
    return right;
  }

  double _bandLeft(Rect from, List<Rect> obstacles) {
    var left = from.left;
    for (final r in obstacles) {
      if (identical(r, from)) continue;
      if (r.left < from.right && r.right > from.left) left = math.min(left, r.left);
    }
    return left;
  }

  /// 去掉零长段与共线中间点（同向），保证后面的圆角/标签段序干净。
  List<Offset> _simplifyPolyline(List<Offset> input) {
    final out = <Offset>[];
    for (final p in input) {
      if (out.isNotEmpty && (p - out.last).distance < 0.01) continue;
      out.add(p);
    }
    var i = 1;
    while (i < out.length - 1) {
      final a = out[i - 1];
      final b = out[i];
      final c = out[i + 1];
      final cross = (b.dx - a.dx) * (c.dy - b.dy) - (b.dy - a.dy) * (c.dx - b.dx);
      if (cross.abs() < 0.01) {
        out.removeAt(i);
      } else {
        i++;
      }
    }
    return out;
  }

  /// 轴对齐线段是否穿过 board rect（只做 BBox 判定——线段非横即竖）。
  bool _segmentCrossesRect(Offset a, Offset b, Rect r) {
    final l = math.min(a.dx, b.dx);
    final rr = math.max(a.dx, b.dx);
    final t = math.min(a.dy, b.dy);
    final bb = math.max(a.dy, b.dy);
    return rr > r.left && l < r.right && bb > r.top && t < r.bottom;
  }

  /// 折线 → 圆角路径：每个拐点用二次贝塞尔收圆角，半径随缩放补偿
  /// （屏幕 ~12px），并钳到相邻线段长度的一半以内。
  Path _roundedPolyline(List<Offset> pts, double radius) {
    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (var i = 1; i < pts.length - 1; i++) {
      final prev = pts[i - 1];
      final cur = pts[i];
      final next = pts[i + 1];
      final l1 = (cur - prev).distance;
      final l2 = (next - cur).distance;
      final r = math.min(radius, math.min(l1, l2) * 0.45);
      if (r <= 0.5) {
        path.lineTo(cur.dx, cur.dy);
        continue;
      }
      final u1 = (cur - prev) / l1;
      final u2 = (next - cur) / l2;
      final p1 = cur - u1 * r;
      final p2 = cur + u2 * r;
      path.lineTo(p1.dx, p1.dy);
      path.quadraticBezierTo(cur.dx, cur.dy, p2.dx, p2.dy);
    }
    path.lineTo(pts.last.dx, pts.last.dy);
    return path;
  }

  void _paintFlow(
    Canvas canvas,
    List<Offset> points,
    double k,
    double zoom,
    List<Rect> obstacles, {
    required bool highlight,
    String label = '',
    int count = 0,
    bool allowLabel = false,
    List<Rect>? labelBoxes,
  }) {
    // 高亮 1.9px / 其余 1.1px（屏幕像素，随缩放补偿）；alpha 0.14 让
    // 非焦点连线退成背景肌理，不再和焦点线抢注意力。
    final color = highlight ? accent.withValues(alpha: 0.9) : accent.withValues(alpha: 0.14);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = (highlight ? 1.9 : 1.1) * k
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(_roundedPolyline(points, (12 * k).clamp(2.0, 36.0).toDouble()), stroke);
    _paintArrow(canvas, points[points.length - 2], points.last, color, k);
    if (!highlight || !allowLabel || labelBoxes == null) return;
    _paintLabel(canvas, points, label, count, k, zoom, obstacles, labelBoxes);
  }

  /// 箭头画在目标板边缘：尖端贴板边、两翼在板外——尺寸 13 屏幕 px
  /// （13 * k 补偿缩放），不会穿进目标板内部。
  void _paintArrow(Canvas canvas, Offset from, Offset tip, Color color, double k) {
    final delta = tip - from;
    final len = delta.distance;
    if (len < 0.01) return;
    final unit = delta / len;
    final head = 13 * k;
    final base = tip - unit * head;
    final normal = Offset(-unit.dy, unit.dx);
    final wing = head * 0.52;
    final arrow = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(base.dx + normal.dx * wing, base.dy + normal.dy * wing)
      ..lineTo(base.dx - normal.dx * wing, base.dy - normal.dy * wing)
      ..close();
    canvas.drawPath(arrow, Paint()..color = color);
  }

  /// 高亮线的唯一标签（目标板名，多条合并时带 ×N）：放在中段外侧的
  /// 法线上，并避开所有板位 rect——不压画板、不叠线。
  void _paintLabel(
    Canvas canvas,
    List<Offset> points,
    String label,
    int count,
    double k,
    double zoom,
    List<Rect> obstacles,
    List<Rect> placedBoxes,
  ) {
    final text = count > 1 ? '$label  ×$count' : label;
    // 字号按 1/zoom 反算：缩到 33% 时画布字号变大，屏幕上始终约 10px
    // （旧实现 *0.55 在 33% 下只有 ~1.8px，标签等于没画）。
    final fontSize = (10.0 / math.max(0.2, zoom)).clamp(6.0, 60.0).toDouble();
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(fontSize: fontSize, fontFamily: 'Menlo', color: ink, height: 1.1),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: 200);
    final padX = fontSize * 0.55;
    final padY = fontSize * 0.3;
    final w = tp.width + padX * 2;
    final h = tp.height + padY * 2;

    // 段序：中线附近优先，再向两侧扩；每段试中线/近中线位置与法线两侧。
    final order = <int>[];
    final mid = (points.length - 1) ~/ 2;
    if (mid < points.length - 1) order.add(mid);
    for (var step = 1; step < points.length; step++) {
      for (final i in <int>[mid - step, mid + step]) {
        if (i >= 0 && i < points.length - 1 && !order.contains(i)) order.add(i);
      }
    }
    Rect? placed;
    for (final i in order) {
      final a = points[i];
      final b = points[i + 1];
      final segLen = (b - a).distance;
      if (segLen < 1) continue;
      final unit = (b - a) / segLen;
      final normal = Offset(-unit.dy, unit.dx);
      for (final t in const <double>[0.5, 0.42, 0.58, 0.32, 0.68]) {
        final base = a + (b - a) * t;
        for (final side in const <double>[1.0, -1.0]) {
          final center = base + normal * side * (h / 2 + 8 * k);
          final rect = Rect.fromCenter(center: center, width: w, height: h);
          if (_rectHitsBoards(rect, obstacles)) continue;
          // 标签互斥：两个标签压在一起比没有标签更乱，放不下就跳过。
          if (placedBoxes.any((r) => rect.overlaps(r.inflate(2)))) continue;
          placed = rect;
          break;
        }
        if (placed != null) break;
      }
      if (placed != null) break;
    }
    if (placed == null) return; // 周围都被板和已有标签占满：这条线不标
    final rect = placed;
    placedBoxes.add(rect);
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(4 * k));
    canvas.drawRRect(rrect, Paint()..color = panel.withValues(alpha: 0.94));
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = line
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1 * k,
    );
    tp.paint(canvas, Offset(rect.left + padX, rect.top + (rect.height - tp.height) / 2));
  }

  bool _rectHitsBoards(Rect rect, List<Rect> obstacles) {
    for (final r in obstacles) {
      if (rect.overlaps(r.inflate(2))) return true;
    }
    return false;
  }

  @override
  bool shouldRepaint(covariant FlowPainter old) =>
      // positions 是字段级对比：layoutBoards 每次 build 新建 Map，恒等比较
      // 恒不等 → 流线整层跟着画布每次 rebuild 重绘，抵消 RepaintBoundary 隔离。
      // flows 保持引用比较（render 信封未变时为同实例）。zoom 不在对比链——
      // 缩放经 repaint listenable（controller）直驱，见构造参数注释。
      // 焦点板与配色都进对比链：hover 换板只重绘连线层，不碰板内 painter。
      old.boards != boards ||
      old.flows != flows ||
      !mapEquals(old.positions, positions) ||
      old.activeBoard != activeBoard ||
      old.hoveredBoard != hoveredBoard ||
      old.entryBoard != entryBoard ||
      old.accent != accent ||
      old.ink != ink ||
      old.panel != panel ||
      old.line != line ||
      old.canvasPadding != canvasPadding;
}

class _EmptyCanvas extends StatelessWidget {
  final AppStore store;
  const _EmptyCanvas({required this.store});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    // 固定 520 宽在手机（画布可用 ~344）会溢出；限宽到可用宽度并给文字留
    // Expanded，按钮换行。宽屏仍保持 520 的卡片宽度。
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
          color: p.panel.withValues(alpha: 0.94),
          borderRadius: BorderRadius.circular(16),
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
                    borderRadius: BorderRadius.circular(12),
                    gradient: LinearGradient(colors: [p.accent, p.accent2]),
                  ),
                  child: const Icon(Icons.auto_awesome, size: 17, color: Colors.white),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('从一句话开始', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: p.ink)),
                      Text('NaN 先写产品文档与设计规范，再把原型画到画布上。',
                          style: TextStyle(fontSize: 11, color: p.ink3)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              MediaQuery.sizeOf(context).width < 700
                  ? '在底部 NaN 面板描述你的产品；或先用文档页生成 PRD。'
                  : '在右侧 NaN 面板描述你的产品；或先用文档页生成 PRD。',
              style: TextStyle(fontSize: 12, height: 1.6, color: p.ink3),
            ),
            const SizedBox(height: 10),
            // 移动适配（2026-11-19）：空项目不再放操作按钮——描述文案
            // 指向右侧 NaN 面板即可，动作由面板/composer 承担。
          ],
        ),
          ),
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
