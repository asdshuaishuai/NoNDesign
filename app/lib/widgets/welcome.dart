import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/keys.dart';
import '../core/store.dart';
import '../core/theme.dart';
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
    final providerCount = store.registry.providers.length;
    final modelCount = store.registry.flatten().length;
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
          Column(
            children: [
              Container(
                height: 60,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    const NonLogo(size: 26),
                    const SizedBox(width: 9),
                    Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('NoNDesign', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: p.ink)),
                        Text('AI PRODUCT DESIGN STUDIO',
                            style: TextStyle(fontSize: 8, letterSpacing: 1.6, color: p.ink4)),
                      ],
                    ),
                    const Spacer(),
                    const SizedBox(width: 6),
                    Pill(label: '$providerCount 服务商 · $modelCount 模型'),
                    const SizedBox(width: 6),
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
              Expanded(
                child: Center(
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
                                      Text('一句话 → 设计文档 → 可交互原型',
                                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w500, color: p.accent)),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 14),
                                ShaderMask(
                                  shaderCallback: (bounds) => const LinearGradient(
                                    colors: [Color(0xFF7C8CFF), Color(0xFFB58CFF), Color(0xFFFF9BD2)],
                                  ).createShader(bounds),
                                  child: const Text('把想法变成\n可以点的产品',
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
                                  '描述目标用户和核心流程。NoN 会先写 PRD、UI 说明与设计规范，再把每一屏画到画布上，'
                                  '连线、状态、交互都经 MoonViz 引擎校验。',
                                  style: TextStyle(fontSize: 12.5, height: 1.65, color: p.ink3),
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
                                        Text('检测到上次未保存的工作', style: TextStyle(fontSize: 10.5, color: p.warn)),
                                        const Spacer(),
                                        TextButton(onPressed: store.restoreRecovery, child: const Text('恢复', style: TextStyle(fontSize: 10.5))),
                                        TextButton(onPressed: store.discardRecovery, child: const Text('忽略', style: TextStyle(fontSize: 10.5))),
                                      ],
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 22),
                                Container(
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
                                          hintStyle: TextStyle(fontSize: 12.5, height: 1.55, color: p.ink4),
                                          border: InputBorder.none,
                                          enabledBorder: InputBorder.none,
                                          focusedBorder: InputBorder.none,
                                          filled: false,
                                          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                                        ),
                                        onSubmitted: (_) => _start(store),
                                      ),
                                      Row(
                                        children: [
                                          for (final example in ['电商 App', 'SaaS 仪表盘', 'AI 助手', '个人作品集'])
                                            Padding(
                                              padding: const EdgeInsets.only(right: 4),
                                              child: InkWell(
                                                borderRadius: BorderRadius.circular(5),
                                                onTap: () => _brief.text = '做一个$example：先写 PRD 与 UI 说明，再生成完整可交互原型。移动端优先，风格现代克制。',
                                                child: Container(
                                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                                                  decoration: BoxDecoration(color: p.panel2, borderRadius: BorderRadius.circular(5)),
                                                  child: Text(example, style: TextStyle(fontSize: 9.5, color: p.ink3)),
                                                ),
                                              ),
                                            ),
                                          const Spacer(),
                                          FilledButton.icon(
                                            style: FilledButton.styleFrom(
                                              backgroundColor: p.accent,
                                              foregroundColor: Colors.white,
                                              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
                                            ),
                                            onPressed: store.agentBusy ? null : () => _start(store),
                                            icon: store.agentBusy
                                                ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5))
                                                : const Icon(Icons.auto_awesome, size: 13),
                                            label: const Text('开始设计', style: TextStyle(fontSize: 12)),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 10),
                                Row(
                                  children: [
                                    Text('${modCombo('⌘↵')} 开始', style: TextStyle(fontSize: 9, color: p.ink4)),
                                    const SizedBox(width: 10),
                                    InkWell(
                                      onTap: () => showNewProjectFlow(context),
                                      child: Text('空白项目', style: TextStyle(fontSize: 9, color: p.ink4)),
                                    ),
                                    const SizedBox(width: 10),
                                    InkWell(
                                      onTap: () => openProjectFlow(context, ''),
                                      child: Text('打开 DDP', style: TextStyle(fontSize: 9, color: p.ink4)),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 44),
                          Expanded(
                            flex: 4,
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
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
                child: Text('NoNDesign v0.1 · MoonViz engine · 模型与端点来自 models.dev · 所有操作可撤销',
                    style: TextStyle(fontSize: 9, color: p.ink4)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _recentCard(BuildContext context, AppStore store) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: p.panel.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: p.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('最近项目', style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w700, letterSpacing: 1.1, color: p.ink4)),
              const Spacer(),
              InkWell(
                onTap: () => openProjectFlow(context, ''),
                child: Text('打开…', style: TextStyle(fontSize: 9.5, color: p.ink4)),
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
                borderRadius: BorderRadius.circular(9),
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
                      decoration: BoxDecoration(color: p.panel2, borderRadius: BorderRadius.circular(7)),
                      child: Icon(Icons.layers_outlined, size: 13, color: p.ink4),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(r['name']?.toString() ?? '', style: TextStyle(fontSize: 11.5, color: p.ink2)),
                          Text(relativeTime(r['ts'] is int ? r['ts'] as int : null),
                              style: TextStyle(fontSize: 9, color: p.ink4)),
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
                  Text('工作区与桌面', style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w700, letterSpacing: 1.1, color: p.ink4)),
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
                        decoration: BoxDecoration(color: p.panel2, borderRadius: BorderRadius.circular(7)),
                        child: Icon(Icons.folder_outlined, size: 13, color: p.ink4),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(s['name']?.toString() ?? '', style: TextStyle(fontSize: 11.5, color: p.ink2)),
                            Text(
                              relativeTime(s['modified'] is num ? (s['modified'] as num).toInt() * 1000 : null),
                              style: TextStyle(fontSize: 9, color: p.ink4),
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
    final color = desktop ? const Color(0xFFFF9BD2) : const Color(0xFF7C8CFF);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(desktop ? '桌面' : '工作区', style: TextStyle(fontSize: 8.5, color: color)),
    );
  }

  Widget _howCard(BuildContext context, NonPalette p) {
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: p.panel.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: p.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('NON 的工作方式', style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w700, letterSpacing: 1.1, color: p.ink4)),
          const SizedBox(height: 9),
          for (final row in [
            ('01', '理解', '从 brief 推导页面图与核心流程'),
            ('02', '规范', '先定配色、字号、间距与圆角'),
            ('03', '生成', '逐屏生成并自检引擎规范'),
            ('04', '连线', '把可点元素接到目标画板'),
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: 7),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 16, child: Text(row.$1, style: TextStyle(fontSize: 8.5, fontFamily: 'Menlo', color: p.accent))),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(row.$2, style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w500, color: p.ink2)),
                        Text(row.$3, style: TextStyle(fontSize: 9, height: 1.4, color: p.ink4)),
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
