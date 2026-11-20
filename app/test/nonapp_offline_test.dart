// 应用包打开路径（app/lib/widgets/nonapp_import.dart + hotapp_workspace.dart）
// 回归 —— 批次 07 起全部本地。
//
// 覆盖：
//   ① html 包 → 安装进本地库 → 工作台 file:// 预览 **恰好一次**；
//      缓存文件自带 CSP 与本地数据桥（策略在前、桥在后、都早于页面内容）；
//      导航白名单：远端整页 prevent、file:// 放行；
//   ② a2ui 包 → 安装进库 + 内嵌查看器（零网络、不写预览缓存）；
//   ③ 坏包 → 一句人话的通知（不把内部错误码当文案），不写库；
//   ④ 冷启动竞态（review nonapp-2）：应用未就绪时打开包要等 ready 再安装；
//   ⑤ 数据桥往返：页面消息 → SQLite → 结果回填 JS；
//   ⑥ 库不可用：html 仍可临时预览，并常驻「不会保存」横幅。
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import 'package:nondesign/core/hotapp_db.dart';
import 'package:nondesign/core/hotapp_service.dart';
import 'package:nondesign/core/nonapp_cache.dart';
import 'package:nondesign/core/nonapp_library.dart';
import 'package:nondesign/core/nonapp_package.dart';
import 'package:nondesign/core/platform_capabilities.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/core/toast_service.dart';
import 'package:nondesign/widgets/hotapp_workspace.dart';
import 'package:nondesign/widgets/nonapp_import.dart';
import 'package:nondesign/widgets/nonapp_viewer.dart';
import 'package:nondesign/widgets/toast_host.dart';

// ---- WebView 平台桩（loadFile / JS 通道 / 导航回调可观测） ----
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
  final jsCalls = <String>[];
  final channels = <String, void Function(JavaScriptMessage)>{};
  _FakePlatformNavigationDelegate? navDelegate;

  @override
  Future<void> setJavaScriptMode(JavaScriptMode mode) async {}

  @override
  Future<void> addJavaScriptChannel(dynamic params) async {
    final channel = params as JavaScriptChannelParams;
    channels[channel.name] = channel.onMessageReceived;
  }

  @override
  Future<void> setPlatformNavigationDelegate(dynamic delegate) async {
    navDelegate = delegate as _FakePlatformNavigationDelegate;
  }

  @override
  Future<void> loadRequest(dynamic params) async {
    loadedUrls.add(params.uri as Uri);
  }

  @override
  Future<void> loadFile(String absoluteFilePath) async {
    loadedFiles.add(absoluteFilePath);
  }

  @override
  Future<void> runJavaScript(String javaScript) async {
    jsCalls.add(javaScript);
  }
}

class _FakePlatformNavigationDelegate extends PlatformNavigationDelegate {
  _FakePlatformNavigationDelegate(super.params) : super.implementation();

  NavigationRequestCallback? onNavigationRequest;

  @override
  Future<void> setOnPageStarted(PageEventCallback cb) async {}

  @override
  Future<void> setOnHttpError(HttpResponseErrorCallback cb) async {}

  @override
  Future<void> setOnWebResourceError(WebResourceErrorCallback cb) async {}

  @override
  Future<void> setOnNavigationRequest(NavigationRequestCallback cb) async =>
      onNavigationRequest = cb;
}

class _FakePlatformWebViewWidget extends PlatformWebViewWidget {
  _FakePlatformWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// 安装必然失败的库（模拟磁盘不可写）：临时预览分支必须仍然可用。
class _FailingLibrary extends NonAppLibrary {
  _FailingLibrary({required super.root});

  @override
  Future<LibraryApp> install(NonAppPackage pkg) async {
    throw const NonAppException('nonapp_install_failed', 'disk full');
  }
}

// ---- 夹具 ----
String _html() =>
    '<!doctype html><html><head><meta charset=utf-8><style>body{background:#111;'
    'color:#eee;font:14px system-ui}canvas{display:block;width:100%;height:60vh}'
    '</style></head><body><canvas id=c></canvas><div id=m>offline-marker</div>'
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
        {'id': 'title', 'component': 'Text', 'text': '本地清单'},
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

Widget _host(AppStore store, String packagePath, NonAppLibrary library) =>
    ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(
        theme: AppTheme.build(dark: true),
        builder: (context, child) =>
            ToastHost(service: store.toasts, child: child ?? const SizedBox.shrink()),
        home: Consumer<AppStore>(
          builder: (context, s, _) => s.view == 'plugin:hotapp'
              ? Scaffold(
                  body: HotAppWorkspace(
                    service: HotAppService(library: library, llm: (_) async => ''),
                  ),
                )
              : Scaffold(
                  body: Builder(
                    builder: (ctx) => Center(
                      child: TextButton(
                        onPressed: () => openNonAppFromPath(ctx, packagePath, library: library),
                        child: const Text('打开包'),
                      ),
                    ),
                  ),
                ),
        ),
      ),
    );

