// 离线语义检索索引（M2 首个价值切片）回归：
// 建索引 / 增量（只重算变化项）/ 余弦排序 / 损坏恢复 / 空与维度不一致降级。
//
// 全部用 fake embedder + 临时目录：不联网、不加载 MediaPipe 原生库。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nondesign/core/embedding_index.dart';
import 'package:nondesign/core/mediapipe_embedder.dart';
import 'package:nondesign/core/mediapipe_service.dart';

/// 记录调用文本的假 embedder；[vectorsFor] 决定输出（默认按关键词给固定向量）。
final class RecordingEmbedder implements Embedder {
  RecordingEmbedder({this.vectorsFor, this.throwOnEmbed = false, this.dimension = 2});

  final List<double> Function(String text)? vectorsFor;
  final bool throwOnEmbed;
  final int dimension;
  final List<String> seen = [];
  int calls = 0;

  @override
  Future<List<List<double>>> embed(List<String> texts) async {
    calls++;
    seen.addAll(texts);
    if (throwOnEmbed) throw StateError('embedder offline');
    return [
      for (final text in texts)
        vectorsFor?.call(text) ?? List<double>.filled(dimension, text.length.toDouble()),
    ];
  }
}

List<double> keywordVectors(String text) {
  if (text.contains('热')) return [1, 0];
  if (text.contains('视频') || text.contains('Video')) return [0, 1];
  return [0.6, 0.8];
}

