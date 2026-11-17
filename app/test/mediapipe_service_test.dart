// MediaPipe 薄服务层（M1 底座）回归：模型路径 / 注册表 / 下载与 sha256 /
// 复用 / 探测降级 / isolate 推理契约。
//
// 纪律：这些测试**不加载原生库**、不联网、不碰真实模型——
//   - HTTP 全部走 MockClient；
//   - 模型用临时目录 + 现场计算的 sha256（同字节的假文件）；
//   - 推理注入 FakeEmbedder（MediaPipeEmbedder 接口），生产 adapter
//     （唯一 import mediapipe 包的文件）不在测试 import 图里。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nondesign/core/mediapipe_embedder.dart';
import 'package:nondesign/core/mediapipe_service.dart';
import 'package:nondesign/core/sha256_digest.dart';

/// 假 embedder：记录调用、返回可预测向量；可注入失败。
final class FakeEmbedder implements MediaPipeEmbedder {
  FakeEmbedder({this.dimension = 3});

  final int dimension;
  final List<List<String>> textBatches = [];
  final List<List<String>> imageBatches = [];
  bool disposed = false;
  MediaPipeEmbedderException? failWith;

  @override
  Future<List<List<double>>> embedTexts(List<String> texts) async {
    textBatches.add(List.of(texts));
    if (failWith != null) throw failWith!;
    return [
      for (final text in texts)
        List<double>.generate(dimension, (i) => (text.length + i).toDouble()),
    ];
  }

  @override
  Future<List<List<double>>> embedImages(List<String> paths) async {
    imageBatches.add(List.of(paths));
    if (failWith != null) throw failWith!;
    return [
      for (final path in paths)
        List<double>.generate(dimension, (i) => (path.length + i).toDouble()),
    ];
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

const _payload = 'fake-mediapipe-model-bytes\n';

void main() {
  late Directory temp;
  late MediaPipeEmbedderFactory? previousDefault;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('mediapipe_service_test');
    previousDefault = MediaPipeService.defaultEmbedderFactory;
    MediaPipeService.defaultEmbedderFactory = null;
  });

