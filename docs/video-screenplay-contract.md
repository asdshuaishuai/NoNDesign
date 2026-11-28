# 视频模块契约（screenplay.json 唯一事实源 · 引擎短片 + 三风格 + VFX + TTS）

> 状态：**部分落地（R0 契约已实施：v1 硬门 + VFX cue allowlist + Phaser 4 播放页 + 真像素 VFX + 项目库/工具，2026-11-28；
>   预览面 UI/抓帧工具/风格包仍未施工）**。原文保留为目标态设计。
> 事实源、时间模型、TimingCompiler、rig/clip、Phaser 4.x 锁版本、pixelfx 子集、TTS、桥 v2、导出与 v1 兼容。
>
> 相关：[plan-creative-workbench.md](plan-creative-workbench.md) §5（方案事实源）·
> [video-clip-contract.md](video-clip-contract.md)（**v1 契约为现状，保留**）·
> [video-pipeline.md](skills/creative-workbench/references/video-pipeline.md)（30fps/QA）·
> [vfx-pixelfx.md](skills/creative-workbench/references/vfx-pixelfx.md)（VFX 子集）·
> [research/video-animation-howto.md](research/video-animation-howto.md)（rig/TTS/工艺）·
> [creative-refactor-decisions.md](creative-refactor-decisions.md)（R0 冻结与缺口）。

## 0. 与 `video-clip-contract.md` v1 的关系

| 渲染面 | 内容层 | 状态 |
| --- | --- | --- |
| 矢量算式动画 | `VideoDocument.frameSvg(t)` 纯 Dart | **现状**，不动 |
| DOM 动效合成（v1 短片） | `app/assets/video/clip/engine.js` + `ND.scene({duration, render})` | **v1 契约保留**（[video-clip-contract.md](video-clip-contract.md) 全部规则继续生效） |
| 引擎短片（新） | `screenplay.json` 编译成 Phaser 4.x 播放页 | **规划**，本文契约 |

v1 两种渲染面现状保留；引擎短片按本契约规划，最终三种渲染面**并存**；新事实源是 `screenplay.json`，但 v1 短片（`clips.json` + `<id>.html` + 桥 v1）**不被取代、不迁移**，`?t=` 逐帧审查与质量线照旧。桥 v1（`ready`/`state` + `window.__ndClip` 命令面）在引擎短片里原样保留，新消息只在 v2 扩展（§8）。plan §5.0 提到的 `docs/video-engine-contract.md` 是否另立待 5a 冻结（decisions §3）。

## 1. 事实源与工作区

```
video/<project>/
  screenplay.json    唯一创作事实源（v1，见 §3）
  style-pack.json    风格包（palette/type/motion tokens/vfx allowlist）
  src/               编译出的播放器 / 自定义场景代码（可执行派生）
  artifacts/         frames / contact sheets / bridges / metrics（agent 只读）
  judge/rNN/         brief + montages + judgment + score
```

`screenplay.json` 是创作事实源；`src/`、`timeline.json`、`spec.json` 都是**编译派生**，不是第二真相；禁止手改 MP4/PNG 作为唯一副本。既有项目 `video/<name>/timeline.json + spec.json + video.json` 继续按 v1 读取（`VideoProjectStore` 现状契约）；是否惰性重写为新布局待 R1 冻结（decisions §3）。播放器必须能只凭 `screenplay.json` + 风格包重放。

## 2. 时间模型与确定性

* **固定 30fps 整数帧**；作者可用秒，编译期一次性转帧，运行时不再出现秒。
* `stateAt(frame)` 是纯函数；`seek(t)` = 截断到当前 shot + `reset()` + 从 shot 起点按 1/30s 步进重放 + 一次性写姿态；区间事件按目标帧重建，一次性事件（音效/震屏）不重放。
* 禁止：CSS transition / timer / 帧间遗留状态、`Math.random` / `Date.now` / `performance.now` 进状态、自由正弦 bob、物理引擎参与状态。
* 随机一律种子派生：`hash(projectSeed, shotId, trackId, instanceId, index)`；弹簧/粒子从 shot 起点按固定步长积分（或用闭式解）。
* 循环片末帧 = 首帧（含光标/粒子）；后台暂停、恢复用 seek，**不补帧**。重新渲染面差异（Phaser / Canvas2D）不改变以上纪律。

## 3. `screenplay.json` v1 字段摘要

| 字段 | 约束 |
| --- | --- |
| `schema` | `nan.screenplay/1`（强制）；未知字段保留；校验失败给 JSON Pointer |
| `fps` / `seed` / `stage` | `fps = 30`（不混 24/60）；全局种子；`stage{w,h}` 如 1080×1920 / 1920×1080 |
| `style` / `audio` | `default / silly_skit / line_toon / ink_line`；`audio{bpm, beatsPerBar, offsetFrames}` 节拍网格 |
| `casts` / `shots[]` | `casts{id:{rig,scale}}`；shot：`id / start / duration / camera / cast[] / events[] / caption / transitionIn` |
| `events[]` | `{f:int, type:vfx / sfx / camera.shake / caption…}`；VFX 见 §7；一次性 vs 区间显式 |
| `musicRef` | 可选，指向音乐项目；链接前必须 `verifyScore` 通过（plan §5.5） |

