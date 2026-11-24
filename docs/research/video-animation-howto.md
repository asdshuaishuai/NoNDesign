# 视频动画工作台：可施工技术调研（沙雕短剧 / 线条漫画，2026-11-20）

> 状态：**调研结论，供施工与方案回填**。对应愿景 [vision.md](../vision.md)「代码创造世界」；
> 模块方案 [plan-creative-workbench.md](../plan-creative-workbench.md) §5。本文回答「怎么做」。
> 证据标记：【事实】有官方文档/仓库/许可证来源；【案例】具体创作者/产品；【推断】工程判断。

## 0. 结论先行

1. **工艺本质**：沙雕动画不是低配动画，而是「**音频为时间主轴 + 有限动画 + 表情贴片 + 音效/字幕卡放大笑点**」。画面精度不是壁垒，节奏与表演时机是。
2. **数据模型**：`screenplay.json`（剧本/镜头/台词/事件）→ 编译成 **30fps 整数帧**的 RuntimePlan；角色用 `rig.json`（部件/骨骼/表情）+ `clip.json`（关键帧）；运行时只读，不回写。
3. **确定性**：所有动画是 `stateAt(frame)` 纯函数；seek = 重置 + 从镜头起点重放；随机用 `hash(seed, shotId, trackId, instanceId, index)`；禁止 `Math.random`/`Date.now`/物理/Phaser 粒子参与状态。
4. **角色**：自建 cutout 木偶（8–12 部件沙雕；15–25 部件线条漫画），不引 Spine/DragonBones/Live2D 运行时；厚描边预烘焙进图集，不做运行时描边。**线条漫画有两条路线**：`line_toon` 美式硬线分格（cutout 图集）；`ink_line` 墨线手绘（开放双笔触+步态求解+Canvas2D 笔触，2026-11-22 新增，只参考 `JDhruv14/line-art-animation` 的规则，不引入其 TS/SVG 运行时，见 §3.6）。
5. **引擎**：Phaser 4.2.1（当前主线，锁版本）或 Phaser 3.90.0（更成熟，锁版本）二选一；本项目只用 Sprite/Container/Camera/Text/Mask，迁移面小。**不要等 Phaser 5，也不要浮动升级**。
6. **配音**：OS 系统音色（macOS `say` / Windows SAPI）**不适合对外发布的商业视频**（Apple SLA 限制个人非商业用途）；主路径用 **sherpa-onnx（Apache-2.0）+ 许可清晰的模型**，OS 音色只做草稿预览并显式提示。
7. **导出**：短期只做确定性播放；未来导出走 **WebView `gl.readPixels` → Rust 二进制 IPC → ffmpeg sidecar**，不用 MediaRecorder；帧级可复现，码流级不承诺字节一致。
8. **分工**：程序化负责时间轴、资产、预设、导出；人负责梗、语气、关键表演、版权判断。

## 1. 沙雕动画的工艺事实

### 1.1 定义与风格语法【案例/推断】

- 角色：头身比 1:2–1:4，头大身小；熊猫头/圆头/方头；五官是贴片（眼白、瞳孔、眉、嘴）；四肢单段或两段；一套角色 10–20 个部件。
- 线条：1080p 下 3–6px 黑描边、平涂、无渐变、6–8 色；允许抖线/不闭合作为风格。
- 表情：不是逐帧画，而是「眼 × 眉 × 嘴」贴片组合 + 汗滴/青筋/泪/黑线/石化等 FX。约 22 张贴图可组合 300+ 表情。
- 表演：有限动画（12fps 或 24fps on 2s）；预备→极限帧→停顿→回落；挤压拉伸；表情硬切；夸张物理（下巴掉地、眼珠弹出）。
- 镜头：snap zoom（3–5 帧）、shake（6–10 帧）、whip pan、hit stop、黑白闪、Dutch angle。
- 叙事：0–3 秒钩子 → 3–15 秒设定 → 15–60 秒升级 → 60–80% 反转 → 结尾回扣；旁白驱动，台词少。

【案例】YY（熊猫头头部作者）：3 分 15 秒作品，接广告「制作一期要一周左右」；早期讽刺、中期校园、后期共鸣。
来源：新榜/腾讯新闻访谈（https://news.qq.com/rain/a/20210129A0FD7400）。

### 1.2 节奏量化（可直接写成 style pack 参数）

| 指标 | 常规 | 快节奏 |
| --- | --- | --- |
| 单集时长 | 60–180s | 45–90s |
| 镜头数 | 12–20/min | 20–30/min |
| 平均镜长 | 3–5s | 1.5–3s |
| 旁白语速 | 4–5 字/s | 5–6 字/s |
| 每分钟字数 | 240–300 | 300–360 |
| 笑点间隔 | 8–12s | 5–8s |
| 停顿 | 0.3–0.6s | 0.2–0.4s |
| 音效密度 | 0.3–0.6/s | 0.6–1.0/s |

