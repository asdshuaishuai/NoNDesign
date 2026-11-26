/// 视频工作区的「生成项目」：时间线脚本 + 规范落盘。
///
/// 背景：视频模块是代码动画（用户裁决 2026-11-18），播放面由
/// [VideoDocument] 逐帧现算；但工作台的创作面此前只有内置示例，NaN 在工作区
/// run 里生成的动画**无处落地**（模型只能调 `video_review` 校验一段内存里的
/// 时间线，关掉 run 就没了——用户可见面即「跑完了但工作台里没有东西」）。
/// 本文件补上落地面：一个项目 = `<项目根>/video/<name>/` 下三份文件
///
/// ```
/// <name>/timeline.json   时间线脚本（`spec` 字段指向 spec.json）
/// <name>/spec.json       规范（硬门 1：science / screenplay …）
/// <name>/video.json      元数据（标题 / 片长 / 帧率 / 来源）
/// ```
///
/// 与 [ThreeService] 同一存储纪律：用户项目根（`AppPaths.projectsRoot()`）下
/// 的子目录、名称白名单（ASCII `a-z0-9_-`）、**写成功之后才出现目录**、读损坏
/// 如实报错而不是静默清空。校验一律先跑 [VideoDocument.build]（预编译全量
/// 算式），失败不落盘——磁盘上不出现半成品项目。
///
/// 列表与读取分开：`list()` 只读 `video.json` 元数据（坏项目标 corrupt，
/// 不让一行坏数据拖垮整张表）；`read()` 才重新校验时间线/规范并返回可直接
/// 逐帧播放的 [VideoDocument]。
library;

import 'dart:convert';
import 'dart:io';

import 'app_paths.dart';
import 'video_service.dart';
import 'workbench_pack.dart';
import 'workbench_pack_io.dart';

/// 项目名不可用、写盘失败、内容不合格时的统一异常。
///
/// [code] 是稳定机器码（测试/日志/智能体工具信封使用），[detail] 是原始诊断。
/// 两者都不直接上屏——用户看到的是 [videoProjectFailureMessage] 的一句话，
/// 原始诊断只进折叠的「技术详情」。
class VideoProjectFailure implements Exception {
  const VideoProjectFailure(this.code, [this.detail = '']);

  /// 稳定机器码：`invalid_name` / `project_exists` / `no_project` /
  /// `timeline_invalid` / `spec_missing` / `spec_invalid` / `no_scenes` /
  /// `no_frames` / `io_error`（校验层的 expr_* 代号也原样透传）。
  final String code;

  /// 原始诊断（只进折叠的技术详情）。
  final String detail;

  /// 日志/折叠详情用的一行。
  String get technical => detail.isEmpty ? code : '$code: $detail';

  /// 用户可见的一句话（按错误码映射，不含裸代号）。
  String get message => videoProjectFailureMessage(this);

  @override
  String toString() => 'VideoProjectFailure($technical)';
}

/// 内部代号 → 用户可见句子。
///
/// 措辞纪律（`docs/copy-glossary.md`）：只回答「发生了什么 + 下一步」，
/// 不出现实现名、错误码、工具名或文件格式名。项目码自己映射；校验层代号
/// （算式写坏、未声明符号等）复用 [videoFailureMessage] 的同一套说法。
String videoProjectFailureMessage(Object? error) {
  final code = error is VideoProjectFailure
      ? error.code
      : error is VideoRejected
      ? error.code
      : error is String
      ? error
      : '';
  switch (code) {
    case 'invalid_name':
      return '项目名只能用字母、数字、下划线和短横线，换一个名字再试';
    case 'project_exists':
      return '已经有同名视频项目了，换一个名字再生成';
    case 'no_project':
      return '这个视频项目已经不在了，可能已经被删除';
    case 'corrupt':
      return '视频项目的文件不完整，可能被手动改坏了';
    case 'spec_missing':
      return '这份视频项目缺一份说明规范，暂时看不了画面';
    case 'spec_invalid':
      return '这份视频项目的说明规范不完整，暂时看不了画面';
    case 'timeline_invalid':
      return '视频项目的脚本文件格式不对，可能被手动改坏了';
    case 'no_scenes':
      return '视频项目的脚本里还没有任何场景';
    case 'no_frames':
      return '视频项目的场景时长都是 0，算不出画面';
    case 'io_error':
      return '项目文件没能写入或读取，请重试';
    default:
      return videoFailureMessage(code);
  }
}

