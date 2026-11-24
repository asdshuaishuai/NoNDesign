/// 3D 工作台的内容区专属面板：场景大纲 + 节点检查器 + 底部状态条。
///
/// 2026-11-24 工作台独立适配（UI-2 首批）：3D 不再只把设计画布的「源码/规范」
/// 侧栏换皮，而是有自己的**视口优先**内容布局——左侧大纲、右侧检查器、底部
/// 状态条；共享外壳（TitleBar/Rail/右 chat/StatusBar）仍由外层提供。
library;

import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';

/// 大纲条目种类（只做 layout/检查器分区，不是场景事实源）。
enum ThreeOutlinerKind { component, material, camera }

/// 一条大纲条目（从 legacy spec / v2 scene 投影出来的只读视图）。
final class ThreeOutlinerItem {
  const ThreeOutlinerItem({
    required this.id,
    required this.kind,
    required this.label,
    this.detail = '',
    this.data = const <String, Object?>{},
  });

  final String id;
  final ThreeOutlinerKind kind;

  /// 用户可读名字（优先 `what`/`view`/材质名，不把内部 id 当主文案）。
  final String label;
  final String detail;
  final Map<String, Object?> data;

  IconData get icon => switch (kind) {
    ThreeOutlinerKind.component => Icons.category_outlined,
    ThreeOutlinerKind.material => Icons.palette_outlined,
    ThreeOutlinerKind.camera => Icons.videocam_outlined,
  };
}

/// 从 3D legacy spec 投影出大纲条目（components/materials/camera）。
///
/// 这不是第二事实源：只用于 3D 工作台的大纲/检查器读取；v2 scene.json 的
/// 节点投影在后续 scene 模式适配时接同一模型。坏项跳过，不炸整份大纲。
List<ThreeOutlinerItem> threeOutlinerItemsFromSpec(Map<String, dynamic>? spec) {
  if (spec == null) return const <ThreeOutlinerItem>[];
  final List<ThreeOutlinerItem> items = <ThreeOutlinerItem>[];
  final Object? components = spec['components'];
  if (components is List) {
    for (final Object? item in components) {
      if (item is! Map) continue;
      final String id = (item['id'] ?? '').toString().trim();
      if (id.isEmpty) continue;
      items.add(
        ThreeOutlinerItem(
          id: 'component:$id',
          kind: ThreeOutlinerKind.component,
          label: (item['what'] ?? id).toString(),
          detail: id,
          data: Map<String, Object?>.from(item),
        ),
      );
    }
  }
  final Object? materials = spec['materials'];
  if (materials is List) {
    for (final Object? item in materials) {
      if (item is! Map) continue;
      final String id = (item['id'] ?? '').toString().trim();
      if (id.isEmpty) continue;
      final String color = (item['color_hex'] ?? '').toString();
      items.add(
        ThreeOutlinerItem(
          id: 'material:$id',
          kind: ThreeOutlinerKind.material,
          label: id,
          detail: color,
          data: Map<String, Object?>.from(item),
        ),
      );
    }
  }
  final Object? camera = spec['camera'];
  if (camera is Map && camera.isNotEmpty) {
    items.add(
      ThreeOutlinerItem(
        id: 'camera',
        kind: ThreeOutlinerKind.camera,
        label: (camera['view'] ?? '作者相机').toString(),
        detail: '相机',
        data: Map<String, Object?>.from(camera),
      ),
    );
  }
  return items;
}

/// 左侧场景大纲（3D 专属；可折叠由外层布局决定）。
class ThreeOutlinerPanel extends StatelessWidget {
  const ThreeOutlinerPanel({
    super.key,
    required this.items,
    this.selectedId,
    required this.onSelect,
  });

