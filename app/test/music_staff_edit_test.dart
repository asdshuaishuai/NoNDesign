/// 五线谱点击编辑纯函数测试（task-14）。
///
/// 覆盖任务要求：追加到空/满/半满小节、按拍号休止补齐、目标小节定位与插新小节、
/// 非法音高/时值/轨道/小节、鼓轨鼓件名（含字符串音名归一）、确定性/未知字段保留，
/// 以及状态行文案纯函数。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nondesign/core/music/music_compile.dart';
import 'package:nondesign/core/music/music_edit.dart';
import 'package:nondesign/core/music/music_score.dart';
import 'package:nondesign/core/music/music_staff_edit.dart';

// ---------------------------------------------------------------------------
// 测试夹具
// ---------------------------------------------------------------------------

MusicEvent _quarter(
  String id, {
  String step = 'C',
  int octave = 5,
  int alter = 0,
}) => MusicEvent(
  id: id,
  isRest: false,
  durNum: 1,
  durDen: 4,
  step: step,
  alter: alter,
  octave: octave,
);

MusicMeasure _fullMeasure(String id, {String prefix = ''}) => MusicMeasure(
  id: id,
  events: <MusicEvent>[
    _quarter('${prefix}a', step: 'C', octave: 5),
    _quarter('${prefix}b', step: 'D', octave: 5),
    _quarter('${prefix}c', step: 'E', octave: 5),
    _quarter('${prefix}d', step: 'F', octave: 5),
  ],
);

MusicMeasure _emptyMeasure(String id) =>
    MusicMeasure(id: id, events: const <MusicEvent>[]);

MusicEvent _rest(String id, {int num = 1, int den = 4}) =>
    MusicEvent(id: id, isRest: true, durNum: num, durDen: den);

/// 小节内第 [index] 个事件的起点（相对小节开头，全音符单位）。
double _startOffsetOf(MusicMeasure measure, int index) {
  double start = 0;
  for (int i = 0; i < index; i++) {
    start += measure.events[i].durationValue;
  }
  return start;
}

/// 事件起点 → 小节内 0 起拍下标（以拍号分母为一拍，例：4/4 里 0.25 = 第 2 拍）。
int _beatIndexOf(MusicMeasure measure, int index, List<int> timeSig) =>
    (_startOffsetOf(measure, index) * timeSig[1]).round();

MusicTrack _track(int measures, {String id = 'melody', bool full = true}) =>
    MusicTrack(
      id: id,
      name: '主旋律',
      instrument: 'piano',
      clef: 'treble',
      measures: <MusicMeasure>[
        for (int i = 0; i < measures; i++)
          full
              ? _fullMeasure('m${i + 1}', prefix: 'n${i + 1}')
              : _emptyMeasure('m${i + 1}'),
      ],
    );

MusicScore _score({
  int measures = 1,
  bool full = true,
  List<int> timeSig = const <int>[4, 4],
  List<MusicTrack>? tracks,
}) => MusicScore(
  title: '追加测试',
  tempo: 96,
  timeSig: timeSig,
  keySig: 'C',
  tracks: tracks ?? <MusicTrack>[_track(measures, full: full)],
);

/// 原始 JSON（带未知字段；鼓轨用字符串音名写法，验证编辑前归一）。
Map<String, Object?> _rawScore({bool drums = false}) => <String, Object?>{
  'schemaVersion': 1,
  'title': '原始谱',
  'tempo': 96,
  'timeSig': <int>[4, 4],
  'keySig': 'C',
  'composer': 'NaN',
  'tracks': <Object?>[
    <String, Object?>{
      'id': drums ? 'dr' : 'melody',
      'name': drums ? '鼓组' : '主旋律',
      'instrument': drums ? 'drums' : 'piano',
      'clef': 'treble',
      'color': '#101010',
      'measures': <Object?>[
        <String, Object?>{
          'id': 'm1',
          'rehearsal': 'A',
          'events': <Object?>[
            if (drums)
              <String, Object?>{
                'id': 'k1',
                'dur': <String, Object?>{'num': 1, 'den': 1},
                'pitch': 'kick',
              }
            else
              <String, Object?>{
                'id': 'n1',
                'type': 'note',
                'pitch': <String, Object?>{
                  'step': 'C',
                  'alter': 0,
                  'octave': 5,
                },
                'dur': <String, Object?>{'num': 1, 'den': 1},
                'accent': true,
              },
          ],
        },
      ],
    },
  ],
};

MusicScore _parsedRaw({bool drums = false}) {
  final parsed = parseMusicScore(_rawScore(drums: drums));
  expect(parsed.score, isNotNull, reason: '测试夹具本身必须是合法乐谱');
  return parsed.score!;
}

Matcher _failure(String code) => throwsA(
  isA<MusicEditFailure>().having((MusicEditFailure f) => f.code, 'code', code),
);

/// 编辑结果必须能被 parse 接受 + verify 通过 + 能编译播放计划。
void _expectAccepted(MusicScore score) {
  final parsed = parseMusicScore(score.toJson());
  expect(parsed.score, isNotNull, reason: '编辑结果必须能被 parseMusicScore 接受');
  expect(verifyMusicScore(score.toJson()).verified, isTrue);
  expect(() => compileMusicScore(score), returnsNormally);
}

double _durationValue(MusicMeasure measure) =>
    measure.events.fold<double>(0, (sum, event) => sum + event.durationValue);

Set<String> _eventIds(MusicScore score) => <String>{
  for (final track in score.tracks)
    for (final measure in track.measures)
      for (final event in measure.events) event.id,
};

int _eventCount(MusicScore score) => score.tracks
    .expand((MusicTrack track) => track.measures)
    .expand((MusicMeasure measure) => measure.events)
    .length;

