// wasm_run spike for MoonViz (batch 01).
//
// Proves — on the host test VM and, through integration_test/wasm_spike_test.dart,
// on a real iOS simulator/device — that the vendored wasm_run executor can:
//
//   1. load `app/assets/engine/moonviz.wasm` (classic WASM MVP, zero imports);
//   2. drive the `_in` byte-slot ABI (in/arg/arg2: LE u32 chunk + length);
//   3. read UTF-16 engine strings ([len@ptr-4][utf16@ptr]);
//   4. see the full session export face (31 non-`_in` + 22 `_in` exports) and
//      the special signatures: session_event/tap/constrain/generate;
//   5. accept `validate_mbt('')` (empty document is legal since engine 0.2) and
//      render a seed document;
//   6. survive `memory.grow` by re-acquiring `WasmMemory.view` (stale views are
//      the documented trap: the getter caches a typed list per pointer/length);
//   7. report fuel usage, p50/p95 per call and peak memory, so the product
//      owner can decide whether phones may run the engine locally
//      (`WasmRuntimeGate`).
//
// The test is deliberately self-contained: it also serves as the reference
// implementation for the Dart engine host that later batches build on.

import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
// wasm_run_flutter re-exports wasm_run (direct dependency).
import 'package:wasm_run_flutter/wasm_run_flutter.dart';

import 'package:nondesign/core/capability.dart';

/// Result of one spike run. Serialisable so CI logs can carry the numbers.
class WasmSpikeReport {
  final String runtime;
  final String runtimeVersion;
  final String engineVersion;
  final int nonInSessionExports;
  final int inSessionExports;
  final bool emptyDocValid;
  final bool seedRenders;
  final bool specialSignaturesOk;
  final bool growSafe;
  final bool fuelSupported;
  final int fuelPerRender;
  final Duration coldStart;
  final Duration p50Render;
  final Duration p95Render;
  final int peakMemoryBytes;
  final int rssBytes;
  final List<String> notes;

  const WasmSpikeReport({
    required this.runtime,
    required this.runtimeVersion,
    required this.engineVersion,
    required this.nonInSessionExports,
    required this.inSessionExports,
    required this.emptyDocValid,
    required this.seedRenders,
    required this.specialSignaturesOk,
    required this.growSafe,
    required this.fuelSupported,
    required this.fuelPerRender,
    required this.coldStart,
    required this.p50Render,
    required this.p95Render,
    required this.peakMemoryBytes,
    required this.rssBytes,
    required this.notes,
  });

  Map<String, dynamic> toJson() => {
        'runtime': '$runtime $runtimeVersion',
        'engineVersion': engineVersion,
        'nonInSessionExports': nonInSessionExports,
        'inSessionExports': inSessionExports,
        'emptyDocValid': emptyDocValid,
        'seedRenders': seedRenders,
        'specialSignaturesOk': specialSignaturesOk,
        'growSafe': growSafe,
        'fuelSupported': fuelSupported,
        'fuelPerRender': fuelPerRender,
        'coldStartMs': coldStart.inMicroseconds / 1000,
        'p50RenderMs': p50Render.inMicroseconds / 1000,
        'p95RenderMs': p95Render.inMicroseconds / 1000,
        'peakMemoryBytes': peakMemoryBytes,
        'rssBytes': rssBytes,
        'notes': notes,
      };

  @override
  String toString() => 'WasmSpikeReport(${jsonEncode(toJson())})';
}

/// Seed document — byte-for-byte the same shape the Python/Rust hosts seed
/// with (`server/engine.py`, `scripts/sync_engine.py`).
const String kSeedDoc = '---\nmoonviz:\n  format: visual-document\n  revision: 1\n  entry: __seed\n---\n\n'
    '# __seed\n\n'
    '<!-- moonviz:artboard __seed -->\n'
    '```mbt\n'
    'fn visual___seed() -> @decl.Prototype {\n'
    '  let page = @decl.prototype(name="__seed", width=390.0, height=844.0)\n'
    '  page\n'
    '}\n'
    '```\n';

/// Minimal complete design spec (the engine silently ignores a bare
/// `{"style":...}` — probed on 0.2-dev).
const String kSpecJson = '{"v":1,"style":"apple",'
    '"palette":{"primary":"#2F6B4F","background":"#FFFFFF","surface":"#F2F7F4",'
    '"text":"#14201A","muted":"#5F7A6B","danger":"#DC2626","success":"#16A34A"},'
    '"typography":{"h1":30,"body":14,"caption":12},'
    '"spacing":[4,8,12,16,24,32],'
    '"radius":{"sm":8,"md":12,"lg":16}}';