字幕：底部 12–18% 安全区；字号屏高 4.5–6.5%；每行 ≤14 汉字（竖屏 ≤12）；白字黑描边 4–8px；强调色 ≤2 种；梗卡全屏 0.6–1.5s。

### 1.3 真实制作流程与耗时【案例/推断】

| 阶段 | 产出 | 常用工具 | 1–3 分钟耗时 |
| --- | --- | --- | --- |
| 选题/文案 | 500–900 字旁白、beat 表 | 文档/Agent | 0.5–2h |
| 配音 | 分角色 WAV、时间戳 | TTS/真人 | 0.3–1h |
| 分镜 | 镜头表、音频标记 | 表格/AN | 0.5–1.5h |
| 角色/场景 | 分层部件、场景包 | PS/Figma/AN/CTA | 首集 2–6h；复用 0.5–1h |
| 动画 | 镜头动画、口型、表情 | AN/CTA/Moho/AE | 4–12h/min |
| 合成/剪辑 | 字幕、音效、BGM | AE/PR/剪映 | 1–3h |
| 发布 | 封面、标题、标签 | 平台后台 | 0.3–0.5h |

- 熟练个人 1–3 天/集；新手 3–7 天；3–5 人小队周更 1–2 集。
- **配音先行**：先有音频，才有镜头时长、口型、停顿、笑点位置；反过来必对不齐。
- 系列化经济学：每集只新增 10–20% 资产，80% 复用（角色卡、场景包、道具包、音效包、梗卡模板）。

### 1.4 工具链定位

| 类别 | 代表 | 适合 | 不适合 |
| --- | --- | --- | --- |
| 通用 2D | Adobe Animate、After Effects | 自由、教程多 | 手工重、协作难 |
| 骨骼/傀儡 | Cartoon Animator、Moho、Spine、DragonBones、Live2D、Rive | 复用、数据化 | 授权/风格限制 |
| 逐帧 | OpenToonz、Blender Grease Pencil | 手绘质感 | 量产慢 |
| 模板/云端 | 万彩、Vyond、Animaker、剪映 | 零门槛、商单 | 喜剧节奏弱 |

**工作台选型**：Phaser + 自研 cutout；Spine/Rive 只做后续导入，不做地基。

## 2. 数据模型

### 2.1 `screenplay.json`（唯一事实源）

```jsonc
{
  "schema": "firelight.screenplay/1",
  "fps": 30,
  "seed": 20261120,
  "stage": { "w": 1080, "h": 1920 },
  "style": "silly_skit",
  "rigs": { "panda_01": { /* 见 §2.2 */ } },
  "shots": [{
    "id": "s07",
    "startFrame": 372,
    "durationFrames": 66,
    "template": "reaction_zoom",
    "bg": "office_day",
    "cast": [
      { "id": "hero", "rig": "panda_01", "x": 540, "y": 980, "scale": 1, "flip": false, "z": 10 }
    ],
    "tracks": [
      { "target": "hero", "clip": "shock", "start": 0, "end": 66 },
      { "target": "hero/face", "kind": "attachment", "keys": [
        { "f": 0, "v": "face_shock" }, { "f": 50, "v": "face_neutral" }
      ]},
      { "target": "hero/mouth", "kind": "attachment", "keys": [
        { "f": 10, "v": "mouth_A" }, { "f": 14, "v": "mouth_closed" }
      ]}
    ],
    "camera": { "from": { "zoom": 1.0 }, "to": { "zoom": 1.45 }, "ease": "expoOut" },
    "caption": { "text": "老板怎么在这儿？", "preset": "bottom_bold", "in": "pop" },
    "events": [
      { "f": 5, "type": "sfx", "cue": "dun" },
      { "f": 8, "type": "camera.shake", "amp": 4, "freq": 18, "dur": 8 }
    ],
    "transitionIn": { "type": "wipe", "duration": 8, "direction": "left" }
  }]
}
```

规则：
- **时间一律整数帧**；作者可用秒，编译期一次性转帧，运行时不再出现秒。
- `schema` 必填；加载时迁移；未知字段保留；校验失败给 JSON Pointer 路径。
- 台词/气泡是区间事件（`startFrame + durationFrames`）；音效/震屏是一次性事件；seek 时区间事件按目标帧重建，一次性事件不重放。
- `seed` 全局 + 稳定 ID 派生；编辑无关文本不重排其他元素随机。

### 2.2 `rig.json`（部件化木偶）

