import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection; // Agent 面板手势门用
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:provider/provider.dart';

import '../core/models.dart';
import '../core/keys.dart';
import '../core/store.dart';
import '../core/theme.dart';
import 'common.dart';

part 'agent_panel.dart';
part 'inspector_panel.dart';

class RightPanel extends StatelessWidget {
  const RightPanel({super.key});

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
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: p.line))),
            child: Row(
              children: [
                _tab(context, 'agent', Icons.auto_awesome, 'NoN'),
                _tab(context, 'inspect', Icons.center_focus_strong_outlined, '检查'),
                const Spacer(),
                if (store.usage['totalTokens'] != null)
                  Pill(
                    label:
                        '${formatTokens((store.usage['totalTokens'] as num?) ?? 0)} tok${_cacheRate(store) > 0 ? ' · ⚡${(_cacheRate(store) * 100).round()}%' : ''}',
                    color: _cacheRate(store) >= 0.5 ? p.success : p.ink4,
                  ),
              ],
            ),
          ),
          Expanded(
            child: store.rightTab == 'agent' ? const AgentPanel() : const Inspector(),
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
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: active ? p.ink : p.ink3)),
          ],
        ),
      ),
    );
  }
}
