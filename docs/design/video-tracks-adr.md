# ADR：视频双轨（常规视频 / 3D 视频）

> 状态：**设计草案（2026-11-25，D1）· 未施工**。本文冻结视频双轨的边界；冲突以
> [docs/README.md](../README.md) §2 决策台账为准。
>
> 关联：[plan-next-iterations.md](../plan-next-iterations.md)（D1/D2/D3）·
> [video-clip-contract.md](../video-clip-contract.md)（常规视频 v1）·
> [video-screenplay-contract.md](../video-screenplay-contract.md)（剧本目标态）·
> [3d-pipeline.md](../skills/creative-workbench/references/3d-pipeline.md)（3D 执行面/门）

## 1. 裁决

视频拆为两条**内容形态不同**的轨道，不共用渲染器，只共用上层创作语义与评审规范：

| | V-A 常规视频 | V-B 3D 视频 |
| --- | --- | --- |
| 形态 | 2D/矢量/动效/图表/漫画风格短片 | 代码化 3D 世界/角色/镜头短剧 |
| 事实源 | `screenplay.json`（目标）/ 现有 timeline+spec（v1 现状） | `scene3d.json` + `screenplay3d.json`（D3） |
| 执行面 | Dart `VideoDocument.frameSvg(t)` / 自包含 DOM clip（现状）；Phaser 引擎短片是 backlog | 现有 **three-live 沙箱**（`webview_all`，自包含 HTML，零外联） |
| 时间轴 | 30fps 整数帧；v1 桥播放/暂停/seek | 30fps 整数帧；WebView 预览 + 帧证据；`seek(t)=重置+按帧重放` |
| 产物 | 应用内播放；导出仍按 v1 裁决屏蔽 | 帧/contact sheet 证据 + 应用内预览；导出默认屏蔽（另裁决） |
| 与 3D 建模工作台 | 无 | 共用 three-live/资源格式，但**项目事实源分开**（不混写 3D 建模项目的 `scene.json`/`src`） |

## 2. 为什么不引入新引擎

- raea 只参考、不引入（FSL/形态/架构，见 `docs/research/raea.md`）；
- 常规视频保持现有 v1 表面，不因 3D 视频迁移底座；
- 3D 视频不替换 three-live 建模面，只新增一条「镜头化 3D 短片」路径；
- 不引入 React/Node/Chromium/Remotion/Blender/Python 运行时。

## 3. 共享语义与隔离

* 共享：blind judge 证据规范、`artifacts/judge/rNN` 目录纪律、30fps 整数帧、
  「代码/JSON 是事实源、产物是派生」、失败显性降级。
* 隔离：两轨的 schema、渲染器、预览控制器独立；不得把常规视频 timeline 直接喂给
  3D 执行面，也不得把 3D scene 塞进 v1 clip 播放器。
* 跨轨联动（若未来需要）必须是显式裁决的新通道，不默认开放。

## 4. 开放问题（不阻塞 D2/D3 草案）

1. V-A 是否恢复 Phaser 3 引擎短片？默认仍 backlog。
2. V-B 导出格式（帧序列 / mp4 / glb）与导出时机；默认只做应用内预览+证据。
3. 移动端 V-B 是否降分辨率/只读，桌面先行。
