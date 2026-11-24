/// 音乐模块契约核心：`score.json` v1 解析 + `verifyScore` 硬门（纯 Dart）。
///
/// 事实源契约见 `docs/music-contract.md` §1/§3；未知字段保留、不静默丢弃；
/// 校验失败不阻断入库（调用方如实上报），本文件只做结构/语义检查。
/// 音高/时值保留记谱语义，播放 tick 由 `music_compile.dart` 编译。
library;

/// 一条校验问题（指针 + 稳定码 + 人话）。
final class MusicIssue {
  const MusicIssue(
    this.pointer,
    this.code,
    this.message, {
    this.blocking = true,
  });

  final String pointer;
  final String code;
  final String message;
  final bool blocking;

  Map<String, Object?> toJson() => <String, Object?>{
    'pointer': pointer,
    'code': code,
    'message': message,
    'blocking': blocking,
  };
}

/// 校验结果（`verified=false` 时调用方必须如实上报，不阻断入库）。
final class MusicValidation {
  const MusicValidation({required this.issues, required this.verified});

  final List<MusicIssue> issues;
  final bool verified;

  factory MusicValidation.from(List<MusicIssue> issues) => MusicValidation(
    issues: issues,
    verified: !issues.any((issue) => issue.blocking),
  );

  List<MusicIssue> get blockingIssues =>
      issues.where((issue) => issue.blocking).toList(growable: false);

  Map<String, Object?> toJson() => <String, Object?>{
    'verified': verified,
    'checks': blockingIssues
        .map((issue) => issue.toJson())
        .toList(growable: false),
  };
}

/// 一条音符/休止事件（保留未知字段）。
final class MusicEvent {
  const MusicEvent({
    required this.id,
    required this.isRest,
    required this.durNum,
    required this.durDen,
    this.step = '',
    this.alter = 0,
    this.octave = 4,
    this.dot = 0,
    this.tupletN = 0,
    this.tupletIn = 0,
    this.extra = const <String, Object?>{},
  });

  final String id;
  final bool isRest;
  final int durNum;
  final int durDen;
  final String step;
  final int alter;
  final int octave;
  final int dot;
  final int tupletN;
  final int tupletIn;
  final Map<String, Object?> extra;

  /// 实际时值（相对全音符；含附点/连音）。分母必须为正。
  double get durationValue {
    double value = durNum / durDen;
    if (dot == 1) value *= 1.5;
    if (tupletN > 0 && tupletIn > 0) value *= tupletIn / tupletN;
    return value;
  }

  Map<String, Object?> toJson() {
    final Map<String, Object?> out = <String, Object?>{
      'id': id,
      'dur': <String, Object?>{'num': durNum, 'den': durDen},
      ...extra,
    };
    if (isRest) {
      out['type'] = 'rest';
    } else {
      out['type'] = 'note';
      out['pitch'] = <String, Object?>{
        'step': step,
        'alter': alter,
        'octave': octave,
      };
      if (dot != 0) out['dot'] = dot;
      if (tupletN > 0) {
        out['tuplet'] = <String, Object?>{
          'n': tupletN,
          'in': tupletIn,
          'group': 1,
        };
      }
    }
    return out;
  }
}

/// 小节（空小节 = 整小节休止；保留未知字段）。
final class MusicMeasure {
  const MusicMeasure({
    required this.id,
    required this.events,
    this.extra = const <String, Object?>{},
  });

  final String id;
  final List<MusicEvent> events;
  final Map<String, Object?> extra;

  double get durationValue =>
      events.fold<double>(0, (sum, event) => sum + event.durationValue);

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    ...extra,
    if (events.isNotEmpty)
      'events': events.map((event) => event.toJson()).toList(growable: false),
  };
}

/// 一条轨道（≤8；鼓轨 instrument=drums）。
final class MusicTrack {
  const MusicTrack({
    required this.id,
    required this.name,
    required this.instrument,
    this.volume = 1.0,
    this.muted = false,
    this.clef = 'treble',
    required this.measures,
    this.extra = const <String, Object?>{},
  });

