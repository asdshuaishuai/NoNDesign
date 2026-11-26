/// 工作台文档生成器：把项目事实源（规范 + 进度/元数据）确定性拼成 markdown，
/// 落成项目目录里的 `docs.md`——四个工作台「文档」栏目的真实内容。
///
/// 纪律：
/// * **确定性**：同一输入两次生成**字节相同**。不出现时间戳、随机数、
///   平台相关的数字格式；只按显式 key 读取（从不遍历 `map.entries` 拼字符串，
///   因为 map 的迭代顺序会让输出随输入构造方式漂移）。
/// * **不调模型**：纯字符串组装。文档会告诉人「改动请落在规范/源码」，
///   但生成器自己不请求任何服务、不写任何事实源。
/// * **人话**：生成物是用户可见内容（四栏目「文档」），遵守
///   `docs/copy-glossary.md`：不出现实现名、内部代号、错误码、文件格式名。
/// * **原子写**：`writeWorkbenchDoc` 先写同目录临时文件并 flush，再改名替换
///   `docs.md`；默认不覆盖已有文档（返回 null），失败不破坏既有文件。
///
/// 本层纯 Dart（`dart:io` 只出现在写/读边界），无 Flutter、无引擎、无 WebView。
///
/// `summary` 是调用方按工作台事实源组装的人话摘要。约定只读下列 key（缺省按
/// 「未记录」渲染，不抛）：
///
/// * `kind == 'three'`：`title`（标题）、`current`（当前层 id）、
///   `components`（组件清单：字符串或 `{name, what, id}` 对象）、
///   `acceptance`（验收项）、`passes`（进度：`{id, status, label, name}` 对象，
///   `status == 'verified'` 记已通过，`'blocked'` 记已阻塞）。
/// * `kind == 'video'`：`title`、`totalSeconds`（或 `seconds`，缺省时按镜头
///   时长求和）、`fps`（缺省 30）、`shots`（`{duration, text}`）。
/// * `kind == 'video3d'`：`title`、`nodes`（或 `nodeCount`）、`totalFrames`
///   （或 `frames`）、`shots`（`{duration, camera}`；camera 为相机 id 字符串或
///   `{id, move: {from, to}}` 对象）。
/// * `kind == 'music'`：`title`、`tempo`、`timeSig`（`[分子, 分母]` 或
///   `"4/4"`）、`keySig`、`tracks`（`{name, instrument, volume, measures}`，
///   `measures` 为数组时取长度）、`verified`（校验是否通过）、
///   `checks` / `issues`（问题数组或问题数）。
library;

import 'dart:io';

/// 自动生成文档的固定首行（工作台文档栏目读到这里就知道这是生成物）。
const String workbenchDocNotice = '本文档由项目事实源自动生成，改动请落在「规范」或「源码」栏目。';

/// 生成文档的落盘文件名（四栏目「文档」栏目优先读它）。
const String workbenchDocFileName = 'docs.md';

/// 生成物缺失时的兜底文件名（[readWorkbenchDoc] 的第二个候选）。
const String workbenchDocFallbackFileName = 'brief.md';

/// 3D 六层推进的用户可见层名。
///
/// 与 `three_service.dart` 的 `threePasses` / `threePassLabel` 同一套文案；
/// 本文件不 import 它（文档生成器保持纯 Dart、轻依赖），一致性由
/// `test/workbench_docs_test.dart` 的锚定用例守住（改了那边这里必须同步）。
const Map<String, String> _threePassLabels = <String, String>{
  'blockout': '占位',
  'structure': '结构',
  'form': '造型',
  'material': '材质',
  'lighting': '灯光',
  'interaction': '交互',
  'done': '完成',
};

/// 音乐契约允许的乐器值 → 用户可见中文名。
///
/// 与 `music_score.dart` 的 `musicInstruments` 一一对应；新增乐器时测试会
/// 失败，提醒同步这张表。
const Map<String, String> _instrumentLabels = <String, String>{
  'piano': '钢琴',
  'strings': '弦乐',
  'bass': '贝斯',
  'bell': '铃音',
  'organ': '风琴',
  'pluck': '拨弦',
  'drums': '鼓',
};

// ---------------------------------------------------------------------------
// 生成：确定性 markdown
// ---------------------------------------------------------------------------

