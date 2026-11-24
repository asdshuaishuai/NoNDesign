# Material Painter 调研：全领域 3D 材质能力候选（GPL 阻塞，参考 / 可选外部工作站）

> 状态：**调研结论（2026-11-24）**，供 3D 工作台的材质能力规划使用。
> **未安装、未运行**；事实来自 `README.md`、`Cargo.toml`、`LICENSE`、`AGENTS.md`、
> `src/mcp.rs`、`src/app/mcp_tools.rs`、`src/export.rs` 与 release workflow。
>
> 用户假设（2026-11-24）：Material Painter 可作 **全领域 3D 的材质能力**。本文结论：
> **能力面确实覆盖得最全，但 GPL-3.0-or-later + 仅 GUI 二进制、无库 API，不能嵌入
> 我们的产品**；可作为参考，以及**可选的外部材质工作站（MCP）候选**——后者是
> 政策例外，需用户单独裁决，当前不施工。
>
> 关联：[plan-creative-workbench.md](../plan-creative-workbench.md) §4 ·
> [skills/creative-workbench/references/3d-pipeline.md](../skills/creative-workbench/references/3d-pipeline.md) §12 ·
> [research/raea.md](raea.md)（3D/短剧引擎候选） ·
> [research/3dcodeverse.md](3dcodeverse.md)（3D harness）。

## 0. 结论先行

1. **它是什么**：`alla2001/material-painter` 是 Rust + wgpu 的 **PBR 纹理绘制 /
   烘焙 / 材质设计**桌面应用。不是运行时材质库，也不是 three.js 材质系统；它
   产出的是**贴图与材质资产**（base color、roughness、metallic、normal、height、
   emission、opacity、AO 等），可导出到 Unreal / Unity / Godot / glTF / Roblox /
   Blender。
2. **能力面**：层栈（paint/fill/folder）、8 个通道、笔刷/对称/投影、按三角形/
   quad/面循环/UV 岛/材质/UDIM 的多边形填充、纹理集、智能材质与智能遮罩、
   AO/曲率/腔体/厚度/法线/高度/位置/世界法线/ID 烘焙、自定义 bake map、
   节点图 Material Designer、WGSL Shader Maker、多组导出预设（Unreal / Unity
   URP/HDRP/Built-in / Godot / glTF / Roblox / Blender + 自定义）、8/16/32-bit
   PNG/TIFF/TGA/JPEG/EXR、约 2,900 个 CC0 素材、`.spp` 导入、可选 MCP。
3. **硬阻塞**：
   - **许可证**：**GPL-3.0-or-later**，强 copyleft。代码是 GUI 应用，`Cargo.toml`
     `publish = false`，没有 `[lib]`，只有 `src/main.rs` 二进制；若我们的产品
     不是 GPL 兼容，把代码嵌入/链接进去，或分发修改版，会触发 GPL 义务。
     不能按「MIT 工具」处理。
   - **形态**：不是库，是 UI 线程驱动的完整应用；没有 headless CLI / batch
     模式。MCP 也要应用开着、UI 线程在跑。
   - **政策**：外部创作工具默认「只参考、不引入」；把它作为外部材质工作站
     是**新的例外**，需要用户明确裁决（本文只登记候选）。
4. **正确用法**：
   - **v1 默认**：自建轻量 PBR 材质层（通道 schema + three-live 材质 + glTF
     导出），不依赖 Material Painter；它的通道模型/导出预设只作需求参考。
   - **可选增强**：用户自行安装并开启 Material Painter 的 MCP，作为外部
     「材质工作站」做绘制/烘焙/导出；我们不捆绑、不自动安装、不作为必需
     依赖。是否允许这条桥，待用户裁决。
   - **不做**：vendor / 嵌入 / 链接 GPL 代码；不随包分发 Material Painter；
     不复制其源码、节点图实现、笔刷/烘焙代码。
5. **它能补我们什么**：高端的纹理绘制、UV 展开、mesh map 烘焙、智能遮罩、
   节点图、WGSL 自定义节点、引擎导出预设。这些不是 v1 3D 工作台的必需项；
   v1 先把「PBR 参数 + 贴图槽 + 环境光 + glTF 导出」做对。

## 1. 事实与数据

