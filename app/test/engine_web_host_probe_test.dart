/// Contract probe for the classic-wasm JS host used by [WebViewEngineHost].
///
/// The host script (`assets/engine/engine_web_host.js`) is dependency-free and
/// DOM-free, so Node can execute the exact same bytes the WebView executes.
/// This test keeps the ABI honest in CI without a display server; the real
/// WebView smoke is covered by integration tests/platform builds.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('classic wasm JS host passes the Node contract probe', () async {
    final probe = File('../scripts/engine_web_probe.mjs');
    if (!probe.existsSync()) {
      fail('probe script missing: ${probe.absolute.path}');
    }
    final nodeCheck = await Process.run('node', const ['--version']);
    if (nodeCheck.exitCode != 0) {
      markTestSkipped('node is not available; skip WebView engine JS probe');
      return;
    }

    final result = await Process.run(
      'node',
      [probe.path],
      workingDirectory: Directory.current.path,
      stdoutEncoding: SystemEncoding(),
      stderrEncoding: SystemEncoding(),
    ).timeout(const Duration(minutes: 2));

    expect(
      result.exitCode,
      0,
      reason: 'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
    );
    expect('${result.stdout}', contains('"ok": true'));
    expect('${result.stdout}', contains('"sessionExports": 53'));
    expect('${result.stdout}', contains('"engine": "moonviz"'));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