/// 按 [kind] 生成一份工作台项目文档（确定性：同输入 → 同输出字节）。
///
/// - `three`：标题 / 组件清单 / 验收项 / 进度（已通过层数 + 层名）；
/// - `video`：标题 / 总时长 / 帧率 / 镜头表（序号 · 时长 · 文本）；
/// - `video3d`：标题 / 节点数 / 镜头表（序号 · 时长 · 相机）/ 总帧数；
/// - `music`：标题 / 速度 · 拍号 · 调号 / 轨道表（名称 · 乐器 · 音量 ·
///   小节数）/ 校验状态；
/// - 其它 kind：通用最小文档（同样以固定首行开头，不抛异常）。
///
/// 标题优先级：显式 [title] → `summary['title']` → 项目名 [name]。
String buildWorkbenchDoc({
  required String kind,
  required String name,
  String title = '',
  Map<String, Object?> summary = const <String, Object?>{},
}) {
  final String docTitle = _resolveTitle(
    title: title,
    summary: summary,
    name: name,
  );
  final StringBuffer out = StringBuffer()
    ..write(workbenchDocNotice)
    ..write('\n\n# ')
    ..write(docTitle)
    ..write('\n');

  if (kind == 'three') {
    _writeThreeDoc(out, summary);
  } else if (kind == 'video') {
    _writeVideoDoc(out, summary);
  } else if (kind == 'video3d') {
    _writeVideo3dDoc(out, summary);
  } else if (kind == 'music') {
    _writeMusicDoc(out, summary);
  } else {
    _writeGenericDoc(out);
  }
  return out.toString();
}

/// 3D 文档：概览（组件/验收项/当前层）+ 组件清单 + 验收项 + 进度。
void _writeThreeDoc(StringBuffer out, Map<String, Object?> summary) {
  final List<Object?> components = _listAt(summary['components']);
  final List<Object?> acceptance = _listAt(summary['acceptance']);
  final List<Object?> passes = _listAt(summary['passes']);
  final String? current = _text(summary['current']);

  _writeOverview(out, <String>[
    '类型：3D 场景',
    '组件数：${components.length} 个',
    '验收项数：${acceptance.length} 条',
    if (current != null) '当前层：${_threePassName(current)}',
  ]);

  out.write('\n## 组件清单\n');
  if (components.isEmpty) {
    out.write('- 暂无组件\n');
  } else {
    for (int i = 0; i < components.length; i++) {
      out.write(
        '${i + 1}. ${_singleLine(_componentText(components[i]) ?? '（未命名组件）')}\n',
      );
    }
  }

  out.write('\n## 验收项\n');
  if (acceptance.isEmpty) {
    out.write('- 暂无验收项\n');
  } else {
    for (final Object? item in acceptance) {
      out.write('- ${_singleLine(_acceptanceText(item) ?? '（未填写验收项）')}\n');
    }
  }

  out.write('\n## 进度\n');
  _writeThreeProgress(out, passes);
}

/// 进度段：已通过层数/层名 + 未通过 + 已阻塞（全部按显式 key 读取）。
void _writeThreeProgress(StringBuffer out, List<Object?> passes) {
  if (passes.isEmpty) {
    out.write('- 暂无进度记录\n');
    return;
  }
  int passedCount = 0;
  final List<String> passedNames = <String>[];
  final List<String> pendingNames = <String>[];
  final List<String> blockedNames = <String>[];
  for (final Object? pass in passes) {
    final ({String? name, String status}) info = _passInfo(pass);
    final String? name = info.name;
    if (info.status == 'verified') {
      passedCount++;
      if (name != null) passedNames.add(name);
    } else {
      if (name != null) pendingNames.add(name);
      if (info.status == 'blocked' && name != null) blockedNames.add(name);
    }
  }
  out.write('- 已通过 $passedCount / ${passes.length} 层\n');
  out.write('- 已通过层：${_joinNames(passedNames)}\n');
  out.write('- 未通过层：${_joinNames(pendingNames)}\n');
  if (blockedNames.isNotEmpty) {
    out.write('- 已阻塞层：${_joinNames(blockedNames)}\n');
  }
}

