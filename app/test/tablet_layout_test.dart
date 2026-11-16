// iPad 布局回归：三档断点（手机 <700 / 平板 700–1024 / 宽屏 ≥1024）。
// - 平板竖屏 768：左栏常驻、右栏折叠为底部 sheet、Welcome 走双栏；
// - 平板横屏 1024：三栏全开、底部 sheet 条消失；
// - 字体在平板上 +5%（responsiveTextScale），一并验证无溢出。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/widgets/a2ui_workspace.dart';
import 'package:nondesign/widgets/portfolio_view.dart';
import 'package:nondesign/widgets/settings_dialog.dart';
import 'package:nondesign/widgets/video_workspace.dart';
import 'package:nondesign/widgets/welcome.dart';
import 'package:nondesign/widgets/workspace.dart';

AppStore _store({bool project = false}) {
  final store = AppStore();
  store.ready = true;
  store.hasProject = project;
  store.settings = AppSettings(providerId: 'deepseek', modelId: 'deepseek-v4.1-flash');
  return store;
}

Widget _wrap(AppStore store, Widget child, {TargetPlatform platform = TargetPlatform.iOS}) =>
    ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(
        theme: AppTheme.build(dark: true).copyWith(platform: platform),
        builder: (context, child) => withResponsiveTextScale(context, child ?? const SizedBox.shrink()),
        home: child,
      ),
    );

Future<void> _pumpAt(WidgetTester tester, Widget child, Size size, {AppStore? store}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(_wrap(store ?? _store(), child));
  await tester.pump(const Duration(milliseconds: 150));
  expect(tester.takeException(), isNull);
}

const _tabletPortrait = Size(768, 1024);
const _tabletLandscape = Size(1024, 768);

void main() {
  testWidgets('Welcome uses the two-column layout on iPad portrait', (tester) async {
    await _pumpAt(
      tester,
      Welcome(onNewProject: () {}, onOpenPath: (_) {}, onSettings: () {}),
      _tabletPortrait,
    );
    expect(find.byKey(const ValueKey('welcome-wide')), findsOneWidget);
    expect(find.text('最近项目'), findsOneWidget);
    expect(find.text('作品集'), findsOneWidget);
  });

  testWidgets('iPad portrait keeps the left panel and folds the right one', (tester) async {
    final store = _store(project: true)..view = 'design';
    await _pumpAt(tester, const Workspace(), _tabletPortrait, store: store);
    // 左栏常驻（空画板提示可见）；右栏折叠成底部 sheet。
    expect(find.text('还没有画板——让 NoN 生成，或点面板顶部 ＋ 新建。'), findsOneWidget);
    expect(find.text('项目面板'), findsNothing);
    expect(find.text('NoN 面板'), findsOneWidget);
  });

  testWidgets('iPad landscape opens all three panes', (tester) async {
    final store = _store(project: true)..view = 'design';
    await _pumpAt(tester, const Workspace(), _tabletLandscape, store: store);
    expect(find.text('还没有画板——让 NoN 生成，或点面板顶部 ＋ 新建。'), findsOneWidget);
    expect(find.text('项目面板'), findsNothing);
    expect(find.text('NoN 面板'), findsNothing);
  });

  testWidgets('video workspace uses the side-by-side layout on iPad', (tester) async {
    await _pumpAt(tester, const Scaffold(body: VideoWorkspace()), _tabletPortrait);
    expect(find.text('标杆示例'), findsOneWidget);
    expect(find.text('加载示例后点「渲染」'), findsOneWidget);
  });

  testWidgets('A2UI and portfolio fit iPad portrait', (tester) async {
    await _pumpAt(tester, const Scaffold(body: A2uiWorkspace()), _tabletPortrait);
    await _pumpAt(tester, const Scaffold(body: PortfolioView()), _tabletPortrait);
  });

  testWidgets('settings dialog fits iPad portrait', (tester) async {
    tester.view.physicalSize = _tabletPortrait;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = _store();
    await tester.pumpWidget(_wrap(
      store,
      Builder(builder: (context) {
        return Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => showSettingsDialog(context),
              child: const Text('open'),
            ),
          ),
        );
      }),
    ));
    await tester.tap(find.text('open'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('模型与端点'), findsOneWidget);
    // iPad 同样属于移动端：第三方智能体入口隐藏。
    expect(find.text('外部智能体'), findsNothing);
  });

  testWidgets('desktop settings keeps the external agent tab', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = _store();
    await tester.pumpWidget(_wrap(
      store,
      Builder(builder: (context) {
        return Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => showSettingsDialog(context),
              child: const Text('open'),
            ),
          ),
        );
      }),
      platform: TargetPlatform.macOS,
    ));
    await tester.tap(find.text('open'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    expect(find.text('外部智能体'), findsOneWidget);
  });
}
