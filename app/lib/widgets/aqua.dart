// Aqua 组件层（早期 Mac OS X 设计语言的 Flutter 移植）。
//
// 定位：**浅色主题即 Aqua**（用户裁决 2026-11-26，不新增第三套主题）。
// 材质语言要点（与「通用毛玻璃 glassmorphism」明确区分）：
//  * 窗口底是**细条纹**（pinstripe）浅灰面，不是模糊半透明；
//  * 主按钮是**糖果凝胶**：不透明的水蓝渐变 + 上半球高光 + 内发光 + 细边线；
//  * 标题栏左侧是红/黄/绿**口香糖球**窗口控件；
//  * 默认按钮有缓慢呼吸光晕（`MediaQuery.disableAnimationsOf` 为真时完全静止）；
//  * 深色软阴影给窗口/浮层。
//
// 约束：凝胶上的文字用白色并带轻微投影（period-correct），白字压在最深的
// 凝胶色上仍需 ≥4.5:1 对比度；键盘焦点必须有可见环；所有动画走 NonMotion 或
// 这里声明的时长，不散落裸 Duration。
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';

/// 当前主题是否走 Aqua 语言（浅色 = Aqua）。
bool isAquaTheme(BuildContext context) =>
    Theme.of(context).brightness == Brightness.light;

/// 细条纹窗口底：1px 低对比横纹，静态（无动画、无模糊）。
///
/// 用 [RepaintBoundary] 包裹，避免父级每帧重绘把条纹一起重画。
class AquaPinstripes extends StatelessWidget {
  const AquaPinstripes({
    super.key,
    required this.child,
    this.stripeColor = const Color(0x0D0F172A),
    this.spacing = 4,
    this.padding = EdgeInsets.zero,
  });

  final Widget child;
  final Color stripeColor;
  final double spacing;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: _PinstripePainter(color: stripeColor, spacing: spacing),
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

class _PinstripePainter extends CustomPainter {
  const _PinstripePainter({required this.color, required this.spacing});

  final Color color;
  final double spacing;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()..color = color;
    // 每 4px 一根 1px 亮纹；条纹只覆盖可视区，不做整幅 shader。
    for (double y = 0; y < size.height; y += spacing) {
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, 1), paint);
    }
  }

  @override
  bool shouldRepaint(_PinstripePainter old) =>
      old.color != color || old.spacing != spacing;
}

/// 糖果凝胶表面（不带文字）：底部线性渐变 + 上半球径向高光 + 内发光 + 细边线。
///
/// 供按钮/徽章/选中态胶囊复用；[radius] 走 [NonRadius] 刻度。
class AquaGelSurface extends StatelessWidget {
  const AquaGelSurface({
    super.key,
    required this.child,
    this.radius = NonRadius.md,
    this.opacity = 1.0,
    this.borderColor,
    this.padding = EdgeInsets.zero,
  });

  final Widget child;
  final double radius;
  final double opacity;
  final Color? borderColor;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final BorderRadius r = BorderRadius.circular(radius);
    return Opacity(
      opacity: opacity,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: r,
          gradient: const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[NonPalette.aquaGelTop, NonPalette.aquaGelBottom],
          ),
          border: Border.all(
            color: borderColor ?? const Color(0x66FFFFFF),
            width: 1,
          ),
          boxShadow: const <BoxShadow>[
            // 外投影 + 上缘 1px 高光切线。
            BoxShadow(
              color: Color(0x33123B7A),
              blurRadius: 6,
              offset: Offset(0, 2),
            ),
            BoxShadow(
              color: Color(0x40FFFFFF),
              blurRadius: 1,
              offset: Offset(0, -1),
            ),
          ],
        ),
        child: ClipRRect(
          // 布尔裁剪用 RRect（GTK/WebView 宿主也能表示；见 AGENTS 裁剪纪律）。
          borderRadius: r,
          child: Stack(
            children: <Widget>[
              // 上半球高光：radial 渐变，覆盖顶部 ~55%。
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                height: 0.55,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: const Alignment(0, -0.7),
                      radius: 1.1,
                      colors: <Color>[
                        NonPalette.aquaGelHighlight,
                        NonPalette.aquaGelHighlight.withValues(alpha: 0),
                      ],
                    ),
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
              Padding(padding: padding, child: child),
            ],
          ),
        ),
      ),
    );
  }
}

