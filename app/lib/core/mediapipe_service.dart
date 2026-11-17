// MediaPipe for Flutter 的**薄服务层**（docs/plan-flutter-3.50-adoption.md N6/M1）。
//
// 只做三件事，不解释模型、不碰视觉语义：
//   1. 模型文件管理：注册表（id/task/url/sha256/bytes/fileName）+ 下载
//      （可注入 http 客户端、进度回调、临时文件 + rename 原子落位、sha256
//      校验失败即删）+ 已存在且 hash 匹配直接复用；
//   2. 推理封装：对外 embedTexts / embedImages，推理在独立 isolate 里跑
//      （见 mediapipe_embedder_adapter.dart；本文件不 import 任何
//      `package:mediapipe_*`，测试注入 fake embedder 即可）；
//   3. 探测：probe() 回答「平台支不支持 / 模型在不在」，缺模型或平台不支持
//      一律返回 unavailable 状态，**绝不抛未捕获异常**。
//
// 模型目录：`<appDataRoot>/models/mediapipe/<task>/<file>`（appDataRoot 见
// app_paths.dart：桌面 `~/.nondesign`，移动/无 HOME 走系统临时目录——与
// nonapp_cache 同一套规则）。模型**不随安装包分发**，首次用前显式下载。
//
// 注册表纪律：URL/sha256 只能逐字取自官方来源（pub 包内 `XxxModels` 常量或
// Google 官方文档），**绝不凭印象编造**；查不到可靠值的条目留空并在 [note]
// 里标 TODO（vision/text 家族本轮未登记，见 MediaPipeModels 的 TODO）。
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

import 'app_paths.dart';
import 'mediapipe_embedder.dart';
import 'sha256_digest.dart';

/// 任务家族（决定模型子目录；与 official 包的 family 名一致）。
enum MediaPipeTask {
  retrieval('retrieval'),
  text('text'),
  vision('vision');

  const MediaPipeTask(this.subdir);

  /// `models/mediapipe/<subdir>/` 的目录名。
  final String subdir;
}

/// 一个可下载模型的注册表条目。
///
/// [url] / [sha256] 为 null 表示**尚未核实**（不是「可以随便填」）——未 pinned
/// 的条目下载会显式报 `model_unpinned`，见 [MediaPipeModels] 的登记说明。
final class MediaPipeModelDescriptor {
  const MediaPipeModelDescriptor({
    required this.id,
    required this.task,
    required this.fileName,
    this.url,
    this.sha256,
    this.bytes,
    this.note,
  });

  /// 稳定 id（索引/日志/设置里引用它，别改）。
  final String id;

  /// 任务家族（决定 `models/mediapipe/<task>/` 子目录）。
  final MediaPipeTask task;

  /// 落盘文件名（官方扩展名要保留：MediaPipe 会按扩展名判断格式）。
  final String fileName;

  /// 官方 URL（或官方归档 + `#member`），null = 未核实。
  final String? url;

  /// 官方 sha256（小写 hex），null = 未核实。
  final String? sha256;

  /// 官方公布的**精确**字节数；只知近似大小时留 null（进度按不确定态呈现）。
  final int? bytes;

  /// 来源/限制说明（人读）。
  final String? note;

  /// 是否具备下载所需的绑定（url + sha256 都在）。
  bool get pinned => url != null && sha256 != null;
}

/// 官方模型注册表。
///
/// 本轮只登记 M1/M2 用得到的 Universal Embedder 模型；URL/sha256 **逐字复制**
/// 自官方包 `mediapipe_retrieval` 0.3.0 的 `lib/models.dart`：
/// `RetrievalModels.embeddingGemma2TextVision`（Apache-2.0，Hugging Face
/// `litert-community/embeddinggemma-2-text-vision-440m-litert-lm` 的固定
/// revision `e301f74d…`）。
abstract final class MediaPipeModels {
  /// EmbeddingGemma 2（text + vision，440M），Universal Embedder 的官方模型。
  static const MediaPipeModelDescriptor universalEmbedder = MediaPipeModelDescriptor(
    id: 'embedding_gemma_2_text_vision',
    task: MediaPipeTask.retrieval,
    fileName: 'embeddinggemma-2-text-vision-440m.litertlm',
    url: 'https://huggingface.co/litert-community/'
        'embeddinggemma-2-text-vision-440m-litert-lm/resolve/'
        'e301f74d5551b0c2641bd5cb4652a76239d5c5f8/'
        'embeddinggemma-2-text-vision-440m.litertlm',
    sha256: '92dcbea108899e5d6e30d919b0744f90d9967e80c67a4ab5503ac16d54f62eb0',
    // 官方包文档写「388 MB」但没有给精确字节数——留 null，别把近似值
    // 当精确值写进进度条（下载进度会退化为不确定态）。
    bytes: null,
    note: '388 MB（官方包文档口径，精确字节数未公布）；Apache-2.0',
  );

