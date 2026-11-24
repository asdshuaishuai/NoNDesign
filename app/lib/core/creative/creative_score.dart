/// 盲评分数：rubric 权重 → 缺陷惩罚 → 地板 → 门 caps 的纯函数算术。
///
/// 契约见 `docs/skills/creative-workbench/references/judging.md` §4 与
/// `references/schemas.md` §5。三条纪律：
/// 1. 总分只由本文件算，judge 不自己给总分；
/// 2. **caps 最后应用**——门 ERROR 不能被「看起来不错」翻案；
/// 3. 最佳轮 ≠ 最后一轮；并列（0.03 内）必须走 pairwise。
library;

import 'creative_gates.dart';
import 'creative_judgment.dart';
import 'creative_schema.dart';

/// 轨道 rubric 起始权重（judging.md §4；数值是起点，需用固定样例校准）。
abstract final class CreativeRubrics {
  const CreativeRubrics._();

  static const Map<CreativeCriterion, double> video =
      <CreativeCriterion, double>{
        CreativeCriterion.idea: 0.20,
        CreativeCriterion.composition: 0.20,
        CreativeCriterion.craft: 0.20,
        CreativeCriterion.motion: 0.20,
        CreativeCriterion.legibility: 0.10,
        CreativeCriterion.constraintFit: 0.10,
      };

  static const Map<CreativeCriterion, double> threeD =
      <CreativeCriterion, double>{
        CreativeCriterion.idea: 0.15,
        CreativeCriterion.composition: 0.20,
        CreativeCriterion.craft: 0.25,
        CreativeCriterion.motion: 0.15,
        CreativeCriterion.legibility: 0.10,
        CreativeCriterion.constraintFit: 0.15,
      };

  static Map<CreativeCriterion, double> forKind(CreativeKind kind) =>
      kind == CreativeKind.video ? video : threeD;
}

/// 评分参数。默认值是 R0 冻结的**暂定值**（见
/// `docs/creative-refactor-decisions.md`）：`passThreshold = 0.85`、
/// 缺陷惩罚默认 0（先靠 caps）、criterion 地板暂空、并列容差 0.03。
final class CreativeScoreConfig {
  const CreativeScoreConfig({
    this.passThreshold = 0.85,
    this.tieTolerance = 0.03,
    this.penalties = const <String, double>{},
    this.caps = const <String, double>{},
    this.criterionFloors = const <CreativeCriterion, double>{},
  });

  final double passThreshold;
  final double tieTolerance;

  /// 缺陷 id → 扣分（`judgment.defects[].present` 时生效）。
  final Map<String, double> penalties;

  /// 显式 caps；与 `gates.json` 的 caps 合并，本字段优先。
  final Map<String, double> caps;

  /// 维度地板：加权前先把低于地板的维度抬到地板（R0 暂空）。
  final Map<CreativeCriterion, double> criterionFloors;
}

/// 一条实际生效过的 cap。
final class CreativeAppliedCap {
  const CreativeAppliedCap({
    required this.id,
    required this.value,
    required this.applied,
  });

  final String id;
  final double value;
  final bool applied;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'value': value,
    'applied': applied,
  };
}

/// 一轮的评分结果（可落 `judge/rNN/score.json`）。
final class CreativeScoreResult {
  const CreativeScoreResult({
    required this.round,
    required this.overall,
    required this.weightedSum,
    required this.penalties,
    required this.passed,
    required this.gateVerdict,
    required this.weights,
    required this.caps,
    required this.improvementPlan,
    this.extra = const <String, Object?>{},
  });

  final int round;
  final double overall;
  final double weightedSum;
  final double penalties;
  final bool passed;
  final CreativeVerdict gateVerdict;
  final Map<CreativeCriterion, double> weights;
  final List<CreativeAppliedCap> caps;
  final List<CreativeImprovementItem> improvementPlan;
  final Map<String, Object?> extra;

  Map<String, Object?> toJson() => <String, Object?>{
    'schema': creativeScoreSchema,
    'round': round,
    'overall': overall,
    'passed': passed,
    'weights': <String, Object?>{
      for (final MapEntry<CreativeCriterion, double> entry in weights.entries)
        entry.key.wire: entry.value,
    },
    'caps': caps
        .map((CreativeAppliedCap cap) => cap.toJson())
        .toList(growable: false),
    'improvement_plan': improvementPlan
        .map((CreativeImprovementItem item) => item.toJson())
        .toList(growable: false),
    ...extra,
  };
}

