import 'dart:async';
import 'keys.dart';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart' hide Flow;
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ai_sdk_dart/ai_sdk_dart.dart' show CancellationToken;

import 'api.dart';
import 'dart_agent.dart';
import 'models.dart';

final GlobalKey<ScaffoldMessengerState> rootMessengerKey = GlobalKey<ScaffoldMessengerState>();

/// 离线移动端的端点回退表（models.json 快照不可用时至少让默认服务商可用）。
const _builtInBaseUrls = <String, String>{
  'openai': 'https://api.openai.com/v1',
  'deepseek': 'https://api.deepseek.com',
  'zhipuai': 'https://open.bigmodel.cn/api/paas/v4',
  'moonshotai-cn': 'https://api.moonshot.cn/v1',
  'moonshotai': 'https://api.moonshot.ai/v1',
  'minimax-cn': 'https://api.minimax.cn/v1',
  'minimax': 'https://api.minimax.io/v1',
  'stepfun': 'https://api.stepfun.com/v1',
};

/// 解析内置 models.json 快照（server/models.json 的入库副本）为注册表。
/// 形状不对/为空返回 null——离线注册表是增强不是依赖，失败保持现 registry。
ModelRegistry? parseBundledModelsSnapshot(Object? decoded) {
  if (decoded is! Map) return null;
  final providers = decoded['providers'];
  if (providers is! Map || providers.isEmpty) return null;
  return ModelRegistry.fromJson(Map<String, dynamic>.from(decoded));
}

String _baseName(String path) {
  final name = path.split(RegExp(r'[\\/]')).last;
  return name.replaceAll(RegExp(r'\.ddp$', caseSensitive: false), '');
}

String _quote(Object? value) {
  if (value is bool) return value ? 'true' : 'false';
  if (value is num) return value.toString();
  final s = value?.toString() ?? '';
  if (s.isEmpty) return '""';
  if (!RegExp(r'[\s"=]').hasMatch(s) && !s.startsWith('@')) return s;
  return '"${s.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"';
}

enum OpenResult { opened, needPassword, cancelled, failed }

class AppStore extends ChangeNotifier {
  NoNDesignApi? api;
  ServerHandle? _server;
  bool ready = false;
  String? bootError;

  ModelRegistry registry = const ModelRegistry(providers: {}, fetchedAt: '');
  AppSettings settings = AppSettings();
  List<dynamic> templates = const [];
  List<dynamic> components = const [];

  // project
  bool hasProject = false;
  String projectName = 'untitled';
  String? projectPath;
  String password = '';
  bool dirty = false;
  int? lastSavedAt;
  String mbt = '';
  RenderEnvelope render = RenderEnvelope.empty();
  RenderEnvelope? previewRender;
  String? activeBoard;
  String? selectedNode;
  String? clipboardNodeId;
  List<String> selectedNodes = const [];
  String view = 'design';
  String docsTab = 'prd';
  String panel = 'project';
  String rightTab = 'agent';
  Docs docs = Docs();

  List<String> history = [];
  int historyIndex = -1;
  int fitEpoch = 0;

  // agent
  bool agentBusy = false;
  String agentPhase = 'idle';
  int? runId;
  List<TimelineEntry> timeline = [];
  String streamText = '';
  /// PLAN 阶段 write_doc 的流式正文缓冲（doc_delta 累积；doc_written 清空）。
  String liveDocText = '';
  String thinkingText = '';
  Map<String, dynamic> usage = const {};
  String? agentError;

  // chat stream 主面（docs/plan-chat-stream-shell.md §2 S1）
  /// 聊天流消息（用户/进度/A2UI/产物卡），随 chat.json 落盘。
  List<ChatMessage> chatMessages = [];
  /// 本轮 sendChat 的活动进度卡（对象引用——下标会被容量截断挪位）。
  ChatMessage? _chatCard;
  /// 本轮 run 由聊天流驱动：run 内不跳 view/rightTab（聊天流是主面，
  /// PLAN 不把用户拽去 docs 视图、BUILD 不拽去 design 视图）。
  bool chatActive = false;
  /// chat.json 串行写链（与 recovery.json 同一撕裂治理）。
  Future<void> _chatWriteQueue = Future.value();

  // recovery / recents
  Map<String, dynamic>? recovery;
  List<Map<String, dynamic>> recent = [];

  // server-discovered DDPs (workspace dir from /health + ~/Desktop).
  // Entries carry `source` ('workspace' | 'desktop') alongside path/name/bytes/modified.
  List<Map<String, dynamic>> serverProjects = [];
  String? workspaceDir;
  bool refreshingProjects = false;

  String _deltaBuffer = '';
  Timer? _deltaTimer;
  /// thinking_delta 的 80ms 合帧缓冲：SSE 思考分片可达几十 Hz，逐片
  /// notifyListeners 会让全树（画布+左右栏）跟着重建——与 assistant_delta
  /// 同一治理。
  String _thinkingBuffer = '';
  Timer? _thinkingTimer;
  /// doc_delta 同一 80ms 合帧治理（PLAN 文档正文逐片 notify 是全树放大器）。
  String _docBuffer = '';
  Timer? _docTimer;
  Timer? _previewTimer;
  String? _previewMbt;
  // ---- 中断恢复：运行进度落盘（2026-11-14）----
  /// 当前 run 的指令与起始时间；agentBusy 期间写入 recovery.json，
  /// 崩溃/意外退出后重启可识别「半程任务」并保留文档与画布进度。
  String? _runInstruction;
  String _runStartedAt = '';
  /// ACP 外部智能体会话句柄（与 projectPath+agentId 绑定）。
  String? _acpSessionId;
  String? _acpSessionAgent;
  String? _acpSessionProject;
  /// 最近一次成功渲染的 preview canonical（run 期间的实时画布进度）。
  String? _liveCanonical;
  Timer? _recoveryTimer;
  /// 内置 Dart 循环（core/dart_agent.dart）在飞请求的本地取消令牌——
  /// dart 运行时无论移动/桌面都无服务器取消端点可调，取消即本地中断。
  CancellationToken? _dartAgentCancel;
  /// 测试注入：Build 循环的模型覆盖（scripted mock），生产恒 null——
  /// runDartAgent 经 OpenAIProvider 直连。
  @visibleForTesting
  Object? debugAgentModelOverride;
  /// recovery.json 所在根目录（生产 ~/.nondesign；测试注入临时目录，
  /// 不污染真实用户 home）。
  @visibleForTesting
  String recoveryDir = '${Platform.environment['HOME']}/.nondesign';
  /// recovery 快照串行写链：run 起点/终态/doc_written/preview/周期 Timer
  /// 多处 unawaited 并发写同一文件——两个 writeAsString（各持 fd、O_TRUNC
  /// 从 0 写）交错可产生撕裂 JSON，下次启动 _loadRecovery 的 catch-all 会
  /// 静默吞掉解析失败，半程任务恢复快照无声丢失。所有写/删经此链接力，
  /// 后写覆盖先写。
  Future<void> _recoveryWriteQueue = Future.value();

  /// 在飞 op 串行队列：HTTP 往返窗口内第二个 op 若不等前一条 _commit，
  /// 会以陈旧 mbt 为基底提交并覆盖（丢改动——缩放松手两连发×方向键×
  /// inspector 编辑任意组合均可触发）。所有画布变更入口统一走
  /// applyOp 链式排队，链内每条读取 `mbt` 前必须等上一条提交完成；
  /// 失败不毒化链（_applyOpNow 内部吞异常返回 false）。
  /// 入口清单（缺一即重新打开交错窗口）：applyOp / autoFix / applySource /
  /// constrainLayout / _jumpHistory（⌘Z/⇧⌘Z/历史面板）/ engineHistory
  /// undo·redo / newProject / openProjectPath。
  Future<void> _opQueue = Future.value();

