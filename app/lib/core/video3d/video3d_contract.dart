/// 3D 视频数据契约 v1（D3 草案落地）：`scene3d.json` / `screenplay3d.json`
/// 的模型、解析与校验。
///
/// 契约见 `docs/design/video3d-contract.md`（本轮权威输入）：
/// * 两份 JSON 是 3D 视频项目的**唯一事实源**；编译产物（JS/HTML/帧证据）只是派生；
/// * agent 只写 JSON，不写 JS/React；
/// * 校验只**收集问题、不 fail-fast**，问题形如 `pointer + code + message`（人话，
///   带怎么修的一句话）；失败时不产出可编译模型（`scene` / `screenplay` 为 null）；
/// * 确定性纪律：同一输入两次编译字节相同（见 `video3d_compile.dart`），因此本层
///   在解析时就拒绝 NaN/Infinity、非整数帧上限等无法稳定编译的输入。
///
/// 本层是纯 Dart（无 IO / 无 Flutter / 无引擎），读写与预览由后续批次接线。
library;

import '../creative/creative_schema.dart';

/// 契约版本（`v` 字段唯一合法值）。
const int video3dVersion = 1;

/// 固定帧率：v1 不混用 24/60（见 D3 §3）。
const int video3dFps = creativeVideoFps;

/// `scene3d.json` 节点上限（D3 §2）。
const int video3dMaxNodes = 256;

/// 相机垂直视场角允许区间（闭区间，D3 §2）。
const double video3dMinFov = 10;
const double video3dMaxFov = 120;

/// 至少一帧的镜头时长（秒）：v1 所有时间按 30fps 转整数帧，短于一帧的镜头
/// 永远不可见，因此在契约层直接拒绝（`video3d_screenplay_shot_too_short`）。
const double video3dMinShotDuration = 1.0 / video3dFps;

/// 时长比对容差（秒）：镜头总时长与片长的差值在容差内即视为一致（D3 §3）。
const double video3dTimeTolerance = 1e-9;

/// 一条契约问题：文档内 JSON Pointer + 稳定错误码 + 人话（含怎么修）。
///
/// 同一份 `checks` 里 scene 与 screenplay 的 pointer 各自从文档根起算，
/// 由 code 前缀（`video3d_scene_*` / `video3d_screenplay_*`）区分来源。
final class Video3dIssue {
  const Video3dIssue(this.pointer, this.code, this.message);

  /// 文档内 JSON Pointer；根级问题为 `''` 或 `'/xxx'`。
  final String pointer;

  /// 稳定错误码，统一 `video3d_` 前缀（界面按码映射人话/技术详情）。
  final String code;

  /// 人话说明（面向 agent/用户，含修复方向；不出现内部实现细节）。
  final String message;

  Map<String, Object?> toJson() => <String, Object?>{
    'pointer': pointer,
    'code': code,
    'message': message,
  };

  @override
  String toString() => '$code @ $pointer: $message';
}

/// `scene3d.json` 支持的基础几何（v1 只做可程序化校验并确定性编译的图元）。
enum Video3dNodeType { box, sphere, cylinder, plane }

/// 灯光类型（D3 §2：directional / point / ambient）。
enum Video3dLightType { directional, point, ambient }

/// 镜头相机运动缓动（v1 只支持线性与 easeInOut，不支持复杂路径/物理）。
enum Video3dEasing { linear, easeInOut }

/// 材质：PBR 三字段；缺省时用 3D 建模 scene v1 同族的默认值（确定性）。
final class Video3dMaterial {
  const Video3dMaterial({
    this.color = defaultColor,
    this.roughness = defaultRoughness,
    this.metalness = defaultMetalness,
  });

  static const String defaultColor = '#c9a06a';
  static const double defaultRoughness = 0.8;
  static const double defaultMetalness = 0.1;

  final String color;
  final double roughness;
  final double metalness;
}

/// 一个场景节点：几何 + 变换 + 材质 + 父子关系。
///
/// `size` 语义与 3D 建模 scene v1 同族：
/// box `[w,h,d]`；sphere `[r,r,r]`；cylinder `[rTop,rBottom,h]`；
/// plane `[w,d,0]`（第三维可为 0）。
final class Video3dNode {
  const Video3dNode({
    required this.id,
    required this.type,
    required this.size,
    this.position = const <double>[0, 0, 0],
    this.rotation = const <double>[0, 0, 0],
    this.scale = const <double>[1, 1, 1],
    this.material = const Video3dMaterial(),
    this.parent,
    this.asset,
  });

  final String id;
  final Video3dNodeType type;
  final List<double> size;

  /// 平移（米）。
  final List<double> position;

  /// 欧拉角（度，绕 x/y/z；编译时转弧度）。
  final List<double> rotation;
  final List<double> scale;
  final Video3dMaterial material;
  final String? parent;

  /// 项目内相对 glTF 路径；v1 只接受 null（执行面尚未接线 loader）。
  final String? asset;
}

/// 一盏灯。`id` 可选（D3 示例带 id，用于预览页/证据命名；缺省则不命名字段）。
final class Video3dLight {
  const Video3dLight({
    this.id,
    required this.type,
    this.intensity = 1.0,
    this.color = '#ffffff',
    this.position,
    this.target,
  });

  final String? id;
  final Video3dLightType type;
  final double intensity;
  final String color;
  final List<double>? position;
  final List<double>? target;
}

