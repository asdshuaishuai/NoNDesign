/// 常规视频「剧本」契约 v1（`nan.screenplay/1`）：解析 + 硬门校验 + 整数帧编译。
///
/// 与 `docs/video-screenplay-contract.md` 对齐的**最小可施工子集**：
///  * 扁平 `shots[]`（`id / start / duration / events[]`），30fps 固定；
///  * 事件 `{f:int, type}`：`vfx` / `sfx` / `camera.shake` / `caption`；
///  * **VFX 事件 `cue` 必须命中 allowlist**（`videoVfxCueAllowlist`，与
///    `app/assets/pixelfx/build-manifest.json` 的 `allowedEffectIds` 逐字一致）——
///    未知 cue 在**编译期**就拒绝，不让它进页面、不静默丢事件；
///  * 未知字段**保留**（前向兼容），校验失败给 **JSON Pointer** 位置；
///  * 时间一律换算成**整数帧**（帧号是唯一时钟，禁 wall clock / 浮点累加）。
///
/// 本层纯 Dart：不碰 WebView、不碰文件；播放页组装在 `video_short_player.dart`。
library;

/// 剧本 schema 标识（强制）。
const String videoScreenplaySchema = 'nan.screenplay/1';

/// 帧率固定 30（与 v1 视频/3D 视频同一时间基）。
const int videoScreenplayFps = 30;

/// 允许的 VFX cue（= pixelfx 入库特效 id，与 build-manifest 同源）。
///
/// 守卫测试会与 `app/assets/pixelfx/build-manifest.json` 的 `allowedEffectIds`
/// 逐字对账：这里改了而资产没变（或反之）都会红。
const List<String> videoVfxCueAllowlist = <String>[
  'fire.campfire',
  'fire.fireball',
  'fire.flame-pillar',
  'ice.frost-breath',
  'ice.ice-shatter',
  'ice.ice-crystal',
  'lightning.lightning-strike',
  'lightning.spark-arc',
  'explosions.small-explosion',
  'explosions.big-explosion',
  'nature.earth-spike',
];

/// 允许的事件类型（未列出的类型编译期拒绝）。
const List<String> videoEventTypeAllowlist = <String>[
  'vfx',
  'sfx',
  'camera.shake',
  'caption',
];

/// VFX 图层（像素画布的前后叠放）。
const List<String> videoVfxLayerAllowlist = <String>['back', 'front'];

/// 像素画布预设（最近邻放大，不引入缩放滤镜）。
const List<List<int>> videoCanvasPresets = <List<int>>[
  <int>[320, 180],
  <int>[480, 270],
];

/// 校验失败码（稳定机器码）。
const String videoScreenplayInvalidSchema = 'screenplay_invalid_schema';
const String videoScreenplayInvalidShot = 'screenplay_invalid_shot';
const String videoScreenplayInvalidEvent = 'screenplay_invalid_event';
const String videoScreenplayUnknownCue = 'screenplay_unknown_cue';
const String videoScreenplayUnknownEventType = 'screenplay_unknown_event_type';
const String videoScreenplayDuplicateId = 'screenplay_duplicate_id';

/// 校验问题（`pointer` 是 JSON Pointer 风格位置，供工具/UI 定位）。
final class VideoScreenplayIssue {
  const VideoScreenplayIssue({
    required this.pointer,
    required this.code,
    required this.message,
  });

  final String pointer;
  final String code;
  final String message;

  Map<String, Object?> toJson() => <String, Object?>{
    'pointer': pointer,
    'code': code,
    'message': message,
  };
}

/// 一条已编译的事件（帧号已校验在时间表内）。
final class VideoScreenplayEvent {
  const VideoScreenplayEvent({
    required this.frame,
    required this.type,
    required this.cue,
    required this.layer,
    required this.x,
    required this.y,
    required this.scale,
    required this.seed,
  });

  /// 全局整数帧号（0 基）。
  final int frame;
  final String type;

