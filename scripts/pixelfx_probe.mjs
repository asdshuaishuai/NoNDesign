#!/usr/bin/env node
// pixelfx 特效子集的确定性探针（开发期工具，不参与运行时）。
//
// 用途：证明「入库的 11 个特效」在没有人物/rig 代码的情况下，依然能：
//   1) 被 import 起来（依赖面完整）；
//   2) 按固定 30fps 步进渲染出非空像素；
//   3) **同种子同帧字节确定**（两次运行哈希相同）；
//   4) 不同种子产出不同画面（避免"全都是同一张黑图"的假绿）。
//
// 运行：node scripts/pixelfx_probe.mjs
import { pathToFileURL } from 'node:url';
import { resolve } from 'node:path';

const root = resolve('app/assets/pixelfx');
const core = await import(pathToFileURL(resolve(root, 'core/index.js')).href);
const { EFFECTS, EFFECT_IDS } = await import(
  pathToFileURL(resolve(root, 'fx/index.js')).href
);

const W = 128, H = 128, FPS = 30;

function fnv1a(bytes) {
  let hash = 0x811c9dc5;
  for (let i = 0; i < bytes.length; i++) {
    hash ^= bytes[i];
    hash = (hash * 0x01000193) >>> 0;
  }
  return hash.toString(16).padStart(8, '0');
}

function render(id, seed, steps) {
  const mod = EFFECTS[id];
  if (!mod) throw new Error(`missing effect ${id}`);
  const frame = core.createFrame(W, H);
  const fx = core.createFx(mod, { x: Math.floor(W / 2), y: H - 6, seed });
  const out = new Uint8ClampedArray(W * H * 4);
  for (let i = 0; i < steps; i++) {
    core.clearFrame(frame);
    fx.update(1 / FPS);
    fx.draw(frame);
  }
  // 最后一帧合成 RGB（不透明黑背景），算哈希与非空像素数。
  core.composite(frame, out, 0x000000, 1);
  let nonEmpty = 0;
  for (let i = 0; i < out.length; i += 4) {
    if (out[i] | out[i + 1] | out[i + 2]) nonEmpty++;
  }
  return { hash: fnv1a(out), nonEmpty };
}

const failures = [];
const rows = [];
for (const id of EFFECT_IDS) {
  const steps = 18;
  const a = render(id, 7, steps);
  const b = render(id, 7, steps);
  const c = render(id, 11, steps);
  const okDeterministic = a.hash === b.hash;
  const okNonEmpty = a.nonEmpty > 0;
  const okSeedSensitive = a.hash !== c.hash;
  if (!okDeterministic) failures.push(`${id}: 同种子两次渲染不一致`);
  if (!okNonEmpty) failures.push(`${id}: 渲染结果为空（假绿）`);
  if (!okSeedSensitive) failures.push(`${id}: 换个种子画面没变（种子没生效）`);
  rows.push(
    `${id}  hash=${a.hash}  px=${a.nonEmpty}  seed11=${c.hash}  ` +
      `${okDeterministic && okNonEmpty && okSeedSensitive ? 'OK' : 'FAIL'}`,
  );
}

console.log(`effects: ${EFFECT_IDS.length}`);
for (const row of rows) console.log(`  ${row}`);
if (failures.length) {
  console.error(`FAIL: ${failures.join('; ')}`);
  process.exit(1);
}
console.log('pixelfx subset: deterministic OK');