/// 糖果凝胶主按钮（Aqua 的"默认按钮"）。
///
/// * 白字 + 轻微投影（凝胶上 period-correct 且保证对比度）；
/// * 键盘焦点：外圈 2px 亮环（`Focus` 驱动，不需要鼠标）；
/// * [pulse] 打开时缓慢呼吸光晕，`disableAnimations` 下静态；
/// * 禁用态降低不透明度并去掉投影，仍保留可读文字。
class AquaGelButton extends StatefulWidget {
  const AquaGelButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.pulse = false,
    this.dense = false,
    this.focusNode,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool pulse;
  final bool dense;
  final FocusNode? focusNode;

  @override
  State<AquaGelButton> createState() => _AquaGelButtonState();
}

class _AquaGelButtonState extends State<AquaGelButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _glow = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );
  bool _focused = false;
  bool _pressed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncPulse();
  }

  @override
  void didUpdateWidget(AquaGelButton old) {
    super.didUpdateWidget(old);
    _syncPulse();
  }

  void _syncPulse() {
    final bool animate =
        widget.pulse &&
        widget.onPressed != null &&
        !MediaQuery.disableAnimationsOf(context);
    if (animate && !_glow.isAnimating) {
      _glow.repeat(reverse: true);
    } else if (!animate && _glow.isAnimating) {
      _glow.stop();
      _glow.value = 0;
    }
  }

  @override
  void dispose() {
    _glow.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool enabled = widget.onPressed != null;
    final double height = widget.dense ? 26 : 30;
    final Widget content = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (widget.icon != null) ...<Widget>[
          Icon(widget.icon, size: NonType.body, color: Colors.white),
          const SizedBox(width: NonSpace.xs),
        ],
        Text(
          widget.label,
          style:
              NonType.of(
                NonType.bodyStrong,
                color: Colors.white,
                weight: FontWeight.w600,
              ).copyWith(
                // 白字压在凝胶上，period-correct 的轻微下投影提升可读性。
                shadows: const <Shadow>[
                  Shadow(
                    color: Color(0x59001847),
                    blurRadius: 1,
                    offset: Offset(0, 1),
                  ),
                ],
              ),
        ),
      ],
    );

    final Widget body = AnimatedBuilder(
      animation: _glow,
      builder: (BuildContext context, Widget? _) {
        final double extraGlow = widget.pulse ? _glow.value * 10 : 0;
        return AquaGelSurface(
          radius: NonRadius.md,
          opacity: enabled ? (_pressed ? 0.86 : 1.0) : 0.42,
          padding: EdgeInsets.symmetric(
            horizontal: widget.dense ? NonSpace.md : NonSpace.lg,
          ),
          child: SizedBox(
            height: height,
            child: Center(child: content),
          ),
        ).withGlow(extraGlow);
      },
    );

    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.label,
      child: Focus(
        focusNode: widget.focusNode,
        onFocusChange: (bool v) => setState(() => _focused = v),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
          onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
          onTap: enabled
              ? () {
                  setState(() => _pressed = false);
                  widget.onPressed!();
                }
              : null,
          child: Container(
            decoration: _focused
                ? BoxDecoration(
                    borderRadius: BorderRadius.circular(NonRadius.lg),
                    boxShadow: const <BoxShadow>[
                      BoxShadow(
                        color: Color(0xCC1862D8),
                        blurRadius: 0,
                        spreadRadius: 2,
                      ),
                    ],
                  )
                : null,
            padding: const EdgeInsets.all(NonSpace.xxs),
            child: body,
          ),
        ),
      ),
    );
  }
}

/// 给凝胶面追加"呼吸光晕"（不改变渐变本身，只在外部加一圈柔光）。
extension _AquaGlowX on Widget {
  Widget withGlow(double intensity) {
    if (intensity <= 0) return this;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(NonRadius.lg),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: const Color(0x661862D8),
            blurRadius: intensity,
            spreadRadius: 1,
          ),
        ],
      ),
      child: this,
    );
  }
}

/// 标题栏左侧的「口香糖」窗口控件（红/黄/绿玻璃球）。
///
/// 纯装饰 + 可选回调；尺寸 12px 球体，间距 8，符合 Aqua 密度。
class AquaGumdrops extends StatelessWidget {
  const AquaGumdrops({
    super.key,
    this.onClose,
    this.onMinimize,
    this.onZoom,
    this.size = 12,
  });

