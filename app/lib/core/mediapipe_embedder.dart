// MediaPipe 推理面的**最小抽象**：服务层（mediapipe_service.dart）与
// 原生 adapter（mediapipe_embedder_adapter.dart）共用，本文件不 import 任何
// `package:mediapipe_*`——单元测试只依赖这个接口 + fake 实现就足够，
// 原生库与 isolate 只在生产路径（adapter + 真实模型）才被拉起。
import 'dart:async';

/// 文本/图像向量化后端。
///
/// 生产实现是 [MediaPipeEmbedderAdapter] 里的 isolate worker（Google
/// Universal Embedder，EmbeddingGemma 2）；测试注入 fake，绝不加载原生库。
abstract interface class MediaPipeEmbedder {
  /// [texts] 逐条编码，返回同序的向量（维度由模型决定，通常 768）。
  Future<List<List<double>>> embedTexts(List<String> texts);

  /// [paths] 是本机图片文件（JPEG/PNG）路径，逐张编码，返回同序向量。
  Future<List<List<double>>> embedImages(List<String> paths);

  /// 释放原生任务与 worker isolate；幂等。
  Future<void> dispose();
}

/// 由模型文件路径创建 embedder（生产默认：isolate adapter）。
typedef MediaPipeEmbedderFactory = Future<MediaPipeEmbedder> Function(
  String modelPath,
);

/// 后端不可用/推理失败（模型缺失、平台不支持、原生库没打进产物等）。
///
/// 服务层会把它转成 [EmbeddingResult] 的 unavailable 态——对外**不抛**
/// 未捕获异常是 M1 的硬约束。
final class MediaPipeEmbedderException implements Exception {
  const MediaPipeEmbedderException(this.message, {this.code = 'embedder_failed'});

  /// 机器可读的原因码（测试与降级文案按它分流）。
  final String code;

  /// 人可读说明（可直接进日志/轨迹）。
  final String message;

  @override
  String toString() => 'MediaPipeEmbedderException($code): $message';
}
