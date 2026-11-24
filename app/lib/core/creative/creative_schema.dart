/// 创意工作台（creative-workbench）契约层：schema 常量、枚举、校验结果与
/// JSON 指针工具。
///
/// 这一层只依赖 Dart 核心库（不碰 Flutter / IO / 引擎），所有工作台、智能体
/// 工具层与测试共用同一份契约，避免每条创作线各写一套 schema。契约来源见
/// `docs/skills/creative-workbench/references/schemas.md` 与
/// `docs/skills/creative-workbench/SKILL.md`。
library;

/// `spec.json` 的 schema 标识（精确匹配，不做前缀推断）。
const String creativeSpecSchema = 'nan.creative.spec/1';

/// `plan.json` 的 schema 标识。
const String creativePlanSchema = 'nan.creative.plan/1';

/// `artifacts/gates.json` 的 schema 标识。
const String creativeGatesSchema = 'nan.creative.gates/1';

/// `judge/rNN/score.json` 的 schema 标识。
const String creativeScoreSchema = 'nan.creative.score/1';

/// 视频线唯一帧率（v1 不混用 24/60）。
const int creativeVideoFps = 30;

/// 视频宽高比白名单。
const List<String> creativeVideoAspects = <String>[
  '16:9',
  '9:16',
  '1:1',
  '4:5',
];

/// 产品导出闸门（成片导出仍屏蔽，见 plan-creative-workbench §5 与
/// video-pipeline §8）。`spec.output.export == "mp4"` 在校验期直接拒绝。
const bool creativeMp4ExportEnabled = false;

/// 工作区目录与文件名（所有创作线共用同一布局）。
abstract final class CreativeWorkspaceLayout {
  const CreativeWorkspaceLayout._();

  /// 请求：kind/track/prompt/must/dims/references/style/output。
  static const String specFile = 'spec.json';

  /// 计划：精确数字 + acceptance。
  static const String planFile = 'plan.json';

  /// 可执行源；`code` 模式是唯一事实源，`scene` 模式由 `scene.json` 编译。
  static const String srcDir = 'src';

  /// 工具输出（GLB/渲染/gates.json/measurement.json），智能体只读。
  static const String artifactsDir = 'artifacts';

  /// 盲评轮次目录根（每轮 `rNN`）。
  static const String judgeDir = 'judge';

  /// `scene` 模式的事实源 / `code` 模式的派生投影。
  static const String sceneFile = 'scene.json';

  /// 3D 场景轨道编译后的资产目录。
  static const String publicDir = 'public';

  /// 视频风格包（项目级）。
  static const String stylePackFile = 'style-pack.json';

  static String roundDir(String label) => '$judgeDir/$label';
  static String roundBrief(String label) => '${roundDir(label)}/brief.md';
  static String roundJudgment(String label) =>
      '${roundDir(label)}/judgment.json';
  static String roundScore(String label) => '${roundDir(label)}/score.json';
}

/// 创作产物类型。
enum CreativeKind {
  threeD('3d'),
  video('video'),
  interactive('interactive'),
  design('design');

  const CreativeKind(this.wire);

  /// JSON 里的稳定字符串值。
  final String wire;

  bool get isCreative => this != CreativeKind.design;
}

/// 创作轨道。3D 与视频各有自己的轨道集合；`track.kind` 必须与 `kind` 一致。
enum CreativeTrack {
  staticObject('static_object', CreativeKind.threeD),
  scene('scene', CreativeKind.threeD),
  graphics('graphics', CreativeKind.threeD),
  sillySkit('silly_skit', CreativeKind.video),
  lineToon('line_toon', CreativeKind.video),
  inkLine('ink_line', CreativeKind.video);

  const CreativeTrack(this.wire, this.kind);

  final String wire;
  final CreativeKind kind;

  bool get isThreeD => kind == CreativeKind.threeD;
  bool get isVideo => kind == CreativeKind.video;
}

/// 风格包。`default` 是中性动效，三种视频风格见 video-pipeline §5。
enum CreativeStylePack {
  neutral('default'),
  sillySkit('silly_skit'),
  lineToon('line_toon'),
  inkLine('ink_line');

