import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/keys.dart';
import '../core/store.dart';
import '../core/theme.dart';
import '../plugins/registry.dart';
import 'common.dart';
import 'workspace.dart';

class Welcome extends StatefulWidget {
  final VoidCallback onNewProject;
  final void Function(String path) onOpenPath;
  final VoidCallback onSettings;
  const Welcome({super.key, required this.onNewProject, required this.onOpenPath, required this.onSettings});

  @override
  State<Welcome> createState() => _WelcomeState();
}

class _WelcomeState extends State<Welcome> {
  final _brief = TextEditingController();

  @override
  void initState() {
    super.initState();
    // boot() already refreshes; this covers a server that came up late.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final store = context.read<AppStore>();
      if (store.serverProjects.isEmpty && !store.refreshingProjects) store.refreshProjects();
    });
  }

  @override
  void dispose() {
    _brief.dispose();
    super.dispose();
  }

  void _start(AppStore store) {
    final brief = _brief.text.trim();
    if (brief.isEmpty || store.agentBusy) return;
    if (store.settings.apiKey.trim().isEmpty) {
      widget.onSettings();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('先在设置里填入服务商 API Key'), behavior: SnackBarBehavior.floating),
      );
      return;
    }
    store.generateFromBrief(brief);
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final p = context.palette;
    return Scaffold(
      backgroundColor: p.bg,
      body: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(painter: _DotsPainter(p.canvasDot)),
          ),
          Positioned(
            left: -180,
            top: -200,
            child: Container(
              width: 560,
              height: 560,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(colors: [p.accent.withValues(alpha: 0.18), Colors.transparent]),
              ),
            ),
          ),
          Positioned(
            right: -200,
            bottom: -240,
            child: Container(
              width: 640,
              height: 640,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(colors: [p.accent2.withValues(alpha: 0.16), Colors.transparent]),
              ),
            ),
          ),
          SafeArea(
            child: Column(
            children: [
              Container(
                height: 60,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    const NonLogo(size: 26),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('NoNDesign',
                              maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: p.ink)),
                          Text('AI CREATION STUDIO',
                              maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 10, letterSpacing: 1.6, color: p.ink4)),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    // 聊天流入口（S1 主面切换）：Welcome 只在关闭
                    // chatStreamHome 时出现，这里给出回聊天流的显式门。
                    IconAction(
                      icon: Icons.forum_outlined,
                      tooltip: '聊天流',
                      onTap: () => store.setView('chat'),
                    ),
                    IconAction(
                      icon: store.settings.theme == 'light' ? Icons.dark_mode_outlined : Icons.light_mode_outlined,
                      tooltip: '切换主题',
                      onTap: () async {
                        store.settings.theme = store.settings.theme == 'light' ? 'dark' : 'light';
                        await store.saveSettings();
                      },
                    ),
                    IconAction(icon: Icons.settings_outlined, tooltip: '设置', onTap: widget.onSettings),
                  ],
                ),
              ),
              if (MediaQuery.of(context).size.width < 700)
                Expanded(
                  child: _mobileBody(context, store),
                )
              else
                Expanded(
                child: Center(
                  key: const ValueKey('welcome-wide'),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1120),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 36),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            flex: 6,
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                  decoration: BoxDecoration(
                                    color: p.accentSoft,
                                    borderRadius: BorderRadius.circular(999),
                                    border: Border.all(color: p.accent.withValues(alpha: 0.25)),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.auto_awesome, size: 11, color: p.accent),
                                      const SizedBox(width: 5),
                                      Text('文档 · 原型 · 3D · 视频 · 热应用',
                                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w500, color: p.accent)),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 14),
                                ShaderMask(
                                  shaderCallback: (bounds) => LinearGradient(
                                    colors: [p.accent, p.accent2, p.danger.withValues(alpha: 0.85)],
                                  ).createShader(bounds),
                                  child: const Text('把想法变成\n能用的作品',
                                      style: TextStyle(
                                        fontSize: 44,
                                        height: 1.08,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: -1.5,
                                        color: Colors.white,
                                      )),
                                ),
                                const SizedBox(height: 14),
                                Text(
                                  '描述你要解决的问题和受众。NoN 会先写设计文档，再把它变成可交互原型；'
                                  '同一个工作台里还能做 3D 场景、代码生成的视频，以及带 SQLite 数据库的热应用。',
                                  style: TextStyle(fontSize: 13, height: 1.65, color: p.ink3),
                                ),
                                if (store.recovery != null) ...[
                                  const SizedBox(height: 12),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                                    decoration: BoxDecoration(
                                      color: p.warn.withValues(alpha: 0.1),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(color: p.warn.withValues(alpha: 0.3)),
                                    ),
                                    child: Row(
                                      children: [
                                        Text('检测到上次未保存的工作', style: TextStyle(fontSize: 11, color: p.warn)),
                                        const Spacer(),
                                        TextButton(onPressed: store.restoreRecovery, child: const Text('恢复', style: TextStyle(fontSize: 11))),
                                        TextButton(onPressed: store.discardRecovery, child: const Text('忽略', style: TextStyle(fontSize: 11))),
                                      ],
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 22),
                                _briefCard(context, store),
                                const SizedBox(height: 10),
                                _briefHints(context),
                              ],
                            ),
                          ),
                          const SizedBox(width: 44),
                          Expanded(
                            flex: 4,
                            // 右列内容高随真实数据无上限增长（recent ≤6 +
                            // 工作区/桌面 ≤8）：1440×920 实测整列溢出
                            // 450px、1024×768 溢出 326px。改可滚动，内容短于
                            // 视口时仍垂直居中（原 Column 的 center 语义，
                            // minHeight 钉满视口实现）。
                            child: LayoutBuilder(
                              builder: (context, constraints) => SingleChildScrollView(
                                child: ConstrainedBox(
                                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      _recentCard(context, store),
                                      const SizedBox(height: 10),
                                      _workbenchCard(context, store),
                                      const SizedBox(height: 10),
                                      _portfolioCard(context, store),
                                      const SizedBox(height: 10),
                                      _howCard(context, p),
                                      const SizedBox(height: 10),
                                      Wrap(
                                        spacing: 5,
                                        runSpacing: 5,
                                        children: const [
                                          Pill(label: '引擎门校验', icon: Icons.verified_outlined),
                                          Pill(label: 'DDP 单文件', icon: Icons.lock_outline),
                                          Pill(label: '前缀缓存', icon: Icons.bolt_outlined),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Container(
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(border: Border(top: BorderSide(color: p.line))),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text('NoNDesign v0.1 · MoonViz engine · 模型与端点来自 models.dev · 所有操作可撤销',
                    textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10, height: 1.3, color: p.ink4)),
              ),
            ],
            ),
          ),
        ],
      ),
    );
  }

  /// 手机窄屏主页：单列滚动。真机实测（iPhone 17 / 402×874）桌面双栏在手机宽度下
  /// 右溢 198px、底溢 327px（右列被压成单字竖排、开始按钮叠到作品集卡上）——
  /// 窄屏改走这条单列路径，宽屏双栏原样保留。
  Widget _mobileBody(BuildContext context, AppStore store) {
    final p = context.palette;
    return SingleChildScrollView(
      key: const ValueKey('welcome-narrow'),
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: p.accentSoft,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: p.accent.withValues(alpha: 0.25)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.auto_awesome, size: 11, color: p.accent),
                  const SizedBox(width: 5),
                  Text('文档 · 原型 · 3D · 视频 · 热应用',
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w500, color: p.accent)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          ShaderMask(
            shaderCallback: (bounds) => LinearGradient(
              colors: [p.accent, p.accent2, p.danger.withValues(alpha: 0.85)],
            ).createShader(bounds),
            child: const Text('把想法变成\n能用的作品',
                style: TextStyle(
                  fontSize: 34,
                  height: 1.1,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -1.0,
                  color: Colors.white,
                )),
          ),
          const SizedBox(height: 12),
          Text(
            '描述你要解决的问题和受众。NoN 会先写设计文档，再把它变成可交互原型；'
            '同一个工作台里还能做 3D 场景、代码生成的视频，以及带 SQLite 数据库的热应用。',
            style: TextStyle(fontSize: 12.5, height: 1.6, color: p.ink3),
          ),
          if (store.recovery != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: p.warn.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: p.warn.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  Expanded(child: Text('检测到上次未保存的工作', style: TextStyle(fontSize: 11, color: p.warn))),
                  TextButton(onPressed: store.restoreRecovery, child: const Text('恢复', style: TextStyle(fontSize: 11))),
                  TextButton(onPressed: store.discardRecovery, child: const Text('忽略', style: TextStyle(fontSize: 11))),
                ],
              ),
            ),
          ],
          const SizedBox(height: 16),
          _briefCard(context, store),
          const SizedBox(height: 8),
          _briefHints(context),
          const SizedBox(height: 16),
          _workbenchCard(context, store),
          const SizedBox(height: 10),
          _portfolioCard(context, store),
          const SizedBox(height: 10),
          _recentCard(context, store),
          const SizedBox(height: 10),
          _howCard(context, p),
          const SizedBox(height: 10),
          Wrap(
            spacing: 5,
            runSpacing: 5,
            children: const [
              Pill(label: '引擎门校验', icon: Icons.verified_outlined),
              Pill(label: 'DDP 单文件', icon: Icons.lock_outline),
              Pill(label: '前缀缓存', icon: Icons.bolt_outlined),
            ],
          ),
        ],
      ),
    );
  }

  /// 输入卡（宽屏与窄屏共用）。窄屏下 chips 与开始按钮改用 Wrap + 换行，
  /// 避免在 198px 宽的双栏列里 chips+按钮横向溢出（真机实证）。
  Widget _briefCard(BuildContext context, AppStore store) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.all(9),
      decoration: BoxDecoration(
        color: p.panel.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: p.lineStrong),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.45), blurRadius: 50, offset: const Offset(0, 24))],
      ),
      child: Column(
        children: [
          TextField(
            controller: _brief,
            minLines: 3,
            maxLines: 5,
            style: TextStyle(fontSize: 13, height: 1.55, color: p.ink),
            decoration: InputDecoration(
              hintText: '例如：做一个面向自由职业者的发票工具。需要登录、发票列表、新建发票、客户管理和设置；风格专业、克制，移动端优先。',
              hintStyle: TextStyle(fontSize: 13, height: 1.55, color: p.ink4),
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              filled: false,
              contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            ),
            onSubmitted: (_) => _start(store),
          ),
          LayoutBuilder(
            builder: (context, constraints) {
              final examples = [
                for (final example in ['电商 App', 'SaaS 仪表盘', 'AI 助手', '个人作品集'])
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(4),
                      onTap: () => _brief.text = '做一个$example：先写 PRD 与 UI 说明，再生成完整可交互原型。移动端优先，风格现代克制。',
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                        decoration: BoxDecoration(color: p.panel2, borderRadius: BorderRadius.circular(4)),
                        child: Text(example, style: TextStyle(fontSize: 10, color: p.ink3)),
                      ),
                    ),
                  ),
              ];
              final button = FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: p.accent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
                ),
                onPressed: store.agentBusy ? null : () => _start(store),
                icon: store.agentBusy
                    ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5))
                    : const Icon(Icons.auto_awesome, size: 13),
                label: const Text('开始创作', style: TextStyle(fontSize: 12)),
              );
              if (constraints.maxWidth < 520) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Wrap(spacing: 4, runSpacing: 6, children: examples),
                    const SizedBox(height: 8),
                    Align(alignment: Alignment.centerRight, child: button),
                  ],
                );
              }
              return Row(children: [...examples, const Spacer(), button]);
            },
          ),
        ],
      ),
    );
  }

  Widget _briefHints(BuildContext context) {
    final p = context.palette;
    // 手机没有键盘：快捷键提示不显示，只留可点的动作。
    final narrow = MediaQuery.sizeOf(context).width < 700;
    return Row(
      children: [
        if (!narrow) ...[
          Text('${modCombo('⌘↵')} 开始', style: TextStyle(fontSize: 10, color: p.ink4)),
          const SizedBox(width: 10),
        ],
        InkWell(
          onTap: () => showNewProjectFlow(context),
          child: Text('空白项目', style: TextStyle(fontSize: 10, color: p.ink4)),
        ),
        const SizedBox(width: 10),
        InkWell(
          onTap: () => openProjectFlow(context, ''),
          child: Text('打开 DDP', style: TextStyle(fontSize: 10, color: p.ink4)),
        ),
      ],
    );
  }

  /// 插件工作台入口区（3D / 视频工作台）：主页呈现插件内容——注册表
  /// 驱动（pluginRegistry），新增插件即自动出现在主页。
  Widget _workbenchCard(BuildContext context, AppStore store) {
    final p = context.palette;
    final statuses = {
      'three': store.settings.threeProjectName.isEmpty ? '未开始' : store.settings.threeProjectName,
      'video': '无声版 · 六类标杆示例',
      'hotapp': 'HTML + SQLite · 覆盖即热更新',
    };
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: p.panel.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('工作台', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1.1, color: p.ink4)),
          const SizedBox(height: 8),
          for (final def in pluginRegistry)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: InkWell(
                onTap: () => store.setView('plugin:${def.id}'),
                borderRadius: BorderRadius.circular(9),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                  decoration: BoxDecoration(
                    color: p.panel2.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(9),
                    border: Border.all(color: p.line),
                  ),
                  child: Row(children: [
                    Icon(def.icon, size: 17, color: p.accent),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(def.title, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: p.ink)),
                        Text(statuses[def.id] ?? '', style: TextStyle(fontSize: 10, color: p.ink4), maxLines: 1, overflow: TextOverflow.ellipsis),
                      ]),
                    ),
                    Icon(Icons.chevron_right, size: 15, color: p.ink4),
                  ]),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 作品集入口卡：聚合热应用/视频/3D 三类产物，快速查看与使用。
  Widget _portfolioCard(BuildContext context, AppStore store) {
    final p = context.palette;
    return InkWell(
      onTap: () => store.setView('portfolio'),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
          color: p.panel.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: p.line),
        ),
        child: Row(children: [
          Icon(Icons.collections_bookmark_outlined, size: 18, color: p.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('作品集', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: p.ink)),
              Text('热应用 · 视频 · 3D 场景——生成过的都在这里', style: TextStyle(fontSize: 10, color: p.ink4)),
            ]),
          ),
          Icon(Icons.chevron_right, size: 15, color: p.ink4),
        ]),
      ),
    );
  }

  Widget _recentCard(BuildContext context, AppStore store) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: p.panel.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('最近项目', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1.1, color: p.ink4)),
              const Spacer(),
              InkWell(
                onTap: () => openProjectFlow(context, ''),
                child: Text('打开…', style: TextStyle(fontSize: 10, color: p.ink4)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (store.recent.isEmpty && store.serverProjects.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 18),
              decoration: BoxDecoration(
                border: Border.all(color: p.line, style: BorderStyle.solid),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text('还没有项目。上面输入一句话，马上开始。',
                  textAlign: TextAlign.center, style: TextStyle(fontSize: 10, color: p.ink4)),
            ),
          for (final r in store.recent.take(6))
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => openProjectFlow(context, r['path']?.toString() ?? ''),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
                child: Row(
                  children: [
                    Container(
                      width: 27,
                      height: 27,
                      decoration: BoxDecoration(color: p.panel2, borderRadius: BorderRadius.circular(8)),
                      child: Icon(Icons.layers_outlined, size: 13, color: p.ink4),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(r['name']?.toString() ?? '', style: TextStyle(fontSize: 12, color: p.ink2)),
                          Text(relativeTime(r['ts'] is int ? r['ts'] as int : null),
                              style: TextStyle(fontSize: 10, color: p.ink4)),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right, size: 13, color: p.ink4),
                  ],
                ),
              ),
            ),
          if (store.serverProjects.isNotEmpty) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Row(
                children: [
                  Text('工作区与桌面', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1.1, color: p.ink4)),
                  const Spacer(),
                  InkWell(
                    onTap: () => store.refreshProjects(),
                    child: Padding(
                      padding: const EdgeInsets.all(3),
                      child: Icon(Icons.refresh, size: 13, color: p.ink4),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            for (final s in store.serverProjects.take(8))
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => openProjectFlow(context, s['path']?.toString() ?? ''),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
                  child: Row(
                    children: [
                      Container(
                        width: 27,
                        height: 27,
                        decoration: BoxDecoration(color: p.panel2, borderRadius: BorderRadius.circular(8)),
                        child: Icon(Icons.folder_outlined, size: 13, color: p.ink4),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(s['name']?.toString() ?? '', style: TextStyle(fontSize: 12, color: p.ink2)),
                            Text(
                              relativeTime(s['modified'] is num ? (s['modified'] as num).toInt() * 1000 : null),
                              style: TextStyle(fontSize: 10, color: p.ink4),
                            ),
                          ],
                        ),
                      ),
                      _sourceTag(s, p),
                      const SizedBox(width: 4),
                      Icon(Icons.chevron_right, size: 13, color: p.ink4),
                    ],
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _sourceTag(Map<String, dynamic> entry, NonPalette p) {
    final desktop = entry['source'] == 'desktop';
    // NonPalette 令牌随主题切换：硬编码的 accent.dark/品牌粉在浅色主题下
    // 「桌面」标签近乎不可读（≈1.9:1）；accent2 是品牌辅助色的主题化形态。
    final color = desktop ? p.accent2 : p.accent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(desktop ? '桌面' : '工作区', style: TextStyle(fontSize: 10, color: color)),
    );
  }

  Widget _howCard(BuildContext context, NonPalette p) {
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: p.panel.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('NON 的工作方式', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1.1, color: p.ink4)),
          const SizedBox(height: 9),
          for (final row in [
            ('01', '描述', '说清问题、受众与想要的作品形态'),
            ('02', '规范', '文档、配色与设计规范先行'),
            ('03', '生成', '原型 / 3D / 视频 / 热应用按需产出'),
            ('04', '打磨', '门校验、对话修改、所有操作可撤销'),
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: 7),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 16, child: Text(row.$1, style: TextStyle(fontSize: 10, fontFamily: 'Menlo', color: p.accent))),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(row.$2, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: p.ink2)),
                        Text(row.$3, style: TextStyle(fontSize: 10, height: 1.4, color: p.ink4)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _DotsPainter extends CustomPainter {
  final Color color;
  _DotsPainter(this.color);
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    const step = 24.0;
    for (double x = 0; x < size.width; x += step) {
      for (double y = 0; y < size.height; y += step) {
        canvas.drawCircle(Offset(x, y), 0.9, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DotsPainter old) => old.color != color;
}