/// 场景相机：position/target 必填，fov 缺省 45°。
final class Video3dCamera {
  const Video3dCamera({
    required this.id,
    required this.position,
    required this.target,
    this.fov = 45.0,
  });

  final String id;
  final List<double> position;
  final List<double> target;
  final double fov;
}

/// 环境：背景色（v1 只保留 `background`，缺省不设背景）。
final class Video3dEnvironment {
  const Video3dEnvironment({this.background});

  final String? background;
}

/// `scene3d.json` v1 的已解析模型（只有零问题输入才会构造出它）。
final class Video3dScene {
  const Video3dScene({
    required this.nodes,
    required this.lights,
    required this.cameras,
    this.units = 'm',
    this.environment,
  });

  /// v1 只支持米。
  final String units;
  final Video3dEnvironment? environment;
  final List<Video3dNode> nodes;
  final List<Video3dLight> lights;
  final List<Video3dCamera> cameras;

  /// 解析 + 校验 `scene3d.json`；问题全部收集，不 fail-fast。
  ///
  /// [scene] 只在没有任何问题时非空——校验失败不得编译进预览（D3 §4）。
  static ({Video3dScene? scene, List<Video3dIssue> issues}) parse(Object? raw) {
    final List<Video3dIssue> issues = <Video3dIssue>[];
    final Map<String, Object?>? root = creativeJsonMap(raw);
    if (root == null) {
      return (
        scene: null,
        issues: <Video3dIssue>[
          const Video3dIssue(
            '',
            'video3d_scene_not_object',
            'scene3d.json 必须是 JSON 对象',
          ),
        ],
      );
    }
    if (creativeInt(root['v']) != video3dVersion) {
      issues.add(
        const Video3dIssue(
          '/v',
          'video3d_scene_unsupported_version',
          'v 必须是 1（当前契约版本）',
        ),
      );
    }

    String units = 'm';
    final Object? rawUnits = root['units'];
    if (rawUnits != null) {
      final String? text = creativeNonEmptyString(rawUnits);
      if (text == 'm') {
        units = 'm';
      } else {
        issues.add(
          const Video3dIssue(
            '/units',
            'video3d_scene_units_unsupported',
            'units 目前只支持米（m）',
          ),
        );
      }
    }

    Video3dEnvironment? environment;
    final Object? rawEnvironment = root['environment'];
    if (rawEnvironment != null) {
      final Map<String, Object?>? envMap = creativeJsonMap(rawEnvironment);
      if (envMap == null) {
        issues.add(
          const Video3dIssue(
            '/environment',
            'video3d_scene_environment_invalid',
            'environment 必须是对象（例如 {"background": "#0b0d12"}）',
          ),
        );
      } else {
        String? background;
        final Object? rawBackground = envMap['background'];
        if (rawBackground != null) {
          final String? text = creativeNonEmptyString(rawBackground);
          if (text == null || !creativeIsHexColor(text)) {
            issues.add(
              const Video3dIssue(
                '/environment/background',
                'video3d_scene_background_invalid',
                'background 必须是 #rrggbb',
              ),
            );
          } else {
            background = text;
          }
        }
        environment = Video3dEnvironment(background: background);
      }
    }

    final List<Video3dNode> nodes = <Video3dNode>[];
    final List<(int, String, String?)> links = <(int, String, String?)>[];
    final Object? rawNodes = root['nodes'];
    if (rawNodes == null) {
      issues.add(
        const Video3dIssue(
          '/nodes',
          'video3d_scene_nodes_invalid',
          'nodes 必须是数组（没有节点就构不成场景）',
        ),
      );
    } else {
      final List<Object?>? nodeList = creativeJsonList(rawNodes);
      if (nodeList == null) {
        issues.add(
          const Video3dIssue(
            '/nodes',
            'video3d_scene_nodes_invalid',
            'nodes 必须是数组',
          ),
        );
      } else {
        if (nodeList.length > video3dMaxNodes) {
          issues.add(
            Video3dIssue(
              '/nodes',
              'video3d_scene_too_many_nodes',
              '节点 ${nodeList.length} 个，超过上限 $video3dMaxNodes 个：删减或拆成多个场景',
            ),
          );
        }
        final Set<String> nodeIds = <String>{};
        for (int i = 0; i < nodeList.length; i++) {
          final String pointer = '/nodes/$i';
          final Map<String, Object?>? item = creativeJsonMap(nodeList[i]);
          if (item == null) {
            issues.add(
              Video3dIssue(
                pointer,
                'video3d_scene_node_invalid',
                '节点必须是 JSON 对象',
              ),
            );
            continue;
          }
          final String? rawId = creativeNonEmptyString(item['id']);
          final bool idValid = rawId != null && creativeIsSnakeCase(rawId);
          if (!idValid) {
            issues.add(
              Video3dIssue(
                '$pointer/id',
                'video3d_scene_node_id_invalid',
                'id 必须是 ASCII snake_case（小写字母开头，只含小写字母/数字/下划线）',
              ),
            );
          } else if (!nodeIds.add(rawId)) {
            issues.add(
              Video3dIssue(
                '$pointer/id',
                'video3d_scene_node_id_duplicate',
                '节点 id 重复：$rawId',
              ),
            );
          }

          final Video3dNodeType? type = creativeEnumByWire<Video3dNodeType>(
            Video3dNodeType.values,
            (Video3dNodeType value) => value.name,
            item['type'],
          );
          if (type == null) {
            issues.add(
              Video3dIssue(
                '$pointer/type',
                'video3d_scene_geometry_unsupported',
                'type 必须是 ${Video3dNodeType.values.map((Video3dNodeType value) => value.name).join('/')}',
              ),
            );
          }

          final List<double>? size = _readVec3(
            item['size'],
            '$pointer/size',
            issues,
            code: 'video3d_scene_size_invalid',
            message: 'size 必须是 3 个有限数字',
          );
          if (size != null && type != null) {
            final int strictAxes = type == Video3dNodeType.plane ? 2 : 3;
            for (int axis = 0; axis < strictAxes; axis++) {
              if (size[axis] <= 0) {
                issues.add(
                  Video3dIssue(
                    '$pointer/size/$axis',
                    'video3d_scene_size_invalid',
                    '尺寸必须为正数（plane 第三维可为 0）',
                  ),
                );
              }
            }
            if (type == Video3dNodeType.plane && size[2] < 0) {
              issues.add(
                Video3dIssue(
                  '$pointer/size/2',
                  'video3d_scene_size_invalid',
                  'plane 第三维必须是 ≥ 0 的有限数字',
                ),
              );
            }
          }

          final List<double> position =
              _readVec3(
                item['position'],
                '$pointer/position',
                issues,
                required: false,
                message: 'position 必须是 3 个有限数字',
              ) ??
              const <double>[0, 0, 0];
          final List<double> rotation =
              _readVec3(
                item['rotation'],
                '$pointer/rotation',
                issues,
                required: false,
                message: 'rotation 必须是 3 个有限数字（度）',
              ) ??
              const <double>[0, 0, 0];
          final List<double> scale =
              _readVec3(
                item['scale'],
                '$pointer/scale',
                issues,
                required: false,
                message: 'scale 必须是 3 个有限数字',
              ) ??
              const <double>[1, 1, 1];

          final Video3dMaterial material = _readMaterial(
            item['material'],
            '$pointer/material',
            issues,
          );

          String? parent;
          final Object? rawParent = item['parent'];
          if (rawParent != null) {
            final String? text = creativeNonEmptyString(rawParent);
            if (text == null || !creativeIsSnakeCase(text)) {
              issues.add(
                Video3dIssue(
                  '$pointer/parent',
                  'video3d_scene_parent_invalid',
                  'parent 必须是另一个节点的 snake_case id，或 null',
                ),
              );
            } else {
              parent = text;
            }
          }

          String? asset;
          final Object? rawAsset = item['asset'];
          if (rawAsset != null) {
            final String? text = creativeNonEmptyString(rawAsset);
            if (text == null ||
                !creativeIsSafeRelativePath(text) ||
                !(text.endsWith('.gltf') || text.endsWith('.glb'))) {
              issues.add(
                Video3dIssue(
                  '$pointer/asset',
                  'video3d_scene_asset_invalid',
                  'asset 必须是项目内相对路径的 .gltf/.glb 文件，或 null',
                ),
              );
            } else {
              // v1 执行面还没有 glTF loader：接受路径也不算数，显性拒绝而不是静默丢内容。
              issues.add(
                Video3dIssue(
                  '$pointer/asset',
                  'video3d_scene_asset_unsupported',
                  'v1 暂不支持外部模型资产，asset 必须为 null（先全部用基础几何）',
                ),
              );
              asset = text;
            }
          }

          if (idValid && type != null && size != null) {
            nodes.add(
              Video3dNode(
                id: rawId,
                type: type,
                size: size,
                position: position,
                rotation: rotation,
                scale: scale,
                material: material,
                parent: parent,
                asset: asset,
              ),
            );
            links.add((i, rawId, parent));
          }
        }

        // parent 存在性 + 无环（在整棵节点表解析完之后统一查，不 fail-fast）。
        final Map<String, String?> parents = <String, String?>{};
        for (final (int _, String id, String? parent) in links) {
          parents.putIfAbsent(id, () => parent);
        }
        for (final (int index, String id, String? parent) in links) {
          final String pointer = '/nodes/$index/parent';
          if (parent != null && !parents.containsKey(parent)) {
            issues.add(
              Video3dIssue(
                pointer,
                'video3d_scene_parent_missing',
                '节点 $id 的 parent $parent 不存在：parent 必须指向已声明的节点 id',
              ),
            );
          }
          // 沿 parent 链最多走节点数次；再长必成环。
          String? cursor = parent;
          int depth = 0;
          while (cursor != null && depth <= parents.length) {
            if (cursor == id) {
              issues.add(
                Video3dIssue(
                  pointer,
                  'video3d_scene_parent_cycle',
                  '节点 $id 的父子关系成环：把 parent 链改成树',
                ),
              );
              break;
            }
            cursor = parents[cursor];
            depth++;
          }
        }
      }
    }

    final List<Video3dLight> lights = <Video3dLight>[];
    final Object? rawLights = root['lights'];
    if (rawLights != null) {
      final List<Object?>? lightList = creativeJsonList(rawLights);
      if (lightList == null) {
        issues.add(
          const Video3dIssue(
            '/lights',
            'video3d_scene_lights_invalid',
            'lights 必须是数组',
          ),
        );
      } else {
        final Set<String> lightIds = <String>{};
        for (int i = 0; i < lightList.length; i++) {
          final String pointer = '/lights/$i';
          final Video3dLight? light = _readLight(lightList[i], pointer, issues);
          if (light == null) continue;
          final String? lightId = light.id;
          if (lightId != null && !lightIds.add(lightId)) {
            issues.add(
              Video3dIssue(
                '$pointer/id',
                'video3d_scene_light_id_duplicate',
                '灯光 id 重复：$lightId',
              ),
            );
          }
          lights.add(light);
        }
      }
    }

    final List<Video3dCamera> cameras = <Video3dCamera>[];
    final Object? rawCameras = root['cameras'];
    if (rawCameras != null) {
      final List<Object?>? cameraList = creativeJsonList(rawCameras);
      if (cameraList == null) {
        issues.add(
          const Video3dIssue(
            '/cameras',
            'video3d_scene_cameras_invalid',
            'cameras 必须是数组',
          ),
        );
      } else {
        final Set<String> cameraIds = <String>{};
        for (int i = 0; i < cameraList.length; i++) {
          final String pointer = '/cameras/$i';
          final Map<String, Object?>? item = creativeJsonMap(cameraList[i]);
          if (item == null) {
            issues.add(
              Video3dIssue(
                pointer,
                'video3d_scene_camera_invalid',
                '相机必须是 JSON 对象',
              ),
            );
            continue;
          }
          final String? id = creativeNonEmptyString(item['id']);
          if (id == null) {
            issues.add(
              Video3dIssue(
                '$pointer/id',
                'video3d_scene_camera_id_invalid',
                '相机 id 必须是非空字符串（screenplay 用它引用相机）',
              ),
            );
          } else if (!cameraIds.add(id)) {
            issues.add(
              Video3dIssue(
                '$pointer/id',
                'video3d_scene_camera_id_duplicate',
                '相机 id 重复：$id',
              ),
            );
          }
          final List<double>? position = _readVec3(
            item['position'],
            '$pointer/position',
            issues,
            message: '相机 position 必须是 3 个有限数字',
          );
          final List<double>? target = _readVec3(
            item['target'],
            '$pointer/target',
            issues,
            message: '相机 target 必须是 3 个有限数字',
          );
          double fov = 45.0;
          final Object? rawFov = item['fov'];
          if (rawFov != null) {
            final double? value = creativeFiniteDouble(rawFov);
            if (value == null ||
                value < video3dMinFov ||
                value > video3dMaxFov) {
              issues.add(
                Video3dIssue(
                  '$pointer/fov',
                  'video3d_scene_camera_fov_invalid',
                  'fov 必须在 $video3dMinFov–$video3dMaxFov 度之间',
                ),
              );
            } else {
              fov = value;
            }
          }
          if (id != null && position != null && target != null) {
            cameras.add(
              Video3dCamera(
                id: id,
                position: position,
                target: target,
                fov: fov,
              ),
            );
          }
        }
      }
    }

    if (issues.isNotEmpty) {
      return (scene: null, issues: issues);
    }
    return (
      scene: Video3dScene(
        units: units,
        environment: environment,
        nodes: nodes,
        lights: lights,
        cameras: cameras,
      ),
      issues: issues,
    );
  }
}

