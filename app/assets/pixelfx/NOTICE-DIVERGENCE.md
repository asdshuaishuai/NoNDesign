# pixelfx vendored 子集（NoNDesign 偏离说明）

上游：`patch-gg/pixelfx` **v0.3.1**，commit 见 `build-manifest.json` 的 `upstreamCommit`。
许可证：MIT（原文见 `LICENSE`，上游第三方声明见 `NOTICE.md`）。

## 为什么有偏离

用户裁决（2026-11-22）：视频 VFX **只引入特效子集**（火焰/冰霜/风/爆炸/闪电），
**不引入人物**——`actor.js` / `rig.js` / `poses.js` / `act.js` / `moves/` 与
`meta.actor` / `o.actor` / on-body 特效一律**不随包分发**。

## 入库范围

* `core/`：`math` / `color` / `painter` / `font` / `particles` / `shapes` / `sim`
  / `fx` / `chain` / `scene` + 裁剪后的 `index.js`（**不导出**人物与 rig 符号）；
* `fx/`：`fire`（campfire / fireball / flame-pillar）、`ice`（frost-breath /
  ice-shatter / ice-crystal）、`lightning`（lightning-strike / spark-arc）、
  `explosions`（small / big）、`nature`（earth-spike=风土特效）及其 `_lib.js`；
* **不在库**：`actor.js`、`act.js`、`rig.js`、`poses.js`、`fx/moves/**`、
  以及任何 `meta.actor` 为真的 on-body 特效（如 `ice/frost-nova`，已剔除）。

## 具体改动（逐条可审计）

1. `core/fx.js`：删除 `import { stockActor } from "./actor.js"`；
   `createFx` 里原本「`meta.actor` 就自动套 stockActor」的分支改为
   **显性抛错**（`pixelfx subset: actor effects are not vendored`）——
   越界拿到 on-body 特效必须失败，不静默降级。
2. `core/index.js`：重写为裁剪后的导出表（去 actor/act/rig/poses 导出）。
3. `fx/index.js`：新建，登记 11 个允许的特效 id（`EFFECT_IDS`），与
   `build-manifest.json` 的 `allowedEffectIds` 逐字一致。

## 验证

`node scripts/pixelfx_probe.mjs`：11 个特效逐个渲染 18 帧 @30fps，断言
**同种子两次哈希一致**、**非空像素 > 0**、**换种子画面不同**；全绿才算入库有效。
守卫测试 `app/test/creative_stack_guard_test.dart` 逐文件核对 sha256/字节，
并断言人物文件名与 `meta.actor` **零残留**。

## 下一步（未施工）

特效渲染接线（把 `{f,type:"vfx",cue}` 事件编译进视频时间线）**尚未施工**；
本目录目前只是「已引入、可渲染、可验证」的资产，不参与 v1 常规视频渲染。
