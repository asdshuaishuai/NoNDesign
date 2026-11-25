# 音乐模块契约（编曲工作台 · score.json 唯一事实源）

> 状态：**R1 契约核心 + 编辑闭环 + 播放页编译产物已落地（2026-11-24/25）· 播放 UI 接入/music_* 工具/五线谱编辑器未施工**。已落地：
> score.json v1 解析/未知字段保留、`verifyMusicScore` 硬门、整数 tick 编译器（ppq=3840）、
> `MusicProjectStore` 存储；`plugin:music` + `MusicWorkspace` 只读钢琴卷帘/检查器/运输条；
> `music_edit.dart` 最小编辑闭环（纯函数 + 可保存检查器）；`music_player.dart` 自包含
> Web Audio 播放页编译产物（CSP/确定性/六音色）；本文契约增量：
> score.json v1、整数 tick 编译、`verifyScore`（拟实现）硬门、五线谱、播放页、存储、工具族、配乐联动与验收。
>
> 相关：[plan-music-module.md](plan-music-module.md)（方案事实源）·
> [research/music-arrangement-howto.md](research/music-arrangement-howto.md)（时间模型/排版/调度）·
> [plan-creative-workbench.md](plan-creative-workbench.md) §1.2（四件套）与 §5.5（配乐联动）·
> [creative-refactor-decisions.md](creative-refactor-decisions.md)（R0 冻结与口径冲突）。

## 1. 事实源 `score.json` v1

* 唯一的**乐谱文档**：只存音乐语义（音高/时值/声部/关系/用户覆盖），**不存算出的 x/y 布局**；人类画五线谱（§4），Agent 经工具改它（§7），一切交互落成一次文档变更。
* 播放是编译产物（Web Audio 调度代码），不是第二事实源；MusicXML / MEI / MIDI 只做导入导出适配器，不进编辑器内存模型。

| 字段 | 契约 |
| --- | --- |
| `schemaVersion` | 整数，解析器只认 `1`；读 N-1 写 N；更高版本报 `score_unsupported_version`；未知字段保留、不静默丢弃 |
| `title` / `tempo` / `timeSig` / `keySig` | `tempo ∈ [20, 300]`；`timeSig` 如 `[4, 4]`；`keySig` 调号语义（如 `"C"`） |
| `tracks[]` | `{id, name, instrument, volume, muted, clef, measures[]}`；**轨道 ≤8**；`instrument` 必须命中合成器注册表（§5），鼓轨用鼓件表音名 |
| `measures[]` | `{id, events[]}`；**小节 ≤256**；空小节省略事件 = 整小节休止；小节时值总和必须等于拍号（休止补齐） |
| `events[]` | note：`{id, pitch:{step, alter, octave}, dur:{num, den}, dot:0/1}`；另有 rest；和弦 = 同一拍位多条 note；`tuplet` 可选 `{n, in, group}`（三/五连音；**七连音 v1 拒绝**） |
| `relations[]` | 关系对象 `Beam{id, events[]}` / `Tie{id, from, to}` / `Slur{id, from, to}`，引用**稳定事件 ID**；**不在单个 note 上写 `beam=true` / `tie=start`** |

* 时值语义：**有理数** `dur{num,den}`（全音符 = 1，四分 = 1/4，八分 = 1/8）；附点 = ×3/2；不在 JSON 里存拍点浮点数。`pitch` 保留拼写语义（`step` C–B、`alter` 记谱升降 -1/0/1、`octave`），播放时折算 MIDI。
* 事件、关系、小节都有**稳定 ID**；编辑/撤销按 ID，不按数组下标。plan-music §2 的早期示例（`"v": 1`、note 级 `pitch:"C5"` / `tie:"start"`）与本节口径不同，按 decisions §4 登记，plan 待 R1 回填修订。

## 2. 编译到整数 tick（纯函数）

```
score.json（有理数）
   │  编译期纯函数
   ▼
PlayPlan（整数 tick；ppq = 3840；tempoMap；events）
   │  Web Audio lookahead
   ▼
AudioContext.currentTime
```

