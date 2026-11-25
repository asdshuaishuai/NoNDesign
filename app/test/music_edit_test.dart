import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nondesign/core/music/music_compile.dart';
import 'package:nondesign/core/music/music_edit.dart';
import 'package:nondesign/core/music/music_score.dart';

Map<String, Object?> _rawScore({
  int tempo = 96,
  String title = '练习曲',
}) => <String, Object?>{
  'schemaVersion': 1,
  'title': title,
  'tempo': tempo,
  'timeSig': <int>[4, 4],
  'keySig': 'C',
  'composer': 'NaN',
  'tracks': <Object?>[
    <String, Object?>{
      'id': 'melody',
      'name': '主旋律',
      'instrument': 'piano',
      'volume': 0.8,
      'muted': false,
      'clef': 'treble',
      'color': '#101010',
      'measures': <Object?>[
        <String, Object?>{
          'id': 'm1',
          'rehearsal': 'A',
          'events': <Object?>[
            <String, Object?>{
              'id': 'n1',
              'type': 'note',
              'pitch': <String, Object?>{'step': 'C', 'alter': 0, 'octave': 5},
              'dur': <String, Object?>{'num': 1, 'den': 1},
              'accent': true,
            },
          ],
        },
      ],
    },
  ],
};

Map<String, Object?> _rawDrums() => <String, Object?>{
  'schemaVersion': 1,
  'title': '鼓',
  'tempo': 100,
  'timeSig': <int>[4, 4],
  'keySig': 'C',
  'tracks': <Object?>[
    <String, Object?>{
      'id': 'dr',
      'name': '鼓组',
      'instrument': 'drums',
      'measures': <Object?>[
        <String, Object?>{
          'id': 'm1',
          'events': <Object?>[
            <String, Object?>{
              'id': 'd1',
              'type': 'note',
              'pitch': 'kick',
              'dur': <String, Object?>{'num': 1, 'den': 1},
            },
          ],
        },
      ],
    },
  ],
};

MusicScore _score({int tempo = 96}) => MusicScore(
  title: '练习曲',
  tempo: tempo,
  timeSig: const <int>[4, 4],
  keySig: 'C',
  tracks: <MusicTrack>[
    MusicTrack(
      id: 'melody',
      name: '主旋律',
      instrument: 'piano',
      volume: 0.8,
      measures: <MusicMeasure>[
        MusicMeasure(
          id: 'm1',
          events: <MusicEvent>[
            MusicEvent(
              id: 'n1',
              isRest: false,
              durNum: 1,
              durDen: 1,
              step: 'C',
              octave: 5,
            ),
          ],
        ),
      ],
    ),
  ],
);

MusicScore _emptyScore(int measures) => MusicScore(
  title: '空谱',
  tempo: 96,
  timeSig: const <int>[4, 4],
  keySig: 'C',
  tracks: <MusicTrack>[
    MusicTrack(
      id: 'melody',
      name: '主旋律',
      instrument: 'piano',
      measures: <MusicMeasure>[
        for (int i = 0; i < measures; i++)
          MusicMeasure(id: 'm${i + 1}', events: const <MusicEvent>[]),
      ],
    ),
  ],
);

MusicScore _parsedBase() => parseMusicScore(_rawScore()).score!;

Matcher _failure(String code) => throwsA(
  isA<MusicEditFailure>().having((MusicEditFailure f) => f.code, 'code', code),
);

void _expectAccepted(MusicScore score) {
  final parsed = parseMusicScore(score.toJson());
  expect(parsed.score, isNotNull, reason: '编辑结果必须能被 parseMusicScore 接受');
  expect(
    verifyMusicScore(score.toJson()).verified,
    isTrue,
    reason: '编辑结果必须通过校验',
  );
}

double _durationValue(MusicMeasure measure) =>
    measure.events.fold<double>(0, (sum, event) => sum + event.durationValue);

