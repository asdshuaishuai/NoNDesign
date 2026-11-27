# 创意工作台交互升级与模块规范（2026-11-20 定稿，2026-11-22 增补 ink_line / 3dcodeverse / pixelfx，2026-11-24 增补 toon_3d 候选与 Raea/Material Painter 候选评估，未施工）

> 状态：**方案定稿；部分批次已落地（2026-11-24 工作树）**。批次 0/1/1b/2/3 已实施；
> 批次 4（3D）仅契约面（v2 工作区/plan 校验/确定性门/测量/构建/摆放门/双面），建模视口、GLB、多视角与 judge 待后续；
> 批次 5a+ 未施工。后续排序见 [plan-next-iterations.md](plan-next-iterations.md)。本文覆盖全局交互升级与四个工作台的能力/联动裁决；
> 音乐模块的技术面（谱面/合成/编译器）以 [plan-music-module.md](plan-music-module.md) 为准。
> 施工按 §7 分批，每批完成回填落地锚点。
>
> 相关文档：[vision.md](vision.md)（愿景：代码创造世界——四个工作台是同一底座的四视图）·
> [README.md](README.md)（总纲）· [plan-cross-platform-runtime.md](plan-cross-platform-runtime.md)
> （全平台 WebView 是本方案工作台 UI 的前置；wasm 宿主迁移互不阻塞）·
> [video-clip-contract.md](video-clip-contract.md)（现有 v1 短片契约；§5.0 的引擎短片是第三渲染面）。

## 0. 用户裁决汇总（2026-11-20，全部有效）

| # | 裁决 |
| --- | --- |
| 1 | 全局交互：强化工作台的**执行过程与结果**呈现；Agent 执行保持在**右侧 chat** |
| 2 | 设计 = 产品 → 交互的一站式「验证式热应用」；该产物**绑定原型本身**，**不再列入热应用模块** |
| 3 | 3D = **建模**（three.js 实现），强化工作区形态与建模能力 |
| 4 | 视频 = 用代码创造视频与动漫；新增两种场景风格（**沙雕短剧** / **美式线条漫画**）；引入**导演台**、**剧本标准**、**TTS**；**联动音乐工作台制作配乐**（继「设计→热应用」之后的第二个跨模块联动，显式裁决）；2026-11-22 增补第三种风格，见 #8 |
| 5 | 音乐 = 编曲工作台（详见 plan-music-module.md），承担视频配乐联动 |
| 6 | **所有工作台必须强绑定且强规范**（结构性纪律，见 §1） |
| 7 | 视频渲染**引入游戏引擎**（2026-11-20 补充裁决）：选定 **Phaser 4.x**（vendored 运行时，2026-11-28 升级），`screenplay.json` 编译为引擎短片（见 §5.0） |
| 8 | 视频新增**第三种风格 `ink_line`（墨线手绘）**（2026-11-22 用户裁决）：参考 `JDhruv14/line-art-animation` 的线稿/步态/昼夜规则，**不引入其 TypeScript/SVG 运行时**；`silly_skit` / `line_toon` 保留 |
| 9 | 3D **直接引入 threejs-live + 3dcodeverse**（2026-11-22 用户裁决）：采用 3dcodeverse 的 skill/harness 契约（Apache-2.0）与 three-live 执行面；Python/Blender/CadQuery/URDF 运行时不进入产品进程，检查器按 Dart/JS 等价实现（见 §4） |
| 10 | 视频 **直接引入 pixelfx 特效子集**（2026-11-22 用户裁决）：只取火焰/冰霜/风/爆炸/闪电等**特效**，**不含人物/角色**；`actor`/`rig`/`poses`/`act`/`moves` 与 on-body 特效一律不引入（见 §5.3、§5.6） |
| 11 | **统一创作 skill `creative-workbench`**（2026-11-22）：把 intake/direction/structure/build/check/blind-judge/refine/deliver 标准化，视频、3D、设计共用；`awesome-opus5-5-videos` 只提供提示词结构参考，不引入其作品/服务（见 `docs/skills/creative-workbench/`） |

## 1. 工作台强绑定强规范（统一契约框架）

### 1.1 强绑定（结构性约束，测试锚定）

