// 「检查」面板按工作区分派（workspace_inspector.dart）的回归面：
// * 设计 / 文档 / 源码 / 未知视图 → 原设计检查器（画板/页型/本板交互仍在）；
// * 3D / 视频 / 热应用 / 演示 / 作品集 → 各自分支，且不出现设计专属文案；
// * 窄栏 tab 文案与折叠条 tooltip/图标跟着工作区变（tab id 仍是 inspect）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:nondesign/core/app_paths.dart';
import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/core/video_samples.dart';
import 'package:nondesign/widgets/chat_rail.dart';
import 'package:nondesign/widgets/right_panel.dart';
import 'package:nondesign/widgets/workspace_inspector.dart';

/// 设计专属文案：只有画板 Inspector 会渲染；其它工作区的检查器不得出现。
const _designOnlyCopy = ['页型判定', '本板交互'];

AppStore _store({String view = 'design'}) {
  final store = AppStore();
  store.view = view;
  store.mbt = '---\nmoonviz:\n  format: visual-document\n  revision: 1\n  entry: home\n---\n';
  store.render = RenderEnvelope(
    ok: true,
    entry: 'home',
    revision: 1,
    mbt: store.mbt,
    artboards: const [
      Artboard(id: 'home', name: 'home', width: 390, height: 844, nodes: []),
    ],
  );
  return store;
}

Widget _host(AppStore store, Widget child) => ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(
        theme: AppTheme.build(dark: true),
        home: Scaffold(body: SizedBox(width: 348, child: child)),
      ),
    );

Future<void> _pump(WidgetTester tester, AppStore store, {Widget child = const WorkspaceInspector()}) async {
  await tester.pumpWidget(_host(store, child));
  await tester.pump(const Duration(milliseconds: 80));
}

void _expectNoDesignCopy() {
  for (final copy in _designOnlyCopy) {
    expect(find.text(copy), findsNothing, reason: '非设计工作区不得出现设计检查器文案：$copy');
  }
}

void _expectOtherBranchesAbsent(String expectedKey) {
  for (final key in ['wi-design', 'wi-three', 'wi-video', 'wi-hotapp', 'wi-play', 'wi-portfolio']) {
    expect(
      find.byKey(ValueKey(key)),
      key == expectedKey ? findsOneWidget : findsNothing,
      reason: '分支 key=$key（期望 $expectedKey）',
    );
  }
}

