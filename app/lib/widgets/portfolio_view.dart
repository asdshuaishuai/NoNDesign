/// 艺术架（Art Shelf）：作品集的货架形态（批次 07：全本地扫描）。
///
/// 数据源（全部在本机，不需要任何连接）：
///   · 热应用 —— `NonAppLibrary` 扫描 `<项目目录>/hotapps/*`；
///   · 原型   —— 本地项目库（当前项目 + 发现结果 + 最近项目去重）；
///   · 3D     —— `ThreeService.listProjects()` 扫 `<项目目录>/3d/*`；
///   · 视频   —— `<项目目录>/videos` 下的 mp4 产物 + **3D 视频项目**（后者不是
///     在这里再扫一遍目录：它与首页作品集卡同一来源，即 `store.portfolioEntries`
///     里 kind='video3d' 的条目，由 `loadPortfolioEntries` 扫描
///     `<项目目录>/portfolio/video3d/*` 生成；这里只按类型过滤后并入「视频」
///     货架行，详情文案「3D 视频 · N 镜头 / M 帧」负责区分来源）。
///
/// 布局：固定分类签（全部/热应用/原型/视频/3D）+ 每个非空分类一行横向货架
/// （大卡 260×176）。分类签固定不进动态拼装：空分类也要在架子上可见，
/// 否则用户无法知道「视频这一类存在但现在没有」。
///
/// 打开契约（各类产物各自直达）：
/// - hotapp   → hotAppLoadOnOpen（应用名）+ plugin:hotapp
/// - prototype→ store.openProjectPath（needPassword 弹一次口令框重试）
/// - video    → videoLoadOnOpen（mp4 绝对路径）+ plugin:video
/// - video3d  → openPortfolioEntry(kind: 'video3d')（项目名一次性通道）+
///              plugin:video3d（与首页作品集卡/顶栏同一条路由）
/// - three    → threeLoadOnOpen（项目名）+ plugin:three
///
/// shelf-2 裁决：原型卡片**本地可打开**，但不提供「从艺术架移除」（它不由
/// 艺术架拥有，删项目在「最近项目」里做）——货架行末尾明示这条边界，而不是
/// 给一个点了必失败的菜单项。
library;

import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/app_paths.dart';
import '../core/embedding_index.dart';
import '../core/mediapipe_service.dart';
import '../core/nonapp_library.dart';
import '../core/portfolio_entries.dart';
import '../core/platform_capabilities.dart';
import '../core/store.dart';
import '../core/theme.dart';
import '../core/three_service.dart';
import 'art_shelf_card.dart';
import 'common.dart';
import 'workspace_open.dart';

class PortfolioView extends StatefulWidget {
  const PortfolioView({
    super.key,
    this.searchIndex,
    this.library,
    this.threeService,
    this.videoRoot,
    this.projectEntries,
  });

  /// 检索入口（生产 = 进程内共享 [EmbeddingIndex]；测试注入 fake/临时目录）。
  ///
  /// 注入 [EmbeddingIndex] 时视图会先 `sync` 已加载条目再检索；注入纯
  /// [SearchIndex] fake 时只用它检索（不建索引）——两条路径都不碰网络。
  final SearchIndex? searchIndex;

  /// 本地热应用库（测试注入临时目录；生产首次加载时打开默认库）。
  final NonAppLibrary? library;

  /// 3D 项目源（测试注入临时目录）。
  final ThreeService? threeService;

  /// 视频产物目录（测试注入；默认 `<项目目录>/videos`）。
  final Directory? videoRoot;

  /// 原型项目列表覆盖（测试/嵌入式宿主；null = 按 store 的当前项目 + 发现
  /// 结果 + 最近项目聚合）。生产不传。
  final List<Map<String, dynamic>>? projectEntries;

  @override
  State<PortfolioView> createState() => _PortfolioViewState();
}

/// 进程内共享的艺术架索引（生产路径；模型未就绪时自动退化子串匹配）。
EmbeddingIndex? _sharedShelfIndex;

EmbeddingIndex defaultShelfIndex() => _sharedShelfIndex ??= EmbeddingIndex(
      embedder: MediaPipeServiceEmbedder(MediaPipeService.shared),
    );

