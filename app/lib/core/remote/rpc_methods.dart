/// Method table of the optional "连接桌面" host (batch 10).
///
/// Every method delegates to the client-side services this app already has —
/// the in-process design engine ([LocalCore.engine]), the `.ddp` library
/// ([LocalCore.projects]), the 3D / hot-app / video / app-package workspaces and
/// the built-in agent loop. There is no Python service behind any of them and
/// no second protocol: the method names are exactly what
/// `core/remote_desktop_client.dart` and `core/api.dart` send.
///
/// Design rules:
///
///  * **never fake a result**: a service that is missing or broken answers
///    `{ok:false, error, detail}` — the client shows a sentence from its copy
///    layer and keeps the raw detail behind "技术详情";
///  * **canvas writes stay gated**: `engine.apply` forwards `gate` verbatim
///    (`human` from the canvas, `agent` from the agent loop) and rejects
///    anything else. The host never edits a document itself;
///  * **paths are constrained**: project save/open only accept `*.ddp`, and
///    workspace names go through the services' own ASCII validators, so a
///    pairing token cannot be turned into an arbitrary file read/write.
///
/// The table is pure Dart plus `dart:io` (directories, ACP processes). It does
/// not touch Flutter, so it can be unit-tested on the Dart VM.
library;

// Public named parameters assigned to private fields are intentional: a
// private named parameter cannot be passed from outside this library, and the
// host API is consumed by the shell/settings batches.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ai_sdk_dart/ai_sdk_dart.dart' show CancellationToken;

import 'package:nondesign/core/engine/engine_types.dart';

import '../acp_client.dart';
import '../api.dart';
import '../app_paths.dart';
import '../dart_agent.dart';
import '../figma_export.dart';
import '../hotapp_service.dart';
import '../models.dart';
import '../nonapp_library.dart';
import '../nonapp_package.dart';
import '../three_service.dart';
import '../video_samples.dart';
import '../video_service.dart';
import 'rpc_protocol.dart';

// ---------------------------------------------------------------------------
// Typed request for the built-in agent
// ---------------------------------------------------------------------------

/// One `agent.run` request, already validated.
class RpcAgentRun {
  const RpcAgentRun({
    required this.runId,
    required this.mode,
    required this.instruction,
    this.mbt = '',
    this.docs = const {},
    this.model = '',
    this.baseUrl = '',
    this.apiKey = '',
    this.thinkingLevel = 'auto',
    this.maxSteps = 300,
    this.contextWindow,
    this.workspaceHint = '',
  });

  final int runId;
  final String mode;
  final String instruction;
  final String mbt;
  final Map<String, dynamic> docs;
  final String model;
  final String baseUrl;
  final String apiKey;
  final String thinkingLevel;
  final int maxSteps;
  final int? contextWindow;

  /// workspace 模式的目标工作台（`three` / `video` / `hotapp` / `auto`）。
  final String workspaceHint;

  bool get isConfigured => model.isNotEmpty && apiKey.isNotEmpty && baseUrl.isNotEmpty;

  DartAgentRequest toRequest() => DartAgentRequest(
    mode: mode,
    instruction: instruction,
    mbt: mbt,
    docs: docs,
    model: model,
    baseUrl: baseUrl,
    apiKey: apiKey,
    thinkingLevel: thinkingLevel,
    maxSteps: maxSteps,
    contextWindow: contextWindow,
    workspaceHint: workspaceHint,
  );
}

/// Streams built-in agent events (same shapes the app's own loop emits).
///
/// An abstract class rather than a function typedef so hosts and tests can
/// implement it and the table can call [run] on the instance.
abstract class RpcAgentRunner {
  Stream<Map<String, dynamic>> run(RpcAgentRun run, CancellationToken abort);
}

/// Production runner: the batch-09 Dart loop over the batch-02 local engine.
///
/// The loop itself owns gates, prompts and tool routing; this class only
/// adapts callback events into a stream and wires the workspace tools so a
/// connected phone can drive 3D / hot apps / video through the desktop.
class LocalCoreAgentRunner extends RpcAgentRunner {
  LocalCoreAgentRunner(this.core, {AgentWorkspaceServices Function(RpcAgentRun run)? workspaceFactory})
    : _workspaceFactory = workspaceFactory ?? _defaultWorkspace;

  final LocalCore core;
  final AgentWorkspaceServices Function(RpcAgentRun run) _workspaceFactory;

  static AgentWorkspaceServices _defaultWorkspace(RpcAgentRun run) => LocalWorkspaceServices(
    model: run.model,
    baseUrl: run.baseUrl,
    apiKey: run.apiKey,
    thinkingLevel: run.thinkingLevel,
  );

  @override
  Stream<Map<String, dynamic>> run(RpcAgentRun run, CancellationToken abort) {
    final controller = StreamController<Map<String, dynamic>>();
    unawaited(_drive(run, abort, controller));
    return controller.stream;
  }

  Future<void> _drive(
    RpcAgentRun run,
    CancellationToken abort,
    StreamController<Map<String, dynamic>> controller,
  ) async {
    var terminal = false;
    void emit(Map<String, dynamic> event) {
      if (controller.isClosed) return;
      if (isTerminalEvent(event)) terminal = true;
      controller.add(event);
    }

    try {
      if (!run.isConfigured) {
        emit(<String, dynamic>{
          'type': 'failed',
          'error': 'agent_not_configured',
          'message': '还没有选择模型，请先在设置里完成',
          'stopReason': 'failed',
        });
        return;
      }
      // workspace 模式走本地工作区服务（3D/视频/热应用），不需要设计引擎。
      if (run.mode != 'plan' && run.mode != 'workspace' && !core.engineReady) {
        emit(<String, dynamic>{
          'type': 'failed',
          'error': 'engine_unavailable',
          'message': '设计服务暂时不可用，请稍后重试',
          'stopReason': 'failed',
        });
        return;
      }
      final result = await runDartAgent(
        request: run.toRequest(),
        bridge: LocalEngineGate(core.engine),
        workspace: run.mode == 'plan' ? null : _workspaceFactory(run),
        onEvent: emit,
        abortSignal: abort,
      );
      if (!terminal) {
        emit(<String, dynamic>{
          'type': result.ok ? 'done' : 'failed',
          if (!result.ok) 'error': result.error ?? 'agent_failed',
          'stopReason': result.stopReason,
          'ops': result.ops,
          if (result.mbt.isNotEmpty) 'mbt_b64': base64Encode(utf8.encode(result.mbt)),
          'docs': result.docs,
        });
      }
    } catch (error) {
      if (!terminal) {
        emit(<String, dynamic>{
          'type': 'failed',
          'error': 'agent_failed',
          'detail': '$error',
          'stopReason': 'failed',
        });
      }
    } finally {
      if (!controller.isClosed) await controller.close();
    }
  }
}

