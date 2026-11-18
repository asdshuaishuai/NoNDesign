// 3D 本地面（批次 06）的契约测试。
//
// 覆盖三组不可回退的语义：
//  1. 规范先行：没有有效规范就没有项目目录（fail-closed）；
//  2. 六层状态机：build-state 是唯一权威，修复轮上限、阻塞、推进门、
//     证据门、损坏自愈、并发推进（stale）逐项断言；
//  3. 预览离线：宿主页 + 场景 + 渲染库同目录落盘，页面只允许相对路径。
//
// 模型调用注入假实现（不碰网络）；资源注入内存字节（不依赖 asset bundle）。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nondesign/core/platform_capabilities.dart';
import 'package:nondesign/core/three_service.dart';

const Map<String, dynamic> _validSpec = <String, dynamic>{
  'title': 'Saturn',
  'summary': '带环行星自转',
  'components': <Map<String, dynamic>>[
    <String, dynamic>{'id': 'planet', 'what': '球体', 'size_scale': 1.0},
    <String, dynamic>{'id': 'ring', 'what': '扁平圆环', 'size_scale': 1.8},
  ],
  'materials': <Map<String, dynamic>>[
    <String, dynamic>{'id': 'rock', 'color_hex': '#c9a06a', 'roughness': 0.8, 'metalness': 0.1},
  ],
  'camera': <String, dynamic>{'view': '略高处斜看'},
  'interactions': <String>['自转'],
  'acceptance': <String>['行星在场', '环可见', '整体可辨识'],
};

const String _sceneJs = '''
export default function build(THREE, scene, camera, controls, renderer) {
  const planet = new THREE.Mesh(
    new THREE.SphereGeometry(1, 24, 16),
    new THREE.MeshStandardMaterial({ color: 0xc9a06a }));
  scene.add(planet);
  return { metrics: { planet: true }, update(dt) { planet.rotation.y += dt; } };
}
''';

String _fence(String lang, String body) => '```$lang\n$body\n```';

/// 与锚点等长、且能被组装器理解的渲染库（一条收尾 export 语句）。
Uint8List fakeThreeModuleBytes() {
  const head = 'const REVISION = "160";\n'
      'const Scene = class Scene {};\n'
      'const Mesh = class Mesh {};\n'
      'const Vector3 = class Vector3 {};\n';
  const tail = 'export { REVISION, Scene, Mesh, Vector3 };\n';
  const wrapperOverhead = '/*'.length + '*/'.length;
  final pad = threeModuleByteLength - head.length - tail.length - wrapperOverhead;
  return Uint8List.fromList(utf8.encode('$head/*${'x' * pad}*/$tail'));
}

/// 一张 1×1 PNG（最小合法字节，用于证据落盘）。
final Uint8List _pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

/// 假模型：按队列返回，同时记录每次请求（提示词断言用）。
class _FakeLlm {
  _FakeLlm(this._replies);

  final List<String> _replies;
  final List<ThreeLlmRequest> requests = <ThreeLlmRequest>[];

  int get calls => requests.length;

  Future<String> call(ThreeLlmRequest request) async {
    requests.add(request);
    if (_replies.isEmpty) throw StateError('fake llm: no reply left');
    return _replies.removeAt(0);
  }
}

/// 极小的 ThreeUI 清单（真实资源校验在 three_threeui_test.dart）。
const String _fakeThreeUiCatalog = '''
{"version":1,"components":[
{"id":"spark-badge","name":"火花徽章","description":"一枚会发光的徽章","file":"spark-badge.html","hint":"暗底"}
]}
''';

/// 假资源：宿主页模板 + 与锚点等长的渲染库（长度校验必须过）。
class _FakeAssets {
  _FakeAssets({String? template}) : template = template ?? _template;

  final String template;
  int loads = 0;

  static const String _template = '''
<!DOCTYPE html><html><body>
<script type="module">
/*__THREE_MODULE__*/
/*__SCENE_SOURCE__*/
window.NON3D.postMessage(JSON.stringify({kind:'metrics', payload:{}}));
</script></body></html>
''';

