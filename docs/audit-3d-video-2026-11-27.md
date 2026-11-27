# 3D / 视频线「技能 · 参考 · 框架 · 引擎」核查报告

> 基线 commit `987bf08`；核查日期 2026-11-27。
> 环境：Linux x86_64（linglong 容器）/ Flutter 3.50.1 / WebKitGTK 4.1。
>
> **口径**：本报告只写实测证据。方案文档写目标态；凡台账标「未施工」的项一律按未施工
> 记账，不冒充现状。每条结论都给出可复现的命令或数字（见 §8）。

## 0. 结论速览

| 项 | 裁决 | 是否在位 | 标记 |
| --- | --- | --- | --- |
| three.js r160（渲染库） | 引入 | 在库 + 字节/哈希硬校验 | ✅ |
| three-live 1.4.0（沙箱执行面） | 引入 | vendored + 许可 + 内嵌 + 零外链 | ✅ |
| ThreeUI 组件目录 | 引入 | 12 组件 + 12 页 + 目录校验 | ✅ |
| 3dcodeverse harness 契约 | 引入契约/不引运行时 | plan/gates/lint/workspace/judge 全部落地 | ✅ |
| 盲评通道（fresh context） | 引入 | `creative_judge` 只在 workspace run 暴露 | ✅ |
| 统一创作 skill 硬纪律 | 定稿 | 代码内注入 run（`creative_skill.dart`） | 🟡 |
| 统一创作 skill 完整流程 | 定稿 | SKILL.md 的 intake→…→deliver 未整体接线 | 🟡 |
| 常规视频 v1（矢量 + DOM 短片） | 现状保留 | 两渲染面俱在 + 桥契约 + 测试 | ✅ |
| 3D 视频数据契约/编译/存储/预览 | 设计 WIP | 全部落地且真机冒烟通过 | ✅ |
| 3D 视频「真 three/WebGL 渲染」 | 设计待后续 | v1 是确定性 Canvas2D 投影 + THREE 兼容层 | 🟡 |
| 3D 视频 agent 工具面（`video3d_*`） | 计划 P2 明确列为必做 | **零实现** | ❌ |
| pixelfx VFX 子集 | 方案定稿·未施工 | 只有事件 schema，零渲染面 | ⬜ |
| Phaser 3 引擎短片 | 方案定稿·未施工 | 无依赖、无运行时 | ⬜ |
| 只参考项零依赖 | 生效裁决 | 全仓零残留 | ✅ |

统计：✅ 9 项、🟡 3 项、⬜ 2 项、❌ 1 项。

## 1. 技能（skills）

| 检查点 | 证据 | 结论 |
| --- | --- | --- |
| 主契约在场 | `docs/skills/creative-workbench/SKILL.md`，364 行 | ✅ |
| 7 份参考齐全 | `references/`：3d-pipeline(263) · judging(114) · prompt-anatomy(151) · schemas(225) · story-short(158) · vfx-pixelfx(98) · video-pipeline(158) | ✅ |
| 运行时注入 | `app/lib/core/creative/creative_skill.dart`（`creativeWorkbenchCore` + `creativeSkillForWorkspace`）→ `dart_agent.dart:2570` / `:2637` | ✅ |
| 注入有测试 | `app/test/creative_skill_injection_test.dart`（在全量测试里通过） | ✅ |
| 完整流程接线 | SKILL.md 的 intake→direction→structure→build→check→judge→refine→deliver 只有 3D 线整套落地；视频线只有 v1 的 sample→create→review | 🟡 |

结论：**硬纪律已进 prompt，完整流程仍属方案态**。台账「未接线」需要改成「部分接线」。

## 2. 参考（research）

`docs/research/` 11 份全部在库（3dcodeverse / pixelfx / raea / material-painter /
openmotion-hyperframes / line-art-animation / claude-animated-shorts /
awesome-opus5-5-videos / video-animation-howto / tts-offline-appendix / music-arrangement-howto）。

只参考项零残留（排除 `docs/` 全仓搜索 `raea|material-painter|openmotion|hyperframes|remotion|bevy`）：
**0 命中**。依赖面同样干净：`app/pubspec.yaml` 无 Phaser / React / Remotion / Node / Chromium，
`third_party/` 只有 `a2ui_web` 与 `wasm_run`（引擎兜底）。

## 3. 框架与引擎（逐项）

### 3.1 three.js（3D 建模工作台渲染库）

