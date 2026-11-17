// 离线打开路径（app/lib/widgets/nonapp_import.dart + hotapp_workspace.dart）回归。
//
// api == null（未连接桌面服务器）时的两个分支：
//   ① html 包 → 写 NonAppCache（原子写 + 保守预筛）→ hotAppOfflinePath →
//      工作台 loadFile **恰好一次**，且常驻 SQLite 降级横幅；
//   ② a2ui 包 → 直接 push 查看器，**零 HTTP**（没有 client，也就没有任何请求）。
//
// WebView 用平台桩（与 three_workspace_test 同法：真 WebKit 控制器在
// flutter test 环境构造即抛 UnimplementedError）。
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import 'package:nondesign/core/api.dart';
import 'package:nondesign/core/api_nonapp.dart';
import 'package:nondesign/core/nonapp_cache.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/widgets/hotapp_workspace.dart';
import 'package:nondesign/widgets/nonapp_import.dart';
import 'package:nondesign/widgets/nonapp_viewer.dart';

// ---- WebView 平台桩（loadFile 可观测） ----
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
  final loadedFiles = <String>[];

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

  @override
  Future<void> loadFile(String absoluteFilePath) async {
    loadedFiles.add(absoluteFilePath);
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

// ---- 夹具 ----
String _html() =>
    '<!doctype html><html><head><meta charset=utf-8><style>body{background:#111;'
    'color:#eee;font:14px system-ui}canvas{display:block;width:100%;height:60vh}'
    '</style></head><body><canvas id=c></canvas><div>offline-marker</div>'
    '<script>const c=document.getElementById("c");const x=c.getContext("2d");'
    'let t=0;function f(){t+=0.1;x.clearRect(0,0,9,9);requestAnimationFrame(f);}f();'
    '</script></body></html>';

final List<Object?> _surface = [
  {
    'version': '1.0',
    'createSurface': {
      'surfaceId': 'demo',
      'catalogId': 'https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json',
      'components': [
        {'id': 'root', 'component': 'Column', 'children': ['title']},
        {'id': 'title', 'component': 'Text', 'text': '离线清单'},
      ],
    },
  },
];

List<int> _zip(Map<String, Object> entries) {
  final archive = Archive();
  for (final e in entries.entries) {
    final bytes = e.value is String ? utf8.encode(e.value as String) : e.value as List<int>;
    archive.addFile(ArchiveFile(e.key, bytes.length, bytes));
  }
  return ZipEncoder().encode(archive);
}

Map<String, Object> _manifest(String renderer) => {
      'formatVersion': 1,
      'id': 'offline-app',
      'name': 'offline-app',
      'title': '离线应用',
      'renderer': renderer,
      'createdAt': 1700000000,
      'minAppVersion': '0.1.0',
    };

/// 宿主：`view == 'plugin:hotapp'` 时渲染工作台（模拟 registry 路由）。
Widget _host(AppStore store, String packagePath) => ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(
        theme: AppTheme.build(dark: true),
        home: Consumer<AppStore>(
          builder: (context, s, _) => s.view == 'plugin:hotapp'
              ? const Scaffold(body: HotAppWorkspace())
              : Scaffold(
                  body: Builder(
                    builder: (ctx) => Center(
                      child: TextButton(
                        onPressed: () => openNonAppFromPath(ctx, packagePath),
                        child: const Text('打开包'),
                      ),
                    ),
                  ),
                ),
        ),
      ),
    );

