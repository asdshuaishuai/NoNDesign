import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/core/workspace_stage.dart';
import 'package:nondesign/widgets/workspace_artifact_card.dart';
import 'package:nondesign/widgets/workspace_progress.dart';

Widget _app(Widget child) => MaterialApp(
  theme: AppTheme.build(dark: true),
  home: Scaffold(body: child),
);

void main() {
  group('WorkspaceProgress（执行过程面）', () {
    testWidgets('阶段状态渲染 + 失败人话 + 取消回调', (tester) async {
      var cancelled = false;
      await tester.pumpWidget(
        _app(
          WorkspaceProgress(
            stages: const <WorkspaceStage>[
              WorkspaceStage(
                id: 'build',
                label: '构建原型',
                detail: '2 屏',
                state: WorkspaceStageState.done,
              ),
              WorkspaceStage(
                id: 'verify',
                label: '覆盖验证',
                state: WorkspaceStageState.running,
              ),
              WorkspaceStage(
                id: 'persist',
                label: '写入项目',
                state: WorkspaceStageState.pending,
              ),
            ],
            errorMessage: '还有 1 条跳转未覆盖',
            onCancel: () => cancelled = true,
          ),
        ),
      );
      expect(find.byKey(const ValueKey('workspace-progress')), findsOneWidget);
      expect(find.text('构建原型'), findsOneWidget);
      expect(find.text('覆盖验证'), findsOneWidget);
      expect(find.text('还有 1 条跳转未覆盖'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('workspace-stage-build')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('workspace-progress-cancel')));
      expect(cancelled, isTrue);
    });

    testWidgets('空阶段不渲染（不占画布空间）', (tester) async {
      await tester.pumpWidget(
        _app(const WorkspaceProgress(stages: <WorkspaceStage>[])),
      );
      expect(find.byKey(const ValueKey('workspace-progress')), findsNothing);
    });
  });

  group('WorkspaceArtifactCard（结果面）', () {
    testWidgets('成功卡：标题/摘要/指标/主操作/打开/收起', (tester) async {
      var primary = false;
      var open = false;
      var dismissed = false;
      await tester.pumpWidget(
        _app(
          WorkspaceArtifactCard(
            title: '验证原型 · demo',
            summary: '全部覆盖',
            metrics: const <String>['2 屏', '1 条跳转', '全部覆盖'],
            primaryLabel: '查看覆盖检查',
            onPrimary: () => primary = true,
            onOpen: () => open = true,
            onDismiss: () => dismissed = true,
          ),
        ),
      );
      expect(
        find.byKey(const ValueKey('workspace-artifact-card')),
        findsOneWidget,
      );
      expect(find.text('验证原型 · demo'), findsOneWidget);
      expect(find.text('全部覆盖'), findsWidgets);
      await tester.tap(
        find.byKey(const ValueKey('workspace-artifact-primary')),
      );
      await tester.tap(find.byKey(const ValueKey('workspace-artifact-open')));
      await tester.tap(
        find.byKey(const ValueKey('workspace-artifact-dismiss')),
      );
      expect(primary, isTrue);
      expect(open, isTrue);
      expect(dismissed, isTrue);
    });

    testWidgets('失败卡：错误色/失败摘要/技术详情折叠', (tester) async {
      await tester.pumpWidget(
        _app(
          const WorkspaceArtifactCard(
            title: '验证原型 · broken',
            ok: false,
            summary: '缺少画板 empty',
            detail: 'engine: unreachable',
          ),
        ),
      );
      expect(find.text('缺少画板 empty'), findsOneWidget);
      expect(find.text('技术详情'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('workspace-artifact-detail')),
        findsOneWidget,
      );
    });
  });
}
