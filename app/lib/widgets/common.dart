import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/store.dart';
import '../core/theme.dart';

Color parseHex(String raw, {Color fallback = const Color(0xFF888888)}) {
  var hex = raw.trim();
  if (hex.isEmpty || hex.toLowerCase() == 'none' || hex.toLowerCase() == 'transparent') {
    return Colors.transparent;
  }
  if (hex.startsWith('#')) hex = hex.substring(1);
  if (hex.length == 3) {
    hex = hex.split('').map((c) => '$c$c').join();
  }
  if (hex.length == 6) hex = 'FF$hex';
  final value = int.tryParse(hex, radix: 16);
  return value == null ? fallback : Color(value);
}

String colorToHex(Color color) {
  final a = (color.a * 255).round();
  final r = (color.r * 255).round();
  final g = (color.g * 255).round();
  final b = (color.b * 255).round();
  String h(int v) => v.toRadixString(16).padLeft(2, '0').toUpperCase();
  return a == 255 ? '#${h(r)}${h(g)}${h(b)}' : '#${h(a)}${h(r)}${h(g)}${h(b)}';
}

String formatTokens(num? value) {
  final n = (value ?? 0).toDouble();
  if (n <= 0) return '0';
  if (n < 1000) return n.toStringAsFixed(0);
  if (n < 1000000) return '${(n / 1000).toStringAsFixed(n < 10000 ? 1 : 0)}K';
  return '${(n / 1000000).toStringAsFixed(1)}M';
}

String formatTime(DateTime ts) {
  final h = ts.hour.toString().padLeft(2, '0');
  final m = ts.minute.toString().padLeft(2, '0');
  return '$h:$m';
}

String relativeTime(int? ms) {
  if (ms == null) return '';
  final delta = DateTime.now().millisecondsSinceEpoch - ms;
  if (delta < 60000) return '刚刚';
  if (delta < 3600000) return '${delta ~/ 60000} 分钟前';
  if (delta < 86400000) return '${delta ~/ 3600000} 小时前';
  return DateTime.fromMillisecondsSinceEpoch(ms).toString().substring(0, 10);
}

class NonLogo extends StatelessWidget {
  final double size;
  const NonLogo({super.key, this.size = 28});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.3),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF8D9BFF), Color(0xFFB58CFF), Color(0xFFFF9BD2)],
        ),
        boxShadow: [
          BoxShadow(color: const Color(0x557C8CFF), blurRadius: size * 0.8, offset: Offset(0, size * 0.18)),
        ],
      ),
      child: CustomPaint(painter: _LogoPainter()),
    );
  }
}

class _LogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = size.width * 0.085
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    final path = Path()
      ..moveTo(size.width * 0.32, size.height * 0.70)
      ..lineTo(size.width * 0.32, size.height * 0.30)
      ..lineTo(size.width * 0.69, size.height * 0.70)
      ..lineTo(size.width * 0.69, size.height * 0.30);
    canvas.drawPath(path, paint);
    canvas.drawCircle(Offset(size.width * 0.30, size.height * 0.78), size.width * 0.045, Paint()..color = Colors.white.withValues(alpha: 0.9));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// 统一对话框入口：fade + 轻微 scale 入场（240ms easeOutCubic），替代裸
/// showDialog 的瞬显。全应用对话框一律走这里。
Future<T?> showNonDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  String? barrierLabel,
  Color? barrierColor,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel: barrierLabel ?? 'dialog',
    barrierColor: barrierColor ?? Colors.black.withValues(alpha: 0.55),
    transitionDuration: NonMotion.slow,
    // builder 必须拿路由自己的 context，不能拿推入方的 context：弹窗在场
    // 时推入视图可能已被切走（根级 ⌘1–⌘7 不让位浮层）——调用点的
    // `Navigator.pop(ctx, …)` 与 `ctx.palette` 在死 element 上前者直接
    // TypeError（StatefulElement.state 空断言），路由 context 则始终存活
    // 且同在 MaterialApp 主题树下，行为不变。
    pageBuilder: (routeCtx, __, ___) => builder(routeCtx),
    transitionBuilder: (context, anim, __, child) {
      final curved = CurvedAnimation(parent: anim, curve: NonMotion.curve);
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween(begin: 0.965, end: 1.0).animate(curved),
          child: child,
        ),
      );
    },
  );
}

