/// Domain facade over the in-process engine (batch 02).
///
/// This is the drop-in replacement for the HTTP engine faces of
/// `NoNDesignApi` (`render` / `validate` / `apply` / `session` / `generate` /
/// `constrainIntent` / `event` / `history` / `exportHtml` / `templates` /
/// `components`): same method names, same envelope shapes, so the store and
/// the Dart agent loop can switch runtime without touching their call sites
/// (batch 05 owns that wiring).
///
/// Design rules:
///
///  * every call returns an engine envelope; transport failures become
///    `{ok: false, error: 'engine_unavailable', detail: …}` — never an
///    exception, never a silent `null`;
///  * the raw `detail` is diagnostic only (collapsed "技术详情"); user copy is
///    derived from `error` by the copy layer;
///  * the service is inert when the host failed to start (`isReady == false`),
///    and [probeAvailability] tells the capability hub exactly why.
library;

// The backend factory is a closure supplied by `start`/`startAuto`; a private
// named parameter (`this._backendFactory`) would leak into call syntax.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;

import '../capability.dart';
import 'engine_backend.dart';
import 'engine_host.dart';
import 'engine_types.dart';
import 'webview_engine_host.dart';

/// Engine facade for one application process.
class EngineService {
  EngineService._(
    this._host,
    this._componentsSnapshot,
    this._startupError, {
    // Named differently from the private field on purpose: this is a factory,
    // not a value callers pass through, and a private named parameter would
    // leak into the invocation syntax.
    Future<EngineBackend> Function()? backendFactory,
  }) : _backendFactory = backendFactory;

  /// Builds a service over [host] (or over nothing when startup failed).
  factory EngineService(
    EngineBackend? host, {
    List<dynamic>? componentsSnapshot,
    String? startupError,
  }) =>
      EngineService._(host, componentsSnapshot, startupError);

  EngineBackend? _host;
  final List<dynamic>? _componentsSnapshot;
  String? _startupError;
  bool _disposed = false;

  /// Re-creates the same backend kind after a failed first start. `null` for
  /// services built in tests over a supplied host.
  final Future<EngineBackend> Function()? _backendFactory;
  Future<bool>? _retryFuture;

  /// Starts a real host from the bundled artifact bytes.
  ///
  /// A failure to start does **not** throw: the returned service answers
  /// `engine_unavailable` and the app keeps working through "连接桌面" (with an
  /// explicit, human message — no silent degradation). The bytes/options are
  /// retained, so [retryEngine] can bring the engine up once the cause is
  /// fixed without restarting the app.
  static Future<EngineService> start({
    required Uint8List wasmBytes,
    EngineHostOptions options = const EngineHostOptions(),
    List<dynamic>? componentsSnapshot,
  }) async {
    Future<EngineBackend> factory() => EngineHost.start(wasmBytes: wasmBytes, options: options);
    try {
      final host = await factory();
      return EngineService._(
        host,
        componentsSnapshot,
        null,
        backendFactory: factory,
      );
    } catch (error) {
      return EngineService._(
        null,
        componentsSnapshot,
        '$error',
        backendFactory: factory,
      );
    }
  }

  /// Starts the full-platform engine: classic wasm in an offscreen WebView.
  ///
  /// The WebView host is the production path on every app target. If the host
  /// cannot be created — no WebView, missing WebKitGTK, a corrupted artifact —
  /// the service falls back to the native `wasm_run` host so the app still
  /// opens; the failure is logged with its real reason and `runtime` exposes
  /// which path won. Tests should keep using [start] (pure Dart, no display).
  static Future<EngineService> startAuto({
    required Uint8List wasmBytes,
    EngineHostOptions options = const EngineHostOptions(),
    List<dynamic>? componentsSnapshot,
    bool preferWebView = true,
  }) async {
    if (!preferWebView || kIsWeb) {
      return start(
        wasmBytes: wasmBytes,
        options: options,
        componentsSnapshot: componentsSnapshot,
      );
    }
    Future<EngineBackend> webFactory() =>
        WebViewEngineHost.start(wasmBytes: wasmBytes, options: options);
    try {
      final host = await webFactory();
      return EngineService._(
        host,
        componentsSnapshot,
        null,
        backendFactory: webFactory,
      );
    } catch (error) {
      options.onLog?.call(
        '[engine] WebView host unavailable ($error); falling back to wasm_run',
      );
      // Fall back to the native host, but keep the native factory for retries.
      return start(
        wasmBytes: wasmBytes,
        options: options,
        componentsSnapshot: componentsSnapshot,
      );
    }
  }

