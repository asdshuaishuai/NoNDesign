// 应用包的只读查看器（renderer=a2ui 分支）。
//
// 渲染走 [A2uiCard.messages]（静态路径：surface 消息 JSON 直灌 MessageProcessor）
// ——与聊天流的交互卡同一条渲染路径，不新增 store.view 路由（Navigator.push）。
// **零网络依赖**：纯离线也能渲染。
//
// 动作回流（点按钮 → 续跑智能体）本批**不做**：只把动作名与上下文以通知
// 明示，注释留作后续接线点（需要智能体运行时 + 数据模型往返）。
// openUrl 显式传 null = 禁用外链（不可信输入）。
//
// 文案纪律：用户可见文字不出现协议名/组件名；渲染器抛出的原始诊断只放在
// 折叠的「技术详情」里，默认不展开。
import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import '../core/nonapp_package.dart';
import '../core/theme.dart';
import '../core/toast_service.dart';
import 'a2ui_card.dart';

class NonAppA2uiViewer extends StatelessWidget {
  const NonAppA2uiViewer({super.key, required this.title, required this.messages});

  final String title;

  /// 归一为数组的消息序列（createSurface / updateComponents …）。
  final List<Object?> messages;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    // StatelessWidget 里的可变错误位：widget 实例级 Notifier（无需 dispose，
    // 且 onError 回调需要把它推到 UI）。
    final error = ValueNotifier<_ViewerError?>(null);
    // 防卫纵深：包解析已跑过同一道门；直接构造（测试/未来调用方）也拦。
    // 渲染器会把结构错当渲染期异常抛出（炸整页），这里先降级成红条。
    _ViewerError? gateError;
    try {
      assertSurfaceRenderable(messages);
    } on NonAppException catch (e) {
      gateError = _ViewerError('这个应用的内容不受支持', e.code);
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
                '本地预览',
                style: TextStyle(fontSize: 11, color: p.ink4),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          if (gateError != null)
            _ErrorBanner(error: gateError)
          else
            ValueListenableBuilder<_ViewerError?>(
              valueListenable: error,
              builder: (ctx, value, _) {
                if (value == null) return const SizedBox.shrink();
                return _ErrorBanner(error: value, onDismiss: () => error.value = null);
              },
            ),
          Expanded(
            child: gateError != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        '这个应用暂时无法在本机显示。',
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
                          // 不可信输入：外链一律禁用（不传即禁用）；媒体组件
                          // 也切到只认 data: 的本地渲染，不发起任何请求。
                          openUrl: null,
                          offlineOnly: true,
                          onAction: (action) =>
                              _showAction(context, action.name, action.context),
                          onOutbound: (message) =>
                              _showAction(context, '当次操作', {'message': '$message'}),
                          onError: (e) => error.value =
                              _ViewerError('预览出错了，可以返回后重新打开', '$e'),
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  /// 动作回流占位：通知里显示动作名与上下文（续跑留后续）。
  void _showAction(BuildContext context, String name, Map<String, dynamic> contextData) {
    String payload;
    try {
      payload = jsonEncode(contextData);
    } catch (_) {
      payload = '$contextData';
    }
    if (payload.length > 120) payload = '${payload.substring(0, 120)}…';
    ToastScope.of(context).info('收到一个操作：$name', payload);
  }
}

/// 查看器内的错误快照：一句人话 + 原始诊断（只进折叠详情）。
class _ViewerError {
  const _ViewerError(this.message, this.detail);

  final String message;
  final String detail;
}

/// 顶部错误条（内容不受支持 / 预览出错）。
class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.error, this.onDismiss});

  final _ViewerError error;

  /// null = 不可关闭（结构门错误不是一次运行错误，关掉也没意义）。
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      width: double.infinity,
      color: p.danger.withValues(alpha: 0.12),
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 2),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.error_outline, size: 15, color: p.danger),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              error.message,
              maxLines: 2,
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
        if (error.detail.trim().isNotEmpty)
          // 折叠详情里的 ExpansionTile 内部是 ListTile：Flutter 3.50 起
          // ListTile 在「与最近 Material 之间夹着带色 ColoredBox/DecoratedBox」
          // 时报 FlutterError（背景与涟漪不可见）。外层 Container 的 danger 底色
          // 正是那个 ColoredBox；补一层透明 Material 把 ListTile 的绘制锚点
          // 拉回来（three_workspace 的 _TechDetails 同法）。
          Material(
            type: MaterialType.transparency,
            child: Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: const EdgeInsets.symmetric(horizontal: 20),
                childrenPadding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                dense: true,
                title: Text('技术详情',
                    style: TextStyle(fontSize: 11, color: p.ink4)),
                iconColor: p.ink4,
                collapsedIconColor: p.ink4,
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: SelectableText(
                      error.detail,
                      style: TextStyle(fontSize: 10.5, color: p.ink4, height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ]),
    );
  }
}
