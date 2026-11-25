/// 五线谱命中测试纯函数测试（task-14）。
///
/// 覆盖任务要求：不同行/间 → 音高、谱号差异（高音/低音/打击）、小节/行/轨道定位、
/// 越界与空白安全返回 null、缩放换算（zoom）、命中已有音符与确定性。
///
/// 几何断言直接读 [musicStaffLayout] 的产出（而不是另算一套魔法数），这样排版常量
/// 调整时测试会一起暴露。
library;

import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nondesign/core/music/music_score.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/widgets/music_staff_view.dart';

Widget _app(Widget child) => MaterialApp(
  theme: AppTheme.build(dark: true),
  home: Scaffold(
    body: Align(alignment: Alignment.topLeft, child: child),
  ),
);

// ---------------------------------------------------------------------------
// 测试夹具（一小节 = 四个四分音符，满 4/4）
// ---------------------------------------------------------------------------

MusicEvent _event(
  String id, {
  int num = 1,
  int den = 4,
  String step = 'C',
  int octave = 4,
  int alter = 0,
  bool rest = false,
}) => MusicEvent(
  id: id,
  isRest: rest,
  durNum: num,
  durDen: den,
  step: rest ? '' : step,
  alter: rest ? 0 : alter,
  octave: rest ? 4 : octave,
);

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
  int measures = 1,
  List<MusicMeasure>? measureList,
}) => MusicTrack(
  id: id,
  name: name,
  instrument: instrument,
  clef: clef,
  measures:
      measureList ??
      <MusicMeasure>[
        for (int i = 0; i < measures; i++) _fullMeasure(i, prefix: '${id}_'),
      ],
);

MusicScore _score({
  int tracks = 1,
  int measures = 1,
  List<MusicTrack>? trackList,
}) => MusicScore(
  title: '命中测试',
  tempo: 96,
  timeSig: const <int>[4, 4],
  keySig: 'C',
  tracks:
      trackList ??
      <MusicTrack>[
        for (int i = 0; i < tracks; i++)
          _track(
            id: 'track_$i',
            name: i == 0 ? '主旋律' : '低音',
            instrument: i == 0 ? 'piano' : 'bass',
            clef: i == 0 ? 'treble' : 'bass',
            measures: measures,
          ),
      ],
);

/// 800 宽下的单行五线几何：row0 top=8，staffTop=38，staffBottom=70，线距 8。
MusicStaffLayout _layoutSingleRow({double width = 800}) {
  final MusicStaffLayout layout = musicStaffLayout(
    _score(tracks: 1, measures: 5),
    width: width,
  );
  return layout;
}

