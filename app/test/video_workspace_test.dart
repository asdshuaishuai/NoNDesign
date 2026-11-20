// 视频工作区（代码动画版）的行为测试。
//
// 覆盖本批次不可回退的语义：
//  1. 主区是**正在播的代码动画**：铺满整块工作区（不再有常驻右侧编辑栏），
//     打开即第一帧就绪（不自动播放），播放/暂停/时间条都在播放器里；
//  2. 编辑类功能不丢：示例选择、帧率、编辑脚本、规范对照状态都收进同一条
//     46px 工具条（窄屏进 ⋯ 菜单），结果是弹层——不占画面；
//  3. 成片导出（mp4）从界面撤掉：没有渲染按钮、没有进度轮询、没有产物文件夹
//     入口，也没有「手机上不能出片」这类提示——手机/桌面同一套播放行为；
//  4. 脚本编辑器与规范对照仍是创作面：坏规范当场落到一句人话，好脚本重新通过；
//  5. 艺术架里**已有的** mp4 仍能打开播放（videoLoadOnOpen → 播放面 + 路径行）；
//  6. 旧版本遗留的渲染任务号被静默清掉（不再有任何轮询/恢复界面）；
//  7. 视频是**独立工作区**：没有项目也能从 `plugin:video` 直接进播放面，不挂
//     设计检查器/不建项目、不继承当前项目；只有显式「返回主页」才离开；
//  8. 时间轴与生命周期：改帧率总帧数重算（播放按新帧率走表）、切示例换文档
//     实例（旧计时器与旧帧缓存随旧播放面释放）、320 宽窄屏不溢出。
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import 'package:nondesign/core/app_paths.dart';
import 'package:nondesign/core/capability_hub.dart';
import 'package:nondesign/core/keys.dart';
import 'package:nondesign/core/platform_capabilities.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/core/toast_service.dart';
import 'package:nondesign/core/video_clip.dart';
import 'package:nondesign/core/video_project.dart';
import 'package:nondesign/core/video_samples.dart';
import 'package:nondesign/core/video_service.dart';
import 'package:nondesign/plugins/registry.dart';
import 'package:nondesign/widgets/right_panel.dart' show Inspector;
import 'package:nondesign/widgets/video_animation_surface.dart';
import 'package:nondesign/widgets/video_clip_surface.dart';
import 'package:nondesign/widgets/video_player_surface.dart';
import 'package:nondesign/widgets/video_workspace.dart';

const _mp4 = '/Users/x/Documents/NoNDesign/videos/job-1/frames.mp4';

/// 每个测试一个临时项目根：`AppPaths.projectsRootOverride` 指到这里，
/// `VideoProjectStore.instance`（路由/const 工作台）也不会扫真实用户目录。
Directory? _tmpRoot;

/// 可编排的本地服务：示例文档与对照结果都可替换（坏脚本 / 坏规范 / 失败结论）。
class _FakeVideoService extends VideoService {
  _FakeVideoService({super.host, this.sample, this.reviewResult});

  final VideoDocument? sample;
  final VideoReviewResult? reviewResult;

  @override
  VideoDocument loadSample(int index) => sample ?? super.loadSample(index);

  @override
  VideoReviewResult review({
    required Map<String, dynamic> timeline,
    required Map<String, dynamic>? spec,
    int samples = 6,
  }) =>
      reviewResult ?? super.review(timeline: timeline, spec: spec, samples: samples);
}

/// 没有任何内置示例的安装形态（资源缺失/裁剪构建）：工作台必须落到空态，
/// 不能对空列表做 `clamp(0, -1)`。
class _EmptySamplesVideoService extends VideoService {
  _EmptySamplesVideoService() : super(host: VideoHost.macos);

  @override
  List<VideoSampleInfo> get samples => const <VideoSampleInfo>[];
}

VideoDocument _sampleDoc() => VideoService(host: VideoHost.macos).loadSample(0);

AppStore _store({
  ToastService? toasts,
  HostOs os = HostOs.macos,
}) {
  final store = AppStore(
    toasts: toasts ?? ToastService(autoDismiss: false),
    capabilities: CapabilityHub(platform: PlatformCapabilities.forOs(os)),
  )..ready = true;
  // saveSettings 的镜像目录也指到临时目录：测试不写真实用户目录。
  final root = _tmpRoot;
  if (root != null) store.settingsMirrorDir = '${root.path}/state';
  return store;
}

Widget _wrap(AppStore store, VideoService service) => ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(
        theme: AppTheme.build(dark: true),
        // 与 main.dart 同一条路径：手机 +10%、平板 +5% 字号缩放。
        builder: (context, child) =>
            withResponsiveTextScale(context, child ?? const SizedBox.shrink()),
        home: Scaffold(body: VideoWorkspace(service: service)),
      ),
    );

Future<void> _pump(
  WidgetTester tester,
  AppStore store,
  VideoService service, {
  Size size = const Size(1440, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(_wrap(store, service));
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 80));
}

String _lastToastTitle(AppStore store) =>
    store.toasts.history.isEmpty ? '' : store.toasts.history.first.title;

Text _timeText(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const ValueKey('video-animation-time')));

/// `mm:ss.SSS / mm:ss.SSS` → 前一段的秒数。
double _secondsOf(String readout) {
  final first = readout.split('/').first.trim();
  final parts = first.split(':');
  return int.parse(parts[0].trim()) * 60 + double.parse(parts[1]);
}

/// 播放器帧号读数 → (当前 1 基帧号, 总帧数)。
(int, int) _frameNumbers(WidgetTester tester) {
  final text =
      tester.widget<Text>(find.byKey(const ValueKey('video-animation-frame'))).data!;
  final match = RegExp(r'^frame (\d+)/(\d+)$').firstMatch(text)!;
  return (int.parse(match.group(1)!), int.parse(match.group(2)!));
}

/// 走真实路由（[pluginWorkspaceFor]）而不是直接 new 工作台：锁住「从
/// `plugin:video` 视图名就能进播放面，与是否打开项目无关」。
Widget _wrapRoute(AppStore store, Widget child) => ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(
        theme: AppTheme.build(dark: true),
        builder: (context, child) =>
            withResponsiveTextScale(context, child ?? const SizedBox.shrink()),
        home: Scaffold(body: child),
      ),
    );

Future<void> _pumpRoute(
  WidgetTester tester,
  AppStore store,
  Widget child, {
  Size size = const Size(1440, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(_wrapRoute(store, child));
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 80));
}

// ---- WebView 平台桩（产物模式真要构造播放面时用；本文件不打真平台）----

class _FakeVideoPlatform extends WebViewPlatform {
  _FakeVideoController? lastController;

