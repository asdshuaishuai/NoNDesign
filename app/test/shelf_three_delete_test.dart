// 3D 工作台 res-1 / res-2 回归（2026-11-17 艺术架批次）：
//
// res-1 删除入口：/three/delete 服务端早已落地并测过（真删 + 越界防护），
//   客户端此前没有任何入口——blocked 项目的错误文案却指路「POST /three/delete
//   删项目重开」（提示了一条 UI 做不到的出路）。对话框项目行现在带删除按钮：
//   二次确认 → POST → 删的是当前项目则整体回空态。
//
// res-2 截图/四方位门：旧判据只有 `_project != null`——预览失败（_loadError）
//   或 controller 未挂载时按钮仍可点，点了是带 ?. 守卫的静默 no-op。新判据 =
//   预览页就绪（预览页 300ms 后主动上报的 metrics 桥；**不用 onPageFinished**：
//   webview_flutter 平台基类 setOnPageFinished 直接 throw UnimplementedError，
//   NavigationDelegate 构造器会同步调用它）。两条 UI 路径都断言：landscape 的
//   _TopBtn 与 portrait 的 PopupMenuItem。
import 'dart:convert';

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
import 'package:nondesign/widgets/art_shelf_card.dart';
import 'package:nondesign/widgets/portfolio_view.dart';
import 'package:nondesign/widgets/three_workspace.dart';

http.Response _json(Object body, [int status = 200]) => http.Response(
      body is String ? body : jsonEncode(body),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

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

/// /three/project 固定 ok（当前层 blockout），/three/projects 给一个项目
/// （测试里就是「当前项目」），/three/delete 记账。
class _ThreeStub {
  final List<String> deleted = [];

  NoNDesignApi api() => NoNDesignApi('http://mock.local', MockClient((request) async {
        switch (request.url.path) {
          case '/three/project':
            return _json({
              'ok': true,
              'state': {
                'current': 'blockout',
                'passes': [
                  {'id': 'blockout', 'status': 'pending'},
                ],
              },
              'spec': {},
              'scene_js': '',
            });
          case '/three/projects':
            return _json({
              'ok': true,
              'projects': [
                {'name': 'saturn-demo', 'current': 'blockout'},
              ],
            });
          case '/three/delete':
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            deleted.add(body['name'] as String);
            return _json({'ok': true, 'name': body['name']});
          case '/portfolio':
            return _json({
              'ok': true,
              'items': [
                {
                  'kind': 'three',
                  'ref': 'saturn-demo',
                  'title': '3D · saturn-demo',
                  'path': '/tmp/3d/saturn-demo/scene.js',
                  'detail': 'three.js 场景',
                },
              ],
            });
          case '/portfolio/delete':
            return _json({'ok': true});
        }
        return _json({'ok': true});
      }));
}

Widget _host(AppStore store, {int gen = 0}) => ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(
        theme: AppTheme.build(dark: true),
        home: Consumer<AppStore>(
          builder: (context, s, _) => s.view == 'plugin:three'
              ? Scaffold(
                  body: KeyedSubtree(
                      key: ValueKey('three-ws-$gen'), child: const ThreeWorkspace()))
              : const Scaffold(body: SizedBox.expand()),
        ),
      ),
    );

// ---- WebView 平台桩（与 three_workspace_test 同法 + runJavaScript 计数）----

class _FakeWebViewPlatform extends WebViewPlatform {
  _FakePlatformController? lastController;

  @override
  PlatformWebViewController createPlatformWebViewController(
          PlatformWebViewControllerCreationParams params) =>
      lastController = _FakePlatformController(params);

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
          PlatformNavigationDelegateCreationParams params) =>
      _FakeNavigationDelegate(params);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(PlatformWebViewWidgetCreationParams params) =>
      _FakeWebViewWidget(params);
}

class _FakePlatformController extends PlatformWebViewController {
  _FakePlatformController(super.params) : super.implementation();

  dynamic channelParams;
  _FakeNavigationDelegate? navDelegate;
  final List<Uri> loadedUrls = [];
  int jsCalls = 0;

  @override
  Future<void> setJavaScriptMode(JavaScriptMode mode) async {}

  @override
  Future<void> addJavaScriptChannel(dynamic params) async {
    channelParams = params;
  }

  @override
  Future<void> setPlatformNavigationDelegate(dynamic delegate) async {
    navDelegate = delegate as _FakeNavigationDelegate;
  }

  @override
  Future<void> loadRequest(dynamic params) async {
    loadedUrls.add(params.uri as Uri);
  }

  @override
  Future<void> runJavaScript(String javaScript) async {
    jsCalls++;
  }

  void fireJsMessage(String text) {
    (channelParams as dynamic).onMessageReceived(JavaScriptMessage(message: text));
  }
}

class _FakeNavigationDelegate extends PlatformNavigationDelegate {
  _FakeNavigationDelegate(super.params) : super.implementation();

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

  void fireHttpError(int statusCode) => onHttpError?.call(
      HttpResponseError(response: WebResourceResponse(uri: null, statusCode: statusCode)));

  void firePageStarted(String url) => onPageStarted?.call(url);
}

