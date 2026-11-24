# 设计模块契约（验证式原型 · 绑定设计项目本身）

> 状态：**已实施（R1 设计模块，2026-11-24）**（R0 契约冻结后完成：项目内验证原型 + 工具收口 + UI/双面 + 迁移过滤）。本文是设计模块
> 的契约增量：事实源、原型产物、覆盖验证、工具收口、迁移与验收；细节不重复方案与已实施文档。
> 落地锚点见 §8。
>
> 相关：[plan-creative-workbench.md](plan-creative-workbench.md) §3（方案事实源）·
> [hotapp-from-prototype.md](hotapp-from-prototype.md)（现行覆盖验证 + 2026-11-20 修订注记）·
> [AGENTS.md](../AGENTS.md) 唯一事实源边界 ·
> [skills/creative-workbench/SKILL.md](skills/creative-workbench/SKILL.md) §3（design 只借 intake/judge）·
> [creative-refactor-decisions.md](creative-refactor-decisions.md)（R0 冻结与缺口）。

## 1. 定位与事实源

* 设计项目 = 产品 → 交互的一站式：PRD / UI / `DESIGN.md` → 画布原型 → **验证原型**，
  同项目闭环（plan §3）。
* 事实源不变：canonical `.mbt.md`（人类画布操作与 agent 操作都经引擎校验回写同一份文档）
  + `DESIGN.md` / DDP 容器；验证原型是**派生证据**，不是第二事实源。
* 设计 ≠ 热应用模块：验证原型**绑定项目本身**，不进热应用列表；热应用继续保留
  手工 / 导入 / agent 独立创建的作品。

## 2. 原型产物与容器

* 落位：设计项目**单文件 `.ddp` 的 docs 元数据**里新增 `prototype` 段
  （`nan.design.prototype/1`：`html` + `manifest` + `verified` + `checks` + `builtAt`）；
  不另开 sidecar 目录，项目复制/移动不丢原型。理由：`.ddp` 容器只承载一份源文档，
  单文件可携带是产品红线。
* 产物是**自包含 HTML + manifest**，零外联；自包含 = 不出现 `src/href/url()/@import`
  指向 `http(s)://` 或 `//` 外部资源（`xmlns="http://www.w3.org/2000/svg"` 命名空间放行）。
* HTML 由**确定性构建器**从 canonical render 信封派生（每屏嵌引擎自渲染 SVG，
  `data-screen`/`data-nav` + 内嵌 manifest + 切屏 JS）；**不调用模型**。
* 修订回到 canonical `.mbt.md` 再重新生成，不直接手改产物当事实源。
* manifest 字段冻结（2026-11-24）：`schema/project/entry/screens(id,title,width,height)/
  flows(from,to,trigger)/builtAt`；checks id 族 `screen_*` / `flow_*` / `entry_screen` /
  `offline` / `self_contained_manifest`。改字段先改契约测试。

## 3. 覆盖验证规则（确定性，不是模型自评）

规则逐条实现自 [hotapp-from-prototype.md](hotapp-from-prototype.md) §2–§3，本文只给契约口径：

| 检查 | 规则 | 失败语义 |
| --- | --- | --- |
| 每屏 | 每个画板必须存在 `<section data-screen="<画板id>">` 段落 | `verified=false` + 缺屏清单 |
| 每条连线 | `data-nav="<to>"` 必须出现在 **from 画板段落之内**（挂错屏/页面别处都算缺失） | `verified=false` + 缺连线清单 |
| 确定性 | 字节级检查，不采信模型自报「已完成」 | 逐条 ok / 人话摘要 |
| 结构门 | 离线 / 零外链 / CSP 仍由安装门把关；覆盖验证是**追加**语义层 | 两层互不替代 |

* **verified 如实上报**：未过时原型仍入库（不回滚已可用的部分），但 UI 明示「覆盖不完全」+
  缺失项摘要，**不冒充成功**（hotapp 同族纪律）。
* 检查是纯函数（`verifyPrototypeCoverage` 族）；「失败不阻断入库」只对语义层成立——
  结构门失败仍拒绝安装。测试锚点见 §8。

## 4. 工具收口（`design_verify_prototype`，已实现）

* 工具面归属设计模块：`design_verify_prototype`（**已实现**）；旧工具
  `hotapp_from_prototype` 已退役（不得双入口并存）。产物落项目 docs 元数据，
  不再生成独立热应用包。
* 输入面：`bridge.session(session_list_artboards)` + `session_flows`（与旧链路同源），
  store 侧用 run 的 canonical `render` 取每屏 SVG；**无模型连接参数**（不生成新应用）。
* 旧工具已退役（2026-11-24）：`hotapp_from_prototype` 从工具面/提示词/文案映射/认领链移除；
  本地库里已存在的 prototype demo 保留文件，但热应用列表只展示 `origin=app` 的应用。
* workspace 模式工具面只暴露本模块 `design_*` + 通用只读；跨模块动作只走裁决过的
  联动通道（plan §1.1）。成功产物走 `_rememberWorkspaceArtifact` /
  `_adoptWorkspaceArtifact` 认领链，工作台自动刷新（AGENTS 纪律）。
* 失败码：`prototype_empty`（画布无屏）、`engine_unavailable`（桥不可用）、
  `design_prototype_unavailable`（宿主未接线验证器）、`design_prototype_failed`（构建/落盘异常）；
  用户可见文案经 `toolFailureMessage` 映射，裸错误码不进气泡。

