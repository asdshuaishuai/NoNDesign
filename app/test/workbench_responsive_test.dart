// 视频 / 3D 视频 / 音乐工作台内部分区的四档响应式回归（task-20）。
//
// 目标：900（窄 PC）/ 1024（左右栏刚好常驻）/ 1280 / 1600 四档宽度下，
// 三个工作台的内容区（面板头、三栏导演台、谱面+运输条、底部时间线）都不得
// 出现 RenderFlex overflow 或其它布局异常。
//
// 纪律：
//  * 不构造真 WebView：3D 视频注入 Fake 预览控制器、音乐注入 Fake 播放控制器；
//  * 不给「布局溢出」开豁免——所有宽度断言异常列表为空（测试内循环
//    `tester.takeException()` 把布局期抛出的异常全部收上来，溢出会带
//    "overflowed" 字样出现在失败信息里）；
//  * 与 main.dart 同一条字号缩放路径（[withResponsiveTextScale]）：窄屏字号放大
//    同样要能排下。
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nondesign/core/capability_hub.dart';
import 'package:nondesign/core/music/music_compile.dart';
import 'package:nondesign/core/music/music_project.dart';
import 'package:nondesign/core/music/music_score.dart';
import 'package:nondesign/core/platform_capabilities.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/core/toast_service.dart';
import 'package:nondesign/core/video3d/video3d_compile.dart';
import 'package:nondesign/core/video3d/video3d_project.dart';
import 'package:nondesign/core/video_clip.dart';
import 'package:nondesign/core/video_project.dart';
import 'package:nondesign/core/video_service.dart';
import 'package:nondesign/widgets/music_playback_surface.dart';
import 'package:nondesign/widgets/music_workspace.dart';
import 'package:nondesign/widgets/video3d_preview_surface.dart';
import 'package:nondesign/widgets/video3d_workspace.dart';
import 'package:nondesign/widgets/video_workspace.dart';

// ---------------------------------------------------------------------------
// 四档视口（宽度语义与 WorkbenchLayout 断点对齐：900/1024/1280/1600）
// ---------------------------------------------------------------------------

const List<Size> _viewports = <Size>[
  Size(900, 700),
  Size(1024, 768),
  Size(1280, 800),
  Size(1600, 1000),
];

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

