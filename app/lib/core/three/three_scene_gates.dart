/// 场景轨（`scene`）确定性门：placement + census 的纯 Dart 实现。
///
/// 契约见 `docs/three-contract.md` §5：脚下间隙、埋入、无支撑、相互穿插、越界、
/// draw calls ≤15000；每条 ERROR 带可执行 fix hint（米）。
/// 输入是执行面测量（`artifacts/measurement.json`：世界 bbox per part）+
/// plan 的 zones/placements；本文件不依赖 WebView/渲染。
library;

import '../creative/creative_gates.dart';
import '../creative/creative_plan.dart';
import '../creative/creative_schema.dart';
import 'three_gates.dart';

/// 场景门阈值（集中一处；单位米）。
final class ThreeSceneGateOptions {
  const ThreeSceneGateOptions({
    this.groundWarnM = 0.010,
    this.groundErrorM = 0.030,
    this.contactM = 0.002,
    this.penetrationWarnM = 0.002,
    this.penetrationErrorM = 0.010,
    this.drawCallMax = 15000,
    this.zoneSlackM = 0.001,
  });

  final double groundWarnM;
  final double groundErrorM;
  final double contactM;
  final double penetrationWarnM;
  final double penetrationErrorM;
  final int drawCallMax;
  final double zoneSlackM;
}

final class _SceneFinding {
  _SceneFinding(
    this.gate,
    this.verdict,
    this.code,
    this.message, {
    this.fixHint = '',
  });

  final String gate;
  final CreativeVerdict verdict;
  final String code;
  final String message;
  final String fixHint;
}

/// 评估场景轨的 placement/census 门。
CreativeGatesReport evaluateThreeSceneGates(
  CreativePlan3d plan,
  ThreeObjectMeasure measurement, {
  int round = 0,
  ThreeSceneGateOptions options = const ThreeSceneGateOptions(),
}) {
  final List<_SceneFinding> findings = <_SceneFinding>[];
  final Map<String, double> metrics = <String, double>{};
  _checkPlacement(plan, measurement, options, findings, metrics);
  _checkCensus(plan, measurement, options, findings, metrics);

  final List<CreativeGate> gates = <CreativeGate>[];
  final Map<String, double> caps = <String, double>{};
  for (final String gateId in <String>['placement', 'census']) {
    final List<_SceneFinding> gateFindings = findings
        .where((finding) => finding.gate == gateId)
        .toList(growable: false);
    final CreativeVerdict verdict = _worst(gateFindings);
    final String fixHint = gateFindings
        .where(
          (finding) =>
              verdict != CreativeVerdict.pass && finding.verdict == verdict,
        )
        .map(
          (finding) =>
              finding.fixHint.isEmpty ? finding.message : finding.fixHint,
        )
        .join('；');
    gates.add(
      CreativeGate(
        id: gateId,
        verdict: verdict,
        metrics: _metricsFor(gateId, metrics),
        fixHint: fixHint,
      ),
    );
    if (verdict == CreativeVerdict.error) {
      if (gateFindings.any((finding) => finding.code == 'floating_object')) {
        caps['floating'] = 0.60;
      }
      if (gateFindings.any((finding) => finding.code == 'penetration')) {
        caps['penetration'] = 0.70;
      }
      if (gateId == 'placement') caps['placement'] = 0.75;
    }
  }
  return CreativeGatesReport(
    round: round,
    verdict: _worst(findings),
    gates: gates,
    caps: caps,
    extra: <String, Object?>{
      'schema': creativeGatesSchema,
      'track': 'scene',
      'notes': findings
          .map((finding) => '${finding.code}: ${finding.message}')
          .toList(growable: false),
    },
  );
}