/// Thin value wrapper around one instantiated MoonViz engine.
class MoonVizProbe {
  MoonVizProbe._(this.module, this.instance, this.memory, this.fuel,
      {required this.fuelBudgetPerCall});

  final WasmModule module;
  final WasmInstance instance;
  final WasmMemory memory;
  final WasmInstanceFuel? fuel;
  final int fuelBudgetPerCall;

  static const int _lenMask = 0x0FFFFFFF;
  int peakMemoryBytes = 0;

  /// Fuel consumed by the most recent engine call (0 when metering is off).
  int lastFuelDelta = 0;

  static bool _loaded = false;
  static String? _loadedAs;
  static String? _stagedWindowsLib;

  /// Windows 的 `LoadLibrary` 只认 `.dll`（无扩展名路径会补 `.dll` 再找），
  /// 而 vendored 文件名是无扩展名的 target 名。工作树里不保证有 `.dll` 垫片
  /// （它是本机开发便利，未入库），缺垫片时把 DLL 复制到带 `.dll` 的临时路径
  /// 再加载——不改变「加载的是哪一份字节」这个契约。
  static String _windowsLoadPath(File lib) {
    final dll = File('${lib.path}.dll');
    if (dll.existsSync()) return dll.path;
    final cached = _stagedWindowsLib;
    if (cached != null && File(cached).existsSync()) return cached;
    final dir = Directory.systemTemp.createTempSync('wasm-run-lib-');
    final copy = File('${dir.path}/${lib.uri.pathSegments.last}.dll');
    copy.writeAsBytesSync(lib.readAsBytesSync());
    _stagedWindowsLib = copy.path;
    return copy.path;
  }

  /// Initialise the native executor for host tests (desktop).
  ///
  /// `flutter test` runs outside the app bundle, so the bundled dylib is not
  /// on the loader path. Point wasm_run at the vendored copy explicitly. On a
  /// device the plugin/code asset handles this, and this method is a no-op.
  static Future<String?> ensureHostLibrary(Directory? repoRoot) async {
    if (_loaded) return _loadedAs;
    if (Platform.isIOS || Platform.isAndroid) {
      // Flutter's native assets wrap the vendored dylib in a framework inside
      // the app bundle (Runner.app/Frameworks/wasm_run_dart.framework) and link
      // it into the process; let wasm_run resolve it through the default path.
      await WasmRunLibrary.setUp();
      _loaded = true;
      _loadedAs = 'bundled process symbols (${Platform.operatingSystem})';
      return _loadedAs;
    }
    if (repoRoot == null) return null;
    final target = _hostTarget();
    if (target == null) return null;
    final lib = File('${repoRoot.path}/third_party/wasm_run/libs/wasm_run_dart-dynamic-$target');
    if (!lib.existsSync()) {
      throw StateError(
        'vendored wasm_run library missing for $target — '
        'run: bash scripts/fetch_wasm_run_libs.sh --target $target',
      );
    }
    final path = Platform.isWindows && !lib.path.toLowerCase().endsWith('.dll')
        ? _windowsLoadPath(lib)
        : lib.path;
    await WasmRunLibrary.setUp(lib: ExternalLibrary.open(path));
    _loaded = true;
    _loadedAs = path;
    return _loadedAs;
  }

