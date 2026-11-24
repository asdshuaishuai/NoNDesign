/// `judge/rNN/judgment.json`：盲评返回的六维判断与改进清单。
///
/// 盲评规则见 `docs/skills/creative-workbench/references/judging.md`：评审只看
/// `brief.md` + 图，不看生成者代码/推理，也**不自己给总分**（总分由
/// `creative_score.dart` 算）。
library;

import 'creative_schema.dart';

/// 单个维度的评分与观察依据。
final class CreativeCriterionScore {
  const CreativeCriterionScore({
    required this.score,
    required this.why,
    this.extra = const <String, Object?>{},
  });

  /// 0–1。
  final double score;

  /// 必须引用可见证据，不允许空泛评价。
  final String why;
  final Map<String, Object?> extra;

  static const Set<String> knownKeys = <String>{'score', 'why'};

  Map<String, Object?> toJson() => <String, Object?>{
    'score': score,
    'why': why,
    ...extra,
  };
}

/// 评审指出的一个问题（必须能指到 tile/证据）。
final class CreativeJudgmentIssue {
  const CreativeJudgmentIssue({
    required this.criterion,
    required this.tile,
    required this.evidence,
    required this.fix,
    this.extra = const <String, Object?>{},
  });

  final CreativeCriterion criterion;
  final String tile;
  final String evidence;
  final String fix;
  final Map<String, Object?> extra;

  static const Set<String> knownKeys = <String>{
    'criterion',
    'tile',
    'evidence',
    'fix',
  };

  Map<String, Object?> toJson() => <String, Object?>{
    'criterion': criterion.wire,
    'tile': tile,
    'evidence': evidence,
    'fix': fix,
    ...extra,
  };
}

/// 下一轮 refine 的唯一输入项。
final class CreativeImprovementItem {
  const CreativeImprovementItem({
    required this.priority,
    required this.target,
    required this.action,
    this.evidence = '',
    this.source = 'judge',
    this.extra = const <String, Object?>{},
  });

  /// 1 = 最高优先级；门 ERROR 的修复用 0。
  final int priority;
  final String target;
  final String action;
  final String evidence;

  /// `judge` / `gate`。
  final String source;
  final Map<String, Object?> extra;

  Map<String, Object?> toJson() => <String, Object?>{
    'priority': priority,
    'target': target,
    'action': action,
    if (evidence.isNotEmpty) 'evidence': evidence,
    if (source != 'judge') 'source': source,
    ...extra,
  };
}

/// acceptance 逐项回答。
final class CreativeAcceptanceVerdict {
  const CreativeAcceptanceVerdict({
    required this.item,
    required this.pass,
    this.evidence = '',
    this.extra = const <String, Object?>{},
  });

  final String item;
  final bool pass;
  final String evidence;
  final Map<String, Object?> extra;

  Map<String, Object?> toJson() => <String, Object?>{
    'item': item,
    'pass': pass,
    if (evidence.isNotEmpty) 'evidence': evidence,
    ...extra,
  };
}

/// 缺陷清单条目（例如 `floating_part`）。
final class CreativeDefectFinding {
  const CreativeDefectFinding({
    required this.id,
    required this.present,
    this.evidence = '',
    this.extra = const <String, Object?>{},
  });

  final String id;
  final bool present;
  final String evidence;
  final Map<String, Object?> extra;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'present': present,
    if (evidence.isNotEmpty) 'evidence': evidence,
    ...extra,
  };
}

/// 盲评结果。
final class CreativeJudgment {
  const CreativeJudgment({
    required this.criteria,
    required this.summary,
    this.strengths = const <String>[],
    this.issues = const <CreativeJudgmentIssue>[],
    this.improvementPlan = const <CreativeImprovementItem>[],
    this.acceptance = const <CreativeAcceptanceVerdict>[],
    this.defects = const <CreativeDefectFinding>[],
    this.extra = const <String, Object?>{},
  });

