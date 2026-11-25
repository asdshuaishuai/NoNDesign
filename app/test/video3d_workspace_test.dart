// 3D 视频工作台回归（task-10）：
//
//   * 插件注册表 / 视图映射 / 打开通道（openVideo3dWorkspace + 作品集入口）；
//   * 工作台：项目列表、空态、坏项目/未过校验项目显性人话、选中项目切预览、
//     只读检查器数值、底部镜头时间线按帧表比例、运输条禁用原因；
//   * 顶栏项目菜单「3D 视频工作台」入口 + _activeProject 显示。
//
// 不构造真 WebView：工作台注入 Fake 预览控制器（戳穿真 WebView 的路径由
// video3d_preview_surface_test.dart 覆盖）。
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/portfolio_entries.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/core/toast_service.dart';
import 'package:nondesign/core/video3d/video3d_compile.dart';
import 'package:nondesign/core/video3d/video3d_contract.dart';
import 'package:nondesign/core/video3d/video3d_project.dart';
import 'package:nondesign/core/workbench_layout.dart';
import 'package:nondesign/plugins/registry.dart';
import 'package:nondesign/widgets/title_bar.dart';
import 'package:nondesign/widgets/video3d_preview_surface.dart';
import 'package:nondesign/widgets/video3d_workspace.dart';
import 'package:nondesign/widgets/workspace_open.dart';

// ---------------------------------------------------------------------------
// Fixtures：契约层合法输入（与 video3d_project_test 同族）。
// ---------------------------------------------------------------------------

Map<String, Object?> _validScene({String secondNodeId = 'table'}) =>
    <String, Object?>{
      'v': 1,
      'units': 'm',
      'environment': <String, Object?>{'background': '#0b0d12'},
      'nodes': <Object?>[
        <String, Object?>{
          'id': 'floor',
          'type': 'box',
          'size': <double>[10, 0.1, 10],
          'position': <double>[0, -0.05, 0],
          'material': <String, Object?>{
            'color': '#9a8c7a',
            'roughness': 0.9,
            'metalness': 0.0,
          },
        },
        <String, Object?>{
          'id': secondNodeId,
          'type': 'plane',
          'size': <double>[2, 1, 0],
          'position': <double>[0, 0.5, 0],
          'parent': 'floor',
        },
        <String, Object?>{
          'id': 'lamp',
          'type': 'sphere',
          'size': <double>[0.12, 0.12, 0.12],
        },
      ],
      'lights': <Object?>[
        <String, Object?>{
          'id': 'key',
          'type': 'directional',
          'intensity': 1.0,
          'color': '#ffffff',
          'position': <double>[4, 6, 4],
          'target': <double>[0, 0, 0],
        },
        <String, Object?>{'type': 'ambient', 'intensity': 0.2},
      ],
      'cameras': <Object?>[
        <String, Object?>{
          'id': 'hero',
          'position': <double>[4, 2, 4],
          'target': <double>[0, 1, 0],
          'fov': 45,
        },
      ],
    };

Map<String, Object?> _validScreenplay({String cameraId = 'hero'}) =>
    <String, Object?>{
      'v': 1,
      'fps': 30,
      'format': <String, Object?>{'width': 720, 'height': 1280},
      'shots': <Object?>[
        <String, Object?>{
          'id': 's1',
          'duration': 5.0,
          'camera': <String, Object?>{'id': cameraId},
        },
        <String, Object?>{
          'id': 's2',
          'duration': 3.0,
          'camera': <String, Object?>{'id': cameraId},
        },
      ],
    };

String _prettyJson(Object? value) =>
    '${const JsonEncoder.withIndent('  ').convert(value)}\n';

void _writeProjectJson(Directory root, String name, Map<String, Object?> json) {
  Directory('${root.path}/$name').createSync(recursive: true);
  File('${root.path}/$name/scene3d.json').writeAsStringSync(_prettyJson(json));
}

Video3dTimeline _timelineOf(
  Map<String, Object?> scene,
  Map<String, Object?> screenplay,
) {
  final Video3dVerification verification = verifyVideo3d(scene, screenplay);
  return compileVideo3dTimeline(verification.screenplay!);
}

// ---------------------------------------------------------------------------
// Fake 预览控制器（不构造真 WebView）。
// ---------------------------------------------------------------------------

class _FakePreview extends Video3dPreviewController {
  _FakePreview({required this.fps, required this.totalFrames});

  @override
  final int fps;

  @override
  final int totalFrames;

  bool disposed = false;
  bool _ready = false;
  bool _playing = false;
  int _frame = 0;
  final String _loadError = '';
  final String _technicalDetail = '';

