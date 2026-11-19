/// In-process MoonViz engine worker (batch 02).
///
/// Two responsibilities live here:
///
/// 1. [EngineWasmCore] — the actual WASM interaction: the `in`/`arg`/`arg2`
///    byte-slot ABI, the UTF-16 read layout, fuel metering, memory recycling,
///    trap recovery and the canonical-document session cache. It was ported
///    call for call from the retired Python reference host (`server/engine.py`,
///    removed with the de-Python migration, batch 15 — see
///    `docs/plan-dart-agent-migration.md`); this file is now the only host.
/// 2. [engineWorkerEntry] — the isolate entry that owns one [EngineWasmCore]
///    and answers requests from [EngineHost]. Every engine call happens on
///    this isolate, so the UI isolate never blocks (a large `apply` can take
///    over a second on desktop, far longer than a frame budget).
///
/// `package:wasm_run` may only be imported from `lib/core/engine/`
/// (`test/architecture_guard_test.dart` enforces this). It is imported
/// directly — not through `wasm_run_flutter` — so this file stays pure Dart
/// and the parity dump tool can run it with `dart run` (no Flutter engine).
///
/// Why the ABI is re-implemented instead of shelling out: the Python host is
/// being retired (batch 00/05); the engine artifact is a classic WASM MVP
/// module with zero imports, so the host is ~400 lines of byte plumbing.
library;

// wasm_run is pinned through dependency_overrides to third_party/wasm_run;
// wasm_run_flutter only adds Flutter asset loading, which this file must not
// depend on (it has to run under plain `dart run`).
// ignore: depend_on_referenced_packages
import 'package:wasm_run/wasm_run.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'engine_types.dart';

/// Options for one core instance (also sent across the isolate boundary).
class EngineCoreOptions {
  /// Per-call fuel floor (see [kEngineDefaultFuelPerCall]).
  final int fuelPerCall;

  /// Fuel allowance per canonical-document byte (see [kEngineFuelPerByte]).
  final int fuelPerByte;

  /// Instance rebuild threshold (see [kEngineMemoryRecycleBytes]).
  final int memoryRecycleBytes;

  /// Whether to request fuel metering from the executor.
  ///
  /// On runtimes without fuel (wasmi on iOS) the compile request is retried
  /// without metering and [EngineRuntimeInfo.fuelSupported] becomes false —
  /// the host watchdog then becomes the only bound on a runaway call.
  final bool consumeFuel;

  const EngineCoreOptions({
    this.fuelPerCall = kEngineDefaultFuelPerCall,
    this.fuelPerByte = kEngineFuelPerByte,
    this.memoryRecycleBytes = kEngineMemoryRecycleBytes,
    this.consumeFuel = true,
  });

  EngineCoreOptions copyWith({
    int? fuelPerCall,
    int? fuelPerByte,
    int? memoryRecycleBytes,
    bool? consumeFuel,
  }) =>
      EngineCoreOptions(
        fuelPerCall: fuelPerCall ?? this.fuelPerCall,
        fuelPerByte: fuelPerByte ?? this.fuelPerByte,
        memoryRecycleBytes: memoryRecycleBytes ?? this.memoryRecycleBytes,
        consumeFuel: consumeFuel ?? this.consumeFuel,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'fuelPerCall': fuelPerCall,
        'fuelPerByte': fuelPerByte,
        'memoryRecycleBytes': memoryRecycleBytes,
        'consumeFuel': consumeFuel,
      };

  static EngineCoreOptions fromJson(Map<String, dynamic> json) => EngineCoreOptions(
        fuelPerCall: (json['fuelPerCall'] as num?)?.toInt() ?? kEngineDefaultFuelPerCall,
        fuelPerByte: (json['fuelPerByte'] as num?)?.toInt() ?? kEngineFuelPerByte,
        memoryRecycleBytes:
            (json['memoryRecycleBytes'] as num?)?.toInt() ?? kEngineMemoryRecycleBytes,
        consumeFuel: json['consumeFuel'] != false,
      );
}

/// The engine core: one module, one live instance, one session cache.
///
/// All methods are async because building an instance is async; individual
/// engine calls are synchronous inside the worker isolate (there is nothing
/// else running there).
class EngineWasmCore {
  EngineWasmCore._(this._module, this._options, this._fuelSupported);

  final WasmModule _module;
  final EngineCoreOptions _options;
  final bool _fuelSupported;

  WasmInstance? _instance;
  WasmMemory? _memory;
  WasmInstanceFuel? _fuel;

  String? _sessMbt;
  int? _sessHandle;

  int _peakMemoryBytes = 0;
  int _instanceGeneration = 0;
  int _recycleCount = 0;
  int _trapCount = 0;
  int _sessionHits = 0;
  int _sessionMisses = 0;
  int _sessionCloses = 0;
  int _calls = 0;
  int _lastFuelDelta = 0;
  Map<String, dynamic> _engineVersion = const {};

