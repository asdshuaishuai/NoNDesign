import 'package:flutter_test/flutter_test.dart';
import 'package:nondesign/core/music/music_compile.dart';
import 'package:nondesign/core/music/music_score.dart';

MusicEvent _note(
  String id, {
  int num = 1,
  int den = 4,
  int dot = 0,
  int tupletN = 0,
  int tupletIn = 0,
  String step = 'C',
  int octave = 5,
}) => MusicEvent(
  id: id,
  isRest: false,
  durNum: num,
  durDen: den,
  dot: dot,
  tupletN: tupletN,
  tupletIn: tupletIn,
  step: step,
  octave: octave,
);

MusicScore _score(List<MusicEvent> events, {String instrument = 'piano'}) =>
    MusicScore(
      title: 't',
      tempo: 120,
      timeSig: const <int>[4, 4],
      keySig: 'C',
      tracks: <MusicTrack>[
        MusicTrack(
          id: 'a',
          name: 'A',
          instrument: instrument,
          measures: <MusicMeasure>[MusicMeasure(id: 'm1', events: events)],
        ),
      ],
    );

void main() {
  group('score → 整数 tick（ppq=3840）', () {
    test('四分/八分/附点/三连音/五连音落整数 tick', () {
      final quarter = compileMusicScore(_score(<MusicEvent>[_note('q')]));
      expect(quarter.ppq, 3840);
      expect(quarter.events.single.durationTicks, 3840);
      expect(quarter.events.single.midi, 72, reason: 'C5 = 72');

      final eighth = compileMusicScore(
        _score(<MusicEvent>[_note('e', den: 8)]),
      );
      expect(eighth.events.single.durationTicks, 1920);

      final dotted = compileMusicScore(
        _score(<MusicEvent>[_note('dq', dot: 1)]),
      );
      expect(dotted.events.single.durationTicks, 5760);

      final triplet = compileMusicScore(
        _score(<MusicEvent>[_note('te', den: 8, tupletN: 3, tupletIn: 2)]),
      );
      expect(triplet.events.single.durationTicks, 1280);

      final quintuplet = compileMusicScore(
        _score(<MusicEvent>[_note('qs', den: 16, tupletN: 5, tupletIn: 4)]),
      );
      expect(quintuplet.events.single.durationTicks, 768);
    });

    test('同输入两次编译字节相同；事件时间单调、rest 也推进游标', () {
      final score = _score(<MusicEvent>[
        _note('n1', den: 4),
        MusicEvent(id: 'r1', isRest: true, durNum: 1, durDen: 4),
        _note('n2', den: 4),
      ]);
      final a = compileMusicScore(score).toJsonString();
      final b = compileMusicScore(score).toJsonString();
      expect(a, b);
      final plan = compileMusicScore(score);
      expect(plan.events.map((event) => event.startTick).toList(), <int>[
        0,
        3840,
        7680,
      ]);
      expect(plan.totalTicks, 11520);
    });

    test('鼓轨按鼓件名编译；精度不足抛显性错误', () {
      final drums = _score(<MusicEvent>[
        MusicEvent(
          id: 'd1',
          isRest: false,
          durNum: 1,
          durDen: 1,
          extra: const <String, Object?>{'drum': 'kick'},
        ),
      ], instrument: 'drums');
      final plan = compileMusicScore(drums);
      expect(plan.events.single.drum, 'kick');
      expect(plan.events.single.midi, 0);

      final seven = _score(<MusicEvent>[
        _note('seven', den: 8, tupletN: 7, tupletIn: 4),
      ]);
      expect(
        () => compileMusicScore(seven),
        throwsA(
          isA<MusicCompileError>().having(
            (e) => e.code,
            'code',
            'score_tuplet_precision',
          ),
        ),
      );
    });
  });
}
