/// Runtime clients for the app (batch 05).
///
/// The app has exactly two ways to run design work:
///
///  * [LocalCore] — the in-process runtime: the design engine
///    (`core/engine/engine_service.dart`, batch 02) plus the local project
///    library (`core/project_service.dart`, batch 03). This is the default on
///    every host where the engine is allowed to run, and the only runtime on
///    phones/tablets until the wasm spike passes.
///  * [RemoteDesktopClient] — the optional "连接桌面" runtime: a desktop host
///    that speaks `/v1/health`, `/v1/capabilities` and `/v1/rpc`. It is off
///    until the user enters an address (and optional one-time token).
///
/// [NoNDesignApi] is the router the rest of the app talks to. It keeps the
/// method names the UI already uses (`render` / `apply` / `session` /
/// `generate` / `saveProject` / …) and decides per call:
///
///   local engine first → remote desktop (when connected) → explicit
///   `{ok:false, error:'engine_unavailable'}`.
///
/// There is no third path: no local HTTP server, no process spawning, no
/// fixed port. Every failure is an envelope — never a silent `null`, never a
/// hang.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'capability.dart';
import 'engine/engine_service.dart';
import 'models.dart';
import 'project_service.dart';
import 'remote_desktop_client.dart';
import 'remote/rpc_methods.dart';

/// The engine face the runtime router needs.
///
/// Production implementations wrap [EngineService] (see
/// [_EngineServiceAdapter]); tests implement a scripted engine so the router
/// and the store can be exercised without compiling a WASM module.
abstract class LocalEngine {
  /// True when calls can be served right now.
  bool get isReady;

  /// Diagnostic reason when [isReady] is false (never user-facing).
  String? get startupError;

  /// Capability snapshot for `CapabilityId.localDesignEngine`.
  CapabilityAvailability probeAvailability();

  Future<Map<String, dynamic>> render(String mbt);
  Future<Map<String, dynamic>> validate(String mbt);
  Future<Map<String, dynamic>> apply(String mbt, String op, {String gate});
  Future<Map<String, dynamic>> session(String mbt, String name, [String? arg]);
  Future<Map<String, dynamic>> generate(
      String mbt, String intent, String name, Map<String, dynamic> spec);
  Future<Map<String, dynamic>> tap(String mbt, String artboard, double x, double y);
  Future<Map<String, dynamic>> constrainIntent(String mbt, String artboard, String intent);
  Future<Map<String, dynamic>> event(String mbt, String artboard, String spec);
  Future<Map<String, dynamic>> history(String mbt, String command);
  Future<Map<String, dynamic>> exportHtml(String mbt);
  Future<Map<String, dynamic>> tokens();
  Future<Map<String, dynamic>> versionInfo();
  Future<List<dynamic>> templates();
  Future<List<dynamic>> components();
  Future<List<dynamic>> themes();
  Future<List<dynamic>> ops();
}

/// [LocalEngine] over the real in-process host.
class EngineServiceAdapter implements LocalEngine {
  EngineServiceAdapter(this.service);

  /// The wrapped host-backed service.
  final EngineService service;

  @override
  bool get isReady => service.isReady;

  @override
  String? get startupError => service.startupError;

  @override
  CapabilityAvailability probeAvailability() => service.probeAvailability();

  @override
  Future<Map<String, dynamic>> render(String mbt) => service.render(mbt);

  @override
  Future<Map<String, dynamic>> validate(String mbt) => service.validate(mbt);

  @override
  Future<Map<String, dynamic>> apply(String mbt, String op, {String gate = 'human'}) =>
      service.apply(mbt, op, gate: gate);

  @override
  Future<Map<String, dynamic>> session(String mbt, String name, [String? arg]) =>
      service.session(mbt, name, arg);

  @override
  Future<Map<String, dynamic>> generate(
          String mbt, String intent, String name, Map<String, dynamic> spec) =>
      service.generate(mbt, intent, name, spec);

  @override
  Future<Map<String, dynamic>> tap(String mbt, String artboard, double x, double y) =>
      service.tap(mbt, artboard, x, y);

  @override
  Future<Map<String, dynamic>> constrainIntent(String mbt, String artboard, String intent) =>
      service.constrainIntent(mbt, artboard, intent);