// ---------------------------------------------------------------------------
// External agents (desktop only)
// ---------------------------------------------------------------------------

/// The external-agent face the host exposes. Tests inject a fake so no process
/// is ever spawned; production uses [SystemRpcAcpRuntime].
abstract class RpcAcpRuntime {
  /// Whether this host can run external agents at all (desktop only).
  bool get supported;

  /// Installed / selectable agents. `probe` only bypasses the detect cache —
  /// it never performs a live handshake; the result is always static
  /// launchability detection.
  Future<List<AcpAgentAvailability>> agents({bool probe = false});

  /// Starts one session; throws [AcpFailure] on failure.
  Future<RpcAcpSession> start({required String agent, String? cwd});
}

/// One external-agent session seen from the host.
abstract class RpcAcpSession {
  String get id;

  /// Prompt events (`assistant_delta`, `tool_start`, `permission`, `done`, …).
  Stream<Map<String, dynamic>> prompt(String text);

  /// Answers a `permission` event. Returns false when the id is unknown/expired.
  Future<bool> answerPermission(String requestId, {String? optionId, bool cancelled = false});

  Future<void> cancel();
  Future<void> close();
}

/// Production external-agent runtime over [AcpClient].
class SystemRpcAcpRuntime implements RpcAcpRuntime {
  SystemRpcAcpRuntime({
    AcpHost? host,
    Future<Directory> Function()? workspaceRoot,
    List<AcpCatalogEntry>? catalog,
  }) : _host = host ?? SystemAcpHost(),
       _workspaceRoot = workspaceRoot,
       _catalog = catalog;

  final AcpHost _host;
  final Future<Directory> Function()? _workspaceRoot;
  final List<AcpCatalogEntry>? _catalog;
  final Map<String, SystemRpcAcpSession> _sessions = <String, SystemRpcAcpSession>{};
  List<AcpAgentAvailability>? _cache;
  int _seq = 0;

  @override
  bool get supported => _host.isDesktop;

  @override
  Future<List<AcpAgentAvailability>> agents({bool probe = false}) async {
    // `probe` 仅绕过检测缓存（让 [AcpPathResolver.detect] 重跑一次）——它从不
    // 触发握手或启动验证；列表始终是「文件可启动形态」的静态检测结果。
    if (!supported) return const <AcpAgentAvailability>[];
    final cached = _cache;
    if (!probe && cached != null) return cached;
    final detected = await AcpPathResolver(host: _host).detect();
    _cache = detected;
    return detected;
  }

  @override
  Future<RpcAcpSession> start({required String agent, String? cwd}) async {
    if (!supported) throw const AcpFailure('acp_desktop_only');
    final workspace = await _workspaceFor(agent, cwd);
    _seq += 1;
    final session = SystemRpcAcpSession(
      id: 'acp-$_seq',
      host: _host,
      catalog: _catalog,
    );
    await session.open(agentId: agent, workspace: workspace);
    _sessions[session.id] = session;
    return session;
  }

  Future<Directory> _workspaceFor(String agent, String? cwd) async {
    final explicit = cwd?.trim() ?? '';
    if (explicit.isNotEmpty) return Directory(explicit);
    final root = _workspaceRoot != null
        ? await _workspaceRoot()
        : await AppPaths.projectsRoot();
    return Directory('${root.path}/agents/$agent');
  }
}

/// One [AcpClient] session, with permission requests turned into stream events.
class SystemRpcAcpSession implements RpcAcpSession {
  SystemRpcAcpSession({required this.id, required AcpHost host, List<AcpCatalogEntry>? catalog})
    : _host = host,
      _catalog = catalog;

  @override
  final String id;

  final AcpHost _host;
  final List<AcpCatalogEntry>? _catalog;

  late final AcpClient _client = AcpClient(
    host: _host,
    catalog: _catalog,
    onPermission: _askPermission,
    onNote: _note,
  );

  /// Where permission/note events go while a prompt is in flight.
  void Function(Map<String, dynamic> event)? _sink;
  final Map<String, Completer<AcpPermissionDecision>> _pending = {};
  StreamSubscription<Map<String, dynamic>>? _promptSub;
  int _permSeq = 0;

  Future<void> open({required String agentId, required Directory workspace}) async {
    await _client.start(agentId: agentId, workspace: workspace.path);
  }

  @override
  Stream<Map<String, dynamic>> prompt(String text) {
    final controller = StreamController<Map<String, dynamic>>();
    _sink = (event) {
      if (!controller.isClosed) controller.add(event);
    };
    _promptSub = _client.prompt(text).listen(
      (event) {
        if (!controller.isClosed) controller.add(event);
      },
      onError: (Object error) {
        if (!controller.isClosed) {
          controller.add(<String, dynamic>{
            'type': 'failed',
            'error': 'acp_rpc_error',
            'detail': '$error',
            'stopReason': 'failed',
          });
        }
      },
      onDone: () {
        _sink = null;
        if (!controller.isClosed) controller.close();
      },
    );
    return controller.stream;
  }

  Future<AcpPermissionDecision> _askPermission(AcpPermissionRequest request) {
    final sink = _sink;
    if (sink == null) return Future<AcpPermissionDecision>.value(const AcpPermissionDecision.cancelled());
    _permSeq += 1;
    final requestId = 'perm-$_permSeq';
    final completer = Completer<AcpPermissionDecision>();
    _pending[requestId] = completer;
    sink(<String, dynamic>{
      'type': 'permission',
      'request_id': requestId,
      'title': request.title,
      'options': <Map<String, dynamic>>[
        for (final option in request.options)
          <String, dynamic>{'option_id': option.optionId, 'name': option.name, 'kind': option.kind},
      ],
    });
    return completer.future.timeout(const Duration(minutes: 2), onTimeout: () {
      _pending.remove(requestId);
      return const AcpPermissionDecision.cancelled();
    });
  }

  void _note(String label, String detail) {
    final sink = _sink;
    if (sink == null) return;
    sink(<String, dynamic>{'type': 'note', 'label': label, if (detail.isNotEmpty) 'detail': detail});
  }

  @override
  Future<bool> answerPermission(String requestId, {String? optionId, bool cancelled = false}) async {
    final completer = _pending.remove(requestId);
    if (completer == null || completer.isCompleted) return false;
    if (cancelled || optionId == null || optionId.isEmpty) {
      completer.complete(const AcpPermissionDecision.cancelled());
    } else {
      completer.complete(AcpPermissionDecision.selected(optionId));
    }
    return true;
  }

  @override
  Future<void> cancel() => _client.cancel();

  @override
  Future<void> close() async {
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.complete(const AcpPermissionDecision.cancelled());
    }
    _pending.clear();
    _sink = null;
    await _promptSub?.cancel();
    _promptSub = null;
    await _client.close();
  }
}