| 绑定 | 内容 | 锚定 |
| --- | --- | --- |
| 项目 ↔ 工作台 | 项目类型字段决定落地视图：打开音乐项目必落 `plugin:music`，3D 落 `plugin:three`……（「工作台跟随项目」裁决的全面推广） | `project_landing` 测试族扩四类 |
| 工作台 ↔ 事实源 | 编辑器只经**事实源文档**变更（无第二份状态）；撤销栈按项目 | 每模块编辑器测试 |
| Agent ↔ 工具面 | workspace 模式只见本模块 `<module>_*` 工具 + 通用只读；**跨模块动作只能走裁决过的联动通道**（当前两条：设计→验证原型、视频→音乐配乐） | 工具面收窄测试 |
| 执行归属 | 一次 run 的产物只落它绑定的项目；预览/结果不串项目 | preview 归属校验族 |

### 1.2 强规范（每模块必须交付的「四件套」，缺一不可）

1. **事实源 schema**：版本化（`v` 字段）、字段域、上限、迁移规则；落
   `docs/<module>-contract.md`。
2. **确定性校验器**：纯函数 `verify<Module>()` → `{verified, checks[]}`；失败如实
   上报不阻断（hotapp 覆盖验证同族纪律）。
3. **工具面**：`<module>_list / create / read | inspect / patch | refine / verify`
   命名族 + `toolFailureMessage` 人话映射 + 提示词教学。
4. **执行/结果双面**：统一进度线（§2.2）+ 产物卡（§2.3）。

**没有契约文档 + 契约测试的模块视为未完成**。契约测试模板：schema roundtrip、
校验器清单、编译器字节确定性、工具接线、落盘扫描。

## 2. 全局交互定型：右 chat + 工作台双面

> **2026-11-24 内容区独立适配**：外层壳（标题栏/左轨/右 chat/状态栏）仍统一；
> 每个工作台内容区的交互姿态/布局各自独立（设计画布优先、3D 视口+大纲/检查器、
> 视频导演台/时间线、音乐谱面/运输条），按 设计→3D→视频→音乐 分批，热应用暂不动。
> 详见 [plan-workbench-ui.md](plan-workbench-ui.md) 与
> `app/lib/core/workbench_layout.dart`。

### 2.1 版面

* 桌面 / 平板横屏：主面 = 工作台（执行过程面 + 结果面）；**右侧 = NaN chat**
  （唯一对话/控制面，时间线只在这里，工作台不复制）。
* 手机（锁竖屏）：chat 全屏 + 实况卡（既有裁决）；工作台的查看/播放可达。

### 2.2 执行过程面（四工作台统一骨架）

* **进度线**：本模块管线阶段条——
  设计（文档 → 画布 → 验证原型）、3D（建模阶段）、视频（剧本 → 分镜 → 渲染 →
  配音 → 配乐）、音乐（写谱 → 校验 → 编译）。
* 当前步实时态、可取消、失败原因人话（原始诊断折叠）。
* 与右侧 chat 时间线**分工**：chat 给逐事件轨迹；工作台给模块化阶段进度。

### 2.3 结果面（产物卡规范）

每完成一步/整轮出**产物卡**：标题 + 关键指标 + 主操作按钮；终态二元（成功/失败卡，
与 agent 终态卡同语义）。

| 模块 | 产物卡 |
| --- | --- |
| 设计 | 原型缩略 + 「打开验证原型」 |
| 3D | 场景快照 + 「进入建模视图」 |
| 视频 | 成片首帧 + 时长 + 「播放 / 分镜表」 |
| 音乐 | 谱面缩略 + 时长/轨道数 + 「播放」 |

### 2.4 统一 creative-workbench skill（标准化）

所有创作线共用一份 skill 契约：[`docs/skills/creative-workbench/SKILL.md`](skills/creative-workbench/SKILL.md)。
它把「创意」拆成可检查的七步，而不是一段万能提示词：

```
intake → direction → structure → build → check → blind judge → refine → deliver
```

**标准四件套**（与 §1.2 的四件套对齐）：

| 件 | 内容 |
| --- | --- |
| `spec.json` | 请求：kind/track、prompt、must/must-not、dims/duration、references、style、output |
| `plan.json` | 精确数字 + acceptance：3D 的 parts/dims/materials，视频的 shots/beats/duration |
| `src/` | 可执行源；code 模式是事实源，scene 模式由 `scene.json` 编译 |
| `artifacts/` + `judge/rNN/` | 渲染/测量证据；blind judge 的 brief/montage/judgment/score |

