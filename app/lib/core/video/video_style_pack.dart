/// 常规视频风格包 v1（`nan.style_pack/1`）：palette / typography / motion。
///
/// 设计约束（`docs/video-screenplay-contract.md` §7）：
///  * 风格包是**数据**，不是代码：不引入网络请求、不引新运行时；
///  * 只允许白名单字段与取值（颜色必须是 `#rrggbb`、字号档位固定、动效预设固定）；
///  * `vfxAllowlist` 只能是全局 allowlist 的**子集**（不许借风格包放大能力面）；
///  * 未知字段保留（前向兼容），失败给 JSON Pointer。
///
/// 本层纯 Dart：播放页组装在 `video_short_player.dart`，应用在工作台是后续。
library;

import 'video_screenplay.dart' show videoVfxCueAllowlist;

/// 风格包 schema 标识（强制）。
const String videoStylePackSchema = 'nan.style_pack/1';

/// 字号档位（相对像素画布高度的比例，禁任意值）。
const List<String> videoStyleFontScales = <String>['sm', 'md', 'lg'];

/// 动效预设（进度条推进曲线；都为确定性函数）。
const List<String> videoStyleMotionPresets = <String>[
  'linear',
  'ease_out',
  'stepped',
];

/// 失败码。
const String videoStylePackInvalidSchema = 'style_pack_invalid_schema';
const String videoStylePackInvalidColor = 'style_pack_invalid_color';
const String videoStylePackInvalidValue = 'style_pack_invalid_value';
const String videoStylePackAllowlistEscape = 'style_pack_allowlist_escape';

