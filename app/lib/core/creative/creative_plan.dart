/// `creative.plan.json`：精确数字 + acceptance 的计划契约（3D / 视频两条）。
///
/// 契约见 `docs/skills/creative-workbench/references/schemas.md` §2。plan 是门与
/// 盲评测量对象的契约：**先校验 plan，再写 src**（SKILL §5 第 3 步）。本文件只做
/// 解析与校验，不执行任何渲染/引擎逻辑。
library;

import 'creative_schema.dart';

/// 计划公共头。3D / 视频各自扩展。
sealed class CreativePlan {
  const CreativePlan({
    required this.summary,
    required this.acceptance,
    this.risks = const <String>[],
    this.extra = const <String, Object?>{},
  });

  final String summary;
  final List<String> acceptance;
  final List<String> risks;
  final Map<String, Object?> extra;

  CreativeKind get kind;

  static const Set<String> commonKeys = <String>{
    'schema',
    'kind',
    'summary',
    'acceptance',
    'risks',
  };

  /// 按 `kind` 分派解析。schema/kind 缺失时 `value == null`。
  static CreativeParseResult<CreativePlan> parse(Object? raw) {
    final CreativeValidation validation = CreativeValidation();
    final Map<String, Object?>? map = creativeJsonMap(raw);
    if (map == null) {
      validation.add('', 'plan_not_object', 'plan.json 必须是 JSON 对象');
      return CreativeParseResult<CreativePlan>(null, validation);
    }
    if (map['schema'] != creativePlanSchema) {
      validation.add(
        '/schema',
        'plan_schema_mismatch',
        'schema 必须是 $creativePlanSchema',
      );
    }
    final String? kind = creativeNonEmptyString(map['kind']);
    if (kind == '3d') {
      final CreativePlan3d? plan = _parse3d(map, validation);
      return CreativeParseResult<CreativePlan>(plan, validation);
    }
    if (kind == 'video') {
      final CreativePlanVideo? plan = _parseVideo(map, validation);
      return CreativeParseResult<CreativePlan>(plan, validation);
    }
    validation.add('/kind', 'plan_kind_invalid', 'kind 必须是 3d/video');
    return CreativeParseResult<CreativePlan>(null, validation);
  }

  Map<String, Object?> toJson();
}

/// 3D 计划（`static_object` / `scene` / `graphics`）。
final class CreativePlan3d extends CreativePlan {
  const CreativePlan3d({
    required super.summary,
    required super.acceptance,
    super.risks,
    super.extra,
    required this.track,
    required this.language,
    this.parts = const <CreativePlanPart>[],
    this.zones = const <Map<String, Object?>>[],
    this.placements = const <Map<String, Object?>>[],
    this.lights = const <Map<String, Object?>>[],
    this.cameras = const <Map<String, Object?>>[],
    this.motion,
  });

  final CreativeTrack track;

  /// `threejs` / `scene_threejs` / `glsl_shader`。
  final String language;
  final List<CreativePlanPart> parts;

  /// 场景轨：分区、摆放、灯、相机保留为通过校验的原始 JSON（R3 升级为类型化）。
  final List<Map<String, Object?>> zones;
  final List<Map<String, Object?>> placements;
  final List<Map<String, Object?>> lights;
  final List<Map<String, Object?>> cameras;

  /// 运动段；R0 原样透传（结构在 R3 定）。
  final Object? motion;

  static const Set<String> knownKeys = <String>{
    ...CreativePlan.commonKeys,
    'track',
    'language',
    'parts',
    'zones',
    'placements',
    'lights',
    'cameras',
    'motion',
  };

  static const List<String> languages = <String>[
    'threejs',
    'scene_threejs',
    'glsl_shader',
  ];

  @override
  CreativeKind get kind => CreativeKind.threeD;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'schema': creativePlanSchema,
    'kind': '3d',
    'track': track.wire,
    'language': language,
    'summary': summary,
    'acceptance': acceptance,
    if (risks.isNotEmpty) 'risks': risks,
    if (parts.isNotEmpty)
      'parts': parts
          .map((CreativePlanPart part) => part.toJson())
          .toList(growable: false),
    if (zones.isNotEmpty) 'zones': zones,
    if (placements.isNotEmpty) 'placements': placements,
    if (lights.isNotEmpty) 'lights': lights,
    if (cameras.isNotEmpty) 'cameras': cameras,
    if (motion != null) 'motion': motion,
    ...extra,
  };
}

/// 视频计划：镜头表 + 节拍网格；事件里 `vfx` 的 cue 由 R0 只做非空校验，
/// allowlist 在 pixelfx 编译期（5c）才是硬门。
final class CreativePlanVideo extends CreativePlan {
  const CreativePlanVideo({
    required super.summary,
    required super.acceptance,
    super.risks,
    super.extra,
    required this.track,
    this.fps = creativeVideoFps,
    required this.durationFrames,
    this.beats,
    this.shots = const <CreativePlanShot>[],
  });

  final CreativeTrack track;
  final int fps;
  final int durationFrames;
  final CreativePlanBeats? beats;
  final List<CreativePlanShot> shots;

