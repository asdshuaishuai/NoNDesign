// 3D 项目接入单一容器（`nan.pack/1`）的契约测试：导出 / 导入 / 列表。
//
// 覆盖本任务不可回退的语义：
//  1. 导出：项目目录 → `<根>/<name>.n3d`，容器含 `three-spec.json` /
//     `scene.js` 等源码文本、规范 JSON 与 docs 正文；进度（build-state）/
//     记账（history）/ 证据 / 派生预览件 / 备份残留一律不进容器；
//  2. 往返：导出 → 删项目目录 → 导入 → `readProject` 的规范 / 场景代码 /
//     初始进度与原始一致（进度不是容器事实源，按初始重置）；
//  3. 目标已存在拒绝覆盖（`pack_target_exists`），旧项目文件字节不变；
//  4. 坏包 / 版本不支持 / 校验和不符 / 错 kind / 包内名不合白名单 / 路径
//     冲突都显性失败：目标不出现、不留暂存目录、不碰既有项目；
//  5. listPacks 只列合法项目名的 `.n3d`，按文件名排序，不影响 listProjects。
//
// 一律注入临时目录 + 假模型 / 资源桩：不碰真实用户项目目录、不依赖 asset
// bundle，也不构造 WebView。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nondesign/core/three_service.dart';
import 'package:nondesign/core/workbench_pack.dart';
import 'package:nondesign/core/workbench_pack_io.dart';

// ---------------------------------------------------------------------------
// Fixtures / 注入
// ---------------------------------------------------------------------------

const Map<String, dynamic> _validSpec = <String, dynamic>{
  'title': 'Saturn',
  'summary': '带环行星自转',
  'components': <Map<String, dynamic>>[
    <String, dynamic>{'id': 'planet', 'what': '球体', 'size_scale': 1.0},
    <String, dynamic>{'id': 'ring', 'what': '扁平圆环', 'size_scale': 1.8},
  ],
  'materials': <Map<String, dynamic>>[
    <String, dynamic>{
      'id': 'rock',
      'color_hex': '#c9a06a',
      'roughness': 0.8,
      'metalness': 0.1,
    },
  ],
  'camera': <String, dynamic>{'view': '略高处斜看'},
  'interactions': <String>['自转'],
  'acceptance': <String>['行星在场', '环可见', '整体可辨识'],
};

const String _sceneJs = '''
export default function build(THREE, scene, camera, controls, renderer) {
  const planet = new THREE.Mesh(new THREE.SphereGeometry(1, 24, 16));
  scene.add(planet);
  return { metrics: { planet: true }, update(dt) { planet.rotation.y += dt; } };
}
''';

const String _docsText = '# Saturn\n\n带环行星，自转展示。\n';

String _fence(String lang, String body) => '```$lang\n$body\n```';

/// 一张 1×1 PNG（最小合法字节；证据是二进制产物，导出时必须被跳过）。
final Uint8List _pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

/// 假模型：按队列返回；导出 / 导入不调模型，只有 newProject 要一份规范。
class _FakeLlm {
  _FakeLlm(this._replies);

  final List<String> _replies;

  Future<String> call(ThreeLlmRequest request) async {
    if (_replies.isEmpty) throw StateError('fake llm: no reply left');
    return _replies.removeAt(0);
  }
}

/// 资源桩：打包链路不读应用资源；真被读到即显性失败（不依赖 asset bundle）。
Future<Uint8List> _assetStub(String key) async {
  throw ThreeFailure('asset_missing', 'pack test must not load assets: $key');
}

ThreeLlmConfig get _config => const ThreeLlmConfig(
  model: 'test-model',
  baseUrl: 'https://api.example.com/v1',
  apiKey: 'k',
);

String _leafName(String path) {
  final List<String> segments = path
      .replaceAll('\\', '/')
      .split('/')
      .where((String segment) => segment.isNotEmpty)
      .toList(growable: false);
  return segments.isEmpty ? path : segments.last;
}

/// 项目目录逐文件字节快照（相对 POSIX 路径 → 字节），用于断言「旧项目字节
/// 不变」。
Map<String, List<int>> _directoryBytes(Directory dir) {
  final Map<String, List<int>> out = <String, List<int>>{};
  if (!dir.existsSync()) return out;
  for (final FileSystemEntity entity in dir.listSync(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is! File) continue;
    final String relative = entity.path
        .substring(dir.path.length)
        .replaceAll('\\', '/')
        .replaceFirst(RegExp(r'^/'), '');
    out[relative] = entity.readAsBytesSync();
  }
  return out;
}

