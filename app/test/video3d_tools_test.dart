// 3D 视频的工具面（LocalWorkspaceServices.video3dCreate / Status / List）。
//
// 覆盖四组行为：
//  1. 合法输入：先校验后落盘，返回节点/镜头/片长/整数帧；
//  2. 同名已存在：拒绝覆盖，磁盘逐字节不变；
//  3. 未通过校验：不落盘（项目目录都不出现），如实回问题清单；
//  4. 非法名 / 查看 / 列表：失败码与读取路径都可复现。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:nondesign/core/dart_agent.dart';
import 'package:nondesign/core/video3d/video3d_project.dart';

// ---------------------------------------------------------------------------
// Fixtures：契约层合法输入（契约语义在 video3d_contract_test 覆盖，这里只验证
// 工具面的落盘/拒绝/读取路径）。
// ---------------------------------------------------------------------------

Map<String, dynamic> _scene() => <String, dynamic>{
  'v': 1,
  'units': 'm',
  'environment': <String, dynamic>{'background': '#0b0d12'},
  'nodes': <dynamic>[
    <String, dynamic>{
      'id': 'floor',
      'type': 'box',
      'size': <double>[10, 0.1, 10],
      'position': <double>[0, -0.05, 0],
      'rotation': <double>[0, 0, 0],
      'scale': <double>[1, 1, 1],
      'material': <String, dynamic>{
        'color': '#9a8c7a',
        'roughness': 0.9,
        'metalness': 0.0,
      },
      'parent': null,
    },
    <String, dynamic>{
      'id': 'table',
      'type': 'plane',
      'size': <double>[2, 1, 0],
      'position': <double>[0, 0.5, 0],
      'parent': 'floor',
    },
  ],
  'lights': <dynamic>[
    <String, dynamic>{
      'id': 'key',
      'type': 'directional',
      'intensity': 1.0,
      'color': '#ffffff',
      'position': <double>[4, 6, 4],
      'target': <double>[0, 0, 0],
    },
  ],
  'cameras': <dynamic>[
    <String, dynamic>{
      'id': 'hero',
      'position': <double>[4, 2, 4],
      'target': <double>[0, 1, 0],
      'fov': 45,
    },
  ],
};

Map<String, dynamic> _screenplay() => <String, dynamic>{
  'v': 1,
  'fps': 30,
  'format': <String, dynamic>{'width': 720, 'height': 1280},
  'seed': 0,
  'shots': <dynamic>[
    <String, dynamic>{
      'id': 's1',
      'duration': 5.0,
      'camera': <String, dynamic>{'id': 'hero'},
      'cues': <dynamic>[],
    },
  ],
};

/// 跨文档校验必失败：镜头引用的相机在场景里不存在（两份都是合法 JSON 对象）。
Map<String, dynamic> _sceneWithoutCamera() {
  final scene = _scene();
  scene['cameras'] = <dynamic>[];
  return scene;
}

