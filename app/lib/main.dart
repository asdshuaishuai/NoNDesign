import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'core/keys.dart';
import 'core/layout.dart';
import 'core/mediapipe_embedder_adapter.dart';
import 'core/mediapipe_service.dart';
import 'core/nonapp_intake.dart';
import 'core/orientation.dart';
import 'core/platform_capabilities.dart';
import 'core/store.dart';
import 'core/theme.dart';
import 'widgets/command_palette.dart';
import 'widgets/common.dart';
import 'widgets/settings_dialog.dart';
import 'widgets/shell_host.dart';
import 'widgets/toast_host.dart';
import 'widgets/workspace.dart';

/// 根级快捷键需要 Navigator 内的 context 才能弹对话框（命令面板/新建/
/// 打开）；MaterialApp.navigatorKey 是这些全局动作的唯一入口。
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // MediaPipe 生产接线（N6/M1）：唯一 import mediapipe 包的 adapter 在独立
  // isolate 里加载模型/推理；服务层与测试只认 MediaPipeEmbedder 接口。
  // 模型缺失/平台不支持时服务层返回 unavailable，艺术架检索自动退化关键词。
  MediaPipeService.defaultEmbedderFactory = createMediaPipeEmbedder;
  runApp(
    ChangeNotifierProvider(
      create: (_) {
        final store = AppStore();
        // 切项目「保存 / 放弃 / 取消」与口令询问的唯一 UI 出口。判定本身
        // 在 store 主路径（newProject/openProjectPath），这里只提供 Navigator。
        store.confirmUnsavedChanges = _confirmUnsavedChanges;
        store.passwordPrompt = _askProjectPassword;
        store.boot();
        return store;
      },
      child: const NonApp(),
    ),
  );
}

/// 移动适配方向门宿主：手机锁竖屏、平板跟随系统旋转（横屏=桌面壳、
/// 竖屏=聊天优先壳）；桌面宿主是 no-op，行为不变（移动适配 2026-11-19）。
class NonApp extends StatefulWidget {
  const NonApp({super.key});

  @override
  State<NonApp> createState() => _NonAppState();
}

class _NonAppState extends State<NonApp> with WidgetsBindingObserver {
  bool get _isMobile {
    final os = PlatformCapabilities.current().os;
    return os == HostOs.ios || os == HostOs.android;
  }

  @override
  void initState() {
    super.initState();
    if (_isMobile) {
      WidgetsBinding.instance.addObserver(this);
      // 首帧后视图尺寸才可信：拿到第一个真实 metrics 就把方向门钉下来
      //（手机竖屏锁定 / 平板四向）。
      WidgetsBinding.instance.addPostFrameCallback((_) => _applyGate());
    }
  }

  @override
  void dispose() {
    if (_isMobile) WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    // 旋转 / 分屏 / 折叠屏展开都会走这里：手机永远被压回竖屏，
    // 平板按当前短边重新决定四向或竖屏。
    _applyGate();
  }

  void _applyGate() {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) return;
    applyDeviceOrientationFor(views.first);
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final dark = store.settings.theme != 'light';
    return MaterialApp(
      title: 'NaN',
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
        return DefaultTextStyle(
            style: platformDefaultTextStyle,
            child: withResponsiveTextScale(
          context,
          // 通知宿主（批次 04）挂在整个路由树之上：对话框/设置/命令面板之上
          // 也能看到通知，且不依赖 Scaffold / ScaffoldMessenger。
          ToastHost(
            child: FocusScope(
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
                  // 3D / 视频 / 热应用没有「就地切工作台」的快捷键（用户裁决
                  // 2026-11-19：工作台类型由项目决定）。进这些工作台要么打开
                  // 对应项目（顶栏项目菜单 / 主页作品集 / 艺术架），要么让 NaN
                  // 在工作区模式下建一个。
                  // Esc：插件视图与作品集（均无设计板）的返回设计出口（镜像
                  // 各全屏视图顶栏返回按钮）；聊天优先壳（手机/竖屏平板）里
                  // 设计面按 Esc 回到聊天主面。桌面壳没有整块聊天路由——Esc
                  // 不抢工作区（聊天在右侧窄栏里随时可达）。
                  // 有对话框/浮层在场（焦点路由非当前路由或本身是 PopupRoute）
                  // 时不消费——交给浮层自身处理。
                  SingleActivator(LogicalKeyboardKey.escape): () {
                    // 顺序固定：fullscreen_view_test 锚定
                    // `store.view == 'portfolio' || store.view.startsWith('plugin:')`
                    // 这段连续文本（作品集与插件工作台必须同路）。
                    final fromShell = store.view == 'portfolio' ||
                        store.view.startsWith('plugin:') ||
                        store.view == 'play';
                    final chatFirst = _usesChatFirstShell(context);
                    if (!fromShell && !(store.view == 'design' && chatFirst)) {
                      return;
                    }
                    final fctx = FocusManager.instance.primaryFocus?.context;
                    final route = fctx == null ? null : ModalRoute.of(fctx);
                    if (route == null || !route.isCurrent || route is PopupRoute) return;
                    // 插件工作区彼此独立：Esc 回**主页**（不是回某个设计项目）；
                    // 作品集/演示仍回设计面（它们是设计项目的展示态）。
                    store.setView(
                        store.view.startsWith('plugin:') ? 'home' : (fromShell ? 'design' : 'chat'));
                  },
                },
                child: child ?? const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      );
      },
      // 应用级 ExcludeSemantics：Flutter macOS 引擎的无障碍桥在 macOS 27.2
      // 上被 AX 客户端激活后，逐帧语义更新经 AccessibilityBridgeMac 触发
      // doesNotRecognizeSelector → SIGABRT（2026-11-14 崩溃报告实证）。语义树
      // 对本工具无价值纯成本，整树排除后引擎侧不再产生 AX 事件，崩溃路径
      // 不可达；待上游修复后移除。
      // NonAppIntakeHost：OS 文件关联（.nonapp 双击/拖入）的唯一编译期
      // 挂载点——接管 `nc/open` 通道与冷启动队列；无 handler/未接线平台
      // 零行为（Linux/Windows/测试宿主静默降级）。
      home: NonAppIntakeHost(
        child: ExcludeSemantics(
          child: store.bootError != null
              ? _BootError(message: store.bootError!)
              : !store.ready
                  ? const _BootScreen()
                  // 响应式壳（批次 12）：手机/iPad 竖屏 = 聊天全屏 + 工作区
                  // 画中画；桌面/iPad 横屏 = 工作区/Welcome + 右侧聊天窄栏。
                  // 四档由 core/layout.dart 单点裁决，这里不再有 view=='chat'
                  // 的整块路由，也不再用 chatStreamHome 决定桌面主面。
                  : _WindowThemeSync(dark: dark, child: _routeFor(store)),
        ),
      ),
    );
  }

