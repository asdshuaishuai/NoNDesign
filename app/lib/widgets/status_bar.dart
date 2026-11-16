import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/store.dart';
import '../core/theme.dart';
import 'common.dart';

class StatusBar extends StatelessWidget {
  final VoidCallback onCommand;
  const StatusBar({super.key, required this.onCommand});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final p = context.palette;
    // 手机没有键盘：⌘K 命令面板提示不显示（命中区仍在，可点）。
    final narrow = MediaQuery.sizeOf(context).width < 700;
    final input = (store.usage['inputTokens'] as num?)?.toDouble() ?? 0;
    final cached = (store.usage['cachedTokens'] as num?)?.toDouble() ?? 0;
    final cacheRate = input > 0 ? (cached / input * 100).round() : 0;
    final nodes = store.render.artboards.fold<int>(0, (n, b) => n + b.nodes.length);
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
          const SizedBox(width: 12),
          Text('rev ${store.render.revision}', style: TextStyle(fontSize: 10, fontFamily: 'Menlo', color: p.ink4)),
          const SizedBox(width: 10),
          Text('${store.render.artboards.length} 板 / $nodes 节点',
              style: TextStyle(fontSize: 10, color: p.ink4)),
          const Spacer(),
          if (store.agentBusy)
            Row(
              children: [
                SizedBox(width: 9, height: 9, child: CircularProgressIndicator(strokeWidth: 1.3, color: p.accent)),
                const SizedBox(width: 5),
                Text(
                  store.agentPhase == 'planning'
                      ? 'NoN 正在撰写文档'
                      : store.agentPhase == 'building'
                          ? 'NoN 正在构建原型'
                          : store.agentPhase == 'refining'
                              ? 'NoN 正在调整'
                              : '正在停止…',
                  style: TextStyle(fontSize: 10, color: p.accent),
                ),
              ],
            )
          else
            Text('就绪', style: TextStyle(fontSize: 10, color: p.ink4)),
          const SizedBox(width: 14),
          if ((store.usage['totalTokens'] as num? ?? 0) > 0) ...[
            Text('ctx ${formatTokens(store.usage['totalTokens'] as num?)}',
                style: TextStyle(fontSize: 10, fontFamily: 'Menlo', color: p.ink4)),
            if (cacheRate > 0) ...[
              const SizedBox(width: 4),
              Text('⚡$cacheRate%', style: TextStyle(fontSize: 10, fontFamily: 'Menlo', color: cacheRate >= 50 ? p.success : p.warn)),
            ],
            const SizedBox(width: 10),
          ],
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
}
