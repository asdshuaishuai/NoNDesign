# pixelfx 调研：视频工作台的特效子集（只引入特效，不引入人物）

> 状态：**调研结论（2026-11-22）**，供视频工作台 `silly_skit` 战斗/环境特效使用。
> **未安装、未运行**；事实来自 README、`docs/AUTHORING.md`、`skills/pixelfx/SKILL.md`、
> `src/core/*` 与示例 effect 源码。
>
> 用户裁决（2026-11-22）：**pixelfx 直接引入我们的项目，但只引入特效，不引入人物**
> （火焰、冰霜、风、爆炸、闪电等）。这是「外部创作工具只参考」的第二个例外。
>
> 关联：[plan-creative-workbench.md](../plan-creative-workbench.md) §5 ·
> [research/awesome-opus5-5-videos.md](awesome-opus5-5-videos.md)（视频 prompt/节拍）·
> [skills/creative-workbench/SKILL.md](../skills/creative-workbench/SKILL.md)。

## 0. 结论先行

1. **它是什么**：`patch-gg/pixelfx` 是「像素艺术特效即代码」库：244 个特效，
   每个是一个 JS 文件；无图片、无依赖；直接画进 `color` + `light` 两个缓冲；
   可实时播放、换色、镜像、重播种，或导出 sprite sheet 给任何引擎。
   MIT，约 **8.7k stars / 1.1k forks**，v0.3.1（2026-11-22 核验）。
2. **它最适合我们的位置**：视频工作台的 `silly_skit`（沙雕短剧）战斗/冲击/环境
   特效——火焰、爆炸、冰霜、闪电、风、烟尘、水花、传送、治疗、拾取等。
   它的 1px 像素语法与「沙雕简笔 + 夸张物理」兼容，能在 1080p 下用低分辨率
   像素层 + nearest-neighbor 放大，形成明确的风格层。
3. **绝对不能引入的部分**：它自带的 24×38 stock character、`actor.js`/`rig.js`/
   `poses.js`/`act.js`、`moves/`（12 个成套攻击）以及所有依赖 `o.actor` 的
   「on-body」特效。**人物/木偶由我们自己的 rig 负责**；pixelfx 只提供特效。
4. **技术价值**：两缓冲（color + additive light）、seeded everything、纯函数/模拟
   两类 effect、120Hz 子步进、sprite sheet 导出、`tools/check.mjs` 的确定性/边界/
   循环/性能检查——这些和我们的「30fps 整数帧 + 确定性 seek」完全同构。
5. **接入方式**：vendor 一个**过滤子集**（core 去掉 actor + 选定类别），在视频
   WebView 里以固定 30fps 渲染到像素帧缓冲，再合成到成片；不引入它的 Claude skill、
   gallery、Patch 发布链、字体或人物资产。

## 1. 事实

| 项 | 事实 |
| --- | --- |
| 仓库 | `patch-gg/pixelfx`，MIT，JavaScript（ESM） |
| 版本 | `package.json` **0.3.1**；最近提交 2026-11-12 |
| 规模 | **244** 个特效；21 个类别；12 个 moves；61 个带角色的效果 |
| 依赖 | 核心零依赖；工具仅 Node ≥18（ffmpeg 可选，用于 GIF/MP4） |
| 渲染 | Canvas/`ImageData`；`color`（像素/抖动/半透明）+ `light`（加法辉光）双缓冲 |
| 时间 | 纯特效 `draw(p,t,o)`（t 的函数）；模拟特效 `create(o)` + 120Hz 子步进 |
| 确定性 | 所有随机数来自 effect seed；禁止 `Math.random`/`Date` |
| 导出 | `node tools/render.mjs <id> --sheet` → 透明 PNG 网格 + Aseprite JSON；`meta.pixelfx` 带 fps/loop/pivot |
| 质量工具 | `node tools/check.mjs <id>` 查越界、循环接缝、未播种随机、慢帧；`--all`/`--mp4`/`--act` 看运动 |
| 许可 | MIT（代码+特效）；`sim.js` 与部分特效改编自 Hugo Duprez（MIT）；`act.js` 改编自 Hollow Crown（MIT）；gallery 字体 Patch Pixel **不在 MIT 内** |

