/// 3D 视频项目存储：`<项目根>/portfolio/video3d/<name>/scene3d.json` +
/// `screenplay3d.json`。
///
/// 契约见 `docs/design/video3d-contract.md` §1/§4 与
/// `docs/design/video3d-execution.md` §1：
///  * 两份 JSON 是 3D 视频项目的**唯一事实源**；预览页/帧/证据都是派生；
///  * `save` 先跑 [verifyVideo3d]，未通过**不落盘**——磁盘上不出现半成品项目，
///    旧项目文件保持原样（不静默删除/覆盖）；
///  * 落盘姿势与本仓库其它项目存储同族：同目录临时文件 + flush + 原子改名；
///    只替换两份事实源，**不动项目目录里其它文件**（`artifacts/` 等派生内容）；
///  * `list` 只读元数据，坏项目标 `corrupt` 而不是让一行坏数据拖垮整张表；
///  * 项目名走 ASCII 白名单（与 3D/视频存储纪律一致），路径逃逸（含符号链接）
///    一律拒绝；
///  * `save` 返回 [Video3dVerification]，序列化即 `{verified, checks}`（与契约层
///    的 `verifyVideo3d` 同一形状），失败时调用方拿到全部问题而不是异常。
///
/// 本层纯 Dart（无 Flutter / 无引擎 / 无 WebView）：预览页组装在
/// `video3d_player.dart`，UI 接线是后续批次。
library;

import 'dart:convert';
import 'dart:io';

import '../app_paths.dart';
import '../creative/creative_schema.dart';
import '../workbench_pack.dart';
import '../workbench_pack_io.dart';
import 'video3d_compile.dart';
import 'video3d_contract.dart';
import 'video3d_evidence.dart';

/// 帧证据清单的 schema 标识（确定性字节；不含时间戳）。
const String video3dRendersSchema = 'nan.video3d.renders/1';

/// 清单里的一帧。
final class Video3dRenderEntry {
  const Video3dRenderEntry({
    required this.frame,
    required this.file,
    required this.bytes,
  });

  /// 整数帧号（0 基）。
  final int frame;

  /// 相对 `artifacts/renders/` 的文件名（由帧号派生，不接受外部路径）。
  final String file;

  /// PNG 字节数。
  final int bytes;

  Map<String, Object?> toJson() => <String, Object?>{
    'frame': frame,
    'file': file,
    'bytes': bytes,
  };
}

/// 一次取证的清单（`artifacts/renders/renders.json`）。
final class Video3dRendersManifest {
  const Video3dRendersManifest({
    required this.renderer,
    required this.frames,
    required this.totalBytes,
  });

  /// 产出这批帧的渲染器（页面如实回传；一批只允许一个渲染器）。
  final String renderer;
  final List<Video3dRenderEntry> frames;
  final int totalBytes;

  int get count => frames.length;

  Map<String, Object?> toJson() => <String, Object?>{
    'schema': video3dRendersSchema,
    'renderer': renderer,
    'count': frames.length,
    'frames': <Object?>[
      for (final Video3dRenderEntry entry in frames) entry.toJson(),
    ],
    'total_bytes': totalBytes,
  };
}

/// 项目名不可用 / 项目不存在 / 磁盘内容损坏时的统一异常。
///
/// [code] 是稳定机器码（测试、日志、后续智能体工具信封使用）；[detail] 是原始
/// 诊断，只进折叠的「技术详情」。用户可见文案经
/// [video3dProjectFailureMessage] 映射，不直接上屏。
final class Video3dProjectFailure implements Exception {
  const Video3dProjectFailure(this.code, [this.detail = '']);

  /// 稳定机器码：`invalid_name` / `path_escape` / `no_project` / `corrupt` /
  /// `invalid_input` / `io_error`。
  final String code;

  /// 原始诊断（只进折叠的技术详情）。
  final String detail;

  /// 日志/折叠详情用的一行。
  String get technical => detail.isEmpty ? code : '$code: $detail';

  /// 用户可见的一句话（按错误码映射，不含裸代号）。
  String get message => video3dProjectFailureMessage(this);

  @override
  String toString() => 'Video3dProjectFailure($technical)';
}

