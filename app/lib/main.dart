import 'package:flutter/material.dart';
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
                  : Welcome(
                      onNewProject: () => showNewProjectFlow(context),
                      onOpenPath: (path) => openProjectFlow(context, path),
                      onSettings: () => showSettingsDialog(context),
                    ),
    );
  }
}

class _BootScreen extends StatelessWidget {
  const _BootScreen();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Scaffold(
      backgroundColor: p.bg,
      body: Stack(
        children: [
          Positioned.fill(child: CustomPaint(painter: _BootGlow(p.accent))),
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const NonLogo(size: 52),
                const SizedBox(height: 16),
                Text('NoNDesign', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w600, color: p.ink)),
                const SizedBox(height: 6),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.6, color: p.accent)),
                    const SizedBox(width: 8),
                    Text('正在启动 Python 引擎与模型清单…', style: TextStyle(fontSize: 11, color: p.ink3)),
                  ],
                ),
              ],
            ),
          ),
          Positioned(
            bottom: 20,
            left: 0,
            right: 0,
            child: Text('canonical .mbt.md · engine-gated · local-first',
                textAlign: TextAlign.center, style: TextStyle(fontSize: 9, color: p.ink4)),
          ),
        ],
      ),
    );
  }
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

class _BootGlow extends CustomPainter {
  final Color accent;
  _BootGlow(this.accent);
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final paint = Paint()
      ..shader = RadialGradient(colors: [accent.withValues(alpha: 0.18), Colors.transparent])
          .createShader(Rect.fromCircle(center: center, radius: 320));
    canvas.drawCircle(center, 320, paint);
  }

  @override
  bool shouldRepaint(covariant _BootGlow old) => old.accent != accent;
}
