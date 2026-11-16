# 插件轨道规划（2026-11-16 用户逐轨裁决定稿）

> **边界总表**：Figma / 3D / 视频 = **客户端能力加强**，与 MoonViz 引擎
> 解耦（不改引擎、不依赖引擎产物）；**RSI 递归视觉修复 = design 模块
> 内置质量环**（原型 UI 设计用），不是插件。核心哲学（用户定案）：常规模型
> 无法原生达到高阶模型的一次成型能力，用递归视觉修复（执行 → 测量 →
> 视觉评审 → 定向修复）把它们的空间/视觉能力榨到位——参照
> 3DCodeVerse（arXiv:2610.22341）三反馈结构。

执行顺序（用户批准）：**A → B → C → D**，每轨独立提交、门禁全绿再进下一轨。

---

## A · Figma 双向（强制性）—— ✅ 已落地（fix 72491c6）

- 服务端 `/project/export/figma`：每板引擎自渲染 SVG + nondesign.json
  manifest + README，落 `~/Documents/NoNDesign/NoNDesign-figma-<ts>/`。
- figma-plugin/（manifest.json + code.js + ui.html）：Import nondesign.json
  → Frame/Text/Rectangle 真实可编辑图层；Export 选区 → NoNDesign JSON。
- 客户端：项目菜单「导出 Figma 包」。
- **两处真机实证修复**（72491c6）：
  ① 路由错挂 `/acp/prompt`（FastAPI 同路径先注册者胜出 → ACP 对话全部
  422）→ 改回正确路由 + body 传 mbt（大文档不进 query，h11 头 16KB 上限）；
  ② 插件 Import 读顶层 n.x/n.w——manifest 几何在 `n.rect`，顶层全
  undefined → 图层塌原点；geomOf() 兼容读取 + 按钮组件 Frame+Text 组合。
- 真机验证：uvicorn 起服 → /acp/prompt 恢复 ACP 语义 → 出包 2 板全字段。

## B · 代码生成视频引擎（独立插件，与引擎完全无关）—— ✅ 本轮落地

**范围（用户裁决）**：不只是科普——全套代码可生成视频：理化生地数学
教育演示、简笔画、经典影视简单复刻、观赏性动画（沙雕风格）。**双强制
纪律**：规范/剧本先行（管线硬门）+ RSI 递归评审。

### 落地面（plugins/video-engine/）
- **spec 硬门**：timeline 必须携带 spec（science：定律/假设/参数量纲/
  公式/事实核查清单；screenplay：风格锚/调色板/角色部件/beats/gags），
  缺失 → `spec_missing` exit 2。规范即环②的对照物。
- **expr 符号声明闭包**：数值属性可写 `{"expr": "0.5*a*t*t"}`，自定义
  标识符必须在 spec.params ∪ spec.formulas——「想当然」的裸坐标进不来
  （`undeclared_symbol` 拒绝）。物理演示的位置由公式算出，不靠手绘。
- **元素**：text（含 textValue 实时读数）/ rect / circle / ellipse /
  line / arrow / polyline / image；anim（fade/rise/pop）+ motion
  （linear/orbit/path，值可 expr）。
- **RSI 三环**：① render 内结构校验（含渲染前全量预编译 fail-closed）
  ② review.py 机械对照（符号闭包/beats 落片长/facts 形状）
  ③ 抽帧+对照提示词 → 评审 agent vision 打分（修复 ≤3 轮）。
- **冒烟实证**：三示例全链路出片；确定性（同 timeline 同 md5）；物理
  读数 v=17.47=3.882×4.5 精确吻合；undeclared_symbol / spec_missing
  拒绝路径 exit=2 实测。
- **视频工作台（无声版，用户裁决音轨旁白暂不做）**：插件化 UI
  （plugin:video 视图）——加载标杆示例 → 环②结果面板 → 后台渲染
  （job 轮询，冒烟降帧 6-30fps 可调）→ 帧条带预览（/video/frame 带目录
  穿越防护）。art/phys 双示例端到端 done+mp4 实证。
- **真 bug 登记并修复**：含 t/T 的公式曾在 T=0 常量化 → 运动钉死起点、
  读数恒 0；现时间相关公式求值期展开（Expr 驻留 env 递归求值）。

### 后续（不本轮）
- 化学（配平校验）/数学（manim 风构造）/地理（色阶图例）规范模板细化
- 音轨/旁白（TTS 时间轴对齐）

## C · 3D 制作工作台（客户端插件）—— 🚧 C1 骨架已落地（C2 强化待接）