/// 固定分类签（顺序即展示顺序）。'prototype' 不是包类目——它是客户端聚合的
/// 本地项目类目。
const _shelfTabs = [
  ('all', '全部'),
  ('hotapp', '热应用'),
  ('prototype', '原型'),
  ('video', '视频'),
  ('three', '3D'),
];

/// 'all' 视图里各货架行的顺序（与分类签一致）。
const _shelfKinds = ['hotapp', 'prototype', 'video', 'three'];

class _PortfolioViewState extends State<PortfolioView> {
  /// 本地热应用（库扫描）。
  List<Map<String, dynamic>> _hotapps = [];

  /// 客户端聚合的原型项目（本地项目文件）。
  List<Map<String, dynamic>> _prototypes = [];

  /// 本地 3D 项目。
  List<Map<String, dynamic>> _three = [];

  /// 视频货架行：本地 mp4 产物 + 3D 视频项目（后者来自 `store.portfolioEntries`
  /// 的 kind='video3d' 条目，与首页作品集卡同一来源）。
  List<Map<String, dynamic>> _videos = [];

  String? _error;
  bool _busy = false;
  String _filter = 'all';

  /// 搜索框状态：输入防抖 180ms（每键一次向量化会把 embedder 拍死）。
  final TextEditingController _searchCtl = TextEditingController();
  Timer? _searchDebounce;
  String _query = '';

  /// 语义检索命中的条目 id（`kind:ref`）；null = 走本地子串匹配。
  Set<String>? _hitIds;

  /// 降级提示（「语义检索不可用，已按关键词匹配」）；null = 无语义/无降级。
  String? _searchNote;

  NonAppLibrary? _library;
  ThreeService? _threeService;

  AppStore get store => context.read<AppStore>();

  PlatformCapabilities get host => store.capabilities.platform;

  @override
  void initState() {
    super.initState();
    _library = widget.library;
    _threeService = widget.threeService;
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchCtl.dispose();
    super.dispose();
  }