  /// Wraps an existing host (tests, or a host the caller already owns).
  static EngineService withHost(EngineBackend host, {List<dynamic>? componentsSnapshot}) =>
      EngineService(host, componentsSnapshot: componentsSnapshot);

  /// A service that is known to be unavailable, with the reason preserved.
  static EngineService unavailable(String reason) =>
      EngineService(null, startupError: reason);

  /// True when the engine can serve calls.
  bool get isReady {
    final host = _host;
    return !_disposed && host != null && host.isReady;
  }

  /// Diagnostic reason when [isReady] is false. A live host owns the truth
  /// (it can recover through [retryEngine]); the constructor value only
  /// describes a host that never started.
  String? get startupError => _host?.startupError ?? _startupError;

  /// Executor + artifact facts once started.
  EngineRuntimeInfo? get runtime => _host?.runtime;

  /// Worker respawn count (watchdog kills and crashes).
  int get restartCount => _host?.restartCount ?? 0;

  /// Snapshot for the capability hub (`CapabilityId.localDesignEngine`).
  CapabilityAvailability probeAvailability() {
    if (isReady) {
      return CapabilityAvailability.available(
        CapabilityId.localDesignEngine,
        technicalDetail: '${runtime ?? ''}',
      );
    }
    return CapabilityAvailability.unavailable(
      CapabilityId.localDesignEngine,
      technicalDetail: startupError,
    );
  }

  Map<String, dynamic> _unavailable() => <String, dynamic>{
        'ok': false,
        'error': EngineErrorCode.unavailable,
        'detail': startupError ?? 'engine is not running',
      };

  // -------------------------------------------------------------------------
  // Document face
  // -------------------------------------------------------------------------

  /// Renders a canonical document (`render_mbt_in`).
  Future<Map<String, dynamic>> render(String mbt) async {
    final host = _host;
    if (host == null || !isReady) return _unavailable();
    return host.render(mbt);
  }

  /// Validates without committing (`validate_mbt_in`).
  Future<Map<String, dynamic>> validate(String mbt) async {
    final host = _host;
    if (host == null || !isReady) return _unavailable();
    return host.validate(mbt);
  }

  /// Applies one op. `gate` is `'human'` (canvas) or `'agent'` (agent loop) —
  /// they are different engine doors; never route agent work through the
  /// human gate.
  Future<Map<String, dynamic>> apply(String mbt, String op, {String gate = 'human'}) async {
    final host = _host;
    if (host == null || !isReady) return _unavailable();
    return host.apply(mbt, op, gate: gate);
  }

  /// One session inspection/mutation call (`session_*`).
  Future<Map<String, dynamic>> session(String mbt, String name, [String? arg]) async {
    final host = _host;
    if (host == null || !isReady) return _unavailable();
    return host.session(mbt, name, arg);
  }

  /// Full-page generation (`session_generate_in`): spec JSON in the `in` slot,
  /// intent in `arg`, artboard name in `arg2`.
  Future<Map<String, dynamic>> generate(
    String mbt,
    String intent,
    String name,
    Map<String, dynamic> spec,
  ) async {
    final host = _host;
    if (host == null || !isReady) return _unavailable();
    return host.generate(mbt, intent, name, spec);
  }

  /// Tap routing (`session_tap_in`) — the play view's primary gesture.
  Future<Map<String, dynamic>> tap(String mbt, String artboard, double x, double y) async {
    final host = _host;
    if (host == null || !isReady) return _unavailable();
    return host.tap(mbt, artboard, x, y);
  }

  /// Layout intent (`session_constrain_in`: arg=artboard, arg2=intent).
  Future<Map<String, dynamic>> constrainIntent(String mbt, String artboard, String intent) async {
    final host = _host;
    if (host == null || !isReady) return _unavailable();
    return host.constrain(mbt, artboard, intent);
  }