// ---------------------------------------------------------------------------
// Service container
// ---------------------------------------------------------------------------

/// Everything the host may delegate to.
///
/// Desktop production constructs it once before `start()` with the app's own
/// [LocalCore]; the remaining fields default to lazily-opened local services.
/// Tests inject fake factories so no user directory or model endpoint is
/// touched.
class RpcServices {
  RpcServices({
    required this.core,
    Future<ThreeService> Function()? three,
    Future<HotAppService> Function()? hotApp,
    Future<NonAppLibrary> Function()? nonApp,
    VideoService? video,
    RpcAgentRunner? agent,
    RpcAcpRuntime? acp,
    FigmaExporter? figma,
    this.modelSnapshot,
    this.modelRefresh,
    bool systemAcp = true,
  }) : three = three ?? (() => ThreeService.open()),
       hotApp = hotApp ?? (() => HotAppService.open()),
       nonApp = nonApp ?? (() => NonAppLibrary.open()),
       video = video ?? VideoService.instance,
       agent = agent ?? LocalCoreAgentRunner(core),
       acp = acp ?? (systemAcp && (Platform.isMacOS || Platform.isWindows || Platform.isLinux) ? SystemRpcAcpRuntime() : null),
       figma = figma ?? FigmaExporter();

  /// In-process engine + local `.ddp` project library.
  final LocalCore core;

  /// 3D workspace factory (lazy: no directory is created until used).
  final Future<ThreeService> Function() three;

  /// Hot-app workspace factory.
  final Future<HotAppService> Function() hotApp;

  /// `.nonapp` application library factory.
  final Future<NonAppLibrary> Function() nonApp;

  /// Video workspace (render is desktop-only inside the service itself).
  final VideoService video;

  /// Built-in agent runner (streaming `agent.run`).
  final RpcAgentRunner agent;

  /// External-agent runtime; null on phones/tablets by design.
  final RpcAcpRuntime? acp;

  /// Figma package exporter (desktop only inside the exporter itself).
  final FigmaExporter figma;

  /// Bundled model snapshot for `models.snapshot`; null = not wired.
  final Future<Map<String, dynamic>> Function()? modelSnapshot;

  /// Registry refresh; null = the bundled snapshot is authoritative.
  final Future<Map<String, dynamic>> Function()? modelRefresh;
}

// ---------------------------------------------------------------------------
// Stream handle
// ---------------------------------------------------------------------------

/// One streaming reply: events plus a hook the host calls when the client
/// disappears before the terminal event (so an abandoned agent run stops
/// burning tokens).
class RpcStreamHandle {
  const RpcStreamHandle(this.events, {this.onClientGone});

  final Stream<Map<String, dynamic>> events;
  final void Function()? onClientGone;
}

// ---------------------------------------------------------------------------
// Method table
// ---------------------------------------------------------------------------

/// The host's method table. One instance per [DesktopRpcHost].
class RpcMethodTable {
  RpcMethodTable(this.services);

  final RpcServices services;

  final Map<String, _UnaryHandler> _unary = <String, _UnaryHandler>{};
  final Map<String, _StreamHandler> _streaming = <String, _StreamHandler>{};
  final Map<int, CancellationToken> _runs = <int, CancellationToken>{};
  final Map<String, RpcAcpSession> _acpSessions = <String, RpcAcpSession>{};
  final Set<String> _videoJobs = <String>{};
  int _runSeq = 0;

  bool _built = false;

  /// Builds the table once. Safe to call repeatedly.
  void build() {
    if (_built) return;
    _built = true;
    _registerProbes();
    _registerEngine();
    _registerProjects();
    _registerAgent();
    _registerExternalAgent();
    _registerThree();
    _registerHotApp();
    _registerNonApp();
    _registerVideo();
    _registerPortfolio();
    _registerModels();
  }

  /// Canonical method names this table implements.
  Iterable<String> get names {
    build();
    return <String>[..._unary.keys, ..._streaming.keys];
  }

  /// Whether [method] answers with SSE.
  bool isStreaming(String method) {
    build();
    return _streaming.containsKey(RpcMethod.canonical(method));
  }

  // -- public entry points ---------------------------------------------------

  /// Runs one unary method. Never throws.
  Future<Map<String, dynamic>> invoke(String method, Map<String, dynamic> params) async {
    build();
    final canonical = RpcMethod.canonical(method);
    final handler = _unary[canonical];
    if (handler == null) {
      if (_streaming.containsKey(canonical)) {
        return rpcFailure(
          RpcErrorCode.unknownMethod,
          detail: '$method answers with a stream; call it over text/event-stream',
        );
      }
      return rpcFailure(RpcErrorCode.unknownMethod, detail: method);
    }
    try {
      return await handler(params);
    } catch (error) {
      return rpcFailure(RpcErrorCode.internal, detail: '$error');
    }
  }

  /// Opens a streaming method, or returns null when [method] is unary/unknown.
  RpcStreamHandle? openStream(String method, Map<String, dynamic> params) {
    build();
    final canonical = RpcMethod.canonical(method);
    final handler = _streaming[canonical];
    if (handler == null) return null;
    try {
      return handler(params);
    } catch (error) {
      return RpcStreamHandle(
        Stream<Map<String, dynamic>>.value(<String, dynamic>{
          'type': 'failed',
          'error': RpcErrorCode.internal,
          'detail': '$error',
          'stopReason': 'failed',
        }),
      );
    }
  }

  /// Cancels a built-in agent run by id. Returns whether anything was running.
  bool cancelRun(int runId) {
    final token = _runs.remove(runId);
    if (token == null) return false;
    token.cancel();
    return true;
  }

  /// Number of in-flight runs (diagnostics/tests).
  int get activeRuns => _runs.length;

  /// Closes every external-agent session (host shutdown).
  Future<void> shutdown() async {
    for (final session in _acpSessions.values.toList()) {
      try {
        await session.close();
      } catch (_) {
        // Shutdown is best-effort: a dead agent process must not block stop().
      }
    }
    _acpSessions.clear();
    for (final token in _runs.values) {
      token.cancel();
    }
    _runs.clear();
  }

  // -- probe faces -----------------------------------------------------------

  void _registerProbes() {
    _unary[RpcMethod.health] = (params) async => healthPayload();
    _unary[RpcMethod.capabilities] = (params) async => capabilitiesPayload();
  }

  /// Body of `GET /v1/health` and the `health` method.
  Map<String, dynamic> healthPayload() => <String, dynamic>{
    'ok': true,
    'protocol': rpcProtocolVersion,
    'version': '$rpcProtocolVersion',
    'name': rpcHostName,
    'engine': services.core.engineReady,
  };

