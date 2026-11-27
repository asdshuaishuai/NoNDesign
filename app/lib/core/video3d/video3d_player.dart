/// 3D 视频预览页编译器：`scene3d.json` + `screenplay3d.json` → 自包含单文件
/// HTML（纯 Dart 字符串组装，不接 UI / 不构造 WebView）。
///
/// 契约见 `docs/design/video3d-contract.md` §4 与
/// `docs/design/video3d-execution.md` §3/§4：
///
///  * 输入是已经过 `verifyVideo3d` 的两份模型（本层不再做契约校验；调用前
///    必须 verified，否则编译时间表会显性抛错，不产出半成品页面）；
///  * 页面内嵌**确定性 scene JS**（[compileVideo3dScene] 产物，去掉 `export
///    default` 后成为可调用的 `build(THREE, scene, camera)`）与**整数帧时间表**
///    （[compileVideo3dTimeline] 产物）。运行时按传入的 [threeSource] 分两档：
///      - **真 three 渲染**（内联 r160 模块，`WebGLRenderer`）：画面由真实场景
///        与相机渲染，`ready.renderer = webgl_three_r160`；
///      - **Canvas2D 确定性投影**（最小 THREE 兼容层 + 透视投影，
///        `ready.renderer = canvas2d_deterministic`）：无 WebGL 时的降级面；
///  * 帧号只由 `floor(t × fps)` 决定，seek 是「重算目标帧并重绘」；页面无
///    `Math.random`、无 `Date.now`/`performance.now`，播放头用
///    `requestAnimationFrame` 的时间戳推进，**像素只由帧号决定**。注意两档的
///    确定性口径不同：Canvas2D 是逐字节确定；WebGL 是几何/相机/帧号确定，
///    像素在同设备同输入下恒定、跨设备可能不同（见执行面文档 §3）；
///  * `window.NONVIDEO3D` 回传 `ready` / `frame` / `ended` / `error` 四类消息；
///    `window.NONVIDEO3D_PLAYER` 是宿主可经 `runJavaScript` 驱动的 seek/播放面；
///  * 固定 CSP：`default-src 'none'; script-src 'unsafe-inline';
///    connect-src 'none'; frame-ancestors 'none'`——页面零外联、不读本地文件；
///  * **three-live 运行时文本必须由调用方注入**（参数 [assembleVideo3dPreview]
///    的 `runtimeSource`）。本层是纯 Dart，不碰 `rootBundle`/资源路径；缺失时
///    显性抛 [Video3dPlayerError]（`video3d_runtime_missing`），绝不静默产出
///    一个少一块执行面的「降级页面」；
///  * 确定性：同一 `scene + screenplay + runtimeSource` 两次组装**字节相同**
///    （页面不含时间戳/随机数/哈希序）；runtime 文本按传入字节原样内嵌
///    （只做 `</script` 级转义，防止不可信资源提前关闭脚本块）。
library;

import 'dart:convert';

import '../three_module.dart';
import 'video3d_compile.dart';
import 'video3d_contract.dart';

/// 预览页固定 CSP（与音乐播放页同一道门：四指令，无 worker/eval/媒体/样式源）。
///
/// v1 页面的最小 Canvas 2D 渲染器不需要动态求值/Worker；`<style>`/外链图片/
/// 字体也一律不放开（页面样式走 CSSOM，不受 style-src 管辖）。真实 three-live
/// 沙箱若在后续批次执行，需要按 [docs/design/video3d-execution.md] 的证据再
/// 单独裁决 CSP 放宽，不能在这里悄悄加指令。
const String video3dPreviewCsp =
    "default-src 'none'; script-src 'unsafe-inline'; "
    "connect-src 'none'; frame-ancestors 'none'";

/// `window.NONVIDEO3D` 回传桥允许的消息种类（契约逐字对齐）。
///
/// `ready` / `frame` / `ended` / `error` 是状态面；`evidence` 只在宿主调
/// `NONVIDEO3D_PLAYER.capture(frame)` 时出现（单帧 PNG 的 data URL）。
const List<String> video3dPreviewBridgeMessages = <String>[
  'ready',
  'frame',
  'ended',
  'error',
  // 抓帧回执：只在宿主显式调 `capture(frame)` 时出现（单帧 PNG data URL）。
  'evidence',
];

/// 出站桥的全局名（宿主 `JavaScriptChannel` 注入同名对象）。
const String video3dPreviewBridge = 'NONVIDEO3D';

/// 入站控制面的全局名（宿主 `runJavaScript` 调 `window.NONVIDEO3D_PLAYER`）。
const String video3dPreviewController = 'NONVIDEO3D_PLAYER';

/// `ready` 消息里如实回传的最小渲染器标识（不冒充实拍 three 渲染）。
const String video3dPreviewRenderer = 'canvas2d_deterministic';

/// 真 three 渲染面的标识：WebGL 可用时覆盖 [video3dPreviewRenderer]，
/// `ready` 里如实回传。两档并存（跨设备像素确定性口径见执行面文档 §3）。
const String video3dWebglRenderer = 'webgl_three_r160';

/// three.js 源码形状不符合 r160 约定（无出口块/出口块为空）时的稳定错误码。
const String video3dThreeModuleInvalidCode = 'video3d_three_module_invalid';

/// 缺运行时文本时的稳定错误码（不静默降级）。
const String video3dRuntimeMissingCode = 'video3d_runtime_missing';

/// 模板占位不完整/重复时的稳定错误码（不产出半成品页面）。
const String video3dTemplateInvalidCode = 'video3d_template_invalid';

/// 编译出的 scene JS 形状不符合执行面契约时的稳定错误码。
const String video3dSceneCompileInvalidCode = 'video3d_scene_compile_invalid';

/// 预览页组装失败：显性失败，不产出半成品页面。
final class Video3dPlayerError implements Exception {
  const Video3dPlayerError(this.code, this.message);

  /// 稳定机器码（测试/日志/后续工具信封使用，不直接上屏）。
  final String code;

  /// 原始诊断（人话修复方向只进折叠的「技术详情」）。
  final String message;

  @override
  String toString() => 'Video3dPlayerError($code: $message)';
}

