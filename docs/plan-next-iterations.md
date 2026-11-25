# NaN 后续迭代计划 v3（2026-11-24，设计先行）

> 状态：**方案（2026-11-24，用户方向已定；未施工）**。本计划取代同日 v1/v2 的宽口径排期：
> 收窄到**视频双轨（常规视频 / 3D 视频）**，**不引入任何新引擎**；3D 视频执行面用现有
> **three-live**，raea 仅作契约/工艺参考（2026-11-24 用户最终裁决：不嵌入、只借鉴）。
> 先完成设计冻结与最小 POC，再进入实现。音乐、TTS、VFX、toon_3d 正式化、Phaser 引擎短片、
> 3D 建模视口/GLB/judge 等移入 §7 backlog。
>
> 相关：[plan-creative-workbench.md](plan-creative-workbench.md)（总方案）·
> [video-clip-contract.md](video-clip-contract.md)（常规视频现状 v1）·
> [video-screenplay-contract.md](video-screenplay-contract.md)（剧本目标态）·
> [three-contract.md](three-contract.md)（3D 执行面/测量/构建）·
> [research/raea.md](research/raea.md)（只参考：composition/词级时间/check/story 契约）·
> [skills/creative-workbench/references/story-short.md](skills/creative-workbench/references/story-short.md)（3D 短剧工艺参考）·
> [docs/README.md](README.md) §2 决策台账 ·
> [plan-workbench-ui.md](plan-workbench-ui.md)（工作台交互姿态/UI 独立适配，另一条并行批次） ·
> 设计草案：[video-tracks-adr.md](design/video-tracks-adr.md) · [video3d-execution.md](design/video3d-execution.md) · [video3d-contract.md](design/video3d-contract.md)。

## 0. 本轮修正（相对 v1/v2）

1. **不引入 raea**：用户复核许可（FSL *Competing Use*）与形态（230 crate 完整应用、无公开
   库 ABI）后决定**不嵌入**；3D 视频执行面用现有 **three-live**，raea 只借 composition/
   词级时间/`check`/story 契约与工艺。无 raea POC、无 Rust/FFI、无新增运行时。
2. **视频拆成两条明确轨道**：常规视频（现有 v1 表面保持）与 3D 视频（three-live 执行面）。
   两轨不共用渲染器，只共用上层创作语义/评审规范。
3. **范围收窄**：只做「收口 + 视频双轨设计 + 3D 视频最小纵切」；音乐、TTS、VFX、Phaser
   引擎短片、3D 建模视口/GLB/judge 全部退到 backlog。
4. **设计先行**：D 阶段只产出设计/决策/POC 计划；设计门通过后再写实现。

## 1. 基线（2026-11-24 工作树）

| 已具备 | 事实 |
| --- | --- |
| 工程门禁 | `flutter analyze` 无问题；全量 `flutter test` 1279 passed / 1 known env；`flutter build linux --debug` ✓ |
| 常规视频现状 | v1 `video-clip-contract`：Dart 矢量 `VideoDocument.frameSvg(t)` + 自包含 DOM `ND.scene` 短片；`screenplay.json` 目标态已冻结但未实现 |
| 3D 执行面 | three-live 沙箱（WebView）+ 现有 3D 预览/截屏/turntable 桥；3D R3 契约面（v2 工作区/plan/确定性门/measurement/build/摆放门/双面）已有可复用基础 |
| 代理/工具 | Genkit + 工具面收窄 + 统一创作 skill + 盲评通道；设计模块 R1 已落地 |
| 待处理 | 81 个变更未提交；`wip/creative-workbench-r3-20261124` 备份分支；GitHub 直连不稳定（用镜像 fetch） |
| 明确不引入 | raea（只参考）、material-painter（只参考）、Remotion/React/Node/Chromium、任何新渲染引擎 |

## 2. 视频双轨定义（设计阶段第一件事）

