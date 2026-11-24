/// 3D 线的 plan 校验与旧规范迁移草案（纯 Dart，无 IO）。
///
/// 契约见 `docs/three-contract.md` §4 与
/// `docs/skills/creative-workbench/references/3d-pipeline.md` §4：
/// plan 必须先过 schema + 数字/验收校验，才允许写 `src/`。本文件只做
/// CreativePlan 之上的 3D 专属规则，不重复通用 schema 校验。
library;

import '../creative/creative_plan.dart';
import '../creative/creative_schema.dart';

/// 3D plan 校验结果。
final class ThreePlanValidation {
  const ThreePlanValidation({required this.parsed, required this.issues});

  final CreativeParseResult<CreativePlan> parsed;

  /// 3D 专属追加问题（含迁移草案的 WARN）。
  final List<CreativeIssue> issues;

  bool get ok =>
      parsed.value is CreativePlan3d &&
      !issues.any((issue) => issue.blocking) &&
      parsed.validation.isValid;

  CreativePlan3d? get plan =>
      parsed.value is CreativePlan3d ? parsed.value! as CreativePlan3d : null;

  List<CreativeIssue> get allIssues => <CreativeIssue>[
    ...parsed.validation.issues,
    ...issues,
  ];

  List<String> get fixHints => allIssues
      .where((issue) => issue.blocking)
      .map((issue) => '${issue.pointer}: ${issue.message}')
      .toList(growable: false);
}

/// 校验 3D plan（`plan.json` 的原始 JSON）。
ThreePlanValidation validateThreePlan(Object? raw) {
  final CreativeParseResult<CreativePlan> parsed = CreativePlan.parse(raw);
  final List<CreativeIssue> extra = <CreativeIssue>[];
  final CreativePlan3d? plan = parsed.value is CreativePlan3d
      ? parsed.value! as CreativePlan3d
      : null;
  if (plan == null) {
    return ThreePlanValidation(parsed: parsed, issues: extra);
  }

  // 迁移草案：dims 来自 legacy size_scale，必须人工/agent 补精确数字。
  if (plan.extra['migration_needs_review'] == true) {
    extra.add(
      const CreativeIssue(
        '',
        'three_plan_migration_draft',
        '这是从旧规范迁移的草案：dims 来自 size_scale，先补精确尺寸再交付',
        blocking: false,
      ),
    );
  }

  // 验收项必须“二分可观测”：至少一项带数字或度量符号（≤/< /mm/cm/m/° 等）。
  final bool observable = plan.acceptance.any(
    (item) => RegExp(r'[0-9０-９]|[≤≥<>=]|mm|cm|米|度|°').hasMatch(item),
  );
  if (!observable) {
    extra.add(
      const CreativeIssue(
        '/acceptance',
        'three_plan_acceptance_not_observable',
        'acceptance 里没有可测量的数字/单位；写不出可验证项就不能当计划',
        blocking: false,
      ),
    );
  }

  switch (plan.track) {
    case CreativeTrack.staticObject:
      if (plan.parts.isEmpty) {
        extra.add(
          const CreativeIssue(
            '/parts',
            'three_plan_parts_empty',
            'static_object 至少需要一个 part（精确尺寸/材质/父级）',
          ),
        );
      }
      if (plan.cameras.isEmpty) {
        extra.add(
          const CreativeIssue(
            '/cameras',
            'three_plan_camera_missing',
            '对象计划建议给作者相机（盲评 14 视角需要），缺省不阻断但会降证据质量',
            blocking: false,
          ),
        );
      }
    case CreativeTrack.scene:
      if (plan.zones.isEmpty) {
        extra.add(
          const CreativeIssue(
            '/zones',
            'three_plan_zones_missing',
            'scene 计划必须给 zones（分区/边界）',
          ),
        );
      }
      if (plan.cameras.isEmpty) {
        extra.add(
          const CreativeIssue(
            '/cameras',
            'three_plan_camera_missing',
            'scene 计划必须给作者相机（盲评 t=0/1.5s + orbit 需要）',
          ),
        );
      }
      if (plan.placements.isEmpty) {
        extra.add(
          const CreativeIssue(
            '/placements',
            'three_plan_placements_missing',
            'scene 计划没有 placements：先说明放了什么、放在哪个 zone',
            blocking: false,
          ),
        );
      }
    case CreativeTrack.graphics:
      // 图形轨 v1 用 common + 帧验收；具体字段待 R1 冻结。
      break;
    default:
      break;
  }
  return ThreePlanValidation(parsed: parsed, issues: extra);
}