* **`ppq = 3840`**：四分 = 3840 tick；三连音 = 1280、五连音 = 768；七连音 = 548.57 → **v1 拒绝**（不提高 ppq 换精度）。所有 `start`/`dur` 编译成 `int tick`，运行时不再出现 `double` 拍点。
* tempo map 用分段常数 BPM；渐快/渐慢拆小段，不做连续插值；秒只在播放/导出时派生 `sec = tick * 60 / (bpm * ppq)`。
* 确定性：同一 `score.json` 两次编译**字节相同**（测试锚定）；`PlayPlan` 是纯函数，事件时间单调、无 NaN。版本迁移：读 N-1 写 N、固定 fixture，只改字段形状不改音乐语义。

## 3. `verifyScore`（**拟实现**）硬门清单（纯函数 → `{verified, checks[]}`）

| 检查 | 判据 |
| --- | --- |
| 版本 | `schemaVersion` 存在且 = 1（更高版本 → `score_unsupported_version`） |
| 小节容量 | 每小节时值总和 == 拍号（休止补齐）；单声部/拍点不重叠 |
| 音高与时值 | `step/alter/octave` 合法；`dur{num,den}` 正数；`dot` 0/1；三/五连音合法 |
| 关系对象 | tie 目标存在且同音高；beam 同声部；slur 端点存在；跨小节 tie 合法 |
| 乐器 | `instrument` 在合成器注册表内（六音色）；鼓轨音名在鼓件表内 |
| 范围/结构 | `tempo ∈ [20, 300]`；轨道 ≤8；小节 ≤256；音符在乐器音域内（音域表待 R1，decisions §3）；反复/跳转结构合法 |

* 以上规则都是**硬门**，任一失败 → `verified=false` + 失败清单；但**校验失败不阻断入库**（hotapp 覆盖验证同族纪律）：如实上报 + 人话摘要，界面折叠原始诊断。
* 四部写作/平行五八/声部交叉等**编曲生成规则**在生成器验收（plan 批次 6 / M2）另行校验，不塞进 `score.json` 结构校验器。用户文案：`score_invalid`（说「哪小节多出半拍」）、`score_not_found`、`score_too_large`、`score_unsupported_version`、`music_busy` 等经 `toolFailureMessage` 映射，裸错误码不进气泡（copy-glossary 纪律）。

## 4. 五线谱渲染（纯 Dart，桌面优先）

* 主路径：Flutter `CustomPainter` 程序化绘制——五线谱线、谱号、符头/符干/符尾/符杠、附点、升降号、小节线、连音线、拍号/调号、播放头；缩放 50–150%，高 DPI 用逻辑 px。
* 度量：**SMuFL 1.4** + **Bravura**（**SIL OFL 1.1**，可嵌入商业软件；保留 OFL；不单独售卖字体；固定版本 + metadata，不依赖系统字体）。谱号等字形「代码画 vs Bravura 字形」两说（plan §3 vs research §2.2）待 R1 冻结（decisions §4）。
* 交互：选中轨道 → 时值工具条 → 谱上点击放音（行/间即音高）→ 同拍位叠点 = 和弦 → 拖动移音/删除/小节加删；撤销栈按项目，交互最终落成一次 score.json 变更。
* **WebView 不进主编辑链**：只做只读 MusicXML/MEI 预览副路径；不在本地资源/零端口上绕一圈（research §2.1、§8）。移动端查看谱面缩略 + 播放，完整画谱交互以桌面为主。

## 5. Web Audio 播放页（编译产物）

* `assembleMusicPlayer(score)`（**拟实现**，`assembleThreePreview` 同族）→ **自包含单文件 HTML**：内嵌 score.json 字面量 + 调度器 JS + 合成器代码；零外联、`file://` 打开即响。
* 调度：标准 lookahead——`setInterval` **25ms**、提前 **100ms** 把事件排进音频时钟（后台节流时 ahead 提到 2s）；**`AudioContext.currentTime` 是唯一时钟**，定时器回调里不直接 `start()`。暂停/seek：`cancelScheduledValues` + 短淡出 + `stop` + `generation` 代际号丢弃旧调度。
* 音色（纯代码）：`piano` / `strings` / `bass` / `bell` / `organ` / `pluck` 六种 + 鼓组（kick/snare/hihat/openhat/crash/ride/tom）；不引大采样库、不依赖 Tone.js。
* CSP 比 3D 更紧：`default-src 'none'; script-src 'unsafe-inline'; connect-src 'none'; frame-ancestors 'none'`；`AudioContext` 需用户手势启动（播放按钮即手势）。
* 桥（拟实现）：`window.NONMUSIC` 回传 `beat` / `ended` / `error`；播放/暂停/停止、每轨音量/静音、拍位回传（与 `window.NON3D` 同模式）。原生备选：`PlaybackEngine` 接口接 `flutter_soloud`（MIT），**不改变 score.json 事实源**。导出（拉伸，v1 不做）：离线 HTML 单文件。

