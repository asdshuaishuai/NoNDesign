import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'core/store.dart';
import 'core/theme.dart';
import 'widgets/common.dart';
import 'widgets/settings_dialog.dart';
import 'widgets/welcome.dart';
import 'widgets/workspace.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    ChangeNotifierProvider(
      create: (_) => AppStore()..boot(),
      child: const NonApp(),
    ),
  );
}

class NonApp extends StatelessWidget {
  const NonApp({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final dark = store.settings.theme != 'light';
    return MaterialApp(
      title: 'NoNDesign',
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: rootMessengerKey,
      theme: AppTheme.build(dark: dark),
      home: store.bootError != null
          ? _BootError(message: store.bootError!)
          : !store.ready
              ? const _BootScreen()
              : store.hasProject
                  ? const Workspace()
                  // Builder：回调的 context 必须落在 MaterialApp（Navigator 子树）
                  // 之内——NonApp 自己的 context 在其上层，showDialog/流程入口
                  // 会以 "does not include a Navigator" 崩溃（2026-11-13 实证）。
                  : _WindowThemeSync(
                    dark: dark,
                    child: Builder(
                      builder: (ctx) => Welcome(
                        onNewProject: () => showNewProjectFlow(ctx),
                        onOpenPath: (path) => openProjectFlow(ctx, path),
                        onSettings: () => showSettingsDialog(ctx),
                      ),
                    ),
                  ),
    );
  }
}

/// 启动画面：品牌化加载动画——logo 呼吸 + 光晕脉动 + 细进度条，
/// 不再出现任何运行时（Python 等）字样。
class _BootScreen extends StatefulWidget {
  const _BootScreen();

  @override
  State<_BootScreen> createState() => _BootScreenState();
}

class _BootScreenState extends State<_BootScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Scaffold(
      backgroundColor: p.bg,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedBuilder(
              animation: _c,
              builder: (context, _) {
                // 0→1→0 呼吸：光晕随相位胀缩，logo 轻微缩放。
                final phase = 0.5 - 0.5 * math.cos(_c.value * math.pi * 2);
                return SizedBox(
                  width: 160,
                  height: 160,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Container(
                        width: 110 + phase * 44,
                        height: 110 + phase * 44,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(colors: [
                            p.accent.withValues(alpha: 0.10 + 0.14 * phase),
                            Colors.transparent,
                          ]),
                        ),
                      ),
                      Transform.scale(scale: 0.95 + 0.06 * phase, child: const NonLogo(size: 52)),
                    ],
                  ),
                );
              },
            ),
            const SizedBox(height: 18),
            Text('NoNDesign', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w600, color: p.ink, letterSpacing: -0.3)),
            const SizedBox(height: 16),
            SizedBox(
              width: 168,
              child: LinearProgressIndicator(
                minHeight: 2,
                color: p.accent,
                backgroundColor: p.line,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 12),
            AnimatedBuilder(
              animation: _c,
              builder: (context, _) {
                final dots = '.' * (1 + ((_c.value * 3).floor() % 3));
                return Text('正在就绪$dots', style: TextStyle(fontSize: 10.5, color: p.ink3));
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// 把主题同步给 macOS 原生窗口（标题栏/背景跟随深浅主题）。
/// 非 macOS 平台没有 nc/window channel，静默跳过。
class _WindowThemeSync extends StatefulWidget {
  final bool dark;
  final Widget child;
  const _WindowThemeSync({required this.dark, required this.child});

  @override
  State<_WindowThemeSync> createState() => _WindowThemeSyncState();
}

class _WindowThemeSyncState extends State<_WindowThemeSync> {
  static const MethodChannel _ch = MethodChannel('nc/window');

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant _WindowThemeSync old) {
    super.didUpdateWidget(old);
    if (old.dark != widget.dark) _sync();
  }

  void _sync() {
    _ch.invokeMethod('setTheme', {'dark': widget.dark}).catchError((_) {});
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _BootError extends StatelessWidget {
  final String message;
  const _BootError({required this.message});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Scaffold(
      backgroundColor: p.bg,
      body: Center(
        child: Container(
          width: 460,
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            color: p.panel,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: p.danger.withValues(alpha: 0.35)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 28, color: p.danger),
              const SizedBox(height: 10),
              Text('启动失败', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: p.ink)),
              const SizedBox(height: 6),
              SelectableText(message, style: TextStyle(fontSize: 10.5, height: 1.5, fontFamily: 'Menlo', color: p.ink3)),
              const SizedBox(height: 14),
              Text('检查 .venv 依赖与 server/main.py；或设置 NONDESIGN_SERVER 指向已运行的服务。',
                  textAlign: TextAlign.center, style: TextStyle(fontSize: 10, color: p.ink4)),
            ],
          ),
        ),
      ),
    );
  }
}

