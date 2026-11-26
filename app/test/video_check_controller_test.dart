// 视频 / 3D 视频工作台接入通用检查器（task-39）：
// 选中镜头 → 右侧「检查」tab 的可编辑属性表 → 写回项目事实源。
//
// 覆盖：
//  * 两个工作台挂载后都把自己的检查控制器注册到 store；无项目/无选中 → sheet null；
//  * 常规视频：选中镜头 → 镜头「id」属性表（起始时间只读 / 时长 / 文本 /
//    背景色 / 元素只读）；改时长/文本/颜色 → update true 且 timeline.json +
//    video.json 落盘变化；非法值 → false 且文件逐字节不变；
//  * 3D 视频：选中镜头 → 时长 + 相机 from/to 6 个坐标 + cues 只读；改时长/
//    坐标 → update true 且 screenplay3d.json 落盘变化、预览面与镜头条重建；
//    非法值 → false 且文件逐字节不变；
//  * 宽屏内容区检查器降级只读（右侧「检查」tab 才是编辑入口），窄屏行为不变；
//  * 卸载只清自己的控制器注册，不误清别的工作台。
//
// 全部用临时目录 + 预览面替身，不构造真 WebView。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nondesign/core/capability_hub.dart';
import 'package:nondesign/core/inspect/check_field.dart';
import 'package:nondesign/core/platform_capabilities.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/core/toast_service.dart';
import 'package:nondesign/core/video3d/video3d_compile.dart';
import 'package:nondesign/core/video3d/video3d_contract.dart';
import 'package:nondesign/core/video3d/video3d_project.dart';
import 'package:nondesign/core/video_clip.dart';
import 'package:nondesign/core/video_project.dart';
import 'package:nondesign/core/video_samples.dart';
import 'package:nondesign/core/video_service.dart';
import 'package:nondesign/widgets/video3d_preview_surface.dart';
import 'package:nondesign/widgets/video3d_workspace.dart';
import 'package:nondesign/widgets/video_workspace.dart';

// ---------------------------------------------------------------------------
// 夹具：合法的视频项目（timeline + screenplay 规范）与 3D 视频项目
// ---------------------------------------------------------------------------

Map<String, dynamic> _videoTimeline() => <String, dynamic>{
  'fps': 30,
  'width': 1280,
  'height': 720,
  'background': '#0E1220',
  'spec': 'spec.json',
  'scenes': <Object?>[
    <String, Object?>{
      'id': 'shot-a',
      'title': '开场',
      'duration': 3.0,
      'background': '#0E1220',
      'elements': <Object?>[
        <String, Object?>{
          'type': 'text',
          'text': '开场',
          'x': '50%',
          'y': 120,
          'size': 28,
          'color': '#FFFFFF',
        },
      ],
    },
    <String, Object?>{
      'id': 'shot-b',
      'title': '推近',
      'duration': 2.0,
      'background': '#10141F',
      'elements': <Object?>[
        <String, Object?>{
          'type': 'text',
          'text': '推近',
          'x': '50%',
          'y': 120,
          'size': 28,
          'color': '#FFFFFF',
        },
      ],
    },
  ],
};

Map<String, dynamic> _videoSpec() => <String, dynamic>{
  'kind': 'screenplay',
  'style': '手绘',
  'beats': <Object?>[
    <String, Object?>{'at': 0, 'say': '开场'},
  ],
};

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
      'camera': <String, Object?>{
        'move': <String, Object?>{
          'from': <double>[0, 1, 5],
          'to': <double>[0, 1, 2],
        },
      },
    },
    <String, Object?>{
      'id': 's2',
      'duration': 3.0,
      'camera': <String, Object?>{'id': 'hero'},
    },
  ],
};

// ---------------------------------------------------------------------------
// 测试替身：没有内置示例的视频服务 / 3D 视频预览控制器（不构造真 WebView）
// ---------------------------------------------------------------------------

class _EmptySamplesVideoService extends VideoService {
  _EmptySamplesVideoService() : super(host: VideoHost.macos);

