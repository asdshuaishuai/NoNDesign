import 'package:flutter_test/flutter_test.dart';
import 'package:nondesign/core/creative/creative.dart';

import 'helpers/creative_fixtures.dart';

Set<String> _codes(CreativeValidation validation) =>
    validation.issues.map((CreativeIssue issue) => issue.code).toSet();

void main() {
  group('creative.gates', () {
    test('合法 gates 报告：裁决、metrics、fix hint 与 caps', () {
      final CreativeParseResult<CreativeGatesReport> result =
          CreativeGatesReport.parse(creativeFixture('gates_3d_floating.json'));
      expect(result.ok, isTrue);
      final CreativeGatesReport report = result.value!;
      expect(report.round, 0);
      expect(report.verdict, CreativeVerdict.error);
      expect(report.gates, hasLength(3));
      expect(report.hasError, isTrue);
      expect(report.gateById('contract')!.verdict, CreativeVerdict.pass);
      expect(report.gateById('connectivity')!.fixHint, contains('平移'));
      expect(report.caps['floating'], 0.6);
    });

    test('roundtrip：gates.json 字段不变', () {
      final CreativeGatesReport report = CreativeGatesReport.parse(
        creativeFixture('gates_3d_floating.json'),
      ).value!;
      final CreativeParseResult<CreativeGatesReport> reparsed =
          CreativeGatesReport.parse(report.toJson());
      expect(reparsed.ok, isTrue);
      expect(reparsed.value!.toJson(), equals(report.toJson()));
    });

    test('ERROR 门没有 fix hint 是阻断问题', () {
      final Map<String, dynamic> raw = creativeFixtureCopy(
        'gates_3d_floating.json',
      );
      final List<Object?> gates = raw['gates'] as List<Object?>;
      (gates[1] as Map<String, dynamic>).remove('fix_hint');
      final CreativeParseResult<CreativeGatesReport> result =
          CreativeGatesReport.parse(raw);
      expect(_codes(result.validation), contains('gates_fix_hint_missing'));
    });

    test('metrics 出现 NaN 是阻断问题', () {
      final Map<String, Object?> raw = <String, Object?>{
        'schema': creativeGatesSchema,
        'round': 0,
        'verdict': 'PASS',
        'gates': <Object?>[
          <String, Object?>{
            'id': 'contract',
            'verdict': 'PASS',
            'metrics': <String, Object?>{'max_bbox_delta_m': double.nan},
          },
        ],
      };
      final CreativeParseResult<CreativeGatesReport> result =
          CreativeGatesReport.parse(raw);
      expect(_codes(result.validation), contains('gates_metric_non_finite'));
    });

    test('存在 ERROR 门时顶层 verdict 必须是 ERROR', () {
      final Map<String, dynamic> raw = creativeFixtureCopy(
        'gates_3d_floating.json',
      )..['verdict'] = 'PASS';
      final CreativeParseResult<CreativeGatesReport> result =
          CreativeGatesReport.parse(raw);
      expect(_codes(result.validation), contains('gates_verdict_mismatch'));
    });

    test('cap 必须在 0–1 之间', () {
      final Map<String, dynamic> raw = creativeFixtureCopy(
        'gates_3d_floating.json',
      )..['caps'] = <String, Object?>{'floating': 1.5};
      final CreativeParseResult<CreativeGatesReport> result =
          CreativeGatesReport.parse(raw);
      expect(_codes(result.validation), contains('gates_caps_invalid'));
    });

    test('重复 gate id 是阻断问题', () {
      final Map<String, dynamic> raw = creativeFixtureCopy(
        'gates_3d_floating.json',
      );
      final List<Object?> gates = raw['gates'] as List<Object?>;
      (gates[2] as Map<String, dynamic>)['id'] = 'contract';
      final CreativeParseResult<CreativeGatesReport> result =
          CreativeGatesReport.parse(raw);
      expect(_codes(result.validation), contains('gates_id_duplicate'));
    });
  });
}
