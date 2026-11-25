// 3D 视频预览面回归（task-10）：
//
//   * 纯函数：时间文案 / 失败人话 / 页面错误人话；
//   * Fake 预览控制器：就绪、播放/暂停/停止/seek/seekFrame、错误 → 人话 + 折叠
//     技术详情（**不构造真 WebView**）；
//   * 生产预览面（WebView 平台桩）：运行时文本注入 → assembleVideo3dPreview →
//     loadHtmlString；命令走 window.NONVIDEO3D_PLAYER；桥消息
//     ready / frame / ended / error 回传；播放状态轮询与页面同步；
//   * 显性降级：WebView 不可用、运行时读取失败、运行时空白、平台未就绪、
//     主帧加载失败——人话主文案 + 折叠技术详情，绝不假装可播。
//
// 测试不构造真 WebView：平台接口用桩（与 music_playback_surface_test 同形）。
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nondesign/core/platform_capabilities.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/core/video3d/video3d_compile.dart';
import 'package:nondesign/core/video3d/video3d_contract.dart';
import 'package:nondesign/core/video3d/video3d_player.dart';
import 'package:nondesign/widgets/video3d_preview_surface.dart';
// 平台接口桩直接从平台接口库取（测试专用传递依赖，与 music_playback_surface_test 同形）。
// ignore: depend_on_referenced_packages
import 'package:webview_platform_interface/webview_platform_interface.dart';
import 'package:webview_all_wkwebview/webview_all_wkwebview.dart';

// ---------------------------------------------------------------------------
// Fixtures：契约层合法输入（校验器语义在 video3d_contract_test 覆盖）。
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
      'material': <String, Object?>{
        'color': '#9a8c7a',
        'roughness': 0.9,
        'metalness': 0.0,
      },
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

({Video3dScene scene, Video3dScreenplay screenplay, Video3dTimeline timeline})
_models() {
  final Video3dVerification verification = verifyVideo3d(
    _scene(),
    _screenplay(),
  );
  return (
    scene: verification.scene!,
    screenplay: verification.screenplay!,
    timeline: compileVideo3dTimeline(verification.screenplay!),
  );
}

Widget _app(Widget child) => MaterialApp(
  theme: AppTheme.build(dark: true),
  home: Scaffold(body: child),
);

// ---------------------------------------------------------------------------
// Fake 预览控制器（不构造 WebView）。
// ---------------------------------------------------------------------------

class _FakePreview extends Video3dPreviewController {
  @override
  final int fps = 30;

  @override
  final int totalFrames = 240;

  bool _ready = false;
  bool _playing = false;
  int _frame = 0;
  String _loadError = '';
  String _technicalDetail = '';

  int playCalls = 0;
  int pauseCalls = 0;
  int stopCalls = 0;
  final List<double> seekCalls = <double>[];
  final List<int> seekFrameCalls = <int>[];

  void emitError(String message, [String detail = '']) {
    _ready = true;
    _playing = false;
    _loadError = message;
    _technicalDetail = detail;
    notifyListeners();
  }

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
    seekCalls.add(seconds);
    _frame = (seconds * fps).floor();
    notifyListeners();
  }

  @override
  Future<void> seekFrame(int frame) async {
    seekFrameCalls.add(frame);
    _frame = frame;
    notifyListeners();
  }
}

// ---------------------------------------------------------------------------
// WebView 平台桩（不构造真 WebView；与 music_playback_surface_test 同形）。
// ---------------------------------------------------------------------------

class _FakeWebViewPlatform extends WebViewPlatform {
  _FakeController? lastController;

  /// 为 true 时控制器创建抛错（覆盖「启动失败 → 人话错误面」路径）。
  bool failControllerCreation = false;

  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) {
    if (failControllerCreation) {
      throw StateError('fake controller creation failed');
    }
    return lastController = _FakeController(params);
  }

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => _FakeNavigationDelegate(params);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) => _FakeWebViewWidget(params);
}

