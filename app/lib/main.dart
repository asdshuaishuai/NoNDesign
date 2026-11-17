import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'core/keys.dart';
import 'core/store.dart';
import 'core/theme.dart';
import 'plugins/registry.dart';
import 'widgets/chat_stream.dart';
import 'widgets/command_palette.dart';
import 'widgets/common.dart';
import 'widgets/settings_dialog.dart';
import 'widgets/welcome.dart';
import 'widgets/workspace.dart';

/// 根级快捷键需要 Navigator 内的 context 才能弹对话框（命令面板/新建/
/// 打开）；MaterialApp.navigatorKey 是这些全局动作的唯一入口。
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

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
      navigatorKey: rootNavigatorKey,
      theme: AppTheme.build(dark: dark),
      // 全局快捷键宿主（真机 CUA 实证：CallbackShortcuts 挂 Workspace 子树
      // 依赖焦点，构建刚结束/无输入焦点时 ⌘2/⌘4 全部无响应）——视图切换
      // 这类「任何时候都该生效」的键上移到 app 根，FocusScope 托管焦点。
      builder: (context, child) {
        final store = context.read<AppStore>();
        // 响应式字号：手机 +10% / 平板 +5% / 桌面 1.0（渲染期统一缩放，
        // 字号声明仍守 8 档字阶）。系统文字大小一并尊重，钳 1.0–1.3。
        return withResponsiveTextScale(context, FocusScope(
          autofocus: true,
          child: CallbackShortcuts(
            bindings: {
              // workspace 级动作上移根级：插件/作品集视图会早退 Workspace
              // 的 CallbackShortcuts，⌘N/⌘O/⌘S/⌘Z/⌘K 在这些全屏视图里
              // 曾全部失联（对应 workspace 内的重复绑定已删除）。
              modKey(LogicalKeyboardKey.keyK): _rootCommand,
              modKey(LogicalKeyboardKey.keyS): () {
                if (!_overlayRouteActive()) store.saveProject();
              },
              modKey(LogicalKeyboardKey.keyN): _rootNewProject,
              modKey(LogicalKeyboardKey.keyO): _rootOpenProject,
              modKey(LogicalKeyboardKey.keyZ): () {
                if (!_overlayRouteActive()) undoRedoShortcut(store, redo: false);
              },
              modKey(LogicalKeyboardKey.keyZ, shift: true): () {
                if (!_overlayRouteActive()) undoRedoShortcut(store, redo: true);
              },
              modKey(LogicalKeyboardKey.digit1): () => store.setView('design'),
              modKey(LogicalKeyboardKey.digit2): () => store.setView('docs'),
              modKey(LogicalKeyboardKey.digit3): () => store.setView('source'),
              modKey(LogicalKeyboardKey.digit4): () => store.setView('play'),
              modKey(LogicalKeyboardKey.digit0): () {
                store.setView('design');
                store.bumpFit();
              },
              // 插件快捷键 ⌘5/⌘6/…：根级挂载（注册表顺序派生）——
              // workspace 级 CallbackShortcuts 在插件视图内不挂载
              // （视图路由早退），插件入口键必须活在根级才能在
              // 插件视图内可达（配合各插件顶栏返回按钮与 Esc）。
              for (var i = 0; i < pluginRegistry.length && i < pluginDigitKeys.length; i++)
                modKey(pluginDigitKeys[i]): () => store.setView('plugin:${pluginRegistry[i].id}'),
              // Esc：插件视图与作品集（均无设计板）的返回设计出口（镜像
              // 各全屏视图顶栏返回按钮）；聊天流为默认主面时，设计壳内
              // Esc 返回聊天流（chat_stream 顶栏进、Esc 出，S1 最小闭环）。
              // 有对话框/浮层在场（焦点路由非当前路由或本身是 PopupRoute）
              // 时不消费——交给浮层自身处理。
              SingleActivator(LogicalKeyboardKey.escape): () {
                final fromShell =
                    store.view == 'portfolio' || store.view.startsWith('plugin:');
                if (!fromShell && !(store.view == 'design' && store.settings.chatStreamHome)) {
                  return;
                }
                final fctx = FocusManager.instance.primaryFocus?.context;
                final route = fctx == null ? null : ModalRoute.of(fctx);
                if (route == null || !route.isCurrent || route is PopupRoute) return;
                store.setView(fromShell ? 'design' : 'chat');
              },
            },
            child: child ?? const SizedBox.shrink(),
          ),
        ),
        );
      },
      // 应用级 ExcludeSemantics：Flutter macOS 引擎的无障碍桥在 macOS 27.2
      // 上被 AX 客户端激活后，逐帧语义更新经 AccessibilityBridgeMac 触发
      // doesNotRecognizeSelector → SIGABRT（2026-11-14 崩溃报告实证）。语义树
      // 对本工具无价值纯成本，整树排除后引擎侧不再产生 AX 事件，崩溃路径
      // 不可达；待上游修复后移除。
      home: ExcludeSemantics(
        child: store.bootError != null
            ? _BootError(message: store.bootError!)
          : !store.ready
              ? const _BootScreen()
              // 聊天流视图（'chat'）与作品集/插件工作台一样不依赖项目，
              // 显式进入（view=='chat'）时无条件可路由。
              : store.view == 'chat'
                  ? _WindowThemeSync(
                    dark: dark,
                    child: ChatStreamView(
                      onSettings: () {
                        final ctx = _navigatorContext();
                        if (ctx != null) showSettingsDialog(ctx);
                      },
                    ),
                  )
                  // 作品集/插件工作台不依赖项目：无项目启动也必须可路由，
                  // 否则欢迎页卡片与 ⌘5–⌘7 点了不换屏（四个入口全不可达）。
                  // 离线移动端恢复的 docs（api==null）同样走 Workspace：
                  // 否则恢复成功后 hasProject 仍 false，界面停在 Welcome，
                  // 文档虽然恢复进 store 却看不见。
                  : (store.hasProject ||
                          store.view == 'portfolio' ||
                          store.view.startsWith('plugin:') ||
                          (store.api == null && store.view == 'docs'))
                      ? const Workspace()
                      // chatStreamHome（用户决策默认开）：无项目时的默认
                      // 主面是聊天流；关闭即回经典 Welcome。
                      : store.settings.chatStreamHome
                          ? _WindowThemeSync(
                            dark: dark,
                            child: ChatStreamView(
                              onSettings: () {
                                final ctx = _navigatorContext();
                                if (ctx != null) showSettingsDialog(ctx);
                              },
                            ),
                          )
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
        ),
    );
  }
}