/// 旧 `three-spec.json` → 新 `plan.json` 草案（deterministic，不编造精确尺寸）。
///
/// 旧规范只有 `components[{id,what,size_scale}]` 与 `acceptance`；没有米制
/// 尺寸/包围盒。本函数把 `size_scale` 转成相对立方体边长（1.0 = 1m），并标
/// `migration_needs_review`，让 plan 校验提示「先补精确尺寸」——迁移草案可以
/// 预览/继续工作，但不能被当成精确 plan 直接过门。
Map<String, Object?> draftPlanFromLegacySpec(
  Map<String, dynamic> legacySpec, {
  CreativeTrack track = CreativeTrack.staticObject,
}) {
  final List<Object?> components = legacySpec['components'] is List
      ? List<Object?>.from(legacySpec['components'] as List)
      : const <Object?>[];
  final List<Object?> materials = legacySpec['materials'] is List
      ? List<Object?>.from(legacySpec['materials'] as List)
      : const <Object?>[];
  final String fallbackMaterial = materials.isNotEmpty && materials.first is Map
      ? ((materials.first as Map)['id'] ?? 'material').toString()
      : 'default';
  final List<Object?> parts = <Object?>[];
  final Set<String> used = <String>{};
  for (int i = 0; i < components.length; i++) {
    final Object? item = components[i];
    if (item is! Map) continue;
    final String rawId = (item['id'] ?? 'part_$i').toString();
    String id = rawId
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_]+'), '_')
        .replaceAll(RegExp(r'_+'), '_');
    if (id.isEmpty || !RegExp(r'^[a-z]').hasMatch(id)) id = 'part_$i';
    String unique = id;
    int suffix = 2;
    while (!used.add(unique)) {
      unique = '${id}_$suffix';
      suffix++;
    }
    final double scale = switch (item['size_scale']) {
      final num value when value.isFinite && value > 0 => value.toDouble(),
      _ => 1.0,
    };
    final String material = (item['material'] ?? fallbackMaterial).toString();
    parts.add(<String, Object?>{
      'id': unique,
      'dims_m': <double>[scale, scale, scale],
      'material': material.isEmpty ? fallbackMaterial : material,
      'parent': null,
      if (item['what'] != null) 'legacy_what': item['what'],
    });
  }
  final List<Object?> acceptance = legacySpec['acceptance'] is List
      ? List<Object?>.from(legacySpec['acceptance'] as List)
      : const <Object?>[];
  final String summary =
      (legacySpec['summary'] ?? legacySpec['title'] ?? '迁移自旧规范').toString();
  return <String, Object?>{
    'schema': creativePlanSchema,
    'kind': '3d',
    'track': track.wire,
    'language': track == CreativeTrack.scene ? 'scene_threejs' : 'threejs',
    'summary': summary.isEmpty ? '迁移自旧规范' : summary,
    'acceptance': acceptance
        .map((item) => item.toString())
        .where((item) => item.trim().isNotEmpty)
        .toList(growable: false),
    'parts': parts,
    'risks': <String>['迁移草案：dims 来自旧 size_scale，需补精确尺寸/包围盒'],
    'migration_needs_review': true,
    'migrated_from': 'three-spec.json',
  };
}
