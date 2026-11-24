import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nondesign/core/design_prototype.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/core/toast_service.dart';
import 'package:nondesign/core/workspace_stage.dart';
import 'package:nondesign/widgets/design_prototype_banner.dart';
import 'package:provider/provider.dart';

DesignPrototypeDocument _doc({bool verified = true}) => DesignPrototypeDocument(
  html: '<!doctype html><html><body><section data-screen="home"></section></body></html>',
  manifest: <String, Object?>{
    'schema': 'nan.design.prototype/1',
    'entry': 'home',
    'screens': <Object?>[
      <String, Object?>{'id': 'home', 'title': '首页'},
    ],
    'flows': <Object?>[
      <String, Object?>{'from': 'home', 'to': 'cart'},
    ],
  },
  verified: verified,
  checks: <DesignPrototypeCheck>[
    const DesignPrototypeCheck('screen_home', true, '画板 home 已实现'),
    DesignPrototypeCheck(
      'flow_home_cart',
      verified,
      verified ? '跳转 home → cart 已实现' : '跳转 home → cart 缺少连线（data-nav）',
    ),
  ],
  builtAt: '2026-11-24T00:00:00Z',
);

Widget _app(AppStore store) => ChangeNotifierProvider<AppStore>.value(
  value: store,
  child: MaterialApp(
    theme: AppTheme.build(dark: true),
    home: const Scaffold(body: DesignPrototypeBanner()),
  ),
);

void main() {
  testWidgets('结果卡：成功态显示指标，主操作/覆盖检查/收起可用', (tester) async {
    final store = AppStore(toasts: ToastService(autoDismiss: false));
    store.projectName = 'demo';
    store.designPrototypeResult = _doc();
    store.designPrototypeStages = <WorkspaceStage>[
      const WorkspaceStage(
        id: 'verify',
        label: '覆盖验证',
        state: WorkspaceStageState.done,
      ),
    ];
    await tester.pumpWidget(_app(store));
    expect(find.text('验证原型 · demo'), findsOneWidget);
    expect(find.text('全部画板与跳转已覆盖，原型已存入项目。'), findsOneWidget);
    expect(find.text('1 屏'), findsOneWidget);
    expect(find.text('1 条跳转'), findsOneWidget);
    // 覆盖检查对话框（不走 WebView 预览，测试环境无平台视图）。
    await tester.tap(find.byKey(const ValueKey('workspace-artifact-open')));
    await tester.pumpAndSettle();
    expect(find.text('原型覆盖检查：全部通过'), findsOneWidget);
    expect(find.text('知道了'), findsOneWidget);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('workspace-artifact-dismiss')));
    expect(store.designPrototypeResult, isNull);
  });

  testWidgets('失败态：未覆盖项 + 覆盖检查列出缺失', (tester) async {
    final store = AppStore(toasts: ToastService(autoDismiss: false));
    store.projectName = 'demo';
    store.designPrototypeResult = _doc(verified: false);
    await tester.pumpWidget(_app(store));
    expect(find.text('有未覆盖项：跳转 home → cart 缺少连线（data-nav）'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('workspace-artifact-open')));
    await tester.pumpAndSettle();
    expect(find.text('原型覆盖检查：有未通过项'), findsOneWidget);
  });

  testWidgets('执行过程面：失败人话显示，阶段条在场', (tester) async {
    final store = AppStore(toasts: ToastService(autoDismiss: false));
    store.designPrototypeStages = <WorkspaceStage>[
      const WorkspaceStage(
        id: 'build',
        label: '构建自包含原型',
        detail: '失败',
        state: WorkspaceStageState.failed,
      ),
    ];
    store.designPrototypeError = '验证原型没有完成，请稍后重试';
    await tester.pumpWidget(_app(store));
    expect(find.byKey(const ValueKey('workspace-progress')), findsOneWidget);
    expect(find.text('验证原型没有完成，请稍后重试'), findsOneWidget);
    expect(find.byKey(const ValueKey('workspace-stage-build')), findsOneWidget);
  });
}
