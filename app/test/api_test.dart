// Runtime router tests (batch 05).
//
// The app has two runtimes: the local core (engine + project library) and the
// optional connected desktop (RPC, see remote_rpc_contract_test.dart). These
// tests pin the router's *local* behaviour and its failure envelopes:
//
//  * local engine calls never touch HTTP;
//  * projects are client-side `.ddp` files (save → open → list round-trip);
//  * with no runtime at all every face answers `engine_unavailable` /
//    `remote_unavailable` instead of throwing or returning null;
//  * remote-only faces (3D / hot-app / portfolio / external agents) are honest
//    when no desktop is connected.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nondesign/core/api.dart';
import 'package:nondesign/core/capability.dart';
import 'package:nondesign/core/project_service.dart';
import 'package:nondesign/core/remote_desktop_client.dart';

class _FakeEngine implements LocalEngine {
  bool ready = true;
  String canonical = 'MBT_0';
  final List<String> gates = [];
  final List<String> appliedOps = [];
  int renderCalls = 0;
  final List<String> calls = [];

  Map<String, dynamic> _envelope(String mbt, {String entry = 'home'}) => {
        'ok': true,
        'mbt': mbt,
        'entry': entry,
        'revision': 1,
        'artboards': [
          {'id': entry, 'name': entry, 'width': 390, 'height': 844, 'nodes': []},
        ],
        'flows': [],
      };

  @override
  bool get isReady => ready;

  @override
  String? get startupError => ready ? null : 'engine fixture off';

  @override
  CapabilityAvailability probeAvailability() => ready
      ? const CapabilityAvailability.available(CapabilityId.localDesignEngine)
      : const CapabilityAvailability.unavailable(CapabilityId.localDesignEngine);

  @override
  Future<Map<String, dynamic>> render(String mbt) async {
    calls.add('render');
    renderCalls++;
    canonical = mbt;
    return _envelope(mbt);
  }

  @override
  Future<Map<String, dynamic>> validate(String mbt) async {
    calls.add('validate');
    return {'ok': true, 'mbt': mbt};
  }

  @override
  Future<Map<String, dynamic>> apply(String mbt, String op, {String gate = 'human'}) async {
    calls.add('apply');
    gates.add(gate);
    appliedOps.add(op);
    canonical = 'MBT_${appliedOps.length}';
    return _envelope(canonical);
  }

  @override
  Future<Map<String, dynamic>> session(String mbt, String name, [String? arg]) async {
    calls.add('session:$name');
    return {'ok': true, 'data': const []};
  }

  @override
  Future<Map<String, dynamic>> generate(
          String mbt, String intent, String name, Map<String, dynamic> spec) async {
    calls.add('generate');
    return {'ok': true, 'mbt': '$mbt<!--gen-->', 'artboard': name};
  }

  @override
  Future<Map<String, dynamic>> tap(String mbt, String artboard, double x, double y) async {
    calls.add('tap');
    return {'ok': true, 'current': artboard};
  }

  @override
  Future<Map<String, dynamic>> constrainIntent(String mbt, String artboard, String intent) async {
    calls.add('constrain');
    return {'ok': true, 'mbt': mbt};
  }

  @override
  Future<Map<String, dynamic>> event(String mbt, String artboard, String spec) async {
    calls.add('event');
    return {'ok': true, 'current': artboard};
  }

  @override
  Future<Map<String, dynamic>> history(String mbt, String command) async {
    calls.add('history');
    return {'ok': true};
  }

  @override
  Future<Map<String, dynamic>> exportHtml(String mbt) async {
    calls.add('exportHtml');
    return {'ok': true, 'html': '<html></html>'};
  }

  @override
  Future<Map<String, dynamic>> tokens() async {
    calls.add('tokens');
    return {'ok': true, 'data': const []};
  }

  @override
  Future<Map<String, dynamic>> versionInfo() async {
    calls.add('version');
    return {'ok': true, 'version': 'fixture'};
  }

  @override
  Future<List<dynamic>> templates() async {
    calls.add('templates');
    return [
      {'id': 'pc_app'},
    ];
  }

  @override
  Future<List<dynamic>> components() async {
    calls.add('components');
    return ['button'];
  }

  @override
  Future<List<dynamic>> themes() async {
    calls.add('themes');
    return ['dark'];
  }

  @override
  Future<List<dynamic>> ops() async {
    calls.add('ops');
    return ['place'];
  }
}

Directory _tempDir() {
  final dir = Directory.systemTemp.createTempSync('nondesign-api-test');
  addTearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });
  return dir;
}

