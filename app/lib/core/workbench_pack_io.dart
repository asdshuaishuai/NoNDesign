/// 工作台项目「单一容器」的文件系统桥：项目目录 ⇄ `<kind 根>/<name><ext>`。
///
/// 容器格式与目录收集在 `workbench_pack.dart`（只读依赖，本层不改它）：
///  * [exportProjectPack] 用 [filesFromDirectory] 收集项目目录里的全部 **UTF-8
///    文本**文件（默认排除 artifacts / history / build-state 等产物缓存），
///    组成 [WorkbenchPack]，再原子写到**项目目录的父目录**（即该工作台的
///    项目根）：`<root>/<name><ext>`，扩展名由 `packExtensionFor(kind)` 决定；
///  * [importProjectPack] 解码 + 校验容器，先把全部文件写进同父目录下的
///    `.临时目录`，再整体 rename 成正式项目目录——**要么完整出现，要么什么都
///    不出现**；默认**拒绝已存在的目标**（不覆盖、不合并、不静默改既有项目）。
///
/// 错误约定：容器层 / 本层的失败一律是 [WorkbenchPackFailure]，`code` 与
/// `message` 原样保留（不吞、不换壳）；文件系统细节只进 `message`（折叠的
/// 技术详情），用户可见文案由 UI 层按 code 映射。
///
/// 本层纯 Dart（无 Flutter / 无引擎 / 无 WebView）；文件系统只出现在本文件的
/// 边界上。测试一律注入临时目录，不碰真实用户项目目录。
library;

import 'dart:io';

import 'workbench_pack.dart';

/// 打包 / 解包层在 [WorkbenchPackFailureCode] 之外追加的稳定机器码。
///
/// 容器格式本身的错误码仍在 [WorkbenchPackFailureCode]（复用、不复制）；
/// 这里只放「目录 ⇄ 容器」这一层特有的失败。
abstract final class WorkbenchPackIoFailureCode {
  const WorkbenchPackIoFailureCode._();

  /// 容器 kind 与目标存储不一致（例如把 3D 场景包导进音乐项目库）。
  static const String kindMismatch = 'pack_kind_mismatch';

  /// 目标项目目录已经存在。导入默认拒绝覆盖（不静默合并 / 不删旧内容）。
  static const String targetExists = 'pack_target_exists';

  /// 容器里没有任何文本文件：空容器不是可用项目，解包会静默造出空项目。
  static const String noFiles = 'pack_no_files';
}

/// 扩展名映射的重复导出不存在：扩展名唯一来源仍是
/// [packExtensionFor] / [WorkbenchPackKind.extension]。

/// 校验容器 kind 与目标存储一致；不一致抛 [WorkbenchPackFailure]
/// `pack_kind_mismatch`。
///
/// 供三个项目存储的 `importPack` 在解包前显性拒绝错 kind（错包不会先落盘再
/// 失败）。[expectedKind] 不在白名单时同样显性失败（`pack_unknown_kind`）。
void requirePackKind(WorkbenchPack pack, String expectedKind) {
  final WorkbenchPackKind? expected = WorkbenchPackKind.tryParse(expectedKind);
  if (expected == null) {
    throw WorkbenchPackFailure(
      WorkbenchPackFailureCode.unknownKind,
      'unknown expected workbench kind: "$expectedKind"',
    );
  }
  if (pack.kind != expected) {
    throw WorkbenchPackFailure(
      WorkbenchPackIoFailureCode.kindMismatch,
      'pack kind "${pack.kind.wire}" cannot be imported as "$expectedKind"',
    );
  }
}

/// 读项目内的人读文档：`docs.md` 优先，其次 `brief.md`；缺失 / 读失败 / 空白
/// 一律视为「没有文档」（与工作台文档栏同一口径）。
///
/// 导出时同时进容器的 `docs` 字段和 `files`（文本文件收集本来也会收它）；
/// 内容为空时返回 null，不把空白文件冒充成文档。
String? readProjectDocs(Directory projectDir) {
  for (final String name in const <String>['docs.md', 'brief.md']) {
    final File file = File('${projectDir.path}/$name');
    if (!file.existsSync()) continue;
    try {
      final String text = file.readAsStringSync();
      if (text.trim().isNotEmpty) return text;
    } on FileSystemException {
      // 读不出来就试下一个候选；都没有按「没有文档」处理（导出时该文件本身
      // 仍会被文本收集读到，收集失败会在导出处显性报错）。
    }
  }
  return null;
}

