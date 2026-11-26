// 工作台「单一容器」的文件系统桥（`workbench_pack_io.dart`）与三个项目存储
// （音乐 / 3D 视频 / 视频）的打包导出 / 导入 / 列表行为测试。
//
// 覆盖本任务不可回退的语义：
//  1. `exportProjectPack`：收集项目目录 UTF-8 文本 → 原子写到项目根
//     `<name><ext>`（扩展名按 kind）；title / docs / spec 进容器；重复导出
//     完整替换旧容器；不留临时文件；
//  2. `importProjectPack`：暂存目录 + 整体 rename，失败不留半成品；默认
//     **拒绝已存在的目标**（目录 / 文件占位都拒绝，旧内容原样）；
//  3. 坏包 / 版本不支持 / 错 kind / 空文件 / 路径冲突 / 父目录被占位都显性
//     失败（`WorkbenchPackFailure`，code / message 原样保留，不吞）；
//  4. 三个存储各自 exportPack → importPack 往返后 `read` 一致；扩展名
//     `.nmu` / `.n3v` / `.nvdo`；`listPacks` 只列自己的扩展名，不影响 `list`；
//  5. 目标已存在策略：三个存储的 `importPack` 都拒绝覆盖
//     （`pack_target_exists`），既有项目文件字节不变。
//
// 测试一律使用系统临时目录，不碰真实用户项目目录。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:nondesign/core/music/music_project.dart';
import 'package:nondesign/core/music/music_score.dart';
import 'package:nondesign/core/video3d/video3d_project.dart';
import 'package:nondesign/core/video_project.dart';
import 'package:nondesign/core/workbench_pack.dart';
import 'package:nondesign/core/workbench_pack_io.dart';

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

MusicScore _musicScore({String title = '练习曲'}) => MusicScore(
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

Map<String, Object?> _validScene({String floorColor = '#9a8c7a'}) {
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
          'color': floorColor,
          'roughness': 0.9,
          'metalness': 0.0,
        },
        'parent': null,
      },
      <String, Object?>{
        'id': 'table',
        'type': 'plane',
        'size': <double>[2, 1, 0],
        'position': <double>[0, 0.5, 0],
        'parent': 'floor',
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
      <String, Object?>{
        'id': 's2',
        'duration': 3.0,
        'camera': <String, Object?>{
          'id': 'hero',
          'move': <String, Object?>{
            'from': <double>[4, 2, 4],
            'to': <double>[3, 2.2, 4],
            'target': <double>[0, 1, 0],
            'easing': 'easeInOut',
          },
        },
      },
    ],
  };
}

/// 一份最小合规视频规范（科学线，硬门 1 的四个必填项都在）。
Map<String, dynamic> _scienceSpec({String subject = '测试主题'}) =>
    <String, dynamic>{
      'kind': 'science',
      'subject': subject,
      'laws': <String>['质量守恒'],
      'assumptions': <String>['无空气阻力'],
      'facts': <String>['斜面摩擦因数 0.12'],
    };

/// 一份最小合规视频时间线（单场景 1 秒、一个文字元素）。
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

void _writeText(Directory root, String relative, String content) {
  final File file = File('${root.path}/$relative');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(content);
}

String _leaf(FileSystemEntity entity) =>
    entity.uri.pathSegments.where((String part) => part.isNotEmpty).last;

/// 目录里所有残留临时文件（原子写 / 暂存目录失败后都必须为空）。
List<FileSystemEntity> _tempLeftovers(Directory dir) => dir
    .listSync(recursive: true)
    .where((FileSystemEntity entity) => entity.path.endsWith('.tmp'))
    .toList(growable: false);

/// 目录第一层条目名（排序后），用来断言「导入失败目录原样」。
List<String> _entries(Directory dir) => dir.existsSync()
    ? (dir.listSync().map(_leaf).toList(growable: false)..sort())
    : const <String>[];

Matcher _throwsPackFailure(String code) => throwsA(
  isA<WorkbenchPackFailure>().having(
    (WorkbenchPackFailure failure) => failure.code,
    'code',
    code,
  ),
);