| 维度 | V-A 常规视频（保持现状） | V-B 3D 视频（three-live 执行面，目标新增） |
| --- | --- | --- |
| 定位 | 2D/矢量/动效短片、图表/科学演示、轻量风格短片 | 代码化 3D 世界/短剧：3D 场景、灯光、相机运动、镜头时间线 |
| 事实源 | `screenplay.json`/timeline（设计阶段只读核对，不重构） | **待设计冻结**：`scene3d.json`（场景/节点/灯光/相机/glTF 引用）+ `screenplay3d.json`（镜头/时间/cue），agent 只写 JSON |
| 执行面 | 现有 Dart 矢量 / DOM clip；Phaser 3 引擎短片仍是 backlog | 现有 **three-live 沙箱**（WebView，自包含 HTML，零外联） |
| 时间模型 | `frameSvg(t)` 纯函数 / 30fps 整数帧 / v1 桥 | 待设计：固定 30fps、`seek(t)=重置+按帧重放`、同输入同帧；帧证据经现有截图桥落 `artifacts/` |
| 产出 | 现有应用内播放；导出仍按 v1 裁决屏蔽 | 应用内预览 + 帧/contact sheet 证据；成片导出裁决待定（默认屏蔽） |
| 本文范围 | **只做回归与兼容** | 设计 → POC → 一条 5–10s 单镜头纵切 |

**边界（写入 ADR）**：3D 视频用 three-live，但与 3D 建模工作台的**事实源分开**（视频项目
有自己的 `scene3d.json`/`screenplay3d.json`，不混写 3D 建模项目）；两轨不共用渲染器；
raea 只提供契约参考，不进入代码依赖。

## 3. 阶段与批次（设计先行）

### M0 · 收口与文档一致（0.5–1 天）

- 81 个变更拆 4 笔提交（Genkit / R0+设计模块 / 3D R3 / Linux 执行器）；处理 WIP 分支与 `.zcode`。
- 同步本次最终裁决到文档：raea **不引入、只借鉴**，3D 视频用 three-live（已完成决策台账/
  AGENTS/README/research/plan/SKILL 回填）。
- 验收：main 无未提交业务代码；analyze/test/build 绿；文档无「raea 嵌入」旧表述。

### D · 设计阶段（3–5 天，**只设计不实现**）

**D1. 视频双轨 ADR**（`docs/design/video-tracks-adr.md`，**草案已落盘**）
- 定义 V-A/V-B 事实源、执行面、时间模型、共享字段、产物边界；明确 3D 视频不替换
  three-live 建模面、不引入 raea；写出与旧裁决的差异/保留。
- 验收：用户 review 通过；与 `plan-creative-workbench` §5 的差异逐条登记。

**D2. 3D 视频执行面设计（three-live）**（`docs/design/video3d-execution.md`，**草案已落盘 + 项目层/预览页编译器已实现**：`core/video3d/video3d_project.dart` / `video3d_player.dart`，25 例测试）
必须回答：
1. 场景合成：`scene3d.json` 如何确定性编译成 three-live 可执行的 `src/scene.js`（复用
   3D 的 scene 编译器/材质约定，还是视频专用编译器？）；节点/灯光/相机/glTF 的资源边界。
2. 时间/镜头：镜头表/相机运动如何驱动场景；固定 30fps、`seek(t)` 重置+重放；确定性
   （随机种子、无 wall clock）；同输入同帧的验收口径。
3. 帧证据：经现有 WebView 截图/`runJavaScript` 桥如何抓取帧、落 `artifacts/renders/`；
   WebView 首帧/合成延迟、分辨率、失败降级怎么处理。
4. 性能预算：1080×1920/30fps 在桌面 WebView 的可达性；是否需要降低预览分辨率；
   移动端是否延后（默认桌面先行）。
5. 借鉴清单：raea 的 composition/帧模型、词级时间、`check` 输入面、story 契约中哪些
   进我们的校验/QA，不引其运行时。
6. 不引入边界：不引 React/Bevy/JS 运行时、不把 raea CLI 作为依赖、不做第二套 agent。