- `app/assets/three/three.module.js`：实测 **1,272,972 字节**，
  sha256 `76dea8151bc9352aef3528b4262e249b2604f62543828328db978d060d61a495`
  **与 `three_service.dart` 的常量逐字一致**。
- 运行时校验策略：拷贝到项目目录时比对字节长度（`threeModuleByteLength`），
  裁剪即显性失败（`three_service.dart:1233`）。
- 预览页 `app/assets/three/preview.html`（732 行）双执行面：
  1. **默认**：场景脚本在 three-live 沙箱 Worker 里构建 Scene → 转 GLB → 由
     three-live viewer（自带渲染器 + 相机操控）显示；
  2. **兜底**：隐藏 three-live，用内联 r160 模块在本页直跑同一份场景函数。
- CSP：`default-src 'none'`，只为沙箱放开 `'unsafe-eval'` 与 `worker-src blob:`。

### 3.2 three-live 1.4.0（沙箱执行面）

- `app/assets/three/vendor/`：`three-live.min.js` **224,716 字节** + `THREE-LIVE-LICENSE`
  + `NOTICE.md`（含 file:// 引擎内联补丁说明）。
- 组装契约：占位符必须出现且仅出现一次；模板要沙箱面却没拿到运行时 → **显性失败**
  （`three_service.dart:2094` / `:2103`）。
- 测试：`app/test/three_live_vendor_test.dart` 覆盖「资源在场 / 组装替换 / 零外链 /
  CSP 不放宽网络」。

### 3.3 ThreeUI 组件目录

- `app/assets/three/threeui/catalog.json`：**12 个组件**，落在硬边界
  `threeUiMinComponents = 8` / `threeUiMaxComponents = 12` 之内；
  12 个 `.html` 页面 + `NOTICE.md` / `LICENSE` / `FONT-LICENSES.md`。
- 接线：`three_workspace.dart` 的 `threeui-gallery` / `threeui-<id>` / `threeui-catalog-retry`；
  测试 `app/test/three_threeui_test.dart`。

### 3.4 3dcodeverse harness 契约（引入契约、不引运行时）

实际落地（全部有测试）：

| 契约面 | 实现 | 测试 |
| --- | --- | --- |
| 工作区 spec/plan/src/artifacts/judge + 旧布局只读迁移 | `core/three/three_workspace.dart`（`ThreeWorkspaceLayout`） | `three_workspace_test.dart` / `three_workspace_build_test.dart` |
| plan schema + 3D 专属追加校验 | `core/three/three_plan.dart` | `three_plan_test.dart` |
| 确定性门（bbox/ground/contact/penetration/floating/placeholder/细节预算） | `core/three/three_gates.dart` + `three_scene_gates.dart` | `three_gates_test.dart` / `three_scene_gates_test.dart` |
| 测量 → `artifacts/measurement.json` → `artifacts/gates.json` | `three_service.dart:860/875/1607/1613` | `three_measurement_test.dart` / `three_gate_dual_face_store_test.dart` |
| 空间 linter | `core/three_lint.dart` | `three_lint_test.dart` |
| 盲评（fresh context + 六维 + caps） | `core/creative/creative_judge.dart` / `creative_score.dart` | `creative_judge_test.dart` / `creative_judgment_score_test.dart` |

Python / Blender / CadQuery / URDF / moderngl 运行时**均未进入产品**（依赖面已核）。

### 3.5 常规视频（v1 双渲染面，现状保留）

| 渲染面 | 实现 | 状态 |
| --- | --- | --- |
| 矢量算式动画 | `core/video_service.dart` 的 `VideoDocument.frameSvg(tGlobal)`（纯 Dart，逐帧） | ✅ |
| DOM 动效合成短片 | `app/assets/video/clip/`：`clips.json` + `engine.js` + `engine.css` + 4 个自包含 HTML；桥 v1 | ✅ |

`video_render` 只回 `video_export_disabled`（`dart_agent.dart:1383`），成片导出仍屏蔽，
与裁决一致。测试：`video_service_test.dart` / `video_clip_test.dart` /
`video_clip_surface_test.dart` / `video_project_test.dart` / `video_workspace_test.dart`。

### 3.6 3D 视频（three-live 目标面 / 现状是确定性 Canvas2D）

- 数据契约：`video3d_contract.dart`（scene3d.json / screenplay3d.json，30fps 整数帧，
  拒绝 NaN/∞）；