  @override
  List<VideoSampleInfo> get samples => const <VideoSampleInfo>[];
}

class _FakePreview extends Video3dPreviewController {
  _FakePreview({required this.fps, required this.totalFrames});

  @override
  final int fps;

  @override
  final int totalFrames;

  bool disposed = false;
  bool _ready = false;
  final int _frame = 0;

  @override
  bool get ready => _ready;

  @override
  bool get playing => false;

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
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> seek(double seconds) async {}

  @override
  Future<void> seekFrame(int frame) async {}

  @override
  void dispose() {
    disposed = true;
    super.dispose();
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

/// 别的「工作台」登记的控制器：验证本工作台卸载时不会误清。
class _ForeignController extends WorkbenchCheckController {
  @override
  CheckSheet? get sheet => null;

  @override
  Future<bool> update(String key, Object? value) async => false;
}

// ---------------------------------------------------------------------------
// 宿主 / 几何 / IO helper
// ---------------------------------------------------------------------------

Widget _wrap(AppStore store, Widget child) =>
    ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(
        theme: AppTheme.build(dark: true),
        home: Scaffold(body: child),
      ),
    );

Future<void> _settleIo(WidgetTester tester) async {
  for (var i = 0; i < 30; i++) {
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
  }
  await tester.pump(const Duration(milliseconds: 200));
}

void _viewport(WidgetTester tester, {Size size = const Size(1440, 900)}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

WorkbenchCheckController _checkOf(AppStore store) {
  final WorkbenchCheckController? controller = store.checkController;
  expect(controller, isNotNull, reason: '工作台挂载后应把检查控制器注册到壳层');
  return controller!;
}

String _fileSignature(String path) {
  final File file = File(path);
  return file.existsSync() ? base64Encode(file.readAsBytesSync()) : '';
}

Map<String, dynamic> _readJson(String path) =>
    (jsonDecode(File(path).readAsStringSync()) as Map).cast<String, dynamic>();

void main() {
  late Directory temp;
  late Directory videoRoot;
  late Directory video3dRoot;
  late VideoProjectStore videoStore;
  late Video3dProjectStore video3dStore;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    temp = await Directory.systemTemp.createTemp('nondesign-video-check-');
    videoRoot = Directory('${temp.path}/video');
    video3dRoot = Directory('${temp.path}/video3d');
    videoStore = VideoProjectStore(root: videoRoot);
    video3dStore = Video3dProjectStore(root: video3dRoot);
  });

