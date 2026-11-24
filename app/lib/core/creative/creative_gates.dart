/// `artifacts/gates.json`：确定性门的报告契约。
///
/// 门是「代码能回答的问题」的裁决：`PASS / WARN / FAIL / ERROR`，ERROR 必须带
/// 可执行 fix hint，视觉判断不能翻案。契约见
/// `docs/skills/creative-workbench/references/schemas.md` §3 与
/// `references/judging.md` §4。
library;

import 'creative_schema.dart';

/// 单个门的裁决与测量值。
final class CreativeGate {
  const CreativeGate({
    required this.id,
    required this.verdict,
    this.metrics = const <String, double>{},
    this.fixHint = '',
    this.extra = const <String, Object?>{},
  });

  /// 门的稳定 id（如 `contract` / `connectivity` / `placement`）。
  final String id;
  final CreativeVerdict verdict;

  /// 可测量的数字（门原话，如 `max_bbox_delta_m`）。
  final Map<String, double> metrics;

  /// 可执行的修复提示（门失败时必须给，运行时的原生单位：米/px/度）。
  final String fixHint;
  final Map<String, Object?> extra;

  static const Set<String> knownKeys = <String>{
    'id',
    'verdict',
    'metrics',
    'fix_hint',
  };

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'verdict': verdict.wire,
    if (metrics.isNotEmpty) 'metrics': metrics,
    if (fixHint.isNotEmpty) 'fix_hint': fixHint,
    ...extra,
  };
}

/// 一轮全部门的结果。`caps` 里是这一轮实际生效的分数上限（0–1）。
final class CreativeGatesReport {
  const CreativeGatesReport({
    required this.round,
    required this.verdict,
    this.gates = const <CreativeGate>[],
    this.caps = const <String, double>{},
    this.extra = const <String, Object?>{},
  });

  final int round;
  final CreativeVerdict verdict;
  final List<CreativeGate> gates;

  /// 例：`{floating: 0.60, penetration: 0.70}`。
  final Map<String, double> caps;
  final Map<String, Object?> extra;

  static const Set<String> knownKeys = <String>{
    'schema',
    'round',
    'verdict',
    'gates',
    'caps',
  };

  bool get hasError =>
      gates.any((CreativeGate gate) => gate.verdict == CreativeVerdict.error);

  /// 有 FAIL/ERROR：分数会被 cap，且不能被视觉判断翻案。
  bool get hasBlocking =>
      gates.any((CreativeGate gate) => gate.verdict.isBlocking);

  CreativeGate? gateById(String id) {
    for (final CreativeGate gate in gates) {
      if (gate.id == id) return gate;
    }
    return null;
  }

