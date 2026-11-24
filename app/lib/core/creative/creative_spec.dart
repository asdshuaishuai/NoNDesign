/// `creative.spec.json`：请求（kind/track/prompt/must/dims/references/style/output）。
///
/// 契约见 `docs/skills/creative-workbench/references/schemas.md` §1。本文件只做
/// 解析与校验：未知字段原样保留（`extra`），缺省字段给文档默认值，所有问题带
/// JSON Pointer 一次列全，不 fail-fast。
library;

import 'creative_schema.dart';

/// 请求里的时长/帧率/画幅。视频线必填；3D 线可选。
final class CreativeDuration {
  const CreativeDuration({
    required this.seconds,
    this.fps = creativeVideoFps,
    this.aspect = '16:9',
    this.extra = const <String, Object?>{},
  });

  final int seconds;
  final int fps;
  final String aspect;
  final Map<String, Object?> extra;

  static const Set<String> knownKeys = <String>{'seconds', 'fps', 'aspect'};

  Map<String, Object?> toJson() => <String, Object?>{
    'seconds': seconds,
    'fps': fps,
    'aspect': aspect,
    ...extra,
  };
}

/// 参考资源条目；`path` 必须是项目内相对路径。
final class CreativeReference {
  const CreativeReference({
    required this.path,
    required this.role,
    this.extra = const <String, Object?>{},
  });

  final String path;
  final CreativeReferenceRole role;
  final Map<String, Object?> extra;

  static const Set<String> knownKeys = <String>{'path', 'role'};

  Map<String, Object?> toJson() => <String, Object?>{
    'path': path,
    'role': role.wire,
    ...extra,
  };
}

/// 风格包选择；`pack` 未给时用中性包。
final class CreativeStyle {
  const CreativeStyle({
    this.pack = CreativeStylePack.neutral,
    this.palette = const <String>[],
    this.type = const <String>[],
    this.extra = const <String, Object?>{},
  });

  final CreativeStylePack pack;
  final List<String> palette;
  final List<String> type;
  final Map<String, Object?> extra;

  static const Set<String> knownKeys = <String>{'pack', 'palette', 'type'};

  Map<String, Object?> toJson() => <String, Object?>{
    'pack': pack.wire,
    'palette': palette,
    'type': type,
    ...extra,
  };
}

/// 输出类型。`export == mp4` 在产品导出闸门关闭时校验期拒绝。
final class CreativeOutput {
  const CreativeOutput({
    this.preview = true,
    this.source = true,
    this.export = CreativeExportFormat.none,
    this.extra = const <String, Object?>{},
  });

  final bool preview;
  final bool source;
  final CreativeExportFormat export;
  final Map<String, Object?> extra;

  static const Set<String> knownKeys = <String>{'preview', 'source', 'export'};

  Map<String, Object?> toJson() => <String, Object?>{
    'preview': preview,
    'source': source,
    'export': export.wire,
    ...extra,
  };
}

/// `spec.json` 的类型化视图。
final class CreativeSpec {
  const CreativeSpec({
    required this.kind,
    required this.track,
    required this.prompt,
    this.mustHave = const <String>[],
    this.mustNot = const <String>[],
    this.dims = const <String, double>{},
    this.duration,
    this.references = const <CreativeReference>[],
    this.style = const CreativeStyle(),
    this.output = const CreativeOutput(),
    this.extra = const <String, Object?>{},
  });

  final CreativeKind kind;
  final CreativeTrack track;
  final String prompt;
  final List<String> mustHave;
  final List<String> mustNot;

  /// 3D 尺寸约束（单位米），如 `{height_m: 0.45}`。
  final Map<String, double> dims;
  final CreativeDuration? duration;
  final List<CreativeReference> references;
  final CreativeStyle style;
  final CreativeOutput output;
  final Map<String, Object?> extra;

  static const Set<String> knownKeys = <String>{
    'schema',
    'kind',
    'track',
    'prompt',
    'must_have',
    'must_not',
    'dims',
    'duration',
    'references',
    'style',
    'output',
  };

