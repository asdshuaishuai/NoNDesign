/// 音乐模块确定性补丁：RFC6902 风格最小补丁（add / remove / replace）。
///
/// 契约见 `docs/music-contract.md` §7：`music_patch` 是确定性补丁，改后自动
/// 校验并如实回报。本文件是**纯 Dart**：不读文件、不碰项目库、不改调用方入参。
///
/// 纪律：
///  * 只允许白名单路径（标题、速度、轨道的安全字段、小节事件），其余一律
///    显性拒绝——未知字段路径、版本字段、越界下标都不接受；
///  * 一次补丁先在深拷贝上逐条应用，**绝不修改入参**；
///  * 全部应用后必须经 [parseMusicScore] 校验通过才返回结果；校验不过就抛
///    [MusicPatchFailure]（可控错误码 + 人话），调用方不得静默吞掉。
library;

import 'music_score.dart';

/// 补丁失败（可控错误；调用方必须显性上报 [message]，原始诊断只进 [detail]）。
///
/// [code] 是模块内的细分码（`invalid_path` / `invalid_operation` /
/// `out_of_range` / `invalid_value` / `score_invalid` / `too_many_ops`），
/// 工具信封会统一加 `music_patch_` 前缀；[message] 是用户可见的一句话。
final class MusicPatchFailure implements Exception {
  const MusicPatchFailure(this.code, this.message, {this.detail = ''});

  final String code;
  final String message;
  final String detail;

  @override
  String toString() =>
      'MusicPatchFailure($code${detail.isEmpty ? '' : ': $detail'})';
}

/// 一次补丁最多允许的操作条数（防止模型一次塞几千条把校验拖垮）。
const int musicMaxPatchOps = 200;

/// 补丁成功的结果：补丁后的原文 + 已校验模型 + 实际应用条数。
///
/// [raw] 保留未知字段与补丁后的形状（便于调用方做「最小改动」比对）；
/// [score] 是 [parseMusicScore] 通过后的模型（保存走它，与既有编辑闭环一致）。
final class MusicPatchResult {
  const MusicPatchResult({
    required this.score,
    required this.raw,
    required this.applied,
  });

  final MusicScore score;
  final Map<String, Object?> raw;
  final int applied;
}

/// 补丁细分码 → 用户可见的一句话（工具层失败码映射的兜底表）。
String musicPatchFailureMessage(String code) => switch (code) {
  'invalid_path' => '补丁路径不可用：只能改标题、速度、轨道的安全字段或小节事件',
  'invalid_operation' => '补丁动作不对：只支持新增、删除、替换',
  'out_of_range' => '补丁路径的下标越界了，先刷新乐谱再试',
  'invalid_value' => '补丁值格式不对，请按乐谱字段要求填写',
  'score_invalid' => '补丁后的乐谱没有通过校验，改动没有保存',
  'too_many_ops' => '一次补丁条数太多，拆成几次再试',
  _ => '乐谱补丁没有完成，请稍后再试',
};

/// 对一份 score.json 文档应用 RFC6902 风格的最小补丁。
///
/// [document] 必须是 score.json v1 的完整对象（未知字段原样保留）；
/// [operations] 是补丁数组，每项为 `{op: add|remove|replace, path, value}`：
///  * 白名单路径：`/title`、`/tempo`、
///    `/tracks/<i>/name|instrument|volume|muted`、
///    `/tracks/<i>/measures/<j>/events`（add 追加/插入单条事件对象）、
///    `/tracks/<i>/measures/<j>/events/<k>`（remove/replace 单条事件）；
///  * 全部应用后必须过 [parseMusicScore]；校验失败抛 [score_invalid]。
///
/// 成功返回 [MusicPatchResult]；任何失败抛 [MusicPatchFailure]。**入参永远
/// 不会被修改**（一开始就深拷贝，失败时直接丢弃拷贝）。
MusicPatchResult applyMusicPatch(
  Map<String, Object?> document,
  List<Object?> operations,
) {
  if (operations.isEmpty) {
    throw const MusicPatchFailure('invalid_operation', '至少要有一条补丁（新增、删除或替换）。');
  }
  if (operations.length > musicMaxPatchOps) {
    throw const MusicPatchFailure(
      'too_many_ops',
      '一次最多 $musicMaxPatchOps 条补丁，拆成几次再试。',
    );
  }
  final Map<String, Object?> patched = _copyDocument(document);
  for (int index = 0; index < operations.length; index++) {
    _applyOperation(patched, _readOperation(operations[index], index));
  }
  final parsed = parseMusicScore(patched);
  final MusicScore? verified = parsed.score;
  if (verified == null) {
    final blocking = parsed.issues
        .where((issue) => issue.blocking)
        .toList(growable: false);
    final first = blocking.isEmpty ? null : blocking.first;
    throw MusicPatchFailure(
      'score_invalid',
      '补丁后的乐谱没有通过校验'
          '${first == null ? '' : '（${first.pointer}：${first.message}）'}，'
          '改动没有保存。',
      detail: blocking
          .map((issue) => '${issue.pointer}: ${issue.code} ${issue.message}')
          .join('；'),
    );
  }
  return MusicPatchResult(
    score: verified,
    raw: patched,
    applied: operations.length,
  );
}