  /// 全量刷新：项目发现（本地库 + 可选连接桌面）→ 热应用库 → 3D → 视频
  /// （mp4 产物 + 3D 视频项目）。
  ///
  /// [forcePortfolio]：手动点「刷新」时把作品集来源也强制重扫（首页作品集卡与
  /// 艺术架共用 `store.portfolioEntries`；自动刷新只在生产启动后的 store 上
  /// 开启，测试里手动构造的 store 不扫真实用户目录）。
  ///
  /// 每个来源独立 best-effort：一个目录读不到（权限/损坏）不得让其他来源
  /// 消失；只有「热应用库打不开」会作为可见错误条呈现（那是主来源）。
  Future<void> _load({bool forcePortfolio = false}) async {
    if (!mounted || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final store = this.store;
    try {
      await store.refreshProjects();
    } catch (_) {
      // refreshProjects 自身吞异常（发现是 best-effort）；这里只防御未来改动。
    }

    String? error;
    var hotapps = <Map<String, dynamic>>[];
    var three = <Map<String, dynamic>>[];
    var videos = <Map<String, dynamic>>[];
    var video3dProjects = <Map<String, dynamic>>[];

    try {
      _library ??= await NonAppLibrary.open();
      final apps = await _library!.scan();
      hotapps = [for (final app in apps) app.toShelfItem()];
    } catch (e) {
      debugPrint('[shelf] library scan failed: $e');
      error = '作品集暂时打不开，请稍后重试';
    }

    try {
      _threeService ??= await ThreeService.open();
      final projects = await _threeService!.listProjects();
      three = [
        for (final project in projects)
          {
            'kind': 'three',
            'ref': project.name,
            'title': project.name,
            'detail': project.blocked ? '这个场景还没完成' : '3D 场景',
            'path': _threeService!.projectDir(project.name).path,
          }
      ];
    } catch (e) {
      debugPrint('[shelf] three scan failed: $e');
    }

    try {
      final root = widget.videoRoot ?? Directory('${(await AppPaths.projectsRoot()).path}/videos');
      videos = _scanVideos(root);
    } catch (e) {
      debugPrint('[shelf] video scan failed: $e');
    }

    // 3D 视频项目不在这里另写一份目录扫描：首页作品集卡（`store.portfolioEntries`
    // 里 kind='video3d' 的条目）已经由 `loadPortfolioEntries` 扫过
    // `<项目目录>/portfolio/video3d/*`，艺术架只按类型过滤后并入「视频」货架行；
    // 详情文案（「3D 视频 · N 镜头 / M 帧」）负责区分来源，点击仍走
    // openPortfolioEntry 的既有 video3d 路由。
    try {
      // 自动刷新门：生产启动后（_bootCompleted=true）才允许扫真实用户目录；
      // 15 秒缓存让连续刷新不重复 IO，显式刷新按钮才 force。
      if (store.portfolioAutoRefreshEnabled) {
        await store.refreshPortfolio(force: forcePortfolio);
      }
      video3dProjects = [
        for (final entry in store.portfolioEntries)
          if (entry.kind == 'video3d')
            {
              'kind': 'video3d',
              'ref': entry.ref,
              'title': entry.title,
              'detail': entry.detail,
              'path': entry.path,
              'modified': entry.modified,
            }
      ];
    } catch (e) {
      debugPrint('[shelf] video3d scan failed: $e');
    }

    if (!mounted) return;
    setState(() {
      _hotapps = hotapps;
      _prototypes = _collectPrototypes(store);
      _three = three;
      _videos = _mergeVideoShelf(videos, video3dProjects);
      _error = error;
      _busy = false;
      _hitIds = null; // 条目重载：旧命中集可能指向已消失的条目
    });
    if (_query.trim().isNotEmpty) {
      unawaited(_runSearch(_query.trim()));
    }
  }

  /// 视频产物：目录下所有 mp4（按修改时间倒序，最多 40 条）。
  List<Map<String, dynamic>> _scanVideos(Directory root) {
    if (!root.existsSync()) return const [];
    final files = <MapEntry<File, DateTime>>[];
    for (final entity in root.listSync(recursive: true, followLinks: false)) {
      if (entity is! File || !entity.path.toLowerCase().endsWith('.mp4')) continue;
      try {
        files.add(MapEntry(entity, entity.statSync().modified));
      } catch (_) {}
    }
    files.sort((a, b) => b.value.compareTo(a.value));
    return [
      for (final entry in files.take(40))
        {
          'kind': 'video',
          'ref': entry.key.path,
          'title': entry.key.uri.pathSegments.last,
          'detail': '视频',
          'path': entry.key.path,
          'modified': entry.value.millisecondsSinceEpoch,
        }
    ];
  }

  /// 「视频」货架行合并：本地 mp4 产物 + 3D 视频项目，按修改时间倒序排列。
  ///
  /// 3D 视频项目没有 mp4 产物时同样是「视频类」作品，统一一行展示；时间读不到
  /// 的排最后，同一时间按 ref 稳定排序，避免每次刷新同一条目换位置。
  List<Map<String, dynamic>> _mergeVideoShelf(
    List<Map<String, dynamic>> products,
    List<Map<String, dynamic>> projects,
  ) {
    final merged = <Map<String, dynamic>>[...products, ...projects];
    merged.sort((a, b) {
      final byTime = _shelfModifiedMs(b).compareTo(_shelfModifiedMs(a));
      if (byTime != 0) return byTime;
      return (a['ref']?.toString() ?? '').compareTo(b['ref']?.toString() ?? '');
    });
    return merged;
  }

  static int _shelfModifiedMs(Map<String, dynamic> item) =>
      item['modified'] is num ? (item['modified'] as num).toInt() : 0;

  /// 原型项目聚合：当前项目 → 本地发现（workspace/桌面/连接桌面）→ 最近项目，
  /// 按 path 去重（先到先得，当前项目永远在最前）。
  List<Map<String, dynamic>> _collectPrototypes(AppStore store) {
    final seen = <String>{};
    final out = <Map<String, dynamic>>[];
    void add(String? path, String? name) {
      final p = path?.trim() ?? '';
      if (p.isEmpty || !seen.add(p)) return;
      final title = (name ?? '').trim().isNotEmpty ? name!.trim() : _baseName(p);
      out.add({
        'kind': 'prototype',
        'ref': p,
        'path': p,
        'title': title,
        'detail': p,
      });
    }

    final override = widget.projectEntries;
    if (override != null) {
      for (final entry in override) {
        add(entry['path']?.toString() ?? entry['ref']?.toString(), entry['name']?.toString() ?? entry['title']?.toString());
      }
      return out;
    }

    add(store.projectPath, store.projectName);
    for (final p in store.serverProjects) {
      add(p['path']?.toString(), p['name']?.toString());
    }
    for (final r in store.recent) {
      add(r['path']?.toString(), r['name']?.toString());
    }
    return out;
  }

  static String _baseName(String path) {
    final name = path.split(RegExp(r'[/\\]')).last;
    return name.endsWith('.ddp') ? name.substring(0, name.length - 4) : name;
  }

  List<Map<String, dynamic>> _itemsOf(String kind) {
    switch (kind) {
      case 'hotapp':
        return _hotapps;
      case 'prototype':
        return _prototypes;
      case 'three':
        return _three;
      case 'video':
        return _videos;
    }
    return const [];
  }

  // ---- 搜索（离线语义检索 + 关键词兜底）----

  /// 条目稳定 id：与 [EmbeddingDoc.id] 同源（`<kind>:<ref>`）。
  static String _itemKey(Map<String, dynamic> item) =>
      '${item['kind']}:${item['ref'] ?? ''}';

  /// 全架条目（不受分类签影响——搜索是全库，分类签只是展示过滤）。
  List<EmbeddingDoc> _searchDocs() {
    final docs = <EmbeddingDoc>[];
    for (final kind in _shelfKinds) {
      for (final item in _itemsOf(kind)) {
        final ref = item['ref']?.toString() ?? '';
        if (ref.isEmpty) continue;
        final title = '${item['title'] ?? ref}';
        final detail = '${item['detail'] ?? item['path'] ?? ''}';
        docs.add(EmbeddingDoc(
          id: _itemKey(item),
          kind: kind,
          title: title,
          text: detail,
          ref: ref,
        ));
      }
    }
    return docs;
  }

  SearchIndex _searchIndex() => widget.searchIndex ?? defaultShelfIndex();

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    final query = value.trim();
    setState(() {
      _query = value;
      if (query.isEmpty) {
        _hitIds = null;
        _searchNote = null;
      }
    });
    if (query.isEmpty) return;
    _searchDebounce = Timer(const Duration(milliseconds: 180), () => _runSearch(query));
  }