/// 项目列表里的一行（只读元数据；不解析时间线，列表不为坏项目陪葬）。
class VideoProjectEntry {
  const VideoProjectEntry({
    required this.name,
    this.title = '',
    this.seconds = 0,
    this.fps = 30,
    this.corrupt = false,
  });

  /// 目录名（也是项目名，ASCII 白名单）。
  final String name;

  /// 用户可见标题（空 = 用 [name] 兜底展示）。
  final String title;

  /// 片长（秒）。
  final double seconds;

  /// 声明帧率。
  final int fps;

  /// 元数据读不出来（坏项目不挡其他行）。
  final bool corrupt;

  /// 列表/工具信封用的稳定 JSON（字段名与顺序固定）。
  Map<String, dynamic> toJson() => <String, dynamic>{
    'name': name,
    'title': title,
    'seconds': seconds,
    'fps': fps,
    'corrupt': corrupt,
  };

  /// [toJson] 的逆操作（智能体工具信封 / 列表快照回读）。
  factory VideoProjectEntry.fromJson(Map<String, dynamic> json) {
    final seconds = json['seconds'];
    final fps = json['fps'];
    return VideoProjectEntry(
      name: (json['name'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      seconds: seconds is num && seconds.isFinite ? seconds.toDouble() : 0,
      fps: fps is num ? fps.toInt() : 30,
      corrupt: json['corrupt'] == true,
    );
  }
}

/// 一个已校验的项目全貌（[document] 已过预编译，可直接逐帧渲染）。
class VideoProjectSnapshot {
  const VideoProjectSnapshot({
    required this.name,
    required this.title,
    required this.timeline,
    required this.spec,
    required this.document,
    required this.dir,
  });

  final String name;
  final String title;
  final Map<String, dynamic> timeline;
  final Map<String, dynamic> spec;

  /// 已编译、可直接铺到 [VideoAnimationSurface] 的文档。
  final VideoDocument document;

  /// 项目目录绝对路径（给「在文件夹中显示」/复制路径用）。
  final String dir;
}

/// 本地视频项目库（纯 Dart，无端口、无外部进程）。
///
/// 生产用 [instance]；测试注入 [root]（直接指到临时的视频根目录，
/// 不碰真实用户目录）。
class VideoProjectStore {
  /// [root] 显式给定时不碰平台目录（测试/嵌入式宿主）。
  VideoProjectStore({Directory? root}) : _rootOverride = root;

  /// 生产单例（工作台/智能体工具共用）。
  static final VideoProjectStore instance = VideoProjectStore();

  final Directory? _rootOverride;

  /// 目录白名单：ASCII 字母/数字/下划线/短横线，1–64 字符。
  ///
  /// 收紧到白名单是为了跨平台路径安全（不出现分隔符/冒号/空串），也让
  /// 项目名能原样当目录名与智能体工具参数。
  static final RegExp _namePattern = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

  static const String _timelineFile = 'timeline.json';
  static const String _specFile = 'spec.json';
  static const String _metaFile = 'video.json';

  /// 解析视频项目根目录（`<用户项目根>/video`），必要时创建。
  ///
  /// 显式注入 [root] 时直接用它（不存在则创建），测试因此无需平台目录。
  Future<Directory> resolveRoot() async {
    final override = _rootOverride;
    if (override != null) {
      if (!override.existsSync()) override.createSync(recursive: true);
      return override;
    }
    return AppPaths.projectsSubdir('video');
  }

  Directory _projectDir(Directory base, String name) {
    if (name.isEmpty || !_namePattern.hasMatch(name)) {
      throw VideoProjectFailure('invalid_name', name);
    }
    return Directory('${base.path}/$name');
  }

  static String _leafName(String path) => path.split(RegExp(r'[/\\]')).last;

  /// 全部项目，按目录名排序；坏项目标 `corrupt` 而不是整表报错。
  ///
  /// 隐藏目录（`.` 开头，比如写到一半的暂存目录）与不合白名单的目录不是
  /// 项目，直接跳过。
  Future<List<VideoProjectEntry>> list() async {
    final base = await resolveRoot();
    if (!base.existsSync()) return const <VideoProjectEntry>[];
    final entries = <VideoProjectEntry>[];
    List<FileSystemEntity> entities;
    try {
      entities = base.listSync(followLinks: false);
    } catch (_) {
      // 目录存在但列不出来（权限/盘符问题）：列表空态由工作面给可行动文案。
      return const <VideoProjectEntry>[];
    }
    for (final entity in entities) {
      if (entity is! Directory) continue;
      final name = _leafName(entity.path);
      if (name.startsWith('.') || !_namePattern.hasMatch(name)) continue;
      entries.add(_readEntry(entity, name));
    }
    entries.sort((a, b) => a.name.compareTo(b.name));
    return entries;
  }

  /// 只读元数据；任何读不出来的情况都降级成 `corrupt` 行（不抛）。
  VideoProjectEntry _readEntry(Directory dir, String name) {
    final meta = File('${dir.path}/$_metaFile');
    if (!meta.existsSync()) {
      return VideoProjectEntry(name: name, title: name, corrupt: true);
    }
    try {
      final decoded = jsonDecode(meta.readAsStringSync());
      if (decoded is! Map) {
        return VideoProjectEntry(name: name, title: name, corrupt: true);
      }
      final map = Map<String, dynamic>.from(decoded);
      final title = (map['title'] ?? '').toString().trim();
      final seconds = map['seconds'];
      final fps = map['fps'];
      return VideoProjectEntry(
        name: name,
        title: title.isEmpty ? name : title,
        seconds: seconds is num && seconds.isFinite && seconds >= 0
            ? seconds.toDouble()
            : 0,
        fps: fps is num && fps > 0 ? fps.toInt() : 30,
      );
    } catch (_) {
      return VideoProjectEntry(name: name, title: name, corrupt: true);
    }
  }

  /// 读一个项目并重新校验（磁盘可能被手改：规范/算式坏了如实报错）。
  Future<VideoProjectSnapshot> read(String name) async {
    final base = await resolveRoot();
    final dir = _projectDir(base, name);
    if (!dir.existsSync()) throw VideoProjectFailure('no_project', name);

    final timeline = _readTimeline(File('${dir.path}/$_timelineFile'));
    final specFile = _resolveSpecFile(dir, timeline);
    final spec = _readSpec(specFile);

    final VideoDocument document;
    try {
      document = VideoDocument.build(
        timeline: timeline,
        spec: spec,
        baseDir: dir,
      );
    } on VideoRejected catch (error) {
      throw VideoProjectFailure(error.code, error.detail);
    } catch (error) {
      throw VideoProjectFailure('timeline_invalid', '$error');
    }

    var title = '';
    final meta = File('${dir.path}/$_metaFile');
    if (meta.existsSync()) {
      try {
        final decoded = jsonDecode(meta.readAsStringSync());
        if (decoded is Map) title = (decoded['title'] ?? '').toString().trim();
      } catch (_) {
        // 元数据坏了不影响播放：标题退到规范标题/项目名。
      }
    }
    if (title.isEmpty) title = document.spec.title;
    if (title.isEmpty) title = name;

    return VideoProjectSnapshot(
      name: name,
      title: title,
      timeline: timeline,
      spec: spec,
      document: document,
      dir: dir.path,
    );
  }

  Map<String, dynamic> _readTimeline(File timelineFile) {
    if (!timelineFile.existsSync()) {
      throw const VideoProjectFailure('no_project', 'timeline.json 不存在');
    }
    try {
      final decoded = jsonDecode(timelineFile.readAsStringSync());
      if (decoded is! Map) throw const FormatException('根节点不是对象');
      return Map<String, dynamic>.from(decoded);
    } on FormatException catch (error) {
      throw VideoProjectFailure('timeline_invalid', '$error');
    } on FileSystemException catch (error) {
      throw VideoProjectFailure('io_error', '$error');
    }
  }

  File _resolveSpecFile(Directory dir, Map<String, dynamic> timeline) {
    final ref = timeline['spec'];
    if (ref is! String || ref.trim().isEmpty) {
      throw const VideoProjectFailure('spec_missing', '时间线缺少 spec 字段（规范先行）');
    }
    final fileName = ref.trim();
    // 只接受同目录下的普通文件名：手改出来的 `../x` 不当规范路径。
    if (fileName.contains('/') || fileName.contains('\\')) {
      throw VideoProjectFailure('spec_invalid', '规范文件名不合法：$fileName');
    }
    final specFile = File('${dir.path}/$fileName');
    if (!specFile.existsSync()) {
      throw VideoProjectFailure('spec_missing', '$fileName 不存在');
    }
    return specFile;
  }

  Map<String, dynamic> _readSpec(File specFile) {
    try {
      final decoded = jsonDecode(specFile.readAsStringSync());
      if (decoded is! Map) throw const FormatException('根节点不是对象');
      return Map<String, dynamic>.from(decoded);
    } on FormatException catch (error) {
      throw VideoProjectFailure('spec_invalid', '$error');
    } on FileSystemException catch (error) {
      throw VideoProjectFailure('io_error', '$error');
    }
  }

  /// 新建项目：**先校验后落盘**，失败不留半成品目录。
  ///
  /// [timeline] 可以带 `spec` 字段（指向文件名）；不要求，落盘时会归一为
  /// `spec.json`。[spec] 缺失/为空按硬门 1 拒绝（`spec_missing`），内容不合
  /// 规范报 `spec_invalid`，脚本结构问题报 `timeline_invalid` / `no_scenes` /
  /// `no_frames`。同名项目拒绝覆盖（与 3D 的 project_exists 同一纪律）。
  ///
  /// 写盘姿势：先写 `.临时目录`，全部成功后再整体 rename 成 `<name>/`——
  /// 中途任何失败都清掉暂存目录，磁盘上不会出现半成品。
  Future<VideoProjectSnapshot> create({
    required String name,
    required Map<String, dynamic> timeline,
    Map<String, dynamic>? spec,
    String title = '',
  }) async {
    final base = await resolveRoot();
    final dir = _projectDir(base, name);
    if (dir.existsSync()) throw VideoProjectFailure('project_exists', name);

    final tl = Map<String, dynamic>.from(timeline);
    // 落盘布局固定：规范文件名归一为 spec.json（不信任调用方随便指向）。
    tl['spec'] = _specFile;
    final normalizedSpec = spec == null || spec.isEmpty
        ? null
        : Map<String, dynamic>.from(spec);

    // 硬门 1/2：全部算式预编译通过才允许碰磁盘。
    final VideoDocument document;
    try {
      document = VideoDocument.build(timeline: tl, spec: normalizedSpec);
    } on VideoRejected catch (error) {
      throw VideoProjectFailure(error.code, error.detail);
    } catch (error) {
      throw VideoProjectFailure('timeline_invalid', '$error');
    }

    final resolvedTitle = title.trim().isEmpty ? name : title.trim();
    final staging = Directory(
      '${base.path}/.$name.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      staging.createSync(recursive: true);
      _writeJson(File('${staging.path}/$_timelineFile'), tl);
      _writeJson(
        File('${staging.path}/$_specFile'),
        normalizedSpec ?? const <String, dynamic>{},
      );
      _writeJson(File('${staging.path}/$_metaFile'), <String, dynamic>{
        'title': resolvedTitle,
        'seconds': document.totalSeconds,
        'fps': document.fps,
        'origin': 'agent',
      });
      // rename 前再查一次：并发写同名项目时，后来的那个干净失败。
      if (dir.existsSync()) throw VideoProjectFailure('project_exists', name);
      staging.renameSync(dir.path);
    } catch (error) {
      _deleteQuietly(staging);
      if (dir.existsSync()) throw VideoProjectFailure('project_exists', name);
      if (error is VideoProjectFailure) rethrow;
      throw VideoProjectFailure('io_error', '$error');
    } finally {
      _deleteQuietly(staging);
    }

    return VideoProjectSnapshot(
      name: name,
      title: resolvedTitle,
      timeline: tl,
      spec: normalizedSpec ?? <String, dynamic>{},
      document: document,
      dir: dir.path,
    );
  }

  /// 删除项目目录（工作台「删除」入口；名称校验在 [_projectDir] 里）。
  Future<void> delete(String name) async {
    final base = await resolveRoot();
    final dir = _projectDir(base, name);
    if (!dir.existsSync()) throw VideoProjectFailure('no_project', name);
    try {
      dir.deleteSync(recursive: true);
    } catch (error) {
      throw VideoProjectFailure('io_error', '$error');
    }
  }

  // ------------------------------------------------------------------ 写盘

  /// 稳定 JSON：两空格缩进 + 末尾换行（手改 diff 可读、字节可复现）。
  void _writeJson(File file, Map<String, dynamic> data) {
    file.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(data)}\n',
      flush: true,
    );
  }

