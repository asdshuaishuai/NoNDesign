/* 动画短片引擎 · 时间轴 / 缓动 / 桥（每支短片共用）
 *
 * 契约（短片只依赖这些）：
 *   ND.scene({ duration, render })   注册一支短片；render(t) 必须是纯函数：
 *                                    同一个 t 永远画出同一帧（可暂停、可拖动、可循环）。
 *   ND.ease.*                        缓动曲线（outCubic / outQuint / outBack / spring ...）
 *   ND.phase(t, start, dur, ease?)   某个时间窗内的 0..1 进度
 *   ND.stagger(t, i, start, step, dur, ease?)  逐个错开的进度
 *   ND.clamp / ND.lerp / ND.mix / ND.map
 *
 * 播放控制：window.__ndClip.{play,pause,seek,restart,setLoop,state}
 *   Dart 侧通过 WebView 的 JS 通道调用；JS 侧把状态回传给 VideoClipBridge。
 * 预览：?t=3.2 只画该时刻的一帧（不自动播放）——用来逐帧审查画面。
 */
(function () {
  'use strict';

  var ND = (window.ND = window.ND || {});

  // ---------------------------------------------------------------- 数学

  function clamp(v, a, b) { return v < a ? a : v > b ? b : v; }
  function lerp(a, b, p) { return a + (b - a) * p; }
  function phase(t, start, dur) {
    var d = dur > 0.000001 ? dur : 0.000001;
    return clamp((t - start) / d, 0, 1);
  }
  function stagger(t, index, start, step, dur) {
    return phase(t, start + index * step, dur);
  }

  var ease = {
    linear: function (p) { return p; },
    inQuad: function (p) { return p * p; },
    outQuad: function (p) { return 1 - (1 - p) * (1 - p); },
    inOutQuad: function (p) { return p < 0.5 ? 2 * p * p : 1 - Math.pow(-2 * p + 2, 2) / 2; },
    inCubic: function (p) { return p * p * p; },
    outCubic: function (p) { return 1 - Math.pow(1 - p, 3); },
    inOutCubic: function (p) { return p < 0.5 ? 4 * p * p * p : 1 - Math.pow(-2 * p + 2, 3) / 2; },
    outQuart: function (p) { return 1 - Math.pow(1 - p, 4); },
    outQuint: function (p) { return 1 - Math.pow(1 - p, 5); },
    inOutQuint: function (p) { return p < 0.5 ? 16 * p * p * p * p * p : 1 - Math.pow(-2 * p + 2, 5) / 2; },
    outExpo: function (p) { return p >= 1 ? 1 : 1 - Math.pow(2, -10 * p); },
    inOutExpo: function (p) {
      if (p <= 0) return 0;
      if (p >= 1) return 1;
      return p < 0.5 ? Math.pow(2, 20 * p - 10) / 2 : (2 - Math.pow(2, -20 * p + 10)) / 2;
    },
    outBack: function (p) {
      var c1 = 1.70158, c3 = c1 + 1;
      return 1 + c3 * Math.pow(p - 1, 3) + c1 * Math.pow(p - 1, 2);
    },
    inBack: function (p) {
      var c1 = 1.70158, c3 = c1 + 1;
      return c3 * p * p * p - c1 * p * p;
    },
    outElastic: function (p) {
      if (p <= 0) return 0;
      if (p >= 1) return 1;
      var c4 = (2 * Math.PI) / 3;
      return Math.pow(2, -10 * p) * Math.sin((p * 10 - 0.75) * c4) + 1;
    },
    // 弹簧式落定：先过冲一点再回来（用于“放下去”的动作）
    spring: function (p) {
      if (p <= 0) return 0;
      if (p >= 1) return 1;
      return 1 - Math.pow(2, -8 * p) * Math.cos(p * 9.2);
    },
  };

  function fmt(n, digits) {
    if (!isFinite(n)) return '0';
    return n.toFixed(digits == null ? 2 : digits);
  }

  ND.ease = ease;
  ND.clamp = clamp;
  ND.lerp = lerp;
  ND.phase = phase;
  ND.stagger = stagger;
  ND.fmt = fmt;
  ND.size = { width: 1280, height: 720 };
  ND.mix = function (a, b, p) { return lerp(a, b, clamp(p, 0, 1)); };
  ND.set = function (el, styles) {
    if (!el) return;
    for (var key in styles) {
      if (!Object.prototype.hasOwnProperty.call(styles, key)) continue;
      el.style[key] = styles[key];
    }
  };
  ND.attr = function (el, name, value) {
    if (el) el.setAttribute(name, value);
  };
  ND.opacity = function (el, value) {
    if (el) el.style.opacity = String(clamp(value, 0, 1));
  };
  ND.translate = function (el, x, y, extra) {
    if (!el) return;
    el.style.transform = 'translate3d(' + x + 'px,' + y + 'px,0)' + (extra || '');
  };

  // ---------------------------------------------------------------- 播放器

  var viewport = document.getElementById('nd-viewport');
  var stage = document.getElementById('nd-stage');
  var params = new URLSearchParams(location.search);

  var state = {
    duration: 6,
    t: 0,
    playing: false,
    loop: true,
    render: null,
    raf: 0,
    lastTs: 0,
    ready: false,
  };

  function post(message) {
    try {
      if (window.VideoClipBridge && window.VideoClipBridge.postMessage) {
        window.VideoClipBridge.postMessage(JSON.stringify(message));
      }
    } catch (error) {
      /* 单独用浏览器预览时没有桥：忽略。 */
    }
  }

  function snapshot() {
    return {
      type: 'state',
      t: state.t,
      duration: state.duration,
      playing: state.playing,
      loop: state.loop,
    };
  }

  function layout() {
    if (!viewport || !stage) return;
    var k = Math.min(viewport.clientWidth / 1280, viewport.clientHeight / 720);
    if (!isFinite(k) || k <= 0) k = 1;
    stage.style.transform = 'translate(-50%,-50%) scale(' + k + ')';
  }

  function draw(t) {
    state.t = clamp(t, 0, state.duration);
    if (state.render) state.render(state.t);
    post(snapshot());
  }

  function tick(ts) {
    if (!state.playing) { state.raf = 0; return; }
    if (!state.lastTs) state.lastTs = ts;
    var dt = (ts - state.lastTs) / 1000;
    state.lastTs = ts;
    // 标签页被挂起时 dt 可能很大：钳住，避免一跳到底。
    if (dt > 0.25) dt = 0.25;
    var next = state.t + dt;
    if (next >= state.duration) {
      if (state.loop) {
        next = state.duration > 0 ? next % state.duration : 0;
      } else {
        next = state.duration;
        state.playing = false;
      }
    }
    draw(next);
    if (state.playing) state.raf = requestAnimationFrame(tick);
    else state.raf = 0;
  }

  function play() {
    if (state.playing || !state.ready) return;
    if (state.t >= state.duration - 0.0001) state.t = 0;
    state.playing = true;
    state.lastTs = 0;
    state.raf = requestAnimationFrame(tick);
    draw(state.t);
  }

  function pause() {
    state.playing = false;
    if (state.raf) cancelAnimationFrame(state.raf);
    state.raf = 0;
    draw(state.t);
  }

  function seek(t) {
    draw(t);
  }

  function restart() {
    state.t = 0;
    draw(0);
    play();
  }

  function setLoop(value) {
    state.loop = !!value;
    draw(state.t);
  }

  ND.scene = function (definition) {
    state.duration = Math.max(0.1, Number(definition && definition.duration) || 6);
    state.render = definition && definition.render;
    state.ready = true;
    layout();
    window.addEventListener('resize', layout);
    if (definition && definition.title) document.title = definition.title;
    draw(0);
    post({ type: 'ready', duration: state.duration });
    if (params.get('t') !== null) {
      // 逐帧审查：只画这一帧，不播放。
      pause();
      seek(parseFloat(params.get('t')) || 0);
    } else {
      play();
    }
  };

  window.__ndClip = {
    play: play,
    pause: pause,
    seek: seek,
    restart: restart,
    setLoop: setLoop,
    get state() {
      return { t: state.t, duration: state.duration, playing: state.playing, loop: state.loop };
    },
  };

  layout();
})();
