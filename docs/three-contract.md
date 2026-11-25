# 3D 模块契约（three-live + 3dcodeverse harness）

> 状态：**R3 契约面 + 检查器属性编辑已落地（2026-11-24/25）· 建模视口/gizmo/GLB/多视角/judge/图形门待后续**。已落地：v2 工作区
> （spec/plan/src/artifacts + 旧布局只读迁移）、plan 追加校验、对象确定性门纯函数、
> `three_workspace_migrate` / `three_plan_validate` / `three_measure` / `three_build` / `three_check` /
> `three_check_placement` 工具；
> 预览页 per-part 测量桥（artifacts/measurement.json）；scene.json 确定性编译；3D 双面阶段线/结果卡。契约增量：
> 轨道、双 authoring、工作区、plan schema、确定性门阈值、盲评、工具面、许可与迁移。
>
> 相关：[plan-creative-workbench.md](plan-creative-workbench.md) §4（方案事实源）·
> [three-live-sandbox.md](three-live-sandbox.md)（执行面现状）·
> [3d-pipeline.md](skills/creative-workbench/references/3d-pipeline.md)（门/盲评/工具映射）·
> [schemas.md](skills/creative-workbench/references/schemas.md) §2（plan schema）·
> [research/3dcodeverse.md](research/3dcodeverse.md)（阈值来源）·
> [creative-refactor-decisions.md](creative-refactor-decisions.md)（R0 冻结与缺口）。

## 1. 定位与执行面

* 3D = **建模**工作台：大纲（场景树）｜视口（Orbit 相机、网格、拾取、变换 gizmo
  move/rotate/scale、吸附）｜检查器（变换/材质/几何参数）；现有 scene spec / pass 管线
  保留为**生成管线**（brief → plan → scene/code → check，plan §4）。
* 执行面 = vendored **three-live 1.4.0** 沙箱（`app/assets/three/vendor/three-live.min.js`），
  跑在 `webview_all` 全平台 WebView，CSP/worker 边界不改（three-live-sandbox.md）。
  `flutter_scene` 不采用（2026-11-20 裁决）；three.js / three-live 是「外部创作工具只参考、
  不引入」的明确例外（AGENTS.md）。
* GLB 从**同一份源码**重建（`object.glb` / `public/assets/*.glb`），`artifacts/` 对 agent
  只读——代码是真相，产物是派生物；不用外部浏览器/headless Chrome/Blender/Python 子进程；
  移动端可降视角数与分辨率，**不得声称 14 视角对等**（3d-pipeline §9）。

## 2. 三轨与双 authoring

| 轨 | v1 | 语言 | 交付物 |
| --- | --- | --- | --- |
| `static_object` | ✅ | `threejs` | 源码 + `object.glb` + 渲染证据 |
| `scene` | ✅ | `scene_threejs` | `src/**` + `public/assets/*.glb` + 渲染 + probes |
| `graphics` | ✅ | `glsl_shader` | 源码 + 判分帧 + sheet + 帧指标 |

`articulated_object`（URDF/Blender）属 **backlog**，不随产品；后续用 three.js Group 层级 + 自定义 joint 检查近似。

| 模式 | 事实源 | 适用 | 编辑器 |
| --- | --- | --- | --- |
| `scene` | `scene.json`（v1：nodes/transform/material/env/camera，节点 ≤200） | 手工建模、图元/变换/材质、轻量场景 | 大纲/视口/检查器直接改 JSON；编译成 `src/scene.js` 预览/导出 |
| `code` | `src/*.js` | 一句生成、3dcodeverse harness、复杂世界/shader | 源码为主；检查器读派生 scene graph，编辑走受控 patch；禁止整文件重写 |

新空场景默认 `scene`；生成/harness 路径默认 `code`。两模式共用 three-live、同一套门/judge/artifacts；**code 模式的 `scene.json` 是派生投影，不是第二真相**，禁止 `scene.json` 与 `src/` 同时写（decisions §1）。

## 3. 工作区布局

```
spec.json   track / language / prompt / must_have / must_not / dims / references
plan.json   精确数字 + acceptance（先过 three_plan_validate 才写代码）
scene.json  scene 模式事实源；code 模式派生投影（只读/受限编辑）
src/        源码（code 事实源；scene 模式由 scene.json 编译）；public/ 为 scene 轨编译资产
artifacts/  object.glb / renders/ / gates.json / measurement.json（agent 只读）
judge/rNN/  brief.md + montages + judgment.json + score.json（每轮一个 git tag）
```

