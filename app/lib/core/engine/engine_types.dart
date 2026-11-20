/// Engine host value types and ABI constants (batch 02).
///
/// This file is deliberately **pure Dart** (no `package:wasm_run`, no
/// `dart:io`, no Flutter): it is the contract the rest of the app compiles
/// against, and it must stay importable from unit tests and tools that never
/// touch the WASM executor.
///
/// The ABI itself is documented in `AGENTS.md § 引擎 ABI`. These constants were
/// ported from the retired Python reference host (`server/engine.py`, removed
/// with the de-Python migration, batch 15 — see
/// `docs/plan-dart-agent-migration.md` and git history); this file is now the
/// only living copy. When the engine adds an export, update [kSessionExports] /
/// [kSessionInExports] and the sync probe together.
library;

import 'dart:convert';

// ---------------------------------------------------------------------------
// ABI constants (do not "tidy" these — they are byte contracts)
// ---------------------------------------------------------------------------

/// Slots are pushed in 4-byte little-endian chunks: `LE u32 value` +
/// `u32 valid-length` (1..4). Layout follows the retired
/// `server/engine.py::_slot` (historical reference; file removed 2026-11-18).
const int kEngineSlotChunkBytes = 4;

/// Engine strings are `[len@ptr-4][UTF-16LE@ptr]`; the length field carries a
/// tag in its high nibble, so reads mask it off (`LEN_MASK`).
const int kEngineLenMask = 0x0FFFFFFF;

/// Default per-call fuel allowance when the runtime supports metering.
///
/// Fuel is topped back up to the budget before every engine call (a lifetime
/// pool, never a reset), so this is "one call may burn at most this much".
/// Calibrated on wasmtime 14.0.4 + engine 0.2-dev: a runaway loop burns the
/// budget in ~225 ms, while a seed-document render costs ~2.3M and a small
/// page apply ~2.5M. Large documents cost more — see [kEngineFuelPerByte].
const int kEngineDefaultFuelPerCall = 500000000;

/// Space needed per canonical-document byte for the most expensive engine
/// call. Measured on engine 0.2-dev (wasmtime 14): a 345 KB document costs
/// ~2.6B fuel for one `apply` and ~1.24B for one `render`, i.e. ~7_500 and
/// ~3_600 fuel per byte. 12_000 keeps ~1.6× headroom on the worst case while
/// staying linear — a fixed 500M budget would trap on any document above
/// ~65 KB, which is a normal page in this product.
const int kEngineFuelPerByte = 12000;

/// Engine linear memory above this size triggers a full instance rebuild
/// (session evicted first) — mirrors `MEMORY_RECYCLE_BYTES` in the Python
/// host. The engine's allocator never returns pages, so long editing sessions
/// must recycle instead of leaking.
const int kEngineMemoryRecycleBytes = 176 * 1024 * 1024;

/// Wall-clock watchdog for one engine call. The Dart host has no epoch
/// interruption, so a watchdog kills and respawns the worker isolate instead
/// (fuel catches runaways first where the runtime supports it).
///
/// Windows 执行器是 pulley 解释器（见 AGENTS.md）：同一调用比 Cranelift
/// 慢数倍，30 s 会把大文档的 generate/render 误杀成 engine_timeout。
/// 90 s 只放宽看门狗这一道兜底——真正的失控调用仍由 fuel 第一时间拦住。
const Duration kEngineDefaultCallTimeout = Duration(seconds: 90);

