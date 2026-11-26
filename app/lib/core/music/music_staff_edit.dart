/// 五线谱点击编辑的纯函数：把「谱面命中音高」追加到指定小节。
///
/// 与 `music_edit.dart` 的编辑纪律一致：
/// - 只改目标轨道的目标小节，其它轨道/小节/未知字段原样保留；
/// - 按拍号休止补齐（结果小节时值总和 == 拍号），时值用整数有理数计算，不经过浮点；
/// - 结果必须能被 [parseMusicScore] 接受，否则抛 [MusicEditFailure]，绝不返回坏 score；
/// - 鼓轨必须显式给鼓件名（[appendNoteAt] 的 `drum`）；缺省/非法鼓件显性拒绝，
///   不会把鼓点当普通音高写进事实源。
///
/// 与 `music_edit.dart` 的 [appendQuarterNote] 相比，这里可以指定
/// `targetMeasureIndex`：点击落在哪一小节就追加到哪一小节；目标小节放不下时
/// 在它后面插入一个新小节，而不是永远追加到轨道末尾。`music_edit.dart` 保持只读，
/// 本文件不修改它。
library;

import 'music_edit.dart';
import 'music_score.dart';

/// 追加音符到指定小节（默认四分音符；默认追加到目标轨道最后一个小节）。
///
/// [trackIndex] 是轨道下标（越界抛 `unknown_track`）。[step]/[alter]/[octave]
/// 按 C–B / -1..1 / 0–9 校验；鼓轨（`instrument=drums`）必须给合法 [drum] 鼓件名，
/// 否则显性拒绝。
///
/// [targetMeasureIndex] 为 null 时追加到轨道最后一个小节；给出时必须落在该轨道
/// 现有小节内（越界抛 `invalid_measure`）。目标小节剩余时值放得下
/// `durNum/durDen` 时原地追加，并用休止补齐到拍号；放不下时在目标小节后插入
/// 一个新小节，再按拍号补齐。插入新小节会让后续小节下标后移，但事件 id 不变。
MusicScore appendNoteAt(
  MusicScore score, {
  required int trackIndex,
  String step = 'C',
  int alter = 0,
  int octave = 4,
  int durNum = 1,
  int durDen = 4,
  int? targetMeasureIndex,
  String? drum,
}) {
  final MusicScore base = _canonical(score);
  if (trackIndex < 0 || trackIndex >= base.tracks.length) {
    throw const MusicEditFailure('unknown_track', '没有找到这条轨道，先刷新试试。');
  }
  final MusicTrack track = base.tracks[trackIndex];
  final String stepValue = step.trim().toUpperCase();
  if (!musicSteps.contains(stepValue) ||
      octave < 0 ||
      octave > 9 ||
      alter < -1 ||
      alter > 1) {
    throw const MusicEditFailure(
      'invalid_pitch',
      '音高要在 C–B、八度 0–9、升降 -1..1 之内。',
    );
  }
  if (durNum <= 0 || durDen <= 0) {
    throw const MusicEditFailure('invalid_duration', '音符时值必须是正有理数。');
  }
  final _Fraction duration = _Fraction(durNum, durDen);
  final List<int> timeSig = base.timeSig;
  final _Fraction capacity = _Fraction(timeSig[0], timeSig[1]);
  if (capacity < duration) {
    throw const MusicEditFailure('invalid_duration', '当前拍号放不下这个音符。');
  }
  final bool isDrumTrack = track.instrument == 'drums';
  final String drumValue = (drum ?? '').trim();
  if (isDrumTrack && !musicDrumNames.contains(drumValue)) {
    throw const MusicEditFailure(
      'invalid_drum',
      '鼓轨要用鼓组音色名（kick/snare/hihat/openhat/crash/ride/tom），'
          '不能按普通音高写。',
    );
  }

  final List<MusicMeasure> measures = List<MusicMeasure>.of(track.measures);
  if (measures.isEmpty) {
    throw const MusicEditFailure('invalid_input', '这条轨道还没有小节，先补一个小节再写音符。');
  }
  final int target = targetMeasureIndex ?? measures.length - 1;
  if (target < 0 || target >= measures.length) {
    throw const MusicEditFailure('invalid_measure', '这条轨道没有对应的小节，先刷新再试。');
  }
  final _Fraction? remaining = capacity.difference(_filledOf(measures[target]));
  final int destinationIndex;
  if (remaining != null && remaining >= duration) {
    destinationIndex = target;
  } else {
    // 目标小节放不下：在它后面插入一个新小节（目标在末尾时就是追加到轨道末尾）。
    if (measures.length >= musicMaxMeasuresPerTrack) {
      throw const MusicEditFailure(
        'score_too_large',
        '每条轨道最多 $musicMaxMeasuresPerTrack 个小节。',
      );
    }
    destinationIndex = target + 1;
    measures.insert(
      destinationIndex,
      MusicMeasure(id: _freshMeasureId(measures), events: const <MusicEvent>[]),
    );
  }
  final MusicMeasure destination = measures[destinationIndex];
  final Set<String> usedIds = _eventIdsOf(base);
  final List<MusicEvent> events = List<MusicEvent>.of(destination.events);
  events.add(
    MusicEvent(
      id: _freshEventId(usedIds),
      isRest: false,
      durNum: duration.n,
      durDen: duration.d,
      step: stepValue,
      alter: alter,
      octave: octave,
      extra: isDrumTrack
          ? <String, Object?>{'drum': drumValue}
          : const <String, Object?>{},
    ),
  );
  final _Fraction padding =
      capacity.difference(_filledOf(destination) + duration) ?? _Fraction.zero;
  if (padding > _Fraction.zero) {
    events.add(
      MusicEvent(
        id: _freshEventId(usedIds),
        isRest: true,
        durNum: padding.n,
        durDen: padding.d,
      ),
    );
  }
  measures[destinationIndex] = MusicMeasure(
    id: destination.id,
    events: events,
    extra: destination.extra,
  );
  final List<MusicTrack> tracks = List<MusicTrack>.of(base.tracks);
  tracks[trackIndex] = _copyTrack(track, measures: measures);
  return _accept(_copyScore(base, tracks: tracks));
}

