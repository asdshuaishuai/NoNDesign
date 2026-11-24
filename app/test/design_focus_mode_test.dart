import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/widgets/canvas_view.dart';
import 'package:nondesign/widgets/left_panel.dart';
import 'package:nondesign/widgets/workspace.dart';
import 'package:nondesign/widgets/workspace_inspector.dart';

AppStore _store() {
  final store = AppStore()
    ..ready = true
    ..hasProject = true
    ..view = 'design'
    ..settings = AppSettings(
      providerId: 'deepseek',
      modelId: 'deepseek-v4.1-flash',
    );
  store.registry = const ModelRegistry(providers: {}, fetchedAt: '');
  return store;
}

Widget _app(AppStore store, Widget child) =>
    ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(theme: AppTheme.build(dark: true), home: child),
    );

void _setViewport(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('专注画布是状态级开关：toggle 翻转并通知', () {
    final store = _store();
    var notified = 0;
    store.addListener(() => notified++);
    expect(store.designCanvasFocus, isFalse);
    store.toggleDesignCanvasFocus();
    expect(store.designCanvasFocus, isTrue);
    expect(notified, 1);
    store.toggleDesignCanvasFocus();
    expect(store.designCanvasFocus, isFalse);
    expect(notified, 2);
  });

  testWidgets('设计专注模式：隐藏左右面板，退出恢复（画布优先）', (tester) async {
    _setViewport(tester, const Size(1440, 900));
    final store = _store();
    await tester.pumpWidget(_app(store, const Workspace()));
    await tester.pump(const Duration(milliseconds: 150));

    expect(find.byType(LeftPanel), findsOneWidget, reason: '普通态保留设计左栏');
    expect(
      find.byType(WorkspaceRightPanel),
      findsOneWidget,
      reason: '宽屏保留右检查栏',
    );
    expect(find.byType(CanvasView), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('design-focus-toggle')));
    await tester.pump(const Duration(milliseconds: 150));
    expect(store.designCanvasFocus, isTrue);
    expect(find.byType(LeftPanel), findsNothing, reason: '专注态隐藏左栏');
    expect(find.byType(WorkspaceRightPanel), findsNothing, reason: '专注态隐藏右栏');
    expect(find.byType(CanvasView), findsOneWidget, reason: '画布保持');
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const ValueKey('design-focus-toggle')));
    await tester.pump(const Duration(milliseconds: 150));
    expect(store.designCanvasFocus, isFalse);
    expect(find.byType(LeftPanel), findsOneWidget);
    expect(find.byType(WorkspaceRightPanel), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
