import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nondesign/core/video3d/video3d_compile.dart';
import 'package:nondesign/core/video3d/video3d_contract.dart';

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
      <String, Object?>{
        'id': 'pillar',
        'type': 'cylinder',
        'size': <double>[0.1, 0.1, 2],
        'position': <double>[1, 1, 0],
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

/// 子节点排在父节点之前的场景（父子挂接必须在所有 mesh 建好之后做）。
Map<String, Object?> _childBeforeParentScene() {
  return <String, Object?>{
    'v': 1,
    'nodes': <Object?>[
      <String, Object?>{
        'id': 'table',
        'type': 'plane',
        'size': <double>[2, 1, 0],
        'parent': 'floor',
      },
      <String, Object?>{
        'id': 'floor',
        'type': 'box',
        'size': <double>[10, 0.1, 10],
      },
    ],
  };
}

Video3dScene _sceneOf(Map<String, Object?> raw) {
  final result = Video3dScene.parse(raw);
  expect(result.issues, isEmpty, reason: 'fixture 必须合法：${result.issues}');
  return result.scene!;
}

Video3dScreenplay _screenplay(
  List<Map<String, Object?>> shots, {
  double? duration,
}) {
  final raw = <String, Object?>{
    'v': 1,
    'fps': 30,
    'format': <String, Object?>{'width': 720, 'height': 1280},
    'shots': <Object?>[
      for (final Map<String, Object?> shot in shots)
        <String, Object?>{
          'id': shot['id'],
          'duration': shot['duration'],
          'camera': <String, Object?>{'id': shot['camera_id'] ?? 'hero'},
        },
    ],
    'duration': ?duration,
  };
  final result = Video3dScreenplay.parse(raw);
  expect(result.issues, isEmpty, reason: 'fixture 必须合法：${result.issues}');
  return result.screenplay!;
}

Map<String, Object?> _reversedKeys(Map<String, Object?> map) {
  return <String, Object?>{
    for (final String key in map.keys.toList().reversed) key: map[key],
  };
}

void main() {
  group('scene3d.json → 确定性 src/scene.js', () {
    test('同输入两次编译字节相同（同一模型 + 两次独立解析）', () {
      final scene = _sceneOf(_validScene());
      final first = compileVideo3dScene(scene);
      final second = compileVideo3dScene(scene);
      expect(first, second, reason: '确定性编译：同输入必须同字节');

      final again = compileVideo3dScene(_sceneOf(_validScene()));
      expect(again, first, reason: '重新解析同一 JSON 后编译也必须同字节');
    });

    test('JSON 字段书写顺序不影响编译字节', () {
      final reordered = _reversedKeys(_validScene());
      reordered['nodes'] = <Object?>[
        for (final Object? node in _validScene()['nodes']! as List<Object?>)
          _reversedKeys(node! as Map<String, Object?>),
      ];
      reordered['lights'] = <Object?>[
        for (final Object? light in _validScene()['lights']! as List<Object?>)
          _reversedKeys(light! as Map<String, Object?>),
      ];
      reordered['cameras'] = <Object?>[
        for (final Object? camera in _validScene()['cameras']! as List<Object?>)
          _reversedKeys(camera! as Map<String, Object?>),
      ];
      expect(
        compileVideo3dScene(_sceneOf(reordered)),
        compileVideo3dScene(_sceneOf(_validScene())),
        reason: '输出只由语义决定，与 JSON 键顺序无关',
      );
    });

    test('覆盖节点/材质/灯光/相机/背景：每个 mesh.name = id', () {
      final js = compileVideo3dScene(_sceneOf(_validScene()));
      expect(js, contains('mesh.name = node.id;'));
      expect(js, contains("case 'box'"));
      expect(js, contains("case 'sphere'"));
      expect(js, contains("case 'cylinder'"));
      expect(js, contains("case 'plane'"));
      expect(js, contains('new THREE.MeshStandardMaterial'));
      expect(js, contains("color: '#9a8c7a'"));
      expect(js, contains('roughness: 0.9'));
      expect(js, contains('metalness: 0'));
      expect(js, contains('new THREE.DirectionalLight'));
      expect(js, contains('new THREE.AmbientLight'));
      expect(js, contains('new THREE.PerspectiveCamera'));
      expect(js, contains("scene.background = new THREE.Color('#0b0d12');"));
      expect(js, contains("id: 'floor', type: 'box'"));
      expect(js, contains("id: 'table', type: 'plane'"));
      expect(js, contains('scene_nodes: 4'));
      expect(js, contains('scene_lights: 2'));
      expect(js, contains('scene_cameras: 1'));
    });

    test('父子挂接：先建 mesh 再统一挂接（父节点可排在子节点之后）', () {
      final js = compileVideo3dScene(_sceneOf(_childBeforeParentScene()));
      final meshIndex = js.indexOf('mesh.name = node.id;');
      final attachIndex = js.indexOf(
        'if (node.parent) nodes[node.parent].add(mesh); else scene.add(mesh);',
      );
      expect(meshIndex, greaterThan(0));
      expect(attachIndex, greaterThan(meshIndex));
      expect(js, contains("id: 'table', type: 'plane'"));
      expect(js, contains("parent: 'floor'"));
      // 父节点即使排在子节点后面，也在同一 nodeDefs 表里。
      expect(js.indexOf("id: 'floor'"), greaterThan(0));
    });

    test('数值格式化确定：整数无小数点、浮点最短表示、无 NaN/Infinity', () {
      final js = compileVideo3dScene(_sceneOf(_validScene()));
      expect(js, contains('size: [10, 0.1, 10]'));
      expect(js, contains('fov: 45,'));
      expect(js, contains('intensity: 1,'));
      expect(js, contains('intensity: 0.2,'));
      // 数值字面量里不允许出现 NaN/Infinity（产品名 "NaN" 在头部注释里是允许的）。
      final nonFiniteLiteral = RegExp(r'[\[,:]\s*(?:NaN|Infinity|-Infinity)');
      expect(nonFiniteLiteral.hasMatch(js), isFalse);
    });

    test('无随机/时间戳/系统时钟：不出现 Math.random、Date.now 等', () {
      final js = compileVideo3dScene(_sceneOf(_validScene()));
      for (final String banned in <String>[
        'Math.random',
        'Date.now',
        'new Date',
        'performance.now',
        'clock',
        'Date(',
      ]) {
        expect(js, isNot(contains(banned)), reason: '确定性编译禁止出现 $banned');
      }
      // 头部也不允许时间戳（2026-… 之类的年份/ISO 时间）。
      expect(RegExp(r'\d{4}-\d{2}-\d{2}').hasMatch(js), isFalse);
    });

    test('最小场景（无灯光/相机/环境）也确定性编译', () {
      final minimal = _sceneOf(<String, Object?>{
        'v': 1,
        'nodes': <Object?>[
          <String, Object?>{
            'id': 'n_0',
            'type': 'box',
            'size': <double>[1, 1, 1],
          },
        ],
      });
      final first = compileVideo3dScene(minimal);
      final second = compileVideo3dScene(minimal);
      expect(first, second);
      expect(first, contains('scene_nodes: 1'));
      expect(first, contains('scene_lights: 0'));
      expect(first, contains('scene_cameras: 0'));
      expect(first, contains('const lightDefs = ['));
      expect(first, contains('const cameraDefs = ['));
      expect(first, isNot(contains('scene.background')));
    });
  });

  group('screenplay3d.json → 整数帧时间表', () {
    test('单镜 5 秒 → 150 帧；起点 0、覆盖全片', () {
      final screenplay = _screenplay(<Map<String, Object?>>[
        <String, Object?>{'id': 's1', 'duration': 5.0},
      ]);
      final timeline = compileVideo3dTimeline(screenplay);
      expect(timeline.fps, 30);
      expect(timeline.totalFrames, 150);
      expect(timeline.durationSeconds, 5.0);
      expect(timeline.shots, hasLength(1));
      final shot = timeline.shots.single;
      expect(shot.id, 's1');
      expect(shot.startFrame, 0);
      expect(shot.frameCount, 150);
      expect(shot.endFrame, 150);
      expect(shot.cameraId, 'hero');
    });

    test('多镜 floor 边界 + 全片覆盖不重叠（2.5s + 1.25s）', () {
      final screenplay = _screenplay(<Map<String, Object?>>[
        <String, Object?>{'id': 's1', 'duration': 2.5},
        <String, Object?>{'id': 's2', 'duration': 1.25},
      ]);
      final timeline = compileVideo3dTimeline(screenplay);
      // 2.5*30 = 75 帧；1.25*30 = 37.5 → 帧表按 floor 切在 75，最后一镜收尾到 112。
      expect(timeline.totalFrames, (3.75 * 30).floor());
      expect(timeline.totalFrames, 112);
      expect(timeline.shots[0].startFrame, 0);
      expect(timeline.shots[0].frameCount, 75);
      expect(timeline.shots[0].endFrame, 75);
      expect(timeline.shots[1].startFrame, 75);
      expect(timeline.shots[1].frameCount, 37);
      expect(timeline.shots[1].endFrame, 112);

      // 覆盖全片：首镜从 0 开始、相邻镜头首尾相接、末镜到总帧数。
      var expectedStart = 0;
      for (final Video3dShotFrames shot in timeline.shots) {
        expect(shot.startFrame, expectedStart, reason: '镜头必须首尾相接、无空洞');
        expect(shot.endFrame, shot.startFrame + shot.frameCount);
        expect(shot.frameCount, greaterThanOrEqualTo(1));
        expectedStart = shot.endFrame;
      }
      expect(expectedStart, timeline.totalFrames);
      expect(
        timeline.shots.fold<int>(
          0,
          (int sum, Video3dShotFrames shot) => sum + shot.frameCount,
        ),
        timeline.totalFrames,
      );
    });

    test('非整数秒按 floor 切帧（0.25 / 0.75 / 1.0 → 7 / 23 / 30 帧）', () {
      final screenplay = _screenplay(<Map<String, Object?>>[
        <String, Object?>{'id': 's1', 'duration': 0.25},
        <String, Object?>{'id': 's2', 'duration': 0.75},
        <String, Object?>{'id': 's3', 'duration': 1.0},
      ]);
      final timeline = compileVideo3dTimeline(screenplay);
      expect(timeline.totalFrames, 60);
      expect(
        timeline.shots
            .map((Video3dShotFrames shot) => shot.frameCount)
            .toList(),
        <int>[7, 23, 30],
      );
    });

    test('浮点累加误差不吞帧：0.3s + 0.6s → 9 + 18 = 27 帧（严格 floor 会得 26）', () {
      final screenplay = _screenplay(<Map<String, Object?>>[
        <String, Object?>{'id': 's1', 'duration': 0.3},
        <String, Object?>{'id': 's2', 'duration': 0.6},
      ]);
      final timeline = compileVideo3dTimeline(screenplay);
      // 0.3 + 0.6 在二进制浮点里是 0.8999999999999999；帧表仍按用户意图切 27 帧。
      expect(timeline.totalFrames, 27);
      expect(timeline.shots[0].frameCount, 9);
      expect(timeline.shots[1].frameCount, 18);
    });

    test('最短合法镜头恰为一帧（1/30 秒 → 1 帧，不被 floor 吞掉）', () {
      final screenplay = _screenplay(<Map<String, Object?>>[
        <String, Object?>{'id': 's1', 'duration': 1.0 / 30.0},
      ]);
      final timeline = compileVideo3dTimeline(screenplay);
      expect(timeline.totalFrames, 1);
      expect(timeline.shots.single.startFrame, 0);
      expect(timeline.shots.single.frameCount, 1);
      expect(timeline.shotAt(0)!.id, 's1');
    });

    test('显式片长参与总帧：1.2s + 2.8s，片长 4s → 120 帧', () {
      final screenplay = _screenplay(<Map<String, Object?>>[
        <String, Object?>{'id': 's1', 'duration': 1.2},
        <String, Object?>{'id': 's2', 'duration': 2.8},
      ], duration: 4.0);
      final timeline = compileVideo3dTimeline(screenplay);
      expect(timeline.totalFrames, 120);
      expect(timeline.shots[0].frameCount, 36);
      expect(timeline.shots[1].frameCount, 84);
    });

    test('纯 from/to 覆盖的镜头：camera_id 缺省为 null（不编造相机）', () {
      final result = Video3dScreenplay.parse(<String, Object?>{
        'v': 1,
        'fps': 30,
        'format': <String, Object?>{'width': 720, 'height': 1280},
        'shots': <Object?>[
          <String, Object?>{
            'id': 's1',
            'duration': 2.0,
            'camera': <String, Object?>{
              'move': <String, Object?>{
                'from': <double>[0, 1, 0],
                'to': <double>[1, 1, 0],
              },
            },
          },
        ],
      });
      expect(result.issues, isEmpty);
      final timeline = compileVideo3dTimeline(result.screenplay!);
      expect(timeline.totalFrames, 60);
      expect(timeline.shots.single.cameraId, isNull);
      final shotJson = timeline.toJson()['shots']! as List<Object?>;
      expect(
        (shotJson.single! as Map<String, Object?>).containsKey('camera_id'),
        isFalse,
      );
    });

    test('帧号映射 shootAt：边界/越界不猜', () {
      final screenplay = _screenplay(<Map<String, Object?>>[
        <String, Object?>{'id': 's1', 'duration': 2.5},
        <String, Object?>{'id': 's2', 'duration': 1.25},
      ]);
      final timeline = compileVideo3dTimeline(screenplay);
      expect(timeline.shotAt(0)!.id, 's1');
      expect(timeline.shotAt(74)!.id, 's1');
      expect(timeline.shotAt(75)!.id, 's2');
      expect(timeline.shotAt(111)!.id, 's2');
      expect(timeline.shotAt(-1), isNull);
      expect(timeline.shotAt(112), isNull);
      expect(timeline.shotAt(9999), isNull);
    });

    test('帧表全整数：toJson 的 start_frame/frame_count/end_frame 是 int', () {
      final screenplay = _screenplay(<Map<String, Object?>>[
        <String, Object?>{'id': 's1', 'duration': 2.5},
        <String, Object?>{'id': 's2', 'duration': 1.25},
      ]);
      final timeline = compileVideo3dTimeline(screenplay);
      final json = timeline.toJson();
      expect(json['fps'], 30);
      expect(json['total_frames'], isA<int>());
      final shots = json['shots']! as List<Object?>;
      for (final Object? entry in shots) {
        final shot = entry! as Map<String, Object?>;
        expect(shot['start_frame'], isA<int>());
        expect(shot['frame_count'], isA<int>());
        expect(shot['end_frame'], isA<int>());
      }
      // JSON 编码再解码后仍是 int（不是 75.0 之类的浮点拍点）。
      final roundTripped = jsonDecode(jsonEncode(json)) as Map<String, Object?>;
      final roundShots = roundTripped['shots']! as List<Object?>;
      for (final Object? entry in roundShots) {
        final shot = entry! as Map<String, Object?>;
        expect(shot['start_frame'], isA<int>());
        expect(shot['frame_count'], isA<int>());
        expect(shot['end_frame'], isA<int>());
      }
      // 区间必须恰好首尾相接且落在 [0, total)。
      var expected = 0;
      for (final Object? entry in roundShots) {
        final shot = entry! as Map<String, Object?>;
        expect(shot['start_frame'], expected);
        expect(
          shot['end_frame'],
          (shot['start_frame']! as int) + (shot['frame_count']! as int),
        );
        expected = shot['end_frame']! as int;
      }
      expect(expected, roundTripped['total_frames']);
    });

    test('时间表数据确定性：两次编译完全相等', () {
      final first = compileVideo3dTimeline(
        _screenplay(<Map<String, Object?>>[
          <String, Object?>{'id': 's1', 'duration': 2.5},
          <String, Object?>{'id': 's2', 'duration': 1.25},
        ]),
      );
      final second = compileVideo3dTimeline(
        _screenplay(<Map<String, Object?>>[
          <String, Object?>{'id': 's1', 'duration': 2.5},
          <String, Object?>{'id': 's2', 'duration': 1.25},
        ]),
      );
      expect(first.toJson(), second.toJson());
      expect(first.totalFrames, second.totalFrames);
      expect(
        first.shots
            .map(
              (Video3dShotFrames shot) =>
                  '${shot.id}:${shot.startFrame}:${shot.frameCount}',
            )
            .toList(),
        second.shots
            .map(
              (Video3dShotFrames shot) =>
                  '${shot.id}:${shot.startFrame}:${shot.frameCount}',
            )
            .toList(),
      );
    });

    test('未通过契约的剧本（时长不匹配）不能构造模型，编译前必须先校验', () {
      final bad = <String, Object?>{
        'v': 1,
        'fps': 30,
        'format': <String, Object?>{'width': 720, 'height': 1280},
        'duration': 4.0,
        'shots': <Object?>[
          <String, Object?>{
            'id': 's1',
            'duration': 5.0,
            'camera': <String, Object?>{'id': 'hero'},
          },
        ],
      };
      final result = Video3dScreenplay.parse(bad);
      expect(result.screenplay, isNull);
      final verification = verifyVideo3d(_validScene(), bad);
      expect(verification.verified, isFalse);
      expect(
        verification.checks.map((Video3dIssue issue) => issue.code).toSet(),
        contains('video3d_screenplay_duration_mismatch'),
      );
    });
  });
}
