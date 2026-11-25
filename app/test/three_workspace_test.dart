import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
// 平台接口桩直接从平台接口库取（测试专用传递依赖）。
// ignore: depend_on_referenced_packages
import 'package:webview_platform_interface/webview_platform_interface.dart';

import 'package:nondesign/core/capability_hub.dart';
import 'package:nondesign/core/creative/creative_plan.dart';
import 'package:nondesign/core/creative/creative_schema.dart';
import 'package:nondesign/core/creative/creative_spec.dart';
import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/platform_capabilities.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/core/three/three_workspace.dart';
import 'package:nondesign/core/three_service.dart';
import 'package:nondesign/core/toast_service.dart';
import 'package:nondesign/widgets/three_workspace.dart';

import 'helpers/creative_fixtures.dart';

Map<String, dynamic> _legacySpec() => <String, dynamic>{
  'title': 'Saturn',
  'summary': '带环行星自转',
  'components': <Map<String, dynamic>>[
    <String, dynamic>{'id': 'planet', 'what': '球体', 'size_scale': 1.0},
    <String, dynamic>{'id': 'ring', 'what': '扁平圆环', 'size_scale': 1.8},
  ],
  'materials': <Map<String, dynamic>>[
    <String, dynamic>{'id': 'rock', 'color_hex': '#c9a06a'},
  ],
  'acceptance': <String>['行星在场', '环可见 ≤2mm'],
};

// ---- 视口控制浮层（批次 15 第一批）的 Widget 夹具 ----------------------------
//
// 不构造真 WebView：`debugThreeWebViewSupported` 覆盖平台矩阵；fake 平台桩
// 只承接 WebViewController 的创建（记录 runJavaScript 脚本，用来断言「未就绪
// 不发命令 / 就绪后真发命令」）。项目夹具直接写旧布局三件套（与本文件 core
// 侧同一份 spec），不依赖模型调用与真实资源。

const String _viewportPreviewTemplate = '''
<!DOCTYPE html><html><body>
<script type="module">
/*__THREE_MODULE__*/
/*__SCENE_SOURCE__*/
window.NON3D.postMessage(JSON.stringify({kind:'metrics', payload:{}}));
</script></body></html>
''';

/// 与锚点等长、且能被组装器改写成 `const THREE = {...}` 的渲染库。
final Uint8List _viewportModuleBytes = () {
  const head =
      'const REVISION = "160";\n'
      'const Scene = class Scene {};\n'
      'const Mesh = class Mesh {};\n'
      'const Vector3 = class Vector3 {};\n';
  const tail = 'export { REVISION, Scene, Mesh, Vector3 };\n';
  const overhead = 4; // /* */
  final pad = threeModuleByteLength - head.length - tail.length - overhead;
  return Uint8List.fromList(utf8.encode('$head/*${'x' * pad}*/$tail'));
}();

Future<Uint8List> _viewportAsset(String key) async {
  if (key == threePreviewAssetKey) {
    return Uint8List.fromList(utf8.encode(_viewportPreviewTemplate));
  }
  if (key == threeModuleAssetKey) return _viewportModuleBytes;
  throw ThreeFailure('asset_missing', key);
}

/// 旧布局三件套夹具（工作台只读，不新建项目、不碰模型）。
void _seedPreviewProject(Directory root, String name) {
  final dir = Directory('${root.path}/$name')..createSync(recursive: true);
  File('${dir.path}/three-spec.json')
      .writeAsStringSync(jsonEncode(_legacySpec()));
  File('${dir.path}/scene.js')
      .writeAsStringSync('export default function build() { return {}; }\n');
  File('${dir.path}/build-state.json').writeAsStringSync(
    jsonEncode(<String, Object?>{
      'current': 'structure',
      'blocked': false,
      'passes': <Object?>[],
    }),
  );
}

ThreeService _previewService(Directory root) => ThreeService(
  root: root,
  llm: (request) async => throw const ThreeFailure('llm_error', 'unused'),
  assets: _viewportAsset,
);

AppStore _appStore() =>
    AppStore(
        toasts: ToastService(autoDismiss: false),
        // flutter_test 默认平台是 android（会关掉内嵌预览）——显式钉桌面。
        capabilities: CapabilityHub(
          platform: PlatformCapabilities.forOs(HostOs.macos),
        ),
      )
      ..ready = true
      ..view = 'plugin:three'
      ..settings = AppSettings(
        providerId: 'deepseek',
        modelId: 'deepseek-v4.1-flash',
        baseUrl: 'https://api.example.com/v1',
        apiKey: 'test-key',
      );