void main() {
  // 热应用分支会读本地应用库（只读）；测试指向临时目录，不碰真实文档目录。
  late Directory tempRoot;
  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('nd-wi-test-');
    AppPaths.projectsRootOverride = tempRoot;
  });
  tearDown(() {
    AppPaths.projectsRootOverride = null;
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  test('检查 tab 文案/图标按工作区分派（tab id 不变）', () {
    expect(inspectTabLabelForView('design'), '检查');
    expect(inspectTabLabelForView('docs'), '检查');
    expect(inspectTabLabelForView('source'), '检查');
    expect(inspectTabLabelForView('plugin:three'), '3D 检查');
    expect(inspectTabLabelForView('plugin:video'), '视频检查');
    expect(inspectTabLabelForView('plugin:hotapp'), '应用检查');
    expect(inspectTabLabelForView('play'), '演示检查');
    expect(inspectTabLabelForView('portfolio'), '作品集检查');
    expect(inspectTabLabelForView('mystery'), '检查');

    expect(inspectTabIconForView('plugin:three'), Icons.view_in_ar_outlined);
    expect(inspectTabIconForView('plugin:video'), Icons.movie_outlined);
    expect(inspectTabIconForView('plugin:hotapp'), Icons.widgets_outlined);
    expect(inspectTabIconForView('design'), Icons.center_focus_strong_outlined);
  });

  testWidgets('设计 / 文档 / 未知视图：仍是原设计检查器', (tester) async {
    for (final view in ['design', 'docs', 'source', 'chat']) {
      final store = _store(view: view);
      await _pump(tester, store);
      expect(find.byKey(const ValueKey('workspace-inspector')), findsOneWidget);
      expect(find.byKey(const ValueKey('wi-design')), findsOneWidget, reason: 'view=$view 兜底设计检查器');
      expect(find.byType(Inspector), findsOneWidget, reason: 'view=$view 设计检查器不得退化');
      // 有画板时原检查器渲染画板级检查与页型判定入口。
      expect(find.text('本板交互'), findsOneWidget, reason: 'view=$view');
      expect(find.text('页型判定'), findsOneWidget, reason: 'view=$view');
      _expectOtherBranchesAbsent('wi-design');
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('3D：未打开场景给提示 + 去 3D 工作台；打开后显示项目与状态', (tester) async {
    final store = _store(view: 'plugin:three');
    await _pump(tester, store);
    expect(find.byKey(const ValueKey('workspace-inspector')), findsOneWidget);
    _expectOtherBranchesAbsent('wi-three');
    expect(find.text('3D 场景还没打开'), findsOneWidget);
    expect(find.text('去 3D 工作台'), findsOneWidget);
    expect(find.byKey(const ValueKey('wi-open-workspace')), findsOneWidget);
    _expectNoDesignCopy();

    // 有项目：项目名 + 场景状态 + 生成入口提示，不再出空态。
    store.settings.threeProjectName = 'saturn-demo';
    store.notifyListeners();
    await tester.pump();
    expect(find.text('saturn-demo'), findsWidgets);
    expect(find.text('已打开'), findsWidgets);
    expect(find.text('生成入口'), findsOneWidget);
    expect(find.text('3D 场景还没打开'), findsNothing);
    _expectNoDesignCopy();
  });

  testWidgets('视频：示例名 + 帧率/时长/帧数 + 打开工作台', (tester) async {
    final store = _store(view: 'plugin:video');
    store.settings.videoSampleIdx = 0;
    await _pump(tester, store);
    _expectOtherBranchesAbsent('wi-video');
    expect(find.text('视频检查'), findsOneWidget);
    expect(find.text(videoSamples[0].label), findsWidgets);
    expect(find.text('帧率'), findsOneWidget);
    expect(find.text('时长'), findsOneWidget);
    expect(find.text('帧数'), findsOneWidget);
    expect(find.text('打开视频工作台'), findsOneWidget);
    _expectNoDesignCopy();
  });

  testWidgets('热应用：应用名 + 类型徽标 + 打开热应用工作台', (tester) async {
    final store = _store(view: 'plugin:hotapp');
    store.settings.hotappApp = 'invoice-demo';
    await _pump(tester, store);
    _expectOtherBranchesAbsent('wi-hotapp');
    expect(find.text('热应用'), findsOneWidget);
    expect(find.text('invoice-demo'), findsWidgets);
    expect(find.text('类型'), findsOneWidget);
    expect(find.text('可用应用'), findsOneWidget, reason: '旧数据缺 origin 字段按可用应用');
    expect(find.text('打开热应用工作台'), findsOneWidget);
    expect(find.byKey(const ValueKey('wi-open-workspace')), findsOneWidget);
    _expectNoDesignCopy();
  });

  testWidgets('演示 / 作品集：不适用检查 + 回到设计', (tester) async {
    final play = _store(view: 'play');
    await _pump(tester, play);
    _expectOtherBranchesAbsent('wi-play');
    expect(find.text('演示模式不写文档'), findsOneWidget);
    expect(find.text('回到设计'), findsOneWidget);
    _expectNoDesignCopy();

    final portfolio = _store(view: 'portfolio');
    await _pump(tester, portfolio);
    _expectOtherBranchesAbsent('wi-portfolio');
    expect(find.text('作品集不适用检查'), findsOneWidget);
    expect(find.text('回到设计'), findsOneWidget);
    _expectNoDesignCopy();
  });

  testWidgets('窄栏检查 tab 与折叠条 tooltip 跟随工作区', (tester) async {
    final store = _store(view: 'plugin:three');
    await tester.pumpWidget(_host(
      store,
      ChatRail(
        width: 360,
        tab: kRailTabInspect,
        onTab: (_) {},
        onCollapse: () {},
      ),
    ));
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.text('3D 检查'), findsOneWidget, reason: '展开栏检查 tab 文案随工作区');
    expect(find.byKey(const ValueKey('workspace-inspector')), findsOneWidget);

    await tester.pumpWidget(_host(
      store,
      ChatRailStrip(tab: kRailTabInspect, onTab: (_) {}),
    ));
    await tester.pump();
    expect(find.byTooltip('3D 检查'), findsOneWidget, reason: '折叠条 tooltip 同步');
  });
}