/// 内部代号 → 用户可见句子（措辞纪律见 `docs/copy-glossary.md`：
/// 只回答「发生了什么 + 下一步」，不出现实现名/错误码/文件格式名）。
String video3dProjectFailureMessage(Object? error) {
  final String code = error is Video3dProjectFailure
      ? error.code
      : error is String
      ? error
      : '';
  return switch (code) {
    'invalid_name' => '项目名只能用字母、数字、下划线和短横线，换一个名字再试',
    'path_escape' => '这个项目路径不安全，已经拒绝访问',
    'no_project' => '这个 3D 视频项目已经不在了，可能已经被删除',
    'corrupt' => '这个 3D 视频项目的场景或镜头文件不完整，可能被手动改坏了',
    'invalid_input' => '场景数据里有无法保存的内容，检查字段是否都是文本、数字或布尔',
    'io_error' => '项目文件没能写入或读取，请重试',
    _ => '3D 视频项目操作没有完成，请重试',
  };
}

/// 项目列表里的一行（只读元数据；坏项目不拖垮整张表）。
final class Video3dProjectEntry {
  const Video3dProjectEntry({
    required this.name,
    this.nodes = 0,
    this.shots = 0,
    this.durationSeconds = 0,
    this.totalFrames = 0,
    this.verified = false,
    this.corrupt = false,
  });

  /// 目录名（也是项目名，ASCII 白名单）。
  final String name;

  /// 场景节点数。
  final int nodes;

  /// 镜头数。
  final int shots;

  /// 片长（秒）。
  final double durationSeconds;

  /// 整数总帧数（`floor(片长 × fps)`；坏项目为 0）。
  final int totalFrames;

  /// 两份事实源都通过契约校验。
  final bool verified;

  /// 元数据读不出来（文件缺失/不是 JSON 对象）；坏项目也留在表里。
  final bool corrupt;

  /// 列表/工具信封用的稳定 JSON（字段名与顺序固定）。
  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'nodes': nodes,
    'shots': shots,
    'duration_seconds': durationSeconds,
    'total_frames': totalFrames,
    'verified': verified,
    'corrupt': corrupt,
  };
}

/// 一份已读取的项目（[verification] 可能是 `verified=false`，不阻断读取）。
final class Video3dProjectSnapshot {
  const Video3dProjectSnapshot({
    required this.name,
    required this.dir,
    required this.sceneRaw,
    required this.screenplayRaw,
    required this.verification,
  });

  /// 项目名（目录名）。
  final String name;

  /// 项目目录绝对路径（「在文件夹中显示」/复制路径用）。
  final String dir;

  /// 已解码的 `scene3d.json`（保留原始字段，未知字段不丢）。
  final Map<String, Object?> sceneRaw;

  /// 已解码的 `screenplay3d.json`。
  final Map<String, Object?> screenplayRaw;

  /// 联合校验结果：`{verified, checks}`；失败时 `scene`/`screenplay` 为 null。
  final Video3dVerification verification;

  bool get verified => verification.verified;

  /// 校验通过时的已解析场景；场景文档不合格时为 null（镜头表可能仍可读）。
  Video3dScene? get scene => verification.scene;

  /// 校验通过时的已解析镜头表；镜头文档不合格时为 null。
  Video3dScreenplay? get screenplay => verification.screenplay;
}

/// 本地 3D 视频项目库（纯 Dart，无端口、无外部进程）。
///
/// 生产用 [instance]；测试注入 [root]（指向临时的 `portfolio/video3d` 根目录，
/// 不碰真实用户目录）。
class Video3dProjectStore {
  /// [root] 显式给定时不碰平台目录（测试/嵌入式宿主）。
  Video3dProjectStore({Directory? root}) : _rootOverride = root;

  /// 生产单例（工作台/智能体工具/预览页组装共用）。
  static final Video3dProjectStore instance = Video3dProjectStore();

  final Directory? _rootOverride;

  /// 场景事实源文件名（契约 §1）。
  static const String sceneFile = 'scene3d.json';

  /// 镜头/时间事实源文件名（契约 §1）。
  static const String screenplayFile = 'screenplay3d.json';

  /// 派生内容目录（帧证据等）；**agent 只读**，事实源是两份 JSON。
  static const String artifactsDir = 'artifacts';

  /// 帧证据目录（相对项目根）。
  static const String rendersDir = 'artifacts/renders';

  /// 帧证据清单（相对项目根；确定性字节，不含时间戳）。
  static const String rendersManifestFile = 'artifacts/renders/renders.json';

