/// 五线谱确定性排版纯函数测试（task-11）。
///
/// 覆盖任务要求：1/2 轨道分行、空谱/空轨道/空小节安全、不同小节数/宽度换行、
/// 音符时值→宽度映射（正例 + 坏数据夹紧反例）、音高/谱号→符头 y、连音线占位、
/// 确定性（`==` 与 toJson 字节相同）。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nondesign/core/music/music_score.dart';
import 'package:nondesign/widgets/music_staff_view.dart';

// ---------------------------------------------------------------------------
// 测试夹具
// ---------------------------------------------------------------------------

MusicEvent _event(
  String id, {
  int num = 1,
  int den = 4,
  String step = 'C',
  int octave = 4,
  int alter = 0,
  bool rest = false,
  int dot = 0,
  int tupletN = 0,
  int tupletIn = 0,
  Map<String, Object?> extra = const <String, Object?>{},
}) => MusicEvent(
  id: id,
  isRest: rest,
  durNum: num,
  durDen: den,
  step: rest ? '' : step,
  alter: rest ? 0 : alter,
  octave: rest ? 4 : octave,
  dot: dot,
  tupletN: tupletN,
  tupletIn: tupletIn,
  extra: extra,
);

/// 默认一小节 = 四个四分音符（C4/D4/E4/F4，满 4/4）。
MusicMeasure _fullMeasure(int index, {String prefix = ''}) => MusicMeasure(
  id: '${prefix}m${index + 1}',
  events: <MusicEvent>[
    _event('${prefix}n${index}a', step: 'C', octave: 4),
    _event('${prefix}n${index}b', step: 'D', octave: 4),
    _event('${prefix}n${index}c', step: 'E', octave: 4),
    _event('${prefix}n${index}d', step: 'F', octave: 4),
  ],
);

MusicTrack _track({
  String id = 'track_0',
  String name = '主旋律',
  String instrument = 'piano',
  String clef = 'treble',
  int measures = 4,
  List<MusicMeasure>? measureList,
  List<MusicEvent> Function(int measureIndex)? eventsOfMeasure,
}) => MusicTrack(
  id: id,
  name: name,
  instrument: instrument,
  clef: clef,
  measures:
      measureList ??
      <MusicMeasure>[
        for (int i = 0; i < measures; i++)
          eventsOfMeasure == null
              ? _fullMeasure(i, prefix: '${id}_')
              : MusicMeasure(id: '${id}_m${i + 1}', events: eventsOfMeasure(i)),
      ],
);

MusicScore _score({
  int tracks = 1,
  int measures = 4,
  List<int> timeSig = const <int>[4, 4],
  String keySig = 'C',
  String clef = 'treble',
  String instrument = 'piano',
  List<MusicTrack>? trackList,
  List<MusicRelation> relations = const <MusicRelation>[],
}) => MusicScore(
  title: '排版测试',
  tempo: 96,
  timeSig: timeSig,
  keySig: keySig,
  tracks:
      trackList ??
      <MusicTrack>[
        for (int i = 0; i < tracks; i++)
          _track(
            id: 'track_$i',
            name: i == 0 ? '主旋律' : '低音',
            instrument: i == 0 ? instrument : 'bass',
            clef: clef,
            measures: measures,
          ),
      ],
  relations: relations,
);

List<int> _measureIndexes(MusicStaffRow row) => <int>[
  for (final MusicStaffColumn column in row.columns) column.measureIndex,
];