// ---------------------------------------------------------------------------
// task-16：按拍位插入 / 删除音符
// ---------------------------------------------------------------------------

/// 在第 [beatIndex] 拍位置插入音符（默认四分音符），结果必须 parse + verify 通过。
///
/// 拍位**0 起**（界面「第 N 拍」= beatIndex + 1，见 [musicStaffInsertAtMessage]）；
/// 音符从该拍起点开始占用 [durNum]/[durDen] 的时长（默认 1/4，在 x/4 拍号里正好
/// 一拍）。语义严格但透明：
/// * 与插入范围重叠的**休止**会被裁短/拆分，空档一律用休止补到拍号；
/// * 与插入范围重叠的**音符**直接显性失败（`beat_occupied`）——不做「把已有音符
///   挪走」或「顺延到下一空位」这类隐式改写；
/// * 时值从该拍起始放不进小节（`start + dur > 拍号容量`）→ `invalid_duration`。
///
/// 只改目标轨道的目标小节；其它轨道/小节、未知字段、事件 id（除被裁休止外）保留。
/// 结果经 [parseMusicScore] 接受且 [verifyMusicScore] 通过，否则抛 [MusicEditFailure]。
MusicScore insertNoteAt(
  MusicScore score, {
  required int trackIndex,
  required int measureIndex,
  int beatIndex = 0,
  String step = 'C',
  int alter = 0,
  int octave = 4,
  int durNum = 1,
  int durDen = 4,
  String? drum,
}) {
  final MusicScore base = _canonical(score);
  if (trackIndex < 0 || trackIndex >= base.tracks.length) {
    throw const MusicEditFailure('unknown_track', '没有找到这条轨道，先刷新试试。');
  }
  final MusicTrack track = base.tracks[trackIndex];
  final String stepValue = step.trim().toUpperCase();
  if (!musicSteps.contains(stepValue) ||
      octave < 0 ||
      octave > 9 ||
      alter < -1 ||
      alter > 1) {
    throw const MusicEditFailure(
      'invalid_pitch',
      '音高要在 C–B、八度 0–9、升降 -1..1 之内。',
    );
  }
  if (durNum <= 0 || durDen <= 0) {
    throw const MusicEditFailure('invalid_duration', '音符时值必须是正有理数。');
  }
  final List<int> timeSig = base.timeSig;
  final _Fraction capacity = _Fraction(timeSig[0], timeSig[1]);
  final _Fraction duration = _Fraction(durNum, durDen);
  if (capacity < duration) {
    throw const MusicEditFailure('invalid_duration', '当前拍号放不下这个音符。');
  }
  if (beatIndex < 0 || beatIndex >= timeSig[0]) {
    throw MusicEditFailure(
      'invalid_beat',
      '拍位要在第 1–${timeSig[0]} 拍之间（读到第 ${beatIndex + 1} 拍）。',
    );
  }
  final _Fraction start = _Fraction(beatIndex, timeSig[1]);
  final _Fraction insertEnd = start + duration;
  if (capacity < insertEnd) {
    throw MusicEditFailure(
      'invalid_duration',
      '从第 ${beatIndex + 1} 拍起放不下这个音符，先缩短时值或换个拍位。',
    );
  }
  if (measureIndex < 0 || measureIndex >= track.measures.length) {
    throw const MusicEditFailure('invalid_measure', '这条轨道没有对应的小节，先刷新再试。');
  }
  final bool isDrumTrack = track.instrument == 'drums';
  final String drumValue = (drum ?? '').trim();
  if (isDrumTrack && !musicDrumNames.contains(drumValue)) {
    throw const MusicEditFailure(
      'invalid_drum',
      '鼓轨要用鼓组音色名（kick/snare/hihat/openhat/crash/ride/tom），'
          '不能按普通音高写。',
    );
  }
  final MusicMeasure measure = track.measures[measureIndex];

  // 现有事件按时间轴排好（空小节 = 整小节休止，时间轴为空）。
  final List<({MusicEvent event, _Fraction start, _Fraction end})> timeline =
      <({MusicEvent event, _Fraction start, _Fraction end})>[];
  _Fraction cursor = _Fraction.zero;
  for (final MusicEvent event in measure.events) {
    final _Fraction eventDuration = _durationOf(event);
    timeline.add((event: event, start: cursor, end: cursor + eventDuration));
    cursor = cursor + eventDuration;
  }
  // 满位 = 插入范围里已经有响的音符：显性失败，不隐式挪音。
  for (final ({MusicEvent event, _Fraction start, _Fraction end}) item
      in timeline) {
    if (item.event.isRest) continue;
    if (item.start < insertEnd && item.end > start) {
      throw MusicEditFailure(
        'beat_occupied',
        '第 ${beatIndex + 1} 拍已经有音符了，先删掉它或换个拍位再插入。',
      );
    }
  }

  // 组织新事件序列：保留不相关的原事件；与插入范围重叠的休止裁成插入前后的
  // 两段；插入范围本身给新音符；最后把空档全部用休止补到拍号。
  final Set<String> usedIds = _eventIdsOf(base);
  final List<({MusicEvent? event, _Fraction start, _Fraction end})> pieces =
      <({MusicEvent? event, _Fraction start, _Fraction end})>[];
  for (final ({MusicEvent event, _Fraction start, _Fraction end}) item
      in timeline) {
    final bool overlaps = item.start < insertEnd && item.end > start;
    if (item.event.isRest && overlaps) {
      if (item.start < start) {
        pieces.add((event: null, start: item.start, end: start));
      }
      if (insertEnd < item.end) {
        pieces.add((event: null, start: insertEnd, end: item.end));
      }
      continue;
    }
    pieces.add((event: item.event, start: item.start, end: item.end));
  }
  final MusicEvent inserted = MusicEvent(
    id: _freshEventId(usedIds),
    isRest: false,
    durNum: duration.n,
    durDen: duration.d,
    step: stepValue,
    alter: alter,
    octave: octave,
    extra: isDrumTrack
        ? <String, Object?>{'drum': drumValue}
        : const <String, Object?>{},
  );
  pieces.add((event: inserted, start: start, end: insertEnd));
  pieces.sort(
    (
      ({MusicEvent? event, _Fraction start, _Fraction end}) a,
      ({MusicEvent? event, _Fraction start, _Fraction end}) b,
    ) => a.start.compareTo(b.start),
  );
  final List<MusicEvent> events = <MusicEvent>[];
  cursor = _Fraction.zero;
  for (final ({MusicEvent? event, _Fraction start, _Fraction end}) piece
      in pieces) {
    if (cursor < piece.start) {
      events.add(_restFor(piece.start.difference(cursor)!, usedIds));
    }
    final MusicEvent? keep = piece.event;
    if (keep != null) {
      events.add(keep);
    } else {
      // 被插入范围裁短的休止：按剩余时值新建等值时值休止。
      events.add(_restFor(piece.end.difference(piece.start)!, usedIds));
    }
    cursor = piece.end;
  }
  if (cursor < capacity) {
    events.add(_restFor(capacity.difference(cursor)!, usedIds));
  }
  final List<MusicMeasure> measures = List<MusicMeasure>.of(track.measures);
  measures[measureIndex] = MusicMeasure(
    id: measure.id,
    events: events,
    extra: measure.extra,
  );
  final List<MusicTrack> tracks = List<MusicTrack>.of(base.tracks);
  tracks[trackIndex] = _copyTrack(track, measures: measures);
  return _accept(_copyScore(base, tracks: tracks));
}

