/*
 * MoonViz classic-wasm JS host (WebView + Node).
 *
 * The engine artifact is the **classic** build: WASM MVP, zero imports,
 * linear memory exported as `memory`. Strings cross the boundary through the
 * `in` / `arg` / `arg2` byte slots (4-byte LE chunks) and come back as
 * `[len@ptr-4][UTF-16LE@ptr]` — the same contract as the retired Dart
 * wasm_run host (`app/lib/core/engine/engine_worker.dart`).
 *
 * This file is deliberately dependency-free and DOM-free: the WebView engine
 * host evaluates it verbatim, and `scripts/engine_web_probe.mjs` runs the same
 * file under Node for contract tests. No `fetch`, no `window`, no Node APIs.
 *
 * Public surface (all arguments/results are JSON-friendly):
 *   __ndEngine.wasmChunk(b64)      append wasm bytes (call before boot)
 *   __ndEngine.boot()              instantiate asynchronously; poll status()
 *   __ndEngine.status()            { ok, status, error, ... }
 *   __ndEngine.info()              export/version facts once ready
 *   __ndEngine.render/validate/exportHtml(mbtB64)
 *   __ndEngine.apply(mbtB64, opB64, gate)
 *   __ndEngine.session(mbtB64, name, argB64)
 *   __ndEngine.generate/tap/constrain/event(...)
 *   __ndEngine.listing(fn) / version() / stats() / recycle()
 *
 * Text is passed as base64 UTF-8 so the JS source never has to escape a large
 * document; results are JSON strings (the Dart side jsonDecodes them).
 */