/// 画幅：宽高必须是正整数像素。
final class Video3dFormat {
  const Video3dFormat({required this.width, required this.height});

  final int width;
  final int height;
}

/// 一个镜头里的相机：可以引用场景相机 id，也可以给出 `move.from/to` 覆盖；
/// 两者同时出现时 `id` 只用于命名/对照（D3 §3 示例即此形态）。
final class Video3dShotCamera {
  const Video3dShotCamera({
    this.id,
    this.moveFrom,
    this.moveTo,
    this.moveTarget,
    this.easing,
  });

  /// 引用的 `scene3d.json` 相机 id（可能为 null：纯 from/to 覆盖）。
  final String? id;
  final List<double>? moveFrom;
  final List<double>? moveTo;
  final List<double>? moveTarget;

  /// 仅在给出 from/to 时有意义；缺省 linear。
  final Video3dEasing? easing;

  bool get hasMove => moveFrom != null && moveTo != null;
}

/// 一个镜头：时长 + 相机 + 可选 cue + 可选场景时间窗。
final class Video3dShot {
  const Video3dShot({
    required this.id,
    required this.duration,
    required this.camera,
    this.cues = const <Object?>[],
    this.sceneFrom,
    this.sceneTo,
  });

  final String id;

  /// 镜头时长（秒，> 0 且至少一帧）。
  final double duration;
  final Video3dShotCamera camera;

