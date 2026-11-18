// 3D 预览的设备级门（批次 06）：file:// 下的模块脚本 + importmap 到底能不能跑。
//
// 这是移动端（iOS/Android）启用本地 3D 预览的唯一判据。桌面三平台在
// `flutter build macos --debug` 的手工验收里已经验证过同一份页面；手机/平板的
// 系统 WebView 版本差异很大，必须真机/模拟器实测：
//
//   cd app && flutter test integration_test/three_webview_test.dart -d <device-id>
//
// 页面是**自包含**的（渲染库与场景在挂载时内联，见 `assembleThreePreview`）：
// 桌面 WKWebView 与移动端 Chromium 都禁止 file:// 页面用模块 import 读取同目录
// 文件（实测 CORS 拒绝），所以不能用 importmap + 相对路径。
//
// 通过 = 页面自包含 + r160 渲染库执行 + 土星场景首帧 metrics + 截图桥回传。
// 失败且错误属于「模块取文件被拦」→ 记为 cannot-do（`ThreeWebViewGate` 保持
// 关闭，移动端只走「连接桌面」），并在输出里留下原始错误；其他失败当回归抛出。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import 'package:nondesign/core/three_service.dart';

/// 土星场景：行星 + 环 + 两盏灯。要能在首帧产生 ≥2 个 mesh，才能证明
/// 渲染库真的执行了 `scene.js`（而不是只把页面加载出来）。
const String _saturnScene = '''
export default function build(THREE, scene, camera, controls, renderer) {
  const planet = new THREE.Mesh(
    new THREE.SphereGeometry(1, 48, 32),
    new THREE.MeshStandardMaterial({ color: 0xd8b273, roughness: 0.85, metalness: 0.05 }));
  planet.rotation.z = 0.2;
  scene.add(planet);

  const ring = new THREE.Mesh(
    new THREE.RingGeometry(1.5, 2.4, 64),
    new THREE.MeshStandardMaterial({
      color: 0xc9b18a, side: THREE.DoubleSide, transparent: true, opacity: 0.85,
    }));
  ring.rotation.x = Math.PI / 2.4;
  scene.add(ring);

  scene.add(new THREE.AmbientLight(0xffffff, 1.2));
  const sun = new THREE.DirectionalLight(0xffffff, 2.0);
  sun.position.set(5, 6, 4);
  scene.add(sun);

  camera.position.set(4, 2.5, 5);
  camera.lookAt(0, 0, 0);

  return {
    metrics: { planet: true, ring: true },
    update(dt) {
      planet.rotation.y += dt * 0.4;
      ring.rotation.z += dt * 0.05;
    },
  };
}
''';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('file:// 自包含预览页能执行渲染库并渲染土星场景', (tester) async {
    // macOS 没有 endorsed 的 WebView 实现，需要显式注册（与工作台同一路径）。
    if (Platform.isMacOS && WebViewPlatform.instance == null) {
      WebKitWebViewPlatform.registerWith();
    }

    // 真实路径：本地面 + 打包资源 + 组装器（与工作台挂载预览同一条代码路）。
    final dir = await Directory.systemTemp.createTemp('non3d_three_webview');
    addTearDown(() async {
      if (dir.existsSync()) await dir.delete(recursive: true);
    });
    final projectDir = Directory('${dir.path}/saturn-demo')..createSync(recursive: true);
    File('${projectDir.path}/three-spec.json').writeAsStringSync(jsonEncode(<String, dynamic>{
      'title': 'Saturn',
      'components': <dynamic>['planet', 'ring'],
      'acceptance': <dynamic>['行星在场', '环可见'],
    }));
    File('${projectDir.path}/build-state.json').writeAsStringSync(jsonEncode(initialThreeState()));
    File('${projectDir.path}/scene.js').writeAsStringSync(_saturnScene, flush: true);

    final service = ThreeService(root: dir);
    final bundle = await service.preparePreview('saturn-demo');
    final htmlPath = bundle.htmlPath;
    final html = File(htmlPath).readAsStringSync();
    expect(File(bundle.modulePath).lengthSync(), threeModuleByteLength,
        reason: '打包进来的渲染库被裁剪了：assets/three/three.module.js 必须完整');
    // 自包含：没有任何“去读另一个文件”的入口，也没有远端地址。
    expect(html, contains('const THREE = {'));
    expect(html, contains('const __non3d_scene_build__ = build;'));
    expect(html, isNot(contains('importmap')));
    expect(html, isNot(contains('./three.module.js')));
    expect(html, isNot(contains('unpkg.com')));
    expect(html, isNot(contains('https://')));

    final messages = <Map<String, dynamic>>[];
    final raw = <String>[];
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel('NON3D', onMessageReceived: (message) {
        raw.add(message.message);
        try {
          final decoded = jsonDecode(message.message);
          if (decoded is Map) messages.add(decoded.cast<String, dynamic>());
        } catch (_) {
          // 桥消息不是 JSON：留着原文，失败时一起打印。
        }
      });
    await controller.loadFile(htmlPath);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: WebViewWidget(controller: controller)),
    ));

    // 首帧 metrics 由预览页在加载完成后主动上报（此后每 2s 一次）。
    final deadline = DateTime.now().add(const Duration(seconds: 25));
    while (DateTime.now().isBefore(deadline) &&
        !messages.any((m) => m['kind'] == 'metrics')) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await tester.pump();
    }

    final metrics = messages.where((m) => m['kind'] == 'metrics').toList();
    final errors = messages.where((m) => m['kind'] == 'error').toList();
    final unsupported = messages.where((m) => m['kind'] == 'unsupported').toList();
    // ignore: avoid_print
    print('[three-webview] messages=$raw');

    if (metrics.isEmpty) {
      final evidence = <String>[
        if (errors.isNotEmpty) 'errors=${errors.map((e) => e['message']).join(' | ')}',
        if (unsupported.isNotEmpty)
          'unsupported=${unsupported.map((e) => e['message']).join(' | ')}',
        if (errors.isEmpty && unsupported.isEmpty) 'no bridge message at all',
      ].join('; ');
      final host = Platform.isIOS ? 'iOS' : (Platform.isAndroid ? 'Android' : Platform.operatingSystem);
      final knownLimit = errors.any((e) =>
              '${e['message']}'.toLowerCase().contains('module') ||
              '${e['message']}'.toLowerCase().contains('import')) ||
          unsupported.isNotEmpty;
      if (knownLimit) {
        // 记录 cannot-do：该平台的系统 WebView 不支持 file:// 下的模块脚本 /
        // importmap。移动端 3D 只能走「连接桌面」，ThreeWebViewGate 保持关闭。
        markTestSkipped(
          '本地 3D 预览在 $host 上不可用（cannot-do）：$evidence。'
          '移动端保持「连接桌面」路径，桌面三平台不受影响。',
        );
        return;
      }
      fail('预览页没有跑起来（$host）：$evidence');
    }

    expect(errors, isEmpty, reason: '预览页报错：${errors.map((e) => e['message']).join(' | ')}');
    final payload = (metrics.first['payload'] as Map?)?.cast<String, dynamic>() ?? const {};
    final meshes = payload['meshes'];
    final triangles = payload['triangles'];
    final user = (payload['user'] as Map?)?.cast<String, dynamic>() ?? const {};

    expect(meshes, isA<int>());
    expect(meshes as int, greaterThanOrEqualTo(2), reason: '土星场景应有行星 + 环两个 mesh');
    expect(triangles, isA<int>());
    expect(triangles as int, greaterThan(100), reason: '球体/圆环的三角面数远大于 100');
    expect(user['planet'], isTrue, reason: 'scene.js 的 metrics 必须回传（证明代码真的执行了）');
    expect(user['ring'], isTrue);

    // 截图桥与四方位桥存在（行为由工作台的按钮门控，这里只确认可调用）。
    await controller.runJavaScript('window.__non3d_screenshot && window.__non3d_screenshot("boot")');
    final deadline2 = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline2) &&
        !messages.any((m) => m['kind'] == 'screenshot')) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pump();
    }
    final shot = messages.where((m) => m['kind'] == 'screenshot').toList();
    expect(shot, isNotEmpty, reason: '截图桥必须能在真机上回传一张 PNG');
    expect('${shot.first['payload']}', startsWith('data:image/png;base64,'));
    expect('${shot.first['tag']}', 'boot');
  });
}
