# 音乐创作模块设计方案（创意工作台 · 编曲；2026-11-20 定稿，未施工）

> 状态：**方案定稿，待施工**。本文是唯一方案事实源；施工按 §9 分批推进，
> 每批完成回填本文件的落地锚点（文件:行），与 round 文档纪律一致。
>
> 相关文档：[README.md](README.md)（总纲）· [plan-creative-workbench.md](plan-creative-workbench.md)
> （全局双面/强绑定规范；§5.5 视频→音乐配乐联动依赖本文批次 1–4）。

## 0. 定位升级与产品裁决

| 裁决 | 内容 |
| --- | --- |
| 产品定位 | 「AI 工作台」→ **「创意工作台」**：文档、界面、原型、3D、视频之外，加入**音乐（编曲）**。NaN 仍是唯一执行面（chat agent 控制每个模块） |
| 模块关系 | 音乐是**第五个独立模块**——与设计 / 热应用 / 3D / 视频相互独立。**（2026-11-20 修订，见 plan-creative-workbench.md）** 旧的「设计 → 热应用唯一联动」已被两条新裁决取代：① 验证式原型绑定设计项目本身（不再计入热应用模块）；② **视频 → 音乐配乐联动为显式裁决的跨模块通道**。热应用嵌音乐播放器仍待裁决，默认不做 |
| 能力边界 | **只做编曲**：五线谱 → 代码合成播放。不做：人声 / 录音 / 音频导入（mp3）/ 采样音源库 / MIDI 外接设备 / 实时协作 |
| 实现哲学 | 与视频模块同一裁决族：**代码实现音乐**——谱面是事实源，播放是编译产物（Web Audio 调度代码），确定性、零外联、全离线 |

定位落地面（施工批次 0 的文案清单，逐字对齐 docs/copy-glossary.md）：
README 开头一句话、site/index.html Hero 与四模块卡（→ 五模块卡）、AGENTS.md 产品裁决表、
应用内主页副标题（「热应用 · 3D · 视频」→ 加「音乐」）。应用显示名不变（NaN）。

## 1. 与既有模块的架构对照（一致性锚点）

| 维度 | 设计 | 3D | 视频 | 热应用 | **音乐（本方案）** |
| --- | --- | --- | --- | --- | --- |
| 事实源 | `.mbt` canonical | scene spec | timeline+spec JSON | score（包内 HTML） | **score.json（乐谱文档）** |
| 执行面 | wasm 引擎 | three-live 沙箱 WebView | 代码动画（WebView 播放） | 自包含 HTML WebView | **Web Audio 播放页（WebView）** |
| Agent 工具 | design_op/read_mbt… | three_* | video_review | hotapp_* | **music_*** |
| 确定性验证 | AgentGate 引擎门 | 对照检查（video_review 同族） | review 机械对照 | hotapp 覆盖验证 | **乐谱校验器（§5）** |
| 存放 | 项目 `.ddp` | `portfolio/3d/<name>` | `videos/` 目录扫描 | `hotapps/`（zip 包） | **`portfolio/music/<name>/`**（score.json + NOTICE） |

复用而非新造：`pluginRegistry` 注册（`plugin:music` 视图路由）、`AgentWorkspaceServices`
扩 music 方法、`assembleThreePreview` 同族的 `assembleMusicPlayer`、主页作品集卡加一类。

## 2. 乐谱文档 score.json（唯一事实源）

```json
{
  "v": 1,
  "title": "untitled",
  "tempo": 96,
  "timeSig": [4, 4],
  "keySig": "C",
  "tracks": [
    {
      "id": "melody",
      "name": "主旋律",
      "instrument": "piano",
      "volume": 0.8,
      "muted": false,
      "clef": "treble",
      "measures": [
        { "notes": [
            { "pitch": "C5", "dur": "q", "acc": null, "dot": 0, "tie": null },
            { "pitch": "E5", "dur": "e", "acc": null, "dot": 0, "tie": "start" }
        ] }
      ]
    }
  ]
}
```