EmbeddingDoc doc(String id, String kind, String title, [String text = '']) =>
    EmbeddingDoc(id: id, kind: kind, title: title, text: text, ref: id);

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('embedding_index_test');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  final docs = [
    doc('hotapp:alpha', 'hotapp', '热应用甲', '一个热应用'),
    doc('video:beta', 'video', '视频乙', '渲染产物'),
    doc('three:gamma', 'three', '3D 丙', 'three.js 场景'),
  ];

  group('建索引与落盘', () {
    test('全量构建：条数/维度/文件都在', () async {
      final embedder = RecordingEmbedder(vectorsFor: keywordVectors);
      final index = EmbeddingIndex(embedder: embedder, rootOverride: temp);
      final result = await index.sync(docs);

      expect(result.total, 3);
      expect(result.embedded, 3);
      expect(result.reused, 0);
      expect(result.removed, 0);
      expect(result.degraded, isFalse);
      expect(index.entryCount, 3);
      expect(index.dimension, 2);
      expect(index.hasVectors, isTrue);
      expect(File(index.indexFilePath).existsSync(), isTrue);

      final decoded = jsonDecode(await File(index.indexFilePath).readAsString());
      expect(decoded['formatVersion'], EmbeddingIndex.formatVersion);
      expect((decoded['entries'] as List).length, 3);
    });

    test('重建索引（同一文件）能读回向量', () async {
      final embedder = RecordingEmbedder(vectorsFor: keywordVectors);
      await EmbeddingIndex(embedder: embedder, rootOverride: temp).sync(docs);

      final reloaded = EmbeddingIndex(embedder: embedder, rootOverride: temp);
      await reloaded.load();
      expect(reloaded.entryCount, 3);
      expect(reloaded.dimension, 2);
      expect(reloaded.hasVectors, isTrue);
      expect(reloaded.entries.first.vector, keywordVectors('热应用甲\n一个热应用'));
    });

    test('空文档列表清空索引', () async {
      final embedder = RecordingEmbedder(vectorsFor: keywordVectors);
      final index = EmbeddingIndex(embedder: embedder, rootOverride: temp);
      await index.sync(docs);
      final result = await index.sync(const []);
      expect(result.removed, 3);
      expect(index.entryCount, 0);
      expect(index.hasVectors, isFalse);
    });
  });

  group('增量更新（content hash 未变的条目复用旧向量）', () {
    test('只把变化项送进 embedder', () async {
      final embedder = RecordingEmbedder(vectorsFor: keywordVectors);
      final index = EmbeddingIndex(embedder: embedder, rootOverride: temp);
      await index.sync(docs);
      final before = {for (final e in index.entries) e.id: e.vector};
      expect(embedder.seen.length, 3);

      final changed = [
        docs[0],
        // 标题变化 → hash 变 → 只有它要重算。
        doc('video:beta', 'video', '视频乙改名', '渲染产物'),
        docs[2],
      ];
      final result = await index.sync(changed);

      expect(result.reused, 2);
      expect(result.embedded, 1);
      expect(result.degraded, isFalse);
      expect(embedder.seen.length, 4, reason: '第二次只该多算 1 条');
      expect(embedder.seen.last, contains('视频乙改名'));

      final unchanged = index.entries.firstWhere((e) => e.id == 'hotapp:alpha');
      expect(unchanged.vector, equals(before['hotapp:alpha']));
      final updated = index.entries.firstWhere((e) => e.id == 'video:beta');
      expect(updated.title, '视频乙改名');
      expect(updated.hash, isNot(docs[1].contentHash));
    });

    test('条目消失 → removed 计数并从索引删除', () async {
      final embedder = RecordingEmbedder(vectorsFor: keywordVectors);
      final index = EmbeddingIndex(embedder: embedder, rootOverride: temp);
      await index.sync(docs);
      final result = await index.sync([docs[0]]);
      expect(result.removed, 2);
      expect(index.entryCount, 1);
      expect(index.entries.single.id, 'hotapp:alpha');
    });

    test('同样文档重复 sync → 零嵌入调用', () async {
      final embedder = RecordingEmbedder(vectorsFor: keywordVectors);
      final index = EmbeddingIndex(embedder: embedder, rootOverride: temp);
      await index.sync(docs);
      final callsAfterFirst = embedder.calls;
      final writesAfterFirst = index.writeCount;
      final result = await index.sync(docs);
      expect(result.reused, 3);
      expect(result.embedded, 0);
      expect(embedder.calls, callsAfterFirst);
      expect(index.writeCount, writesAfterFirst,
          reason: '无变化的 sync 不该重写索引文件（每次搜索都会 sync）');

      await index.sync([docs[0], docs[1], doc('three:gamma', 'three', '3D 丙改名', 'scene')]);
      expect(index.writeCount, writesAfterFirst + 1);
    });
  });

  group('余弦检索排序', () {
    test('最相似条目排第一，topK 生效', () async {
      final embedder = RecordingEmbedder(vectorsFor: keywordVectors);
      final index = EmbeddingIndex(embedder: embedder, rootOverride: temp);
      await index.sync(docs);

      final outcome = await index.search('热应用', topK: 2);
      expect(outcome.semantic, isTrue);
      expect(outcome.reason, isNull);
      expect(outcome.hits.first.entry.id, 'hotapp:alpha');
      expect(outcome.hits.first.score, greaterThan(0.99));
      expect(outcome.hits.length, lessThanOrEqualTo(2));

      final single = await index.search('热应用', topK: 1);
      expect(single.hits.length, 1);
    });

    test('低于 minScore 的条目不返回（不拿噪音填货架）', () async {
      final embedder = RecordingEmbedder(vectorsFor: keywordVectors);
      final index = EmbeddingIndex(embedder: embedder, rootOverride: temp, minScore: 0.9);
      await index.sync(docs);
      final outcome = await index.search('热应用');
      expect(outcome.semantic, isTrue);
      expect(outcome.hits.every((h) => h.score >= 0.9), isTrue);
    });

    test('空查询返回空结果', () async {
      final embedder = RecordingEmbedder(vectorsFor: keywordVectors);
      final index = EmbeddingIndex(embedder: embedder, rootOverride: temp);
      await index.sync(docs);
      final outcome = await index.search('   ');
      expect(outcome.hits, isEmpty);
      expect(outcome.semantic, isFalse);
      expect(outcome.reason, isNull);
    });
  });

  group('降级（空索引 / 无 embedder / 维度不一致 / 抛错）', () {
    test('空索引：semantic=false 且带原因', () async {
      final index = EmbeddingIndex(embedder: RecordingEmbedder(), rootOverride: temp);
      final outcome = await index.search('anything');
      expect(outcome.semantic, isFalse);
      expect(outcome.hits, isEmpty);
      expect(outcome.reason, isNotNull);
      expect(index.lastDegradedReason, isNotNull);
    });

    test('没有 embedder：条目仍可关键词检索（大小写不敏感）', () async {
      final index = EmbeddingIndex(rootOverride: temp);
      final result = await index.sync([
        doc('video:beta', 'video', 'Video Beta', 'A rendered clip'),
        doc('three:gamma', 'three', '3D 丙', '场景'),
      ]);
      expect(result.degraded, isTrue);
      expect(result.error, isNotNull);
      expect(index.hasVectors, isFalse);

      final outcome = await index.search('video');
      expect(outcome.semantic, isFalse);
      expect(outcome.hits.length, 1);
      expect(outcome.hits.single.entry.id, 'video:beta');
      expect(outcome.reason, isNotNull);

      final byText = await index.search('rendered');
      expect(byText.hits.single.entry.id, 'video:beta');
      final noHit = await index.search('不存在词');
      expect(noHit.hits, isEmpty);
    });

    test('查询向量维度与索引不一致 → 退化为子串并说明原因', () async {
      final dim2 = RecordingEmbedder(vectorsFor: keywordVectors);
      await EmbeddingIndex(embedder: dim2, rootOverride: temp).sync(docs);

      final dim3 = RecordingEmbedder(dimension: 3);
      final index = EmbeddingIndex(embedder: dim3, rootOverride: temp);
      await index.load();
      expect(index.dimension, 2);

      final outcome = await index.search('视频');
      expect(outcome.semantic, isFalse);
      expect(outcome.reason, contains('维度'));
      expect(outcome.hits.single.entry.id, 'video:beta');
    });

    test('embedder 抛错 → sync 降级 + 检索退子串', () async {
      final index = EmbeddingIndex(
        embedder: RecordingEmbedder(throwOnEmbed: true),
        rootOverride: temp,
      );
      final result = await index.sync(docs);
      expect(result.degraded, isTrue);
      expect(result.error, contains('向量化失败'));
      expect(index.hasVectors, isFalse);

      final outcome = await index.search('热应用');
      expect(outcome.semantic, isFalse);
      expect(outcome.hits.single.entry.id, 'hotapp:alpha');
    });

    test('向量模型换了维度 → 整库重嵌一次', () async {
      final dim2 = RecordingEmbedder(vectorsFor: (t) => [1, 0]);
      await EmbeddingIndex(embedder: dim2, rootOverride: temp).sync(docs);

      final dim3 = RecordingEmbedder(vectorsFor: (_) => [1, 0, 0]);
      final index = EmbeddingIndex(embedder: dim3, rootOverride: temp);
      final result = await index.sync([
        docs[0],
        docs[1],
        doc('three:gamma', 'three', '3D 丙改名', 'three.js 场景'),
      ]);
      expect(result.embedded, 3, reason: '模型维度变化必须整库重嵌');
      expect(index.dimension, 3);
      expect(index.entries.every((e) => e.vector!.length == 3), isTrue);
    });
  });

  group('损坏/异构索引文件恢复', () {
    test('坏 JSON → 清空重置并把原文件改名 .corrupt', () async {
      final index = EmbeddingIndex(embedder: RecordingEmbedder(), rootOverride: temp);
      final file = File(index.indexFilePath);
      await file.parent.create(recursive: true);
      await file.writeAsString('{ this is not json');

      await index.load();
      expect(index.entryCount, 0);
      expect(index.lastError, contains('损坏'));
      expect(File('${index.indexFilePath}.corrupt').existsSync(), isTrue);

      // 重置后仍能正常建索引（不让一次坏文件炸掉整条检索线）。
      await index.sync(docs);
      expect(index.entryCount, 3);
    });

    test('坏条目跳过、好条目保留', () async {
      final good = EmbeddingEntry(
        id: 'hotapp:alpha',
        kind: 'hotapp',
        title: '热应用甲',
        text: '',
        ref: 'hotapp:alpha',
        hash: docs[0].contentHash,
        vector: [1, 0],
      );
      final payload = {
        'formatVersion': EmbeddingIndex.formatVersion,
        'modelId': 'embedding_gemma_2_text_vision',
        'dimension': 2,
        'entries': [
          good.toJson(),
          {'id': 42}, // 坏条目：id 不是字符串
          'garbage',
        ],
      };
      final index = EmbeddingIndex(embedder: RecordingEmbedder(), rootOverride: temp);
      final file = File(index.indexFilePath);
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(payload));

      await index.load();
      expect(index.entryCount, 1);
      expect(index.hasVectors, isTrue);
      expect(index.lastError, isNull);
    });

    test('formatVersion 不认识 → 重置', () async {
      final index = EmbeddingIndex(embedder: RecordingEmbedder(), rootOverride: temp);
      final file = File(index.indexFilePath);
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode({'formatVersion': 999, 'entries': []}));
      await index.load();
      expect(index.entryCount, 0);
      expect(index.lastError, contains('formatVersion'));
    });

    test('向量模型不同 → 条目保留、向量作废（子串仍可用）', () async {
      final embedder = RecordingEmbedder(vectorsFor: keywordVectors);
      await EmbeddingIndex(embedder: embedder, rootOverride: temp).sync(docs);

      final other = EmbeddingIndex(
        embedder: embedder,
        rootOverride: temp,
        modelId: 'another_embedding_model',
      );
      await other.load();
      expect(other.entryCount, 3);
      expect(other.hasVectors, isFalse);
      expect(other.lastError, contains('另一向量模型'));

      final outcome = await other.search('视频');
      expect(outcome.semantic, isFalse);
      expect(outcome.hits.single.entry.id, 'video:beta');
    });
  });

  group('工具函数', () {
    test('cosineSimilarity 边界', () {
      expect(cosineSimilarity([1, 0], [1, 0]), closeTo(1, 1e-9));
      expect(cosineSimilarity([1, 0], [0, 1]), 0);
      expect(cosineSimilarity([1, 0], [-1, 0]), closeTo(-1, 1e-9));
      expect(cosineSimilarity([1, 0], [1, 0, 0]), 0, reason: '长度不一致按 0');
      expect(cosineSimilarity([0, 0], [1, 0]), 0, reason: '零向量按 0');
    });

    test('substringMatch 大小写/空值/空查询', () {
      expect(substringMatch('video', ['Video Beta']), isTrue);
      expect(substringMatch('BETA', ['video beta']), isTrue);
      expect(substringMatch('x', [null, 'abc']), isFalse);
      expect(substringMatch('  ', ['abc']), isFalse);
      expect(substringMatch('热', ['热应用甲', null]), isTrue);
    });

    test('contentHash 只随 kind/title/text 变化', () {
      const a = EmbeddingDoc(id: 'a', kind: 'hotapp', title: 't', text: 'x', ref: 'r1');
      const b = EmbeddingDoc(id: 'a', kind: 'hotapp', title: 't', text: 'x', ref: 'r2');
      const c = EmbeddingDoc(id: 'a', kind: 'hotapp', title: 't', text: 'y', ref: 'r1');
      expect(a.contentHash, b.contentHash);
      expect(a.contentHash, isNot(c.contentHash));
      expect(a.contentHash.length, 64);
    });
  });

  group('MediaPipeServiceEmbedder 桥接', () {
    test('模型缺失时把 unavailable 转成异常（索引据此降级）', () async {
      final tempRoot = await Directory.systemTemp.createTemp('embed_bridge_test');
      addTearDown(() => tempRoot.delete(recursive: true));
      final service = MediaPipeService(rootOverride: tempRoot);
      final bridge = MediaPipeServiceEmbedder(service);
      await expectLater(
        bridge.embed(['x']),
        throwsA(isA<MediaPipeEmbedderException>()
            .having((e) => e.code, 'code', MediaPipeStatus.modelMissing.name)),
      );
    });
  });
}