  /// 把一个变更任务排到 _opQueue 链尾：任务在链内执行（此刻前一条已
  /// _commit），读到的 mbt/history 才是新鲜的。异常不毒化链——任务自身
  /// 应吞异常返回失败（与 _applyOpNow 的约定一致），onError 只是二道防线。
  Future<T> _chainOp<T>(Future<T> Function() task) {
    final next = _opQueue.then((_) => task());
    _opQueue = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  /// 测试锚点：等 op 队列排空（undo() 等 void 入口拿不到返回 Future）。
  @visibleForTesting
  Future<void> get opQueueIdle => _opQueue;

  ModelInfo? get model {
    final found = registry.find(settings.providerId, settings.modelId);
    if (found != null) return found;
    final all = registry.flatten().where((m) => m.toolCall).toList();
    if (all.isEmpty) return null;
    return all.firstWhere(
      (m) => m.providerId == 'deepseek' && m.id.contains('v4.1'),
      orElse: () => all.firstWhere((m) => m.providerId == 'deepseek', orElse: () => all.first),
    );
  }

  Artboard? get board => render.board(activeBoard);

  CanvasNode? get node {
    final b = board;
    if (b == null || selectedNode == null) return null;
    for (final n in b.nodes) {
      if (n.id == selectedNode) return n;
    }
    return null;
  }

  List<Flow> get flows => render.flows;

  Future<void> boot() async {
    SharedPreferences? prefs;
    try {
      // 先读设置、再拉起服务器：manualBaseUrl（「连接桌面」）必须赶在
      // launch 之前生效——旧顺序先 launch 后读盘，设置里填的地址永远
      // 赶不上本次启动（移动端直接恒失败）。
      prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString('nondesign.settings');
      if (stored != null) {
        try {
          settings = AppSettings.fromJson(Map<String, dynamic>.from(jsonDecode(stored) as Map));
        } catch (_) {}
      }
      ServerLauncher.manualBaseUrl = settings.serverUrl;
      _server = await ServerLauncher.launch();
      api = NoNDesignApi(_server!.baseUrl);
      final modelsRaw = await api!.models();
      final snapshot = modelsRaw['snapshot'];
      if (snapshot is Map) {
        registry = ModelRegistry.fromJson(Map<String, dynamic>.from(snapshot));
      }
      final m = model;
      if (m == null) {
        final all = registry.flatten().where((x) => x.toolCall).toList();
        final preferred = all.firstWhere(
          (x) => x.providerId == 'deepseek' && x.id.contains('v4.1'),
          orElse: () => all.isEmpty ? throw StateError('no models in registry') : all.first,
        );
        settings.providerId = preferred.providerId;
        settings.modelId = preferred.id;
        settings.baseUrl = preferred.baseUrl;
      } else {
        if (settings.baseUrl.isEmpty) settings.baseUrl = m.baseUrl;
      }
      templates = await api!.templates();
      components = await api!.components();
      recent = _loadRecent(prefs);
      await _loadRecovery();
      await _loadChat();
      await refreshProjects();
      // Dev/e2e affordance: auto-open a project and/or jump to a view.
      // NONDESIGN_OPEN=/path/to.ddp  NONDESIGN_VIEW=design|docs|source|play
      final envOpen = Platform.environment['NONDESIGN_OPEN'];
      final envView = Platform.environment['NONDESIGN_VIEW'];
      if (envOpen != null && envOpen.isNotEmpty) {
        final res = await openProjectPath(envOpen);
        if (res == OpenResult.opened && envView != null && envView.isNotEmpty) {
          setView(envView);
        }
      } else if (envView != null && envView.isNotEmpty) {
        setView(envView);
      }
      ready = true;
      _recoveryTimer = Timer.periodic(const Duration(seconds: 20), (_) => _persistRecovery());
      notifyListeners();
    } catch (e) {
      // 移动端没有 server/main.py，也无法 spawn Python：launch 失败是
      // 正常形态（连接桌面 / PLAN 直连二选一），不能把用户钉死在错误
      // 死屏——降级为离线就绪，api 依赖的加载全部跳过。
      // 例外：配置过「连接桌面」地址却连不上（mobileDegradedBootError
      // 非空）必须显性报错——静默降级会让用户以为已连接，直到进 3D/
      // 热应用才撞上散点提示；bootError 屏自带重试/设置/离线继续三出路。
      if ((Platform.isIOS || Platform.isAndroid) && _server == null) {
        final visible = mobileDegradedBootError(e, settings.serverUrl);
        if (visible != null) {
          bootError = visible;
          ready = false;
          notifyListeners();
          return;
        }
        api = null;
        bootError = null;
        if (prefs != null) recent = _loadRecent(prefs);
        await ensureBundledRegistry();
        await _loadRecovery();
        await _loadChat();
        ready = true;
        _recoveryTimer ??= Timer.periodic(const Duration(seconds: 20), (_) => _persistRecovery());
        notifyListeners();
        return;
      }
      bootError = e.toString();
      ready = false;
      notifyListeners();
    }
  }

  /// 移动端 boot 降级分支的失败可见性裁决：配置过「连接桌面」地址却连不上
  /// → 返回错误文案（bootError 屏显性呈现）；未配置地址 → null（launch
  /// 失败是移动端正常离线形态，PLAN 直连可用，静默降级）。
  static String? mobileDegradedBootError(Object error, String serverUrl) {
    if (serverUrl.trim().isEmpty) return null;
    return error.toString();
  }

  /// 离线兜底注册表：app/assets/models.json 是 server/models.json 的入库
  /// 副本（scripts/sync_models.py 双写保持同步）。服务器 /models 拿不到时
  /// （移动端 PLAN 直连 / 离线继续），模型选择与 toolCall/protocol 门控
  /// 仍有数据源，不再恒空。幂等：registry 已有更权威的服务器快照时不覆盖。
  /// [load] 仅供测试注入（widget test 的 flutter/assets 通道无人应答，
  /// rootBundle 会挂死而非抛错）。
  Future<void> ensureBundledRegistry({Future<String> Function(String path)? load}) async {
    if (registry.providers.isNotEmpty) return;
    try {
      final raw = await (load ?? rootBundle.loadString)('assets/models.json');
      final parsed = parseBundledModelsSnapshot(jsonDecode(raw));
      if (parsed != null) registry = parsed;
    } catch (_) {
      // 资产缺失/损坏：保持空 registry，离线回退尽力而为。
    }
  }

  /// 启动失败后的「重试」：清掉半残实例再走一遍 boot（设置已落盘，
  /// 用户可在错误页先改服务器地址）。
  Future<void> retryBoot() async {
    _server?.dispose();
    _server = null;
    api = null;
    bootError = null;
    ready = false;
    notifyListeners();
    await boot();
  }

  /// 启动失败后的「离线继续」：桌面保留错误提示，这里只服务愿意在无
  /// 引擎条件下查看恢复文档的场景。
  Future<void> continueOffline() async {
    api = null;
    bootError = null;
    // 离线（含移动端 PLAN 直连）也需要模型清单数据源——服务器快照拿不到
    // 时回退内置副本，模型选择与能力门控不空转。
    await ensureBundledRegistry();
    ready = true;
    notifyListeners();
    await _loadRecovery();
    await _loadChat();
    _recoveryTimer ??= Timer.periodic(const Duration(seconds: 20), (_) => _persistRecovery());
    notifyListeners();
  }

  /// Discover DDPs the server can see: the workspace directory reported by
  /// /health plus a fixed ~/Desktop. Results are merged and deduped by path
  /// (workspace wins on collision) into [serverProjects]; discovery is
  /// best-effort — one directory failing must not hide the other.
  Future<void> refreshProjects() async {
    final client = api;
    if (client == null || refreshingProjects) return;
    refreshingProjects = true;
    notifyListeners();
    final desktop = '${Platform.environment['HOME']}/Desktop';
    try {
      if (workspaceDir == null || workspaceDir!.isEmpty) {
        final health = await client.health();
        if (health['ok'] == true) {
          final ws = health['workspace']?.toString();
          if (ws != null && ws.isNotEmpty) workspaceDir = ws;
        }
      }
      final sources = <(String, String)>[
        if (workspaceDir != null && workspaceDir!.isNotEmpty) ('workspace', workspaceDir!),
        ('desktop', desktop),
      ];
      final merged = <String, Map<String, dynamic>>{};
      for (final (source, dir) in sources) {
        try {
          final items = await client.listProjects(dir);
          for (final item in items.whereType<Map>()) {
            final entry = Map<String, dynamic>.from(item);
            final path = entry['path']?.toString() ?? '';
            if (path.isEmpty || merged.containsKey(path)) continue;
            entry['source'] = source;
            merged[path] = entry;
          }
        } catch (_) {}
      }
      final list = merged.values.toList()
        ..sort((a, b) {
          final am = a['modified'] is num ? a['modified'] as num : 0;
          final bm = b['modified'] is num ? b['modified'] as num : 0;
          return bm.compareTo(am);
        });
      serverProjects = list;
    } catch (_) {
      // keep the previous list on failure; refresh is cheap to retry
    }
    refreshingProjects = false;
    notifyListeners();
  }

  List<Map<String, dynamic>> _loadRecent(SharedPreferences prefs) {
    try {
      final raw = jsonDecode(prefs.getString('nondesign.recent') ?? '[]');
      if (raw is List) return raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    } catch (_) {}
    return [];
  }

  Future<void> _remember(String path, String name) async {
    recent = [
      {'path': path, 'name': name, 'ts': DateTime.now().millisecondsSinceEpoch},
      ...recent.where((r) => r['path'] != path),
    ].take(12).toList();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('nondesign.recent', jsonEncode(recent));
    notifyListeners();
  }

  Future<void> saveSettings() async {
    // 连接桌面地址与持久化同源：设置面板保存后立刻对下一次 launch 生效。
    ServerLauncher.manualBaseUrl = settings.serverUrl;
    final encoded = jsonEncode(settings.toJson());
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('nondesign.settings', encoded);
    // 镜像到 ~/.nondesign/settings.json：SharedPreferences 落在 macOS plist，
    // 测试探针/e2e 不便直读；镜像文件是服务端与工具链的读取口（含 apiKey，
    // 本机单用户，与 plist 同级安全模型）。
    try {
      final dir = '${Platform.environment['HOME']}/.nondesign';
      await Directory(dir).create(recursive: true);
      await File('$dir/settings.json').writeAsString(encoded);
    } catch (_) {}
    notifyListeners();
  }

  void setView(String value) {
    view = value;
    notifyListeners();
  }

  /// 3D 工作台当前项目名（'' = 无）：跨视图/跨会话续接同一项目
  /// （工作台视图切换即 dispose，内存态不保活）。
  void setThreeProjectName(String name) {
    settings.threeProjectName = name;
    saveSettings();
    notifyListeners();
  }

  /// NoN 热应用工作台当前应用名（'' = 无）：同 threeProjectName，切走后回来
  /// 仍停在原应用并自动重挂载。
  void setHotApp(String name) {
    settings.hotappApp = name;
    saveSettings();
    notifyListeners();
  }

  /// 视频工作台：示例下标 + 渲染 job（回来可重新接回轮询）。
  void setVideoState({int? sampleIdx, String? job}) {
    if (sampleIdx != null) settings.videoSampleIdx = sampleIdx;
    if (job != null) settings.videoJob = job;
    saveSettings();
    notifyListeners();
  }

  /// 3D 规范手编草稿（按项目名）：未保存的编辑跨视图保留。
  String? threeSpecDraft(String project) => settings.threeSpecDrafts[project];

  void setThreeSpecDraft(String project, String? draft) {
    if (project.isEmpty) return;
    if (draft == null || draft.isEmpty) {
      settings.threeSpecDrafts.remove(project);
    } else {
      settings.threeSpecDrafts[project] = draft;
    }
    saveSettings();
    notifyListeners();
  }

  /// 演示批注墨迹（板 id → 笔迹 → 归一化点），随项目文档持久——保存时
  /// 幂等注入 `<!-- nondesign:ink … -->` 尾块，打开时解析恢复（对齐原版
  /// inkPersist/inkRestore；引擎对未知 HTML 注释容忍，文末最稳）。
  Map<String, List<List<Offset>>> demoInks = {};

  /// 带墨迹块的文档（保存用）；无墨迹时剥旧块返回干净文档。
  String get mbtWithInk {
    final clean = mbt.replaceFirst(RegExp(r'<!--\s*nondesign:ink[\s\S]*?-->\s*'), '').trimRight();
    if (demoInks.isEmpty) return clean;
    final payload = jsonEncode(demoInks.map((k, v) => MapEntry(
        k,
        v.map((s) => s.map((o) => [
              double.parse(o.dx.toStringAsFixed(4)),
              double.parse(o.dy.toStringAsFixed(4)),
            ]).toList()).toList())));
    return '$clean\n\n<!-- nondesign:ink $payload -->';
  }

  /// 从文档恢复墨迹（只在打开项目时调用——运行中 op 不得清运行态批注）。
  void restoreInks(String documentMbt) {
    demoInks = {};
    final m = RegExp(r'<!--\s*nondesign:ink\s*([\s\S]*?)-->').firstMatch(documentMbt);
    if (m == null) return;
    try {
      final raw = (jsonDecode(m.group(1) ?? '') as Map).cast<String, dynamic>();
      demoInks = raw.map((k, v) => MapEntry(
          k,
          ((v as List).map((s) => ((s as List).map((pt) {
                final pair = pt as List;
                return Offset((pair[0] as num).toDouble(), (pair[1] as num).toDouble());
              }).toList())).toList())));
      notifyListeners();
    } catch (_) {}
  }

  void setDocsTab(String value) {
    docsTab = value;
    notifyListeners();
  }

  void setPanel(String value) {
    panel = value;
    if (value == 'docs' || value == 'spec') view = 'docs';
    notifyListeners();
  }

  void setRightTab(String value) {
    rightTab = value;
    notifyListeners();
  }

  void selectBoard(String id) {
    activeBoard = id;
    selectedNode = null;
    // 多选不跨板存活（与 _commit 的按活动板剪枝同语义）：跨板拖动会对
    // 旧板外来 id 发 move op，坐标被兜底套到错误节点上。
    selectedNodes = const [];
    if (view == 'docs' || view == 'play') view = 'design';
    notifyListeners();
  }

  void selectNode(String? id) {
    selectedNode = id;
    if (id != null) rightTab = 'inspect';
    notifyListeners();
  }

  /// Shift-click 多选：切换一个节点在多选集合中的存在。
  void toggleNodeSelection(String id) {
    if (selectedNodes.contains(id)) {
      selectedNodes = selectedNodes.where((x) => x != id).toList();
    } else {
      selectedNodes = [...selectedNodes, id];
    }
    if (selectedNodes.isNotEmpty) selectedNode = id;
    notifyListeners();
  }

  void clearNodeMultiSelection() {
    if (selectedNodes.isEmpty) return;
    selectedNodes = const [];
    notifyListeners();
  }

  void bumpFit() {
    fitEpoch += 1;
    notifyListeners();
  }

  void _toast(String title, [String? detail]) {
    final messenger = rootMessengerKey.currentState;
    if (messenger == null) return;
    // 姿态防线：toast 是短提示，不是输出面板——标题/详情去换行并截断，
    // 长结论留给时间线 finish 条目（done 分支曾把 120 字模型摘要塞进
    // 画布 SnackBar，黑块糊脸实证 2026-11-15）。
    final t = title.replaceAll(RegExp(r'\s+'), ' ').trim();
    final safeTitle = t.length > 40 ? '${t.substring(0, 40)}…' : t;
    String? safeDetail;
    if (detail != null && detail.trim().isNotEmpty) {
      final d = detail.replaceAll(RegExp(r'\s+'), ' ').trim();
      safeDetail = d.length > 90 ? '${d.substring(0, 90)}…' : d;
    }
    messenger.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        width: 360,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(safeTitle, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            if (safeDetail != null && safeDetail.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(safeDetail, style: const TextStyle(fontSize: 11, color: Colors.white70)),
              ),
          ],
        ),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  void _pushHistory(String prev) {
    if (prev == mbt && history.isNotEmpty) return;
    if (history.isEmpty) {
      history = [prev];
      historyIndex = 0;
    }
    var stack = history.sublist(0, historyIndex + 1);
    if (stack.isEmpty) stack = [prev];
    if (stack.last != prev) stack.add(prev);
    if (stack.last != mbt) stack.add(mbt);
    if (stack.length > 80) stack = stack.sublist(stack.length - 80);
    history = stack;
    historyIndex = stack.length - 1;
  }

  bool _commit(Map<String, dynamic> raw, {bool recordHistory = true, bool markDirty = true}) {
    final env = RenderEnvelope.fromJson(raw);
    if (!env.ok) {
      _toast('操作被引擎拒绝', env.error ?? 'unknown');
      return false;
    }
    final prev = mbt;
    final next = env.mbt.isNotEmpty ? env.mbt : prev;
    if (recordHistory && next != prev) {
      mbt = next;
      _pushHistory(prev);
    } else {
      mbt = next;
      if (history.isEmpty) {
        history = [next];
        historyIndex = 0;
      }
    }
    render = env;
    previewRender = null;
    if (env.artboards.isNotEmpty && !env.artboards.any((b) => b.id == activeBoard)) {
      activeBoard = env.entry.isNotEmpty ? env.entry : env.artboards.first.id;
    }
    final activeB = render.board(activeBoard);
    if (activeB != null) {
      if (selectedNode != null && !activeB.nodes.any((n) => n.id == selectedNode)) {
        selectedNode = null;
      }
      if (selectedNodes.isNotEmpty) {
        selectedNodes = selectedNodes.where((id) => activeB.nodes.any((n) => n.id == id)).toList();
      }
    } else {
      selectedNode = null;
      selectedNodes = const [];
    }
    if (markDirty) dirty = true;
    notifyListeners();
    return true;
  }

  Future<bool> newProject({
    String name = 'untitled',
    String device = 'mobile',
    String? templateId,
    bool empty = false,
  }) {
    if (api == null) return Future.value(false);
    // agentBusy 门（core-1）：run 在飞时切项目，在飞 run 的 done/failed
    // 事件随后会把旧项目的 canonical mbt 提交进新项目（静默覆盖新项目
    // 内容）；此前这里还硬置 agentBusy=false，把在飞 run 的状态位也拆了。
    if (agentBusy) {
      _toast('NoN 正在工作', '等这一轮结束再新建项目。');
      return Future.value(false);
    }
    // 同 op 队列串行：在飞 op 提交完才换项目，反向排队的 op 落在新项目
    // 上会被引擎按未知 id 拒绝（可恢复），不会静默覆盖。
    return _chainOp(() => _newProjectNow(
          name: name,
          device: device,
          templateId: templateId,
          empty: empty,
        ));
  }

  Future<bool> _newProjectNow({
    String name = 'untitled',
    String device = 'mobile',
    String? templateId,
    bool empty = false,
  }) async {
    final sizes = {'mobile': [390, 844], 'web': [1280, 800], 'desktop': [1440, 900]};
    final size = sizes[device] ?? sizes['mobile']!;
    _invalidateAcpSession(); // 新项目 → 新工作区 → ACP 会话重建
    try {
      if (empty) {
        hasProject = true;
        projectName = name.trim().isEmpty ? 'untitled' : name.trim();
        projectPath = null;
        password = '';
        dirty = true;
        lastSavedAt = null;
        mbt = '';
        render = RenderEnvelope.empty();
        previewRender = null;
        activeBoard = null;
        selectedNode = null;
        docs = Docs();
        history = [''];
        historyIndex = 0;
        // 聊天流驱动的建项目（sendChat 新 brief）不跳视图——聊天流是主面。
        if (!chatActive) view = 'design';
        panel = 'project';
        rightTab = 'agent';
        timeline = [];
        // 上一项目 run 的流式/思考残留不进新项目面板（孤立 stream 行 + thinking tile）。
        streamText = '';
        thinkingText = '';
        // 上一项目的演示墨迹不随 mbtWithInk（⌘S）持久进新项目——newProject
        // 是项目切换边界（非运行中 op），清运行态批注不违反 restoreInks 注释。
        demoInks = {};
        notifyListeners();
        return true;
      }
      final op = templateId != null ? 'template $templateId home' : 'create home ${size[0]} ${size[1]}';
      final res = await api!.apply('', op);
      // HTTP 往返期间有 run 启动（入口门之后的小竞态窗口）：此刻换项目
      // 会把 run 的终态 canonical 提交进新项目——放弃交换（服务端 apply
      // 对空 mbt 无需回滚）。
      if (agentBusy) {
        _toast('NoN 正在工作', '等这一轮结束再新建项目。');
        return false;
      }
      if (res['ok'] != true) {
        _toast('新建失败', res['error']?.toString());
        return false;
      }
      hasProject = true;
      projectName = name.trim().isEmpty ? 'untitled' : name.trim();
      projectPath = null;
      password = '';
      dirty = true;
      lastSavedAt = null;
      docs = Docs();
      activeBoard = (res['entry'] ?? 'home').toString();
      selectedNode = null;
      if (!chatActive) view = 'design'; // 同空分支：聊天流驱动不跳视图
      panel = 'project';
      rightTab = 'agent';
      timeline = [];
      // 上一项目 run 的流式/思考残留不进新项目面板（孤立 stream 行 + thinking tile）。
      streamText = '';
      thinkingText = '';
      // 同空分支：演示墨迹是项目态不是应用态，换项目即清。
      demoInks = {};
      history = [];
      _commit(res);
      _toast('项目已创建', '$projectName · ${size[0]}×${size[1]}');
      return true;
    } catch (e) {
      _toast('新建失败', e.toString());
      return false;
    }
  }

  Future<OpenResult> openProjectPath(String path, {String password = ''}) {
    if (api == null) return Future.value(OpenResult.failed);
    // agentBusy 门（core-1）：与 newProject 同根——run 在飞时切项目，
    // 在飞 run 的终态 canonical 会覆盖刚打开的项目。
    if (agentBusy) {
      _toast('NoN 正在工作', '等这一轮结束再打开项目。');
      return Future.value(OpenResult.failed);
    }
    // 同 op 队列串行：旧项目在飞 op 先提交，打开的整篇 _commit 后落。
    return _chainOp(() => _openProjectPathNow(path, password: password));
  }

  Future<OpenResult> _openProjectPathNow(String path, {String password = ''}) async {
    _invalidateAcpSession(); // 切项目 → ACP 会话重建
    try {
      var res = await api!.openProject(path, password: password);
      if (res['need_password'] == true) return OpenResult.needPassword;
      if (res['ok'] != true) {
        _toast('打开失败', res['error']?.toString());
        return OpenResult.failed;
      }
      final openedMbt = (res['mbt'] ?? '').toString();
      final rendered = await api!.render(openedMbt);
      if (rendered['ok'] != true) {
        _toast('项目无法渲染', rendered['error']?.toString());
        return OpenResult.failed;
      }
      // 两次 HTTP 往返期间有 run 启动：放弃交换（/project/open 只读解密，
      // 无服务端副作用可弃），避免在飞 run 的终态 canonical 覆盖新项目。
      if (agentBusy) {
        _toast('NoN 正在工作', '等这一轮结束再打开项目。');
        return OpenResult.failed;
      }
      hasProject = true;
      projectPath = (res['path'] ?? path).toString();
      projectName = _baseName(projectPath!);
      this.password = password;
      restoreInks(openedMbt);
      dirty = false;
      lastSavedAt = DateTime.now().millisecondsSinceEpoch;
      docs = Docs.fromJson(res['docs']);
      selectedNode = null;
      view = 'design';
      panel = 'project';
      rightTab = 'agent';
      // 上一项目 run 的流式/思考残留不进新项目面板（timeline 是否同清属
      // 「轨迹全局唯一时间线」语义拍板，本轮不动）。
      streamText = '';
      thinkingText = '';
      history = [];
      _commit(rendered, recordHistory: false, markDirty: false);
      dirty = false;
      await _remember(projectPath!, projectName);
      await _clearRecovery();
      _toast('项目已打开', projectName);
      return OpenResult.opened;
    } catch (e) {
      _toast('打开失败', e.toString());
      return OpenResult.failed;
    }
  }

  Future<OpenResult> pickAndOpenProject({String password = ''}) async {
    const group = XTypeGroup(label: 'NoNDesign 项目', extensions: ['ddp']);
    final file = await openFile(acceptedTypeGroups: const [group]);
    if (file == null) return OpenResult.cancelled;
    return openProjectPath(file.path, password: password);
  }

  Future<bool> saveProject({String? path}) async {
    if (api == null || !hasProject) return false;
    var target = path ?? projectPath;
    if (target == null) {
      final location = await getSaveLocation(
        suggestedName: '${projectName.isEmpty ? 'untitled' : projectName}.ddp',
        acceptedTypeGroups: const [XTypeGroup(label: 'NoNDesign 项目', extensions: ['ddp'])],
      );
      if (location == null) return false;
      target = location.path;
    }
    try {
      final res = await api!.saveProject(
        mbt: mbtWithInk,
        path: target,
        password: password,
        docs: docs.toJson(),
      );
      if (res['ok'] != true) {
        _toast('保存失败', res['error']?.toString());
        return false;
      }
      projectPath = (res['path'] ?? target).toString();
      projectName = _baseName(projectPath!);
      dirty = false;
      lastSavedAt = DateTime.now().millisecondsSinceEpoch;
      await _remember(projectPath!, projectName);
      await _clearRecovery();
      _toast('已保存', '$projectName · ${((res['bytes'] ?? 0) as num) ~/ 1024} KB');
      notifyListeners();
      return true;
    } catch (e) {
      _toast('保存失败', e.toString());
      return false;
    }
  }

  Future<bool> exportHtml() async {
    if (api == null) return false;
    try {
      final res = await api!.exportHtml(mbt);
      if (res['ok'] != true || res['html'] is! String) {
        _toast('导出失败', res['error']?.toString());
        return false;
      }
      final location = await getSaveLocation(
        suggestedName: '$projectName.html',
        acceptedTypeGroups: const [XTypeGroup(label: 'HTML', extensions: ['html'])],
      );
      if (location == null) return false;
      await File(location.path).writeAsString(res['html'] as String);
      _toast('已导出 HTML 原型', location.path);
      return true;
    } catch (e) {
      _toast('导出失败', e.toString());
      return false;
    }
  }

  /// 导出 Figma 包：服务器落盘 ~/Documents/NoNDesign/NoNDesign-figma-<ts>/，
  /// 不弹保存框；toast 携带目录。返回 true = 落盘成功。
  Future<bool> exportFigma() async {
    if (api == null) return false;
    try {
      final res = await api!.exportFigma(mbt);
      if (res['ok'] != true || res['dir'] is! String) {
        _toast('导出 Figma 包失败', res['error']?.toString());
        return false;
      }
      final boards = res['boards'];
      _toast('已导出 Figma 包（${boards is num ? boards : '?'} 板）', res['dir'] as String);
      return true;
    } catch (e) {
      _toast('导出 Figma 包失败', e.toString());
      return false;
    }
  }

  Future<bool> exportSvg() async {
    if (api == null || activeBoard == null) return false;
    try {
      final res = await api!.session(mbt, 'session_export_svg', activeBoard);
      final data = res['data'];
      if (data is! Map || data['svg'] is! String) {
        _toast('导出失败', res['error']?.toString());
        return false;
      }
      final location = await getSaveLocation(
        suggestedName: '$projectName-$activeBoard.svg',
        acceptedTypeGroups: const [XTypeGroup(label: 'SVG', extensions: ['svg'])],
      );
      if (location == null) return false;
      await File(location.path).writeAsString(data['svg'] as String);
      _toast('已导出 SVG', location.path);
      return true;
    } catch (e) {
      _toast('导出失败', e.toString());
      return false;
    }
  }

  /// 画布变更统一入口：op 串行入队（跨入口互斥），返回链尾结果。
  Future<bool> applyOp(String op, {bool silent = false}) =>
      _chainOp(() => _applyOpNow(op, silent: silent));

  /// Agent 变更 op 统一入口（core/dart_agent.dart Build 模式的写路径）：
  /// 复用 applyOp 的门与队列语义——同一条 _opQueue 链（跨入口互斥，链内
  /// 读 `mbt` 时前一条已 _commit）、同一个 _commit 采纳（history 推栈 /
  /// render 信封 / activeBoard 矫正 / dirty）。两处刻意不同：
  /// ① 门参数 gate:'agent'（引擎 AgentGate，比人类门严——双门语义，绝不
  /// 降级到 human 门）；② 无 applyOp 的 agentBusy 拒绝——这是 run 自己的
  /// 写路径（agentBusy 期间人类 op 仍被 _applyOpNow 拦住，两边不打架）。
  /// api 未连接返回 engine_unavailable 信封（循环侧同形消费）。
  Future<Map<String, dynamic>> applyAgentOp(String op) =>
      _chainOp(() => _applyAgentOpNow(op));

  Future<Map<String, dynamic>> _applyAgentOpNow(String op) async {
    if (api == null) return {'ok': false, 'error': 'engine_unavailable'};
    try {
      final res = await api!.apply(mbt, op, gate: 'agent');
      if (res['ok'] != true) return res;
      _commit(res);
      return res;
    } catch (e) {
      return {'ok': false, 'error': 'engine_gate_failed:$e'};
    }
  }

  Future<bool> _applyOpNow(String op, {bool silent = false}) async {
    if (api == null || agentBusy) {
      if (agentBusy) _toast('NoN 正在工作', '等这一轮结束再改画布。');
      return false;
    }
    try {
      final res = await api!.apply(mbt, op);
      if (res['ok'] != true) {
        if (!silent) _toast('操作被引擎拒绝', res['error']?.toString());
        return false;
      }
      return _commit(res);
    } catch (e) {
      if (!silent) _toast('引擎异常', e.toString());
      return false;
    }
  }

  Future<bool> createBoard({String? templateId, String? name, double? width, double? height}) async {
    final count = render.artboards.length + 1;
    final id = (name ?? templateId ?? 'screen_$count').replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
    final w = (width ?? (render.artboards.isNotEmpty ? render.artboards.first.width : 390)).round();
    final h = (height ?? (render.artboards.isNotEmpty ? render.artboards.first.height : 844)).round();
    final op = templateId != null ? 'template $templateId $id' : 'create $id $w $h';
    final ok = await applyOp(op);
    if (ok) {
      activeBoard = templateId ?? id;
      view = 'design';
      notifyListeners();
    }
    return ok;
  }

  Future<bool> deleteBoard(String id) async {
    if (render.artboards.length <= 1) {
      _toast('至少保留一个画板');
      return false;
    }
    return applyOp('delete-artboard $id');
  }

  Future<bool> duplicateBoard(String id) async {
    final newId = '${id}_copy_${DateTime.now().millisecondsSinceEpoch % 1000}';
    final ok = await applyOp('duplicate $id $newId');
    if (ok) {
      activeBoard = newId;
      notifyListeners();
    }
    return ok;
  }

  Future<bool> updateNode(String id, Map<String, dynamic> patch) async {
    if (activeBoard == null) return false;
    final parts = patch.entries
        .where((e) => e.value != null)
        .map((e) => '${e.key}=${_quote(e.value)}')
        .toList();
    if (parts.isEmpty) return false;
    return applyOp('update $activeBoard $id ${parts.join(' ')}');
  }

  Future<bool> moveNode(String id, double x, double y) async {
    if (activeBoard == null) return false;
    return applyOp('move $activeBoard $id ${x.round()} ${y.round()}');
  }

  Future<bool> resizeNode(String id, double w, double h) async {
    if (activeBoard == null) return false;
    return applyOp(
      'update $activeBoard $id width_mode=fixed height_mode=fixed w=${w.round().clamp(1, 10000)} h=${h.round().clamp(1, 10000)}',
    );
  }

  /// ⌘C：把选中节点记入画布剪贴板（引用节点 id，⌘V 时用引擎 copy 落新实例）。
  void copyNode(String id) {
    clipboardNodeId = id;
    _toast('已复制 $id', '${modCombo('⌘V')} 粘贴到画布');
  }

  /// ⌘V：把剪贴板节点复制一份（偏移 24,24），返回新节点 id（失败为 null）。
  Future<String?> pasteNode() async {
    if (clipboardNodeId == null || activeBoard == null) return null;
    final newId = '${clipboardNodeId}_p${DateTime.now().millisecondsSinceEpoch % 100000}';
    final ok = await applyOp('copy $activeBoard $clipboardNodeId $newId 24 24');
    return ok ? newId : null;
  }

  Future<bool> deleteNode(String id) async {
    if (activeBoard == null) return false;
    final ok = await applyOp('delete $activeBoard $id');
    if (ok) selectedNode = null;
    return ok;
  }

  Future<bool> duplicateNode(String id) async {
    if (activeBoard == null) return false;
    final newId = '${id}_copy_${DateTime.now().millisecondsSinceEpoch % 1000}';
    final ok = await applyOp('copy $activeBoard $id $newId 16 16');
    if (ok) selectedNode = newId;
    return ok;
  }

  Future<bool> reorderNode(String id, String mode) async {
    if (activeBoard == null) return false;
    return applyOp('reorder $activeBoard $id $mode');
  }

  /// Mirror a node horizontally/vertically. Engine axes: h | v | both | none.
  Future<bool> flipNode(String id, String axis) async {
    if (activeBoard == null) return false;
    const axes = {'h', 'v', 'both', 'none'};
    if (!axes.contains(axis)) return false;
    return applyOp('flip $activeBoard $id $axis');
  }

  /// Define a state patch on a node. Engine-accepted k=v keys:
  /// fill / text_color / stroke / text / radius / font_size.
  Future<bool> setNodeState(String id, String stateName, Map<String, dynamic> props) async {
    if (activeBoard == null) return false;
    final parts = props.entries
        .where((e) => e.value != null)
        .map((e) => '${e.key}=${_quote(e.value)}')
        .toList();
    if (parts.isEmpty) return false;
    return applyOp('state $activeBoard $id $stateName ${parts.join(' ')}');
  }

  /// Switch a node's current state with a toggle (persists a [cur:<name>]
  /// marker). The set-state op takes no artboard: `set-state <node> <state> toggle`.
  Future<bool> toggleNodeState(String id, String state) => applyOp('set-state $id $state toggle');

  /// 引擎对齐：left/right/top/bottom/hcenter/vcenter，≥2 节点。
  Future<bool> alignNodes(List<String> ids, String mode) {
    if (activeBoard == null || ids.length < 2) return Future.value(false);
    return applyOp('align $activeBoard $mode ${ids.join(' ')}');
  }

  Future<bool> groupNodes(String groupId, List<String> ids) {
    if (activeBoard == null || ids.length < 2) return Future.value(false);
    return applyOp('group $activeBoard $groupId ${ids.join(' ')}');
  }

  Future<bool> ungroupNodes(String groupId) {
    if (activeBoard == null) return Future.value(false);
    return applyOp('ungroup $activeBoard $groupId');
  }

  /// 交互标记：actionSpec 形如 back / haptic / navigate_to:<board> /
  /// show_toast:<msg> / set_text:<node>:<text> / set_state:<node>:<state> /
  /// toggle_state:<node> / play_sound:<name>。含空格时引擎可容忍（探针过）。
  Future<bool> interactNode(String node, String trigger, String actionSpec) {
    if (activeBoard == null) return Future.value(false);
    return applyOp('interact $activeBoard $node $trigger $actionSpec');
  }

  Future<bool> uninteractNode(String node) {
    if (activeBoard == null) return Future.value(false);
    return applyOp('uninteract $activeBoard $node');
  }

  Future<bool> connectFlow(String target) async {
    if (activeBoard == null || selectedNode == null) return false;
    return applyOp('flow $activeBoard $target $selectedNode');
  }

  Future<bool> disconnectFlow(String target) async {
    if (activeBoard == null || selectedNode == null) return false;
    return applyOp('unflow $activeBoard $target $selectedNode');
  }

  Future<bool> setTheme(String theme) => applyOp('theme $theme');

  Future<bool> setToken(String name, String value) => applyOp('token $name $value');

  /// Regenerate the active board against responsive breakpoints (engine creates
  /// _tablet/_desktop variants). Standard apply envelope; commits directly.
  Future<bool> responsiveBoard() async {
    if (activeBoard == null) return false;
    return applyOp('responsive $activeBoard');
  }

  /// 自动修复同样是画布变更，必须与 applyOp 同队列串行——绕过队列的
  /// 整篇 _commit 会与在飞 op 的 HTTP 往返交错，以陈旧 mbt 为基底提交
  /// （丢改动；队列注释宣称的不变量对所有变更入口成立）。
  Future<bool> autoFix() => _chainOp(_autoFixNow);

  Future<bool> _autoFixNow() async {
    if (api == null || activeBoard == null) return false;
    try {
      final res = await api!.session(mbt, 'session_auto_fix', activeBoard);
      if (res['ok'] != true) {
        _toast('自动修复未提交', res['error']?.toString());
        return false;
      }
      return _commit(res);
    } catch (e) {
      _toast('自动修复失败', e.toString());
      return false;
    }
  }

  Future<Map<String, dynamic>?> critique() async {
    if (api == null || activeBoard == null) return null;
    final res = await api!.session(mbt, 'session_critique', activeBoard);
    final data = res['data'];
    if (data is Map) return Map<String, dynamic>.from(data);
    return res;
  }

  /// Token/color usage extracted from a board (session_extract_design_system):
  /// {summary, color_tokens[], components[]}.
  Future<Map<String, dynamic>?> extractDesignSystem(String ab) async {
    if (api == null) return null;
    final res = await api!.session(mbt, 'session_extract_design_system', ab);
    final data = res['data'];
    if (data is Map) return Map<String, dynamic>.from(data);
    return res;
  }

  /// 把引擎提取的 color_tokens 合并进 docs.design.palette（usage 降序，
  /// 高频覆盖同名低频）——规范页提取与 build 终态 designFromEngine 共用。
  void mergeExtractedPalette(Map<String, dynamic> data) {
    final raw = data['color_tokens'];
    if (raw is! List) return;
    final tokens = raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
      ..sort((a, b) {
        final ua = (a['usage'] as num?) ?? 0;
        final ub = (b['usage'] as num?) ?? 0;
        return ub.compareTo(ua);
      });
    final palette = Map.of(docs.design.palette);
    for (final t in tokens) {
      final name = t['name']?.toString();
      final value = t['value']?.toString();
      if (name != null && value != null && value.isNotEmpty) palette[name] = value;
    }
    final d = docs.design;
    setDocs(design: DesignSpec(
      palette: palette,
      h1: d.h1, h2: d.h2, body: d.body,
      spacing: d.spacing,
      radiusSm: d.radiusSm, radiusMd: d.radiusMd, radiusLg: d.radiusLg,
      rules: d.rules, notes: d.notes,
    ));
  }

  /// 规范是否仍是默认值（未被 PLAN 写入/未手编/未提取过）。
  bool get designIsDefault {
    final d = docs.design;
    if (d.notes.isNotEmpty || d.rules.length != DesignSpec.defaults.rules.length) return false;
    for (final e in DesignSpec.defaults.palette.entries) {
      if (d.palette[e.key]?.toUpperCase() != e.value.toUpperCase()) return false;
    }
    return true;
  }

  /// deepDesign「校验并渲染」对齐：把源码编辑器的整篇提交走引擎校验
  /// （render 面，比 op 路径更严——真实重叠债会拒绝），通过即 commit。
  /// 与 applyOp/autoFix 同队列串行（整篇覆盖型提交更需要排队防交错）。
  Future<bool> applySource(String text) => _chainOp(() => _applySourceNow(text));

  Future<bool> _applySourceNow(String text) async {
    if (api == null || agentBusy) {
      if (agentBusy) _toast('NoN 正在工作', '等这一轮结束再改画布。');
      return false;
    }
    try {
      final res = await api!.render(text);
      if (res['ok'] != true) {
        _toast('源码被引擎拒绝', res['error']?.toString());
        return false;
      }
      return _commit(res);
    } catch (e) {
      _toast('引擎异常', e.toString());
      return false;
    }
  }

  /// deepDesign designFromEngine 对齐：build 终态且规范仍为默认时，
  /// 从入口画板提取真实配色落进规范——流程闭环「生成即得规范」。
  Future<void> _autoDesignFromEngine() async {
    if (api == null || !hasProject || !designIsDefault) return;
    final ab = render.entry.isNotEmpty
        ? render.entry
        : (render.artboards.isEmpty ? '' : render.artboards.first.id);
    if (ab.isEmpty) return;
    try {
      final data = await extractDesignSystem(ab);
      if (data != null) mergeExtractedPalette(data);
    } catch (_) {}
  }

  /// Missing-element check (session_infer_missing): {page_type, missing_count,
  /// missing[{type, element, suggestion}]}. The upstream detector autofill
  /// materializes.
  Future<Map<String, dynamic>?> inferMissing(String ab) async {
    if (api == null) return null;
    final res = await api!.session(mbt, 'session_infer_missing', ab);
    final data = res['data'];
    if (data is Map) return Map<String, dynamic>.from(data);
    return res;
  }

  /// Page-type classifier (session_infer_page_type): {page_type, signals}.
  Future<Map<String, dynamic>?> inferPageType(String ab) async {
    if (api == null) return null;
    final res = await api!.session(mbt, 'session_infer_page_type', ab);
    final data = res['data'];
    if (data is Map) return Map<String, dynamic>.from(data);
    return res;
  }

  /// Layout intent via /engine/constrain (session_constrain), e.g. 居中 / 等间距 /
  /// 网格 3. The success envelope carries canonical mbt without the render face,
  /// so we re-render before committing (same guard shape as the agent done path).
  /// 与 applyOp/autoFix 同队列串行（core-2）：与在飞 op 的 HTTP 往返交错
  /// 会以陈旧 mbt 为基底提交——队列注释宣称的不变量对所有变更入口成立。
  Future<bool> constrainLayout(String intent) => _chainOp(() => _constrainLayoutNow(intent));

  Future<bool> _constrainLayoutNow(String intent) async {
    if (api == null || agentBusy) {
      if (agentBusy) _toast('NoN 正在工作', '等这一轮结束再改画布。');
      return false;
    }
    final ab = activeBoard;
    if (ab == null) return false;
    try {
      final res = await api!.constrainIntent(mbt, ab, intent);
      if (res['ok'] != true) {
        _toast('布局意图未生效', res['error']?.toString());
        return false;
      }
      final canonical = res['mbt']?.toString() ?? '';
      final rendered = canonical.isNotEmpty ? await api!.render(canonical) : null;
      if (rendered == null || rendered['ok'] != true) {
        _toast('布局意图未生效', rendered?['error']?.toString() ?? 'render_failed');
        return false;
      }
      return _commit(rendered);
    } catch (e) {
      _toast('布局意图失败', e.toString());
      return false;
    }
  }

  void setDocs({String? prd, String? ui, DesignSpec? design}) {
    docs = Docs(
      prd: prd ?? docs.prd,
      ui: ui ?? docs.ui,
      design: design ?? docs.design,
    );
    dirty = true;
    notifyListeners();
  }

  void undo() {
    // 边界检查只在链内做：调用期读 historyIndex 会拿到在飞 op 提交前的
    // 旧下标，连按 ⌘Z 合并/丢失（已知缺口②）。agentBusy 快速路径保留。
    if (agentBusy) return;
    _chainOp(() => _historyStepNow(-1));
  }

  void redo() {
    if (agentBusy) return;
    _chainOp(() => _historyStepNow(1));
  }

  /// 排队的历史步进（⌘Z/⇧⌘Z）：目标下标必须在链内（前一条提交后）计算
  /// ——调用期急着算 historyIndex±1 会在在飞 op 未提交时读到旧下标，
  /// 连按两次合并成一步/撤销丢失（已知缺口②「与①同根应随队列一并做」，
  /// 本轮收口）。
  Future<void> _historyStepNow(int delta) async {
    if (agentBusy) return;
    if (delta < 0 && historyIndex <= 0) return;
    if (delta > 0 && historyIndex >= history.length - 1) return;
    await _jumpHistoryNow(historyIndex + delta);
  }

  Future<void> jumpHistory(int index) => _chainOp(() => _jumpHistoryNow(index));

  /// Engine-side version control (session_history). `command` is the
  /// sub-command expression: `init <board>`, `commit`, `log`, `undo`, `redo`,
  /// `diff <from> <to>`. Returns the engine envelope for panel display —
  /// nothing commits automatically except undo/redo jumps, whose canonical
  /// mbt is re-rendered and committed when present.
  /// undo/redo 的重渲染提交是画布变更，与 applyOp 同队列串行（core-2）。
  Future<Map<String, dynamic>> engineHistory(String command) =>
      _chainOp(() => _engineHistoryNow(command));

  Future<Map<String, dynamic>> _engineHistoryNow(String command) async {
    if (api == null || agentBusy) {
      return {'ok': false, 'error': agentBusy ? 'agent_busy' : 'no_server'};
    }
    try {
      final res = await api!.history(mbt, command);
      final kind = command.trim().split(RegExp(r'\s+')).first.toLowerCase();
      if ((kind == 'undo' || kind == 'redo') && res['ok'] == true) {
        final canonical = res['mbt']?.toString() ?? '';
        if (canonical.isNotEmpty) {
          final rendered = await api!.render(canonical);
          if (rendered['ok'] == true) _commit(rendered);
        }
      }
      return res;
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  Future<void> _jumpHistoryNow(int index) async {
    if (api == null || agentBusy || index < 0 || index >= history.length) return;
    final target = history[index];
    final res = await api!.render(target);
    if (res['ok'] != true) {
      _toast('无法切换历史', res['error']?.toString());
      return;
    }
    render = RenderEnvelope.fromJson(res);
    mbt = render.mbt.isNotEmpty ? render.mbt : target;
    historyIndex = index;
    previewRender = null;
    selectedNode = null;
    activeBoard = render.entry.isNotEmpty ? render.entry : (render.artboards.isEmpty ? null : render.artboards.first.id);
    dirty = true;
    notifyListeners();
  }

  Future<bool> runPlan(String brief) => _runAgent('plan', brief);

  Future<bool> runBuild(String instruction) => _runAgent('build', instruction);

  Future<bool> runRefine(String instruction) => _runAgent('refine', instruction);

  /// 发消息给外部 ACP 智能体（设置里选择后生效）。会话幂等：同一
  /// 项目+agent 复用已建立的连接；事件形状与 NoN 管线同族，时间线直接复用。
  Future<bool> runAcp(String text) async {
    // 移动端没有本地 agent/引擎：第三方智能体（ACP）不可用，强制走 NoN 内置
    //（设置里残留 acpAgentId 也不放行——用户裁决 2026-11-16）。
    if (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.android) {
      _toast('移动端不支持第三方智能体', '请使用 NoN 内置管线（文档直连 / 连接桌面）。');
      return false;
    }
    if (api == null || agentBusy) {
      if (agentBusy) _toast('NoN 正在工作', '等这一轮结束再发。');
      return false;
    }
    final agentId = settings.acpAgentId;
    if (agentId == null || agentId.isEmpty) {
      _toast('未选择外部智能体', '设置 → 外部智能体 里选择。');
      return false;
    }
    runId = DateTime.now().microsecondsSinceEpoch % 0x7fffffff;
    agentBusy = true;
    agentPhase = 'external';
    agentError = null;
    streamText = '';
    thinkingText = '';
    _deltaBuffer = '';
    _thinkingBuffer = '';
    _runInstruction = text;
    _runStartedAt = DateTime.now().toIso8601String();
    _liveCanonical = null;
    usage = const {};
    timeline = [
      TimelineEntry.user(text),
      TimelineEntry(kind: 'phase', text: '外部智能体 · $agentId（ACP）'),
    ];
    rightTab = 'agent';
    unawaited(_persistRecovery(force: true));
    notifyListeners();

    var success = false;
    try {
      // 会话幂等：项目或 agent 变了就重建。
      final project = projectPath ?? '~';
      if (_acpSessionId == null || _acpSessionAgent != agentId || _acpSessionProject != project) {
        final res = await api!.acpNewSession(agentId, projectPath);
        if (res['ok'] != true) {
          throw Exception('${res['error'] ?? 'session failed'}${res['note'] != null ? ' · ${res['note']}' : ''}');
        }
        _acpSessionId = res['sessionId']?.toString();
        _acpSessionAgent = agentId;
        _acpSessionProject = project;
      }
      await for (final ev in api!.acpPrompt(_acpSessionId!, text)) {
        switch ((ev['type'] ?? '').toString()) {
          case 'assistant_delta':
            _deltaBuffer += (ev['text'] ?? '').toString();
            _deltaTimer ??= Timer(const Duration(milliseconds: 80), () {
              _deltaTimer = null;
              _flushDelta();
            });
            break;
          case 'thinking_delta':
            _thinkingBuffer += (ev['text'] ?? '').toString();
            _thinkingTimer ??= Timer(const Duration(milliseconds: 80), () {
              _thinkingTimer = null;
              _flushThinking();
            });
            break;
          case 'tool_start':
            _flushDelta();
            _flushThinking();
            timeline.add(TimelineEntry(
              kind: 'tool',
              tool: (ev['tool'] ?? 'tool').toString(),
              running: true,
            ));
            notifyListeners();
            break;
          case 'tool_end':
            for (var i = timeline.length - 1; i >= 0; i--) {
              if (timeline[i].kind == 'tool' && timeline[i].running) {
                timeline[i].running = false;
                timeline[i].ok = ev['ok'] != false;
                break;
              }
            }
            notifyListeners();
            break;
          case 'note':
            timeline.add(TimelineEntry.note((ev['label'] ?? '').toString(), (ev['detail'] ?? '').toString()));
            notifyListeners();
            break;
          case 'done':
            success = true;
            break;
          case 'failed':
            agentError = (ev['error'] ?? '').toString();
            break;
        }
        if (ev['type'] == 'done' || ev['type'] == 'failed') break;
      }
      _flushDelta();
      _flushThinking();
      timeline.add(success
          ? TimelineEntry.finish(true, '外部智能体完成', 'agent: $agentId · ACP')
          : TimelineEntry.finish(false, '外部智能体异常结束', agentError ?? 'unknown'));
    } catch (e) {
      agentError = e.toString();
      _flushDelta();
      _flushThinking();
      timeline.add(TimelineEntry.finish(false, '外部智能体连接失败', e.toString()));
    } finally {
      agentBusy = false;
      agentPhase = 'idle';
      runId = null;
      previewRender = null;
      _runInstruction = null;
      notifyListeners();
      unawaited(_persistRecovery(force: true));
    }
    return success;
  }

  Future<bool> generateFromBrief(String brief) async {
    if (agentBusy) return false;
    if (settings.apiKey.trim().isEmpty) {
      _toast('先配置模型', '在设置里填入服务商 API Key。');
      return false;
    }
    if (!hasProject) {
      final name = brief.replaceAll(RegExp(r'[^\p{L}\p{N}\s]', unicode: true), '').trim();
      await newProject(name: name.length > 18 ? name.substring(0, 18) : (name.isEmpty ? 'untitled' : name), empty: true);
    }
    final planned = await runPlan(brief);
    if (!planned || docs.prd.trim().isEmpty) {
      _toast('文档未完成', '继续补全文档，或直接调整画布。');
      return false;
    }
    return runBuild('请根据 PRD 与 UI 说明生成完整可交互原型。先规划页面连接，再逐屏生成，最后连线并自检。\n\nBRIEF:\n$brief');
  }

  Future<void> cancelAgent() async {
    if (runId == null || !agentBusy) return;
    agentPhase = 'cancelling';
    notifyListeners();
    // 内置 Dart 循环在飞：无论移动/桌面都没有服务器取消端点可调——
    // 取消即本地中断（token 透传到 streamText 的 abortSignal）。
    final token = _dartAgentCancel;
    if (token != null) {
      token.cancel();
      _toast('正在停止', '内置循环请求已中断。');
      return;
    }
    if (api == null) return;
    // /agent/cancel 超时/网络异常不得从按钮回调逸出为未处理异步异常
    // （postJson 默认 30s 超时；取消失败也要让用户知道下一步动作）。
    try {
      await api?.cancelAgent(runId!);
      _toast('正在停止', '当前这一步结束后生效。');
    } catch (e) {
      _toast('停止请求失败', '可等流自行结束，或重试停止。$e');
    }
  }

  // ============================================================
  // 聊天流主面（docs/plan-chat-stream-shell.md §2 S1）
  // ============================================================

  /// 追加一条聊天消息（容量封顶 300 条，与落盘上限同值；老的截掉）。
  void appendChat(ChatMessage message) {
    chatMessages.add(message);
    if (chatMessages.length > 300) {
      chatMessages = chatMessages.sublist(chatMessages.length - 300);
    }
    notifyListeners();
  }

  /// 聊天流发送入口：用户消息入列后按文档状态选模式——无文档先 PLAN
  /// 再 BUILD（generateFromBrief 同一管线），有文档直接 BUILD。执行
  /// 路由走 [_runAgent]：agentRuntime=dart → 内置 Dart 循环；server →
  /// 桌面服务 /agent/run（现状路径平移）。
  Future<bool> sendChat(String text) async {
    final brief = text.trim();
    if (brief.isEmpty) return false;
    if (agentBusy) {
      _toast('NoN 正在工作', '等这一轮结束再发。');
      return false;
    }
    appendChat(ChatMessage.user(brief));
    unawaited(_persistChat());
    return _runChatTurn(brief);
  }

  /// 一轮聊天 run：进度卡入列 → 事件镜像推进 → 终态收尾 + BUILD 成功
  /// 追加产物卡（原型）。
  Future<bool> _runChatTurn(String brief) async {
    final fresh = !docs.hasContent;
    final card = ChatMessage.progress(fresh ? '理解 brief，撰写产品文档' : '按指令更新原型');
    appendChat(card);
    _chatCard = card;
    chatActive = true;
    var built = false;
    var ok = false;
    try {
      if (fresh) {
        // 桌面/连接桌面：先建空项目（generateFromBrief 同一先建后用纪律）；
        // 移动离线（api==null）不建——内置 Dart PLAN 成功后自建最小项目态
        // （_runDartLoop 的 !hasProject 分支）。
        if (!hasProject && api != null) {
          final name = brief.replaceAll(RegExp(r'[^\p{L}\p{N}\s]', unicode: true), '').trim();
          final created = await newProject(
            name: name.length > 18 ? name.substring(0, 18) : (name.isEmpty ? 'untitled' : name),
            empty: true,
          );
          if (!created) {
            card.running = false;
            card.ok = false;
            card.detail = '项目创建失败';
            return false;
          }
        }
        ok = await _runAgent('plan', brief);
        if (ok && docs.prd.trim().isNotEmpty) {
          card.text = '规划页面并生成原型';
          notifyListeners();
          ok = await _runAgent(
            'build',
            '请根据 PRD 与 UI 说明生成完整可交互原型。先规划页面连接，再逐屏生成，最后连线并自检。\n\nBRIEF:\n$brief',
          );
          built = ok;
        }
      } else {
        ok = await _runAgent('build', brief);
        built = ok;
      }
      return ok;
    } finally {
      chatActive = false;
      _chatCard = null;
      card.running = false;
      if (ok && built) {
        card.text = '原型已生成';
        appendChat(ChatMessage.artifact(
          kind: artifactPrototype,
          title: projectName,
          detail: '可交互原型已生成，点开进入工作区',
        ));
      } else {
        card.ok = ok;
        if (!ok) card.detail ??= agentError ?? '本轮未完成';
      }
      notifyListeners();
      unawaited(_persistChat());
    }
  }

  /// run 事件 → 活动进度卡的镜像（时间线管线不动，聊天卡并行推进）。
  void _mirrorChatEvent(String type, Map<String, dynamic> event) {
    final card = _chatCard;
    if (card == null) return;
    switch (type) {
      case 'tool_start':
        card.steps.add(ChatStep(label: (event['tool'] ?? 'tool').toString(), running: true));
      case 'tool_end':
        final tool = (event['tool'] ?? '').toString();
        for (final s in card.steps.reversed) {
          if (s.label == tool && s.running) {
            s.running = false;
            s.ok = event['ok'] != false;
            s.ms = (event['ms'] is num) ? (event['ms'] as num).toInt() : null;
            break;
          }
        }
      case 'note':
        card.steps.add(ChatStep(
          label: (event['label'] ?? '').toString(),
          detail: (event['detail'] ?? '').toString(),
        ));
      case 'page_generated':
        card.steps.add(ChatStep(
          label: '生成画板 ${event['artboard'] ?? ''}',
          detail: event['summary']?.toString(),
        ));
      case 'assistant_text':
        // 助手正文独立成卡（不在进度卡里折叠）；streamText 此时仍被
        // _handleAgentEvent 的同名分支持有，读同一份不清空。
        if (event['final'] == true) {
          final text =
              streamText.trim().isNotEmpty ? streamText : (event['text'] ?? '').toString();
          if (text.trim().isNotEmpty) chatMessages.add(ChatMessage.assistant(text));
        }
      case 'doc_written':
        final kind = (event['kind'] ?? '').toString();
        final content = event['content'];
        card.steps.add(ChatStep(
          label: kind == 'prd' ? '撰写产品文档' : '撰写 UI 说明',
          detail: content is String && content.isNotEmpty ? '${content.length} 字' : null,
        ));
      case 'design_spec_written':
        card.steps.add(ChatStep(label: '写入设计规范'));
      case 'failed':
        card.detail = (event['error'] ?? 'failed').toString();
    }
  }

  /// A2UI 交互卡动作回流（plan §2「确认表单/参数选择 → 回流续跑」）：
  /// 动作摘要作为用户消息入列并自动续跑一轮。agentBusy 时只提示——
  /// 动作不丢（卡片还在流里），可稍后重发。
  Future<void> handleChatAction(String name, Map<String, dynamic> context) async {
    if (agentBusy) {
      _toast('NoN 正在工作', '等这一轮结束再交互。');
      return;
    }
    final ctx = context.isEmpty ? '' : ' ${jsonEncode(context)}';
    final summary = '交互卡提交「$name」$ctx';
    appendChat(ChatMessage.user(summary));
    unawaited(_persistChat());
    await _runChatTurn(summary);
  }

  /// 聊天流顶栏「工作区」入口：无项目先建空项目（先建后用纪律），再切
  /// 设计视图。聊天主面下这是进工作区的显式唯一门（S4 分栏/PiP 之前）。
  Future<void> openWorkspace() async {
    if (!hasProject) {
      final ok = await newProject(empty: true);
      if (!ok) return;
    }
    setView('design');
  }

  /// 聊天记录落盘（$recoveryDir/chat.json，与 recovery 同目录、测试可注入）。
  /// 写链串行——append/clear 与在飞写交错会产生撕裂 JSON（recovery.json
  /// 同一治理）。
  Future<void> _persistChat() async {
    try {
      await Directory(recoveryDir).create(recursive: true);
      final payload = jsonEncode({
        'v': 1,
        'ts': DateTime.now().millisecondsSinceEpoch,
        'messages': [for (final m in chatMessages) m.toJson()],
      });
      final write =
          _chatWriteQueue.then((_) => File('$recoveryDir/chat.json').writeAsString(payload));
      _chatWriteQueue = write.then<void>((_) {}, onError: (Object _) {});
      await write;
    } catch (_) {}
  }

  /// 重启恢复聊天记录。在跑的进度卡随进程死亡降级为失败卡（诚实呈现，
  /// 不伪装成仍在运行）。
  Future<void> _loadChat() async {
    try {
      final file = File('$recoveryDir/chat.json');
      if (!await file.exists()) return;
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map) return;
      final list = raw['messages'];
      if (list is! List) return;
      chatMessages = [
        for (final e in list)
          if (e is Map) ChatMessage.fromJson(Map<String, dynamic>.from(e)),
      ];
      for (final m in chatMessages) {
        if (m.kind == chatKindProgress && m.running) {
          m.running = false;
          m.ok = false;
          m.detail ??= '应用重启，运行中断';
        }
      }
    } catch (_) {}
  }

  @visibleForTesting
  Future<void> debugLoadChat() => _loadChat();

  @visibleForTesting
  Future<void> debugPersistChat() => _persistChat();

  @visibleForTesting
  Future<void> get chatWritesIdle => _chatWriteQueue;

  /// 清空聊天流（含落盘记录）。
  Future<void> clearChat() async {
    chatMessages = [];
    _chatCard = null;
    try {
      final del = _chatWriteQueue.then((_) => File('$recoveryDir/chat.json').delete());
      _chatWriteQueue = del.then<void>((_) {}, onError: (Object _) {});
      await del;
    } catch (_) {}
    notifyListeners();
  }

  /// 内置 Dart 循环（core/dart_agent.dart，agentRuntime='dart'）。
  /// PLAN/Refine 纯本地（无引擎依赖）；BUILD/Refine 的 design_op 经
  /// store 锚定桥（[_StoreEngineGate]）走 applyAgentOp——applyOp 同队列
  /// 同提交语义 + /engine/apply gate:'agent'（AgentGate——绝不绕过引擎门）。
  /// 事件与 server SSE 同形，复用 [_handleAgentEvent] 的时间线/文档/preview 管线。
  Future<bool> _runDartLoop(String mode, String instruction) async {
    if (agentBusy) return false;
    if (settings.apiKey.trim().isEmpty) {
      _toast('先配置模型', '内置 Dart 循环需要 API Key（或连接桌面服务器）。');
      return false;
    }
    final selected = model;
    if (selected != null && !selected.toolCall) {
      _toast('该模型不支持工具调用', 'Agent 需要 function calling。');
      return false;
    }
    if (selected != null && selected.protocol != 'openai') {
      _toast('非 OpenAI 兼容协议不可用', '请选择 OpenAI 兼容端点（MiniMax 亦提供 /v1）。');
      return false;
    }
    var base = settings.baseUrl.trim();
    if (base.isEmpty) base = selected?.baseUrl.trim() ?? '';
    if (base.isEmpty) base = _builtInBaseUrls[settings.providerId] ?? _builtInBaseUrls['openai']!;
    if (settings.baseUrl.trim().isEmpty) {
      settings.baseUrl = base; // 空端点曾让 OpenAIProvider 发到空 baseUrl 静默失败
      unawaited(saveSettings());
      _toast('已回退默认端点', base);
    }
    // run 起点的 mbt 快照与 server 路径同一纪律：在飞 op 先排空再取快照，
    // 否则终态回来会覆盖掉尚未 _commit 的 op（丢更新）。
    await _opQueue;
    if (agentBusy) return false; // 排队等待期间有并发 run 启动：让位
    runId = DateTime.now().microsecondsSinceEpoch % 0x7fffffff;
    agentBusy = true;
    agentPhase = mode == 'plan' ? 'planning' : mode == 'refine' ? 'refining' : 'building';
    _runInstruction = instruction;
    _runStartedAt = DateTime.now().toIso8601String();
    _liveCanonical = null;
    unawaited(_persistRecovery(force: true));
    agentError = null;
    streamText = '';
    thinkingText = '';
    _deltaBuffer = '';
    _thinkingBuffer = '';
    // doc 直播同 run 生命周期（与 _runAgent 同根）：上一失败 run 的残尾不进本轮。
    liveDocText = '';
    _docBuffer = '';
    usage = const {};
    timeline = [
      TimelineEntry.user(instruction),
      TimelineEntry(
        kind: 'phase',
        text: mode == 'plan'
            ? '理解 brief，撰写产品文档（内置 Dart）'
            : mode == 'refine'
                ? '定位改动，保持设计系统（内置 Dart）'
                : '规划页面并落画布（内置 Dart · 引擎门）',
      ),
    ];
    // 聊天流驱动的 run 不跳视图/rightTab（聊天流是主面；进工作区是
    // 显式动作——openWorkspace）。
    if (!chatActive) {
      rightTab = 'agent';
      if (mode == 'plan') view = 'docs';
      if (mode != 'plan') view = 'design';
    }
    _dartAgentCancel = CancellationToken();
    notifyListeners();

    var success = false;
    var orphaned = false;
    final myRun = runId!;
    final events = StreamController<Map<String, dynamic>>();
    try {
      final runFuture = runDartAgent(
        request: DartAgentRequest(
          mode: mode,
          instruction: instruction,
          mbt: mbt,
          docs: docs.toJson(),
          model: selected?.id ?? settings.modelId,
          baseUrl: base,
          apiKey: settings.apiKey,
          thinkingLevel: settings.thinkingLevel,
          maxSteps: settings.maxSteps,
          contextWindow: selected?.context,
        ),
        // Build/Refine 的写路径经 store 锚定桥：design_op 落 applyAgentOp
        // （applyOp 同队列同提交语义 + AgentGate）；检视走 HTTP 只读路由。
        bridge: api == null ? null : _StoreEngineGate(this),
        // 测试注入 scripted mock；生产恒 null（OpenAIProvider 直连）。
        modelOverride: debugAgentModelOverride,
        abortSignal: _dartAgentCancel,
        timeout: const Duration(minutes: 10),
        onEvent: (ev) {
          if (!events.isClosed) events.add(ev);
        },
      );
      unawaited(runFuture.whenComplete(() => unawaited(events.close())));
      await for (final ev in events.stream) {
        // run 归属校验（与 _runAgent 同一结构性兜底）：项目切换等路径换掉
        // runId 即本 run 废弃，剩余事件整流丢弃。
        if (runId != myRun) {
          orphaned = true;
          break;
        }
        await _handleAgentEvent(ev);
        if (ev['type'] == 'done') success = true;
      }
      await runFuture; // 循环自身保证终态事件；这里只兜异常
      if (!orphaned && success && mode == 'plan' && !hasProject) {
        // 移动 PLAN 成功必须建立最小项目态：否则 hasProject 仍 false，
        // 主界面停在 Welcome、_persistRecovery 早退，文档看不见也救不回。
        hasProject = true;
        final cleaned = instruction
            .replaceAll(RegExp(r'[^\p{L}\p{N}\s]', unicode: true), '')
            .trim();
        projectName = cleaned.length > 18 ? cleaned.substring(0, 18) : (cleaned.isEmpty ? 'untitled' : cleaned);
        render = RenderEnvelope.empty();
        previewRender = null;
        activeBoard = null;
        dirty = true;
        docsTab = 'prd';
        unawaited(_persistRecovery(force: true));
        _toast('文档已生成', '内置 Dart 直连完成。');
      } else if (!orphaned && !success && agentError == 'doc_not_written') {
        _toast('无文档产出', '模型未调用 write_doc——重试或换模型。');
      }
    } catch (e) {
      agentError = e.toString();
      timeline.add(TimelineEntry.finish(false, '运行失败', e.toString()));
    } finally {
      _dartAgentCancel = null;
      _flushStreamAsAssistant();
      _flushThinking();
      _docBuffer = '';
      agentBusy = false;
      streamText = '';
      agentPhase = 'idle';
      runId = null;
      previewRender = null;
      notifyListeners();
      unawaited(_persistRecovery(force: true));
    }
    return success;
  }

  Future<bool> _runAgent(String mode, String instruction) async {
    if (agentBusy) return false;
    // 运行时路由（models.dart agentRuntime）：dart = 内置 Dart 循环
    // （PLAN/Refine 纯本地；BUILD 需引擎桥——画布变更必须过 AgentGate）；
    // server = 桌面服务 /agent/run。显式选择的运行时不静默降级：
    // server 未连接、dart 缺引擎桥都显性报错。
    final dartRuntime = settings.agentRuntime == agentRuntimeDart;
    if (dartRuntime && mode == 'build' && api == null) {
      _toast('内置 Dart 构建需要引擎', 'Build 的画布变更必须经引擎 AgentGate——'
          '连接桌面服务器（设置 → 桌面服务器）后重试，或切回「桌面服务」运行时。');
      return false;
    }
    if (dartRuntime) {
      return _runDartLoop(mode, instruction);
    }
    if (api == null) {
      _toast('未连接桌面服务', '「桌面服务」运行时需要先连接桌面服务器'
          '（设置 → 桌面服务器），或切回「内置 Dart」运行时。');
      return false;
    }
    if (settings.apiKey.trim().isEmpty) {
      _toast('先配置模型', '在设置里填入服务商 API Key。');
      return false;
    }
    final selected = model;
    if (selected == null) {
      _toast('模型不存在', '请在设置里重新选择模型。');
      return false;
    }
    if (!selected.toolCall) {
      _toast('该模型不支持工具调用', 'Agent 需要 function calling。');
      return false;
    }
    if (selected.protocol != 'openai') {
      _toast('非 OpenAI 兼容协议不可用', '请选择 OpenAI 兼容端点（MiniMax 亦提供 /v1）。');
      return false;
    }
    // run 起点的 mbt 快照必须取在 op 队列排空之后：在飞 op 尚未 _commit
    // 就启动 run，服务端会拿着旧 canonical 干活，终态回来覆盖掉该 op
    // （丢更新——与 op 队列同一类，只是边界换到 run 起点）。排队中的 op
    // 各自 ≤30s HTTP 超时，这里至多等一条链。
    await _opQueue;
    if (agentBusy) return false; // 排队等待期间有并发 run 启动：让位
    runId = DateTime.now().microsecondsSinceEpoch % 0x7fffffff;
    agentBusy = true;
    agentPhase = mode == 'plan' ? 'planning' : mode == 'refine' ? 'refining' : 'building';
    _runInstruction = instruction;
    _runStartedAt = DateTime.now().toIso8601String();
    _liveCanonical = null;
    unawaited(_persistRecovery(force: true)); // 运行起点的第一份进度快照
    agentError = null;
    streamText = '';
    thinkingText = '';
    _deltaBuffer = '';
    _thinkingBuffer = '';
    // doc 直播同 run 生命周期：上一失败 run 的半截文档/未冲刷缓冲不进
    // 本轮直播（docs_view 以 liveDocText 非空判定直播，残留会在 PLAN run
    // 置 view='docs' 的第一帧就被当成新文档渲染；新 doc_delta 也会先拼上残留）。
    liveDocText = '';
    _docBuffer = '';
    usage = const {};
    timeline = [
      TimelineEntry.user(instruction),
      TimelineEntry(kind: 'phase', text: mode == 'plan' ? '理解 brief，撰写产品文档' : mode == 'refine' ? '定位改动，保持设计系统' : '规划页面并生成原型'),
    ];
    // 同 _runDartLoop：聊天流驱动的 run 不跳视图/rightTab。
    if (!chatActive) {
      rightTab = 'agent';
      if (mode == 'plan') view = 'docs';
      if (mode != 'plan') view = 'design';
    }
    notifyListeners();

    final body = {
      'run_id': runId,
      'mode': mode,
      'instruction': instruction,
      'mbt': mbt,
      'docs': docs.toJson(),
      'design_spec': docs.design.toJson(),
      'model': selected.id,
      'base_url': settings.baseUrl.isNotEmpty ? settings.baseUrl : selected.baseUrl,
      'api_key': settings.apiKey,
      'protocol': selected.protocol,
      'thinking_level': settings.thinkingLevel,
      'max_steps': settings.maxSteps,
      'session_key': projectPath ?? projectName,
      'context_window': selected.context,
    };

    var success = false;
    var orphaned = false;
    final myRun = runId!;
    try {
      await for (final event in api!.agentRun(body)) {
        // run 归属校验（core-1 兜底）：SSE 事件不携带 run id，以 stream
        // 启动时捕获的 runId 为归属令牌——store.runId 被换（项目切换等
        // 路径）即本 run 已废弃，剩余事件（含 done/failed 的 canonical
        // 提交）整流丢弃，旧项目内容不得写进当前项目。入口门已挡住常规
        // 路径，这里是结构性兜底。
        if (runId != myRun) {
          orphaned = true;
          break;
        }
        await _handleAgentEvent(event);
        if (event['type'] == 'done') success = true;
      }
      // 终态兜底：服务端进程崩溃/被杀时 socket 正常关闭、await for 无异常
      // 返回——没有 done 也没有 failed 事件。此时合成失败终态卡 + toast，
      // 并把悬挂的 running 工具条目收尾，避免时间线无声结束。
      // 废弃 run 不合成（它已不属于当前时间线）。
      if (!orphaned && !success && agentError == null) {
        agentError = '连接中断：服务端未返回终态事件';
        for (final item in timeline) {
          if (item.kind == 'tool' && item.running) {
            item.running = false;
            item.ok = false;
            item.error = agentError;
          }
        }
        timeline.add(TimelineEntry.finish(false, 'NoN 异常结束', agentError));
        _toast('NoN 异常结束', '连接中断，已提交的部分已保留。');
      }
    } catch (e) {
      agentError = e.toString();
      timeline.add(TimelineEntry.finish(false, '运行失败', e.toString()));
    } finally {
      _flushStreamAsAssistant();
      _flushThinking();
      // 失败 run 的 doc 尾巴就地丢弃（成功路径 doc_written 已冲刷+清零，
      // 这里只可能剩失败 run 未冲刷的缓冲；清空后挂起的 80ms doc timer
      // 空转返回，不再把残尾拼进任何后续直播）。
      _docBuffer = '';
      agentBusy = false;
      streamText = '';
      agentPhase = 'idle';
      runId = null;
      previewRender = null;
      notifyListeners();
      unawaited(_persistRecovery(force: true)); // 终态快照（run 标记已清）
    }
    return success;
  }

  Future<void> _handleAgentEvent(Map<String, dynamic> event) async {
    final type = (event['type'] ?? '').toString();
    // 聊天流镜像（S1）：时间线管线原样不动，活动进度卡并行推进。
    // 位置在 switch 之前——assistant_text 分支会消费并清空 streamText，
    // 镜像必须先读同一份正文。
    if (_chatCard != null) _mirrorChatEvent(type, event);
    switch (type) {
      case 'note':
        _flushStreamAsAssistant();
        timeline.add(TimelineEntry.note((event['label'] ?? '').toString(), (event['detail'] ?? '').toString()));
        break;
      case 'tool_start':
        _flushStreamAsAssistant();
        timeline.add(TimelineEntry(
          kind: 'tool',
          tool: (event['tool'] ?? '').toString(),
          args: event['args'] is Map ? Map<String, dynamic>.from(event['args'] as Map) : null,
          running: true,
        ));
        break;
      case 'tool_end':
        final tool = (event['tool'] ?? '').toString();
        for (var i = timeline.length - 1; i >= 0; i--) {
          final item = timeline[i];
          if (item.kind == 'tool' && item.running && item.tool == tool) {
            item.running = false;
            item.ok = event['ok'] != false;
            item.ms = (event['ms'] is num) ? (event['ms'] as num).toInt() : null;
            item.preview = event['preview']?.toString();
            item.error = event['error']?.toString();
            break;
          }
        }
        break;
      case 'page_generated':
        timeline.add(TimelineEntry.note(
          '生成画板 ${event['artboard'] ?? ''}',
          [
            if (event['template'] != null) '模板 ${event['template']}',
            if (event['score'] != null) '评分 ${event['score']}',
            if (event['summary'] != null) event['summary'].toString(),
          ].join(' · '),
        ));
        break;
      case 'assistant_delta':
        _deltaBuffer += (event['text'] ?? '').toString();
        _deltaTimer ??= Timer(const Duration(milliseconds: 80), () {
          _deltaTimer = null;
          _flushDelta();
          _flushThinking();
        });
        // 80ms 合帧只节流字符串还不够：逐片 notifyListeners 是全树重建
        // 放大器（30 处 context.watch + 根组件每次 build 新建 ThemeData）。
        // 缓冲后直接返回，通知统一由 Timer 冲刷与 switch 尾部承担。
        return;
      case 'assistant_text':
        if (event['final'] == true) {
          _flushDelta();
          final text =
              streamText.trim().isNotEmpty ? streamText : (event['text'] ?? '').toString();
          if (text.trim().isNotEmpty) timeline.add(TimelineEntry.assistant(text));
          streamText = '';
        }
        break;
      case 'thinking_delta':
        _thinkingBuffer += (event['text'] ?? '').toString();
        _thinkingTimer ??= Timer(const Duration(milliseconds: 80), () {
          _thinkingTimer = null;
          _flushThinking();
        });
        return; // 同 assistant_delta：缓冲后跳过 switch 尾部通知
      case 'doc_delta':
        // PLAN 阶段 write_doc 参数流式增量：正文边写边推进。同
        // assistant/thinking 的 80ms 合帧（逐片 notify 是全树重建放大器）；
        // doc_written 全量到达时先冲刷尾巴再清缓冲（全量事件是兜底）。
        _docBuffer += (event['text'] ?? '').toString();
        _docTimer ??= Timer(const Duration(milliseconds: 80), () {
          _docTimer = null;
          _flushDoc();
        });
        return;
      case 'doc_written':
        _flushDoc();
        final kind = (event['kind'] ?? '').toString();
        final content = (event['content'] ?? '').toString();
        if (kind == 'prd') docs.prd = content;
        if (kind == 'ui') docs.ui = content;
        liveDocText = '';
        unawaited(_persistRecovery()); // PLAN 半程崩溃也要保住已写文档
        notifyListeners();
        break;
      case 'design_spec_written':
        docs = Docs(prd: docs.prd, ui: docs.ui, design: DesignSpec.fromJson(event['spec']));
        notifyListeners();
        break;
      case 'preview':
        final b64 = event['mbt_b64']?.toString();
        if (b64 != null) {
          final incoming = utf8.decode(base64Decode(b64));
          // dart Build 的 op 已由 applyAgentOp 实时 _commit（store.mbt 即最新
          // canonical）——同 canonical 免一次 700ms 后的重复 /engine/render；
          // server 路径 run 中 store.mbt 不前进，preview 恒新，照常调度。
          if (incoming == mbt) break;
          _previewMbt = incoming;
          _previewTimer ??= Timer(const Duration(milliseconds: 700), () async {
            _previewTimer = null;
            final target = _previewMbt;
            _previewMbt = null;
            if (target == null || api == null) return;
            try {
              final res = await api!.render(target);
              if (res['ok'] == true && agentBusy) {
                previewRender = RenderEnvelope.fromJson(res);
                _liveCanonical = target;
                unawaited(_persistRecovery()); // 构建进度即时落盘
                notifyListeners();
              }
            } catch (_) {}
          });
        }
        break;
      case 'usage':
        usage = Map<String, dynamic>.from(event); // 通知由 switch 尾部统一发，不双发
        break;
      case 'cleanup':
        final removed = event['removed'];
        if (removed is List && removed.isNotEmpty) {
          timeline.add(TimelineEntry.note('清理空画板 ${removed.join(', ')}'));
        }
        break;
      case 'failed':
        agentError = (event['error'] ?? 'failed').toString();
        final partial = event['mbt_b64']?.toString();
        if (partial != null && partial.isNotEmpty && api != null) {
          final partialMbt = utf8.decode(base64Decode(partial));
          final res = await api!.render(partialMbt);
          if (res['ok'] == true) {
            _commit(res);
          } else {
            // 渲染失败也不丢已提交的 canonical：落 mbt + dirty，finally 的
            // _persistRecovery 会把它写进 recovery.json，重启后可恢复。
            mbt = partialMbt;
            dirty = true;
            _toast('画布渲染失败、文字已保留', res['error']?.toString());
          }
        }
        if (event['docs'] is Map) docs = Docs.fromJson(event['docs']);
        timeline.add(TimelineEntry.finish(false, 'NoN 异常结束', agentError));
        break;
      case 'done':
        final finalMbt = event['mbt_b64']?.toString();
        if (finalMbt != null && api != null) {
          final decoded = utf8.decode(base64Decode(finalMbt));
          final res = await api!.render(decoded);
          if (res['ok'] == true) {
            _commit(res);
          } else {
            // 同 failed 路径：最后一次 /engine/render 失败不能吞掉整轮提交，
            // 采纳 decoded canonical，等下一次渲染或保存恢复画面。
            mbt = decoded;
            dirty = true;
            _toast('画布渲染失败、文字已保留', res['error']?.toString());
          }
        }
        if (event['docs'] is Map) docs = Docs.fromJson(event['docs']);
        final summary = (event['text'] ?? '').toString();
        timeline.add(TimelineEntry.finish(true, 'NoN 完成', summary));
        // designFromEngine：直接构建（无 PLAN）时规范仍是默认 → 自动从
        // 画布提取真实配色，流程闭环（异步，不阻塞终态）。
        unawaited(_autoDesignFromEngine());
        // done 不再弹 toast（用户定案：没必要）——完整结论就在时间线
        // finish 条目里，画布保持干净。
        break;
    }
    notifyListeners();
  }

  void _flushDelta() {
    if (_deltaBuffer.isEmpty) return;
    streamText += _deltaBuffer;
    _deltaBuffer = '';
    notifyListeners();
  }

  /// 把未固化的流式正文落成 timeline assistant 条目并清空尾槽——
  /// 之后 append 的工具/系统条目自然排在它后面，保证严格时序
  /// （此前流式正文钉在列表尾槽，先说的话显示在工具后面）。
  void _flushStreamAsAssistant() {
    _flushDelta();
    if (streamText.trim().isEmpty) return;
    timeline.add(TimelineEntry.assistant(streamText));
    streamText = '';
  }

  void _flushThinking() {
    if (_thinkingBuffer.isEmpty) return;
    thinkingText += _thinkingBuffer;
    if (thinkingText.length > 6000) thinkingText = thinkingText.substring(thinkingText.length - 6000);
    _thinkingBuffer = '';
    notifyListeners();
  }

  /// 冲刷 doc_delta 缓冲（doc_written 全量到达前把尾巴落进直播正文）。
  void _flushDoc() {
    if (_docBuffer.isEmpty) return;
    liveDocText += _docBuffer;
    _docBuffer = '';
    notifyListeners();
  }

  Future<void> _loadRecovery() async {
    try {
      final file = File('$recoveryDir/recovery.json');
      if (!await file.exists()) return;
      final raw = jsonDecode(await file.readAsString());
      if (raw is Map && raw['mbt'] is String) {
        recovery = Map<String, dynamic>.from(raw);
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> _persistRecovery({bool force = false}) async {
    // 运行期间（agentBusy）即使未置 dirty 也要写：中途崩溃时文档
    //（doc_written）与画布进度（preview canonical）都靠这份快照恢复。
    // 移动端（api==null）没有画布/项目概念：只要 docs 有内容就落
    // docs-only recovery（hasProject 硬门曾让移动 PLAN 文档永远救不回）。
    final docsOnly = api == null && !hasProject;
    if (!force && !agentBusy) {
      if (docsOnly) {
        if (!docs.hasContent) return;
      } else if (!hasProject || !dirty) {
        return;
      }
    }
    try {
      await Directory(recoveryDir).create(recursive: true);
      final payload = jsonEncode({
        'mbt': mbt,
        'docs': docs.toJson(),
        'view': view,
        'name': projectName,
        'path': projectPath,
        'ts': DateTime.now().millisecondsSinceEpoch,
        // 半程任务标记：非空即「上次运行未正常结束」；partialMbt 是
        // run 中实时 preview 的最新 canonical（构建进度）。
        'run': agentBusy
            ? {
                'phase': agentPhase,
                'instruction': _runInstruction ?? '',
                'startedAt': _runStartedAt,
                'partialMbt': _liveCanonical ?? '',
              }
            : null,
      });
      // 串行写链（core-5）：本方法被 run 起点/终态/doc_written/preview 与
      // 周期 Timer 多处 unawaited 并发调用，两个 writeAsString（各持 fd、
      // truncate 从 0 写）交错可产生撕裂 JSON——下次启动 _loadRecovery 的
      // catch-all 会静默吞掉解析失败，半程恢复快照无声丢失。后写覆盖先写。
      final write = _recoveryWriteQueue
          .then((_) => File('$recoveryDir/recovery.json').writeAsString(payload));
      _recoveryWriteQueue = write.then<void>((_) {}, onError: (Object _) {});
      await write;
    } catch (_) {}
  }

  /// 测试锚点：直驱一份快照 + 等写链排空（应用代码走内部各调用点）。
  @visibleForTesting
  Future<void> debugPersistRecovery({bool force = false}) => _persistRecovery(force: force);

  @visibleForTesting
  Future<void> get recoveryWritesIdle => _recoveryWriteQueue;

  void _invalidateAcpSession() {
    final sid = _acpSessionId;
    _acpSessionId = null;
    _acpSessionAgent = null;
    _acpSessionProject = null;
    if (sid != null && api != null) unawaited(api!.acpClose(sid));
  }

  Future<void> restoreRecovery() async {
    final rec = recovery;
    if (rec == null) return;
    try {
      // 移动端离线（api==null）：只恢复文档与视图——没有引擎可 render。
      if (api == null) {
        docs = Docs.fromJson(rec['docs']);
        view = 'docs';
        docsTab = 'prd';
        recovery = null;
        await _clearRecovery();
        notifyListeners();
        _toast('已恢复未保存的文档', '移动直连生成的内容已回到文档视图。');
        return;
      }
      // 中断运行优先用 partial canonical（构建进度），无则回落已提交 mbt。
      final run = rec['run'];
      final partial = (run is Map ? (run['partialMbt'] ?? '') : '').toString();
      var mbtValue = rec['mbt'].toString();
      if (partial.isNotEmpty) mbtValue = partial;
      var res = await api!.render(mbtValue);
      if (res['ok'] != true && partial.isNotEmpty) {
        mbtValue = rec['mbt'].toString(); // partial 坏掉时回落到已提交版本
        res = await api!.render(mbtValue);
      }
      if (res['ok'] != true) {
        _toast('恢复失败', res['error']?.toString());
        return;
      }
      hasProject = true;
      projectName = (rec['name'] ?? 'recovered').toString();
      projectPath = rec['path']?.toString();
      docs = Docs.fromJson(rec['docs']);
      dirty = true;
      history = [];
      _commit(res, recordHistory: false);
      recovery = null;
      await _clearRecovery();
      if (run is Map && (run['phase'] ?? '').toString().isNotEmpty) {
        final phase = (run['phase'] ?? '').toString();
        final label = switch (phase) { 'planning' => '撰写文档', 'building' => '构建原型', 'refining' => '调整原型', _ => phase };
        _toast('已恢复中断的$label进度', '文档与画布均已保留，可让 NoN 接着继续。');
      } else {
        _toast('已恢复未保存的工作');
      }
    } catch (e) {
      _toast('恢复失败', e.toString());
    }
  }

  Future<void> discardRecovery() async {
    recovery = null;
    await _clearRecovery();
    notifyListeners();
  }

  Future<void> _clearRecovery() async {
    // 删除同样入写链：与在飞快照写交错会出现「删后又复活旧内容」。
    try {
      final del = _recoveryWriteQueue
          .then((_) => File('$recoveryDir/recovery.json').delete());
      _recoveryWriteQueue = del.then<void>((_) {}, onError: (Object _) {});
      await del;
    } catch (_) {}
  }

  Future<void> refreshModels() async {
    if (api == null) return;
    try {
      final res = await api!.refreshModels();
      if (res['ok'] == true && res['snapshot'] is Map) {
        registry = ModelRegistry.fromJson(Map<String, dynamic>.from(res['snapshot'] as Map));
        notifyListeners();
        _toast('模型清单已更新', '${registry.providers.length} 个服务商');
      } else {
        _toast('更新失败', res['error']?.toString());
      }
    } catch (e) {
      _toast('更新失败', e.toString());
    }
  }

  Future<void> clearAgentSession() async {
    if (api == null) return;
    final res = await api!.clearSession(projectPath ?? projectName);
    _toast(res['removed'] == true ? '对话记忆已清空' : '没有找到会话文件');
  }

  String formatTokens(num? value) {
    final n = (value ?? 0).toDouble();
    if (n <= 0) return '0';
    if (n < 1000) return n.toStringAsFixed(0);
    if (n < 1000000) return '${(n / 1000).toStringAsFixed(n < 10000 ? 1 : 0)}K';
    return '${(n / 1000000).toStringAsFixed(1)}M';
  }

  @override
  void dispose() {
    _deltaTimer?.cancel();
    _thinkingTimer?.cancel(); // 与 _deltaTimer 对称：pending 合帧不得在 dispose 后触发
    _docTimer?.cancel(); // 同上（core-4）：pending doc_delta 冲刷会 notifyListeners 于已销毁的 notifier
    _previewTimer?.cancel();
    _recoveryTimer?.cancel();
    _server?.dispose();
    super.dispose();
  }
}

/// Build/Refine 循环的引擎桥（store 锚定，docs/plan-dart-agent-migration.md
/// P1 的 Build 写路径落地）。路由表：
/// - 变更（design_op 唯一去路）：[AppStore.applyAgentOp]——applyOp 同一条
///   _opQueue 队列 + 同一个 _commit 采纳 + /engine/apply gate:'agent'
///   （AgentGate，绝不绕过引擎门、绝不降级 human 门）。入参 mbt 刻意不用：
///   链内读 store.mbt 才是新鲜的（run 在飞时 agentBusy 挡住其余写者，
///   loop ctx.mbt 与 store.mbt 锁步）。
/// - 检视：POST /engine/session（session_query_nodes / session_interactions /
///   session_states / session_lint / session_critique / session_spec /
///   session_export_svg / session_flows / session_list_artboards，只读面）。
/// - 注册表：GET /engine/templates、GET /engine/components。
/// read_docs 不经引擎（server 同构：docs 在 run 请求载荷里，循环本地读）。
class _StoreEngineGate implements EngineGateBridge {
  final AppStore store;
  _StoreEngineGate(this.store);

  @override
  Future<Map<String, dynamic>> applyAgent(String mbt, String op) => store.applyAgentOp(op);

  @override
  Future<Map<String, dynamic>> session(String mbt, String name, [String? arg]) =>
      store.api!.session(mbt, name, arg);

  @override
  Future<List<dynamic>> templates() => store.api!.templates();

  @override
  Future<List<dynamic>> components() => store.api!.components();
}