**四条跨线硬规则**：

1. **代码是真相，产物是派生物**；GLB/PNG/MP4/sheet 都可重建。
2. **确定性门先行，视觉判断殿后**；门 ERROR 直接 cap 分数，视觉不能翻案。
3. **生成者与评审者分离**；judge 只看 brief + 图，不看代码/推理。
4. **交付最佳轮，不是最后一轮**；每轮 `rNN` 可回退。

该 skill 不引入新运行时：3D 走 three-live，视频走应用 WebView，VFX 走过滤后的
pixelfx 子集；Python/Blender/headless Chrome 只在开发期参考。

## 3. 设计：验证式原型一站式（绑定原型）

* **裁决变更**：验证式热应用**不再进热应用模块列表**，绑定设计项目本身。
* 形态：设计项目 `.ddp`（事实源不变：mbt + DESIGN.md）内派生 `prototype/`
  （自包含 HTML + manifest）；覆盖验证照旧（每屏 `data-screen`、每条连线 `data-nav`，
  确定性检查、`verified` 如实上报）。
* 入口：设计工作台工具条「验证原型」+ 结果卡；热应用工作台列表不再出现原型验证
  demo（热应用保留独立作品：手工 / 导入 / agent 独立创建）。
* Agent 工具收口：`hotapp_from_prototype` → **`design_verify_prototype`**（工具面归
  设计模块，产物落项目目录）。
* 一站式链路：一句话或导入文档 → PRD/UI/DESIGN.md → 画布原型 → 验证原型（同项目闭环）。
* 迁移：已存在于 hotapps 的原型验证 demo 保留文件、从列表过滤（登记迁移项，
  不静默删除用户数据）。
* 验收：项目内 prototype 生成 / 覆盖验证结果 / 入口可达 / 热应用列表不含。

## 4. 3D：建模工作台 + 3dcodeverse harness

* 定位：three.js 实现的**建模**工作台（从「场景展示」升级为「建模」）；执行面 =
  vendored **three-live 1.4.0** 沙箱，编辑面 = 大纲/视口/检查器。
* **直接引入（2026-11-22 用户裁决）**：threejs-live + 3dcodeverse 的
  **skill/harness 契约**（Apache-2.0）——控制器/语言 skill、`plan.json` schema、
  确定性门阈值、judge rubric、`spec/src/artifacts/judge` 工作区布局。
  **不引入** Python CLI / Blender / CadQuery / URDF / moderngl 运行时（产品无 Python
  子进程）；需要的检查器用 Dart/JS 等价实现。数据集 CC-BY-NC-SA 不随产品分发。
* **双 authoring 模式**（解决 `scene.json` 与「code is truth」的冲突）：

| 模式 | 事实源 | 适用 | 编辑器 |
| --- | --- | --- | --- |
| `scene` | `scene.json`（v1：nodes/transform/material/env/camera，节点 ≤200） | 手工建模、图元/变换/材质、轻量场景 | 大纲/视口/检查器直接改 JSON；编译成 `src/scene.js` 预览/导出 |
| `code` | `src/*.js` | 一句话生成、3dcodeverse harness、复杂世界/shader | 源码为主；检查器读派生 scene graph，编辑走受控 patch；禁止整文件重写 |

  新空场景默认 `scene`；生成/harness 路径默认 `code`。两种模式共用 three-live、
  同一套门/judge/artifacts；`code` 模式的 `scene.json` 是**派生投影**，不是第二真相。
* **工作区**：`spec.json`（track/language/prompt/must/dims/references）+
  `plan.json`（精确数字 + acceptance）+ `src/` + `artifacts/` + `judge/rNN/`。
* **工作区形态**：三栏 = 大纲（场景树）｜视口（Orbit 相机、网格、拾取、变换 gizmo
  move/rotate/scale、吸附）｜检查器（对象变换/材质/几何参数）；现有 scene spec /
  pass 管线保留为**生成管线**（brief → plan → scene/code → check）。
* **轨道**：v1 做 `static_object`（threejs）、`scene`（scene_threejs）、
  `graphics`（glsl_shader）；`articulated_object`（URDF/Blender）列入 backlog，
  先用 three.js Group 层级 + 自定义 joint 检查近似。
* **计划/验收**：plan 必须写精确尺寸/材质/父级/bbox + 二分验收项（如「座高
  0.45m」「四腿落地 ≤2mm」「无漂浮/穿插 >2mm」）；`three_plan_validate` 通过后才写代码。
