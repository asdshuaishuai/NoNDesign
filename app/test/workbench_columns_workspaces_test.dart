// 四栏目（呈现效果 / 文档 / 规范 / 源码）接入真实工作台的永久回归测试。
//
// 用户裁决 2026-11-27：所有工作台内容区固定四栏目，栏目框架唯一实现在
// `lib/widgets/workbench_views.dart`。本文件把「临时验证」固化成回归门：
//   * 3D / 音乐 / 3D 视频 / 视频 四个真实工作台 widget 都出现栏目条四项；
//   * 依次 tap 文档 / 规范 / 源码 / 呈现效果，对应面板出现（空态也算）；
//   * 切到非「呈现效果」时，呈现面子树不在 widget 树里（用其内部 Key 断言），
//     切回后原样回来——即切栏目不会重挂预览/播放控制器；
//   * 3D 与音乐各覆盖深色 + 浅色（Aqua），1440×900 下栏目条存在且无 overflow。
//
// 全部用测试替身：不构造真 WebView、不连网络、不碰真实用户目录。
// 3D：`debugThreeWebViewSupported=false` + 临时目录 `ThreeService`（降级面）。
// 音乐：临时 `MusicProjectStore` + Fake 播放控制器。
// 3D 视频：临时 `Video3dProjectStore` + Fake 预览控制器。
// 视频：临时 `VideoProjectStore` + 空示例 `VideoService`（落空态，无播放器）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nondesign/core/capability_hub.dart';
import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/music/music_compile.dart';
import 'package:nondesign/core/music/music_project.dart';
import 'package:nondesign/core/music/music_score.dart';
import 'package:nondesign/core/platform_capabilities.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/core/three_service.dart';
import 'package:nondesign/core/toast_service.dart';
import 'package:nondesign/core/video3d/video3d_compile.dart';
import 'package:nondesign/core/video3d/video3d_project.dart';
import 'package:nondesign/core/video_clip.dart';
import 'package:nondesign/core/video_project.dart';
import 'package:nondesign/core/video_samples.dart';
import 'package:nondesign/core/video_service.dart';
import 'package:nondesign/widgets/music_playback_surface.dart';
import 'package:nondesign/widgets/music_workspace.dart';
import 'package:nondesign/widgets/three_workspace.dart';
import 'package:nondesign/widgets/video3d_preview_surface.dart';
import 'package:nondesign/widgets/video3d_workspace.dart';
import 'package:nondesign/widgets/video_workspace.dart';
import 'package:nondesign/widgets/workbench_views.dart';

// ---------------------------------------------------------------------------
// 通用夹具
// ---------------------------------------------------------------------------

/// 桌面尺寸：四栏目 + 各工作台面板在 1440×900 下必须不溢出。
const Size _desktop = Size(1440, 900);

ThemeData _theme({required bool dark}) => AppTheme.build(dark: dark);

void _setViewport(WidgetTester tester, [Size size = _desktop]) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// 真实 IO（3D 读盘 / 预览组装）要走 runAsync 才推得动；faked clock 下不能
/// `pumpAndSettle`（加载指示可能是无限动画）。
Future<void> _settleIo(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
  }
  await tester.pump(const Duration(milliseconds: 120));
}

/// 音乐 / 3D 视频 / 视频用的是「同步磁盘读写包在 async 里」的工作台：交替
/// pump 推进微任务即可（与 music_workspace_test / video3d_workspace_test 同法）。
Future<void> _settleFast(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 50));
}

/// 断言栏目条固定四项（Key + 文案都来自唯一出口 [WorkbenchColumnLabel]）。
void _expectFourColumns(WidgetTester tester) {
  expect(
    find.byKey(const ValueKey('workbench-columns-bar')),
    findsOneWidget,
    reason: '栏目条必须常显',
  );
  for (final WorkbenchColumn column in WorkbenchColumn.values) {
    expect(
      find.byKey(ValueKey<String>(column.tabKey)),
      findsOneWidget,
      reason: '栏目「${column.label}」的稳定 Key 必须存在',
    );
    expect(find.text(column.label), findsOneWidget);
  }
}