/// Budgets from the migration plan for enabling the engine *on phones*.
/// Reaching them does not enable mobile by itself: `WasmRuntimeGate` gates
/// that, and iOS currently cannot execute the module at all (wasmi 0.31 has
/// no SIMD). Desktop is expected to be far below these numbers.
///
/// Cross-reference: `capability.dart` (`WasmRuntimeGate`, owned by batch 01)
/// uses a 400 ms render p95 and a 250 ms call p95, i.e. *stricter* for render
/// and *looser* for apply than the plan numbers here. Both sets are satisfied
/// by the desktop measurements in `engine_host_test.dart` (render p95 ≈7 ms,
/// apply p95 ≈4 ms); the discrepancy is registered for the 01 owner to
/// reconcile rather than silently "fixed" in two places.
const Duration kEngineMobileFirstRenderBudget = Duration(seconds: 2);
const Duration kEngineMobileRenderP95Budget = Duration(milliseconds: 500);
const Duration kEngineMobileApplyP95Budget = Duration(milliseconds: 200);

// ---------------------------------------------------------------------------
// Export faces (engine 0.2-dev, 78 exports / 53 session exports)
// ---------------------------------------------------------------------------

/// The 31 non-`_in` session exports (the session face the plan promises).
///
/// `session_generate_spec` takes four raw UTF-16 pointers and `session_count`
/// is a zero-parameter void export; neither can be driven through the generic
/// session path — see [kSessionUnsupportedSignatures].
const List<String> kSessionExports = <String>[
  'session_apply_agent',
  'session_apply_human',
  'session_auto_fix',
  'session_benchmark',
  'session_close',
  'session_component_compile_b64',
  'session_constrain',
  'session_count',
  'session_critique',
  'session_event',
  'session_export_svg',
  'session_extract_design_system',
  'session_flows',
  'session_generate',
  'session_generate_responsive',
  'session_generate_spec',
  'session_history',
  'session_infer_missing',
  'session_infer_page_type',
  'session_interactions',
  'session_library_snapshot',
  'session_lint',
  'session_list_artboards',
  'session_open',
  'session_open_project_json',
  'session_query_nodes',
  'session_save',
  'session_snapshot',
  'session_spec',
  'session_states',
  'session_tap',
];

/// The 22 `_in` session exports (byte-slot write path).
const List<String> kSessionInExports = <String>[
  'session_apply_agent_in',
  'session_apply_human_in',
  'session_auto_fix_in',
  'session_component_compile_b64_in',
  'session_constrain_in',
  'session_critique_in',
  'session_event_in',
  'session_export_svg_in',
  'session_extract_design_system_in',
  'session_generate_in',
  'session_generate_responsive_in',
  'session_history_in',
  'session_infer_missing_in',
  'session_infer_page_type_in',
  'session_interactions_in',
  'session_lint_in',
  'session_open_in',
  'session_open_project_json_in',
  'session_query_nodes_in',
  'session_spec_in',
  'session_states_in',
  'session_tap_in',
];

/// Envelope sessions that return a mutated canonical document. Ported from the
/// retired `SESSION_MUTATING` table in `server/engine.py` (file removed with
/// the de-Python migration) — the host writes the returned
/// `mbt` back into the session cache so the next caller hits the same handle.
///
/// `session_history` is included even though `init`/`commit`/`log` return no
/// `mbt`: undo/redo do, and the guard in [EngineSessionCache] simply never
/// fires for the others.
const Set<String> kSessionMutating = <String>{
  'session_apply_agent',
  'session_apply_human',
  'session_auto_fix',
  'session_constrain',
  'session_tap',
  'session_generate_responsive',
  'session_component_compile_b64',
  'session_generate',
  'session_event',
  'session_history',
};

/// True when [name] is one of the non-`_in` session exports the generic
/// session face (and the `engine.session` RPC method) may be asked for.
///
/// The `_in` variants are deliberately excluded: the generic face appends that
/// suffix itself, so accepting the suffixed names would drive the byte-slot
/// exports with a handle and the wrong argument count.
bool isSessionExportName(String name) => kSessionExports.contains(name);

/// Sessions whose export takes only the handle and returns JSON directly
/// (`_in` variants do not exist for these; verified against engine 0.2-dev).
const Set<String> kSessionHandleOnly = <String>{
  'session_flows',
  'session_benchmark',
  'session_list_artboards',
  'session_save',
  'session_library_snapshot',
  'session_snapshot',
};