void main() {
  group('元数据编辑：正例', () {
    test('标题/速度 → 结果可解析，未知字段在 score/track/measure/event 级都保留', () {
      final MusicScore base = _parsedBase();
      final MusicScore edited = editScoreTempo(
        editScoreTitle(base, '  新练习曲  '),
        120,
      );
      expect(edited.title, '新练习曲');
      expect(edited.tempo, 120);
      expect(edited.extra['composer'], 'NaN');
      final MusicTrack track = edited.tracks.single;
      expect(track.extra['color'], '#101010');
      expect(track.measures.single.extra['rehearsal'], 'A');
      expect(track.measures.single.events.single.extra['accent'], isTrue);
      _expectAccepted(edited);
      final roundtrip = jsonDecode(jsonEncode(edited.toJson())) as Map;
      expect(roundtrip['composer'], 'NaN');
    });

    test('轨道音量/静音 → 结果可解析，其它轨道字段不动', () {
      final MusicScore base = _parsedBase();
      final MusicScore edited = editTrackMuted(
        editTrackVolume(base, 'melody', 0.35),
        'melody',
        true,
      );
      final MusicTrack track = edited.tracks.single;
      expect(track.volume, closeTo(0.35, 1e-9));
      expect(track.muted, isTrue);
      expect(track.name, '主旋律');
      expect(track.extra['color'], '#101010');
      _expectAccepted(edited);
    });

    test('空小节可以换拍号（3/4），结果可解析', () {
      final MusicScore empty = _emptyScore(2);
      final MusicScore edited = editScoreTimeSig(empty, 3, 4);
      expect(edited.timeSig, <int>[3, 4]);
      _expectAccepted(edited);
    });

    test('鼓轨字符串音名（pitch:"kick"）编辑后仍可解析/编译（占位音高归一）', () {
      final MusicScore drums = parseMusicScore(_rawDrums()).score!;
      final MusicScore renamed = editScoreTitle(drums, '鼓点');
      _expectAccepted(renamed);
      expect(
        renamed.tracks.single.measures.single.events.single.extra['drum'],
        'kick',
      );
      expect(() => compileMusicScore(renamed), returnsNormally);

      final MusicScore withNote = appendQuarterNote(renamed, 'dr');
      _expectAccepted(withNote);
      expect(() => compileMusicScore(withNote), returnsNormally);
      expect(
        withNote.tracks.single.measures.last.events.first.extra['drum'],
        'kick',
      );
    });
  });

  group('元数据编辑：反例', () {
    test('空标题/越界速度/越界音量/未知轨道 → 可控错误', () {
      final MusicScore base = _parsedBase();
      expect(() => editScoreTitle(base, '   '), _failure('invalid_title'));
      expect(() => editScoreTempo(base, 19), _failure('invalid_tempo'));
      expect(() => editScoreTempo(base, 301), _failure('invalid_tempo'));
      expect(
        () => editTrackVolume(base, 'melody', 1.2),
        _failure('invalid_volume'),
      );
      expect(
        () => editTrackVolume(base, 'ghost', 0.5),
        _failure('unknown_track'),
      );
      expect(
        () => editTrackMuted(base, 'ghost', true),
        _failure('unknown_track'),
      );
    });

    test('非法拍号/已有小节与新拍号冲突 → 可控错误', () {
      final MusicScore base = _parsedBase();
      expect(() => editScoreTimeSig(base, 0, 4), _failure('invalid_time_sig'));
      expect(() => editScoreTimeSig(base, 3, 3), _failure('invalid_time_sig'));
      expect(() => editScoreTimeSig(base, 3, 4), _failure('time_sig_conflict'));
    });

    test('输入本身不合法：拒绝编辑并标明输入问题，不产出坏 score', () {
      final MusicScore bad = _score(tempo: 10);
      expect(() => editScoreTitle(bad, '标题'), _failure('invalid_input'));
    });
  });

  group('小节编辑', () {
    test('追加/删除空小节：小节数增减，结果可解析', () {
      final MusicScore base = _parsedBase();
      final MusicScore added = appendEmptyMeasure(base, 'melody');
      expect(added.tracks.single.measures.length, 2);
      expect(added.tracks.single.measures.last.events, isEmpty);
      expect(added.tracks.single.measures.last.id, isNot('m1'));
      _expectAccepted(added);

      final MusicScore removed = removeLastEmptyMeasure(added, 'melody');
      expect(removed.tracks.single.measures.length, 1);
      _expectAccepted(removed);
    });

    test('删除空小节：非空末小节/只剩一个小节 → 拒绝', () {
      final MusicScore twoMeasures = appendQuarterNote(_parsedBase(), 'melody');
      expect(twoMeasures.tracks.single.measures.length, 2);
      expect(
        () => removeLastEmptyMeasure(twoMeasures, 'melody'),
        _failure('measure_not_empty'),
      );
      expect(
        () => removeLastEmptyMeasure(_emptyScore(1), 'melody'),
        _failure('measure_required'),
      );
    });

    test('小节上限 256：满 256 再追加 → score_too_large；删空小节仍可用', () {
      final MusicScore full = _emptyScore(256);
      expect(
        () => appendEmptyMeasure(full, 'melody'),
        _failure('score_too_large'),
      );
      final MusicScore trimmed = removeLastEmptyMeasure(full, 'melody');
      expect(trimmed.tracks.single.measures.length, 255);
      _expectAccepted(trimmed);
    });
  });

  group('音符/休止追加', () {
    test('满小节追加四分音符 → 新开小节并用休止补齐到拍号', () {
      final MusicScore edited = appendQuarterNote(_parsedBase(), 'melody');
      final MusicTrack track = edited.tracks.single;
      expect(track.measures.length, 2, reason: '4/4 整小节已满，应新开小节');
      final MusicMeasure measure = track.measures.last;
      expect(measure.events.length, 2);
      expect(measure.events[0].isRest, isFalse);
      expect(measure.events[0].step, 'C');
      expect(measure.events[0].octave, 4);
      expect(measure.events[0].durNum, 1);
      expect(measure.events[0].durDen, 4);
      expect(measure.events[1].isRest, isTrue);
      expect(_durationValue(measure), closeTo(1.0, 1e-9));
      expect(track.measures.first.events.length, 1, reason: '原小节不被改动');
      _expectAccepted(edited);
      expect(edited.tracks.single.measures.last.events.first.id, isNotEmpty);
    });

    test('空小节追加四分音符 → 原小节内补齐，不新开小节', () {
      final MusicScore empty = appendEmptyMeasure(_parsedBase(), 'melody');
      final MusicScore edited = appendQuarterNote(empty, 'melody');
      expect(edited.tracks.single.measures.length, 2);
      final MusicMeasure measure = edited.tracks.single.measures.last;
      expect(measure.events.length, 2);
      expect(_durationValue(measure), closeTo(1.0, 1e-9));
      _expectAccepted(edited);
    });

    test('自定义音高/八度/升降；非法音高拒绝', () {
      final MusicScore edited = appendQuarterNote(
        _parsedBase(),
        'melody',
        step: 'a',
        octave: 5,
        alter: 1,
      );
      final MusicEvent note = edited.tracks.single.measures.last.events.first;
      expect(note.step, 'A');
      expect(note.octave, 5);
      expect(note.alter, 1);
      _expectAccepted(edited);

      expect(
        () => appendQuarterNote(_parsedBase(), 'melody', step: 'H'),
        _failure('invalid_pitch'),
      );
      expect(
        () => appendQuarterNote(_parsedBase(), 'melody', octave: 10),
        _failure('invalid_pitch'),
      );
    });

    test('追加四分休止 → 休止事件补齐到拍号', () {
      final MusicScore edited = appendQuarterRest(_parsedBase(), 'melody');
      final MusicMeasure measure = edited.tracks.single.measures.last;
      expect(edited.tracks.single.measures.length, 2);
      expect(measure.events.length, 2);
      expect(measure.events.every((event) => event.isRest), isTrue);
      expect(_durationValue(measure), closeTo(1.0, 1e-9));
      _expectAccepted(edited);
    });

    test('事件 id 唯一且编辑确定（同一输入两次得到相同 JSON）', () {
      final MusicScore first = appendQuarterRest(
        appendQuarterNote(_parsedBase(), 'melody'),
        'melody',
      );
      final MusicScore second = appendQuarterRest(
        appendQuarterNote(_parsedBase(), 'melody'),
        'melody',
      );
      expect(jsonEncode(first.toJson()), jsonEncode(second.toJson()));
      final Set<String> ids = <String>{
        for (final track in first.tracks)
          for (final measure in track.measures)
            for (final event in measure.events) event.id,
      };
      int count = 0;
      for (final track in first.tracks) {
        for (final measure in track.measures) {
          count += measure.events.length;
        }
      }
      expect(ids.length, count, reason: '事件 id 必须全局唯一');
    });

    test('增删空小节后未知字段仍保留', () {
      final MusicScore edited = appendQuarterNote(
        appendEmptyMeasure(_parsedBase(), 'melody'),
        'melody',
      );
      expect(edited.extra['composer'], 'NaN');
      expect(edited.tracks.single.extra['color'], '#101010');
      expect(edited.tracks.single.measures.first.extra['rehearsal'], 'A');
      _expectAccepted(edited);
    });
  });
}
