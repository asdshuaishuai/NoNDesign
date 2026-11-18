// Engine host tests (batch 02).
//
// Proves the isolate-hosted engine behaves like the product needs, not just
// like the ABI:
//
//  * the UI isolate never blocks (a busy worker still lets timers run);
//  * 100 mixed render/apply calls stay under the 176 MiB memory cap with a
//    flat tail (no unbounded growth);
//  * crossing the recycle threshold rebuilds the instance and the engine keeps
//    working;
//  * a runaway call is stopped in ≤2 s — by fuel where the executor meters it,
//    by the isolate watchdog where it does not — and the instance/isolate is
//    rebuilt;
//  * the saturated call path stays within the plan's p95 budgets;
//  * the service facade exposes the same shapes the HTTP API did.

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nondesign/core/engine/engine_host.dart';
import 'package:nondesign/core/engine/engine_service.dart';
import 'package:nondesign/core/engine/engine_types.dart';
import 'package:nondesign/core/engine/engine_worker.dart';

import 'fixtures/engine/test_env.dart';
import 'fixtures/engine/wasm_fixtures.dart';

void main() {
  group('host lifecycle', () {
    test('starts, reports the artifact face and disposes idempotently', () async {
      final watch = Stopwatch()..start();
      final host = await EngineHost.start(wasmBytes: engineBytes());
      watch.stop();
      expect(watch.elapsed, lessThan(kEngineMobileFirstRenderBudget),
          reason: 'cold start was ${watch.elapsedMilliseconds}ms');

      final runtime = host.runtime;
      expect(runtime, isNotNull);
      expect(runtime!.exportCount, 78);
      expect(runtime.sessionExportCount, 53);
      expect(runtime.engineVersion, isNotEmpty);
      if (!runtime.fuelSupported) {
        fail('desktop executor must meter fuel; measured $runtime');
      }

      final exports = await host.exportNames();
      expect(exports.exports.length, 78);
      expect(exports.sessionExports.length, 53);

      await host.dispose();
      await host.dispose(); // idempotent
      final late = await host.render(seedDoc);
      expect(late['ok'], isFalse);
      expect(late['error'], EngineErrorCode.unavailable);
    });

    test('concurrent calls are serialised by the queue and all succeed', () async {
      final host = await EngineHost.start(wasmBytes: engineBytes());
      addTearDown(host.dispose);

      final futures = <Future<Map<String, dynamic>>>[
        for (var i = 0; i < 5; i++) host.render(seedDoc),
        for (var i = 0; i < 5; i++) host.session(seedDoc, 'session_list_artboards'),
      ];
      final results = await Future.wait(futures);
      expect(results.every((envelope) => envelope['ok'] == true), isTrue);
      final stats = await host.stats();
      expect(stats.calls, greaterThanOrEqualTo(10));
    });
  });

  group('performance budgets', () {
    test('first render fits the mobile first-frame budget; p95 fits render/apply budgets', () async {
      final start = Stopwatch()..start();
      final host = await EngineHost.start(wasmBytes: engineBytes());
      addTearDown(host.dispose);
      final first = await host.render(seedDoc);
      start.stop();
      expect(first['ok'], isTrue);
      expect(start.elapsed, lessThan(kEngineMobileFirstRenderBudget),
          reason: 'start + first render took ${start.elapsedMilliseconds}ms');

      final mbt = await seedWithButtonViaHost(host);

      final renderSamples = <Duration>[];
      for (var i = 0; i < 20; i++) {
        final watch = Stopwatch()..start();
        final envelope = await host.render(mbt);
        watch.stop();
        expect(envelope['ok'], isTrue);
        renderSamples.add(watch.elapsed);
      }

      final applySamples = <Duration>[];
      for (var i = 0; i < 20; i++) {
        final watch = Stopwatch()..start();
        final envelope = await host.apply(mbt, 'move __seed probe_btn ${i % 4} 0');
        watch.stop();
        expect(envelope['ok'], isTrue, reason: '$envelope');
        applySamples.add(watch.elapsed);
      }

      final renderP95 = percentile(renderSamples, 0.95);
      final applyP95 = percentile(applySamples, 0.95);
      // ignore: avoid_print
      print('[engine-budget] cold=${start.elapsedMilliseconds}ms '
          'render p50=${percentile(renderSamples, 0.5).inMilliseconds}ms '
          'p95=${renderP95.inMilliseconds}ms '
          'apply p50=${percentile(applySamples, 0.5).inMilliseconds}ms '
          'p95=${applyP95.inMilliseconds}ms');

      expect(renderP95, lessThan(kEngineMobileRenderP95Budget),
          reason: 'hot render p95 must fit the phone budget on desktop');
      expect(applyP95, lessThan(kEngineMobileApplyP95Budget),
          reason: 'apply p95 must fit the phone budget on desktop');
    });
  });

  group('memory', () {
    test('100 mixed render/apply calls stay far below 176 MiB with a flat tail', () async {
      final host = await EngineHost.start(wasmBytes: engineBytes());
      addTearDown(host.dispose);

      var mbt = await seedWithButtonViaHost(host);
      final sizes = <int>[];
      for (var i = 0; i < 100; i++) {
        final rendered = await host.render(mbt);
        expect(rendered['ok'], isTrue, reason: 'render $i: $rendered');
        if (i.isEven) {
          final applied = await host.apply(mbt, 'move __seed probe_btn ${i % 5} 0');
          expect(applied['ok'], isTrue, reason: 'apply $i: $applied');
          mbt = (applied['mbt'] as String?) ?? mbt;
        }
        final stats = await host.stats();
        sizes.add(stats.memoryBytes);
      }

      final maxBytes = sizes.reduce(math.max);
      // ignore: avoid_print
      print('[engine-memory] max=${maxBytes ~/ 1024}KiB first=${sizes.first ~/ 1024}KiB '
          'tail=${sizes.last ~/ 1024}KiB distinct=${sizes.toSet().length}');

      expect(maxBytes, lessThan(kEngineMemoryRecycleBytes),
          reason: 'memory crossed the 176 MiB recycle cap');
      // Warm-up may grow memory (the allocator is a bump allocator), but the
      // last half of the loop must not keep climbing.
      final tail = sizes.sublist(50);
      expect(tail.last, lessThanOrEqualTo(tail.first + 64 * 1024),
          reason: 'memory kept growing: first=${tail.first} last=${tail.last}');
    });

    test('a 70 KB document stays inside the scaled fuel budget', () async {
      final host = await EngineHost.start(wasmBytes: engineBytes());
      addTearDown(host.dispose);

      var mbt = seedDoc;
      for (var i = 0; i < 70; i++) {
        final applied = await host.apply(
          mbt,
          'place __seed button n$i - ${10 + (i % 5) * 74} ${40 + (i ~/ 5) * 36} 64 30 text=按钮$i',
        );
        expect(applied['ok'], isTrue, reason: 'apply $i failed: ${applied['error']}');
        mbt = applied['mbt'] as String;
      }
      expect(mbt.length, greaterThan(60000),
          reason: 'the point is a document large enough to exceed a fixed 500M budget');
      // ~7_500 fuel per byte on the worst call (apply): a fixed budget would
      // trap here, the scaled budget must not.
      final applied = await host.apply(mbt, 'move __seed n0 12 42');
      expect(applied['ok'], isTrue, reason: '${applied['error']}');
      final rendered = await host.render(mbt);
      expect(rendered['ok'], isTrue);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('crossing the recycle threshold rebuilds and the engine keeps working', () async {
      final host = await EngineHost.start(
        wasmBytes: engineBytes(),
        options: const EngineHostOptions(
          core: EngineCoreOptions(memoryRecycleBytes: 300 * 1024),
        ),
      );
      addTearDown(host.dispose);

      expect((await host.render(seedDoc))['ok'], isTrue);
      expect((await host.render(seedDoc))['ok'], isTrue);
      final stats = await host.stats();
      expect(stats.recycleCount, greaterThanOrEqualTo(1));
      expect(stats.instanceGeneration, greaterThan(1));
      expect(stats.memoryBytes, lessThan(kEngineMemoryRecycleBytes));

      // A recycled host re-opens its session transparently.
      final queried = await host.session(seedDoc, 'session_list_artboards');
      expect(queried['ok'], isTrue);
      final released = await host.recycle();
      expect(released.instanceGeneration, greaterThan(stats.instanceGeneration));
      expect((await host.render(seedDoc))['ok'], isTrue);
    });
  });

  group('runaway calls', () {
    test('fuel stops a spin loop within 2 s and rebuilds the instance', () async {
      final host = await EngineHost.start(
        wasmBytes: buildFixtureModule(),
        // Default fuel budget on purpose: the gate is "a runaway call is
        // stopped in ≤2 s", not "with a tiny budget".
        options: const EngineHostOptions(requireEngineAbi: false),
      );
      addTearDown(host.dispose);

      final watch = Stopwatch()..start();
      await expectLater(
        host.rawCall('spin'),
        throwsA(isA<EngineCallFailure>().having(
          (failure) => failure.code,
          'code',
          EngineErrorCode.fuelExhausted,
        )),
      );
      watch.stop();
      // ignore: avoid_print
      print('[engine-fuel] spin trap in ${watch.elapsedMilliseconds}ms');
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)),
          reason: 'fuel trap took ${watch.elapsedMilliseconds}ms');

      final stats = await host.stats();
      expect(stats.trapCount, greaterThanOrEqualTo(1));
      expect(stats.instanceGeneration, greaterThan(1));
      expect(await host.rawCall('busy', <Object?>[3]), 0,
          reason: 'the rebuilt instance must serve calls again');
    });

    test('the watchdog bounds a long call and the host recovers', () async {
      // No fuel metering here: the watchdog is the only bound. A finite long
      // call is used on purpose — an *infinite* call cannot be interrupted by
      // killing the isolate (Isolate.kill does not unwind the native frame),
      // so the executor stays busy until it returns. That is exactly why the
      // production host refuses to start a real engine without fuel.
      final host = await EngineHost.start(
        wasmBytes: buildFixtureModule(),
        options: const EngineHostOptions(
          requireEngineAbi: false,
          core: EngineCoreOptions(consumeFuel: false),
          callTimeout: Duration(milliseconds: 120),
          startTimeout: Duration(seconds: 20),
        ),
      );
      addTearDown(host.dispose);

      // `busy` takes an i32 counter; 2e9 is the largest safe count and costs
      // ~0.4 s on wasmtime — comfortably above the 120 ms watchdog even on a
      // machine several times faster than this one.
      const iterations = 2000000000;
      final calibration = Stopwatch()..start();
      await host.rawCall('busy', <Object?>[10000000]);
      calibration.stop();
      if (calibration.elapsedMicroseconds > 50000) {
        fail('calibration unexpectedly slow: ${calibration.elapsedMicroseconds}us for 1e7');
      }

      final watch = Stopwatch()..start();
      await expectLater(
        host.rawCall('busy', <Object?>[iterations]),
        throwsA(isA<EngineCallFailure>().having(
          (failure) => failure.code,
          'code',
          EngineErrorCode.timeout,
        )),
      );
      watch.stop();
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)),
          reason: 'the caller must be answered at the watchdog, not after recovery');
      expect(host.restartCount, greaterThanOrEqualTo(1));

      // Recovery completes once the abandoned native call returns.
      expect(await host.rawCall('busy', <Object?>[3]).timeout(const Duration(seconds: 30)), 0);
    }, timeout: const Timeout(Duration(seconds: 90)));
  });

  group('UI isolate', () {
    test('the main isolate keeps processing while the worker is busy', () async {
      final host = await EngineHost.start(
        wasmBytes: buildFixtureModule(),
        options: const EngineHostOptions(
          requireEngineAbi: false,
          // No fuel gate: the point is a long *bounded* call, not a runaway.
          core: EngineCoreOptions(consumeFuel: false),
        ),
      );
      addTearDown(host.dispose);

      // Calibrate a ~300 ms bounded call on this machine.
      final calibration = Stopwatch()..start();
      await host.rawCall('busy', <Object?>[10000000]);
      calibration.stop();
      final perIteration = calibration.elapsedMicroseconds / 10000000.0;
      final iterations = math.max(10000000,
          math.min(4000000000, (300000 / perIteration).round()));

      var ticks = 0;
      final timer = Timer.periodic(const Duration(milliseconds: 10), (_) => ticks++);
      final busy = host.rawCall('busy', <Object?>[iterations]);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      final ticksWhileBusy = ticks;
      await busy;
      timer.cancel();

      // ignore: avoid_print
      print('[engine-isolate] busy iterations=$iterations ticks=$ticksWhileBusy');
      expect(ticksWhileBusy, greaterThanOrEqualTo(5),
          reason: 'the UI isolate must keep its event loop while the engine works');
    });
  });

  group('service facade', () {
    test('exposes API-shaped calls over the in-process engine', () async {
      final service = await EngineService.start(wasmBytes: engineBytes());
      addTearDown(service.dispose);
      expect(service.isReady, isTrue, reason: service.startupError);
      expect(service.probeAvailability().isUsable, isTrue);

      expect(await service.templates(), hasLength(17));
      expect(await service.themes(), hasLength(13));
      expect(await service.ops(), hasLength(27));
      final tokens = await service.tokens();
      expect(tokens['colors'], isA<List>());
      expect((tokens['colors'] as List), isNotEmpty);
      expect(await service.components(), hasLength(65));

      final rendered = await service.render(seedDoc);
      expect(rendered['ok'], isTrue);
      expect((rendered['artboards'] as List), hasLength(1));

      final applied = await service.apply(
        seedDoc,
        'place __seed button svc_btn - 20 60 120 40 text=开始',
        gate: 'agent',
      );
      expect(applied['ok'], isTrue, reason: '$applied');
      final mbt = applied['mbt'] as String;

      final queried = await service.session(mbt, 'session_query_nodes', '__seed');
      expect(queried['ok'], isTrue);
      final events = await service.event(mbt, '__seed', 'key_enter');
      expect(events['ok'], isTrue);
      final tapped = await service.tap(mbt, '__seed', 40, 80);
      expect(tapped['ok'], isTrue);
      final constrained = await service.constrainIntent(mbt, '__seed', '居中');
      expect(constrained['ok'], isTrue);
      final history = await service.history(seedDoc, 'init __seed');
      expect(history['ok'], isTrue);

      final version = await service.versionInfo();
      expect(version['engine'], 'moonviz');
    });

    test('an unavailable service answers engine_unavailable instead of throwing', () async {
      final service = EngineService.unavailable('executor missing');
      expect(service.isReady, isFalse);
      expect(service.probeAvailability().isUsable, isFalse);
      final rendered = await service.render(seedDoc);
      expect(rendered['ok'], isFalse);
      expect(rendered['error'], EngineErrorCode.unavailable);
      expect(await service.templates(), isEmpty);
      await service.dispose();
    });

    test('a failed first start can be retried once the cause is fixed', () async {
      final valid = engineBytes();
      final broken = Uint8List.fromList(valid)..[1] = 0; // magic is 00 61 73 6d
      final service = await EngineService.start(wasmBytes: broken);
      addTearDown(service.dispose);

      expect(service.isReady, isFalse);
      expect(service.startupError, isNotNull,
          reason: 'the startup failure must be preserved for the surface');
      expect(await service.retryEngine(), isFalse, reason: 'still corrupt');
      expect(service.isReady, isFalse);

      broken.setAll(0, valid);
      expect(await service.retryEngine(), isTrue, reason: service.startupError);
      expect(service.isReady, isTrue);
      expect(service.startupError, isNull);
      final rendered = await service.render(seedDoc);
      expect(rendered['ok'], isTrue);
      expect(rendered['artboards'], hasLength(1));
    });
  });
}

/// Applies the seed button through the host and returns the canonical.
Future<String> seedWithButtonViaHost(EngineHost host) async {
  final applied = await host.apply(
    seedDoc,
    'place __seed button probe_btn - 30 110 140 44 text=下一页',
  );
  final mbt = applied['mbt'];
  if (applied['ok'] != true || mbt is! String) {
    throw StateError('seed button apply failed: $applied');
  }
  return mbt;
}

/// p-th percentile (0..1) of [samples], sorted in place.
Duration percentile(List<Duration> samples, double p) {
  final sorted = List<Duration>.from(samples)..sort((a, b) => a.compareTo(b));
  final index = math.max(0, (sorted.length * p).ceil() - 1);
  return sorted[index];
}
