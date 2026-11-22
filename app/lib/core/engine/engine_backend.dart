/// Engine execution backend contract.
///
/// Two implementations exist:
///
///  * `EngineHost` — the native `wasm_run` isolate host. Pure Dart, test-friendly;
///    kept as the fallback while the WebView host is validated.
///  * `WebViewEngineHost` — the classic-wasm JS host running in an offscreen
///    `webview_all` session. This is the full-platform path: WKWebView,
///    WebView2, WebKitGTK and Android WebView all execute the same artifact,
///    with no native wasm runtime or per-platform dynamic library.
///
/// `EngineService` programs against this interface, so callers do not know
/// which host is active. Envelope shapes and error codes are identical.
library;

import 'engine_types.dart';

abstract interface class EngineBackend {
  /// Runtime facts once the host is ready.
  EngineRuntimeInfo? get runtime;

  /// Why the host failed to start, if it did (`null` when healthy).
  String? get startupError;

  /// Number of host respawns (watchdog kills + crashes).
  int get restartCount;

  /// True when calls can be served.
  bool get isReady;

  /// Clears a recorded startup failure and tries to bring the host back.
  Future<bool> retry();

  /// Stops the host and fails any in-flight call.
  Future<void> dispose();

  Future<Map<String, dynamic>> render(String mbt);

  Future<Map<String, dynamic>> validate(String mbt);

  Future<Map<String, dynamic>> apply(String mbt, String op, {String gate = 'human'});

  Future<Map<String, dynamic>> session(String mbt, String name, [String? arg]);

  Future<Map<String, dynamic>> generate(
    String mbt,
    String intent,
    String name,
    Object? spec,
  );

  Future<Map<String, dynamic>> tap(String mbt, String artboard, double x, double y);

  Future<Map<String, dynamic>> constrain(String mbt, String artboard, String intent);

  Future<Map<String, dynamic>> event(String mbt, String artboard, String spec);

  Future<Map<String, dynamic>> exportHtml(String mbt);

  /// `list_templates` / `list_themes` / `list_ops` / `list_tokens` /
  /// `list_components`.
  Future<Map<String, dynamic>> listing(String functionName);

  /// The engine's `version_info` envelope.
  Future<Map<String, dynamic>> version();

  /// Diagnostic counters (memory, generation, traps, session cache).
  Future<EngineStats> stats();

  /// Forces an instance rebuild (memory released, session evicted).
  Future<EngineStats> recycle();
}
