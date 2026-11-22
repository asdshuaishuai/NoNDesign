/// Wire contract of the optional "连接桌面" desktop host (batch 10).
///
/// The host is a normal Dart `HttpServer` inside the desktop app. It is **off
/// by default**, binds loopback only unless the user explicitly allows phones,
/// and always requires a token. There is no Python service, no fixed port and
/// no port file: the address is `http://<host>:<ephemeral port>` with the token
/// printed in the settings card.
///
/// Faces (the client side lives in `core/remote_desktop_client.dart`):
///
/// ```
/// GET  /v1/health         → {ok, protocol, version, name, uptime_s}
/// GET  /v1/capabilities   → {ok, protocol, version, capabilities:{engine,…}}
/// POST /v1/rpc            → {ok, result:{…}} | {ok:false, error, detail, message}
///      body: {method, params, protocol?}
/// POST /v1/rpc (stream)   → same body; method `agent.run` /
///                           `agent.external.prompt` answer `text/event-stream`
/// GET  /v1/assets/<kind>/<name>?token=…   (3D preview page / hot-app page)
/// ```
///
/// Every request carries `authorization: Bearer <token>` except asset GETs,
/// which may carry `?token=` because a WebView navigation cannot set headers.
///
/// This file is pure Dart (no `dart:io`, no Flutter): the client, the host and
/// the tests all read the same constants, so a drift shows up as a failing
/// contract test rather than a silent mismatch.
library;

import 'dart:convert';

/// Protocol revision implemented by this host.
///
/// Bump only for an incompatible envelope change. Additive methods do not bump
/// it: clients discover them through `/v1/capabilities` and get
/// `unknown_method` when an older host is asked for one.
const int rpcProtocolVersion = 1;

/// Oldest protocol this host still answers. Currently identical to [rpcProtocolVersion].
const int rpcProtocolMinVersion = 1;

/// Host display name (diagnostics; the settings card may show it).
///
/// Not user-facing copy on its own — it appears inside "技术详情".
const String rpcHostName = 'Firelight 桌面宿主';

/// Hard limits, shared with the client documentation.
abstract final class RpcLimits {
  /// Maximum request body (JSON envelope). Larger bodies are rejected with
  /// `413 payload_too_large` before the envelope is parsed.
  ///
  /// 16 MiB covers a full project snapshot plus its documents with room to
  /// spare; project files themselves are capped at 8 MiB by the DDP layer.
  static const int maxBodyBytes = 16 * 1024 * 1024;

  /// Maximum number of simultaneous requests (streams included). The probes
  /// (`/v1/health`, `/v1/capabilities`) are exempt so a busy host still
  /// answers "I am here, wait".
  static const int maxConcurrentRequests = 8;

  /// How long a streaming response may stay silent before the host ends it
  /// with a terminal `failed` event.
  ///
  /// This is an **idle** budget, not a total-duration cap: a long generation
  /// that keeps producing events is never cut. The client's own idle budget
  /// (`RemoteDesktopClient.sseIdleTimeout`, 660 s) is a backstop; the host
  /// fires first so the phone always receives an explanation instead of a
  /// dead socket.
  static const Duration streamIdleTimeout = Duration(seconds: 600);

  /// How often a streaming reply writes an SSE comment (`: ping`) so a dead
  /// peer is noticed by the next write. The comment is framing noise for
  /// clients and must never reset the idle budget above.
  static const Duration keepAliveInterval = Duration(seconds: 20);

  /// Socket idle timeout for non-streaming connections.
  static const Duration connectionIdleTimeout = Duration(minutes: 5);
}

/// Machine error codes produced by the host transport.
///
/// Domain errors (engine, project, 3D, …) travel unchanged inside the
/// `result` envelope, so the app's existing copy mapping keeps working. Codes
/// in this class describe *the connection itself*.
abstract final class RpcErrorCode {
  /// Missing or wrong token.
  static const String unauthorized = 'unauthorized';