  /// 解析 3D 视频项目根目录（`<用户项目根>/portfolio/video3d`），必要时创建。
  ///
  /// 显式注入 [root] 时直接用它（不存在则创建），测试因此无需平台目录。
  Future<Directory> resolveRoot() async {
    final Directory? override = _rootOverride;
    if (override != null) {
      if (!override.existsSync()) override.createSync(recursive: true);
      return override;
    }
    return AppPaths.projectsSubdir('portfolio/video3d');
  }

  /// 校验项目名并解析项目目录；名称白名单之外的输入、以及可能把读写带到
  /// 项目根之外的符号链接一律显性失败（不猜、不静默兜底）。
  Directory _projectDir(Directory base, String name) {
    if (!creativeIsSafeProjectName(name)) {
      throw Video3dProjectFailure('invalid_name', name);
    }
    final Directory dir = Directory('${base.path}/$name');
    final FileSystemEntityType type = FileSystemEntity.typeSync(
      dir.path,
      followLinks: false,
    );
    if (type == FileSystemEntityType.link) {
      // 符号链接项目会让读写离开 `<根>/portfolio/video3d`，属于路径逃逸。
      throw Video3dProjectFailure('path_escape', name);
    }
    return dir;
  }

  static String _leafName(String path) => path.split(RegExp(r'[/\\]')).last;

  /// 全部项目，按目录名排序；坏项目标 `corrupt` 而不是整表报错。
  ///
  /// 隐藏目录（`.` 开头，比如写到一半的暂存目录）、不合白名单的目录与符号链接
  /// 不是项目，直接跳过。
  Future<List<Video3dProjectEntry>> list() async {
    final Directory base = await resolveRoot();
    if (!base.existsSync()) return const <Video3dProjectEntry>[];
    List<FileSystemEntity> entities;
    try {
      entities = base.listSync(followLinks: false);
    } catch (_) {
      // 目录存在但列不出来（权限/盘符问题）：空表由工作面给可行动文案。
      return const <Video3dProjectEntry>[];
    }
    final List<Video3dProjectEntry> entries = <Video3dProjectEntry>[];
    for (final FileSystemEntity entity in entities) {
      if (entity is! Directory) continue;
      final String name = _leafName(entity.path);
      if (name.startsWith('.') || !creativeIsSafeProjectName(name)) continue;
      entries.add(_readEntry(entity, name));
    }
    entries.sort(
      (Video3dProjectEntry a, Video3dProjectEntry b) =>
          a.name.compareTo(b.name),
    );
    return entries;
  }

  /// 只读元数据；任何读不出来的情况都降级成 `corrupt` 行（不抛）。
  Video3dProjectEntry _readEntry(Directory dir, String name) {
    final Map<String, Object?>? sceneRaw = _decodeObject(
      File('${dir.path}/$sceneFile'),
    );
    final Map<String, Object?>? screenplayRaw = _decodeObject(
      File('${dir.path}/$screenplayFile'),
    );
    if (sceneRaw == null || screenplayRaw == null) {
      return Video3dProjectEntry(name: name, corrupt: true);
    }
    try {
      final Video3dVerification verification = verifyVideo3d(
        sceneRaw,
        screenplayRaw,
      );
      final Video3dScreenplay? screenplay = verification.screenplay;
      int totalFrames = 0;
      if (screenplay != null) {
        // 已通过契约校验时一定可编译；仍防御性兜底：坏数据只降级这一行。
        try {
          totalFrames = compileVideo3dTimeline(screenplay).totalFrames;
        } catch (_) {
          totalFrames = 0;
        }
      }
      return Video3dProjectEntry(
        name: name,
        nodes: verification.scene?.nodes.length ?? 0,
        shots: screenplay?.shots.length ?? 0,
        durationSeconds: screenplay?.durationSeconds ?? 0,
        totalFrames: totalFrames,
        verified: verification.verified,
      );
    } catch (_) {
      return Video3dProjectEntry(name: name, corrupt: true);
    }
  }

