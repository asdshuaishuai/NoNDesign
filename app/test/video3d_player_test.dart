import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nondesign/core/video3d/video3d_compile.dart';
import 'package:nondesign/core/video3d/video3d_contract.dart';
import 'package:nondesign/core/video3d/video3d_player.dart';

// ---------------------------------------------------------------------------
// Fixtures：契约层合法输入（校验器语义在 video3d_contract_test 覆盖；这里只
// 验证预览页组装的字节面/桥面/确定性）。
// ---------------------------------------------------------------------------

/// 测试用 three-live 运行时文本：**故意不执行真三维**，只证明运行文本被
/// 逐字内嵌且缺失时显性失败。stub 里不含任何 HTML 结束标签/外链。
const String _runtimeStub =
    '''/* three-live runtime stub (test only: embedded verbatim) */
var __VIDEO3D_RUNTIME_STUB__ = true;
var __VIDEO3D_RUNTIME_MESSAGE__ = 'stub';
''';

Map<String, Object?> _validScene() {
  return <String, Object?>{
    'v': 1,
    'units': 'm',
    'environment': <String, Object?>{'background': '#0b0d12'},
    'nodes': <Object?>[
      <String, Object?>{
        'id': 'floor',
        'type': 'box',
        'size': <double>[10, 0.1, 10],
        'position': <double>[0, -0.05, 0],
        'rotation': <double>[0, 0, 0],
        'scale': <double>[1, 1, 1],
        'material': <String, Object?>{
          'color': '#9a8c7a',
          'roughness': 0.9,
          'metalness': 0.0,
        },
        'parent': null,
      },
      <String, Object?>{
        'id': 'table',
        'type': 'plane',
        'size': <double>[2, 1, 0],
        'position': <double>[0, 0.5, 0],
        'parent': 'floor',
      },
      <String, Object?>{
        'id': 'lamp',
        'type': 'sphere',
        'size': <double>[0.12, 0.12, 0.12],
        'rotation': <double>[0, 30, 0],
        'material': <String, Object?>{'color': '#f0c070'},
      },
    ],
    'lights': <Object?>[
      <String, Object?>{
        'id': 'key',
        'type': 'directional',
        'intensity': 1.0,
        'color': '#ffffff',
        'position': <double>[4, 6, 4],
        'target': <double>[0, 0, 0],
      },
      <String, Object?>{'type': 'ambient', 'intensity': 0.2},
    ],
    'cameras': <Object?>[
      <String, Object?>{
        'id': 'hero',
        'position': <double>[4, 2, 4],
        'target': <double>[0, 1, 0],
        'fov': 45,
      },
      <String, Object?>{
        'id': 'wide',
        'position': <double>[0, 2, 6],
        'target': <double>[0, 1, 0],
        'fov': 60,
      },
    ],
  };
}

/// 两镜：5s 固定机位 + 3s easeInOut 直线推近；总片长 8s = 240 帧。
Map<String, Object?> _validScreenplay({String? firstShotId}) {
  return <String, Object?>{
    'v': 1,
    'fps': 30,
    'format': <String, Object?>{'width': 720, 'height': 1280},
    'seed': 7,
    'shots': <Object?>[
      <String, Object?>{
        'id': firstShotId ?? 's1',
        'duration': 5.0,
        'camera': <String, Object?>{'id': 'hero'},
        'cues': <Object?>[],
      },
      <String, Object?>{
        'id': 's2',
        'duration': 3.0,
        'camera': <String, Object?>{
          'id': 'wide',
          'move': <String, Object?>{
            'from': <double>[4, 2, 4],
            'to': <double>[3, 2.2, 4],
            'target': <double>[0, 1, 0],
            'easing': 'easeInOut',
          },
        },
      },
    ],
  };
}

({Video3dScene scene, Video3dScreenplay screenplay}) _models({
  Map<String, Object?>? sceneRaw,
  Map<String, Object?>? screenplayRaw,
}) {
  final sceneResult = Video3dScene.parse(sceneRaw ?? _validScene());
  final screenplayResult = Video3dScreenplay.parse(
    screenplayRaw ?? _validScreenplay(),
  );
  expect(sceneResult.issues, isEmpty, reason: 'fixture 场景必须合法');
  expect(screenplayResult.issues, isEmpty, reason: 'fixture 镜头必须合法');
  return (scene: sceneResult.scene!, screenplay: screenplayResult.screenplay!);
}

