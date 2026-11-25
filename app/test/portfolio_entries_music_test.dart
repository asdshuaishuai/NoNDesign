// 首页「作品集」音乐项目条目回归（task-9：音乐项目跟随链路）。
//
// 覆盖：
//   * 扫描 `<项目根>/portfolio/music/<name>/score.json` 生成
//     PortfolioEntry(kind:'music', ref:name, title, detail:'音乐 · N 轨 / M 小节')；
//   * 音乐类别 append 在末尾：热应用 → 3D → 视频 → 音乐（类别顺序稳定）；
//   * 坏项目（缺 score.json / 读不出 / 目录名非法）跳过，不炸其它来源；
//   * 项目根复用 AppPaths（生产默认路径）与 MusicProjectStore 注入（测试临时根）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:nondesign/core/app_paths.dart';
import 'package:nondesign/core/music/music_project.dart';
import 'package:nondesign/core/music/music_score.dart';
import 'package:nondesign/core/nonapp_library.dart';
import 'package:nondesign/core/portfolio_entries.dart';
import 'package:nondesign/core/three_service.dart';

/// 一个校验通过的乐谱：默认 1 轨 1 小节，用于生成真实 score.json。
MusicScore _score({String title = '练习曲', int tracks = 1, int measures = 1}) =>
    MusicScore(
      title: title,
      tempo: 96,
      timeSig: const <int>[4, 4],
      keySig: 'C',
      tracks: <MusicTrack>[
        for (int i = 0; i < tracks; i++)
          MusicTrack(
            id: 'track_$i',
            name: i == 0 ? '主旋律' : '低音',
            instrument: i == 0 ? 'piano' : 'bass',
            measures: <MusicMeasure>[
              for (int m = 0; m < measures; m++)
                MusicMeasure(
                  id: 'm${m + 1}',
                  events: <MusicEvent>[
                    MusicEvent(
                      id: 'n${i}_$m',
                      isRest: false,
                      durNum: 1,
                      durDen: 1,
                      step: 'C',
                      octave: i == 0 ? 5 : 3,
                    ),
                  ],
                ),
            ],
          ),
      ],
    );

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('nd_portfolio_music');
  });

  tearDown(() {
    AppPaths.projectsRootOverride = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Directory musicRoot({bool create = true}) {
    final dir = Directory('${tmp.path}/portfolio/music');
    if (create && !dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// 写一个可被库扫描到的热应用（manifest + index.html）。
  void writeHotapp(String rootPath, String name, {String title = ''}) {
    final dir = Directory('$rootPath/$name')..createSync(recursive: true);
    File('${dir.path}/manifest.json').writeAsStringSync(
      jsonEncode(<String, Object?>{
        'name': name,
        'title': title.isEmpty ? name : title,
        'renderer': 'html',
        'createdAt': 1760000000000,
      }),
    );
    File('${dir.path}/index.html')
        .writeAsStringSync('<!doctype html><html></html>');
  }

  void writeThree(String rootPath, String name) {
    final dir = Directory('$rootPath/$name')..createSync(recursive: true);
    File('${dir.path}/build-state.json').writeAsStringSync(
      jsonEncode(<String, Object?>{'current': 'material', 'blocked': false}),
    );
  }

  File writeVideo(Directory root, String name, DateTime modified) {
    final file = File('${root.path}/$name')
      ..createSync(recursive: true)
      ..writeAsBytesSync(const <int>[0, 0, 0]);
    file.setLastModifiedSync(modified);
    return file;
  }

  /// 路径断言用：Windows 上扫描出来的绝对路径是反斜杠，先归一化再比较。
  String normPath(String path) => path.replaceAll(r'\', '/');

  Future<List<PortfolioEntry>> load({
    MusicProjectStore? musicStore,
    int limit = 0,
  }) => loadPortfolioEntries(
    library: NonAppLibrary(root: Directory('${tmp.path}/hotapps')),
    threeService: ThreeService(root: Directory('${tmp.path}/3d')),
    videoRoot: Directory('${tmp.path}/videos'),
    musicStore: musicStore,
    limit: limit,
  );

  test('扫描音乐项目：字段齐全，同类按目录修改时间倒序', () async {
    final root = musicRoot();
    final store = MusicProjectStore(root: root);
    await store.save('dusk', _score(title: '暮色', tracks: 1, measures: 2));
    // 目录 mtime 决定同类排序：隔开一点再写 dawn，保证它比 dusk 新。
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await store.save('dawn', _score(title: '晨光', tracks: 2, measures: 1));

    final entries = await load(musicStore: store);

    expect(entries.map((e) => e.kind).toList(), <String>['music', 'music']);
    expect(entries.map((e) => e.ref).toList(), <String>[
      'dawn',
      'dusk',
    ], reason: '音乐类内部按修改时间倒序');
    final PortfolioEntry dawn = entries.first;
    expect(dawn.title, '晨光', reason: '标题取 score.json，不取目录名');
    expect(dawn.detail, '音乐 · 2 轨 / 1 小节');
    expect(normPath(dawn.path!), endsWith('/portfolio/music/dawn'));
    expect(dawn.modified, isNotNull);
    expect(entries.last.title, '暮色');
    expect(entries.last.detail, '音乐 · 1 轨 / 2 小节');
  });

  test('音乐 append 在末尾：热应用 → 3D → 视频 → 音乐 顺序稳定', () async {
    final libRoot = Directory('${tmp.path}/hotapps')
      ..createSync(recursive: true);
    writeHotapp(libRoot.path, 'demo-app', title: '演示应用');
    final threeRoot = Directory('${tmp.path}/3d')..createSync(recursive: true);
    writeThree(threeRoot.path, 'saturn-demo');
    final videos = Directory('${tmp.path}/videos')..createSync(recursive: true);
    writeVideo(videos, 'clip.mp4', DateTime(2026, 11, 19, 10));
    final store = MusicProjectStore(root: musicRoot());
    await store.save('dawn', _score(title: '晨光'));

    final entries = await load(musicStore: store);

    expect(entries.map((e) => e.kind).toList(), <String>[
      'hotapp',
      'three',
      'video',
      'music',
    ], reason: '音乐是新类别，append 在末尾，不打乱现有类别顺序');
    expect(entries.last.ref, 'dawn');
    expect(entries.last.detail, '音乐 · 1 轨 / 1 小节');
  });

  test('坏项目跳过：缺 score.json / 坏 JSON / 非法目录名都不进作品集，其它来源不受影响', () async {
    final root = musicRoot();
    final store = MusicProjectStore(root: root);
    await store.save('good', _score(title: '完好'));
    // 坏 JSON。
    Directory('${root.path}/broken').createSync(recursive: true);
    File('${root.path}/broken/score.json').writeAsStringSync('{not json');
    // 缺 score.json 的目录。
    Directory('${root.path}/missing').createSync(recursive: true);
    // 非法项目名（含空格）。
    Directory('${root.path}/bad name').createSync(recursive: true);
    // 非目录实体。
    File('${root.path}/stray.txt').writeAsStringSync('not a project');
    // 另一个来源（3D）照常存在，验证坏项目不连带其它类别失败。
    final threeRoot = Directory('${tmp.path}/3d')..createSync(recursive: true);
    writeThree(threeRoot.path, 'saturn-demo');

    final entries = await load(musicStore: store);

    final music = entries.where((e) => e.kind == 'music').toList();
    expect(music.map((e) => e.ref).toList(), <String>['good']);
    expect(music.single.detail, '音乐 · 1 轨 / 1 小节');
    expect(entries.where((e) => e.kind == 'three').length, 1);
  });

  test('未注入 musicStore 时复用 AppPaths 项目根扫描（生产默认路径可测）', () async {
    AppPaths.projectsRootOverride = tmp;
    final root = musicRoot();
    final store = MusicProjectStore(root: root);
    await store.save('dawn', _score(title: '晨光'));

    final entries = await load();

    final music = entries.where((e) => e.kind == 'music').toList();
    expect(music.single.ref, 'dawn');
    expect(music.single.title, '晨光');
    expect(music.single.detail, '音乐 · 1 轨 / 1 小节');
  });
}