void main() {
  group('空小节/半满小节：原地追加并休止补齐', () {
    test('空小节点击 → 音符落在目标小节，休止补到 4/4', () {
      final MusicScore base = _score(measures: 1, full: false);
      final MusicScore edited = appendNoteAt(
        base,
        trackIndex: 0,
        step: 'C',
        octave: 5,
        targetMeasureIndex: 0,
      );
      expect(edited.tracks.single.measures, hasLength(1), reason: '空小节放得下，不新开');
      final MusicMeasure measure = edited.tracks.single.measures.single;
      expect(measure.events, hasLength(2));
      final MusicEvent note = measure.events.first;
      expect(note.isRest, isFalse);
      expect(note.step, 'C');
      expect(note.alter, 0);
      expect(note.octave, 5);
      expect(note.durNum, 1);
      expect(note.durDen, 4);
      final MusicEvent rest = measure.events.last;
      expect(rest.isRest, isTrue);
      expect(rest.durNum, 3);
      expect(rest.durDen, 4);
      expect(_durationValue(measure), closeTo(1.0, 1e-9));
      expect(measure.id, 'm1', reason: '原地修改保留小节 id');
      _expectAccepted(edited);
      // 输入乐谱不被就地修改（纯函数）。
      expect(base.tracks.single.measures.single.events, isEmpty);
    });

    test('不指定 targetMeasureIndex → 默认追加到轨道最后一个小节', () {
      final MusicScore base = _score(measures: 2, full: false);
      final MusicScore edited = appendNoteAt(
        base,
        trackIndex: 0,
        step: 'D',
        octave: 5,
      );
      expect(edited.tracks.single.measures, hasLength(2));
      final MusicMeasure last = edited.tracks.single.measures.last;
      expect(last.id, 'm2');
      expect(last.events.first.step, 'D');
      expect(_durationValue(last), closeTo(1.0, 1e-9));
      expect(edited.tracks.single.measures.first.events, isEmpty);
      _expectAccepted(edited);
    });

    test('已有内容但已用休止补满的小节（半音 + 半休止）按满小节处理 → 新开小节', () {
      // 契约要求非空小节的时值总和 == 拍号，所以「写了半个小节」也必须带休止补齐；
      // 这样的目标小节没有剩余时值，追加音符会落到它后面的新小节。
      final MusicScore score = _score(
        tracks: <MusicTrack>[
          MusicTrack(
            id: 'melody',
            name: '主旋律',
            instrument: 'piano',
            measures: <MusicMeasure>[
              MusicMeasure(
                id: 'm1',
                events: <MusicEvent>[
                  MusicEvent(
                    id: 'h1',
                    isRest: false,
                    durNum: 1,
                    durDen: 2,
                    step: 'E',
                    octave: 5,
                  ),
                  MusicEvent(id: 'hr1', isRest: true, durNum: 1, durDen: 2),
                ],
              ),
            ],
          ),
        ],
      );
      final MusicScore edited = appendNoteAt(
        score,
        trackIndex: 0,
        step: 'G',
        octave: 5,
        targetMeasureIndex: 0,
      );
      expect(edited.tracks.single.measures, hasLength(2));
      final MusicMeasure original = edited.tracks.single.measures.first;
      expect(original.id, 'm1');
      expect(original.events, hasLength(2), reason: '原小节已被休止补满，内容保留');
      expect(original.events.first.id, 'h1');
      final MusicMeasure added = edited.tracks.single.measures.last;
      expect(added.events, hasLength(2));
      expect(added.events.first.step, 'G');
      expect(added.events.last.isRest, isTrue);
      expect(_durationValue(added), closeTo(1.0, 1e-9));
      _expectAccepted(edited);
    });

    test('3/4 拍：空小节追加四分音符 → 休止补 1/2', () {
      final MusicScore base = _score(
        measures: 1,
        full: false,
        timeSig: const <int>[3, 4],
      );
      final MusicScore edited = appendNoteAt(
        base,
        trackIndex: 0,
        step: 'A',
        octave: 4,
        targetMeasureIndex: 0,
      );
      final MusicMeasure measure = edited.tracks.single.measures.single;
      expect(measure.events, hasLength(2));
      expect(measure.events.last.isRest, isTrue);
      expect(measure.events.last.durNum, 1);
      expect(measure.events.last.durDen, 2);
      expect(_durationValue(measure), closeTo(0.75, 1e-9));
      _expectAccepted(edited);
    });

    test('整小节刚好放得下的时值 → 不补休止', () {
      final MusicScore base = _score(measures: 1, full: false);
      final MusicScore edited = appendNoteAt(
        base,
        trackIndex: 0,
        step: 'C',
        octave: 5,
        durNum: 1,
        durDen: 1,
        targetMeasureIndex: 0,
      );
      final MusicMeasure measure = edited.tracks.single.measures.single;
      expect(measure.events, hasLength(1), reason: '1/1 正好填满 4/4，不需要休止');
      expect(measure.events.single.durNum, 1);
      expect(measure.events.single.durDen, 1);
      expect(_durationValue(measure), closeTo(1.0, 1e-9));
      _expectAccepted(edited);
    });

    test('中间空小节命中：原地追加，不移动后面的小节', () {
      final MusicScore base = _score(measures: 3, full: false);
      final MusicScore edited = appendNoteAt(
        base,
        trackIndex: 0,
        step: 'F',
        octave: 4,
        targetMeasureIndex: 1,
      );
      expect(edited.tracks.single.measures, hasLength(3));
      expect(edited.tracks.single.measures[1].id, 'm2');
      expect(edited.tracks.single.measures[1].events, hasLength(2));
      expect(edited.tracks.single.measures[2].id, 'm3');
      expect(edited.tracks.single.measures[0].events, isEmpty);
      _expectAccepted(edited);
    });
  });

  group('满小节：新开/插入小节', () {
    test('满小节且是最后一个小节 → 新开小节，原小节不动', () {
      final MusicScore base = _score(measures: 1, full: true);
      final MusicScore edited = appendNoteAt(
        base,
        trackIndex: 0,
        step: 'C',
        octave: 5,
        targetMeasureIndex: 0,
      );
      expect(
        edited.tracks.single.measures,
        hasLength(2),
        reason: '4/4 已满，新开小节',
      );
      expect(edited.tracks.single.measures.first.events, hasLength(4));
      final MusicMeasure added = edited.tracks.single.measures.last;
      expect(added.id, isNot('m1'));
      expect(added.events, hasLength(2));
      expect(added.events.first.step, 'C');
      expect(added.events.first.octave, 5);
      expect(added.events.last.isRest, isTrue);
      expect(_durationValue(added), closeTo(1.0, 1e-9));
      _expectAccepted(edited);
    });

    test('满小节在中间 → 在它后面插入新小节，后面的小节整体后移但内容不变', () {
      final MusicScore base = _score(measures: 3, full: true);
      final MusicScore edited = appendNoteAt(
        base,
        trackIndex: 0,
        step: 'B',
        octave: 4,
        targetMeasureIndex: 0,
      );
      final List<MusicMeasure> measures = edited.tracks.single.measures;
      expect(measures, hasLength(4));
      expect(measures[0].id, 'm1');
      expect(measures[0].events, hasLength(4), reason: '满小节内容不被改动');
      expect(measures[1].events, hasLength(2), reason: '新小节在目标后面');
      expect(measures[1].events.first.step, 'B');
      expect(measures[2].id, 'm2', reason: '原第 2 小节后移到下标 2');
      expect(measures[3].id, 'm3');
      expect(measures[2].events, hasLength(4));
      _expectAccepted(edited);
    });

    test('小节上限 256：目标满小节再追加 → score_too_large', () {
      final List<MusicMeasure> measures = <MusicMeasure>[
        for (int i = 0; i < 255; i++) _emptyMeasure('m${i + 1}'),
        _fullMeasure('m256', prefix: 'last_'),
      ];
      final MusicScore base = _score(
        tracks: <MusicTrack>[
          MusicTrack(
            id: 'melody',
            name: '主旋律',
            instrument: 'piano',
            measures: measures,
          ),
        ],
      );
      expect(
        () => appendNoteAt(
          base,
          trackIndex: 0,
          targetMeasureIndex: 255,
          step: 'C',
          octave: 5,
        ),
        _failure('score_too_large'),
      );
    });
  });

  group('非法输入：可控 MusicEditFailure', () {
    test('轨道下标越界 → unknown_track', () {
      final MusicScore base = _score();
      for (final int index in <int>[-1, 1, 99]) {
        expect(
          () => appendNoteAt(base, trackIndex: index),
          _failure('unknown_track'),
          reason: 'trackIndex=$index',
        );
      }
    });

    test('非法音高/八度/升降 → invalid_pitch', () {
      final MusicScore base = _score(measures: 1, full: false);
      expect(
        () => appendNoteAt(base, trackIndex: 0, step: 'H'),
        _failure('invalid_pitch'),
      );
      expect(
        () => appendNoteAt(base, trackIndex: 0, octave: 10),
        _failure('invalid_pitch'),
      );
      expect(
        () => appendNoteAt(base, trackIndex: 0, octave: -1),
        _failure('invalid_pitch'),
      );
      expect(
        () => appendNoteAt(base, trackIndex: 0, alter: 2),
        _failure('invalid_pitch'),
      );
      expect(
        () => appendNoteAt(base, trackIndex: 0, alter: -2),
        _failure('invalid_pitch'),
      );
    });

    test('非法时值/超过拍号 → invalid_duration', () {
      final MusicScore base = _score(measures: 1, full: false);
      expect(
        () => appendNoteAt(base, trackIndex: 0, durNum: 0),
        _failure('invalid_duration'),
      );
      expect(
        () => appendNoteAt(base, trackIndex: 0, durDen: 0),
        _failure('invalid_duration'),
      );
      expect(
        () => appendNoteAt(base, trackIndex: 0, durNum: 5, durDen: 4),
        _failure('invalid_duration'),
      );
      expect(
        () => appendNoteAt(base, trackIndex: 0, durNum: 3, durDen: 2),
        _failure('invalid_duration'),
        reason: '1.5 拍超过 4/4 小节容量',
      );
    });

    test('targetMeasureIndex 越界 → invalid_measure', () {
      final MusicScore base = _score(measures: 2, full: false);
      for (final int target in <int>[-1, 2, 99]) {
        expect(
          () => appendNoteAt(base, trackIndex: 0, targetMeasureIndex: target),
          _failure('invalid_measure'),
          reason: 'target=$target',
        );
      }
    });

    test('输入乐谱本身不合法 → invalid_input，不产出坏 score', () {
      final MusicScore bad = _score();
      final MusicScore broken = MusicScore(
        title: bad.title,
        tempo: 10, // 低于 20，parser 拒绝
        timeSig: bad.timeSig,
        keySig: bad.keySig,
        tracks: bad.tracks,
      );
      expect(
        () => appendNoteAt(broken, trackIndex: 0),
        _failure('invalid_input'),
      );
    });
  });

  group('鼓轨：鼓件名或显性拒绝', () {
    test('鼓轨必须给合法鼓件名：缺省/未知鼓件 → invalid_drum', () {
      final MusicScore drums = _parsedRaw(drums: true);
      expect(
        () => appendNoteAt(drums, trackIndex: 0, targetMeasureIndex: 0),
        _failure('invalid_drum'),
        reason: '鼓轨不按普通音高写',
      );
      expect(
        () => appendNoteAt(
          drums,
          trackIndex: 0,
          drum: 'cowbell',
          targetMeasureIndex: 0,
        ),
        _failure('invalid_drum'),
      );
    });

    test('字符串音名鼓轨（pitch:"kick"）编辑后仍可解析/编译；新事件带鼓件名', () {
      final MusicScore drums = _parsedRaw(drums: true);
      expect(
        drums.tracks.single.measures.single.events.single.extra['drum'],
        'kick',
      );
      expect(drums.tracks.single.measures.single.events.single.step, '');
      final MusicScore edited = appendNoteAt(
        drums,
        trackIndex: 0,
        drum: 'snare',
        targetMeasureIndex: 0,
      );
      expect(edited.tracks.single.measures, hasLength(2), reason: '原小节满，新开');
      final MusicEvent added = edited.tracks.single.measures.last.events.first;
      expect(added.isRest, isFalse);
      expect(added.extra['drum'], 'snare');
      expect(musicDrumNames.contains(added.extra['drum']), isTrue);
      expect(added.step, 'C', reason: '鼓件事件仍带合法占位音高');
      expect(added.durNum, 1);
      expect(added.durDen, 4);
      // 原字符串音名事件被归一为合法占位音高，鼓件名保留。
      final MusicEvent original =
          edited.tracks.single.measures.first.events.single;
      expect(original.extra['drum'], 'kick');
      expect(original.step, 'C');
      _expectAccepted(edited);
    });
  });

  group('确定性、未知字段与文案', () {
    test('同一输入两次追加得到相同 JSON；事件 id 全局唯一；未知字段保留', () {
      final MusicScore base = _parsedRaw();
      final MusicScore first = appendNoteAt(
        base,
        trackIndex: 0,
        step: 'A',
        alter: 1,
        octave: 4,
        targetMeasureIndex: 0,
      );
      final MusicScore second = appendNoteAt(
        _parsedRaw(),
        trackIndex: 0,
        step: 'A',
        alter: 1,
        octave: 4,
        targetMeasureIndex: 0,
      );
      expect(jsonEncode(first.toJson()), jsonEncode(second.toJson()));
      expect(
        _eventIds(first).length,
        _eventCount(first),
        reason: '事件 id 必须全局唯一',
      );
      expect(first.extra['composer'], 'NaN', reason: 'score 级未知字段保留');
      final MusicTrack track = first.tracks.single;
      expect(track.extra['color'], '#101010', reason: 'track 级未知字段保留');
      expect(track.measures.first.extra['rehearsal'], 'A', reason: '原小节未知字段保留');
      expect(
        track.measures.first.events.first.extra['accent'],
        isTrue,
        reason: '原事件未知字段保留',
      );
      final MusicEvent added = track.measures.last.events.first;
      expect(added.step, 'A');
      expect(added.alter, 1);
      expect(added.octave, 4);
      _expectAccepted(first);
    });

    test('文案纯函数：音高/时值/鼓件/确认消息', () {
      expect(musicNoteLabel(step: 'C', octave: 5), 'C5');
      expect(musicNoteLabel(step: 'c', octave: 5, alter: 1), 'C#5');
      expect(musicNoteLabel(step: 'B', octave: 4, alter: -1), 'Bb4');
      expect(musicDurationLabel(1, 1), '全音符');
      expect(musicDurationLabel(1, 2), '二分音符');
      expect(musicDurationLabel(1, 4), '四分音符');
      expect(musicDurationLabel(1, 8), '八分音符');
      expect(musicDurationLabel(1, 16), '十六分音符');
      expect(musicDurationLabel(2, 16), '八分音符', reason: '先约分再命名');
      expect(musicDurationLabel(3, 8), '3/8 音符');
      expect(musicDurationLabel(0, 4), '未知时值');
      expect(musicDrumLabel('kick'), '底鼓');
      expect(musicDrumLabel('snare'), '军鼓');
      expect(musicDrumLabel('unknown'), 'unknown');
      expect(musicStaffInsertMessage(step: 'C', octave: 5), '已插入 C5 四分音符');
      expect(
        musicStaffInsertMessage(
          step: 'C',
          octave: 5,
          alter: 1,
          durNum: 1,
          durDen: 2,
        ),
        '已插入 C#5 二分音符',
      );
      expect(musicStaffInsertMessage(drum: 'snare'), '已插入 军鼓 四分音符');
      // task-16：按拍位插入 / 删除的确认文案。
      expect(
        musicStaffInsertAtMessage(beatIndex: 0, step: 'C', octave: 5),
        '已在第 1 拍插入 C5',
      );
      expect(
        musicStaffInsertAtMessage(beatIndex: 1, step: 'C', octave: 5),
        '已在第 2 拍插入 C5',
      );
      expect(
        musicStaffInsertAtMessage(
          beatIndex: 2,
          step: 'A',
          alter: -1,
          octave: 4,
        ),
        '已在第 3 拍插入 Ab4',
      );
      expect(
        musicStaffInsertAtMessage(beatIndex: 0, drum: 'snare'),
        '已在第 1 拍插入 军鼓',
      );
      expect(musicStaffDeleteMessage(), '已删除音符');
    });
  });

  group('按拍位插入（task-16）', () {
    test('空小节第 1 拍插入：音符在最前，其余休止补齐到 4/4', () {
      final MusicScore base = _score(measures: 1, full: false);
      final MusicScore edited = insertNoteAt(
        base,
        trackIndex: 0,
        measureIndex: 0,
        beatIndex: 0,
        step: 'C',
        octave: 5,
      );
      expect(edited.tracks.single.measures, hasLength(1));
      final MusicMeasure measure = edited.tracks.single.measures.single;
      expect(measure.id, 'm1');
      expect(measure.events, hasLength(2));
      final MusicEvent note = measure.events.first;
      expect(note.isRest, isFalse);
      expect(note.step, 'C');
      expect(note.octave, 5);
      expect(note.durNum, 1);
      expect(note.durDen, 4);
      expect(_beatIndexOf(measure, 0, const <int>[4, 4]), 0);
      expect(measure.events.last.isRest, isTrue);
      expect(measure.events.last.durNum, 3);
      expect(measure.events.last.durDen, 4);
      expect(_durationValue(measure), closeTo(1.0, 1e-9));
      _expectAccepted(edited);
    });

    test('空小节第 2 拍插入：前面补 1/4 休止、后面补 1/2 休止，起始拍 = 2', () {
      final MusicScore base = _score(measures: 1, full: false);
      final MusicScore edited = insertNoteAt(
        base,
        trackIndex: 0,
        measureIndex: 0,
        beatIndex: 1,
        step: 'D',
        octave: 5,
      );
      final MusicMeasure measure = edited.tracks.single.measures.single;
      expect(measure.events, hasLength(3));
      expect(measure.events[0].isRest, isTrue);
      expect(measure.events[0].durationValue, closeTo(0.25, 1e-9));
      expect(measure.events[1].isRest, isFalse);
      expect(measure.events[1].step, 'D');
      expect(measure.events[1].durationValue, closeTo(0.25, 1e-9));
      expect(measure.events[2].isRest, isTrue);
      expect(measure.events[2].durationValue, closeTo(0.5, 1e-9));
      expect(
        _beatIndexOf(measure, 1, const <int>[4, 4]),
        1,
        reason: '0 起拍下标 1 = 第 2 拍',
      );
      expect(_startOffsetOf(measure, 1), closeTo(0.25, 1e-9));
      expect(_durationValue(measure), closeTo(1.0, 1e-9));
      _expectAccepted(edited);
    });

    test('空小节最后一拍（边界拍位）插入：前面 3/4 休止，音符在最后一拍', () {
      final MusicScore base = _score(measures: 1, full: false);
      final MusicScore edited = insertNoteAt(
        base,
        trackIndex: 0,
        measureIndex: 0,
        beatIndex: 3,
        step: 'F',
        octave: 4,
      );
      final MusicMeasure measure = edited.tracks.single.measures.single;
      expect(measure.events, hasLength(2));
      expect(measure.events.first.isRest, isTrue);
      expect(measure.events.first.durationValue, closeTo(0.75, 1e-9));
      expect(measure.events.last.isRest, isFalse);
      expect(measure.events.last.durationValue, closeTo(0.25, 1e-9));
      expect(_beatIndexOf(measure, 1, const <int>[4, 4]), 3);
      expect(_durationValue(measure), closeTo(1.0, 1e-9));
      _expectAccepted(edited);
    });

    test('休止覆盖目标拍位：裁剪休止后插入（不按满位失败）', () {
      final MusicScore base = _score(
        tracks: <MusicTrack>[
          MusicTrack(
            id: 'melody',
            name: '主旋律',
            instrument: 'piano',
            clef: 'treble',
            measures: <MusicMeasure>[
              MusicMeasure(
                id: 'm1',
                events: <MusicEvent>[_rest('r1', num: 1, den: 1)],
              ),
            ],
          ),
        ],
      );
      final MusicScore edited = insertNoteAt(
        base,
        trackIndex: 0,
        measureIndex: 0,
        beatIndex: 1,
        step: 'E',
        octave: 5,
      );
      final MusicMeasure measure = edited.tracks.single.measures.single;
      expect(measure.events, hasLength(3));
      expect(measure.events[0].isRest, isTrue);
      expect(measure.events[0].durationValue, closeTo(0.25, 1e-9));
      expect(measure.events[1].isRest, isFalse);
      expect(measure.events[1].durationValue, closeTo(0.25, 1e-9));
      expect(measure.events[2].isRest, isTrue);
      expect(measure.events[2].durationValue, closeTo(0.5, 1e-9));
      expect(_eventIds(edited).contains('r1'), isFalse, reason: '被裁剪的休止换新 id');
      expect(_durationValue(measure), closeTo(1.0, 1e-9));
      _expectAccepted(edited);
    });

    test('满位策略：目标拍位已有音符 → beat_occupied 显性失败（不隐式挪音）', () {
      final MusicScore quarters = _score(measures: 1, full: true);
      expect(
        () => insertNoteAt(
          quarters,
          trackIndex: 0,
          measureIndex: 0,
          beatIndex: 1,
          step: 'G',
          octave: 5,
        ),
        _failure('beat_occupied'),
      );
      // 跨拍的二分音符也覆盖第 2 拍：同样显性失败。
      final MusicScore halfSpan = _score(
        tracks: <MusicTrack>[
          MusicTrack(
            id: 'melody',
            name: '主旋律',
            instrument: 'piano',
            clef: 'treble',
            measures: <MusicMeasure>[
              MusicMeasure(
                id: 'm1',
                events: <MusicEvent>[
                  MusicEvent(
                    id: 'h1',
                    isRest: false,
                    durNum: 1,
                    durDen: 2,
                    step: 'C',
                    octave: 5,
                  ),
                  _rest('r1', num: 1, den: 2),
                ],
              ),
            ],
          ),
        ],
      );
      expect(
        () => insertNoteAt(
          halfSpan,
          trackIndex: 0,
          measureIndex: 0,
          beatIndex: 1,
          step: 'G',
          octave: 5,
        ),
        _failure('beat_occupied'),
      );
    });

    test('非法拍位 → invalid_beat（负数/超过拍数/3/4 的第 4 拍）', () {
      final MusicScore base = _score(measures: 1, full: false);
      for (final int beat in <int>[-1, 4, 99]) {
        expect(
          () => insertNoteAt(
            base,
            trackIndex: 0,
            measureIndex: 0,
            beatIndex: beat,
          ),
          _failure('invalid_beat'),
          reason: 'beatIndex=$beat',
        );
      }
      final MusicScore threeFour = _score(
        measures: 1,
        full: false,
        timeSig: const <int>[3, 4],
      );
      expect(
        () => insertNoteAt(
          threeFour,
          trackIndex: 0,
          measureIndex: 0,
          beatIndex: 3,
        ),
        _failure('invalid_beat'),
        reason: '3/4 没有第 4 拍',
      );
    });

    test('时值放不下 → invalid_duration（从该拍起越界/超过拍号/非法时值）', () {
      final MusicScore base = _score(measures: 1, full: false);
      expect(
        () => insertNoteAt(
          base,
          trackIndex: 0,
          measureIndex: 0,
          beatIndex: 3,
          durNum: 1,
          durDen: 2,
        ),
        _failure('invalid_duration'),
        reason: '第 4 拍 + 二分音符超出小节',
      );
      expect(
        () => insertNoteAt(base, trackIndex: 0, measureIndex: 0, durNum: 5),
        _failure('invalid_duration'),
        reason: '5/4 超过 4/4 小节容量',
      );
      expect(
        () => insertNoteAt(base, trackIndex: 0, measureIndex: 0, durNum: 0),
        _failure('invalid_duration'),
      );
      expect(
        () => insertNoteAt(base, trackIndex: 0, measureIndex: 0, durDen: 0),
        _failure('invalid_duration'),
      );
    });

    test('非法轨道/小节/音高 → 可控失败码', () {
      final MusicScore base = _score(measures: 2, full: false);
      for (final int track in <int>[-1, 1, 99]) {
        expect(
          () => insertNoteAt(base, trackIndex: track, measureIndex: 0),
          _failure('unknown_track'),
          reason: 'trackIndex=$track',
        );
      }
      for (final int measure in <int>[-1, 2, 99]) {
        expect(
          () => insertNoteAt(
            base,
            trackIndex: 0,
            measureIndex: measure,
            beatIndex: 0,
          ),
          _failure('invalid_measure'),
          reason: 'measureIndex=$measure',
        );
      }
      expect(
        () => insertNoteAt(base, trackIndex: 0, measureIndex: 0, step: 'H'),
        _failure('invalid_pitch'),
      );
      expect(
        () => insertNoteAt(base, trackIndex: 0, measureIndex: 0, octave: 10),
        _failure('invalid_pitch'),
      );
      expect(
        () => insertNoteAt(base, trackIndex: 0, measureIndex: 0, alter: 2),
        _failure('invalid_pitch'),
      );
    });

    test('鼓轨：缺鼓件名显性拒绝；给合法鼓件名可插入且带占位音高', () {
      final MusicScore drums = _score(
        tracks: <MusicTrack>[
          MusicTrack(
            id: 'drums',
            name: '鼓组',
            instrument: 'drums',
            clef: 'treble',
            measures: <MusicMeasure>[
              MusicMeasure(id: 'm1', events: const <MusicEvent>[]),
            ],
          ),
        ],
      );
      expect(
        () => insertNoteAt(drums, trackIndex: 0, measureIndex: 0),
        _failure('invalid_drum'),
      );
      expect(
        () => insertNoteAt(
          drums,
          trackIndex: 0,
          measureIndex: 0,
          drum: 'cowbell',
        ),
        _failure('invalid_drum'),
      );
      final MusicScore edited = insertNoteAt(
        drums,
        trackIndex: 0,
        measureIndex: 0,
        beatIndex: 0,
        drum: 'snare',
      );
      final MusicEvent added =
          edited.tracks.single.measures.single.events.first;
      expect(added.isRest, isFalse);
      expect(added.extra['drum'], 'snare');
      expect(added.step, 'C', reason: '鼓件事件仍带合法占位音高');
      expect(
        _durationValue(edited.tracks.single.measures.single),
        closeTo(1.0, 1e-9),
      );
      _expectAccepted(edited);
    });

    test('跨拍时值（二分音符占两拍）在空位插入：起始拍正确、休止前后补齐', () {
      final MusicScore base = _score(measures: 1, full: false);
      final MusicScore edited = insertNoteAt(
        base,
        trackIndex: 0,
        measureIndex: 0,
        beatIndex: 1,
        step: 'G',
        octave: 4,
        durNum: 1,
        durDen: 2,
      );
      final MusicMeasure measure = edited.tracks.single.measures.single;
      expect(measure.events, hasLength(3));
      expect(measure.events[0].durationValue, closeTo(0.25, 1e-9));
      expect(measure.events[1].isRest, isFalse);
      expect(measure.events[1].durationValue, closeTo(0.5, 1e-9));
      expect(measure.events[2].durationValue, closeTo(0.25, 1e-9));
      expect(_beatIndexOf(measure, 1, const <int>[4, 4]), 1);
      expect(_durationValue(measure), closeTo(1.0, 1e-9));
      _expectAccepted(edited);
    });

    test('3/4 第 2 拍插入：休止补到 3/4，拍位/时值都对', () {
      final MusicScore base = _score(
        measures: 1,
        full: false,
        timeSig: const <int>[3, 4],
      );
      final MusicScore edited = insertNoteAt(
        base,
        trackIndex: 0,
        measureIndex: 0,
        beatIndex: 1,
        step: 'A',
        octave: 4,
      );
      final MusicMeasure measure = edited.tracks.single.measures.single;
      expect(measure.events, hasLength(3));
      expect(measure.events[1].isRest, isFalse);
      expect(_beatIndexOf(measure, 1, const <int>[3, 4]), 1);
      expect(_durationValue(measure), closeTo(0.75, 1e-9));
      _expectAccepted(edited);
    });

    test('中间小节插入：不动其它小节，未知字段与 id 保留', () {
      final MusicScore base = MusicScore(
        title: '保留字段',
        tempo: 96,
        timeSig: const <int>[4, 4],
        keySig: 'C',
        extra: <String, Object?>{'composer': 'NaN'},
        tracks: <MusicTrack>[
          MusicTrack(
            id: 'melody',
            name: '主旋律',
            instrument: 'piano',
            clef: 'treble',
            extra: <String, Object?>{'color': '#101010'},
            measures: <MusicMeasure>[
              MusicMeasure(
                id: 'm1',
                events: const <MusicEvent>[],
                extra: const <String, Object?>{'rehearsal': 'A'},
              ),
              MusicMeasure(
                id: 'm2',
                events: const <MusicEvent>[],
                extra: const <String, Object?>{'rehearsal': 'B'},
              ),
              MusicMeasure(id: 'm3', events: const <MusicEvent>[]),
            ],
          ),
        ],
      );
      final MusicScore edited = insertNoteAt(
        base,
        trackIndex: 0,
        measureIndex: 1,
        beatIndex: 2,
        step: 'E',
        octave: 4,
      );
      final List<MusicMeasure> measures = edited.tracks.single.measures;
      expect(measures, hasLength(3));
      expect(measures.map((MusicMeasure m) => m.id), <String>[
        'm1',
        'm2',
        'm3',
      ]);
      expect(measures[0].events, isEmpty);
      expect(measures[1].events, hasLength(3));
      expect(measures[2].events, isEmpty);
      expect(measures[1].extra['rehearsal'], 'B', reason: '被编辑小节的未知字段保留');
      expect(measures[0].extra['rehearsal'], 'A', reason: '未编辑小节原样保留');
      expect(edited.extra['composer'], 'NaN', reason: 'score 级未知字段保留');
      expect(
        edited.tracks.single.extra['color'],
        '#101010',
        reason: 'track 级未知字段保留',
      );
      expect(_beatIndexOf(measures[1], 1, const <int>[4, 4]), 2);
      _expectAccepted(edited);
    });

    test('确定性：同一输入两次插入得到相同 JSON；事件 id 全局唯一', () {
      final MusicScore first = insertNoteAt(
        _score(measures: 2, full: false),
        trackIndex: 0,
        measureIndex: 0,
        beatIndex: 2,
        step: 'A',
        alter: 1,
        octave: 4,
      );
      final MusicScore second = insertNoteAt(
        _score(measures: 2, full: false),
        trackIndex: 0,
        measureIndex: 0,
        beatIndex: 2,
        step: 'A',
        alter: 1,
        octave: 4,
      );
      expect(jsonEncode(first.toJson()), jsonEncode(second.toJson()));
      expect(_eventIds(first).length, _eventCount(first));
      _expectAccepted(first);
    });
  });

  group('删除音符（task-16）', () {
    test('满小节删第一个四分音符 → 同拍位等长休止，其它音符与 id 不变', () {
      final MusicScore base = _score(measures: 1, full: true);
      final MusicScore edited = deleteNoteAt(
        base,
        trackIndex: 0,
        measureIndex: 0,
        eventId: 'n1a',
      );
      final MusicMeasure measure = edited.tracks.single.measures.single;
      expect(measure.events, hasLength(4));
      expect(measure.events.first.isRest, isTrue);
      expect(measure.events.first.durationValue, closeTo(0.25, 1e-9));
      expect(measure.events[1].id, 'n1b');
      expect(measure.events[2].id, 'n1c');
      expect(measure.events[3].id, 'n1d');
      expect(_eventIds(edited).contains('n1a'), isFalse);
      expect(_beatIndexOf(measure, 0, const <int>[4, 4]), 0);
      expect(_durationValue(measure), closeTo(1.0, 1e-9));
      _expectAccepted(edited);
    });

    test('删全音符 → 整小节休止 1/1，小节时值总和不变', () {
      final MusicScore base = _score(
        tracks: <MusicTrack>[
          MusicTrack(
            id: 'melody',
            name: '主旋律',
            instrument: 'piano',
            clef: 'treble',
            measures: <MusicMeasure>[
              MusicMeasure(
                id: 'm1',
                events: <MusicEvent>[
                  MusicEvent(
                    id: 'w1',
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
      final MusicScore edited = deleteNoteAt(
        base,
        trackIndex: 0,
        measureIndex: 0,
        eventId: 'w1',
      );
      final MusicMeasure measure = edited.tracks.single.measures.single;
      expect(measure.events, hasLength(1));
      expect(measure.events.single.isRest, isTrue);
      expect(measure.events.single.durNum, 1);
      expect(measure.events.single.durDen, 1);
      expect(_durationValue(measure), closeTo(1.0, 1e-9));
      _expectAccepted(edited);
    });

    test('非法/不存在的事件 id → invalid_event 显性失败', () {
      final MusicScore base = _score(measures: 1, full: true);
      for (final String id in <String>['missing', '', '   ']) {
        expect(
          () => deleteNoteAt(base, trackIndex: 0, measureIndex: 0, eventId: id),
          _failure('invalid_event'),
          reason: 'eventId="$id"',
        );
      }
    });

    test('事件 id 属于别的小节 → 只在目标小节内找，invalid_event', () {
      final MusicScore base = _score(measures: 2, full: true);
      expect(
        () =>
            deleteNoteAt(base, trackIndex: 0, measureIndex: 0, eventId: 'n2a'),
        _failure('invalid_event'),
      );
      expect(
        () =>
            deleteNoteAt(base, trackIndex: 0, measureIndex: 1, eventId: 'n1a'),
        _failure('invalid_event'),
      );
    });

    test('非法轨道/小节 → unknown_track / invalid_measure', () {
      final MusicScore base = _score(measures: 1, full: true);
      for (final int track in <int>[-1, 1, 99]) {
        expect(
          () => deleteNoteAt(
            base,
            trackIndex: track,
            measureIndex: 0,
            eventId: 'n1a',
          ),
          _failure('unknown_track'),
          reason: 'trackIndex=$track',
        );
      }
      for (final int measure in <int>[-1, 1, 99]) {
        expect(
          () => deleteNoteAt(
            base,
            trackIndex: 0,
            measureIndex: measure,
            eventId: 'n1a',
          ),
          _failure('invalid_measure'),
          reason: 'measureIndex=$measure',
        );
      }
    });

    test('删附点音符 → 等值休止（3/8）占原拍位，小节仍满拍', () {
      final MusicScore base = _score(
        tracks: <MusicTrack>[
          MusicTrack(
            id: 'melody',
            name: '主旋律',
            instrument: 'piano',
            clef: 'treble',
            measures: <MusicMeasure>[
              MusicMeasure(
                id: 'm1',
                events: <MusicEvent>[
                  MusicEvent(
                    id: 'dq',
                    isRest: false,
                    durNum: 1,
                    durDen: 4,
                    dot: 1,
                    step: 'E',
                    octave: 5,
                  ),
                  _rest('r5', num: 5, den: 8),
                ],
              ),
            ],
          ),
        ],
      );
      expect(
        _durationValue(base.tracks.single.measures.single),
        closeTo(1.0, 1e-9),
      );
      final MusicScore edited = deleteNoteAt(
        base,
        trackIndex: 0,
        measureIndex: 0,
        eventId: 'dq',
      );
      final MusicMeasure measure = edited.tracks.single.measures.single;
      expect(measure.events, hasLength(2));
      expect(measure.events.first.isRest, isTrue);
      expect(measure.events.first.durationValue, closeTo(0.375, 1e-9));
      expect(measure.events.last.id, 'r5', reason: '未动的休止 id 保留');
      expect(_eventIds(edited).contains('dq'), isFalse);
      expect(_durationValue(measure), closeTo(1.0, 1e-9));
      _expectAccepted(edited);
    });

    test('删休止事件 → 等长休止占原槽位，前后音符不动', () {
      final MusicScore base = _score(
        tracks: <MusicTrack>[
          MusicTrack(
            id: 'melody',
            name: '主旋律',
            instrument: 'piano',
            clef: 'treble',
            measures: <MusicMeasure>[
              MusicMeasure(
                id: 'm1',
                events: <MusicEvent>[
                  MusicEvent(
                    id: 'h1',
                    isRest: false,
                    durNum: 1,
                    durDen: 2,
                    step: 'C',
                    octave: 5,
                  ),
                  _rest('r1', num: 1, den: 2),
                ],
              ),
            ],
          ),
        ],
      );
      final MusicScore edited = deleteNoteAt(
        base,
        trackIndex: 0,
        measureIndex: 0,
        eventId: 'r1',
      );
      final MusicMeasure measure = edited.tracks.single.measures.single;
      expect(measure.events, hasLength(2));
      expect(measure.events.first.id, 'h1');
      expect(measure.events.first.isRest, isFalse);
      expect(measure.events.last.isRest, isTrue);
      expect(measure.events.last.durationValue, closeTo(0.5, 1e-9));
      expect(_durationValue(measure), closeTo(1.0, 1e-9));
      _expectAccepted(edited);
    });

    test('删被关系对象引用的音符 → invalid_result 显性失败（不静默丢关系）', () {
      final MusicScore base = MusicScore(
        title: 'tie',
        tempo: 96,
        timeSig: const <int>[4, 4],
        keySig: 'C',
        relations: <MusicRelation>[
          MusicRelation(
            type: 'tie',
            id: 't1',
            data: <String, Object?>{'from': 'a', 'to': 'b'},
          ),
        ],
        tracks: <MusicTrack>[
          MusicTrack(
            id: 'melody',
            name: '主旋律',
            instrument: 'piano',
            clef: 'treble',
            measures: <MusicMeasure>[
              MusicMeasure(
                id: 'm1',
                events: <MusicEvent>[
                  MusicEvent(
                    id: 'a',
                    isRest: false,
                    durNum: 1,
                    durDen: 2,
                    step: 'C',
                    octave: 5,
                  ),
                  MusicEvent(
                    id: 'b',
                    isRest: false,
                    durNum: 1,
                    durDen: 2,
                    step: 'C',
                    octave: 5,
                  ),
                ],
              ),
            ],
          ),
        ],
      );
      expect(
        () => deleteNoteAt(base, trackIndex: 0, measureIndex: 0, eventId: 'a'),
        _failure('invalid_result'),
      );
    });

    test('确定性：同一输入两次删除相同 JSON；输入乐谱不被就地修改', () {
      final MusicScore base = _score(measures: 1, full: true);
      final MusicScore first = deleteNoteAt(
        base,
        trackIndex: 0,
        measureIndex: 0,
        eventId: 'n1b',
      );
      final MusicScore second = deleteNoteAt(
        base,
        trackIndex: 0,
        measureIndex: 0,
        eventId: 'n1b',
      );
      expect(jsonEncode(first.toJson()), jsonEncode(second.toJson()));
      expect(_eventIds(first).length, _eventCount(first));
      expect(
        base.tracks.single.measures.single.events,
        hasLength(4),
        reason: '纯函数：输入不被就地修改',
      );
      _expectAccepted(first);
    });

    test('删中间小节音符：其它小节原样保留', () {
      final MusicScore base = _score(measures: 3, full: true);
      final MusicScore edited = deleteNoteAt(
        base,
        trackIndex: 0,
        measureIndex: 1,
        eventId: 'n2a',
      );
      final List<MusicMeasure> measures = edited.tracks.single.measures;
      expect(measures, hasLength(3));
      expect(measures.map((MusicMeasure m) => m.id), <String>[
        'm1',
        'm2',
        'm3',
      ]);
      expect(measures[0].events, hasLength(4));
      expect(measures[2].events, hasLength(4));
      expect(measures[1].events, hasLength(4));
      expect(measures[1].events.first.isRest, isTrue);
      expect(_durationValue(measures[1]), closeTo(1.0, 1e-9));
      _expectAccepted(edited);
    });
  });
}
