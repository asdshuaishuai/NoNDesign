// iPad 布局回归：三档断点（手机 <700 / 平板 700–1024 / 宽屏 ≥1024）。
// - 平板竖屏 768：左栏常驻、右栏折叠为底部 sheet、Welcome 走双栏；
// - 平板横屏 1024：三栏全开、底部 sheet 条消失；
// - 字体在平板上 +5%（responsiveTextScale），一并验证无溢出。
//
// 批次 12 追加：iPad 横版进桌面壳（工作区优先 + 右侧唯一聊天窄栏），
// Workspace 自带 348 右栏必须关掉（showRightPanel:false）；竖屏仍是
// 聊天优先壳（裁决 C）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/platform_capabilities.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/widgets/chat_pip_shell.dart';
import 'package:nondesign/widgets/desktop_shell.dart';
import 'package:nondesign/widgets/hotapp_workspace.dart';
import 'package:nondesign/widgets/portfolio_view.dart';
import 'package:nondesign/widgets/right_panel.dart';
import 'package:nondesign/widgets/settings_dialog.dart';
import 'package:nondesign/widgets/shell_host.dart';
import 'package:nondesign/widgets/three_workspace.dart';
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
    expect(find.text('还没有画板——让 NaN 生成，或点面板顶部 ＋ 新建。'), findsOneWidget);
    expect(find.text('项目面板'), findsNothing);
    expect(find.text('NaN 面板'), findsOneWidget);
  });

  testWidgets('iPad landscape opens all three panes', (tester) async {
    final store = _store(project: true)..view = 'design';
    await _pumpAt(tester, const Workspace(), _tabletLandscape, store: store);
    expect(find.text('还没有画板——让 NaN 生成，或点面板顶部 ＋ 新建。'), findsOneWidget);
    expect(find.text('项目面板'), findsNothing);
    expect(find.text('NaN 面板'), findsNothing);
  });

  testWidgets('video workspace is a full-bleed player on iPad', (tester) async {
    await _pumpAt(tester, const Scaffold(body: VideoWorkspace()), _tabletPortrait);
    // 代码动画版：播放面铺满主区，编辑类动作收进 46px 工具条（不再有常驻侧栏）。
    expect(find.byKey(const ValueKey('video-animation-surface')), findsOneWidget);
    expect(find.byKey(const ValueKey('video-sample-picker')), findsOneWidget);
    final playerRect = tester.getRect(find.byKey(const ValueKey('video-animation-surface')));
    expect(playerRect.width, greaterThan(_tabletPortrait.width * 0.9),
        reason: '播放器应当铺满工作台主区，而不是被右侧栏挤窄');
    expect(playerRect.height, greaterThan(_tabletPortrait.height * 0.8),
        reason: '播放器应当占满主区高度');
    // 帧率是工具条弹层：同一时刻只有播放器自己那根时间滑条。
    expect(find.byType(Slider), findsOneWidget);
    // iPad 竖屏宽度放不下全部文字标签：低频动作在 ⋯ 菜单里，仍然可达。
    expect(find.byKey(const ValueKey('video-more-menu')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('video-more-menu')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('编辑脚本'), findsOneWidget, reason: '⋯ 菜单里仍能编辑脚本');
    expect(find.textContaining('帧率'), findsWidgets, reason: '⋯ 菜单里仍能改帧率');
    // 没有任何渲染/导出入口。
    expect(find.text('渲染（后台）'), findsNothing);
    expect(find.textContaining('手机上不能出片'), findsNothing);
  });

  testWidgets('video workspace shows full labels on iPad landscape', (tester) async {
    await _pumpAt(tester, const Scaffold(body: VideoWorkspace()), _tabletLandscape);
    // 横屏宽度够：示例 / 帧率 / 编辑脚本 / 对照 / 加载示例 全部在工具条上露面。
    expect(find.text('编辑脚本'), findsOneWidget);
    expect(find.text('规范对照'), findsOneWidget);
    expect(find.text('加载示例'), findsOneWidget);
    expect(find.byKey(const ValueKey('video-more-menu')), findsNothing);
  });

  testWidgets('热应用 and portfolio fit iPad portrait', (tester) async {
    await _pumpAt(tester, const Scaffold(body: HotAppWorkspace()), _tabletPortrait);
    await _pumpAt(tester, const Scaffold(body: PortfolioView()), _tabletPortrait);
  });

  testWidgets('3D workspace uses the two-row chrome on iPad portrait', (tester) async {
    final store = _store()..settings.threeProjectName = 'demo';
    await _pumpAt(tester, const Scaffold(body: ThreeWorkspace()), _tabletPortrait, store: store);
    expect(find.byKey(const ValueKey('three-header-portrait')), findsOneWidget);
    expect(find.byKey(const ValueKey('three-header-landscape')), findsNothing);
    expect(find.byKey(const ValueKey('three-body-split')), findsNothing);
  });

  testWidgets('3D workspace fits iPad 11 portrait', (tester) async {
    final store = _store()..settings.threeProjectName = 'saturn-demo';
    await _pumpAt(tester, const Scaffold(body: ThreeWorkspace()), const Size(834, 1194), store: store);
    expect(find.byKey(const ValueKey('three-header-portrait')), findsOneWidget);
    expect(find.text('项目'), findsOneWidget);
    expect(find.text('生成当前层'), findsOneWidget);
  });

  testWidgets('iPad 11 landscape keeps full action labels and split side pane', (tester) async {
    final store = _store()..settings.threeProjectName = 'saturn-demo';
    await _pumpAt(tester, const Scaffold(body: ThreeWorkspace()), const Size(1194, 834), store: store);
    expect(find.byKey(const ValueKey('three-header-landscape')), findsOneWidget);
    expect(find.byKey(const ValueKey('three-header-portrait')), findsNothing);
    expect(find.text('截图'), findsOneWidget);
    expect(find.text('源码'), findsOneWidget);
    expect(find.byTooltip('3D 操作'), findsNothing);

    await tester.tap(find.text('源码'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('three-body-split')), findsOneWidget);
  });

  testWidgets('3D workspace uses one-row chrome + side pane on iPad landscape', (tester) async {
    final store = _store()..settings.threeProjectName = 'demo';
    await _pumpAt(tester, const Scaffold(body: ThreeWorkspace()), _tabletLandscape, store: store);
    expect(find.byKey(const ValueKey('three-header-landscape')), findsOneWidget);
    expect(find.byKey(const ValueKey('three-header-portrait')), findsNothing);
    expect(find.text('项目'), findsOneWidget);
    expect(find.text('生成当前层'), findsOneWidget);

    // 横屏下源码/规范是预览侧栏，不是把预览整块替换掉。
    await tester.tap(find.byTooltip('3D 操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('源码（侧栏）'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('three-body-split')), findsOneWidget);
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
    // 入场 fade+scale（0.965→1.0）：首帧量尺寸会整体缩水 3.5%（44→42.46），
    // 再泵一帧等动画收束（本文件从 settings-1 起有尺寸断言）。
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('模型与端点'), findsOneWidget);
    // iPad 同样属于移动端：第三方智能体入口隐藏。
    expect(find.text('外部智能体'), findsNothing);
  });

  testWidgets('settings uses top tabs on iPad portrait', (tester) async {
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
    // 入场 fade+scale（0.965→1.0）：首帧量尺寸会整体缩水 3.5%（44→42.46），
    // 再泵一帧等动画收束（本文件从 settings-1 起有尺寸断言）。
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('settings-topnav')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-rail')), findsNothing);
    // settings-1：触屏（iPad 竖屏）顶部 tab 与关闭按钮命中区都 ≥44。
    final tab = tester.getRect(find.byKey(const ValueKey('settings-nav-models')));
    expect(tab.height, greaterThanOrEqualTo(44), reason: 'iPad 顶部 tab 触控目标 ≥44');
    final close = tester.getRect(find.byTooltip('关闭'));
    expect(close.width, greaterThanOrEqualTo(44), reason: '关闭按钮命中区 ≥44');
    expect(close.height, greaterThanOrEqualTo(44));
  });

  testWidgets('settings uses the side rail on iPad landscape', (tester) async {
    tester.view.physicalSize = _tabletLandscape;
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
    // 入场 fade+scale（0.965→1.0）：首帧量尺寸会整体缩水 3.5%（44→42.46），
    // 再泵一帧等动画收束（本文件从 settings-1 起有尺寸断言）。
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('settings-rail')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-topnav')), findsNothing);
    // settings-1：iPad 横屏侧栏项同样按触屏目标 44。
    final item = tester.getRect(find.byKey(const ValueKey('settings-nav-models')));
    expect(item.height, greaterThanOrEqualTo(44), reason: 'iPad 侧栏项触控目标 ≥44');
  });

  testWidgets('settings stays full-screen on phone landscape', (tester) async {
    tester.view.physicalSize = const Size(844, 390);
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
    // 入场 fade+scale（0.965→1.0）：首帧量尺寸会整体缩水 3.5%（44→42.46），
    // 再泵一帧等动画收束（本文件从 settings-1 起有尺寸断言）。
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    // 手机横屏（844×390）同样走移动端独立布局（分组根页），不再挤顶部 tab。
    expect(find.byKey(const ValueKey('settings-mobile-root')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-topnav')), findsNothing);
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
    // 入场 fade+scale（0.965→1.0）：首帧量尺寸会整体缩水 3.5%（44→42.46），
    // 再泵一帧等动画收束（本文件从 settings-1 起有尺寸断言）。
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    expect(find.text('外部智能体'), findsOneWidget);
    // 非触屏（macOS）维持紧凑密度：关闭命中区仍是 26——触屏 ≥44 的规则
    // 不得外溢到桌面（settings-1 的反向锚点）。
    final close = tester.getRect(find.byTooltip('关闭'));
    expect(close.width, lessThan(44));
  });

  // ---- 批次 12：iPad 横/竖的壳裁决 ---------------------------------------

  Widget shellWrap(AppStore store, HostOs os) => ChangeNotifierProvider<AppStore>.value(
        value: store,
        child: MaterialApp(
          theme: AppTheme.build(dark: true),
          builder: (context, child) =>
              withResponsiveTextScale(context, child ?? const SizedBox.shrink()),
          home: ShellHost(capabilities: PlatformCapabilities.forOs(os)),
        ),
      );

  Future<void> pumpShell(WidgetTester tester, AppStore store, Size size, HostOs os) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(shellWrap(store, os));
    await tester.pump(const Duration(milliseconds: 80));
  }

  testWidgets('iPad 横版 1024×768 → DesktopShell：Workspace 主面 + 右侧唯一窄栏', (tester) async {
    final store = _store(project: true)..view = 'design';
    await pumpShell(tester, store, _tabletLandscape, HostOs.ios);

    expect(find.byType(DesktopShell), findsOneWidget);
    expect(find.byType(ChatPiPShell), findsNothing);
    expect(find.byType(Workspace), findsOneWidget);
    final ws = tester.widget<Workspace>(find.byType(Workspace));
    expect(ws.showRightPanel, isFalse, reason: '348 右栏必须让位给唯一窄栏');
    expect(find.byType(RightPanel), findsNothing);
    expect(find.byKey(const ValueKey('desktop-chat-rail-strip')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('iPad 竖版 768×1024 → ChatPiPShell（裁决 C，禁止桌面壳）', (tester) async {
    final store = _store(project: true)..view = 'design';
    await pumpShell(tester, store, _tabletPortrait, HostOs.ios);

    expect(find.byType(ChatPiPShell), findsOneWidget);
    expect(find.byType(DesktopShell), findsNothing);
    expect(find.byKey(const ValueKey('desktop-chat-rail')), findsNothing);
    expect(find.byKey(const ValueKey('chat-input')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Workspace(showRightPanel:false) 不渲染 348 RightPanel；默认仍渲染', (tester) async {
    final store = _store(project: true)..view = 'design';
    await _pumpAt(tester, const Workspace(showRightPanel: false), _tabletLandscape, store: store);
    expect(find.byType(RightPanel), findsNothing);
    expect(find.text('还没有画板——让 NaN 生成，或点面板顶部 ＋ 新建。'), findsOneWidget,
        reason: '画布主面仍在');

    await _pumpAt(tester, const Workspace(), _tabletLandscape, store: store);
    expect(find.byType(RightPanel), findsOneWidget, reason: '独立 Workspace 默认保留右栏');
  });
}
