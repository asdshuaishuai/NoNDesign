/// 动效合成（HTML/CSS/JS 短片）的目录与单文件装配。
///
/// 视频工作台有两种渲染面：矢量动画（[VideoDocument.frameSvg] 纯 Dart）与
/// 动效合成（自包含 HTML 短片，交给应用内 WebView 的 `requestAnimationFrame`
/// 播放）。本文件只负责后者的**数据面**，不碰 WebView：
///
///  * [VideoClipInfo]：`clips.json` 里的一条短片（顺序即列表顺序）；
///  * [parseVideoClips]：纯函数，坏条目跳过、不崩（测试直接注入原始 JSON）；
///  * [loadVideoClips]：从 `assets/video/clip/clips.json` 读清单，失败给人话；
///  * [assembleVideoClipHtml]：把 `engine.css` / `engine.js` 内联进短片页面，
///    得到单文件 HTML（离线可跑、无外链），纯函数、可测、重复调用幂等。
///
/// 契约见 `docs/video-clip-contract.md`：页面骨架、桥消息、`clips.json` schema
/// 都在那里。这里不解释画面语义，只做字符串搬运与校验。
library;

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

/// 清单文件在资源包里的固定路径（`pubspec.yaml` 必须声明该目录）。
const String videoClipCatalogAsset = 'assets/video/clip/clips.json';

/// 短片运行时资源（与短片同目录，随清单一起内联进单文件页面）。
const String videoClipEngineCssAsset = 'assets/video/clip/engine.css';
const String videoClipEngineJsAsset = 'assets/video/clip/engine.js';

/// 短片文件在资源包里的路径前缀。
const String videoClipAssetDir = 'assets/video/clip/';

/// `clips.json` 里的一条短片。
///
/// `id` 与文件名同源：`file` 缺省时就是 `<id>.html`；`duration` 是声明值，
/// 播放面以页面桥回传的真实时长为准；`style` 归一化到
/// `hand`（手绘）/ `motion`（动效排版）/ `ui`（界面演示）/ `data`（数据）。
class VideoClipInfo {
  VideoClipInfo({
    required this.id,
    required this.title,
    this.subtitle = '',
    this.style = 'hand',
    this.duration = 0,
    String? file,
    this.tags = const <String>[],
  }) : file = file ?? '$id.html';

  /// 稳定标识，与文件名同源（`<id>.html`）。
  final String id;

  /// 列表里显示的名字。
  final String title;

  /// 列表里的一行说明（也是只读对照卡的副标题）。
  final String subtitle;

  /// 视觉风格：`hand` / `motion` / `ui` / `data`。
  final String style;

  /// 声明时长（秒）；UI 以页面回传的真实值为准。
  final double duration;

  /// 短片文件名（相对 `assets/video/clip/`）。
  final String file;

  /// 标签（只读对照卡展示）。
  final List<String> tags;

  /// 严格解析：缺 `id` / `title`、时长非法都抛 [FormatException]。
  ///
  /// 目录解析走 [tryParse]（坏条目跳过），单条严格解析留给测试与未来编辑面。
  factory VideoClipInfo.fromJson(Map<String, dynamic> json) {
    final info = tryParse(json);
    if (info == null) {
      throw const FormatException('video clip entry is missing required fields');
    }
    return info;
  }

  /// 宽松解析：坏条目不抛异常，返回 null 交给调用方跳过。
  static VideoClipInfo? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final title = raw['title'];
    if (id is! String || id.trim().isEmpty) return null;
    if (title is! String || title.trim().isEmpty) return null;

    final durationRaw = raw['duration'];
    if (durationRaw is! num) return null;
    final duration = durationRaw.toDouble();
    if (!duration.isFinite || duration < 0) return null;

    final fileRaw = raw['file'];
    final file = (fileRaw is String && fileRaw.trim().isNotEmpty)
        ? fileRaw.trim()
        : '${id.trim()}.html';

    final tags = <String>[];
    final tagsRaw = raw['tags'];
    if (tagsRaw is List) {
      for (final tag in tagsRaw) {
        if (tag is String && tag.trim().isNotEmpty) tags.add(tag.trim());
      }
    }

    final subtitleRaw = raw['subtitle'];
    return VideoClipInfo(
      id: id.trim(),
      title: title.trim(),
      subtitle: subtitleRaw is String ? subtitleRaw.trim() : '',
      style: _normalizeStyle(raw['style']),
      duration: duration,
      file: file,
      tags: tags,
    );
  }

  @override
  String toString() => 'VideoClipInfo($id, $title, ${duration}s, $file)';
}

const List<String> _knownStyles = <String>['hand', 'motion', 'ui', 'data'];

String _normalizeStyle(Object? raw) {
  if (raw is! String) return 'hand';
  final value = raw.trim().toLowerCase();
  return _knownStyles.contains(value) ? value : 'hand';
}

