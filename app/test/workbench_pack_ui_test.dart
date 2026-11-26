// 工作台项目打包 UI 接线（task-35）：store 的打包出口 + 顶栏项目菜单入口。
//
// 覆盖本任务不可回退的语义：
//  1. `packKindForView`：`plugin:music`→music、`plugin:video`→video、
//     `plugin:video3d`→video3d，其它视图 null（设计面没有打包入口）；
//  2. `exportWorkbenchPack`：三个工作台各自产生扩展名正确的容器
//     （`.nmu` / `.nvdo` / `.n3v`），成功 toast「已打包：<文件名>」并返回 File；
//  3. 没有打开项目 / 视图不支持：人话提示且**不写盘**（不猜项目去打包）；
//  4. `importWorkbenchPack`：文件选择器按视图过滤扩展名（测试注入 fake，不弹
//     真对话框）→ 导入成功 → 刷新作品集 + 当前项目跟随 + toast「已导入：<名>」；
//  5. 同名导入拒绝（人话 + 旧项目字节不变）；错 kind / 坏容器显性失败；用户
//     取消不报错；
//  6. 顶栏项目菜单两项 Key 存在，按「当前视图 + 是否打开项目」启用/禁用，
//     点菜单项真的走 store 的导出（产生容器文件）。
//
// 全部用临时目录 + 注入项目库 / 文件选择器 / ToastService：不弹真文件对话框，
// 不写真实用户目录（AppPaths.projectsRootOverride 指向临时目录）。
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nondesign/core/app_paths.dart';
import 'package:nondesign/core/music/music_project.dart';
import 'package:nondesign/core/music/music_score.dart';
import 'package:nondesign/core/portfolio_entries.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/core/toast_service.dart';
import 'package:nondesign/core/video3d/video3d_project.dart';
import 'package:nondesign/core/video_project.dart';
import 'package:nondesign/core/workbench_pack.dart';
import 'package:nondesign/widgets/title_bar.dart';

// ---------------------------------------------------------------------------
// Fixtures（与多个工作台测试同形：只造「能过各自校验」的最小项目）
// ---------------------------------------------------------------------------

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

Map<String, Object?> _validScene() {
  return <String, Object?>{
    'v': 1,
    'units': 'm',
    'environment': <String, Object?>{'background': '#0b0d12'},
    'nodes': <Object?>[
      <String, Object?>{
        'id': 'floor',
        'type': 'box',
        'size': <double>[10, 0.1, 10],
        'position': <double>[0, -0.05, 0],
        'rotation': <double>[0, 0, 0],
        'scale': <double>[1, 1, 1],
        'material': <String, Object?>{
          'color': '#9a8c7a',
          'roughness': 0.9,
          'metalness': 0.0,
        },
        'parent': null,
      },
      <String, Object?>{
        'id': 'lamp',
        'type': 'sphere',
        'size': <double>[0.12, 0.12, 0.12],
        'rotation': <double>[0, 30, 0],
      },
    ],
    'lights': <Object?>[
      <String, Object?>{
        'id': 'key',
        'type': 'directional',
        'intensity': 1.0,
        'color': '#ffffff',
        'position': <double>[4, 6, 4],
        'target': <double>[0, 0, 0],
      },
    ],
    'cameras': <Object?>[
      <String, Object?>{
        'id': 'hero',
        'position': <double>[4, 2, 4],
        'target': <double>[0, 1, 0],
        'fov': 45,
      },
    ],
  };
}

Map<String, Object?> _validScreenplay({double? duration}) {
  return <String, Object?>{
    'v': 1,
    'fps': 30,
    'format': <String, Object?>{'width': 720, 'height': 1280},
    'seed': 0,
    'duration': ?duration,
    'shots': <Object?>[
      <String, Object?>{
        'id': 's1',
        'duration': 5.0,
        'camera': <String, Object?>{'id': 'hero'},
        'cues': <Object?>[],
      },
    ],
  };
}

Map<String, dynamic> _scienceSpec() => <String, dynamic>{
  'kind': 'science',
  'subject': '测试主题',
  'laws': <String>['质量守恒'],
  'assumptions': <String>['无空气阻力'],
  'facts': <String>['斜面摩擦因数 0.12'],
};

