/// 聊天流内嵌的**工作区实况预览卡**（genUI 形态，移动适配 2026-11-19）。
///
/// 裁决：chat agent 跑起来后，实况预览**直接长在聊天流的框里**——不是画中画
/// 浮窗。出现条件：`agentBusy && previewRender != null`（首轮实况帧就绪）；
/// 运行结束自动消失（终稿回落画布与产物卡）。
///
/// 卡体内嵌的就是桌面同一个 [Workspace]（embedded 模式，底层完全一致）：
/// 实况数据源同一条 preview 管线（preview 事件 → 700ms 合帧 → 信封重渲染），
/// 画布手势在卡内可用（卡片不在聊天 ListView 里，无嵌套滚动冲突）。
/// 折叠态只留标题行，让用户回聊天记录。
library;

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../core/store.dart';
import '../core/theme.dart';
import 'workspace.dart';

class ChatLivePreviewCard extends StatefulWidget {
  const ChatLivePreviewCard({super.key});

  @override
  State<ChatLivePreviewCard> createState() => _ChatLivePreviewCardState();
}

class _ChatLivePreviewCardState extends State<ChatLivePreviewCard> {
  bool _collapsed = false;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final p = context.palette;
    final frames = store.previewRender?.artboards.length ?? 0;
    
    return Container(
      key: const ValueKey('chat-live-preview'),
      margin: const EdgeInsets.fromLTRB(NonSpace.md, NonSpace.sm, NonSpace.md, NonSpace.xs),
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: p.accent.withValues(alpha: 0.45), width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: () => setState(() => _collapsed = !_collapsed),
            child: Container(
              height: 38,
              padding: const EdgeInsets.symmetric(horizontal: NonSpace.md),
              child: Row(
                children: [
                  _PulseDot(color: p.accent),
                  const SizedBox(width: NonSpace.sm),
                  Expanded(
                    child: Text(
                      '实况预览 · 正在构建工作区',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: NonType.body,
                          fontWeight: FontWeight.w600,
                          color: p.ink),
                    ),
                  ),
                  Text(
                    '$frames 屏',
                    style: TextStyle(fontSize: NonType.caption, color: p.ink3),
                  ),
                  const SizedBox(width: 6),
                  Icon(
                    _collapsed
                        ? Icons.keyboard_arrow_down
                        : Icons.keyboard_arrow_up,
                    size: 18,
                    color: p.ink3,
                  ),
                ],
              ),
            ),
          ),
          if (!_collapsed)
            Container(
              height: 300,
              margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: p.line),
                color: p.canvas,
              ),
              clipBehavior: Clip.antiAlias,
              // 底层完全一致：内嵌桌面同一个 Workspace（embedded 模式），
              // 实况数据同一条 preview 管线，画布手势在卡内可用。
              child: const Workspace(embedded: true),
            ),
        ],
      ),
    );
  }
}

/// 构建中的呼吸圆点（实况徽标）。
class _PulseDot extends StatefulWidget {
  const _PulseDot({required this.color});

  final Color color;

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 900))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 0.35, end: 1).animate(
          CurvedAnimation(parent: _c, curve: Curves.easeInOut)),
      child: Container(
        width: 8,
        height: 8,
        decoration:
            BoxDecoration(color: widget.color, shape: BoxShape.circle),
      ),
    );
  }
}
