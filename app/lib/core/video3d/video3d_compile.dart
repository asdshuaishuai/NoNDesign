/// 3D 视频编译层：`scene3d.json` → 确定性 `src/scene.js` 文本，
/// `screenplay3d.json` → 整数帧时间表。
///
/// 契约见 `docs/design/video3d-contract.md` / `docs/design/video3d-execution.md`：
/// * 两份 JSON 是事实源，本层产物是派生；同输入两次编译**字节相同**；
/// * 编译不得引入随机/时间戳/wall clock（所有随机后续由 screenplay 的 seed 驱动），
///   因此输出只由模型字段决定；
/// * 屏幕上的画面只由「场景 + 镜头 + 帧号」决定：帧表全部是整数帧，不做浮点拍点；
/// * 校验失败时禁止调用本层（先走 `verifyVideo3d`，模型只会从零问题输入构造出来）。
///
/// 本层是纯 Dart、无 IO；执行面（self-contained HTML/WebView）是后续批次。
library;

import 'video3d_contract.dart';

/// `src/scene.js` 的函数名（执行面按此 import；与 3D 建模 scene 编译器同族）。
const String video3dSceneBuildFunction = 'build';

/// 编译 `scene3d.json` 模型到确定性 `src/scene.js` 文本。
///
/// 输出约定（执行面契约，不随预览页变化）：
/// * 每个节点 `mesh.name = <id>`（证据/检查用名字锚定节点）；
/// * 几何只覆盖 box/sphere/cylinder/plane 四种基础图元；
/// * 材质是 `MeshStandardMaterial`（color/roughness/metalness）；
/// * 灯光覆盖 directional/point/ambient，相机覆盖 PerspectiveCamera；
/// * 父子挂接在全部 mesh 建好之后统一做（父节点可以排在子节点之后）；
/// * 返回 `{ nodes, cameras, metrics }`，供预览页/证据层消费。
///
/// 注意：函数只读取模型字段，不读系统状态，所以同输入必然同字节。
String compileVideo3dScene(Video3dScene scene) {
  final StringBuffer out = StringBuffer();
  out.writeln('// Generated from scene3d.json by NaN.');
  out.writeln(
    '// Deterministic build: same scene3d.json input => byte-identical',
  );
  out.writeln('// output. Do not edit by hand (edit scene3d.json instead).');
  out.writeln(
    '// contract: video3d.scene/1 | nodes: ${scene.nodes.length} | '
    'lights: ${scene.lights.length} | cameras: ${scene.cameras.length}',
  );
  out.writeln(
    'export default function $video3dSceneBuildFunction(THREE, scene, camera) {',
  );
  out.writeln('  const nodes = Object.create(null);');
  out.writeln('  const cameras = Object.create(null);');
  out.writeln();
  out.writeln('  function geometry(node) {');
  out.writeln('    switch (node.type) {');
  out.writeln(
    "      case 'box': return new THREE.BoxGeometry(node.size[0], node.size[1], node.size[2]);",
  );
  out.writeln(
    "      case 'sphere': return new THREE.SphereGeometry(node.size[0], 24, 16);",
  );
  out.writeln(
    "      case 'cylinder': return new THREE.CylinderGeometry(node.size[0], node.size[1], node.size[2], 24);",
  );
  out.writeln(
    "      case 'plane': return new THREE.PlaneGeometry(node.size[0], node.size[1]);",
  );
  out.writeln(
    "      default: throw new Error('unsupported geometry: ' + node.type);",
  );
  out.writeln('    }');
  out.writeln('  }');
  out.writeln();
  out.writeln('  function material(node) {');
  out.writeln('    return new THREE.MeshStandardMaterial({');
  out.writeln('      color: new THREE.Color(node.color),');
  out.writeln('      roughness: node.roughness,');
  out.writeln('      metalness: node.metalness,');
  out.writeln('      name: node.id,');
  out.writeln('    });');
  out.writeln('  }');
  out.writeln();
  out.writeln('  const nodeDefs = [');
  for (final Video3dNode node in scene.nodes) {
    out.writeln('    {');
    out.writeln("      id: '${_js(node.id)}', type: '${node.type.name}',");
    out.writeln('      size: [${_nums(node.size)}],');
    out.writeln(
      '      position: [${_nums(node.position)}], '
      'rotation: [${_nums(node.rotation)}], '
      'scale: [${_nums(node.scale)}],',
    );
    final Video3dMaterial material = node.material;
    out.writeln(
      "      color: '${_js(material.color)}', "
      'roughness: ${_num(material.roughness)}, '
      'metalness: ${_num(material.metalness)},',
    );
    out.writeln(
      '      parent: ${node.parent == null ? 'null' : "'${_js(node.parent!)}'"},',
    );
    out.writeln('    },');
  }
  out.writeln('  ];');
  out.writeln();
  out.writeln('  const lightDefs = [');
  for (final Video3dLight light in scene.lights) {
    out.writeln('    {');
    out.writeln(
      '      name: ${light.id == null ? 'null' : "'${_js(light.id!)}'"}, '
      "type: '${light.type.name}',",
    );
    out.writeln(
      "      intensity: ${_num(light.intensity)}, "
      "color: '${_js(light.color)}',",
    );
    out.writeln(
      '      position: ${light.position == null ? 'null' : '[${_nums(light.position!)}]'}, '
      'target: ${light.target == null ? 'null' : '[${_nums(light.target!)}]'},',
    );
    out.writeln('    },');
  }
  out.writeln('  ];');
  out.writeln();
  out.writeln('  const cameraDefs = [');
  for (final Video3dCamera cameraDef in scene.cameras) {
    out.writeln('    {');
    out.writeln("      id: '${_js(cameraDef.id)}',");
    out.writeln(
      '      position: [${_nums(cameraDef.position)}], '
      'target: [${_nums(cameraDef.target)}],',
    );
    out.writeln('      fov: ${_num(cameraDef.fov)},');
    out.writeln('    },');
  }
  out.writeln('  ];');
  out.writeln();
  out.writeln('  function nodeMesh(node) {');
  out.writeln(
    '    const mesh = new THREE.Mesh(geometry(node), material(node));',
  );
  out.writeln('    mesh.name = node.id;');
  out.writeln(
    '    mesh.position.set(node.position[0], node.position[1], node.position[2]);',
  );
  out.writeln('    mesh.rotation.set(');
  out.writeln('      THREE.MathUtils.degToRad(node.rotation[0]),');
  out.writeln('      THREE.MathUtils.degToRad(node.rotation[1]),');
  out.writeln('      THREE.MathUtils.degToRad(node.rotation[2]));');
  out.writeln(
    '    mesh.scale.set(node.scale[0], node.scale[1], node.scale[2]);',
  );
  out.writeln('    return mesh;');
  out.writeln('  }');
  out.writeln();
  out.writeln('  for (const node of nodeDefs) {');
  out.writeln('    const mesh = nodeMesh(node);');
  out.writeln('    nodes[node.id] = mesh;');
  out.writeln('  }');
  out.writeln();
  out.writeln('  for (const node of nodeDefs) {');
  out.writeln('    const mesh = nodes[node.id];');
  out.writeln(
    '    if (node.parent) nodes[node.parent].add(mesh); else scene.add(mesh);',
  );
  out.writeln('  }');
  out.writeln();
  out.writeln('  function sceneLight(def) {');
  out.writeln("    if (def.type === 'ambient') {");
  out.writeln(
    '      return new THREE.AmbientLight(new THREE.Color(def.color), def.intensity);',
  );
  out.writeln('    }');
  out.writeln("    if (def.type === 'directional') {");
  out.writeln(
    '      const light = new THREE.DirectionalLight(new THREE.Color(def.color), def.intensity);',
  );
  out.writeln(
    '      if (def.position) light.position.set(def.position[0], def.position[1], def.position[2]);',
  );
  out.writeln(
    '      if (def.target) light.target.position.set(def.target[0], def.target[1], def.target[2]);',
  );
  out.writeln('      scene.add(light.target);');
  out.writeln('      return light;');
  out.writeln('    }');
  out.writeln(
    '    const light = new THREE.PointLight(new THREE.Color(def.color), def.intensity);',
  );
  out.writeln(
    '    if (def.position) light.position.set(def.position[0], def.position[1], def.position[2]);',
  );
  out.writeln('    return light;');
  out.writeln('  }');
  out.writeln();
  out.writeln('  for (const def of lightDefs) {');
  out.writeln('    const light = sceneLight(def);');
  out.writeln('    if (def.name !== null) light.name = def.name;');
  out.writeln('    scene.add(light);');
  out.writeln('  }');
  out.writeln();
  out.writeln('  for (const def of cameraDefs) {');
  out.writeln(
    '    const cam = new THREE.PerspectiveCamera(def.fov, 1, 0.1, 500);',
  );
  out.writeln('    cam.name = def.id;');
  out.writeln(
    '    cam.position.set(def.position[0], def.position[1], def.position[2]);',
  );
  out.writeln('    cam.lookAt(def.target[0], def.target[1], def.target[2]);');
  out.writeln('    cameras[def.id] = cam;');
  out.writeln('  }');
  out.writeln();
  out.writeln('  if (camera && cameraDefs.length > 0) {');
  out.writeln('    const first = cameraDefs[0];');
  out.writeln('    camera.name = first.id;');
  out.writeln('    camera.fov = first.fov;');
  out.writeln('    camera.updateProjectionMatrix();');
  out.writeln(
    '    camera.position.set(first.position[0], first.position[1], first.position[2]);',
  );
  out.writeln(
    '    camera.lookAt(first.target[0], first.target[1], first.target[2]);',
  );
  out.writeln('  }');
  out.writeln();
  if (scene.environment?.background != null) {
    out.writeln(
      "  scene.background = new THREE.Color('${_js(scene.environment!.background!)}');",
    );
    out.writeln();
  }
  out.writeln('  return {');
  out.writeln('    nodes: nodes,');
  out.writeln('    cameras: cameras,');
  out.writeln('    metrics: {');
  out.writeln('      scene_nodes: ${scene.nodes.length},');
  out.writeln('      scene_lights: ${scene.lights.length},');
  out.writeln('      scene_cameras: ${scene.cameras.length},');
  out.writeln("      source: 'scene3d.json',");
  out.writeln('    },');
  out.writeln('  };');
  out.writeln('}');
  return out.toString();
}