  /// 仅 `vfx` 事件有 cue（已命中 allowlist）。
  final String cue;
  final String layer;
  final double x;
  final double y;
  final double scale;
  final int seed;

  Map<String, Object?> toJson() => <String, Object?>{
    'f': frame,
    'type': type,
    if (type == 'vfx') 'cue': cue,
    if (type == 'vfx') 'layer': layer,
    if (type == 'vfx') 'x': x,
    if (type == 'vfx') 'y': y,
    if (type == 'vfx') 'scale': scale,
    if (type == 'vfx') 'seed': seed,
  };
}

/// 一个镜头（已编译成整数帧区间）。
final class VideoScreenplayShot {
  const VideoScreenplayShot({
    required this.id,
    required this.startFrame,
    required this.frameCount,
    required this.events,
  });

  final String id;
  final int startFrame;
  final int frameCount;
  final List<VideoScreenplayEvent> events;

  int get endFrameExclusive => startFrame + frameCount;
}

/// 已校验通过的剧本：整数帧时间表 + 事件表。
final class VideoScreenplay {
  const VideoScreenplay({
    required this.shots,
    required this.totalFrames,
    required this.width,
    required this.height,
    required this.raw,
  });

  final List<VideoScreenplayShot> shots;
  final int totalFrames;
  final int width;
  final int height;

  /// 原始 JSON（未知字段原样保留，供后续版本消费）。
  final Map<String, Object?> raw;

  /// 全量事件（按帧号升序；同帧按原序）。
  List<VideoScreenplayEvent> get events => <VideoScreenplayEvent>[
    for (final VideoScreenplayShot shot in shots) ...shot.events,
  ];
}

/// 校验结果：零问题才 `verified`；失败时 `screenplay` 为 null。
final class VideoScreenplayVerification {
  const VideoScreenplayVerification({
    required this.verified,
    required this.checks,
    this.screenplay,
  });

  final bool verified;
  final List<VideoScreenplayIssue> checks;
  final VideoScreenplay? screenplay;

  Map<String, Object?> toJson() => <String, Object?>{
    'verified': verified,
    'checks': checks
        .map((VideoScreenplayIssue issue) => issue.toJson())
        .toList(growable: false),
  };
}