  /// 全部已登记条目。
  static const List<MediaPipeModelDescriptor> all = [universalEmbedder];

  // TODO(N6-M2/M3): 视觉与文本任务的官方模型尚未登记——本仓未核实
  // `mediapipe_vision` / `mediapipe_text` 各 `XxxModels` 常量的 URL/sha256。
  // 新增条目时**逐字**从 `~/.pub-cache/hosted/pub.dev/mediapipe_<family>-<ver>/lib/models.dart`
  // 复制，并在 note 里注明包版本 + 常量名；绝不凭印象填。候选（M3 用）：
  // ObjectDetector、ImageSegmenter/InteractiveSegmenter、TextEmbedder、TextClassifier。
}

/// 平台是否在官方支持矩阵内（检索/嵌入模型要求 64 位目标）。
///
/// 表与官方 `largeModelRuntimeTargets` 对齐：macos/arm64、linux/x64、
/// windows/x64、ios/arm64、android/arm64、android/x64。macOS x64（Intel）
/// 不在官方构建面内；移动 32 位 Android（armeabi-v7a）装不下这些模型。
final class MediaPipePlatformSupport {
  const MediaPipePlatformSupport({
    required this.supported,
    required this.platform,
    this.reason,
  });

  final bool supported;

  /// `os/arch`，如 `macos/arm64`（日志/降级文案用）。
  final String platform;

  /// 不支持时的原因（人读）。
  final String? reason;

  /// 按当前进程推导（可在测试里替换整个对象）。
  static MediaPipePlatformSupport detect() {
    if (kIsWeb) {
      return const MediaPipePlatformSupport(
        supported: false,
        platform: 'web',
        reason: 'Web 目标未接入（需要 WebGPU，且本仓无 web 产品面）',
      );
    }
    var arch = 'unknown';
    try {
      arch = Abi.current().toString().split('_').last;
    } catch (_) {
      // 极端环境取不到 ABI：按不支持处理，绝不猜。
    }
    final target = '${Platform.operatingSystem}/$arch';
    const supportedTargets = {
      'macos/arm64',
      'linux/x64',
      'windows/x64',
      'ios/arm64',
      'android/arm64',
      'android/x64',
    };
    if (supportedTargets.contains(target)) {
      return MediaPipePlatformSupport(supported: true, platform: target);
    }
    return MediaPipePlatformSupport(
      supported: false,
      platform: target,
      reason: '官方 MediaPipe 检索库不覆盖 $target（需要 64 位受支持目标）',
    );
  }
}

/// probe() 与推理结果共用的状态码。
enum MediaPipeStatus {
  /// 平台受支持且模型已就位。
  ready,

  /// 平台受支持，但模型文件不在本地（未下载）。
  modelMissing,

  /// 当前平台/架构不在官方支持矩阵内。
  unsupportedPlatform,

  /// 没接线 embedder 工厂（生产 = main.dart 注入；测试 = 注入 fake）。
  backendMissing,

  /// 模型文件不可用（下载失败/校验失败/未 pinned）。
  modelUnavailable,

  /// 推理失败（原生库缺失、模型损坏、编码出错等）。
  inferenceFailed,
}

/// `probe()` 的返回值。永远可构造、永远不抛。
final class MediaPipeAvailability {
  const MediaPipeAvailability({
    required this.status,
    required this.platform,
    required this.modelId,
    this.modelPath,
    this.reason,
  });

  final MediaPipeStatus status;
  final String platform;
  final String modelId;
  final String? modelPath;
  final String? reason;

  /// 平台是否受支持（与模型在不在无关）。
  bool get supported => status != MediaPipeStatus.unsupportedPlatform;

  /// 平台 + 模型都就绪。
  bool get available => status == MediaPipeStatus.ready;