/// 一个镜头在整数帧表里的位置：`[startFrame, endFrame)` 左闭右开。
final class Video3dShotFrames {
  const Video3dShotFrames({
    required this.id,
    required this.startFrame,
    required this.frameCount,
    this.cameraId,
  });

  final String id;

  /// 起始帧（含）。
  final int startFrame;

  /// 帧数（≥ 1；v1 契约不允许不可见的零帧镜头）。
  final int frameCount;

  /// 镜头引用的相机 id（纯 from/to 覆盖时为 null）。
  final String? cameraId;

  /// 结束帧（不含）：`startFrame + frameCount`。
  int get endFrame => startFrame + frameCount;

  bool contains(int frame) => frame >= startFrame && frame < endFrame;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'start_frame': startFrame,
    'frame_count': frameCount,
    'end_frame': endFrame,
    if (cameraId != null) 'camera_id': cameraId,
  };
}

/// `screenplay3d.json` 编译出的整数帧时间表（全片覆盖、不重叠、无浮点拍点）。
final class Video3dTimeline {
  const Video3dTimeline({
    required this.fps,
    required this.totalFrames,
    required this.durationSeconds,
    required this.shots,
  });

  final int fps;

  /// 总帧数 = `floor(片长 × fps)`（片长已在契约层与镜头总时长对齐）。
  final int totalFrames;
  final double durationSeconds;
  final List<Video3dShotFrames> shots;

