/// 常规视频「引擎短片」播放页（Phaser 4）：自包含单文件 HTML 组装器。
///
/// 纪律（与 3D 视频页/音乐播放页同族）：
///  * **零网络**：CSP `default-src 'none'` + `connect-src 'none'`，Phaser 运行时文本
///    随包内联（`app/assets/phaser/phaser.min.js`），页面不 fetch 任何外部资源；
///  * **确定性**：固定 30fps、帧号是唯一时钟；`seekFrame(n)` 重绘是纯函数
///    （同一剧本 + 同一帧号 → 同一画面），页面不用 wall clock 决定内容；
///  * **画面只由剧本决定**：按镜头区间、事件（vfx/sfx/camera.shake/caption）绘制
///    确定性色块/文字标记；**像素级 VFX 渲染仍未施工**（本页是时序/位置的预览面）；
///  * 失败显性：剧本没编译通过不组装页面；Phaser 文本缺失直接抛错。
library;

import 'dart:convert';

import 'video_screenplay.dart';
import 'video_style_pack.dart';

/// Phaser 4 vendored 运行时资源键（`build-manifest.json` 锁 sha256/字节）。
const String videoShortPhaserAssetKey = 'assets/phaser/phaser.min.js';

/// pixelfx 特效子集的 IIFE 包（`third_party/pixelfx_web` 构建；
/// `build-manifest.json` 锁 sha256/字节）。可选：缺失时页面如实降级为占位标记。
const String videoShortPixelfxAssetKey = 'assets/pixelfx/pixelfx.min.js';

/// VFX 渲染面标识：真像素（pixelfx）或占位标记（没有该包时的诚实降级）。
const String videoShortVfxPixelRenderer = 'pixelfx_pixels';
const String videoShortVfxPlaceholderRenderer = 'placeholder_markers';

/// 播放页 CSP：只允许内联脚本/样式与 data 图片，**不允许任何网络连接**。
const String videoShortPageCsp =
    "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; "
    "img-src data:; connect-src 'none'; base-uri 'none'; form-action 'none'";

/// 出站桥全局名（页面只经 `postMessage(JSON.stringify(...))` 回传）。
const String videoShortBridge = 'NONSHORT';

/// 出站桥允许的消息种类。
const List<String> videoShortBridgeMessages = <String>[
  'ready',
  'frame',
  'ended',
  'error',
  // 抓帧回执：只在宿主显式调 `capture(frame)` 时出现（单帧 PNG data URL）。
  'evidence',
];

/// 页面侧命令面对象名。
const String videoShortController = 'NONSHORT_PLAYER';

/// 渲染器标识：Phaser 4 的 Canvas 2D 渲染面（确定性优先，不用 WebGL 抗锯齿差异）。
const String videoShortRenderer = 'phaser4_canvas';

/// 组装失败（phraser 文本缺失/剧本未编译）。
const String videoShortPhaserMissingCode = 'short_phaser_missing';
const String videoShortScreenplayInvalidCode = 'short_screenplay_invalid';

/// 播放页组装错误：`code` 是稳定机器码，`detail` 只进折叠的技术详情。
final class VideoShortPlayerError implements Exception {
  const VideoShortPlayerError(this.code, this.detail);

  final String code;
  final String detail;

  @override
  String toString() => 'VideoShortPlayerError($code: $detail)';
}

const String _cspSlot = '/*__CSP__*/';
const String _phaserSlot = '/*__PHASER_SOURCE__*/';
const String _pixelfxSlot = '/*__PIXELFX_SOURCE__*/';
const String _pixelsRendererSlot = '/*__PIXELS_RENDERER__*/';
const String _placeholderRendererSlot = '/*__PLACEHOLDER_RENDERER__*/';
const String _timelineSlot = '/*__TIMELINE_JSON__*/';
const String _widthSlot = '/*__WIDTH__*/';
const String _heightSlot = '/*__HEIGHT__*/';
const String _rendererSlot = '/*__RENDERER__*/';
const String _bridgeSlot = '/*__BRIDGE_NAME__*/';
const String _controllerSlot = '/*__CONTROLLER_NAME__*/';

const List<String> _templateSlots = <String>[
  _cspSlot,
  _phaserSlot,
  _pixelfxSlot,
  _pixelsRendererSlot,
  _placeholderRendererSlot,
  _timelineSlot,
  _widthSlot,
  _heightSlot,
  _rendererSlot,
  _bridgeSlot,
  _controllerSlot,
];