  /// Unknown path.
  static const String notFound = 'not_found';

  /// Wrong HTTP verb for a known path.
  static const String methodNotAllowed = 'method_not_allowed';

  /// Body larger than [RpcLimits.maxBodyBytes].
  static const String payloadTooLarge = 'payload_too_large';

  /// Too many in-flight requests.
  static const String busy = 'busy';

  /// Body is not valid UTF-8 JSON in the envelope shape.
  static const String badRequest = 'bad_request';

  /// Envelope parsed but a required parameter is missing/ill-typed.
  static const String invalidParams = 'invalid_params';

  /// Method not in the table.
  static const String unknownMethod = 'unknown_method';

  /// Client announced a protocol this host cannot speak.
  static const String unsupportedProtocol = 'unsupported_protocol';

  /// Handler threw. The detail is diagnostic only.
  static const String internal = 'internal_error';

  /// Streaming response stayed silent past [RpcLimits.streamIdleTimeout].
  static const String streamIdle = 'stream_idle_timeout';
}

/// User-facing sentences for transport failures.
///
/// Copy rules (`docs/copy-glossary.md`): plain speech, no ports, no protocol
/// names, no bare error codes. Raw details belong in the collapsed "技术详情".
abstract final class RpcCopy {
  static const String unauthorized = '连接码不正确，请在桌面端重新获取';
  static const String notFound = '桌面端没有这个功能，请更新后再试';
  static const String methodNotAllowed = '桌面端没有这个功能，请更新后再试';
  static const String payloadTooLarge = '这次同步的内容太大，请分几次保存';
  static const String busy = '桌面端正忙，请稍后再试';
  static const String badRequest = '桌面端没能读懂这次请求，请重试';
  static const String invalidParams = '这次请求缺少必要内容，请重试';
  static const String unknownMethod = '桌面端还不支持这个操作，请更新桌面端';
  static const String unsupportedProtocol = '桌面端和这台设备的版本不匹配，请更新桌面端';
  static const String internal = '桌面端暂时出了点问题，请稍后重试';
  static const String streamIdle = '桌面端长时间没有回应，请重试';

  /// Sentence for an arbitrary code: known transport codes map, everything
  /// else falls back to a neutral sentence (the raw code stays in `detail`).
  static String forCode(String code) => switch (code) {
    RpcErrorCode.unauthorized => unauthorized,
    RpcErrorCode.notFound => notFound,
    RpcErrorCode.methodNotAllowed => methodNotAllowed,
    RpcErrorCode.payloadTooLarge => payloadTooLarge,
    RpcErrorCode.busy => busy,
    RpcErrorCode.badRequest => badRequest,
    RpcErrorCode.invalidParams => invalidParams,
    RpcErrorCode.unknownMethod => unknownMethod,
    RpcErrorCode.unsupportedProtocol => unsupportedProtocol,
    RpcErrorCode.internal => internal,
    RpcErrorCode.streamIdle => streamIdle,
    _ => '桌面端没有完成这个操作，请稍后重试',
  };
}

/// Canonical method names. One source of truth for the host table, the client
/// and the coverage test.
abstract final class RpcMethod {
  // --- probe faces (also available over GET) ---
  static const String health = 'health';
  static const String capabilities = 'capabilities';

  // --- engine (HumanGate / AgentGate stay on the engine side) ---
  static const String engineRender = 'engine.render';
  static const String engineValidate = 'engine.validate';
  static const String engineApply = 'engine.apply';
  static const String engineSession = 'engine.session';
  static const String engineGenerate = 'engine.generate';
  static const String engineTap = 'engine.tap';
  static const String engineConstrain = 'engine.constrain';
  static const String engineEvent = 'engine.event';
  static const String engineHistory = 'engine.history';
  static const String engineExportHtml = 'engine.exportHtml';
  static const String engineTokens = 'engine.tokens';
  static const String engineVersion = 'engine.version';
  static const String engineTemplates = 'engine.templates';
  static const String engineComponents = 'engine.components';
  static const String engineThemes = 'engine.themes';
  static const String engineOps = 'engine.ops';
  static const String engineStats = 'engine.stats';
  static const String engineRecycle = 'engine.recycle';