```jsonc
{
  "id": "panda_01",
  "canvas": [512, 512],
  "root": { "pivot": [256, 480] },
  "bones": [
    { "id": "root", "parent": null, "x": 0, "y": 0 },
    { "id": "hip", "parent": "root", "x": 0, "y": -120 },
    { "id": "torso", "parent": "hip", "x": 0, "y": 0, "len": 120 },
    { "id": "head", "parent": "torso", "x": 0, "y": -120 },
    { "id": "arm_r", "parent": "torso", "x": 24, "y": -90, "len": 90 }
  ],
  "slots": [
    { "id": "body", "bone": "torso", "z": 10, "attachment": "body_base" },
    { "id": "head", "bone": "head", "z": 30, "attachment": "head_neutral" },
    { "id": "face", "bone": "head", "z": 31, "attachment": "face_neutral" },
    { "id": "mouth", "bone": "head", "z": 32, "attachment": "mouth_closed" }
  ],
  "faces": {
    "eyes": ["normal", "shock", "angry", "cry", "sleep"],
    "brows": ["neutral", "angry", "sad", "raise"],
    "mouths": ["closed", "A", "I", "U", "E", "O", "grin", "scream"]
  }
}
```

- 世界变换：`world = world(parent) × T × R × S`；每个部件最终只需 `x/y/rot/sx/sy/alpha/frame`。
- 表情 = 眼 × 眉 × 嘴组合（22 张贴图 → 300+ 组合），再叠 FX 贴纸。
- 旋转用角度，不用四元数；attachment 用 step 插值（硬切）。
- **不要 v1 做 mesh/IK 编辑器**；需要时只做双骨解析 IK（手/脚）。
- 父级非均匀缩放 + 子级旋转会产生 shear，Phaser Sprite 表达不了；squash 只作用单部件，或用 Mesh2D quad。

### 2.3 `clip.json`（关键帧）

```jsonc
{
  "id": "shock",
  "duration": 13,
  "loop": false,
  "tracks": [
    { "part": "head", "keys": [
      { "f": 0, "rot": 0, "sx": 1.0, "sy": 1.0 },
      { "f": 3, "rot": -8, "sx": 1.15, "sy": 0.9, "ease": "backOut" },
      { "f": 8, "rot": 0, "sx": 1.0, "sy": 1.0, "ease": "elasticOut" }
    ]},
    { "part": "mouth", "keys": [
      { "f": 0, "src": "closed" }, { "f": 3, "src": "scream" }
    ]}
  ],
  "events": [
    { "f": 2, "type": "sfx", "cue": "gasp" },
    { "f": 3, "type": "camera.shake", "amp": 5, "freq": 18, "dur": 8 }
  ]
}
```

缓动：弹入 `backOut`（overshoot 1.7–2.2）；Q 弹 `elasticOut`；落地 `bounceOut`；急停 `expoOut/quintOut`；机械/搞笑用 `linear`。弹簧跟随 `a = -k(x-target) - c*v`，k 180–400、c 12–26。

### 2.4 时序编译

如果剧本只有台词/动作描述、没有精确时长，必须有 **TimingCompiler**：按语速/动作节拍把台词语音、镜头时长编译成 `startFrame/durationFrames`，写回 screenplay 或带 hash 的派生 timing 文件。运行时绝不临时估算时长，否则 seek 漂移。

## 3. 角色、镜头与字幕

### 3.1 表情与口型

- 表情切换 `setFrame`，不销毁/重建 Sprite；同一图集内切换不破坏批处理。
- 眨眼用 hash 派生间隔，纯函数；沙雕允许 1–2 帧坏帧作为笑点；线条漫画用硬切。
- 口型 6–8 个 viseme（closed/A/I/U/E/O/M）；离线生成 viseme track，运行时不做语音识别/音频分析。
- 无音频时按台词长度做确定性开合节奏（每 3–4 帧切换）；有音频时音频为 slave，每 30 帧校正漂移。

### 3.2 挤压拉伸与描边

- 体积守恒 `sy = 1/sx` 只作作者辅助；冲击帧 2–3 帧 `sx=1.15, sy=0.85`，再 `backOut` 回弹。
- 不用 skew（Phaser 3 不支持 GameObject skew；Phaser 4 也不要依赖）。
- 描边**预烘焙**进图集，留 4–8px padding/extrude；不要运行时多份 tint 偏移或每部件 shader outline。

### 3.3 镜头与转场

| 镜头 | 参数 |
| --- | --- |
| Snap zoom | 1.0→1.12–1.45，0.08–0.15s |
| Shake | 2–6px，12–24Hz，0.2–0.4s；用衰减正弦 + trauma，不用每帧随机 |
| Whip pan | x 位移 + 3 帧拖影 |
| Hit stop | 全局冻结 40–80ms |
| 黑白闪 | 1–2 帧 overlay |

