// vendored ThreeUI（Community 1.1.0）组件画廊契约。
//
// 覆盖四组：
//  1. 真实资源：清单 8–12 个、总量 < 6MB、每个页面自包含（零外链/零同目录读取）；
//  2. 清单解析：坏条目丢弃、空清单显性失败、健康区间；
//  3. 画廊 UI：空态卡片 → 应用内 WebView 真实打开（fake 平台注入）；
//  4. 失败路径：主帧失败显示人话 + 重试；清单读不出来显示重试而不是空屏。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
// 平台接口桩直接从平台接口库取（测试专用传递依赖）。
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

const String _fakeCatalog = '''
{"version":1,"components":[
{"id":"spark-badge","name":"火花徽章","description":"一枚会发光的徽章","file":"spark-badge.html","hint":"暗底"},
{"id":"gallery-heading","name":"画廊标题","description":"颗粒渐变的大标题动效","file":"gallery-heading.html","hint":"大标题"}
]}
''';

AppStore _store() =>
    AppStore(
        toasts: ToastService(autoDismiss: false),
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

Widget _host(AppStore store, ThreeService service) =>
    ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(
        theme: AppTheme.build(dark: true),
        home: Scaffold(body: ThreeWorkspace(service: service)),
      ),
    );

Future<void> _pumpEmpty(
  WidgetTester tester,
  AppStore store,
  ThreeService service, {
  Size size = const Size(1440, 1600),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(_host(store, service));
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 50));
}

/// 临时服务：只喂组件清单（画廊不碰预览三件套）。
Future<ThreeService> _galleryService({bool failFirstCatalog = false}) async {
  final root = Directory.systemTemp.createTempSync('threeui_gallery_test');
  addTearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });
  var catalogCalls = 0;
  Future<Uint8List> assets(String key) async {
    if (key == threeUiCatalogAssetKey) {
      catalogCalls++;
      if (failFirstCatalog && catalogCalls == 1) {
        throw const ThreeFailure('asset_missing', 'catalog: injected failure');
      }
      return Uint8List.fromList(utf8.encode(_fakeCatalog));
    }
    throw ThreeFailure('asset_missing', key);
  }

  return ThreeService(
    root: root,
    llm: (request) async => throw const ThreeFailure('llm_error', 'unused'),
    assets: assets,
  );
}

// ---- WebView 平台桩（注入即避免真 WebView；与 three_workspace_test 同形） ----

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

  _FakeNavigationDelegate? navDelegate;
  final List<String> loadedAssets = <String>[];
  final List<String> loadedFiles = <String>[];

  @override
  Future<void> setJavaScriptMode(JavaScriptMode mode) async {}

  @override
  Future<void> addJavaScriptChannel(dynamic params) async {}

  @override
  Future<void> setPlatformNavigationDelegate(dynamic delegate) async {
    navDelegate = delegate as _FakeNavigationDelegate;
  }

  @override
  Future<void> loadFile(String absoluteFilePath) async {
    loadedFiles.add(absoluteFilePath);
  }

  @override
  Future<void> loadFlutterAsset(String key) async {
    loadedAssets.add(key);
  }

  @override
  Future<void> runJavaScript(String javaScript) async {}
}

class _FakeNavigationDelegate extends PlatformNavigationDelegate {
  _FakeNavigationDelegate(super.params) : super.implementation();

  void Function(WebResourceError)? onWebResourceError;

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
}

