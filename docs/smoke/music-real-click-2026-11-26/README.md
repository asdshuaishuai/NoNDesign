# 音乐工作台真机点击实测（2026-11-26，Linux / WebKitGTK）

本目录是**真实客户端进程**上用手动鼠标点击得到的验证记录，不是单元测试或自动化脚本。

## 环境与方法

- 真实应用：`flutter run -d linux --debug`（GTK + WebKitGTK，容器内 `unshare -rm` 把宿主
  `webkit2gtk-4.1` 库目录 bind 到硬编码路径），`NONDESIGN_VIEW=plugin:music` 开局即音乐工作台。
- 引擎主路径命中：启动日志 `[engine] runtime: EngineRuntimeInfo(webview linux … 78 exports, fuel=false)`。
- 测试数据：`~/Documents/NoNDesign/portfolio/music/manual-smoke/score.json`
  （4 小节 × 4 个四分音符 C5，120 BPM，4/4，C 大调）。
- 点击方式：X11 `XTest` 合成鼠标事件（真实坐标来自运行中应用导出的控件矩形，
  不是截图猜测）。点击对象：`music-transport-play`（24×24 图标按钮，窗口内 (66,651)）、
  进度条左端（归零）、`music-view-staff` / `music-view-roll` 视图切换标签。

## 实测结果（可量化）

| 操作 | 观测 | 数值 |
| --- | --- | --- |
| 点「钢琴卷帘」标签 | 主内容区画面从五线谱切换为卷帘网格 | 内容区像素变化 **49.4%** |
| 再点回「五线谱」 | 切回五线谱 | 内容区像素变化 **49.4%** |
| 进度条左端点击 + 点「播放」 | 运输条状态变化（播放/进度显示） | 运输条区域像素变化 **0.93%**（整窗 0.17%） |

运行中真实状态（通过 Dart VM Service 在应用内执行诊断表达式读出）：

```
entries=1 names=demo
PROBE2 verified=true plan=true events=16 ticks=61440 measures=4
```

即：项目被列出、乐谱校验通过、播放计划有 16 个事件（61440 ticks = 4 小节 × 4 拍 × 3840 ppq），
`MusicPlaybackSurface` 状态文案为「可以播放」。

## 截图

- `before-click.png`：点击前的音乐工作台（五线谱 + 演奏面 + 运输条）
- `after-click-play.png`：点「播放」后的同一窗口

## 结论与边界

- 客户端在本机真实跑起来并正确渲染：左轨道/标题栏/项目菜单/乐章面板/五线谱/演奏面/运输条/
  右侧聊天栏/状态栏都在。
- 真实点击有响应：视图切换与播放键都产生了可见的界面变化。
- **边界**：像素变化只证明界面响应，不证明"听起来对"。音频时钟的正确性由
  `integration_test/webview_pages_test.dart` 在真 WebView 里验证（播放 1.5s 后播放头
  `positionAfter≈1.52`、`beat` 桥有回传）。主观听感仍需人耳验收。