void main() {
  group('高音谱号：行/间 → 音高', () {
    test('底线到顶线逐线/逐间命中；加线范围也能命中', () {
      final MusicStaffLayout layout = _layoutSingleRow();
      final MusicStaffRow row = layout.rows.single;
      expect(row.clef, 'treble');
      expect(row.staffTop, 38);
      expect(row.staffBottom, 70);

      // (dy, 期望音高)：五线底线 E4 起，半间距 4px。
      const List<(double, String, int)> expected = <(double, String, int)>[
        (70.0, 'E', 4), // step 0 底线
        (66.0, 'F', 4), // step 1 间
        (62.0, 'G', 4),
        (58.0, 'A', 4),
        (54.0, 'B', 4),
        (50.0, 'C', 5), // step 5 第三间（高音谱 C5）
        (46.0, 'D', 5),
        (42.0, 'E', 5),
        (38.0, 'F', 5), // step 8 顶线
        (30.0, 'A', 5), // step 10 上加线
        (26.0, 'B', 5),
      ];
      for (final (double dy, String step, int octave) in expected) {
        final MusicStaffHit? hit = staffHitTest(layout, Offset(100, dy));
        expect(hit, isNotNull, reason: 'dy=$dy 应命中五线内位置');
        expect(hit!.trackIndex, 0);
        expect(hit.measureIndex, 0);
        expect(hit.step, step, reason: 'dy=$dy 的音名');
        expect(hit.octave, octave, reason: 'dy=$dy 的八度');
        expect(hit.alter, 0, reason: '命中默认自然音，不应用调号');
        expect(hit.clef, 'treble');
        expect(hit.staffStep, ((70 - dy) / 4).round());
      }

      // 五线下方加线：C4 在底线下方一条加线（step -2）。
      final MusicStaffHit? below = staffHitTest(layout, const Offset(100, 78));
      expect(below?.step, 'C');
      expect(below?.octave, 4);
      expect(below?.staffStep, -2);
    });

    test('距离命中点最近的线/间被吸附：偏移 2px 仍取上一个半间距', () {
      final MusicStaffLayout layout = _layoutSingleRow();
      // 70 是 E4；68 距离 70/66 都是 2px，round(0.5) 向上 → step1 = F4。
      expect(staffHitTest(layout, const Offset(100, 68))?.step, 'F');
      // 67 更靠近 66（step1）→ F4；69 更靠近 70（step0）→ E4。
      expect(staffHitTest(layout, const Offset(100, 67))?.step, 'F');
      expect(staffHitTest(layout, const Offset(100, 69))?.step, 'E');
    });
  });

  group('谱号差异：低音谱号与打击谱号', () {
    test('低音谱号：底线 G2，C4 在上方一条加线', () {
      final MusicScore score = _score(
        trackList: <MusicTrack>[
          _track(
            id: 'bass',
            name: '低音',
            instrument: 'bass',
            clef: 'bass',
            measures: 2,
          ),
        ],
      );
      final MusicStaffLayout layout = musicStaffLayout(score, width: 800);
      final MusicStaffRow row = layout.rows.single;
      expect(row.clef, 'bass');
      expect(row.staffTop, 38);
      expect(row.staffBottom, 70);

      expect(staffHitTest(layout, const Offset(100, 70)), isNotNull);
      expect(staffHitTest(layout, const Offset(100, 70))?.step, 'G');
      expect(staffHitTest(layout, const Offset(100, 70))?.octave, 2);
      expect(staffHitTest(layout, const Offset(100, 58))?.step, 'C');
      expect(staffHitTest(layout, const Offset(100, 58))?.octave, 3);
      // C4 = step 10：低音谱号底线上方 10 个半间距（顶线 A3 再上一条加线）。
      final MusicStaffHit? c4 = staffHitTest(layout, const Offset(100, 30));
      expect(c4?.step, 'C');
      expect(c4?.octave, 4);
      expect(c4?.staffStep, 10);
    });

    test('打击谱号：按五线高度映射到最近鼓件，step/octave 只是占位', () {
      final MusicScore score = _score(
        trackList: <MusicTrack>[
          _track(
            id: 'drums',
            name: '鼓组',
            instrument: 'drums',
            clef: 'treble', // 鼓轨不看 clef 字段，固定打击谱号
            measures: 1,
          ),
        ],
      );
      final MusicStaffLayout layout = musicStaffLayout(score, width: 800);
      final MusicStaffRow row = layout.rows.single;
      expect(row.clef, 'percussion');

      // staffBottom=70：step0=kick，step2=tom，step4=snare，step6=openhat。
      for (final (double dy, String drum, int staffStep)
          in <(double, String, int)>[
            (70.0, 'kick', 0),
            (62.0, 'tom', 2),
            (54.0, 'snare', 4),
            (46.0, 'openhat', 6),
            (38.0, 'hihat', 8),
            (30.0, 'ride', 10),
            (22.0, 'crash', 12),
          ]) {
        final MusicStaffHit? hit = staffHitTest(layout, Offset(100, dy));
        expect(hit, isNotNull);
        expect(hit!.isPercussion, isTrue);
        expect(hit.drum, drum, reason: 'dy=$dy 的鼓件');
        expect(hit.staffStep, staffStep);
        expect(hit.step, 'C', reason: '打击谱号音高是占位');
        expect(hit.octave, 4);
        expect(hit.alter, 0);
      }

      // 逆映射的确定性：等距取更低鼓件；两端夹到边界鼓件。
      expect(musicStaffDrumForStep(0), 'kick');
      expect(musicStaffDrumForStep(2), 'tom');
      expect(musicStaffDrumForStep(3), 'tom', reason: 'step3 与 tom/snare 等距');
      expect(musicStaffDrumForStep(4), 'snare');
      expect(
        musicStaffDrumForStep(5),
        'snare',
        reason: 'step5 与 snare/openhat 等距',
      );
      expect(musicStaffDrumForStep(12), 'crash');
      expect(musicStaffDrumForStep(13), 'crash');
      expect(musicStaffDrumForStep(-1), 'kick');
    });

    test('音高逆映射：[musicStaffPitchForStep] 与正向映射互逆', () {
      for (final String clef in <String>['treble', 'bass']) {
        for (int step = -4; step <= 12; step++) {
          final ({String step, int octave}) pitch = musicStaffPitchForStep(
            step,
            clef,
          );
          final MusicEvent event = _event(
            'probe_$step',
            step: pitch.step,
            octave: pitch.octave,
          );
          expect(
            musicStaffStepForEvent(event, clef),
            step,
            reason: '$clef 谱号 step=$step 正逆映射应一致',
          );
        }
      }
    });
  });

  group('小节/行/轨道定位', () {
    test('400 宽 8 小节：行内定位到对应小节，跨行按行几何命中', () {
      final MusicStaffLayout layout = musicStaffLayout(
        _score(tracks: 1, measures: 8),
        width: 400,
      );
      expect(layout.rows, hasLength(3));
      expect(layout.rows[0].columns, hasLength(3));
      expect(layout.rows[1].columns.first.measureIndex, 3);
      expect(layout.rows[2].columns.first.measureIndex, 6);

      // 第 0 行：列 0/1/2 的 x 区间由布局给出，点在列内即可。
      final MusicStaffColumn c0 = layout.rows[0].columns[0];
      final MusicStaffColumn c1 = layout.rows[0].columns[1];
      final MusicStaffHit? m0 = staffHitTest(
        layout,
        Offset(c0.contentLeft + 1, 50),
      );
      expect(m0?.measureIndex, 0);
      expect(m0?.rowIndex, 0);
      final MusicStaffHit? m1 = staffHitTest(
        layout,
        Offset(c1.contentLeft + 1, 50),
      );
      expect(m1?.measureIndex, 1);

      // 第 1 行（row top=120，staffBottom=182）：dy=162 → C5（step 5）。
      final MusicStaffRow row1 = layout.rows[1];
      final MusicStaffColumn r1c1 = row1.columns[1];
      final MusicStaffHit? hit = staffHitTest(
        layout,
        Offset(r1c1.contentLeft + 1, 162),
      );
      expect(hit, isNotNull);
      expect(hit!.rowIndex, 1);
      expect(hit.trackIndex, 0);
      expect(hit.measureIndex, 4);
      expect(hit.step, 'C');
      expect(hit.octave, 5);
    });

    test('多轨道：点哪一行就回哪一条轨道（低音轨道按低音谱号换算）', () {
      final MusicScore score = _score(tracks: 2, measures: 1);
      final MusicStaffLayout layout = musicStaffLayout(score, width: 800);
      expect(layout.rows, hasLength(2));

      final MusicStaffHit? treble = staffHitTest(layout, const Offset(100, 50));
      expect(treble?.trackIndex, 0);
      expect(treble?.step, 'C');
      expect(treble?.octave, 5);

      // 第 2 行（row top=120）：staffTop=150、staffBottom=182。
      final MusicStaffHit? bass0 = staffHitTest(layout, const Offset(100, 182));
      expect(bass0?.trackIndex, 1);
      expect(bass0?.clef, 'bass');
      expect(bass0?.staffStep, 0);
      expect(bass0?.step, 'G');
      expect(bass0?.octave, 2);
      final MusicStaffHit? bass10 = staffHitTest(
        layout,
        const Offset(100, 142),
      );
      expect(bass10?.staffStep, 10);
      expect(bass10?.step, 'C');
      expect(bass10?.octave, 4);
    });
  });

  group('越界与空白安全', () {
    test('空布局/非法参数一律 null，不抛异常', () {
      final MusicScore empty = const MusicScore(
        title: '空谱',
        tempo: 90,
        timeSig: <int>[4, 4],
        keySig: 'C',
        tracks: <MusicTrack>[],
      );
      final MusicStaffLayout emptyLayout = musicStaffLayout(empty, width: 800);
      expect(emptyLayout.rows, isEmpty);
      expect(staffHitTest(emptyLayout, Offset.zero), isNull);
      expect(staffHitTest(emptyLayout, const Offset(100, 50)), isNull);

      final MusicStaffLayout layout = _layoutSingleRow();
      expect(
        staffHitTest(layout, Offset(double.nan, 50)),
        isNull,
        reason: '非有限 x',
      );
      expect(
        staffHitTest(layout, Offset(100, double.infinity)),
        isNull,
        reason: '非有限 y',
      );
      expect(staffHitTest(layout, const Offset(100, 50), zoom: 0), isNull);
      expect(staffHitTest(layout, const Offset(100, 50), zoom: -1), isNull);
      expect(
        staffHitTest(layout, const Offset(100, 50), zoom: double.nan),
        isNull,
      );
      expect(
        staffHitTest(layout, const Offset(100, 50), zoom: double.infinity),
        isNull,
      );
    });

    test('行外/行首谱号区/小节区外/离五线过远 → null', () {
      final MusicStaffLayout layout = _layoutSingleRow();
      final MusicStaffRow row = layout.rows.single;
      // 行上方/下方空白（layout.height 之外）。
      expect(staffHitTest(layout, Offset(100, row.top - 2)), isNull);
      expect(
        staffHitTest(layout, Offset(100, row.top + row.height + 2)),
        isNull,
      );
      // 行内但离五线太远（超过 kMusicStaffHitLineTolerance）：行内空白。
      expect(staffHitTest(layout, const Offset(100, 100)), isNull);
      expect(staffHitTest(layout, const Offset(100, 4)), isNull);
      // 行首谱号/调号/拍号区不是小节。
      expect(staffHitTest(layout, const Offset(20, 50)), isNull);
      expect(staffHitTest(layout, const Offset(0, 50)), isNull);
      // 小节区右侧空白（超出 systemWidth）。
      final double outside = row.contentLeft + row.systemWidth + 4;
      expect(staffHitTest(layout, Offset(outside, 50)), isNull);
      // 小节区左边界算命中（contentLeft 是第一个小节内容左沿）。
      expect(staffHitTest(layout, Offset(row.contentLeft, 50)), isNotNull);
      // 负坐标。
      expect(staffHitTest(layout, const Offset(-10, 50)), isNull);
    });
  });

  group('缩放换算（zoom）', () {
    test('local 坐标按 zoom 缩小回排版坐标；不同 zoom 命中不同位置', () {
      final MusicStaffLayout layout = _layoutSingleRow();
      // 排版坐标 (80, 50) = 第一小节 C5；200% 下同一排版点落在 local (160, 100)。
      final MusicStaffHit? zoomed = staffHitTest(
        layout,
        const Offset(160, 100),
        zoom: 2.0,
      );
      expect(zoomed, isNotNull);
      expect(zoomed!.measureIndex, 0);
      expect(zoomed.step, 'C');
      expect(zoomed.octave, 5);
      expect(zoomed.staffStep, 5);

      // 同样 local 在 100% 下变成 (160, 100)：y 离五线太远 → null。
      expect(staffHitTest(layout, const Offset(160, 100)), isNull);

      // 50%：排版 (80, 50) 落在 local (40, 25) → 仍是 C5。
      final MusicStaffHit? half = staffHitTest(
        layout,
        const Offset(40, 25),
        zoom: 0.5,
      );
      expect(half?.step, 'C');
      expect(half?.octave, 5);
      expect(half?.staffStep, 5);
      // 50% 下 local (160,200) → 排版 (320,400)：行外 → null。
      expect(staffHitTest(layout, const Offset(160, 200), zoom: 0.5), isNull);
    });
  });

  group('视图接线（onNoteTap）', () {
    testWidgets('给了 onNoteTap 才装点击热区；点击 local (80,50) 回调 C5 命中', (
      tester,
    ) async {
      MusicStaffHit? tapped;
      await tester.pumpWidget(
        _app(
          SizedBox(
            width: 800,
            height: 400,
            child: MusicStaffView(
              score: _score(tracks: 1, measures: 5),
              onNoteTap: (MusicStaffHit hit) => tapped = hit,
            ),
          ),
        ),
      );
      await tester.pump();
      final Finder hitTarget = find.byKey(const ValueKey('music-staff-hit'));
      expect(hitTarget, findsOneWidget);
      await tester.tapAt(tester.getTopLeft(hitTarget) + const Offset(80, 50));
      await tester.pump();
      expect(tapped, isNotNull);
      expect(tapped!.trackIndex, 0);
      expect(tapped!.measureIndex, 0);
      expect(tapped!.staffStep, 5);
      expect(tapped!.step, 'C');
      expect(tapped!.octave, 5);
      expect(tester.takeException(), isNull);
    });

    testWidgets('不传 onNoteTap 保持只读：不装点击热区，点击不产生回调', (tester) async {
      await tester.pumpWidget(
        _app(
          SizedBox(
            width: 800,
            height: 400,
            child: MusicStaffView(score: _score(tracks: 1, measures: 5)),
          ),
        ),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('music-staff-hit')),
        findsNothing,
        reason: 'null = 保持只读，不装手势',
      );
      // 直接点谱面空白位置也不会崩（没有手势目标）。
      await tester.tapAt(
        tester.getTopLeft(find.byType(MusicStaffView)) + const Offset(80, 60),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  group('命中已有音符与确定性', () {
    test('点击已有符头返回 eventIndex/eventId；点在空白处为 null 但仍给音高位置', () {
      final MusicScore score = _score(
        trackList: <MusicTrack>[
          _track(
            id: 'melody',
            measureList: <MusicMeasure>[
              MusicMeasure(
                id: 'm1',
                events: <MusicEvent>[
                  _event('n1', step: 'C', octave: 5),
                  _event('n2', step: 'D', octave: 5),
                  _event('n3', step: 'E', octave: 5),
                  _event('n4', step: 'F', octave: 5),
                ],
              ),
            ],
          ),
        ],
      );
      final MusicStaffLayout layout = musicStaffLayout(score, width: 800);
      final MusicStaffColumn column = layout.rows.single.columns.single;
      final MusicStaffNote first = column.notes[0];
      expect(first.headY, 50, reason: 'C5 = staffStep 5');
      final Offset headCenter = Offset(
        first.headX + kMusicStaffHeadWidth / 2,
        first.headY,
      );
      final MusicStaffHit? onHead = staffHitTest(layout, headCenter);
      expect(onHead, isNotNull);
      expect(onHead!.eventIndex, 0);
      expect(onHead.eventId, 'n1');
      expect(onHead.step, 'C');
      expect(onHead.octave, 5);

      // 同一行/小节但点在两个符头之间：不是已有音符，仍得到该处的音高。
      final MusicStaffHit? gap = staffHitTest(
        layout,
        Offset(first.x + 20, first.headY),
      );
      expect(gap, isNotNull);
      expect(gap!.eventIndex, isNull);
      expect(gap.eventId, isNull);
      expect(gap.measureIndex, 0);
      expect(gap.step, 'C');
    });

    test('同输入两次命中结果相等、JSON 字节相同；与音符内容无关的几何稳定', () {
      final MusicStaffLayout layout = _layoutSingleRow();
      final MusicStaffHit first = staffHitTest(
        layout,
        const Offset(150, 62.5),
        zoom: 1.25,
      )!;
      final MusicStaffHit second = staffHitTest(
        layout,
        const Offset(150, 62.5),
        zoom: 1.25,
      )!;
      expect(first, second);
      expect(first.hashCode, second.hashCode);
      expect(jsonEncode(first.toJson()), jsonEncode(second.toJson()));
      expect(first.toJson()['clef'], 'treble');
      expect(first.toJson()['step'], 'C');
      expect(first.toJson()['octave'], 5);
      expect(first.toJson()['drum'], '');
    });
  });
}