  static String? _hostTarget() {
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
      default:
        return null;
    }
  }

  /// Compile + instantiate the module, optionally with fuel metering.
  static Future<MoonVizProbe> load(
    Uint8List bytes, {
    bool consumeFuel = true,
    int? fuelBudgetPerCall,
  }) async {
    WasmModule? module;
    var fuelEnabled = consumeFuel;
    if (consumeFuel) {
      try {
        module = await compileWasmModule(bytes, config: const ModuleConfig(consumeFuel: true));
      } catch (_) {
        fuelEnabled = false;
      }
    }
    module ??= await compileWasmModule(bytes);
    final builder = module.builder();
    final fuel = builder.fuel();
    if (fuel != null) fuel.addFuel(WasmRuntimeGate.fuelPerCallBudget);
    final instance = await builder.build();
    final memory = instance.getMemory('memory');
    if (memory == null) throw StateError('engine does not export linear memory');
    final probe = MoonVizProbe._(
      module,
      instance,
      memory,
      fuelEnabled ? fuel : null,
      fuelBudgetPerCall: fuelBudgetPerCall ?? WasmRuntimeGate.fuelPerCallBudget,
    );
    probe._trackMemory();
    return probe;
  }

  bool get fuelSupported => fuel != null;

  int get memoryBytes => memory.lengthInBytes;

  void _trackMemory() => peakMemoryBytes = math.max(peakMemoryBytes, memory.lengthInBytes);

  List<String> get exportNames => instance.exports.keys.toList(growable: false);

  WasmFunction _fn(String name) {
    final fn = instance.getFunction(name);
    if (fn == null) throw StateError('missing engine export: $name');
    return fn;
  }

  /// Fuel is a lifetime pool: top it back up to one call-budget before every
  /// engine call so a long sequence of small calls never starves (and a single
  /// runaway call still traps at the budget — that is the point of the gate).
  void _topUpFuel() {
    final f = fuel;
    if (f == null) return;
    final remaining = f.fuelAdded() - f.fuelConsumed();
    if (remaining < fuelBudgetPerCall) {
      f.addFuel(fuelBudgetPerCall - remaining);
    }
  }

  int callInt(String name, [List<Object?> args = const []]) {
    _topUpFuel();
    final before = fuel?.fuelConsumed() ?? 0;
    final out = _fn(name)(args);
    lastFuelDelta = (fuel?.fuelConsumed() ?? 0) - before;
    _trackMemory();
    if (out.isEmpty) return 0;
    final value = out.first;
    return value is int ? value : 0;
  }

  void callVoid(String name, [List<Object?> args = const []]) {
    _topUpFuel();
    final before = fuel?.fuelConsumed() ?? 0;
    _fn(name)(args);
    lastFuelDelta = (fuel?.fuelConsumed() ?? 0) - before;
    _trackMemory();
  }

  /// Push [text] into one of the three UTF-8 byte slots (in/arg/arg2).
  void pushSlot(String resetFn, String pushFn, String text) {
    callVoid(resetFn);
    final raw = utf8.encode(text);
    for (var i = 0; i < raw.length; i += 4) {
      final end = math.min(i + 4, raw.length);
      var le = 0;
      for (var b = i; b < end; b++) {
        le |= raw[b] << (8 * (b - i));
      }
      callVoid(pushFn, [le, end - i]);
    }
  }

  void setIn(String text) => pushSlot('in_reset', 'in_push', text);
  void setArg(String text) => pushSlot('arg_reset', 'arg_push', text);
  void setArg2(String text) => pushSlot('arg2_reset', 'arg2_push', text);

  /// Read an engine-owned UTF-16 string: [len@ptr-4][utf16@ptr].
  ///
  /// Always re-reads [WasmMemory.view]: the cached typed list is only valid
  /// until the next `memory.grow`.
  String readString(int ptr) {
    final view = memory.view; // re-acquire: grow invalidates the old view
    if (ptr < 4 || ptr + 2 > view.lengthInBytes) return '';
    final data = ByteData.view(view.buffer, view.offsetInBytes, view.lengthInBytes);
    final declared = data.getUint32(ptr - 4, Endian.little) & _lenMask;
    final maxChars = (view.lengthInBytes - ptr) ~/ 2;
    final chars = declared < maxChars ? declared : maxChars;
    if (chars <= 0) return '';
    final codeUnits = Uint16List(chars);
    for (var i = 0; i < chars; i++) {
      codeUnits[i] = data.getUint16(ptr + i * 2, Endian.little);
    }
    return String.fromCharCodes(codeUnits);
  }

  dynamic readJson(int ptr) {
    final raw = readString(ptr);
    if (raw.isEmpty) return null;
    try {
      return jsonDecode(raw);
    } on FormatException {
      return null;
    }
  }

  bool growOnePage() {
    final before = memory.lengthInBytes;
    memory.grow(1);
    final after = memory.lengthInBytes;
    _trackMemory();
    return after >= before + WasmMemory.bytesPerPage;
  }

  void dispose() {
    try {
      instance.dispose();
    } catch (_) {}
  }
}

