// 视频产物真播回归（2026-11-17 艺术架批次）：
// ① 艺术架「打开」→ videoLoadOnOpen → 视频工作台产物模式（播放面 + 路径行），
//    不再是只弹一条 SnackBar 的路径字符串；
// ② 播放面经 /video/mp4?path=… 走 HTTP（服务端 FileResponse 承担 Range/seek），
//    无服务器时回落 loadFile；
// ③ WebKit 创建参数必须是「内联播放 + 无需用户手势」——默认值是
//    mediaTypesRequiringUserAction={audio,video} + allowsInlineMediaPlayback=false，
//    不开这两个参数视频会被自动播放策略静默拦住（真机黑屏的根因）。
//    本测试对 fake 平台收到的 creationParams 做结构断言；若某天 fake 不再暴露
//    参数，可退化为源码常量断言（测试名会注明）。
// ④ 主帧 HTTP ≥400 → 覆盖层「无法播放」+ 复制路径（失败不是死端）。
// ⑤ 默认渲染台模式一字不动：文案保持，且**不创建** WebView（既有
//    video_workspace_test 不设 WebViewPlatform 也能跑，靠的就是这条）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import 'package:nondesign/core/api.dart';
import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/widgets/video_player_surface.dart';
import 'package:nondesign/widgets/video_workspace.dart';

const _mp4 = '/Users/x/Documents/NoNDesign/videos/job-1/frames.mp4';

AppStore _store() {
  final store = AppStore()
    ..ready = true
    ..settings = AppSettings(providerId: 'deepseek', modelId: 'deepseek-v4.1-flash');
  // 产物模式不需要真正的服务器；baseUrl 用于拼 /video/mp4 播放地址。
  store.api = NoNDesignApi(
      'http://mock.local',
      MockClient((request) async => http.Response('{"ok":false,"detail":"no_route"}', 404,
          headers: {'content-type': 'application/json; charset=utf-8'})));
  return store;
}

Widget _wrap(Widget child) => MaterialApp(
      theme: AppTheme.build(dark: true),
      home: Scaffold(body: child),
    );

// ---- WebView 平台桩（捕获创建参数 / loadRequest / loadFile）----

class _FakeVideoPlatform extends WebViewPlatform {
  _FakeVideoController? lastController;
  PlatformWebViewControllerCreationParams? lastParams;

  @override
  PlatformWebViewController createPlatformWebViewController(
      PlatformWebViewControllerCreationParams params) {
    lastParams = params;
    return lastController = _FakeVideoController(params);
  }

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

  final List<Uri> loadedUrls = [];
  final List<String> loadedFiles = [];
  _FakeVideoNavigationDelegate? navDelegate;

  @override
  Future<void> setJavaScriptMode(JavaScriptMode mode) async {}

  @override
  Future<void> setPlatformNavigationDelegate(dynamic delegate) async {
    navDelegate = delegate as _FakeVideoNavigationDelegate;
  }

  @override
  Future<void> loadRequest(dynamic params) async {
    loadedUrls.add(params.uri as Uri);
  }

  @override
  Future<void> loadFile(String absoluteFilePath) async {
    loadedFiles.add(absoluteFilePath);
  }
}

class _FakeVideoNavigationDelegate extends PlatformNavigationDelegate {
  _FakeVideoNavigationDelegate(super.params) : super.implementation();

  void Function(HttpResponseError)? onHttpError;
  void Function(WebResourceError)? onWebResourceError;

  @override
  Future<void> setOnHttpError(HttpResponseErrorCallback cb) async => onHttpError = cb;

  @override
  Future<void> setOnWebResourceError(WebResourceErrorCallback cb) async =>
      onWebResourceError = cb;

  void fireHttpError(int statusCode) => onHttpError?.call(
      HttpResponseError(response: WebResourceResponse(uri: null, statusCode: statusCode)));
}