void _checkPlacement(
  CreativePlan3d plan,
  ThreeObjectMeasure measurement,
  ThreeSceneGateOptions options,
  List<_SceneFinding> findings,
  Map<String, double> metrics,
) {
  if (measurement.parts.isEmpty) {
    findings.add(
      _SceneFinding(
        'placement',
        CreativeVerdict.error,
        'measurement_empty',
        '测量里没有 parts，无法判断摆放',
        fixHint: '先让预览页回传场景测量（bbox per node）',
      ),
    );
    return;
  }
  double lowest = double.infinity;
  for (final ThreePartMeasure part in measurement.parts) {
    final double minY = part.box.min.y;
    if (minY < lowest) lowest = minY;
    if (minY > options.groundErrorM) {
      // 只有明确应落地/支撑的对象才单独报？场景整体由最低点判；逐件漂浮在下面报。
      continue;
    }
    if (minY < -options.groundErrorM) {
      findings.add(
        _SceneFinding(
          'placement',
          CreativeVerdict.error,
          'buried_object',
          '${part.id} 埋入地面 ${_m(-minY)}',
          fixHint: '${part.id}：沿 y 平移 ${_m(-minY)} 抬出地面',
        ),
      );
    } else if (minY < -options.groundWarnM) {
      findings.add(
        _SceneFinding(
          'placement',
          CreativeVerdict.warn,
          'buried_object',
          '${part.id} 埋入地面 ${_m(-minY)}',
          fixHint: '${part.id}：沿 y 平移 ${_m(-minY)} 抬出地面',
        ),
      );
    }
  }
  metrics['lowest_y_m'] = lowest.isFinite ? lowest : 0;
  if (lowest.isFinite && lowest > options.groundErrorM) {
    findings.add(
      _SceneFinding(
        'placement',
        CreativeVerdict.error,
        'ground_gap',
        '场景整体离地 ${_m(lowest)}（阈值 ${_m(options.groundErrorM)}）',
        fixHint: '整体沿 y 平移 ${_m(-lowest)} 落地',
      ),
    );
  } else if (lowest.isFinite && lowest > options.groundWarnM) {
    findings.add(
      _SceneFinding(
        'placement',
        CreativeVerdict.warn,
        'ground_gap',
        '场景整体离地 ${_m(lowest)}',
        fixHint: '整体沿 y 平移 ${_m(-lowest)} 落地',
      ),
    );
  }

  double maxPenetration = 0;
  int floating = 0;
  final Set<String> supported = <String>{};
  for (int i = 0; i < measurement.parts.length; i++) {
    final ThreePartMeasure a = measurement.parts[i];
    if (a.box.min.y.abs() <= options.groundWarnM) supported.add(a.id);
    for (int j = i + 1; j < measurement.parts.length; j++) {
      final ThreePartMeasure b = measurement.parts[j];
      if (_touching(a.box, b.box, options.contactM)) {
        supported.add(a.id);
        supported.add(b.id);
      }
      final double penetration = _penetration(a.box, b.box);
      if (penetration > maxPenetration) maxPenetration = penetration;
      if (penetration > options.penetrationErrorM) {
        findings.add(
          _SceneFinding(
            'placement',
            CreativeVerdict.error,
            'penetration',
            '${a.id} 与 ${b.id} 穿插 ${_m(penetration)}',
            fixHint: '缩小 ${a.id}/${b.id} 的重叠 ${_m(penetration)}，或让它们止于接触面',
          ),
        );
      } else if (penetration > options.penetrationWarnM) {
        findings.add(
          _SceneFinding(
            'placement',
            CreativeVerdict.warn,
            'penetration',
            '${a.id} 与 ${b.id} 穿插 ${_m(penetration)}',
            fixHint: '缩小 ${a.id}/${b.id} 的重叠 ${_m(penetration)}',
          ),
        );
      }
    }
  }
  for (final ThreePartMeasure part in measurement.parts) {
    if (supported.contains(part.id)) continue;
    floating++;
    findings.add(
      _SceneFinding(
        'placement',
        CreativeVerdict.error,
        'floating_object',
        '${part.id} 无支撑且离地 ${_m(part.box.min.y)}',
        fixHint: '${part.id}：沿 y 平移 ${_m(-part.box.min.y)} 落地，或接到支撑面上',
      ),
    );
  }
  metrics['max_penetration_m'] = maxPenetration;
  metrics['floating_objects'] = floating.toDouble();

  // zones/placements：placement.at_m 必须落在 zone.bounds_m 的半边长内。
  final Map<String, ThreeVec3> zoneBounds = <String, ThreeVec3>{};
  for (final Map<String, Object?> zone in plan.zones) {
    final String? id = zone['id']?.toString();
    final ThreeVec3? bounds = _vec3(zone['bounds_m']);
    if (id != null && id.isNotEmpty && bounds != null) zoneBounds[id] = bounds;
  }
  int outside = 0;
  for (final Map<String, Object?> placement in plan.placements) {
    final String? id = placement['id']?.toString();
    final String? zoneId = placement['zone']?.toString();
    final ThreeVec3? at = _vec3(placement['at_m']);
    if (id == null || zoneId == null || at == null) continue;
    final ThreeVec3? bounds = zoneBounds[zoneId];
    if (bounds == null) continue;
    final bool inBounds =
        at.x.abs() <= bounds.x / 2 + options.zoneSlackM &&
        at.z.abs() <= bounds.z / 2 + options.zoneSlackM &&
        at.y >= -options.zoneSlackM &&
        at.y <= bounds.y + options.zoneSlackM;
    if (!inBounds) {
      outside++;
      findings.add(
        _SceneFinding(
          'placement',
          CreativeVerdict.error,
          'zone_out_of_bounds',
          '${placement['id']} 在 zone $zoneId 边界外',
          fixHint:
              '把 placement $id 的 at_m 移回 zone 内（zone ${_m(bounds.x)}×${_m(bounds.y)}×${_m(bounds.z)}）',
        ),
      );
    }
  }
  metrics['placements_outside_zone'] = outside.toDouble();
}

