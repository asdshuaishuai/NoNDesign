// Engine asset drift guard (batch 01).
//
// The Flutter app only reads `app/assets/engine/`; the canonical copies live
// in the repo-root `engine/`. `scripts/sync_engine.py` writes both and now also
// supports `--check`. This test is the second pair of eyes:
//
//   * `app/assets/engine/moonviz.wasm` must match its manifest sha512/bytes;
//   * `components.json` must match the manifest's component count and carry
//     unique ids;
//   * `app/assets/engine/*` must be byte-identical to `engine/*`;
//   * when the ENGINE_LOCAL marker points at a local dev build, that build's
//     sha512 must match the synced manifest — so "rebuild engine, forget to
//     sync" turns this test red (that is the required drift signal).
//
// The Python host is deliberately not used here: this test must run on any
// machine (and after server/ is retired).

import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

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
  fail('cannot locate app/ (cwd=${Directory.current.path})');
}

Directory _repoRoot(Directory appDir) => appDir.parent;

Future<String> _sha512Base64(List<int> bytes) async =>
    'sha512-${base64.encode((await Sha512().hash(bytes)).bytes)}';

void main() {
  final appDir = _appDir();
  final repoRoot = _repoRoot(appDir);
  final appAssets = Directory('${appDir.path}/assets/engine');
  final repoAssets = Directory('${repoRoot.path}/engine');

  late Map<String, dynamic> manifest;
  late List<int> wasm;
  late List<dynamic> components;

  setUpAll(() {
    final manifestFile = File('${appAssets.path}/manifest.json');
    expect(manifestFile.existsSync(), isTrue, reason: 'run: python3 scripts/sync_engine.py');
    manifest = jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>;
    wasm = File('${appAssets.path}/moonviz.wasm').readAsBytesSync();
    components = jsonDecode(File('${appAssets.path}/components.json').readAsStringSync()) as List<dynamic>;
  });

  test('wasm asset matches the manifest sha512 and byte count', () async {
    expect(manifest['bytes'], isA<int>());
    expect(manifest['sha512'], isA<String>());
    expect(wasm.length, manifest['bytes'],
        reason: 'app/assets/engine/moonviz.wasm is a different size than the manifest');
    expect(await _sha512Base64(wasm), manifest['sha512'],
        reason: 'app/assets/engine/moonviz.wasm does not match the manifest hash — re-run scripts/sync_engine.py');
    // A classic wasm module starts with \0asm + version 1.
    expect(wasm.take(4).toList(), [0x00, 0x61, 0x73, 0x6d]);
    expect(wasm[4] | wasm[5] << 8 | wasm[6] << 16 | wasm[7] << 24, 1);
  });

  test('component snapshot matches the manifest and has unique ids', () {
    final ids = <String>[];
    for (final entry in components) {
      expect(entry, isA<Map>(), reason: 'components.json must be a list of objects');
      final id = (entry as Map)['id'];
      expect(id, isA<String>());
      ids.add(id as String);
    }
    expect(ids.length, manifest['components'], reason: 'component count drifted from the manifest');
    expect(ids.toSet().length, ids.length, reason: 'duplicate component ids in components.json');
    expect(manifest['templates'], greaterThanOrEqualTo(15));
  });

  test('app assets are a byte-identical mirror of engine/', () {
    for (final pair in [
      ('moonviz.wasm', 'moonviz.wasm'),
      ('manifest.json', 'manifest.json'),
      ('components.json', 'components.json'),
    ]) {
      final canonical = File('${repoAssets.path}/${pair.$1}');
      final mirrored = File('${appAssets.path}/${pair.$2}');
      expect(canonical.existsSync(), isTrue, reason: 'missing canonical ${canonical.path}');
      expect(mirrored.readAsBytesSync(), canonical.readAsBytesSync(),
          reason: '${pair.$2} drifted from engine/${pair.$1} — re-run scripts/sync_engine.py');
    }
  });

  test('ENGINE_LOCAL rebuild without resync turns this test red', () async {
    // The marker is gitignored; its content is the local build path used by the
    // last `--local` sync (relative to the repo root).
    final marker = File('${repoAssets.path}/ENGINE_LOCAL');
    if (!marker.existsSync()) {
      // ignore: avoid_print
      print('[engine-drift] no ENGINE_LOCAL marker; skipping local-build pin check');
      return;
    }
    final text = marker.readAsStringSync().trim();
    if (text.isEmpty) {
      // ignore: avoid_print
      print('[engine-drift] empty ENGINE_LOCAL marker; skipping local-build pin check');
      return;
    }
    final local = File(text).existsSync() ? File(text) : File('${repoRoot.path}/$text');
    if (!local.existsSync()) {
      // ignore: avoid_print
      print('[engine-drift] local build missing (${local.path}); skipping pin check');
      return;
    }
    expect(await _sha512Base64(local.readAsBytesSync()), manifest['sha512'],
        reason: 'engine/ is stale against ${local.path} — re-run scripts/sync_engine.py '
            '(a fresh local build must change both engine/ and app/assets/engine/)');
  });
}