  /// Body of `GET /v1/capabilities` and the `capabilities` method.
  Map<String, dynamic> capabilitiesPayload() {
    final videoReady = services.video.host.isDesktop;
    return <String, dynamic>{
      'ok': true,
      'protocol': rpcProtocolVersion,
      'version': '$rpcProtocolVersion',
      'capabilities': <String, bool>{
        'engine': services.core.engineReady,
        'projects': true,
        'agent': true,
        'three': true,
        'hotapp': true,
        'nonapp': true,
        'video': videoReady,
        'acp': services.acp?.supported ?? false,
        'models': services.modelSnapshot != null,
        'figma': services.figma.isAvailable,
      },
    };
  }

  // -- engine ----------------------------------------------------------------

  void _registerEngine() {
    final engine = services.core.engine;
    _unary[RpcMethod.engineRender] = (p) async => engine.render(_str(p, 'mbt'));
    _unary[RpcMethod.engineValidate] = (p) async => engine.validate(_str(p, 'mbt'));
    _unary[RpcMethod.engineApply] = (p) async {
      final gate = _str(p, 'gate', 'human');
      if (gate != 'human' && gate != 'agent') {
        return rpcFailure(RpcErrorCode.invalidParams, detail: 'gate must be human|agent');
      }
      final op = _str(p, 'op');
      if (op.isEmpty) return rpcFailure(RpcErrorCode.invalidParams, detail: 'missing op');
      return engine.apply(_str(p, 'mbt'), op, gate: gate);
    };
    _unary[RpcMethod.engineSession] = (p) async {
      final name = _str(p, 'name');
      // Whitelist, not a prefix test: an arbitrary `session_bogus` used to
      // open a real session just to fail on the missing export (leaking one
      // engine session per call before the handle was closed).
      if (!isSessionExportName(name)) {
        return rpcFailure(RpcErrorCode.invalidParams, detail: 'unlisted session call');
      }
      final arg = p['arg'];
      return engine.session(_str(p, 'mbt'), name, arg == null ? null : '$arg');
    };
    _unary[RpcMethod.engineGenerate] = (p) async {
      final spec = p['spec'];
      if (spec is! Map) return rpcFailure(RpcErrorCode.invalidParams, detail: 'spec must be an object');
      return engine.generate(
        _str(p, 'mbt'),
        _str(p, 'intent'),
        _str(p, 'name'),
        Map<String, dynamic>.from(spec),
      );
    };
    _unary[RpcMethod.engineTap] = (p) async =>
        engine.tap(_str(p, 'mbt'), _str(p, 'artboard'), _double(p, 'x'), _double(p, 'y'));
    _unary[RpcMethod.engineConstrain] = (p) async =>
        engine.constrainIntent(_str(p, 'mbt'), _str(p, 'artboard'), _str(p, 'intent'));
    _unary[RpcMethod.engineEvent] = (p) async =>
        engine.event(_str(p, 'mbt'), _str(p, 'artboard'), _str(p, 'spec'));
    _unary[RpcMethod.engineHistory] = (p) async => engine.history(_str(p, 'mbt'), _str(p, 'command'));
    _unary[RpcMethod.engineExportHtml] = (p) async => engine.exportHtml(_str(p, 'mbt'));
    _unary[RpcMethod.engineTokens] = (p) async => engine.tokens();
    _unary[RpcMethod.engineVersion] = (p) async => engine.versionInfo();
    _unary[RpcMethod.engineTemplates] = (p) async => <String, dynamic>{
      'ok': true,
      'templates': await engine.templates(),
    };
    _unary[RpcMethod.engineComponents] = (p) async => <String, dynamic>{
      'ok': true,
      'components': await engine.components(),
    };
    _unary[RpcMethod.engineThemes] = (p) async => <String, dynamic>{
      'ok': true,
      'themes': await engine.themes(),
    };
    _unary[RpcMethod.engineOps] = (p) async => <String, dynamic>{'ok': true, 'ops': await engine.ops()};
    _unary[RpcMethod.engineStats] = (p) async {
      final adapter = engine;
      if (adapter is EngineServiceAdapter) {
        final stats = await adapter.service.stats();
        return <String, dynamic>{'ok': true, 'stats': stats.toJson()};
      }
      return rpcFailure('engine_unavailable', detail: 'statistics need the in-process host');
    };
    _unary[RpcMethod.engineRecycle] = (p) async {
      final adapter = engine;
      if (adapter is EngineServiceAdapter) {
        final stats = await adapter.service.recycle();
        return <String, dynamic>{'ok': true, 'stats': stats.toJson()};
      }
      return rpcFailure('engine_unavailable', detail: 'recycling needs the in-process host');
    };
  }

  // -- projects --------------------------------------------------------------

  void _registerProjects() {
    final projects = services.core.projects;
    _unary[RpcMethod.projectSave] = (p) async {
      final path = _str(p, 'path');
      if (!_isProjectPath(path)) {
        return rpcFailure(RpcErrorCode.invalidParams, detail: 'path must be a .ddp file');
      }
      final result = await projects.save(
        path: path,
        mbt: _str(p, 'mbt'),
        password: _str(p, 'password'),
        docs: _map(p, 'docs'),
      );
      if (!result.ok) {
        return <String, dynamic>{'ok': false, 'error': result.error, 'path': result.path};
      }
      return <String, dynamic>{'ok': true, 'path': result.path, 'bytes': result.bytes};
    };
    _unary[RpcMethod.projectOpen] = (p) async {
      final path = _str(p, 'path');
      if (!_isProjectPath(path)) {
        return rpcFailure(RpcErrorCode.invalidParams, detail: 'path must be a .ddp file');
      }
      final result = await projects.open(path, password: _str(p, 'password'));
      if (result.ok) {
        return <String, dynamic>{
          'ok': true,
          'path': result.path,
          'mbt': result.mbt,
          'docs': result.docs,
          'bytes': result.bytes,
        };
      }
      if (result.needPassword) {
        return <String, dynamic>{
          'ok': false,
          'need_password': true,
          'path': result.path,
          'error': result.error,
        };
      }
      return <String, dynamic>{'ok': false, 'path': result.path, 'error': result.error};
    };
    _unary[RpcMethod.projectList] = (p) async {
      final dir = _str(p, 'dir');
      final result = await projects.list(dir: dir.isEmpty ? null : dir);
      if (!result.ok) {
        return <String, dynamic>{'ok': false, 'dir': result.dir, 'error': result.error};
      }
      return <String, dynamic>{
        'ok': true,
        'dir': result.dir,
        'projects': <Map<String, dynamic>>[for (final entry in result.projects) entry.toJson()],
      };
    };
    _unary[RpcMethod.projectExportFigma] = (p) async {
      final render = RenderEnvelope.fromJson(await services.core.engine.render(_str(p, 'mbt')));
      final dir = _str(p, 'directory');
      final target = dir.isNotEmpty
          ? dir
          : '${(await AppPaths.projectsRoot()).path}/figma';
      final result = await services.figma.export(render: render, directory: target);
      return result.toJson();
    };
  }