String _html({
  Map<String, Object?>? sceneRaw,
  Map<String, Object?>? screenplayRaw,
  String? runtime = _runtimeStub,
  String three = '',
  String babylon = '',
}) {
  final models = _models(sceneRaw: sceneRaw, screenplayRaw: screenplayRaw);
  return assembleVideo3dPreview(
    models.scene,
    models.screenplay,
    runtimeSource: runtime,
    threeSource: three,
    babylonSource: babylon,
  );
}

/// 极小 Babylon 兜底样本：经典脚本 + 全局 NAN_BABYLON + 唯一标记。
const String _babylonStub =
    'var __BABYLON_STUB_MARKER__ = true;\n'
    'window.NAN_BABYLON = { createVideoRenderer: function () { return null; } };\n';

/// 最小可改写的「渲染库」文本：形状与 r160 一致（末尾一条出口块）。
const String _threeStub =
    'const Vector3 = class Vector3 {};\n'
    'export { Vector3 };\n';

/// 从内联脚本里取出 `var NAME = <json>;` 的单行 JSON 字面量原文。
String _jsonLiteral(String html, String name) {
  final String marker = 'var $name = ';
  final int start = html.indexOf(marker);
  expect(start, isNot(-1), reason: '页面缺少 $name 字面量');
  final int begin = start + marker.length;
  final int end = html.indexOf(';\n', begin);
  expect(end, greaterThan(begin), reason: '$name 字面量没有结束分号');
  final String raw = html.substring(begin, end);
  expect(raw, isNot(contains('\n')), reason: '$name 应内联成单行 JSON');
  return raw;
}

Video3dTimeline _timelineOf(Map<String, Object?> screenplayRaw) {
  final result = Video3dScreenplay.parse(screenplayRaw);
  expect(result.issues, isEmpty);
  return compileVideo3dTimeline(result.screenplay!);
}