/// 删除指定事件（按事件 id 定位），删除后用**等长休止**留在原拍位并补到拍号。
///
/// [eventId] 必须是目标轨道目标小节里的事件 id，否则显性失败（`invalid_event`）。
/// 删除一个音符 = 把它的时间槽换成休止（不把后面的音符向前挪），所以小节时值
/// 总和仍等于拍号；删除休止也走同一路径（占用槽位不变，只换 id）。
/// 被关系对象（tie/beam/slur）引用的事件删除后会让关系悬空，此时 [MusicEditFailure]
/// 显性拒绝（`invalid_result`），不静默丢关系、也不返回坏 score。
MusicScore deleteNoteAt(
  MusicScore score, {
  required int trackIndex,
  required int measureIndex,
  required String eventId,
}) {
  final MusicScore base = _canonical(score);
  if (trackIndex < 0 || trackIndex >= base.tracks.length) {
    throw const MusicEditFailure('unknown_track', '没有找到这条轨道，先刷新试试。');
  }
  final MusicTrack track = base.tracks[trackIndex];
  if (measureIndex < 0 || measureIndex >= track.measures.length) {
    throw const MusicEditFailure('invalid_measure', '这条轨道没有对应的小节，先刷新再试。');
  }
  final String idValue = eventId.trim();
  if (idValue.isEmpty) {
    throw const MusicEditFailure('invalid_event', '要删除的音符 id 不能为空。');
  }
  final MusicMeasure measure = track.measures[measureIndex];
  int index = -1;
  for (int i = 0; i < measure.events.length; i++) {
    if (measure.events[i].id == idValue) {
      index = i;
      break;
    }
  }
  if (index < 0) {
    throw const MusicEditFailure('invalid_event', '这一小节里没有找到要删除的音符，先刷新再试。');
  }
  final _Fraction removedDuration = _durationOf(measure.events[index]);
  final Set<String> usedIds = _eventIdsOf(base);
  final List<MusicEvent> events = List<MusicEvent>.of(measure.events);
  events[index] = _restFor(removedDuration, usedIds);
  // 合法乐谱里「等长替换」已经保持总和 == 拍号；这里对坏数据兜底补休止。
  _Fraction total = _Fraction.zero;
  for (final MusicEvent event in events) {
    total = total + _durationOf(event);
  }
  final _Fraction capacity = _Fraction(base.timeSig[0], base.timeSig[1]);
  final _Fraction? missing = capacity.difference(total);
  if (missing != null && missing > _Fraction.zero) {
    events.add(_restFor(missing, usedIds));
  }
  final List<MusicMeasure> measures = List<MusicMeasure>.of(track.measures);
  measures[measureIndex] = MusicMeasure(
    id: measure.id,
    events: events,
    extra: measure.extra,
  );
  final List<MusicTrack> tracks = List<MusicTrack>.of(base.tracks);
  tracks[trackIndex] = _copyTrack(track, measures: measures);
  return _accept(_copyScore(base, tracks: tracks));
}

