import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nondesign/core/creative/creative_plan.dart';
import 'package:nondesign/core/creative/creative_schema.dart';
import 'package:nondesign/core/creative/creative_spec.dart';
import 'package:nondesign/core/three_service.dart';

import 'helpers/creative_fixtures.dart';

ThreeService _service(Directory root) => ThreeService(
  root: root,
  llm: (_) async => '{}',
  assets: (_) async => Uint8List(0),
);

CreativeSpec _spec() =>
    CreativeSpec.parse(creativeFixture('spec_3d_ok.json')).value!;

CreativePlan3d _scenePlan() =>
    CreativePlan.parse(<String, dynamic>{
          'schema': creativePlanSchema,
          'kind': '3d',
          'track': 'scene',
          'language': 'scene_threejs',
          'summary': '一个房间',
          'acceptance': <String>['地面平整 ≤1mm', '相机可见'],
          'parts': <Object?>[
            <String, Object?>{
              'id': 'table',
              'dims_m': <double>[1.2, 0.75, 0.8],
              'material': 'oak',
              'bbox_center_m': <double>[0, 0.375, 0],
            },
          ],
          'zones': <Object?>[
            <String, Object?>{
              'id': 'main',
              'bounds_m': <double>[10, 3, 10],
            },
          ],
          'placements': <Object?>[
            <String, Object?>{
              'id': 'table_spot',
              'zone': 'main',
              'at_m': <double>[0, 0, 0],
            },
          ],
          'cameras': <Object?>[
            <String, Object?>{
              'id': 'hero',
              'at_m': <double>[4, 2, 4],
              'look_at_m': <double>[0, 1, 0],
            },
          ],
        }).value!
        as CreativePlan3d;

Map<String, Object?> _scene() => <String, Object?>{
  'v': 1,
  'nodes': <Object?>[
    <String, Object?>{
      'id': 'floor',
      'type': 'box',
      'size': <double>[10, 0.1, 10],
      'position': <double>[0, -0.05, 0],
      'color': '#9a8c7a',
    },
    <String, Object?>{
      'id': 'table',
      'type': 'box',
      'size': <double>[1.2, 0.75, 0.8],
      'position': <double>[0, 0.375, 0],
      'color': '#c9a06a',
      'parent': 'floor',
    },
  ],
  'camera': <String, Object?>{
    'position': <double>[4, 2, 4],
    'target': <double>[0, 1, 0],
  },
};

