import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../core/keys.dart';
import '../core/store.dart';
import '../core/theme.dart';
import 'aqua.dart';
import 'common.dart';
import 'workspace_open.dart';

/// 顶栏命令条让位断点（整条顶栏的宽度）。
///
/// 中部命令条（搜索图标 + 文案 + ⌘K 键帽 + 模型胶囊）在顶栏 730–820 区间
/// 实测溢出 1.5–61px（批次：桌面壳层）。880 是命令条真正放得下的宽度：
/// 低于它时空出中部，只留搜索图标；高于它时命令条文案仍可收缩省略。
const double kTitleBarNarrowWidth = 880;

/// 深色主题标题栏高度（浅色 = Aqua，高度取 [AquaMetrics.titleBarHeight]）。
const double _kTitleBarHeightDark = 52;

/// 项目徽章 [Selector] 的选择值：这些字段变了才重建徽章，agent 运行期
/// 的逐条事件（usage / 时间线）不再重建整条标题栏。
typedef _ProjectBadgeKey = (
  String, // view
  String, // projectName
  String, // settings.threeProjectName
  String, // settings.hotappApp
  String, // musicProjectName
  String, // video3dProjectName
  bool, // dirty
);

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
      case 'plugin:video3d':
        // 3D 视频项目由工作台自己的项目库切换；store 只在能观察到切换的入口
        // （项目菜单 / 打包导入）记录当前项目名，有记录时显示它，让「打包当前
        // 项目」的目标在顶栏可见。
        final name = store.video3dProjectName.trim();
        return (
          '3D 视频',
          name.isEmpty ? '3D 视频工作台' : name,
          name,
          Icons.movie_creation_outlined,
        );
      case 'plugin:music':
        final name = store.musicProjectName.trim();
        return (
          '音乐',
          name.isEmpty ? '音乐工作台' : name,
          name,
          Icons.library_music_outlined,
        );
      default:
        return ('设计', store.projectName, '', Icons.layers_outlined);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 只读、不订阅：整条顶栏不再随 store.notify 全量重建（agent 运行期
    // 逐条事件是这条路径上最热的来源）。真正需要跟随 store 的四处——项目
    // 徽章、忙碌芯片、模型胶囊、窄栏/主题图标——各自用 Selector 收窄。
    final store = context.read<AppStore>();
    final p = context.palette;
    final bool aqua = isAquaTheme(context);
    final double height = aqua
        ? AquaMetrics.titleBarHeight
        : _kTitleBarHeightDark;
    return LayoutBuilder(
      builder: (context, constraints) {
        // 窄断点按整条顶栏宽度判定（命令条在 880 以下放不下，见常量注释）。
        final narrow = constraints.maxWidth < kTitleBarNarrowWidth;
        final content = Padding(
          padding: const EdgeInsets.symmetric(horizontal: NonSpace.md),
          child: Row(
            children: [
              // 浅色 = Aqua：左侧红/黄/绿口香糖窗口控件。本期只作材质装饰，
              // 不新增窗口行为（执行 `ExcludeSemantics`：不给读屏报假按钮）。
              if (aqua) ...[
                const ExcludeSemantics(
                  child: AquaGumdrops(size: AquaMetrics.gumdropSize),
                ),
                const SizedBox(width: NonSpace.sm),
              ],
              const NonLogo(size: 24),
              const SizedBox(width: NonSpace.sm),
              PopupMenuButton<String>(
                key: const ValueKey('title-bar-project-menu'),
                tooltip: '项目与工作台',
                offset: const Offset(0, 38),
                color: p.panel,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(NonRadius.md),
                  side: BorderSide(color: p.lineStrong),
                ),
                // 菜单宽度统一走 nonMenuWidthCap（≤280 / 窄屏 屏宽-24）。
                constraints: BoxConstraints(maxWidth: nonMenuWidthCap(context)),
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
                  if (value.startsWith('switch:music:')) {
                    openMusicWorkspace(
                      store,
                      value.substring('switch:music:'.length),
                    );
                    return;
                  }
                  if (value.startsWith('switch:video3d:')) {
                    final name = value
                        .substring('switch:video3d:'.length)
                        .trim();
                    // 记下「当前 3D 视频项目」：工作台内部切项目没有回写 store，
                    // 从项目菜单点进来的这一跳是能观察到切换的入口。
                    if (name.isNotEmpty) store.setVideo3dProjectName(name);
                    openVideo3dWorkspace(store, name);
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
                    case 'export-pack':
                      await store.exportWorkbenchPack();
                    case 'import-pack':
                      await store.importWorkbenchPack();
                    case 'home':
                      store.setView('home');
                    case 'video':
                      openVideoWorkspace(store);
                    case 'video3d':
                      // 不带项目进 3D 视频工作台：工作台会自动打开列表首项，
                      // store 此刻不知道是哪一个——清掉记录，宁可不给打包入口
                      // 也不拿旧项目名打包错项目（工作台内部切换的接线是后续项）。
                      if (store.view != 'plugin:video3d') {
                        store.setVideo3dProjectName('');
                      }
                      openVideo3dWorkspace(store);
                    case 'new-video3d':
                      if (store.view != 'plugin:video3d') {
                        store.setVideo3dProjectName('');
                      }
                      newVideo3dProject(store);
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
                  final musicEntries = store.portfolioEntries
                      .where((e) => e.kind == 'music')
                      .take(5)
                      .toList();
                  final video3dEntries = store.portfolioEntries
                      .where((e) => e.kind == 'video3d')
                      .take(5)
                      .toList();
                  final designFace = !store.view.startsWith('plugin:');
                  final current = _activeProject(store);
                  // 打包入口只对音乐 / 视频 / 3D 视频三个工作台开放（它们有
                  // 单一容器的事实源）；导出还要求当前工作台确实打开了一个项目，
                  // 否则禁用——不给「点了没反应」或「打包了别的项目」的可能。
                  final String? packKind = store.packKindForView(store.view);
                  final bool canImportPack = packKind != null;
                  final bool canExportPack =
                      packKind != null &&
                      store.currentPackProjectName.isNotEmpty;
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
                    _menu(
                      context,
                      'export-pack',
                      Icons.inventory_2_outlined,
                      '打包当前项目…',
                      '',
                      key: const ValueKey('title-bar-export-pack'),
                      enabled: canExportPack,
                    ),
                    _menu(
                      context,
                      'import-pack',
                      Icons.unarchive_outlined,
                      '导入打包项目…',
                      '',
                      key: const ValueKey('title-bar-import-pack'),
                      enabled: canImportPack,
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
                    const PopupMenuDivider(),
                    _sectionLabel(context, '音乐'),
                    for (final e in musicEntries)
                      _menu(
                        context,
                        'switch:music:${e.ref}',
                        Icons.library_music_outlined,
                        e.title,
                        e.ref == current.$3 && store.view == 'plugin:music'
                            ? '当前'
                            : '',
                      ),
                    _menu(
                      context,
                      'music',
                      Icons.library_music_outlined,
                      '音乐工作台',
                      '乐谱 / 编曲',
                    ),
                    // 3D 视频分区放在音乐之后：既保持既有分区顺序，也让「新建
                    // 3D 视频」贴着工作台入口（点它进工作台空态，由空态里的
                    // 新建按钮拉起小对话框）。
                    const PopupMenuDivider(),
                    _sectionLabel(context, '3D 视频'),
                    for (final e in video3dEntries)
                      _menu(
                        context,
                        'switch:video3d:${e.ref}',
                        Icons.movie_creation_outlined,
                        e.title,
                        e.ref == current.$3 && store.view == 'plugin:video3d'
                            ? '当前'
                            : '',
                      ),
                    _menu(
                      context,
                      'video3d',
                      Icons.movie_creation_outlined,
                      '3D 视频工作台',
                      '只读预览',
                    ),
                    _menu(context, 'new-video3d', Icons.add, '新建 3D 视频', ''),
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
                child: Selector<AppStore, _ProjectBadgeKey>(
                  selector: (context, s) => (
                    s.view,
                    s.projectName,
                    s.settings.threeProjectName,
                    s.settings.hotappApp,
                    s.musicProjectName,
                    s.video3dProjectName,
                    s.dirty,
                  ),
                  builder: (context, _, child) {
                    final store = context.read<AppStore>();
                    final active = _activeProject(store);
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: NonSpace.xs,
                        vertical: 6,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // 标识当前项目类型：同一个位置既显示「现在在哪个项目」，
                          // 也是唯一的切换口（工作台类型由项目决定）。
                          Icon(active.$4, size: 14, color: p.ink4),
                          const SizedBox(width: 6),
                          ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: narrow ? 96 : 210,
                            ),
                            child: Text(
                              active.$2,
                              overflow: TextOverflow.ellipsis,
                              style: NonType.of(
                                NonType.bodyStrong,
                                color: p.ink,
                                weight: FontWeight.w600,
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
                    );
                  },
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
                    // 命令条是静态片（只响应点按），单独隔离重绘。
                    child: RepaintBoundary(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 440),
                        child: Material(
                          key: const ValueKey('title-bar-command-bar'),
                          color: p.panel2.withValues(alpha: 0.65),
                          borderRadius: BorderRadius.circular(NonRadius.md),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(NonRadius.md),
                            onTap: onCommand,
                            child: Container(
                              height: 31,
                              padding: const EdgeInsets.symmetric(
                                horizontal: NonSpace.sm,
                              ),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(
                                  NonRadius.md,
                                ),
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
                                      style: NonType.of(
                                        NonType.body,
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
                ),
              const Spacer(),
              // 忙碌芯片：只在 agentBusy/agentPhase 变化时重建这一小块。
              Selector<AppStore, (bool, String)>(
                selector: (context, s) => (s.agentBusy, s.agentPhase),
                builder: (context, state, child) {
                  if (!state.$1) return const SizedBox.shrink();
                  final store = context.read<AppStore>();
                  return Container(
                    margin: const EdgeInsets.only(right: 6),
                    padding: const EdgeInsets.only(
                      left: NonSpace.sm,
                      right: NonSpace.xxs,
                      top: NonSpace.xxs,
                      bottom: NonSpace.xxs,
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
                            state.$2 == 'planning'
                                ? '规划中'
                                : state.$2 == 'building'
                                ? '构建中'
                                : state.$2 == 'refining'
                                ? '调整中'
                                : '停止中',
                            style: NonType.of(
                              NonType.caption,
                              color: p.accent,
                              weight: FontWeight.w600,
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
                  );
                },
              ),
              // 模型胶囊：菜单项在展开时现读 store（永远是最新清单）。
              PopupMenuButton<String>(
                tooltip: '模型',
                offset: const Offset(0, 38),
                color: p.panel,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(NonRadius.md),
                  side: BorderSide(color: p.lineStrong),
                ),
                // 与项目下拉同一宽度上限（长模型名/服务商名不撑宽菜单）。
                constraints: BoxConstraints(maxWidth: nonMenuWidthCap(context)),
                onSelected: (v) {
                  if (v == 'settings') onSettings();
                },
                itemBuilder: (context) {
                  final model = store.model;
                  return [
                    PopupMenuItem<String>(
                      enabled: false,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 模型名/服务商名可能很长：单行省略 + 悬停 Tooltip，
                          // 不再把菜单撑到宽度上限之外。
                          Tooltip(
                            message: model?.name ?? '未选择模型',
                            child: Text(
                              model?.name ?? '未选择模型',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: NonType.of(
                                NonType.body,
                                color: p.ink,
                                weight: FontWeight.w600,
                              ),
                            ),
                          ),
                          Tooltip(
                            message:
                                '${model?.providerName ?? ''} · ${model?.id ?? ''}',
                            child: Text(
                              '${model?.providerName ?? ''} · ${model?.id ?? ''}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: NonType.of(NonType.micro, color: p.ink4),
                            ),
                          ),
                          Text(
                            '上下文 ${formatTokens(model?.context)}',
                            style: NonType.of(NonType.micro, color: p.ink4),
                          ),
                        ],
                      ),
                    ),
                    const PopupMenuDivider(),
                    _menu(context, 'settings', Icons.tune, '模型与密钥…', ''),
                  ];
                },
                child: Selector<AppStore, (String?, String?, int?)>(
                  selector: (context, s) =>
                      (s.model?.name, s.model?.providerName, s.model?.context),
                  builder: (context, state, child) {
                    final model = context.read<AppStore>().model;
                    return Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: narrow ? 3 : 6,
                        vertical: 6,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.auto_awesome, size: 12, color: p.accent),
                          if (!narrow) ...[
                            const SizedBox(width: NonSpace.xs),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 150),
                              child: Text(
                                model?.name ?? '选择模型',
                                overflow: TextOverflow.ellipsis,
                                style: NonType.of(
                                  NonType.caption,
                                  color: p.ink2,
                                  weight: FontWeight.w500,
                                ),
                              ),
                            ),
                            const SizedBox(width: NonSpace.xs),
                            Text(
                              formatTokens(model?.context),
                              style: NonType.of(
                                NonType.micro,
                                color: p.ink4,
                                // 数字对齐用等宽字体（字体族不是颜色令牌）。
                              ).copyWith(fontFamily: 'Menlo'),
                            ),
                          ],
                        ],
                      ),
                    );
                  },
                ),
              ),
              Selector<AppStore, bool>(
                selector: (context, s) => s.rightTab == 'agent',
                builder: (context, active, child) => IconAction(
                  key: const ValueKey('title-bar-rail-toggle'),
                  icon: Icons.bolt_outlined,
                  tooltip: 'NaN 面板',
                  active: active,
                  onTap: () {
                    final store = context.read<AppStore>();
                    store.setRightTab(
                      store.rightTab == 'agent' ? 'inspect' : 'agent',
                    );
                  },
                ),
              ),
              Selector<AppStore, bool>(
                selector: (context, s) => s.settings.theme == 'light',
                builder: (context, light, child) => IconAction(
                  key: const ValueKey('title-bar-theme'),
                  icon: light
                      ? Icons.dark_mode_outlined
                      : Icons.light_mode_outlined,
                  tooltip: '切换主题',
                  onTap: () async {
                    final store = context.read<AppStore>();
                    store.settings.theme = light ? 'dark' : 'light';
                    await store.saveSettings();
                  },
                ),
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
        // 浅色 = Aqua：窗口标题栏是细条纹面（pinstripe）+ palette 取色；
        // 深色主题保持原来的半透明底。两种分支的几何完全一致（同一内边距）。
        final Widget bar = Container(
          height: height,
          decoration: BoxDecoration(
            color: aqua ? p.bgElevated : p.bgElevated.withValues(alpha: 0.94),
            border: Border(bottom: BorderSide(color: p.line)),
          ),
          child: aqua
              ? AquaPinstripes(stripeColor: p.line, child: content)
              : content,
        );
        // 静态头部隔离重绘：内容层动画/滚动不会把标题栏一起重画。
        return RepaintBoundary(child: bar);
      },
    );
  }

  /// 菜单行：宽度不再写死（此前固定 236 内容宽 + 行内边距 + PopupMenu 的
  /// 56px 步进，把整份菜单顶到 280 上限、只剩大片空白）：改为按内容 intrinsic
  /// 收缩、由弹层 constraints 的 [nonMenuWidthCap] 封顶；长文案（项目名等）
  /// 省略 + 悬停 Tooltip 看全文，而不是把菜单撑宽。行高统一 32。
  PopupMenuItem<String> _menu(
    BuildContext context,
    String value,
    IconData icon,
    String label,
    String shortcut, {
    Key? key,
    bool enabled = true,
  }) {
    final p = context.palette;
    return PopupMenuItem<String>(
      key: key,
      value: value,
      enabled: enabled,
      height: kNonMenuRowHeight,
      child: Row(
        children: [
          Icon(icon, size: 14, color: p.ink4),
          const SizedBox(width: NonSpace.sm),
          Expanded(
            child: Tooltip(
              message: label,
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: NonType.of(NonType.body, color: p.ink2),
              ),
            ),
          ),
          if (shortcut.isNotEmpty) ...[
            const SizedBox(width: NonSpace.sm),
            Text(
              shortcut,
              style: NonType.of(
                NonType.micro,
                color: p.ink4,
              ).copyWith(fontFamily: 'Menlo'),
            ),
          ],
        ],
      ),
    );
  }

  /// 分节标签（不可交互）：字号 11（NonType.caption），行高 24。
  PopupMenuItem<String> _sectionLabel(BuildContext context, String label) {
    final p = context.palette;
    return PopupMenuItem<String>(
      enabled: false,
      height: 24,
      child: Text(
        label,
        style: NonType.of(NonType.caption, color: p.ink4, letterSpacing: 0.6),
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
      padding: const EdgeInsets.symmetric(
        horizontal: 5,
        vertical: NonSpace.xxs,
      ),
      decoration: BoxDecoration(
        color: p.panel2,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: p.line),
      ),
      child: Text(
        label,
        style: NonType.of(
          NonType.micro,
          color: p.ink3,
        ).copyWith(fontFamily: 'Menlo'),
      ),
    );
  }
}