/// Sessions with a dedicated slot layout; they must never go through the
/// generic "push arg, call `<name>_in`" path.
///
/// `EngineWasmCore.session` enforces this: `session_constrain` is routed
/// through the typed path with an explicit empty intent (a stale `arg2` must
/// never be reused), and the others are refused with
/// [EngineErrorCode.unsupportedSignature] instead of being called with the
/// wrong argument count (which traps the instance).
const Set<String> kSessionSpecial = <String>{
  'session_generate', // in=spec JSON, arg=intent, arg2=artboard name
  'session_event', // in=event token, arg=artboard
  'session_tap', // arg=artboard, plus f64 x/y parameters
  'session_constrain', // arg=artboard, arg2=intent
};

/// Exports that exist but cannot be reached through [EngineSessionCache]:
///
/// * `session_generate_spec` — `(handle, artboardPtr, namePtr, specPtr)`:
///   three raw UTF-16 pointers into engine memory that a host cannot allocate.
///   Spec-driven generation goes through `session_generate_in` instead (spec
///   in the `in` slot), which is what the Python host and the app use.
/// * `session_count` — zero parameters, returns nothing (void debug export).
/// * `session_open` — `(docPtr)`: a raw UTF-16 pointer, the pointer-form of
///   the open the host already performs implicitly via `session_open_in`.
///   Refusing it explicitly keeps a wrong call from trapping the instance.
const Set<String> kSessionUnsupportedSignatures = <String>{
  'session_generate_spec',
  'session_count',
  'session_open',
};

/// The exports the ABI layer itself depends on. A missing member means the
/// artifact is not the classic MoonViz module we expect — fail loudly.
const List<String> kEngineAbiExports = <String>[
  'version_info',
  'list_templates',
  'list_themes',
  'list_ops',
  'list_tokens',
  'list_components',
  'validate_mbt_in',
  'render_mbt_in',
  'apply_human_op_in',
  'apply_agent_op_in',
  'export_html_in',
  'in_reset',
  'in_push',
  'arg_reset',
  'arg_push',
  'arg2_reset',
  'arg2_push',
  'session_open_in',
  'session_close',
];

// ---------------------------------------------------------------------------
// Error codes (user copy is mapped from these; never show the code itself)
// ---------------------------------------------------------------------------

/// Stable machine codes carried by failed engine envelopes (`error` field).
///
/// The copy layer maps them to human sentences (see `docs/copy-glossary.md`):
/// `engine_unavailable` → "设计服务暂时不可用，请稍后重试", `engine_timeout` →
/// "这次操作耗时过长，已安全停止", and so on. Raw runtime text only ever goes
/// into `detail`, which the UI shows inside a collapsed "技术详情" block.
abstract final class EngineErrorCode {
  /// The host never started (missing artifact, executor library, init crash).
  static const String unavailable = 'engine_unavailable';

  /// The watchdog killed the worker mid-call.
  static const String timeout = 'engine_timeout';

  /// The per-call fuel allowance ran out (runaway or oversized call).
  static const String fuelExhausted = 'engine_fuel_exhausted';

  /// The module trapped; the instance was rebuilt before returning.
  static const String trap = 'engine_trap';

  /// A session call failed (trap or engine-side error inside an open session).
  static const String sessionFailed = 'engine_session_failed';

  /// `session_open_in` returned a negative handle.
  static const String sessionOpenFailed = 'engine_session_open_failed';

  /// The export does not exist in this artifact.
  static const String unknownFunction = 'engine_unknown_function';

  /// The engine returned an empty string pointer.
  static const String emptyResult = 'engine_empty_result';

  /// The engine returned a string that is not JSON.
  static const String nonJson = 'engine_non_json';

  /// The requested operation needs a signature this host cannot build.
  static const String unsupportedSignature = 'engine_unsupported_signature';

