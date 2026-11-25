import 'package:flutter_test/flutter_test.dart';
import 'package:nondesign/core/video3d/video3d_contract.dart';

/// D3 草案 §2 的合法 scene3d.json（节点/灯光/相机/环境齐全）。
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
        'asset': null,
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

/// D3 草案 §3 的合法 screenplay3d.json（一镜、相机引用 + 缓动覆盖、5 秒）。
Map<String, Object?> _validScreenplay({
  double? duration,
  bool withMove = true,
}) {
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
        if (withMove)
          'camera': <String, Object?>{
            'id': 'hero',
            'move': <String, Object?>{
              'from': <double>[4, 2, 4],
              'to': <double>[3, 2.2, 4],
              'target': <double>[0, 1, 0],
              'easing': 'easeInOut',
            },
          }
        else
          'camera': <String, Object?>{'id': 'hero'},
        'cues': <Object?>[],
        'scene': <String, Object?>{'from': 0.0, 'to': 5.0},
      },
    ],
  };
}

Set<String> _codes(List<Video3dIssue> issues) =>
    issues.map((Video3dIssue issue) => issue.code).toSet();

Set<String> _pointers(List<Video3dIssue> issues) =>
    issues.map((Video3dIssue issue) => issue.pointer).toSet();

List<Object?> _nodesOf(Map<String, Object?> scene) =>
    scene['nodes']! as List<Object?>;

Map<String, Object?> _nodeAt(Map<String, Object?> scene, int index) =>
    _nodesOf(scene)[index]! as Map<String, Object?>;

