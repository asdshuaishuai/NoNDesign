// 设计 + 3D 工作台内容区响应式回归（task-19）。
//
// 目标：900（窄 PC）/ 1280（中）/ 1600（宽）三档窗口尺寸下，两个工作台的
// 内容区都不得出现 RenderFlex overflow 或其它布局异常；面板必须按
// `core/workbench_layout.dart` 的规格出现/收起：
//
//   * 设计面（spec：leftDock ≥700、rightDock ≥1024）：
//       - 三档左栏都常驻，宽度取规格 leftWidth（252，不再是 widget 里写死）；
//       - 900（<1024）右栏折叠成底部入口（窄条「NaN 面板」），1280/1600 常驻；
//       - 面板头部统一高度 44（workspaceHeaderHeight）与 NonType.bodyStrong 标题。
//   * 3D（spec：leftDock ≥900、rightDock ≥1024、bottomBar 34）：
//       - 900：左大纲常驻，右检查器仍走 sheet；≥1024：大纲 | 视口 | 检查器三栏；
//       - 视口控制浮层只在 isWide（右栏常驻）时出现；
//       - 面板头 44（panelHeaderHeight），状态条高度取规格 bottomBarHeight；
//       - 工具条开关能真实收起/恢复大纲（宽度不变时不叠黄条）。
//
// 纪律（与任务约定一致）：
//   * **不构造真 WebView**：3D 用 `debugThreeWebViewSupported = false` 走
//     「这台设备不能内嵌 3D 预览」的真实降级面，三栏/大纲/检查器/状态条
//     仍是生产 widget；
//   * store / services 全部是测试替身：设计面用内存 AppStore，3D 用临时目录
//     + 假 llm/assets 的 ThreeService（不读用户磁盘、不联网）；
//   * 布局期异常全部收上来断言为空（失败信息里会带 "overflowed" 字样）。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nondesign/core/capability_hub.dart';
import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/platform_capabilities.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/core/toast_service.dart';
import 'package:nondesign/core/three_service.dart';
import 'package:nondesign/core/workbench_layout.dart';
import 'package:nondesign/widgets/aqua.dart';
import 'package:nondesign/widgets/canvas_view.dart';
import 'package:nondesign/widgets/left_panel.dart';
import 'package:nondesign/widgets/three_workbench_panels.dart';
import 'package:nondesign/widgets/three_workspace.dart';
import 'package:nondesign/widgets/workspace.dart';
import 'package:nondesign/widgets/workspace_inspector.dart';

/// 三档窗口尺寸（宽度语义与两个工作台的 WorkbenchLayout 断点对齐）。
const List<Size> _viewports = <Size>[
  Size(900, 700),
  Size(1280, 800),
  Size(1600, 1000),
];

// ---------------------------------------------------------------------------
// 公共 fixture
// ---------------------------------------------------------------------------

void _setViewport(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget _host(AppStore store, Widget child, {bool dark = true}) =>
    ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(
        theme: AppTheme.build(dark: dark),
        home: child,
      ),
    );

/// 把布局期抛出的异常全部收上来：任何一条（尤其 RenderFlex overflow）都算
/// 失败。`takeException()` 只返回第一条，所以循环取到 null 为止。
void _expectNoLayoutException(WidgetTester tester, String label) {
  final List<String> errors = <String>[];
  Object? error;
  while ((error = tester.takeException()) != null) {
    errors.add('$error');
  }
  expect(
    errors,
    isEmpty,
    reason: '$label 渲染出现布局异常（含 overflow）：\n${errors.join('\n---\n')}',
  );
}

/// 面板头部标题的档位必须统一（标题 > 关键值 > 说明的第一级）。
void _expectPanelTitleIsTier(WidgetTester tester, Key headKey) {
  final Finder head = find.byKey(headKey);
  final Text title = tester.widget<Text>(
    find.descendant(of: head, matching: find.byType(Text)).first,
  );
  expect(
    title.style?.fontSize,
    NonType.bodyStrong,
    reason: '$headKey 的标题档位应为 NonType.bodyStrong',
  );
}

// ---------------------------------------------------------------------------
// 设计面 fixture（与 design_focus_mode_test 同形：内存 store，不碰引擎）
// ---------------------------------------------------------------------------

AppStore _designStore() {
  final AppStore store = AppStore()
    ..ready = true
    ..hasProject = true
    ..view = 'design'
    ..settings = AppSettings(
      providerId: 'deepseek',
      modelId: 'deepseek-v4.1-flash',
    );
  store.registry = const ModelRegistry(
    providers: <String, Object>{},
    fetchedAt: '',
  );
  return store;
}

