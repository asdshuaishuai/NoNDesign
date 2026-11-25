import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nondesign/core/video3d/video3d_project.dart';

// ---------------------------------------------------------------------------
// Fixtures：契约层合法输入（校验器语义在 video3d_contract_test 覆盖；
// 这里只用来验证项目存储的落盘/读取/失败路径）。
// ---------------------------------------------------------------------------

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
      <String, Object?>{'type': 'ambient', 'intensity': 0.2},
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

String _prettyJson(Object? value) =>
    '${const JsonEncoder.withIndent('  ').convert(value)}\n';

void _writeJsonFile(String path, Object? value) {
  final File file = File(path);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(_prettyJson(value));
}

void main() {
  late Directory temp;
  late Video3dProjectStore store;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('nondesign-video3d-project-');
    store = Video3dProjectStore(root: temp);
  });

  tearDown(() async {
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  group('save → list / read', () {
    test('合法项目落两份事实源，列表与读取元数据一致', () async {
      final Map<String, Object?> scene = _validScene();
      final Map<String, Object?> screenplay = _validScreenplay();
      final verification = await store.save(
        'demo',
        scene: scene,
        screenplay: screenplay,
      );
      expect(verification.verified, isTrue);
      expect(verification.checks, isEmpty);
      expect(verification.scene, isNotNull);
      expect(verification.screenplay, isNotNull);
      expect(verification.toJson(), <String, Object?>{
        'verified': true,
        'checks': <Object?>[],
      });

      expect(File('${temp.path}/demo/scene3d.json').existsSync(), isTrue);
      expect(File('${temp.path}/demo/screenplay3d.json').existsSync(), isTrue);
      expect(
        File('${temp.path}/demo/scene3d.json').readAsStringSync(),
        _prettyJson(scene),
        reason: '落盘 JSON 稳定（两空格缩进 + 末尾换行）',
      );

      final entries = await store.list();
      expect(entries, hasLength(1));
      final entry = entries.single;
      expect(entry.name, 'demo');
      expect(entry.nodes, 3);
      expect(entry.shots, 2);
      expect(entry.durationSeconds, 8.0);
      expect(entry.totalFrames, 240, reason: '8 秒 × 30fps = 240 帧');
      expect(entry.verified, isTrue);
      expect(entry.corrupt, isFalse);

      final snapshot = await store.read('demo');
      expect(snapshot.name, 'demo');
      expect(snapshot.dir, '${temp.path}/demo');
      expect(snapshot.sceneRaw, scene);
      expect(snapshot.screenplayRaw, screenplay);
      expect(snapshot.verified, isTrue);
      expect(snapshot.scene!.nodes.map((node) => node.id), <String>[
        'floor',
        'table',
        'lamp',
      ]);
      expect(snapshot.screenplay!.shots.map((shot) => shot.id), <String>[
        's1',
        's2',
      ]);
    });

    test('重复保存同一输入得到相同事实源字节；未知字段原样保留', () async {
      final Map<String, Object?> scene = _validScene();
      scene['title'] = '保留的未知字段';
      final Map<String, Object?> screenplay = _validScreenplay();
      screenplay['notes'] = <Object?>['a', 1, true];

      await store.save('demo', scene: scene, screenplay: screenplay);
      await store.save('demo', scene: scene, screenplay: screenplay);
      expect(
        File('${temp.path}/demo/scene3d.json').readAsStringSync(),
        _prettyJson(scene),
      );
      expect(
        File('${temp.path}/demo/screenplay3d.json').readAsStringSync(),
        _prettyJson(screenplay),
      );
    });

    test('保存只替换事实源，不静默删项目里其它文件（artifacts 保留）', () async {
      await store.save(
        'demo',
        scene: _validScene(),
        screenplay: _validScreenplay(),
      );
      final File artifact = File('${temp.path}/demo/artifacts/frames.txt');
      artifact.parent.createSync(recursive: true);
      artifact.writeAsStringSync('derived');

      await store.save(
        'demo',
        scene: _validScene(floorColor: '#123456'),
        screenplay: _validScreenplay(),
      );
      expect(artifact.existsSync(), isTrue);
      expect(artifact.readAsStringSync(), 'derived');
      expect(
        jsonDecode(File('${temp.path}/demo/scene3d.json').readAsStringSync()),
        _validScene(floorColor: '#123456'),
      );
      // 临时文件已清理（不以 .tmp 结尾的残留）。
      expect(
        Directory('${temp.path}/demo')
            .listSync()
            .where((entity) => entity.path.endsWith('.tmp')),
        isEmpty,
      );
    });
  });

  group('坏输入不落半成品', () {
    test('新项目的校验失败：返回 checks，不创建项目目录、不写文件', () async {
      final verification = await store.save(
        'fresh',
        scene: _validScene(floorColor: 'red'), // 非法颜色
        screenplay: _validScreenplay(),
      );
      expect(verification.verified, isFalse);
      expect(verification.checks, isNotEmpty);
      final Map<String, Object?> envelope = verification.toJson();
      expect(envelope['verified'], isFalse);
      expect(envelope['checks'], isA<List<Object?>>());
      final firstCheck = (envelope['checks']! as List<Object?>).first! as Map;
      expect(firstCheck['pointer'], '/nodes/0/material/color');
      expect(firstCheck['code'], 'video3d_scene_color_invalid');
      expect(firstCheck['message'], isA<String>());

      expect(Directory('${temp.path}/fresh').existsSync(), isFalse);
      expect(await store.list(), isEmpty);
    });

    test('已有项目的校验失败：旧事实源字节不变、不出现临时文件', () async {
      await store.save(
        'demo',
        scene: _validScene(),
        screenplay: _validScreenplay(),
      );
      final String sceneBefore = File('${temp.path}/demo/scene3d.json')
          .readAsStringSync();
      final String screenplayBefore = File(
        '${temp.path}/demo/screenplay3d.json',
      ).readAsStringSync();

      // 跨文档错误：镜头引用了不存在的相机。
      final Map<String, Object?> badScreenplay = _validScreenplay();
      final List<Object?> shots = badScreenplay['shots']! as List<Object?>;
      final Map<String, Object?> firstShot = Map<String, Object?>.from(
        shots.first! as Map,
      );
      firstShot['camera'] = <String, Object?>{'id': 'ghost'};
      badScreenplay['shots'] = <Object?>[firstShot, shots[1]];

      final verification = await store.save(
        'demo',
        scene: _validScene(),
        screenplay: badScreenplay,
      );
      expect(verification.verified, isFalse);
      expect(
        verification.checks.map((check) => check.code),
        contains('video3d_screenplay_camera_missing'),
      );

      expect(
        File('${temp.path}/demo/scene3d.json').readAsStringSync(),
        sceneBefore,
      );
      expect(
        File('${temp.path}/demo/screenplay3d.json').readAsStringSync(),
        screenplayBefore,
      );
      expect(
        Directory('${temp.path}/demo')
            .listSync()
            .where((entity) => entity.path.endsWith('.tmp')),
        isEmpty,
      );
    });
  });

  group('坏项目隔离（list / read）', () {
    test('坏 JSON / 缺文件标 corrupt，不影响合法行，也不炸列表', () async {
      await store.save(
        'good',
        scene: _validScene(),
        screenplay: _validScreenplay(),
      );

      final Directory broken = Directory('${temp.path}/broken')
        ..createSync(recursive: true);
      File('${broken.path}/scene3d.json').writeAsStringSync('{not json');
      _writeJsonFile('${broken.path}/screenplay3d.json', _validScreenplay());

      final Directory missing = Directory('${temp.path}/missing')
        ..createSync(recursive: true);
      _writeJsonFile('${missing.path}/scene3d.json', _validScene());
      // screenplay3d.json 缺失。

      final Directory invalid = Directory('${temp.path}/invalid')
        ..createSync(recursive: true);
      _writeJsonFile('${invalid.path}/scene3d.json', <String, Object?>{'v': 1});
      _writeJsonFile('${invalid.path}/screenplay3d.json', _validScreenplay());

      // 非项目目录：隐藏目录、非法名、普通文件都被跳过。
      Directory('${temp.path}/.staging').createSync(recursive: true);
      Directory('${temp.path}/bad name').createSync(recursive: true);
      File('${temp.path}/notes.txt').writeAsStringSync('not a project');

      final entries = await store.list();
      expect(entries.map((entry) => entry.name), <String>[
        'broken',
        'good',
        'invalid',
        'missing',
      ]);
      final Map<String, Video3dProjectEntry> byName =
          <String, Video3dProjectEntry>{
            for (final entry in entries) entry.name: entry,
          };
      expect(byName['good']!.verified, isTrue);
      expect(byName['good']!.corrupt, isFalse);
      expect(byName['broken']!.corrupt, isTrue);
      expect(byName['missing']!.corrupt, isTrue);
      expect(byName['invalid']!.corrupt, isFalse, reason: '能读但契约不合格');
      expect(byName['invalid']!.verified, isFalse);
      expect(byName['invalid']!.nodes, 0, reason: '场景不合格 → 场景模型为 null');
      expect(
        byName['invalid']!.shots,
        2,
        reason: '镜头文件本身可读 → 元数据如实上报（verified=false 仍保留这一行）',
      );
    });

    test('read：坏 JSON / 缺文件 → corrupt；能读但契约不合格 → verified=false', () async {
      final Directory broken = Directory('${temp.path}/broken')
        ..createSync(recursive: true);
      File('${broken.path}/scene3d.json').writeAsStringSync('{not json');
      _writeJsonFile('${broken.path}/screenplay3d.json', _validScreenplay());
      await expectLater(
        () => store.read('broken'),
        throwsA(
          isA<Video3dProjectFailure>().having(
            (failure) => failure.code,
            'code',
            'corrupt',
          ),
        ),
      );

      final Directory missing = Directory('${temp.path}/missing')
        ..createSync(recursive: true);
      _writeJsonFile('${missing.path}/scene3d.json', _validScene());
      await expectLater(
        () => store.read('missing'),
        throwsA(
          isA<Video3dProjectFailure>().having(
            (failure) => failure.code,
            'code',
            'corrupt',
          ),
        ),
      );

      _writeJsonFile('${temp.path}/invalid/scene3d.json', <String, Object?>{
        'v': 1,
        'nodes': <Object?>[
          <String, Object?>{
            'id': 'x',
            'type': 'octahedron',
            'size': <int>[1, 1, 1],
          },
        ],
      });
      _writeJsonFile(
        '${temp.path}/invalid/screenplay3d.json',
        _validScreenplay(),
      );
      final snapshot = await store.read('invalid');
      expect(snapshot.verified, isFalse);
      expect(snapshot.scene, isNull, reason: '场景文档不合格 → 不可编译进预览');
      // 两份文档独立解析：场景坏了不代表镜头表不可读（读取如实返回）。
      expect(snapshot.screenplay, isNotNull);
      expect(snapshot.screenplay!.shots, hasLength(2));
      expect(snapshot.sceneRaw['v'], 1);
      expect(
        snapshot.verification.checks.map((check) => check.code),
        contains('video3d_scene_geometry_unsupported'),
      );
    });
  });

  group('名称白名单与路径逃逸', () {
    test('非法项目名一律 invalid_name，且不创建任何目录', () async {
      final List<String> badNames = <String>[
        '',
        '..',
        '../escape',
        'a/b',
        r'a\b',
        '.hidden',
        'bad name',
        '中文名',
        'a' * 65,
        'x/../y',
      ];
      for (final String name in badNames) {
        await expectLater(
          () => store.read(name),
          throwsA(
            isA<Video3dProjectFailure>().having(
              (failure) => failure.code,
              'code',
              'invalid_name',
            ),
          ),
          reason: 'read($name) 必须拒绝',
        );
        await expectLater(
          () => store.save(
            name,
            scene: _validScene(),
            screenplay: _validScreenplay(),
          ),
          throwsA(
            isA<Video3dProjectFailure>().having(
              (failure) => failure.code,
              'code',
              'invalid_name',
            ),
          ),
          reason: 'save($name) 必须拒绝',
        );
        await expectLater(
          () => store.delete(name),
          throwsA(
            isA<Video3dProjectFailure>().having(
              (failure) => failure.code,
              'code',
              'invalid_name',
            ),
          ),
          reason: 'delete($name) 必须拒绝',
        );
      }
      // 合法字符组合仍可用。
      final verification = await store.save(
        'ok-Name_1',
        scene: _validScene(),
        screenplay: _validScreenplay(),
      );
      expect(verification.verified, isTrue);
      expect(Directory('${temp.path}/ok-Name_1').existsSync(), isTrue);
    });

    test('符号链接项目目录被拒绝（路径逃逸），列表跳过', () async {
      final Directory outside = Directory(
        '${temp.path}_outside_${DateTime.now().microsecondsSinceEpoch}',
      )..createSync(recursive: true);
      try {
        Link('${temp.path}/leak').createSync(outside.path);
      } catch (_) {
        // 某些平台（Windows 非管理员）不允许创建符号链接：跳过该断言。
        outside.deleteSync(recursive: true);
        return;
      }
      try {
        await expectLater(
          () => store.read('leak'),
          throwsA(
            isA<Video3dProjectFailure>().having(
              (failure) => failure.code,
              'code',
              'path_escape',
            ),
          ),
        );
        final entries = await store.list();
        expect(entries.map((entry) => entry.name), isNot(contains('leak')));
      } finally {
        outside.deleteSync(recursive: true);
      }
    });
  });

  group('delete 与错误映射', () {
    test('delete 移除项目；缺失项目删除失败；失败码映射人话', () async {
      await store.save(
        'demo',
        scene: _validScene(),
        screenplay: _validScreenplay(),
      );
      await store.delete('demo');
      expect(Directory('${temp.path}/demo').existsSync(), isFalse);
      await expectLater(
        () => store.delete('demo'),
        throwsA(
          isA<Video3dProjectFailure>().having(
            (failure) => failure.code,
            'code',
            'no_project',
          ),
        ),
      );

      const failure = Video3dProjectFailure('corrupt', 'raw diagnostic');
      expect(failure.technical, 'corrupt: raw diagnostic');
      expect(failure.message, '这个 3D 视频项目的场景或镜头文件不完整，可能被手动改坏了');
      expect(video3dProjectFailureMessage(failure), failure.message);
      expect(video3dProjectFailureMessage('unknown_code'), isNotEmpty);
    });

    test('read 不存在的项目 → no_project', () async {
      await expectLater(
        () => store.read('ghost'),
        throwsA(
          isA<Video3dProjectFailure>().having(
            (failure) => failure.code,
            'code',
            'no_project',
          ),
        ),
      );
    });
  });
}
