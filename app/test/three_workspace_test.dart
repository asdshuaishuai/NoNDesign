// 3D 工作台（批次 06：全本地）的界面契约测试。
//
// 覆盖四组：
//  1. 本地文件加载：预览按 `loadFile(<项目>/preview.html)` 加载，宿主页、场景
//     代码、渲染库三件套同目录（WebKit 的读取范围就是父目录）；
//  2. 通知与错误：全部走 ToastService（不再有 ScaffoldMessenger 散点弹条），
//     原始诊断只进折叠的「技术详情」；
//  3. 平台矩阵：无 WebView 的平台不构造控制器，给可复制路径的降级面；
//  4. 生命周期：弹窗期间切走视图（死 State）不 setState、不写全局设置。
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:webview_flutter/webview_flutter.dart';
// 平台类（PlatformWebViewController/PlatformNavigationDelegate/PlatformWebViewWidget）
// 不经 webview_flutter 主库 re-export——桩直接从平台接口库取（测试专用传递依赖）。
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import 'package:nondesign/core/capability_hub.dart';
import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/platform_capabilities.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/core/three_service.dart';
import 'package:nondesign/core/toast_service.dart';
import 'package:nondesign/widgets/three_workspace.dart';

const Map<String, dynamic> _spec = <String, dynamic>{
  'title': 'Saturn',
  'summary': '带环行星',
  'components': <Map<String, dynamic>>[
    <String, dynamic>{'id': 'planet', 'what': '球体'},
  ],
  'acceptance': <String>['行星在场'],
};

/// NaN 在 run 里新建的第二个项目：独立规范，切项目后界面必须跟着换。
const Map<String, dynamic> _moonSpec = <String, dynamic>{
  'title': 'Moon',
  'summary': '月球地表',
  'components': <Map<String, dynamic>>[
    <String, dynamic>{'id': 'moon-surface', 'what': '球体'},
  ],
  'acceptance': <String>['月面在场'],
};

/// 第二个项目的场景代码（断言「切项目后源码/预览真的换了内容」）。
const String _moonScene = '''
export default function build(THREE, scene, camera, controls, renderer) {
  // moon-surface
  return {};
}
''';

/// run 进行中落盘的场景代码（断言「run 里推进的进度能进界面」）。
const String _runScene = '''
export default function build(THREE, scene, camera, controls, renderer) {
  // generated-during-run
  return {};
}
''';

/// 与生产模板同形：两个内联占位 + 一段宿主代码（预览页自包含）。
const String _previewTemplate = '''
<!DOCTYPE html><html><body>
<script type="module">
/*__THREE_MODULE__*/
/*__SCENE_SOURCE__*/
window.NON3D.postMessage(JSON.stringify({kind:'metrics', payload:{}}));
</script></body></html>
''';

/// 与锚点等长、且能被组装器改写成 `const THREE = {...}` 的渲染库。
final Uint8List _moduleBytes = () {
  const head = 'const REVISION = "160";\n'
      'const Scene = class Scene {};\n'
      'const Mesh = class Mesh {};\n'
      'const Vector3 = class Vector3 {};\n';
  const tail = 'export { REVISION, Scene, Mesh, Vector3 };\n';
  const overhead = 4; // /* */
  final pad = threeModuleByteLength - head.length - tail.length - overhead;
  return Uint8List.fromList(utf8.encode('$head/*${'x' * pad}*/$tail'));
}();

Future<Uint8List> _loadAsset(String key) async {
  if (key == threePreviewAssetKey) return Uint8List.fromList(utf8.encode(_previewTemplate));
  if (key == threeModuleAssetKey) return _moduleBytes;
  if (key == threeLiveAssetKey) {
    return Uint8List.fromList(utf8.encode('/* three-live vendor (fake) */'));
  }
  if (key == threeUiCatalogAssetKey) {
    return Uint8List.fromList(utf8.encode(_fakeThreeUiCatalog));
  }
  throw ThreeFailure('asset_missing', key);
}