**D3. 3D 视频数据契约**（`docs/design/video3d-contract.md`，**草案已落盘 + 契约核心已实现**：`app/lib/core/video3d/video3d_contract.dart` / `video3d_compile.dart`，48 例测试）
- `scene3d.json` / `screenplay3d.json` v1 字段、路径白名单、体积上限、缺资产显性失败；
  与 3D 建模 `scene.json` 的关系（只读兼容/不混写）。
- 与 story-short 的 8 段脚本/词级时间/镜头表/look 参数映射；toon_3d 只作为 style 候选。
- 验收：schema 正反例 + 一个 5s 单镜头映射示例通过设计评审。

**D4. 工作台与最小面**（`docs/design/video3d-workbench.md`）
- 3D 视频工作台形态：镜头表/时间线/预览/帧证据/状态；与 `WorkspaceChrome`/双面的接入。
- 工具面：`video3d_create`（最小）/`video3d_status`/`video3d_render_frames`（命名实现时定）；
  agent 只写 JSON；工具失败人话映射。
- `artifacts/` + `judge/` 目录骨架（不实现完整盲评/评分）。

**D5. POC 计划与验收**（`docs/design/video3d-poc-plan.md`）
- 最小 POC：把固定 `scene3d.json` + 一个镜头编译成 three-live 页面，在无 UI 下手动/脚本
  抓 5s（150 帧中抽取 5 帧）PNG；再验证 `seek(t)` 同帧。
- 只验证可行性与确定性，不交付产品功能；失败即回报用户，不硬撑。

**D 门（用户 review）**：双轨 ADR + three-live 执行面设计 + 数据契约 + POC 计划通过后进 P1。

### P1 · 3D 视频 POC（2–3 天，设计门后）

| 批 | 内容 | 验收 |
| --- | --- | --- |
| P1.1 | `scene3d.json` → three-live 页面组装（复用现有 `assembleThreePreview`/预览资源） | 页面能跑；无外部网络；构建可重复 |
| P1.2 | 固定帧抓取（5 帧）+ `seek(t)` 重置重放 | 同输入同帧或差异记录；证据落盘 |
| P1.3 | 性能/首帧/分辨率基准；失败降级路径 | 数字报告 + go/no-go |

**P1 门**：go/no-go 交用户；no-go 则 3D 视频回到设计/范围收缩（不硬造替代引擎）。

**P1 进展（2026-11-25）**：契约核心/项目存储/自包含预览页编译器与 `plugin:video3d` 只读工作台已落地；
剩真机 WebView 渲染 smoke 与「真 three 执行面」裁决。

### P2 · 3D 视频最小纵切（1–1.5 周，P1 go 后）

只做一条可演示链路：
- 数据：`scene3d.json` + `screenplay3d.json` 样例 → three-live 预览（5–10s、单镜头）。
- 工作台：最小视频项目存储（project store）+ 预览面 + 状态/失败人话 + 双面阶段线/结果卡。
- 工具：`video3d_create` / `video3d_status` / `video3d_render_frames`（最小）→ agent 只写 JSON。
- 证据：`artifacts/renders/` 帧/contact sheet；`judge/` 目录骨架（不实现完整评分）。
- 验收：端到端 demo；analyze/test/build 绿；不引入新运行时/第二套 agent。

### P3 · 常规视频保持（0–1 天）

- 跑 v1 clip/矢量视频回归；确认 `screenplay.json` 未实现部分不在本轮施工。
- **不迁移常规视频底座**；Phaser 3 引擎短片继续冻结（§7）。

### U · 工作台 UI 独立适配（并行批次，详见 plan-workbench-ui.md）

按用户顺序 **设计 → 3D → 视频 → 音乐** 分批；热应用暂不动。与视频双轨互不替代：

| 批 | 内容 | 依赖 |
| --- | --- | --- |
| UI-0 | `workbench_layout.dart` 独立规格 + 设计面接线（本批已开工） | 无 |
| UI-1 | 设计工作台：画布优先/面板折叠/画板条/浮动工具条 | UI-0 |
| UI-2 | 3D 工作台：大纲 + 检查器 + 建模工具条骨架 + 状态底栏 | UI-0；gizmo 等 3D 视口批次 |
| UI-3 | 视频导演台：剧本/镜头树 + 时间线 + 检查器 | UI-0；常规视频时间线，3D 视频预览等 P1 |
| UI-4 | 音乐：谱面 + 声部/运输条/混音器 | 音乐模块契约 |

