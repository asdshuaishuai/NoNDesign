// 批次 14：官方 A2UI Web 渲染器 spike 的契约测试。
//
// 四层覆盖：
// ① 打包产物自包含：CSP 只经 <meta> 注入、script-src 是内联脚本的 sha256、
//    零外部脚本/样式、除纯标识符外无外链、无网络原语；
// ② build-manifest.json 锁版本（@a2ui/web_core / @a2ui/lit 0.15.0）且逐文件
//    sha256/字节数与产物一致（手改产物不重建会红）；独立 bundle 与内联脚本同源；
// ③ 桥消息解码：ready/rendered/action/error/surface_removed/reset、未知类型
//    向前兼容、畸形/超大消息显式失败；
// ④ 卡片接线：装载打包页面、ready 前不下发、ready 后 reset+下发、动作回流、
//    装载失败/启动超时的人话错误、导航白名单、dispose。
//
// 真实 WKWebView 的加载与点击不在 flutter test 的宿主能力内（没有插件宿主，
// 不能实例化 WebViewController）——由 docs/plan-a2ui-web-spike.md 的 smoke
// 命令在 macOS/iOS 上用真实 WebView 覆盖。
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nondesign/core/theme.dart';
import 'package:nondesign/widgets/a2ui_web_card.dart';

const String _assetRoot = 'assets/a2ui_web';

String _readAsset(String name) => File('$_assetRoot/$name').readAsStringSync();

String _html() => _readAsset('index.html');

Map<String, Object?> _manifest() =>
    jsonDecode(_readAsset('build-manifest.json')) as Map<String, Object?>;

String _inlineScript(String html) {
  final match = RegExp(r'<script>([\s\S]*)</script>').firstMatch(html);
  expect(match, isNotNull, reason: '产物里没有内联脚本');
  return match!.group(1)!;
}