class _FakeController extends PlatformWebViewController {
  _FakeController(super.params) : super.implementation();

  String? loadedHtml;
  final List<String> jsCommands = <String>[];
  void Function(JavaScriptMessage)? bridgeCallback;
  _FakeNavigationDelegate? navigationDelegate;

  /// 页面 `window.NONVIDEO3D_PLAYER.state()` 的返回值（状态轮询用）。
  String pageState = 'idle';

  @override
  Future<void> setJavaScriptMode(JavaScriptMode mode) async {}

  @override
  Future<void> addJavaScriptChannel(dynamic params) async {
    if (params.name == video3dPreviewBridgeChannel) {
      bridgeCallback =
          params.onMessageReceived as void Function(JavaScriptMessage);
    }
  }

  @override
  Future<void> setPlatformNavigationDelegate(dynamic delegate) async {
    navigationDelegate = delegate as _FakeNavigationDelegate;
  }

  @override
  Future<void> loadHtmlString(String html, {String? baseUrl}) async {
    loadedHtml = html;
  }

  @override
  Future<void> runJavaScript(String javaScript) async {
    jsCommands.add(javaScript);
  }

  @override
  Future<Object> runJavaScriptReturningResult(String javaScript) async {
    // 先判 state()：状态轮询脚本里也含 `typeof` 守卫。
    if (javaScript.contains('state()')) return pageState;
    if (javaScript.contains('typeof')) return 'object';
    return 'undefined';
  }

  void fireBridge(String json) =>
      bridgeCallback?.call(JavaScriptMessage(message: json));
}

class _FakeNavigationDelegate extends PlatformNavigationDelegate {
  _FakeNavigationDelegate(super.params) : super.implementation();

  void Function(WebResourceError)? onResourceError;

  @override
  Future<void> setOnWebResourceError(WebResourceErrorCallback cb) async =>
      onResourceError = cb;

  void fireMainFrameError() => onResourceError?.call(
    const WebResourceError(
      errorCode: -1009,
      description: 'offline',
      isForMainFrame: true,
    ),
  );
}

