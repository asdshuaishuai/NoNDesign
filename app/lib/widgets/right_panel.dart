import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart' show ScrollDirection; // Agent 面板手势门用
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:provider/provider.dart';

import '../core/dart_agent.dart' show toolLabel;
import '../core/models.dart';
import '../core/keys.dart';
import '../core/store.dart';
import '../core/theme.dart';
import 'a2ui_card.dart';
import 'common.dart';
import 'markdown_theme.dart';

part 'agent_panel.dart';
part 'inspector_panel.dart';

class RightPanel extends StatelessWidget {
  /// 检查 tab 的正文；缺省是设计检查器（单独使用时行为不变）。
  ///
  /// `Workspace` 通过 [WorkspaceRightPanel]（`workspace_inspector.dart`）传入
  /// 按工作区分派的检查器——设计画板 / 3D / 视频 / 热应用各看各的。
  final Widget? inspectBody;

  /// 检查 tab 的文案/图标（随工作区变；tab id 仍是 `inspect`，持久化值不变）。
  final String inspectLabel;
  final IconData inspectIcon;

  const RightPanel({
    super.key,
    this.inspectBody,
    this.inspectLabel = '检查',
    this.inspectIcon = Icons.center_focus_strong_outlined,
  });

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final p = context.palette;
    return Container(
      width: 348,
      decoration: BoxDecoration(
        color: p.bgElevated.withValues(alpha: 0.82),
        border: Border(left: BorderSide(color: p.line)),
      ),
      child: Column(
        children: [
          Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: NonSpace.sm),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: p.line))),
            child: Row(
              children: [
                _tab(context, 'agent', Icons.auto_awesome, 'NaN'),
                _tab(context, 'inspect', inspectIcon, inspectLabel),
                const Spacer(),
                if (store.usage['totalTokens'] != null)
                  Pill(
                    label:
                        '上下文 ${formatTokens((store.usage['totalTokens'] as num?) ?? 0)}${_cacheRate(store) > 0 ? ' · ⚡${(_cacheRate(store) * 100).round()}%' : ''}',
                    color: _cacheRate(store) >= 0.5 ? p.success : p.ink4,
                  ),
              ],
            ),
          ),
          Expanded(
            child: store.rightTab == 'agent'
                ? const AgentPanel()
                : (inspectBody ?? const Inspector()),
          ),
        ],
      ),
    );
  }

  double _cacheRate(AppStore store) {
    final input = (store.usage['inputTokens'] as num?)?.toDouble() ?? 0;
    final cached = (store.usage['cachedTokens'] as num?)?.toDouble() ?? 0;
    return input <= 0 ? 0 : (cached / input).clamp(0, 1);
  }

  Widget _tab(BuildContext context, String id, IconData icon, String label) {
    final store = context.read<AppStore>();
    final p = context.palette;
    final active = store.rightTab == id;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => store.setRightTab(id),
      child: Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 9),
        decoration: BoxDecoration(
          color: active ? p.panel2 : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(icon, size: 12, color: active ? p.accent : p.ink4),
            const SizedBox(width: 5),
            Text(label,
                style: TextStyle(
                    fontSize: NonType.body,
                    fontWeight: FontWeight.w600,
                    color: active ? p.ink : p.ink3)),
          ],
        ),
      ),
    );
  }
}