  /// 检索：索引可用 → 向量 topK（命中只留这些卡片）；否则 → 本地子串。
  ///
  /// 语义检索「零命中」也退回子串——topK 的余弦下限以上没有结果时，关键词
  /// 匹配比空货架更有用（用户输入的是字面词时尤其明显）。
  Future<void> _runSearch(String query) async {
    final index = _searchIndex();
    try {
      if (index is EmbeddingIndex) {
        await index.sync(_searchDocs());
      }
      final outcome = await index.search(query, topK: 50);
      if (!mounted || _query.trim() != query) return; // 过期结果（输入已变）
      setState(() {
        if (outcome.semantic && outcome.hits.isNotEmpty) {
          _hitIds = outcome.hits.map((h) => h.entry.id).toSet();
          _searchNote = null;
        } else {
          _hitIds = null;
          _searchNote = outcome.semantic ? null : (outcome.reason ?? '已按关键词匹配');
        }
      });
    } catch (e) {
      if (!mounted || _query.trim() != query) return;
      // 检索任何异常都不该让货架不可用：直接退回本地子串。
      setState(() {
        _hitIds = null;
        _searchNote = '语义检索不可用，已按关键词匹配';
      });
    }
  }

  bool _localMatch(Map<String, dynamic> item, String query) => substringMatch(query, [
        '${item['title'] ?? ''}',
        '${item['detail'] ?? ''}',
        '${item['path'] ?? ''}',
        '${item['ref'] ?? ''}',
        '${item['kind'] ?? ''}',
      ]);