Future<void> _tapColumn(WidgetTester tester, WorkbenchColumn column) async {
  await tester.tap(find.byKey(ValueKey<String>(column.tabKey)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

/// 切走「呈现效果」时：呈现面子树必须真的不在树里（不是被藏起来）。
void _expectPresentGone(WidgetTester tester, List<String> presentKeys) {
  for (final String key in presentKeys) {
    expect(
      find.byKey(ValueKey<String>(key)),
      findsNothing,
      reason: '切到文档/规范/源码后，呈现面 Key $key 不应还在树里',
    );
  }
}

void _expectPresentBack(WidgetTester tester, List<String> presentKeys) {
  for (final String key in presentKeys) {
    expect(
      find.byKey(ValueKey<String>(key)),
      findsOneWidget,
      reason: '切回「呈现效果」后，呈现面 Key $key 必须回来',
    );
  }
}

/// 3D 呈现面的内部稳定 Key（都在 `_presentPane` 里）：
/// 工具条 + 「无内嵌预览能力」的降级面。
const List<String> _threePresentKeys = <String>[
  'three-workbench-toolstrip',
  'three-preview-unsupported',
];

/// 音乐呈现面的内部稳定 Key：五线谱视图 + 运输条。
const List<String> _musicPresentKeys = <String>[
  'music-staff-view',
  'music-transport',
];

/// 3D 视频呈现面的内部稳定 Key：预览面 + 只读检查器 + 底部镜头时间线。
const List<String> _video3dPresentKeys = <String>[
  'video3d-preview-surface',
  'video3d-inspector',
  'video3d-bottom-bar',
];

/// 视频（代码动画）呈现面在「无项目/无示例」空态下的稳定 Key。
const List<String> _videoPresentKeys = <String>['video-player-hint'];

// ---------------------------------------------------------------------------
// 3D 工作台
// ---------------------------------------------------------------------------

/// 旧布局三件套夹具（3D 工作台只读，不新建项目、不碰模型）。
void _seedLegacyThreeProject(Directory root, String name, {String? docs}) {
  final Directory dir = Directory('${root.path}/$name')
    ..createSync(recursive: true);
  File('${dir.path}/three-spec.json').writeAsStringSync(
    jsonEncode(<String, dynamic>{
      'title': 'Saturn',
      'summary': '带环行星自转',
      'components': <Map<String, dynamic>>[
        <String, dynamic>{'id': 'planet', 'what': '球体', 'size_scale': 1.0},
        <String, dynamic>{'id': 'ring', 'what': '扁平圆环', 'size_scale': 1.8},
      ],
      'materials': <Map<String, dynamic>>[
        <String, dynamic>{'id': 'rock', 'color_hex': '#c9a06a'},
      ],
      'acceptance': <String>['行星在场', '环可见'],
    }),
  );
  File('${dir.path}/scene.js')
      .writeAsStringSync('export default function build() { return {}; }\n');
  File('${dir.path}/build-state.json').writeAsStringSync(
    jsonEncode(<String, Object?>{
      'current': 'structure',
      'blocked': false,
      'passes': <Object?>[],
    }),
  );
  if (docs != null) File('${dir.path}/docs.md').writeAsStringSync(docs);
}

ThreeService _threeService(Directory root) => ThreeService(
  root: root,
  llm: (request) async => throw const ThreeFailure('llm_error', 'unused'),
  assets: (String key) async => throw ThreeFailure('asset_missing', key),
);

AppStore _threeAppStore(Directory temp) =>
    AppStore(
        toasts: ToastService(autoDismiss: false),
        // flutter_test 默认平台是 android（会关掉内嵌预览）——显式钉桌面。
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
      )
      // 设置镜像写临时目录：测试不碰真实 home。
      ..settingsMirrorDir = '${temp.path}/state';

Widget _threeHost(AppStore store, ThreeService service, {required bool dark}) =>
    ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(
        theme: _theme(dark: dark),
        home: Scaffold(body: ThreeWorkspace(service: service)),
      ),
    );

// ---------------------------------------------------------------------------
// 音乐工作台
// ---------------------------------------------------------------------------

MusicScore _musicScore({String title = '练习曲', int measures = 1}) => MusicScore(
  title: title,
  tempo: 96,
  timeSig: const <int>[4, 4],
  keySig: 'C',
  tracks: <MusicTrack>[
    MusicTrack(
      id: 'track_0',
      name: '主旋律',
      instrument: 'piano',
      measures: <MusicMeasure>[
        for (int i = 0; i < measures; i++)
          MusicMeasure(
            id: 'm${i + 1}',
            events: <MusicEvent>[
              MusicEvent(
                id: 'n${i + 1}',
                isRest: false,
                durNum: 1,
                durDen: 1,
                step: 'C',
                octave: 5,
              ),
            ],
          ),
      ],
    ),
  ],
);

/// 不构造真 WebView 的播放控制器（生产实现是 webview_all + 播放页）。
class _FakePlayback extends MusicPlaybackController {
  _FakePlayback({this.duration = 2.5});

  @override
  final double duration;

  bool _ready = false;
  bool _playing = false;
  double _position = 0;
  int _beat = -1;
  int _bar = 0;

  int startCalls = 0;
  int disposeCalls = 0;

  @override
  bool get ready => _ready;

  @override
  bool get playing => _playing;

  @override
  double get position => _position;

  @override
  int get beat => _beat;

  @override
  int get bar => _bar;

  @override
  String get loadError => '';

  @override
  String get technicalDetail => '';

  @override
  Future<void> start() async {
    startCalls += 1;
    _ready = true;
    notifyListeners();
  }

  @override
  Future<void> play() async {
    _playing = true;
    notifyListeners();
  }

  @override
  Future<void> pause() async {
    _playing = false;
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    _playing = false;
    _position = 0;
    _beat = -1;
    _bar = 0;
    notifyListeners();
  }

  @override
  Future<void> seek(double seconds) async {
    _position = seconds;
    notifyListeners();
  }

  @override
  void dispose() {
    disposeCalls += 1;
    super.dispose();
  }
}

MusicProjectSnapshot _unverifiedSnapshot(Directory dir) {
  final MusicScore score = _musicScore();
  return MusicProjectSnapshot(
    name: 'stale',
    score: score,
    raw: score.toJson(),
    validation: const MusicValidation(
      issues: <MusicIssue>[MusicIssue('/tempo', 'score_invalid', '速度不在允许范围')],
      verified: false,
    ),
    playPlan: null,
    dir: dir.path,
  );
}

/// 读盘桩：让工作台拿到「校验未通过」的真实 snapshot 形状（不伪造成功）。
class _UnverifiedSnapshotStore extends MusicProjectStore {
  _UnverifiedSnapshotStore({required super.root, required this.snapshot});

  final MusicProjectSnapshot snapshot;

  @override
  Future<MusicProjectSnapshot> read(String name) async => snapshot;
}

Widget _musicHost(
  MusicProjectStore store, {
  required bool dark,
  MusicPlaybackController Function(MusicScore score, MusicPlayPlan plan)?
  playbackFactory,
}) => MaterialApp(
  theme: _theme(dark: dark),
  home: Scaffold(
    body: MusicWorkspace(store: store, playbackFactory: playbackFactory),
  ),
);

// ---------------------------------------------------------------------------
// 3D 视频工作台
// ---------------------------------------------------------------------------

Map<String, Object?> _valid3dScene() => <String, Object?>{
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
      'id': 'table',
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

Map<String, Object?> _valid3dScreenplay() => <String, Object?>{
  'v': 1,
  'fps': 30,
  'format': <String, Object?>{'width': 720, 'height': 1280},
  'shots': <Object?>[
    <String, Object?>{
      'id': 's1',
      'duration': 5.0,
      'camera': <String, Object?>{'id': 'hero'},
    },
    <String, Object?>{
      'id': 's2',
      'duration': 3.0,
      'camera': <String, Object?>{'id': 'hero'},
    },
  ],
};

/// 不构造真 WebView 的 3D 视频预览控制器。
class _FakePreview extends Video3dPreviewController {
  _FakePreview({required this.fps, required this.totalFrames});

  @override
  final int fps;

  @override
  final int totalFrames;

  bool _ready = false;
  bool _playing = false;
  int _frame = 0;

  @override
  bool get ready => _ready;

  @override
  bool get playing => _playing;

  @override
  int get frame => _frame;

  @override
  String get loadError => '';

  @override
  String get technicalDetail => '';

  @override
  Future<void> start() async {
    _ready = true;
    notifyListeners();
  }

  @override
  Future<void> play() async {
    _playing = true;
    notifyListeners();
  }

  @override
  Future<void> pause() async {
    _playing = false;
    notifyListeners();
  }

  @override
  Future<void> stop() async {
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
    _frame = frame;
    notifyListeners();
  }
}

class _PreviewFactory {
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

Widget _video3dHost(
  Video3dProjectStore store,
  _PreviewFactory factory, {
  required bool dark,
}) => MaterialApp(
  theme: _theme(dark: dark),
  home: Scaffold(
    body: Video3dWorkspace(projectStore: store, previewFactory: factory.call),
  ),
);

// ---------------------------------------------------------------------------
// 视频（代码动画）工作台：空示例注入 —— 空态，不构造真 WebView。
// ---------------------------------------------------------------------------

class _EmptySamplesVideoService extends VideoService {
  _EmptySamplesVideoService() : super(host: VideoHost.macos);

  @override
  List<VideoSampleInfo> get samples => const <VideoSampleInfo>[];
}

AppStore _videoAppStore(Directory temp) =>
    AppStore(
        toasts: ToastService(autoDismiss: false),
        capabilities: CapabilityHub(
          platform: PlatformCapabilities.forOs(HostOs.macos),
        ),
      )
      ..ready = true
      ..settingsMirrorDir = '${temp.path}/state';

Widget _videoHost(
  AppStore store,
  VideoService service,
  VideoProjectStore projectStore, {
  required bool dark,
}) => ChangeNotifierProvider<AppStore>.value(
  value: store,
  child: MaterialApp(
    theme: _theme(dark: dark),
    home: Scaffold(
      body: VideoWorkspace(
        service: service,
        projectStore: projectStore,
        // 动效合成清单注入空表：本用例只看四栏目框架，不让真 assets 加载
        // 把等待时机搅浑，也不给播放面建 WebView 的机会。
        clips: const <VideoClipInfo>[],
      ),
    ),
  ),
);

// ---------------------------------------------------------------------------

void main() {
  setUp(() {
    // 所有工作台都读 SharedPreferences（设置/草稿）；测试用内存桩。
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  // -------------------------------------------------------------------------
  // 3D
  // -------------------------------------------------------------------------
  group('3D 工作台四栏目', () {
    late Directory temp;
    late AppStore store;
    late ThreeService service;

    setUp(() async {
      temp = Directory.systemTemp.createTempSync('nondesign-columns-3d-');
      _seedLegacyThreeProject(temp, 'saturn', docs: '# 需求\n\n- 行星在场\n- 环可见\n');
      service = _threeService(temp);
      store = _threeAppStore(temp);
      // 不构造真 WebView：走「这台设备不能内嵌预览」的降级面（同真机代码路）。
      debugThreeWebViewSupported = false;
      // 打开一个磁盘上真实存在的旧布局项目（工作台只读）。
      threeLoadOnOpen = 'saturn';
    });

    tearDown(() {
      debugThreeWebViewSupported = null;
      threeLoadOnOpen = null;
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });

    testWidgets('栏目条四项；依次 tap 文档/规范/源码/呈现效果，present 子树随栏目进出', (tester) async {
      _setViewport(tester);
      await tester.pumpWidget(_threeHost(store, service, dark: true));
      await _settleIo(tester);

      _expectFourColumns(tester);
      _expectPresentBack(tester, _threePresentKeys);

      // 文档：项目目录里的 docs.md 有正文 → 正文面（不是空态）。
      await _tapColumn(tester, WorkbenchColumn.docs);
      expect(find.byKey(const ValueKey('workbench-docs-body')), findsOneWidget);
      expect(find.textContaining('行星在场'), findsOneWidget);
      expect(find.byKey(const ValueKey('workbench-docs-empty')), findsNothing);
      expect(
        find.byKey(const ValueKey('workbench-columns-bar')),
        findsOneWidget,
      );
      _expectPresentGone(tester, _threePresentKeys);

      // 规范：旧布局 three-spec.json 被只读展示（JSON 正文 + 没有编造摘要）。
      await _tapColumn(tester, WorkbenchColumn.spec);
      expect(find.byKey(const ValueKey('workbench-spec-body')), findsOneWidget);
      expect(find.byKey(const ValueKey('workbench-spec-empty')), findsNothing);
      expect(find.textContaining('Saturn'), findsOneWidget);
      _expectPresentGone(tester, _threePresentKeys);

      // 源码：scene.js + three-spec.json 进入源码结构树。
      await _tapColumn(tester, WorkbenchColumn.source);
      expect(
        find.byKey(const ValueKey('workbench-source-body')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('workbench-source-file:scene.js')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('workbench-source-file:three-spec.json')),
        findsOneWidget,
      );
      _expectPresentGone(tester, _threePresentKeys);

      // 切回呈现效果：原预览面（降级提示）回来，栏目数据面板退场。
      await _tapColumn(tester, WorkbenchColumn.present);
      _expectPresentBack(tester, _threePresentKeys);
      expect(find.byKey(const ValueKey('workbench-source-body')), findsNothing);
      expect(find.byKey(const ValueKey('workbench-docs-body')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('深色与浅色（Aqua）：栏目条存在、四项齐全、1440×900 无 overflow', (tester) async {
      _setViewport(tester);
      for (final bool dark in <bool>[true, false]) {
        await tester.pumpWidget(_threeHost(store, service, dark: dark));
        await _settleIo(tester);
        expect(
          tester.takeException(),
          isNull,
          reason: '${dark ? '深色' : '浅色（Aqua）'} 1440×900 不应溢出',
        );
        _expectFourColumns(tester);
        expect(
          tester
              .getSize(find.byKey(const ValueKey('workbench-columns-bar')))
              .height,
          38,
          reason: '栏目条高度是框架契约（widgets/workbench_views.dart）',
        );
      }
    });
  });

  // -------------------------------------------------------------------------
  // 音乐
  // -------------------------------------------------------------------------
  group('音乐工作台四栏目', () {
    late Directory temp;
    late MusicProjectStore store;

    setUp(() async {
      temp = Directory.systemTemp.createTempSync('nondesign-columns-music-');
      store = MusicProjectStore(root: temp);
      await store.save('study', _musicScore());
    });

    tearDown(() async {
      if (temp.existsSync()) await temp.delete(recursive: true);
    });

    testWidgets('栏目条四项；tap 四栏目各一次，规范摘要与 score.json 源码条目齐全', (tester) async {
      _setViewport(tester);
      int playbackCreates = 0;
      final List<_FakePlayback> playbackes = <_FakePlayback>[];
      await tester.pumpWidget(
        _musicHost(
          store,
          dark: true,
          playbackFactory: (MusicScore score, MusicPlayPlan plan) {
            playbackCreates += 1;
            final _FakePlayback fake = _FakePlayback(
              duration: musicPlaybackDurationSeconds(plan),
            );
            playbackes.add(fake);
            return fake;
          },
        ),
      );
      await _settleFast(tester);

      _expectFourColumns(tester);
      _expectPresentBack(tester, _musicPresentKeys);
      expect(playbackCreates, 1, reason: '打开项目时创建一次播放控制器');
      expect(playbackes.single.startCalls, greaterThanOrEqualTo(1));

      // 文档：没有 docs.md → 可行动空态（不伪造文档）。
      await _tapColumn(tester, WorkbenchColumn.docs);
      expect(
        find.byKey(const ValueKey('workbench-docs-empty')),
        findsOneWidget,
      );
      expect(find.text('还没有文档'), findsOneWidget);
      _expectPresentGone(tester, _musicPresentKeys);

      // 规范：摘要必须显性写「校验通过/校验未通过」，JSON 是乐谱事实源。
      await _tapColumn(tester, WorkbenchColumn.spec);
      expect(find.byKey(const ValueKey('workbench-spec-body')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('workbench-spec-body')),
          matching: find.textContaining('校验通过'),
        ),
        findsOneWidget,
        reason: '规范栏摘要必须写出校验结论',
      );
      expect(find.textContaining('"tempo": 96'), findsOneWidget);
      _expectPresentGone(tester, _musicPresentKeys);

      // 源码：score.json 是事实源条目，且排在结构树里。
      await _tapColumn(tester, WorkbenchColumn.source);
      expect(
        find.byKey(const ValueKey('workbench-source-body')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('workbench-source-file:score.json')),
        findsOneWidget,
        reason: '源码栏必须列出 score.json 事实源',
      );
      _expectPresentGone(tester, _musicPresentKeys);

      // 切回呈现效果：谱面/运输条回来；切栏目不重建播放控制器。
      await _tapColumn(tester, WorkbenchColumn.present);
      _expectPresentBack(tester, _musicPresentKeys);
      expect(find.byKey(const ValueKey('workbench-source-body')), findsNothing);
      expect(playbackCreates, 1, reason: '切栏目不得重新创建播放控制器（不重挂播放 WebView）');
      expect(playbackes.single.disposeCalls, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('校验未通过的项目：规范摘要写「校验未通过」并按问题数说明', (tester) async {
      _setViewport(tester);
      final _UnverifiedSnapshotStore unverifiedStore = _UnverifiedSnapshotStore(
        root: temp,
        snapshot: _unverifiedSnapshot(temp),
      );
      await tester.pumpWidget(
        _musicHost(
          unverifiedStore,
          dark: true,
          playbackFactory: (MusicScore score, MusicPlayPlan plan) =>
              _FakePlayback(),
        ),
      );
      await _settleFast(tester);

      _expectFourColumns(tester);
      _expectPresentBack(tester, _musicPresentKeys);

      await _tapColumn(tester, WorkbenchColumn.spec);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('workbench-spec-body')),
          matching: find.textContaining('校验未通过 · 1 处问题'),
        ),
        findsOneWidget,
        reason: '未通过校验不得被摘要伪装成通过；问题数要如实写',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('深色与浅色（Aqua）：栏目条存在、四项齐全、1440×900 无 overflow', (tester) async {
      _setViewport(tester);
      for (final bool dark in <bool>[true, false]) {
        await tester.pumpWidget(
          _musicHost(
            store,
            dark: dark,
            playbackFactory: (MusicScore score, MusicPlayPlan plan) =>
                _FakePlayback(),
          ),
        );
        await _settleFast(tester);
        expect(
          tester.takeException(),
          isNull,
          reason: '${dark ? '深色' : '浅色（Aqua）'} 1440×900 不应溢出',
        );
        _expectFourColumns(tester);
        expect(
          tester
              .getSize(find.byKey(const ValueKey('workbench-columns-bar')))
              .height,
          38,
        );
      }
    });
  });

  // -------------------------------------------------------------------------
  // 3D 视频
  // -------------------------------------------------------------------------
  group('3D 视频工作台四栏目', () {
    late Directory temp;
    late Video3dProjectStore projectStore;

    setUp(() async {
      temp = Directory.systemTemp.createTempSync('nondesign-columns-video3d-');
      projectStore = Video3dProjectStore(root: temp);
    });

    tearDown(() async {
      if (temp.existsSync()) await temp.delete(recursive: true);
    });

    testWidgets('栏目条四项；present 子树随栏目进出，预览控制器不重建；docs 空态/源码两份事实源', (
      tester,
    ) async {
      _setViewport(tester);
      await projectStore.save(
        'alpha',
        scene: _valid3dScene(),
        screenplay: _valid3dScreenplay(),
      );
      final _PreviewFactory factory = _PreviewFactory();
      await tester.pumpWidget(_video3dHost(projectStore, factory, dark: true));
      await _settleFast(tester);

      _expectFourColumns(tester);
      _expectPresentBack(tester, _video3dPresentKeys);
      expect(factory.created, hasLength(1), reason: '打开项目时创建一次预览控制器');

      // 文档：项目还没有 docs.md → 空态。
      await _tapColumn(tester, WorkbenchColumn.docs);
      expect(
        find.byKey(const ValueKey('workbench-docs-empty')),
        findsOneWidget,
      );
      _expectPresentGone(tester, _video3dPresentKeys);

      // 规范：两份机器可读事实源按文件名并排 + 校验结论摘要。
      await _tapColumn(tester, WorkbenchColumn.spec);
      expect(find.byKey(const ValueKey('workbench-spec-body')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('workbench-spec-body')),
          matching: find.textContaining('校验通过'),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('scene3d.json'), findsOneWidget);
      _expectPresentGone(tester, _video3dPresentKeys);

      // 源码：scene3d.json + screenplay3d.json 是唯一事实源。
      await _tapColumn(tester, WorkbenchColumn.source);
      expect(
        find.byKey(const ValueKey('workbench-source-body')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('workbench-source-file:scene3d.json')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('workbench-source-file:screenplay3d.json')),
        findsOneWidget,
      );
      _expectPresentGone(tester, _video3dPresentKeys);

      // 切回呈现效果：预览/检查器/底部条回来，控制器仍只有最初那一个。
      await _tapColumn(tester, WorkbenchColumn.present);
      _expectPresentBack(tester, _video3dPresentKeys);
      expect(find.byKey(const ValueKey('workbench-source-body')), findsNothing);
      expect(
        factory.created,
        hasLength(1),
        reason: '切栏目不得重新创建预览控制器（不重挂预览 WebView）',
      );
      expect(factory.created.single.ready, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('深色与浅色（Aqua）：栏目条存在、四项齐全、1440×900 无 overflow', (tester) async {
      _setViewport(tester);
      await projectStore.save(
        'alpha',
        scene: _valid3dScene(),
        screenplay: _valid3dScreenplay(),
      );
      final _PreviewFactory factory = _PreviewFactory();
      for (final bool dark in <bool>[true, false]) {
        await tester.pumpWidget(
          _video3dHost(projectStore, factory, dark: dark),
        );
        await _settleFast(tester);
        expect(
          tester.takeException(),
          isNull,
          reason: '${dark ? '深色' : '浅色（Aqua）'} 1440×900 不应溢出',
        );
        _expectFourColumns(tester);
        expect(
          tester
              .getSize(find.byKey(const ValueKey('workbench-columns-bar')))
              .height,
          38,
        );
      }
    });
  });

  // -------------------------------------------------------------------------
  // 视频（代码动画）
  // -------------------------------------------------------------------------
  group('视频工作台四栏目', () {
    late Directory temp;
    late AppStore store;
    late VideoProjectStore projectStore;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('nondesign-columns-video-');
      store = _videoAppStore(temp);
      projectStore = VideoProjectStore(root: temp);
    });

    tearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });

    testWidgets('栏目条四项；没有项目时文档/规范/源码都是可行动空态，present 子树随栏目进出', (tester) async {
      _setViewport(tester);
      await tester.pumpWidget(
        _videoHost(
          store,
          _EmptySamplesVideoService(),
          projectStore,
          dark: true,
        ),
      );
      await _settleFast(tester);

      _expectFourColumns(tester);
      _expectPresentBack(tester, _videoPresentKeys);

      await _tapColumn(tester, WorkbenchColumn.docs);
      expect(
        find.byKey(const ValueKey('workbench-docs-empty')),
        findsOneWidget,
      );
      _expectPresentGone(tester, _videoPresentKeys);

      await _tapColumn(tester, WorkbenchColumn.spec);
      expect(
        find.byKey(const ValueKey('workbench-spec-empty')),
        findsOneWidget,
      );
      _expectPresentGone(tester, _videoPresentKeys);

      await _tapColumn(tester, WorkbenchColumn.source);
      expect(
        find.byKey(const ValueKey('workbench-source-empty')),
        findsOneWidget,
      );
      _expectPresentGone(tester, _videoPresentKeys);

      await _tapColumn(tester, WorkbenchColumn.present);
      _expectPresentBack(tester, _videoPresentKeys);
      expect(tester.takeException(), isNull);
    });

    testWidgets('深色与浅色（Aqua）：栏目条存在、四项齐全、1440×900 无 overflow', (tester) async {
      _setViewport(tester);
      final VideoService service = _EmptySamplesVideoService();
      for (final bool dark in <bool>[true, false]) {
        await tester.pumpWidget(
          _videoHost(store, service, projectStore, dark: dark),
        );
        await _settleFast(tester);
        expect(
          tester.takeException(),
          isNull,
          reason: '${dark ? '深色' : '浅色（Aqua）'} 1440×900 不应溢出',
        );
        _expectFourColumns(tester);
        expect(
          tester
              .getSize(find.byKey(const ValueKey('workbench-columns-bar')))
              .height,
          38,
        );
      }
    });
  });
}