/// 组装单文件播放页。
///
/// [phaserSource] 是 `phaser.min.js` 的原文（生产由调用方经 rootBundle 读入）；
/// 空串/空白 → 显性失败（不产出没有引擎的空页面）。
/// [screenplay] 必须是**已校验通过**的剧本（调用方先跑 `verifyVideoScreenplay`）。
String assembleVideoShortPage(
  VideoScreenplay screenplay, {
  required String phaserSource,
  String pixelfxSource = '',
  VideoStylePack? stylePack,
}) {
  final String phaser = phaserSource.trim();
  if (phaser.isEmpty) {
    throw const VideoShortPlayerError(
      videoShortPhaserMissingCode,
      'phaser runtime source is empty',
    );
  }
  if (screenplay.totalFrames <= 0) {
    throw const VideoShortPlayerError(
      videoShortScreenplayInvalidCode,
      'screenplay has no frames',
    );
  }

  final String timelineJson = _embeddedJson(<String, Object?>{
    'schema': videoScreenplaySchema,
    'style': stylePack?.toJson(),
    'fps': videoScreenplayFps,
    'width': screenplay.width,
    'height': screenplay.height,
    'totalFrames': screenplay.totalFrames,
    'shots': <Object?>[
      for (final VideoScreenplayShot shot in screenplay.shots)
        <String, Object?>{
          'id': shot.id,
          'start': shot.startFrame,
          'frames': shot.frameCount,
          'events': <Object?>[
            for (final VideoScreenplayEvent event in shot.events) event.toJson(),
          ],
        },
    ],
  });

  final String pixelfx = pixelfxSource.trim().isEmpty
      ? ''
      : _inlineSource(pixelfxSource.trim());
  var page = _playerTemplate
      .replaceFirst(_cspSlot, videoShortPageCsp)
      .replaceFirst(_phaserSlot, _inlineSource(phaser))
      .replaceFirst(_pixelfxSlot, pixelfx)
      .replaceFirst(_timelineSlot, timelineJson)
      .replaceFirst(_widthSlot, '${screenplay.width}')
      .replaceFirst(_heightSlot, '${screenplay.height}')
      .replaceFirst(_rendererSlot, _embeddedJson(videoShortRenderer))
      .replaceFirst(_pixelsRendererSlot, _embeddedJson(videoShortVfxPixelRenderer))
      .replaceFirst(_placeholderRendererSlot, _embeddedJson(videoShortVfxPlaceholderRenderer))
      .replaceFirst(_bridgeSlot, _embeddedJson(videoShortBridge))
      .replaceFirst(_controllerSlot, _embeddedJson(videoShortController));

  // 没有 pixelfx 包时把整块脚本删掉（不留空 script 标签）。
  if (pixelfx.isEmpty) {
    page = page.replaceFirst(
      '<script id="short-pixelfx">\n\n</script>\n',
      '',
    );
  }

  for (final String slot in _templateSlots) {
    if (page.contains(slot)) {
      throw VideoShortPlayerError(
        videoShortScreenplayInvalidCode,
        'page template slot not replaced: $slot',
      );
    }
  }
  return page;
}

/// JSON 内嵌（转义结束标签序列，避免提前关闭脚本块）。
String _embeddedJson(Object? value) =>
    jsonEncode(value).replaceAll('</', r'<\/');

/// 源码内嵌：只做 `</script` 转义（与 3D 视频页同一口径）。
String _inlineSource(String source) => source.replaceAllMapped(
  RegExp('</script', caseSensitive: false),
  (Match match) => '<\\/script',
);