// ---------------------------------------------------------------------------
// 3D 面 fixture（临时目录 + 假 llm/assets；不构造 WebView）
// ---------------------------------------------------------------------------

Map<String, dynamic> _legacySpec() => <String, dynamic>{
  'title': 'Saturn',
  'summary': '带环行星自转',
  'components': <Map<String, dynamic>>[
    <String, dynamic>{'id': 'planet', 'what': '球体', 'size_scale': 1.0},
    <String, dynamic>{'id': 'ring', 'what': '扁平圆环', 'size_scale': 1.8},
  ],
  'materials': <Map<String, dynamic>>[
    <String, dynamic>{'id': 'rock', 'color_hex': '#c9a06a'},
  ],
  'acceptance': <String>['行星在场', '环可见 ≤2mm'],
};

void _seedProject(Directory root, String name) {
  final Directory dir = Directory('${root.path}/$name')
    ..createSync(recursive: true);
  File('${dir.path}/three-spec.json')
      .writeAsStringSync(jsonEncode(_legacySpec()));
  File('${dir.path}/scene.js')
      .writeAsStringSync('export default function build() { return {}; }\n');
  File('${dir.path}/build-state.json').writeAsStringSync(
    jsonEncode(<String, Object?>{
      'current': 'structure',
      'blocked': false,
      'passes': <Object?>[],
    }),
  );
}

ThreeService _threeService(Directory root) => ThreeService(
  root: root,
  llm: (request) async => throw const ThreeFailure('llm_error', 'unused'),
  // 空资产字节：组件清单解析失败会在 widget 内被 catch 成可读的清单错误，
  // 本用例只验证布局，不依赖组件画廊内容。
  assets: (_) async => Uint8List(0),
);

AppStore _threeStore() =>
    AppStore(
        toasts: ToastService(autoDismiss: false),
        // flutter_test 默认平台是 android；显式钉桌面，语义与生产桌面壳一致。
        capabilities: CapabilityHub(
          platform: PlatformCapabilities.forOs(HostOs.macos),
        ),
      )
      ..ready = true
      ..view = 'plugin:three'
      ..settings = AppSettings(
        providerId: 'deepseek',
        modelId: 'deepseek-v4.1-flash',
        baseUrl: 'https://api.example.com/v1',
        apiKey: 'test-key',
      );

Widget _threeHost(AppStore store, ThreeService service) =>
    ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(
        theme: AppTheme.build(dark: true),
        home: Scaffold(body: ThreeWorkspace(service: service)),
      ),
    );

