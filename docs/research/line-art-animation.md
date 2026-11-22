# 墨线手绘动画调研：JDhruv14/line-art-animation

> 状态：**调研结论（2026-11-22）**，供视频工作台 `ink_line` 风格包施工参考。
> **未安装、未运行、未引入代码**；本文事实来自 GitHub 元数据、README、`SKILL.md`、
> `references/` 与 `lib/` 源码的只读检查。标记：【事实】有仓库文档/源码来源；
> 【推断】是 NaN 侧工程判断。
>
> 约束：外部创作工具**只参考、不引入**（2026-11-21 用户裁决）——`ink_line` 是我们
> 自己的风格包，不依赖该仓库的 TypeScript/SVG 运行时，也不复制它的代码。
>
> 关联：[plan-creative-workbench.md](../plan-creative-workbench.md) §5.3 ·
> [research/video-animation-howto.md](video-animation-howto.md) ·
> [vision.md](../vision.md)（代码创造世界）。

## 0. 结论先行

1. **它是什么**：`JDhruv14/line-art-animation` 是一个 Claude skill + 无依赖
   TypeScript 小库 + 两个示例（单人 walker、整条 village 街景）+ 确定性截帧脚本。
   用 SVG 实时绘制「细、略抖的墨线 + 暖纸底」的人物与场景，支持行走、骑行、
   交互反应、昼夜循环，以及 headless Chrome 逐帧导出视频。MIT，TypeScript，
   约 **1.1k stars / 170 forks**（2026-11-22 核验），当前仍在更新。
2. **它为什么值得看**：它把「线条漫画」从「画得像不像」拆成了**可执行的规则**——
   开放双笔触四肢、求解式步态（脚不滑、髋高由腿长反解）、弹簧/摆锤次级运动、
   昼夜调色板反转、逐帧验收。它最有价值的不是 SVG 库，而是**运动求解器与验收纪律**。
3. **我们怎么用**：把它登记为视频工作台的**第三种风格 `ink_line`（墨线手绘）**，
   与 `silly_skit`（沙雕短剧）、`line_toon`（美式线条漫画）并列；只借风格参数、
   步态规则、昼夜逻辑与验收方法，渲染器自研。
4. **不引入什么**：不把它的 TypeScript/SVG 库作为依赖，不套它的 Claude skill，
   不复制示例角色/场景/媒体，不把 headless Chrome + ffmpeg 捕获链塞进产品运行时。
5. **渲染建议**：`ink_line` 在同一 `screenplay.json` 编译器下走**自研 Canvas2D
   矢量笔触分支**（固定 30fps、整数帧、种子化抖动、纸面遮挡），不运行时 SVG、
   不依赖 SVG filter；`silly_skit` / `line_toon` 仍走 Phaser 3。若移动端 1080p30
   实测不达标，再回退到预烘焙笔触图集（质量会打折，需实测后再定）。
   Phaser 3 裁决与 3D 栈例外均不变。

## 1. 仓库事实

| 项 | 事实 |
| --- | --- |
| 仓库 | `JDhruv14/line-art-animation` |
| 许可 | **MIT**（代码；示例媒体/字体是否可商用需逐项核对，本文不假设） |
| 语言 | TypeScript（主），少量 HTML/CSS |
| 社区 | 约 1,146 stars / 170 forks（2026-11-22） |
| 结构 | `SKILL.md` + `references/`（style/motion/scenes/verify/video/matching）+ `lib/` 四个模块 + `examples/walker`、`examples/village` + `scripts/`（capture/clip/frames） |
| 运行时 | Node ≥ 22.18；Vite 仅开发用；组件是普通 DOM/SVG，无框架 |
| 视频导出 | `scripts/capture.ts` 用 DevTools 协议驱动 headless Chrome，按 1/fps 精确步进截帧，再交给 ffmpeg；capture 本身无 npm 依赖 |
| 定位 | **参考实现/技能包**，不是 Flutter 库，不是产品，不是编码器 |

`lib/` 四个模块的分工（这正是「风格包」应该拆出的四层）：

