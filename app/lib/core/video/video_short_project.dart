/// 常规视频「引擎短片」项目存储：`<项目根>/portfolio/video_short/<name>/screenplay.json`。
///
/// 纪律（与 3D 视频项目存储同族，但只有**一份**事实源）：
///  * `screenplay.json` 是唯一事实源；预览页/帧都是派生；
///  * `save` 先跑 [verifyVideoScreenplay]，未通过**不落盘**（磁盘上不出现半成品，
///    旧文件保持原样）；`overwrite` 默认 false（同名拒绝覆盖，要覆盖得显式传）；
///  * 落盘：同目录临时文件 + flush + 原子改名；只写这一份文件；
///  * `list` 只读元数据，坏项目标 `corrupt` 而不是让一行坏数据拖垮整张表；
///  * 项目名走 ASCII 白名单，符号链接 = 路径逃逸，一律拒绝。
///
/// 本层纯 Dart（无 Flutter / 无 WebView）：播放页组装在 `video_short_player.dart`，
/// 预览面与工具接线是后续批次。
library;

import 'dart:convert';
import 'dart:io';

import '../app_paths.dart';
import '../creative/creative_schema.dart';
import 'video_screenplay.dart';

/// 项目名不可用 / 不存在 / 内容损坏时的统一异常。
final class VideoShortProjectFailure implements Exception {
  const VideoShortProjectFailure(this.code, [this.detail = '']);

  /// 稳定机器码：`invalid_name` / `path_escape` / `no_project` / `corrupt` /
  /// `unverified` / `exists` / `io_error`。
  final String code;
  final String detail;

  @override
  String toString() => 'VideoShortProjectFailure($code: $detail)';
}

/// 只读项目元数据（列表用）。
final class VideoShortProjectEntry {
  const VideoShortProjectEntry({
    required this.name,
    required this.shots,
    required this.frames,
    required this.verified,
    required this.corrupt,
    this.width = 0,
    this.height = 0,
  });

  final String name;
  final int shots;
  final int frames;
  final bool verified;
  final bool corrupt;
  final int width;
  final int height;

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'shots': shots,
    'frames': frames,
    'verified': verified,
    if (corrupt) 'corrupt': true,
    'width': width,
    'height': height,
  };
}

/// 读出来的完整项目：原始 JSON + 校验结果。
final class VideoShortProjectSnapshot {
  const VideoShortProjectSnapshot({
    required this.name,
    required this.raw,
    required this.verification,
  });

  final String name;
  final Map<String, Object?> raw;
  final VideoScreenplayVerification verification;

  VideoScreenplay? get screenplay => verification.screenplay;
}

/// 引擎短片项目库。
class VideoShortProjectStore {
  /// [root] 显式给定时不碰平台目录（测试/嵌入式宿主）。
  VideoShortProjectStore({Directory? root}) : _rootOverride = root;

  /// 生产单例（工具/预览/工作台共用）。
  static final VideoShortProjectStore instance = VideoShortProjectStore();

  final Directory? _rootOverride;

  /// 事实源文件名。
  static const String screenplayFile = 'screenplay.json';

  /// 解析项目根目录（`<用户项目根>/portfolio/video_short`），必要时创建。
  Future<Directory> resolveRoot() async {
    final Directory? override = _rootOverride;
    if (override != null) {
      if (!override.existsSync()) override.createSync(recursive: true);
      return override;
    }
    return AppPaths.projectsSubdir('portfolio/video_short');
  }

  Directory _projectDir(Directory base, String name) {
    if (!creativeIsSafeProjectName(name)) {
      throw VideoShortProjectFailure('invalid_name', name);
    }
    final Directory dir = Directory('${base.path}/$name');
    final FileSystemEntityType type = FileSystemEntity.typeSync(
      dir.path,
      followLinks: false,
    );
    if (type == FileSystemEntityType.link) {
      throw VideoShortProjectFailure('path_escape', name);
    }
    return dir;
  }

  static String _leafName(String path) => path.split(RegExp(r'[/\\]')).last;

  /// 全部项目（按名排序）。坏项目标 `corrupt`，不整表报错。
  Future<List<VideoShortProjectEntry>> list() async {
    final Directory base = await resolveRoot();
    if (!base.existsSync()) return const <VideoShortProjectEntry>[];
    List<FileSystemEntity> entities;
    try {
      entities = base.listSync(followLinks: false);
    } catch (_) {
      return const <VideoShortProjectEntry>[];
    }
    final List<VideoShortProjectEntry> entries = <VideoShortProjectEntry>[];
    for (final FileSystemEntity entity in entities) {
      if (entity is! Directory) continue;
      final String name = _leafName(entity.path);
      if (name.startsWith('.') || !creativeIsSafeProjectName(name)) continue;
      entries.add(_readEntry(Directory(entity.path), name));
    }
    entries.sort(
      (VideoShortProjectEntry a, VideoShortProjectEntry b) =>
          a.name.compareTo(b.name),
    );
    return entries;
  }