/// 按剩余时值新建一个休止事件（event id 从全局未用 id 里取，保证唯一）。
MusicEvent _restFor(_Fraction value, Set<String> usedIds) => MusicEvent(
  id: _freshEventId(usedIds),
  isRest: true,
  durNum: value.n,
  durDen: value.d,
);

// ---------------------------------------------------------------------------
// 状态行文案（纯函数：工作台只拼确认消息，不自己猜音高/时值名称）
// ---------------------------------------------------------------------------

/// 音高显示名：`C5` / `C#5` / `Bb4`（升降号按记谱 glyph 习惯放音名后面）。
String musicNoteLabel({required String step, int alter = 0, int octave = 4}) {
  final String stepValue = step.trim().toUpperCase();
  final String accidental = alter > 0 ? '#' : (alter < 0 ? 'b' : '');
  return '$stepValue$accidental$octave';
}

/// 时值显示名（默认四分音符；未列出的时值按分数原样显示）。
String musicDurationLabel(int num, int den) {
  if (num <= 0 || den <= 0) return '未知时值';
  final int gcd = _gcd(num, den);
  final int n = num ~/ gcd;
  final int d = den ~/ gcd;
  return switch ((n, d)) {
    (1, 1) => '全音符',
    (1, 2) => '二分音符',
    (1, 4) => '四分音符',
    (1, 8) => '八分音符',
    (1, 16) => '十六分音符',
    (1, 32) => '三十二分音符',
    _ => '$num/$den 音符',
  };
}

