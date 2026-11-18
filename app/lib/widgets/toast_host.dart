/// 通知宿主：把 [ToastService] 的通知画成「顶部左侧堆叠的圆角胶囊 + 毛玻璃」。
///
/// 挂载点（批次 12 负责接线）：MaterialApp 的 builder 里包住整个路由树——
/// ```dart
/// builder: (context, child) => ToastHost(child: child),
/// ```
/// 这样浮层（对话框、设置、命令面板）之上也能看到通知。
///
/// 宿主**不依赖 Scaffold / ScaffoldMessenger / SnackBar**，也不吃页面上下文：
/// 只要有 Theme（取调色板）与 Directionality 就能渲染，空态时完全不拦截指针。
library;

import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../core/toast_service.dart';

/// 全局通知宿主。
class ToastHost extends StatelessWidget {
  /// 使用的服务；缺省为 [ToastService.instance]（测试请显式传入）。
  final ToastService? service;

  /// 宿主覆盖的内容（通常是整个路由树）。
  final Widget? child;

  /// 相对安全区的边距（左上角起算）。
  final EdgeInsetsGeometry margin;

  /// 胶囊最大宽度。
  final double maxWidth;

  const ToastHost({
    super.key,
    this.service,
    this.child,
    this.margin = const EdgeInsets.fromLTRB(16, 12, 16, 0),
    this.maxWidth = ToastVisuals.maxWidth,
  });

  @override
  Widget build(BuildContext context) {
    final svc = service ?? ToastService.instance;
    return AnimatedBuilder(
      animation: svc,
      builder: (context, _) {
        final toasts = svc.visible;
        return Stack(
          children: [
            ?child,
            Positioned.fill(
              child: IgnorePointer(
                // 没有通知时整层不参与命中测试——画布左上角永远可点。
                ignoring: toasts.isEmpty,
                child: SafeArea(
                  bottom: false,
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: Padding(
                      padding: margin,
                      child: SizedBox(
                        width: maxWidth,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (final toast in toasts)
                              Padding(
                                key: ValueKey<int>(toast.id),
                                padding: const EdgeInsets.only(bottom: 8),
                                child: ToastEntrance(
                                  child: ToastCapsule(
                                    item: toast,
                                    blur: svc.blurEnabled,
                                    onDismiss: () => svc.dismiss(toast.id),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 单条通知胶囊：圆角 + 毛玻璃 + 级别色图标 + 关闭。
///
/// 低端设备降级（[blur] 为 false）时改为不透明实底，其余形态不变。
class ToastCapsule extends StatelessWidget {
  final ToastItem item;
  final bool blur;
  final VoidCallback? onDismiss;

  const ToastCapsule({super.key, required this.item, this.blur = true, this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final levelColor = _levelColor(p);
    final radius = BorderRadius.circular(ToastVisuals.radius);

    final content = Padding(
      padding: const EdgeInsets.fromLTRB(10, 9, 9, 9),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              color: levelColor.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(7),
            ),
            child: Icon(_levelIcon, size: 13, color: levelColor),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: p.ink,
                          height: 1.35,
                        ),
                      ),
                    ),
                    if (item.repeatCount > 1) ...[
                      const SizedBox(width: 6),
                      Text(
                        '×${item.repeatCount}',
                        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: p.ink4),
                      ),
                    ],
                  ],
                ),
                if (item.detail != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    item.detail!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: p.ink3, height: 1.4),
                  ),
                ],
              ],
            ),
          ),
          if (onDismiss != null) ...[
            const SizedBox(width: 6),
            _CloseButton(onTap: onDismiss!),
          ],
        ],
      ),
    );

    final glass = DecoratedBox(
      decoration: BoxDecoration(
        color: blur ? p.panel.withValues(alpha: 0.80) : p.panel2,
        borderRadius: radius,
        border: Border.all(color: levelColor.withValues(alpha: 0.30)),
      ),
      child: content,
    );

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: ToastVisuals.maxWidth),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.32),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: blur
              ? BackdropFilter(
                  filter: ImageFilter.blur(
                    sigmaX: ToastVisuals.blurSigma,
                    sigmaY: ToastVisuals.blurSigma,
                  ),
                  child: glass,
                )
              : glass,
        ),
      ),
    );
  }

  Color _levelColor(NonPalette p) => switch (item.level) {
        ToastLevel.info => p.accent,
        ToastLevel.success => p.success,
        ToastLevel.warn => p.warn,
        ToastLevel.error => p.danger,
      };

  IconData get _levelIcon => switch (item.level) {
        ToastLevel.info => Icons.info_outline,
        ToastLevel.success => Icons.check_circle_outline,
        ToastLevel.warn => Icons.warning_amber_rounded,
        ToastLevel.error => Icons.error_outline,
      };
}

/// 可点关闭的小按钮（不用 InkWell：宿主可能挂在 Material 之外）。
class _CloseButton extends StatelessWidget {
  final VoidCallback onTap;

  const _CloseButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Semantics(
      button: true,
      label: '关闭通知',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: Icon(Icons.close, size: 12, color: p.ink4),
        ),
      ),
    );
  }
}

/// 给胶囊加入场（淡入 + 从上方 6px 落位）；移除不做退场动画，避免堆叠错位。
class ToastEntrance extends StatelessWidget {
  final Widget child;

  const ToastEntrance({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: NonMotion.base,
      curve: NonMotion.curve,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, (1 - t) * -6), child: child),
      ),
      child: child,
    );
  }
}
