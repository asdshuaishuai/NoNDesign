# 3DCodeVerse 调研：代码即真相的 3D 生成 / 验证 harness

> 状态：**调研结论（2026-11-22）**，供 3D 工作台与 `creative-workbench` skill 使用。
> 论文、项目页、仓库与 harness 源码均已读；**未安装/未运行其 Python CLI**。
>
> 用户裁决（2026-11-22）：**threejs-live 与 3dcodeverse 直接引入我们的项目**；
> 本文把「直接引入什么、不引入什么、怎么落到现有架构」写清楚。3D 栈是
> 「只参考、不引入」规则的明确例外。
>
> 关联：[plan-creative-workbench.md](../plan-creative-workbench.md) §4 ·
> [plan-plugins.md](../plan-plugins.md) C 节 ·
> [three-live-sandbox.md](../three-live-sandbox.md) ·
> [skills/creative-workbench/SKILL.md](../skills/creative-workbench/SKILL.md)。

## 0. 结论先行

1. **它是什么**：3DCodeVerse 是「把 3D 世界写成可执行代码」的研究生态——数据集
   （3DCodeVerse-2M）+ 多智能体 harness + 开放模型基线。论文 arXiv 2610.22341
   （2026-10-15），代码 Apache-2.0，仓库约 **413 stars / 34 forks**（2026-11-22）。
2. **核心主张**：3D 内容不是生成一张图/一个 mesh，而是生成**可运行、可编辑、
   可测量、可验证的代码**。几何、材质、运动、相机都在源码里；GLB/PNG/URDF 都是
   派生物。代码是唯一事实源。
3. ** harness 的价值**：把「生成 3D」拆成
   `plan → validate → build → check（确定性门）→ judge（盲评）→ refine → 选最佳轮`；
   执行日志、空间测量、视觉判断三路反馈；门错误会 cap 分数，视觉判断不能覆盖
   确定性事实。论文报告：同一 Claude Opus 5.5 下，对 Claude Design 的 3D 对象
   人偏好胜率 **90%**；fine-tuned 27B 的 3DCodeBench 执行率 **51.9% → 92.9%**。
4. **为什么适合我们**：我们的 3D 工作台已经是 three.js + three-live 沙箱；
   缺的正是 3DCodeVerse 的「计划数字 → 确定性门 → 盲评 → 定向修复」这一层。
   它能把「模型说做完了」变成「测量/渲染/评分证明做完了」。
5. **直接引入的边界**：直接引入其 **skill/harness 契约**（Apache-2.0 的技能文档、
   plan schema、门阈值、judge rubric、工作区布局），在 three-live 执行面上用
   Dart/JS 实现等价 instruments；**不把 Python CLI / Blender / CadQuery / URDF
   运行时塞进产品进程**（违反「无 Python 服务、纯 Dart 核心」架构）。数据集
   CC-BY-NC-SA，不随产品分发。

## 1. 事实与数据