* shot 时间是整数帧；除非显式转场不重叠；`start + duration` 不越 `durationFrames`。
* 台词/字幕是用户数据：转义、禁 `innerHTML`、字体/颜色白名单、安全区。
* **幕→场→镜头层级**：plan §5.1 写层级，`schemas.md` / video-pipeline 用扁平 `shots[]`；R0 契约先按**扁平 shots**，层级形态待 R1 冻结（decisions §3）。完整字段见 [schemas.md](skills/creative-workbench/references/schemas.md) §2「Video」与 [video-pipeline.md](skills/creative-workbench/references/video-pipeline.md) §3。

## 4. TimingCompiler（**拟实现**；配音先行，编译期定时）

* 流程：按 `。！？；…` 主切、`，、` 次切 → 每句独立 TTS → 量每句真实时长 → `shot.durationFrames = round(lineDuration × 30) + gap`（句间静音 80–150ms）。
* 句级用真实时长，句内按「汉字 1 / 数字 1.5 / 英文按音节」估算字级；标点额外停顿（逗号 120–180ms、句号 250–400ms、省略号 400–600ms）；可选 VAD 吸附静音谷。
* 镜头关键帧与口型按音频时间派生；**运行时绝不临时估算时长**（否则 seek 漂移）。改语速优先**重合成**，不做后期时间伸缩；落点（回写 `durationFrames` vs 带 hash 派生 timing 文件）待 R1 冻结（decisions §3）。工艺见 [research/video-animation-howto.md](research/video-animation-howto.md) §5.2。

## 5. 角色：`rig.json` / `clip.json`（cutout 木偶）

* `rig.json`：`canvas / root / bones[{id,parent,x,y,len}] / slots[{id,bone,z,attachment}] / faces{eyes,brows,mouths}`；世界变换 `world = world(parent) × T × R × S`，部件最终只需 `x/y/rot/sx/sy/alpha/frame`；旋转用角度。
* `clip.json`：`duration / loop / tracks[{part,keys[{f,rot,sx,sy,ease} | {f,src}]}] / events[]`；attachment 硬切（step 插值）。
* 规模：`silly_skit` 8–12 部件，`line_toon` 15–25 部件；表情 = 眼×眉×嘴贴片组合，厚描边**预烘焙进图集**（不做运行时描边、不用每部件 filter/mask）。
* **不把 Spine / DragonBones / Live2D / Rive 当事实源或 v1 主方案**；不做完整骨骼/IK/mesh 编辑器；父级非均匀缩放 + 子级旋转的 shear 用 Phaser 表达不了，squash 只作用单部件。完整字段见 [research/video-animation-howto.md](research/video-animation-howto.md) §2.2/§2.3。

## 6. 引擎短片：Phaser 4.x 锁版本 + vendored manifest

* 版本：**锁定单一版本，不浮动升级**；R0 建议 **4.2.1**、**3.90** 回退，最终由 5a spike 定（decisions §1）。角色/关键帧/引擎边界见 research §4.3。
* vendoring：`app/assets/video/engine/phaser.min.js` + `manifest.json`（版本 + SHA256 + 字节数 + 来源）；按仓库字节锁定纪律加 `.gitattributes`，不手改哈希产物。
* 编译：`assembleEnginePlayer(screenplay, stylePack)`（**拟实现**）→ **单文件 HTML**：内嵌 `phaser.min.js` + 解释器 `nd-stage.js` + screenplay 字面量 + 风格包；全部代码绘制、**零图片资源、零外联**。Agent **只写 JSON，不写 Phaser 代码**（保确定性/可校验/可回放）。
* 解释器映射：shot = 时间线段；台词 = 字幕/气泡；动作 = 预设 tween 组（命令式状态机不作姿态真源）；转场 = 相机/遮罩；角色 = 矢量绘制 + RenderTexture 缓存。

## 7. 风格包与 pixelfx 特效子集

| `style` | 渲染 | 要点 |
| --- | --- | --- |
| `silly_skit` | Phaser | 夸张弹跳预设 + 大字幕梗卡 + 点音效 + **pixelfx 战斗/环境特效（主用）** |
| `line_toon` | Phaser | 单线条人物 + 气泡 + 分格转场（相机遮罩）；像素特效只在刻意像素层 |
| `ink_line` | **自研 Canvas2D 矢量笔触** | 细抖墨线/暖纸/无脸/开放双笔触四肢/纸面遮挡/昼夜反转；**不引 line-art 的 TS/SVG 运行时**；首版不进（decisions §1） |