| 项 | 事实（2026-11-24 核验） |
| --- | --- |
| 仓库 | <https://github.com/alla2001/material-painter> |
| 规模 | **349 stars / 34 forks**；默认分支 `master`；最近推送 2026-11-18 |
| 许可 | **GPL-3.0-or-later**；`Cargo.toml` `license = "GPL-3.0-or-later"`、`publish = false` |
| 最新版 | **v0.1.8**（2026-11-16）；资产含 Windows setup/zip、Linux x64 tar、macOS universal DMG |
| 技术栈 | Rust 2024 + wgpu + eframe/egui + egui_tiles；自有 GPU 绘制/烘焙 |
| 形态 | 单一 GUI 二进制 `material_painter`；`src/main.rs` 只有 `mod` 与 `eframe::run_native`；无 `[lib]` |
| 平台 | Windows 10/11 x64、Linux x64（glibc 2.35+）、macOS universal（release workflow + `scripts/package-macos.sh`） |
| 资产 | 约 2,900 个 CC0 材质（Poly Haven / ambientCG）；内置 HDRI、PBR 样例 |
| 互操作 | 导入 OBJ/FBX；导出 OBJ（带新 UV）；打开 Substance 3D Painter `.spp`（有限） |
| MCP | 可选，默认关闭；`127.0.0.1:39831` 起，Streamable HTTP + plain JSON（无 SSE），MCP 协议 `2025-06-18` |

## 2. 能力面

### 2.1 绘制与层

- 层栈：paint layer、fill layer、folder；混合模式、透明度、遮罩层。
- 通道：base color、roughness、metallic、height、opacity、emission、normal、
  specular level；每个通道都能像普通层一样绘制/填充。
- 笔刷：笔尖、颗粒、压感、稳定器、对称、屏幕/表面/UV 投影。
- 多边形填充：按三角形、quad、面循环、平面区域（角度上限）、松散部件、
  对象、UV 岛、纹理集；点击/拖拽/框选/套索。
- 路径工具、克隆/涂抹、模板（stencil）、3D 鼠标（SpaceMouse）、UDIM。

### 2.2 纹理集与 UV

- 多材质 mesh → 每个材质一个 texture set，各自层栈/尺寸/烘焙图/导出文件。
- 无 UV 的 mesh 导入时用 xatlas 自动展开；可替换文件 UV 并导出 mesh。
- UDIM：按 tile 拆 texture set，导出 `Name_BaseColor.1001.png` 等；Unreal/
  Maya/Blender/Houdini 可读。

### 2.3 烘焙

- AO、曲率、腔体、厚度、法线、高度、位置、世界法线、ID 等。
- 高低模匹配、cage、按名称匹配；cage 可视化/自动修复。
- 自定义 bake map：流体方向、风暴露、侵蚀、沙/雪堆积、部件接触、点到
  距离等。
- 烘焙质量 Draft/Standard/High/Ultra；分辨率可选。

### 2.4 材质设计

- Material Designer：节点图生成可平铺纹理，驱动 fill layer 与遮罩；实时
  预览 + 3D 视图。
- Shader Maker：WGSL 自定义节点，语法高亮、实时预览、编译错误定位。
- 预览着色器：toon、clay、unlit、rim light，或自定义节点图。
- 智能材质/智能遮罩：边缘磨损、污垢、灰尘、雨痕、滴落、腔体污渍等；
  遮罩滤镜（levels/blur/warp/noise breakup）。

### 2.5 导出

| 预设 | 通道打包 |
| --- | --- |
| Unreal Engine | BaseColor、Normal(DX)、OcclusionRoughnessMetallic、Emissive |
| Unity URP | BaseMap、Normal(GL)、MetallicSmoothness、Height、Emissive |
| Unity HDRP | BaseMap、Normal(GL)、MaskMap、Height、Emissive |
| Unity Built-in | Albedo、MetallicSmoothness、Normal(GL)、Height、Emissive |
| Godot 4 | Albedo、ORM、Normal(GL)、Height、Emissive |
| glTF PBR | baseColor、occlusionRoughnessMetallic、normal |
| Roblox | Color、Normal、Roughness |
| Blender | BaseColor、Roughness、Metallic、Normal、Height、Emissive |
| PBR Metallic Roughness | 分离通道 |
| 自定义 | 通道打包模板 |

格式：PNG/TIFF/TGA/JPEG/EXR；8/16/32-bit；UDIM 文件名模板；padding。

### 2.6 MCP

`src/mcp.rs` 的本地服务器：

- 只绑 `127.0.0.1`，默认端口 `39831`，最多往后找 9 个空闲端口。
- 默认关闭；关闭时请求返回 **503**，监听器保留端口。
- 拒绝非 localhost 的网页 Origin（DNS rebinding 防护）。
- Streamable HTTP，plain JSON（无 SSE），MCP 协议 `2025-06-18`。
- 工具调用通过 channel 交给 UI 线程执行；bake/screenshot 完成后再回复。
- 21 个工具：`get_state`、`list_presets`、`load_mesh`、`bake`、`add_layer`、
  `update_layer`、`delete_layer`、`duplicate_layer`、`move_layer`、`set_mask`、
  `set_view`、`paint_stroke`、`poly_fill`、`cage_preview`、`save_project`、
  `open_project`、`preview_settings`、`render_view`、`select_surface`、
  `screenshot_app`、`export_textures`。

