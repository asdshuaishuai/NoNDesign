/// 3D 确定性门的纯 Dart 实现：measurement → `gates.json`。
///
/// 阈值来自 `docs/three-contract.md` §5 / `docs/skills/creative-workbench/
/// references/3d-pipeline.md` §6 / `research/3dcodeverse.md` §5.1：
/// bbox 每轴 `max(10mm, 10%)`、ground 10mm WARN / 30mm ERROR、接触 ≤2mm、
/// 穿插 >2mm WARN / >10mm ERROR、漂浮 ERROR、占位件 ERROR、孤岛 <5% WARN。
/// 执行面只负责产生测量（JS/WebView），本文件只做算术与 fix hint，不碰渲染。
library;

import '../creative/creative_gates.dart';
import '../creative/creative_plan.dart';
import '../creative/creative_schema.dart';

/// 三维点/尺寸。
final class ThreeVec3 {
  const ThreeVec3(this.x, this.y, this.z);

  final double x;
  final double y;
  final double z;

  static ThreeVec3? parse(Object? raw) {
    if (raw is! List || raw.length != 3) return null;
    final List<double> values = <double>[];
    for (final Object? item in raw) {
      if (item is! num || !item.isFinite) return null;
      values.add(item.toDouble());
    }
    return ThreeVec3(values[0], values[1], values[2]);
  }

  List<double> toJson() => <double>[x, y, z];
}

/// 轴对齐包围盒（世界坐标，单位米）。
final class ThreeBox3 {
  const ThreeBox3({required this.min, required this.max});

  final ThreeVec3 min;
  final ThreeVec3 max;

  ThreeVec3 get dims => ThreeVec3(max.x - min.x, max.y - min.y, max.z - min.z);
  ThreeVec3 get center =>
      ThreeVec3((max.x + min.x) / 2, (max.y + min.y) / 2, (max.z + min.z) / 2);

  static ThreeBox3? parse(Object? raw) {
    if (raw is! Map) return null;
    final Object? minValue = raw['min'];
    final Object? maxValue = raw['max'];
    final ThreeVec3? min = ThreeVec3.parse(minValue);
    final ThreeVec3? max = ThreeVec3.parse(maxValue);
    if (min == null || max == null) return null;
    if (max.x < min.x || max.y < min.y || max.z < min.z) return null;
    return ThreeBox3(min: min, max: max);
  }

  static ThreeBox3 fromPlanPart(CreativePlanPart part) {
    final ThreeVec3 center = part.bboxCenterM == null
        ? const ThreeVec3(0, 0, 0)
        : ThreeVec3(
            part.bboxCenterM![0],
            part.bboxCenterM![1],
            part.bboxCenterM![2],
          );
    final double hx = part.dimsM[0] / 2;
    final double hy = part.dimsM[1] / 2;
    final double hz = part.dimsM[2] / 2;
    return ThreeBox3(
      min: ThreeVec3(center.x - hx, center.y - hy, center.z - hz),
      max: ThreeVec3(center.x + hx, center.y + hy, center.z + hz),
    );
  }
}

/// 执行面测到的一个 part（id 必须与 plan 对齐）。
final class ThreePartMeasure {
  const ThreePartMeasure({
    required this.id,
    required this.box,
    this.triangles = 0,
    this.material = '',
  });

  final String id;
  final ThreeBox3 box;

  /// 三角面数（占位件判定与 detail budget 用）。
  final int triangles;
  final String material;

  static ThreePartMeasure? parse(Object? raw) {
    if (raw is! Map) return null;
    final String id = (raw['id'] ?? '').toString().trim();
    final ThreeBox3? box = ThreeBox3.parse(raw['bbox'] ?? raw);
    if (id.isEmpty || box == null) return null;
    final Object? triangles = raw['triangles'] ?? raw['tris'];
    return ThreePartMeasure(
      id: id,
      box: box,
      triangles: triangles is num && triangles.isFinite ? triangles.toInt() : 0,
      material: (raw['material'] ?? '').toString(),
    );
  }
}

