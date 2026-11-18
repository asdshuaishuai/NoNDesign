#!/usr/bin/env node
// Build the offline A2UI web renderer page for the NoNDesign WebView spike.
//
// What this script produces (committed, deterministic):
//   app/assets/a2ui_web/index.html              self-contained page (inline CSP + inline bundle)
//   app/assets/a2ui_web/a2ui_web.js             the same bundle as a standalone file (audit copy)
//   app/assets/a2ui_web/fixture_surface.json    the v1.0 fixture surface rendered on load
//   app/assets/a2ui_web/build-manifest.json     pinned versions + sha256 of the emitted files
//
// Reproducibility rules:
//   * every @a2ui / build dependency is pinned exactly in package.json and verified against
//     the installed node_modules before bundling (version drift fails the build);
//   * no timestamp / host path is written into any artifact (byte-stable rebuilds);
//   * `npm run build` also runs `--probe`, which evaluates the *emitted* bundle in a
//     headless DOM (happy-dom) and asserts that the official renderer paints the fixture
//     and that a button action reaches the host bridge.
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import * as esbuild from 'esbuild';

const root = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(root, '..', '..');
const outDir = join(repoRoot, 'app', 'assets', 'a2ui_web');
const args = new Set(process.argv.slice(2));
const runProbe = !args.has('--no-probe');

const pkg = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'));
const PINNED = {
  '@a2ui/web_core': pkg.dependencies['@a2ui/web_core'],
  '@a2ui/lit': pkg.dependencies['@a2ui/lit'],
  esbuild: pkg.devDependencies.esbuild,
};

function installedVersion(name) {
  const manifest = JSON.parse(
    readFileSync(join(root, 'node_modules', name, 'package.json'), 'utf8'),
  );
  return manifest.version;
}

for (const [name, want] of Object.entries(PINNED)) {
  const got = installedVersion(name);
  if (got !== want) {
    throw new Error(
      `dependency drift: ${name} pinned ${want}, node_modules has ${got}. ` +
        'Run `npm ci` (the lockfile is the source of truth).',
    );
  }
}

// ---------------------------------------------------------------------------
// Fixture: a minimal A2UI v1.0 surface. It intentionally exercises the pieces
// the spike must prove: layout (Card/Column), text, a two-way input bound to
// the data model, and a Button whose action carries the resolved input back to
// the host. v1.0 binds dynamic values with the reserved "@path" key (the v0.9
// form is "path"); the official web renderer resolves only "@path" at v1.0.
// ---------------------------------------------------------------------------
const BASIC_CATALOG_V1 =
  'https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json';
const FIXTURE = [
  {
    version: '1.0',
    createSurface: {
      surfaceId: 'spike',
      catalogId: BASIC_CATALOG_V1,
    },
  },
  {
    version: '1.0',
    updateComponents: {
      surfaceId: 'spike',
      components: [
        { id: 'root', component: 'Card', child: 'col' },
        { id: 'col', component: 'Column', children: ['title', 'hint', 'choice', 'confirm'] },
        { id: 'title', component: 'Text', text: '离线预览表单', variant: 'body' },
        {
          id: 'hint',
          component: 'Text',
          text: '这是由官方 Web 渲染器绘制的表面；选择后点确认，动作会回流到宿主。',
          variant: 'caption',
        },
        {
          id: 'choice',
          component: 'ChoicePicker',
          label: '选择一个方案',
          options: [
            { value: 'a', label: '方案 A · 稳妥' },
            { value: 'b', label: '方案 B · 激进' },
          ],
          value: { '@path': '/choice' },
        },
        {
          id: 'confirm',
          component: 'Button',
          variant: 'primary',
          child: 'confirmLabel',
          action: {
            event: {
              name: 'spike_confirm',
              context: {
                choice: { '@path': '/choice' },
                source: 'offline_preview',
              },
            },
          },
        },
        { id: 'confirmLabel', component: 'Text', text: '确认' },
      ],
    },
  },
  {
    version: '1.0',
    updateDataModel: {
      surfaceId: 'spike',
      path: '/',
      value: { choice: 'a' },
    },
  },
];

