// Store runtime/write-path tests (batch 05 rework).
//
// The store no longer spawns or talks to a local HTTP server. Runtime routing
// is now:
//
//   local core (engine + project library) → connected desktop (RPC) → explicit
//   failure.
//
// Tests therefore build the store over an injected [LocalCore] with a scripted
// engine (the real engine is a WASM host covered by engine_host_test.dart), and
// use a fake desktop only for the explicit `server` runtime.
//
// Regression anchors kept from the previous suite: op serialisation, undo
// queueing, run-start queue drain, orphaned-run terminal drop, recovery write
// chain, cancelAgent error swallowing, and the Build loop (agent gate + live
// commit). Added by this batch: default runtime is local, explicit `server`
// runtime never silently falls back, toasts go through ToastService, and local
// project save/open works without any engine.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ai_sdk_dart/test.dart';
// ai_sdk_provider is a transitive dependency of ai_sdk_dart (not declared in
// pubspec); the scripted mock needs its stream part types.
// ignore: depend_on_referenced_packages
import 'package:ai_sdk_provider/ai_sdk_provider.dart';
import 'package:flutter/foundation.dart' show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter_test/flutter_test.dart';
import 'package:nondesign/core/api.dart';
import 'package:nondesign/core/app_paths.dart';
import 'package:nondesign/core/capability.dart';
import 'package:nondesign/core/ddp.dart';
import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/project_service.dart';
import 'package:nondesign/core/remote_desktop_client.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/toast_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------------------------------------------------------------------------
// Scripted engine
// ---------------------------------------------------------------------------

class _FakeEngine implements LocalEngine {
  bool ready = true;
  String canonical = 'MBT_0';
  bool rejectNextApply = false;
  String rejectCode = 'mbt_gate_block:lg:no_sibling_overlap:t1';
  Completer<void>? applyGate;
  final List<String> gates = [];
  final List<String> appliedOps = [];
  final List<String> appliedBases = [];
  final List<String> rendered = [];
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
  String? get startupError => ready ? null : 'engine fixture off';

  @override
  CapabilityAvailability probeAvailability() => ready
      ? const CapabilityAvailability.available(CapabilityId.localDesignEngine)
      : const CapabilityAvailability.unavailable(CapabilityId.localDesignEngine);

  @override
  Future<Map<String, dynamic>> render(String mbt) async {
    rendered.add(mbt);
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
    final gateCompleter = applyGate;
    if (gateCompleter != null) await gateCompleter.future;
    if (rejectNextApply) {
      rejectNextApply = false;
      return {'ok': false, 'error': rejectCode};
    }
    canonical = op.startsWith('create home') ? 'MBT_HOME' : 'MBT_${appliedOps.length}';
    return _envelope(canonical);
  }

  @override
  Future<Map<String, dynamic>> session(String mbt, String name, [String? arg]) async {
    sessionNames.add(name);
    switch (name) {
      case 'session_auto_fix':
        canonical = 'MBT_FIXED';
        return _envelope(canonical);
      case 'session_critique':
        return {
          'ok': true,
          'data': {
            'results': [
              {'principle': 'contrast', 'score': 5, 'verdict': 'good'},
            ],
          },
        };
      case 'session_list_artboards':
        return {
          'ok': true,
          'data': [
            {'id': 'home', 'nodes': 1, 'width': 390, 'height': 844},
          ],
        };
      default:
        return {'ok': true, 'data': const []};
    }
  }

  @override
  Future<Map<String, dynamic>> generate(
      String mbt, String intent, String name, Map<String, dynamic> spec) async {
    canonical = '$mbt<!-- generated: $intent -->';
    return {'ok': true, 'mbt': canonical, 'artboard': name, 'score': 90.0};
  }

  @override
  Future<Map<String, dynamic>> tap(String mbt, String artboard, double x, double y) async =>
      {'ok': true, 'current': artboard};

  @override
  Future<Map<String, dynamic>> constrainIntent(String mbt, String artboard, String intent) async {
    canonical = 'MBT_CONSTRAINED';
    return {'ok': true, 'mbt': canonical};
  }

  @override
  Future<Map<String, dynamic>> event(String mbt, String artboard, String spec) async =>
      {'ok': true, 'current': artboard};

  @override
  Future<Map<String, dynamic>> history(String mbt, String command) async {
    if (command.trim().toLowerCase().startsWith('undo')) {
      canonical = 'MBT_HISTORY';
      return {'ok': true, 'mbt': canonical};
    }
    return {'ok': true};
  }

  @override
  Future<Map<String, dynamic>> exportHtml(String mbt) async => {'ok': true, 'html': '<html></html>'};

  @override
  Future<Map<String, dynamic>> tokens() async => {'ok': true, 'data': const []};

  @override
  Future<Map<String, dynamic>> versionInfo() async => {'ok': true, 'version': 'fixture'};

  @override
  Future<List<dynamic>> templates() async => [
        {'id': 'pc_app', 'name': 'PC App', 'device': 'pc'},
      ];

  @override
  Future<List<dynamic>> components() async => ['button', 'text'];

  @override
  Future<List<dynamic>> themes() async => ['dark'];

  @override
  Future<List<dynamic>> ops() async => ['place'];
}

// ---------------------------------------------------------------------------
// Scripted model for the built-in Build loop
// ---------------------------------------------------------------------------

class _ScriptedBuildModel extends MockLanguageModelV4 {
  final List<List<LanguageModelV4ContentPart>> script;
  int _i = 0;
  _ScriptedBuildModel(this.script) : super(provider: 'scripted', modelId: 'm');