Widget _appHost(AppStore store, ThreeService service) =>
    ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(
        theme: AppTheme.build(dark: true),
        home: Scaffold(body: ThreeWorkspace(service: service)),
      ),
    );

void _setViewportSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// 真 IO（项目读盘 / 预览组装）要走 runAsync 才推得动；faked clock 下不能
/// pumpAndSettle（加载指示是无限动画）。
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
  }
  await tester.pump(const Duration(milliseconds: 120));
}

// ---- WebView 平台桩（与 shelf_three_delete_test 同形；不构造真 WebView）----

class _FakeWebViewPlatform extends WebViewPlatform {
  _FakePlatformController? lastController;

  void install() => WebViewPlatform.instance = this;

  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) => lastController = _FakePlatformController(params);

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => _FakeNavigationDelegate(params);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) => _FakeWebViewWidget(params);
}

class _FakePlatformController extends PlatformWebViewController {
  _FakePlatformController(super.params) : super.implementation();

  dynamic channelParams;
  _FakeNavigationDelegate? navDelegate;
  final List<String> jsScripts = <String>[];

  int get jsCalls => jsScripts.length;

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
  Future<void> loadFile(String absoluteFilePath) async {}

  @override
  Future<void> runJavaScript(String javaScript) async {
    jsScripts.add(javaScript);
  }

  void fireJsMessage(String text) {
    (channelParams as dynamic).onMessageReceived(
      JavaScriptMessage(message: text),
    );
  }
}

class _FakeNavigationDelegate extends PlatformNavigationDelegate {
  _FakeNavigationDelegate(super.params) : super.implementation();

  @override
  Future<void> setOnPageStarted(PageEventCallback cb) async {}

  @override
  Future<void> setOnWebResourceError(WebResourceErrorCallback cb) async {}
}