/// 极小的 ThreeUI 清单：画廊 UI 测试只关心「解析出来 → 卡片 → 打开」。
const String _fakeThreeUiCatalog = '''
{"version":1,"components":[
{"id":"spark-badge","name":"火花徽章","description":"一枚会发光的徽章","file":"spark-badge.html","hint":"暗底"},
{"id":"gallery-heading","name":"画廊标题","description":"颗粒渐变的大标题动效","file":"gallery-heading.html","hint":"大标题"}
]}
''';

String _fence(String lang, String body) => '```$lang\n$body\n```';

/// 假模型：按队列返回；队列空时抛与生产同形的失败（llm_error）。
ThreeLlmCall _llm(List<String> replies) {
  final queue = List<String>.from(replies);
  return (request) async {
    if (queue.isEmpty) throw const ThreeFailure('llm_error', 'fake: no reply left');
    return queue.removeAt(0);
  };
}

const ThreeLlmConfig _config =
    ThreeLlmConfig(model: 'test-model', baseUrl: 'https://api.example.com/v1', apiKey: 'k');

class _Fixture {
  _Fixture(this.root, this.service);

  final Directory root;
  final ThreeService service;

  String get projectDir => '${root.path}/saturn-demo';
}

/// 每个测试一个独立根目录：预置一个可续接的项目（规范 + 初始进度）。
Future<_Fixture> _seedProject({String name = 'saturn-demo'}) async {
  final root = Directory.systemTemp.createTempSync('three_workspace_test');
  addTearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });
  final creator = ThreeService(
    root: root,
    llm: _llm(<String>[_fence('json', jsonEncode(_spec))]),
    assets: _loadAsset,
  );
  await creator.newProject(name: name, brief: '带环行星自转', config: _config);
  return _Fixture(root, ThreeService(root: root, llm: _llm(<String>[]), assets: _loadAsset));
}

/// 在同一个根目录里再造一个「已生成第一层」的项目：模拟 NaN 的
/// `three_create` → `three_pass` 在本机磁盘上留下的第二个项目。
Future<void> _seedSecondProject(_Fixture fixture, {String name = 'moon-scene'}) async {
  final creator = ThreeService(
    root: fixture.root,
    llm: _llm(<String>[_fence('json', jsonEncode(_moonSpec))]),
    assets: _loadAsset,
  );
  await creator.newProject(name: name, brief: '月球地表', config: _config);
  final runner = ThreeService(
    root: fixture.root,
    llm: _llm(<String>[_fence('js', _moonScene)]),
    assets: _loadAsset,
  );
  await runner.runPass(name, _config);
}

AppStore _store({HostOs os = HostOs.macos}) {
  // 测试宿主默认钉在 macOS 桌面：flutter_test 默认把 defaultTargetPlatform
  // 当成 android，会把内嵌预览与文件管理器都关掉。Windows 分支测试显式传
  // HostOs.windows。
  final store = AppStore(
    toasts: ToastService(autoDismiss: false),
    capabilities: CapabilityHub(platform: PlatformCapabilities.forOs(os)),
  )
    ..ready = true
    ..view = 'plugin:three'
    ..settings = AppSettings(
      providerId: 'deepseek',
      modelId: 'deepseek-v4.1-flash',
      baseUrl: 'https://api.example.com/v1',
      apiKey: 'test-key',
    );
  return store;
}