void main() {
  late Directory cacheDir;

  setUp(() {
    cacheDir = Directory.systemTemp.createTempSync('nonapp_cache_test_');
    NonAppCache.rootOverride = cacheDir;
    hotAppLoadOnOpen = null;
    hotAppOfflinePath = null;
  });

  tearDown(() {
    NonAppCache.rootOverride = null;
    hotAppLoadOnOpen = null;
    hotAppOfflinePath = null;
    if (cacheDir.existsSync()) cacheDir.deleteSync(recursive: true);
  });

  testWidgets('api==null + html 包：写缓存并 loadFile 一次，横幅明示 SQLite 降级', (tester) async {
    final store = AppStore()..ready = true; // api 保持 null（离线）
    final dir = Directory.systemTemp.createTempSync('nonapp_pkg_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/offline.nonapp')
      ..writeAsBytesSync(_zip({
        'manifest.json': jsonEncode(_manifest('html')),
        'payload/index.html': _html(),
      }));

    // WebView 平台桩：HotAppWorkspace.initState 的 WebKit registerWith 是
    // 进程级一次性（_wkRegistered），必须**先跑一帧把它耗掉**再装 fake，
    // 否则 registerWith 会把 fake 覆盖回 WebKit（flutter test 下构造即抛
    // 「TargetPlatform.android is not supported」）。
    await tester.pumpWidget(MaterialApp(
      home: ChangeNotifierProvider<AppStore>.value(
        value: store,
        child: const Scaffold(body: HotAppWorkspace()),
      ),
    ));
    await tester.pump();
    final fake = _FakeWebViewPlatform();
    WebViewPlatform.instance = fake;
    addTearDown(() => WebViewPlatform.instance = WebKitWebViewPlatform());

    await tester.pumpWidget(_host(store, file.path));
    await tester.pump(const Duration(milliseconds: 30));

    // 真文件 IO 在 widget test 的假时钟里不会推进——必须 runAsync。
    // 轮询条件包含 store.view：writeHtml 的 await prune 与随后的 setView 都在
    // 真实异步链上（假时钟 pump 不驱动）；只看文件存在会在 setView 之前放行，
    // 全量并发跑时偶发「view 仍是 design」，并让 tearDown 抢删 prune 正在
    // 列目录的缓存目录（2026-11-17 全量门禁实测）。
    await tester.runAsync(() async {
      await tester.tap(find.text('打开包'));
      for (var i = 0; i < 80; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        if (File('${cacheDir.path}/offline-app.html').existsSync() &&
            store.view == 'plugin:hotapp') {
          break;
        }
      }
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));

    final cached = File('${cacheDir.path}/offline-app.html');
    expect(cached.existsSync(), isTrue, reason: 'html 载荷必须落到本地缓存');
    expect(cached.readAsStringSync(), contains('offline-marker'));
    expect(store.view, 'plugin:hotapp');

    final controller = fake.lastController;
    expect(controller, isNotNull);
    expect(controller!.loadedFiles, [cached.path], reason: 'file:// 打开必须恰好一次');
    expect(controller.loadedUrls, isEmpty, reason: '离线路径不得走 HTTP');

    // 常驻横幅：SQLite 桥降级必须明示
    expect(find.textContaining('离线运行：SQLite 桥不可用'), findsOneWidget);
    expect(find.text('退出离线'), findsOneWidget);
  });

  testWidgets('api==null + a2ui 包：直接 push 查看器，零 HTTP', (tester) async {
    final store = AppStore()..ready = true;
    final dir = Directory.systemTemp.createTempSync('nonapp_pkg_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/a2ui.nonapp')
      ..writeAsBytesSync(_zip({
        'manifest.json': jsonEncode(_manifest('a2ui')),
        'payload/surface.json': jsonEncode(_surface),
      }));

    await tester.pumpWidget(_host(store, file.path));
    await tester.pump(const Duration(milliseconds: 30));

    await tester.runAsync(() async {
      await tester.tap(find.text('打开包'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));

    expect(find.byType(NonAppA2uiViewer), findsOneWidget);
    expect(find.text('离线清单'), findsOneWidget);
    expect(store.api, isNull, reason: '离线分支不建 client，也就没有任何请求');
    expect(store.view, isNot('plugin:hotapp'), reason: 'a2ui 不进 WebView 工作台');
    expect(cacheDir.listSync(), isEmpty, reason: 'a2ui 不写 html 缓存');
  });

  testWidgets('坏包：SnackBar 显示稳定 code，不写缓存不进工作台', (tester) async {
    final store = AppStore()..ready = true;
    final dir = Directory.systemTemp.createTempSync('nonapp_pkg_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/bad.nonapp')..writeAsStringSync('not a zip');

    await tester.pumpWidget(_host(store, file.path));
    await tester.pump(const Duration(milliseconds: 30));

    await tester.runAsync(() async {
      await tester.tap(find.text('打开包'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));

    expect(find.text('应用包被拒'), findsOneWidget);
    expect(find.textContaining('nonapp_invalid_zip'), findsOneWidget);
    expect(store.view, isNot('plugin:hotapp'));
    expect(cacheDir.listSync(), isEmpty);
  });

  testWidgets('工作台已挂载时打开 html 包：didUpdateWidget 补消费通道（review nonapp-1）',
      (tester) async {
    // 复现 reviewer 的链路：view 已是 plugin:hotapp、工作台 State 已存在，
    // 此时（应用内「导入」/空态按钮/运行中双击）写全局通道 + setView 同一
    // view——只在 initState 消费会静默吞掉，工作台停在空态。
    final store = AppStore()
      ..ready = true
      ..view = 'plugin:hotapp';
    final dir = Directory.systemTemp.createTempSync('nonapp_pkg_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/reentry.nonapp')
      ..writeAsBytesSync(_zip({
        'manifest.json': jsonEncode(_manifest('html')),
        'payload/index.html': _html(),
      }));

    await tester.pumpWidget(_host(store, file.path));
    await tester.pump();
    final fake = _FakeWebViewPlatform();
    WebViewPlatform.instance = fake;
    addTearDown(() => WebViewPlatform.instance = WebKitWebViewPlatform());
    await tester.pump(const Duration(milliseconds: 30));
    // 已挂载、且是空态（没有离线通道可消费）
    expect(find.text('打开 .nonapp…'), findsOneWidget);

    final ctx = tester.element(find.byType(HotAppWorkspace));
    await tester.runAsync(() async {
      await openNonAppFromPath(ctx, file.path);
      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        if (File('${cacheDir.path}/offline-app.html').existsSync()) break;
      }
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pump(const Duration(milliseconds: 60));

    expect(store.view, 'plugin:hotapp', reason: '视图不变也必须在已挂载的工作台上生效');
    final controller = fake.lastController;
    expect(controller, isNotNull, reason: 'didUpdateWidget 必须补建控制器');
    expect(controller!.loadedFiles, [File('${cacheDir.path}/offline-app.html').path]);
    expect(find.textContaining('离线运行：SQLite 桥不可用'), findsOneWidget);
  });

  testWidgets('离线门更严：<a href=https> 包 parse 通过但写缓存被拒（review nonapp-4）',
      (tester) async {
    final store = AppStore()..ready = true;
    final dir = Directory.systemTemp.createTempSync('nonapp_pkg_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final linkedHtml = _html().replaceFirst('<canvas id=c>',
        '<canvas id=c></canvas><a href="https://example.com/docs">文档</a>');
    final file = File('${dir.path}/linked.nonapp')
      ..writeAsBytesSync(_zip({
        'manifest.json': jsonEncode(_manifest('html')),
        'payload/index.html': linkedHtml,
      }));

    await tester.pumpWidget(_host(store, file.path));
    await tester.pump(const Duration(milliseconds: 30));

    await tester.runAsync(() async {
      await tester.tap(find.text('打开包'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));

    expect(find.text('离线打开失败'), findsOneWidget);
    expect(find.textContaining('nonapp_html_external_refs'), findsOneWidget);
    expect(store.view, isNot('plugin:hotapp'), reason: '被拒不得进 file:// 工作台');
    expect(cacheDir.listSync(), isEmpty);
  });

  testWidgets('冷启动：boot 未完成时打开包要等 ready 再判在线/离线（review nonapp-2）',
      (tester) async {
    // store.ready=false 时 api 尚未赋值（ServerLauncher.launch 还没回来）：
    // 若立刻判定就走离线分支（不导入、不进作品集）。这里让 api 在打开后到位。
    final store = AppStore(); // ready=false，api=null
    final dir = Directory.systemTemp.createTempSync('nonapp_pkg_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/cold.nonapp')
      ..writeAsBytesSync(_zip({
        'manifest.json': jsonEncode(_manifest('html')),
        'payload/index.html': _html(),
      }));

    // 预热/装桩（在线 html 分支会挂工作台 → 需要 WebView 桩）
    await tester.pumpWidget(MaterialApp(
      home: ChangeNotifierProvider<AppStore>.value(
        value: store,
        child: const Scaffold(body: HotAppWorkspace()),
      ),
    ));
    await tester.pump();
    final fake = _FakeWebViewPlatform();
    WebViewPlatform.instance = fake;
    addTearDown(() => WebViewPlatform.instance = WebKitWebViewPlatform());

    await tester.pumpWidget(_host(store, file.path));
    await tester.pump(const Duration(milliseconds: 30));

    final calls = <String>[];
    final api = NoNDesignApi('http://mock.local');
    // 字节面自建 client 的注入点（api.dart 的 _client 是私有字段）
    useNonAppHttpClient(api, MockClient((request) async {
      calls.add('${request.method} ${request.url.path}');
      if (request.url.path == '/hotapp/import') {
        return http.Response.bytes(
          utf8.encode(jsonEncode({
            'ok': true, 'name': 'offline-app', 'title': '离线应用',
            'renderer': 'html', 'id': 'offline-app', 'formatVersion': 1,
            'dir': '/tmp/x', 'portfolio': true,
          })),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      }
      if (request.url.path.startsWith('/hotapp/info/')) {
        return http.Response.bytes(
          utf8.encode(jsonEncode({
            'ok': true, 'name': 'offline-app', 'title': '离线应用',
            'renderer': 'html', 'exists': true,
          })),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response.bytes(utf8.encode(jsonEncode({'ok': true})), 200,
          headers: const {'content-type': 'application/json; charset=utf-8'});
    }));

    await tester.runAsync(() async {
      await tester.tap(find.text('打开包'));
      await Future<void>.delayed(const Duration(milliseconds: 80));
      // boot 完成：api 就位（等价于 ServerLauncher.launch 返回）
      store.api = api;
      store.ready = true;
      store.notifyListeners();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));

    expect(calls, contains('POST /hotapp/import'),
        reason: '冷启动必须先等 boot，再走在线导入而不是离线缓存');
    expect(store.view, 'plugin:hotapp');
    expect(cacheDir.listSync(), isEmpty, reason: '在线分支不写离线缓存');
    expect(fake.lastController?.loadedUrls, isNotEmpty,
        reason: '在线 html 走 /hotapp/page 的 HTTP 路径，不是 file://');
  });
}