  /// 分类签 + 搜索后的可见条目。
  List<Map<String, dynamic>> _visibleItems(String kind) {
    final items = _itemsOf(kind);
    final query = _query.trim();
    if (query.isEmpty) return items;
    final ids = _hitIds;
    if (ids != null) {
      return items.where((item) => ids.contains(_itemKey(item))).toList();
    }
    return items.where((item) => _localMatch(item, query)).toList();
  }

  void _clearSearch() {
    _searchDebounce?.cancel();
    _searchCtl.clear();
    setState(() {
      _query = '';
      _hitIds = null;
      _searchNote = null;
    });
  }

  // ---- 打开 ----

  Future<void> _open(Map<String, dynamic> item) async {
    final kind = item['kind']?.toString() ?? '';
    final ref = item['ref']?.toString() ?? '';
    if (ref.isEmpty) return;
    if (kind == 'prototype') {
      await _openPrototype(ref);
      return;
    }
    // 各类产物走同一个切换口（工作台跟着项目走）：3D 视频条目与首页作品集卡
    // 同一条 openPortfolioEntry 路由（video3d → 3D 视频工作台）。
    if (kind == 'hotapp' || kind == 'video' || kind == 'three' || kind == 'video3d') {
      openPortfolioEntry(
        store,
        PortfolioEntry(
          kind: kind,
          ref: ref,
          title: '${item['title'] ?? ref}',
          detail: '${item['detail'] ?? ''}',
          path: item['path']?.toString(),
        ),
      );
    }
  }

  Future<void> _openPrototype(String path) async {
    var res = await store.openProjectPath(path);
    if (!mounted) return;
    if (res == OpenResult.needPassword) {
      // 口令只问一次：取消即放弃（不循环弹框）。
      final password = await _askPassword(path);
      if (password == null || !mounted) return;
      res = await store.openProjectPath(path, password: password);
      if (!mounted) return;
    }
    if (res == OpenResult.opened) {
      store.setView('design');
    } else if (res == OpenResult.failed) {
      store.toasts.error('打开失败', '这个项目可能已经不在原来的位置了。');
    }
  }

  Future<String?> _askPassword(String path) async {
    return showNonDialog<String>(
      context: context,
      builder: (ctx) => _PasswordDialog(name: _baseName(path)),
    );
  }

  // ---- 卡片动作 ----

  Future<void> _copyPath(String path) async {
    await Clipboard.setData(ClipboardData(text: path));
    if (!mounted) return;
    store.toasts.success('已复制路径', path);
  }

  /// 在系统文件管理器中定位产物（平台矩阵是唯一判据）。
  Future<void> _reveal(String path) async {
    if (!host.supportsRevealInFolder) {
      store.toasts.warn('这台设备不支持在文件夹中显示');
      return;
    }
    try {
      if (host.os == HostOs.macos) {
        await Process.run('open', ['-R', path]);
      } else if (host.os == HostOs.windows) {
        // explorer 命中成功也常返回非 0（其退出码语义不可靠），不读 exitCode。
        await Process.run('explorer', ['/select,$path']);
      } else {
        await Process.run('xdg-open', [File(path).parent.path]);
      }
    } catch (e) {
      debugPrint('[shelf] reveal failed: $e');
      store.toasts.warn('没能打开文件夹');
    }
  }