* **确定性门**（先于视觉）：contract（bbox max(10mm,10%)、ground 10/30mm、
  footprint 居中、placeholder part）、connectivity（接触 ≤2mm、穿插 >2mm WARN /
  >10mm ERROR、漂浮 ERROR）、detail budget、scene placement/census/draw calls、
  shader compile、frame metrics；每条 ERROR 带可执行 fix hint。
* **盲评**：`three_judge` 打包 brief + 多视角 montage（对象 14 视角；场景作者相机
  t=0/1.5s + orbit；图形 frame sheet），交独立 judge 上下文；`three_score` 做
  rubric 权重 + 惩罚 + caps，输出 improvement list；最佳轮交付。
* **工具面**：`three_list / create / read / patch / verify / inspect` 保留；
  新增 `three_plan_validate / build / check / measure / render_views / scene_probe /
  check_placement / shader_probe / judge / score`（命名实现时定）。
* **能力分批**：图元（box/sphere/cylinder/cone/torus/plane/lathe）→ 变换/复制/父级 →
  材质 PBR 参数 → 布尔（three-bvh-csg vendored，拉伸）；3dcodeverse 的 plan/check/
  judge 从第一批就接入，不等几何能力全齐。

### 4.1 候选引擎与材质边界（2026-11-24 调研，未施工）

2026-11-24 评估了两个仓库，结论**均不直接引入**；3D 执行面仍是 three-live +
3dcodeverse：

| 候选 | 能补什么 | 裁决 | 原因 |
| --- | --- | --- | --- |
| `shinyobjectz/raea` | Bevy 3D、composition/帧模型、story model、短剧 `cut` / `check` P0–P3 | **只参考（2026-11-24 用户最终裁决）** | FSL-1.1-ALv2 的 *Competing Use* + 230 crate 完整应用/无公开库 ABI，不适合引入；3D 视频执行面仍用 three-live，只借 composition/词级时间/check/story 契约 |
| `alla2001/material-painter` | PBR 纹理绘制、烘焙、材质节点图、WGSL 节点、引擎导出预设 | **只参考；可选外部 MCP 工作站待裁决** | GPL-3.0-or-later + 仅 GUI 二进制、无 `[lib]`；嵌入/链接会触发 copyleft。独立进程 MCP 不 vendor 代码，但属于外部工具例外 |

* **raea 只借契约（2026-11-24 用户最终裁决：不引入）**：3D 视频执行面仍用现有
  three-live；只借词级时间、`check` 输入面、typed story（world/telling/beat、
  value turns、setup/payoff）与 composition/帧模型思路，不引 React/Bevy/JS 整仓、
  不复制 skills/代码/资产。见 [research/raea.md](research/raea.md) 与
  [plan-next-iterations.md](plan-next-iterations.md)。
* **Material Painter 只借需求**：八通道模型、bake map 分类、导出通道打包、
  层栈/智能遮罩 UX、MCP 安全模式（loopback/默认关闭/503/Origin allowlist）。
  v1 材质自建 `nan.material/1`（baseColor/metallic/roughness/normal/emissive/
  occlusion/alpha + 贴图槽 + HDRI + glTF ORM），**不做绘制/UV 展开/烘焙**；
  可选外部工作站必须用户自行安装、显式开启、失败诚实降级，不随包分发。
* **政策**：外部创作工具仍「只参考、不引入」；3D 栈例外仅限 three.js /
  three-live / 3dcodeverse。Material Painter 的外部 MCP 桥是**新增例外候选**，
  未获用户裁决前不施工。

详见 [research/3dcodeverse.md](research/3dcodeverse.md)、
[research/raea.md](research/raea.md)、
[research/material-painter.md](research/material-painter.md) 与
[skills/creative-workbench/references/3d-pipeline.md](skills/creative-workbench/references/3d-pipeline.md)。

## 5. 视频：导演台 + 剧本标准 + 三风格 + TTS + 配乐联动

> **双轨口径（2026-11-24 用户最终裁决）**：视频拆为 **常规视频**（保持现有 v1 表面与
> 本节目标态；不迁移底座）与 **3D 视频**（执行面用现有 **three-live**；只借鉴
> raea/story-short 等契约与工艺，不引入新引擎）。本节 Phaser/三风格/TTS/VFX 等
> 属于常规视频方案线，不自动套到 3D 视频轨；排期与设计门见
> [plan-next-iterations.md](plan-next-iterations.md)。