Map<String, dynamic> _timeline() => <String, dynamic>{
  'fps': 30,
  'width': 1280,
  'height': 720,
  'scenes': <Map<String, dynamic>>[
    <String, dynamic>{
      'duration': 1.0,
      'elements': <Map<String, dynamic>>[
        <String, dynamic>{'type': 'text', 'text': '你好', 'x': '50%', 'y': 100},
      ],
    },
  ],
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// 造一个 `.nmu` 音乐打包文件（供导入测试；内容是可读的 score.json）。
Future<File> _writeMusicPack(
  Directory dir,
  String name, {
  String title = '导入项目',
}) async {
  final File file = File('${dir.path}/$name.nmu');
  await WorkbenchPack(
    kind: WorkbenchPackKind.music,
    name: name,
    title: title,
    files: <String, String>{'score.json': jsonEncode(_score(title: title))},
  ).writeTo(file);
  return file;
}

/// 项目根下所有打包容器文件名（排序）。
List<String> _packNames(Directory dir) {
  if (!dir.existsSync()) return const <String>[];
  final names = <String>[
    for (final entity in dir.listSync(followLinks: false))
      if (entity is File) entity.uri.pathSegments.last,
  ]..sort();
  return names;
}

List<String> _entries(Directory dir) {
  if (!dir.existsSync()) return const <String>[];
  final names = <String>[
    for (final entity in dir.listSync(followLinks: false))
      entity.uri.pathSegments.where((String part) => part.isNotEmpty).last,
  ]..sort();
  return names;
}

Widget _titleBarApp(AppStore store) => ChangeNotifierProvider<AppStore>.value(
  value: store,
  child: MaterialApp(
    theme: AppTheme.build(dark: true),
    home: Scaffold(
      body: TitleBar(
        onCommand: () {},
        onSettings: () {},
        onNewProject: () {},
        onOpenProject: () {},
        onShortcuts: () {},
        onOpenRecent: (_) {},
      ),
    ),
  ),
);

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  await tester.pump(const Duration(milliseconds: 120));
}

Future<void> _openProjectMenu(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('title-bar-project-menu')));
  await tester.pumpAndSettle();
}

bool _menuItemEnabled(WidgetTester tester, String key) {
  return tester
      .widget<PopupMenuItem<String>>(find.byKey(ValueKey(key)))
      .enabled;
}