  /// `generate`/`tap`/`event`/`constrain` wrapper failure prefixes.
  static const String generateFailed = 'engine_generate_failed';
  static const String tapFailed = 'engine_tap_failed';
  static const String eventFailed = 'engine_event_failed';
  static const String constrainFailed = 'engine_constrain_failed';
}

/// Thrown by the low-level core when a call traps, exhausts fuel, or hits a
/// missing export. The instance has already been rebuilt when this escapes.
class EngineCallFailure implements Exception {
  final String code;
  final String detail;

  const EngineCallFailure(this.code, [this.detail = '']);

  @override
  String toString() => detail.isEmpty ? code : '$code: $detail';
}

/// Normalises a raw engine reply the way the retired
/// `server/engine.py::_parse` did (historical source; file removed with the
/// de-Python migration): an empty pointer is `engine_empty_result`, a non-JSON
/// body is
/// `engine_non_json` with the first 400 characters preserved, and a JSON
/// scalar/array is wrapped as `{ok: true, data: …}`.
Map<String, dynamic> parseEngineEnvelope(String raw) {
  if (raw.isEmpty) {
    return <String, dynamic>{'ok': false, 'error': EngineErrorCode.emptyResult};
  }
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    return <String, dynamic>{
      'ok': false,
      'error': EngineErrorCode.nonJson,
      'raw': raw.length > 400 ? raw.substring(0, 400) : raw,
    };
  }
  if (decoded is Map) {
    return Map<String, dynamic>.from(decoded);
  }
  return <String, dynamic>{'ok': true, 'data': decoded};
}

// ---------------------------------------------------------------------------
// Runtime info / stats
// ---------------------------------------------------------------------------

/// Facts about the loaded engine + executor. Produced by the worker at init.
class EngineRuntimeInfo {
  /// Executor name reported by `wasm_run` (`wasmtime` / `wasmi` / …).
  final String runtime;

  /// Executor version.
  final String runtimeVersion;

  /// Engine self-reported version envelope (`{"engine":"moonviz",…}`).
  final String engineVersion;

  /// Whether the executor meters fuel (false ⇒ only the watchdog bounds calls).
  final bool fuelSupported;

  /// Number of exports in the artifact (78 for engine 0.2-dev).
  final int exportCount;

  /// Session exports found (`session_*`, both direct and `_in`).
  final int sessionExportCount;

  /// Per-call fuel floor.
  final int fuelPerCall;

  /// Fuel allowance per canonical-document byte.
  final int fuelPerByte;

  const EngineRuntimeInfo({
    required this.runtime,
    required this.runtimeVersion,
    required this.engineVersion,
    required this.fuelSupported,
    required this.exportCount,
    required this.sessionExportCount,
    required this.fuelPerCall,
    required this.fuelPerByte,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'runtime': runtime,
        'runtimeVersion': runtimeVersion,
        'engineVersion': engineVersion,
        'fuelSupported': fuelSupported,
        'exportCount': exportCount,
        'sessionExportCount': sessionExportCount,
        'fuelPerCall': fuelPerCall,
        'fuelPerByte': fuelPerByte,
      };

  static EngineRuntimeInfo fromJson(Map<String, dynamic> json) => EngineRuntimeInfo(
        runtime: '${json['runtime'] ?? ''}',
        runtimeVersion: '${json['runtimeVersion'] ?? ''}',
        engineVersion: '${json['engineVersion'] ?? ''}',
        fuelSupported: json['fuelSupported'] == true,
        exportCount: (json['exportCount'] as num?)?.toInt() ?? 0,
        sessionExportCount: (json['sessionExportCount'] as num?)?.toInt() ?? 0,
        fuelPerCall: (json['fuelPerCall'] as num?)?.toInt() ?? kEngineDefaultFuelPerCall,
        fuelPerByte: (json['fuelPerByte'] as num?)?.toInt() ?? kEngineFuelPerByte,
      );

  @override
  String toString() => 'EngineRuntimeInfo($runtime $runtimeVersion, engine $engineVersion, '
      '$exportCount exports, fuel=$fuelSupported)';
}

/// Counters for diagnostics + the memory-recycle gate. Serialisable across the
/// isolate boundary.
class EngineStats {
  /// Current linear-memory size in bytes.
  final int memoryBytes;