class _FakeWebViewWidget extends PlatformWebViewWidget {
  _FakeWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

Future<_FakeWebViewPlatform> _installFakePlatform() async {
  final _FakeWebViewPlatform fake = _FakeWebViewPlatform();
  WebViewPlatform.instance = fake;
  // 平台接口只允许设成非空实现；测试结束还原成真实 WebKit 平台（同音乐播放面测试）。
  addTearDown(() => WebViewPlatform.instance = WebKitWebViewPlatform());
  return fake;
}

Video3dWebPreview _preview({
  String runtime = '/* fake runtime text */',
  PlatformCapabilities? host,
}) {
  final models = _models();
  return Video3dWebPreview(
    scene: models.scene,
    screenplay: models.screenplay,
    timeline: models.timeline,
    host: host,
    runtimeLoader: () async => runtime,
  );
}

void main() {
  setUp(() {
    debugVideo3dPreviewWebViewSupported = null;
  });

  tearDown(() {
    debugVideo3dPreviewWebViewSupported = null;
  });

  group('纯函数', () {
    test('组装失败码 → 人话；原始诊断留给技术详情', () {
      expect(
        video3dPreviewFailureMessage(
          const Video3dPlayerError(video3dRuntimeMissingCode, 'raw'),
        ),
        contains('运行文件'),
      );
      expect(
        video3dPreviewFailureMessage(
          const Video3dPlayerError(video3dTemplateInvalidCode, 'raw'),
        ),
        contains('组装'),
      );
      expect(
        video3dPreviewFailureMessage(
          const Video3dPlayerError(video3dSceneCompileInvalidCode, 'raw'),
        ),
        contains('场景'),
      );
      expect(
        video3dPreviewFailureMessage(
          const Video3dPlayerError('video3d_unknown_code', 'raw'),
        ),
        contains('可以重试'),
      );
    });

    test('页面原始错误 → 人话（不直接上屏原始文本）', () {
      expect(video3dPageErrorMessage('帧表为空：检查镜头时长'), contains('画面数据是空的'));
      expect(video3dPageErrorMessage('预览页初始化失败：画布元素缺失'), contains('初始化'));
      expect(video3dPageErrorMessage('未知炸裂'), contains('预览出错了'));
    });
  });

  group('Fake 预览面（不构造 WebView）', () {
    testWidgets('就绪/播放/暂停/停止/seek/seekFrame 状态变化反映到预览面', (tester) async {
      final _FakePreview fake = _FakePreview();
      await tester.pumpWidget(_app(Video3dPreviewSurface(preview: fake)));
      await tester.pump();

      expect(
        find.byKey(const ValueKey('video3d-preview-surface')),
        findsOneWidget,
      );
      expect(find.text('准备中'), findsOneWidget);
      // Fake 的舞台占位（真 WebView 只在生产控制器里挂）。
      expect(
        find.byKey(const ValueKey('video3d-preview-stage')),
        findsOneWidget,
      );

      await fake.start();
      await tester.pump();
      expect(find.text('可以预览'), findsOneWidget);

      await fake.play();
      await tester.pump();
      expect(fake.playCalls, 1);
      expect(find.text('预览中'), findsOneWidget);

      await fake.pause();
      await tester.pump();
      expect(fake.pauseCalls, 1);
      expect(find.text('可以预览'), findsOneWidget);

      await fake.seekFrame(120);
      expect(fake.seekFrameCalls, <int>[120]);
      await fake.seek(2.0);
      expect(fake.seekCalls, <double>[2.0]);

      await fake.stop();
      await tester.pump();
      expect(fake.stopCalls, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('错误回调 → 人话主文案 + 折叠技术详情；Fake 不显示重试', (tester) async {
      final _FakePreview fake = _FakePreview();
      await tester.pumpWidget(_app(Video3dPreviewSurface(preview: fake)));
      await tester.pump();
      fake.emitError('预览出错了，可以再试一次', 'raw-diagnostic');
      await tester.pump();

      expect(
        find.byKey(const ValueKey('video3d-preview-error')),
        findsOneWidget,
      );
      expect(find.text('预览出错了，可以再试一次'), findsOneWidget);
      expect(find.text('不可用'), findsOneWidget);
      // 原始诊断不直接出现在主区（折叠在「技术详情」里）。
      expect(find.text('技术详情'), findsOneWidget);
      expect(find.text('raw-diagnostic'), findsNothing);
      await tester.tap(find.text('技术详情'));
      await tester.pumpAndSettle();
      expect(find.text('raw-diagnostic'), findsOneWidget);
      // Fake 没有重试语义：重试按钮只对真实预览面出现。
      expect(find.byKey(const ValueKey('video3d-preview-retry')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('生产预览面（WebView 平台桩）', () {
    test('运行时注入 → 组装页 → 命令走页面 API → 桥消息回传', () async {
      await _installFakePlatform();

      final Video3dWebPreview playback = _preview(
        runtime: '/* three runtime injected */',
      );
      await playback.start();
      final _FakeWebViewPlatform platform =
          WebViewPlatform.instance! as _FakeWebViewPlatform;
      final _FakeController controller = platform.lastController!;

      expect(playback.ready, isTrue, reason: '页面 API 出现即就绪');
      expect(playback.totalFrames, 240);
      expect(playback.fps, 30);
      expect(playback.frame, 0);
      final String? html = playback.html;
      expect(html, isNotNull);
      expect(html, contains('<!doctype html>'));
      expect(html, contains('three runtime injected'));
      expect(html, contains('window.NONVIDEO3D_PLAYER'));
      expect(html, contains('window.NONVIDEO3D'));
      expect(controller.loadedHtml, contains('NONVIDEO3D'));
      expect(
        controller.loadedHtml,
        contains('three runtime injected'),
        reason: '运行时文本是经 assembleVideo3dPreview 注入的',
      );
      expect(controller.bridgeCallback, isNotNull, reason: 'NONVIDEO3D 桥必须挂上');

      // 命令面：页面自身 API（不是宿主伪造状态）。
      await playback.play();
      expect(
        controller.jsCommands.last,
        contains('window.NONVIDEO3D_PLAYER.play()'),
      );
      expect(playback.playing, isTrue);
      await playback.pause();
      expect(
        controller.jsCommands.last,
        contains('window.NONVIDEO3D_PLAYER.pause()'),
      );
      expect(playback.playing, isFalse);
      await playback.seek(1.25);
      expect(
        controller.jsCommands.last,
        contains('window.NONVIDEO3D_PLAYER.seek(1.250)'),
      );
      expect(playback.frame, 37, reason: '1.25 秒 × 30fps = 第 37 帧');
      await playback.seekFrame(100);
      expect(
        controller.jsCommands.last,
        contains('window.NONVIDEO3D_PLAYER.seekFrame(100)'),
      );
      expect(playback.frame, 100);
      await playback.stop();
      expect(
        controller.jsCommands.last,
        contains('window.NONVIDEO3D_PLAYER.stop()'),
      );
      expect(playback.frame, 0);

      // ready / frame / ended / error 四类桥消息。
      controller.fireBridge(
        jsonEncode(<String, Object?>{
          'kind': 'ready',
          'fps': 30,
          'total_frames': 240,
          'duration_seconds': 8,
          'renderer': video3dPreviewRenderer,
          'runtime': 'embedded',
        }),
      );
      expect(playback.ready, isTrue);
      expect(playback.totalFrames, 240);
      controller.fireBridge(
        jsonEncode(<String, Object?>{
          'kind': 'frame',
          'frame': 99,
          'seconds': 3.3,
          'total_frames': 240,
        }),
      );
      expect(playback.frame, 99);
      controller.fireBridge(
        jsonEncode(<String, Object?>{'kind': 'ended', 'frame': 239}),
      );
      expect(playback.playing, isFalse);
      expect(playback.frame, 239);
      controller.fireBridge(
        jsonEncode(<String, Object?>{
          'kind': 'error',
          'message': '帧表为空：检查镜头时长',
        }),
      );
      expect(playback.playing, isFalse);
      expect(playback.loadError, contains('画面数据是空的'));
      expect(playback.technicalDetail, contains('帧表为空'));

      playback.dispose();
    });

    testWidgets('就绪后挂出舞台；页面状态轮询与页面同步；主帧加载失败显性降级', (tester) async {
      await _installFakePlatform();
      final Video3dWebPreview playback = _preview();
      await playback.start();

      await tester.pumpWidget(_app(Video3dPreviewSurface(preview: playback)));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('video3d-preview-stage')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('video3d-preview-error')), findsNothing);
      expect(find.text('可以预览'), findsOneWidget);

      // 页面内运输条起播时，宿主状态以页面 state() 轮询为准。
      final _FakeWebViewPlatform platform =
          WebViewPlatform.instance! as _FakeWebViewPlatform;
      platform.lastController!.pageState = 'playing';
      await tester.pump(const Duration(milliseconds: 500));
      expect(playback.playing, isTrue, reason: '页面 state=playing → 宿主跟随');
      platform.lastController!.pageState = 'idle';
      await tester.pump(const Duration(milliseconds: 500));
      expect(playback.playing, isFalse);

      // 主帧资源错误（导航失败）→ 错误占位 + 重试 + 技术详情；
      // 子资源错误不整块替换（这里只触发主帧）。
      platform.lastController!.navigationDelegate!.fireMainFrameError();
      await tester.pump();
      expect(
        find.byKey(const ValueKey('video3d-preview-error')),
        findsOneWidget,
      );
      expect(find.text('预览页没有加载出来，可以重试'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('video3d-preview-retry')),
        findsOneWidget,
      );
      expect(playback.ready, isFalse);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      playback.dispose();
      expect(tester.takeException(), isNull);
    });

    test('真实 three-live 运行时文本：资源路径存在、组装后不提前关闭脚本块', () async {
      // 资源键必须指向真实打包路径（pubspec 已声明 assets/three/vendor/）。
      expect(File(video3dRuntimeAssetKey).existsSync(), isTrue);
      await _installFakePlatform();
      final String runtime = File(video3dRuntimeAssetKey).readAsStringSync();
      expect(runtime.length, greaterThan(100000), reason: '真实运行时不是占位文本');

      final models = _models();
      final Video3dWebPreview playback = Video3dWebPreview(
        scene: models.scene,
        screenplay: models.screenplay,
        timeline: models.timeline,
        runtimeLoader: () async => runtime,
      );
      await playback.start();
      expect(playback.ready, isTrue, reason: '真实运行时文本可以组装并载入');
      final String html = playback.html!;
      // 与 assembleVideo3dPreview 同一转义口径：运行时文本里的 `</script` 被转义，
      // 页面本身只剩模板的 3 个脚本块结束标签（否则运行时可能提前关闭脚本）。
      final String inlined = runtime.replaceAll(
        RegExp('</script', caseSensitive: false),
        r'<\/script',
      );
      expect(html, contains(inlined));
      expect(
        RegExp('</script', caseSensitive: false).allMatches(html).length,
        3,
        reason: '模板三个脚本块 + 运行时零个裸结束标签',
      );
      playback.dispose();
    });

    test('WebView 不可用：显性降级，不假装可播', () async {
      debugVideo3dPreviewWebViewSupported = false;
      final Video3dWebPreview playback = _preview();
      await playback.start();
      expect(playback.ready, isFalse);
      expect(playback.loadError, '这台设备暂时不能内嵌预览 3D 视频');
      expect(playback.technicalDetail, contains('WebView'));
      // 不可用时命令是空操作：不会把 playing 伪装成 true。
      await playback.play();
      expect(playback.playing, isFalse);
      playback.dispose();
    });

    test('运行时读取失败 / 运行时空文本：组装前显性降级', () async {
      final Video3dWebPreview readFailure = Video3dWebPreview(
        scene: _models().scene,
        screenplay: _models().screenplay,
        timeline: _models().timeline,
        runtimeLoader: () async => throw StateError('bundle missing'),
      );
      await readFailure.start();
      expect(readFailure.ready, isFalse);
      expect(readFailure.loadError, contains('运行文件没有找到'));
      expect(readFailure.technicalDetail, contains('bundle missing'));
      expect(readFailure.html, isNull, reason: '失败时不产出半成品页面');
      readFailure.dispose();

      final Video3dWebPreview blank = _preview(runtime: '   ');
      await blank.start();
      expect(blank.ready, isFalse);
      expect(blank.loadError, contains('运行文件没有找到'));
      expect(blank.technicalDetail, contains(video3dRuntimeMissingCode));
      expect(blank.html, isNull);
      blank.dispose();
    });

    test('控制器创建失败：显性降级，不假装可播', () async {
      await _installFakePlatform();
      final Video3dWebPreview playback = _preview();
      // 平台桩的导航委托创建成功，但让 WebView 控制器创建失败：start 只落人话
      // 错误面，不抛穿、不假装可播。
      final _FakeWebViewPlatform platform =
          WebViewPlatform.instance! as _FakeWebViewPlatform;
      platform.failControllerCreation = true;
      await playback.start();
      expect(playback.ready, isFalse);
      expect(playback.loadError, '预览页没有启动起来，可以重试');
      expect(playback.technicalDetail, isNotEmpty);
      playback.dispose();
    });
  });
}