  static const Set<String> knownKeys = <String>{
    ...CreativePlan.commonKeys,
    'track',
    'fps',
    'durationFrames',
    'beats',
    'shots',
  };

  @override
  CreativeKind get kind => CreativeKind.video;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'schema': creativePlanSchema,
    'kind': 'video',
    'track': track.wire,
    'fps': fps,
    'durationFrames': durationFrames,
    if (beats != null) 'beats': beats!.toJson(),
    'summary': summary,
    'acceptance': acceptance,
    if (risks.isNotEmpty) 'risks': risks,
    'shots': shots
        .map((CreativePlanShot shot) => shot.toJson())
        .toList(growable: false),
    ...extra,
  };
}

/// 3D 部件：尺寸/材质/父级/包围盒中心都是门要测量的数字。
final class CreativePlanPart {
  const CreativePlanPart({
    required this.id,
    required this.dimsM,
    required this.material,
    this.parent,
    this.bboxCenterM,
    this.fixed = false,
    this.extra = const <String, Object?>{},
  });

  final String id;

  /// 三轴尺寸（米）。
  final List<double> dimsM;
  final String material;
  final String? parent;
  final List<double>? bboxCenterM;

  /// `fixed` 部件禁止被重命名/移动/删除（3dcodeverse fixed parts 门）。
  final bool fixed;
  final Map<String, Object?> extra;

  static const Set<String> knownKeys = <String>{
    'id',
    'dims_m',
    'material',
    'parent',
    'bbox_center_m',
    'fixed',
  };

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'dims_m': dimsM,
    'material': material,
    if (parent != null) 'parent': parent,
    if (bboxCenterM != null) 'bbox_center_m': bboxCenterM,
    if (fixed) 'fixed': true,
    ...extra,
  };
}

/// 节拍网格（视频配乐/剪辑依据）。
final class CreativePlanBeats {
  const CreativePlanBeats({
    required this.bpm,
    this.beatsPerBar = 4,
    this.offsetFrames = 0,
    this.extra = const <String, Object?>{},
  });

  final double bpm;
  final int beatsPerBar;
  final int offsetFrames;
  final Map<String, Object?> extra;

  static const Set<String> knownKeys = <String>{
    'bpm',
    'beatsPerBar',
    'offsetFrames',
  };

  Map<String, Object?> toJson() => <String, Object?>{
    'bpm': bpm,
    'beatsPerBar': beatsPerBar,
    'offsetFrames': offsetFrames,
    ...extra,
  };
}

/// 镜头。`camera` / `caption` / `transitionIn` 保留为通过校验的原始 JSON
/// （R4 的播放器编译期再收窄为类型）。
final class CreativePlanShot {
  const CreativePlanShot({
    required this.id,
    required this.start,
    required this.duration,
    this.camera,
    this.cast = const <CreativePlanCast>[],
    this.events = const <CreativePlanEvent>[],
    this.caption,
    this.transitionIn,
    this.extra = const <String, Object?>{},
  });

  final String id;

  /// 镜头起始帧（整数）。
  final int start;

  /// 镜头持续帧数（> 0）。
  final int duration;
  final Map<String, Object?>? camera;
  final List<CreativePlanCast> cast;
  final List<CreativePlanEvent> events;
  final Map<String, Object?>? caption;
  final Map<String, Object?>? transitionIn;
  final Map<String, Object?> extra;

  int get end => start + duration;

  static const Set<String> knownKeys = <String>{
    'id',
    'start',
    'duration',
    'camera',
    'cast',
    'events',
    'caption',
    'transitionIn',
  };

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'start': start,
    'duration': duration,
    if (camera != null) 'camera': camera,
    if (cast.isNotEmpty)
      'cast': cast
          .map((CreativePlanCast item) => item.toJson())
          .toList(growable: false),
    if (events.isNotEmpty)
      'events': events
          .map((CreativePlanEvent event) => event.toJson())
          .toList(growable: false),
    if (caption != null) 'caption': caption,
    if (transitionIn != null) 'transitionIn': transitionIn,
    ...extra,
  };
}

/// 镜头里的角色实例（`rig` 指向 cutout 木偶，x/y 为舞台坐标）。
final class CreativePlanCast {
  const CreativePlanCast({
    required this.id,
    required this.x,
    required this.y,
    this.rig,
    this.scale = 1,
    this.flip = false,
    this.z,
    this.extra = const <String, Object?>{},
  });

  final String id;
  final double x;
  final double y;
  final String? rig;
  final double scale;
  final bool flip;
  final int? z;
  final Map<String, Object?> extra;

  static const Set<String> knownKeys = <String>{
    'id',
    'rig',
    'x',
    'y',
    'scale',
    'flip',
    'z',
  };

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    if (rig != null) 'rig': rig,
    'x': x,
    'y': y,
    'scale': scale,
    'flip': flip,
    if (z != null) 'z': z,
    ...extra,
  };
}

/// 镜头内事件：`vfx`（pixelfx cue）、`sfx`（音效 cue）、`camera.shake`。
final class CreativePlanEvent {
  const CreativePlanEvent({
    required this.frame,
    required this.type,
    this.cue,
    this.x,
    this.y,
    this.scale = 1,
    this.flip = false,
    this.seed,
    this.layer,
    this.palette = const <String>[],
    this.light,
    this.amp,
    this.freq,
    this.duration,
    this.extra = const <String, Object?>{},
  });

