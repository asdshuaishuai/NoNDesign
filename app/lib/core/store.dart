import 'dart:async';
import 'keys.dart';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart' hide Flow;
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'models.dart';

final GlobalKey<ScaffoldMessengerState> rootMessengerKey = GlobalKey<ScaffoldMessengerState>();

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
  String thinkingText = '';
  Map<String, dynamic> usage = const {};
  String? agentError;

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
  Timer? _previewTimer;
  String? _previewMbt;
  Timer? _recoveryTimer;

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
    try {
      _server = await ServerLauncher.launch();
      api = NoNDesignApi(_server!.baseUrl);
      final modelsRaw = await api!.models();
      final snapshot = modelsRaw['snapshot'];
      if (snapshot is Map) {
        registry = ModelRegistry.fromJson(Map<String, dynamic>.from(snapshot));
      }
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString('nondesign.settings');
      if (stored != null) {
        try {
          settings = AppSettings.fromJson(Map<String, dynamic>.from(jsonDecode(stored) as Map));
        } catch (_) {}
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
      bootError = e.toString();
      ready = false;
      notifyListeners();
    }
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
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('nondesign.settings', jsonEncode(settings.toJson()));
    notifyListeners();
  }

  void setView(String value) {
    view = value;
    notifyListeners();
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
    messenger.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        width: 360,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            if (detail != null && detail.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(detail, style: const TextStyle(fontSize: 11, color: Colors.white70)),
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
  }) async {
    if (api == null) return false;
    final sizes = {'mobile': [390, 844], 'web': [1280, 800], 'desktop': [1440, 900]};
    final size = sizes[device] ?? sizes['mobile']!;
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
        view = 'design';
        panel = 'project';
        rightTab = 'agent';
        agentBusy = false;
        agentPhase = 'idle';
        timeline = [];
        notifyListeners();
        return true;
      }
      final op = templateId != null ? 'template $templateId home' : 'create home ${size[0]} ${size[1]}';
      final res = await api!.apply('', op);
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
      view = 'design';
      panel = 'project';
      rightTab = 'agent';
      agentBusy = false;
      agentPhase = 'idle';
      timeline = [];
      history = [];
      _commit(res);
      _toast('项目已创建', '$projectName · ${size[0]}×${size[1]}');
      return true;
    } catch (e) {
      _toast('新建失败', e.toString());
      return false;
    }
  }

  Future<OpenResult> openProjectPath(String path, {String password = ''}) async {
    if (api == null) return OpenResult.failed;
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
      hasProject = true;
      projectPath = (res['path'] ?? path).toString();
      projectName = _baseName(projectPath!);
      this.password = password;
      dirty = false;
      lastSavedAt = DateTime.now().millisecondsSinceEpoch;
      docs = Docs.fromJson(res['docs']);
      selectedNode = null;
      view = 'design';
      panel = 'project';
      rightTab = 'agent';
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
        mbt: mbt,
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

  Future<bool> applyOp(String op, {bool silent = false}) async {
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

  Future<bool> autoFix() async {
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
  Future<bool> constrainLayout(String intent) async {
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
    if (agentBusy || historyIndex <= 0) return;
    _jumpHistory(historyIndex - 1);
  }

  void redo() {
    if (agentBusy || historyIndex >= history.length - 1) return;
    _jumpHistory(historyIndex + 1);
  }

  Future<void> jumpHistory(int index) => _jumpHistory(index);

  /// Engine-side version control (session_history). `command` is the
  /// sub-command expression: `init <board>`, `commit`, `log`, `undo`, `redo`,
  /// `diff <from> <to>`. Returns the engine envelope for panel display —
  /// nothing commits automatically except undo/redo jumps, whose canonical
  /// mbt is re-rendered and committed when present.
  Future<Map<String, dynamic>> engineHistory(String command) async {
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

  Future<void> _jumpHistory(int index) async {
    if (api == null || index < 0 || index >= history.length) return;
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
    await api?.cancelAgent(runId!);
    _toast('正在停止', '当前这一步结束后生效。');
  }

  Future<bool> _runAgent(String mode, String instruction) async {
    if (api == null || agentBusy) return false;
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
    runId = DateTime.now().microsecondsSinceEpoch % 0x7fffffff;
    agentBusy = true;
    agentPhase = mode == 'plan' ? 'planning' : mode == 'refine' ? 'refining' : 'building';
    agentError = null;
    streamText = '';
    thinkingText = '';
    _deltaBuffer = '';
    _thinkingBuffer = '';
    usage = const {};
    timeline = [
      TimelineEntry.user(instruction),
      TimelineEntry(kind: 'phase', text: mode == 'plan' ? '理解 brief，撰写产品文档' : mode == 'refine' ? '定位改动，保持设计系统' : '规划页面并生成原型'),
    ];
    rightTab = 'agent';
    if (mode == 'plan') view = 'docs';
    if (mode != 'plan') view = 'design';
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
    try {
      await for (final event in api!.agentRun(body)) {
        await _handleAgentEvent(event);
        if (event['type'] == 'done') success = true;
      }
      // 终态兜底：服务端进程崩溃/被杀时 socket 正常关闭、await for 无异常
      // 返回——没有 done 也没有 failed 事件。此时合成失败终态卡 + toast，
      // 并把悬挂的 running 工具条目收尾，避免时间线无声结束。
      if (!success && agentError == null) {
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
      _flushDelta();
      _flushThinking();
      agentBusy = false;
      agentPhase = 'idle';
      runId = null;
      previewRender = null;
      notifyListeners();
      await _persistRecovery();
    }
    return success;
  }

  Future<void> _handleAgentEvent(Map<String, dynamic> event) async {
    final type = (event['type'] ?? '').toString();
    switch (type) {
      case 'note':
        timeline.add(TimelineEntry.note((event['label'] ?? '').toString(), (event['detail'] ?? '').toString()));
        break;
      case 'tool_start':
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
          timeline.add(TimelineEntry.assistant((event['text'] ?? '').toString()));
        }
        break;
      case 'thinking_delta':
        _thinkingBuffer += (event['text'] ?? '').toString();
        _thinkingTimer ??= Timer(const Duration(milliseconds: 80), () {
          _thinkingTimer = null;
          _flushThinking();
        });
        return; // 同 assistant_delta：缓冲后跳过 switch 尾部通知
      case 'doc_written':
        final kind = (event['kind'] ?? '').toString();
        final content = (event['content'] ?? '').toString();
        if (kind == 'prd') docs.prd = content;
        if (kind == 'ui') docs.ui = content;
        notifyListeners();
        break;
      case 'design_spec_written':
        docs = Docs(prd: docs.prd, ui: docs.ui, design: DesignSpec.fromJson(event['spec']));
        notifyListeners();
        break;
      case 'preview':
        final b64 = event['mbt_b64']?.toString();
        if (b64 != null) {
          _previewMbt = utf8.decode(base64Decode(b64));
          _previewTimer ??= Timer(const Duration(milliseconds: 700), () async {
            _previewTimer = null;
            final target = _previewMbt;
            _previewMbt = null;
            if (target == null || api == null) return;
            try {
              final res = await api!.render(target);
              if (res['ok'] == true && agentBusy) {
                previewRender = RenderEnvelope.fromJson(res);
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
        _toast('NoN 完成', summary.length > 120 ? summary.substring(0, 120) : summary);
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

  void _flushThinking() {
    if (_thinkingBuffer.isEmpty) return;
    thinkingText += _thinkingBuffer;
    if (thinkingText.length > 6000) thinkingText = thinkingText.substring(thinkingText.length - 6000);
    _thinkingBuffer = '';
    notifyListeners();
  }

  Future<void> _loadRecovery() async {
    try {
      final path = '${Platform.environment['HOME']}/.nondesign/recovery.json';
      final file = File(path);
      if (!await file.exists()) return;
      final raw = jsonDecode(await file.readAsString());
      if (raw is Map && raw['mbt'] is String) {
        recovery = Map<String, dynamic>.from(raw);
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> _persistRecovery() async {
    if (!hasProject || !dirty) return;
    try {
      final dir = '${Platform.environment['HOME']}/.nondesign';
      await Directory(dir).create(recursive: true);
      await File('$dir/recovery.json').writeAsString(jsonEncode({
        'mbt': mbt,
        'docs': docs.toJson(),
        'name': projectName,
        'path': projectPath,
        'ts': DateTime.now().millisecondsSinceEpoch,
      }));
    } catch (_) {}
  }

  Future<void> restoreRecovery() async {
    final rec = recovery;
    if (rec == null || api == null) return;
    try {
      final mbtValue = rec['mbt'].toString();
      final res = await api!.render(mbtValue);
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
      _toast('已恢复未保存的工作');
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
    try {
      await File('${Platform.environment['HOME']}/.nondesign/recovery.json').delete();
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
    _previewTimer?.cancel();
    _recoveryTimer?.cancel();
    _server?.dispose();
    super.dispose();
  }
}