/// 校验问题（JSON Pointer + 稳定码）。
final class VideoStylePackIssue {
  const VideoStylePackIssue({
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

/// 已校验的风格包。
final class VideoStylePack {
  const VideoStylePack({
    required this.id,
    required this.background,
    required this.band,
    required this.accent,
    required this.text,
    required this.fontScale,
    required this.motion,
    required this.vfxAllowlist,
    required this.raw,
  });

  final String id;

  /// 画布底色（0xRRGGBB）。
  final int background;
  final int band;
  final int accent;
  final int text;

  /// 字号档位（`sm` / `md` / `lg`）。
  final String fontScale;

  /// 进度推进曲线。
  final String motion;

  /// 允许的 VFX cue（空 = 用全局 allowlist）。
  final List<String> vfxAllowlist;

  /// 原始 JSON（未知字段保留）。
  final Map<String, Object?> raw;

  Map<String, Object?> toJson() => <String, Object?>{
    'schema': videoStylePackSchema,
    'id': id,
    'palette': <String, Object?>{
      'background': _hex(background),
      'band': _hex(band),
      'accent': _hex(accent),
      'text': _hex(text),
    },
    'typography': <String, Object?>{'caption': fontScale},
    'motion': <String, Object?>{'progress': motion},
    if (vfxAllowlist.isNotEmpty) 'vfxAllowlist': vfxAllowlist,
  };
}

/// 校验结果。
final class VideoStylePackVerification {
  const VideoStylePackVerification({
    required this.verified,
    required this.checks,
    this.stylePack,
  });

  final bool verified;
  final List<VideoStylePackIssue> checks;
  final VideoStylePack? stylePack;

  Map<String, Object?> toJson() => <String, Object?>{
    'verified': verified,
    'checks': checks
        .map((VideoStylePackIssue issue) => issue.toJson())
        .toList(growable: false),
  };
}

String _hex(int value) =>
    '#${value.toRadixString(16).padLeft(6, '0').toLowerCase()}';

/// 校验风格包；[globalVfxAllowlist] 用于子集检查。
VideoStylePackVerification verifyVideoStylePack(
  Map<String, Object?> raw, {
  required List<String> globalVfxAllowlist,
}) {
  final List<VideoStylePackIssue> issues = <VideoStylePackIssue>[];
  if (raw['schema'] != videoStylePackSchema) {
    return VideoStylePackVerification(
      verified: false,
      checks: const <VideoStylePackIssue>[
        VideoStylePackIssue(
          pointer: '/schema',
          code: videoStylePackInvalidSchema,
          message: 'schema 必须是 nan.style_pack/1',
        ),
      ],
    );
  }

  final Object? idRaw = raw['id'];
  final String id = idRaw is String ? idRaw.trim() : '';
  if (id.isEmpty) {
    issues.add(
      const VideoStylePackIssue(
        pointer: '/id',
        code: videoStylePackInvalidValue,
        message: 'id 必须是非空字符串',
      ),
    );
  }

  final Object? paletteRaw = raw['palette'];
  int background = 0x06080c;
  int band = 0x141a24;
  int accent = 0xffffff;
  int text = 0xffffff;
  if (paletteRaw is! Map) {
    issues.add(
      const VideoStylePackIssue(
        pointer: '/palette',
        code: videoStylePackInvalidValue,
        message: 'palette 必须是对象',
      ),
    );
  } else {
    final Map<String, Object?> palette = paletteRaw.cast<String, Object?>();
    int? read(String key, String pointer) {
      final Object? value = palette[key];
      if (value == null) return null;
      final int? parsed = _parseHexColor(value);
      if (parsed == null) {
        issues.add(
          VideoStylePackIssue(
            pointer: pointer,
            code: videoStylePackInvalidColor,
            message: '$key 必须是 #rrggbb',
          ),
        );
      }
      return parsed;
    }

    background = read('background', '/palette/background') ?? background;
    band = read('band', '/palette/band') ?? band;
    accent = read('accent', '/palette/accent') ?? accent;
    text = read('text', '/palette/text') ?? text;
  }

  // 对比度：正文色相对底的亮度差要有下限（不做出「看不见的字」）。
  final double contrast = _luma(text) - _luma(background);
  if (contrast.abs() < 0.05) {
    issues.add(
      const VideoStylePackIssue(
        pointer: '/palette/text',
        code: videoStylePackInvalidValue,
        message: 'text 与 background 亮度太接近，会看不清',
      ),
    );
  }

  String fontScale = 'md';
  final Object? typographyRaw = raw['typography'];
  if (typographyRaw != null) {
    if (typographyRaw is! Map) {
      issues.add(
        const VideoStylePackIssue(
          pointer: '/typography',
          code: videoStylePackInvalidValue,
          message: 'typography 必须是对象',
        ),
      );
    } else {
      final Object? caption = (typographyRaw.cast<String, Object?>())['caption'];
      if (caption != null) {
        if (caption is! String || !videoStyleFontScales.contains(caption)) {
          issues.add(
            VideoStylePackIssue(
              pointer: '/typography/caption',
              code: videoStylePackInvalidValue,
              message: 'caption 只能是 ${videoStyleFontScales.join('/')}',
            ),
          );
        } else {
          fontScale = caption;
        }
      }
    }
  }

  String motion = 'linear';
  final Object? motionRaw = raw['motion'];
  if (motionRaw != null) {
    if (motionRaw is! Map) {
      issues.add(
        const VideoStylePackIssue(
          pointer: '/motion',
          code: videoStylePackInvalidValue,
          message: 'motion 必须是对象',
        ),
      );
    } else {
      final Object? progress = (motionRaw.cast<String, Object?>())['progress'];
      if (progress != null) {
        if (progress is! String ||
            !videoStyleMotionPresets.contains(progress)) {
          issues.add(
            VideoStylePackIssue(
              pointer: '/motion/progress',
              code: videoStylePackInvalidValue,
              message: 'progress 只能是 ${videoStyleMotionPresets.join('/')}',
            ),
          );
        } else {
          motion = progress;
        }
      }
    }
  }

  final List<String> vfxAllowlist = <String>[];
  final Object? allowlistRaw = raw['vfxAllowlist'];
  if (allowlistRaw != null) {
    if (allowlistRaw is! List) {
      issues.add(
        const VideoStylePackIssue(
          pointer: '/vfxAllowlist',
          code: videoStylePackInvalidValue,
          message: 'vfxAllowlist 必须是数组',
        ),
      );
    } else {
      for (int i = 0; i < allowlistRaw.length; i++) {
        final Object? item = allowlistRaw[i];
        if (item is! String || !globalVfxAllowlist.contains(item)) {
          issues.add(
            VideoStylePackIssue(
              pointer: '/vfxAllowlist/$i',
              code: videoStylePackAllowlistEscape,
              message: 'vfxAllowlist 只能是全局 allowlist 的子集，越界值：$item',
            ),
          );
          continue;
        }
        vfxAllowlist.add(item);
      }
    }
  }

  if (issues.isNotEmpty) {
    return VideoStylePackVerification(verified: false, checks: issues);
  }
  return VideoStylePackVerification(
    verified: true,
    checks: const <VideoStylePackIssue>[],
    stylePack: VideoStylePack(
      id: id,
      background: background,
      band: band,
      accent: accent,
      text: text,
      fontScale: fontScale,
      motion: motion,
      vfxAllowlist: vfxAllowlist,
      raw: raw,
    ),
  );
}

int? _parseHexColor(Object? value) {
  if (value is! String) return null;
  final String text = value.trim();
  final RegExp pattern = RegExp(r'^#[0-9a-fA-F]{6}$');
  if (!pattern.hasMatch(text)) return null;
  return int.parse(text.substring(1), radix: 16);
}

/// 相对亮度（sRGB 感知近似；只用于「看得清」的下限检查）。
double _luma(int rgb) {
  final double r = ((rgb >> 16) & 0xff) / 255.0;
  final double g = ((rgb >> 8) & 0xff) / 255.0;
  final double b = (rgb & 0xff) / 255.0;
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

/// 内置风格预设（id → 原始 JSON）。都过同一套硬门；新增预设必须能通过
/// `verifyVideoStylePack`（守卫测试会逐个校验）。
const Map<String, Map<String, Object?>> videoStylePackPresets =
    <String, Map<String, Object?>>{
      'default_dark': <String, Object?>{
        'schema': 'nan.style_pack/1',
        'id': 'default_dark',
        'palette': <String, Object?>{
          'background': '#06080c',
          'band': '#141a24',
          'accent': '#7ad7ff',
          'text': '#ffffff',
        },
        'typography': <String, Object?>{'caption': 'md'},
        'motion': <String, Object?>{'progress': 'linear'},
      },
      'warm_amber': <String, Object?>{
        'schema': 'nan.style_pack/1',
        'id': 'warm_amber',
        'palette': <String, Object?>{
          'background': '#100c08',
          'band': '#241a10',
          'accent': '#ffaa33',
          'text': '#fff4e0',
        },
        'typography': <String, Object?>{'caption': 'lg'},
        'motion': <String, Object?>{'progress': 'ease_out'},
      },
      'cool_blue': <String, Object?>{
        'schema': 'nan.style_pack/1',
        'id': 'cool_blue',
        'palette': <String, Object?>{
          'background': '#080c14',
          'band': '#101a2c',
          'accent': '#4da3ff',
          'text': '#e8f2ff',
        },
        'typography': <String, Object?>{'caption': 'sm'},
        'motion': <String, Object?>{'progress': 'stepped'},
      },
    };

/// 按 id 取内置预设（未知名返回 null，调用方显性处理，不猜）。
VideoStylePack? videoStylePackPreset(String id) {
  final Map<String, Object?>? raw = videoStylePackPresets[id];
  if (raw == null) return null;
  final VideoStylePackVerification verified = verifyVideoStylePack(
    raw,
    globalVfxAllowlist: videoVfxCueAllowlist,
  );
  return verified.verified ? verified.stylePack : null;
}

/// 内置预设的显示名（UI 用；不在表里就回 id）。
String videoStylePackLabel(String id) {
  return switch (id) {
    'default_dark' => '默认暗色',
    'warm_amber' => '暖琥珀',
    'cool_blue' => '冷蓝',
    _ => id,
  };
}