void main() {
  group('CSP 与零外联', () {
    test('CSP 固定为四指令，且先于第一个脚本、只出现一次', () {
      final String html = _html();
      expect(
        video3dPreviewCsp,
        "default-src 'none'; script-src 'unsafe-inline'; "
        "connect-src 'none'; frame-ancestors 'none'",
      );
      expect(
        html,
        contains(
          '<meta http-equiv="Content-Security-Policy" '
          'content="$video3dPreviewCsp">',
        ),
      );
      // 离线页只能靠 meta 生效：策略必须早于第一个脚本。
      expect(
        html.indexOf('Content-Security-Policy'),
        lessThan(html.indexOf('<script')),
      );
      expect(
        '<meta http-equiv="Content-Security-Policy"'.allMatches(html).length,
        1,
      );
      for (final String directive in <String>[
        'unsafe-eval',
        'worker-src',
        'style-src',
        'img-src',
        'font-src',
        'media-src',
        'blob:',
      ]) {
        expect(html, isNot(contains(directive)), reason: 'CSP 不应放开 $directive');
      }
    });

    test('零外联：无 http(s) 地址、无外链资源、无网络 API', () {
      final String html = _html();
      expect(RegExp(r'https?://').hasMatch(html), isFalse);
      expect(
        RegExp(r'<script[^>]*\bsrc\s*=', caseSensitive: false).hasMatch(html),
        isFalse,
      );
      expect(RegExp(r'<link\b', caseSensitive: false).hasMatch(html), isFalse);
      expect(RegExp(r'<img\b', caseSensitive: false).hasMatch(html), isFalse);
      expect(
        RegExp(r'<iframe\b', caseSensitive: false).hasMatch(html),
        isFalse,
      );
      expect(
        RegExp(r'<object\b', caseSensitive: false).hasMatch(html),
        isFalse,
      );
      expect(RegExp(r'@import\b').hasMatch(html), isFalse);
      expect(RegExp(r'\bcrossorigin\b').hasMatch(html), isFalse);
      for (final String forbidden in <String>[
        'fetch(',
        'XMLHttpRequest',
        'WebSocket',
        'sendBeacon',
        'importScripts',
        'new Worker',
        'localStorage',
        'indexedDB',
        'new Function',
        'eval(',
        'data:audio',
        '.mp3',
        '.wav',
        '.ogg',
        '.m4a',
        '.flac',
      ]) {
        expect(html, isNot(contains(forbidden)), reason: '不应出现 $forbidden');
      }
    });

    test('页面自包含：五段内联脚本（运行时/Babylon/模块渲染面/场景/页面），不读本地文件', () {
      final String html = _html();
      expect(html.startsWith('<!doctype html>'), isTrue);
      expect(html, contains('<meta charset="utf-8">'));
      // 运行时 / 模块渲染面（含渲染库+场景）/ 经典场景 / 页面主脚本。
      expect('<script'.allMatches(html).length, 5);
      expect('</script>'.allMatches(html).length, 5);
      expect(html, isNot(contains('<base')));
      expect(html, isNot(contains('file://')));
      // 自包含页的主体必须真有渲染循环/投影代码，而不是只塞 JSON。
      expect(html.length, greaterThan(20000));
      expect(html, contains('id="video3d-canvas"'));
      expect(html, contains('id="video3d-seek"'));
    });
  });

  group('确定性', () {
    test('同输入两次组装字节相同（含 JSON 重解析后重建）', () {
      final models = _models();
      final String first = assembleVideo3dPreview(
        models.scene,
        models.screenplay,
        runtimeSource: _runtimeStub,
      );
      final String second = assembleVideo3dPreview(
        models.scene,
        models.screenplay,
        runtimeSource: _runtimeStub,
      );
      expect(first, second);
      expect(first.length, second.length);

      // 两份事实源经 JSON 往返后构造出的同一模型必须产出同一字节页面。
      final reModels = _models(
        sceneRaw: _validScene(),
        screenplayRaw: _validScreenplay(),
      );
      expect(
        assembleVideo3dPreview(
          reModels.scene,
          reModels.screenplay,
          runtimeSource: _runtimeStub,
        ),
        first,
        reason: '同输入（即使对象实例不同）必须字节相同',
      );
      expect(
        assembleVideo3dPreview(
          models.scene,
          models.screenplay,
          runtimeSource: _runtimeStub,
        ).length,
        first.length,
      );
    });

    test('runtime 文本参与确定性：不同运行文本 → 不同页面；页面无时间戳', () {
      final models = _models();
      final String base = assembleVideo3dPreview(
        models.scene,
        models.screenplay,
        runtimeSource: _runtimeStub,
      );
      final String different = assembleVideo3dPreview(
        models.scene,
        models.screenplay,
        runtimeSource: '$_runtimeStub/* variant */\n',
      );
      expect(different, isNot(equals(base)));
      expect(different.length, greaterThan(base.length));
      for (final String forbidden in <String>[
        'Date.now',
        'performance.now',
        'new Date(',
        'Math.random',
        'crypto.getRandomValues',
      ]) {
        expect(base, isNot(contains(forbidden)), reason: '不应出现 $forbidden');
      }
    });
  });

  group('内嵌 scene JS / 帧时间表 / 渲染模型', () {
    test('scene JS 来自 compileVideo3dScene，并以可调用 build 函数内嵌', () {
      final models = _models();
      final String compiled = compileVideo3dScene(models.scene);
      final String inline = compiled.replaceFirst(
        'export default function build(',
        'function build(',
      );
      final String html = _html();
      expect(html, contains(inline), reason: 'scene JS 必须逐字内嵌（仅去掉 export）');
      expect(html, contains('function build(THREE, scene, camera)'));
      expect(html, isNot(contains('export default')));
      // 证据/检查靠 mesh.name 锚定节点：全部节点 id 必须出现在内嵌代码里。
      expect(compiled, contains('mesh.name = node.id'));
      for (final String nodeId in <String>['floor', 'table', 'lamp']) {
        expect(html, contains("id: '$nodeId'"));
      }
      expect(compiled, contains('scene_nodes: 3'));
    });

    test('帧时间表来自 compileVideo3dTimeline：240 帧、镜头区间覆盖全片', () {
      final screenplayRaw = _validScreenplay();
      final timeline = _timelineOf(screenplayRaw);
      expect(timeline.totalFrames, 240);
      expect(timeline.fps, video3dFps);

      final html = _html(screenplayRaw: screenplayRaw);
      final raw = _jsonLiteral(html, 'TIMELINE');
      expect(jsonDecode(raw), timeline.toJson());
      final decoded = jsonDecode(raw)! as Map<String, Object?>;
      expect(decoded['fps'], 30);
      expect(decoded['total_frames'], 240);
      expect(decoded['duration_seconds'], 8.0);
      expect(decoded['shots'], <Object?>[
        <String, Object?>{
          'id': 's1',
          'start_frame': 0,
          'frame_count': 150,
          'end_frame': 150,
          'camera_id': 'hero',
        },
        <String, Object?>{
          'id': 's2',
          'start_frame': 150,
          'frame_count': 90,
          'end_frame': 240,
          'camera_id': 'wide',
        },
      ]);
      expect(html, contains('var TOTAL_FRAMES'));
      expect(html, contains('var SHOTS'));
    });

    test('渲染模型内嵌格式/背景/相机/镜头运动（确定性派生）', () {
      final html = _html();
      final rawRender = _jsonLiteral(html, 'RENDER');
      final render = jsonDecode(rawRender)! as Map<String, Object?>;
      expect(render['fps'], 30);
      expect(render['duration_seconds'], 8.0);
      expect(render['total_frames'], 240);
      expect(render['seed'], 7);
      expect(render['background'], '#0b0d12');
      expect(render['format'], <String, Object?>{'width': 720, 'height': 1280});
      expect(render['nodes'], hasLength(3));
      expect(render['cameras'], hasLength(2));
      expect(render['lights'], hasLength(2));
      final List<Object?> shotCameras =
          render['shot_cameras']! as List<Object?>;
      expect(shotCameras, hasLength(2));
      expect(shotCameras[0], <String, Object?>{
        'camera_id': 'hero',
        'easing': 'linear',
      });
      expect(shotCameras[1], <String, Object?>{
        'camera_id': 'wide',
        'from': <double>[4, 2, 4],
        'to': <double>[3, 2.2, 4],
        'target': <double>[0, 1, 0],
        'easing': 'easeInOut',
      });
      expect(html, contains('var FORMAT'));
      expect(html, contains('var WIDTH'));
      expect(html, contains('var HEIGHT'));
      expect(jsonDecode(rawRender), isNot(contains('timestamp')));
    });
  });

  group('渲染循环 / seek API / 桥面', () {
    test('window.NONVIDEO3D 只回传 ready / frame / ended / error', () {
      final String html = _html();
      expect(video3dPreviewBridgeMessages, <String>[
        'ready',
        'frame',
        'ended',
        'error',
        'evidence',
      ]);
      expect(html, contains('window.$video3dPreviewBridge'));
      expect(
        html,
        contains(
          'window.$video3dPreviewBridge.postMessage(JSON.stringify(object))',
        ),
      );
      final Set<String> kinds = RegExp(r"postMessage\('([a-z]+)'")
          .allMatches(html)
          .map((match) => match.group(1)!)
          .toSet();
      expect(kinds, video3dPreviewBridgeMessages.toSet());
      expect(html, contains("window.addEventListener('error'"));
      expect(html, contains('unhandledrejection'));
      expect(html, contains('window.$video3dPreviewController'));
    });

    test('最小渲染循环：rAF 播放头 + Canvas 投影 + seek 按帧重绘', () {
      final String html = _html();
      expect(html, contains('requestAnimationFrame'));
      expect(html, contains('cancelAnimationFrame'));
      expect(html, contains('canvas.getContext'));
      expect(html, contains('function renderFrame('));
      expect(html, contains('function play()'));
      expect(html, contains('function pause()'));
      expect(html, contains('function stopPlayback()'));
      expect(html, contains('function finishPlayback()'));
      expect(html, contains('function seek('));
      expect(html, contains('function seekFrame('));
      expect(html, contains('function projectPoint('));
      expect(html, contains('function cameraAt('));
      expect(html, contains('easeInOut'));
      // 帧号由整数帧表决定：不出现浮点拍点/墙钟。
      expect(html, contains('Math.floor'));
      expect(html, isNot(contains('setInterval')));
      expect(html, isNot(contains('setTimeout')));
    });

    test('ready 消息如实标注渲染器：两档都不冒充', () {
      final String html = _html();
      expect(video3dPreviewRenderer, 'canvas2d_deterministic');
      expect(video3dWebglRenderer, 'webgl_three_r160');
      expect(video3dBabylonRenderer, 'babylon_webgl_v9');
      // 无渲染库时 RENDERER 保持注入的降级标识；GL 变量存在但不会被赋值。
      expect(html, contains('var RENDERER = "canvas2d_deterministic";'));
      expect(html, contains('var GL = null;'));
      expect(html, contains('renderer: RENDERER'));
      // ready 的节点数/度量按渲染面如实取（three → Babylon → 兼容层）。
      expect(html, contains('scene_nodes: GL'));
      expect(html, contains('Number(BABYLON_RENDERER.meshCount) || 0'));
      expect(html, contains('scene_metrics: GL ? GL.metrics : null'));
      // 页面暴露 renderer 查询面，宿主/冒烟可以问「你到底用哪档」。
      expect(html, contains('renderer: function () { return RENDERER; }'));
    });
  });

  group('真 three 渲染面（WebGL）', () {
    test('threeSource 为空：页面只有 Canvas2D 路径（模块脚本自失活）', () {
      final String html = _html();
      // 没有注入命名空间：模块脚本只留 `typeof THREE === 'undefined'` 的早退。
      expect(html, isNot(contains('const THREE = {')));
      expect(html, contains("if (typeof THREE === 'undefined')"));
      // 渲染器标识以注入的降级值为准（GL 未被赋值时不会改写 RENDERER）。
      expect(html, contains('var RENDERER = "canvas2d_deterministic";'));
    });

    test('threeSource 非空：命名空间内联进模块作用域 + 如实渲染器标识', () {
      final String html = _html(three: _threeStub);
      expect(html, contains('const THREE = {'));
      // 出口改写按简写条目（`Vector3,`）聚成命名空间对象。
      expect(html, contains('Vector3,'));
      expect(html, contains(video3dWebglRenderer));
      expect(html, contains('new THREE.WebGLRenderer('));
      // 读回帧证据要靠它：渲染后 canvas 仍可 toDataURL。
      expect(html, contains('preserveDrawingBuffer: true'));
      // 场景函数同时进模块与经典脚本（两条执行面共用一份事实源）。
      expect('<script'.allMatches(html).length, 5);
    });

    test('threeSource 形状不对（无出口块）→ 显性抛错，不产出半成品', () {
      final models = _models();
      expect(
        () => assembleVideo3dPreview(
          models.scene,
          models.screenplay,
          runtimeSource: _runtimeStub,
          threeSource: 'const A = 1;',
        ),
        throwsA(
          isA<Video3dPlayerError>().having(
            (e) => e.code,
            'code',
            'video3d_three_module_invalid',
          ),
        ),
      );
    });

    test('threeSource 里的结束标签被转义，不破坏脚本块', () {
      final String hostileThree =
          'const A = 1; // </script> in comment\n'
          'export { A };\n';
      final String html = _html(three: hostileThree);
      expect(html, contains(r'<\/script>'));
      expect('<script'.allMatches(html).length, 5);
      expect('</script>'.allMatches(html).length, 5);
    });

    test('抓帧命令：capture(frame) 渲染后回传 evidence（渲染器 + PNG data URL）', () {
      final String html = _html(three: _threeStub);
      expect(html, contains('function captureFrame('));
      expect(html, contains('capture: captureFrame'));
      expect(html, contains("postMessage('evidence'"));
      // 回执里必须带帧号/渲染器/data URL（宿主按帧号配对，不猜）。
      expect(html, contains('data_url: dataUrl'));
      expect(html, contains('renderer: RENDERER'));
      // 没有像素时要如实报错，而不是回一个空白 PNG。
      expect(html, contains("postMessage('error', { message: 'evidence_empty' })"));
    });

  group('Babylon 共同托底（第三档渲染面）', () {
    test('babylonSource 为空：页面不内联 Babylon（只有 three/Canvas2D 两档）', () {
      final String html = _html();
      expect(html, isNot(contains('__BABYLON_STUB_MARKER__')));
      // 页面仍然认识这个兜底入口（只是没有产物可装）。
      expect(html, contains('typeof window.NAN_BABYLON.createVideoRenderer'));
    });

    test('babylonSource 非空：逐字内联 + 如实标识 + 选择顺序 three→Babylon→2D', () {
      final String html = _html(babylon: _babylonStub);
      expect(html, contains('__BABYLON_STUB_MARKER__'));
      expect(html, contains(video3dBabylonRenderer));
      // three 先、Babylon 次、Canvas2D 最后：同一 canvas 必须在取 2d 上下文前决定。
      expect(html, contains('if (!activeRenderer()) tryCreateBabylon();'));
      expect(html, contains('function activeRenderer()'));
      expect(html, contains('var BABYLON_RENDERER = null;'));
    });

    test('含 babylonSource 时仍是字节确定（同输入两次组装相同）', () {
      final String first = _html(babylon: _babylonStub);
      final String second = _html(babylon: _babylonStub);
      expect(first, second);
    });
  });

    test('含 threeSource 时仍是字节确定（同输入两次组装相同）', () {
      final String first = _html(three: _threeStub);
      final String second = _html(three: _threeStub);
      expect(first, second);
    });
  });

  group('运行时注入契约（缺失显性失败，不静默降级）', () {
    test('runtimeSource 为 null / 空串 / 空白 → 显性抛错', () {
      final models = _models();
      for (final String? missing in <String?>[null, '', '   ', '\n\t ']) {
        expect(
          () => assembleVideo3dPreview(
            models.scene,
            models.screenplay,
            runtimeSource: missing,
          ),
          throwsA(
            isA<Video3dPlayerError>().having(
              (error) => error.code,
              'code',
              video3dRuntimeMissingCode,
            ),
          ),
          reason:
              'runtimeSource=${missing == null ? 'null' : jsonEncode(missing)} '
              '必须显性失败',
        );
      }
    });

    test('runtime 文本逐字内嵌（仅做 </script 级转义）', () {
      final String html = _html();
      expect(html, contains(_runtimeStub));

      final String hostile = 'var __EVIL__ = "</script>";';
      final String hostileHtml = _html(runtime: hostile);
      // 注入的结束标签被转义，页面不会多出/提前关闭脚本块。
      expect(hostileHtml, isNot(contains('</script><script>')));
      expect(hostileHtml, contains(r'<\/script>'));
      expect('<script'.allMatches(hostileHtml).length, 5);
      expect('</script>'.allMatches(hostileHtml).length, 5);
    });

    test('镜头 id 里的 HTML 结束标签被 JSON 转义，不破坏内联脚本', () {
      final String evilId = '</script><script>alert(1)</script>';
      final String html = _html(
        screenplayRaw: _validScreenplay(firstShotId: evilId),
      );
      final String raw = _jsonLiteral(html, 'TIMELINE');
      expect(raw, isNot(contains('</script>')));
      expect(raw, isNot(contains('<script')));
      expect(raw, contains(r'\u003c'));
      expect('<script'.allMatches(html).length, 5);
      expect('</script>'.allMatches(html).length, 5);
      final decoded = jsonDecode(raw)! as Map<String, Object?>;
      final decodedShots = decoded['shots']! as List<Object?>;
      final decodedFirst = decodedShots.first! as Map<String, Object?>;
      expect(decodedFirst['id'], evilId);
      // 页面仍然有帧表与渲染循环。
      expect(html, contains('function renderFrame('));
    });
  });
}