转场：80% 硬切 + 音效；白闪/黑闪、whip、zoom punch、match cut、freeze card、record scratch。分格用 Stencil/Mask（Phaser 4）或 GeometryMask（Phaser 3）；不要每部件 mask。

### 3.4 字幕卡与气泡

- 6 个预设：`bottom_bold`、`top_question`、`meme_card`、`news_flash`、`speech_bubble`、`impact_word`。
- 气泡放屏幕空间层；结构 = NineSlice 底 + 文本 + 尾巴；整体缓存纹理；打字机用 crop/mask 显示字符数，不每帧改 Text。
- 用户文本必须转义；颜色/字体白名单；不要拼 `innerHTML`。

### 3.5 音效语法

| 音效 | 程序化配方（Web Audio） |
| --- | --- |
| Boing | 正弦 180→520Hz + 12Hz 颤音 + 0.25s 指数衰减 |
| Whoosh | 白噪声 + 带通 300→2500Hz 扫频 + 0.25–0.4s |
| Ding | FM 钟声，载波 1200Hz，调制比 2.4，衰减 0.8s |
| Pop | 8ms 噪声爆发 + 正弦 900→200Hz 60ms |
| Impact | 55Hz 正弦 0.12s + 低通噪声 |
| Scratch | 锯齿 + LFO 音高调制 0.3s |

Cue 表 12–16 个：dun/ding/boing/whoosh/slap/gasp/scratch/awkward/laugh/impact/pop/click/riser/sub_drop。**音效是最大版权雷区**：不要扒影视/游戏/综艺；用 CC0 + 程序合成，资产打 `license/risk` 字段。

**战斗/环境特效**：`silly_skit` 可接 **pixelfx 特效子集**（MIT；火焰/冰霜/风/爆炸/闪电/烟尘/水花等），只取特效、不取人物/stock actor/moves；VFX 以 `{f,type:"vfx",cue,...}` 事件进 `screenplay.json`，固定 30fps、color+light 双缓冲、最近邻放大。`line_toon` 只在刻意像素层用，`ink_line` 默认不用。详见 [pixelfx.md](pixelfx.md)。

### 3.6 墨线手绘（`ink_line`）的额外约束

`ink_line` 是第三种风格包，不走 cutout 图集；完整调研见
[line-art-animation.md](line-art-animation.md)。施工时守住：

- **视觉签名**：一支细（约 1.35 人物单位）、略抖的墨线在暖纸上；人物无脸；
  四肢是两条**开放**笔画夹纸色带（绝不画闭合管）；纸色填充做遮挡；1–2 个点缀色；
  建筑正立面画满、天空留白；页面底色不随昼夜变化。
- **运动**：步态必须解（站立脚以行进速度后滑、最小 jerk 摆动、脚跟离地、髋高由
  腿长反解）；两骨 IK；衣摆绕前膝/两踝；袖/包/灯笼用弹簧/摆锤；禁止自由正弦 bob。
- **昼夜**：`palette(τ)` 反转墨/纸；每扇窗/每盏灯独立阈值错峰亮灭；夜色 tint；
  辉光单独一层；同一套 30fps 整数帧、种子化随机。
- **渲染**：自研 Canvas2D 矢量笔触（几何抖动，不用运行时 SVG filter）；静态层
  缓存 `Path2D`；若移动端 1080p30 不达标，再评估预烘焙笔触图集回退。
- **验收**：站立脚漂移 <0.5px/帧、开放四肢、前腿在上、昼夜对比度、交互回 idle；
  先做一个 figure 给用户过，再铺整场。

### 3.7 2D 角色 + 3D 世界（`toon_3d` 候选）

`mromidev/claude-animated-shorts` 这条线是「55–70s 竖屏动画短剧」：2D 扁平
billboard 角色站在 three.js 手绘 3D 世界里，墨线轮廓、景深、滑翔相机、合成
音效/配乐。完整调研见 [claude-animated-shorts.md](claude-animated-shorts.md)，
skill 参考 [story-short.md](../skills/creative-workbench/references/story-short.md)。

- **只参考、不引入**：Remotion/React/Node/Chromium 运行时、1.3GB 参考资产、
  参考片/角色/脚本/镜头都不进来；执行面仍是 three-live + 30fps 确定性帧。
- **可借**：8 段脚本（hook/setting/escalation/mystery/pivot/analogy/consequence/
  callback）、`words.json` 词级时间、镜头表 schema、相机语法、look 数值
  （墨线 3px、日/黄金光、DOF、post 顺序、角色比例）、逐帧 QA、look-match loop。
- **状态**：`toon_3d` 是候选风格，**不改变当前三风格定稿口径**；先做 three-live
  的 billboard/后处理/1080×1920 30fps spike，再决定是否进入正式 style pack。