void main() {
  group('local runtime', () {
    late _FakeEngine engine;
    late ProjectService projects;
    late NoNDesignApi api;

    setUp(() {
      engine = _FakeEngine();
      projects = ProjectService(root: () async => _tempDir());
      api = NoNDesignApi.runtime(
        local: LocalCore(engine: engine, projects: projects),
      );
    });

    test('engine faces go to the in-process engine, never to HTTP', () async {
      expect((await api.render('MBT_A'))['mbt'], 'MBT_A');
      expect((await api.apply('MBT_A', 'move home n1 1 2'))['ok'], isTrue);
      expect((await api.session('MBT_A', 'session_list_artboards'))['ok'], isTrue);
      expect((await api.generate('MBT_A', '居中', 'home', const {}))['ok'], isTrue);
      expect((await api.tap('MBT_A', 'home', 1, 2))['current'], 'home');
      expect((await api.event('MBT_A', 'home', 'key_enter'))['current'], 'home');
      expect((await api.constrainIntent('MBT_A', 'home', '居中'))['ok'], isTrue);
      expect((await api.history('MBT_A', 'undo'))['ok'], isTrue);
      expect((await api.exportHtml('MBT_A'))['html'], isNotNull);

      expect(engine.gates, ['human']);
      expect(engine.renderCalls, 1);
      expect(
        engine.calls,
        containsAll([
          'render',
          'apply',
          'session:session_list_artboards',
          'generate',
          'tap',
          'event',
          'constrain',
          'history',
          'exportHtml',
        ]),
      );
    });

    test('agent gate is forwarded verbatim', () async {
      await api.apply('MBT_A', 'place home text t1 0 0 10 10', gate: 'agent');
      expect(engine.gates, ['agent']);
    });

    test('registries read from the local engine', () async {
      expect(await api.templates(), hasLength(1));
      expect(await api.components(), ['button']);
      expect(await api.themes(), ['dark']);
      expect(await api.ops(), ['place']);
      expect((await api.tokens())['ok'], isTrue);
      expect((await api.versionInfo())['version'], 'fixture');
    });

    test('projects are local .ddp files: save → open → list', () async {
      final dir = _tempDir();
      final target = '${dir.path}/demo.ddp';

      final saved = await api.saveProject(
        mbt: 'MBT_BODY',
        path: target,
        docs: {'prd': '需求', 'ui': ''},
      );
      expect(saved['ok'], isTrue);
      expect(saved['path'], target);
      expect(File(target).existsSync(), isTrue);
      expect(saved['bytes'], greaterThan(0));

      final opened = await api.openProject(target);
      expect(opened['ok'], isTrue);
      expect(opened['mbt'], contains('MBT_BODY'));
      expect((opened['docs'] as Map)['prd'], '需求');

      final listed = await api.listProjects(dir.path);
      expect(listed.map((e) => (e as Map)['name']), contains('demo'));
    });

    test('a wrong password is reported as need_password, not a failure', () async {
      final dir = _tempDir();
      final target = '${dir.path}/locked.ddp';
      await api.saveProject(mbt: 'MBT_BODY', path: target, password: 'pw', docs: const {});

      final locked = await api.openProject(target);
      expect(locked['ok'], isFalse);
      expect(locked['need_password'], isTrue);

      final opened = await api.openProject(target, password: 'pw');
      expect(opened['ok'], isTrue);
    });

    test('local models() answers honestly (the registry lives in the store)', () async {
      final models = await api.models();
      expect(models['ok'], isFalse);
      expect(models['error'], 'models_local_only');
    });
  });

  group('no runtime', () {
    final api = NoNDesignApi.runtime();

    test('isReady is false and every engine face returns engine_unavailable', () async {
      expect(api.isReady, isFalse);
      for (final res in await Future.wait([
        api.render('x'),
        api.validate('x'),
        api.apply('x', 'op'),
        api.session('x', 'session_list_artboards'),
        api.generate('x', 'i', 'n', const {}),
        api.tap('x', 'a', 0, 0),
        api.event('x', 'a', 'e'),
        api.constrainIntent('x', 'a', '居中'),
        api.history('x', 'log'),
        api.exportHtml('x'),
      ])) {
        expect(res['ok'], isFalse);
        expect(res['error'], 'engine_unavailable');
      }
      expect(await api.templates(), isEmpty);
      expect(await api.components(), isEmpty);
    });

    test('agentRun is a single failed terminal, never a hang', () async {
      final events = await api.agentRun({'run_id': 1}).toList();
      expect(events.single['type'], 'failed');
      expect(events.single['error'], 'remote_unavailable');
    });

    test('remote-only faces answer remote_unavailable', () async {
      for (final res in await Future.wait([
        api.exportFigma('x'),
        api.threeProjects(),
        api.hotAppList(),
        api.portfolio(),
        api.clearSession('x'),
      ])) {
        expect(res['ok'], isFalse);
        expect(res['error'], 'remote_unavailable');
      }
      expect(await api.acpAgents(), isEmpty);
      expect(await api.cancelAgent(1), isFalse);
    });
  });

  test('SSE idle timeout is shared with the connected desktop client', () {
    final previous = RemoteDesktopClient.sseIdleTimeout;
    addTearDown(() => RemoteDesktopClient.sseIdleTimeout = previous);
    NoNDesignApi.sseIdleTimeout = const Duration(milliseconds: 123);
    expect(RemoteDesktopClient.sseIdleTimeout, const Duration(milliseconds: 123));
  });

  test('a configured desktop address is normalised once', () {
    final api = NoNDesignApi('http://127.0.0.1:8799///');
    addTearDown(() => api.remote?.close());
    expect(api.baseUrl, 'http://127.0.0.1:8799');
    expect(api.hasRemote, isTrue);
    expect(api.isReady, isTrue);
  });

  test('runtime router exposes no raw HTTP escape hatch', () {
    // 旧 `getJson`/`postJson` 助手已随旧 HTTP 路由一起删除：远程面只能经
    // `/v1/health|capabilities|rpc`（RemoteDesktopClient）访问。
    final source = File('lib/core/api.dart').readAsStringSync();
    expect(source.contains('getJson('), isFalse);
    expect(source.contains('postJson('), isFalse);
  });

  test('hot-app / 3D asset URLs degrade to a placeholder page, never a blank', () {
    final api = NoNDesignApi.runtime();
    final page = api.hotAppPageUrl('demo');
    expect(page, startsWith('data:text/html'));
    final decoded = Uri.parse(page).data!.contentAsString();
    expect(decoded, contains('热应用需要先连接桌面'));
    expect(api.threePreviewUrl('demo'), startsWith('data:text/html'));
  });

  test('bundled model snapshot is parseable JSON with providers', () {
    final raw = File('assets/models.json').readAsStringSync();
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    expect(decoded['providers'], isA<Map>());
    expect((decoded['providers'] as Map), isNotEmpty);
  });
}