/// 统一下拉（inspector/settings 全部 DropdownButtonFormField 走这里）：
/// 菜单配色/圆角/最大高度/箭头一处定义，调用方只管 value/items/onChanged/decoration。
DropdownMenu<T> nonSelect<T>(
  BuildContext context, {
  required T? value,
  required List<DropdownMenuItem<T>> items,
  required ValueChanged<T?> onChanged,
  InputDecoration? decoration,
  Widget? hint,
  bool expanded = false,
  bool enabled = true,
}) {
  final p = context.palette;
  // M3 DropdownMenu：菜单行是 MenuItemButton，行高可经 entry style 收敛到
  // 32px——经典 DropdownButton 有运行时断言 itemHeight >= 48（2026-11-14
  // 红屏实证），无法做紧凑菜单。
  final entries = <DropdownMenuEntry<T>>[
    for (final it in items)
      DropdownMenuEntry<T>(
        value: it.value as T,
        label: it.child is Text ? ((it.child as Text).data ?? '') : '',
        style: MenuItemButton.styleFrom(
          // 高度对必须规范化：fromWidth 的隐含高度是 Infinity，
          // 与 maximumSize 高 32 组成 min>max 即崩溃。
          minimumSize: const Size(64, 0),
          maximumSize: const Size.fromHeight(32),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          foregroundColor: p.ink2,
          textStyle: TextStyle(fontSize: 12, color: p.ink2),
        ),
      ),
  ];
  return DropdownMenu<T>(
    initialSelection: value,
    enabled: enabled,
    hintText: decoration?.hintText ?? (hint is Text ? hint.data : null),
    enableFilter: false,
    enableSearch: false,
    trailingIcon: Icon(Icons.expand_more, size: 14, color: p.ink4),
    selectedTrailingIcon: Icon(Icons.expand_more, size: 14, color: p.ink4),
    textStyle: TextStyle(fontSize: 12, color: p.ink2),
    menuStyle: MenuStyle(
      backgroundColor: WidgetStatePropertyAll(p.panel2),
      surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
      elevation: const WidgetStatePropertyAll(14),
      shadowColor: WidgetStatePropertyAll(Colors.black.withValues(alpha: 0.45)),
      shape: WidgetStatePropertyAll(RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: p.line.withValues(alpha: 0.6)),
      )),
      padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 4)),
      maximumSize: const WidgetStatePropertyAll(Size(double.infinity, 300)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: p.panel2,
      contentPadding: decoration?.contentPadding ?? const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      hintStyle: decoration?.hintStyle ?? TextStyle(color: p.ink4, fontSize: 12),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: p.line)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: p.line)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: p.accent.withValues(alpha: 0.7))),
    ),
    dropdownMenuEntries: entries,
    onSelected: onChanged,
  );
}

/// 新建画板菜单（左栏「画板」头与画板页签的 ＋ 共用同一份实现）。
/// 紧凑形态：固定宽 248，模板列表内嵌滚动（面板高 300），单行 30px——
/// 此前两处各自维护 40px 双行 ×20 项，弹层撑满整屏（2026-11-14 截图实证）。
class BoardTemplateMenu extends StatelessWidget {
  final AppStore store;
  final Widget child;
  final Offset offset;
  const BoardTemplateMenu({super.key, required this.store, required this.child, this.offset = const Offset(0, 32)});

