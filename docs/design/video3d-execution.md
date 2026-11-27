# 3D 视频执行面设计（three-live）

> 状态：**已落地（D2 设计 + 2026-11-27 真 three 渲染与帧证据）**。项目层/预览页编译器/工作台
> 于 2026-11-25 落地；2026-11-27 补上**真 three.js r160 WebGL 渲染面**（无 WebGL 时如实降级到
> Canvas2D）与**帧证据**（`video3d_render_frames` → `artifacts/renders/`），并在 Linux WebKitGTK
> 实跑（`renderer=webgl_three_r160`、抓帧 PNG 11,871 B）。目标是把 `scene3d.json` +
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
* 画面只由「场景 + 镜头 + 帧号」决定。**确定性口径按渲染面分两档**（页面 `ready.renderer` 如实回传）：
  * `canvas2d_deterministic`：几何 + 投影都在 Dart/JS 数值路径上，**逐字节确定**；
  * `webgl_three_r160`：几何/相机/帧号确定，**同一设备同一输入同帧恒定**；像素受
    GPU/驱动影响，跨设备**不承诺逐字节一致**——这是 WebGL 的物理事实，不能写成硬验收。
* 词级时间/beat grid 作为可选的 cue 对齐语义，来自 raea/story-short 的契约参考，
  不引入其运行时。

## 4. 预览与取证

* 预览 = 应用内 WebView（`webview_all`）；与 3D 建模共用 WebView 纪律，但控制器/页面独立。
* 帧证据：页面暴露 `NONVIDEO3D_PLAYER.capture(frame)`：暂停 → 渲染目标帧 →
  `canvas.toDataURL('image/png')` → 桥 `evidence` 回传 → Dart 解码校验（PNG 魔数、
  单帧 ≤8 MiB、≤120 帧、总量 ≤64 MiB）→ `artifacts/renders/frame-NNNN.png` +
  `artifacts/renders/renders.json`（确定性清单，无时间戳）。失败显性
  （`video3d_capture_*` / `video3d_evidence_*`），**绝不写空白 PNG**。
* 抓帧只产证据：两份事实源不动；预览没打开（没有活动运行器）时工具显性失败。
* contact sheet：暂未做（按镜头序号命名已可核对）；不做 ffmpeg/Imagemagick。

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