## 5. 入口与热应用列表迁移

* 设计工作台工具条「验证原型」+ 结果面产物卡（缩略 +「打开验证原型」）。
* 热应用工作台：**列表过滤**旧「原型验证」demo；**文件保留**、登记迁移项，不静默删除
  用户数据（plan §3）。热应用独立作品正常显示。
* 一个项目只对应一个验证原型；重复生成的覆盖策略（原地更新 vs 多份）待 R1 冻结，
  不得在列表里出现两个同名产物。
* 迁移验收：旧 demo 文件仍在、列表不出现、设计项目内原型可打开可验证。

## 6. 与 creative-workbench skill 的关系

* 设计线**只借 intake / judge 两个阶段**（[SKILL.md](skills/creative-workbench/SKILL.md) §3），
  **不引入 `spec.json` / `plan.json` / `src/` / `artifacts/` 四件套**——那会与 canonical
  `.mbt.md` 形成双事实源。
* judge 的证据形态（画布截图 / 原型帧截图）与 rubric 权重待 R1 冻结；盲评通道本身按
  [creative-refactor-decisions.md](creative-refactor-decisions.md) §1 执行
  （fresh context + 视觉能力探测 + 失败降级标记）。
* 视频 / 3D / 音乐线各自的事实源不因设计契约改变；跨模块联动仍只有裁决过的通道。

## 7. 边界与不做

* 不做「验证原型独立导出包」（plan §8 待裁决，默认不做）。
* 不把 prototype HTML 当事实源；不允许 agent 绕过引擎直写 `.ddp` / mbt。
* 不改热应用结构门、安装链路与 `.nonapp` 容器语义。

## 8. 落地锚点与验收（2026-11-24）

* 构建/校验纯函数：`app/lib/core/design_prototype.dart`（`DesignPrototypeBuilder.build/verify`、
  `DesignPrototypeDocument.toProjectMetadata/fromProjectMetadata`）。
* 项目容器：`app/lib/core/project_service.dart` 的 docs 注释读写 `prototype` 段；
  `app/lib/core/models.dart` 的 `Docs.prototype` 随 `.ddp` 保存。
* store：`AppStore.verifyDesignPrototype()`（工具栏入口）与
  `_agentVerifyDesignPrototype`（agent 工具回调）；产物卡 `artifactPrototype`。
* agent 工具：`design_verify_prototype`（仅设计 run 暴露；用 run 的 mbt 渲染取证，
  不调模型）; 旧 `hotapp_from_prototype` 已退役。
* 双面组件（2026-11-24）：`app/lib/widgets/workspace_progress.dart`（阶段条）+
  `app/lib/widgets/workspace_artifact_card.dart`（产物卡）接入设计画布：验证中显示
  build/verify/persist 进度，完成后显示结果卡（指标 + 「查看覆盖检查」对话框 + 收起）；
  状态模型 `app/lib/core/workspace_stage.dart`，store 字段
  `designPrototypeStages/designPrototypeResult/designPrototypeError`。
* 双面横幅：`app/lib/widgets/design_prototype_banner.dart`（进度线 + 结果卡 + 覆盖检查
  对话框 + 预览入口；设计画布只挂这一处，单独 widget 可测）。
* 预览：`app/lib/widgets/design_prototype_preview.dart`（`webview_all` 渲染项目内
  HTML；失败显性降级为人话 + 折叠技术详情）——结果卡主操作「打开验证原型」，
  第二动作「覆盖检查」打开逐条 check 列表。
* 测试锚点补充：`app/test/workspace_dual_face_test.dart`（阶段/失败人话/产物卡成功失败）。
* UI：设计工具条 `ValueKey('design-verify-prototype')`「验证原型」按钮；
  热应用列表隐藏 prototype demo（文件保留）。
* 测试：`app/test/design_prototype_test.dart`（构建/覆盖/元数据往返/离线）、
  `app/test/project_prototype_metadata_test.dart`（`.ddp` 注释往返）、
  `app/test/design_verify_prototype_store_test.dart`（store 落盘/未保存/空画布）、
  `app/test/dart_agent_tools_test.dart` 的 design_verify 用例 +
  `workspace_artifact_adoption_test.dart`（不误认领热应用）。

## 9. 验收锚点（后续模块 UI/迁移收尾）

| 契约面 | 拟写测试 | 锚定 |
| --- | --- | --- |
| 覆盖验证纯函数 | `design_contract_test.dart` | 缺屏 / 缺连线 / 全量覆盖三态；规则不采信模型自报 |
| 原型产物 | `design_prototype_test.dart` | `.ddp` 内 prototype 生成；自包含（零外链）；manifest 往返 |
| 工具接线 | `design_verify_prototype_test.dart` | 成功产物落项目 + 失败码人话映射 + verified 上报 |
| 入口与迁移 | `hotapp_list_migration_test.dart` | 旧 demo 文件保留、列表过滤；独立热应用不受影响 |
| 工具面收窄 | 拟扩 `dart_agent_tools_test.dart` 的 `workspace mode tool surface` | design workspace 只见 `design_*` + 通用只读，不含 `hotapp_*` |
| 项目落地 | 拟扩 `project_landing` 测试族 | 设计项目打开落设计画布，不落热应用 |
