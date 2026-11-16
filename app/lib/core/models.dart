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

class AppSettings {
  String providerId;
  String modelId;
  String baseUrl;
  String apiKey;
  String thinkingLevel;
  int maxSteps;
  String theme;
  /// 外部智能体（ACP）：null 或空 = NoN 内置管线；否则发给该 ACP agent。
  String? acpAgentId;
  /// 选中 agent 的显示名（选定时随 id 一起持久化，输入框 pill 用）。
  String? acpAgentName;
  /// 3D 工作台当前项目名（'' = 无）。工作台视图切换会 dispose 状态，
  /// 项目名持久化让「切走再回来」续接同一项目（跨会话亦然）。
  String threeProjectName;
  /// NoN 热应用工作台当前应用名（'' = 无）：工作台 dispose 后回来仍停在原应用。
  String hotappApp;
  /// 视频工作台：当前示例下标 + 在飞/最近的渲染 job（回来可接回轮询）。
  int videoSampleIdx;
  String videoJob;
  /// 3D 规范手编草稿（项目名 → JSON 文本）：未保存的编辑跨视图保留。
  Map<String, String> threeSpecDrafts;
  /// 「连接桌面」模式：桌面端服务器地址（如 http://192.168.1.5:8799）。
  /// 非空时 launch 优先连接它（移动端无法本地跑 Python 服务器）；
  /// 留空且本地 spawn 失败时回落 PLAN 直连（Dart AI SDK）。
  String serverUrl;

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
  }) : threeSpecDrafts = threeSpecDrafts ?? {};

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
      );
}

/// ACP 目录项（服务端 /acp/agents 探测结果）。
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