  tearDown(() async {
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  Future<void> seedVideoProject() async {
    await videoStore.create(
      name: 'clip',
      timeline: _videoTimeline(),
      spec: _videoSpec(),
      title: '检查片',
    );
  }

  Future<void> seedVideo3dProject() async {
    final Video3dVerification verification = await video3dStore.save(
      'demo',
      scene: _scene(),
      screenplay: _screenplay(),
    );
    expect(verification.verified, isTrue, reason: '测试夹具必须先通过契约校验');
  }

  AppStore videoAppStore({
    String project = 'clip',
    String view = 'plugin:video',
  }) {
    final AppStore store =
        AppStore(
            toasts: ToastService(autoDismiss: false),
            capabilities: CapabilityHub(
              platform: PlatformCapabilities.forOs(HostOs.macos),
            ),
          )
          ..ready = true
          ..view = view;
    store.settingsMirrorDir = '${temp.path}/state';
    if (project.isNotEmpty) store.settings.videoProjectName = project;
    return store;
  }

  AppStore video3dAppStore() =>
      AppStore(toasts: ToastService(autoDismiss: false))
        ..ready = true
        ..view = 'plugin:video3d';

  Future<AppStore> pumpVideo(
    WidgetTester tester, {
    Size size = const Size(1440, 900),
    bool withProject = true,
  }) async {
    _viewport(tester, size: size);
    final AppStore store = videoAppStore(project: withProject ? 'clip' : '');
    await tester.pumpWidget(
      _wrap(
        store,
        VideoWorkspace(
          service: _EmptySamplesVideoService(),
          projectStore: videoStore,
          clips: const <VideoClipInfo>[],
        ),
      ),
    );
    await _settleIo(tester);
    return store;
  }

  Future<({AppStore store, _PreviewFactory factory})> pumpVideo3d(
    WidgetTester tester, {
    Size size = const Size(1440, 900),
  }) async {
    _viewport(tester, size: size);
    final AppStore store = video3dAppStore();
    final _PreviewFactory factory = _PreviewFactory();
    await tester.pumpWidget(
      _wrap(
        store,
        Video3dWorkspace(
          projectStore: video3dStore,
          previewFactory: factory.call,
        ),
      ),
    );
    await _settleIo(tester);
    return (store: store, factory: factory);
  }

  String videoPath(String name) => '${videoRoot.path}/clip/$name';
  String video3dPath(String name) => '${video3dRoot.path}/demo/$name';

  // -------------------------------------------------------------------------
  // 常规视频
  // -------------------------------------------------------------------------

  group('常规视频检查器', () {
    testWidgets('没有生成项目（只有内置示例）→ 注册控制器但 sheet 为 null', (tester) async {
      final AppStore store = await pumpVideo(tester, withProject: false);
      final WorkbenchCheckController check = _checkOf(store);
      expect(check.sheet, isNull, reason: '内置示例不是可写项目，检查器空态而不是伪造可编辑属性');
    });

    testWidgets('生成项目 + 未选中镜头 → sheet null；挂载即注册', (tester) async {
      await seedVideoProject();
      final AppStore store = await pumpVideo(tester);
      final WorkbenchCheckController check = _checkOf(store);
      expect(check.sheet, isNull, reason: '还没选中镜头时检查器给空态');
      // 导演台三栏在场（宽屏）：镜头树/检查器/时间线。
      expect(
        find.byKey(const ValueKey('video-workbench-script-tree')),
        findsOneWidget,
      );
    });

    testWidgets('选中镜头 → 镜头「shot-a」属性表字段与契约值齐全；切镜头跟着换', (tester) async {
      await seedVideoProject();
      final AppStore store = await pumpVideo(tester);
      final WorkbenchCheckController check = _checkOf(store);

      await tester.tap(find.byKey(const ValueKey('video-shot-0')));
      await tester.pump();

      final CheckSheet sheet = check.sheet!;
      expect(sheet.title, '镜头「shot-a」');
      expect(sheet.kindLabel, '镜头');
      expect(sheet.subtitle, contains('timeline.json'));
      expect(
        sheet.fields.map((CheckField field) => field.key).toList(),
        <String>['start', 'duration', 'label', 'background', 'elements'],
        reason: '只映射 timeline.scenes[i] 里真实存在且可写的键',
      );

      final CheckField start = sheet.field('start')!;
      expect(start.kind, CheckFieldKind.number);
      expect((start.value! as num).toDouble(), 0.0);
      expect(start.enabled, isFalse, reason: '起始时间由前面镜头时长累加，不可直接写');

      final CheckField duration = sheet.field('duration')!;
      expect(duration.kind, CheckFieldKind.number);
      expect((duration.value! as num).toDouble(), 3.0);
      expect(duration.min, greaterThan(0), reason: '镜头时长必须大于 0');

      final CheckField label = sheet.field('label')!;
      expect(label.kind, CheckFieldKind.text);
      expect(label.value, '开场');

      final CheckField background = sheet.field('background')!;
      expect(background.kind, CheckFieldKind.color);
      expect(background.value, 0xFF0E1220);

      final CheckField elements = sheet.field('elements')!;
      expect(elements.kind, CheckFieldKind.readOnly);
      expect(elements.value, '1');

      // 切到第二个镜头：标题、起始时间、背景色都跟着换。
      await tester.tap(find.byKey(const ValueKey('video-shot-1')));
      await tester.pump();
      final CheckSheet second = check.sheet!;
      expect(second.title, '镜头「shot-b」');
      expect(
        (second.field('start')!.value! as num).toDouble(),
        3.0,
        reason: '第二个镜头的起始时间 = 前一条时长累加',
      );
      expect(second.field('background')!.value, 0xFF10141F);
      expect(second.field('label')!.value, '推近');
    });

    testWidgets('改时长 → update true，timeline.json / video.json 真落盘并刷新', (
      tester,
    ) async {
      await seedVideoProject();
      final AppStore store = await pumpVideo(tester);
      final WorkbenchCheckController check = _checkOf(store);
      await tester.tap(find.byKey(const ValueKey('video-shot-0')));
      await tester.pump();

      final String specBefore = _fileSignature(videoPath('spec.json'));
      final bool ok = (await tester.runAsync(
        () => check.update('duration', 4.5),
      ))!;
      expect(ok, isTrue, reason: '合法值必须真的保存成功');
      await tester.pump();

      final Map<String, dynamic> timeline = _readJson(
        videoPath('timeline.json'),
      );
      final Map<dynamic, dynamic> scene =
          (timeline['scenes'] as List).first as Map<dynamic, dynamic>;
      expect((scene['duration'] as num).toDouble(), closeTo(4.5, 1e-9));
      final Map<String, dynamic> meta = _readJson(videoPath('video.json'));
      expect(
        (meta['seconds'] as num).toDouble(),
        closeTo(6.5, 1e-9),
        reason: '元数据片长随镜头时长变化',
      );
      expect(
        _fileSignature(videoPath('spec.json')),
        specBefore,
        reason: '只改时间线，不碰规范',
      );
      expect(
        (check.sheet!.field('duration')!.value! as num).toDouble(),
        closeTo(4.5, 1e-9),
        reason: '保存后检查表重取新值',
      );
    });

    testWidgets('改文本与背景色 → update true，落盘值变化且检查表刷新', (tester) async {
      await seedVideoProject();
      final AppStore store = await pumpVideo(tester);
      final WorkbenchCheckController check = _checkOf(store);
      await tester.tap(find.byKey(const ValueKey('video-shot-0')));
      await tester.pump();

      expect(
        (await tester.runAsync(() => check.update('label', '第一镜')))!,
        isTrue,
      );
      await tester.pump();
      expect(
        await tester.runAsync(() => check.update('background', 0xFF10141F)),
        isTrue,
      );
      await tester.pump();

      final Map<String, dynamic> timeline = _readJson(
        videoPath('timeline.json'),
      );
      final Map<dynamic, dynamic> scene =
          (timeline['scenes'] as List).first as Map<dynamic, dynamic>;
      expect(scene['title'], '第一镜');
      expect(scene['background'], '#10141f');
      expect(check.sheet!.field('label')!.value, '第一镜');
      expect(check.sheet!.field('background')!.value, 0xFF10141F);
    });

    testWidgets('非法值 → update false 且 timeline.json / video.json 逐字节不变', (
      tester,
    ) async {
      await seedVideoProject();
      final AppStore store = await pumpVideo(tester);
      final WorkbenchCheckController check = _checkOf(store);
      await tester.tap(find.byKey(const ValueKey('video-shot-0')));
      await tester.pump();

      final String timelineBefore = _fileSignature(videoPath('timeline.json'));
      final String metaBefore = _fileSignature(videoPath('video.json'));

      expect(
        (await tester.runAsync(() => check.update('duration', 0)))!,
        isFalse,
      );
      expect(
        (await tester.runAsync(() => check.update('duration', 0.01)))!,
        isFalse,
        reason: '镜头时长不足一帧',
      );
      expect(
        (await tester.runAsync(() => check.update('label', 42)))!,
        isFalse,
      );
      expect(
        (await tester.runAsync(() => check.update('background', 'blue')))!,
        isFalse,
      );
      expect(
        (await tester.runAsync(() => check.update('volume', 0.5)))!,
        isFalse,
        reason: '契约里没有音量字段：不造字段也不接受写入',
      );

      expect(_fileSignature(videoPath('timeline.json')), timelineBefore);
      expect(_fileSignature(videoPath('video.json')), metaBefore);
    });

    testWidgets('宽屏内容区检查器降级只读；窄屏不渲染内容检查器（行为不变）', (tester) async {
      await seedVideoProject();
      await pumpVideo(tester);
      await tester.tap(find.byKey(const ValueKey('video-shot-0')));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('video-workbench-inspector-readonly-hint')),
        findsOneWidget,
        reason: '宽屏下编辑走右侧「检查」tab，内容区检查器只读',
      );

      await tester.pumpWidget(
        _wrap(videoAppStore(project: 'clip'), const SizedBox.shrink()),
      );
      await tester.pump();

      // 窄屏（右栏抽屉）：内容区不渲染检查器，只有导演台预览与镜头条。
      final AppStore narrowStore = await pumpVideo(
        tester,
        size: const Size(820, 700),
      );
      expect(
        find.byKey(const ValueKey('video-workbench-inspector')),
        findsNothing,
        reason: '窄屏本来就不渲染内容检查器，行为保持原样',
      );
      // 检查控制器仍注册在壳层：窄屏通过底部镜头条选中后，右侧「检查」tab 可编辑。
      await tester.tap(find.byKey(const ValueKey('video-timeline-shot-0')));
      await tester.pump();
      expect(_checkOf(narrowStore).sheet, isNotNull);
    });

    testWidgets('卸载只清自己的控制器注册', (tester) async {
      await seedVideoProject();
      final AppStore store = await pumpVideo(tester);
      expect(store.checkController, isNotNull);
      await tester.pumpWidget(_wrap(store, const SizedBox.shrink()));
      await tester.pump();
      expect(store.checkController, isNull);
    });

    testWidgets('卸载不清别的工作台已接管的控制器', (tester) async {
      await seedVideoProject();
      final AppStore store = await pumpVideo(tester);
      final WorkbenchCheckController foreign = _ForeignController();
      addTearDown(foreign.dispose);
      store.setCheckController(foreign);
      await tester.pumpWidget(_wrap(store, const SizedBox.shrink()));
      await tester.pump();
      expect(
        store.checkController,
        same(foreign),
        reason: '清空必须先判身份，不能把别的工作台的控制器清掉',
      );
    });
  });

