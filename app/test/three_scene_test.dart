import 'package:flutter_test/flutter_test.dart';
import 'package:nondesign/core/three/three_scene.dart';

Map<String, dynamic> _valid() => <String, dynamic>{
  'v': 1,
  'nodes': <Map<String, dynamic>>[
    <String, dynamic>{
      'id': 'floor',
      'type': 'box',
      'size': <double>[10, 0.1, 10],
      'position': <double>[0, -0.05, 0],
      'color': '#9a8c7a',
      'roughness': 0.9,
    },
    <String, dynamic>{
      'id': 'table',
      'type': 'box',
      'size': <double>[1.2, 0.75, 0.8],
      'position': <double>[0, 0.375, 0],
      'color': '#c9a06a',
      'parent': 'floor',
    },
    <String, dynamic>{
      'id': 'lamp',
      'type': 'sphere',
      'size': <double>[0.12, 0.12, 0.12],
      'segments': <int>[24, 16],
      'position': <double>[0, 1.6, 0],
      'color': '#ffd166',
      'metalness': 0.4,
      'rotation': <double>[0, 30, 0],
    },
  ],
  'camera': <String, dynamic>{
    'position': <double>[4, 2, 4],
    'target': <double>[0, 1, 0],
  },
  'env': <String, dynamic>{'background': '#0b0d12'},
};

void main() {
  group('scene.json 解析/校验', () {
    test('合法场景：节点/父子/camera/env', () {
      final result = ThreeSceneDocument.parse(_valid());
      expect(result.issues.where((i) => i.blocking), isEmpty);
      final doc = result.document!;
      expect(doc.nodes, hasLength(3));
      expect(doc.nodes[1].parent, 'floor');
      expect(doc.cameraPosition, <double>[4, 2, 4]);
      expect(doc.background, '#0b0d12');
    });

    test('重复 id / 未知类型 / parent 缺失 / 成环 / 坏颜色 → 全列问题', () {
      final raw = _valid();
      final nodes = (raw['nodes'] as List).cast<Map<String, dynamic>>();
      nodes[1]['id'] = 'floor';
      nodes[0]['type'] = 'torus';
      nodes[2]['parent'] = 'ghost';
      nodes[1]['parent'] = 'table';
      nodes[0]['color'] = 'red';
      final result = ThreeSceneDocument.parse(raw);
      expect(result.document, isNull);
      final codes = result.issues.map((issue) => issue.code).toSet();
      expect(
        codes,
        containsAll(<String>[
          'scene_node_id_duplicate',
          'scene_geometry_unsupported',
          'scene_parent_missing',
          'scene_color_invalid',
        ]),
      );

      final cycle = ThreeSceneDocument.parse(<String, dynamic>{
        'v': 1,
        'nodes': <dynamic>[
          <String, dynamic>{
            'id': 'a',
            'type': 'box',
            'size': <double>[1, 1, 1],
            'parent': 'b',
          },
          <String, dynamic>{
            'id': 'b',
            'type': 'box',
            'size': <double>[1, 1, 1],
            'parent': 'a',
          },
        ],
      });
      expect(
        cycle.issues.map((issue) => issue.code),
        contains('scene_parent_cycle'),
      );
    });

    test('上限 200 节点；版本/结构错误', () {
      final tooMany = <Map<String, dynamic>>[
        for (int i = 0; i < 201; i++)
          <String, dynamic>{
            'id': 'n_$i',
            'type': 'box',
            'size': <double>[1, 1, 1],
          },
      ];
      final result = ThreeSceneDocument.parse(<String, dynamic>{
        'v': 1,
        'nodes': tooMany,
      });
      expect(
        result.issues.map((i) => i.code),
        contains('scene_too_many_nodes'),
      );
      expect(ThreeSceneDocument.parse(null).document, isNull);
      expect(
        ThreeSceneDocument.parse(<String, dynamic>{
          'v': 2,
          'nodes': <dynamic>[],
        }).issues.map((i) => i.code),
        contains('scene_unsupported_version'),
      );
    });

    test('尺寸必须为正（plane 第三维可为 0）', () {
      final bad = ThreeSceneDocument.parse(<String, dynamic>{
        'v': 1,
        'nodes': <dynamic>[
          <String, dynamic>{
            'id': 'a',
            'type': 'box',
            'size': <double>[1, 0, 1],
          },
        ],
      });
      expect(bad.issues.map((i) => i.code), contains('scene_size_invalid'));
      final plane = ThreeSceneDocument.parse(<String, dynamic>{
        'v': 1,
        'nodes': <dynamic>[
          <String, dynamic>{
            'id': 'ground',
            'type': 'plane',
            'size': <double>[10, 10, 0],
          },
        ],
      });
      expect(plane.document, isNotNull);
    });
  });

  group('scene.json → src/scene.js 编译', () {
    test('含 name/几何/材质/父子/相机；相同输入字节相同', () {
      final doc = ThreeSceneDocument.parse(_valid()).document!;
      final first = compileThreeScene(doc);
      final second = compileThreeScene(doc);
      expect(first, second, reason: '确定性编译：同输入必须同字节');
      expect(first, contains('mesh.name = node.id;'));
      expect(first, contains("case 'box'"));
      expect(first, contains("case 'sphere'"));
      expect(first, contains("color: '#c9a06a'"));
      expect(first, contains("parent: 'floor'"));
      expect(first, contains('camera.position.set(4, 2, 4);'));
      expect(first, contains('controls.target.set(0, 1, 0);'));
      expect(first, contains("source: 'scene.json'"));
      // 无随机/时间。
      expect(first, isNot(contains('Math.random')));
      expect(first, isNot(contains('Date.now')));
    });

    test('plane/cylinder 几何分支与默认 transform', () {
      final doc = ThreeSceneDocument.parse(<String, dynamic>{
        'v': 1,
        'nodes': <dynamic>[
          <String, dynamic>{
            'id': 'ground',
            'type': 'plane',
            'size': <double>[10, 10, 0],
          },
          <String, dynamic>{
            'id': 'pillar',
            'type': 'cylinder',
            'size': <double>[0.2, 0.3, 2],
          },
        ],
      }).document!;
      final js = compileThreeScene(doc);
      expect(js, contains("case 'plane'"));
      expect(js, contains("case 'cylinder'"));
      expect(js, contains('position: [0, 0, 0]'));
      expect(js, contains('scale: [1, 1, 1]'));
    });
  });
}