| 模块 | 内容 |
| --- | --- |
| `ink.ts` | 笔、纸、开放双笔触四肢、纸面填充、IK、鞋、放置、抖动 filter、固定步长循环 |
| `gait.ts` | walk / shuffle / run 步态求解器：站立脚、摆动脚、脚跟离地、髋高 |
| `motion.ts` | 弹簧、摆锤、指针风、关键姿势序列、种子随机、分层正弦、缓动 |
| `daynight.ts` | 昼夜调色板：天空/纸/墨、灯光阈值、夜色 tint |

## 2. 视觉语法（可直接变成 style pack 参数）

一句话：**一支细、略抖的墨笔在暖纸上画；人物无脸、四肢开放、颜色极少；
建筑用正立面画满细节，天空留白。**

| 项 | 仓库默认值 | 说明 |
| --- | --- | --- |
| 笔宽 | `1.35` 人物单位（≈95 单位人物的 1.4%） | 更细像矢量，更粗像卡通 |
| 场景笔宽 | `pen × 人物缩放`（人物 0.5 → 约 0.7–0.8） | 建筑与人物必须同一支笔 |
| 细节笔宽 | `0.4–0.6 × pen` | 瓦线、格栅、排线、肋条 |
| 日间墨色 | `#1c1c1c` | **不是纯黑** |
| 日间纸色 | `#fdfcf8` / `#fdfdfc` | 暖白，**不是纯白** |
| 线帽/转角 | round | 所有笔画圆头圆角 |
| 抖动 | `feTurbulence` baseFrequency 0.6 / `feDisplacementMap` scale 0.45 / blur 0.12 | 轻微「墨」感，不是矢量硬边 |
| 人物空间 | 高约 95，脚在 y=120，朝 +x，站在 x=40 | 比例、笔宽、步态预设都按这个空间 |
| 头 | 小椭圆约 7×9，**无脸** | 角色感来自发型/帽子（发髻、鸭舌帽、礼帽、草帽、斗笠） |
| 头身比 | 成人 ≈1/9.5；儿童 ≈1/6 | 儿童头大、四肢短，草帽/帽子一眼读出年龄 |
| 四肢 | `limb()`：两条**开放**笔画夹一条纸色带，末端互不闭合 | 这是风格最可识别的签名；绝不画闭合管状四肢 |
| 腿/臂宽 | 腿 4.2、臂 3.6（人物单位） | 臂长 ≈0.44×身高；拎包的手垂到大腿，不是腰 |
| 脚 | `shoe()` 楔形，或木屐/足袋；脚跟先离地 | 脚要「剥」起来，不是整只平移 |
| 服装 | 绕骨架画：先解腿（即使被挡住），再按前膝+两踝画衣摆 | 大衣/和服随步幅开合；袖、围巾、包用弹簧 |
| 动物 | 只开放笔画：背线+腹线、单线腿+墨点脚、小头+耳 | 坐猫是闭合纸形+少量斑块；鸟是身体椭圆+帽子墨块+尾线 |
| 建筑 | 正立面（无透视），瓦沟/瓦当/椽头/格栅/障子/招牌画满 | 丰富度放在建筑；天空保持大片纸白 |
| 颜色 | 1–2 个点缀色，小面积（红伞、靛蓝和服、黄桶） | 物体不用渐变；渐变只给天空/光 |
| 场景卡 | 圆角卡片+软阴影，放在固定中性页面底色 `#ebe8e2` 上 | **页面底色不随场景昼夜变化**；2:1 是默认比例 |
| 图层 | 天空 → 建筑后景 → 建筑 → 街道/家具 → 行人（按 ground y 排序）→ 前景 → 粒子 → 辉光 → 热区 | 墨线 filter 只加在场景组，不加天空/辉光 |

**为什么它读起来像手绘**：四肢是两条开放笔画而不是闭合轮廓；所有线略弯、
转角圆；纸色填充制造前后遮挡；人物无脸，观众用发型/帽子/动作补全；颜色只做
小面积提示；建筑密度高、天空留白。这五条合起来就是「墨线手绘」，不是滤镜。

## 3. 运动语法（最值得移植的部分）

### 3.1 步态是解出来的，不是正弦波

仓库明确把「自由正弦步态」列为被拒版本。`gait()` 的四条规则：

