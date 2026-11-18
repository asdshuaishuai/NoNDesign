// "连接桌面" RPC contract (batch 05).
//
// The desktop host itself lands in batch 10; this test pins the *client* side
// of the contract so the host has something concrete to implement:
//
//   GET  /v1/health        → {ok, version}
//   GET  /v1/capabilities  → {ok, version, capabilities:{engine, agent, …}}
//   POST /v1/rpc           → {ok, result}
//        method table: health / capabilities / engine.render / engine.apply /
//        project.list / agent.run (streaming) …
//
// Also pinned here:
//  * token travels as `authorization: Bearer …` on every request;
//  * an unreachable desktop is an explicit error (never a silent local
//    fallback);
//  * a stalled `agent.run` stream always ends with a terminal failed event;
//  * the router prefers the local engine and only falls back to the desktop.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nondesign/core/api.dart';
import 'package:nondesign/core/capability.dart';
import 'package:nondesign/core/project_service.dart';
import 'package:nondesign/core/remote_desktop_client.dart';

// ---------------------------------------------------------------------------
// Fake local engine (the real one is a WASM host; batch 02 owns it)
// ---------------------------------------------------------------------------

class _FakeEngine implements LocalEngine {
  bool ready = true;
  String canonical = 'MBT_0';
  String startupErrorText = 'engine fixture';
  int renderCalls = 0;
  final List<String> gates = [];
  final List<String> appliedOps = [];
  final List<String> appliedBases = [];
  final List<String> sessionNames = [];

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
  String? get startupError => ready ? null : startupErrorText;

  @override
  CapabilityAvailability probeAvailability() => ready
      ? const CapabilityAvailability.available(CapabilityId.localDesignEngine)
      : CapabilityAvailability.unavailable(
          CapabilityId.localDesignEngine,
          technicalDetail: startupErrorText,
        );

  @override
  Future<Map<String, dynamic>> render(String mbt) async {
    renderCalls++;
    canonical = mbt;
    return _envelope(mbt);
  }

  @override
  Future<Map<String, dynamic>> validate(String mbt) async => {'ok': true, 'mbt': mbt};

  @override
  Future<Map<String, dynamic>> apply(String mbt, String op, {String gate = 'human'}) async {
    gates.add(gate);
    appliedOps.add(op);
    appliedBases.add(mbt);
    canonical = 'MBT_${appliedOps.length}';
    return _envelope(canonical);
  }

  @override
  Future<Map<String, dynamic>> session(String mbt, String name, [String? arg]) async {
    sessionNames.add(name);
    return {
      'ok': true,
      'data': name == 'session_list_artboards'
          ? [
              {'id': 'home', 'nodes': 1, 'width': 390, 'height': 844},
            ]
          : const [],
    };
  }

  @override
  Future<Map<String, dynamic>> generate(
          String mbt, String intent, String name, Map<String, dynamic> spec) async =>
      {'ok': true, 'mbt': '$mbt<!-- $intent -->', 'artboard': name};

  @override
  Future<Map<String, dynamic>> tap(String mbt, String artboard, double x, double y) async =>
      {'ok': true, 'current': artboard};

  @override
  Future<Map<String, dynamic>> constrainIntent(String mbt, String artboard, String intent) async =>
      {'ok': true, 'mbt': mbt};

  @override
  Future<Map<String, dynamic>> event(String mbt, String artboard, String spec) async =>
      {'ok': true, 'current': artboard};

  @override
  Future<Map<String, dynamic>> history(String mbt, String command) async => {'ok': true};

  @override
  Future<Map<String, dynamic>> exportHtml(String mbt) async => {'ok': true, 'html': '<html></html>'};

  @override
  Future<Map<String, dynamic>> tokens() async => {'ok': true, 'data': const []};

  @override
  Future<Map<String, dynamic>> versionInfo() async => {'ok': true, 'version': 'fixture'};

  @override
  Future<List<dynamic>> templates() async => [
        {'id': 'pc_app', 'name': 'PC App'},
      ];

  @override
  Future<List<dynamic>> components() async => ['button', 'text'];

  @override
  Future<List<dynamic>> themes() async => ['dark'];

  @override
  Future<List<dynamic>> ops() async => ['place'];
}

// ---------------------------------------------------------------------------
// Fake desktop host
// ---------------------------------------------------------------------------