## 4. 确定性运行时

### 4.1 帧时钟

- 固定 30fps，所有状态由 `frame` 计算；预览 rAF 只负责决定「现在显示第几帧」。
- 后台/切后台暂停；恢复时 seek 到当前时间，不补帧（补帧改变一次性事件语义）。
- 不要把 Phaser `fps.target` 当确定性保证；它只是调度提示。

### 4.2 seek = 重置 + 重放

```text
seek(target):
  clamp 到当前 shot
  shot.reset()                      // 清姿态/附件/气泡/临时状态
  for f = shot.startFrame .. target: shot.stepState(f)   // 只算数学
  shot.applyPose(target)            // 一次性写 Phaser 对象
  shot.syncPersistentEvents()       // 区间事件按目标帧重建
```

- 一次性事件（音效/震屏）seek 不重放；持续事件（气泡/转场）按区间重建。
- 验收：`poseAfterSeek(n) === poseAfterStep(n)`，逐字段 JSON 比较；同输入跑 3 次完全一致。

### 4.3 引擎能力边界【事实】

- **Phaser 4.2.1**（2026-07）：WebGL RenderNode、Stencil、Mesh2D、Spine 新路径；Canvas 渲染器 deprecated；WebGL1 基线，需要 `ANGLE_instanced_arrays` / `OES_vertex_array_object`，老设备要真机验证。
- **Phaser 3.90.0**（2025-05）：v3 最后版本；生态成熟；Canvas/WebGL 双渲染。
- **Tween**：`seek(amount, delta, emit)` 先 reset 再按 delta 重放，可重复；但它是命令式状态机，不作为姿态纯函数。**不要用 Tween 做主引擎**。
- **Timeline**：事件调度器，只能 reset，没有 seek；不要当 shot timeline。
- **粒子**：随机源最终 `Math.random`，无种子；不要用于叙事特效（预计算或自写 seeded emitter）。
- **Arcade/Matter**：没有确定性承诺；角色动作不用物理。
- **Container**：子对象不能被 mask；不要每骨一个 Container。
- **Graphics**：WebGL 下分解多边形；复杂图形昂贵；`generateTexture()` 缓存，不每帧重绘。
- **Text**：内容变化重建 canvas 并重传 GPU；气泡缓存纹理/BitmapText。
- **Spine/DragonBones/Live2D/Rive**：Spine 质量最高但运行时授权绑定商业编辑器；DragonBones 免费但 Phaser 适配层陈旧；Live2D 闭源 Core + 许可；Rive runtime MIT 但编辑器 SaaS、`.riv` 成为第二事实源。v1 全部不做主方案。

来源：Phaser Releases（https://github.com/phaserjs/phaser/releases）、Phaser 4.2（https://phaser.io/news/2026/07/phaser-4-2-spine-renderer-mesh2d-stencil）、Tween API（https://docs.phaser.io/api-documentation/class/tweens-tween）、Timeline（https://docs.phaser.io/api-documentation/class/time-timeline）、Particles（https://docs.phaser.io/phaser/concepts/gameobjects/particles）、Spine 许可（http://en.esotericsoftware.com/spine-runtimes-license）、Rive（https://rive.app/runtimes）、DragonBones Phaser 适配（https://github.com/DragonBones/DragonBonesJS/tree/master/Phaser/3.x）。

### 4.4 种子随机

```text
rng(seed, shotId, trackId, instanceId, index) = mulberry32(hash32(...))
```

- 无状态派生：同一元素在任何帧、任何 seek 顺序得到同一值；编辑无关文本不重排。
- 随机只用于眨眼、头发/天线抖动、粒子初速、背景噪点、分格偏移。
- 禁止 `Math.random`、`Date.now`、`performance.now` 进入姿态/事件状态；`performance.now` 只用于播放选帧。

### 4.5 资产与性能

| 项 | 数值/建议 |
| --- | --- |
| 图集页 | 移动端 ≤2048×2048；桌面 ≤4096 |
| 纹理内存 | 2048² RGBA = 16 MiB；4096² = 64 MiB；单项目标 ≤64 MB |
| 纹理总内存 | WebView 目标 ≤150–200 MB（iOS 实测有 ~256MB canvas 上限报告） |
| 批处理 | 一个角色一个图集；同屏角色共享风格图集；draw calls 几百以内 |
| 字体 | WOFF2 内嵌；`document.fonts.ready` 后再测量 |
| 音频 | 短音效 base64；长音频 sidecar 或 Flutter 侧播放 |

来源：Phaser Textures（https://docs.phaser.io/phaser/concepts/textures）、WebGL Best Practices（https://developer.mozilla.org/en-US/docs/Web/API/WebGL_API/WebGL_best_practices）、WebKit canvas memory（https://bugs.webkit.org/show_bug.cgi?id=195325）。