1. **站立脚不滑**：支撑脚以 `speed = stride / (duty × period)` 向后滑，人物
   前进速度必须等于这个值；否则脚在冰上滑。
2. **摆动脚走 minimum-jerk**：走路抬脚低（3.4），跑步加脚跟后踢、抬高且早抬。
3. **脚跟离地**：支撑期最后 14% 以脚尖为支点旋转（pitch），不是整脚抬起。
4. **髋高反解**：走路时取站立腿能够到的最高髋位（双脚支撑时最低、腿并拢时最高）；
   跑步时在支撑脚上压缩、腾空时最高。**没有正弦上下 bob。**

| 预设 | period | duty | stride | lift | heelOff | heelKick | thigh/shin | ankleY | toe |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `walk` | 1.0s | 0.62 | 24 | 3.4 | 15° | 0 | 23/23 | 118.4 | 4.2 |
| `shuffle` | 0.9s | 0.64 | 18 | 2.4 | 12° | 0 | 23/23 | 116 | 4.2 |
| `run` | 0.5s | 0.36 | 16 | 12 | 10° | 3.5 | 13/13 | 118 | 3 |

> 这些是**人物空间单位**的默认值，不是像素；场景里乘人物缩放。成人约 2 步/秒；
> 和服/木屐步幅更短更低；儿童跑约 4 步/秒并前倾。

其他关键实现：

- **两骨 IK**：髋→膝→踝，膝盖朝前；前腿画在上层（`front`）。
- **停顿**：`go ∈ [0,1]` 把双脚混合回站姿；要鞠躬/招手先让 `go` 在约 0.4s 内降到 0。
- **服装绕骨架**：前缘从腰→前膝→前踝下方；衣摆从前踝到后踝（腿分开时呈 A 形）；
  后缘只在后腿向后伸时推开；后膝有折线，前脚有叠线。腿被和服挡住也要解。
- **上身**：骑在 `bob` 上，带 1–2° 倾斜；手臂与腿反向摆，用弹簧；袖/包用摆锤。
- **车轮**：角 = 位移/半径；曲柄按齿比；脚踩踏板用 IK。**撑船**：竿尖钉在水里，
  船在竿下前冲、竿后仰、再抬起前摆；船速跟推竿，不是常量。
- **悬挂物**：弹簧（袖、围巾、包、伞倾角）与摆锤（灯笼、窗帘、风铃、柳条、晾衣）。
  驱动量是风、载体加速度、点击。
- **闲置生命**：呼吸 ±0.35、尾尖偶尔弹、耳朵抖、鸟 1–4s 随机跳/转/理羽、烟、
  水纹、星星闪。**随机化间隔，不随机化形状。**
- **手势**：关键姿势 + `sequence()`/`curve()`，每段缓动；典型时长：鞠躬 2.6s、
  抬帽 1.6s、猫醒 8s。
- **时间压缩**：一天压到 30s 时，人仍按自然速度走；能压的是到达频率、天空、灯光，
  不是步态。

### 3.2 昼夜与光照

`palette(τ)`，τ∈[0,1)：0 午夜、0.25 黎明、0.5 正午、0.75 黄昏。

- 白天深墨+暖纸；夜晚**反转**成浅墨+靛蓝纸，光来自窗、灯笼、路灯、车灯、
  萤火虫，每盏灯有暖色径向辉光，放在 `mix-blend-mode: screen` 的辉光层。
- `inkT` 由纸的亮度驱动；`lamp` 由纸亮度阈值驱动；`night` 由天空亮度驱动；
  `sunset` 是黎明/黄昏两个窗口的乘积。
- **每扇窗有自己的开灯阈值**，所以灯会一盏盏亮/灭；店铺打烊收帘；鸟归巢、
  萤火虫/飞蛾出现、猫眼发光；水面有灯源的横向暖色倒影。
- 平面色在夜里过 `nightTint()` 压向夜色；墨色用 `currentColor` 统一翻转。
- 组件默认从下午 τ≈0.66 开始，访客一分钟内能看到黄昏；可拖太阳/月亮刷时间。

## 4. 确定性与验收（这部分比画面更值得学）

