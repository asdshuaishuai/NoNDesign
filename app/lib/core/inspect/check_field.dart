// 通用「检查器」属性表：把"选中元素 → 可编辑属性"统一成一份声明式模型。
//
// 用户裁决 2026-11-27：所有工作台右侧都有「助手 + 检查」，检查=人工修改细节，
// 且**按各工作台自己的元素与属性适配**。为避免每个工作台各写一套表单，这里定义：
//
//   * [CheckField] / [CheckSheet]：只描述"有哪些字段、什么类型、当前值"；
//   * [WorkbenchCheckController]：工作台实现它——把选中元素映射成 [CheckSheet]，
//     并把 [update] 写回自己的项目事实源（保存/刷新由工作台负责）；
//   * `widgets/check_panel.dart`：唯一的渲染器（分组、行内编辑、空态）。
//
// 纪律：本层**不持有项目事实源**，也不做视觉语义解释；数值/颜色/开关的校验
// 只在"能否写回"范围内做边界检查，真正的契约校验仍由各工作台（引擎/校验器）负责。
library;

import 'package:material_ui/material_ui.dart';

/// 字段编辑类型。
enum CheckFieldKind {
  /// 单行文本（标题/名称/表达式）。
  text,

  /// 数值（带单位与可选范围）。
  number,

  /// 颜色（`#RRGGBB`，渲染成色块 + 十六进制值）。
  color,

  /// 开关（可见性/静音等）。
  toggle,

  /// 枚举（下拉，选项由工作台给）。
  select,

  /// 只读展示（计算值/校验结果，不可编辑）。
  readOnly,
}

/// 一个可编辑字段。
@immutable
final class CheckField {
  const CheckField({
    required this.key,
    required this.label,
    required this.kind,
    required this.value,
    this.options = const <String>[],
    this.unit = '',
    this.min,
    this.max,
    this.hint = '',
    this.enabled = true,
  });

  /// 稳定键（工作台 `update` 时用它定位属性；测试也用它）。
  final String key;

  /// 人话标签。
  final String label;

  final CheckFieldKind kind;

  /// 当前值：text/readOnly/select(String)、number(num)、color(int ARGB)、toggle(bool)。
  final Object? value;

  /// [CheckFieldKind.select] 的选项（人类可读，写回时工作台自行映射）。
  final List<String> options;

  /// 数值单位（如 `m`、`°`、`%`）。
  final String unit;

  /// 数值范围（写回前用于夹取，避免非法值进项目）。
  final num? min;
  final num? max;

  /// 该字段的补充说明（只读字段用来解释来源）。
  final String hint;

  /// 是否允许编辑（只读/未满足前提时为 false）。
  final bool enabled;

  CheckField copyWith({Object? value, bool? enabled}) => CheckField(
    key: key,
    label: label,
    kind: kind,
    value: value ?? this.value,
    options: options,
    unit: unit,
    min: min,
    max: max,
    hint: hint,
    enabled: enabled ?? this.enabled,
  );
}

/// 一份检查表：一次选中元素的所有属性。
@immutable
final class CheckSheet {
  const CheckSheet({
    required this.title,
    required this.fields,
    this.subtitle = '',
    this.kindLabel = '',
  });

  /// 选中元素的人话标题（如「节点「柱子」」）。
  final String title;

  /// 元素类型/来源说明（如「网格节点 · 来自 scene.json」）。
  final String subtitle;

  /// 类型徽标（如「节点」/「镜头」/「音符」），用于分组视觉。
  final String kindLabel;

  final List<CheckField> fields;

  CheckSheet copyWith({List<CheckField>? fields}) =>
      CheckSheet(title: title, subtitle: subtitle, kindLabel: kindLabel, fields: fields ?? this.fields);

  /// 按 key 找字段（渲染/测试用）。
  CheckField? field(String key) {
    for (final CheckField f in fields) {
      if (f.key == key) return f;
    }
    return null;
  }
}

/// 工作台实现的检查控制器：选中什么 → 给出 [sheet]；用户改了什么 → [update] 写回。
///
/// 生命周期由工作台负责：挂载时 `store.setCheckController(this)`，卸载时清空。
class WorkbenchCheckController extends ChangeNotifier {
  /// 当前选中元素的属性表；null = 没有选中（检查器显示"选中后可调整"的提示）。
  CheckSheet? get sheet => null;

  /// 写回一个字段。实现方负责：夹取范围、落盘、刷新、失败显性提示。
  ///
  /// 返回 false 表示拒绝写入（非法值/只读/未就绪），调用方保持旧值。
  Future<bool> update(String key, Object? value) async => false;

  /// 元素选择变化后让面板重取 [sheet]。
  void notifySelectionChanged() => notifyListeners();
}