| 项 | 事实 |
| --- | --- |
| 论文 | [arXiv 2610.22341](https://arxiv.org/abs/2610.22341)，Submitted 2026-10-15 |
| 项目页 | <https://3dcodeverse.com/> |
| 仓库 | <https://github.com/gaoypeng/3dcodeverse>，Apache-2.0，Python 主语言 |
| 规模 | 3DCodeVerse-2M：**2,028,286** 行统一文本（342 shards）/ **269,597** 个可执行程序 / **768,596** 个去重 prompt–code 对 |
| 主要子集 | DeepCAD→CadQuery 128,201；Shadertoy GLSL 119,961；Articraft 6,882；URDF 6,146；Bioinspired3D 6,343；Thingiverse OpenSCAD 1,193；3DCodeBench 486；另有 agent 写的 Blender/Three.js |
| 运行形态 | Claude Code / Codex / Antigravity 插件；`3dcode` CLI；Python 3.13、node ≥20.6、Blender 5.2 LTS（仅 blender 轨） |
| 四轨 | `static_object` · `articulated_object` · `scene` · `graphics` |
| 七运行时 | bpy、CadQuery、Three.js、URDF+Blender、scene_threejs、GLSL、moderngl（OpenGL Python） |
| 结果 | 3D 对象人偏好 69–89%（vs 原生 harness）；对 Claude Design **90%**；四轨相对 one-shot 提升 15.5–29.1 分；fine-tuned 27B 执行率 92.9% |
| 许可 | 代码 Apache-2.0；数据集 CC-BY-NC-SA（**非商业**，不得随产品分发） |

## 2. 十条设计法（直接可抄进我们的规范）

`harness/docs/ARCHITECTURE.md` §1 的 laws，逐条映射到我们：

1. **代码是真相，产物是派生物**：`src/` 是交付物；GLB/PNG/URDF 可重建；每轮是
   `src/` 的 git commit + `rNN` tag。→ 我们的 3D 项目必须以源码为主，`scene.json`
   只能是投影/中间表示（见 §6 的冲突解决）。
2. **给要求，不给模板**：技能只写「必须为真、在哪里、怎么测」的接口/沙箱/阈值，
   不强制 brief 没要求的形状；每种语言只给一个可执行接口示例，围栏 ≤12 行。
3. **代码能回答的交给代码**：确定性门/测量用代码跑；模型只负责感知与判断；
   分数由 rubric 权重、惩罚、floor、cap 算出。
4. **把责任移出 Agent 代码**：导出 wrapper、相机 rig、placement 校验、URDF 组合
   数学、场景装配、GLSL header 是工具的事，不是模型每次重写。
5. **证据式验收**：plan 带 acceptance checklist；judge 逐项从渲染/测量回答。
6. **全类型化**：一个 contracts 包；不用正则解析 id 做控制流；不允许 god file。
7. **便宜的先跑**：lint → build → gates → montage → judge。
8. **生成者与评审者分离**：judge 只看 `brief.md` + 图片，不看代码/推理。
9. **按作者坐标导出**：wrapper 不重新居中/落地；门测量 Agent 放的位置，并打印
   修复所需翻译量。
10. **每条规则只在一处**：流程/措辞在 skill；代码测量的数字写在 Agent 读到的
    地方，用门的原话。

## 3. 四轨与运行时

| 轨 | 是什么 | 语言（默认在前） | 交付物 |
| --- | --- | --- | --- |
| `static_object` | 不动的物体：家具、工具、道具、静止车辆 | `blender` / `cadquery` / `threejs` | 代码 + `object.glb`（+ stl/step） |
| `articulated_object` | 会动的机构：门、抽屉、轮、连杆、机器人 | `urdf_blender` | 代码 + `robot.urdf` + `meshes/*.glb` + `object.glb` |
| `scene` | 一个地方：地形/房间、天空与光、大量摆放物、作者相机、运动 | `scene_threejs` / `scene_blender` | `src/**` + `public/assets/*.glb` + renders + probes |
| `graphics` | 动画图像：fragment shader / moderngl | `glsl_shader` / `opengl_python` | 源码 + 判分帧 + sheet + GIF + 帧指标 |

**我们的 v1 映射**：

- `static_object`（threejs）→ 直接做；three-live 执行 + GLB 导出。
- `scene`（scene_threejs）→ 直接做；这是 3D 工作台的主力（世界/房间/街道）。
- `graphics`（glsl_shader）→ 做；three-live 里的 ShaderMaterial / 全屏 shader。
- `articulated_object`（URDF/Blender）→ **backlog**；我们不在产品内跑 Blender，
  关节机构可先用 three.js 的 Group 层级 + 自定义 joint 检查近似，完整 URDF
  等桌面 sidecar 或未来能力再评估。

## 4. 工作区与循环（直接采用）

```
spec.json     请求：track, language, prompt, must_have, must_not, dims, references
plan.json     计划：精确数字、部件/尺寸/材质/运动/验收清单
src/          原始代码（scene 轨还有 public/ 编译资产）
artifacts/    工具输出：object.glb、renders/、gates.json、measurement.json（只读）
judge/rNN/    brief.md + montages + judgment.json + score.json
```

循环：

1. **Plan**：先写 `plan.json`，精确数字 + acceptance；对象 plan <5KB。
2. **Validate**：`validate-plan` 通过 schema + 计划检查；FAIL 给 JSON path；
   不要和验证器争论。
3. **Baseline（r00）**：按 plan 写代码；最多三步写完所有文件（entry 最后）；
   跑 `check`，逐个清 ERROR；对象先全件粗坯再细节；禁止用非均匀缩放把成品
   塞进 plan box。
4. **Judge（用户要求评分/refine 时）**：`judge --round N` 提交/打 tag/打包；
   把 `JUDGE INSTRUCTION:` 原样交给**全新上下文**的 `3d-judge`；它只看
   `brief.md` + 图片，写 `judgment.json`；`score` 做 rubric 算术。
5. **Refine（轮数由用户定）**：只做 score 的 improvement list；gate ERROR 优先；
   一次只改被点名的部分；重复的测量问题要换一种改法，不是重复同一编辑。
6. **Stop**：用户要求的轮数完成 / score 通过且清单空 / 连续两轮总分下降；
   交付最佳轮（不是最后一轮），`checkout rNN -- src` 后补一次 `check`。

**轮数纪律**：默认一轮；judge/refine 只在用户明确要求时跑；不做「自我抛光」。
这正好匹配我们「用户点一次生成，先交付可验收的一轮」的产品节奏。

## 5. 确定性门、盲评与评分

### 5.1 门的种类

| 轨 | 门 |
| --- | --- |
| 对象 | lint；contract（每个 part/整体 bbox 在 max(10mm,10%) 内，ground 10/30mm，footprint 居中，placeholder part）；connectivity（接触 ≤2mm，穿插 >2mm WARN / >10mm ERROR，漂浮 ERROR，孤岛 <5% WARN）；detail budget；fixed parts |
| 关节 | 上述 + FK、rest penetration、joint sweep、motion direction |
| 场景 | scene placement、scene probe（census/budget/world/atmosphere/drivers）、shader preflight、scene frames（exposure/camera/content）、frame motion、hero unseen |
| 图形 | lint；gl frames（NaN/black/blown/static/flicker/low detail） |

### 5.2 盲评

- `judge-pack` 渲判分视角（对象 14 视角 + 细节/接触 crop；关节加 pose sheet；
  场景每个作者相机 t=0/1.5s + orbit；图形 frame sheet），拼带标签的 2×2 montage，
  写 `brief.md`：请求、plan 摘要、acceptance、测量/门事实、rubric 标准与锚点、
  缺陷清单、**judge 必须返回的精确 JSON**。
- judge 只看这个文件夹；不看生成者代码/推理；不自行给总分。
- `score` 解析 judgment，修 trivial deviation 并说明；按权重/惩罚/floor，再套
  `gates.json` 的 cap（build error 0；floating 0.60；penetration 0.70；contract
  violation 0.75；未满足 must 0.60/0.70；各轨测量 cap）。
- 生成者与评审者分离，是为了防止「模型给自己打高分」；我们产品里也必须用
  **独立的 judge 上下文**，不能在同一轮对话里自评。

### 5.3 对我们最有用的三条

1. **门优先于视觉**：视觉说「看起来对」不能推翻 bbox/contact/grounding 的 ERROR。
2. **修复要带数字**：不是「把腿调一下」，而是「沿 (0,0,−0.012)m 平移」；
   我们的错误信封必须带可执行的 fix hint。
3. **最佳轮交付**：不是最后一轮；保留每轮 commit/tag，便于回退和对比。

## 6. 与现有 `scene.json` 的冲突与解决（关键）

现有 3D 方案（[plan-creative-workbench.md](../plan-creative-workbench.md) §4）把
`scene.json` 当事实源：`nodes[{id, primitive, params, transform, material, parent}]`，
编辑器改 JSON。3DCodeVerse 的 law #1 是 **code is truth**。两者不能同时是唯一真相。

**建议的 spec 决议：双 authoring 模式，同一渲染/验证面。**

| 模式 | 事实源 | 适用 | 编辑器 |
| --- | --- | --- | --- |
| `scene` | `scene.json` | 手工建模、图元/变换/材质、轻量场景 | 大纲/视口/检查器直接改 JSON；编译成 `src/scene.js` 预览/导出 |
| `code` | `src/*.js` | Agent 生成、3dcodeverse harness、复杂世界/shader | 源码为主；检查器读派生 scene graph，编辑走受控 patch；禁止整文件重写 |

- 新项目：手工「新建空场景」默认 `scene`；一句话生成/3dcodeverse 路径默认 `code`。
- `scene` 模式仍可跑 3dcodeverse 的确定性门（把 JSON 编译成代码后测）；
  `code` 模式的 `scene.json` 是**派生投影**，只读或有限编辑。
- 两种模式共用 three-live 执行面、同一套 gate/judge、同一套 artifacts 布局。
- 这是对现有 §4 的修订：`scene.json` 不再是所有 3D 项目的唯一事实源；它仍是
  `scene` 模式的事实源。若不接受双模式，就必须二选一：要么放弃手工图元编辑，
  要么放弃 3dcodeverse 的 code-first harness。本文建议双模式。

## 7. 直接引入清单（用户裁决）

### 7.1 直接引入

- **threejs-live 1.4.0**：已在库（`app/assets/three/vendor/three-live.min.js`），
  继续作为 3D 沙箱执行面；不改沙箱边界/CSP。
- **3dcodeverse 的 skill 层**（Apache-2.0）：vendor/改写
  `harness/skills/3dcodeverse/SKILL.md`（控制器）、`3d-lang-threejs`、
  `3d-lang-scene-threejs`，以及按需的 `c3d-*` craft bundles（part-contact、
  bbox-contract、scene-lighting、scene-placement、scene-atmosphere 等）。
  适配点：`3dcode <cmd>` → 我们的 `three_*` 工具；`--workspace` → 项目目录；
  `spec.json/plan.json/src/artifacts/judge` 布局保留。随包保留 Apache-2.0
  LICENSE/NOTICE 与来源 commit。
- **3dcodeverse 的 harness 契约**：plan schema（parts/dims/materials/acceptance）、
  门阈值、judge brief/JSON、score caps、最佳轮交付。用 Dart/JS 实现 instruments：
  `validate_plan`、`build`、`check`、`measure`、`render_views`、`scene_probe`、
  `check_placement`、`shader_probe`、`judge`、`score`。
- **3dcodeverse 的 judge rubric**：按轨选 `static_object`/`scene`/`shader`/
  `reference` 的权重与 cap；先做静态对象 + 场景两套。
- **开发期对拍**：允许在开发机 clone 上游仓库并运行 `3dcode` CLI/harness，作为
  我们 Dart/JS 检查器的参考实现与阈值对拍；它**不随 App 分发、不成为运行时依赖**。

### 7.2 不直接引入

- Python CLI / `codeverse3d` 包作为产品运行时（架构禁止 Python 服务/子进程）。
  它只作为**离线参考实现**；需要时在开发机跑，不随 App 分发。
- Blender、CadQuery、URDF、moderngl 运行时（v1 不做；articulated 轨 backlog）。
- 3DCodeVerse-2M 数据集（CC-BY-NC-SA 非商业，不得随产品分发；若未来用于训练，
  单独做法务/许可评估）。
- 其示例资产、prompt、渲染图（只作研究参考，不复制）。

### 7.3 落地形态

```
3D 项目/
  spec.json          # track/language/prompt/must/dims/references
  plan.json          # 精确数字 + acceptance
  src/               # code 模式事实源（scene 模式由 scene.json 编译）
  scene.json         # scene 模式事实源 / code 模式派生投影
  artifacts/         # object.glb, renders/, gates.json, measurement.json
  judge/rNN/         # brief.md, montages, judgment.json, score.json
```

`three_*` 工具面扩展（名称待实现时定）：

| 工具 | 作用 |
| --- | --- |
| `three_plan_validate` | 校验 `plan.json`（schema + 数字/验收） |
| `three_build` | 编译/导出 GLB，跑 lint |
| `three_check` | 全部门 + `gates.json`，返回 PASS/FAIL/ERROR + fix hint |
| `three_measure` | bbox/ground/part size/tris |
| `three_render_views` | 多视角/线框/法线/轮廓/clay + contact sheet |
| `three_scene_probe` | census/draw calls/triangles/console errors/atmosphere |
| `three_check_placement` | 漂浮/埋入/无支撑/穿插 + 移动米数 |
| `three_shader_probe` | 编译所有 ShaderMaterial，带行号 |
| `three_judge` | 打包 brief + montage，交独立 judge 上下文 |
| `three_score` | rubric 算术 + caps + improvement list |

## 8. 与 `creative-workbench` skill 的关系

3DCodeVerse 是 3D 线的**验证式骨架**；`creative-workbench` 是跨视频/3D/设计的
**统一 intake/plan/build/judge/deliver 外壳**。两者合并方式：

- `creative-workbench` 的 Stage 2 对 3D 请求调用 3dcodeverse 的 `plan` 模板；
- Stage 3 用 three-live 执行 `src/`；Stage 4 跑 3dcodeverse 的门；
- Stage 5 用 blind judge；Stage 6 只改 score 列出的项；
- 视频线复用同一 judge/score 语法，但门换成帧时钟/循环/节拍/字幕安全区。

## 9. 未验证 / 待补

- 未安装/运行 3dcodeverse 的 Python CLI；阈值与门行为来自源码/文档，不是我们的
  实测；首次接入必须用一个小对象 + 一个场景做真机对拍。
- 未验证 three-live 沙箱能否承载 3dcodeverse 的 scene_threejs starter（模块/
  import map/多文件）；需要 spike。
- 未验证 14 视角渲染在 WKWebView/WebView2 的耗时与内存；移动端可能只跑 4–6 视角。
- 未决定 articulated 轨是否值得做；URDF/Blender 与我们的纯 Dart/three-live 架构
  距离较远。
- 未核验 rubric 权重/阈值在中文 brief 上的校准；需要 A/B。
- 数据集许可（CC-BY-NC-SA）与商用边界未做正式法务评估。

## 10. 来源

- 论文：<https://arxiv.org/abs/2610.22341> · <https://arxiv.org/html/2610.22341v1>
- 项目页：<https://3dcodeverse.com/>
- 仓库：<https://github.com/gaoypeng/3dcodeverse>
- `README.md`、`harness/README.md`、`harness/docs/ARCHITECTURE.md`、
  `harness/skills/3dcodeverse/SKILL.md`、`harness/agents/3d-judge.md`
- 数据集：<https://huggingface.co/datasets/3dcodeverse/3dcodeverse-2m>
- GitHub metadata（2026-11-22 核验）