  int playCalls = 0;
  int pauseCalls = 0;
  int stopCalls = 0;
  final List<int> seekFrameCalls = <int>[];

  @override
  bool get ready => _ready;

  @override
  bool get playing => _playing;

  @override
  int get frame => _frame;

  @override
  String get loadError => _loadError;

  @override
  String get technicalDetail => _technicalDetail;

  @override
  Future<void> start() async {
    _ready = true;
    notifyListeners();
  }

  @override
  Future<void> play() async {
    playCalls += 1;
    _playing = true;
    notifyListeners();
  }

  @override
  Future<void> pause() async {
    pauseCalls += 1;
    _playing = false;
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    stopCalls += 1;
    _playing = false;
    _frame = 0;
    notifyListeners();
  }

  @override
  Future<void> seek(double seconds) async {
    _frame = (seconds * fps).floor();
    notifyListeners();
  }

  @override
  Future<void> seekFrame(int frame) async {
    seekFrameCalls.add(frame);
    _frame = frame;
    notifyListeners();
  }

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}

class _Factory {
  final List<_FakePreview> created = <_FakePreview>[];

  Video3dPreviewController call(
    Video3dProjectSnapshot snapshot,
    Video3dTimeline timeline,
  ) {
    final _FakePreview fake = _FakePreview(
      fps: timeline.fps,
      totalFrames: timeline.totalFrames,
    );
    created.add(fake);
    return fake;
  }
}

Widget _app(Widget child) => MaterialApp(
  theme: AppTheme.build(dark: true),
  home: Scaffold(body: child),
);

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 50));
}

