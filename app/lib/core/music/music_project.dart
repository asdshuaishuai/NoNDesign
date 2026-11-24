/// 音乐项目存储：`<项目根>/portfolio/music/<name>/score.json`。
///
/// 契约见 `docs/music-contract.md` §6：与 3D 同模式的目录扫描；score.json 是
/// 唯一事实源；校验失败不阻断入库（读时如实带 verified/checks）。
library;

import 'dart:convert';
import 'dart:io';

import '../app_paths.dart';
import 'music_compile.dart';
import 'music_score.dart';

final class MusicProjectFailure implements Exception {
  const MusicProjectFailure(this.code, [this.detail = '']);

  final String code;
  final String detail;

  @override
  String toString() =>
      'MusicProjectFailure($code${detail.isEmpty ? '' : ': $detail'})';
}

String musicProjectFailureMessage(Object? error) {
  final String code = error is MusicProjectFailure ? error.code : '';
  return switch (code) {
    'invalid_name' => '音乐项目名只能用字母、数字、下划线和短横线',
    'project_exists' => '已经有同名音乐项目了，换一个名字再试',
    'no_project' => '没有找到这个音乐项目',
    'score_invalid' => '乐谱还没有通过校验：先修好小节/时值/关系再保存',
    'score_unsupported_version' => '这份乐谱版本太新，暂时读不了',
    'io_error' => '乐谱文件没能读写，请稍后再试',
    _ => '音乐项目操作没有完成，请稍后再试',
  };
}

/// 列表行（只读元数据；坏项目标 corrupt 不拖垮整张表）。
final class MusicProjectEntry {
  const MusicProjectEntry({
    required this.name,
    this.title = '',
    this.tracks = 0,
    this.measures = 0,
    this.verified = false,
    this.corrupt = false,
  });

  final String name;
  final String title;
  final int tracks;
  final int measures;
  final bool verified;
  final bool corrupt;

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'title': title,
    'tracks': tracks,
    'measures': measures,
    'verified': verified,
    'corrupt': corrupt,
  };
}

/// 一份已读取的乐谱（validation 可能是 `verified=false`；不阻断读取）。
final class MusicProjectSnapshot {
  const MusicProjectSnapshot({
    required this.name,
    required this.score,
    required this.raw,
    required this.validation,
    required this.playPlan,
    required this.dir,
  });

  final String name;
  final MusicScore score;
  final Map<String, Object?> raw;
  final MusicValidation validation;
  final MusicPlayPlan? playPlan;
  final String dir;
}

/// 本地音乐项目库（纯 Dart，无端口/外部进程）。
class MusicProjectStore {
  MusicProjectStore({Directory? root}) : _rootOverride = root;

  static final MusicProjectStore instance = MusicProjectStore();
  final Directory? _rootOverride;
  static final RegExp _namePattern = RegExp(r'^[A-Za-z0-9_-]{1,64}$');
  static const String scoreFile = 'score.json';

  Future<Directory> resolveRoot() async {
    final override = _rootOverride;
    if (override != null) {
      if (!override.existsSync()) override.createSync(recursive: true);
      return override;
    }
    return AppPaths.projectsSubdir('portfolio/music');
  }

  Directory _projectDir(Directory base, String name) {
    if (name.isEmpty || !_namePattern.hasMatch(name)) {
      throw MusicProjectFailure('invalid_name', name);
    }
    return Directory('${base.path}/$name');
  }

  Future<List<MusicProjectEntry>> list() async {
    final base = await resolveRoot();
    if (!base.existsSync()) return const <MusicProjectEntry>[];
    final List<MusicProjectEntry> entries = <MusicProjectEntry>[];
    List<FileSystemEntity> entities;
    try {
      entities = base.listSync(followLinks: false);
    } catch (_) {
      return const <MusicProjectEntry>[];
    }
    for (final entity in entities) {
      if (entity is! Directory) continue;
      final name = entity.uri.pathSegments
          .where((part) => part.isNotEmpty)
          .last;
      if (!_namePattern.hasMatch(name)) continue;
      final file = File('${entity.path}/$scoreFile');
      if (!file.existsSync()) {
        entries.add(MusicProjectEntry(name: name, corrupt: true));
        continue;
      }
      try {
        final decoded = jsonDecode(file.readAsStringSync());
        final parsed = parseMusicScore(decoded);
        final score = parsed.score;
        entries.add(
          MusicProjectEntry(
            name: name,
            title: score?.title ?? name,
            tracks: score?.tracks.length ?? 0,
            measures: score?.measureCount ?? 0,
            verified: !parsed.issues.any((issue) => issue.blocking),
            corrupt: score == null,
          ),
        );
      } catch (_) {
        entries.add(MusicProjectEntry(name: name, corrupt: true));
      }
    }
    entries.sort((a, b) => a.name.compareTo(b.name));
    return entries;
  }

  Future<MusicProjectSnapshot> read(String name) async {
    final base = await resolveRoot();
    final dir = _projectDir(base, name);
    final file = File('${dir.path}/$scoreFile');
    if (!file.existsSync()) throw MusicProjectFailure('no_project', name);
    Object? decoded;
    try {
      decoded = jsonDecode(file.readAsStringSync());
    } catch (error) {
      throw MusicProjectFailure('score_invalid', '$error');
    }
    final parsed = parseMusicScore(decoded);
    final score = parsed.score;
    if (score == null) {
      throw MusicProjectFailure(
        'score_invalid',
        parsed.issues
            .where((issue) => issue.blocking)
            .map((issue) => '${issue.code}: ${issue.message}')
            .join('；'),
      );
    }
    final validation = MusicValidation.from(parsed.issues);
    MusicPlayPlan? plan;
    try {
      plan = compileMusicScore(score);
    } on MusicCompileError {
      plan = null;
    }
    return MusicProjectSnapshot(
      name: name,
      score: score,
      raw: Map<String, Object?>.from(decoded as Map),
      validation: validation,
      playPlan: plan,
      dir: dir.path,
    );
  }

  /// 写入 score.json（原子）；校验失败也允许入库，返回 validation 如实上报。
  Future<MusicValidation> save(String name, MusicScore score) async {
    final base = await resolveRoot();
    final dir = _projectDir(base, name);
    dir.createSync(recursive: true);
    final target = File('${dir.path}/$scoreFile');
    const encoder = JsonEncoder.withIndent('  ');
    final tmp = File(
      '${target.path}.tmp-${DateTime.now().microsecondsSinceEpoch}',
    );
    tmp.writeAsStringSync('${encoder.convert(score.toJson())}\n', flush: true);
    if (target.existsSync()) target.deleteSync();
    tmp.renameSync(target.path);
    return verifyMusicScore(score.toJson());
  }

  Future<void> delete(String name) async {
    final base = await resolveRoot();
    final dir = _projectDir(base, name);
    if (!dir.existsSync()) throw MusicProjectFailure('no_project', name);
    dir.deleteSync(recursive: true);
  }
}