这使「外部工作站」在工程上可行：我们的 3D 工作台/Agent 可以经本地 MCP
调用它，产出贴图，再把贴图接回我们的 PBR 材质槽。它仍然是**独立进程**，
不是我们的库。

## 3. 映射到我们的 3D 材质需求

| 我们的需求 | Material Painter | 我们的 v1 处理 |
| --- | --- | --- |
| Base color / metal / rough / normal / emissive / AO / alpha | ✅ 7 个绘制通道 + AO 烘焙 | 自建 `nan.material/1` 七通道，three-live `MeshStandardMaterial`/`MeshPhysicalMaterial` |
| 贴图槽、UV/tri-planar、tiling | ✅ | 贴图槽 + UV repeat/offset；tri-planar 可后置 |
| HDRI / 环境光 | ✅ 内置 HDRI + path-traced preview | three-live `PMREMGenerator` + HDRI 资产 |
| glTF / GLB 导出 | ✅ glTF PBR 预设 | 从同一份材质 schema 导出 glTF |
| 通道打包（ORM 等） | ✅ 多引擎预设 | v1 只做 glTF ORM；其他预设后置 |
| 纹理绘制 / 层栈 | ✅ 完整 | **v1 不做**；v2 可选外部工作站 |
| UV 展开 | ✅ xatlas | 后置；先要求 mesh 自带 UV |
| 烘焙（AO/曲率/厚度/法线…） | ✅ 完整 | **v1 不做**；v2 可选外部工作站 |
| 节点图 / WGSL 自定义节点 | ✅ | v1 不做；three-live 自定义 shader 后置 |
| UDIM / 多 texture set | ✅ | v1 不做 |
| `.spp` 导入 | ✅ 有限 | 不做 |
| 3D 鼠标 / 路径工具 / 模板 | ✅ | 不做 |

**关键区别**：Material Painter 是「把材质画出来/烘出来」的 authoring 工具；
我们的 3D 工作台需要的是「运行时能加载、能预览、能导出」的材质系统。两者
可以互补，但不能互相替代。

## 4. 许可与架构边界

### 4.1 GPL-3.0-or-later 的含义（按文本通常理解，非法务意见）

- 如果你分发基于 GPL 程序的衍生作品，整个作品需按 GPL 兼容条款提供源码。
- 把 GPL 代码链接进我们的闭源/专有产品，通常会被视为衍生作品；具体边界
  需法务判断。
- 通过**独立进程 + 本地协议**（MCP/HTTP）调用一个用户自己安装的 GPL 应用，
  通常不会要求我们的代码按 GPL 发布；但**分发该应用本身、修改后分发、
  或把它打包进安装器**会触发 GPL 义务。
- 我们不能把 Material Painter 的源码、笔刷/烘焙/节点图实现复制进仓库；
  也不能把它作为我们安装包的一部分。

### 4.2 形态边界

- 没有 `[lib]`，没有公开 crate，没有 headless CLI；`main.rs` 直接启动 egui
  应用，MCP 调用排队到 UI 线程。它不是可嵌入的材质库。
- 它需要 GPU（DX12/Vulkan/Metal），4K 贴图建议 8GB VRAM；作为外部工作站
  时由用户自己的机器承担。
- macOS 有 universal DMG；但仍是 GUI 应用，不是服务器。

### 4.3 政策边界

2026-11-21 用户裁决：外部创作工具只参考、不引入；3D 栈（three.js/three-live）
是明确例外。Material Painter 不在现有例外里。把它作为「可选外部材质工作站」
是**新增例外**，必须单独裁决；本文不把它写成已批准的能力。

## 5. 接入形态（按推荐顺序）

### A. 参考 + 自建 PBR 材质层（v1 默认，推荐）

- 定义 `nan.material/1`：`baseColor`、`metallic`、`roughness`、`normal`、
  `emissive`、`occlusion`、`alpha`、`textures`、`uv`、`tiling`、`colorSpace`。
- three-live 用 `MeshStandardMaterial`/`MeshPhysicalMaterial` 预览；HDRI
  环境；glTF/GLB 导出时按 glTF PBR 规则打包 ORM。
- 提供材质库（金属/木材/石材/布料/塑料/玻璃等）与确定性预览；不做绘制/
  烘焙。
- 这是唯一不引入 GPL、不增加外部进程的路线，和本文 §7 / plan §4 的 3D 能力
  分批一致。

### B. 可选外部「材质工作站」（候选，需用户裁决）

- 用户自行安装并运行 Material Painter，手动开启 MCP；我们的 3D 工作台在
  用户授权后连接 `http://127.0.0.1:39831/mcp`。
