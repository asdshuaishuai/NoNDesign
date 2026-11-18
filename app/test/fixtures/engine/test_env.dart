/// Shared helpers for the engine tests (batch 02).
///
/// Kept out of `lib/` on purpose: the executor library is resolved from the
/// vendored dev tree, and fixture modules are generated (see
/// `wasm_fixtures.dart`).
library;

import 'dart:io';
import 'dart:typed_data';

// ignore: depend_on_referenced_packages
import 'package:wasm_run/wasm_run.dart';

import 'package:nondesign/core/engine/engine_host.dart';
import 'package:nondesign/core/engine/engine_worker.dart';

/// Walks up from the current directory until it finds `app/pubspec.yaml`.
Directory appDir() {
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

/// The bundled engine artifact (805,952 B on the 0.2-dev build line).
Uint8List engineBytes() => File('${appDir().path}/assets/engine/moonviz.wasm').readAsBytesSync();

/// Registers the vendored executor library once per isolate.
///
/// `flutter test` runs outside the app bundle, so the library is not on the
/// loader path; [EngineLibraryResolver] finds the vendored copy.
bool _libraryReady = false;
Future<void> ensureExecutor() async {
  if (_libraryReady) return;
  final path = EngineLibraryResolver.resolve();
  if (path == null) {
    await WasmRunLibrary.setUp();
  } else {
    await WasmRunLibrary.setUp(lib: ExternalLibrary.open(path));
  }
  _libraryReady = true;
}

/// Loads the real engine into a core on the **test** isolate (no worker).
///
/// Use this only for ABI-level assertions; anything that should prove the
/// production path must go through [EngineHost]/`EngineService`.
Future<EngineWasmCore> loadEngineCore({
  EngineCoreOptions options = const EngineCoreOptions(),
}) async {
  await ensureExecutor();
  return EngineWasmCore.load(engineBytes(), options: options);
}

/// Seed document — byte-for-byte the shape the Python host and the sync probe
/// use. Engine 0.2 also accepts the empty document, so the seed is only a
/// convenient starting point.
const String seedDoc = '---\nmoonviz:\n  format: visual-document\n  revision: 1\n  entry: __seed\n---\n\n'
    '# __seed\n\n'
    '<!-- moonviz:artboard __seed -->\n'
    '```mbt\n'
    'fn visual___seed() -> @decl.Prototype {\n'
    '  let page = @decl.prototype(name="__seed", width=390.0, height=844.0)\n'
    '  page\n'
    '}\n'
    '```\n';

/// Complete design spec (a bare `{"style":…}` is silently ignored by 0.2).
const String specJson = '{"v":1,"style":"apple",'
    '"palette":{"primary":"#2F6B4F","background":"#FFFFFF","surface":"#F2F7F4",'
    '"text":"#14201A","muted":"#5F7A6B","danger":"#DC2626","success":"#16A34A"},'
    '"typography":{"h1":30,"body":14,"caption":12},'
    '"spacing":[4,8,12,16,24,32],'
    '"radius":{"sm":8,"md":12,"lg":16}}';

/// A page with one button — the "small representative page" used for the p95
/// budgets. Returns the new canonical document.
Future<String> seedWithButton(EngineWasmCore core, {String id = 'probe_btn'}) async {
  final applied = await core.apply(
    seedDoc,
    'place __seed button $id - 30 110 140 44 text=下一页',
  );
  final mbt = applied['mbt'];
  if (applied['ok'] != true || mbt is! String) {
    throw StateError('seed button apply failed: $applied');
  }
  return mbt;
}