  final String id;
  final String name;
  final String instrument;
  final double volume;
  final bool muted;
  final String clef;
  final List<MusicMeasure> measures;
  final Map<String, Object?> extra;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'instrument': instrument,
    'volume': volume,
    'muted': muted,
    'clef': clef,
    'measures': measures
        .map((measure) => measure.toJson())
        .toList(growable: false),
    ...extra,
  };
}

/// 关系对象（Beam/Tie/Slur 引用稳定事件 ID）。
final class MusicRelation {
  const MusicRelation({
    required this.type,
    required this.id,
    required this.data,
  });

  final String type; // beam / tie / slur
  final String id;
  final Map<String, Object?> data;

  Map<String, Object?> toJson() => <String, Object?>{
    'type': type,
    'id': id,
    ...data,
  };
}

/// score.json 文档。
final class MusicScore {
  const MusicScore({
    this.schemaVersion = 1,
    required this.title,
    required this.tempo,
    required this.timeSig,
    required this.keySig,
    required this.tracks,
    this.relations = const <MusicRelation>[],
    this.extra = const <String, Object?>{},
  });

  final int schemaVersion;
  final String title;
  final int tempo;
  final List<int> timeSig;
  final String keySig;
  final List<MusicTrack> tracks;
  final List<MusicRelation> relations;
  final Map<String, Object?> extra;

  int get measureCount => tracks.isEmpty ? 0 : tracks.first.measures.length;

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': schemaVersion,
    'title': title,
    'tempo': tempo,
    'timeSig': <int>[...timeSig],
    'keySig': keySig,
    'tracks': tracks.map((track) => track.toJson()).toList(growable: false),
    if (relations.isNotEmpty)
      'relations': relations
          .map((relation) => relation.toJson())
          .toList(growable: false),
    ...extra,
  };
}