  Future<Uint8List> load(String key) async {
    loads++;
    if (key == threePreviewAssetKey) return Uint8List.fromList(utf8.encode(template));
    if (key == threeModuleAssetKey) return fakeThreeModuleBytes();
    if (key == threeLiveAssetKey) {
      return Uint8List.fromList(utf8.encode('/* three-live vendor (fake) */'));
    }
    if (key == threeUiCatalogAssetKey) {
      return Uint8List.fromList(utf8.encode(_fakeThreeUiCatalog));
    }
    throw ThreeFailure('asset_missing', key);
  }
}

class _Harness {
  _Harness(this.root, this.service, this.llm, this.assets);

  final Directory root;
  final ThreeService service;
  final _FakeLlm llm;
  final _FakeAssets assets;

  File stateFile(String name) => File('${root.path}/$name/build-state.json');
  File specFile(String name) => File('${root.path}/$name/three-spec.json');
  File sceneFile(String name) => File('${root.path}/$name/scene.js');

  Map<String, dynamic> state(String name) =>
      (jsonDecode(stateFile(name).readAsStringSync()) as Map).cast<String, dynamic>();

  List<Map<String, dynamic>> history(String name) {
    final file = File('${root.path}/$name/history.jsonl');
    if (!file.existsSync()) return const <Map<String, dynamic>>[];
    return file
        .readAsStringSync()
        .split('\n')
        .where((l) => l.trim().isNotEmpty)
        .map((l) => (jsonDecode(l) as Map).cast<String, dynamic>())
        .toList();
  }

  Map<String, dynamic> pass(String name, String id) => (state(name)['passes'] as List)
      .cast<Map>()
      .firstWhere((p) => p['id'] == id)
      .cast<String, dynamic>();
}

_Harness _harness({List<String>? replies, String? template}) {
  final root = Directory.systemTemp.createTempSync('three_service_test');
  addTearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });
  final llm = _FakeLlm(replies ?? <String>[_fence('json', jsonEncode(_validSpec))]);
  final assets = _FakeAssets(template: template);
  final service = ThreeService(root: root, llm: llm.call, assets: assets.load);
  return _Harness(root, service, llm, assets);
}

ThreeLlmConfig get _config =>
    const ThreeLlmConfig(model: 'test-model', baseUrl: 'https://api.example.com/v1', apiKey: 'k');

Future<ThreeProjectSnapshot> _newProject(_Harness h, {String name = 'saturn-demo'}) =>
    h.service.newProject(name: name, brief: '带环行星自转', config: _config);