/// Navigator 内的 context（Overlay 是 Navigator 的子级）——GlobalKey 挂在
/// 根 Navigator 上时，currentContext 是 Navigator 自身，位于它之上，
/// showDialog 的 Navigator.of 会找不到 Navigator；overlay.context 才对。
BuildContext? _navigatorContext() => rootNavigatorKey.currentState?.overlay?.context;

/// 根级 ⌘K：命令面板需要 Navigator 内 context；有对话框/浮层在场时
/// 不叠加新面板（与 Esc 的浮层让位语义一致）。
void _rootCommand() {
  if (_overlayRouteActive()) return;
  final ctx = _navigatorContext();
  if (ctx == null) return;
  showCommandPalette(
    ctx,
    onNewProject: () => showNewProjectFlow(ctx),
    onOpenPath: (path) => openProjectFlow(ctx, path),
    onSettings: () => showSettingsDialog(ctx),
    onShortcuts: () => showShortcutsDialog(ctx),
  );
}

void _rootNewProject() {
  if (_overlayRouteActive()) return;
  final ctx = _navigatorContext();
  if (ctx == null) return;
  showNewProjectFlow(ctx);
}

void _rootOpenProject() {
  if (_overlayRouteActive()) return;
  final ctx = _navigatorContext();
  if (ctx == null) return;
  openProjectFlow(ctx, '');
}

/// 焦点是否落在 PopupRoute（对话框/命令面板）或非当前路由上——根级
/// CallbackShortcuts 活在 Navigator 之上，不挡就会在对话框里触发
/// 新建/打开/撤销等全局动作。
bool _overlayRouteActive() {
  final fctx = FocusManager.instance.primaryFocus?.context;
  final route = fctx == null ? null : ModalRoute.of(fctx);
  return route is PopupRoute || (route != null && !route.isCurrent);
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
            Text('NoNDesign', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: p.ink, letterSpacing: -0.3)),
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
                return Text('正在就绪$dots', style: TextStyle(fontSize: 11, color: p.ink3));
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
    final store = context.read<AppStore>();
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
              SelectableText(message, style: TextStyle(fontSize: 11, height: 1.5, fontFamily: 'Menlo', color: p.ink3)),
              const SizedBox(height: 14),
              Text('检查 .venv 依赖与 server/main.py；或设置 NONDESIGN_SERVER 指向已运行的服务。',
                  textAlign: TextAlign.center, style: TextStyle(fontSize: 10, color: p.ink4)),
              const SizedBox(height: 12),
              // 死屏三出路：重试（改完环境/服务器地址后）、设置（改连接
              // 桌面地址或模型）、离线继续（只看恢复文档，不碰引擎）。
              Wrap(
                spacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  OutlinedButton(
                    onPressed: () => store.retryBoot(),
                    child: const Text('重试', style: TextStyle(fontSize: 12)),
                  ),
                  TextButton(
                    onPressed: () => showSettingsDialog(context),
                    child: const Text('设置', style: TextStyle(fontSize: 12)),
                  ),
                  TextButton(
                    onPressed: () => store.continueOffline(),
                    child: const Text('离线继续', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

