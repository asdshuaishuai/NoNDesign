/// Engine host client: owns the worker isolate and serialises calls (batch 02).
///
/// Responsibilities:
///
///  * spawn [engineWorkerEntry] and hand it the engine bytes;
///  * queue every request (the engine is single-threaded, and the worker is
///    one isolate);
///  * enforce a wall-clock watchdog per call. Fuel is the first line of
///    defence; the watchdog answers the caller and respawns the worker as the
///    backstop. It cannot *interrupt* a synchronous WASM call: `Isolate.kill`
///    does not unwind a native frame, so an abandoned call keeps the executor
///    busy until it returns. That is why [start] refuses to bring up a real
///    engine on an executor without fuel metering — one runaway call would
///    otherwise wedge every future call in the process;
///  * resolve the wasm_run executor library (bundled app, dev tree, explicit
///    path).
///
/// All calls are `Future`s, so the UI isolate never blocks. That is a hard
/// requirement: a mid-size document `apply` can take over a second on
/// desktop, which is ~60 dropped frames if it ran on the UI isolate.
library;

import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'engine_types.dart';
import 'engine_worker.dart';

/// Host-level configuration (bytes/isolate/timeout), plus the core options
/// forwarded to the worker.
class EngineHostOptions {
  /// Executor options inside the worker (fuel, recycle threshold).
  final EngineCoreOptions core;

  /// Watchdog for one engine call. Mirrors the Python host's 30 s epoch
  /// deadline; tests shorten it to prove the kill+respawn path.
  final Duration callTimeout;

  /// How long to wait for isolate spawn + module compile + first instance.
  final Duration startTimeout;

  /// Explicit executor library path; [EngineLibraryResolver] otherwise.
  final String? libraryPath;

  /// Whether the artifact must expose the MoonViz ABI. Only synthetic test
  /// fixtures (fuel/grow/trap probes) set this to false.
  final bool requireEngineAbi;

  /// Diagnostic sink (never user-facing copy).
  final void Function(String message)? onLog;

  const EngineHostOptions({
    this.core = const EngineCoreOptions(),
    this.callTimeout = kEngineDefaultCallTimeout,
    this.startTimeout = const Duration(seconds: 30),
    this.libraryPath,
    this.requireEngineAbi = true,
    this.onLog,
  });
}

/// Resolves the `wasm_run` executor library.
///
/// On iOS/Android the library is linked into the process (native asset or
/// ffiPlugin), so the default `WasmRunLibrary.setUp()` path is correct and
/// `null` is returned. On desktop the app bundle ships
/// `libwasm_run_dart.dylib` / `wasm_run_dart.dll` / `libwasm_run_dart.so`; a
/// dev/test tree keeps the vendored copy under
/// `third_party/wasm_run/libs/`, which is also searched so `flutter test`
/// works without extra setup.
abstract final class EngineLibraryResolver {
  static String? resolve({String? explicitPath, Directory? startDirectory}) {
    if (explicitPath != null && explicitPath.isNotEmpty) {
      return File(explicitPath).existsSync() ? explicitPath : null;
    }
    final env = Platform.environment['WASM_RUN_DART_DYNAMIC_LIBRARY'];
    if (env != null && env.isNotEmpty && File(env).existsSync()) return env;
    for (final candidate in _bundleCandidates()) {
      if (File(candidate).existsSync()) return candidate;
    }
    // iOS/Android normally link the executor into the process (native asset or
    // ffiPlugin), so `WasmRunLibrary.setUp()` without an explicit library is
    // the right path. Only a bundled framework found above overrides it.
    if (Platform.isIOS || Platform.isAndroid) return null;
    return _devTreeLibrary(startDirectory ?? Directory.current);
  }

  static String get _dylibName {
    if (Platform.isMacOS) return 'libwasm_run_dart.dylib';
    if (Platform.isWindows) return 'wasm_run_dart.dll';
    return 'libwasm_run_dart.so';
  }