/// 扫描 [root] 下扩展名为 [kind] 的打包文件（按文件名排序）。
///
///  * 只列**普通文件**：目录、符号链接、隐藏文件（`.` 开头）与临时文件不列；
///  * [accept] 按 **包内 name**（文件名去掉扩展名）过滤：包内项目名必须能当
///    本工作台的项目目录名，才可能被对应 store 导入（例如 music 的
///    `[A-Za-z0-9_-]{1,64}`、video3d 的 ASCII 项目名）；
///  * 扩展名不区分大小写（`.NMU` 也列出，名字里的扩展名保留原样截掉）；
///  * 目录不存在 / 列不出来按空表处理（与三个 store 的 `list()` 同口径，
///    工作面给空态而不是把列目录失败当断言错误）。
List<File> listProjectPacks(
  Directory root, {
  required String kind,
  bool Function(String name)? accept,
}) {
  final String extension = packExtensionFor(kind);
  if (!root.existsSync()) return const <File>[];
  List<FileSystemEntity> entities;
  try {
    entities = root.listSync(followLinks: false);
  } catch (_) {
    return const <File>[];
  }
  final List<File> packs = <File>[];
  for (final FileSystemEntity entity in entities) {
    if (entity is! File) continue;
    final String leaf = _leafName(entity.path);
    if (leaf.startsWith('.')) continue;
    final String lower = leaf.toLowerCase();
    if (!lower.endsWith(extension)) continue;
    final String name = leaf.substring(0, leaf.length - extension.length);
    if (accept != null && !accept(name)) continue;
    packs.add(entity);
  }
  packs.sort(
    (File a, File b) => _leafName(a.path).compareTo(_leafName(b.path)),
  );
  return List<File>.unmodifiable(packs);
}

/// 把 [projectDir] 打包成单一容器并原子写入项目根。
///
/// 事实源字段：
///  * [kind] 工作台类型（design / three / video / video3d / music），扩展名走
///    [packExtensionFor]；未知 kind 显性失败（`pack_unknown_kind`）；
///  * [projectDir] 要收集的项目目录（必须是普通目录，符号链接 / 不存在都显性
///    失败 `pack_io_failed`）；收集规则见 [filesFromDirectory]（只收 UTF-8
///    文本，产物/缓存默认排除）；
///  * [name] 项目名，决定目标文件名 `<name><ext>`；容器层还会校验它不像路径
///    （`/`、`..`、控制字符等），本层再拒绝 `\`（Windows 上是路径分隔符，
///    否则目标会悄悄跑到子目录）；
///  * [title] 展示标题；缺省 / 空白时用 [name]（容器要求 title 是字符串）；
///  * [docs] 人读文档（调用方一般从 `readProjectDocs` 取）；缺省为 null；
///  * [spec] 机器可校验的规范（各自的事实源 JSON）；缺省为 null。
///
/// 目标文件写到 [projectDir] 的父目录（该工作台的项目根）：
/// `<projectDir.parent>/<name><ext>`。写入姿势复用 [WorkbenchPack.writeTo]
/// （同目录临时文件 + rename 原子替换），失败时旧打包文件保持原样。
///
/// 返回写出的打包文件；内容确定（同一项目目录 + 同一输入 → 同一字节，容器
/// 不写时间戳）。
Future<File> exportProjectPack({
  required String kind,
  required Directory projectDir,
  required String name,
  String? title,
  String? docs,
  Object? spec,
}) async {
  final String extension = packExtensionFor(kind);
  final WorkbenchPackKind parsedKind = WorkbenchPackKind.tryParse(kind)!;
  if (name.contains('\\')) {
    throw WorkbenchPackFailure(
      WorkbenchPackFailureCode.invalidField,
      'field "name" must not contain a backslash: "$name"',
    );
  }
  final String trimmedTitle = (title ?? '').trim();
  final Map<String, String> files = filesFromDirectory(projectDir);
  final WorkbenchPack pack = WorkbenchPack(
    kind: parsedKind,
    name: name,
    title: trimmedTitle.isEmpty ? name : trimmedTitle,
    docs: docs,
    spec: spec,
    files: files,
  );
  final File target = File('${projectDir.parent.path}/$name$extension');
  await pack.writeTo(target);
  return target;
}

