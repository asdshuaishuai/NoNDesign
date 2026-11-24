import 'package:flutter_test/flutter_test.dart';
import 'package:nondesign/core/creative/creative_plan.dart';
import 'package:nondesign/core/three/three_plan.dart';

import 'helpers/creative_fixtures.dart';

void main() {
  group('3D plan 校验（three_plan）', () {
    test('合法椅子 plan：通过且无阻断项', () {
      final validation = validateThreePlan(
        creativeFixture('plan_3d_chair.json'),
      );
      expect(validation.ok, isTrue, reason: validation.fixHints.join('\n'));
      expect(validation.plan, isNotNull);
      expect(validation.allIssues.where((issue) => issue.blocking), isEmpty);
    });

    test('缺 acceptance 阻断；scene 缺 zones/cameras 阻断', () {
      final missingAcceptance = validateThreePlan(<String, dynamic>{
        'schema': 'nan.creative.plan/1',
        'kind': '3d',
        'track': 'static_object',
        'language': 'threejs',
        'summary': 'x',
        'acceptance': <Object?>[],
        'parts': <Object?>[
          <String, Object?>{
            'id': 'box',
            'dims_m': <double>[1, 1, 1],
            'material': 'oak',
          },
        ],
      });
      expect(missingAcceptance.ok, isFalse);
      expect(
        missingAcceptance.allIssues.map((issue) => issue.code),
        contains('plan_acceptance_missing'),
      );

      final scene = validateThreePlan(<String, dynamic>{
        'schema': 'nan.creative.plan/1',
        'kind': '3d',
        'track': 'scene',
        'language': 'scene_threejs',
        'summary': 'x',
        'acceptance': <String>['地面平整 ≤1mm'],
      });
      expect(scene.ok, isFalse);
      final codes = scene.allIssues.map((issue) => issue.code).toSet();
      expect(
        codes,
        containsAll(<String>[
          'three_plan_zones_missing',
          'three_plan_camera_missing',
        ]),
      );
    });

    test('旧规范 → plan 草案：标记 needs review，尺寸来自 size_scale', () {
      final raw = <String, dynamic>{
        'title': 'Saturn',
        'summary': '带环行星自转',
        'components': <Map<String, dynamic>>[
          <String, dynamic>{'id': 'planet', 'what': '球体', 'size_scale': 1.0},
          <String, dynamic>{
            'id': 'Ring Glow',
            'what': '扁平圆环',
            'size_scale': 1.8,
          },
        ],
        'materials': <Map<String, dynamic>>[
          <String, dynamic>{'id': 'rock', 'color_hex': '#c9a06a'},
        ],
        'acceptance': <String>['行星在场', '环可见 ≤2mm', '整体可辨识'],
      };
      final draft = draftPlanFromLegacySpec(raw);
      expect(draft['schema'], 'nan.creative.plan/1');
      expect(draft['track'], 'static_object');
      expect(draft['migration_needs_review'], isTrue);
      final parts = draft['parts'] as List;
      expect(parts, hasLength(2));
      expect((parts.first as Map)['id'], 'planet');
      expect((parts.last as Map)['id'], 'ring_glow');
      expect((parts.last as Map)['dims_m'], <double>[1.8, 1.8, 1.8]);

      final validation = validateThreePlan(draft);
      expect(validation.ok, isTrue);
      expect(
        validation.allIssues.map((issue) => issue.code),
        contains('three_plan_migration_draft'),
      );
    });

    test('验收项没有数字/单位 → 非阻断提醒', () {
      final validation = validateThreePlan(<String, dynamic>{
        'schema': 'nan.creative.plan/1',
        'kind': '3d',
        'track': 'static_object',
        'language': 'threejs',
        'summary': 'x',
        'acceptance': <String>['看起来不错'],
        'parts': <Object?>[
          <String, Object?>{
            'id': 'box',
            'dims_m': <double>[1, 1, 1],
            'material': 'oak',
          },
        ],
      });
      expect(
        validation.allIssues.map((issue) => issue.code),
        contains('three_plan_acceptance_not_observable'),
      );
    });

    test('plan 不是对象 / kind 不对 → 解析为空', () {
      expect(validateThreePlan(null).ok, isFalse);
      expect(
        validateThreePlan(<String, dynamic>{'kind': 'video'}).plan,
        isNull,
      );
    });
  });

  test('CreativePlan.parse 对 plan 草案 roundtrip 稳定', () {
    final draft = draftPlanFromLegacySpec(<String, dynamic>{
      'title': 'legacy',
      'components': <Map<String, dynamic>>[
        <String, dynamic>{'id': 'a', 'size_scale': 1.0},
      ],
      'acceptance': <String>['落地'],
    });
    final parsed = CreativePlan.parse(draft);
    expect(parsed.value, isA<CreativePlan3d>());
    expect(parsed.value!.toJson()['migration_needs_review'], isTrue);
  });
}