  @override
  Future<LanguageModelV4StreamResult> doStream(LanguageModelV4CallOptions options) async {
    final step = _i < script.length ? script[_i++] : <LanguageModelV4ContentPart>[mockText('done')];
    var seq = 0;
    final parts = <LanguageModelV4StreamPart>[const StreamPartStreamStart(warnings: [])];
    for (final part in step) {
      if (part is LanguageModelV4ToolCallPart) {
        parts.add(StreamPartToolInputStart(id: 't$seq', toolName: part.toolName));
        parts.add(StreamPartToolInputDelta(id: 't$seq', delta: jsonEncode(part.input)));
        parts.add(StreamPartToolInputEnd(id: 't$seq'));
        parts.add(StreamPartToolCall(toolCall: part));
      }
      seq++;
    }
    parts.add(const StreamPartFinish(
      finishReason: LanguageModelV4FinishReason.stop,
      rawFinishReason: 'stop',
    ));
    return LanguageModelV4StreamResult(stream: Stream.fromIterable(parts));
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Directory _tempDir([String prefix = 'nondesign-store-test']) {
  final dir = Directory.systemTemp.createTempSync(prefix);
  addTearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });
  return dir;
}

void _seedRegistry(AppStore store) {
  store.registry = ModelRegistry.fromJson({
    'providers': {
      'testp': {
        'api': 'http://127.0.0.1:1',
        'protocol': 'openai',
        'models': {
          'm1': {'name': 'M1', 'tool_call': true, 'limit': {'context': 128000}},
        },
      },
    },
  });
  store.settings.apiKey = 'test-key';
  store.settings.providerId = 'testp';
  store.settings.modelId = 'm1';
  store.settings.baseUrl = 'http://127.0.0.1:1';
}

({AppStore store, _FakeEngine engine, ToastService toasts}) _localStore({
  Directory? projectsDir,
}) {
  SharedPreferences.setMockInitialValues({});
  final engine = _FakeEngine();
  final toasts = ToastService(autoDismiss: false);
  final store = AppStore(
    localCore: LocalCore(
      engine: engine,
      projects: ProjectService(root: () async => projectsDir ?? _tempDir()),
    ),
    toasts: toasts,
  );
  store.recoveryDir = _tempDir('nondesign-recovery').path;
  store.settingsMirrorDir = _tempDir('nondesign-settings').path;
  return (store: store, engine: engine, toasts: toasts);
}

/// HTTP JSON server answering the RPC contract with a whole-body JSON event.
///
/// Whole-body answers are a supported host shape (the client falls back to
/// parsing the body when the content type is not event-stream), which keeps
/// these tests independent of socket-level chunking.
Future<(String, Future<void> Function(), List<Map<String, dynamic>>)> _jsonDesktop(
  FutureOr<Map<String, dynamic>> Function(Map<String, dynamic> params) onAgentRun, {
  Future<void>? hold,
}) async {
  final requests = <Map<String, dynamic>>[];
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final chunks = await request.fold<List<int>>([], (a, b) => a..addAll(b));
    final body = chunks.isEmpty ? '{}' : utf8.decode(chunks);
    final decoded = (jsonDecode(body) as Map).cast<String, dynamic>();
    requests.add(decoded);
    if (hold != null) await hold;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(await onAgentRun(
      (decoded['params'] as Map?)?.cast<String, dynamic>() ?? const {},
    )));
    await request.response.close();
  });
  return (
    'http://127.0.0.1:${server.port}',
    () => server.close(force: true),
    requests,
  );
}