  // --- project library (DDP read/write stays client-side or here) ---
  static const String projectSave = 'project.save';
  static const String projectOpen = 'project.open';
  static const String projectList = 'project.list';
  static const String projectExportFigma = 'project.exportFigma';

  // --- built-in agent (stream) ---
  static const String agentRun = 'agent.run';
  static const String agentCancel = 'agent.cancel';
  static const String agentSessionClear = 'agent.session.clear';

  // --- external agents (desktop only) ---
  static const String externalAgents = 'agent.external.agents';
  static const String externalSession = 'agent.external.session';
  static const String externalPrompt = 'agent.external.prompt';
  static const String externalCancel = 'agent.external.cancel';
  static const String externalClose = 'agent.external.close';
  static const String externalPermission = 'agent.external.permission';

  // --- 3D ---
  static const String threeProjects = 'three.projects';
  static const String threeProject = 'three.project';
  static const String threeProjectNew = 'three.project.new';
  static const String threePass = 'three.pass';
  static const String threeFeedback = 'three.feedback';
  static const String threeContinue = 'three.continue';
  static const String threeSpec = 'three.spec';
  static const String threeDelete = 'three.delete';
  static const String threePreview = 'three.preview';

  // --- hot apps / .nonapp ---
  static const String hotAppList = 'hotapp.list';
  static const String hotAppRead = 'hotapp.read';
  static const String hotAppGenerate = 'hotapp.generate';
  static const String hotAppRefine = 'hotapp.refine';
  static const String hotAppInspect = 'hotapp.inspect';
  static const String hotAppDelete = 'hotapp.delete';
  static const String hotAppExport = 'hotapp.export';

  static const String nonAppList = 'nonapp.list';
  static const String nonAppInspect = 'nonapp.inspect';
  static const String nonAppExport = 'nonapp.export';
  static const String nonAppDelete = 'nonapp.delete';

  // --- video ---
  static const String videoReview = 'video.review';
  static const String videoRender = 'video.render';
  static const String videoJobs = 'video.jobs';
  static const String videoJob = 'video.job';
  static const String videoCancel = 'video.cancel';
  static const String videoSamples = 'video.samples';
  static const String videoSample = 'video.sample';

  // --- portfolio (shelf aggregation) ---
  static const String portfolioList = 'portfolio.list';
  static const String portfolioDelete = 'portfolio.delete';

  // --- model snapshot (bundled, never fetched at runtime) ---
  static const String modelsSnapshot = 'models.snapshot';
  static const String modelsRefresh = 'models.refresh';

  /// Every canonical method the host implements.
  static const List<String> all = <String>[
    health,
    capabilities,
    engineRender,
    engineValidate,
    engineApply,
    engineSession,
    engineGenerate,
    engineTap,
    engineConstrain,
    engineEvent,
    engineHistory,
    engineExportHtml,
    engineTokens,
    engineVersion,
    engineTemplates,
    engineComponents,
    engineThemes,
    engineOps,
    engineStats,
    engineRecycle,
    projectSave,
    projectOpen,
    projectList,
    projectExportFigma,
    agentRun,
    agentCancel,
    agentSessionClear,
    externalAgents,
    externalSession,
    externalPrompt,
    externalCancel,
    externalClose,
    externalPermission,
    threeProjects,
    threeProject,
    threeProjectNew,
    threePass,
    threeFeedback,
    threeContinue,
    threeSpec,
    threeDelete,
    threePreview,
    hotAppList,
    hotAppRead,
    hotAppGenerate,
    hotAppRefine,
    hotAppInspect,
    hotAppDelete,
    hotAppExport,
    nonAppList,
    nonAppInspect,
    nonAppExport,
    nonAppDelete,
    videoReview,
    videoRender,
    videoJobs,
    videoJob,
    videoCancel,
    videoSamples,
    videoSample,
    portfolioList,
    portfolioDelete,
    modelsSnapshot,
    modelsRefresh,
  ];