Future<void> _viewport(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1440, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  late Directory temp;
  late Directory projectsRoot;
  late Directory musicRoot;
  late Directory videoRoot;
  late Directory video3dRoot;
  late MusicProjectStore musicStore;
  late VideoProjectStore videoStore;
  late Video3dProjectStore video3dStore;
  late ToastService toasts;
  late AppStore appStore;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    temp = Directory.systemTemp.createTempSync('nd-pack-ui-');
    projectsRoot = Directory('${temp.path}/projects')
      ..createSync(recursive: true);
    // 作品集刷新（导入成功后的 refreshPortfolio）只看临时项目根，不扫真实
    // 用户目录。
    AppPaths.projectsRootOverride = projectsRoot;
    musicRoot = Directory('${projectsRoot.path}/portfolio/music');
    videoRoot = Directory('${projectsRoot.path}/video');
    video3dRoot = Directory('${projectsRoot.path}/portfolio/video3d');
    musicStore = MusicProjectStore(root: musicRoot);
    videoStore = VideoProjectStore(root: videoRoot);
    video3dStore = Video3dProjectStore(root: video3dRoot);
    toasts = ToastService(autoDismiss: false);
    appStore = AppStore(toasts: toasts)
      ..recoveryDir = '${temp.path}/state'
      ..settingsMirrorDir = '${temp.path}/state'
      ..musicProjectsOverride = musicStore
      ..videoProjectsOverride = videoStore
      ..video3dProjectsOverride = video3dStore;
  });

  tearDown(() {
    AppPaths.projectsRootOverride = null;
    if (temp.existsSync()) {
      try {
        temp.deleteSync(recursive: true);
      } on FileSystemException {
        // 清理失败不影响断言结果。
      }
    }
  });

  // -------------------------------------------------------------------------
  // 视图 → 打包 kind
  // -------------------------------------------------------------------------

  test('packKindForView：四个内容工作台映射到容器 kind，其它视图没有打包入口', () {
    expect(appStore.packKindForView('plugin:three'), 'three');
    expect(appStore.packKindForView('plugin:music'), 'music');
    expect(appStore.packKindForView('plugin:video'), 'video');
    expect(appStore.packKindForView('plugin:video3d'), 'video3d');
    for (final String other in <String>[
      'design',
      'home',
      'docs',
      'play',
      'source',
      'plugin:hotapp',
      '',
    ]) {
      expect(appStore.packKindForView(other), isNull, reason: '$other 没有打包入口');
    }
    // 扩展名唯一来源是容器层（UI 的文件选择器按它过滤）。
    expect(packExtensionFor('three'), '.n3d');
    expect(packExtensionFor('music'), '.nmu');
    expect(packExtensionFor('video'), '.nvdo');
    expect(packExtensionFor('video3d'), '.n3v');
  });

  // -------------------------------------------------------------------------
  // 导出
  // -------------------------------------------------------------------------

  test('exportWorkbenchPack：音乐 → `.nmu`，成功 toast「已打包：<文件名>」', () async {
    await musicStore.save('alpha', _score(title: '阿尔法'));
    appStore.view = 'plugin:music';
    appStore.setMusicProjectName('alpha');

    final File? file = await appStore.exportWorkbenchPack();

    expect(file, isNotNull);
    final File packFile = file!;
    expect(packFile.path, '${musicRoot.path}/alpha.nmu');
    expect(packFile.existsSync(), isTrue);
    final WorkbenchPack pack = await WorkbenchPack.readFrom(packFile);
    expect(pack.kind, WorkbenchPackKind.music);
    expect(pack.name, 'alpha');
    expect(toasts.history.first.title, '已打包：alpha.nmu');
    expect(toasts.history.first.level, ToastLevel.success);
  });

  test('exportWorkbenchPack：视频 → `.nvdo`，打包内容来自项目事实源', () async {
    await videoStore.create(
      name: 'clip',
      timeline: _timeline(),
      spec: _scienceSpec(),
      title: '测试视频',
    );
    appStore.view = 'plugin:video';
    appStore.setVideoProjectName('clip');

    final File? file = await appStore.exportWorkbenchPack();

    expect(file, isNotNull);
    expect(file!.path, '${videoRoot.path}/clip.nvdo');
    expect(file.path, endsWith('.nvdo'));
    final WorkbenchPack pack = await WorkbenchPack.readFrom(file);
    expect(pack.kind, WorkbenchPackKind.video);
    expect(pack.name, 'clip');
    expect(toasts.history.first.title, '已打包：clip.nvdo');
  });

  test('exportWorkbenchPack：3D 视频 → `.n3v`（当前项目来自 store 记录）', () async {
    final saved = await video3dStore.save(
      'stage',
      scene: _validScene(),
      screenplay: _validScreenplay(),
    );
    expect(saved.verified, isTrue, reason: 'fixture 必须是可保存的合规项目');
    appStore.view = 'plugin:video3d';
    appStore.setVideo3dProjectName('stage');

    final File? file = await appStore.exportWorkbenchPack();

    expect(file, isNotNull);
    expect(file!.path, '${video3dRoot.path}/stage.n3v');
    expect(file.path, endsWith('.n3v'));
    final WorkbenchPack pack = await WorkbenchPack.readFrom(file);
    expect(pack.kind, WorkbenchPackKind.video3d);
    expect(pack.name, 'stage');
    expect(toasts.history.first.title, '已打包：stage.n3v');
  });

  test('没有打开项目：三个工作台都给人话且不写盘', () async {
    for (final (String view, Directory root) in <(String, Directory)>[
      ('plugin:music', musicRoot),
      ('plugin:video', videoRoot),
      ('plugin:video3d', video3dRoot),
    ]) {
      appStore.view = view;
      final File? file = await appStore.exportWorkbenchPack();
      expect(file, isNull, reason: '$view 没有项目时不该产出容器');
      expect(
        _packNames(root),
        isEmpty,
        reason: '$view 没有项目时不该写盘：${_packNames(root)}',
      );
      expect(
        toasts.history.first.title,
        contains('先在'),
        reason: '$view 的人话提示要指路「先在对应工作台打开项目」',
      );
      expect(toasts.history.first.level, ToastLevel.warn);
    }
  });

  test('视图不支持打包（设计 / 热应用）：人话提示，不写盘', () async {
    for (final String view in <String>['design', 'plugin:hotapp']) {
      appStore.view = view;
      final File? file = await appStore.exportWorkbenchPack();
      expect(file, isNull);
      expect(toasts.history.first.title, contains('这个工作台暂时没有打包入口'));
    }
    expect(_packNames(projectsRoot), isEmpty);
  });

  // -------------------------------------------------------------------------
  // 导入
  // -------------------------------------------------------------------------

  test('importWorkbenchPack：选择器按视图过滤 `.nmu`；导入后刷新作品集 + 当前项目跟随', () async {
    final Directory downloads = Directory('${temp.path}/downloads')
      ..createSync(recursive: true);
    final File pack = await _writeMusicPack(downloads, 'beta', title: '贝塔');
    String? requestedExtension;
    appStore.pickPackFileOverride = (String extension) async {
      requestedExtension = extension;
      return pack.path;
    };
    appStore.view = 'plugin:music';

    final bool ok = await appStore.importWorkbenchPack();

    expect(ok, isTrue);
    expect(requestedExtension, '.nmu', reason: '文件选择器按当前视图的扩展名过滤');
    expect(
      (await musicStore.list()).map((MusicProjectEntry e) => e.name),
      contains('beta'),
      reason: '项目要真的落进当前工作台的项目库',
    );
    expect(appStore.musicProjectName, 'beta', reason: '导入后当前项目跟随导入项');
    expect(
      appStore.portfolioEntries.any(
        (PortfolioEntry entry) => entry.kind == 'music' && entry.ref == 'beta',
      ),
      isTrue,
      reason: '成功后刷新作品集（顶栏项目菜单/首页卡片同源）',
    );
    expect(toasts.history.first.title, '已导入：beta');
    expect(toasts.history.first.level, ToastLevel.success);
  });

  test(
    'importWorkbenchPack：3D 视频导入后当前项目跟随（`.n3v` + video3dProjectName）',
    () async {
      final Directory sourceRoot = Directory('${temp.path}/source-v3d')
        ..createSync(recursive: true);
      final Video3dProjectStore source = Video3dProjectStore(root: sourceRoot);
      await source.save(
        'stage',
        scene: _validScene(),
        screenplay: _validScreenplay(),
      );
      final File pack = await source.exportPack('stage');
      String? requestedExtension;
      appStore.pickPackFileOverride = (String extension) async {
        requestedExtension = extension;
        return pack.path;
      };
      appStore.view = 'plugin:video3d';

      final bool ok = await appStore.importWorkbenchPack();

      expect(ok, isTrue);
      expect(requestedExtension, '.n3v');
      final Video3dProjectSnapshot imported = await video3dStore.read('stage');
      expect(imported.verified, isTrue, reason: '导入的 3D 视频项目仍通过契约校验');
      expect(appStore.video3dProjectName, 'stage');
      expect(toasts.history.first.title, '已导入：stage');
    },
  );

  test('importWorkbenchPack：同名项目已存在 → 拒绝 + 人话，旧项目字节不变', () async {
    final MusicValidation validation = await musicStore.save(
      'beta',
      _score(title: '旧版本'),
    );
    expect(validation.verified, isTrue);
    final String before = File(
      '${musicRoot.path}/beta/${MusicProjectStore.scoreFile}',
    ).readAsStringSync();

    final Directory downloads = Directory('${temp.path}/downloads')
      ..createSync(recursive: true);
    final File incoming = await _writeMusicPack(
      downloads,
      'beta',
      title: '新版本',
    );
    appStore.pickPackFileOverride = (String extension) async => incoming.path;
    appStore.view = 'plugin:music';

    final bool ok = await appStore.importWorkbenchPack();

    expect(ok, isFalse);
    expect(toasts.history.first.level, ToastLevel.error);
    expect(toasts.history.first.title, contains('同名项目已存在'));
    final String after = File(
      '${musicRoot.path}/beta/${MusicProjectStore.scoreFile}',
    ).readAsStringSync();
    expect(after, before, reason: '导入失败绝不覆盖既有项目');
  });

  test('importWorkbenchPack：错 kind 的包显性失败（不落目标目录）', () async {
    final Directory sourceRoot = Directory('${temp.path}/source-v3d')
      ..createSync(recursive: true);
    final Video3dProjectStore source = Video3dProjectStore(root: sourceRoot);
    await source.save(
      'stage',
      scene: _validScene(),
      screenplay: _validScreenplay(),
    );
    final File wrongKindPack = await source.exportPack('stage');
    appStore.pickPackFileOverride = (String extension) async =>
        wrongKindPack.path;
    appStore.view = 'plugin:music';

    final bool ok = await appStore.importWorkbenchPack();

    expect(ok, isFalse);
    expect(_entries(musicRoot), isEmpty, reason: '错 kind 的包不能在音乐项目库留下半成品');
    expect(toasts.history.first.level, ToastLevel.error);
    expect(toasts.history.first.title, contains('属于别的工作台'));
  });

  test('importWorkbenchPack：坏容器给人话；用户取消不报错也不写盘', () async {
    final File broken = File('${temp.path}/broken.nmu')
      ..writeAsStringSync('not a nan.pack container');
    appStore.pickPackFileOverride = (String extension) async => broken.path;
    appStore.view = 'plugin:music';

    final bool ok = await appStore.importWorkbenchPack();

    expect(ok, isFalse);
    expect(_entries(musicRoot), isEmpty);
    expect(toasts.history.first.level, ToastLevel.error);
    expect(toasts.history.first.title, contains('不完整或已损坏'));

    // 取消：选择器返回 null → 无提示（不是失败，也不是成功）。
    toasts.clearHistory();
    appStore.pickPackFileOverride = (String extension) async => null;
    final bool cancelled = await appStore.importWorkbenchPack();
    expect(cancelled, isFalse);
    expect(toasts.history, isEmpty, reason: '用户取消不该弹失败提示');
    expect(_entries(musicRoot), isEmpty);
  });

  // -------------------------------------------------------------------------
  // 顶栏项目菜单
  // -------------------------------------------------------------------------

  testWidgets('顶栏项目菜单：打包/导入两项 Key 存在；音乐工作台有项目时都可用，导出真的写盘', (tester) async {
    await _viewport(tester);
    await musicStore.save('alpha', _score(title: '阿尔法'));
    appStore.view = 'plugin:music';
    appStore.setMusicProjectName('alpha');

    await tester.pumpWidget(_titleBarApp(appStore));
    await _openProjectMenu(tester);

    expect(find.byKey(const ValueKey('title-bar-export-pack')), findsOneWidget);
    expect(find.byKey(const ValueKey('title-bar-import-pack')), findsOneWidget);
    expect(find.text('打包当前项目…'), findsOneWidget);
    expect(find.text('导入打包项目…'), findsOneWidget);
    expect(_menuItemEnabled(tester, 'title-bar-export-pack'), isTrue);
    expect(_menuItemEnabled(tester, 'title-bar-import-pack'), isTrue);

    await tester.tap(find.byKey(const ValueKey('title-bar-export-pack')));
    await _settle(tester);

    final File expected = File('${musicRoot.path}/alpha.nmu');
    expect(expected.existsSync(), isTrue, reason: '菜单项要真的走 store 的导出');
    expect(toasts.history.first.title, '已打包：alpha.nmu');
    expect(tester.takeException(), isNull);
  });

  testWidgets('顶栏项目菜单：设计面两项都在但禁用（没有打包能力）', (tester) async {
    await _viewport(tester);
    appStore.view = 'design';

    await tester.pumpWidget(_titleBarApp(appStore));
    await _openProjectMenu(tester);

    expect(find.byKey(const ValueKey('title-bar-export-pack')), findsOneWidget);
    expect(find.byKey(const ValueKey('title-bar-import-pack')), findsOneWidget);
    expect(_menuItemEnabled(tester, 'title-bar-export-pack'), isFalse);
    expect(_menuItemEnabled(tester, 'title-bar-import-pack'), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('顶栏项目菜单：音乐工作台没打开项目 → 导出禁用、导入可用', (tester) async {
    await _viewport(tester);
    appStore.view = 'plugin:music';
    appStore.setMusicProjectName('');

    await tester.pumpWidget(_titleBarApp(appStore));
    await _openProjectMenu(tester);

    expect(_menuItemEnabled(tester, 'title-bar-export-pack'), isFalse);
    expect(_menuItemEnabled(tester, 'title-bar-import-pack'), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('顶栏项目菜单：切到 3D 视频项目记录当前项目，再导出 `.n3v`', (tester) async {
    await _viewport(tester);
    await video3dStore.save(
      'stage',
      scene: _validScene(),
      screenplay: _validScreenplay(),
    );
    appStore.portfolioEntries = const <PortfolioEntry>[
      PortfolioEntry(
        kind: 'video3d',
        ref: 'stage',
        title: '舞台',
        detail: '3D 视频 · 1 镜头',
      ),
    ];
    appStore.view = 'design';

    await tester.pumpWidget(_titleBarApp(appStore));
    await _openProjectMenu(tester);

    // 从「3D 视频」分区点进项目：这一跳是能观察到切换的入口，store 记录它。
    await tester.tap(find.text('舞台'));
    await _settle(tester);

    expect(appStore.view, 'plugin:video3d');
    expect(appStore.video3dProjectName, 'stage');

    // 再开一次菜单：这次导出入口可用，点它真的产生 `.n3v`。
    await _openProjectMenu(tester);
    expect(_menuItemEnabled(tester, 'title-bar-export-pack'), isTrue);

    await tester.tap(find.byKey(const ValueKey('title-bar-export-pack')));
    await _settle(tester);

    expect(File('${video3dRoot.path}/stage.n3v').existsSync(), isTrue);
    expect(toasts.history.first.title, '已打包：stage.n3v');
    expect(tester.takeException(), isNull);
  });
}
