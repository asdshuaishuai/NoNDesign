// 挂载迟到回包回归（批次 07 本地化后仍成立）。
//
// 症状（修复前，res-2）：预览控制器的赋值发生在 `await` 之后，没有 setState
// 跟随——本地库读取晚于下一次 build 时，UI 停在「正在打开…」或继续显示上
// 一个应用。本测试用一个可门控的本地库把读取推迟到首帧之后，断言放行后
// WebViewWidget 出现、加载文案消失、预览文件只加载一次。
import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_all/webview_all.dart';
import 'package:webview_platform_interface/webview_platform_interface.dart';
import 'package:webview_all_wkwebview/webview_all_wkwebview.dart';

import 'package:nondesign/core/hotapp_service.dart';
import 'package:nondesign/core/nonapp_cache.dart';
import 'package:nondesign/core/nonapp_library.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/widgets/hotapp_workspace.dart';

String _html() =>
    '<!doctype html><html><head><meta charset=utf-8><style>body{background:#111;'
    'color:#eee;font:14px system-ui}canvas{display:block;width:100%;height:60vh}'
    '</style></head><body><canvas id=c></canvas><div>mount-marker</div>'
    '<script>const c=document.getElementById("c");const x=c.getContext("2d");'
    'function f(){x.clearRect(0,0,9,9);requestAnimationFrame(f);}f();'
    '</script></body></html>';

/// 读取被门控的本地库：模拟「本地库还在解析/读盘」的迟到回包。
class _DelayedLibrary extends NonAppLibrary {
  _DelayedLibrary({required super.root, required this.gate, required this.entry});

  final Completer<void> gate;
  final LibraryApp entry;

  @override
  Future<LibraryApp?> read(String name) async {
    await gate.future;
    return entry;
  }

  @override
  Future<String?> readHtml(String name) async => _html();
}

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

  final loadedFiles = <String>[];

  @override
  Future<void> setJavaScriptMode(JavaScriptMode mode) async {}

  @override
  Future<void> addJavaScriptChannel(dynamic params) async {}

  @override
  Future<void> setPlatformNavigationDelegate(dynamic delegate) async {}

  @override
  Future<void> loadFile(String absoluteFilePath) async {
    loadedFiles.add(absoluteFilePath);
  }

  @override
  Future<void> runJavaScript(String javaScript) async {}
}

class _FakePlatformNavigationDelegate extends PlatformNavigationDelegate {
  _FakePlatformNavigationDelegate(super.params) : super.implementation();

  @override
  Future<void> setOnPageStarted(PageEventCallback cb) async {}

  @override
  Future<void> setOnHttpError(HttpResponseErrorCallback cb) async {}

  @override
  Future<void> setOnWebResourceError(WebResourceErrorCallback cb) async {}

  @override
  Future<void> setOnNavigationRequest(NavigationRequestCallback cb) async {}
}

class _FakePlatformWebViewWidget extends PlatformWebViewWidget {
  _FakePlatformWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

Widget _host(AppStore store, HotAppService service) =>
    ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(
        theme: AppTheme.build(dark: true),
        home: Scaffold(body: HotAppWorkspace(service: service)),
      ),
    );

void main() {
  late Directory temp;
  late Directory cacheDir;
  late _FakeWebViewPlatform fake;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    temp = Directory.systemTemp.createTempSync('nonapp_mount_');
    cacheDir = Directory('${temp.path}/cache')..createSync(recursive: true);
    NonAppCache.rootOverride = cacheDir;
    hotAppLoadOnOpen = null;
    hotAppOfflinePath = null;
    fake = _FakeWebViewPlatform();
    WebViewPlatform.instance = fake;
  });

  tearDown(() {
    WebViewPlatform.instance = WebKitWebViewPlatform();
    NonAppCache.rootOverride = null;
    hotAppLoadOnOpen = null;
    hotAppOfflinePath = null;
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  testWidgets('迟到的本地库读取：放行后落控制器并离开「正在打开…」', (tester) async {
    final store = AppStore()..ready = true;
    final gate = Completer<void>();
    final entry = LibraryApp(
      name: 'demo',
      title: '演示应用',
      renderer: 'html',
      createdAt: 1700000000,
      dir: '${temp.path}/hotapps/demo',
      payloadBytes: _html().length,
      brief: '演示应用',
    );
    final library = _DelayedLibrary(
      root: Directory('${temp.path}/hotapps')..createSync(recursive: true),
      gate: gate,
      entry: entry,
    );
    final service = HotAppService(library: library, llm: (_) async => '');

    hotAppLoadOnOpen = 'demo';
    await tester.pumpWidget(_host(store, service));
    await tester.pump(); // initState 消费通道 → 帧末启动 _mountSaved
    await tester.pump(); // _mountSaved 进入 await gate

    // 回包尚未放行：加载态，且还没有控制器。
    expect(find.text('正在打开…'), findsOneWidget);
    expect(find.byType(WebViewWidget), findsNothing);
    expect(fake.lastController, isNull);

    // 放行迟到回包 + 让真实文件 IO 完成：修复前这里不会触发重建。
    // 交替 pump（跑假时钟的微任务）与 runAsync（推进真实 IO）直到控制器出现。
    gate.complete();
    for (var i = 0; i < 40; i++) {
      await tester.pump();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 15));
      });
      if (fake.lastController != null) break;
    }
    await tester.pump();
    await tester.pump();

    expect(find.text('正在打开…'), findsNothing, reason: '回包后必须离开加载态');
    expect(find.byType(WebViewWidget), findsOneWidget, reason: '回包后控制器必须进树');
    final controller = fake.lastController;
    expect(controller, isNotNull);
    expect(controller!.loadedFiles, hasLength(1), reason: '预览文件恰好加载一次');
    expect(controller.loadedFiles.single, '${cacheDir.path}/demo.html');
    expect(File(controller.loadedFiles.single).existsSync(), isTrue);
  });
}