  /// 清掉暂存目录/残留临时文件；清理失败不能盖掉原始错误。
  void _deleteQuietly(Directory dir) {
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } catch (_) {}
  }

  // --------------------------------------------------------------- 单一容器

  /// 把项目打包成单一容器，原子写到项目根目录：`<根>/<name>.nvdo`。
  ///
  /// 打包内容 = 项目目录里的 UTF-8 文本文件（`timeline.json` / `spec.json` /
  /// `video.json` 及其它源码；`docs.md` / `brief.md` 有正文时同时进容器的
  /// `docs` 字段）；事实源 `spec.json` 的解码视图进 `spec`。项目读不出来
  /// （缺时间线/规范、规范非法）先抛 [VideoProjectFailure]（坏项目不导出）；
  /// 容器或文件系统失败抛 [WorkbenchPackFailure]（code / message 原样保留，
  /// 不吞）。
  Future<File> exportPack(String name) async {
    final VideoProjectSnapshot snapshot = await read(name);
    final Directory dir = Directory(snapshot.dir);
    return exportProjectPack(
      kind: WorkbenchPackKind.video.wire,
      projectDir: dir,
      name: name,
      title: snapshot.title,
      docs: readProjectDocs(dir),
      spec: snapshot.spec,
    );
  }

  /// 从单一容器导入项目；包内 `name` 决定目标目录 `<根>/<name>`。
  ///
  /// **目标已存在时拒绝**（抛 [WorkbenchPackFailure] `pack_target_exists`），
  /// 不覆盖、不合并既有项目——重名项目换一个名字再导入。坏容器 / 版本不支持 /
  /// 错 kind 同样显性失败（`WorkbenchPackFailure`）；包内 name 不合本存储
  /// 白名单时抛 [VideoProjectFailure] `invalid_name`。任何失败都不留半成品，
  /// 项目根保持原样（解包暂存目录会被清理）。
  Future<void> importPack(File file) async {
    final WorkbenchPack pack = await WorkbenchPack.readFrom(file);
    requirePackKind(pack, WorkbenchPackKind.video.wire);
    final Directory base = await resolveRoot();
    final Directory target = _projectDir(base, pack.name);
    await importProjectPack(
      file,
      projectDir: target,
      expectKind: WorkbenchPackKind.video.wire,
    );
  }

  /// 视频根下所有 `.nvdo` 打包文件（按文件名排序）。
  ///
  /// 隐藏 / 临时文件与包内 name 不合本项目名白名单的包不列（列出来的包
  /// 一定能用 [importPack] 导入）。不影响 [list]：它只认项目目录。
  Future<List<File>> listPacks() async {
    final base = await resolveRoot();
    return listProjectPacks(
      base,
      kind: WorkbenchPackKind.video.wire,
      accept: (String name) => _namePattern.hasMatch(name),
    );
  }
}