/// 最佳轮选择结果。并列时 `requiresPairwise == true`，调用方必须跑两种展示顺序。
final class CreativeBestRound {
  const CreativeBestRound({
    required this.round,
    required this.overall,
    required this.tiedRounds,
    required this.requiresPairwise,
  });

  final int round;
  final double overall;
  final List<int> tiedRounds;
  final bool requiresPairwise;
}

/// 评分算术（纯函数）。
abstract final class CreativeScore {
  const CreativeScore._();

  static CreativeScoreResult compute({
    required CreativeJudgment judgment,
    required CreativeGatesReport gates,
    required Map<CreativeCriterion, double> weights,
    CreativeScoreConfig config = const CreativeScoreConfig(),
  }) {
    final double weightSum = weights.values.fold<double>(
      0,
      (double sum, double w) => sum + w,
    );
    if ((weightSum - 1).abs() > 1e-6) {
      throw ArgumentError.value(
        weights,
        'weights',
        'rubric 权重之和必须为 1（当前 $weightSum）',
      );
    }
    for (final CreativeCriterion criterion in CreativeCriterion.values) {
      if (!weights.containsKey(criterion)) {
        throw ArgumentError.value(weights, 'weights', '缺少维度 ${criterion.wire}');
      }
      if (!judgment.criteria.containsKey(criterion)) {
        throw ArgumentError.value(
          judgment.criteria,
          'judgment',
          'judge 缺维度 ${criterion.wire}',
        );
      }
    }

    double weightedSum = 0;
    for (final CreativeCriterion criterion in CreativeCriterion.values) {
      double score = judgment.criteria[criterion]!.score;
      final double? floor = config.criterionFloors[criterion];
      if (floor != null && score < floor) score = floor;
      weightedSum += weights[criterion]! * score;
    }

    double penalties = 0;
    for (final CreativeDefectFinding defect in judgment.defects) {
      if (!defect.present) continue;
      penalties += config.penalties[defect.id] ?? 0;
    }

    final Map<String, double> caps = <String, double>{};
    caps.addAll(gates.caps);
    caps.addAll(config.caps);
    // 「build error 0」：构建失败直接清零，不看视觉。
    if (gates.gateById('build')?.verdict == CreativeVerdict.error) {
      caps['build_error'] = 0;
    }

    double overall = (weightedSum - penalties).clamp(0, 1).toDouble();
    final List<CreativeAppliedCap> appliedCaps = <CreativeAppliedCap>[];
    for (final String id in caps.keys.toList()..sort()) {
      final double value = caps[id]!;
      final bool applied = value < overall;
      if (applied) overall = value;
      appliedCaps.add(
        CreativeAppliedCap(id: id, value: value, applied: applied),
      );
    }
    overall = overall.clamp(0, 1).toDouble();

    final List<CreativeImprovementItem> plan = <CreativeImprovementItem>[
      for (final CreativeGate gate in gates.gates)
        if (gate.verdict == CreativeVerdict.error)
          CreativeImprovementItem(
            priority: 0,
            target: gate.id,
            action: gate.fixHint,
            evidence: 'gate ERROR',
            source: 'gate',
          ),
      ...judgment.improvementPlan,
    ];

    final bool passed =
        !gates.hasBlocking && plan.isEmpty && overall >= config.passThreshold;

    return CreativeScoreResult(
      round: gates.round,
      overall: overall,
      weightedSum: weightedSum,
      penalties: penalties,
      passed: passed,
      gateVerdict: gates.verdict,
      weights: weights,
      caps: appliedCaps,
      improvementPlan: plan,
    );
  }

  /// 最高分为最佳轮；最高分 0.03 内出现多轮时要求 pairwise 复核。
  static CreativeBestRound? selectBestRound(
    Iterable<CreativeScoreResult> results, {
    double tieTolerance = 0.03,
  }) {
    final List<CreativeScoreResult> all = results.toList(growable: false);
    if (all.isEmpty) return null;
    final CreativeScoreResult best = all.reduce(
      (CreativeScoreResult a, CreativeScoreResult b) =>
          b.overall > a.overall ? b : a,
    );
    final List<int> tied = <int>[
      for (final CreativeScoreResult result in all)
        if (best.overall - result.overall <= tieTolerance) result.round,
    ]..sort();
    return CreativeBestRound(
      round: best.round,
      overall: best.overall,
      tiedRounds: tied,
      requiresPairwise: tied.length > 1,
    );
  }
}