/// 项目根下的暂存 / 现场编辑临时残留（`.xxx.<stamp>.tmp`）。
List<String> _tempEntries(Directory root) {
  if (!root.existsSync()) return const <String>[];
  return root
      .listSync(followLinks: false)
      .map((FileSystemEntity entity) => _leafName(entity.path))
      .where((String leaf) => leaf.startsWith('.') && leaf.endsWith('.tmp'))
      .toList(growable: false);
}

/// 把合法容器的 CRC32 行改成一个不相等的值（模拟传输损坏 / 篡改）。
String _corruptChecksum(String text) {
  final List<String> lines = text.trimRight().split('\n');
  expect(lines, hasLength(3), reason: '容器固定三行');
  expect(lines[2], startsWith(workbenchPackChecksumPrefix));
  final int checksum = int.parse(
    lines[2].substring(workbenchPackChecksumPrefix.length),
    radix: 16,
  );
  final String wrong = (checksum ^ 0x1).toRadixString(16).padLeft(8, '0');
  return '${lines[0]}\n${lines[1]}\n$workbenchPackChecksumPrefix$wrong\n';
}

Matcher _throwsPackFailure(String code) => throwsA(
  isA<WorkbenchPackFailure>().having(
    (WorkbenchPackFailure failure) => failure.code,
    'code',
    code,
  ),
);

Matcher _throwsThreeFailure(String code) => throwsA(
  isA<ThreeFailure>().having(
    (ThreeFailure failure) => failure.code,
    'code',
    code,
  ),
);

class _Harness {
  _Harness(this.root, this.service, this.llm);

  final Directory root;
  final ThreeService service;
  final _FakeLlm llm;

  Directory dir(String name) => Directory('${root.path}/$name');
  File specFile(String name) => File('${dir(name).path}/three-spec.json');
  File sceneFile(String name) => File('${dir(name).path}/scene.js');
  File packFile(String name) => File('${root.path}/$name.n3d');

  Future<ThreeProjectSnapshot> newProject({String name = 'saturn-demo'}) =>
      service.newProject(name: name, brief: '带环行星自转', config: _config);

  void writeScene(String name, [String source = _sceneJs]) =>
      sceneFile(name).writeAsStringSync(source);

  void writeDocs(String name, [String text = _docsText]) =>
      File('${dir(name).path}/docs.md').writeAsStringSync(text);
}

_Harness _harness({List<String>? replies}) {
  final Directory root = Directory.systemTemp.createTempSync('three_pack_test');
  addTearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });
  final _FakeLlm llm = _FakeLlm(
    replies ?? <String>[_fence('json', jsonEncode(_validSpec))],
  );
  final ThreeService service = ThreeService(
    root: root,
    llm: llm.call,
    assets: _assetStub,
  );
  return _Harness(root, service, llm);
}