  /// v1 只保留字段（不接音频/TTS/VFX），编译时间表不消费。
  final List<Object?> cues;

  /// 可选场景时间窗（秒）；v1 无场景动画，只校验形状以保住前向兼容。
  final double? sceneFrom;
  final double? sceneTo;
}

/// `screenplay3d.json` v1 的已解析模型（只有零问题输入才会构造出它）。
final class Video3dScreenplay {
  const Video3dScreenplay({
    required this.fps,
    required this.format,
    required this.shots,
    required this.durationSeconds,
    this.seed = 0,
  });

  /// v1 固定 30（契约层已强制，保留字段供下游显式消费）。
  final int fps;
  final Video3dFormat format;
  final List<Video3dShot> shots;

  /// 片长（秒）：顶层 `duration` 给出时用它，否则等于镜头总时长。
  final double durationSeconds;

  /// 顶层可选随机种子（缺省 0；所有随机必须种子化，不碰 wall clock）。
  final int seed;

  /// 解析 + 校验 `screenplay3d.json`；问题全部收集，不 fail-fast。
  ///
  /// 片长口径：D3 §3 要求「镜头总时长 = 片长」，但顶层没有单独列出片长字段；
  /// 因此 v1 约定顶层可选 `duration`（秒）为片长——给出时必须与镜头总时长一致
  /// （容差 [video3dTimeTolerance]）；缺省时片长即镜头总时长。
  static ({Video3dScreenplay? screenplay, List<Video3dIssue> issues}) parse(
    Object? raw,
  ) {
    final List<Video3dIssue> issues = <Video3dIssue>[];
    final Map<String, Object?>? root = creativeJsonMap(raw);
    if (root == null) {
      return (
        screenplay: null,
        issues: <Video3dIssue>[
          const Video3dIssue(
            '',
            'video3d_screenplay_not_object',
            'screenplay3d.json 必须是 JSON 对象',
          ),
        ],
      );
    }
    if (creativeInt(root['v']) != video3dVersion) {
      issues.add(
        const Video3dIssue(
          '/v',
          'video3d_screenplay_unsupported_version',
          'v 必须是 1（当前契约版本）',
        ),
      );
    }

    final int? fps = creativeInt(root['fps']);
    if (fps != video3dFps) {
      issues.add(
        Video3dIssue(
          '/fps',
          'video3d_screenplay_fps_invalid',
          'fps 必须是 $video3dFps（v1 固定 30fps）',
        ),
      );
    }

    Video3dFormat? format;
    final Map<String, Object?>? formatMap = creativeJsonMap(root['format']);
    if (formatMap == null) {
      issues.add(
        const Video3dIssue(
          '/format',
          'video3d_screenplay_format_invalid',
          'format 必须是对象，例如 {"width": 720, "height": 1280}',
        ),
      );
    } else {
      final int? width = creativeInt(formatMap['width']);
      final int? height = creativeInt(formatMap['height']);
      if (width == null || width <= 0) {
        issues.add(
          const Video3dIssue(
            '/format/width',
            'video3d_screenplay_format_invalid',
            'format.width 必须是正整数',
          ),
        );
      }
      if (height == null || height <= 0) {
        issues.add(
          const Video3dIssue(
            '/format/height',
            'video3d_screenplay_format_invalid',
            'format.height 必须是正整数',
          ),
        );
      }
      if (width != null && width > 0 && height != null && height > 0) {
        format = Video3dFormat(width: width, height: height);
      }
    }

    int seed = 0;
    final Object? rawSeed = root['seed'];
    if (rawSeed != null) {
      final int? value = creativeInt(rawSeed);
      if (value == null || value < 0) {
        issues.add(
          const Video3dIssue(
            '/seed',
            'video3d_screenplay_seed_invalid',
            'seed 必须是 ≥ 0 的整数（缺省 0）',
          ),
        );
      } else {
        seed = value;
      }
    }

    double? declaredDuration;
    final Object? rawDuration = root['duration'];
    if (rawDuration != null) {
      final double? value = creativeFiniteDouble(rawDuration);
      if (value == null || value <= 0) {
        issues.add(
          const Video3dIssue(
            '/duration',
            'video3d_screenplay_duration_invalid',
            '片长 duration 必须是正的有限数字（秒）',
          ),
        );
      } else {
        declaredDuration = value;
      }
    }

    final List<Video3dShot> shots = <Video3dShot>[];
    double shotsDuration = 0;
    bool durationsComplete = true;
    final Object? rawShots = root['shots'];
    if (rawShots == null) {
      issues.add(
        const Video3dIssue(
          '/shots',
          'video3d_screenplay_shots_invalid',
          'shots 必须是数组',
        ),
      );
    } else {
      final List<Object?>? shotList = creativeJsonList(rawShots);
      if (shotList == null) {
        issues.add(
          const Video3dIssue(
            '/shots',
            'video3d_screenplay_shots_invalid',
            'shots 必须是数组',
          ),
        );
      } else if (shotList.isEmpty) {
        issues.add(
          const Video3dIssue(
            '/shots',
            'video3d_screenplay_no_shots',
            '至少需要一个镜头：加一条 shot（id/duration/camera）',
          ),
        );
      } else {
        final Set<String> shotIds = <String>{};
        for (int i = 0; i < shotList.length; i++) {
          final String pointer = '/shots/$i';
          final Map<String, Object?>? item = creativeJsonMap(shotList[i]);
          if (item == null) {
            issues.add(
              Video3dIssue(
                pointer,
                'video3d_screenplay_shot_invalid',
                '镜头必须是 JSON 对象',
              ),
            );
            durationsComplete = false;
            continue;
          }

          final String? id = creativeNonEmptyString(item['id']);
          if (id == null) {
            issues.add(
              Video3dIssue(
                '$pointer/id',
                'video3d_screenplay_shot_id_invalid',
                '镜头 id 必须是非空字符串',
              ),
            );
          } else if (!shotIds.add(id)) {
            issues.add(
              Video3dIssue(
                '$pointer/id',
                'video3d_screenplay_shot_id_duplicate',
                '镜头 id 重复：$id',
              ),
            );
          }

          final double? duration = creativeFiniteDouble(item['duration']);
          if (duration == null || duration <= 0) {
            issues.add(
              Video3dIssue(
                '$pointer/duration',
                'video3d_screenplay_shot_duration_invalid',
                '镜头时长必须是正的有限数字（秒）',
              ),
            );
            durationsComplete = false;
          } else {
            if (duration < video3dMinShotDuration) {
              issues.add(
                Video3dIssue(
                  '$pointer/duration',
                  'video3d_screenplay_shot_too_short',
                  '镜头时长至少一帧（$video3dFps fps 下约 0.0333 秒），否则这一镜永远不可见',
                ),
              );
            }
            shotsDuration += duration;
          }

          final Video3dShotCamera? camera = _readShotCamera(
            item['camera'],
            '$pointer/camera',
            issues,
          );

          List<Object?> cues = const <Object?>[];
          final Object? rawCues = item['cues'];
          if (rawCues != null) {
            final List<Object?>? cueList = creativeJsonList(rawCues);
            if (cueList == null) {
              issues.add(
                Video3dIssue(
                  '$pointer/cues',
                  'video3d_screenplay_shot_cues_invalid',
                  'cues 必须是数组（v1 只保留字段，内容不解释）',
                ),
              );
            } else {
              cues = List<Object?>.unmodifiable(cueList);
            }
          }

          double? sceneFrom;
          double? sceneTo;
          final Object? rawScene = item['scene'];
          if (rawScene != null) {
            final Map<String, Object?>? sceneMap = creativeJsonMap(rawScene);
            if (sceneMap == null) {
              issues.add(
                Video3dIssue(
                  '$pointer/scene',
                  'video3d_screenplay_shot_scene_invalid',
                  'scene 必须是对象，例如 {"from": 0, "to": 5}',
                ),
              );
            } else {
              final double? from = creativeFiniteDouble(sceneMap['from']);
              final double? to = creativeFiniteDouble(sceneMap['to']);
              if (from == null || from < 0) {
                issues.add(
                  Video3dIssue(
                    '$pointer/scene/from',
                    'video3d_screenplay_shot_scene_range_invalid',
                    'scene.from 必须是 ≥ 0 的有限数字（秒）',
                  ),
                );
              }
              if (to == null || (from != null && to <= from)) {
                issues.add(
                  Video3dIssue(
                    '$pointer/scene/to',
                    'video3d_screenplay_shot_scene_range_invalid',
                    'scene.to 必须是大于 from 的有限数字（秒）',
                  ),
                );
              }
              if (from != null && to != null && from >= 0 && to > from) {
                sceneFrom = from;
                sceneTo = to;
              }
            }
          }

          if (id != null &&
              duration != null &&
              duration > 0 &&
              camera != null) {
            shots.add(
              Video3dShot(
                id: id,
                duration: duration,
                camera: camera,
                cues: cues,
                sceneFrom: sceneFrom,
                sceneTo: sceneTo,
              ),
            );
          }
        }
      }
    }

    if (!shotsDuration.isFinite) {
      issues.add(
        const Video3dIssue(
          '/shots',
          'video3d_screenplay_duration_invalid',
          '镜头总时长超出可表示范围：缩短片长',
        ),
      );
      durationsComplete = false;
    }

    double filmDuration = 0;
    if (declaredDuration != null) {
      filmDuration = declaredDuration;
      if (durationsComplete && shotsDuration.isFinite) {
        final double delta = (declaredDuration - shotsDuration).abs();
        if (delta > video3dTimeTolerance) {
          issues.add(
            Video3dIssue(
              '/duration',
              'video3d_screenplay_duration_mismatch',
              '镜头总时长 ${_formatSeconds(shotsDuration)} 秒与片长 '
                  '${_formatSeconds(declaredDuration)} 秒不一致：调整 shot duration '
                  '或顶层 duration',
            ),
          );
        }
      }
    } else if (durationsComplete &&
        shotsDuration.isFinite &&
        shotsDuration > 0) {
      filmDuration = shotsDuration;
    }

    if (filmDuration > 0 && filmDuration.isFinite) {
      final double frameCount = filmDuration * video3dFps;
      if (!frameCount.isFinite || frameCount.floor() <= 0) {
        issues.add(
          Video3dIssue(
            declaredDuration != null ? '/duration' : '/shots',
            'video3d_screenplay_no_frames',
            '片长不足一帧或超出范围：至少要有 $video3dFps 分之一秒',
          ),
        );
      }
    }

    if (issues.isNotEmpty || format == null || shots.isEmpty) {
      return (screenplay: null, issues: issues);
    }
    return (
      screenplay: Video3dScreenplay(
        fps: video3dFps,
        format: format,
        shots: shots,
        durationSeconds: filmDuration,
        seed: seed,
      ),
      issues: issues,
    );
  }
}