  /// 从艺术架移除：热应用删本地应用目录（不可恢复）；3D 只提供单独的
  /// 「删除 3D 项目」动作（真删产物）。视频/原型不提供移除（产物不归艺术架
  /// 所有，删文件是文件管理器的事）。
  Future<void> _remove(Map<String, dynamic> item) async {
    final kind = item['kind']?.toString();
    final ref = item['ref']?.toString() ?? '';
    if (kind != 'hotapp' || ref.isEmpty) return;
    final title = (item['title'] ?? ref).toString();
    final ok = await showNonDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ctx.palette.panel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text('删除这个热应用？',
            style: TextStyle(fontSize: NonType.subtitle, fontWeight: FontWeight.w700, color: ctx.palette.ink)),
        content: Text(
          '会同时删除它在本机的数据，无法恢复：\n$title',
          style: TextStyle(fontSize: NonType.bodyStrong, height: 1.5, color: ctx.palette.ink2),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: ctx.palette.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (!mounted || ok != true) return;
    final library = _library;
    if (library == null) return;
    try {
      await library.delete(ref);
      if (!mounted) return;
      await _load();
      if (mounted) store.toasts.success('已删除热应用', title);
    } on Object catch (e) {
      debugPrint('[shelf] delete hotapp failed: $e');
      if (mounted) store.toasts.error('删除没有完成', '请稍后重试');
    }
  }

  /// 删除 3D 项目（真删产物，不可恢复）。
  Future<void> _deleteThree(Map<String, dynamic> item) async {
    final ref = item['ref']?.toString() ?? '';
    final service = _threeService;
    if (service == null || ref.isEmpty) return;
    final ok = await showNonDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ctx.palette.panel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text('删除这个 3D 场景？',
            style: TextStyle(fontSize: NonType.subtitle, fontWeight: FontWeight.w700, color: ctx.palette.ink)),
        content: Text(
          '会删除整个项目目录，无法恢复。',
          style: TextStyle(fontSize: NonType.bodyStrong, height: 1.5, color: ctx.palette.ink2),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: ctx.palette.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (!mounted || ok != true) return;
    try {
      await service.deleteProject(ref);
      if (!mounted) return;
      // 与 3D 工作台的删除路径同语义：删的若是工作台上一轮停留的项目，
      // 持久化项目名与规范草稿必须一起清。
      if (store.settings.threeProjectName == ref) {
        store.setThreeProjectName('');
        store.setThreeSpecDraft(ref, null);
      }
      await _load();
      if (mounted) store.toasts.success('已删除 3D 场景', ref);
    } catch (e) {
      debugPrint('[shelf] delete three failed: $e');
      if (mounted) store.toasts.error('删除没有完成', '请稍后重试');
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final rows = <Widget>[];
    for (final kind in _shelfKinds) {
      if (_filter != 'all' && _filter != kind) continue;
      final items = _visibleItems(kind);
      if (items.isEmpty) continue;
      rows.add(_shelfRow(p, kind, items));
    }
    final searching = _query.trim().isNotEmpty;
    return Column(
      children: [
        _header(p),
        if (_error != null) _errorBar(p),
        Expanded(
          child: rows.isEmpty
              ? (searching ? _noSearchResults(p) : _emptyState(p))
              : ListView(children: [...rows, const SizedBox(height: 18)]),
        ),
      ],
    );
  }

  /// 头部三行（手机宽度 390/402 下五个分类签与标题同排必溢出）：
  /// 第一行 44 = 返回/标题/刷新/⋯；第二行 36 = 横向滚动的固定分类签；
  /// 第三行 40 = 检索框（语义优先、关键词兜底），降级时附一行提示。
  Widget _header(NonPalette p) {
    return Container(
      decoration: BoxDecoration(
          color: p.bgElevated, border: Border(bottom: BorderSide(color: p.line))),
      child: Column(children: [
        SizedBox(
          height: 44,
          child: Row(children: [
            // 全屏视图的可见出口（无项目启动也能进来，必须有回头路）。
            Padding(
              padding: const EdgeInsets.only(left: NonSpace.xs),
              child: IconButton(
                icon: const Icon(Icons.arrow_back, size: 18),
                tooltip: '返回设计 ⌘1',
                color: p.ink2,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                onPressed: () => store.setView('design'),
              ),
            ),
            const SizedBox(width: NonSpace.xs),
            Icon(Icons.collections_bookmark_outlined, size: 17, color: p.accent),
            const SizedBox(width: NonSpace.sm),
            Text('作品集', style: TextStyle(fontSize: NonType.bodyStrong, fontWeight: FontWeight.w700, color: p.ink)),
            const Spacer(),
            if (_busy)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: SizedBox(
                    width: 13,
                    height: 13,
                    child: CircularProgressIndicator(strokeWidth: 1.6, color: p.accent)),
              ),
            IconButton(
              tooltip: '刷新',
              onPressed: _busy ? null : () => _load(forcePortfolio: true),
              icon: Icon(Icons.refresh, size: 17, color: p.ink3),
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            ),
          ]),
        ),
        SizedBox(
          height: 36,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: NonSpace.md),
            child: Row(children: [
              for (final (k, label) in _shelfTabs)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: InkWell(
                    onTap: () => setState(() => _filter = k),
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                      decoration: BoxDecoration(
                        color: _filter == k ? p.accentSoft : Colors.transparent,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: _filter == k ? p.accent : p.line),
                      ),
                      child: Text(label,
                          style: TextStyle(
                              fontSize: NonType.caption,
                              fontWeight: _filter == k ? FontWeight.w600 : FontWeight.w500,
                              color: _filter == k ? p.accent : p.ink3)),
                    ),
                  ),
                ),
            ]),
          ),
        ),
        _searchRow(p),
        if (_searchNote != null) _searchNoteRow(p),
      ]),
    );
  }

  /// 检索输入行：语义优先、关键词兜底（模型未就绪/无网络时同样可用）。
  Widget _searchRow(NonPalette p) {
    return SizedBox(
      height: 40,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(NonSpace.md, 0, NonSpace.md, 6),
        child: TextField(
          key: const ValueKey('shelf-search'),
          controller: _searchCtl,
          onChanged: _onSearchChanged,
          textInputAction: TextInputAction.search,
          style: TextStyle(fontSize: NonType.body, color: p.ink),
          decoration: InputDecoration(
            isDense: true,
            hintText: '搜索作品（语义 / 关键词）',
            hintStyle: TextStyle(fontSize: NonType.body, color: p.ink4),
            prefixIcon: Icon(Icons.search, size: 15, color: p.ink3),
            prefixIconConstraints: const BoxConstraints(minWidth: 30, minHeight: 30),
            suffixIcon: _query.isEmpty
                ? null
                : IconButton(
                    key: const ValueKey('shelf-search-clear'),
                    tooltip: '清除搜索',
                    icon: Icon(Icons.close, size: 14, color: p.ink3),
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                    padding: EdgeInsets.zero,
                    onPressed: _clearSearch,
                  ),
            suffixIconConstraints: const BoxConstraints(minWidth: 30, minHeight: 30),
            filled: true,
            fillColor: p.panel,
            contentPadding: const EdgeInsets.symmetric(vertical: NonSpace.sm),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: p.line),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: p.line),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: p.accent),
            ),
          ),
        ),
      ),
    );
  }

  /// 降级提示条（只在语义检索不可用时出现，避免噪音）。
  Widget _searchNoteRow(NonPalette p) => Container(
        key: const ValueKey('shelf-search-note'),
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(14, 0, NonSpace.md, NonSpace.xs),
        child: Row(children: [
          Icon(Icons.info_outline, size: 12, color: p.ink4),
          const SizedBox(width: 5),
          Expanded(
            child: Text(
              _searchNote!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: NonType.micro, color: p.ink4),
            ),
          ),
        ]),
      );

  /// 搜索无结果（与「还没有作品」区分开——用户刚输入了关键词）。
  Widget _noSearchResults(NonPalette p) => Center(
        key: const ValueKey('shelf-search-empty'),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: NonSpace.xl),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.search_off, size: 38, color: p.ink4),
            const SizedBox(height: 10),
            Text('没有匹配的作品',
                style: TextStyle(fontSize: NonType.subtitle, fontWeight: FontWeight.w600, color: p.ink2)),
            const SizedBox(height: 6),
            Text('换个关键词试试；模型未就绪时按标题/路径做关键词匹配。',
                textAlign: TextAlign.center, style: TextStyle(fontSize: NonType.body, color: p.ink4)),
          ]),
        ),
      );

  Widget _errorBar(NonPalette p) => Container(
        key: const ValueKey('shelf-error'),
        width: double.infinity,
        color: p.danger.withValues(alpha: 0.12),
        padding: const EdgeInsets.fromLTRB(NonSpace.md, NonSpace.xs, 6, NonSpace.xs),
        child: Row(children: [
          Icon(Icons.error_outline, size: 14, color: p.danger),
          const SizedBox(width: 6),
          Expanded(
            child: Text(_error!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: NonType.caption, color: p.danger)),
          ),
          TextButton(
            onPressed: _busy ? null : () => _load(forcePortfolio: true),
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 28),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              padding: const EdgeInsets.symmetric(horizontal: 10),
            ),
            child: const Text('重试', style: TextStyle(fontSize: NonType.caption)),
          ),
        ]),
      );

  Widget _emptyState(NonPalette p) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: NonSpace.xl),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.collections_bookmark_outlined, size: 42, color: p.ink4),
          const SizedBox(height: NonSpace.md),
          Text('还没有作品',
              style: TextStyle(fontSize: NonType.subtitle, fontWeight: FontWeight.w600, color: p.ink2)),
          const SizedBox(height: 6),
          Text(
            '生成的热应用、3D 场景与视频会自动收进这里。',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: NonType.body, color: p.ink4),
          ),
        ]),
      ),
    );
  }

  /// 单行货架：标题 + 计数 + 横向卡片列表（行高 176 / 卡宽 260）。
  Widget _shelfRow(NonPalette p, String kind, List<Map<String, dynamic>> items) {
    final hint = kind == 'prototype' ? '原型项目在「最近项目」里管理，不在这里删除。' : null;
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: NonSpace.lg),
          child: Row(children: [
            Text(shelfKindLabel[kind] ?? kind,
                style: TextStyle(fontSize: NonType.body, fontWeight: FontWeight.w700, color: p.ink2)),
            const SizedBox(width: 6),
            Text('${items.length}', style: TextStyle(fontSize: NonType.caption, color: p.ink4)),
            if (hint != null) ...[
              const SizedBox(width: NonSpace.sm),
              Expanded(
                child: Text(
                  hint,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: NonType.micro, color: p.ink4),
                ),
              ),
            ],
          ]),
        ),
        const SizedBox(height: NonSpace.sm),
        SizedBox(
          height: 176,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: NonSpace.lg),
            itemCount: items.length,
            separatorBuilder: (context, index) => const SizedBox(width: 10),
            itemBuilder: (ctx, i) {
              final it = items[i];
              final path = it['path']?.toString() ?? '';
              final isThree = it['kind'] == 'three';
              return SizedBox(
                width: 260,
                child: ArtShelfCard(
                  item: it,
                  onOpen: () => _open(it),
                  onCopyPath: () => _copyPath(path),
                  onReveal:
                      host.supportsRevealInFolder && path.isNotEmpty ? () => _reveal(path) : null,
                  // 只有热应用由艺术架拥有（删除 = 删本地应用与数据）。
                  // 原型/视频/3D 的移除语义不同：原型不给（行首明示），
                  // 视频文件归用户自己，3D 走单独的「删除 3D 项目」。
                  onRemove: it['kind'] == 'hotapp' ? () => _remove(it) : null,
                  onDelete3d: isThree ? () => _deleteThree(it) : null,
                ),
              );
            },
          ),
        ),
      ]),
    );
  }
}

/// 口令框：self-contained StatefulWidget，TextEditingController 随路由销毁
/// 一起释放——在调用方 await 之后再 dispose 会撞上弹窗退出动画期间的
/// rebuild，实机/测试都会抛 "used after being disposed"。
class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog({required this.name});
  final String name;

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final _ctl = TextEditingController();

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return AlertDialog(
      backgroundColor: p.panel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      title: Text('项目已加密',
          style: TextStyle(fontSize: NonType.subtitle, fontWeight: FontWeight.w700, color: p.ink)),
      content: SizedBox(
        width: 360,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('打开「${widget.name}」需要口令',
              style: TextStyle(fontSize: NonType.bodyStrong, color: p.ink2)),
          const SizedBox(height: 10),
          TextField(
            controller: _ctl,
            autofocus: true,
            obscureText: true,
            decoration: const InputDecoration(labelText: '口令'),
            style: const TextStyle(fontSize: NonType.bodyStrong),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(context, _ctl.text), child: const Text('打开')),
      ],
    );
  }
}
