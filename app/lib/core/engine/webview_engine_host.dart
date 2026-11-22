/// Classic-wasm engine host running in an offscreen WebView.
///
/// Why this exists: the engine's **classic** artifact is pure WASM MVP with
/// zero imports, so every WebView we target can run it — WKWebView (JSC),
/// WebView2 (V8), WebKitGTK (JSC) and Android WebView (V8). That removes the
/// native wasm runtime split (wasmtime on desktop, wasmi on iOS, a custom
/// Windows DLL) and the per-platform dynamic-library/build-hook problems that
/// came with it.
///
/// The engine's other artifact (wasm-gc + JS String Builtins) is smaller, but
/// it requires Chrome 119+/Safari 18.2+; the classic artifact is the only
/// baseline that also covers older WebViews. wasm-gc stays a future fast path,
/// not the full-platform contract.
///
/// The JS host is `assets/engine/engine_web_host.js` — the same file
/// `scripts/engine_web_probe.mjs` runs under Node. Dart only moves canonical
/// text and JSON envelopes; it never interprets the engine's semantics.
///
/// Isolation: a WebView JS call cannot be interrupted from Dart, but it runs
/// in the platform web process, not on the Flutter UI isolate. The watchdog
/// destroys the offscreen session and boots a fresh one, which is stronger
/// than the native host's isolate kill (that cannot unwind a native frame).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show rootBundle;
import 'package:webview_all/webview_all.dart';
import 'package:webview_all_wkwebview/webview_all_wkwebview.dart';

import 'engine_backend.dart';
import 'engine_host.dart' show EngineHostOptions, EngineStartupException;
import 'engine_types.dart';

/// Host script asset; also the Node probe's subject.
const String kEngineWebHostAsset = 'assets/engine/engine_web_host.js';

/// One engine call's cross-boundary payload is split into base64 chunks of
/// this many raw bytes (≈256 KiB of base64 text per `runJavaScript` call).
const int _kWasmChunkBytes = 192 * 1024;

class WebViewEngineHost implements EngineBackend {
  WebViewEngineHost._(this._wasmBytes, this._options, this._hostScript);

  final Uint8List _wasmBytes;
  final EngineHostOptions _options;
  final String _hostScript;

  OffscreenWebViewSession? _session;
  WebViewController? _controller;
  EngineRuntimeInfo? _runtime;
  String? _startupError;
  bool _ready = false;
  bool _disposed = false;
  int _restartCount = 0;

  Future<void> _tail = Future<void>.value();
  Future<void>? _restartFuture;

  /// Brings up an offscreen WebView and boots the engine.
  ///
  /// Throws [EngineStartupException] when the platform has no WebView, the
  /// offscreen session cannot be created, the JS host asset is missing, or the
  /// artifact fails its ABI probe. The caller maps that to
  /// `engine_unavailable`, never to a silent null.
  static Future<WebViewEngineHost> start({
    required Uint8List wasmBytes,
    EngineHostOptions options = const EngineHostOptions(),
    String? hostScript,
  }) async {
    final script = hostScript ?? await rootBundle.loadString(kEngineWebHostAsset);
    final host = WebViewEngineHost._(wasmBytes, options, script);
    try {
      await host._boot();
    } catch (error) {
      await host._closeSession();
      throw EngineStartupException('$error');
    }
    return host;
  }

  @override
  EngineRuntimeInfo? get runtime => _runtime;

  @override
  String? get startupError => _startupError;

  @override
  int get restartCount => _restartCount;

  @override
  bool get isReady => !_disposed && _ready && _controller != null;

  void _log(String message) => _options.onLog?.call('[webview-engine] $message');

  Map<String, dynamic> _failure(String code, String detail) =>
      <String, dynamic>{'ok': false, 'error': code, 'detail': detail};

  // -------------------------------------------------------------------------
  // Boot / lifecycle
  // -------------------------------------------------------------------------

