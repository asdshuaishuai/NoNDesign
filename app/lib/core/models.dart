import 'dart:convert';

double _num(dynamic v, [double fallback = 0]) => (v is num) ? v.toDouble() : fallback;

class NodeStyle {
  final String fill;
  final String textColor;
  final String stroke;
  final double strokeWidth;
  final double radius;
  final double opacity;
  final double fontSize;
  final String weight;
  final String shadow;
  final bool visible;
  final String align;
  /// 入场动效档（engine-0.2 白名单仅 fade_in；空串/none 不参与）。
  final String motion;
  /// 绕节点中心旋转（度，引擎 svg transform 实证）。
  final double rotate;
  /// 高斯模糊半径（引擎 feGaussianBlur 语义）。
  final double blur;
  /// 描边线型：solid / dashed / dotted。
  final String dash;
  /// 行高倍数（引擎信封默认 1.5；<=0 时消费侧回落 1.5）。
  final double line;
  /// 字距（em 比例 ×fontSize，引擎 letter-spacing 语义）。
  final double tracking;
  /// 斜体：italic / normal。
  final String italic;

  const NodeStyle({
    this.fill = '#FFFFFF',
    this.textColor = '#111827',
    this.stroke = 'none',
    this.strokeWidth = 0,
    this.radius = 0,
    this.opacity = 1,
    this.fontSize = 14,
    this.weight = 'normal',
    this.shadow = 'none',
    this.visible = true,
    this.align = 'left',
    this.motion = 'none',
    this.rotate = 0,
    this.blur = 0,
    this.dash = 'solid',
    this.line = 1.5,
    this.tracking = 0,
    this.italic = 'normal',
  });

  factory NodeStyle.fromJson(dynamic raw) {
    final m = raw is Map ? raw : const {};
    return NodeStyle(
      fill: (m['fill'] ?? '#FFFFFF').toString(),
      textColor: (m['text_color'] ?? '#111827').toString(),
      stroke: (m['stroke'] ?? 'none').toString(),
      strokeWidth: _num(m['stroke_width']),
      radius: _num(m['radius']),
      opacity: _num(m['opacity'], 1),
      fontSize: _num(m['font_size'], 14),
      weight: (m['weight'] ?? 'normal').toString(),
      shadow: (m['shadow'] ?? 'none').toString(),
      visible: m['visible'] != false,
      align: (m['align'] ?? 'left').toString(),
      motion: (m['motion'] ?? 'none').toString(),
      rotate: _num(m['rotate']),
      blur: _num(m['blur']),
      dash: (m['dash'] ?? 'solid').toString(),
      line: _num(m['line'], 1.5),
      tracking: _num(m['tracking']),
      italic: (m['italic'] ?? 'normal').toString(),
    );
  }
}

class CanvasNode {
  final String id;
  final String parent;
  final String kind;
  final String component;
  final String name;
  final String text;
  final double x;
  final double y;
  final double w;
  final double h;
  final NodeStyle style;
  /// 尺寸模式：fixed / hug / fill（引擎 update 词表 width_mode/height_mode）。
  final String widthMode;
  final String heightMode;
  /// 容器布局：layout.dir none/vertical/horizontal + gap/padding/justify。
  final String layoutDir;
  final double layoutGap;
  final double layoutPadding;
  final String layoutJustify;

  const CanvasNode({
    required this.id,
    required this.parent,
    required this.kind,
    required this.component,
    required this.name,
    required this.text,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.style,
    this.widthMode = 'fixed',
    this.heightMode = 'fixed',
    this.layoutDir = 'none',
    this.layoutGap = 0,
    this.layoutPadding = 0,
    this.layoutJustify = 'start',
  });