  // -- built-in agent --------------------------------------------------------

  void _registerAgent() {
    _streaming[RpcMethod.agentRun] = _agentRun;
    _unary[RpcMethod.agentCancel] = (p) async {
      final runId = _int(p, 'run_id', -1);
      if (runId < 0) return rpcFailure(RpcErrorCode.invalidParams, detail: 'missing run_id');
      final cancelled = cancelRun(runId);
      return <String, dynamic>{'ok': true, 'cancelled': cancelled};
    };
    _unary[RpcMethod.agentSessionClear] = (p) async =>
        <String, dynamic>{'ok': true, 'cleared': true};
  }

  RpcStreamHandle _agentRun(Map<String, dynamic> params) {
    final runIdParam = _int(params, 'run_id', -1);
    final runId = runIdParam >= 0 ? runIdParam : ++_runSeq;
    final mode = _str(params, 'mode', 'build');
    final run = RpcAgentRun(
      runId: runId,
      // workspace 模式必须保留：宿主据此收窄工具面（只给工作区工具）。
      mode: const <String>['plan', 'refine', 'workspace'].contains(mode) ? mode : 'build',
      instruction: _str(params, 'instruction'),
      mbt: _str(params, 'mbt'),
      docs: _map(params, 'docs'),
      model: _str(params, 'model'),
      baseUrl: _str(params, 'base_url'),
      apiKey: _str(params, 'api_key'),
      thinkingLevel: _str(params, 'thinking_level', 'auto'),
      maxSteps: _int(params, 'max_steps', 300),
      contextWindow: params['context_window'] is num
          ? (params['context_window'] as num).toInt()
          : null,
      workspaceHint: _str(params, 'workspace_hint'),
    );

    final token = CancellationToken();
    _runs[runId] = token;
    final source = services.agent.run(run, token);
    final controller = StreamController<Map<String, dynamic>>();
    late final StreamSubscription<Map<String, dynamic>> sub;
    var terminal = false;

    void emit(Map<String, dynamic> event) {
      if (controller.isClosed) return;
      if (isTerminalEvent(event)) terminal = true;
      controller.add(event);
    }

    controller.add(<String, dynamic>{'type': 'started', 'run_id': runId, 'mode': run.mode});
    sub = source.listen(
      emit,
      onError: (Object error) {
        emit(<String, dynamic>{
          'type': 'failed',
          'error': 'agent_failed',
          'detail': '$error',
          'stopReason': 'failed',
        });
      },
      onDone: () {
        if (!terminal) {
          emit(<String, dynamic>{
            'type': 'failed',
            'error': 'agent_incomplete',
            'stopReason': 'failed',
          });
        }
        _runs.remove(runId);
        if (!controller.isClosed) controller.close();
      },
      cancelOnError: false,
    );

    return RpcStreamHandle(
      controller.stream,
      onClientGone: () {
        token.cancel();
        _runs.remove(runId);
        unawaited(sub.cancel());
      },
    );
  }

  // -- external agents -------------------------------------------------------

  void _registerExternalAgent() {
    _streaming[RpcMethod.externalPrompt] = _externalPrompt;

    _unary[RpcMethod.externalAgents] = (p) async {
      final runtime = services.acp;
      if (runtime == null || !runtime.supported) {
        return <String, dynamic>{'ok': true, 'agents': const <dynamic>[]};
      }
      try {
        final agents = await runtime.agents(probe: _bool(p, 'probe'));
        return <String, dynamic>{
          'ok': true,
          'agents': <Map<String, dynamic>>[for (final agent in agents) agent.toJson()],
        };
      } on AcpFailure catch (error) {
        return <String, dynamic>{
          'ok': false,
          'error': error.code,
          'message': acpFailureMessage(error.code),
          'detail': error.detail,
        };
      }
    };

    _unary[RpcMethod.externalSession] = (p) async {
      final runtime = services.acp;
      if (runtime == null || !runtime.supported) {
        return <String, dynamic>{
          'ok': false,
          'error': 'acp_desktop_only',
          'message': acpFailureMessage('acp_desktop_only'),
        };
      }
      final agent = _str(p, 'agent');
      if (agent.isEmpty) return rpcFailure(RpcErrorCode.invalidParams, detail: 'missing agent');
      try {
        final session = await runtime.start(agent: agent, cwd: _str(p, 'cwd'));
        _acpSessions[session.id] = session;
        return <String, dynamic>{'ok': true, 'session_id': session.id};
      } on AcpFailure catch (error) {
        return <String, dynamic>{
          'ok': false,
          'error': error.code,
          'message': acpFailureMessage(error.code),
          'detail': error.detail,
        };
      }
    };

    _unary[RpcMethod.externalCancel] = (p) async {
      final session = _acpSessions[_str(p, 'session_id')];
      if (session == null) return <String, dynamic>{'ok': false, 'error': 'acp_session_not_started'};
      await session.cancel();
      return <String, dynamic>{'ok': true};
    };

    _unary[RpcMethod.externalClose] = (p) async {
      final session = _acpSessions.remove(_str(p, 'session_id'));
      if (session == null) return <String, dynamic>{'ok': true, 'closed': false};
      await session.close();
      return <String, dynamic>{'ok': true, 'closed': true};
    };

    _unary[RpcMethod.externalPermission] = (p) async {
      final session = _acpSessions[_str(p, 'session_id')];
      if (session == null) return <String, dynamic>{'ok': false, 'error': 'acp_session_not_started'};
      final answered = await session.answerPermission(
        _str(p, 'request_id'),
        optionId: p['option_id'] == null ? null : '${p['option_id']}',
        cancelled: _bool(p, 'cancelled'),
      );
      return <String, dynamic>{'ok': answered};
    };
  }

  RpcStreamHandle _externalPrompt(Map<String, dynamic> params) {
    final sessionId = _str(params, 'session_id');
    final session = _acpSessions[sessionId];
    if (session == null) {
      return RpcStreamHandle(
        Stream<Map<String, dynamic>>.value(<String, dynamic>{
          'type': 'failed',
          'error': 'acp_session_not_started',
          'message': acpFailureMessage('acp_session_not_started'),
          'stopReason': 'failed',
        }),
      );
    }
    final controller = StreamController<Map<String, dynamic>>();
    late final StreamSubscription<Map<String, dynamic>> sub;
    var terminal = false;
    void emit(Map<String, dynamic> event) {
      if (controller.isClosed) return;
      if (isTerminalEvent(event)) terminal = true;
      controller.add(event);
    }

    sub = session.prompt(_str(params, 'text')).listen(
      emit,
      onError: (Object error) {
        emit(<String, dynamic>{
          'type': 'failed',
          'error': 'acp_rpc_error',
          'detail': '$error',
          'stopReason': 'failed',
        });
      },
      onDone: () {
        if (!terminal) {
          emit(<String, dynamic>{'type': 'failed', 'error': 'acp_rpc_error', 'stopReason': 'failed'});
        }
        if (!controller.isClosed) controller.close();
      },
    );

    return RpcStreamHandle(
      controller.stream,
      onClientGone: () {
        unawaited(sub.cancel());
        unawaited(session.cancel());
      },
    );
  }