  /// 帧号 → 所属镜头；越界返回 null（证据取帧/检查用，不猜）。
  Video3dShotFrames? shotAt(int frame) {
    if (frame < 0 || frame >= totalFrames) return null;
    int low = 0;
    int high = shots.length - 1;
    while (low <= high) {
      final int mid = (low + high) >> 1;
      final Video3dShotFrames shot = shots[mid];
      if (frame < shot.startFrame) {
        high = mid - 1;
      } else if (frame >= shot.endFrame) {
        low = mid + 1;
      } else {
        return shot;
      }
    }
    return null;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'fps': fps,
    'total_frames': totalFrames,
    'duration_seconds': durationSeconds,
    'shots': shots
        .map((Video3dShotFrames shot) => shot.toJson())
        .toList(growable: false),
  };
}

/// 编译 `screenplay3d.json` 模型到整数帧时间表（D3 §3/§4）。
///
/// 规则：`frameIndex = floor(t × fps)`，镜头边界取累积时长的整数帧；最后一个
/// 镜头的结束帧钉在 `totalFrames`，因此帧表**覆盖全片、无空洞、不重叠**。
/// 秒→帧换算带一个 1e-6 帧的浮点误差修正（只影响恰好落在整数帧边界前的
/// 累加误差，例如 0.3 + 0.6 = 0.8999999999999999，不会吞掉一帧）。
Video3dTimeline compileVideo3dTimeline(Video3dScreenplay screenplay) {
  final int fps = screenplay.fps;
  if (fps <= 0) {
    throw StateError('screenplay.fps 必须为正整数（契约层要求 30）');
  }
  final int totalFrames = _frameAt(screenplay.durationSeconds, fps);
  if (totalFrames <= 0) {
    throw StateError('screenplay 片长不足一帧，不能编译时间表（先跑 verifyVideo3d）');
  }
  final List<Video3dShotFrames> shots = <Video3dShotFrames>[];
  double cumulativeSeconds = 0;
  int previousBoundary = 0;
  for (int i = 0; i < screenplay.shots.length; i++) {
    final Video3dShot shot = screenplay.shots[i];
    cumulativeSeconds += shot.duration;
    final bool isLast = i == screenplay.shots.length - 1;
    final int boundary = isLast
        ? totalFrames
        : _frameAt(cumulativeSeconds, fps);
    final int frameCount = boundary - previousBoundary;
    if (frameCount <= 0) {
      throw StateError('镜头 ${shot.id} 在帧表里没有帧（时长不足一帧？）：请求先通过契约校验');
    }
    shots.add(
      Video3dShotFrames(
        id: shot.id,
        startFrame: previousBoundary,
        frameCount: frameCount,
        cameraId: shot.camera.id,
      ),
    );
    previousBoundary = boundary;
  }
  return Video3dTimeline(
    fps: fps,
    totalFrames: totalFrames,
    durationSeconds: screenplay.durationSeconds,
    shots: shots,
  );
}

