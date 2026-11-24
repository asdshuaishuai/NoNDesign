import 'package:flutter_test/flutter_test.dart';
import 'package:nondesign/core/creative/creative_plan.dart';
import 'package:nondesign/core/creative/creative_schema.dart';
import 'package:nondesign/core/three/three_gates.dart';

CreativePlan3d _plan({double topCenterY = 0.35}) =>
    CreativePlan.parse(<String, dynamic>{
          'schema': creativePlanSchema,
          'kind': '3d',
          'track': 'static_object',
          'language': 'threejs',
          'summary': '两层盒子',
          'acceptance': <String>['整体落地 ≤2mm', '整体宽 1m'],
          'parts': <Object?>[
            <String, Object?>{
              'id': 'base',
              'dims_m': <double>[1, 0.1, 1],
              'material': 'oak',
              'bbox_center_m': <double>[0, 0.05, 0],
            },
            <String, Object?>{
              'id': 'top',
              'dims_m': <double>[0.5, 0.5, 0.5],
              'material': 'oak',
              'bbox_center_m': <double>[0, topCenterY, 0],
            },
          ],
          'cameras': <Object?>[
            <String, Object?>{
              'id': 'hero',
              'at_m': <double>[4, 2, 4],
              'look_at_m': <double>[0, 1, 0],
            },
          ],
        }).value!
        as CreativePlan3d;

ThreeBox3 _box(List<double> dims, List<double> center) => ThreeBox3(
  min: ThreeVec3(
    center[0] - dims[0] / 2,
    center[1] - dims[1] / 2,
    center[2] - dims[2] / 2,
  ),
  max: ThreeVec3(
    center[0] + dims[0] / 2,
    center[1] + dims[1] / 2,
    center[2] + dims[2] / 2,
  ),
);

ThreeObjectMeasure _measure({
  List<double>? topDims,
  List<double>? topCenter,
  int topTriangles = 120,
}) => ThreeObjectMeasure(
  parts: <ThreePartMeasure>[
    ThreePartMeasure(
      id: 'base',
      box: _box(<double>[1, 0.1, 1], <double>[0, 0.05, 0]),
      triangles: 120,
    ),
    ThreePartMeasure(
      id: 'top',
      box: _box(
        topDims ?? <double>[0.5, 0.5, 0.5],
        topCenter ?? <double>[0, 0.35, 0],
      ),
      triangles: topTriangles,
    ),
  ],
);

void main() {
  group('3D 对象门（contract / connectivity）', () {
    test('尺寸一致、接地、无漂浮穿插 → PASS，无 caps', () {
      final report = evaluateThreeGates(_plan(), _measure());
      expect(
        report.verdict,
        CreativeVerdict.pass,
        reason: report.gates.toString(),
      );
      expect(report.caps, isEmpty);
      expect(report.gateById('contract')!.verdict, CreativeVerdict.pass);
      expect(report.gateById('connectivity')!.verdict, CreativeVerdict.pass);
      expect(
        report.gateById('contract')!.metrics['max_bbox_delta_m'],
        closeTo(0, 1e-9),
      );
      expect(
        report.gateById('connectivity')!.metrics['max_penetration_m'],
        closeTo(0, 1e-9),
      );
    });

    test('整体离地 150mm → contract ERROR，cap 0.75，fix hint 带平移米数', () {
      final plan = _plan(topCenterY: 0.5);
      final measure = _measure(topCenter: <double>[0, 0.5, 0]);
      // 两层一起上移 150mm：base 0.15–0.25、top 0.25–0.75。
      final report = evaluateThreeGates(
        plan,
        ThreeObjectMeasure(
          parts: <ThreePartMeasure>[
            ThreePartMeasure(
              id: 'base',
              box: _box(<double>[1, 0.1, 1], <double>[0, 0.2, 0]),
              triangles: 120,
            ),
            ThreePartMeasure(
              id: 'top',
              box: _box(<double>[0.5, 0.5, 0.5], <double>[0, 0.65, 0]),
              triangles: 120,
            ),
          ],
        ),
      );
      expect(report.verdict, CreativeVerdict.error);
      expect(
        report.gates.firstWhere((g) => g.id == 'contract').verdict,
        CreativeVerdict.error,
      );
      expect(report.caps['contract'], 0.75);
      expect(report.gateById('contract')!.fixHint, contains(' m'));
      expect(measure.parts, isNotEmpty);
    });

    test('top 漂浮（不相连、离地）→ connectivity ERROR，cap 0.60', () {
      final plan = _plan(topCenterY: 0.8);
      final measure = _measure(topCenter: <double>[0, 0.8, 0]);
      final report = evaluateThreeGates(plan, measure);
      expect(report.verdict, CreativeVerdict.error);
      expect(report.caps['floating'], 0.60);
      expect(report.gateById('connectivity')!.metrics['floating_parts'], 1);
      expect(report.gateById('connectivity')!.fixHint, contains('漂浮'));
    });

    test('top 穿插 50mm → connectivity ERROR，cap 0.70', () {
      final plan = _plan(topCenterY: 0.3);
      final measure = _measure(topCenter: <double>[0, 0.3, 0]);
      final report = evaluateThreeGates(plan, measure);
      expect(report.verdict, CreativeVerdict.error);
      expect(report.caps['penetration'], 0.70);
      expect(
        report.gateById('connectivity')!.metrics['max_penetration_m'],
        closeTo(0.05, 1e-9),
      );
    });

    test('bbox 偏差 300mm（容差 50mm）→ contract ERROR', () {
      final report = evaluateThreeGates(
        _plan(),
        _measure(topDims: <double>[0.8, 0.5, 0.5]),
      );
      expect(report.verdict, CreativeVerdict.error);
      expect(report.caps['contract'], 0.75);
      expect(
        report.gateById('contract')!.metrics['max_bbox_delta_m'],
        closeTo(0.3, 1e-9),
      );
    });

    test('≤12 三角且尺寸吻合的占位盒 → placeholder ERROR', () {
      final report = evaluateThreeGates(_plan(), _measure(topTriangles: 8));
      expect(report.verdict, CreativeVerdict.error);
      expect(report.extra['notes']?.toString(), contains('placeholder_part'));
    });

    test('detail budget 超上限 → detail_budget ERROR', () {
      final report = evaluateThreeGates(
        _plan(),
        _measure(),
        options: const ThreeGateOptions(maxTriangles: 100),
      );
      expect(report.verdict, CreativeVerdict.error);
      expect(report.gateById('detail_budget')!.verdict, CreativeVerdict.error);
      expect(report.gateById('detail_budget')!.metrics['triangles'], 240);
    });
  });

  group('measurement 解析', () {
    test('坏项跳过、有限值校验', () {
      final measure = ThreeObjectMeasure.parse(<String, Object?>{
        'parts': <Object?>[
          <String, Object?>{
            'id': 'ok',
            'bbox': <String, Object?>{
              'min': <double>[0, 0, 0],
              'max': <double>[1, 1, 1],
            },
            'triangles': 6,
          },
          <String, Object?>{
            'id': 'bad',
            'bbox': <double>[0, 0, 0],
          },
        ],
        'build_ms': 12.5,
      });
      expect(measure.parts, hasLength(1));
      expect(measure.parts.single.id, 'ok');
      expect(measure.buildMs, 12.5);
    });
  });
}
