# 真机 demo 证据（2026-11-28，Linux WebKitGTK）

由集成测试真机生成（不是离线合成）：

```bash
WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1 \
  bash scripts/wf/run_webview_smoke.sh --plain-name demo
```

## 3D 视频（three.js WebGL 真渲染）

- 项目：`_sceneRaw()`（地板 + 立柱 + 平行光 + hero 机位）+ `_screenplayRaw()`
  （s1 静态 3s → s2 相机运动 2s，共 150 帧 @30fps）；
- 渲染器：`webgl_three_r160`（真机 WebGL 命中）；
- 帧证据：`3d-frame-{0,90,120,149}.png`（1280×720）+ `3d-manifest.json`。
- 读图要点：`0` 与 `90` **字节相同**是正确行为——s2 的 `move.from` 与 s1 的
  `hero` 机位同为 `[6,3,6]`（续接同一机位）；s2 内部（`90` → `149`）像素不同，
  证明**帧号真的驱动相机**（11871B → 9094B）。

## 视频（引擎短片：Phaser 4 + pixelfx 真像素 VFX + 风格包）

- 剧本：两镜头 90 帧 @30fps（火焰特效 + 字幕 + 闪电 + 震屏）；
- 风格包：`warm_amber`（palette/typography/motion 全生效）；
- 渲染面：`phaser4_canvas` + `pixelfx_pixels`（真像素管线）；
- 帧证据：`short-frame-{0,20,50,80}.png`（320×180）+ `short-manifest.json`。
- 读图要点：`20` 帧 12497B vs 其余 735–742B —— 第 20 帧火焰特效已铺满画面，
  其余帧只有底色/进度条，**特效真的画出来了**。

## 复验

同输入同帧字节一致（确定性）；两份 manifest 记录 renderer/vfx/style/帧号/字节数，
可与 PNG 逐一核对。