// ---------------------------------------------------------------------------
// 操作读取与派发
// ---------------------------------------------------------------------------

final class _MusicPatchOperation {
  const _MusicPatchOperation({
    required this.type,
    required this.path,
    required this.value,
  });

  final String type;
  final String path;
  final Object? value;
}

_MusicPatchOperation _readOperation(Object? raw, int index) {
  const Set<String> allowedKeys = <String>{'op', 'path', 'value'};
  if (raw is! Map) {
    throw MusicPatchFailure(
      'invalid_value',
      '第 ${index + 1} 条补丁必须是 {op, path, value} 对象。',
    );
  }
  final Map<String, Object?> map = raw.cast<String, Object?>();
  final unknown = map.keys
      .where((key) => !allowedKeys.contains(key))
      .toList(growable: false);
  if (unknown.isNotEmpty) {
    throw MusicPatchFailure(
      'invalid_operation',
      '第 ${index + 1} 条补丁有未知字段（${unknown.join('、')}）：'
          '只认 op / path / value。',
    );
  }
  final String type = (map['op'] ?? '').toString();
  if (type != 'add' && type != 'remove' && type != 'replace') {
    throw MusicPatchFailure(
      'invalid_operation',
      '第 ${index + 1} 条补丁的动作不对：只支持 add / remove / replace。',
    );
  }
  final Object? path = map['path'];
  if (path is! String || path.isEmpty) {
    throw MusicPatchFailure(
      'invalid_path',
      '第 ${index + 1} 条补丁缺少路径（path 要以 / 开头，例如 /tempo）。',
    );
  }
  if (type == 'remove') {
    if (map.containsKey('value')) {
      throw MusicPatchFailure(
        'invalid_operation',
        '第 ${index + 1} 条 remove 不需要 value，删掉它再试。',
      );
    }
    return _MusicPatchOperation(type: type, path: path, value: null);
  }
  if (!map.containsKey('value')) {
    throw MusicPatchFailure(
      'invalid_value',
      '第 ${index + 1} 条 $type 缺少 value。',
    );
  }
  return _MusicPatchOperation(type: type, path: path, value: map['value']);
}

void _applyOperation(Map<String, Object?> document, _MusicPatchOperation op) {
  final List<String> tokens = _parsePointer(op.path);
  final String head = tokens.first;
  if (tokens.length == 1) {
    switch (head) {
      case 'title':
        _rejectRemove(op, '标题');
        document['title'] = _requireText(op.value, '标题', op.path);
        return;
      case 'tempo':
        _rejectRemove(op, '速度');
        document['tempo'] = _requireTempo(op.value, op.path);
        return;
      case 'schemaVersion':
        throw const MusicPatchFailure('invalid_path', '版本字段是只读的，不能用补丁修改。');
      default:
        throw _unknownPath(op.path);
    }
  }
  if (head != 'tracks') throw _unknownPath(op.path);
  _applyTrackOperation(document, tokens, op);
}

void _applyTrackOperation(
  Map<String, Object?> document,
  List<String> tokens,
  _MusicPatchOperation op,
) {
  if (tokens.length < 3) throw _unknownPath(op.path);
  final List<dynamic> tracks = _requireList(
    document['tracks'],
    '轨道数组',
    op.path,
  );
  final int trackIndex = _readIndex(tokens[1], op.path, '轨道');
  if (trackIndex >= tracks.length) {
    throw MusicPatchFailure(
      'out_of_range',
      '轨道下标 $trackIndex 越界（当前共 ${tracks.length} 条）：'
          '${_shortPath(op.path)}',
    );
  }
  final Map<String, Object?> track = _requireMap(
    tracks[trackIndex],
    '轨道',
    op.path,
  );
  if (tokens.length == 3) {
    _rejectRemove(op, _trackFieldLabel(tokens[2]));
    final Object value = switch (tokens[2]) {
      'name' => _requireText(op.value, '轨道名称', op.path),
      'instrument' => _requireInstrument(op.value, op.path),
      'volume' => _requireVolume(op.value, op.path),
      'muted' => _requireMuted(op.value, op.path),
      _ => throw _unknownPath(op.path),
    };
    track[tokens[2]] = value;
    return;
  }
  if (tokens[2] != 'measures') throw _unknownPath(op.path);
  if (tokens.length != 5 && tokens.length != 6) {
    // 小节级只开放事件数组；不能再造小节、改小节 id 等结构字段。
    throw _unknownPath(op.path);
  }
  final List<dynamic> measures = _requireList(
    track['measures'],
    '小节数组',
    op.path,
  );
  final int measureIndex = _readIndex(tokens[3], op.path, '小节');
  if (measureIndex >= measures.length) {
    throw MusicPatchFailure(
      'out_of_range',
      '小节下标 $measureIndex 越界（当前共 ${measures.length} 个）：'
          '${_shortPath(op.path)}',
    );
  }
  final Map<String, Object?> measure = _requireMap(
    measures[measureIndex],
    '小节',
    op.path,
  );
  if (tokens[4] != 'events') throw _unknownPath(op.path);
  _applyEventOperation(measure, tokens, op);
}

