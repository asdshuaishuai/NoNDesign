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