/// 视频文档：概览（总时长/帧率/镜头数）+ 镜头表（序号 · 时长 · 文本）。
void _writeVideoDoc(StringBuffer out, Map<String, Object?> summary) {
  final List<Object?> shots = _listAt(summary['shots']);
  final double? declared =
      _doubleValue(summary['totalSeconds']) ?? _doubleValue(summary['seconds']);
  final double? totalSeconds = declared ?? _sumShotDurations(shots);
  final int fps = _positiveInt(summary['fps']) ?? 30;

  _writeOverview(out, <String>[
    '类型：视频',
    '总时长：${_durationText(totalSeconds)}',
    '帧率：$fps 帧/秒',
    '镜头数：${shots.length} 个',
  ]);

  out.write('\n## 镜头表\n');
  if (shots.isEmpty) {
    out.write('- 暂无镜头\n');
    return;
  }
  out.write('| 序号 | 时长 | 文本 |\n');
  out.write('| --- | --- | --- |\n');
  for (int i = 0; i < shots.length; i++) {
    final Object? shot = shots[i];
    final Object? duration = shot is Map ? shot['duration'] : null;
    final String text = _shotText(shot);
    out.write(
      '| ${i + 1} | ${_durationText(_doubleValue(duration))} | '
      '${_tableCell(text)} |\n',
    );
  }
}

/// 3D 视频文档：概览（节点数/镜头数/总帧数）+ 镜头表（序号 · 时长 · 相机）。
void _writeVideo3dDoc(StringBuffer out, Map<String, Object?> summary) {
  final List<Object?> shots = _listAt(summary['shots']);
  final int? nodes =
      _intValue(summary['nodes']) ?? _intValue(summary['nodeCount']);
  final int? totalFrames =
      _intValue(summary['totalFrames']) ?? _intValue(summary['frames']);

  _writeOverview(out, <String>[
    '类型：3D 视频',
    '节点数：${_countText(nodes)}',
    '镜头数：${shots.length} 个',
    '总帧数：${_framesText(totalFrames)}',
  ]);

  out.write('\n## 镜头表\n');
  if (shots.isEmpty) {
    out.write('- 暂无镜头\n');
    return;
  }
  out.write('| 序号 | 时长 | 相机 |\n');
  out.write('| --- | --- | --- |\n');
  for (int i = 0; i < shots.length; i++) {
    final Object? shot = shots[i];
    final Object? duration = shot is Map ? shot['duration'] : null;
    final Object? camera = shot is Map ? shot['camera'] : null;
    out.write(
      '| ${i + 1} | ${_durationText(_doubleValue(duration))} | '
      '${_tableCell(_cameraText(camera))} |\n',
    );
  }
}

/// 音乐文档：概览（速度/拍号/调号/轨道数）+ 轨道表 + 校验状态。
void _writeMusicDoc(StringBuffer out, Map<String, Object?> summary) {
  final List<Object?> tracks = _listAt(summary['tracks']);
  final int? tempo = _intValue(summary['tempo']);

  _writeOverview(out, <String>[
    '类型：音乐',
    '速度：${tempo == null ? '未记录' : '每分钟 $tempo 拍'}',
    '拍号：${_timeSigText(summary['timeSig'])}',
    '调号：${_keySigText(summary['keySig'])}',
    '轨道数：${tracks.length} 条',
  ]);

  out.write('\n## 轨道表\n');
  if (tracks.isEmpty) {
    out.write('- 暂无轨道\n');
  } else {
    out.write('| 序号 | 名称 | 乐器 | 音量 | 小节数 |\n');
    out.write('| --- | --- | --- | --- | --- |\n');
    for (int i = 0; i < tracks.length; i++) {
      final Object? track = tracks[i];
      final Object? volume = track is Map ? track['volume'] : null;
      final Object? measures = track is Map ? track['measures'] : null;
      out.write(
        '| ${i + 1} | ${_tableCell(_trackName(track))} | '
        '${_tableCell(_instrumentText(track))} | ${_volumeText(volume)} | '
        '${_measureText(measures)} |\n',
      );
    }
  }

  out.write('\n## 校验\n');
  out.write('- 状态：${_validationText(summary)}\n');
}

/// 未知 kind 的通用最小文档：只有概览 + 一句说明，绝不抛。
void _writeGenericDoc(StringBuffer out) {
  _writeOverview(out, const <String>['类型：工作台项目', '说明：本项目还没有可自动生成的文档结构。']);
}

// ---------------------------------------------------------------------------
// 写盘 / 读盘（原子写；docs.md 优先、brief.md 兜底）
// ---------------------------------------------------------------------------

