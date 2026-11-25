/// 音乐播放页编译产物（纯 Dart 字符串组装，不接 UI / 不构造 WebView）。
///
/// 契约见 `docs/music-contract.md` §5 与 `docs/plan-music-module.md` §4：
/// [assembleMusicPlayer] 把 [MusicScore]（唯一事实源）与 [MusicPlayPlan]
/// （整数 tick 编译产物）组装成**自包含单文件 HTML**，供 WebView 以离线单文件方式
/// 直接加载：
///
///  * 内嵌 score / playplan JSON 字面量，页面不读任何本地文件，零外联；
///  * Web Audio lookahead 调度器：`setInterval` **25ms**、提前 **100ms** 把事件
///    排进音频时钟（页面后台节流时窗口放宽到 2s）；调度只用
///    `AudioContext.currentTime`，定时器回调不直接 `start()` 播放；
///  * 演奏面：播放 / 暂停 / 停止 / seek、每轨音量 / 静音；
///  * 音色：六种纯代码合成（piano / strings / bass / bell / organ / pluck）
///    + 鼓组（kick / snare / hihat / openhat / crash / ride / tom）；
///    不引第三方音频库、不内嵌音频采样文件、不做动态代码求值；
///  * `window.NONMUSIC` 回传 `beat` / `ended` / `error` 三类桥消息（与
///    `window.NON3D` 同模式）；宿主可经 `window.NONMUSIC_PLAYER` 驱动运输条；
///  * 固定 CSP：`default-src 'none'; script-src 'unsafe-inline';
///    connect-src 'none'; frame-ancestors 'none'`；`AudioContext` 只由播放
///    按钮的用户手势启动；
///  * 确定性：同一 `score + playplan` 两次组装**字节相同**（测试锚定），
///    HTML 不出现 `http(s)://` 外链、不依赖本地文件。
library;

import 'dart:convert';

import 'music_compile.dart';
import 'music_score.dart';

/// 播放页固定 CSP（比 3D 更紧：无动态求值 / worker / 媒体源，也不放开图片字体）。
const String musicPlayerCsp =
    "default-src 'none'; script-src 'unsafe-inline'; "
    "connect-src 'none'; frame-ancestors 'none'";

/// lookahead 定时器周期（毫秒）；契约固定 25ms。
const int musicPlayerLookaheadTimerMs = 25;

/// lookahead 提前排队的窗口（秒）；契约固定 100ms。
const double musicPlayerLookaheadAheadSeconds = 0.1;

/// 页面被后台节流时的宽窗口（秒）；契约 §5 允许提高到 2s。
const double musicPlayerBackgroundAheadSeconds = 2.0;

/// 桥消息面：只允许 `beat` / `ended` / `error` 三类（与契约 §5 逐字对齐）。
const List<String> musicPlayerBridgeMessages = <String>[
  'beat',
  'ended',
  'error',
];

/// 页面内置合成的六种音色名（必须命中 `music_score.dart` 的乐器注册表）。
const List<String> musicPlayerTimbres = <String>[
  'piano',
  'strings',
  'bass',
  'bell',
  'organ',
  'pluck',
];

/// 页面内置的鼓件名（必须命中 `music_score.dart` 的鼓件表）。
const List<String> musicPlayerDrumPieces = <String>[
  'kick',
  'snare',
  'hihat',
  'openhat',
  'crash',
  'ride',
  'tom',
];