仓库把「看起来对」拆成可执行的检查：

1. **精确步进**：`?debug` 关闭 rAF，暴露 `window.__step(seconds)`，按 1/60s
   精确推进；`?t=1.25` 冻结某一刻。背景标签页/headless 会把 rAF 限到 1–2fps，
   所以验收必须在 debug 模式。
2. **看帧条，不看整卡截图**：把 SVG 容器放大 4–11 倍或截帧后裁剪，逐帧看：
   站立脚是否不动、身体是否在支撑脚上起伏、衣服是否随步幅开合、前腿是否在上层、
   线是否没有尺子直、四肢末端是否开放、道具是否在手上。
3. **触发每个交互**：对每个热区派发 `pointerdown`，截开始/中段/结束，确认能回 idle。
4. **扫一天**：τ=0.3/0.5/0.72/0.75/0.8/0.95/0.24，检查对比度、墨色翻转、
   灯依次亮灭；除了短暂翻转瞬间，对比度必须成立。
5. **真实帧率**：前台标签页数 3s rAF，目标 ~60。
6. **视频捕获**：`capture.ts` 用 headless Chrome，按 1/fps 精确推进，不依赖机器速度；
   ffmpeg 编码后先看 contact sheet。1080p30 的 30s = 900 帧，约 90s 捕获。
7. **参考片匹配**：先 `ffprobe` 判断可变帧率，按时间重采样（`-vf fps=30`）；
   用 `clip.ts period` 量循环长度、`blobs` 跟踪脚部暗块、`frames.sh` 打网格读姿势；
   最后用 `?overlay` 把参考视频和自己的画对齐检查。**借运动感觉，不抄角色。**

## 5. 映射到 NaN 的 `ink_line` 风格包

### 5.1 定位

- 第三种视频风格，与 `silly_skit`、`line_toon` 并列；`screenplay.json` 的
  `style` 取 `"ink_line"`。
- 适合：生活流、街道/店铺/小镇、产品故事、温柔叙事、昼夜变化、无脸角色群像。
- 不适合：沙雕短剧的夸张挤压/弹跳、美式硬线分格、强动作/物理喜剧——那些仍走
  `silly_skit` / `line_toon`。
- 它**不是**「line_toon 换个颜色」：`line_toon` 是硬边单线+气泡+分格；
  `ink_line` 是抖墨线+纸面遮挡+开放四肢+昼夜反转，角色与场景语法不同。

### 5.2 数据模型增量

`screenplay.json` 已有 `style`；`ink_line` 需要把风格参数显式化（可作为内置
style pack，也可落 `style-pack.json`，施工时二选一，不把大对象塞进每份剧本）：

```jsonc
{
  "style": "ink_line",
  "stylePack": {
    "renderer": "ink_canvas",
    "pen": 1.35,
    "scenePenScale": true,
    "inkDay": "#1c1c1c",
    "paperDay": "#fdfcf8",
    "accents": ["#b4553f", "#3f5f8a"],
    "wobble": { "amplitude": 0.45, "frequency": 0.6, "seed": 7 },
    "figure": { "height": 95, "feetY": 120, "headRatio": 9.5,
                "legWidth": 4.2, "armWidth": 3.6 },
    "gait": { "walk": { "period": 1.0, "duty": 0.62, "stride": 24,
                        "lift": 3.4, "heelOff": 15 },
              "shuffle": { "period": 0.9, "duty": 0.64, "stride": 18,
                           "lift": 2.4, "heelOff": 12 },
              "run": { "period": 0.5, "duty": 0.36, "stride": 16,
                       "lift": 12, "heelOff": 10, "heelKick": 3.5 } },
    "palette": { "startTau": 0.66, "dayLengthFrames": 900 }
  }
}
```

角色 rig 不是 cutout 部件，而是 `ink_figure`：

```jsonc
{
  "kind": "ink_figure",
  "joints": ["hip", "knee_l", "knee_r", "ankle_l", "ankle_r",
             "shoulder_l", "shoulder_r", "elbow_l", "elbow_r",
             "wrist_l", "wrist_r"],
  "garment": { "kind": "coat|kimono|shirt", "hem": "knee|ankle" },
  "head": { "hair": "bun|cap|bowler|straw|kasa", "face": "none" },
  "props": ["bag", "parasol", "lantern"]
}
```