  @override
  Future<Map<String, dynamic>> event(String mbt, String artboard, String spec) =>
      service.event(mbt, artboard, spec);

  @override
  Future<Map<String, dynamic>> history(String mbt, String command) =>
      service.history(mbt, command);

  @override
  Future<Map<String, dynamic>> exportHtml(String mbt) => service.exportHtml(mbt);

  @override
  Future<Map<String, dynamic>> tokens() => service.tokens();

  @override
  Future<Map<String, dynamic>> versionInfo() => service.versionInfo();

  @override
  Future<List<dynamic>> templates() => service.templates();

  @override
  Future<List<dynamic>> components() => service.components();

  @override
  Future<List<dynamic>> themes() => service.themes();

  @override
  Future<List<dynamic>> ops() => service.ops();
}

/// The local, in-process runtime.
///
/// [engine] is never null: a failed start is still a service that answers
/// `engine_unavailable` (see [EngineService.unavailable]), so [engineReady] is
/// the single question the store asks.
class LocalCore {
  LocalCore({
    required this.engine,
    required this.projects,
    this.componentsSnapshot,
  });

  /// In-process design engine (batch 02).
  final LocalEngine engine;

  /// Local `.ddp` project library (batch 03).
  final ProjectService projects;

  /// Verified component registry (`assets/engine/components.json`).
  final List<dynamic>? componentsSnapshot;

  /// True when the engine can serve calls right now.
  bool get engineReady => engine.isReady;
}

/// Runtime router over the local core and the optional connected desktop.
class NoNDesignApi {
  /// Legacy/remote-only construction: points the router at a desktop host.
  ///
  /// Kept for call sites and tests that only exercise remote-only faces
  /// (3D / hot-app / video / portfolio / external agents). Engine and project
  /// calls go through the same RPC contract.
  NoNDesignApi(String baseUrl, [http.Client? client])
      : _local = null,
        _remote = RemoteDesktopClient(baseUrl: baseUrl, client: client),
        _localAcp = null;

  /// Local-first construction used by the store.
  ///
  /// [localAcp] 在没有桌面连接时提供**本机**外部智能体扫描（同一
  /// AcpPathResolver 探测器在进程内直跑，不经 RPC、不需要另一台电脑）。
  NoNDesignApi.runtime({
    LocalCore? local,
    RemoteDesktopClient? remote,
    SystemRpcAcpRuntime? localAcp,
  })  : _local = local,
        _remote = remote,
        _localAcp = localAcp;

  final LocalCore? _local;
  final RemoteDesktopClient? _remote;
  final SystemRpcAcpRuntime? _localAcp;

  /// The local runtime, when this router was built with one.
  LocalCore? get local => _local;

  /// The connected desktop client, when one is configured.
  RemoteDesktopClient? get remote => _remote;

  /// Address of the connected desktop ('' when local-only).
  String get baseUrl => _remote?.baseUrl ?? '';

  /// True when the in-process engine is serving calls.
  bool get hasLocalEngine => _local?.engineReady ?? false;

  /// True when a desktop address is configured (not necessarily reachable).
  bool get hasRemote => _remote?.isConfigured ?? false;

  /// True when at least one runtime can answer.
  bool get isReady => hasLocalEngine || hasRemote;

  /// Streaming idle budget (re-exported for tests and call sites).
  static Duration get sseIdleTimeout => RemoteDesktopClient.sseIdleTimeout;
  static set sseIdleTimeout(Duration value) => RemoteDesktopClient.sseIdleTimeout = value;

  /// Long generative RPC budget (re-exported for tests and call sites).
  static Duration get llmGenTimeout => RemoteDesktopClient.llmGenTimeout;
  static set llmGenTimeout(Duration value) => RemoteDesktopClient.llmGenTimeout = value;

  Map<String, dynamic> _unavailable([Object? detail]) => {
        'ok': false,
        'error': 'engine_unavailable',
        if (detail != null) 'detail': '$detail',
      };

  // -------------------------------------------------------------------------
  // Engine face
  // -------------------------------------------------------------------------

