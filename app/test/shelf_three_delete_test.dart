// 3D 工作台 res-1 / res-2 回归（批次 06：全本地数据面）。
//
// res-1 删除入口：对话框项目行带删除按钮——二次确认 → 删本地项目目录 →
//   删的是当前项目则整体回空态。艺术架上的「删除 3D 项目…」必须同一清理语义
//   （持久化项目名 + 规范草稿一起清），否则下次进工作台会续接一个盘上已不
//   存在的项目、回灌幽灵草稿。
//
// res-2 截图/四方位门：旧判据只有 `_project != null`——预览失败（_loadError）
//   或 controller 未挂载时按钮仍可点，点了是带 ?. 守卫的静默 no-op。新判据 =
//   预览页就绪（预览页 300ms 后主动上报的 metrics 桥；**不用 onPageFinished**：
//   webview_flutter 平台基类 setOnPageFinished 直接 throw UnimplementedError，
//   NavigationDelegate 构造器会同步调用它）。两条 UI 路径都断言：landscape 的
//   _TopBtn 与 portrait 的 PopupMenuItem。
//
// 数据面从 HTTP（/three/projects、/three/delete）迁到本机目录后，夹具改为
// 临时根目录 + 注入 `ThreeService`（three_workspace_test 同法）。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
// 平台类不经 webview_flutter 主库 re-export——桩直接从平台接口库取。
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import 'package:nondesign/core/capability_hub.dart';
import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/nonapp_library.dart';
import 'package:nondesign/core/platform_capabilities.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/core/three_service.dart';
import 'package:nondesign/core/toast_service.dart';
import 'package:nondesign/widgets/art_shelf_card.dart';
import 'package:nondesign/widgets/portfolio_view.dart';
import 'package:nondesign/widgets/three_workspace.dart';

const Map<String, dynamic> _spec = <String, dynamic>{
  'title': 'Saturn',
  'summary': '带环行星',
  'components': <Map<String, dynamic>>[
    <String, dynamic>{'id': 'planet', 'what': '球体'},
  ],
  'acceptance': <String>['行星在场'],
};

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
  throw ThreeFailure('asset_missing', key);
}

String _fence(String lang, String body) => '```$lang\n$body\n```';

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
  final root = Directory.systemTemp.createTempSync('shelf_three_delete');
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

AppStore _store() {
  final store = AppStore(
    toasts: ToastService(autoDismiss: false),
    // flutter_test 默认 platform 是 android（移动端会关掉内嵌预览）——显式钉桌面。
    capabilities: CapabilityHub(platform: PlatformCapabilities.forOs(HostOs.macos)),
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

// ---- WebView 平台桩（与 three_workspace_test 同法）----

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

/// 预热一帧（确保 initState 的注册只发生一次）→ 装 fake → threeLoadOnOpen
/// 直载 saturn-demo 重建工作台 → postFrame 的 _boot/_refresh/_mountPreview 跑完。
Future<_FakeWebViewPlatform> _pumpProject(
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
  return fake;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 25; i++) {
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
  }
  await tester.pump(const Duration(milliseconds: 120));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() {
    debugThreeWebViewSupported = null;
    threeLoadOnOpen = null;
  });

  testWidgets('res-1：项目对话框带删除入口，确认后删本地项目并清空当前项目', (tester) async {
    final fixture = await _seedProject();
    final store = _store();
    await _pumpProject(tester, store, fixture.service);

    await tester.tap(find.text('项目'));
    await tester.pumpAndSettle();
    expect(find.text('3D 项目'), findsOneWidget);
    expect(find.text('saturn-demo（占位）'), findsOneWidget);

    await tester.tap(find.byTooltip('删除项目'));
    await tester.pumpAndSettle();
    expect(find.text('删除 3D 项目？'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(Directory(fixture.projectDir).existsSync(), isFalse, reason: '真删项目目录');
    // 删的是当前项目：工作台回空态、持久化项目名清空。
    expect(find.text('直接制作 3D'), findsOneWidget);
    expect(store.settings.threeProjectName, isEmpty);
  });

  testWidgets('shelf-2：艺术架删除 3D 项目同步清工作台持久化（项目名 + 规范草稿）', (tester) async {
    final fixture = await _seedProject();
    final store = _store()..settings.threeProjectName = 'saturn-demo';
    store.setThreeSpecDraft('saturn-demo', '{"stale":true}');

    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(
        theme: AppTheme.build(dark: true),
        home: Scaffold(
          body: PortfolioView(
            library: NonAppLibrary(root: Directory('${fixture.root.path}/empty-hotapps')),
            threeService: fixture.service,
            videoRoot: Directory('${fixture.root.path}/empty-videos'),
          ),
        ),
      ),
    ));
    await _settle(tester);

    final card = find.ancestor(of: find.text('saturn-demo'), matching: find.byType(ArtShelfCard));
    expect(card, findsOneWidget);
    await tester.tap(find.descendant(of: card, matching: find.byTooltip('更多操作')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除 3D 项目…'));
    await tester.pumpAndSettle();
    expect(find.text('删除这个 3D 场景？'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    // 删除后货架会重新扫描本地目录（dart:io）：此处不能 pumpAndSettle——
    // 扫描期间 `_busy` 的 CircularProgressIndicator 是无限动画，假时钟下
    // 真实 IO 又推不动，settle 必然超时。用 pump + runAsync 交替推进。
    await tester.pump(const Duration(milliseconds: 60));
    await _settle(tester);

    expect(Directory(fixture.projectDir).existsSync(), isFalse);
    // 两条删除入口（工作台对话框 / 艺术架菜单）必须同一清理语义：否则下次
    // 进工作台会续接一个盘上已不存在的项目，并回灌幽灵规范草稿。
    expect(store.settings.threeProjectName, isEmpty);
    expect(store.threeSpecDraft('saturn-demo'), isNull);
  });

  testWidgets('res-2 landscape：metrics 未到前「截图」点不动，到达后可点并真发 JS', (tester) async {
    final fixture = await _seedProject();
    final fake = await _pumpProject(tester, _store(), fixture.service);
    final ctl = fake.lastController!;

    // 未就绪：按钮禁用（onTap null），点击不产生 JS 调用。
    await tester.tap(find.text('截图'));
    await tester.pump(const Duration(milliseconds: 30));
    expect(ctl.jsCalls, 0);

    // 新导航开始 + 一条 metrics 之外的消息：仍未就绪。
    ctl.navDelegate!.firePageStarted('file://${fixture.projectDir}/preview.html');
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

    // 主帧失败（didFail Navigation）：错误占位替换预览 → 截图再次禁用。
    ctl.navDelegate!.fireResourceError(mainFrame: true);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('截图'));
    await tester.pump(const Duration(milliseconds: 30));
    expect(ctl.jsCalls, 1, reason: '预览失败后截图必须立刻失效');
    expect(find.textContaining('预览加载失败'), findsOneWidget);
  });

  testWidgets('res-2 手机竖屏：PopupMenu 的截图/四方位项共用同一就绪判据', (tester) async {
    // 390×844（手机竖屏）：动作全部收进「3D 操作」菜单——这是 portrait 侧的
    // 真实路径（iPad 竖屏走双行工具栏、没有菜单，别拿它当 portrait 锚）。
    final fixture = await _seedProject();
    final fake = await _pumpProject(tester, _store(), fixture.service, size: const Size(390, 844));
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
