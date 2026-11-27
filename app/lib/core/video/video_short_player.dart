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

/// Phaser 4 vendored 运行时资源键（`build-manifest.json` 锁 sha256/字节）。
const String videoShortPhaserAssetKey = 'assets/phaser/phaser.min.js';

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
const String _timelineSlot = '/*__TIMELINE_JSON__*/';
const String _widthSlot = '/*__WIDTH__*/';
const String _heightSlot = '/*__HEIGHT__*/';
const String _rendererSlot = '/*__RENDERER__*/';
const String _bridgeSlot = '/*__BRIDGE_NAME__*/';
const String _controllerSlot = '/*__CONTROLLER_NAME__*/';

const List<String> _templateSlots = <String>[
  _cspSlot,
  _phaserSlot,
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

  var page = _playerTemplate
      .replaceFirst(_cspSlot, videoShortPageCsp)
      .replaceFirst(_phaserSlot, _inlineSource(phaser))
      .replaceFirst(_timelineSlot, timelineJson)
      .replaceFirst(_widthSlot, '${screenplay.width}')
      .replaceFirst(_heightSlot, '${screenplay.height}')
      .replaceFirst(_rendererSlot, _embeddedJson(videoShortRenderer))
      .replaceFirst(_bridgeSlot, _embeddedJson(videoShortBridge))
      .replaceFirst(_controllerSlot, _embeddedJson(videoShortController));

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
<script>
(function () {
  'use strict';

  var BRIDGE = /*__BRIDGE_NAME__*/;
  var CONTROLLER = /*__CONTROLLER_NAME__*/;
  var RENDERER = /*__RENDERER__*/;
  var TIMELINE = /*__TIMELINE_JSON__*/;
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

  function post(kind, payload) {
    try {
      var message = { kind: kind };
      if (payload) {
        for (var key in payload) {
          if (Object.prototype.hasOwnProperty.call(payload, key)) {
            message[key] = payload[key];
          }
        }
      }
      window[BRIDGE].postMessage(JSON.stringify(message));
    } catch (err) {
      // 桥不可用不致命（页面仍能自己跑）；但错误要留痕。
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

  // 确定性调色：按镜头序号取固定色相（同一剧本同一镜头永远同色）。
  function shotColor(index) {
    var hue = (index * 47) % 360;
    return { h: hue, css: 'hsl(' + hue + ', 55%, 42%)' };
  }

  // 一帧画面 = 镜头底 + 事件标记；纯函数（只吃帧号）。
  function renderFrame(frame) {
    if (!scene) return;
    var g = scene.__g;
    if (!g) return;
    var target = clampFrame(frame);
    var shot = shotAt(target);
    g.clear();
    g.fillStyle(0x06080c, 1);
    g.fillRect(0, 0, WIDTH, HEIGHT);
    if (!shot) {
      currentFrame = target;
      updateReadout();
      return;
    }
    var index = TIMELINE.shots.indexOf(shot);
    var color = shotColor(index);
    var local = target - shot.start;
    var progress = shot.frames > 1 ? local / (shot.frames - 1) : 0;
    // 镜头底：一条随进度移动的色带（只由帧号决定，可复验）。
    g.fillStyle(Phaser.Display.Color.HSLToColor(color.h / 360, 0.55, 0.24).color, 1);
    g.fillRect(0, 0, WIDTH, HEIGHT);
    g.fillStyle(Phaser.Display.Color.HSLToColor(color.h / 360, 0.55, 0.42).color, 1);
    g.fillRect(0, Math.floor(HEIGHT * 0.62), WIDTH, Math.floor(HEIGHT * 0.38));
    g.fillStyle(0xffffff, 0.85);
    var barWidth = Math.max(2, Math.floor(WIDTH * 0.2));
    g.fillRect(Math.floor(progress * (WIDTH - barWidth)), Math.floor(HEIGHT * 0.62) - 3, barWidth, 3);
    // 事件标记：按 layer 分前后；vfx 用允许的 cue 名字做确定性「占位符」。
    for (var i = 0; i < shot.events.length; i++) {
      var event = shot.events[i];
      if (event.f > local) continue;
      if (event.type === 'vfx') {
        var top = event.layer === 'back' ? 0.12 : 0.34;
        var size = Math.max(3, Math.floor(10 * (event.scale || 1)));
        g.fillStyle(Phaser.Display.Color.HSLToColor((color.h + 180) % 360 / 360, 0.7, 0.6).color, 0.9);
        g.fillRect(Math.floor(WIDTH * 0.5) + Math.floor(event.x || 0), Math.floor(HEIGHT * top) + Math.floor(event.y || 0), size, size);
      } else if (event.type === 'caption') {
        g.fillStyle(0xffffff, 0.18);
        g.fillRect(Math.floor(WIDTH * 0.1), Math.floor(HEIGHT * 0.82), Math.floor(WIDTH * 0.8), 3);
      } else if (event.type === 'camera.shake') {
        g.fillStyle(0xffffff, 0.10);
        g.fillRect(0, 0, WIDTH, HEIGHT);
      } else if (event.type === 'sfx') {
        g.fillStyle(0xffffff, 0.06);
        g.fillRect(Math.floor(WIDTH * 0.5), Math.floor(HEIGHT * 0.45), 3, 3);
      }
    }
    currentFrame = target;
    updateReadout();
  }

  function updateReadout() {
    // 页面上不放宿主文案（文案由 Flutter 侧出）；这里只留像素画布。
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
      renderCurrent();
      post('frame', { frame: frame, seconds: frame / FPS });
    }
    requestTick();
  }

  function seekFrame(frame) {
    playing = false;
    startTimestamp = null;
    var target = clampFrame(frame);
    currentFrame = target;
    // 播放中 seek：把播放头落到目标帧并从那里继续。
    if (target >= TOTAL_FRAMES - 1) {
      playing = false;
    }
    renderCurrent();
    post('frame', { frame: target, seconds: target / FPS, seeked: true });
    return target;
  }

  window[CONTROLLER] = {
    state: function () { return playing ? 'playing' : 'idle'; },
    frame: function () { return currentFrame; },
    totalFrames: function () { return TOTAL_FRAMES; },
    fps: function () { return FPS; },
    renderer: function () { return RENDERER; },
    play: function () { play(); return true; },
    pause: function () { pause(); return true; },
    stop: function () { stopPlayback(); return true; },
    seekFrame: function (frame) { return seekFrame(frame); },
    renderFrame: function (frame) { renderFrame(frame); return true; }
  };

  try {
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
          scene.__g = scene.add.graphics();
          renderFrame(0);
          ready = true;
          post('ready', {
            fps: FPS,
            total_frames: TOTAL_FRAMES,
            width: WIDTH,
            height: HEIGHT,
            renderer: RENDERER,
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