`src/` 文件名 kebab-case、一文件一 part/zone/layer/shot；`judge/rNN/` 零填充；每轮 = `src/` 提交 + tag（decisions §1）。轮次证据与快照不写进 `src/`。

## 4. plan schema 摘要

| 轨 | 必填主体 | 规则 |
| --- | --- | --- |
| 对象 | `parts[{id, dims_m[3], material, parent, bbox_center_m}]` + `acceptance` + `motion` + `camera.views` | `id` 唯一、ASCII snake_case；`dims_m` 3 个有限正数；`parent` 存在或 null；`dims` 与 `bbox` 差 ≤1mm |
| 场景 | `zones` / `placements` / `lights` / `atmosphere` / `cameras` / `motion` + 同风格 `acceptance` | placements 引用存在的 zone；相机坐标有限；对象 plan <5KB |

* 图形轨用 common 段（`schema/kind/summary/acceptance/risks`）+ 帧验收；具体字段待 R1 冻结（decisions §3）。
* `acceptance` 非空，逐条**二分可观测**（如「座高 0.45m」「四腿落地 ≤2mm」「无漂浮/穿插 >2mm」）；无精确数字、无验收项的 plan 视为无效。
* 占位件只允许出现在 plan，**不允许进 `src/`**：检查期 ≤12 三角且与 plan box 偏差 ≤1mm 的 box 判 `placeholder_part` ERROR；禁止用非均匀缩放把成品塞进 plan box。
* 完整字段/校验规则见 [schemas.md](skills/creative-workbench/references/schemas.md) §2、[3d-pipeline.md](skills/creative-workbench/references/3d-pipeline.md) §4。

## 5. 确定性门与阈值（先于视觉；每条 ERROR 带可执行 fix hint）

| 轨 | 门 | 阈值 |
| --- | --- | --- |
| 对象 | contract / connectivity | bbox 每轴 `max(10mm, 10%)`（1× WARN / 3× ERROR）；ground 10mm WARN / 30mm ERROR；footprint 居中；`placeholder_part`；接触 ≤2mm；穿插 >2mm WARN / >10mm ERROR；**漂浮 ERROR**；孤岛 <5% WARN |
| 对象 | detail / fixed | 三角面上下限、构建耗时（parts×instances）；fixed parts 不得改名/移动/删除 |
| 场景 | placement / census | 脚下间隙、埋入、无支撑、相互穿插、越界、缩放（打印「移动 x 米」）；对象/材质/灯光/三角面/console errors；**draw calls ≤15000** |
| 场景 | shader preflight / frames | 逐个 ShaderMaterial 无头编译（Dart/JS 等价实现，错误带行号）；曝光/相机/内容/帧运动/hero unseen |
| 图形 | lint / frames | t=0/1/2.5/4/6s @1280×720；NaN、全黑/过曝、静止、闪烁、低细节 |

任何 ERROR 都 cap 分数；WARN 不 cap（便宜就修一次）；fix hint 用运行时原生单位（米/px/度）。阈值出处：[3d-pipeline.md](skills/creative-workbench/references/3d-pipeline.md) §6、[research/3dcodeverse.md](research/3dcodeverse.md) §5.1。

## 6. 盲评与评分

* 打包：对象 = 14 视角 + 细节/接触 montage；场景 = 作者相机 t=0 / 1.5s + orbit；图形 = 逐帧 sheet。`brief.md` 含请求、plan 摘要、acceptance、测量/门事实、rubric 锚点、缺陷清单、judge 必须返回的精确 JSON。
* judge = **fresh context**，只看 `brief.md` + 图片，不写总分；`three_score` 做算术：`overall = Σ(weight×criterion) − penalties → floors → caps last`。
* rubric 起始权重（3D）：idea .15 / composition .20 / craft .25 / motion .15 / legibility .10 / constraint_fit .15；caps：build error 0、floating .60、penetration .70、contract .75、未满足 must .60（graphics .70）。
* 交付**最佳轮**（不是最后一轮）；tie 容差 `0.03` 内走 pairwise 且两种展示顺序都跑。评分默认参数（`passThreshold=0.85` 暂定、penalty 默认 0、floors 空）见 decisions §1。

## 7. 工具面（10 个新工具均为**拟实现**，名称实现时定）