**类别**（README catalog）：moves 12、fire 12、explosions 12、water 12、ice 10、
lightning 11、sci-fi 12、melee 12、impacts 11、projectiles 13、spawn & death 10、
arcane 12、holy 10、shadow 12、status 13、nature 13、weather 12、ui 12、pickups 11、
transitions 10、critters 12。

## 2. 视觉/技术语法（值得直接借）

- **两个缓冲**：`color` 是不透明/抖动/真半透明像素；`light` 是加法辉光，叠在
  color 上。热的东西看起来热，是因为 light buffer，而不是把颜色调亮。
- **局部坐标**：`(0,0)` 是锚点——角色脚底、命中点、火把底座、枪口；x 右 y 下，
  1 单位 = 1px；定向特效朝右；地面特效站在 `y=0`。
- **纯特效 vs 模拟特效**：
  - 纯特效 `draw(p,t,o)`：画面只由 `t` 决定，循环无缝；适合光环、传送门、瀑布、
    光束、小生物。
  - 模拟特效 `create(o)`：在 `create`/`update` 里生成粒子/碎片/光，运行时按
    120Hz 或更细步进；适合爆炸、冲击、火焰、烟尘。
- **两套像素层**：`drawBack` 画角色后面的部分（远半环、背景烟），`draw` 画前面；
  我们的视频合成器需要同样的 back/front 分层。
- **种子化一切**：`new Rng(o.seed)`；同一 seed 第 40 帧永远一样；`tools/check.mjs`
  会抓未播种随机。
- **调色板**：每个特效接受 `palette`（暗→亮 ramp）；`fit(o.palette, n)` 适配任意
  长度；`PAL` 有 fire/ice/water/electric/poison/holy/arcane/shadow/blood/earth/
  stone/gold/leaf/wood/metal/bone/neon/cyber/matrix/candy/night 等 ramp。
- **质量 Bar**（`docs/AUTHORING.md` 的 10 条，摘要）：
  1. 线和光，不是大色块；1px 轮廓/环/拖尾/火花，白热核心 + 染色中间 + 深色阴影。
  2. 光到处都是：大范围低 k 光池 + 核心高光 + 每个火花/闪光 + 冲击瞬间的 Lights。
  3. 烟雾/蒸汽/尘/雾是半透明软体（`SMOKE`/`VAPOUR`/`DUST`/`p.disc`），不是棋盘抖动。
  4. 真实运动：火花按速度拉伸、下落、弹跳；碎片翻滚、弹跳、停住；火上升冷却成烟。
  5. 分阶段编排：蓄力/聚集 → 释放（1–2 帧白闪/hero frame）→ 扩散 → 停留
     （闪光/余烬）→ 破裂/融化 → 长衰减。
  6. 深度：地面环是扁椭圆，远半在角色后、近半在前；后排水晶/火焰更暗。
  7. 节奏：快进慢出；大特效余留 2–4s；命中 0.3–0.8s 但有 follow-through。
  8. 1x 可读：清晰焦点，形状内部不撒噪点。
  9. 原创：通用母题可以，绝不复制具体游戏 sprite/角色/logo。
  10. 干净：不出画布、一次性特效结束为空、循环无缝、确定性、<2ms/帧。

## 3. 与我们的视频运行时对齐

### 3.1 像素层，不是矢量层

pixelfx 是 1px 像素艺术：stock character 24×38，特效画布常见 96–320px 宽。
在 1080p 成片里直接按 1:1 画会太小/太细；建议：