### 5.0 引擎选型：Phaser 4.x（2026-11-20 裁决「引入游戏引擎」，2026-11-28 版本升级为 4.x）

**结论**：引入 **Phaser 4.x**（MIT，单文件可 vendored，WebGL/Canvas 双渲染面；2026-11-28 用户裁决把版本从 3.x 升级到 4.x）作为「引擎短片」的
2D 游戏引擎运行时；沿用现有沙箱——自包含 HTML + `file://` WebView + `VideoClipBridge` 桥，零外联。

**候选对比（为什么不选别的）**：

| 候选 | 结论 | 理由 |
| --- | --- | --- |
| Phaser 4 | ✅ 采用 | 完整 2D 引擎：Scene / Tween / Timeline / Arcade+Matter 物理 / 粒子 / 相机（闪白、震屏、变焦）/ 遮罩 / 滤镜 / 声音；单文件约 1.2MB 可 vendored；有 HEADLESS 模式可做确定性自检；与 `assets/video/clip/` 沙箱同构 |
| PixiJS 8 | ❌ | 只是渲染器：tween / 物理 / 场景 / 时间线全部要自建，等于自造半个引擎 |
| Godot 4 web export | ❌ | 单项目 wasm+pck ≥ 20–40MB；`file://` 下 fetch/wasm MIME 与 COOP/COEP 线程限制，需要本地 HTTP 服务（违背零端口纪律）；构建 pck 需要 Godot 工具链（违背零外部工具链纪律） |
| Unity WebGL | ❌ | 许可、体积、加载器三面全不可行 |
| Flame（Flutter 原生） | ❌（备选记录） | 预览可原生渲染且理论上能逐帧截图，但产物不再是可脱离 NaN 打开的自包含 HTML，引擎生态也小一个量级 |
| 自写 Canvas/DOM（现状 `ND.scene`） | 保留 | 已发布样片与 science / screenplay v1 规范不动，作为轻量渲染面并存（三渲染面：矢量算式动画 / DOM 动效合成 / 引擎短片） |

**架构（引擎短片 = 编译产物，不是手写 Phaser 代码）**：

* 事实源仍是 `screenplay.json`（§5.1）；**Agent 只写 JSON，不写 Phaser 代码**——确定性、可校验、可回放。
* 编译器 `assembleEnginePlayer(screenplay, stylePack)` → 单文件 HTML：内嵌 `phaser.min.js` +
  场景解释器 `nd-stage.js` + screenplay 字面量 + 风格包（全部代码绘制，零图片资源）。
* 解释器把剧本编译成 Phaser Scene：shot = 时间线段；台词 = 字幕/气泡；动作 = 预设 tween 组；
  转场 = 相机/遮罩；角色 = 矢量绘制（Graphics → RenderTexture 缓存）。
* 运行时**固定步进 30fps**；`seek(t)` = 重置场景 + 按 1/30s 步进重放 `t×30` 帧（≤3 分钟片子
  5400 步，可接受）——任意时刻回放同一帧；随机数一律种子化（`seed` 字段），不用 wall clock。
* 桥扩展（`VideoClipBridge` v2，向后兼容 v1）：`ready/state` 照旧，新增 `shot`（当前镜头
  id/进度）、`markers`（自检结果）、`audio`（beat/ended，配乐联动用）。
* 播放控制 `window.__ndClip` 命令面不变（play/pause/seek/restart/setLoop），
  Dart 侧 `VideoClipWebPlayback` 不改。
* vendoring：`app/assets/video/engine/phaser.min.js` + `manifest.json`（版本 + SHA256 + 字节数，
  沿用 `three.module.js` / wasm_run 纪律）；`docs/video-engine-contract.md` 记录版本、升级流程、
  桥契约、解释器 schema 映射。
* 验证：Dart 侧 `verifyScreenplay`（schema）+ 页面内 `?verify=1` 自检（逐镜头步进，检查台词出场、
  转场触发、时长和，经 `markers` 回传）——「机械对照」升级为引擎实测。
* 平台：应用内 WebView 已统一到 `webview_all`（macOS/iOS WKWebView、Windows
  WebView2、Linux WebKitGTK、Android WebView），视频播放面与 3D/热应用同一条
  `WebViewController` 路径，不再有 Windows 专属分支。见
  [plan-cross-platform-runtime.md](plan-cross-platform-runtime.md) §1。

