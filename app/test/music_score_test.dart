import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nondesign/core/music/music_score.dart';

MusicEvent _note(
  String id,
  String step, {
  int den = 4,
  int dot = 0,
  int? tupletN,
  int? tupletIn,
}) => MusicEvent(
  id: id,
  isRest: false,
  step: step,
  octave: 4,
  durNum: 1,
  durDen: den,
  dot: dot,
  tupletN: tupletN ?? 0,
  tupletIn: tupletIn ?? 0,
);

MusicEvent _rest(String id) =>
    MusicEvent(id: id, isRest: true, durNum: 1, durDen: 4);

Map<String, Object?> _validRaw() => <String, Object?>{
  'schemaVersion': 1,
  'title': '小星星',
  'tempo': 96,
  'timeSig': <int>[4, 4],
  'keySig': 'C',
  'tracks': <Object?>[
    <String, Object?>{
      'id': 'melody',
      'name': '主旋律',
      'instrument': 'piano',
      'volume': 0.8,
      'muted': false,
      'clef': 'treble',
      'measures': <Object?>[
        <String, Object?>{
          'id': 'm1',
          'events': <Object?>[
            <String, Object?>{
              'id': 'n1',
              'type': 'note',
              'pitch': <String, Object?>{'step': 'C', 'alter': 0, 'octave': 5},
              'dur': <String, Object?>{'num': 1, 'den': 4},
            },
            <String, Object?>{
              'id': 'r1',
              'type': 'rest',
              'dur': <String, Object?>{'num': 1, 'den': 4},
            },
            <String, Object?>{
              'id': 'n2',
              'type': 'note',
              'pitch': <String, Object?>{'step': 'E', 'alter': 0, 'octave': 5},
              'dur': <String, Object?>{'num': 1, 'den': 4},
            },
            <String, Object?>{
              'id': 'n3',
              'type': 'note',
              'pitch': <String, Object?>{'step': 'G', 'alter': 0, 'octave': 5},
              'dur': <String, Object?>{'num': 1, 'den': 4},
            },
          ],
        },
      ],
    },
  ],
};

void main() {
  group('score.json v1', () {
    test('合法乐谱：解析/verified，未知字段 roundtrip 保留', () {
      final raw = _validRaw();
      raw['composer'] = 'NaN';
      final parsed = parseMusicScore(raw);
      expect(parsed.score, isNotNull);
      expect(verifyMusicScore(raw).verified, isTrue);

      final roundtrip = jsonDecode(jsonEncode(parsed.score!.toJson())) as Map;
      expect(roundtrip['composer'], 'NaN');
      expect((roundtrip['tracks'] as List).length, 1);
    });

    test('版本/速度/结构上限/音高时值/关系：正反例', () {
      final badVersion = _validRaw()..['schemaVersion'] = 2;
      expect(verifyMusicScore(badVersion).verified, isFalse);
      expect(
        verifyMusicScore(badVersion).blockingIssues.map((i) => i.code),
        contains('score_unsupported_version'),
      );

      final badTempo = _validRaw()..['tempo'] = 10;
      expect(verifyMusicScore(badTempo).verified, isFalse);

      final badStep = _validRaw();
      (((badStep['tracks'] as List)[0] as Map)['measures']
              as List)[0]['events'][0]['pitch']['step'] =
          'H';
      expect(verifyMusicScore(badStep).verified, isFalse);

      final sevenTuplet = _validRaw();
      final note =
          (((sevenTuplet['tracks'] as List)[0] as Map)['measures']
                  as List)[0]['events'][0]
              as Map;
      note['tuplet'] = <String, Object?>{'n': 7, 'in': 4, 'group': 1};
      expect(verifyMusicScore(sevenTuplet).verified, isFalse);
    });

    test('小节时值总和不等于拍号 / tie 音高不一致 / 引用不存在 → 失败', () {
      final shortMeasure = _validRaw();
      final measure =
          (((shortMeasure['tracks'] as List)[0] as Map)['measures'] as List)[0]
              as Map;
      (measure['events'] as List).removeLast();
      expect(verifyMusicScore(shortMeasure).verified, isFalse);

      final tie = _validRaw();
      tie['relations'] = <Object?>[
        <String, Object?>{'type': 'tie', 'id': 't1', 'from': 'n1', 'to': 'n2'},
      ];
      final issues = verifyMusicScore(tie).blockingIssues
          .map((i) => i.message)
          .join();
      expect(issues, contains('tie 两端音高不一致'));

      final missing = _validRaw();
      missing['relations'] = <Object?>[
        <String, Object?>{
          'type': 'slur',
          'id': 's1',
          'events': <Object?>['ghost'],
        },
      ];
      expect(verifyMusicScore(missing).verified, isFalse);
    });

    test('鼓轨：pitch 用鼓件名；环鼓件拒绝', () {
      final drums = <String, Object?>{
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
      expect(verifyMusicScore(drums).verified, isTrue);
      (drums['tracks'] as List)[0]['measures'][0]['events'][0]['pitch'] =
          'kazoo';
      expect(verifyMusicScore(drums).verified, isFalse);
    });
  });

  test('模型 → JSON → 模型稳定', () {
    final score = MusicScore(
      title: 't',
      tempo: 120,
      timeSig: const <int>[2, 4],
      keySig: 'G',
      tracks: <MusicTrack>[
        MusicTrack(
          id: 'a',
          name: 'A',
          instrument: 'strings',
          measures: <MusicMeasure>[
            MusicMeasure(
              id: 'm1',
              events: <MusicEvent>[_note('n1', 'C'), _rest('r1')],
            ),
          ],
        ),
      ],
      extra: const <String, Object?>{'composer': 'x'},
    );
    final parsed = parseMusicScore(jsonDecode(jsonEncode(score.toJson())));
    expect(parsed.score, isNotNull);
    expect(parsed.score!.extra['composer'], 'x');
  });
}
