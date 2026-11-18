// 视频工作区（批次 08：全本地）的行为测试。
//
// 覆盖本批次不可回退的语义：
//  1. 示例加载与规范对照都在本地完成：对照通过才放开渲染，失败原因当场
//     列在按钮旁边（不等点渲染才报错）；
//  2. 渲染走本地任务：创建任务 → 轮询 → 终态（成功/失败）的提示与复位；
//  3. 手机/平板点渲染必须得到明确提示（视频导出只在电脑上可用），
//     不允许「点了没反应」；
//  4. 进程重启后的旧任务号查无此项：清持久化并轻提示，不空转轮询；
//  5. 脚本编辑器提供第二条输入路径：粘贴/修改后本地校验并载入。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nondesign/core/capability_hub.dart';
import 'package:nondesign/core/platform_capabilities.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/core/toast_service.dart';
import 'package:nondesign/core/video_service.dart';
import 'package:nondesign/widgets/video_workspace.dart';

/// 可编排的本地服务：示例文档可替换，渲染任务可脚本化。
class _FakeVideoService extends VideoService {
  _FakeVideoService({
    super.host,
    this.sample,
    this.startError,
    this.nextJob,
  }) : super(videosRoot: () async {
          final dir = Directory.systemTemp.createTempSync('video_ws_test');
          addTearDown(() {
            if (dir.existsSync()) dir.deleteSync(recursive: true);
          });
          return dir;
        });

  final VideoDocument? sample;
  final Object? startError;
  final VideoRenderJob? nextJob;
  final List<String> renderCalls = <String>[];

  /// 轮询读取的任务快照（按 id 返回；null 走真实注册表——空）。
  VideoRenderJob? Function(String id)? jobLookup;

  @override
  VideoDocument loadSample(int index) => sample ?? super.loadSample(index);

  @override
  Future<VideoRenderJob> startRender(
    VideoDocument document, {
    int? fps,
    bool keepSvg = false,
  }) async {
    renderCalls.add('render:${fps ?? document.fps}');
    final error = startError;
    if (error != null) throw error;
    return nextJob!;
  }

  @override
  VideoRenderJob? job(String id) => jobLookup?.call(id);
}

VideoDocument _sampleDoc() => VideoService(host: VideoHost.macos).loadSample(0);

VideoDocument _badBeatsDoc() => VideoDocument.build(
      timeline: <String, dynamic>{
        'fps': 10,
        'width': 640,
        'height': 360,
        'spec': 'screenplay.json',
        'scenes': <dynamic>[
          <String, dynamic>{
            'duration': 2.0,
            'elements': <dynamic>[
              <String, dynamic>{'type': 'text', 'text': 'hi', 'x': '50%', 'y': 100},
            ],
          },
        ],
      },
      spec: <String, dynamic>{
        'kind': 'screenplay',
        'style': '简笔',
        'beats': <dynamic>[
          <String, dynamic>{'at': 99, 'what': '结尾'},
        ],
      },
    );

VideoRenderJob _job({
  VideoJobStatus status = VideoJobStatus.running,
  int frames = 0,
  String? mp4,
}) =>
    VideoRenderJob(
      id: 'job-1',
      status: status,
      fps: 10,
      frames: frames,
      totalFrames: 6,
      totalSeconds: 0.6,
      directory: '/tmp/video-job-1',
      mp4Path: mp4,
    );

AppStore _store({
  ToastService? toasts,
  HostOs os = HostOs.macos,
}) =>
    AppStore(
      toasts: toasts ?? ToastService(autoDismiss: false),
      capabilities: CapabilityHub(platform: PlatformCapabilities.forOs(os)),
    )..ready = true;

Widget _wrap(AppStore store, VideoService service) => ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(
        theme: AppTheme.build(dark: true),
        home: Scaffold(body: VideoWorkspace(service: service)),
      ),
    );

Future<void> _pump(WidgetTester tester, AppStore store, VideoService service) async {
  tester.view.physicalSize = const Size(1440, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(_wrap(store, service));
  await tester.pump(const Duration(milliseconds: 50));
}

OutlinedButton _renderButton(WidgetTester tester) =>
    tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '渲染（后台）'));

String _lastToastTitle(AppStore store) =>
    store.toasts.history.isEmpty ? '' : store.toasts.history.first.title;

