// Session signature tests (batch 02).
//
// The engine has four call shapes that do **not** fit "push arg, call the _in
// export", and getting one wrong silently drives the wrong slots (e.g. feeding
// an artboard name into the spec slot). This file pins each shape:
//
//  * `session_event`  — in=event token, arg=artboard;
//  * `session_tap`    — handle + f64 x/y, arg=artboard;
//  * `session_constrain` — arg=artboard, arg2=intent;
//  * `session_generate`  — in=spec JSON, arg=intent, arg2=artboard name.
//
// It also replays the play view's routing contract (`api.event` / `api.tap`
// envelopes, then `api.render(newMbt)`), because that screen is the main
// consumer of the gesture face and used to depend on the HTTP route names.

import 'package:flutter_test/flutter_test.dart';

import 'package:nondesign/core/engine/engine_host.dart';
import 'package:nondesign/core/engine/engine_types.dart';
import 'package:nondesign/core/engine/engine_worker.dart';

import 'fixtures/engine/test_env.dart';

void main() {
  group('signature tables', () {
    test('specials have dedicated _in exports and never go through the generic path', () {
      for (final name in kSessionSpecial) {
        expect(kSessionInExports, contains('${name}_in'),
            reason: '$name is driven through its _in export');
      }
      expect(kSessionSpecial.contains('session_event'), isTrue);
      expect(kSessionSpecial.contains('session_tap'), isTrue);
      expect(kSessionSpecial.contains('session_constrain'), isTrue);
      expect(kSessionSpecial.contains('session_generate'), isTrue);
      // session_history is a plain arg-slot session, not a special.
      expect(kSessionSpecial.contains('session_history'), isFalse);
      expect(kSessionMutating.contains('session_history'), isTrue);
    });

    test('the generic/RPC session whitelist names only the documented face', () {
      for (final name in kSessionExports) {
        expect(isSessionExportName(name), isTrue, reason: name);
      }
      expect(isSessionExportName('session_bogus'), isFalse);
      expect(isSessionExportName('apply-agent-mbt'), isFalse);
      expect(isSessionExportName('session_list_artboards_in'), isFalse,
          reason: 'the generic face appends the _in suffix itself');
    });
  });

  group('event (in=token, arg=artboard)', () {
    late EngineWasmCore core;

    setUpAll(() async {
      core = await loadEngineCore();
    });

    tearDownAll(() => core.dispose());

    test('accepted vocabulary returns the gesture envelope', () async {
      for (final spec in <String>[
        'key_enter',
        'key:left',
        'key:up',
        'swipe_left',
        'swipe_right:10:20',
        'long_press:100:130:500',
      ]) {
        final envelope = await core.event(seedDoc, '__seed', spec);
        expect(envelope['ok'], isTrue, reason: 'spec "$spec" -> $envelope');
        expect(envelope['current'], '__seed');
        expect(envelope['mbt'], isA<String>());
        expect(envelope['changes'], isA<List>());
      }
    });

    test('unknown tokens are rejected (play view falls back on this)', () async {
      for (final spec in <String>['long_press', 'focus', '{"type":"key"}', 'key_up']) {
        final envelope = await core.event(seedDoc, '__seed', spec);
        expect(envelope['ok'], isFalse, reason: 'spec "$spec" should be rejected');
        expect(envelope['error'], 'unknown_event');
      }
    });

    test('the artboard comes from the arg slot, not from a stale value', () async {
      final wrongBoard = await core.event(seedDoc, 'no_such_board', 'key_enter');
      expect(wrongBoard['ok'], isFalse);
      expect('${wrongBoard['error'] ?? wrongBoard['detail']}',
          contains('unknown_artboard'));
      // The next call with a real board must work: the slot was overwritten.
      final right = await core.event(seedDoc, '__seed', 'key_enter');
      expect(right['ok'], isTrue);
    });
  });

  group('tap (handle + f64 x/y, arg=artboard)', () {
    late EngineWasmCore core;

    setUpAll(() async {
      core = await loadEngineCore();
    });

    tearDownAll(() => core.dispose());

    test('taps route through the f64 parameters and the arg slot', () async {
      final applied = await core.apply(
        seedDoc,
        'place __seed button tap_btn - 30 110 140 44 text=下一页',
      );
      final mbt = applied['mbt'] as String;

      final inside = await core.tap(mbt, '__seed', 60, 120);
      expect(inside['ok'], isTrue, reason: '$inside');
      expect(inside['current'], '__seed');

      // Outside the board is still a valid call (no hit), not an error.
      final outside = await core.tap(mbt, '__seed', 3000, 3000);
      expect(outside['ok'], isTrue);
    });
  });

  group('constrain (arg=artboard, arg2=intent)', () {
    late EngineWasmCore core;

    setUpAll(() async {
      core = await loadEngineCore();
    });

    tearDownAll(() => core.dispose());

    test('a parsed intent returns the canonical envelope with the node id', () async {
      final applied = await core.apply(
        seedDoc,
        'place __seed button c_btn - 30 110 140 44 text=下一页',
      );
      final mbt = applied['mbt'] as String;

      final centered = await core.constrain(mbt, '__seed', '居中');
      expect(centered['ok'], isTrue, reason: '$centered');
      expect(centered['id'], 'c_btn');
      expect(centered['mbt'], isA<String>());
      // The envelope carries no render face: the client renders separately.
      expect(centered.containsKey('render'), isFalse);
    });

    test('an unknown intent returns the vocabulary, not a silent no-op', () async {
      final envelope = await core.constrain(seedDoc, '__seed', '不是布局意图');
      expect(envelope['ok'], isFalse);
      expect('${envelope['error']}', contains('cannot_parse'));
      // The vocabulary is part of the error message (error-as-documentation).
      expect('${envelope['error']}', contains('居中'));
    });

    test('intent really comes from arg2 (arg=artboard alone is not enough)', () async {
      final applied = await core.apply(
        seedDoc,
        'place __seed button c2 - 30 110 140 44 text=下一页',
      );
      final mbt = applied['mbt'] as String;
      final envelope = await core.constrain(mbt, '__seed', '');
      expect(envelope['ok'], isFalse);
      expect('${envelope['error']}', contains('cannot_parse'));
    });
  });

  group('generate (in=spec, arg=intent, arg2=name)', () {
    late EngineWasmCore core;

    setUpAll(() async {
      core = await loadEngineCore();
    });

    tearDownAll(() => core.dispose());

    test('generates a new artboard named by arg2 with the spec from the in slot', () async {
      final envelope = await core.generate(seedDoc, '探针页 as probe_generate', 'probe_generate', specJson);
      expect(envelope['ok'], isTrue, reason: '$envelope');
      expect(envelope['artboard'], 'probe_generate');
      expect(envelope['mbt'], isA<String>());
      final mbt = envelope['mbt'] as String;
      expect(mbt, contains('probe_generate'));
      // The design spec's style preset lands in the document frontmatter.
      expect(mbt, contains('theme:'));

      final boards = await core.session(mbt, 'session_list_artboards');
      expect(boards['ok'], isTrue);
      final ids = (boards['data'] as List).cast<Map>().map((board) => board['id']).toList();
      expect(ids, contains('probe_generate'));
    });

    test('a spec object and a spec string produce the same document', () async {
      // The service passes maps; the host serialises with jsonEncode.
      final fromString = await core.generate(seedDoc, 'A as a_board', 'a_board', specJson);
      final fromMap = await core.generate(
        seedDoc,
        'A as a_board',
        'a_board',
        (const {
          'v': 1,
          'style': 'apple',
          'palette': {
            'primary': '#2F6B4F',
            'background': '#FFFFFF',
            'surface': '#F2F7F4',
            'text': '#14201A',
            'muted': '#5F7A6B',
            'danger': '#DC2626',
            'success': '#16A34A',
          },
          'typography': {'h1': 30, 'body': 14, 'caption': 12},
          'spacing': [4, 8, 12, 16, 24, 32],
          'radius': {'sm': 8, 'md': 12, 'lg': 16},
        }),
      );
      expect(fromString['ok'], isTrue);
      expect(fromMap['ok'], isTrue);
      expect(fromMap['mbt'], fromString['mbt']);
    });
  });

  group('signature edge cases', () {
    test('session_open_project_json reads the project JSON from the in slot', () async {
      final core = await loadEngineCore();
      addTearDown(core.dispose);
      final saved = await core.session(seedDoc, 'session_save');
      expect(saved['ok'], isTrue);
      final projectJson = saved['data'];
      expect(projectJson, isA<String>());

      final opened = await core.session('', 'session_open_project_json', projectJson as String);
      expect(opened['ok'], isTrue, reason: '$opened');
      expect(opened['handle'], isA<int>());
      expect(opened['handle'] as int, greaterThanOrEqualTo(0));

      // The handle is cached, not leaked: opening the same payload again
      // reuses it, and an ordinary session call evicts and closes it.
      final again = await core.session('', 'session_open_project_json', projectJson);
      expect(again['ok'], isTrue);
      expect(again['handle'], opened['handle']);
      expect(core.stats().sessionHits, greaterThanOrEqualTo(1));

      final closesBefore = core.stats().sessionCloses;
      final boards = await core.session(seedDoc, 'session_list_artboards');
      expect(boards['ok'], isTrue);
      expect(core.stats().sessionCloses, greaterThan(closesBefore),
          reason: 'the project handle must be closed when the cache turns over');
      expect(core.stats().trapCount, 0,
          reason: 'closing the project handle must not trap the instance');
    });

    test('exports without a host-buildable signature fail explicitly', () async {
      final core = await loadEngineCore();
      addTearDown(core.dispose);
      for (final name in kSessionUnsupportedSignatures) {
        final envelope = await core.session(seedDoc, name);
        expect(envelope['ok'], isFalse, reason: name);
        expect(envelope['error'], EngineErrorCode.unsupportedSignature, reason: name);
      }
    });

    test('the host clears the arg slot between session calls', () async {
      final host = await EngineHost.start(wasmBytes: engineBytes());
      addTearDown(host.dispose);
      final withArg = await host.session(seedDoc, 'session_query_nodes', '__seed');
      expect(withArg['ok'], isTrue);
      final withoutArg = await host.session(seedDoc, 'session_query_nodes');
      expect(withoutArg['ok'], isFalse);
      expect('${withoutArg['error']}', contains('unknown_artboard'));
    });
  });

  group('generic session face dispatch', () {
    test('session_generate is refused and adds no artboard', () async {
      final core = await loadEngineCore();
      addTearDown(core.dispose);

      final envelope = await core.session(seedDoc, 'session_generate');
      expect(envelope['ok'], isFalse, reason: '$envelope');
      expect(envelope['error'], EngineErrorCode.unsupportedSignature);

      final boards = await core.session(seedDoc, 'session_list_artboards');
      expect(boards['ok'], isTrue);
      final ids = (boards['data'] as List).cast<Map>().map((board) => board['id']).toList();
      expect(ids, isNot(contains('empty_state')),
          reason: 'the old generic path silently generated an empty_state board');
      expect(core.stats().trapCount, 0);
    });

    test('session_tap / session_event / session_open do not trap the instance', () async {
      final core = await loadEngineCore();
      addTearDown(core.dispose);

      for (final name in <String>['session_tap', 'session_event', 'session_open']) {
        final envelope = await core.session(seedDoc, name, '__seed');
        expect(envelope['ok'], isFalse, reason: name);
        expect(envelope['error'], EngineErrorCode.unsupportedSignature, reason: name);
      }
      expect(core.stats().trapCount, 0,
          reason: 'wrong argument counts used to trap and rebuild the instance');

      // The warm instance is untouched: the next call works normally.
      final boards = await core.session(seedDoc, 'session_list_artboards');
      expect(boards['ok'], isTrue);
    });

    test('session_constrain never reuses a stale arg2 intent', () async {
      final core = await loadEngineCore();
      addTearDown(core.dispose);

      final applied = await core.apply(
        seedDoc,
        'place __seed button warm_btn - 30 110 140 44 text=下一页',
      );
      expect(applied['ok'], isTrue, reason: '$applied');
      final mbt = applied['mbt'] as String;

      // Warm arg2 with a real intent.
      final warm = await core.constrain(mbt, '__seed', '居中');
      expect(warm['ok'], isTrue, reason: '$warm');
      final canonical = warm['mbt'] as String;

      // The generic face carries no intent, so an explicit empty arg2 must
      // reach the engine: the stale 居中 can never be applied a second time.
      final generic = await core.session(canonical, 'session_constrain', '__seed');
      expect(generic['ok'], isFalse, reason: '$generic');
      expect('${generic['error']}', contains('cannot_parse'));
      expect(core.stats().trapCount, 0);
    });
  });

  group('play view routing regression', () {
    test('event/tap envelopes then render(newMbt) is the whole gesture path', () async {
      final host = await EngineHost.start(wasmBytes: engineBytes());
      addTearDown(host.dispose);

      final placed = await host.apply(
        seedDoc,
        'place __seed button play_btn - 30 110 140 44 text=下一页',
      );
      expect(placed['ok'], isTrue, reason: '$placed');
      final interacted = await host.apply(
        placed['mbt'] as String,
        'interact __seed play_btn tap haptic',
      );
      expect(interacted['ok'], isTrue, reason: '$interacted');
      final mbt = interacted['mbt'] as String;

      // play_view._sendGesture: api.event(...) → ok? → follow `current`/`mbt`.
      final gesture = await host.event(mbt, '__seed', 'long_press:100:130:500');
      expect(gesture['ok'], isTrue, reason: '$gesture');
      expect(gesture['current'], isA<String>());
      expect(gesture['changes'], isA<List>());

      // play_view tap path.
      final tapped = await host.tap(mbt, '__seed', 60, 120);
      expect(tapped['ok'], isTrue);
      expect(tapped['current'], '__seed');
      expect(tapped['changes'], contains('node_updated:play_btn'));

      // Both paths re-render the mutated canonical locally.
      final canonical = (tapped['mbt'] as String?) ?? mbt;
      final rendered = await host.render(canonical);
      expect(rendered['ok'], isTrue);
      expect(rendered['artboards'], hasLength(1));

      // A rejected gesture must not look like a navigation:
      // play_view uses `ok == false` to fall back to its local back stack.
      final rejected = await host.event(mbt, '__seed', 'focus');
      expect(rejected['ok'], isFalse);
      expect(rejected['current'], isNull);
    });

    test('interactions export feeds the hot-zone list', () async {
      final host = await EngineHost.start(wasmBytes: engineBytes());
      addTearDown(host.dispose);
      final placed = await host.apply(
        seedDoc,
        'place __seed button hz_btn - 30 110 140 44 text=下一页',
      );
      expect(placed['ok'], isTrue);
      final interacted = await host.apply(
        placed['mbt'] as String,
        'interact __seed hz_btn tap haptic',
      );
      expect(interacted['ok'], isTrue, reason: '$interacted');
      final mbt = interacted['mbt'] as String;

      final interactions = await host.session(mbt, 'session_interactions', '__seed');
      expect(interactions['ok'], isTrue);
      final data = (interactions['data'] as List).cast<Map>();
      expect(data, isNotEmpty, reason: 'the interaction should be exported');
      final entry = data.firstWhere((item) => item['node'] == 'hz_btn');
      expect(entry['trigger'], 'tap');
      expect((entry['action'] as Map)['kind'], 'haptic');
      expect(entry['source'], 'marker');
    });
  });
}