**定位（用户裁决）**：不是 2D 画板 3D 化预览，而是**直接制作 3D**——
LLM 生成 three.js 场景代码，**应用内 WebView 即执行面**（不引外部浏览器、
不引 headless）。与原型（DDP/引擎）并列的新项目类型，独立存储
（`~/Documents/NoNDesign/3d/`，scene.js + spec.json），不走 .mbt.md/.ddp。

- **三反馈闭环**（3DCodeVerse 式）：① 执行反馈 window.onerror 回传；
  ② 场景几何自检（物体数/AABB/相机包含）；③ `canvas.toDataURL()` 截图
  （renderer preserveDrawingBuffer）→ vision 评审。WebView reload 即迭代。
- **吸收 img2threejs 设计理念**（用户点名强化）：
  - 分阶段雕塑，永不一次性出场景：blockout → structure → form →
    material → lighting → interaction 分 pass 生成，每 pass 只碰当前层；
  - spec 先行 + 质量契约（组件层级/材质/灯光/锚点/复杂度评估）+
    detail inventory（身份细节必须映射 spec 条目，不许 prose）；
  - build-state.json 状态门禁：每步先查状态、完成必带 evidence，禁止从
    对话记忆重建进度；修复轮上限（每 pass 3 次/总 6 次）；
  - **确定性几何门先行，AI vision 殿后**：turntable 四方位截图（单视角
    不是证据）、自相交检测、attachment anchor 校验，全过才轮到 vision；
  - fail-closed：门不过不交付，BLOCKED 保留证据 refine-spec，不许通用
    场景糊弄；生成代码不是重建决策的唯一副本（手改回灌 spec）。
- **C2 强化（本轮落地）**：turntable 四方位取证（单视角不是证据——
  0/90/180/270 相机环绕各截一帧进 evidence，tag 命名）；规范手编回灌
  （/three/spec/save + 工作台「规范」pane——img2threejs 纪律：手改落
  spec 不许只改代码，components/acceptance 门复检）。
- 输入模态：文字 brief / 参考图（img2threejs 式图→程序化 3D 重建：
  macro→meso→micro 分层观察、身份特征清单、单视角盲区显式声明）/ 图+文。
- 技术底座已预验证：webview_flutter_wkwebview 3.27.2 macOS 支持 +
  `WebKitWebViewPlatform.registerWith()`（真实 API 名）+ profile 构建链接。
- **C1 落地明细**（本轮）：server/three_agent.py（new→spec 生成 / run_pass
  分 pass 生成 / feedback 三反馈 / continue 状态推进 / blocked fail-closed
  上限每 pass 3 轮）；端点 /three/*（preview 页含执行错误桥 window.onerror、
  测量桥 __measure、截图桥 __non3d_screenshot，2s 节流）；客户端
  three_workspace.dart（新建表单→spec→生成当前层→截图→通过并继续；
  JavaScriptChannel NON3D 自动转发三反馈；pass 状态 chips；⌘5 进视图）。
  mock LLM 全链 E2E 11 步全绿（含重复生成守卫/修复轮/blocked 打满/
  preview 三桥/scene serve）。真 bug 登记×2：① main.py 的 three_agent
  import 曾置于 sys.path 注入前（ModuleNotFoundError）；② Path.open 位置
  参数陷阱（"a","utf-8" 把 encoding 当 buffering）；③ new_project 的
  mkdir 曾在 LLM 成功前执行（失败残留目录 → project_exists）。
- 后续：GLTF 真 3D 资产（3dcodeverse 语料模型）、动画时间轴、多场景分镜。

## D · RSI 审查与增强（design 模块内置）—— 📋 待施工

- 审查 agent.py review 循环对 0.2 引擎 critique 信封（results[].
  verdict poor/good）的解析正确性；
- （可选增强）SVG→PNG 抽帧 → vision 图评进 run 循环。

---

## 状态总表

| 轨道 | 状态 | 提交 |
|---|---|---|
| A Figma 双向 | ✅ 落地（含两处真机修复） | 72491c6 |
| B 视频引擎 | ✅ 落地（spec 硬门 + expr 闭包 + RSI 三环 + 三示例） | 本轮 |
| C 3D 工作台 | 🚧 C1 落地（spec 先行 + 分 pass 状态门禁 + WebView 执行面 + 三反馈桥 + fail-closed 全链 E2E）；C2 强化（turntable 四方位门/自相交检测/spec 手编）待接 | 本轮 |
| D RSI 审查 | 📋 待施工 | — |