  final Map<CreativeCriterion, CreativeCriterionScore> criteria;
  final String summary;
  final List<String> strengths;
  final List<CreativeJudgmentIssue> issues;
  final List<CreativeImprovementItem> improvementPlan;
  final List<CreativeAcceptanceVerdict> acceptance;
  final List<CreativeDefectFinding> defects;
  final Map<String, Object?> extra;

  static const Set<String> knownKeys = <String>{
    'criteria',
    'summary',
    'strengths',
    'issues',
    'improvement_plan',
    'acceptance',
    'defects',
  };

  static CreativeParseResult<CreativeJudgment> parse(Object? raw) {
    final CreativeValidation validation = CreativeValidation();
    final Map<String, Object?>? map = creativeJsonMap(raw);
    if (map == null) {
      validation.add('', 'judgment_not_object', 'judgment.json 必须是 JSON 对象');
      return CreativeParseResult<CreativeJudgment>(null, validation);
    }

    final Map<CreativeCriterion, CreativeCriterionScore> criteria =
        <CreativeCriterion, CreativeCriterionScore>{};
    final Map<String, Object?>? criteriaRaw = creativeJsonMap(map['criteria']);
    if (criteriaRaw == null) {
      validation.add(
        '/criteria',
        'judgment_criteria_missing',
        'criteria 必须是对象',
      );
    } else {
      for (final CreativeCriterion criterion in CreativeCriterion.values) {
        final String pointer = creativePointer('/criteria', criterion.wire);
        final Map<String, Object?>? entry = creativeJsonMap(
          criteriaRaw[criterion.wire],
        );
        if (entry == null) {
          validation.add(
            pointer,
            'judgment_criterion_missing',
            '缺少维度 ${criterion.wire}',
          );
          continue;
        }
        final double? score = creativeFiniteDouble(entry['score']);
        if (score == null || score < 0 || score > 1) {
          validation.add(
            '$pointer/score',
            'judgment_criterion_invalid',
            'score 必须是 0–1',
          );
        }
        final String? why = creativeNonEmptyString(entry['why']);
        if (why == null) {
          validation.add(
            '$pointer/why',
            'judgment_criterion_invalid',
            'why 不能为空（必须引用观察证据）',
          );
        }
        criteria[criterion] = CreativeCriterionScore(
          score: score ?? 0,
          why: why ?? '',
          extra: _collectExtras(entry, CreativeCriterionScore.knownKeys),
        );
      }
    }

    final String? summary = creativeNonEmptyString(map['summary']);
    if (summary == null) {
      validation.add('/summary', 'judgment_summary_missing', 'summary 不能为空');
    }
    final List<String> strengths = _parseStringList(
      map['strengths'],
      '/strengths',
      validation,
    );

    final List<CreativeJudgmentIssue> issues = <CreativeJudgmentIssue>[];
    final List<Object?>? issuesRaw = creativeJsonList(map['issues']);
    if (map['issues'] != null && issuesRaw == null) {
      validation.add('/issues', 'judgment_issues_invalid', 'issues 必须是数组');
    } else if (issuesRaw != null) {
      for (int i = 0; i < issuesRaw.length; i++) {
        final String pointer = creativeIndexPointer('/issues', i);
        final Map<String, Object?>? entry = creativeJsonMap(issuesRaw[i]);
        if (entry == null) {
          validation.add(pointer, 'judgment_issue_invalid', 'issue 必须是对象');
          continue;
        }
        final CreativeCriterion? criterion = creativeEnumByWire(
          CreativeCriterion.values,
          (CreativeCriterion value) => value.wire,
          entry['criterion'],
        );
        if (criterion == null) {
          validation.add(
            '$pointer/criterion',
            'judgment_issue_invalid',
            'criterion 不在枚举内',
          );
        }
        final String? tile = creativeNonEmptyString(entry['tile']);
        final String? evidence = creativeNonEmptyString(entry['evidence']);
        final String? fix = creativeNonEmptyString(entry['fix']);
        if (tile == null) {
          validation.add(
            '$pointer/tile',
            'judgment_issue_invalid',
            'issue 必须给 tile',
          );
        }
        if (evidence == null) {
          validation.add(
            '$pointer/evidence',
            'judgment_issue_invalid',
            'issue 必须给 evidence',
          );
        }
        if (fix == null) {
          validation.add(
            '$pointer/fix',
            'judgment_issue_invalid',
            'issue 必须给 fix',
          );
        }
        if (criterion != null) {
          issues.add(
            CreativeJudgmentIssue(
              criterion: criterion,
              tile: tile ?? '',
              evidence: evidence ?? '',
              fix: fix ?? '',
              extra: _collectExtras(entry, CreativeJudgmentIssue.knownKeys),
            ),
          );
        }
      }
    }

    final List<CreativeImprovementItem> plan = <CreativeImprovementItem>[];
    final List<Object?>? planRaw = creativeJsonList(map['improvement_plan']);
    if (map['improvement_plan'] != null && planRaw == null) {
      validation.add(
        '/improvement_plan',
        'judgment_improvement_invalid',
        'improvement_plan 必须是数组',
      );
    } else if (planRaw != null) {
      for (int i = 0; i < planRaw.length; i++) {
        final String pointer = creativeIndexPointer('/improvement_plan', i);
        final Map<String, Object?>? entry = creativeJsonMap(planRaw[i]);
        if (entry == null) {
          validation.add(pointer, 'judgment_improvement_invalid', '改进项必须是对象');
          continue;
        }
        final int? priority = creativeInt(entry['priority']);
        if (priority == null || priority < 1) {
          validation.add(
            '$pointer/priority',
            'judgment_improvement_invalid',
            'priority 必须是 ≥1 的整数',
          );
        }
        final String? target = creativeNonEmptyString(entry['target']);
        final String? action = creativeNonEmptyString(entry['action']);
        final String? evidence = creativeNonEmptyString(entry['evidence']);
        if (target == null) {
          validation.add(
            '$pointer/target',
            'judgment_improvement_invalid',
            'target 不能为空',
          );
        }
        if (action == null) {
          validation.add(
            '$pointer/action',
            'judgment_improvement_invalid',
            'action 不能为空',
          );
        }
        if (evidence == null) {
          validation.add(
            '$pointer/evidence',
            'judgment_improvement_invalid',
            'evidence 不能为空',
          );
        }
        if (priority != null) {
          plan.add(
            CreativeImprovementItem(
              priority: priority,
              target: target ?? '',
              action: action ?? '',
              evidence: evidence ?? '',
              extra: _collectExtras(entry, const <String>{
                'priority',
                'target',
                'action',
                'evidence',
              }),
            ),
          );
        }
      }
    }

    final List<CreativeAcceptanceVerdict> acceptance =
        <CreativeAcceptanceVerdict>[];
    final List<Object?>? acceptanceRaw = creativeJsonList(map['acceptance']);
    if (map['acceptance'] != null && acceptanceRaw == null) {
      validation.add(
        '/acceptance',
        'judgment_acceptance_invalid',
        'acceptance 必须是数组',
      );
    } else if (acceptanceRaw != null) {
      for (int i = 0; i < acceptanceRaw.length; i++) {
        final String pointer = creativeIndexPointer('/acceptance', i);
        final Map<String, Object?>? entry = creativeJsonMap(acceptanceRaw[i]);
        if (entry == null) {
          validation.add(
            pointer,
            'judgment_acceptance_invalid',
            'acceptance 项必须是对象',
          );
          continue;
        }
        final String? item = creativeNonEmptyString(entry['item']);
        final Object? passRaw = entry['pass'];
        if (item == null) {
          validation.add(
            '$pointer/item',
            'judgment_acceptance_invalid',
            'item 不能为空',
          );
        }
        if (passRaw is! bool) {
          validation.add(
            '$pointer/pass',
            'judgment_acceptance_invalid',
            'pass 必须是布尔',
          );
        }
        acceptance.add(
          CreativeAcceptanceVerdict(
            item: item ?? '',
            pass: passRaw is bool ? passRaw : false,
            evidence: creativeNonEmptyString(entry['evidence']) ?? '',
            extra: _collectExtras(entry, const <String>{
              'item',
              'pass',
              'evidence',
            }),
          ),
        );
      }
    }

    final List<CreativeDefectFinding> defects = <CreativeDefectFinding>[];
    final List<Object?>? defectsRaw = creativeJsonList(map['defects']);
    if (map['defects'] != null && defectsRaw == null) {
      validation.add('/defects', 'judgment_defects_invalid', 'defects 必须是数组');
    } else if (defectsRaw != null) {
      for (int i = 0; i < defectsRaw.length; i++) {
        final String pointer = creativeIndexPointer('/defects', i);
        final Map<String, Object?>? entry = creativeJsonMap(defectsRaw[i]);
        if (entry == null) {
          validation.add(pointer, 'judgment_defect_invalid', 'defect 项必须是对象');
          continue;
        }
        final String? id = creativeNonEmptyString(entry['id']);
        if (id == null || !creativeIsSnakeCase(id)) {
          validation.add(
            '$pointer/id',
            'judgment_defect_invalid',
            'defect.id 必须是 ASCII snake_case',
          );
        }
        final Object? presentRaw = entry['present'];
        if (presentRaw is! bool) {
          validation.add(
            '$pointer/present',
            'judgment_defect_invalid',
            'present 必须是布尔',
          );
        }
        defects.add(
          CreativeDefectFinding(
            id: id ?? '',
            present: presentRaw is bool ? presentRaw : false,
            evidence: creativeNonEmptyString(entry['evidence']) ?? '',
            extra: _collectExtras(entry, const <String>{
              'id',
              'present',
              'evidence',
            }),
          ),
        );
      }
    }

    final bool validCriteria =
        criteria.length == CreativeCriterion.values.length;
    if (summary == null || !validCriteria) {
      return CreativeParseResult<CreativeJudgment>(null, validation);
    }
    return CreativeParseResult<CreativeJudgment>(
      CreativeJudgment(
        criteria: criteria,
        summary: summary,
        strengths: strengths,
        issues: issues,
        improvementPlan: plan,
        acceptance: acceptance,
        defects: defects,
        extra: _collectExtras(map, CreativeJudgment.knownKeys),
      ),
      validation,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'criteria': <String, Object?>{
      for (final MapEntry<CreativeCriterion, CreativeCriterionScore> entry
          in criteria.entries)
        entry.key.wire: entry.value.toJson(),
    },
    'summary': summary,
    'strengths': strengths,
    'issues': issues
        .map((CreativeJudgmentIssue issue) => issue.toJson())
        .toList(growable: false),
    'improvement_plan': improvementPlan
        .map((CreativeImprovementItem item) => item.toJson())
        .toList(growable: false),
    'acceptance': acceptance
        .map((CreativeAcceptanceVerdict item) => item.toJson())
        .toList(growable: false),
    'defects': defects
        .map((CreativeDefectFinding item) => item.toJson())
        .toList(growable: false),
    ...extra,
  };
}

List<String> _parseStringList(
  Object? raw,
  String pointer,
  CreativeValidation validation,
) {
  if (raw == null) return const <String>[];
  final List<Object?>? list = creativeJsonList(raw);
  if (list == null) {
    validation.add(pointer, 'judgment_list_invalid', '必须是字符串数组');
    return const <String>[];
  }
  final List<String> out = <String>[];
  for (int i = 0; i < list.length; i++) {
    final String? value = creativeNonEmptyString(list[i]);
    if (value == null) {
      validation.add(
        creativeIndexPointer(pointer, i),
        'judgment_list_item_invalid',
        '数组项必须是非空字符串',
      );
      continue;
    }
    out.add(value);
  }
  return out;
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
