import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ai_sdk_dart/ai_sdk_dart.dart' show CancellationToken;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show debugPrint, defaultTargetPlatform, kIsWeb, visibleForTesting;
import 'package:flutter/material.dart' hide Flow;
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'app_paths.dart';
import 'capability.dart';
import 'capability_hub.dart';
import 'dart_agent.dart';
import 'ddp.dart';
import 'engine/engine_service.dart';
import 'keys.dart';
import 'models.dart';
import 'platform_capabilities.dart';
import 'project_service.dart';
import 'remote/desktop_rpc_host.dart';
import 'remote/rpc_methods.dart';
import 'remote_desktop_client.dart';
import 'toast_service.dart';

/// Kept for the shell/full-screen hosts that still wire a ScaffoldMessenger.
///
/// Store-originated notices no longer go through it (batch 04 owns the
/// [ToastService]/ToastHost outlet); the key stays until the shell migration
/// (batch 12) removes the remaining call sites.
final GlobalKey<ScaffoldMessengerState> rootMessengerKey = GlobalKey<ScaffoldMessengerState>();

const String _settingsKey = 'nondesign.settings';
const String _serverTokenKey = 'nondesign.serverToken';
const String _recentKey = 'nondesign.recent';

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

/// 解析随包发布的模型快照（`assets/models.json`，由 scripts/sync_models.py
/// 从上游裁剪生成）为注册表。形状不对/为空返回 null——离线注册表是增强
/// 不是依赖，失败保持现 registry。
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

/// 原子替换写入：先写同目录临时文件，再 rename 覆盖目标。
///
/// 进程在写到一半被杀/断电时目标保持旧内容，不会留下半截 JSON——正是
/// 崩溃恢复快照与聊天记录最需要的那条保证（此前是就地截断写）。
Future<void> _writeStringAtomic(File target, String contents) async {
  final temp = File('${target.path}.tmp-$pid-${DateTime.now().microsecondsSinceEpoch}');
  try {
    await temp.writeAsString(contents, flush: true);
    await temp.rename(target.path);
  } catch (_) {
    try {
      if (await temp.exists()) await temp.delete();
    } catch (_) {}
    rethrow;
  }
}

enum OpenResult { opened, needPassword, cancelled, failed }

/// 切换项目前对未保存改动的处置。
///
/// [cancel] 必须中止切换——静默清空当前项目的文档与画布是数据丢失事故
/// （审查 nav-2：新建/打开命中即空，没有任何二次确认）。
enum UnsavedChoice { save, discard, cancel }

class AppStore extends ChangeNotifier {
  /// [projects], [toasts] and [capabilities] are injectable so tests never
  /// touch the real project folder, the global notification bus or the host
  /// capability matrix.
  AppStore({
    ProjectService? projects,
    ToastService? toasts,
    CapabilityHub? capabilities,
    LocalCore? localCore,
  })  : projects = projects ?? ProjectService(),
        toasts = toasts ?? ToastService.instance,
        capabilities =
            capabilities ?? CapabilityHub(platform: PlatformCapabilities.current()),
        local = localCore {
    // Test/embedded hosts may hand over a ready local runtime; production
    // builds it in [boot] from the bundled artifact.
    if (localCore != null) {
      api = NoNDesignApi.runtime(local: localCore);
      this.capabilities.update(localCore.engine.probeAvailability());
    }
  }

  /// Runtime router: local engine first, connected desktop second.
  NoNDesignApi? api;

  /// Local, in-process runtime (engine + project library); null before boot.
  LocalCore? local;

  /// In-process design engine (batch 02). A failed start is still a service —
  /// it answers `engine_unavailable` and carries the diagnostic reason.
  EngineService? engine;

  /// Local `.ddp` project library. Client-side on every host, engine or not.
  final ProjectService projects;

  /// Optional "连接桌面" runtime.
  RemoteDesktopClient? remote;

  /// Optional desktop *host* that phones/tablets may connect to.
  ///
  /// Off by default; the settings card starts/stops it and shows the address
  /// plus the one-time pairing code. It is the same [DesktopRpcHost] the
  /// tests exercise — without this field the card would promise a desktop
  /// entry that no build ever started.
  DesktopRpcHost? desktopHost;
  bool desktopHostBusy = false;
  String? desktopHostError;

  /// Whether this host can serve a desktop connection at all (native desktop).
  bool get canServeDesktop =>
      !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

  bool get desktopHostRunning => desktopHost?.isRunning ?? false;

  /// Live host snapshot for the settings card (address/code/LAN state).
  RpcHostStatus? get desktopHostStatus => desktopHost?.status;

  /// Last probe of the connected desktop (user-ready copy included).
  RemoteDesktopStatus remoteStatus = const RemoteDesktopStatus.notConfigured();

  /// One-time pairing token for the connected desktop.
  ///
  /// Deliberately stored next to [AppSettings.serverUrl] instead of inside it:
  /// `models.dart` is owned by another batch. The value is persisted both as a
  /// dedicated preference and as an extra key in the settings JSON, so the
  /// settings surface can pick it up without a migration.
  String serverToken = '';

  /// Capability registry every surface asks before letting the user act.
  final CapabilityHub capabilities;

  /// Notification service — the single outlet for short user-visible notices.
  final ToastService toasts;

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
  bool _dirty = false;
  bool get dirty => _dirty;
  set dirty(bool value) {
    _dirty = value;
    // 每次置脏都推进「编辑代次」：切换项目的一次批准只对批准时的内容有效，
    // 排队中的 op 在批准后又改了项目就必须重新确认（不静默丢新改动）。
    if (value) _editGeneration++;
  }

  /// 当前项目文件本身受口令保护（打开 DDP1 / 以口令保存过）。
  ///
  /// 崩溃恢复不恢复口令，若放任空口令保存，下一次 ⌘S 会把 DDP1 静默
  /// 改写成无加密的 DDP2（审查 sec-recovery-password-downgrade）。
  bool _projectLocked = false;

  /// 打开/恢复的项目没有拿到画布预览（本机没有可用运行时，或预览生成
  /// 失败）。空画布不能冒充「还没有画板的空项目」（审查 depython-1）。
  bool canvasPreviewDegraded = false;

  /// 项目内容的编辑代次（见 [dirty] setter）。
  int _editGeneration = 0;

  /// 已获用户批准（保存/放弃）切换时对应的编辑代次；-1 = 未批准。
  ///
  /// 同一代次内重复发起切换（例如受保护项目「无口令打开 → needPassword →
  /// 带口令重试」的第二跳）不再重复弹确认框。
  int _switchApprovedGeneration = -1;

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
  /// 失败事件的人话版本（`failed.message`）；不上屏的原始码只在 [agentError]。
  String? agentUserMessage;

  // chat stream 主面（docs/plan-chat-stream-shell.md §2 S1）
  /// 聊天流消息（用户/进度/A2UI/产物卡），随 chat.json 落盘。
  List<ChatMessage> chatMessages = [];
  /// 本轮 sendChat 的活动进度卡（对象引用——下标会被容量截断挪位）。
  ChatMessage? _chatCard;
  /// 本轮 run 由聊天流驱动：run 内不跳 view/rightTab（聊天流是主面，
  /// PLAN 不把用户拽去 docs 视图、BUILD 不拽去 design 视图）。
  bool chatActive = false;
  /// 嵌入式工作区宿主登记计数（`Workspace(embedded: true)` 的
  /// initState/dispose 各记一次；聊天分栏与画中画浮窗会各挂一份）。
  ///
  /// 嵌入期间 view 必须保持 'chat'：面板里发送（runPlan/runBuild/runRefine）、
  /// 最近项目（openProjectFlow → openProjectPath）、新建项目/画板若把 view
  /// 切走，聊天宿主被整块替换，而全屏壳没有回聊天流的入口（review pip-1
  /// 的面板内路径）。计数而非布尔：宽窄切换/折叠重开时新旧实例可能短暂并存。
  int _embeddedHosts = 0;
  bool get embeddedHostActive => _embeddedHosts > 0;
  void enterEmbeddedHost() => _embeddedHosts++;
  void exitEmbeddedHost() {
    if (_embeddedHosts > 0) _embeddedHosts--;
  }

  /// 视图锁：聊天流驱动（本轮 run）或嵌入宿主在场时，view 不离开 'chat'。
  bool get _keepChatView => chatActive || embeddedHostActive;
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
  String? _recoveryDirOverride;

  /// 进度快照 / 聊天记录所在根目录。
  ///
  /// 生产走 [AppPaths.stateRoot]（桌面 `~/.nondesign`，无 HOME 的受限沙箱
  /// 与移动端落到应用文档目录）——此前直接拼 `$HOME`，HOME 缺失时所有
  /// 写入都落进空 catch，恢复功能静默失效（审查 sec-recovery-root-hardcoded-home）。
  /// 测试注入临时目录，不污染真实用户 home。
  @visibleForTesting
  String get recoveryDir => _recoveryDirOverride ?? AppPaths.stateRoot();
  @visibleForTesting
  set recoveryDir(String value) => _recoveryDirOverride = value;

  /// 切换项目（新建/打开）前询问「保存 / 放弃 / 取消」的出口。
  ///
  /// 根壳在 main.dart 用 Navigator 对话框注入；没有注入时按「取消」处理
  /// ——宁可不让切换，也不静默丢改动。判定本身在 [newProject] /
  /// [openProjectPath] 主路径，所有入口（工作区、左栏、Welcome、作品集、
  /// 命令面板、根级快捷键）共用同一道门。
  Future<UnsavedChoice> Function(String action)? confirmUnsavedChanges;

  /// 需要口令时向用户索取（恢复受保护项目 / 保存已加锁项目）。
  ///
  /// 返回 null 表示用户取消。未接线时不恢复、不保存（正文绝不因缺口令
  /// 而落到明文容器）。
  Future<String?> Function(String? path)? passwordPrompt;

  /// 进度快照写失败时只提示一次（周期写会把通知刷屏）。
  bool _recoveryWriteWarned = false;

  /// 聊天记录写失败时只提示一次。
  bool _chatWriteWarned = false;

  /// 进度/聊天记录损坏的提示只发一次（启动时两条记录可能同时坏）。
  bool _brokenStateNoticeShown = false;

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