/// 把生成文档原子写进 `projectDir/docs.md`。
///
/// * 目标已存在（文件或同名目录）且 `overwrite == false` → 返回 null，**不写**；
/// * 写入姿势：同目录临时文件 → flush → 改名替换（与仓库其它项目存储同一纪律
///   「要么完整出现，要么什么都不出现」）；
/// * 失败不破坏既有 `docs.md`；临时文件在 `finally` 里清理；
/// * 项目目录不存在时按需创建（`create(recursive: true)`）。
///
/// 返回写好的 [File]；文件系统失败以 [FileSystemException] 抛出（用户可见文案
/// 由调用方按「项目文件没能写入，请重试」映射）。
Future<File?> writeWorkbenchDoc({
  required Directory projectDir,
  required String kind,
  required String name,
  String title = '',
  Map<String, Object?> summary = const <String, Object?>{},
  bool overwrite = false,
}) async {
  if (!projectDir.existsSync()) {
    projectDir.createSync(recursive: true);
  }
  final File target = File('${projectDir.path}/$workbenchDocFileName');
  final bool occupied =
      FileSystemEntity.typeSync(target.path) != FileSystemEntityType.notFound;
  if (occupied && !overwrite) return null;

  final String content = buildWorkbenchDoc(
    kind: kind,
    name: name,
    title: title,
    summary: summary,
  );
  final File temp = File(
    '${projectDir.path}/.$workbenchDocFileName.'
    '${DateTime.now().microsecondsSinceEpoch}.tmp',
  );
  try {
    _writeFlushed(temp, content);
    if (target.existsSync()) {
      // 已有普通文件：Linux/macOS 的改名会原子替换；Windows 上改名遇在场目标
      // 可能失败，退回「先删目标再改名」（与仓库其它项目存储同法）。
      _renameReplacing(temp, target);
    } else {
      // 目标不是普通文件（缺失，或被目录占位）：直接改名；被目录占位时改名
      // 失败，抛异常并保留现场，不做破坏性兜底。
      temp.renameSync(target.path);
    }
  } finally {
    _deleteQuietly(temp);
  }
  return target;
}

/// 读项目内的人读文档：`docs.md` 优先，`brief.md` 兜底。
///
/// 文件缺失 / 读失败 / 正文空白都视为「没有文档」，继续试下一个候选；两个
/// 候选都不可用时返回 null（与四栏目工作台的读盘口径一致）。
Future<String?> readWorkbenchDoc(Directory projectDir) async {
  for (final String fileName in const <String>[
    workbenchDocFileName,
    workbenchDocFallbackFileName,
  ]) {
    final File file = File('${projectDir.path}/$fileName');
    if (!file.existsSync()) continue;
    try {
      final String text = await file.readAsString();
      if (text.trim().isNotEmpty) return text;
    } on FileSystemException {
      // 读不出来就试下一个候选；按「没有文档」降级，不抛给工作面。
    }
  }
  return null;
}

/// 项目里是否已有可展示的人读文档（`docs.md` 优先、`brief.md` 兜底）。
///
/// 判定与 [readWorkbenchDoc] 同一口径：候选文件存在且正文非空白即为 true；
/// 读失败按该候选不可用处理（不抛）。
bool hasWorkbenchDoc(Directory projectDir) {
  for (final String fileName in const <String>[
    workbenchDocFileName,
    workbenchDocFallbackFileName,
  ]) {
    final File file = File('${projectDir.path}/$fileName');
    if (!file.existsSync()) continue;
    try {
      if (file.readAsStringSync().trim().isNotEmpty) return true;
    } on FileSystemException {
      // 读不出来按该候选不可用处理，继续下一个候选。
    }
  }
  return false;
}

// ---------------------------------------------------------------------------
// 内部：写盘原语
// ---------------------------------------------------------------------------

/// 写临时文件并 flush：没 flush 的改名在掉电/崩溃时会变成半截文件。
void _writeFlushed(File file, String text) {
  final RandomAccessFile handle = file.openSync(mode: FileMode.writeOnly);
  try {
    handle.writeStringSync(text);
    handle.flushSync();
  } finally {
    handle.closeSync();
  }
}

/// 原子替换：先改名；Windows 目标在场时改名可能失败，先删目标再改名。
void _renameReplacing(File temp, File target) {
  try {
    temp.renameSync(target.path);
  } on FileSystemException {
    if (target.existsSync()) target.deleteSync();
    temp.renameSync(target.path);
  }
}

/// 清掉残留临时文件；清理失败不能盖掉原始错误。
void _deleteQuietly(File file) {
  try {
    if (file.existsSync()) file.deleteSync();
  } on FileSystemException {
    // 临时文件清理失败不影响主流程。
  }
}

// ---------------------------------------------------------------------------
// 内部：文本与取值（全部按显式 key 读，保证确定性）
// ---------------------------------------------------------------------------