/// 把已校验的 [scene] / [screenplay] 组装成自包含单文件预览页。
///
/// [runtimeSource] 是 three-live 运行时的**文本**（必须是调用方从应用资源读出
/// 后传入的字符串）：本层只做字符串内嵌，不读路径/资源键。缺失或空白时抛
/// [Video3dPlayerError]（`video3d_runtime_missing`），不静默降级。
///
/// [threeSource] 是 three.js r160 渲染库的**原文**（可选）：非空时页面内联一段
/// 模块脚本（`const THREE = {…}` 命名空间 + 同一份 scene 函数）+ **真 WebGL
/// 渲染面**；空串时页面只有 Canvas2D 确定性路径（测试与无 WebGL 环境用）。
/// 渲染库形状不对（无出口块）时抛 `video3d_three_module_invalid`，不产出半成品。
///
/// 失败前提：调用方必须先跑 `verifyVideo3d` 且 `verified == true`；模型齐全时
/// 本层只可能因运行时缺失/模板损坏/时间表不可编译而抛错。
String assembleVideo3dPreview(
  Video3dScene scene,
  Video3dScreenplay screenplay, {
  String? runtimeSource,
  String threeSource = '',
}) {
  if (runtimeSource == null || runtimeSource.trim().isEmpty) {
    throw const Video3dPlayerError(
      video3dRuntimeMissingCode,
      '预览页必须内嵌 three-live 运行时文本（runtimeSource），缺失时显性失败，'
      '不产出降级页面',
    );
  }

  // 时间表是页面帧循环的唯一权威：坏输入在这里显性抛错，不写半成品页面。
  final Video3dTimeline timeline = compileVideo3dTimeline(screenplay);
  if (timeline.totalFrames <= 0) {
    throw const Video3dPlayerError(
      video3dTemplateInvalidCode,
      '帧时间表为空，不能组装预览页',
    );
  }

  final String sceneJs = _inlineSceneJs(scene);
  final String timelineJson = _embeddedJson(timeline.toJson());
  final String renderJson = _embeddedJson(
    _renderModel(scene, screenplay, timeline),
  );

  for (final String slot in _templateSlots) {
    _requireSingleSlot(_previewTemplate, slot);
  }

  // 先替换固定槽位、最后才注入不可信运行时文本：runtime 里即使出现槽位字样
  // 也不会把其它注入点顶掉。
  final String namespaceSource = _inlineThreeNamespace(threeSource);
  var page = _previewTemplate
      .replaceFirst(_cspSlot, video3dPreviewCsp)
      .replaceFirst(_threeNamespaceSlot, namespaceSource)
      .replaceFirst(_sceneModuleSlot, sceneJs)
      .replaceFirst(_sceneSlot, sceneJs)
      .replaceFirst(_timelineSlot, timelineJson)
      .replaceFirst(_renderSlot, renderJson)
      .replaceFirst(_rendererSlot, _embeddedJson(video3dPreviewRenderer));
  page = page.replaceFirst(_runtimeSlot, _inlineRuntime(runtimeSource));

  for (final String slot in _templateSlots) {
    if (page.contains(slot)) {
      throw Video3dPlayerError(
        video3dTemplateInvalidCode,
        '预览页组装后仍有未替换占位：$slot',
      );
    }
  }
  return page;
}

// ---------------------------------------------------------------------------
// 组装细节
// ---------------------------------------------------------------------------

const String _cspSlot = '/*__PREVIEW_CSP__*/';
const String _runtimeSlot = '/*__THREE_LIVE_SOURCE__*/';
const String _threeNamespaceSlot = '/*__THREE_NAMESPACE__*/';
const String _sceneModuleSlot = '/*__SCENE_MODULE_SOURCE__*/';
const String _sceneSlot = '/*__SCENE_SOURCE__*/';
const String _timelineSlot = '/*__TIMELINE_JSON__*/';
const String _renderSlot = '/*__RENDER_JSON__*/';
const String _rendererSlot = '/*__RENDERER_NAME__*/';
const List<String> _templateSlots = <String>[
  _cspSlot,
  _runtimeSlot,
  _threeNamespaceSlot,
  _sceneModuleSlot,
  _sceneSlot,
  _timelineSlot,
  _renderSlot,
  _rendererSlot,
];

void _requireSingleSlot(String template, String slot) {
  final int first = template.indexOf(slot);
  if (first < 0 || first != template.lastIndexOf(slot)) {
    throw Video3dPlayerError(
      video3dTemplateInvalidCode,
      '预览页模板占位必须恰好出现一次：$slot',
    );
  }
}

/// 编译后的 scene JS → 页面内可直接调用的全局 `build(THREE, scene, camera)`。
///
/// [compileVideo3dScene] 产出的是 ES module（`export default function build(...)`）；
/// 页面是经典内联脚本（CSP 只允许 `'unsafe-inline'`），所以去掉 `export default`
/// 让函数声明留在全局作用域，页面用最小 `THREE` 兼容层执行它。
String _inlineSceneJs(Video3dScene scene) {
  final String compiled = compileVideo3dScene(scene);
  final String marker = 'export default function $video3dSceneBuildFunction(';
  if (!compiled.contains(marker)) {
    throw const Video3dPlayerError(
      video3dSceneCompileInvalidCode,
      'scene JS 缺少 build 入口（compileVideo3dScene 产物形状变了）',
    );
  }
  if (compiled.toLowerCase().contains('</script')) {
    throw const Video3dPlayerError(
      video3dSceneCompileInvalidCode,
      'scene JS 含有会提前关闭内联脚本的序列',
    );
  }
  final String callable = compiled.replaceFirst(
    marker,
    'function $video3dSceneBuildFunction(',
  );
  return callable;
}

/// three.js 原文 → 模块脚本里可直接使用的 `const THREE = {…}` 命名空间。
///
/// 空串表示「本页不内联渲染库」：页面自行降级到 Canvas2D 确定性路径。
/// 形状不对时抛 `video3d_three_module_invalid`（不产出只有半块渲染面的页面）。
String _inlineThreeNamespace(String source) {
  if (source.trim().isEmpty) return '';
  try {
    return _inlineRuntime(threeModuleNamespaceSource(source));
  } on ThreeModuleRewriteError catch (error) {
    throw Video3dPlayerError(video3dThreeModuleInvalidCode, error.message);
  }
}

/// 不可信文本内嵌到 `<script>` 前的转义：HTML 对脚本结束标签大小写不敏感，
/// 把 `</script` 换成 JS 里等价的 `<\/script`，既能保留字符串语义，又不会让
/// 运行时文本提前关闭脚本块。固定替换 → 不破坏字节确定性。
String _inlineRuntime(String source) {
  return source.replaceAll(
    RegExp('</script', caseSensitive: false),
    r'<\/script',
  );
}

