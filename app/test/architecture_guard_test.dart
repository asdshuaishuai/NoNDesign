// Architecture guard (batch 01).
//
// Locks the seams this batch introduced so later batches cannot quietly
// re-break them:
//
//  * the capability/layout contract stays platform-pure (no dart:io, no
//    Flutter widgets) so it is unit-testable and cannot smuggle the engine in;
//  * `package:wasm_run` is only imported from `lib/core/engine/` (the Dart
//    engine host), never from UI code;
//  * the only wasm blob in the app is `assets/engine/moonviz.wasm`;
//  * required direct dependencies stay direct (path_provider in particular —
//    it used to be transitive only);
//  * `wasm_run` stays vendored (path override) with an offline, network-free
//    build hook and a full 15-target library set;
//  * `scripts/sync_engine.py` keeps the app-asset mirror and `--check`.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Directory _appDir() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    if (File('${dir.path}/pubspec.yaml').existsSync()) return dir;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  fail('cannot locate app/ from ${Directory.current.path}');
}

List<File> _dartFiles(Directory dir) => dir
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'))
    .toList(growable: false);

List<String> _imports(File file) {
  final text = file.readAsStringSync();
  final matches = RegExp(r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''', multiLine: true)
      .allMatches(text);
  return matches.map((m) => m.group(1)!).toList(growable: false);
}

/// Minimal top-level-section parser: returns `section -> [indent-2 keys]`.
Map<String, List<String>> _sections(String yaml) {
  final out = <String, List<String>>{};
  String? current;
  for (final raw in yaml.split('\n')) {
    final line = raw.trimRight();
    if (line.trim().isEmpty || line.trimLeft().startsWith('#')) continue;
    final indent = line.length - line.trimLeft().length;
    if (indent == 0 && line.endsWith(':')) {
      current = line.substring(0, line.length - 1).trim();
      out[current] = <String>[];
      continue;
    }
    if (current != null && indent == 2 && line.contains(':')) {
      out[current]!.add(line.trim().split(':').first.trim());
    }
  }
  return out;
}

void main() {
  final appDir = _appDir();
  final repoRoot = appDir.parent;
  final libDir = Directory('${appDir.path}/lib');
  final coreDir = Directory('${libDir.path}/core');

  group('capability/layout contract is platform-pure', () {
    for (final name in ['capability.dart', 'capability_hub.dart', 'layout.dart', 'platform_capabilities.dart']) {
      test('lib/core/$name avoids io/ffi/http and widget imports', () {
        final file = File('${coreDir.path}/$name');
        expect(file.existsSync(), isTrue);
        for (final import in _imports(file)) {
          expect(
            import.startsWith('dart:io') ||
                import.startsWith('dart:ffi') ||
                import.startsWith('dart:ui') ||
                import.startsWith('package:http') ||
                import.startsWith('package:wasm_run') ||
                import.startsWith('package:flutter/widgets') ||
                import.startsWith('package:flutter/material') ||
                import.startsWith('package:flutter/cupertino') ||
                import.startsWith('package:flutter/services'),
            isFalse,
            reason: '$name must stay pure; found import "$import"',
          );
        }
        // platform_capabilities is the adapter: foundation only.
        if (name == 'platform_capabilities.dart') {
          final flutterImports = _imports(file).where((i) => i.startsWith('package:flutter/'));
          expect(flutterImports, ['package:flutter/foundation.dart']);
        }
      });
    }
  });

  group('engine boundary', () {
    test('package:wasm_run is confined to lib/core/engine/', () {
      for (final file in _dartFiles(libDir)) {
        final rel = file.path.substring(libDir.path.length + 1);
        if (_imports(file).any((i) => i.startsWith('package:wasm_run'))) {
          expect(rel.startsWith('core/engine/'), isTrue,
              reason: 'wasm_run must only be imported by the Dart engine host, not $rel');
        }
      }
    });

    test('the only wasm blob in the app is assets/engine/moonviz.wasm', () {
      final wasm = Directory(appDir.path)
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) =>
              f.path.endsWith('.wasm') &&
              !f.path.contains('/build/') &&
              !f.path.contains('/.dart_tool/') &&
              !f.path.contains('/macos/') &&
              !f.path.contains('/ios/') &&
              !f.path.contains('/android/') &&
              !f.path.contains('/linux/') &&
              !f.path.contains('/windows/'))
          .map((f) => f.path.substring(appDir.path.length + 1))
          .toList();
      expect(wasm, ['assets/engine/moonviz.wasm']);
    });

    test('engine manifest is the 0.2-dev build line', () {
      final manifest = jsonDecode(File('${appDir.path}/assets/engine/manifest.json').readAsStringSync())
          as Map<String, dynamic>;
      expect(manifest['build_line'], '0.2-dev');
      expect(manifest['bytes'], 805952);
      expect(manifest['templates'], 17);
      expect(manifest['components'], 65);
    });
  });

  group('pubspec contract', () {
    late Map<String, List<String>> sections;
    late String pubspec;

    setUpAll(() {
      pubspec = File('${appDir.path}/pubspec.yaml').readAsStringSync();
      sections = _sections(pubspec);
    });

    test('required capabilities are direct dependencies', () {
      final deps = sections['dependencies'] ?? const <String>[];
      for (final name in ['cryptography', 'sqlite3', 'sqlite3_flutter_libs', 'wasm_run_flutter', 'path_provider']) {
        expect(deps, contains(name), reason: '$name must be a direct main dependency');
      }
    });

    test('wasm_run is a path override into third_party/wasm_run', () {
      expect(sections['dependency_overrides'], contains('wasm_run'));
      expect(
        RegExp(r'wasm_run:\s*\n\s*path:\s*(\S+)').firstMatch(pubspec)?.group(1),
        '../third_party/wasm_run',
      );
      expect(Directory('${repoRoot.path}/third_party/wasm_run').existsSync(), isTrue);
    });

    test('the engine asset directory is bundled', () {
      expect(pubspec, contains('- assets/engine/'));
      expect(pubspec, contains('- assets/models.json'));
    });
  });

  group('vendored wasm_run stays offline', () {
    final vendor = Directory('${repoRoot.path}/third_party/wasm_run');

    test('build hook has no network or build_rust_binaries dependency', () {
      // Comments may explain the upstream hook; only executable code counts.
      final hook = File('${vendor.path}/hook/build.dart')
          .readAsLinesSync()
          .where((line) => !line.trimLeft().startsWith('//'))
          .join('\n');
      for (final banned in [
        "package:build_rust_binaries",
        'BuildModeEnum',
        'HttpClient',
        'http://',
        'https://',
        'Uri.parse',
      ]) {
        expect(hook.contains(banned), isFalse, reason: 'hook must stay offline: found "$banned"');
      }
      final pubspec = File('${vendor.path}/pubspec.yaml')
          .readAsLinesSync()
          .where((line) => !line.trimLeft().startsWith('#'))
          .join('\n');
      expect(pubspec.contains('build_rust_binaries'), isFalse);
      expect(pubspec.contains('version: 0.2.0+2'), isTrue);
    });

    test('all 15 target libraries are vendored', () {
      final libs = Directory('${vendor.path}/libs');
      expect(libs.existsSync(), isTrue, reason: 'run scripts/fetch_wasm_run_libs.sh');
      final names = libs.listSync().whereType<File>().map((f) => f.uri.pathSegments.last).toSet();
      expect(names.length, 15);
      for (final target in [
        'aarch64-apple-darwin',
        'x86_64-apple-darwin',
        'aarch64-apple-ios',
        'aarch64-apple-ios-sim',
        'aarch64-linux-android',
        'x86_64-linux-android',
        'aarch64-unknown-linux-gnu',
        'x86_64-unknown-linux-gnu',
        'x86_64-pc-windows-msvc',
      ]) {
        expect(names, contains('wasm_run_dart-dynamic-$target'));
      }
    });

    test('the fetch script pins the same version as the vendored package', () {
      final script = File('${repoRoot.path}/scripts/fetch_wasm_run_libs.sh').readAsStringSync();
      expect(script.contains('PKG_VERSION="0.2.0+2"'), isTrue);
      expect(script.contains('--check'), isTrue);
      expect(script.contains('wasm_run_dart-dynamic-aarch64-apple-ios'), isTrue);
    });
  });

  group('engine sync script', () {
    test('mirrors into app/assets/engine and supports --check', () {
      final script = File('${repoRoot.path}/scripts/sync_engine.py').readAsStringSync();
      expect(script.contains('APP_ENGINE_DIR'), isTrue);
      expect(script.contains('mirror_to_app()'), isTrue);
      expect(script.contains('--check'), isTrue);
    });
  });
}