  /// 读一个项目并重新校验（磁盘可能被手改）。
  ///
  /// 文件缺失/不是 JSON 对象 → `corrupt`；两份都是 JSON 对象但契约不合格 →
  /// **照常返回快照**，由 `verification.verified == false` 如实上报（契约 §2：
  /// 校验失败不炸项目，但不得编译进预览）。
  Future<Video3dProjectSnapshot> read(String name) async {
    final Directory base = await resolveRoot();
    final Directory dir = _projectDir(base, name);
    if (!dir.existsSync()) throw Video3dProjectFailure('no_project', name);
    final Map<String, Object?>? sceneRaw = _decodeObject(
      File('${dir.path}/$sceneFile'),
    );
    final Map<String, Object?>? screenplayRaw = _decodeObject(
      File('${dir.path}/$screenplayFile'),
    );
    if (sceneRaw == null || screenplayRaw == null) {
      throw Video3dProjectFailure(
        'corrupt',
        '${dir.path} 缺少可读的 $sceneFile / $screenplayFile',
      );
    }
    return Video3dProjectSnapshot(
      name: name,
      dir: dir.path,
      sceneRaw: sceneRaw,
      screenplayRaw: screenplayRaw,
      verification: verifyVideo3d(sceneRaw, screenplayRaw),
    );
  }

  /// 保存项目：**先校验后落盘**，未通过不碰磁盘，返回 `{verified, checks}`。
  ///
  /// * 两份输入先一起过 [verifyVideo3d]；任何问题都在返回值里，磁盘保持原样
  ///   （新项目连目录都不会创建，已有项目的旧事实源不被覆盖）；
  /// * 通过后先写两份同目录临时文件（flush），再逐个原子改名替换事实源；
  ///   只替换 `scene3d.json` / `screenplay3d.json`，不删 `artifacts/` 等其它文件；
  /// * 同输入重复保存得到同样内容的 JSON（两空格缩进 + 末尾换行）。
  Future<Video3dVerification> save(
    String name, {
    required Object? scene,
    required Object? screenplay,
  }) async {
    final Directory base = await resolveRoot();
    final Directory dir = _projectDir(base, name);
    final Video3dVerification verification = verifyVideo3d(scene, screenplay);
    if (!verification.verified) return verification;

    final Map<String, Object?>? sceneRaw = creativeJsonMap(scene);
    final Map<String, Object?>? screenplayRaw = creativeJsonMap(screenplay);
    if (sceneRaw == null || screenplayRaw == null) {
      // verified 为 true 时契约层已保证根是对象；这里只做防御。
      throw const Video3dProjectFailure('invalid_input', '根不是 JSON 对象');
    }

    // 序列化先于任何磁盘动作：不可序列化的输入同样不能落半成品。
    final String sceneText;
    final String screenplayText;
    try {
      sceneText = _prettyJson(sceneRaw);
      screenplayText = _prettyJson(screenplayRaw);
    } catch (error) {
      throw Video3dProjectFailure('invalid_input', '$error');
    }

    try {
      dir.createSync(recursive: true);
      _writePair(
        dir: dir,
        sceneText: sceneText,
        screenplayText: screenplayText,
      );
    } on FileSystemException catch (error) {
      throw Video3dProjectFailure('io_error', '$error');
    }
    return verification;
  }

  /// 删除项目目录（工作台「删除」入口；名称校验在 [_projectDir] 里）。
  Future<void> delete(String name) async {
    final Directory base = await resolveRoot();
    final Directory dir = _projectDir(base, name);
    if (!dir.existsSync()) throw Video3dProjectFailure('no_project', name);
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException catch (error) {
      throw Video3dProjectFailure('io_error', '$error');
    }
  }

  // ------------------------------------------------------------------ 帧证据