class _FakeWebViewWidget extends PlatformWebViewWidget {
  _FakeWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

void main() {
  tearDown(() {
    debugThreeWebViewSupported = null;
  });

  group('ThreeUI 真实资源', () {
    test('清单 8–12 个，总量 < 6MB，卡片字段齐全', () {
      final catalog = parseThreeUiCatalog(
        File('assets/three/threeui/catalog.json').readAsStringSync(),
      );
      expect(
        catalog.length,
        inInclusiveRange(threeUiMinComponents, threeUiMaxComponents),
      );
      expect(threeUiCatalogHealth(catalog.length), isNull);
      final ids = <String>{};
      var total = 0;
      for (final component in catalog) {
        expect(ids.add(component.id), isTrue, reason: 'id 重复：${component.id}');
        expect(component.name, isNotEmpty);
        expect(component.description, isNotEmpty);
        expect(component.hint, isNotEmpty);
        final file = File(component.assetKey);
        expect(file.existsSync(), isTrue, reason: component.assetKey);
        total += file.lengthSync();
      }
      expect(total, lessThan(6 * 1024 * 1024), reason: '合计体积必须 < 6MB');
    });

    test('每个组件页自包含：无外链、无同目录相对读取', () {
      final catalog = parseThreeUiCatalog(
        File('assets/three/threeui/catalog.json').readAsStringSync(),
      );
      final externalRef = RegExp(r'(?:src|href)="(?!data:|#|\$\{)([^"]+)"');
      final externalLink = RegExp(
        '<(?:script|link)[^>]+(?:src|href)\\s*=\\s*["\\\'](?:https?:)?//',
        caseSensitive: false,
      );
      for (final component in catalog) {
        final html = File(component.assetKey).readAsStringSync();
        expect(
          html.toLowerCase(),
          contains('<!doctype html'),
          reason: component.id,
        );
        expect(html.length, greaterThan(2000), reason: component.id);
        for (final match in externalRef.allMatches(html)) {
          final value = match.group(1)!;
          expect(
            value.startsWith('https://www.w3.org/'),
            isTrue,
            reason: '${component.id} 还有外部引用：$value',
          );
        }
        expect(externalLink.hasMatch(html), isFalse, reason: component.id);
        expect(
          html,
          isNot(contains('inner-green-assets/')),
          reason: component.id,
        );
        expect(html, isNot(contains('cdn.jsdelivr.net')), reason: component.id);
        expect(
          html,
          isNot(contains('cdn.tailwindcss.com')),
          reason: component.id,
        );
        // 相对 url(...) 只允许 #片段 / data: / %23 转义片段。
        final urlRef = RegExp(
          r"""url\((?!['"]?(?:data:|#|%23|%27#))(?:['"]?)([^)'"]+)""",
        );
        for (final match in urlRef.allMatches(html)) {
          final value = match.group(1)!.trim();
          expect(
            value.startsWith('#'),
            isTrue,
            reason: '${component.id} 还有相对资源：$value',
          );
        }
      }
    });

    test('许可与来源声明在场（MIT + 字体 OFL + NOTICE）', () {
      expect(File('assets/three/threeui/LICENSE').existsSync(), isTrue);
      expect(
        File('assets/three/threeui/FONT-LICENSES.md').existsSync(),
        isTrue,
      );
      final notice = File('assets/three/threeui/NOTICE.md').readAsStringSync();
      expect(notice, contains('1.1.0'));
      expect(notice, contains('MIT'));
      expect(notice, contains('@designcodeio/threeui'));
    });
  });

  group('ThreeUI 清单解析', () {
    test('合法条目全部保留，assetKey 落在同目录', () {
      final catalog = parseThreeUiCatalog(_fakeCatalog);
      expect(catalog.map((c) => c.id), <String>[
        'spark-badge',
        'gallery-heading',
      ]);
      expect(catalog.first.assetKey, 'assets/three/threeui/spark-badge.html');
      expect(
        threeUiCatalogHealth(catalog.length),
        isNotNull,
        reason: '2 个不在 8–12 区间',
      );
    });

    test('坏条目丢弃：缺字段 / 非法 id / 目录穿越 / 非 html / 重复 id', () {
      final catalog = parseThreeUiCatalog(
        jsonEncode(<String, dynamic>{
          'components': <Object?>[
            <String, dynamic>{
              'id': 'ok',
              'name': '好',
              'description': '说明',
              'file': 'ok.html',
            },
            <String, dynamic>{
              'id': 'ok',
              'name': '重复',
              'description': '说明',
              'file': 'ok.html',
            },
            <String, dynamic>{
              'id': 'Bad Id',
              'name': 'x',
              'description': 'x',
              'file': 'x.html',
            },
            <String, dynamic>{'id': 'no-file', 'name': 'x', 'description': 'x'},
            <String, dynamic>{
              'id': 'escape',
              'name': 'x',
              'description': 'x',
              'file': '../x.html',
            },
            <String, dynamic>{
              'id': 'sub',
              'name': 'x',
              'description': 'x',
              'file': 'sub/x.html',
            },
            <String, dynamic>{
              'id': 'remote',
              'name': 'x',
              'description': 'x',
              'file': 'https://a/b.html',
            },
            <String, dynamic>{
              'id': 'js',
              'name': 'x',
              'description': 'x',
              'file': 'x.js',
            },
            <String, dynamic>{
              'id': 'missing-desc',
              'name': 'x',
              'description': '',
              'file': 'y.html',
            },
            'not-an-object',
          ],
        }),
      );
      expect(catalog.map((c) => c.id), <String>['ok']);
    });

    test('坏 JSON / 空清单：显性失败，不返回空画廊', () {
      for (final raw in <String>['{not json', '{"components": []}', '[]']) {
        expect(
          () => parseThreeUiCatalog(raw),
          throwsA(
            isA<ThreeFailure>().having((f) => f.code, 'code', 'asset_missing'),
          ),
          reason: raw,
        );
      }
    });

    test('服务走注入资源读清单（不依赖 asset bundle）', () async {
      final service = await _galleryService();
      final catalog = await service.loadUiCatalog();
      expect(catalog.map((c) => c.id), <String>[
        'spark-badge',
        'gallery-heading',
      ]);
    });
  });

  group('ThreeUI 画廊（应用内 WebView，fake 平台注入）', () {
    testWidgets('空态卡片 → 打开组件页 → 主帧失败人话 + 重试重载', (tester) async {
      final fake = _FakeWebViewPlatform()..install();
      addTearDown(() => WebViewPlatform.instance = WebKitWebViewPlatform());
      final service = await _galleryService();
      await _pumpEmpty(tester, _store(), service);

      expect(find.byKey(const ValueKey('threeui-gallery')), findsOneWidget);
      expect(find.text('ThreeUI 组件'), findsWidgets);
      final card = find.byKey(const ValueKey('threeui-spark-badge'));
      expect(card, findsOneWidget);
      await tester.ensureVisible(card);
      await tester.tap(card);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));

      expect(fake.lastController, isNotNull, reason: '点开必须真的构造 WebView');
      expect(
        fake.lastController!.loadedAssets,
        contains('assets/three/threeui/spark-badge.html'),
      );
      expect(find.byKey(const ValueKey('threeui-viewer')), findsOneWidget);
      expect(find.text('火花徽章'), findsWidgets);

      // 主帧失败：可读占位 + 重试（不是白屏、不是死路）。
      fake.lastController!.navDelegate!.fireResourceError(mainFrame: true);
      await tester.pump(const Duration(milliseconds: 30));
      expect(find.text('组件没能打开，请重试'), findsOneWidget);
      expect(find.text('技术详情'), findsOneWidget);

      await tester.tap(find.text('重试'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(
        fake.lastController!.loadedAssets,
        contains('assets/three/threeui/spark-badge.html'),
      );
      expect(find.text('组件没能打开，请重试'), findsNothing);
    });

    testWidgets('清单读不出来：一句人话 + 重试恢复', (tester) async {
      final fake = _FakeWebViewPlatform()..install();
      addTearDown(() => WebViewPlatform.instance = WebKitWebViewPlatform());
      final service = await _galleryService(failFirstCatalog: true);
      await _pumpEmpty(tester, _store(), service);

      expect(find.text('组件清单没有读出来，请重试'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('threeui-catalog-retry')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('threeui-spark-badge')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('threeui-catalog-retry')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(find.byKey(const ValueKey('threeui-spark-badge')), findsOneWidget);
      expect(find.text('组件清单没有读出来，请重试'), findsNothing);
      expect(fake.lastController, isNull, reason: '读清单不该构造 WebView');
    });

    testWidgets('无内嵌 WebView 的平台：画廊仍可见，点卡片不假装打开', (tester) async {
      debugThreeWebViewSupported = false;
      final service = await _galleryService();
      await _pumpEmpty(tester, _store(), service);
      expect(find.byKey(const ValueKey('threeui-gallery')), findsOneWidget);
      final card = find.byKey(const ValueKey('threeui-spark-badge'));
      await tester.ensureVisible(card);
      await tester.tap(card);
      await tester.pump(const Duration(milliseconds: 30));
      expect(find.byKey(const ValueKey('threeui-viewer')), findsNothing);
    });
  });
}
