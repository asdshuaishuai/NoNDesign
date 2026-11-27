/// 3D 视频帧证据：单帧 PNG 的 data URL → 字节 + 上限校验。
///
/// 设计约束见 `docs/design/video3d-execution.md` §4：
///  * 帧证据经既有截图桥回传（页面 `NONVIDEO3D_PLAYER.capture(frame)`）；
///  * 单帧、帧数、总量都有上限，超限**显性失败**（不静默截断、不写空白文件）；
///  * 本层是纯 Dart：不碰文件、不碰 WebView，落盘由项目存储负责。
library;

import 'dart:convert';
import 'dart:typed_data';

/// 单帧 PNG 上限（与 3D 建模截图证据同档：8 MiB）。
const int video3dEvidenceMaxBytes = 8 * 1024 * 1024;

/// 一次取证允许的帧数上限。
const int video3dEvidenceMaxFrames = 120;

/// 一次取证允许的总字节上限（64 MiB）。
const int video3dEvidenceMaxTotalBytes = 64 * 1024 * 1024;

/// 稳定失败码（工具/存储/UI 共用；原始诊断只进折叠详情）。
const String video3dEvidenceEmptyCode = 'video3d_evidence_empty';
const String video3dEvidenceTooLargeCode = 'video3d_evidence_too_large';
const String video3dEvidenceLimitCode = 'video3d_evidence_limit';
const String video3dEvidenceFormatCode = 'video3d_evidence_format';

/// 抓帧通道的三类失败：预览没就绪 / 页面没回证据（超时）/ 页面报错。
const String video3dCaptureUnavailableCode = 'video3d_capture_unavailable';
const String video3dCaptureTimeoutCode = 'video3d_capture_timeout';
const String video3dCaptureFailedCode = 'video3d_capture_failed';

/// 抓帧等待上限（每帧）。
const Duration video3dCaptureTimeout = Duration(seconds: 5);

/// 帧号越界（工具入参校验；不夹取、不猜）。
const String video3dFramesOutOfRangeCode = 'video3d_frames_out_of_range';

/// 抓帧运行器：由工作台在预览面就绪时注册，工具经 store 调用。
///
/// 参数是项目名与整数帧列表；返回解码后的 PNG 证据。没有注册 = 预览没打开，
/// 调用方必须显性失败（`video3d_capture_unavailable`），不能静默返回空列表。
typedef Video3dCaptureRunner =
    Future<List<Video3dFrameEvidence>> Function(String project, List<int> frames);

/// 一帧已解码的证据。
final class Video3dFrameEvidence {
  const Video3dFrameEvidence({
    required this.frame,
    required this.bytes,
    required this.renderer,
  });

  /// 整数帧号（0 基，已按帧表夹取到合法区间）。
  final int frame;

  /// PNG 字节（已解码）。
  final Uint8List bytes;

  /// 产出这一帧的渲染器标识（页面如实回传）。
  final String renderer;

  int get byteLength => bytes.length;
}

/// 证据解码/校验失败。
final class Video3dEvidenceError implements Exception {
  const Video3dEvidenceError(this.code, this.message, [this.detail = '']);

  /// 稳定机器码：`video3d_evidence_*`。
  final String code;

  /// 人话（可直接映射失败码表）。
  final String message;

  /// 原始诊断（只进折叠的技术详情）。
  final String detail;

  @override
  String toString() => 'Video3dEvidenceError($code: $message)';
}

/// 把页面回传的 `data:image/png;base64,…` 解成 PNG 字节。
///
/// 只接受 PNG（不猜格式）；空载荷、非 PNG、超限都显性抛错。
Uint8List decodeVideo3dEvidenceDataUrl(
  String dataUrl, {
  int maxBytes = video3dEvidenceMaxBytes,
}) {
  const String prefix = 'data:image/png;base64,';
  if (!dataUrl.startsWith(prefix)) {
    throw const Video3dEvidenceError(
      video3dEvidenceFormatCode,
      '帧证据不是 PNG 数据',
      'unsupported data url prefix',
    );
  }
  final String payload = dataUrl.substring(prefix.length).trim();
  if (payload.isEmpty) {
    throw const Video3dEvidenceError(
      video3dEvidenceEmptyCode,
      '这一帧没有拿到画面数据',
    );
  }
  // base64 长度线性于字节数：先按长度粗筛，避免为超大载荷分配内存。
  final int roughBytes = (payload.length * 3) ~/ 4;
  if (roughBytes > maxBytes + 1024) {
    throw Video3dEvidenceError(
      video3dEvidenceTooLargeCode,
      '单帧证据超过上限',
      '$roughBytes bytes',
    );
  }
  Uint8List bytes;
  try {
    bytes = base64Decode(payload);
  } on FormatException catch (error) {
    throw Video3dEvidenceError(
      video3dEvidenceFormatCode,
      '帧证据数据坏了',
      '$error',
    );
  }
  if (bytes.isEmpty) {
    throw const Video3dEvidenceError(
      video3dEvidenceEmptyCode,
      '这一帧没有拿到画面数据',
    );
  }
  if (bytes.length > maxBytes) {
    throw Video3dEvidenceError(
      video3dEvidenceTooLargeCode,
      '单帧证据超过上限',
      '${bytes.length} bytes',
    );
  }
  // PNG 魔数校验：不把坏字节当图片写盘。
  if (bytes.length < 8 ||
      bytes[0] != 0x89 ||
      bytes[1] != 0x50 ||
      bytes[2] != 0x4E ||
      bytes[3] != 0x47) {
    throw const Video3dEvidenceError(
      video3dEvidenceFormatCode,
      '帧证据不是有效的 PNG',
      'png signature mismatch',
    );
  }
  return bytes;
}

/// 一次取证的总量校验：帧数与总字节都必须在限内。
void checkVideo3dEvidenceBudget(List<Video3dFrameEvidence> frames) {
  if (frames.length > video3dEvidenceMaxFrames) {
    throw Video3dEvidenceError(
      video3dEvidenceLimitCode,
      '一次取证帧数超过上限',
      '${frames.length} > $video3dEvidenceMaxFrames',
    );
  }
  int total = 0;
  for (final Video3dFrameEvidence evidence in frames) {
    total += evidence.byteLength;
  }
  if (total > video3dEvidenceMaxTotalBytes) {
    throw Video3dEvidenceError(
      video3dEvidenceLimitCode,
      '这次取证总量超过上限',
      '$total > $video3dEvidenceMaxTotalBytes',
    );
  }
}