void _applyEventOperation(
  Map<String, Object?> measure,
  List<String> tokens,
  _MusicPatchOperation op,
) {
  final List<dynamic> events = _eventList(measure, op.path);
  if (tokens.length == 5) {
    if (op.type != 'add') {
      throw const MusicPatchFailure(
        'invalid_operation',
        '删改单条事件要带事件下标，例如 …/events/0。',
      );
    }
    events.add(_requireEvent(op.value, op.path));
    measure['events'] = events;
    return;
  }
  final String indexToken = tokens[5];
  if (op.type == 'add' && indexToken == '-') {
    events.add(_requireEvent(op.value, op.path));
    measure['events'] = events;
    return;
  }
  final int index = _readIndex(indexToken, op.path, '事件');
  if (op.type == 'add') {
    if (index > events.length) {
      throw MusicPatchFailure(
        'out_of_range',
        '事件下标 $index 越界（当前共 ${events.length} 个）：'
            '${_shortPath(op.path)}',
      );
    }
    events.insert(index, _requireEvent(op.value, op.path));
  } else {
    if (index >= events.length) {
      throw MusicPatchFailure(
        'out_of_range',
        '事件下标 $index 越界（当前共 ${events.length} 个）：'
            '${_shortPath(op.path)}',
      );
    }
    if (op.type == 'remove') {
      events.removeAt(index);
    } else {
      events[index] = _requireEvent(op.value, op.path);
    }
  }
  measure['events'] = events;
}

List<dynamic> _eventList(Map<String, Object?> measure, String path) {
  final Object? raw = measure['events'];
  if (raw == null) return <dynamic>[];
  if (raw is! List) {
    throw MusicPatchFailure(
      'score_invalid',
      '这个小节的 events 不是数组，先修好乐谱再打补丁：${_shortPath(path)}',
    );
  }
  return raw;
}

// ---------------------------------------------------------------------------
// 路径解析（RFC6901 JSON Pointer 子集；白名单在派发层）
// ---------------------------------------------------------------------------

List<String> _parsePointer(String path) {
  if (!path.startsWith('/') || path.length < 2) {
    throw MusicPatchFailure(
      'invalid_path',
      '补丁路径要以 / 开头，并且不能是空路径：${_shortPath(path)}',
    );
  }
  final List<String> tokens = <String>[];
  for (final String raw in path.substring(1).split('/')) {
    if (raw.isEmpty) {
      throw MusicPatchFailure('invalid_path', '补丁路径不能有空层级：${_shortPath(path)}');
    }
    final String token = _decodePointerToken(raw, path);
    if (token == '.' || token == '..') {
      throw MusicPatchFailure(
        'invalid_path',
        '补丁路径不能包含相对层级：${_shortPath(path)}',
      );
    }
    tokens.add(token);
  }
  return tokens;
}

String _decodePointerToken(String raw, String path) {
  final StringBuffer out = StringBuffer();
  for (int i = 0; i < raw.length; i++) {
    final String char = raw[i];
    if (char != '~') {
      out.write(char);
      continue;
    }
    if (i + 1 >= raw.length || raw[i + 1] != '0' && raw[i + 1] != '1') {
      throw MusicPatchFailure(
        'invalid_path',
        '补丁路径的 ~ 转义不合法：${_shortPath(path)}',
      );
    }
    out.write(raw[i + 1] == '0' ? '~' : '/');
    i += 1;
  }
  return out.toString();
}

int _readIndex(String token, String path, String label) {
  final bool digits =
      token.isNotEmpty &&
      token.codeUnits.every((unit) => unit >= 0x30 && unit <= 0x39);
  final bool canonical = digits && (token.length == 1 || token[0] != '0');
  if (!canonical) {
    throw MusicPatchFailure(
      'invalid_path',
      '$label下标只认 0、1、2 …：${_shortPath(path)}',
    );
  }
  final int? index = int.tryParse(token);
  if (index == null || index < 0) {
    throw MusicPatchFailure('invalid_path', '$label下标超出范围：${_shortPath(path)}');
  }
  return index;
}