class _FakeVideoWebViewWidget extends PlatformWebViewWidget {
  _FakeVideoWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

Future<_FakeVideoPlatform> _installFake() async {
  final fake = _FakeVideoPlatform();
  WebViewPlatform.instance = fake;
  addTearDown(() => WebViewPlatform.instance = WebKitWebViewPlatform());
  return fake;
}

Future<void> _pump(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(1100, 760);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(child);
  await tester.pump(const Duration(milliseconds: 80));
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    videoLoadOnOpen = null;
  });
  tearDown(() => videoLoadOnOpen = null);

  testWidgets('产物模式：videoLoadOnOpen → 播放面 + 路径行，URL 走 /video/mp4?path=…', (tester) async {
    final fake = await _installFake();
    videoLoadOnOpen = _mp4;
    final store = _store();
    await _pump(
      tester,
      ChangeNotifierProvider<AppStore>.value(
        value: store,
        child: _wrap(const VideoWorkspace()),
      ),
    );

    // 产物模式：标题/返回渲染台/播放面/信息行。
    expect(find.textContaining('视频产物'), findsOneWidget);
    expect(find.text('返回渲染台'), findsOneWidget);
    expect(find.byType(VideoPlayerSurface), findsOneWidget);
    expect(find.text('复制路径'), findsOneWidget);
    final pathText = tester.widget<SelectableText>(find.byType(SelectableText));
    expect(pathText.data, _mp4);

    // WebView 载入的服务端 URL。
    final uri = fake.lastController!.loadedUrls.single;
    expect(uri.path, '/video/mp4');
    expect(uri.queryParameters['path'], _mp4);

    // 创建参数：允许内联播放 + 无需用户手势（自动播放策略硬前提）。
    final params = fake.lastParams;
    expect(params, isA<WebKitWebViewControllerCreationParams>());
    final wk = params! as WebKitWebViewControllerCreationParams;
    expect(wk.allowsInlineMediaPlayback, isTrue);
    expect(wk.mediaTypesRequiringUserAction, isEmpty);
  });

  testWidgets('产物模式在手机宽度 390 下不溢出（标题 + 返回渲染台 + 信息行）', (tester) async {
    final fake = await _installFake();
    videoLoadOnOpen = _mp4;
    final store = _store();
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: _wrap(const VideoWorkspace()),
    ));
    await tester.pump(const Duration(milliseconds: 80));

    expect(tester.takeException(), isNull);
    expect(find.textContaining('视频产物'), findsOneWidget);
    expect(find.text('返回渲染台'), findsOneWidget);
    expect(fake.lastController!.loadedUrls.single.path, '/video/mp4');
  });

  testWidgets('默认渲染台：文案不变且不创建 WebView', (tester) async {
    final fake = await _installFake();
    final store = _store();
    await _pump(
      tester,
      ChangeNotifierProvider<AppStore>.value(
        value: store,
        child: _wrap(const VideoWorkspace()),
      ),
    );

    expect(find.text('视频工作台'), findsOneWidget);
    expect(find.text('标杆示例'), findsOneWidget);
    expect(find.text('加载示例后点「渲染」'), findsOneWidget);
    expect(find.byType(VideoPlayerSurface), findsNothing);
    // 「默认模式不构造播放面」是可测事实：fake 平台一次控制器都没创建。
    expect(fake.lastController, isNull);
  });

  testWidgets('离线（无服务器）：播放面回落 loadFile 本地文件', (tester) async {
    final fake = await _installFake();
    await _pump(tester, _wrap(const VideoPlayerSurface(path: _mp4)));

    expect(fake.lastController, isNotNull);
    expect(fake.lastController!.loadedFiles, [_mp4]);
    expect(fake.lastController!.loadedUrls, isEmpty);
  });

  testWidgets('主帧 HTTP ≥400：覆盖层「无法播放」+ 复制路径', (tester) async {
    final fake = await _installFake();
    await _pump(tester, _wrap(const VideoPlayerSurface(path: _mp4, baseUrl: 'http://mock.local')));

    fake.lastController!.navDelegate!.fireHttpError(404);
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byKey(const ValueKey('video-error')), findsOneWidget);
    expect(find.textContaining('无法播放'), findsOneWidget);
    expect(find.text('复制路径'), findsOneWidget);
  });
}
