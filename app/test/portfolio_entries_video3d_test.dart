// 首页「作品集」3D 视频项目条目回归（task-12）。
//
// 覆盖：
//   * 扫描 `<项目根>/portfolio/video3d/<name>/`（两份事实源存在即项目）生成
//     PortfolioEntry(kind:'video3d', ref:name, title:name,
//     detail:'3D 视频 · N 镜头 / M 帧' 或 '3D 视频 · 未通过校验')；
//   * 坏项目（缺文件 / 坏 JSON / 非法目录名 / 隐藏目录）跳过，不炸其它来源；
//   * 3D 视频类别 append 在音乐之后：热应用 → 3D → 视频 → 音乐 → 3D 视频；
//   * 同类按目录修改时间倒序；
//   * Video3dProjectStore 注入临时根（测试）与生产默认 AppPaths 项目根可测。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:nondesign/core/app_paths.dart';
import 'package:nondesign/core/music/music_project.dart';
import 'package:nondesign/core/music/music_score.dart';
import 'package:nondesign/core/nonapp_library.dart';
import 'package:nondesign/core/portfolio_entries.dart';
import 'package:nondesign/core/three_service.dart';
import 'package:nondesign/core/video3d/video3d_project.dart';

// ---------------------------------------------------------------------------
// Fixtures：契约层合法输入（与 video3d_workspace_test 同族的最小场景）。
// ---------------------------------------------------------------------------

Map<String, Object?> _scene() => <String, Object?>{
  'v': 1,
  'units': 'm',
  'nodes': <Object?>[
    <String, Object?>{
      'id': 'floor',
      'type': 'box',
      'size': <double>[10, 0.1, 10],
      'position': <double>[0, -0.05, 0],
    },
  ],
  'lights': <Object?>[
    <String, Object?>{
      'id': 'key',
      'type': 'directional',
      'position': <double>[4, 6, 4],
      'target': <double>[0, 0, 0],
    },
  ],
  'cameras': <Object?>[
    <String, Object?>{
      'id': 'hero',
      'position': <double>[4, 2, 4],
      'target': <double>[0, 0.5, 0],
      'fov': 45,
    },
  ],
};

/// 合法镜头表：镜头时长之和即片长，固定 30fps。
Map<String, Object?> _screenplay(
  List<double> shotDurations, {
  String cameraId = 'hero',
}) {
  final double total = shotDurations.fold<double>(
    0,
    (double sum, double value) => sum + value,
  );
  return <String, Object?>{
    'v': 1,
    'fps': 30,
    'format': <String, Object?>{'width': 1280, 'height': 720},
    'duration': total,
    'shots': <Object?>[
      for (int i = 0; i < shotDurations.length; i++)
        <String, Object?>{
          'id': 's${i + 1}',
          'duration': shotDurations[i],
          'camera': <String, Object?>{'id': cameraId},
        },
    ],
  };
}

String _prettyJson(Object? value) =>
    '${const JsonEncoder.withIndent('  ').convert(value)}\n';