/// 一次联合校验的结果：`verified` + 问题清单（形如 `{pointer, code, message}[]`）。
final class Video3dVerification {
  const Video3dVerification({
    required this.verified,
    required this.checks,
    this.scene,
    this.screenplay,
  });

  /// 两份文档都零问题时才为 true；失败时禁止生成新预览（D3 §4）。
  final bool verified;
  final List<Video3dIssue> checks;

  /// 校验通过时的已解析模型（供编译直接消费）。
  final Video3dScene? scene;
  final Video3dScreenplay? screenplay;

  Map<String, Object?> toJson() => <String, Object?>{
    'verified': verified,
    'checks': checks
        .map((Video3dIssue issue) => issue.toJson())
        .toList(growable: false),
  };
}

/// 联合校验 `scene3d.json` + `screenplay3d.json`（D3 §4 的 `verifyVideo3d`）。
///
/// 除各自的结构校验外，还做跨文档检查：screenplay 里引用的相机 id 必须存在于
/// scene。问题全部收集、不 fail-fast；`checks` 为空即 `verified`。
Video3dVerification verifyVideo3d(Object? sceneRaw, Object? screenplayRaw) {
  final ({Video3dScene? scene, List<Video3dIssue> issues}) sceneResult =
      Video3dScene.parse(sceneRaw);
  final ({Video3dScreenplay? screenplay, List<Video3dIssue> issues})
  screenplayResult = Video3dScreenplay.parse(screenplayRaw);
  final List<Video3dIssue> checks = <Video3dIssue>[
    ...sceneResult.issues,
    ...screenplayResult.issues,
  ];
  final Video3dScene? scene = sceneResult.scene;
  final Video3dScreenplay? screenplay = screenplayResult.screenplay;
  if (scene != null && screenplay != null) {
    final Set<String> cameraIds = <String>{
      for (final Video3dCamera camera in scene.cameras) camera.id,
    };
    for (int i = 0; i < screenplay.shots.length; i++) {
      final Video3dShot shot = screenplay.shots[i];
      final String? reference = shot.camera.id;
      if (reference != null && !cameraIds.contains(reference)) {
        checks.add(
          Video3dIssue(
            '/shots/$i/camera/id',
            'video3d_screenplay_camera_missing',
            '镜头 ${shot.id} 引用的相机 $reference 在 scene3d.json 里不存在',
          ),
        );
      }
    }
  }
  return Video3dVerification(
    verified: checks.isEmpty && scene != null && screenplay != null,
    checks: checks,
    scene: scene,
    screenplay: screenplay,
  );
}