// ---------------------------------------------------------------------------
// Page runtime. Bundled by esbuild from stdin; kept dependency-free of DOM
// globals at module scope so the same file works in a WebView and in the probe.
// ---------------------------------------------------------------------------
const runtimeSource = `
import { MessageProcessor, RELAXED_VALIDATION } from '@a2ui/web_core/v1_0';
import { basicCatalog as basicCatalogV1 } from '@a2ui/web_core/v1_0';
import { A2uiSurface } from '@a2ui/lit/v0_9';
import { basicCatalog as basicCatalogV09 } from '@a2ui/lit/v0_9';

var BRIDGE_VERSION = 1;
var CHANNEL = 'A2uiBridge';
var FIXTURE = ${JSON.stringify(FIXTURE)};
var VERSIONS = ${JSON.stringify({ core: PINNED['@a2ui/web_core'], lit: PINNED['@a2ui/lit'], bridge: 1 })};

var host = document.getElementById('surface-host');
var boot = document.getElementById('boot');
var surfaces = new Map();
var renderCount = 0;
var renderTimers = new Map();

function post(payload) {
  var text;
  try {
    text = JSON.stringify(payload);
  } catch (error) {
    return;
  }
  var bridge = window[CHANNEL];
  if (bridge && typeof bridge.postMessage === 'function') {
    try {
      bridge.postMessage(text);
      return;
    } catch (error) {
      // fall through to the console diagnostic below
    }
  }
  if (window.console && window.console.debug) {
    window.console.debug('[offline-preview] ' + text);
  }
}

function describeError(error) {
  if (!error) return 'unknown';
  if (typeof error === 'string') return error;
  return String(error.message || error.code || error);
}

function scheduleRendered(surfaceId) {
  if (renderTimers.has(surfaceId)) clearTimeout(renderTimers.get(surfaceId));
  var timer = setTimeout(function () {
    renderTimers.delete(surfaceId);
    var element = surfaces.get(surfaceId);
    if (!element) return;
    var text = (element.textContent || '').replace(/\\s+/g, ' ').trim();
    post({
      type: 'rendered',
      surfaceId: surfaceId,
      textLength: text.length,
      text: text.slice(0, 400),
    });
  }, 30);
  renderTimers.set(surfaceId, timer);
}

function createProcessor() {
  var processor = new MessageProcessor(
    [basicCatalogV1, basicCatalogV09],
    function (action) {
      post({
        type: 'action',
        name: action.name,
        surfaceId: action.surfaceId,
        sourceComponentId: action.sourceComponentId,
        timestamp: action.timestamp,
        context: action.context || {},
        catalogId: action.catalogId || null,
        userMessage: action.userMessage || null,
      });
    },
    {
      version: '1.0',
      validationConfig: RELAXED_VALIDATION,
      reportErrorsOnly: true,
      errorHandler: function (error) {
        post({
          type: 'error',
          code: (error && error.code) || 'message_rejected',
          message: describeError(error),
        });
      },
    },
  );
  processor.model.onSurfaceCreated.subscribe(function (surface) {
    var element = surfaces.get(surface.id);
    if (!element) {
      element = document.createElement('a2ui-surface');
      element.setAttribute('data-surface-id', surface.id);
      surfaces.set(surface.id, element);
      host.appendChild(element);
    }
    element.surface = surface;
    scheduleRendered(surface.id);
  });
  processor.model.onSurfaceDeleted.subscribe(function (surfaceId) {
    var element = surfaces.get(surfaceId);
    if (element && element.parentNode) element.parentNode.removeChild(element);
    surfaces.delete(surfaceId);
    post({ type: 'surface_removed', surfaceId: surfaceId });
  });
  return processor;
}

var processor = createProcessor();

function render(payload, options) {
  if (options && options.reset) reset(false);
  var list;
  if (Array.isArray(payload)) list = payload;
  else if (payload && Array.isArray(payload.messages)) list = payload.messages;
  else list = [payload];
  try {
    processor.processMessages(list);
    renderCount += 1;
    post({
      type: 'render_accepted',
      count: list.length,
      surfaces: Array.from(surfaces.keys()),
    });
    return true;
  } catch (error) {
    post({ type: 'error', code: 'render_failed', message: describeError(error) });
    return false;
  }
}

function reset(notify) {
  try {
    processor.dispose();
  } catch (error) {
    // ignore: dispose is best-effort
  }
  surfaces.forEach(function (element) {
    if (element.parentNode) element.parentNode.removeChild(element);
  });
  surfaces.clear();
  processor = createProcessor();
  if (notify !== false) post({ type: 'reset' });
}

function setTheme(theme) {
  var dark = theme !== 'light';
  var html = document.documentElement;
  html.classList.toggle('a2ui-dark', dark);
  html.classList.toggle('a2ui-light', !dark);
  html.style.colorScheme = dark ? 'dark' : 'light';
}

window.A2uiWeb = {
  bridgeVersion: BRIDGE_VERSION,
  protocol: '1.0',
  versions: VERSIONS,
  render: render,
  reset: function () { reset(true); },
  setTheme: setTheme,
  fixture: function () { reset(false); return render(FIXTURE); },
  stats: function () {
    return {
      surfaces: Array.from(surfaces.keys()),
      renders: renderCount,
      protocol: '1.0',
      versions: VERSIONS,
    };
  },
};

window.addEventListener('error', function (event) {
  post({ type: 'error', code: 'page_error', message: describeError(event && event.message) });
});
window.addEventListener('unhandledrejection', function (event) {
  post({ type: 'error', code: 'page_error', message: describeError(event && event.reason) });
});

if (boot && boot.parentNode) boot.parentNode.removeChild(boot);
post({
  type: 'ready',
  bridgeVersion: BRIDGE_VERSION,
  protocol: '1.0',
  versions: VERSIONS,
  catalogs: [basicCatalogV1.id, basicCatalogV09.id],
});
setTheme('dark');
render(FIXTURE);
`;