Future<String> _sha256Hex(List<int> bytes) async {
  final hash = await Sha256().hash(bytes);
  return hash.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

Future<String> _sha256Base64(List<int> bytes) async {
  final hash = await Sha256().hash(bytes);
  return base64Encode(hash.bytes);
}

List<Object?> _fixture() =>
    jsonDecode(_readAsset('fixture_surface.json')) as List<Object?>;

Widget _host(Widget child) => MaterialApp(
      theme: AppTheme.build(dark: true),
      home: Scaffold(body: Center(child: child)),
    );

/// 假页面：记录装载内容/下发脚本，测试里手动发桥事件。
class _FakePage implements A2uiWebPage {
  final List<String> loadedHtml = [];
  final List<String> scripts = [];
  bool disposed = false;
  void Function(String message)? _handler;

  @override
  void setMessageHandler(void Function(String message) handler) {
    _handler = handler;
  }

  @override
  Future<void> loadHtml(String html, {String? baseUrl}) async {
    loadedHtml.add(html);
  }

  @override
  Future<void> runJavaScript(String script) async {
    scripts.add(script);
  }

  @override
  Widget buildView() => const SizedBox.shrink();

  @override
  Future<void> dispose() async {
    disposed = true;
  }

  void emit(Map<String, Object?> event) {
    final handler = _handler;
    if (handler == null) {
      fail('页面还没注册消息回调');
    }
    handler(jsonEncode(event));
  }
}

void main() {
  group('打包产物自包含', () {
    test('CSP 只经 meta 注入，script-src 与内联脚本的 sha256 一致', () async {
      final html = _html();
      final cspMatch = RegExp(
        r'<meta http-equiv="Content-Security-Policy" content="([^"]+)">',
      ).firstMatch(html);
      expect(cspMatch, isNotNull, reason: '缺少 CSP meta');
      final csp = cspMatch!.group(1)!;
      expect(csp, contains("default-src 'none'"));
      expect(csp, contains("connect-src 'none'"));
      expect(csp, contains("base-uri 'none'"));
      expect(csp, contains("form-action 'none'"));
      expect(csp, contains("frame-ancestors 'none'"));
      expect(csp, contains("style-src 'unsafe-inline'"));

      final script = _inlineScript(html);
      final expected = await _sha256Base64(utf8.encode(script));
      final scriptSrc = RegExp(r"script-src ([^;]+);").firstMatch(csp);
      expect(scriptSrc, isNotNull);
      expect(scriptSrc!.group(1)!.trim(), "'sha256-$expected'");
    });

    test('零外链：无外部脚本/样式，URL 只剩协议标识符，无网络原语', () {
      final html = _html();
      final script = _inlineScript(html);
      expect(html, isNot(contains('<script src=')));
      expect(html, isNot(contains('<link ')));
      expect(html, isNot(contains('<iframe')));

      const allowedHosts = {
        'a2ui.org',
        'json-schema.org',
        'example.invalid',
        'example.com',
        'www.w3.org',
      };
      final urls = RegExp(r'https?://[^\s"' r"'`)\\]*")
          .allMatches(html)
          .map((match) => match.group(0)!)
          .toList();
      for (final url in urls) {
        expect(
          allowedHosts.contains(Uri.parse(url).host),
          isTrue,
          reason: '产物里出现非标识符外链：$url',
        );
      }

      for (final primitive in const [
        'fetch(',
        'XMLHttpRequest',
        'importScripts',
        'sendBeacon',
        'new WebSocket',
      ]) {
        expect(script.contains(primitive), isFalse, reason: primitive);
      }
    });

    test('manifest 锁版本且逐文件 sha256/字节数对得上', () async {
      final manifest = _manifest();
      final packages = manifest['packages'] as Map<String, Object?>;
      expect(packages['@a2ui/web_core'], '0.15.0');
      expect(packages['@a2ui/lit'], '0.15.0');
      expect(manifest['protocol'], '1.0');
      expect(manifest['bridgeVersion'], 1);
      final toolchain = manifest['toolchain'] as Map<String, Object?>;
      expect(toolchain['esbuild'], isNotEmpty);

      final files = manifest['files'] as Map<String, Object?>;
      for (final name in ['index.html', 'a2ui_web.js', 'fixture_surface.json']) {
        final bytes = File('$_assetRoot/$name').readAsBytesSync();
        final entry = files[name] as Map<String, Object?>;
        expect(entry['sha256'], await _sha256Hex(bytes), reason: name);
        expect(entry['bytes'], bytes.length, reason: name);
      }
    });

    test('独立 bundle 与页面内联脚本同源', () {
      final standalone = _readAsset('a2ui_web.js');
      final escaped = standalone
          .replaceAll(RegExp('</script', caseSensitive: false), r'<\/script')
          .replaceAll('<!--', r'<\u0021--');
      expect(escaped, _inlineScript(_html()));
    });
  });

  group('fixture', () {
    test('v1.0 信封、按钮动作与 @path 数据绑定', () {
      final fixture = _fixture();
      expect(fixture, hasLength(3));

      final create = (fixture[0] as Map)['createSurface'] as Map;
      expect((fixture[0] as Map)['version'], '1.0');
      expect(create['surfaceId'], 'spike');
      expect(
        create['catalogId'],
        'https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json',
      );

      final components =
          ((fixture[1] as Map)['updateComponents'] as Map)['components'] as List;
      final byId = {
        for (final component in components.cast<Map>())
          component['id'] as String: component,
      };
      final button = byId['confirm']!;
      final action = (button['action'] as Map)['event'] as Map;
      expect(action['name'], 'spike_confirm');
      final context = action['context'] as Map;
      expect((context['choice'] as Map)['@path'], '/choice');
      expect((byId['choice']!['value'] as Map)['@path'], '/choice');

      final data = (fixture[2] as Map)['updateDataModel'] as Map;
      expect(data['path'], '/');
      expect((data['value'] as Map)['choice'], 'a');
    });
  });

  group('桥消息解码', () {
    test('ready / rendered / action / error / removed / reset', () {
      final ready = decodeA2uiWebEvent(
        '{"type":"ready","protocol":"1.0","bridgeVersion":1,'
        '"versions":{"core":"0.15.0"}}',
      );
      expect(ready, isA<A2uiWebReady>());
      expect((ready! as A2uiWebReady).protocol, '1.0');
      expect((ready as A2uiWebReady).versions['core'], '0.15.0');

      final rendered = decodeA2uiWebEvent(
        '{"type":"rendered","surfaceId":"spike","textLength":3,"text":"abc"}',
      );
      expect(rendered, isA<A2uiWebRendered>());
      expect((rendered! as A2uiWebRendered).textLength, 3);

      final action = decodeA2uiWebEvent(
        '{"type":"action","name":"spike_confirm","surfaceId":"spike",'
        '"sourceComponentId":"confirm","context":{"choice":"a"},'
        '"timestamp":"2026-11-18T00:00:00Z"}',
      );
      expect(action, isA<A2uiWebAction>());
      final actionValue = action! as A2uiWebAction;
      expect(actionValue.name, 'spike_confirm');
      expect(actionValue.context['choice'], 'a');
      expect(actionValue.timestamp, '2026-11-18T00:00:00Z');

      final error = decodeA2uiWebEvent(
        '{"type":"error","code":"render_failed","message":"boom"}',
      );
      expect(error, isA<A2uiWebPageError>());
      expect((error! as A2uiWebPageError).code, 'render_failed');

      expect(
        decodeA2uiWebEvent('{"type":"surface_removed","surfaceId":"spike"}'),
        isA<A2uiWebSurfaceRemoved>(),
      );
      expect(decodeA2uiWebEvent('{"type":"reset"}'), isA<A2uiWebReset>());
    });

    test('未知类型向前兼容；动作缺 name 视为非法', () {
      expect(decodeA2uiWebEvent('{"type":"future_event"}'), isNull);
      expect(decodeA2uiWebEvent('{"type":"render_accepted","count":3}'), isNull);
      expect(
        () => decodeA2uiWebEvent('{"type":"action","surfaceId":"s"}'),
        throwsA(isA<A2uiWebProtocolException>()),
      );
    });

    test('畸形 JSON / 非对象 / 超大消息显式失败', () {
      expect(
        () => decodeA2uiWebEvent('{not json'),
        throwsA(isA<A2uiWebProtocolException>()),
      );
      expect(
        () => decodeA2uiWebEvent('[1,2,3]'),
        throwsA(isA<A2uiWebProtocolException>()),
      );
      final oversized = '{"type":"action","name":"n","pad":"'
          '${'x' * (kA2uiWebMaxMessageBytes + 1)}"}';
      expect(
        () => decodeA2uiWebEvent(oversized),
        throwsA(isA<A2uiWebProtocolException>()),
      );
    });
  });

  group('导航白名单', () {
    test('只放行注入文档自身，外部 scheme 一律拒绝', () {
      expect(a2uiWebNavigationAllowed('about:blank'), isTrue);
      expect(a2uiWebNavigationAllowed('data:text/html,<p>x</p>'), isTrue);
      expect(a2uiWebNavigationAllowed('blob:https://x/1'), isTrue);
      expect(a2uiWebNavigationAllowed(''), isTrue);
      expect(a2uiWebNavigationAllowed('https://evil.example'), isFalse);
      expect(a2uiWebNavigationAllowed('http://127.0.0.1:9/'), isFalse);
      expect(a2uiWebNavigationAllowed('file:///etc/passwd'), isFalse);
      expect(a2uiWebNavigationAllowed('javascript:alert(1)'), isFalse);
    });
  });

  group('卡片接线', () {
    test('asset 未声明时回退到仓库文件（测试/调试路径）', () async {
      A2uiWebBundle.resetCache();
      final html = await A2uiWebBundle.loadHtml();
      expect(html, startsWith('<!doctype html>'));
      expect(html, contains("default-src 'none'"));
    });

    testWidgets('装载打包页面；ready 前不下发；动作经桥回流', (tester) async {
      final page = _FakePage();
      A2uiWebAction? action;
      A2uiWebReady? ready;
      await tester.pumpWidget(_host(A2uiWebCard(
        pageFactory: () => page,
        htmlLoader: () async => _html(),
        onAction: (value) => action = value,
        onReady: (value) => ready = value,
      )));
      await tester.pump();

      expect(page.loadedHtml, hasLength(1));
      expect(page.loadedHtml.single, contains('Content-Security-Policy'));
      expect(page.scripts, isEmpty, reason: 'fixture 路径不应下发消息');
      expect(find.text('预览准备中…'), findsOneWidget);

      page.emit({
        'type': 'ready',
        'protocol': '1.0',
        'bridgeVersion': 1,
        'versions': {'core': '0.15.0'},
      });
      await tester.pump();
      expect(ready?.protocol, '1.0');
      expect(find.text('预览准备中…'), findsNothing);

      page.emit({
        'type': 'action',
        'name': 'spike_confirm',
        'surfaceId': 'spike',
        'sourceComponentId': 'confirm',
        'context': {'choice': 'a'},
        'timestamp': '2026-11-18T00:00:00Z',
      });
      await tester.pump();
      expect(action?.name, 'spike_confirm');
      expect(action?.surfaceId, 'spike');
      expect(action?.context['choice'], 'a');
    });

    testWidgets('messages 在 ready 后先 reset 再整批下发', (tester) async {
      final page = _FakePage();
      await tester.pumpWidget(_host(A2uiWebCard(
        messages: _fixture(),
        pageFactory: () => page,
        htmlLoader: () async => _html(),
      )));
      await tester.pump();
      expect(page.scripts, isEmpty);

      page.emit({'type': 'ready', 'protocol': '1.0', 'bridgeVersion': 1});
      await tester.pump();

      // ready 后先同步主题，再整批下发（reset 在同一条脚本里）。
      expect(
        page.scripts.any((value) => value.contains(".setTheme('dark')")),
        isTrue,
        reason: '页面主题应跟随宿主明暗',
      );
      final renders =
          page.scripts.where((value) => value.contains('.render(')).toList();
      expect(renders, hasLength(1));
      final script = renders.single;
      expect(script, contains('window.A2uiWeb && window.A2uiWeb.render('));
      expect(script, contains('{reset:true}'));
      expect(script, contains('"version":"1.0"'));
      expect(script, contains('"spike_confirm"'));
      expect(script, contains('"@path":"/choice"'));
    });

    testWidgets('装载失败与启动超时都给人话错误', (tester) async {
      final failed = _FakePage();
      await tester.pumpWidget(_host(A2uiWebCard(
        pageFactory: () => failed,
        htmlLoader: () async =>
            throw const A2uiWebBundleException('asset 缺失'),
      )));
      await tester.pump();
      expect(find.text('离线预览还没有准备好，请稍后重试'), findsOneWidget);

      final slow = _FakePage();
      await tester.pumpWidget(_host(A2uiWebCard(
        key: const ValueKey('slow'),
        pageFactory: () => slow,
        htmlLoader: () async => '<!doctype html>',
        bootTimeout: const Duration(milliseconds: 20),
      )));
      await tester.pump(const Duration(milliseconds: 40));
      expect(find.text('离线预览没有启动，请重试'), findsOneWidget);
    });

    testWidgets('dispose 释放页面控制器', (tester) async {
      final page = _FakePage();
      await tester.pumpWidget(_host(A2uiWebCard(
        pageFactory: () => page,
        htmlLoader: () async => '<!doctype html>',
      )));
      await tester.pump();
      await tester.pumpWidget(_host(const SizedBox.shrink()));
      expect(page.disposed, isTrue);
    });
  });
}