  bool get modelReady => available;

  @override
  String toString() =>
      'MediaPipeAvailability(${status.name}, platform=$platform, model=$modelId'
      '${reason == null ? '' : ', reason=$reason'})';
}

/// 推理结果：成功带向量，失败带状态与原因——调用方永远不需要 try/catch。
final class EmbeddingResult {
  const EmbeddingResult._({
    required this.vectors,
    this.status,
    this.error,
    this.modelId,
  });

  /// 成功：向量与输入同序，维度由模型决定。
  const EmbeddingResult.ready(List<List<double>> vectors)
      : this._(vectors: vectors);

  /// 降级：没有向量，status 说明为什么。
  const EmbeddingResult.unavailable(
    MediaPipeStatus status,
    String reason, {
    String? modelId,
  }) : this._(vectors: const [], status: status, error: reason, modelId: modelId);

  final List<List<double>> vectors;

  /// null = 成功。
  final MediaPipeStatus? status;

  /// 失败原因（人读）。
  final String? error;

  final String? modelId;

  bool get ok => status == null;

  @override
  String toString() => ok
      ? 'EmbeddingResult(${vectors.length} vectors)'
      : 'EmbeddingResult(${status!.name}: $error)';
}

/// 模型层错误（下载/校验/未 pin）；服务层会把它转成 unavailable 结果。
final class MediaPipeModelException implements Exception {
  const MediaPipeModelException(
    this.code,
    this.message, {
    this.expectedSha256,
    this.actualSha256,
  });

  /// `model_unpinned` / `download_failed` / `sha256_mismatch` / `write_failed`
  final String code;
  final String message;
  final String? expectedSha256;
  final String? actualSha256;

  @override
  String toString() => 'MediaPipeModelException($code): $message';
}

/// 下载进度回调（[total] 为 null 表示服务端没给 Content-Length）。
typedef MediaPipeDownloadProgress = void Function(int received, int? total);

/// 模型下载 + 推理封装（无状态的服务对象，可安全复用）。
final class MediaPipeService {
  MediaPipeService({
    this.rootOverride,
    this.httpClient,
    this.embedderFactory,
    this.platformSupport,
    this.autoDownload = false,
  });

  /// 生产默认 embedder 工厂。
  ///
  /// 由 main.dart 注入 `createMediaPipeEmbedder`（唯一 import mediapipe 包的
  /// adapter）；单元测试不设置它，因此永远不加载原生库。未注入时推理按
  /// [MediaPipeStatus.backendMissing] 降级。
  static MediaPipeEmbedderFactory? defaultEmbedderFactory;

  /// 进程内共享实例（艺术架等 UI 入口用它；测试请自建）。
  static MediaPipeService? _shared;
  static MediaPipeService get shared => _shared ??= MediaPipeService();

  /// 数据根目录覆盖（测试用临时目录；默认走 [AppPaths]）。
  final Directory? rootOverride;

  /// 下载用 HTTP 客户端（测试注入 MockClient；默认每次下载自建并关闭）。
  final http.Client? httpClient;

  /// embedder 工厂（优先于 [defaultEmbedderFactory]；测试注入 fake）。
  final MediaPipeEmbedderFactory? embedderFactory;

  /// 平台支持覆盖（测试模拟不支持平台）。
  final MediaPipePlatformSupport? platformSupport;

  /// 模型缺失时 embed 是否顺手下载（默认 false：388 MB 的下载必须由用户
  /// 显式触发 [ensureModel]，不能在检索输入框里静默发生）。
  final bool autoDownload;

  MediaPipeEmbedder? _embedder;
  String? _embedderModelPath;
  Future<MediaPipeEmbedder>? _embedderSpawn;

  /// 数据根目录（测试可经构造参数或 [AppPaths.rootOverride] 覆盖）。
  Directory _root() => rootOverride ?? AppPaths.dataRoot();

  /// 模型应落到的绝对路径：`<root>/models/mediapipe/<task>/<file>`。
  String modelPathFor(MediaPipeModelDescriptor model) =>
      '${_root().path}/models/mediapipe/${model.task.subdir}/${model.fileName}';