  Future<void> _boot() async {
    _ready = false;
    _startupError = null;
    if (_disposed) throw StateError('engine host disposed');

    if (WebViewPlatform.instance == null && !kIsWeb && (Platform.isMacOS || Platform.isIOS)) {
      // The generated plugin registrant normally does this; the fallback keeps
      // `flutter run` and integration tests from depending on registration
      // order (same reason the 3D/video surfaces keep a guard).
      WebKitWebViewPlatform.registerWith();
    }
    final platform = WebViewPlatform.instance;
    if (platform == null) {
      throw const EngineStartupException('no WebView platform is registered');
    }
    if (!platform.supportsOffscreenWebViews) {
      throw const EngineStartupException('offscreen WebView is not supported on this platform');
    }

    _log('creating offscreen WebView session');
    final session = await OffscreenWebViewSession.create();
    final controller = session.controller;
    _session = session;
    _controller = controller;
    try {
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      try {
        // Cosmetic only (the session is offscreen); a platform that cannot set
        // it must not take the whole engine down.
        await controller.setBackgroundColor(const Color(0x00000000));
      } catch (_) {}
      await controller.loadHtmlString(_html);
      await _waitUntil(() async {
        final value = await _evalRaw('typeof __ndEngine');
        return value == 'object';
      }, _options.startTimeout, 'JS host did not start');

      var offset = 0;
      while (offset < _wasmBytes.length) {
        final end = (offset + _kWasmChunkBytes).clamp(0, _wasmBytes.length);
        final chunk = base64Encode(_wasmBytes.sublist(offset, end));
        final result = await _evalRaw('__ndEngine.wasmChunk("$chunk")');
        if (result != 'ok') {
          throw EngineStartupException('wasm chunk rejected: $result');
        }
        offset = end;
      }
      await _evalRaw('__ndEngine.boot()');

      Map<String, dynamic> status = const <String, dynamic>{};
      await _waitUntil(() async {
        status = _asMap(await _evalJson('__ndEngine.status()'));
        if (status['status'] == 'error') {
          throw EngineStartupException('${status['error'] ?? 'engine boot failed'}');
        }
        return status['status'] == 'ready';
      }, _options.startTimeout, 'engine boot timed out');
      if (status['status'] != 'ready') {
        throw EngineStartupException('${status['error'] ?? 'engine boot failed'}');
      }

      final info = _asMap(await _evalJson('__ndEngine.info()'));
      final exports = (info['exports'] as List?)?.length ?? 0;
      final sessionExports = (info['sessionExports'] as List?)?.length ?? 0;
      if (exports == 0 || sessionExports == 0) {
        throw EngineStartupException('artifact exports are empty');
      }
      _runtime = EngineRuntimeInfo(
        runtime: 'webview',
        runtimeVersion: '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
        engineVersion: '${info['engineVersion'] ?? 'unknown'}',
        fuelSupported: false,
        exportCount: exports,
        sessionExportCount: sessionExports,
        fuelPerCall: _options.core.fuelPerCall,
        fuelPerByte: _options.core.fuelPerByte,
      );
      _startupError = null;
      _ready = true;
      _log('engine ready: $_runtime');
    } catch (error) {
      _ready = false;
      await _closeSession();
      rethrow;
    }
  }

  String get _html {
    // Single inline script: no network, no modules, no external files. The CSP
    // permits only the inline host and wasm compilation; the page cannot reach
    // the network even if a document tries to.
    final script = _hostScript.replaceAll('</script', r'<\/script');
    return '<!doctype html><html><head><meta charset="utf-8">'
        '<meta http-equiv="Content-Security-Policy" content="default-src \'none\'; '
        'script-src \'unsafe-inline\' \'wasm-unsafe-eval\'; style-src \'unsafe-inline\'; '
        'img-src data:; connect-src \'none\'">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        '<style>html,body{margin:0;padding:0;background:transparent;overflow:hidden}</style>'
        '</head><body><script>$script</script></body></html>';
  }