  final List<ThreeOutlinerItem> items;
  final String? selectedId;
  final ValueChanged<ThreeOutlinerItem> onSelect;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      key: const ValueKey('three-workbench-outliner'),
      color: p.bgElevated.withValues(alpha: 0.9),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 10, 8),
            child: Row(
              children: <Widget>[
                Icon(Icons.account_tree_outlined, size: 13, color: p.ink4),
                const SizedBox(width: 6),
                Text(
                  '场景大纲',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: p.ink,
                  ),
                ),
                const Spacer(),
                Text(
                  '${items.length}',
                  style: TextStyle(fontSize: 10, color: p.ink4),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: p.line),
          Expanded(
            child: items.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        '还没有场景内容\n先让 NaN 生成规格/场景',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 11,
                          height: 1.5,
                          color: p.ink4,
                        ),
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(
                      vertical: 6,
                      horizontal: 6,
                    ),
                    itemCount: items.length,
                    itemBuilder: (context, index) {
                      final item = items[index];
                      final active = item.id == selectedId;
                      return InkWell(
                        key: ValueKey('three-outliner-${item.id}'),
                        borderRadius: BorderRadius.circular(7),
                        onTap: () => onSelect(item),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 7,
                          ),
                          child: Row(
                            children: <Widget>[
                              Icon(
                                item.icon,
                                size: 13,
                                color: active ? p.accent : p.ink4,
                              ),
                              const SizedBox(width: 7),
                              Expanded(
                                child: Text(
                                  item.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: active ? p.ink : p.ink2,
                                    fontWeight: active
                                        ? FontWeight.w600
                                        : FontWeight.w400,
                                  ),
                                ),
                              ),
                              if (item.detail.isNotEmpty)
                                Text(
                                  item.detail,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 9,
                                    fontFamily: 'Menlo',
                                    color: p.ink4,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// 右侧节点检查器（3D 专属；与设计检查器/视频镜头检查器分开）。
class ThreeNodeInspector extends StatelessWidget {
  const ThreeNodeInspector({
    super.key,
    this.item,
    this.sceneChars = 0,
    this.currentPass = '',
  });

  final ThreeOutlinerItem? item;
  final int sceneChars;
  final String currentPass;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final item = this.item;
    return Container(
      key: const ValueKey('three-workbench-inspector'),
      color: p.panel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 10, 8),
            child: Row(
              children: <Widget>[
                Icon(Icons.tune, size: 13, color: p.ink4),
                const SizedBox(width: 6),
                Text(
                  '检查器',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: p.ink,
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: p.line),
          if (item == null)
            _InspectorEmpty(
              p: p,
              sceneChars: sceneChars,
              currentPass: currentPass,
            )
          else
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      item.label,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: p.ink,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(switch (item.kind) {
                      ThreeOutlinerKind.component => '组件',
                      ThreeOutlinerKind.material => '材质',
                      ThreeOutlinerKind.camera => '相机',
                    }, style: TextStyle(fontSize: 10, color: p.ink4)),
                    const SizedBox(height: 10),
                    for (final entry in item.data.entries)
                      if (entry.key != 'what' && entry.key != 'id')
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              SizedBox(
                                width: 78,
                                child: Text(
                                  entry.key.toString(),
                                  style: TextStyle(fontSize: 10, color: p.ink4),
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  '${entry.value}',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: p.ink2,
                                    height: 1.35,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                    const SizedBox(height: 8),
                    Text(
                      '属性编辑在 3D 视口/受控 patch 批次接入；本检查器当前只读。',
                      style: TextStyle(
                        fontSize: 10,
                        height: 1.45,
                        color: p.ink4,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _InspectorEmpty extends StatelessWidget {
  const _InspectorEmpty({
    required this.p,
    required this.sceneChars,
    required this.currentPass,
  });

  final NonPalette p;
  final int sceneChars;
  final String currentPass;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '场景概览',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: p.ink,
              ),
            ),
            const SizedBox(height: 10),
            _kv(p, '当前层', currentPass.isEmpty ? '—' : currentPass),
            _kv(p, '场景代码', '$sceneChars 字符'),
            const SizedBox(height: 8),
            Text(
              '在左侧大纲选择组件/材质/相机查看只读属性。',
              style: TextStyle(fontSize: 10, height: 1.45, color: p.ink4),
            ),
          ],
        ),
      ),
    );
  }

  Widget _kv(NonPalette p, String key, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(
      children: <Widget>[
        SizedBox(
          width: 78,
          child: Text(key, style: TextStyle(fontSize: 10, color: p.ink4)),
        ),
        Expanded(
          child: Text(value, style: TextStyle(fontSize: 11, color: p.ink2)),
        ),
      ],
    ),
  );
}

/// 3D 内容区底部状态条（不是共享外壳的 StatusBar）。
class ThreeWorkbenchStatusBar extends StatelessWidget {
  const ThreeWorkbenchStatusBar({
    super.key,
    required this.currentPass,
    required this.blocked,
    required this.attempts,
    this.gateVerdict,
  });

  final String currentPass;
  final bool blocked;
  final int attempts;
  final String? gateVerdict;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      key: const ValueKey('three-workbench-status'),
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: p.bgElevated,
        border: Border(top: BorderSide(color: p.line)),
      ),
      child: Row(
        children: <Widget>[
          Icon(
            blocked ? Icons.error_outline : Icons.view_in_ar_outlined,
            size: 12,
            color: blocked ? p.warn : p.ink4,
          ),
          const SizedBox(width: 6),
          Text(
            blocked
                ? '已阻塞 · $currentPass'
                : '当前层 · ${currentPass.isEmpty ? '—' : currentPass}',
            style: TextStyle(fontSize: 11, color: blocked ? p.warn : p.ink3),
          ),
          const SizedBox(width: 12),
          Text('尝试 $attempts', style: TextStyle(fontSize: 10, color: p.ink4)),
          const Spacer(),
          if (gateVerdict != null)
            Text(
              '门 · $gateVerdict',
              style: TextStyle(
                fontSize: 10,
                color: gateVerdict == 'ERROR' ? p.warn : p.ink4,
              ),
            ),
        ],
      ),
    );
  }
}
