// a2ui 载荷的只读查看器（`.nonapp` 的 renderer=a2ui 分支）。
//
// 渲染走 [A2uiCard.messages]（静态路径：surface 消息 JSON 直灌 MessageProcessor）
// ——与聊天流的 A2UI 卡同一条渲染路径，不新增 store.view 路由（Navigator.push）。
// **零服务依赖**：纯离线也能渲染（这是 a2ui 相对 html 载荷的离线优势）。
//
// 动作回流（点按钮 → 续跑 agent）本批**不做**：只把动作名与 context 以 SnackBar
// 明示，注释留作后续接线点（需要 agent 运行时 + DataModel 往返，属 S3 后续）。
// openUrl 显式传 null = 禁用外链（官方语义：不可信输入）。
import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/nonapp_package.dart';
import '../core/theme.dart';
import 'a2ui_card.dart';

class NonAppA2uiViewer extends StatelessWidget {
  const NonAppA2uiViewer({super.key, required this.title, required this.messages});

  final String title;

  /// A2UI v1.0 消息序列（已归一为数组：createSurface / updateComponents …）。
  final List<Object?> messages;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    // StatelessWidget 里的可变错误位：widget 实例级 Notifier（无需 dispose，
    // 且 onError 回调需要把它推到 UI —— 用 StatefulWidget 只是为了这一格值）。
    final error = ValueNotifier<String?>(null);
    // 防卫纵深：包解析已跑过同一道门；直接构造（测试/未来调用方）也拦。
    // a2ui 0.3.0 会把结构错当渲染期异常抛出（炸整页），这里先降级成红条。
    String? gateError;
    try {
      assertSurfaceRenderable(messages);
    } on NonAppException catch (e) {
      gateError = '组件错误：${e.message}';
    }
    return Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(
        backgroundColor: p.bgElevated,
        surfaceTintColor: Colors.transparent,
        titleSpacing: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, size: 18),
          tooltip: '返回',
          color: p.ink2,
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: p.ink),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: Text(
                'A2UI · 本地渲染',
                style: TextStyle(fontSize: 11, color: p.ink4),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          if (gateError != null)
            _ErrorBanner(message: gateError)
          else
            ValueListenableBuilder<String?>(
              valueListenable: error,
              builder: (ctx, message, _) {
                if (message == null) return const SizedBox.shrink();
                return _ErrorBanner(message: message, onDismiss: () => error.value = null);
              },
            ),
          Expanded(
            child: gateError != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        '这个 surface 无法在本地渲染（结构不受支持）。',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 12, color: p.ink3),
                      ),
                    ),
                  )
                : SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 720),
                        child: A2uiCard.messages(
                          messages: messages,
                          locale: 'zh-CN',
                          // 不可信输入：外链一律禁用（不传即禁用）。
                          openUrl: null,
                          onAction: (action) => _showAction(context, action.name, action.context),
                          onOutbound: (message) =>
                              _showAction(context, 'outbound', {'message': '$message'}),
                          onError: (e) => error.value = '组件错误：$e',
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  /// 动作回流占位：显示动作名与 context（agent 续跑留后续）。
  void _showAction(BuildContext context, String name, Map<String, dynamic> contextData) {
    String payload;
    try {
      payload = jsonEncode(contextData);
    } catch (_) {
      payload = '$contextData';
    }
    if (payload.length > 180) payload = '${payload.substring(0, 180)}…';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
        '动作 $name（回流续跑待接线）· $payload',
        style: const TextStyle(fontSize: 12),
      ),
    ));
  }
}

/// 顶部错误条（组件错误 / 结构不受支持）。
class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, this.onDismiss});

  final String message;

  /// null = 不可关闭（结构门错误不是一次运行错误，关掉也没意义）。
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      width: double.infinity,
      color: p.danger.withValues(alpha: 0.12),
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      child: Row(children: [
        Icon(Icons.error_outline, size: 15, color: p.danger),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            message,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: p.danger),
          ),
        ),
        if (onDismiss != null)
          IconButton(
            tooltip: '忽略',
            visualDensity: VisualDensity.compact,
            onPressed: onDismiss,
            icon: Icon(Icons.close, size: 14, color: p.ink4),
          ),
      ]),
    );
  }
}