void main() {
  group('scene3d.json 解析/校验', () {
    test('D3 示例合法场景：节点/灯光/相机/环境与默认值', () {
      final result = Video3dScene.parse(_validScene());
      expect(result.issues, isEmpty);
      final scene = result.scene!;
      expect(scene.units, 'm');
      expect(scene.environment!.background, '#0b0d12');
      expect(scene.nodes, hasLength(3));
      expect(scene.nodes[0].type, Video3dNodeType.box);
      expect(scene.nodes[1].type, Video3dNodeType.plane);
      expect(scene.nodes[1].parent, 'floor');
      expect(scene.nodes[0].material.color, '#9a8c7a');
      expect(scene.nodes[0].material.roughness, 0.9);
      // 未写 material 的节点用同族默认值。
      expect(scene.nodes[2].material.color, Video3dMaterial.defaultColor);
      expect(scene.lights, hasLength(2));
      expect(scene.lights[0].type, Video3dLightType.directional);
      expect(scene.lights[1].id, isNull, reason: '灯光 id 是可选字段');
      expect(scene.cameras.single.id, 'hero');
      expect(scene.cameras.single.fov, 45.0);
    });

    test('units 缺省为 m；非 m 拒绝', () {
      final withoutUnits = _validScene()..remove('units');
      expect(Video3dScene.parse(withoutUnits).scene, isNotNull);
      final cm = _validScene()..['units'] = 'cm';
      expect(
        _codes(Video3dScene.parse(cm).issues),
        contains('video3d_scene_units_unsupported'),
      );
    });

    test('重复 id / 未知几何 / 坏尺寸 / 坏颜色 / 材质越界 → 全列问题', () {
      final raw = _validScene();
      _nodeAt(raw, 1)['id'] = 'floor';
      _nodeAt(raw, 2)['type'] = 'torus';
      _nodeAt(raw, 0)['size'] = <double>[10, 0, 10];
      _nodeAt(raw, 1)['material'] = <String, Object?>{'color': 'red'};
      (_nodeAt(raw, 0)['material']! as Map<String, Object?>)['roughness'] = 1.5;
      (_nodeAt(raw, 0)['material']! as Map<String, Object?>)['metalness'] =
          -0.1;
      final result = Video3dScene.parse(raw);
      expect(result.scene, isNull);
      expect(
        _codes(result.issues),
        containsAll(<String>[
          'video3d_scene_node_id_duplicate',
          'video3d_scene_geometry_unsupported',
          'video3d_scene_size_invalid',
          'video3d_scene_color_invalid',
          'video3d_scene_roughness_invalid',
          'video3d_scene_metalness_invalid',
        ]),
      );
    });

    test('缺 size / 非有限数字 → 数字问题', () {
      final raw = _validScene();
      _nodeAt(raw, 2).remove('size');
      (_nodeAt(raw, 0)['position']! as List<Object?>)[0] = double.nan;
      final result = Video3dScene.parse(raw);
      expect(
        _codes(result.issues),
        containsAll(<String>[
          'video3d_scene_size_invalid',
          'video3d_scene_number_invalid',
        ]),
      );
    });

    test('plane 第三维可为 0；box 的 0 与负数都拒绝', () {
      // plane [2,1,0] 在合法场景里已通过；负数第三维拒绝。
      final negativePlane = _validScene();
      _nodeAt(negativePlane, 1)['size'] = <double>[2, 1, -1];
      expect(
        _codes(Video3dScene.parse(negativePlane).issues),
        contains('video3d_scene_size_invalid'),
      );
    });

    test('parent 不存在 / 成环 / 自环 / 非法格式', () {
      final missing = _validScene();
      _nodeAt(missing, 2)['parent'] = 'ghost';
      expect(
        _codes(Video3dScene.parse(missing).issues),
        contains('video3d_scene_parent_missing'),
      );

      final cycle = _validScene();
      _nodeAt(cycle, 0)['parent'] = 'table';
      _nodeAt(cycle, 1)['parent'] = 'floor';
      expect(
        _codes(Video3dScene.parse(cycle).issues),
        contains('video3d_scene_parent_cycle'),
      );

      final selfCycle = _validScene();
      _nodeAt(selfCycle, 2)['parent'] = 'lamp';
      expect(
        _codes(Video3dScene.parse(selfCycle).issues),
        contains('video3d_scene_parent_cycle'),
      );

      final badFormat = _validScene();
      _nodeAt(badFormat, 2)['parent'] = 'Bad-Parent';
      expect(
        _codes(Video3dScene.parse(badFormat).issues),
        contains('video3d_scene_parent_invalid'),
      );
    });

    test('节点上限 256：到上限通过，超一个拒绝', () {
      Map<String, Object?> sceneWith(int count) => <String, Object?>{
        'v': 1,
        'nodes': <Object?>[
          for (int i = 0; i < count; i++)
            <String, Object?>{
              'id': 'n_$i',
              'type': 'box',
              'size': <double>[1, 1, 1],
            },
        ],
      };
      final atLimit = Video3dScene.parse(sceneWith(video3dMaxNodes));
      expect(atLimit.issues, isEmpty);
      expect(atLimit.scene!.nodes, hasLength(video3dMaxNodes));

      final overLimit = Video3dScene.parse(sceneWith(video3dMaxNodes + 1));
      expect(
        _codes(overLimit.issues),
        contains('video3d_scene_too_many_nodes'),
      );
    });

    test('fov 越界拒绝，10/120 边界通过', () {
      Map<String, Object?> sceneWithFov(num fov) {
        final scene = _validScene();
        ((scene['cameras']! as List<Object?>).single!
                as Map<String, Object?>)['fov'] =
            fov;
        return scene;
      }

      for (final num fov in <num>[9, 121]) {
        expect(
          _codes(Video3dScene.parse(sceneWithFov(fov)).issues),
          contains('video3d_scene_camera_fov_invalid'),
          reason: 'fov=$fov 必须越界',
        );
      }
      for (final int fov in <int>[10, 120]) {
        expect(
          Video3dScene.parse(sceneWithFov(fov)).scene,
          isNotNull,
          reason: 'fov=$fov 是闭区间边界',
        );
      }
    });

    test('灯光：坏类型 / 负强度 / 坏颜色 / 非有限位置', () {
      final raw = _validScene();
      final lights = raw['lights']! as List<Object?>;
      (lights[0]! as Map<String, Object?>)['type'] = 'spot';
      (lights[0]! as Map<String, Object?>)['intensity'] = -0.5;
      (lights[0]! as Map<String, Object?>)['color'] = 'white';
      (lights[0]! as Map<String, Object?>)['position'] = <double>[
        double.infinity,
        0,
        0,
      ];
      (lights[1]! as Map<String, Object?>)['target'] = <double>[
        0,
        double.nan,
        0,
      ];
      expect(
        _codes(Video3dScene.parse(raw).issues),
        containsAll(<String>[
          'video3d_scene_light_type_unsupported',
          'video3d_scene_light_intensity_invalid',
          'video3d_scene_color_invalid',
          'video3d_scene_number_invalid',
        ]),
      );
    });

    test('asset：null 合法；v1 拒绝外部模型；越界/非 glTF 路径非法', () {
      final nullAsset = _validScene();
      expect(Video3dScene.parse(nullAsset).scene, isNotNull);

      final relative = _validScene();
      _nodeAt(relative, 0)['asset'] = 'models/chair.glb';
      expect(
        _codes(Video3dScene.parse(relative).issues),
        contains('video3d_scene_asset_unsupported'),
      );

      for (final String badPath in <String>[
        '/tmp/chair.glb',
        '../chair.glb',
        'models/chair.png',
      ]) {
        final raw = _validScene();
        _nodeAt(raw, 0)['asset'] = badPath;
        expect(
          _codes(Video3dScene.parse(raw).issues),
          contains('video3d_scene_asset_invalid'),
          reason: '路径 $badPath 必须被拒绝',
        );
      }
    });

    test('环境：背景必须是 #rrggbb；environment 必须是对象', () {
      final badColor = _validScene();
      (badColor['environment']! as Map<String, Object?>)['background'] =
          'black';
      expect(
        _codes(Video3dScene.parse(badColor).issues),
        contains('video3d_scene_background_invalid'),
      );

      final badShape = _validScene()..['environment'] = <Object?>[];
      expect(
        _codes(Video3dScene.parse(badShape).issues),
        contains('video3d_scene_environment_invalid'),
      );
    });

    test('非对象 / 版本错误 / nodes 缺失 / nodes 非数组', () {
      expect(
        _codes(Video3dScene.parse(null).issues),
        contains('video3d_scene_not_object'),
      );
      final badVersion = _validScene()..['v'] = 2;
      expect(
        _codes(Video3dScene.parse(badVersion).issues),
        contains('video3d_scene_unsupported_version'),
      );
      final noNodes = _validScene()..remove('nodes');
      expect(
        _codes(Video3dScene.parse(noNodes).issues),
        contains('video3d_scene_nodes_invalid'),
      );
      final badNodes = _validScene()..['nodes'] = 'floor';
      expect(
        _codes(Video3dScene.parse(badNodes).issues),
        contains('video3d_scene_nodes_invalid'),
      );
    });

    test('灯光/相机 id 重复；相机缺 position/target 拒绝', () {
      final duplicateLight = _validScene();
      ((duplicateLight['lights']! as List<Object?>).last!
              as Map<String, Object?>)['id'] =
          'key';
      expect(
        _codes(Video3dScene.parse(duplicateLight).issues),
        contains('video3d_scene_light_id_duplicate'),
      );

      final duplicateCamera = _validScene();
      final cameras = duplicateCamera['cameras']! as List<Object?>;
      final copy = Map<String, Object?>.from(
        cameras.single! as Map<String, Object?>,
      );
      cameras.add(copy);
      expect(
        _codes(Video3dScene.parse(duplicateCamera).issues),
        contains('video3d_scene_camera_id_duplicate'),
      );

      final missingPosition = _validScene();
      ((missingPosition['cameras']! as List<Object?>).single!
              as Map<String, Object?>)
          .remove('position');
      expect(
        _codes(Video3dScene.parse(missingPosition).issues),
        contains('video3d_scene_number_invalid'),
      );
    });

    test('所有问题都是 video3d_ 码 + 人话 message + 文档内 pointer', () {
      final raw = _validScene();
      _nodeAt(raw, 1)['id'] = 'floor';
      _nodeAt(raw, 2)['type'] = 'torus';
      ((raw['cameras']! as List<Object?>).single!
              as Map<String, Object?>)['fov'] =
          0;
      final result = Video3dScene.parse(raw);
      expect(result.issues, isNotEmpty);
      for (final Video3dIssue issue in result.issues) {
        expect(issue.code, startsWith('video3d_'));
        expect(issue.message, isNotEmpty);
        expect(issue.pointer.startsWith('/') || issue.pointer.isEmpty, isTrue);
        expect(
          issue.message.contains('video3d_'),
          isFalse,
          reason: 'message 是人话，不是错误码',
        );
      }
    });
  });

  group('screenplay3d.json 解析/校验', () {
    test('D3 示例合法剧本（相机引用 + from/to 覆盖）', () {
      final result = Video3dScreenplay.parse(_validScreenplay());
      expect(result.issues, isEmpty);
      final screenplay = result.screenplay!;
      expect(screenplay.fps, 30);
      expect(screenplay.format.width, 720);
      expect(screenplay.format.height, 1280);
      expect(screenplay.shots, hasLength(1));
      final shot = screenplay.shots.single;
      expect(shot.id, 's1');
      expect(shot.duration, 5.0);
      expect(shot.camera.id, 'hero');
      expect(shot.camera.moveFrom, <double>[4, 2, 4]);
      expect(shot.camera.moveTo, <double>[3, 2.2, 4]);
      expect(shot.camera.easing, Video3dEasing.easeInOut);
      expect(shot.cues, isEmpty);
      // 没有顶层 duration 时片长派生 = 镜头总时长。
      expect(screenplay.durationSeconds, 5.0);
      expect(screenplay.seed, 0);
    });

    test('fps 必须 30；缺 fps 也拒绝', () {
      for (final Object? fps in <Object?>[24, 29.97, '30', null]) {
        final raw = _validScreenplay();
        if (fps == null) {
          raw.remove('fps');
        } else {
          raw['fps'] = fps;
        }
        expect(
          _codes(Video3dScreenplay.parse(raw).issues),
          contains('video3d_screenplay_fps_invalid'),
        );
      }
    });

    test('format 宽高必须是正整数', () {
      final bad = _validScreenplay();
      bad['format'] = <String, Object?>{'width': 0, 'height': -1};
      expect(
        _codes(Video3dScreenplay.parse(bad).issues),
        contains('video3d_screenplay_format_invalid'),
      );

      final missing = _validScreenplay()..remove('format');
      expect(
        _codes(Video3dScreenplay.parse(missing).issues),
        contains('video3d_screenplay_format_invalid'),
      );
    });

    test('无镜头 / shots 非数组 / 重复镜头 id', () {
      final empty = _validScreenplay()..['shots'] = <Object?>[];
      expect(
        _codes(Video3dScreenplay.parse(empty).issues),
        contains('video3d_screenplay_no_shots'),
      );

      final notList = _validScreenplay()..['shots'] = 'nope';
      expect(
        _codes(Video3dScreenplay.parse(notList).issues),
        contains('video3d_screenplay_shots_invalid'),
      );

      final duplicate = _validScreenplay();
      final shots = duplicate['shots']! as List<Object?>;
      final copy = Map<String, Object?>.from(
        shots.single! as Map<String, Object?>,
      );
      shots.add(copy);
      expect(
        _codes(Video3dScreenplay.parse(duplicate).issues),
        contains('video3d_screenplay_shot_id_duplicate'),
      );
    });

    test('时长：0/负数/非数字拒绝；不足一帧拒绝', () {
      for (final Object? duration in <Object?>[0, -1.0, '5', null]) {
        final raw = _validScreenplay();
        final shot =
            (raw['shots']! as List<Object?>).single! as Map<String, Object?>;
        if (duration == null) {
          shot.remove('duration');
        } else {
          shot['duration'] = duration;
        }
        expect(
          _codes(Video3dScreenplay.parse(raw).issues),
          contains('video3d_screenplay_shot_duration_invalid'),
        );
      }

      final tooShort = _validScreenplay();
      ((tooShort['shots']! as List<Object?>).single!
              as Map<String, Object?>)['duration'] =
          0.01;
      expect(
        _codes(Video3dScreenplay.parse(tooShort).issues),
        contains('video3d_screenplay_shot_too_short'),
      );
    });

    test('镜头相机：引用 / from-to 覆盖 / 二者并存都接受；缺相机拒绝', () {
      // id 固定相机。
      final fixed = _validScreenplay(withMove: false);
      expect(Video3dScreenplay.parse(fixed).screenplay, isNotNull);
      expect(
        Video3dScreenplay.parse(fixed).screenplay!.shots.single.camera.hasMove,
        isFalse,
      );

      // 纯 from/to 覆盖（不引用场景相机）。
      final override = _validScreenplay();
      final shot =
          (override['shots']! as List<Object?>).single! as Map<String, Object?>;
      shot['camera'] = <String, Object?>{
        'move': <String, Object?>{
          'from': <double>[0, 1, 0],
          'to': <double>[1, 1, 0],
        },
      };
      expect(Video3dScreenplay.parse(override).screenplay, isNotNull);

      // 两个都没有。
      final missing = _validScreenplay();
      ((missing['shots']! as List<Object?>).single! as Map<String, Object?>)
          .remove('camera');
      expect(
        _codes(Video3dScreenplay.parse(missing).issues),
        contains('video3d_screenplay_shot_camera_invalid'),
      );
      final empty = _validScreenplay();
      ((empty['shots']! as List<Object?>).single!
              as Map<String, Object?>)['camera'] =
          <String, Object?>{};
      expect(
        _codes(Video3dScreenplay.parse(empty).issues),
        contains('video3d_screenplay_shot_camera_missing'),
      );
    });

    test('镜头相机 move 缺 from/to、坏 easing、坏 target', () {
      final badMove = _validScreenplay();
      final camera = <String, Object?>{
        'move': <String, Object?>{
          'from': <double>[1, 2, 3],
        },
      };
      ((badMove['shots']! as List<Object?>).single!
              as Map<String, Object?>)['camera'] =
          camera;
      expect(
        _codes(Video3dScreenplay.parse(badMove).issues),
        contains('video3d_screenplay_camera_move_invalid'),
      );

      for (final Object? easing in <Object?>['bounce', 3]) {
        final raw = _validScreenplay();
        final move =
            (((raw['shots']! as List<Object?>).single!
                        as Map<String, Object?>)['camera']!
                    as Map<String, Object?>)['move']!
                as Map<String, Object?>;
        move['easing'] = easing;
        expect(
          _codes(Video3dScreenplay.parse(raw).issues),
          contains('video3d_screenplay_camera_easing_invalid'),
        );
      }

      final badTarget = _validScreenplay();
      final move =
          (((badTarget['shots']! as List<Object?>).single!
                      as Map<String, Object?>)['camera']!
                  as Map<String, Object?>)['move']!
              as Map<String, Object?>;
      move['target'] = <double>[0, double.nan, 0];
      expect(
        _codes(Video3dScreenplay.parse(badTarget).issues),
        contains('video3d_screenplay_camera_move_invalid'),
      );
    });

    test('cues 必须是数组；shot 场景时间窗形状校验', () {
      final badCues = _validScreenplay();
      ((badCues['shots']! as List<Object?>).single!
              as Map<String, Object?>)['cues'] =
          'clap';
      expect(
        _codes(Video3dScreenplay.parse(badCues).issues),
        contains('video3d_screenplay_shot_cues_invalid'),
      );

      final badWindow = _validScreenplay();
      ((badWindow['shots']! as List<Object?>).single!
          as Map<String, Object?>)['scene'] = <String, Object?>{
        'from': -1.0,
        'to': 0.0,
      };
      expect(
        _codes(Video3dScreenplay.parse(badWindow).issues),
        contains('video3d_screenplay_shot_scene_range_invalid'),
      );
    });

    test('seed 必须是非负整数（缺省 0）', () {
      for (final Object? seed in <Object?>[-1, 1.5, 'abc']) {
        final raw = _validScreenplay()..['seed'] = seed;
        expect(
          _codes(Video3dScreenplay.parse(raw).issues),
          contains('video3d_screenplay_seed_invalid'),
        );
      }
      final noSeed = _validScreenplay()..remove('seed');
      expect(Video3dScreenplay.parse(noSeed).screenplay!.seed, 0);
    });

    test('非对象 / 版本错误', () {
      expect(
        _codes(Video3dScreenplay.parse(null).issues),
        contains('video3d_screenplay_not_object'),
      );
      expect(
        _codes(Video3dScreenplay.parse(<Object?>[]).issues),
        contains('video3d_screenplay_not_object'),
      );
      final badVersion = _validScreenplay()..['v'] = 2;
      expect(
        _codes(Video3dScreenplay.parse(badVersion).issues),
        contains('video3d_screenplay_unsupported_version'),
      );
    });
  });

  group('verifyVideo3d 联合校验', () {
    test('D3 示例成对校验通过', () {
      final verification = verifyVideo3d(_validScene(), _validScreenplay());
      expect(verification.verified, isTrue);
      expect(verification.checks, isEmpty);
      expect(verification.scene, isNotNull);
      expect(verification.screenplay, isNotNull);
    });

    test('镜头引用的相机不存在 → camera_missing', () {
      final screenplay = _validScreenplay(withMove: false);
      final camera =
          (((screenplay['shots']! as List<Object?>).single!
                  as Map<String, Object?>)['camera']!)
              as Map<String, Object?>;
      camera['id'] = 'ghost';
      final verification = verifyVideo3d(_validScene(), screenplay);
      expect(verification.verified, isFalse);
      final codes = _codes(verification.checks);
      expect(codes, contains('video3d_screenplay_camera_missing'));
      expect(_pointers(verification.checks), contains('/shots/0/camera/id'));
    });

    test('纯 from/to 覆盖不要求相机引用（scene 无 cameras 也通过）', () {
      final sceneWithoutCameras = _validScene()..remove('cameras');
      final screenplay = _validScreenplay();
      final shot =
          (screenplay['shots']! as List<Object?>).single!
              as Map<String, Object?>;
      shot['camera'] = <String, Object?>{
        'move': <String, Object?>{
          'from': <double>[0, 1, 0],
          'to': <double>[1, 1, 0],
        },
      };
      expect(verifyVideo3d(sceneWithoutCameras, screenplay).verified, isTrue);
    });

    test('镜头总时长与片长不一致 → duration_mismatch；容差内通过', () {
      final mismatch = verifyVideo3d(
        _validScene(),
        _validScreenplay(duration: 4.0),
      );
      expect(mismatch.verified, isFalse);
      expect(
        _codes(mismatch.checks),
        contains('video3d_screenplay_duration_mismatch'),
      );

      final withinTolerance = verifyVideo3d(
        _validScene(),
        _validScreenplay(duration: 5.0 + 5e-10),
      );
      expect(withinTolerance.verified, isTrue);

      final beyondTolerance = verifyVideo3d(
        _validScene(),
        _validScreenplay(duration: 5.0 + 1e-3),
      );
      expect(beyondTolerance.verified, isFalse);
    });

    test('scene 与 screenplay 问题同时收集（不 fail-fast）', () {
      final scene = _validScene();
      (_nodeAt(scene, 0)['material']! as Map<String, Object?>)['color'] =
          'black';
      final screenplay = _validScreenplay()..['fps'] = 24;
      final verification = verifyVideo3d(scene, screenplay);
      expect(verification.verified, isFalse);
      expect(
        _codes(verification.checks),
        containsAll(<String>[
          'video3d_scene_color_invalid',
          'video3d_screenplay_fps_invalid',
        ]),
      );
      expect(
        verification.checks.map((Video3dIssue issue) => issue.pointer).toSet(),
        containsAll(<String>['/nodes/0/material/color', '/fps']),
      );
    });

    test('toJson 形状：verified + {pointer, code, message}[]', () {
      final ok = verifyVideo3d(_validScene(), _validScreenplay()).toJson();
      expect(ok['verified'], isTrue);
      expect(ok['checks'], isEmpty);
      expect(ok.keys, containsAll(<String>['verified', 'checks']));

      final bad = verifyVideo3d(
        _validScene(),
        _validScreenplay()..['fps'] = 24,
      ).toJson();
      expect(bad['verified'], isFalse);
      final checks = bad['checks']! as List<Object?>;
      final check = checks.single! as Map<String, Object?>;
      expect(check.keys, containsAll(<String>['pointer', 'code', 'message']));
      expect(check['code'], 'video3d_screenplay_fps_invalid');
      expect(check['pointer'], '/fps');
      final message = check['message']! as String;
      expect(message, isNotEmpty, reason: '必须是人话，不是裸错误码');
      expect(message.contains('30'), isTrue);
    });
  });
}