  /// Compiles [bytes] with fuel metering when available.
  ///
  /// Returns the module plus whether metering is actually on. A compile that
  /// rejects metering (wasmi) is retried once without it; any other compile
  /// failure propagates.
  static Future<({WasmModule module, bool fuelSupported})> compile(
    Uint8List bytes, {
    required bool consumeFuel,
  }) async {
    if (consumeFuel) {
      try {
        final module = await compileWasmModule(
          bytes,
          config: const ModuleConfig(consumeFuel: true),
        );
        return (module: module, fuelSupported: true);
      } catch (_) {
        // Executor cannot meter (or rejects the config) — fall through to a
        // plain compile. A genuinely broken module throws below.
      }
    }
    final module = await compileWasmModule(bytes);
    return (module: module, fuelSupported: false);
  }

  /// Loads and instantiates [bytes]; the returned core owns the instance.
  static Future<EngineWasmCore> load(
    Uint8List bytes, {
    EngineCoreOptions options = const EngineCoreOptions(),
  }) async {
    final core = await loadRaw(bytes, options: options);
    final missing = kEngineAbiExports
        .where((name) => core._findFunction(name) == null)
        .toList(growable: false);
    if (missing.isNotEmpty) {
      core.dispose();
      throw EngineCallFailure(
        EngineErrorCode.unavailable,
        'artifact is missing ABI exports: ${missing.join(", ")}',
      );
    }
    final version = core._parse(await core._invoke(
      'version_info',
      const [],
      budget: options.fuelPerCall,
    ));
    core._engineVersion = version;
    return core;
  }

  /// Loads without the engine-ABI preflight — for synthetic fixture modules
  /// (fuel/grow/trap probes) and tools that only need the ABI primitives.
  /// The application always goes through [load].
  static Future<EngineWasmCore> loadRaw(
    Uint8List bytes, {
    EngineCoreOptions options = const EngineCoreOptions(),
  }) async {
    final compiled = await compile(bytes, consumeFuel: options.consumeFuel);
    final core = EngineWasmCore._(compiled.module, options, compiled.fuelSupported);
    await core._build();
    return core;
  }

  /// The engine's own `version_info` envelope.
  Map<String, dynamic> get engineVersion => _engineVersion;

  /// Whether the executor meters fuel.
  bool get fuelSupported => _fuelSupported;

  /// Every export name in the artifact (sorted).
  List<String> get exportNames {
    final instance = _instance;
    if (instance == null) return const [];
    final names = instance.exports.keys.toList()..sort();
    return names;
  }

  /// Export names starting with `session_`.
  List<String> get sessionExportNames =>
      exportNames.where((name) => name.startsWith('session_')).toList(growable: false);

  /// Runtime facts for diagnostics and the host handshake.
  Future<EngineRuntimeInfo> runtimeInfo() async {
    final features = await wasmRuntimeFeatures();
    return EngineRuntimeInfo(
      runtime: features.name,
      runtimeVersion: features.version,
      engineVersion: '${_engineVersion['version'] ?? _engineVersion['data'] ?? 'unknown'}',
      fuelSupported: _fuelSupported,
      exportCount: exportNames.length,
      sessionExportCount: sessionExportNames.length,
      fuelPerCall: _options.fuelPerCall,
      fuelPerByte: _options.fuelPerByte,
    );
  }

  // -------------------------------------------------------------------------
  // Instance lifecycle
  // -------------------------------------------------------------------------

  Future<void> _build() async {
    final builder = _module.builder();
    final fuel = builder.fuel();
    fuel?.addFuel(_options.fuelPerCall);
    final instance = await builder.build();
    final memory = instance.getMemory('memory');
    if (memory == null) {
      instance.dispose();
      throw EngineCallFailure(
        EngineErrorCode.unavailable,
        'engine does not export linear memory',
      );
    }
    final previous = _instance;
    _instance = instance;
    _memory = memory;
    _fuel = instance.fuel();
    _instanceGeneration++;
    _sessHandle = null;
    _sessMbt = null;
    _trackMemory();
    try {
      previous?.dispose();
    } catch (_) {
      // Disposing a trapped instance may throw; nothing to do about it.
    }
  }

  WasmFunction? _findFunction(String name) => _instance?.getFunction(name);

  bool _hasExport(String name) => _instance?.exports.containsKey(name) ?? false;

  /// Rebuilds the instance (session evicted first). Used after traps and by
  /// the memory-recycle gate.
  Future<void> _rebuild() async {
    try {
      await _build();
    } on EngineCallFailure {
      rethrow;
    } catch (error) {
      _instance = null;
      _memory = null;
      _fuel = null;
      _sessHandle = null;
      _sessMbt = null;
      throw EngineCallFailure(EngineErrorCode.unavailable, '$error');
    }
  }