/// 把单一容器解包到 [projectDir]：**先完整写进临时目录，再整体 rename**。
///
/// 语义：
///  * 先 [WorkbenchPack.readFrom] 解码（容器损坏 / 版本不支持 / 字段非法等
///    原样抛 [WorkbenchPackFailure]，不返回半成品）；
///  * [expectKind] 给定且与容器 kind 不符 → `pack_kind_mismatch`（在碰磁盘
///    之前拒绝）；
///  * 容器里没有文本文件 → `pack_no_files`（空容器不是可用项目）；
///  * **默认拒绝已存在的 [projectDir]**：目录 / 文件 / 符号链接占位都算存在
///    （`pack_target_exists`），绝不覆盖、删除或往旧项目里合并文件；换目标
///    或用不存在的项目目录再导入；
///  * 全部文件（[WorkbenchPack.files] 的相对 POSIX 路径）按目录结构写进
///    同父目录的 `.临时目录`（每个文件 flush），成功后 rename 成 [projectDir]；
///    任何失败都清掉临时目录 → 目标要么完整出现、要么完全不存在，不留半成品；
///  * 容器的 `docs` / `spec` / `title` 是冗余元数据（事实源是 `files` 里原文
///    件），解包只按 `files` 还原磁盘内容，不凭元数据另造文件（避免造出与
///    原项目不一致的 `docs.md`）。
///
/// 返回解包后的项目目录。[projectDir] 的子路径若非容器允许的安全相对路径，
/// 容器解码阶段已显性失败（`pack_invalid_path`）；`files` 里同时出现
/// `a` 与 `a/b` 这种「一个当文件、一个当目录」的组合也会显性失败
/// （`pack_invalid_path`），不靠平台相关的写盘错误碰运气。
Future<Directory> importProjectPack(
  File packFile, {
  required Directory projectDir,
  String? expectKind,
}) async {
  final WorkbenchPack pack = await WorkbenchPack.readFrom(packFile);
  if (expectKind != null) requirePackKind(pack, expectKind);
  if (pack.files.isEmpty) {
    throw const WorkbenchPackFailure(
      WorkbenchPackIoFailureCode.noFiles,
      'pack contains no text files; refusing to create an empty project',
    );
  }
  _validateFileSet(pack.files.keys);

  final Directory target = projectDir;
  final FileSystemEntityType occupying = FileSystemEntity.typeSync(
    target.path,
    followLinks: false,
  );
  if (occupying != FileSystemEntityType.notFound) {
    throw WorkbenchPackFailure(
      WorkbenchPackIoFailureCode.targetExists,
      'target project directory already exists: "${target.path}"',
    );
  }

  final Directory parent = target.parent;
  final String stamp = DateTime.now().microsecondsSinceEpoch.toString();
  final Directory staging = Directory(
    '${parent.path}/.${_leafName(target.path)}.$stamp.tmp',
  );
  try {
    try {
      parent.createSync(recursive: true);
      staging.createSync(recursive: true);
      for (final MapEntry<String, String> entry in pack.files.entries) {
        final File file = File('${staging.path}/${entry.key}');
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(entry.value, flush: true);
      }
    } catch (error) {
      throw _ioFailure('import staging failed for "${target.path}"', error);
    }

    try {
      staging.renameSync(target.path);
    } on FileSystemException catch (error) {
      // 预检之后目标才被别处占位：仍然按「已存在」显性失败，不覆盖。
      final FileSystemEntityType current = FileSystemEntity.typeSync(
        target.path,
        followLinks: false,
      );
      if (current != FileSystemEntityType.notFound) {
        throw WorkbenchPackFailure(
          WorkbenchPackIoFailureCode.targetExists,
          'target project directory appeared during import: "${target.path}"',
        );
      }
      throw _ioFailure('rename failed for "${target.path}"', error);
    }
  } finally {
    _deleteQuietly(staging);
  }
  return target;
}

// ------------------------------------------------------------------ 辅助

/// 校验 `files` 路径集合能落成一个目录树：同一路径不能既当文件又当目录
/// （容器允许两者共存，但磁盘上无法同时成立）。
void _validateFileSet(Iterable<String> paths) {
  final List<String> sorted = paths.toList(growable: false)..sort();
  for (var i = 1; i < sorted.length; i++) {
    final String previous = sorted[i - 1];
    final String current = sorted[i];
    if (!current.startsWith('$previous/')) continue;
    throw WorkbenchPackFailure(
      WorkbenchPackFailureCode.invalidPath,
      'file path "$previous" would also need to be a directory '
      'for "$current"',
    );
  }
}

WorkbenchPackFailure _ioFailure(String action, Object error) =>
    WorkbenchPackFailure(WorkbenchPackFailureCode.ioFailed, '$action: $error');

String _leafName(String path) {
  final List<String> segments = path
      .replaceAll('\\', '/')
      .split('/')
      .where((String segment) => segment.isNotEmpty)
      .toList(growable: false);
  return segments.isEmpty ? path : segments.last;
}

/// 清掉暂存目录；清理失败不能盖掉原始错误。
void _deleteQuietly(Directory dir) {
  try {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  } catch (_) {
    // 清理失败不能盖掉原始错误。
  }
}
