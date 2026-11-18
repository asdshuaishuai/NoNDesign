# 演示视频插件（轨道 D）

把演示模式的完整走查录制成视频。两段式：

1. **帧采集（NaN 内置）**：play_view「录制」按钮（后续接入；当前
   可用 macOS 自带工具对窗口录屏）→ PNG 序列落 `frames-<ts>/`。
2. **合成**：ffmpeg 在场：
   ffmpeg -framerate 30 -i frames-%04d.png -c:v libx264 -pix_fmt yuv420p demo.mp4
   不在场时本目录 `make-video.sh` 会打印安装指引（brew install ffmpeg）。

设计参考（3DCodeVerse 式「执行→视觉→修复」）：帧采集也用于 RSI 视觉修复
的 rubric 评审输入——vision 模型选中时逐屏图评（后续增强）。