/// 清单解析（纯函数）。
///
/// 顺序即数组顺序；非数组 / JSON 坏掉返回空表；单条缺字段或时长非法跳过；
/// 重复 `id` 只保留第一条（契约要求 id 唯一，这里不静默覆盖成两条）。
List<VideoClipInfo> parseVideoClips(String raw) {
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    return const <VideoClipInfo>[];
  }
  if (decoded is! List) return const <VideoClipInfo>[];

  final clips = <VideoClipInfo>[];
  final seen = <String>{};
  for (final entry in decoded) {
    final clip = VideoClipInfo.tryParse(entry);
    if (clip == null) continue;
    if (!seen.add(clip.id)) continue;
    clips.add(clip);
  }
  return clips;
}

/// 清单加载结果：失败不抛栈，`error` 是一句可以直接上屏的人话。
class VideoClipCatalog {
  const VideoClipCatalog({required this.clips, this.error = ''});

  const VideoClipCatalog.failed(String message)
      : clips = const <VideoClipInfo>[],
        error = message;

  final List<VideoClipInfo> clips;

  /// 空串 = 读取成功；非空 = 可以直接展示的一句人话。
  final String error;

  bool get ok => error.isEmpty;
}

/// 共享的清单 Future：检查面板与工作台读同一份，避免每次重建都重新解析。
///
/// 资源读取失败会返回 `VideoClipCatalog.failed`（不抛），调用方按人话展示。
Future<VideoClipCatalog>? _sharedCatalog;
Future<VideoClipCatalog> sharedVideoClips() => _sharedCatalog ??= loadVideoClips();

/// 测试或热替换后重置共享缓存。
void resetSharedVideoClips() => _sharedCatalog = null;

/// 从资源包读 `clips.json`（运行时离线，不联网）。
Future<VideoClipCatalog> loadVideoClips() async {
  final String raw;
  try {
    raw = await rootBundle.loadString(videoClipCatalogAsset);
  } catch (_) {
    return const VideoClipCatalog.failed('动效合成示例没载入，可以先看矢量动画');
  }
  final clips = parseVideoClips(raw);
  if (clips.isEmpty) {
    return const VideoClipCatalog.failed('动效合成示例清单是空的');
  }
  return VideoClipCatalog(clips: clips);
}

// ---------------------------------------------------------------------------
// 单文件装配
// ---------------------------------------------------------------------------

/// 幂等标记：页面里已经有这两个标记时不再重复注入引擎。
const String _engineCssMarker = 'data-nd-engine="css"';
const String _engineJsMarker = 'data-nd-engine="js"';

/// 把 `engine.css` / `engine.js` 内联进一支短片的 HTML，返回单文件页面。
///
/// 契约（§2）：
///  * CSS 注入到 `</head>` 之前；
///  * JS 注入到 `</body>` 之前；
///  * 找不到锚点时兜底（见下），两个引擎块都带幂等标记，重复调用不重复注入。
///
/// 兜底顺序：
///  * CSS：`</head>` → `<body` 之前 → 文档开头；
///  * JS：`</body>` → `</html>` → 第一个 `<script` 之前 → 文档末尾。
///
/// JS 的「第一个 `<script` 之前」兜底是给没有 `</body>` 的页面留的（现有
/// `sketch-friction.html` 就没有闭合标签）：短片脚本写成 `DOMContentLoaded`
/// 里才执行，所以注入点在前在后都能跑；但若某支短片仍是加载即调 `ND.scene`，
/// 把引擎放在它的 `<script>` 之前是唯一安全的位置。
String assembleVideoClipHtml({
  required String engineCss,
  required String engineJs,
  required String clipHtml,
}) {
  var html = clipHtml;

  if (!html.contains(_engineCssMarker)) {
    final block = '<style $_engineCssMarker>\n$engineCss\n</style>';
    final headEnd = _indexOfIgnoreCase(html, '</head>');
    final bodyStart = _indexOfIgnoreCase(html, '<body');
    if (headEnd >= 0) {
      html = html.replaceRange(headEnd, headEnd, block);
    } else if (bodyStart >= 0) {
      html = html.replaceRange(bodyStart, bodyStart, '$block\n');
    } else {
      html = '$block\n$html';
    }
  }

  if (!html.contains(_engineJsMarker)) {
    final block = '<script $_engineJsMarker>\n$engineJs\n</script>';
    final bodyEnd = _indexOfIgnoreCase(html, '</body>');
    final htmlEnd = _indexOfIgnoreCase(html, '</html>');
    final firstScript = _indexOfIgnoreCase(html, '<script');
    if (bodyEnd >= 0) {
      html = html.replaceRange(bodyEnd, bodyEnd, '$block\n');
    } else if (htmlEnd >= 0) {
      html = html.replaceRange(htmlEnd, htmlEnd, '$block\n');
    } else if (firstScript >= 0) {
      html = html.replaceRange(firstScript, firstScript, '$block\n');
    } else {
      html = '$html\n$block\n';
    }
  }

  return html;
}

int _indexOfIgnoreCase(String haystack, String needle) =>
    haystack.toLowerCase().indexOf(needle.toLowerCase());
