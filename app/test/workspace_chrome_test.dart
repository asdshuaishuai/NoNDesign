// 四个工作台外壳统一回归（用户裁决 2026-11-20）：
//
// 设计 / 3D / 视频 / 热应用四个工作台必须用**同一套外壳**：
//  * 标题栏（项目下拉 / 设置 / 主题入口照旧可用）、左侧图标轨、底部状态栏；
//  * 插件内容只占「设计画布」那块主区（`workspace-main-area`），不重复标题栏/
//    状态栏，插件自己的 46px 工具条仍保留在主区内容顶部；
//  * 设计画布同样在主区（对照组），设计左栏仍在、插件不挂设计左栏；
//  * 桌面 / iPad 横屏仍走 DesktopShell，右侧 NaN 窄栏常驻（插件不是主页）；
//  * 手机 / iPad 竖屏仍由 ChatPiPShell 整屏渲染插件工作区（不进桌面窄栏路）。
//
// 产品裁决与断点唯一来源是 `core/layout.dart` / `docs/copy-glossary.md`。
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/platform_capabilities.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/widgets/canvas_view.dart';
import 'package:nondesign/widgets/chat_pip_shell.dart';
import 'package:nondesign/widgets/chat_rail.dart';
import 'package:nondesign/widgets/desktop_shell.dart';
import 'package:nondesign/widgets/hotapp_workspace.dart';
import 'package:nondesign/widgets/left_panel.dart';
import 'package:nondesign/widgets/pip_window.dart';
import 'package:nondesign/widgets/rail.dart';
import 'package:nondesign/widgets/shell_host.dart';
import 'package:nondesign/widgets/status_bar.dart';
import 'package:nondesign/widgets/three_workspace.dart';
import 'package:nondesign/widgets/title_bar.dart';
import 'package:nondesign/widgets/video_workspace.dart';
import 'package:nondesign/widgets/workspace.dart';
import 'package:nondesign/widgets/workspace_chrome.dart';

/// 插件工作台 widget 类型（主区内容锚点）。
Finder _pluginContent(String view) => switch (view) {
      'plugin:three' => find.byType(ThreeWorkspace),
      'plugin:video' => find.byType(VideoWorkspace),
      'plugin:hotapp' => find.byType(HotAppWorkspace),
      _ => throw ArgumentError.value(view, 'view', '不是插件视图'),
    };

AppStore _store({String view = 'design', bool project = false}) {
  final store = AppStore()
    ..ready = true
    ..hasProject = project
    ..view = view
    ..settings = AppSettings(providerId: 'deepseek', modelId: 'deepseek-v4.1-flash');
  store.registry = const ModelRegistry(providers: {}, fetchedAt: '');
  return store;
}

Widget _app(AppStore store, Widget child) => ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(
        theme: AppTheme.build(dark: true),
        builder: (context, child) =>
            withResponsiveTextScale(context, child ?? const SizedBox.shrink()),
        home: child,
      ),
    );

