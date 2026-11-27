// pixelfx 特效子集的页面侧入口（IIFE，全局 NAN_PIXELFX）。
//
// 只做一件事：把「已入库、actor-free」的特效子集包成一个**确定性像素渲染器**，
// 供 Phaser 引擎短片播放页按帧调用：
//   renderInto(ctx, {cue, x, y, seed, flip, advanceFrames, fps, width, height})
//     → 返回该帧非空像素数（0 = 这一帧没画出来，宿主可如实降级）
//
// 纪律：不联网、不读文件、不用随机/墙钟；同一 (cue, seed, advanceFrames) 必然
// 产出同一 RGBA 字节（pixelfx 内部 120Hz 子步进由固定 fps 驱动）。
import { EFFECTS } from "../../app/assets/pixelfx/fx/index.js";
import { createFrame, clearFrame, createFx, composite } from "../../app/assets/pixelfx/core/index.js";

function finite(value, fallback) {
  const number = Number(value);
  return isFinite(number) ? number : fallback;
}

const frameCache = new Map();

function frameFor(width, height) {
  const key = width + "x" + height;
  let frame = frameCache.get(key);
  if (!frame) {
    frame = createFrame(width, height);
    frameCache.set(key, frame);
  }
  return frame;
}

let imageDataCache = null;

export function renderInto(ctx, options) {
  const opts = options || {};
  const cue = String(opts.cue || "");
  const mod = EFFECTS[cue];
  if (!mod) throw new Error("pixelfx: cue not in subset: " + cue);
  const width = Math.max(1, Math.floor(finite(opts.width, 320)));
  const height = Math.max(1, Math.floor(finite(opts.height, 180)));
  const fps = Math.max(1, finite(opts.fps, 30));
  const advance = Math.max(0, Math.floor(finite(opts.advanceFrames, 0)));

  const frame = frameFor(width, height);
  clearFrame(frame);

  // 每个事件每次渲染都从 t=0 重建实例并推进到目标帧：纯函数式重建，
  // 避免状态跨帧漂移（同一帧号 seek 两次必然同一画面）。
  const fx = createFx(mod, {
    x: finite(opts.x, Math.floor(width / 2)),
    y: finite(opts.y, Math.floor(height * 0.9)),
    seed: Math.floor(finite(opts.seed, 0)),
    flip: !!opts.flip,
  });
  for (let i = 0; i < advance; i++) fx.update(1 / fps);
  fx.draw(frame, "back");
  fx.draw(frame, "front");

  const pixels = width * height;
  let out = imageDataCache;
  if (!out || out.width !== width || out.height !== height) {
    out = { width: width, height: height, data: new Uint8ClampedArray(pixels * 4) };
    imageDataCache = out;
  }
  for (let i = 0; i < out.data.length; i++) out.data[i] = 0;
  // 透明背景合成：光效变成 alpha，叠到目标画布上就是加法发光。
  composite(frame, out.data, null, 1);

  let drawn = 0;
  for (let i = 3; i < out.data.length; i += 4) {
    if (out.data[i]) drawn++;
  }
  if (drawn > 0) {
    const imageData =
      typeof ImageData === "function"
        ? new ImageData(out.data, width, height)
        : null;
    if (imageData) {
      ctx.putImageData(imageData, 0, 0);
    }
  }
  return drawn;
}

export const effectIds = Object.keys(EFFECTS);