  factory CanvasNode.fromJson(Map<String, dynamic> m) {
    final rect = m['rect'] is Map ? m['rect'] as Map : const {};
    final layout = m['layout'] is Map ? m['layout'] as Map : const {};
    return CanvasNode(
      id: (m['id'] ?? '').toString(),
      parent: (m['parent'] ?? 'root').toString(),
      kind: (m['kind'] ?? 'rect').toString(),
      component: (m['component'] ?? '').toString(),
      name: (m['name'] ?? '').toString(),
      text: (m['text'] ?? '').toString(),
      x: _num(rect['x']),
      y: _num(rect['y']),
      w: _num(rect['w']),
      h: _num(rect['h']),
      style: NodeStyle.fromJson(m['style']),
      widthMode: (m['width_mode'] ?? 'fixed').toString(),
      heightMode: (m['height_mode'] ?? 'fixed').toString(),
      layoutDir: (layout['dir'] ?? 'none').toString(),
      layoutGap: _num(layout['gap']),
      layoutPadding: _num(layout['padding']),
      layoutJustify: (layout['justify'] ?? 'start').toString(),
    );
  }
}

class Artboard {
  final String id;
  final String name;
  final double width;
  final double height;
  final List<CanvasNode> nodes;
  /// 板底色（hex；server 从引擎 svg 的全幅背景 rect 提取，空 = 白底）。
  final String background;
  /// 引擎自渲染 SVG（内容层唯一真源；空 = 旧信封，客户端回落节点绘制）。
  final String svg;

  const Artboard({
    required this.id,
    required this.name,
    required this.width,
    required this.height,
    required this.nodes,
    this.background = '',
    this.svg = '',
  });