  VideoShortProjectEntry _readEntry(Directory dir, String name) {
    final Map<String, Object?>? raw = _decodeObject(
      File('${dir.path}/$screenplayFile'),
    );
    if (raw == null) {
      return VideoShortProjectEntry(
        name: name,
        shots: 0,
        frames: 0,
        verified: false,
        corrupt: true,
      );
    }
    final VideoScreenplayVerification verification = verifyVideoScreenplay(raw);
    final VideoScreenplay? screenplay = verification.screenplay;
    return VideoShortProjectEntry(
      name: name,
      shots: screenplay?.shots.length ?? 0,
      frames: screenplay?.totalFrames ?? 0,
      verified: verification.verified,
      corrupt: false,
      width: screenplay?.width ?? 0,
      height: screenplay?.height ?? 0,
    );
  }

  /// 读项目；不存在 = `no_project`，坏 JSON = `corrupt`（都不静默）。
  Future<VideoShortProjectSnapshot> read(String name) async {
    final Directory base = await resolveRoot();
    final Directory dir = _projectDir(base, name);
    if (!dir.existsSync()) throw VideoShortProjectFailure('no_project', name);
    final Map<String, Object?>? raw = _decodeObject(
      File('${dir.path}/$screenplayFile'),
    );
    if (raw == null) throw VideoShortProjectFailure('corrupt', name);
    return VideoShortProjectSnapshot(
      name: name,
      raw: raw,
      verification: verifyVideoScreenplay(raw),
    );
  }

  /// 写项目：先校验，未通过**不落盘**。
  ///
  /// [overwrite] 为 false 时同名已存在直接拒绝（`exists`）；为 true 时原子替换。
  Future<VideoScreenplayVerification> save(
    String name,
    Map<String, Object?> screenplay, {
    bool overwrite = false,
  }) async {
    final VideoScreenplayVerification verification = verifyVideoScreenplay(
      screenplay,
    );
    if (!verification.verified) return verification;

    final Directory base = await resolveRoot();
    final Directory dir = _projectDir(base, name);
    if (dir.existsSync() && !overwrite) {
      throw VideoShortProjectFailure('exists', name);
    }
    try {
      if (!dir.existsSync()) dir.createSync(recursive: true);
      _writeAtomically(
        File('${dir.path}/$screenplayFile'),
        _prettyJson(screenplay),
      );
    } on FileSystemException catch (error) {
      throw VideoShortProjectFailure('io_error', '$error');
    }
    return verification;
  }

  /// 删除项目（递归）；不存在 = `no_project`。
  Future<void> delete(String name) async {
    final Directory base = await resolveRoot();
    final Directory dir = _projectDir(base, name);
    if (!dir.existsSync()) throw VideoShortProjectFailure('no_project', name);
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException catch (error) {
      throw VideoShortProjectFailure('io_error', '$error');
    }
  }

  // ------------------------------------------------------------------ 内部

  /// 原子写：临时文件 + flush + rename（失败重试一次先删目标）。
  void _writeAtomically(File target, String text) {
    final String stamp = DateTime.now().microsecondsSinceEpoch.toString();
    final File tmp = File('${target.path}.$stamp.tmp');
    try {
      final RandomAccessFile handle = tmp.openSync(mode: FileMode.writeOnly);
      try {
        handle.writeStringSync(text);
        handle.flushSync();
      } finally {
        handle.closeSync();
      }
      try {
        tmp.renameSync(target.path);
      } on FileSystemException {
        if (target.existsSync()) target.deleteSync();
        tmp.renameSync(target.path);
      }
    } finally {
      try {
        if (tmp.existsSync()) tmp.deleteSync();
      } catch (_) {}
    }
  }

  /// 稳定 JSON：两空格缩进 + 末尾换行（手改 diff 可读、字节可复现）。
  String _prettyJson(Object? value) =>
      '${const JsonEncoder.withIndent('  ').convert(value)}\n';

  Map<String, Object?>? _decodeObject(File file) {
    if (!file.existsSync()) return null;
    try {
      return creativeJsonMap(jsonDecode(file.readAsStringSync()));
    } catch (_) {
      return null;
    }
  }
}

/// 项目库失败码 → 人话（UI/工具共用；原始诊断只进折叠的技术详情）。
String videoShortProjectFailureMessage(String code) {
  return switch (code) {
    'invalid_name' => '项目名不可用：只能小写字母、数字、短横线或下划线',
    'path_escape' => '这个项目名指向了项目库之外，已拒绝',
    'no_project' => '找不到这个引擎短片项目',
    'corrupt' => '这个引擎短片项目的剧本文件损坏了',
    'unverified' => '剧本没有通过校验',
    'exists' => '同名引擎短片项目已存在，请换一个名字',
    'io_error' => '磁盘读写失败，请稍后重试',
    _ => '引擎短片项目打不开，可以重试',
  };
}