  tearDown(() async {
    MediaPipeService.defaultEmbedderFactory = previousDefault;
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  MediaPipeModelDescriptor descriptor({
    List<int>? bytes,
    String? sha256,
    String fileName = 'fixture.litertlm',
  }) {
    final data = bytes ?? utf8.encode(_payload);
    return MediaPipeModelDescriptor(
      id: 'fixture_model',
      task: MediaPipeTask.retrieval,
      fileName: fileName,
      url: 'https://example.invalid/$fileName',
      sha256: sha256 ?? sha256Hex(data),
      bytes: data.length,
    );
  }

  MediaPipeService service({
    http.Client? client,
    MediaPipeEmbedderFactory? factory,
    bool autoDownload = false,
  }) =>
      MediaPipeService(
        rootOverride: temp,
        httpClient: client,
        embedderFactory: factory,
        autoDownload: autoDownload,
      );

  group('模型路径解析（沿用 nonapp_cache 的平台规则）', () {
    test('桌面/临时根：<root>/models/mediapipe/<task>/<file>', () {
      final svc = service();
      expect(
        svc.modelPathFor(MediaPipeModels.universalEmbedder),
        '${temp.path}/models/mediapipe/retrieval/'
        'embeddinggemma-2-text-vision-440m.litertlm',
      );
    });

    test('不同 task 落到不同子目录', () {
      final svc = service();
      final text = MediaPipeModelDescriptor(
        id: 'x',
        task: MediaPipeTask.text,
        fileName: 'x.tflite',
      );
      final vision = MediaPipeModelDescriptor(
        id: 'y',
        task: MediaPipeTask.vision,
        fileName: 'y.tflite',
      );
      expect(svc.modelPathFor(text), contains('/models/mediapipe/text/x.tflite'));
      expect(svc.modelPathFor(vision), contains('/models/mediapipe/vision/y.tflite'));
    });
  });

  group('官方注册表（URL/sha256 必须是真实官方值）', () {
    test('Universal Embedder 条目逐字对齐官方包 RetrievalModels', () {
      const model = MediaPipeModels.universalEmbedder;
      expect(model.id, 'embedding_gemma_2_text_vision');
      expect(model.task, MediaPipeTask.retrieval);
      expect(model.fileName, 'embeddinggemma-2-text-vision-440m.litertlm');
      // 逐字取自 mediapipe_retrieval 0.3.0 lib/models.dart:
      // RetrievalModels.embeddingGemma2TextVision（Apache-2.0）。
      expect(
        model.sha256,
        '92dcbea108899e5d6e30d919b0744f90d9967e80c67a4ab5503ac16d54f62eb0',
      );
      expect(model.url, contains('huggingface.co/litert-community/'));
      expect(model.url, contains('e301f74d5551b0c2641bd5cb4652a76239d5c5f8'));
      expect(model.sha256!.length, 64);
      expect(model.pinned, isTrue);
      // 官方只公布「388 MB」近似值 → 精确字节数留空，不许编造。
      expect(model.bytes, isNull);
      expect(model.note, contains('388'));
    });

    test('注册表非空且 id 唯一', () {
      expect(MediaPipeModels.all, isNotEmpty);
      final ids = MediaPipeModels.all.map((m) => m.id).toSet();
      expect(ids.length, MediaPipeModels.all.length);
    });
  });

  group('ensureModel：下载 / sha256 / 原子落位 / 复用', () {
    test('下载成功后文件内容一致，进度回调有终值', () async {
      var requests = 0;
      final bytes = utf8.encode(_payload);
      final svc = service(
        client: MockClient((request) async {
          requests++;
          return http.Response.bytes(bytes, 200);
        }),
      );
      final model = descriptor();
      final progress = <(int, int?)>[];
      final file = await svc.ensureModel(model, onProgress: (r, t) => progress.add((r, t)));

      expect(requests, 1);
      expect(await file.readAsString(), _payload);
      expect(File(svc.modelPathFor(model)).existsSync(), isTrue);
      expect(progress, isNotEmpty);
      expect(progress.last.$1, bytes.length);
      expect(progress.last.$2, bytes.length);
      // 不留临时文件。
      final leftovers = temp
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.part'))
          .toList();
      expect(leftovers, isEmpty);
    });

    test('已存在且 hash 匹配 → 零网络请求直接复用', () async {
      var requests = 0;
      final svc = service(
        client: MockClient((request) async {
          requests++;
          return http.Response.bytes(utf8.encode(_payload), 200);
        }),
      );
      final model = descriptor();
      await svc.ensureModel(model);
      expect(requests, 1);

      // 新实例（模拟重启）：仍然不该发请求。
      final again = service(
        client: MockClient((request) async {
          requests++;
          return http.Response.bytes(utf8.encode(_payload), 200);
        }),
      );
      final file = await again.ensureModel(model);
      expect(requests, 1);
      expect(await file.readAsString(), _payload);
    });

    test('sha256 不匹配 → 删除临时文件并抛 sha256_mismatch', () async {
      final svc = service(
        client: MockClient((request) async => http.Response.bytes(utf8.encode('tampered'), 200)),
      );
      final model = descriptor(); // 期望 _payload 的 hash
      await expectLater(
        svc.ensureModel(model),
        throwsA(isA<MediaPipeModelException>()
            .having((e) => e.code, 'code', 'sha256_mismatch')
            .having((e) => e.expectedSha256, 'expected', model.sha256)),
      );
      expect(File(svc.modelPathFor(model)).existsSync(), isFalse);
      expect(
        temp.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.part')),
        isEmpty,
      );
    });

    test('本地文件内容已损坏 → 删掉重下', () async {
      var requests = 0;
      final svc = service(
        client: MockClient((request) async {
          requests++;
          return http.Response.bytes(utf8.encode(_payload), 200);
        }),
      );
      final model = descriptor();
      final target = File(svc.modelPathFor(model));
      await target.parent.create(recursive: true);
      await target.writeAsString('corrupt-not-the-model');

      final file = await svc.ensureModel(model);
      expect(requests, 1);
      expect(await file.readAsString(), _payload);
    });

    test('HTTP 非 200 → download_failed，盘上不留残片', () async {
      final svc = service(
        client: MockClient((request) async => http.Response('nope', 503)),
      );
      final model = descriptor();
      await expectLater(
        svc.ensureModel(model),
        throwsA(isA<MediaPipeModelException>()
            .having((e) => e.code, 'code', 'download_failed')),
      );
      expect(File(svc.modelPathFor(model)).existsSync(), isFalse);
      expect(temp.listSync(recursive: true).whereType<File>(), isEmpty);
    });

    test('未登记 URL/sha256 的条目 → model_unpinned，且不发请求', () async {
      var requests = 0;
      final svc = service(
        client: MockClient((request) async {
          requests++;
          return http.Response('', 200);
        }),
      );
      const model = MediaPipeModelDescriptor(
        id: 'not_pinned',
        task: MediaPipeTask.vision,
        fileName: 'todo.tflite',
      );
      await expectLater(
        svc.ensureModel(model),
        throwsA(isA<MediaPipeModelException>()
            .having((e) => e.code, 'code', 'model_unpinned')),
      );
      expect(requests, 0);
    });

    test('verifyModel：正确 true / 被篡改 false / 缺失 false', () async {
      final svc = service(
        client: MockClient((request) async => http.Response.bytes(utf8.encode(_payload), 200)),
      );
      final model = descriptor();
      expect(await svc.verifyModel(model), isFalse);
      await svc.ensureModel(model);
      expect(await svc.verifyModel(model), isTrue);
      await File(svc.modelPathFor(model)).writeAsString('tampered');
      expect(await svc.verifyModel(model), isFalse);
    });
  });

  group('probe / embed 降级（绝不抛未捕获异常）', () {
    test('平台不支持 → unsupportedPlatform，embed 返回 unavailable', () async {
      final svc = MediaPipeService(
        rootOverride: temp,
        platformSupport:
            const MediaPipePlatformSupport(supported: false, platform: 'macos/x64', reason: '不在支持矩阵'),
        embedderFactory: (_) async => FakeEmbedder(),
      );
      final availability = await svc.probe();
      expect(availability.status, MediaPipeStatus.unsupportedPlatform);
      expect(availability.supported, isFalse);
      expect(availability.available, isFalse);

      final result = await svc.embedTexts(['anything']);
      expect(result.ok, isFalse);
      expect(result.status, MediaPipeStatus.unsupportedPlatform);
      expect(result.vectors, isEmpty);
      expect(result.error, contains('不在支持矩阵'));
    });

    test('模型缺失 → modelMissing；默认不触发下载', () async {
      var requests = 0;
      final svc = service(
        client: MockClient((request) async {
          requests++;
          return http.Response.bytes(utf8.encode(_payload), 200);
        }),
        factory: (_) async => FakeEmbedder(),
      );
      final availability = await svc.probe();
      expect(availability.status, MediaPipeStatus.modelMissing);
      final result = await svc.embedTexts(['x']);
      expect(result.status, MediaPipeStatus.modelMissing);
      expect(requests, 0, reason: '388MB 模型不能因一次检索静默下载');
    });

    test('模型存在 → ready；embed 走注入的 fake embedder', () async {
      final svc = service(factory: (_) async => FakeEmbedder(dimension: 4));
      final model = MediaPipeModels.universalEmbedder;
      final file = File(svc.modelPathFor(model));
      await file.parent.create(recursive: true);
      await file.writeAsString('placeholder'); // probe 只验存在性

      final availability = await svc.probe();
      expect(availability.status, MediaPipeStatus.ready);
      expect(availability.modelPath, svc.modelPathFor(model));

      final result = await svc.embedTexts(['甲', '乙丙']);
      expect(result.ok, isTrue);
      expect(result.vectors.length, 2);
      expect(result.vectors.every((v) => v.length == 4), isTrue);
    });

    test('embedImages 传路径给 embedder', () async {
      final fake = FakeEmbedder();
      final svc = service(factory: (_) async => fake);
      await File(svc.modelPathFor(MediaPipeModels.universalEmbedder))
          .parent
          .create(recursive: true);
      await File(svc.modelPathFor(MediaPipeModels.universalEmbedder)).writeAsString('x');

      final result = await svc.embedImages(['/tmp/a.png', '/tmp/b.png']);
      expect(result.ok, isTrue);
      expect(fake.imageBatches.single, ['/tmp/a.png', '/tmp/b.png']);
      expect(result.vectors.length, 2);
    });

    test('未接线 embedder 工厂 → backendMissing（不抛）', () async {
      final svc = service();
      final model = MediaPipeModels.universalEmbedder;
      await File(svc.modelPathFor(model)).parent.create(recursive: true);
      await File(svc.modelPathFor(model)).writeAsString('x');

      final result = await svc.embedTexts(['x']);
      expect(result.ok, isFalse);
      expect(result.status, MediaPipeStatus.backendMissing);
    });

    test('embedder 抛异常 → inferenceFailed（带原因，不抛）', () async {
      final fake = FakeEmbedder()
        ..failWith = const MediaPipeEmbedderException('native boom', code: 'native_boom');
      final svc = service(factory: (_) async => fake);
      final model = MediaPipeModels.universalEmbedder;
      await File(svc.modelPathFor(model)).parent.create(recursive: true);
      await File(svc.modelPathFor(model)).writeAsString('x');

      final result = await svc.embedTexts(['x']);
      expect(result.ok, isFalse);
      expect(result.status, MediaPipeStatus.inferenceFailed);
      expect(result.error, contains('native boom'));
    });

    test('autoDownload=true 时缺失模型就地下载再推理', () async {
      var requests = 0;
      final svc = service(
        autoDownload: true,
        client: MockClient((request) async {
          requests++;
          return http.Response.bytes(utf8.encode(_payload), 200);
        }),
        factory: (_) async => FakeEmbedder(),
      );
      // universalEmbedder 用官方 sha256，假响应必然校验失败 → 这里只验证
      // 「确实尝试了下载」而不是「下载成功」（成功路径用 fixture descriptor 覆盖）。
      final result = await svc.embedTexts(['x']);
      expect(requests, 1, reason: 'autoDownload 打开时必须真的去下载');
      expect(result.ok, isFalse);
      expect(result.status, MediaPipeStatus.modelUnavailable,
          reason: '下载/校验失败按模型不可用降级，而不是抛异常');
      expect(result.error, contains('校验失败'));
    });

    test('空输入短路：不探测、不建 embedder', () async {
      var factoryCalls = 0;
      final svc = service(factory: (_) async {
        factoryCalls++;
        return FakeEmbedder();
      });
      final texts = await svc.embedTexts(const []);
      final images = await svc.embedImages(const []);
      expect(texts.ok, isTrue);
      expect(images.ok, isTrue);
      expect(texts.vectors, isEmpty);
      expect(factoryCalls, 0);
    });

    test('dispose 释放 embedder', () async {
      final fake = FakeEmbedder();
      final svc = service(factory: (_) async => fake);
      final model = MediaPipeModels.universalEmbedder;
      await File(svc.modelPathFor(model)).parent.create(recursive: true);
      await File(svc.modelPathFor(model)).writeAsString('x');
      await svc.embedTexts(['x']);
      await svc.dispose();
      expect(fake.disposed, isTrue);
    });
  });

  group('平台支持矩阵', () {
    test('detect() 返回 os/arch 形式的 target', () {
      final support = MediaPipePlatformSupport.detect();
      expect(support.platform, matches(RegExp(r'^[a-z]+/[A-Za-z0-9_]+$')));
      if (!support.supported) {
        expect(support.reason, isNotNull);
      }
    });
  });
}