  const CreativeStylePack(this.wire);

  final String wire;
}

/// `spec.output.export` 的三态。
enum CreativeExportFormat {
  none('none'),
  mp4('mp4'),
  glb('glb');

  const CreativeExportFormat(this.wire);

  final String wire;
}

/// 参考图/参考片在请求里的角色。
enum CreativeReferenceRole {
  silhouette('silhouette'),
  palette('palette'),
  motion('motion'),
  style('style');

  const CreativeReferenceRole(this.wire);

  final String wire;
}

/// 盲评 rubric 的六个维度（权重按轨道取，见 judging.md）。
enum CreativeCriterion {
  idea('idea'),
  composition('composition'),
  craft('craft'),
  motion('motion'),
  legibility('legibility'),
  constraintFit('constraint_fit');

  const CreativeCriterion(this.wire);

  final String wire;
}

/// 门/报告的四档裁决。
enum CreativeVerdict {
  pass('PASS'),
  warn('WARN'),
  fail('FAIL'),
  error('ERROR');

  const CreativeVerdict(this.wire);

  final String wire;

  bool get isBlocking =>
      this == CreativeVerdict.fail || this == CreativeVerdict.error;
}

/// 一条契约校验问题。[pointer] 是相对文档根的 JSON Pointer（`""` 表示根）。
final class CreativeIssue {
  const CreativeIssue(
    this.pointer,
    this.code,
    this.message, {
    this.blocking = true,
  });

  /// JSON Pointer；用于把错误定位回字段。
  final String pointer;

  /// 稳定机器码（测试/日志/工具信封使用，不直接上屏）。
  final String code;

  /// 原始诊断（只进折叠的技术详情）。
  final String message;

  /// `false` 表示 WARN 级问题：不阻止解析，只记录。
  final bool blocking;

  Map<String, Object?> toJson() => <String, Object?>{
    'pointer': pointer,
    'code': code,
    'message': message,
    'blocking': blocking,
  };

  @override
  String toString() => '$code@$pointer: $message';
}

/// 校验结果收集器。所有 `parse` 入口都返回它，而不是抛异常——
/// 这样智能体工具层可以一次把全部问题带 fix hint 回给模型。
final class CreativeValidation {
  CreativeValidation();

  CreativeValidation.of(Iterable<CreativeIssue> issues) {
    this.issues.addAll(issues);
  }

  final List<CreativeIssue> issues = <CreativeIssue>[];

  /// 没有任何问题（含 WARN）。
  bool get ok => issues.isEmpty;

  /// 没有阻断项；WARN 不算失败。
  bool get isValid => !issues.any((CreativeIssue issue) => issue.blocking);

  bool get hasBlocking => !isValid;

  void add(
    String pointer,
    String code,
    String message, {
    bool blocking = true,
  }) {
    issues.add(CreativeIssue(pointer, code, message, blocking: blocking));
  }

  void warn(String pointer, String code, String message) {
    add(pointer, code, message, blocking: false);
  }

  void addIssue(CreativeIssue issue) => issues.add(issue);

  List<Map<String, Object?>> toJsonList() => issues
      .map((CreativeIssue issue) => issue.toJson())
      .toList(growable: false);

  @override
  String toString() => issues.join('\n');
}

/// 解析结果：`value` 在核心字段合法时非空；即使 `value` 为空，
/// [validation] 也会列出全部问题（不 fail-fast）。
final class CreativeParseResult<T> {
  const CreativeParseResult(this.value, this.validation);

  final T? value;
  final CreativeValidation validation;

  bool get ok => validation.isValid && value != null;
}

/// 按 wire 字符串查枚举；非法或缺省返回 null，由调用方补问题。
T? creativeEnumByWire<T>(
  Iterable<T> values,
  String Function(T) wireOf,
  Object? raw,
) {
  if (raw is! String) return null;
  for (final T value in values) {
    if (wireOf(value) == raw) return value;
  }
  return null;
}

