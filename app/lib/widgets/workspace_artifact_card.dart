/// 四工作台统一的「结果面」产物卡：标题 + 关键指标 + 主操作按钮，
/// 终态二元（成功/失败卡，与 agent 终态卡同语义）。契约见
/// plan-creative-workbench §2.3。
library;

import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';

/// 产物卡（工作台内，不复制聊天时间线）。
class WorkspaceArtifactCard extends StatelessWidget {
  const WorkspaceArtifactCard({
    super.key,
    required this.title,
    this.summary = '',
    this.ok = true,
    this.metrics = const <String>[],
    this.primaryLabel,
    this.onPrimary,
    this.openLabel,
    this.onOpen,
    this.onDismiss,
    this.detail,
  });

  final String title;
  final String summary;
  final bool ok;

  /// 短指标串（例：`3 屏 · 5 跳转 · 全部覆盖`）。
  final List<String> metrics;
  final String? primaryLabel;
  final VoidCallback? onPrimary;

  /// 第二动作文案（缺省「打开」）。
  final String? openLabel;

  /// 打开产物（跳转/预览）的第二动作。
  final VoidCallback? onOpen;
  final VoidCallback? onDismiss;

  /// 失败时的可展开详情（原始诊断只在这里）。
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      key: const ValueKey('workspace-artifact-card'),
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: ok ? p.line : p.warn.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                ok ? Icons.task_alt : Icons.error_outline,
                size: 16,
                color: ok ? p.success : p.warn,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: NonType.bodyStrong,
                    fontWeight: FontWeight.w700,
                    color: p.ink,
                  ),
                ),
              ),
              if (onDismiss != null)
                IconButton(
                  key: const ValueKey('workspace-artifact-dismiss'),
                  onPressed: onDismiss,
                  icon: Icon(Icons.close, size: 15, color: p.ink4),
                  tooltip: '收起',
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
          if (summary.trim().isNotEmpty) ...<Widget>[
            const SizedBox(height: NonSpace.xs),
            Text(
              summary,
              style: TextStyle(
                fontSize: NonType.body,
                height: NonType.lineBody,
                color: ok ? p.ink2 : p.warn,
              ),
            ),
          ],
          if (metrics.isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                for (final metric in metrics)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: p.panel2,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      metric,
                      style: TextStyle(fontSize: NonType.caption, color: p.ink3),
                    ),
                  ),
              ],
            ),
          ],
          if (detail != null && detail!.trim().isNotEmpty) ...<Widget>[
            const SizedBox(height: NonSpace.xs),
            Material(
              type: MaterialType.transparency,
              child: ExpansionTile(
                key: const ValueKey('workspace-artifact-detail'),
                tilePadding: EdgeInsets.zero,
                childrenPadding: EdgeInsets.zero,
                title: Text(
                  '技术详情',
                  style: TextStyle(fontSize: NonType.caption, color: p.ink4),
                ),
                children: <Widget>[
                  Text(detail!, style: TextStyle(fontSize: NonType.caption, color: p.ink4)),
                ],
              ),
            ),
          ],
          if (onPrimary != null || onOpen != null) ...<Widget>[
            const SizedBox(height: NonSpace.sm),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                if (onOpen != null)
                  TextButton(
                    key: const ValueKey('workspace-artifact-open'),
                    onPressed: onOpen,
                    child: Text(
                      openLabel ?? '打开',
                      style: const TextStyle(fontSize: NonType.body),
                    ),
                  ),
                if (primaryLabel != null && onPrimary != null)
                  FilledButton(
                    key: const ValueKey('workspace-artifact-primary'),
                    onPressed: onPrimary,
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      textStyle: const TextStyle(fontSize: NonType.body),
                    ),
                    child: Text(primaryLabel!),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
