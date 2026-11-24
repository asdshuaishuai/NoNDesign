import 'package:flutter_test/flutter_test.dart';
import 'package:nondesign/core/creative/creative.dart';

import 'helpers/creative_fixtures.dart';

Set<String> _codes(CreativeValidation validation) =>
    validation.issues.map((CreativeIssue issue) => issue.code).toSet();

CreativeJudgment _judgment({
  Map<CreativeCriterion, double>? scores,
  List<CreativeImprovementItem> plan = const <CreativeImprovementItem>[],
  List<CreativeDefectFinding> defects = const <CreativeDefectFinding>[],
}) {
  final Map<CreativeCriterion, double> resolved =
      scores ??
      <CreativeCriterion, double>{
        for (final CreativeCriterion criterion in CreativeCriterion.values)
          criterion: 0.8,
      };
  return CreativeJudgment(
    criteria: <CreativeCriterion, CreativeCriterionScore>{
      for (final MapEntry<CreativeCriterion, double> entry in resolved.entries)
        entry.key: CreativeCriterionScore(score: entry.value, why: '可见证据'),
    },
    summary: '总体成立',
    improvementPlan: plan,
    defects: defects,
  );
}

CreativeGatesReport _gates({
  List<CreativeGate> gates = const <CreativeGate>[],
  Map<String, double> caps = const <String, double>{},
  int round = 0,
  CreativeVerdict? verdict,
}) {
  final CreativeVerdict resolved =
      verdict ??
      (gates.any((CreativeGate gate) => gate.verdict == CreativeVerdict.error)
          ? CreativeVerdict.error
          : gates.any(
              (CreativeGate gate) => gate.verdict == CreativeVerdict.fail,
            )
          ? CreativeVerdict.fail
          : gates.any(
              (CreativeGate gate) => gate.verdict == CreativeVerdict.warn,
            )
          ? CreativeVerdict.warn
          : CreativeVerdict.pass);
  return CreativeGatesReport(
    round: round,
    verdict: resolved,
    gates: gates,
    caps: caps,
  );
}

CreativeScoreResult _result(int round, double overall) => CreativeScoreResult(
  round: round,
  overall: overall,
  weightedSum: overall,
  penalties: 0,
  passed: false,
  gateVerdict: CreativeVerdict.pass,
  weights: CreativeRubrics.threeD,
  caps: const <CreativeAppliedCap>[],
  improvementPlan: const <CreativeImprovementItem>[],
);

