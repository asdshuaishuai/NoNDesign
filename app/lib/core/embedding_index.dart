// 离线语义检索索引（docs/plan-flutter-3.50-adoption.md N6/M2 首个价值切片）。
//
// 形态：JSON 索引文件（原子写）+ 纯 Dart 余弦 topK；向量来自注入的
// [Embedder]（生产 = MediaPipe Universal Embedder，测试 = fake）。
//
// 三条硬约束：
//   1. **可降级**：空索引 / 未配置 embedder / 维度不一致 / 向量检索抛错，
//      一律退回子串匹配（[SearchOutcome.semantic] == false 并带原因），
//      绝不让检索入口因模型缺失而不可用；
//   2. **增量**：content hash（kind/title/text 的 sha256）未变的条目复用旧
//      向量，只把变化的条目送进 embedder——388 MB 模型不该为改一个标题重算全库；
//   3. **可恢复**：索引文件损坏/格式不认识 → 清空重来（坏文件改名 `.corrupt`
//      留档），不把启动路径炸掉。
//
// 存储位置：`<appDataRoot>/embedding_index/<fileName>`（app_paths 规则：
// 桌面 `~/.nondesign`，移动/无 HOME 走系统临时目录）。
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'app_paths.dart';
import 'mediapipe_embedder.dart';
import 'mediapipe_service.dart';
import 'sha256_digest.dart';

/// 文本向量化接口（生产由 MediaPipe Universal Embedder 实现；测试用 fake）。
abstract interface class Embedder {
  /// [texts] 逐条编码，返回同序向量。
  Future<List<List<double>>> embed(List<String> texts);
}

/// 艺术架/检索入口依赖的最小检索面（生产 = [EmbeddingIndex]；测试注入 fake）。
abstract interface class SearchIndex {
  Future<SearchOutcome> search(String query, {int topK});
}

/// 待索引条目（构建输入；hash 由内容派生）。
final class EmbeddingDoc {
  const EmbeddingDoc({
    required this.id,
    required this.kind,
    required this.title,
    required this.text,
    required this.ref,
  });

  /// 稳定 id（艺术架 = `<kind>:<ref>`）。
  final String id;

  /// hotapp / prototype / video / three / doc
  final String kind;

  final String title;

  /// 参与向量化的正文（标题之外的描述/路径/标签）。
  final String text;

  /// 打开用的引用（应用名 / mp4 路径 / DDP 路径）。
  final String ref;

  /// 内容指纹：kind + title + text（ref 变化不影响语义，不参与）。
  String get contentHash =>
      sha256Hex(utf8.encode('$kind\u0000$title\u0000$text'));
}

/// 索引条目（落盘形态；向量可为 null = 未向量化/已降级）。
final class EmbeddingEntry {
  EmbeddingEntry({
    required this.id,
    required this.kind,
    required this.title,
    required this.text,
    required this.ref,
    required this.hash,
    List<double>? vector,
  }) : vector = vector == null ? null : List<double>.unmodifiable(vector);

  final String id;
  final String kind;
  final String title;
  final String text;
  final String ref;
  final String hash;
  final List<double>? vector;

  bool get hasVector => vector != null && vector!.isNotEmpty;

  EmbeddingEntry withVector(List<double>? next) => EmbeddingEntry(
        id: id,
        kind: kind,
        title: title,
        text: text,
        ref: ref,
        hash: hash,
        vector: next,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'kind': kind,
        'title': title,
        'text': text,
        'ref': ref,
        'hash': hash,
        if (vector != null) 'vector': vector,
      };

  /// 容错解析：坏条目返回 null（跳过该条，不拖垮整份索引）。
  static EmbeddingEntry? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final kind = raw['kind'];
    final title = raw['title'];
    final text = raw['text'];
    final ref = raw['ref'];
    final hash = raw['hash'];
    if (id is! String || id.isEmpty) return null;
    if (kind is! String || title is! String || text is! String || ref is! String) {
      return null;
    }
    if (hash is! String || hash.isEmpty) return null;
    List<double>? vector;
    final rawVector = raw['vector'];
    if (rawVector is List) {
      final values = <double>[];
      var ok = true;
      for (final value in rawVector) {
        if (value is num) {
          values.add(value.toDouble());
        } else {
          ok = false;
          break;
        }
      }
      if (ok && values.isNotEmpty) vector = values;
    }
    return EmbeddingEntry(
      id: id,
      kind: kind,
      title: title,
      text: text,
      ref: ref,
      hash: hash,
      vector: vector,
    );
  }
}