  /// Builds the instance lazily. This must never recycle: [_invoke] runs once
  /// per 4-byte slot chunk, and a rebuild there would drop the prefix already
  /// pushed into the slot (the engine then renders a truncated document and
  /// still answers `ok`).
  Future<void> _ensureInstance() async {
    if (_instance == null) await _rebuild();
  }

  /// Memory-recycle gate. Only call this at the **start of a logical
  /// operation**, before the first slot reset/push: a rebuild evicts the
  /// session and resets every slot, so it must never land between the chunks
  /// of one payload. Rebuilding here keeps the capped-instance guarantee
  /// without ever handing a partial document to the engine.
  Future<void> _maybeRecycle() async {
    if (_instance == null) {
      await _rebuild();
      return;
    }
    final memory = _memory;
    if (memory == null) return;
    if (memory.lengthInBytes > _options.memoryRecycleBytes) {
      _recycleCount++;
      await _rebuild();
    }
  }

  void _trackMemory() {
    final memory = _memory;
    if (memory == null) return;
    final bytes = memory.lengthInBytes;
    if (bytes > _peakMemoryBytes) _peakMemoryBytes = bytes;
  }

  /// Runs one instance rebuild now (releases memory). Public for the store's
  /// "project closed / long idle" path and for tests.
  Future<void> releaseMemory() async {
    _recycleCount++;
    await _rebuild();
  }

  // -------------------------------------------------------------------------
  // ABI primitives
  // -------------------------------------------------------------------------

  /// Fuel budget for a call whose largest input is [text].
  int budgetFor(String text) {
    final bytes = utf8.encode(text).length;
    final scaled = bytes * _options.fuelPerByte;
    return scaled > _options.fuelPerCall ? scaled : _options.fuelPerCall;
  }

  void _topUp(int budget) {
    final fuel = _fuel;
    if (fuel == null) return;
    final remaining = fuel.fuelAdded() - fuel.fuelConsumed();
    if (remaining < budget) fuel.addFuel(budget - remaining);
  }

  bool _looksLikeFuelError(String detail) => detail.toLowerCase().contains('fuel');

  /// Invokes one export, returning its first result as an int (0 when void).
  ///
  /// A trap rebuilds the instance before throwing: the engine state after a
  /// trap is untrusted (Python does the same — `_call_raw`).
  Future<int> _invoke(
    String name,
    List<Object?> args, {
    required int budget,
  }) async {
    await _ensureInstance();
    final instance = _instance;
    if (instance == null) {
      throw const EngineCallFailure(EngineErrorCode.unavailable, 'no instance');
    }
    final fn = instance.getFunction(name);
    if (fn == null) {
      throw EngineCallFailure(EngineErrorCode.unknownFunction, name);
    }
    _calls++;
    _topUp(budget);
    final before = _fuel?.fuelConsumed() ?? 0;
    try {
      final out = fn(args);
      _lastFuelDelta = (_fuel?.fuelConsumed() ?? 0) - before;
      _trackMemory();
      if (out.isEmpty) return 0;
      final value = out.first;
      return value is int ? value : 0;
    } catch (error) {
      _trapCount++;
      final detail = '$error';
      try {
        await _rebuild();
      } catch (_) {
        // Rebuild failure is surfaced by the next call as engine_unavailable.
      }
      throw EngineCallFailure(
        _looksLikeFuelError(detail) ? EngineErrorCode.fuelExhausted : EngineErrorCode.trap,
        detail,
      );
    }
  }

  /// Reads an engine-owned UTF-16 string: `[len@ptr-4][UTF-16LE@ptr]`.
  ///
  /// The view is re-acquired on **every** read: `WasmMemory.view` caches a
  /// typed list keyed on pointer+length, and `memory.grow` can relocate the
  /// buffer. Reusing a previously returned view after a grow is the documented
  /// way to read freed/relocated memory (see `engine_host_test.dart`).
  String readString(int ptr) {
    final memory = _memory;
    if (memory == null) return '';
    final view = memory.view;
    final size = view.lengthInBytes;
    if (ptr < 4 || ptr > size) return '';
    final data = ByteData.view(view.buffer, view.offsetInBytes, size);
    var length = data.getUint32(ptr - 4, Endian.little) & kEngineLenMask;
    final maxChars = (size - ptr) ~/ 2;
    if (length > maxChars) length = maxChars;
    if (length <= 0) return '';
    final units = Uint16List(length);
    for (var i = 0; i < length; i++) {
      units[i] = data.getUint16(ptr + i * 2, Endian.little);
    }
    return String.fromCharCodes(units);
  }

  Map<String, dynamic> _parse(int ptr) => parseEngineEnvelope(readString(ptr));

