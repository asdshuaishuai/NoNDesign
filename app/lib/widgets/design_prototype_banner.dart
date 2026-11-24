/// 设计模块的「执行过程面 + 结果面」横幅：验证原型的阶段线、结果卡、
/// 覆盖检查对话框与预览入口。由设计画布复用；单独可测（不依赖整个 Workspace）。
library;

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../core/design_prototype.dart';
import '../core/store.dart';
import '../core/theme.dart';
import 'common.dart';
import 'design_prototype_preview.dart';
import 'workspace_artifact_card.dart';
import 'workspace_progress.dart';

class DesignPrototypeBanner extends StatelessWidget {
  const DesignPrototypeBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final p = context.palette;
    final doc = store.designPrototypeResult;
    final running = store.designPrototypeBusy ||
        (store.designPrototypeError != null && store.designPrototypeStages.isNotEmpty);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (store.designPrototypeBusy || store.designPrototypeError != null)
          WorkspaceProgress(
            stages: store.designPrototypeStages,
            errorMessage: store.designPrototypeError,
          ),
        if (doc != null)
          WorkspaceArtifactCard(
            title: '验证原型 · ${store.projectName}',
            ok: doc.verified,
            summary: doc.verified
                ? '全部画板与跳转已覆盖，原型已存入项目。'
                : '有未覆盖项：${_failures(doc)}',
            metrics: <String>[
              '${doc.manifest['screens'] is List ? (doc.manifest['screens'] as List).length : 0} 屏',
              '${doc.manifest['flows'] is List ? (doc.manifest['flows'] as List).length : 0} 条跳转',
              doc.verified ? '全部覆盖' : '未通过',
            ],
            primaryLabel: '打开验证原型',
            onPrimary: () => DesignPrototypePreviewDialog.show(
              context,
              title: '验证原型 · ${store.projectName}',
              html: doc.html,
            ),
            openLabel: '覆盖检查',
            onOpen: () => _showChecks(context, doc),
            onDismiss: store.dismissDesignPrototypeResult,
          ),
        if (running && store.designPrototypeBusy)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              '正在验证原型…',
              style: TextStyle(fontSize: 11, color: p.ink4),
            ),
          ),
      ],
    );
  }

  static String _failures(DesignPrototypeDocument doc) => doc.checks
      .where((DesignPrototypeCheck check) => !check.ok)
      .map((DesignPrototypeCheck check) => check.detail)
      .join('；');

  static Future<void> _showChecks(BuildContext context, DesignPrototypeDocument doc) async {
    final p = context.palette;
    await showNonDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.panel,
        title: Text(
          doc.verified ? '原型覆盖检查：全部通过' : '原型覆盖检查：有未通过项',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: p.ink),
        ),
        content: SizedBox(
          width: 520,
          child: ListView(
            shrinkWrap: true,
            children: <Widget>[
              for (final check in doc.checks)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Icon(
                        check.ok ? Icons.check_circle : Icons.error_outline,
                        size: 15,
                        color: check.ok ? p.success : p.warn,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          check.detail,
                          key: ValueKey('prototype-check-${check.id}'),
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.4,
                            color: check.ok ? p.ink2 : p.warn,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }
}