  // -- 3D --------------------------------------------------------------------

  void _registerThree() {
    Future<Map<String, dynamic>> guard(Future<Map<String, dynamic>> Function() body) async {
      try {
        return await body();
      } on ThreeFailure catch (error) {
        return <String, dynamic>{'ok': false, 'error': error.code, 'detail': error.detail};
      }
    }

    _unary[RpcMethod.threeProjects] = (p) => guard(() async {
      final service = await services.three();
      final projects = await service.listProjects();
      return <String, dynamic>{
        'ok': true,
        'projects': <Map<String, dynamic>>[
          for (final project in projects)
            <String, dynamic>{
              'name': project.name,
              'current': project.current,
              'blocked': project.blocked,
            },
        ],
      };
    });

    _unary[RpcMethod.threeProject] = (p) => guard(() async {
      final service = await services.three();
      final snapshot = await service.readProject(_str(p, 'name'));
      return <String, dynamic>{'ok': true, 'project': _threeSnapshot(snapshot)};
    });

    _unary[RpcMethod.threeProjectNew] = (p) => guard(() async {
      final config = _threeConfig(p);
      if (config.model.isEmpty || !config.isConfigured) {
        return <String, dynamic>{'ok': false, 'error': 'model_not_configured'};
      }
      final service = await services.three();
      final snapshot = await service.newProject(
        name: _str(p, 'name'),
        brief: _str(p, 'brief'),
        config: config,
      );
      return <String, dynamic>{'ok': true, 'project': _threeSnapshot(snapshot)};
    });

    _unary[RpcMethod.threePass] = (p) => guard(() async {
      final config = _threeConfig(p);
      if (config.model.isEmpty || !config.isConfigured) {
        return <String, dynamic>{'ok': false, 'error': 'model_not_configured'};
      }
      final service = await services.three();
      final result = await service.runPass(_str(p, 'name'), config);
      return <String, dynamic>{
        'ok': true,
        'pass': result.pass,
        'stale': result.stale,
        'chars': result.chars,
        'state': result.state,
      };
    });

    _unary[RpcMethod.threeFeedback] = (p) => guard(() async {
      final service = await services.three();
      final result = await service.feedback(
        _str(p, 'name'),
        _str(p, 'kind', 'metrics'),
        p['payload'],
      );
      return <String, dynamic>{
        'ok': true,
        'status': result.status,
        'pass': result.pass,
        'attempts': result.attempts,
        'state': result.state,
      };
    });

    _unary[RpcMethod.threeContinue] = (p) => guard(() async {
      final service = await services.three();
      final result = await service.continuePass(_str(p, 'name'), _str(p, 'summary'));
      return <String, dynamic>{'ok': true, 'current': result.current, 'done': result.done};
    });

    _unary[RpcMethod.threeSpec] = (p) => guard(() async {
      final service = await services.three();
      final result = await service.saveSpec(_str(p, 'name'), _map(p, 'spec'));
      return <String, dynamic>{'ok': true, 'unblocked': result.unblocked, 'state': result.state};
    });

    _unary[RpcMethod.threeDelete] = (p) => guard(() async {
      final service = await services.three();
      await service.deleteProject(_str(p, 'name'));
      return <String, dynamic>{'ok': true};
    });

    _unary[RpcMethod.threePreview] = (p) => guard(() async {
      final name = _str(p, 'name');
      final service = await services.three();
      final bundle = await service.preparePreview(name);
      return <String, dynamic>{
        'ok': true,
        'name': name,
        'url': '/v1/assets/three/${Uri.encodeComponent(name)}',
        'html_path': bundle.htmlPath,
      };
    });
  }

  // -- hot apps --------------------------------------------------------------

  void _registerHotApp() {
    Future<Map<String, dynamic>> guard(Future<Map<String, dynamic>> Function() body) async {
      try {
        return await body();
      } on HotAppFailure catch (error) {
        return <String, dynamic>{
          'ok': false,
          'error': error.code,
          'message': hotAppFailureMessage(error),
          'detail': error.detail,
        };
      } on NonAppException catch (error) {
        return <String, dynamic>{'ok': false, 'error': error.code, 'detail': error.message};
      }
    }

    _unary[RpcMethod.hotAppList] = (p) => guard(() async {
      final service = await services.hotApp();
      final apps = await service.list();
      return <String, dynamic>{
        'ok': true,
        'apps': <Map<String, dynamic>>[for (final app in apps) _libraryApp(app)],
      };
    });

    _unary[RpcMethod.hotAppRead] = (p) => guard(() async {
      final service = await services.hotApp();
      final name = _str(p, 'name');
      final app = await service.read(name);
      if (app == null) return <String, dynamic>{'ok': false, 'error': 'no_app'};
      final html = await service.html(name);
      final surface = await service.surface(name);
      return <String, dynamic>{
        'ok': true,
        'app': _libraryApp(app),
        'html': ?html,
        'surface': ?surface,
      };
    });

    _unary[RpcMethod.hotAppGenerate] = (p) => guard(() async {
      final config = _hotAppConfig(p);
      if (config.model.isEmpty || !config.isConfigured) {
        return <String, dynamic>{'ok': false, 'error': 'llm_error', 'detail': 'model_not_configured'};
      }
      final service = await services.hotApp();
      final app = await service.generate(
        name: _str(p, 'name'),
        brief: _str(p, 'brief'),
        config: config,
      );
      return <String, dynamic>{'ok': true, 'app': _libraryApp(app)};
    });

    _unary[RpcMethod.hotAppRefine] = (p) => guard(() async {
      final config = _hotAppConfig(p);
      if (config.model.isEmpty || !config.isConfigured) {
        return <String, dynamic>{'ok': false, 'error': 'llm_error', 'detail': 'model_not_configured'};
      }
      final service = await services.hotApp();
      final app = await service.refine(
        name: _str(p, 'name'),
        instruction: _str(p, 'instruction'),
        config: config,
      );
      return <String, dynamic>{'ok': true, 'app': _libraryApp(app)};
    });

    _unary[RpcMethod.hotAppInspect] = (p) => guard(() async {
      final service = await services.hotApp();
      final name = _str(p, 'name');
      final app = await service.read(name);
      if (app == null) return <String, dynamic>{'ok': false, 'error': 'no_app'};
      final surface = await service.surface(name);
      return <String, dynamic>{
        'ok': true,
        'app': _libraryApp(app),
        'url': '/v1/assets/hotapp/${Uri.encodeComponent(name)}',
        'surface': ?surface,
      };
    });

    _unary[RpcMethod.hotAppDelete] = (p) => guard(() async {
      final service = await services.hotApp();
      await service.delete(_str(p, 'name'));
      return <String, dynamic>{'ok': true};
    });

    _unary[RpcMethod.hotAppExport] = (p) => guard(() async {
      final service = await services.hotApp();
      final bytes = await service.exportPackage(_str(p, 'name'));
      return <String, dynamic>{
        'ok': true,
        'bytes': bytes.length,
        'base64': base64Encode(bytes),
      };
    });
  }