Map<String, Object?> _scene() => <String, Object?>{
  'v': 1,
  'units': 'm',
  'environment': <String, Object?>{'background': '#0b0d12'},
  'nodes': <Object?>[
    <String, Object?>{
      'id': 'floor',
      'type': 'box',
      'size': <double>[10, 0.1, 10],
      'position': <double>[0, -0.05, 0],
    },
    <String, Object?>{
      'id': 'table',
      'type': 'plane',
      'size': <double>[2, 1, 0],
      'position': <double>[0, 0.5, 0],
      'parent': 'floor',
    },
  ],
  'lights': <Object?>[
    <String, Object?>{
      'id': 'key',
      'type': 'directional',
      'intensity': 1.0,
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

Map<String, Object?> _screenplay() => <String, Object?>{
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

MusicScore _score({int tracks = 2}) => MusicScore(
  title: '响应式练习曲',
  tempo: 96,
  timeSig: const <int>[4, 4],
  keySig: 'C',
  tracks: <MusicTrack>[
    for (int i = 0; i < tracks; i++)
      MusicTrack(
        id: 'track_$i',
        name: i == 0 ? '主旋律' : '低音',
        instrument: i == 0 ? 'piano' : 'bass',
        measures: <MusicMeasure>[
          MusicMeasure(
            id: 'm1',
            events: <MusicEvent>[
              for (int j = 0; j < 4; j++)
                MusicEvent(
                  id: 'n${i}_$j',
                  isRest: false,
                  durNum: 1,
                  durDen: 4,
                  step: const <String>['C', 'E', 'G', 'B'][j],
                  octave: i == 0 ? 5 : 3,
                ),
            ],
          ),
        ],
      ),
  ],
);

// ---------------------------------------------------------------------------
// Fake 控制器（不构造真 WebView）
// ---------------------------------------------------------------------------

class _FakeVideo3dPreview extends Video3dPreviewController {
  _FakeVideo3dPreview({required this.fps, required this.totalFrames});

  @override
  final int fps;

  @override
  final int totalFrames;

  bool _ready = false;
  bool _playing = false;
  int _frame = 0;
  final String _loadError = '';
  final String _technicalDetail = '';

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

class _FakeMusicPlayback extends MusicPlaybackController {
  _FakeMusicPlayback();

  bool _ready = false;
  bool _playing = false;
  double _position = 0;
  final int _beat = -1;
  final int _bar = 0;
  final String _loadError = '';
  final String _technicalDetail = '';

  @override
  bool get ready => _ready;

  @override
  bool get playing => _playing;

  @override
  double get position => _position;

  @override
  double get duration => 8.0;

  @override
  int get beat => _beat;

  @override
  int get bar => _bar;

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
    notifyListeners();
  }

  @override
  Future<void> seek(double seconds) async {
    _position = seconds;
    notifyListeners();
  }
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

AppStore _store() {
  final AppStore store = AppStore(
    toasts: ToastService(autoDismiss: false),
    capabilities: CapabilityHub(
      platform: PlatformCapabilities.forOs(HostOs.macos),
    ),
  )..ready = true;
  return store;
}

Widget _app(Widget child) => MaterialApp(
  theme: AppTheme.build(dark: true),
  // 与 main.dart 同一条字号缩放路径：窄屏 +10%、平板 +5%。
  builder: (BuildContext context, Widget? child) =>
      withResponsiveTextScale(context, child ?? const SizedBox.shrink()),
  home: Scaffold(body: child),
);

Widget _appWithStore(AppStore store, Widget child) =>
    ChangeNotifierProvider<AppStore>.value(value: store, child: _app(child));

void _setViewport(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
}

/// 交替 pump 与真实 IO 让「列项目 → 读项目 → 建播放面」链路走完。
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    });
  }
  await tester.pump(const Duration(milliseconds: 120));
}

/// 收掉本档布局期间抛出的所有异常并断言为空。
///
/// RenderFlex overflow 会在布局期作为 FlutterError 抛出，测试框架默认记为
/// 失败；这里显式收集后给带尺寸/工作台名的失败信息（且把溢出字样带出来）。
void _expectNoLayoutErrors(WidgetTester tester, String label, Size size) {
  final List<Object> errors = <Object>[];
  while (true) {
    final Object? error = tester.takeException();
    if (error == null) break;
    errors.add(error);
  }
  expect(
    errors,
    isEmpty,
    reason:
        '$label @ ${size.width.toInt()}x${size.height.toInt()} 出现布局异常：'
        '${errors.isEmpty ? '' : errors.first}',
  );
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

void main() {
  late Directory temp;
  late VideoProjectStore videoProjectStore;
  late Video3dProjectStore video3dProjectStore;
  late MusicProjectStore musicProjectStore;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    temp = Directory.systemTemp.createTempSync('nd-workbench-responsive-');
    videoProjectStore = VideoProjectStore(root: temp);
    video3dProjectStore = Video3dProjectStore(root: temp);
    musicProjectStore = MusicProjectStore(root: temp);
    await video3dProjectStore.save(
      'responsive',
      scene: _scene(),
      screenplay: _screenplay(),
    );
    await musicProjectStore.save('responsive', _score());
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  group('视频导演台（三栏 + 时间线）', () {
    for (final Size size in _viewports) {
      testWidgets('${size.width.toInt()}x${size.height.toInt()} 无溢出', (
        WidgetTester tester,
      ) async {
        _setViewport(tester, size);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final AppStore store = _store();
        await tester.pumpWidget(
          _appWithStore(
            store,
            VideoWorkspace(
              service: VideoService(host: VideoHost.macos),
              clips: const <VideoClipInfo>[],
              projectStore: videoProjectStore,
            ),
          ),
        );
        await _settle(tester);
        _expectNoLayoutErrors(tester, '视频工作台', size);
      });
    }
  });

  group('3D 视频工作台（项目列表 + 预览 + 检查器 + 时间线）', () {
    for (final Size size in _viewports) {
      testWidgets('${size.width.toInt()}x${size.height.toInt()} 无溢出', (
        WidgetTester tester,
      ) async {
        _setViewport(tester, size);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          _app(
            Video3dWorkspace(
              projectStore: video3dProjectStore,
              previewFactory:
                  (Video3dProjectSnapshot snapshot, Video3dTimeline timeline) =>
                      _FakeVideo3dPreview(
                        fps: timeline.fps,
                        totalFrames: timeline.totalFrames,
                      ),
            ),
          ),
        );
        await _settle(tester);
        _expectNoLayoutErrors(tester, '3D 视频工作台', size);
      });
    }
  });

  group('音乐工作台（项目/轨道 + 谱面 + 检查器 + 运输条）', () {
    for (final Size size in _viewports) {
      testWidgets('${size.width.toInt()}x${size.height.toInt()} 无溢出', (
        WidgetTester tester,
      ) async {
        _setViewport(tester, size);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          _app(
            MusicWorkspace(
              store: musicProjectStore,
              playbackFactory: (MusicScore score, MusicPlayPlan plan) =>
                  _FakeMusicPlayback(),
            ),
          ),
        );
        await _settle(tester);
        _expectNoLayoutErrors(tester, '音乐工作台', size);
      });
    }
  });
}