  final int frame;
  final String type;
  final String? cue;
  final double? x;
  final double? y;
  final double scale;
  final bool flip;
  final int? seed;

  /// `front` / `back`（VFX 分层）。
  final String? layer;
  final List<String> palette;
  final double? light;

  /// `camera.shake` 的参数。
  final double? amp;
  final double? freq;
  final int? duration;
  final Map<String, Object?> extra;

  static const Set<String> knownKeys = <String>{
    'f',
    'type',
    'cue',
    'x',
    'y',
    'scale',
    'flip',
    'seed',
    'layer',
    'palette',
    'light',
    'amp',
    'freq',
    'dur',
  };

  static const Set<String> types = <String>{'vfx', 'sfx', 'camera.shake'};
  static const Set<String> layers = <String>{'front', 'back'};

  Map<String, Object?> toJson() => <String, Object?>{
    'f': frame,
    'type': type,
    if (cue != null) 'cue': cue,
    if (x != null) 'x': x,
    if (y != null) 'y': y,
    if (scale != 1) 'scale': scale,
    if (flip) 'flip': true,
    if (seed != null) 'seed': seed,
    if (layer != null) 'layer': layer,
    if (palette.isNotEmpty) 'palette': palette,
    if (light != null) 'light': light,
    if (amp != null) 'amp': amp,
    if (freq != null) 'freq': freq,
    if (duration != null) 'dur': duration,
    ...extra,
  };
}

// ============================================================
// 解析
// ============================================================

CreativePlan3d? _parse3d(
  Map<String, Object?> map,
  CreativeValidation validation,
) {
  final _CommonPlan common = _parseCommon(map, validation);
  final CreativeTrack? track = creativeEnumByWire(
    CreativeTrack.values,
    (CreativeTrack value) => value.wire,
    map['track'],
  );
  if (track == null || !track.isThreeD) {
    validation.add(
      '/track',
      'plan_track_invalid',
      '3D plan 的 track 必须是 static_object/scene/graphics',
    );
  }
  final String? language = creativeNonEmptyString(map['language']);
  if (language == null || !CreativePlan3d.languages.contains(language)) {
    validation.add(
      '/language',
      'plan_language_invalid',
      'language 必须是 ${CreativePlan3d.languages.join('/')}',
    );
  } else if (track != null) {
    final String expected = switch (track) {
      CreativeTrack.staticObject => 'threejs',
      CreativeTrack.scene => 'scene_threejs',
      CreativeTrack.graphics => 'glsl_shader',
      _ => language,
    };
    if (language != expected) {
      validation.add(
        '/language',
        'plan_language_track_mismatch',
        '${track.wire} 应使用 $expected',
      );
    }
  }

  final List<CreativePlanPart> parts = _parseParts(map['parts'], validation);
  if (parts.isEmpty && map['parts'] == null) {
    validation.add(
      '/parts',
      'plan_parts_missing',
      'plan 必须给 parts（精确尺寸/材质/父级）',
    );
  }

  final List<Map<String, Object?>> zones = _parseObjectList(
    map['zones'],
    '/zones',
    validation,
  );
  _validateZones(zones, validation);
  final List<Map<String, Object?>> placements = _parseObjectList(
    map['placements'],
    '/placements',
    validation,
  );
  _validatePlacements(placements, zones, validation);
  final List<Map<String, Object?>> lights = _parseObjectList(
    map['lights'],
    '/lights',
    validation,
  );
  _validateLights(lights, validation);
  final List<Map<String, Object?>> cameras = _parseObjectList(
    map['cameras'],
    '/cameras',
    validation,
  );
  _validateCameras(cameras, validation);
  if (track == CreativeTrack.scene && cameras.isEmpty) {
    validation.warn(
      '/cameras',
      'plan_cameras_missing',
      'scene 轨建议给作者相机（盲评取证需要）',
    );
  }

  final Map<String, Object?> extra = _collectExtras(
    map,
    CreativePlan3d.knownKeys,
  );
  if (common.summary == null || track == null || language == null) {
    return null;
  }
  return CreativePlan3d(
    summary: common.summary!,
    acceptance: common.acceptance,
    risks: common.risks,
    extra: extra,
    track: track,
    language: language,
    parts: parts,
    zones: zones,
    placements: placements,
    lights: lights,
    cameras: cameras,
    motion: map['motion'],
  );
}