  /// 整壳全幅视图先于响应式壳：只有 play / portfolio 不吃右侧窄栏。
  ///
  /// 四个工作区里的三个（3D / 视频 / 热应用）都走 `plugin:*`，它们**必须**
  /// 留在响应式壳里：桌面壳左侧是固定工作区、右侧是常驻 NaN 窄栏（用户
  /// 裁决 2026-11-18：所有内容都通过 NaN 交互，工作区里不能没有它）。
  /// 手机/iPad 聊天优先壳由 [ChatPiPShell] 自己把 plugin 视图渲染成整屏。
  Widget _routeFor(AppStore store) {
    if (store.view == 'portfolio' || store.view == 'play') {
      // 无项目也必须可路由（Welcome 卡片曾点了不换屏）。
      return const Workspace();
    }
    return const ShellHost();
  }
}

/// 当前视口是否属于聊天优先壳（手机竖屏——横屏仅为方向门兜底、真机不可达；
/// iPad 竖屏）。
///
/// Esc 的「设计 → 聊天」只在聊天优先壳里成立：桌面壳的聊天在右侧窄栏，
/// 不存在整块聊天路由可回。
bool _usesChatFirstShell(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  return LayoutSpec.classifyHost(
    PlatformCapabilities.current(),
    width: size.width,
    height: size.height,
  ).usesChatFirstShell;
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

/// 切换项目前的未保存改动确认（store 主路径调用的唯一 UI 出口）。
///
/// 没有 Navigator（极早期/无 UI 宿主）时按取消处理：宁可不让切换，
/// 也不静默丢掉当前项目的文档与画布。
Future<UnsavedChoice> _confirmUnsavedChanges(String action) async {
  final ctx = _navigatorContext();
  if (ctx == null) return UnsavedChoice.cancel;
  final choice = await showNonDialog<UnsavedChoice>(
    context: ctx,
    builder: (_) => _UnsavedChangesDialog(action: action),
  );
  return choice ?? UnsavedChoice.cancel;
}

/// 受口令保护的项目需要口令时（恢复崩溃快照 / 保存加锁项目）。
///
/// 返回 null 表示取消——调用方据此不恢复、不写盘。
Future<String?> _askProjectPassword(String? path) async {
  final ctx = _navigatorContext();
  if (ctx == null) return null;
  return showNonDialog<String>(
    context: ctx,
    builder: (_) => PasswordDialog(path: path ?? '', retry: false),
  );
}

/// 「保存 / 放弃 / 取消」三选一。
class _UnsavedChangesDialog extends StatelessWidget {
  final String action;
  const _UnsavedChangesDialog({required this.action});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return AlertDialog(
      backgroundColor: p.panel,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16), side: BorderSide(color: p.lineStrong)),
      title: const Text('还有未保存的改动',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
      content: SizedBox(
        width: 380,
        child: Text(
          '$action会替换当前项目的内容。要先把现在的改动保存下来吗？',
          style: TextStyle(fontSize: 12, height: 1.6, color: p.ink3),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(UnsavedChoice.cancel),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(UnsavedChoice.discard),
          child: const Text('放弃改动'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(UnsavedChoice.save),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

/// 启动画面：品牌化加载动画——logo 呼吸 + 光晕脉动 + 细进度条，
/// 不再出现任何运行时服务或连接方式字样。
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
            Text('NaN', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: p.ink, letterSpacing: -0.3)),
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
              Text('可以先重试；或打开设置调整「连接桌面」；也可以先离线继续查看已恢复的内容。',
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