/// JSON 作为内联脚本字面量：把 HTML 有意义的字符写成 JSON 转义。
///
/// 镜头 id 等字段由用户/Agent 输入（契约只要求非空字符串），字面量里的
/// `</script>` 会提前关闭内联脚本；`<` / `>` / `&` 与 U+2028 / U+2029 一并转义。
/// 全部是**输入无关的固定替换**，因此字节确定性不受影响。
String _embeddedJson(Object? value) {
  final String encoded = jsonEncode(value);
  return encoded
      .replaceAll('&', r'\u0026')
      .replaceAll('<', r'\u003c')
      .replaceAll('>', r'\u003e')
      .replaceAll('\u2028', r'\u2028')
      .replaceAll('\u2029', r'\u2029');
}

/// 预览页需要的确定性渲染模型（只由两份模型推导，无时间戳/随机）。
///
/// 页面最小渲染器消费 `format` / `background` / `cameras` / `lights` /
/// `shot_cameras`；`nodes` 留给证据/后续批次对照（渲染本身执行内嵌 scene JS）。
Map<String, Object?> _renderModel(
  Video3dScene scene,
  Video3dScreenplay screenplay,
  Video3dTimeline timeline,
) {
  return <String, Object?>{
    'format': <String, Object?>{
      'width': screenplay.format.width,
      'height': screenplay.format.height,
    },
    'fps': timeline.fps,
    'duration_seconds': timeline.durationSeconds,
    'total_frames': timeline.totalFrames,
    'seed': screenplay.seed,
    'units': scene.units,
    'background': scene.environment?.background ?? '#0b0d12',
    'nodes': <Object?>[
      for (final Video3dNode node in scene.nodes)
        <String, Object?>{
          'id': node.id,
          'type': node.type.name,
          'size': node.size,
          'position': node.position,
          'rotation': node.rotation,
          'scale': node.scale,
          'color': node.material.color,
          'roughness': node.material.roughness,
          'metalness': node.material.metalness,
          'parent': node.parent,
        },
    ],
    'cameras': <Object?>[
      for (final Video3dCamera camera in scene.cameras)
        <String, Object?>{
          'id': camera.id,
          'position': camera.position,
          'target': camera.target,
          'fov': camera.fov,
        },
    ],
    'lights': <Object?>[
      for (final Video3dLight light in scene.lights)
        <String, Object?>{
          'id': light.id,
          'type': light.type.name,
          'intensity': light.intensity,
          'color': light.color,
          'position': light.position,
          'target': light.target,
        },
    ],
    'shot_cameras': <Object?>[
      for (int index = 0; index < screenplay.shots.length; index++)
        <String, Object?>{
          'camera_id': timeline.shots[index].cameraId,
          if (screenplay.shots[index].camera.moveFrom != null)
            'from': screenplay.shots[index].camera.moveFrom,
          if (screenplay.shots[index].camera.moveTo != null)
            'to': screenplay.shots[index].camera.moveTo,
          if (screenplay.shots[index].camera.moveTarget != null)
            'target': screenplay.shots[index].camera.moveTarget,
          'easing':
              (screenplay.shots[index].camera.easing ?? Video3dEasing.linear)
                  .name,
        },
    ],
  };
}

// ---------------------------------------------------------------------------
// 页面模板
// ---------------------------------------------------------------------------