CreativePlanVideo? _parseVideo(
  Map<String, Object?> map,
  CreativeValidation validation,
) {
  final _CommonPlan common = _parseCommon(map, validation);
  final CreativeTrack? track = creativeEnumByWire(
    CreativeTrack.values,
    (CreativeTrack value) => value.wire,
    map['track'],
  );
  if (track == null || !track.isVideo) {
    validation.add(
      '/track',
      'plan_track_invalid',
      '视频 plan 的 track 必须是 silly_skit/line_toon/ink_line',
    );
  }
  final int? fps = creativeInt(map['fps']);
  if (fps != creativeVideoFps) {
    validation.add(
      '/fps',
      'plan_fps_unsupported',
      'v1 只支持 $creativeVideoFps fps',
    );
  }
  final int? durationFrames = creativeInt(map['durationFrames']);
  if (durationFrames == null || durationFrames <= 0) {
    validation.add(
      '/durationFrames',
      'plan_duration_frames_invalid',
      'durationFrames 必须是正整数',
    );
  }

  CreativePlanBeats? beats;
  if (map['beats'] != null) {
    beats = _parseBeats(map['beats'], validation);
  }

  final List<CreativePlanShot> shots = _parseShots(
    map['shots'],
    durationFrames,
    validation,
  );
  if (shots.isEmpty && map['shots'] == null) {
    validation.add('/shots', 'plan_shots_missing', 'plan 必须给 shots（镜头/时间/事件）');
  }
  _validateShotTimeline(shots, durationFrames, validation);

  final Map<String, Object?> extra = _collectExtras(
    map,
    CreativePlanVideo.knownKeys,
  );
  if (common.summary == null || track == null || durationFrames == null) {
    return null;
  }
  return CreativePlanVideo(
    summary: common.summary!,
    acceptance: common.acceptance,
    risks: common.risks,
    extra: extra,
    track: track,
    fps: fps ?? creativeVideoFps,
    durationFrames: durationFrames,
    beats: beats,
    shots: shots,
  );
}

class _CommonPlan {
  const _CommonPlan(this.summary, this.acceptance, this.risks);

  final String? summary;
  final List<String> acceptance;
  final List<String> risks;
}

_CommonPlan _parseCommon(
  Map<String, Object?> map,
  CreativeValidation validation,
) {
  final String? summary = creativeNonEmptyString(map['summary']);
  if (summary == null) {
    validation.add('/summary', 'plan_summary_missing', 'summary 不能为空');
  }
  final List<String> acceptance = _parseStringList(
    map['acceptance'],
    '/acceptance',
    validation,
  );
  if (acceptance.isEmpty) {
    validation.add(
      '/acceptance',
      'plan_acceptance_missing',
      'acceptance 必须是非空的可观测项清单',
    );
  }
  final List<String> risks = _parseStringList(
    map['risks'],
    '/risks',
    validation,
  );
  return _CommonPlan(summary, acceptance, risks);
}

List<CreativePlanPart> _parseParts(Object? raw, CreativeValidation validation) {
  final List<Object?>? list = creativeJsonList(raw);
  if (list == null) return const <CreativePlanPart>[];
  final List<CreativePlanPart> parts = <CreativePlanPart>[];
  final Set<String> ids = <String>{};
  for (int i = 0; i < list.length; i++) {
    final String pointer = creativeIndexPointer('/parts', i);
    final Map<String, Object?>? map = creativeJsonMap(list[i]);
    if (map == null) {
      validation.add(pointer, 'plan_part_invalid', 'part 必须是对象');
      continue;
    }
    final String? id = creativeNonEmptyString(map['id']);
    if (id == null || !creativeIsSnakeCase(id)) {
      validation.add(
        '$pointer/id',
        'plan_part_id_invalid',
        'id 必须是 ASCII snake_case',
      );
    } else if (!ids.add(id)) {
      validation.add('$pointer/id', 'plan_part_id_duplicate', 'part id 重复：$id');
    }
    final List<double> dims = _parseVec3(
      map['dims_m'],
      '$pointer/dims_m',
      validation,
    );
    if (dims.any((double value) => value <= 0)) {
      validation.add(
        '$pointer/dims_m',
        'plan_part_dims_invalid',
        'dims 必须是有限正数',
      );
    }
    final String? material = creativeNonEmptyString(map['material']);
    if (material == null) {
      validation.add(
        '$pointer/material',
        'plan_part_material_invalid',
        'material 不能为空',
      );
    }
    final Object? parentRaw = map['parent'];
    String? parent;
    if (parentRaw != null) {
      parent = creativeNonEmptyString(parentRaw);
      if (parent == null || !creativeIsSnakeCase(parent)) {
        validation.add(
          '$pointer/parent',
          'plan_part_parent_invalid',
          'parent 必须是合法 part id 或 null',
        );
      }
    }
    List<double>? bboxCenter;
    if (map['bbox_center_m'] != null) {
      bboxCenter = _parseVec3(
        map['bbox_center_m'],
        '$pointer/bbox_center_m',
        validation,
      );
    }
    final Object? fixedRaw = map['fixed'];
    if (fixedRaw != null && fixedRaw is! bool) {
      validation.add(
        '$pointer/fixed',
        'plan_part_fixed_invalid',
        'fixed 必须是布尔',
      );
    }
    if (id == null) continue;
    parts.add(
      CreativePlanPart(
        id: id,
        dimsM: dims,
        material: material ?? '',
        parent: parent,
        bboxCenterM: bboxCenter,
        fixed: creativeBoolOr(fixedRaw, fallback: false),
        extra: _collectExtras(map, CreativePlanPart.knownKeys),
      ),
    );
  }
  // parent 必须指向存在的 part（在收齐 id 之后检查）。
  for (int i = 0; i < parts.length; i++) {
    final CreativePlanPart part = parts[i];
    final String? parent = part.parent;
    if (parent != null && !ids.contains(parent)) {
      validation.add(
        '${creativeIndexPointer('/parts', i)}/parent',
        'plan_part_parent_missing',
        'part ${part.id} 的 parent $parent 不存在',
      );
    }
  }
  return parts;
}

