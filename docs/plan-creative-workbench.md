# 创意工作台交互升级与模块规范（2026-11-20 定稿，未施工）

> 状态：**方案定稿，待施工**。本文覆盖全局交互升级与四个工作台的能力/联动裁决；
> 音乐模块的技术面（谱面/合成/编译器）以 [plan-music-module.md](plan-music-module.md) 为准。
> 施工按 §7 分批，每批完成回填落地锚点。

## 0. 用户裁决汇总（2026-11-20，全部有效）

| # | 裁决 |
| --- | --- |
| 1 | 全局交互：强化工作台的**执行过程与结果**呈现；Agent 执行保持在**右侧 chat** |
| 2 | 设计 = 产品 → 交互的一站式「验证式热应用」；该产物**绑定原型本身**，**不再列入热应用模块** |
| 3 | 3D = **建模**（three.js 实现），强化工作区形态与建模能力 |
| 4 | 视频 = 用代码创造视频与动漫；新增两种场景风格（**沙雕短剧** / **美式线条漫画**）；引入**导演台**、**剧本标准**、**TTS**；**联动音乐工作台制作配乐**（继「设计→热应用」之后的第二个跨模块联动，显式裁决） |
| 5 | 音乐 = 编曲工作台（详见 plan-music-module.md），承担视频配乐联动 |
| 6 | **所有工作台必须强绑定且强规范**（结构性纪律，见 §1） |
| 7 | 视频渲染**引入游戏引擎**（2026-11-20 补充裁决）：选定 **Phaser 3**（vendored 运行时），`screenplay.json` 编译为引擎短片（见 §5.0） |

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

## 4. 3D：建模工作台强化

* 定位：three.js 实现的**建模**工作台（从「场景展示」升级为「建模」）。
* **工作区形态**：三栏 = 大纲（场景树）｜视口（Orbit 相机、网格、拾取、变换 gizmo
  move/rotate/scale、吸附）｜检查器（对象变换/材质/几何参数）。视口 = WebView 内嵌
  vendored `three.module.js`（已在库），编辑事件经桥回 Dart 落事实源。
* **事实源**：`scene.json`（`v:1`）：`nodes[{id, primitive, params, transform, material,
  parent}]` + 环境（灯光/背景）+ 相机；上限（节点 200）。既有 scene spec / pass 管线
  作为**生成管线**保留（brief → scene.json → 检查）。
* **工具面**：与强规范命名对齐 `three_list / create / read / patch / verify / inspect`；
  既有 `three_pass / three_continue` 保留为生成推进。
* **校验器**：图元参数域、变换数值有限、材质参数域、父级引用完整、节点/尺寸上限。
* **能力分批**：图元（box/sphere/cylinder/cone/torus/plane/lathe）→ 变换/复制/父级 →
  材质 PBR 参数 → 布尔（three-bvh-csg vendored，拉伸）。

## 5. 视频：导演台 + 剧本标准 + 双风格 + TTS + 配乐联动

### 5.0 引擎选型：Phaser 3（2026-11-20 裁决「引入游戏引擎」）

**结论**：引入 **Phaser 3.x**（MIT，单文件可 vendored，WebGL/Canvas 双渲染面）作为「引擎短片」的
2D 游戏引擎运行时；沿用现有沙箱——自包含 HTML + `file://` WebView + `VideoClipBridge` 桥，零外联。

**候选对比（为什么不选别的）**：

| 候选 | 结论 | 理由 |
| --- | --- | --- |
| Phaser 3 | ✅ 采用 | 完整 2D 引擎：Scene / Tween / Timeline / Arcade+Matter 物理 / 粒子 / 相机（闪白、震屏、变焦）/ 遮罩 / 滤镜 / 声音；单文件约 1.2MB 可 vendored；有 HEADLESS 模式可做确定性自检；与 `assets/video/clip/` 沙箱同构 |
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
* 平台：沿用现有 WebView 矩阵（macOS/iOS 应用内；Win/Linux 仍降级）。Windows 原生 WebView2
  接线是独立工作项（视频工作台全平台化的前置，不在本批）。

### 5.1 剧本标准（新契约文档 `docs/video-screenplay-contract.md`）

`screenplay.json`（`v:1`）：幕 → 场 → 镜头（`id`、场景、镜头语言、时长、台词
`[{role, text, tts}]`、动作、转场）。剧本是创作面**事实源**；既有 timeline/spec 由
编译产生（保持播放器与机械对照兼容）。

