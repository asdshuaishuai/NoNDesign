// 项目/工作台切换回归（用户裁决 2026-11-19）：
//
// 「右侧 chat 不允许出现多工作区；一个项目只对应它自己的工作台类型；切换工作台
// 必定追随着项目的切换」——所以：
//   * NaN 窄栏里不再有「主页/设计/3D/视频/热应用」切换条；
//   * 唯一的切换口是顶栏的项目下拉（列出设计项目 / 3D 场景 / 热应用 / 视频），
//     点一个项目才换工作台；
//   * 3D / 视频 / 热应用工作台没有设计壳顶栏，它们靠自己的项目菜单与「返回主页」，
//     不会在项目内部横跳。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/platform_capabilities.dart';
import 'package:nondesign/core/portfolio_entries.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/core/toast_service.dart';
import 'package:nondesign/widgets/hotapp_workspace.dart';
import 'package:nondesign/widgets/shell_host.dart';
import 'package:nondesign/widgets/three_workspace.dart';

AppStore _store() {
  final store = AppStore(toasts: ToastService(autoDismiss: false))
    ..ready = true
    ..hasProject = true
    ..projectName = 'demo'
    ..projectPath = '/tmp/demo.ddp'
    ..settings = AppSettings(providerId: 'deepseek', modelId: 'deepseek-v4.1-flash');
  store.portfolioEntries = [
    const PortfolioEntry(
        kind: 'three', ref: 'saturn-demo', title: 'saturn-demo', detail: '3D 场景'),
    const PortfolioEntry(
        kind: 'three', ref: 'pomodoro-3d', title: 'pomodoro-3d', detail: '3D 场景'),
    const PortfolioEntry(
        kind: 'hotapp', ref: 'demo-app', title: 'demo-app', detail: '热应用'),
    const PortfolioEntry(
        kind: 'video', ref: '/tmp/clip.mp4', title: 'clip.mp4', detail: '视频', path: '/tmp/clip.mp4'),
  ];
  store.portfolioLoadedAt = DateTime.now().millisecondsSinceEpoch;
  store.view = 'design';
  return store;
}

Future<void> _pump(WidgetTester tester, AppStore store) async {
  tester.view.physicalSize = const Size(1440, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(ChangeNotifierProvider<AppStore>.value(
    value: store,
    child: MaterialApp(
      theme: AppTheme.build(dark: true),
      builder: (context, child) =>
          withResponsiveTextScale(context, child ?? const SizedBox.shrink()),
      home: ShellHost(capabilities: PlatformCapabilities.forOs(HostOs.macos)),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 80));
}

Future<void> _openProjectMenu(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('title-bar-project-menu')));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    threeLoadOnOpen = null;
    hotAppLoadOnOpen = null;
  });
  tearDown(() {
    threeLoadOnOpen = null;
    hotAppLoadOnOpen = null;
  });

  testWidgets('右侧 NaN 窄栏没有工作区切换条（只剩 NaN / 检查）', (tester) async {
    final store = _store();
    await _pump(tester, store);

    expect(find.byKey(const ValueKey('desktop-chat-rail')), findsOneWidget);
    for (final mode in const ['home', 'design', 'three', 'video', 'hotapp']) {
      expect(find.byKey(ValueKey('rail-workspace-$mode')), findsNothing,
          reason: '窄栏不允许出现工作区切换条（$mode）');
    }
    expect(find.byKey(const ValueKey('desktop-chat-rail-tab-agent')), findsOneWidget);
    expect(find.byKey(const ValueKey('desktop-chat-rail-tab-inspect')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('顶栏项目下拉按类型列出项目：点 3D 场景 → 工作台跟着项目切', (tester) async {
    final store = _store();
    await _pump(tester, store);

    await _openProjectMenu(tester);
    // 菜单里按项目类型分组：3D 场景 / 热应用 / 视频都在。
    expect(find.text('3D 场景'), findsWidgets);
    expect(find.text('saturn-demo'), findsOneWidget);
    expect(find.text('pomodoro-3d'), findsOneWidget);
    expect(find.text('demo-app'), findsOneWidget);
    expect(find.text('新建 3D 场景'), findsOneWidget);
    expect(find.text('新建热应用'), findsOneWidget);
    expect(find.text('回到主页'), findsOneWidget);

    await tester.tap(find.text('saturn-demo'));
    await tester.pumpAndSettle();
    expect(store.view, 'plugin:three', reason: '打开 3D 项目 = 进 3D 工作台');
    // 工作台在 initState 消费开局全局并落回设置（跨视图续接同一场景）。
    expect(store.settings.threeProjectName, 'saturn-demo', reason: '工作台要拿到项目名');
    expect(threeLoadOnOpen, isNull, reason: '开局全局是「一次性」的，消费后必须清空');
    expect(tester.takeException(), isNull);
  });

  testWidgets('点热应用项目 → 热应用工作台；当前项目标记跟着走', (tester) async {
    final store = _store();
    await _pump(tester, store);

    await _openProjectMenu(tester);
    await tester.tap(find.text('demo-app'));
    await tester.pumpAndSettle();
    expect(store.view, 'plugin:hotapp');
    expect(store.settings.hotappApp, 'demo-app');
    expect(hotAppLoadOnOpen, isNull, reason: '开局全局是「一次性」的，消费后必须清空');
    expect(tester.takeException(), isNull);
  });

  testWidgets('「新建 3D 场景」清掉当前场景名，工作台落新建态', (tester) async {
    final store = _store()..setThreeProjectName('saturn-demo');
    store.view = 'design';
    await _pump(tester, store);

    await _openProjectMenu(tester);
    await tester.tap(find.text('新建 3D 场景'));
    await tester.pumpAndSettle();
    expect(store.view, 'plugin:three');
    expect(store.settings.threeProjectName, isEmpty);
    expect(threeLoadOnOpen, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('「回到主页」回主页（工作台入口）', (tester) async {
    final store = _store();
    await _pump(tester, store);

    await _openProjectMenu(tester);
    await tester.tap(find.text('回到主页'));
    await tester.pumpAndSettle();
    expect(store.view, 'home');
    expect(tester.takeException(), isNull);
  });

  testWidgets('3D 工作台里没有设计壳顶栏，也就没有工作区切换入口', (tester) async {
    final store = _store()..view = 'plugin:three';
    store.setThreeProjectName('saturn-demo');
    await _pump(tester, store);

    // 插件工作台整屏渲染自己的顶栏：设计壳的 TitleBar（含项目下拉）不出现。
    expect(find.byKey(const ValueKey('title-bar-project-menu')), findsNothing);
    // 右侧 NaN 仍在，但窄栏仍只有 NaN/检查两个 tab。
    expect(find.byKey(const ValueKey('desktop-chat-rail')), findsOneWidget);
    expect(find.byKey(const ValueKey('rail-workspace-three')), findsNothing);
    expect(find.byKey(const ValueKey('rail-workspace-design')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