| 工具（拟实现） | 作用 | 对应 3dcodeverse |
| --- | --- | --- |
| `three_plan_validate` | ✅ **已实现**：schema + 数字 + acceptance + scene 必填 + 迁移草案提醒 | `validate-plan` |
| `three_build` | ✅ **已实现**：scene 模式 scene.json → `src/scene.js` 确定性编译 + `artifacts/build.json`；GLB 导出待后续 | `build` |
| `three_check` | ✅ **已实现**：省略 measurement 时自动读最新测量 → contract/connectivity/detail 门 → `artifacts/gates.json` | `check` |
| `three_measure` | ✅ **已实现**：读取预览页 per-part bbox/三角面（`artifacts/measurement.json`） | `measure` |
| `three_render_views` | 多视角/线框/法线/轮廓/clay + contact sheet | `render-views` / `render-sheet` |
| `three_scene_probe` | census / draw calls / triangles / console / atmosphere | `scene-probe` |
| `three_check_placement` | ✅ **已实现**：场景轨 placement/census（落地/埋入/漂浮/穿插/越界/draw calls ≤15000），ERROR + 米制 fix hint | `check-placement` |
| `three_shader_probe` | 编译全部 ShaderMaterial，带行号 | `shader-probe` |
| `three_judge` | 打包 brief + montage，交独立 judge 上下文 | `judge` / `judge-pack` |
| `three_score` | rubric 算术 + caps + improvement list | `score` |

既有 `three_list / create / read / patch / verify / inspect` 保留（现状工具）。workspace 模式只暴露 `three_*` + 通用只读；跨模块不走 `three_*`。工具结果必须整形（剥源码/长文本、截断节点、追加 state 卡），避免吃光上下文（AGENTS 纪律）。

## 8. 许可边界（直接引入的硬约束）

* **随包**：3dcodeverse skill/harness 契约（Apache-2.0）的 LICENSE / NOTICE 与来源 commit；three-live 1.4.0（已在库）。
* **不引运行时**：Python CLI / Blender / CadQuery / URDF / moderngl；检查器全部 Dart/JS 等价实现；开发期只可 clone 上游对拍，不随 App 分发。
* **不引数据集/资产**：3DCodeVerse-2M（CC-BY-NC-SA）不随产品分发；示例资产/prompt/渲染图不复制。articulated 轨与多 agent DAG 是 backlog，不做训练/微调。

## 9. 迁移（现有 `three-spec.json` / `scene.js` / `build-state.json` → 新布局）

| 现状（`three_service.dart` 实测 2026-11-23） | 新布局 |
| --- | --- |
| `three-spec.json` | `spec.json`（请求面）+ `plan.json`（组件/材质/相机/验收）；scene 模式的图元/变换另落 `scene.json` |
| `scene.js` | `src/*.js`（code 模式事实源）或 `src/scene.js`（scene 模式编译产物） |
| `build-state.json` | `artifacts/gates.json` + `judge/rNN/` 轮次记录；六层 pass 顺序保留为生成管线 |
| `preview.html` / `three.module.js` / `evidence/` / `history.jsonl` | 执行面资源拷贝（不是事实源）；证据进 `artifacts/renders/`；`history.jsonl` 继续记账 |

迁移纪律：旧文件**不静默删**；首次成功打开并写新布局后标 legacy；删除策略待 R1 冻结。

## 10. 落地锚点与验收（2026-11-24，R3 第一批）

* v2 工作区：`app/lib/core/three/three_workspace.dart`（spec/plan/src/artifacts/judge 布局、
  原子写、`migrateLegacy` 只增不删、`migration.json`、code/scene/legacy 三模式）。
* plan 校验：`app/lib/core/three/three_plan.dart`（3D 追加规则 + `draftPlanFromLegacySpec`）。
* 确定性门：`app/lib/core/three/three_gates.dart`（`evaluateThreeGates`：contract /
  connectivity / detail_budget；阈值常量集中在 `ThreeGateOptions`；caps floating .60 /
  penetration .70 / contract .75）。
* 服务与工具：`ThreeService.workspaceMigrate/workspacePlanValidate/workspaceCheckGates`；
  agent 工具 `three_workspace_migrate` / `three_plan_validate` / `three_check`（workspace run
  仅 `three_*` 可见）；`three_workspace_migrate` 计入交付水位。
* 测试：`app/test/three_plan_test.dart`（6）、`app/test/three_gates_test.dart`（8）、
  `app/test/three_workspace_test.dart`（6）、`dart_agent_tools_test` 的 3D v2 工具流程。
* 场景门（2026-11-24 第四批）：`app/lib/core/three/three_scene_gates.dart`——
  `evaluateThreeSceneGates`（placement：lowest/ground_gap/buried/floating/penetration/
  zone_out_of_bounds；census：draw_calls ≤15000；caps floating .60 / penetration .70 /
  placement .75）。`ThreeService.workspaceCheckPlacement` 自动读最新 measurement，
  写 `artifacts/placement-gates.json`；agent 工具 `three_check_placement`（对象轨拒绝，
  返回 `three_track_not_scene`）。3D 双面新增「摆放门」阶段。