/// 鼓件显示名。
String musicDrumLabel(String drum) => switch (drum.trim()) {
  'kick' => '底鼓',
  'snare' => '军鼓',
  'hihat' => '踩镲',
  'openhat' => '开镲',
  'crash' => '强音镲',
  'ride' => '叮叮镲',
  'tom' => '嗵鼓',
  final String other => other.isEmpty ? '鼓点' : other,
};

/// 插入成功后的确认文案（例：`已插入 C5 四分音符`）。
///
/// 鼓轨传 [drum] 时用鼓件名（例：`已插入 军鼓 四分音符`），不显示占位音高。
String musicStaffInsertMessage({
  String step = 'C',
  int alter = 0,
  int octave = 4,
  int durNum = 1,
  int durDen = 4,
  String? drum,
}) {
  final String label = drum == null
      ? musicNoteLabel(step: step, alter: alter, octave: octave)
      : musicDrumLabel(drum);
  return '已插入 $label ${musicDurationLabel(durNum, durDen)}';
}

/// 按拍位插入成功后的确认文案（例：`已在第 2 拍插入 C5`）。
///
/// [beatIndex] 是**0 起**小节内拍下标（[musicStaffInsertAtMessage] 内部 +1 后
/// 显示人话拍号）；鼓轨传 [drum] 时用鼓件名。
String musicStaffInsertAtMessage({
  required int beatIndex,
  String step = 'C',
  int alter = 0,
  int octave = 4,
  String? drum,
}) {
  final String label = drum == null
      ? musicNoteLabel(step: step, alter: alter, octave: octave)
      : musicDrumLabel(drum);
  return '已在第 ${beatIndex + 1} 拍插入 $label';
}