  /// Methods that answer `text/event-stream` instead of one JSON document.
  static const Set<String> streaming = <String>{agentRun, externalPrompt};

  /// Short aliases kept because the batch brief names the external-agent face
  /// `acp.*`. Both spellings route to the same handler; the client uses
  /// `agent.external.*` (pinned by `remote_rpc_contract_test.dart`).
  static const Map<String, String> aliases = <String, String>{
    'acp.agents': externalAgents,
    'acp.session': externalSession,
    'acp.prompt': externalPrompt,
    'acp.cancel': externalCancel,
    'acp.close': externalClose,
    'acp.permission': externalPermission,
  };

  /// Resolves an alias to its canonical name; unknown names pass through.
  static String canonical(String method) => aliases[method] ?? method;
}

/// One parsed `/v1/rpc` envelope.
class RpcRequest {
  const RpcRequest({required this.method, this.params = const {}, this.protocol});

  final String method;
  final Map<String, dynamic> params;

  /// Protocol announced by the caller; null means "assume 1".
  final int? protocol;

  /// Parses a decoded JSON body. Returns a record with either a request or a
  /// transport error (code + diagnostic detail).
  static ({RpcRequest? request, String? error, String? detail}) parse(Object? body) {
    if (body is! Map) {
      return (request: null, error: RpcErrorCode.badRequest, detail: 'body is not a JSON object');
    }
    final map = Map<String, dynamic>.from(body);
    final rawMethod = map['method'];
    if (rawMethod is! String || rawMethod.trim().isEmpty) {
      return (request: null, error: RpcErrorCode.badRequest, detail: 'missing method');
    }
    final rawParams = map['params'];
    Map<String, dynamic> params;
    if (rawParams == null) {
      params = <String, dynamic>{};
    } else if (rawParams is Map) {
      params = Map<String, dynamic>.from(rawParams);
    } else {
      return (request: null, error: RpcErrorCode.badRequest, detail: 'params must be an object');
    }
    final rawProtocol = map['protocol'];
    int? protocol;
    if (rawProtocol is num) {
      protocol = rawProtocol.toInt();
    } else if (rawProtocol is String) {
      protocol = int.tryParse(rawProtocol);
    }
    return (
      request: RpcRequest(method: rawMethod.trim(), params: params, protocol: protocol),
      error: null,
      detail: null,
    );
  }

  @override
  String toString() => 'RpcRequest($method, protocol:$protocol)';
}

/// Success envelope used by `/v1/rpc`.
Map<String, dynamic> rpcOk(Map<String, dynamic> result) =>
    <String, dynamic>{'ok': true, 'result': result};

/// Failure envelope used by `/v1/rpc` and the JSON faces.
///
/// [message] is the user-facing sentence; [detail] is diagnostic only.
Map<String, dynamic> rpcFailure(
  String code, {
  String? detail,
  String? message,
  bool includeMessage = false,
}) =>
    <String, dynamic>{
      'ok': false,
      'error': code,
      'detail': ?detail,
      if (includeMessage) 'message': message ?? RpcCopy.forCode(code),
    };

/// Whether [protocol] is a revision this host can serve. Null (unspecified)
/// is treated as the current revision.
bool rpcProtocolSupported(int? protocol) {
  if (protocol == null) return true;
  return protocol >= rpcProtocolMinVersion && protocol <= rpcProtocolVersion;
}

/// One SSE frame.
String encodeSseEvent(Map<String, dynamic> event) => 'data: ${jsonEncode(event)}\n\n';

/// Terminal events end a stream. Mirrors the client's rule.
bool isTerminalEvent(Map<String, dynamic> event) {
  final type = event['type'];
  return type == 'done' || type == 'failed';
}