  Future<void> _waitUntil(
    Future<bool> Function() predicate,
    Duration timeout,
    String message,
  ) async {
    final deadline = DateTime.now().add(timeout);
    Object? lastError;
    while (DateTime.now().isBefore(deadline)) {
      try {
        if (await predicate()) return;
      } catch (error) {
        lastError = error;
        if (error is EngineStartupException) rethrow;
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    throw EngineStartupException(
      lastError == null ? message : '$message: $lastError',
    );
  }

  Future<void> _closeSession() async {
    final session = _session;
    _session = null;
    _controller = null;
    _ready = false;
    if (session == null) return;
    try {
      await session.close().timeout(const Duration(seconds: 5));
    } catch (error) {
      _log('closing offscreen session failed: $error');
    }
  }

  @override
  Future<bool> retry() async {
    if (_disposed) return false;
    _startupError = null;
    await _restart('manual retry');
    return isReady;
  }

  Future<void> _restart(String reason) {
    final existing = _restartFuture;
    if (existing != null) return existing;
    final future = _doRestart(reason).whenComplete(() => _restartFuture = null);
    _restartFuture = future;
    return future;
  }

  Future<void> _doRestart(String reason) async {
    _restartCount++;
    _log('restarting engine WebView: $reason');
    await _closeSession();
    if (_disposed) return;
    try {
      await _boot();
    } catch (error) {
      _startupError = '$error';
      _log('engine restart failed: $error');
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _ready = false;
    await _closeSession();
  }

  // -------------------------------------------------------------------------
  // Bridge primitives
  // -------------------------------------------------------------------------

  Future<Object?> _evalRaw(String script) async {
    final controller = _controller;
    if (controller == null) throw StateError('engine WebView is not running');
    final result = await controller.runJavaScriptReturningResult(script);
    if (result is String && result.length >= 2 && result.startsWith('"') && result.endsWith('"')) {
      // Some platform wrappers hand back a JSON-encoded string instead of the
      // plain value. Decode exactly once so callers always see the raw text.
      try {
        final decoded = jsonDecode(result);
        if (decoded is String) return decoded;
      } catch (_) {
        // Not double-encoded; return the original string.
      }
    }
    return result;
  }

  Future<Object?> _evalJson(String script) async {
    final value = await _evalRaw(script);
    if (value is String) return jsonDecode(value);
    if (value is Map || value is List) return value;
    return jsonDecode(jsonEncode(value));
  }

  static Map<String, dynamic> _asMap(Object? value) {
    if (value is Map) return Map<String, dynamic>.from(value);
    return <String, dynamic>{'ok': false, 'error': EngineErrorCode.nonJson, 'detail': '$value'};
  }

  /// Serialises one bridge call behind the queue and applies the watchdog.
  Future<Map<String, dynamic>> _envelope(String script, {String? errorCode}) {
    return _enqueue(() async {
      if (_disposed) return _failure(EngineErrorCode.unavailable, 'engine host disposed');
      if (!isReady) {
        return _failure(EngineErrorCode.unavailable, _startupError ?? 'engine is not running');
      }
      try {
        final value = await _evalJson(script).timeout(_options.callTimeout);
        return _asMap(value);
      } on TimeoutException {
        await _restart('engine call timed out');
        return _failure(EngineErrorCode.timeout, 'engine call timed out');
      } catch (error) {
        // The JS host converts engine traps into JSON envelopes, so anything
        // thrown here is a transport/protocol failure (page reload, WebView
        // process death, malformed result). Rebuild the session before the
        // next call instead of leaving a half-dead bridge behind.
        await _restart('bridge error: $error');
        return _failure(errorCode ?? EngineErrorCode.trap, '$error');
      }
    });
  }

  /// Like [_envelope], but keeps the raw JSON shape (listing returns an array,
  /// stats/recycle return a stats object). A failure still comes back as a map.
  Future<Object?> _rawCall(String script) {
    return _enqueue(() async {
      if (_disposed) return _failure(EngineErrorCode.unavailable, 'engine host disposed');
      if (!isReady) {
        return _failure(EngineErrorCode.unavailable, _startupError ?? 'engine is not running');
      }
      try {
        return await _evalJson(script).timeout(_options.callTimeout);
      } on TimeoutException {
        await _restart('engine call timed out');
        return _failure(EngineErrorCode.timeout, 'engine call timed out');
      } catch (error) {
        await _restart('bridge error: $error');
        return _failure(EngineErrorCode.trap, '$error');
      }
    });
  }

  Future<T> _enqueue<T>(Future<T> Function() task) {
    final runner = _tail.then((_) => task());
    _tail = runner.then<void>((_) {}, onError: (Object _) {});
    return runner;
  }

  static String _b64(String text) => base64Encode(utf8.encode(text));

  // -------------------------------------------------------------------------
  // Document face
  // -------------------------------------------------------------------------

  @override
  Future<Map<String, dynamic>> render(String mbt) =>
      _envelope('__ndEngine.render("${_b64(mbt)}")', errorCode: EngineErrorCode.trap);

  @override
  Future<Map<String, dynamic>> validate(String mbt) =>
      _envelope('__ndEngine.validate("${_b64(mbt)}")', errorCode: EngineErrorCode.trap);

  @override
  Future<Map<String, dynamic>> apply(String mbt, String op, {String gate = 'human'}) =>
      _envelope('__ndEngine.apply("${_b64(mbt)}","${_b64(op)}","${gate == 'agent' ? 'agent' : 'human'}")');

  @override
  Future<Map<String, dynamic>> exportHtml(String mbt) =>
      _envelope('__ndEngine.exportHtml("${_b64(mbt)}")');

  // -------------------------------------------------------------------------
  // Session face
  // -------------------------------------------------------------------------

  @override
  Future<Map<String, dynamic>> session(String mbt, String name, [String? arg]) =>
      _envelope(
        '__ndEngine.session("${_b64(mbt)}","${_b64(name)}","${_b64(arg ?? '')}")',
        errorCode: EngineErrorCode.sessionFailed,
      );

  @override
  Future<Map<String, dynamic>> generate(
    String mbt,
    String intent,
    String name,
    Object? spec,
  ) {
    final specText = spec is String ? spec : jsonEncode(spec ?? const <String, dynamic>{});
    return _envelope(
      '__ndEngine.generate("${_b64(mbt)}","${_b64(intent)}","${_b64(name)}","${_b64(specText)}")',
      errorCode: EngineErrorCode.generateFailed,
    );
  }

  @override
  Future<Map<String, dynamic>> tap(String mbt, String artboard, double x, double y) =>
      _envelope(
        '__ndEngine.tap("${_b64(mbt)}","${_b64(artboard)}",${jsonEncode(x)},${jsonEncode(y)})',
        errorCode: EngineErrorCode.tapFailed,
      );

  @override
  Future<Map<String, dynamic>> constrain(String mbt, String artboard, String intent) =>
      _envelope(
        '__ndEngine.constrain("${_b64(mbt)}","${_b64(artboard)}","${_b64(intent)}")',
        errorCode: EngineErrorCode.constrainFailed,
      );

  @override
  Future<Map<String, dynamic>> event(String mbt, String artboard, String spec) =>
      _envelope(
        '__ndEngine.event("${_b64(mbt)}","${_b64(artboard)}","${_b64(spec)}")',
        errorCode: EngineErrorCode.eventFailed,
      );

  // -------------------------------------------------------------------------
  // Registry / diagnostics
  // -------------------------------------------------------------------------

  @override
  Future<Map<String, dynamic>> listing(String functionName) async {
    final value = await _rawCall('__ndEngine.listing(${jsonEncode(functionName)})');
    if (value is List) return <String, dynamic>{'ok': true, 'data': value};
    return _asMap(value);
  }

  @override
  Future<Map<String, dynamic>> version() => _envelope('__ndEngine.version()');

  @override
  Future<EngineStats> stats() async {
    final value = await _rawCall('__ndEngine.stats()');
    if (value is Map) return EngineStats.fromJson(Map<String, dynamic>.from(value));
    return EngineStats.empty;
  }

  @override
  Future<EngineStats> recycle() async {
    final value = await _rawCall('__ndEngine.recycle()');
    if (value is Map) return EngineStats.fromJson(Map<String, dynamic>.from(value));
    return EngineStats.empty;
  }
}
