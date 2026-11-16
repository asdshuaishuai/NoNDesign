import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/store.dart';
import '../core/theme.dart';
import 'a2ui_workspace.dart';
import 'common.dart';

/// 作品集（横切收藏夹）：聚合 a2ui 小应用 / 视频渲染 / 3D 场景三类产物，
/// 网格卡片 + 类型过滤 + 打开/移除。历史产物自动补扫（存量 mp4/3D 场景
/// 首次进入即可见）。
class PortfolioView extends StatefulWidget {
  const PortfolioView({super.key});

  @override
  State<PortfolioView> createState() => _PortfolioViewState();
}

const _kindLabel = {'a2ui': '小应用', 'video': '视频', 'three': '3D'};
const _kindIcon = {
  'a2ui': Icons.auto_fix_high_outlined,
  'video': Icons.movie_outlined,
  'three': Icons.view_in_ar_outlined,
};

class _PortfolioViewState extends State<PortfolioView> {
  List<Map<String, dynamic>> _items = [];
  String _filter = 'all';
  bool _busy = false;

  AppStore get store => context.read<AppStore>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final api = store.api;
    if (api == null) return;
    setState(() => _busy = true);
    try {
      final res = await api.portfolio();
      if (res['ok'] == true && mounted) {
        setState(() => _items = ((res['items'] as List?) ?? []).cast<Map<String, dynamic>>());
      }
    } catch (_) {
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove(Map<String, dynamic> item) async {
    final api = store.api;
    if (api == null) return;
    try {
      await api.portfolioDelete(item['kind'] as String, item['ref'] as String);
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('移除失败：$e')));
      }
    }
  }

  void _open(Map<String, dynamic> item) {
    final api = store.api;
    final kind = item['kind'] as String?;
    if (api == null) return;
    if (kind == 'a2ui') {
      a2uiLoadOnOpen = item['ref'] as String?;
      store.setView('plugin:a2ui');
    } else if (kind == 'video') {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('视频产物：${item['path']}')));
    } else if (kind == 'three') {
      store.setView('plugin:three');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('3D 场景：${item['ref']}（工作台同名续接）')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final kinds = ['all', ..._items.map((i) => i['kind'] as String).toSet()];
    final shown = _filter == 'all' ? _items : _items.where((i) => i['kind'] == _filter).toList();
    return Column(
      children: [
        Container(
          height: 46,
          decoration: BoxDecoration(color: p.bgElevated, border: Border(bottom: BorderSide(color: p.line))),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(children: [
            Icon(Icons.collections_bookmark_outlined, size: 17, color: p.accent),
            const SizedBox(width: 8),
            Text('作品集', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: p.ink)),
            const SizedBox(width: 8),
            for (final k in kinds)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: InkWell(
                  onTap: () => setState(() => _filter = k),
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                    decoration: BoxDecoration(
                      color: _filter == k ? p.accentSoft : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: _filter == k ? p.accent : p.line),
                    ),
                    child: Text(k == 'all' ? '全部' : (_kindLabel[k] ?? k),
                        style: TextStyle(fontSize: 11, color: _filter == k ? p.accent : p.ink3)),
                  ),
                ),
              ),
            const Spacer(),
            if (_busy) SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 1.6, color: p.accent)),
            IconButton(
              tooltip: '刷新',
              onPressed: _load,
              icon: Icon(Icons.refresh, size: 17, color: p.ink3),
              visualDensity: VisualDensity.compact,
            ),
          ]),
        ),
        Expanded(
          child: shown.isEmpty
              ? Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.collections_bookmark_outlined, size: 42, color: p.ink4),
                    const SizedBox(height: 12),
                    Text('还没有作品', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: p.ink2)),
                    const SizedBox(height: 6),
                    Text('生成的小应用、视频与 3D 场景会自动收进这里',
                        style: TextStyle(fontSize: 12, color: p.ink4)),
                  ]),
                )
              : GridView.builder(
                  padding: const EdgeInsets.all(14),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 300, mainAxisSpacing: 10, crossAxisSpacing: 10, childAspectRatio: 1.5),
                  itemCount: shown.length,
                  itemBuilder: (ctx, i) {
                    final it = shown[i];
                    final kind = it['kind'] as String;
                    return Container(
                      decoration: BoxDecoration(
                        color: p.panel.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: p.line),
                      ),
                      padding: const EdgeInsets.all(12),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Icon(_kindIcon[kind] ?? Icons.help_outline, size: 15, color: p.accent),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(color: p.accentSoft, borderRadius: BorderRadius.circular(6)),
                            child: Text(_kindLabel[kind] ?? kind, style: TextStyle(fontSize: 10, color: p.accent)),
                          ),
                          const Spacer(),
                          InkWell(
                            onTap: () => _remove(it),
                            borderRadius: BorderRadius.circular(6),
                            child: Icon(Icons.delete_outline, size: 15, color: p.ink4),
                          ),
                        ]),
                        const Spacer(),
                        Text('${it['title']}', maxLines: 2, overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: p.ink)),
                        const SizedBox(height: 4),
                        Text('${it['detail']}', maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 10, color: p.ink4)),
                        const Spacer(),
                        Align(
                          alignment: Alignment.centerRight,
                          child: OutlinedButton(
                            onPressed: () => _open(it),
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                              side: BorderSide(color: p.line),
                            ),
                            child: Text('打开', style: TextStyle(fontSize: 11, color: p.ink2)),
                          ),
                        ),
                      ]),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
