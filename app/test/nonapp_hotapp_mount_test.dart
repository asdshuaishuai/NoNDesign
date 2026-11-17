// res-2 回归：`_mount` 自 async 化后，/hotapp/info 的迟到回包必须触发重建。
//
// 症状（修复前）：`_controller = _newController()..loadRequest(...)` 的赋值
// 发生在 await 之后，没有 setState 跟随——回包晚于下一次 build 时 UI 停在
// 「加载中…」或继续显示上一个应用。本测试用可门控的 /hotapp/info mock 把
// 回包推迟到首帧之后，断言放行后 WebViewWidget 出现、加载文案消失。
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import 'package:nondesign/core/api.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/widgets/hotapp_workspace.dart';

// ---- WebView 平台桩（与 nonapp_offline_test 同法：真 WebKit 控制器在
// flutter test 环境构造即抛） ----
class _FakeWebViewPlatform extends WebViewPlatform {
  _FakePlatformWebViewController? lastController;

  @override
  PlatformWebViewController createPlatformWebViewController(
          PlatformWebViewControllerCreationParams params) =>
      lastController = _FakePlatformWebViewController(params);

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

  @override
  Future<void> setJavaScriptMode(JavaScriptMode mode) async {}

  @override
  Future<void> addJavaScriptChannel(dynamic params) async {}

  @override
  Future<void> setPlatformNavigationDelegate(dynamic delegate) async {}

  @override
  Future<void> loadRequest(dynamic params) async {
    loadedUrls.add(params.uri as Uri);
  }
}

class _FakePlatformNavigationDelegate extends PlatformNavigationDelegate {
  _FakePlatformNavigationDelegate(super.params) : super.implementation();

  @override
  Future<void> setOnPageStarted(PageEventCallback cb) async {}

  @override
  Future<void> setOnHttpError(HttpResponseErrorCallback cb) async {}

  @override
  Future<void> setOnWebResourceError(WebResourceErrorCallback cb) async {}
}

class _FakePlatformWebViewWidget extends PlatformWebViewWidget {
  _FakePlatformWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

Widget _host(AppStore store, {Key? workspaceKey}) => ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(
        theme: AppTheme.build(dark: true),
        home: Scaffold(body: HotAppWorkspace(key: workspaceKey)),
      ),
    );

void main() {
  testWidgets('延迟 /hotapp/info 回包：放行后落控制器并离开「加载中…」', (tester) async {
    final store = AppStore()..ready = true;
    final gate = Completer<void>();
    store.api = NoNDesignApi('http://127.0.0.1:1', MockClient((request) async {
      if (request.url.path == '/hotapp/info/demo') {
        await gate.future;
        return http.Response(
          jsonEncode({
            'ok': true,
            'name': 'demo',
            'title': '演示应用',
            'renderer': 'html',
            'exists': true,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('not found', 404);
    }));

    // 先跑一帧消耗进程级 WebKit registerWith（_wkRegistered 一次性），否则
    // 下方 registerWith 会把 fake 覆盖回 WebKit。
    await tester.pumpWidget(_host(store, workspaceKey: const ValueKey('warmup')));
    await tester.pump();
    final fake = _FakeWebViewPlatform();
    WebViewPlatform.instance = fake;
    addTearDown(() => WebViewPlatform.instance = WebKitWebViewPlatform());

    // 换 key = 重建 State，initState 消费 hotAppLoadOnOpen → _mount 起跑。
    hotAppLoadOnOpen = 'demo';
    addTearDown(() => hotAppLoadOnOpen = null);
    await tester.pumpWidget(_host(store, workspaceKey: const ValueKey('real')));
    await tester.pump();
    await tester.pump();

    // 回包尚未放行：加载态，且还没有控制器。
    expect(find.text('加载中…'), findsOneWidget);
    expect(find.byType(WebViewWidget), findsNothing);
    expect(fake.lastController, isNull);

    // 放行迟到回包：_mount 的 await 之后才赋值控制器——修复前这里不会
    // 触发重建，界面继续停在「加载中…」。
    gate.complete();
    await tester.pump();
    await tester.pump();

    expect(find.text('加载中…'), findsNothing, reason: '回包后必须离开加载态');
    expect(find.byType(WebViewWidget), findsOneWidget, reason: '回包后控制器必须进树');
    final controller = fake.lastController;
    expect(controller, isNotNull);
    expect(
      controller!.loadedUrls.map((u) => u.toString()),
      contains('http://127.0.0.1:1/hotapp/page/demo'),
      reason: '控制器必须加载当前应用页面',
    );
  });
}