/// HTTP JSON server implementing the RPC contract (non-streaming faces).
Future<(String, _FakeDesktop)> _startFakeDesktop() async {
  final desktop = _FakeDesktop();
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  desktop._server = server;
  server.listen((request) async {
    final chunks = await request.fold<List<int>>([], (a, b) => a..addAll(b));
    final raw = chunks.isEmpty ? '{}' : utf8.decode(chunks);
    final body = (jsonDecode(raw) as Map).cast<String, dynamic>();
    desktop.auth.add(request.headers.value('authorization'));
    desktop.paths.add(request.uri.path);

    Future<void> json(Map<String, dynamic> payload, [int status = 200]) async {
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(payload));
      await request.response.close();
    }

    if (request.uri.path == '/v1/health') {
      if (desktop.rejectToken && request.headers.value('authorization') != 'Bearer good-token') {
        return json({'ok': false, 'error': 'unauthorized'}, 401);
      }
      return json({'ok': true, 'version': 'desktop-1', 'name': 'fixture'});
    }
    if (request.uri.path == '/v1/capabilities') {
      return json({
        'ok': true,
        'version': 'desktop-1',
        'capabilities': {'engine': true, 'agent': true, 'projects': true},
      });
    }
    if (request.uri.path == '/v1/rpc') {
      final method = body['method']?.toString() ?? '';
      final params = (body['params'] as Map?)?.cast<String, dynamic>() ?? const {};
      desktop.methods.add(method);
      switch (method) {
        case 'engine.render':
          return json({
            'ok': true,
            'result': {
              'ok': true,
              'mbt': params['mbt'],
              'entry': 'home',
              'artboards': [
                {'id': 'home', 'name': 'home', 'width': 390, 'height': 844, 'nodes': []},
              ],
              'flows': [],
            },
          });
        case 'engine.apply':
          desktop.lastGate = params['gate']?.toString();
          return json({
            'ok': true,
            'result': {'ok': true, 'mbt': 'REMOTE_MBT', 'entry': 'home', 'artboards': [], 'flows': []},
          });
        case 'project.list':
          return json({
            'ok': true,
            'result': {
              'ok': true,
              'projects': [
                {'path': '/remote/a.ddp', 'name': 'a', 'bytes': 10, 'modified': 1.0},
              ],
            },
          });
        case 'engine.session':
          return json({
            'ok': true,
            'result': {
              'ok': true,
              'data': [
                {'id': 'home', 'nodes': 2},
              ],
            },
          });
        case 'agent.external.prompt':
          return json({
            'ok': true,
            'result': {'type': 'done', 'text': 'ok', 'stopReason': 'done'},
          });
        default:
          return json({'ok': false, 'error': 'unknown_method', 'detail': method}, 404);
      }
    }
    return json({'ok': false, 'error': 'not_found'}, 404);
  });
  return ('http://127.0.0.1:${server.port}', desktop);
}

class _FakeDesktop {
  HttpServer? _server;
  final List<String?> auth = [];
  final List<String> paths = [];
  final List<String> methods = [];
  bool rejectToken = false;
  String? lastGate;

  Future<void> close() async {
    await _server?.close(force: true);
  }
}

/// Raw-socket SSE server: `dart:io`'s HttpResponse buffers the body until
/// close, so a real "connection alive, events arriving one by one" stream can
/// only be produced by writing chunked frames on a socket.
///
/// The request (headers + `content-length` body) is drained **before** the
/// first response byte goes out. A real host reads the request first; answering
/// and closing while the client is still writing its POST body makes the kernel
/// answer with RST, and the client's write dies with EPIPE
/// (`SocketException: Write failed … Broken pipe`) before it can read a single
/// event — a ~25% flake when it did.
Future<(String, Future<void> Function())> _sseServer(
  Future<void> Function(Future<void> Function(Map<String, dynamic> event) send) script,
) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final sockets = <Socket>[];
  final sub = server.listen((socket) {
    sockets.add(socket);

    void start() {
      socket.write('HTTP/1.1 200 OK\r\n'
          'content-type: text/event-stream\r\n'
          'transfer-encoding: chunked\r\n\r\n');
      Future<void> send(Map<String, dynamic> event) async {
        final data = utf8.encode('data: ${jsonEncode(event)}\n\n');
        socket.add(utf8.encode('${data.length.toRadixString(16)}\r\n'));
        socket.add(data);
        socket.add(utf8.encode('\r\n'));
        await socket.flush();
      }

      unawaited(socket.flush().then((_) => script(send)).then((_) async {
        socket.add(utf8.encode('0\r\n\r\n'));
        await socket.flush();
        socket.destroy();
      }));
    }

    // Wait for the whole request, then answer (see doc comment).
    final received = <int>[];
    var headerEnd = -1;
    var contentLength = 0;
    var started = false;
    socket.listen((chunk) {
      if (started) return;
      received.addAll(chunk);
      if (headerEnd < 0) {
        final text = latin1.decode(received);
        final end = text.indexOf('\r\n\r\n');
        if (end < 0) return;
        headerEnd = end + 4;
        final match = RegExp(r'content-length:\s*(\d+)', caseSensitive: false)
            .firstMatch(text.substring(0, end));
        contentLength = int.tryParse(match?.group(1) ?? '') ?? 0;
      }
      if (received.length - headerEnd < contentLength) return;
      started = true;
      start();
    });
  });
  return (
    'http://127.0.0.1:${server.port}',
    () async {
      await sub.cancel();
      for (final socket in sockets) {
        try {
          socket.destroy();
        } catch (_) {}
      }
      await server.close();
    },
  );
}