  /// Runs [localCall] on the local engine, else forwards [method] over RPC.
  Future<Map<String, dynamic>> _engine(
    String method,
    Map<String, dynamic> params,
    Future<Map<String, dynamic>> Function(LocalEngine engine) localCall,
  ) async {
    final core = _local;
    if (core != null && core.engineReady) {
      try {
        return await localCall(core.engine);
      } catch (e) {
        return _unavailable('$e');
      }
    }
    final desktop = _remote;
    if (desktop != null && desktop.isConfigured) {
      return desktop.call(method, params);
    }
    return _unavailable(core?.engine.startupError);
  }

  /// Renders a source document.
  Future<Map<String, dynamic>> render(String mbt) => _engine(
        'engine.render',
        {'mbt': mbt},
        (engine) => engine.render(mbt),
      );

  /// Validates without committing.
  Future<Map<String, dynamic>> validate(String mbt) => _engine(
        'engine.validate',
        {'mbt': mbt},
        (engine) => engine.validate(mbt),
      );

  /// Applies one canvas op. `gate` is `'human'` or `'agent'` — different doors.
  Future<Map<String, dynamic>> apply(String mbt, String op, {String gate = 'human'}) => _engine(
        'engine.apply',
        {'mbt': mbt, 'op': op, 'gate': gate},
        (engine) => engine.apply(mbt, op, gate: gate),
      );

  /// One session inspection/mutation call.
  Future<Map<String, dynamic>> session(String mbt, String name, [String? arg]) => _engine(
        'engine.session',
        {'mbt': mbt, 'name': name, if (arg != null) 'arg': arg},
        (engine) => engine.session(mbt, name, arg),
      );

  /// Full-page generation.
  Future<Map<String, dynamic>> generate(
    String mbt,
    String intent,
    String name,
    Map<String, dynamic> spec,
  ) =>
      _engine(
        'engine.generate',
        {'mbt': mbt, 'intent': intent, 'name': name, 'spec': spec},
        (engine) => engine.generate(mbt, intent, name, spec),
      );

  /// Demo-mode tap routing (play view).
  Future<Map<String, dynamic>> tap(String mbt, String artboard, double x, double y) => _engine(
        'engine.tap',
        {'mbt': mbt, 'artboard': artboard, 'x': x, 'y': y},
        (engine) => engine.tap(mbt, artboard, x, y),
      );

  /// Demo-mode gesture (`session_event`).
  Future<Map<String, dynamic>> event(String mbt, String artboard, String spec) => _engine(
        'engine.event',
        {'mbt': mbt, 'artboard': artboard, 'spec': spec},
        (engine) => engine.event(mbt, artboard, spec),
      );

  /// Layout intent (`session_constrain`).
  Future<Map<String, dynamic>> constrainIntent(String mbt, String artboard, String intent) => _engine(
        'engine.constrain',
        {'mbt': mbt, 'artboard': artboard, 'intent': intent},
        (engine) => engine.constrainIntent(mbt, artboard, intent),
      );

  /// Engine-side version history (`session_history`).
  Future<Map<String, dynamic>> history(String mbt, String command) => _engine(
        'engine.history',
        {'mbt': mbt, 'command': command},
        (engine) => engine.history(mbt, command),
      );

  /// Self-contained HTML export.
  Future<Map<String, dynamic>> exportHtml(String mbt) => _engine(
        'engine.exportHtml',
        {'mbt': mbt},
        (engine) => engine.exportHtml(mbt),
      );

  /// Design tokens registry.
  Future<Map<String, dynamic>> tokens() => _engine(
        'engine.tokens',
        const {},
        (engine) => engine.tokens(),
      );

  /// Engine version facts (diagnostics only).
  Future<Map<String, dynamic>> versionInfo() => _engine(
        'engine.version',
        const {},
        (engine) => engine.versionInfo(),
      );

  Future<List<dynamic>> _listing(
    String method,
    String key,
    Future<List<dynamic>> Function(LocalEngine engine) localCall,
  ) async {
    final core = _local;
    if (core != null && core.engineReady) {
      try {
        return await localCall(core.engine);
      } catch (_) {
        return const [];
      }
    }
    final desktop = _remote;
    if (desktop != null && desktop.isConfigured) {
      final reply = await desktop.call(method);
      if (reply['ok'] != true) return const [];
      final data = reply[key] ?? reply['data'];
      if (data is List) return data;
    }
    return const [];
  }