  static CreativeParseResult<CreativeGatesReport> parse(Object? raw) {
    final CreativeValidation validation = CreativeValidation();
    final Map<String, Object?>? map = creativeJsonMap(raw);
    if (map == null) {
      validation.add('', 'gates_not_object', 'gates.json 必须是 JSON 对象');
      return CreativeParseResult<CreativeGatesReport>(null, validation);
    }
    if (map['schema'] != creativeGatesSchema) {
      validation.add(
        '/schema',
        'gates_schema_mismatch',
        'schema 必须是 $creativeGatesSchema',
      );
    }
    final int? round = creativeInt(map['round']);
    if (round == null || round < 0) {
      validation.add('/round', 'gates_round_invalid', 'round 必须是 ≥0 的整数');
    }
    final CreativeVerdict? verdict = creativeEnumByWire(
      CreativeVerdict.values,
      (CreativeVerdict value) => value.wire,
      map['verdict'],
    );
    if (verdict == null) {
      validation.add(
        '/verdict',
        'gates_verdict_invalid',
        'verdict 必须是 PASS/WARN/FAIL/ERROR',
      );
    }

    final List<CreativeGate> gates = <CreativeGate>[];
    final List<Object?>? rawGates = creativeJsonList(map['gates']);
    if (rawGates == null) {
      validation.add('/gates', 'gates_list_invalid', 'gates 必须是数组');
    } else {
      final Set<String> ids = <String>{};
      for (int i = 0; i < rawGates.length; i++) {
        final String pointer = creativeIndexPointer('/gates', i);
        final Map<String, Object?>? entry = creativeJsonMap(rawGates[i]);
        if (entry == null) {
          validation.add(pointer, 'gates_entry_invalid', 'gate 必须是对象');
          continue;
        }
        final String? id = creativeNonEmptyString(entry['id']);
        if (id == null) {
          validation.add('$pointer/id', 'gates_id_empty', 'gate.id 不能为空');
        } else if (!ids.add(id)) {
          validation.add('$pointer/id', 'gates_id_duplicate', 'gate id 重复：$id');
        }
        final CreativeVerdict? gateVerdict = creativeEnumByWire(
          CreativeVerdict.values,
          (CreativeVerdict value) => value.wire,
          entry['verdict'],
        );
        if (gateVerdict == null) {
          validation.add(
            '$pointer/verdict',
            'gates_verdict_invalid',
            'gate.verdict 不在枚举内',
          );
        }
        final Map<String, Object?>? metricsRaw = creativeJsonMap(
          entry['metrics'],
        );
        final Map<String, double> metrics = <String, double>{};
        if (entry['metrics'] != null && metricsRaw == null) {
          validation.add(
            '$pointer/metrics',
            'gates_metrics_invalid',
            'metrics 必须是对象',
          );
        } else if (metricsRaw != null) {
          for (final MapEntry<String, Object?> metric in metricsRaw.entries) {
            final double? value = creativeFiniteDouble(metric.value);
            if (value == null) {
              validation.add(
                creativePointer('$pointer/metrics', metric.key),
                'gates_metric_non_finite',
                'metrics 值必须是有限数字（禁止 NaN/Infinity）',
              );
              continue;
            }
            metrics[metric.key] = value;
          }
        }
        final String fixHint = creativeNonEmptyString(entry['fix_hint']) ?? '';
        if (gateVerdict == CreativeVerdict.error && fixHint.isEmpty) {
          validation.add(
            '$pointer/fix_hint',
            'gates_fix_hint_missing',
            'ERROR 门必须给可执行 fix_hint',
          );
        }
        gates.add(
          CreativeGate(
            id: id ?? '',
            verdict: gateVerdict ?? CreativeVerdict.warn,
            metrics: metrics,
            fixHint: fixHint,
            extra: _collectExtras(entry, CreativeGate.knownKeys),
          ),
        );
      }
      if (gates.isEmpty) {
        validation.warn('/gates', 'gates_empty', 'gates 为空：无法区分「通过」与「没跑」');
      }
      if (gates.any(
            (CreativeGate gate) => gate.verdict == CreativeVerdict.error,
          ) &&
          verdict != null &&
          verdict != CreativeVerdict.error) {
        validation.add(
          '/verdict',
          'gates_verdict_mismatch',
          '存在 ERROR 门时顶层 verdict 必须是 ERROR',
        );
      }
    }

    final Map<String, Object?>? capsRaw = creativeJsonMap(map['caps']);
    final Map<String, double> caps = <String, double>{};
    if (map['caps'] != null && capsRaw == null) {
      validation.add('/caps', 'gates_caps_invalid', 'caps 必须是对象');
    } else if (capsRaw != null) {
      for (final MapEntry<String, Object?> cap in capsRaw.entries) {
        final double? value = creativeFiniteDouble(cap.value);
        if (value == null || value < 0 || value > 1) {
          validation.add(
            creativePointer('/caps', cap.key),
            'gates_caps_invalid',
            'cap 必须是 0–1 的有限数字',
          );
          continue;
        }
        caps[cap.key] = value;
      }
    }

    if (round == null || verdict == null) {
      return CreativeParseResult<CreativeGatesReport>(null, validation);
    }
    return CreativeParseResult<CreativeGatesReport>(
      CreativeGatesReport(
        round: round,
        verdict: verdict,
        gates: gates,
        caps: caps,
        extra: _collectExtras(map, CreativeGatesReport.knownKeys),
      ),
      validation,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'schema': creativeGatesSchema,
    'round': round,
    'verdict': verdict.wire,
    'gates': gates
        .map((CreativeGate gate) => gate.toJson())
        .toList(growable: false),
    if (caps.isNotEmpty) 'caps': caps,
    ...extra,
  };
}

Map<String, Object?> _collectExtras(
  Map<String, Object?> map,
  Set<String> known,
) {
  final Map<String, Object?> extra = <String, Object?>{};
  for (final MapEntry<String, Object?> entry in map.entries) {
    if (known.contains(entry.key)) continue;
    extra[entry.key] = entry.value;
  }
  return extra;
}