  /// 解析并校验。核心字段（kind/track/prompt）缺失时 `value == null`，
  /// 但 [CreativeParseResult.validation] 仍列出全部问题。
  static CreativeParseResult<CreativeSpec> parse(Object? raw) {
    final CreativeValidation validation = CreativeValidation();
    final Map<String, Object?>? map = creativeJsonMap(raw);
    if (map == null) {
      validation.add('', 'spec_not_object', 'spec.json 必须是 JSON 对象');
      return CreativeParseResult<CreativeSpec>(null, validation);
    }

    if (map['schema'] != creativeSpecSchema) {
      validation.add(
        '/schema',
        'spec_schema_mismatch',
        'schema 必须是 $creativeSpecSchema',
      );
    }

    final CreativeKind? kind = creativeEnumByWire(
      CreativeKind.values,
      (CreativeKind value) => value.wire,
      map['kind'],
    );
    if (kind == null) {
      validation.add(
        '/kind',
        'spec_kind_invalid',
        'kind 必须是 3d/video/interactive/design',
      );
    }

    final CreativeTrack? track = creativeEnumByWire(
      CreativeTrack.values,
      (CreativeTrack value) => value.wire,
      map['track'],
    );
    if (track == null) {
      validation.add('/track', 'spec_track_invalid', 'track 不在枚举内');
    } else if (kind != null && track.kind != kind) {
      validation.add(
        '/track',
        'spec_track_kind_mismatch',
        'track ${track.wire} 属于 ${track.kind.wire}，与 kind ${kind.wire} 不匹配',
      );
    }

    final String? prompt = creativeNonEmptyString(map['prompt']);
    if (prompt == null) {
      validation.add('/prompt', 'spec_prompt_missing', 'prompt 不能为空');
    }

    final List<String> mustHave = _parseStringList(
      map['must_have'],
      '/must_have',
      validation,
    );
    final List<String> mustNot = _parseStringList(
      map['must_not'],
      '/must_not',
      validation,
    );

    final Map<String, double> dims = _parseDims(map['dims'], validation);

    CreativeDuration? duration;
    if (map['duration'] != null) {
      duration = _parseDuration(map['duration'], '/duration', validation);
    }
    if (kind == CreativeKind.video && duration == null && validation.isValid) {
      validation.add('/duration', 'spec_duration_required', '视频请求必须给 duration');
    }

    final List<CreativeReference> references = _parseReferences(
      map['references'],
      validation,
    );

    CreativeStyle style = const CreativeStyle();
    if (map['style'] != null) {
      style = _parseStyle(map['style'], '/style', validation) ?? style;
    }

    CreativeOutput output = const CreativeOutput();
    if (map['output'] != null) {
      output = _parseOutput(map['output'], '/output', validation) ?? output;
    }
    _checkExport(kind, output, validation);

    final Map<String, Object?> extra = _collectExtras(map, knownKeys);

    if (kind == null || track == null || prompt == null) {
      return CreativeParseResult<CreativeSpec>(null, validation);
    }

    return CreativeParseResult<CreativeSpec>(
      CreativeSpec(
        kind: kind,
        track: track,
        prompt: prompt,
        mustHave: mustHave,
        mustNot: mustNot,
        dims: dims,
        duration: duration,
        references: references,
        style: style,
        output: output,
        extra: extra,
      ),
      validation,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'schema': creativeSpecSchema,
    'kind': kind.wire,
    'track': track.wire,
    'prompt': prompt,
    'must_have': mustHave,
    'must_not': mustNot,
    if (dims.isNotEmpty) 'dims': dims,
    if (duration != null) 'duration': duration!.toJson(),
    'references': references
        .map((CreativeReference ref) => ref.toJson())
        .toList(growable: false),
    'style': style.toJson(),
    'output': output.toJson(),
    ...extra,
  };
}

List<String> _parseStringList(
  Object? raw,
  String pointer,
  CreativeValidation validation,
) {
  if (raw == null) return const <String>[];
  final List<Object?>? list = creativeJsonList(raw);
  if (list == null) {
    validation.add(pointer, 'spec_list_invalid', '必须是字符串数组');
    return const <String>[];
  }
  final List<String> out = <String>[];
  for (int i = 0; i < list.length; i++) {
    final String? value = creativeNonEmptyString(list[i]);
    if (value == null) {
      validation.add(
        creativeIndexPointer(pointer, i),
        'spec_list_item_invalid',
        '数组项必须是非空字符串',
      );
      continue;
    }
    out.add(value);
  }
  return out;
}

Map<String, double> _parseDims(Object? raw, CreativeValidation validation) {
  if (raw == null) return const <String, double>{};
  final Map<String, Object?>? map = creativeJsonMap(raw);
  if (map == null) {
    validation.add('/dims', 'spec_dims_invalid', 'dims 必须是对象');
    return const <String, double>{};
  }
  final Map<String, double> out = <String, double>{};
  for (final MapEntry<String, Object?> entry in map.entries) {
    final String pointer = creativePointer('/dims', entry.key);
    if (entry.key.trim().isEmpty) {
      validation.add(pointer, 'spec_dims_invalid', 'dims 字段名不能为空');
      continue;
    }
    final double? value = creativeFiniteDouble(entry.value);
    if (value == null || value <= 0) {
      validation.add(pointer, 'spec_dims_invalid', 'dims 值必须是有限正数');
      continue;
    }
    out[entry.key] = value;
  }
  return out;
}

CreativeDuration? _parseDuration(
  Object? raw,
  String pointer,
  CreativeValidation validation,
) {
  final Map<String, Object?>? map = creativeJsonMap(raw);
  if (map == null) {
    validation.add(pointer, 'spec_duration_invalid', 'duration 必须是对象');
    return null;
  }
  final int? seconds = creativeInt(map['seconds']);
  if (seconds == null || seconds <= 0) {
    validation.add(
      '$pointer/seconds',
      'spec_duration_seconds_invalid',
      'seconds 必须是正整数',
    );
  }
  final int? fps = creativeInt(map['fps']);
  if (fps == null || fps != creativeVideoFps) {
    validation.add(
      pointer,
      'spec_fps_unsupported',
      'v1 只支持 $creativeVideoFps fps',
    );
  }
  final String? aspect = creativeNonEmptyString(map['aspect']);
  if (aspect == null || !creativeVideoAspects.contains(aspect)) {
    validation.add(
      '$pointer/aspect',
      'spec_aspect_invalid',
      'aspect 必须是 ${creativeVideoAspects.join('/')}',
    );
  }
  return CreativeDuration(
    seconds: seconds ?? 0,
    fps: fps ?? creativeVideoFps,
    aspect: aspect ?? '16:9',
    extra: _collectExtras(map, CreativeDuration.knownKeys),
  );
}

List<CreativeReference> _parseReferences(
  Object? raw,
  CreativeValidation validation,
) {
  if (raw == null) return const <CreativeReference>[];
  final List<Object?>? list = creativeJsonList(raw);
  if (list == null) {
    validation.add(
      '/references',
      'spec_references_invalid',
      'references 必须是数组',
    );
    return const <CreativeReference>[];
  }
  final List<CreativeReference> out = <CreativeReference>[];
  for (int i = 0; i < list.length; i++) {
    final String pointer = creativeIndexPointer('/references', i);
    final Map<String, Object?>? map = creativeJsonMap(list[i]);
    if (map == null) {
      validation.add(pointer, 'spec_reference_invalid', '参考项必须是对象');
      continue;
    }
    final String? path = creativeNonEmptyString(map['path']);
    if (path == null || !creativeIsSafeRelativePath(path)) {
      validation.add(
        '$pointer/path',
        'spec_reference_path_unsafe',
        '参考路径必须在项目内且为相对路径',
      );
    }
    final CreativeReferenceRole? role = creativeEnumByWire(
      CreativeReferenceRole.values,
      (CreativeReferenceRole value) => value.wire,
      map['role'],
    );
    if (role == null) {
      validation.add(
        '$pointer/role',
        'spec_reference_role_invalid',
        'role 必须是 silhouette/palette/motion/style',
      );
    }
    out.add(
      CreativeReference(
        path: path ?? '',
        role: role ?? CreativeReferenceRole.style,
        extra: _collectExtras(map, CreativeReference.knownKeys),
      ),
    );
  }
  return out;
}

CreativeStyle? _parseStyle(
  Object? raw,
  String pointer,
  CreativeValidation validation,
) {
  final Map<String, Object?>? map = creativeJsonMap(raw);
  if (map == null) {
    validation.add(pointer, 'spec_style_invalid', 'style 必须是对象');
    return null;
  }
  CreativeStylePack pack = CreativeStylePack.neutral;
  if (map['pack'] != null) {
    final CreativeStylePack? parsed = creativeEnumByWire(
      CreativeStylePack.values,
      (CreativeStylePack value) => value.wire,
      map['pack'],
    );
    if (parsed == null) {
      validation.add(
        '$pointer/pack',
        'spec_style_pack_invalid',
        'style.pack 不在枚举内',
      );
    } else {
      pack = parsed;
    }
  }
  final List<String> palette = _parseStringList(
    map['palette'],
    '$pointer/palette',
    validation,
  );
  for (int i = 0; i < palette.length; i++) {
    if (!creativeIsHexColor(palette[i])) {
      validation.add(
        creativeIndexPointer('$pointer/palette', i),
        'spec_style_palette_invalid',
        '调色板必须是 #rrggbb',
      );
    }
  }
  final List<String> type = _parseStringList(
    map['type'],
    '$pointer/type',
    validation,
  );
  return CreativeStyle(
    pack: pack,
    palette: palette,
    type: type,
    extra: _collectExtras(map, CreativeStyle.knownKeys),
  );
}

CreativeOutput? _parseOutput(
  Object? raw,
  String pointer,
  CreativeValidation validation,
) {
  final Map<String, Object?>? map = creativeJsonMap(raw);
  if (map == null) {
    validation.add(pointer, 'spec_output_invalid', 'output 必须是对象');
    return null;
  }
  final Object? previewRaw = map['preview'];
  final Object? sourceRaw = map['source'];
  if (previewRaw != null && previewRaw is! bool) {
    validation.add(
      '$pointer/preview',
      'spec_output_invalid',
      'output.preview 必须是布尔',
    );
  }
  if (sourceRaw != null && sourceRaw is! bool) {
    validation.add(
      '$pointer/source',
      'spec_output_invalid',
      'output.source 必须是布尔',
    );
  }
  CreativeExportFormat export = CreativeExportFormat.none;
  if (map['export'] != null) {
    final CreativeExportFormat? parsed = creativeEnumByWire(
      CreativeExportFormat.values,
      (CreativeExportFormat value) => value.wire,
      map['export'],
    );
    if (parsed == null) {
      validation.add(
        '$pointer/export',
        'spec_export_invalid',
        'export 必须是 none/mp4/glb',
      );
    } else {
      export = parsed;
    }
  }
  return CreativeOutput(
    preview: creativeBoolOr(previewRaw, fallback: true),
    source: creativeBoolOr(sourceRaw, fallback: true),
    export: export,
    extra: _collectExtras(map, CreativeOutput.knownKeys),
  );
}

void _checkExport(
  CreativeKind? kind,
  CreativeOutput output,
  CreativeValidation validation,
) {
  if (output.export == CreativeExportFormat.mp4 && !creativeMp4ExportEnabled) {
    validation.add(
      '/output/export',
      'spec_export_blocked',
      '成片导出仍屏蔽，export 只能是 none/glb',
    );
  }
  if (output.export == CreativeExportFormat.glb &&
      kind != null &&
      kind != CreativeKind.threeD) {
    validation.add(
      '/output/export',
      'spec_export_kind_mismatch',
      'GLB 只属于 3D 请求',
    );
  }
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
