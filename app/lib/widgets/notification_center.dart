/// 通知中心：通知历史（可回看、可重放）的呈现面板。
///
/// 入口（批次 12 接状态栏铃铛、批次 13 接命令面板）：[showNotificationCenter]
/// 弹出一张浮层；面板本身是普通 widget，测试可直接挂载。
///
/// 历史规则由 [ToastService] 决定：最近 100 条、连续相同只留一条并计数、
/// 敏感内容在入库前已脱敏。本文件只负责呈现与「点按重放」。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../core/toast_service.dart';
import 'common.dart';

/// 通知历史面板（标题 + 计数 + 清空/关闭 + 列表 + 空态）。
class NotificationCenter extends StatelessWidget {
  final ToastService? service;
  final VoidCallback? onClose;
  final double width;
  final double maxHeight;

  const NotificationCenter({
    super.key,
    this.service,
    this.onClose,
    this.width = 360,
    this.maxHeight = 420,
  });

  @override
  Widget build(BuildContext context) {
    final svc = service ?? ToastService.instance;
    final p = context.palette;
    final screenWidth = MediaQuery.maybeOf(context)?.size.width ?? width + 32;
    final panelWidth = math.min(width, math.max(240.0, screenWidth - 32));
    return AnimatedBuilder(
      animation: svc,
      builder: (context, _) {
        final history = svc.history;
        return Material(
          // 透明 Material 只提供 ink 画布：面板可能挂在对话框路由上（没有 Scaffold）。
          type: MaterialType.transparency,
          child: Container(
            width: panelWidth,
            constraints: BoxConstraints(maxHeight: maxHeight),
            decoration: BoxDecoration(
              color: p.panel,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: p.lineStrong),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.4),
                  blurRadius: 28,
                  offset: const Offset(0, 14),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _Header(count: history.length, onClear: svc.clearHistory, onClose: onClose),
                if (history.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 26),
                    child: EmptyHint(
                      icon: Icons.notifications_none,
                      title: '还没有通知',
                      detail: '操作结果会出现在这里',
                    ),
                  )
                else
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      itemCount: history.length,
                      separatorBuilder: (_, _) => Divider(height: 1, thickness: 0.5, color: p.line),
                      itemBuilder: (context, i) {
                        final item = history[i];
                        return _HistoryRow(item: item, onTap: () => svc.replay(item));
                      },
                    ),
                  ),
                _Footer(maxHistory: svc.maxHistory),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  final int count;
  final VoidCallback onClear;
  final VoidCallback? onClose;

  const _Header({required this.count, required this.onClear, this.onClose});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 6),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: p.line))),
      child: Row(
        children: [
          Icon(Icons.notifications_none, size: 14, color: p.ink3),
          const SizedBox(width: 6),
          Text('通知', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: p.ink)),
          const SizedBox(width: 6),
          if (count > 0) Pill(label: '$count', color: p.ink3, background: p.panel2),
          const Spacer(),
          TextButton(
            onPressed: count > 0 ? onClear : null,
            child: const Text('清空'),
          ),
          if (onClose != null)
            TextButton(
              onPressed: onClose,
              child: const Text('关闭'),
            ),
        ],
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  final int maxHistory;

  const _Footer({required this.maxHistory});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: p.line))),
      child: Text(
        '最多保留 $maxHistory 条 · 点按可再次提醒',
        style: TextStyle(fontSize: 10, color: p.ink4),
      ),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  final ToastItem item;
  final VoidCallback onTap;

  const _HistoryRow({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final levelColor = switch (item.level) {
      ToastLevel.info => p.accent,
      ToastLevel.success => p.success,
      ToastLevel.warn => p.warn,
      ToastLevel.error => p.danger,
    };
    final levelIcon = switch (item.level) {
      ToastLevel.info => Icons.info_outline,
      ToastLevel.success => Icons.check_circle_outline,
      ToastLevel.warn => Icons.warning_amber_rounded,
      ToastLevel.error => Icons.error_outline,
    };
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(levelIcon, size: 13, color: levelColor),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: p.ink),
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
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(formatTime(item.createdAt), style: TextStyle(fontSize: 10, color: p.ink4)),
                if (item.repeatCount > 1)
                  Text('×${item.repeatCount}', style: TextStyle(fontSize: 10, color: p.ink4)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 弹出通知中心（统一对话框动效，全应用一处入口）。
Future<void> showNotificationCenter(BuildContext context, {ToastService? service}) {
  final svc = service ?? ToastService.instance;
  return showNonDialog<void>(
    context: context,
    barrierLabel: '通知',
    // 面板宽度自己按屏宽收窄（-32），外层只留垂直呼吸位，窄屏不会二次挤压。
    builder: (routeCtx) => SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: NotificationCenter(
            service: svc,
            onClose: () => Navigator.of(routeCtx).pop(),
          ),
        ),
      ),
    ),
  );
}