/// 镜像 workspace.dart 的插件视图路由：watch store → view 变化即重建/dispose。
/// gen 变化时强制重建工作台（const 三连会被 pumpWidget 当同一配置短路，
/// initState 不会重跑——_pumpProject 的第二次 pump 必须靠换 key 触发）。
Widget _host(AppStore store, ThreeService service, {int gen = 0}) =>
    ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(
        theme: AppTheme.build(dark: true),
        home: Consumer<AppStore>(
          builder: (context, s, _) => s.view == 'plugin:three'
              ? Scaffold(
                  body: KeyedSubtree(
                    key: ValueKey('three-ws-$gen'),
                    child: ThreeWorkspace(service: service),
                  ),
                )
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
  await tester.pump(const Duration(milliseconds: 50));
}

// ---- WebView 平台桩：记录 loadFile 的绝对路径与桥消息 ----

class _FakeWebViewPlatform extends WebViewPlatform {
  _FakePlatformController? lastController;

  void install() {
    WebViewPlatform.instance = this;
  }

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
  final List<String> loadedFiles = <String>[];
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
  Future<void> loadFile(String absoluteFilePath) async {
    loadedFiles.add(absoluteFilePath);
  }

  @override
  Future<void> runJavaScript(String javaScript) async {
    jsCalls++;
  }

  /// 模拟预览页的桥消息（NON3D 通道 → _onBridgeMessage）。
  void fireJsMessage(String text) {
    (channelParams as dynamic).onMessageReceived(JavaScriptMessage(message: text));
  }
}

class _FakeNavigationDelegate extends PlatformNavigationDelegate {
  _FakeNavigationDelegate(super.params) : super.implementation();

  void Function(WebResourceError)? onWebResourceError;
  void Function(String)? onPageStarted;

  @override
  Future<void> setOnPageStarted(PageEventCallback cb) async => onPageStarted = cb;

  @override
  Future<void> setOnWebResourceError(WebResourceErrorCallback cb) async =>
      onWebResourceError = cb;

  /// 模拟 didFail(Navigation)：主帧/子资源两类。
  void fireResourceError({required bool mainFrame}) => onWebResourceError?.call(
        WebResourceError(
          errorCode: mainFrame ? -1009 : -100,
          description: mainFrame ? 'offline' : 'subresource',
          isForMainFrame: mainFrame,
        ),
      );

  void firePageStarted(String url) => onPageStarted?.call(url);
}

class _FakeWebViewWidget extends PlatformWebViewWidget {
  _FakeWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

class _Pumped {
  _Pumped(this.fake);

  final _FakeWebViewPlatform fake;

  _FakePlatformController get controller => fake.lastController!;
}

/// 预热一帧（确保 initState 的注册只发生一次）→ 装 fake → threeLoadOnOpen
/// 直载 saturn-demo 重建工作台 → postFrame 的 _boot/_refresh/_mountPreview 跑完。
Future<_Pumped> _pumpProject(
  WidgetTester tester,
  AppStore store,
  ThreeService service, {
  Size size = const Size(1440, 900),
  String project = 'saturn-demo',
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(_host(store, service, gen: 0));
  await tester.pump(const Duration(milliseconds: 50));

  final fake = _FakeWebViewPlatform()..install();
  addTearDown(() => WebViewPlatform.instance = WebKitWebViewPlatform());
  addTearDown(() => threeLoadOnOpen = null);

  threeLoadOnOpen = project;
  await tester.pumpWidget(_host(store, service, gen: 1));
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 50));
  return _Pumped(fake);
}

void main() {
  tearDown(() {
    debugThreeWebViewSupported = null;
    threeLoadOnOpen = null;
  });

  // ---- 本地文件加载 ----

  testWidgets('预览按文件加载：preview.html / scene.js / three.module.js 同目录', (tester) async {
    final fixture = await _seedProject();
    final store = _store();
    final pumped = await _pumpProject(tester, store, fixture.service);

    final controller = pumped.fake.lastController;
    expect(controller, isNotNull, reason: '有 WebView 的平台必须挂控制器');
    expect(controller!.loadedFiles, hasLength(1));
    final htmlPath = controller.loadedFiles.single;
    expect(htmlPath, endsWith('/saturn-demo/preview.html'));

    final dir = File(htmlPath).parent;
    expect(File(htmlPath).existsSync(), isTrue);
    expect(File('${dir.path}/scene.js').existsSync(), isTrue, reason: '三件套必须同目录');
    expect(File('${dir.path}/three.module.js').existsSync(), isTrue, reason: '三件套必须同目录');
    expect(File('${dir.path}/three.module.js').lengthSync(), threeModuleByteLength);

    expect(find.byType(WebViewWidget), findsOneWidget);
    expect(find.text('占位'), findsOneWidget, reason: '进度条显示当前层');
    expect(find.byType(SnackBar), findsNothing, reason: '通知不再走 ScaffoldMessenger');
  });

  testWidgets('截图/四方位：metrics 未到前禁用，到达后可点并真发 JS', (tester) async {
    final fixture = await _seedProject();
    final store = _store();
    final pumped = await _pumpProject(tester, store, fixture.service);
    final controller = pumped.controller;

    await tester.tap(find.text('截图'));
    await tester.pump(const Duration(milliseconds: 30));
    expect(controller.jsCalls, 0, reason: '未就绪不得在预览页里跑脚本');

    // 非 metrics 的桥消息不点亮就绪态。
    controller.fireJsMessage(jsonEncode(<String, dynamic>{'kind': 'unknown-kind'}));
    await tester.pump(const Duration(milliseconds: 30));
    await tester.tap(find.text('截图'));
    await tester.pump(const Duration(milliseconds: 30));
    expect(controller.jsCalls, 0);

    controller.fireJsMessage(
        jsonEncode(<String, dynamic>{'kind': 'metrics', 'payload': <String, dynamic>{}}));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('截图'));
    await tester.pump(const Duration(milliseconds: 30));
    expect(controller.jsCalls, 1);

    await tester.tap(find.text('四方位取证'));
    await tester.pump(const Duration(milliseconds: 30));
    expect(controller.jsCalls, 2);
  });

  testWidgets('预览主帧失败：整块换成可重试的占位，截图立刻失效，详情默认折叠', (tester) async {
    final fixture = await _seedProject();
    final store = _store();
    final pumped = await _pumpProject(tester, store, fixture.service);
    final controller = pumped.controller;

    controller.fireJsMessage(
        jsonEncode(<String, dynamic>{'kind': 'metrics', 'payload': <String, dynamic>{}}));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('截图'));
    await tester.pump(const Duration(milliseconds: 30));
    expect(controller.jsCalls, 1);

    controller.navDelegate!.fireResourceError(mainFrame: true);
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('预览加载失败，请重试'), findsOneWidget);
    expect(find.text('重试加载'), findsOneWidget);
    await tester.tap(find.text('截图'));
    await tester.pump(const Duration(milliseconds: 30));
    expect(controller.jsCalls, 1, reason: '预览失败后截图必须立刻失效');

    // 技术详情默认折叠：正文不可见，点开才出现原始诊断。
    expect(find.text('技术详情'), findsOneWidget);
    expect(find.textContaining('offline'), findsNothing);
    await tester.tap(find.text('技术详情'));
    await tester.pumpAndSettle();
    expect(find.textContaining('offline'), findsWidgets);

    // 重试：重新准备并加载同一份宿主页（新建控制器，旧的被替换）。
    final previous = controller;
    await tester.tap(find.text('重试加载'));
    await tester.pump(const Duration(milliseconds: 80));
    final reloaded = pumped.fake.lastController!;
    expect(identical(reloaded, previous), isFalse);
    expect(reloaded.loadedFiles.single, endsWith('/saturn-demo/preview.html'));
    expect(find.text('重试加载'), findsNothing);
  });

  testWidgets('子资源错误不清占位，新导航开始清旧占位', (tester) async {
    final fixture = await _seedProject();
    final store = _store();
    final pumped = await _pumpProject(tester, store, fixture.service);
    final nav = pumped.controller.navDelegate!;

    nav.fireResourceError(mainFrame: false);
    await tester.pump(const Duration(milliseconds: 30));
    expect(find.text('预览加载失败，请重试'), findsNothing);

    nav.fireResourceError(mainFrame: true);
    await tester.pump(const Duration(milliseconds: 30));
    expect(find.text('预览加载失败，请重试'), findsOneWidget);

    nav.firePageStarted('file:///tmp/preview.html');
    await tester.pump(const Duration(milliseconds: 30));
    expect(find.text('预览加载失败，请重试'), findsNothing);
  });

  // ---- 失败呈现：人话 + 折叠详情 + ToastService ----

  testWidgets('项目不存在：错误横幅说人话，原始诊断折叠，通知走 ToastService', (tester) async {
    final fixture = await _seedProject();
    final store = _store();
    final pumped = await _pumpProject(tester, store, fixture.service, project: 'ghost-scene');

    expect(find.byKey(const ValueKey('three-refresh-error')), findsOneWidget);
    expect(find.text('没有找到这个 3D 项目'), findsWidgets);
    expect(find.byType(SnackBar), findsNothing);

    // 状态类失败用常驻横幅表达（不叠通知：同一件事说两遍）。
    expect(store.toasts.history, isEmpty, reason: '读不到项目是状态，不是事件');

    // 技术详情折叠：默认看不到原始诊断。
    expect(find.byKey(const ValueKey('three-tech-details-body')), findsNothing);
    await tester.tap(find.text('技术详情').first);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('three-tech-details-body')), findsOneWidget);
    // 预览控制器没有挂上（项目不存在）。
    expect(pumped.fake.lastController, isNull);
  });

  testWidgets('生成失败（模型不可用）：横幅 + 通知，不写半截场景', (tester) async {
    final fixture = await _seedProject();
    final store = _store();
    final pumped = await _pumpProject(tester, store, fixture.service);

    await tester.tap(find.text('生成当前层'));
    await tester.pump(const Duration(milliseconds: 80));

    // 注入的假模型没有回复 → llm_error → 人话横幅 + 一条通知。
    expect(find.byKey(const ValueKey('three-refresh-error')), findsOneWidget);
    expect(find.text('模型这次没有响应，请稍后重试'), findsWidgets);
    expect(store.toasts.history.first.title, '模型这次没有响应，请稍后重试');
    // 预览准备时落的是骨架场景；失败的那一轮没有写进任何生成的代码。
    final scene = File('${fixture.projectDir}/scene.js');
    expect(scene.existsSync(), isTrue);
    expect(scene.readAsStringSync(), contains('GridHelper'));
    expect(scene.readAsStringSync(), isNot(contains('planet')));
    // 预览控制器仍在（生成失败不影响已挂载的预览）。
    expect(pumped.fake.lastController, isNotNull);
  });

  // ---- 平台矩阵 ----

  testWidgets('Windows：预览走 WebView2 面；初始化失败给浏览器兜底', (tester) async {
    // 测试进程没有 WebView2 原生实现：用平台通道桩模拟「系统缺运行时」，
    // 让 initialize 快速失败（无桩时通道调用在 widget 测试里永远挂起）。
    const channel = MethodChannel('io.jns.webview.win');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'initialize') {
        throw PlatformException(code: 'webview2_unavailable', message: 'missing runtime');
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final fixture = await _seedProject();
    final store = _store(os: HostOs.windows);
    addTearDown(() => threeLoadOnOpen = null);

    await _pumpAt(tester, _host(store, fixture.service), const Size(1440, 900));
    threeLoadOnOpen = 'saturn-demo';
    await tester.pumpWidget(_host(store, fixture.service, gen: 1));
    // 预览面挂载是异步的（写宿主页 → 建 WebView2 → 初始化失败上报），
    // 多泵几帧让这条链走完。
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    // 初始化失败必须落 Windows 专属兜底面（浏览器打开 / 文件夹 / 重试），
    // 既不能退回「这台设备不能内嵌显示」的终态，也不能误构造 webview_flutter
    // 控制器。
    expect(find.byType(WebViewWidget), findsNothing);
    expect(find.text('这台设备不能内嵌显示 3D 预览'), findsNothing);
    expect(find.text('这台电脑暂时不能内嵌显示 3D 预览'), findsOneWidget);
    expect(find.text('用浏览器打开'), findsOneWidget);
    expect(find.text('在文件夹中显示'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.byKey(const ValueKey('three-preview-unsupported')), findsOneWidget);

    // 缺 WebView2 的原始诊断不静默丢弃：一句人话在上，原始原因折叠在
    // 「技术详情」里（能力缺失不得静默）。
    expect(find.text('技术详情'), findsOneWidget);
    expect(find.byKey(const ValueKey('three-preview-unsupported-detail')), findsNothing);
    await tester.tap(find.text('技术详情'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('three-preview-unsupported-detail')), findsOneWidget);
    expect(find.textContaining('webview2_unavailable'), findsWidgets);
  });

  testWidgets('没有 WebView 的平台：不构造控制器，给可复制路径的降级面', (tester) async {
    debugThreeWebViewSupported = false;
    addTearDown(() => debugThreeWebViewSupported = null);
    final fixture = await _seedProject();
    final store = _store();
    final fake = _FakeWebViewPlatform()..install();
    addTearDown(() => WebViewPlatform.instance = WebKitWebViewPlatform());
    addTearDown(() => threeLoadOnOpen = null);

    await _pumpAt(tester, _host(store, fixture.service), const Size(1440, 900));
    threeLoadOnOpen = 'saturn-demo';
    await tester.pumpWidget(_host(store, fixture.service, gen: 1));
    await tester.pump(const Duration(milliseconds: 120));

    expect(fake.lastController, isNull, reason: '不支持平台绝不构造 WebViewController');
    expect(find.byType(WebViewWidget), findsNothing);
    expect(find.text('准备预览…'), findsNothing, reason: '不能把加载态当终态');
    expect(find.byKey(const ValueKey('three-preview-unsupported')), findsOneWidget);
    expect(find.text('这台设备不能内嵌显示 3D 预览'), findsOneWidget);
    expect(find.text('复制项目路径'), findsOneWidget);
    expect(find.text('复制预览文件路径'), findsOneWidget);
    expect(find.text('在文件夹中显示'), findsOneWidget, reason: '桌面三平台有文件管理器');
    final pathText = tester.widget<SelectableText>(
      find.byKey(const ValueKey('three-preview-path')),
    );
    expect('${pathText.data}', contains('saturn-demo'));

    // 用户可见文案里不得出现实现名。
    final visible = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .join(' ');
    for (final word in <String>['服务器', '桌面服务', 'WebView', 'blockout', 'localhost', '端口', 'scene.js']) {
      expect(visible.contains(word), isFalse, reason: '降级面出现了内部用词：$word');
    }
  });

  testWidgets('存储目录不可用：整块退化提示，不静默空着', (tester) async {
    // root 指向一个文件（不是目录）→ 工作台必须显性退化。
    final container = Directory.systemTemp.createTempSync('three_workspace_bad_root');
    addTearDown(() {
      if (container.existsSync()) container.deleteSync(recursive: true);
    });
    final bogus = File('${container.path}/not-a-dir')..writeAsStringSync('x');
    final failing = ThreeService(root: Directory(bogus.path), assets: _loadAsset);
    final store = _store();

    await _pumpAt(tester, _host(store, failing), const Size(1200, 800));

    expect(find.byKey(const ValueKey('three-service-unavailable')), findsOneWidget);
    expect(find.text('3D 项目的存储目录打不开'), findsOneWidget);
    expect(find.text('技术详情'), findsOneWidget);
  });

  // ---- 生命周期 ----

  testWidgets('pickProject：弹窗期间切走视图后选项目不复活死 State', (tester) async {
    final fixture = await _seedProject();
    final store = _store();
    await _pumpAt(tester, _host(store, fixture.service), const Size(1440, 900));

    await tester.tap(find.text('项目'));
    await tester.pumpAndSettle();
    expect(find.text('3D 项目'), findsOneWidget);
    expect(find.text('saturn-demo（占位）'), findsOneWidget);

    // 对话框在场时切走视图（⌘1 的等价动作）：ThreeWorkspace 被 dispose。
    store.setView('design');
    await tester.pumpAndSettle();
    expect(store.view, 'design');

    // 在仍开着的弹窗里选项目 → await 之后的续体在死 State 上跑。
    await tester.tap(find.text('saturn-demo（占位）'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.takeException(), isNull);
    // 死工作台不得推进项目切换/写全局设置。
    expect(store.settings.threeProjectName, isEmpty);
  });

  testWidgets('createProject：弹窗期间切走视图后确认新建不触发 setState-after-dispose', (tester) async {
    final fixture = await _seedProject();
    final store = _store();
    await _pumpAt(tester, _host(store, fixture.service), const Size(1440, 900));

    await tester.tap(find.text('新建 3D 项目'));
    await tester.pumpAndSettle();
    expect(find.text('生成规范'), findsOneWidget);
    await tester.enterText(find.byType(TextField).at(0), 'demo');
    await tester.enterText(find.byType(TextField).at(1), '带环行星自转');

    store.setView('design');
    await tester.pumpAndSettle();

    await tester.tap(find.text('生成规范'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.takeException(), isNull);
    expect(store.settings.threeProjectName, isEmpty);
  });

  // ---- 删除（本地目录，不再有远端调用）----

  testWidgets('删除场景：确认后目录消失、当前项目回空态、持久化项目名清空', (tester) async {
    final fixture = await _seedProject();
    final store = _store();
    await _pumpProject(tester, store, fixture.service);

    await tester.tap(find.text('项目'));
    await tester.pumpAndSettle();
    expect(find.text('saturn-demo（占位）'), findsOneWidget);

    await tester.tap(find.byTooltip('删除项目'));
    await tester.pumpAndSettle();
    expect(find.text('删除 3D 项目？'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(Directory(fixture.projectDir).existsSync(), isFalse);
    expect(find.text('直接制作 3D'), findsOneWidget);
    expect(store.settings.threeProjectName, isEmpty);
  });

  // ---- NaN 生成后的工作台同步（store → 界面）----
  //
  // 用户可见问题：让 NaN 在 3D 工作台生成场景，run 结束提示「3D 工作台已
  // 更新」，但工作台里没有东西——项目列表不刷新、不切新项目、预览空白。
  // 根因是工作台只用 context.read 读一次 store，不订阅 threeProjectName /
  // agentBusy 的变化。下面三条用例分别锁死「空工作台自动打开新项目」「切
  // 项目刷新进度/预览/列表」「run 中推进 + run 结束重载」。

  testWidgets('NaN 生成后 store 项目名变化：空工作台自动打开新项目并挂载预览', (tester) async {
    final fixture = await _seedProject();
    final store = _store();
    final fake = _FakeWebViewPlatform()..install();
    addTearDown(() => WebViewPlatform.instance = WebKitWebViewPlatform());

    // 空工作台：没有持久化项目名（用户刚打开 3D 工作台就让 NaN 生成）。
    await _pumpAt(tester, _host(store, fixture.service), const Size(1440, 900));
    expect(find.text('直接制作 3D'), findsOneWidget);

    // NaN 的 three_create 成功：tool_end 走 _adoptWorkspaceArtifact，写入
    // settings.threeProjectName 并 notify。
    store.setThreeProjectName('saturn-demo');
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump(const Duration(milliseconds: 120));

    expect(find.text('saturn-demo'), findsWidgets, reason: '工作台必须切到 NaN 新建的项目');
    expect(find.text('直接制作 3D'), findsNothing);
    expect(fake.lastController, isNotNull, reason: '切完项目必须挂预览');
    expect(fake.lastController!.loadedFiles.single, endsWith('/saturn-demo/preview.html'));
    expect(find.text('占位'), findsOneWidget, reason: '层进度来自磁盘快照');
  });

  testWidgets('store 切到另一个项目：切项目、刷新列表与层状态、重载预览', (tester) async {
    final fixture = await _seedProject();
    await _seedSecondProject(fixture);
    final store = _store();
    final pumped = await _pumpProject(tester, store, fixture.service);
    final firstController = pumped.fake.lastController!;
    expect(firstController.loadedFiles.single, endsWith('/saturn-demo/preview.html'));

    // NaN 在 run 里改了当前项目 → store 项目名变化 → 工作台必须跟过去，
    // 而不是停在旧项目/旧预览上。
    store.setThreeProjectName('moon-scene');
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump(const Duration(milliseconds: 120));

    expect(find.text('moon-scene'), findsWidgets, reason: '顶栏标题必须换成新项目');
    final switched = pumped.fake.lastController!;
    expect(identical(switched, firstController), isFalse, reason: '切项目必须重挂预览控制器');
    expect(switched.loadedFiles.single, endsWith('/moon-scene/preview.html'));

    // 层状态/场景代码来自磁盘快照：源码面看到的是新项目自己的代码。
    await tester.tap(find.text('源码'));
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.textContaining('moon-surface'), findsWidgets);
    expect(find.textContaining('场景代码 · '), findsOneWidget, reason: '场景代码长度必须跟着刷新');
    expect(find.textContaining('planet'), findsNothing, reason: '不得残留旧项目的场景代码');

    // 项目列表也重扫过：弹窗里两个项目都在（NaN 新建的项目不再缺席）。
    await tester.tap(find.text('项目'));
    await tester.pumpAndSettle();
    expect(find.text('3D 项目'), findsOneWidget);
    expect(find.text('saturn-demo（占位）'), findsOneWidget);
    expect(find.text('moon-scene（占位）'), findsOneWidget);
  });

  testWidgets('run 在飞：周期刷新看到磁盘进度；run 结束：强制刷新并重载预览', (tester) async {
    final fixture = await _seedProject();
    final store = _store();
    final pumped = await _pumpProject(tester, store, fixture.service);
    final beforeRun = pumped.fake.lastController!;

    // run 起点（真实链路 _runDartLoop 会置 agentBusy 并 notify）。
    store.agentBusy = true;
    store.notifyListeners();
    await tester.pump(const Duration(milliseconds: 60));

    // run 中 NaN 的 three_pass 在磁盘上写了新场景代码（工作台还没收到终态）。
    final runner = ThreeService(
      root: fixture.root,
      llm: _llm(<String>[_fence('js', _runScene)]),
      assets: _loadAsset,
    );
    await runner.runPass('saturn-demo', _config);

    // 运行中的节流轮询（600ms 定时 + 500ms 合并窗口）把进度拉进界面。
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('源码'));
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.textContaining('generated-during-run'), findsWidgets,
        reason: 'run 进行中工作台也要看到场景代码在变（不能空白/永远转圈）');

    // run 终态：agentBusy true→false → 强制刷新 + 重载预览（最后一层不能漏）。
    store.agentBusy = false;
    store.notifyListeners();
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 150));

    final afterRun = pumped.fake.lastController!;
    expect(identical(afterRun, beforeRun), isFalse, reason: 'run 结束必须重载预览');
    expect(afterRun.loadedFiles.single, endsWith('/saturn-demo/preview.html'));
    expect(find.textContaining('generated-during-run'), findsWidgets);
  });

  testWidgets('run 中刷新不覆盖用户规范草稿；NaN 切项目后草稿按项目保留/恢复', (tester) async {
    final fixture = await _seedProject();
    await _seedSecondProject(fixture);
    final store = _store();
    final pumped = await _pumpProject(tester, store, fixture.service);

    await tester.tap(find.text('规范'));
    await tester.pump(const Duration(milliseconds: 60));
    const draft = '{"title": "user-edit", "components": [{"id": "planet", "what": "球"}]}';
    await tester.enterText(find.byType(TextField), draft);
    await tester.pump(const Duration(milliseconds: 40));

    // run 在飞 → 周期刷新读的是磁盘规范，但用户未保存的编辑不能被冲掉。
    store.agentBusy = true;
    store.notifyListeners();
    await tester.pump(const Duration(milliseconds: 700));
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, draft,
        reason: '刷新不得覆盖用户正在编辑的规范');

    // NaN 切到另一个项目：旧项目未保存的编辑先落草稿。
    store.setThreeProjectName('moon-scene');
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump(const Duration(milliseconds: 120));
    expect(store.threeSpecDraft('saturn-demo'), draft);

    store.agentBusy = false;
    store.notifyListeners();
    await tester.pump(const Duration(milliseconds: 60));

    // 切回 saturn-demo：草稿恢复，磁盘上的规范没有把用户编辑冲掉。
    store.setThreeProjectName('saturn-demo');
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump(const Duration(milliseconds: 120));
    await tester.tap(find.text('规范'));
    await tester.pump(const Duration(milliseconds: 60));
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, draft,
        reason: '切回来的项目必须恢复自己的未保存草稿');
    expect(pumped.fake.lastController!.loadedFiles.single, endsWith('/saturn-demo/preview.html'));
  });

  // ---- 规范编辑 ----

  testWidgets('规范页：非法内容给出人话提示，不覆盖磁盘上的规范', (tester) async {
    final fixture = await _seedProject();
    final store = _store();
    await _pumpProject(tester, store, fixture.service);
    final specFile = File('${fixture.projectDir}/three-spec.json');
    final before = specFile.readAsStringSync();

    await tester.tap(find.text('规范'));
    await tester.pumpAndSettle();
    expect(find.text('项目规范'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '{broken');
    await tester.tap(find.text('保存规范'));
    await tester.pump(const Duration(milliseconds: 50));

    expect(store.toasts.history.first.title, '规范格式不对');
    expect(find.byType(SnackBar), findsNothing);
    expect(specFile.readAsStringSync(), before);
  });
}