/// 预览页模板：占位由 [assembleVideo3dPreview] 填充，禁止任何外链入口。
///
/// 页面结构：标题/元数据 + 画布 + 运输条（播放/暂停/停止/seek）+ 状态。
/// 样式全部经 CSSOM 设置（固定 CSP 没放开样式源，内联 `<style>` 会被拦）。
/// 注释里不写占位字面量：组装器按字面量定位替换，写在这里会顶到注释里。
const String _previewTemplate = r'''<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="/*__PREVIEW_CSP__*/">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>3D 视频预览</title>
<!--
  自包含 3D 视频预览页（v1 最小执行面）。

  * 内嵌 three-live 运行时文本（宿主注入；缺失时 Dart 侧显性失败，本页不会
    以「少一块运行时」的形态被产出来）；
  * 内嵌 compileVideo3dScene 产出的确定性 scene JS（两处引用同一份文本）：
    一处进模块脚本，由**真 three r160** 构建场景并用 WebGL 渲染；一处进经典
    脚本，由最小 THREE 兼容层建出对象图，供 Canvas2D 降级面使用；
  * 内嵌 compileVideo3dTimeline 产出的整数帧表：帧号 = floor(秒 × fps)，
    画面只由「场景 + 镜头 + 帧号」决定，页面不调用随机数/墙钟接口；
  * 渲染面如实两档：WebGL 成功 → ready.renderer = webgl_three_r160；
    WebGL 不可用/建场景失败 → canvas2d_deterministic（不冒充、不白屏）；
  * 出站桥 window.NONVIDEO3D 回传 ready / frame / ended / error / evidence；
    evidence 只在宿主调 `capture(frame)` 时出现（帧证据 PNG 的 data URL）；
  * 零外链：不加载任何远端脚本/样式/图片/字体，不读本地文件，不发起网络请求。
-->
</head>
<body>
<main id="video3d-stage">
  <div id="video3d-head">
    <span id="video3d-title">3D 视频预览</span>
    <span id="video3d-meta"></span>
  </div>
  <canvas id="video3d-canvas" width="1" height="1"></canvas>
  <div id="video3d-transport">
    <button id="video3d-play" type="button">播放</button>
    <button id="video3d-pause" type="button">暂停</button>
    <button id="video3d-stop" type="button">停止</button>
    <input id="video3d-seek" type="range" min="0" max="0" step="1" value="0">
    <span id="video3d-clock">0 / 0</span>
    <span id="video3d-status">加载中</span>
  </div>
</main>
<script id="video3d-runtime">
/*__THREE_LIVE_SOURCE__*/
</script>
<!-- —— 真 three 渲染面（WebGL）：渲染库与场景函数在同一模块作用域内 ——
     经典脚本等 DOMContentLoaded 才启动，模块脚本一定先跑完；WebGL 不可用时
     模块只把 window.__video3d_gl 留空，由经典脚本如实降级到 Canvas2D。 -->
<script type="module">
/*__THREE_NAMESPACE__*/
/*__SCENE_MODULE_SOURCE__*/
(function () {
'use strict';
try {
  if (typeof THREE === 'undefined') { window.__video3d_gl = null; return; }
  var det = window.__video3d_det;
  if (!det) { window.__video3d_gl = null; return; }
  var width = Math.max(1, Math.floor(Number(det.WIDTH) || 720));
  var height = Math.max(1, Math.floor(Number(det.HEIGHT) || 1280));
  var renderer = new THREE.WebGLRenderer({
    antialias: true,
    alpha: false,
    preserveDrawingBuffer: true
  });
  renderer.setPixelRatio(1);
  renderer.setSize(width, height, false);
  if (THREE.SRGBColorSpace && renderer.outputColorSpace !== undefined) {
    renderer.outputColorSpace = THREE.SRGBColorSpace;
  }
  var scene = new THREE.Scene();
  try {
    scene.background = new THREE.Color(String(det.BACKGROUND || '#0b0d12'));
  } catch (err) {}
  var camera = new THREE.PerspectiveCamera(45, width / height, 0.1, 2000);
  var built = build(THREE, scene, camera);
  var metrics = (built && built.metrics) ? built.metrics : null;
  var nodeCount = 0;
  scene.traverse(function (object) {
    if (object && object.isMesh) nodeCount += 1;
  });

  function applyCamera(frame) {
    var view = det.cameraAt(frame);
    camera.fov = isFinite(Number(view.fov)) ? Number(view.fov) : 45;
    camera.aspect = width / height;
    camera.position.set(
      Number(view.position.x), Number(view.position.y), Number(view.position.z));
    camera.lookAt(
      Number(view.target.x), Number(view.target.y), Number(view.target.z));
    camera.updateProjectionMatrix();
  }

  function renderFrame(frame) {
    var target = det.clampFrame(frame);
    applyCamera(target);
    renderer.render(scene, camera);
    return target;
  }

  // 先渲染一帧探路：能建上下文但首帧就抛（驱动/上下文问题）同样如实降级。
  renderer.render(scene, camera);

  var canvas = renderer.domElement;
  try { canvas.id = 'video3d-gl-canvas'; } catch (err) {}

  window.__video3d_gl = {
    rendererId: 'webgl_three_r160',
    renderFrame: renderFrame,
    // 读回当前帧：preserveDrawingBuffer 下 render 之后 canvas 仍可导出。
    capture: function () {
      try { return canvas.toDataURL('image/png'); } catch (err) { return ''; }
    },
    canvas: canvas,
    sceneNodes: nodeCount,
    metrics: metrics
  };
} catch (err) {
  window.__video3d_gl = null;
}
})();
</script>
<script>
/*__SCENE_SOURCE__*/
</script>
<script>
(function () {
'use strict';

// 组装时注入的确定性输入：整数帧时间表（compileVideo3dTimeline 产物）与渲染
// 模型（两份事实源推导）。二者均为固定字节，页面不读任何本地文件。
var TIMELINE = /*__TIMELINE_JSON__*/;
var RENDER = /*__RENDER_JSON__*/;

var FPS = Number(TIMELINE.fps) > 0 ? Number(TIMELINE.fps) : 30;
var TOTAL_FRAMES = Number(TIMELINE.total_frames) > 0
  ? Math.floor(Number(TIMELINE.total_frames))
  : 0;
var DURATION_SECONDS = Number(TIMELINE.duration_seconds) || 0;
var SHOTS = (TIMELINE.shots && TIMELINE.shots.length) ? TIMELINE.shots : [];
var FORMAT = RENDER.format || {};
var WIDTH = Math.max(1, Math.floor(Number(FORMAT.width) || 720));
var HEIGHT = Math.max(1, Math.floor(Number(FORMAT.height) || 1280));
var BACKGROUND = String(RENDER.background || '#0b0d12');
var CAMERAS = (RENDER.cameras && RENDER.cameras.length) ? RENDER.cameras : [];
var SHOT_CAMERAS = (RENDER.shot_cameras && RENDER.shot_cameras.length)
  ? RENDER.shot_cameras
  : [];
var LIGHTS = (RENDER.lights && RENDER.lights.length) ? RENDER.lights : [];
var RENDERER = /*__RENDERER_NAME__*/;
var LIGHT_FACTOR = computeLightFactor();

// 真渲染面（上面的模块脚本）需要的确定性输入：模块先于 DOMContentLoaded
// 执行，此时本经典脚本已同步跑完；cameraAt / clampFrame 是函数声明（提升），
// 这里只是把引用交出去。
try {
  window.__video3d_det = {
    WIDTH: WIDTH,
    HEIGHT: HEIGHT,
    FPS: FPS,
    TOTAL_FRAMES: TOTAL_FRAMES,
    BACKGROUND: BACKGROUND,
    cameraAt: cameraAt,
    clampFrame: clampFrame
  };
} catch (err) {}

// 模块脚本产出的真 three 渲染面；null = 没有 WebGL，走 Canvas2D。
var GL = null;

var canvas = null;
var context = null;
var meshes = [];
var sceneMetrics = null;
var currentFrame = 0;
var playing = false;
var rafId = 0;
var startTimestamp = null;
var startFrame = 0;

// —— window.NONVIDEO3D 回传桥（宿主 JavaScriptChannel；离线直开时静默降级） ——
function postMessage(kind, payload) {
  var object = { kind: kind };
  if (payload) {
    for (var key in payload) {
      if (Object.prototype.hasOwnProperty.call(payload, key)) {
        object[key] = payload[key];
      }
    }
  }
  try {
    if (window.NONVIDEO3D &&
        typeof window.NONVIDEO3D.postMessage === 'function') {
      window.NONVIDEO3D.postMessage(JSON.stringify(object));
    }
  } catch (err) {}
}

function reportError(message) {
  var text = String(message);
  setStatus('预览出错：' + text);
  postMessage('error', { message: text });
}

window.addEventListener('error', function (event) {
  reportError(event && event.message ? event.message : '未知错误');
});
window.addEventListener('unhandledrejection', function () {
  reportError('异步执行失败');
});

// —— 确定性数值工具（页面不碰随机/墙钟；像素只由帧号决定） ——
function finiteOrZero(value) {
  var number = Number(value);
  return isFinite(number) ? number : 0;
}

function clampNumber(value, min, max) {
  var number = Number(value);
  if (!isFinite(number)) return min;
  if (number < min) return min;
  if (number > max) return max;
  return number;
}

function computeLightFactor() {
  var ambient = 0.0;
  var directional = 0.0;
  for (var i = 0; i < LIGHTS.length; i++) {
    var light = LIGHTS[i] || {};
    var intensity = Math.max(0, Number(light.intensity) || 0);
    if (light.type === 'ambient') ambient += intensity;
    if (light.type === 'directional') directional += intensity;
  }
  var factor = 0.4 + 0.2 * ambient + 0.3 * directional;
  return clampNumber(factor, 0.35, 1.0);
}

// —— 最小 THREE 兼容层：只覆盖 compileVideo3dScene 用到的构造器/方法 ——
// v1 不追求与真 three 像素一致：这里只建出对象图，供下面的 Canvas 2D 投影。
function SpanVec3() {
  this.x = 0;
  this.y = 0;
  this.z = 0;
}
SpanVec3.prototype.set = function (x, y, z) {
  this.x = finiteOrZero(x);
  this.y = finiteOrZero(y);
  this.z = finiteOrZero(z);
  return this;
};

function SpanColor(value) {
  this.value = String(value);
}

function SpanGeometry(kind, size) {
  this.kind = kind;
  this.size = size;
}

function SpanMaterial(options) {
  options = options || {};
  this.color = options.color instanceof SpanColor
    ? options.color
    : new SpanColor(options.color);
  this.roughness = finiteOrZero(options.roughness);
  this.metalness = finiteOrZero(options.metalness);
  this.name = options.name == null ? null : String(options.name);
}

function SpanObject3D() {
  this.name = null;
  this.children = [];
  this.position = new SpanVec3();
  this.rotation = new SpanVec3();
  this.scale = new SpanVec3().set(1, 1, 1);
}
SpanObject3D.prototype.add = function (child) {
  if (child) this.children.push(child);
  return this;
};

function SpanMesh(geometry, material) {
  SpanObject3D.call(this);
  this.isMesh = true;
  this.geometry = geometry || {};
  this.material = material || {};
}
SpanMesh.prototype = Object.create(SpanObject3D.prototype);
SpanMesh.prototype.constructor = SpanMesh;

function SpanLight(type, color, intensity) {
  SpanObject3D.call(this);
  this.isLight = true;
  this.lightType = String(type || 'ambient');
  this.color = color instanceof SpanColor ? color : new SpanColor(color);
  this.intensity = finiteOrZero(intensity);
  this.target = new SpanObject3D();
}
SpanLight.prototype = Object.create(SpanObject3D.prototype);
SpanLight.prototype.constructor = SpanLight;

function SpanCamera(fov, aspect) {
  SpanObject3D.call(this);
  this.isCamera = true;
  this.fov = finiteOrZero(fov) || 45;
  this.aspect = finiteOrZero(aspect) || 1;
  this.target = new SpanVec3();
}
SpanCamera.prototype = Object.create(SpanObject3D.prototype);
SpanCamera.prototype.constructor = SpanCamera;
SpanCamera.prototype.lookAt = function (x, y, z) {
  this.target.set(x, y, z);
};
SpanCamera.prototype.updateProjectionMatrix = function () {};

function SpanScene() {
  this.children = [];
  this.background = null;
}
SpanScene.prototype.add = function (child) {
  if (child) this.children.push(child);
  return this;
};

function makeMinimalThree() {
  return {
    BoxGeometry: function (width, height, depth) {
      return new SpanGeometry('box', [
        finiteOrZero(width), finiteOrZero(height), finiteOrZero(depth)
      ]);
    },
    SphereGeometry: function (radius) {
      var value = Math.abs(finiteOrZero(radius));
      return new SpanGeometry('sphere', [value, value, value]);
    },
    CylinderGeometry: function (radiusTop, radiusBottom, height) {
      return new SpanGeometry('cylinder', [
        Math.abs(finiteOrZero(radiusTop)),
        Math.abs(finiteOrZero(radiusBottom)),
        Math.abs(finiteOrZero(height))
      ]);
    },
    PlaneGeometry: function (width, depth) {
      return new SpanGeometry('plane', [
        Math.abs(finiteOrZero(width)),
        Math.abs(finiteOrZero(depth)),
        0
      ]);
    },
    MeshStandardMaterial: function (options) {
      return new SpanMaterial(options);
    },
    Color: function (value) {
      return new SpanColor(value);
    },
    Mesh: function (geometry, material) {
      return new SpanMesh(geometry, material);
    },
    AmbientLight: function (color, intensity) {
      return new SpanLight('ambient', color, intensity);
    },
    DirectionalLight: function (color, intensity) {
      return new SpanLight('directional', color, intensity);
    },
    PointLight: function (color, intensity) {
      return new SpanLight('point', color, intensity);
    },
    PerspectiveCamera: function (fov) {
      return new SpanCamera(fov, 1);
    },
    MathUtils: {
      degToRad: function (degrees) {
        return finiteOrZero(degrees) * Math.PI / 180.0;
      }
    }
  };
}

// —— 执行内嵌的确定性 scene JS，收集世界坐标下的 mesh ——
function buildSceneGraph() {
  if (typeof build !== 'function') {
    throw new Error('场景构建入口 build 未内嵌');
  }
  var three = makeMinimalThree();
  var root = new SpanScene();
  var cameraSlot = new SpanCamera(45, 1);
  var result = build(three, root, cameraSlot);
  sceneMetrics = (result && result.metrics) ? result.metrics : null;
  var collected = [];
  collectMeshes(root, 0, 0, 0, collected);
  return collected;
}

function collectMeshes(object, baseX, baseY, baseZ, out) {
  if (!object) return;
  var position = object.position || {};
  var worldX = baseX + (isFinite(Number(position.x)) ? Number(position.x) : 0);
  var worldY = baseY + (isFinite(Number(position.y)) ? Number(position.y) : 0);
  var worldZ = baseZ + (isFinite(Number(position.z)) ? Number(position.z) : 0);
  if (object.isMesh) {
    out.push({
      mesh: object,
      x: worldX,
      y: worldY,
      z: worldZ,
      order: out.length
    });
  }
  var children = object.children || [];
  for (var i = 0; i < children.length; i++) {
    collectMeshes(children[i], worldX, worldY, worldZ, out);
  }
}

// —— 相机/镜头：固定相机 + 线性/easeInOut 直线移动（契约 §3） ——
function pointFromArray(values, fallback) {
  if (!values || values.length !== 3) return fallback;
  var x = Number(values[0]);
  var y = Number(values[1]);
  var z = Number(values[2]);
  if (!isFinite(x) || !isFinite(y) || !isFinite(z)) return fallback;
  return { x: x, y: y, z: z };
}

function cameraBase(cameraId) {
  for (var i = 0; i < CAMERAS.length; i++) {
    if (CAMERAS[i] && CAMERAS[i].id === cameraId) return CAMERAS[i];
  }
  return CAMERAS.length ? CAMERAS[0] : null;
}

function shotIndexAt(frame) {
  for (var i = 0; i < SHOTS.length; i++) {
    var shot = SHOTS[i] || {};
    var start = Number(shot.start_frame) || 0;
    var count = Number(shot.frame_count) || 0;
    if (frame >= start && frame < start + count) return i;
  }
  return -1;
}

function cameraAt(frame) {
  var index = shotIndexAt(frame);
  var shot = index >= 0 ? SHOTS[index] : null;
  var move = (index >= 0 && SHOT_CAMERAS[index]) ? SHOT_CAMERAS[index] : {};
  var base = cameraBase(shot ? shot.camera_id : null);
  var position = pointFromArray(
    base ? base.position : null, { x: 4, y: 2, z: 4 });
  var target = pointFromArray(
    base ? base.target : null, { x: 0, y: 1, z: 0 });
  var fov = base && isFinite(Number(base.fov)) ? Number(base.fov) : 45;
  if (move && move.from && move.to) {
    var from = pointFromArray(move.from, position);
    var to = pointFromArray(move.to, position);
    var count = Math.max(1, Number(shot.frame_count) || 1);
    var progress = count > 1
      ? (frame - (Number(shot.start_frame) || 0)) / (count - 1)
      : 0;
    progress = clampNumber(progress, 0, 1);
    if (move.easing === 'easeInOut') {
      progress = progress * progress * (3.0 - 2.0 * progress);
    }
    position = {
      x: position.x + (to.x - position.x) * progress,
      y: position.y + (to.y - position.y) * progress,
      z: position.z + (to.z - position.z) * progress
    };
    var moved = pointFromArray(move.target, target);
    target = moved;
  }
  return { position: position, target: target, fov: fov };
}

// —— 透视投影：相机 position/target/fov + 格式宽高（像素=世界的确定性映射） ——
function vec(x, y, z) {
  return { x: x, y: y, z: z };
}

function subtract(a, b) {
  return { x: a.x - b.x, y: a.y - b.y, z: a.z - b.z };
}

function dot(a, b) {
  return a.x * b.x + a.y * b.y + a.z * b.z;
}

function cross(a, b) {
  return {
    x: a.y * b.z - a.z * b.y,
    y: a.z * b.x - a.x * b.z,
    z: a.x * b.y - a.y * b.x
  };
}

function normalize(value) {
  var length = Math.sqrt(dot(value, value));
  if (!isFinite(length) || length <= 1.0e-6) return null;
  return { x: value.x / length, y: value.y / length, z: value.z / length };
}

function projectPoint(point, camera) {
  var eye = camera.position;
  var forward = normalize(subtract(camera.target, eye));
  if (!forward) return null;
  var right = normalize(cross(forward, vec(0, 1, 0)));
  if (!right) right = normalize(cross(forward, vec(1, 0, 0)));
  if (!right) return null;
  var up = cross(right, forward);
  var relative = subtract(point, eye);
  var depth = dot(relative, forward);
  if (!isFinite(depth) || depth <= 0.05) return null;
  var focal = 1.0 / Math.tan((camera.fov * Math.PI / 180.0) / 2.0);
  var ndcX = (focal * dot(relative, right)) / depth;
  var ndcY = (focal * dot(relative, up)) / depth;
  return {
    x: WIDTH / 2.0 + ndcX * (HEIGHT / 2.0),
    y: HEIGHT / 2.0 - ndcY * (HEIGHT / 2.0),
    z: depth,
    scale: focal / depth * (HEIGHT / 2.0)
  };
}

function projectedRadius(kind, size) {
  size = size || [0, 0, 0];
  var a = Math.abs(Number(size[0]) || 0);
  var b = Math.abs(Number(size[1]) || 0);
  var c = Math.abs(Number(size[2]) || 0);
  if (kind === 'sphere') return Math.max(a, 0.001);
  if (kind === 'box') return Math.sqrt(a * a + b * b + c * c) / 2.0;
  if (kind === 'cylinder') return Math.max(a, b, c / 2.0, 0.001);
  if (kind === 'plane') return Math.max(a, b) / 2.0;
  return Math.max(a, b, c, 0.001);
}

// —— 颜色：hex → rgb，按固定环境光因子做确定性明暗（无随机/无图像采样） ——
function colorChannels(hex) {
  var text = String(hex || '').replace('#', '');
  if (/^[0-9a-fA-F]{6}$/.test(text) === false) {
    return { r: 201, g: 160, b: 106 };
  }
  return {
    r: parseInt(text.substring(0, 2), 16),
    g: parseInt(text.substring(2, 4), 16),
    b: parseInt(text.substring(4, 6), 16)
  };
}

function shadeColor(hex, factor) {
  var channels = colorChannels(hex);
  function channel(value) {
    return clampNumber(Math.round(value * factor), 0, 255);
  }
  return 'rgb(' + channel(channels.r) + ',' +
    channel(channels.g) + ',' + channel(channels.b) + ')';
}

// —— 帧循环：帧号由时间表决定；播放头推进用 rAF 时间戳，像素只由帧号决定 ——
function clampFrame(frame) {
  var value = Math.floor(Number(frame));
  if (!isFinite(value)) value = 0;
  if (value < 0) value = 0;
  if (TOTAL_FRAMES > 0 && value > TOTAL_FRAMES - 1) value = TOTAL_FRAMES - 1;
  return value;
}

function drawMesh(item) {
  var radius = item.radius;
  context.lineWidth = 1;
  context.strokeStyle = '#0a0d12';
  context.fillStyle = item.color;
  if (item.kind === 'sphere') {
    context.beginPath();
    context.arc(item.x, item.y, radius, 0, Math.PI * 2, false);
    context.fill();
    context.stroke();
    return;
  }
  if (item.kind === 'cylinder') {
    context.beginPath();
    context.ellipse(
      item.x, item.y, radius, Math.max(0.6, radius * 0.6),
      0, 0, Math.PI * 2, false);
    context.fill();
    context.stroke();
    return;
  }
  if (item.kind === 'plane') {
    context.fillRect(item.x - radius, item.y - radius * 0.5, radius * 2, radius);
    context.strokeRect(
      item.x - radius, item.y - radius * 0.5, radius * 2, radius);
    return;
  }
  context.fillRect(item.x - radius, item.y - radius, radius * 2, radius * 2);
  context.strokeRect(
    item.x - radius, item.y - radius, radius * 2, radius * 2);
}

function renderFrame(frame) {
  var target = clampFrame(frame);
  if (GL && typeof GL.renderFrame === 'function') {
    GL.renderFrame(target);
    currentFrame = target;
    updateReadout(target);
    postMessage('frame', {
      frame: target,
      seconds: target / FPS,
      total_frames: TOTAL_FRAMES,
      renderer: RENDERER
    });
    return target;
  }
  if (!context) return target;
  var camera = cameraAt(target);
  context.setTransform(1, 0, 0, 1, 0, 0);
  context.clearRect(0, 0, WIDTH, HEIGHT);
  context.fillStyle = BACKGROUND;
  context.fillRect(0, 0, WIDTH, HEIGHT);
  var drawables = [];
  for (var i = 0; i < meshes.length; i++) {
    var item = meshes[i];
    var projection = projectPoint(vec(item.x, item.y, item.z), camera);
    if (!projection) continue;
    var geometry = item.mesh.geometry || {};
    var size = geometry.size || [0.1, 0.1, 0.1];
    var radius = projection.scale * projectedRadius(geometry.kind, size);
    if (!isFinite(radius) || radius < 0.6) radius = 0.6;
    var material = item.mesh.material || {};
    var colorHex = material.color ? material.color.value : '#c9a06a';
    drawables.push({
      x: projection.x,
      y: projection.y,
      z: projection.z,
      radius: radius,
      kind: geometry.kind,
      color: shadeColor(colorHex, LIGHT_FACTOR),
      order: i
    });
  }
  drawables.sort(function (a, b) {
    if (a.z !== b.z) return b.z - a.z;
    return a.order - b.order;
  });
  for (var j = 0; j < drawables.length; j++) drawMesh(drawables[j]);
  currentFrame = target;
  updateReadout(target);
  postMessage('frame', {
    frame: target,
    seconds: target / FPS,
    total_frames: TOTAL_FRAMES,
    renderer: RENDERER
  });
  return target;
}

function play() {
  if (TOTAL_FRAMES <= 0) {
    reportError('帧表为空，没有可播放的画面');
    return;
  }
  if (playing) return;
  if (currentFrame >= TOTAL_FRAMES - 1) seekFrame(0);
  playing = true;
  rafId = 0;
  startTimestamp = null;
  startFrame = Math.max(0, currentFrame);
  setStatus('播放中');
  rafId = window.requestAnimationFrame(tick);
}

function pause() {
  if (!playing) return;
  playing = false;
  if (rafId) {
    window.cancelAnimationFrame(rafId);
    rafId = 0;
  }
  setStatus('已暂停');
}

function stopPlayback() {
  playing = false;
  if (rafId) {
    window.cancelAnimationFrame(rafId);
    rafId = 0;
  }
  seekFrame(0);
  setStatus('已停止');
}

function tick(timestamp) {
  if (!playing) return;
  var now = Number(timestamp);
  if (!isFinite(now)) now = 0;
  if (startTimestamp === null) {
    startTimestamp = now;
    startFrame = Math.max(0, currentFrame);
  }
  var advance = Math.floor(((now - startTimestamp) * FPS) / 1000.0 + 1.0e-9);
  var frame = startFrame + advance;
  if (frame > TOTAL_FRAMES - 1) frame = TOTAL_FRAMES - 1;
  if (frame < 0) frame = 0;
  if (frame !== currentFrame) renderFrame(frame);
  if (frame >= TOTAL_FRAMES - 1) {
    finishPlayback();
    return;
  }
  rafId = window.requestAnimationFrame(tick);
}

function finishPlayback() {
  playing = false;
  if (rafId) {
    window.cancelAnimationFrame(rafId);
    rafId = 0;
  }
  setStatus('播放结束');
  postMessage('ended', {
    frame: Math.max(0, TOTAL_FRAMES - 1),
    total_frames: TOTAL_FRAMES
  });
}

function seek(seconds) {
  return seekFrame(Math.floor((Number(seconds) || 0) * FPS));
}

function seekFrame(frame) {
  var target = clampFrame(frame);
  if (playing) {
    startTimestamp = null;
    startFrame = target;
  }
  var rendered = renderFrame(target);
  setStatus('就绪');
  return rendered;
}

// —— 帧证据：按帧渲染 → 当前画布导出 PNG → 桥回传（抓完恢复原播放状态） ——
function captureFrame(frame) {
  var target = clampFrame(frame);
  var wasPlaying = playing;
  if (wasPlaying) pause();
  var dataUrl = '';
  try {
    if (GL && typeof GL.renderFrame === 'function') {
      GL.renderFrame(target);
      currentFrame = target;
      updateReadout(target);
      dataUrl = typeof GL.capture === 'function'
        ? String(GL.capture() || '')
        : '';
    } else if (context && canvas) {
      renderFrame(target);
      dataUrl = String(canvas.toDataURL('image/png'));
    }
  } catch (err) {
    postMessage('error', { message: 'evidence_failed: ' + String(err) });
    return false;
  }
  if (dataUrl.indexOf('data:image/png') !== 0) {
    // 不产出空白/坏 PNG：没有像素就如实报错，交给宿主显性处理。
    postMessage('error', { message: 'evidence_empty' });
    return false;
  }
  postMessage('evidence', {
    frame: target,
    renderer: RENDERER,
    data_url: dataUrl
  });
  if (wasPlaying) play();
  return true;
}

// —— 运输条 / 界面 ——
function setStatus(text) {
  var element = document.getElementById('video3d-status');
  if (element) element.textContent = text;
}

function updateReadout(frame) {
  var clock = document.getElementById('video3d-clock');
  if (clock) {
    clock.textContent = String(frame) + ' / ' +
      String(Math.max(0, TOTAL_FRAMES - 1));
  }
  var seekElement = document.getElementById('video3d-seek');
  if (seekElement && document.activeElement !== seekElement) {
    seekElement.value = String(frame);
  }
}

function updateHeader() {
  var title = document.getElementById('video3d-title');
  if (title) title.textContent = '3D 视频预览';
  var meta = document.getElementById('video3d-meta');
  if (meta) {
    meta.textContent = String(FPS) + ' fps · ' + String(TOTAL_FRAMES) +
      ' 帧 · ' + formatDuration(DURATION_SECONDS) + ' · ' +
      String(WIDTH) + '×' + String(HEIGHT);
  }
}

function formatDuration(seconds) {
  var value = Math.floor(Math.max(0, Number(seconds) || 0));
  var minutes = Math.floor(value / 60);
  var rest = value % 60;
  return String(minutes) + ':' + (rest < 10 ? '0' : '') + String(rest);
}

function bindTransport() {
  var playButton = document.getElementById('video3d-play');
  if (playButton) {
    playButton.addEventListener('click', function () { play(); });
  }
  var pauseButton = document.getElementById('video3d-pause');
  if (pauseButton) {
    pauseButton.addEventListener('click', function () { pause(); });
  }
  var stopButton = document.getElementById('video3d-stop');
  if (stopButton) {
    stopButton.addEventListener('click', function () { stopPlayback(); });
  }
  var seekElement = document.getElementById('video3d-seek');
  if (seekElement) {
    seekElement.max = String(Math.max(0, TOTAL_FRAMES - 1));
    seekElement.addEventListener('input', function () {
      seekFrame(Number(seekElement.value) || 0);
    });
  }
}

// 固定 CSP 没放开样式源：全部样式经 CSSOM 赋值（样式源指令保持关闭）。
function setStyle(element, properties) {
  if (!element || !element.style) return;
  for (var key in properties) {
    if (Object.prototype.hasOwnProperty.call(properties, key)) {
      try {
        element.style.setProperty(key, properties[key]);
      } catch (err) {}
    }
  }
}

function styleById(id, properties) {
  setStyle(document.getElementById(id), properties);
}

function applyStyles() {
  setStyle(document.body, {
    margin: '0',
    padding: '0',
    background: '#0b0d12',
    color: '#e8eaf0',
    'font-family': '-apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif',
    'font-size': '14px',
    overflow: 'hidden'
  });
  styleById('video3d-stage', {
    display: 'flex',
    'flex-direction': 'column',
    'align-items': 'center',
    'justify-content': 'center',
    height: '100vh',
    'box-sizing': 'border-box',
    padding: '12px',
    gap: '10px'
  });
  styleById('video3d-head', {
    display: 'flex',
    'justify-content': 'space-between',
    'align-items': 'baseline',
    width: '100%',
    'max-width': '720px'
  });
  styleById('video3d-title', { 'font-size': '16px', 'font-weight': '600' });
  styleById('video3d-meta', {
    color: '#9aa4b5',
    'font-size': '12px',
    'font-variant-numeric': 'tabular-nums'
  });
  styleById('video3d-canvas', {
    'max-width': '100%',
    'max-height': 'calc(100vh - 150px)',
    'border-radius': '12px',
    background: BACKGROUND,
    display: 'block'
  });
  styleById('video3d-transport', {
    display: 'flex',
    'flex-wrap': 'wrap',
    'align-items': 'center',
    'justify-content': 'center',
    gap: '8px',
    width: '100%',
    'max-width': '720px'
  });
  styleById('video3d-seek', { flex: '1 1 120px', 'min-width': '90px' });
  styleById('video3d-clock', {
    color: '#9aa4b5',
    'font-size': '12px',
    'font-variant-numeric': 'tabular-nums',
    'min-width': '72px',
    'text-align': 'right'
  });
  styleById('video3d-status', { color: '#9aa4b5', 'font-size': '12px' });
  var buttonIds = ['video3d-play', 'video3d-pause', 'video3d-stop'];
  for (var i = 0; i < buttonIds.length; i++) {
    styleById(buttonIds[i], {
      padding: '7px 14px',
      'border-radius': '8px',
      border: '1px solid #34445c',
      background: '#1b2432',
      color: '#e8eaf0',
      'font-size': '13px',
      cursor: 'pointer'
    });
  }
}

function resolveRenderer() {
  try {
    if (window.__video3d_gl) GL = window.__video3d_gl;
  } catch (err) {}
  if (GL && typeof GL.rendererId === 'string' && GL.rendererId) {
    RENDERER = GL.rendererId;
  }
}

// 真渲染面用渲染器自己的 canvas；隐藏 2D 画布，按同一尺寸语义挂上去。
function attachGlCanvas() {
  if (!GL || !GL.canvas) return;
  try { canvas.style.display = 'none'; } catch (err) {}
  var stage = document.getElementById('video3d-stage');
  var head = document.getElementById('video3d-head');
  if (stage) {
    if (head && head.parentNode === stage) {
      stage.insertBefore(GL.canvas, head.nextSibling);
    } else {
      stage.appendChild(GL.canvas);
    }
  }
  styleById('video3d-gl-canvas', {
    'max-width': '100%',
    'max-height': 'calc(100vh - 150px)',
    'border-radius': '12px',
    display: 'block'
  });
}

function boot() {
  try {
    resolveRenderer();
    applyStyles();
    canvas = document.getElementById('video3d-canvas');
    if (!canvas) throw new Error('画布元素缺失');
    canvas.width = WIDTH;
    canvas.height = HEIGHT;
    context = canvas.getContext('2d');
    if (!context) throw new Error('画布上下文不可用');
    attachGlCanvas();
    updateHeader();
    bindTransport();
    meshes = GL ? [] : buildSceneGraph();
    if (TOTAL_FRAMES <= 0) {
      reportError('帧表为空：检查 screenplay3d.json 的镜头时长');
      return;
    }
    postMessage('ready', {
      fps: FPS,
      total_frames: TOTAL_FRAMES,
      duration_seconds: DURATION_SECONDS,
      width: WIDTH,
      height: HEIGHT,
      shots: SHOTS.length,
      scene_nodes: GL ? Number(GL.sceneNodes) || 0 : meshes.length,
      scene_metrics: GL ? GL.metrics : sceneMetrics,
      renderer: RENDERER,
      runtime: 'embedded'
    });
    renderFrame(0);
    setStatus('就绪');
  } catch (err) {
    reportError(
      '预览页初始化失败：' + (err && err.message ? err.message : String(err))
    );
  }
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', boot);
} else {
  boot();
}

// 宿主可经 WebView 的 runJavaScript 调 window.NONVIDEO3D_PLAYER 驱动预览；
// 出站消息仍只走 window.NONVIDEO3D 的 ready / frame / ended / error 四类。
try {
  window.NONVIDEO3D_PLAYER = {
    play: play,
    pause: pause,
    stop: stopPlayback,
    seek: seek,
    seekFrame: seekFrame,
    renderFrame: renderFrame,
    state: function () { return playing ? 'playing' : 'idle'; },
    frame: function () { return currentFrame; },
    totalFrames: function () { return TOTAL_FRAMES; },
    renderer: function () { return RENDERER; },
    capture: captureFrame
  };
} catch (err) {}
})();
</script>
</body>
</html>
''';