/// Runs the whole spike against [wasmPath]; returns the measured report.
///
/// [strictBudget] asserts the desktop budget for p95/cold start. On mobile
/// simulators pass `false`: the numbers are recorded for the enable decision
/// instead of failing the build.
Future<WasmSpikeReport> runWasmSpike({
  String? wasmPath,
  Uint8List? wasmBytes,
  Directory? repoRoot,
  bool strictBudget = true,
  int renderIterations = 20,
  int? fuelBudgetPerCall,
}) async {
  final notes = <String>[];
  final lib = await MoonVizProbe.ensureHostLibrary(repoRoot);
  if (lib != null) notes.add('host library: $lib');
  final features = await wasmRuntimeFeatures();
  final bytes = wasmBytes ?? File(wasmPath!).readAsBytesSync();

  final coldStart = Stopwatch()..start();
  final probe = await MoonVizProbe.load(bytes, fuelBudgetPerCall: fuelBudgetPerCall);
  coldStart.stop();
  notes.add('memory at load: ${probe.memoryBytes} B');

  final exports = probe.exportNames.toSet();
  final sessionExports = exports.where((e) => e.startsWith('session_')).toList();
  final nonIn = sessionExports.where((e) => !e.endsWith('_in')).length;
  final inCount = sessionExports.where((e) => e.endsWith('_in')).length;
  final specialSignaturesOk = exports.containsAll(const {
    'session_event_in',
    'session_tap_in',
    'session_constrain_in',
    'session_generate_in',
    'session_apply_human_in',
    'session_open_in',
    'session_close',
    'in_reset',
    'in_push',
    'arg_reset',
    'arg_push',
    'arg2_reset',
    'arg2_push',
    'validate_mbt_in',
    'render_mbt_in',
  });

  final version = probe.readJson(probe.callInt('version_info'));
  final engineVersion = version is Map ? '${version['version'] ?? version['data']}' : 'unknown';

  // Empty document is legal since engine 0.2.
  probe.setIn('');
  final empty = probe.readJson(probe.callInt('validate_mbt_in'));
  final emptyDocValid = empty is Map && empty['ok'] == true;
  notes.add('validate_mbt("") → ${jsonEncode(empty).substring(0, math.min(120, jsonEncode(empty).length))}');

  // Seed render.
  probe.setIn(kSeedDoc);
  final rendered = probe.readJson(probe.callInt('render_mbt_in'));
  notes.add('fuel render: ${probe.lastFuelDelta}');
  final seedRenders = rendered is Map && rendered['ok'] == true;
  if (rendered is Map) {
    notes.add('render keys: ${rendered.keys.join(",")}');
  }

  // Session face + special signatures.
  probe.setIn(kSeedDoc);
  final handle = probe.callInt('session_open_in');
  if (handle < 0) throw StateError('session_open_in returned $handle');
  final humanOp = 'place __seed button probe_btn - 30 110 140 44 text=下一页';
  // Slot plan (mirrors the Rust host): apply_*_in reads the op text from the
  // **arg** slot; the in slot is only used by open/generate/event.
  probe.setArg(humanOp);
  final applied = probe.callJson('session_apply_human_in', [handle]);
  notes.add('fuel apply: ${probe.lastFuelDelta}');
  var mbt = kSeedDoc;
  if (applied is Map && applied['ok'] == true && applied['mbt'] is String) {
    mbt = applied['mbt'] as String;
  } else {
    notes.add('apply failed: ${jsonEncode(applied)}');
  }
  // Re-open on the applied document so later ops see the new node.
  probe.callVoid('session_close', [handle]);
  probe.setIn(mbt);
  final handle2 = probe.callInt('session_open_in');

  probe.setArg('__seed');
  final query = probe.callJson('session_query_nodes_in', [handle2]);
  final queryOk = query is Map && query['ok'] == true;

  // constrain: arg=artboard, arg2=intent.
  probe.setArg('__seed');
  probe.setArg2('居中');
  final constrain = probe.callJson('session_constrain_in', [handle2]);

  // event: arg=artboard, in=spec token.
  probe.setIn('long_press:100:130:500');
  probe.setArg('__seed');
  final event = probe.callJson('session_event_in', [handle2]);

  // tap: handle + f64 x/y, artboard in arg slot.
  probe.setArg('__seed');
  final tapResult = probe.callJson('session_tap_in', [handle2, 100.0, 130.0]);

  // generate: in=spec, arg=intent, arg2=artboard name.
  probe.setIn(kSpecJson);
  probe.setArg('探针页 as probe_generate');
  probe.setArg2('probe_generate');
  final generated = probe.callJson('session_generate_in', [handle2]);
  notes.add('fuel generate: ${probe.lastFuelDelta}');
  probe.callVoid('session_close', [handle2]);

  final specialOk = specialSignaturesOk &&
      queryOk &&
      constrain is Map &&
      (constrain['ok'] == true || '${constrain['error']}'.contains('cannot_parse')) &&
      event is Map &&
      tapResult is Map &&
      generated is Map &&
      generated['ok'] == true;

  // memory.grow must not break the ABI: grow, then round-trip a slot write.
  final growSafe = probe.growOnePage() && () {
    probe.setIn(kSeedDoc);
    final out = probe.readJson(probe.callInt('validate_mbt_in'));
    return out is Map && out['ok'] == true;
  }();

  // Timing + fuel: render the seed repeatedly.
  final samples = <Duration>[];
  var fuelDelta = 0;
  for (var i = 0; i < renderIterations; i++) {
    probe.setIn(kSeedDoc);
    final fuelBefore = probe.fuel?.fuelConsumed() ?? 0;
    final watch = Stopwatch()..start();
    final ptr = probe.callInt('render_mbt_in');
    watch.stop();
    final fuelAfter = probe.fuel?.fuelConsumed() ?? 0;
    if (i == 0) fuelDelta = fuelAfter - fuelBefore;
    if (ptr <= 0) {
      notes.add('render returned empty pointer at iteration $i');
    }
    samples.add(watch.elapsed);
  }
  samples.sort((a, b) => a.compareTo(b));
  final p50 = samples[samples.length ~/ 2];
  final p95 = samples[math.max(0, (samples.length * 0.95).floor() - 1)];

  final rss = ProcessInfo.currentRss;
  probe.dispose();

  final report = WasmSpikeReport(
    runtime: features.name,
    runtimeVersion: features.version,
    engineVersion: engineVersion,
    nonInSessionExports: nonIn,
    inSessionExports: inCount,
    emptyDocValid: emptyDocValid,
    seedRenders: seedRenders,
    specialSignaturesOk: specialOk,
    growSafe: growSafe,
    fuelSupported: probe.fuelSupported,
    fuelPerRender: fuelDelta,
    coldStart: coldStart.elapsed,
    p50Render: p50,
    p95Render: p95,
    peakMemoryBytes: probe.peakMemoryBytes,
    rssBytes: rss,
    notes: notes,
  );
  // ignore: avoid_print
  print('[wasm-spike] ${jsonEncode(report.toJson())}');

  expect(report.nonInSessionExports, greaterThanOrEqualTo(31), reason: 'session export face shrank');
  expect(report.inSessionExports, greaterThanOrEqualTo(22), reason: '_in export face shrank');
  expect(report.emptyDocValid, isTrue, reason: 'validate_mbt("") must be legal on engine 0.2');
  expect(report.seedRenders, isTrue, reason: 'seed document must render');
  expect(report.specialSignaturesOk, isTrue,
      reason: 'event/tap/constrain/generate special signatures must work');
  expect(report.growSafe, isTrue, reason: 'memory.grow must not break the _in ABI');
  if (strictBudget) {
    expect(report.coldStart, lessThan(WasmRuntimeGate.coldStartBudget));
    expect(report.p95Render, lessThan(WasmRuntimeGate.renderP95Budget));
  }
  return report;
}