> **版本研究回填（2026-11-20）**：Phaser 4.2.1 已是当前主线（WebGL1 基线、Stencil/Mesh2D），
> Phaser 3.90 是 v3 最后版本。本项目只用 Sprite/Container/Camera/Text/Mask，迁移面小；
> 施工时在 **4.2.1 / 3.90 中锁定一个版本**（建议 4.2.1，3.90 作老 WebGL 降级），不要浮动升级。
> 角色/关键帧/确定性/资产预算的完整工艺见
> [research/video-animation-howto.md](research/video-animation-howto.md)。
>
> **OpenMotion / HyperFrames 对照调研（2026-11-21，用户裁决）**：两者都是
> Apache-2.0 的“HTML-as-video”工具，但**只参考、不引入**——不做依赖、不内置
> 进程、不套壳、不设导出适配器；只借 Motion.md/版本/导出纪律。3D 栈
> （three.js / three-live / Babylon.js）是明确例外；本方案 **Phaser 4 裁决**（2026-11-28 版本升级）。
> 完整结论见 [research/openmotion-hyperframes.md](research/openmotion-hyperframes.md)。
>
> **`ink_line` 的渲染分支（2026-11-22）**：墨线手绘是第三种风格包，不走 Phaser
> 的 cutout 图集，**方案是**同一 `screenplay.json` 编译器下的自研 Canvas2D 矢量笔触
> 后端（固定 30fps、几何抖动、纸面遮挡，I0 spike 验证）；不引入
> `JDhruv14/line-art-animation` 的 TypeScript/SVG 库。`silly_skit` / `line_toon`
> 仍走 Phaser 3。详见 [research/line-art-animation.md](research/line-art-animation.md)。

### 5.1 剧本标准（新契约文档 `docs/video-screenplay-contract.md`）

`screenplay.json`（`v:1`）：幕 → 场 → 镜头（`id`、场景、镜头语言、时长、台词
`[{role, text, tts}]`、动作、**VFX 事件** `[{f,type:"vfx",cue,...}]`、转场）。剧本是
创作面**事实源**；既有 timeline/spec 由编译产生（保持播放器与机械对照兼容）。
动画短剧候选线另带 `words.json`（词级 start/end）作为时间主轴，视觉反应对齐到词前
0–3 帧（见 §5.3 `toon_3d` 候选）。

### 5.2 导演台（工作区形态）

剧本树 ｜ 分镜时间线（镜头条）｜ 镜头审查卡（对照检查）+ 配音轨 + 配乐轨 ｜
成片预览。四区与右侧 chat 分工同 §2。

### 5.3 三风格场景包（解释器插件，全部代码绘制）

| 风格 | 内容 |
| --- | --- |
| `silly_skit` 沙雕短剧 | 几何/简笔角色库 + 夸张弹跳运动预设（outBack/spring 参数族）+ 大字幕梗卡规范 + 点音效组 + **pixelfx 战斗/环境特效子集**（火焰/冰霜/风/爆炸等，不含人物） |
| `line_toon` 美式线条漫画 | 单线条人物 + 对话气泡 + 分格转场（panel wipe，相机遮罩实现）+ 滑稽物理预设 |
| `ink_line` 墨线手绘 | 细抖墨线 + 暖纸底 + 无脸小人 + 开放双笔触四肢 + 纸面遮挡 + 1–2 点缀色 + 昼夜反转；步态用求解器（站立脚/最小 jerk 摆动/脚跟离地/髋高反解），服装绕骨架绘制；Canvas2D 矢量笔触渲染 |

风格包 = 角色库（`silly_skit`/`line_toon` 用 Phaser Graphics 程序化绘制；
`ink_line` 用 `ink_figure` 骨架 + 服装/发型/道具路径）+ 运动/转场预设 + 字幕规范 +
音效组；解释器按 `screenplay.style` 选择，确定性、零外联、零图片资源。默认风格
（`default`）保留。

`ink_line` 的「角色库」不是 cutout 图集：它需要两骨 IK、开放双笔触肢体、纸色遮挡和
衣摆绕膝，图集化会把风格签名磨掉。渲染**建议**走自研 Canvas2D 矢量笔触（固定 30fps、
整数帧、种子化几何抖动，I0 spike 验证），**不引入 line-art-animation 的 TypeScript/SVG
库**；若移动端 1080p30 实测不达标，再评估预烘焙笔触图集回退。