/// 组装失败（模板占位缺失/不唯一等）；显性失败，不产出半成品页面。
final class MusicPlayerError implements Exception {
  const MusicPlayerError(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'MusicPlayerError($code: $message)';
}

/// 把 [score] 与 [plan] 组装成自包含单文件 HTML（确定性、零外联）。
///
/// [plan] 应来自 [compileMusicScore]；这里不重算 tick，只做页面组装。
/// 同一输入两次调用返回**逐字节相同**的字符串（无时间戳/随机数/哈希序）。
String assembleMusicPlayer(MusicScore score, MusicPlayPlan plan) {
  final String scoreJson = _embeddedJson(score.toJson());
  final String planJson = _embeddedJson(plan.toJson());
  for (final String slot in _templateSlots) {
    _requireSingleSlot(_musicPlayerTemplate, slot);
  }
  return _musicPlayerTemplate
      .replaceFirst(_cspSlot, musicPlayerCsp)
      .replaceFirst(_lookaheadTimerSlot, '$musicPlayerLookaheadTimerMs')
      .replaceFirst(_lookaheadAheadSlot, '$musicPlayerLookaheadAheadSeconds')
      .replaceFirst(
        _lookaheadBackgroundSlot,
        '$musicPlayerBackgroundAheadSeconds',
      )
      .replaceFirst(_scoreSlot, scoreJson)
      .replaceFirst(_planSlot, planJson);
}

// ---------------------------------------------------------------------------
// 组装细节
// ---------------------------------------------------------------------------

const String _cspSlot = '/*__CSP__*/';
const String _lookaheadTimerSlot = '/*__LOOKAHEAD_MS__*/';
const String _lookaheadAheadSlot = '/*__AHEAD_SEC__*/';
const String _lookaheadBackgroundSlot = '/*__AHEAD_BG_SEC__*/';
const String _scoreSlot = '/*__SCORE_JSON__*/';
const String _planSlot = '/*__PLAN_JSON__*/';
const List<String> _templateSlots = <String>[
  _cspSlot,
  _lookaheadTimerSlot,
  _lookaheadAheadSlot,
  _lookaheadBackgroundSlot,
  _scoreSlot,
  _planSlot,
];

void _requireSingleSlot(String template, String slot) {
  final int first = template.indexOf(slot);
  if (first < 0 || first != template.lastIndexOf(slot)) {
    throw MusicPlayerError(
      'music_player_template_invalid',
      '播放页模板占位必须恰好出现一次：$slot',
    );
  }
}

/// JSON 作为内联脚本字面量：把 HTML 有意义的字符写成 JSON 转义。
///
/// 乐谱标题等用户/Agent 内容属于不可信输入——字面量里的 `</script>` 会提前
/// 关闭内联脚本。jsonEncode 本身不转义 `<` / `>` / `&`，这里补上；U+2028 /
/// U+2029 也转义（旧 JS 行终止符会让字面量语法失效）。全部是**输入无关的
/// 固定替换**，因此字节确定性不受影响。
String _embeddedJson(Object? value) {
  final String encoded = jsonEncode(value);
  return encoded
      .replaceAll('&', r'\u0026')
      .replaceAll('<', r'\u003c')
      .replaceAll('>', r'\u003e')
      .replaceAll('\u2028', r'\u2028')
      .replaceAll('\u2029', r'\u2029');
}

/// 播放页模板：占位由 [assembleMusicPlayer] 填充，禁止任何外链入口。
///
/// 页面结构保持极简（标题 / 运输条 / 进度 / 轨道条 / 状态），样式经 CSSOM
/// 设置：固定 CSP 未放开样式源，内联样式块与 style 属性都会落回
/// `default-src 'none'` 被拦截，CSSOM 属性赋值不受 CSP 管辖；样式失败也不
/// 影响播放，页面仍可操作。
const String _musicPlayerTemplate = r'''<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="/*__CSP__*/">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>音乐播放</title>
</head>
<body>
<main id="music-player">
  <h1 id="music-title">音乐播放</h1>
  <p id="music-meta"></p>
  <div id="music-transport">
    <button id="music-play" type="button">播放</button>
    <button id="music-pause" type="button">暂停</button>
    <button id="music-stop" type="button">停止</button>
  </div>
  <input id="music-seek" type="range" min="0" max="1000" step="1" value="0">
  <p id="music-clock">0:00 / 0:00</p>
  <div id="music-tracks"></div>
  <p id="music-status">就绪</p>
</main>
<script>
(function () {
'use strict';

// 组装时注入：score.json（唯一事实源）与整数 tick 的播放计划（二者均为确定字节）。
var SCORE = /*__SCORE_JSON__*/;
var PLAN = /*__PLAN_JSON__*/;

// 契约固定调度参数：25ms 定时器只负责把窗口内事件提前排队；唯一时钟是
// AudioContext.currentTime；页面后台节流时窗口放宽到 2s。
var LOOKAHEAD_MS = /*__LOOKAHEAD_MS__*/;
var AHEAD_SEC = /*__AHEAD_SEC__*/;
var AHEAD_BG_SEC = /*__AHEAD_BG_SEC__*/;
var PPQ = Number(PLAN && PLAN.ppq) > 0 ? Number(PLAN.ppq) : 3840;
var MASTER_GAIN = 0.85;
var FADE_SEC = 0.05;

// —— window.NONMUSIC 回传桥（宿主 JavaScriptChannel；离线直开时为静默降级） ——
function postMessage(kind, payload) {
  var obj = { kind: kind };
  if (payload) {
    for (var key in payload) {
      if (Object.prototype.hasOwnProperty.call(payload, key)) obj[key] = payload[key];
    }
  }
  try {
    if (window.NONMUSIC && typeof window.NONMUSIC.postMessage === 'function') {
      window.NONMUSIC.postMessage(JSON.stringify(obj));
    }
  } catch (err) {}
}

function reportError(message) {
  var text = String(message);
  var statusEl = document.getElementById('music-status');
  if (statusEl) statusEl.textContent = '播放出错：' + text;
  postMessage('error', { message: text });
}

window.addEventListener('error', function (event) {
  reportError(event && event.message ? event.message : '未知错误');
});
window.addEventListener('unhandledrejection', function () {
  reportError('异步执行失败');
});

// —— 基础工具 ——
function clampNumber(value, min, max) {
  var n = Number(value);
  if (!isFinite(n)) return min;
  if (n < min) return min;
  if (n > max) return max;
  return n;
}

function midiToHz(midi) {
  return 440 * Math.pow(2, (midi - 69) / 12);
}

// —— 时间模型：整数 tick ↔ 秒（分段常数 BPM；秒只在播放/显示时派生） ——
var TEMPO = buildTempoMap();

function buildTempoMap() {
  var source = (PLAN && PLAN.tempoMap && PLAN.tempoMap.length)
    ? PLAN.tempoMap
    : [{ tick: 0, bpm: SCORE.tempo || 120 }];
  var map = [];
  for (var i = 0; i < source.length; i++) {
    map.push({
      tick: Math.max(0, Number(source[i].tick) || 0),
      bpm: clampNumber(source[i].bpm, 20, 300)
    });
  }
  map.sort(function (a, b) { return a.tick - b.tick; });
  if (!map.length || map[0].tick !== 0) {
    map.unshift({ tick: 0, bpm: clampNumber(SCORE.tempo || 120, 20, 300) });
  }
  return map;
}

function ticksToSec(ticks, bpm) {
  return ticks * 60.0 / (bpm * PPQ);
}

function tickToSec(tick) {
  var target = Number(tick) || 0;
  if (target <= 0) return 0;
  var sec = 0;
  var lastTick = 0;
  var bpm = TEMPO[0].bpm;
  for (var i = 0; i < TEMPO.length; i++) {
    var entry = TEMPO[i];
    if (entry.tick <= 0) {
      bpm = entry.bpm;
      continue;
    }
    if (entry.tick >= target) break;
    sec += ticksToSec(entry.tick - lastTick, bpm);
    lastTick = entry.tick;
    bpm = entry.bpm;
  }
  return sec + ticksToSec(target - lastTick, bpm);
}

function secToTick(sec) {
  var target = Number(sec) || 0;
  if (target <= 0) return 0;
  var remaining = target;
  var lastTick = 0;
  var bpm = TEMPO[0].bpm;
  for (var i = 0; i < TEMPO.length; i++) {
    var entry = TEMPO[i];
    if (entry.tick <= 0) {
      bpm = entry.bpm;
      continue;
    }
    var segment = ticksToSec(entry.tick - lastTick, bpm);
    if (segment > 0 && remaining < segment) break;
    remaining -= segment;
    lastTick = entry.tick;
    bpm = entry.bpm;
  }
  return lastTick + remaining * bpm * PPQ / 60.0;
}

// —— 事件表：按拍点排序（编译产物按轨道分组，运行时必须先排序） ——
var EVENTS = buildEvents();
var TOTAL_SEC = totalSeconds();

function buildEvents() {
  var source = (PLAN && PLAN.events && PLAN.events.length) ? PLAN.events : [];
  var trackOrder = Object.create(null);
  if (PLAN && PLAN.tracks) {
    for (var t = 0; t < PLAN.tracks.length; t++) trackOrder[PLAN.tracks[t]] = t;
  }
  var list = [];
  for (var i = 0; i < source.length; i++) {
    var raw = source[i];
    if (!raw) continue;
    var startTick = Math.max(0, Number(raw.start) || 0);
    var endTick = startTick + Math.max(0, Number(raw.dur) || 0);
    var startSec = tickToSec(startTick);
    var endSec = tickToSec(endTick);
    list.push({
      startSec: startSec,
      endSec: endSec,
      durSec: Math.max(0, endSec - startSec),
      rest: raw.rest === true,
      track: String(raw.track || ''),
      instrument: String(raw.instrument || 'piano'),
      midi: Number(raw.midi) || 0,
      drum: String(raw.drum || ''),
      order: i
    });
  }
  list.sort(function (a, b) {
    if (a.startSec !== b.startSec) return a.startSec - b.startSec;
    var oa = trackOrder[a.track];
    var ob = trackOrder[b.track];
    if (oa === undefined) oa = 9999;
    if (ob === undefined) ob = 9999;
    if (oa !== ob) return oa - ob;
    return a.order - b.order;
  });
  return list;
}

function totalSeconds() {
  var planned = tickToSec(Math.max(0, Number(PLAN && PLAN.totalTicks) || 0));
  var last = 0;
  for (var i = 0; i < EVENTS.length; i++) {
    if (EVENTS[i].endSec > last) last = EVENTS[i].endSec;
  }
  return Math.max(planned, last, 0);
}

function barOf(tick) {
  var sig = (SCORE && SCORE.timeSig && SCORE.timeSig.length === 2) ? SCORE.timeSig : [4, 4];
  var ticksPerBeat = PPQ * 4 / (Number(sig[1]) || 4);
  var ticksPerBar = ticksPerBeat * (Number(sig[0]) || 4);
  if (ticksPerBar <= 0) return 1;
  return Math.floor(Number(tick) / ticksPerBar) + 1;
}

// —— 轨道混音状态（音量/静音；未知字段一律有安全默认） ——
var trackVolumes = Object.create(null);
var trackMuted = Object.create(null);
var trackGains = Object.create(null);
var trackSliders = Object.create(null);
var trackMuteButtons = Object.create(null);
initTrackMixerState();

function initTrackMixerState() {
  var tracks = (SCORE && SCORE.tracks) ? SCORE.tracks : [];
  for (var i = 0; i < tracks.length; i++) {
    var id = String(tracks[i].id || '');
    if (!id) continue;
    trackVolumes[id] = clampNumber(tracks[i].volume, 0, 1);
    trackMuted[id] = tracks[i].muted === true;
  }
}

function trackMixValue(trackId) {
  if (trackMuted[trackId]) return 0;
  var volume = trackVolumes[trackId];
  return volume === undefined ? 1 : volume;
}

// —— 音频图与运输状态 ——
var audioCtx = null;
var master = null;
var noiseBuffer = null;
var activeVoices = [];
var state = 'idle';
var positionSec = 0;
var startedAtCtx = 0;
var nextEventIndex = 0;
var timerId = 0;
var generation = 0;
var lastBeat = -1;
var endedSent = false;

function ensureAudio() {
  if (audioCtx) return true;
  var Ctor = window.AudioContext || window.webkitAudioContext;
  if (!Ctor) {
    reportError('当前环境不支持音频上下文');
    return false;
  }
  try {
    audioCtx = new Ctor();
  } catch (err) {
    audioCtx = null;
    reportError('音频上下文创建失败');
    return false;
  }
  var now = audioCtx.currentTime;
  master = audioCtx.createGain();
  master.gain.setValueAtTime(MASTER_GAIN, now);
  master.connect(audioCtx.destination);
  var tracks = (SCORE && SCORE.tracks) ? SCORE.tracks : [];
  for (var i = 0; i < tracks.length; i++) {
    var trackId = String(tracks[i].id || '');
    if (!trackId) continue;
    var gainNode = audioCtx.createGain();
    gainNode.gain.setValueAtTime(trackMixValue(trackId), now);
    gainNode.connect(master);
    trackGains[trackId] = gainNode;
  }
  noiseBuffer = makeNoiseBuffer();
  return true;
}

function resumeAudio() {
  if (!audioCtx || typeof audioCtx.resume !== 'function') return;
  if (audioCtx.state === 'suspended') {
    try { audioCtx.resume(); } catch (err) {}
  }
}

// 固定种子 xorshift：同一页面每次启动得到同一段噪声（合成确定、每次启动可复现）。
function makeNoiseBuffer() {
  var length = Math.floor(audioCtx.sampleRate * 2.0);
  var buffer = audioCtx.createBuffer(1, length, audioCtx.sampleRate);
  var data = buffer.getChannelData(0);
  var seed = 2463534242;
  for (var i = 0; i < length; i++) {
    seed ^= seed << 13;
    seed ^= seed >>> 17;
    seed ^= seed << 5;
    data[i] = (seed >>> 0) / 2147483648.0 - 1.0;
  }
  return buffer;
}

function displayPosition() {
  if (state === 'playing' && audioCtx) {
    return clampNumber(positionSec + (audioCtx.currentTime - startedAtCtx), 0, TOTAL_SEC);
  }
  return positionSec;
}

// —— 播放 / 暂停 / 停止 / seek ——
function play() {
  if (TOTAL_SEC <= 0.001) {
    reportError('乐谱没有可播放的内容');
    return;
  }
  if (!ensureAudio()) return;
  resumeAudio();
  if (state === 'playing') return;
  if (positionSec >= TOTAL_SEC - 0.000001) positionSec = 0;
  generation += 1;
  startedAtCtx = audioCtx.currentTime;
  lastBeat = -1;
  endedSent = false;
  state = 'playing';
  restoreMasterGain();
  resetCursor(positionSec);
  startTimer();
  updateUi();
}

function pause() {
  if (state !== 'playing' || !audioCtx) return;
  positionSec = displayPosition();
  state = 'paused';
  generation += 1;
  var guard = generation;
  stopTimer();
  fadeOutAndStop(guard);
  updateUi();
}

function stopPlayback() {
  generation += 1;
  state = 'idle';
  positionSec = 0;
  lastBeat = -1;
  endedSent = false;
  stopTimer();
  stopVoices();
  restoreMasterGain();
  updateUi();
}

function seek(seconds) {
  var target = clampNumber(seconds, 0, TOTAL_SEC);
  endedSent = false;
  if (state === 'playing' && audioCtx) {
    generation += 1;
    stopVoices();
    positionSec = target;
    startedAtCtx = audioCtx.currentTime;
    lastBeat = -1;
    restoreMasterGain();
  } else {
    positionSec = target;
  }
  resetCursor(positionSec);
  updateUi();
}

function restoreMasterGain() {
  if (!audioCtx || !master) return;
  var now = audioCtx.currentTime;
  try {
    master.gain.cancelScheduledValues(now);
    master.gain.setValueAtTime(MASTER_GAIN, now);
  } catch (err) {}
}

function fadeOutAndStop(guard) {
  if (!audioCtx || !master) {
    stopVoices();
    return;
  }
  var now = audioCtx.currentTime;
  try {
    master.gain.cancelScheduledValues(now);
    master.gain.setValueAtTime(MASTER_GAIN, now);
    master.gain.linearRampToValueAtTime(0, now + FADE_SEC);
  } catch (err) {}
  window.setTimeout(function () {
    if (guard !== generation) return;
    stopVoices();
    restoreMasterGain();
  }, Math.round(FADE_SEC * 1000) + 20);
}

function startTimer() {
  stopTimer();
  timerId = window.setInterval(schedulerTick, LOOKAHEAD_MS);
  schedulerTick();
}

function stopTimer() {
  if (timerId) {
    window.clearInterval(timerId);
    timerId = 0;
  }
}

function resetCursor(fromSec) {
  nextEventIndex = 0;
  while (nextEventIndex < EVENTS.length &&
    EVENTS[nextEventIndex].endSec <= fromSec + 0.000001) {
    nextEventIndex += 1;
  }
}

// —— lookahead 调度：只有这里把事件排进 AudioContext 时钟 ——
function schedulerTick() {
  if (state !== 'playing' || !audioCtx) return;
  try {
    var now = audioCtx.currentTime;
    pruneVoices(now);
    var ahead = (typeof document.hidden === 'boolean' && document.hidden)
      ? AHEAD_BG_SEC
      : AHEAD_SEC;
    var songAtNow = positionSec + (now - startedAtCtx);
    var horizon = songAtNow + ahead;
    while (nextEventIndex < EVENTS.length &&
      EVENTS[nextEventIndex].startSec <= horizon) {
      var event = EVENTS[nextEventIndex];
      nextEventIndex += 1;
      if (event.rest || event.durSec <= 0) continue;
      scheduleEvent(event, now);
    }
    var tick = secToTick(songAtNow);
    var beatIndex = Math.floor(tick / PPQ + 1e-9);
    if (beatIndex > lastBeat) {
      lastBeat = beatIndex;
      postMessage('beat', {
        beat: beatIndex,
        bar: barOf(tick),
        tick: tick,
        position: songAtNow,
        total: TOTAL_SEC
      });
    }
    updateUi();
    if (!endedSent && songAtNow >= TOTAL_SEC - 0.000001) finishPlayback();
  } catch (err) {
    reportError('调度失败：' + (err && err.message ? err.message : String(err)));
  }
}

function finishPlayback() {
  if (endedSent) return;
  endedSent = true;
  state = 'idle';
  positionSec = 0;
  lastBeat = -1;
  generation += 1;
  stopTimer();
  stopVoices();
  restoreMasterGain();
  updateUi();
  postMessage('ended', { position: TOTAL_SEC, total: TOTAL_SEC });
}

function pruneVoices(now) {
  var keep = [];
  for (var i = 0; i < activeVoices.length; i++) {
    var voice = activeVoices[i];
    if (voice.endTime > now) {
      keep.push(voice);
      continue;
    }
    for (var n = 0; n < voice.nodes.length; n++) {
      try { voice.nodes[n].disconnect(); } catch (err) {}
    }
  }
  activeVoices = keep;
}

function stopVoices() {
  var voices = activeVoices;
  activeVoices = [];
  if (!audioCtx) return;
  var now = audioCtx.currentTime;
  for (var i = 0; i < voices.length; i++) {
    for (var n = 0; n < voices[i].nodes.length; n++) {
      var node = voices[i].nodes[n];
      try {
        if (typeof node.stop === 'function') node.stop(now);
      } catch (err) {}
      try { node.disconnect(); } catch (err) {}
    }
  }
}

function scheduleEvent(event, nowCtx) {
  var dest = trackGains[event.track] || master;
  if (!dest) return;
  var songAtNow = positionSec + (nowCtx - startedAtCtx);
  var when = startedAtCtx + event.startSec - positionSec;
  var overlap = songAtNow - event.startSec;
  var playDur = overlap > 0 ? event.endSec - songAtNow : event.durSec;
  if (when < nowCtx) when = nowCtx;
  if (playDur <= 0.005) return;
  var nodes = [];
  var endAt;
  if (event.instrument === 'drums') {
    endAt = scheduleDrum(event.drum, event.order, dest, when, nodes);
  } else {
    endAt = scheduleTimbre(event.instrument, event.midi, dest, when, playDur, nodes);
  }
  if (endAt <= when) {
    for (var i = 0; i < nodes.length; i++) {
      try { nodes[i].disconnect(); } catch (err) {}
    }
    return;
  }
  activeVoices.push({ nodes: nodes, endTime: endAt });
}

function scheduleTimbre(instrument, midi, dest, when, dur, nodes) {
  switch (instrument) {
    case 'strings':
      return voiceStrings(midi, dest, when, dur, nodes);
    case 'bass':
      return voiceBass(midi, dest, when, dur, nodes);
    case 'bell':
      return voiceBell(midi, dest, when, dur, nodes);
    case 'organ':
      return voiceOrgan(midi, dest, when, dur, nodes);
    case 'pluck':
      return voicePluck(midi, dest, when, dur, nodes);
    case 'piano':
    default:
      return voicePiano(midi, dest, when, dur, nodes);
  }
}

function oscillator(type, hz, when, stopAt, nodes) {
  var osc = audioCtx.createOscillator();
  osc.type = type;
  osc.frequency.setValueAtTime(hz, when);
  osc.start(when);
  osc.stop(stopAt);
  nodes.push(osc);
  return osc;
}

// —— 六种纯代码音色 ——
function voicePiano(midi, dest, when, dur, nodes) {
  var hz = midiToHz(midi);
  var tail = clampNumber(dur, 0.08, 4.0);
  var stopAt = when + tail + 0.02;
  var gain = audioCtx.createGain();
  gain.connect(dest);
  gain.gain.setValueAtTime(0.0001, when);
  gain.gain.linearRampToValueAtTime(0.85, when + 0.005);
  gain.gain.exponentialRampToValueAtTime(0.0001, when + tail);
  oscillator('triangle', hz, when, stopAt, nodes).connect(gain);
  var overtone = oscillator('sine', hz * 2, when, stopAt, nodes);
  var overtoneGain = audioCtx.createGain();
  overtoneGain.gain.setValueAtTime(0.25, when);
  overtoneGain.connect(gain);
  overtone.connect(overtoneGain);
  return stopAt;
}

function voiceStrings(midi, dest, when, dur, nodes) {
  var hz = midiToHz(midi);
  var attack = clampNumber(dur * 0.35, 0.04, 0.18);
  var release = 0.12;
  var stopAt = when + Math.max(dur, attack + release + 0.02) + 0.01;
  var holdEnd = stopAt - release;
  var gain = audioCtx.createGain();
  gain.connect(dest);
  gain.gain.setValueAtTime(0.0001, when);
  gain.gain.linearRampToValueAtTime(0.7, when + attack);
  gain.gain.setValueAtTime(0.7, holdEnd);
  gain.gain.exponentialRampToValueAtTime(0.0001, stopAt);
  var filter = audioCtx.createBiquadFilter();
  filter.type = 'lowpass';
  filter.frequency.setValueAtTime(Math.min(4200, hz * 3.2 + 500), when);
  filter.Q.setValueAtTime(0.7, when);
  filter.connect(gain);
  oscillator('sawtooth', hz, when, stopAt, nodes).connect(filter);
  oscillator('sawtooth', hz * 1.004, when, stopAt, nodes).connect(filter);
  return stopAt;
}

function voiceBass(midi, dest, when, dur, nodes) {
  var hz = midiToHz(Math.max(0, midi - 12));
  var tail = clampNumber(dur, 0.08, 4.0);
  var stopAt = when + tail + 0.02;
  var gain = audioCtx.createGain();
  gain.connect(dest);
  gain.gain.setValueAtTime(0.0001, when);
  gain.gain.linearRampToValueAtTime(0.75, when + 0.012);
  gain.gain.exponentialRampToValueAtTime(0.0001, when + tail);
  oscillator('sine', hz, when, stopAt, nodes).connect(gain);
  return stopAt;
}

function voiceBell(midi, dest, when, dur, nodes) {
  var hz = midiToHz(midi);
  var tail = clampNumber(dur * 1.2, 0.3, 1.6);
  var stopAt = when + tail + 0.02;
  var carrier = oscillator('sine', hz, when, stopAt, nodes);
  var modulator = oscillator('sine', hz * 2.4, when, stopAt, nodes);
  var modDepth = audioCtx.createGain();
  modDepth.gain.setValueAtTime(hz * 1.1, when);
  modulator.connect(modDepth);
  modDepth.connect(carrier.frequency);
  var gain = audioCtx.createGain();
  gain.connect(dest);
  gain.gain.setValueAtTime(0.0001, when);
  gain.gain.linearRampToValueAtTime(0.7, when + 0.004);
  gain.gain.exponentialRampToValueAtTime(0.0001, when + tail);
  carrier.connect(gain);
  return stopAt;
}

function voiceOrgan(midi, dest, when, dur, nodes) {
  var hz = midiToHz(midi);
  var release = 0.1;
  var stopAt = when + Math.max(dur, 0.06) + release;
  var holdEnd = stopAt - release;
  var gain = audioCtx.createGain();
  gain.connect(dest);
  gain.gain.setValueAtTime(0.0001, when);
  gain.gain.linearRampToValueAtTime(0.65, when + 0.02);
  gain.gain.setValueAtTime(0.65, holdEnd);
  gain.gain.exponentialRampToValueAtTime(0.0001, stopAt);
  var partial1 = oscillator('sine', hz, when, stopAt, nodes);
  var partial2 = oscillator('sine', hz * 2, when, stopAt, nodes);
  var partial3 = oscillator('sine', hz * 3, when, stopAt, nodes);
  var mix2 = audioCtx.createGain();
  mix2.gain.setValueAtTime(0.5, when);
  var mix3 = audioCtx.createGain();
  mix3.gain.setValueAtTime(0.28, when);
  partial1.connect(gain);
  partial2.connect(mix2);
  mix2.connect(gain);
  partial3.connect(mix3);
  mix3.connect(gain);
  return stopAt;
}

function voicePluck(midi, dest, when, dur, nodes) {
  var hz = midiToHz(midi);
  var tail = clampNumber(dur, 0.12, 1.2);
  var stopAt = when + tail + 0.02;
  var gain = audioCtx.createGain();
  gain.connect(dest);
  gain.gain.setValueAtTime(0.0001, when);
  gain.gain.linearRampToValueAtTime(0.8, when + 0.003);
  gain.gain.exponentialRampToValueAtTime(0.0001, when + tail);
  var filter = audioCtx.createBiquadFilter();
  filter.type = 'lowpass';
  filter.frequency.setValueAtTime(Math.min(5200, hz * 5 + 700), when);
  filter.Q.setValueAtTime(1.1, when);
  filter.connect(gain);
  oscillator('sawtooth', hz, when, stopAt, nodes).connect(filter);
  return stopAt;
}

// —— 鼓组：噪声脉冲 + 定音高扫频（纯代码，全部来自同一段确定噪声） ——
function noiseSource(order, when, stopAt, nodes) {
  var source = audioCtx.createBufferSource();
  source.buffer = noiseBuffer;
  var offset = Math.min(0.8, (order % 251) * 0.0031);
  source.start(when, offset);
  try { source.stop(stopAt); } catch (err) {}
  nodes.push(source);
  return source;
}

function noiseHit(order, dest, when, tail, highpassHz, peak, nodes) {
  var stopAt = when + tail + 0.02;
  var noise = noiseSource(order, when, stopAt, nodes);
  var filter = audioCtx.createBiquadFilter();
  filter.type = 'highpass';
  filter.frequency.setValueAtTime(highpassHz, when);
  filter.Q.setValueAtTime(0.8, when);
  var gain = audioCtx.createGain();
  gain.connect(dest);
  gain.gain.setValueAtTime(0.0001, when);
  gain.gain.linearRampToValueAtTime(peak, when + 0.003);
  gain.gain.exponentialRampToValueAtTime(0.0001, when + Math.max(0.01, tail));
  noise.connect(filter);
  filter.connect(gain);
  return stopAt;
}

function scheduleDrum(drum, order, dest, when, nodes) {
  switch (drum) {
    case 'snare':
      return drumSnare(order, dest, when, nodes);
    case 'hihat':
      return drumHihat(order, dest, when, nodes);
    case 'openhat':
      return drumOpenhat(order, dest, when, nodes);
    case 'crash':
      return drumCrash(order, dest, when, nodes);
    case 'ride':
      return drumRide(order, dest, when, nodes);
    case 'tom':
      return drumTom(order, dest, when, nodes);
    case 'kick':
    default:
      return drumKick(dest, when, nodes);
  }
}

function drumKick(dest, when, nodes) {
  var stopAt = when + 0.32;
  var gain = audioCtx.createGain();
  gain.connect(dest);
  gain.gain.setValueAtTime(0.0001, when);
  gain.gain.linearRampToValueAtTime(0.9, when + 0.004);
  gain.gain.exponentialRampToValueAtTime(0.0001, when + 0.28);
  var body = oscillator('sine', 150, when, stopAt, nodes);
  body.frequency.exponentialRampToValueAtTime(45, when + 0.09);
  body.connect(gain);
  return stopAt;
}

function drumSnare(order, dest, when, nodes) {
  var stopAt = when + 0.2;
  var noise = noiseSource(order, when, stopAt, nodes);
  var filter = audioCtx.createBiquadFilter();
  filter.type = 'highpass';
  filter.frequency.setValueAtTime(650, when);
  var noiseGain = audioCtx.createGain();
  noiseGain.connect(dest);
  noiseGain.gain.setValueAtTime(0.0001, when);
  noiseGain.gain.linearRampToValueAtTime(0.65, when + 0.004);
  noiseGain.gain.exponentialRampToValueAtTime(0.0001, when + 0.16);
  noise.connect(filter);
  filter.connect(noiseGain);
  var body = oscillator('sine', 190, when, when + 0.1, nodes);
  var bodyGain = audioCtx.createGain();
  bodyGain.connect(dest);
  bodyGain.gain.setValueAtTime(0.0001, when);
  bodyGain.gain.linearRampToValueAtTime(0.35, when + 0.003);
  bodyGain.gain.exponentialRampToValueAtTime(0.0001, when + 0.09);
  body.connect(bodyGain);
  return stopAt;
}

function drumHihat(order, dest, when, nodes) {
  return noiseHit(order, dest, when, 0.05, 6800, 0.5, nodes);
}

function drumOpenhat(order, dest, when, nodes) {
  return noiseHit(order, dest, when, 0.22, 5200, 0.5, nodes);
}

function drumCrash(order, dest, when, nodes) {
  return noiseHit(order, dest, when, 0.45, 3200, 0.55, nodes);
}

function drumRide(order, dest, when, nodes) {
  return noiseHit(order, dest, when, 0.3, 3800, 0.5, nodes);
}

function drumTom(order, dest, when, nodes) {
  var stopAt = when + 0.22;
  var gain = audioCtx.createGain();
  gain.connect(dest);
  gain.gain.setValueAtTime(0.0001, when);
  gain.gain.linearRampToValueAtTime(0.7, when + 0.005);
  gain.gain.exponentialRampToValueAtTime(0.0001, when + 0.18);
  var body = oscillator('sine', 230, when, stopAt, nodes);
  body.frequency.exponentialRampToValueAtTime(110, when + 0.12);
  body.connect(gain);
  return stopAt;
}

// —— 传输条 / 轨道混音 / 界面 ——
function updateUi() {
  var clockEl = document.getElementById('music-clock');
  if (clockEl) {
    clockEl.textContent = formatTime(displayPosition()) + ' / ' + formatTime(TOTAL_SEC);
  }
  var seekEl = document.getElementById('music-seek');
  if (seekEl && document.activeElement !== seekEl && TOTAL_SEC > 0) {
    var percent = Math.round(clampNumber(displayPosition() / TOTAL_SEC, 0, 1) * 1000);
    seekEl.value = String(percent);
  }
}

function formatTime(sec) {
  var total = Math.max(0, Math.round(Number(sec) || 0));
  var minutes = Math.floor(total / 60);
  var seconds = total % 60;
  return minutes + ':' + (seconds < 10 ? '0' : '') + seconds;
}

function updateHeader() {
  var titleEl = document.getElementById('music-title');
  var title = (SCORE && SCORE.title) ? String(SCORE.title) : '';
  if (titleEl) titleEl.textContent = title || '未命名乐谱';
  document.title = title || '音乐播放';
  var metaEl = document.getElementById('music-meta');
  if (metaEl) {
    var tracks = (SCORE && SCORE.tracks) ? SCORE.tracks.length : 0;
    var tempo = Number(SCORE && SCORE.tempo) || 120;
    var sig = (SCORE && SCORE.timeSig && SCORE.timeSig.length === 2)
      ? SCORE.timeSig[0] + '/' + SCORE.timeSig[1]
      : '4/4';
    metaEl.textContent = tracks + ' 轨 · ' + sig + ' · ' + tempo + ' BPM · ' + formatTime(TOTAL_SEC);
  }
}

function buildTrackUi() {
  var host = document.getElementById('music-tracks');
  if (!host) return;
  var tracks = (SCORE && SCORE.tracks) ? SCORE.tracks : [];
  for (var i = 0; i < tracks.length; i++) {
    var track = tracks[i] || {};
    var id = String(track.id || '');
    var row = document.createElement('div');
    var label = document.createElement('span');
    label.textContent = String(track.name || id || ('轨道 ' + (i + 1)));
    var muteButton = document.createElement('button');
    muteButton.type = 'button';
    muteButton.textContent = trackMuted[id] ? '取消静音' : '静音';
    (function (trackId, button) {
      button.addEventListener('click', function () {
        setTrackMuted(trackId, !trackMuted[trackId]);
        button.textContent = trackMuted[trackId] ? '取消静音' : '静音';
      });
    })(id, muteButton);
    trackMuteButtons[id] = muteButton;
    var slider = document.createElement('input');
    slider.type = 'range';
    slider.min = '0';
    slider.max = '100';
    slider.step = '1';
    var initial = Math.round(trackMixValue(id) * 100);
    slider.value = String(initial);
    (function (trackId, range) {
      range.addEventListener('input', function () {
        setTrackVolume(trackId, Number(range.value) / 100.0);
      });
    })(id, slider);
    trackSliders[id] = slider;
    row.appendChild(label);
    row.appendChild(muteButton);
    row.appendChild(slider);
    host.appendChild(row);
  }
}

function setTrackVolume(trackId, value) {
  if (!trackId) return;
  var volume = clampNumber(value, 0, 1);
  trackVolumes[trackId] = volume;
  var slider = trackSliders[trackId];
  if (slider) slider.value = String(Math.round(volume * 100));
  applyTrackGain(trackId);
}

function setTrackMuted(trackId, muted) {
  if (!trackId) return;
  trackMuted[trackId] = !!muted;
  var button = trackMuteButtons[trackId];
  if (button) button.textContent = trackMuted[trackId] ? '取消静音' : '静音';
  applyTrackGain(trackId);
}

function applyTrackGain(trackId) {
  if (!audioCtx || !trackGains[trackId]) return;
  try {
    trackGains[trackId].gain.setValueAtTime(trackMixValue(trackId), audioCtx.currentTime);
  } catch (err) {}
}

function bindTransport() {
  var playButton = document.getElementById('music-play');
  if (playButton) playButton.addEventListener('click', function () { play(); });
  var pauseButton = document.getElementById('music-pause');
  if (pauseButton) pauseButton.addEventListener('click', function () { pause(); });
  var stopButton = document.getElementById('music-stop');
  if (stopButton) stopButton.addEventListener('click', function () { stopPlayback(); });
  var seekInput = document.getElementById('music-seek');
  if (seekInput) {
    seekInput.addEventListener('input', function () {
      seek(Number(seekInput.value) / 1000.0 * TOTAL_SEC);
    });
  }
  document.addEventListener('visibilitychange', function () {
    if (state === 'playing') schedulerTick();
  });
}

// 固定 CSP 未放开样式源：内联样式块与 style 属性都会落回 default-src 'none'
// 被拦截；CSSOM 属性赋值不受 CSP 管辖，是严格 CSP 下仍让页面可读的合规路径。
function applyStyle(element, props) {
  if (!element || !element.style || typeof element.style.setProperty !== 'function') return;
  for (var key in props) {
    if (Object.prototype.hasOwnProperty.call(props, key)) {
      try {
        element.style.setProperty(key, props[key]);
      } catch (err) {}
    }
  }
}

function styleById(elementId, props) {
  applyStyle(document.getElementById(elementId), props);
}

function applyStyles() {
  applyStyle(document.body, {
    margin: '0',
    padding: '24px',
    background: '#101317',
    color: '#e8eaf0',
    'font-family': '-apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif',
    'font-size': '14px'
  });
  styleById('music-player', { 'max-width': '760px', margin: '0 auto' });
  styleById('music-title', {
    'font-size': '22px',
    'font-weight': '600',
    margin: '0 0 4px',
    color: '#f5f7fb'
  });
  styleById('music-meta', { margin: '0 0 18px', color: '#9aa4b5', 'font-size': '13px' });
  styleById('music-transport', {
    display: 'flex',
    gap: '8px',
    'align-items': 'center',
    'margin-bottom': '10px'
  });
  styleById('music-seek', { width: '100%', margin: '6px 0' });
  styleById('music-clock', {
    'font-variant-numeric': 'tabular-nums',
    color: '#9aa4b5',
    margin: '4px 0 18px'
  });
  styleById('music-tracks', {
    display: 'flex',
    'flex-direction': 'column',
    gap: '6px'
  });
  styleById('music-status', { color: '#9aa4b5', 'font-size': '12px' });
  var buttonIds = ['music-play', 'music-pause', 'music-stop'];
  for (var i = 0; i < buttonIds.length; i++) {
    styleById(buttonIds[i], {
      padding: '8px 14px',
      'border-radius': '8px',
      border: '1px solid #34445c',
      background: '#1b2432',
      color: '#e8eaf0',
      'font-size': '14px',
      cursor: 'pointer'
    });
  }
}

function boot() {
  try {
    try { applyStyles(); } catch (err) {}
    updateHeader();
    buildTrackUi();
    bindTransport();
    updateUi();
  } catch (err) {
    reportError('播放器初始化失败：' + (err && err.message ? err.message : String(err)));
  }
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', boot);
} else {
  boot();
}

// 宿主可经 WebView 的 runJavaScript 调 window.NONMUSIC_PLAYER 驱动运输条；
// 出站消息仍只走 window.NONMUSIC 的 beat / ended / error 三类。
try {
  window.NONMUSIC_PLAYER = {
    play: play,
    pause: pause,
    stop: stopPlayback,
    seek: seek,
    setTrackVolume: setTrackVolume,
    setTrackMuted: setTrackMuted,
    state: function () { return state; },
    position: function () { return displayPosition(); }
  };
} catch (err) {}
})();
</script>
</body>
</html>
''';