void main() {
  group('导出（项目目录 → .n3d）', () {
    test('导出：生成 <根>/<name>.n3d，含规范 / 场景源码 / 文档，title 取规范标题', () async {
      final _Harness h = _harness();
      await h.newProject();
      h.writeScene('saturn-demo');
      h.writeDocs('saturn-demo');

      final File file = await h.service.exportPack('saturn-demo');

      expect(file.existsSync(), isTrue);
      expect(file.path, '${h.root.path}/saturn-demo.n3d');
      expect(_leafName(file.path), 'saturn-demo.n3d');
      expect(_tempEntries(h.root), isEmpty, reason: '原子写不留下临时文件');

      final WorkbenchPack pack = await WorkbenchPack.readFrom(file);
      expect(pack.kind, WorkbenchPackKind.three);
      expect(pack.kind.wire, 'three');
      expect(pack.extension, '.n3d');
      expect(pack.name, 'saturn-demo');
      expect(pack.title, 'Saturn', reason: 'title 取 three-spec.json 的 title');
      expect(pack.docs, _docsText);
      expect(
        pack.files.keys,
        unorderedEquals(<String>['three-spec.json', 'scene.js', 'docs.md']),
      );
      expect(pack.files['scene.js'], _sceneJs);
      expect(
        pack.files['three-spec.json'],
        h.specFile('saturn-demo').readAsStringSync(),
      );

      final Object? spec = pack.spec;
      expect(spec, isA<Map>());
      expect((spec! as Map<String, Object?>)['title'], 'Saturn');
      expect((spec as Map<String, Object?>)['components'], isA<List>());
    });

    test('导出只收源码：进度 / 记账 / 证据 / 派生预览件 / 备份残留都不进容器', () async {
      final _Harness h = _harness();
      await h.newProject();
      h.writeScene('saturn-demo');

      // 运行痕迹：测量产物、截图证据、派生预览件、进度备份、原子写残留。
      await h.service.feedback('saturn-demo', 'metrics', <String, dynamic>{
        'meshes': 3,
      });
      final String projectPath = h.dir('saturn-demo').path;
      final Directory evidence = Directory('$projectPath/evidence')
        ..createSync(recursive: true);
      File('${evidence.path}/blockout-shot-01.png').writeAsBytesSync(_pngBytes);
      File('$projectPath/preview.html').writeAsStringSync('<html>预览</html>');
      File('$projectPath/three.module.js').writeAsStringSync('// 渲染库副本');
      File('$projectPath/build-state.json.bak').writeAsStringSync('{}');
      File('$projectPath/three-spec.json.123.tmp').writeAsStringSync('{}');

      expect(File('$projectPath/build-state.json').existsSync(), isTrue);
      expect(File('$projectPath/history.jsonl').existsSync(), isTrue);
      expect(
        File('$projectPath/artifacts/measurement.json').existsSync(),
        isTrue,
      );

      final WorkbenchPack pack = await WorkbenchPack.readFrom(
        await h.service.exportPack('saturn-demo'),
      );

      // 新项目目录里可打包的源码只有这两份：任何运行痕迹都不在 files 里。
      expect(
        pack.files.keys,
        unorderedEquals(<String>['three-spec.json', 'scene.js']),
      );
      final List<String> keys = pack.files.keys.toList(growable: false);
      for (final String excluded in <String>[
        'build-state.json',
        'history.jsonl',
        'artifacts/measurement.json',
        'evidence/blockout-shot-01.png',
        'preview.html',
        'three.module.js',
        'build-state.json.bak',
        'three-spec.json.123.tmp',
      ]) {
        expect(keys, isNot(contains(excluded)), reason: excluded);
      }
      expect(keys.where((String key) => key.startsWith('artifacts/')), isEmpty);
      expect(keys.where((String key) => key.startsWith('evidence/')), isEmpty);
    });

    test('没有 three-spec.json 的项目（v2 工作区）：spec 为 null、标题回退项目名、源码照常打包', () async {
      final _Harness h = _harness();
      await h.newProject();
      // 模拟 v2 工作区：旧规范被移除，事实源是 spec.json / src/*.js。
      h.specFile('saturn-demo').deleteSync();
      File('${h.dir('saturn-demo').path}/spec.json')
          .writeAsStringSync('{"title":"Saturn v2"}');
      Directory('${h.dir('saturn-demo').path}/src').createSync(recursive: true);
      File('${h.dir('saturn-demo').path}/src/scene.js')
          .writeAsStringSync('export default function build() {}\n');

      final WorkbenchPack pack = await WorkbenchPack.readFrom(
        await h.service.exportPack('saturn-demo'),
      );

      expect(pack.spec, isNull);
      expect(pack.title, 'saturn-demo', reason: '没有规范标题时回退项目名');
      expect(
        pack.files.keys,
        containsAll(<String>['spec.json', 'src/scene.js']),
      );
      expect(pack.files['src/scene.js'], contains('export default'));
    });

    test('导出拒绝：项目不存在 / 空目录 / 非法项目名，不写任何容器', () async {
      final _Harness h = _harness();

      await expectLater(
        h.service.exportPack('ghost'),
        _throwsThreeFailure('no_project'),
      );

      // 只有目录、没有任何源码（只有进度 / 缓存也不算项目）：不产出空容器。
      h.dir('empty').createSync(recursive: true);
      await expectLater(
        h.service.exportPack('empty'),
        _throwsThreeFailure('no_project'),
      );

      for (final String bad in <String>['', '土星', '../escape', 'a/b']) {
        await expectLater(
          h.service.exportPack(bad),
          _throwsThreeFailure('invalid_name'),
          reason: 'name=<$bad>',
        );
      }
      expect(
        h.root.listSync().whereType<File>().where(
          (File file) => _leafName(file.path).endsWith('.n3d'),
        ),
        isEmpty,
      );
      expect(_tempEntries(h.root), isEmpty);
    });
  });

  group('往返 / 导入', () {
    test('往返：导出 → 删目录 → 导入 → readProject 的规范 / 场景 / 初始进度与原始一致', () async {
      final _Harness h = _harness();
      await h.newProject();
      h.writeScene('saturn-demo');

      final ThreeProjectSnapshot before = await h.service.readProject(
        'saturn-demo',
      );
      final String specText = h.specFile('saturn-demo').readAsStringSync();
      final File packFile = await h.service.exportPack('saturn-demo');

      await h.service.deleteProject('saturn-demo');
      expect(h.dir('saturn-demo').existsSync(), isFalse);

      await h.service.importPack(packFile);

      final ThreeProjectSnapshot after = await h.service.readProject(
        'saturn-demo',
      );
      expect(after.name, before.name);
      expect(after.spec, before.spec);
      expect(after.sceneJs, before.sceneJs);
      expect(after.state, before.state, reason: '全新项目的初始进度按原样重建');
      expect(after.dir, before.dir);

      // 规范文件与场景代码逐字节一致。
      expect(h.specFile('saturn-demo').readAsStringSync(), specText);
      expect(h.sceneFile('saturn-demo').readAsStringSync(), _sceneJs);

      // 进度 / 记账不是容器事实源：导入后从初始进度开始，历史为空。
      expect(after.history, isEmpty);
      expect(
        File('${h.dir('saturn-demo').path}/history.jsonl').existsSync(),
        isFalse,
      );
      // 导入的项目能被列表看见（进度权威文件已补齐）。
      final List<ThreeProjectEntry> entries = await h.service.listProjects();
      expect(entries.map((ThreeProjectEntry e) => e.name), <String>[
        'saturn-demo',
      ]);
      expect(entries.single.current, 'blockout');
    });

    test('目标已存在拒绝覆盖（pack_target_exists），旧项目文件字节不变', () async {
      final _Harness h = _harness();
      await h.newProject();
      h.writeScene('saturn-demo');
      h.writeDocs('saturn-demo');
      final File packFile = await h.service.exportPack('saturn-demo');
      final String packText = packFile.readAsStringSync();
      final Map<String, List<int>> beforeBytes = _directoryBytes(
        h.dir('saturn-demo'),
      );

      await expectLater(
        h.service.importPack(packFile),
        _throwsPackFailure(WorkbenchPackIoFailureCode.targetExists),
      );

      // 旧项目一个字节都没变；拒绝发生在碰磁盘之前，不留暂存目录。
      expect(_directoryBytes(h.dir('saturn-demo')), beforeBytes);
      expect(_tempEntries(h.root), isEmpty);
      expect(packFile.readAsStringSync(), packText, reason: '被拒导入不改动包本身');
    });

    test('坏包 / 版本不支持 / 校验和不符显性失败，目标不出现且不留暂存', () async {
      final _Harness h = _harness();
      await h.newProject();
      final File good = await h.service.exportPack('saturn-demo');
      await h.service.deleteProject('saturn-demo');
      final String goodText = good.readAsStringSync();

      // 不是容器（行数 / magic 都不对）。
      final File garbage = File('${h.root.path}/garbage.n3d')
        ..writeAsStringSync('不是容器');
      await expectLater(
        h.service.importPack(garbage),
        _throwsPackFailure(WorkbenchPackFailureCode.invalidContainer),
      );

      // 头部版本比实现新：显性拒绝，不猜兼容。
      final File future = File('${h.root.path}/future.n3d')
        ..writeAsStringSync(goodText.replaceFirst('nan.pack/1', 'nan.pack/2'));
      await expectLater(
        h.service.importPack(future),
        _throwsPackFailure(WorkbenchPackFailureCode.versionUnsupported),
      );

      // 校验和与 payload 不符（篡改 / 传输损坏）。
      final File tampered = File('${h.root.path}/tampered.n3d')
        ..writeAsStringSync(_corruptChecksum(goodText));
      await expectLater(
        h.service.importPack(tampered),
        _throwsPackFailure(WorkbenchPackFailureCode.checksumFailed),
      );

      expect(h.dir('saturn-demo').existsSync(), isFalse);
      expect(_tempEntries(h.root), isEmpty);
    });

    test('错 kind 显性失败（pack_kind_mismatch），目标不出现', () async {
      final _Harness h = _harness();
      // 一份合法的音乐容器：3D 工作台必须拒绝，不把内容写进任何目录。
      final Directory source = Directory('${h.root.path}/music-src')
        ..createSync(recursive: true);
      File('${source.path}/score.json')
          .writeAsStringSync('{"schemaVersion":1}');
      final File musicPack = await exportProjectPack(
        kind: 'music',
        projectDir: source,
        name: 'melody',
        title: '练习曲',
      );
      expect(_leafName(musicPack.path), 'melody.nmu');

      await expectLater(
        h.service.importPack(musicPack),
        _throwsPackFailure(WorkbenchPackIoFailureCode.kindMismatch),
      );
      expect(h.dir('melody').existsSync(), isFalse);
      expect(_tempEntries(h.root), isEmpty);
    });

    test('包内项目名不合白名单 → invalid_name，不建目标目录', () async {
      final _Harness h = _harness();
      final File nonAscii = File('${h.root.path}/中文.n3d');
      await WorkbenchPack(
        kind: WorkbenchPackKind.three,
        name: '土星',
        title: '土星',
        files: <String, String>{'scene.js': _sceneJs},
      ).writeTo(nonAscii);

      await expectLater(
        h.service.importPack(nonAscii),
        _throwsThreeFailure('invalid_name'),
      );
      expect(h.dir('土星').existsSync(), isFalse);
      expect(_tempEntries(h.root), isEmpty);
    });

    test('导入失败不留半成品：路径冲突包显性失败，目标目录与暂存都不出现', () async {
      final _Harness h = _harness();
      final File conflict = File('${h.root.path}/conflict.n3d');
      await WorkbenchPack(
        kind: WorkbenchPackKind.three,
        name: 'conflict',
        title: 'Conflict',
        files: <String, String>{'a': '1', 'a/b': '2'},
      ).writeTo(conflict);

      await expectLater(
        h.service.importPack(conflict),
        _throwsPackFailure(WorkbenchPackFailureCode.invalidPath),
      );
      expect(h.dir('conflict').existsSync(), isFalse);
      expect(_tempEntries(h.root), isEmpty);
    });
  });

  group('listPacks', () {
    test('只列合法项目名的 .n3d，按文件名排序，不影响 listProjects', () async {
      final _Harness h = _harness(
        replies: <String>[
          _fence('json', jsonEncode(_validSpec)),
          _fence('json', jsonEncode(_validSpec)),
        ],
      );
      await h.newProject(name: 'zeta');
      await h.newProject(name: 'alpha');
      await h.service.exportPack('zeta');
      await h.service.exportPack('alpha');

      // 干扰项：非容器扩展名 / 隐藏包 / 临时文件 / 目录 / 非法项目名 / 错 kind。
      File('${h.root.path}/notes.txt').writeAsStringSync('x');
      File('${h.root.path}/.hidden.n3d').writeAsStringSync('x');
      File('${h.root.path}/alpha.n3d.tmp').writeAsStringSync('x');
      Directory('${h.root.path}/dir.n3d').createSync();
      File('${h.root.path}/bad name.n3d').writeAsStringSync('x');
      File('${h.root.path}/土星.n3d').writeAsStringSync('x');
      File('${h.root.path}/melody.nmu').writeAsStringSync('x');

      final List<File> packs = await h.service.listPacks();
      expect(packs.map((File file) => _leafName(file.path)), <String>[
        'alpha.n3d',
        'zeta.n3d',
      ]);
      expect(
        packs.map((File file) => file.parent.path),
        everyElement(h.root.path),
      );

      // 项目列表只认目录：打包文件不是项目。
      final List<ThreeProjectEntry> entries = await h.service.listProjects();
      expect(entries.map((ThreeProjectEntry entry) => entry.name), <String>[
        'alpha',
        'zeta',
      ]);

      // 根目录不存在 → 空表（不把列目录失败当断言错误）。
      final ThreeService missingRoot = ThreeService(
        root: Directory('${h.root.path}/missing'),
        llm: h.llm.call,
        assets: _assetStub,
      );
      expect(await missingRoot.listPacks(), isEmpty);
    });
  });
}