  static List<String> _bundleCandidates() {
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      return <String>[
        '$exeDir/$_dylibName',
        // Flutter's native-asset bundling ships a framework on Apple
        // platforms (`Contents/Frameworks/wasm_run_dart.framework`).
        '$exeDir/../Frameworks/wasm_run_dart.framework/wasm_run_dart',
        '$exeDir/../Frameworks/wasm_run_dart.framework/Versions/A/wasm_run_dart',
        '$exeDir/../Frameworks/$_dylibName',
        '$exeDir/../Resources/$_dylibName',
        '$exeDir/../lib/$_dylibName',
        '$exeDir/lib/$_dylibName',
      ];
    } catch (_) {
      return const <String>[];
    }
  }

  static String? _devTreeLibrary(Directory start) {
    final target = rustTargetForCurrentAbi();
    if (target == null) return null;
    var dir = start;
    for (var depth = 0; depth < 6; depth++) {
      final candidate = File('${dir.path}/third_party/wasm_run/libs/wasm_run_dart-dynamic-$target');
      if (candidate.existsSync()) {
        // Windows 的 LoadLibrary 对裸名路径自动补 `.dll` 再查找（找不到即
        // error 126），vendored 文件又按上游裸名冻结落盘——垫一份带后缀的
        // 临时副本再加载。生产包不走这里：native-asset 机制（hook/build.dart）
        // 已把同一份拷成 wasm_run_dart.dll 放进应用目录，bundle 候选先命中。
        if (!Platform.isWindows) return candidate.path;
        return _stageWindowsDll(candidate, target);
      }
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    return null;
  }

  /// Windows 专用：裸名 vendored 库 → 带 `.dll` 后缀的临时副本。
  ///
  /// 每次解析都重拷（约 8MB、每次进程只发生一次）：内容总是最新，免去
  /// 「引擎升版后临时副本滞留旧文件」的一致性陷阱。副本在系统临时目录，
  /// 由操作系统回收。
  static String? _stageWindowsDll(File source, String target) {
    try {
      final staging = Directory('${Directory.systemTemp.path}/wasm_run_dart-staged');
      staging.createSync(recursive: true);
      final staged = File('${staging.path}/wasm_run_dart-$target.dll');
      source.copySync(staged.path);
      return staged.path;
    } catch (_) {
      return null;
    }
  }

  /// Maps the current process ABI to the vendored executor file suffix.
  ///
  /// Kept in sync with `scripts/fetch_wasm_run_libs.sh` and
  /// `third_party/wasm_run/hook/build.dart`.
  static String? rustTargetForCurrentAbi() {
    switch (ffi.Abi.current()) {
      case ffi.Abi.macosArm64:
        return 'aarch64-apple-darwin';
      case ffi.Abi.macosX64:
        return 'x86_64-apple-darwin';
      case ffi.Abi.linuxX64:
        return 'x86_64-unknown-linux-gnu';
      case ffi.Abi.linuxArm64:
        return 'aarch64-unknown-linux-gnu';
      case ffi.Abi.windowsX64:
        return 'x86_64-pc-windows-msvc';
      case ffi.Abi.windowsArm64:
        return 'aarch64-pc-windows-msvc';
      case ffi.Abi.androidArm64:
        return 'aarch64-linux-android';
      case ffi.Abi.androidArm:
        return 'armv7-linux-androideabi';
      case ffi.Abi.androidX64:
        return 'x86_64-linux-android';
      case ffi.Abi.androidIA32:
        return 'i686-linux-android';
      case ffi.Abi.iosArm64:
        return 'aarch64-apple-ios';
      case ffi.Abi.iosX64:
        return 'x86_64-apple-ios';
      default:
        return null;
    }
  }
}

/// Client for one engine worker isolate.
///
/// One instance per app. Every method returns an engine envelope
/// (`{ok: bool, …}`) — transport failures are enveloped too, never thrown, so
/// callers (store, agent loop) have a single error shape to handle.
class EngineHost {
  EngineHost._(this._wasmBytes, this._options);

  final Uint8List _wasmBytes;
  final EngineHostOptions _options;

  final ReceivePort _receiver = ReceivePort();
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  Future<void> _tail = Future<void>.value();
  int _nextId = 1;

  Isolate? _isolate;
  SendPort? _worker;
  StreamSubscription<dynamic>? _errorSubscription;
  Completer<Map<String, dynamic>>? _initCompleter;
  EngineRuntimeInfo? _runtime;
  String? _startupError;
  bool _needsRestart = false;
  bool _disposed = false;
  int _restartCount = 0;
  Future<void>? _restartFuture;

