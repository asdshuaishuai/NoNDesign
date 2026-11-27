// pixelfx core（NoNDesign 裁剪子集）：只导出特效子集真的用到的符号。
//
// 上游：patch-gg/pixelfx v0.3.1（MIT）。裁剪内容见同目录 NOTICE-DIVERGENCE.md：
//   * 不导出/不随包 actor.js、act.js、rig.js、poses.js（人物与 rig 按用户裁决不引入）；
//   * core/fx.js 的 meta.actor 分支改为显性抛错（on-body 特效越界即失败）。
export * from "./math.js";
export * from "./color.js";
export * from "./particles.js";
export * from "./shapes.js";
export { Particles, Bits, Lights, Blazes, P, PF, B, GRAVITY, FIRE_RAMP, SMOKE_RAMP, sparkle, flare, band, crystal } from "./sim.js";
export { Painter } from "./painter.js";
export { FONTS, textWidth } from "./font.js";
export { createFrame, clearFrame, createFx, composite, painterFor, resolveOptions } from "./fx.js";
export { backdrop, BACKDROPS } from "./scene.js";
export { chain, shiftKeys, shiftHits } from "./chain.js";