### 5.2 导演台（工作区形态）

剧本树 ｜ 分镜时间线（镜头条）｜ 镜头审查卡（对照检查）+ 配音轨 + 配乐轨 ｜
成片预览。四区与右侧 chat 分工同 §2。

### 5.3 双风格场景包（解释器插件，全部代码绘制）

| 风格 | 内容 |
| --- | --- |
| `silly_skit` 沙雕短剧 | 几何/简笔角色库 + 夸张弹跳运动预设（outBack/spring 参数族）+ 大字幕梗卡规范 + 点音效组 |
| `line_toon` 美式线条漫画 | 单线条人物 + 对话气泡 + 分格转场（panel wipe，相机遮罩实现）+ 滑稽物理预设 |

风格包 = 角色库（Phaser Graphics 程序化绘制）+ 运动/转场预设 + 字幕规范 + 音效组；
解释器按 `screenplay.style` 选择，确定性、零外联、零图片资源。默认风格（`default`）保留。

### 5.4 TTS（离线）

OS 音色离线渲染：macOS `say -o` / Windows SAPI（PowerShell）渲染 WAV → base64 内嵌
播放页（确定性、零网络）。台词编辑在导演台；**不做云 TTS**。

### 5.5 音乐联动（新裁决，第二条跨模块通道）

video 项目 `musicRef` 指向音乐项目；播放经桥接共享时钟同步，导出时混入配乐（拉伸）。
校验：`musicRef` 存在且该谱面校验通过。

### 5.6 工具面与校验器

`video_list / create / read / patch / verify / inspect` + 既有 `video_review`；
TTS 渲染 `video_tts_render`；联动 `video_link_music`。校验器：镜头时长 > 0、台词非空、
tts 行与台词一一对应、`musicRef` 合法、风格包在场。`verify` 双档：Dart schema 校验 +
播放页 `?verify=1` 引擎自检（`markers` 回传）；`video_review` 保留为人工审查面。

## 6. 音乐：编曲工作台（承接 plan-music-module.md）

工作台双面按 §1.2；配乐联动侧：音乐模块提供「播放 / 导出音频」能力给视频（共享时钟
/ 离线混音）；音频 per-track bounce 列入拉伸。

## 7. 施工分批（每批可独立验收）

| 批次 | 内容 | 验收 |
| --- | --- | --- |
| 0 | 「创意工作台」定位文案全落面（README / site / AGENTS / 主页副标题含音乐） | copy_guard 绿 |
| 1 | 强规范框架：四份契约文档矩阵 + 契约测试模板 | 模板测试全绿 |
| 2 | 全局执行/结果双面组件（进度线 + 产物卡），四工作台接入骨架 | 双面组件测试 |
| 3 | 设计：验证原型绑定原型 + `design_verify_prototype` 收口 + 迁移过滤 | §3 验收清单 |
| 4 | 3D：建模视口（大纲/检查器/gizmo 桥）+ `scene.json` 契约 | §4 校验器 + 视口测试 |
| 5a | 视频引擎接入：Phaser vendored（manifest/SHA256）+ 解释器 + `assembleEnginePlayer` + 桥 v2 + 既有样片回归 | 引擎短片单测：字节确定性 / seek 重放同帧 / 桥 v2 兼容 v1 |
| 5b | 视频：剧本标准 + 导演台 + 双风格包 + TTS | §5 契约测试 + `?verify=1` 自检全绿 |
| 6 | 音乐：按 plan-music-module 批次 1–4 | 该文档验收 |
| 7 | 视频 ↔ 音乐配乐联动 | 共享时钟/`musicRef` 校验 |
| 8（拉伸） | CSG、音频导出、MIDI、音乐局域网分享、Windows WebView2 接线 | 另立裁决 |

## 8. 明确不做 / 待裁决

* 云 TTS、采样音源、实时协作、出版级排版：不做。
* 热应用嵌音乐播放器（新跨模块联动）、验证原型是否允许独立导出包：**待裁决**，默认不做。
* 3D 布尔/曲线编辑、视频导出成片：拉伸批次。
* Godot / Unity / PixiJS / Flame 已裁决不采用（理由见 §5.0）；引擎短片 v1 **只走剧本解释器**，
  不允许 Agent 手写 Phaser 代码（保确定性与可校验性）。