const buildResult = await esbuild.build({
  stdin: {
    contents: runtimeSource,
    resolveDir: root,
    sourcefile: 'a2ui_web_page.js',
    loader: 'js',
  },
  bundle: true,
  minify: true,
  format: 'iife',
  platform: 'browser',
  target: ['es2020'],
  legalComments: 'none',
  charset: 'utf8',
  banner: {
    js:
      '/*! NoNDesign offline preview page. Built from the official A2UI web renderer ' +
      `(@a2ui/web_core ${PINNED['@a2ui/web_core']}, @a2ui/lit ${PINNED['@a2ui/lit']}), Apache-2.0. ` +
      'See third_party/a2ui_web/NOTICE. */',
  },
  outfile: 'a2ui_web.js',
  metafile: true,
  write: false,
  logLevel: 'warning',
});

const jsFile = buildResult.outputFiles.find((file) => file.path.endsWith('.js'));
if (!jsFile) throw new Error('esbuild produced no JavaScript output');
const bundle = jsFile.text;

// The runtime page must not reach the network. http(s) strings left in the bundle
// are identifier-only (published catalog ids, JSON Schema `$schema` names and
// documentation examples); anything with another host, or an actual network
// primitive, fails the build. CSP `default-src 'none'` / `connect-src 'none'` is
// the runtime backstop.
const IDENTIFIER_HOSTS = new Set([
  'a2ui.org',
  'json-schema.org',
  'example.invalid',
  'example.com',
  'www.w3.org',
]);
const urlMatches = bundle.match(/https?:\/\/[^\s"'`)\\]*/g) || [];
const unexpectedUrls = urlMatches.filter((url) => {
  try {
    return !IDENTIFIER_HOSTS.has(new URL(url).host);
  } catch {
    return true;
  }
});
if (unexpectedUrls.length > 0) {
  throw new Error(
    'bundle contains unexpected external URLs (offline page must not reference a CDN): ' +
      unexpectedUrls.slice(0, 5).join(', '),
  );
}
if (/\bimport\s*\(/.test(bundle)) {
  throw new Error('bundle contains a dynamic import(); the page must load as one classic script');
}
for (const primitive of ['fetch(', 'XMLHttpRequest', 'importScripts', 'sendBeacon', 'new WebSocket']) {
  if (bundle.includes(primitive)) {
    throw new Error(
      `bundle contains a network primitive (${primitive}); the offline page must not reach the network`,
    );
  }
}

const inlineScript = bundle.replace(/<\/script/gi, '<\\/script').replace(/<!--/g, '<\\u0021--');
const scriptHash = createHash('sha256').update(inlineScript, 'utf8').digest('base64');
const csp =
  "default-src 'none'; " +
  `script-src 'sha256-${scriptHash}'; ` +
  "style-src 'unsafe-inline'; " +
  'img-src data: blob:; font-src data:; media-src data: blob:; ' +
  "connect-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'";

const html = `<!doctype html>
<html lang="zh-CN" class="a2ui-dark">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta http-equiv="Content-Security-Policy" content="${csp}">
<title>离线预览</title>
<style>
  :root { color-scheme: dark; }
  html, body { margin: 0; padding: 0; background: transparent; }
  body {
    padding: 12px;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "PingFang SC", "Microsoft YaHei", sans-serif;
    color: #e8e8ea;
  }
  #boot {
    padding: 18px 4px;
    font-size: 13px;
    opacity: 0.7;
  }
  #surface-host { display: block; }
  a2ui-surface { display: block; }
</style>
</head>
<body>
<div id="boot">预览准备中…</div>
<div id="surface-host"></div>
<script>${inlineScript}</script>
</body>
</html>
`;

const fixtureJson = `${JSON.stringify(FIXTURE, null, 2)}\n`;
const sha256 = (text) => createHash('sha256').update(text, 'utf8').digest('hex');

// Which packages actually made it into the shipped bundle (esbuild metafile), so
// the NOTICE and the decision record can list them without guessing.
const bundledPackages = {};
for (const input of Object.keys(buildResult.metafile.inputs)) {
  const match = input.match(/(?:^|\/)node_modules\/((?:@[^/]+\/)?[^/]+)\//);
  if (!match) continue;
  const name = match[1];
  if (bundledPackages[name]) continue;
  try {
    bundledPackages[name] = installedVersion(name);
  } catch {
    bundledPackages[name] = 'unknown';
  }
}
const sortedBundledPackages = Object.fromEntries(
  Object.entries(bundledPackages).sort(([a], [b]) => a.localeCompare(b)),
);

const manifest = {
  name: 'nondesign-a2ui-web',
  protocol: '1.0',
  bridgeVersion: 1,
  packages: {
    '@a2ui/web_core': PINNED['@a2ui/web_core'],
    '@a2ui/lit': PINNED['@a2ui/lit'],
  },
  bundledPackages: sortedBundledPackages,
  toolchain: { esbuild: PINNED.esbuild },
  csp,
  files: {
    'index.html': { sha256: sha256(html), bytes: Buffer.byteLength(html) },
    'a2ui_web.js': { sha256: sha256(bundle), bytes: Buffer.byteLength(bundle) },
    'fixture_surface.json': { sha256: sha256(fixtureJson), bytes: Buffer.byteLength(fixtureJson) },
  },
};

mkdirSync(outDir, { recursive: true });
writeFileSync(join(outDir, 'index.html'), html);
writeFileSync(join(outDir, 'a2ui_web.js'), bundle);
writeFileSync(join(outDir, 'fixture_surface.json'), fixtureJson);
writeFileSync(join(outDir, 'build-manifest.json'), `${JSON.stringify(manifest, null, 2)}\n`);

console.log(
  `built ${join('app', 'assets', 'a2ui_web')} ` +
    `(html ${Buffer.byteLength(html)} B, js ${Buffer.byteLength(bundle)} B, script-sha256 ${scriptHash})`,
);

// ---------------------------------------------------------------------------
// Probe: evaluate the emitted bundle (not the sources) inside a headless DOM and
// assert the fixture paints and the button action reaches the bridge.
// ---------------------------------------------------------------------------
if (runProbe) {
  const { Window } = await import('happy-dom');
  const window = new Window({ url: 'https://offline-preview.invalid/' });
  const posted = [];
  window.A2uiBridge = {
    postMessage(message) {
      posted.push(JSON.parse(message));
    },
  };
  const errors = [];
  window.console.error = (...parts) => errors.push(parts.join(' '));

  const scriptMatch = html.match(/<script>([\s\S]*)<\/script>/);
  if (!scriptMatch) throw new Error('probe: emitted page has no inline script');
  // Recreate the document the WebView parses: take the emitted <body> markup and
  // drop only the inline script, which is evaluated explicitly below (happy-dom
  // does not execute scripts assigned through innerHTML).
  const bodyMatch = html.match(/<body>([\s\S]*)<\/body>/);
  if (!bodyMatch) throw new Error('probe: emitted page has no <body>');
  window.document.body.innerHTML = bodyMatch[1].replace(/<script>[\s\S]*<\/script>/, '');
  if (!window.document.getElementById('surface-host')) {
    throw new Error('probe: emitted body lost its #surface-host mount point');
  }
  window.eval(scriptMatch[1]);

  const settle = (ms = 120) => new Promise((done) => setTimeout(done, ms));
  await settle();

  const api = window.A2uiWeb;
  const fail = (message) => {
    throw new Error(`probe failed: ${message}\nposted=${JSON.stringify(posted).slice(0, 2000)}`);
  };
  if (!api) fail('window.A2uiWeb missing');
  if (!posted.some((event) => event.type === 'ready')) fail('no ready event');
  if (!posted.some((event) => event.type === 'rendered')) fail('fixture did not report rendered');
  if (!window.document.querySelector('a2ui-surface')) fail('no <a2ui-surface> element');
  if (!window.document.querySelector('a2ui-basic-button')) fail('no basic button rendered');
  const bodyText = (window.document.body.textContent || '').replace(/\s+/g, ' ');
  if (!bodyText.includes('离线预览表单')) fail('fixture title missing from DOM');

  const button = window.document.querySelector('a2ui-basic-button button');
  if (!button) fail('button not found');
  button.dispatchEvent(new window.Event('click', { bubbles: true, composed: true }));
  await settle();

  const action = posted.find((event) => event.type === 'action');
  if (!action) fail('button click produced no action event');
  if (action.name !== 'spike_confirm') fail(`unexpected action name ${action.name}`);
  if (action.context.choice !== 'a') {
    fail(`action context was not resolved from the data model: ${JSON.stringify(action.context)}`);
  }
  if (errors.length > 0) fail(`page console.error output: ${errors.join(' | ')}`);
  console.log(`probe ok: ${posted.length} bridge events, action=${JSON.stringify(action.context)}`);
}
