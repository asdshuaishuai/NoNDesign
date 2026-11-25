// 设计工作台面板手势（2026-11-25）：
//
// 设计面（非插件视图）左右面板与主区之间的 1px 分隔边界给约 8px 热区：
//  * 双击左边界 → 左栏隐藏（store.leftPanelCollapsed = true），再次双击恢复；
//  * 双击右边界 → 右栏隐藏（store.rightPanelCollapsed = true），再次双击恢复；
//  * 热区只覆盖边界窄条（不是全屏 GestureDetector），悬停有左右分隔光标；
//  * 折叠后仍保留恢复入口（左轨 / 边界热区），不产生「面板没了且无入口」死路；
//  * 窄屏（390，左栏本来就是 sheet 形态）没有热区，双击不崩、不误开面板；
//  * 与 designCanvasFocus 正交：专注模式仍两侧全隐藏，退出后折叠状态保留。
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/widgets/canvas_view.dart';
import 'package:nondesign/widgets/left_panel.dart';
import 'package:nondesign/widgets/rail.dart';
import 'package:nondesign/widgets/workspace.dart';
import 'package:nondesign/widgets/workspace_chrome.dart';
import 'package:nondesign/widgets/workspace_inspector.dart';

const _leftDividerKey = ValueKey('design-left-panel-divider');
const _rightDividerKey = ValueKey('design-right-panel-divider');

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