  /// Demo gesture (`session_event_in`: in=token, arg=artboard).
  Future<Map<String, dynamic>> event(String mbt, String artboard, String spec) async {
    final host = _host;
    if (host == null || !isReady) return _unavailable();
    return host.event(mbt, artboard, spec);
  }

  /// Engine history (`session_history_in`): `init <board>`, `commit`, `log`,
  /// `undo`, `redo`, `diff <from> <to>`.
  Future<Map<String, dynamic>> history(String mbt, String command) =>
      session(mbt, 'session_history', command);

  /// Self-contained HTML export (`export_html_in`).
  Future<Map<String, dynamic>> exportHtml(String mbt) async {
    final host = _host;
    if (host == null || !isReady) return _unavailable();
    return host.exportHtml(mbt);
  }

  // -------------------------------------------------------------------------
  // Registries
  // -------------------------------------------------------------------------

  Future<List<dynamic>> _listing(String fn) async {
    final host = _host;
    if (host == null || !isReady) return const <dynamic>[];
    final envelope = await host.listing(fn);
    if (envelope['ok'] != true) return const <dynamic>[];
    final data = envelope['data'];
    if (data is List) return data;
    return const <dynamic>[];
  }

  /// Page templates (17 on engine 0.2-dev), live from the engine.
  Future<List<dynamic>> templates() => _listing('list_templates');

  /// Live component registry (65 on engine 0.2-dev).
  Future<List<dynamic>> liveComponents() => _listing('list_components');

  /// Components for the agent/UI: the verified `components.json` snapshot when
  /// one was injected (same choice the Python host makes), else the live
  /// registry.
  Future<List<dynamic>> components() async {
    final snapshot = _componentsSnapshot;
    if (snapshot != null && snapshot.isNotEmpty) return snapshot;
    return liveComponents();
  }

  /// Theme presets (13 on engine 0.2-dev).
  Future<List<dynamic>> themes() => _listing('list_themes');

  /// Mutating ops registry (`list_ops`, 27 on engine 0.2-dev).
  Future<List<dynamic>> ops() => _listing('list_ops');

  /// Design tokens (`list_tokens`).
  Future<Map<String, dynamic>> tokens() async {
    final host = _host;
    if (host == null || !isReady) return _unavailable();
    return host.listing('list_tokens');
  }

  /// Engine `version_info`.
  Future<Map<String, dynamic>> versionInfo() async {
    final host = _host;
    if (host == null || !isReady) return _unavailable();
    return host.version();
  }

  // -------------------------------------------------------------------------
  // Diagnostics / lifecycle
  // -------------------------------------------------------------------------

  /// Memory / generation / trap / session-cache counters.
  Future<EngineStats> stats() async => _host?.stats() ?? Future.value(EngineStats.empty);

  /// Forces an instance rebuild (memory released, session evicted).
  Future<EngineStats> recycle() async => _host?.recycle() ?? Future.value(EngineStats.empty);

  /// Retries a failed startup (e.g. after the user fixed a missing file).
  ///
  /// A live host recovers through its own restart path. A service whose
  /// *first* start failed keeps the artifact bytes and the backend factory, so
  /// this re-runs the same kind of host instead of returning false forever.
  Future<bool> retryEngine() async {
    if (_disposed) return false;
    final host = _host;
    if (host != null) return host.retry();
    final pending = _retryFuture;
    if (pending != null) return pending;
    final factory = _backendFactory;
    if (factory == null) return false;
    final future = _retryStart(factory);
    _retryFuture = future;
    try {
      return await future;
    } finally {
      _retryFuture = null;
    }
  }

  Future<bool> _retryStart(Future<EngineBackend> Function() factory) async {
    try {
      final host = await factory();
      if (_disposed) {
        await host.dispose();
        return false;
      }
      _host = host;
      _startupError = null;
      return host.isReady;
    } catch (error) {
      _startupError = '$error';
      return false;
    }
  }

  /// Stops the worker.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _host?.dispose();
  }
}
