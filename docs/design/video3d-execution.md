# 3D 视频执行面设计（three-live）

> 状态：**设计草案（D2）已落项目层/预览页编译器/工作台（2026-11-25，v1 为确定性 Canvas2D 预览，真 three 渲染与真机 smoke 待后续）**。目标是把 `scene3d.json` +
> `screenplay3d.json` 确定性渲染成可审阅的 3D 短片，**不引入新引擎**。
>
> 关联：[video-tracks-adr.md](video-tracks-adr.md) · [video3d-contract.md](video3d-contract.md) ·
> [three-contract.md](../three-contract.md)（three-live 执行面/确定性门）·
> [research/raea.md](../research/raea.md)（只借 composition/词级时间/check 契约）

## 1. 输入与输出

```
scene3d.json（场景事实源：nodes/lights/materials/cameras/assets）
screenplay3d.json（镜头事实源：shots/camera timeline/duration）
        │ 确定性编译（Dart 纯函数）
        ▼
自包含 single-file HTML（内嵌 three-live runtime + scene code + shot timeline）
        │ webview_all 预览/取证
        ▼
artifacts/renders/*.png（帧证据；contact sheet）+ artifacts/measurement.json（可选）
```

## 2. 场景合成

1. **复用现有 three-live 组装链路**：沿用 `assembleThreePreview` 的资源内联/离线纪律；
   3D 视频页面不联网、不加载远端 CDN。
2. `scene3d.json` 由 Dart 编译成确定性 `src/scene.js`（与 3D 建模的 scene 编译器同族，
   但不共享项目目录）；每次编译字节相同，作为预览页内联输入。
3. 资产：glTF/贴图只允许项目内相对路径白名单；缺失/越界/超大在 Dart 侧拒绝，
   不把坏 URL 交给 WebView。**不随包分发第三方资产**。

## 3. 镜头与时间

* `screenplay3d.json` 的 shot = `{id, duration, camera, cues}`；相机可以是固定
  position/target，也可以是按关键帧/参数曲线的简单路径（v1 只做固定+直线/缓动）。
* 固定 30fps；`frameIndex = floor(t*30)`；`seek(t)` = 重置场景 + 按 1/30s 步进到目标帧；
  所有随机必须种子化，禁止 wall clock/Date.now。
* 画面只由「场景 + 镜头 + 帧号」决定；同输入同帧是硬验收。
* 词级时间/beat grid 作为可选的 cue 对齐语义，来自 raea/story-short 的契约参考，
  不引入其运行时。

## 4. 预览与取证

* 预览 = 应用内 WebView（`webview_all`）；与 3D 建模共用 WebView 纪律，但控制器/页面独立。
* 帧证据：通过现有截图桥在目标帧抓 PNG；帧数上限、单帧体积上限照 3D 证据纪律；
  落 `artifacts/renders/`，失败显性（不静默给空白）。
* contact sheet：Dart 侧拼帧（或按镜头序号命名），不引入 ffmpeg/Imagemagick。

## 5. 性能与平台

* 桌面先行；预览分辨率默认 720×1280/1080×1920 二选一（按实测定），不承诺移动端
  与桌面同等分辨率/帧率。
* 首帧/每帧回传时间有观测与预算；超时/崩溃 = 显性降级（可重开预览），不假装成功。
* 不把 3D 视频渲染搬到 Flutter UI isolate；仍由 WebView 执行。

## 6. 借鉴清单（raea，仅契约）

* composition 的「帧 → 画面」形状；词级时间锚点；`check` 的 manifest/words 输入面与
  P0–P3 检查项；typed story 的 world/telling/beat 分层。**不复制代码/skills/资产**。

## 7. 不做

* 不替换 3D 建模工作台；不引入 React/JS 客户端运行时；不做完整编辑器（v1 只读预览+镜头选择）；
* 不做 Blender/Python/URDF/GLB 导出工具链；不做物理/骨骼/布料（backlog）。