* 测试补充：`app/test/three_scene_gates_test.dart`（8）；`three_workspace_build_test`
  增摆放门服务用例（自动测量/对象轨拒绝）；agent 工具面/流程断言覆盖
  `three_check_placement`。
* scene 事实源（2026-11-24 第三批）：`app/lib/core/three/three_scene.dart`——
  `ThreeSceneDocument.parse`（v1、节点 ≤200、snake id、父级/环/尺寸/颜色校验）+
  `compileThreeScene`（确定性：同输入同字节、无随机/时间；`mesh.name = node.id`，
  支撑测量与门对齐）。`ThreeService.workspaceBuild` 只写派生产物
  （`src/scene.js` + `artifacts/build.json`），不改事实源；code 模式要求 `src/` 非空。
* 迁移证据：`migrateLegacy` 额外把旧 `build-state.json` 复制到
  `artifacts/legacy-build-state.json`（旧文件仍保留）。
* 测试补充：`app/test/three_scene_test.dart`（6）、`app/test/three_workspace_build_test.dart`（4）；
  agent 工具面增加 `three_build` 流程断言。
* 测量桥（2026-11-24 第二批）：`app/assets/three/preview.html` 的 `__measure()` 逐 mesh
  输出 `parts[{id,bbox,triangles}]`（mesh.name 对齐 plan part id；未命名用 mesh_N 诚实兜底）；
  `ThreeService.feedback(metrics)` 落 `artifacts/measurement.json`，
  `latestMeasurement` / agent `three_measure` 可读；`three_check` 省略 measurement 时自动读最新值。
* 3D 双面：`AppStore.threePipelineStages/threeGateVerdict/threeGateFixHints`，由 v2 工具结果回调
  `applyThreeWorkspaceEvent` 推进；`three_workspace.dart` 挂 `WorkspaceProgress` + `WorkspaceArtifactCard`
  （阶段：迁移 → 计划校验 → 测量 → 确定性门；结果卡可查看修复提示/收起）。
* 测试补充：`app/test/three_measurement_test.dart`（4）、
  `app/test/three_gate_dual_face_store_test.dart`（2）。
* 检查器属性编辑（2026-11-25）：`three_workbench_panels.dart` 的 `ThreeNodeInspector` 对 legacy
  `three-spec.json` 的 component（what/size_scale/material）、material（color_hex/roughness/metalness）、
  camera（view）提供受控编辑；面板只产出最小补丁（`ThreeInspectorEdit`），
  `validateThreeInspectorEdit`/`applyThreeInspectorEdit` 纯函数合并，`three_workspace.dart`
  复用既有 `_saveSpec` 落盘并刷新快照；v2 scene.json 节点仍只读。测试：`three_workbench_panels_test`（13 例）。
* 视口控件（2026-11-26）：`assets/three/preview.html` 追加 `window.__non3d_view(front|top|iso|reset)`
  与 `window.__non3d_grid(visible)`（legacy 网格用独立 scene 渲染，不污染 `__measure` 的包围盒事实；
  沙箱面网格按命名 mesh 开关，缺失时 `supported:false` 如实回复、宿主复原并提示一次）；
  `three_viewport_controls.dart` 提供预置视角/网格/重置浮层，宽屏预览面上方挂载，未就绪时禁用并给真因。
  测试：`three_viewport_controls_test`（3）+ `three_workspace_test`（视图控件分支）。
* **待后续**：GLB 导出、多视角 render_views、
  建模视口（大纲/视口/gizmo/检查器）、scene/graphics 轨门、judge 打包。

## 11. 验收锚点（拟写测试名，施工时落地）

| 契约面 | 拟写测试 | 锚定 |
| --- | --- | --- |
| plan/契约纯函数 | `three_contract_test.dart` + `three_plan_validate_test.dart` | schema、阈值常量、fix hint 单位；缺验收/重复 id/尺寸非法/placeholder 拒绝 |
| 对象门 | `three_gates_test.dart` | bbox、ground、contact、penetration、floating、placeholder 正反例 |
| 场景/图形门 | `three_scene_gates_test.dart` | draw calls ≤15000、shader preflight、帧指标 |
| 盲评/评分 | `three_judge_test.dart` | brief 打包、caps、best round、0.03 tie |
| 迁移/工具面 | `three_workspace_migration_test.dart` + 拟扩 `dart_agent_tools_test.dart` 的 `workspace mode tool surface` | 旧布局可读、新布局落盘、legacy 标记、不删文件；只见 `three_*` + 通用只读 |