- 编译：`video3d_compile.dart`（同一输入两次编译字节相同）；
- 播放页：`video3d_player.dart`，**`video3dPreviewRenderer = 'canvas2d_deterministic'`**，
  `canvas.getContext('2d')` + 页面内**最小 THREE 兼容层**；three-live 运行时文本被内嵌到
  `<script id="video3d-runtime">`，但 **v1 不做 WebGL 真渲染**（代码注释已明示）。
- 存储：`video3d_project.dart`（先 `verifyVideo3d` 再落盘，磁盘不出现半成品）；
- 真机证据：WebView 冒烟里 `Video3dPreviewSurface` 就绪、`totalFrames=150`、
  `seekFrame(90)` 到位。

结论：**数据/确定性/预览链路完整**；「真 three/WebGL 渲染」按设计文档仍是待后续批次。

### 3.7 pixelfx VFX 子集（方案定稿·未施工）

- 契约层**只有事件 schema 校验**：`core/creative/creative_plan.dart` 的
  `CreativePlanEvent`（`type ∈ {vfx, sfx, camera.shake}`，vfx 校验 x/y 锚点）；
- **零渲染面**：`app/lib` 内 `video3d/`、`video_service.dart`、全部 `video_*.dart` 中
  **没有任何 vfx/camera.shake 渲染代码**；`pixelfx` 只出现在两处注释里；
- `CreativePlanVideo`（`creative_plan.dart:142`）**零消费者** —— 视频线的真实事实源是
  `timeline.json + spec.json`（v1）与 `scene3d.json + screenplay3d.json`（3D 视频），
  两者都**没有 vfx 事件字段**。

结论：**与台账「方案定稿（未施工）」一致，不是谎报，但能力完全不在位**。

### 3.8 Phaser 3 引擎短片（方案定稿·未施工）

- `app/pubspec.yaml` **无 Phaser 依赖**；`app/lib` 无任何 Phaser 代码；
- 仅文档里有选型（`docs/plan-creative-workbench.md` §5.0、`docs/video-screenplay-contract.md`）。

结论：与台账一致（未施工）。常规视频当前是 v1 两渲染面，不依赖 Phaser。

## 4. 工具面清单（从 `addWorkspaceTool(` 实测量出）

| 线 | 数量 | 工具 |
| --- | --- | --- |
| 3D（three-live + 3dcodeverse） | 12 | `three_plan_validate` `three_create` `three_pass` `three_continue` `three_feedback` `three_build` `three_measure` `three_check` `three_check_placement` `three_status` `three_list` `three_workspace_migrate` |
| 常规视频 | 5 | `video_sample` `video_create` `video_review` `video_list` `video_render`（只回导出屏蔽） |
| 3D 视频 | **0** | —— |
| 盲评（3D/视频共用） | 1 | `creative_judge`（仅 `mode == 'workspace'` 暴露，`kind ∈ {3d, video}`） |

`dart_agent.dart` 与工作台模式里**没有 `video3d` 这个 workspace mode**
（只有 `three` / `video` / `music` / `design`），因此 agent 无法创建或修改 3D 视频项目 ——
用户只能在 UI 里手填 `scene3d.json` / `screenplay3d.json`。

## 5. 调用链流畅性证据（本轮实测）

| 检查 | 结果 |
| --- | --- |
| `flutter analyze --no-pub` | **No issues found!（2.6s）** |
| 3D/视频/创意定向测试（38 文件） | **446 passed / 0 failed（44s）** |
| 全量 `flutter test` | **1802 passed / 5 skipped / 1 failed**；唯一失败是 AGENTS.md 已登记的环境限制 `desktop_rpc_host_test`（容器 loopback 观测不到「对端消失 → 取消」） |
| 真机 WebView 冒烟（Linux WebKitGTK，`scripts/wf/run_webview_smoke.sh`） | **6/6 passed** |
| `flutter build linux --debug` | 见 §7 门禁记录 |

冒烟实测数字：

```
[webview-music] ready=object position=0.0 totalTicks=n/a
[webview-music] positionAfter=1.544126984126984 beats=1 errors=[]
[webview-video3d] totalFrames=150.0 frames=2 errors=[]  frameAfterPlay=149.0
[webview-three] view=true grid=false gridReceipt=[false]
[webview-music-surface] ready=true position=1.520907029478458 beat=1
[webview-video3d-surface] ready=true totalFrames=150 frame=90
[webview-overlay] taps=1 probe=hit
```

