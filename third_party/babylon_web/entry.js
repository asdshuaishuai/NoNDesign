// 3D 视频预览的 Babylon 渲染适配器（tree-shaken 最小集）。
//
// 只做一件事：把 NoNDesign 的确定性渲染模型（nodes/lights/cameras）+ 每帧相机
// 求解函数（由页面注入，与 three 面共用同一份 `cameraAt`）映射成 Babylon 场景并渲染。
//
// 纪律：
//  * 不联网、不读文件、不使用随机/墙钟——画面只由「场景 + 镜头 + 帧号」决定；
//  * 渲染器身份如实暴露（`babylon_webgl_v9`），不冒充 three 的像素结果；
//  * 只做**降级兜底**：three 可用时永远优先 three（见页面渲染面选择顺序）。
import { Engine } from '@babylonjs/core/Engines/engine.js';
import { Scene } from '@babylonjs/core/scene.js';
import { FreeCamera } from '@babylonjs/core/Cameras/freeCamera.js';
import { Vector3 } from '@babylonjs/core/Maths/math.vector.js';
import { Color3, Color4 } from '@babylonjs/core/Maths/math.color.js';
import { MeshBuilder } from '@babylonjs/core/Meshes/meshBuilder.js';
import { TransformNode } from '@babylonjs/core/Meshes/transformNode.js';
import { StandardMaterial } from '@babylonjs/core/Materials/standardMaterial.js';
import { HemisphericLight } from '@babylonjs/core/Lights/hemisphericLight.js';
import { DirectionalLight } from '@babylonjs/core/Lights/directionalLight.js';
import { PointLight } from '@babylonjs/core/Lights/pointLight.js';
// 几何体构建器是副作用注册（MeshBuilder.CreateBox 等由这些模块挂上）。
import '@babylonjs/core/Meshes/Builders/boxBuilder.js';
import '@babylonjs/core/Meshes/Builders/sphereBuilder.js';
import '@babylonjs/core/Meshes/Builders/cylinderBuilder.js';
import '@babylonjs/core/Meshes/Builders/planeBuilder.js';

const DEG_TO_RAD = Math.PI / 180.0;

function finite(value, fallback) {
  const number = Number(value);
  return isFinite(number) ? number : fallback;
}

function colorOf(hex, fallback) {
  const text = String(hex || '').trim();
  if (/^#[0-9a-fA-F]{6}$/.test(text)) {
    return new Color3(
      parseInt(text.substring(1, 3), 16) / 255.0,
      parseInt(text.substring(3, 5), 16) / 255.0,
      parseInt(text.substring(5, 7), 16) / 255.0,
    );
  }
  return fallback;
}

function sizeOf(node) {
  const raw = node && node.size ? node.size : [];
  const a = Math.abs(finite(raw[0], 0.1)) || 0.1;
  const b = Math.abs(finite(raw[1], 0.1)) || 0.1;
  const c = Math.abs(finite(raw[2], 0.1)) || 0.1;
  return [a, b, c];
}

// 与 compileVideo3dScene 的几何语义逐项对齐：
//   box      → BoxGeometry(s0, s1, s2)      全尺寸
//   sphere   → SphereGeometry(s0, 24, 16)   半径 s0
//   cylinder → CylinderGeometry(s0, s1, s2) rTop s0 / rBottom s1 / height s2
//   plane    → PlaneGeometry(s0, s1)        XY 平面、朝向 +Z
function createMeshFor(type, node, scene) {
  const [a, b, c] = sizeOf(node);
  switch (type) {
    case 'box':
      return MeshBuilder.CreateBox(
        String(node.id),
        { width: a, height: b, depth: c },
        scene,
      );
    case 'sphere':
      return MeshBuilder.CreateSphere(
        String(node.id),
        { diameter: a * 2.0, segments: 24 },
        scene,
      );
    case 'cylinder':
      return MeshBuilder.CreateCylinder(
        String(node.id),
        {
          height: c,
          diameterTop: a * 2.0,
          diameterBottom: b * 2.0,
          tessellation: 24,
        },
        scene,
      );
    case 'plane':
      return MeshBuilder.CreatePlane(
        String(node.id),
        { width: a, height: b },
        scene,
      );
    default:
      return null; // 未知类型：不猜，跳过该节点（页面会把 metrics 回传宿主）
  }
}