  Future<void> _slot(
    String reset,
    String push,
    String text, {
    required int budget,
  }) async {
    final raw = utf8.encode(text);
    // No recycle gate runs inside this loop (see [_maybeRecycle]), but a trap
    // could still rebuild the instance mid-push. The generation check below
    // makes that explicit: if the instance changed under the payload, the
    // prefix is gone with it and the whole sequence is replayed once.
    for (var attempt = 0; attempt < 2; attempt++) {
      await _invoke(reset, const [], budget: budget);
      final generation = _instanceGeneration;
      var rebuiltMidPush = false;
      for (var i = 0; i < raw.length; i += kEngineSlotChunkBytes) {
        final end = math.min(i + kEngineSlotChunkBytes, raw.length);
        var le = 0;
        for (var b = i; b < end; b++) {
          le |= raw[b] << (8 * (b - i));
        }
        await _invoke(push, <Object?>[le, end - i], budget: budget);
        if (_instanceGeneration != generation) {
          rebuiltMidPush = true;
          break;
        }
      }
      if (!rebuiltMidPush) return;
    }
    throw const EngineCallFailure(
      EngineErrorCode.unavailable,
      'slot payload kept racing an instance rebuild',
    );
  }

  Future<void> _slotIn(String text, {required int budget}) =>
      _slot('in_reset', 'in_push', text, budget: budget);

  Future<void> _slotArg(String text, {required int budget}) =>
      _slot('arg_reset', 'arg_push', text, budget: budget);

  Future<void> _slotArg2(String text, {required int budget}) =>
      _slot('arg2_reset', 'arg2_push', text, budget: budget);

  // -------------------------------------------------------------------------
  // Session cache
  // -------------------------------------------------------------------------

  Future<int> _open(String mbt) async {
    await _maybeRecycle();
    final cached = _sessHandle;
    if (_sessMbt == mbt && cached != null) {
      _sessionHits++;
      return cached;
    }
    _sessionMisses++;
    await _closeSession();
    final budget = budgetFor(mbt);
    await _slotIn(mbt, budget: budget);
    final handle = await _invoke('session_open_in', const [], budget: budget);
    if (handle < 0) {
      throw EngineCallFailure(EngineErrorCode.sessionOpenFailed, 'handle=$handle');
    }
    _sessMbt = mbt;
    _sessHandle = handle;
    return handle;
  }

  Future<void> _closeSession() async {
    final handle = _sessHandle;
    _sessHandle = null;
    _sessMbt = null;
    if (handle != null) await _closeHandle(handle);
  }

  /// Closes one engine session handle. A broken instance cannot close
  /// cleanly; the rebuild already happened and the failure is ignored.
  Future<void> _closeHandle(int handle) async {
    _sessionCloses++;
    try {
      await _invoke('session_close', <Object?>[handle], budget: _options.fuelPerCall);
    } catch (_) {
      // Nothing to do: the handle died with the old instance.
    }
  }

