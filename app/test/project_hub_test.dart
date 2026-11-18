// 架构裁决（2026-11-18）：设计 / 热应用 / 3D / 视频是相互独立的模块，
// 项目打开/新建**不默认落在设计画布**——桌面壳落中性模块入口（hub）。
// 移动端壳以设计为工作面，行为不变（defaultTargetPlatform 覆盖锚定两分支）。
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/platform_capabilities.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/core/toast_service.dart';
import 'package:nondesign/widgets/shell_host.dart';

AppStore _store() {
  final store = AppStore(toasts: ToastService(autoDismiss: false));
  store.ready = true;
  store.settings = AppSettings(providerId: 'deepseek', modelId: 'deepseek-v4.1-flash');
  return store;
}

Widget _wrap(AppStore store) =>
    ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(
        theme: AppTheme.build(dark: true),
        builder: (context, child) =>
            withResponsiveTextScale(context, child ?? const SizedBox.shrink()),
        home: ShellHost(capabilities: PlatformCapabilities.forOs(HostOs.macos)),
      ),
    );

Future<void> _pump(WidgetTester tester, AppStore store) async {
  tester.view.physicalSize = const Size(1440, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(_wrap(store));
  await tester.pump(const Duration(milliseconds: 60));
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('桌面：新建项目落在模块入口 hub（不是设计画布）', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final store = _store();
    await _pump(tester, store);

    final ok = await store.newProject(empty: true);
    expect(ok, isTrue);
    await tester.pump(const Duration(milliseconds: 120));

    expect(store.view, 'hub', reason: '项目落地 = 中性模块入口');
    expect(find.byKey(const ValueKey('hub-module-设计')), findsOneWidget);
    expect(find.byKey(const ValueKey('hub-module-NaN 热应用')), findsOneWidget);
    expect(find.byKey(const ValueKey('hub-module-3D 工作台')), findsOneWidget);
    expect(find.byKey(const ValueKey('hub-module-视频工作台')), findsOneWidget);
  });

  testWidgets('hub 点「设计」进入设计画布（设计是可选模块，不是默认）', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final store = _store();
    await _pump(tester, store);

    await store.newProject(empty: true);
    await tester.pump(const Duration(milliseconds: 120));
    await tester.tap(find.byKey(const ValueKey('hub-module-设计')));
    await tester.pump(const Duration(milliseconds: 120));
    expect(store.view, 'design');
  });

  test('移动端落地保持设计工作面（行为不变）', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final store = _store();
    // _projectLandingView 是私有的：经由移动端分支断言落地值。
    store.newProject(empty: true);
    expect(store.view, 'design');
  });
}
