/// 3D 场景套件（kits）：预置「一句话场景」入口。
///
/// 灵感来自 three-live 的 Domain Kits 与其「一套可直接改的场景」思路：
/// 用户不该从空白 brief 开始，而是选一个已成立的场景骨架（构图/材质/灯光
/// 的心智模型都对），再让 NaN 逐层细化。这里只放**静态目录**（纯 Dart 常量，
/// 不联网、不下载资产）；真正的生成仍走 ThreeService 的规范先行 + 六层推进。
library;

/// 一个场景套件：名称、一句话目标、标签、以及一个可读的构图提示。
class ThreeKit {
  const ThreeKit({
    required this.id,
    required this.name,
    required this.brief,
    required this.tags,
    required this.hint,
  });

  final String id;
  final String name;

  /// 新建项目时的 brief（会交给规范阶段）。
  final String brief;

  /// 标签（产品 / 建筑 / 抽象 / 科学 / 空间）。
  final List<String> tags;

  /// 给用户看的一句构图提示（不做成 prompt，避免把模型带偏）。
  final String hint;
}

/// 六个套件覆盖三类常见需求：产品展示、空间/建筑、抽象/科学可视化。
const List<ThreeKit> threeKits = <ThreeKit>[
  ThreeKit(
    id: 'product_turntable',
    name: '产品转台',
    brief: '一个居中台座上的产品展示场景：产品为主体，环形灯带打轮廓，'
        '相机四分之三视角缓慢环绕，背景深色渐变，材质偏哑光金属。',
    tags: <String>['产品', '展示'],
    hint: '主体居中、四分之三视角、环形补光',
  ),
  ThreeKit(
    id: 'architecture_mass',
    name: '建筑体块',
    brief: '一组建筑体块的空间构成：三层错落的方盒体量，地面格栅，'
        '斜向日光投影，相机低角度仰看，整体冷灰材质。',
    tags: <String>['建筑', '构成'],
    hint: '体块错落、低角度、长投影',
  ),
  ThreeKit(
    id: 'planet_system',
    name: '行星系统',
    brief: '一颗带环行星与两颗卫星的科学场景：行星缓慢自转，环面倾斜，'
        '背景星空点缀，主光来自侧后方，整体深蓝紫。',
    tags: <String>['科学', '空间'],
    hint: '行星居中、环面倾斜、星空背景',
  ),
  ThreeKit(
    id: 'abstract_sculpture',
    name: '抽象雕塑',
    brief: '一组抽象几何雕塑：球体、环面与棱柱交叠组合，金属与玻璃材质对比，'
        '相机缓慢推进，聚光来自上方，背景近黑。',
    tags: <String>['抽象', '材质'],
    hint: '几何交叠、材质对比、顶部聚光',
  ),
  ThreeKit(
    id: 'floating_cards',
    name: '悬浮卡片',
    brief: '三张悬浮在空间中的半透明卡片式面板：微微错落倾斜，边缘发光，'
        '相机正对，背景深色，卡片表面有细腻反射。',
    tags: <String>['界面', '空间'],
    hint: '三卡错落、边缘发光、正对相机',
  ),
  ThreeKit(
    id: 'interior_room',
    name: '室内一角',
    brief: '一个室内角落场景：地面、两面墙、一扇开窗与一件家具，'
        '窗外柔光进入形成光斑，相机平视，材质偏暖木与织物。',
    tags: <String>['空间', '室内'],
    hint: '两墙一窗、平视、窗外柔光',
  ),
];