  /// Runs one session call.
  ///
  /// Dispatch follows the layout inherited from the retired
  /// `server/engine.py::session` (historical source; file removed with the
  /// de-Python migration):
  ///  * unknown names — rejected before any session is opened;
  ///  * `session_close` / `session_open` — lifecycle, never a generic call:
  ///    closing drops the cache entry, opening is implicit (the host always
  ///    opens the document it is asked about);
  ///  * [kSessionUnsupportedSignatures] — signatures the host cannot build;
  ///  * [kSessionHandleOnly] — call the export with the handle, no slot push;
  ///  * [kSessionSpecial] — dedicated layouts (see [generate], [tap],
  ///    [constrain], [event]); the generic face cannot express them, so it
  ///    routes `session_constrain` through its typed path (with an explicit
  ///    empty intent) and refuses the rest instead of driving the wrong slots;
  ///  * everything else — push `arg` (empty when omitted: stale slot content
  ///    would otherwise leak across calls) and call `<name>_in` when present.
  Future<Map<String, dynamic>> session(String mbt, String name, [String? arg]) async {
    await _maybeRecycle();
    // Reject names this host cannot serve **before** opening a session. The
    // engine allocates a session arena per open (its allocator never returns
    // pages), so an unknown name used to cost ~60 KiB of linear memory on
    // every call even when the handle was closed afterwards.
    if (!isSessionExportName(name) || !_hasExport(name)) {
      return <String, dynamic>{
        'ok': false,
        'error': EngineErrorCode.unknownFunction,
        'detail': '$name is not a session export',
      };
    }
    if (kSessionUnsupportedSignatures.contains(name)) {
      return <String, dynamic>{
        'ok': false,
        'error': EngineErrorCode.unsupportedSignature,
        'detail': '$name needs a signature this host cannot build',
      };
    }
    if (name == 'session_close') {
      // Closing must also drop the cache entry: keeping the handle would
      // poison every later call for this document with invalid_session_handle.
      await _closeSession();
      return <String, dynamic>{'ok': true, 'closed': true};
    }
    if (kSessionSpecial.contains(name)) {
      if (name == 'session_constrain') {
        // arg carries the artboard; the intent lives in arg2 and the generic
        // face has no place for it. Route through the typed path with an
        // explicit empty intent so a stale arg2 from an earlier call can
        // never be reused (the engine answers cannot_parse with its
        // vocabulary, which is the honest result for a missing intent).
        return constrain(mbt, arg ?? '', '');
      }
      return <String, dynamic>{
        'ok': false,
        'error': EngineErrorCode.unsupportedSignature,
        'detail': '$name needs its typed call: the generic session face cannot '
            'build its slot layout',
      };
    }
    if (name == 'session_open_project_json') {
      // The `_in` variant takes no handle: the project JSON goes in the `in`
      // slot and the call returns a raw session handle. Cache it like any
      // other session (keyed by the payload) so eviction closes it instead of
      // leaking one engine session per call.
      final payload = arg ?? '';
      final budget = budgetFor(payload);
      try {
        final cached = _sessHandle;
        if (cached != null && _sessMbt == payload) {
          _sessionHits++;
          return <String, dynamic>{'ok': true, 'handle': cached};
        }
        _sessionMisses++;
        await _closeSession();
        await _slotIn(payload, budget: budget);
        final handle = await _invoke('session_open_project_json_in', const [], budget: budget);
        if (handle < 0) {
          throw EngineCallFailure(EngineErrorCode.sessionOpenFailed, 'handle=$handle');
        }
        _sessMbt = payload;
        _sessHandle = handle;
        return <String, dynamic>{'ok': true, 'handle': handle};
      } on EngineCallFailure catch (failure) {
        return <String, dynamic>{
          'ok': false,
          'error': EngineErrorCode.sessionFailed,
          'cause': failure.code,
          'detail': failure.detail,
        };
      }
    }
    try {
      final handle = await _open(mbt);
      final budget = budgetFor(mbt);
      late Map<String, dynamic> out;
      if (kSessionHandleOnly.contains(name)) {
        out = _parse(await _invoke(name, <Object?>[handle], budget: budget));
      } else {
        await _slotArg(arg ?? '', budget: budget);
        final inName = '${name}_in';
        final fn = _hasExport(inName) ? inName : name;
        out = _parse(await _invoke(fn, <Object?>[handle], budget: budget));
      }
      if (kSessionMutating.contains(name) && out['ok'] == true && out['mbt'] is String) {
        _sessMbt = out['mbt'] as String;
      }
      return out;
    } on EngineCallFailure catch (failure) {
      // Drop the cache entry. A clean failure (unknown export) leaves the
      // opened handle alive — close it, or every bogus name leaks a session.
      // After a trap the rebuild already cleared the handle, so nothing to do.
      final stale = _sessHandle;
      _sessHandle = null;
      _sessMbt = null;
      if (stale != null) await _closeHandle(stale);
      return <String, dynamic>{
        'ok': false,
        'error': EngineErrorCode.sessionFailed,
        'cause': failure.code,
        'detail': failure.detail,
      };
    }
  }

  // -------------------------------------------------------------------------
  // Document-face operations
  // -------------------------------------------------------------------------

  Future<Map<String, dynamic>> _inEnvelope(String fn, String mbt) async {
    await _maybeRecycle();
    final budget = budgetFor(mbt);
    try {
      await _slotIn(mbt, budget: budget);
      return _parse(await _invoke(fn, const [], budget: budget));
    } on EngineCallFailure catch (failure) {
      return <String, dynamic>{
        'ok': false,
        'error': failure.code,
        'detail': failure.detail,
      };
    }
  }

  Future<Map<String, dynamic>> validate(String mbt) => _inEnvelope('validate_mbt_in', mbt);

  Future<Map<String, dynamic>> render(String mbt) => _inEnvelope('render_mbt_in', mbt);

  Future<Map<String, dynamic>> exportHtml(String mbt) => _inEnvelope('export_html_in', mbt);

  /// Human gate (`gate: 'human'`, the canvas path) or agent gate
  /// (`gate: 'agent'`, the agent path). They are different engine doors on
  /// purpose — never route agent changes through the human gate.
  Future<Map<String, dynamic>> apply(String mbt, String op, {String gate = 'human'}) async {
    await _maybeRecycle();
    final fn = gate == 'agent' ? 'apply_agent_op_in' : 'apply_human_op_in';
    final budget = budgetFor(mbt);
    try {
      await _slotIn(mbt, budget: budget);
      await _slotArg(op, budget: budget);
      return _parse(await _invoke(fn, const [], budget: budget));
    } on EngineCallFailure catch (failure) {
      return <String, dynamic>{
        'ok': false,
        'error': failure.code,
        'detail': failure.detail,
      };
    }
  }