  factory Artboard.fromJson(Map<String, dynamic> m) => Artboard(
        id: (m['id'] ?? '').toString(),
        name: (m['name'] ?? m['id'] ?? '').toString(),
        width: _num(m['width'], 390),
        height: _num(m['height'], 844),
        nodes: ((m['nodes'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => CanvasNode.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
        background: (m['background'] ?? '').toString(),
        svg: (m['svg'] ?? '').toString(),
      );
}

class Flow {
  final String from;
  final String to;
  final String trigger;
  final String transition;

  const Flow({required this.from, required this.to, required this.trigger, this.transition = 'push'});

  factory Flow.fromJson(Map<String, dynamic> m) => Flow(
        from: (m['from'] ?? '').toString(),
        to: (m['to'] ?? '').toString(),
        trigger: (m['trigger'] ?? '').toString(),
        transition: (m['transition'] ?? 'push').toString(),
      );

  String get nodeId => trigger.startsWith('tap:') ? trigger.substring(4) : trigger;
}

class RenderEnvelope {
  final bool ok;
  final String? error;
  final String entry;
  final int revision;
  final String mbt;
  final List<Artboard> artboards;
  final List<Flow> flows;

  const RenderEnvelope({
    required this.ok,
    this.error,
    this.entry = '',
    this.revision = 0,
    this.mbt = '',
    this.artboards = const [],
    this.flows = const [],
  });

  factory RenderEnvelope.empty() => const RenderEnvelope(ok: true);

  factory RenderEnvelope.fromJson(Map<String, dynamic> m) => RenderEnvelope(
        ok: m['ok'] != false,
        error: m['error']?.toString(),
        entry: (m['entry'] ?? '').toString(),
        revision: (m['revision'] is num) ? (m['revision'] as num).toInt() : 0,
        mbt: (m['mbt'] ?? '').toString(),
        artboards: ((m['artboards'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => Artboard.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
        flows: ((m['flows'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => Flow.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
      );

  Artboard? board(String? id) {
    if (artboards.isEmpty) return null;
    return artboards.firstWhere((b) => b.id == id, orElse: () => artboards.first);
  }
}

class DesignSpec {
  final Map<String, String> palette;
  final double h1;
  final double h2;
  final double body;
  final List<double> spacing;
  final double radiusSm;
  final double radiusMd;
  final double radiusLg;
  final List<String> rules;
  final String notes;

  const DesignSpec({
    required this.palette,
    required this.h1,
    required this.h2,
    required this.body,
    required this.spacing,
    required this.radiusSm,
    required this.radiusMd,
    required this.radiusLg,
    required this.rules,
    required this.notes,
  });

  static const defaults = DesignSpec(
    palette: {
      'primary': '#6E7BFF',
      'background': '#F7F8FA',
      'surface': '#FFFFFF',
      'text': '#14161A',
      'muted': '#6B7280',
      'danger': '#DC2626',
      'success': '#16A34A',
    },
    h1: 32,
    h2: 24,
    body: 14,
    spacing: [4, 8, 12, 16, 24, 32],
    radiusSm: 8,
    radiusMd: 12,
    radiusLg: 16,
    rules: ['正文对比度 ≥ 4.5', '8pt 间距节奏', '按钮圆角 8', '列表 3 行以上加分隔线'],
    notes: '',
  );

  factory DesignSpec.fromJson(dynamic raw) {
    if (raw is! Map) return defaults;
    final typo = raw['typography'] is Map ? raw['typography'] as Map : const {};
    final radius = raw['radius'] is Map ? raw['radius'] as Map : const {};
    final palette = <String, String>{...defaults.palette};
    if (raw['palette'] is Map) {
      (raw['palette'] as Map).forEach((k, v) => palette[k.toString()] = v.toString());
    }
    return DesignSpec(
      palette: palette,
      h1: _num(typo['h1'], defaults.h1),
      h2: _num(typo['h2'], defaults.h2),
      body: _num(typo['body'], defaults.body),
      spacing: ((raw['spacing'] as List?) ?? defaults.spacing)
          .whereType<num>()
          .map((e) => e.toDouble())
          .toList(),
      radiusSm: _num(radius['sm'], defaults.radiusSm),
      radiusMd: _num(radius['md'], defaults.radiusMd),
      radiusLg: _num(radius['lg'], defaults.radiusLg),
      rules: ((raw['rules'] as List?) ?? defaults.rules).map((e) => e.toString()).toList(),
      notes: (raw['notes'] ?? '').toString(),
    );
  }

  Map<String, dynamic> toJson() => {
        'v': 1,
        'palette': palette,
        'typography': {'h1': h1, 'h2': h2, 'body': body},
        'spacing': spacing,
        'radius': {'sm': radiusSm, 'md': radiusMd, 'lg': radiusLg},
        'rules': rules,
        'notes': notes,
      };
}

class Docs {
  String prd;
  String ui;
  DesignSpec design;

  Docs({this.prd = '', this.ui = '', DesignSpec? design}) : design = design ?? DesignSpec.defaults;

  factory Docs.fromJson(dynamic raw) {
    if (raw is! Map) return Docs();
    return Docs(
      prd: (raw['prd'] ?? '').toString(),
      ui: (raw['ui'] ?? '').toString(),
      design: DesignSpec.fromJson(raw['design']),
    );
  }

  Map<String, dynamic> toJson() => {'prd': prd, 'ui': ui, 'design': design.toJson()};

  bool get hasContent => prd.trim().isNotEmpty || ui.trim().isNotEmpty;
}

class ModelInfo {
  final String providerId;
  final String providerName;
  final String id;
  final String name;
  final String baseUrl;
  final String protocol;
  final int context;
  final bool toolCall;
  final bool reasoning;
  final List<dynamic> reasoningOptions;

  const ModelInfo({
    required this.providerId,
    required this.providerName,
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.protocol,
    required this.context,
    required this.toolCall,
    required this.reasoning,
    required this.reasoningOptions,
  });
}

class ModelRegistry {
  final Map<String, dynamic> providers;
  final String fetchedAt;

  const ModelRegistry({required this.providers, required this.fetchedAt});

  factory ModelRegistry.fromJson(Map<String, dynamic> m) => ModelRegistry(
        providers: Map<String, dynamic>.from((m['providers'] as Map?) ?? const {}),
        fetchedAt: (m['fetched_at'] ?? '').toString(),
      );

  List<String> get providerIds => providers.keys.toList();

  Map<String, dynamic>? provider(String id) =>
      providers[id] is Map ? Map<String, dynamic>.from(providers[id] as Map) : null;

  List<ModelInfo> flatten() {
    final list = <ModelInfo>[];
    providers.forEach((pid, raw) {
      if (raw is! Map) return;
      final p = Map<String, dynamic>.from(raw);
      final models = p['models'] is Map ? p['models'] as Map : const {};
      models.forEach((mid, m) {
        if (m is! Map) return;
        final mm = Map<String, dynamic>.from(m);
        final limit = mm['limit'] is Map ? mm['limit'] as Map : const {};
        list.add(ModelInfo(
          providerId: pid,
          providerName: (p['name'] ?? pid).toString(),
          id: mid.toString(),
          name: (mm['name'] ?? mid).toString(),
          baseUrl: (p['api'] ?? '').toString(),
          protocol: (p['protocol'] ?? 'openai').toString(),
          context: (limit['context'] is num) ? (limit['context'] as num).toInt() : 128000,
          toolCall: mm['tool_call'] == true,
          reasoning: mm['reasoning'] == true,
          reasoningOptions: (mm['reasoning_options'] as List?) ?? const [],
        ));
      });
    });
    return list;
  }

  ModelInfo? find(String providerId, String modelId) {
    final p = provider(providerId);
    if (p == null) return null;
    final models = p['models'] is Map ? p['models'] as Map : const {};
    final m = models[modelId];
    if (m is! Map) return null;
    final mm = Map<String, dynamic>.from(m);
    final limit = mm['limit'] is Map ? mm['limit'] as Map : const {};
    return ModelInfo(
      providerId: providerId,
      providerName: (p['name'] ?? providerId).toString(),
      id: modelId,
      name: (mm['name'] ?? modelId).toString(),
      baseUrl: (p['api'] ?? '').toString(),
      protocol: (p['protocol'] ?? 'openai').toString(),
      context: (limit['context'] is num) ? (limit['context'] as num).toInt() : 128000,
      toolCall: mm['tool_call'] == true,
      reasoning: mm['reasoning'] == true,
      reasoningOptions: (mm['reasoning_options'] as List?) ?? const [],
    );
  }
}

// ---------------------------------------------------------------------------
// 工作区模式（主页输入框选择的目标工作台）
// ---------------------------------------------------------------------------

/// 主页一句话输入的目标工作台：`auto` = 由 NaN 按任务自行决定。
///
/// 四个工作区互相独立（用户裁决 2026-11-18），但共用同一个 NaN：
/// 用户在主页选中某个工作区，就是「这次任务先落在那里」；选 auto 则交给
/// 智能体按任务状态与它调用的工具自己切（`store.followAgentWorkspace`）。
const String workspaceModeAuto = 'auto';
const String workspaceModeDesign = 'design';
const String workspaceModeThree = 'three';
const String workspaceModeVideo = 'video';
const String workspaceModeHotapp = 'hotapp';

const List<String> kWorkspaceModes = <String>[
  workspaceModeAuto,
  workspaceModeDesign,
  workspaceModeThree,
  workspaceModeVideo,
  workspaceModeHotapp,
];

/// 主页工作区选择器的用户可见标签（唯一出口，别处只读这里）。
String workspaceModeLabel(String mode) {
  switch (normalizeWorkspaceMode(mode)) {
    case workspaceModeDesign:
      return '设计';
    case workspaceModeThree:
      return '3D';
    case workspaceModeVideo:
      return '视频';
    case workspaceModeHotapp:
      return '热应用';
    default:
      return '自动';
  }
}

/// 归一：未知值一律回落 `auto`（旧存档没有这个键）。
String normalizeWorkspaceMode(String? raw) {
  final value = (raw ?? '').trim();
  return kWorkspaceModes.contains(value) ? value : workspaceModeAuto;
}

/// Agent 循环运行时（设置界面「运行方式」）：
/// - `local`（默认）：内置循环在本机执行，桌面与移动一致；Build 的
///   design_op 仍经设计校验（绝不绕过引擎门）。
/// - `server`：消息发给显式连接的桌面端执行（wire 值 `server` 保持稳定，
///   设置界面文案称「连接桌面」）。显式选择远程时绝不静默回落本地。
///
/// 旧存档里的 `dart`（历史内置循环取值）与任何未知值统一回落 `local`——
/// 迁移不抹掉用户显式选择的 `server`，也不把未知值静默当成远程。
const String agentRuntimeLocal = 'local';

/// 历史内置循环取值：与 [agentRuntimeLocal] 同义（旧存档/旧测试只读兼容）。
const String agentRuntimeDart = agentRuntimeLocal;

/// 「连接桌面」远程运行时（wire 值保持 `server`）。
const String agentRuntimeServer = 'server';

String defaultAgentRuntime() => agentRuntimeLocal;

/// 把任意存档值归一到两个合法运行时：显式 `server` 保留，其余一律 `local`。
String normalizeAgentRuntime(String? raw) =>
    raw == agentRuntimeServer ? agentRuntimeServer : agentRuntimeLocal;

/// 内置服务商端点兜底表（模型清单快照不可用时，设置页仍能显示端点）。
///
/// 与 `store.dart` 的私有回退表逐字一致：设置页与请求层看到同一组地址，
/// 避免「界面显示 A、请求发往 B」。端点在内置服务商下只读。
const Map<String, String> builtInBaseUrls = {
  'openai': 'https://api.openai.com/v1',
  'deepseek': 'https://api.deepseek.com',
  'zhipuai': 'https://open.bigmodel.cn/api/paas/v4',
  'moonshotai-cn': 'https://api.moonshot.cn/v1',
  'moonshotai': 'https://api.moonshot.ai/v1',
  'minimax-cn': 'https://api.minimax.cn/v1',
  'minimax': 'https://api.minimax.io/v1',
  'stepfun': 'https://api.stepfun.com/v1',
};

/// 服务商的内置端点（快照优先未命中时用这张表；未知服务商回落 openai）。
String builtInBaseUrlFor(String providerId) =>
    builtInBaseUrls[providerId] ?? builtInBaseUrls['openai'] ?? '';

class AppSettings {
  String providerId;
  String modelId;
  String baseUrl;
  String apiKey;
  String thinkingLevel;
  int maxSteps;
  String theme;
  /// 外部智能体（ACP）：null 或空 = NaN 内置管线；否则发给该 ACP agent。
  String? acpAgentId;
  /// 选中 agent 的显示名（选定时随 id 一起持久化，输入框 pill 用）。
  String? acpAgentName;
  /// 3D 工作台当前项目名（'' = 无）。工作台视图切换会 dispose 状态，
  /// 项目名持久化让「切走再回来」续接同一项目（跨会话亦然）。
  String threeProjectName;
  /// NaN 热应用工作台当前应用名（'' = 无）：工作台 dispose 后回来仍停在原应用。
  String hotappApp;
  /// 视频工作台：当前示例下标 + 在飞/最近的渲染 job（回来可接回轮询）。
  int videoSampleIdx;
  String videoJob;
  /// 3D 规范手编草稿（项目名 → JSON 文本）：未保存的编辑跨视图保留。
  Map<String, String> threeSpecDrafts;
  /// 「连接桌面」模式：桌面端地址（如 http://192.168.1.5:12345）。
  /// 非空时运行方式可切换到桌面端执行（移动端不能在本机提供全部桌面能力）；
  /// 留空则只使用内置本机运行时。地址与连接码都由用户显式填写。
  String serverUrl;
  /// Agent 循环运行时（`local` | `server`）。缺省 [agentRuntimeLocal]；
  /// 旧存档的 `dart` 与未知值读入即回落 `local`，显式 `server` 保留。
  String _agentRuntime;
  String get agentRuntime => _agentRuntime;
  set agentRuntime(String value) => _agentRuntime = normalizeAgentRuntime(value);
  /// 聊天优先壳（手机四向、iPad 竖屏）的主面选择：true = 聊天流，
  /// false = 经典 Welcome。桌面/iPad 横屏的工作区壳不使用该值——设置面
  /// 只在聊天优先壳展示这一项，避免「开关打开却在桌面无效果」。
  bool chatStreamHome;
  /// 让手机/iPad 连接这台桌面电脑（本机连接宿主）。桌面独占，默认关。
  bool desktopHostEnabled;
  /// 连接宿主是否允许局域网访问（默认只监听 127.0.0.1）。
  bool desktopHostAllowLan;
  /// 主页一句话输入的目标工作台（见 `workspaceModeAuto` 一族）。
  /// 只决定「这次任务先落到哪个工作台」，不影响四个模块互相独立。
  String chatWorkspaceMode;

  AppSettings({
    this.providerId = 'deepseek',
    this.modelId = 'deepseek-v4.1-flash',
    this.baseUrl = '',
    this.apiKey = '',
    this.thinkingLevel = 'auto',
    this.maxSteps = 300,
    this.theme = 'dark',
    this.acpAgentId,
    this.acpAgentName,
    this.threeProjectName = '',
    this.hotappApp = '',
    this.videoSampleIdx = 0,
    this.videoJob = '',
    Map<String, String>? threeSpecDrafts,
    this.serverUrl = '',
    String? agentRuntime,
    this.chatStreamHome = true,
    this.desktopHostEnabled = false,
    this.desktopHostAllowLan = false,
    String? chatWorkspaceMode,
  })  : threeSpecDrafts = threeSpecDrafts ?? {},
        chatWorkspaceMode = normalizeWorkspaceMode(chatWorkspaceMode),
        // 默认内置；旧存档的 `dart`/未知值归一 local，显式 `server` 保留。
        _agentRuntime = normalizeAgentRuntime(agentRuntime);

  Map<String, dynamic> toJson() => {
        'providerId': providerId,
        'modelId': modelId,
        'baseUrl': baseUrl,
        'apiKey': apiKey,
        'thinkingLevel': thinkingLevel,
        'maxSteps': maxSteps,
        'theme': theme,
        'acpAgentId': acpAgentId,
        'acpAgentName': acpAgentName,
        'threeProjectName': threeProjectName,
        'hotappApp': hotappApp,
        'videoSampleIdx': videoSampleIdx,
        'videoJob': videoJob,
        'threeSpecDrafts': threeSpecDrafts,
        'serverUrl': serverUrl,
        'agentRuntime': agentRuntime,
        'chatStreamHome': chatStreamHome,
        'desktopHostEnabled': desktopHostEnabled,
        'desktopHostAllowLan': desktopHostAllowLan,
        'chatWorkspaceMode': chatWorkspaceMode,
      };

  factory AppSettings.fromJson(Map<String, dynamic> m) => AppSettings(
        providerId: (m['providerId'] ?? 'deepseek').toString(),
        modelId: (m['modelId'] ?? 'deepseek-v4.1-flash').toString(),
        baseUrl: (m['baseUrl'] ?? '').toString(),
        apiKey: (m['apiKey'] ?? '').toString(),
        thinkingLevel: (m['thinkingLevel'] ?? 'auto').toString(),
        maxSteps: (m['maxSteps'] is num) ? (m['maxSteps'] as num).toInt() : 300,
        theme: (m['theme'] ?? 'dark').toString(),
        acpAgentId: m['acpAgentId']?.toString(),
        acpAgentName: m['acpAgentName']?.toString(),
        threeProjectName: (m['threeProjectName'] ?? '').toString(),
        hotappApp: (m['hotappApp'] ?? '').toString(),
        videoSampleIdx: (m['videoSampleIdx'] is num) ? (m['videoSampleIdx'] as num).toInt() : 0,
        videoJob: (m['videoJob'] ?? '').toString(),
        threeSpecDrafts: (m['threeSpecDrafts'] is Map)
            ? Map<String, String>.fromEntries(
                (m['threeSpecDrafts'] as Map).entries
                    .map((e) => MapEntry(e.key.toString(), e.value.toString())))
            : <String, String>{},
        serverUrl: (m['serverUrl'] ?? '').toString(),
        // 默认 local；旧存档的 `dart` / 未知值回落 local，显式 `server` 保留。
        agentRuntime: normalizeAgentRuntime(m['agentRuntime']?.toString()),
        // 旧存档无此键：默认开（用户决策 2026-11-17，聊天流是主面）。
        chatStreamHome: m['chatStreamHome'] is bool ? m['chatStreamHome'] as bool : true,
        desktopHostEnabled: m['desktopHostEnabled'] == true,
        desktopHostAllowLan: m['desktopHostAllowLan'] == true,
        // 旧存档无此键：默认自动（交给 NaN 判断）。
        chatWorkspaceMode: (m['chatWorkspaceMode'] ?? workspaceModeAuto).toString(),
      );
}

/// ACP 目录项（外部智能体探测结果）。
class AcpAgentInfo {
  final String id;
  final String name;
  final bool installed;
  final bool selectable;
  final String? executable;
  final bool grayed;
  final String note;
  final String probeState;
  const AcpAgentInfo({
    required this.id,
    required this.name,
    required this.installed,
    this.selectable = false,
    this.executable,
    required this.grayed,
    required this.note,
    this.probeState = 'unprobed',
  });

  factory AcpAgentInfo.fromJson(Map<String, dynamic> m) => AcpAgentInfo(
        id: (m['id'] ?? '').toString(),
        name: (m['name'] ?? '').toString(),
        installed: m['installed'] == true,
        selectable: m['selectable'] == true,
        executable: m['executable']?.toString(),
        grayed: m['grayed'] == true,
        note: (m['note'] ?? '').toString(),
        probeState: (m['probeState'] ?? 'unprobed').toString(),
      );
}

// ============================================================
// 聊天流消息模型（docs/plan-chat-stream-shell.md §2 S1）
// ============================================================

/// 卡片类型：用户消息 / 进度卡（步骤+工具调用）/ 助手正文 /
/// A2UI 交互卡（surface 消息序列）/ 产物卡（热应用/原型/视频/3D）。
const String chatKindUser = 'user';
const String chatKindProgress = 'progress';
const String chatKindAssistant = 'assistant';
const String chatKindA2ui = 'a2ui';
const String chatKindArtifact = 'artifact';

/// 产物种类（产物卡点开去哪）：原型→工作区；热应用/视频/3D→对应工作台。
const String artifactPrototype = 'prototype';
const String artifactHotapp = 'hotapp';
const String artifactVideo = 'video';
const String artifactThree = 'three';

/// 进度卡里的一个步骤（复用 TimelineEntry 工具行的分类经验：running/
/// ok/ms/明细），随聊天卡持久化。
class ChatStep {
  String label;
  bool running;
  bool ok;
  int? ms;
  String? detail;

  ChatStep({required this.label, this.running = false, this.ok = true, this.ms, this.detail});

  factory ChatStep.fromJson(dynamic raw) {
    final m = raw is Map ? raw : const {};
    return ChatStep(
      label: (m['label'] ?? '').toString(),
      running: m['running'] == true,
      ok: m['ok'] != false,
      ms: (m['ms'] is num) ? (m['ms'] as num).toInt() : null,
      detail: m['detail']?.toString(),
    );
  }

  Map<String, dynamic> toJson() => {
        'label': label,
        'running': running,
        'ok': ok,
        if (ms != null) 'ms': ms,
        if (detail != null && detail!.isNotEmpty) 'detail': detail,
      };
}

/// 聊天流的一条消息。进度卡的 steps/running/ok 与正文 text 可变（run 中
/// 被事件推进），其余字段出生即定；序列化形态供 chat.json 落盘。
class ChatMessage {
  final String kind;
  String text;
  final List<ChatStep> steps;
  bool running;
  bool ok;
  String? detail;
  /// A2UI 卡的 surface 消息序列（与 A2uiCard.messages 静态路径同形——
  /// 已解码的信封 map 列表，如 `{'version': '1.0', 'createSurface': {...}}`）。
  final List<Object?>? a2uiMessages;
  String? artifactKind;
  String? artifactName;
  final DateTime ts;

  ChatMessage({
    required this.kind,
    this.text = '',
    List<ChatStep>? steps,
    this.running = false,
    this.ok = true,
    this.detail,
    this.a2uiMessages,
    this.artifactKind,
    this.artifactName,
    DateTime? ts,
  })  : steps = steps ?? [],
        ts = ts ?? DateTime.now();

  factory ChatMessage.user(String text) => ChatMessage(kind: chatKindUser, text: text);

  factory ChatMessage.assistant(String text) => ChatMessage(kind: chatKindAssistant, text: text);

  factory ChatMessage.progress(String title) =>
      ChatMessage(kind: chatKindProgress, text: title, running: true);

  factory ChatMessage.a2ui(List<Object?> messages, {String? text}) =>
      ChatMessage(kind: chatKindA2ui, text: text ?? '', a2uiMessages: messages);

  /// 产物卡：标题进 artifactName，text 留给一句话描述。
  factory ChatMessage.artifact({required String kind, required String title, String? detail}) =>
      ChatMessage(
        kind: chatKindArtifact,
        text: detail ?? '',
        artifactKind: kind,
        artifactName: title,
      );

  factory ChatMessage.fromJson(dynamic raw) {
    final m = raw is Map ? raw : const {};
    return ChatMessage(
      kind: (m['kind'] ?? '').toString(),
      text: (m['text'] ?? '').toString(),
      steps: ((m['steps'] as List?) ?? const []).map(ChatStep.fromJson).toList(),
      running: m['running'] == true,
      ok: m['ok'] != false,
      detail: m['detail']?.toString(),
      a2uiMessages: (m['a2ui'] as List?)?.toList(),
      artifactKind: m['artifactKind']?.toString(),
      artifactName: m['artifactName']?.toString(),
      ts: DateTime.tryParse((m['ts'] ?? '').toString()) ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
        'kind': kind,
        'text': text,
        if (steps.isNotEmpty) 'steps': [for (final s in steps) s.toJson()],
        'running': running,
        'ok': ok,
        if (detail != null && detail!.isNotEmpty) 'detail': detail,
        if (a2uiMessages != null) 'a2ui': a2uiMessages,
        if (artifactKind != null) 'artifactKind': artifactKind,
        if (artifactName != null) 'artifactName': artifactName,
        'ts': ts.toIso8601String(),
      };
}

class TimelineEntry {
  final String kind; // user, phase, tool, note, assistant, finish
  final String text;
  final String? title;
  final String? tool;
  final Map<String, dynamic>? args;
  bool ok;
  int? ms;
  String? preview;
  String? error;
  /// 服务层给出的人话失败句（`tool_end.message`）；原始码只留在 [error]。
  String? message;
  bool running;
  final DateTime ts;

  TimelineEntry({
    required this.kind,
    this.text = '',
    this.title,
    this.tool,
    this.args,
    this.ok = true,
    this.ms,
    this.preview,
    this.error,
    this.message,
    this.running = false,
    DateTime? ts,
  }) : ts = ts ?? DateTime.now();

  static TimelineEntry user(String text) => TimelineEntry(kind: 'user', text: text);
  static TimelineEntry note(String title, [String? detail]) =>
      TimelineEntry(kind: 'note', title: title, text: detail ?? '');
  static TimelineEntry assistant(String text) => TimelineEntry(kind: 'assistant', text: text);
  static TimelineEntry finish(bool ok, String title, [String? detail]) =>
      TimelineEntry(kind: 'finish', ok: ok, title: title, text: detail ?? '');
}

Map<String, dynamic> deepCopy(Map<String, dynamic> m) =>
    jsonDecode(jsonEncode(m)) as Map<String, dynamic>;