/// 解析文档标题：显式 title → 摘要标题 → 项目名；都为空时给中性兜底。
String _resolveTitle({
  required String title,
  required Map<String, Object?> summary,
  required String name,
}) {
  final String given = _singleLine(title);
  if (given.isNotEmpty) return given;
  final String? fromSummary = _text(summary['title']);
  if (fromSummary != null) return _singleLine(fromSummary);
  final String fromName = _singleLine(name);
  return fromName.isEmpty ? '未命名项目' : fromName;
}

/// 一层推进的名字：已知 id 用中文层名，未知/缺失收回中性词。
String _threePassName(String idOrLabel) {
  final String text = idOrLabel.trim();
  if (text.isEmpty) return '进行中';
  return _threePassLabels[text] ?? '进行中';
}

/// 一条 pass 的展示名与状态（只读显式 key：label/name/id/status）。
({String? name, String status}) _passInfo(Object? raw) {
  if (raw is! Map) {
    return (name: _text(raw), status: '');
  }
  final String? label = _firstText(raw, const <String>['label', 'name']);
  final String? id = _firstText(raw, const <String>['id']);
  final String status = _firstText(raw, const <String>['status']) ?? '';
  return (
    name: label ?? (id == null ? null : _threePassName(id)),
    status: status,
  );
}

/// 组件一行：`name（what）` 优先，其次单个字段，最后退到 id。
String? _componentText(Object? raw) {
  if (raw is! Map) return _text(raw);
  final String? name = _firstText(raw, const <String>['name']);
  final String? what = _firstText(raw, const <String>['what']);
  if (name != null && what != null) return '$name（$what）';
  return name ?? what ?? _firstText(raw, const <String>['id', 'title']);
}

/// 验收项一行：按显式 key 依次取。
String? _acceptanceText(Object? raw) =>
    _firstText(raw, const <String>['what', 'name', 'text', 'criterion', 'id']);

/// 视频镜头文本：`text` 优先，其次标题类字段。
String _shotText(Object? raw) =>
    _firstText(raw, const <String>['text', 'title', 'label']) ?? '未记录';

/// 3D 视频镜头相机：相机 id，或移动镜头的 from/to 一句话。
String _cameraText(Object? raw) {
  if (raw is! Map) return _text(raw) ?? '未记录';
  final String? id = _firstText(raw, const <String>['id']);
  final Object? move = raw['move'];
  String? fromText;
  String? toText;
  if (move is Map) {
    fromText = _vec3Text(move['from']);
    toText = _vec3Text(move['to']);
  }
  final bool hasMove = fromText != null && toText != null;
  if (id != null && hasMove) return '$id（从 $fromText 到 $toText）';
  if (hasMove) return '从 $fromText 到 $toText';
  return id ?? '未记录';
}

/// 轨道名：`name` 优先，其次 id，最后中性兜底。
String _trackName(Object? raw) =>
    _firstText(raw, const <String>['name', 'id']) ?? '未命名轨道';

/// 乐器名：契约值翻成中文；未知值原样展示（便于人对照规范）。
String _instrumentText(Object? raw) {
  final String? instrument = _firstText(raw, const <String>['instrument']);
  if (instrument == null) return '未记录';
  return _instrumentLabels[instrument] ?? instrument;
}

/// 音量：0–1 → 百分比整数（越界按契约夹取；缺失记「未记录」）。
String _volumeText(Object? raw) {
  final double? value = _doubleValue(raw);
  if (value == null) return '未记录';
  return '${(value.clamp(0.0, 1.0) * 100).round()}%';
}

/// 小节数：数组取长度，数字原样（缺失记「未记录」）。
String _measureText(Object? raw) {
  if (raw is List) return '${raw.length}';
  final int? count = _intValue(raw);
  if (count == null || count < 0) return '未记录';
  return '$count';
}

/// 拍号：`[分子, 分母]` → `4/4`；文本原样；其它「未记录」。
String _timeSigText(Object? raw) {
  if (raw is List && raw.length == 2) {
    final int? numerator = _intValue(raw[0]);
    final int? denominator = _intValue(raw[1]);
    if (numerator != null && denominator != null) {
      return '$numerator/$denominator';
    }
  }
  return _text(raw) ?? '未记录';
}

/// 调号：文本原样（如 `C` / `F#`），缺失「未记录」。
String _keySigText(Object? raw) => _text(raw) ?? '未记录';

/// 校验状态：通过 / 未通过（N 处问题）/ 未校验。
String _validationText(Map<String, Object?> summary) {
  final Object? verified = summary['verified'];
  if (verified is! bool) return '未校验';
  if (verified) return '校验通过';
  final int? count = _issueCount(summary);
  return count == null ? '校验未通过' : '校验未通过（$count 处问题）';
}

