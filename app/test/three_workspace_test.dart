// 3D 工作台 await 弹窗返回后的 mounted 守卫回归（审查 ui-2）。
// 触发链：根级 ⌘1–⌘7 绑定不让位浮层（main.dart 无 _overlayRouteActive 守卫），
// 对话框打开期间切走视图 → workspace.dart 重建并 dispose ThreeWorkspace →
// 弹窗里继续操作即在死 State 上继续执行：
// - _createProject 的 setState 在 try 之外 → 未处理异常（本测试的红/绿锚点）；
// - _pickProject 的 setState 被外层 catch 吞掉 → 项目切换静默失效（语义锚点：
//   死工作台不得推进项目切换/挂预览）。
// 对照同型正确实现：hotapp_workspace.dart 的 `if (!mounted || ...) return;`。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:webview_flutter/webview_flutter.dart';
// 平台类（PlatformWebViewController/PlatformNavigationDelegate/PlatformWebViewWidget）
// 不经 webview_flutter 主库 re-export——桩直接从平台接口库取（测试专用传递依赖）。
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import 'package:nondesign/core/api.dart';
import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/widgets/three_workspace.dart';

AppStore _store(NoNDesignApi api) {
  final store = AppStore()
    ..ready = true
    ..view = 'plugin:three'
    ..settings = AppSettings(
      providerId: 'deepseek',
      modelId: 'deepseek-v4.1-flash',
      baseUrl: 'https://api.example.com/v1',
      apiKey: 'test-key',
    );
  store.api = api;
  return store;
}

NoNDesignApi _api() => NoNDesignApi(
      'http://mock.local',
      MockClient((request) async {
        if (request.url.path == '/three/projects') {
          return http.Response(
            '{"ok":true,"projects":[{"name":"saturn-demo","current":"blockout"}]}',
            200,
          );
        }
        return http.Response('{"ok":false,"detail":"no_route"}', 404);
      }),
    );

/// 镜像 workspace.dart 的插件视图路由：watch store → view 变化即重建/dispose。
/// gen 变化时强制重建工作台（const 三连会被 pumpWidget 当同一配置短路，
/// initState 不会重跑——_pumpProject 的第二次 pump 必须靠换 key 触发）。
Widget _host(AppStore store, {int gen = 0}) => ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(
        theme: AppTheme.build(dark: true),
        home: Consumer<AppStore>(
          builder: (context, s, _) => s.view == 'plugin:three'
              ? Scaffold(
                  body: KeyedSubtree(key: ValueKey('three-ws-$gen'), child: const ThreeWorkspace()))
              : const Scaffold(body: SizedBox.expand()),
        ),
      ),
    );

Future<void> _pumpAt(WidgetTester tester, Widget child, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(child);
  await tester.pump(const Duration(milliseconds: 50));
}

// ---- three-5 WebView 平台桩 ----
// 真 WebKit 控制器在 flutter test 环境构造即抛 UnimplementedError
//（PlatformWebView 只支持真机目标平台）——fake 让「threeLoadOnOpen 直载 →
// initState _refresh → _mountPreview → loadRequest/导航回调」全链自然跑通。
// 装桩时机：initState 的 registerWith 只会在首个 pump 发生（_wkRegistered
// 全局一次），_pumpProject 先以无项目空态预热一帧确保它已发生，再替换
// instance——单跑 --plain-name（上方既有测试不执行）也不会被覆盖。
class _FakeWebViewPlatform extends WebViewPlatform {
  _FakePlatformWebViewController? lastController;

  @override
  PlatformWebViewController createPlatformWebViewController(
      PlatformWebViewControllerCreationParams params) {
    return lastController = _FakePlatformWebViewController(params);
  }

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
          PlatformNavigationDelegateCreationParams params) =>
      _FakePlatformNavigationDelegate(params);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
          PlatformWebViewWidgetCreationParams params) =>
      _FakePlatformWebViewWidget(params);
}

class _FakePlatformWebViewController extends PlatformWebViewController {
  _FakePlatformWebViewController(super.params) : super.implementation();

  final loadedUrls = <Uri>[];
  // channel/delegate 形参类型（LoadRequestParams/JavaScriptChannelParams/
  // PlatformNavigationDelegate）不经 webview_flutter 主库 re-export——
  // 桩里按 contravariance 用 dynamic 形参接住即可。
  dynamic channelParams;
  _FakePlatformNavigationDelegate? navDelegate;

  @override
  Future<void> setJavaScriptMode(JavaScriptMode mode) async {}

  @override
  Future<void> addJavaScriptChannel(dynamic params) async {
    channelParams = params;
  }

  @override
  Future<void> setPlatformNavigationDelegate(dynamic delegate) async {
    navDelegate = delegate as _FakePlatformNavigationDelegate;
  }

  @override
  Future<void> loadRequest(dynamic params) async {
    loadedUrls.add(params.uri as Uri);
  }