/// 一条检索命中。
final class SearchHit {
  const SearchHit(this.entry, this.score, {required this.semantic});

  final EmbeddingEntry entry;

  /// 余弦相似度（子串降级时为 0）。
  final double score;

  /// true = 向量检索；false = 子串降级。
  final bool semantic;

  @override
  String toString() =>
      'SearchHit(${entry.id}, ${score.toStringAsFixed(3)}, semantic=$semantic)';
}

/// 检索结果（含降级原因——UI 可以据此提示「语义检索不可用，已用关键词」）。
final class SearchOutcome {
  const SearchOutcome({
    required this.hits,
    required this.semantic,
    this.reason,
  });

  static const SearchOutcome empty =
      SearchOutcome(hits: [], semantic: false);

  final List<SearchHit> hits;

  /// 本次是否走向量检索。
  final bool semantic;

  /// 降级原因（semantic=false 且有查询时非空）。
  final String? reason;

  bool get degraded => !semantic && reason != null;

  @override
  String toString() =>
      'SearchOutcome(${hits.length} hits, semantic=$semantic'
      '${reason == null ? '' : ', reason=$reason'})';
}

/// 增量同步结果（轨迹/日志/测试断言用）。
final class EmbeddingSyncResult {
  const EmbeddingSyncResult({
    required this.total,
    required this.reused,
    required this.embedded,
    required this.removed,
    required this.degraded,
    this.error,
  });

  final int total;

  /// hash 未变、复用旧向量的条目数。
  final int reused;

  /// 本次新算向量的条目数。
  final int embedded;

  /// 从索引里移除的条目数。
  final int removed;

  /// 是否有条目没拿到向量（embedder 缺失/失败）。
  final bool degraded;

  final String? error;

  @override
  String toString() => 'EmbeddingSyncResult(total=$total, reused=$reused, '
      'embedded=$embedded, removed=$removed, degraded=$degraded'
      '${error == null ? '' : ', error=$error'})';
}

/// 本地 JSON 向量索引。
final class EmbeddingIndex implements SearchIndex {
  EmbeddingIndex({
    this.embedder,
    this.rootOverride,
    this.fileName = 'embedding_index.json',
    this.modelId = 'embedding_gemma_2_text_vision',
    this.minScore = 0.15,
  });

  /// 索引格式版本；不认识就整份重置（宁可重算，不猜语义）。
  static const int formatVersion = 1;

  /// 向量来源（换模型 → 旧向量作废；与 [MediaPipeModels.universalEmbedder]
  /// 的 id 同源，改模型时一起改）。
  final String modelId;

  /// 生产注入 MediaPipe embedder；null/失败时检索退化为子串。
  final Embedder? embedder;

  /// 余弦命中下限（低于它就是「不相关」，不污染艺术架）。
  final double minScore;

  /// 根目录覆盖（测试用临时目录；默认走 [AppPaths.dataRoot]）。
  final Directory? rootOverride;

  /// 索引文件名（同一目录下可并存多份索引）。
  final String fileName;

  final Map<String, EmbeddingEntry> _entries = {};
  int? _dimension;
  bool _loaded = false;
  int _writeCount = 0;
  String? _lastError;
  String? _lastDegradedReason;

  /// 落盘次数（诊断/测试用：无变化的 sync 不应重写索引文件）。
  int get writeCount => _writeCount;

  /// 索引文件绝对路径。
  String get indexFilePath =>
      '${(rootOverride ?? AppPaths.dataRoot()).path}/embedding_index/$fileName';

  /// 条目数（含未向量化的）。
  int get entryCount => _entries.length;

  /// 索引内向量维度（没有向量时为 null）。
  int? get dimension => _dimension;

