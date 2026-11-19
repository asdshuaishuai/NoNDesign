# 由产品原型生成可验证的热应用（2026-11-18 已实施）

设计 → 热应用是**唯一允许的模块间关联**（AGENTS.md 架构裁决）；本能力把它做成
一等能力并加上**确定性验证**——模型说自己做完了不算数，产物必须逐画板、逐连线
通过字节级检查。本文是完整规格；原记录在 `docs/pending-ui-fixes.md`（已迁出）。

## 1. 服务面

`HotAppService.generateFromPrototype`（`app/lib/core/hotapp_service.dart:182`）：

- **输入**：应用名、模型连接（HotAppLlmConfig）、原型规范文档
  （`prototypeMbt`，超 12,000 字符截断，`store.dart:2890`）、画板清单
  （`PrototypeScreenSpec`：id + 标题）、跳转清单（`PrototypeLinkSpec`：from + to）。
- **提示词硬性要求**（缺一条都算没完成，`hotapp_service.dart:203-210`）：
  1. 每个原型画板对应一个段落：`<section data-screen="<画板id>">…</section>`，
     页面初始只显示入口画板，其余隐藏；
  2. 每条原型跳转 from→to：在 from 画板段落内的可点元素上加
     `data-nav="<to>"`，点击切换到目标画板；
  3. 需要记住的数据一律用 `window.NoN.db`（本机数据库，无需服务器）；
  4. 零外链全内联：不出现 http(s):// 或 `//` 开头的外部资源引用；
  5. 只输出完整 HTML 文档，不要解释。
- **前置拒绝**：画板清单为空（`prototype_has_no_screens`）、模型未配置、应用名
  不合法、同名应用已存在——失败不留半成品。
- **产出**：`HotAppFromPrototypeResult { app, checks, verified }`。

## 2. 覆盖验证：字节级检查，不是模型自评

生成结果逐条跑 `_verifyPrototypeCoverage`（`hotapp_service.dart`）：

- **逐画板**：产物 HTML 里必须存在该画板的 `<section data-screen="<id>">` 段落；
- **逐连线**：`data-nav="<to>"` 必须出现在 **from 画板段落之内**——连线挂错屏
  或挂在页面别处都算缺失；
- 检查结果（`checks`）逐条带 ok / 人话摘要（如「缺少画板 settings」「缺少连线」），
  `failureSummary` 汇总缺失项。

结构门（离线 / 零外链 / CSP）**仍由 `NonAppLibrary.install` 把关**——覆盖验证是
安装之后追加的一层语义检查，两层互不替代。

## 3. verified 如实上报（不冒充成功）

- **验证未过时应用仍入库**：结构门已过、不回滚（删除产物只会让用户丢失可用的
  90% 结果）；但 `verified=false`，UI 明确告知「原型覆盖不完全」+ 缺失项摘要
  （`store.dart:2905`），**不冒充成功**。
- 入库来源带 `origin`（原型生成），便于与一句话生成的应用区分。
- 测试锚定：`app/test/hotapp_local_test.dart:315-385` 三例——
  全量覆盖 `verified=true` / 缺画板如实上报且应用仍在库里 / 缺连线该跳转检查失败
  （画板在场的检查仍为 ok）。

## 4. 入口与调用链

> 入口迁移（2026-11-19，c0cfb92）：生成入口曾短暂放在设计画布工具条，现已
> **唯一化到热应用工作台顶栏**——设计工具条刻意只保留「进入热应用工作台」
> 按钮，避免出现三个看起来一样、点了没动静的生成入口
> （`workspace.dart:657-661` 注释与 `hotapp_workspace.dart:1137-1148` 唯一入口）。
> 本节按现行入口书写。

- **入口**：热应用工作台顶栏「由原型生成」按钮（键 `hotapp-from-prototype`；
  有原型才可用，生成中显示进度并禁点——`hotapp_workspace.dart:1137-1148`）。
  设计画布工具条只有「进入热应用工作台」的入口，不再挂生成按钮
  （`workspace.dart:657-661`）。
- **store 路径**：`generateHotAppFromPrototype`（`store.dart:2829`）：
  - 守卫：重复点击防抖；无项目早退；NaN 正在工作时提示等这一轮结束；
    画布无原型时提示先生成原型；模型连接未配置时提示先去设置。
  - 端点回退：设置里没填端点时用当前模型自带的地址（空端点曾让入口
    「点了没反应」）。
  - **应用名由项目名派生并去重**（`_prototypeAppName` / `_uniqueHotAppName`）；
    一个项目只对应一个「由原型生成」的热应用——同名已存在就**原地更新**
    （先删旧再生成，删不掉时诚实报错不覆盖，`store.dart:2880-2889`）。
  - 成功 / 部分成功（verified=false）都会切换到热应用工作台打开新应用。
- **后续：agent 工具 `hotapp_from_prototype` 尚未实施**（全仓 `grep -rn
  "hotapp_from_prototype" app/ engine/` 零命中，2026-11-19 复核）——需要给
  AgentWorkspaceServices / RPC 面加方法（涉及 api.dart 远端实现与 rpc_methods
  宿主），单独一批做；届时 NaN 才能在工作区模式下直接发起这一能力，当前只能
  由用户在设计画布工具条手动触发。

## 5. 验证记录（2026-11-18）

`hotapp_local_test` 新增 3 例（见 §3），全量 `flutter test` 823 项全绿，
`flutter analyze` 0 error/warning。