/// 一次对象测量（执行面产出，`artifacts/measurement.json`）。
final class ThreeObjectMeasure {
  const ThreeObjectMeasure({
    required this.parts,
    this.buildMs = 0,
    this.drawCalls = 0,
  });

  final List<ThreePartMeasure> parts;
  final double buildMs;
  final int drawCalls;

  ThreePartMeasure? byId(String id) {
    for (final ThreePartMeasure part in parts) {
      if (part.id == id) return part;
    }
    return null;
  }

  /// 从 `measurement.json` 解析；坏项跳过而不是炸整份报告。
  static ThreeObjectMeasure parse(Object? raw) {
    if (raw is! Map) {
      return const ThreeObjectMeasure(parts: <ThreePartMeasure>[]);
    }
    final List<ThreePartMeasure> parts = <ThreePartMeasure>[];
    final Object? rawParts = raw['parts'];
    if (rawParts is List) {
      for (final Object? item in rawParts) {
        final ThreePartMeasure? parsed = ThreePartMeasure.parse(item);
        if (parsed != null) parts.add(parsed);
      }
    }
    final Object? buildMs = raw['build_ms'] ?? raw['buildMs'];
    final Object? drawCalls = raw['draw_calls'] ?? raw['drawCalls'];
    return ThreeObjectMeasure(
      parts: parts,
      buildMs: buildMs is num && buildMs.isFinite ? buildMs.toDouble() : 0,
      drawCalls: drawCalls is num && drawCalls.isFinite ? drawCalls.toInt() : 0,
    );
  }
}

/// 门阈值（集中一处；测试锚定）。单位：米。
final class ThreeGateOptions {
  const ThreeGateOptions({
    this.bboxToleranceMinM = 0.010,
    this.bboxToleranceRatio = 0.10,
    this.groundWarnM = 0.010,
    this.groundErrorM = 0.030,
    this.contactM = 0.002,
    this.penetrationWarnM = 0.002,
    this.penetrationErrorM = 0.010,
    this.placeholderMaxTriangles = 12,
    this.placeholderToleranceM = 0.001,
    this.islandWarnRatio = 0.05,
    this.minTriangles = 0,
    this.maxTriangles = 0,
    this.maxBuildMs = 0,
  });

  final double bboxToleranceMinM;
  final double bboxToleranceRatio;
  final double groundWarnM;
  final double groundErrorM;
  final double contactM;
  final double penetrationWarnM;
  final double penetrationErrorM;
  final int placeholderMaxTriangles;
  final double placeholderToleranceM;
  final double islandWarnRatio;

  /// detail budget（0 = 不检查；阈值未在契约里定死，由调用方显式给）。
  final int minTriangles;
  final int maxTriangles;
  final double maxBuildMs;
}