  /// 模拟 WebView JS 桥消息（NON3D 通道 → _onBridgeMessage）。
  void fireJsMessage(String text) {
    (channelParams as dynamic).onMessageReceived(JavaScriptMessage(message: text));
  }
}

class _FakePlatformNavigationDelegate extends PlatformNavigationDelegate {
  _FakePlatformNavigationDelegate(super.params) : super.implementation();

  void Function(HttpResponseError)? onHttpError;
  void Function(WebResourceError)? onWebResourceError;
  void Function(String)? onPageStarted;

  @override
  Future<void> setOnPageStarted(PageEventCallback cb) async => onPageStarted = cb;

  @override
  Future<void> setOnHttpError(HttpResponseErrorCallback cb) async => onHttpError = cb;

  @override
  Future<void> setOnWebResourceError(WebResourceErrorCallback cb) async =>
      onWebResourceError = cb;

  /// 模拟 WKNavigationDelegate decidePolicyForNavigationResponse（HTTP ≥400）。
  void fireHttpError(int statusCode) => onHttpError?.call(HttpResponseError(
      response: WebResourceResponse(uri: null, statusCode: statusCode)));

  /// 模拟 didFail(Navigation)：主帧/子资源两类。
  void fireResourceError({required bool mainFrame}) =>
      onWebResourceError?.call(WebResourceError(
          errorCode: mainFrame ? -1009 : -100,
          description: mainFrame ? 'offline' : 'subresource',
          isForMainFrame: mainFrame));

  void firePageStarted(String url) => onPageStarted?.call(url);
}

