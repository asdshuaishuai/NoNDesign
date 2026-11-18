// Device spike for the in-process design engine (batch 01).
//
// Runs the exact same probe as test/wasm_run_spike_test.dart on a real
// simulator/device, using the bundled asset (`assets/engine/moonviz.wasm`) and
// the platform executor from the vendored wasm_run package:
//
//   iOS              → wasmi 0.31
//   Android arm64    → wasmtime 14
//   macOS/Linux/Win  → wasmtime 14
//
// Gate (batch 01): 31 non-`_in` session exports, the event/tap/constrain/
// generate special signatures, `validate_mbt('')` legal, the seed renders,
// memory.grow safe. p50/p95 and memory are printed for the product decision —
// they are not asserted on mobile (WasmRuntimeGate.mobileLocalEngineEnabled
// stays false until iOS *and* Android pass, and Android cannot be built yet).
//
// Run: cd app && flutter test integration_test/wasm_spike_test.dart -d <device-id>

import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/wasm_run_spike_test.dart' as spike;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('wasm_run loads MoonViz and drives the _in contract on device', (tester) async {
    final data = await rootBundle.load('assets/engine/moonviz.wasm');
    final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    expect(bytes.length, greaterThan(700000), reason: 'bundled engine asset looks truncated');

    try {
      final report = await spike.runWasmSpike(
        wasmBytes: bytes,
        repoRoot: Directory.current,
        strictBudget: false, // record mobile numbers; do not gate yet
        renderIterations: 10,
      );

      // ignore: avoid_print
      print('[wasm-spike-device] ${report.toJson()}');
      expect(report.emptyDocValid, isTrue);
      expect(report.seedRenders, isTrue);
      expect(report.specialSignaturesOk, isTrue);
      expect(report.growSafe, isTrue);
    } catch (error) {
      // Known, evidence-backed platform limit (batch 01): iOS uses wasmi 0.31,
      // which cannot validate the SIMD instructions MoonViz is compiled with.
      // Recorded instead of faked: iOS must use 连接桌面 for now. Any other
      // failure is a real regression and rethrows.
      if ('$error'.contains('SIMD support is not enabled')) {
        // ignore: avoid_print
        print('[wasm-spike-device] cannot-do: wasmi has no SIMD — iOS local engine unavailable');
        markTestSkipped(
          '本地设计引擎在 iOS 上不可用：wasmi 0.31 不支持 MoonViz 使用的 SIMD 指令；'
          'iOS 只能使用「连接桌面」。见 docs/wasm-run-vendoring.md §7。',
        );
        return;
      }
      rethrow;
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