* 风格包字段：`palette / type / pen / motion 预设族 / vfx allowlist / caption 预设 / transition 集`；风格包是数据，不得加网络请求或新运行时。
* **pixelfx 只 vendor 特效子集**（MIT）：`app/assets/video/vendor/pixelfx/` 的 `core/` + allowlist `fx/` + `LICENSE` + `NOTICE.md` + `manifest.json`（upstream commit / 每文件 SHA256 / allowlist）。
* **不 vendor**：`actor.js` / `rig.js` / `poses.js` / `act.js` / `moves/` / `gallery/` / `skills/` / `tools/`（开发期用）/ 字体（Patch Pixel **不在 MIT**）；凡 `meta.actor` / `o.actor` / `onBody` 的效果一律禁。角色仍由我们自己的 rig 负责。
* VFX 是一等事件：`{f:int, type:"vfx", cue, x, y, scale, flip, palette, seed, light, layer}`；`x/y` 是锚点不是左上角；`seed` 缺省由稳定 hash 派生；`palette` 走风格包白名单；`layer` 默认 front。**cue 必须命中 allowlist**，未知 id 编译期拒绝。
* 运行时：color + light 双缓冲，light 最后叠加；固定 30fps（模拟特效内部 120Hz 子步进，帧号是唯一时钟）；像素画布 320×180 / 480×270，最近邻放大。门见 [vfx-pixelfx.md](skills/creative-workbench/references/vfx-pixelfx.md) §1–§6。

## 8. 验证与桥 v2

* Dart 侧 `verifyScreenplay`（**拟实现**，schema）+ 页面内 `?verify=1` 自检：逐镜头步进，检查台词出场、转场触发、时长和、事件越界，经 `markers` 回传——「机械对照」升级为引擎实测。
* 桥 v2 **向后兼容 v1**：`ready`/`state` 照旧；新增 `shot`（当前镜头 id/进度）、`markers`（自检结果）、`audio`（beat / ended，配乐联动用）。`window.__ndClip` 命令面（play/pause/seek/restart/setLoop）不变，Dart 侧播放适配不改。
* `video_review` 保留为人工审查面；VFX 另查 allowlist、确定性（同 seed 同帧同像素）、越界、循环/一次性结束、palette 白名单、单帧预算、无人形（§7）。

## 9. TTS（离线，含许可红线）

* 主路径 **sherpa-onnx**（Apache-2.0）+ 许可清晰的中文模型；Dart FFI 五端统一；句级真实时长回写 TimingCompiler，口型用 6 viseme（闭/A/E/O/F/L）+ 30Hz 包络。
* **OS 系统音色（macOS `say` / Windows SAPI / iOS AVSpeech / Android TTS）只做草稿预览**，UI 必须标注「个人非商业」——Apple macOS SLA 禁止录制/公开分享/商业再分发；**不做云 TTS**。模型体积/随包形态待 5b 冻结（decisions §1）。
* 音效优先程序化合成（Cue 表见 research §3.5）；采样只用 CC0/CC-BY 并打 `license/risk`。单一音频宿主：成片里所有声音在视频页同一个 `AudioContext` 调度，音乐页只发指令。

## 10. 导出仍屏蔽

`video_render` 只回 `video_export_disabled`，界面无成片导出入口；**不得**用 MediaRecorder 作事实源。启用后：确定性逐帧捕获（`gl.readPixels`/canvas）→ 编码器；帧哈希是 golden 锚，**码流哈希不承诺**。像素 VFX 按像素分辨率渲染再最近邻放大。帧级可复现、pose JSON 逻辑一致；不承诺跨平台像素级一致。

## 11. 迁移与兼容

| 现状 | 新布局 / 兼容策略 |
| --- | --- |
| `video/<name>/timeline.json` + `spec.json` + `video.json` | 继续按 v1 读取；新项目由 `screenplay.json` 编译产生 timeline/spec；重写策略待 R1（decisions §3） |
| `app/assets/video/clip/`（`clips.json` + `<id>.html` + `engine.js/css`） | **v1 契约保留**，不迁移；与引擎短片并存 |
| 桥 v1（`ready`/`state` + `__ndClip`） | 保留；v2 只做增量字段 |
| `video_sample` / `video_create` / `video_review` / `video_list`（现状工具） | 保留；剧本工具族 `video_list/create/read/patch/verify/inspect` 为**拟实现**（plan §5.6） |

## 12. 验收锚点（拟写测试名；既有 `video_project_test.dart` / `video_workspace_test.dart` 保留）

| 契约面 | 拟写测试 | 锚定 |
| --- | --- | --- |
| screenplay schema | `screenplay_contract_test.dart` | roundtrip、版本拒绝、shot/事件越界、cue allowlist |
| 时间确定性 | `video_determinism_test.dart` | 同帧同像素/姿态；`seek = reset+replay`；无 Math.random |
| TimingCompiler | `timing_compiler_test.dart` | 句级真实时长→帧、gap、幂等 |
| 桥 v2 | `video_bridge_v2_test.dart` | v1 消息兼容 + shot/markers/audio；命令面不变 |
| Phaser 4.x 锁版本 | `phaser_manifest_test.dart` | manifest 版本/SHA256/字节数与文件一致，不浮动 |
| VFX 子集 | `pixelfx_allowlist_test.dart` | allowlist 命中/拒绝、无人形依赖、种子确定性 |
| 自检页 | `video_verify_page_test.dart` | `?verify=1` markers 回传、时长和 |
| 项目兼容 | `video_project_migration_test.dart` | 旧 timeline/spec/video.json 可读；clip v1 不受影响 |
