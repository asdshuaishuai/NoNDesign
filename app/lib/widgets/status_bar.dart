import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../core/store.dart';
import '../core/theme.dart';

/// 底部状态栏：`版本 N · X 画板 · Y 节点 · 模型名 · 上下文 42%`。
///
/// 文案纪律（docs/copy-glossary.md §5）：不出现 rev/ctx/board/node 这类内部
/// 缩写，也不出现内部运行时代号；上下文百分比用当前模型的窗口做分母。
class StatusBar extends StatelessWidget {
  final VoidCallback onCommand;
  const StatusBar({super.key, required this.onCommand});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final p = context.palette;
    // 手机没有键盘：命令面板快捷键提示不显示（命中区仍在，可点）。
    final narrow = MediaQuery.sizeOf(context).width < 700;
    final boards = store.render.artboards.length;
    final nodes = store.render.artboards.fold<int>(0, (n, b) => n + b.nodes.length);
    final version = store.render.revision;
    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: p.bgElevated.withValues(alpha: 0.92),
        border: Border(top: BorderSide(color: p.line)),
      ),
      child: Row(
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: store.dirty ? p.warn : p.success,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              store.projectPath == null ? '未保存项目' : (store.projectPath!.split(RegExp(r'[\\/]')).last),
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10, color: p.ink3),
            ),
          ),
          if (store.dirty) ...[
            const SizedBox(width: 5),
            Text('未保存', style: TextStyle(fontSize: 10, color: p.warn)),
          ],
          if (!narrow) ...[
            const SizedBox(width: 12),
            Text(
              '版本 $version · $boards 画板 · $nodes 节点',
              key: const ValueKey('status-summary'),
              style: TextStyle(fontSize: 10, color: p.ink4),
            ),
          ],
          const Spacer(),
          if (store.agentBusy)
            Row(
              children: [
                SizedBox(width: 9, height: 9, child: CircularProgressIndicator(strokeWidth: 1.3, color: p.accent)),
                const SizedBox(width: 5),
                Text(
                  store.agentPhase == 'planning'
                      ? 'NaN 正在撰写文档'
                      : store.agentPhase == 'building'
                          ? 'NaN 正在构建原型'
                          : store.agentPhase == 'refining'
                              ? 'NaN 正在调整'
                              : '正在停止…',
                  style: TextStyle(fontSize: 10, color: p.accent),
                ),
              ],
            )
          else
            Text('就绪', style: TextStyle(fontSize: 10, color: p.ink4)),
          const SizedBox(width: 12),
          Text(
            _contextLabel(store),
            key: const ValueKey('status-context'),
            style: TextStyle(fontSize: 10, color: p.ink4),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(store.model?.name ?? '未选择模型',
                overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 10, color: p.ink4)),
          ),
          const SizedBox(width: 10),
          if (!narrow)
            InkWell(
              onTap: onCommand,
              child: Row(
                children: [
                  Icon(Icons.keyboard_command_key, size: 10, color: p.ink4),
                  const SizedBox(width: 2),
                  Text('K', style: TextStyle(fontSize: 10, fontFamily: 'Menlo', color: p.ink4)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// 上下文用量：`上下文 42%`；模型窗口未知时诚实显示 `上下文 —`。
  String _contextLabel(AppStore store) {
    final window = store.model?.context ?? 0;
    final used = (store.usage['totalTokens'] as num?)?.toDouble() ?? 0;
    if (window <= 0) return '上下文 —';
    final percent = (used / window * 100).round().clamp(0, 100);
    return '上下文 $percent%';
  }
}
