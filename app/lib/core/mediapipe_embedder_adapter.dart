// MediaPipe 原生 adapter——**本仓唯一 import `package:mediapipe_*` 的文件**。
//
// 职责只有两件：
//   1. 把 Google 官方 Universal Embedder（`mediapipe_retrieval` 0.3.x，
//      EmbeddingGemma 2，文本+图像同一向量空间）包成 [MediaPipeEmbedder]；
//   2. 让推理跑在**独立 worker isolate**——模型加载（几百 MB）与逐条编码
//      都不占用 UI isolate。Google 的实现本身也在自己的 worker 上跑任务，
//      这层 isolate 是我们自己的契约面：可注入、可 dispose、错误以数据返回。
//
// 隔离纪律：服务层（mediapipe_service.dart）不 import 本文件、不 import
// mediapipe 包——它只认 mediapipe_embedder.dart 的接口。生产接线在
// main.dart：`MediaPipeService.defaultEmbedderFactory = createMediaPipeEmbedder`。
// 单元测试永远注入 fake embedder，不加载原生库。
//
// 0.x API 备注（0.3.0 实测源码）：
//   - `UniversalEmbedderOptions` 三选一 model / modelPath / modelBytes——我们
//     传 modelPath（本服务自己做过 sha256 校验的本地文件）。
//   - `embedImage` 收的是图片**字节**不是路径，故路径在 worker 内读取。
//   - 结果 `UniversalEmbedderResult.embeddings` 按模型输出头排列，通常一个；
//     `Embedding.floatEmbedding` 为量化模型下可能为 null（此处显式报错，
//     不静默返回空向量）。
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:mediapipe_retrieval/mediapipe_retrieval.dart' as mp;

import 'mediapipe_embedder.dart';

/// 生产默认工厂：在独立 isolate 里创建 Universal Embedder。
Future<MediaPipeEmbedder> createMediaPipeEmbedder(String modelPath) =>
    MediaPipeEmbedderAdapter.spawn(modelPath);

/// 跨 isolate 的 embedder 句柄（主 isolate 侧）。
final class MediaPipeEmbedderAdapter implements MediaPipeEmbedder {
  MediaPipeEmbedderAdapter._(this._isolate, this._receivePort);

  final Isolate _isolate;
  final ReceivePort _receivePort;

  /// worker 的请求端口（ready 消息里带回来，握手完成前不可用）。
  late final SendPort _requestPort;
  final Map<int, Completer<Object?>> _pending = {};
  int _nextId = 1;
  bool _disposed = false;

  /// worker 死亡原因（isolate 崩了 / 启动失败后所有请求都按它失败）。
  String? _deathReason;

  /// 启动 worker：创建 embedder 并等它报 ready（模型加载在 worker 内）。
  static Future<MediaPipeEmbedder> spawn(String modelPath) async {
    if (modelPath.isEmpty) {
      throw const MediaPipeEmbedderException(
        '模型路径为空',
        code: 'model_path_empty',
      );
    }
    final receivePort = ReceivePort();
    final isolate = await Isolate.spawn<Map<String, Object?>>(
      _workerMain,
      {'sendPort': receivePort.sendPort, 'modelPath': modelPath},
      debugName: 'nondesign-mediapipe-embedder',
      onError: receivePort.sendPort,
      onExit: receivePort.sendPort,
      errorsAreFatal: true,
    );
    final adapter = MediaPipeEmbedderAdapter._(isolate, receivePort);
    final ready = Completer<SendPort>();
    adapter._attach(ready);
    try {
      adapter._requestPort = await ready.future;
    } on MediaPipeEmbedderException {
      adapter._shutdown();
      rethrow;
    }
    return adapter;
  }

  void _attach(Completer<SendPort> ready) {
    _receivePort.listen((message) {
      // onExit 发 null；onError 发 [error, stackTrace]（error 通常是 String）。
      if (message == null) {
        // isolate 退出：先记死因（后续请求立刻失败，不许永远挂在 SendPort 上）。
        _deathReason ??= 'embedder isolate exited';
        _failAll(_deathReason!);
        if (!ready.isCompleted) {
          ready.completeError(MediaPipeEmbedderException(
            'embedder isolate exited before it was ready',
            code: 'isolate_exited',
          ));
        }
        return;
      }
      if (message is List) {
        // onError 发 [error, stackTrace]（向量响应是 Map，不会撞这里）。
        final reason = 'embedder isolate error: ${message.isEmpty ? 'unknown' : message.first}';
        _deathReason = reason;
        _failAll(reason);
        if (!ready.isCompleted) {
          ready.completeError(MediaPipeEmbedderException(reason, code: 'isolate_error'));
        }
        return;
      }
      if (message is! Map) return;
      final id = message['id'];
      final ok = message['ok'] == true;
      if (id == 0) {
        // ready 握手（id 0 保留给启动）；重复握手只认第一个。
        if (ready.isCompleted) return;
        if (ok) {
          final port = message['port'];
          if (port is SendPort) {
            ready.complete(port);
          } else {
            ready.completeError(const MediaPipeEmbedderException(
              'embedder worker 未回传请求端口',
              code: 'isolate_protocol',
            ));
          }
        } else {
          ready.completeError(MediaPipeEmbedderException(
            '${message['error'] ?? '模型加载失败'}',
            code: '${message['code'] ?? 'model_load_failed'}',
          ));
        }
        return;
      }
      final completer = _pending.remove(id);
      if (completer == null) return;
      if (ok) {
        completer.complete(message['vectors']);
      } else {
        completer.completeError(MediaPipeEmbedderException(
          '${message['error'] ?? 'inference failed'}',
          code: '${message['code'] ?? 'inference_failed'}',
        ));
      }
    });
  }