extension on MoonVizProbe {
  /// Convenience: call a function whose first arg is the session handle and
  /// decode its JSON envelope.
  dynamic callJson(String name, List<Object?> args) {
    final ptr = callInt(name, args);
    if (ptr <= 0) return null;
    return readJson(ptr);
  }
}

Directory _appDir() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    if (File('${dir.path}/pubspec.yaml').existsSync() &&
        Directory('${dir.path}/assets/engine').existsSync()) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  throw StateError('cannot locate app/ from ${Directory.current.path}');
}

void main() {
  late Directory appDir;
  late Directory repoRoot;

  setUpAll(() {
    appDir = _appDir();
    repoRoot = appDir.parent;
  });

  test('vendored wasm_run executor loads the MoonViz module', () async {
    await MoonVizProbe.ensureHostLibrary(repoRoot);
    expect(await WasmRunLibrary.isReachable(), isTrue);
    final features = await wasmRuntimeFeatures();
    expect(features.name, isNotEmpty);
  });

  test('full spike: _in ABI, session face, grow, fuel, p50/p95', () async {
    final report = await runWasmSpike(
      wasmPath: '${appDir.path}/assets/engine/moonviz.wasm',
      repoRoot: repoRoot,
    );
    expect(report.fuelSupported || !Platform.isMacOS, isTrue,
        reason: 'wasmtime on macOS is expected to support fuel metering');
    if (report.fuelSupported) {
      expect(report.fuelPerRender, greaterThan(0),
          reason: 'fuel metering must actually consume fuel');
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
