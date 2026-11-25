/// 音乐模块最小编辑闭环：纯函数修改 `score.json` v1 文档模型。
///
/// 契约见 `docs/music-contract.md` §1/§3：
/// - 编辑只改音乐语义字段，未知字段（score/track/measure/event 级 `extra`）原样保留；
/// - 所有输入/输出都是 [MusicScore]，结果必须能被 `parseMusicScore` 接受；
/// - 非法输入或编辑后不再合法的乐谱抛 [MusicEditFailure]（可控错误码 + 人话），
///   绝不返回坏 score。
///
/// 小节容量按契约「休止补齐」处理：往末尾追加音符/休止时，若当前小节放不下就
/// 追加一个空小节，再用休止把新小节补满到拍号——结果始终满足「小节时值总和 ==
/// 拍号」。时间计算用整数有理数，不经过浮点，所以补齐后的时值是精确的。
library;

import 'music_score.dart';

/// 编辑失败（可控错误；调用方必须显性显示 [message]，不能静默吞掉）。
final class MusicEditFailure implements Exception {
  const MusicEditFailure(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'MusicEditFailure($code: $message)';
}

/// 速度合法区间（与解析器一致，见 `music_score.dart`）。
const int musicTempoMin = 20;
const int musicTempoMax = 300;

/// 每条轨道的小节上限（与解析器一致）。
const int musicMaxMeasuresPerTrack = 256;

/// 标题最大长度（界面输入上限，不是契约硬门）。
const int musicMaxTitleLength = 80;

/// 允许的拍号分母（二分/四分/八分/十六分/三十二分音符为一拍）。
const List<int> musicAllowedBeatUnits = <int>[1, 2, 4, 8, 16, 32];

/// 改乐谱标题（去首尾空白；空标题/超长标题拒绝）。
MusicScore editScoreTitle(MusicScore score, String title) {
  final MusicScore base = _canonical(score);
  final String value = title.trim();
  if (value.isEmpty) {
    throw const MusicEditFailure('invalid_title', '标题不能为空。');
  }
  if (value.length > musicMaxTitleLength) {
    throw const MusicEditFailure(
      'invalid_title',
      '标题最多 $musicMaxTitleLength 个字。',
    );
  }
  return _accept(_copyScore(base, title: value));
}

/// 改速度（BPM；合法区间 [20, 300]）。
MusicScore editScoreTempo(MusicScore score, int tempo) {
  final MusicScore base = _canonical(score);
  if (tempo < musicTempoMin || tempo > musicTempoMax) {
    throw const MusicEditFailure(
      'invalid_tempo',
      '速度必须在 $musicTempoMin–$musicTempoMax 之间。',
    );
  }
  return _accept(_copyScore(base, tempo: tempo));
}

/// 改拍号（`beats/beatUnit`）。
///
/// 只有空小节（整小节休止）随拍号变化；已经写了事件的小节必须与新拍号等值，
/// 否则拒绝——换拍号不能把已有小节悄悄改坏。
MusicScore editScoreTimeSig(MusicScore score, int beats, int beatUnit) {
  final MusicScore base = _canonical(score);
  if (beats < 1 || beats > 32 || !musicAllowedBeatUnits.contains(beatUnit)) {
    throw const MusicEditFailure(
      'invalid_time_sig',
      '拍号必须是 1–32 拍、分母为 1/2/4/8/16/32。',
    );
  }
  final _Fraction target = _Fraction(beats, beatUnit);
  for (int ti = 0; ti < base.tracks.length; ti++) {
    final MusicTrack track = base.tracks[ti];
    for (int mi = 0; mi < track.measures.length; mi++) {
      final MusicMeasure measure = track.measures[mi];
      if (measure.events.isEmpty) continue;
      if (_filledOf(measure) != target) {
        throw MusicEditFailure(
          'time_sig_conflict',
          '第 ${ti + 1} 条轨道的第 ${mi + 1} 小节时值和新的拍号对不上，'
              '先调整那个小节再换拍号。',
        );
      }
    }
  }
  return _accept(_copyScore(base, timeSig: <int>[beats, beatUnit]));
}

/// 改轨道音量（0–1）。
MusicScore editTrackVolume(MusicScore score, String trackId, double volume) {
  final MusicScore base = _canonical(score);
  if (!volume.isFinite || volume < 0 || volume > 1) {
    throw const MusicEditFailure('invalid_volume', '音量必须在 0–1 之间。');
  }
  final MusicTrack track = _trackOf(base, trackId);
  return _accept(
    _copyScore(
      base,
      tracks: _replaceTrack(base, track, _copyTrack(track, volume: volume)),
    ),
  );
}

/// 改轨道静音状态。
MusicScore editTrackMuted(MusicScore score, String trackId, bool muted) {
  final MusicScore base = _canonical(score);
  final MusicTrack track = _trackOf(base, trackId);
  return _accept(
    _copyScore(
      base,
      tracks: _replaceTrack(base, track, _copyTrack(track, muted: muted)),
    ),
  );
}

/// 在选中轨道末尾追加一个空小节（整小节休止）。
MusicScore appendEmptyMeasure(MusicScore score, String trackId) {
  final MusicScore base = _canonical(score);
  final MusicTrack track = _trackOf(base, trackId);
  if (track.measures.length >= musicMaxMeasuresPerTrack) {
    throw const MusicEditFailure(
      'score_too_large',
      '每条轨道最多 $musicMaxMeasuresPerTrack 个小节。',
    );
  }
  final List<MusicMeasure> measures = List<MusicMeasure>.of(track.measures);
  measures.add(
    MusicMeasure(id: _freshMeasureId(measures), events: const <MusicEvent>[]),
  );
  return _accept(
    _copyScore(
      base,
      tracks: _replaceTrack(base, track, _copyTrack(track, measures: measures)),
    ),
  );
}

/// 删除选中轨道末尾的空小节；非空/只剩一个小节时拒绝。
MusicScore removeLastEmptyMeasure(MusicScore score, String trackId) {
  final MusicScore base = _canonical(score);
  final MusicTrack track = _trackOf(base, trackId);
  if (track.measures.length <= 1) {
    throw const MusicEditFailure('measure_required', '每条轨道至少要保留一个小节。');
  }
  if (track.measures.last.events.isNotEmpty) {
    throw const MusicEditFailure('measure_not_empty', '最后一个小节里还有内容，只能删空小节。');
  }
  final List<MusicMeasure> measures = List<MusicMeasure>.of(track.measures)
    ..removeLast();
  return _accept(
    _copyScore(
      base,
      tracks: _replaceTrack(base, track, _copyTrack(track, measures: measures)),
    ),
  );
}

/// 在选中轨道末尾追加一个四分音符（默认 C4），必要时新开小节并用休止补齐。
///
/// [step] C–B、[octave] 0–9、[alter] -1..1；鼓轨用 [drum] 鼓件名（默认 kick），
/// 音高字段只作为占位（鼓轨播放按鼓件名）。
MusicScore appendQuarterNote(
  MusicScore score,
  String trackId, {
  String step = 'C',
  int octave = 4,
  int alter = 0,
  String drum = 'kick',
}) {
  final MusicScore base = _canonical(score);
  final MusicTrack track = _trackOf(base, trackId);
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
  if (track.instrument == 'drums' && !musicDrumNames.contains(drum)) {
    throw const MusicEditFailure('invalid_pitch', '鼓件名不在鼓组音色表里。');
  }
  final Map<String, Object?> extra = track.instrument == 'drums'
      ? <String, Object?>{'drum': drum}
      : const <String, Object?>{};
  return _appendEvent(
    base,
    track,
    _quarter,
    (String eventId) => MusicEvent(
      id: eventId,
      isRest: false,
      durNum: 1,
      durDen: 4,
      step: stepValue,
      alter: alter,
      octave: octave,
      extra: extra,
    ),
  );
}

/// 在选中轨道末尾追加一个四分休止，必要时新开小节并用休止补齐。
MusicScore appendQuarterRest(MusicScore score, String trackId) {
  final MusicScore base = _canonical(score);
  final MusicTrack track = _trackOf(base, trackId);
  return _appendEvent(
    base,
    track,
    _quarter,
    (String eventId) =>
        MusicEvent(id: eventId, isRest: true, durNum: 1, durDen: 4),
  );
}

final _Fraction _quarter = _Fraction(1, 4);

// ---------------------------------------------------------------------------
// 内部实现
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

/// 轨道内已填时值总和（空小节 = 0，全部容量可用）。
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

_Fraction _timeSignatureOf(MusicScore score) {
  final List<int> timeSig = score.timeSig;
  if (timeSig.length != 2 || timeSig[0] <= 0 || timeSig[1] <= 0) {
    throw const MusicEditFailure('invalid_input', '当前乐谱的拍号不合法。');
  }
  return _Fraction(timeSig[0], timeSig[1]);
}

MusicScore _appendEvent(
  MusicScore base,
  MusicTrack track,
  _Fraction eventDuration,
  MusicEvent Function(String eventId) build,
) {
  final _Fraction timeSig = _timeSignatureOf(base);
  if (timeSig < eventDuration) {
    throw const MusicEditFailure('invalid_duration', '当前拍号放不下这个音符。');
  }
  final List<MusicMeasure> measures = List<MusicMeasure>.of(track.measures);
  final Set<String> usedIds = _eventIdsOf(base);

  _Fraction capacity;
  final _Fraction? remaining = timeSig.difference(_filledOf(measures.last));
  if (remaining != null && remaining >= eventDuration) {
    capacity = remaining;
  } else {
    if (measures.length >= musicMaxMeasuresPerTrack) {
      throw const MusicEditFailure(
        'score_too_large',
        '每条轨道最多 $musicMaxMeasuresPerTrack 个小节。',
      );
    }
    measures.add(
      MusicMeasure(id: _freshMeasureId(measures), events: const <MusicEvent>[]),
    );
    capacity = timeSig;
  }

  final MusicMeasure destination = measures.last;
  final List<MusicEvent> events = List<MusicEvent>.of(destination.events);
  events.add(build(_freshEventId(usedIds)));
  final _Fraction padding =
      capacity.difference(eventDuration) ?? _Fraction.zero;
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
  measures[measures.length - 1] = MusicMeasure(
    id: destination.id,
    events: events,
    extra: destination.extra,
  );
  return _accept(
    _copyScore(
      base,
      tracks: _replaceTrack(base, track, _copyTrack(track, measures: measures)),
    ),
  );
}

MusicTrack _trackOf(MusicScore score, String trackId) {
  for (final MusicTrack track in score.tracks) {
    if (track.id == trackId) return track;
  }
  throw const MusicEditFailure('unknown_track', '没有找到这条轨道，先刷新试试。');
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

List<MusicTrack> _replaceTrack(
  MusicScore score,
  MusicTrack target,
  MusicTrack replacement,
) {
  final List<MusicTrack> tracks = List<MusicTrack>.of(score.tracks);
  for (int i = 0; i < tracks.length; i++) {
    if (tracks[i].id == target.id) {
      tracks[i] = replacement;
      return tracks;
    }
  }
  return tracks;
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

  _Fraction operator -(_Fraction other) {
    final _Fraction? result = difference(other);
    if (result == null) {
      throw const MusicEditFailure('invalid_result', '时值相减出现负数。');
    }
    return result;
  }

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