void main() {
  setUp(() {
    // setVideoState → saveSettings：无 mock 时 getInstance 抛 MissingPluginException。
    SharedPreferences.setMockInitialValues({});
    videoLoadOnOpen = null;
  });
  tearDown(() => videoLoadOnOpen = null);

  testWidgets('示例在本地载入并完成对照：渲染按钮放开，不依赖任何外部连接', (tester) async {
    final store = _store();
    final service = _FakeVideoService(sample: _sampleDoc());
    await _pump(tester, store, service);

    expect(find.text('视频工作台'), findsOneWidget);
    expect(find.text('标杆示例'), findsOneWidget);
    // 三个内置示例都在。
    expect(service.samples.length, 3);
    // 对照通过（内嵌示例都是干净样例）。
    expect(find.textContaining('对照检查通过'), findsWidgets);
    expect(_renderButton(tester).onPressed, isNotNull);
    // 没有任务在跑。
    expect(store.settings.videoJob, isEmpty);
  });

  testWidgets('对照 FAIL：渲染按钮禁用，失败原因就近可见', (tester) async {
    final store = _store();
    final service = _FakeVideoService(sample: _badBeatsDoc());
    await _pump(tester, store, service);

    expect(_renderButton(tester).onPressed, isNull);
    expect(find.textContaining('第 1 个节拍落在片长之外'), findsWidgets);
  });

  testWidgets('点渲染创建本地任务并进入轮询；完成后续接成功提示', (tester) async {
    final store = _store();
    final service = _FakeVideoService(sample: _sampleDoc(), nextJob: _job());
    service.jobLookup = (id) =>
        _job(status: VideoJobStatus.done, frames: 6, mp4: '/tmp/video-job-1/frames.mp4');
    await _pump(tester, store, service);

    await tester.tap(find.text('渲染（后台）'));
    await tester.pump(const Duration(milliseconds: 50));
    // 任务号已持久化（切视图回来能接回轮询）。
    expect(store.settings.videoJob, 'job-1');
    expect(service.renderCalls.single, 'render:10');
    // 轮询中：按钮禁用。
    expect(_renderButton(tester).onPressed, isNull);

    await tester.pump(const Duration(milliseconds: 400));
    expect(_renderButton(tester).onPressed, isNotNull);
    expect(_lastToastTitle(store), contains('渲染完成'));
    // 终态不再持久化在飞 job。
    expect(store.settings.videoJob, isEmpty);
  });

  testWidgets('渲染失败：人话提示 + 原始诊断只进折叠的技术详情', (tester) async {
    final store = _store();
    final service = _FakeVideoService(
      sample: _sampleDoc(),
      startError: const VideoRejected('rasterizer_missing', 'resvg not found'),
    );
    await _pump(tester, store, service);

    await tester.tap(find.text('渲染（后台）'));
    await tester.pump(const Duration(milliseconds: 50));

    expect(_lastToastTitle(store), '这台电脑缺少把画面转成图片的组件，请先安装后重试');
    expect(find.text('技术详情'), findsOneWidget);
    // 原始诊断默认不展开：展开后才可见。
    await tester.tap(find.text('技术详情'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('rasterizer_missing'), findsOneWidget);
  });

  testWidgets('手机（iOS）：点渲染给明确提示，不创建任何任务', (tester) async {
    final store = _store(os: HostOs.ios);
    final service = _FakeVideoService(host: VideoHost.ios, sample: _sampleDoc());
    await _pump(tester, store, service);

    // 能力文案在按钮下方常驻可见。
    expect(find.text('视频导出只在电脑上可用'), findsOneWidget);
    expect(_renderButton(tester).onPressed, isNotNull);

    await tester.tap(find.text('渲染（后台）'));
    await tester.pump(const Duration(milliseconds: 50));

    expect(_lastToastTitle(store), '视频导出只在电脑上可用');
    expect(service.renderCalls, isEmpty);
    expect(store.settings.videoJob, isEmpty);
  });

  testWidgets('进程重启后的旧任务：清持久化并轻提示，不留空转轮询', (tester) async {
    final store = _store();
    store.settings.videoJob = 'video-gone-1';
    final service = _FakeVideoService(sample: _sampleDoc());
    await _pump(tester, store, service);
    await tester.pump(const Duration(milliseconds: 100));

    expect(store.settings.videoJob, isEmpty);
    expect(_lastToastTitle(store), '上次的渲染任务已经不在了');
  });

  testWidgets('脚本编辑器：粘贴坏规范 → 本地校验失败并禁用渲染', (tester) async {
    final store = _store();
    final service = _FakeVideoService(sample: _sampleDoc());
    await _pump(tester, store, service);

    expect(_renderButton(tester).onPressed, isNotNull);
    await tester.tap(find.widgetWithText(TextButton, '编辑脚本'));
    await tester.pump(const Duration(milliseconds: 100));

    // 两个输入框：时间线脚本 / 规范。把规范换成空对象。
    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(2));
    await tester.enterText(fields.at(1), '{}');
    await tester.tap(find.text('检查并载入'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(_renderButton(tester).onPressed, isNull);
    expect(find.textContaining('说明规范不完整'), findsWidgets);
  });

  testWidgets('脚本编辑器：粘贴合规脚本 → 重新通过对照', (tester) async {
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

    expect(_renderButton(tester).onPressed, isNotNull);
    expect(find.textContaining('对照检查通过'), findsWidgets);
  });
}