/// 秒 → 整数帧号：`floor(t × fps)`，并修正极其贴近整数帧边界的浮点累加误差。
///
/// 修正阈值是 1e-6 帧（约 3.3e-8 秒），比契约允许的 1e-9 秒时长容差略宽，
/// 所以正常输入下严格等价于 floor；它只用来吃掉 `0.3 + 0.6` 这类表示误差。
int _frameAt(double seconds, int fps) {
  final double scaled = seconds * fps;
  if (!scaled.isFinite) {
    throw StateError('时间 × fps 超出可表示范围：先跑 verifyVideo3d');
  }
  final int base = scaled.floor();
  final double remainder = scaled - base.toDouble();
  if (remainder >= 1.0 - _frameArtifactTolerance) return base + 1;
  return base;
}

/// 浮点误差修正阈值（帧）：只吸收表示误差，不改变正常的 floor 语义。
const double _frameArtifactTolerance = 1e-6;

/// 数值 → JS 字面量（确定性：整数不带小数点，其余用 double 的最短往返表示；
/// `-0` 归一成 `0`，避免不同来源的零写出不同字节）。
String _num(double value) {
  if (value == 0) return '0';
  if (value == value.roundToDouble() && value.abs() < 1e15) {
    return value.toStringAsFixed(0);
  }
  return value.toString();
}

String _nums(List<double> values) =>
    values.map((double value) => _num(value)).join(', ');

/// 字符串 → JS 单引号字面量内容（id / 颜色都是受限字符串，仍做转义兜底）。
String _js(String value) => value
    .replaceAll('\\', '\\\\')
    .replaceAll("'", "\\'")
    .replaceAll('\n', '\\n')
    .replaceAll('\r', '\\r');