/// 问题数：`checks` 优先、`issues` 兜底；数组取长度，数字原样。
int? _issueCount(Map<String, Object?> summary) {
  for (final String key in const <String>['checks', 'issues']) {
    final Object? raw = summary[key];
    if (raw is List) return raw.length;
    final int? count = _intValue(raw);
    if (count != null && count >= 0) return count;
  }
  return null;
}

/// 秒数人话：`3.5 秒` / `7 秒`；缺失或非法「未记录」。
String _durationText(double? seconds) {
  if (seconds == null || seconds < 0) return '未记录';
  return '${_decimalText(seconds)} 秒';
}

/// 数量人话：`3 个`；缺失或负数「未记录」。
String _countText(int? count) {
  if (count == null || count < 0) return '未记录';
  return '$count 个';
}

/// 帧数人话：`150 帧`；缺失或负数「未记录」。
String _framesText(int? frames) {
  if (frames == null || frames < 0) return '未记录';
  return '$frames 帧';
}

/// 镜头时长求和（没有任何可读时长时返回 null，不拿 0 冒充）。
double? _sumShotDurations(List<Object?> shots) {
  double total = 0;
  bool any = false;
  for (final Object? shot in shots) {
    if (shot is! Map) continue;
    final double? duration = _doubleValue(shot['duration']);
    if (duration == null || duration < 0) continue;
    total += duration;
    any = true;
  }
  return any ? total : null;
}

/// 向量 → `(0, 2, 6)`；形状不对返回 null。
String? _vec3Text(Object? raw) {
  if (raw is! List || raw.length != 3) return null;
  final List<String> parts = <String>[];
  for (final Object? value in raw) {
    final double? number = _doubleValue(value);
    if (number == null) return null;
    parts.add(_decimalText(number));
  }
  return '(${parts.join(', ')})';
}

/// 数字人话：整数不带小数点，最多两位小数并去尾零（确定性格式）。
String _decimalText(double value) {
  if (value == value.roundToDouble() && value.abs() < 1e15) {
    return value.toInt().toString();
  }
  String text = value.toStringAsFixed(2);
  if (text.contains('.')) {
    text = text.replaceFirst(RegExp(r'0+$'), '');
    text = text.replaceFirst(RegExp(r'\.$'), '');
  }
  return text;
}

/// 表格单元格：换行压成空格、竖线转义（不破坏 markdown 表格）。
String _tableCell(String text) => _singleLine(text).replaceAll('|', r'\|');

/// 单行化：行内换行/制表压成空格，连续空格收敛，首尾去空白。
String _singleLine(String text) => text
    .replaceAll(RegExp(r'[\r\n\t]+'), ' ')
    .replaceAll(RegExp(r' {2,}'), ' ')
    .trim();

/// 文本值：非空字符串去首尾空白后返回，否则 null。
String? _text(Object? value) {
  if (value is! String) return null;
  final String trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// 只按 [keys] 的显式顺序取第一个非空文本；[raw] 本身是字符串时原样使用。
String? _firstText(Object? raw, List<String> keys) {
  if (raw is! Map) return _text(raw);
  for (final String key in keys) {
    final String? text = _text(raw[key]);
    if (text != null) return text;
  }
  return null;
}

/// 摘要里的 list 值；不是 list 时按空列表处理（不抛）。
List<Object?> _listAt(Object? raw) {
  if (raw is List) return raw;
  return const <Object?>[];
}

/// 整数值；非有限数字 / 非数字返回 null。
int? _intValue(Object? raw) => raw is num && raw.isFinite ? raw.toInt() : null;

/// 正整数值（fps 一类）；非正数返回 null。
int? _positiveInt(Object? raw) {
  final int? value = _intValue(raw);
  return value == null || value <= 0 ? null : value;
}

/// 浮点值；非有限数字 / 非数字返回 null。
double? _doubleValue(Object? raw) =>
    raw is num && raw.isFinite ? raw.toDouble() : null;

/// 层名列表 → 顿号连接；空列表给「暂无」。
String _joinNames(List<String> names) => names.isEmpty ? '暂无' : names.join('、');

/// 概览小节：统一标题 + 若干 `- key：value` 行。
void _writeOverview(StringBuffer out, List<String> bullets) {
  out.write('\n## 项目概览\n');
  for (final String bullet in bullets) {
    out.write('- $bullet\n');
  }
}
