import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../core/keys.dart';
import '../core/store.dart';
import '../core/theme.dart';
import 'common.dart';
import 'workspace_open.dart';

/// 顶栏命令条让位断点（整条顶栏的宽度）。
///
/// 中部命令条（搜索图标 + 文案 + ⌘K 键帽 + 模型胶囊）在顶栏 730–820 区间
/// 实测溢出 1.5–61px（批次：桌面壳层）。880 是命令条真正放得下的宽度：
/// 低于它时空出中部，只留搜索图标；高于它时命令条文案仍可收缩省略。
const double kTitleBarNarrowWidth = 880;

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

  /// 当前项目（kind 标签, 显示名, 项目引用, 图标）。
  ///
  /// 一个项目只对应它自己的工作台类型：顶栏永远显示「现在是哪个项目」，
  /// 而不是「现在是哪个工作台」。
  (String, String, String, IconData) _activeProject(AppStore store) {
    switch (store.view) {
      case 'plugin:three':
        final name = store.settings.threeProjectName.trim();
        return (
          '3D 场景',
          name.isEmpty ? '3D 工作台' : name,
          name,
          Icons.view_in_ar_outlined,
        );
      case 'plugin:hotapp':
        final name = store.settings.hotappApp.trim();
        return (
          '热应用',
          name.isEmpty ? 'NaN 热应用' : name,
          name,
          Icons.auto_fix_high_outlined,
        );
      case 'plugin:video':
        return ('视频', '视频工作台', '', Icons.movie_outlined);
      case 'plugin:music':
        return ('音乐', '音乐工作台', '', Icons.library_music_outlined);
      default:
        return ('设计', store.projectName, '', Icons.layers_outlined);
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final p = context.palette;
    final model = store.model;
    return LayoutBuilder(
      builder: (context, constraints) {
        // 窄断点按整条顶栏宽度判定（命令条在 880 以下放不下，见常量注释）。
        final narrow = constraints.maxWidth < kTitleBarNarrowWidth;
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
                key: const ValueKey('title-bar-project-menu'),
                tooltip: '项目与工作台',
                offset: const Offset(0, 38),
                color: p.panel,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: BorderSide(color: p.lineStrong),
                ),
                // 每次展开都刷一次目录（刚做出来的 3D 场景/热应用要能立刻出现在
                // 项目切换列表里）。
                onOpened: () {
                  if (store.portfolioAutoRefreshEnabled) {
                    store.refreshPortfolio(force: true);
                  }
                },
                onSelected: (value) async {
                  if (value.startsWith('switch:design:')) {
                    final path = value.substring('switch:design:'.length);
                    // 当前项目那一行是「当前」标记，点了不重复打开。
                    if (path.isNotEmpty) onOpenRecent(path);
                    return;
                  }
                  if (value.startsWith('switch:three:')) {
                    openThreeScene(
                      store,
                      value.substring('switch:three:'.length),
                    );
                    return;
                  }
                  if (value.startsWith('switch:hotapp:')) {
                    openHotApp(store, value.substring('switch:hotapp:'.length));
                    return;
                  }
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
                    case 'home':
                      store.setView('home');
                    case 'video':
                      openVideoWorkspace(store);
                    case 'music':
                      openMusicWorkspace(store);
                    case 'new-three':
                      newThreeScene(store);
                    case 'new-hotapp':
                      newHotApp(store);
                  }
                },
                itemBuilder: (context) {
                  // 工作台跟着项目走（用户裁决 2026-11-19）：这份菜单就是唯一的
                  // 项目/工作台切换口，列的是**项目**，不是工作台按钮。
                  final threeEntries = store.portfolioEntries
                      .where((e) => e.kind == 'three')
                      .take(5)
                      .toList();
                  final hotEntries = store.portfolioEntries
                      .where((e) => e.kind == 'hotapp')
                      .take(5)
                      .toList();
                  final designFace = !store.view.startsWith('plugin:');
                  final current = _activeProject(store);
                  final recent = [
                    for (final r in store.recent.take(4))
                      if ((r['path'] ?? '').toString() !=
                          (store.projectPath ?? ''))
                        r,
                  ];
                  return [
                    _menu(
                      context,
                      'new',
                      Icons.add_box_outlined,
                      '新建项目',
                      modCombo('⌘N'),
                    ),
                    _menu(
                      context,
                      'open',
                      Icons.folder_open_outlined,
                      '打开项目…',
                      modCombo('⌘O'),
                    ),
                    if (designFace)
                      _menu(
                        context,
                        'save',
                        Icons.save_outlined,
                        '保存',
                        modCombo('⌘S'),
                      ),
                    const PopupMenuDivider(),
                    _menu(context, 'home', Icons.home_outlined, '回到主页', ''),
                    const PopupMenuDivider(),
                    _sectionLabel(context, '设计项目'),
                    _menu(
                      context,
                      'switch:design:${store.projectPath ?? ''}',
                      Icons.layers_outlined,
                      store.projectName,
                      '当前',
                    ),
                    for (final r in recent)
                      _menu(
                        context,
                        'switch:design:${r['path']}',
                        Icons.layers_outlined,
                        (r['name'] ?? '').toString(),
                        '',
                      ),
                    const PopupMenuDivider(),
                    _sectionLabel(context, '3D 场景'),
                    for (final e in threeEntries)
                      _menu(
                        context,
                        'switch:three:${e.ref}',
                        Icons.view_in_ar_outlined,
                        e.title,
                        e.ref == current.$3 && store.view == 'plugin:three'
                            ? '当前'
                            : '',
                      ),
                    _menu(context, 'new-three', Icons.add, '新建 3D 场景', ''),
                    const PopupMenuDivider(),
                    _sectionLabel(context, '热应用'),
                    for (final e in hotEntries)
                      _menu(
                        context,
                        'switch:hotapp:${e.ref}',
                        Icons.auto_fix_high_outlined,
                        e.title,
                        e.ref == current.$3 && store.view == 'plugin:hotapp'
                            ? '当前'
                            : '',
                      ),
                    _menu(context, 'new-hotapp', Icons.add, '新建热应用', ''),
                    const PopupMenuDivider(),
                    _menu(
                      context,
                      'video',
                      Icons.movie_outlined,
                      '视频工作台',
                      '代码动画',
                    ),
                    _menu(
                      context,
                      'music',
                      Icons.library_music_outlined,
                      '音乐工作台',
                      '乐谱 / 编曲',
                    ),
                    if (designFace) ...[
                      const PopupMenuDivider(),
                      _menu(
                        context,
                        'html',
                        Icons.download_outlined,
                        '导出 HTML 原型',
                        modCombo('⇧⌘H'),
                      ),
                      _menu(
                        context,
                        'svg',
                        Icons.image_outlined,
                        '导出当前画板 SVG',
                        '',
                      ),
                      _menu(
                        context,
                        'figma',
                        Icons.layers_outlined,
                        '导出 Figma 包',
                        '',
                      ),
                    ],
                    const PopupMenuDivider(),
                    _menu(
                      context,
                      'shortcuts',
                      Icons.keyboard_outlined,
                      '快捷键与命令',
                      modCombo('⌘/'),
                    ),
                  ];
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 6,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 标识当前项目类型：同一个位置既显示「现在在哪个项目」，
                      // 也是唯一的切换口（工作台类型由项目决定）。
                      Icon(_activeProject(store).$4, size: 14, color: p.ink4),
                      const SizedBox(width: 6),
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: narrow ? 96 : 210,
                        ),
                        child: Text(
                          _activeProject(store).$2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: p.ink,
                          ),
                        ),
                      ),
                      if (store.dirty && !store.view.startsWith('plugin:'))
                        Padding(
                          padding: const EdgeInsets.only(left: 5),
                          child: Container(
                            width: 5,
                            height: 5,
                            decoration: BoxDecoration(
                              color: p.warn,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                      Icon(Icons.expand_more, size: 15, color: p.ink4),
                    ],
                  ),
                ),
              ),
              const Spacer(),
              if (narrow)
                IconAction(
                  key: const ValueKey('title-bar-command-icon'),
                  icon: Icons.search,
                  tooltip: '命令 ${modCombo('⌘K')}',
                  onTap: onCommand,
                )
              else
                Expanded(
                  flex: 4,
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 440),
                      child: Material(
                        key: const ValueKey('title-bar-command-bar'),
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
                                // 文案可收缩省略：宽度不够时截断而不是把整条命令条撑出。
                                Expanded(
                                  child: Text(
                                    '问 NaN，或运行一个命令…',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: p.ink3,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
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
                  padding: const EdgeInsets.only(
                    left: 8,
                    right: 2,
                    top: 2,
                    bottom: 2,
                  ),
                  decoration: BoxDecoration(
                    color: p.accentSoft,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 10,
                        height: 10,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.6,
                          color: p.accent,
                        ),
                      ),
                      const SizedBox(width: 5),
                      if (!narrow)
                        Text(
                          store.agentPhase == 'planning'
                              ? '规划中'
                              : store.agentPhase == 'building'
                              ? '构建中'
                              : store.agentPhase == 'refining'
                              ? '调整中'
                              : '停止中',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: p.accent,
                          ),
                        ),
                      IconButton(
                        tooltip: '停止',
                        onPressed: () => store.cancelAgent(),
                        icon: Icon(
                          Icons.stop_rounded,
                          size: 14,
                          color: p.accent,
                        ),
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints(
                          minWidth: 26,
                          minHeight: 24,
                        ),
                      ),
                    ],
                  ),
                ),
              PopupMenuButton<String>(
                tooltip: '模型',
                offset: const Offset(0, 38),
                color: p.panel,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: BorderSide(color: p.lineStrong),
                ),
                onSelected: (v) {
                  if (v == 'settings') onSettings();
                },
                itemBuilder: (context) => [
                  PopupMenuItem<String>(
                    enabled: false,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          model?.name ?? '未选择模型',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: p.ink,
                          ),
                        ),
                        Text(
                          '${model?.providerName ?? ''} · ${model?.id ?? ''}',
                          style: TextStyle(fontSize: 10, color: p.ink4),
                        ),
                        Text(
                          '上下文 ${formatTokens(model?.context)}',
                          style: TextStyle(fontSize: 10, color: p.ink4),
                        ),
                      ],
                    ),
                  ),
                  const PopupMenuDivider(),
                  _menu(context, 'settings', Icons.tune, '模型与密钥…', ''),
                ],
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: narrow ? 3 : 6,
                    vertical: 6,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.auto_awesome, size: 12, color: p.accent),
                      if (!narrow) ...[
                        const SizedBox(width: 4),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 150),
                          child: Text(
                            model?.name ?? '选择模型',
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: p.ink2,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          formatTokens(model?.context),
                          style: TextStyle(
                            fontSize: 10,
                            fontFamily: 'Menlo',
                            color: p.ink4,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              IconAction(
                key: const ValueKey('title-bar-rail-toggle'),
                icon: Icons.bolt_outlined,
                tooltip: 'NaN 面板',
                active: store.rightTab == 'agent',
                onTap: () => store.setRightTab(
                  store.rightTab == 'agent' ? 'inspect' : 'agent',
                ),
              ),
              IconAction(
                key: const ValueKey('title-bar-theme'),
                icon: store.settings.theme == 'light'
                    ? Icons.dark_mode_outlined
                    : Icons.light_mode_outlined,
                tooltip: '切换主题',
                onTap: () async {
                  store.settings.theme = store.settings.theme == 'light'
                      ? 'dark'
                      : 'light';
                  await store.saveSettings();
                },
              ),
              IconAction(
                key: const ValueKey('title-bar-settings'),
                icon: Icons.settings_outlined,
                tooltip: '设置 ${modCombo('⌘,')}',
                onTap: onSettings,
              ),
            ],
          ),
        );
      },
    );
  }

  /// 菜单统一宽度（弹层宽度 = 最宽项）：固定 236，避免长文件名把菜单撑爆。
  static const double _menuWidth = 236;

  PopupMenuItem<String> _menu(
    BuildContext context,
    String value,
    IconData icon,
    String label,
    String shortcut,
  ) {
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
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: p.ink2),
              ),
            ),
            if (shortcut.isNotEmpty)
              Text(
                shortcut,
                style: TextStyle(
                  fontSize: 10,
                  fontFamily: 'Menlo',
                  color: p.ink4,
                ),
              ),
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
        child: Text(
          label,
          style: TextStyle(fontSize: 10, letterSpacing: 0.6, color: p.ink4),
        ),
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
      child: Text(
        label,
        style: TextStyle(fontSize: 10, fontFamily: 'Menlo', color: p.ink3),
      ),
    );
  }
}