- 用途：绘制/烘焙/导出贴图；我们读取导出的 PBR 贴图，写入 `nan.material/1`
  的贴图槽，再在 three-live 里预览/导出。
- 约束：
  - 不捆绑、不自动安装、不自动启动、不作为必需依赖；检测不到就诚实提示
    「外部材质工作站不可用」，不静默降级。
  - 只连 loopback；不代理任意 Origin；限制请求体/超时；用户显式开启。
  - 版本/端口可配置；记录来源与导出文件；不修改对方工程。
  - 许可证边界：独立进程调用；不分发/修改 Material Painter；具体合规由
    法务确认。
- 这是「能力增强」，不是「内置能力」；默认关闭，文档标注外部依赖。

### C. 自研绘制/烘焙（长期，不在本轮）

- 需要层栈、笔刷、UV 展开、GPU 烘焙、节点图、WGSL/着色器图、导出预设；
  工作量接近一个独立产品。
- 只有在 B 证明需求足够、且外部工作站不能作为长期方案时才评估；不能为了
  「全领域」在 v1 吞下这个复杂度。

### D. vendor / 嵌入（不做）

- GPL + 无 lib + GUI-only，三条都指向「不做」。不进入施工清单。

## 6. 可以借什么（只借需求与契约）

1. **八通道模型**：base color、roughness、metallic、height、opacity、
   emission、normal、specular level。我们的 v1 取其中六通道（baseColor/
   roughness/metallic/opacity/emission/normal），加烘焙 AO，共七通道；
   height/specular 后置，但 schema 预留。
2. **导出预设的通道打包规则**：Unreal ORM、Unity MetallicSmoothness、
   Godot ORM、glTF occlusionRoughnessMetallic。我们只实现 glTF ORM，其余
   作为未来导出器的需求表。
3. **烘焙图分类**：AO/曲率/腔体/厚度/法线/高度/位置/世界法线/ID + 自定义
   环境图。v1 不做，但这张表是未来 bake 工具面的验收清单。
4. **层栈/智能遮罩/智能材质的 UX 语言**：paint/fill/folder、mask layer、
   generator + filter。若未来做绘制，这是交互参考，不抄实现。
5. **MCP 安全模式**：loopback、默认关闭、503、Origin allowlist、UI 线程
   队列、显式启用。我们未来若做本地 MCP 桥，可复用这些原则（不是代码）。
6. **CC0 资产来源**：Poly Haven / ambientCG；如果我们要内置材质库，按 CC0
   元数据引入，不复制 Material Painter 的库文件。

## 7. 材质能力分批

| 批次 | 能力 | 依赖 |
| --- | --- | --- |
| v1（随 3D 工作台） | `nan.material/1` 七通道；贴图槽；UV repeat/offset；HDRI/PMREM；材质库；glTF ORM 导出；确定性材质预览 | three-live；无外部工具 |
| v1.5 | 通道打包预设（Unreal/Unity/Godot）；tri-planar；简单程序化节点（noise/gradient/checker）；材质变体 | three-live shader；无需 GPL |
| v2（待裁决） | 可选外部 Material Painter MCP 工作站：绘制/烘焙/导出贴图 → 导入我们的材质槽 | 用户安装 + 开启 MCP；政策例外 |
| 不做 | 内置完整绘制/烘焙、UDIM、`.spp` 导入、3D 鼠标、路径工具、2,900 资产随包、GPL 代码嵌入 | — |

## 8. 未验证 / 待补

- 未安装/运行 Material Painter；能力来自 README、源码与 release 元数据，
  没有实测绘制/烘焙质量、性能、macOS 稳定性。
- 未实际测试其 MCP：工具列表/端口/权限来自 `src/mcp.rs` 与
  `src/app/mcp_tools.rs`，没有跑通「我们的客户端 → 它」的端到端。
- 未做 GPL 法务评估；「独立进程 MCP 是否构成衍生作品」需律师确认。
- 未验证导出的 glTF PBR 贴图在 three-live 的色彩空间/法线方向/ORM 通道
  是否完全一致；接入前要做一张标准材质球的对拍。
- 未评估 4K 贴图在用户机器上的显存/时间成本；外部工作站由用户承担，但
  我们的导入/预览也要有上限。
- 未决定「可选外部工作站」是否真的进入产品；本文只登记候选，需用户裁决。

## 9. 来源

- 仓库：<https://github.com/alla2001/material-painter>
- `README.md`、`LICENSE`、`Cargo.toml`、`AGENTS.md`
- `src/main.rs`、`src/mcp.rs`、`src/app/mcp_tools.rs`、`src/export.rs`
- `scripts/package-macos.sh`、`.github/workflows/release.yml`
- GitHub Release `v0.1.8` 资产与仓库元数据（2026-11-24 核验）