/// 读 3 个有限数字组成的向量；[required] 为 false 时缺省返回 null（不报问题）。
List<double>? _readVec3(
  Object? raw,
  String pointer,
  List<Video3dIssue> issues, {
  bool required = true,
  String code = 'video3d_scene_number_invalid',
  String message = '必须是 3 个有限数字',
}) {
  if (raw == null) {
    if (required) issues.add(Video3dIssue(pointer, code, message));
    return null;
  }
  final List<Object?>? list = creativeJsonList(raw);
  if (list == null || list.length != 3) {
    issues.add(Video3dIssue(pointer, code, message));
    return null;
  }
  final List<double> out = <double>[];
  bool ok = true;
  for (int i = 0; i < list.length; i++) {
    final double? value = creativeFiniteDouble(list[i]);
    if (value == null) {
      issues.add(
        Video3dIssue('$pointer/$i', code, '必须是有限数字（不能是 NaN/Infinity）'),
      );
      out.add(0);
      ok = false;
    } else {
      out.add(value);
    }
  }
  return ok ? out : null;
}

/// 读材质；缺省给同族默认值，问题收集但不阻断其余字段解析。
Video3dMaterial _readMaterial(
  Object? raw,
  String pointer,
  List<Video3dIssue> issues,
) {
  if (raw == null) return const Video3dMaterial();
  final Map<String, Object?>? map = creativeJsonMap(raw);
  if (map == null) {
    issues.add(
      Video3dIssue(pointer, 'video3d_scene_material_invalid', 'material 必须是对象'),
    );
    return const Video3dMaterial();
  }
  String color = Video3dMaterial.defaultColor;
  final Object? rawColor = map['color'];
  if (rawColor != null) {
    final String? text = creativeNonEmptyString(rawColor);
    if (text == null || !creativeIsHexColor(text)) {
      issues.add(
        Video3dIssue(
          '$pointer/color',
          'video3d_scene_color_invalid',
          'color 必须是 #rrggbb（六个十六进制位）',
        ),
      );
    } else {
      color = text;
    }
  }
  double roughness = Video3dMaterial.defaultRoughness;
  final Object? rawRoughness = map['roughness'];
  if (rawRoughness != null) {
    final double? value = creativeFiniteDouble(rawRoughness);
    if (value == null || value < 0 || value > 1) {
      issues.add(
        Video3dIssue(
          '$pointer/roughness',
          'video3d_scene_roughness_invalid',
          'roughness 必须是 0–1 的有限数字',
        ),
      );
    } else {
      roughness = value;
    }
  }
  double metalness = Video3dMaterial.defaultMetalness;
  final Object? rawMetalness = map['metalness'];
  if (rawMetalness != null) {
    final double? value = creativeFiniteDouble(rawMetalness);
    if (value == null || value < 0 || value > 1) {
      issues.add(
        Video3dIssue(
          '$pointer/metalness',
          'video3d_scene_metalness_invalid',
          'metalness 必须是 0–1 的有限数字',
        ),
      );
    } else {
      metalness = value;
    }
  }
  return Video3dMaterial(
    color: color,
    roughness: roughness,
    metalness: metalness,
  );
}