* `pitch`：科学音名（`C4`–`B6`；鼓轨用 `kick/snare/hihat/openhat/crash/ride/tom`）。
* `dur`：`w/h/q/e/s`（全/二分/四分/八分/十六分）；`dot` 附点数（0/1）；`tie`：`start|continue|null`。
* `acc`：`sharp|flat|null`（记谱升/降；合成按半音折算）。
* 空小节省略 `notes`（整小节休止）；和弦 = 同一拍位多条 note。
* 轨道数上限 8（音轨 6 + 鼓轨 2），小节上限 256——防失控，校验器报 `score_too_large`。
* `v` 版本字段：解析器只认 `v:1`，更高版本报 `score_unsupported_version`（nonapp 同纪律）。

**为什么是 JSON 不是 DSL**：Agent 工具要确定性读写（读/改小节、补拍），JSON 可校验、
可 diff、可被编辑器与工具双端消费；与 video timeline+spec JSON 同族。人类不手写它——
人类画五线谱（§3），Agent 经工具改它。

## 3. 五线谱绘制器（编辑器，桌面优先）

* **渲染**：Flutter `CustomPainter` 程序化绘制——五线谱线、谱号（高音/低音/打击，代码画
  而非 SMuFL 字体，零依赖）、符头/符干/符尾/符杠、附点、升降号、小节线、连音线、
  拍号/调号、播放头。缩放 50–150%。
* **输入**：选中轨道 → 时值工具条（w/h/q/e/s · 附点 · 休止 · 升/降/还原）→ 在谱上点击
  放音（行/间即音高）；同拍位叠点 = 和弦；拖动移音；右键/删除键删音；小节加删。
* **事实源纪律**：编辑器直接改 score.json（与设计画布同门：**一切交互最终落成一次
  文档变更**），撤销栈按项目（对齐引擎 history 边界语义）。
* **播放头**：播放时按拍推进（§4 播放页回传拍位消息）。
* **移动端**：手机可**查看谱面缩略 + 播放**；画谱交互以桌面为主（编辑器桌面优先，
  手机不放完整输入工具条）。

## 4. 代码实现音乐（编译 → Web Audio 播放页）

* **编译**：`assembleMusicPlayer(score)`（`assembleThreePreview` 同族）→ **自包含单文件
  HTML**：内嵌 score.json 字面量 + 调度器 JS + 合成器音色代码。零外联、零依赖、
  `file://` 打开即可响。
* **调度**：标准 lookahead（25ms 定时器排 100ms 窗口内的音符事件到 `AudioContext`
  时钟）；播放/暂停/停止、每轨音量/静音、拍位回传（`window.NONMUSIC` 桥消息族：
  `beat` / `ended` / `error`，与 three 的 `window.NON3D` 同模式）。
* **合成音色（纯代码，编曲 v1 六种 + 鼓组）**：
  `piano`（三角波+正弦混合快攻）、`strings`（锯齿慢攻+低通）、`bass`（正弦低八度）、
  `bell`（FM 正弦）、`organ`（加法正弦叠置）、`pluck`（衰减锯齿）；鼓组 = 噪声脉冲 +
  定音高扫频正弦（kick/snare/hihat/openhat/crash/ride/tom）。
* **确定性**：同一 score.json 两次编译字节相同（测试锚定，与 sync 探针同纪律）。
* **CSP**：比 three 更紧——调度器不需要 `eval`：`default-src 'none'; script-src
  'unsafe-inline'; worker-src 无; connect-src 'none'; frame-ancestors 'none'`。
  `AudioContext` 需用户手势启动（播放按钮即手势，符合策略）。
* **导出（拉伸项，v1 不做）**：离线 HTML 单文件（热应用式）；MIDI 导入/导出。

## 5. 乐谱校验器（确定性验证，hotapp 覆盖验证同族）

`verifyScore(score)` 纯函数，产出 `{verified: bool, checks[]}`，校验：
每小节时值总和 == 拍号（休止补齐）；音名/八度/时值/附点/连音线配对合法；
`instrument` 在合成器注册表内；`tempo` ∈ [20, 300]；轨道/小节上限；
鼓轨音名在鼓件表内。**校验失败不阻断入库**，结果如实上报（`verified=false` + 失败清单
人话摘要）——与 hotapp「如实标注未通过项」同一裁决。

## 6. Agent 工具面（music_*，workspace 模式工具集）

