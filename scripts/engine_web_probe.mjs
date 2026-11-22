#!/usr/bin/env node
// Contract probe for the classic-wasm JS host used by the WebView engine.
//
// The same file (`app/assets/engine/engine_web_host.js`) is evaluated inside
// the offscreen WebView on every platform; this probe runs it under Node so
// the ABI contract can be checked in CI without a display server.
//
// Usage: node scripts/engine_web_probe.mjs [--wasm PATH]

import { createRequire } from 'node:module';
import { readFileSync, existsSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, '..');
const require = createRequire(import.meta.url);

const args = process.argv.slice(2);
const wasmIndex = args.indexOf('--wasm');
const wasmPath = wasmIndex >= 0
  ? resolve(args[wasmIndex + 1])
  : resolve(ROOT, 'app/assets/engine/moonviz.wasm');
if (!existsSync(wasmPath)) {
  console.error(`engine wasm not found: ${wasmPath}`);
  process.exit(2);
}

const host = require(resolve(ROOT, 'app/assets/engine/engine_web_host.js'));
const wasm = readFileSync(wasmPath);
const CHUNK = 256 * 1024;
for (let i = 0; i < wasm.length; i += CHUNK) {
  const part = wasm.subarray(i, Math.min(i + CHUNK, wasm.length));
  const result = host.wasmChunk(part.toString('base64'));
  if (result !== 'ok') throw new Error(result);
}

host.boot();
await waitFor(() => {
  const status = JSON.parse(host.status());
  if (status.status === 'error') throw new Error(`boot failed: ${status.error}`);
  return status.status === 'ready';
}, 30000);

const info = JSON.parse(host.info());
assert(info.ok === true, `info not ok: ${host.info()}`);
assert(info.exports.length >= 70, `export count ${info.exports.length} < 70`);
assert(info.sessionExports.length >= 50, `session export count ${info.sessionExports.length} < 50`);
assert(info.exports.includes('session_event_in'), 'session_event_in missing (0.2 face)');
assert(info.exports.includes('render_mbt_in'), 'render_mbt_in missing');

const seedDoc = [
  '---',
  'moonviz:',
  '  format: visual-document',
  '  revision: 1',
  '  entry: __seed',
  '---',
  '',
  '# __seed',
  '',
  '<!-- moonviz:artboard __seed -->',
  '```mbt',
  'fn visual___seed() -> @decl.Prototype {',
  '  let page = @decl.prototype(name="__seed", width=390.0, height=844.0)',
  '  page',
  '}',
  '```',
  '',
].join('\n');

const b64 = (text) => Buffer.from(text, 'utf8').toString('base64');
const parse = (text, label) => {
  const value = JSON.parse(text);
  assert(value && typeof value === 'object', `${label}: not an object`);
  return value;
};

const version = parse(host.version(), 'version');
assert(version.engine === 'moonviz', `unexpected engine: ${JSON.stringify(version)}`);

const rendered = parse(host.render(b64(seedDoc)), 'render');
assert(rendered.ok === true, `render failed: ${JSON.stringify(rendered)}`);
assert(Array.isArray(rendered.artboards) && rendered.artboards.length >= 1, 'render: no artboards');

const validated = parse(host.validate(b64(seedDoc)), 'validate');
assert(validated.ok === true, `validate failed: ${JSON.stringify(validated)}`);

const placed = parse(host.apply(
  b64(seedDoc),
  b64('place __seed button probe_btn - 30 110 140 44 text=下一页'),
  'human',
), 'apply');
assert(placed.ok === true, `apply failed: ${JSON.stringify(placed)}`);
assert(typeof placed.mbt === 'string' && placed.mbt.length > seedDoc.length, 'apply: no canonical mbt');

const mbt = placed.mbt;
const boards = parse(host.session(b64(mbt), b64('session_list_artboards'), ''), 'list_artboards');
assert(boards.ok === true, `list_artboards failed: ${JSON.stringify(boards)}`);

const nodes = parse(host.session(b64(mbt), b64('session_query_nodes'), b64('__seed')), 'query_nodes');
assert(nodes.ok === true, `query_nodes failed: ${JSON.stringify(nodes)}`);

const flows = parse(host.session(b64(mbt), b64('session_flows'), ''), 'flows');
assert(flows.ok === true, `flows failed: ${JSON.stringify(flows)}`);

const moved = parse(host.apply(b64(mbt), b64('move __seed probe_btn 4 0'), 'agent'), 'agent apply');
assert(moved.ok === true, `agent apply failed: ${JSON.stringify(moved)}`);

const event = parse(host.event(b64(moved.mbt), b64('__seed'), b64('key_enter')), 'event');
assert(event.ok === true, `event failed: ${JSON.stringify(event)}`);

const tapped = parse(host.tap(b64(moved.mbt), b64('__seed'), 40, 80), 'tap');
assert(tapped.ok === true, `tap failed: ${JSON.stringify(tapped)}`);

const constrained = parse(host.constrain(b64(moved.mbt), b64('__seed'), b64('居中')), 'constrain');
assert(constrained.ok === true, `constrain failed: ${JSON.stringify(constrained)}`);

const templates = JSON.parse(host.listing('list_templates'));
assert(Array.isArray(templates) && templates.length >= 10,
  `list_templates failed: ${host.listing('list_templates')}`);

const stats = JSON.parse(host.stats());
assert(stats.calls > 10, `calls counter too low: ${stats.calls}`);
assert(stats.sessionMisses >= 1, 'session cache was never opened');
assert(stats.sessionHits >= 1, 'session cache never hit');

console.log(JSON.stringify({
  ok: true,
  engine: version,
  exports: info.exports.length,
  sessionExports: info.sessionExports.length,
  artboards: rendered.artboards.length,
  calls: stats.calls,
  sessionHits: stats.sessionHits,
  sessionMisses: stats.sessionMisses,
  stats,
}, null, 2));

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

async function waitFor(predicate, timeoutMs) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    if (predicate()) return;
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 20));
  }
  throw new Error('timed out waiting for engine boot');
}