  /// High-water mark since the host started.
  final int peakMemoryBytes;

  /// How many instances have been built (1 = initial, +1 per rebuild).
  final int instanceGeneration;

  /// How many times the instance was rebuilt because memory crossed the cap.
  final int recycleCount;

  /// How many engine calls trapped (fuel or otherwise) and forced a rebuild.
  final int trapCount;

  /// Session cache hits (same canonical document, same handle).
  final int sessionHits;

  /// Session cache misses (handle reopened).
  final int sessionMisses;

  /// How many session handles were closed (evictions, explicit closes and
  /// cleanup after a failed call).
  final int sessionCloses;

  /// Total engine calls issued through the core.
  final int calls;

  /// Fuel consumed by the last call (0 without metering).
  final int lastFuelDelta;

  /// Fuel still available before the next top-up.
  final int fuelRemaining;

  const EngineStats({
    required this.memoryBytes,
    required this.peakMemoryBytes,
    required this.instanceGeneration,
    required this.recycleCount,
    required this.trapCount,
    required this.sessionHits,
    required this.sessionMisses,
    required this.sessionCloses,
    required this.calls,
    required this.lastFuelDelta,
    required this.fuelRemaining,
  });

  static const EngineStats empty = EngineStats(
    memoryBytes: 0,
    peakMemoryBytes: 0,
    instanceGeneration: 0,
    recycleCount: 0,
    trapCount: 0,
    sessionHits: 0,
    sessionMisses: 0,
    sessionCloses: 0,
    calls: 0,
    lastFuelDelta: 0,
    fuelRemaining: 0,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'memoryBytes': memoryBytes,
        'peakMemoryBytes': peakMemoryBytes,
        'instanceGeneration': instanceGeneration,
        'recycleCount': recycleCount,
        'trapCount': trapCount,
        'sessionHits': sessionHits,
        'sessionMisses': sessionMisses,
        'sessionCloses': sessionCloses,
        'calls': calls,
        'lastFuelDelta': lastFuelDelta,
        'fuelRemaining': fuelRemaining,
      };

  static EngineStats fromJson(Map<String, dynamic> json) => EngineStats(
        memoryBytes: (json['memoryBytes'] as num?)?.toInt() ?? 0,
        peakMemoryBytes: (json['peakMemoryBytes'] as num?)?.toInt() ?? 0,
        instanceGeneration: (json['instanceGeneration'] as num?)?.toInt() ?? 0,
        recycleCount: (json['recycleCount'] as num?)?.toInt() ?? 0,
        trapCount: (json['trapCount'] as num?)?.toInt() ?? 0,
        sessionHits: (json['sessionHits'] as num?)?.toInt() ?? 0,
        sessionMisses: (json['sessionMisses'] as num?)?.toInt() ?? 0,
        sessionCloses: (json['sessionCloses'] as num?)?.toInt() ?? 0,
        calls: (json['calls'] as num?)?.toInt() ?? 0,
        lastFuelDelta: (json['lastFuelDelta'] as num?)?.toInt() ?? 0,
        fuelRemaining: (json['fuelRemaining'] as num?)?.toInt() ?? 0,
      );

  @override
  String toString() => 'EngineStats(mem=$memoryBytes peak=$peakMemoryBytes '
      'gen=$instanceGeneration recycles=$recycleCount traps=$trapCount '
      'hits=$sessionHits misses=$sessionMisses closes=$sessionCloses calls=$calls fuel=$lastFuelDelta)';
}