void main() {
  late Directory temp;
  late ThreeService service;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('nondesign-3dbuild-');
    service = _service(temp);
  });

  tearDown(() async {
    await temp.delete(recursive: true);
  });

  test(
    'scene 模式：plan 校验后 scene.json 确定性编译成 src/scene.js + build.json',
    () async {
      final store = service.workspaceStore;
      Directory('${temp.path}/room').createSync(recursive: true);
      await store.writeSpec('room', _spec());
      await store.writePlan('room', _scenePlan());
      await store.writeScene('room', _scene());

      final build = await service.workspaceBuild('room');
      expect(build['ok'], isTrue, reason: '$build');
      expect(build['mode'], 'scene');
      expect(build['source'], 'src/scene.js');
      final jsFile = File('${temp.path}/room/src/scene.js');
      expect(jsFile.existsSync(), isTrue);
      final first = jsFile.readAsBytesSync();
      final js = utf8.decode(first);
      expect(js, contains('mesh.name = node.id;'));
      expect(js, contains("parent: 'floor'"));
      expect(js, contains('camera.position.set(4, 2, 4);'));
      expect(
        File('${temp.path}/room/artifacts/build.json').existsSync(),
        isTrue,
      );
      final manifest = jsonDecode(
        File('${temp.path}/room/artifacts/build.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      expect(manifest['status'], 'built');
      expect(manifest['scene_nodes'], 2);

      // 同输入 → 同字节。
      final again = await service.workspaceBuild('room');
      expect(again['ok'], isTrue);
      expect(jsFile.readAsBytesSync(), first);
    },
  );

  test('scene.json 不合法 → three_scene_invalid（不写半成品 src）', () async {
    final store = service.workspaceStore;
    Directory('${temp.path}/bad').createSync(recursive: true);
    await store.writeSpec('bad', _spec());
    await store.writePlan('bad', _scenePlan());
    await store.writeScene('bad', <String, Object?>{
      'v': 1,
      'nodes': <Object?>[
        <String, Object?>{
          'id': 'dup',
          'type': 'box',
          'size': <double>[1, 1, 1],
        },
        <String, Object?>{
          'id': 'dup',
          'type': 'torus',
          'size': <double>[1, 1, 1],
        },
      ],
    });
    final build = await service.workspaceBuild('bad');
    expect(build['ok'], isFalse);
    expect(build['error'], 'three_scene_invalid');
    expect(File('${temp.path}/bad/src/scene.js').existsSync(), isFalse);
  });

  test('code 模式：src 存在才构建；缺 plan/src 显性失败', () async {
    final store = service.workspaceStore;
    final chairPlan =
        CreativePlan.parse(creativeFixture('plan_3d_chair.json')).value!
            as CreativePlan3d;
    Directory('${temp.path}/code').createSync(recursive: true);
    await store.writeSpec('code', _spec());
    await store.writePlan('code', chairPlan);
    final missingCode = await service.workspaceBuild('code');
    expect(missingCode['ok'], isFalse);
    expect(missingCode['error'], 'three_code_missing');

    await store.writeSource(
      'code',
      'parts/seat.js',
      'export const seat = {};\n',
    );
    final build = await service.workspaceBuild('code');
    expect(build['ok'], isTrue, reason: '$build');
    expect(build['mode'], 'code');
    expect(build['source_files'], <String>['parts/seat.js']);

    Directory('${temp.path}/noplan').createSync(recursive: true);
    await store.writeSpec('noplan', _spec());
    final noPlan = await service.workspaceBuild('noplan');
    expect(noPlan['ok'], isFalse);
    expect(noPlan['error'], 'three_plan_missing');
  });

  test(
    'workspaceCheckPlacement：自动读 measurement + 落 placement-gates.json',
    () async {
      final store = service.workspaceStore;
      Directory('${temp.path}/scene').createSync(recursive: true);
      await store.writeSpec('scene', _spec());
      await store.writePlan('scene', _scenePlan());
      await store.writeScene('scene', _scene());
      await store.writeArtifact('scene', 'measurement.json', <String, Object?>{
        'path': 'legacy',
        'parts': <Object?>[
          <String, Object?>{
            'id': 'floor',
            'bbox': <String, Object?>{
              'min': <double>[-5, 0, -5],
              'max': <double>[5, 0.1, 5],
            },
            'triangles': 12,
          },
          <String, Object?>{
            'id': 'table',
            'bbox': <String, Object?>{
              'min': <double>[-0.6, 0.1, -0.4],
              'max': <double>[0.6, 0.85, 0.4],
            },
            'triangles': 600,
          },
          <String, Object?>{
            'id': 'lamp',
            'bbox': <String, Object?>{
              'min': <double>[-0.06, 1.6, -0.06],
              'max': <double>[0.06, 1.72, 0.06],
            },
            'triangles': 96,
          },
        ],
        'draw_calls': 1200,
      });
      final check = await service.workspaceCheckPlacement('scene');
      expect(check['ok'], isTrue, reason: '$check');
      expect(check['verdict'], 'ERROR');
      expect((check['caps'] as Map)['floating'], 0.6);
      expect(
        File('${temp.path}/scene/artifacts/placement-gates.json').existsSync(),
        isTrue,
      );

      // 对象轨项目不能跑摆放门。
      final chairPlan =
          CreativePlan.parse(creativeFixture('plan_3d_chair.json')).value!
              as CreativePlan3d;
      Directory('${temp.path}/object').createSync(recursive: true);
      await store.writeSpec('object', _spec());
      await store.writePlan('object', chairPlan);
      final wrongTrack = await service.workspaceCheckPlacement('object');
      expect(wrongTrack['ok'], isFalse);
      expect(wrongTrack['error'], 'three_track_not_scene');
    },
  );

  test('没有迁移的旧项目 → three_no_legacy', () async {
    Directory('${temp.path}/legacy').createSync(recursive: true);
    File('${temp.path}/legacy/three-spec.json').writeAsStringSync('{}');
    final build = await service.workspaceBuild('legacy');
    expect(build['ok'], isFalse);
    expect(build['error'], 'three_no_legacy');
  });
}
