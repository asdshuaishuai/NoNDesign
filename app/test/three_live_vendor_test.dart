// vendored three-live（1.4.0）与预览页组装契约。
//
// 覆盖四组：
//  1. 资源在场：经典脚本 + Apache-2.0 许可 + NOTICE + file:// 兼容补丁标记；
//  2. 组装：场景同时进 three-live 沙箱脚本与旧路径模块，占位全部替换；
//  3. 自包含：页面零外链（脚本/样式/目录文件都不读）；
//  4. CSP：default-src / connect-src 仍为 none，只为沙箱放开 eval 与 blob worker。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:nondesign/core/three_service.dart';

String _read(String path) => File(path).readAsStringSync();

String _threeSource() =>
    'const Scene = class Scene {};\n'
    'const Mesh = class Mesh {};\n'
    'const Vector3 = class Vector3 {};\n'
    'export { Scene, Mesh, Vector3 };\n';

const String _sceneSource = '''
export default function build(THREE, scene, camera, controls, renderer) {
  const mesh = new THREE.Mesh(
    new THREE.BoxGeometry(1, 1, 1),
    new THREE.MeshStandardMaterial({ color: 0xffffff }));
  scene.add(mesh);
  return { metrics: { box: true } };
}
''';

String _assemble() => assembleThreePreview(
  template: _read('assets/three/preview.html'),
  threeSource: _threeSource(),
  threeLiveSource: _read('assets/three/vendor/three-live.min.js'),
  sceneSource: _sceneSource,
  version: 7,
);