## 5. 配音、口型与音效

### 5.1 TTS 路线（含许可红线）

【事实】**Apple macOS SLA 把 System Voices 限制为个人、非商业用途，禁止录制/公开分享/商业再分发**（原文见 https://www.apple.com/legal/sla/docs/macOS27.pdf F 节）。所以 `say -o` 生成音频再随视频发布到抖音/B站/YouTube，属于被禁止的公开分享/商业场景——这不是音质问题，是许可证红线。

| 平台/方案 | 能力与坑 | 许可 | 结论 |
| --- | --- | --- | --- |
| macOS `say` | 本机实测 187 个音色；可输出 WAV（`--data-format=LEI16@22050`）；`[[slnc 1000]]` 可插停顿；无时间戳；`-o .m4a` 默认仍是 LPCM | 系统音色仅个人非商业 | **仅草稿预览**，UI 明示 |
| Windows SAPI | `SetOutputToWaveFile` 写 WAV；`BookmarkReached.AudioPosition` 给书签音频位置（句/词级时间戳最好用）；Win11 Natural Voices 不暴露给 SAPI；PowerShell 5.1 调用 | 随 Windows 授权；商业再分发需法务确认 | 草稿/离线可用 |
| Linux espeak-ng | `-w` 写 WAV；`--pho` 输出带时长的音素数据（音素级时间戳）；`-D` 确定性 | **GPL-3.0** | 可作降级；闭源分发需审计 |
| iOS AVSpeechSynthesizer | `write(_:toBufferCallback:)` 可取 PCM 落盘；文件合成无词级时间戳；enhanced/premium 需下载 | 随 iOS 授权；商业输出需确认 | 草稿/备选 |
| Android TextToSpeech | `synthesizeToFile`；`onRangeStart(start,end,frame)` 给字符区间 + 音频帧偏移；高质量音色通常联网，离线音色一般；需 `<queries>` 声明 TTS_SERVICE | 引擎相关 | 草稿/备选 |
| **sherpa-onnx** | Apache-2.0；Flutter/Dart 五端包；TTS + VAD + forced alignment；可跑 Matcha/Kokoro/VITS/Melo | Apache-2.0（模型逐个核对） | **主路径** |
| Piper | 旧仓库 MIT 已归档；新 piper1-gpl 为 **GPL-3.0**；音色许可随训练集（CC0/CC-BY/研究限定） | 代码与音色分开看 | 备选，逐音色核对 |
| Kokoro-82M | 权重 Apache-2.0；int8 约 80–90MB；中文 8 个音色 | 权重干净；英文 G2P 依赖 espeak-ng（GPL）需审计 | 高质量备选 |
| Coqui XTTS | 公司已停止运营；XTTS 权重 **CPML 仅非商业** | 不可商用 | **排除** |

推荐：
- **草稿/预览**用 OS 音色（零体积、即时），但界面必须标注「个人非商业」。
- **导出/发布**默认切随包 neural：中文 Matcha zh-baker（约 73MB）或 Kokoro int8；英文 Piper medium（约 61MB）。模型按语言分包/可选下载，保持零联网。
- 统一走 `sherpa_onnx` Flutter 包（Dart FFI），一套 API 覆盖五端；OS 音色只是「快速预览」适配器。

### 5.2 时间对齐：句级真实 + 字级估算

原生时间戳能力：
- Windows SAPI：`BookmarkReached.AudioPosition`（自己插 bookmark，句/词级）。
- Android TTS：`onRangeStart(start,end,frame)`（字符区间 + 帧偏移）。
- espeak-ng：`--pho` 音素时长。
- iOS AVSpeech：`willSpeakRangeOfSpeechString` 仅实时播放，文件合成拿不到。
- macOS `say` / Piper / Kokoro / VITS：无标准时间戳。

推荐流水线（TTS-first）：
1. 按 `。！？；…` 主切、`，、` 次切；每句独立合成。
2. 用 WAV 头/`ffprobe` 测每句真实时长；句间插 80–150ms 静音。
3. 句内按「汉字 1、数字 1.5、英文按音节」分配字级时间；标点额外停顿（逗号 120–180ms，句号 250–400ms，省略号 400–600ms）。
4. 可选：用能量 VAD 把估算边界吸附到静音谷。
5. 回写 `shot.durationFrames = round(lineDuration * 30) + gap`；镜头关键帧按音频时间生成。