class _FakeWebViewWidget extends PlatformWebViewWidget {
  _FakeWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

void main() {
  late Directory temp;
  late ThreeWorkspaceStore store;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('nondesign-3dws-');
    store = ThreeWorkspaceStore(temp);
  });

  tearDown(() async {
    await temp.delete(recursive: true);
  });

  group('旧布局迁移', () {
    test(
      'three-spec.json/scene.js/build-state.json → spec/plan/src，旧文件保留',
      () async {
        final dir = Directory('${temp.path}/saturn')
          ..createSync(recursive: true);
        File('${dir.path}/three-spec.json')
            .writeAsStringSync(jsonEncode(_legacySpec()));
        File('${dir.path}/scene.js')
            .writeAsStringSync('export default function build() {}\n');
        File('${dir.path}/build-state.json').writeAsStringSync(
          jsonEncode(<String, Object?>{
            'current': 'structure',
            'blocked': false,
            'passes': <Object?>[],
          }),
        );

        final before = await store.list();
        expect(before, hasLength(1));
        expect(before.single.mode, ThreeAuthoringMode.legacy);
        expect(before.single.legacyCurrentPass, 'structure');

        final result = await store.migrateLegacy('saturn');
        expect(result.alreadyMigrated, isFalse);
        expect(result.wroteSpec, isTrue);
        expect(result.wrotePlan, isTrue);
        expect(result.copiedScene, isTrue);
        expect(result.planWarnings.join('\n'), contains('dims 来自'));

        // 旧文件一个都不删。
        expect(File('${dir.path}/three-spec.json').existsSync(), isTrue);
        expect(File('${dir.path}/scene.js').existsSync(), isTrue);
        expect(File('${dir.path}/build-state.json').existsSync(), isTrue);
        // 新布局齐全。
        expect(File('${dir.path}/spec.json').existsSync(), isTrue);
        expect(File('${dir.path}/plan.json').existsSync(), isTrue);
        expect(File('${dir.path}/src/scene.js').existsSync(), isTrue);
        expect(File('${dir.path}/migration.json').existsSync(), isTrue);
        expect(
          File('${dir.path}/artifacts/legacy-build-state.json').existsSync(),
          isTrue,
        );

        final project = await store.read('saturn');
        expect(project.migrated, isTrue);
        expect(project.mode, ThreeAuthoringMode.code);
        expect(project.spec, isA<CreativeSpec>());
        expect(project.spec!.kind.name, 'threeD');
        expect(project.plan, isA<CreativePlan3d>());
        expect(project.plan!.parts, hasLength(2));
        expect(project.sourceFiles, <String>['scene.js']);
        expect(project.issues, isEmpty);

        // 幂等。
        final again = await store.migrateLegacy('saturn');
        expect(again.alreadyMigrated, isTrue);
        expect(again.wroteSpec, isFalse);
      },
    );

    test('缺旧规范 → no_legacy；非法名字 → invalid_name；缺项目 → no_project', () async {
      final dir = Directory('${temp.path}/empty')..createSync(recursive: true);
      expect(dir.existsSync(), isTrue);
      await expectLater(
        () => store.migrateLegacy('empty'),
        throwsA(
          isA<ThreeWorkspaceFailure>().having(
            (f) => f.code,
            'code',
            'no_legacy',
          ),
        ),
      );
      await expectLater(
        () => store.read('nope'),
        throwsA(
          isA<ThreeWorkspaceFailure>().having(
            (f) => f.code,
            'code',
            'no_project',
          ),
        ),
      );
      await expectLater(
        () => store.read('../escape'),
        throwsA(
          isA<ThreeWorkspaceFailure>().having(
            (f) => f.code,
            'code',
            'invalid_name',
          ),
        ),
      );
    });
  });

  group('v2 工作区读写', () {
    test(
      'writeSpec/writePlan/writeSource/writeArtifact → read 反映 code 模式',
      () async {
        final spec = CreativeSpec.parse(creativeFixture('spec_3d_ok.json'))
            .value!;
        final plan =
            CreativePlan.parse(creativeFixture('plan_3d_chair.json')).value!
                as CreativePlan3d;
        Directory('${temp.path}/chair').createSync(recursive: true);
        await store.writeSpec('chair', spec);
        await store.writePlan('chair', plan);
        await store.writeSource(
          'chair',
          'parts/seat.js',
          'export const seat = {};\n',
        );
        await store.writeArtifact('chair', 'gates.json', <String, Object?>{
          'schema': 'x',
        });

        final project = await store.read('chair');
        expect(project.migrated, isTrue);
        expect(project.mode, ThreeAuthoringMode.code);
        expect(project.spec!.track.name, 'staticObject');
        expect(project.plan!.parts, hasLength(3));
        expect(project.sourceFiles, <String>['parts/seat.js']);
        expect(
          File('${temp.path}/chair/artifacts/gates.json').existsSync(),
          isTrue,
        );
        expect(project.issues, isEmpty);
      },
    );

    test('scene.json 存在且无 src → scene 模式', () async {
      Directory('${temp.path}/room').createSync(recursive: true);
      await store.writeSpec(
        'room',
        CreativeSpec.parse(creativeFixture('spec_3d_ok.json')).value!,
      );
      await store.writeScene('room', <String, Object?>{
        'v': 1,
        'nodes': <Object?>[],
      });
      final project = await store.read('room');
      expect(project.mode, ThreeAuthoringMode.scene);
      expect(project.sceneJson, isNotNull);
      expect(project.migrated, isTrue);
    });

    test('非法 plan 拒绝写入；路径逃逸拒绝', () async {
      Directory('${temp.path}/bad').createSync(recursive: true);
      const invalid = CreativePlan3d(
        summary: 'x',
        acceptance: <String>[],
        track: CreativeTrack.staticObject,
        language: 'threejs',
      );
      await expectLater(
        () => store.writePlan('bad', invalid),
        throwsA(
          isA<ThreeWorkspaceFailure>().having(
            (f) => f.code,
            'code',
            'plan_invalid',
          ),
        ),
      );
      final plan =
          CreativePlan.parse(creativeFixture('plan_3d_chair.json')).value!
              as CreativePlan3d;
      await store.writePlan('bad', plan);
      await expectLater(
        () => store.writeSource('bad', '../escape.js', 'x'),
        throwsA(
          isA<ThreeWorkspaceFailure>().having(
            (f) => f.code,
            'code',
            'invalid_path',
          ),
        ),
      );
    });
  });

  test('list：空目录跳过，迁移后显示 migrated', () async {
    Directory('${temp.path}/skip').createSync(recursive: true);
    final dir = Directory('${temp.path}/legacy')..createSync(recursive: true);
    File('${dir.path}/three-spec.json')
        .writeAsStringSync(jsonEncode(_legacySpec()));
    final before = await store.list();
    expect(before.map((entry) => entry.name), <String>['legacy']);
    await store.migrateLegacy('legacy');
    final after = await store.list();
    expect(after.single.migrated, isTrue);
  });

  // -- 视口控制浮层（批次 15 第一批） -------------------------------------
  //
  // 只断言 UI 层与命令面：不构造真 WebView。宽屏内容区是「大纲 | 视口 |
  // 检查器」三栏，浮层应该叠在视口面上；未就绪/无能力时整组禁用，tooltip
  // 写真实原因。就绪信号仍是预览页主动上报的 metrics 桥（不是
  // onPageFinished：平台基类该方法会 throw）。
  group('视口控制浮层', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    tearDown(() {
      debugThreeWebViewSupported = null;
      threeLoadOnOpen = null;
    });

    testWidgets('无内嵌预览能力：宽屏浮层存在但整组禁用，tooltip 写真实原因', (tester) async {
      final root = Directory('${temp.path}/viewport-unsupported')
        ..createSync(recursive: true);
      _seedPreviewProject(root, 'saturn');
      final service = _previewService(root);
      final appStore = _appStore();
      debugThreeWebViewSupported = false;
      _setViewportSize(tester, const Size(1440, 900));
      threeLoadOnOpen = 'saturn';

      await tester.pumpWidget(_appHost(appStore, service));
      await _settle(tester);

      expect(
        find.byKey(const ValueKey('three-viewport-stack')),
        findsOneWidget,
        reason: '宽屏预览面必须叠视口浮层',
      );
      expect(
        find.byKey(const ValueKey('three-viewport-controls')),
        findsOneWidget,
      );
      final keys = <Key>[
        for (final id in const <String>['front', 'top', 'iso'])
          ValueKey('three-view-$id'),
        const ValueKey('three-view-grid'),
        const ValueKey('three-view-reset'),
      ];
      for (final key in keys) {
        expect(find.byKey(key), findsOneWidget, reason: '$key 必须存在');
        expect(
          tester.widget<TextButton>(find.byKey(key)).onPressed,
          isNull,
          reason: '$key 在这台设备上必须禁用',
        );
      }
      expect(find.byTooltip('这台设备不能内嵌显示 3D 预览'), findsNWidgets(keys.length));
    });

    testWidgets('预览未就绪：禁用且不发 JS；metrics 到达后启用并真发视角/网格/重置命令', (tester) async {
      final root = Directory('${temp.path}/viewport-not-ready')
        ..createSync(recursive: true);
      _seedPreviewProject(root, 'saturn');
      final service = _previewService(root);
      final appStore = _appStore();
      _setViewportSize(tester, const Size(1440, 900));
      final previousPlatform = WebViewPlatform.instance;
      final fake = _FakeWebViewPlatform()..install();
      // 平台接口不允许把 instance 设回 null；测试进程内没有后续用例依赖
      // 「无平台」状态，保持 fake 即可（文件内无其它 WebView 用例）。
      addTearDown(() {
        if (previousPlatform != null) {
          WebViewPlatform.instance = previousPlatform;
        }
      });
      threeLoadOnOpen = 'saturn';

      await tester.pumpWidget(_appHost(appStore, service));
      await _settle(tester);

      final controller = fake.lastController;
      expect(controller, isNotNull, reason: 'fake 平台应创建预览控制器');
      expect(
        find.byKey(const ValueKey('three-viewport-controls')),
        findsOneWidget,
      );

      // 未就绪（metrics 桥还没到）：整组禁用，点击零命令。
      expect(find.byTooltip('预览还没就绪，视角控制暂不可用'), findsNWidgets(5));
      await tester.tap(find.byKey(const ValueKey('three-view-front')));
      await tester.pump(const Duration(milliseconds: 30));
      expect(controller!.jsCalls, 0, reason: '未就绪不得发 runJavaScript');

      // 预览页首帧 metrics 到达 = 唯一就绪信号。
      controller.fireJsMessage(
        jsonEncode(<String, dynamic>{
          'kind': 'metrics',
          'payload': <String, dynamic>{},
        }),
      );
      await _settle(tester);
      expect(find.byTooltip('预览还没就绪，视角控制暂不可用'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('three-view-front')));
      await tester.pump();
      expect(controller.jsScripts.last, contains('__non3d_view("front")'));
      await tester.tap(find.byKey(const ValueKey('three-view-iso')));
      await tester.pump();
      expect(controller.jsScripts.last, contains('__non3d_view("iso")'));
      await tester.tap(find.byKey(const ValueKey('three-view-reset')));
      await tester.pump();
      expect(controller.jsScripts.last, contains('__non3d_view("reset")'));

      await tester.tap(find.byKey(const ValueKey('three-view-grid')));
      await tester.pump();
      expect(controller.jsScripts.last, contains('__non3d_grid(true)'));

      // 沙箱执行面没有可开关网格 → 页面用 grid 回执如实说明 → 开关复原。
      controller.fireJsMessage(
        jsonEncode(<String, dynamic>{
          'kind': 'grid',
          'supported': false,
          'visible': true,
        }),
      );
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('three-view-grid')));
      await tester.pump();
      expect(
        controller.jsScripts.last,
        contains('__non3d_grid(true)'),
        reason: '不支持回执必须把开关复原，否则这里会发 false',
      );
    });
  });
}
