// Engine contract tests (batch 02).
//
// Locks the byte-level contract the Dart host shares with the Python reference
// host (`server/engine.py`) and the Rust host before it:
//
//  * the artifact face — 78 exports, 31 non-`_in` session exports, 22 `_in`;
//  * the `in`/`arg`/`arg2` slot ABI (4-byte little-endian chunks + length);
//  * the UTF-16 read layout (`[len@ptr-4][UTF-16LE@ptr]`), including surrogate
//    pairs and the stale-view hazard after `memory.grow`;
//  * the canonical-document session cache (hit on same document, miss on a
//    different one, key updated by mutating envelopes, no arg-slot leakage);
//  * envelope shapes (`apply` carries `mbt` but no `render`; `render` carries
//    `artboards`), empty-document legality, trap recovery, memory recycling.
//
// Anything that can only be proven through the isolate host lives in
// `engine_host_test.dart`; dedicated slot layouts live in
// `session_signatures_test.dart`.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nondesign/core/engine/engine_types.dart';
import 'package:nondesign/core/engine/engine_worker.dart';

import 'fixtures/engine/test_env.dart';
import 'fixtures/engine/wasm_fixtures.dart';

void main() {
  group('artifact export face', () {
    late EngineWasmCore core;

    setUpAll(() async {
      core = await loadEngineCore();
    });

    tearDownAll(() => core.dispose());

    test('78 exports, 31 session exports, 22 _in exports', () {
      final exports = core.exportNames.toSet();
      expect(exports.length, 78, reason: 'engine 0.2-dev export face changed');
      final session = exports.where((name) => name.startsWith('session_')).toList();
      final direct = session.where((name) => !name.endsWith('_in')).toSet();
      final inFace = session.where((name) => name.endsWith('_in')).toSet();
      expect(direct.length, 31);
      expect(inFace.length, 22);
      expect(direct, kSessionExports.toSet(),
          reason: 'kSessionExports drifted from the artifact');
      expect(inFace, kSessionInExports.toSet(),
          reason: 'kSessionInExports drifted from the artifact');
    });

    test('every ABI export the host depends on is present', () {
      final exports = core.exportNames.toSet();
      final missing = kEngineAbiExports.where((name) => !exports.contains(name)).toList();
      expect(missing, isEmpty, reason: 'missing: $missing');
      for (final name in const ['in_len', 'arg_len']) {
        expect(exports, contains(name));
      }
    });

    test('session tables only name real exports', () {
      final direct = kSessionExports.toSet();
      for (final name in kSessionMutating) {
        expect(direct, contains(name), reason: '$name is not a session export');
      }
      for (final name in kSessionHandleOnly) {
        expect(direct, contains(name));
        expect(kSessionInExports, isNot(contains('${name}_in')),
            reason: 'handle-only sessions must not have an _in variant');
      }
      for (final name in kSessionSpecial) {
        expect(direct, contains(name));
        expect(kSessionInExports, contains('${name}_in'));
      }
      for (final name in kSessionUnsupportedSignatures) {
        expect(direct, contains(name));
      }
      expect(kSessionSpecial.intersection(kSessionHandleOnly), isEmpty);
      expect(kSessionMutating.intersection(kSessionUnsupportedSignatures), isEmpty);
    });

    test('engine self-reports as moonviz', () {
      expect(core.engineVersion['ok'], isTrue);
      expect(core.engineVersion['engine'], 'moonviz');
      expect('${core.engineVersion['version']}', isNotEmpty);
    });

    test('fuel metering is available on this executor', () async {
      final info = await core.runtimeInfo();
      expect(info.exportCount, 78);
      expect(info.sessionExportCount, 53);
      if (Platform.isMacOS || Platform.isLinux || Platform.isWindows) {
        expect(info.fuelSupported, isTrue,
            reason: 'wasmtime desktops must meter fuel; without it a runaway '
                'call can only be stopped by killing the isolate');
      }
    });
  });

  group('slot ABI', () {
    late EngineWasmCore core;

    setUpAll(() async {
      core = await loadEngineCore();
    });

    tearDownAll(() => core.dispose());

    test('in_len reports the byte length of the pushed UTF-8 payload', () async {
      // 4-byte chunks: 5 bytes = one full chunk + one 1-byte chunk.
      await core.validate('abcde');
      expect(await core.rawCall('in_len'), 5);
      await core.validate('abcdefgh');
      expect(await core.rawCall('in_len'), 8);
      await core.validate('');
      expect(await core.rawCall('in_len'), 0);
    });

    test('non-ASCII payloads round-trip through the chunked slot', () async {
      // "下一页按钮" is 15 UTF-8 bytes (not a multiple of 4): the final chunk
      // carries 3 valid bytes and the length field must say so.
      final applied = await core.apply(
        seedDoc,
        'place __seed button b1 - 30 110 140 44 text=下一页按钮',
      );
      expect(applied['ok'], isTrue, reason: '$applied');
      final mbt = applied['mbt'] as String;
      expect(mbt, contains('下一页按钮'));

      final queried = await core.session(mbt, 'session_query_nodes', '__seed');
      expect(queried['ok'], isTrue);
      final nodes = (queried['data'] as List).cast<Map>();
      final button = nodes.firstWhere((node) => node['id'] == 'b1');
      expect(button['text'], '下一页按钮');
    });

    test('a 1-byte payload works (single short chunk)', () async {
      // `validate_mbt` accepts arbitrary text as a document; the point here is
      // the slot chunking, not the document semantics.
      final out = await core.validate('x');
      expect(out, isA<Map<String, dynamic>>());
      expect(await core.rawCall('in_len'), 1);
    });

    test('arg slot is cleared by an explicit empty push (no leakage)', () async {
      final first = await core.session(seedDoc, 'session_query_nodes', '__seed');
      expect(first['ok'], isTrue);
      // Without the explicit empty push the previous artboard would leak and
      // this call would silently return __seed's nodes (Python documents the
      // same bug). The engine rejects an empty artboard instead.
      final second = await core.session(seedDoc, 'session_query_nodes');
      expect(second['ok'], isFalse);
      expect('${second['error'] ?? second['detail']}', contains('unknown_artboard'));
    });
  });

  group('UTF-16 read layout', () {
    late EngineWasmCore core;

    setUpAll(() async {
      core = await loadEngineCore();
    });

    tearDownAll(() => core.dispose());

    test('null and out-of-range pointers read as empty', () {
      expect(core.readString(0), '');
      expect(core.readString(-4), '');
      expect(core.readString(1 << 30), '');
    });

    test('surrogate pairs survive the read path', () async {
      final applied = await core.apply(
        seedDoc,
        'place __seed button b1 - 30 110 140 44 text=确认🎨',
      );
      expect(applied['ok'], isTrue, reason: '$applied');
      final mbt = applied['mbt'] as String;
      final queried = await core.session(mbt, 'session_query_nodes', '__seed');
      final nodes = (queried['data'] as List).cast<Map>();
      expect(nodes.firstWhere((node) => node['id'] == 'b1')['text'], '确认🎨');
    });

    test('memory.grow invalidates the cached view (stale view regression)', () async {
      final fixtureCore = await EngineWasmCore.loadRaw(buildFixtureModule());
      addTearDown(fixtureCore.dispose);

      // Prime a view before the grow, exactly like a caching host would.
      final before = fixtureCore.readString(kFixtureStringPtr);
      expect(before, '', reason: 'string lives in pages that do not exist yet');

      final ptr = await fixtureCore.rawCall('make_string');
      expect(ptr, kFixtureStringPtr);
      // A host that reused the pre-grow view would read freed/relocated memory
      // here; reading through the re-acquired view must see the string.
      expect(fixtureCore.readString(ptr), kFixtureString);
      final stats = fixtureCore.stats();
      expect(stats.memoryBytes, greaterThan(65536),
          reason: 'make_string must have grown linear memory');
    });
  });

  group('session cache', () {
    test('same canonical document hits the cache, a different one misses', () async {
      final core = await loadEngineCore();
      addTearDown(core.dispose);

      final a = await core.session(seedDoc, 'session_list_artboards');
      expect(a['ok'], isTrue);
      var stats = core.stats();
      expect(stats.sessionMisses, 1);
      expect(stats.sessionHits, 0);

      final b = await core.session(seedDoc, 'session_flows');
      expect(b['ok'], isTrue);
      stats = core.stats();
      expect(stats.sessionMisses, 1, reason: 'same document must reuse the handle');
      expect(stats.sessionHits, 1);

      final other = seedDoc.replaceFirst('width=390.0', 'width=391.0');
      final c = await core.session(other, 'session_list_artboards');
      expect(c['ok'], isTrue);
      stats = core.stats();
      expect(stats.sessionMisses, 2);
    });

    test('mutating sessions update the cache key to the returned canonical', () async {
      final core = await loadEngineCore();
      addTearDown(core.dispose);

      final applied = await core.session(
        seedDoc,
        'session_apply_human',
        'place __seed button b1 - 30 110 140 44 text=下一页',
      );
      expect(applied['ok'], isTrue, reason: '$applied');
      final mbt = applied['mbt'] as String;

      final queried = await core.session(mbt, 'session_query_nodes', '__seed');
      expect(queried['ok'], isTrue);
      final stats = core.stats();
      expect(stats.sessionHits, greaterThanOrEqualTo(1),
          reason: 'the canonical returned by a mutating call must hit the cache');
    });

    test('releaseMemory evicts the session and rebuilds', () async {
      final core = await loadEngineCore();
      addTearDown(core.dispose);

      await core.session(seedDoc, 'session_list_artboards');
      final before = core.stats();
      await core.releaseMemory();
      final after = core.stats();
      expect(after.instanceGeneration, greaterThan(before.instanceGeneration));
      expect(after.recycleCount, before.recycleCount + 1);
      await core.session(seedDoc, 'session_list_artboards');
      expect(core.stats().sessionMisses, before.sessionMisses + 1);
    });

    test('session_close drops the cached handle instead of poisoning it', () async {
      final core = await loadEngineCore();
      addTearDown(core.dispose);

      final first = await core.session(seedDoc, 'session_list_artboards');
      expect(first['ok'], isTrue);
      expect(core.stats().sessionCloses, 0);

      final closed = await core.session(seedDoc, 'session_close');
      expect(closed['ok'], isTrue, reason: '$closed');
      expect(core.stats().sessionCloses, 1);

      final missesBefore = core.stats().sessionMisses;
      final second = await core.session(seedDoc, 'session_list_artboards');
      expect(second['ok'], isTrue,
          reason: 'a closed session must be reopened, not reused: $second');
      expect(core.stats().sessionMisses, missesBefore + 1);

      final third = await core.session(seedDoc, 'session_list_artboards');
      expect(third['ok'], isTrue);
    });

    test('an unknown session name is rejected before any session is opened', () async {
      final core = await loadEngineCore();
      addTearDown(core.dispose);

      final before = core.stats();
      const bogus = 'session_definitely_not_an_export';
      for (var i = 0; i < 5; i++) {
        final envelope = await core.session(seedDoc, bogus);
        expect(envelope['ok'], isFalse);
        expect(envelope['error'], EngineErrorCode.unknownFunction);
      }
      final after = core.stats();
      expect(after.trapCount, before.trapCount,
          reason: 'an unlisted name must fail cleanly, not trap the instance');
      expect(after.sessionMisses, before.sessionMisses,
          reason: 'no session may be opened for a name this host cannot serve');
      expect(after.sessionCloses, before.sessionCloses);
      expect(after.memoryBytes, before.memoryBytes,
          reason: 'the old path opened (and dropped) one engine session per call');
    });
  });

  group('envelope contract', () {
    late EngineWasmCore core;

    setUpAll(() async {
      core = await loadEngineCore();
    });

    tearDownAll(() => core.dispose());

    test('the empty document is legal (engine 0.2)', () async {
      final validated = await core.validate('');
      expect(validated['ok'], isTrue);
      expect(validated['artboards'], isEmpty);

      final rendered = await core.render('');
      expect(rendered['ok'], isTrue);
      expect(rendered['artboards'], isEmpty);
      expect(rendered['mbt'], isA<String>());
    });

    test('render carries artboards with SVG; apply carries mbt but no render', () async {
      final rendered = await core.render(seedDoc);
      expect(rendered['ok'], isTrue);
      final boards = (rendered['artboards'] as List).cast<Map>();
      expect(boards, hasLength(1));
      expect('${boards.first['svg']}', contains('<svg'));

      final applied = await core.apply(
        seedDoc,
        'place __seed button b1 - 30 110 140 44 text=下一页',
      );
      expect(applied['ok'], isTrue, reason: '$applied');
      expect(applied['mbt'], isA<String>());
      expect(applied.containsKey('render'), isFalse,
          reason: 'mutating envelopes do not ship SVG; the client renders separately');
    });

    test('the agent gate is a different door', () async {
      final op = 'place __seed button agent_btn - 40 220 160 44 text=确认';
      final human = await core.apply(seedDoc, op);
      final agent = await core.apply(seedDoc, op, gate: 'agent');
      expect(human['ok'], isTrue, reason: '$human');
      expect(agent['ok'], isTrue, reason: '$agent');
      expect(agent['mbt'], isA<String>());
    });

    test('unknown exports fail loudly instead of returning empty data', () async {
      await expectLater(
        core.rawCall('definitely_not_an_export'),
        throwsA(isA<EngineCallFailure>().having(
          (failure) => failure.code,
          'code',
          EngineErrorCode.unknownFunction,
        )),
      );
    });

    test('parseEngineEnvelope mirrors the Python host', () {
      expect(parseEngineEnvelope(''), {'ok': false, 'error': 'engine_empty_result'});
      final nonJson = parseEngineEnvelope('not-json');
      expect(nonJson['ok'], isFalse);
      expect(nonJson['error'], 'engine_non_json');
      expect(nonJson['raw'], 'not-json');
      expect(parseEngineEnvelope('[1,2]'), {'ok': true, 'data': [1, 2]});
      expect(parseEngineEnvelope('{"ok":true,"x":1}'), {'ok': true, 'x': 1});
      expect(parseEngineEnvelope('x' * 1000)['raw'], hasLength(400));
    });
  });

  group('memory recycling', () {
    test('crossing the threshold rebuilds the instance and keeps the engine usable', () async {
      // 300 KiB is below the ~393 KiB the engine reaches after a render, so the
      // gate must fire on the second call — the same logic that protects the
      // real 176 MiB threshold in long sessions.
      final core = await loadEngineCore(
        options: const EngineCoreOptions(memoryRecycleBytes: 300 * 1024),
      );
      addTearDown(core.dispose);

      final first = await core.render(seedDoc);
      expect(first['ok'], isTrue);
      final second = await core.render(seedDoc);
      expect(second['ok'], isTrue);

      final stats = core.stats();
      expect(stats.recycleCount, greaterThanOrEqualTo(1));
      expect(stats.instanceGeneration, greaterThan(1));
      expect(stats.fuelRemaining, lessThanOrEqualTo(kEngineDefaultFuelPerCall),
          reason: 'fuel is a lifetime pool that is only topped up, never reset');
    });

    test('the production threshold is 176 MiB', () {
      expect(kEngineMemoryRecycleBytes, 176 * 1024 * 1024);
    });

    test('the recycle gate never rebuilds between slot chunks (no truncated render)', () async {
      // The engine's post-load footprint is 3 pages (196608 B); this threshold
      // is armed but below the first grow, so the old per-`_invoke` gate fired
      // inside the 4-byte `in_push` loop, dropped the payload prefix and let
      // the engine answer `ok` with a truncated document.
      final core = await loadEngineCore(
        options: const EngineCoreOptions(memoryRecycleBytes: 196608 + 1024),
      );
      addTearDown(core.dispose);

      final bigDoc = seedDoc + ('\n' * 200000);
      final before = core.stats();
      final rendered = await core.render(bigDoc);
      final after = core.stats();

      expect(rendered['ok'], isTrue, reason: '$rendered');
      final boards = (rendered['artboards'] as List).cast<Map>();
      expect(boards, hasLength(1),
          reason: 'a truncated payload renders as an empty document with ok:true');
      final mbt = rendered['mbt'] as String;
      expect(mbt.length, greaterThan(150000),
          reason: 'the engine must receive the whole document, not just the tail');
      expect(mbt, contains('__seed'));
      expect(after.instanceGeneration, before.instanceGeneration,
          reason: 'no rebuild may land inside one logical render');
      expect(after.recycleCount, before.recycleCount);
      expect(after.trapCount, 0);
    });

    test('the per-call fuel budget scales with the document size', () async {
      final core = await loadEngineCore();
      addTearDown(core.dispose);
      // A fixed 500M budget traps on any document above ~65 KB: 12_000 fuel
      // per canonical byte is the measured worst case (~7_500/B) with margin.
      expect(core.budgetFor(''), kEngineDefaultFuelPerCall);
      expect(core.budgetFor('x' * 1000), kEngineDefaultFuelPerCall);
      expect(core.budgetFor('x' * 100000), 100000 * kEngineFuelPerByte);
    });
  });

  group('trap recovery', () {
    test('a trap rebuilds the instance and the next call works', () async {
      final core = await EngineWasmCore.loadRaw(buildFixtureModule());
      addTearDown(core.dispose);

      final before = core.stats();
      expect(await core.rawCall('busy', <Object?>[3]), 0);

      await expectLater(
        core.rawCall('boom'),
        throwsA(isA<EngineCallFailure>().having(
          (failure) => failure.code,
          'code',
          EngineErrorCode.trap,
        )),
      );
      final after = core.stats();
      expect(after.trapCount, before.trapCount + 1);
      expect(after.instanceGeneration, before.instanceGeneration + 1);
      expect(await core.rawCall('busy', <Object?>[3]), 0);
    });

    test('fuel exhaustion is reported as such and rebuilds', () async {
      final core = await EngineWasmCore.loadRaw(
        buildFixtureModule(),
        options: const EngineCoreOptions(fuelPerCall: 50000000),
      );
      addTearDown(core.dispose);

      final watch = Stopwatch()..start();
      await expectLater(
        core.rawCall('spin'),
        throwsA(isA<EngineCallFailure>().having(
          (failure) => failure.code,
          'code',
          EngineErrorCode.fuelExhausted,
        )),
      );
      watch.stop();
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
      expect(core.stats().instanceGeneration, greaterThan(1));
      expect(await core.rawCall('busy', <Object?>[3]), 0);
    });
  });

  group('parity fixtures', () {
    test('cases.json parses and placeholders are resolvable', () {
      final file = File('${appDir().path}/test/fixtures/engine/cases.json');
      expect(file.existsSync(), isTrue, reason: 'the parity script shares this file');
      final data = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      expect(data['seed'], isA<String>());
      expect(data['spec'], isA<String>());
      final cases = (data['cases'] as List).cast<Map>();
      expect(cases.length, greaterThanOrEqualTo(15));
      final ids = cases.map((c) => '${c['id']}').toList();
      expect(ids.toSet().length, ids.length, reason: 'case ids must be unique');
      for (final c in cases) {
        final steps = c['steps'] is List ? (c['steps'] as List) : <dynamic>[c];
        for (final step in steps.cast<Map>()) {
          expect(step['kind'], isA<String>(), reason: 'case ${c['id']} step has no kind');
        }
      }
    });

    test('the fixture wasm encoder is deterministic', () {
      final a = buildFixtureModule();
      final b = buildFixtureModule();
      expect(a, equals(b));
      expect(a.sublist(0, 8), <int>[0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]);
      expect(a, isA<Uint8List>());
    });
  });
}