- 中文正常 4.5–6 字/秒，沙雕夸张 7–8 字/秒；句内字级误差 ±80ms 对口型足够。
- 需要词级精确时才上强制对齐：sherpa-onnx alignment（Apache-2.0，跨平台）或 MFA（MIT）/WhisperX（BSD-2，重）。对沙雕短剧属于过度工程。
- 改语速优先「重合成」（`say -r`、espeak `-s`、SSML `<prosody rate>`、Android `setSpeechRate`、Piper `--length-scale`），不要后期时间伸缩（会破坏音色，Rubber Band 还有 GPL/商业双许可）。

### 5.3 口型：6 个 viseme 足够

| ID | 口型 | 典型音素 |
| --- | --- | --- |
| X | 闭口 | b/p/m |
| A | 张口 | a/ai/an/ang |
| E | 扁口 | e/ei/en/eng/i/in |
| O | 圆口 | o/ou/ong/u/ü |
| F | 齿唇 | f/s/sh/z/c/zh/ch |
| L | 舌尖 | d/t/n/l/r |

- 中文用 `pinyin` 包（MIT）转拼音，取声母+韵母首字母映射；多音字用词组词典，剩余误差对沙雕口型影响很小。
- 混合驱动：时间用句级真实时长 + 字级估算；开合用 30Hz RMS 包络 `smoothstep`；宽圆用谱质心（>1500Hz 偏扁，低偏圆）；爆破音（b/p/d/t/g/k）插 60–100ms 闭口。
- **预计算 30Hz 曲线写进 timeline，`render(frame)` 只插值**；不要逐帧 FFT，60Hz 是浪费。
- 音频为 slave：`audio.currentTime` 对齐 `frame/30`，每 30 帧校正漂移；WebView 自动播放需用户手势。

参考：Rhubarb Lip Sync 的 6 基本口型 + 3 扩展（MIT，https://github.com/DanielSWolf/rhubarb-lip-sync）；Microsoft viseme 22 个适合 3D 精细口型，不适合 2D 沙雕。

### 5.4 音效与配乐联动

- 程序化音效优先（§3.5 配方），采样只保留笑声/脚步/环境等难以合成的；采样库用 Kenney CC0、Freesound CC0/CC-BY，避开 BBC RemArc（非商用）。
- 资产打 `license/risk` 字段；导出前做高风险音效提示。
- **单一音频宿主**：所有声音在视频页同一个 `AudioContext` 里调度；音乐页只发指令（播放/暂停/seek/音量），不各自建时钟。跨页面 `postMessage` 只能做到预览级对齐，不能采样级。
- 导出：`OfflineAudioContext` 或 Dart PCM 混音成 WAV，再与视频帧一起封装；桌面 ffmpeg，移动端 AVAssetWriter/MediaMuxer；**不要用已退役的 FFmpegKit**。

## 6. 导出与验收

### 6.1 短期：只做播放

- `screenplay.json` → `timeline.json`（编译期校验帧数守恒、镜头不重叠、资源齐全）→ Phaser 播放器。
- `renderAt(frame)` 是唯一渲染入口；rAF 只决定帧号；音频参考 WAV + 时钟校准。
- 验收：同机 `renderAt(n)` 重复像素一致（帧哈希）；golden 10–20 张。

### 6.2 长期：mp4 导出

```text
WebView renderAt(f) → gl.readPixels → Uint8Array(约 8MB/1080p)
   → Rust IPC（Raw bytes，非 base64）
   → ffmpeg stdin: -f rawvideo -pix_fmt rgba -s WxH -r 30 -i -
   → -vf vflip -pix_fmt yuv420p → H.264（VideoToolbox/Media Foundation 或 libx264）
   + OfflineAudioContext → WAV → AAC 混流（处理 AAC priming）
```

- **不要用 MediaRecorder**：实时录制、无逐帧控制；Safari 只出 MP4，Chromium 传统只出 WebM，Linux WebKitGTK 不可靠。
- **不要用 Phaser `snapshot()` 逐帧**：每帧 200 万像素 JS 循环 + 异步 Image；自写 `readPixels` 到预分配 `Uint8Array`。
- ffmpeg 许可：闭源分发优先 LGPL 构建 + 硬件编码器；`libx264` 会触发 GPL。法务评审后再打包。
- 帧级可复现，码流级不承诺；golden 锚在帧哈希，不锚 mp4 文件哈希。

来源：MediaRecorder（https://developer.mozilla.org/en-US/docs/Web/API/MediaRecorder）、WebKit MediaRecorder（https://webkit.org/blog/11353/mediarecorder-api/）、ffmpeg legal（https://ffmpeg.org/legal.html）、OfflineAudioContext（https://developer.mozilla.org/en-US/docs/Web/API/OfflineAudioContext）、Tauri sidecar（https://v2.tauri.app/develop/sidecar/）。

### 6.3 质量门（导出前自动检查）