  /// 写入一次帧证据（PNG 逐帧 + 确定性清单）。
  ///
  /// 纪律：
  ///  * **路径只由帧号派生**（`artifacts/renders/frame-NNNN.png`），不接受任何
  ///    外部路径，因此没有路径穿越面；
  ///  * 每个文件先写临时 + flush，再原子改名；清单同样；
  ///  * 帧号去重后**升序**，清单字节确定（无时间戳/随机数），可复验可 diff；
  ///  * 帧数/单帧/总量超限或渲染器混用 → 抛 [Video3dEvidenceError]（不静默截断）；
  ///  * 项目不存在 → [Video3dProjectFailure]（`no_project`）；
  ///  * 只动 `artifacts/`，两份事实源与其它文件保持原样。
  Future<Video3dRendersManifest> writeRenders(
    String name,
    List<Video3dFrameEvidence> frames,
  ) async {
    if (frames.isEmpty) {
      throw const Video3dEvidenceError(
        video3dEvidenceEmptyCode,
        '没有可写入的帧证据',
      );
    }
    final Directory base = await resolveRoot();
    final Directory dir = _projectDir(base, name);
    if (!dir.existsSync()) throw Video3dProjectFailure('no_project', name);

    final Map<int, Video3dFrameEvidence> unique = <int, Video3dFrameEvidence>{};
    for (final Video3dFrameEvidence evidence in frames) {
      if (unique.containsKey(evidence.frame)) {
        throw Video3dEvidenceError(
          video3dEvidenceFormatCode,
          '同一帧出现了两次',
          'frame=${evidence.frame}',
        );
      }
      unique[evidence.frame] = evidence;
    }
    final List<Video3dFrameEvidence> ordered = unique.values.toList()
      ..sort(
        (Video3dFrameEvidence a, Video3dFrameEvidence b) =>
            a.frame.compareTo(b.frame),
      );
    checkVideo3dEvidenceBudget(ordered);

    final String renderer = ordered.first.renderer;
    for (final Video3dFrameEvidence evidence in ordered) {
      if (evidence.renderer != renderer) {
        throw const Video3dEvidenceError(
          video3dEvidenceFormatCode,
          '这一批证据来自不同渲染器，不能混写',
        );
      }
    }

    final Directory renders = Directory('${dir.path}/$rendersDir');
    try {
      if (!renders.existsSync()) renders.createSync(recursive: true);
    } on FileSystemException catch (error) {
      throw Video3dProjectFailure('io_error', '$error');
    }

    final List<Video3dRenderEntry> entries = <Video3dRenderEntry>[];
    int totalBytes = 0;
    for (final Video3dFrameEvidence evidence in ordered) {
      final Video3dRenderEntry entry = Video3dRenderEntry(
        frame: evidence.frame,
        file: 'frame-${evidence.frame.toString().padLeft(4, '0')}.png',
        bytes: evidence.byteLength,
      );
      final File target = File('${renders.path}/${entry.file}');
      try {
        _writeBytesAtomically(target, evidence.bytes);
      } on FileSystemException catch (error) {
        throw Video3dProjectFailure('io_error', '$error');
      }
      entries.add(entry);
      totalBytes += entry.bytes;
    }

    final Video3dRendersManifest manifest = Video3dRendersManifest(
      renderer: renderer,
      frames: entries,
      totalBytes: totalBytes,
    );
    try {
      _writeTextAtomically(
        File('${dir.path}/$rendersManifestFile'),
        _prettyJson(manifest.toJson()),
      );
    } on FileSystemException catch (error) {
      throw Video3dProjectFailure('io_error', '$error');
    }
    return manifest;
  }

  // ------------------------------------------------------------------ 写盘

  /// 两份事实源先各自写临时文件（flush 后才改名），把「已写一半」窗口压到
  /// 两次 rename 之间；每次改名本身原子（Windows 目标在场时先删再改名）。
  void _writePair({
    required Directory dir,
    required String sceneText,
    required String screenplayText,
  }) {
    final String stamp = DateTime.now().microsecondsSinceEpoch.toString();
    final File sceneTmp = File('${dir.path}/.$sceneFile.$stamp.tmp');
    final File screenplayTmp = File('${dir.path}/.$screenplayFile.$stamp.tmp');
    try {
      _writeFlushed(sceneTmp, sceneText);
      _writeFlushed(screenplayTmp, screenplayText);
      _replaceWithTmp(sceneTmp, File('${dir.path}/$sceneFile'));
      _replaceWithTmp(screenplayTmp, File('${dir.path}/$screenplayFile'));
    } finally {
      _deleteQuietlyFile(sceneTmp);
      _deleteQuietlyFile(screenplayTmp);
    }
  }

  /// 临时文件写入并 flush：没 flush 的改名在掉电/崩溃时会变成半截文件。
  void _writeFlushed(File file, String text) {
    final RandomAccessFile handle = file.openSync(mode: FileMode.writeOnly);
    try {
      handle.writeStringSync(text);
      handle.flushSync();
    } finally {
      handle.closeSync();
    }
  }

  /// 字节内容原子写（帧证据用）：临时文件 + flush + 改名。
  void _writeBytesAtomically(File target, List<int> bytes) {
    final String stamp = DateTime.now().microsecondsSinceEpoch.toString();
    final File tmp = File('${target.path}.$stamp.tmp');
    try {
      final RandomAccessFile handle = tmp.openSync(mode: FileMode.writeOnly);
      try {
        handle.writeFromSync(bytes);
        handle.flushSync();
      } finally {
        handle.closeSync();
      }
      _replaceWithTmp(tmp, target);
    } finally {
      _deleteQuietlyFile(tmp);
    }
  }