Future<WorkbenchPackFailure> _packFailureOf(
  Future<Object?> Function() action,
) async {
  try {
    await action();
  } on WorkbenchPackFailure catch (error) {
    return error;
  }
  fail('期望抛出 WorkbenchPackFailure，但调用成功返回了');
}

/// 与实现相同的 IEEE CRC32（只为造「校验和正确、字段非法」的容器）。
int _testCrc32(List<int> data) {
  final List<int> table = List<int>.generate(256, (int n) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1);
    }
    return c;
  }, growable: false);
  var crc = 0xFFFFFFFF;
  for (final int byte in data) {
    crc = table[(crc ^ byte) & 0xFF] ^ (crc >> 8);
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

String _checksumOf(String payload) =>
    _testCrc32(utf8.encode(payload)).toRadixString(16).padLeft(8, '0');

/// 用给定 payload 造一个 CRC32 正确的 `nan.pack/1` 容器文本。
String _craftPack(Map<String, Object?> payload) {
  final String payloadText = jsonEncode(payload);
  return 'nan.pack/1\n$payloadText\ncrc32=${_checksumOf(payloadText)}\n';
}

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('nan_pack_io_test_');
  });

  tearDown(() {
    if (temp.existsSync()) {
      try {
        temp.deleteSync(recursive: true);
      } on FileSystemException {
        // 清理失败不影响断言结果。
      }
    }
  });

  group('容器 ⇄ 目录（通用层）', () {
    test('exportProjectPack：扩展名/目标位置/容器字段/原子写', () async {
      final Directory projectDir = Directory('${temp.path}/proj')..createSync();
      _writeText(projectDir, 'score.json', '{"score":1}');
      _writeText(projectDir, 'docs.md', '# 文档\n\n正文。\n');
      _writeText(projectDir, 'src/helper.dart', '// 源码\n');

      final File packFile = await exportProjectPack(
        kind: 'music',
        projectDir: projectDir,
        name: 'study',
        title: '   ',
        docs: '# 文档\n\n正文。\n',
        spec: <String, Object?>{'score': 1},
      );
      expect(packFile.path, '${temp.path}/study.nmu');
      expect(packFile.existsSync(), isTrue);

      final WorkbenchPack pack = await WorkbenchPack.readFrom(packFile);
      expect(pack.kind, WorkbenchPackKind.music);
      expect(pack.name, 'study');
      expect(pack.title, 'study', reason: '空白标题回退到项目名');
      expect(pack.docs, '# 文档\n\n正文。\n');
      expect(pack.spec, <String, Object?>{'score': 1});
      expect(pack.files.keys.toList(growable: false), <String>[
        'docs.md',
        'score.json',
        'src/helper.dart',
      ]);
      expect(_tempLeftovers(temp), isEmpty);

      // 再次导出：旧容器被完整替换（不是留下旧内容）。
      _writeText(projectDir, 'extra.txt', 'extra');
      final File again = await exportProjectPack(
        kind: 'music',
        projectDir: projectDir,
        name: 'study',
        title: '练习曲',
        spec: <String, Object?>{'score': 2},
      );
      final WorkbenchPack replaced = await WorkbenchPack.readFrom(again);
      expect(replaced.title, '练习曲');
      expect(replaced.files.keys, contains('extra.txt'));
      expect(replaced.spec, <String, Object?>{'score': 2});
      expect(_tempLeftovers(temp), isEmpty);
    });

    test('exportProjectPack：未知 kind / 反斜杠项目名显性失败，不写文件', () async {
      final Directory projectDir = Directory('${temp.path}/proj')..createSync();
      _writeText(projectDir, 'a.txt', 'a');

      await expectLater(
        () => exportProjectPack(
          kind: 'audio',
          projectDir: projectDir,
          name: 'study',
        ),
        _throwsPackFailure(WorkbenchPackFailureCode.unknownKind),
      );
      await expectLater(
        () => exportProjectPack(
          kind: 'music',
          projectDir: projectDir,
          name: r'bad\name',
        ),
        _throwsPackFailure(WorkbenchPackFailureCode.invalidField),
      );
      expect(_entries(temp), <String>['proj']);
    });

    test('importProjectPack：目标已存在（目录 / 文件占位）→ target_exists，旧内容原样', () async {
      final Directory projectDir = Directory('${temp.path}/proj')..createSync();
      _writeText(projectDir, 'score.json', '{"score":1}');
      final File packFile = await exportProjectPack(
        kind: 'music',
        projectDir: projectDir,
        name: 'study',
      );

      // 目标目录已存在：不覆盖、不合并、不删除其中文件。
      final Directory occupied = Directory('${temp.path}/study')..createSync();
      _writeText(occupied, 'keep.txt', 'keep');
      await expectLater(
        () => importProjectPack(packFile, projectDir: occupied),
        _throwsPackFailure(WorkbenchPackIoFailureCode.targetExists),
      );
      expect(occupied.listSync(), hasLength(1));
      expect(File('${occupied.path}/keep.txt').readAsStringSync(), 'keep');

      // 目标路径被普通文件占位：同样拒绝，占位文件不动。
      final File occupiedFile = File('${temp.path}/blocked')
        ..writeAsStringSync('keep-file');
      final File blockedPack = await exportProjectPack(
        kind: 'music',
        projectDir: projectDir,
        name: 'blocked',
      );
      await expectLater(
        () => importProjectPack(
          blockedPack,
          projectDir: Directory(occupiedFile.path),
        ),
        _throwsPackFailure(WorkbenchPackIoFailureCode.targetExists),
      );
      expect(occupiedFile.readAsStringSync(), 'keep-file');
      expect(_tempLeftovers(temp), isEmpty);
    });

    test('importProjectPack：坏包 / 版本不支持 / 错 kind / 空文件显性失败，目标不出现', () async {
      final Directory target = Directory('${temp.path}/target');

      // 不是容器。
      final File garbage = File('${temp.path}/garbage.nmu')
        ..writeAsStringSync('not a pack at all');
      await expectLater(
        () => importProjectPack(garbage, projectDir: target),
        _throwsPackFailure(WorkbenchPackFailureCode.invalidContainer),
      );
      expect(target.existsSync(), isFalse);

      // 版本不支持（拿真实容器改头部版本）。
      final File version2 = File('${temp.path}/future.nmu')
        ..writeAsStringSync(
          'nan.pack/2\n'
          '{"files":{"a.txt":"a"},"kind":"music","name":"future","title":"",'
          '"version":1}\n'
          'crc32=${_checksumOf('{"files":{"a.txt":"a"},"kind":"music",'
          '"name":"future","title":"","version":1}')}\n',
        );
      await expectLater(
        () => importProjectPack(version2, projectDir: target),
        _throwsPackFailure(WorkbenchPackFailureCode.versionUnsupported),
      );
      expect(target.existsSync(), isFalse);

      // 错 kind（容器合法，但目标存储不是这个工作台）。
      final File musicPack = File('${temp.path}/music.nmu')
        ..writeAsStringSync(
          _craftPack(<String, Object?>{
            'version': 1,
            'kind': 'music',
            'name': 'wrong',
            'title': '',
            'files': <String, Object?>{'score.json': '{}'},
          }),
        );
      final Directory wrongTarget = Directory('${temp.path}/wrong');
      await expectLater(
        () => importProjectPack(
          musicPack,
          projectDir: wrongTarget,
          expectKind: 'video3d',
        ),
        _throwsPackFailure(WorkbenchPackIoFailureCode.kindMismatch),
      );
      expect(wrongTarget.existsSync(), isFalse);

      // 空容器（没有任何文本文件）。
      final File emptyPack = File('${temp.path}/empty.nmu');
      await WorkbenchPack(
        kind: WorkbenchPackKind.music,
        name: 'empty',
        title: '',
      ).writeTo(emptyPack);
      final Directory emptyTarget = Directory('${temp.path}/empty-target');
      await expectLater(
        () => importProjectPack(emptyPack, projectDir: emptyTarget),
        _throwsPackFailure(WorkbenchPackIoFailureCode.noFiles),
      );
      expect(emptyTarget.existsSync(), isFalse);
      expect(_tempLeftovers(temp), isEmpty);
    });

    test('importProjectPack：路径冲突 / 父目录被占位显性失败，不留暂存或半成品', () async {
      // 同一容器里 `a` 与 `a/b` 无法同时成立：解码后显性拒绝，不碰磁盘。
      final File conflictPack = File('${temp.path}/conflict.nmu');
      await WorkbenchPack(
        kind: WorkbenchPackKind.music,
        name: 'conflict',
        title: '',
        files: <String, String>{'a': '1', 'a/b': '2'},
      ).writeTo(conflictPack);
      final Directory conflictTarget = Directory('${temp.path}/conflict');
      await expectLater(
        () => importProjectPack(conflictPack, projectDir: conflictTarget),
        _throwsPackFailure(WorkbenchPackFailureCode.invalidPath),
      );
      expect(conflictTarget.existsSync(), isFalse);
      expect(_tempLeftovers(temp), isEmpty);

      // 父目录被普通文件占位：文件系统失败包装成 pack_io_failed，不改占位文件。
      final File blocker = File('${temp.path}/blocker')
        ..writeAsStringSync('keep');
      final File blockedPack = File('${temp.path}/blocked.nmu');
      await WorkbenchPack(
        kind: WorkbenchPackKind.music,
        name: 'blocked',
        title: '',
        files: <String, String>{'score.json': '{}'},
      ).writeTo(blockedPack);
      final WorkbenchPackFailure failure = await _packFailureOf(
        () => importProjectPack(
          blockedPack,
          projectDir: Directory('${blocker.path}/blocked'),
        ),
      );
      expect(failure.code, WorkbenchPackFailureCode.ioFailed);
      expect(failure.message, isNotEmpty);
      expect(failure.message, contains('blocked'));
      expect(blocker.readAsStringSync(), 'keep');
      expect(_tempLeftovers(temp), isEmpty);
    });

    test('listProjectPacks：扩展名 / 隐藏 / 临时 / 目录 / 名字过滤，排序稳定', () async {
      final Directory root = Directory('${temp.path}/root')..createSync();
      _writeText(root, 'study.nmu', 'x');
      _writeText(root, 'Upper.NMU', 'x');
      _writeText(root, '.hidden.nmu', 'x');
      _writeText(root, 'study.nmu.tmp', 'x');
      _writeText(root, 'notes.txt', 'x');
      Directory('${root.path}/dir.nmu').createSync();
      _writeText(root, 'bad name.nmu', 'x');

      final RegExp accept = RegExp(r'^[A-Za-z0-9_-]{1,64}$');
      final List<File> packs = listProjectPacks(
        root,
        kind: 'music',
        accept: (String name) => accept.hasMatch(name),
      );
      expect(packs.map(_leaf), <String>['Upper.NMU', 'study.nmu']);
      expect(listProjectPacks(root, kind: 'video'), isEmpty);
      expect(
        listProjectPacks(Directory('${temp.path}/missing'), kind: 'music'),
        isEmpty,
      );
      expect(
        () => listProjectPacks(root, kind: 'audio'),
        _throwsPackFailure(WorkbenchPackFailureCode.unknownKind),
      );
    });
  });

  group('音乐项目存储', () {
    test('exportPack → importPack 往返：read 一致，.nmu 与 docs 保留', () async {
      final Directory rootA = Directory('${temp.path}/music-a')..createSync();
      final MusicProjectStore storeA = MusicProjectStore(root: rootA);
      await storeA.save('study', _musicScore());
      _writeText(
        Directory('${rootA.path}/study'),
        'docs.md',
        '# 练琴笔记\n\n第一小节。\n',
      );

      final File packFile = await storeA.exportPack('study');
      expect(packFile.path, endsWith('.nmu'));
      expect(packFile.parent.path, rootA.path);
      final WorkbenchPack pack = await WorkbenchPack.readFrom(packFile);
      expect(pack.kind, WorkbenchPackKind.music);
      expect(pack.docs, '# 练琴笔记\n\n第一小节。\n');
      expect(pack.spec, equals((await storeA.read('study')).raw));

      expect((await storeA.listPacks()).map(_leaf), <String>['study.nmu']);

      final Directory rootB = Directory('${temp.path}/music-b');
      final MusicProjectStore storeB = MusicProjectStore(root: rootB);
      await storeB.importPack(packFile);

      final MusicProjectSnapshot imported = await storeB.read('study');
      final MusicProjectSnapshot original = await storeA.read('study');
      expect(imported.raw, equals(original.raw));
      expect(imported.score.title, '练习曲');
      expect(imported.validation.verified, isTrue);
      expect(
        File('${imported.dir}/docs.md').readAsStringSync(),
        '# 练琴笔记\n\n第一小节。\n',
      );
      expect(_tempLeftovers(temp), isEmpty);
    });

    test('importPack：目标已存在拒绝覆盖；坏包 / 版本 / 错 kind 显性失败', () async {
      final Directory rootA = Directory('${temp.path}/music-a')..createSync();
      final MusicProjectStore storeA = MusicProjectStore(root: rootA);
      await storeA.save('study', _musicScore());
      final File packFile = await storeA.exportPack('study');

      // 目标已存在：既有项目字节不变，不覆盖不合并。
      final Directory rootB = Directory('${temp.path}/music-b')..createSync();
      final MusicProjectStore storeB = MusicProjectStore(root: rootB);
      await storeB.save('study', _musicScore(title: '另一个版本'));
      final String before = File('${rootB.path}/study/score.json')
          .readAsStringSync();
      await expectLater(
        () => storeB.importPack(packFile),
        _throwsPackFailure(WorkbenchPackIoFailureCode.targetExists),
      );
      expect(
        File('${rootB.path}/study/score.json').readAsStringSync(),
        before,
        reason: '已存在的项目一个字节都不改',
      );

      // 坏包。
      final File garbage = File('${temp.path}/garbage.nmu')
        ..writeAsStringSync('garbage');
      await expectLater(
        () => storeB.importPack(garbage),
        _throwsPackFailure(WorkbenchPackFailureCode.invalidContainer),
      );
      // 版本不支持。
      final File futurePack = File('${temp.path}/future.nmu')
        ..writeAsStringSync(
          packFile.readAsStringSync().replaceFirst('nan.pack/1', 'nan.pack/2'),
        );
      await expectLater(
        () => storeB.importPack(futurePack),
        _throwsPackFailure(WorkbenchPackFailureCode.versionUnsupported),
      );
      // 错 kind：3D 视频包不能导进音乐库。
      final Directory videoRoot = Directory('${temp.path}/video-a');
      final Video3dProjectStore videoStore = Video3dProjectStore(
        root: videoRoot,
      );
      await videoStore.save(
        'demo',
        scene: _validScene(),
        screenplay: _validScreenplay(),
      );
      final File videoPack = await videoStore.exportPack('demo');
      final Directory rootC = Directory('${temp.path}/music-c')..createSync();
      final MusicProjectStore storeC = MusicProjectStore(root: rootC);
      await expectLater(
        () => storeC.importPack(videoPack),
        _throwsPackFailure(WorkbenchPackIoFailureCode.kindMismatch),
      );
      expect(_entries(rootC), isEmpty);
      expect(_tempLeftovers(temp), isEmpty);
    });

    test('importPack：包内 name 不合白名单 → invalid_name，且不建目标目录', () async {
      final File badNamePack = File('${temp.path}/bad-name.nmu');
      await WorkbenchPack(
        kind: WorkbenchPackKind.music,
        name: 'bad name',
        title: '',
        files: <String, String>{'score.json': '{}'},
      ).writeTo(badNamePack);
      final Directory root = Directory('${temp.path}/music-root');
      final MusicProjectStore store = MusicProjectStore(root: root);
      await expectLater(
        () => store.importPack(badNamePack),
        throwsA(
          isA<MusicProjectFailure>().having(
            (MusicProjectFailure failure) => failure.code,
            'code',
            'invalid_name',
          ),
        ),
      );
      expect(_entries(root), isEmpty);
    });
  });

  group('3D 视频项目存储', () {
    test(
      'exportPack → importPack 往返：scene / screenplay 原文与校验一致，.n3v',
      () async {
        final Directory rootA = Directory('${temp.path}/v3d-a')..createSync();
        final Video3dProjectStore storeA = Video3dProjectStore(root: rootA);
        final saved = await storeA.save(
          'demo',
          scene: _validScene(),
          screenplay: _validScreenplay(),
        );
        expect(saved.verified, isTrue);
        _writeText(Directory('${rootA.path}/demo'), 'docs.md', '# 分镜说明\n');

        final File packFile = await storeA.exportPack('demo');
        expect(packFile.path, endsWith('.n3v'));
        final WorkbenchPack pack = await WorkbenchPack.readFrom(packFile);
        expect(pack.kind, WorkbenchPackKind.video3d);
        expect(
          pack.files.keys,
          containsAll(<String>[
            Video3dProjectStore.sceneFile,
            Video3dProjectStore.screenplayFile,
          ]),
        );
        expect((await storeA.listPacks()).map(_leaf), <String>['demo.n3v']);

        final Directory rootB = Directory('${temp.path}/v3d-b');
        final Video3dProjectStore storeB = Video3dProjectStore(root: rootB);
        await storeB.importPack(packFile);

        final Video3dProjectSnapshot imported = await storeB.read('demo');
        final Video3dProjectSnapshot original = await storeA.read('demo');
        expect(imported.sceneRaw, equals(original.sceneRaw));
        expect(imported.screenplayRaw, equals(original.screenplayRaw));
        expect(imported.verified, isTrue);
        expect(File('${imported.dir}/docs.md').readAsStringSync(), '# 分镜说明\n');
        expect(_tempLeftovers(temp), isEmpty);
      },
    );

    test('importPack：目标已存在拒绝覆盖；坏包 / 错 kind 显性失败', () async {
      final Directory rootA = Directory('${temp.path}/v3d-a')..createSync();
      final Video3dProjectStore storeA = Video3dProjectStore(root: rootA);
      await storeA.save(
        'demo',
        scene: _validScene(),
        screenplay: _validScreenplay(),
      );
      final File packFile = await storeA.exportPack('demo');

      final Directory rootB = Directory('${temp.path}/v3d-b')..createSync();
      final Video3dProjectStore storeB = Video3dProjectStore(root: rootB);
      await storeB.save(
        'demo',
        scene: _validScene(floorColor: '#123456'),
        screenplay: _validScreenplay(),
      );
      final String sceneBefore = File('${rootB.path}/demo/scene3d.json')
          .readAsStringSync();
      await expectLater(
        () => storeB.importPack(packFile),
        _throwsPackFailure(WorkbenchPackIoFailureCode.targetExists),
      );
      expect(
        File('${rootB.path}/demo/scene3d.json').readAsStringSync(),
        sceneBefore,
      );

      final File garbage = File('${temp.path}/garbage.n3v')
        ..writeAsStringSync('garbage');
      await expectLater(
        () => storeB.importPack(garbage),
        _throwsPackFailure(WorkbenchPackFailureCode.invalidContainer),
      );

      // 错 kind：音乐包不能导进 3D 视频库。
      final File musicPack = File('${temp.path}/music.nmu');
      await WorkbenchPack(
        kind: WorkbenchPackKind.music,
        name: 'study',
        title: '',
        files: <String, String>{'score.json': '{}'},
      ).writeTo(musicPack);
      await expectLater(
        () => storeB.importPack(musicPack),
        _throwsPackFailure(WorkbenchPackIoFailureCode.kindMismatch),
      );
      expect(_tempLeftovers(temp), isEmpty);
    });
  });

  group('视频项目存储', () {
    test('exportPack → importPack 往返：timeline / spec / 片长一致，.nvdo', () async {
      final Directory rootA = Directory('${temp.path}/video-a')..createSync();
      final VideoProjectStore storeA = VideoProjectStore(root: rootA);
      await storeA.create(
        name: 'clip',
        timeline: _timeline(),
        spec: _scienceSpec(),
        title: '测试视频',
      );
      _writeText(Directory('${rootA.path}/clip'), 'docs.md', '# 视频脚本\n');

      final File packFile = await storeA.exportPack('clip');
      expect(packFile.path, endsWith('.nvdo'));
      final WorkbenchPack pack = await WorkbenchPack.readFrom(packFile);
      expect(pack.kind, WorkbenchPackKind.video);
      expect(
        pack.files.keys,
        containsAll(<String>['timeline.json', 'spec.json', 'video.json']),
      );
      expect((await storeA.listPacks()).map(_leaf), <String>['clip.nvdo']);

      final Directory rootB = Directory('${temp.path}/video-b');
      final VideoProjectStore storeB = VideoProjectStore(root: rootB);
      await storeB.importPack(packFile);

      final VideoProjectSnapshot imported = await storeB.read('clip');
      final VideoProjectSnapshot original = await storeA.read('clip');
      expect(imported.timeline, equals(original.timeline));
      expect(imported.spec, equals(original.spec));
      expect(imported.title, '测试视频');
      expect(imported.document.totalSeconds, original.document.totalSeconds);
      expect(imported.document.frameCount(), original.document.frameCount());
      expect(File('${imported.dir}/docs.md').readAsStringSync(), '# 视频脚本\n');
      expect(_tempLeftovers(temp), isEmpty);
    });

    test('importPack：目标已存在拒绝覆盖；错 kind / 坏包显性失败', () async {
      final Directory rootA = Directory('${temp.path}/video-a')..createSync();
      final VideoProjectStore storeA = VideoProjectStore(root: rootA);
      await storeA.create(
        name: 'clip',
        timeline: _timeline(),
        spec: _scienceSpec(),
        title: '第一版',
      );
      final File packFile = await storeA.exportPack('clip');

      final Directory rootB = Directory('${temp.path}/video-b')..createSync();
      final VideoProjectStore storeB = VideoProjectStore(root: rootB);
      await storeB.create(
        name: 'clip',
        timeline: _timeline(),
        spec: _scienceSpec(subject: '另一个主题'),
        title: '第二版',
      );
      final String specBefore = File('${rootB.path}/clip/spec.json')
          .readAsStringSync();
      await expectLater(
        () => storeB.importPack(packFile),
        _throwsPackFailure(WorkbenchPackIoFailureCode.targetExists),
      );
      expect(
        File('${rootB.path}/clip/spec.json').readAsStringSync(),
        specBefore,
      );

      final File garbage = File('${temp.path}/garbage.nvdo')
        ..writeAsStringSync('garbage');
      await expectLater(
        () => storeB.importPack(garbage),
        _throwsPackFailure(WorkbenchPackFailureCode.invalidContainer),
      );

      // 错 kind：3D 视频包不能导进视频库。
      final Directory v3dRoot = Directory('${temp.path}/v3d-c');
      final Video3dProjectStore v3dStore = Video3dProjectStore(root: v3dRoot);
      await v3dStore.save(
        'demo',
        scene: _validScene(),
        screenplay: _validScreenplay(),
      );
      final File v3dPack = await v3dStore.exportPack('demo');
      await expectLater(
        () => storeB.importPack(v3dPack),
        _throwsPackFailure(WorkbenchPackIoFailureCode.kindMismatch),
      );
      expect(_tempLeftovers(temp), isEmpty);
    });
  });

  group('三个存储的 listPacks', () {
    test('只列各自扩展名的打包文件，项目目录与临时文件不算包', () async {
      final Directory shared = Directory('${temp.path}/shared')..createSync();

      final MusicProjectStore music = MusicProjectStore(root: shared);
      await music.save('study', _musicScore());
      await music.exportPack('study');

      final Video3dProjectStore video3d = Video3dProjectStore(root: shared);
      await video3d.save(
        'demo',
        scene: _validScene(),
        screenplay: _validScreenplay(),
      );
      await video3d.exportPack('demo');

      final VideoProjectStore video = VideoProjectStore(root: shared);
      await video.create(
        name: 'clip',
        timeline: _timeline(),
        spec: _scienceSpec(),
      );
      await video.exportPack('clip');

      _writeText(shared, 'notes.txt', 'x');
      _writeText(shared, 'staged.nmu.part', 'x');

      expect((await music.listPacks()).map(_leaf), <String>['study.nmu']);
      expect((await video3d.listPacks()).map(_leaf), <String>['demo.n3v']);
      expect((await video.listPacks()).map(_leaf), <String>['clip.nvdo']);
      expect(_tempLeftovers(temp), isEmpty);
    });
  });
}