轨道增量：

| 轨道 | 作用 |
| --- | --- |
| `gait` | `{kind, phase0, speedScale, goKeys}`——由相位解姿势，不逐帧烘关键帧 |
| `pose` | 手势/反应的关键关节角，`sequence` 分段缓动 |
| `attachment` | 袖/包/伞/灯笼的弹簧或摆锤参数（stiffness/damping，初始状态） |
| `palette` | τ 关键帧（场景时间），不是 wall clock |
| `light` | 每扇窗/每盏灯的 `onThreshold` / `offAt`，允许错峰 |

**确定性铁律**：30fps 整数帧；`phase = frame / (30 × period)`；弹簧/摆锤从镜头
起点按 1/30 固定步长积分（seek = 重置+重放）；静态细节用 `seeded(seed)`；
禁止 `Math.random` / `Date.now` / 物理引擎参与状态。

### 5.3 渲染分支：Canvas2D 矢量笔触

建议 `ink_line` 走**自研 Canvas2D 渲染器**，不运行时 SVG：

- 细线在 1080p 需要连续笔触；Canvas2D 的 `lineCap/lineJoin=round` 直接满足，
  纸色填充天然做遮挡；不需要 DOM/SVG 节点树。
- 静态建筑/道具预生成 `Path2D` 缓存；动态人物每帧只重建关节相关的路径，
  坐标四舍五入到 0.01px，避免每帧字符串分配。
- **抖动用几何，不用 filter**：沿路径法线加一层种子化、低频的偏移（amplitude
  0.45 / frequency 0.6 量级），而不是 `feTurbulence`。这样跨 WKWebView/
  WebView2/WebKitGTK/Android WebView 的渲染结果一致，也能逐帧复现。
- 四肢按 `limb()` 的几何复刻：沿关节二次贝塞尔采样 17 点，向两侧偏移
  `(width - pen)/2`，得到纸色带；两条开放笔画各留 0.4/0.9 的末端缺口。
- 图层顺序按 §2；行人每帧按 ground y 排序；辉光单独一层，用 `screen` 混合。
- 固定 30fps；预览 rAF 只决定「显示第几帧」，不把 delta 喂给状态。
- **性能门**：先在 WKWebView/WebView2 各跑 1080p30、40 个运动对象、约 100 条
  动态路径；单帧 >16ms 就减采样/把静态层预烘到离屏 canvas。仍不达标再回退
  预烘焙笔触图集（走 Phaser），但细线锐度会打折，必须实测后再定。

为什么不是 Phaser 直接画：Phaser 的强项是 Sprite/物理/相机；`ink_line` 需要
连续细线、纸面遮挡、每帧关节几何，用 Phaser Graphics 每帧重建反而绕。**这不是
替换 Phaser**：`silly_skit` / `line_toon` 仍走 Phaser 3；`ink_line` 是同一
`screenplay` 编译器下的第二个执行后端，渲染器是我们自己的代码，不引入外部引擎。

### 5.4 验收锚点

在通用视频验收（时长、台词、音效、字幕安全区）之外，`ink_line` 加确定性检查：

| 检查 | 判据 |
| --- | --- |
| 站立脚不滑 | 支撑期每帧世界 x 漂移 < 0.5px（按场景缩放） |
| 髋高是解出来的 | `bob` 非常量、无固定正弦；双脚支撑低、腿并拢高 |
| 四肢开放 | 每条肢体两条笔画、末端有缺口、无闭合管 |
| 前腿在上 | `front` 腿的绘制顺序正确 |
| 纸面遮挡 | 衣摆/建筑遮挡关系随层序正确，不靠透明度 |
| 昼夜对比 | τ 扫描下墨/纸对比度 ≥4.5（大字/大块可 3.0）；翻转瞬间除外 |
| 灯光错峰 | 窗/灯按各自阈值亮灭，不是全场景同时开关 |
| 交互回 idle | 每个热区触发后 1–8s 内回到 idle |
| 帧率 | 1080p30 预览稳定；导出帧与预览同帧号同姿势 |