- 钩子 ≤3s；首个笑点 ≤5s；无 >0.8s 无意图死气。
- 字幕不溢出/不超行/不越安全区；镜头时长 1.2–6s（除刻意长镜头）。
- 音效不过密/过疏；无缺失资产/未授权音效。
- 响度 −14 LUFS、峰值 −1 dBTP（短视频）；竖屏避开右侧按钮区。

## 7. 施工顺序

| 阶段 | 内容 | 验收 |
| --- | --- | --- |
| P0 | 时间轴编译器 + TTS 接入 + 字幕卡 + SFX cue + 固定步长播放 | 一段 30s 沙雕 demo 可播、可 seek、可导出双子 |
| P1 | cutout rig + 20–30 个动作 clip + 组合表情 + 镜头预设 + 分格 | 3 个镜头模板可复用；pose 快照一致 |
| P2 | 剧本/分镜编辑器 + Agent 分镜/音效建议 + 剪映草稿导出（锁版本） | 1–3 分钟成片流程跑通 |
| P3 | mp4 导出（readPixels→ffmpeg）、A/B 钩子、自动 QC | 时长误差 <1 帧；音画偏移 ≤1 帧 |

## 8. 不要做

1. 不要自研完整骨骼编辑器（建骨/IK/mesh/曲线/撤销/格式/兼容）。
2. 不要把 Phaser Tween/Timeline 当动画事实源；不要用 Arcade/Matter 驱动角色。
3. 不要用 Phaser 粒子做叙事特效；不要 `Math.random`/`Date.now` 进状态。
4. 不要用 wall clock delta 插值；一律整数帧。
5. 不要每骨一个 Container；不要每部件 mask/filter；不要每帧 `Graphics.clear()` 重绘。
6. 不要运行时 SVG 做复杂线条漫画；不要运行时描边；不要 >2048 图集做移动端首屏。`ink_line` 走 Canvas2D 矢量笔触，不引入 `line-art-animation` 的 TS/SVG 库；几何抖动可复现，运行时 SVG filter 不可作为跨端确定性保证。
7. 不要用 MediaRecorder 导出；不要把整段 mp4 base64 塞进默认 HTML。
8. 不要用 Apple System Voices 做对外发布配音；不要用 Coqui XTTS（CPML）商用。
9. 不要把 Spine/Rive/Live2D 作为 v1 唯一角色格式；它们是导入格式，不是事实源。
10. 不要承诺跨平台像素级一致；承诺同平台可复现、pose JSON 逻辑一致。

## 9. 主要来源

- 新榜/腾讯新闻 YY 访谈：https://news.qq.com/rain/a/20210129A0FD7400
- 墨线手绘参考：https://github.com/JDhruv14/line-art-animation（MIT；只参考，不引入）
- 流媒体网 AI 解说漫流水线：https://lmtw.com/mzw/content/detail/id/247980
- Adobe Animate：https://www.adobe.com/products/animate.html
- Cartoon Animator：https://www.reallusion.com/cartoon-animator/
- Moho：https://moho.lostmarble.com/
- OpenToonz：https://opentoonz.github.io/
- Blender Grease Pencil：https://www.blender.org/features/grease-pencil/
- Phaser：https://github.com/phaserjs/phaser · https://phaser.io/news/2026/07/phaser-4-2-spine-renderer-mesh2d-stencil
- Spine 许可：http://en.esotericsoftware.com/spine-runtimes-license
- DragonBones：https://github.com/DragonBones/DragonBonesJS
- Rive：https://rive.app/runtimes
- Live2D SDK 许可：https://www.live2d.com/en/sdk/license/
- Web Audio：https://www.w3.org/TR/webaudio/
- WebView file/CORS：https://developer.mozilla.org/en-US/docs/Web/HTTP/Guides/CORS/Errors/CORSRequestNotHttp
- Android file access：https://developer.android.com/privacy-and-security/risks/webview-unsafe-file-inclusion
- WKWebView loadFileURL：https://developer.apple.com/documentation/webkit/wkwebview/loadfileurl(_:allowingreadaccessto:)
- Apple macOS SLA：https://www.apple.com/legal/sla/docs/macOS27.pdf
- sherpa-onnx：https://github.com/k2-fsa/sherpa-onnx
- Piper：https://github.com/rhasspy/piper
- Kokoro：https://github.com/hexgrad/kokoro
- Coqui TTS：https://github.com/coqui-ai/TTS
- FFmpeg legal：https://ffmpeg.org/legal.html
- MediaRecorder：https://developer.mozilla.org/en-US/docs/Web/API/MediaRecorder
- OfflineAudioContext：https://developer.mozilla.org/en-US/docs/Web/API/OfflineAudioContext
- Playwright screenshots：https://playwright.dev/docs/test-snapshots
- pyJianYingDraft：https://github.com/GuanYixuan/pyJianYingDraft
