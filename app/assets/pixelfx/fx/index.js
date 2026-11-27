// pixelfx 特效子集目录（NoNDesign）：只登记入库的 12 个特效。
//
// 裁决边界（2026-11-22）：火焰/冰霜/风/爆炸/闪电允许；人物、rig、stock actor、
// moves 与 on-body 特效一律不引入。新增特效必须同时改这里 + Dart 侧 allowlist +
// 守卫测试（三者同源，避免「文件在库里但不可达」或「可调用但没入库」）。
import * as campfire from "./fire/campfire.js";
import * as fireball from "./fire/fireball.js";
import * as flamePillar from "./fire/flame-pillar.js";
import * as frostBreath from "./ice/frost-breath.js";
import * as iceShatter from "./ice/ice-shatter.js";
import * as iceCrystal from "./ice/ice-crystal.js";
import * as lightningStrike from "./lightning/lightning-strike.js";
import * as sparkArc from "./lightning/spark-arc.js";
import * as smallExplosion from "./explosions/small-explosion.js";
import * as bigExplosion from "./explosions/big-explosion.js";
import * as earthSpike from "./nature/earth-spike.js";

export const EFFECTS = {
  "fire.campfire": campfire,
  "fire.fireball": fireball,
  "fire.flame-pillar": flamePillar,
  "ice.frost-breath": frostBreath,
  "ice.ice-shatter": iceShatter,
  "ice.ice-crystal": iceCrystal,
  "lightning.lightning-strike": lightningStrike,
  "lightning.spark-arc": sparkArc,
  "explosions.small-explosion": smallExplosion,
  "explosions.big-explosion": bigExplosion,
  "nature.earth-spike": earthSpike,
};

export const EFFECT_IDS = Object.keys(EFFECTS);
