# 代码生成视频引擎（独立插件，与 MoonViz 引擎完全无关）

LLM（或人）写 **timeline JSON**（视频程序），`render.py` 逐帧确定性
渲染：合规 SVG → resvg 光栅化 → PNG 序列 → ffmpeg mp4。教育科普
（理化生地数学）、简笔画、沙雕动画、影视简单复刻、观赏性动画都走
这一条管线。

## 双强制纪律（管线硬门，不是提示词约定）

**1. 规范/剧本先行**——timeline 必须携带 `spec`，缺失/不达标直接拒绝
（`spec_missing` / `spec_invalid`，exit 2）：

| 内容类型 | spec 形态 | 模板 |
|---|---|---|
| 物理/化学/生物/数学/地理 科普 | `science-spec`（定律/理想化假设/参数量纲/公式/事实核查清单） | [specs/science-spec.schema.md](specs/science-spec.schema.md) |
| 简笔画/沙雕动画/影视复刻/观赏动画 | `screenplay-spec`（风格锚/调色板/角色部件分解/beats 节拍表/gags） | [specs/screenplay-spec.schema.md](specs/screenplay-spec.schema.md) |

**2. RSI 递归评审**——`review.py` 环②（机械）+ 环③（agent vision）：

- 环① 结构：render 的 schema/符号校验（确定性，零成本）
- 环② spec 对照：`review.py timeline.json`——符号闭包复检、beats 落在
  片长内、facts/storyboard 形状完整性（exit 1 = fail，必须修复后重渲）
- 环③ 视觉评审：`review.py … --samples 4 --frames-dir 渲染目录
  --vision-prompt` 输出抽帧清单 + 对照提示词，由评审 agent（带 vision）
  逐条打 PASS/FAIL——**scripts do enforcement; agent vision does
  judgment**（img2threejs 原则）。任一环 fail → 定向修复 timeline/spec
  → 重渲 → 复审（≤3 轮，轨迹记录每轮 review_round）。

## 表达式驱动动画（「不能想当然」的技术落实）

数值属性（x/y/w/h/r/cx/cy/x1/y1/x2/y2/rx/ry/textValue）支持
`{"expr": "0.5 * a * t * t"}`，逐帧求值。**硬门：expr 里的自定义标识符
必须在 spec.params ∪ spec.formulas 声明**（外加内建 t/T/pi/e 与 math
白名单函数），未声明 → `undeclared_symbol` 拒绝（exit 2）。

- 物理：spec 声明 `a = g(sinθ − μcosθ)`，timeline 滑块位置写 expr——
  位置由物理定律算出来，想当然的坐标进不来。
- 时间相关公式（含 t/T）在**求值期展开**；纯参数公式常量化。
  （首版曾把全部公式在 T=0 冻结——滑块钉死顶部、读数恒 0.00，真机
  抓出后修复；含 T 公式冻结 = 运动全灭。）
- 渲染前**全量预编译**：语法/符号错误在第一帧之前报干净（fail-closed）。

## DSL 速览

```jsonc
{
  "fps": 30, "width": 1280, "height": 720,
  "background": "#0B0D12",
  "spec": "spec.json",            // 必填，相对 timeline 目录
  "scenes": [                     // 严格顺序播放
    { "duration": 3.5, "background": "#0E1220",
      "elements": [
        {"type": "text", "text": "标题", "x": "50%", "y": 64, "size": 40,
         "color": "#FFF", "weight": "700", "anchor": "middle",
         "anim": {"in": "fade|rise|pop", "dur": 0.5, "delay": 0.2}},
        {"type": "rect", "x": 0, "y": 0, "w": 100, "h": 60, "radius": 8},
        {"type": "circle", "cx": "50%", "cy": "50%", "r": 40},
        {"type": "ellipse", "cx": 0, "cy": 0, "rx": 50, "ry": 30},
        {"type": "line", "x1": 0, "y1": 0, "x2": 100, "y2": 0, "stroke_width": 2},
        {"type": "arrow", "x1": 0, "y1": 0, "x2": 80, "y2": 0, "head": 14},
        {"type": "polyline", "points": [[0,0],[50,20]], "fill": "none"},
        {"type": "image", "path": "/abs/img.png", "w": 200, "h": 200},
        {"type": "text", "textValue": {"expr": "a*t", "format": "v = {:.2f} m/s"},
         "x": 880, "y": 200, "size": 44}
      ] }
  ]
}
```

- 坐标支持数字 / `"50%"` / `"center"`；元素级 `opacity`；色值字面量
  （**颜色不支持 expr**）。
- `motion`（持续运动，值均可 expr；path 超出终点即停）：
  - `linear`：**加性偏移**——元素从自身坐标按速度 (vx, vy) 平移；
  - `orbit`：**绝对定位**——元素绕屏幕点 (cx, cy) 转圈（r/omega），自身
    x/y 被忽略（t=0 在 (cx+r, cy)）；
  - `path`：**绝对定位**——元素沿屏幕坐标折线 points 匀速走，自身 x/y
    被忽略。
  ⚠️ orbit/path 是绝对语义（位置完全由 motion 决定）——曾为加性语义，
  按「绕屏幕中心转」的自然读法写会把元素甩出画外（真机复现后改定）。
  DSL 速览里的 `image`：path 相对 **timeline 目录** 解析（同 timeline 同
  片，不随调用目录漂移）；缺失 fail-closed（`image_missing` 拒绝）；
  mime 按扩展名 png/jpg/webp。
- 字体默认 `PingFang SC`（resvg 已验证 CJK 出图）。
- 场景边界浮点容差防闪黑（t=场景结束时刻仍渲染该场景终态）。

## 用法

```bash
../../.venv/bin/python render.py examples/physics-friction/timeline.json out/
../../.venv/bin/python render.py timeline.json out/ --fps 10     # 冒烟加速
../../.venv/bin/python render.py timeline.json out/ --keep-svg   # 调试留 SVG
../../.venv/bin/python review.py examples/physics-friction/timeline.json \
    --samples 4 --frames-dir out/ --vision-prompt                # RSI 环②③
```

依赖：resvg（`brew install resvg`；回退 rsvg-convert → cairosvg）、
ffmpeg（不在场则只出帧序列并打印合成命令）。

## 标杆示例（examples/）

| 示例 | 展示 |
|---|---|
| `physics-friction/` | **真实性门面**：斜面滑块匀加速（a=3.88 m/s² 实测读数吻合）、三力箭头跟随滑块、T 连续跨场景读数 |
| `bio-mitosis/` | 五阶段示意构图 + 每阶段 facts 核查清单 |
| `art-sketch/` | 沙雕简笔：入画/蓄力/起跳抛物线（hop 公式）/落地压扁（squash 高斯窗，头 rx↗ry↘）/对白气泡 |

## 确定性

同 (timeline, spec) 永远出同一片（逐帧 `t=f/fps` 纯函数，无随机源）——
冒烟实证：两次渲染 frame_00030 md5 相同。