void _checkCensus(
  CreativePlan3d plan,
  ThreeObjectMeasure measurement,
  ThreeSceneGateOptions options,
  List<_SceneFinding> findings,
  Map<String, double> metrics,
) {
  metrics['draw_calls'] = measurement.drawCalls.toDouble();
  metrics['parts'] = measurement.parts.length.toDouble();
  if (measurement.drawCalls <= 0) return;
  if (measurement.drawCalls > options.drawCallMax) {
    findings.add(
      _SceneFinding(
        'census',
        CreativeVerdict.error,
        'draw_calls_over',
        'draw calls ${measurement.drawCalls} 超过上限 ${options.drawCallMax}',
        fixHint: '合并静态几何/共享材质，把 draw calls 降到 ≤${options.drawCallMax}',
      ),
    );
  }
}

bool _touching(ThreeBox3 a, ThreeBox3 b, double contactM) {
  final List<double> gaps = <double>[
    _gap(a.min.x, a.max.x, b.min.x, b.max.x),
    _gap(a.min.y, a.max.y, b.min.y, b.max.y),
    _gap(a.min.z, a.max.z, b.min.z, b.max.z),
  ];
  return gaps.every((gap) => gap <= contactM);
}

double _penetration(ThreeBox3 a, ThreeBox3 b) {
  final List<double> overlaps = <double>[
    _overlap(a.min.x, a.max.x, b.min.x, b.max.x),
    _overlap(a.min.y, a.max.y, b.min.y, b.max.y),
    _overlap(a.min.z, a.max.z, b.min.z, b.max.z),
  ];
  if (overlaps.any((overlap) => overlap <= 0)) return 0;
  return overlaps.reduce((x, y) => x < y ? x : y);
}

double _gap(double aMin, double aMax, double bMin, double bMax) {
  final double low = aMin > bMin ? aMin : bMin;
  final double high = aMax < bMax ? aMax : bMax;
  return high < low ? low - high : 0;
}

double _overlap(double aMin, double aMax, double bMin, double bMax) {
  final double low = aMin > bMin ? aMin : bMin;
  final double high = aMax < bMax ? aMax : bMax;
  return high > low ? high - low : 0;
}

ThreeVec3? _vec3(Object? raw) {
  if (raw is! List || raw.length != 3) return null;
  final List<double> out = <double>[];
  for (final Object? item in raw) {
    if (item is! num || !item.isFinite) return null;
    out.add(item.toDouble());
  }
  return ThreeVec3(out[0], out[1], out[2]);
}

CreativeVerdict _worst(List<_SceneFinding> findings) {
  if (findings.any((finding) => finding.verdict == CreativeVerdict.error)) {
    return CreativeVerdict.error;
  }
  if (findings.any((finding) => finding.verdict == CreativeVerdict.warn)) {
    return CreativeVerdict.warn;
  }
  return CreativeVerdict.pass;
}

Map<String, double> _metricsFor(String gateId, Map<String, double> all) =>
    switch (gateId) {
      'placement' => <String, double>{
        if (all.containsKey('lowest_y_m')) 'lowest_y_m': all['lowest_y_m']!,
        if (all.containsKey('max_penetration_m'))
          'max_penetration_m': all['max_penetration_m']!,
        if (all.containsKey('floating_objects'))
          'floating_objects': all['floating_objects']!,
        if (all.containsKey('placements_outside_zone'))
          'placements_outside_zone': all['placements_outside_zone']!,
      },
      'census' => <String, double>{
        if (all.containsKey('draw_calls')) 'draw_calls': all['draw_calls']!,
        if (all.containsKey('parts')) 'parts': all['parts']!,
      },
      _ => const <String, double>{},
    };

String _m(double value) => '${value.toStringAsFixed(3)} m';
