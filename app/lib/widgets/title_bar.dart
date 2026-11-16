import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/keys.dart';
import '../core/store.dart';
import '../core/theme.dart';
import 'common.dart';

class TitleBar extends StatelessWidget {
  final VoidCallback onCommand;
  final VoidCallback onSettings;
  final VoidCallback onNewProject;
  final VoidCallback onOpenProject;
  final VoidCallback onShortcuts;
  /// 最近项目行按各自路径直接打开（此前所有行都落到通用打开对话框，真 bug）。
  final void Function(String path) onOpenRecent;

  const TitleBar({
    super.key,
    required this.onCommand,
    required this.onSettings,
    required this.onNewProject,
    required this.onOpenProject,
    required this.onShortcuts,
    required this.onOpenRecent,
  });

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final p = context.palette;
    final model = store.model;
    return Container(
      height: 52,
      decoration: BoxDecoration(
        color: p.bgElevated.withValues(alpha: 0.94),
        border: Border(bottom: BorderSide(color: p.line)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          const NonLogo(size: 24),
          const SizedBox(width: 8),
          PopupMenuButton<String>(
            tooltip: '项目菜单',
            offset: const Offset(0, 38),
            color: p.panel,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: p.lineStrong)),
            onSelected: (value) async {
              switch (value) {
                case 'new':
                  onNewProject();
                case 'open':
                  onOpenProject();
                case 'save':
                  await store.saveProject();
                case 'html':
                  await store.exportHtml();
                case 'svg':
                  await store.exportSvg();
                case 'figma':
                  await store.exportFigma();
                case 'shortcuts':
                  onShortcuts();
                default:
                  if (value.startsWith('recent:')) {
                    onOpenRecent(value.substring('recent:'.length));
                  }
              }
            },
            itemBuilder: (context) => [
              _menu(context, 'new', Icons.add_box_outlined, '新建项目', modCombo('⌘N')),
              _menu(context, 'open', Icons.folder_open_outlined, '打开 DDP…', modCombo('⌘O')),
              _menu(context, 'save', Icons.save_outlined, '保存', modCombo('⌘S')),
              const PopupMenuDivider(),
              _menu(context, 'html', Icons.download_outlined, '导出 HTML 原型', modCombo('⇧⌘H')),
              _menu(context, 'svg', Icons.image_outlined, '导出当前画板 SVG', ''),
              _menu(context, 'figma', Icons.layers_outlined, '导出 Figma 包', ''),
              if (store.recent.isNotEmpty) ...[
                const PopupMenuDivider(),
                _sectionLabel(context, '最近项目'),
                for (final r in store.recent.take(4))
                  _menu(
                    context,
                    'recent:${r['path']}',
                    Icons.history,
                    (r['name'] ?? '').toString(),
                    '',
                  ),
              ],
              const PopupMenuDivider(),
              _menu(context, 'shortcuts', Icons.keyboard_outlined, '快捷键与命令', modCombo('⌘/')),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 210),
                    child: Text(
                      store.projectName,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: p.ink),
                    ),
                  ),
                  if (store.dirty)
                    Padding(
                      padding: const EdgeInsets.only(left: 5),
                      child: Container(width: 5, height: 5, decoration: BoxDecoration(color: p.warn, shape: BoxShape.circle)),
                    ),
                  Icon(Icons.expand_more, size: 15, color: p.ink4),
                ],
              ),
            ),
          ),
          const Spacer(),
          Expanded(
            flex: 4,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Material(
                  color: p.panel2.withValues(alpha: 0.65),
                  borderRadius: BorderRadius.circular(10),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: onCommand,
                    child: Container(
                      height: 31,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: p.line),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.search, size: 14, color: p.ink4),
                          const SizedBox(width: 7),
                          Text('问 NoN，或运行一个命令…', style: TextStyle(fontSize: 12, color: p.ink3)),
                          const Spacer(),
                          _Kbd(modCombo('⌘K')),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const Spacer(),
          if (store.agentBusy)
            Container(
              margin: const EdgeInsets.only(right: 6),
              padding: const EdgeInsets.only(left: 8, right: 2, top: 2, bottom: 2),
              decoration: BoxDecoration(color: p.accentSoft, borderRadius: BorderRadius.circular(8)),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 10,
                    height: 10,
                    child: CircularProgressIndicator(strokeWidth: 1.6, color: p.accent),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    store.agentPhase == 'planning'
                        ? '规划中'
                        : store.agentPhase == 'building'
                            ? '构建中'
                            : store.agentPhase == 'refining'
                                ? '调整中'
                                : '停止中',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: p.accent),
                  ),
                  IconButton(
                    tooltip: '停止',
                    onPressed: () => store.cancelAgent(),
                    icon: Icon(Icons.stop_rounded, size: 14, color: p.accent),
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(minWidth: 26, minHeight: 24),
                  ),
                ],
              ),
            ),
          PopupMenuButton<String>(
            tooltip: '模型',
            offset: const Offset(0, 38),
            color: p.panel,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: p.lineStrong)),
            onSelected: (v) {
              if (v == 'settings') onSettings();
            },
            itemBuilder: (context) => [
              PopupMenuItem<String>(
                enabled: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(model?.name ?? '未选择模型', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: p.ink)),
                    Text('${model?.providerName ?? ''} · ${model?.id ?? ''}',
                        style: TextStyle(fontSize: 10, color: p.ink4)),
                    Text('上下文 ${formatTokens(model?.context)}', style: TextStyle(fontSize: 10, color: p.ink4)),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              _menu(context, 'settings', Icons.tune, '模型与 API Key…', ''),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.auto_awesome, size: 12, color: p.accent),
                  const SizedBox(width: 4),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 150),
                    child: Text(model?.name ?? '选择模型',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: p.ink2, fontWeight: FontWeight.w500)),
                  ),
                  const SizedBox(width: 4),
                  Text(formatTokens(model?.context), style: TextStyle(fontSize: 10, fontFamily: 'Menlo', color: p.ink4)),
                ],
              ),
            ),
          ),
          IconAction(icon: Icons.bolt_outlined, tooltip: 'NoN 面板', active: store.rightTab == 'agent',
              onTap: () => store.setRightTab(store.rightTab == 'agent' ? 'inspect' : 'agent')),
          IconAction(
            icon: store.settings.theme == 'light' ? Icons.dark_mode_outlined : Icons.light_mode_outlined,
            tooltip: '切换主题',
            onTap: () async {
              store.settings.theme = store.settings.theme == 'light' ? 'dark' : 'light';
              await store.saveSettings();
            },
          ),
          IconAction(icon: Icons.settings_outlined, tooltip: '设置 ${modCombo('⌘,')}', onTap: onSettings),
        ],
      ),
    );
  }

  /// 菜单统一宽度（弹层宽度 = 最宽项）：固定 236，避免长文件名把菜单撑爆。
  static const double _menuWidth = 236;

  PopupMenuItem<String> _menu(BuildContext context, String value, IconData icon, String label, String shortcut) {
    final p = context.palette;
    return PopupMenuItem<String>(
      value: value,
      height: 34,
      child: SizedBox(
        width: _menuWidth,
        child: Row(
          children: [
            Icon(icon, size: 14, color: p.ink4),
            const SizedBox(width: 8),
            Expanded(
              child: Text(label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: p.ink2)),
            ),
            if (shortcut.isNotEmpty)
              Text(shortcut,
                  style: TextStyle(fontSize: 10, fontFamily: 'Menlo', color: p.ink4)),
          ],
        ),
      ),
    );
  }

  /// 分节标签（不可交互）。
  PopupMenuItem<String> _sectionLabel(BuildContext context, String label) {
    final p = context.palette;
    return PopupMenuItem<String>(
      enabled: false,
      height: 24,
      child: SizedBox(
        width: _menuWidth,
        child: Text(label,
            style: TextStyle(fontSize: 10, letterSpacing: 0.6, color: p.ink4)),
      ),
    );
  }
}

class _Kbd extends StatelessWidget {
  final String label;
  const _Kbd(this.label);
  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: p.panel2,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: p.line),
      ),
      child: Text(label, style: TextStyle(fontSize: 10, fontFamily: 'Menlo', color: p.ink3)),
    );
  }
}
