// 首页「作品集」展开卡的数据源回归（用户裁决 2026-11-19：
// 首页作品集要像「最近项目」一样展开，而不是一张只跳转的窄卡）。
//
// 覆盖：三类来源（热应用 / 3D / 视频）各自 best-effort、视频按修改时间倒序、
// 总条数截断、坏目录不影响其它来源、标题/类型/时间字段。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:nondesign/core/nonapp_library.dart';
import 'package:nondesign/core/portfolio_entries.dart';
import 'package:nondesign/core/three_service.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('nd_portfolio_entries');
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Directory _videoRoot() {
    final dir = Directory('${tmp.path}/videos')..createSync(recursive: true);
    return dir;
  }

  /// 写一个可被库扫描到的热应用（manifest + index.html）。
  void writeHotapp(String rootPath, String name, {String title = ''}) {
    final dir = Directory('${rootPath}/$name')..createSync(recursive: true);
    File('${dir.path}/manifest.json').writeAsStringSync(jsonEncode({
      'name': name,
      'title': title.isEmpty ? name : title,
      'renderer': 'html',
      'createdAt': 1760000000000,
    }));
    File('${dir.path}/index.html').writeAsStringSync('<!doctype html><html></html>');
  }

  void writeThree(String rootPath, String name, {bool blocked = false}) {
    final dir = Directory('${rootPath}/$name')..createSync(recursive: true);
    File('${dir.path}/build-state.json').writeAsStringSync(jsonEncode({
      'current': 'material',
      'blocked': blocked,
    }));
  }

  File writeVideo(Directory root, String name, DateTime modified) {
    final file = File('${root.path}/$name')
      ..createSync(recursive: true)
      ..writeAsBytesSync(const [0, 0, 0]);
    file.setLastModifiedSync(modified);
    return file;
  }

  test('三类来源汇总：热应用 → 3D → 视频，字段齐全', () async {
    final libRoot = Directory('${tmp.path}/hotapps')..createSync(recursive: true);
    writeHotapp(libRoot.path, 'demo-app', title: '演示应用');
    final threeRoot = Directory('${tmp.path}/three')..createSync(recursive: true);
    writeThree(threeRoot.path, 'saturn-demo');
    final videos = _videoRoot();
    writeVideo(videos, 'clip.mp4', DateTime(2026, 11, 19, 10));

    final entries = await loadPortfolioEntries(
      library: NonAppLibrary(root: libRoot),
      threeService: ThreeService(root: threeRoot),
      videoRoot: videos,
    );

    expect(entries.map((e) => e.kind).toList(), ['hotapp', 'three', 'video']);
    final app = entries[0];
    expect(app.ref, 'demo-app');
    expect(app.title, '演示应用');
    expect(app.detail, '热应用');
    expect(app.modified, isNotNull);
    final scene = entries[1];
    expect(scene.ref, 'saturn-demo');
    expect(scene.detail, '3D 场景');
    final clip = entries[2];
    expect(clip.title, 'clip.mp4');
    expect(clip.detail, '视频');
    expect(clip.path, endsWith('clip.mp4'));
    expect(clip.modified, isNotNull);
  });

  test('视频按修改时间倒序；3D 未完成标记可见', () async {
    final videos = _videoRoot();
    writeVideo(videos, 'older.mp4', DateTime(2026, 11, 18, 8));
    writeVideo(videos, 'newer.mp4', DateTime(2026, 11, 19, 8));
    final threeRoot = Directory('${tmp.path}/three')..createSync(recursive: true);
    writeThree(threeRoot.path, 'unfinished', blocked: true);

    final entries = await loadPortfolioEntries(
      library: NonAppLibrary(root: Directory('${tmp.path}/hotapps')),
      threeService: ThreeService(root: threeRoot),
      videoRoot: videos,
    );

    final videosOnly = entries.where((e) => e.kind == 'video').toList();
    expect(videosOnly.first.title, 'newer.mp4', reason: '视频必须按修改时间倒序');
    expect(videosOnly.last.title, 'older.mp4');
    final scene = entries.firstWhere((e) => e.kind == 'three');
    expect(scene.detail, contains('未完成'));
  });

  test('总条数按 limit 截断（默认 5 条）', () async {
    final libRoot = Directory('${tmp.path}/hotapps')..createSync(recursive: true);
    for (var i = 0; i < 4; i++) {
      writeHotapp(libRoot.path, 'app-$i');
    }
    final threeRoot = Directory('${tmp.path}/three')..createSync(recursive: true);
    for (var i = 0; i < 4; i++) {
      writeThree(threeRoot.path, 'scene-$i');
    }
    final videos = _videoRoot();
    for (var i = 0; i < 4; i++) {
      writeVideo(videos, 'v$i.mp4', DateTime(2026, 11, 19, i));
    }

    final all = await loadPortfolioEntries(
      library: NonAppLibrary(root: libRoot),
      threeService: ThreeService(root: threeRoot),
      videoRoot: videos,
    );
    expect(all.length, kHomePortfolioLimit, reason: '首页默认只展示 5 条');
    expect(all.take(4).map((e) => e.kind).toSet(), {'hotapp'},
        reason: '类别顺序稳定：热应用在前');
    expect(all.last.kind, 'three', reason: '第 5 条轮到 3D 场景');
  });

  test('目录不存在 / 读不出来：不抛错，缺哪类就少哪类', () async {
    final entries = await loadPortfolioEntries(
      library: NonAppLibrary(root: Directory('${tmp.path}/missing-hotapps')),
      threeService: ThreeService(root: Directory('${tmp.path}/missing-three')),
      videoRoot: Directory('${tmp.path}/missing-videos'),
    );
    expect(entries, isEmpty);
  });

  test('损坏的热应用目录仍以条目出现（不静默消失）', () async {
    final libRoot = Directory('${tmp.path}/hotapps')..createSync(recursive: true);
    final broken = Directory('${libRoot.path}/broken-app')..createSync(recursive: true);
    File('${broken.path}/manifest.json').writeAsStringSync('{ not json');
    final entries = await loadPortfolioEntries(
      library: NonAppLibrary(root: libRoot),
      threeService: ThreeService(root: Directory('${tmp.path}/three')),
      videoRoot: Directory('${tmp.path}/videos'),
    );
    expect(entries, hasLength(1));
    expect(entries.single.title, 'broken-app');
  });

  test('通用文件名（frames.mp4）用目录名当标题，避免首页一排同名条目', () async {
    final videos = _videoRoot();
    final dir = Directory('${videos.path}/video-1795006477531-1')..createSync(recursive: true);
    writeVideo(dir, 'frames.mp4', DateTime(2026, 11, 19, 9));

    final entries = await loadPortfolioEntries(
      library: NonAppLibrary(root: Directory('${tmp.path}/hotapps')),
      threeService: ThreeService(root: Directory('${tmp.path}/three')),
      videoRoot: videos,
    );
    expect(entries, hasLength(1));
    expect(entries.single.title, 'video-1795006477531-1');
    expect(entries.single.path, endsWith('frames.mp4'));
  });
}