/// 解析入口：坏结构尽量收集问题；只有可构造出轨道的部分才进模型。
({MusicScore? score, List<MusicIssue> issues}) parseMusicScore(Object? raw) {
  final List<MusicIssue> issues = <MusicIssue>[];
  if (raw is! Map) {
    return (
      score: null,
      issues: <MusicIssue>[const MusicIssue('', 'score_invalid', '乐谱根节点必须是对象')],
    );
  }
  final Map<String, Object?> doc = Map<String, Object?>.from(raw);
  final int version = _intOr(doc['schemaVersion'], 0);
  if (version != 1) {
    issues.add(
      MusicIssue(
        '/schemaVersion',
        'score_unsupported_version',
        '只认 schemaVersion=1（读到 $version）',
      ),
    );
  }
  final String title = (doc['title'] ?? '').toString();
  final int tempo = _intOr(doc['tempo'], 0);
  if (tempo < 20 || tempo > 300) {
    issues.add(
      MusicIssue('/tempo', 'score_invalid', 'tempo 必须 ∈ [20,300]（读到 $tempo）'),
    );
  }
  final List<int> timeSig = _intList(doc['timeSig']);
  if (timeSig.length != 2 || timeSig[0] <= 0 || timeSig[1] <= 0) {
    issues.add(
      const MusicIssue('/timeSig', 'score_invalid', 'timeSig 必须是 [分子,分母] 正整数'),
    );
  }
  final String keySig = (doc['keySig'] ?? 'C').toString();
  final Object? rawTracks = doc['tracks'];
  final List<MusicTrack> tracks = <MusicTrack>[];
  final Set<String> trackIds = <String>{};
  final Map<String, String> eventTrack = <String, String>{};
  final Map<String, MusicEvent> eventsById = <String, MusicEvent>{};
  if (rawTracks is! List || rawTracks.isEmpty) {
    issues.add(const MusicIssue('/tracks', 'score_invalid', '至少需要一条轨道'));
  } else {
    if (rawTracks.length > 8) {
      issues.add(const MusicIssue('/tracks', 'score_too_large', '轨道最多 8 条'));
    }
    for (int ti = 0; ti < rawTracks.length; ti++) {
      final Object? rawTrack = rawTracks[ti];
      final String tp = '/tracks/$ti';
      if (rawTrack is! Map) {
        issues.add(MusicIssue(tp, 'score_invalid', '轨道具必须是对象'));
        continue;
      }
      final Map<String, Object?> trackMap = Map<String, Object?>.from(rawTrack);
      final String id = (trackMap['id'] ?? '').toString().trim();
      if (id.isEmpty || !trackIds.add(id)) {
        issues.add(MusicIssue('$tp/id', 'score_invalid', '轨道 id 必须非空且唯一'));
      }
      final String instrument = (trackMap['instrument'] ?? '').toString();
      if (!musicInstruments.contains(instrument)) {
        issues.add(
          MusicIssue(
            '$tp/instrument',
            'score_invalid',
            'instrument 必须是 ${musicInstruments.join('/')}（读到 $instrument）',
          ),
        );
      }
      final double volume = _doubleOr(trackMap['volume'], 1.0);
      if (volume < 0 || volume > 1) {
        issues.add(MusicIssue('$tp/volume', 'score_invalid', 'volume 必须在 0–1'));
      }
      final Object? rawMeasures = trackMap['measures'];
      final List<MusicMeasure> measures = <MusicMeasure>[];
      if (rawMeasures is! List || rawMeasures.isEmpty) {
        issues.add(MusicIssue('$tp/measures', 'score_invalid', '轨道至少需要一个小节'));
      } else {
        if (rawMeasures.length > 256) {
          issues.add(MusicIssue('$tp/measures', 'score_too_large', '小节最多 256'));
        }
        for (int mi = 0; mi < rawMeasures.length; mi++) {
          final Object? rawMeasure = rawMeasures[mi];
          final String mp = '$tp/measures/$mi';
          if (rawMeasure is! Map) {
            issues.add(MusicIssue(mp, 'score_invalid', '小节必须是对象'));
            continue;
          }
          final Map<String, Object?> measureMap = Map<String, Object?>.from(
            rawMeasure,
          );
          final String measureId = (measureMap['id'] ?? 'm${mi + 1}')
              .toString();
          final Object? rawEvents = measureMap['events'] ?? measureMap['notes'];
          final List<MusicEvent> events = <MusicEvent>[];
          if (rawEvents != null) {
            if (rawEvents is! List) {
              issues.add(
                MusicIssue('$mp/events', 'score_invalid', 'events 必须是数组'),
              );
            } else {
              for (int ei = 0; ei < rawEvents.length; ei++) {
                final MusicEvent? event = _parseEvent(
                  rawEvents[ei],
                  '$mp/events/$ei',
                  issues,
                );
                if (event == null) continue;
                if (!eventsById.containsKey(event.id)) {
                  eventsById[event.id] = event;
                  eventTrack[event.id] = id;
                } else {
                  issues.add(
                    MusicIssue(
                      '$mp/events/$ei/id',
                      'score_invalid',
                      '事件 id 重复：${event.id}',
                    ),
                  );
                }
                events.add(event);
              }
            }
          }
          // 小节容量：空小节 = 整小节休止；否则时值总和必须等于拍号。
          if (events.isNotEmpty && timeSig.length == 2) {
            final double expected = timeSig[0] / timeSig[1];
            if ((events.fold<double>(0, (sum, e) => sum + e.durationValue) -
                        expected)
                    .abs() >
                1e-9) {
              issues.add(
                MusicIssue(
                  '$mp/events',
                  'score_invalid',
                  '小节时值总和不等于拍号 ${timeSig[0]}/${timeSig[1]}',
                ),
              );
            }
          }
          measures.add(
            MusicMeasure(
              id: measureId,
              events: events,
              extra: _extra(measureMap, const <String>{
                'id',
                'events',
                'notes',
              }),
            ),
          );
        }
      }
      tracks.add(
        MusicTrack(
          id: id,
          name: (trackMap['name'] ?? id).toString(),
          instrument: instrument,
          volume: volume,
          muted: trackMap['muted'] == true,
          clef: (trackMap['clef'] ?? 'treble').toString(),
          measures: measures,
          extra: _extra(trackMap, const <String>{
            'id',
            'name',
            'instrument',
            'volume',
            'muted',
            'clef',
            'measures',
          }),
        ),
      );
    }
  }

  // 鼓轨音名检查（pitch 以字符串鼓件名表示时；对象写法按普通音高处理）。
  for (final track in tracks) {
    if (track.instrument != 'drums') continue;
    for (final measure in track.measures) {
      for (final event in measure.events) {
        if (event.isRest) continue;
        final Object? drum = event.extra['drum'];
        if (drum is String && !musicDrumNames.contains(drum)) {
          issues.add(
            MusicIssue('/tracks/${track.id}', 'score_invalid', '鼓件名不合法：$drum'),
          );
        }
      }
    }
  }

  // 关系对象：端点存在；tie 同音高；beam/slur 端点存在。
  final Object? rawRelations = doc['relations'];
  final List<MusicRelation> relations = <MusicRelation>[];
  if (rawRelations is List) {
    for (int ri = 0; ri < rawRelations.length; ri++) {
      final Object? rawRelation = rawRelations[ri];
      final String rp = '/relations/$ri';
      if (rawRelation is! Map) continue;
      final Map<String, Object?> relationMap = Map<String, Object?>.from(
        rawRelation,
      );
      final String type = (relationMap['type'] ?? '').toString();
      final String id = (relationMap['id'] ?? '').toString();
      if (!const <String>{'beam', 'tie', 'slur'}.contains(type)) {
        issues.add(
          MusicIssue('$rp/type', 'score_invalid', '关系类型只支持 beam/tie/slur'),
        );
      }
      if (type == 'tie') {
        final String from = (relationMap['from'] ?? '').toString();
        final String to = (relationMap['to'] ?? '').toString();
        final MusicEvent? a = eventsById[from];
        final MusicEvent? b = eventsById[to];
        if (a == null || b == null) {
          issues.add(MusicIssue(rp, 'score_invalid', 'tie 端点事件不存在'));
        } else if (a.step != b.step ||
            a.alter != b.alter ||
            a.octave != b.octave) {
          issues.add(MusicIssue(rp, 'score_invalid', 'tie 两端音高不一致'));
        }
      } else {
        final Object? refs = relationMap['events'];
        if (refs is List) {
          for (final ref in refs) {
            if (!eventsById.containsKey(ref.toString())) {
              issues.add(MusicIssue(rp, 'score_invalid', '关系引用了不存在的事件：$ref'));
            }
          }
        }
      }
      relations.add(
        MusicRelation(
          type: type,
          id: id,
          data: _extra(relationMap, const <String>{'type', 'id'}),
        ),
      );
    }
  }

  if (issues.any((issue) => issue.blocking)) {
    // 结构性失败仍返回可解析部分，便于调用方给指针；score 仅在无 error 时可靠。
    return (score: null, issues: issues);
  }
  return (
    score: MusicScore(
      schemaVersion: version,
      title: title,
      tempo: tempo,
      timeSig: timeSig,
      keySig: keySig,
      tracks: tracks,
      relations: relations,
      extra: _extra(doc, const <String>{
        'schemaVersion',
        'title',
        'tempo',
        'timeSig',
        'keySig',
        'tracks',
        'relations',
      }),
    ),
    issues: issues,
  );
}

