/// 首页「作品集」展开卡片的数据源（热应用 / 3D 场景 / 视频）。
///
/// 与艺术架（`PortfolioView`）同源但更轻：首页只列**非项目类**产物——
/// 原型项目在「最近项目」卡里已经列了一份，不重复。每个来源都 best-effort：
/// 一个目录读不到（权限/损坏）不得让其它来源消失，也不让首页报错。
library;

import 'dart:io';

import 'app_paths.dart';
import 'nonapp_library.dart';
import 'three_service.dart';

/// 一条作品集产物。
class PortfolioEntry {
  const PortfolioEntry({
    required this.kind,
    required this.ref,
    required this.title,
    required this.detail,
    this.path,
    this.modified,
  });

  /// `hotapp` / `three` / `video`。
  final String kind;

  /// 打开用的引用：热应用 = 应用名，3D = 项目名，视频 = 产物绝对路径。
  final String ref;

  final String title;

  /// 一行类型说明（用户可见）。
  final String detail;

  /// 视频产物的绝对路径（其它类型为 null）。
  final String? path;

  /// 修改时间（毫秒）；读不到时为 null。
  final int? modified;
}

/// 首页最多展示多少条（卡片高度与信息量之间的取舍）。
const int kHomePortfolioLimit = 5;

/// 汇总首页作品集条目：热应用库 → 3D 项目 → 视频产物，各自按修改时间倒序。
///
/// 总条数截到 [limit]（默认 [kHomePortfolioLimit]）；同类内部按时间倒序，
/// 类别之间保持「热应用 → 3D → 视频」的稳定顺序，避免首页顺序每次刷新乱跳。
Future<List<PortfolioEntry>> loadPortfolioEntries({
  NonAppLibrary? library,
  ThreeService? threeService,
  Directory? videoRoot,
  int limit = kHomePortfolioLimit,
}) async {
  final out = <PortfolioEntry>[];

  // 热应用：库里每个应用取目录 mtime 作为排序依据。
  try {
    final lib = library ?? await NonAppLibrary.open();
    final apps = await lib.scan();
    final entries = <PortfolioEntry>[];
    for (final app in apps) {
      final item = app.toShelfItem();
      entries.add(PortfolioEntry(
        kind: 'hotapp',
        ref: '${item['ref'] ?? app.name}',
        title: '${item['title'] ?? app.name}',
        detail: '${item['detail'] ?? '热应用'}',
        path: item['path']?.toString(),
        modified: _mtimeMs(item['path']?.toString()),
      ));
    }
    entries.sort(_newestFirst);
    out.addAll(entries);
  } catch (_) {
    // 库打不开：跳过这一类，不影响 3D/视频。
  }

  // 3D 场景：项目列表 + 目录 mtime。
  try {
    final svc = threeService ?? await ThreeService.open();
    final projects = await svc.listProjects();
    final entries = <PortfolioEntry>[];
    for (final project in projects) {
      entries.add(PortfolioEntry(
        kind: 'three',
        ref: project.name,
        title: project.name,
        detail: project.blocked ? '3D 场景 · 未完成' : '3D 场景',
        path: svc.projectDir(project.name).path,
        modified: _mtimeMs(svc.projectDir(project.name).path),
      ));
    }
    entries.sort(_newestFirst);
    out.addAll(entries);
  } catch (_) {
    // 3D 目录不可用：跳过。
  }

  // 视频产物：目录下所有 mp4（导出面仍隐藏，但既有产物要能被找到）。
  try {
    final root = videoRoot ??
        Directory('${(await AppPaths.projectsRoot()).path}/videos');
    if (root.existsSync()) {
      final files = <MapEntry<File, DateTime>>[];
      for (final entity in root.listSync(recursive: true, followLinks: false)) {
        if (entity is! File || !entity.path.toLowerCase().endsWith('.mp4')) continue;
        try {
          files.add(MapEntry(entity, entity.statSync().modified));
        } catch (_) {}
      }
      files.sort((a, b) => b.value.compareTo(a.value));
      out.addAll([
        for (final entry in files)
          PortfolioEntry(
            kind: 'video',
            ref: entry.key.path,
            title: _videoTitle(entry.key),
            detail: '视频',
            path: entry.key.path,
            modified: entry.value.millisecondsSinceEpoch,
          ),
      ]);
    }
  } catch (_) {
    // 视频目录不可用：跳过。
  }

  if (limit > 0 && out.length > limit) return out.sublist(0, limit);
  return out;
}

/// 视频条目的标题：产物批量导出时常统一叫 `frames.mp4`，那样首页会出现
/// 一排同名条目——这类通用文件名改用所在目录名，用户才分得清是哪一段。
String _videoTitle(File file) {
  final segments = file.uri.pathSegments.where((s) => s.isNotEmpty).toList();
  final name = segments.isEmpty ? file.path : segments.last;
  const generic = {'frames.mp4', 'output.mp4', 'video.mp4', 'render.mp4'};
  if (generic.contains(name.toLowerCase()) && segments.length >= 2) {
    return segments[segments.length - 2];
  }
  return name;
}

int _newestFirst(PortfolioEntry a, PortfolioEntry b) =>
    (b.modified ?? 0).compareTo(a.modified ?? 0);

/// 文件或目录的修改时间（毫秒）；不存在/读不到返回 null。
int? _mtimeMs(String? path) {
  if (path == null || path.isEmpty) return null;
  try {
    return FileSystemEntity.typeSync(path) == FileSystemEntityType.directory
        ? Directory(path).statSync().modified.millisecondsSinceEpoch
        : File(path).statSync().modified.millisecondsSinceEpoch;
  } catch (_) {
    return null;
  }
}