void main() {
  late Directory root;
  late Video3dProjectStore store;
  late LocalWorkspaceServices workspace;

  setUp(() {
    root = Directory.systemTemp.createTempSync('video3d-tools-');
    store = Video3dProjectStore(root: root);
    workspace = LocalWorkspaceServices(
      model: 'scripted-model',
      baseUrl: 'https://example.invalid/v1',
      apiKey: 'k',
      video3dProjects: store,
    );
  });

  tearDown(() {
    if (root.existsSync()) {
      try {
        root.deleteSync(recursive: true);
      } catch (_) {
        // 临时目录清理失败不影响断言结果。
      }
    }
  });

  test('合法输入：先校验后落盘，回节点/镜头/片长/整数帧', () async {
    final result = await workspace.video3dCreate(
      name: 'stage',
      scene: _scene(),
      screenplay: _screenplay(),
    );
    expect(result['ok'], isTrue);
    expect(result['verified'], isTrue);
    expect(result['project'], 'stage');
    expect(result['nodes'], 2);
    expect(result['shots'], 1);
    expect(result['seconds'], 5.0);
    // 30fps × 5s = 150 整数帧。
    expect(result['frames'], 150);

    // 两份事实源真的落到 `<root>/stage/`，且能被存储重新读出来。
    final dir = Directory('${root.path}/stage');
    expect(dir.existsSync(), isTrue);
    expect(File('${dir.path}/scene3d.json').existsSync(), isTrue);
    expect(File('${dir.path}/screenplay3d.json').existsSync(), isTrue);
    final snapshot = await store.read('stage');
    expect(snapshot.verification.verified, isTrue);
  });

  test('同名已存在：拒绝覆盖，磁盘逐字节不变', () async {
    await workspace.video3dCreate(
      name: 'stage',
      scene: _scene(),
      screenplay: _screenplay(),
    );
    final sceneFile = File('${root.path}/stage/scene3d.json');
    final screenplayFile = File('${root.path}/stage/screenplay3d.json');
    final sceneBefore = sceneFile.readAsStringSync();
    final screenplayBefore = screenplayFile.readAsStringSync();

    // 用一份「不同颜色」的合法场景再建同名项目：必须被拒绝。
    final other = _scene();
    ((other['nodes'] as List)[0] as Map)['material'] = <String, dynamic>{
      'color': '#ff0000',
      'roughness': 0.5,
      'metalness': 0.0,
    };
    final result = await workspace.video3dCreate(
      name: 'stage',
      scene: other,
      screenplay: _screenplay(),
    );
    expect(result['ok'], isFalse);
    expect(result['error'], 'video3d_project_exists');
    expect(result['message'], toolFailureMessage('video3d_project_exists'));

    expect(sceneFile.readAsStringSync(), sceneBefore);
    expect(screenplayFile.readAsStringSync(), screenplayBefore);
  });

  test('未通过校验：不落盘（目录不出现），如实回问题清单', () async {
    final result = await workspace.video3dCreate(
      name: 'broken',
      scene: _sceneWithoutCamera(),
      screenplay: _screenplay(),
    );
    expect(result['ok'], isFalse);
    expect(result['error'], 'video3d_unverified');
    expect(result['verified'], isFalse);
    final checks = result['checks'];
    expect(checks, isA<List<dynamic>>());
    expect((checks as List).isEmpty, isFalse);

    // 先校验后落盘：未通过时目录都不该出现。
    expect(Directory('${root.path}/broken').existsSync(), isFalse);

    // 改好再建就能通过（同一名字不被上一轮污染）。
    final fixed = await workspace.video3dCreate(
      name: 'broken',
      scene: _scene(),
      screenplay: _screenplay(),
    );
    expect(fixed['ok'], isTrue);
    expect(fixed['verified'], isTrue);
  });

  test('非法项目名：稳定失败码，不写盘', () async {
    final result = await workspace.video3dCreate(
      name: 'Bad Name!',
      scene: _scene(),
      screenplay: _screenplay(),
    );
    expect(result['ok'], isFalse);
    expect(result['error'], 'video3d_invalid_name');
    expect(result['message'], toolFailureMessage('video3d_invalid_name'));
    expect(Directory('${root.path}/Bad Name!').existsSync(), isFalse);
  });

  test('查看：回校验状态 + 两份事实源原文 + 整数帧', () async {
    await workspace.video3dCreate(
      name: 'stage',
      scene: _scene(),
      screenplay: _screenplay(),
    );
    final status = await workspace.video3dStatus('stage');
    expect(status['ok'], isTrue);
    expect(status['verified'], isTrue);
    expect(status['frames'], 150);
    expect(status['checks'], isEmpty);
    expect(status['scene'], isA<Map<String, dynamic>>());
    expect(status['screenplay'], isA<Map<String, dynamic>>());
    expect((status['scene'] as Map)['v'], 1);
    expect((status['screenplay'] as Map)['fps'], 30);
  });

  test('查看：校验未通过的项目照常返回（verified=false + checks）', () async {
    // 绕过 create 的校验门，直接落一份「两份是 JSON、契约不通过」的项目。
    final dir = Directory('${root.path}/broken')..createSync(recursive: true);
    File('${dir.path}/scene3d.json').writeAsStringSync(
      '{"v": 1, "units": "m", "nodes": [], "lights": [], "cameras": []}',
    );
    File('${dir.path}/screenplay3d.json').writeAsStringSync(
      '{"v": 1, "fps": 30, "shots": [{"id": "s1", "duration": 1,'
      ' "camera": {"id": "missing"}}]}',
    );
    final status = await workspace.video3dStatus('broken');
    expect(status['ok'], isTrue);
    expect(status['verified'], isFalse);
    expect((status['checks'] as List).isEmpty, isFalse);
    // 校验未通过时不算帧（不拿坏数据算出一个假帧数）。
    expect(status['frames'], 0);
  });

  test('查看：项目不存在 → video3d_no_project', () async {
    final status = await workspace.video3dStatus('nope');
    expect(status['ok'], isFalse);
    expect(status['error'], 'video3d_no_project');
    expect(status['message'], toolFailureMessage('video3d_no_project'));
  });

  test('列表：包含已建项目与摘要字段', () async {
    await workspace.video3dCreate(
      name: 'stage',
      scene: _scene(),
      screenplay: _screenplay(),
    );
    final list = await workspace.video3dList();
    expect(list['ok'], isTrue);
    expect(list['count'], 1);
    final projects = list['projects'] as List;
    expect(projects, hasLength(1));
    final first = projects.first as Map;
    expect(first['name'], 'stage');
    expect(first['nodes'], 2);
    expect(first['shots'], 1);
    expect(first['frames'], 150);
    expect(first['verified'], isTrue);
  });
}
