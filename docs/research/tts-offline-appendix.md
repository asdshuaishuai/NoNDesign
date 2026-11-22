# 视频动画离线配音 / 口型 / 音效技术报告

> 目标场景：Flutter 五端（macOS / Windows / Linux / iOS / Android），离线优先、零外联；视频工作台为自包含 HTML + WebView 播放；需要为「沙雕短剧」生成角色台词、时间对齐、简单口型、音效，并支持视频页与音乐页的配乐联动。
>
> 阅读约定：**[事实]** = 有来源或本机实测；**[实测]** = 本机命令实测；**[推断]** = 基于事实的工程判断，不是直接引用。

---

## 目录

1. 离线 TTS 方案对比
2. 高质量离线 TTS
3. 时间对齐
4. 口型与表情
5. 音效
6. 配乐联动
7. 最小可行架构
8. 不要做清单
9. 推荐方案 + 风险 + 备选
10. 来源清单

---

## 0. 结论摘要

1. **OS 音色不能作为对外发布视频的默认音色**。Apple 的 macOS 软件许可明确把 System Voices 限制在「个人、非商业」用途，并禁止录制/再分发到商业场景（[macOS SLA](https://www.apple.com/legal/sla/docs/macOS27.pdf)）。这是本报告最重要的法律结论。
2. **跨平台最干净的内置 neural TTS 路线是 sherpa-onnx（Apache-2.0）+ 许可清晰的模型**（Matcha zh-baker 73MB、Kokoro int8、VITS-zh 系列），一套 Dart/Flutter API 覆盖五端，且自带 forced alignment 能力（[sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)、[Flutter 包](https://pub.dev/packages/sherpa_onnx)）。
3. **时间对齐不要追求词级精确**。沙雕短剧只需「句级真实时长 + 字级估算」，配合原生时间戳（Windows SAPI Bookmark、Android onRangeStart）或强制对齐（MFA / WhisperX / sherpa-onnx）即可。
4. **口型 6 个 viseme + 表情层足够**，从拼音声母/韵母映射，再用音频 RMS 包络驱动开合；不要逐帧 FFT。
5. **音效优先程序化生成**（pop / boing / whoosh / scratch / drum 均可合成），必须采样的只保留人声笑声、脚步、环境声等；采样库优先 Kenney CC0、Freesound CC0/CC-BY，避开 BBC RemArc（非商用）。
6. **配乐联动的最优解是「单一音频宿主」**：所有声音在一个 WebView 的同一个 AudioContext 里调度，音乐页只发指令不发声；跨页面用 postMessage 对齐时钟只能做到预览级，不能做到采样级。
7. **导出走离线混音**（Dart PCM 混音或 OfflineAudioContext），桌面用系统 ffmpeg 封装，移动端用 AVAssetWriter / MediaMuxer；不要用已退役的 FFmpegKit。

---

## 1. 离线 TTS 方案对比

### 1.1 平台原生能力总表

| 平台 | 方案 | 音质/音色 | 语言 | 输出格式 | 时间戳 | 延迟 | 许可 |
|---|---|---|---|---|---|---|---|
| macOS | `/usr/bin/say` | 187 个音色（本机实测），含 Tingting、Eddy/Flo/Grandma/Grandpa/Rocko 等中文音色；Siri 音色不可见 | 多语言 | AIFF / WAVE / CAF / m4af，可指定 `--data-format=LEI16@22050`（[man page](https://ss64.com/mac/say.html)） | 无 | 本机实测：3.48s 音频耗时 0.95s（含进程启动） | **系统音色仅个人非商业**（[macOS SLA](https://www.apple.com/legal/sla/docs/macOS27.pdf)） |
| Windows | SAPI 5 / `System.Speech.Synthesis` | 取决于系统语言包；Win10/11 通常有 David/Zira，中文系统有 Huihui/Yaoyao/Kangkang 等；Win11 的 Natural Voices 不暴露给 SAPI | 多语言 | WAV（`SetOutputToWaveFile`） | **有**：`BookmarkReached` 事件带 `AudioPosition`（[文档](https://learn.microsoft.com/en-us/dotnet/api/system.speech.synthesis.speechsynthesizer.bookmarkreached)） | PowerShell 启动 300–800ms，合成本身快 | 随 Windows 授权；商业再分发需法务确认 |
| Linux | espeak-ng | 机器人音，可懂；中文一般 | 100+ 语言 | WAV（`-w`） | **有**：`--pho` 输出带时长的音素数据；`-x`/`--ipa` 输出音素 | 极快 | **GPL-3.0**（[repo](https://github.com/espeak-ng/espeak-ng)） |
| iOS | `AVSpeechSynthesizer` | 系统音色，quality 分 default/enhanced/premium（[文档](https://developer.apple.com/documentation/avfaudio/avspeechsynthesisvoicequality/premium)） | 多语言 | 通过 `write(_:toBufferCallback:)` 拿 PCM buffer（iOS 13+），再写 `AVAudioFile`（[文档](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer/write(_:tobuffercallback:))） | `willSpeakRangeOfSpeechString` 仅实时播放回调；文件合成无时间戳 | 低 | 随 iOS 授权；商业输出需法务确认 |
| Android | `TextToSpeech` | 取决于引擎（Google TTS / 厂商引擎）；高质量音色通常联网，离线音色质量较低（[讨论](https://groups.io/g/blindandroidusers/topic/google_tts_sounds_low_quality/101803068)） | 多语言 | `synthesizeToFile`，格式由引擎决定（常见 WAV） | **有**：`onRangeStart(utteranceId, start, end, frame)`，`frame` 是音频帧偏移（[API](https://developer.android.com/reference/android/speech/tts/UtteranceProgressListener)） | 低 | 引擎相关；Google TTS 受其条款约束 |

### 1.2 各平台细节与坑

**macOS `say`**

- **[实测]** `say -v '?'` 本机列出 187 个音色；中文有 Tingting、Meijia、Sinji，以及 Eddy/Flo/Grandma/Grandpa/Reed/Rocko/Sandy/Shelley 等较新的多语言音色。
- **[实测]** `say -v Tingting -o out.wav --file-format=WAVE --data-format=LEI16@22050 "…"` 输出 22.05kHz / 16-bit / 单声道 WAV。
- **[实测]** `[[slnc 1000]]` 可在文本中插入约 1 秒静音（0.726s → 1.614s，差 0.89s），适合做喜剧停顿；`[[pbas]]`、`[[rate]]` 也可用。
- **[实测]** `-o out.m4a` 默认仍是 LPCM（m4af 容器），不是 AAC；要压缩得显式指定 `--data-format=aac`。
- **[事实]** Siri 音色不在 `say -v '?'` 列表中，`say` 无法使用（[StackOverflow](https://stackoverflow.com/questions/61122378/make-the-say-terminal-utility-and-nsspeechsynthesizer-work-with-siri-voices)）。
- **[事实]** macOS SLA 原文（F 节）：

  > "use the system voices included in the Apple Software (“System Voices”) (1) while running the Apple Software and (2) to create your own original content and projects **for your personal, non-commercial use** … No other creation or use of the System Voices … is permitted … including … **recording, publishing or redistribution** … in a profit, non-profit, public sharing or commercial context."

  这意味着：**用 `say -o` 生成音频再随视频发布到抖音/B站/YouTube，属于被禁止的公开分享/商业场景**。这不是「音质问题」，是许可证红线。

**Windows SAPI**

- **[事实]** `SpeechSynthesizer.SetOutputToWaveFile` 可直接写 WAV（[文档](https://learn.microsoft.com/en-us/dotnet/api/system.speech.synthesis.speechsynthesizer.setoutputtowavefile)）。
- **[事实]** 配合 `PromptBuilder.AppendBookmark` 与 `BookmarkReached`，事件参数 `e.AudioPosition` 给出书签在音频流中的位置（[文档示例](https://learn.microsoft.com/en-us/dotnet/api/system.speech.synthesis.speechsynthesizer.bookmarkreached)）。这是 **Windows 上最好的原生时间戳机制**：每句/每词前插 bookmark，就能拿到精确音频位置。
- **[事实]** Win11 的 Natural Voices（Aria/Guy/Jenny 等）只服务于 Narrator/Edge Read Aloud，`System.Speech` 枚举不到；需要第三方适配器才能进 SAPI 列表（[NaturalVoiceSAPIAdapter](https://github.com/gexgd0419/NaturalVoiceSAPIAdapter)）。
- **[推断]** 因此 Windows 上的音质天花板是「系统 SAPI 音色 + 第三方 SAPI 音色」；想要 neural 音质必须自带模型。
- **[推断]** PowerShell 调用建议固定用 `powershell.exe`（Windows PowerShell 5.1），因为 `System.Speech` 在 PowerShell 7 里默认不一定可加载；并加 `-NoProfile -ExecutionPolicy Bypass`。64 位宿主只看到 64 位注册的 SAPI 音色，32 位音色需要 32 位宿主。

**Linux espeak-ng**

- **[事实]** `-w out.wav` 写 WAV；`-v zh` 中文；`-s` 语速、`-p` 音高、`-a` 振幅；`-x`/`--ipa` 输出音素；`--pho` 输出 MBROLA 音素数据（含时长），`--phonout` 指定文件（[man page](https://github.com/espeak-ng/espeak-ng/blob/master/src/espeak-ng.1.ronn)）。
- **[事实]** 支持 `-m` 解析部分 SSML；`-D` 确定性随机模式。
- **[推断]** `--pho` 是 Linux 上免费的「音素级时间戳」来源：解析每个音素的 duration，累加即可得到音素边界，再映射 viseme。这比强制对齐轻量得多。
- **[事实]** 代码许可证 GPL-3.0。若随闭源应用分发，需要履行 GPL 义务（提供对应源码/许可）；作为独立可执行文件通过 `Process.run` 调用，通常被视为聚合而非链接，但仍建议法务确认。

**iOS AVSpeechSynthesizer**

- **[事实]** `write(_:toBufferCallback:)` 可以拿到合成音频的 `AVAudioBuffer`，写入 `AVAudioFile` 即可落盘（[Apple 文档](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer/write(_:tobuffercallback:))；`flutter_tts` 也注明 synthesize-to-file 需要 iOS 13+，[pub.dev](https://pub.dev/packages/flutter_tts)）。
- **[事实]** `AVSpeechSynthesisVoice.speechVoices()` 返回可用音色，`quality` 分 default / enhanced / premium；enhanced/premium 通常需要用户下载（[文档](https://developer.apple.com/documentation/avfaudio/avspeechsynthesisvoicequality/premium)）。
- **[推断]** 文件合成路径没有词级时间戳；`willSpeakRangeOfSpeechString` 只在实时 `speak` 时回调。要时间戳就按句拆分成多个 utterance，分别统计每个 buffer 的帧数。

**Android TextToSpeech**

- **[事实]** `synthesizeToFile` 写文件；`UtteranceProgressListener.onRangeStart` 在 API 26+ 给出字符区间和音频帧偏移（[API](https://developer.android.com/reference/android/speech/tts/UtteranceProgressListener)）。
- **[事实]** 高质量 Google 音色通常走网络，离线音色质量较低；不同厂商引擎差异大（[讨论](https://groups.io/g/blindandroidusers/topic/google_tts_sounds_low_quality/101803068)）。
- **[推断]** 必须在运行时枚举引擎与语言可用性（`TextToSpeech.getEngines()`、`isLanguageAvailable`），不能假设 Google TTS 一定存在；国产 ROM 可能只有厂商引擎。

### 1.3 Flutter 里怎么调用

| 路径 | 适用 | 做法 | 注意 |
|---|---|---|---|
| Dart `Process.run` | macOS / Windows / Linux 桌面 | macOS 调 `say`；Windows 调 `powershell.exe -File synth.ps1`；Linux 调 `espeak-ng` | 应用已用 `Process.run` 调 ffmpeg（`/Volumes/data/dev/coding/deepcodeUI/deepStudio/NoNDesign/app/lib/core/video_service.dart`），同一套模式可复用；注意路径探测（`which`/`where`）与超时 |
| MethodChannel + 原生 | iOS / Android | Swift 调 `AVSpeechSynthesizer.write`；Kotlin 调 `TextToSpeech.synthesizeToFile` | 需要自己写小插件；`flutter_tts` 只覆盖 synthesizeToFile（Android/iOS），macOS 不支持写文件（[pub.dev](https://pub.dev/packages/flutter_tts)） |
| `sherpa_onnx` Flutter 包 | 五端统一 | Dart FFI 直接加载 ONNX 模型，TTS + forced alignment | Apache-2.0；模型放 assets 或应用支持目录；首次加载有 100–500ms 开销（[pub.dev](https://pub.dev/packages/sherpa_onnx)） |

**打包注意**

- macOS：`/usr/bin/say` 一定存在；若启用 App Sandbox，`Process.run` 可能被限制，当前 Flutter 桌面默认不沙箱，保持现状即可。
- Windows：PowerShell 5.1 一定存在；不要依赖用户安装 PowerShell 7。把 `.ps1` 放 assets，运行时释放到临时目录再执行。
- Linux：espeak-ng 不保证预装；要么在安装包中附带二进制 + `espeak-ng-data`（约 10MB），要么直接走 sherpa-onnx。
- iOS：音频会话设为 `.playback` 或 `.ambient`（需要与音乐共存时用 `.ambient + mixWithOthers`），否则会打断其他音频。
- Android：API 30+ 需要在 `AndroidManifest.xml` 的 `<queries>` 声明 `android.intent.action.TTS_SERVICE`（`flutter_tts` 文档也明确要求，[pub.dev](https://pub.dev/packages/flutter_tts)）。
- 模型体积：Android AAB 基础包有 200MB 量级限制，iOS 蜂窝下载也有限制；100MB+ 模型建议做「首次启动从本地文件导入」或按语言分包，保持零联网。

---

## 2. 高质量离线 TTS

### 2.1 模型对比

| 方案 | 代码许可 | 模型/音色许可 | 体积 | CPU 实时率（RTF，Pi4 4 线程） | 中文 | 备注 |
|---|---|---|---|---|---|---|
| **Piper**（rhasspy/piper） | MIT，**已归档**（2025-10） | **逐音色不同**：CC0 / CC-BY / MIT / 研究限定都有 | medium 约 61–75MB | 0.357（en_US-lessac-medium，61MB） | zh_CN-huayan-medium 约 63MB | 无时间戳；`--length-scale` 可控时长 |
| **Piper 新版**（OHF-Voice/piper1-gpl） | **GPL-3.0** | 同上 | 同上 | 同上 | 同上 | 许可证从 MIT 变为 GPL-3.0（[repo](https://github.com/OHF-Voice/piper1-gpl)） |
| **Kokoro-82M** | Apache-2.0 | **Apache-2.0** | fp32 310MB；int8 约 80–90MB；voices.bin 26MB | 3.191（multi-lang v1.0，311MB） | 53/103 speakers 中含 8 个中文音色（zf_xiaobei / zf_xiaoni / zf_xiaoxiao / zf_xiaoyi / zm_yunjian / zm_yunxi / zm_yunxia / zm_yunyang） | 质量高、体积大；sherpa-onnx 有 int8 版本（[文档](https://k2-fsa.github.io/sherpa/onnx/tts/pretrained_models/kokoro.html)） |
| **sherpa-onnx**（运行时） | Apache-2.0 | 取决于模型 | 30–311MB | 0.156–7.635 | 多套中文模型 | 五端 + Dart；自带 forced alignment；可跑 VITS/Piper/Kokoro/Matcha/Melo |
| **VITS 系列** | MIT（代码） | 逐模型不同 | 30–163MB | 0.156–6.7 | vits-zh-hf-fanchen 116MB / aishell3 30MB / vits-melo 163MB | 经典、稳定；音质取决于训练集 |
| **Matcha-TTS** | MIT | 逐模型不同（zh-baker 常用） | 73MB（zh-baker） | 0.391 | 中文女声 | 轻量、快，适合随包 |
| **MeloTTS** | MIT | 仓库 MIT | 163MB（sherpa 版 vits-melo） | 2.518 | 中英 | 质量好，但 CPU 偏慢 |
| **Coqui TTS / XTTS** | 代码 MPL-2.0 | **XTTS 为 CPML，仅非商业** | 数 GB | 慢 | 多语言 | **不建议**：公司 2024 年已关闭，CPML 禁止商用（[LICENSE](https://huggingface.co/coqui/XTTS-v2/blob/main/LICENSE.txt)、[讨论](https://github.com/coqui-ai/TTS/discussions/2960)） |

> RTF 数据来自 sherpa-onnx 官方在 Raspberry Pi 4 上的实测表（[RTF 页](https://k2-fsa.github.io/sherpa/onnx/tts/pretrained_models/rtf.html)）。**[推断]** 桌面 x86/Apple Silicon 通常快 5–20 倍；Pi4 上 RTF 3.19 的 Kokoro，在 M 系列/现代 x86 上大致是 0.2–0.8 RTF，仍需以目标机实测为准。

### 2.2 关键结论

- **Piper 的「代码许可」和「音色许可」是两件事**。仓库 MIT（旧版）不代表音色可商用；Piper 官方讨论明确说音色许可证随训练数据集而变，Blizzard 数据集派生的音色仅限研究，LibriTTS（CC-BY）派生的可以商用但需署名（[discussion #271](https://github.com/rhasspy/piper/discussions/271)）。**[推断]** 随包分发 Piper 音色前，必须逐音色读 model card，不能看仓库 LICENSE 就下结论。
- **Kokoro 是许可证最干净的高质量选择**：权重 Apache-2.0，可商用；但它的英文 G2P 依赖 espeak-ng，**[推断]** 若把 espeak-ng 静态链入，GPL-3.0 会污染分发物；sherpa-onnx 也常带 espeak-ng-data。闭源分发前要做依赖审计，或把 G2P 放在独立进程。
- **sherpa-onnx 是运行时的最佳载体**：Apache-2.0、五端、Dart API、支持 TTS + 强制对齐 + VAD（[repo](https://github.com/k2-fsa/sherpa-onnx)、[Flutter](https://pub.dev/packages/sherpa_onnx)）。模型可以换，运行时不用换。
- **Coqui 直接排除**：XTTS 的 CPML 明确「仅非商业」，且公司已停止运营，无法购买商业授权（[CPML](https://coqui.ai/cpml)、[issue #3490](https://github.com/coqui-ai/TTS/issues/3490)）。

### 2.3 随包分发 vs OS 音色

| 维度 | OS 音色 | 随包 neural |
|---|---|---|
| 体积 | 0 | 30–150MB/语言 |
| 音质 | 机械—中等；macOS 新音色尚可 | 接近自然；Kokoro > Matcha/Melo > VITS > Piper |
| 一致性 | 每台机器不同，随 OS 更新变化 | 完全一致 |
| 延迟 | 极低（本机实测 macOS 含启动 <1s） | 首次加载 100–500ms，之后快 |
| 许可证 | **macOS 明确仅个人非商业**；Windows/Android/iOS 需确认 | 取决于模型；Kokoro/Matcha/Melo 较干净 |
| 沙雕适配 | 机械感本身是笑点 | 需要选夸张音色 + 调 rate/pitch |

**建议**：

- **草稿/预览**用 OS 音色（零体积、即时），但 UI 必须标注「个人非商业」。
- **导出/发布**默认切到随包 neural 音色；如果用户坚持用 OS 音色，给出明确许可提示，不默认选中。
- 随包模型按语言拆：中文 73MB（Matcha zh-baker）或 30MB（aishell3，音质一般）；英文 61MB（Piper medium）；高质量可选 Kokoro int8（约 100MB 级）。

---

## 3. 时间对齐

### 3.1 原生时间戳能力

| 平台/引擎 | 能力 | 粒度 | 可靠性 |
|---|---|---|---|
| Windows SAPI | `BookmarkReached` + `AudioPosition` | 句/词（你自己插 bookmark） | 高，官方 API |
| Android TTS | `onRangeStart(start, end, frame)` | 字符区间 + 帧偏移 | 中高，取决于引擎 |
| iOS AVSpeech | `willSpeakRangeOfSpeechString`（仅实时） | 字符区间 | 文件合成不可用 |
| macOS `say` | 无 | — | 只能句级拆分 |
| espeak-ng | `--pho` 音素时长 | 音素 | 高（MBROLA 格式） |
| Piper / Kokoro / VITS | 无标准时间戳 | — | 需拆分或对齐 |
| sherpa-onnx | 自带 forced alignment | 词级 | 高，跨平台 |

### 3.2 没有时间戳时：句级真实 + 字级估算

**推荐流水线（TTS-first）**：

1. **拆句**：按 `。！？；…` 主切，按 `，、` 次切；每句独立合成。
2. **测真实时长**：每个 WAV 用 `afinfo` / `ffprobe` / WAV 头计算 `duration`；句间插入 80–150ms 静音。
3. **字级估算**：句内按「汉字 1 权重、数字 1.5、英文按音节」分配；标点额外加停顿。
4. **可选精修**：用能量 VAD 找句内静音边界，把估算边界吸附到最近的静音谷。
5. **回写 shot 时长**：`shot.duration = line.duration + gap`；镜头关键帧按音频时间生成。

**默认参数（工程经验，[推断]）**：

- 中文正常语速约 4.5–6 字/秒；沙雕夸张语速可到 7–8 字/秒。
- 停顿：逗号 120–180ms；句号/问号/感叹号 250–400ms；省略号 400–600ms。
- 句内字级误差通常在 ±80ms，肉眼口型完全够用。

**Fit-to-duration**：

- `say` 用 `-r`（词/分钟）；espeak-ng 用 `-s`；SAPI 用 SSML `<prosody rate>`；Android `setSpeechRate`；iOS `AVSpeechUtterance.rate`。
- Piper 用 `--length-scale`（>1 变慢、<1 变快）；VITS 系列本身有 `length_scale`。
- **[推断]** 优先「改语速重合成」而不是「后期时间伸缩」；后者会破坏音色且引入算法许可问题（Rubber Band 是 GPL/商业双许可）。

### 3.3 强制对齐（需要词级精确时）

| 工具 | 许可 | 适用 | 成本 |
|---|---|---|---|
| **MFA** | MIT（[repo](https://github.com/MontrealCorpusTools/Montreal-Forced-Aligner)） | 桌面批处理；中英文模型齐全 | 需 conda/Kaldi，模型数百 MB，重 |
| **WhisperX** | BSD-2（[repo](https://github.com/m-bain/whisperX)） | 词级时间戳 + 说话人分离；CPU 可跑但慢 | Python/PyTorch，重 |
| **sherpa-onnx forced alignment** | Apache-2.0 | 运行时跨平台；与 TTS 同一套依赖 | 需要对齐模型；中文模型需确认 |
| aeneas | AGPL | 不推荐（AGPL 传染） | — |

**[推断]** 对沙雕短剧，强制对齐是「过度工程」：句级真实时长 + 字级估算已经足够；只有在做「逐字卡拉 OK 字幕」或「精确口型特写」时才值得上 MFA/WhisperX。

---

## 4. 口型与表情

### 4.1 Viseme 集合：6 个足够

| ID | 名称 | 典型音素 | 口型 |
|---|---|---|---|
| `X` | 闭口 | b / p / m | 双唇闭合 |
| `A` | 张口 | a / ai / an / ang | 下颌打开，舌位低 |
| `E` | 扁口 | e / ei / en / eng / i / in | 嘴角拉开，开口小 |
| `O` | 圆口 | o / ou / ong / u / ü | 嘴唇收圆前突 |
| `F` | 齿唇 | f / s / sh / z / c / zh / ch | 上齿轻触下唇或接近 |
| `L` | 舌尖 | d / t / n / l / r | 舌尖抵上齿龈，口半开 |

可选第 7/8 个：`G`（g/k/h，喉部张开，可并入 A）、`Q`（j/q/x，可并入 E/F）。

**依据**：

- Rhubarb Lip Sync 使用 Preston Blair 的 6 个基础口型 + 最多 3 个扩展口型，输出 JSON/XML，MIT 许可，且其 `phonetic` 识别器是语言无关的，可用于中文（[repo](https://github.com/DanielSWolf/rhubarb-lip-sync)、[README](https://github.com/DanielSWolf/rhubarb-lip-sync/blob/master/README.adoc)）。
- Microsoft 的 viseme 体系是 22 个（0–21），适合精细 3D，不适合 2D 沙雕（[文档](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/how-to-speech-synthesis-viseme)）。

### 4.2 从文本/拼音映射

- 中文用 `pinyin` Dart 包（MIT，[pub.dev](https://pub.dev/packages/pinyin)）把每个汉字转成带声调拼音；取声母 + 韵母首字母映射到上表。
- 英文可用简单字母/音素规则；或直接用 RMS 包络，不依赖音素。
- 多音字：`pinyin` 支持词组/成语词典，能覆盖大部分；剩余错误对口型影响很小。

**[推断]** 沙雕短剧的观众不会读唇；口型只要「开合节奏对、表情夸张」就成立。文本映射的精度损失可以接受。

### 4.3 从音频能量/频谱驱动

**推荐混合方案**：

- **时间**：用 TTS 的句级真实时长 + 字级估算，保证口型与声音同步。
- **开合**：预计算 30Hz RMS 包络，`open = smoothstep((rms - floor) / (peak - floor))`。
- **宽圆**：预计算谱质心，`wide = clamp((centroid - 1500) / 2500)`；`round = 1 - wide`。
- **音素重音**：在拼音映射的 plosive（b/p/d/t/g/k）位置插入一个 60–100ms 的闭口，制造「爆破感」。

**不要逐帧 FFT**：在合成时一次性算完，存进 timeline JSON；`render(t)` 只做插值。30Hz 足够，60Hz 是浪费。

### 4.4 沙雕风格建议

- **口型**：3 个状态（闭 / 半开 / 大张）+ 幅度就够；夸张时让下颌过冲（squash & stretch）。
- **表情**：真正决定「沙雕感」的是眼睛和眉毛，不是嘴。建议表情层：`neutral` / `happy` / `angry` / `shock` / `smug` / `cry`，由台词情绪字段或标点触发（`！`→shock/angry，`？`→confused，`…`→awkward）。
- **头部**：跟随重音轻微点头/摇头；比口型更能提升「在说话」的感觉。
- **字幕**：逐字弹出 + 抖动，和口型同源时间轴。

### 4.5 与 Phaser / WebView 的同步

**核心原则：音频时钟是唯一主时钟。**

```js
// 错误：rAF 累加时间（会漂移）
let t = 0;
function loop(dt) { t += dt; render(t); }

// 正确：每帧从 AudioContext 读时间
const ctx = new AudioContext();
let t0 = 0, offset = 0;
function loop() {
  const t = ctx.currentTime - t0 + offset; // 秒
  render(t);
  requestAnimationFrame(loop);
}
```

- `AudioContext.currentTime` 是调度时钟，精度高于 `setTimeout`（[MDN](https://developer.mozilla.org/en-US/docs/Web/API/BaseAudioContext/currentTime)）。
- `getOutputTimestamp()` 可把 context time 映射到 `performance.now()`，并配合 `outputLatency` 做显示补偿（[MDN](https://developer.mozilla.org/en-US/docs/Web/API/AudioContext/getOutputTimestamp)）。
- Phaser 3 的 `scene.time.now` 是 rAF 时钟，不要用它做口型；用 `scene.sound.context.currentTime` 或自己持有的 AudioContext。
- `render(t)` 保持纯函数：`visemeAt(t)` 是对预计算关键帧数组的二分查找，不读 `Date.now()`、不读 `Math.random()`。这与现有 `video-clip-contract.md` 的纯函数纪律一致（`/Volumes/data/dev/coding/deepcodeUI/deepStudio/NoNDesign/docs/video-clip-contract.md`）。
- 播放/暂停/拖动：`AudioBufferSourceNode` 不能重启，seek 时必须 `stop()` 旧节点、创建新节点，并从 `ctx.currentTime + 0.05` 调度，避免爆音。
- 自动播放：AudioContext 在用户手势前是 suspended；首次播放必须由点击/触摸触发 `ctx.resume()`（[Chrome autoplay policy](https://developer.chrome.com/blog/autoplay)）。现有 WKWebView 已放开 video 自动播放，但 AudioContext 仍受策略约束，建议加「点击开始」覆盖层。

---

## 5. 音效

### 5.1 程序化生成能覆盖的沙雕音效

| 音效 | 合成配方 | 是否够用 |
|---|---|---|
| `pop` | 正弦 400→900Hz，30ms 上升 + 80ms 指数衰减 + 5ms 噪声 click | 够 |
| `boing` | 正弦 220Hz，频率 320→110Hz / 350ms，12Hz LFO 调频，低通 | 够（弹簧/卡通跳跃） |
| `whoosh` | 白噪声 → 带通 300→3000Hz / 350ms，增益包络 | 够（转场/挥手） |
| `record scratch` | 噪声 + 带通 1.2kHz + playbackRate 快速上下扫 | 够（尴尬停顿） |
| `drum hit` | 正弦 120→45Hz / 120ms（kick）+ 10ms 噪声（snare 加带通 1.5kHz） | 够（重音/笑点） |
| `dizzy` | 正弦 + 颤音 + 声像左右摆 | 够 |
| `wrong answer` | 两个下行方波音符（经典 buzzer） | 够 |
| `sparkle` | 多个高频正弦随机相位 + 短衰减 | 够 |

**[推断]** 这些配方用 Web Audio 的 `OscillatorNode` / `AudioBufferSourceNode` / `BiquadFilterNode` / `GainNode` 即可实现（[Web Audio API](https://developer.mozilla.org/en-US/docs/Web/API/Web_Audio_API)），不需要任何采样文件，体积为零、可确定性复现（固定 seed 的噪声 buffer）。

**Web Audio 代码骨架**：

```js
function env(gain, t0, peak, attack, decay) {
  gain.gain.setValueAtTime(0, t0);
  gain.gain.linearRampToValueAtTime(peak, t0 + attack);
  gain.gain.exponentialRampToValueAtTime(0.0001, t0 + attack + decay);
}

function pop(ctx, dest, t0) {
  const o = ctx.createOscillator(), g = ctx.createGain();
  o.type = 'sine';
  o.frequency.setValueAtTime(400, t0);
  o.frequency.exponentialRampToValueAtTime(900, t0 + 0.03);
  env(g, t0, 0.8, 0.005, 0.08);
  o.connect(g).connect(dest);
  o.start(t0);
  o.stop(t0 + 0.12);
}

function boing(ctx, dest, t0) {
  const o = ctx.createOscillator(), g = ctx.createGain();
  const lfo = ctx.createOscillator(), lg = ctx.createGain();
  o.type = 'sine';
  o.frequency.setValueAtTime(320, t0);
  o.frequency.exponentialRampToValueAtTime(110, t0 + 0.35);
  lfo.frequency.value = 12;
  lg.gain.value = 60;
  lfo.connect(lg).connect(o.frequency);
  env(g, t0, 0.7, 0.01, 0.4);
  o.connect(g).connect(dest);
  lfo.start(t0); o.start(t0);
  o.stop(t0 + 0.5); lfo.stop(t0 + 0.5);
}
```

### 5.2 必须采样的音效

程序化合成不了（或合成成本远高于采样）的：

- 人声：笑声、喘气、惊呼、咳嗽、群众笑声/掌声。
- 拟人：脚步、衣服摩擦、纸张翻动、开门、玻璃碎。
- 环境：雨、风、街道、办公室底噪。
- 音乐性 sting：如果不想合成旋律，用 CC0 短采样。

### 5.3 音效库许可证

| 来源 | 许可 | 商用 | 署名 | 注意 |
|---|---|---|---|---|
| **Kenney** | CC0 | 是 | 不需要 | 游戏音效为主，质量稳定（[support](https://kenney.nl/support)） |
| **Freesound** | CC0 / CC-BY / CC-BY-NC | CC0/CC-BY 可商用 | CC-BY 必须署名 | 必须逐条过滤，不能整站当 CC0（[FAQ](https://freesound.org/help/faq)） |
| **ZapSplat** | Standard License | 是 | 免费账号必须署名；Gold 可免 | 不能把音效作为独立素材再分发（[license](https://www.zapsplat.com/license-type/standard-license)） |
| **Pixabay** | Content License | 是 | 不需要 | 不能作为独立素材再分发；音频质量参差 |
| **BBC Sound Effects** | RemArc | **否** | — | 仅个人/教育/研究；商业需单独授权（[licensing](https://sound-effects.bbcrewind.co.uk/licensing)） |
| **Sonniss GDC** | 自有 royalty-free | 是 | 通常不需要 | 包很大（GB 级），需读当届 EULA |

**[推断]** 对「离线可复现」，建议：

- 程序化音效：构建期生成 WAV（固定 seed），提交到仓库，运行时零依赖。
- 采样音效：只收 CC0 + 少量 CC-BY；在 `sfx/manifest.json` 记录 `id/file/license/source/author/sha256`；应用内「版权信息」页自动生成署名列表。
- 不要运行时下载，不要依赖 Freesound API。

### 5.4 离线可复现音效包

```
assets/sfx/
  manifest.json
  pop.wav
  boing.wav
  whoosh.wav
  scratch.wav
  kick.wav
  laugh_01.wav
```

`manifest.json`：

```json
{
  "version": 1,
  "items": [
    {
      "id": "pop",
      "file": "pop.wav",
      "license": "CC0",
      "source": "generated",
      "author": "internal",
      "sha256": "…",
      "duration": 0.12,
      "tags": ["ui", "comedic"]
    },
    {
      "id": "laugh_01",
      "file": "laugh_01.wav",
      "license": "CC-BY-4.0",
      "source": "https://freesound.org/s/123456/",
      "author": "…",
      "sha256": "…",
      "duration": 2.3,
      "tags": ["voice", "crowd"]
    }
  ]
}
```

构建脚本 `tools/gen_sfx.py`（或 Dart）用固定 seed 生成程序化音效；采样音效由人工放入并计算 sha256。运行时校验 sha256（可选），manifest 驱动 UI 与署名页。

---

## 6. 配乐联动

### 6.1 共享时钟的可行方案

| 方案 | 精度 | 复杂度 | 适用 |
|---|---|---|---|
| **单一音频宿主**：所有声音在视频页的同一个 AudioContext 播放；音乐页只发「选曲/播放/暂停/seek」指令 | 采样级 | 低 | **推荐** |
| 宿主做时钟代理：两个页面各自播放，Flutter 每 100ms 广播 `{epochMs, positionMs}`，页面用 `Date.now()` 估算偏移 | ±20–50ms | 中 | 预览级；音乐+语音会有梳状滤波 |
| `performance.timeOrigin` 对齐：两页同源，用 `performance.now()` + 启动时间映射 | ±1–5ms（同机） | 中 | 同源 iframe；不同 WebView 的 timeOrigin 不同，需校准 |
| `postMessage` 直接传 AudioContext 时间戳 | 取决于消息延迟 | 高 | 不推荐做采样级 |

**[推断]** 最稳的是「单一音频宿主」：视频页持有 AudioContext，音乐页把「音乐轨道 + 起播时间 + 增益」作为 timeline 的一部分发给视频页。这样根本不存在跨页面时钟问题。

### 6.2 实时同步 vs 离线混音

| 维度 | 实时同步 | 离线混音 |
|---|---|---|
| 精度 | 受调度/设备延迟影响 | 采样级、完全确定 |
| 等待 | 即时 | 渲染时间（通常 < 实时） |
| 适用 | 预览、交互调整 | 导出、终版 |
| 实现 | Web Audio 调度 + AudioContext 时钟 | OfflineAudioContext 或 Dart PCM 混音 |

**推荐**：

- 预览：实时，单一 AudioContext，所有轨道预解码为 `AudioBuffer`。
- 导出：离线。`OfflineAudioContext(2, 48000 * duration, 48000)` 按同一张 timeline 调度，`startRendering()` 生成 `AudioBuffer`，再写 WAV（[MDN](https://developer.mozilla.org/en-US/docs/Web/API/OfflineAudioContext)）。
- 如果不想在 WebView 里做离线渲染，Dart 侧 PCM 混音更简单：所有素材统一为 48kHz/16-bit WAV，按 timeline 求和、加增益、限幅，写 WAV。确定性好、可单测。

### 6.3 导出时的音轨合成

1. **素材统一**：TTS 输出 22.05/24kHz → 重采样到 48kHz；SFX 统一 48kHz；音乐 48kHz。
2. **混音**：语音总线 -3dB、音乐总线 -12~-18dB、SFX -6dB；语音区间对音乐做 -6~-10dB ducking（80ms attack / 200ms release）。
3. **限幅**：master limiter，true peak ≤ -1dBTP。
4. **响度**：桌面用 ffmpeg `loudnorm=I=-16:TP=-1.5:LRA=11`（[ffmpeg loudnorm](https://ffmpeg.org/ffmpeg-filters.html#loudnorm)）；移动端做简单峰值归一。
5. **封装**：
   - 桌面：`ffmpeg -i frames.mp4 -i mix.wav -c:v copy -c:a aac -b:a 192k -shortest out.mp4`。
   - iOS：`AVAssetWriter` + `AVAssetWriterInput`（AAC）。
   - Android：`MediaMuxer` + `MediaCodec`（AAC）。
   - **不要用 FFmpegKit**：2025-01-06 退役，2025-04-01 从 Maven Central 移除（[repo](https://github.com/ffmpegkit-maintained/ffmpeg-kit)）。

**[推断]** 当前 `video_service.dart` 已在桌面用系统 ffmpeg 编码 mp4，加一条 `-i mix.wav -c:a aac` 是最低成本的导出方案；移动端没有 ffmpeg，v1 可以只导出无声 mp4 + 独立 WAV，或后续补原生封装。

---

## 7. 最小可行架构

### 7.1 模块图

```
Flutter (Dart)
├─ VoiceService                    // 统一接口
│   ├─ MacSayAdapter               // Process.run say
│   ├─ WinSapiAdapter              // powershell System.Speech
│   ├─ LinuxEspeakAdapter          // Process.run espeak-ng
│   ├─ IosAvSpeechAdapter          // MethodChannel + AVSpeechSynthesizer.write
│   ├─ AndroidTtsAdapter           // MethodChannel + synthesizeToFile
│   └─ SherpaAdapter               // sherpa_onnx FFI（可选随包模型）
├─ VoiceCache                      // hash → wav + timings.json
├─ TimingService                   // native / sentence / estimate / align
├─ VisemeMapper                    // pinyin → visemes; RMS → open/wide
├─ SfxLibrary                      // manifest + WAV
├─ AudioTimeline                   // JSON（单一事实源）
└─ MixdownService                  // Dart PCM mix → WAV；桌面 ffmpeg mux
        │
        ▼ 注入 timeline JSON + ND.audio runtime
Clip HTML (engine.js + 短片 render(t))
        │
        ▼
WebView AudioContext（预览） / OfflineAudioContext（导出）
```

### 7.2 核心数据模型

```json
{
  "version": 1,
  "sampleRate": 48000,
  "duration": 12.4,
  "tracks": [
    {
      "id": "voice",
      "kind": "voice",
      "gain": 0.9,
      "clips": [
        {"asset": "voice/ab12cd.wav", "start": 0.40, "duration": 2.10}
      ]
    },
    {
      "id": "sfx",
      "kind": "sfx",
      "gain": 0.7,
      "clips": [
        {"asset": "sfx/boing.wav", "start": 2.50, "duration": 0.50}
      ]
    },
    {
      "id": "music",
      "kind": "music",
      "gain": 0.25,
      "duck": [[0.40, 2.50, -8], [3.00, 5.10, -8]]
    }
  ],
  "visemes": [
    {"t": 0.42, "v": "X", "w": 1.0},
    {"t": 0.52, "v": "A", "w": 0.8}
  ],
  "words": [
    {"t": 0.40, "d": 0.18, "s": 0, "e": 1}
  ],
  "meta": {
    "timing": "estimated",
    "engine": "sherpa-matcha-zh",
    "license": "MIT"
  }
}
```

### 7.3 流水线

1. **剧本 → 台词行**：`{speaker, text, emotion, targetDuration?}`。
2. **拆句 → 逐句 TTS**：写入缓存；记录每句真实时长。
3. **时间戳**：优先原生（Windows bookmark / Android onRangeStart）；否则句级真实 + 字级估算；可选 sherpa 对齐。
4. **镜头时长**：`shot.duration = line.duration + gap`；如目标时长固定，先用 `rate/length_scale` 重合成，再补静音。
5. **口型**：拼音映射 + RMS 包络 → viseme 关键帧。
6. **音效/音乐**：按时间轴放置；音乐区间与语音区间计算 ducking。
7. **组装 timeline JSON**：注入 HTML；`render(t)` 读 `visemeAt(t)`。
8. **预览**：WebView 单一 AudioContext 调度。
9. **导出**：Dart 混音或 OfflineAudioContext → WAV → mux。

### 7.4 缓存

```
<appSupport>/voice/<engine>/<voice>/<sha1(normalizedText|rate|pitch|engineVer)>.wav
<appSupport>/voice/<engine>/<voice>/<sha1>.json   // {durationMs, timings, sampleRate}
```

- 文本先归一化（去首尾空白、统一标点）。
- 缓存上限 500MB，LRU 淘汰。
- 引擎/模型版本变化 → 换目录，不误用旧音频。
- 同一句在多集复用，命中率很高。

### 7.5 降级与失败

| 失败 | 降级 |
|---|---|
| OS TTS 不可用 | 依次尝试：随包 sherpa → espeak-ng → 静音 + 字幕 |
| 音色不存在 | 用默认音色 + 提示 |
| 时间戳缺失 | `timing: "estimated"`，UI 标注 |
| 音频解码失败 | 视频静音播放，字幕保留 |
| 自动播放被拦 | 「点击开始」覆盖层，手势后 `ctx.resume()` |

---

## 8. 不要做清单

1. **不要云端 TTS / 云端音效搜索**——违反「离线优先、零外联」，也引入网络延迟与隐私问题。
2. **不要把 macOS `say` 的输出用于对外发布的商业视频**——违反 Apple SLA 的 System Voices 条款。
3. **不要随包 Coqui XTTS**——CPML 仅非商业，公司已停止运营。
4. **不要把 GPL 的 Piper/espeak-ng 直接静态链进闭源应用**——piper1-gpl 是 GPL-3.0，espeak-ng 是 GPL-3.0；要么独立进程 + 履行 GPL 义务，要么换 Apache/MIT 运行时（sherpa-onnx）。
5. **不要逐帧做 FFT / 音频分析**——合成时算一次 30Hz 包络，存 JSON。
6. **不要用 `<audio>` 元素播多个重叠音效**——延迟高、混音不可控；用 Web Audio `AudioBufferSourceNode`。
7. **不要用 rAF 累加时间做口型时钟**——会漂移；用 `AudioContext.currentTime`。
8. **不要逐字合成来拿时间戳**——破坏韵律，听起来像机器人报字；按句合成。
9. **不要用 FFmpegKit**——已退役，二进制已下架。
10. **不要用实时时间伸缩（Rubber Band 等）硬凑时长**——音色破坏 + GPL/商业许可问题；用引擎自带的 rate/length_scale。
11. **不要在 `render(t)` 里用 `Math.random()` / `Date.now()`**——破坏现有短片契约的纯函数性；用固定 seed 预生成。
12. **不要导出 MP3**——编码器许可与音质都不划算；用 WAV 中间态 + AAC/M4A 终态。
13. **不要把音乐和语音放在两个独立 AudioContext 里实时对齐**——设备延迟不同，会有可闻相位问题；单一音频宿主。
14. **不要依赖 Siri 音色**——`say` 不可见。
15. **不要在移动端假设 Google TTS 存在**——枚举引擎，准备随包 fallback。

---

## 9. 推荐方案 + 风险 + 备选

### 9.1 推荐方案（分三期）

**Phase 1：可用（2–3 周）**

- TTS 适配层：macOS `say` + Windows PowerShell SAPI + Linux espeak-ng + iOS/Android 平台通道。
- 句级真实时长 + 字级估算；6 viseme + RMS 包络；程序化 SFX；单一 AudioContext timeline。
- Dart PCM 混音导出 WAV；桌面 ffmpeg 封装。
- UI 明确标注 OS 音色「个人非商业」。

**Phase 2：可发布（3–4 周）**

- 接入 sherpa-onnx + 一个中文模型（Matcha zh-baker 73MB 或 Kokoro int8）。
- 缓存、失败降级、音色选择、角色音色预设（rate/pitch/音色）。
- 可选 forced alignment（sherpa）用于特写镜头。
- 移动端原生封装（AVAssetWriter / MediaMuxer）。

**Phase 3：增强**

- 音效包管理 + 署名页；音乐 ducking 自动化；导出响度标准化。
- 多语言模型分包/本地导入。
- 口型编辑器（手动修正关键帧）。

### 9.2 风险

| 风险 | 概率 | 影响 | 缓解 |
|---|---|---|---|
| Apple System Voices 许可 | 高 | 高（不能商用导出） | 默认随包模型；OS 音色仅预览并标注；法务复核 iOS SLA |
| GPL 污染（espeak-ng/Piper） | 中 | 高 | 依赖审计；独立进程；优先 Apache/MIT |
| Android TTS 引擎缺失/质量差 | 中 | 中 | 运行时探测 + 随包 fallback |
| 中文 neural 音质不达预期 | 中 | 中 | 先做 Matcha/Kokoro/Melo 三方 A/B；保留 OS 音色 |
| 应用体积 +100–200MB | 高 | 中 | 按语言分包；本地导入；int8 量化 |
| WebView 音频自动播放被拦 | 高 | 低 | 手势覆盖层；`ctx.resume()` |
| 移动端导出封装缺失 | 中 | 中 | v1 导出无声 mp4 + WAV sidecar；后续原生 |
| 跨页面同步漂移 | 低 | 高 | 单一音频宿主；导出离线混音 |
| 模型/音色许可不清 | 中 | 高 | manifest 记录 license/source；逐模型审计 |

### 9.3 备选方案

| 方案 | 适用 | 代价 |
|---|---|---|
| **A. 全 OS 音色** | 个人/内部使用、快速原型 | 不能商用；跨机器不一致 |
| **B. 全内置 neural（sherpa + Kokoro int8）** | 追求一致性与音质 | 体积 +100–200MB；低端机慢 |
| **C. 混合（推荐）** | 产品化 | 需要两套音色与许可提示 |
| **D. 人声录制/导入** | 最高音质、零 TTS 许可风险 | 需要录音 UX；不适合批量 |
| **E. 只做字幕 + 音效，不做配音** | 极简 MVP | 沙雕感靠字幕/音效，弱于配音 |

---

## 10. 来源清单

**平台与许可证**

- Apple macOS SLA（System Voices 条款）：https://www.apple.com/legal/sla/docs/macOS27.pdf
- `say` man page：https://ss64.com/mac/say.html
- Windows `SetOutputToWaveFile`：https://learn.microsoft.com/en-us/dotnet/api/system.speech.synthesis.speechsynthesizer.setoutputtowavefile
- Windows `BookmarkReached` / `AudioPosition`：https://learn.microsoft.com/en-us/dotnet/api/system.speech.synthesis.speechsynthesizer.bookmarkreached
- Windows Natural Voices 不进 SAPI：https://github.com/gexgd0419/NaturalVoiceSAPIAdapter
- espeak-ng（GPL-3.0）：https://github.com/espeak-ng/espeak-ng
- espeak-ng man page：https://github.com/espeak-ng/espeak-ng/blob/master/src/espeak-ng.1.ronn
- Android `UtteranceProgressListener`：https://developer.android.com/reference/android/speech/tts/UtteranceProgressListener
- iOS `AVSpeechSynthesizer.write`：https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer/write(_:tobuffercallback:)
- iOS 音色质量：https://developer.apple.com/documentation/avfaudio/avspeechsynthesisvoicequality/premium
- flutter_tts 能力矩阵：https://pub.dev/packages/flutter_tts

**TTS 模型**

- Piper（MIT，已归档）：https://github.com/rhasspy/piper
- Piper 新版（GPL-3.0）：https://github.com/OHF-Voice/piper1-gpl
- Piper 音色许可讨论：https://github.com/rhasspy/piper/discussions/271
- Piper VOICES：https://github.com/rhasspy/piper/blob/master/VOICES.md
- Kokoro（Apache-2.0）：https://github.com/hexgrad/kokoro
- Kokoro ONNX 体积：https://github.com/thewh1teagle/kokoro-onnx
- sherpa-onnx（Apache-2.0）：https://github.com/k2-fsa/sherpa-onnx
- sherpa-onnx Flutter：https://pub.dev/packages/sherpa_onnx
- sherpa RTF 表：https://k2-fsa.github.io/sherpa/onnx/tts/pretrained_models/rtf.html
- sherpa Kokoro 模型：https://k2-fsa.github.io/sherpa/onnx/tts/pretrained_models/kokoro.html
- Coqui TTS：https://github.com/coqui-ai/TTS
- XTTS CPML：https://huggingface.co/coqui/XTTS-v2/blob/main/LICENSE.txt
- MeloTTS（MIT）：https://github.com/myshell-ai/MeloTTS
- Matcha-TTS（MIT）：https://github.com/shivammehta25/Matcha-TTS
- VITS（MIT）：https://github.com/jaywalnut310/vits

**时间对齐 / 口型**

- WhisperX（BSD-2）：https://github.com/m-bain/whisperX
- MFA（MIT）：https://github.com/MontrealCorpusTools/Montreal-Forced-Aligner
- Rhubarb Lip Sync（MIT，含语言无关 phonetic 模式）：https://github.com/DanielSWolf/rhubarb-lip-sync
- Microsoft viseme 0–21：https://learn.microsoft.com/en-us/azure/ai-services/speech-service/how-to-speech-synthesis-viseme
- W3C SSML `<mark>`：https://www.w3.org/TR/speech-synthesis11
- 拼音 Dart 包：https://pub.dev/packages/pinyin

**Web Audio / 导出**

- `AudioContext.currentTime`：https://developer.mozilla.org/en-US/docs/Web/API/BaseAudioContext/currentTime
- `getOutputTimestamp()`：https://developer.mozilla.org/en-US/docs/Web/API/AudioContext/getOutputTimestamp
- `OfflineAudioContext`：https://developer.mozilla.org/en-US/docs/Web/API/OfflineAudioContext
- Chrome autoplay policy：https://developer.chrome.com/blog/autoplay
- FFmpegKit 退役：https://github.com/ffmpegkit-maintained/ffmpeg-kit
- ffmpeg loudnorm：https://ffmpeg.org/ffmpeg-filters.html#loudnorm

**音效库**

- Kenney CC0：https://kenney.nl/support
- Freesound FAQ：https://freesound.org/help/faq
- ZapSplat Standard License：https://www.zapsplat.com/license-type/standard-license
- BBC Sound Effects（RemArc，非商用）：https://sound-effects.bbcrewind.co.uk/licensing

---

## 附：与本仓库相关的现有锚点

- 视频播放面：`/Volumes/data/dev/coding/deepcodeUI/deepStudio/NoNDesign/app/lib/widgets/video_player_surface.dart`
- 视频服务（桌面 ffmpeg 编码）：`/Volumes/data/dev/coding/deepcodeUI/deepStudio/NoNDesign/app/lib/core/video_service.dart`
- 短片 HTML 装配：`/Volumes/data/dev/coding/deepcodeUI/deepStudio/NoNDesign/app/lib/core/video_clip.dart`
- 短片契约（`render(t)` 纯函数、桥消息）：`/Volumes/data/dev/coding/deepcodeUI/deepStudio/NoNDesign/docs/video-clip-contract.md`
- 动效播放面：`/Volumes/data/dev/coding/deepcodeUI/deepStudio/NoNDesign/app/lib/widgets/video_animation_surface.dart`

---

### 最后一句判断

对这个产品，**「音质」不是第一约束，「许可证 + 跨端一致性 + 导出可发布」才是**。因此推荐把 OS 音色降级为草稿工具，把 sherpa-onnx + 许可证清晰的模型作为发布引擎，把口型和音效做成「预计算时间轴 + 单一 AudioContext」的确定性系统；这样既能做出沙雕感，又不会在导出环节踩法律和同步的坑。