/// Raw-socket SSE desktop (real per-event streaming for timer tests).
///
/// The request is drained before the response goes out: answering and closing
/// while the client is still writing its POST body makes the kernel reply with
/// RST and the client dies with EPIPE ("Broken pipe") before reading any event.
Future<(String, Future<void> Function())> _sseDesktop(
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
  // The widget binding installs an HttpOverrides that answers every request
  // with 400 (test anti-network guard). These tests talk to local fake
  // desktops on loopback, so restore the real transport.
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  group('op pipeline (local engine)', () {
    test('applyOp commits the envelope, pushes history and marks dirty', () async {
      final h = _localStore();
      h.store.mbt = 'MBT_V1';
      h.store.history = ['MBT_V1'];
      h.store.historyIndex = 0;

      final ok = await h.store.applyOp('move home n1 10 10');

      expect(ok, isTrue);
      expect(h.store.mbt, 'MBT_1');
      expect(h.store.history, ['MBT_V1', 'MBT_1']);
      expect(h.store.historyIndex, 1);
      expect(h.store.dirty, isTrue);
      expect(h.store.render.entry, 'home');
      expect(h.engine.gates, ['human'], reason: 'canvas ops use the human door');
    });

    test('a rejected op leaves mbt/history untouched and warns through ToastService', () async {
      final h = _localStore();
      h.engine.rejectNextApply = true;
      h.store.mbt = 'MBT_V1';
      h.store.history = ['MBT_V1'];
      h.store.historyIndex = 0;

      final ok = await h.store.applyOp('bogus-op');

      expect(ok, isFalse);
      expect(h.store.mbt, 'MBT_V1');
      expect(h.store.history, ['MBT_V1']);
      expect(h.toasts.history.first.title, '这次改动未通过设计校验');
    });

    test('applyOp is rejected while an agent run is in flight', () async {
      final h = _localStore();
      h.store.agentBusy = true;

      final ok = await h.store.applyOp('move home n1 0 0', silent: true);

      expect(ok, isFalse);
      expect(h.engine.appliedOps, isEmpty);
      expect(h.toasts.history.first.title, contains('NaN 正在工作'));
    });

    test('two in-flight applyOps are serialized — the second reads the refreshed mbt', () async {
      final h = _localStore();
      h.engine.applyGate = Completer<void>();
      h.store.mbt = 'MBT_V1';
      h.store.history = ['MBT_V1'];
      h.store.historyIndex = 0;

      final op1 = h.store.applyOp('op one');
      final op2 = h.store.applyOp('op two');
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(h.engine.appliedOps, ['op one'], reason: '第二条在飞窗口内不得发出');

      h.engine.applyGate!.complete();
      h.engine.applyGate = null;
      expect(await op1, isTrue);
      expect(await op2, isTrue);
      expect(h.engine.appliedBases, ['MBT_V1', 'MBT_1'],
          reason: '第二条必须以刷新后的 mbt 为基底');
      expect(h.store.mbt, 'MBT_2');
    });

    test('undo/redo round-trips through history', () async {
      final h = _localStore();
      h.store.mbt = 'MBT_V2';
      h.store.history = ['MBT_V1', 'MBT_V2'];
      h.store.historyIndex = 1;

      h.store.undo();
      await h.store.opQueueIdle;
      expect(h.store.mbt, 'MBT_V1');
      expect(h.store.historyIndex, 0);

      h.store.redo();
      await h.store.opQueueIdle;
      expect(h.store.mbt, 'MBT_V2');
      expect(h.store.historyIndex, 1);
      expect(h.engine.rendered, ['MBT_V1', 'MBT_V2']);
    });

    test('undo at the start of history is a no-op', () async {
      final h = _localStore();
      h.store.mbt = 'MBT_V1';
      h.store.history = ['MBT_V1'];
      h.store.historyIndex = 0;

      h.store.undo();
      await h.store.opQueueIdle;

      expect(h.store.mbt, 'MBT_V1');
      expect(h.engine.rendered, isEmpty);
    });

    test('undo issued while an op is in flight lands on the committed history', () async {
      final h = _localStore();
      h.engine.applyGate = Completer<void>();
      h.store.mbt = 'MBT_V1';
      h.store.history = ['MBT_V1'];
      h.store.historyIndex = 0;

      final op = h.store.applyOp('op');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      h.store.undo();
      h.engine.applyGate!.complete();
      h.engine.applyGate = null;
      await op;
      await h.store.opQueueIdle;

      expect(h.store.mbt, 'MBT_V1');
      expect(h.store.historyIndex, 0);
    });

    test('constrainLayout queues behind an in-flight op and uses the refreshed mbt', () async {
      final h = _localStore();
      h.engine.applyGate = Completer<void>();
      h.store.mbt = 'MBT_V1';
      h.store.history = ['MBT_V1'];
      h.store.historyIndex = 0;
      h.store.hasProject = true;
      h.store.activeBoard = 'home';

      final op = h.store.applyOp('op');
      final constrained = h.store.constrainLayout('居中');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(h.engine.rendered, isEmpty, reason: '在飞 op 提交前不得发 constrain');

      h.engine.applyGate!.complete();
      h.engine.applyGate = null;
      expect(await op, isTrue);
      expect(await constrained, isTrue);
      expect(h.store.mbt, 'MBT_CONSTRAINED');
    });

    test('engineHistory undo re-renders and commits its canonical', () async {
      final h = _localStore();
      h.store.mbt = 'MBT_V1';
      h.store.history = ['MBT_V1'];
      h.store.historyIndex = 0;

      final res = await h.store.engineHistory('undo');

      expect(res['ok'], isTrue);
      expect(h.store.mbt, 'MBT_HISTORY');
    });

    test('newProject/openProjectPath are gated while an agent run is in flight', () async {
      final h = _localStore();
      h.store.agentBusy = true;
      h.store.runId = 42;
      h.store.hasProject = true;
      h.store.projectName = 'old';
      h.store.mbt = 'OLD_MBT';

      expect(await h.store.newProject(name: 'x', empty: true), isFalse);
      expect(await h.store.openProjectPath('/tmp/does-not-exist.ddp'), OpenResult.failed);

      expect(h.store.agentBusy, isTrue);
      expect(h.store.runId, 42);
      expect(h.store.projectName, 'old');
      expect(h.store.mbt, 'OLD_MBT');
    });

    test('local project save/open works without any engine', () async {
      final dir = _tempDir();
      final h = _localStore(projectsDir: dir);
      h.store.hasProject = true;
      h.store.projectName = 'demo';
      h.store.mbt = 'MBT_BODY';
      h.store.docs.prd = '需求正文';
      final path = '${dir.path}/demo.ddp';

      expect(await h.store.saveProject(path: path), isTrue);
      expect(File(path).existsSync(), isTrue);
      expect(h.store.dirty, isFalse);

      h.store.hasProject = false;
      h.store.mbt = '';
      h.store.docs.prd = '';
      h.engine.ready = false; // engine down: opening must still restore the file

      final opened = await h.store.openProjectPath(path);

      expect(opened, OpenResult.opened);
      expect(h.store.hasProject, isTrue);
      expect(h.store.mbt, contains('MBT_BODY'));
      expect(h.store.docs.prd, '需求正文');
      expect(h.store.projectName, 'demo');
    });

    test('templates/components come from the local engine', () async {
      final h = _localStore();
      expect(await h.store.api!.templates(), hasLength(1));
      expect(await h.store.api!.components(), contains('button'));
    });
  });

  group('runtime routing', () {
    test('default runtime is the local built-in loop (no desktop needed)', () async {
      final h = _localStore();
      _seedRegistry(h.store);
      h.store.settings.agentRuntime = agentRuntimeDart; // current default until batch 11
      h.store.settings.apiKey = '';

      final ok = await h.store.runPlan('做个方案');

      expect(ok, isFalse);
      expect(h.toasts.history.first.title, contains('先配置模型'),
          reason: '进了本地循环的前置门，而不是“没有连接桌面”的服务器门');
      expect(h.store.agentBusy, isFalse);
    });

    test('explicit server runtime without a desktop fails visibly, never falls back', () async {
      final h = _localStore();
      _seedRegistry(h.store);
      h.store.settings.agentRuntime = agentRuntimeServer;

      final ok = await h.store.runPlan('做个方案');

      expect(ok, isFalse);
      expect(h.toasts.history.first.title, '还没有连接桌面，无法使用这个运行时');
      expect(h.engine.appliedOps, isEmpty);
      expect(h.engine.rendered, isEmpty);
      expect(h.store.agentBusy, isFalse);
    });

    test('a connected desktop runs the server runtime and streams its events', () async {
      final (base, close, requests) = await _jsonDesktop((params) async {
        return {
          'ok': true,
          'result': {
            'type': 'done',
            'text': 'ok',
            'stopReason': 'done',
            'mbt_b64': base64Encode(utf8.encode('REMOTE_MBT')),
          },
        };
      });
      addTearDown(close);
      final h = _localStore();
      _seedRegistry(h.store);
      h.store.settings.agentRuntime = agentRuntimeServer;
      h.store.api = NoNDesignApi.runtime(
        local: LocalCore(engine: h.engine, projects: ProjectService(root: () async => _tempDir())),
        remote: RemoteDesktopClient(baseUrl: base),
      );

      final ok = await h.store.runPlan('生成');

      expect(ok, isTrue);
      expect(requests.single['method'], 'agent.run');
      expect(((requests.single['params'] as Map)['mode']), 'plan');
      expect(h.store.mbt, 'REMOTE_MBT', reason: 'done canonical is re-rendered and committed');
      expect(h.store.agentBusy, isFalse);
      expect(h.store.timeline.any((t) => t.kind == 'finish' && t.ok && t.title == 'NaN 完成'),
          isTrue);
    });

    test('run start drains the op queue so the run snapshot is fresh', () async {
      final (base, close, requests) = await _jsonDesktop((params) async {
        return {
          'ok': true,
          'result': {'type': 'done', 'text': 'ok', 'stopReason': 'done'},
        };
      });
      addTearDown(close);
      final h = _localStore();
      _seedRegistry(h.store);
      h.store.settings.agentRuntime = agentRuntimeServer;
      h.store.api = NoNDesignApi.runtime(
        local: LocalCore(engine: h.engine, projects: ProjectService(root: () async => _tempDir())),
        remote: RemoteDesktopClient(baseUrl: base),
      );
      h.engine.applyGate = Completer<void>();
      h.store.mbt = 'MBT_V1';
      h.store.history = ['MBT_V1'];
      h.store.historyIndex = 0;

      final op = h.store.applyOp('op');
      final run = h.store.runPlan('生成');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(requests, isEmpty, reason: 'run 起点必须等 op 提交');

      h.engine.applyGate!.complete();
      h.engine.applyGate = null;
      await op;
      expect(await run, isTrue);
      expect((requests.single['params'] as Map)['mbt'], 'MBT_1');
    });

    test('orphaned run events are dropped — terminal canonical never commits', () async {
      final release = Completer<void>();
      final (base, close, _) = await _jsonDesktop(
        (params) async => {
          'ok': true,
          'result': {
            'type': 'done',
            'text': 'ok',
            'stopReason': 'done',
            'mbt_b64': base64Encode(utf8.encode('ORPHAN_CANONICAL')),
          },
        },
        hold: release.future,
      );
      addTearDown(close);
      final h = _localStore();
      _seedRegistry(h.store);
      h.store.settings.agentRuntime = agentRuntimeServer;
      h.store.api = NoNDesignApi.runtime(
        local: LocalCore(engine: h.engine, projects: ProjectService(root: () async => _tempDir())),
        remote: RemoteDesktopClient(baseUrl: base),
      );
      h.store.hasProject = true;
      h.store.mbt = 'NEW_PROJECT_MBT';

      final run = h.store.runPlan('做点什么');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      h.store.runId = 999; // ownership token replaced → run abandoned
      release.complete();

      expect(await run, isFalse);
      expect(h.store.mbt, 'NEW_PROJECT_MBT');
      expect(h.store.agentBusy, isFalse);
    });

    test('a stalled agent stream releases agentBusy via the idle terminal', () async {
      RemoteDesktopClient.sseIdleTimeout = const Duration(milliseconds: 250);
      addTearDown(() => RemoteDesktopClient.sseIdleTimeout = const Duration(seconds: 660));
      final (base, close) = await _sseDesktop((send) async {
        await send({'type': 'note', 'label': 'NaN 开始'});
        await Completer<void>().future;
      });
      addTearDown(close);
      final h = _localStore();
      _seedRegistry(h.store);
      h.store.settings.agentRuntime = agentRuntimeServer;
      h.store.api = NoNDesignApi.runtime(
        local: LocalCore(engine: h.engine, projects: ProjectService(root: () async => _tempDir())),
        remote: RemoteDesktopClient(baseUrl: base),
      );

      final ok = await h.store.runPlan('做个方案');

      expect(ok, isFalse);
      expect(h.store.agentBusy, isFalse);
      expect(h.store.agentError, contains('sse_idle_timeout'));
    });

    test('pending doc_delta flush timer does not notify after dispose', () async {
      final hold = Completer<void>();
      final (base, close) = await _sseDesktop((send) async {
        await send({'type': 'doc_delta', 'text': '部分文档正文'});
        await hold.future;
      });
      addTearDown(close);
      final h = _localStore();
      _seedRegistry(h.store);
      h.store.settings.agentRuntime = agentRuntimeServer;
      h.store.api = NoNDesignApi.runtime(
        local: LocalCore(engine: h.engine, projects: ProjectService(root: () async => _tempDir())),
        remote: RemoteDesktopClient(baseUrl: base),
      );

      final errors = <Object>[];
      await runZonedGuarded(() async {
        final run = h.store.runPlan('写文档');
        await Future<void>.delayed(const Duration(milliseconds: 60));
        h.store.dispose();
        await Future<void>.delayed(const Duration(milliseconds: 250));
        unawaited(run);
      }, (e, st) => errors.add(e));

      expect(errors, isEmpty, reason: 'dispose 后不得再触发 notifyListeners');
    });

    test('cancelAgent swallows network failures from the stop request', () async {
      SharedPreferences.setMockInitialValues({});
      final store = AppStore(toasts: ToastService(autoDismiss: false));
      store.recoveryDir = _tempDir().path;
      store.settingsMirrorDir = _tempDir().path;
      store.api = NoNDesignApi.runtime(
        remote: RemoteDesktopClient(baseUrl: 'http://127.0.0.1:1'),
      );
      store.agentBusy = true;
      store.runId = 7;

      await store.cancelAgent(); // must not throw

      expect(store.agentBusy, isTrue);
      expect(store.agentPhase, 'cancelling');
    });
  });

  group('recovery and settings', () {
    test('concurrent persistRecovery writes serialize — intact JSON, last write wins', () async {
      SharedPreferences.setMockInitialValues({});
      final dir = _tempDir();
      final store = AppStore();
      store.recoveryDir = dir.path;
      store.settingsMirrorDir = _tempDir().path;
      store.hasProject = true;
      store.projectName = 'alpha';
      store.mbt = 'MBT_A';

      unawaited(store.debugPersistRecovery(force: true));
      store.projectName = 'beta';
      store.mbt = 'MBT_B';
      await store.debugPersistRecovery(force: true);
      await store.recoveryWritesIdle;

      final raw = jsonDecode(await File('${dir.path}/recovery.json').readAsString()) as Map;
      expect(raw['name'], 'beta');
      expect(raw['mbt'], 'MBT_B');
    });

    test('saveSettings persists the desktop token without a MissingPluginException', () async {
      SharedPreferences.setMockInitialValues({});
      final mirror = _tempDir();
      final store = AppStore();
      store.settingsMirrorDir = mirror.path;
      store.settings.serverUrl = 'http://192.168.1.5:9000';
      store.serverToken = 'tok-1';

      await store.saveSettings();

      final prefs = await SharedPreferences.getInstance();
      final raw = jsonDecode(prefs.getString('nondesign.settings')!) as Map;
      expect(raw['serverUrl'], 'http://192.168.1.5:9000');
      expect(raw['serverToken'], 'tok-1');
      expect(prefs.getString('nondesign.serverToken'), 'tok-1');
      expect(File('${mirror.path}/settings.json').existsSync(), isTrue);
    });

    test('desktop host: settings switch starts a real listener and exposes address/token', () async {
      final h = _localStore();
      addTearDown(h.store.stopDesktopHost);

      final ok = await h.store.startDesktopHost();

      expect(ok, true);
      expect(h.store.desktopHostRunning, true);
      final status = h.store.desktopHostStatus!;
      expect(status.baseUrl, startsWith('http://127.0.0.1:'));
      expect(status.token, isNotEmpty);
      // 默认只监听 loopback；手机连接需要显式打开局域网开关。
      expect(status.lanEnabled, isFalse);

      await h.store.setDesktopHostAllowLan(true);
      expect(h.store.desktopHostStatus!.lanEnabled, isTrue);

      await h.store.stopDesktopHost();
      expect(h.store.desktopHostRunning, isFalse);
    });
  });

  group('Build loop (agent gate × store queue)', () {
    test('runBuild commits every design_op through the agent gate, live', () async {
      final h = _localStore();
      _seedRegistry(h.store);
      h.store.settings.agentRuntime = agentRuntimeDart;
      h.store.mbt = 'MBT_V1';
      h.store.history = ['MBT_V1'];
      h.store.historyIndex = 0;
      h.store.debugAgentModelOverride = _ScriptedBuildModel([
        [mockToolCall(toolName: 'design_op', input: {'op': 'create home 390 844'})],
        [mockToolCall(toolName: 'design_op', input: {'op': 'place home text t1 10 10 100 30'})],
        [mockToolCall(toolName: 'finish', input: {'summary': '建好首页'})],
      ]);

      final ok = await h.store.runBuild('搭一个首页');

      expect(ok, isTrue);
      expect(h.engine.gates, ['agent', 'agent'], reason: '全部 op 走 AgentGate');
      expect(h.engine.appliedOps, ['create home 390 844', 'place home text t1 10 10 100 30']);
      expect(h.engine.appliedBases, ['MBT_V1', 'MBT_HOME'],
          reason: 'canonical 线程化：第二条以第一条提交后的值为基底');
      expect(h.store.mbt, 'MBT_2');
      expect(h.store.history, ['MBT_V1', 'MBT_HOME', 'MBT_2']);
      expect(h.store.agentBusy, isFalse);
      expect(h.store.runId, isNull);
      expect(h.store.timeline.any((t) => t.kind == 'tool' && t.tool == 'design_op'), isTrue);
      expect(h.store.timeline.any((t) => t.kind == 'finish' && t.ok && t.title == 'NaN 完成'),
          isTrue);
    });

    test('a human op queued before a build is committed first', () async {
      final h = _localStore();
      _seedRegistry(h.store);
      h.store.settings.agentRuntime = agentRuntimeDart;
      h.store.mbt = 'MBT_V1';
      h.store.history = ['MBT_V1'];
      h.store.historyIndex = 0;
      h.engine.applyGate = Completer<void>();
      h.store.debugAgentModelOverride = _ScriptedBuildModel([
        [mockToolCall(toolName: 'design_op', input: {'op': 'create home 390 844'})],
        [mockToolCall(toolName: 'finish', input: {'summary': 'ok'})],
      ]);

      final human = h.store.applyOp('move home n1 1 2'); // human door, gated
      final run = h.store.runBuild('搭一个首页');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(h.engine.appliedOps, ['move home n1 1 2'],
          reason: 'run 起点等队列排空：此刻只有人类 op 在飞');
      h.engine.applyGate!.complete();
      h.engine.applyGate = null;
      await human;
      expect(await run, isTrue);

      expect(h.engine.gates, ['human', 'agent']);
      expect(h.engine.appliedBases, ['MBT_V1', 'MBT_1']);
    });
  });

  // ---------------------------------------------------------------------------
  // 项目切换与崩溃恢复（不静默清空 / 不降级口令 / 不丢批注）
  // ---------------------------------------------------------------------------
  group('project switch guard', () {
    test('unsaved work is never cleared without confirmation', () async {
      final h = _localStore();
      h.store.hasProject = true;
      h.store.projectName = 'alpha';
      h.store.mbt = 'MBT_UNSAVED';
      h.store.docs.prd = '需求正文';
      h.store.dirty = true;

      expect(h.store.hasUnsavedChanges, isTrue);
      // 没有确认出口时保守拒绝；生产由 main.dart 注入三选一对话框。
      expect(await h.store.newProject(name: 'beta', empty: true), isFalse);
      expect(h.store.projectName, 'alpha');
      expect(h.store.mbt, 'MBT_UNSAVED');
      expect(h.store.docs.prd, '需求正文');
    });

    test('discard confirmation switches the project; cancel aborts the open', () async {
      final h = _localStore();
      h.store.hasProject = true;
      h.store.projectName = 'alpha';
      h.store.mbt = 'MBT_UNSAVED';
      h.store.dirty = true;

      h.store.confirmUnsavedChanges = (_) async => UnsavedChoice.cancel;
      expect(await h.store.openProjectPath('/tmp/never-touched.ddp'), OpenResult.cancelled);
      expect(h.store.projectName, 'alpha');
      expect(h.store.mbt, 'MBT_UNSAVED');

      var asked = 0;
      h.store.confirmUnsavedChanges = (action) async {
        asked += 1;
        expect(action, '新建项目');
        return UnsavedChoice.discard;
      };
      expect(await h.store.newProject(name: 'beta', empty: true), isTrue);
      expect(asked, 1);
      expect(h.store.projectName, 'beta');
      expect(h.store.mbt, '');
    });

    test('受保护项目：追问口令的那次重试不再重复确认切换', () async {
      final dir = _tempDir();
      final writer = _localStore(projectsDir: dir);
      final path = '${dir.path}/locked.ddp';
      writer.store.hasProject = true;
      writer.store.projectName = 'locked';
      writer.store.mbt = 'MBT_LOCKED';
      writer.store.password = 'pw';
      expect(await writer.store.saveProject(path: path), isTrue);

      final h = _localStore(projectsDir: dir);
      h.store.hasProject = true;
      h.store.projectName = 'alpha';
      h.store.mbt = 'MBT_ALPHA';
      h.store.dirty = true;
      var asked = 0;
      h.store.confirmUnsavedChanges = (_) async {
        asked += 1;
        return UnsavedChoice.discard;
      };

      expect(await h.store.openProjectPath(path), OpenResult.needPassword);
      expect(asked, 1);
      expect(await h.store.openProjectPath(path, password: 'pw'), OpenResult.opened);
      expect(asked, 1, reason: '同一次切换的口令重试不重复弹确认框');
      expect(h.store.projectName, 'locked');
    });

    test('save confirmation writes the current project before switching', () async {
      final dir = _tempDir();
      final h = _localStore(projectsDir: dir);
      final path = '${dir.path}/alpha.ddp';
      h.store.hasProject = true;
      h.store.projectName = 'alpha';
      h.store.projectPath = path;
      h.store.mbt = 'MBT_ALPHA';
      h.store.dirty = true;
      h.store.confirmUnsavedChanges = (_) async => UnsavedChoice.save;

      expect(await h.store.newProject(name: 'beta', empty: true), isTrue);

      expect(File(path).existsSync(), isTrue, reason: '切换前把旧项目落盘');
      expect(h.store.projectName, 'beta');
      final opened = await h.store.projects.open(path);
      expect(opened.mbt, contains('MBT_ALPHA'));
    });

    test('左轨「规范 / 文档」同步文档标签', () {
      final h = _localStore();
      h.store.setPanel('spec');
      expect(h.store.view, 'docs');
      expect(h.store.docsTab, 'spec');
      h.store.setPanel('docs');
      expect(h.store.view, 'docs');
      expect(h.store.docsTab, 'prd');
    });
  });

  group('recovery data integrity', () {
    test('口令保护的快照不落明文，恢复后再保存仍是受保护容器', () async {
      final dir = _tempDir();
      final recDir = _tempDir('nondesign-recovery');
      final first = _localStore(projectsDir: dir);
      final path = '${dir.path}/locked.ddp';
      first.store.recoveryDir = recDir.path;
      first.store.hasProject = true;
      first.store.projectName = 'locked';
      first.store.projectPath = path;
      first.store.mbt = 'MBT_SECRET_BODY';
      first.store.docs.prd = '秘密需求';
      first.store.password = 'pw-123';

      expect(await first.store.saveProject(path: path), isTrue);
      first.store.dirty = true; // 模拟编辑后崩溃
      await first.store.debugPersistRecovery(force: true);
      await first.store.recoveryWritesIdle;

      final raw = await File('${recDir.path}/recovery.json').readAsString();
      expect(raw.contains('MBT_SECRET_BODY'), isFalse, reason: '受保护正文不得明文落盘');
      expect(raw.contains('秘密需求'), isFalse, reason: '受保护正文不得明文落盘');
      expect((jsonDecode(raw) as Map)['locked'], isTrue);

      // 冷启动：快照是密文，恢复时必须重新问口令。
      final cold = _localStore(projectsDir: dir);
      cold.store.recoveryDir = recDir.path;
      var asked = 0;
      cold.store.passwordPrompt = (askedPath) async {
        asked += 1;
        expect(askedPath, path);
        return 'pw-123';
      };
      await cold.store.debugLoadRecovery();
      expect(cold.store.recovery, isNotNull);
      await cold.store.restoreRecovery();
      expect(asked, 1);
      expect(cold.store.password, 'pw-123');
      expect(cold.store.mbt, contains('MBT_SECRET_BODY'));

      // 再保存：容器必须还是加密的 DDP1，不能降级成无加密 DDP2。
      expect(await cold.store.saveProject(), isTrue);
      final head = (await File(path).readAsBytes()).sublist(0, 4);
      expect(head, DdpCodec.magicLocked);
    });

    test('磁盘上已是受保护容器时，缺口令的保存被拒绝', () async {
      final dir = _tempDir();
      final writer = _localStore(projectsDir: dir);
      final path = '${dir.path}/locked.ddp';
      writer.store.hasProject = true;
      writer.store.projectName = 'locked';
      writer.store.mbt = 'MBT_KEEP';
      writer.store.password = 'pw';
      expect(await writer.store.saveProject(path: path), isTrue);
      final before = await File(path).readAsBytes();

      // 新会话只知道路径（旧版明文快照恢复后的形态）：没有口令不能写。
      final cold = _localStore(projectsDir: dir);
      cold.store.hasProject = true;
      cold.store.projectName = 'locked';
      cold.store.projectPath = path;
      cold.store.mbt = 'MBT_REPLACED';
      cold.store.dirty = true;

      expect(await cold.store.saveProject(), isFalse);
      expect(await File(path).readAsBytes(), before, reason: '拒绝写盘时文件不动');
      expect(cold.toasts.history.any((t) => t.title.contains('口令')), isTrue);
    });

    test('崩溃恢复保留演示批注墨迹', () async {
      final dir = _tempDir();
      final recDir = _tempDir('nondesign-recovery');
      final first = _localStore(projectsDir: dir);
      first.store.recoveryDir = recDir.path;
      first.store.hasProject = true;
      first.store.projectName = 'inked';
      first.store.mbt = 'MBT_BODY';
      first.store.restoreInks('MBT_BODY\n\n<!-- nondesign:ink {"home":[[[0.1,0.2],[0.3,0.4]]]} -->');
      expect(first.store.demoInks, isNotEmpty);
      first.store.dirty = true;
      await first.store.debugPersistRecovery(force: true);
      await first.store.recoveryWritesIdle;

      final cold = _localStore(projectsDir: dir);
      cold.store.recoveryDir = recDir.path;
      await cold.store.debugLoadRecovery();
      await cold.store.restoreRecovery();

      expect(cold.store.demoInks['home'], isNotEmpty, reason: '恢复后墨迹要回填');
      expect(await cold.store.saveProject(path: '${dir.path}/inked.ddp'), isTrue);
      final opened = await cold.store.projects.open('${dir.path}/inked.ddp');
      expect(opened.mbt, contains('nondesign:ink'),
          reason: '保存不得把原批注整块删掉');
    });

    test('损坏的快照保留 .bad 副本并给一次可见提示', () async {
      final recDir = _tempDir('nondesign-recovery');
      await File('${recDir.path}/recovery.json').writeAsString('{"mbt": "half');
      final h = _localStore();
      h.store.recoveryDir = recDir.path;

      await h.store.debugLoadRecovery();

      expect(h.store.recovery, isNull);
      final bad = Directory(recDir.path)
          .listSync()
          .whereType<File>()
          .where((f) => f.path.contains('.bad-'))
          .toList();
      expect(bad, isNotEmpty, reason: '撕裂文件改名保留，不静默丢弃');
      expect(h.toasts.history.any((t) => t.title.contains('损坏')), isTrue);
    });

    test('默认恢复目录走 AppPaths（无 HOME 也有回退）', () {
      expect(AppPaths.stateRoot(), isNotEmpty);
      expect(AppStore().recoveryDir, AppPaths.stateRoot());
    });

    test('ask 卡运行中点选：入队不丢，本轮收尾自动续跑（一轮收一个）', () async {
      final h = _localStore();
      h.store.settings.apiKey = ''; // 续跑的一轮会在前置门快速失败
      h.store
        ..ready = true
        ..hasProject = true;
      h.store.agentBusy = true;

      // 运行中点两个选项：都不立刻起 run，也不进气泡。
      await h.store.handleChatAction('订阅与用量运营', {'question': '业务线'});
      await h.store.handleChatAction('销售/CRM 漏斗', {'question': '业务线'});
      expect(
        h.store.chatMessages.where((m) => m.kind == chatKindUser),
        isEmpty,
        reason: '忙时选择先排队，不写气泡',
      );

      // 本轮收尾（finally 同路径）：先入队的先续跑。
      h.store.agentBusy = false;
      h.store.continueQueuedChatAction();
      final first = h.store.chatMessages.where((m) => m.kind == chatKindUser).toList();
      expect(first, hasLength(1));
      expect(first.single.text, '选择：订阅与用量运营');

      // 续跑的那轮结束后再收下一个（顺序 FIFO）。
      for (var i = 0; i < 50 && h.store.agentBusy; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      h.store.agentBusy = false;
      h.store.continueQueuedChatAction();
      final second = h.store.chatMessages.where((m) => m.kind == chatKindUser).toList();
      expect(second, hasLength(2));
      expect(second.last.text, '选择：销售/CRM 漏斗');
      for (var i = 0; i < 50 && h.store.chatActive; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });

    test('A2UI 选择动作只把人话写进用户气泡', () async {
      final h = _localStore();
      h.store.settings.apiKey = ''; // 本轮 run 会在前置门快速失败
      await h.store.handleChatAction('底部标签栏', {'question': '导航放哪里？'});

      final user = h.store.chatMessages.where((m) => m.kind == chatKindUser).toList();
      expect(user, hasLength(1));
      expect(user.single.text, '选择：底部标签栏');
      expect(user.single.text.contains('{'), isFalse, reason: '结构化上下文不进气泡');
      expect(user.single.text.contains('交互卡'), isFalse, reason: '不暴露内部标签');
    });

    test('外部智能体时间线用显示名，不拼内部目录 id', () async {
      // 测试宿主默认 targetPlatform 是 android（runAcp 会按移动端拒绝），
      // 这里显式标成桌面，走真实的时间线构造路径。
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final h = _localStore();
      h.store.settings.acpAgentId = 'claude-code';
      h.store.settings.acpAgentName = 'Claude Code';

      // 本地运行时没有外接会话面：失败是显性的，但轨迹文案必须已经用显示名。
      expect(await h.store.runAcp('做个首页'), isFalse);

      final phase = h.store.timeline.firstWhere((t) => t.kind == 'phase');
      expect(phase.text, '外部智能体 · Claude Code');
      expect(phase.text.contains('claude-code'), isFalse);
      final finish = h.store.timeline.where((t) => t.kind == 'finish').toList().last;
      expect(finish.text.contains('claude-code'), isFalse);
    });

    test('工作区切换映射：工具 → 工作台，视图 → 模式', () {
      expect(AppStore.workspaceViewForTool('three_create'), 'plugin:three');
      expect(AppStore.workspaceViewForTool('three_pass'), 'plugin:three');
      expect(AppStore.workspaceViewForTool('hotapp_generate'), 'plugin:hotapp');
      expect(AppStore.workspaceViewForTool('video_review'), 'plugin:video');
      expect(AppStore.workspaceViewForTool('design_op'), 'design');
      expect(AppStore.workspaceViewForTool('generate_page'), 'design');
      expect(AppStore.workspaceViewForTool('ask_user'), isNull);

      expect(AppStore.workspaceModeForView('plugin:three'), workspaceModeThree);
      expect(AppStore.workspaceModeForView('plugin:video'), workspaceModeVideo);
      expect(AppStore.workspaceModeForView('plugin:hotapp'), workspaceModeHotapp);
      expect(AppStore.workspaceModeForView('design'), workspaceModeDesign);
      expect(AppStore.workspaceModeForView('docs'), workspaceModeDesign);
    });

    test('工作区模式归一：未知值回落自动，持久化进设置', () async {
      final h = _localStore();
      expect(h.store.chatWorkspaceMode, workspaceModeAuto);

      await h.store.setChatWorkspaceMode('video');
      expect(h.store.chatWorkspaceMode, workspaceModeVideo);
      expect(h.store.settings.chatWorkspaceMode, workspaceModeVideo);

      await h.store.setChatWorkspaceMode('nope');
      expect(h.store.chatWorkspaceMode, workspaceModeAuto);

      // 旧存档没有这个键 → 自动。
      expect(AppSettings.fromJson(const <String, dynamic>{}).chatWorkspaceMode,
          workspaceModeAuto);
    });

    test('工作区彼此独立：agent 的插件工具不再把主面拽去别的工区', () {
      // 2026-11-19 用户裁决：3D / 视频 / 热应用是独立工作区，不互相挂靠、
      // 也不主动关联设计项目。NaN 在某个面调用它们的工具时，只更新数据，
      // 不替用户切主面；设计工具仍可把主面带回设计画布（用户看着画布时
      // 生成/改稿要能看到结果）。
      final h = _localStore();
      h.store.hasProject = true;
      h.store.setView('design');

      h.store.followAgentWorkspace('three_create');
      expect(h.store.view, 'design', reason: '3D 工具不得把设计面拽走');

      h.store.followAgentWorkspace('hotapp_generate');
      expect(h.store.view, 'design');

      h.store.followAgentWorkspace('video_review');
      expect(h.store.view, 'design');

      // 设计工具仍回设计画布（从文档/源码面回设计）。
      h.store.setView('docs');
      h.store.followAgentWorkspace('design_op');
      expect(h.store.view, 'design');

      // 演示是显式的「只看不跑」：任何工具都不拽走。
      h.store.setView('play');
      h.store.followAgentWorkspace('video_review');
      expect(h.store.view, 'play');
    });
  });
}
