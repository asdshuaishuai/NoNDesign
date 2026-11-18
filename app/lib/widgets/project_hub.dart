import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/store.dart';
import '../core/theme.dart';

/// 项目中性主面：四个独立模块的入口，不是任何单一模块的工作面。
///
/// 架构裁决（用户 2026-11-18）：设计 / 热应用 / 3D / 视频是相互独立的模块，
/// NaN（chat agent）可以控制每个模块；唯一的关联是设计 → 热应用
/// （可以从设计生成热应用）。因此项目打开/新建后**不默认落在设计画布**，
/// 而是落在这里，由用户选择进入哪个模块。
class ProjectHubView extends StatelessWidget {
  const ProjectHubView({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final p = context.palette;
    final entries = <(String, IconData, String, VoidCallback)>[
      (
        '设计',
        Icons.design_services_outlined,
        '文档 · 画布 · 原型（可生成热应用）',
        () => store.setView('design'),
      ),
      (
        'NaN 热应用',
        Icons.auto_fix_high_outlined,
        '带本地数据库的可运行小应用',
        () => store.setView('plugin:hotapp'),
      ),
      (
        '3D 工作台',
        Icons.view_in_ar_outlined,
        '场景 · 交互 · 实时预览',
        () => store.setView('plugin:three'),
      ),
      (
        '视频工作台',
        Icons.movie_outlined,
        '代码生成视频 · 对照检查',
        () => store.setView('plugin:video'),
      ),
    ];
    return ColoredBox(
      color: p.bg,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  store.projectName.isEmpty ? '这个项目' : store.projectName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 22, fontWeight: FontWeight.w700, color: p.ink),
                ),
                const SizedBox(height: 6),
                Text(
                  '选择一个模块开始；右侧 NaN 可以替你操作任何一个模块。',
                  style: TextStyle(fontSize: 12.5, color: p.ink3),
                ),
                const SizedBox(height: 18),
                for (final (title, icon, sub, onTap) in entries) ...[
                  _HubCard(
                      title: title, icon: icon, sub: sub, onTap: onTap, p: p),
                  const SizedBox(height: 10),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HubCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final String sub;
  final VoidCallback onTap;
  final NonPalette p;

  const _HubCard({
    required this.title,
    required this.icon,
    required this.sub,
    required this.onTap,
    required this.p,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: p.panel,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        key: ValueKey('hub-module-$title'),
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: p.line),
          ),
          child: Row(
            children: [
              Icon(icon, size: 20, color: p.accent),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: p.ink)),
                    const SizedBox(height: 2),
                    Text(sub,
                        style: TextStyle(fontSize: 11, color: p.ink3)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, size: 18, color: p.ink4),
            ],
          ),
        ),
      ),
    );
  }
}
