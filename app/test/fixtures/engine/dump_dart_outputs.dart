/// Dumps the Dart engine host's envelopes for the parity cases.
///
/// Used by `scripts/wf/engine_parity.py` to compare the Dart host against the
/// Python reference host (`server/engine.py`) field by field. Runs under plain
/// `dart` — the engine layer is Flutter-free on purpose, so no widget binding
/// is needed:
///
/// ```bash
/// dart --packages=app/.dart_tool/package_config.json \
///   app/test/fixtures/engine/dump_dart_outputs.dart \
///   --cases app/test/fixtures/engine/cases.json \
///   --wasm app/assets/engine/moonviz.wasm \
///   --out /tmp/dart-engine-dump.json
/// ```
///
/// One fresh core per case keeps the comparison order-independent: no session
/// cache, revision counter or memory state leaks between cases.
library;

import 'dart:convert';
import 'dart:io';

// ignore: depend_on_referenced_packages
import 'package:wasm_run/wasm_run.dart';

import 'package:nondesign/core/engine/engine_host.dart' show EngineLibraryResolver;
import 'package:nondesign/core/engine/engine_worker.dart';

Future<void> main(List<String> args) async {
  final options = _parseArgs(args);
  final casesFile = File(options['cases']!);
  final wasmFile = File(options['wasm']!);
  final outFile = File(options['out']!);
  if (!casesFile.existsSync()) {
    stderr.writeln('cases file not found: ${casesFile.path}');
    exit(2);
  }
  if (!wasmFile.existsSync()) {
    stderr.writeln('engine artifact not found: ${wasmFile.path} '
        '(run: python3 scripts/sync_engine.py)');
    exit(2);
  }

  final libraryPath = EngineLibraryResolver.resolve(
    explicitPath: options['library'],
    startDirectory: wasmFile.parent.parent.parent.parent,
  );
  if (libraryPath != null) {
    await WasmRunLibrary.setUp(lib: ExternalLibrary.open(libraryPath));
  } else {
    await WasmRunLibrary.setUp();
  }

  final doc = jsonDecode(casesFile.readAsStringSync()) as Map<String, dynamic>;
  final seed = '${doc['seed'] ?? ''}';
  final spec = '${doc['spec'] ?? ''}';
  final cases = (doc['cases'] as List).cast<Map>();
  final wasm = wasmFile.readAsBytesSync();

  final results = <Map<String, dynamic>>[];
  for (final entry in cases) {
    final id = '${entry['id']}';
    final steps = entry['steps'] is List
        ? (entry['steps'] as List).cast<Map>()
        : <Map>[entry];
    final engine = await EngineWasmCore.load(wasm);
    var lastMbt = seed;
    final outputs = <Map<String, dynamic>>[];
    try {
      for (final step in steps) {
        final kind = '${step['kind']}';
        final mbt = _subst(step['mbt'], seed: seed, spec: spec, lastMbt: lastMbt);
        Map<String, dynamic> envelope;
        switch (kind) {
          case 'validate':
            envelope = await engine.validate(mbt);
            break;
          case 'render':
            envelope = await engine.render(mbt);
            break;
          case 'apply':
            envelope = await engine.apply(
              mbt,
              _subst(step['op'], seed: seed, spec: spec, lastMbt: lastMbt),
              gate: '${step['gate'] ?? 'human'}',
            );
            break;
          case 'session':
            envelope = await engine.session(
              mbt,
              '${step['name']}',
              step['arg'] == null
                  ? null
                  : _subst(step['arg'], seed: seed, spec: spec, lastMbt: lastMbt),
            );
            break;
          case 'generate':
            envelope = await engine.generate(
              mbt,
              _subst(step['intent'], seed: seed, spec: spec, lastMbt: lastMbt),
              '${step['name'] ?? ''}',
              _subst(step['spec'], seed: seed, spec: spec, lastMbt: lastMbt),
            );
            break;
          case 'tap':
            envelope = await engine.tap(
              mbt,
              '${step['artboard'] ?? ''}',
              (step['x'] as num?)?.toDouble() ?? 0,
              (step['y'] as num?)?.toDouble() ?? 0,
            );
            break;
          case 'constrain':
            envelope = await engine.constrain(
              mbt,
              '${step['artboard'] ?? ''}',
              _subst(step['intent'], seed: seed, spec: spec, lastMbt: lastMbt),
            );
            break;
          case 'event':
            envelope = await engine.event(
              mbt,
              '${step['artboard'] ?? ''}',
              '${step['spec'] ?? ''}',
            );
            break;
          case 'exportHtml':
            envelope = await engine.exportHtml(mbt);
            break;
          case 'listing':
            envelope = await engine.listing('${step['fn']}');
            break;
          case 'version':
            envelope = Map<String, dynamic>.from(engine.engineVersion);
            break;
          default:
            envelope = <String, dynamic>{
              'ok': false,
              'error': 'unknown_kind',
              'detail': kind,
            };
        }
        final canonical = envelope['mbt'];
        if (canonical is String && canonical.isNotEmpty) lastMbt = canonical;
        outputs.add(envelope);
      }
    } finally {
      engine.dispose();
    }
    results.add(<String, dynamic>{'id': id, 'steps': outputs});
  }

  outFile.parent.createSync(recursive: true);
  final runtime = await wasmRuntimeFeatures();
  outFile.writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
      'engine': <String, dynamic>{
        'runtime': '${runtime.name} ${runtime.version}',
        'cases': cases.length,
      },
      'cases': results,
    }),
  );
  stdout.writeln('dart engine dump: ${cases.length} cases -> ${outFile.path}');
}

String _subst(
  Object? value, {
  required String seed,
  required String spec,
  required String lastMbt,
}) {
  final text = '${value ?? ''}';
  return text
      .replaceAll(r'$seed', seed)
      .replaceAll(r'$spec', spec)
      .replaceAll(r'$lastMbt', lastMbt);
}

Map<String, String?> _parseArgs(List<String> args) {
  final out = <String, String?>{
    'cases': 'app/test/fixtures/engine/cases.json',
    'wasm': 'app/assets/engine/moonviz.wasm',
    'out': '${Directory.systemTemp.path}/nondesign-dart-engine-dump.json',
    'library': null,
  };
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    String? next() => i + 1 < args.length ? args[++i] : null;
    if (arg == '--cases') {
      out['cases'] = next();
    } else if (arg == '--wasm') {
      out['wasm'] = next();
    } else if (arg == '--out') {
      out['out'] = next();
    } else if (arg == '--library') {
      out['library'] = next();
    }
  }
  return out;
}