/// 路径断言用：Windows 上扫描出来的绝对路径是反斜杠，先归一化再比较。
String _normPath(String path) => path.replaceAll(r'\', '/');

MusicScore _score({String title = '练习曲'}) => MusicScore(
  title: title,
  tempo: 96,
  timeSig: const <int>[4, 4],
  keySig: 'C',
  tracks: <MusicTrack>[
    MusicTrack(
      id: 'melody',
      name: '主旋律',
      instrument: 'piano',
      measures: <MusicMeasure>[
        MusicMeasure(
          id: 'm1',
          events: <MusicEvent>[
            MusicEvent(
              id: 'n1',
              isRest: false,
              durNum: 1,
              durDen: 1,
              step: 'C',
              octave: 5,
            ),
          ],
        ),
      ],
    ),
  ],
);

void main() {
  late Directory tmp;
  late Directory video3dRoot;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('nd_portfolio_video3d');
    video3dRoot = Directory('${tmp.path}/portfolio/video3d')
      ..createSync(recursive: true);
  });

  tearDown(() {
    AppPaths.projectsRootOverride = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Video3dProjectStore store() => Video3dProjectStore(root: video3dRoot);

  /// 写一个可被库扫描到的热应用（manifest + index.html）。
  void writeHotapp(String rootPath, String name) {
    final Directory dir = Directory('$rootPath/$name')
      ..createSync(recursive: true);
    File('${dir.path}/manifest.json').writeAsStringSync(
      jsonEncode(<String, Object?>{
        'name': name,
        'title': name,
        'renderer': 'html',
        'createdAt': 1760000000000,
      }),
    );
    File('${dir.path}/index.html')
        .writeAsStringSync('<!doctype html><html></html>');
  }

  void writeThree(String rootPath, String name) {
    final Directory dir = Directory('$rootPath/$name')
      ..createSync(recursive: true);
    File('${dir.path}/build-state.json').writeAsStringSync(
      jsonEncode(<String, Object?>{'current': 'material', 'blocked': false}),
    );
  }

  void writeVideo(Directory root, String name, DateTime modified) {
    final File file = File('${root.path}/$name')
      ..createSync(recursive: true)
      ..writeAsBytesSync(const <int>[0, 0, 0]);
    file.setLastModifiedSync(modified);
  }

  Future<List<PortfolioEntry>> load({
    Video3dProjectStore? video3dStore,
    MusicProjectStore? musicStore,
    int limit = 0,
  }) => loadPortfolioEntries(
    library: NonAppLibrary(root: Directory('${tmp.path}/hotapps')),
    threeService: ThreeService(root: Directory('${tmp.path}/3d')),
    videoRoot: Directory('${tmp.path}/videos'),
    musicStore: musicStore,
    video3dStore: video3dStore,
    limit: limit,
  );

  test('扫描 3D 视频项目：字段齐全，校验通过给镜头数与总帧数', () async {
    final Video3dProjectStore projectStore = store();
    await projectStore.save(
      'single',
      scene: _scene(),
      screenplay: _screenplay(<double>[5.0]),
    );
    // 目录 mtime 决定同类排序：隔开一点再写 second，让 second 更新。
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await projectStore.save(
      'second',
      scene: _scene(),
      screenplay: _screenplay(<double>[5.0, 3.0]),
    );

    final List<PortfolioEntry> entries = await load(video3dStore: projectStore);

    expect(entries.map((PortfolioEntry e) => e.kind).toList(), <String>[
      'video3d',
      'video3d',
    ]);
    expect(entries.map((PortfolioEntry e) => e.ref).toList(), <String>[
      'second',
      'single',
    ], reason: '3D 视频类内部按修改时间倒序');

    final PortfolioEntry second = entries.first;
    expect(second.title, 'second', reason: '标题取目录名（与任务口径一致）');
    expect(second.detail, '3D 视频 · 2 镜头 / 240 帧');
    expect(_normPath(second.path!), endsWith('/portfolio/video3d/second'));
    expect(second.modified, isNotNull);
    expect(entries.last.detail, '3D 视频 · 1 镜头 / 150 帧');
  });

  test('未通过校验的项目保留：detail 标记「未通过校验」而不是消失', () async {
    final Video3dProjectStore projectStore = store();
    await projectStore.save(
      'good',
      scene: _scene(),
      screenplay: _screenplay(<double>[5.0]),
    );
    // 镜头引用了场景里不存在的相机：文件可读、契约不合格。
    final Directory dir = Directory('${video3dRoot.path}/unverified')
      ..createSync(recursive: true);
    File('${dir.path}/scene3d.json').writeAsStringSync(_prettyJson(_scene()));
    File('${dir.path}/screenplay3d.json').writeAsStringSync(
      _prettyJson(_screenplay(<double>[4.0], cameraId: 'ghost')),
    );

    final List<PortfolioEntry> entries = await load(video3dStore: projectStore);

    final PortfolioEntry unverified = entries.firstWhere(
      (PortfolioEntry e) => e.ref == 'unverified',
    );
    expect(unverified.kind, 'video3d');
    expect(unverified.detail, '3D 视频 · 未通过校验');
    expect(unverified.title, 'unverified');
    expect(
      entries.where((PortfolioEntry e) => e.detail.contains('未通过校验')),
      hasLength(1),
      reason: '只有不合格的那一条被标记，好的照常给帧数',
    );
  });

  test('坏项目跳过：缺文件 / 坏 JSON / 非法目录名 / 隐藏目录都不进作品集', () async {
    final Video3dProjectStore projectStore = store();
    await projectStore.save(
      'good',
      scene: _scene(),
      screenplay: _screenplay(<double>[5.0]),
    );
    // 缺 screenplay3d.json。
    final Directory missing = Directory('${video3dRoot.path}/missing')
      ..createSync(recursive: true);
    File('${missing.path}/scene3d.json')
        .writeAsStringSync(_prettyJson(_scene()));
    // 坏 JSON。
    final Directory broken = Directory('${video3dRoot.path}/broken')
      ..createSync(recursive: true);
    File('${broken.path}/scene3d.json').writeAsStringSync('{not json');
    File('${broken.path}/screenplay3d.json')
        .writeAsStringSync(_prettyJson(_screenplay(<double>[5.0])));
    // 非法项目名（含空格）与隐藏目录（写到一半的暂存目录）。
    Directory('${video3dRoot.path}/bad name').createSync(recursive: true);
    Directory('${video3dRoot.path}/.draft').createSync(recursive: true);
    // 非目录实体。
    File('${video3dRoot.path}/stray.txt').writeAsStringSync('not a project');
    // 另一个来源照常存在，验证坏项目不连带其它类别失败。
    final Directory threeRoot = Directory('${tmp.path}/3d')
      ..createSync(recursive: true);
    writeThree(threeRoot.path, 'saturn-demo');

    final List<PortfolioEntry> entries = await load(video3dStore: projectStore);

    final List<PortfolioEntry> video3d = entries
        .where((PortfolioEntry e) => e.kind == 'video3d')
        .toList();
    expect(video3d.map((PortfolioEntry e) => e.ref).toList(), <String>['good']);
    expect(video3d.single.detail, '3D 视频 · 1 镜头 / 150 帧');
    expect(
      entries.where((PortfolioEntry e) => e.kind == 'three'),
      hasLength(1),
    );
  });

  test('3D 视频 append 在音乐之后：热应用 → 3D → 视频 → 音乐 → 3D 视频', () async {
    final Directory libRoot = Directory('${tmp.path}/hotapps')
      ..createSync(recursive: true);
    writeHotapp(libRoot.path, 'demo-app');
    final Directory threeRoot = Directory('${tmp.path}/3d')
      ..createSync(recursive: true);
    writeThree(threeRoot.path, 'saturn-demo');
    final Directory videos = Directory('${tmp.path}/videos')
      ..createSync(recursive: true);
    writeVideo(videos, 'clip.mp4', DateTime(2026, 11, 19, 10));
    final MusicProjectStore musicStore = MusicProjectStore(
      root: Directory('${tmp.path}/portfolio/music')
        ..createSync(recursive: true),
    );
    await musicStore.save('dawn', _score(title: '晨光'));
    final Video3dProjectStore projectStore = store();
    await projectStore.save(
      'solo',
      scene: _scene(),
      screenplay: _screenplay(<double>[5.0]),
    );

    final List<PortfolioEntry> entries = await load(
      video3dStore: projectStore,
      musicStore: musicStore,
    );

    expect(entries.map((PortfolioEntry e) => e.kind).toList(), <String>[
      'hotapp',
      'three',
      'video',
      'music',
      'video3d',
    ], reason: '3D 视频是新类别，append 在音乐之后，不打乱现有类别顺序');
    expect(entries.last.ref, 'solo');
    expect(entries.last.detail, '3D 视频 · 1 镜头 / 150 帧');
  });

  test('未注入 video3dStore 时复用 AppPaths 项目根扫描（生产默认路径可测）', () async {
    AppPaths.projectsRootOverride = tmp;
    final Directory root = Directory('${tmp.path}/portfolio/video3d')
      ..createSync(recursive: true);
    final Video3dProjectStore projectStore = Video3dProjectStore(root: root);
    await projectStore.save(
      'night-market',
      scene: _scene(),
      screenplay: _screenplay(<double>[5.0]),
    );

    final List<PortfolioEntry> entries = await load();

    final List<PortfolioEntry> video3d = entries
        .where((PortfolioEntry e) => e.kind == 'video3d')
        .toList();
    expect(video3d.single.ref, 'night-market');
    expect(video3d.single.detail, '3D 视频 · 1 镜头 / 150 帧');
  });
}