/// 契约校验入口：解析 + 返回 `verified/checks`（不阻断入库）。
MusicValidation verifyMusicScore(Object? raw) {
  final ({MusicScore? score, List<MusicIssue> issues}) parsed = parseMusicScore(
    raw,
  );
  return MusicValidation.from(parsed.issues);
}

MusicEvent? _parseEvent(Object? raw, String pointer, List<MusicIssue> issues) {
  if (raw is! Map) {
    issues.add(MusicIssue(pointer, 'score_invalid', '事件必须是对象'));
    return null;
  }
  final Map<String, Object?> map = Map<String, Object?>.from(raw);
  final String id = (map['id'] ?? '').toString().trim();
  if (id.isEmpty) {
    issues.add(MusicIssue('$pointer/id', 'score_invalid', '事件 id 不能为空'));
  }
  final String type = (map['type'] ?? (map.containsKey('pitch') ? 'note' : ''))
      .toString();
  final bool isRest = type == 'rest';
  if (!isRest && type != 'note') {
    issues.add(
      MusicIssue('$pointer/type', 'score_invalid', '事件类型只支持 note/rest'),
    );
  }
  final Object? rawDur = map['dur'];
  final Map<String, Object?> dur = rawDur is Map
      ? Map<String, Object?>.from(rawDur)
      : <String, Object?>{};
  final int num = _intOr(dur['num'], 0);
  final int den = _intOr(dur['den'], 0);
  if (num <= 0 || den <= 0) {
    issues.add(MusicIssue('$pointer/dur', 'score_invalid', 'dur 必须是正有理数'));
  }
  final int dot = _intOr(map['dot'], 0);
  if (dot != 0 && dot != 1) {
    issues.add(MusicIssue('$pointer/dot', 'score_invalid', 'dot 只支持 0/1'));
  }
  String step = '';
  int alter = 0;
  int octave = 0;
  String? drum;
  final Object? rawPitch = map['pitch'];
  if (!isRest) {
    if (rawPitch is String) {
      drum = rawPitch;
    } else if (rawPitch is Map) {
      step = (rawPitch['step'] ?? '').toString().toUpperCase();
      alter = _intOr(rawPitch['alter'], 0);
      octave = _intOr(rawPitch['octave'], 0);
      if (!musicSteps.contains(step)) {
        issues.add(
          MusicIssue('$pointer/pitch/step', 'score_invalid', 'step 必须是 C–B'),
        );
      }
      if (alter < -1 || alter > 1) {
        issues.add(
          MusicIssue(
            '$pointer/pitch/alter',
            'score_invalid',
            'alter 必须在 -1..1',
          ),
        );
      }
      if (octave < 0 || octave > 9) {
        issues.add(
          MusicIssue(
            '$pointer/pitch/octave',
            'score_invalid',
            'octave 必须在 0..9',
          ),
        );
      }
    } else {
      issues.add(
        MusicIssue('$pointer/pitch', 'score_invalid', 'note 必须有 pitch'),
      );
    }
  }
  final Object? rawTuplet = map['tuplet'];
  int tupletN = 0;
  int tupletIn = 0;
  if (rawTuplet is Map) {
    tupletN = _intOr(rawTuplet['n'], 0);
    tupletIn = _intOr(rawTuplet['in'], 0);
    if (tupletN != 3 && tupletN != 5) {
      issues.add(
        MusicIssue('$pointer/tuplet', 'score_invalid', 'v1 只支持三/五连音（七连音拒绝）'),
      );
    }
    if (tupletIn <= 0) {
      issues.add(
        MusicIssue('$pointer/tuplet/in', 'score_invalid', 'tuplet.in 必须为正'),
      );
    }
  }
  final Map<String, Object?> extra = Map<String, Object?>.from(map);
  for (final key in <String>['id', 'type', 'dur', 'pitch', 'dot', 'tuplet']) {
    extra.remove(key);
  }
  return MusicEvent(
    id: id,
    isRest: isRest,
    durNum: num < 1 ? 1 : num,
    durDen: den < 1 ? 1 : den,
    step: step,
    alter: alter,
    octave: octave,
    dot: dot,
    tupletN: tupletN,
    tupletIn: tupletIn,
    extra: drum == null ? extra : <String, Object?>{'drum': drum, ...extra},
  );
}

Map<String, Object?> _extra(Map<String, Object?> source, Set<String> known) {
  final out = <String, Object?>{};
  for (final entry in source.entries) {
    if (!known.contains(entry.key)) out[entry.key] = entry.value;
  }
  return out;
}

int _intOr(Object? value, int fallback) =>
    value is num && value.isFinite ? value.toInt() : fallback;
double _doubleOr(Object? value, double fallback) =>
    value is num && value.isFinite ? value.toDouble() : fallback;
List<int> _intList(Object? value) {
  if (value is! List || value.length != 2) return const <int>[];
  final out = <int>[];
  for (final item in value) {
    if (item is! num || !item.isFinite) return const <int>[];
    out.add(item.toInt());
  }
  return out;
}

const Set<String> musicInstruments = <String>{
  'piano',
  'strings',
  'bass',
  'bell',
  'organ',
  'pluck',
  'drums',
};
const Set<String> musicSteps = <String>{'C', 'D', 'E', 'F', 'G', 'A', 'B'};
const Set<String> musicDrumNames = <String>{
  'kick',
  'snare',
  'hihat',
  'openhat',
  'crash',
  'ride',
  'tom',
};