export function createVideoRenderer(options) {
  const opts = options || {};
  const canvas = opts.canvas;
  if (!canvas) throw new Error('babylon: canvas missing');
  const width = Math.max(1, Math.floor(finite(opts.width, 720)));
  const height = Math.max(1, Math.floor(finite(opts.height, 1280)));
  const nodes = Array.isArray(opts.nodes) ? opts.nodes : [];
  const lights = Array.isArray(opts.lights) ? opts.lights : [];
  const cameraAt = typeof opts.cameraAt === 'function' ? opts.cameraAt : null;
  if (!cameraAt) throw new Error('babylon: cameraAt missing');

  const engine = new Engine(
    canvas,
    true,
    { preserveDrawingBuffer: true, stencil: false, alpha: false },
    false,
  );
  engine.setHardwareScalingLevel(1);
  engine.setSize(width, height);

  const scene = new Scene(engine);
  const background = colorOf(opts.background, new Color3(0.04, 0.05, 0.07));
  scene.clearColor = new Color4(background.r, background.g, background.b, 1.0);

  const camera = new FreeCamera('video3d-camera', new Vector3(4, 2, 4), scene);
  camera.setTarget(new Vector3(0, 1, 0));
  camera.minZ = 0.1;
  camera.maxZ = 2000;

  // 每个节点一个 TransformNode 承载「位置/旋转/缩放/父子」，几何体挂在下面：
  // plane 的基朝向差 90°（three 的 XY 平面 vs Babylon 的 XZ 平面），放在子网格上，
  // 这样节点旋转语义与 three 一致（节点自身旋转不被基朝向污染）。
  const wrapperByNode = new Map();
  let meshCount = 0;
  for (const node of nodes) {
    if (!node || !node.id) continue;
    const mesh = createMeshFor(String(node.type), node, scene);
    if (!mesh) continue;
    const wrapper = new TransformNode('node-' + String(node.id), scene);
    mesh.parent = wrapper;
    if (String(node.type) === 'plane') {
      // 绕 X 轴 +90°：把 Babylon 的 XZ 平面转成 three 的 XY 平面（法线 +Z）。
      mesh.rotation.x = Math.PI / 2.0;
    }
    const material = new StandardMaterial('mat-' + String(node.id), scene);
    material.diffuseColor = colorOf(node.color, new Color3(0.79, 0.63, 0.42));
    material.specularColor = new Color3(0.08, 0.08, 0.08);
    mesh.material = material;

    const position = node.position || [];
    wrapper.position = new Vector3(
      finite(position[0], 0),
      finite(position[1], 0),
      finite(position[2], 0),
    );
    const rotation = node.rotation || [];
    wrapper.rotation = new Vector3(
      finite(rotation[0], 0) * DEG_TO_RAD,
      finite(rotation[1], 0) * DEG_TO_RAD,
      finite(rotation[2], 0) * DEG_TO_RAD,
    );
    const scale = node.scale || [1, 1, 1];
    wrapper.scaling = new Vector3(
      finite(scale[0], 1),
      finite(scale[1], 1),
      finite(scale[2], 1),
    );
    wrapperByNode.set(String(node.id), wrapper);
    meshCount += 1;
  }
  // 父子关系第二遍处理：父节点不在场就挂回根（不猜）。
  for (const node of nodes) {
    if (!node || !node.id) continue;
    const wrapper = wrapperByNode.get(String(node.id));
    if (!wrapper) continue;
    const parentId = node.parent == null ? null : String(node.parent);
    const parentWrapper = parentId ? wrapperByNode.get(parentId) : null;
    if (parentWrapper && parentWrapper !== wrapper) {
      wrapper.parent = parentWrapper;
    }
  }

  for (const def of lights) {
    if (!def) continue;
    const color = colorOf(def.color, new Color3(1, 1, 1));
    const intensity = Math.max(0, finite(def.intensity, 1.0));
    const position = def.position || [];
    const type = String(def.type || 'ambient');
    if (type === 'ambient') {
      const light = new HemisphericLight('light-ambient', new Vector3(0, 1, 0), scene);
      light.intensity = intensity;
      light.diffuse = color;
      light.groundColor = color;
    } else if (type === 'directional') {
      const direction = new Vector3(
        -finite(position[0], 0),
        -finite(position[1], 1),
        -finite(position[2], 0),
      );
      if (direction.length() <= 1e-6) direction.set(0, -1, 0);
      direction.normalize();
      const light = new DirectionalLight('light-directional', direction, scene);
      light.position = new Vector3(
        finite(position[0], 0),
        finite(position[1], 0),
        finite(position[2], 0),
      );
      light.diffuse = color;
      light.intensity = intensity;
    } else if (type === 'point') {
      const light = new PointLight(
        'light-point',
        new Vector3(
          finite(position[0], 0),
          finite(position[1], 0),
          finite(position[2], 0),
        ),
        scene,
      );
      light.diffuse = color;
      light.intensity = intensity;
    }
  }

  function applyCamera(frame) {
    const view = cameraAt(frame) || {};
    const position = view.position || { x: 4, y: 2, z: 4 };
    const target = view.target || { x: 0, y: 1, z: 0 };
    camera.position.set(
      finite(position.x, 4),
      finite(position.y, 2),
      finite(position.z, 4),
    );
    camera.setTarget(
      new Vector3(
        finite(target.x, 0),
        finite(target.y, 1),
        finite(target.z, 0),
      ),
    );
    // three 的 fov 是「垂直视场角、角度」；Babylon 的 fov 是「弧度」。
    camera.fov = Math.max(0.05, Math.min(Math.PI - 0.05, finite(view.fov, 45) * DEG_TO_RAD));
  }

  function renderFrame(frame) {
    const target = Number(frame) || 0;
    applyCamera(target);
    scene.render();
    return target;
  }

  // 首帧探路：能建上下文但首帧就抛 → 让页面如实降级（不假装成功）。
  applyCamera(0);
  scene.render();

  return {
    rendererId: 'babylon_webgl_v9',
    renderFrame,
    capture: function () {
      try {
        return canvas.toDataURL('image/png');
      } catch (err) {
        return '';
      }
    },
    meshCount,
    dispose: function () {
      try {
        scene.dispose();
      } catch (err) {}
      try {
        engine.dispose();
      } catch (err) {}
    },
  };
}

export const babylonVersion = '9.38.0';