List<Map<String, Object?>> _parseObjectList(
  Object? raw,
  String pointer,
  CreativeValidation validation,
) {
  if (raw == null) return const <Map<String, Object?>>[];
  final List<Object?>? list = creativeJsonList(raw);
  if (list == null) {
    validation.add(pointer, 'plan_list_invalid', '必须是对象数组');
    return const <Map<String, Object?>>[];
  }
  final List<Map<String, Object?>> out = <Map<String, Object?>>[];
  for (int i = 0; i < list.length; i++) {
    final Map<String, Object?>? map = creativeJsonMap(list[i]);
    if (map == null) {
      validation.add(
        creativeIndexPointer(pointer, i),
        'plan_object_invalid',
        '必须是对象',
      );
      continue;
    }
    out.add(map);
  }
  return out;
}

void _validateZones(
  List<Map<String, Object?>> zones,
  CreativeValidation validation,
) {
  final Set<String> ids = <String>{};
  for (int i = 0; i < zones.length; i++) {
    final Map<String, Object?> zone = zones[i];
    final String pointer = creativeIndexPointer('/zones', i);
    final String? id = creativeNonEmptyString(zone['id']);
    if (id == null || !creativeIsSnakeCase(id)) {
      validation.add(
        '$pointer/id',
        'plan_zone_id_invalid',
        'zone id 必须是 ASCII snake_case',
      );
    } else if (!ids.add(id)) {
      validation.add('$pointer/id', 'plan_zone_id_duplicate', 'zone id 重复：$id');
    }
    _parseVec3(zone['bounds_m'], '$pointer/bounds_m', validation);
  }
}

void _validatePlacements(
  List<Map<String, Object?>> placements,
  List<Map<String, Object?>> zones,
  CreativeValidation validation,
) {
  final Set<String> zoneIds = <String>{
    for (final Map<String, Object?> zone in zones)
      if (creativeNonEmptyString(zone['id']) case final String id) id,
  };
  final Set<String> ids = <String>{};
  for (int i = 0; i < placements.length; i++) {
    final Map<String, Object?> placement = placements[i];
    final String pointer = creativeIndexPointer('/placements', i);
    final String? id = creativeNonEmptyString(placement['id']);
    if (id == null || !creativeIsSnakeCase(id)) {
      validation.add(
        '$pointer/id',
        'plan_placement_id_invalid',
        'placement id 必须是 ASCII snake_case',
      );
    } else if (!ids.add(id)) {
      validation.add(
        '$pointer/id',
        'plan_placement_id_duplicate',
        'placement id 重复：$id',
      );
    }
    final String? zone = creativeNonEmptyString(placement['zone']);
    if (zone == null) {
      validation.add(
        '$pointer/zone',
        'plan_placement_zone_invalid',
        'zone 不能为空',
      );
    } else if (!zoneIds.contains(zone)) {
      validation.add(
        '$pointer/zone',
        'plan_placement_zone_missing',
        'zone $zone 不存在',
      );
    }
    _parseVec3(placement['at_m'], '$pointer/at_m', validation);
  }
}

void _validateLights(
  List<Map<String, Object?>> lights,
  CreativeValidation validation,
) {
  final Set<String> ids = <String>{};
  for (int i = 0; i < lights.length; i++) {
    final Map<String, Object?> light = lights[i];
    final String pointer = creativeIndexPointer('/lights', i);
    final String? id = creativeNonEmptyString(light['id']);
    if (id == null || !creativeIsSnakeCase(id)) {
      validation.add(
        '$pointer/id',
        'plan_light_id_invalid',
        'light id 必须是 ASCII snake_case',
      );
    } else if (!ids.add(id)) {
      validation.add(
        '$pointer/id',
        'plan_light_id_duplicate',
        'light id 重复：$id',
      );
    }
    if (creativeNonEmptyString(light['type']) == null) {
      validation.add('$pointer/type', 'plan_light_invalid', 'light.type 不能为空');
    }
    if (light['color'] != null && !creativeIsHexColor(light['color'])) {
      validation.add(
        '$pointer/color',
        'plan_light_color_invalid',
        'light.color 必须是 #rrggbb',
      );
    }
    if (light['intensity'] != null &&
        creativeFiniteDouble(light['intensity']) == null) {
      validation.add(
        '$pointer/intensity',
        'plan_light_invalid',
        'intensity 必须是有限数字',
      );
    }
  }
}