const String _playerTemplate = '''
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="/*__CSP__*/">
<title>引擎短片</title>
<style>
  html, body { margin: 0; padding: 0; background: #06080c; overflow: hidden; }
  #short-stage { display: block; margin: 0 auto; image-rendering: pixelated; }
  body { display: flex; align-items: center; justify-content: center; height: 100vh; }
</style>
</head>
<body>
<div id="short-stage"></div>
<script id="short-runtime">
/*__PHASER_SOURCE__*/
</script>
<script id="short-pixelfx">
/*__PIXELFX_SOURCE__*/
</script>
<script>
(function () {
  'use strict';

  var BRIDGE = /*__BRIDGE_NAME__*/;
  var CONTROLLER = /*__CONTROLLER_NAME__*/;
  var RENDERER = /*__RENDERER__*/;
  var RENDERER_PIXELS = /*__PIXELS_RENDERER__*/;
  var RENDERER_PLACEHOLDER = /*__PLACEHOLDER_RENDERER__*/;
  var TIMELINE = /*__TIMELINE_JSON__*/;
  var STYLE = TIMELINE.style || null;
  var WIDTH = /*__WIDTH__*/;
  var HEIGHT = /*__HEIGHT__*/;
  var FPS = TIMELINE.fps || 30;
  var TOTAL_FRAMES = TIMELINE.totalFrames || 0;

  var game = null;
  var scene = null;
  var ready = false;
  var playing = false;
  var currentFrame = 0;
  var startTimestamp = null;
  var startFrame = 0;
  var lastFrame = 0;

  // 像素渲染面：pixelfx 包在场时走真像素，否则如实降级为占位标记。
  var HAS_PIXELFX = false;
  try {
    HAS_PIXELFX = !!(window.NAN_PIXELFX && typeof window.NAN_PIXELFX.renderInto === 'function');
  } catch (err) { HAS_PIXELFX = false; }
  var VFX_RENDERER = HAS_PIXELFX ? RENDERER_PIXELS : RENDERER_PLACEHOLDER;
  var pxCanvas = null;
  var pxCtx = null;
  var tmpCanvas = null;
  var tmpCtx = null;
  var pxTexture = null;
  var currentShotColor = null;
  var SKIPPED_VFX = 0;

  function post(kind, payload) {
    try {
      var message = { kind: kind };
      if (payload) {
        for (var key in payload) {
          if (Object.prototype.hasOwnProperty.call(payload, key)) message[key] = payload[key];
        }
      }
      window[BRIDGE].postMessage(JSON.stringify(message));
    } catch (err) {
      try { console.error('short bridge failed', err); } catch (e2) {}
    }
  }

  function clampFrame(frame) {
    var value = Math.floor(Number(frame) || 0);
    if (value < 0) return 0;
    if (value > TOTAL_FRAMES - 1) return TOTAL_FRAMES - 1;
    return value;
  }

  function shotAt(frame) {
    for (var i = 0; i < TIMELINE.shots.length; i++) {
      var shot = TIMELINE.shots[i];
      if (frame >= shot.start && frame < shot.start + shot.frames) return shot;
    }
    return null;
  }

  // 风格包颜色（缺省 = 内置暗色）。
  var PALETTE = {
    background: 0x06080c,
    band: 0x141a24,
    accent: 0xffffff,
    text: 0xffffff
  };
  var FONT_SCALE = 1.0;
  var MOTION = 'linear';
  var STYLE_VFX = null;

  function hexToInt(text) {
    return parseInt(String(text).replace('#', ''), 16) || 0;
  }

  function applyStyle() {
    if (!STYLE) return;
    var palette = STYLE.palette || {};
    if (palette.background) PALETTE.background = hexToInt(palette.background);
    if (palette.band) PALETTE.band = hexToInt(palette.band);
    if (palette.accent) PALETTE.accent = hexToInt(palette.accent);
    if (palette.text) PALETTE.text = hexToInt(palette.text);
    var typography = STYLE.typography || {};
    if (typography.caption === 'sm') FONT_SCALE = 0.75;
    else if (typography.caption === 'lg') FONT_SCALE = 1.35;
    else FONT_SCALE = 1.0;
    var motion = STYLE.motion || {};
    if (motion.progress === 'ease_out') MOTION = 'ease_out';
    else if (motion.progress === 'stepped') MOTION = 'stepped';
    else MOTION = 'linear';
    if (STYLE.vfxAllowlist && STYLE.vfxAllowlist.length) {
      STYLE_VFX = {};
      for (var i = 0; i < STYLE.vfxAllowlist.length; i++) {
        STYLE_VFX[STYLE.vfxAllowlist[i]] = true;
      }
    }
  }

  // 进度曲线的确定性实现（同帧号必然同位置，不看墙钟）。
  function easeProgress(value) {
    if (MOTION === 'ease_out') return 1 - Math.pow(1 - value, 2);
    if (MOTION === 'stepped') return Math.floor(value * 8) / 8;
    return value;
  }

  function rgbOfColor(value) {
    return {
      r: (value >> 16) & 0xff,
      g: (value >> 8) & 0xff,
      b: value & 0xff
    };
  }

  // 确定性调色：HSL -> RGB 手算（不依赖引擎内部状态，同输入必然同色）。
  function shotRgb(index) {
    var hue = (index * 47) % 360;
    var s = 0.55, l = 0.24;
    var c = (1 - Math.abs(2 * l - 1)) * s;
    var x = c * (1 - Math.abs((hue / 60) % 2 - 1));
    var m = l - c / 2;
    var r = 0, g = 0, b = 0;
    if (hue < 60) { r = c; g = x; } else if (hue < 120) { r = x; g = c; }
    else if (hue < 180) { g = c; b = x; } else if (hue < 240) { g = x; b = c; }
    else if (hue < 300) { r = x; b = c; } else { r = c; b = x; }
    function channel(value) { return Math.max(0, Math.min(255, Math.floor((value + m) * 255))); }
    return { r: channel(r), g: channel(g), b: channel(b) };
  }

  function shotRgbLight(index) {
    var base = shotRgb(index);
    function lighten(value) { return Math.max(0, Math.min(255, Math.floor(value + (255 - value) * 0.28))); }
    return { r: lighten(base.r), g: lighten(base.g), b: lighten(base.b) };
  }

  function drawBackgroundPixels(shot, index, local) {
    var bg = rgbOfColor(PALETTE.background);
    var band = rgbOfColor(PALETTE.band);
    var accent = rgbOfColor(PALETTE.accent);
    pxCtx.fillStyle = 'rgb(' + bg.r + ',' + bg.g + ',' + bg.b + ')';
    pxCtx.fillRect(0, 0, WIDTH, HEIGHT);
    pxCtx.fillStyle = 'rgb(' + band.r + ',' + band.g + ',' + band.b + ')';
    pxCtx.fillRect(0, Math.floor(HEIGHT * 0.62), WIDTH, Math.floor(HEIGHT * 0.38));
    var progress = shot.frames > 1 ? easeProgress(local / (shot.frames - 1)) : 0;
    var barWidth = Math.max(2, Math.floor(WIDTH * 0.2));
    pxCtx.fillStyle = 'rgb(' + accent.r + ',' + accent.g + ',' + accent.b + ')';
    pxCtx.fillRect(Math.floor(progress * (WIDTH - barWidth)), Math.floor(HEIGHT * 0.62) - 3, barWidth, 3);
  }

  // 真像素路径：pixelfx 逐事件渲染 → 叠到像素画布 → 刷新 Phaser 画布纹理。
  function renderFramePixels(target) {
    var shot = shotAt(target);
    pxCtx.clearRect(0, 0, WIDTH, HEIGHT);
    if (!shot) {
      pxCtx.fillStyle = 'rgb(6,8,12)';
      pxCtx.fillRect(0, 0, WIDTH, HEIGHT);
    } else {
      var index = TIMELINE.shots.indexOf(shot);
      var local = target - shot.start;
      drawBackgroundPixels(shot, index, local);
      for (var i = 0; i < shot.events.length; i++) {
        var event = shot.events[i];
        if (event.type !== 'vfx') continue;
        if (event.f > local) continue;
        if (!HAS_PIXELFX) continue;
        // 风格包可以**收窄**允许的 cue（不能放大）：不在白名单里的特效跳过，
        // 并在 ready 回执里如实报数量（不静默）。
        if (STYLE_VFX && !STYLE_VFX[event.cue]) {
          SKIPPED_VFX += 1;
          continue;
        }
        var advance = local - event.f;
        try {
          tmpCtx.clearRect(0, 0, WIDTH, HEIGHT);
          window.NAN_PIXELFX.renderInto(tmpCtx, {
            cue: event.cue,
            x: Math.floor(WIDTH * 0.5) + (event.x || 0),
            y: Math.floor(HEIGHT * 0.72) + (event.y || 0),
            seed: event.seed || 0,
            flip: !!event.flip,
            advanceFrames: advance,
            fps: FPS,
            width: WIDTH,
            height: HEIGHT
          });
          pxCtx.drawImage(tmpCanvas, 0, 0);
        } catch (renderErr) {
          post('error', { message: 'vfx 渲染失败：' + String(renderErr) });
        }
      }
      // 非 VFX 事件的确定性标记（captions/shake/sfx）。
      for (var j = 0; j < shot.events.length; j++) {
        var marker = shot.events[j];
        if (marker.f > local) continue;
        if (marker.type === 'caption') {
          var text = rgbOfColor(PALETTE.text);
          pxCtx.fillStyle = 'rgba(' + text.r + ',' + text.g + ',' + text.b + ',0.18)';
          pxCtx.fillRect(
            Math.floor(WIDTH * 0.1),
            Math.floor(HEIGHT * 0.82),
            Math.floor(WIDTH * 0.8),
            Math.max(2, Math.floor(3 * FONT_SCALE)));
        } else if (marker.type === 'camera.shake') {
          pxCtx.fillStyle = 'rgba(255,255,255,0.10)';
          pxCtx.fillRect(0, 0, WIDTH, HEIGHT);
        } else if (marker.type === 'sfx') {
          pxCtx.fillStyle = 'rgba(255,255,255,0.06)';
          pxCtx.fillRect(Math.floor(WIDTH * 0.5), Math.floor(HEIGHT * 0.45), 3, 3);
        }
      }
    }
    if (pxTexture && typeof pxTexture.refresh === 'function') {
      pxTexture.refresh();
    }
    currentFrame = target;
  }

  // 占位路径（没有 pixelfx 包时）：确定性色块，明确不是像素级 VFX。
  function renderFrameMarkers(target) {
    var g = scene.__g;
    if (!g) return;
    var shot = shotAt(target);
    g.clear();
    g.fillStyle(0x06080c, 1);
    g.fillRect(0, 0, WIDTH, HEIGHT);
    if (!shot) { currentFrame = target; return; }
    var index = TIMELINE.shots.indexOf(shot);
    var local = target - shot.start;
    var color = shotRgb(index);
    var hexBase = (color.r << 16) | (color.g << 8) | color.b;
    g.fillStyle(hexBase, 1);
    g.fillRect(0, 0, WIDTH, HEIGHT);
    g.fillStyle(0xffffff, 0.85);
    var progress = shot.frames > 1 ? local / (shot.frames - 1) : 0;
    var barWidth = Math.max(2, Math.floor(WIDTH * 0.2));
    g.fillRect(Math.floor(progress * (WIDTH - barWidth)), Math.floor(HEIGHT * 0.62) - 3, barWidth, 3);
    for (var i = 0; i < shot.events.length; i++) {
      var event = shot.events[i];
      if (event.f > local) continue;
      if (event.type === 'vfx') {
        var top = event.layer === 'back' ? 0.12 : 0.34;
        var size = Math.max(3, Math.floor(10 * (event.scale || 1)));
        g.fillStyle(0xffffff, 0.9);
        g.fillRect(Math.floor(WIDTH * 0.5) + Math.floor(event.x || 0), Math.floor(HEIGHT * top) + Math.floor(event.y || 0), size, size);
      }
    }
    currentFrame = target;
  }

  function renderFrame(frame) {
    if (!scene) return;
    var target = clampFrame(frame);
    if (pxCtx && pxTexture) renderFramePixels(target);
    else renderFrameMarkers(target);
  }

  function renderCurrent() {
    renderFrame(currentFrame);
  }

  function play() {
    if (playing) return;
    if (currentFrame >= TOTAL_FRAMES - 1) currentFrame = 0;
    playing = true;
    startFrame = currentFrame;
    startTimestamp = null;
    requestTick();
  }

  function pause() {
    playing = false;
    startTimestamp = null;
    startFrame = currentFrame;
  }

  function stopPlayback() {
    playing = false;
    startTimestamp = null;
    currentFrame = 0;
    renderCurrent();
  }

  var tickHandle = 0;
  function requestTick() {
    if (!playing) return;
    tickHandle = window.requestAnimationFrame(tick);
  }

  function tick(timestamp) {
    if (!playing) return;
    if (startTimestamp === null) startTimestamp = timestamp;
    var elapsed = timestamp - startTimestamp;
    var frame = startFrame + Math.floor(elapsed / 1000 * FPS);
    if (frame >= TOTAL_FRAMES - 1) {
      currentFrame = TOTAL_FRAMES - 1;
      renderCurrent();
      playing = false;
      startTimestamp = null;
      startFrame = currentFrame;
      post('frame', { frame: currentFrame, seconds: currentFrame / FPS });
      post('ended', { frame: currentFrame });
      return;
    }
    if (frame !== lastFrame) {
      lastFrame = frame;
      renderFrame(frame);
      post('frame', { frame: frame, seconds: frame / FPS });
    }
    requestTick();
  }

  function seekFrame(frame) {
    playing = false;
    startTimestamp = null;
    var target = clampFrame(frame);
    currentFrame = target;
    renderCurrent();
    post('frame', { frame: target, seconds: target / FPS, seeked: true });
    return target;
  }

  // —— 帧证据：渲染目标帧 → 从像素画布导出 PNG → 桥回传 ——
  // 只从像素画布导出（同步、确定）；没有 pixelfx 像素面时如实报错，
  // 不去截 Phaser 的合成画布冒充「帧证据」。
  function captureFrame(frame) {
    if (!pxCanvas || !pxCtx) {
      post('error', { message: 'evidence_unavailable: 没有像素渲染面' });
      return false;
    }
    var target = clampFrame(frame);
    renderFrame(target);
    var dataUrl = '';
    try {
      dataUrl = String(pxCanvas.toDataURL('image/png'));
    } catch (err) {
      post('error', { message: 'evidence_failed: ' + String(err) });
      return false;
    }
    if (dataUrl.indexOf('data:image/png') !== 0) {
      post('error', { message: 'evidence_empty' });
      return false;
    }
    post('evidence', {
      frame: target,
      renderer: RENDERER,
      vfx: VFX_RENDERER,
      data_url: dataUrl
    });
    return true;
  }

  window[CONTROLLER] = {
    state: function () { return playing ? 'playing' : 'idle'; },
    frame: function () { return currentFrame; },
    totalFrames: function () { return TOTAL_FRAMES; },
    fps: function () { return FPS; },
    renderer: function () { return RENDERER; },
    vfxRenderer: function () { return VFX_RENDERER; },
    play: function () { play(); return true; },
    pause: function () { pause(); return true; },
    stop: function () { stopPlayback(); return true; },
    seekFrame: function (frame) { return seekFrame(frame); },
    renderFrame: function (frame) { renderFrame(frame); return true; },
    capture: captureFrame
  };

  try {
    applyStyle();
    game = new Phaser.Game({
      type: Phaser.CANVAS,
      width: WIDTH,
      height: HEIGHT,
      parent: 'short-stage',
      banner: false,
      audio: { noAudio: true },
      pixelArt: true,
      antialias: false,
      scene: {
        create: function () {
          scene = this;
          if (HAS_PIXELFX) {
            pxCanvas = document.createElement('canvas');
            pxCanvas.width = WIDTH;
            pxCanvas.height = HEIGHT;
            pxCtx = pxCanvas.getContext('2d');
            if (pxCtx) pxCtx.imageSmoothingEnabled = false;
            tmpCanvas = document.createElement('canvas');
            tmpCanvas.width = WIDTH;
            tmpCanvas.height = HEIGHT;
            tmpCtx = tmpCanvas.getContext('2d');
            if (pxCtx && tmpCtx) {
              pxTexture = scene.textures.addCanvas('short-pixels', pxCanvas);
              if (pxTexture && typeof pxTexture.setFilter === 'function') {
                pxTexture.setFilter(Phaser.Textures.FilterMode.NEAREST);
              }
              scene.add.image(0, 0, 'short-pixels').setOrigin(0, 0);
            } else {
              pxCtx = null;
              pxTexture = null;
            }
          }
          if (!pxCtx) scene.__g = scene.add.graphics();
          renderFrame(0);
          ready = true;
          post('ready', {
            fps: FPS,
            total_frames: TOTAL_FRAMES,
            width: WIDTH,
            height: HEIGHT,
            renderer: RENDERER,
            vfx: VFX_RENDERER,
            style: STYLE ? String(STYLE.id || '') : '',
            vfx_skipped: SKIPPED_VFX,
            phaser: String(Phaser.VERSION || '')
          });
        }
      }
    });
  } catch (err) {
    post('error', { message: '引擎启动失败：' + String(err) });
  }

  window.addEventListener('error', function (event) {
    post('error', { message: String(event.message || 'unknown') });
  });
  window.addEventListener('unhandledrejection', function () {
    post('error', { message: 'unhandled rejection' });
  });
})();
</script>
</body>
</html>
''';