void _setViewport(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// 桌面尺寸下每个工作台都必须出现的四个外壳部件。
void _expectSharedChrome() {
  expect(find.byType(TitleBar), findsOneWidget, reason: '标题栏是四个工作台共用的');
  expect(find.byType(Rail), findsOneWidget, reason: '左侧图标轨是四个工作台共用的');
  expect(find.byType(StatusBar), findsOneWidget, reason: '底部状态栏是四个工作台共用的');
  expect(find.byType(WorkspaceMainArea), findsOneWidget, reason: '主区槽只有一个');
  expect(find.byKey(const ValueKey('title-bar-project-menu')), findsOneWidget,
      reason: '顶栏项目下拉照旧可用');
  expect(find.byKey(const ValueKey('title-bar-settings')), findsOneWidget,
      reason: '顶栏设置入口照旧可用');
  expect(find.byKey(const ValueKey('title-bar-theme')), findsOneWidget,
      reason: '顶栏主题入口照旧可用');
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  // ---- 1. 四个视图同一套外壳（设计对照 + 三个插件） ----------------------

  testWidgets('design：设计画布在主区，设计左栏保留', (tester) async {
    _setViewport(tester, const Size(1440, 900));
    final store = _store(project: true);
    await tester.pumpWidget(_app(store, const Workspace()));
    await tester.pump(const Duration(milliseconds: 150));

    _expectSharedChrome();
    expect(find.byType(LeftPanel), findsOneWidget, reason: '设计工作台保留设计左栏');
    expect(find.byType(CanvasView), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(WorkspaceMainArea),
        matching: find.byType(CanvasView),
      ),
      findsOneWidget,
      reason: '设计画布在主区槽内（对照组）',
    );
    expect(tester.takeException(), isNull);
  });

  for (final view in const ['plugin:three', 'plugin:video', 'plugin:hotapp']) {
    testWidgets('$view：与设计同一套外壳，插件内容只占主区', (tester) async {
      _setViewport(tester, const Size(1440, 900));
      final store = _store(view: view);
      await tester.pumpWidget(_app(store, const Workspace()));
      await tester.pump(const Duration(milliseconds: 150));

      _expectSharedChrome();
      // 插件工作台没有设计左栏：板/图层/文档都是设计面的内容，插件有自己的
      // 46px 工具条（保留在内容顶部）。
      expect(find.byType(LeftPanel), findsNothing, reason: '插件工作台不挂设计左栏');
      // 插件内容在主区槽里，且铺满主区（不另起整页 Scaffold、不重复标题栏/
      // 状态栏）。
      final plugin = _pluginContent(view);
      expect(
        find.descendant(of: find.byType(WorkspaceMainArea), matching: plugin),
        findsOneWidget,
        reason: '插件工作台落在主区槽内',
      );
      expect(tester.getRect(plugin), tester.getRect(find.byType(WorkspaceMainArea)),
          reason: '插件内容铺满主区（与设计画布同一块区域）');
      // 设计画布组件不得在插件视图里出现（主区只换人，不是叠加）。
      expect(find.byType(CanvasView), findsNothing, reason: '插件主区不渲染设计画布');
      expect(tester.takeException(), isNull);
    });
  }

  // ---- 2. 桌面 / iPad 横屏：插件留在 DesktopShell，右侧 NaN 窄栏常驻 ------

  testWidgets('桌面壳：plugin:three 带右侧 NaN 窄栏 + 统一外壳', (tester) async {
    _setViewport(tester, const Size(1440, 900));
    final store = _store(view: 'plugin:three', project: true);
    await tester.pumpWidget(_app(
      store,
      ShellHost(capabilities: PlatformCapabilities.forOs(HostOs.macos)),
    ));
    await tester.pump(const Duration(milliseconds: 120));

    expect(find.byType(DesktopShell), findsOneWidget);
    expect(find.byType(ChatPiPShell), findsNothing);
    // 用户裁决 2026-11-18：插件工作台不是主页，右侧 NaN 窄栏常驻、不折叠。
    expect(find.byKey(const ValueKey('desktop-chat-rail')), findsOneWidget,
        reason: '桌面壳右侧 NaN 窄栏常驻');
    expect(find.byType(ChatRail), findsOneWidget);
    // 插件不是主页：插件视图必须占住主面（不能回落到 Welcome）。
    expect(find.byType(Workspace), findsOneWidget);
    _expectSharedChrome();
    expect(
      find.descendant(
        of: find.byType(WorkspaceMainArea),
        matching: find.byType(ThreeWorkspace),
      ),
      findsOneWidget,
      reason: '插件内容在桌面壳主区内',
    );
    expect(tester.takeException(), isNull);
  });

  // ---- 3. 手机 / iPad 竖屏：ChatPiPShell 整屏插件工作区 -------------------

  testWidgets('手机竖屏：ChatPiPShell 整屏渲染插件工作区，无桌面窄栏', (tester) async {
    _setViewport(tester, const Size(390, 844));
    final store = _store(view: 'plugin:video', project: true);
    await tester.pumpWidget(_app(
      store,
      ShellHost(capabilities: PlatformCapabilities.forOs(HostOs.ios)),
    ));
    await tester.pump(const Duration(milliseconds: 150));

    expect(find.byType(ChatPiPShell), findsOneWidget, reason: '手机竖屏走聊天优先壳');
    expect(find.byType(DesktopShell), findsNothing);
    // 插件工作区是整屏主面，不是画中画浮窗。
    expect(find.byType(PipWindow), findsNothing);
    expect(find.byKey(const ValueKey('pip-edge-capsule')), findsNothing);
    expect(find.byKey(const ValueKey('desktop-chat-rail')), findsNothing,
        reason: '手机壳没有桌面右栏');
    expect(find.byType(Workspace), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(WorkspaceMainArea),
        matching: find.byType(VideoWorkspace),
      ),
      findsOneWidget,
      reason: '整屏插件内容在主区内',
    );
    expect(tester.takeException(), isNull);
  });
}
