// 视频产物真播回归（批次 08：本机文件播放）。
//
// 覆盖：
//  ① 艺术架「打开」→ videoLoadOnOpen → 视频工作台产物模式（播放面 + 路径行），
//    不再是只弹一条提示的路径字符串；
//  ② 播放面直接载入**本机文件**（不再经任何内部路由取流），URL 加载一次都不发；
//  ③ WebKit 创建参数必须是「内联播放 + 无需用户手势」——默认值是
//    mediaTypesRequiringUserAction={audio,video} + allowsInlineMediaPlayback=false，
//    不开这两个参数视频会被自动播放策略静默拦住（真机黑屏的根因）；
//  ④ 主帧加载失败 → 覆盖层「无法播放」+ 复制路径（失败不是死端）；
//  ⑤ 默认创作面（代码动画）不创建 WebView（工作台测试无需平台桩）；
//  ⑥ 平台判定只认能力矩阵：Windows 能力矩阵同样建 WebView（webview_all →
//    WebView2）；「macOS 播放面」用例显式注入 macos host，Windows 宿主上也拿到
//    WebKit 参数。
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:webview_platform_interface/webview_platform_interface.dart';
import 'package:webview_all_wkwebview/webview_all_wkwebview.dart';

import 'package:nondesign/core/capability_hub.dart';
import 'package:nondesign/core/platform_capabilities.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/widgets/video_player_surface.dart';
import 'package:nondesign/widgets/video_workspace.dart';

const _mp4 = '/Users/x/Documents/NoNDesign/videos/job-1/frames.mp4';

/// 本文件验收的是 macOS 播放面：显式给 macOS 能力矩阵。
///
/// `flutter test` 的 `defaultTargetPlatform` 默认是 android，
/// `PlatformCapabilities.current()` 会把工作台当成手机（渲染/定位入口隐藏），
/// 与本文件的桌面场景不符。
AppStore _store() => AppStore(
      capabilities: CapabilityHub(platform: PlatformCapabilities.forOs(HostOs.macos)),
    )..ready = true;

Widget _wrap(Widget child) => MaterialApp(
      theme: AppTheme.build(dark: true),
      home: Scaffold(body: child),
    );

// ---- WebView 平台桩（捕获创建参数 / loadRequest / loadFile）----

const _macHost = PlatformCapabilities(os: HostOs.macos);
const _windowsHost = PlatformCapabilities(os: HostOs.windows);

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

  void fireMainFrameError(int code) => onWebResourceError?.call(
      WebResourceError(errorCode: code, description: 'no such file', isForMainFrame: true));
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

  testWidgets('产物模式：videoLoadOnOpen → 播放面 + 路径行，按本机文件加载', (tester) async {
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

    // 产物模式：标题/返回创作台/播放面/信息行。
    expect(find.textContaining('视频产物'), findsOneWidget);
    expect(find.text('返回创作台'), findsOneWidget);
    expect(find.byType(VideoPlayerSurface), findsOneWidget);
    expect(find.text('复制路径'), findsOneWidget);
    final pathText = tester.widget<SelectableText>(find.byType(SelectableText));
    expect(pathText.data, _mp4);

    // 本机文件直读：不做任何 URL 请求。
    expect(fake.lastController!.loadedFiles, [_mp4]);
    expect(fake.lastController!.loadedUrls, isEmpty);

    // 创建参数：允许内联播放 + 无需用户手势（自动播放策略硬前提）。
    final params = fake.lastParams;
    expect(params, isA<WebKitWebViewControllerCreationParams>());
    final wk = params! as WebKitWebViewControllerCreationParams;
    expect(wk.allowsInlineMediaPlayback, isTrue);
    expect(wk.mediaTypesRequiringUserAction, isEmpty);
  });

  testWidgets('产物模式在手机宽度 390 下不溢出（标题 + 返回创作台 + 信息行）', (tester) async {
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
    expect(find.text('返回创作台'), findsOneWidget);
    expect(fake.lastController!.loadedFiles, [_mp4]);
  });

  testWidgets('默认创作面：代码动画就绪且不创建 WebView', (tester) async {
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
    // 主区是代码动画的第一帧，不是「点渲染出片」的空态。
    expect(find.byKey(const ValueKey('video-animation-surface')), findsOneWidget);
    expect(find.text('渲染（后台）'), findsNothing);
    expect(find.byType(VideoPlayerSurface), findsNothing);
    // 「默认模式不构造播放面」是可测事实：fake 平台一次控制器都没创建。
    expect(fake.lastController, isNull);
  });

  testWidgets('单独挂播放面：不传任何地址也只读本机文件', (tester) async {
    final fake = await _installFake();
    await _pump(
      tester,
      _wrap(const VideoPlayerSurface(path: _mp4, host: _macHost)),
    );

    expect(fake.lastController, isNotNull);
    expect(fake.lastController!.loadedFiles, [_mp4]);
    expect(fake.lastController!.loadedUrls, isEmpty);
  });

  testWidgets('主帧加载失败：覆盖层「无法播放」+ 复制路径', (tester) async {
    final fake = await _installFake();
    await _pump(
      tester,
      _wrap(const VideoPlayerSurface(path: _mp4, host: _macHost)),
    );

    fake.lastController!.navDelegate!.fireMainFrameError(-1009);
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byKey(const ValueKey('video-error')), findsOneWidget);
    expect(find.textContaining('无法播放'), findsOneWidget);
    expect(find.text('复制路径'), findsOneWidget);
  });

  testWidgets('Windows 能力矩阵：同样创建 WebView（webview_all 全平台）', (tester) async {
    final fake = await _installFake();
    await _pump(
      tester,
      _wrap(const VideoPlayerSurface(path: _mp4, host: _windowsHost)),
    );

    // webview_all 在 Windows 用 WebView2：平台矩阵不再把 Windows 降级。
    expect(fake.lastController, isNotNull);
    expect(find.text('当前平台不支持应用内视频播放'), findsNothing);
    expect(find.textContaining(_mp4), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
