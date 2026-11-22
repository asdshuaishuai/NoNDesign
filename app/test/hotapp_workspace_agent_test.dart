// 「NaN 生成完热应用，工作台里没有东西」回归（批次 07 / 共享任务 task-4）。
//
// 断点（修复前）：`hotapp_workspace.dart` 的 store 监听只对
// `settings.hotappApp`/`hotappFromPrototypeBusy` 做了一次 setState——顶栏重建
// 了，但 `_app`/`_entry`/预览控制器还停在旧值；`hotapp_refine` 这类**不改名**
// 的原地改写更是完全没有信号。于是「NaN 说做完了」时工作台没有新应用、预览
// 还是旧页面，run 结束也没有任何收尾刷新。
//
// 这里用注入的临时库 + 假 WebView 平台锚定修复后的行为：
//  1. store 写入新的 hotappApp → 自动切应用、重挂预览、刷新类型/来源徽标；
//  2. NaN run 在飞 → 有可见进度；run 结束 → 重扫列表 + 刷新当前应用（同名精修）；
//  3. 读失败有正常人话文案（不白屏）；
//  4. Windows（无应用内 WebView）保留浏览器/路径降级面；
//  5. 390px 手机宽度与桌面宽度都不溢出。
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_platform_interface/webview_platform_interface.dart';
import 'package:webview_all_wkwebview/webview_all_wkwebview.dart';

import 'package:nondesign/core/capability_hub.dart';
import 'package:nondesign/core/hotapp_service.dart';
import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/nonapp_cache.dart';
import 'package:nondesign/core/nonapp_library.dart';
import 'package:nondesign/core/nonapp_package.dart';
import 'package:nondesign/core/platform_capabilities.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/widgets/hotapp_workspace.dart';

String _html(String marker) =>
    '<!doctype html><html><head><meta charset=utf-8><style>'
    'html,body{margin:0;height:100%;background:#111;color:#eee;'
    'font:14px system-ui}.m{display:block;padding:12px}'
    '</style></head><body><div class="m">$marker</div>'
    '<script>window.__marker="$marker";</script></body></html>';

LibraryApp _app(
  String name, {
  String title = '演示应用',
  String origin = nonAppOriginApp,
  String? brief,
}) =>
    LibraryApp(
      name: name,
      title: title,
      renderer: 'html',
      createdAt: 1700000000,
      // 真实目录由注入的库覆盖；这里只用于「在文件夹中显示」的字段完整性。
      dir: Directory.systemTemp.path,
      payloadBytes: 128,
      brief: brief,
      origin: origin,
    );

/// 注入用的本地库：应用清单与页面都在内存里，不碰真实用户目录。
class _AgentLibrary extends NonAppLibrary {
  _AgentLibrary({required super.root});

  final List<LibraryApp> apps = [];
  final Map<String, String> pages = {};

  /// run 结束后工作台应重扫列表（不拿旧数据）。
  int scanCount = 0;

  void put(LibraryApp app, String html) {
    apps.add(app);
    pages[app.name] = html;
  }

  void replaceMeta(
    String name, {
    String? origin,
    String? title,
    String? brief,
  }) {
    for (var i = 0; i < apps.length; i++) {
      final a = apps[i];
      if (a.name != name) continue;
      apps[i] = LibraryApp(
        name: a.name,
        title: title ?? a.title,
        renderer: a.renderer,
        createdAt: a.createdAt,
        dir: a.dir,
        payloadBytes: a.payloadBytes,
        brief: brief ?? a.brief,
        origin: origin ?? a.origin,
      );
      return;
    }
  }

  @override
  Future<List<LibraryApp>> scan() async {
    scanCount++;
    return List<LibraryApp>.of(apps);
  }

  @override
  Future<LibraryApp?> read(String name) async {
    for (final a in apps) {
      if (a.name == name) return a;
    }
    return null;
  }

  @override
  Future<String?> readHtml(String name) async => pages[name];
}

class _FakeWebViewPlatform extends WebViewPlatform {
  _FakePlatformWebViewController? lastController;
  int controllerCreations = 0;