  // -------------------------------------------------------------------------
  // 3D 视频
  // -------------------------------------------------------------------------

  group('3D 视频检查器', () {
    testWidgets('没有打开项目 → 注册控制器但 sheet 为 null', (tester) async {
      final ({AppStore store, _PreviewFactory factory}) empty =
          await pumpVideo3d(tester);
      final WorkbenchCheckController check = _checkOf(empty.store);
      expect(check.sheet, isNull, reason: '没有打开项目时检查器空态');
      expect(empty.factory.created, isEmpty, reason: '没有项目就没有预览面');
    });

    testWidgets('项目自动打开但未选中镜头 → sheet null', (tester) async {
      await seedVideo3dProject();
      final ({AppStore store, _PreviewFactory factory}) loaded =
          await pumpVideo3d(tester);
      expect(_checkOf(loaded.store).sheet, isNull, reason: '项目打开但还没选中镜头时检查器空态');
      expect(loaded.factory.created, hasLength(1), reason: '项目自动打开并建预览面');
    });

    testWidgets('选中镜头 → 时长 / 相机 6 坐标 / cues 只读；只引用相机的镜头显性只读', (tester) async {
      await seedVideo3dProject();
      final ({AppStore store, _PreviewFactory factory}) loaded =
          await pumpVideo3d(tester);
      final WorkbenchCheckController check = _checkOf(loaded.store);

      await tester.tap(find.byKey(const ValueKey('video3d-shot-s1')));
      await tester.pump();
      final CheckSheet first = check.sheet!;
      expect(first.title, '镜头「s1」');
      expect(first.kindLabel, '镜头');
      expect(first.subtitle, contains('screenplay3d.json'));
      expect(
        first.fields.map((CheckField field) => field.key).toList(),
        <String>[
          'duration',
          'move_from_x',
          'move_from_y',
          'move_from_z',
          'move_to_x',
          'move_to_y',
          'move_to_z',
          'cues',
        ],
      );
      expect((first.field('duration')!.value! as num).toDouble(), 5.0);
      expect(
        first.field('duration')!.min,
        video3dMinShotDuration,
        reason: '时长下限 = 一帧',
      );
      expect((first.field('move_from_y')!.value! as num).toDouble(), 1.0);
      expect((first.field('move_to_z')!.value! as num).toDouble(), 2.0);
      expect(first.field('cues')!.kind, CheckFieldKind.readOnly);
      expect(first.field('cues')!.value, '0');

      await tester.tap(find.byKey(const ValueKey('video3d-shot-s2')));
      await tester.pump();
      final CheckSheet second = check.sheet!;
      expect(second.title, '镜头「s2」');
      expect(
        second.fields.map((CheckField field) => field.key).toList(),
        <String>['duration', 'camera', 'cues'],
        reason: '只引用场景相机的镜头没有可编辑坐标，显性只读',
      );
      final CheckField camera = second.field('camera')!;
      expect(camera.kind, CheckFieldKind.readOnly);
      expect('${camera.value}', contains('hero'));
    });

    testWidgets('改时长 → update true，screenplay3d.json 落盘变化、预览与镜头条重建', (
      tester,
    ) async {
      await seedVideo3dProject();
      final ({AppStore store, _PreviewFactory factory}) loaded =
          await pumpVideo3d(tester);
      final WorkbenchCheckController check = _checkOf(loaded.store);
      await tester.tap(find.byKey(const ValueKey('video3d-shot-s1')));
      await tester.pump();

      final String sceneBefore = _fileSignature(video3dPath('scene3d.json'));
      final bool ok = (await tester.runAsync(
        () => check.update('duration', 6.0),
      ))!;
      expect(ok, isTrue, reason: '合法时长必须真的保存成功');
      await tester.pump();

      final Map<String, dynamic> screenplay = _readJson(
        video3dPath('screenplay3d.json'),
      );
      final Map<dynamic, dynamic> shot =
          (screenplay['shots'] as List).first as Map<dynamic, dynamic>;
      expect((shot['duration'] as num).toDouble(), closeTo(6.0, 1e-9));
      expect(
        _fileSignature(video3dPath('scene3d.json')),
        sceneBefore,
        reason: '只替换事实源内容；场景文件字节不变',
      );
      expect(
        loaded.factory.created,
        hasLength(2),
        reason: '保存成功后重建预览面（旧预览面释放）',
      );
      expect(
        loaded.factory.created.last.totalFrames,
        270,
        reason: '6s + 3s @30fps = 270 帧：预览面与镜头条按新帧表重建',
      );
      expect(
        (check.sheet!.field('duration')!.value! as num).toDouble(),
        closeTo(6.0, 1e-9),
      );

      // 镜头条比例随之变化：s1 占 6/9。
      await tester.pump();
      final Size s1 = tester.getSize(
        find.byKey(const ValueKey('video3d-shot-s1')),
      );
      final Size s2 = tester.getSize(
        find.byKey(const ValueKey('video3d-shot-s2')),
      );
      expect(
        s1.width / (s1.width + s2.width),
        closeTo(6.0 / 9.0, 0.02),
        reason: '镜头条按新帧表比例重排',
      );
    });

    testWidgets('改相机 from 坐标 → update true 且 screenplay3d.json 落盘变化', (
      tester,
    ) async {
      await seedVideo3dProject();
      final ({AppStore store, _PreviewFactory factory}) loaded =
          await pumpVideo3d(tester);
      final WorkbenchCheckController check = _checkOf(loaded.store);
      await tester.tap(find.byKey(const ValueKey('video3d-shot-s1')));
      await tester.pump();

      final bool ok = (await tester.runAsync(
        () => check.update('move_from_y', 2.0),
      ))!;
      expect(ok, isTrue);
      await tester.pump();

      final Map<String, dynamic> screenplay = _readJson(
        video3dPath('screenplay3d.json'),
      );
      final Map<dynamic, dynamic> shot =
          (screenplay['shots'] as List).first as Map<dynamic, dynamic>;
      final Map<dynamic, dynamic> move =
          (shot['camera'] as Map<dynamic, dynamic>)['move']
              as Map<dynamic, dynamic>;
      expect((move['from'] as List).map((Object? v) => v).toList(), <Object?>[
        0,
        2,
        5,
      ]);
      expect(
        (check.sheet!.field('move_from_y')!.value! as num).toDouble(),
        closeTo(2.0, 1e-9),
      );
    });

    testWidgets('非法值 → update false 且两份事实源逐字节不变', (tester) async {
      await seedVideo3dProject();
      final ({AppStore store, _PreviewFactory factory}) loaded =
          await pumpVideo3d(tester);
      final WorkbenchCheckController check = _checkOf(loaded.store);
      await tester.tap(find.byKey(const ValueKey('video3d-shot-s1')));
      await tester.pump();

      final String sceneBefore = _fileSignature(video3dPath('scene3d.json'));
      final String screenplayBefore = _fileSignature(
        video3dPath('screenplay3d.json'),
      );

      expect(
        (await tester.runAsync(() => check.update('duration', 0)))!,
        isFalse,
      );
      expect(
        (await tester.runAsync(() => check.update('duration', 0.01)))!,
        isFalse,
        reason: '镜头时长不足一帧',
      );
      expect(
        (await tester.runAsync(() => check.update('duration', 'abc')))!,
        isFalse,
      );
      expect(
        (await tester.runAsync(() => check.update('move_from_z', double.nan)))!,
        isFalse,
        reason: '坐标必须是有限数字',
      );
      expect(
        (await tester.runAsync(() => check.update('cues', 3)))!,
        isFalse,
        reason: 'cues 数量只读，契约外字段不得写入',
      );

      expect(_fileSignature(video3dPath('scene3d.json')), sceneBefore);
      expect(
        _fileSignature(video3dPath('screenplay3d.json')),
        screenplayBefore,
      );
    });

    testWidgets('宽屏内容区检查器降级只读；窄屏不渲染（行为不变）', (tester) async {
      await seedVideo3dProject();
      await pumpVideo3d(tester);
      expect(
        find.byKey(const ValueKey('video3d-inspector-readonly-hint')),
        findsOneWidget,
        reason: '宽屏下镜头属性编辑在右侧「检查」tab，内容区检查器只读',
      );

      await tester.pumpWidget(
        _wrap(video3dAppStore(), const SizedBox.shrink()),
      );
      await tester.pump();

      await pumpVideo3d(tester, size: const Size(820, 700));
      expect(
        find.byKey(const ValueKey('video3d-inspector')),
        findsNothing,
        reason: '窄屏本来就不渲染内容检查器，行为保持原样',
      );
    });

    testWidgets('卸载只清自己的控制器注册', (tester) async {
      await seedVideo3dProject();
      final ({AppStore store, _PreviewFactory factory}) loaded =
          await pumpVideo3d(tester);
      expect(loaded.store.checkController, isNotNull);
      await tester.pumpWidget(_wrap(loaded.store, const SizedBox.shrink()));
      await tester.pump();
      expect(loaded.store.checkController, isNull);
    });

    testWidgets('卸载不清别的工作台已接管的控制器', (tester) async {
      await seedVideo3dProject();
      final ({AppStore store, _PreviewFactory factory}) loaded =
          await pumpVideo3d(tester);
      final WorkbenchCheckController foreign = _ForeignController();
      addTearDown(foreign.dispose);
      loaded.store.setCheckController(foreign);
      await tester.pumpWidget(_wrap(loaded.store, const SizedBox.shrink()));
      await tester.pump();
      expect(
        loaded.store.checkController,
        same(foreign),
        reason: '清空必须先判身份，不能把别的工作台的控制器清掉',
      );
    });
  });
}
