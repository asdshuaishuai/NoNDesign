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
import 'video3d_compile.dart';
import 'video3d_contract.dart';

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
}