void _viewport(WidgetTester tester, {Size size = const Size(1440, 900)}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// 顶栏测试用 store（不碰真实用户目录；与 music_project_follow_test 同族）。
AppStore _store() {
  final AppStore store = AppStore(toasts: ToastService(autoDismiss: false))
    ..ready = true
    ..settings = AppSettings(
      providerId: 'deepseek',
      modelId: 'deepseek-v4.1-flash',
    )
    ..view = 'design';
  store.recoveryDir = Directory.systemTemp
      .createTempSync('nd-video3d-workspace-recovery')
      .path;
  return store;
}

Widget _titleBarApp(AppStore store) => ChangeNotifierProvider<AppStore>.value(
  value: store,
  child: _app(
    TitleBar(
      onCommand: () {},
      onSettings: () {},
      onNewProject: () {},
      onOpenProject: () {},
      onShortcuts: () {},
      onOpenRecent: (_) {},
    ),
  ),
);

void _resetGlobals() {
  video3dLoadOnOpen = null;
}

void main() {
  late Directory temp;
  late Video3dProjectStore projectStore;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _resetGlobals();
    temp = Directory.systemTemp.createTempSync('nd-video3d-workspace-');
    projectStore = Video3dProjectStore(root: temp);
  });

  tearDown(() {
    _resetGlobals();
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  // ---------------------------------------------------------------------------
  // 纯函数 / 布局映射 / 注册表
  // ---------------------------------------------------------------------------

  group('纯函数与映射', () {
    test('时间文案：向零取整秒，非法值按 0:00', () {
      expect(formatVideo3dClock(0), '0:00');
      expect(formatVideo3dClock(8.0), '0:08');
      expect(formatVideo3dClock(125.4), '2:05');
      expect(formatVideo3dClock(double.nan), '0:00');
    });

    test('镜头条按整数帧表比例：5s+3s @30fps → 150/240 + 90/240', () {
      final Video3dTimeline timeline = _timelineOf(
        _validScene(),
        _validScreenplay(),
      );
      final List<double> fractions = video3dShotFractions(timeline);
      expect(fractions, hasLength(2));
      expect(fractions[0], closeTo(150 / 240, 1e-9));
      expect(fractions[1], closeTo(90 / 240, 1e-9));
      expect(fractions[0] + fractions[1], closeTo(1.0, 1e-9));

      const Video3dTimeline empty = Video3dTimeline(
        fps: 30,
        totalFrames: 0,
        durationSeconds: 0.0,
        shots: <Video3dShotFrames>[],
      );
      expect(video3dShotFractions(empty), isEmpty);
    });

    test('注册表：plugin:video3d → 3D 视频工作台（图标/标题/构建器）', () {
      final PluginDef? def = pluginById('video3d');
      expect(def, isNotNull);
      expect(def!.title, '3D 视频工作台');
      expect(def.icon, Icons.movie_creation_outlined);
      expect(def.builder(), isA<Video3dWorkspace>());
      final Widget? workspace = pluginWorkspaceFor('plugin:video3d');
      expect(workspace, isA<Video3dWorkspace>());
      // 既有四个插件工作台不受影响。
      expect(
        pluginRegistry.map((PluginDef d) => d.id),
        containsAll(<String>['three', 'video', 'music', 'hotapp']),
      );
    });

    test('视图映射：plugin:video3d 沿用视频导演台内容区规格（不新增第五份规格）', () {
      expect(workbenchKindForView('plugin:video3d'), WorkbenchKind.video);
      final WorkbenchLayout layout = resolveWorkbenchLayout(
        kind: WorkbenchKind.video,
        width: 1200,
        height: 800,
      );
      expect(layout.left, PanelPolicy.docked);
      expect(layout.right, PanelPolicy.docked);
      expect(layout.bottomBar, isTrue);
      expect(layout.bottomBarHeight, 148);
      expect(workbenchLayoutSpecs, hasLength(4), reason: '既有四工作台规格不动');
    });

    test('openVideo3dWorkspace：name 通道 + 视图；不传 name 清掉通道', () {
      final AppStore store = _store();

      openVideo3dWorkspace(store, '  beta  ');
      expect(store.view, 'plugin:video3d');
      expect(video3dLoadOnOpen, 'beta', reason: '项目名 trim 后交给工作台');

      openVideo3dWorkspace(store);
      expect(store.view, 'plugin:video3d');
      expect(video3dLoadOnOpen, isNull, reason: '不带项目 = 列表首项逻辑');
    });

    test('openPortfolioEntry(kind:video3d) 走同一条打开路由', () {
      final AppStore store = _store();

      openPortfolioEntry(
        store,
        const PortfolioEntry(
          kind: 'video3d',
          ref: 'alpha',
          title: '阿尔法',
          detail: '3D 视频',
        ),
      );

      expect(store.view, 'plugin:video3d');
      expect(video3dLoadOnOpen, 'alpha');
    });
  });

  // ---------------------------------------------------------------------------
  // 工作台内容
  // ---------------------------------------------------------------------------

  group('工作台', () {
    testWidgets('自动打开首项：项目列表、预览面、检查器与镜头时间线比例', (tester) async {
      _viewport(tester);
      await projectStore.save(
        'alpha',
        scene: _validScene(),
        screenplay: _validScreenplay(),
      );
      await projectStore.save(
        'beta',
        scene: _validScene(secondNodeId: 'desk'),
        screenplay: _validScreenplay(),
      );
      final _Factory factory = _Factory();

      await tester.pumpWidget(
        _app(
          Video3dWorkspace(
            projectStore: projectStore,
            previewFactory: factory.call,
          ),
        ),
      );
      await _settle(tester);

      // 左侧项目列表：两项都在，首项自动打开。
      expect(
        find.byKey(const ValueKey('video3d-project-list')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('video3d-project-alpha')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('video3d-project-beta')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('video3d-header')),
          matching: find.textContaining('alpha'),
        ),
        findsOneWidget,
      );

      // 中部预览面：Fake 控制器已创建并启动（不构造真 WebView）。
      expect(factory.created, hasLength(1));
      expect(factory.created.single.ready, isTrue);
      expect(
        find.byKey(const ValueKey('video3d-preview-surface')),
        findsOneWidget,
      );

      // 右侧只读检查器：节点 / 灯光 / 相机 / 镜头 / 时长 / 帧数 / 校验。
      expect(find.byKey(const ValueKey('video3d-inspector')), findsOneWidget);
      expect(find.text('3'), findsWidgets, reason: '场景节点数');
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('video3d-inspector-verify')),
          matching: find.text('通过'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('video3d-inspector-duration')),
          matching: find.text('0:08'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('video3d-inspector-frames')),
          matching: find.text('240'),
        ),
        findsOneWidget,
      );

      // 底部镜头时间线：5s/3s → 150/240 与 90/240 帧，按比例分段。
      expect(find.byKey(const ValueKey('video3d-bottom-bar')), findsOneWidget);
      expect(find.byKey(const ValueKey('video3d-shot-s1')), findsOneWidget);
      expect(find.byKey(const ValueKey('video3d-shot-s2')), findsOneWidget);
      final Size s1 = tester.getSize(
        find.byKey(const ValueKey('video3d-shot-s1')),
      );
      final Size s2 = tester.getSize(
        find.byKey(const ValueKey('video3d-shot-s2')),
      );
      final double ratio = s1.width / (s1.width + s2.width);
      expect(ratio, closeTo(150 / 240, 0.02), reason: '镜头条宽度按帧表比例');

      // 运输条控制面：Fake 的 ready 状态已反映，播放按钮可点。
      expect(
        find.byKey(const ValueKey('video3d-transport-play')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('video3d-transport-play')));
      await tester.pump();
      expect(factory.created.single.playCalls, 1);
      expect(factory.created.single.playing, isTrue);

      // 切项目：旧预览面释放、新预览面按新项目重建。
      await tester.tap(find.byKey(const ValueKey('video3d-project-beta')));
      await _settle(tester);
      expect(factory.created, hasLength(2));
      expect(factory.created.first.disposed, isTrue, reason: '旧预览面必须释放');
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('video3d-header')),
          matching: find.textContaining('beta'),
        ),
        findsOneWidget,
      );

      // 刷新列表：刷新后新项目出现在左侧（不打断当前项目）。
      await projectStore.save(
        'gamma',
        scene: _validScene(secondNodeId: 'shelf'),
        screenplay: _validScreenplay(),
      );
      await tester.tap(find.byKey(const ValueKey('video3d-refresh')));
      await _settle(tester);
      expect(
        find.byKey(const ValueKey('video3d-project-gamma')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('空态：没有项目时显性人话，播放禁用并说明原因', (tester) async {
      _viewport(tester);
      final _Factory factory = _Factory();

      await tester.pumpWidget(
        _app(
          Video3dWorkspace(
            projectStore: projectStore,
            previewFactory: factory.call,
          ),
        ),
      );
      await _settle(tester);

      expect(find.byKey(const ValueKey('video3d-empty')), findsOneWidget);
      expect(find.text('还没有 3D 视频项目'), findsOneWidget);
      expect(factory.created, isEmpty, reason: '没有项目不构造预览面');
      // 播放按钮禁用，并给出人话原因。
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const ValueKey('video3d-transport-play')),
            )
            .onPressed,
        isNull,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('video3d-transport-reason')),
          matching: find.textContaining('还没有选中'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('坏项目：列表保留条目，打开时显性人话 + 折叠技术详情', (tester) async {
      _viewport(tester);
      Directory('${temp.path}/broken').createSync(recursive: true);
      File('${temp.path}/broken/scene3d.json').writeAsStringSync('not json');
      File('${temp.path}/broken/screenplay3d.json').writeAsStringSync('{}');
      final _Factory factory = _Factory();

      await tester.pumpWidget(
        _app(
          Video3dWorkspace(
            projectStore: projectStore,
            previewFactory: factory.call,
          ),
        ),
      );
      await _settle(tester);

      // 坏项目仍在列表里（不拖垮整张表），并标出文件不完整。
      expect(
        find.byKey(const ValueKey('video3d-project-broken')),
        findsOneWidget,
      );
      expect(find.textContaining('文件不完整'), findsWidgets);
      // 自动打开首个（坏）项目：中心给可行动人话，而不是空白/假播放。
      expect(
        find.byKey(const ValueKey('video3d-project-failure')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('video3d-project-failure')),
          matching: find.text('这个 3D 视频项目的场景或镜头文件不完整，可能被手动改坏了'),
        ),
        findsOneWidget,
      );
      expect(factory.created, isEmpty, reason: '坏项目不得构造预览面');
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const ValueKey('video3d-transport-play')),
            )
            .onPressed,
        isNull,
      );
      // 原始诊断折叠在「技术详情」里。
      await tester.tap(find.text('技术详情'));
      await tester.pumpAndSettle();
      expect(find.textContaining('corrupt'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('未过校验项目：明确说明问题数，预览与播放都禁用', (tester) async {
      _viewport(tester);
      // 镜头引用场景里不存在的相机 → verifyVideo3d 不通过（项目文件可读）。
      _writeProjectJson(temp, 'unverified', _validScene());
      File('${temp.path}/unverified/screenplay3d.json')
          .writeAsStringSync(_prettyJson(_validScreenplay(cameraId: 'ghost')));
      final _Factory factory = _Factory();

      await tester.pumpWidget(
        _app(
          Video3dWorkspace(
            projectStore: projectStore,
            previewFactory: factory.call,
          ),
        ),
      );
      await _settle(tester);

      expect(
        find.byKey(const ValueKey('video3d-verification-failed')),
        findsOneWidget,
      );
      expect(find.text('这个项目没有通过校验，暂时不能预览'), findsOneWidget);
      expect(find.textContaining('2 个问题'), findsWidgets);
      expect(factory.created, isEmpty, reason: '校验未通过不得编译进预览');
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const ValueKey('video3d-transport-play')),
            )
            .onPressed,
        isNull,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('video3d-transport-reason')),
          matching: find.textContaining('校验'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('video3d-inspector-verify')),
          matching: find.textContaining('未通过'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('open 通道：指定项目优先于列表首项，消费后清空', (tester) async {
      _viewport(tester);
      await projectStore.save(
        'alpha',
        scene: _validScene(),
        screenplay: _validScreenplay(),
      );
      await projectStore.save(
        'beta',
        scene: _validScene(secondNodeId: 'desk'),
        screenplay: _validScreenplay(),
      );
      video3dLoadOnOpen = 'beta';
      final _Factory factory = _Factory();

      await tester.pumpWidget(
        _app(
          Video3dWorkspace(
            projectStore: projectStore,
            previewFactory: factory.call,
          ),
        ),
      );
      await _settle(tester);

      expect(video3dLoadOnOpen, isNull, reason: '开局通道是一次性的');
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('video3d-header')),
          matching: find.textContaining('beta'),
        ),
        findsOneWidget,
      );
      expect(factory.created, hasLength(1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('窄屏：左侧项目栏隐藏，抬头项目菜单仍可切项目', (tester) async {
      _viewport(tester, size: const Size(900, 700));
      await projectStore.save(
        'alpha',
        scene: _validScene(),
        screenplay: _validScreenplay(),
      );
      await projectStore.save(
        'beta',
        scene: _validScene(secondNodeId: 'desk'),
        screenplay: _validScreenplay(),
      );
      final _Factory factory = _Factory();

      await tester.pumpWidget(
        _app(
          Video3dWorkspace(
            projectStore: projectStore,
            previewFactory: factory.call,
          ),
        ),
      );
      await _settle(tester);

      expect(
        find.byKey(const ValueKey('video3d-project-list')),
        findsNothing,
        reason: '窄屏左栏走隐藏策略（与视频导演台断点一致）',
      );
      expect(
        find.byKey(const ValueKey('video3d-project-menu')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('video3d-project-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('beta').last);
      await _settle(tester);

      expect(factory.created.length, greaterThanOrEqualTo(2));
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('video3d-header')),
          matching: find.textContaining('beta'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('手机窄屏：左右栏都隐藏，内容不被撑爆，播放仍可禁用说明', (tester) async {
      _viewport(tester, size: const Size(390, 844));
      await projectStore.save(
        'alpha',
        scene: _validScene(),
        screenplay: _validScreenplay(),
      );
      final _Factory factory = _Factory();

      await tester.pumpWidget(
        _app(
          Video3dWorkspace(
            projectStore: projectStore,
            previewFactory: factory.call,
          ),
        ),
      );
      await _settle(tester);

      expect(
        find.byKey(const ValueKey('video3d-project-list')),
        findsNothing,
        reason: '手机断点下左栏隐藏',
      );
      expect(
        find.byKey(const ValueKey('video3d-inspector')),
        findsNothing,
        reason: '手机断点下右栏隐藏',
      );
      expect(
        find.byKey(const ValueKey('video3d-project-menu')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('video3d-bottom-bar')), findsOneWidget);
      // 手机窄屏下预览面与运输条都还在，没有布局溢出（RenderFlex 会 throw）。
      expect(tester.takeException(), isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // 顶栏接线
  // ---------------------------------------------------------------------------

  group('顶栏', () {
    testWidgets('项目菜单「3D 视频工作台」→ plugin:video3d', (tester) async {
      _viewport(tester);
      final AppStore store = _store();

      await tester.pumpWidget(_titleBarApp(store));
      await tester.tap(find.byKey(const ValueKey('title-bar-project-menu')));
      await tester.pumpAndSettle();

      expect(find.text('3D 视频工作台'), findsOneWidget);
      await tester.tap(find.text('3D 视频工作台'));
      await tester.pumpAndSettle();

      expect(store.view, 'plugin:video3d');
      expect(video3dLoadOnOpen, isNull);
      // 当前项目标识随视图切到 3D 视频工作台。
      expect(find.text('3D 视频工作台'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('_activeProject 对 plugin:video3d：显示「3D 视频工作台」', (tester) async {
      _viewport(tester);
      final AppStore store = _store()..view = 'plugin:video3d';

      await tester.pumpWidget(_titleBarApp(store));
      expect(find.text('3D 视频工作台'), findsOneWidget);
      expect(find.byIcon(Icons.movie_creation_outlined), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });
}