/// 单条门发现（内部；最终聚合成 [CreativeGate]）。
final class _Finding {
  _Finding(
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

/// 评估对象门的纯函数。返回可直接落 `artifacts/gates.json` 的报告。
CreativeGatesReport evaluateThreeGates(
  CreativePlan3d plan,
  ThreeObjectMeasure measurement, {
  int round = 0,
  ThreeGateOptions options = const ThreeGateOptions(),
}) {
  final List<_Finding> findings = <_Finding>[];
  final Map<String, double> metrics = <String, double>{};
  _checkContract(plan, measurement, options, findings, metrics);
  _checkConnectivity(plan, measurement, options, findings, metrics);
  _checkDetail(plan, measurement, options, findings, metrics);

  final Map<String, List<_Finding>> byGate = <String, List<_Finding>>{};
  for (final _Finding finding in findings) {
    byGate.putIfAbsent(finding.gate, () => <_Finding>[]).add(finding);
  }
  final List<CreativeGate> gates = <CreativeGate>[];
  final Map<String, double> caps = <String, double>{};
  final List<String> coreGates = <String>['contract', 'connectivity'];
  if (byGate.containsKey('detail_budget') ||
      options.minTriangles > 0 ||
      options.maxTriangles > 0 ||
      options.maxBuildMs > 0) {
    coreGates.add('detail_budget');
  }
  for (final String gateId in coreGates) {
    final List<_Finding> gateFindings = byGate[gateId] ?? const <_Finding>[];
    final CreativeVerdict verdict = _worst(gateFindings);
    final _Finding? worst = _firstBlocking(gateFindings);
    final String fixHint = worst == null
        ? ''
        : gateFindings
              .where((finding) => finding.verdict == worst.verdict)
              .map(
                (finding) =>
                    finding.fixHint.isEmpty ? finding.message : finding.fixHint,
              )
              .join('；');
    gates.add(
      CreativeGate(
        id: gateId,
        verdict: verdict,
        metrics: _gateMetrics(gateId, metrics),
        fixHint: fixHint,
      ),
    );
    if (verdict == CreativeVerdict.error) {
      if (gateId == 'contract') caps['contract'] = 0.75;
      if (_hasFloating(findings)) caps['floating'] = 0.60;
      if (_hasPenetrationError(findings)) caps['penetration'] = 0.70;
    }
  }
  final CreativeVerdict overall = _worst(findings);
  return CreativeGatesReport(
    round: round,
    verdict: overall,
    gates: gates,
    caps: caps,
    extra: <String, Object?>{
      'schema': creativeGatesSchema,
      'track': plan.track.wire,
      'notes': findings
          .map((finding) => '${finding.code}: ${finding.message}')
          .toList(growable: false),
    },
  );
}

void _checkContract(
  CreativePlan3d plan,
  ThreeObjectMeasure measurement,
  ThreeGateOptions options,
  List<_Finding> findings,
  Map<String, double> metrics,
) {
  double maxBboxDelta = 0;
  int missing = 0;
  int placeholders = 0;
  final Map<String, double> axisTolerance = <String, double>{};

  for (final CreativePlanPart part in plan.parts) {
    final ThreePartMeasure? measured = measurement.byId(part.id);
    if (measured == null) {
      missing++;
      findings.add(
        _Finding(
          'contract',
          CreativeVerdict.error,
          'missing_part',
          'plan 中的 ${part.id} 在测量里不存在',
          fixHint: '补回 ${part.id} 的几何，或从 plan 删除该 part',
        ),
      );
      continue;
    }
    final ThreeVec3 measuredDims = measured.box.dims;
    final List<double> planned = part.dimsM;
    final List<double> actual = <double>[
      measuredDims.x,
      measuredDims.y,
      measuredDims.z,
    ];
    for (int axis = 0; axis < 3; axis++) {
      final double tolerance = _bboxTolerance(planned[axis], options);
      final double delta = (actual[axis] - planned[axis]).abs();
      if (delta > maxBboxDelta) maxBboxDelta = delta;
      final String axisName = <String>['x', 'y', 'z'][axis];
      axisTolerance['${part.id}.$axisName'] = tolerance;
      if (delta > tolerance * 3) {
        findings.add(
          _Finding(
            'contract',
            CreativeVerdict.error,
            'bbox_delta',
            '${part.id} 的 $axisName 尺寸偏差 ${_m(delta)}（容差 ${_m(tolerance)}）',
            fixHint:
                '把 ${part.id} 的 $axisName 尺寸调整 ${_m(planned[axis] - actual[axis])}',
          ),
        );
      } else if (delta > tolerance) {
        findings.add(
          _Finding(
            'contract',
            CreativeVerdict.warn,
            'bbox_delta',
            '${part.id} 的 $axisName 尺寸偏差 ${_m(delta)} 超过容差 ${_m(tolerance)}',
            fixHint:
                '把 ${part.id} 的 $axisName 尺寸调整 ${_m(planned[axis] - actual[axis])}',
          ),
        );
      }
    }
    final bool placeholder =
        measured.triangles > 0 &&
        measured.triangles <= options.placeholderMaxTriangles &&
        (actual[0] - planned[0]).abs() <= options.placeholderToleranceM &&
        (actual[1] - planned[1]).abs() <= options.placeholderToleranceM &&
        (actual[2] - planned[2]).abs() <= options.placeholderToleranceM;
    if (placeholder) {
      placeholders++;
      findings.add(
        _Finding(
          'contract',
          CreativeVerdict.error,
          'placeholder_part',
          '${part.id} 是 ≤${options.placeholderMaxTriangles} 三角的占位盒',
          fixHint: '把 ${part.id} 做成真实几何（placeholders 只允许出现在 plan）',
        ),
      );
    }
  }

  // footprint 居中：overall bbox center 与 plan 的 bbox 中心偏差（只在 plan 给过 bbox 中心时）。
  double footprintOffset = 0;
  final List<ThreeBox3> plannedBoxes = <ThreeBox3>[
    for (final CreativePlanPart part in plan.parts)
      if (part.bboxCenterM != null) ThreeBox3.fromPlanPart(part),
  ];
  if (plannedBoxes.isNotEmpty && measurement.parts.isNotEmpty) {
    final ThreeBox3 measuredOverall = _overallBox(
      measurement.parts.map((part) => part.box),
    );
    final ThreeBox3 plannedOverall = _overallBox(plannedBoxes);
    final ThreeVec3 measuredCenter = measuredOverall.center;
    final ThreeVec3 plannedCenter = plannedOverall.center;
    final double dx = (measuredCenter.x - plannedCenter.x).abs();
    final double dz = (measuredCenter.z - plannedCenter.z).abs();
    footprintOffset = dx > dz ? dx : dz;
    final double footprint = plannedOverall.dims.x > plannedOverall.dims.z
        ? plannedOverall.dims.x
        : plannedOverall.dims.z;
    final double tolerance = _bboxTolerance(footprint, options);
    if (footprintOffset > tolerance * 3) {
      findings.add(
        _Finding(
          'contract',
          CreativeVerdict.error,
          'footprint_offset',
          '整体 footprint 偏离 ${_m(footprintOffset)}（容差 ${_m(tolerance)}）',
          fixHint:
              '沿 (${_m(plannedCenter.x - measuredCenter.x)}, 0, ${_m(plannedCenter.z - measuredCenter.z)}) m 平移',
        ),
      );
    } else if (footprintOffset > tolerance) {
      findings.add(
        _Finding(
          'contract',
          CreativeVerdict.warn,
          'footprint_offset',
          '整体 footprint 偏离 ${_m(footprintOffset)}',
          fixHint:
              '沿 (${_m(plannedCenter.x - measuredCenter.x)}, 0, ${_m(plannedCenter.z - measuredCenter.z)}) m 平移',
        ),
      );
    }
  }

  // 接地：只在 plan 的验收明确要求落地/座高时检查（漂浮行星不该被判不落地）。
  double groundGap = 0;
  if (_needsGround(plan) && measurement.parts.isNotEmpty) {
    final double lowest = _overallBox(measurement.parts.map((part) => part.box))
        .min
        .y;
    groundGap = lowest;
    if (lowest > options.groundErrorM) {
      findings.add(
        _Finding(
          'contract',
          CreativeVerdict.error,
          'ground_gap',
          '整体离地 ${_m(lowest)}（阈值 ${_m(options.groundErrorM)}）',
          fixHint: '沿 y 平移 ${_m(-lowest)} 让最低点落地',
        ),
      );
    } else if (lowest > options.groundWarnM) {
      findings.add(
        _Finding(
          'contract',
          CreativeVerdict.warn,
          'ground_gap',
          '整体离地 ${_m(lowest)}',
          fixHint: '沿 y 平移 ${_m(-lowest)} 让最低点落地',
        ),
      );
    } else if (lowest < -options.groundErrorM) {
      findings.add(
        _Finding(
          'contract',
          CreativeVerdict.error,
          'ground_penetration',
          '整体埋入地面 ${_m(-lowest)}',
          fixHint: '沿 y 平移 ${_m(-lowest)} 抬出地面',
        ),
      );
    } else if (lowest < -options.groundWarnM) {
      findings.add(
        _Finding(
          'contract',
          CreativeVerdict.warn,
          'ground_penetration',
          '整体埋入地面 ${_m(-lowest)}',
          fixHint: '沿 y 平移 ${_m(-lowest)} 抬出地面',
        ),
      );
    }
  }

  metrics['max_bbox_delta_m'] = maxBboxDelta;
  metrics['footprint_offset_m'] = footprintOffset;
  metrics['ground_gap_m'] = groundGap;
  metrics['missing_parts'] = missing.toDouble();
  metrics['placeholder_parts'] = placeholders.toDouble();
  metrics['bbox_tolerance_min_m'] = options.bboxToleranceMinM;
}

void _checkConnectivity(
  CreativePlan3d plan,
  ThreeObjectMeasure measurement,
  ThreeGateOptions options,
  List<_Finding> findings,
  Map<String, double> metrics,
) {
  if (measurement.parts.length < 2 && plan.parts.length < 2) {
    metrics['max_penetration_m'] = 0;
    metrics['floating_parts'] = 0;
    metrics['islands'] = 1;
    return;
  }
  double maxPenetration = 0;
  int floating = 0;
  final Map<String, Set<String>> adjacency = <String, Set<String>>{
    for (final ThreePartMeasure part in measurement.parts) part.id: <String>{},
  };
  final bool needsGround = _needsGround(plan);

  // 接触标记必须按 part 记录（成对更新两侧）——只在 i 侧记会让后一个 part
  // 到不了自己的 j 循环，被误判漂浮。
  final Set<String> contacted = <String>{};
  for (int i = 0; i < measurement.parts.length; i++) {
    final ThreePartMeasure a = measurement.parts[i];
    if (needsGround && a.box.min.y.abs() <= options.groundWarnM) {
      contacted.add(a.id);
    }
    for (int j = i + 1; j < measurement.parts.length; j++) {
      final ThreePartMeasure b = measurement.parts[j];
      final List<double> gaps = _axisGaps(a.box, b.box);
      final List<double> overlaps = _axisOverlaps(a.box, b.box);
      final bool contact = gaps.every((gap) => gap <= options.contactM);
      if (contact) {
        contacted.add(a.id);
        contacted.add(b.id);
        adjacency[a.id]!.add(b.id);
        adjacency[b.id]!.add(a.id);
      }
      if (overlaps.every((overlap) => overlap > 0)) {
        final double penetration = overlaps.reduce((x, y) => x < y ? x : y);
        if (penetration > maxPenetration) maxPenetration = penetration;
        if (penetration > options.penetrationErrorM) {
          findings.add(
            _Finding(
              'connectivity',
              CreativeVerdict.error,
              'penetration',
              '${a.id} 与 ${b.id} 穿插 ${_m(penetration)}（阈值 ${_m(options.penetrationErrorM)}）',
              fixHint: '让 ${a.id}/${b.id} 止于接触面：缩小重叠 ${_m(penetration)}',
            ),
          );
        } else if (penetration > options.penetrationWarnM) {
          findings.add(
            _Finding(
              'connectivity',
              CreativeVerdict.warn,
              'penetration',
              '${a.id} 与 ${b.id} 穿插 ${_m(penetration)}',
              fixHint: '让 ${a.id}/${b.id} 止于接触面：缩小重叠 ${_m(penetration)}',
            ),
          );
        }
      }
    }
  }
  for (final ThreePartMeasure part in measurement.parts) {
    if (contacted.contains(part.id)) continue;
    floating++;
    final double lowest = part.box.min.y;
    findings.add(
      _Finding(
        'connectivity',
        CreativeVerdict.error,
        'floating_part',
        '${part.id} 漂浮：没有接触面且离地 ${_m(lowest)}',
        fixHint: '漂浮：沿 y 平移 ${_m(-lowest)} 落地，或把它接到支撑件上',
      ),
    );
  }

  // 孤岛：连通分量里小于总 parts 5% 的分量（且不是最大）→ WARN。
  final List<Set<String>> islands = <Set<String>>[];
  final Set<String> seen = <String>{};
  for (final String id in adjacency.keys) {
    if (!seen.add(id)) continue;
    final Set<String> component = <String>{id};
    final List<String> stack = <String>[id];
    while (stack.isNotEmpty) {
      final String current = stack.removeLast();
      for (final String next in adjacency[current]!) {
        if (seen.add(next)) {
          component.add(next);
          stack.add(next);
        }
      }
    }
    islands.add(component);
  }
  islands.sort((a, b) => b.length.compareTo(a.length));
  final int largest = islands.isEmpty ? 0 : islands.first.length;
  for (final Set<String> island in islands.skip(1)) {
    if (largest > 0 && island.length / largest < options.islandWarnRatio) {
      findings.add(
        _Finding(
          'connectivity',
          CreativeVerdict.warn,
          'island',
          '疑似孤岛：${island.join(',')} 与主体不相连',
          fixHint: '把 ${island.join(',')} 接到主体，或从 plan 删除',
        ),
      );
    }
  }

  metrics['max_penetration_m'] = maxPenetration;
  metrics['floating_parts'] = floating.toDouble();
  metrics['islands'] = islands.length.toDouble();
}

void _checkDetail(
  CreativePlan3d plan,
  ThreeObjectMeasure measurement,
  ThreeGateOptions options,
  List<_Finding> findings,
  Map<String, double> metrics,
) {
  if (options.minTriangles <= 0 &&
      options.maxTriangles <= 0 &&
      options.maxBuildMs <= 0) {
    return;
  }
  final int triangles = measurement.parts.fold<int>(
    0,
    (sum, part) => sum + part.triangles,
  );
  metrics['triangles'] = triangles.toDouble();
  metrics['build_ms'] = measurement.buildMs;
  if (options.maxTriangles > 0 && triangles > options.maxTriangles) {
    findings.add(
      _Finding(
        'detail_budget',
        CreativeVerdict.error,
        'triangles_over',
        '三角面 $triangles 超过上限 ${options.maxTriangles}',
        fixHint: '降采样/合并几何到 ≤${options.maxTriangles} 三角',
      ),
    );
  }
  if (options.minTriangles > 0 && triangles < options.minTriangles) {
    findings.add(
      _Finding(
        'detail_budget',
        CreativeVerdict.warn,
        'triangles_low',
        '三角面 $triangles 低于下限 ${options.minTriangles}（可能太粗糙）',
        fixHint: '补细节到 ≥${options.minTriangles} 三角',
      ),
    );
  }
  if (options.maxBuildMs > 0 && measurement.buildMs > options.maxBuildMs) {
    findings.add(
      _Finding(
        'detail_budget',
        CreativeVerdict.warn,
        'build_slow',
        '构建耗时 ${measurement.buildMs.toStringAsFixed(1)}ms 超预算 ${options.maxBuildMs.toStringAsFixed(1)}ms',
        fixHint: '减少 parts/几何，或缓存重复几何',
      ),
    );
  }
}

double _bboxTolerance(double planned, ThreeGateOptions options) {
  final double ratio = options.bboxToleranceRatio * planned.abs();
  return ratio > options.bboxToleranceMinM ? ratio : options.bboxToleranceMinM;
}

bool _needsGround(CreativePlan3d plan) => plan.acceptance.any(
  (item) => RegExp(r'落地|地面|地面|ground|floor|座高|贴地').hasMatch(item),
);

List<double> _axisGaps(ThreeBox3 a, ThreeBox3 b) => <double>[
  _gap(a.min.x, a.max.x, b.min.x, b.max.x),
  _gap(a.min.y, a.max.y, b.min.y, b.max.y),
  _gap(a.min.z, a.max.z, b.min.z, b.max.z),
];

List<double> _axisOverlaps(ThreeBox3 a, ThreeBox3 b) => <double>[
  _overlap(a.min.x, a.max.x, b.min.x, b.max.x),
  _overlap(a.min.y, a.max.y, b.min.y, b.max.y),
  _overlap(a.min.z, a.max.z, b.min.z, b.max.z),
];

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

ThreeBox3 _overallBox(Iterable<ThreeBox3> boxes) {
  double minX = double.infinity, minY = double.infinity, minZ = double.infinity;
  double maxX = -double.infinity,
      maxY = -double.infinity,
      maxZ = -double.infinity;
  for (final ThreeBox3 box in boxes) {
    if (box.min.x < minX) minX = box.min.x;
    if (box.min.y < minY) minY = box.min.y;
    if (box.min.z < minZ) minZ = box.min.z;
    if (box.max.x > maxX) maxX = box.max.x;
    if (box.max.y > maxY) maxY = box.max.y;
    if (box.max.z > maxZ) maxZ = box.max.z;
  }
  return ThreeBox3(
    min: ThreeVec3(minX, minY, minZ),
    max: ThreeVec3(maxX, maxY, maxZ),
  );
}

CreativeVerdict _worst(List<_Finding> findings) {
  if (findings.any((finding) => finding.verdict == CreativeVerdict.error)) {
    return CreativeVerdict.error;
  }
  if (findings.any((finding) => finding.verdict == CreativeVerdict.warn)) {
    return CreativeVerdict.warn;
  }
  return CreativeVerdict.pass;
}

_Finding? _firstBlocking(List<_Finding> findings) {
  for (final _Finding finding in findings) {
    if (finding.verdict == CreativeVerdict.error) return finding;
  }
  for (final _Finding finding in findings) {
    if (finding.verdict == CreativeVerdict.warn) return finding;
  }
  return null;
}

bool _hasFloating(List<_Finding> findings) =>
    findings.any((finding) => finding.code == 'floating_part');
bool _hasPenetrationError(List<_Finding> findings) => findings.any(
  (finding) =>
      finding.code == 'penetration' && finding.verdict == CreativeVerdict.error,
);

Map<String, double> _gateMetrics(String gateId, Map<String, double> all) =>
    switch (gateId) {
      'contract' => <String, double>{
        if (all.containsKey('max_bbox_delta_m'))
          'max_bbox_delta_m': all['max_bbox_delta_m']!,
        if (all.containsKey('footprint_offset_m'))
          'footprint_offset_m': all['footprint_offset_m']!,
        if (all.containsKey('ground_gap_m'))
          'ground_gap_m': all['ground_gap_m']!,
        if (all.containsKey('missing_parts'))
          'missing_parts': all['missing_parts']!,
        if (all.containsKey('placeholder_parts'))
          'placeholder_parts': all['placeholder_parts']!,
      },
      'connectivity' => <String, double>{
        if (all.containsKey('max_penetration_m'))
          'max_penetration_m': all['max_penetration_m']!,
        if (all.containsKey('floating_parts'))
          'floating_parts': all['floating_parts']!,
        if (all.containsKey('islands')) 'islands': all['islands']!,
      },
      'detail_budget' => <String, double>{
        if (all.containsKey('triangles')) 'triangles': all['triangles']!,
        if (all.containsKey('build_ms')) 'build_ms': all['build_ms']!,
      },
      _ => const <String, double>{},
    };

String _m(double value) => '${value.toStringAsFixed(3)} m';