  /// Page templates.
  Future<List<dynamic>> templates() => _listing(
        'engine.templates',
        'templates',
        (engine) => engine.templates(),
      );

  /// Component registry (verified snapshot when available).
  Future<List<dynamic>> components() => _listing(
        'engine.components',
        'components',
        (engine) => engine.components(),
      );

  /// Theme presets.
  Future<List<dynamic>> themes() => _listing(
        'engine.themes',
        'themes',
        (engine) => engine.themes(),
      );

  /// Mutating ops registry.
  Future<List<dynamic>> ops() => _listing(
        'engine.ops',
        'ops',
        (engine) => engine.ops(),
      );

  /// Model snapshot. The local runtime reads the bundled snapshot through the
  /// store; a connected desktop may forward its own registry copy.
  Future<Map<String, dynamic>> models() async {
    final desktop = _remote;
    if (desktop != null && desktop.isConfigured) {
      return desktop.call('models.snapshot');
    }
    return {'ok': false, 'error': 'models_local_only'};
  }

  /// Re-reads the model registry. Local builds ship a verified snapshot, so a
  /// "refresh" never reaches the network (no models.dev fetch at runtime).
  Future<Map<String, dynamic>> refreshModels() async {
    final desktop = _remote;
    if (desktop != null && desktop.isConfigured) {
      return desktop.call('models.refresh');
    }
    return {'ok': false, 'error': 'models_local_only'};
  }

  // -------------------------------------------------------------------------
  // Project face (local library first — projects are client-side now)
  // -------------------------------------------------------------------------

  /// Saves one project through the local `.ddp` library.
  Future<Map<String, dynamic>> saveProject({
    required String mbt,
    required String path,
    String password = '',
    required Map<String, dynamic> docs,
  }) async {
    final core = _local;
    if (core == null) {
      return {'ok': false, 'error': 'project_store_unavailable'};
    }
    final result = await core.projects.save(
      path: path,
      mbt: mbt,
      password: password,
      docs: docs,
    );
    if (!result.ok) return {'ok': false, 'error': result.error, 'path': result.path};
    return {'ok': true, 'path': result.path, 'bytes': result.bytes};
  }

  /// Opens one project. Falls back to the connected desktop when the file does
  /// not exist locally (the user may be opening one from the desktop library).
  Future<Map<String, dynamic>> openProject(String path, {String password = ''}) async {
    final core = _local;
    if (core != null) {
      final result = await core.projects.open(path, password: password);
      if (result.ok) {
        return {
          'ok': true,
          'path': result.path,
          'mbt': result.mbt,
          'docs': result.docs,
          'bytes': result.bytes,
        };
      }
      if (result.needPassword) {
        return {'ok': false, 'need_password': true, 'path': result.path, 'error': result.error};
      }
      if (result.error != 'file_not_found') {
        return {'ok': false, 'path': result.path, 'error': result.error};
      }
    }
    final desktop = _remote;
    if (desktop != null && desktop.isConfigured) {
      return desktop.call('project.open', {'path': path, 'password': password});
    }
    return {'ok': false, 'path': path, 'error': 'file_not_found'};
  }

  /// Lists `.ddp` files in the local library (or [dir] when given).
  Future<List<dynamic>> listProjects([String? dir]) async {
    final core = _local;
    if (core != null) {
      final result = await core.projects.list(dir: dir);
      if (result.ok) {
        return [for (final entry in result.projects) entry.toJson()];
      }
      if (result.error != 'dir_not_found') return const [];
    }
    final desktop = _remote;
    if (desktop != null && desktop.isConfigured) {
      final reply = await desktop.call('project.list', {if (dir != null) 'dir': dir});
      final projects = reply['projects'];
      if (projects is List) return projects;
    }
    return const [];
  }

  /// Figma package export (desktop-side packaging).
  Future<Map<String, dynamic>> exportFigma(String mbt) async {
    final desktop = _remote;
    if (desktop == null || !desktop.isConfigured) {
      return {'ok': false, 'error': 'remote_unavailable'};
    }
    return desktop.call('project.exportFigma', {'mbt': mbt});
  }

