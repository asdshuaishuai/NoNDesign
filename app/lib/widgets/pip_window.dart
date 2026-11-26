import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';
import 'common.dart';

/// 画中画浮窗的开启方向：true = 从右缘向左划（iOS 侧滑惯例，右缘 20px
/// 条带 + 常驻「工作区」胶囊）。产品口径若反过来（左缘/向右划），只改
/// 这一个常量——条带摆放与本文件内的方向判定都从它派生。
const bool kPipOpensFromRightEdge = true;

/// 浮窗最小尺寸（右下缩放手柄不得低于此值）。与 clip 到堆叠区的上限
/// 一起由宿主在 onRect 里收口。
const Size kPipMinSize = Size(320, 280);

/// 画中画浮窗（docs/plan-chat-stream-shell.md §2 S4）。
///
/// 受控组件：位置/尺寸（[rect]）与全屏态（[maximized]）由宿主持有并经
/// [onRect]/[onToggleMax] 回传；只有「拖动/缩放进行中」([_interacting])
/// 是视图局部状态——它决定 child 之上的指针吸收层是否存在，必须由本
/// 组件自己持有，宿主不能代管。
///
/// 手势优先级：窗容器先于内容（plan §6.4）——头部拖动或手柄缩放期间，
/// child 上方盖一层 opaque GestureDetector 吸收新指针，画布/内容不响应；
/// 松手（onPanEnd/onPanCancel）即撤除，内容恢复可交互。
class PipWindow extends StatefulWidget {
  final Widget child;
  final String title;
  final Rect rect;
  final ValueChanged<Rect> onRect;
  final VoidCallback onClose;
  final VoidCallback onToggleMax;
  final bool maximized;

  /// 拖动/缩放手势结束（宿主据此持久化 rect——逐帧写盘不可接受）。
  final VoidCallback? onInteractEnd;

  const PipWindow({
    super.key,
    required this.child,
    required this.title,
    required this.rect,
    required this.onRect,
    required this.onClose,
    required this.onToggleMax,
    this.maximized = false,
    this.onInteractEnd,
  });

  @override
  State<PipWindow> createState() => _PipWindowState();
}

class _PipWindowState extends State<PipWindow> {
  /// 拖动/缩放进行中：child 之上的吸收层只在此时存在（结束后必须撤除，
  /// 否则画布永久不可交互）。
  bool _interacting = false;

  /// 手势起点几何：pan 增量按起点累计，不依赖 widget.rect 的逐帧回灌
  ///（宿主 setState 要下一帧才把新 rect 传回来，同帧多次 update 会丢位移）。
  Rect? _baseRect;
  Offset _delta = Offset.zero;

  void _beginInteract() {
    if (widget.maximized) return;
    setState(() {
      _interacting = true;
      _baseRect = widget.rect;
      _delta = Offset.zero;
    });
  }

  void _endInteract() {
    if (!_interacting) return;
    setState(() {
      _interacting = false;
      _baseRect = null;
      _delta = Offset.zero;
    });
    widget.onInteractEnd?.call();
  }

  void _onDragUpdate(DragUpdateDetails d) {
    final base = _baseRect;
    if (base == null) return;
    _delta += d.delta;
    widget.onRect(base.shift(_delta));
  }