/// 读一盏灯；结构/类型错误时返回 null，其余字段继续收集问题。
Video3dLight? _readLight(
  Object? raw,
  String pointer,
  List<Video3dIssue> issues,
) {
  final Map<String, Object?>? map = creativeJsonMap(raw);
  if (map == null) {
    issues.add(
      Video3dIssue(pointer, 'video3d_scene_light_invalid', '灯光必须是 JSON 对象'),
    );
    return null;
  }
  final Video3dLightType? type = creativeEnumByWire<Video3dLightType>(
    Video3dLightType.values,
    (Video3dLightType value) => value.name,
    map['type'],
  );
  if (type == null) {
    issues.add(
      Video3dIssue(
        '$pointer/type',
        'video3d_scene_light_type_unsupported',
        '灯光 type 必须是 ${Video3dLightType.values.map((Video3dLightType value) => value.name).join('/')}',
      ),
    );
  }
  String? id;
  final Object? rawId = map['id'];
  if (rawId != null) {
    final String? text = creativeNonEmptyString(rawId);
    if (text == null) {
      issues.add(
        Video3dIssue(
          '$pointer/id',
          'video3d_scene_light_id_invalid',
          '灯光 id 必须是非空字符串，或省略',
        ),
      );
    } else {
      id = text;
    }
  }
  double intensity = 1.0;
  final Object? rawIntensity = map['intensity'];
  if (rawIntensity != null) {
    final double? value = creativeFiniteDouble(rawIntensity);
    if (value == null || value < 0) {
      issues.add(
        Video3dIssue(
          '$pointer/intensity',
          'video3d_scene_light_intensity_invalid',
          'intensity 必须是 ≥ 0 的有限数字',
        ),
      );
    } else {
      intensity = value;
    }
  }
  String color = '#ffffff';
  final Object? rawColor = map['color'];
  if (rawColor != null) {
    final String? text = creativeNonEmptyString(rawColor);
    if (text == null || !creativeIsHexColor(text)) {
      issues.add(
        Video3dIssue(
          '$pointer/color',
          'video3d_scene_color_invalid',
          'color 必须是 #rrggbb',
        ),
      );
    } else {
      color = text;
    }
  }
  final List<double>? position = _readVec3(
    map['position'],
    '$pointer/position',
    issues,
    required: false,
    message: 'position 必须是 3 个有限数字',
  );
  final List<double>? target = _readVec3(
    map['target'],
    '$pointer/target',
    issues,
    required: false,
    message: 'target 必须是 3 个有限数字',
  );
  if (type == null) return null;
  return Video3dLight(
    id: id,
    type: type,
    intensity: intensity,
    color: color,
    position: position,
    target: target,
  );
}

