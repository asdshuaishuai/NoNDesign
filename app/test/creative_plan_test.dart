import 'package:flutter_test/flutter_test.dart';
import 'package:nondesign/core/creative/creative.dart';

import 'helpers/creative_fixtures.dart';

Set<String> _codes(CreativeValidation validation) =>
    validation.issues.map((CreativeIssue issue) => issue.code).toSet();

void main() {
  group('creative.plan 3D', () {
    test('椅子计划：parts/parent/camera 全解析', () {
      final CreativeParseResult<CreativePlan> result = CreativePlan.parse(
        creativeFixture('plan_3d_chair.json'),
      );
      expect(result.ok, isTrue);
      final CreativePlan3d plan = result.value! as CreativePlan3d;
      expect(plan.track, CreativeTrack.staticObject);
      expect(plan.language, 'threejs');
      expect(plan.parts, hasLength(3));
      final CreativePlanPart seat = plan.parts.firstWhere(
        (CreativePlanPart part) => part.id == 'seat',
      );
      expect(seat.parent, 'frame');
      expect(seat.dimsM, equals(<double>[0.45, 0.04, 0.42]));
      expect(seat.bboxCenterM, equals(<double>[0, 0.45, 0]));
      expect(plan.cameras.single['id'], 'hero');
    });

    test('roundtrip：3D plan 保持不变', () {
      final CreativePlan plan = CreativePlan.parse(
        creativeFixture('plan_3d_chair.json'),
      ).value!;
      final CreativeParseResult<CreativePlan> reparsed = CreativePlan.parse(
        plan.toJson(),
      );
      expect(reparsed.ok, isTrue);
      expect(reparsed.value!.toJson(), equals(plan.toJson()));
    });

    test('坏计划：语言/重复 id/父级缺失/尺寸非法/验收为空/zone 引用', () {
      final CreativeParseResult<CreativePlan> result = CreativePlan.parse(
        creativeFixture('plan_3d_bad.json'),
      );
      expect(result.ok, isFalse);
      expect(
        _codes(result.validation),
        containsAll(<String>[
          'plan_language_track_mismatch',
          'plan_part_id_duplicate',
          'plan_part_parent_missing',
          'plan_part_dims_invalid',
          'plan_acceptance_missing',
          'plan_placement_zone_missing',
          'plan_vec3_invalid',
        ]),
      );
    });

    test('scene 轨：zone/placement 引用成立时通过', () {
      final Map<String, dynamic> raw = creativeFixtureCopy('plan_3d_chair.json')
        ..['track'] = 'scene'
        ..['language'] = 'scene_threejs'
        ..['zones'] = <Object?>[
          <String, Object?>{
            'id': 'room',
            'bounds_m': <double>[10, 3, 10],
          },
        ]
        ..['placements'] = <Object?>[
          <String, Object?>{
            'id': 'chair_01',
            'zone': 'room',
            'at_m': <double>[1, 0, 2],
          },
        ];
      final CreativeParseResult<CreativePlan> result = CreativePlan.parse(raw);
      expect(result.ok, isTrue);
      expect(result.value, isA<CreativePlan3d>());
    });
  });

  group('creative.plan video', () {
    test('15 秒剧本计划：镜头/事件/节拍全解析', () {
      final CreativeParseResult<CreativePlan> result = CreativePlan.parse(
        creativeFixture('plan_video_15s.json'),
      );
      expect(result.ok, isTrue);
      final CreativePlanVideo plan = result.value! as CreativePlanVideo;
      expect(plan.track, CreativeTrack.sillySkit);
      expect(plan.fps, creativeVideoFps);
      expect(plan.durationFrames, 450);
      expect(plan.beats!.bpm, 120);
      expect(plan.shots, hasLength(2));
      final CreativePlanShot first = plan.shots.first;
      expect(first.start, 0);
      expect(first.end, 90);
      expect(first.cast.single.id, 'hero');
      expect(first.events, hasLength(3));
      expect(first.events.first.type, 'vfx');
      expect(first.events.first.cue, 'fire/fireball');
      expect(first.events.first.seed, 7);
      expect(first.events.last.type, 'camera.shake');
      expect(first.caption!['text'], '点击之后会发生什么？');
      expect(plan.shots.last.transitionIn!['type'], 'wipe');
    });

    test('坏视频计划一次列出问题', () {
      final CreativeParseResult<CreativePlan> result = CreativePlan.parse(
        creativeFixture('plan_video_bad.json'),
      );
      expect(result.ok, isFalse);
      expect(
        _codes(result.validation),
        containsAll(<String>[
          'plan_fps_unsupported',
          'plan_cast_invalid',
          'plan_event_frame_invalid',
          'plan_event_cue_invalid',
          'plan_event_type_unknown',
          'plan_shot_overlap',
          'plan_shot_id_duplicate',
        ]),
      );
    });

    test('转场声明可以覆盖重叠帧数', () {
      final Map<String, dynamic> raw = creativeFixtureCopy(
        'plan_video_15s.json',
      );
      final List<Object?> shots = raw['shots'] as List<Object?>;
      final Map<String, dynamic> second = shots[1] as Map<String, dynamic>;
      second['start'] = 82;
      second['transitionIn'] = <String, Object?>{
        'type': 'wipe',
        'duration': 8,
        'direction': 'left',
      };
      final CreativeParseResult<CreativePlan> result = CreativePlan.parse(raw);
      expect(result.ok, isTrue);
      expect(_codes(result.validation), isNot(contains('plan_shot_overlap')));
    });

    test('事件帧不得超出镜头时长', () {
      final Map<String, dynamic> raw = creativeFixtureCopy(
        'plan_video_15s.json',
      );
      final List<Object?> shots = raw['shots'] as List<Object?>;
      final Map<String, dynamic> first = shots[0] as Map<String, dynamic>;
      final List<Object?> events = first['events'] as List<Object?>;
      (events.first as Map<String, dynamic>)['f'] = 90;
      final CreativeParseResult<CreativePlan> result = CreativePlan.parse(raw);
      expect(_codes(result.validation), contains('plan_event_frame_invalid'));
    });

    test('acceptance 不能为空', () {
      final Map<String, dynamic> raw = creativeFixtureCopy(
        'plan_video_15s.json',
      )..['acceptance'] = <Object?>[];
      final CreativeParseResult<CreativePlan> result = CreativePlan.parse(raw);
      expect(_codes(result.validation), contains('plan_acceptance_missing'));
    });
  });
}
