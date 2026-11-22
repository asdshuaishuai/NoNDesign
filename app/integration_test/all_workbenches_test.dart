/// 全工作台串行冒烟（macOS 真实应用进程）。
///
/// 用户要求：每个工作台都跑一遍、串行。这里按真实产品路径走：
///
///   设计（本地引擎建模板项目 + 画布）
///     → 3D（磁盘项目 + 真实 WebView 预览）
///     → 视频（内置代码动画示例 + 播放）
///     → 热应用（安装最小 .nonapp + 真实 WebView）
///     → 作品集
///     → 回到设计
///
/// 所有项目/缓存都落在临时目录（`AppPaths.*Override` + SharedPreferences
/// mock），绝不碰真实 `~/Documents/NoNDesign`。3D 与热应用使用真实服务与
/// 真实 WebView，只有模型调用用确定性假 LLM（3D 建项目阶段）。
///
/// 运行：flutter test integration_test/all_workbenches_test.dart -d macos
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_all/webview_all.dart' show WebViewWidget;

import 'package:nondesign/core/app_paths.dart';
import 'package:nondesign/core/nonapp_library.dart';
import 'package:nondesign/core/nonapp_package.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/three_service.dart';
import 'package:nondesign/core/video_samples.dart';
import 'package:nondesign/main.dart';
import 'package:nondesign/plugins/registry.dart';
import 'package:nondesign/widgets/canvas_view.dart';
import 'package:nondesign/widgets/hotapp_workspace.dart';
import 'package:nondesign/widgets/portfolio_view.dart';
import 'package:nondesign/widgets/three_workspace.dart';
import 'package:nondesign/widgets/video_workspace.dart';

const Map<String, dynamic> _threeSpec = <String, dynamic>{
  'title': 'E2E Saturn',
  'summary': '带环行星自转',
  'components': <Map<String, dynamic>>[
    <String, dynamic>{'id': 'planet', 'what': '球体'},
  ],
  'acceptance': <String>['行星在场'],
};