  /// `session_generate_in`: in=spec JSON, arg=intent, arg2=artboard name.
  Future<Map<String, dynamic>> generate(
    String mbt,
    String intent,
    String name,
    Object? spec,
  ) async {
    await _maybeRecycle();
    final specText = spec is String ? spec : jsonEncode(spec ?? const <String, dynamic>{});
    final budget = budgetFor(mbt);
    try {
      final handle = await _open(mbt);
      await _slotIn(specText, budget: budget);
      await _slotArg(intent, budget: budget);
      await _slotArg2(name, budget: budget);
      final out = _parse(await _invoke('session_generate_in', <Object?>[handle], budget: budget));
      if (out['ok'] == true && out['mbt'] is String) _sessMbt = out['mbt'] as String;
      return out;
    } on EngineCallFailure catch (failure) {
      return <String, dynamic>{
        'ok': false,
        'error': EngineErrorCode.generateFailed,
        'cause': failure.code,
        'detail': failure.detail,
      };
    }
  }

  /// `session_tap_in`: handle + f64 x/y, artboard in the `arg` slot.
  Future<Map<String, dynamic>> tap(String mbt, String artboard, double x, double y) async {
    await _maybeRecycle();
    final budget = budgetFor(mbt);
    try {
      final handle = await _open(mbt);
      await _slotArg(artboard, budget: budget);
      final out = _parse(
        await _invoke('session_tap_in', <Object?>[handle, x, y], budget: budget),
      );
      if (out['ok'] == true && out['mbt'] is String) _sessMbt = out['mbt'] as String;
      return out;
    } on EngineCallFailure catch (failure) {
      return <String, dynamic>{
        'ok': false,
        'error': EngineErrorCode.tapFailed,
        'cause': failure.code,
        'detail': failure.detail,
      };
    }
  }

  /// `session_constrain_in`: arg=artboard, arg2=intent.
  Future<Map<String, dynamic>> constrain(String mbt, String artboard, String intent) async {
    await _maybeRecycle();
    final budget = budgetFor(mbt);
    try {
      final handle = await _open(mbt);
      await _slotArg(artboard, budget: budget);
      await _slotArg2(intent, budget: budget);
      final out = _parse(
        await _invoke('session_constrain_in', <Object?>[handle], budget: budget),
      );
      if (out['ok'] == true && out['mbt'] is String) _sessMbt = out['mbt'] as String;
      return out;
    } on EngineCallFailure catch (failure) {
      return <String, dynamic>{
        'ok': false,
        'error': EngineErrorCode.constrainFailed,
        'cause': failure.code,
        'detail': failure.detail,
      };
    }
  }

  /// `session_event_in`: in=raw event token, arg=artboard.
  Future<Map<String, dynamic>> event(String mbt, String artboard, String spec) async {
    await _maybeRecycle();
    final budget = budgetFor(mbt);
    try {
      final handle = await _open(mbt);
      await _slotArg(artboard, budget: budget);
      await _slotIn(spec, budget: budget);
      final out = _parse(
        await _invoke('session_event_in', <Object?>[handle], budget: budget),
      );
      if (out['ok'] == true && out['mbt'] is String) _sessMbt = out['mbt'] as String;
      return out;
    } on EngineCallFailure catch (failure) {
      return <String, dynamic>{
        'ok': false,
        'error': EngineErrorCode.eventFailed,
        'cause': failure.code,
        'detail': failure.detail,
      };
    }
  }

  /// Zero-argument listing exports (`list_templates` …). Returns the raw
  /// engine envelope (`{ok, data}` for JSON arrays).
  Future<Map<String, dynamic>> listing(String fn) async {
    await _maybeRecycle();
    try {
      return _parse(await _invoke(fn, const [], budget: _options.fuelPerCall));
    } on EngineCallFailure catch (failure) {
      return <String, dynamic>{
        'ok': false,
        'error': failure.code,
        'detail': failure.detail,
      };
    }
  }

  /// Raw escape hatch: call any export and return its int result (0 for
  /// void). Used by contract tests and by tools that probe a new export.
  Future<int> rawCall(String fn, [List<Object?> args = const []]) async {
    await _maybeRecycle();
    return _invoke(fn, args, budget: _options.fuelPerCall);
  }

  /// Diagnostic counters.
  EngineStats stats() {
    final fuel = _fuel;
    final remaining = fuel == null ? 0 : fuel.fuelAdded() - fuel.fuelConsumed();
    return EngineStats(
      memoryBytes: _memory?.lengthInBytes ?? 0,
      peakMemoryBytes: _peakMemoryBytes,
      instanceGeneration: _instanceGeneration,
      recycleCount: _recycleCount,
      trapCount: _trapCount,
      sessionHits: _sessionHits,
      sessionMisses: _sessionMisses,
      sessionCloses: _sessionCloses,
      calls: _calls,
      lastFuelDelta: _lastFuelDelta,
      fuelRemaining: remaining,
    );
  }

  /// Disposes the instance (the module stays compiled until GC).
  void dispose() {
    try {
      _instance?.dispose();
    } catch (_) {}
    _instance = null;
    _memory = null;
    _fuel = null;
    _sessHandle = null;
    _sessMbt = null;
  }
}