/// 在边界热区上完成一次双击（两次 tap 间隔要小于 kDoubleTapTimeout）。
Future<void> _doubleTap(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pump(const Duration(milliseconds: 100));
  await tester.tap(finder);
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('左右面板折叠是状态级开关：toggle 翻转并通知', () {
    final store = _store();
    var notified = 0;
    store.addListener(() => notified++);
    expect(store.leftPanelCollapsed, isFalse);
    expect(store.rightPanelCollapsed, isFalse);
    store.toggleLeftPanel();
    expect(store.leftPanelCollapsed, isTrue);
    expect(store.rightPanelCollapsed, isFalse, reason: '两侧独立');
    expect(notified, 1);
    store.toggleRightPanel();
    expect(store.rightPanelCollapsed, isTrue);
    expect(notified, 2);
    store.toggleLeftPanel();
    expect(store.leftPanelCollapsed, isFalse);
    expect(notified, 3);
  });

  testWidgets('1440：双击左边界折叠左栏，再次双击恢复', (tester) async {
    _setViewport(tester, const Size(1440, 900));
    final store = _store();
    await tester.pumpWidget(_app(store, const Workspace()));
    await tester.pump(const Duration(milliseconds: 150));

    expect(find.byType(LeftPanel), findsOneWidget, reason: '普通态保留设计左栏');
    expect(find.byType(WorkspaceRightPanel), findsOneWidget);
    expect(find.byType(CanvasView), findsOneWidget);

    final divider = find.byKey(_leftDividerKey);
    expect(divider, findsOneWidget);
    // 热区只覆盖边界窄条（8px），不是铺满全屏的手势层；画布其余区域照常可点。
    expect(tester.getSize(divider).width, 8);
    expect(
      tester.getTopLeft(divider).dx,
      tester.getBottomRight(find.byType(LeftPanel)).dx,
      reason: '热区贴着左栏的 1px 分隔边界',
    );
    expect(
      tester.widget<MouseRegion>(divider).cursor,
      SystemMouseCursors.resizeLeftRight,
      reason: '悬停边界显示左右分隔光标',
    );

    // 单击不折叠（只有双击生效；热区不抢画布的普通点击语义）。
    await tester.tap(divider);
    await tester.pump(const Duration(milliseconds: 350));
    expect(store.leftPanelCollapsed, isFalse);

    await _doubleTap(tester, divider);
    expect(store.leftPanelCollapsed, isTrue);
    expect(find.byType(LeftPanel), findsNothing, reason: '双击隐藏左栏');
    expect(find.byType(WorkspaceRightPanel), findsOneWidget, reason: '右栏不受影响');
    expect(
      find.byKey(_leftDividerKey),
      findsOneWidget,
      reason: '折叠后仍留可恢复的热区入口',
    );
    expect(find.byType(CanvasView), findsOneWidget, reason: '画布保持');

    await _doubleTap(tester, find.byKey(_leftDividerKey));
    expect(store.leftPanelCollapsed, isFalse);
    expect(find.byType(LeftPanel), findsOneWidget, reason: '再次双击恢复左栏');
    expect(tester.takeException(), isNull);
  });

  testWidgets('1440：双击右边界折叠右栏，再次双击恢复', (tester) async {
    _setViewport(tester, const Size(1440, 900));
    final store = _store();
    await tester.pumpWidget(_app(store, const Workspace()));
    await tester.pump(const Duration(milliseconds: 150));

    expect(find.byType(WorkspaceRightPanel), findsOneWidget);
    expect(find.byType(LeftPanel), findsOneWidget);

    final divider = find.byKey(_rightDividerKey);
    expect(divider, findsOneWidget);
    expect(tester.getSize(divider).width, 8);
    expect(
      tester.getTopLeft(divider).dx,
      tester.getBottomRight(find.byType(WorkspaceMainArea)).dx,
      reason: '热区贴着右栏的 1px 分隔边界',
    );
    expect(
      tester.widget<MouseRegion>(divider).cursor,
      SystemMouseCursors.resizeLeftRight,
    );

    await _doubleTap(tester, divider);
    expect(store.rightPanelCollapsed, isTrue);
    expect(find.byType(WorkspaceRightPanel), findsNothing, reason: '双击隐藏右栏');
    expect(find.byType(LeftPanel), findsOneWidget, reason: '左栏不受影响');
    expect(
      find.byKey(_rightDividerKey),
      findsOneWidget,
      reason: '折叠后仍留可恢复的热区入口',
    );

    await _doubleTap(tester, find.byKey(_rightDividerKey));
    expect(store.rightPanelCollapsed, isFalse);
    expect(find.byType(WorkspaceRightPanel), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('折叠左栏后从左轨入口仍能恢复（不产生死路）', (tester) async {
    _setViewport(tester, const Size(1440, 900));
    final store = _store();
    await tester.pumpWidget(_app(store, const Workspace()));
    await tester.pump(const Duration(milliseconds: 150));

    await _doubleTap(tester, find.byKey(_leftDividerKey));
    expect(store.leftPanelCollapsed, isTrue);
    expect(find.byType(LeftPanel), findsNothing);

    // 折叠态下点左侧图标轨「设计」入口：先展开左栏，再照常切面板/视图。
    await tester.tap(
      find.descendant(of: find.byType(Rail), matching: find.text('设计')),
    );
    await tester.pump(const Duration(milliseconds: 150));
    expect(store.leftPanelCollapsed, isFalse, reason: '左轨仍是恢复入口');
    expect(find.byType(LeftPanel), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('390 窄屏没有左栏热区：双击边界不崩、不误开面板', (tester) async {
    _setViewport(tester, const Size(390, 844));
    final store = _store();
    await tester.pumpWidget(_app(store, const Workspace()));
    await tester.pump(const Duration(milliseconds: 150));

    // 手机宽：左栏本来就是 sheet 形态，不渲染常驻左栏与边界热区。
    expect(find.byType(LeftPanel), findsNothing);
    expect(find.byKey(_leftDividerKey), findsNothing);
    expect(find.byKey(_rightDividerKey), findsNothing);
    expect(
      find.byType(CanvasView),
      findsOneWidget,
      reason: '主区仍是画布（窄屏 sheet 行为不变）',
    );

    // 在没有热区的窄屏上双击边界附近：不抛出异常、不误开面板/误折叠。
    await tester.tapAt(const Offset(60, 400));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(const Offset(60, 400));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    expect(store.leftPanelCollapsed, isFalse);
    expect(store.rightPanelCollapsed, isFalse);
    expect(find.byType(LeftPanel), findsNothing);
    expect(find.byType(WorkspaceRightPanel), findsNothing);
  });

  testWidgets('designCanvasFocus 仍优先：专注态全隐藏，退出后折叠状态保留且可恢复', (tester) async {
    _setViewport(tester, const Size(1440, 900));
    final store = _store();
    await tester.pumpWidget(_app(store, const Workspace()));
    await tester.pump(const Duration(milliseconds: 150));

    // 先用边界热区把左右两侧都折叠。
    await _doubleTap(tester, find.byKey(_leftDividerKey));
    await _doubleTap(tester, find.byKey(_rightDividerKey));
    expect(store.leftPanelCollapsed, isTrue);
    expect(store.rightPanelCollapsed, isTrue);
    expect(find.byType(LeftPanel), findsNothing);
    expect(find.byType(WorkspaceRightPanel), findsNothing);
    expect(find.byKey(_leftDividerKey), findsOneWidget, reason: '折叠态仍留左热区');
    expect(find.byKey(_rightDividerKey), findsOneWidget, reason: '折叠态仍留右热区');

    // 专注模式仍全部隐藏：两侧面板与边界热区都不挂。
    store.toggleDesignCanvasFocus();
    await tester.pump(const Duration(milliseconds: 150));
    expect(store.designCanvasFocus, isTrue);
    expect(find.byType(LeftPanel), findsNothing);
    expect(find.byType(WorkspaceRightPanel), findsNothing);
    expect(find.byKey(_leftDividerKey), findsNothing, reason: '专注态不挂边界热区');
    expect(find.byKey(_rightDividerKey), findsNothing);
    expect(find.byType(CanvasView), findsOneWidget);
    expect(tester.takeException(), isNull);

    // 退出专注：折叠状态正交保留，不会偷偷把面板放回来。
    store.toggleDesignCanvasFocus();
    await tester.pump(const Duration(milliseconds: 150));
    expect(store.designCanvasFocus, isFalse);
    expect(store.leftPanelCollapsed, isTrue);
    expect(store.rightPanelCollapsed, isTrue);
    expect(find.byType(LeftPanel), findsNothing);
    expect(find.byType(WorkspaceRightPanel), findsNothing);
    expect(find.byKey(_leftDividerKey), findsOneWidget);
    expect(find.byKey(_rightDividerKey), findsOneWidget);

    // 折叠后仍可双击恢复。
    await _doubleTap(tester, find.byKey(_leftDividerKey));
    expect(store.leftPanelCollapsed, isFalse);
    expect(find.byType(LeftPanel), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
