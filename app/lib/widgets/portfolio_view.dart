import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/api_shelf.dart';
import '../core/store.dart';
import '../core/theme.dart';
import 'art_shelf_card.dart';
import 'common.dart';
import 'hotapp_workspace.dart';
import 'three_workspace.dart';
import 'video_workspace.dart';

/// 艺术架（Art Shelf）：作品集的货架形态。
///
/// 数据源仍是横切收藏夹（/portfolio 聚合 hotapp/video/three + 存量补扫），
/// 另加一类**原型项目**（DDP：store.serverProjects + recent + 当前项目）——
/// 「生成物都在架子上」是艺术架与旧作品集网格的核心差别。
///
/// 布局：固定分类签（全部/热应用/原型/视频/3D）+ 每个非空分类一行横向货架
/// （大卡 260×176）。分类签固定不进动态拼装：空分类也要在架子上可见，
/// 否则用户无法知道「视频这一类存在但现在没有」。
///
/// 打开契约（四类产物各自直达，不再有只弹 SnackBar 的分支）：
/// - hotapp   → hotAppLoadOnOpen（应用**名**）+ plugin:hotapp
/// - prototype→ store.openProjectPath（needPassword 弹一次口令框重试）
/// - video    → videoLoadOnOpen（mp4 绝对路径）+ plugin:video（真播放）
/// - three    → threeLoadOnOpen（项目名）+ plugin:three
class PortfolioView extends StatefulWidget {
  const PortfolioView({super.key});

  @override
  State<PortfolioView> createState() => _PortfolioViewState();
}