- 在 **320×180 / 480×270** 的像素画布上渲染（或按场景像素密度定）；
- 用 `image-rendering: pixelated` / nearest-neighbor 放大到目标尺寸；
- `color` 层按背景合成，`light` 层用加法（或 `screen`）叠上；
- 固定 30fps；模拟特效内部 120Hz 子步进，但**帧号是唯一时间源**；
- effect seed 由 `hash(projectSeed, shotId, cueId, instanceId)` 派生；
- 一次性特效在 `t=duration` 画空；循环特效首尾同帧。

### 3.2 与 `screenplay.json` 的接线

新增 VFX 轨道/事件（示意）：

```jsonc
{
  "f": 42,
  "type": "vfx",
  "cue": "fire/fireball",
  "x": 540, "y": 960,
  "scale": 1.0,
  "flip": false,
  "palette": ["#2b0a06", "#7a1a10", "#d33a1e", "#ff8a2a", "#ffd166", "#fff3c4"],
  "seed": 7,
  "light": 1.2,
  "layer": "front"
}
```

规则：

- `cue` 必须是 **允许清单** 里的 id（无人物依赖）；未知 id 在编译期拒绝。
- `x/y` 是锚点（命中点/地面/枪口），不是包围盒左上角。
- `layer` 默认 `front`；地面环/远半环用 `back`（或 effect 自己的 `drawBack`）。
- `seed` 缺省由稳定 hash 派生；不允许运行时 `Math.random`。
- `palette` 走风格包白名单；不允许任意 CSS 颜色/渐变。
- 一次性特效的 `f + duration` 不能超过镜头；循环特效必须标 `loop`。

### 3.3 风格兼容矩阵

| 风格 | 用 pixelfx？ | 说明 |
| --- | --- | --- |
| `silly_skit` 沙雕短剧 | ✅ **主用** | 战斗/冲击/烟尘/火焰/冰霜/闪电/风；像素层与简笔角色可共存，注意统一像素密度 |
| `line_toon` 美式线条漫画 | ⚠️ 有条件 | 只在「像素特效作为刻意的风格层」时用；默认不要把像素火焰混进硬线漫画 |
| `ink_line` 墨线手绘 | ❌ 默认不用 | 1px 像素光效与细墨线/暖纸语法冲突；除非做「像素墨线」实验风格 |
| 3D 工作台 | ❌ 不用 | 3D 用 three-live/3dcodeverse；pixelfx 是 2D 视频特效 |

**人物边界**：`silly_skit` 的角色由我们自己的 cutout/rig 负责；pixelfx 不提供
人物、不驱动人物、不做 `createAct`/`moves`。需要「角色被火焰/冰冻」时，用我们
自己的角色层 + pixelfx 的**环境/命中特效**叠在周围，不调用 `onBody` 类效果。

## 4. 引入清单（直接引入，但只限特效）

### 4.1 Vendor 过滤子集

建议目录：`app/assets/video/vendor/pixelfx/`

```
core/                 # 只保留特效需要的模块
  color.js
  math.js
  painter.js
  sim.js
  shapes.js
  fx.js               # 去掉 stockActor import / actor 分支
  scene.js            # 如需要多 effect 合成
  index.js            # 只导出上述
fx/                   # 允许清单（见下）
LICENSE
NOTICE.md             # Hugo Duprez / Hollow Crown / Patch 字体排除
manifest.json         # upstream commit、版本、每个文件 sha256、允许清单
```

**不 vendor**：`actor.js`、`rig.js`、`poses.js`、`act.js`、`moves/`、`gallery/`、
`skills/`、`tools/`（工具只在开发期用，不进入产品）、字体。

### 4.2 允许类别（初版）

- ✅ fire、explosions、water、ice、lightning、nature、weather、impacts（非角色）、
  projectiles、melee（只取特效，不取 act）、arcane、holy、shadow、sci-fi、
  transitions、pickups、ui、status（只取非 on-body 的环境/光环部分）。
- ⚠️ critters（动物/小生物）：不是人类，但只有在场景需要时按 id 白名单加入；
  默认不随包。
- ❌ moves（成套攻击）、任何 `meta.actor`/`o.actor`/`onBody` 的 effect、
  任何会绘制 stock character 的 effect。