  /// 是否有任何可用向量（决定能否走语义检索）。
  bool get hasVectors => _entries.values.any((e) => e.hasVector);

  /// 最近一次加载/同步/检索的错误（人读；正常为 null）。
  String? get lastError => _lastError;

  /// 最近一次检索降级的原因（UI 提示用）。
  String? get lastDegradedReason => _lastDegradedReason;

  /// 当前条目（只读快照；UI 展示/测试断言用）。
  List<EmbeddingEntry> get entries => List.unmodifiable(_entries.values);

  /// 读取索引（幂等；损坏/版本不认 → 重置并留档 `.corrupt`）。
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final file = File(indexFilePath);
    if (!await file.exists()) return;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) {
        throw const FormatException('索引根节点不是对象');
      }
      if (decoded['formatVersion'] != formatVersion) {
        throw FormatException('不认识的 formatVersion: ${decoded['formatVersion']}');
      }
      final entries = decoded['entries'];
      if (entries is! List) {
        throw const FormatException('entries 缺失');
      }
      final parsed = <String, EmbeddingEntry>{};
      for (final raw in entries) {
        final entry = EmbeddingEntry.tryParse(raw);
        if (entry != null) parsed[entry.id] = entry;
      }
      final storedModel = decoded['modelId'];
      final sameModel = storedModel == null || storedModel == modelId;
      final rawDimension = decoded['dimension'];
      var dimension = rawDimension is num ? rawDimension.toInt() : null;
      if (!sameModel) {
        // 换过向量模型：标题/正文还有用（子串降级），向量一律作废。
        for (final id in parsed.keys.toList()) {
          parsed[id] = parsed[id]!.withVector(null);
        }
        dimension = null;
        _lastError = '索引由另一向量模型（$storedModel）构建，向量已作废';
      }
      _entries
        ..clear()
        ..addAll(parsed);
      _dimension = dimension;
    } catch (e) {
      _lastError = '索引文件损坏，已重置：$e';
      _entries.clear();
      _dimension = null;
      try {
        await file.rename('$indexFilePath.corrupt');
      } catch (_) {
        // 改名失败（只读盘/并发占用）也要能继续用——空索引即可。
      }
    }
  }

  /// 增量建/更新索引：hash 未变且向量维度一致的条目直接复用。
  Future<EmbeddingSyncResult> sync(
    List<EmbeddingDoc> docs, {
    void Function(int done, int total)? onProgress,
  }) async {
    await load();
    final old = Map<String, EmbeddingEntry>.of(_entries);
    final next = <String, EmbeddingEntry>{};
    final pending = <EmbeddingDoc>[];
    for (final doc in docs) {
      final hash = doc.contentHash;
      final prior = old[doc.id];
      final reusable = prior != null &&
          prior.hash == hash &&
          prior.hasVector &&
          (_dimension == null || prior.vector!.length == _dimension);
      next[doc.id] = EmbeddingEntry(
        id: doc.id,
        kind: doc.kind,
        title: doc.title,
        text: doc.text,
        ref: doc.ref,
        hash: hash,
        vector: reusable ? prior.vector : null,
      );
      if (!reusable) pending.add(doc);
    }
    final removed = old.keys.where((id) => !next.containsKey(id)).length;
    final reused = docs.length - pending.length;

    // 无变化（无重算、无删除）：不重写索引文件——搜索输入框每键一次 sync，
    // 几百条 × 768 维的 JSON 不该跟着键盘节奏反复落盘。
    if (pending.isEmpty && removed == 0) {
      _lastError = null;
      return EmbeddingSyncResult(
        total: docs.length,
        reused: reused,
        embedded: 0,
        removed: 0,
        degraded: false,
      );
    }

    var embedded = 0;
    var degraded = pending.isNotEmpty;
    String? error;
    final worker = embedder;
    if (pending.isNotEmpty) {
      if (worker == null) {
        error = '未配置 embedder（语义向量不可用）';
      } else {
        try {
          final texts = pending.map(_documentText).toList(growable: false);
          final vectors = await worker.embed(texts);
          final dimension = _validateVectors(vectors, texts.length);
          onProgress?.call(texts.length, texts.length);
          if (_dimension != null && dimension != _dimension) {
            // 模型换了维度：旧向量全部作废，整库重嵌一次（索引仍可用）。
            final allTexts = docs.map(_documentText).toList(growable: false);
            final allVectors = await worker.embed(allTexts);
            final allDimension = _validateVectors(allVectors, allTexts.length);
            if (allDimension != dimension) {
              throw EmbedderDimensionError(
                  '两次嵌入维度不一致：$dimension vs $allDimension');
            }
            for (var i = 0; i < docs.length; i++) {
              next[docs[i].id] = next[docs[i].id]!.withVector(allVectors[i]);
            }
            _dimension = dimension;
            embedded = docs.length;
          } else {
            for (var i = 0; i < pending.length; i++) {
              next[pending[i].id] = next[pending[i].id]!.withVector(vectors[i]);
            }
            _dimension = dimension;
            embedded = pending.length;
          }
          degraded = false;
        } catch (e) {
          error = '向量化失败：$e';
          degraded = true;
        }
      }
    }

    _entries
      ..clear()
      ..addAll(next);
    if (error != null) {
      _lastError = error;
    } else {
      _lastError = null;
    }
    await _write();
    return EmbeddingSyncResult(
      total: docs.length,
      reused: reused,
      embedded: embedded,
      removed: removed,
      degraded: degraded,
      error: error,
    );
  }

  /// 检索：有向量走向量（余弦 topK），否则/失败时退化为子串匹配。
  @override
  Future<SearchOutcome> search(String query, {int topK = 12}) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      _lastDegradedReason = null;
      return SearchOutcome.empty;
    }
    await load();
    final dimension = _dimension;
    final vectorized = dimension == null
        ? const <EmbeddingEntry>[]
        : _entries.values
            .where((e) => e.hasVector && e.vector!.length == dimension)
            .toList(growable: false);
    final worker = embedder;
    if (vectorized.isEmpty || worker == null) {
      final reason = vectorized.isEmpty
          ? '索引里没有可用向量（模型未就绪或尚未建立索引）'
          : '未配置 embedder';
      _lastDegradedReason = reason;
      return SearchOutcome(
        hits: _substringHits(trimmed),
        semantic: false,
        reason: reason,
      );
    }
    try {
      final vectors = await worker.embed([trimmed]);
      if (vectors.isEmpty || vectors.first.isEmpty) {
        throw const EmbedderDimensionError('查询向量为空');
      }
      final queryVector = vectors.first;
      if (queryVector.length != dimension) {
        const reason = '维度不一致，已退化为子串匹配';
        _lastDegradedReason = reason;
        return SearchOutcome(
          hits: _substringHits(trimmed),
          semantic: false,
          reason: reason,
        );
      }
      final hits = <SearchHit>[];
      for (final entry in vectorized) {
        final score = cosineSimilarity(queryVector, entry.vector!);
        if (score.isNaN || score.isInfinite) continue;
        if (score < minScore) continue;
        hits.add(SearchHit(entry, score, semantic: true));
      }
      hits.sort((a, b) => b.score.compareTo(a.score));
      _lastDegradedReason = null;
      return SearchOutcome(
        hits: hits.take(topK).toList(growable: false),
        semantic: true,
      );
    } catch (e) {
      final reason = '向量检索失败，已退化为子串匹配：$e';
      _lastDegradedReason = reason;
      return SearchOutcome(
        hits: _substringHits(trimmed),
        semantic: false,
        reason: reason,
      );
    }
  }

  /// 清空索引（可选删除文件）。
  Future<void> clear({bool deleteFile = true}) async {
    _entries.clear();
    _dimension = null;
    _lastError = null;
    _lastDegradedReason = null;
    _loaded = true;
    if (deleteFile) {
      try {
        final file = File(indexFilePath);
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
  }

  List<SearchHit> _substringHits(String query) {
    final hits = <SearchHit>[];
    for (final entry in _entries.values) {
      if (!substringMatch(query, [entry.title, entry.text, entry.ref, entry.kind])) {
        continue;
      }
      hits.add(SearchHit(entry, 0, semantic: false));
    }
    hits.sort((a, b) {
      final byKind = _kindOrder(a.entry.kind).compareTo(_kindOrder(b.entry.kind));
      if (byKind != 0) return byKind;
      return a.entry.title.compareTo(b.entry.title);
    });
    return hits;
  }

  Future<void> _write() async {
    try {
      final file = File(indexFilePath);
      final dir = file.parent;
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final payload = jsonEncode({
        'formatVersion': formatVersion,
        'modelId': modelId,
        'dimension': _dimension,
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
        'entries': _entries.values.map((e) => e.toJson()).toList(growable: false),
      });
      final temp = File('${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp');
      await temp.writeAsString(payload, flush: true);
      await temp.rename(file.path);
      _writeCount++;
    } catch (e) {
      // 落盘失败不影响本次会话的检索（内存索引仍然有效）。
      _lastError = (e is EmbedderDimensionError) ? e.message : '索引落盘失败：$e';
    }
  }

  static String _documentText(EmbeddingDoc doc) =>
      doc.text.trim().isEmpty ? doc.title : '${doc.title}\n${doc.text}';

  /// 校验 embedder 返回（条数 + 非空 + 同批维度一致），返回维度。
  static int _validateVectors(List<List<double>> vectors, int expectedCount) {
    if (vectors.length != expectedCount) {
      throw EmbedderDimensionError(
          '向量条数不一致：期望 $expectedCount，实际 ${vectors.length}');
    }
    int? dimension;
    for (final vector in vectors) {
      if (vector.isEmpty) {
        throw const EmbedderDimensionError('embedder 返回空向量');
      }
      if (dimension == null) {
        dimension = vector.length;
      } else if (vector.length != dimension) {
        throw EmbedderDimensionError(
            '同批向量维度不一致：$dimension vs ${vector.length}');
      }
    }
    return dimension!;
  }

  static int _kindOrder(String kind) {
    switch (kind) {
      case 'hotapp':
        return 0;
      case 'prototype':
        return 1;
      case 'video':
        return 2;
      case 'three':
        return 3;
      default:
        return 4;
    }
  }
}

/// embedder 返回的维度不一致/条数不对——按降级处理，不写坏索引。
final class EmbedderDimensionError implements Exception {
  const EmbedderDimensionError(this.message);
  final String message;
  @override
  String toString() => 'EmbedderDimensionError: $message';
}

/// 余弦相似度（纯 Dart，无依赖）。长度不一致或零向量返回 0（调用方另行降级）。
double cosineSimilarity(List<double> a, List<double> b) {
  if (a.length != b.length || a.isEmpty) return 0;
  var dot = 0.0;
  var normA = 0.0;
  var normB = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    normA += a[i] * a[i];
    normB += b[i] * b[i];
  }
  if (normA <= 0 || normB <= 0) return 0;
  return dot / (math.sqrt(normA) * math.sqrt(normB));
}

/// 大小写不敏感的子串匹配（任一字段命中即算）。
bool substringMatch(String query, Iterable<String?> fields) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return false;
  for (final field in fields) {
    if (field == null) continue;
    if (field.toLowerCase().contains(needle)) return true;
  }
  return false;
}

/// 生产 Embedder：把 [MediaPipeService.embedTexts] 的结果转成 [Embedder]。
///
/// 模型缺失/平台不支持时 embedTexts 返回 unavailable（不抛），这里转成
/// [MediaPipeEmbedderException]，让 [EmbeddingIndex] 走既定的子串降级路径。
final class MediaPipeServiceEmbedder implements Embedder {
  const MediaPipeServiceEmbedder(this.service);

  final MediaPipeService service;

  @override
  Future<List<List<double>>> embed(List<String> texts) async {
    final result = await service.embedTexts(texts);
    if (!result.ok) {
      throw MediaPipeEmbedderException(
        result.error ?? 'MediaPipe embedder unavailable',
        code: result.status?.name ?? 'unavailable',
      );
    }
    return result.vectors;
  }
}
