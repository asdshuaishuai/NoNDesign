// 发布验收：本地核心（批次 15）。
//
// 这条测试把「应用不再依赖 Python 服务」的用户验收标准锚成可重复的门禁：
//
//   C. 去 Python：app/lib 不再出现 Python 服务的启动/发现面（server/main.py、
//      NONDESIGN_SERVER、server.json、.venv、固定端口）；DDP / 项目库 / 模型
//      快照 / 本地引擎 / 3D / 热应用 / 视频都能在客户端完成。
//   D. 引擎：画布变更仍走 MoonViz 引擎门——HumanGate 与 AgentGate 都能提交，
//      渲染信封带 artboards/SVG。
//   E. 工作台：DDP 往返、项目列表、本地引擎 render、3D/热应用/视频 smoke。
//
// 这里不打开任何 socket：默认「连接桌面」关闭时的无监听状态由
// scripts/wf/check_desktop_release.dart 在发布包上验。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nondesign/core/ddp.dart';
import 'package:nondesign/core/engine/engine_service.dart';
import 'package:nondesign/core/hotapp_service.dart';
import 'package:nondesign/core/nonapp_library.dart';
import 'package:nondesign/core/project_service.dart';
import 'package:nondesign/core/three_service.dart';
import 'package:nondesign/core/video_service.dart';

import 'fixtures/engine/test_env.dart';

Directory _packageRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    if (File('${dir.path}/pubspec.yaml').existsSync()) return dir;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  fail('cannot locate app/ from ${Directory.current.path}');
}

/// 一次 DDP 往返的最小文档（引擎也接受它）。
const String _doc = '---\nmoonviz:\n  format: visual-document\n  revision: 1\n  entry: __seed\n---\n\n'
    '# __seed\n\n'
    '<!-- moonviz:artboard __seed -->\n'
    '```mbt\n'
    'fn visual___seed() -> @decl.Prototype {\n'
    '  let page = @decl.prototype(name="__seed", width=390.0, height=844.0)\n'
    '  page\n'
    '}\n'
    '```\n';

const Map<String, dynamic> _docs = <String, dynamic>{
  'prd': '# 需求\n\n按钮 2–4 字，正文对比度 ≥ 4.5。\n',
  'ui': '首页：一句话起步。\n',
  'design': <String, dynamic>{
    'v': 1,
    'palette': <String, dynamic>{'primary': '#2F6B4F'},
    'typography': <String, dynamic>{'h1': 30, 'body': 14},
    'spacing': <int>[4, 8, 12],
    'radius': <String, dynamic>{'sm': 8},
    'rules': <String>['正文对比度 ≥ 4.5'],
    'notes': '',
  },
};

