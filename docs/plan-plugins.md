# 扩展规划：产出质量 RSI · Figma 双向 · 3D 插件 · 演示视频插件

> 2026-11-16 定稿。四个轨道，按强制性排序。核心哲学（用户定案）：**常规模型
> 无法原生达到高阶模型的一次成型能力，我们用递归视觉修复（执行 → 测量 →
> 视觉评审 → 定向修复）把它们的空间/视觉能力榨到位**——参照
> 3DCodeVerse Harness（arXiv:2610.22341）的三反馈结构（执行日志 / 空间
> 测量 / rubric 视觉评审）。

---

## 轨道 A（强制性）：Figma 双向

### 现状与可行路（leanrea 分析 + 社区调研结论）
- `.fig` 是 Figma 私有二进制（KFS 分块容器），**无公开 schema**；Figma
  官方明确警告第三方解析（file-extension.info 佐证）。fig2sketch 证明了
  逆向可行但方向是 .fig→.sketch 单向。
- Figma 桌面版（Electron 126.6.14，本机实测 asar 解包）：
  - `File → Open File Browser` 支持 **`.fig/.svg/.png/.pdf` 直接打开**；
  - 插件系统走 `manifest.json` 开发目录（ExtensionFileType:
    MANIFEST/CODE/UI，chokidar 热监听——`main.js` 实读证据）；
  - 插件 API 可以**创建真实可编辑的 Figma 节点**（Frame/Text/Rectangle…）。
- **结论（不是照抄 .fig 逆向）**：以 SVG（Figma 原生导入、矢量可编辑）+
  官方插件 API 双向桥接，保真度与可编辑性最优，零私有格式逆向。

### 实现（本轮落地）
1. **导出**：`/project/export/figma` → `NoNDesign-figma-<ts>/`：
   - 每板 `board-<id>.svg`（引擎自渲染，Figma 拖入即矢量图层）；
   - `nondesign.json`（节点树 manifest：板/节点/样式/flows）；
   - `README.txt`（导入三法）。
2. **Figma 插件源码**（仓库 `figma-plugin/`）：`manifest.json` +
   `code.js` + `ui.html`：
   - **Import**：读 nondesign.json → 逐板建 Frame，节点映射为
     Rectangle/Text/Image（真实可编辑 Figma 图层，含 fill/radius/字号）；
   - **Export**：序列化当前选区 → NoNDesign JSON（`nodes` 数组）→
     下载，粘贴进 `.mbt.md`（由 NoN 侧 `place` ops 物化）。
3. **UI**：顶栏导出菜单加「导出 Figma 包」。

### 后续（不本轮）
- .fig 只读解析（KFS zip → 部分内容提取）作为增强，跟随 fig2sketch
  的发现节奏。

---

## 轨道 B（质量核心）：递归视觉修复（RSI 循环）

### 设计（3DCodeVerse 三反馈映射到 2D 设计域）
| 3DCodeVerse | NoNDesign 对应 |
|---|---|
| 执行反馈（build/runtime 日志） | op 失败信封 / validate 门错误 |
| 测量反馈（尺寸/碰撞/连通） | engine `critique`（评分/分类/违例数）+ `lint` + `infer_missing` |
| 视觉反馈（rubric VLM 多视角） | 渲染 SVG 上屏即视觉；vision 模型选中时可加图评（后续） |

### 实现（本轮落地）
- build/refine 终态后进入 **review 循环 ≤2 轮**（固定，无新设置项）：
  1. 对每屏跑 `critique`（评分 <95 或违例>0 触发修复轮）；
  2. 把 critique findings 拼成定向修复指令再入 run（同一 agent 会话，
     前缀缓存友好）；
  3. 时间线逐轮可见（`review_round` note）；
  4. 达标（全部 ≥95 且 0 违例）或轮次耗尽即收，finish 条目记录轮数。
- prompts 增补自审清单节（对照引擎规范硬标准）。

---

## 轨道 C（插件）：3D 预览导出（3DCodeVerse 式 Three.js）

3DCodeVerse 语料含 **Three.js 场景代码**——我们的画板（绝对定位节点树）
可以无损映射为 Three.js 场景：rect→BoxGeometry(z 深度按层级)、text→
CanvasTexture 贴图平面、fill→材质色/渐变纹理。

- **实现**：`/project/export/3d` → 自包含 `board-<id>-3d.html`
  （three.js CDN + OrbitControls + 节点→拉伸盒 + 文本贴图 + 摄像机
  初始正视，可旋转/缩放/飞行）。
- **插件化**：独立端点 + 导出菜单项；后续可换 3dcodeverse 语料微调的
  模型生成真 3D 资产（GLTF 落画布 image 节点）。

---

## 轨道 D（插件）：演示视频录制

- **客户端**：play_view 加「录制」按钮——RepaintBoundary 逐屏截帧
  （自动按 flow 走一遍演示路径，每屏 2s × 30fps 采样），PNG 落
  `~/Documents/NoNDesign/frames-<ts>/`。
- **编码**：ffmpeg 在场直接合成 mp4（跨帧插值用 -framerate 30）；不在场
  生成 `make-video.sh` 一键脚本。
- **后续**：接视频生成模型（图首帧 → 运镜视频）作可选增强。

---

## 优先级与状态
| 轨道 | 状态 |
|---|---|
| A Figma | **本轮落地**（强制性） |
| B RSI 循环 | **本轮落地**（质量核心） |
| C 3D 导出 | 本轮骨架（端点+导出器） |
| D 视频 | 本轮骨架（录帧+ffmpeg 脚本） |