  static const double _width = 248;
  static const double _listHeight = 300;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final templates = store.templates.whereType<Map>().take(30).toList();
    return PopupMenuButton<String>(
      tooltip: '新建画板',
      offset: offset,
      color: p.panel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: p.lineStrong)),
      onSelected: (value) {
        if (value == '__blank__') {
          store.createBoard();
        } else if (value.isNotEmpty) {
          store.createBoard(templateId: value, name: value);
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem<String>(
          value: '__blank__',
          height: 34,
          child: SizedBox(
            width: _width,
            child: Row(children: [
              Icon(Icons.crop_square, size: 14, color: p.ink4),
              const SizedBox(width: 8),
              Text('空白画板', style: TextStyle(fontSize: 12, color: p.ink2)),
            ]),
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          value: '',
          height: _listHeight + 8,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          // 单个可滚动面板：模板再多菜单也不撑高；每行点按直接带模板 id 弹回。
          child: SizedBox(
            width: _width - 12,
            height: _listHeight,
            child: ListView.builder(
              padding: EdgeInsets.zero,
              itemCount: templates.length,
              itemBuilder: (context, i) {
                final t = templates[i];
                final id = t['id']?.toString() ?? '';
                return InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: () => Navigator.pop(context, id),
                  child: SizedBox(
                    height: 30,
                    child: Row(
                      children: [
                        Expanded(
                          child: Text((t['name'] ?? id).toString(),
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 12, color: p.ink2)),
                        ),
                        const SizedBox(width: 8),
                        Text(id, style: TextStyle(fontSize: 10, fontFamily: 'Menlo', color: p.ink4)),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
      child: child,
    );
  }
}

class IconAction extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool active;

  /// 视觉尺寸（图标按 0.52 缩放）。
  final double size;

  /// 触控命中区（InkWell 盒子边长）：缺省等于 [size]（桌面紧凑密度不变）。
  /// 触屏（iOS/Android）调用点应传 ≥44 —— HIG / Material 最小触控目标；
  /// 命中区放大不改变图标视觉尺寸。
  final double? hitSize;
  final Color? color;

  const IconAction({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onTap,
    this.active = false,
    this.size = 26,
    this.hitSize,
    this.color,
  });

  @override
  State<IconAction> createState() => _IconActionState();
}

class _IconActionState extends State<IconAction> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final hit = widget.hitSize ?? widget.size;
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: AnimatedContainer(
          duration: NonMotion.fast,
          curve: NonMotion.curve,
          decoration: BoxDecoration(
            color: widget.active
                ? p.accentSoft
                : _hover
                    ? p.line // 与全局 hoverColor 同一令牌强度（theme.dart AppTheme.build）
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: widget.onTap,
            child: SizedBox(
              width: hit,
              height: hit,
              child: Center(
                child: Icon(widget.icon, size: (widget.size * 0.52).roundToDouble(),
                    color: widget.active ? p.accent : (widget.color ?? p.ink3)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class Pill extends StatelessWidget {
  final String label;
  final Color? color;
  final Color? background;
  final IconData? icon;
  const Pill({super.key, required this.label, this.color, this.background, this.icon});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final fg = color ?? p.ink3;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: background ?? p.panel2,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 10, color: fg), const SizedBox(width: 3)],
          Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w500, color: fg)),
        ],
      ),
    );
  }
}

class SectionLabel extends StatelessWidget {
  final String text;
  final Widget? trailing;
  const SectionLabel(this.text, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Row(
      children: [
        Expanded(
          child: Text(
            text.toUpperCase(),
            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1.1, color: p.ink4),
          ),
        ),
        if (trailing != null) trailing!,
      ],
    );
  }
}

class ThinDivider extends StatelessWidget {
  const ThinDivider({super.key});
  @override
  Widget build(BuildContext context) => Divider(height: 1, thickness: 0.5, color: context.palette.line);
}

class EmptyHint extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? detail;
  final Widget? action;
  const EmptyHint({super.key, required this.icon, required this.title, this.detail, this.action});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(color: p.panel2, borderRadius: BorderRadius.circular(12)),
              child: Icon(icon, size: 18, color: p.ink3),
            ),
            const SizedBox(height: 12),
            Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: p.ink)),
            if (detail != null) ...[
              const SizedBox(height: 4),
              Text(detail!, textAlign: TextAlign.center, style: TextStyle(fontSize: 11, height: 1.5, color: p.ink3)),
            ],
            if (action != null) ...[const SizedBox(height: 14), action!],
          ],
        ),
      ),
    );
  }
}

class BoardMiniPainter extends CustomPainter {
  final Artboard board;
  const BoardMiniPainter(this.board);

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / math.max(1, board.width);
    final sy = size.height / math.max(1, board.height);
    final bg = Paint()..color = Colors.white;
    canvas.drawRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(2)), bg);
    for (final node in board.nodes) {
      if (!node.style.visible) continue;
      final rect = Rect.fromLTWH(node.x * sx, node.y * sy, math.max(0.6, node.w * sx), math.max(0.6, node.h * sy));
      final fill = parseHex(node.style.fill, fallback: const Color(0xFFE5E7EB));
      final color = fill == Colors.transparent ? const Color(0xFFE5E7EB) : fill;
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(math.min(rect.shortestSide / 2, node.style.radius * sx))),
        Paint()..color = color.withValues(alpha: node.style.opacity.clamp(0.1, 1)),
      );
    }
  }

  @override
  bool shouldRepaint(covariant BoardMiniPainter old) => old.board != board;
}