**允许清单生成**：vendoring 时扫描 `src/fx/**/*.js`，排除 `meta.actor`、`o.actor`、
`createAct`、`stockActor` 引用；把结果写入 `manifest.json`。清单是唯一事实源，
视频编译器只接受清单内 id。

### 4.3 运行时适配

- `createFrame(w,h)` → 我们的像素帧缓冲；`clearFrame` 每帧清。
- `createFx(mod, opts)` → 每个 VFX 实例；`update(dt)` 固定 1/30（内部 120Hz 子步进）；
  `draw(frame,"back"/"front")`；`composite(frame, rgba, bg)` 合成。
- 多个 effect 共享一帧；按 `layer`/y 排序；光层最后叠加。
- 移动端：优先 sprite sheet 预烘（`tools/render.mjs --sheet` 的产物格式），
  避免每帧跑 120Hz 粒子；桌面/WebView 可实时。
- 导出：把像素帧缓冲合成到 1080p 画布，nearest-neighbor 放大；不要用双线性
  （会糊掉像素边缘）。

## 5. 验收门（pixelfx 子集）

| 检查 | 判据 |
| --- | --- |
| 清单合法 | cue 在允许清单；无 `actor`/`onBody`/`moves` |
| 确定性 | 同 seed 同帧号输出同像素；无 `Math.random`/`Date` |
| 越界 | 不画到画布外；`check` 无 spill |
| 循环 | 循环特效首尾同帧；一次性特效 `t=duration` 为空 |
| 调色板 | 只接受风格包白名单 ramp；不出现任意 CSS 渐变 |
| 性能 | 单 effect <2ms/帧（桌面参考）；移动端走 sheet |
| 合成 | back/front 层正确；light 只叠加，不覆盖角色 |
| 人物边界 | 不出现 stock character/人类 rig；角色层来自我们自己的 rig |
| 许可 | LICENSE/NOTICE 随包；字体不引入；manifest 记录 commit/sha256 |

## 6. 只借什么 / 不借什么

| 借 | 不借 |
| --- | --- |
| 两缓冲（color + light）、seeded RNG、纯/模拟两类 effect、120Hz 子步进 | stock character、`actor.js`/`rig.js`/`poses.js`/`act.js`、`moves/` |
| 粒子/光/碎片/烟雾的配方与质量 bar | 任何 `meta.actor`/`onBody` 特效 |
| `tools/check.mjs` 的越界/接缝/随机/性能检查（开发期） | Patch 发布链、gallery、Claude skill、字体 |
| sprite sheet + Aseprite JSON 导出格式 | 它的人体/角色资产、示例场景 |
| 调色板 ramp 与 `fit()` 适配 | 把像素特效默认混进 `line_toon`/`ink_line` |

## 7. 未验证 / 待补

- 未安装/运行 pixelfx；性能、跨 WebView 行为、移动端内存未实测。
- 未验证 320×180 像素层在 1080p 视频里的观感；需要和 `silly_skit` 角色层做
  A/B（像素密度、缩放、光层强度）。
- 未验证 `sim.js` 在 30fps 固定步进下的确定性（它内部 120Hz，但浮点/顺序可能
  受引擎影响）；需要逐帧哈希对拍。
- 未决定初版允许清单的具体 id 数；建议先 30–50 个高频特效（火焰/爆炸/冰霜/
  闪电/烟尘/水花/风），再扩。
- 未做许可法务复核；MIT 代码可商用，但 Hugo Duprez/Hollow Crown 的 NOTICE 必须
  保留，Patch 字体不引入。

## 8. 来源

- 仓库：<https://github.com/patch-gg/pixelfx>
- `README.md`、`docs/AUTHORING.md`、`docs/CATALOG.md`、`skills/pixelfx/SKILL.md`
- `src/core/fx.js`、`src/core/sim.js`、`src/core/painter.js`、
  `src/fx/fire/torch.js` 等示例
- `NOTICE.md`、`package.json`、GitHub metadata（2026-11-22 核验）
