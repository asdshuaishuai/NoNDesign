/// 统一创作 skill 的运行时蒸馏文本（代码内注入，不读磁盘 docs）。
///
/// 权威契约是 `docs/skills/creative-workbench/SKILL.md`；这里只保留模型每次
/// run 都必须看到的硬纪律（代码是真相 / plan 先过门 / 确定性 / 盲评分离 /
/// 定向修复 / 最佳轮交付 / 无外部运行时）。改契约时同步回填 SKILL.md。
library;

/// 设计/3D/视频/音乐共用的一段创作纪律。
const String creativeWorkbenchCore = '''
## CREATIVE WORKBENCH (code-first creative contract)
- 代码是事实源，产物是派生物：GLB/PNG/MP4/sprite sheet 都能从 src 重建；
  不要手改派生物当唯一副本。
- 先 spec 后 plan：plan 必须给精确数字（尺寸/帧/节拍）与 acceptance
  （binary、可观测）；plan 校验通过才写代码。缺关键输入先 ask_user，
  不要静默编造品牌/事实/资产。
- 确定性优先：固定帧率/整数帧、种子随机、禁止 wall-clock/Math.random 进状态；
  seek = 重置 + 重放。门（代码能回答的测量）先于视觉判断；门 ERROR 不能被
  「看起来不错」翻案。
- 生成者与评审者分离：不要给自己打分；judge 只看 brief + 图，返回六维
  （idea/composition/craft/motion/legibility/constraint_fit）+ improvement list；
  总分由 score 算，caps 最后应用。评分只在用户要求时跑，refine 按用户给的轮数。
- 修复要有数字：目标对象 + 测量偏差 + 方向/量；一次只改被点名的项；
  同一发现重复出现要换一种改法，不要重复同一编辑。
- 交付最佳轮（不是最后一轮）：≤10 行报告 kind/track · round · score · source ·
  evidence · open items；不列文件清单、不自我表扬。
- 零外部运行时、零网络：执行面只有 three-live / 应用 WebView / Dart/JS；
  外部脚本/几何工具（Blender/CadQuery/URDF/headless Chrome 等）只在开发期参考，不进产品。
''';

/// workspace run 的模块级纪律（在核心纪律后追加）。
String creativeSkillForWorkspace(String hint) {
  final target = hint.trim().isEmpty ? 'auto' : hint.trim();
  return '''
## WORKSPACE DISCIPLINE ($target)
- 只在本工作台的事实源上工作：项目 ↔ 工作台强绑定，不跨项目/跨模块写产物。
- 工具面已按本工作台收窄；看不到的工具就是这次不能做，如实在 finish 摘要里说。
- 交付前跑该模块的确定性检查（3D 几何/视频时长与事件/热应用离线门），
  检查失败先修复；不要用「完成了」代替证据。
''';
}