// ---------------------------------------------------------------------------
// Isolate protocol
// ---------------------------------------------------------------------------

/// Request/reply field names, shared with `engine_host.dart`.
abstract final class EngineWorkerProtocol {
  static const String type = 'type';

  static const String init = 'init';
  static const String ready = 'ready';
  static const String initFailed = 'initFailed';
  static const String call = 'call';
  static const String reply = 'reply';
  static const String close = 'close';

  static const String id = 'id';
  static const String op = 'op';
  static const String params = 'params';
  static const String ok = 'ok';
  static const String envelope = 'envelope';
  static const String error = 'error';
  static const String detail = 'detail';
  static const String info = 'info';
  static const String replyPort = 'replyPort';
  static const String wasm = 'wasm';
  static const String libraryPath = 'libraryPath';
  static const String options = 'options';
  static const String requireEngineAbi = 'requireEngineAbi';
  static const String value = 'value';
  static const String text = 'text';

  // op names
  static const String opRender = 'render';
  static const String opValidate = 'validate';
  static const String opApply = 'apply';
  static const String opSession = 'session';
  static const String opGenerate = 'generate';
  static const String opTap = 'tap';
  static const String opConstrain = 'constrain';
  static const String opEvent = 'event';
  static const String opExportHtml = 'exportHtml';
  static const String opListing = 'listing';
  static const String opRaw = 'raw';
  static const String opReadString = 'readString';
  static const String opStats = 'stats';
  static const String opRecycle = 'recycle';
  static const String opExports = 'exports';
  static const String opVersion = 'version';
}

/// Isolate entry point: owns one [EngineWasmCore] and answers host requests.
///
/// Replies are plain maps (`{type: reply, id, ok, …}`) so nothing exotic
/// crosses the port. A fatal error during init is reported as `initFailed`
/// and the isolate exits — the host surfaces `engine_unavailable`.
Future<void> engineWorkerEntry(SendPort handshake) async {
  final inbox = ReceivePort();
  handshake.send(inbox.sendPort);
  SendPort? replies;
  EngineWasmCore? core;

  void reply(Map<String, dynamic> message) => replies?.send(message);

  await for (final message in inbox) {
    if (message is! Map) continue;
    final type = message[EngineWorkerProtocol.type];

    if (type == EngineWorkerProtocol.init) {
      replies = message[EngineWorkerProtocol.replyPort] as SendPort?;
      final wasm = message[EngineWorkerProtocol.wasm];
      final libraryPath = message[EngineWorkerProtocol.libraryPath] as String?;
      final requireEngineAbi = message[EngineWorkerProtocol.requireEngineAbi] != false;
      final rawOptions = message[EngineWorkerProtocol.options];
      final options = rawOptions is Map
          ? EngineCoreOptions.fromJson(Map<String, dynamic>.from(rawOptions))
          : const EngineCoreOptions();
      try {
        if (wasm is! Uint8List || wasm.isEmpty) {
          throw StateError('engine artifact bytes missing');
        }
        if (libraryPath != null && libraryPath.isNotEmpty) {
          await WasmRunLibrary.setUp(lib: ExternalLibrary.open(libraryPath));
        } else {
          await WasmRunLibrary.setUp();
        }
        core = requireEngineAbi
            ? await EngineWasmCore.load(wasm, options: options)
            : await EngineWasmCore.loadRaw(wasm, options: options);
        final info = await core.runtimeInfo();
        reply(<String, dynamic>{
          EngineWorkerProtocol.type: EngineWorkerProtocol.ready,
          EngineWorkerProtocol.info: info.toJson(),
        });
      } catch (error) {
        reply(<String, dynamic>{
          EngineWorkerProtocol.type: EngineWorkerProtocol.initFailed,
          EngineWorkerProtocol.error: EngineErrorCode.unavailable,
          EngineWorkerProtocol.detail: '$error',
        });
        inbox.close();
        return;
      }
      continue;
    }

    if (type == EngineWorkerProtocol.close) {
      core?.dispose();
      inbox.close();
      return;
    }

    if (type != EngineWorkerProtocol.call) continue;
    final id = message[EngineWorkerProtocol.id];
    final op = '${message[EngineWorkerProtocol.op]}';
    final params = message[EngineWorkerProtocol.params] is Map
        ? Map<String, dynamic>.from(message[EngineWorkerProtocol.params] as Map)
        : const <String, dynamic>{};
    final engine = core;
    if (engine == null) {
      reply(<String, dynamic>{
        EngineWorkerProtocol.type: EngineWorkerProtocol.reply,
        EngineWorkerProtocol.id: id,
        EngineWorkerProtocol.ok: false,
        EngineWorkerProtocol.error: EngineErrorCode.unavailable,
        EngineWorkerProtocol.detail: 'worker has no engine instance',
      });
      continue;
    }
    try {
      final result = await _dispatch(engine, op, params);
      reply(<String, dynamic>{
        EngineWorkerProtocol.type: EngineWorkerProtocol.reply,
        EngineWorkerProtocol.id: id,
        ...result,
      });
    } on EngineCallFailure catch (failure) {
      // Preserve the structured code: fuel exhaustion and traps must stay
      // distinguishable from "the host is broken".
      reply(<String, dynamic>{
        EngineWorkerProtocol.type: EngineWorkerProtocol.reply,
        EngineWorkerProtocol.id: id,
        EngineWorkerProtocol.ok: false,
        EngineWorkerProtocol.error: failure.code,
        EngineWorkerProtocol.detail: failure.detail,
      });
    } catch (error) {
      reply(<String, dynamic>{
        EngineWorkerProtocol.type: EngineWorkerProtocol.reply,
        EngineWorkerProtocol.id: id,
        EngineWorkerProtocol.ok: false,
        EngineWorkerProtocol.error: EngineErrorCode.unavailable,
        EngineWorkerProtocol.detail: '$error',
      });
    }
  }
}