**流程门**（借它的工作流，不借代码）：先钉死笔宽/纸色/人物比例/1–2 个点缀色 →
只做一个 figure 或一个角落 → 给用户看截图/短片段 → 通过后再铺整场。
「一次生成整套」正是它明确拒绝的 AI slop 路径。

### 5.5 施工批次建议

| 批次 | 内容 | 验收 |
| --- | --- | --- |
| I0 | style pack schema + `ink_figure` rig + 一个 walker + Canvas2D 笔触 spike | 1080p30 单帧 <16ms；脚不滑；一帧条通过 |
| I1 | gait 三预设 + 两骨 IK + 鞋/衣摆/前腿层序 | 走/跑/和服步的帧条对比 |
| I2 | 场景层序 + 纸面遮挡 + 建筑细节 + 深度排序 | 静态场景与行人穿插正确 |
| I3 | 昼夜 palette + 窗/灯阈值 + 辉光/倒影 | τ 扫描 contact sheet |
| I4 | 手势/交互 + 弹簧/摆锤 + 参考片匹配 | 每个交互回 idle；overlay 对齐 |
| I5（可选） | 走现有 readPixels→ffmpeg 导出 | 帧级可复现；同帧号同姿势 |

不建完整 village 再验收——先一个 figure，符合「单点先过」的流程门。

## 6. 只借什么 / 不借什么

| 借（规则/参数/方法） | 不借（代码/运行时/资产） |
| --- | --- |
| 视觉语法：笔宽、纸色、无脸、开放双笔触、纸面遮挡、建筑正立面、1–2 点缀色 | TypeScript/SVG 库 `lib/` 作为依赖 |
| 步态求解：站立脚、minimum-jerk 摆动、脚跟离地、髋高反解、`go` 停顿混合 | 直接复制 `gait.ts` / `ink.ts` 代码 |
| 两骨 IK、服装绕骨架、前腿层序 | 运行时 SVG DOM + `feTurbulence` filter |
| 弹簧/摆锤/指针风/种子随机/分层正弦 | `Math.random` / `Date.now` / 指针风进入成片状态 |
| 昼夜 palette、灯光阈值、夜色 tint、辉光层 | Claude skill 打包方式、示例角色/场景/媒体 |
| `?debug` 精确步进、帧条验收、一天扫描、参考片测量/overlay | headless Chrome + ffmpeg 作为产品运行时（导出可另走我们自己的链路） |
| 工作流：先钉 look、单 figure 先过、再铺整场；「新就是新」 | 把 OpenMotion/HyperFrames/line-art-animation 套壳成我们的工作台 |

**3D 栈例外不变**：three.js / three-live 仍是明确例外；本文不涉及 3D。
**Phaser 3 不变**：`silly_skit` / `line_toon` 的引擎短片继续按 2026-11-20 裁决。

## 7. 未验证 / 待补

- 没有安装/运行该仓库，没有实测它的渲染质量、性能、跨平台行为；本文的数值来自
  源码默认值，不是我们的实测结论。
- 没有在 WKWebView / WebView2 / WebKitGTK / Android WebView 上测 Canvas2D
  1080p30 的帧预算；I0 必须先做这个 spike。
- 没有验证几何抖动与 SVG filter 抖动在视觉上的差异；需要用同一帧条对比。
- 没有核验示例媒体/字体的授权（代码 MIT 不等于示例资产可商用）；我们不复制它们。
- 没有把它的 MCP/技能工作流映射到我们的工具面；本文只借「流程门」。
- 没有决定 `ink_line` 是否进入首版风格包；本文把它登记为方案线第三种风格，
  施工优先级由视频批次 5b 统一排。

## 8. 来源

- 仓库：<https://github.com/JDhruv14/line-art-animation>
- `README.md`、`SKILL.md`
- `references/style.md`、`references/motion.md`、`references/scenes.md`、
  `references/verify.md`、`references/video.md`、`references/matching.md`
- `lib/ink.ts`、`lib/gait.ts`、`lib/motion.ts`、`lib/daynight.ts`
- GitHub metadata（stars/forks/license/language/updated，2026-11-22 核验）
