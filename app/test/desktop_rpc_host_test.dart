// Desktop RPC host — batch 10 gates.
//
// These tests exercise the *host* side of the "连接桌面" contract with a real
// `dart:io` HttpServer on loopback and a scripted local core. Nothing here
// spawns Python, touches a user directory or calls a model.
//
// Pinned here (see the batch gates):
//  * off by default — constructing the host opens no socket;
//  * loopback + ephemeral port when switched on; `0.0.0.0` only with the
//    explicit LAN toggle;
//  * the token is mandatory (401 without / with a wrong one), and rotating it
//    invalidates the old one immediately;
//  * 16 MiB body ceiling, 8 concurrent requests, 600 s stream idle timeout;
//  * the method table covers engine / project / agent / three / hotapp /
//    video / nonapp / external-agent faces and delegates to the local core;
//  * `agent.run` streams SSE and always ends with a terminal event, including
//    when the client disappears or the source stalls.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:ai_sdk_dart/ai_sdk_dart.dart' show CancellationToken;
import 'package:flutter_test/flutter_test.dart';
import 'package:nondesign/core/acp_client.dart';
import 'package:nondesign/core/api.dart';
import 'package:nondesign/core/capability.dart';
import 'package:nondesign/core/project_service.dart';
import 'package:nondesign/core/remote/desktop_rpc_host.dart';
import 'package:nondesign/core/remote/rpc_auth.dart';
import 'package:nondesign/core/remote/rpc_methods.dart';
import 'package:nondesign/core/remote/rpc_protocol.dart';

// ---------------------------------------------------------------------------
// Scripted local engine
// ---------------------------------------------------------------------------

class _FakeEngine implements LocalEngine {
  bool ready = true;
  String canonical = 'MBT_0';
  int renderCalls = 0;
  final List<String> gates = [];
  final List<String> appliedOps = [];
  final List<String> sessions = [];
  Completer<void>? block;
  int active = 0;
  int maxActive = 0;

  Map<String, dynamic> _envelope(String mbt) => <String, dynamic>{
    'ok': true,
    'mbt': mbt,
    'entry': 'home',
    'revision': 1,
    'artboards': <Map<String, dynamic>>[
      <String, dynamic>{'id': 'home', 'name': 'home', 'width': 390, 'height': 844, 'nodes': <dynamic>[]},
    ],
    'flows': <dynamic>[],
  };

  @override
  bool get isReady => ready;

  @override
  String? get startupError => ready ? null : 'fixture engine unavailable';

  @override
  CapabilityAvailability probeAvailability() => ready
      ? const CapabilityAvailability.available(CapabilityId.localDesignEngine)
      : const CapabilityAvailability.unavailable(CapabilityId.localDesignEngine);

  @override
  Future<Map<String, dynamic>> render(String mbt) async {
    if (!ready) {
      return <String, dynamic>{
        'ok': false,
        'error': 'engine_unavailable',
        'detail': 'fixture engine unavailable',
      };
    }
    renderCalls++;
    active++;
    maxActive = math.max(maxActive, active);
    try {
      final gate = block;
      if (gate != null) await gate.future;
      canonical = mbt;
      return _envelope(mbt);
    } finally {
      active--;
    }
  }

  @override
  Future<Map<String, dynamic>> validate(String mbt) async => <String, dynamic>{'ok': true, 'mbt': mbt};

  @override
  Future<Map<String, dynamic>> apply(String mbt, String op, {String gate = 'human'}) async {
    gates.add(gate);
    appliedOps.add(op);
    canonical = 'MBT_${appliedOps.length}';
    return _envelope(canonical);
  }

