import 'package:flutter/material.dart';

import '../core/theme.dart';

/// 艺术架卡片：单个产物（热应用 / 原型 / 视频 / 3D）的一张大卡。
///
/// 视觉与前一代网格卡片同源（panel 底 + line 边 + 类型徽标），但动作面
/// 升级为「一键打开」：整卡可点（onOpen）+ 右下显式「打开」按钮；右上 ⋯
/// 收纳低频动作（复制路径 / 在文件夹中显示 / 从艺术架移除 / 删除 3D 项目）。
/// 卡片本身不自带尺寸——货架行统一给 260×176，别在卡内写死宽高。
class ArtShelfCard extends StatelessWidget {
  const ArtShelfCard({
    super.key,
    required this.item,
    required this.onOpen,
    required this.onCopyPath,
    this.onRemove,
    this.onReveal,
    this.onDelete3d,
  });

  /// 作品集条目（kind/ref/title/detail/path；hotapp 可能带 renderer）。
  final Map<String, dynamic> item;
  final VoidCallback onOpen;
  final VoidCallback onCopyPath;

  /// 「从艺术架移除」：null = 该 entry 不由服务端作品集拥有（原型项目是
  /// 客户端聚合的发现结果）——菜单项整个不出现，别让用户点一条必失败的出路。
  final VoidCallback? onRemove;

  /// 「在文件夹中显示」：null = 平台不支持（移动端）——菜单项整个不出现。
  final VoidCallback? onReveal;

  /// three 专用「删除 3D 项目…」（真删产物，二次确认在调用方）。
  final VoidCallback? onDelete3d;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final kind = item['kind']?.toString() ?? '';
    final kindLabel = shelfKindLabel[kind] ?? kind;
    final title = '${item['title'] ?? item['ref'] ?? ''}';
    final detail = '${item['detail'] ?? item['path'] ?? ''}';
    // A2UI 是热应用的一个渲染后端（双后端并存），不是第四类产物：
    // 只在热应用卡上贴第二枚徽标，货架分类签仍是「热应用」。
    final a2ui = kind == 'hotapp' && item['renderer'] == 'a2ui';
    return Container(
      decoration: BoxDecoration(
        color: p.panel.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.line),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onOpen,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(shelfKindIcon[kind] ?? Icons.help_outline, size: 15, color: p.accent),
                const SizedBox(width: 6),
                _Badge(label: kindLabel),
                if (a2ui) ...[
                  const SizedBox(width: 5),
                  _Badge(label: 'A2UI', accent2: true),
                ],
                const Spacer(),
                _menu(context, p),
              ]),
              const SizedBox(height: 6),
              Text(title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: p.ink, height: 1.25)),
              const SizedBox(height: 4),
              Text(detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10, color: p.ink4)),
              const Spacer(),
              Align(
                alignment: Alignment.centerRight,
                child: OutlinedButton(
                  onPressed: onOpen,
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    minimumSize: const Size(0, 30),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    side: BorderSide(color: p.line),
                  ),
                  child: Text('打开', style: TextStyle(fontSize: 11, color: p.ink2)),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _menu(BuildContext context, NonPalette p) {
    return PopupMenuButton<String>(
      tooltip: '更多操作',
      padding: EdgeInsets.zero,
      iconSize: 16,
      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
      icon: Icon(Icons.more_horiz, size: 16, color: p.ink4),
      color: p.panel,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10), side: BorderSide(color: p.lineStrong)),
      onSelected: (v) {
        switch (v) {
          case 'copy':
            onCopyPath();
          case 'reveal':
            onReveal?.call();
          case 'remove':
            onRemove?.call();
          case 'delete3d':
            onDelete3d?.call();
        }
      },
      itemBuilder: (ctx) => [
        _item(ctx, 'copy', Icons.copy_all_outlined, '复制路径'),
        if (onReveal != null) _item(ctx, 'reveal', Icons.folder_open_outlined, '在文件夹中显示'),
        // 原型项目没有服务端作品集条目（kind 白名单只有 hotapp/video/three）：
        // 对它们显示「移除」= 一条点了必失败、还会被服务端 400 静默吞掉的出路。
        if (onRemove != null) _item(ctx, 'remove', Icons.hide_source_outlined, '从艺术架移除'),
        if (onDelete3d != null) ...[
          const PopupMenuDivider(),
          _item(ctx, 'delete3d', Icons.delete_outline, '删除 3D 项目…', danger: true),
        ],
      ],
    );
  }

  PopupMenuItem<String> _item(BuildContext context, String value, IconData icon, String label,
      {bool danger = false}) {
    final p = context.palette;
    final color = danger ? p.danger : p.ink3;
    return PopupMenuItem<String>(
      value: value,
      height: 36,
      child: Row(children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 8),
        Text(label, style: TextStyle(fontSize: 13, color: danger ? color : null)),
      ]),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, this.accent2 = false});
  final String label;
  final bool accent2;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final color = accent2 ? p.accent2 : p.accent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: accent2 ? color.withValues(alpha: 0.16) : p.accentSoft,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label, style: TextStyle(fontSize: 10, color: color)),
    );
  }
}

/// 货架分类签的标签/图标表（艺术架视图与卡片共用一处定义）。
const shelfKindLabel = {'hotapp': '热应用', 'prototype': '原型', 'video': '视频', 'three': '3D'};
const shelfKindIcon = {
  'hotapp': Icons.auto_fix_high_outlined,
  'prototype': Icons.dashboard_customize_outlined,
  'video': Icons.movie_outlined,
  'three': Icons.view_in_ar_outlined,
};