  @override
  PlatformWebViewController createPlatformWebViewController(
      PlatformWebViewControllerCreationParams params) =>
      lastController = _FakeVideoController(params);

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
          PlatformNavigationDelegateCreationParams params) =>
      _FakeVideoNavigationDelegate(params);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(PlatformWebViewWidgetCreationParams params) =>
      _FakeVideoWebViewWidget(params);
}

class _FakeVideoController extends PlatformWebViewController {
  _FakeVideoController(super.params) : super.implementation();

  final List<String> loadedFiles = [];

  @override
  Future<void> setJavaScriptMode(JavaScriptMode mode) async {}

  @override
  Future<void> setPlatformNavigationDelegate(dynamic delegate) async {}

  @override
  Future<void> loadFile(String absoluteFilePath) async => loadedFiles.add(absoluteFilePath);
}

class _FakeVideoNavigationDelegate extends PlatformNavigationDelegate {
  _FakeVideoNavigationDelegate(super.params) : super.implementation();

  @override
  Future<void> setOnHttpError(HttpResponseErrorCallback cb) async {}

  @override
  Future<void> setOnWebResourceError(WebResourceErrorCallback cb) async {}
}

class _FakeVideoWebViewWidget extends PlatformWebViewWidget {
  _FakeVideoWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

Future<_FakeVideoPlatform> _installFakeWebView() async {
  final fake = _FakeVideoPlatform();
  WebViewPlatform.instance = fake;
  addTearDown(() => WebViewPlatform.instance = WebKitWebViewPlatform());
  return fake;
}

void main() {
  setUp(() async {
    // setVideoState → saveSettings：无 mock 时 getInstance 抛 MissingPluginException。
    SharedPreferences.setMockInitialValues({});
    videoLoadOnOpen = null;
    _tmpRoot = await Directory.systemTemp.createTemp('nan-video-ws-test-');
    AppPaths.projectsRootOverride = _tmpRoot;
  });
  tearDown(() async {
    videoLoadOnOpen = null;
    AppPaths.projectsRootOverride = null;
    final root = _tmpRoot;
    _tmpRoot = null;
    if (root != null && root.existsSync()) await root.delete(recursive: true);
  });

  testWidgets('打开即满幅播放面：编辑动作收进工具条，不再常驻侧栏', (tester) async {
    final store = _store();
    final service = _FakeVideoService(sample: _sampleDoc());
    await _pump(tester, store, service);

    expect(find.text('视频工作台'), findsOneWidget);
    // 主区就是一整块播放器：不再有 340 宽的常驻编辑栏。
    expect(find.byKey(const ValueKey('video-animation-surface')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('video-animation-surface'))).width,
      greaterThan(1200),
    );
    expect(find.byKey(const ValueKey('video-animation-play')), findsOneWidget);
    expect(_timeText(tester).data, '00:00.000 / 00:08.000');

    // 功能没丢：示例 / 帧率 / 脚本 / 对照 / 加载示例都在同一条工具条上。
    expect(find.text('标杆示例'), findsOneWidget);
    expect(find.text('物理 · 斜面摩擦力'), findsOneWidget);
    expect(find.text('帧率 30'), findsOneWidget);
    expect(find.text('编辑脚本'), findsOneWidget);
    expect(find.text('规范对照'), findsOneWidget);
    expect(find.text('加载示例'), findsOneWidget);
    expect(find.byKey(const ValueKey('video-review-chip')), findsOneWidget);
    // 帧率是弹层：同一时刻只有播放器自己那根时间滑条。
    expect(find.byType(Slider), findsOneWidget);
    // 播放器底部一行仍保留「不导出成片」的口径（不抢画面）。
    expect(find.text('代码动画直接播放，暂不导出成片'), findsOneWidget);

    // 旧的渲染面彻底撤掉。
    expect(find.byType(VideoPlayerSurface), findsNothing);
    expect(find.text('渲染（后台）'), findsNothing);
    expect(find.textContaining('渲染'), findsNothing);
    expect(find.text('在文件夹中显示'), findsNothing);
  });

  testWidgets('没有任何内置示例：空态 + 人话，不因 clamp(0, -1) 崩', (tester) async {
    final store = _store();
    await _pump(tester, store, _EmptySamplesVideoService());

    expect(tester.takeException(), isNull);
    expect(find.text('还没有视频'), findsOneWidget);
    expect(find.text('内置示例没能加载，请重新安装应用'), findsOneWidget);
    expect(find.byKey(const ValueKey('video-animation-surface')), findsNothing);
  });