/// 删除音符成功后的确认文案。
String musicStaffDeleteMessage() => '已删除音符';

// ---------------------------------------------------------------------------
// 内部实现（校验/精确时值/补丁，与 music_edit.dart 同纪律）
// ---------------------------------------------------------------------------

/// 校验并规范化输入（鼓轨字符串音名先归一，保证模型能再次被解析）。
MusicScore _canonical(MusicScore score) {
  final parsed = parseMusicScore(_normalizeDrums(score).toJson());
  final MusicScore? canonical = parsed.score;
  if (canonical == null) {
    throw const MusicEditFailure('invalid_input', '当前乐谱本身没有通过检查，先修好再编辑。');
  }
  return canonical;
}

/// 校验结果；不合法就抛可控错误，绝不落盘坏 score。
MusicScore _accept(MusicScore candidate) {
  final parsed = parseMusicScore(_normalizeDrums(candidate).toJson());
  final MusicScore? canonical = parsed.score;
  if (canonical == null) {
    String detail = '';
    for (final MusicIssue issue in parsed.issues) {
      if (!issue.blocking) continue;
      detail = issue.message;
      break;
    }
    throw MusicEditFailure(
      'invalid_result',
      detail.isEmpty ? '这次修改会让乐谱不合法，已取消。' : '这次修改会让乐谱不合法，已取消：$detail',
    );
  }
  return canonical;
}

/// 鼓轨字符串音名（`"pitch": "kick"`）解析后模型 `step` 为空，直接序列化会
/// 变成非法音高；编辑时统一补一个合法占位音高（播放仍按 `drum` 鼓件名）。
MusicScore _normalizeDrums(MusicScore score) {
  bool changed = false;
  final List<MusicTrack> tracks = <MusicTrack>[];
  for (final MusicTrack track in score.tracks) {
    if (track.instrument != 'drums') {
      tracks.add(track);
      continue;
    }
    bool trackChanged = false;
    final List<MusicMeasure> measures = <MusicMeasure>[];
    for (final MusicMeasure measure in track.measures) {
      bool measureChanged = false;
      final List<MusicEvent> events = <MusicEvent>[];
      for (final MusicEvent event in measure.events) {
        if (event.isRest || event.step.isNotEmpty) {
          events.add(event);
          continue;
        }
        measureChanged = true;
        events.add(
          MusicEvent(
            id: event.id,
            isRest: false,
            durNum: event.durNum,
            durDen: event.durDen,
            step: 'C',
            alter: 0,
            octave: 4,
            dot: event.dot,
            tupletN: event.tupletN,
            tupletIn: event.tupletIn,
            extra: event.extra,
          ),
        );
      }
      if (!measureChanged) {
        measures.add(measure);
      } else {
        trackChanged = true;
        measures.add(
          MusicMeasure(id: measure.id, events: events, extra: measure.extra),
        );
      }
    }
    if (!trackChanged) {
      tracks.add(track);
    } else {
      changed = true;
      tracks.add(_copyTrack(track, measures: measures));
    }
  }
  if (!changed) return score;
  return _copyScore(score, tracks: tracks);
}

/// 小节已填时值总和（空小节 = 整小节休止，按 0 计，整段容量可用）。
_Fraction _filledOf(MusicMeasure measure) {
  _Fraction total = _Fraction.zero;
  for (final MusicEvent event in measure.events) {
    total = total + _durationOf(event);
  }
  return total;
}

/// 单个事件的精确时值（相对全音符；含附点/连音）。
_Fraction _durationOf(MusicEvent event) {
  int num = event.durNum;
  int den = event.durDen;
  if (num <= 0 || den <= 0) {
    throw const MusicEditFailure('invalid_input', '乐谱里有非法时值。');
  }
  if (event.dot == 1) {
    num *= 3;
    den *= 2;
  }
  if (event.tupletN > 0 || event.tupletIn > 0) {
    if (event.tupletN <= 0 || event.tupletIn <= 0) {
      throw const MusicEditFailure('invalid_input', '乐谱里有非法连音时值。');
    }
    num *= event.tupletIn;
    den *= event.tupletN;
  }
  return _Fraction(num, den);
}