**VFX 层（2026-11-22 用户裁决）**：`silly_skit` 直接引入 **pixelfx 特效子集**
（MIT；火焰/冰霜/风/爆炸/闪电/烟尘/水花等），只取**特效**，不取人物：
`actor.js`/`rig.js`/`poses.js`/`act.js`/`moves/` 与所有 `meta.actor`/`o.actor`/
on-body 特效一律不引入；角色仍由我们的 cutout/rig 负责。VFX 是
`screenplay.json` 的一等事件（`{f,type:"vfx",cue,x,y,seed,palette,layer}`），cue
必须在 allowlist 内；固定 30fps、双缓冲（color+light）、最近邻放大。`line_toon`
只在刻意的像素特效层用；`ink_line` 默认不用（1px 像素光与细墨线语法冲突）。
详见 [research/pixelfx.md](research/pixelfx.md)。

**候选风格 `toon_3d`（2D 角色 + 3D 世界，2026-11-24 调研，待裁决）**：参考
`mromidev/claude-animated-shorts` 的 55–70s 竖屏动画短剧流水线——8 段脚本、
词级时间、镜头表、2D billboard 角色 + three.js 手绘世界、墨线/景深/滑翔相机、
合成声音与逐帧 QA。**只借工艺与 look 数值**；不引入 Remotion/React/Node/Chromium
运行时，不复制参考帧/角色/脚本/镜头。执行面用 three-live；详见
[research/claude-animated-shorts.md](research/claude-animated-shorts.md) 与
[skills/creative-workbench/references/story-short.md](skills/creative-workbench/references/story-short.md)。
本候选**不改变当前三风格定稿口径**，是否进入正式 style pack 待裁决。

### 5.4 TTS（离线，含许可红线）

主路径：**sherpa-onnx（Apache-2.0）+ 许可清晰的中文模型**（Matcha zh-baker 约 73MB / Kokoro int8），
Dart FFI 五端统一；句级真实时长 + 字级估算回写镜头时长；台词编辑在导演台；**不做云 TTS**。
OS 系统音色（macOS `say` / Windows SAPI / iOS AVSpeech / Android TTS）只做**草稿预览**——
Apple macOS SLA 把 System Voices 限定为个人非商业用途，禁止录制/公开分享/商业再分发。
详见 [research/video-animation-howto.md](research/video-animation-howto.md) §5。

### 5.5 音乐联动（新裁决，第二条跨模块通道）

video 项目 `musicRef` 指向音乐项目；播放经桥接共享时钟同步，导出时混入配乐（拉伸）。
校验：`musicRef` 存在且该谱面校验通过。

### 5.6 工具面与校验器

`video_list / create / read / patch / verify / inspect` + 既有 `video_review`；
TTS 渲染 `video_tts_render`；联动 `video_link_music`。校验器：镜头时长 > 0、台词非空、
tts 行与台词一一对应、`musicRef` 合法、风格包在场；`ink_line` 另查站立脚漂移
（< 0.5px/帧）、开放双笔触四肢、昼夜对比度与灯光错峰。`verify` 双档：Dart schema
校验 + 播放页 `?verify=1` 引擎自检（`markers` 回传）；`video_review` 保留为人工审查面。

**VFX 校验**：`cue` 在 pixelfx allowlist、无 `actor`/`onBody`/`moves`、同 seed
同帧同像素、不出画布、一次性结束为空/循环无缝、palette 白名单、单帧预算。
allowlist 由 vendoring 时扫描生成并写入 `manifest.json`，视频编译器只认清单。

## 6. 音乐：编曲工作台（承接 plan-music-module.md）

工作台双面按 §1.2；配乐联动侧：音乐模块提供「播放 / 导出音频」能力给视频（共享时钟
/ 离线混音）；音频 per-track bounce 列入拉伸。

## 7. 施工分批（每批可独立验收）