  testWidgets('示例选择：工具条下拉换示例，画面时长跟着换', (tester) async {
    final store = _store();
    final service = VideoService(host: VideoHost.macos);
    await _pump(tester, store, service);
    final second = service.loadSample(1);

    await tester.tap(find.byKey(const ValueKey('video-sample-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('生物 · 细胞有丝分裂'));
    await tester.pumpAndSettle();

    expect(find.text('生物 · 细胞有丝分裂'), findsOneWidget);
    expect(
      _timeText(tester).data,
      '00:00.000 / ${formatVideoTime(second.totalSeconds)}',
    );
    expect(find.byKey(const ValueKey('video-animation-surface')), findsOneWidget);
  });

  testWidgets('帧率是紧凑弹层：改完立即按新帧率播放', (tester) async {
    final store = _store();
    final service = _FakeVideoService(sample: _sampleDoc());
    await _pump(tester, store, service);

    expect(find.text('帧率 30'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('video-fps-control')));
    await tester.pumpAndSettle();
    expect(find.text('播放帧率'), findsOneWidget);

    final slider = tester.widget<Slider>(find.byKey(const ValueKey('video-fps-slider')));
    slider.onChanged!(20);
    await tester.pump();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    expect(find.text('帧率 20'), findsOneWidget);
    expect(find.byKey(const ValueKey('video-animation-surface')), findsOneWidget);
  });

  testWidgets('规范对照是一枚状态 chip，点开是结果 sheet', (tester) async {
    final store = _store();
    final service = _FakeVideoService(sample: _sampleDoc());
    await _pump(tester, store, service);

    expect(find.text('未通过'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('video-review-chip')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('video-review-sheet')), findsOneWidget);
    expect(find.textContaining('对照检查通过'), findsWidgets);
    expect(find.text('技术详情'), findsNothing, reason: '通过时没有原始诊断可看');
  });

  testWidgets('对照 FAIL：chip 变「未通过」，点开就近看到原因', (tester) async {
    final store = _store();
    final service = _FakeVideoService(
      sample: _sampleDoc(),
      reviewResult: const VideoReviewResult(
        ok: false,
        totalSeconds: 8,
        problems: <String>['第 1 个节拍落在片长之外（99.0 秒）'],
        notes: <String>['规范里写了 3 幕，脚本里有 2 个场景'],
        technical: <String>['beat_out_of_range:99.0'],
      ),
    );
    await _pump(tester, store, service);

    expect(find.text('未通过'), findsOneWidget);
    // 对照失败不等于不能看：代码动画照样在第一帧。
    expect(find.byKey(const ValueKey('video-animation-surface')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('video-review-chip')));
    await tester.pumpAndSettle();
    expect(find.textContaining('第 1 个节拍落在片长之外'), findsWidgets);
    expect(find.text('需要修正'), findsOneWidget);
    // notes 与 technical 都在同一张 sheet 里。
    expect(find.text('值得留意'), findsOneWidget);
    expect(find.text('技术详情'), findsOneWidget);
  });

  testWidgets('手机（iOS 390）与桌面同一套：没有「不能出片」的提示', (tester) async {
    final store = _store(os: HostOs.ios);
    final service = _FakeVideoService(host: VideoHost.ios, sample: _sampleDoc());
    await _pump(tester, store, service, size: const Size(390, 844));

    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('video-animation-surface')), findsOneWidget);
    // 窄屏也保留示例名与「加载示例」，其余动作收进 ⋯ 菜单。
    expect(find.text('标杆示例'), findsOneWidget);
    expect(find.text('加载示例'), findsOneWidget);
    expect(find.byKey(const ValueKey('video-more-menu')), findsOneWidget);
    expect(find.textContaining('视频导出只在电脑上可用'), findsNothing);
    expect(find.textContaining('手机上不能出片'), findsNothing);
    expect(find.text('渲染（后台）'), findsNothing);

    // 收进 ⋯ 的动作仍然可达：帧率与脚本编辑都在。
    await tester.tap(find.byKey(const ValueKey('video-more-menu')));
    await tester.pumpAndSettle();
    expect(find.text('帧率 30'), findsOneWidget);
    expect(find.text('编辑脚本'), findsOneWidget);
    await tester.tapAt(const Offset(6, 6));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('脚本编辑器：粘贴坏规范 → 本地校验失败并退回空态', (tester) async {
    final store = _store();
    final service = _FakeVideoService(sample: _sampleDoc());
    await _pump(tester, store, service);

    await tester.tap(find.widgetWithText(TextButton, '编辑脚本'));
    await tester.pump(const Duration(milliseconds: 100));

    // 两个输入框：时间线脚本 / 规范。把规范换成空对象。
    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(2));
    await tester.enterText(fields.at(1), '{}');
    await tester.tap(find.text('检查并载入'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('说明规范不完整'), findsWidgets);
    expect(find.byKey(const ValueKey('video-animation-surface')), findsNothing);
    expect(find.text('还没有视频'), findsOneWidget);
    expect(find.text('未通过'), findsOneWidget);
  });

  testWidgets('脚本编辑器：粘贴合规脚本 → 重新通过对照并回到第一帧', (tester) async {
    final store = _store();
    final service = _FakeVideoService(sample: _sampleDoc());
    await _pump(tester, store, service);

    await tester.tap(find.widgetWithText(TextButton, '编辑脚本'));
    await tester.pump(const Duration(milliseconds: 100));
    final fields = find.byType(TextField);
    await tester.enterText(
      fields.at(0),
      '{"fps": 10, "width": 640, "height": 360, "scenes": [{"duration": 1.0, '
          '"elements": [{"type": "text", "text": "hi", "x": "50%", "y": 100}]}]}',
    );
    await tester.enterText(
      fields.at(1),
      '{"kind": "science", "subject": "小样", "laws": ["x"], '
          '"assumptions": ["y"], "facts": ["z"]}',
    );
    await tester.tap(find.text('检查并载入'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byKey(const ValueKey('video-animation-surface')), findsOneWidget);
    expect(_timeText(tester).data, '00:00.000 / 00:01.000');
    expect(find.text('未通过'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('video-review-chip')));
    await tester.pumpAndSettle();
    expect(find.textContaining('对照检查通过'), findsWidgets);
  });

  testWidgets('脚本里出现 1e999：编辑器内干净拒绝，不把底层异常抛给工作台', (tester) async {
    final store = _store();
    final service = _FakeVideoService(sample: _sampleDoc());
    await _pump(tester, store, service);

    await tester.tap(find.widgetWithText(TextButton, '编辑脚本'));
    await tester.pump(const Duration(milliseconds: 100));
    final fields = find.byType(TextField);
    await tester.enterText(
      fields.at(0),
      '{"fps": 1e999, "width": 640, "height": 360, "scenes": '
          '[{"duration": 1.0, "elements": []}]}',
    );
    await tester.enterText(
      fields.at(1),
      '{"kind": "science", "subject": "小样", "laws": ["x"], '
          '"assumptions": ["y"], "facts": ["z"]}',
    );
    await tester.tap(find.text('检查并载入'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.takeException(), isNull);
    expect(find.text('还没有视频'), findsOneWidget);
    expect(find.text('脚本格式不对，请检查括号、引号与逗号'), findsOneWidget);
    expect(find.text('未通过'), findsOneWidget);
  });

  testWidgets('产物模式：videoLoadOnOpen 仍打开 mp4 播放面（既有产物可播）', (tester) async {
    final fake = await _installFakeWebView();
    videoLoadOnOpen = _mp4;
    final store = _store();
    final service = _FakeVideoService(sample: _sampleDoc());
    await _pump(tester, store, service);

    expect(find.textContaining('视频产物'), findsOneWidget);
    expect(find.text('返回创作台'), findsOneWidget);
    expect(find.byType(VideoPlayerSurface), findsOneWidget);
    expect(find.text('复制路径'), findsOneWidget);
    expect(find.byType(VideoAnimationSurface), findsNothing);
    expect(fake.lastController!.loadedFiles, [_mp4]);

    // 回到创作面：动画面板重新出现。
    await tester.tap(find.text('返回创作台'));
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.byKey(const ValueKey('video-animation-surface')), findsOneWidget);
  });

  testWidgets('旧版本遗留的渲染任务号：静默清掉，不留任何轮询/恢复界面', (tester) async {
    final store = _store();
    store.settings.videoJob = 'video-gone-1';
    final service = _FakeVideoService(sample: _sampleDoc());
    await _pump(tester, store, service);

    expect(store.settings.videoJob, isEmpty);
    expect(_lastToastTitle(store), isEmpty);
    expect(find.textContaining('渲染'), findsNothing);
  });

  // -------------------------------------------------------------------------
  // 工作区独立性（用户新规则）：视频是独立工作区，不属于任何设计项目
  // -------------------------------------------------------------------------

  testWidgets('独立工作区：无项目时 plugin:video 直接出播放面，不挂设计检查器/不建项目', (tester) async {
    final store = _store();
    expect(store.hasProject, isFalse);
    store.setView('plugin:video');

    // 走真实注册表路由：`plugin:video` 这个名字自己就能构出工作台。
    final route = pluginWorkspaceFor(store.view);
    expect(route, isA<VideoWorkspace>());
    await _pumpRoute(tester, store, route!);

    // 播放面直接可用：文档来自视频服务内置示例，与是否有项目无关。
    expect(find.byKey(const ValueKey('video-animation-surface')), findsOneWidget);
    expect(_timeText(tester).data, '00:00.000 / 00:08.000');
    expect(store.hasProject, isFalse);
    expect(store.projectPath, isNull);
    // 设计侧重型面板一个都不在（没有项目也不会被拉进设计工作区）。
    expect(find.byType(Inspector), findsNothing);

    // 播放 / 拖时间 / 换示例 / 开帧率弹层 / 开关对照 sheet：都不离开视频。
    await tester.tap(find.byKey(const ValueKey('video-animation-play')));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.byKey(const ValueKey('video-animation-play')));
    await tester.pump(const Duration(milliseconds: 50));

    tester.widget<Slider>(find.byKey(const ValueKey('video-animation-slider'))).onChanged!(3.0);
    await tester.pump();
    expect(_secondsOf(_timeText(tester).data!), closeTo(3.0, 1e-6));

    await tester.tap(find.byKey(const ValueKey('video-sample-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('生物 · 细胞有丝分裂').last);
    await tester.pumpAndSettle();
    expect(_timeText(tester).data, '00:00.000 / ${formatVideoTime(10)}');

    await tester.tap(find.byKey(const ValueKey('video-fps-control')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('video-review-chip')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('video-review-sheet')), findsOneWidget);
    await tester.tapAt(const Offset(6, 6));
    await tester.pumpAndSettle();

    // 全程没有离开视频工作区、也没有因为视频操作建立/切换到项目。
    expect(store.view, 'plugin:video');
    expect(store.hasProject, isFalse);
    expect(store.projectPath, isNull);
    expect(find.byKey(const ValueKey('video-animation-surface')), findsOneWidget);
    expect(tester.takeException(), isNull);

    // 只有显式的「返回主页」按钮才离开：视频是独立工作区，回主页（模块入口），
    // 不是回某个设计项目的画布。
    expect(find.byTooltip('返回主页'), findsOneWidget);
    expect(find.byTooltip('返回设计 ${modCombo('⌘1')}'), findsNothing);
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pump();
    expect(store.view, 'home');
    expect(store.view, isNot('design'));
  });

  testWidgets('视频工作区不继承当前项目：已有项目时进 plugin:video 仍是视频示例', (tester) async {
    final store = _store();
    // 模拟「已打开一个设计项目」：项目态与视频工作台毫无关系。
    store.hasProject = true;
    store.projectName = 'demo';
    store.projectPath = '/tmp/demo.ddp';
    store.setView('plugin:video');

    await _pumpRoute(tester, store, pluginWorkspaceFor(store.view)!);

    expect(find.byKey(const ValueKey('video-animation-surface')), findsOneWidget);
    expect(_timeText(tester).data, '00:00.000 / 00:08.000');
    expect(find.byType(Inspector), findsNothing);

    // 视频内的操作不碰项目态、也不换视图。
    await tester.tap(find.byKey(const ValueKey('video-load-sample')));
    await tester.pump();
    expect(store.view, 'plugin:video');
    expect(store.hasProject, isTrue);
    expect(store.projectPath, '/tmp/demo.ddp');
    expect(tester.takeException(), isNull);
  });

  // -------------------------------------------------------------------------
  // 时间轴 / 生命周期 / 窄屏
  // -------------------------------------------------------------------------

  testWidgets('帧率改动后时间轴重算：总帧数换成新帧率，播放按新帧率推进', (tester) async {
    final store = _store();
    final service = _FakeVideoService(sample: _sampleDoc());
    await _pump(tester, store, service);

    expect(_frameNumbers(tester), (1, 240));
    expect(_timeText(tester).data, '00:00.000 / 00:08.000');

    // 30 → 10 帧/秒：8 秒片的帧数从 240 变 80，片长不变。
    await tester.tap(find.byKey(const ValueKey('video-fps-control')));
    await tester.pumpAndSettle();
    tester.widget<Slider>(find.byKey(const ValueKey('video-fps-slider'))).onChanged!(10);
    await tester.pump();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    expect(find.text('帧率 10'), findsOneWidget);
    expect(_frameNumbers(tester), (1, 80), reason: '8 秒 × 10 帧/秒 = 80 帧');
    expect(_timeText(tester).data, '00:00.000 / 00:08.000', reason: '改帧率不改变片长');

    // 播放按新帧率走表，且帧号与时间读数同源（同一帧率换算）。
    await tester.tap(find.byKey(const ValueKey('video-animation-play')));
    await tester.pump(const Duration(milliseconds: 450));
    final (currentFrame, totalFrames) = _frameNumbers(tester);
    final seconds = _secondsOf(_timeText(tester).data!);
    expect(totalFrames, 80);
    expect(seconds, greaterThan(0.1));
    expect(currentFrame, (seconds * 10).floor() + 1);

    // 播放中再改帧率：当前时间不回零，总帧数按新帧率重算。
    await tester.tap(find.byKey(const ValueKey('video-fps-control')));
    await tester.pump(const Duration(milliseconds: 250));
    tester.widget<Slider>(find.byKey(const ValueKey('video-fps-slider'))).onChanged!(15);
    await tester.pump();
    await tester.tap(find.text('完成'));
    await tester.pump(const Duration(milliseconds: 250));
    final (_, totalFrames15) = _frameNumbers(tester);
    expect(totalFrames15, 120, reason: '8 秒 × 15 帧/秒 = 120 帧');
    expect(_secondsOf(_timeText(tester).data!), greaterThan(0.1), reason: '改帧率不回到片头');

    // 收尾：暂停，别把计时器留到测试结束。
    await tester.tap(find.byKey(const ValueKey('video-animation-play')));
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);
  });

  testWidgets('切示例即换实例：旧计时器与帧缓存随旧播放面释放，新片从片头开始', (tester) async {
    final store = _store();
    final service = VideoService(host: VideoHost.macos);
    await _pump(tester, store, service);

    final firstDoc =
        tester.widget<VideoAnimationSurface>(find.byType(VideoAnimationSurface)).document;

    // 先播起来：旧实例持有周期计时器（约 33ms 一跳）。
    await tester.tap(find.byKey(const ValueKey('video-animation-play')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(_secondsOf(_timeText(tester).data!), greaterThan(0));

    // 播放中直接切示例：旧实例当场 dispose，新实例从片头开始且不继承播放态。
    await tester.tap(find.byKey(const ValueKey('video-sample-picker')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('生物 · 细胞有丝分裂').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    final next = tester.widget<VideoAnimationSurface>(find.byType(VideoAnimationSurface));
    expect(identical(next.document, firstDoc), isFalse, reason: '切示例必须换文档实例');
    expect(next.document.totalSeconds, 10.0, reason: '新文档来自新示例，不沿用旧帧缓存');
    expect(_timeText(tester).data, '00:00.000 / ${formatVideoTime(10)}');
    expect(_frameNumbers(tester), (1, 300));
    final playIcon = tester.widget<Icon>(find.descendant(
      of: find.byKey(const ValueKey('video-animation-play')),
      matching: find.byType(Icon),
    ));
    expect(playIcon.icon, Icons.play_arrow, reason: '新片停在片头，不继承播放态');

    // 旧计时器若没被 cancel，这里会在已 dispose 的 State 上 setState 抛异常。
    await tester.pump(const Duration(milliseconds: 800));
    expect(tester.takeException(), isNull);
    expect(_timeText(tester).data, '00:00.000 / ${formatVideoTime(10)}');
  });

  testWidgets('320 宽窄屏：工具条与播放器不溢出，更多菜单/对照 sheet 仍可达', (tester) async {
    final store = _store(os: HostOs.ios);
    final service = _FakeVideoService(host: VideoHost.ios, sample: _sampleDoc());
    await _pump(tester, store, service, size: const Size(320, 640));

    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('video-animation-surface')), findsOneWidget);
    expect(find.byKey(const ValueKey('video-sample-picker')), findsOneWidget);
    expect(find.byKey(const ValueKey('video-review-chip')), findsOneWidget);
    expect(find.byKey(const ValueKey('video-more-menu')), findsOneWidget);
    expect(find.byKey(const ValueKey('video-load-sample')), findsOneWidget);
    // 播放器控件都在，画面区没有被压成 0。
    expect(find.byKey(const ValueKey('video-animation-play')), findsOneWidget);
    expect(find.byKey(const ValueKey('video-animation-slider')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('video-animation-surface'))).width,
      greaterThan(280),
    );

    // 收进 ⋯ 的低频动作在 320 宽仍然可达。
    await tester.tap(find.byKey(const ValueKey('video-more-menu')));
    await tester.pumpAndSettle();
    expect(find.text('帧率 30'), findsOneWidget);
    expect(find.text('编辑脚本'), findsOneWidget);
    await tester.tapAt(const Offset(6, 6));
    await tester.pumpAndSettle();

    // 对照 sheet 在窄屏也打得开（三段结论不折行溢出）。
    await tester.tap(find.byKey(const ValueKey('video-review-chip')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('video-review-sheet')), findsOneWidget);
    await tester.tapAt(const Offset(6, 6));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  _clipModeTests();
  _projectModeTests();
}


// ---------------------------------------------------------------------------
// 动效合成（HTML/CSS/JS 短片）接线
// ---------------------------------------------------------------------------

VideoClipInfo _clipInfo(
  int index, {
  String id = '',
  String title = '',
  String subtitle = '',
  String style = 'motion',
  double duration = 13.2,
  List<String> tags = const <String>[],
}) {
  final clipId = id.isEmpty ? 'clip-$index' : id;
  return VideoClipInfo(
    id: clipId,
    title: title.isEmpty ? '动效合成 $index' : title,
    subtitle: subtitle.isEmpty ? '副标题 $index' : subtitle,
    style: style,
    duration: duration,
    tags: tags,
  );
}

/// 测试用播放源：不建 WebView，记录 dispose 以便断言「切模式即释放」。
class _FakeClipPlayback extends VideoClipPlayback {
  _FakeClipPlayback(this.clip, {this.loadError = ''});

  final VideoClipInfo clip;

  @override
  final String loadError;

  double _t = 0;
  bool _playing = false;
  bool _loop = true;

  bool disposed = false;

  @override
  double get t => _t;

  @override
  double get duration => clip.duration;

  @override
  bool get playing => _playing;

  @override
  bool get loop => _loop;

  @override
  bool get ready => true;

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
  Future<void> seek(double seconds) async {
    _t = seconds.clamp(0.0, clip.duration).toDouble();
    notifyListeners();
  }

  @override
  Future<void> restart() async {
    _t = 0;
    _playing = true;
    notifyListeners();
  }

  @override
  Future<void> setLoop(bool value) async {
    _loop = value;
    notifyListeners();
  }

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}

Widget _wrapClips(
  AppStore store,
  VideoService service, {
  required List<VideoClipInfo> clips,
  required VideoClipPlayback Function(VideoClipInfo clip) factory,
}) =>
    ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(
        theme: AppTheme.build(dark: true),
        builder: (context, child) =>
            withResponsiveTextScale(context, child ?? const SizedBox.shrink()),
        home: Scaffold(
          body: VideoWorkspace(
            service: service,
            clips: clips,
            clipPlaybackFactory: factory,
          ),
        ),
      ),
    );

Future<void> _pumpClips(
  WidgetTester tester,
  AppStore store,
  VideoService service,
  List<VideoClipInfo> clips,
  VideoClipPlayback Function(VideoClipInfo clip) factory, {
  Size size = const Size(1440, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(_wrapClips(store, service, clips: clips, factory: factory));
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 80));
}

void _clipModeTests() {
  testWidgets('切到动效合成：出现播放面与运输条，矢量编辑入口消失，视图不变', (tester) async {
    final store = _store();
    store.setView('plugin:video');
    final service = _FakeVideoService(sample: _sampleDoc());
    final clips = <VideoClipInfo>[
      _clipInfo(
        0,
        id: 'sketch-friction',
        title: '摩擦力 · 简笔演示',
        subtitle: '手绘纸面 + 逐笔描线 + 数值滚动',
        style: 'hand',
        duration: 13.2,
        tags: const <String>['简笔', '物理'],
      ),
      _clipInfo(1, title: '动效排版 · 标题落位', subtitle: '字号与字距的层次'),
      _clipInfo(2, title: '界面 · 卡片进场', subtitle: '分层入场与落定'),
      _clipInfo(3, title: '数据 · 折线生长', subtitle: '数字滚动 + 折线描出'),
    ];
    final created = <_FakeClipPlayback>[];
    await _pumpClips(tester, store, service, clips, (clip) {
      final playback = _FakeClipPlayback(clip);
      created.add(playback);
      return playback;
    });

    // 起点仍是矢量动画。
    expect(find.byKey(const ValueKey('video-animation-surface')), findsOneWidget);
    expect(find.byKey(const ValueKey('video-clip-surface')), findsNothing);

    // 选择器分两组：动效合成那 4 条按清单顺序就在菜单里。
    await tester.tap(find.byKey(const ValueKey('video-sample-picker')));
    await tester.pumpAndSettle();
    expect(find.text('矢量动画'), findsOneWidget);
    expect(find.text('动效合成'), findsOneWidget);
    for (final clip in clips) {
      expect(find.text(clip.title), findsOneWidget);
      expect(find.text(clip.subtitle), findsOneWidget);
    }
    await tester.tap(find.text('摩擦力 · 简笔演示'));
    await tester.pumpAndSettle();

    // 主区换成动效合成播放面 + 运输条。
    expect(find.byKey(const ValueKey('video-clip-surface')), findsOneWidget);
    expect(find.byKey(const ValueKey('video-clip-transport')), findsOneWidget);
    expect(find.byKey(const ValueKey('video-clip-play')), findsOneWidget);
    expect(find.byKey(const ValueKey('video-clip-slider')), findsOneWidget);
    expect(find.byKey(const ValueKey('video-clip-time')), findsOneWidget);
    expect(find.byKey(const ValueKey('video-clip-frame')), findsOneWidget);
    expect(find.byKey(const ValueKey('video-clip-loop')), findsOneWidget);
    expect(find.byKey(const ValueKey('video-animation-surface')), findsNothing);

    // 工具条：规格对照 + 加示例在；矢量稿的编辑脚本/帧率不在。
    expect(find.byKey(const ValueKey('video-clip-review-chip')), findsOneWidget);
    expect(find.text('规格对照'), findsOneWidget);
    expect(find.byKey(const ValueKey('video-clip-add-sample')), findsOneWidget);
    expect(find.byKey(const ValueKey('video-edit-script')), findsNothing);
    expect(find.text('编辑脚本'), findsNothing);
    expect(find.byKey(const ValueKey('video-fps-control')), findsNothing);
    expect(find.byKey(const ValueKey('video-review-chip')), findsNothing);

    // 模式口径文案跟着换。
    expect(
      find.text('HTML/CSS/JS 动效合成，应用内实时播放，暂不导出成片'),
      findsOneWidget,
    );
    expect(find.text('代码动画直接播放，暂不导出成片'), findsNothing);

    // 视频是独立工作区：切模式不换视图。
    expect(store.view, 'plugin:video');

    // 规格对照是只读卡：subtitle 与 tags 都在，没有写入口。
    await tester.tap(find.byKey(const ValueKey('video-clip-review-chip')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('video-clip-review-sheet')), findsOneWidget);
    expect(find.text('手绘纸面 + 逐笔描线 + 数值滚动'), findsOneWidget);
    expect(find.text('#简笔'), findsOneWidget);
    expect(find.text('#物理'), findsOneWidget);
    expect(find.text('只读'), findsWidgets);
    expect(find.text('编辑脚本'), findsNothing);
    await tester.tapAt(const Offset(6, 6));
    await tester.pumpAndSettle();

    // 切回矢量动画：原播放面恢复，动效合成的播放源当场释放。
    expect(created, hasLength(1));
    await tester.tap(find.byKey(const ValueKey('video-sample-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('生物 · 细胞有丝分裂'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('video-animation-surface')), findsOneWidget);
    expect(find.byKey(const ValueKey('video-clip-surface')), findsNothing);
    expect(find.byKey(const ValueKey('video-clip-transport')), findsNothing);
    expect(created.single.disposed, isTrue, reason: '切模式必须释放旧播放器');
    expect(store.view, 'plugin:video');
    expect(tester.takeException(), isNull);
  });

  testWidgets('动效合成窄屏（320）：工具条与运输条不溢出，仍可切回矢量', (tester) async {
    final store = _store(os: HostOs.ios);
    final service = _FakeVideoService(host: VideoHost.ios, sample: _sampleDoc());
    final clips = <VideoClipInfo>[_clipInfo(0, title: '动效排版 · 标题落位')];
    await _pumpClips(
      tester,
      store,
      service,
      clips,
      (clip) => _FakeClipPlayback(clip),
      size: const Size(320, 640),
    );

    await tester.tap(find.byKey(const ValueKey('video-sample-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('动效排版 · 标题落位').last);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('video-clip-surface')), findsOneWidget);
    expect(find.byKey(const ValueKey('video-clip-transport')), findsOneWidget);
    expect(find.byKey(const ValueKey('video-clip-review-chip')), findsOneWidget);
    expect(find.byKey(const ValueKey('video-clip-add-sample')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('片段切片段：旧播放源当场释放，新片段接手运输条', (tester) async {
    final store = _store();
    final service = _FakeVideoService(sample: _sampleDoc());
    final clips = <VideoClipInfo>[
      _clipInfo(0, id: 'clip-a', title: '片段 A', duration: 4),
      _clipInfo(1, id: 'clip-b', title: '片段 B', duration: 7),
    ];
    final created = <_FakeClipPlayback>[];
    await _pumpClips(tester, store, service, clips, (clip) {
      final playback = _FakeClipPlayback(clip);
      created.add(playback);
      return playback;
    });

    await tester.tap(find.byKey(const ValueKey('video-sample-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('片段 A'));
    await tester.pumpAndSettle();
    expect(created, hasLength(1));
    expect(find.text('00:00.000 / 00:04.000'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('video-clip-play')));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('video-sample-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('片段 B'));
    await tester.pumpAndSettle();

    expect(created, hasLength(2));
    expect(created[0].disposed, isTrue, reason: '切片段必须释放旧播放源');
    expect(created[1].disposed, isFalse);
    expect(find.text('00:00.000 / 00:07.000'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // 切回矢量动画：第二个播放源也必须释放。
    await tester.tap(find.byKey(const ValueKey('video-sample-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('生物 · 细胞有丝分裂'));
    await tester.pumpAndSettle();
    expect(created[1].disposed, isTrue);
    expect(find.byKey(const ValueKey('video-clip-transport')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('再次选择同一片段：换新播放源并清掉旧错误态', (tester) async {
    final store = _store();
    final service = _FakeVideoService(sample: _sampleDoc());
    final clips = <VideoClipInfo>[
      _clipInfo(0, id: 'clip-a', title: '片段 A', duration: 4),
    ];
    final created = <_FakeClipPlayback>[];
    await _pumpClips(tester, store, service, clips, (clip) {
      final playback = _FakeClipPlayback(
        clip,
        loadError: created.isEmpty ? '动效合成没有启动，可重试' : '',
      );
      created.add(playback);
      return playback;
    });

    await tester.tap(find.byKey(const ValueKey('video-sample-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('片段 A'));
    await tester.pumpAndSettle();
    expect(find.text('动效合成没有启动，可重试'), findsOneWidget);

    // 同一个片段再选一次：旧源（错误态）释放，新源接手，错误面不能留着。
    await tester.tap(find.byKey(const ValueKey('video-sample-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('片段 A').last);
    await tester.pumpAndSettle();

    expect(created, hasLength(2));
    expect(created[0].disposed, isTrue);
    expect(find.text('动效合成没有启动，可重试'), findsNothing);
    expect(find.byKey(const ValueKey('video-clip-error')), findsNothing);
    expect(find.byKey(const ValueKey('video-clip-stage')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('动效合成清单为空：选择器给空态，工作台不崩', (tester) async {
    final store = _store();
    final service = _FakeVideoService(sample: _sampleDoc());
    await _pumpClips(
      tester,
      store,
      service,
      const <VideoClipInfo>[],
      (clip) => _FakeClipPlayback(clip),
    );

    await tester.tap(find.byKey(const ValueKey('video-sample-picker')));
    await tester.pumpAndSettle();
    expect(find.text('暂无动效合成示例'), findsOneWidget);
    await tester.tapAt(const Offset(6, 6));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}

// ---------------------------------------------------------------------------
// 生成项目（NaN 的 video_create 落盘 → 工作台里真的出现并播放）
// ---------------------------------------------------------------------------

/// 每个用例独立的生成项目库（临时视频根，不碰真实用户目录）。
Future<VideoProjectStore> _projectStoreAt() async {
  final root = _tmpRoot;
  final videoRoot = Directory(
    '${root!.path}/video-projects-${DateTime.now().microsecondsSinceEpoch}',
  );
  return VideoProjectStore(root: videoRoot);
}

/// 用内置示例的时间线/规范播一个生成项目（等价于 NaN 的 video_create 落盘）。
Future<VideoProjectSnapshot> _seedProject(
  VideoProjectStore store, {
  required String name,
  required String title,
  int sampleIndex = 1,
}) {
  final doc = VideoService(host: VideoHost.macos).loadSample(sampleIndex);
  return store.create(
    name: name,
    timeline: doc.timeline,
    spec: doc.spec.raw,
    title: title,
  );
}

Widget _wrapProjects(
  AppStore store,
  VideoService service,
  VideoProjectStore projectStore,
) =>
    ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(
        theme: AppTheme.build(dark: true),
        builder: (context, child) =>
            withResponsiveTextScale(context, child ?? const SizedBox.shrink()),
        home: Scaffold(
          body: VideoWorkspace(
            service: service,
            projectStore: projectStore,
            // 动效合成清单注入空表：生成项目用例只管「生成项目」组，不让
            // 真实 assets 加载把等待时机搅浑。
            clips: const <VideoClipInfo>[],
          ),
        ),
      ),
    );

Future<void> _pumpProjects(
  WidgetTester tester,
  AppStore store,
  VideoService service,
  VideoProjectStore projectStore, {
  Size size = const Size(1440, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(_wrapProjects(store, service, projectStore));
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));
}

/// 从播放面里取当前文档（生成项目用例判断「是否真的换成了这一片」）。
VideoDocument _surfaceDoc(WidgetTester tester) =>
    tester.widget<VideoAnimationSurface>(find.byType(VideoAnimationSurface)).document;

void _projectModeTests() {
  testWidgets('生成项目出现在选择器（标题+片长），选中后铺到播放面并写回设置', (tester) async {
    final projectStore = await _projectStoreAt();
    final seeded = await _seedProject(
      projectStore,
      name: 'nan-demo',
      title: 'NaN 生成片',
    );
    final store = _store();
    final service = VideoService(host: VideoHost.macos);
    await _pumpProjects(tester, store, service, projectStore);

    // 默认仍是内置示例（8 秒）。
    expect(find.text('物理 · 斜面摩擦力'), findsOneWidget);
    expect(_surfaceDoc(tester).totalSeconds, 8.0);

    // 选择器里「生成项目」与内置示例并列：标题 + 片长。
    await tester.tap(find.byKey(const ValueKey('video-sample-picker')));
    await tester.pumpAndSettle();
    expect(find.text('生成项目'), findsOneWidget);
    expect(find.text('NaN 生成片'), findsOneWidget);
    expect(
      find.text('片长 ${formatVideoTime(seeded.document.totalSeconds)}'),
      findsOneWidget,
    );

    await tester.tap(find.text('NaN 生成片'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // 播放面换成 read() 出来的文档（10 秒片），工具条标题跟着换。
    expect(find.byKey(const ValueKey('video-animation-surface')), findsOneWidget);
    expect(_surfaceDoc(tester).totalSeconds, seeded.document.totalSeconds);
    expect(identical(_surfaceDoc(tester), seeded.document), isFalse,
        reason: 'read 必须重新构建文档，不能复用 create 的内存对象');
    expect(find.text('NaN 生成片'), findsWidgets);
    expect(find.byKey(const ValueKey('video-project-delete')), findsOneWidget);
    expect(store.settings.videoProjectName, 'nan-demo');
    expect(_lastToastTitle(store), '已打开生成项目「NaN 生成片」');

    // 切回内置示例：设置里的项目名清掉，下次回来续接示例而不是已离开的项目。
    await tester.tap(find.byKey(const ValueKey('video-sample-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('物理 · 斜面摩擦力'));
    await tester.pumpAndSettle();
    expect(store.settings.videoProjectName, isEmpty);
    expect(_surfaceDoc(tester).totalSeconds, 8.0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('NaN 生成完成（store 写 videoProjectName）→ 自动切过去播放', (tester) async {
    final projectStore = await _projectStoreAt();
    final store = _store();
    final service = VideoService(host: VideoHost.macos);
    await _pumpProjects(tester, store, service, projectStore);
    final seeded = await _seedProject(
      projectStore,
      name: 'nan-run',
      title: 'NaN 刚生成',
    );

    // 模拟 root 的 `_adoptWorkspaceArtifact`：video_create 成功 → 写名字 + notify。
    store.setVideoProjectName('nan-run');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(store.settings.videoProjectName, 'nan-run');
    expect(find.byKey(const ValueKey('video-animation-surface')), findsOneWidget);
    expect(_surfaceDoc(tester).totalSeconds, seeded.document.totalSeconds);
    expect(find.text('NaN 刚生成'), findsWidgets);
    expect(_lastToastTitle(store), contains('NaN 刚生成'));
    // 列表也刷新了：选择器里已经能再选一次这个项目。
    await tester.tap(find.byKey(const ValueKey('video-sample-picker')));
    await tester.pumpAndSettle();
    expect(find.text('NaN 刚生成'), findsWidgets);
    await tester.tapAt(const Offset(6, 6));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('run 结束（agentBusy true→false）刷新项目列表：生成中不空白', (tester) async {
    final projectStore = await _projectStoreAt();
    final store = _store();
    final service = VideoService(host: VideoHost.macos);
    await _pumpProjects(tester, store, service, projectStore);

    // run 在飞；项目落盘了但 run 还没收尾。
    store.agentBusy = true;
    store.notifyListeners();
    await tester.pump();
    await _seedProject(projectStore, name: 'during-run', title: 'run 中生成');

    // 生成中：列表不空（给可行动空态人话），不因在飞 run 抖动。
    await tester.tap(find.byKey(const ValueKey('video-sample-picker')));
    await tester.pumpAndSettle();
    expect(
      find.text('还没有生成项目 · 在工作区里让 NaN 做一个视频，跑完后会出现在这里'),
      findsOneWidget,
    );
    await tester.tapAt(const Offset(6, 6));
    await tester.pumpAndSettle();

    // run 收尾：agentBusy true→false → 再刷一次列表，项目现在就出现。
    store.agentBusy = false;
    store.notifyListeners();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    await tester.tap(find.byKey(const ValueKey('video-sample-picker')));
    await tester.pumpAndSettle();
    expect(find.text('run 中生成'), findsOneWidget);
    expect(find.text('片长 00:10.000'), findsOneWidget);
    await tester.tapAt(const Offset(6, 6));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('恢复选中：设置里的项目名在打开工作台时续接，读失败给人话+折叠技术详情', (tester) async {
    final projectStore = await _projectStoreAt();
    final seeded = await _seedProject(
      projectStore,
      name: 'nan-broken',
      title: '坏掉的项目',
    );
    // 规范被手改坏（文件还在，内容不完整）。
    File('${seeded.dir}/spec.json').writeAsStringSync('{"kind": "science"}');

    final store = _store();
    // 模拟上次离开时停在这个项目：名字在设置里。
    store.settings.videoProjectName = 'nan-broken';
    final service = VideoService(host: VideoHost.macos);
    await _pumpProjects(tester, store, service, projectStore);

    expect(find.byKey(const ValueKey('video-project-error')), findsOneWidget);
    expect(find.text('这个生成项目打不开'), findsOneWidget);
    expect(find.text('这份视频项目的说明规范不完整，暂时看不了画面'), findsOneWidget);
    // 裸代号只在折叠的技术详情里，默认不上屏。
    expect(find.textContaining('spec_invalid'), findsNothing);
    expect(find.byKey(const ValueKey('video-animation-surface')), findsNothing);

    // 展开技术详情才看到原始诊断。
    expect(find.text('技术详情'), findsOneWidget);
    await tester.tap(find.text('技术详情'));
    await tester.pumpAndSettle();
    expect(find.textContaining('spec_invalid'), findsOneWidget);

    // 重试仍失败（文件确实还坏着），但界面保持可行动、不崩。
    await tester.tap(find.byKey(const ValueKey('video-project-retry')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.byKey(const ValueKey('video-project-error')), findsOneWidget);

    // 回退到内置示例：设置里的项目名清掉，播放面恢复。
    await tester.tap(find.byKey(const ValueKey('video-project-use-sample')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('video-animation-surface')), findsOneWidget);
    expect(store.settings.videoProjectName, isEmpty);
    expect(_surfaceDoc(tester).totalSeconds, 8.0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('删除项目：确认后删目录、回退到内置示例、列表刷新', (tester) async {
    final projectStore = await _projectStoreAt();
    final seeded = await _seedProject(
      projectStore,
      name: 'nan-del',
      title: '待删除项目',
    );
    final store = _store();
    store.settings.videoProjectName = 'nan-del';
    final service = VideoService(host: VideoHost.macos);
    await _pumpProjects(tester, store, service, projectStore);

    expect(find.byKey(const ValueKey('video-animation-surface')), findsOneWidget);
    expect(_surfaceDoc(tester).totalSeconds, seeded.document.totalSeconds);

    // 第一次点删除后取消：项目与播放都不受影响。
    await tester.tap(find.byKey(const ValueKey('video-project-delete')));
    await tester.pumpAndSettle();
    expect(find.text('删除生成项目'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(Directory(seeded.dir).existsSync(), isTrue);
    expect(store.settings.videoProjectName, 'nan-del');

    // 确认删除：磁盘目录没了、设置清空、播放面回退示例、列表刷新。
    await tester.tap(find.byKey(const ValueKey('video-project-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('video-project-delete-confirm')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(Directory(seeded.dir).existsSync(), isFalse);
    expect(store.settings.videoProjectName, isEmpty);
    expect(find.byKey(const ValueKey('video-animation-surface')), findsOneWidget);
    expect(_surfaceDoc(tester).totalSeconds, 8.0);
    expect(_lastToastTitle(store), '已删除生成项目「待删除项目」');

    await tester.tap(find.byKey(const ValueKey('video-sample-picker')));
    await tester.pumpAndSettle();
    expect(find.text('待删除项目'), findsNothing);
    expect(find.textContaining('还没有生成项目'), findsOneWidget);
    await tester.tapAt(const Offset(6, 6));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('坏项目在列表里标 corrupt；选中后给人话而不是裸代号', (tester) async {
    final projectStore = await _projectStoreAt();
    final root = await projectStore.resolveRoot();
    // 元数据坏掉的目录：list 标 corrupt，read 报 no_project。
    Directory('${root.path}/bad-one').createSync(recursive: true);
    File('${root.path}/bad-one/video.json').writeAsStringSync('{"title": "坏项目"');

    final store = _store();
    final service = VideoService(host: VideoHost.macos);
    await _pumpProjects(tester, store, service, projectStore);

    await tester.tap(find.byKey(const ValueKey('video-sample-picker')));
    await tester.pumpAndSettle();
    expect(find.text('bad-one'), findsOneWidget);
    expect(find.text('打不开 · 文件可能被改动'), findsOneWidget);
    await tester.tap(find.text('bad-one'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));

    expect(find.byKey(const ValueKey('video-project-error')), findsOneWidget);
    expect(find.text('这个视频项目已经不在了，可能已经被删除'), findsOneWidget);
    expect(find.textContaining('no_project'), findsNothing);
    expect(find.text('技术详情'), findsOneWidget);
    await tester.tapAt(const Offset(6, 6));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('没有生成项目时：选择器给可行动空态人话，不出现裸代号', (tester) async {
    final projectStore = await _projectStoreAt();
    final store = _store();
    final service = VideoService(host: VideoHost.macos);
    await _pumpProjects(tester, store, service, projectStore);

    await tester.tap(find.byKey(const ValueKey('video-sample-picker')));
    await tester.pumpAndSettle();
    expect(find.text('生成项目'), findsOneWidget);
    expect(
      find.text('还没有生成项目 · 在工作区里让 NaN 做一个视频，跑完后会出现在这里'),
      findsOneWidget,
    );
    expect(find.textContaining('io_error'), findsNothing);
    await tester.tapAt(const Offset(6, 6));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}


