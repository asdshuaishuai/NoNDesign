/// 引擎短片帧证据：单帧 PNG 的 data URL → 字节 + 上限校验。
///
/// 与 3D 视频证据同族纪律（`video3d_evidence.dart`）：
///  * 证据经页面 `NONSHORT_PLAYER.capture(frame)` 回传（桥 `evidence`）；
///  * 只接受 PNG（不猜格式）；空载荷/非 PNG/坏 base64/超限一律**显性失败**；
///  * 单帧 ≤8 MiB、一次 ≤120 帧、总量 ≤64 MiB；
///  * 本层纯 Dart：不碰文件、不碰 WebView，落盘由项目存储负责。
library;

import 'dart:convert';
import 'dart:typed_data';

/// 单帧 PNG 上限（与 3D 视频证据同档）。
const int videoShortEvidenceMaxBytes = 8 * 1024 * 1024;

/// 一次取证允许的帧数上限。
const int videoShortEvidenceMaxFrames = 120;

/// 一次取证允许的总字节上限（64 MiB）。
const int videoShortEvidenceMaxTotalBytes = 64 * 1024 * 1024;

/// 稳定失败码（工具/存储/UI 共用；原始诊断只进折叠详情）。
const String videoShortEvidenceEmptyCode = 'video_short_evidence_empty';
const String videoShortEvidenceFormatCode = 'video_short_evidence_format';
const String videoShortEvidenceTooLargeCode = 'video_short_evidence_too_large';
const String videoShortEvidenceLimitCode = 'video_short_evidence_limit';
const String videoShortCaptureUnavailableCode = 'video_short_capture_unavailable';
const String videoShortCaptureTimeoutCode = 'video_short_capture_timeout';
const String videoShortCaptureFailedCode = 'video_short_capture_failed';
const String videoShortFramesOutOfRangeCode = 'video_short_frames_out_of_range';

/// 抓帧等待上限（每帧）。
const Duration videoShortCaptureTimeout = Duration(seconds: 8);

/// 抓帧运行器：由工作台在短片预览面就绪时注册，工具经 store 调用。
typedef VideoShortCaptureRunner =
    Future<List<VideoShortFrameEvidence>> Function(
      String project,
      List<int> frames,
    );

/// 一帧已解码的短片证据。
final class VideoShortFrameEvidence {
  const VideoShortFrameEvidence({
    required this.frame,
    required this.bytes,
    required this.renderer,
    required this.vfx,
  });

  final int frame;
  final Uint8List bytes;

  /// 出这一帧的引擎渲染面（`phaser4_canvas`）。
  final String renderer;

  /// VFX 渲染面（`pixelfx_pixels` / `placeholder_markers`）。
  final String vfx;

  int get byteLength => bytes.length;
}

/// 证据解码/校验失败。
final class VideoShortEvidenceError implements Exception {
  const VideoShortEvidenceError(this.code, this.message, [this.detail = '']);

  final String code;
  final String message;
  final String detail;

  @override
  String toString() => 'VideoShortEvidenceError($code: $message)';
}

/// 把 `data:image/png;base64,…` 解成 PNG 字节（只接受 PNG）。
Uint8List decodeVideoShortEvidenceDataUrl(
  String dataUrl, {
  int maxBytes = videoShortEvidenceMaxBytes,
}) {
  const String prefix = 'data:image/png;base64,';
  if (!dataUrl.startsWith(prefix)) {
    throw const VideoShortEvidenceError(
      videoShortEvidenceFormatCode,
      '帧证据不是 PNG 数据',
      'unsupported data url prefix',
    );
  }
  final String payload = dataUrl.substring(prefix.length).trim();
  if (payload.isEmpty) {
    throw const VideoShortEvidenceError(
      videoShortEvidenceEmptyCode,
      '这一帧没有拿到画面数据',
    );
  }
  final int roughBytes = (payload.length * 3) ~/ 4;
  if (roughBytes > maxBytes + 1024) {
    throw VideoShortEvidenceError(
      videoShortEvidenceTooLargeCode,
      '单帧证据超过上限',
      '$roughBytes bytes',
    );
  }
  Uint8List bytes;
  try {
    bytes = base64Decode(payload);
  } on FormatException catch (error) {
    throw VideoShortEvidenceError(
      videoShortEvidenceFormatCode,
      '帧证据数据坏了',
      '$error',
    );
  }
  if (bytes.isEmpty) {
    throw const VideoShortEvidenceError(
      videoShortEvidenceEmptyCode,
      '这一帧没有拿到画面数据',
    );
  }
  if (bytes.length > maxBytes) {
    throw VideoShortEvidenceError(
      videoShortEvidenceTooLargeCode,
      '单帧证据超过上限',
      '${bytes.length} bytes',
    );
  }
  // PNG 魔数：不把坏字节当图片写盘。
  if (bytes.length < 8 ||
      bytes[0] != 0x89 ||
      bytes[1] != 0x50 ||
      bytes[2] != 0x4E ||
      bytes[3] != 0x47) {
    throw const VideoShortEvidenceError(
      videoShortEvidenceFormatCode,
      '帧证据不是有效的 PNG',
      'png signature mismatch',
    );
  }
  return bytes;
}

/// 一次取证的总量校验：帧数与总字节都必须在限内。
void checkVideoShortEvidenceBudget(List<VideoShortFrameEvidence> frames) {
  if (frames.length > videoShortEvidenceMaxFrames) {
    throw VideoShortEvidenceError(
      videoShortEvidenceLimitCode,
      '一次取证帧数超过上限',
      '${frames.length} > $videoShortEvidenceMaxFrames',
    );
  }
  int total = 0;
  for (final VideoShortFrameEvidence evidence in frames) {
    total += evidence.byteLength;
  }
  if (total > videoShortEvidenceMaxTotalBytes) {
    throw VideoShortEvidenceError(
      videoShortEvidenceLimitCode,
      '这次取证总量超过上限',
      '$total > $videoShortEvidenceMaxTotalBytes',
    );
  }
}