void main() {
  group('creative.judgment', () {
    test('合法 judgment：六维、问题、改进项、accepted 与缺陷', () {
      final CreativeParseResult<CreativeJudgment> result =
          CreativeJudgment.parse(creativeFixture('judgment_3d_ok.json'));
      expect(result.ok, isTrue);
      final CreativeJudgment judgment = result.value!;
      expect(judgment.criteria, hasLength(CreativeCriterion.values.length));
      expect(judgment.criteria[CreativeCriterion.idea]!.score, 0.8);
      expect(judgment.issues.single.criterion, CreativeCriterion.craft);
      expect(judgment.issues.single.tile, 'm2');
      expect(judgment.improvementPlan.single.target, 'leg_fr');
      expect(judgment.acceptance, hasLength(2));
      expect(judgment.defects.single.id, 'floating_part');
      expect(judgment.defects.single.present, isTrue);
    });

    test('roundtrip：judgment 字段不变', () {
      final CreativeJudgment judgment = CreativeJudgment.parse(
        creativeFixture('judgment_3d_ok.json'),
      ).value!;
      final CreativeParseResult<CreativeJudgment> reparsed =
          CreativeJudgment.parse(judgment.toJson());
      expect(reparsed.ok, isTrue);
      expect(reparsed.value!.toJson(), equals(judgment.toJson()));
    });

    test('坏 judgment 一次列出问题', () {
      final CreativeParseResult<CreativeJudgment> result =
          CreativeJudgment.parse(creativeFixture('judgment_bad.json'));
      expect(result.ok, isFalse);
      expect(
        _codes(result.validation),
        containsAll(<String>[
          'judgment_criterion_missing',
          'judgment_criterion_invalid',
          'judgment_summary_missing',
          'judgment_issue_invalid',
          'judgment_improvement_invalid',
          'judgment_acceptance_invalid',
          'judgment_defect_invalid',
        ]),
      );
    });
  });

  group('creative.score', () {
    test('加权和：3D rubric 权重', () {
      final CreativeScoreResult result = CreativeScore.compute(
        judgment: _judgment(
          scores: <CreativeCriterion, double>{
            CreativeCriterion.idea: 0.8,
            CreativeCriterion.composition: 0.75,
            CreativeCriterion.craft: 0.8,
            CreativeCriterion.motion: 0.7,
            CreativeCriterion.legibility: 0.85,
            CreativeCriterion.constraintFit: 0.9,
          },
        ),
        gates: _gates(),
        weights: CreativeRubrics.threeD,
      );
      expect(result.weightedSum, closeTo(0.795, 1e-9));
      expect(result.overall, closeTo(0.795, 1e-9));
      expect(result.penalties, 0);
      expect(result.caps, isEmpty);
      expect(result.passed, isFalse); // 低于暂定通过线 0.85
    });

    test('caps 最后应用：浮动 cap 0.60 压过视觉高分', () {
      final CreativeScoreResult result = CreativeScore.compute(
        judgment: _judgment(
          scores: <CreativeCriterion, double>{
            for (final CreativeCriterion criterion in CreativeCriterion.values)
              criterion: 1,
          },
        ),
        gates: _gates(caps: <String, double>{'floating': 0.6}),
        weights: CreativeRubrics.threeD,
      );
      expect(result.overall, closeTo(0.6, 1e-9));
      final CreativeAppliedCap cap = result.caps.firstWhere(
        (CreativeAppliedCap item) => item.id == 'floating',
      );
      expect(cap.applied, isTrue);
      expect(cap.value, 0.6);
    });

    test('缺陷惩罚先于 caps', () {
      final CreativeScoreResult result = CreativeScore.compute(
        judgment: _judgment(
          scores: <CreativeCriterion, double>{
            for (final CreativeCriterion criterion in CreativeCriterion.values)
              criterion: 1,
          },
          defects: <CreativeDefectFinding>[
            const CreativeDefectFinding(id: 'floating_part', present: true),
          ],
        ),
        gates: _gates(caps: <String, double>{'floating': 0.6}),
        weights: CreativeRubrics.threeD,
        config: const CreativeScoreConfig(
          penalties: <String, double>{'floating_part': 0.2},
        ),
      );
      expect(result.weightedSum, 1);
      expect(result.penalties, closeTo(0.2, 1e-9));
      expect(result.overall, closeTo(0.6, 1e-9));
    });

    test('criterion 地板在加权前生效', () {
      final CreativeScoreResult result = CreativeScore.compute(
        judgment: _judgment(
          scores: <CreativeCriterion, double>{
            CreativeCriterion.idea: 0.5,
            CreativeCriterion.composition: 0.8,
            CreativeCriterion.craft: 0.8,
            CreativeCriterion.motion: 0.8,
            CreativeCriterion.legibility: 0.8,
            CreativeCriterion.constraintFit: 0.8,
          },
        ),
        gates: _gates(),
        weights: CreativeRubrics.threeD,
        config: const CreativeScoreConfig(
          criterionFloors: <CreativeCriterion, double>{
            CreativeCriterion.idea: 0.9,
          },
        ),
      );
      expect(result.weightedSum, closeTo(0.815, 1e-9));
    });

    test('build ERROR 直接清零，并把门的修复项放最前', () {
      final CreativeScoreResult result = CreativeScore.compute(
        judgment: _judgment(
          scores: <CreativeCriterion, double>{
            for (final CreativeCriterion criterion in CreativeCriterion.values)
              criterion: 1,
          },
          plan: <CreativeImprovementItem>[
            const CreativeImprovementItem(
              priority: 2,
              target: 'seat',
              action: '加厚 2mm',
              evidence: 'm1',
            ),
          ],
        ),
        gates: _gates(
          gates: <CreativeGate>[
            const CreativeGate(
              id: 'build',
              verdict: CreativeVerdict.error,
              fixHint: '修复 entry 文件编译错误',
            ),
          ],
        ),
        weights: CreativeRubrics.threeD,
      );
      expect(result.overall, 0);
      expect(result.improvementPlan.first.source, 'gate');
      expect(result.improvementPlan.first.priority, 0);
      expect(result.improvementPlan, hasLength(2));
      expect(result.passed, isFalse);
    });

    test('最佳轮：分数最高；0.03 内并列要求 pairwise', () {
      final CreativeBestRound? best = CreativeScore.selectBestRound(
        <CreativeScoreResult>[
          _result(0, 0.80),
          _result(1, 0.90),
          _result(2, 0.88),
        ],
      );
      expect(best, isNotNull);
      expect(best!.round, 1);
      expect(best.overall, 0.90);
      expect(best.tiedRounds, <int>[1, 2]);
      expect(best.requiresPairwise, isTrue);
      expect(
        CreativeScore.selectBestRound(const <CreativeScoreResult>[]),
        isNull,
      );
    });

    test('rubric 权重之和不是 1 时拒绝计算', () {
      expect(
        () => CreativeScore.compute(
          judgment: _judgment(),
          gates: _gates(),
          weights: const <CreativeCriterion, double>{
            CreativeCriterion.idea: 1.0,
          },
        ),
        throwsArgumentError,
      );
    });
  });
}