void main() {
  group('空谱与空轨道安全', () {
    test('没有轨道：空布局可序列化、可比较、不抛异常', () {
      final MusicScore empty = const MusicScore(
        title: '空谱',
        tempo: 90,
        timeSig: <int>[4, 4],
        keySig: 'C',
        tracks: <MusicTrack>[],
      );
      final MusicStaffLayout layout = musicStaffLayout(empty, width: 800);
      expect(layout.rows, isEmpty);
      expect(layout.ties, isEmpty);
      expect(layout.width, 800);
      expect(
        layout.height,
        kMusicStaffTopPadding + kMusicStaffBottomPadding,
        reason: '没有行时仍保留上下留白，几何不退化为 0',
      );
      expect(layout.maxMeasuresPerRow, greaterThanOrEqualTo(1));
      expect(layout.toJsonString(), isNotEmpty);
      expect(jsonEncode(layout.toJson()), layout.toJsonString());
      expect(musicStaffLayout(empty, width: 800), layout);
    });

    test('空轨道 / 空小节：无小节的行不出现，空小节列不产生音符', () {
      final MusicScore score = _score(
        trackList: <MusicTrack>[
          _track(
            id: 'empty_track',
            name: '没写小节',
            measureList: const <MusicMeasure>[],
          ),
          _track(
            id: 'empty_measures',
            name: '空小节轨',
            measureList: <MusicMeasure>[
              const MusicMeasure(id: 'm1', events: <MusicEvent>[]),
              const MusicMeasure(id: 'm2', events: <MusicEvent>[]),
            ],
          ),
        ],
      );
      final MusicStaffLayout layout = musicStaffLayout(score, width: 800);
      expect(layout.rows, hasLength(1), reason: '没有小节的轨道不画空行');
      expect(layout.rows.single.trackId, 'empty_measures');
      expect(layout.rows.single.columns, hasLength(2));
      expect(
        layout.rows.single.columns.every(
          (MusicStaffColumn column) => column.notes.isEmpty,
        ),
        isTrue,
        reason: '空小节 = 整小节休止，几何里不应伪造音符',
      );
      expect(layout.ties, isEmpty);
      expect(layout.toJsonString(), isNotEmpty);
    });

    test('非法轨道索引与极端宽度：空安全退化，不抛异常', () {
      final MusicScore score = _score(tracks: 2, measures: 2);
      for (final int outOfRange in <int>[-1, 2, 99]) {
        final MusicStaffLayout layout = musicStaffLayout(
          score,
          width: 800,
          trackIndex: outOfRange,
        );
        expect(layout.rows, isEmpty, reason: 'trackIndex=$outOfRange 越界返回空布局');
        expect(layout.trackIndex, outOfRange);
      }
      expect(() => musicStaffLayout(score, width: 100), returnsNormally);
      expect(() => musicStaffLayout(score, width: -50), returnsNormally);
      expect(() => musicStaffLayout(score, width: double.nan), returnsNormally);
      expect(
        () => musicStaffLayout(score, width: double.infinity),
        returnsNormally,
      );
      expect(musicStaffLayout(score, width: 100).width, kMusicStaffMinWidth);
      expect(musicStaffLayout(score, width: -50).width, kMusicStaffMinWidth);
      expect(
        musicStaffLayout(score, width: double.nan).width,
        kMusicStaffMinWidth,
      );
      expect(
        musicStaffLayout(score, width: double.infinity).width,
        kMusicStaffMinWidth,
      );
    });
  });

  group('按轨分行与宽度自适应', () {
    test('单轨道：不同宽度换行，小节按顺序完整覆盖', () {
      final MusicScore score = _score(tracks: 1, measures: 8);

      final MusicStaffLayout narrow = musicStaffLayout(score, width: 400);
      expect(narrow.width, 400);
      expect(narrow.maxMeasuresPerRow, 3, reason: '400 宽：行内容量 3');
      expect(narrow.rows, hasLength(3), reason: '8 小节按 3/3/2 换行');
      expect(
        <int>[for (final MusicStaffRow row in narrow.rows) row.columns.length],
        <int>[3, 3, 2],
      );
      expect(
        <int>[
          for (final MusicStaffRow row in narrow.rows) ..._measureIndexes(row),
        ],
        <int>[0, 1, 2, 3, 4, 5, 6, 7],
        reason: '换行只重排，不丢小节、不重复',
      );

      final MusicStaffLayout wide = musicStaffLayout(score, width: 1400);
      expect(wide.maxMeasuresPerRow, kMusicStaffMaxMeasuresPerRow);
      expect(wide.rows, hasLength(1), reason: '1400 宽：8 小节一行放得下');
      expect(wide.rows.single.columns, hasLength(8));

      // 行几何自洽：行高/五线/行间距来自唯一常量。
      for (final MusicStaffRow row in narrow.rows) {
        expect(row.height, kMusicStaffRowHeight);
        expect(
          row.staffBottom - row.staffTop,
          4 * kMusicStaffLineSpacing,
          reason: '五线 4 个间距',
        );
        expect(row.lineSpacing, kMusicStaffLineSpacing);
        expect(
          row.top,
          kMusicStaffTopPadding + row.index * kMusicStaffRowHeight,
        );
        expect(row.columns.every((MusicStaffColumn c) => c.width > 0), isTrue);
      }
      expect(
        narrow.height,
        kMusicStaffTopPadding +
            3 * kMusicStaffRowHeight +
            kMusicStaffBottomPadding,
      );
    });

    test('2 轨道：按轨分行；trackIndex 只排指定轨道', () {
      final MusicScore score = _score(tracks: 2, measures: 3);
      final MusicStaffLayout layout = musicStaffLayout(score, width: 800);
      expect(layout.rows, hasLength(2), reason: '每条轨道各占一行');
      expect(layout.rows[0].trackIndex, 0);
      expect(layout.rows[1].trackIndex, 1);
      expect(layout.rows[0].trackName, '主旋律');
      expect(layout.rows[1].trackName, '低音');
      expect(_measureIndexes(layout.rows[0]), <int>[0, 1, 2]);
      expect(_measureIndexes(layout.rows[1]), <int>[0, 1, 2]);

      final MusicStaffLayout filtered = musicStaffLayout(
        score,
        width: 800,
        trackIndex: 1,
      );
      expect(filtered.rows, hasLength(1));
      expect(filtered.rows.single.trackIndex, 1);
      expect(_measureIndexes(filtered.rows.single), <int>[0, 1, 2]);
      expect(filtered.trackIndex, 1);
      expect(filtered.height, lessThan(layout.height));
    });

    test('不同小节数的轨道各自换行，互不影响', () {
      final MusicScore score = _score(
        trackList: <MusicTrack>[
          _track(id: 'short', measures: 2),
          _track(id: 'long', name: '长轨', instrument: 'bass', measures: 9),
        ],
      );
      final MusicStaffLayout layout = musicStaffLayout(score, width: 400);
      expect(layout.rows.first.columns, hasLength(2));
      expect(layout.rows.first.trackIndex, 0);
      expect(
        layout.rows.where((MusicStaffRow row) => row.trackIndex == 1).length,
        3,
        reason: '9 小节在 400 宽下按 3/3/3 换行',
      );
      expect(
        <int>[
          for (final MusicStaffRow row in layout.rows)
            if (row.trackIndex == 1) ..._measureIndexes(row),
        ],
        <int>[0, 1, 2, 3, 4, 5, 6, 7, 8],
      );
    });
  });

  group('时值与位置映射', () {
    test('音符时值→宽度：二分是四分的两倍，位置按拍偏移累进', () {
      final MusicScore score = _score(
        trackList: <MusicTrack>[
          _track(
            measureList: <MusicMeasure>[
              MusicMeasure(
                id: 'm1',
                events: <MusicEvent>[
                  _event('q', num: 1, den: 4, step: 'C', octave: 5),
                  _event('h', num: 1, den: 2, step: 'D', octave: 5),
                  _event('r', num: 1, den: 4, rest: true),
                ],
              ),
            ],
          ),
        ],
      );
      final MusicStaffLayout layout = musicStaffLayout(score, width: 800);
      final MusicStaffColumn column = layout.rows.single.columns.single;
      // 800 宽单小节：列宽夹到 240，列内可用 228（语义与几何常量联动）。
      expect(column.width, kMusicStaffMeasureMaxWidth);
      expect(
        column.contentWidth,
        kMusicStaffMeasureMaxWidth - 2 * kMusicStaffMeasurePaddingX,
      );
      final List<MusicStaffNote> notes = column.notes;
      expect(notes, hasLength(3));
      final double quarterWidth = notes[0].width;
      final double halfWidth = notes[1].width;
      expect(quarterWidth, closeTo(0.25 * column.contentWidth, 1e-9));
      expect(halfWidth, closeTo(0.5 * column.contentWidth, 1e-9));
      expect(halfWidth, closeTo(quarterWidth * 2, 1e-9));
      expect(notes[2].width, closeTo(quarterWidth, 1e-9), reason: '休止占同样拍宽');
      expect(notes[0].x, closeTo(column.contentLeft, 1e-9));
      expect(notes[1].x, closeTo(column.contentLeft + quarterWidth, 1e-9));
      expect(
        notes[2].x,
        closeTo(column.contentLeft + quarterWidth + halfWidth, 1e-9),
      );
    });

    test('附点：附点四分宽度是四分 1.5 倍；三分/八分音符按实际时值映射', () {
      final MusicScore score = _score(
        trackList: <MusicTrack>[
          _track(
            measureList: <MusicMeasure>[
              MusicMeasure(
                id: 'm1',
                events: <MusicEvent>[
                  _event('dq', num: 1, den: 4, dot: 1, step: 'C', octave: 5),
                  _event('q', num: 1, den: 4, step: 'D', octave: 5),
                  _event('dq2', num: 1, den: 4, dot: 1, step: 'E', octave: 5),
                ],
              ),
            ],
          ),
        ],
      );
      final MusicStaffLayout layout = musicStaffLayout(score, width: 800);
      final List<MusicStaffNote> notes =
          layout.rows.single.columns.single.notes;
      expect(notes[0].durationValue, closeTo(0.375, 1e-9));
      expect(notes[1].durationValue, closeTo(0.25, 1e-9));
      expect(notes[0].width, closeTo(notes[1].width * 1.5, 1e-9));
      expect(notes[2].width, closeTo(notes[0].width, 1e-9));
    });

    test('三连音落宽度：三个三连八分 = 一个四分，各占八分宽的 2/3', () {
      final MusicScore score = _score(
        trackList: <MusicTrack>[
          _track(
            measureList: <MusicMeasure>[
              MusicMeasure(
                id: 'm1',
                events: <MusicEvent>[
                  _event(
                    't1',
                    num: 1,
                    den: 8,
                    step: 'C',
                    octave: 5,
                    tupletN: 3,
                    tupletIn: 2,
                  ),
                  _event(
                    't2',
                    num: 1,
                    den: 8,
                    step: 'D',
                    octave: 5,
                    tupletN: 3,
                    tupletIn: 2,
                  ),
                  _event(
                    't3',
                    num: 1,
                    den: 8,
                    step: 'E',
                    octave: 5,
                    tupletN: 3,
                    tupletIn: 2,
                  ),
                  for (int i = 0; i < 6; i++)
                    _event('r$i', num: 1, den: 8, rest: true),
                ],
              ),
            ],
          ),
        ],
      );
      final MusicStaffLayout layout = musicStaffLayout(score, width: 800);
      final List<MusicStaffNote> notes =
          layout.rows.single.columns.single.notes;
      expect(notes, hasLength(9));
      expect(notes[0].durationValue, closeTo(1 / 12, 1e-9));
      expect(notes[1].x, closeTo(notes[0].x + notes[0].width, 1e-9));
      expect(notes[2].x, closeTo(notes[1].x + notes[1].width, 1e-9));
      final MusicStaffNote eighthRest = notes[3];
      expect(eighthRest.durationValue, closeTo(1 / 8, 1e-9));
      expect(notes[0].width, closeTo(eighthRest.width * (2 / 3), 1e-9));
    });

    test('坏数据反例：小节超容量时后一个音符夹在列内，不画到列外', () {
      final MusicScore score = _score(
        trackList: <MusicTrack>[
          _track(
            measureList: <MusicMeasure>[
              MusicMeasure(
                id: 'm1',
                events: <MusicEvent>[
                  _event('whole', num: 1, den: 1, step: 'C', octave: 5),
                  _event('over', num: 1, den: 4, step: 'D', octave: 5),
                ],
              ),
            ],
          ),
        ],
      );
      final MusicStaffLayout layout = musicStaffLayout(score, width: 800);
      final MusicStaffColumn column = layout.rows.single.columns.single;
      final MusicStaffNote over = column.notes[1];
      expect(over.x, greaterThanOrEqualTo(column.contentLeft));
      expect(
        over.x + over.width,
        lessThanOrEqualTo(column.contentLeft + column.contentWidth + 1e-9),
      );
      expect(over.width, greaterThanOrEqualTo(1.5));
      expect(
        column.notes.every(
          (MusicStaffNote note) => note.width.isFinite && note.width > 0,
        ),
        isTrue,
      );
    });
  });

  group('音高、谱号与连音线', () {
    test('高音谱号：C4 在下方加线、C5 高出 7 个半间距', () {
      final MusicScore score = _score(
        trackList: <MusicTrack>[
          _track(
            measureList: <MusicMeasure>[
              MusicMeasure(
                id: 'm1',
                events: <MusicEvent>[
                  _event('c4', num: 1, den: 2, step: 'C', octave: 4),
                  _event('c5', num: 1, den: 2, step: 'C', octave: 5),
                ],
              ),
            ],
          ),
        ],
      );
      final MusicStaffLayout layout = musicStaffLayout(score, width: 800);
      final MusicStaffRow row = layout.rows.single;
      final List<MusicStaffNote> notes = row.columns.single.notes;
      expect(row.clef, 'treble');
      expect(notes[0].staffStep, -2, reason: 'C4 比底线 E4 低两个半间距');
      expect(notes[1].staffStep, 5);
      expect(
        notes[0].headY,
        closeTo(row.staffBottom + kMusicStaffLineSpacing, 1e-9),
        reason: 'C4 符头在底线下方一条加线',
      );
      expect(
        notes[0].headY - notes[1].headY,
        closeTo(7 * kMusicStaffLineSpacing / 2, 1e-9),
        reason: 'C4→C5 是一个八度 = 7 个半间距',
      );
      expect(notes[0].stemUp, isTrue);
      expect(notes[1].stemUp, isFalse);
    });

    test('低音谱号：C4 在五线上方一条加线', () {
      final MusicScore score = _score(
        trackList: <MusicTrack>[
          _track(
            clef: 'bass',
            instrument: 'bass',
            measureList: <MusicMeasure>[
              MusicMeasure(
                id: 'm1',
                events: <MusicEvent>[
                  _event('c4', num: 1, den: 1, step: 'C', octave: 4),
                ],
              ),
            ],
          ),
        ],
      );
      final MusicStaffLayout layout = musicStaffLayout(score, width: 800);
      final MusicStaffRow row = layout.rows.single;
      final MusicStaffNote note = row.columns.single.notes.single;
      expect(row.clef, 'bass');
      expect(note.staffStep, 10, reason: 'C4 比低音谱号底线 G2 高 10 个半间距');
      expect(
        note.headY,
        closeTo(row.staffTop - kMusicStaffLineSpacing, 1e-9),
        reason: 'C4 在低音谱表上方一条加线',
      );
    });

    test('打击谱号：鼓轨按鼓件名映射，kick/snare/crash 依次升高', () {
      final MusicScore score = _score(
        trackList: <MusicTrack>[
          _track(
            id: 'drums',
            name: '鼓组',
            instrument: 'drums',
            clef: 'treble', // 鼓轨不看 clef 字段，固定打击谱号
            measureList: <MusicMeasure>[
              MusicMeasure(
                id: 'm1',
                events: <MusicEvent>[
                  _event('k', extra: <String, Object?>{'drum': 'kick'}),
                  _event('s', extra: <String, Object?>{'drum': 'snare'}),
                  _event('c', extra: <String, Object?>{'drum': 'crash'}),
                ],
              ),
            ],
          ),
        ],
      );
      final MusicStaffLayout layout = musicStaffLayout(score, width: 800);
      final MusicStaffRow row = layout.rows.single;
      expect(row.clef, 'percussion');
      final List<MusicStaffNote> notes = row.columns.single.notes;
      expect(notes, hasLength(3));
      expect(notes[0].staffStep, musicStaffDrumStep('kick'));
      expect(notes[1].staffStep, musicStaffDrumStep('snare'));
      expect(notes[2].staffStep, musicStaffDrumStep('crash'));
      expect(notes[0].staffStep, lessThan(notes[1].staffStep));
      expect(notes[1].staffStep, lessThan(notes[2].staffStep));
      for (int i = 0; i < notes.length; i++) {
        final double expectedY =
            row.staffBottom - notes[i].staffStep * (row.lineSpacing / 2);
        expect(notes[i].headY, closeTo(expectedY, 1e-9));
      }
    });

    test('连音线占位：同行的 tie 可见、跨行的保留占位不伪造', () {
      final List<MusicMeasure> measures = <MusicMeasure>[
        for (int i = 0; i < 8; i++)
          MusicMeasure(
            id: 'm${i + 1}',
            events: <MusicEvent>[
              _event('n${i}a', num: 1, den: 2, step: 'C', octave: 5),
              _event('n${i}b', num: 1, den: 2, step: 'D', octave: 5),
            ],
          ),
      ];
      final MusicScore score = MusicScore(
        title: '连音线测试',
        tempo: 96,
        timeSig: const <int>[4, 4],
        keySig: 'C',
        tracks: <MusicTrack>[
          MusicTrack(
            id: 'track_0',
            name: '主旋律',
            instrument: 'piano',
            measures: measures,
          ),
        ],
        relations: const <MusicRelation>[
          MusicRelation(
            type: 'tie',
            id: 'tie_same_row',
            data: <String, Object?>{'from': 'n0a', 'to': 'n1a'},
          ),
          MusicRelation(
            type: 'tie',
            id: 'tie_cross_row',
            data: <String, Object?>{'from': 'n0b', 'to': 'n4a'},
          ),
          MusicRelation(
            type: 'tie',
            id: 'tie_missing_endpoint',
            data: <String, Object?>{'from': 'n0a', 'to': 'ghost'},
          ),
        ],
      );
      // 400 宽 → 行容量 3：measure 0/1 同在第 0 行，measure 4 在第 1 行。
      final MusicStaffLayout layout = musicStaffLayout(score, width: 400);
      expect(layout.rows[0].columns.first.measureIndex, 0);
      expect(layout.rows[1].columns.first.measureIndex, 3);
      expect(layout.ties, hasLength(2), reason: '端点缺失的占位被跳过');
      final MusicStaffTie sameRow = layout.ties[0];
      expect(sameRow.fromEventId, 'n0a');
      expect(sameRow.toEventId, 'n1a');
      expect(sameRow.visible, isTrue);
      expect(sameRow.rowIndex, 0);
      expect(sameRow.fromX, greaterThan(0));
      expect(sameRow.toX, greaterThan(sameRow.fromX));
      final MusicStaffTie crossRow = layout.ties[1];
      expect(crossRow.visible, isFalse, reason: '跨行只留占位，不在错行画弧');
      expect(crossRow.rowIndex, 0);
      expect(crossRow.fromEventId, 'n0b');
    });
  });

  group('确定性', () {
    test('同输入两次布局相等：== 与 toJson 字节都相同', () {
      final MusicScore score = _score(tracks: 2, measures: 5);
      final MusicStaffLayout first = musicStaffLayout(score, width: 900);
      final MusicStaffLayout second = musicStaffLayout(score, width: 900);
      expect(first, second);
      expect(first.toJsonString(), second.toJsonString());
      expect(jsonEncode(first.toJson()), first.toJsonString());
      expect(first.hashCode, second.hashCode);

      // 重建等价（值相同的）乐谱对象，布局也必须相同（不依赖对象身份）。
      final MusicStaffLayout rebuilt = musicStaffLayout(
        _score(tracks: 2, measures: 5),
        width: 900,
      );
      expect(rebuilt, first);

      // 过滤轨道同样确定。
      final MusicStaffLayout filteredA = musicStaffLayout(
        score,
        width: 900,
        trackIndex: 0,
      );
      final MusicStaffLayout filteredB = musicStaffLayout(
        score,
        width: 900,
        trackIndex: 0,
      );
      expect(filteredA, filteredB);
    });

    test('不同宽度/轨道参数得到不同布局（不是把参数吞掉的假确定性）', () {
      final MusicScore score = _score(tracks: 2, measures: 5);
      final MusicStaffLayout wide = musicStaffLayout(score, width: 900);
      final MusicStaffLayout narrow = musicStaffLayout(score, width: 500);
      expect(wide, isNot(narrow));
      expect(wide.rows, hasLength(2), reason: '900 宽：每条轨道 5 小节一行');
      expect(
        narrow.rows,
        hasLength(4),
        reason: '500 宽：行容量 4，每条轨道按 4/1 换行，共 4 行',
      );
      final MusicStaffLayout filtered = musicStaffLayout(
        score,
        width: 900,
        trackIndex: 0,
      );
      expect(filtered, isNot(wide));
      expect(filtered.rows, hasLength(1));
    });
  });
}

// ---------------------------------------------------------------------------
// 备注：几何常量本身就是契约的一部分，测试直接用 kMusicStaff* 常量断言，
// 这样调排版常量时测试会一起暴露，不会出现「常量改了但测试还绿」的假象。
// ---------------------------------------------------------------------------