  @override
  PlatformWebViewController createPlatformWebViewController(
          PlatformWebViewControllerCreationParams params) {
    controllerCreations++;
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

/// 预览挂载/读盘都走真实文件 IO：交替 pump 与 runAsync 推进。
/// 条件满足后再 pump 一帧，让刚完成的异步挂载真正进树后再断言。
Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() done, {
  int maxPumps = 60,
}) async {
  for (var i = 0; i < maxPumps; i++) {
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    if (done()) {
      await tester.pump();
      return;
    }
  }
}

void _setPhone(WidgetTester tester, {double width = 390, double height = 844}) {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  late Directory temp;
  late Directory cacheDir;
  late _FakeWebViewPlatform fake;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    temp = Directory.systemTemp.createTempSync('hotapp_agent_');
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
    // Windows 上临时目录里的文件可能被上一轮 WebView/设置镜像短暂占用：
    // 清理失败不该让通过的业务断言变成红。
    try {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  AppStore store() {
    final s = AppStore()..ready = true;
    s.settingsMirrorDir = temp.path;
    return s;
  }

  HotAppService service(_AgentLibrary library) =>
      HotAppService(library: library, llm: (_) async => '');

  testWidgets('store 写入新 hotappApp → 自动切应用、重挂预览、刷新类型徽标',
      (tester) async {
    _setPhone(tester);
    final lib = _AgentLibrary(root: Directory('${temp.path}/hotapps'));
    lib.put(_app('old-app', title: '旧应用'), _html('old-marker'));
    final appStore = store();
    appStore.setHotApp('old-app');

    await tester.pumpWidget(_host(appStore, service(lib)));
    await _pumpUntil(tester, () => fake.lastController != null);

    expect(find.text('热应用 · old-app'), findsOneWidget);
    expect(find.byKey(const ValueKey('hotapp-origin-badge-app')), findsOneWidget);

    // NaN 生成/精修完成：store 在成功的 hotapp_* tool_end 后写新应用名。
    lib.put(
      _app('new-demo', title: '新应用', origin: nonAppOriginPrototype, brief: '刚生成'),
      _html('new-marker'),
    );
    appStore.setHotApp('new-demo');
    await tester.pump();
    await _pumpUntil(
      tester,
      () =>
          fake.controllerCreations >= 2 &&
          fake.lastController != null &&
          fake.lastController!.loadedFiles.isNotEmpty &&
          fake.lastController!.loadedFiles.last.endsWith('/new-demo.html'),
    );

    // 工作台不再停在旧应用：标题、徽标、预览文件都跟着换。
    expect(find.text('热应用 · new-demo'), findsOneWidget,
        reason: 'NaN 生成完必须自动切到新应用');
    expect(find.byKey(const ValueKey('hotapp-origin-badge-prototype')), findsOneWidget,
        reason: '类型/来源徽标必须跟着应用刷新');
    final lastFile = fake.lastController!.loadedFiles.last;
    expect(lastFile, '${cacheDir.path}/new-demo.html');
    expect(File(lastFile).existsSync(), isTrue);
    expect(File(lastFile).readAsStringSync(), contains('new-marker'));
  });

  testWidgets('NaN run 在飞有进度横幅；run 结束重扫列表并刷新同名精修',
      (tester) async {
    _setPhone(tester);
    final lib = _AgentLibrary(root: Directory('${temp.path}/hotapps'));
    lib.put(_app('demo', title: '演示', brief: '初版'), _html('v1-marker'));
    final appStore = store();
    appStore.setHotApp('demo');

    await tester.pumpWidget(_host(appStore, service(lib)));
    await _pumpUntil(tester, () => fake.lastController != null);
    expect(File('${cacheDir.path}/demo.html').readAsStringSync(), contains('v1-marker'));

    // 用户已在修改框里写了内容：自动刷新不得吞掉它。
    await tester.enterText(find.byType(TextField), '把背景换成绿色');
    await tester.pump();

    // NaN 正在跑一轮热应用精修（run 在飞 + hotapp_* 工具行）。
    appStore.agentBusy = true;
    appStore.timeline.add(
      TimelineEntry(
        kind: 'tool',
        tool: 'hotapp_refine',
        args: const {'name': 'demo'},
        running: true,
      ),
    );
    // ignore: invalid_use_of_protected_member
    appStore.notifyListeners();
    await tester.pump();

    expect(find.text('NaN 正在生成或修改热应用，完成后会自动刷新预览。'), findsOneWidget,
        reason: '生成期间不能看起来「没反应」');
    expect(find.byType(CircularProgressIndicator), findsOneWidget,
        reason: '生成期间保持转圈，但 run 终态必须收掉');

    // 精修落地：应用名不变（所以只监听 settings.hotappApp 会漏掉），页面与
    // 类型都变了。
    lib.pages['demo'] = _html('v2-marker');
    lib.replaceMeta('demo', origin: nonAppOriginPrototype);
    appStore.timeline.last.running = false;
    final scansBefore = lib.scanCount;
    final creationsBefore = fake.controllerCreations;
    appStore.debugForceIdle(); // agentBusy=false + notify = run 终态
    await tester.pump();
    expect(appStore.settings.hotappApp, 'demo',
        reason: '同名精修：应用名没变，必须靠 run 结束信号刷新');
    await _pumpUntil(
      tester,
      () =>
          fake.controllerCreations > creationsBefore &&
          fake.lastController != null &&
          fake.lastController!.loadedFiles.isNotEmpty &&
          File(fake.lastController!.loadedFiles.last)
              .readAsStringSync()
              .contains('v2-marker'),
    );

    expect(find.text('NaN 正在生成或修改热应用，完成后会自动刷新预览。'), findsNothing,
        reason: 'run 终态必须收掉进度横幅，不留无终态转圈');
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byKey(const ValueKey('hotapp-origin-badge-prototype')), findsOneWidget);
    expect(File('${cacheDir.path}/demo.html').readAsStringSync(), contains('v2-marker'),
        reason: 'run 结束必须重挂预览，拾取智能体原地写回的新页面');
    expect(find.text('把背景换成绿色'), findsOneWidget,
        reason: '自动刷新不得清掉用户手动输入/精修状态');
    await _pumpUntil(tester, () => lib.scanCount > scansBefore);
    expect(lib.scanCount, greaterThan(scansBefore),
        reason: 'run 结束必须重扫应用列表');
  });

  testWidgets('读失败：应用不在了 / 内容读不出来都是人话文案，不白屏',
      (tester) async {
    _setPhone(tester);
    final lib = _AgentLibrary(root: Directory('${temp.path}/hotapps'));
    // 页面缺失：入口还在，内容读不出来。
    lib.put(_app('broken', title: '内容损坏'), '');
    lib.pages.clear();
    final appStore = store();
    appStore.setHotApp('broken');

    await tester.pumpWidget(_host(appStore, service(lib)));
    await _pumpUntil(
      tester,
      () => find.text('这个应用的内容读不出来').evaluate().isNotEmpty,
    );
    expect(find.text('这个应用的内容读不出来'), findsOneWidget);
    expect(fake.lastController, isNull, reason: '读失败不得挂空控制器白屏');

    // 应用被删掉：切过去要明说「已经不在了」，而不是停在上一个应用。
    lib.apps.clear();
    appStore.setHotApp('ghost');
    await tester.pump();
    await _pumpUntil(
      tester,
      () => find.text('这个应用已经不在了，可能在作品集里被删除了').evaluate().isNotEmpty,
    );
    expect(find.text('这个应用已经不在了，可能在作品集里被删除了'), findsOneWidget);
    expect(fake.lastController?.loadedFiles ?? const <String>[], isEmpty);
  });

  testWidgets('无内嵌 WebView 的宿主：预览路径不可用时保留浏览器/路径降级面（不静默白屏）',
      (tester) async {
    _setPhone(tester);
    final caps = CapabilityHub(
      platform: PlatformCapabilities.forOs(HostOs.web, isWeb: true),
    );
    final appStore = AppStore(capabilities: caps)..ready = true;
    appStore.settingsMirrorDir = temp.path;
    final lib = _AgentLibrary(root: Directory('${temp.path}/hotapps'));
    lib.put(_app('win-app', title: 'Windows 应用'), '');
    lib.pages.clear(); // 页面内容读不出来 → WebView2 路径解析失败
    appStore.setHotApp('win-app');

    await tester.pumpWidget(_host(appStore, service(lib)));
    await _pumpUntil(
      tester,
      () => find.text('这台电脑暂时不能在应用内预览').evaluate().isNotEmpty,
    );

    expect(find.text('这台电脑暂时不能在应用内预览'), findsOneWidget);
    expect(find.text('用浏览器打开'), findsWidgets);
    expect(find.text('复制文件路径'), findsOneWidget,
        reason: '降级面必须给出浏览器/路径两条可执行出路');
    expect(find.text('这个应用的内容读不出来'), findsOneWidget,
        reason: '原始读失败仍以人话告知');
  });

  testWidgets('390px 手机与桌面宽度都不溢出（含进度横幅与切换入口）',
      (tester) async {
    _setPhone(tester);
    final lib = _AgentLibrary(root: Directory('${temp.path}/hotapps'));
    lib.put(
      _app('long-name-app', title: '一个名字很长的热应用', brief: '一句话需求描述也比较长'),
      _html('marker'),
    );
    final appStore = store();
    appStore.setHotApp('long-name-app');

    await tester.pumpWidget(_host(appStore, service(lib)));
    await _pumpUntil(tester, () => fake.lastController != null);

    // 生成中（横幅 + 转圈）也不能把 390 宽顶栏/正文撑爆。
    appStore.agentBusy = true;
    appStore.timeline.add(
      TimelineEntry(kind: 'tool', tool: 'hotapp_generate', running: true),
    );
    // ignore: invalid_use_of_protected_member
    appStore.notifyListeners();
    await tester.pump();
    expect(tester.takeException(), isNull, reason: '390px 宽度下不得有溢出异常');

    // 收掉生成态（生成中切换入口按纪律禁点），再验桌面宽度。
    appStore.timeline.last.running = false;
    appStore.debugForceIdle();
    await tester.pump();

    // 桌面宽度：更多文字按钮出现，打开应用切换列表同样不溢出。
    tester.view.physicalSize = const Size(1280, 900);
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('应用'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull);
    expect(find.text('热应用'), findsWidgets, reason: '切换入口在桌面宽度可用');
  });
}