  void _failAll(String reason) {
    final error = MediaPipeEmbedderException(reason, code: 'isolate_dead');
    final waiting = _pending.values.toList();
    _pending.clear();
    for (final completer in waiting) {
      if (!completer.isCompleted) completer.completeError(error);
    }
  }

  Future<List<List<double>>> _request(String cmd, Map<String, Object?> payload) async {
    if (_disposed) {
      throw const MediaPipeEmbedderException('embedder 已释放', code: 'disposed');
    }
    final death = _deathReason;
    if (death != null) {
      throw MediaPipeEmbedderException(death, code: 'isolate_dead');
    }
    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _requestPort.send({'id': id, 'cmd': cmd, ...payload});
    final vectors = await completer.future;
    return _normalizeVectors(vectors);
  }

  @override
  Future<List<List<double>>> embedTexts(List<String> texts) {
    if (texts.isEmpty) return Future.value(const []);
    return _request('embedTexts', {'texts': List<String>.of(texts)});
  }

  @override
  Future<List<List<double>>> embedImages(List<String> paths) {
    if (paths.isEmpty) return Future.value(const []);
    return _request('embedImages', {'paths': List<String>.of(paths)});
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (_deathReason != null) {
      // worker 已死：没有可等的 ack，直接收尸。
      _shutdown();
      return;
    }
    try {
      final id = _nextId++;
      final completer = Completer<Object?>();
      _pending[id] = completer;
      _requestPort.send({'id': id, 'cmd': 'dispose'});
      await completer.future.timeout(const Duration(seconds: 3));
    } catch (_) {
      // worker 已死/超时：直接收尸，别再等。
    } finally {
      _shutdown();
    }
  }

  void _shutdown() {
    _failAll('embedder 已释放');
    try {
      _receivePort.close();
    } catch (_) {}
    try {
      _isolate.kill(priority: Isolate.immediate);
    } catch (_) {}
  }

  static List<List<double>> _normalizeVectors(Object? raw) {
    if (raw is! List) {
      throw const MediaPipeEmbedderException('worker 返回的向量不是数组', code: 'bad_result');
    }
    final out = <List<double>>[];
    for (final row in raw) {
      if (row is! List) {
        throw const MediaPipeEmbedderException('向量行不是数组', code: 'bad_result');
      }
      out.add(List<double>.generate(row.length, (i) {
        final value = row[i];
        if (value is num) return value.toDouble();
        throw const MediaPipeEmbedderException('向量元素不是数值', code: 'bad_result');
      }, growable: false));
    }
    return out;
  }
}

/// worker isolate 入口（顶层函数，[Isolate.spawn] 要求）。
Future<void> _workerMain(Map<String, Object?> init) async {
  final mainPort = init['sendPort'] as SendPort;
  final modelPath = init['modelPath'] as String;
  final requests = ReceivePort();

  mp.UniversalEmbedder? embedder;
  try {
    embedder = await mp.UniversalEmbedder.create(
      mp.UniversalEmbedderOptions(modelPath: modelPath, delegate: mp.Delegate.cpu),
    );
  } catch (e) {
    mainPort.send({'id': 0, 'ok': false, 'error': '$e', 'code': 'model_load_failed'});
    requests.close();
    return;
  }
  mainPort.send({'id': 0, 'ok': true, 'port': requests.sendPort});

  await for (final message in requests) {
    if (message is! Map) continue;
    final id = (message['id'] as num?)?.toInt() ?? -1;
    final cmd = message['cmd'];
    try {
      switch (cmd) {
        case 'embedTexts':
          final texts = ((message['texts'] as List?) ?? const []).cast<String>();
          final vectors = <List<double>>[];
          for (final text in texts) {
            vectors.add(_firstVector(await embedder.embedText(text)));
          }
          mainPort.send({'id': id, 'ok': true, 'vectors': vectors});
        case 'embedImages':
          final paths = ((message['paths'] as List?) ?? const []).cast<String>();
          final vectors = <List<double>>[];
          for (final path in paths) {
            final bytes = await File(path).readAsBytes();
            vectors.add(_firstVector(await embedder.embedImage(bytes)));
          }
          mainPort.send({'id': id, 'ok': true, 'vectors': vectors});
        case 'dispose':
          await embedder.dispose();
          mainPort.send({'id': id, 'ok': true, 'vectors': const []});
          requests.close();
          return;
        default:
          mainPort.send({
            'id': id,
            'ok': false,
            'error': '未知命令：$cmd',
            'code': 'unknown_command',
          });
      }
    } catch (e) {
      mainPort.send({
        'id': id,
        'ok': false,
        'error': '$e',
        'code': e is MediaPipeEmbedderException ? e.code : 'inference_failed',
      });
    }
  }
}

/// 取第一个输出头的浮点向量（量化输出显式报错，不静默变空）。
List<double> _firstVector(mp.UniversalEmbedderResult result) {
  if (result.embeddings.isEmpty) {
    throw const MediaPipeEmbedderException(
      'embedder 未返回任何向量',
      code: 'empty_result',
    );
  }
  final embedding = result.embeddings.first;
  final values = embedding.floatEmbedding;
  if (values == null || values.isEmpty) {
    throw const MediaPipeEmbedderException(
      'embedder 返回量化向量（需要浮点输出）',
      code: 'quantized_result',
    );
  }
  return List<double>.generate(values.length, (i) => values[i], growable: false);
}