void main() {
  test('probe reads health + capabilities and reports the host version', () async {
    final (base, desktop) = await _startFakeDesktop();
    addTearDown(desktop.close);
    final client = RemoteDesktopClient(baseUrl: base, token: 'good-token');
    addTearDown(client.close);

    final status = await client.probe();

    expect(status.configured, isTrue);
    expect(status.connected, isTrue);
    expect(status.version, 'desktop-1');
    expect(status.supports('engine'), isTrue);
    expect(status.message, '已连接桌面');
    expect(desktop.paths, containsAllInOrder(['/v1/health', '/v1/capabilities']));
  });

  test('method table: engine.render / engine.apply / project.list / engine.session', () async {
    final (base, desktop) = await _startFakeDesktop();
    addTearDown(desktop.close);
    final api = NoNDesignApi(base, http.Client());
    addTearDown(() => api.remote?.close());

    final rendered = await api.render('MBT_X');
    expect(rendered['ok'], isTrue);
    expect(rendered['mbt'], 'MBT_X');
    expect(rendered['artboards'], hasLength(1));

    final applied = await api.apply('MBT_X', 'move home n1 1 2', gate: 'agent');
    expect(applied['ok'], isTrue);
    expect(applied['mbt'], 'REMOTE_MBT');
    expect(desktop.lastGate, 'agent', reason: 'agent gate must travel verbatim');

    final projects = await api.listProjects();
    expect((projects.single as Map)['path'], '/remote/a.ddp');

    final session = await api.session('MBT_X', 'session_list_artboards');
    expect((session['data'] as List).single['nodes'], 2);

    expect(
      desktop.methods,
      containsAll(['engine.render', 'engine.apply', 'project.list', 'engine.session']),
    );
    // Every call is one POST /v1/rpc — no per-feature routes.
    expect(desktop.paths.where((p) => p != '/v1/health').toSet(), {'/v1/rpc'});
  });

  test('external-agent prompts use their own streaming method', () async {
    final (base, desktop) = await _startFakeDesktop();
    addTearDown(desktop.close);
    final api = NoNDesignApi(base, http.Client());
    addTearDown(() => api.remote?.close());

    final events = await api.acpPrompt('sid', 'hello').toList();

    expect(events.single['type'], 'done');
    expect(desktop.methods, ['agent.external.prompt'],
        reason: 'ACP 走独立的流式方法，不是把参数塞进 agent.run');
  });

  test('the token travels as a Bearer header and a bad token is explicit', () async {
    final (base, desktop) = await _startFakeDesktop();
    addTearDown(desktop.close);
    desktop.rejectToken = true;

    final bad = RemoteDesktopClient(baseUrl: base, token: 'wrong');
    addTearDown(bad.close);
    final rejected = await bad.probe();
    expect(rejected.connected, isFalse);
    expect(rejected.authorized, isFalse);
    expect(rejected.reason, RemoteErrorCode.unauthorized);
    expect(rejected.message, contains('连接码'));
    expect(desktop.auth.first, 'Bearer wrong');

    final good = RemoteDesktopClient(baseUrl: base, token: 'good-token');
    addTearDown(good.close);
    final ok = await good.probe();
    expect(ok.connected, isTrue);
    expect(desktop.auth.last, 'Bearer good-token');
  });

  test('agent.run streams events over the RPC contract and stops at done', () async {
    final (base, close) = await _sseServer((send) async {
      await send({'type': 'note', 'label': '开始'});
      await send({'type': 'assistant_delta', 'text': 'hi'});
      await send({'type': 'done', 'text': 'ok', 'stopReason': 'done'});
    });
    addTearDown(close);
    final client = RemoteDesktopClient(baseUrl: base);
    addTearDown(client.close);

    final events = await client
        .agentRun({'run_id': 1, 'mode': 'plan', 'instruction': 'x'})
        .toList()
        .timeout(const Duration(seconds: 5));

    expect(events.map((e) => e['type']), ['note', 'assistant_delta', 'done']);
    expect(events.last['text'], 'ok');
  });

  test('a stalled agent stream always ends with a failed terminal', () async {
    RemoteDesktopClient.sseIdleTimeout = const Duration(milliseconds: 250);
    addTearDown(() => RemoteDesktopClient.sseIdleTimeout = const Duration(seconds: 660));
    final (base, close) = await _sseServer((send) async {
      await send({'type': 'note', 'label': '开始'});
      await Completer<void>().future; // alive but silent
    });
    addTearDown(close);
    final client = RemoteDesktopClient(baseUrl: base);
    addTearDown(client.close);

    final events = await client
        .agentRun({'run_id': 1, 'mode': 'build', 'instruction': 'x'})
        .toList()
        .timeout(const Duration(seconds: 5));

    expect(events.map((e) => e['type']), ['note', 'failed']);
    expect(events.last['error'], RemoteErrorCode.streamIdle);
  });

  test('an unreachable desktop answers remote_unreachable — never a silent success', () async {
    // Port 1 has no listener: connection is refused quickly.
    final client = RemoteDesktopClient(baseUrl: 'http://127.0.0.1:1', token: 't');
    addTearDown(client.close);

    final status = await client.probe();
    expect(status.configured, isTrue);
    expect(status.reachable, isFalse);
    expect(status.connected, isFalse);
    expect(status.message, contains('连接桌面没有成功'));

    final rendered = await client.call('engine.render', {'mbt': ''});
    expect(rendered['ok'], isFalse);
    expect(rendered['error'], RemoteErrorCode.unreachable);

    final events = await client.agentRun({'run_id': 1}).toList();
    expect(events.single['type'], 'failed');
    expect(events.single['error'], RemoteErrorCode.unreachable);
  });

  test('router prefers the local engine; remote is only the fallback', () async {
    final (base, desktop) = await _startFakeDesktop();
    addTearDown(desktop.close);
    final engine = _FakeEngine();
    final local = LocalCore(engine: engine, projects: ProjectService(root: () async => Directory.systemTemp));
    final router = NoNDesignApi.runtime(
      local: local,
      remote: RemoteDesktopClient(baseUrl: base, token: 'good-token'),
    );
    addTearDown(() => router.remote?.close());

    final res = await router.render('MBT_LOCAL');
    expect(res['ok'], isTrue);
    expect(engine.renderCalls, 1);
    expect(desktop.methods, isEmpty, reason: 'local engine must win when it is ready');

    // Local unavailable + remote connected → remote answers.
    engine.ready = false;
    final remoteRes = await router.render('MBT_REMOTE');
    expect(remoteRes['ok'], isTrue);
    expect(desktop.methods, contains('engine.render'));

    // Neither runtime → explicit engine_unavailable.
    final bare = NoNDesignApi.runtime();
    final missing = await bare.render('x');
    expect(missing['ok'], isFalse);
    expect(missing['error'], 'engine_unavailable');
  });

  test('baseUrl normalisation strips slashes and adds a scheme', () {
    expect(RemoteDesktopClient.normalizeBaseUrl('  http://h:1/// '), 'http://h:1');
    expect(RemoteDesktopClient.normalizeBaseUrl('192.168.1.9:8799'), 'http://192.168.1.9:8799');
    expect(RemoteDesktopClient.normalizeBaseUrl(''), '');
  });

  test('remote generative calls carry the long LLM timeout', () async {
    expect(RemoteDesktopClient.llmGenTimeout, const Duration(minutes: 10));
    RemoteDesktopClient.llmGenTimeout = const Duration(milliseconds: 120);
    addTearDown(() => RemoteDesktopClient.llmGenTimeout = const Duration(minutes: 10));
    final api = NoNDesignApi('http://127.0.0.1:1', _SlowClient());
    addTearDown(() => api.remote?.close());

    final res = await api.threeNewProject(
      name: 'saturn',
      brief: 'ringed planet',
      model: 'm',
      baseUrl: 'u',
      apiKey: 'k',
      thinkingLevel: 'off',
    );
    expect(res['ok'], isFalse);
    expect(res['error'], RemoteErrorCode.timeout);
  });
}

/// Client whose every request takes longer than the shortened LLM budget.
class _SlowClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    return http.StreamedResponse(
      Stream<List<int>>.fromIterable([
        utf8.encode('{"ok":true}'),
      ]),
      200,
    );
  }
}