Future<Map<String, dynamic>> _dispatch(
  EngineWasmCore core,
  String op,
  Map<String, dynamic> params,
) async {
  final mbt = '${params['mbt'] ?? ''}';
  switch (op) {
    case EngineWorkerProtocol.opRender:
      return <String, dynamic>{'ok': true, 'envelope': await core.render(mbt)};
    case EngineWorkerProtocol.opValidate:
      return <String, dynamic>{'ok': true, 'envelope': await core.validate(mbt)};
    case EngineWorkerProtocol.opApply:
      return <String, dynamic>{
        'ok': true,
        'envelope': await core.apply(mbt, '${params['op'] ?? ''}', gate: '${params['gate'] ?? 'human'}'),
      };
    case EngineWorkerProtocol.opSession:
      return <String, dynamic>{
        'ok': true,
        'envelope': await core.session(
          mbt,
          '${params['name'] ?? ''}',
          params['arg'] == null ? null : '${params['arg']}',
        ),
      };
    case EngineWorkerProtocol.opGenerate:
      return <String, dynamic>{
        'ok': true,
        'envelope': await core.generate(
          mbt,
          '${params['intent'] ?? ''}',
          '${params['name'] ?? ''}',
          params['spec'],
        ),
      };
    case EngineWorkerProtocol.opTap:
      return <String, dynamic>{
        'ok': true,
        'envelope': await core.tap(
          mbt,
          '${params['artboard'] ?? ''}',
          (params['x'] as num?)?.toDouble() ?? 0,
          (params['y'] as num?)?.toDouble() ?? 0,
        ),
      };
    case EngineWorkerProtocol.opConstrain:
      return <String, dynamic>{
        'ok': true,
        'envelope': await core.constrain(
          mbt,
          '${params['artboard'] ?? ''}',
          '${params['intent'] ?? ''}',
        ),
      };
    case EngineWorkerProtocol.opEvent:
      return <String, dynamic>{
        'ok': true,
        'envelope': await core.event(
          mbt,
          '${params['artboard'] ?? ''}',
          '${params['spec'] ?? ''}',
        ),
      };
    case EngineWorkerProtocol.opExportHtml:
      return <String, dynamic>{'ok': true, 'envelope': await core.exportHtml(mbt)};
    case EngineWorkerProtocol.opListing:
      return <String, dynamic>{
        'ok': true,
        'envelope': await core.listing('${params['fn'] ?? ''}'),
      };
    case EngineWorkerProtocol.opRaw:
      final args = params['args'] is List ? List<Object?>.from(params['args'] as List) : const <Object?>[];
      final value = await core.rawCall('${params['fn'] ?? ''}', args);
      return <String, dynamic>{'ok': true, 'value': value};
    case EngineWorkerProtocol.opReadString:
      return <String, dynamic>{
        'ok': true,
        'text': core.readString((params['ptr'] as num?)?.toInt() ?? 0),
      };
    case EngineWorkerProtocol.opStats:
      return <String, dynamic>{'ok': true, 'info': core.stats().toJson()};
    case EngineWorkerProtocol.opExports:
      return <String, dynamic>{
        'ok': true,
        'info': <String, dynamic>{
          'exports': core.exportNames,
          'sessionExports': core.sessionExportNames,
        },
      };
    case EngineWorkerProtocol.opVersion:
      return <String, dynamic>{'ok': true, 'envelope': core.engineVersion};
    case EngineWorkerProtocol.opRecycle:
      await core.releaseMemory();
      return <String, dynamic>{'ok': true, 'info': core.stats().toJson()};
    default:
      return <String, dynamic>{
        'ok': false,
        'error': EngineErrorCode.unknownFunction,
        'detail': 'unknown worker op: $op',
      };
  }
}
