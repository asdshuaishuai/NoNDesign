// "连接桌面" end-to-end: the real client (`RemoteDesktopClient`, the same code
// that runs on a phone) against the real desktop host (`DesktopRpcHost`).
//
// The host is a `dart:io` server on loopback with a token; the client speaks
// the `/v1/health`, `/v1/capabilities` and `/v1/rpc` contract. Everything runs
// in-process here, which is exactly what the phone does over the network —
// only the transport distance differs.
//
// Covered:
//  * probe (health + capabilities) and the user-facing status sentence;
//  * a wrong token is `remote_unauthorized`, an address with no listener is
//    `remote_unreachable` — never a silent local fallback;
//  * project.list / engine.render / engine.apply over `NoNDesignApi.runtime`;
//  * `agent.run` streaming (SSE) through the client, and `agent.cancel`;
//  * the desktop stopping makes the next probe fail honestly.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ai_sdk_dart/ai_sdk_dart.dart' show CancellationToken;
import 'package:flutter_test/flutter_test.dart';
import 'package:nondesign/core/api.dart';
import 'package:nondesign/core/capability.dart';
import 'package:nondesign/core/project_service.dart';
import 'package:nondesign/core/remote/desktop_rpc_host.dart';
import 'package:nondesign/core/remote/rpc_methods.dart';
import 'package:nondesign/core/remote_desktop_client.dart';

// ---------------------------------------------------------------------------
// Local core fixtures (no wasm, no network)
// ---------------------------------------------------------------------------

class _Engine implements LocalEngine {
  String canonical = 'MBT_START';
  final List<String> gates = <String>[];

  @override
  bool get isReady => true;

  @override
  String? get startupError => null;

  @override
  CapabilityAvailability probeAvailability() =>
      const CapabilityAvailability.available(CapabilityId.localDesignEngine);

  @override
  Future<Map<String, dynamic>> render(String mbt) async => <String, dynamic>{
    'ok': true,
    'mbt': mbt,
    'entry': 'home',
    'revision': 3,
    'artboards': <Map<String, dynamic>>[
      <String, dynamic>{'id': 'home', 'name': 'home', 'width': 390, 'height': 844, 'nodes': <dynamic>[]},
    ],
    'flows': <dynamic>[],
  };

  @override
  Future<Map<String, dynamic>> validate(String mbt) async => <String, dynamic>{'ok': true, 'mbt': mbt};

  @override
  Future<Map<String, dynamic>> apply(String mbt, String op, {String gate = 'human'}) async {
    gates.add(gate);
    canonical = 'MBT_AFTER';
    return render(canonical);
  }

  @override
  Future<Map<String, dynamic>> session(String mbt, String name, [String? arg]) async =>
      <String, dynamic>{'ok': true, 'data': <dynamic>[]};

  @override
  Future<Map<String, dynamic>> generate(
    String mbt,
    String intent,
    String name,
    Map<String, dynamic> spec,
  ) async => <String, dynamic>{'ok': true, 'mbt': mbt, 'artboard': name};

  @override
  Future<Map<String, dynamic>> tap(String mbt, String artboard, double x, double y) async =>
      <String, dynamic>{'ok': true};

  @override
  Future<Map<String, dynamic>> constrainIntent(String mbt, String artboard, String intent) async =>
      <String, dynamic>{'ok': true};

  @override
  Future<Map<String, dynamic>> event(String mbt, String artboard, String spec) async =>
      <String, dynamic>{'ok': true};

  @override
  Future<Map<String, dynamic>> history(String mbt, String command) async => <String, dynamic>{'ok': true};

  @override
  Future<Map<String, dynamic>> exportHtml(String mbt) async =>
      <String, dynamic>{'ok': true, 'html': '<html></html>'};

  @override
  Future<Map<String, dynamic>> tokens() async => <String, dynamic>{'ok': true, 'data': <dynamic>[]};

  @override
  Future<Map<String, dynamic>> versionInfo() async => <String, dynamic>{'ok': true, 'version': 'fixture'};

  @override
  Future<List<dynamic>> templates() async => const <dynamic>[];

  @override
  Future<List<dynamic>> components() async => const <dynamic>[];

  @override
  Future<List<dynamic>> themes() async => const <dynamic>[];

  @override
  Future<List<dynamic>> ops() async => const <dynamic>[];
}

class _Runner extends RpcAgentRunner {
  _Runner(this.script);

  final Stream<Map<String, dynamic>> Function(RpcAgentRun run, CancellationToken abort) script;
  final List<RpcAgentRun> runs = <RpcAgentRun>[];

  @override
  Stream<Map<String, dynamic>> run(RpcAgentRun run, CancellationToken abort) {
    runs.add(run);
    return script(run, abort);
  }
}