  /// Boots the app: settings → local model snapshot → local runtime → optional
  /// connected desktop → project/recovery loading.
  ///
  /// Ordering rules (each one exists because the opposite order was a real
  /// defect):
  ///  * settings are read **before** any runtime is built — the "连接桌面"
  ///    address and token decide whether a desktop is probed at all;
  ///  * the bundled model snapshot is loaded **before** runtimes answer so the
  ///    model picker and the tool gates never depend on a remote face;
  ///  * a configured desktop that cannot be reached is a **visible failure**
  ///    (boot error screen), never a silent local fallback — otherwise the user
  ///    believes the desktop is connected until a 3D/hot-app entry fails;
  ///  * a local engine that fails to start is **not** fatal: documents,
  ///    recovery and the local project library keep working and the capability
  ///    hub carries the honest reason.
  Future<void> boot() async {
    // 进度快照/聊天记录要落在持久目录：没有可用 home 的宿主（移动端、
    // 受限沙箱）先把应用文档目录解析出来，AppPaths.stateRoot 才能返回
    // 真实路径而不是临时目录占位。
    await _ensureDurableStateRoot();
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(_settingsKey);
      if (stored != null) {
        try {
          final map = Map<String, dynamic>.from(jsonDecode(stored) as Map);
          settings = AppSettings.fromJson(map);
          serverToken = (map['serverToken'] ?? '').toString();
        } catch (_) {}
      }
      if (serverToken.isEmpty) {
        serverToken = (prefs.getString(_serverTokenKey) ?? '').toString();
      }

      await ensureBundledRegistry();
      await _startLocalEngine();
      // Restore the opt-in phone/tablet host before any client probe. It is
      // independent of the "连接桌面" *client* mode below: a desktop may both
      // serve phones and use its own local engine.
      if (settings.desktopHostEnabled && canServeDesktop) {
        await _startDesktopHostInternal(allowLan: settings.desktopHostAllowLan, persist: false);
      }

      // Probe a connected desktop only when the user actually chose that
      // runtime. A stale address saved from an earlier session must not turn
      // every cold start into the boot-error screen after the user switched
      // back to 内置.
      remote = settings.agentRuntime == agentRuntimeServer ? _buildRemoteClient() : null;
      if (remote != null) {
        final status = await remote!.probe(attempts: 2);
        remoteStatus = status;
        capabilities.setConnectedDesktop(
          connected: status.connected,
          message: status.message,
          technicalDetail: status.technicalDetail,
        );
        if (!status.connected) {
          // A configured desktop that cannot be reached is a visible failure:
          // never a silent local fallback, or the user believes the desktop is
          // connected until a 3D/hot-app entry fails.
          bootError = mobileDegradedBootError(
                status.technicalDetail ?? status.reason ?? status.message,
                settings.serverUrl,
              ) ??
              status.message;
          ready = false;
          notifyListeners();
          return;
        }
      }

      api = NoNDesignApi.runtime(local: local, remote: remote);

      final selected = model;
      if (selected != null) {
        if (settings.baseUrl.isEmpty) settings.baseUrl = selected.baseUrl;
      } else if (registry.providers.isNotEmpty) {
        final all = registry.flatten().where((x) => x.toolCall).toList();
        if (all.isNotEmpty) {
          final preferred = all.firstWhere(
            (x) => x.providerId == 'deepseek' && x.id.contains('v4.1'),
            orElse: () => all.first,
          );
          settings.providerId = preferred.providerId;
          settings.modelId = preferred.id;
          settings.baseUrl = preferred.baseUrl;
        }
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
      // Defensive: nothing above should throw (engine/desktop failures are
      // captured as capabilities). If something still does, stay usable in
      // offline mode rather than bricking the window.
      debugPrint('[store] boot degraded: $e');
      bootError = null;
      if (prefs != null) recent = _loadRecent(prefs);
      await ensureBundledRegistry();
      ready = true;
      await _loadRecovery();
      await _loadChat();
      _recoveryTimer ??= Timer.periodic(const Duration(seconds: 20), (_) => _persistRecovery());
      notifyListeners();
    }
  }

  /// 解析应用文档目录（仅在没有持久 home 的宿主上），让
  /// [AppPaths.stateRoot] 指向真实持久位置。失败不致命：恢复功能降级但
  /// 不影响主流程（写入失败会有一条可见提示）。
  Future<void> _ensureDurableStateRoot() async {
    if (!(Platform.isIOS || Platform.isAndroid || !AppPaths.hasDurableHome)) return;
    try {
      await AppPaths.appDocumentsDirectory();
    } catch (e) {
      debugPrint('[store] documents directory unavailable: $e');
    }
  }

  /// Whether phones/tablets may run the in-process engine.
  ///
  /// Hard default: no. `WasmRuntimeGate.mobileLocalEngineEnabled` flips only
  /// after `integration_test/wasm_spike_test.dart` records passing p95 /
  /// memory / fuel evidence on real devices.
  bool get _localEngineAllowed {
    if (!(Platform.isIOS || Platform.isAndroid)) return true;
    return WasmRuntimeGate.mobileLocalEngineEnabled;
  }

  /// Brings up the local runtime (engine over the bundled artifact, plus the
  /// client-side project library) and mirrors the outcome into the hub.
  Future<void> _startLocalEngine() async {
    if (!_localEngineAllowed) {
      final service = EngineService.unavailable(
        'local engine is disabled on this host until the device verification passes',
      );
      engine = service;
      local = LocalCore(engine: EngineServiceAdapter(service), projects: projects);
      capabilities.update(service.probeAvailability());
      return;
    }
    EngineService service;
    List<dynamic>? snapshot;
    try {
      final data = await rootBundle.load('assets/engine/moonviz.wasm');
      final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      try {
        final raw = await rootBundle.loadString('assets/engine/components.json');
        final decoded = jsonDecode(raw);
        if (decoded is List) snapshot = decoded;
      } catch (_) {
        // Missing/corrupt snapshot: the live registry still works.
      }
      service = await EngineService.start(wasmBytes: bytes, componentsSnapshot: snapshot);
    } catch (e) {
      service = EngineService.unavailable('$e');
    }
    engine = service;
    local = LocalCore(
      engine: EngineServiceAdapter(service),
      projects: projects,
      componentsSnapshot: snapshot,
    );
    capabilities.update(service.probeAvailability());
  }

  RemoteDesktopClient? _buildRemoteClient() {
    final url = RemoteDesktopClient.normalizeBaseUrl(settings.serverUrl);
    if (url.isEmpty) return null;
    return RemoteDesktopClient(baseUrl: url, token: serverToken);
  }

  /// 连接桌面的失败可见性裁决：配置过地址却连不上 → 返回错误文案
  /// （bootError 屏显性呈现）；未配置地址 → null（本地运行时是正常形态）。
  static String? mobileDegradedBootError(Object error, String serverUrl) {
    if (serverUrl.trim().isEmpty) return null;
    debugPrint('[store] connect desktop failed: $error');
    return '连接桌面没有成功，请检查地址与桌面端是否已开启连接';
  }

  /// 随包模型快照（`assets/models.json`，scripts/sync_models.py 生成）：
  /// 模型选择与 toolCall/protocol 门控的数据源，任何运行时都先读它。
  /// 幂等：registry 已有快照时不覆盖。
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

  /// 启动失败后的「重试」：清掉半残运行时再走一遍 boot（设置已落盘，
  /// 用户可在错误页先改连接桌面地址）。
  Future<void> retryBoot() async {
    await _disposeRuntimes();
    bootError = null;
    ready = false;
    notifyListeners();
    await boot();
  }

  /// 启动失败后的「离线继续」：不使用连接桌面，本地文档/项目库照常。
  ///
  /// Persists the local-runtime choice so the next cold start does not probe
  /// the same unreachable desktop again; the address stays for a later retry.
  Future<void> continueOffline() async {
    remote?.close();
    remote = null;
    remoteStatus = const RemoteDesktopStatus.notConfigured();
    capabilities.setConnectedDesktop(connected: false, message: '已在本地继续，未连接桌面');
    api = NoNDesignApi.runtime(local: local, remote: null);
    settings.agentRuntime = agentRuntimeLocal;
    await saveSettings();
    bootError = null;
    await ensureBundledRegistry();
    ready = true;
    notifyListeners();
    await _loadRecovery();
    await _loadChat();
    _recoveryTimer ??= Timer.periodic(const Duration(seconds: 20), (_) => _persistRecovery());
    notifyListeners();
  }

  Future<void> _disposeRuntimes() async {
    final service = engine;
    engine = null;
    local = null;
    await service?.dispose();
    final host = desktopHost;
    desktopHost = null;
    await host?.dispose();
    remote?.close();
    remote = null;
    api = null;
  }