Set<String> _eventIdsOf(MusicScore score) {
  final Set<String> ids = <String>{};
  for (final MusicTrack track in score.tracks) {
    for (final MusicMeasure measure in track.measures) {
      for (final MusicEvent event in measure.events) {
        ids.add(event.id);
      }
    }
  }
  return ids;
}

String _freshEventId(Set<String> used) {
  int index = 1;
  while (used.contains('e_$index')) {
    index++;
  }
  final String id = 'e_$index';
  used.add(id);
  return id;
}

String _freshMeasureId(List<MusicMeasure> measures) {
  final Set<String> used = <String>{
    for (final MusicMeasure measure in measures) measure.id,
  };
  int index = measures.length + 1;
  while (used.contains('m_$index')) {
    index++;
  }
  return 'm_$index';
}

MusicScore _copyScore(
  MusicScore source, {
  String? title,
  int? tempo,
  List<int>? timeSig,
  String? keySig,
  List<MusicTrack>? tracks,
  List<MusicRelation>? relations,
}) => MusicScore(
  schemaVersion: source.schemaVersion,
  title: title ?? source.title,
  tempo: tempo ?? source.tempo,
  timeSig: timeSig ?? source.timeSig,
  keySig: keySig ?? source.keySig,
  tracks: tracks ?? source.tracks,
  relations: relations ?? source.relations,
  extra: source.extra,
);

MusicTrack _copyTrack(
  MusicTrack source, {
  String? name,
  String? instrument,
  double? volume,
  bool? muted,
  String? clef,
  List<MusicMeasure>? measures,
}) => MusicTrack(
  id: source.id,
  name: name ?? source.name,
  instrument: instrument ?? source.instrument,
  volume: volume ?? source.volume,
  muted: muted ?? source.muted,
  clef: clef ?? source.clef,
  measures: measures ?? source.measures,
  extra: source.extra,
);

/// 精确正有理数（内部只用整数，避免浮点误差影响「小节时值总和 == 拍号」）。
final class _Fraction implements Comparable<_Fraction> {
  const _Fraction._(this.n, this.d);

  factory _Fraction(int numerator, int denominator) {
    if (denominator <= 0) {
      throw const MusicEditFailure('invalid_input', '时值分母必须是正整数。');
    }
    if (numerator < 0) {
      throw const MusicEditFailure('invalid_input', '时值不能为负。');
    }
    if (numerator == 0) return zero;
    final int gcd = _gcd(numerator, denominator);
    return _Fraction._(numerator ~/ gcd, denominator ~/ gcd);
  }

  static const _Fraction zero = _Fraction._(0, 1);

  final int n;
  final int d;

  _Fraction operator +(_Fraction other) =>
      _Fraction(n * other.d + other.n * d, d * other.d);

  /// `this - other`；结果为负时返回 null（调用方按「放不下」处理）。
  _Fraction? difference(_Fraction other) {
    final int numerator = n * other.d - other.n * d;
    if (numerator < 0) return null;
    return _Fraction(numerator, d * other.d);
  }

  bool operator <(_Fraction other) => n * other.d < other.n * d;

  bool operator >=(_Fraction other) => n * other.d >= other.n * d;

  bool operator >(_Fraction other) => n * other.d > other.n * d;

  @override
  bool operator ==(Object other) =>
      other is _Fraction && n == other.n && d == other.d;

  @override
  int get hashCode => Object.hash(n, d);

  @override
  int compareTo(_Fraction other) => n * other.d - other.n * d;
}

int _gcd(int a, int b) {
  int x = a.abs();
  int y = b.abs();
  while (y != 0) {
    final int t = x % y;
    x = y;
    y = t;
  }
  return x == 0 ? 1 : x;
}