  @override
  Future<Map<String, dynamic>> session(String mbt, String name, [String? arg]) async {
    sessions.add(name);
    return <String, dynamic>{
      'ok': true,
      'data': <dynamic>[
        <String, dynamic>{'id': 'home', 'nodes': 1},
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> generate(
    String mbt,
    String intent,
    String name,
    Map<String, dynamic> spec,
  ) async => <String, dynamic>{'ok': true, 'mbt': '$mbt<!-- $intent -->', 'artboard': name};

  @override
  Future<Map<String, dynamic>> tap(String mbt, String artboard, double x, double y) async =>
      <String, dynamic>{'ok': true, 'current': artboard, 'x': x, 'y': y};

  @override
  Future<Map<String, dynamic>> constrainIntent(String mbt, String artboard, String intent) async =>
      <String, dynamic>{'ok': true, 'mbt': mbt};

  @override
  Future<Map<String, dynamic>> event(String mbt, String artboard, String spec) async =>
      <String, dynamic>{'ok': true, 'current': artboard};

  @override
  Future<Map<String, dynamic>> history(String mbt, String command) async =>
      <String, dynamic>{'ok': true, 'command': command};

  @override
  Future<Map<String, dynamic>> exportHtml(String mbt) async =>
      <String, dynamic>{'ok': true, 'html': '<html></html>'};

  @override
  Future<Map<String, dynamic>> tokens() async => <String, dynamic>{'ok': true, 'data': <dynamic>[]};

  @override
  Future<Map<String, dynamic>> versionInfo() async => <String, dynamic>{'ok': true, 'version': 'fixture'};

  @override
  Future<List<dynamic>> templates() async => <dynamic>[
    <String, dynamic>{'id': 'pc_app', 'name': 'PC App'},
  ];

  @override
  Future<List<dynamic>> components() async => <dynamic>['button', 'text'];

  @override
  Future<List<dynamic>> themes() async => <dynamic>['dark'];

  @override
  Future<List<dynamic>> ops() async => <dynamic>['place'];
}

// ---------------------------------------------------------------------------
// Scripted agent runner
// ---------------------------------------------------------------------------

class _FakeAgentRunner extends RpcAgentRunner {
  _FakeAgentRunner(this.script);

  final Stream<Map<String, dynamic>> Function(RpcAgentRun run, CancellationToken abort) script;
  final List<RpcAgentRun> runs = <RpcAgentRun>[];
  CancellationToken? lastToken;

  @override
  Stream<Map<String, dynamic>> run(RpcAgentRun run, CancellationToken abort) {
    runs.add(run);
    lastToken = abort;
    return script(run, abort);
  }
}

// ---------------------------------------------------------------------------
// Scripted external-agent runtime (no process is ever spawned)
// ---------------------------------------------------------------------------

class _FakeAcpRuntime implements RpcAcpRuntime {
  @override
  bool get supported => true;

  final List<String> started = <String>[];

  @override
  Future<List<AcpAgentAvailability>> agents({bool probe = false}) async => <AcpAgentAvailability>[
    const AcpAgentAvailability(
      id: 'fake',
      name: '假智能体',
      installed: true,
      selectable: true,
      note: '测试用',
    ),
  ];

  @override
  Future<RpcAcpSession> start({required String agent, String? cwd}) async {
    started.add(agent);
    return _FakeAcpSession(id: 'acp-test');
  }
}

class _FakeAcpSession implements RpcAcpSession {
  _FakeAcpSession({required this.id});

  @override
  final String id;

  StreamController<Map<String, dynamic>>? _controller;
  final List<String> answers = <String>[];
  bool closed = false;

  @override
  Stream<Map<String, dynamic>> prompt(String text) {
    final controller = StreamController<Map<String, dynamic>>();
    _controller = controller;
    scheduleMicrotask(() {
      controller.add(<String, dynamic>{
        'type': 'permission',
        'request_id': 'p1',
        'title': '允许读取文件吗',
        'options': <Map<String, dynamic>>[
          <String, dynamic>{'option_id': 'allow', 'name': '允许', 'kind': 'allow'},
          <String, dynamic>{'option_id': 'deny', 'name': '拒绝', 'kind': 'reject'},
        ],
      });
    });
    return controller.stream;
  }

  @override
  Future<bool> answerPermission(String requestId, {String? optionId, bool cancelled = false}) async {
    answers.add(cancelled ? 'cancelled' : '$requestId:$optionId');
    final controller = _controller;
    if (controller != null && !controller.isClosed) {
      controller.add(<String, dynamic>{'type': 'note', 'label': '已收到答复'});
      controller.add(<String, dynamic>{'type': 'done', 'stopReason': 'end_turn'});
      await controller.close();
    }
    return true;
  }

  @override
  Future<void> cancel() async {}

  @override
  Future<void> close() async {
    closed = true;
    final controller = _controller;
    if (controller != null && !controller.isClosed) await controller.close();
  }
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

Directory _tempDir() {
  final dir = Directory.systemTemp.createTempSync('nondesign-rpc-host-');
  addTearDown(() {
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } catch (_) {}
  });
  return dir;
}

RpcServices _services({
  LocalEngine? engine,
  Directory? projectsRoot,
  RpcAgentRunner? agent,
  RpcAcpRuntime? acp,
}) {
  final root = projectsRoot ?? _tempDir();
  return RpcServices(
    core: LocalCore(
      engine: engine ?? _FakeEngine(),
      projects: ProjectService(root: () async => root),
    ),
    agent: agent ?? _FakeAgentRunner(_simpleScript),
    acp: acp,
    systemAcp: false,
  );
}

Stream<Map<String, dynamic>> _simpleScript(RpcAgentRun run, CancellationToken abort) async* {
  yield <String, dynamic>{'type': 'note', 'label': '开始'};
  yield <String, dynamic>{'type': 'assistant_delta', 'text': 'hi'};
  yield <String, dynamic>{
    'type': 'done',
    'text': 'ok',
    'stopReason': 'done',
    'mbt_b64': base64Encode(utf8.encode(run.mbt)),
  };
}

// --- HTTP helpers ----------------------------------------------------------

class _Reply {
  _Reply(this.status, this.body);
  final int status;
  final String body;

  Map<String, dynamic> get json => jsonDecode(body) as Map<String, dynamic>;
  Map<String, dynamic> get result => Map<String, dynamic>.from(json['result'] as Map);
}

Future<_Reply> _send(
  DesktopRpcHost host,
  String method,
  String path, {
  String? token,
  Object? body,
  Map<String, String> headers = const <String, String>{},
  Duration timeout = const Duration(seconds: 15),
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  try {
    final uri = Uri.parse('http://127.0.0.1:${host.port}$path');
    final request = await client.openUrl(method, uri);
    if (token != null) request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    headers.forEach(request.headers.set);
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(body is String ? body : jsonEncode(body));
    }
    final response = await request.close().timeout(timeout);
    final text = await utf8.decodeStream(response).timeout(timeout);
    return _Reply(response.statusCode, text);
  } finally {
    client.close(force: true);
  }
}

Future<_Reply> _rpc(
  DesktopRpcHost host,
  String method, {
  Map<String, dynamic> params = const <String, dynamic>{},
  String? token,
  int? protocol,
}) => _send(
  host,
  'POST',
  '/v1/rpc',
  token: token ?? host.status.token,
  body: <String, dynamic>{
    'method': method,
    'params': params,
    'protocol': ?protocol,
  },
);

/// Reads an SSE reply to completion (the host ends it with a terminal event).
Future<List<Map<String, dynamic>>> _stream(
  DesktopRpcHost host,
  String method, {
  Map<String, dynamic> params = const <String, dynamic>{},
  String? token,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  try {
    final request = await client.openUrl(
      'POST',
      Uri.parse('http://127.0.0.1:${host.port}/v1/rpc'),
    );
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${token ?? host.status.token}');
    request.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(<String, dynamic>{'method': method, 'params': params}));
    final response = await request.close();
    expect(response.statusCode, 200);
    final events = <Map<String, dynamic>>[];
    await for (final line
        in response
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .timeout(timeout)) {
      if (line.startsWith('data:')) {
        final payload = line.substring(5).trim();
        if (payload.isNotEmpty) {
          events.add(Map<String, dynamic>.from(jsonDecode(payload) as Map));
        }
      }
    }
    return events;
  } finally {
    client.close(force: true);
  }
}

/// Opens an SSE reply without waiting for it to finish, so the test can answer
/// a `permission` event while the stream is still open.
Future<({Stream<Map<String, dynamic>> events, Future<void> Function() close})> _openSse(
  DesktopRpcHost host,
  String method, {
  Map<String, dynamic> params = const <String, dynamic>{},
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  final request = await client.openUrl('POST', Uri.parse('http://127.0.0.1:${host.port}/v1/rpc'));
  request.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${host.status.token}');
  request.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
  request.headers.contentType = ContentType.json;
  request.write(jsonEncode(<String, dynamic>{'method': method, 'params': params}));
  final response = await request.close();
  expect(response.statusCode, 200);
  final controller = StreamController<Map<String, dynamic>>();
  late final StreamSubscription<String> sub;
  sub = response
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(
        (line) {
          if (!line.startsWith('data:')) return;
          final payload = line.substring(5).trim();
          if (payload.isEmpty) return;
          controller.add(Map<String, dynamic>.from(jsonDecode(payload) as Map));
        },
        onDone: () {
          if (!controller.isClosed) controller.close();
        },
        onError: (Object error) {
          if (!controller.isClosed) controller.close();
        },
      );
  return (
    events: controller.stream,
    close: () async {
      await sub.cancel();
      client.close(force: true);
    },
  );
}

Future<Map<String, dynamic>> _waitForType(
  List<Map<String, dynamic>> events,
  String type, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    for (final event in events) {
      if (event['type'] == type) return event;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('no "$type" event within $timeout: $events');
}

void main() {
  group('lifecycle: off by default, loopback first', () {
    test('constructing the host opens no socket and defaults to loopback', () {
      final host = DesktopRpcHost(services: _services());
      addTearDown(host.dispose);

      expect(host.isRunning, isFalse);
      expect(host.port, 0);
      expect(host.status.baseUrl, '');
      expect(host.status.lanEnabled, isFalse);
      expect(host.status.token, isNotEmpty);
      // The production contract behind the gate.
      expect(RpcHostOptions().allowLan, isFalse);
      expect(RpcHostOptions().port, 0);
    });

    test('start() binds 127.0.0.1 on an ephemeral port', () async {
      final host = DesktopRpcHost(services: _services());
      addTearDown(host.dispose);

      final status = await host.start();

      expect(status.running, isTrue);
      expect(status.address, '127.0.0.1');
      expect(status.port, greaterThan(0));
      expect(status.loopbackOnly, isTrue);
      expect(status.baseUrl, 'http://127.0.0.1:${status.port}');
      expect(status.error, isNull);
    });

    test('the LAN toggle binds 0.0.0.0 and exposes the warning', () async {
      final host = DesktopRpcHost(services: _services());
      addTearDown(host.dispose);

      final status = await host.start(allowLan: true);

      expect(status.running, isTrue);
      expect(status.address, '0.0.0.0');
      expect(status.lanEnabled, isTrue);
      expect(status.loopbackOnly, isFalse);
      expect(status.warning, isNotEmpty);
      // A phone on the same network can still reach it through loopback here.
      final reply = await _send(host, 'GET', '/v1/health', token: status.token);
      expect(reply.status, 200);
    });

    test('stop() closes the listener immediately', () async {
      final host = DesktopRpcHost(services: _services());
      final status = await host.start();
      final port = status.port;
      expect(host.isRunning, isTrue);

      await host.stop();

      expect(host.isRunning, isFalse);
      expect(host.status.baseUrl, '');
      await expectLater(
        _send(host, 'GET', '/v1/health', token: status.token),
        throwsA(isA<SocketException>()),
        reason: 'no listener may survive stop(); port $port is dead',
      );
    });

    test('start() is idempotent for the same mode', () async {
      final host = DesktopRpcHost(services: _services());
      addTearDown(host.dispose);

      final first = await host.start();
      final second = await host.start();

      expect(second.port, first.port);
    });
  });

  group('authentication', () {
    test('every face requires the token; wrong tokens are 401', () async {
      final host = DesktopRpcHost(services: _services());
      addTearDown(host.dispose);
      final status = await host.start();

      final missing = await _send(host, 'GET', '/v1/health');
      expect(missing.status, 401);
      expect(missing.json['error'], RpcErrorCode.unauthorized);
      expect(missing.json['message'], RpcCopy.unauthorized);

      final wrong = await _send(host, 'GET', '/v1/health', token: 'definitely-not-the-token');
      expect(wrong.status, 401);

      final rpcWithout = await _send(
        host,
        'POST',
        '/v1/rpc',
        body: <String, dynamic>{'method': 'health'},
      );
      expect(rpcWithout.status, 401);

      final ok = await _send(host, 'GET', '/v1/health', token: status.token);
      expect(ok.status, 200);
      expect(ok.json['ok'], isTrue);
      expect(ok.json['protocol'], rpcProtocolVersion);
      expect(ok.json['name'], isNotEmpty);
    });

    test('rotating the token invalidates the previous one at once', () async {
      final host = DesktopRpcHost(services: _services());
      addTearDown(host.dispose);
      final first = (await host.start()).token;

      expect((await _send(host, 'GET', '/v1/health', token: first)).status, 200);

      final second = host.regenerateToken().value;
      expect(second, isNot(first));
      expect((await _send(host, 'GET', '/v1/health', token: first)).status, 401);
      expect((await _send(host, 'GET', '/v1/health', token: second)).status, 200);
    });

    test('restarting the host rotates the token', () async {
      final host = DesktopRpcHost(services: _services());
      addTearDown(host.dispose);
      final first = (await host.start()).token;
      await host.stop();
      final second = (await host.start()).token;

      expect(second, isNot(first));
      expect((await _send(host, 'GET', '/v1/health', token: first)).status, 401);
      expect((await _send(host, 'GET', '/v1/health', token: second)).status, 200);
    });

    test('token helpers: format, hint and bearer parsing', () {
      final token = RpcAuthToken.generate();
      expect(token.value.length, 32);
      expect(token.isValid, isTrue);
      expect(token.matches('Bearer ${token.value}'), isTrue);
      expect(token.matches('bearer ${token.value}'), isTrue);
      expect(token.matches(token.value), isTrue);
      expect(token.matches('Bearer nope'), isFalse);
      expect(token.matches(null), isFalse);
      expect(token.matches('Basic ${token.value}'), isFalse);
      expect(token.hint, contains('…'));
      expect(RpcAuthToken.generate().value, isNot(token.value));
    });

    test('asset URLs accept the token as a query parameter and nothing else', () async {
      final host = DesktopRpcHost(services: _services());
      addTearDown(host.dispose);
      final status = await host.start();

      // Authorization is checked before the workspace is touched: without a
      // token this is a 401 even though the 3D service fixture is absent.
      final anonymous = await _send(host, 'GET', '/v1/assets/three/demo');
      expect(anonymous.status, 401);

      final bad = await _send(host, 'GET', '/v1/assets/three/demo?token=wrong');
      expect(bad.status, 401);

      // With the right token the request reaches the (missing) project and
      // answers honestly instead of leaking a file.
      final withToken = await _send(
        host,
        'GET',
        '/v1/assets/three/demo?token=${Uri.encodeQueryComponent(status.token)}',
      );
      expect(withToken.status, isNot(200));
    });
  });

  group('method table coverage', () {
    test('every documented method is registered exactly once', () {
      final table = RpcMethodTable(_services())..build();

      expect(RpcMethod.all.toSet().length, RpcMethod.all.length, reason: 'no duplicate constants');
      expect(table.names.toSet(), containsAll(RpcMethod.all));
      expect(table.names.length, RpcMethod.all.length);
    });

    test('the faces named by the batch brief are present', () {
      final names = (RpcMethodTable(_services())..build()).names.toSet();
      for (final required in <String>[
        'health',
        'capabilities',
        'engine.render',
        'engine.apply',
        'engine.session',
        'engine.generate',
        'engine.history',
        'project.save',
        'project.open',
        'project.list',
        'agent.run',
        'agent.cancel',
        'three.project.new',
        'three.pass',
        'hotapp.list',
        'hotapp.generate',
        'video.review',
        'video.render',
        'nonapp.list',
        'nonapp.inspect',
        'agent.external.agents',
        'agent.external.prompt',
        'portfolio.list',
      ]) {
        expect(names, contains(required), reason: 'missing $required');
      }
    });

    test('streaming methods are flagged and aliases resolve', () {
      final table = RpcMethodTable(_services())..build();
      expect(table.isStreaming('agent.run'), isTrue);
      expect(table.isStreaming('agent.external.prompt'), isTrue);
      expect(table.isStreaming('acp.prompt'), isTrue);
      expect(table.isStreaming('engine.render'), isFalse);
      expect(RpcMethod.canonical('acp.agents'), 'agent.external.agents');
      expect(RpcMethod.canonical('engine.render'), 'engine.render');
    });

    test('unknown methods answer unknown_method and wrong verbs 405', () async {
      final host = DesktopRpcHost(services: _services());
      addTearDown(host.dispose);
      await host.start();

      final unknown = await _rpc(host, 'engine.nope');
      expect(unknown.status, 200);
      expect(unknown.result['ok'], isFalse);
      expect(unknown.result['error'], RpcErrorCode.unknownMethod);

      final wrongVerb = await _send(host, 'GET', '/v1/rpc', token: host.status.token);
      expect(wrongVerb.status, 405);
      expect(wrongVerb.json['error'], RpcErrorCode.methodNotAllowed);

      final unknownPath = await _send(host, 'GET', '/v1/nope', token: host.status.token);
      expect(unknownPath.status, 404);
    });

    test('protocol negotiation rejects a future revision', () async {
      final host = DesktopRpcHost(services: _services());
      addTearDown(host.dispose);
      await host.start();

      final reply = await _rpc(host, 'health', protocol: rpcProtocolVersion + 1);
      expect(reply.result['ok'], isFalse);
      expect(reply.result['error'], RpcErrorCode.unsupportedProtocol);
    });
  });

  group('engine face delegates to the local core', () {
    late DesktopRpcHost host;
    late _FakeEngine engine;

    setUp(() async {
      engine = _FakeEngine();
      host = DesktopRpcHost(services: _services(engine: engine));
      await host.start();
    });

    tearDown(() async {
      await host.dispose();
    });

    test('render / apply / session / generate / history', () async {
      final render = await _rpc(host, 'engine.render', params: <String, dynamic>{'mbt': 'MBT_X'});
      expect(render.result['ok'], isTrue);
      expect(render.result['mbt'], 'MBT_X');
      expect((render.result['artboards'] as List).length, 1);

      final apply = await _rpc(
        host,
        'engine.apply',
        params: <String, dynamic>{'mbt': 'MBT_X', 'op': 'move home n1 1 2', 'gate': 'agent'},
      );
      expect(apply.result['ok'], isTrue);
      expect(engine.gates, <String>['agent'], reason: 'the gate must travel verbatim');

      final human = await _rpc(
        host,
        'engine.apply',
        params: <String, dynamic>{'mbt': 'MBT_X', 'op': 'move home n1 3 4'},
      );
      expect(human.result['ok'], isTrue);
      expect(engine.gates.last, 'human', reason: 'the default gate is the human door');

      final session = await _rpc(
        host,
        'engine.session',
        params: <String, dynamic>{'mbt': 'MBT_X', 'name': 'session_list_artboards'},
      );
      expect(session.result['ok'], isTrue);
      expect((session.result['data'] as List).length, 1);

      final generate = await _rpc(
        host,
        'engine.generate',
        params: <String, dynamic>{
          'mbt': 'MBT_X',
          'intent': 'landing',
          'name': 'Home',
          'spec': <String, dynamic>{'pages': 1},
        },
      );
      expect(generate.result['ok'], isTrue);
      expect(generate.result['artboard'], 'Home');

      final history = await _rpc(
        host,
        'engine.history',
        params: <String, dynamic>{'mbt': 'MBT_X', 'command': 'log'},
      );
      expect(history.result['command'], 'log');
    });

    test('invalid gates and non-session calls are rejected as params errors', () async {
      final gate = await _rpc(
        host,
        'engine.apply',
        params: <String, dynamic>{'mbt': 'MBT_X', 'op': 'op', 'gate': 'root'},
      );
      expect(gate.result['error'], RpcErrorCode.invalidParams);

      final session = await _rpc(
        host,
        'engine.session',
        params: <String, dynamic>{'mbt': 'MBT_X', 'name': 'apply-agent-mbt'},
      );
      expect(session.result['error'], RpcErrorCode.invalidParams);
    });

    test('an unavailable engine answers engine_unavailable, never a silent ok', () async {
      engine.ready = false;
      final reply = await _rpc(host, 'engine.render', params: <String, dynamic>{'mbt': 'x'});
      expect(reply.result['ok'], isFalse);
      expect(reply.result['error'], 'engine_unavailable');
    });
  });

  group('project face', () {
    test('save → list → open round-trips through the local library', () async {
      final root = _tempDir();
      final host = DesktopRpcHost(services: _services(projectsRoot: root));
      addTearDown(host.dispose);
      await host.start();
      final path = '${root.path}/demo.ddp';
      const mbt = '## Home\n\n```mbt\nplace home button b1 8 8 100 40\n```\n';

      final saved = await _rpc(
        host,
        'project.save',
        params: <String, dynamic>{
          'path': path,
          'mbt': mbt,
          'docs': <String, dynamic>{'prd': '# 需求'},
        },
      );
      expect(saved.result['ok'], isTrue, reason: '${saved.result}');
      expect(saved.result['bytes'], greaterThan(0));

      final listed = await _rpc(host, 'project.list');
      final projects = listed.result['projects'] as List;
      expect(projects.length, 1);
      expect((projects.single as Map)['name'], 'demo');

      final opened = await _rpc(host, 'project.open', params: <String, dynamic>{'path': path});
      expect(opened.result['ok'], isTrue);
      expect(opened.result['mbt'], contains('place home button b1'));
      expect((opened.result['docs'] as Map)['prd'], '# 需求');
    });

    test('a password-protected project reports need_password', () async {
      final root = _tempDir();
      final host = DesktopRpcHost(services: _services(projectsRoot: root));
      addTearDown(host.dispose);
      await host.start();
      final path = '${root.path}/locked.ddp';

      await _rpc(
        host,
        'project.save',
        params: <String, dynamic>{'path': path, 'mbt': '## A\n', 'password': 'pw'},
      );
      final opened = await _rpc(host, 'project.open', params: <String, dynamic>{'path': path});
      expect(opened.result['ok'], isFalse);
      expect(opened.result['need_password'], isTrue);

      final withPassword = await _rpc(
        host,
        'project.open',
        params: <String, dynamic>{'path': path, 'password': 'pw'},
      );
      expect(withPassword.result['ok'], isTrue);
    });

    test('only .ddp paths are accepted (the token is not a file-write primitive)', () async {
      final host = DesktopRpcHost(services: _services());
      addTearDown(host.dispose);
      await host.start();

      final reply = await _rpc(
        host,
        'project.save',
        params: <String, dynamic>{'path': '/tmp/whatever.txt', 'mbt': 'x'},
      );
      expect(reply.result['ok'], isFalse);
      expect(reply.result['error'], RpcErrorCode.invalidParams);
    });
  });

  group('limits', () {
    test('the body ceiling is 16 MiB', () {
      expect(RpcLimits.maxBodyBytes, 16 * 1024 * 1024);
      expect(RpcHostOptions().maxBodyBytes, RpcLimits.maxBodyBytes);
    });

    test('a body over the configured ceiling answers 413', () async {
      final host = DesktopRpcHost(
        services: _services(),
        options: const RpcHostOptions(maxBodyBytes: 4096),
      );
      addTearDown(host.dispose);
      await host.start();

      final reply = await _send(
        host,
        'POST',
        '/v1/rpc',
        token: host.status.token,
        body: <String, dynamic>{
          'method': 'engine.render',
          'params': <String, dynamic>{'mbt': 'a' * 8192},
        },
      );
      expect(reply.status, 413);
      expect(reply.json['error'], RpcErrorCode.payloadTooLarge);
    });

    test('the default ceiling rejects a 16 MiB + 1 body', () async {
      final host = DesktopRpcHost(services: _services());
      addTearDown(host.dispose);
      await host.start();

      final body = jsonEncode(<String, dynamic>{
        'method': 'engine.render',
        'params': <String, dynamic>{'mbt': 'a' * (RpcLimits.maxBodyBytes + 1)},
      });
      expect(body.length, greaterThan(RpcLimits.maxBodyBytes));
      // 超限契约（跨平台）：要么拿到明确的 413，要么连接被直接丢弃——
      // 两者都算「拒绝」，不接受静默成功。Windows 上服务端排空请求体后
      // 可以回 413；macOS/Linux 上客户端可能在写完前就被断开。
      _Reply? reply;
      Object? dropped;
      try {
        reply = await _send(host, 'POST', '/v1/rpc', token: host.status.token, body: body);
      } catch (error) {
        dropped = error;
      }
      if (reply != null) {
        expect(reply.status, 413);
        expect(reply.json['error'], RpcErrorCode.payloadTooLarge);
      } else {
        expect(dropped, anyOf(isA<SocketException>(), isA<HttpException>()),
            reason: 'the host drops the connection once the ceiling is crossed');
      }
      // The host must still be alive for the next request.
      final health = await _send(host, 'GET', '/v1/health', token: host.status.token);
      expect(health.status, 200);
    });

    test('more than 8 concurrent requests are refused with busy', () async {
      final engine = _FakeEngine()..block = Completer<void>();
      final host = DesktopRpcHost(services: _services(engine: engine));
      addTearDown(host.dispose);
      await host.start();

      final inFlight = <Future<_Reply>>[
        for (var i = 0; i < RpcLimits.maxConcurrentRequests; i++)
          _rpc(host, 'engine.render', params: <String, dynamic>{'mbt': 'MBT_$i'}),
      ];
      // Wait until the engine actually sees all 8 calls.
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (engine.active < RpcLimits.maxConcurrentRequests && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(engine.active, RpcLimits.maxConcurrentRequests);

      final ninth = await _rpc(host, 'engine.render', params: <String, dynamic>{'mbt': 'MBT_9'});
      expect(ninth.status, 503);
      expect(ninth.json['error'], RpcErrorCode.busy);

      // The probe faces stay reachable while saturated.
      final health = await _send(host, 'GET', '/v1/health', token: host.status.token);
      expect(health.status, 200);

      engine.block!.complete();
      final replies = await Future.wait(inFlight);
      expect(replies.every((r) => r.result['ok'] == true), isTrue);
      expect(engine.maxActive, RpcLimits.maxConcurrentRequests);
    });

    test('the stream idle ceiling is 600 s and a stalled stream ends with failed', () async {
      expect(RpcLimits.streamIdleTimeout, const Duration(seconds: 600));

      final host = DesktopRpcHost(
        services: _services(
          agent: _FakeAgentRunner((run, abort) async* {
            yield <String, dynamic>{'type': 'note', 'label': '开始'};
            await Completer<void>().future; // never produces another event
          }),
        ),
        options: const RpcHostOptions(streamIdleTimeout: Duration(milliseconds: 250)),
      );
      addTearDown(host.dispose);
      await host.start();

      final events = await _stream(host, 'agent.run', params: <String, dynamic>{'run_id': 7});
      expect(events.first['type'], 'started');
      expect(events.last['type'], 'failed');
      expect(events.last['error'], RpcErrorCode.streamIdle);
    });
  });

  group('agent.run streaming', () {
    test('events stream in order and end with done', () async {
      final runner = _FakeAgentRunner(_simpleScript);
      final host = DesktopRpcHost(services: _services(agent: runner));
      addTearDown(host.dispose);
      await host.start();

      final events = await _stream(
        host,
        'agent.run',
        params: <String, dynamic>{
          'run_id': 42,
          'mode': 'build',
          'instruction': '做个落地页',
          'mbt': 'MBT_START',
          'model': 'm',
          'base_url': 'u',
          'api_key': 'k',
        },
      );

      expect(events.map((e) => e['type']), <String>['started', 'note', 'assistant_delta', 'done']);
      expect(events.first['run_id'], 42);
      expect(events.last['stopReason'], 'done');
      expect(runner.runs.single.instruction, '做个落地页');
      expect(runner.runs.single.mbt, 'MBT_START');
      expect(host.table.activeRuns, 0, reason: 'the run registry is cleaned up');
    });

    test('agent.cancel cancels the token and the stream still terminates', () async {
      final seen = Completer<CancellationToken>();
      final runner = _FakeAgentRunner((run, abort) async* {
        yield <String, dynamic>{'type': 'note', 'label': '开始'};
        seen.complete(abort);
        await abort.onCancelled;
        yield <String, dynamic>{'type': 'failed', 'error': 'cancelled', 'stopReason': 'cancelled'};
      });
      final host = DesktopRpcHost(services: _services(agent: runner));
      addTearDown(host.dispose);
      await host.start();

      final streaming = _stream(host, 'agent.run', params: <String, dynamic>{'run_id': 11});
      final token = await seen.future;
      expect(token.isCancelled, isFalse);

      final cancelled = await _rpc(host, 'agent.cancel', params: <String, dynamic>{'run_id': 11});
      expect(cancelled.result['ok'], isTrue);
      expect(cancelled.result['cancelled'], isTrue);

      final events = await streaming;
      expect(events.last['type'], 'failed');
      expect(events.last['stopReason'], 'cancelled');

      // Cancelling an unknown run is an honest false, not an error.
      final again = await _rpc(host, 'agent.cancel', params: <String, dynamic>{'run_id': 11});
      expect(again.result['cancelled'], isFalse);
    });

    test('a client that disappears mid-stream cancels the run', () async {
      final seen = Completer<CancellationToken>();
      final runner = _FakeAgentRunner((run, abort) async* {
        yield <String, dynamic>{'type': 'note', 'label': '开始'};
        seen.complete(abort);
        await abort.onCancelled;
        yield <String, dynamic>{'type': 'failed', 'error': 'cancelled', 'stopReason': 'cancelled'};
      });
      final host = DesktopRpcHost(
        services: _services(agent: runner),
        options: const RpcHostOptions(keepAliveInterval: Duration(milliseconds: 100)),
      );
      addTearDown(host.dispose);
      await host.start();

      // A raw socket mimics a phone that vanishes: dart:io does not report a
      // peer reset as an exception, so the host notices through the keep-alive
      // flush deadline (2 × 100 ms). This is the path that stops a run from
      // burning tokens for an hour after the phone leaves the network.
      final body = jsonEncode(<String, dynamic>{
        'method': 'agent.run',
        'params': <String, dynamic>{'run_id': 3},
      });
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, host.port);
      socket.write(
        'POST /v1/rpc HTTP/1.1\r\n'
        'Host: 127.0.0.1\r\n'
        'Authorization: Bearer ${host.status.token}\r\n'
        'Accept: text/event-stream\r\n'
        'Content-Type: application/json\r\n'
        'Content-Length: ${utf8.encode(body).length}\r\n'
        '\r\n'
        '$body',
      );
      await socket.flush();
      final gotData = Completer<void>();
      socket.listen((_) {
        if (!gotData.isCompleted) gotData.complete();
      });
      await gotData.future.timeout(const Duration(seconds: 5));
      final token = await seen.future.timeout(const Duration(seconds: 5));
      expect(token.isCancelled, isFalse);

      socket.destroy();

      // CI 实测偶发：对端被 destroy 后，循环回环上的写不一定在第一个
      // 2×keepAlive（200ms）内报错——有的内核把写成功吞掉，要等下一个
      // keep-alive 才暴露（2026-11-19 再证：20s 窗口在 macos-26 runner 上
      // 仍两次全红）。放宽到 60s——仍是有限等待，语义只断言「最终会被
      // keep-alive 写期限取消」。
      final deadline = DateTime.now().add(const Duration(seconds: 60));
      while (!token.isCancelled && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(token.isCancelled, isTrue, reason: 'keep-alive write deadline must cancel the run');
    }, skip: Platform.isWindows
        ? 'Windows loopback 不把对端 destroy 暴露为 socket 写错误（写一直成功），'
            'keep-alive 写期限在 Windows 上测不到；取消链路由 agent.cancel 用例覆盖'
        : null);

    test('a runner that ends without a terminal event is closed with failed', () async {
      final host = DesktopRpcHost(
        services: _services(
          agent: _FakeAgentRunner((run, abort) async* {
            yield <String, dynamic>{'type': 'note', 'label': '开始'};
          }),
        ),
      );
      addTearDown(host.dispose);
      await host.start();

      final events = await _stream(host, 'agent.run', params: <String, dynamic>{'run_id': 5});
      expect(events.last['type'], 'failed');
      expect(events.last['error'], 'agent_incomplete');
    });
  });

  group('external agents', () {
    test('list → session → prompt (with permission) → close', () async {
      final acp = _FakeAcpRuntime();
      final host = DesktopRpcHost(services: _services(acp: acp));
      addTearDown(host.dispose);
      await host.start();

      final agents = await _rpc(host, 'agent.external.agents');
      expect(agents.result['ok'], isTrue);
      expect((agents.result['agents'] as List).length, 1);

      final session = await _rpc(
        host,
        'agent.external.session',
        params: <String, dynamic>{'agent': 'fake'},
      );
      expect(session.result['ok'], isTrue, reason: '${session.result}');
      final sessionId = session.result['session_id'] as String;
      expect(acp.started, <String>['fake']);

      // The prompt stream stays open while the permission is answered: this is
      // exactly the shape a phone sees (event first, decision second).
      final stream = await _openSse(
        host,
        'agent.external.prompt',
        params: <String, dynamic>{'session_id': sessionId, 'text': '你好'},
      );
      final events = <Map<String, dynamic>>[];
      final terminal = Completer<void>();
      final sub = stream.events.listen((event) {
        events.add(event);
        if ((event['type'] == 'done' || event['type'] == 'failed') && !terminal.isCompleted) {
          terminal.complete();
        }
      });

      final permission = await _waitForType(events, 'permission');
      expect((permission['options'] as List).length, 2);

      final answered = await _rpc(
        host,
        'agent.external.permission',
        params: <String, dynamic>{
          'session_id': sessionId,
          'request_id': permission['request_id'],
          'option_id': 'allow',
        },
      );
      expect(answered.result['ok'], isTrue);

      await terminal.future.timeout(const Duration(seconds: 5));
      expect(events.last['type'], 'done', reason: '$events');
      await sub.cancel();
      await stream.close();

      final closed = await _rpc(
        host,
        'agent.external.close',
        params: <String, dynamic>{'session_id': sessionId},
      );
      expect(closed.result['ok'], isTrue);
      expect(closed.result['closed'], isTrue);
    });

    test('the acp.* aliases reach the same handlers', () async {
      final host = DesktopRpcHost(services: _services(acp: _FakeAcpRuntime()));
      addTearDown(host.dispose);
      await host.start();

      final agents = await _rpc(host, 'acp.agents');
      expect(agents.result['ok'], isTrue);
      expect((agents.result['agents'] as List).length, 1);
    });

    test('without a desktop runtime the face answers an honest empty list', () async {
      final host = DesktopRpcHost(services: _services());
      addTearDown(host.dispose);
      await host.start();

      final agents = await _rpc(host, 'agent.external.agents');
      expect(agents.result['ok'], isTrue);
      expect(agents.result['agents'], isEmpty);
    });
  });

  group('caps, capabilities and honest degradation', () {
    test('capabilities mirror the wired services', () async {
      final host = DesktopRpcHost(services: _services(acp: _FakeAcpRuntime()));
      addTearDown(host.dispose);
      await host.start();

      final reply = await _send(host, 'GET', '/v1/capabilities', token: host.status.token);
      expect(reply.status, 200);
      final caps = (reply.json['capabilities'] as Map).cast<String, bool>();
      expect(caps['engine'], isTrue);
      expect(caps['projects'], isTrue);
      expect(caps['agent'], isTrue);
      expect(caps['acp'], isTrue);
      expect(reply.json['protocol'], rpcProtocolVersion);
    });

    test('video review and samples work without any desktop binary', () async {
      final host = DesktopRpcHost(services: _services());
      addTearDown(host.dispose);
      await host.start();

      final samples = await _rpc(host, 'video.samples');
      expect(samples.result['ok'], isTrue);
      expect(samples.result['samples'], isNotEmpty);

      final sample = await _rpc(host, 'video.sample', params: <String, dynamic>{'index': 0});
      expect(sample.result['ok'], isTrue);
      final review = await _rpc(
        host,
        'video.review',
        params: <String, dynamic>{
          'timeline': sample.result['timeline'],
          'spec': sample.result['spec'],
        },
      );
      expect(review.result['total_seconds'], greaterThan(0));
      expect(review.result['summary'], isNotEmpty);
    });

    test('models.snapshot is honest when the snapshot was not wired', () async {
      final host = DesktopRpcHost(services: _services());
      addTearDown(host.dispose);
      await host.start();

      final reply = await _rpc(host, 'models.snapshot');
      expect(reply.result['ok'], isFalse);
      expect(reply.result['error'], 'models_unavailable');
    });
  });
}
