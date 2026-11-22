/// Build hook for the vendored `wasm_run` package.
///
/// The pub.dev release downloads its executor from GitHub at build time
/// (`BuildModeEnum.fetch` via `build_rust_binaries`, which pins `hooks ^1.0.0`
/// and therefore conflicts with mediapipe_core's `hooks >=2.0.0`). This hook
/// is written against hooks 2.x and copies a library from the vendored
/// directory instead:
///
///   libs/wasm_run_dart-dynamic-<rust-target>
///
/// Fetch/replace those files with `scripts/fetch_wasm_run_libs.sh` (sha256
/// pinned). Nothing here touches the network.
///
/// Optional override: `hooks.user_defines.wasm_run.libsPath` (a directory
/// relative to this package's root, or an absolute path).
library;

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

const _libraryName = 'wasm_run_dart';

/// Name of the code asset. Kept identical to the upstream hook
/// (`build_rust_binaries`' default) so FFI lookups and tooling stay aligned.
const _codeAssetName = 'src/rust/frb_generated.io.dart';

void main(List<String> args) => build(args, (input, output) async {
  if (!input.config.buildCodeAssets) {
    // Web / non-code build: the browser executor ships as Dart assets.
    return;
  }
  final code = input.config.code;
  final target = _rustTarget(code);
  final fileName = code.targetOS.dylibFileName(_libraryName);
  final source = _libsDirectory(input).resolve(_libraryName + '-dynamic-' + target);
  final sourceFile = File(source.toFilePath(windows: Platform.isWindows));
  if (!sourceFile.existsSync()) {
    throw UnsupportedError(
      'No vendored wasm_run library for $target.\n'
      '  expected: ${source.toFilePath(windows: Platform.isWindows)}\n'
      '  run: bash scripts/fetch_wasm_run_libs.sh --target $target',
    );
  }
  final destination = input.outputDirectory.resolve(fileName);
  await sourceFile.copy(destination.toFilePath(windows: Platform.isWindows));
  output.assets.code.add(
    CodeAsset(
      package: input.packageName,
      name: _codeAssetName,
      linkMode: DynamicLoadingBundled(),
      file: destination,
    ),
  );
  output.dependencies.add(source);
});

Uri _libsDirectory(BuildInput input) {
  final override = input.userDefines['libsPath'];
  if (override is String && override.isNotEmpty) {
    final uri = Uri.file(override, windows: Platform.isWindows);
    return uri.isAbsolute ? uri : input.packageRoot.resolve(override);
  }
  return input.packageRoot.resolve('libs/');
}

/// Mirrors `_asRustTarget` from build_rust_binaries 0.1.0, restricted to the
/// targets we vendor. Keeping the mapping explicit makes a missing asset fail
/// here with the target name instead of a generic lookup error.
String _rustTarget(CodeConfig code) {
  if (code.targetOS == OS.iOS &&
      code.targetArchitecture == Architecture.arm64 &&
      code.iOS.targetSdk == IOSSdk.iPhoneSimulator) {
    return 'aarch64-apple-ios-sim';
  }
  final key = (code.targetOS, code.targetArchitecture);
  if (key == (OS.android, Architecture.arm)) return 'armv7-linux-androideabi';
  if (key == (OS.android, Architecture.arm64)) return 'aarch64-linux-android';
  if (key == (OS.android, Architecture.ia32)) return 'i686-linux-android';
  if (key == (OS.android, Architecture.x64)) return 'x86_64-linux-android';
  if (key == (OS.iOS, Architecture.arm64)) return 'aarch64-apple-ios';
  if (key == (OS.iOS, Architecture.x64)) return 'x86_64-apple-ios';
  if (key == (OS.linux, Architecture.arm)) return 'armv7-unknown-linux-gnueabihf';
  if (key == (OS.linux, Architecture.arm64)) return 'aarch64-unknown-linux-gnu';
  if (key == (OS.linux, Architecture.riscv64)) return 'riscv64gc-unknown-linux-gnu';
  if (key == (OS.linux, Architecture.x64)) return 'x86_64-unknown-linux-gnu';
  if (key == (OS.macOS, Architecture.arm64)) return 'aarch64-apple-darwin';
  if (key == (OS.macOS, Architecture.x64)) return 'x86_64-apple-darwin';
  if (key == (OS.windows, Architecture.arm64)) return 'aarch64-pc-windows-msvc';
  if (key == (OS.windows, Architecture.x64)) return 'x86_64-pc-windows-msvc';
  throw UnsupportedError(
    'No vendored wasm_run library for ${code.targetOS.name}/${code.targetArchitecture.name}.',
  );
}