即：音乐页就绪 + 音频时钟真实推进；3D 视频 150 帧表 + seek 同步；3D 视口预设真页面可用；
生产面（`MusicPlaybackSurface` / `Video3dPreviewSurface`）在真 WebView 里就绪；Flutter 浮层
叠在真 WebView 上仍可点击。

## 6. 缺口（按严重度）

1. **❌ 3D 视频没有 agent 工具面**。`docs/plan-next-iterations.md:94` 明确写了
   `video3d_create`（最小）/`video3d_status`/`video3d_render_frames`，实现为零；
   `dart_agent.dart` 全文无 `video3d` 字样。后果：3D 视频只能靠人手写两份 JSON。
2. **🟡 3D 视频预览不是真 three 渲染**。v1 是确定性 Canvas2D 投影 + 最小 THREE 兼容层；
   保真度（光照/材质/透视正确性）与「3D」名义有落差，属设计文档已登记的后续批次。
3. **⬜ pixelfx VFX 未施工**。事件 schema 已冻结但零渲染面、零事实源字段、
   `CreativePlanVideo` 无消费者。
4. **⬜ Phaser 引擎短片未施工**。无依赖无运行时，常规视频维持 v1。
5. **🟡 SKILL.md 完整流程未接线**（硬纪律已注入）。
6. **台账滞后**（本轮已纠偏，见 §7）：`docs/README.md` 把已落地的 3D 视频三份设计稿、
   3D 视口预设与盲评标成「未施工 / 待后续」；AGENTS.md 把 skill 写成「未接线」。
7. 非代码残留：仓库根有未跟踪的 `server/__pycache__/`（无 Python 源码，`.gitignore` 外的
   陈旧构建产物），不影响门禁，建议清理。

## 7. 本轮修复动作

1. 新增本报告（唯一事实：3D/视频线能力矩阵 + 证据 + 缺口）。
2. 纠偏台账状态（只改状态行，不改契约内容）：
   - `docs/README.md` §1.4：3D 视频三行、SKILL 行、three-contract 行；
   - `docs/design/video-tracks-adr.md` 状态头；
   - `docs/plan-next-iterations.md` P2 施工状态；
   - `AGENTS.md` 文档入口里的 skill 状态。
3. 未实现的能力（§6 的 1–4）**不在本轮伪造**：全部按「未施工 / 缺口」记账，
   下一步施工顺序见 §9。

## 8. 复现命令

```bash
# 门禁
cd app && flutter analyze --no-pub
cd app && LD_LIBRARY_PATH=$HOME/.local/nan-dev/lib flutter test --no-pub

# 3D/视频/创意定向
cd app && LD_LIBRARY_PATH=$HOME/.local/nan-dev/lib \
  flutter test --no-pub $(ls test | grep -E '^(three_|video|video3d_|creative_|vfx)' | sed 's|^|test/|')

# 真机 WebView（Linux WebKitGTK）
scripts/wf/run_webview_smoke.sh

# 资源对账
wc -c app/assets/three/three.module.js && sha256sum app/assets/three/three.module.js
wc -c app/assets/three/vendor/three-live.min.js
grep -c '"id"' app/assets/three/threeui/catalog.json

# 只参考项零残留（应 0 命中）
grep -rniI "raea|material-painter|openmotion|hyperframes|remotion|bevy" \
  --exclude-dir=docs --exclude-dir=.git --exclude=*.md .
```

## 9. 下一步施工顺序（按缺口严重度）

1. **3D 视频工具面**：`video3d_create` / `video3d_status`（先最小），
   加 `video3d` workspace mode + 工作区适配器 + 测试（把「只能手填 JSON」补上）。
2. **3D 视频真 three 渲染**：把 Canvas2D 投影替换为 three-live 场景渲染，保留整数帧
   seek 与帧证据桥。
3. **pixelfx VFX**：先落 `screenplay.json` 的 `vfx` 字段 + allowlist 编译期硬门，
   再落特效渲染（只取火焰/冰霜/风/爆炸/闪电，不取人物）。
4. **Phaser 引擎短片**：按 `docs/plan-creative-workbench.md` §5.0 批次 5a。
5. **SKILL 完整流程接线**：把 intake/direction/structure 三段做成 run 可调用的阶段门。