| 批次 | 内容 | 验收 |
| --- | --- | --- |
| 0 | 「创意工作台」定位文案全落面（README / site / AGENTS / 主页副标题含音乐） | copy_guard 绿 |
| 1 | 强规范框架：四份契约文档矩阵 + 契约测试模板 | 模板测试全绿 |
| 1b | 标准化 `creative-workbench` skill：`SKILL.md` + 六份 references + spec/plan/gates/judge schema | 文档对照 + 样例 roundtrip |
| 2 | 全局执行/结果双面组件（进度线 + 产物卡），四工作台接入骨架 | 双面组件测试 |
| 3 | 设计：验证原型绑定原型 + `design_verify_prototype` 收口 + 迁移过滤 | §3 验收清单 |
| 4 | 3D：3dcodeverse plan/gates/judge + three-live 双 authoring 模式 + 建模视口（大纲/检查器/gizmo 桥） | §4 校验器 + 视口测试 |
| 5a | 视频引擎接入：Phaser vendored（manifest/SHA256）+ 解释器 + `assembleEnginePlayer` + 桥 v2 + 既有样片回归 | 引擎短片单测：字节确定性 / seek 重放同帧 / 桥 v2 兼容 v1 |
| 5b | 视频：剧本标准 + 导演台 + 三风格包 + TTS | §5 契约测试 + `?verify=1` 自检全绿 |
| 5c | 视频 VFX：pixelfx 过滤子集 + allowlist + VFX 事件 + color/light 合成 + 性能门 | allowlist/确定性/越界/循环/合成测试 |
| 6 | 音乐：按 plan-music-module 批次 1–4 | 该文档验收 |
| 7 | 视频 ↔ 音乐配乐联动 | 共享时钟/`musicRef` 校验 |
| 8（拉伸） | CSG、音频导出、MIDI、音乐局域网分享、Windows WebView2 接线 | 另立裁决 |

## 8. 明确不做 / 待裁决

* 云 TTS、采样音源、实时协作、出版级排版：不做。
* 热应用嵌音乐播放器（新跨模块联动）、验证原型是否允许独立导出包：**待裁决**，默认不做。
* 3D 布尔/曲线编辑、视频导出成片、articulated（URDF/Blender）轨：拉伸/backlog。
* **3dcodeverse 的运行时边界**：不引入 Python CLI / Blender / CadQuery / URDF /
  moderngl 到产品进程；只采用其 skill/harness 契约与阈值，检查器用 Dart/JS 实现。
  3DCodeVerse-2M 数据集（CC-BY-NC-SA）不随产品分发。
* **pixelfx 的人物边界**：只引入特效，不引入 stock character / `actor` / `rig` /
  `poses` / `act` / `moves` / on-body 特效；角色由我们自己的 rig 负责。
* **awesome-opus5-5-videos 只借结构**：不复制创作者作品、角色、品牌、成段 prompt，
  不接入 Skillry 服务；六段 prompt 结构进 `creative-workbench` skill。
* **claude-animated-shorts / Remotion 只参考**：不引入 Remotion / `@remotion/three` /
  React / Node / Chromium / ffmpeg 运行时；不复制参考帧/角色/脚本/镜头/配音/音乐。
  只借 8 段脚本、词级时间、镜头语法、look 数值与 QA 逻辑；`toon_3d` 为候选风格，
  待裁决与 spike（见 [research/claude-animated-shorts.md](research/claude-animated-shorts.md)）。
* **raea 不引入（2026-11-24 用户最终裁决）**：不 vendor 代码/TS SDK/skills/资产、
  不嵌入库、不引 React/Bevy/JS/Bun/CMake 整仓、不把 CLI 作为产品依赖或捆绑进程；
  3D 视频执行面仍用 three-live，只借鉴其契约与工艺
  （见 [research/raea.md](research/raea.md) 与 [plan-next-iterations.md](plan-next-iterations.md)）。
* **Material Painter 不嵌入**：GPL-3.0-or-later + GUI-only 二进制、无库 API；不 vendor、
  不随包分发、不复制源码。v1 材质自建 PBR 层；可选外部 MCP 工作站是**未裁决**的
  例外候选（见 [research/material-painter.md](research/material-painter.md)）。
* Godot / Unity / PixiJS / Flame 已裁决不采用（理由见 §5.0）；引擎短片 v1 **只走剧本解释器**，
  不允许 Agent 手写 Phaser 代码（保确定性与可校验性）。
* `ink_line` 的参考源是 `JDhruv14/line-art-animation`（MIT），但**不复制其代码、不依赖
  其 TypeScript/SVG 运行时**；只借风格参数、步态求解规则与验收方法（见
  [research/line-art-animation.md](research/line-art-animation.md)）。