| 工具 | 入参 | 语义 |
| --- | --- | --- |
| `music_list` | – | 列出本机音乐项目（名称/轨道数/小节数/时长） |
| `music_create` | `name`, `brief` | 由 brief 作曲：Agent 产出 score.json，过校验器入库 |
| `music_read` | `name` | 读乐谱文档（整谱 JSON） |
| `music_patch` | `name`, `json_patch` | 确定性改谱（RFC6902 风格补丁；改后自动校验，结果如实回报） |
| `music_inspect` | `name` | 摘要面：轨道/小节/时长/校验状态（不回全谱，省上下文） |

* 人话映射（`toolFailureMessage`）：`score_invalid`（哪里不对，按校验器清单）、
  `score_not_found`、`score_too_large`、`score_unsupported_version`、`music_busy`…
  **裸错误码一律不进气泡**（copy-glossary 纪律）。
* 提示词教学：WORKSPACE TOOLS 区加一行 + 「编曲写谱后先过校验器再交付」纪律。
* `AgentWorkspaceServices` 扩 5 个方法；`LocalWorkspaceServices` 实现（工厂可注入，
  测试不落用户目录——三服务同模式）。

## 7. 工作台 UI 与接线

* `music_workspace.dart`：左侧轨道/小节面板，中部五线谱画布（横向滚动），底部播放
  控制条（播放/暂停/停止 · BPM · 轨道音量/静音）。顶部工具条与三个工作台同语言
  （返回主页按钮——tooltip 不带快捷键后缀）。
* `pluginRegistry` 注册 `PluginDef(id: 'music', ...)`；主页作品集卡加「音乐」类
  （`portfolio/music/` 扫描，与 3D 同模式）；工作台跟随项目（打开音乐项目 → 落
  `plugin:music` 视图，既有裁决）。
* `portfolio_entries.dart` 加音乐条目读取；艺术架不在范围（音乐不经艺术架）。

## 8. 平台、存储与文案

* 存储：`~/Documents/NoNDesign/portfolio/music/<name>/score.json`（+`NOTICE.md` 记
  来源）；最近项目列表照常收音乐项目。
* 平台：桌面完整（编辑+播放）；手机播放+查看；Web 不在范围。
* 文案纪律：错误只给人话（§6 映射）；界面不出现 JSON/patch/校验器等内部词——
  「乐谱检查」/「小节拍数不对：第 3 小节多出半拍」这类说法。
* 可诊断性：编译/校验失败进 `logs/` JSONL（agent run 日志族），界面折叠详情给原始诊断。

## 9. 施工分批（每批可独立验收）

| 批次 | 内容 | 验收 |
| --- | --- | --- |
| 0 | 定位文案落地面（§0 清单，README/site/AGENTS/主页副标题） | copy_guard + 文案扫描绿 |
| 1 | score 模型 + 解析/校验器 + `assembleMusicPlayer` 编译器 + 确定性测试 | 纯 Dart 单测：校验清单/字节确定性/播放页 CSP 自检 |
| 2 | 五线谱编辑器（绘制 + 输入 + 播放头） | widget 测试：放音/拖移/删除/小节操作；谱面重绘确定性 |
| 3 | 工作台接线（registry / 作品集 / 项目跟随）+ 存储扫描 | 打开音乐项目落 `plugin:music`；主页作品集出现音乐类 |
| 4 | Agent 工具面 + 提示词 + 人话映射 + 排队续跑兼容 | 工具接线测试（workspace tools 全绿家族）+ 脚本化全链 |
| 5（拉伸） | 离线 HTML 导出 / MIDI 导入导出 / 三连音与装饰音 | 另立裁决再开工 |

## 10. 明确不做（v1 边界，防蔓延）

人声与歌词、录音、音频文件导入、采样音源/SF2、MIDI 外接、五线谱识别（OMR）、
实时协作、乐谱打印排版级精细度（出版级排版是另一档工程）、复杂记谱（三连音/
装饰音/力度记号→批次 5 后另裁决）、设计→音乐与音乐→热应用等跨模块联动
（**例外**：视频→音乐配乐联动为 2026-11-20 显式裁决，见 plan-creative-workbench.md §5.5）。