/// 读一个镜头的相机字段（id 引用 + 可选 move.from/to/target/easing）。
Video3dShotCamera? _readShotCamera(
  Object? raw,
  String pointer,
  List<Video3dIssue> issues,
) {
  final Map<String, Object?>? map = creativeJsonMap(raw);
  if (map == null) {
    issues.add(
      Video3dIssue(
        pointer,
        'video3d_screenplay_shot_camera_invalid',
        'camera 必须是对象（引用相机 id，或给出 move.from/to）',
      ),
    );
    return null;
  }

  String? cameraId;
  final Object? rawId = map['id'];
  if (rawId != null) {
    final String? text = creativeNonEmptyString(rawId);
    if (text == null) {
      issues.add(
        Video3dIssue(
          '$pointer/id',
          'video3d_screenplay_shot_camera_invalid',
          'camera.id 必须是非空字符串（引用 scene3d.json 的相机 id）',
        ),
      );
    } else {
      cameraId = text;
    }
  }

  List<double>? from;
  List<double>? to;
  List<double>? target;
  Video3dEasing? easing;
  bool hasMove = false;
  final Object? rawMove = map['move'];
  if (rawMove != null) {
    final Map<String, Object?>? moveMap = creativeJsonMap(rawMove);
    if (moveMap == null) {
      issues.add(
        Video3dIssue(
          '$pointer/move',
          'video3d_screenplay_shot_camera_invalid',
          'camera.move 必须是对象',
        ),
      );
    } else {
      hasMove = true;
      from = _readVec3(
        moveMap['from'],
        '$pointer/move/from',
        issues,
        code: 'video3d_screenplay_camera_move_invalid',
        message: 'camera.move.from 必须是 3 个有限数字',
      );
      to = _readVec3(
        moveMap['to'],
        '$pointer/move/to',
        issues,
        code: 'video3d_screenplay_camera_move_invalid',
        message: 'camera.move.to 必须是 3 个有限数字',
      );
      target = _readVec3(
        moveMap['target'],
        '$pointer/move/target',
        issues,
        required: false,
        code: 'video3d_screenplay_camera_move_invalid',
        message: 'camera.move.target 必须是 3 个有限数字',
      );
      final Object? rawEasing = moveMap['easing'];
      if (rawEasing == null) {
        easing = Video3dEasing.linear;
      } else if (rawEasing is String &&
          rawEasing == Video3dEasing.linear.name) {
        easing = Video3dEasing.linear;
      } else if (rawEasing is String &&
          rawEasing == Video3dEasing.easeInOut.name) {
        easing = Video3dEasing.easeInOut;
      } else {
        issues.add(
          Video3dIssue(
            '$pointer/move/easing',
            'video3d_screenplay_camera_easing_invalid',
            'easing 只支持 ${Video3dEasing.values.map((Video3dEasing value) => value.name).join('/')}',
          ),
        );
      }
    }
  }

  if (cameraId == null && !hasMove) {
    issues.add(
      Video3dIssue(
        pointer,
        'video3d_screenplay_shot_camera_missing',
        '镜头必须引用相机 id 或给出 move.from/to',
      ),
    );
  }
  if ((cameraId == null && !hasMove) ||
      (hasMove && (from == null || to == null))) {
    return null;
  }
  if (!hasMove) return Video3dShotCamera(id: cameraId);
  return Video3dShotCamera(
    id: cameraId,
    moveFrom: from,
    moveTo: to,
    moveTarget: target,
    easing: easing ?? Video3dEasing.linear,
  );
}

/// 秒数的人话展示（最多 6 位小数，去尾零）：只用于错误文案。
String _formatSeconds(double value) {
  final String text = value.toStringAsFixed(6);
  return text.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
}