// ---------------------------------------------------------------------------
// 容器/取值helpers
// ---------------------------------------------------------------------------

Map<String, Object?> _copyDocument(Map<String, Object?> source) =>
    _copyValue(source) as Map<String, Object?>;

Object? _copyValue(Object? value) {
  if (value is Map) {
    final Map<String, Object?> out = <String, Object?>{};
    for (final entry in value.entries) {
      out[entry.key.toString()] = _copyValue(entry.value);
    }
    return out;
  }
  if (value is List) {
    return <Object?>[for (final item in value) _copyValue(item)];
  }
  return value;
}

List<dynamic> _requireList(Object? value, String label, String path) {
  if (value is! List) {
    throw MusicPatchFailure(
      'score_invalid',
      '这份乐谱缺少$label，先修好再打补丁：${_shortPath(path)}',
    );
  }
  return value;
}

Map<String, Object?> _requireMap(Object? value, String label, String path) {
  if (value is! Map) {
    throw MusicPatchFailure(
      'score_invalid',
      '这份乐谱的$label不是对象，先修好再打补丁：${_shortPath(path)}',
    );
  }
  return value.cast<String, Object?>();
}

Map<String, Object?> _requireEvent(Object? value, String path) {
  if (value is! Map) {
    throw MusicPatchFailure(
      'invalid_value',
      '事件必须是对象（id / type / dur / pitch …）：${_shortPath(path)}',
    );
  }
  // 事件值来自调用方的补丁数组：深拷贝后再落进补丁文档，绝不共享引用。
  return _copyValue(value) as Map<String, Object?>;
}

void _rejectRemove(_MusicPatchOperation op, String label) {
  if (op.type == 'remove') {
    throw MusicPatchFailure(
      'invalid_operation',
      '$label不能删除，用 replace 改值：${_shortPath(op.path)}',
    );
  }
}

String _trackFieldLabel(String field) => switch (field) {
  'name' => '轨道名称',
  'instrument' => '音色',
  'volume' => '音量',
  'muted' => '静音状态',
  _ => '这个字段',
};

MusicPatchFailure _unknownPath(String path) => MusicPatchFailure(
  'invalid_path',
  '补丁路径不可用：只能改标题、速度、轨道的名称/音色/音量/静音，'
      '或小节里的事件（${_shortPath(path)}）。',
);

String _shortPath(String path) =>
    path.length <= 80 ? path : '${path.substring(0, 80)}…';

// ---------------------------------------------------------------------------
// 字段取值验证（类型/范围在补丁层先挡，语义硬门仍交给 parseMusicScore）
// ---------------------------------------------------------------------------

String _requireText(Object? value, String label, String path) {
  if (value is! String || value.trim().isEmpty) {
    throw MusicPatchFailure(
      'invalid_value',
      '$label必须是非空文本：${_shortPath(path)}',
    );
  }
  return value;
}

int _requireTempo(Object? value, String path) {
  if (value is! num || !value.isFinite) {
    throw MusicPatchFailure('invalid_value', '速度必须是整数 BPM：${_shortPath(path)}');
  }
  final double asDouble = value.toDouble();
  // 拒绝非整数与超出安全整数范围的值（toInt() 对超大浮点数不可靠）；
  // tempo ∈ [20,300] 的语义范围仍交给 parseMusicScore 硬门。
  final bool integral = asDouble == asDouble.truncateToDouble();
  const double safeInteger = 9007199254740992.0; // 2^53
  if (!integral || asDouble.abs() > safeInteger) {
    throw MusicPatchFailure('invalid_value', '速度必须是整数 BPM：${_shortPath(path)}');
  }
  return asDouble.toInt();
}

String _requireInstrument(Object? value, String path) {
  if (value is! String || !musicInstruments.contains(value)) {
    throw MusicPatchFailure(
      'invalid_value',
      '音色必须是 ${musicInstruments.join(' / ')} 之一：${_shortPath(path)}',
    );
  }
  return value;
}

double _requireVolume(Object? value, String path) {
  if (value is! num || !value.isFinite || value < 0 || value > 1) {
    throw MusicPatchFailure(
      'invalid_value',
      '音量必须是 0–1 之间的数字：${_shortPath(path)}',
    );
  }
  return value.toDouble();
}

bool _requireMuted(Object? value, String path) {
  if (value is! bool) {
    throw MusicPatchFailure(
      'invalid_value',
      '静音状态必须是 true / false：${_shortPath(path)}',
    );
  }
  return value;
}