void _validateCameras(
  List<Map<String, Object?>> cameras,
  CreativeValidation validation,
) {
  final Set<String> ids = <String>{};
  for (int i = 0; i < cameras.length; i++) {
    final Map<String, Object?> camera = cameras[i];
    final String pointer = creativeIndexPointer('/cameras', i);
    final String? id = creativeNonEmptyString(camera['id']);
    if (id == null || !creativeIsSnakeCase(id)) {
      validation.add(
        '$pointer/id',
        'plan_camera_id_invalid',
        'camera id 必须是 ASCII snake_case',
      );
    } else if (!ids.add(id)) {
      validation.add(
        '$pointer/id',
        'plan_camera_id_duplicate',
        'camera id 重复：$id',
      );
    }
    _parseVec3(camera['at_m'], '$pointer/at_m', validation);
    _parseVec3(camera['look_at_m'], '$pointer/look_at_m', validation);
  }
}

CreativePlanBeats? _parseBeats(Object? raw, CreativeValidation validation) {
  final Map<String, Object?>? map = creativeJsonMap(raw);
  if (map == null) {
    validation.add('/beats', 'plan_beats_invalid', 'beats 必须是对象');
    return null;
  }
  final double? bpm = creativeFiniteDouble(map['bpm']);
  if (bpm == null || bpm <= 0) {
    validation.add('/beats/bpm', 'plan_beats_bpm_invalid', 'bpm 必须是有限正数');
  }
  final int? beatsPerBar = creativeInt(map['beatsPerBar']);
  if (beatsPerBar == null || beatsPerBar < 1) {
    validation.add(
      '/beats/beatsPerBar',
      'plan_beats_per_bar_invalid',
      'beatsPerBar 必须是正整数',
    );
  }
  final int? offsetFrames = creativeInt(map['offsetFrames']);
  if (offsetFrames == null) {
    validation.add(
      '/beats/offsetFrames',
      'plan_beats_offset_invalid',
      'offsetFrames 必须是整数',
    );
  }
  return CreativePlanBeats(
    bpm: bpm ?? 0,
    beatsPerBar: beatsPerBar ?? 4,
    offsetFrames: offsetFrames ?? 0,
    extra: _collectExtras(map, CreativePlanBeats.knownKeys),
  );
}

List<CreativePlanShot> _parseShots(
  Object? raw,
  int? durationFrames,
  CreativeValidation validation,
) {
  final List<Object?>? list = creativeJsonList(raw);
  if (list == null) return const <CreativePlanShot>[];
  final List<CreativePlanShot> shots = <CreativePlanShot>[];
  final Set<String> ids = <String>{};
  for (int i = 0; i < list.length; i++) {
    final String pointer = creativeIndexPointer('/shots', i);
    final Map<String, Object?>? map = creativeJsonMap(list[i]);
    if (map == null) {
      validation.add(pointer, 'plan_shot_invalid', 'shot 必须是对象');
      continue;
    }
    final String? id = creativeNonEmptyString(map['id']);
    if (id == null || !creativeIsSnakeCase(id)) {
      validation.add(
        '$pointer/id',
        'plan_shot_id_invalid',
        'shot id 必须是 ASCII snake_case',
      );
    } else if (!ids.add(id)) {
      validation.add('$pointer/id', 'plan_shot_id_duplicate', 'shot id 重复：$id');
    }
    final int? start = creativeInt(map['start']);
    if (start == null || start < 0) {
      validation.add(
        '$pointer/start',
        'plan_shot_start_invalid',
        'start 必须是 ≥0 的整数帧',
      );
    }
    final int? duration = creativeInt(map['duration']);
    if (duration == null || duration <= 0) {
      validation.add(
        '$pointer/duration',
        'plan_shot_duration_invalid',
        'duration 必须是正整数帧',
      );
    }
    if (durationFrames != null &&
        start != null &&
        duration != null &&
        start + duration > durationFrames) {
      validation.add(pointer, 'plan_shot_out_of_range', '镜头超出 durationFrames');
    }
    final Map<String, Object?>? camera = map['camera'] == null
        ? null
        : creativeJsonMap(map['camera']);
    if (map['camera'] != null && camera == null) {
      validation.add(
        '$pointer/camera',
        'plan_shot_camera_invalid',
        'camera 必须是对象',
      );
    }
    final List<CreativePlanCast> cast = _parseCast(
      map['cast'],
      '$pointer/cast',
      validation,
    );
    final List<CreativePlanEvent> events = _parseEvents(
      map['events'],
      '$pointer/events',
      duration,
      validation,
    );
    Map<String, Object?>? caption;
    if (map['caption'] != null) {
      caption = creativeJsonMap(map['caption']);
      if (caption == null) {
        validation.add(
          '$pointer/caption',
          'plan_caption_invalid',
          'caption 必须是对象',
        );
      } else if (creativeNonEmptyString(caption['text']) == null) {
        validation.add(
          '$pointer/caption/text',
          'plan_caption_invalid',
          'caption.text 不能为空',
        );
      }
    }
    Map<String, Object?>? transitionIn;
    if (map['transitionIn'] != null) {
      transitionIn = creativeJsonMap(map['transitionIn']);
      if (transitionIn == null) {
        validation.add(
          '$pointer/transitionIn',
          'plan_transition_invalid',
          'transitionIn 必须是对象',
        );
      } else {
        if (creativeNonEmptyString(transitionIn['type']) == null) {
          validation.add(
            '$pointer/transitionIn/type',
            'plan_transition_invalid',
            'transitionIn.type 不能为空',
          );
        }
        final int? transitionDuration = creativeInt(transitionIn['duration']);
        if (transitionDuration == null || transitionDuration <= 0) {
          validation.add(
            '$pointer/transitionIn/duration',
            'plan_transition_invalid',
            'transitionIn.duration 必须是正整数帧',
          );
        }
      }
    }
    shots.add(
      CreativePlanShot(
        id: id ?? '',
        start: start ?? 0,
        duration: duration ?? 0,
        camera: camera,
        cast: cast,
        events: events,
        caption: caption,
        transitionIn: transitionIn,
        extra: _collectExtras(map, CreativePlanShot.knownKeys),
      ),
    );
  }
  return shots;
}

