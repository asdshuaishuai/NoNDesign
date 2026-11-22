// 诊断脚本（不进运行时）：对 vendored DLL 复现 fuel 陷阱行为。
// 用法：cd app && dart run tool/fuel_probe.dart [budget]
// 判据：
//   * 数秒内捕获「fuel」字样异常 → 执行器 fuel 陷阱健康（macOS 形态）。
//   * 永不返回（脚本挂死）→ Windows 执行器 fuel 不生效，死循环无界。
//   * 捕获 panic 形态异常 → 陷阱以 panic 展开（补丁应把它转成 Err）。
import 'dart:async';
import 'dart:io';

// ignore: depend_on_referenced_packages
import 'package:wasm_run/wasm_run.dart';

import '../test/fixtures/engine/wasm_fixtures.dart';

Future<void> main(List<String> args) async {
  final budget = args.isNotEmpty
      ? int.parse(args.first)
      : 500000000; // kEngineDefaultFuelPerCall
  final sw = Stopwatch()..start();
  // dev 树：vendored 执行器在 third_party/wasm_run/libs（与 EngineLibraryResolver 同源）。
  final dll = File('../third_party/wasm_run/libs/'
      'wasm_run_dart-dynamic-x86_64-pc-windows-msvc.dll');
  await WasmRunLibrary.setUp(
      lib: ExternalLibrary.open(dll.absolute.path));
  final module = await compileWasmModule(
    buildFixtureModule(),
    config: const ModuleConfig(consumeFuel: true),
  );
  stdout.writeln('[probe] compiled in ${sw.elapsedMilliseconds}ms');
  final builder = module.builder();
  final builderFuel = builder.fuel();
  builderFuel?.addFuel(budget);
  final instance = await builder.build();
  final fuel = instance.fuel();
  stdout.writeln('[probe] fuel handle: $fuel');
  if (fuel == null) {
    stdout.writeln('[probe] VERDICT: 执行器未暴露 fuel —— 计量不生效，死循环无界');
    exit(2);
  }
  stdout.writeln(
      '[probe] fuel added=${fuel.fuelAdded()} consumed=${fuel.fuelConsumed()}');
  final fn = instance.getFunction('spin');
  if (fn == null) {
    stdout.writeln('[probe] spin 导出不存在');
    exit(2);
  }
  final callSw = Stopwatch()..start();
  try {
    final out = fn(const []);
    stdout.writeln(
        '[probe] spin 正常返回（不该发生）out=$out consumed=${fuel.fuelConsumed()} '
        'in ${callSw.elapsedMilliseconds}ms');
    stdout.writeln('[probe] VERDICT: fuel 未拦截死循环（计量编译或扣减没生效）');
    exit(3);
  } catch (error) {
    stdout.writeln('[probe] spin 捕获异常 in ${callSw.elapsedMilliseconds}ms');
    stdout.writeln('[probe] type=${error.runtimeType}');
    stdout.writeln('[probe] detail=$error');
    final looksFuel = '$error'.toLowerCase().contains('fuel');
    stdout.writeln(
        '[probe] VERDICT: ${looksFuel ? "fuel 陷阱健康（macOS 形态）" : "陷阱形态异常（panic？）"}');
    exit(0);
  }
}
