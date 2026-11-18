/// 视频工作台的内置标杆示例（批次 08）。
///
/// 为什么是内嵌常量而不是 asset bundle：`pubspec.yaml` 的资产清单归批次 01
/// 所有，本批次不越界改它。示例文本同时以文件形式存放在
/// `app/assets/video/sample/`（与本文件逐字一致，由 `video_service_test.dart`
/// 的漂移用例与 `scripts/wf/video_golden_check.py` 双向对账）——文件是
/// 对外工具与人工核对的产物，常量是运行时唯一读取面。
///
/// 三个示例覆盖两条规范线：science（物理/生物）与 screenplay（艺术）。
library;

/// 一个内置示例的完整定义。
class VideoSampleInfo {
  const VideoSampleInfo({
    required this.id,
    required this.label,
    required this.note,
    required this.timelineJson,
    required this.specJson,
    required this.specName,
  });

  /// 目录名（与 `assets/video/sample/<id>/` 对应）。
  final String id;

  /// 列表里显示的名字。
  final String label;

  /// 一行说明（列表副标题）。
  final String note;

  /// 时间线脚本原文。
  final String timelineJson;

  /// 规范原文。
  final String specJson;

  /// 规范文件名（时间线 `spec` 字段指向它）。
  final String specName;
}

/// 三个示例，顺序即工作台里的顺序。
const List<VideoSampleInfo> videoSamples = <VideoSampleInfo>[
  VideoSampleInfo(
    id: 'physics-friction',
    label: '物理 · 斜面摩擦力',
    note: '斜面上的匀加速下滑：受力三箭头 + 实时读数',
    timelineJson: r'''
{
  "fps": 30,
  "width": 1280,
  "height": 720,
  "background": "#0E1220",
  "spec": "spec.json",
  "scenes": [
    {
      "duration": 3.5,
      "background": "#0E1220",
      "elements": [
        { "type": "text", "text": "斜面上的滑动摩擦力", "x": "50%", "y": 64,
          "size": 40, "color": "#FFFFFF", "weight": "700",
          "anim": { "in": "fade", "dur": 0.5 } },
        { "type": "text", "text": "θ = 30°   μ = 0.12   刚体·质点·无空气阻力", "x": "50%", "y": 106,
          "size": 20, "color": "#9AA3B2",
          "anim": { "in": "fade", "dur": 0.5, "delay": 0.4 } },
        { "type": "polyline", "points": [[240, 580], [840, 580], [840, 234], [240, 580]],
          "color": "#3A4358", "stroke_width": 4, "fill": "#161B2C",
          "anim": { "in": "fade", "dur": 0.5 } },
        { "type": "line", "x1": 160, "y1": 580, "x2": 1160, "y2": 580,
          "color": "#3A4358", "stroke_width": 4 },
        { "type": "text", "text": "30°", "x": 282, "y": 566, "size": 18, "color": "#7C8CFF",
          "anchor": "start", "anim": { "in": "fade", "dur": 0.4, "delay": 0.6 } },
        { "type": "rect", "x": { "expr": "810 - 600*u1" }, "y": { "expr": "216 + 346*u1" },
          "w": 60, "h": 36, "radius": 6, "color": "#FFB65C" },
        { "type": "arrow", "x1": { "expr": "840 - 600*u1" }, "y1": { "expr": "252 + 346*u1" },
          "x2": { "expr": "840 - 600*u1" }, "y2": { "expr": "344 + 346*u1" },
          "color": "#FF8A7A", "stroke_width": 3, "head": 13,
          "anim": { "in": "fade", "dur": 0.4, "delay": 1.0 } },
        { "type": "arrow", "x1": { "expr": "840 - 600*u1" }, "y1": { "expr": "234 + 346*u1" },
          "x2": { "expr": "795 - 600*u1" }, "y2": { "expr": "156 + 346*u1" },
          "color": "#6FA8FF", "stroke_width": 3, "head": 13,
          "anim": { "in": "fade", "dur": 0.4, "delay": 1.4 } },
        { "type": "arrow", "x1": { "expr": "840 - 600*u1" }, "y1": { "expr": "234 + 346*u1" },
          "x2": { "expr": "909 - 600*u1" }, "y2": { "expr": "194 + 346*u1" },
          "color": "#C792EA", "stroke_width": 3, "head": 13,
          "anim": { "in": "fade", "dur": 0.4, "delay": 1.8 } },
        { "type": "text", "text": "mg", "x": { "expr": "858 - 600*u1" }, "y": { "expr": "330 + 346*u1" },
          "size": 16, "color": "#FF8A7A", "anchor": "start",
          "anim": { "in": "fade", "dur": 0.4, "delay": 1.2 } },
        { "type": "text", "text": "N", "x": { "expr": "776 - 600*u1" }, "y": { "expr": "160 + 346*u1" },
          "size": 16, "color": "#6FA8FF", "anchor": "end",
          "anim": { "in": "fade", "dur": 0.4, "delay": 1.6 } },
        { "type": "text", "text": "f = μN", "x": { "expr": "915 - 600*u1" }, "y": { "expr": "186 + 346*u1" },
          "size": 16, "color": "#C792EA", "anchor": "start",
          "anim": { "in": "fade", "dur": 0.4, "delay": 2.0 } },
        { "type": "text", "text": "a = g(sinθ − μcosθ) ≈ 3.88 m/s²", "x": "50%", "y": 660,
          "size": 24, "color": "#FFB65C", "weight": "700",
          "anim": { "in": "rise", "dur": 0.5, "delay": 2.2 } }
      ]
    },
    {
      "duration": 4.5,
      "background": "#0E1220",
      "elements": [
        { "type": "polyline", "points": [[240, 580], [840, 580], [840, 234], [240, 580]],
          "color": "#3A4358", "stroke_width": 4, "fill": "#161B2C" },
        { "type": "line", "x1": 160, "y1": 580, "x2": 1160, "y2": 580,
          "color": "#3A4358", "stroke_width": 4 },
        { "type": "rect", "x": { "expr": "810 - 600*u2" }, "y": { "expr": "216 + 346*u2" },
          "w": 60, "h": 36, "radius": 6, "color": "#FFB65C" },
        { "type": "text", "textValue": { "expr": "v", "format": "v = {:.2f} m/s" },
          "x": 880, "y": 200, "size": 44, "color": "#FFB65C", "anchor": "middle", "weight": "700" },
        { "type": "text", "textValue": { "expr": "xm", "format": "x = {:.2f} m" },
          "x": 880, "y": 270, "size": 44, "color": "#6FA8FF", "anchor": "middle", "weight": "700" },
        { "type": "text", "text": "时间 T 从片头起算：位移按 0.5·a·T² 增长（二次），速度按 a·T 增长（线性）",
          "x": "50%", "y": 660, "size": 20, "color": "#9AA3B2",
          "anim": { "in": "rise", "dur": 0.5, "delay": 0.6 } }
      ]
    }
  ]
}
''',
    specJson: r'''
{
  "kind": "science",
  "subject": "斜面上的滑动摩擦力：为什么滑块匀加速下滑",
  "domain": "physics",
  "laws": [
    "滑动摩擦力 f = μN，N 为法向压力（斜面上 N = mg·cosθ）",
    "牛顿第二定律：沿斜面方向 ma = mg·sinθ − μmg·cosθ"
  ],
  "assumptions": [
    "滑块视为质点，忽略空气阻力",
    "斜面与滑块均为刚体，μ 全程为常数",
    "画面几何按 tan30°≈0.577 布置（底 600px、高 346px），像素舍入误差忽略"
  ],
  "params": {
    "g": 9.8,
    "theta_deg": 30,
    "mu": 0.12,
    "scale_px_per_m": 200
  },
  "formulas": [
    { "name": "theta", "expr": "radians(theta_deg)" },
    { "name": "a", "expr": "g * (sin(theta) - mu * cos(theta))" },
    { "name": "u1", "expr": "min(1, 0.5 * a * scale_px_per_m * t * t / 693)" },
    { "name": "u2", "expr": "min(1, 0.5 * a * scale_px_per_m * T * T / 693)" },
    { "name": "v", "expr": "a * T" },
    { "name": "xm", "expr": "0.5 * a * T * T" }
  ],
  "facts": [
    "a = 9.8·(sin30° − 0.12·cos30°) ≈ 3.88 m/s² > 0，滑块确实下滑",
    "斜边 693px 对应实际 3.47m；由 0.5·a·t²=3.47 解得 t≈1.34s 滑到底，之后静止",
    "速度读数 v = a·T 随时间线性增大，位移读数为时间的二次函数",
    "受力三箭头方向：重力竖直向下、法向垂直斜面向上、摩擦沿斜面向上（阻碍下滑）"
  ],
  "storyboard": [
    { "note": "斜面+滑块从顶部起动，重力/法向/摩擦三箭头跟随滑块", "duration": 3.5 },
    { "note": "滑到底后镜头保留斜面，叠加大号实时读数 v 与 x（用全局时间 T 保持物理连续）", "duration": 4.5 }
  ]
}
''',
    specName: 'spec.json',
  ),
  VideoSampleInfo(
    id: 'bio-mitosis',
    label: '生物 · 细胞有丝分裂',
    note: '五个阶段各一幕：间期到末期的几何示意',
    timelineJson: r'''
{
  "fps": 30,
  "width": 1280,
  "height": 720,
  "background": "#10141F",
  "spec": "spec.json",
  "scenes": [
    {
      "duration": 2.0,
      "background": "#10141F",
      "elements": [
        { "type": "text", "text": "有丝分裂 · 间期", "x": "50%", "y": 80,
          "size": 36, "color": "#FFFFFF", "weight": "700", "anim": { "in": "fade", "dur": 0.5 } },
        { "type": "circle", "cx": "50%", "cy": "52%", "r": 170, "color": "#1B2338",
          "anim": { "in": "pop", "dur": 0.5 } },
        { "type": "circle", "cx": "50%", "cy": "52%", "r": 96, "color": "#25406B",
          "anim": { "in": "pop", "dur": 0.5, "delay": 0.2 } },
        { "type": "text", "text": "细胞核", "x": "50%", "y": 404, "size": 18, "color": "#8FB3FF",
          "anim": { "in": "fade", "dur": 0.4, "delay": 0.5 } },
        { "type": "text", "text": "DNA 复制：每条染色体形成两条姐妹染色单体", "x": "50%", "y": 640,
          "size": 24, "color": "#9AA3B2", "anim": { "in": "rise", "dur": 0.5, "delay": 0.8 } }
      ]
    },
    {
      "duration": 2.0,
      "background": "#10141F",
      "elements": [
        { "type": "text", "text": "前期", "x": "50%", "y": 80,
          "size": 36, "color": "#FFFFFF", "weight": "700", "anim": { "in": "fade", "dur": 0.4 } },
        { "type": "circle", "cx": "50%", "cy": "52%", "r": 170, "color": "#1B2338" },
        { "type": "circle", "cx": "50%", "cy": "52%", "r": 96, "color": "#25406B" },
        { "type": "line", "x1": 560, "y1": 330, "x2": 620, "y2": 352, "color": "#FFB65C", "stroke_width": 9,
          "anim": { "in": "pop", "dur": 0.4, "delay": 0.2 } },
        { "type": "line", "x1": 668, "y1": 330, "x2": 722, "y2": 306, "color": "#FFB65C", "stroke_width": 9,
          "anim": { "in": "pop", "dur": 0.4, "delay": 0.35 } },
        { "type": "line", "x1": 596, "y1": 402, "x2": 660, "y2": 416, "color": "#FFB65C", "stroke_width": 9,
          "anim": { "in": "pop", "dur": 0.4, "delay": 0.5 } },
        { "type": "text", "text": "染色质凝缩为染色体（X 形短棒示意）", "x": "50%", "y": 640,
          "size": 24, "color": "#9AA3B2", "anim": { "in": "rise", "dur": 0.5, "delay": 0.7 } }
      ]
    },
    {
      "duration": 2.0,
      "background": "#10141F",
      "elements": [
        { "type": "text", "text": "中期", "x": "50%", "y": 80,
          "size": 36, "color": "#FFFFFF", "weight": "700", "anim": { "in": "fade", "dur": 0.4 } },
        { "type": "circle", "cx": "50%", "cy": "52%", "r": 170, "color": "#1B2338" },
        { "type": "circle", "cx": "50%", "cy": "52%", "r": 96, "color": "#25406B" },
        { "type": "line", "x1": 480, "y1": 374, "x2": 800, "y2": 374, "color": "#3A4358",
          "stroke_width": 2, "anim": { "in": "fade", "dur": 0.3 } },
        { "type": "line", "x1": 540, "y1": 366, "x2": 572, "y2": 382, "color": "#FFB65C", "stroke_width": 9,
          "anim": { "in": "pop", "dur": 0.3, "delay": 0.2 } },
        { "type": "line", "x1": 620, "y1": 364, "x2": 652, "y2": 384, "color": "#FFB65C", "stroke_width": 9,
          "anim": { "in": "pop", "dur": 0.3, "delay": 0.35 } },
        { "type": "line", "x1": 700, "y1": 364, "x2": 732, "y2": 382, "color": "#FFB65C", "stroke_width": 9,
          "anim": { "in": "pop", "dur": 0.3, "delay": 0.5 } },
        { "type": "text", "text": "赤道板", "x": 812, "y": 380, "size": 15, "color": "#7C8CFF",
          "anchor": "start", "anim": { "in": "fade", "dur": 0.3, "delay": 0.6 } },
        { "type": "text", "text": "染色体排列在细胞中央赤道板", "x": "50%", "y": 640,
          "size": 24, "color": "#9AA3B2", "anim": { "in": "rise", "dur": 0.5, "delay": 0.7 } }
      ]
    },
    {
      "duration": 2.0,
      "background": "#10141F",
      "elements": [
        { "type": "text", "text": "后期", "x": "50%", "y": 80,
          "size": 36, "color": "#FFFFFF", "weight": "700", "anim": { "in": "fade", "dur": 0.4 } },
        { "type": "circle", "cx": "50%", "cy": "52%", "r": 170, "color": "#1B2338" },
        { "type": "circle", "cx": "50%", "cy": "52%", "r": 96, "color": "#25406B" },
        { "type": "line", "x1": 548, "y1": 360, "x2": 580, "y2": 388, "color": "#FFB65C", "stroke_width": 9 },
        { "type": "line", "x1": 700, "y1": 360, "x2": 732, "y2": 388, "color": "#FFB65C", "stroke_width": 9 },
        { "type": "arrow", "x1": 640, "y1": 374, "x2": 548, "y2": 374, "color": "#6FA8FF",
          "stroke_width": 3, "head": 13, "anim": { "in": "fade", "dur": 0.4, "delay": 0.3 } },
        { "type": "arrow", "x1": 640, "y1": 374, "x2": 732, "y2": 374, "color": "#6FA8FF",
          "stroke_width": 3, "head": 13, "anim": { "in": "fade", "dur": 0.4, "delay": 0.3 } },
        { "type": "text", "text": "着丝点分裂：姐妹染色单体分别移向两极", "x": "50%", "y": 640,
          "size": 24, "color": "#9AA3B2", "anim": { "in": "rise", "dur": 0.5, "delay": 0.7 } }
      ]
    },
    {
      "duration": 2.0,
      "background": "#10141F",
      "elements": [
        { "type": "text", "text": "末期", "x": "50%", "y": 80,
          "size": 36, "color": "#FFFFFF", "weight": "700", "anim": { "in": "fade", "dur": 0.4 } },
        { "type": "circle", "cx": "50%", "cy": "52%", "r": 190, "color": "#1B2338",
          "anim": { "in": "pop", "dur": 0.6 } },
        { "type": "circle", "cx": 560, "cy": 374, "r": 58, "color": "#25406B",
          "anim": { "in": "pop", "dur": 0.5, "delay": 0.3 } },
        { "type": "circle", "cx": 720, "cy": 374, "r": 58, "color": "#25406B",
          "anim": { "in": "pop", "dur": 0.5, "delay": 0.45 } },
        { "type": "line", "x1": 640, "y1": 230, "x2": 640, "y2": 500, "color": "#3A4358",
          "stroke_width": 3, "anim": { "in": "fade", "dur": 0.5, "delay": 0.8 } },
        { "type": "text", "text": "核膜重建 · 胞质分裂 → 两个子细胞", "x": "50%", "y": 640,
          "size": 24, "color": "#9AA3B2", "anim": { "in": "rise", "dur": 0.5, "delay": 1.0 } }
      ]
    }
  ]
}
''',
    specJson: r'''
{
  "kind": "science",
  "subject": "动物细胞有丝分裂的五个阶段",
  "domain": "biology",
  "laws": [
    "细胞周期：间期（DNA 复制）→ 前期（染色质凝缩、核膜解体）→ 中期（染色体赤道板排列）→ 后期（着丝点分裂、姐妹染色单体移两极）→ 末期（核膜重建、胞质分裂）"
  ],
  "assumptions": [
    "2D 几何示意：细胞以圆形近似，染色体以短棒简化",
    "只展示核内事件，不绘制纺锤体微管的完整结构",
    "阶段时长为示意节奏（真实 M 期约 1 小时量级），不表示真实时间比例"
  ],
  "params": {},
  "formulas": [],
  "facts": [
    "间期先行 DNA 复制，因此中期每条染色体含两条姐妹染色单体",
    "中期染色体排列在细胞中央的赤道板（画面中央横线）",
    "后期着丝点分裂，两组染色单体分别移向两极（画面左右）",
    "末期形成两个独立子核，最终胞质分裂为两个子细胞"
  ],
  "storyboard": [
    { "note": "间期：完整细胞核，标注 DNA 复制", "duration": 2 },
    { "note": "前期：染色体凝缩出现（短棒）", "duration": 2 },
    { "note": "中期：染色体沿中央赤道板排列", "duration": 2 },
    { "note": "后期：两组分向左右两极（箭头）", "duration": 2 },
    { "note": "末期：两个子核形成，胞质分裂完成", "duration": 2 }
  ]
}
''',
    specName: 'spec.json',
  ),
  VideoSampleInfo(
    id: 'art-sketch',
    label: '艺术 · 沙雕简笔小人',
    note: '火柴人滑入、起跳、压扁落地，挤压拉伸是灵魂',
    timelineJson: r'''
{
  "fps": 30,
  "width": 1280,
  "height": 720,
  "background": "#FAF6EE",
  "spec": "screenplay.json",
  "scenes": [
    {
      "duration": 5.0,
      "background": "#FAF6EE",
      "elements": [
        {
          "type": "line",
          "x1": 120,
          "y1": 600,
          "x2": 1160,
          "y2": 600,
          "color": "#111111",
          "stroke_width": 5
        },
        {
          "type": "ellipse",
          "cx": {
            "expr": "420 + 360 * min(1, t / 1.5)"
          },
          "cy": {
            "expr": "430 - 120 * hop"
          },
          "r": {
            "expr": "34 * (1 - 0.35 * (squash + squat))"
          },
          "color": "#111111",
          "rx": {
            "expr": "40.8 * (1 + 0.2 * (squash + squat))"
          },
          "ry": {
            "expr": "34 * (1 - 0.35 * (squash + squat))"
          }
        },
        {
          "type": "line",
          "x1": {
            "expr": "420 + 360 * min(1, t / 1.5)"
          },
          "y1": {
            "expr": "464 - 120 * hop"
          },
          "x2": {
            "expr": "420 + 360 * min(1, t / 1.5)"
          },
          "y2": {
            "expr": "544 - 90 * hop"
          },
          "color": "#111111",
          "stroke_width": 6
        },
        {
          "type": "line",
          "x1": {
            "expr": "420 + 360 * min(1, t / 1.5)"
          },
          "y1": {
            "expr": "490 - 105 * hop"
          },
          "x2": {
            "expr": "356 + 360 * min(1, t / 1.5)"
          },
          "y2": {
            "expr": "524 - 60 * hop"
          },
          "color": "#111111",
          "stroke_width": 5
        },
        {
          "type": "line",
          "x1": {
            "expr": "420 + 360 * min(1, t / 1.5)"
          },
          "y1": {
            "expr": "490 - 105 * hop"
          },
          "x2": {
            "expr": "484 + 360 * min(1, t / 1.5)"
          },
          "y2": {
            "expr": "524 - 60 * hop"
          },
          "color": "#111111",
          "stroke_width": 5
        },
        {
          "type": "line",
          "x1": {
            "expr": "420 + 360 * min(1, t / 1.5)"
          },
          "y1": {
            "expr": "544 - 90 * hop"
          },
          "x2": {
            "expr": "396 + 360 * min(1, t / 1.5)"
          },
          "y2": {
            "expr": "600 - 20 * hop"
          },
          "color": "#111111",
          "stroke_width": 5
        },
        {
          "type": "line",
          "x1": {
            "expr": "420 + 360 * min(1, t / 1.5)"
          },
          "y1": {
            "expr": "544 - 90 * hop"
          },
          "x2": {
            "expr": "444 + 360 * min(1, t / 1.5)"
          },
          "y2": {
            "expr": "600 - 20 * hop"
          },
          "color": "#111111",
          "stroke_width": 5
        },
        {
          "type": "polyline",
          "points": [
            [
              700,
              470
            ],
            [
              760,
              430
            ],
            [
              830,
              445
            ],
            [
              880,
              425
            ]
          ],
          "color": "#4ECDC4",
          "stroke_width": 4,
          "anim": {
            "in": "fade",
            "dur": 0.3,
            "delay": 3.6
          }
        },
        {
          "type": "text",
          "text": "再来一次！",
          "x": 900,
          "y": 420,
          "size": 26,
          "color": "#111111",
          "anchor": "middle",
          "weight": "700",
          "anim": {
            "in": "pop",
            "dur": 0.35,
            "delay": 3.8
          }
        },
        {
          "type": "text",
          "text": "沙雕简笔 · 挤压拉伸是灵魂",
          "x": "50%",
          "y": 668,
          "size": 20,
          "color": "#B8AD99",
          "anim": {
            "in": "fade",
            "dur": 0.5,
            "delay": 4.2
          }
        },
        {
          "type": "line",
          "x1": 720,
          "y1": 596,
          "x2": 676,
          "y2": 584,
          "color": "#B8AD99",
          "stroke_width": 3,
          "anim": {
            "in": "fade",
            "dur": 0.25,
            "delay": 2.95
          },
          "opacity": 0.7
        },
        {
          "type": "line",
          "x1": 812,
          "y1": 596,
          "x2": 856,
          "y2": 584,
          "color": "#B8AD99",
          "stroke_width": 3,
          "anim": {
            "in": "fade",
            "dur": 0.25,
            "delay": 2.95
          },
          "opacity": 0.7
        }
      ]
    }
  ]
}
''',
    specJson: r'''
{
  "kind": "screenplay",
  "title": "跳跳的小人",
  "style": "sand-sketch 沙雕简笔：火柴人（圆头+单线躯干+线四肢）、粗线条、夸张挤压拉伸（scale 0.7↔1.3）、高饱和点缀色（橙/青）少量出现",
  "palette": [
    "#111111",
    "#FFB65C",
    "#4ECDC4",
    "#FFFFFF"
  ],
  "characters": [
    {
      "id": "stick",
      "desc": "火柴人：圆头、单线躯干、两臂两腿各一条线；落地压扁、起跳拉长",
      "parts": [
        "head",
        "body",
        "arm_l",
        "arm_r",
        "leg_l",
        "leg_r"
      ]
    }
  ],
  "beats": [
    {
      "at": 0.0,
      "what": "小人从画面中部（420）向右滑入，站到中央偏右（780）"
    },
    {
      "at": 1.6,
      "what": "蓄力下蹲（整体压扁 0.7）"
    },
    {
      "at": 2.0,
      "what": "起跳（拉长 1.3 + 离地抛物线）"
    },
    {
      "at": 3.0,
      "what": "落地重压扁（0.65）+ 落点两侧对称扬起两条尘土短线"
    },
    {
      "at": 3.6,
      "what": "回弹站直，头顶弹出对白气泡『再来一次！』"
    }
  ],
  "gags": [
    "挤压拉伸必须夸张——普通缓动的跳跃不沙雕，环③按 style 对照",
    "落地瞬间必带压扁帧（头 r 压到 0.65 倍，高斯窗宽 ~0.25s）与对称尘土线",
    "对白气泡只允许一次，出现在结尾拍"
  ],
  "params": {},
  "formulas": [
    {
      "name": "hop",
      "expr": "max(0, sin(pi * min(1, max(0, (t - 2.0) / 1.0))))"
    },
    {
      "name": "squash",
      "expr": "exp(-16 * (t - 3.0) * (t - 3.0))"
    },
    {
      "name": "squat",
      "expr": "exp(-12 * (t - 1.7) * (t - 1.7))"
    }
  ]
}
''',
    specName: 'screenplay.json',
  ),
];
