import 'package:flutter_test/flutter_test.dart';
import 'package:nondesign/core/creative/creative_plan.dart';
import 'package:nondesign/core/creative/creative_schema.dart';
import 'package:nondesign/core/three/three_gates.dart';
import 'package:nondesign/core/three/three_scene_gates.dart';

CreativePlan3d _plan({List<double> placementAt = const <double>[0, 0, 0]}) =>
    CreativePlan.parse(<String, dynamic>{
          'schema': creativePlanSchema,
          'kind': '3d',
          'track': 'scene',
          'language': 'scene_threejs',
          'summary': '一个房间',
          'acceptance': <String>['地面平整 ≤1mm'],
          'parts': <Object?>[
            <String, Object?>{
              'id': 'table',
              'dims_m': <double>[1.2, 0.75, 0.8],
              'material': 'oak',
              'bbox_center_m': <double>[0, 0.475, 0],
            },
          ],
          'zones': <Object?>[
            <String, Object?>{
              'id': 'main',
              'bounds_m': <double>[10, 3, 10],
            },
          ],
          'placements': <Object?>[
            <String, Object?>{
              'id': 'table_spot',
              'zone': 'main',
              'at_m': placementAt,
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

ThreePartMeasure _floor({double centerY = 0.05}) => ThreePartMeasure(
  id: 'floor',
  box: _box(<double>[10, 0.1, 10], <double>[0, centerY, 0]),
  triangles: 12,
);

ThreePartMeasure _table({double centerY = 0.475}) => ThreePartMeasure(
  id: 'table',
  box: _box(<double>[1.2, 0.75, 0.8], <double>[0, centerY, 0]),
  triangles: 600,
);

ThreeObjectMeasure _measure({
  List<double>? floorCenter,
  double tableCenterY = 0.475,
  bool withLamp = false,
  int drawCalls = 1200,
}) => ThreeObjectMeasure(
  parts: <ThreePartMeasure>[
    _floor(centerY: floorCenter?[1] ?? 0.05),
    _table(centerY: tableCenterY),
    if (withLamp)
      ThreePartMeasure(
        id: 'lamp',
        box: _box(<double>[0.12, 0.12, 0.12], <double>[0, 1.6, 0]),
        triangles: 96,
      ),
  ],
  drawCalls: drawCalls,
);

void main() {
  group('场景 placement / census 门', () {
    test('落地 + 接触 + draw calls 正常 → PASS', () {
      final report = evaluateThreeSceneGates(_plan(), _measure());
      expect(
        report.verdict,
        CreativeVerdict.pass,
        reason: report.gates.toString(),
      );
      expect(report.caps, isEmpty);
      expect(report.gateById('placement')!.verdict, CreativeVerdict.pass);
      expect(report.gateById('census')!.metrics['draw_calls'], 1200);
    });

    test('无支撑漂浮物 → placement ERROR + cap 0.60', () {
      final report = evaluateThreeSceneGates(_plan(), _measure(withLamp: true));
      expect(report.verdict, CreativeVerdict.error);
      expect(report.caps['floating'], 0.60);
      expect(report.gateById('placement')!.metrics['floating_objects'], 1);
      expect(report.gateById('placement')!.fixHint, contains('落地'));
    });

    test('桌子穿插地面 25mm → penetration ERROR + cap 0.70', () {
      final report = evaluateThreeSceneGates(
        _plan(),
        _measure(tableCenterY: 0.45),
      );
      expect(report.verdict, CreativeVerdict.error);
      expect(report.caps['penetration'], 0.70);
      expect(
        report.gateById('placement')!.metrics['max_penetration_m'],
        closeTo(0.025, 1e-9),
      );
    });

    test('地面埋入 50mm → buried ERROR', () {
      final report = evaluateThreeSceneGates(
        _plan(),
        _measure(floorCenter: <double>[0, 0, 0]),
      );
      expect(report.verdict, CreativeVerdict.error);
      expect(report.extra['notes'].toString(), contains('buried_object'));
    });

    test('整体离地 150mm → ground_gap ERROR', () {
      final report = evaluateThreeSceneGates(
        _plan(),
        _measure(floorCenter: <double>[0, 0.2, 0], tableCenterY: 0.625),
      );
      expect(report.verdict, CreativeVerdict.error);
      expect(report.extra['notes'].toString(), contains('ground_gap'));
    });

    test('draw calls 16000 → census ERROR，不静默截断', () {
      final report = evaluateThreeSceneGates(
        _plan(),
        _measure(drawCalls: 16000),
      );
      expect(report.verdict, CreativeVerdict.error);
      expect(report.gateById('census')!.verdict, CreativeVerdict.error);
      expect(report.gateById('census')!.fixHint, contains('15000'));
    });

    test('placement 越界 → zone_out_of_bounds ERROR，fix hint 带 zone 尺寸', () {
      final report = evaluateThreeSceneGates(
        _plan(placementAt: <double>[10, 0, 0]),
        _measure(),
      );
      expect(report.verdict, CreativeVerdict.error);
      expect(
        report.gateById('placement')!.metrics['placements_outside_zone'],
        1,
      );
      expect(report.gateById('placement')!.fixHint, contains('10.000 m'));
    });

    test('没有测量 parts → measurement_empty ERROR（不伪造 PASS）', () {
      final report = evaluateThreeSceneGates(
        _plan(),
        const ThreeObjectMeasure(parts: <ThreePartMeasure>[]),
      );
      expect(report.verdict, CreativeVerdict.error);
      expect(report.extra['notes'].toString(), contains('measurement_empty'));
    });
  });
}