void main() {
  group('vendored three-live', () {
    test('资源在场：经典脚本 + Apache-2.0 许可 + NOTICE', () {
      final vendor = File('assets/three/vendor/three-live.min.js');
      expect(vendor.existsSync(), isTrue);
      expect(vendor.lengthSync(), greaterThan(200000));
      final source = vendor.readAsStringSync();
      expect(source, contains('Copyright 2026 Google LLC'));
      expect(source, contains('Apache License, Version 2.0'));
      // file:// 兼容补丁：两处标记各出现一次（复现步骤见 NOTICE.md）。
      expect(
        'globalThis.__three_live_engine_source__'.allMatches(source),
        hasLength(1),
      );
      expect('(r.THREE||x(L))'.allMatches(source), hasLength(1));
      expect(
        File('assets/three/vendor/THREE-LIVE-LICENSE').existsSync(),
        isTrue,
      );
      final notice = _read('assets/three/vendor/NOTICE.md');
      expect(notice, contains('1.4.0'));
      expect(notice, contains('Apache-2.0'));
      expect(notice, contains('importScripts'));
    });

    test('模板：three-live 沙箱执行面 + 旧路径都保留，占位全部替换', () {
      final html = _assemble();
      expect(html, contains('<three-live'));
      expect(html, contains('allow-client-scripts'));
      expect(html, contains('camera-controls'));
      expect(html, contains('<script type="text/three">'));
      // 沙箱脚本 + 旧路径各有一份构建函数；两处 call 点也都在。
      expect(
        '__non3d_scene_build__'.allMatches(html).length,
        greaterThanOrEqualTo(4),
      );
      // vendor 是内联的（带补丁的引擎源文字出现在页面里），不是外链。
      expect(html, contains('globalThis.__three_live_engine_source__'));
      expect(html, contains('id="three-live-runtime"'));
      // 旧路径的 r160 命名空间与宿主函数还在（沙箱失败时的降级面）。
      expect(html, contains('const THREE = {'));
      expect(html, contains('__non3d_legacy_boot'));
      for (final slot in <String>[
        '/*__THREE_MODULE__*/',
        '/*__SCENE_SOURCE__*/',
        '/*__THREE_LIVE__*/',
        '/*__SCENE_SANDBOX__*/',
      ]) {
        expect(html.contains(slot), isFalse, reason: '占位没被替换：$slot');
      }
      expect(html, contains('// build 7'));
    });

    test('沙箱脚本：占位 controls + 单帧 update，不放逐帧循环', () {
      final html = _assemble();
      expect(html, contains('__non3d_controls'));
      expect(html, contains('update(0.016)'));
      expect(html, contains('allow-client-scripts'));
      // 页面自己不排 rAF/interval 跑沙箱场景（Worker DONE 即终止）。
      final sandbox = html.substring(
        html.indexOf('<script type="text/three">'),
        html.indexOf('</script>', html.indexOf('<script type="text/three">')),
      );
      expect(sandbox, isNot(contains('setInterval')));
      expect(sandbox, isNot(contains('requestAnimationFrame')));
    });

    test('页面自包含：没有外链脚本 / 样式 / 目录文件', () {
      final html = _assemble();
      expect(
        RegExp(r'<script[^>]+src\s*=', caseSensitive: false).hasMatch(html),
        isFalse,
      );
      expect(
        RegExp(
          "<link[^>]+href\\s*=\\s*[\"']https?:",
          caseSensitive: false,
        ).hasMatch(html),
        isFalse,
      );
      // three-live 是内联的，不按目录文件路径加载；沙箱 iframe 变体也不用。
      expect(html, isNot(contains('assets/three/vendor/three-live.min.js')));
      // 字符串常量里提到 iframe 变体没问题；不能出现的是按该文件加载的引用。
      expect(html, isNot(contains('src="three-live-sandbox.html"')));
      expect(html, isNot(contains('importmap')));
    });

    test('CSP：默认全关，只为沙箱放开 eval 与 blob worker', () {
      final html = _assemble();
      final match = RegExp(
        r'<meta http-equiv="Content-Security-Policy" content="([^"]+)"',
      ).firstMatch(html);
      expect(match, isNotNull);
      final csp = match!.group(1)!;
      expect(csp, threePreviewCsp);
      expect(csp, contains("default-src 'none'"));
      expect(csp, contains("connect-src 'none'"));
      expect(csp, contains("frame-ancestors 'none'"));
      expect(csp, contains("img-src data: blob:"));
      expect(csp, contains("script-src 'unsafe-inline' 'unsafe-eval'"));
      expect(csp, contains('worker-src blob:'));
      expect(csp, isNot(contains('*')));
      expect(csp, isNot(contains('http')));
    });

    test('模板要求 three-live 但没给源码：显性失败，不产出半成品', () {
      expect(
        () => assembleThreePreview(
          template: _read('assets/three/preview.html'),
          threeSource: _threeSource(),
          sceneSource: _sceneSource,
          version: 1,
        ),
        throwsA(
          isA<ThreeFailure>().having((f) => f.code, 'code', 'asset_missing'),
        ),
      );
    });

    test('ensureThreePreviewCsp：模板缺 CSP 时注入到 DOCTYPE 之后', () {
      final out = ensureThreePreviewCsp(
        '<!doctype html><html><script>1</script></html>',
      );
      expect(out.indexOf('Content-Security-Policy'), greaterThan(0));
      expect(
        out.indexOf('Content-Security-Policy'),
        lessThan(out.indexOf('<script>')),
      );
      final already = ensureThreePreviewCsp(
        '<html><meta http-equiv="Content-Security-Policy" content="x"></html>',
      );
      expect(
        already,
        '<html><meta http-equiv="Content-Security-Policy" content="x"></html>',
      );
    });

    test('模板注释里不能出现占位字面量（防「注入进注释」白屏事故）', () {
      final template = _read('assets/three/preview.html');
      final body = template.substring(0, template.indexOf('<body'));
      // 注释区（head）里不允许出现任何组装占位字面量。
      for (final slot in <String>[
        'THREE_MODULE__',
        'SCENE_SOURCE__',
        'THREE_LIVE__',
        'SCENE_SANDBOX__',
      ]) {
        expect(body.contains(slot), isFalse, reason: '注释里出现占位：$slot');
      }
    });
  });
}