  // -- .nonapp packages ------------------------------------------------------

  void _registerNonApp() {
    Future<Map<String, dynamic>> guard(Future<Map<String, dynamic>> Function() body) async {
      try {
        return await body();
      } on NonAppException catch (error) {
        return <String, dynamic>{'ok': false, 'error': error.code, 'detail': error.message};
      }
    }

    _unary[RpcMethod.nonAppList] = (p) => guard(() async {
      final library = await services.nonApp();
      final apps = await library.scan();
      return <String, dynamic>{
        'ok': true,
        'apps': <Map<String, dynamic>>[for (final app in apps) _libraryApp(app)],
      };
    });

    _unary[RpcMethod.nonAppInspect] = (p) => guard(() async {
      final library = await services.nonApp();
      final name = _str(p, 'name');
      final app = await library.read(name);
      if (app == null) return <String, dynamic>{'ok': false, 'error': 'no_app'};
      final surface = await library.readSurface(name);
      final html = await library.readHtml(name);
      return <String, dynamic>{
        'ok': true,
        'app': _libraryApp(app),
        'url': '/v1/assets/hotapp/${Uri.encodeComponent(name)}',
        'surface': ?surface,
        'html_bytes': html?.length ?? 0,
      };
    });

    _unary[RpcMethod.nonAppExport] = (p) => guard(() async {
      final library = await services.nonApp();
      final name = _str(p, 'name');
      final bytes = await library.buildPackage(name);
      return <String, dynamic>{
        'ok': true,
        'name': name,
        'bytes': bytes.length,
        'base64': base64Encode(bytes),
      };
    });

    _unary[RpcMethod.nonAppDelete] = (p) => guard(() async {
      final library = await services.nonApp();
      await library.delete(_str(p, 'name'));
      return <String, dynamic>{'ok': true};
    });
  }

  // -- video -----------------------------------------------------------------

  void _registerVideo() {
    _unary[RpcMethod.videoReview] = (p) async {
      try {
        final result = reviewVideoScript(
          timeline: _map(p, 'timeline'),
          spec: p['spec'] is Map ? Map<String, dynamic>.from(p['spec'] as Map) : null,
          samples: _int(p, 'samples', 6),
        );
        return <String, dynamic>{
          'ok': result.ok,
          'total_seconds': result.totalSeconds,
          'problems': result.problems,
          'notes': result.notes,
          'technical': result.technical,
          'sample_times': result.sampleTimes,
          'summary': result.summary,
        };
      } on VideoRejected catch (error) {
        return <String, dynamic>{
          'ok': false,
          'error': error.code,
          'message': videoFailureMessage(error),
          'detail': error.technical,
        };
      }
    };

    _unary[RpcMethod.videoRender] = (p) async {
      try {
        final document = VideoDocument.build(
          timeline: _map(p, 'timeline'),
          spec: p['spec'] is Map ? Map<String, dynamic>.from(p['spec'] as Map) : null,
          baseDir: _str(p, 'base_dir').isEmpty ? null : Directory(_str(p, 'base_dir')),
        );
        final job = await services.video.startRender(
          document,
          fps: p['fps'] is num ? (p['fps'] as num).toInt() : null,
          keepSvg: _bool(p, 'keep_svg'),
        );
        _videoJobs.add(job.id);
        return <String, dynamic>{'ok': true, 'job': _videoJob(job)};
      } on VideoRejected catch (error) {
        return <String, dynamic>{
          'ok': false,
          'error': error.code,
          'message': videoFailureMessage(error),
          'detail': error.technical,
        };
      }
    };

    _unary[RpcMethod.videoJobs] = (p) async => <String, dynamic>{
      'ok': true,
      'jobs': <Map<String, dynamic>>[
        for (final id in _videoJobs)
          if (services.video.job(id) case final job?) _videoJob(job),
      ],
    };

    _unary[RpcMethod.videoJob] = (p) async {
      final job = services.video.job(_str(p, 'id'));
      if (job == null) return <String, dynamic>{'ok': false, 'error': 'job_missing'};
      return <String, dynamic>{'ok': true, 'job': _videoJob(job)};
    };

    _unary[RpcMethod.videoCancel] = (p) async {
      services.video.cancel(_str(p, 'id'));
      return <String, dynamic>{'ok': true};
    };

    _unary[RpcMethod.videoSamples] = (p) async => <String, dynamic>{
      'ok': true,
      'samples': <Map<String, dynamic>>[
        for (var i = 0; i < videoSamples.length; i++)
          <String, dynamic>{
            'index': i,
            'id': videoSamples[i].id,
            'label': videoSamples[i].label,
            'note': videoSamples[i].note,
          },
      ],
    };

    _unary[RpcMethod.videoSample] = (p) async {
      final index = _int(p, 'index', -1);
      if (index < 0 || index >= videoSamples.length) {
        return <String, dynamic>{'ok': false, 'error': 'sample_missing'};
      }
      final sample = videoSamples[index];
      return <String, dynamic>{
        'ok': true,
        'timeline': jsonDecode(sample.timelineJson),
        'spec': jsonDecode(sample.specJson),
      };
    };
  }

  // -- portfolio -------------------------------------------------------------

