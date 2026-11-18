/// 3D 场景质检（spatial lint）。
///
/// 参照 three-live 的空间 linter 与 threeui 示例里常见的「场景成立性」检查：
/// 不是评价好不好看，而是抓那些**一眼能判定、修起来有明确动作**的问题——
/// 没有相机/灯光、场景代码是骨架或空、六层里跳过的层、循环卡住、预算超标。
///
/// 纯函数、只读快照，不碰磁盘也不调模型：工作台与「检查」面板共用同一份
/// 报告，测试直接对 fixture 断言。
library;

import 'three_service.dart';

/// 严重级别：error 必须修（场景跑不起来/不合规），warn 建议修，
/// info 只是提示（不阻塞交付）。
enum ThreeLintLevel { error, warn, info }

/// 一条质检结论。
class ThreeLintIssue {
  const ThreeLintIssue({
    required this.level,
    required this.title,
    required this.detail,
    required this.fix,
  });

  final ThreeLintLevel level;
  final String title;
  final String detail;

  /// 人话修复动作（工作台里对应一次「继续生成本层」或补规范）。
  final String fix;
}

/// 一份质检报告。
class ThreeLintReport {
  const ThreeLintReport(this.issues);

  final List<ThreeLintIssue> issues;

  int get errors => issues.where((i) => i.level == ThreeLintLevel.error).length;
  int get warns => issues.where((i) => i.level == ThreeLintLevel.warn).length;
  bool get clean => issues.isEmpty;
}

/// 对一份 3D 项目快照做只读质检。
ThreeLintReport lintThreeProject(ThreeProjectSnapshot snapshot) {
  final issues = <ThreeLintIssue>[];
  final spec = snapshot.spec;
  final scene = snapshot.sceneJs.trim();
  final state = snapshot.state;

  // 1) 规范面：没有组件清单/验收标准，后面每一层都没有靶子。
  if (!_hasList(spec['components'])) {
    issues.add(const ThreeLintIssue(
      level: ThreeLintLevel.error,
      title: '规范缺少组件清单',
      detail: '场景没有列出要出现的组件，生成时容易只画一个占位块。',
      fix: '回到新建场景补一句「场景里有什么」，或让 NaN 重写规范。',
    ));
  }
  if (!_hasList(spec['acceptance'])) {
    issues.add(const ThreeLintIssue(
      level: ThreeLintLevel.error,
      title: '规范缺少验收标准',
      detail: '没有可判定的完成条件，六层推进无法判断「做完了」。',
      fix: '补齐验收标准（构图/材质/灯光各一条）。',
    ));
  }

  // 2) 场景代码：空或还是骨架，等于没有可看的东西。
  if (scene.isEmpty) {
    issues.add(const ThreeLintIssue(
      level: ThreeLintLevel.error,
      title: '还没有场景代码',
      detail: '预览里只有默认网格，没有主体。',
      fix: '从「占位」开始生成第一层。',
    ));
  } else {
    final lower = scene.toLowerCase();
    if (lower.contains('skeleton: true')) {
      issues.add(const ThreeLintIssue(
        level: ThreeLintLevel.error,
        title: '场景还是骨架',
        detail: '当前代码只放了网格辅助线，没有真实主体。',
        fix: '生成「结构」层，把主体几何立起来。',
      ));
    }
    if (!lower.contains('camera')) {
      issues.add(const ThreeLintIssue(
        level: ThreeLintLevel.warn,
        title: '没有找到相机设置',
        detail: '相机不明确时，换机器/换尺寸会得到不同构图。',
        fix: '在场景里显式设置相机位置与朝向。',
      ));
    }
    if (!lower.contains('light') && !lower.contains('hemisphere')) {
      issues.add(const ThreeLintIssue(
        level: ThreeLintLevel.warn,
        title: '场景没有灯光',
        detail: '只有环境光时材质看起来是平的，主体会糊成一片。',
        fix: '加一盏主光 + 一盏补光，给主体轮廓。',
      ));
    }
    if (!lower.contains('material')) {
      issues.add(const ThreeLintIssue(
        level: ThreeLintLevel.info,
        title: '材质还没定义',
        detail: '默认材质会让不同物体的质感无法区分。',
        fix: '在「材质」层补 PBR 参数（颜色/粗糙度/金属度）。',
      ));
    }
    final meshCount = 'mesh('.allMatches(lower).length + 'mesh<'.allMatches(lower).length;
    if (meshCount > 120) {
      issues.add(ThreeLintIssue(
        level: ThreeLintLevel.info,
        title: '物体数量偏多（$meshCount 个）',
        detail: '移动端/低配机器可能掉帧。',
        fix: '合并重复物体，或用 InstancedMesh。',
      ));
    }
  }

  // 3) 六层进度：跳过的层会在后面以「材质不对/构图不对」的形式返工。
  final passes = snapshot.passes;
  final pending = passes
      .where((p) => '${p['status']}' == 'pending')
      .map((p) => '${p['label'] ?? threePassLabel('${p['id']}')}');
  if (pending.isNotEmpty) {
    issues.add(ThreeLintIssue(
      level: ThreeLintLevel.warn,
      title: '还有 ${pending.length} 层没做',
      detail: '未完成：${pending.join(' / ')}。',
      fix: '继续生成当前层，逐层推进到「交互」。',
    ));
  }

  // 4) 卡住：循环超限后必须有人接手，不能静默停在半成品。
  if (state['blocked'] == true) {
    issues.add(ThreeLintIssue(
      level: ThreeLintLevel.error,
      title: '场景推进被卡住',
      detail: '${state['blocked_reason'] ?? '同一层反复失败，已停止自动重试。'}',
      fix: '看一次失败原因（技术详情），改 brief 或手动写这层。',
    ));
  }

  return ThreeLintReport(issues);
}

bool _hasList(Object? raw) => raw is List && raw.where((e) => '$e'.trim().isNotEmpty).isNotEmpty;