## 6. 存储、工作台与项目跟随

* `~/Documents/NoNDesign/portfolio/music/<name>/score.json`（+ `NOTICE.md` 记来源）；与 3D 同模式扫描；最近项目列表收音乐项目。
* `pluginRegistry` 注册 `plugin:music`；工作台跟随项目（打开音乐项目落音乐工作台）；主页作品集加「音乐」类；艺术架不在范围（音乐不经艺术架）。平台：桌面完整（编辑 + 播放），手机播放 + 查看，Web 不在范围。

## 7. Agent 工具族（`music_*`，**拟实现**，链接 [plan-music-module.md](plan-music-module.md) §6）

| 工具（拟实现） | 语义 |
| --- | --- |
| `music_list` | 列本机音乐项目（名称/轨道数/小节数/时长） |
| `music_create` | 由 brief 产 score.json，过校验器入库 |
| `music_read` | 读整谱 JSON |
| `music_patch` | RFC6902 风格确定性补丁；改后自动校验并如实回报 |
| `music_inspect` | 摘要面（轨道/小节/时长/校验状态），不回全谱 |

* workspace 模式只暴露 `music_*` + 通用只读；跨模块动作只走裁决过的联动通道（§8）。`AgentWorkspaceServices` 扩方法、`LocalWorkspaceServices` 实现（工厂可注入，测试不落用户目录）；成功产物走 workspace 产物认领链；提示词教学加「写谱后先过校验器再交付」。

## 8. 与视频的配乐联动（第二条跨模块通道）

* 视频项目 `musicRef` 指向音乐项目；链接前必须 `verifyScore` 通过（plan §5.5）。共享时钟播放 + 导出时混入配乐（拉伸）在联动批次（7）实现；per-track bounce 是拉伸项。
* **单一音频宿主**：成片里所有声音在视频页同一个 `AudioContext` 调度；音乐页只发播放/暂停/seek/音量指令，不各自建时钟。跨页面 `postMessage` 只能到预览级对齐，**不能采样级**（research §5.4）。

## 9. 验收锚点（拟写测试名，施工时落地）

| 契约面 | 拟写测试 | 锚定 |
| --- | --- | --- |
| schema / 契约 | `music_score_test.dart`（已落地） | roundtrip、未知字段保留、轨道/小节上限、七连音拒绝 |
| 版本迁移 | `music_score_migration_test.dart` | 读 N-1 写 N、固定 fixture、不支持版本报错 |
| tick 编译 | `music_compile_test.dart`（已落地） | ppq=3840、三/五连音、tempoMap、字节确定性、无浮点拍点 |
| 校验器 | `music_score_test.dart`（已落地） | 小节时值/关系配对/乐器/范围/鼓件正反例 |
| 播放页 | `music_player_test.dart`（已落地） | CSP 自检、零外联、lookahead 参数、无 Tone.js/采样、字节确定性 |
| 编辑器/工作台 | `music_edit_test.dart` + `music_workspace_test.dart`（已落地部分） | 标题/tempo/小节/音符/休止编辑→保存→重读；校验结果如实显示；放音/拖移与 `music_*` 工具待后续 |

**编辑锚点**：`music_edit_test.dart`（已落地，16 例）；**播放页锚点**：`music_player_test.dart`（已落地，10 例）。

**存储锚点**：`music_project_test.dart`（已落地）：save→list/read、坏名/坏文件显性失败、delete。

**落地文件**：`app/lib/core/music/music_score.dart` / `music_compile.dart` / `music_project.dart`。

## 10. 不做（v1 边界）

人声与歌词、录音、音频文件导入、采样音源/SF2、MIDI 外接、五线谱识别（OMR）、实时协作、出版级排版、复杂记谱（批次 5 后另裁决）、设计→音乐 / 音乐→热应用等跨模块联动（**例外**：视频→音乐为显式裁决，§8）。