const String _hotappHtml = '<!doctype html><html><head><meta charset="utf-8">'
    '<title>E2E 热应用</title>'
    '<style>html,body{margin:0;height:100%;background:#101820;color:#f4f7fb;'
    'font:16px system-ui;display:grid;place-items:center}'
    '#marker{padding:24px;border:1px solid #35506b;border-radius:12px}</style>'
    '</head><body><div id="marker"><h1>E2E hotapp</h1>'
    '<p>全工作台串行冒烟：热应用的真实 WebView 预览面。</p></div></body></html>';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('serial walkthrough: design -> 3D -> video -> hotapp -> portfolio', (tester) async {
    final temp = Directory.systemTemp.createTempSync('nondesign_e2e_');
    final projectsRoot = Directory('${temp.path}/NoNDesign');
    final dataRoot = Directory('${temp.path}/.nondesign');
    AppPaths.projectsRootOverride = projectsRoot;
    AppPaths.rootOverride = dataRoot;
    AppPaths.documentsDirectoryOverride = Directory('${temp.path}/Documents');
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      AppPaths.projectsRootOverride = null;
      AppPaths.rootOverride = null;
      AppPaths.documentsDirectoryOverride = null;
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });

    final store = AppStore();
    await store.boot();
    expect(store.engine?.isReady, isTrue, reason: store.engine?.startupError ?? 'engine not ready');
    expect(store.engine?.runtime?.runtime, 'webview',
        reason: 'production path must be the offscreen WebView engine');
    addTearDown(store.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppStore>.value(value: store, child: const NonApp()),
    );
    await tester.pump(const Duration(milliseconds: 500));

    // ---- 1. 设计：真实引擎建模板项目 + 画布 ----
    debugPrint('[e2e] design: creating template project');
    final created = await store.newProject(name: 'e2e-design', templateId: 'login');
    expect(created, isTrue, reason: 'newProject failed');
    await tester.pump(const Duration(milliseconds: 600));
    expect(store.hasProject, isTrue);
    expect(store.render.artboards, isNotEmpty, reason: 'template project has no artboards');
    expect(find.byType(CanvasView), findsOneWidget);
    debugPrint('[e2e] design ok: ${store.render.artboards.length} artboards');

    // ---- 2. 3D：磁盘项目 + 真实 WebView 预览 ----
    debugPrint('[e2e] three: seeding project');
    final threeRoot = Directory('${projectsRoot.path}/3d');
    final seeder = ThreeService(
      root: threeRoot,
      llm: (request) async => '```json\n${jsonEncode(_threeSpec)}\n```',
    );
    await seeder.newProject(
      name: 'e2e-three',
      brief: '带环行星自转',
      config: const ThreeLlmConfig(
        model: 'e2e-model',
        baseUrl: 'https://example.invalid/v1',
        apiKey: 'test-key',
      ),
    );
    store.setThreeProjectName('e2e-three');
    store.setView('plugin:three');
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(ThreeWorkspace), findsOneWidget);
    await _pumpUntil(
      tester,
      () => find.byKey(const ValueKey('three-header-landscape')).evaluate().isNotEmpty,
      timeout: const Duration(seconds: 20),
      label: '3D workspace header',
    );
    await _pumpUntil(
      tester,
      () => find.byType(WebViewWidget).evaluate().isNotEmpty,
      timeout: const Duration(seconds: 30),
      label: '3D preview WebView',
    );
    expect(find.byKey(const ValueKey('three-service-unavailable')), findsNothing);
    expect(find.byKey(const ValueKey('three-preview-unsupported')), findsNothing);
    debugPrint('[e2e] three ok: preview WebView mounted');

    // ---- 3. 视频：内置代码动画示例 + 播放 ----
    debugPrint('[e2e] video: opening sample');
    store.setView('plugin:video');
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.byType(VideoWorkspace), findsOneWidget);
    await _pumpUntil(
      tester,
      () => find.byKey(const ValueKey('video-animation-surface')).evaluate().isNotEmpty,
      timeout: const Duration(seconds: 20),
      label: 'video animation surface',
    );
    expect(find.byKey(const ValueKey('video-sample-picker')), findsOneWidget);
    expect(find.text(videoSamples.first.label), findsWidgets);
    final play = find.byKey(const ValueKey('video-animation-play'));
    expect(play, findsOneWidget);
    await tester.tap(play);
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.takeException(), isNull);
    debugPrint('[e2e] video ok: sample="${videoSamples.first.label}"');

    // ---- 4. 热应用：安装最小 .nonapp + 真实 WebView ----
    debugPrint('[e2e] hotapp: installing package');
    final library = await NonAppLibrary.open();
    final pkg = NonAppPackage.parse(_zip(<String, Object>{
      'manifest.json': jsonEncode(<String, Object>{
        'formatVersion': 1,
        'id': 'e2e-hotapp',
        'name': 'e2e-hotapp',
        'title': 'E2E 热应用',
        'renderer': 'html',
        'createdAt': 1700000000,
        'minAppVersion': '0.1.0',
        'brief': '全工作台串行测试',
      }),
      'payload/index.html': _hotappHtml,
    }));
    await library.install(pkg);
    store.setHotApp('e2e-hotapp');
    store.setView('plugin:hotapp');
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.byType(HotAppWorkspace), findsOneWidget);
    await _pumpUntil(
      tester,
      () => find.textContaining('e2e-hotapp').evaluate().isNotEmpty,
      timeout: const Duration(seconds: 20),
      label: 'hotapp title',
    );
    await _pumpUntil(
      tester,
      () => find.byType(WebViewWidget).evaluate().isNotEmpty,
      timeout: const Duration(seconds: 30),
      label: 'hotapp preview WebView',
    );
    expect(find.byKey(const ValueKey('hotapp-origin-badge-app')), findsOneWidget);
    debugPrint('[e2e] hotapp ok: preview WebView mounted');

    // ---- 5. 作品集 ----
    debugPrint('[e2e] portfolio: opening');
    store.setView('portfolio');
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.byType(PortfolioView), findsOneWidget);
    debugPrint('[e2e] portfolio ok');

    // ---- 6. 回到设计：壳与项目仍在 ----
    store.setView('design');
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(CanvasView), findsOneWidget);
    expect(store.projectName, 'e2e-design');
    expect(store.render.artboards, isNotEmpty);

    // 音乐工作台尚未施工（方案定稿），没有可路由的插件——如实登记而不是
    // 假装测过。
    expect(pluginById('music'), isNull);
    debugPrint('[e2e] all implemented workbenches passed; music is plan-only');
  }, timeout: const Timeout(Duration(minutes: 8)));
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() predicate, {
  required Duration timeout,
  required String label,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (predicate()) return;
    await tester.pump(const Duration(milliseconds: 100));
  }
  fail('timed out waiting for $label');
}

List<int> _zip(Map<String, Object> entries) {
  final archive = Archive();
  for (final entry in entries.entries) {
    final bytes = entry.value is String ? utf8.encode(entry.value as String) : entry.value as List<int>;
    archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
  }
  return ZipEncoder().encode(archive);
}