  /// 模型子目录（不存在时创建）。
  Directory _modelDir(MediaPipeModelDescriptor model) {
    final dir = Directory('${_root().path}/models/mediapipe/${model.task.subdir}');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// 平台支持 + 模型是否就绪（只做存在性检查；完整 sha256 校验见
  /// [verifyModel]，下载/复用时由 [ensureModel] 做）。
  Future<MediaPipeAvailability> probe([
    MediaPipeModelDescriptor? model,
  ]) async {
    final descriptor = model ?? MediaPipeModels.universalEmbedder;
    final support = platformSupport ?? MediaPipePlatformSupport.detect();
    final path = modelPathFor(descriptor);
    if (!support.supported) {
      return MediaPipeAvailability(
        status: MediaPipeStatus.unsupportedPlatform,
        platform: support.platform,
        modelId: descriptor.id,
        modelPath: path,
        reason: support.reason,
      );
    }
    var exists = false;
    try {
      exists = await File(path).exists();
    } catch (_) {
      exists = false;
    }
    if (!exists) {
      return MediaPipeAvailability(
        status: MediaPipeStatus.modelMissing,
        platform: support.platform,
        modelId: descriptor.id,
        modelPath: path,
        reason: '模型未下载：$path',
      );
    }
    return MediaPipeAvailability(
      status: MediaPipeStatus.ready,
      platform: support.platform,
      modelId: descriptor.id,
      modelPath: path,
    );
  }

  /// 完整校验（sha256 与注册表比对）；文件不在/未 pinned 一律 false。
  Future<bool> verifyModel([MediaPipeModelDescriptor? model]) async {
    final descriptor = model ?? MediaPipeModels.universalEmbedder;
    final expected = descriptor.sha256;
    if (expected == null) return false;
    final file = File(modelPathFor(descriptor));
    if (!await file.exists()) return false;
    try {
      return (await sha256File(file)) == expected;
    } catch (_) {
      return false;
    }
  }

  /// 确保模型在本地：已存在且 sha256 匹配直接返回；否则下载 → 校验 →
  /// 原子 rename。校验失败删除临时文件并抛 [MediaPipeModelException]。
  ///
  /// 注意：这里持有一个 388 MB 文件的完整哈希窗口（几十毫秒到数秒），
  /// 调用方应在后台触发（UI 侧显示进度）。
  Future<File> ensureModel(
    MediaPipeModelDescriptor model, {
    MediaPipeDownloadProgress? onProgress,
  }) async {
    final target = File(modelPathFor(model));
    if (await target.exists()) {
      final expected = model.sha256;
      if (expected != null) {
        final actual = await sha256File(target);
        if (actual == expected) return target;
        // 内容不对（损坏/旧版本）：删掉重下，绝不让坏模型留在盘上。
        try {
          await target.delete();
        } catch (_) {}
      } else {
        throw MediaPipeModelException(
          'model_unpinned',
          '模型 ${model.id} 缺少官方 sha256，拒绝复用未校验文件',
        );
      }
    }
    if (!model.pinned) {
      throw MediaPipeModelException(
        'model_unpinned',
        '模型 ${model.id} 未登记官方 URL/sha256（注册表条目留空，见 MediaPipeModels 注释）',
      );
    }
    _modelDir(model);
    final temp = File('${target.path}.${DateTime.now().microsecondsSinceEpoch}.part');
    final client = httpClient ?? http.Client();
    final ownsClient = httpClient == null;
    try {
      final request = http.Request('GET', Uri.parse(model.url!));
      final response = await client.send(request);
      if (response.statusCode != 200) {
        throw MediaPipeModelException(
          'download_failed',
          '下载 ${model.id} 失败：HTTP ${response.statusCode}',
        );
      }
      final total = response.contentLength ?? model.bytes;
      final sink = temp.openWrite();
      var received = 0;
      try {
        await for (final chunk in response.stream) {
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(received, total);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      final actual = await sha256File(temp);
      if (actual != model.sha256) {
        throw MediaPipeModelException(
          'sha256_mismatch',
          '模型 ${model.id} 校验失败（期望 ${model.sha256}，实际 $actual）',
          expectedSha256: model.sha256,
          actualSha256: actual,
        );
      }
      await temp.rename(target.path);
      return target;
    } catch (e) {
      try {
        if (await temp.exists()) await temp.delete();
      } catch (_) {}
      if (e is MediaPipeModelException) rethrow;
      throw MediaPipeModelException('download_failed', '下载 ${model.id} 失败：$e');
    } finally {
      if (ownsClient) client.close();
    }
  }

  /// 文本向量化（模型缺失/平台不支持/后端未接线时返回 unavailable）。
  Future<EmbeddingResult> embedTexts(List<String> texts) async {
    if (texts.isEmpty) return const EmbeddingResult.ready([]);
    return _infer((embedder) => embedder.embedTexts(texts));
  }

  /// 图像向量化（[paths] 为本机 JPEG/PNG 路径）。
  Future<EmbeddingResult> embedImages(List<String> paths) async {
    if (paths.isEmpty) return const EmbeddingResult.ready([]);
    return _infer((embedder) => embedder.embedImages(paths));
  }

  Future<EmbeddingResult> _infer(
    Future<List<List<double>>> Function(MediaPipeEmbedder embedder) run,
  ) async {
    final descriptor = MediaPipeModels.universalEmbedder;
    final availability = await probe(descriptor);
    final willDownload =
        autoDownload && availability.status == MediaPipeStatus.modelMissing;
    if (!availability.available && !willDownload) {
      return EmbeddingResult.unavailable(
        availability.status,
        availability.reason ?? availability.status.name,
        modelId: descriptor.id,
      );
    }
    final factory = embedderFactory ?? defaultEmbedderFactory;
    if (factory == null) {
      return const EmbeddingResult.unavailable(
        MediaPipeStatus.backendMissing,
        'MediaPipe embedder 未接线（main.dart 注入 defaultEmbedderFactory）',
      );
    }
    try {
      var file = File(availability.modelPath!);
      if (!await file.exists() && autoDownload) {
        file = await ensureModel(descriptor);
      }
      if (!await file.exists()) {
        return EmbeddingResult.unavailable(
          MediaPipeStatus.modelMissing,
          '模型未下载：${file.path}',
          modelId: descriptor.id,
        );
      }
      final embedder = await _ensureEmbedder(factory, file.path);
      return EmbeddingResult.ready(await run(embedder));
    } on MediaPipeModelException catch (e) {
      return EmbeddingResult.unavailable(
        MediaPipeStatus.modelUnavailable,
        e.message,
        modelId: descriptor.id,
      );
    } on MediaPipeEmbedderException catch (e) {
      return EmbeddingResult.unavailable(
        MediaPipeStatus.inferenceFailed,
        e.message,
        modelId: descriptor.id,
      );
    } catch (e) {
      return EmbeddingResult.unavailable(
        MediaPipeStatus.inferenceFailed,
        '$e',
        modelId: descriptor.id,
      );
    }
  }

  /// 同一时刻只有一个 embedder 创建在飞；模型路径变了就重建。
  Future<MediaPipeEmbedder> _ensureEmbedder(
    MediaPipeEmbedderFactory factory,
    String path,
  ) async {
    final current = _embedder;
    if (current != null && _embedderModelPath == path) return current;
    final pending = _embedderSpawn;
    if (pending != null) return pending;
    final future = _spawnEmbedder(factory, path);
    _embedderSpawn = future;
    try {
      return await future;
    } finally {
      if (identical(_embedderSpawn, future)) _embedderSpawn = null;
    }
  }

  Future<MediaPipeEmbedder> _spawnEmbedder(
    MediaPipeEmbedderFactory factory,
    String path,
  ) async {
    await _disposeEmbedder();
    final created = await factory(path);
    _embedder = created;
    _embedderModelPath = path;
    return created;
  }

  Future<void> _disposeEmbedder() async {
    final embedder = _embedder;
    _embedder = null;
    _embedderModelPath = null;
    if (embedder == null) return;
    try {
      await embedder.dispose();
    } catch (_) {
      // 释放失败不阻断（isolate 可能已死）。
    }
  }

  /// 释放 embedder（应用退出/切项目时调用；之后可继续 embed，会重新创建）。
  Future<void> dispose() => _disposeEmbedder();
}

/// 便捷：JSON 摘要（调试/日志，不含向量）。
String describeAvailability(MediaPipeAvailability availability) =>
    jsonEncode({
      'status': availability.status.name,
      'platform': availability.platform,
      'model': availability.modelId,
      if (availability.modelPath != null) 'path': availability.modelPath,
      if (availability.reason != null) 'reason': availability.reason,
    });