class _FakeWebViewWidget extends PlatformWebViewWidget {
  _FakeWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// 预热一帧（让 initState 的注册只发生一次）→ 装 fake → threeLoadOnOpen
/// 直载 saturn-demo 重建工作台 → postFrame 的 _refresh/_mountPreview 跑完。
Future<_FakeWebViewPlatform> _pumpProject(WidgetTester tester, AppStore store, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(_host(store, gen: 0));
  await tester.pump(const Duration(milliseconds: 50));

  final fake = _FakeWebViewPlatform();
  WebViewPlatform.instance = fake;
  addTearDown(() => WebViewPlatform.instance = WebKitWebViewPlatform());
  addTearDown(() => threeLoadOnOpen = null);

  threeLoadOnOpen = 'saturn-demo';
  await tester.pumpWidget(_host(store, gen: 1));
  await tester.pump(const Duration(milliseconds: 50));
  return fake;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => threeLoadOnOpen = null);

  testWidgets('res-1：项目对话框带删除入口，确认后调 /three/delete 并清空当前项目', (tester) async {
    final stub = _ThreeStub();
    final store = _store(stub.api());
    await _pumpProject(tester, store, const Size(1440, 900));

    await tester.tap(find.text('项目'));
    await tester.pumpAndSettle();
    expect(find.text('3D 项目'), findsOneWidget);
    expect(find.text('saturn-demo（占位）'), findsOneWidget);

    await tester.tap(find.byTooltip('删除项目'));
    await tester.pumpAndSettle();
    expect(find.text('删除 3D 项目？'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(stub.deleted, ['saturn-demo']);
    // 删的是当前项目：工作台回空态、持久化项目名清空。
    expect(find.text('直接制作 3D'), findsOneWidget);
    expect(store.settings.threeProjectName, isEmpty);
  });

  testWidgets('shelf-2：艺术架删除 3D 项目同步清工作台持久化（项目名 + 规范草稿）', (tester) async {
    final stub = _ThreeStub();
    final store = _store(stub.api())
      ..settings.threeProjectName = 'saturn-demo';
    store.setThreeSpecDraft('saturn-demo', '{"stale":true}');

    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(
        theme: AppTheme.build(dark: true),
        home: const Scaffold(body: PortfolioView()),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 150));

    final card = find.ancestor(of: find.text('3D · saturn-demo'), matching: find.byType(ArtShelfCard));
    expect(card, findsOneWidget);
    await tester.tap(find.descendant(of: card, matching: find.byTooltip('更多操作')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除 3D 项目…'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(stub.deleted, ['saturn-demo']);
    // 两条删除入口（工作台对话框 / 艺术架菜单）必须同一清理语义：否则下次
    // 进工作台会续接一个盘上已不存在的项目，并回灌幽灵规范草稿。
    expect(store.settings.threeProjectName, isEmpty);
    expect(store.threeSpecDraft('saturn-demo'), isNull);
  });

  testWidgets('res-2 landscape：metrics 未到前「截图」点不动，到达后可点并真发 JS', (tester) async {
    final fake = await _pumpProject(tester, _store(_ThreeStub().api()), const Size(1440, 900));
    final ctl = fake.lastController!;

    // 未就绪：按钮禁用（onTap null），点击不产生 JS 调用。
    await tester.tap(find.text('截图'));
    await tester.pump(const Duration(milliseconds: 30));
    expect(ctl.jsCalls, 0);

    // 新导航开始 + 一条 metrics 之外的消息：仍未就绪。
    ctl.navDelegate!.firePageStarted('http://mock.local/three/preview/saturn-demo');
    ctl.fireJsMessage(jsonEncode({'kind': 'error', 'message': 'boom'}));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('截图'));
    await tester.pump(const Duration(milliseconds: 30));
    expect(ctl.jsCalls, 0, reason: '非 metrics 桥消息不得点亮就绪态');

    // 预览页的 metrics 桥到达 → 就绪 → 可点且真发 JS。
    ctl.fireJsMessage(jsonEncode({'kind': 'metrics', 'payload': <String, dynamic>{}}));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('截图'));
    await tester.pump(const Duration(milliseconds: 30));
    expect(ctl.jsCalls, 1);

    // 主帧 HTTP ≥400：错误占位替换预览 → 截图再次禁用。
    ctl.navDelegate!.fireHttpError(400);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('截图'));
    await tester.pump(const Duration(milliseconds: 30));
    expect(ctl.jsCalls, 1, reason: '预览失败后截图必须立刻失效');
    expect(find.textContaining('预览加载失败'), findsOneWidget);
  });

  testWidgets('res-2 手机竖屏：PopupMenu 的截图/四方位项共用同一就绪判据', (tester) async {
    // 390×844（手机竖屏）：动作全部收进「3D 操作」菜单——这是 portrait 侧的
    // 真实路径（iPad 竖屏走双行工具栏、没有菜单，别拿它当 portrait 锚）。
    final fake = await _pumpProject(tester, _store(_ThreeStub().api()), const Size(390, 844));
    final ctl = fake.lastController!;

    PopupMenuItem<String> item(String value) => tester.widget<PopupMenuItem<String>>(
        find.byWidgetPredicate((w) => w is PopupMenuItem<String> && w.value == value));

    await tester.tap(find.byTooltip('3D 操作'));
    await tester.pumpAndSettle();
    expect(item('shot').enabled, isFalse);
    expect(item('turntable').enabled, isFalse);

    // 关菜单（点屏障外，避开左上角返回键）→ metrics 到达 → 重开：两项启用。
    await tester.tapAt(const Offset(10, 820));
    await tester.pumpAndSettle();
    ctl.fireJsMessage(jsonEncode({'kind': 'metrics', 'payload': <String, dynamic>{}}));
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.byTooltip('3D 操作'));
    await tester.pumpAndSettle();
    expect(item('shot').enabled, isTrue);
    expect(item('turntable').enabled, isTrue);
  });
}
