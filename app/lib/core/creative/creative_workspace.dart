/// 创作工作区的轮次协议与路径工具。
///
/// R0 只冻结协议（轮次标签、目录、round manifest 字段），不实现存储；R1 的
/// `CreativeWorkspaceStore` 按它落盘。轮次版本化默认策略见
/// `docs/creative-refactor-decisions.md`：git-first（项目目录是 git 仓库时用
/// tag/commit）+ `judge/rNN/src` 快照回退。
library;

import 'creative_schema.dart';

/// 一轮的路径视图（judge/rNN/ 下的证据文件）。
final class CreativeRoundPaths {
  const CreativeRoundPaths(this.round);

  final CreativeRoundId round;

  String get label => round.label;
  String get dir => CreativeWorkspaceLayout.roundDir(label);
  String get brief => CreativeWorkspaceLayout.roundBrief(label);
  String get judgment => CreativeWorkspaceLayout.roundJudgment(label);
  String get score => CreativeWorkspaceLayout.roundScore(label);
}

/// 轮次清单：记录这一轮的源码锚点与产物时间，保证「最佳轮可回退、可复验」。
///
/// 存在 `<项目>/judge/rNN/round.json`。`srcHash`（sha256，64 位小写 hex）在
/// 没有 git 仓库时作为快照锚点；有 git 时 `gitTag`/`gitCommit` 优先。
final class CreativeRoundManifest {
  const CreativeRoundManifest({
    required this.round,
    this.gitTag,
    this.gitCommit,
    this.srcHash,
    this.createdAt,
    this.extra = const <String, Object?>{},
  });

  static const Set<String> knownKeys = <String>{
    'round',
    'gitTag',
    'gitCommit',
    'srcHash',
    'createdAt',
  };

  final CreativeRoundId round;
  final String? gitTag;
  final String? gitCommit;

  /// sha256 hex（小写 64 位）。
  final String? srcHash;

  /// ISO-8601（UTC）时间戳。
  final DateTime? createdAt;
  final Map<String, Object?> extra;

  static CreativeParseResult<CreativeRoundManifest> parse(Object? raw) {
    final CreativeValidation validation = CreativeValidation();
    final Map<String, Object?>? map = creativeJsonMap(raw);
    if (map == null) {
      validation.add('', 'round_manifest_not_object', 'round.json 必须是 JSON 对象');
      return CreativeParseResult<CreativeRoundManifest>(null, validation);
    }
    final CreativeRoundId? round = CreativeRoundId.parse(map['round']);
    if (round == null) {
      validation.add(
        '/round',
        'round_manifest_round_invalid',
        'round 必须是 rNN 标签（至少两位数字）',
      );
    }
    String? gitTag;
    if (map['gitTag'] != null) {
      gitTag = creativeNonEmptyString(map['gitTag']);
      if (gitTag == null) {
        validation.add(
          '/gitTag',
          'round_manifest_tag_invalid',
          'gitTag 必须是非空字符串',
        );
      }
    }
    String? gitCommit;
    if (map['gitCommit'] != null) {
      gitCommit = creativeNonEmptyString(map['gitCommit']);
      if (gitCommit == null) {
        validation.add(
          '/gitCommit',
          'round_manifest_commit_invalid',
          'gitCommit 必须是非空字符串',
        );
      }
    }
    String? srcHash;
    if (map['srcHash'] != null) {
      srcHash = creativeNonEmptyString(map['srcHash']);
      if (srcHash == null || !_isSha256Hex(srcHash)) {
        validation.add(
          '/srcHash',
          'round_manifest_hash_invalid',
          'srcHash 必须是 64 位小写 sha256',
        );
        srcHash = null;
      }
    }
    DateTime? createdAt;
    if (map['createdAt'] != null) {
      final String? rawCreated = creativeNonEmptyString(map['createdAt']);
      createdAt = rawCreated == null ? null : DateTime.tryParse(rawCreated);
      if (createdAt == null) {
        validation.add(
          '/createdAt',
          'round_manifest_created_invalid',
          'createdAt 必须是 ISO-8601 时间',
        );
      }
    }
    if (round == null) {
      return CreativeParseResult<CreativeRoundManifest>(null, validation);
    }
    return CreativeParseResult<CreativeRoundManifest>(
      CreativeRoundManifest(
        round: round,
        gitTag: gitTag,
        gitCommit: gitCommit,
        srcHash: srcHash,
        createdAt: createdAt,
        extra: _collectExtras(map),
      ),
      validation,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'round': round.label,
    if (gitTag != null) 'gitTag': gitTag,
    if (gitCommit != null) 'gitCommit': gitCommit,
    if (srcHash != null) 'srcHash': srcHash,
    if (createdAt != null) 'createdAt': createdAt!.toUtc().toIso8601String(),
    ...extra,
  };
}

final RegExp _sha256Hex = RegExp(r'^[0-9a-f]{64}$');

bool _isSha256Hex(String value) => _sha256Hex.hasMatch(value);

Map<String, Object?> _collectExtras(Map<String, Object?> map) {
  final Map<String, Object?> extra = <String, Object?>{};
  for (final MapEntry<String, Object?> entry in map.entries) {
    if (CreativeRoundManifest.knownKeys.contains(entry.key)) continue;
    extra[entry.key] = entry.value;
  }
  return extra;
}