  void _registerPortfolio() {
    _unary[RpcMethod.portfolioList] = (p) async {
      final items = <Map<String, dynamic>>[];
      try {
        final library = await services.nonApp();
        for (final app in await library.scan()) {
          items.add(app.toShelfItem());
        }
      } catch (_) {
        // A broken hot-app folder must not hide the other shelves.
      }
      try {
        final three = await services.three();
        for (final project in await three.listProjects()) {
          items.add(<String, dynamic>{
            'kind': 'three',
            'ref': project.name,
            'title': project.name,
            'detail': project.blocked ? '这个场景还没完成' : '3D 场景',
            'path': three.projectDir(project.name).path,
          });
        }
      } catch (_) {}
      try {
        final root = Directory('${(await AppPaths.projectsRoot()).path}/videos');
        items.addAll(_scanVideos(root));
      } catch (_) {}
      try {
        final listed = await services.core.projects.list();
        if (listed.ok) {
          for (final project in listed.projects) {
            items.add(<String, dynamic>{
              'kind': 'prototype',
              'ref': project.path,
              'title': project.name,
              'detail': project.path,
              'path': project.path,
            });
          }
        }
      } catch (_) {}
      return <String, dynamic>{'ok': true, 'items': items};
    };

    _unary[RpcMethod.portfolioDelete] = (p) async {
      final kind = _str(p, 'kind');
      final ref = _str(p, 'ref');
      if (ref.isEmpty) return rpcFailure(RpcErrorCode.invalidParams, detail: 'missing ref');
      switch (kind) {
        case 'hotapp':
          await (await services.hotApp()).delete(ref);
          return <String, dynamic>{'ok': true};
        case 'three':
          await (await services.three()).deleteProject(ref);
          return <String, dynamic>{'ok': true};
        case 'video':
          // Deleting a render output is allowed only inside the videos folder.
          final root = Directory('${(await AppPaths.projectsRoot()).path}/videos');
          final file = File(ref);
          if (!_isInside(root.path, file.path)) {
            return rpcFailure(RpcErrorCode.invalidParams, detail: 'ref must be a render output');
          }
          if (await file.exists()) await file.delete();
          return <String, dynamic>{'ok': true};
        case 'prototype':
          // The shelf does not own project files (shelf-2 decision): removing a
          // project is done from the recent-projects list, not from the shelf.
          return <String, dynamic>{'ok': false, 'error': 'not_supported'};
        default:
          return rpcFailure(RpcErrorCode.invalidParams, detail: 'unknown kind');
      }
    };
  }

  List<Map<String, dynamic>> _scanVideos(Directory root) {
    if (!root.existsSync()) return const <Map<String, dynamic>>[];
    final files = <MapEntry<File, DateTime>>[];
    for (final entity in root.listSync(recursive: true, followLinks: false)) {
      if (entity is! File || !entity.path.toLowerCase().endsWith('.mp4')) continue;
      try {
        files.add(MapEntry(entity, entity.statSync().modified));
      } catch (_) {}
    }
    files.sort((a, b) => b.value.compareTo(a.value));
    return <Map<String, dynamic>>[
      for (final entry in files.take(40))
        <String, dynamic>{
          'kind': 'video',
          'ref': entry.key.path,
          'title': entry.key.uri.pathSegments.last,
          'detail': '视频',
          'path': entry.key.path,
        },
    ];
  }

  // -- models ----------------------------------------------------------------

  void _registerModels() {
    _unary[RpcMethod.modelsSnapshot] = (p) async {
      final load = services.modelSnapshot;
      if (load == null) return <String, dynamic>{'ok': false, 'error': 'models_unavailable'};
      try {
        return <String, dynamic>{'ok': true, 'registry': await load()};
      } catch (error) {
        return <String, dynamic>{'ok': false, 'error': 'models_unavailable', 'detail': '$error'};
      }
    };
    _unary[RpcMethod.modelsRefresh] = (p) async {
      final refresh = services.modelRefresh;
      if (refresh == null) {
        // The bundled snapshot is authoritative; there is nothing to fetch.
        return <String, dynamic>{'ok': false, 'error': 'models_local_only'};
      }
      try {
        return <String, dynamic>{'ok': true, 'registry': await refresh()};
      } catch (error) {
        return <String, dynamic>{'ok': false, 'error': 'models_unavailable', 'detail': '$error'};
      }
    };
  }
}

// ---------------------------------------------------------------------------
// Param helpers (defensive: a malformed request must never throw)
// ---------------------------------------------------------------------------

typedef _UnaryHandler = Future<Map<String, dynamic>> Function(Map<String, dynamic> params);
typedef _StreamHandler = RpcStreamHandle Function(Map<String, dynamic> params);

String _str(Map<String, dynamic> params, String key, [String fallback = '']) {
  final value = params[key];
  if (value == null) return fallback;
  return value is String ? value : '$value';
}

int _int(Map<String, dynamic> params, String key, int fallback) {
  final value = params[key];
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}

double _double(Map<String, dynamic> params, String key, [double fallback = 0]) {
  final value = params[key];
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? fallback;
  return fallback;
}

bool _bool(Map<String, dynamic> params, String key, [bool fallback = false]) {
  final value = params[key];
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) return value == 'true' || value == '1';
  return fallback;
}

Map<String, dynamic> _map(Map<String, dynamic> params, String key) {
  final value = params[key];
  if (value is Map) return Map<String, dynamic>.from(value);
  return <String, dynamic>{};
}

ThreeLlmConfig _threeConfig(Map<String, dynamic> params) => ThreeLlmConfig(
  model: _str(params, 'model'),
  baseUrl: _str(params, 'base_url'),
  apiKey: _str(params, 'api_key'),
  thinkingLevel: _str(params, 'thinking_level', 'auto'),
);

HotAppLlmConfig _hotAppConfig(Map<String, dynamic> params) => HotAppLlmConfig(
  model: _str(params, 'model'),
  baseUrl: _str(params, 'base_url'),
  apiKey: _str(params, 'api_key'),
  thinkingLevel: _str(params, 'thinking_level', 'auto'),
);

Map<String, dynamic> _threeSnapshot(ThreeProjectSnapshot snapshot) => <String, dynamic>{
  'name': snapshot.name,
  'spec': snapshot.spec,
  'state': snapshot.state,
  'scene_js': snapshot.sceneJs,
  'history': snapshot.history,
  'dir': snapshot.dir,
  'current': snapshot.current,
  'blocked': snapshot.blocked,
};

Map<String, dynamic> _libraryApp(LibraryApp app) => <String, dynamic>{
  'name': app.name,
  'title': app.title,
  'renderer': app.renderer,
  'created_at': app.createdAt,
  'bytes': app.payloadBytes,
  'brief': app.brief,
  'corrupt': app.corrupt,
  'dir': app.dir,
};

Map<String, dynamic> _videoJob(VideoRenderJob job) => <String, dynamic>{
  'id': job.id,
  'status': job.status.name,
  'fps': job.fps,
  'frames': job.frames,
  'total_frames': job.totalFrames,
  'total_seconds': job.totalSeconds,
  'directory': job.directory,
  'mp4_path': job.mp4Path,
  'failure_code': job.failureCode,
  'log': job.log,
};

/// Project paths must look like `.ddp` files. This keeps the pairing token
/// from doubling as an arbitrary file read/write primitive.
bool _isProjectPath(String path) {
  final value = path.trim();
  if (value.isEmpty || value.contains('\u0000')) return false;
  return value.toLowerCase().endsWith('.ddp');
}

/// Whether [child] resolves inside [root] (segment-aware prefix check).
bool _isInside(String root, String child) {
  final normalizedRoot = Directory(root).absolute.path;
  final normalizedChild = File(child).absolute.path;
  if (normalizedChild == normalizedRoot) return true;
  return normalizedChild.startsWith('$normalizedRoot${Platform.pathSeparator}');
}