  /// Scans the local project library (`~/Documents/NoNDesign` on desktop,
  /// app documents on mobile) plus the Desktop folder, and merges those with
  /// the connected desktop's library when one is available.
  ///
  /// Discovery is best-effort per source: one folder failing (permissions,
  /// missing) must not hide the others. Results are deduped by path, first
  /// source wins.
  Future<void> refreshProjects() async {
    if (refreshingProjects) return;
    refreshingProjects = true;
    notifyListeners();
    final merged = <String, Map<String, dynamic>>{};

    Future<void> merge(List<dynamic> items, String source) async {
      for (final item in items.whereType<Map>()) {
        final entry = Map<String, dynamic>.from(item);
        final path = entry['path']?.toString() ?? '';
        if (path.isEmpty || merged.containsKey(path)) continue;
        entry['source'] = source;
        merged[path] = entry;
      }
    }

    try {
      try {
        final root = await projects.defaultDirectory();
        workspaceDir = root.path;
        final localList = await projects.list(dir: root.path);
        if (localList.ok) {
          await merge([for (final e in localList.projects) e.toJson()], 'workspace');
        }
      } catch (_) {
        // Keep whatever the other sources produce.
      }
      final home = Platform.environment['HOME'];
      if (home != null && home.isNotEmpty) {
        try {
          final desktopList = await projects.list(dir: '$home/Desktop');
          if (desktopList.ok) {
            await merge([for (final e in desktopList.projects) e.toJson()], 'desktop');
          }
        } catch (_) {}
      }
      final client = remote;
      if (client != null && remoteStatus.connected) {
        try {
          final reply = await client.call('project.list');
          final items = reply['projects'];
          if (items is List) await merge(items, 'remote');
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
      final raw = jsonDecode(prefs.getString(_recentKey) ?? '[]');
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
    await prefs.setString(_recentKey, jsonEncode(recent));
    notifyListeners();
  }

  /// Persists settings and the optional desktop token.
  ///
  /// The token travels in the settings JSON **in addition to** its own key so a
  /// settings surface that models the whole object can round-trip it; unknown
  /// keys are ignored by [AppSettings.fromJson] until batch 11 adds the field.
  Future<void> saveSettings() async {
    final map = Map<String, dynamic>.from(settings.toJson());
    if (serverToken.isNotEmpty) map['serverToken'] = serverToken;
    final encoded = jsonEncode(map);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_settingsKey, encoded);
    await prefs.setString(_serverTokenKey, serverToken);
    // 镜像到 ~/.nondesign/settings.json：SharedPreferences 落在 macOS plist，
    // 测试探针/e2e 不便直读。含 apiKey/连接码，本机单用户，与 plist 同级
    // 安全模型；测试可改写 [settingsMirrorDir] 避免碰真实 home。
    try {
      final dir = settingsMirrorDir;
      await Directory(dir).create(recursive: true);
      await _writeStringAtomic(File('$dir/settings.json'), encoded);
    } catch (_) {}
    notifyListeners();
  }

  String? _settingsMirrorDirOverride;

  /// 设置镜像目录（生产 [AppPaths.stateRoot]；测试注入临时目录）。
  ///
  /// 与 [recoveryDir] 同一平台感知回退：没有 HOME 的受限沙箱不再写空。
  @visibleForTesting
  String get settingsMirrorDir => _settingsMirrorDirOverride ?? AppPaths.stateRoot();
  @visibleForTesting
  set settingsMirrorDir(String value) => _settingsMirrorDirOverride = value;

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
    return '$clean\n\n<!-- nondesign:ink ${jsonEncode(_inksJson)} -->';
  }

  /// 墨迹的可序列化形态（保存与崩溃快照共用；点坐标保留 4 位小数）。
  Map<String, dynamic> get _inksJson => demoInks.map((k, v) => MapEntry(
      k,
      v
          .map((s) => s
              .map((o) => [
                    double.parse(o.dx.toStringAsFixed(4)),
                    double.parse(o.dy.toStringAsFixed(4)),
                  ])
              .toList())
          .toList()));

  void _applyInksJson(Object? raw) {
    demoInks = {};
    if (raw is! Map || raw.isEmpty) return;
    try {
      demoInks = raw.map((k, v) => MapEntry(
          k.toString(),
          ((v as List).map((s) => ((s as List).map((pt) {
                final pair = pt as List;
                return Offset((pair[0] as num).toDouble(), (pair[1] as num).toDouble());
              }).toList())).toList())));
    } catch (_) {
      demoInks = {};
    }
  }

  /// 从文档恢复墨迹（只在打开项目时调用——运行中 op 不得清运行态批注）。
  void restoreInks(String documentMbt) {
    _parseInk(documentMbt);
    notifyListeners();
  }

  void _parseInk(String documentMbt) {
    demoInks = {};
    final m = RegExp(r'<!--\s*nondesign:ink\s*([\s\S]*?)-->').firstMatch(documentMbt);
    if (m == null) return;
    try {
      _applyInksJson(jsonDecode(m.group(1) ?? ''));
    } catch (_) {}
  }

  /// 恢复崩溃快照里的墨迹：优先用快照的 `ink` 字段，旧快照回落到文档尾块。
  ///
  /// 不回填的话「带批注 → 崩溃 → 恢复 → 保存」会把文件里的批注整块删掉
  /// （审查 data-ink-lost-on-recovery：mbtWithInk 空墨迹即剥块）。
  void _restoreInkSnapshot(Object? snapshot, String documentMbt) {
    if (snapshot is Map && snapshot.isNotEmpty) {
      _applyInksJson(snapshot);
    } else {
      _parseInk(documentMbt);
    }
  }

  void setDocsTab(String value) {
    docsTab = value;
    notifyListeners();
  }

  void setPanel(String value) {
    panel = value;
    // 左轨的「文档 / 规范」进的是同一个文档视图，标签必须跟着面板走：
    // 只切 view 会把「规范」停在「产品需求」页（审查 nav-4，docs_view 的
    // 标签完全取自 docsTab）。
    if (value == 'docs') {
      view = 'docs';
      docsTab = 'prd';
    } else if (value == 'spec') {
      view = 'docs';
      docsTab = 'spec';
    }
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

  /// 短提示出口（唯一）：级别决定停留时长与强调，文案走术语表。
  ///
  /// [technical] 只进控制台日志，不进通知——原始错误码属于折叠的「技术
  /// 详情」，通知里没有折叠空间。
  void _toast(String title, [Object? technical]) {
    if (technical != null) debugPrint('[store] $title: $technical');
    toasts.info(title);
  }

  void _toastSuccess(String title, [Object? technical]) {
    if (technical != null) debugPrint('[store] $title: $technical');
    toasts.success(title);
  }

  void _toastWarn(String title, [Object? technical]) {
    if (technical != null) debugPrint('[store] $title: $technical');
    toasts.warn(title);
  }

  void _toastError(String title, [Object? technical]) {
    if (technical != null) debugPrint('[store] $title: $technical');
    toasts.error(title);
  }

  /// True when at least one runtime can answer engine calls right now.
  bool get engineReady => api?.isReady ?? false;

  /// True when a "连接桌面" runtime is configured (and, in production, probed
  /// good). Tests that inject a router directly are treated as configured.
  bool get hasConnectedDesktop => remoteStatus.connected || (api?.hasRemote ?? false);

  /// Gate used by every engine-touching entry point: when no runtime can
  /// answer, say so through the capability hub instead of doing nothing.
  bool _requireEngine([CapabilityId id = CapabilityId.localDesignEngine]) {
    if (engineReady) return true;
    final availability = capabilities.availability(id);
    _toastWarn(availability.userMessage, availability.technicalDetail);
    return false;
  }

  /// User-facing sentence for an engine/project failure code.
  ///
  /// Codes are internal; only this mapping may reach the screen (glossary §4).
  static String failureMessage(Object? error) {
    final code = (error ?? '').toString().toLowerCase();
    if (code.contains('gate_block') || code.contains('unsupported')) {
      return '这次改动未通过设计校验';
    }
    if (code.contains('render')) return '预览生成失败';
    if (code.contains('unavailable') || code.contains('disconnected')) {
      return '设计服务暂时不可用，请稍后重试';
    }
    if (code.contains('timeout')) return '操作超时，请重试';
    if (code.contains('not_found') || code.contains('file_not_found')) return '文件不存在或已移动';
    return '操作没有完成，请重试';
  }

  /// 连接桌面的运行态快照（设置面板「检测连接」直接消费）。
  Future<RemoteDesktopStatus> testRemoteConnection(String url, {String? token}) async {
    // An empty field means "use the code saved from last time", not "send no
    // credential": the host rejects every /v1 request without a token.
    final typed = (token ?? '').trim();
    final effective = typed.isEmpty ? serverToken : typed;
    final client = RemoteDesktopClient(
      baseUrl: RemoteDesktopClient.normalizeBaseUrl(url),
      token: effective,
    );
    try {
      final status = await client.probe(attempts: 2);
      if (status.technicalDetail != null) {
        debugPrint('[store] connect probe: ${status.technicalDetail}');
      }
      return status;
    } finally {
      client.close();
    }
  }

  /// Applies a new "连接桌面" address/token, re-probes and rebuilds the router.
  ///
  /// An unreachable desktop is recorded as such (capability unavailable) and
  /// [RemoteDesktopStatus.message] is returned for the settings surface — the
  /// local runtime keeps working, but nothing pretends the desktop is there.
  Future<RemoteDesktopStatus> applyRemoteDesktop(String url, {String? token}) async {
    final normalized = RemoteDesktopClient.normalizeBaseUrl(url);
    settings.serverUrl = normalized;
    // Empty input keeps the saved code (the field is never "no auth"); only a
    // non-empty value replaces it. Clearing happens via
    // [disconnectRemoteDesktop], which also drops the address.
    final typed = (token ?? '').trim();
    if (typed.isNotEmpty) serverToken = typed;
    await saveSettings();

    remote?.close();
    remote = null;
    remoteStatus = const RemoteDesktopStatus.notConfigured();
    if (normalized.isEmpty) {
      capabilities.setConnectedDesktop(connected: false, message: '还没有连接桌面');
      api = NoNDesignApi.runtime(local: local, remote: null);
      notifyListeners();
      return remoteStatus;
    }

    final client = RemoteDesktopClient(baseUrl: normalized, token: serverToken);
    final status = await client.probe(attempts: 2);
    if (status.connected) {
      remote = client;
      remoteStatus = status;
    } else {
      client.close();
      remoteStatus = status;
    }
    capabilities.setConnectedDesktop(
      connected: status.connected,
      message: status.message,
      technicalDetail: status.technicalDetail,
    );
    api = NoNDesignApi.runtime(local: local, remote: remote);
    notifyListeners();
    return status;
  }

  /// Drops the connected desktop and returns to the local runtime.
  ///
  /// Forgetting the address/code is deliberate: leaving them behind made the
  /// next cold start probe an unreachable desktop again even after the user
  /// chose 内置.
  Future<void> disconnectRemoteDesktop() async {
    remote?.close();
    remote = null;
    remoteStatus = const RemoteDesktopStatus.notConfigured();
    settings.serverUrl = '';
    settings.agentRuntime = agentRuntimeLocal;
    serverToken = '';
    capabilities.setConnectedDesktop(connected: false, message: '还没有连接桌面');
    api = NoNDesignApi.runtime(local: local, remote: null);
    await saveSettings();
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // 连接桌面宿主（让手机/iPad 连到这台桌面电脑）
  // ---------------------------------------------------------------------------

  /// Starts (or keeps) the local host so phones/tablets can pair with it.
  Future<bool> startDesktopHost({bool? allowLan}) =>
      _startDesktopHostInternal(allowLan: allowLan, persist: true);

  /// Stops listening and remembers that the user turned the host off.
  Future<void> stopDesktopHost() async {
    settings.desktopHostEnabled = false;
    await saveSettings();
    await desktopHost?.stop();
    notifyListeners();
  }

  /// Settings switch entry point.
  Future<bool> setDesktopHostEnabled(bool enabled) async {
    if (!enabled) {
      await stopDesktopHost();
      return true;
    }
    return startDesktopHost();
  }

  /// Switches between loopback-only and LAN access. Restarts the host (the
  /// pairing code is regenerated by design) when it is currently listening.
  Future<bool> setDesktopHostAllowLan(bool allowLan) async {
    settings.desktopHostAllowLan = allowLan;
    await saveSettings();
    if (!desktopHostRunning) {
      notifyListeners();
      return settings.desktopHostEnabled;
    }
    return startDesktopHost(allowLan: allowLan);
  }

  /// Rotates the pairing code without restarting the listener.
  void regenerateDesktopHostToken() {
    desktopHost?.regenerateToken();
    notifyListeners();
  }

  Future<bool> _startDesktopHostInternal({bool? allowLan, required bool persist}) async {
    if (!canServeDesktop) {
      desktopHostError = '这台设备不能开启手机连接';
      notifyListeners();
      return false;
    }
    final core = local;
    if (core == null) {
      desktopHostError = '本机设计服务还没有准备好，请稍后再试';
      notifyListeners();
      return false;
    }
    final lan = allowLan ?? settings.desktopHostAllowLan;
    if (persist) {
      settings.desktopHostEnabled = true;
      settings.desktopHostAllowLan = lan;
      await saveSettings();
    }
    desktopHostBusy = true;
    desktopHostError = null;
    notifyListeners();
    try {
      var host = desktopHost;
      if (host == null) {
        // RpcServices lazily opens the workspaces; the local engine/project
        // library is the one dependency that already exists after boot.
        host = DesktopRpcHost(services: RpcServices(core: core));
        desktopHost = host;
      }
      final status = await host.start(allowLan: lan);
      if (!status.running) {
        desktopHostError = status.error ?? '连接没有启动成功';
        if (persist) {
          settings.desktopHostEnabled = false;
          await saveSettings();
        }
        return false;
      }
      return true;
    } catch (error) {
      debugPrint('[store] desktop host start failed: $error');
      desktopHostError = '$error';
      if (persist) {
        settings.desktopHostEnabled = false;
        await saveSettings();
      }
      return false;
    } finally {
      desktopHostBusy = false;
      notifyListeners();
    }
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
      _toastWarn(failureMessage(env.error), env.error);
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
    // 拿到真实画板即不再是「空画布冒充空项目」的降级态（depython-1）。
    if (env.artboards.isNotEmpty) canvasPreviewDegraded = false;
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

  /// 当前项目是否有会因切换而丢失的未保存改动。
  ///
  /// 空项目（无正文也无文档）不打扰用户；一旦有正文或文档，切换就必须
  /// 走 [confirmUnsavedChanges]（审查 nav-2：新建/打开曾经命中即清空）。
  bool get hasUnsavedChanges =>
      hasProject && _dirty && (mbt.trim().isNotEmpty || docs.hasContent);

  /// 已打开的项目没拿到可显示的画布（本机没有可用运行时，或预览生成失败）。
  ///
  /// 界面据此给出「画布需要连接桌面后才能预览」，而不是把无引擎的空画布
  /// 冒充「还没有画板的空项目」（审查 depython-1）。
  bool get canvasPreviewUnavailable =>
      hasProject && canvasPreviewDegraded && render.artboards.isEmpty;

  bool get _switchAlreadyApproved => _switchApprovedGeneration == _editGeneration;

  /// 项目切换审批：未保存改动 → 保存 / 放弃 / 取消。
  ///
  /// 返回 false 时调用方必须中止切换（取消 = 什么都不做）。同一编辑代次
  /// 内的重复发起（受保护项目的「无口令 → 追问 → 带口令重试」两跳）只问
  /// 一次。
  Future<bool> _confirmProjectSwitch(String action) async {
    if (!hasUnsavedChanges || _switchAlreadyApproved) return true;
    final ask = confirmUnsavedChanges;
    if (ask == null) {
      // 没有 UI 出口时保守拒绝：宁可不让切换，也不静默丢改动。
      _toastWarn('还有未保存的改动，先保存或放弃后再$action。');
      return false;
    }
    final choice = await ask(action);
    switch (choice) {
      case UnsavedChoice.save:
        final saved = await saveProject();
        if (saved) _switchApprovedGeneration = _editGeneration;
        return saved;
      case UnsavedChoice.discard:
        _switchApprovedGeneration = _editGeneration;
        return true;
      case UnsavedChoice.cancel:
        return false;
    }
  }

  /// 批准之后、真正交换内容之前复核：排队中的 op 可能在确认框打开期间
  /// 改了项目——那就必须重新确认，不能拿旧批准丢掉新改动。
  bool _switchTargetChanged(int approvedAt) {
    if (!hasUnsavedChanges) return false;
    if (_editGeneration == approvedAt) return false;
    _toastWarn('项目刚有新的未保存改动，请重新确认后再切换。');
    return true;
  }

  Future<bool> newProject({
    String name = 'untitled',
    String device = 'mobile',
    String? templateId,
    bool empty = false,
  }) async {
    // An empty project is a document container, not a canvas: it needs no
    // engine (phones can still write docs and recover them). A template or
    // default artboard does.
    if (!empty && !_requireEngine()) return false;
    // agentBusy 门（core-1）：run 在飞时切项目，在飞 run 的 done/failed
    // 事件随后会把旧项目的 canonical mbt 提交进新项目（静默覆盖新项目
    // 内容）；此前这里还硬置 agentBusy=false，把在飞 run 的状态位也拆了。
    if (agentBusy) {
      _toastWarn('NoN 正在工作，等这一轮结束再新建项目。');
      return false;
    }
    // 未保存改动门（nav-2）：所有入口共用 store 主路径——工作区、左栏最近
    // 项目、Welcome、作品集、命令面板与根级 ⌘N 都到这里。取消即中止。
    if (!await _confirmProjectSwitch('新建项目')) return false;
    final approvedAt = _editGeneration;
    // 同 op 队列串行：在飞 op 提交完才换项目，反向排队的 op 落在新项目
    // 上会被引擎按未知 id 拒绝（可恢复），不会静默覆盖。
    return _chainOp(() async {
      // 确认框打开期间排队 op 又改了项目 → 旧批准作废，重新确认。
      if (_switchTargetChanged(approvedAt)) return false;
      return _newProjectNow(
        name: name,
        device: device,
        templateId: templateId,
        empty: empty,
      );
    });
  }

  Future<bool> _newProjectNow({
    String name = 'untitled',
    String device = 'mobile',
    String? templateId,
    bool empty = false,
  }) async {
    final sizes = {'mobile': [390, 844], 'web': [1280, 800], 'desktop': [1440, 900]};
    final size = sizes[device] ?? sizes['mobile']!;
    final resolvedName = name.trim().isEmpty ? 'untitled' : name.trim();
    // 移动端没有文件选择器：新项目在应用文档目录先分配默认保存路径，
    // 聊天面的「保存」与切项目前的「保存并切换」才有落点。
    final defaultPath = await _mobileProjectPath(resolvedName);
    _invalidateAcpSession(); // 新项目 → 新工作区 → ACP 会话重建
    try {
      if (empty) {
        hasProject = true;
        projectName = resolvedName;
        projectPath = defaultPath;
        password = '';
        _projectLocked = false;
        canvasPreviewDegraded = false;
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
        // 聊天流驱动的建项目（sendChat 新 brief）与嵌入宿主内建项目不跳
        // 视图——聊天流是主面，切走就拆宿主（review pip-1）。
        if (!_keepChatView) view = 'design';
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
      // 往返期间有 run 启动（入口门之后的小竞态窗口）：此刻换项目
      // 会把 run 的终态 canonical 提交进新项目——放弃交换（apply
      // 对空 mbt 无需回滚）。
      if (agentBusy) {
        _toastWarn('NoN 正在工作，等这一轮结束再新建项目。');
        return false;
      }
      if (res['ok'] != true) {
        _toastError('新建失败，请重试', res['error']);
        return false;
      }
      hasProject = true;
      projectName = resolvedName;
      projectPath = defaultPath;
      password = '';
      _projectLocked = false;
      canvasPreviewDegraded = false;
      dirty = true;
      lastSavedAt = null;
      docs = Docs();
      activeBoard = (res['entry'] ?? 'home').toString();
      selectedNode = null;
      if (!_keepChatView) view = 'design'; // 同空分支：聊天流/嵌入宿主不跳视图
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
      _toastSuccess('项目已创建：$projectName');
      return true;
    } catch (e) {
      _toastError('新建失败，请重试', e);
      return false;
    }
  }

  /// 移动端新项目的默认保存路径（应用文档目录，首个空闲文件名）。
  ///
  /// 桌面返回 null：保留原生「另存为」对话框的既有语义。文件名非法字符
  /// 会被替换，重名追加序号，绝不覆盖已有项目。
  Future<String?> _mobileProjectPath(String name) async {
    if (kIsWeb || !(Platform.isIOS || Platform.isAndroid)) return null;
    try {
      final dir = await projects.defaultDirectory();
      final safe = _safeFileName(name);
      var candidate = File('${dir.path}/$safe.ddp');
      var n = 2;
      while (await candidate.exists()) {
        candidate = File('${dir.path}/$safe-$n.ddp');
        n += 1;
      }
      return candidate.path;
    } catch (e) {
      debugPrint('[store] default project path unavailable: $e');
      return null;
    }
  }

  static String _safeFileName(String name) {
    final cleaned = name
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '-')
        .replaceAll(RegExp(r'^\.+'), '')
        .trim();
    final base = cleaned.isEmpty ? 'project-${DateTime.now().millisecondsSinceEpoch}' : cleaned;
    return base.length > 60 ? base.substring(0, 60) : base;
  }

  Future<OpenResult> openProjectPath(String path, {String password = ''}) async {
    // agentBusy 门（core-1）：与 newProject 同根——run 在飞时切项目，
    // 在飞 run 的终态 canonical 会覆盖刚打开的项目。
    if (agentBusy) {
      _toastWarn('NoN 正在工作，等这一轮结束再打开项目。');
      return OpenResult.failed;
    }
    // 未保存改动门（nav-2）：作品集直达、左栏/Welcome 最近项目、命令面板、
    // ⌘O 全部落到这里。取消即中止（cancelled 不是 failed，调用方不该报错）。
    if (!await _confirmProjectSwitch('打开项目')) return OpenResult.cancelled;
    final approvedAt = _editGeneration;
    // 同 op 队列串行：旧项目在飞 op 先提交，打开的整篇 _commit 后落。
    return _chainOp(() async {
      if (_switchTargetChanged(approvedAt)) return OpenResult.cancelled;
      return _openProjectPathNow(path, password: password);
    });
  }

  Future<OpenResult> _openProjectPathNow(String path, {String password = ''}) async {
    _invalidateAcpSession(); // 切项目 → 外部智能体会话重建
    try {
      // Project files live on the client: the local library opens them, and a
      // connected desktop is only asked when the file is not here.
      final res = api == null
          ? <String, dynamic>{'ok': false, 'error': 'project_store_unavailable'}
          : await api!.openProject(path, password: password);
      if (res['need_password'] == true) return OpenResult.needPassword;
      if (res['ok'] != true) {
        _toastError(failureMessage(res['error']), res['error']);
        return OpenResult.failed;
      }
      final openedMbt = (res['mbt'] ?? '').toString();
      Map<String, dynamic>? renderedJson;
      if (engineReady) {
        final rendered = await api!.render(openedMbt);
        if (rendered['ok'] == true) {
          renderedJson = rendered;
        } else {
          _toastWarn('项目已打开，画布预览暂时不可用', rendered['error']);
        }
      }
      // 没有本地运行时（手机离线）或预览失败：画布空不代表项目空，界面
      // 需要显示「画布需要连接桌面后才能预览」（审查 depython-1）。
      final degraded = renderedJson == null;
      // 往返期间有 run 启动：放弃交换（open 只读解密，无副作用可弃），
      // 避免在飞 run 的终态 canonical 覆盖新项目。
      if (agentBusy) {
        _toastWarn('NoN 正在工作，等这一轮结束再打开项目。');
        return OpenResult.failed;
      }
      hasProject = true;
      projectPath = (res['path'] ?? path).toString();
      projectName = _baseName(projectPath!);
      this.password = password;
      // 成功打开受口令保护的容器 ⇒ 这个项目是加锁的：之后没有口令就拒绝
      // 保存（否则 DDP1 会被静默改写成无加密 DDP2）。
      _projectLocked = password.isNotEmpty;
      _switchApprovedGeneration = -1;
      canvasPreviewDegraded = degraded;
      restoreInks(openedMbt);
      dirty = false;
      lastSavedAt = DateTime.now().millisecondsSinceEpoch;
      docs = Docs.fromJson(res['docs']);
      selectedNode = null;
      // 嵌入宿主/聊天流里打开项目只换内容，不换路由（review pip-1：
      // 「最近项目」点一下就把聊天宿主拆成全屏设计视图，触屏回不来）。
      if (!_keepChatView) view = 'design';
      panel = 'project';
      rightTab = 'agent';
      // 上一项目 run 的流式/思考残留不进新项目面板（timeline 是否同清属
      // 「轨迹全局唯一时间线」语义拍板，本轮不动）。
      streamText = '';
      thinkingText = '';
      history = [];
      if (renderedJson != null) {
        _commit(renderedJson, recordHistory: false, markDirty: false);
      } else {
        mbt = openedMbt;
        render = RenderEnvelope.empty();
        history = [openedMbt];
        historyIndex = 0;
      }
      dirty = false;
      await _remember(projectPath!, projectName);
      await _clearRecovery();
      if (!engineReady) {
        // 项目打开了，但画布没法在这里渲染：不能报「已打开」成功而把空画布
        // 留在界面上冒充空项目（审查 depython-1）。
        _toastWarn('项目已打开，画布需要连接桌面后才能预览');
      } else if (renderedJson != null) {
        _toastSuccess('项目已打开：$projectName');
      }
      return OpenResult.opened;
    } catch (e) {
      _toastError('打开失败，请检查文件是否完整', e);
      return OpenResult.failed;
    }
  }

  Future<OpenResult> pickAndOpenProject({String password = ''}) async {
    const group = XTypeGroup(label: 'NoNDesign 项目', extensions: ['ddp']);
    final file = await openFile(acceptedTypeGroups: const [group]);
    if (file == null) return OpenResult.cancelled;
    return openProjectPath(file.path, password: password);
  }

  /// 确保加锁项目在保存前拿到口令；返回 false 表示不能写盘。
  ///
  /// 走 [passwordPrompt]（根壳注入口令对话框）；没有出口时拒绝保存——
  /// 宁可这次不存，也不把受保护的正文写成无加密容器。目标文件本身是
  /// DDP1（旧版明文快照恢复后没有 locked 标记）也要拦下。
  Future<bool> _ensureSavePassword(String? target) async {
    if (password.isNotEmpty) return true;
    if (!_projectLocked && !await _pathNeedsPassword(target)) return true;
    _projectLocked = true;
    final ask = passwordPrompt;
    if (ask == null) {
      _toastWarn('这个项目有口令保护，需要输入口令后才能保存');
      return false;
    }
    final entered = await ask(target);
    if (entered == null || entered.isEmpty) {
      _toastWarn('没有输入口令，这次改动还没有保存');
      return false;
    }
    password = entered;
    return true;
  }

  /// Saves the project as one `.ddp` file through the client-side library.
  ///
  /// Deliberately independent of the engine: a failed engine start must not
  /// cost the user their work.
  Future<bool> saveProject({String? path}) async {
    if (!hasProject) return false;
    var target = path ?? projectPath;
    if (target == null) {
      // 移动端没有文件选择器：先落到应用文档目录的默认路径。
      target = await _mobileProjectPath(projectName);
    }
    if (target == null) {
      // 没有原生文件选择器的宿主（或移动端默认路径分配失败）：给一条
      // 人话失败提示，别让异常从保存入口逸出（聊天面的保存按钮）。
      try {
        final location = await getSaveLocation(
          suggestedName: '${projectName.isEmpty ? 'untitled' : projectName}.ddp',
          acceptedTypeGroups: const [XTypeGroup(label: 'NoNDesign 项目', extensions: ['ddp'])],
        );
        if (location == null) return false;
        target = location.path;
      } catch (e) {
        _toastError('保存失败，请重试', e);
        return false;
      }
    }
    // 口令门（sec-recovery-password-downgrade）：打开过 DDP1 的项目在内存里
    // 没有口令时（崩溃恢复后）保存，会让 encrypt 走空口令分支写出无加密
    // DDP2——静默降级。缺口令时先问用户，问不到就不写。
    if (!await _ensureSavePassword(target)) return false;
    try {
      final res = api == null
          ? <String, dynamic>{'ok': false, 'error': 'project_store_unavailable'}
          : await api!.saveProject(
              mbt: mbtWithInk,
              path: target,
              password: password,
              docs: docs.toJson(),
            );
      if (res['ok'] != true) {
        _toastError('保存失败，请重试', res['error']);
        return false;
      }
      projectPath = (res['path'] ?? target).toString();
      projectName = _baseName(projectPath!);
      if (password.isNotEmpty) _projectLocked = true;
      dirty = false;
      lastSavedAt = DateTime.now().millisecondsSinceEpoch;
      await _remember(projectPath!, projectName);
      await _clearRecovery();
      _toastSuccess('已保存：$projectName');
      notifyListeners();
      return true;
    } catch (e) {
      _toastError('保存失败，请重试', e);
      return false;
    }
  }

  Future<bool> exportHtml() async {
    if (!_requireEngine()) return false;
    try {
      final res = await api!.exportHtml(mbt);
      if (res['ok'] != true || res['html'] is! String) {
        _toastError('导出失败，请重试', res['error']);
        return false;
      }
      final location = await getSaveLocation(
        suggestedName: '$projectName.html',
        acceptedTypeGroups: const [XTypeGroup(label: 'HTML', extensions: ['html'])],
      );
      if (location == null) return false;
      await File(location.path).writeAsString(res['html'] as String);
      _toastSuccess('已导出 HTML 原型');
      return true;
    } catch (e) {
      _toastError('导出失败，请重试', e);
      return false;
    }
  }

  /// 导出 Figma 包：桌面端落盘后返回目录，不弹保存框。
  Future<bool> exportFigma() async {
    try {
      final res = await api?.exportFigma(mbt) ?? {'ok': false, 'error': 'remote_unavailable'};
      if (res['ok'] != true || res['dir'] is! String) {
        if (res['error'] == 'remote_unavailable') {
          _toastWarn('导出 Figma 包需要先连接桌面');
        } else {
          _toastError('导出 Figma 包失败，请重试', res['error']);
        }
        return false;
      }
      final boards = res['boards'];
      _toastSuccess('已导出 Figma 包（${boards is num ? boards : '?'} 个画板）');
      return true;
    } catch (e) {
      _toastError('导出 Figma 包失败，请重试', e);
      return false;
    }
  }

  Future<bool> exportSvg() async {
    if (!_requireEngine() || activeBoard == null) return false;
    try {
      final res = await api!.session(mbt, 'session_export_svg', activeBoard);
      final data = res['data'];
      if (data is! Map || data['svg'] is! String) {
        _toastError('导出失败，请重试', res['error']);
        return false;
      }
      final location = await getSaveLocation(
        suggestedName: '$projectName-$activeBoard.svg',
        acceptedTypeGroups: const [XTypeGroup(label: 'SVG', extensions: ['svg'])],
      );
      if (location == null) return false;
      await File(location.path).writeAsString(data['svg'] as String);
      _toastSuccess('已导出 SVG');
      return true;
    } catch (e) {
      _toastError('导出失败，请重试', e);
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
    if (!engineReady) return {'ok': false, 'error': 'engine_unavailable'};
    try {
      final res = await api!.apply(mbt, op, gate: 'agent');
      if (res['ok'] != true) return res;
      _commit(res);
      return res;
    } catch (e) {
      return {'ok': false, 'error': 'engine_gate_failed:$e'};
    }
  }

  /// 整屏生成统一入口（dart 循环 generate_page 工具的写路径）：与
  /// [applyAgentOp] 同一条 _opQueue 链——链内读到的 `mbt` 才是新鲜的
  /// （上一条 op 已 _commit）。生成信封只带 canonical（无 render 面），
  /// 所以立即走渲染面并 [_commit]：**store.mbt 必须与循环 ctx.mbt
  /// 锁步**，否则后续 design_op 会以陈旧 canonical 为基底提交、把生成/
  /// 清扫的成果覆盖回去。render 失败也采纳 canonical（mbt + dirty），
  /// 画面等下一次渲染恢复——生成成果绝不丢。
  Future<Map<String, dynamic>> applyGeneratePage(
          String intent, String name, Map<String, dynamic> spec) =>
      _chainOp(() => _applyGeneratePageNow(intent, name, spec));

  Future<Map<String, dynamic>> _applyGeneratePageNow(
      String intent, String name, Map<String, dynamic> spec) async {
    if (!engineReady) return {'ok': false, 'error': 'engine_unavailable'};
    try {
      final res = await api!.generate(mbt, intent, name, spec);
      if (res['ok'] != true) return res;
      await _adoptCanonical(res);
      return res;
    } catch (e) {
      return {'ok': false, 'error': 'engine_generate_failed:$e'};
    }
  }

  /// 宿主侧 session 变更统一入口（dart 循环收尾桥段：RSI `session_auto_fix`
  /// 与空板清扫 `session_apply_agent` 的 delete-artboard）。同为 SESSION_MUTATING
  /// 面，同样必须走 _opQueue + canonical 采纳（与 [applyGeneratePage] 同一
  /// 锁步理由——清扫删掉的板不能被后续陈旧提交复活）。
  Future<Map<String, dynamic>> applySessionMutation(String name, String? arg) =>
      _chainOp(() => _applySessionMutationNow(name, arg));

  Future<Map<String, dynamic>> _applySessionMutationNow(String name, String? arg) async {
    if (!engineReady) return {'ok': false, 'error': 'engine_unavailable'};
    try {
      final res = await api!.session(mbt, name, arg);
      if (res['ok'] != true) return res;
      await _adoptCanonical(res);
      return res;
    } catch (e) {
      return {'ok': false, 'error': 'engine_session_failed:$e'};
    }
  }

  /// 变更信封（只带 canonical、无 render 面）的采纳：render 成功 → [_commit]
  /// （history/render/activeBoard/dirty 全链）；render 失败 → 直接落 canonical
  /// + dirty（不丢变更，画面待下次渲染）。只读信封（无 mbt）是 no-op。
  Future<void> _adoptCanonical(Map<String, dynamic> env) async {
    final canonical = env['mbt'];
    if (canonical is! String || canonical.isEmpty) return;
    Map<String, dynamic> rendered;
    try {
      rendered = api == null ? const {} : await api!.render(canonical);
    } catch (_) {
      rendered = const {};
    }
    if (rendered['ok'] == true) {
      _commit(rendered);
    } else {
      mbt = canonical;
      dirty = true;
      notifyListeners();
    }
  }

  Future<bool> _applyOpNow(String op, {bool silent = false}) async {
    if (agentBusy) {
      _toastWarn('NoN 正在工作，等这一轮结束再改画布。');
      return false;
    }
    if (!engineReady) {
      if (!silent) _requireEngine();
      return false;
    }
    try {
      final res = await api!.apply(mbt, op);
      if (res['ok'] != true) {
        if (!silent) _toastWarn(failureMessage(res['error']), res['error']);
        return false;
      }
      return _commit(res);
    } catch (e) {
      if (!silent) _toastError(failureMessage(e), e);
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
      // 嵌入宿主内建板留在聊天宿主（画板条「＋ 新建」在浮窗里同样可达）。
      if (!_keepChatView) view = 'design';
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
    _toastSuccess('已复制，${modCombo('⌘V')} 粘贴到画布');
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
    if (!engineReady || activeBoard == null) return false;
    try {
      final res = await api!.session(mbt, 'session_auto_fix', activeBoard);
      if (res['ok'] != true) {
        _toastWarn(failureMessage(res['error']), res['error']);
        return false;
      }
      return _commit(res);
    } catch (e) {
      _toastError('自动整理没有完成，请重试', e);
      return false;
    }
  }

  Future<Map<String, dynamic>?> critique() async {
    if (!engineReady || activeBoard == null) return null;
    final res = await api!.session(mbt, 'session_critique', activeBoard);
    final data = res['data'];
    if (data is Map) return Map<String, dynamic>.from(data);
    return res;
  }

  /// Token/color usage extracted from a board (session_extract_design_system):
  /// {summary, color_tokens[], components[]}.
  Future<Map<String, dynamic>?> extractDesignSystem(String ab) async {
    if (!engineReady) return null;
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
    if (agentBusy) {
      _toastWarn('NoN 正在工作，等这一轮结束再改画布。');
      return false;
    }
    if (!engineReady) {
      _requireEngine();
      return false;
    }
    try {
      final res = await api!.render(text);
      if (res['ok'] != true) {
        _toastWarn(failureMessage(res['error']), res['error']);
        return false;
      }
      return _commit(res);
    } catch (e) {
      _toastError('设计服务暂时不可用，请稍后重试', e);
      return false;
    }
  }

  /// deepDesign designFromEngine 对齐：build 终态且规范仍为默认时，
  /// 从入口画板提取真实配色落进规范——流程闭环「生成即得规范」。
  Future<void> _autoDesignFromEngine() async {
    if (!engineReady || !hasProject || !designIsDefault) return;
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
    if (!engineReady) return null;
    final res = await api!.session(mbt, 'session_infer_missing', ab);
    final data = res['data'];
    if (data is Map) return Map<String, dynamic>.from(data);
    return res;
  }

  /// Page-type classifier (session_infer_page_type): {page_type, signals}.
  Future<Map<String, dynamic>?> inferPageType(String ab) async {
    if (!engineReady) return null;
    final res = await api!.session(mbt, 'session_infer_page_type', ab);
    final data = res['data'];
    if (data is Map) return Map<String, dynamic>.from(data);
    return res;
  }

  /// Layout intent via session_constrain, e.g. 居中 / 等间距 /
  /// 网格 3. The success envelope carries canonical mbt without the render face,
  /// so we re-render before committing (same guard shape as the agent done path).
  /// 与 applyOp/autoFix 同队列串行（core-2）：与在飞 op 的 HTTP 往返交错
  /// 会以陈旧 mbt 为基底提交——队列注释宣称的不变量对所有变更入口成立。
  Future<bool> constrainLayout(String intent) => _chainOp(() => _constrainLayoutNow(intent));

  Future<bool> _constrainLayoutNow(String intent) async {
    if (agentBusy) {
      _toastWarn('NoN 正在工作，等这一轮结束再改画布。');
      return false;
    }
    if (!engineReady) {
      _requireEngine();
      return false;
    }
    final ab = activeBoard;
    if (ab == null) return false;
    try {
      final res = await api!.constrainIntent(mbt, ab, intent);
      if (res['ok'] != true) {
        _toastWarn('布局没有生效，换个说法试试', res['error']);
        return false;
      }
      final canonical = res['mbt']?.toString() ?? '';
      final rendered = canonical.isNotEmpty ? await api!.render(canonical) : null;
      if (rendered == null || rendered['ok'] != true) {
        _toastWarn('布局没有生效，请重试', rendered?['error'] ?? 'render_failed');
        return false;
      }
      return _commit(rendered);
    } catch (e) {
      _toastError('布局没有生效，请重试', e);
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
    if (agentBusy) return {'ok': false, 'error': 'agent_busy'};
    if (!engineReady) return {'ok': false, 'error': 'engine_unavailable'};
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
    if (!engineReady || agentBusy || index < 0 || index >= history.length) return;
    final target = history[index];
    final res = await api!.render(target);
    if (res['ok'] != true) {
      _toastWarn('无法切换到该版本', res['error']);
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
      _toastWarn('手机上不能使用外部智能体，请使用内置智能体');
      return false;
    }
    if (agentBusy) {
      _toastWarn('NoN 正在工作，等这一轮结束再发送。');
      return false;
    }
    if (!capabilities.isUsable(CapabilityId.externalAgent)) {
      _toastWarn(capabilities.message(CapabilityId.externalAgent));
      return false;
    }
    if (api == null) {
      _toastWarn('外部智能体暂时不可用，请稍后重试');
      return false;
    }
    final agentId = settings.acpAgentId;
    if (agentId == null || agentId.isEmpty) {
      _toastWarn('还没有选择外部智能体，请在设置里选择');
      return false;
    }
    // 轨迹用用户选中的显示名，不把内部目录 id（claude-code/qwen/…）写进
    // 用户文案（审查 copy-2）。显示名缺失时退到无标识句子。
    final agentLabel = (settings.acpAgentName ?? '').trim();
    runId = DateTime.now().microsecondsSinceEpoch % 0x7fffffff;
    agentBusy = true;
    agentPhase = 'external';
    agentError = null;
    agentUserMessage = null;
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
      TimelineEntry(
        kind: 'phase',
        text: agentLabel.isEmpty ? '外部智能体正在工作' : '外部智能体 · $agentLabel',
      ),
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
                timeline[i].ms = (ev['ms'] is num) ? (ev['ms'] as num).toInt() : null;
                timeline[i].preview = ev['preview']?.toString();
                timeline[i].error = ev['error']?.toString();
                timeline[i].message = ev['message']?.toString();
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
          ? TimelineEntry.finish(true, '外部智能体完成', agentLabel.isEmpty ? null : agentLabel)
          : TimelineEntry.finish(false, '外部智能体异常结束', failureMessage(agentError)));
    } catch (e) {
      agentError = e.toString();
      _flushDelta();
      _flushThinking();
      timeline.add(TimelineEntry.finish(false, '外部智能体连接失败', failureMessage(e)));
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
      _toastWarn('先配置模型，在设置里填入密钥');
      return false;
    }
    if (!hasProject) {
      final name = brief.replaceAll(RegExp(r'[^\p{L}\p{N}\s]', unicode: true), '').trim();
      await newProject(name: name.length > 18 ? name.substring(0, 18) : (name.isEmpty ? 'untitled' : name), empty: true);
    }
    final planned = await runPlan(brief);
    if (!planned || docs.prd.trim().isEmpty) {
      _toastWarn('文档还没有写完，继续补全或先调整画布');
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
      _toast('正在停止…');
      return;
    }
    // 停止请求超时/网络异常不得从按钮回调逸出为未处理异步异常；取消
    // 失败也要让用户知道下一步动作。
    try {
      await api?.cancelAgent(runId!);
      _toast('正在停止，当前这一步结束后生效');
    } catch (e) {
      _toastWarn('停止请求没有生效，可以等这一轮自己结束', e);
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
  /// 连接桌面的 RPC 运行时。
  Future<bool> sendChat(String text) async {
    final brief = text.trim();
    if (brief.isEmpty) return false;
    if (agentBusy) {
      _toastWarn('NoN 正在工作，等这一轮结束再发送。');
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
        if (!ok) card.detail ??= agentUserMessage ?? failureMessage(agentError);
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
            // 失败行显示服务层的人话；原始码只进时间线的折叠详情。
            if (s.ok == false && event['message'] is String) {
              s.detail = event['message'].toString();
            }
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
      case 'review_round':
        card.steps.add(ChatStep(
          label: '质量审查 第${event['round']}轮',
          detail: (event['detail'] ?? '').toString(),
        ));
      case 'cleanup':
        final removed = event['removed'];
        card.steps.add(ChatStep(
          label: removed is List && removed.isNotEmpty
              ? '清理 ${removed.length} 块空画板'
              : '清理空画板',
        ));
      case 'failed':
        final message = event['message'];
        card.detail = message is String && message.isNotEmpty
            ? message
            : failureMessage(event['error']);
    }
  }

  /// A2UI 交互卡动作回流（plan §2「确认表单/参数选择 → 回流续跑」）：
  /// 动作摘要作为用户消息入列并自动续跑一轮。agentBusy 时只提示——
  /// 动作不丢（卡片还在流里），可稍后重发。
  Future<void> handleChatAction(String name, Map<String, dynamic> context) async {
    if (agentBusy) {
      _toastWarn('NoN 正在工作，等这一轮结束再操作。');
      return;
    }
    // 用户气泡只放人话（「选择：X」）；结构化上下文只进本轮运行指令——
    // 此前把 jsonEncode(context) 与会话内部标签一起拼进气泡，并且随
    // chat.json 落盘（审查 a2ui-action-summary-json）。
    final label = name.trim().isEmpty ? '这个选项' : name.trim();
    final summary = '选择：$label';
    appendChat(ChatMessage.user(summary));
    unawaited(_persistChat());
    final instruction = context.isEmpty ? summary : '$summary\n${jsonEncode(context)}';
    await _runChatTurn(instruction);
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
  /// 写链串行 + 原子替换——append/clear 与在飞写交错、以及写到一半进程被
  /// 杀的撕裂文件都不会留下半截 JSON（recovery.json 同一治理）。
  Future<void> _persistChat() async {
    try {
      final payload = jsonEncode({
        'v': 1,
        'ts': DateTime.now().millisecondsSinceEpoch,
        'messages': [for (final m in chatMessages) m.toJson()],
      });
      final write = _chatWriteQueue.then((_) async {
        await Directory(recoveryDir).create(recursive: true);
        await _writeStringAtomic(File('$recoveryDir/chat.json'), payload);
      });
      _chatWriteQueue = write.then<void>((_) {}, onError: (Object _) {});
      await write;
    } catch (e) {
      debugPrint('[store] chat history write failed: $e');
      if (!_chatWriteWarned) {
        _chatWriteWarned = true;
        _toastWarn('聊天记录没有写进本地存储，请检查磁盘空间');
      }
    }
  }

  /// 重启恢复聊天记录。在跑的进度卡随进程死亡降级为失败卡（诚实呈现，
  /// 不伪装成仍在运行）。
  Future<void> _loadChat() async {
    final file = File('$recoveryDir/chat.json');
    try {
      if (!await file.exists()) return;
      final text = await file.readAsString();
      Map<String, dynamic>? raw;
      try {
        final decoded = jsonDecode(text);
        if (decoded is Map) raw = Map<String, dynamic>.from(decoded);
      } catch (_) {
        raw = null;
      }
      final list = raw?['messages'];
      if (list is! List) {
        if (raw == null) {
          await _quarantineBroken(file);
          _notifyBrokenStateOnce('上次的聊天记录损坏，已保留一份副本');
        }
        return;
      }
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
    } catch (e) {
      debugPrint('[store] chat history unreadable: $e');
      _notifyBrokenStateOnce('上次的聊天记录没有读出来，不影响当前使用');
    }
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
  /// 同提交语义 + AgentGate（绝不绕过引擎门）。
  /// 事件与 server SSE 同形，复用 [_handleAgentEvent] 的时间线/文档/preview 管线。
  Future<bool> _runDartLoop(String mode, String instruction) async {
    if (agentBusy) return false;
    if (settings.apiKey.trim().isEmpty) {
      _toastWarn('先配置模型，内置智能体需要密钥或连接桌面');
      return false;
    }
    final selected = model;
    if (selected != null && !selected.toolCall) {
      _toastWarn('这个模型不支持智能体操作，换一个模型试试');
      return false;
    }
    if (selected != null && selected.protocol != 'openai') {
      _toastWarn('这个模型服务暂不支持，请换一个模型');
      return false;
    }
    var base = settings.baseUrl.trim();
    if (base.isEmpty) base = selected?.baseUrl.trim() ?? '';
    if (base.isEmpty) base = _builtInBaseUrls[settings.providerId] ?? _builtInBaseUrls['openai']!;
    if (settings.baseUrl.trim().isEmpty) {
      settings.baseUrl = base; // 空端点曾让 OpenAIProvider 发到空 baseUrl 静默失败
      unawaited(saveSettings());
      _toast('已恢复默认的模型服务地址', base);
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
    agentUserMessage = null;
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
            ? '理解需求，撰写产品文档'
            : mode == 'refine'
                ? '定位改动，保持设计系统'
                : '规划页面并落画布',
      ),
    ];
    // 聊天流驱动的 run 与嵌入宿主内发起的 run 不跳视图（聊天流是主面；
    // 进工作区是显式动作——openWorkspace）。rightTab 只按 chatActive 收，
    // 嵌入面板里 run 起来时右栏切到 Agent 是可观察的目标态。
    if (!chatActive) {
      rightTab = 'agent';
    }
    if (!_keepChatView) {
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
        bridge: engineReady ? _StoreEngineGate(this) : null,
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
        _toastSuccess('文档已生成');
      } else if (!orphaned && !success && agentError == 'doc_not_written') {
        _toastWarn('这次没有生成文档，请重试或换个模型');
      }
    } catch (e) {
      agentError = e.toString();
      timeline.add(TimelineEntry.finish(false, '运行失败', failureMessage(e)));
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

  /// Dispatches one agent run.
  ///
  /// Runtime routing (see `models.dart` `agentRuntime`):
  ///  * local (default) → the built-in loop (`core/dart_agent.dart`). PLAN and
  ///    Refine are pure local; BUILD/Refine canvas writes go through the engine
  ///    bridge, so the design gate always applies.
  ///  * `server` → the connected desktop's `agent.run` stream. An explicitly
  ///    requested runtime never silently degrades: no desktop means a visible
  ///    failure, not a quiet local rerun.
  Future<bool> _runAgent(String mode, String instruction) async {
    if (agentBusy) return false;
    final localRuntime = settings.agentRuntime != agentRuntimeServer;
    if (localRuntime && mode == 'build' && !engineReady) {
      _toastWarn('构建原型需要设计服务，请先连接桌面或稍后重试');
      return false;
    }
    if (localRuntime) {
      return _runDartLoop(mode, instruction);
    }
    if (!hasConnectedDesktop) {
      _toastWarn('还没有连接桌面，无法使用这个运行时');
      capabilities.setConnectedDesktop(
        connected: false,
        message: '还没有连接桌面',
        technicalDetail: remoteStatus.technicalDetail,
      );
      return false;
    }
    if (settings.apiKey.trim().isEmpty) {
      _toastWarn('先配置模型，在设置里填入密钥');
      return false;
    }
    final selected = model;
    if (selected == null) {
      _toastWarn('找不到这个模型，请在设置里重新选择');
      return false;
    }
    if (!selected.toolCall) {
      _toastWarn('这个模型不支持智能体操作，换一个模型试试');
      return false;
    }
    if (selected.protocol != 'openai') {
      _toastWarn('这个模型服务暂不支持，请换一个模型');
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
    agentUserMessage = null;
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
    // 同 _runDartLoop：聊天流驱动/嵌入宿主内的 run 不跳视图。
    if (!chatActive) {
      rightTab = 'agent';
    }
    if (!_keepChatView) {
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
      await for (final event in (api ?? NoNDesignApi.runtime()).agentRun(body)) {
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
        timeline.add(TimelineEntry.finish(false, 'NoN 异常结束', failureMessage(agentError)));
        _toastError('NoN 异常结束，已提交的部分已保留', agentError);
      }
    } catch (e) {
      agentError = e.toString();
      timeline.add(TimelineEntry.finish(false, '运行失败', failureMessage(e)));
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
            item.message = event['message']?.toString();
            break;
          }
        }
        break;
      case 'a2ui':
        // Real producer path: the agent's ask_user tool emits a v1.0 surface,
        // and the chat stream renders it. Actions flow back through
        // handleChatAction → a new turn (no test-only construction).
        final messages = event['messages'];
        if (messages is List && messages.isNotEmpty) {
          appendChat(ChatMessage.a2ui(
            List<Object?>.from(messages),
            text: (event['text'] ?? '').toString(),
          ));
          unawaited(_persistChat());
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
      case 'review_round':
        _flushStreamAsAssistant();
        timeline.add(TimelineEntry.note(
          '质量审查 · 第${event['round']}轮',
          (event['detail'] ?? '').toString(),
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
          // canonical）——同 canonical 免一次 700ms 后的重复渲染；
          // server 路径 run 中 store.mbt 不前进，preview 恒新，照常调度。
          if (incoming == mbt) break;
          _previewMbt = incoming;
          _previewTimer ??= Timer(const Duration(milliseconds: 700), () async {
            _previewTimer = null;
            final target = _previewMbt;
            _previewMbt = null;
            if (target == null || !engineReady) return;
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
          timeline.add(TimelineEntry.note('清理空画板', '已移除 ${removed.length} 块空画板'));
        }
        break;
      case 'failed':
        agentError = (event['error'] ?? 'failed').toString();
        final userMessage = event['message'];
        if (userMessage is String && userMessage.isNotEmpty) agentUserMessage = userMessage;
        final partial = event['mbt_b64']?.toString();
        if (partial != null && partial.isNotEmpty && engineReady) {
          final partialMbt = utf8.decode(base64Decode(partial));
          final res = await api!.render(partialMbt);
          if (res['ok'] == true) {
            _commit(res);
          } else {
            // 渲染失败也不丢已提交的 canonical：落 mbt + dirty，finally 的
            // _persistRecovery 会把它写进 recovery.json，重启后可恢复。
            mbt = partialMbt;
            dirty = true;
            _toastWarn('画布预览生成失败，文字内容已保留', res['error']);
          }
        }
        if (event['docs'] is Map) docs = Docs.fromJson(event['docs']);
        timeline.add(TimelineEntry.finish(false, 'NoN 异常结束', failureMessage(agentError)));
        break;
      case 'done':
        final finalMbt = event['mbt_b64']?.toString();
        if (finalMbt != null && engineReady) {
          final decoded = utf8.decode(base64Decode(finalMbt));
          final res = await api!.render(decoded);
          if (res['ok'] == true) {
            _commit(res);
          } else {
            // 同 failed 路径：最后一次渲染失败不能吞掉整轮提交，
            // 采纳 decoded canonical，等下一次渲染或保存恢复画面。
            mbt = decoded;
            dirty = true;
            _toastWarn('画布预览生成失败，文字内容已保留', res['error']);
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
    final file = File('$recoveryDir/recovery.json');
    try {
      if (!await file.exists()) return;
      final text = await file.readAsString();
      Map<String, dynamic>? parsed;
      try {
        final raw = jsonDecode(text);
        // 明文快照（有 mbt）或受口令保护的快照（locked + enc）。
        if (raw is Map &&
            (raw['mbt'] is String ||
                (raw['locked'] == true && raw['enc'] is String))) {
          parsed = Map<String, dynamic>.from(raw);
        }
      } catch (_) {
        parsed = null;
      }
      if (parsed == null) {
        // 撕裂/半截/形状不对：保留 .bad 副本并让用户知道，不静默丢快照
        // （审查 sec-recovery-chat-writes-not-atomic）。
        await _quarantineBroken(file);
        _notifyBrokenStateOnce(
            '上次的进度记录损坏，已保留一份副本，当前项目不受影响');
        return;
      }
      recovery = parsed;
      notifyListeners();
    } catch (e) {
      debugPrint('[store] recovery snapshot unreadable: $e');
      _notifyBrokenStateOnce('上次的进度记录没有读出来，不影响当前使用');
    }
  }

  /// 把读不出来的记录改名保存（`.bad-<时间戳>`），留给用户/排障取证。
  Future<void> _quarantineBroken(File file) async {
    try {
      final stamp = DateTime.now().millisecondsSinceEpoch;
      await file.rename('${file.path}.bad-$stamp');
    } catch (_) {}
  }

  /// 损坏提示只发一次（启动时进度与聊天记录可能同时坏）。
  void _notifyBrokenStateOnce(String message) {
    if (_brokenStateNoticeShown) return;
    _brokenStateNoticeShown = true;
    _toastWarn(message);
  }

  /// 进度快照载荷。
  ///
  /// 受口令保护的项目整份正文用同一口令加密（`locked + enc`），明文只存在
  /// 于内存；快照同时带上演示批注墨迹，恢复后保存不会删掉原批注
  /// （审查 sec-recovery-password-downgrade / data-ink-lost-on-recovery）。
  Future<Map<String, dynamic>> _recoveryPayload() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final body = <String, dynamic>{
      'mbt': mbt,
      'docs': docs.toJson(),
      'ink': _inksJson,
      'view': view,
      'name': projectName,
      'path': projectPath,
      'ts': now,
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
    };
    if (!_projectLocked) {
      return {'v': 2, 'locked': false, ...body};
    }
    final sealed = await DdpCodec.encrypt(jsonEncode(body), password: password);
    return {
      'v': 2,
      'locked': true,
      'enc': base64Encode(sealed),
      'name': projectName,
      'path': projectPath,
      'ts': now,
    };
  }

  /// 读文件头判断已有容器是否受口令保护（读不到按当前内存状态）。
  Future<bool> _pathNeedsPassword(String? path) async {
    if (kIsWeb || path == null || path.isEmpty) return false;
    try {
      final file = File(path);
      if (!await file.exists()) return false;
      final raf = await file.open();
      try {
        final head = await raf.read(4);
        if (head.length != 4) return false;
        for (var i = 0; i < 4; i++) {
          if (head[i] != DdpCodec.magicLocked[i]) return false;
        }
        return true;
      } finally {
        await raf.close();
      }
    } catch (_) {
      return false;
    }
  }

  Future<void> _persistRecovery({bool force = false}) async {
    // 运行期间（agentBusy）即使未置 dirty 也要写：中途崩溃时文档
    //（doc_written）与画布进度（preview canonical）都靠这份快照恢复。
    // 没有项目时没有画布可存：只要 docs 有内容就落 docs-only recovery
    // （hasProject 硬门曾让无项目时的 PLAN 文档永远救不回）。
    final docsOnly = !hasProject;
    if (!force && !agentBusy) {
      if (docsOnly) {
        if (!docs.hasContent) return;
      } else if (!hasProject || !dirty) {
        return;
      }
    }
    // 受口令保护的项目：正文绝不明文落盘。没有内存口令时（保存同样会被
    // 拒绝）宁可不写快照，也不把受保护内容写进明文文件。
    if (_projectLocked && password.isEmpty) return;
    try {
      // 串行写链（core-5）：本方法被 run 起点/终态/doc_written/preview 与
      // 周期 Timer 多处 unawaited 并发调用。整个「取载荷 → 原子替换」都在
      // 链内执行——加密慢（受保护项目）也不会让后发起的写抢先落盘；两个
      // 就地写交错产生的撕裂 JSON 也整类消除。
      final write = _recoveryWriteQueue.then((_) async {
        await Directory(recoveryDir).create(recursive: true);
        final payload = await _recoveryPayload();
        await _writeStringAtomic(
            File('$recoveryDir/recovery.json'), jsonEncode(payload));
      });
      _recoveryWriteQueue = write.then<void>((_) {}, onError: (Object _) {});
      await write;
    } catch (e) {
      debugPrint('[store] recovery snapshot write failed: $e');
      if (!_recoveryWriteWarned) {
        _recoveryWriteWarned = true;
        _toastWarn('进度记录没有写进本地存储，请检查磁盘空间');
      }
    }
  }

  /// 测试锚点：直驱一份快照 + 等写链排空（应用代码走内部各调用点）。
  @visibleForTesting
  Future<void> debugPersistRecovery({bool force = false}) => _persistRecovery(force: force);

  /// 测试锚点：冷启动加载快照（应用代码在 boot 内调用）。
  @visibleForTesting
  Future<void> debugLoadRecovery() => _loadRecovery();

  @visibleForTesting
  Future<void> get recoveryWritesIdle => _recoveryWriteQueue;

  void _invalidateAcpSession() {
    final sid = _acpSessionId;
    _acpSessionId = null;
    _acpSessionAgent = null;
    _acpSessionProject = null;
    if (sid != null && hasConnectedDesktop) unawaited(api?.acpClose(sid));
  }

  Future<void> restoreRecovery() async {
    final stored = recovery;
    if (stored == null) return;

    // 受口令保护的快照：整份正文是密文，恢复前必须重新向用户索取口令
    // （审查 sec-recovery-password-downgrade）。取消即不恢复。
    var rec = stored;
    var locked = rec['locked'] == true;
    if (locked) {
      final sealed = rec['enc'];
      if (sealed is! String) {
        // 只有标记没有正文：不冒充可恢复。
        _toastWarn('这份进度需要口令才能恢复，请重新打开项目文件');
        return;
      }
      final ask = passwordPrompt;
      if (ask == null) {
        // 没有口令出口：不静默失败，也不落回明文恢复。
        _toastWarn('这份进度有口令保护，需要输入口令后才能恢复');
        return;
      }
      final entered = await ask(rec['path']?.toString());
      if (entered == null || entered.isEmpty) return; // 用户取消
      try {
        final plain = await DdpCodec.decrypt(base64Decode(sealed), password: entered);
        final decoded = jsonDecode(plain);
        if (decoded is! Map) throw const FormatException('snapshot');
        rec = Map<String, dynamic>.from(decoded);
        password = entered;
      } catch (_) {
        _toastError('口令不正确，无法恢复这份进度');
        return;
      }
    }

    try {
      // 中断运行优先用 partial canonical（构建进度），无则回落已提交 mbt。
      final run = rec['run'];
      final partial = (run is Map ? (run['partialMbt'] ?? '') : '').toString();
      var mbtValue = (rec['mbt'] ?? '').toString();
      if (partial.isNotEmpty) mbtValue = partial;

      // 没有画布运行时（手机离线/本地启动失败且未连接桌面）：正文与文档
      // 都恢复出来，画布标记为「待连接桌面」——不清空内容，也不把无画布
      // 冒充成「还没有画板的空项目」（审查 depython-1）。
      if (!engineReady) {
        final hasBody = mbtValue.trim().isNotEmpty;
        hasProject = hasBody || rec['path'] != null;
        projectName = (rec['name'] ?? projectName).toString();
        projectPath = rec['path']?.toString();
        docs = Docs.fromJson(rec['docs']);
        _projectLocked = locked || await _pathNeedsPassword(projectPath);
        _restoreInkSnapshot(rec['ink'], mbtValue);
        if (hasBody) {
          mbt = mbtValue;
          history = [mbtValue];
          historyIndex = 0;
          dirty = true;
        }
        canvasPreviewDegraded = hasProject;
        view = 'docs';
        docsTab = 'prd';
        recovery = null;
        await _clearRecovery();
        notifyListeners();
        _toastSuccess(hasProject
            ? '已恢复未保存的工作，连接桌面后可继续预览画布'
            : '已恢复未保存的文档');
        return;
      }

      var res = await api!.render(mbtValue);
      if (res['ok'] != true && partial.isNotEmpty) {
        mbtValue = (rec['mbt'] ?? '').toString(); // partial 坏掉时回落到已提交版本
        res = await api!.render(mbtValue);
      }
      if (res['ok'] != true) {
        _toastError('恢复失败，请重试', res['error']);
        return;
      }
      hasProject = true;
      projectName = (rec['name'] ?? 'recovered').toString();
      projectPath = rec['path']?.toString();
      docs = Docs.fromJson(rec['docs']);
      // 旧版明文快照没有 locked 字段：以磁盘容器头为准（DDP1 必须继续
      // 加锁，否则下一次保存会把它改写成无加密容器）。
      _projectLocked = locked || await _pathNeedsPassword(projectPath);
      _restoreInkSnapshot(rec['ink'], mbtValue);
      canvasPreviewDegraded = false;
      dirty = true;
      history = [];
      _commit(res, recordHistory: false);
      recovery = null;
      await _clearRecovery();
      if (run is Map && (run['phase'] ?? '').toString().isNotEmpty) {
        final phase = (run['phase'] ?? '').toString();
        final label = switch (phase) { 'planning' => '撰写文档', 'building' => '构建原型', 'refining' => '调整原型', _ => phase };
        _toastSuccess('已恢复中断的$label进度，文档与画布都已保留');
      } else {
        _toastSuccess('已恢复未保存的工作');
      }
    } catch (e) {
      _toastError('恢复失败，请重试', e);
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

  /// Re-reads the bundled model snapshot. Nothing goes to the network: the
  /// registry ships with the app (see `scripts/sync_models.mjs`).
  Future<void> refreshModels() async {
    try {
      final raw = await rootBundle.loadString('assets/models.json');
      final parsed = parseBundledModelsSnapshot(jsonDecode(raw));
      if (parsed == null) {
        _toastError('更新失败，请重试');
        return;
      }
      registry = parsed;
      notifyListeners();
      _toastSuccess('模型清单已更新，共 ${registry.providers.length} 个服务商');
    } catch (e) {
      _toastError('更新失败，请重试', e);
    }
  }

  /// Clears the agent conversation memory.
  ///
  /// The built-in loop keeps no cross-run memory (each run starts from the
  /// project map), so there is nothing to clear locally; a connected desktop
  /// may keep a session file and is asked to drop it.
  Future<void> clearAgentSession() async {
    if (!hasConnectedDesktop) {
      _toast('没有可清理的对话记忆');
      return;
    }
    final res = await api?.clearSession(projectPath ?? projectName) ??
        {'ok': false, 'error': 'remote_unavailable'};
    _toast(res['removed'] == true ? '对话记忆已清空' : '没有可清理的对话记忆');
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
    unawaited(engine?.dispose());
    remote?.close();
    super.dispose();
  }
}

/// Build/Refine 循环的引擎桥（store 锚定，docs/plan-dart-agent-migration.md
/// P1 的 Build 写路径落地）。路由表：
/// - 变更（design_op 唯一去路）：[AppStore.applyAgentOp]——applyOp 同一条
///   _opQueue 队列 + 同一个 _commit 采纳 + AgentGate
///   （AgentGate，绝不绕过引擎门、绝不降级 human 门）。入参 mbt 刻意不用：
///   链内读 store.mbt 才是新鲜的（run 在飞时 agentBusy 挡住其余写者，
///   loop ctx.mbt 与 store.mbt 锁步）。
/// - 检视：只读 session 面（query_nodes / interactions / states / lint /
///   critique / spec / export_svg / flows / list_artboards）。
/// - 整屏生成（P1）：[AppStore.applyGeneratePage]——链内读新鲜 mbt，
///   整屏生成后 render + commit（store.mbt 与循环 ctx.mbt 锁步）。
/// - 宿主侧 session 变更（P1）：[AppStore.applySessionMutation]——RSI
///   `session_auto_fix` 与空板清扫 `session_apply_agent` 同链采纳 canonical。
/// - 注册表：templates / components。
/// read_docs 不经引擎（旧参考实现同构：docs 在 run 请求载荷里，循环本地读）。
class _StoreEngineGate implements EngineGateBridge, EngineWriteBridge {
  final AppStore store;
  _StoreEngineGate(this.store);

  @override
  Future<Map<String, dynamic>> applyAgent(String mbt, String op) => store.applyAgentOp(op);

  static Map<String, dynamic> get _engineMissing => {'ok': false, 'error': 'engine_unavailable'};

  @override
  Future<Map<String, dynamic>> session(String mbt, String name, [String? arg]) =>
      store.api?.session(mbt, name, arg) ?? Future.value(_engineMissing);

  /// 整屏生成：入参 mbt 刻意不用（同 [applyAgent]）——链内读 store.mbt 才是
  /// 新鲜的；render + commit 由 store 侧完成。
  @override
  Future<Map<String, dynamic>> generate(
          String mbt, String intent, String name, Map<String, dynamic> spec) =>
      store.applyGeneratePage(intent, name, spec);

  /// RSI auto_fix / 空板清扫：session 变更同链采纳 canonical。
  @override
  Future<Map<String, dynamic>> mutateSession(String mbt, String name, [String? arg]) =>
      store.applySessionMutation(name, arg);

  @override
  Future<List<dynamic>> templates() async => await store.api?.templates() ?? const <dynamic>[];

  @override
  Future<List<dynamic>> components() async => await store.api?.components() ?? const <dynamic>[];
}