  final VoidCallback? onClose;
  final VoidCallback? onMinimize;
  final VoidCallback? onZoom;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _Gumdrop(
          key: const ValueKey('aqua-gumdrop-close'),
          color: NonPalette.aquaGumdropClose,
          size: size,
          semanticLabel: '关闭',
          onTap: onClose,
        ),
        SizedBox(width: NonSpace.sm),
        _Gumdrop(
          key: const ValueKey('aqua-gumdrop-minimize'),
          color: NonPalette.aquaGumdropMinimize,
          size: size,
          semanticLabel: '最小化',
          onTap: onMinimize,
        ),
        SizedBox(width: NonSpace.sm),
        _Gumdrop(
          key: const ValueKey('aqua-gumdrop-zoom'),
          color: NonPalette.aquaGumdropZoom,
          size: size,
          semanticLabel: '放大',
          onTap: onZoom,
        ),
      ],
    );
  }
}

class _Gumdrop extends StatelessWidget {
  const _Gumdrop({
    super.key,
    required this.color,
    required this.size,
    required this.semanticLabel,
    this.onTap,
  });

  final Color color;
  final double size;
  final String semanticLabel;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          width: size,
          height: size,
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                center: const Alignment(-0.35, -0.5),
                radius: 1.2,
                colors: <Color>[
                  Color.lerp(color, Colors.white, 0.75)!,
                  color,
                  Color.lerp(color, Colors.black, 0.25)!,
                ],
              ),
              border: Border.all(color: const Color(0x40000000), width: 0.5),
              boxShadow: const <BoxShadow>[
                BoxShadow(
                  color: Color(0x33000000),
                  blurRadius: 2,
                  offset: Offset(0, 1),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 用 Aqua 条纹面包装窗口/工作台主区（浅色主题下才需要）。
class AquaWindowSurface extends StatelessWidget {
  const AquaWindowSurface({super.key, required this.child, this.padding});

  final Widget child;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    if (!isAquaTheme(context)) {
      return Padding(padding: padding ?? EdgeInsets.zero, child: child);
    }
    return AquaPinstripes(
      padding: padding ?? const EdgeInsets.all(NonSpace.sm),
      child: child,
    );
  }
}

/// 供测试/文档引用的几何常量（避免魔法数散落）。
abstract final class AquaMetrics {
  /// 窗口控件球直径。
  static const double gumdropSize = 12;

  /// 标题栏高度（浅色 Aqua 下标题栏略高于深色主题的 46）。
  static const double titleBarHeight = 52;

  /// 凝胶按钮常规高度。
  static const double buttonHeight = 30;

  /// 胶囊圆角（非对称：小控件 6/面板 10/大卡 14）。
  static const double maxPanelRadius = NonRadius.lg;

  /// 呼吸光晕周期（2.4s，慢速、低强度，避免分散注意力）。
  static const Duration pulsePeriod = Duration(milliseconds: 2400);

  /// 把 [color] 叠到白色上的相对亮度（测试对比度用）。
  static double relativeLuminance(Color color) {
    double channel(int v) {
      final double c = v / 255.0;
      return c <= 0.03928
          ? c / 12.92
          : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
    }

    return 0.2126 * channel((color.r * 255).round()) +
        0.7152 * channel((color.g * 255).round()) +
        0.0722 * channel((color.b * 255).round());
  }

  /// WCAG 对比度（前景/背景）。
  static double contrastRatio(Color fg, Color bg) {
    final double l1 = relativeLuminance(fg);
    final double l2 = relativeLuminance(bg);
    final double hi = math.max(l1, l2);
    final double lo = math.min(l1, l2);
    return (hi + 0.05) / (lo + 0.05);
  }
}

/// Aqua 分段胶囊页签（四栏目/工作台内切换用）。
///
/// 选中项 = 糖果凝胶（水蓝渐变 + 顶部高光）；未选中 = 白面 + 发丝线。
/// 键盘可达：每个 tab 是 [InkWell] 且带 Semantics；焦点态用 2px 亮环。
class AquaSegmentedTabs extends StatelessWidget {
  const AquaSegmentedTabs({
    super.key,
    required this.labels,
    required this.selectedIndex,
    required this.onSelected,
    this.icons,
    this.itemKeys,
    this.height = 30,
    this.compact = false,
  });

  final List<String> labels;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final List<IconData>? icons;

  /// 每个页签的稳定 Key（可选）。调用方若原本对每个 tab 暴露了 Key
  /// （如 `music-view-staff` / `three-view-front`），必须在这里透传，
  /// 否则浅色（Aqua）分支会比深色分支少一层可测试/可自动化的契约。
  final List<Key>? itemKeys;

  final double height;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final NonPalette p = context.palette;
    final bool aqua = isAquaTheme(context);
    return Semantics(
      container: true,
      label: '栏目切换',
      child: Container(
        height: height,
        padding: const EdgeInsets.all(NonSpace.xxs),
        decoration: BoxDecoration(
          color: aqua ? Colors.white : p.panel2,
          borderRadius: BorderRadius.circular(NonRadius.lg),
          border: Border.all(color: p.line),
          boxShadow: aqua
              ? const <BoxShadow>[
                  BoxShadow(
                    color: Color(0x1A123B7A),
                    blurRadius: 4,
                    offset: Offset(0, 1),
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (int i = 0; i < labels.length; i++)
              KeyedSubtree(
                key: itemKeys != null && i < itemKeys!.length
                    ? itemKeys![i]
                    : null,
                child: _AquaTabButton(
                  label: labels[i],
                  icon: icons != null && i < icons!.length ? icons![i] : null,
                  selected: i == selectedIndex,
                  compact: compact,
                  onTap: () => onSelected(i),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _AquaTabButton extends StatelessWidget {
  const _AquaTabButton({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.compact,
    this.icon,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool compact;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final NonPalette p = context.palette;
    final bool aqua = isAquaTheme(context);
    final Widget body = Padding(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? NonSpace.sm : NonSpace.md,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(
              icon,
              size: NonType.caption,
              color: selected ? Colors.white : p.ink3,
            ),
            const SizedBox(width: NonSpace.xs),
          ],
          Text(
            label,
            style:
                NonType.of(
                  NonType.body,
                  color: selected ? Colors.white : p.ink2,
                  weight: selected ? FontWeight.w600 : FontWeight.w500,
                ).copyWith(
                  shadows: selected
                      ? const <Shadow>[
                          Shadow(
                            color: Color(0x59001847),
                            blurRadius: 1,
                            offset: Offset(0, 1),
                          ),
                        ]
                      : null,
                ),
          ),
        ],
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(right: NonSpace.xxs),
      child: Semantics(
        selected: selected,
        button: true,
        label: label,
        child: InkWell(
          borderRadius: BorderRadius.circular(NonRadius.md),
          onTap: onTap,
          child: selected && aqua
              ? AquaGelSurface(
                  radius: NonRadius.md,
                  padding: EdgeInsets.zero,
                  child: body,
                )
              : Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(NonRadius.md),
                    color: selected ? p.accentSoft : Colors.transparent,
                  ),
                  child: body,
                ),
        ),
      ),
    );
  }
}

/// Aqua 工具条圆钮：白面 + 发丝线 + 柔和内高光；hover/焦点可见，禁用降透明。
///
/// 用于工作台顶部工具条的高频动作（替代裸 `IconButton` 的默认观感）。
class AquaToolIcon extends StatelessWidget {
  const AquaToolIcon({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onTap,
    this.size = 28,
    this.selected = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final double size;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final NonPalette p = context.palette;
    final bool aqua = isAquaTheme(context);
    final bool enabled = onTap != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: tooltip,
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          borderRadius: BorderRadius.circular(size / 2),
          onTap: onTap,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: selected
                  ? (aqua ? null : p.accentSoft)
                  : (aqua ? Colors.white : Colors.transparent),
              gradient: selected && aqua
                  ? const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: <Color>[
                        NonPalette.aquaGelTop,
                        NonPalette.aquaGelBottom,
                      ],
                    )
                  : null,
              border: aqua ? Border.all(color: p.line) : null,
              boxShadow: aqua && enabled
                  ? const <BoxShadow>[
                      BoxShadow(
                        color: Color(0x1A123B7A),
                        blurRadius: 3,
                        offset: Offset(0, 1),
                      ),
                    ]
                  : null,
            ),
            child: Icon(
              icon,
              size: NonType.bodyStrong,
              color: selected
                  ? (aqua ? Colors.white : p.accent)
                  : (enabled ? p.ink2 : p.ink4),
            ),
          ),
        ),
      ),
    );
  }
}

/// Aqua 白面面板：白底 + 发丝线 + 柔和外阴影（浅色主题）/ 现有面板色（深色）。
class AquaPanelSurface extends StatelessWidget {
  const AquaPanelSurface({
    super.key,
    required this.child,
    this.radius = NonRadius.md,
    this.padding = const EdgeInsets.all(NonSpace.md),
  });

  final Widget child;
  final double radius;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final NonPalette p = context.palette;
    final bool aqua = isAquaTheme(context);
    return Container(
      decoration: BoxDecoration(
        color: aqua ? Colors.white : p.panel,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: p.line),
        boxShadow: aqua
            ? const <BoxShadow>[
                BoxShadow(
                  color: Color(0x14123B7A),
                  blurRadius: 8,
                  offset: Offset(0, 2),
                ),
              ]
            : null,
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}