  /// 文本内容原子写（清单用）；口径与 [_writeBytesAtomically] 一致。
  void _writeTextAtomically(File target, String text) {
    final String stamp = DateTime.now().microsecondsSinceEpoch.toString();
    final File tmp = File('${target.path}.$stamp.tmp');
    try {
      _writeFlushed(tmp, text);
      _replaceWithTmp(tmp, target);
    } finally {
      _deleteQuietlyFile(tmp);
    }
  }

  /// 原子替换：先 rename；Windows 目标在场时 rename 可能失败，先删目标再改名。
  void _replaceWithTmp(File tmp, File target) {
    try {
      tmp.renameSync(target.path);
    } on FileSystemException {
      if (target.existsSync()) target.deleteSync();
      tmp.renameSync(target.path);
    }
  }

  /// 稳定 JSON：两空格缩进 + 末尾换行（手改 diff 可读、字节可复现）。
  String _prettyJson(Object? value) {
    return '${const JsonEncoder.withIndent('  ').convert(value)}\n';
  }

  /// 清掉残留临时文件；清理失败不能盖掉原始错误。
  void _deleteQuietlyFile(File file) {
    try {
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
  }

  /// 读 JSON 对象；文件缺失、读失败、语法错误、根不是对象一律返回 null
  /// （列表把它标成 `corrupt`，read 抛 `corrupt`）。
  Map<String, Object?>? _decodeObject(File file) {
    if (!file.existsSync()) return null;
    try {
      return creativeJsonMap(jsonDecode(file.readAsStringSync()));
    } catch (_) {
      return null;
    }
  }

  // --------------------------------------------------------------- 单一容器

  /// 把项目打包成单一容器，原子写到项目根目录：`<根>/<name>.n3v`。
  ///
  /// 打包内容 = 两份事实源 `scene3d.json` / `screenplay3d.json` 及其它 UTF-8
  /// 文本文件（`docs.md` / `brief.md` 有正文时同时进容器的 `docs` 字段）；
  /// `spec` 字段带两份事实源的解码视图 `{scene, screenplay}`。读不出来（corrupt）
  /// 不导出；容器或文件系统失败抛 [WorkbenchPackFailure]（code / message
  /// 原样保留，不吞）。
  Future<File> exportPack(String name) async {
    final Video3dProjectSnapshot snapshot = await read(name);
    final Directory dir = Directory(snapshot.dir);
    final Object? sceneTitle = snapshot.sceneRaw['title'];
    return exportProjectPack(
      kind: WorkbenchPackKind.video3d.wire,
      projectDir: dir,
      name: name,
      title: sceneTitle is String ? sceneTitle : name,
      docs: readProjectDocs(dir),
      spec: <String, Object?>{
        'scene': snapshot.sceneRaw,
        'screenplay': snapshot.screenplayRaw,
      },
    );
  }

  /// 从单一容器导入项目；包内 `name` 决定目标目录 `<根>/<name>`。
  ///
  /// **目标已存在时拒绝**（抛 [WorkbenchPackFailure] `pack_target_exists`），
  /// 不覆盖、不合并既有项目——重名项目换一个名字再导入。坏容器 / 版本不支持 /
  /// 错 kind 同样显性失败（`WorkbenchPackFailure`）；包内 name 不合本项目名
  /// 白名单时抛 [Video3dProjectFailure] `invalid_name`（符号链接目标按
  /// `path_escape` 拒绝）。任何失败都不留半成品，项目根保持原样。
  Future<void> importPack(File file) async {
    final WorkbenchPack pack = await WorkbenchPack.readFrom(file);
    requirePackKind(pack, WorkbenchPackKind.video3d.wire);
    final Directory base = await resolveRoot();
    final Directory target = _projectDir(base, pack.name);
    await importProjectPack(
      file,
      projectDir: target,
      expectKind: WorkbenchPackKind.video3d.wire,
    );
  }

  /// 项目根下所有 `.n3v` 打包文件（按文件名排序）。
  ///
  /// 隐藏 / 临时文件与包内 name 不合本项目名白名单的包不列（列出来的包
  /// 一定能用 [importPack] 导入）。不影响 [list]：它只认项目目录。
  Future<List<File>> listPacks() async {
    final Directory base = await resolveRoot();
    return listProjectPacks(
      base,
      kind: WorkbenchPackKind.video3d.wire,
      accept: creativeIsSafeProjectName,
    );
  }
}