  /// Starts a host: spawns the isolate, compiles the module, builds the first
  /// instance. Throws [EngineStartupException] when the executor or artifact
  /// cannot be loaded — callers turn that into `engine_unavailable` copy.
  static Future<EngineHost> start({
    required Uint8List wasmBytes,
    EngineHostOptions options = const EngineHostOptions(),
  }) async {
    final host = EngineHost._(wasmBytes, options);
    host._receiver.listen(host._onMessage);
    final libraryPath = EngineLibraryResolver.resolve(explicitPath: options.libraryPath);
    host._log('executor library: ${libraryPath ?? 'bundled process symbols'}');
    try {
      await host._spawn(libraryPath: libraryPath);
    } catch (error) {
      await host._errorSubscription?.cancel();
      host._receiver.close();
      throw EngineStartupException('$error');
    }
    return host;
  }

  /// Runtime facts once the host is ready.
  EngineRuntimeInfo? get runtime => _runtime;

  /// Why the host failed to start, if it did (`null` when healthy).
  String? get startupError => _startupError;

  /// Number of isolate respawns (watchdog kills + crashes).
  int get restartCount => _restartCount;

  /// True when calls can be served (worker alive and initialised).
  bool get isReady => _worker != null && _startupError == null && !_disposed;

  /// Clears a recorded startup failure and tries to bring the worker back.
  /// Returns whether the host is usable afterwards.
  Future<bool> retry() async {
    if (_disposed) return false;
    _startupError = null;
    _needsRestart = true;
    await _ensureRestarted('manual retry');
    return isReady;
  }

  void _log(String message) => _options.onLog?.call(message);