void main() {
  group('C 去 Python：客户端源码不再有服务启动面', () {
    test('app/lib 无旧运行时 / 旧 HTTP 路由；远程只允许 /v1 契约', () {
      final root = _packageRoot();
      final lib = Directory('${root.path}/lib');

      /// 去掉行注释与块注释后的可执行行。注释里的历史叙述不算运行时引用；
      /// 用户可见文案另由 copy_guard / copy_screen 守。
      List<String> codeLines(File file) {
        final out = <String>[];
        var inBlock = false;
        for (final raw in file.readAsLinesSync()) {
          var text = raw;
          if (inBlock) {
            final end = text.indexOf('*/');
            if (end < 0) continue;
            text = text.substring(end + 2);
            inBlock = false;
          }
          final close = text.indexOf('*/');
          final open = text.indexOf('/*');
          if (open >= 0 && (close < 0 || open < close)) {
            final after = text.indexOf('*/', open + 2);
            if (after < 0) {
              text = text.substring(0, open);
              inBlock = true;
            } else {
              text = text.substring(0, open) + text.substring(after + 2);
            }
          }
          final lineComment = text.indexOf('//');
          if (lineComment >= 0) text = text.substring(0, lineComment);
          if (text.trim().isNotEmpty) out.add(text);
        }
        return out;
      }

      final forbiddenTokens = <String>[
        'ServerLauncher',
        'server/main.py',
        '_spawnFromRoot',
        'NONDESIGN_SERVER',
        'NONDESIGN_PYTHON',
        'NONDESIGN_ROOT',
        'server.json',
        'python3 -m venv',
        '.venv',
      ];
      // 旧内部 HTTP 路由（前一个字符不能是标识符/路径片段，避免把
      // `assets/three/...` 这类资产路径误判成路由）。
      final oldRoute = RegExp(
        r'''(^|[^\w])/(engine|project|agent|three|hotapp|nonapp|video|portfolio|acp)(?=[/"']|$)''',
      );
      final v1Route = RegExp(r'(^|[^\w])/v1/');
      final loopback = RegExp(r'\b(localhost|127\.0\.0\.1)\b');
      final python = RegExp(r'\bpython[0-9.]*\b', caseSensitive: false);
      final fixedPort = RegExp(r'\b(8799|8765)\b');

      final offenders = <String>[];
      for (final entity in lib.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final relative = entity.path.substring(lib.path.length + 1);
        final remoteDir = relative.startsWith('core/remote/');
        final remoteClient = relative == 'core/remote_desktop_client.dart';
        final runtimeRouter = relative == 'core/api.dart';
        for (final line in codeLines(entity)) {
          for (final token in forbiddenTokens) {
            if (line.contains(token)) offenders.add('$relative: $token');
          }
          for (final match in oldRoute.allMatches(line)) {
            offenders.add('$relative: old route ${match.group(0)!.trim()}');
          }
          if (v1Route.hasMatch(line) && !(remoteDir || remoteClient || runtimeRouter)) {
            offenders.add('$relative: /v1 只允许出现在连接桌面契约里');
          }
          if (loopback.hasMatch(line) && !(remoteDir || remoteClient)) {
            offenders.add('$relative: loopback / localhost 只允许连接桌面宿主');
          }
          if (python.hasMatch(line)) {
            offenders.add('$relative: python 运行时引用');
          }
          if (fixedPort.hasMatch(line)) {
            offenders.add('$relative: 固定端口 ${fixedPort.firstMatch(line)!.group(0)}');
          }
        }
      }
      expect(offenders, isEmpty, reason: offenders.join('\n'));
    });
  });

  group('E DDP 往返 + 本地项目库', () {
    late Directory root;
    late ProjectService projects;

    setUp(() {
      root = Directory.systemTemp.createTempSync('acceptance-projects_');
      projects = ProjectService(root: () async => root);
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    test('DDP1 口令 + DDP2 免密：保存 → 列表 → 打开（含文档注释）', () async {
      final locked = await projects.save(
        path: '${root.path}/locked',
        mbt: _doc,
        password: 'pass-123',
        docs: _docs,
      );
      expect(locked.ok, isTrue, reason: '${locked.error}');
      final lockedPath = locked.path!;
      expect(lockedPath.endsWith('.ddp'), isTrue);
      expect(File(lockedPath).readAsBytesSync().sublist(0, 4), DdpCodec.magicLocked);

      await Future<void>.delayed(const Duration(milliseconds: 20));
      final open = await projects.save(
        path: '${root.path}/open',
        mbt: _doc,
        docs: _docs,
      );
      expect(open.ok, isTrue, reason: '${open.error}');
      expect(File(open.path!).readAsBytesSync().sublist(0, 4), DdpCodec.magicOpen);

      final listed = await projects.list(dir: root.path);
      expect(listed.ok, isTrue);
      expect(listed.projects.map((entry) => entry.name), ['open', 'locked'],
          reason: '新保存的项目排前面');

      final missingPassword = await projects.open(lockedPath);
      expect(missingPassword.needPassword, isTrue);
      expect(missingPassword.error, 'ddp_password_required');

      final wrong = await projects.open(lockedPath, password: 'nope');
      expect(wrong.needPassword, isTrue);
      expect(wrong.error, 'ddp_authentication_failed');

      final opened = await projects.open(lockedPath, password: 'pass-123');
      expect(opened.ok, isTrue, reason: '${opened.error}');
      expect(opened.mbt, contains('moonviz:artboard __seed'));
      expect(opened.docs?['prd'], _docs['prd']);
      expect(opened.docs?['ui'], _docs['ui']);
      expect((opened.docs?['design'] as Map)['rules'], _docs['design']!['rules']);

      final opened2 = await projects.open(open.path!);
      expect(opened2.ok, isTrue, reason: '${opened2.error}');
      expect(opened2.docs?['prd'], _docs['prd']);

      final leftovers = root
          .listSync()
          .whereType<File>()
          .where((file) => file.path.contains('.tmp-'))
          .toList();
      expect(leftovers, isEmpty, reason: '原子写不得留下临时文件');
    });

    test('缺失文件与缺失目录是显式错误，不是空成功', () async {
      final missing = await projects.open('${root.path}/ghost.ddp');
      expect(missing.ok, isFalse);
      expect(missing.error, 'file_not_found');

      final listed = await projects.list(dir: '${root.path}/nope');
      expect(listed.ok, isFalse);
      expect(listed.error, 'dir_not_found');
    });
  });

  group('D/E 本地引擎：render + 两道门', () {
    late EngineService engine;

    setUpAll(() async {
      engine = await EngineService.start(wasmBytes: engineBytes());
    });

    tearDownAll(() async {
      await engine.dispose();
    });

    test('引擎能启动并渲染种子文档（artboards + SVG）', () async {
      expect(engine.isReady, isTrue, reason: engine.startupError);
      final rendered = await engine.render(seedDoc);
      expect(rendered['ok'], isTrue, reason: '$rendered');
      final boards = (rendered['artboards'] as List).cast<Map>();
      expect(boards, hasLength(1));
      expect('${boards.first['svg']}', contains('<svg'));
    });

    test('HumanGate 与 AgentGate 都可提交，变更信封带 mbt', () async {
      final human = await engine.apply(
        seedDoc,
        'place __seed button human_btn - 30 110 140 44 text=下一页',
      );
      expect(human['ok'], isTrue, reason: '$human');
      expect(human['mbt'], isA<String>());

      final agent = await engine.apply(
        seedDoc,
        'place __seed button agent_btn - 40 220 160 44 text=确认',
        gate: 'agent',
      );
      expect(agent['ok'], isTrue, reason: '$agent');
      expect(agent['mbt'], isA<String>());

      final sessions = await engine.session(seedDoc, 'session_list_artboards');
      expect(sessions['ok'], isTrue, reason: '$sessions');
    });
  });

  group('E 3D 工作台（本机模型调用注入）', () {
    test('规范先行 → 项目落盘 → 列表可见', () async {
      final root = Directory.systemTemp.createTempSync('acceptance-three_');
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });

      const spec = <String, dynamic>{
        'title': 'Saturn',
        'summary': '带环行星自转',
        'components': <Map<String, dynamic>>[
          <String, dynamic>{'id': 'planet', 'what': '球体', 'size_scale': 1.0},
        ],
        'materials': <Map<String, dynamic>>[],
        'camera': <String, dynamic>{'view': '略高处斜看'},
        'interactions': <String>['自转'],
        'acceptance': <String>['行星在场'],
      };
      final service = ThreeService(
        root: root,
        llm: (request) async => '```json\n${jsonEncode(spec)}\n```',
        assets: (key) async {
          if (key == threePreviewAssetKey) {
            return Uint8List.fromList(utf8.encode('<!doctype html><html><body></body></html>'));
          }
          // 与锚点等长的渲染库：服务只校验长度与导出存在性。
          const head = 'export const Scene = 1;\n';
          const tail = 'export { Scene };\n';
          final pad = threeModuleByteLength - head.length - tail.length;
          return Uint8List.fromList(utf8.encode('$head${'x' * pad}$tail'));
        },
      );

      final snapshot = await service.newProject(
        name: 'saturn-demo',
        brief: '带环行星自转',
        config: const ThreeLlmConfig(
          model: 'test-model',
          baseUrl: 'https://model.invalid/v1',
          apiKey: 'test-key',
        ),
      );
      expect(snapshot.spec['title'], 'Saturn');
      expect(File('${root.path}/saturn-demo/three-spec.json').existsSync(), isTrue);
      expect(File('${root.path}/saturn-demo/build-state.json').existsSync(), isTrue);

      final listed = await service.listProjects();
      expect(listed.map((entry) => entry.name), contains('saturn-demo'));
    });
  });

  group('E 热应用（本机生成 + 本地库）', () {
    test('一句话生成 → 页面/清单/数据库落盘 → 列表可读', () async {
      final root = Directory.systemTemp.createTempSync('acceptance-hotapp_');
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      final library = await NonAppLibrary.open(root: Directory('${root.path}/hotapps'));
      const html = '<!doctype html><html><head><meta charset="utf-8"><style>'
          'html,body{margin:0;height:100%;background:#1b1b2f;color:#eee}'
          '</style></head><body><div id="app">你好</div>'
          '<script>document.getElementById("app").textContent+="，热应用";</script>'
          '</body></html>';
      final service = HotAppService(
        library: library,
        llm: (request) async => '```html\n$html\n```',
      );

      final entry = await service.generate(
        name: 'hello-app',
        brief: '一个打招呼的页面',
        config: const HotAppLlmConfig(
          model: 'test-model',
          baseUrl: 'https://model.invalid/v1',
          apiKey: 'test-key',
        ),
      );
      expect(entry.name, 'hello-app');
      expect(File('${entry.dir}/index.html').readAsStringSync(), contains('热应用'));
      expect(File('${entry.dir}/app.db').existsSync(), isTrue);
      expect(File('${entry.dir}/manifest.json').existsSync(), isTrue);

      final apps = await service.list();
      expect(apps.map((app) => app.name), contains('hello-app'));
    });
  });

  group('E 视频工作台（脚本 + 机械对照）', () {
    test('内置示例可解析，对照检查通过（不 spawn 外部程序）', () {
      final root = Directory.systemTemp.createTempSync('acceptance-video_');
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      final service = VideoService(
        host: VideoHost.macos,
        videosRoot: () async => root,
        binaryResolver: (_) async => null,
      );
      expect(service.samples.length, greaterThanOrEqualTo(3));

      final document = service.loadSample(0);
      expect(document.frameCount(), greaterThan(0));

      final review = service.review(
        timeline: document.timeline,
        spec: document.spec.raw,
      );
      expect(review.ok, isTrue, reason: review.output);
      expect(review.totalSeconds, greaterThan(0));
    });
  });
}