class _FakePlatformWebViewWidget extends PlatformWebViewWidget {
  _FakePlatformWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// /three/project 固定 200（当前层 blockout/pending），其余路径 200 ok。
NoNDesignApi _projectApi() => NoNDesignApi('http://mock.local', MockClient((request) async {
      if (request.url.path == '/three/project') {
        return http.Response(
          '{"ok":true,"state":{"current":"blockout","passes":[{"id":"blockout","status":"pending"}]},'
          '"spec":{},"scene_js":""}',
          200,
        );
      }
      return http.Response('{"ok":true}', 200);
    }));

/// 预热一帧（确保 initState 的 registerWith 已发生）→ 装 fake → 以
/// threeLoadOnOpen 直载 saturn-demo 重建工作台 → postFrame 的
/// _refresh/_mountPreview 全链跑完。
Future<_FakeWebViewPlatform> _pumpProject(WidgetTester tester, AppStore store) async {
  await tester.pumpWidget(_host(store, gen: 0));
  await tester.pump(const Duration(milliseconds: 50));
  final fake = _FakeWebViewPlatform();
  WebViewPlatform.instance = fake;
  addTearDown(() => WebViewPlatform.instance = WebKitWebViewPlatform());
  addTearDown(() => threeLoadOnOpen = null);
  threeLoadOnOpen = 'saturn-demo';
  // gen 变化强制重建工作台：initState 消费 threeLoadOnOpen →
  // postFrame 的 _refresh/_mountPreview（此刻 instance 已是 fake）。
  await tester.pumpWidget(_host(store, gen: 1));
  await tester.pump(const Duration(milliseconds: 50));
  return fake;
}

void main() {
  testWidgets('pickProject：弹窗期间切走视图后选项目不复活死 State', (tester) async {
    final store = _store(_api());
    await _pumpAt(tester, _host(store), const Size(1440, 900));

    await tester.tap(find.text('项目'));
    await tester.pumpAndSettle();
    expect(find.text('3D 项目'), findsOneWidget);

    // 对话框在场时切走视图（⌘1 的等价动作）：ThreeWorkspace 被 dispose，
    // 弹窗路由独立存活。
    store.setView('design');
    await tester.pumpAndSettle();
    expect(store.view, 'design');

    // 在仍开着的弹窗里选项目 → await showNonDialog 之后的续体在死 State 上跑。
    // （Navigator.pop 能成功走通依赖 showNonDialog 把路由 context 传给
    // builder——推入方 context 已死时 dialog 动作会先在这里崩。）
    await tester.tap(find.text('saturn-demo（占位）'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.takeException(), isNull);
    // 死工作台不得推进项目切换/写全局设置。
    expect(store.settings.threeProjectName, isEmpty);
  });

  testWidgets('createProject：弹窗期间切走视图后确认新建不触发 setState-after-dispose', (tester) async {
    final store = _store(_api());
    await _pumpAt(tester, _host(store), const Size(1440, 900));

    await tester.tap(find.text('新建 3D 项目'));
    await tester.pumpAndSettle();
    expect(find.text('生成规范'), findsOneWidget);
    await tester.enterText(find.byType(TextField).at(0), 'demo');
    await tester.enterText(find.byType(TextField).at(1), '带环行星自转');

    store.setView('design');
    await tester.pumpAndSettle();

    // 点「生成规范」→ pop(true) → 续体在 try 之外直接 setState(_busy=true)：
    // 无守卫时是未处理异常（debug 抛 FlutterError），守卫后安静返回。
    await tester.tap(find.text('生成规范'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.takeException(), isNull);
    expect(store.settings.threeProjectName, isEmpty);
  });

  // ---- 2026-11-17 3D 客户端错误呈现批次回归锚（three-5）----

  testWidgets('refresh 非 ok：错误红条 + toast 显式呈现，状态不被伪造', (tester) async {
    var projectOk = false;
    final api = NoNDesignApi('http://mock.local', MockClient((request) async {
      if (request.url.path == '/three/project') {
        if (!projectOk) return http.Response('{"detail":"no_project:saturn-demo"}', 400);
        return http.Response(
          '{"ok":true,"state":{"current":"blockout","passes":[{"id":"blockout","status":"pending"}]},'
          '"spec":{},"scene_js":""}',
          200,
        );
      }
      return http.Response('{"ok":true}', 200);
    }));
    final fake = await _pumpProject(tester, _store(api));

    // 直载路径 initState postFrame 的 _refresh 已失败：红条 + toast；
    // 盘上无项目 ⇒ pass chips 不被旧状态伪造。
    expect(find.byKey(const ValueKey('three-refresh-error')), findsOneWidget);
    expect(find.textContaining('no_project:saturn-demo'), findsWidgets);
    expect(find.text('项目状态刷新失败'), findsOneWidget);
    expect(find.text('占位'), findsNothing);

    // 桥反馈（WebView 每条消息都跟一次 _refresh）——服务器恢复后同路径自愈。
    projectOk = true;
    fake.lastController!.fireJsMessage(jsonEncode({'kind': 'metrics', 'payload': <String, dynamic>{}}));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byKey(const ValueKey('three-refresh-error')), findsNothing);
    expect(find.text('占位'), findsOneWidget);
    await tester.pumpAndSettle(); // 收掉失败 toast 的展示定时器
  });

  testWidgets('refresh 异常（服务器不可达）：同样红条 + toast，不再静默吞', (tester) async {
    final api = NoNDesignApi('http://mock.local', MockClient((request) async {
      if (request.url.path == '/three/project') throw Exception('connection reset');
      return http.Response('{"ok":true}', 200);
    }));
    final fake = await _pumpProject(tester, _store(api));

    expect(find.byKey(const ValueKey('three-refresh-error')), findsOneWidget);
    expect(find.textContaining('connection reset'), findsWidgets);
    expect(find.text('项目状态刷新失败'), findsOneWidget);

    // 同 detail 去重：桥反馈每条都跟一次 _refresh，重复失败不叠同文 toast。
    fake.lastController!.fireJsMessage(jsonEncode({'kind': 'metrics', 'payload': <String, dynamic>{}}));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byKey(const ValueKey('three-refresh-error')), findsOneWidget);
    expect(find.text('项目状态刷新失败'), findsOneWidget);
    await tester.pumpAndSettle(); // 收掉失败 toast 的展示定时器
  });

  testWidgets('预览主帧 HTTP ≥400：错误占位替换 WebView 区域，重试可恢复', (tester) async {
    final fake = await _pumpProject(tester, _store(_projectApi()));
    expect(find.textContaining('预览加载失败'), findsNothing);

    // /three/preview/<错名> 的 400 JSON 场景
    //（decidePolicyForNavigationResponse = onNavigationResponse 语义桥）。
    fake.lastController!.navDelegate!.fireHttpError(400);
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.textContaining('预览加载失败'), findsOneWidget);
    expect(find.textContaining('HTTP 400'), findsOneWidget);
    expect(find.text('重试加载'), findsOneWidget);

    // 重试：重新 loadRequest（初始 1 次 + 重试 1 次），占位退场、WebView 恢复。
    await tester.tap(find.text('重试加载'));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.textContaining('预览加载失败'), findsNothing);
    expect(find.byType(WebViewWidget), findsOneWidget);
    expect(fake.lastController!.loadedUrls.length, 2);
  });

  testWidgets('子资源错误不清占位，主帧资源错误才置占位', (tester) async {
    final fake = await _pumpProject(tester, _store(_projectApi()));
    final nav = fake.lastController!.navDelegate!;

    // 子资源（图片/脚本）失败不整块呈现。
    nav.fireResourceError(mainFrame: false);
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('预览加载失败'), findsNothing);

    nav.fireResourceError(mainFrame: true);
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('预览加载失败'), findsOneWidget);
    expect(find.textContaining('offline'), findsWidgets);

    // 新导航开始清旧占位（刷新成功页照常渲染，失败会再置）。
    nav.firePageStarted('http://mock.local/three/preview/saturn-demo');
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('预览加载失败'), findsNothing);
  });
}