/// 校验 + 编译（唯一入口；失败不产出半成品时间表）。
VideoScreenplayVerification verifyVideoScreenplay(Map<String, Object?> raw) {
  final List<VideoScreenplayIssue> issues = <VideoScreenplayIssue>[];

  if (raw['schema'] != videoScreenplaySchema) {
    issues.add(
      const VideoScreenplayIssue(
        pointer: '/schema',
        code: videoScreenplayInvalidSchema,
        message: 'schema 必须是 nan.screenplay/1',
      ),
    );
    return VideoScreenplayVerification(verified: false, checks: issues);
  }

  // 画布：缺省 320×180；只允许预设。
  final int width = _asInt(raw['width']) ?? 320;
  final int height = _asInt(raw['height']) ?? 180;
  if (!videoCanvasPresets.any(
      (List<int> preset) => preset[0] == width && preset[1] == height)) {
    issues.add(
      VideoScreenplayIssue(
        pointer: '/width',
        code: videoScreenplayInvalidSchema,
        message: '画布必须是 320×180 或 480×270，实得 ${width}x$height',
      ),
    );
  }

  final Object? shotsRaw = raw['shots'];
  if (shotsRaw is! List || shotsRaw.isEmpty) {
    issues.add(
      const VideoScreenplayIssue(
        pointer: '/shots',
        code: videoScreenplayInvalidShot,
        message: 'shots 必须是非空数组',
      ),
    );
    return VideoScreenplayVerification(verified: false, checks: issues);
  }

  final Set<String> seenShotIds = <String>{};
  final List<VideoScreenplayShot> shots = <VideoScreenplayShot>[];
  int cursorFrame = 0;

  for (int i = 0; i < shotsRaw.length; i++) {
    final Object? shotRaw = shotsRaw[i];
    final String base = '/shots/$i';
    if (shotRaw is! Map) {
      issues.add(
        VideoScreenplayIssue(
          pointer: base,
          code: videoScreenplayInvalidShot,
          message: '镜头必须是对象',
        ),
      );
      continue;
    }
    final Map<String, Object?> shot =
        shotRaw.cast<String, Object?>();
    final Object? idRaw = shot['id'];
    if (idRaw is! String || idRaw.trim().isEmpty) {
      issues.add(
        VideoScreenplayIssue(
          pointer: '$base/id',
          code: videoScreenplayInvalidShot,
          message: '镜头 id 必须是非空字符串',
        ),
      );
      continue;
    }
    final String id = idRaw.trim();
    if (!seenShotIds.add(id)) {
      issues.add(
        VideoScreenplayIssue(
          pointer: '$base/id',
          code: videoScreenplayDuplicateId,
          message: '镜头 id 重复：$id',
        ),
      );
      continue;
    }

    final double? start = _asDouble(shot['start']);
    final double? duration = _asDouble(shot['duration']);
    if (start == null || start < 0) {
      issues.add(
        VideoScreenplayIssue(
          pointer: '$base/start',
          code: videoScreenplayInvalidShot,
          message: 'start 必须是 ≥0 的秒数',
        ),
      );
      continue;
    }
    if (duration == null || duration <= 0) {
      issues.add(
        VideoScreenplayIssue(
          pointer: '$base/duration',
          code: videoScreenplayInvalidShot,
          message: 'duration 必须是 >0 的秒数',
        ),
      );
      continue;
    }

    // 整数帧：start 用向零取整（同一输入两次编译必然同帧号）。
    final int startFrame = (start * videoScreenplayFps).floor();
    final int frameCount = (duration * videoScreenplayFps).round();
    if (startFrame < cursorFrame) {
      issues.add(
        VideoScreenplayIssue(
          pointer: '$base/start',
          code: videoScreenplayInvalidShot,
          message:
              '镜头起始帧 $startFrame 与上一镜头结束帧 $cursorFrame 重叠/倒序',
        ),
      );
      continue;
    }
    if (frameCount <= 0) {
      issues.add(
        VideoScreenplayIssue(
          pointer: '$base/duration',
          code: videoScreenplayInvalidShot,
          message: 'duration 太短，换算后不足 1 帧',
        ),
      );
      continue;
    }

    final Object eventsRaw = shot['events'] ?? const <Object?>[];
    if (eventsRaw is! List) {
      issues.add(
        VideoScreenplayIssue(
          pointer: '$base/events',
          code: videoScreenplayInvalidEvent,
          message: 'events 必须是数组',
        ),
      );
      continue;
    }

    final List<VideoScreenplayEvent> events = <VideoScreenplayEvent>[];
    for (int j = 0; j < eventsRaw.length; j++) {
      final Object? eventRaw = eventsRaw[j];
      final String eventBase = '$base/events/$j';
      if (eventRaw is! Map) {
        issues.add(
          VideoScreenplayIssue(
            pointer: eventBase,
            code: videoScreenplayInvalidEvent,
            message: '事件必须是对象',
          ),
        );
        continue;
      }
      final Map<String, Object?> event = eventRaw.cast<String, Object?>();
      final Object? typeRaw = event['type'];
      final String type = typeRaw is String ? typeRaw : '';
      if (!videoEventTypeAllowlist.contains(type)) {
        issues.add(
          VideoScreenplayIssue(
            pointer: '$eventBase/type',
            code: videoScreenplayUnknownEventType,
            message: '事件类型不在 allowlist：$type',
          ),
        );
        continue;
      }

      // `f` 是镜头内相对帧（0 基）；也接受绝对帧的写法会被这里判成越界。
      final int? relative = _asInt(event['f']);
      if (relative == null || relative < 0) {
        issues.add(
          VideoScreenplayIssue(
            pointer: '$eventBase/f',
            code: videoScreenplayInvalidEvent,
            message: 'f 必须是 ≥0 的整数帧',
          ),
        );
        continue;
      }
      if (relative >= frameCount) {
        issues.add(
          VideoScreenplayIssue(
            pointer: '$eventBase/f',
            code: videoScreenplayInvalidEvent,
            message: 'f=$relative 超出镜头 $id 的帧数 $frameCount',
          ),
        );
        continue;
      }

      String cue = '';
      String layer = 'front';
      double x = 0;
      double y = 0;
      double scale = 1;
      int seed = 0;
      if (type == 'vfx') {
        final Object? cueRaw = event['cue'];
        cue = cueRaw is String ? cueRaw : '';
        if (!videoVfxCueAllowlist.contains(cue)) {
          issues.add(
            VideoScreenplayIssue(
              pointer: '$eventBase/cue',
              code: videoScreenplayUnknownCue,
              message: 'VFX cue 不在 allowlist：$cue（可用：'
                  '${videoVfxCueAllowlist.join(', ')}）',
            ),
          );
          continue;
        }
        final Object? layerRaw = event['layer'];
        layer = layerRaw == null ? 'front' : '$layerRaw';
        if (!videoVfxLayerAllowlist.contains(layer)) {
          issues.add(
            VideoScreenplayIssue(
              pointer: '$eventBase/layer',
              code: videoScreenplayInvalidEvent,
              message: 'layer 必须是 back/front，实得 $layer',
            ),
          );
          continue;
        }
        x = _asDouble(event['x']) ?? 0;
        y = _asDouble(event['y']) ?? 0;
        scale = _asDouble(event['scale']) ?? 1;
        if (scale <= 0) {
          issues.add(
            VideoScreenplayIssue(
              pointer: '$eventBase/scale',
              code: videoScreenplayInvalidEvent,
              message: 'scale 必须 >0',
            ),
          );
          continue;
        }
        final int? seedRaw = _asInt(event['seed']);
        // seed 缺省由稳定 hash 派生（同输入同种子，不用随机数）。
        seed = seedRaw ?? _stableSeed('$id/$relative/$cue');
      }

      events.add(
        VideoScreenplayEvent(
          frame: startFrame + relative,
          type: type,
          cue: cue,
          layer: layer,
          x: x,
          y: y,
          scale: scale,
          seed: seed,
        ),
      );
    }
    if (issues.isNotEmpty) {
      // 该镜头有事件问题：不产出它的时间表（避免半成品）。
      continue;
    }

    shots.add(
      VideoScreenplayShot(
        id: id,
        startFrame: startFrame,
        frameCount: frameCount,
        events: events,
      ),
    );
    cursorFrame = startFrame + frameCount;
  }

  // 镜头之间允许留空（黑场），但总帧数必须 > 0。
  final int totalFrames = shots.fold<int>(
    0,
    (int total, VideoScreenplayShot shot) =>
        total < shot.endFrameExclusive ? shot.endFrameExclusive : total,
  );
  if (totalFrames <= 0) {
    issues.add(
      const VideoScreenplayIssue(
        pointer: '/shots',
        code: videoScreenplayInvalidShot,
        message: '时间表为空',
      ),
    );
  }

  if (issues.isNotEmpty) {
    return VideoScreenplayVerification(verified: false, checks: issues);
  }
  return VideoScreenplayVerification(
    verified: true,
    checks: const <VideoScreenplayIssue>[],
    screenplay: VideoScreenplay(
      shots: shots,
      totalFrames: totalFrames,
      width: width,
      height: height,
      raw: raw,
    ),
  );
}

/// 稳定种子：FNV-1a 32 位（同输入必然同值，跨平台一致）。
int _stableSeed(String text) {
  int hash = 0x811c9dc5;
  for (final int unit in text.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash;
}

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is num && value.isFinite && value == value.floorToDouble()) {
    return value.toInt();
  }
  if (value is String) return int.tryParse(value.trim());
  return null;
}

double? _asDouble(Object? value) {
  if (value is num && value.isFinite) return value.toDouble();
  if (value is String) return double.tryParse(value.trim());
  return null;
}