/// 交替 pump（假时钟里的微任务）与 runAsync（真实文件 IO），直到条件成立。
///
/// 本地路径全是真实磁盘操作：widget test 的假时钟只推进微任务，不推进
/// dart:io 的事件；只 pump 会让「等待写预览」的分支停在半路。
Future<void> _drainUntil(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 80; i++) {
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    if (done()) break;
  }
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 60));
}

Future<void> _openAndSettle(
  WidgetTester tester,
  AppStore store,
  _FakeWebViewPlatform fake,
) async {
  await tester.tap(find.text('打开包'));
  await _drainUntil(
    tester,
    () => store.view == 'plugin:hotapp' && fake.lastController != null,
  );
}

void main() {
  late Directory temp;
  late Directory cacheDir;
  late NonAppLibrary library;
  late _FakeWebViewPlatform fake;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    temp = Directory.systemTemp.createTempSync('nonapp_open_');
    cacheDir = Directory('${temp.path}/cache')..createSync(recursive: true);
    NonAppCache.rootOverride = cacheDir;
    library = await NonAppLibrary.open(root: Directory('${temp.path}/hotapps'));
    hotAppLoadOnOpen = null;
    hotAppOfflinePath = null;
    fake = _FakeWebViewPlatform();
    WebViewPlatform.instance = fake;
  });

  tearDown(() async {
    WebViewPlatform.instance = WebKitWebViewPlatform();
    NonAppCache.rootOverride = null;
    hotAppLoadOnOpen = null;
    hotAppOfflinePath = null;
    // Windows 上 WebView/临时文件句柄可能晚一点释放：删除失败重试。
    await _deleteTempWithRetry(temp);
  });

  testWidgets('html 包：装进本机库 → file:// 预览一次，CSP 与数据桥先于内容', (tester) async {
    final store = AppStore(toasts: ToastService(autoDismiss: false))..ready = true;
    final file = File('${temp.path}/offline.nonapp')
      ..writeAsBytesSync(_zip({
        'manifest.json': jsonEncode(_manifest('html')),
        'payload/index.html': _html(),
      }));

    await tester.pumpWidget(_host(store, file.path, library));
    await tester.pump();
    await _openAndSettle(tester, store, fake);

    final entry = await library.read('offline-app');
    expect(entry, isNotNull, reason: '导入必须落本地库');
    expect(File('${entry!.dir}/app.db').existsSync(), isTrue);
    expect(store.view, 'plugin:hotapp');

    final controller = fake.lastController;
    expect(controller, isNotNull);
    final cached = '${cacheDir.path}/offline-app.html';
    expect(controller!.loadedFiles, [cached], reason: 'file:// 打开必须恰好一次');
    expect(controller.loadedUrls, isEmpty, reason: '本地预览不得走网络');

    final cachedHtml = File(cached).readAsStringSync();
    expect(cachedHtml, contains('http-equiv="Content-Security-Policy"'));
    expect(cachedHtml, contains(nonAppOfflineCsp));
    expect(cachedHtml, contains('window.NoN.db'));
    expect(cachedHtml.indexOf('Content-Security-Policy'),
        lessThan(cachedHtml.indexOf('window.NoN.db')));
    expect(cachedHtml.indexOf('window.NoN.db'), lessThan(cachedHtml.indexOf('offline-marker')),
        reason: '策略与数据桥必须先于页面内容生效');

    // nonapp-5：运行期导航白名单——远端整页导航 prevent，file:// 放行。
    final nav = controller.navDelegate;
    expect(nav?.onNavigationRequest, isNotNull);
    expect(
        await nav!.onNavigationRequest!(
            const NavigationRequest(url: 'https://evil.example/x', isMainFrame: true)),
        NavigationDecision.prevent);
    expect(
        await nav.onNavigationRequest!(
            NavigationRequest(url: Uri.file(cached).toString(), isMainFrame: true)),
        NavigationDecision.navigate);
    expect(find.byType(WebViewWidget), findsOneWidget);
  });

  testWidgets('数据桥往返：页面消息 → SQLite → JS 回填结果', (tester) async {
    final store = AppStore(toasts: ToastService(autoDismiss: false))..ready = true;
    final file = File('${temp.path}/db.nonapp')
      ..writeAsBytesSync(_zip({
        'manifest.json': jsonEncode(_manifest('html')),
        'payload/index.html': _html(),
      }));
    await tester.pumpWidget(_host(store, file.path, library));
    await tester.pump();
    await _openAndSettle(tester, store, fake);

    final controller = fake.lastController!;
    final db = controller.channels[hotAppDbChannel];
    expect(db, isNotNull, reason: '工作台必须挂数据通道');

    db!(const JavaScriptMessage(
        message: '{"id":"q1","sql":"CREATE TABLE kv (k TEXT PRIMARY KEY, v TEXT)","params":[]}'));
    db(const JavaScriptMessage(
        message: '{"id":"q2","sql":"INSERT INTO kv (k, v) VALUES (?, ?)","params":["a","1"]}'));
    db(const JavaScriptMessage(
        message: '{"id":"q3","sql":"SELECT v FROM kv WHERE k = ?","params":["a"]}'));
    await tester.pump();

    expect(controller.jsCalls.length, 3);
    final last = controller.jsCalls.last;
    expect(last, contains(hotAppDbResultFunction));
    expect(last, contains('"ok":true'));
    expect(last, contains('"v":"1"'));

    // 内部错误不让页面卡死：被拒的 SQL 也回填 ok:false。
    db(const JavaScriptMessage(
        message: '{"id":"q4","sql":"ATTACH DATABASE \'/tmp/x\' AS y","params":[]}'));
    await tester.pump();
    expect(controller.jsCalls.last, contains('"ok":false'));
  });

  testWidgets('a2ui 包：装进本机库 + 内嵌查看器，不写预览缓存', (tester) async {
    final store = AppStore(toasts: ToastService(autoDismiss: false))..ready = true;
    final file = File('${temp.path}/a2ui.nonapp')
      ..writeAsBytesSync(_zip({
        'manifest.json': jsonEncode(_manifest('a2ui')),
        'payload/surface.json': jsonEncode(_surface),
      }));

    await tester.pumpWidget(_host(store, file.path, library));
    await tester.pump();

    await tester.tap(find.text('打开包'));
    await _drainUntil(
      tester,
      () => find.byType(NonAppA2uiViewer).evaluate().isNotEmpty,
    );

    expect(find.byType(NonAppA2uiViewer), findsOneWidget);
    expect(find.text('本地清单'), findsOneWidget);
    expect(await library.read('offline-app'), isNotNull);
    expect(Directory(cacheDir.path).listSync(), isEmpty, reason: 'a2ui 不写预览缓存');
    expect(store.view, isNot('plugin:hotapp'));
  });

  testWidgets('坏包：通知里只有一句人话，不写库、不进工作台', (tester) async {
    final store = AppStore(toasts: ToastService(autoDismiss: false))..ready = true;
    final file = File('${temp.path}/bad.nonapp')..writeAsStringSync('not a zip');

    await tester.pumpWidget(_host(store, file.path, library));
    await tester.pump();

    await tester.tap(find.text('打开包'));
    await _drainUntil(
      tester,
      () => find.text('应用包被拒').evaluate().isNotEmpty,
    );

    expect(find.text('应用包被拒'), findsOneWidget);
    expect(find.text('这个文件不是有效的应用包'), findsOneWidget);
    expect(find.textContaining('nonapp_invalid_zip'), findsNothing,
        reason: '内部错误码不得出现在用户可见文案里');
    expect(await library.scan(), isEmpty);
    expect(store.view, isNot('plugin:hotapp'));
  });

  testWidgets('冷启动竞态：应用未就绪时打开包要等 ready 再安装（review nonapp-2）',
      (tester) async {
    final store = AppStore(toasts: ToastService(autoDismiss: false)); // ready=false
    final file = File('${temp.path}/cold.nonapp')
      ..writeAsBytesSync(_zip({
        'manifest.json': jsonEncode(_manifest('html')),
        'payload/index.html': _html(),
      }));

    await tester.pumpWidget(_host(store, file.path, library));
    await tester.pump();

    await tester.runAsync(() async {
      await tester.tap(find.text('打开包'));
      await Future<void>.delayed(const Duration(milliseconds: 80));
      // 启动完成：就绪信号到达后，等待中的打开动作必须继续安装。
      store.ready = true;
      store.notifyListeners();
      for (var i = 0; i < 80; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        if (store.view == 'plugin:hotapp') break;
      }
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));

    expect(store.view, 'plugin:hotapp', reason: '就绪后必须继续，不得静默丢弃');
    expect(await library.read('offline-app'), isNotNull);
  });

  testWidgets('库不可用：html 仍可临时预览，并常驻「不会保存」横幅', (tester) async {
    final store = AppStore(toasts: ToastService(autoDismiss: false))..ready = true;
    final failing = _FailingLibrary(root: Directory('${temp.path}/readonly'));
    final file = File('${temp.path}/temp.nonapp')
      ..writeAsBytesSync(_zip({
        'manifest.json': jsonEncode(_manifest('html')),
        'payload/index.html': _html(),
      }));

    await tester.pumpWidget(_host(store, file.path, failing));
    await tester.pump();
    await _openAndSettle(tester, store, fake);

    expect(store.view, 'plugin:hotapp');
    // 通道被工作台消费后会被清空，真正的证据是缓存文件与它被加载。
    final tempPreview = '${cacheDir.path}/offline-app.html';
    expect(File(tempPreview).existsSync(), isTrue);
    expect(fake.lastController?.loadedFiles, [tempPreview]);
    expect(find.textContaining('临时预览：这个应用没有保存到本机'), findsOneWidget);
    expect(find.text('退出预览'), findsOneWidget);
  });

  test('没有系统文件关联的平台：界面明示从应用内打开（不静默缺失）', () {
    expect(nonAppOpenHint(PlatformCapabilities.forOs(HostOs.linux)), isNotNull);
    expect(nonAppOpenHint(PlatformCapabilities.forOs(HostOs.windows)), isNotNull);
    expect(nonAppOpenHint(PlatformCapabilities.forOs(HostOs.macos)), isNull);
    expect(nonAppOpenHint(PlatformCapabilities.forOs(HostOs.android)), isNull);
  });

  test('失败提示：版本过新映射成人话，不把内部错误码上屏', () {
    expect(
      nonAppExceptionMessage(
          const NonAppException('nonapp_unsupported_version:2', '不支持的包格式版本')),
      '应用版本过新，请更新本应用',
    );
    expect(
      nonAppExceptionMessage(const NonAppException('nonapp_too_large', '太大')),
      '这个应用包太大了，无法打开',
    );
    expect(
      nonAppExceptionMessage(const NonAppException('nonapp_unknown_thing', 'x')),
      isNot(contains('nonapp')),
    );
  });

  test('移动端缓存根：应用支持目录，不再落系统临时目录', () async {
    final support = Directory('${temp.path}/support')..createSync(recursive: true);
    NonAppCache.rootOverride = null;
    NonAppCache.debugMobileOverride = true;
    NonAppCache.debugSupportDirectory = () async => support;
    addTearDown(() {
      NonAppCache.debugMobileOverride = null;
      NonAppCache.debugSupportDirectory = null;
    });

    final root = await NonAppCache.root();
    expect(root.path, '${support.path}/nonapp_cache');
    expect(root.path, isNot('${Directory.systemTemp.path}/nonapp_cache'),
        reason: '缓存必须落应用支持目录（系统清理临时目录不再连带丢掉预览）');
  });

  test('预览缓存修剪：只保留最近 8 个（移动端迁移后同一策略）', () async {
    for (var i = 0; i < 11; i++) {
      await NonAppCache.writeHtml(
        name: 'cache-app-$i',
        htmlBytes: utf8.encode(_html()),
        withDbBridge: true,
      );
    }
    final files = Directory(cacheDir.path)
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.html'))
        .toList();
    expect(files.length, 8, reason: 'prune 默认保留最近 8 个预览文件');
  });

  // nonapp-5：导航白名单的纯函数面。
  group('hotAppNavigationAllowed', () {
    test('file/about 放行；远端主机、非常规 scheme、无 baseUrl 一律拦', () {
      expect(hotAppNavigationAllowed('file:///tmp/cache/app.html'), isTrue);
      expect(hotAppNavigationAllowed('about:blank'), isTrue);
      expect(
          hotAppNavigationAllowed('http://127.0.0.1:8799/hotapp/page/x',
              baseUrl: 'http://127.0.0.1:8799'),
          isTrue);
      expect(
          hotAppNavigationAllowed('http://127.0.0.1:8800/hotapp/page/x',
              baseUrl: 'http://127.0.0.1:8799'),
          isFalse,
          reason: '端口不同即不同源');
      expect(hotAppNavigationAllowed('https://evil.example/x', baseUrl: 'http://127.0.0.1:8799'),
          isFalse);
      expect(hotAppNavigationAllowed('http://127.0.0.1:8799/x', baseUrl: ''), isFalse);
      expect(hotAppNavigationAllowed('javascript:alert(1)'), isFalse);
      expect(hotAppNavigationAllowed('data:text/html,<script>1</script>'), isFalse);
      expect(hotAppNavigationAllowed('not a url'), isFalse);
    });
  });
}

/// Windows 上 sqlite / WebView / 临时文件句柄可能还没释放：删除失败重试几次，
/// 别让清理步骤把已通过的断言判红。
Future<void> _deleteTempWithRetry(Directory dir) async {
  for (var attempt = 0; attempt < 10; attempt++) {
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
      return;
    } on FileSystemException {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
}