(function (global) {
  'use strict';

  var LEN_MASK = 0x0FFFFFFF;
  var SLOT_CHUNK = 4;
  var MEMORY_RECYCLE_BYTES = 176 * 1024 * 1024;

  var ABI_EXPORTS = [
    'version_info',
    'list_templates',
    'list_themes',
    'list_ops',
    'list_tokens',
    'list_components',
    'validate_mbt_in',
    'render_mbt_in',
    'apply_human_op_in',
    'apply_agent_op_in',
    'export_html_in',
    'in_reset',
    'in_push',
    'arg_reset',
    'arg_push',
    'arg2_reset',
    'arg2_push',
    'session_open_in',
    'session_close',
  ];

  var SESSION_EXPORTS = [
    'session_apply_agent',
    'session_apply_human',
    'session_auto_fix',
    'session_benchmark',
    'session_close',
    'session_component_compile_b64',
    'session_constrain',
    'session_count',
    'session_critique',
    'session_event',
    'session_export_svg',
    'session_extract_design_system',
    'session_flows',
    'session_generate',
    'session_generate_responsive',
    'session_generate_spec',
    'session_history',
    'session_infer_missing',
    'session_infer_page_type',
    'session_interactions',
    'session_library_snapshot',
    'session_lint',
    'session_list_artboards',
    'session_open',
    'session_open_project_json',
    'session_query_nodes',
    'session_save',
    'session_snapshot',
    'session_spec',
    'session_states',
    'session_tap',
  ];

  var SESSION_HANDLE_ONLY = [
    'session_flows',
    'session_benchmark',
    'session_list_artboards',
    'session_save',
    'session_library_snapshot',
    'session_snapshot',
  ];

  var SESSION_SPECIAL = [
    'session_generate',
    'session_event',
    'session_tap',
    'session_constrain',
  ];

  var SESSION_UNSUPPORTED = [
    'session_generate_spec',
    'session_count',
    'session_open',
  ];

  var SESSION_MUTATING = [
    'session_apply_agent',
    'session_apply_human',
    'session_auto_fix',
    'session_constrain',
    'session_tap',
    'session_generate_responsive',
    'session_component_compile_b64',
    'session_generate',
    'session_event',
    'session_history',
  ];

  var state = {
    status: 'idle',
    error: '',
    chunks: [],
    bytes: null,
    module: null,
    exports: null,
    memory: null,
    engineVersion: '',
    sessMbt: null,
    sessHandle: null,
    peakMemoryBytes: 0,
    instanceGeneration: 0,
    recycleCount: 0,
    trapCount: 0,
    sessionHits: 0,
    sessionMisses: 0,
    sessionCloses: 0,
    calls: 0,
  };

  function encodeUtf8(text) {
    if (typeof TextEncoder !== 'undefined') return new TextEncoder().encode(text);
    // Old WebKit fallback (Safari < 10.1) — the engine host still runs there.
    var out = [];
    for (var i = 0; i < text.length; i++) {
      var c = text.charCodeAt(i);
      if (c < 0x80) out.push(c);
      else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 0x3f));
      else if (c >= 0xd800 && c <= 0xdbff && i + 1 < text.length) {
        var d = text.charCodeAt(++i);
        var cp = 0x10000 + ((c - 0xd800) << 10) + (d - 0xdc00);
        out.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3f),
          0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f));
      } else out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f));
    }
    return new Uint8Array(out);
  }

  function decodeUtf8(bytes) {
    if (typeof TextDecoder !== 'undefined') return new TextDecoder('utf-8').decode(bytes);
    var s = '';
    for (var i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
    try {
      return decodeURIComponent(escape(s));
    } catch (_) {
      return s;
    }
  }

  function b64ToBytes(b64) {
    var bin = global.atob ? global.atob(b64) : Buffer.from(b64, 'base64').toString('binary');
    var out = new Uint8Array(bin.length);
    for (var i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  }

  function b64ToText(b64) {
    return b64 ? decodeUtf8(b64ToBytes(b64)) : '';
  }

  function fail(code, detail) {
    return { ok: false, error: code, detail: detail == null ? '' : String(detail) };
  }

  function callFailure(code, detail) {
    return { code: code, detail: detail == null ? '' : String(detail) };
  }

  function isCallFailure(e) {
    return e && typeof e === 'object' && typeof e.code === 'string';
  }

  function invoke(name, args) {
    var exports = state.exports;
    if (!exports || typeof exports[name] !== 'function') {
      throw callFailure('engine_unknown_function', name + ' is not an engine export');
    }
    state.calls++;
    try {
      var out = exports[name].apply(null, args || []);
      return typeof out === 'number' ? out : 0;
    } catch (e) {
      if (isCallFailure(e)) throw e;
      // A WebAssembly trap leaves the instance state untrusted: drop the
      // session and rebuild before any later call (same discipline as the
      // Dart host's `_invoke`).
      state.trapCount++;
      try {
        rebuild();
      } catch (_) {
        // The next call reports engine_unavailable if rebuild keeps failing.
      }
      throw callFailure('engine_trap', e && e.message ? e.message : e);
    }
  }

  function memoryBytes() {
    return state.memory ? state.memory.buffer.byteLength : 0;
  }

  function trackMemory() {
    var bytes = memoryBytes();
    if (bytes > state.peakMemoryBytes) state.peakMemoryBytes = bytes;
  }

  function readString(ptr) {
    var memory = state.memory;
    if (!memory) return '';
    var buffer = memory.buffer;
    if (ptr < 4 || ptr > buffer.byteLength) return '';
    var view = new DataView(buffer);
    var length = view.getUint32(ptr - 4, true) & LEN_MASK;
    var maxChars = Math.floor((buffer.byteLength - ptr) / 2);
    if (length > maxChars) length = maxChars;
    if (length <= 0) return '';
    if (typeof TextDecoder !== 'undefined') {
      return new TextDecoder('utf-16le').decode(new Uint8Array(buffer, ptr, length * 2));
    }
    var units = [];
    for (var i = 0; i < length; i++) units.push(view.getUint16(ptr + i * 2, true));
    var out = '';
    for (var j = 0; j < units.length; j += 8192) {
      out += String.fromCharCode.apply(null, units.slice(j, j + 8192));
    }
    return out;
  }

  function parse(ptr) {
    var text = readString(ptr);
    if (!text) return fail('engine_empty_result', 'engine returned an empty string');
    try {
      return JSON.parse(text);
    } catch (e) {
      return fail('engine_non_json', text.slice(0, 200));
    }
  }

  function slot(reset, push, text) {
    var raw = encodeUtf8(text == null ? '' : text);
    invoke(reset, []);
    for (var i = 0; i < raw.length; i += SLOT_CHUNK) {
      var end = Math.min(i + SLOT_CHUNK, raw.length);
      var le = 0;
      for (var b = i; b < end; b++) le |= raw[b] << (8 * (b - i));
      invoke(push, [le, end - i]);
    }
  }

  function slotIn(text) { slot('in_reset', 'in_push', text); }
  function slotArg(text) { slot('arg_reset', 'arg_push', text); }
  function slotArg2(text) { slot('arg2_reset', 'arg2_push', text); }

  function rebuild() {
    if (!state.module) throw callFailure('engine_unavailable', 'engine module is not loaded');
    try {
      var instance = new WebAssembly.Instance(state.module, {});
      state.exports = instance.exports;
      state.memory = instance.exports.memory;
      if (!state.memory) throw new Error('engine does not export linear memory');
      state.instanceGeneration++;
      state.sessMbt = null;
      state.sessHandle = null;
      trackMemory();
    } catch (e) {
      state.exports = null;
      state.memory = null;
      state.sessMbt = null;
      state.sessHandle = null;
      throw callFailure('engine_unavailable', e && e.message ? e.message : e);
    }
  }

  function maybeRecycle() {
    if (!state.exports) {
      rebuild();
      return;
    }
    if (memoryBytes() > MEMORY_RECYCLE_BYTES) {
      state.recycleCount++;
      rebuild();
    }
  }

  function closeHandle(handle) {
    state.sessionCloses++;
    try {
      invoke('session_close', [handle]);
    } catch (_) {
      // A trapped instance already lost the handle.
    }
  }

  function closeSession() {
    var handle = state.sessHandle;
    state.sessHandle = null;
    state.sessMbt = null;
    if (handle !== null) closeHandle(handle);
  }

  function open(mbt) {
    maybeRecycle();
    if (state.sessHandle !== null && state.sessMbt === mbt) {
      state.sessionHits++;
      return state.sessHandle;
    }
    state.sessionMisses++;
    closeSession();
    slotIn(mbt);
    var handle = invoke('session_open_in', []);
    if (handle < 0) throw callFailure('engine_session_open_failed', 'handle=' + handle);
    state.sessMbt = mbt;
    state.sessHandle = handle;
    return handle;
  }

  function remember(out) {
    if (out && out.ok === true && typeof out.mbt === 'string') state.sessMbt = out.mbt;
    return out;
  }

  function docCall(fn, mbt) {
    try {
      maybeRecycle();
      slotIn(mbt);
      return parse(invoke(fn, []));
    } catch (e) {
      return fail(isCallFailure(e) ? e.code : 'engine_trap', isCallFailure(e) ? e.detail : e);
    }
  }

  function apply(mbt, op, gate) {
    try {
      maybeRecycle();
      slotIn(mbt);
      slotArg(op);
      return parse(invoke(gate === 'agent' ? 'apply_agent_op_in' : 'apply_human_op_in', []));
    } catch (e) {
      return fail(isCallFailure(e) ? e.code : 'engine_trap', isCallFailure(e) ? e.detail : e);
    }
  }

  function listing(fn) {
    try {
      maybeRecycle();
      return parse(invoke(fn, []));
    } catch (e) {
      return fail(isCallFailure(e) ? e.code : 'engine_trap', isCallFailure(e) ? e.detail : e);
    }
  }

  function tagged(prefix, body) {
    try {
      return body();
    } catch (e) {
      return {
        ok: false,
        error: prefix,
        cause: isCallFailure(e) ? e.code : 'engine_trap',
        detail: isCallFailure(e) ? e.detail : String(e),
      };
    }
  }

  function session(mbt, name, arg) {
    maybeRecycle();
    if (SESSION_EXPORTS.indexOf(name) < 0 || typeof state.exports[name] !== 'function') {
      return fail('engine_unknown_function', name + ' is not a session export');
    }
    if (SESSION_UNSUPPORTED.indexOf(name) >= 0) {
      return fail('engine_unsupported_signature', name + ' needs a signature this host cannot build');
    }
    if (name === 'session_close') {
      closeSession();
      return { ok: true, closed: true };
    }
    if (SESSION_SPECIAL.indexOf(name) >= 0) {
      if (name === 'session_constrain') return constrain(mbt, arg || '', '');
      return fail('engine_unsupported_signature',
        name + ' needs its typed call: the generic session face cannot build its slot layout');
    }
    if (name === 'session_open_project_json') {
      var payload = arg || '';
      try {
        if (state.sessHandle !== null && state.sessMbt === payload) {
          state.sessionHits++;
          return { ok: true, handle: state.sessHandle };
        }
        state.sessionMisses++;
        closeSession();
        slotIn(payload);
        var projectHandle = invoke('session_open_project_json_in', []);
        if (projectHandle < 0) {
          throw callFailure('engine_session_open_failed', 'handle=' + projectHandle);
        }
        state.sessMbt = payload;
        state.sessHandle = projectHandle;
        return { ok: true, handle: projectHandle };
      } catch (e) {
        return {
          ok: false,
          error: 'engine_session_failed',
          cause: isCallFailure(e) ? e.code : 'engine_trap',
          detail: isCallFailure(e) ? e.detail : String(e),
        };
      }
    }
    try {
      var handle = open(mbt);
      var out;
      if (SESSION_HANDLE_ONLY.indexOf(name) >= 0) {
        out = parse(invoke(name, [handle]));
      } else {
        slotArg(arg || '');
        var inName = name + '_in';
        out = parse(invoke(typeof state.exports[inName] === 'function' ? inName : name, [handle]));
      }
      if (SESSION_MUTATING.indexOf(name) >= 0) remember(out);
      return out;
    } catch (e) {
      var stale = state.sessHandle;
      state.sessHandle = null;
      state.sessMbt = null;
      if (stale !== null) closeHandle(stale);
      return {
        ok: false,
        error: 'engine_session_failed',
        cause: isCallFailure(e) ? e.code : 'engine_trap',
        detail: isCallFailure(e) ? e.detail : String(e),
      };
    }
  }

  function generate(mbt, intent, name, specText) {
    return tagged('engine_generate_failed', function () {
      maybeRecycle();
      var handle = open(mbt);
      slotIn(specText || '{}');
      slotArg(intent || '');
      slotArg2(name || '');
      return remember(parse(invoke('session_generate_in', [handle])));
    });
  }

  function tap(mbt, artboard, x, y) {
    return tagged('engine_tap_failed', function () {
      maybeRecycle();
      var handle = open(mbt);
      slotArg(artboard || '');
      return remember(parse(invoke('session_tap_in', [handle, x, y])));
    });
  }

  function constrain(mbt, artboard, intent) {
    return tagged('engine_constrain_failed', function () {
      maybeRecycle();
      var handle = open(mbt);
      slotArg(artboard || '');
      slotArg2(intent || '');
      return remember(parse(invoke('session_constrain_in', [handle])));
    });
  }

  function event(mbt, artboard, spec) {
    return tagged('engine_event_failed', function () {
      maybeRecycle();
      var handle = open(mbt);
      slotArg(artboard || '');
      slotIn(spec || '');
      return remember(parse(invoke('session_event_in', [handle])));
    });
  }

  function exportNames() {
    if (!state.exports) return [];
    return Object.keys(state.exports).sort();
  }

  function stats() {
    return {
      memoryBytes: memoryBytes(),
      peakMemoryBytes: state.peakMemoryBytes,
      instanceGeneration: state.instanceGeneration,
      recycleCount: state.recycleCount,
      trapCount: state.trapCount,
      sessionHits: state.sessionHits,
      sessionMisses: state.sessionMisses,
      sessionCloses: state.sessionCloses,
      calls: state.calls,
      lastFuelDelta: 0,
      fuelRemaining: 0,
    };
  }

  var api = {
    wasmChunk: function (b64) {
      try {
        state.chunks.push(b64ToBytes(b64));
        return 'ok';
      } catch (e) {
        state.status = 'error';
        state.error = 'wasm chunk decode failed: ' + e;
        return state.error;
      }
    },

    boot: function () {
      if (state.status === 'booting' || state.status === 'ready') return state.status;
      state.status = 'booting';
      state.error = '';
      try {
        var total = 0;
        for (var i = 0; i < state.chunks.length; i++) total += state.chunks[i].length;
        var bytes = new Uint8Array(total);
        var offset = 0;
        for (var j = 0; j < state.chunks.length; j++) {
          bytes.set(state.chunks[j], offset);
          offset += state.chunks[j].length;
        }
        state.bytes = bytes;
        state.chunks = [];
        WebAssembly.instantiate(bytes, {})
          .then(function (result) {
            var module = result.module || result;
            var instance = result.instance || result;
            state.module = module;
            state.exports = instance.exports;
            state.memory = instance.exports.memory;
            if (!state.memory) throw new Error('engine does not export linear memory');
            var missing = ABI_EXPORTS.filter(function (name) {
              return typeof instance.exports[name] !== 'function';
            });
            if (missing.length) {
              throw new Error('artifact is missing ABI exports: ' + missing.join(','));
            }
            state.instanceGeneration++;
            trackMemory();
            var version = parse(invoke('version_info', []));
            state.engineVersion = version && (version.version || version.data) || 'unknown';
            state.status = 'ready';
          })
          .catch(function (e) {
            state.status = 'error';
            state.error = e && e.message ? e.message : String(e);
          });
      } catch (e) {
        state.status = 'error';
        state.error = e && e.message ? e.message : String(e);
      }
      return state.status;
    },

    status: function () {
      return JSON.stringify({
        ok: state.status === 'ready',
        status: state.status,
        error: state.error,
        engineVersion: state.engineVersion,
        exportCount: exportNames().length,
        sessionExportCount: exportNames().filter(function (n) {
          return n.indexOf('session_') === 0;
        }).length,
        memoryBytes: memoryBytes(),
      });
    },

    info: function () {
      return JSON.stringify({
        ok: state.status === 'ready',
        status: state.status,
        error: state.error,
        engineVersion: state.engineVersion,
        exports: exportNames(),
        sessionExports: exportNames().filter(function (n) {
          return n.indexOf('session_') === 0;
        }),
        memoryBytes: memoryBytes(),
      });
    },

    version: function () {
      try {
        maybeRecycle();
        return json(parse(invoke('version_info', [])));
      } catch (e) {
        return json(fail(isCallFailure(e) ? e.code : 'engine_trap', e));
      }
    },
    render: function (mbt) { return json(docCall('render_mbt_in', b64ToText(mbt))); },
    validate: function (mbt) { return json(docCall('validate_mbt_in', b64ToText(mbt))); },
    exportHtml: function (mbt) { return json(docCall('export_html_in', b64ToText(mbt))); },
    apply: function (mbt, op, gate) { return json(apply(b64ToText(mbt), b64ToText(op), gate)); },
    listing: function (fn) { return json(listing(fn)); },
    session: function (mbt, name, arg) {
      try {
        return json(session(b64ToText(mbt), b64ToText(name), b64ToText(arg)));
      } catch (e) {
        return json(fail(isCallFailure(e) ? e.code : 'engine_trap', e));
      }
    },
    generate: function (mbt, intent, name, spec) {
      return json(generate(b64ToText(mbt), b64ToText(intent), b64ToText(name), b64ToText(spec)));
    },
    tap: function (mbt, artboard, x, y) {
      return json(tap(b64ToText(mbt), b64ToText(artboard), Number(x), Number(y)));
    },
    constrain: function (mbt, artboard, intent) {
      return json(constrain(b64ToText(mbt), b64ToText(artboard), b64ToText(intent)));
    },
    event: function (mbt, artboard, spec) {
      return json(event(b64ToText(mbt), b64ToText(artboard), b64ToText(spec)));
    },
    stats: function () { return JSON.stringify(stats()); },
    recycle: function () {
      try {
        maybeRecycle();
        state.recycleCount++;
        rebuild();
        return JSON.stringify(stats());
      } catch (e) {
        return JSON.stringify(fail('engine_unavailable', e));
      }
    },
    rawCall: function (fn, argsJson) {
      try {
        maybeRecycle();
        return JSON.stringify({ ok: true, value: invoke(fn, JSON.parse(argsJson || '[]')) });
      } catch (e) {
        return JSON.stringify(fail(isCallFailure(e) ? e.code : 'engine_trap', e));
      }
    },
    _resetForTests: function () {
      state.status = 'idle';
      state.error = '';
      state.chunks = [];
      state.bytes = null;
      state.module = null;
      state.exports = null;
      state.memory = null;
      state.engineVersion = '';
      state.sessMbt = null;
      state.sessHandle = null;
      state.peakMemoryBytes = 0;
      state.instanceGeneration = 0;
      state.recycleCount = 0;
      state.trapCount = 0;
      state.sessionHits = 0;
      state.sessionMisses = 0;
      state.sessionCloses = 0;
      state.calls = 0;
    },
  };

  function json(value) {
    try {
      return JSON.stringify(value);
    } catch (e) {
      return JSON.stringify(fail('engine_non_json', e));
    }
  }

  global.__ndEngine = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