List<CreativePlanCast> _parseCast(
  Object? raw,
  String pointer,
  CreativeValidation validation,
) {
  final List<Object?>? list = creativeJsonList(raw);
  if (list == null) return const <CreativePlanCast>[];
  final List<CreativePlanCast> out = <CreativePlanCast>[];
  final Set<String> ids = <String>{};
  for (int i = 0; i < list.length; i++) {
    final String itemPointer = creativeIndexPointer(pointer, i);
    final Map<String, Object?>? map = creativeJsonMap(list[i]);
    if (map == null) {
      validation.add(itemPointer, 'plan_cast_invalid', 'cast 项必须是对象');
      continue;
    }
    final String? id = creativeNonEmptyString(map['id']);
    if (id == null) {
      validation.add('$itemPointer/id', 'plan_cast_invalid', 'cast.id 不能为空');
    } else if (!ids.add(id)) {
      validation.add(
        '$itemPointer/id',
        'plan_cast_invalid',
        '同一镜头内 cast id 重复：$id',
      );
    }
    final double? x = creativeFiniteDouble(map['x']);
    final double? y = creativeFiniteDouble(map['y']);
    if (x == null || y == null) {
      validation.add(itemPointer, 'plan_cast_invalid', 'cast 的 x/y 必须是有限数字');
    }
    final double? scale = map['scale'] == null
        ? 1
        : creativeFiniteDouble(map['scale']);
    if (scale == null || scale <= 0) {
      validation.add(
        '$itemPointer/scale',
        'plan_cast_invalid',
        'scale 必须是有限正数',
      );
    }
    final Object? flipRaw = map['flip'];
    if (flipRaw != null && flipRaw is! bool) {
      validation.add('$itemPointer/flip', 'plan_cast_invalid', 'flip 必须是布尔');
    }
    final Object? zRaw = map['z'];
    if (zRaw != null && creativeInt(zRaw) == null) {
      validation.add('$itemPointer/z', 'plan_cast_invalid', 'z 必须是整数');
    }
    out.add(
      CreativePlanCast(
        id: id ?? '',
        x: x ?? 0,
        y: y ?? 0,
        rig: creativeNonEmptyString(map['rig']),
        scale: scale ?? 1,
        flip: creativeBoolOr(flipRaw, fallback: false),
        z: creativeInt(zRaw),
        extra: _collectExtras(map, CreativePlanCast.knownKeys),
      ),
    );
  }
  return out;
}