  void _onResizeUpdate(DragUpdateDetails d) {
    final base = _baseRect;
    if (base == null) return;
    _delta += d.delta;
    widget.onRect(Rect.fromLTWH(
      base.left,
      base.top,
      math.max(kPipMinSize.width, base.width + _delta.dx),
      math.max(kPipMinSize.height, base.height + _delta.dy),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Material(
      elevation: 18,
      shadowColor: Colors.black.withValues(alpha: 0.45),
      color: p.bgElevated,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          _header(context, p),
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(child: widget.child),
                if (!widget.maximized)
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: _resizeHandle(context, p),
                  ),
                // 手势吸收层：拖动/缩放期间盖在 child 之上，任何新指针都
                // 落在这一层（opaque），内容（画布/滚动）不抢手势。
                if (_interacting)
                  Positioned.fill(
                    child: IgnorePointer(
                      ignoring: false,
                      child: GestureDetector(
                        key: const ValueKey('pip-absorb'),
                        behavior: HitTestBehavior.opaque,
                        onPanStart: (_) {},
                        onPanUpdate: (_) {},
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context, NonPalette p) {
    return GestureDetector(
      key: const ValueKey('pip-header'),
      behavior: HitTestBehavior.opaque,
      onPanStart: (_) => _beginInteract(),
      onPanUpdate: _onDragUpdate,
      onPanEnd: (_) => _endInteract(),
      onPanCancel: _endInteract,
      child: MouseRegion(
        cursor: widget.maximized ? MouseCursor.defer : SystemMouseCursors.move,
        child: Container(
          height: 40,
          padding: const EdgeInsets.only(left: 10, right: 4),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: p.line))),
          child: Row(
            children: [
              Icon(Icons.space_dashboard_outlined, size: 14, color: p.ink3),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: NonType.body, fontWeight: FontWeight.w600, color: p.ink2),
                ),
              ),
              IconAction(
                key: const ValueKey('pip-max'),
                icon: widget.maximized ? Icons.fullscreen_exit : Icons.fullscreen,
                tooltip: widget.maximized ? '还原' : '全屏',
                onTap: widget.onToggleMax,
              ),
              IconAction(
                key: const ValueKey('pip-close'),
                icon: Icons.close,
                tooltip: '关闭工作区',
                onTap: widget.onClose,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _resizeHandle(BuildContext context, NonPalette p) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeUpLeftDownRight,
      child: GestureDetector(
        key: const ValueKey('pip-resize'),
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) => _beginInteract(),
        onPanUpdate: _onResizeUpdate,
        onPanEnd: (_) => _endInteract(),
        onPanCancel: _endInteract,
        child: SizedBox(
          width: 22,
          height: 22,
          child: CustomPaint(painter: _ResizeGripPainter(p.ink4)),
        ),
      ),
    );
  }
}

/// 右下角缩放手柄的三道斜纹（纯装饰，命中区是 22×22 的 GestureDetector）。
class _ResizeGripPainter extends CustomPainter {
  final Color color;
  const _ResizeGripPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;
    for (var i = 1; i <= 3; i++) {
      final d = 5.0 * i;
      canvas.drawLine(
        Offset(size.width - d, size.height - 3),
        Offset(size.width - 3, size.height - d),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ResizeGripPainter old) => old.color != color;
}

/// 右侧（或左缘，随 [kPipOpensFromRightEdge]）20px 条带 + 常驻「工作区」
/// 胶囊：右划（向窗内方向）或点胶囊都开画中画浮窗。条带不占满屏宽的
/// 命中区——Align 只在其子级区域内命中，其余指针穿透给下面的聊天流。
class PipEdgeHandle extends StatefulWidget {
  final VoidCallback onOpen;

  const PipEdgeHandle({super.key, required this.onOpen});

  @override
  State<PipEdgeHandle> createState() => _PipEdgeHandleState();
}

class _PipEdgeHandleState extends State<PipEdgeHandle> {
  /// 本次横划累计位移；方向常量决定哪个符号算「开」。开一次即复位，
  /// 同一次手势不重复触发。
  double _drag = 0;
  bool _consumed = false;

  bool _opens(double dx) => kPipOpensFromRightEdge ? dx < -24 : dx > 24;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Align(
      alignment:
          kPipOpensFromRightEdge ? Alignment.centerRight : Alignment.centerLeft,
      child: SizedBox(
        width: 20,
        child: GestureDetector(
          key: const ValueKey('pip-edge-handle'),
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (_) {
            _drag = 0;
            _consumed = false;
          },
          onHorizontalDragUpdate: (d) {
            if (_consumed) return;
            _drag += d.delta.dx;
            if (_opens(_drag)) {
              _consumed = true;
              widget.onOpen();
            }
          },
          onHorizontalDragEnd: (_) => _drag = 0,
          onHorizontalDragCancel: () => _drag = 0,
          child: Align(
            alignment: Alignment.center,
            child: Material(
              color: p.panel2,
              borderRadius: BorderRadius.horizontal(
                left: Radius.circular(kPipOpensFromRightEdge ? 8 : 0),
                right: Radius.circular(kPipOpensFromRightEdge ? 0 : 8),
              ),
              child: InkWell(
                key: const ValueKey('pip-edge-capsule'),
                borderRadius: BorderRadius.circular(8),
                onTap: widget.onOpen,
                child: Container(
                  width: 18,
                  padding: const EdgeInsets.symmetric(vertical: NonSpace.sm),
                  decoration: BoxDecoration(
                    border: Border.all(color: p.line),
                    borderRadius: BorderRadius.horizontal(
                      left: Radius.circular(kPipOpensFromRightEdge ? 8 : 0),
                      right: Radius.circular(kPipOpensFromRightEdge ? 0 : 8),
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final ch in '工作区'.characters)
                        Text(ch,
                            style: TextStyle(
                                fontSize: NonType.micro, height: 1.35, color: p.ink3)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