void main() {
  group('规范先行', () {
    test('新建：规范落盘 + 初始进度 + 记账，目录在成功之后才出现', () async {
      final h = _harness();
      expect(Directory('${h.root.path}/saturn-demo').existsSync(), isFalse);

      final snapshot = await _newProject(h);

      expect(snapshot.name, 'saturn-demo');
      expect(snapshot.spec['title'], 'Saturn');
      expect(h.specFile('saturn-demo').existsSync(), isTrue);
      expect(h.state('saturn-demo')['current'], 'blockout');
      expect(h.history('saturn-demo').map((e) => e['action']), contains('new'));
      expect(snapshot.history.map((e) => e['action']), contains('new'));
    });

    test('没有 components/acceptance 的规范被拒绝，且不留半成品目录', () async {
      final h = _harness(replies: <String>[
        _fence('json', jsonEncode({'title': 'x', 'components': <dynamic>[], 'acceptance': <dynamic>[]})),
      ]);
      await expectLater(
        _newProject(h),
        throwsA(isA<ThreeFailure>().having((f) => f.code, 'code', 'spec_invalid')),
      );
      expect(Directory('${h.root.path}/saturn-demo').existsSync(), isFalse);
    });

    test('模型返回非 JSON：spec_parse_failed，且不留目录', () async {
      final h = _harness(replies: <String>['我觉得这个场景应该很酷']);
      await expectLater(
        _newProject(h),
        throwsA(isA<ThreeFailure>().having((f) => f.code, 'code', 'spec_parse_failed')),
      );
      expect(Directory('${h.root.path}/saturn-demo').existsSync(), isFalse);
    });

    test('同名项目被拒绝（不覆盖既有规范与进度）', () async {
      final h = _harness(replies: <String>[
        _fence('json', jsonEncode(_validSpec)),
        _fence('json', jsonEncode(_validSpec)),
      ]);
      await _newProject(h);
      await expectLater(
        _newProject(h),
        throwsA(isA<ThreeFailure>().having((f) => f.code, 'code', 'project_exists')),
      );
    });

    test('名称白名单：中文 / 路径穿越 / 空串一律拒绝', () async {
      final h = _harness();
      for (final bad in <String>['', '土星', '../escape', 'a/b', 'a b']) {
        await expectLater(
          h.service.newProject(name: bad, brief: 'x', config: _config),
          throwsA(isA<ThreeFailure>().having((f) => f.code, 'code', 'invalid_name')),
          reason: 'name=$bad',
        );
      }
    });
  });

  group('六层状态机', () {
    test('初始进度：六层顺序固定，全部待生成，上限 3', () async {
      final h = _harness();
      await _newProject(h);
      final state = h.state('saturn-demo');
      expect(state['loop_max'], threeLoopMax);
      expect(state['blocked'], isFalse);
      final passes = (state['passes'] as List).cast<Map>();
      expect(passes.map((p) => p['id']).toList(), threePasses.map((p) => p.id).toList());
      expect(passes.every((p) => p['status'] == 'pending' && p['attempts'] == 0), isTrue);
      expect(passes.every((p) => (p['evidence'] as List).isEmpty), isTrue);
    });

    test('生成当前层：写场景代码、标 generated、记账，提示词带规范与当前层', () async {
      final h = _harness(replies: <String>[
        _fence('json', jsonEncode(_validSpec)),
        _fence('js', _sceneJs),
      ]);
      await _newProject(h);

      final result = await h.service.runPass('saturn-demo', _config);

      expect(result.pass, 'blockout');
      expect(result.stale, isFalse);
      expect(result.state['current'], 'blockout');
      expect(h.sceneFile('saturn-demo').readAsStringSync(), contains('export default'));
      expect(h.pass('saturn-demo', 'blockout')['status'], 'generated');
      expect(h.history('saturn-demo').map((e) => e['action']), contains('generate'));

      final prompt = h.llm.requests.last.prompt;
      expect(prompt, contains('# 规格（three-spec.json）'));
      expect(prompt, contains('Saturn'));
      expect(prompt, contains('# 当前 pass：blockout'));
      expect(prompt, contains(threePassGoal('blockout')));
      expect(prompt, contains('修复轮：0/3'));
      expect(prompt, contains('# 尚无代码——从本 pass 起步。'));
      expect(h.llm.requests.last.system, contains('export default function build'));
      expect(h.llm.requests.last.system, contains('只实现/完善当前 pass 的层'));
    });

    test('await 期间进度被推进：代码落盘但状态不被旧快照改写（stale）', () async {
      final h = _harness(replies: <String>[_fence('json', jsonEncode(_validSpec))]);
      await _newProject(h);
      // 假模型在「生成」的 await 窗口里把进度推进到下一层：模拟并发的推进。
      final advanced = <String>[];
      final service = ThreeService(
        root: h.root,
        assets: h.assets.load,
        llm: (request) async {
          advanced.add(request.prompt);
          final state = h.state('saturn-demo');
          for (final pass in (state['passes'] as List).cast<Map>()) {
            if (pass['id'] == 'blockout') {
              pass['status'] = 'verified';
              pass['evidence'] = <String>['blockout-turn-0-01.png'];
            }
          }
          state['current'] = 'structure';
          h.stateFile('saturn-demo').writeAsStringSync(jsonEncode(state));
          return _fence('js', _sceneJs);
        },
      );

      final result = await service.runPass('saturn-demo', _config);

      expect(result.stale, isTrue);
      expect(result.pass, 'blockout');
      expect(h.state('saturn-demo')['current'], 'structure');
      expect(h.pass('saturn-demo', 'structure')['status'], 'pending', reason: '不得把别的层标成已生成');
      expect(h.sceneFile('saturn-demo').readAsStringSync(), contains('export default'));
      expect(h.history('saturn-demo').any((e) => e['stale'] == true), isTrue);
    });

    test('已生成且未失败：先看预览收集反馈，拒绝重复生成', () async {
      final h = _harness(replies: <String>[
        _fence('json', jsonEncode(_validSpec)),
        _fence('js', _sceneJs),
      ]);
      await _newProject(h);
      await h.service.runPass('saturn-demo', _config);

      await expectLater(
        h.service.runPass('saturn-demo', _config),
        throwsA(isA<ThreeFailure>().having((f) => f.code, 'code', 'pass_awaiting_feedback')),
      );
    });

    test('修复轮达上限：落盘 blocked 并拒绝继续生成', () async {
      final h = _harness(replies: <String>[
        _fence('json', jsonEncode(_validSpec)),
        for (var i = 0; i < threeLoopMax; i++) _fence('js', _sceneJs),
      ]);
      await _newProject(h);
      for (var i = 0; i < threeLoopMax; i++) {
        await h.service.feedback('saturn-demo', 'error', 'boom-$i');
        if (i < threeLoopMax - 1) await h.service.runPass('saturn-demo', _config);
      }

      final state = h.state('saturn-demo');
      expect(state['blocked'], isTrue);
      expect(h.pass('saturn-demo', 'blockout')['status'], 'blocked');
      expect(h.pass('saturn-demo', 'blockout')['attempts'], threeLoopMax);

      await expectLater(
        h.service.runPass('saturn-demo', _config),
        throwsA(isA<ThreeFailure>().having((f) => f.code, 'code', 'blocked')),
      );
      expect(h.history('saturn-demo').map((e) => e['action']), contains('blocked'));
    });

    test('错误反馈：修复轮 +1、状态转失败、留最近一次原始信息', () async {
      final h = _harness();
      await _newProject(h);

      final result = await h.service.feedback('saturn-demo', 'error', 'TypeError: x is undefined');

      expect(result.status, 'failed');
      expect(result.attempts, 1);
      expect(h.pass('saturn-demo', 'blockout')['status'], 'failed');
      expect(h.pass('saturn-demo', 'blockout')['last_error'], contains('TypeError'));
      expect(h.pass('saturn-demo', 'blockout')['attempts'], 1);
    });

    test('测量反馈：只记账，不改状态与修复轮', () async {
      final h = _harness();
      await _newProject(h);

      final result = await h.service.feedback('saturn-demo', 'metrics', <String, dynamic>{'meshes': 3});

      expect(result.status, 'metrics-ok');
      expect(result.attempts, 0);
      expect(h.pass('saturn-demo', 'blockout')['status'], 'pending');
      final entry = h.history('saturn-demo').last;
      expect(entry['kind'], 'metrics');
      expect('${entry['summary']}', contains('meshes'));
    });

    test('截图证据：按层/方位/序号落盘，有生成痕迹才把状态转 generated', () async {
      final h = _harness(replies: <String>[
        _fence('json', jsonEncode(_validSpec)),
        _fence('js', _sceneJs),
      ]);
      await _newProject(h);
      await h.service.runPass('saturn-demo', _config);

      final dataUrl = 'data:image/png;base64,${base64Encode(_pngBytes)}';
      final first = await h.service.feedback(
        'saturn-demo',
        'screenshot',
        <String, dynamic>{'data': dataUrl, 'tag': 'turn-90'},
      );

      expect(first.status, 'evidence-ok');
      final evidenceDir = Directory('${h.root.path}/saturn-demo/evidence');
      final files = evidenceDir.listSync().whereType<File>().map((f) => f.path).toList();
      expect(files, hasLength(1));
      expect(files.single, endsWith('blockout-turn-90-01.png'));
      expect(File(files.single).readAsBytesSync(), _pngBytes);
      expect(h.pass('saturn-demo', 'blockout')['evidence'], <String>['blockout-turn-90-01.png']);
      expect(h.pass('saturn-demo', 'blockout')['status'], 'generated');
    });

    test('骨架页的截图不算生成痕迹：只记证据，不点亮推进门', () async {
      final h = _harness();
      await _newProject(h);
      // 场景文件还没生成（没有 scene.js）：骨架页截图不得把状态转 generated。
      final result = await h.service.feedback(
        'saturn-demo',
        'screenshot',
        <String, dynamic>{'data': base64Encode(_pngBytes), 'tag': 'shot'},
      );
      expect(result.status, 'evidence-ok');
      expect(h.pass('saturn-demo', 'blockout')['status'], 'pending');
      expect(h.pass('saturn-demo', 'blockout')['evidence'], hasLength(1));
    });

    test('推进门：没有证据不能推进；最后一层通过即完成', () async {
      final h = _harness(replies: <String>[
        _fence('json', jsonEncode(_validSpec)),
        for (var i = 0; i < threePasses.length; i++) _fence('js', _sceneJs),
      ]);
      await _newProject(h);

      // 状态还是 pending：直接推进被拒。
      await expectLater(
        h.service.continuePass('saturn-demo'),
        throwsA(isA<ThreeFailure>().having((f) => f.code, 'code', 'cannot_continue')),
      );

      for (var i = 0; i < threePasses.length; i++) {
        await h.service.runPass('saturn-demo', _config);
        await h.service.feedback(
          'saturn-demo',
          'screenshot',
          <String, dynamic>{'data': base64Encode(_pngBytes), 'tag': 'shot'},
        );
        final result = await h.service.continuePass('saturn-demo', 'reviewed');
        final isLast = i == threePasses.length - 1;
        expect(result.done, isLast);
        expect(result.current, isLast ? 'done' : threePasses[i + 1].id);
      }

      expect(h.state('saturn-demo')['current'], 'done');
      await expectLater(
        h.service.runPass('saturn-demo', _config),
        throwsA(isA<ThreeFailure>().having((f) => f.code, 'code', 'already_done')),
      );
    });

    test('规范回灌：解除阻塞、复位失败层计数并记账', () async {
      final h = _harness();
      await _newProject(h);
      for (var i = 0; i < threeLoopMax; i++) {
        await h.service.feedback('saturn-demo', 'error', 'boom-$i');
      }
      expect(h.state('saturn-demo')['blocked'], isTrue);

      final spec = Map<String, dynamic>.from(_validSpec)
        ..['acceptance'] = <String>['行星在场', '环可见'];
      final result = await h.service.saveSpec('saturn-demo', spec);

      expect(result.unblocked, isTrue);
      expect(h.state('saturn-demo')['blocked'], isFalse);
      expect(h.pass('saturn-demo', 'blockout')['attempts'], 0);
      expect(h.pass('saturn-demo', 'blockout')['status'], 'pending');
      expect(h.history('saturn-demo').map((e) => e['action']), contains('refine-spec'));
    });

    test('规范回灌缺 components/acceptance：拒绝且不动既有规范', () async {
      final h = _harness();
      await _newProject(h);
      final before = h.specFile('saturn-demo').readAsStringSync();

      await expectLater(
        h.service.saveSpec('saturn-demo', <String, dynamic>{'title': 'x'}),
        throwsA(isA<ThreeFailure>().having((f) => f.code, 'code', 'spec_invalid')),
      );
      expect(h.specFile('saturn-demo').readAsStringSync(), before);
    });

    test('进度文件损坏：备份 .bak、重置初始进度、记账', () async {
      final h = _harness();
      await _newProject(h);
      h.stateFile('saturn-demo').writeAsStringSync('{"current": "block');

      final snapshot = await h.service.readProject('saturn-demo');

      expect(snapshot.state['current'], 'blockout');
      expect(File('${h.stateFile('saturn-demo').path}.bak').existsSync(), isTrue);
      expect(h.history('saturn-demo').map((e) => e['action']), contains('state-corrupt-reset'));
      // 重置后的状态是合法 JSON，可继续推进。
      expect(h.state('saturn-demo')['current'], 'blockout');
    });

    test('规范文件损坏：如实报错，不静默清空', () async {
      final h = _harness();
      await _newProject(h);
      h.specFile('saturn-demo').writeAsStringSync('{not json');

      await expectLater(
        h.service.readProject('saturn-demo'),
        throwsA(isA<ThreeFailure>().having((f) => f.code, 'code', 'spec_corrupt')),
      );
      expect(h.specFile('saturn-demo').readAsStringSync(), '{not json');
    });

    test('列表：按名字排序、跳过非项目目录、损坏项目单独标记', () async {
      final h = _harness(replies: <String>[
        _fence('json', jsonEncode(_validSpec)),
        _fence('json', jsonEncode(_validSpec)),
      ]);
      await _newProject(h, name: 'zeta');
      await _newProject(h, name: 'alpha');
      Directory('${h.root.path}/not-a-project').createSync();
      h.stateFile('zeta').writeAsStringSync('gone');

      final entries = await h.service.listProjects();

      expect(entries.map((e) => e.name).toList(), <String>['alpha', 'zeta']);
      expect(entries.first.current, 'blockout');
      expect(entries.last.current, 'corrupt');
      expect(entries.last.blocked, isTrue);
    });

    test('删除：目录整体消失；不存在时报 no_project', () async {
      final h = _harness();
      await _newProject(h);
      await h.service.deleteProject('saturn-demo');
      expect(Directory('${h.root.path}/saturn-demo').existsSync(), isFalse);
      await expectLater(
        h.service.deleteProject('saturn-demo'),
        throwsA(isA<ThreeFailure>().having((f) => f.code, 'code', 'no_project')),
      );
    });
  });

  group('预览三件套（离线、同目录）', () {
    test('宿主页 + 场景 + 渲染库落在同一目录，页面自包含（file:// 可用）', () async {
      final h = _harness();
      await _newProject(h);

      final bundle = await h.service.preparePreview('saturn-demo');
      final dir = Directory('${h.root.path}/saturn-demo').path;

      expect(bundle.htmlPath, '$dir/preview.html');
      expect(bundle.scenePath, '$dir/scene.js');
      expect(bundle.modulePath, '$dir/three.module.js');
      expect(File(bundle.htmlPath).existsSync(), isTrue);
      expect(File(bundle.scenePath).existsSync(), isTrue);
      expect(File(bundle.modulePath).lengthSync(), threeModuleByteLength);

      final html = File(bundle.htmlPath).readAsStringSync();
      // 渲染库与场景都是内联的：页面不再发起任何文件/网络读取。
      expect(html, contains('const THREE = {'));
      expect(html, contains('__non3d_scene_build__'));
      expect(html, contains('const __non3d_scene_build__ = build;'));
      expect(html, isNot(contains('export {')));
      expect(html, isNot(contains('importmap')));
      expect(html, isNot(contains('http://')));
      expect(html, isNot(contains('https://')));
      expect(html.length, greaterThan(threeModuleByteLength), reason: '渲染库已内联');
      // 场景还不存在时落骨架，首帧不空白。
      final skeleton = File(bundle.scenePath).readAsStringSync();
      expect(skeleton, contains('GridHelper'));
      expect(html, contains('GridHelper'));
    });

    test('渲染库长度不符（资源被裁剪）：显性失败，不给白屏', () async {
      final root = Directory.systemTemp.createTempSync('three_service_assets');
      addTearDown(() => root.deleteSync(recursive: true));
      final service = ThreeService(
        root: root,
        llm: _FakeLlm(<String>[_fence('json', jsonEncode(_validSpec))]).call,
        assets: (key) async {
          if (key == threePreviewAssetKey) {
            return Uint8List.fromList(utf8.encode('<html>__SCENE_V__</html>'));
          }
          return Uint8List(16);
        },
      );
      await service.newProject(name: 'saturn-demo', brief: 'x', config: _config);

      await expectLater(
        service.preparePreview('saturn-demo'),
        throwsA(isA<ThreeFailure>().having((f) => f.code, 'code', 'asset_missing')),
      );
    });

    test('没有规范的项目不给预览页（no_project）', () async {
      final h = _harness();
      await expectLater(
        h.service.preparePreview('ghost'),
        throwsA(isA<ThreeFailure>().having((f) => f.code, 'code', 'no_project')),
      );
    });
  });

  group('预览组装（file:// 自包含）', () {
    test('渲染库出口语句被改写成 THREE 命名空间（含别名）', () {
      final source = 'const A = 1;\nconst B = 2;\nexport { A, B as Bee };\n';
      final out = threeModuleAsInlineNamespace(source);
      expect(out, contains('const THREE = {'));
      expect(out, contains('  A,'));
      expect(out, contains('  Bee: B,'));
      expect(out, isNot(contains('export {')));
    });

    test('没有出口语句的渲染库：显性失败（不生成残缺页面）', () {
      expect(
        () => threeModuleAsInlineNamespace('const A = 1;\n'),
        throwsA(isA<ThreeFailure>().having((f) => f.code, 'code', 'asset_missing')),
      );
    });

    test('场景：命名默认导出 → 同名函数；import 被剥掉', () {
      final scene = threeSceneAsInlineFunction(
        "import * as THREE from 'three';\n"
        'export default function build(THREE, scene) { return { metrics: { ok: true } }; }\n',
      );
      expect(scene.entry, 'build');
      expect(scene.source, contains('function build('));
      expect(scene.source, isNot(contains('import')));
      expect(scene.source, isNot(contains('export')));
    });

    test('场景：箭头默认导出 → __build；裸标识符也可用', () {
      final arrow = threeSceneAsInlineFunction(
        'export default (THREE, scene) => ({ metrics: { ok: true } });\n',
      );
      expect(arrow.entry, '__build');
      expect(arrow.source, contains('const __build ='));

      final ident = threeSceneAsInlineFunction(
        'function make() { return {}; }\nexport default make;\n',
      );
      expect(ident.entry, '__build');
      expect(ident.source, contains('const __build = make;'));
    });

    test('场景：类导出 / 残留 import / 额外 export 一律拒绝', () {
      for (final source in <String>[
        'export default class Scene {}\n',
        'import * as THREE from "three"\nexport default function build() {}\n',
        'export default function build() {}\nexport const extra = 1;\n',
        'const x = 1;\n',
      ]) {
        expect(
          () => threeSceneAsInlineFunction(source),
          throwsA(isA<ThreeFailure>().having((f) => f.code, 'code', 'code_parse_failed')),
          reason: source,
        );
      }
    });

    test('模板缺占位：显性失败，不产出半成品页面', () {
      expect(
        () => assembleThreePreview(
          template: '<html></html>',
          threeSource: 'const A = 1;\nexport { A };\n',
          sceneSource: 'export default function build() {}\n',
          version: 1,
        ),
        throwsA(isA<ThreeFailure>().having((f) => f.code, 'code', 'asset_missing')),
      );
    });

    test('组装结果：模块作用域里同时有 THREE 与可调用的构建函数', () {
      final html = assembleThreePreview(
        template: '<script type="module">/*__THREE_MODULE__*/\n/*__SCENE_SOURCE__*/\n</script>',
        threeSource: 'const Scene = class {};\nexport { Scene };\n',
        sceneSource: 'export default function build(THREE) { return { metrics: { ok: !!THREE.Scene } }; }\n',
        version: 42,
      );
      expect(html, contains('const THREE = {'));
      expect(html, contains('function build(THREE)'));
      expect(html, contains('const __non3d_scene_build__ = build;'));
      expect(html, contains('// build 42'));
      expect(html, isNot(contains('export default')));
    });
  });

  group('模型方言（逐字移植）', () {
    test('思考等级只认 low/medium/high，其余不注入', () {
      expect(threeReasoningEffort('low'), 'low');
      expect(threeReasoningEffort('medium'), 'medium');
      expect(threeReasoningEffort('high'), 'high');
      for (final other in <String>['', 'auto', 'off', 'on', 'max', 'HIGH', 'none']) {
        expect(threeReasoningEffort(other), isNull, reason: other);
        expect(threeProviderOptions(other), isNull, reason: other);
      }
      expect(threeProviderOptions('high'), <String, Map<String, dynamic>>{
        'openai': <String, dynamic>{'reasoning_effort': 'high'},
      });
    });

    test('JSON 提取：围栏 / 裸 JSON / 花括号夹在散文里都能取到', () async {
      for (final reply in <String>[
        _fence('json', jsonEncode(_validSpec)),
        jsonEncode(_validSpec),
        '好的，规范如下：${jsonEncode(_validSpec)} 请查收。',
      ]) {
        final root = Directory.systemTemp.createTempSync('three_service_json');
        addTearDown(() => root.deleteSync(recursive: true));
        final service = ThreeService(
          root: root,
          llm: _FakeLlm(<String>[reply]).call,
          assets: _FakeAssets().load,
        );
        final snapshot = await service.newProject(name: 'saturn', brief: 'x', config: _config);
        expect(snapshot.spec['title'], 'Saturn', reason: reply);
      }
    });

    test('代码提取：没有 export default 即拒绝，不写半截场景', () async {
      final h = _harness(replies: <String>[
        _fence('json', jsonEncode(_validSpec)),
        '这里是一段伪代码',
      ]);
      await _newProject(h);
      await expectLater(
        h.service.runPass('saturn-demo', _config),
        throwsA(isA<ThreeFailure>().having((f) => f.code, 'code', 'code_parse_failed')),
      );
      expect(h.sceneFile('saturn-demo').existsSync(), isFalse);
    });

    test('连接参数不全：直接失败，不发起请求', () async {
      final h = _harness();
      await expectLater(
        h.service.newProject(
          name: 'saturn-demo',
          brief: 'x',
          config: const ThreeLlmConfig(model: 'm', baseUrl: '', apiKey: ''),
        ),
        throwsA(isA<ThreeFailure>().having((f) => f.code, 'code', 'llm_error')),
      );
      expect(h.llm.calls, 0);
    });
  });

  group('用户可见文案', () {
    test('失败映射是人话：不出现实现名与裸错误码', () {
      const banned = <String>[
        'engine', 'wasm', 'moonviz', 'server', 'python', 'localhost', 'sqlite',
        '_failed', '_error', '_invalid', 'spec_', 'llm_', 'state_',
      ];
      for (final code in <String>[
        'invalid_name', 'project_exists', 'no_project', 'brief_empty', 'spec_invalid',
        'spec_parse_failed', 'spec_corrupt', 'code_parse_failed', 'state_corrupt',
        'blocked', 'already_done', 'pass_awaiting_feedback', 'cannot_continue',
        'evidence_invalid', 'invalid_feedback_kind', 'llm_error', 'asset_missing',
        'something_new',
      ]) {
        final message = threeFailureMessage(ThreeFailure(code));
        expect(message.trim(), isNotEmpty);
        expect(RegExp(r'^[a-z0-9]+(_[a-z0-9]+)+$').hasMatch(message), isFalse, reason: code);
        for (final word in banned) {
          expect(message.toLowerCase(), isNot(contains(word)), reason: '$code ← $word');
        }
      }
    });

    test('层名是中文短语，未知 id 不把内部代号漏出去', () {
      expect(threePassLabel('blockout'), '占位');
      expect(threePassLabel('interaction'), '交互');
      expect(threePassLabel('done'), '完成');
      expect(threePassLabel('mystery_pass'), isNot(contains('mystery')));
    });
  });

  group('文件管理能力', () {
    test('没有文件管理器的平台直接返回 false（不尝试进程调用）', () async {
      final dir = Directory.systemTemp.createTempSync('three_reveal');
      addTearDown(() => dir.deleteSync(recursive: true));
      final ok = await revealThreeProject(
        dir.path,
        host: PlatformCapabilities.forOs(HostOs.ios),
      );
      expect(ok, isFalse);
    });

    test('目录不在场时返回 false（不假装成功）', () async {
      final ok = await revealThreeProject(
        '/nonexistent/three-project-xyz',
        host: PlatformCapabilities.forOs(HostOs.macos),
      );
      expect(ok, isFalse);
    });
  });
}
