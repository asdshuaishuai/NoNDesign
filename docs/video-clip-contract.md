# 动效合成（HTML/CSS/JS 短片）契约 v1

> 状态：**v1 契约生效中**。2026-11-20 方案新增第三渲染面「引擎短片」（Phaser 3，
> 剧本 JSON 编译，见 [plan-creative-workbench.md](plan-creative-workbench.md) §5.0），
> 施工后另立 `docs/video-engine-contract.md`；本文的两种渲染面、`ND.scene` 纯函数
> 纪律与桥消息契约保持不变。

视频工作台从「Dart 逐帧矢量」升级为两种渲染面并存：

| 渲染面 | 内容层 | 适合 |
| --- | --- | --- |
| 矢量动画（现有） | `VideoDocument.frameSvg(t)` 纯 Dart | 科学演示、图表、可逐帧导出的算式动画 |
| 动效合成（新） | 自包含 HTML/CSS/JS 短片，WebView 内 `requestAnimationFrame` | 手绘简笔、动效排版、UI 精修演示等「精致感」片子 |

动效合成的运行时就是 `app/assets/video/clip/engine.js` + `engine.css`：它规定
「一支短片 = 一个 `ND.scene({duration, render})`」，`render(t)` 必须是**纯函数**
（同一个 t 永远画同一帧），因此可暂停、可拖动、可逐帧审查。这正是我们希望模型
和作者产出的「可验收动画」，而不是一次性播完的 CSS。

## 1. 目录与文件

```
app/assets/video/clip/
  engine.js          运行时（时间轴 / 缓动 / 舞台缩放 / 桥）——不要改它的契约
  engine.css         舞台、字体、通用排版令牌
  clips.json         短片目录（UI 只从这里读清单）
  sketch-friction.html   已有：手绘简笔 · 摩擦力
  <id>.html          每支短片一个文件（自包含）
```

`app/pubspec.yaml` 必须包含 `- assets/video/clip/`，否则运行期读不到。

## 2. 页面骨架（每支短片都必须长这样）

```html
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>短片标题</title>
  <style>/* 本片专属样式；可以用 engine.css 的令牌（--ink / --paper / --accent / .nd-hand …） */</style>
</head>
<body>
  <div id="nd-viewport">
    <div id="nd-stage">
      <!-- 所有画面元素都放在 #nd-stage 里；舞台逻辑尺寸固定 1280×720 -->
    </div>
  </div>
  <script>
    (function () {
      'use strict';
      var stage = document.getElementById('nd-stage');
      // …取元素、写 render(t)…
      function render(t) {
        // 只根据 t 更新 DOM / SVG 属性；不要读 Date.now()、不要 setTimeout、
        // 不要 Math.random()（需要随机感就用确定性的伪随机：sin(i*12.9898)）。
      }
      ND.scene({ duration: 12.0, title: '短片标题', render: render });
    })();
  </script>
</body>
</html>
```

加载顺序由 Flutter 侧保证：`engine.css` 注入 `<head>` 末尾、`engine.js` 注入
`</body>` 之前，因此短片的脚本可以安全地使用 `ND`。

## 3. 运行时 API（短片里唯一允许依赖的面）

- `ND.scene({duration, title, render})`：注册唯一一支短片；`render(t)` 秒。
- `ND.ease.*`：`linear / inQuad / outQuad / inOutQuad / inCubic / outCubic /
  inOutCubic / outQuart / outQuint / inOutQuint / outExpo / outBack / spring`。
- `ND.phase(t, start, dur)` → 0..1；`ND.stagger(t, i, start, step, dur)` 逐个错开。
- `ND.clamp / ND.lerp / ND.mix / ND.map / ND.fmt`。
- `ND.set(el, {style: value}) / ND.attr(el, name, value) / ND.opacity(el, v) /
  ND.translate(el, x, y, extraTransform)`。
- `ND.size = {width: 1280, height: 720}`；舞台自动按视口等比缩放居中。

禁止：外部 URL（`http(s)://`、CDN、`<img src>` 外链）、`fetch`、`localStorage`、
`eval`、`document.write`、`Math.random()`、`setInterval` 驱动画面、在 `render` 里
改 `duration`。字体只用系统字体令牌（`--hand` / `--body` / `--mono`），不下载字体。

## 4. Dart ↔ 页面桥

页面在每次 `render` 后回传状态，Flutter 侧通过 `JavaScriptChannel` 接收：

```json
{"type":"state","t":3.2,"duration":13.2,"playing":true,"loop":true}
{"type":"ready","duration":13.2}
```

发送姿势固定为：

```js
window.VideoClipBridge.postMessage(JSON.stringify(message))
```

Flutter → 页面只允许调用：

```js
window.__ndClip.play()
window.__ndClip.pause()
window.__ndClip.seek(6.4)
window.__ndClip.restart()
window.__ndClip.setLoop(true)
window.__ndClip.state            // {t, duration, playing, loop}
```

逐帧审查：加载 URL 带 `?t=6.4` 时只画该帧、不自动播放（`engine.js` 已实现）。

## 5. 短片目录 `clips.json`

```json
[
  {
    "id": "sketch-friction",
    "title": "摩擦力 · 简笔演示",
    "subtitle": "手绘纸面 + 逐笔描线 + 数值滚动",
    "style": "hand",
    "duration": 13.2,
    "file": "sketch-friction.html",
    "tags": ["简笔", "物理"]
  }
]
```

- `id` 与文件名同源（`<id>.html` 可省略 `file`）。
- `duration` 是声明值，UI 以页面回传的真实值为准。
- `style` ∈ `hand`（手绘）/ `motion`（动效排版）/ `ui`（界面演示）/ `data`（数据）。
- 目录顺序即列表顺序；新增短片必须补一条且 id 唯一。

## 6. 质量线（验收时会逐条看）

一支片子的「精致感」不来自元素数量，而来自这四件事：

1. **入场有层次**：先主体、再辅题、再注记，错开 60–140ms；用 `stagger` 而不是同时。
2. **缓动不是线性**：位置/缩放用 `outCubic~outQuint`，落定用 `outBack/spring`，
   透明度可以线性；同一动作里不要混三种以上缓动。
3. **有「手」的痕迹**：线用 dash 逐笔画出（`stroke-dasharray` + `stroke-dashoffset`），
   文字逐字落位，卡片有 1–2° 的轻微倾斜与阴影，纸面有颗粒/暗角。
4. **收尾收干净**：最后一秒有明确的落版（标题/公式/结论），不要停在半成品画面。

每支片子 8–16 秒、1280×720、循环播放不跳帧；`render(t)` 在 `t=0` 与
`t=duration-ε` 都必须画出完整合法画面（验收会用 `?t=0`、`?t=6`、`?t=12` 截图对比）。