/// 固定分类签（顺序即展示顺序）。'prototype' 不是服务端 portfolio kind——
/// 它是客户端聚合的 DDP 项目类目。
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
  /// 服务端作品集条目（/portfolio）。
  List<Map<String, dynamic>> _apiItems = [];

  /// 客户端聚合的原型项目（DDP）。
  List<Map<String, dynamic>> _prototypes = [];
  String? _error;
  bool _busy = false;
  String _filter = 'all';

  AppStore get store => context.read<AppStore>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  /// 全量刷新：先对账项目发现（store.serverProjects 是原型段的数据源；store 的
  /// notifyListeners 不会重建本视图——context.read 不订阅，所以必须在 await
  /// 之后自己 setState 收账），再取服务端作品集。失败一律落到 _error（旧实现
  /// 的空 catch 让「加载失败」显示成「还没有作品」）。
  Future<void> _load() async {
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
    var items = <Map<String, dynamic>>[];
    String? error;
    final api = store.api;
    if (api != null) {
      try {
        final res = await api.portfolio();
        if (res['ok'] == true) {
          items = ((res['items'] as List?) ?? const [])
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList();
        } else {
          error = '${res['detail'] ?? res['error'] ?? 'HTTP ${res['status'] ?? '?'}'}';
        }
      } catch (e) {
        error = e.toString();
      }
    }
    if (!mounted) return;
    setState(() {
      _apiItems = items;
      _prototypes = _collectPrototypes(store);
      _error = error;
      _busy = false;
    });
  }

  /// 原型项目聚合：当前项目 → 服务端发现（workspace/桌面）→ 最近项目，
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
    if (kind == 'prototype') return _prototypes;
    return _apiItems.where((i) => i['kind'] == kind).toList();
  }

  // ---- 打开 ----

  Future<void> _open(Map<String, dynamic> item) async {
    final kind = item['kind']?.toString() ?? '';
    final ref = item['ref']?.toString() ?? '';
    if (ref.isEmpty) return;
    if (kind == 'prototype') {
      if (store.api == null) {
        _toast('未连接服务器', '打开 DDP 项目需要桌面服务。');
        return;
      }
      await _openPrototype(ref);
      return;
    }
    if (store.api == null) {
      _toast('未连接服务器', '热应用 / 视频 / 3D 需要桌面服务。');
      return;
    }
    if (kind == 'hotapp') {
      // 该全局只写应用名（不是路径）：离线缓存的路径面走 nonapp 的
      // hotAppOfflinePath，两个取值域不得混用。
      hotAppLoadOnOpen = ref;
      store.setView('plugin:hotapp');
    } else if (kind == 'video') {
      // 视频产物条目 ref 就是 mp4 绝对路径（作品集补扫与 render 登记同源）。
      videoLoadOnOpen = item['path']?.toString() ?? ref;
      store.setView('plugin:video');
    } else if (kind == 'three') {
      threeLoadOnOpen = ref;
      store.setView('plugin:three');
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
      _toast('打开失败', path);
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
    _toast('已复制路径', path);
  }

  Future<void> _reveal(String path) async {
    final ok = await revealInFolder(path);
    if (!mounted) return;
    if (!ok) _toast('无法在文件夹中显示', path);
  }

  /// 从艺术架移除（语义不变）：hotapp 删源码目录（不可恢复）；video/three
  /// 只隐藏条目，产物本身不归作品集所有。
  Future<void> _remove(Map<String, dynamic> item) async {
    final api = store.api;
    if (api == null) return;
    final kind = item['kind']?.toString();
    final ref = item['ref']?.toString() ?? '';
    if (kind == null || ref.isEmpty) return;
    final title = (item['title'] ?? ref).toString();
    final deletesSource = kind == 'hotapp';
    final ok = await showNonDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ctx.palette.panel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text(deletesSource ? '删除热应用源码？' : '从艺术架移除？',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: ctx.palette.ink)),
        content: Text(
          deletesSource
              ? '将删除源码目录与 SQLite 数据库（不可恢复）：\n~/Documents/NoNDesign/hotapps/$ref'
              : '仅从艺术架隐藏，不删除产物：\n$title',
          style: TextStyle(fontSize: 13, height: 1.5, color: ctx.palette.ink2),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: deletesSource ? FilledButton.styleFrom(backgroundColor: ctx.palette.danger) : null,
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(deletesSource ? '删除' : '隐藏'),
          ),
        ],
      ),
    );
    if (!mounted || ok != true) return;
    try {
      // api 层把 4xx/5xx 归一成 {'ok': false, status, detail} 且不抛异常——
      // 只看异常会把服务端拒绝（如非法 kind）静默吞成「什么都没发生」。
      final res = await api.portfolioDelete(kind, ref);
      if (!mounted) return;
      if (res['ok'] != true) {
        _toast('移除失败', '${res['detail'] ?? res['error'] ?? 'HTTP ${res['status']}'}');
        return;
      }
      await _load();
    } catch (e) {
      if (mounted) _toast('移除失败', e.toString());
    }
  }

  /// 删除 3D 项目（真删产物，不可恢复）——服务端 /three/delete 早已实现，
  /// 客户端此前没有接线（blocked 项目的错误文案指向一条 UI 做不到的出路）。
  Future<void> _deleteThree(Map<String, dynamic> item) async {
    final api = store.api;
    final ref = item['ref']?.toString() ?? '';
    if (api == null || ref.isEmpty) return;
    final ok = await showNonDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ctx.palette.panel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text('删除 3D 项目？',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: ctx.palette.ink)),
        content: Text(
          '将删除整个项目目录（spec / scene / 证据，不可恢复）：\n~/Documents/NoNDesign/3d/$ref',
          style: TextStyle(fontSize: 13, height: 1.5, color: ctx.palette.ink2),
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
      final res = await api.threeDelete(ref);
      if (res['ok'] != true) {
        if (mounted) _toast('删除失败', '${res['detail'] ?? res['error'] ?? 'HTTP ${res['status']}'}');
        return;
      }
      // 索引残留 best-effort：目录已删，portfolio_list 的存在性校验会剔除
      // 条目；显式清理一次让 hidden/items 也归位。
      try {
        await api.portfolioDelete('three', ref);
      } catch (_) {}
      if (!mounted) return;
      // 与 3D 工作台的删除路径同语义（three_workspace.dart 的 _deleteProject）：
      // 删的若是工作台上一轮停留的项目，持久化项目名与规范草稿必须一起清——
      // 否则下次进工作台会续接一个盘上已不存在的项目（no_project 红条 +
      // 预览 400），并回灌幽灵规范草稿。
      if (store.settings.threeProjectName == ref) {
        store.setThreeProjectName('');
        store.setThreeSpecDraft(ref, null);
      }
      await _load();
      if (mounted) _toast('已删除 3D 项目', ref);
    } catch (e) {
      if (mounted) _toast('删除失败', e.toString());
    }
  }

  void _toast(String title, String detail) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        if (detail.trim().isNotEmpty)
          Text(detail.trim(), style: const TextStyle(fontSize: 11), maxLines: 2, overflow: TextOverflow.ellipsis),
      ]),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final rows = <Widget>[];
    for (final kind in _shelfKinds) {
      if (_filter != 'all' && _filter != kind) continue;
      final items = _itemsOf(kind);
      if (items.isEmpty) continue;
      rows.add(_shelfRow(p, kind, items));
    }
    return Column(
      children: [
        _header(p),
        if (_error != null) _errorBar(p),
        if (store.api == null && rows.isNotEmpty) _offlineBar(p),
        Expanded(child: rows.isEmpty ? _emptyState(p) : ListView(children: [...rows, const SizedBox(height: 18)])),
      ],
    );
  }

  /// 头部分两行（手机宽度 390/402 下五个分类签与标题同排必溢出 404px）：
  /// 第一行 44 = 返回/标题/刷新/⋯；第二行 36 = 横向滚动的固定分类签。
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
              padding: const EdgeInsets.only(left: 4),
              child: IconButton(
                icon: const Icon(Icons.arrow_back, size: 18),
                tooltip: '返回设计 ⌘1',
                color: p.ink2,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                onPressed: () => store.setView('design'),
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.collections_bookmark_outlined, size: 17, color: p.accent),
            const SizedBox(width: 8),
            Text('作品集', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: p.ink)),
            const Spacer(),
            if (_busy)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: SizedBox(
                    width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 1.6, color: p.accent)),
              ),
            IconButton(
              tooltip: '刷新',
              onPressed: _busy ? null : _load,
              icon: Icon(Icons.refresh, size: 17, color: p.ink3),
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            ),
            PopupMenuButton<String>(
              tooltip: '更多操作',
              icon: Icon(Icons.more_horiz, size: 18, color: p.ink3),
              iconSize: 18,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              color: p.panel,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10), side: BorderSide(color: p.lineStrong)),
              onSelected: (v) {
                if (v == 'refresh') _load();
              },
              itemBuilder: (ctx) => [
                PopupMenuItem<String>(
                  value: 'refresh',
                  height: 36,
                  child: Row(children: [
                    Icon(Icons.refresh, size: 16, color: p.ink3),
                    const SizedBox(width: 8),
                    const Text('刷新', style: TextStyle(fontSize: 13)),
                  ]),
                ),
              ],
            ),
          ]),
        ),
        SizedBox(
          height: 36,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
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
                              fontSize: 11,
                              fontWeight: _filter == k ? FontWeight.w600 : FontWeight.w500,
                              color: _filter == k ? p.accent : p.ink3)),
                    ),
                  ),
                ),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _errorBar(NonPalette p) => Container(
        key: const ValueKey('shelf-error'),
        width: double.infinity,
        color: p.danger.withValues(alpha: 0.12),
        padding: const EdgeInsets.fromLTRB(12, 4, 6, 4),
        child: Row(children: [
          Icon(Icons.error_outline, size: 14, color: p.danger),
          const SizedBox(width: 6),
          Expanded(
            child: Text('作品集加载失败：$_error',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: p.danger)),
          ),
          TextButton(
            onPressed: _busy ? null : _load,
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 28),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              padding: const EdgeInsets.symmetric(horizontal: 10),
            ),
            child: const Text('重试', style: TextStyle(fontSize: 11)),
          ),
        ]),
      );

  /// 离线提示条：api==null 时「连不上」必须与「没作品」区分开
  /// （旧实现直接 return，空态把两者伪装成同一件事）。
  Widget _offlineBar(NonPalette p) => Container(
        key: const ValueKey('shelf-offline'),
        width: double.infinity,
        color: p.warn.withValues(alpha: 0.10),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(children: [
          Icon(Icons.cloud_off_outlined, size: 14, color: p.warn),
          const SizedBox(width: 6),
          Expanded(
            child: Text('未连接服务器：热应用 / 视频 / 3D 需要桌面服务，原型项目仍可打开。',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: p.warn)),
          ),
        ]),
      );

  Widget _emptyState(NonPalette p) {
    final offline = store.api == null;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(offline ? Icons.cloud_off_outlined : Icons.collections_bookmark_outlined,
              size: 42, color: p.ink4),
          const SizedBox(height: 12),
          Text(offline ? '未连接服务器' : '还没有作品',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: p.ink2)),
          const SizedBox(height: 6),
          Text(
            offline
                ? '热应用 / 视频 / 3D 需要桌面服务；原型项目仍会显示在这里。'
                : '生成的热应用、视频与 3D 场景会自动收进这里',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: p.ink4),
          ),
        ]),
      ),
    );
  }

  /// 单行货架：标题 + 计数 + 横向卡片列表（行高 176 / 卡宽 260）。
  Widget _shelfRow(NonPalette p, String kind, List<Map<String, dynamic>> items) {
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            Text(shelfKindLabel[kind] ?? kind,
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: p.ink2)),
            const SizedBox(width: 6),
            Text('${items.length}', style: TextStyle(fontSize: 11, color: p.ink4)),
          ]),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 176,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
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
                  onReveal: revealSupported && path.isNotEmpty ? () => _reveal(path) : null,
                  // 原型项目不在服务端作品集里（kind 白名单只有
                  // hotapp/video/three）：给它「从艺术架移除」= 一条点了必
                  // 400 的死路，直接不提供该动作。
                  onRemove: it['kind'] == 'prototype' ? null : () => _remove(it),
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
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: p.ink)),
      content: SizedBox(
        width: 360,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('打开「${widget.name}」需要口令',
              style: TextStyle(fontSize: 13, color: p.ink2)),
          const SizedBox(height: 10),
          TextField(
            controller: _ctl,
            autofocus: true,
            obscureText: true,
            decoration: const InputDecoration(labelText: '口令'),
            style: const TextStyle(fontSize: 13),
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