Stream<Map<String, dynamic>> _script(RpcAgentRun run, CancellationToken abort) async* {
  yield <String, dynamic>{'type': 'note', 'label': '开始'};
  yield <String, dynamic>{'type': 'assistant_delta', 'text': '正在设计'};
  yield <String, dynamic>{
    'type': 'done',
    'text': '完成',
    'stopReason': 'done',
    'mbt_b64': base64Encode(utf8.encode('MBT_DONE')),
  };
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

Directory _tempDir() {
  final dir = Directory.systemTemp.createTempSync('nondesign-rpc-e2e-');
  addTearDown(() {
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } catch (_) {}
  });
  return dir;
}

RpcServices _services({RpcAgentRunner? agent, Directory? root}) {
  final projects = root ?? _tempDir();
  return RpcServices(
    core: LocalCore(engine: _Engine(), projects: ProjectService(root: () async => projects)),
    agent: agent ?? _Runner(_script),
    systemAcp: false,
  );
}

void main() {
  test('client ↔ host: probe, project.list, engine.render, agent.run stream', () async {
    final runner = _Runner(_script);
    final root = _tempDir();
    final host = DesktopRpcHost(services: _services(agent: runner, root: root));
    addTearDown(host.dispose);
    final status = await host.start();
    expect(status.running, isTrue);

    final client = RemoteDesktopClient(baseUrl: status.baseUrl, token: status.token);
    addTearDown(client.close);

    // 1. Probe reads health + capabilities.
    final probed = await client.probe();
    expect(probed.connected, isTrue, reason: '${probed.reason}');
    expect(probed.version, isNotEmpty);
    expect(probed.supports('engine'), isTrue);
    expect(probed.supports('agent'), isTrue);
    expect(probed.supports('projects'), isTrue);
    expect(probed.message, '已连接桌面');

    // 2. Project list: empty library answers an empty list, not an error.
    final projects = await client.call('project.list');
    expect(projects['ok'], isTrue);
    expect(projects['projects'], isEmpty);

    // 3. Project save/open round-trip through the host's library.
    final path = '${root.path}/shared.ddp';
    final saved = await client.call('project.save', <String, dynamic>{
      'path': path,
      'mbt': '## Home\n\n```mbt\nplace home button b1 8 8 100 40\n```\n',
    });
    expect(saved['ok'], isTrue, reason: '$saved');
    final opened = await client.call('project.open', <String, dynamic>{'path': path});
    expect(opened['ok'], isTrue);
    expect(opened['mbt'], contains('place home button b1'));

    // 4. Engine render + apply (the gate travels).
    final rendered = await client.call('engine.render', <String, dynamic>{'mbt': 'MBT_X'});
    expect(rendered['ok'], isTrue);
    expect((rendered['artboards'] as List).length, 1);

    final applied = await client.call('engine.apply', <String, dynamic>{
      'mbt': 'MBT_X',
      'op': 'move home b1 1 2',
      'gate': 'agent',
    });
    expect(applied['ok'], isTrue);
    expect(applied['mbt'], 'MBT_AFTER');

    // 5. The app router (local engine missing) forwards to the host.
    final router = NoNDesignApi.runtime(remote: RemoteDesktopClient(baseUrl: status.baseUrl, token: status.token));
    addTearDown(() => router.remote?.close());
    final viaRouter = await router.render('MBT_ROUTER');
    expect(viaRouter['ok'], isTrue);
    expect(viaRouter['mbt'], 'MBT_ROUTER');

    // 6. Streaming agent run: same client call the phone makes.
    final events = await client
        .agentRun(<String, dynamic>{
          'run_id': 99,
          'mode': 'build',
          'instruction': '做一个落地页',
          'mbt': 'MBT_START',
          'model': 'm',
          'base_url': 'u',
          'api_key': 'k',
        })
        .toList()
        .timeout(const Duration(seconds: 10));
    expect(events.first['type'], 'started');
    expect(events.first['run_id'], 99);
    expect(events.map((e) => e['type']), containsAll(<String>['note', 'assistant_delta', 'done']));
    expect(events.last['stopReason'], 'done');
    expect(runner.runs.single.instruction, '做一个落地页');
  });

  test('a wrong token is remote_unauthorized with a human sentence', () async {
    final host = DesktopRpcHost(services: _services());
    addTearDown(host.dispose);
    final status = await host.start();

    final bad = RemoteDesktopClient(baseUrl: status.baseUrl, token: 'wrong-token-value');
    addTearDown(bad.close);
    final probed = await bad.probe();

    expect(probed.configured, isTrue);
    expect(probed.connected, isFalse);
    expect(probed.authorized, isFalse);
    expect(probed.reason, RemoteErrorCode.unauthorized);
    expect(probed.message, contains('连接码'));

    final call = await bad.call('engine.render', <String, dynamic>{'mbt': ''});
    expect(call['ok'], isFalse);
    expect(call['error'], RemoteErrorCode.unauthorized);

    // The same token from the other client shape (raw header) is accepted.
    final good = RemoteDesktopClient(baseUrl: status.baseUrl, token: status.token);
    addTearDown(good.close);
    expect((await good.probe()).connected, isTrue);
  });

  test('agent.cancel over the wire ends the stream with a terminal event', () async {
    final seen = Completer<CancellationToken>();
    final runner = _Runner((run, abort) async* {
      yield <String, dynamic>{'type': 'note', 'label': '开始'};
      seen.complete(abort);
      await abort.onCancelled;
      yield <String, dynamic>{'type': 'failed', 'error': 'cancelled', 'stopReason': 'cancelled'};
    });
    final host = DesktopRpcHost(services: _services(agent: runner));
    addTearDown(host.dispose);
    final status = await host.start();
    final client = RemoteDesktopClient(baseUrl: status.baseUrl, token: status.token);
    addTearDown(client.close);

    final events = <Map<String, dynamic>>[];
    final finished = Completer<void>();
    final sub = client
        .agentRun(<String, dynamic>{'run_id': 7, 'mode': 'build', 'instruction': 'x'})
        .listen(
          (event) {
            events.add(event);
            if ((event['type'] == 'done' || event['type'] == 'failed') && !finished.isCompleted) {
              finished.complete();
            }
          },
          onError: (Object error) {
            if (!finished.isCompleted) finished.completeError(error);
          },
        );

    await seen.future.timeout(const Duration(seconds: 5));
    final cancelled = await client.cancelAgent(7);
    expect(cancelled['ok'], isTrue);
    expect(cancelled['cancelled'], isTrue);
    await finished.future.timeout(const Duration(seconds: 10));

    expect(events.last['type'], 'failed');
    expect(events.last['stopReason'], 'cancelled');
    await sub.cancel();
  });

  test('an unreachable address and a stopped host both fail explicitly', () async {
    // No listener on port 1.
    final dead = RemoteDesktopClient(baseUrl: 'http://127.0.0.1:1', token: 't');
    addTearDown(dead.close);
    final deadProbe = await dead.probe();
    expect(deadProbe.reachable, isFalse);
    expect(deadProbe.connected, isFalse);
    expect(deadProbe.message, contains('连接桌面没有成功'));

    final host = DesktopRpcHost(services: _services());
    final status = await host.start();
    final client = RemoteDesktopClient(baseUrl: status.baseUrl, token: status.token);
    addTearDown(client.close);
    expect((await client.probe()).connected, isTrue);

    await host.stop();
    final afterStop = await client.probe();
    expect(afterStop.connected, isFalse);
    expect(afterStop.reachable, isFalse);

    final events = await client.agentRun(<String, dynamic>{'run_id': 1}).toList();
    expect(events.single['type'], 'failed');
    expect(events.single['error'], isNotNull);
  });

  test('unknown methods survive the round trip as a domain error', () async {
    final host = DesktopRpcHost(services: _services());
    addTearDown(host.dispose);
    final status = await host.start();
    final client = RemoteDesktopClient(baseUrl: status.baseUrl, token: status.token);
    addTearDown(client.close);

    final reply = await client.call('engine.teleport', <String, dynamic>{});
    expect(reply['ok'], isFalse);
    expect(reply['error'], 'unknown_method');
    expect(reply['detail'], contains('engine.teleport'));
  });

  test('the protocol version a future client announces is rejected', () async {
    final host = DesktopRpcHost(services: _services());
    addTearDown(host.dispose);
    final status = await host.start();

    // Raw request: the typed client does not expose the envelope field.
    final raw = await _rawRpc(status.baseUrl, status.token, <String, dynamic>{
      'method': 'health',
      'protocol': 99,
    });
    expect(raw['ok'], isTrue); // transport ok …
    final result = Map<String, dynamic>.from(raw['result'] as Map);
    expect(result['ok'], isFalse); // … domain says "update the desktop"
    expect(result['error'], 'unsupported_protocol');
    expect(result['message'], isNotEmpty);
  });
}

Future<Map<String, dynamic>> _rawRpc(
  String baseUrl,
  String token,
  Map<String, dynamic> body,
) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(Uri.parse('$baseUrl/v1/rpc'));
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(body));
    final response = await request.close();
    final text = await utf8.decodeStream(response);
    return Map<String, dynamic>.from(jsonDecode(text) as Map);
  } finally {
    client.close(force: true);
  }
}