/// 真 IO（项目读盘）要走 runAsync 才推得动；faked clock 下不能 pumpAndSettle
/// （空态/清单的加载指示是无限动画）。
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
  }
  await tester.pump(const Duration(milliseconds: 120));
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  // -------------------------------------------------------------------------
  // 设计工作台
  // -------------------------------------------------------------------------

  group('设计工作台响应式（900/1280/1600）', () {
    for (final Size size in _viewports) {
      testWidgets('${size.width.toInt()} 宽：无溢出，左右面板按规格出现/收起', (tester) async {
        _setViewport(tester, size);
        final AppStore store = _designStore();
        await tester.pumpWidget(_host(store, const Workspace()));
        await tester.pump(const Duration(milliseconds: 200));
        _expectNoLayoutException(tester, '设计 ${size.width.toInt()} 宽');

        final WorkbenchLayout layout = resolveWorkbenchLayout(
          kind: WorkbenchKind.design,
          width: size.width,
          height: size.height,
        );
        // 左栏三档都常驻，宽度取规格（252），不再是 widget 里写死。
        expect(find.byType(LeftPanel), findsOneWidget);
        expect(tester.getSize(find.byType(LeftPanel)).width, layout.leftWidth);
        expect(find.byType(CanvasView), findsOneWidget, reason: '画布始终在主区');
        // 右栏：≥1024 常驻；<1024 折叠成底部入口（「NaN 面板」窄条）。
        expect(
          find.byType(WorkspaceRightPanel),
          layout.isWide ? findsOneWidget : findsNothing,
        );
        expect(
          find.text('NaN 面板'),
          layout.isWide ? findsNothing : findsOneWidget,
          reason: '窄档右栏入口 = 底部窄条，不允许同时常驻两栏',
        );
        // 面板头统一：高度 + 标题档位。
        final Finder head = find.byKey(const ValueKey('panel-head-画板'));
        expect(head, findsOneWidget);
        expect(tester.getSize(head).height, workspaceHeaderHeight);
        _expectPanelTitleIsTier(tester, const ValueKey('panel-head-画板'));
      });
    }

    testWidgets('浅色（Aqua）1280：主区套细条纹窗口面且无溢出', (tester) async {
      _setViewport(tester, const Size(1280, 800));
      final AppStore store = _designStore();
      await tester.pumpWidget(_host(store, const Workspace(), dark: false));
      await tester.pump(const Duration(milliseconds: 200));
      _expectNoLayoutException(tester, '设计 Aqua 1280');
      expect(
        find.byType(AquaWindowSurface),
        findsWidgets,
        reason: '浅色 = Aqua：主区/画布应套 AquaWindowSurface 细化纹理',
      );
    });
  });

  // -------------------------------------------------------------------------
  // 3D 工作台
  // -------------------------------------------------------------------------

  group('3D 工作台响应式（900/1280/1600）', () {
    late Directory temp;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('nondesign-resp-3d-');
    });

    tearDown(() async {
      threeLoadOnOpen = null;
      debugThreeWebViewSupported = null;
      await temp.delete(recursive: true);
    });

    for (final Size size in _viewports) {
      testWidgets('${size.width.toInt()} 宽：无溢出，大纲/检查器按规格出现/收起', (tester) async {
        _seedProject(temp, 'saturn');
        final ThreeService service = _threeService(temp);
        final AppStore store = _threeStore();
        // 不构造真 WebView：走真实「无内嵌预览」降级面，但三栏与面板仍是生产 widget。
        debugThreeWebViewSupported = false;
        threeLoadOnOpen = 'saturn';
        _setViewport(tester, size);
        await tester.pumpWidget(_threeHost(store, service));
        await _settle(tester);
        _expectNoLayoutException(tester, '3D ${size.width.toInt()} 宽');

        final WorkbenchLayout layout = resolveWorkbenchLayout(
          kind: WorkbenchKind.three,
          width: size.width,
          height: size.height,
        );
        expect(
          find.byKey(const ValueKey('three-header-landscape')),
          findsOneWidget,
          reason: '900+ 不是手机档，头部是单行工具栏',
        );
        expect(
          find.byKey(const ValueKey('three-body-three-pane')),
          findsOneWidget,
          reason: '左栏/右栏至少一侧常驻 → 三栏容器必须在',
        );

        final Finder outliner = find.byKey(
          const ValueKey('three-workbench-outliner'),
        );
        final Finder inspector = find.byKey(
          const ValueKey('three-workbench-inspector'),
        );
        expect(
          outliner,
          layout.left == PanelPolicy.docked ? findsOneWidget : findsNothing,
        );
        expect(
          inspector,
          layout.right == PanelPolicy.docked ? findsOneWidget : findsNothing,
          reason: '900 右检查器仍走 sheet；≥1024 才常驻',
        );
        if (layout.left == PanelPolicy.docked) {
          expect(tester.getSize(outliner).width, layout.leftWidth);
          expect(
            tester
                .getSize(find.byKey(const ValueKey('three-outliner-head')))
                .height,
            panelHeaderHeight,
          );
          _expectPanelTitleIsTier(
            tester,
            const ValueKey('three-outliner-head'),
          );
        }
        if (layout.right == PanelPolicy.docked) {
          expect(tester.getSize(inspector).width, layout.rightWidth);
          expect(
            tester
                .getSize(find.byKey(const ValueKey('three-inspector-head')))
                .height,
            panelHeaderHeight,
          );
          _expectPanelTitleIsTier(
            tester,
            const ValueKey('three-inspector-head'),
          );
        }

        // 底部状态条：高度只从 WorkbenchLayout 规格来（不再写死 30）。
        final Finder status = find.byKey(
          const ValueKey('three-workbench-status'),
        );
        expect(status, findsOneWidget);
        expect(
          tester.getSize(status).height,
          layout.bottomBarHeight,
          reason: '状态条高度必须等于规格 bottomBarHeight',
        );

        // 视口控制浮层只在 isWide（右栏常驻）时叠在视口上。
        expect(
          find.byKey(const ValueKey('three-viewport-stack')),
          layout.isWide ? findsOneWidget : findsNothing,
        );
      });
    }

    testWidgets('1280：大纲开关真实收起/恢复（面板宽度不叠黄条）', (tester) async {
      _seedProject(temp, 'saturn');
      final ThreeService service = _threeService(temp);
      final AppStore store = _threeStore();
      debugThreeWebViewSupported = false;
      threeLoadOnOpen = 'saturn';
      _setViewport(tester, const Size(1280, 800));
      await tester.pumpWidget(_threeHost(store, service));
      await _settle(tester);
      _expectNoLayoutException(tester, '3D 1280 开关');

      final Finder outliner = find.byKey(
        const ValueKey('three-workbench-outliner'),
      );
      expect(outliner, findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('three-toggle-outliner')));
      await tester.pump();
      expect(outliner, findsNothing, reason: '工具条开关应真实收起大纲');
      expect(
        find.byKey(const ValueKey('three-workbench-inspector')),
        findsOneWidget,
        reason: '只收大纲，检查器不受影响',
      );
      _expectNoLayoutException(tester, '3D 1280 收起大纲后');

      await tester.tap(find.byKey(const ValueKey('three-toggle-outliner')));
      await tester.pump();
      expect(outliner, findsOneWidget, reason: '再点一次恢复大纲');
      _expectNoLayoutException(tester, '3D 1280 恢复大纲后');
    });

    testWidgets('浅色（Aqua）1280：3D 主区套细条纹窗口面且无溢出', (tester) async {
      _seedProject(temp, 'saturn');
      final ThreeService service = _threeService(temp);
      final AppStore store = _threeStore();
      debugThreeWebViewSupported = false;
      threeLoadOnOpen = 'saturn';
      _setViewport(tester, const Size(1280, 800));
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStore>.value(
          value: store,
          child: MaterialApp(
            theme: AppTheme.build(dark: false),
            home: Scaffold(body: ThreeWorkspace(service: service)),
          ),
        ),
      );
      await _settle(tester);
      _expectNoLayoutException(tester, '3D Aqua 1280');
      expect(
        find.byType(AquaWindowSurface),
        findsWidgets,
        reason: '浅色下 3D 主区应套 AquaWindowSurface',
      );
    });
  });

  // -------------------------------------------------------------------------
  // 令牌 / 性能锚点（与 design_tokens_test 的棘轮互补：本任务是「这 6 个文件
  // 必须清零」，不是全局上限）
  // -------------------------------------------------------------------------

  test('6 个文件令牌清零 + 重绘/裁剪锚点在位', () {
    const List<String> files = <String>[
      'lib/widgets/workspace.dart',
      'lib/widgets/left_panel.dart',
      'lib/widgets/inspector_panel.dart',
      'lib/widgets/three_workspace.dart',
      'lib/widgets/three_workbench_panels.dart',
      'lib/widgets/three_viewport_controls.dart',
    ];
    final RegExp rawFontSize = RegExp(r'fontSize: [0-9]');
    final RegExp rawRadius = RegExp(r'BorderRadius\.circular\([0-9]');
    for (final String path in files) {
      final String source = File(path).readAsStringSync();
      expect(
        rawFontSize.hasMatch(source),
        isFalse,
        reason: '$path 仍有裸 fontSize 字面量（应改用 NonType）',
      );
      expect(
        rawRadius.hasMatch(source),
        isFalse,
        reason: '$path 仍有裸 BorderRadius 字面量（应改用 NonRadius）',
      );
    }
    // 两个面板头高度是同一档（设计面 workspaceHeaderHeight / 3D panelHeaderHeight）。
    expect(panelHeaderHeight, workspaceHeaderHeight);
    expect(panelHeaderHeight, 44);
    // WebView 宿主：必须 ClipRRect 裁剪 + RepaintBoundary 隔离父级重绘。
    final String three = File('lib/widgets/three_workspace.dart')
        .readAsStringSync();
    expect(three.contains('ClipRRect'), isTrue);
    expect(three.contains('RepaintBoundary'), isTrue);
    expect(three.contains('RepaintBoundary(child: WebViewWidget'), isTrue);
    // 可见的 WebViewWidget 出现点（主预览 + 组件预览弹窗）都在 RepaintBoundary 内。
    expect(RegExp(r'WebViewWidget\(').allMatches(three).length >= 2, isTrue);
    // 画布主区外包 RepaintBoundary；列表用 itemExtent 固定行高。
    expect(
      File('lib/widgets/workspace.dart')
          .readAsStringSync()
          .contains('RepaintBoundary(child: canvas)'),
      isTrue,
    );
    expect(
      File('lib/widgets/three_workbench_panels.dart')
          .readAsStringSync()
          .contains('itemExtent'),
      isTrue,
    );
  });
}
