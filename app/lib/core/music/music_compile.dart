/// score.json → 整数 tick 的确定性编译（纯函数；ppq=3840）。
///
/// 契约见 `docs/music-contract.md` §2：四分音符 = 3840 tick；三/五连音
/// 必须落整数 tick（半分不取整），同一 score.json 两次编译字节相同。
library;

import 'dart:convert';

import 'music_score.dart';

/// 编译失败（精度/结构问题）；调用方必须显性回报。
final class MusicCompileError implements Exception {
  const MusicCompileError(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'MusicCompileError($code: $message)';
}

/// 编译后的播放事件（整数 tick；运行时不再有浮点拍点）。
final class MusicPlayEvent {
  const MusicPlayEvent({
    required this.trackId,
    required this.eventId,
    required this.isRest,
    required this.startTick,
    required this.durationTicks,
    required this.instrument,
    this.midi = 0,
    this.drum = '',
  });

  final String trackId;
  final String eventId;
  final bool isRest;
  final int startTick;
  final int durationTicks;
  final String instrument;
  final int midi;
  final String drum;

  Map<String, Object?> toJson() => <String, Object?>{
    'track': trackId,
    'event': eventId,
    'rest': isRest,
    'start': startTick,
    'dur': durationTicks,
    'instrument': instrument,
    if (!isRest && instrument == 'drums') 'drum': drum,
    if (!isRest && instrument != 'drums') 'midi': midi,
  };
}

/// 编译产物（字节确定性：toJson + 固定 key 顺序）。
final class MusicPlayPlan {
  const MusicPlayPlan({
    required this.ppq,
    required this.tempoMap,
    required this.tracks,
    required this.events,
    required this.totalTicks,
  });

  static const int defaultPpq = 3840;

  final int ppq;
  final List<Map<String, int>> tempoMap;
  final List<String> tracks;
  final List<MusicPlayEvent> events;
  final int totalTicks;

  Map<String, Object?> toJson() => <String, Object?>{
    'schema': 'nan.music.playplan/1',
    'ppq': ppq,
    'tempoMap': tempoMap
        .map(
          (entry) => <String, Object?>{
            'tick': entry['tick'],
            'bpm': entry['bpm'],
          },
        )
        .toList(growable: false),
    'tracks': tracks,
    'events': events.map((event) => event.toJson()).toList(growable: false),
    'totalTicks': totalTicks,
  };

  String toJsonString() => jsonEncode(toJson());
}

/// 把合法 score 编译成 [MusicPlayPlan]；不合法/精度不足抛 [MusicCompileError]。
MusicPlayPlan compileMusicScore(MusicScore score) {
  final List<MusicPlayEvent> out = <MusicPlayEvent>[];
  final List<Map<String, int>> tempoMap = <Map<String, int>>[
    <String, int>{'tick': 0, 'bpm': score.tempo},
  ];
  int totalTicks = 0;
  for (final MusicTrack track in score.tracks) {
    int cursor = 0;
    for (final MusicMeasure measure in track.measures) {
      for (final MusicEvent event in measure.events) {
        final int ticks = _ticksFor(event, MusicPlayPlan.defaultPpq);
        if (event.isRest) {
          out.add(
            MusicPlayEvent(
              trackId: track.id,
              eventId: event.id,
              isRest: true,
              startTick: cursor,
              durationTicks: ticks,
              instrument: track.instrument,
            ),
          );
        } else {
          if (track.instrument == 'drums') {
            final String drum = (event.extra['drum'] ?? '').toString();
            if (!musicDrumNames.contains(drum)) {
              throw MusicCompileError(
                'score_invalid',
                '鼓轨事件必须给合法鼓件名：${event.id}',
              );
            }
            out.add(
              MusicPlayEvent(
                trackId: track.id,
                eventId: event.id,
                isRest: false,
                startTick: cursor,
                durationTicks: ticks,
                instrument: track.instrument,
                drum: drum,
              ),
            );
          } else {
            out.add(
              MusicPlayEvent(
                trackId: track.id,
                eventId: event.id,
                isRest: false,
                startTick: cursor,
                durationTicks: ticks,
                instrument: track.instrument,
                midi: _midiOf(event),
              ),
            );
          }
        }
        cursor += ticks;
      }
    }
    if (cursor > totalTicks) totalTicks = cursor;
  }
  return MusicPlayPlan(
    ppq: MusicPlayPlan.defaultPpq,
    tempoMap: tempoMap,
    tracks: score.tracks.map((track) => track.id).toList(growable: false),
    events: out,
    totalTicks: totalTicks,
  );
}

int _ticksFor(MusicEvent event, int ppq) {
  final int dotFactor = event.dot == 1 ? 3 : 1;
  final int dotDen = event.dot == 1 ? 2 : 1;
  final int tupletN = event.tupletN > 0 ? event.tupletN : 1;
  final int tupletIn = event.tupletIn > 0 ? event.tupletIn : 1;
  final int numerator = ppq * 4 * event.durNum * dotFactor * tupletIn;
  final int denominator = event.durDen * dotDen * tupletN;
  if (denominator <= 0 || numerator % denominator != 0) {
    throw MusicCompileError(
      'score_tuplet_precision',
      '事件 ${event.id} 的时值无法落整数 tick（三分/五分连音精度不足）',
    );
  }
  return numerator ~/ denominator;
}

int _midiOf(MusicEvent event) {
  const Map<String, int> stepSemitones = <String, int>{
    'C': 0,
    'D': 2,
    'E': 4,
    'F': 5,
    'G': 7,
    'A': 9,
    'B': 11,
  };
  final int semitone = stepSemitones[event.step] ?? 0;
  return (event.octave + 1) * 12 + semitone + event.alter;
}