/// 把 JSON 对象转成 `Map<String, Object?>`；非对象返回 null。
Map<String, Object?>? creativeJsonMap(Object? value) {
  if (value is! Map) return null;
  final Map<String, Object?> out = <String, Object?>{};
  for (final MapEntry<Object?, Object?> entry in value.entries) {
    final Object? key = entry.key;
    if (key is! String) return null;
    out[key] = entry.value;
  }
  return out;
}

/// JSON 列表；非列表返回 null。
List<Object?>? creativeJsonList(Object? value) =>
    value is List ? value.cast<Object?>() : null;

/// 有限 double；非数字 / NaN / Infinity 返回 null。
double? creativeFiniteDouble(Object? value) {
  if (value is num && value.isFinite) return value.toDouble();
  return null;
}

/// 整数；整值 double 也接受（JSON 数字反序列化在不同路径可能得到 double）。
int? creativeInt(Object? value) {
  if (value is int) return value;
  if (value is double && value.isFinite && value == value.roundToDouble()) {
    return value.toInt();
  }
  return null;
}

/// 非空字符串（trim 后）；否则 null。
String? creativeNonEmptyString(Object? value) {
  if (value is! String) return null;
  final String trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// 可选布尔；缺省时给 [fallback]。
bool creativeBoolOr(Object? value, {required bool fallback}) =>
    value is bool ? value : fallback;

/// 把父指针和字段名拼成 JSON Pointer，并转义 `~` 与 `/`。
String creativePointer(String parent, String key) {
  final String escaped = key.replaceAll('~', '~0').replaceAll('/', '~1');
  return parent.isEmpty ? '/$escaped' : '$parent/$escaped';
}

/// 数组元素指针。
String creativeIndexPointer(String parent, int index) =>
    parent.isEmpty ? '/$index' : '$parent/$index';

final RegExp _hexColor = RegExp(r'^#[0-9a-fA-F]{6}$');
final RegExp _snakeCase = RegExp(r'^[a-z][a-z0-9_]*$');
final RegExp _projectName = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$');
final RegExp _roundLabel = RegExp(r'^r(\d{2,})$');

/// 是否为 `#rrggbb`。
bool creativeIsHexColor(Object? value) =>
    value is String && _hexColor.hasMatch(value);

/// 是否 ASCII snake_case（parts/events/cues 等稳定 id 的统一规范）。
bool creativeIsSnakeCase(Object? value) =>
    value is String && _snakeCase.hasMatch(value);

/// 是否可用的项目目录名（与 3D/视频存储纪律一致：ASCII 字母数字 `-` `_`）。
bool creativeIsSafeProjectName(Object? value) =>
    value is String && _projectName.hasMatch(value);

/// 是否是安全的项目内相对路径：非空、无盘符/协议、无 `.`/`..` 段、无 NUL。
bool creativeIsSafeRelativePath(Object? value) {
  if (value is! String) return false;
  if (value.isEmpty || value.length > 512) return false;
  if (value.startsWith('/') || value.startsWith(r'\')) return false;
  if (value.contains(':') || value.contains('\u0000')) return false;
  final List<String> segments = value.split(RegExp(r'[/\\]'));
  for (final String segment in segments) {
    if (segment.isEmpty || segment == '.' || segment == '..') return false;
  }
  return true;
}

/// 轮次 id：`r00`、`r01`…，至少两位数字（与 judge/rNN 目录一致）。
final class CreativeRoundId implements Comparable<CreativeRoundId> {
  const CreativeRoundId(this.number);

  final int number;

  String get label => 'r${number.toString().padLeft(2, '0')}';

  static CreativeRoundId? parse(Object? raw) {
    if (raw is! String) return null;
    final RegExpMatch? match = _roundLabel.firstMatch(raw);
    if (match == null) return null;
    return CreativeRoundId(int.parse(match.group(1)!));
  }

  @override
  int compareTo(CreativeRoundId other) => number.compareTo(other.number);

  @override
  bool operator ==(Object other) =>
      other is CreativeRoundId && other.number == number;

  @override
  int get hashCode => number.hashCode;

  @override
  String toString() => label;
}