  // -------------------------------------------------------------------------
  // Agent face
  // -------------------------------------------------------------------------

  /// Server-runtime agent stream (`agent.run` on the connected desktop).
  Stream<Map<String, dynamic>> agentRun(Map<String, dynamic> body) {
    final desktop = _remote;
    if (desktop == null || !desktop.isConfigured) {
      return Stream.fromIterable([
        {'type': 'failed', 'error': 'remote_unavailable', 'stopReason': 'failed'},
      ]);
    }
    return desktop.agentRun(body);
  }

  /// Cancels the in-flight run on the connected desktop.
  Future<bool> cancelAgent(int runId) async {
    final desktop = _remote;
    if (desktop == null || !desktop.isConfigured) return false;
    final reply = await desktop.cancelAgent(runId);
    return reply['ok'] == true;
  }

  /// Clears the agent conversation memory.
  Future<Map<String, dynamic>> clearSession(String key) async {
    final desktop = _remote;
    if (desktop == null || !desktop.isConfigured) {
      return {'ok': false, 'error': 'remote_unavailable'};
    }
    return desktop.call('agent.session.clear', {'key': key});
  }

  // -------------------------------------------------------------------------
  // External agents (desktop-only by design)
  // -------------------------------------------------------------------------

  /// Available external agents. Empty when nothing can host one.
  ///
  /// 路由：配置了桌面 → 桌面扫描；否则 → **本机直扫**（历史缺陷：这里
  /// 曾直接返回空列表，导致独立安装时外部智能体页永远扫不到本地已装的
  /// CLI——用户实测 2026-11-19）。本机扫描只做可启动形态探测，不 spawn
  /// 握手（快、无超时风险）。
  Future<List<AcpAgentInfo>> acpAgents({bool probe = false}) async {
    final desktop = _remote;
    if (desktop != null && desktop.isConfigured) {
      final reply = await desktop.call('agent.external.agents', {'probe': probe});
      return ((reply['agents'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => AcpAgentInfo.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    }
    final localAcp = _localAcp;
    if (localAcp == null || !localAcp.supported) return const [];
    final detected = await localAcp.agents(probe: false);
    return [
      for (final a in detected) AcpAgentInfo.fromJson(a.toJson()),
    ];
  }

  Future<Map<String, dynamic>> acpNewSession(String agent, String? cwd) async {
    final desktop = _remote;
    if (desktop == null || !desktop.isConfigured) {
      return {'ok': false, 'error': 'remote_unavailable'};
    }
    return desktop.call('agent.external.session', {'agent': agent, if (cwd != null) 'cwd': cwd});
  }

  /// Streamed external-agent prompt. Event shapes match the built-in loop.
  Stream<Map<String, dynamic>> acpPrompt(String sessionId, String text) {
    final desktop = _remote;
    if (desktop == null || !desktop.isConfigured) {
      return Stream.fromIterable([
        {'type': 'failed', 'error': 'remote_unavailable', 'stopReason': 'failed'},
      ]);
    }
    return desktop.streamCall('agent.external.prompt', {
      'session_id': sessionId,
      'text': text,
    });
  }

  Future<void> acpCancel(String sessionId) async {
    final desktop = _remote;
    if (desktop == null || !desktop.isConfigured) return;
    await desktop.call('agent.external.cancel', {'session_id': sessionId});
  }

  Future<void> acpClose(String sessionId) async {
    final desktop = _remote;
    if (desktop == null || !desktop.isConfigured) return;
    await desktop.call('agent.external.close', {'session_id': sessionId});
  }

  // -------------------------------------------------------------------------
  // 3D / hot-app / video / portfolio (hosted by the local core in later
  // batches; until then they are remote-only and answer honestly)
  // -------------------------------------------------------------------------

  Map<String, dynamic> get _noDesktop => {'ok': false, 'error': 'remote_unavailable'};

  Future<Map<String, dynamic>> _rpc(
    String method, [
    Map<String, dynamic>? params,
    Duration? timeout,
  ]) {
    final desktop = _remote;
    if (desktop == null || !desktop.isConfigured) {
      return Future.value(_noDesktop);
    }
    return desktop.call(method, params, timeout);
  }

  Future<Map<String, dynamic>> threeNewProject({
    required String name,
    required String brief,
    required String model,
    required String baseUrl,
    required String apiKey,
    required String thinkingLevel,
  }) =>
      _rpc(
        'three.project.new',
        {
          'name': name,
          'brief': brief,
          'model': model,
          'base_url': baseUrl,
          'api_key': apiKey,
          'thinking_level': thinkingLevel,
        },
        RemoteDesktopClient.llmGenTimeout,
      );

  Future<Map<String, dynamic>> threeRunPass({
    required String name,
    required String model,
    required String baseUrl,
    required String apiKey,
    required String thinkingLevel,
  }) =>
      _rpc(
        'three.pass',
        {
          'name': name,
          'model': model,
          'base_url': baseUrl,
          'api_key': apiKey,
          'thinking_level': thinkingLevel,
        },
        RemoteDesktopClient.llmGenTimeout,
      );

  Future<Map<String, dynamic>> threeFeedback(String name, String kind, [Object? payload]) =>
      _rpc('three.feedback', {'name': name, 'kind': kind, if (payload != null) 'payload': payload});

  Future<Map<String, dynamic>> threeContinue(String name, [String summary = '']) =>
      _rpc('three.continue', {'name': name, 'summary': summary});

  Future<Map<String, dynamic>> threeProject(String name) => _rpc('three.project', {'name': name});

  Future<Map<String, dynamic>> threeProjects() => _rpc('three.projects');

  /// Asset URL for the 3D preview, or a friendly placeholder page when no
  /// desktop is connected (the workspace gates the entry through the
  /// capability hub long before this point).
  String threePreviewUrl(String name) {
    final desktop = _remote;
    if (desktop == null || !desktop.isConfigured) {
      return _placeholderPage('3D 场景需要先连接桌面');
    }
    return '${desktop.baseUrl}/v1/assets/three/${Uri.encodeQueryComponent(name)}';
  }

  Future<Map<String, dynamic>> hotAppGenerate({
    required String name,
    required String brief,
    required String model,
    required String baseUrl,
    required String apiKey,
  }) =>
      _rpc(
        'hotapp.generate',
        {
          'name': name,
          'brief': brief,
          'model': model,
          'base_url': baseUrl,
          'api_key': apiKey,
        },
        RemoteDesktopClient.llmGenTimeout,
      );

  Future<Map<String, dynamic>> hotAppRefine({
    required String name,
    required String instruction,
    required String model,
    required String baseUrl,
    required String apiKey,
  }) =>
      _rpc(
        'hotapp.refine',
        {
          'name': name,
          'instruction': instruction,
          'model': model,
          'base_url': baseUrl,
          'api_key': apiKey,
        },
        RemoteDesktopClient.llmGenTimeout,
      );

  Future<Map<String, dynamic>> hotAppList() => _rpc('hotapp.list');

  Future<Map<String, dynamic>> hotAppDelete(String name) =>
      _rpc('hotapp.delete', {'name': name});

  String hotAppPageUrl(String name) {
    final desktop = _remote;
    if (desktop == null || !desktop.isConfigured) {
      return _placeholderPage('热应用需要先连接桌面');
    }
    return '${desktop.baseUrl}/v1/assets/hotapp/${Uri.encodeQueryComponent(name)}';
  }

  Future<Map<String, dynamic>> portfolio() => _rpc('portfolio.list');

  Future<Map<String, dynamic>> portfolioDelete(String kind, String ref) =>
      _rpc('portfolio.delete', {'kind': kind, 'ref': ref});

  /// Inline page used when a full-screen feature is opened without a desktop.
  /// Keeps the WebView out of an empty white screen and states the reason.
  static String _placeholderPage(String message) => Uri.dataFromString(
        '<!doctype html><html><head><meta charset="utf-8">'
        '<meta name="color-scheme" content="light dark">'
        '<style>html,body{height:100%;margin:0;display:grid;place-items:center;'
        'font:14px/1.6 -apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif;'
        'color:#8a8f98;background:transparent}</style></head>'
        '<body><p id="m"></p>'
        '<script>document.getElementById("m").textContent=${jsonEncode(message)};</script>'
        '</body></html>',
        mimeType: 'text/html',
        encoding: utf8,
      ).toString();
}