  Future<void> _spawn({String? libraryPath}) async {
    final handshake = ReceivePort();
    final errorPort = ReceivePort();
    final isolate = await Isolate.spawn(
      engineWorkerEntry,
      handshake.sendPort,
      onError: errorPort.sendPort,
      errorsAreFatal: true,
      debugName: 'nondesign-engine',
    );
    await _errorSubscription?.cancel();
    final subscription = errorPort.listen(_onWorkerError);
    _errorSubscription = subscription;

    // Every failure path must kill the isolate and release its error port:
    // a handshake timeout used to leave a permanently idle worker behind
    // because only the port was closed.
    Future<void> abandon() async {
      await subscription.cancel();
      if (identical(_errorSubscription, subscription)) _errorSubscription = null;
      errorPort.close();
      try {
        isolate.kill(priority: Isolate.immediate);
      } catch (_) {}
    }

    final Object? workerPort;
    try {
      workerPort = await handshake.first.timeout(_options.startTimeout);
    } on TimeoutException {
      await abandon();
      throw const EngineStartupException('worker handshake timed out');
    } finally {
      handshake.close();
    }
    if (workerPort is! SendPort) {
      await abandon();
      throw const EngineStartupException('worker handshake failed');
    }
    _isolate = isolate;
    _worker = workerPort;
    final init = Completer<Map<String, dynamic>>();
    _initCompleter = init;
    workerPort.send(<String, dynamic>{
      EngineWorkerProtocol.type: EngineWorkerProtocol.init,
      EngineWorkerProtocol.wasm: _wasmBytes,
      EngineWorkerProtocol.libraryPath: libraryPath,
      EngineWorkerProtocol.options: _options.core.toJson(),
      EngineWorkerProtocol.requireEngineAbi: _options.requireEngineAbi,
      EngineWorkerProtocol.replyPort: _receiver.sendPort,
    });
    final Map<String, dynamic> ready;
    try {
      ready = await init.future.timeout(_options.startTimeout);
    } on TimeoutException {
      await abandon();
      _worker = null;
      throw const EngineStartupException('engine initialisation timed out');
    } finally {
      _initCompleter = null;
    }
    if (ready[EngineWorkerProtocol.type] != EngineWorkerProtocol.ready) {
      final detail = '${ready[EngineWorkerProtocol.detail] ??
          ready[EngineWorkerProtocol.error] ??
          'engine initialisation failed'}';
      await abandon();
      _worker = null;
      throw EngineStartupException(detail);
    }
    final info = ready[EngineWorkerProtocol.info];
    _runtime = info is Map
        ? EngineRuntimeInfo.fromJson(Map<String, dynamic>.from(info))
        : null;
    // A real engine without fuel metering must not run: a synchronous WASM
    // call cannot be interrupted from Dart (Isolate.kill does not unwind the
    // native frame), so one runaway call would keep the executor busy forever
    // and every replacement isolate would block on the executor lock. Refusing
    // to start is the only honest option — the surface then reports
    // engine_unavailable and the user can fall back to "连接桌面".
    if (_options.requireEngineAbi && _runtime != null && !_runtime!.fuelSupported) {
      await abandon();
      _worker = null;
      throw const EngineStartupException(
        'executor cannot meter fuel; unbounded engine calls cannot be cancelled',
      );
    }
    _startupError = null;
    _log('engine ready: $_runtime');
  }

  void _onMessage(Object? message) {
    if (message is! Map) return;
    final type = message[EngineWorkerProtocol.type];
    if (type == EngineWorkerProtocol.ready || type == EngineWorkerProtocol.initFailed) {
      final init = _initCompleter;
      if (init != null && !init.isCompleted) init.complete(Map<String, dynamic>.from(message));
      return;
    }
    if (type != EngineWorkerProtocol.reply) return;
    final id = (message[EngineWorkerProtocol.id] as num?)?.toInt();
    if (id == null) return;
    final completer = _pending.remove(id);
    if (completer == null) return; // late reply for a timed-out call
    if (!completer.isCompleted) completer.complete(Map<String, dynamic>.from(message));
  }

  void _onWorkerError(Object? message) {
    _log('engine worker died: $message');
    _worker = null;
    _needsRestart = true;
    final detail = '$message';
    final init = _initCompleter;
    if (init != null && !init.isCompleted) {
      init.complete(<String, dynamic>{
        EngineWorkerProtocol.type: EngineWorkerProtocol.initFailed,
        EngineWorkerProtocol.error: EngineErrorCode.unavailable,
        EngineWorkerProtocol.detail: detail,
      });
    }
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.complete(_failure(EngineErrorCode.unavailable, detail));
      }
    }
    _pending.clear();
  }

  /// Ensures exactly one restart is in flight.
  Future<void> _ensureRestarted(String reason) {
    final existing = _restartFuture;
    if (existing != null) return existing;
    final future = _restart(reason).whenComplete(() => _restartFuture = null);
    _restartFuture = future;
    return future;
  }

  /// Kills the worker and starts a fresh one. In-flight calls are completed
  /// with [EngineErrorCode.timeout] before the respawn.
  Future<void> _restart(String reason) async {
    _log('restarting engine worker: $reason');
    _restartCount++;
    _needsRestart = true;
    _worker = null;
    try {
      _isolate?.kill(priority: Isolate.immediate);
    } catch (_) {}
    _isolate = null;
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.complete(_failure(EngineErrorCode.timeout, reason));
      }
    }
    _pending.clear();
    final libraryPath = EngineLibraryResolver.resolve(explicitPath: _options.libraryPath);
    try {
      await _spawn(libraryPath: libraryPath);
      _needsRestart = false;
      if (_disposed) {
        // The host was disposed while the replacement was starting.
        _worker?.send(<String, dynamic>{EngineWorkerProtocol.type: EngineWorkerProtocol.close});
        _isolate?.kill(priority: Isolate.immediate);
        _worker = null;
        _isolate = null;
      }
    } catch (error) {
      _startupError = '$error';
      _log('engine restart failed: $error');
    }
  }

  /// Serialises [task] behind every previously queued call.
  Future<T> _enqueue<T>(Future<T> Function() task) {
    final runner = _tail.then((_) => task());
    _tail = runner.then<void>((_) {}, onError: (Object _) {});
    return runner;
  }

  Map<String, dynamic> _failure(String code, String detail) =>
      <String, dynamic>{'ok': false, 'error': code, 'detail': detail};

  Future<Map<String, dynamic>> _call(String op, [Map<String, dynamic> params = const {}]) {
    return _enqueue(() async {
      if (_disposed) {
        return _failure(EngineErrorCode.unavailable, 'engine host disposed');
      }
      final startupError = _startupError;
      if (startupError != null) {
        // Do not retry a 30 s spawn on every call; [retry] is explicit.
        return _failure(EngineErrorCode.unavailable, startupError);
      }
      final restarting = _restartFuture;
      if (restarting != null) await restarting;
      if (_needsRestart) await _ensureRestarted('worker needs restart');
      final worker = _worker;
      if (worker == null) {
        final detail = _startupError ?? 'engine worker is not running';
        return _failure(EngineErrorCode.unavailable, detail);
      }
      final id = _nextId++;
      final completer = Completer<Map<String, dynamic>>();
      _pending[id] = completer;
      worker.send(<String, dynamic>{
        EngineWorkerProtocol.type: EngineWorkerProtocol.call,
        EngineWorkerProtocol.id: id,
        EngineWorkerProtocol.op: op,
        EngineWorkerProtocol.params: params,
      });
      try {
        final reply = await completer.future.timeout(_options.callTimeout);
        if (reply[EngineWorkerProtocol.ok] == true) return reply;
        return _failure(
          '${reply[EngineWorkerProtocol.error] ?? EngineErrorCode.unavailable}',
          '${reply[EngineWorkerProtocol.detail] ?? ''}',
        );
      } on TimeoutException {
        _pending.remove(id);
        final detail =
            'engine call "$op" exceeded the ${_options.callTimeout.inMilliseconds} ms watchdog';
        // Answer immediately; recovery runs in the background and the next
        // queued call waits for it. (With fuel metering this path is only
        // reachable for calls that trap late; without it, the native call
        // keeps the executor busy until it returns — see the class docs.)
        unawaited(_ensureRestarted(detail));
        return _failure(EngineErrorCode.timeout, detail);
      }
    });
  }

  /// Unwraps `{ok: true, envelope: …}` replies into the engine envelope.
  Future<Map<String, dynamic>> _envelopeCall(String op, [Map<String, dynamic> params = const {}]) async {
    final reply = await _call(op, params);
    if (reply['ok'] != true) {
      return <String, dynamic>{
        'ok': false,
        'error': '${reply['error'] ?? EngineErrorCode.unavailable}',
        'detail': '${reply['detail'] ?? ''}',
      };
    }
    final envelope = reply[EngineWorkerProtocol.envelope];
    if (envelope is Map) return Map<String, dynamic>.from(envelope);
    return <String, dynamic>{'ok': false, 'error': EngineErrorCode.emptyResult};
  }

  Future<Map<String, dynamic>> render(String mbt) =>
      _envelopeCall(EngineWorkerProtocol.opRender, <String, dynamic>{'mbt': mbt});

  Future<Map<String, dynamic>> validate(String mbt) =>
      _envelopeCall(EngineWorkerProtocol.opValidate, <String, dynamic>{'mbt': mbt});

  Future<Map<String, dynamic>> apply(String mbt, String op, {String gate = 'human'}) =>
      _envelopeCall(EngineWorkerProtocol.opApply, <String, dynamic>{
        'mbt': mbt,
        'op': op,
        'gate': gate,
      });

  Future<Map<String, dynamic>> session(String mbt, String name, [String? arg]) =>
      _envelopeCall(EngineWorkerProtocol.opSession, <String, dynamic>{
        'mbt': mbt,
        'name': name,
        'arg': ?arg,
      });

  Future<Map<String, dynamic>> generate(
    String mbt,
    String intent,
    String name,
    Object? spec,
  ) =>
      _envelopeCall(EngineWorkerProtocol.opGenerate, <String, dynamic>{
        'mbt': mbt,
        'intent': intent,
        'name': name,
        'spec': spec,
      });

  Future<Map<String, dynamic>> tap(String mbt, String artboard, double x, double y) =>
      _envelopeCall(EngineWorkerProtocol.opTap, <String, dynamic>{
        'mbt': mbt,
        'artboard': artboard,
        'x': x,
        'y': y,
      });

  Future<Map<String, dynamic>> constrain(String mbt, String artboard, String intent) =>
      _envelopeCall(EngineWorkerProtocol.opConstrain, <String, dynamic>{
        'mbt': mbt,
        'artboard': artboard,
        'intent': intent,
      });

  Future<Map<String, dynamic>> event(String mbt, String artboard, String spec) =>
      _envelopeCall(EngineWorkerProtocol.opEvent, <String, dynamic>{
        'mbt': mbt,
        'artboard': artboard,
        'spec': spec,
      });

  Future<Map<String, dynamic>> exportHtml(String mbt) =>
      _envelopeCall(EngineWorkerProtocol.opExportHtml, <String, dynamic>{'mbt': mbt});

  /// `list_templates` / `list_themes` / `list_ops` / `list_tokens` /
  /// `list_components`.
  Future<Map<String, dynamic>> listing(String functionName) =>
      _envelopeCall(EngineWorkerProtocol.opListing, <String, dynamic>{'fn': functionName});

  /// Raw export call (int result). For contract tests and new-export probes.
  Future<int> rawCall(String functionName, [List<Object?> args = const []]) async {
    final reply = await _call(EngineWorkerProtocol.opRaw, <String, dynamic>{
      'fn': functionName,
      'args': args,
    });
    if (reply['ok'] != true) {
      throw EngineCallFailure(
        '${reply['error'] ?? EngineErrorCode.unavailable}',
        '${reply['detail'] ?? ''}',
      );
    }
    return (reply[EngineWorkerProtocol.value] as num?)?.toInt() ?? 0;
  }

  /// Reads an engine-owned UTF-16 string (used with [rawCall]).
  Future<String> readString(int ptr) async {
    final reply = await _call(EngineWorkerProtocol.opReadString, <String, dynamic>{'ptr': ptr});
    return '${reply[EngineWorkerProtocol.text] ?? ''}';
  }

  /// Diagnostic counters (memory, generation, traps, session cache).
  Future<EngineStats> stats() async {
    final reply = await _call(EngineWorkerProtocol.opStats);
    final info = reply[EngineWorkerProtocol.info];
    if (info is Map) return EngineStats.fromJson(Map<String, dynamic>.from(info));
    return EngineStats.empty;
  }

  /// Forces an instance rebuild (memory released, session evicted).
  Future<EngineStats> recycle() async {
    final reply = await _call(EngineWorkerProtocol.opRecycle);
    final info = reply[EngineWorkerProtocol.info];
    if (info is Map) return EngineStats.fromJson(Map<String, dynamic>.from(info));
    return EngineStats.empty;
  }

  /// All exports / session exports of the loaded artifact.
  Future<({List<String> exports, List<String> sessionExports})> exportNames() async {
    final reply = await _call(EngineWorkerProtocol.opExports);
    final info = reply[EngineWorkerProtocol.info];
    if (info is Map) {
      final map = Map<String, dynamic>.from(info);
      return (
        exports: (map['exports'] as List?)?.cast<String>() ?? const <String>[],
        sessionExports: (map['sessionExports'] as List?)?.cast<String>() ?? const <String>[],
      );
    }
    return (exports: const <String>[], sessionExports: const <String>[]);
  }

  /// The engine's `version_info` envelope.
  Future<Map<String, dynamic>> version() => _call(EngineWorkerProtocol.opVersion).then((reply) {
        final envelope = reply[EngineWorkerProtocol.envelope];
        if (envelope is Map) return Map<String, dynamic>.from(envelope);
        return <String, dynamic>{'ok': false, 'error': EngineErrorCode.unavailable};
      });

  /// Stops the worker and fails any in-flight call.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      _worker?.send(<String, dynamic>{EngineWorkerProtocol.type: EngineWorkerProtocol.close});
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 20));
    try {
      _isolate?.kill(priority: Isolate.immediate);
    } catch (_) {}
    _worker = null;
    _isolate = null;
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.complete(_failure(EngineErrorCode.unavailable, 'engine host disposed'));
      }
    }
    _pending.clear();
    await _errorSubscription?.cancel();
    _receiver.close();
  }
}

/// Raised by [EngineHost.start] when the executor/artifact cannot be brought
/// up. Callers map it to `engine_unavailable` — the message is diagnostic and
/// belongs in a collapsed technical-details block, never on screen.
class EngineStartupException implements Exception {
  final String detail;

  const EngineStartupException(this.detail);

  @override
  String toString() => 'EngineStartupException: $detail';
}