## 4. 依赖关系

```
M0 收口
  └─ D1/D2/D3/D4/D5（设计）── 用户 review ──┬─ P1 POC ── go ── P2 3D 视频纵切
                                             └─ no-go → 回报用户/范围收缩
P3 常规视频回归（独立，可与 D 并行；不阻塞）
```

## 5. 决策点

| # | 决策 | 影响 |
| --- | --- | --- |
| D-1 | 3D 视频风格：`toon_3d`（2D 角色+3D 世界）作为候选，还是先做纯 3D 世界镜头？ | 影响 D2/D3 与 POC 场景 |
| D-2 | 3D 视频数据格式：独立 `scene3d.json`/`screenplay3d.json`，还是复用 3D 建模 `scene.json` | 影响事实源分离与资产复用 |
| D-3 | 帧证据/预览分辨率：1080×1920 还是先 720×1280；桌面先行还是含移动 | 影响性能预算与平台承诺 |
| D-4 | 成片导出是否开、如何开（默认屏蔽） | 影响 P2 范围，未裁决不动 |
| D-5 | 常规视频是否仍保留 Phaser 3 引擎短片计划 | 默认冻结，不在本轮 |

## 6. Definition of Done（每批）

1. 设计文档先于实现；状态行 + 决策台账 + README 索引同步。
2. 每批一条可验证链（design review 或测试）；未验证的「应该能跑」不算完成。
3. `flutter analyze` + `flutter test` + `flutter build linux --debug` 绿（已知 env 失败登记）。
4. 失败路径显性：WebView/资产/帧抓取失败都有用户可见人话 + 技术详情，不静默成功。
5. 文档中「raea 不引入/只借鉴」与「3D 视频用 three-live」表述一致，不留旧嵌入方向。

## 7. Backlog（明确移出本轮）

- **raea 嵌入**：已由用户最终裁决关闭（只参考，不引入）；不重开、不做 Rust/FFI POC。
- 音乐编曲模块、视频→音乐联动、TTS/sherpa-onnx、pixelfx VFX、`toon_3d` 正式化。
- Phaser 3 引擎短片（常规视频第三渲染面）——除非 D-5 另行裁决。
- 3D 建模视口（大纲/视口/gizmo/检查器）、GLB 导出、多视角 `three_render_views`、3D judge/score、
  六层 pass 轮次。
- 设计模块进一步视觉盲评/校准；`material-painter` 外部 MCP；评分阈值校准。
- 上述项目保留原方案文档与契约，不因 backlog 删除；重开时先过对应决策门。

## 8. 第一周任务清单（建议）

- [ ] Day 1（M0）：拆提交、清 WIP 分支、`.zcode` 处理；确认文档已回到「raea 不引入」。
- [ ] Day 2（D1/D5）：视频双轨 ADR 初稿；POC 验收指标与风险清单。
- [ ] Day 3（D2）：three-live 3D 视频执行面设计初稿（场景合成/时间/帧证据/性能）。
- [ ] Day 4（D3/D4）：`scene3d.json`/`screenplay3d.json` schema 草案；工作台/工具最小面设计。
- [ ] Day 5：设计 review（用户参加）；通过后排 P1 POC 工程任务。

## 9. 成功判据（本计划结束）

- 视频双轨 ADR、3D 视频数据契约与 three-live 执行面设计通过 review；范围没有再次铺宽。
- P1 给出可复现的帧证据 POC 报告（同输入同帧/差异记录）；go/no-go 有数字依据。
- 若 go：P2 产出一条 3D 视频端到端 demo（5–10s、单镜头、确定性帧），接入最小工具面与双面。
- 若 no-go：不引入替代引擎、不硬造，把技术结论回报用户并更新决策台账。