List<CreativePlanEvent> _parseEvents(
  Object? raw,
  String pointer,
  int? shotDuration,
  CreativeValidation validation,
) {
  final List<Object?>? list = creativeJsonList(raw);
  if (list == null) return const <CreativePlanEvent>[];
  final List<CreativePlanEvent> out = <CreativePlanEvent>[];
  for (int i = 0; i < list.length; i++) {
    final String itemPointer = creativeIndexPointer(pointer, i);
    final Map<String, Object?>? map = creativeJsonMap(list[i]);
    if (map == null) {
      validation.add(itemPointer, 'plan_event_invalid', 'event 必须是对象');
      continue;
    }
    final int? frame = creativeInt(map['f']);
    if (frame == null || frame < 0) {
      validation.add(
        '$itemPointer/f',
        'plan_event_frame_invalid',
        'f 必须是 ≥0 的整数帧',
      );
    } else if (shotDuration != null && frame >= shotDuration) {
      validation.add('$itemPointer/f', 'plan_event_frame_invalid', 'f 超出镜头时长');
    }
    final String? type = creativeNonEmptyString(map['type']);
    if (type == null || !CreativePlanEvent.types.contains(type)) {
      validation.add(
        '$itemPointer/type',
        'plan_event_type_unknown',
        'type 必须是 vfx/sfx/camera.shake',
      );
    }
    String? cue = creativeNonEmptyString(map['cue']);
    if (type == 'vfx' || type == 'sfx') {
      if (cue == null) {
        validation.add(
          '$itemPointer/cue',
          'plan_event_cue_invalid',
          '$type 事件必须给 cue',
        );
      }
    } else {
      cue = null;
    }
    double? x;
    double? y;
    if (type == 'vfx') {
      x = creativeFiniteDouble(map['x']);
      y = creativeFiniteDouble(map['y']);
      if (x == null || y == null) {
        validation.add(
          itemPointer,
          'plan_event_anchor_invalid',
          'vfx 的 x/y 锚点必须是有限数字',
        );
      }
    }
    final Object? seedRaw = map['seed'];
    final int? seed = seedRaw == null ? null : creativeInt(seedRaw);
    if (seedRaw != null && seed == null) {
      validation.add(
        '$itemPointer/seed',
        'plan_event_seed_invalid',
        'seed 必须是整数',
      );
    }
    String? layer;
    if (map['layer'] != null) {
      layer = creativeNonEmptyString(map['layer']);
      if (layer == null || !CreativePlanEvent.layers.contains(layer)) {
        validation.add(
          '$itemPointer/layer',
          'plan_event_layer_invalid',
          'layer 必须是 front/back',
        );
      }
    }
    final List<String> palette = _parseStringList(
      map['palette'],
      '$itemPointer/palette',
      validation,
    );
    for (int j = 0; j < palette.length; j++) {
      if (!creativeIsHexColor(palette[j])) {
        validation.add(
          creativeIndexPointer('$itemPointer/palette', j),
          'plan_event_palette_invalid',
          'palette 必须是 #rrggbb',
        );
      }
    }
    if (type == 'camera.shake') {
      final double? amp = creativeFiniteDouble(map['amp']);
      final double? freq = creativeFiniteDouble(map['freq']);
      final int? duration = creativeInt(map['dur']);
      if (amp == null || freq == null || duration == null || duration <= 0) {
        validation.add(
          itemPointer,
          'plan_event_shake_invalid',
          'camera.shake 需要 amp/freq/dur',
        );
      }
    }
    if (type != null &&
        (type == 'vfx' || type == 'sfx' || type == 'camera.shake')) {
      out.add(
        CreativePlanEvent(
          frame: frame ?? 0,
          type: type,
          cue: cue,
          x: x,
          y: y,
          scale: creativeFiniteDouble(map['scale']) ?? 1,
          flip: creativeBoolOr(map['flip'], fallback: false),
          seed: seed,
          layer: layer,
          palette: palette,
          light: creativeFiniteDouble(map['light']),
          amp: creativeFiniteDouble(map['amp']),
          freq: creativeFiniteDouble(map['freq']),
          duration: creativeInt(map['dur']),
          extra: _collectExtras(map, CreativePlanEvent.knownKeys),
        ),
      );
    }
  }
  return out;
}

void _validateShotTimeline(
  List<CreativePlanShot> shots,
  int? durationFrames,
  CreativeValidation validation,
) {
  int cursor = 0;
  for (int i = 0; i < shots.length; i++) {
    final CreativePlanShot shot = shots[i];
    final int overlap = cursor - shot.start;
    if (overlap > 0) {
      final int? transition = creativeInt(shot.transitionIn?['duration']);
      if (transition == null || transition < overlap) {
        validation.add(
          creativeIndexPointer('/shots', i),
          'plan_shot_overlap',
          '镜头 ${shot.id} 与上一镜头重叠 $overlap 帧（无转场声明）',
        );
      }
    } else if (overlap < 0) {
      final int gap = -overlap;
      validation.warn(
        creativeIndexPointer('/shots', i),
        'plan_shot_gap',
        '镜头 ${shot.id} 前有 $gap 帧空隙',
      );
    }
    if (shot.end > cursor) cursor = shot.end;
  }
  if (durationFrames != null && cursor < durationFrames) {
    validation.warn(
      '/shots',
      'plan_shot_gap',
      '镜头未覆盖到 durationFrames（尾部 ${durationFrames - cursor} 帧）',
    );
  }
}

List<double> _parseVec3(
  Object? raw,
  String pointer,
  CreativeValidation validation,
) {
  final List<Object?>? list = creativeJsonList(raw);
  if (list == null || list.length != 3) {
    validation.add(pointer, 'plan_vec3_invalid', '必须是 3 个有限数字');
    return const <double>[0, 0, 0];
  }
  final List<double> out = <double>[];
  for (int i = 0; i < 3; i++) {
    final double? value = creativeFiniteDouble(list[i]);
    if (value == null) {
      validation.add(
        creativeIndexPointer(pointer, i),
        'plan_vec3_invalid',
        '必须是有限数字',
      );
      out.add(0);
    } else {
      out.add(value);
    }
  }
  return out;
}

List<String> _parseStringList(
  Object? raw,
  String pointer,
  CreativeValidation validation,
) {
  if (raw == null) return const <String>[];
  final List<Object?>? list = creativeJsonList(raw);
  if (list == null) {
    validation.add(pointer, 'plan_list_invalid', '必须是字符串数组');
    return const <String>[];
  }
  final List<String> out = <String>[];
  for (int i = 0; i < list.length; i++) {
    final String? value = creativeNonEmptyString(list[i]);
    if (value == null) {
      validation.add(
        creativeIndexPointer(pointer, i),
        'plan_list_item_invalid',
        '数组项必须是非空字符串',
      );
      continue;
    }
    out.add(value);
  }
  return out;
}

Map<String, Object?> _collectExtras(
  Map<String, Object?> map,
  Set<String> known,
) {
  final Map<String, Object?> extra = <String, Object?>{};
  for (final MapEntry<String, Object?> entry in map.entries) {
    if (known.contains(entry.key)) continue;
    extra[entry.key] = entry.value;
  }
  return extra;
}
