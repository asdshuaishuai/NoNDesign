// 全屏视图/启动路径的源码契约测试（widget 化全屏 WebView 在测试环境
// 依赖平台通道，这里断言结构不变量——与仓库 test_studio 的静态防线同法）。
//
// 覆盖 nav-1/nav-2/tests-5/mobile-1 的回归点：
//  - 无项目时 portfolio 仍路由到 Workspace；plugin:<id> 与设计画布共用同一套
//    外壳（2026-11-20 外壳统一），插件内容进主区、同一 Scaffold 宿主；
//  - 全屏视图在 Scaffold 内（其 SnackBar 才有 ScaffoldMessenger 宿主）；
//  - 热应用/作品集顶栏有返回设计出口；
//  - boot 先读设置再 launch（连接桌面地址赶得上本次启动）；
//  - ⌘N/⌘O/⌘S/⌘Z/⌘K 只在根级绑定，不在 workspace 重复。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  test('Workspace routes portfolio out of the design chrome; plugin shares the unified chrome', () {
    final ws = _read('lib/widgets/workspace.dart');
    expect(ws.contains("store.view == 'portfolio'"), isTrue);
    expect(
      RegExp(r"store\.view == 'portfolio'[\s\S]{0,200}Scaffold").hasMatch(ws),
      isTrue,
      reason: 'portfolio 早退必须包 Scaffold（SnackBar 宿主）',
    );
    // 用户裁决 2026-11-20：插件工作台不再整页替换 Workspace 的 Scaffold，
    // 而是与设计画布共用同一套外壳（workspace_chrome.dart）——插件内容只是
    // 主区 `WorkspaceMainArea` 里的内容，仍是同一个 Scaffold 宿主。
    expect(
      ws.contains('pluginWorkspaceFor(store.view)'),
      isTrue,
      reason: '插件视图经注册表路由进主区',
    );
    expect(ws.contains('WorkspaceChrome('), isTrue, reason: '四个工作台共用同一套壳骨架');
    expect(ws.contains('_center(store, pluginView)'), isTrue, reason: '插件内容是主区内容');
    final chrome = _read('lib/widgets/workspace_chrome.dart');
    expect(chrome.contains('WorkspaceMainArea'), isTrue,
        reason: '插件内容与设计画布共用主区容器');
    expect(chrome.contains('titleBar'), isTrue, reason: '外壳含标题栏');
    expect(chrome.contains('statusBar'), isTrue, reason: '外壳含状态栏');
    expect(ws.contains('LayoutBuilder'), isTrue, reason: '窄屏断点');
  });

  test('App routes only play/portfolio out of the shell; plugin stays in it', () {
    final main = _read('lib/main.dart');
    expect(main.contains("store.view == 'portfolio'"), isTrue);
    // 2026-11-18：3D / 视频 / 热应用（plugin:*）必须留在响应式壳里，右侧 NaN
    // 窄栏常驻。main.dart 的全幅路由只剩 play / portfolio 两项。
    expect(
      RegExp(r"if \(store\.view == 'portfolio' \|\| store\.view == 'play'\)")
          .hasMatch(main),
      isTrue,
      reason: '全幅路由只允许 play / portfolio',
    );
    // Esc 仍覆盖作品集与插件工作台（返回设计面）。
    expect(main.contains("store.view.startsWith('plugin:')"), isTrue);
    // Esc 也覆盖作品集（不只 plugin:）
    expect(
      RegExp(r"store\.view == 'portfolio' \|\| store\.view\.startsWith\('plugin:'\)").hasMatch(main),
      isTrue,
    );
  });

  test('All full-screen views expose a visible back control', () {
    // 2026-11-19 用户裁决：3D / 视频 / 热应用是彼此独立的workspace，不属于
    // 某个 ddp，所以返回出口是**主页**（不是设计项目）；作品集是设计项目的
    // 展示态，仍回设计面。
    for (final path in [
      'lib/widgets/hotapp_workspace.dart',
      'lib/widgets/three_workspace.dart',
      'lib/widgets/video_workspace.dart',
    ]) {
      final source = _read(path);
      expect(source.contains('Icons.arrow_back'), isTrue, reason: path);
      expect(source.contains("setView('home')"), isTrue, reason: path);
    }
    final portfolio = _read('lib/widgets/portfolio_view.dart');
    expect(portfolio.contains('Icons.arrow_back'), isTrue);
    expect(portfolio.contains("setView('design')"), isTrue);
  });

  test('boot reads settings before building runtimes; no Python spawn remains', () {
    final store = _read('lib/core/store.dart');
    final api = _read('lib/core/api.dart');

    // Ordering: preferences (connect-desktop address + token) → local engine →
    // remote client. The opposite order made a saved address miss the launch.
    final prefs = store.indexOf('SharedPreferences.getInstance()');
    final local = store.indexOf('_startLocalEngine()');
    final remote = store.indexOf('_buildRemoteClient()');
    expect(prefs, greaterThan(0));
    expect(local, greaterThan(prefs), reason: '本地引擎在设置之后启动');
    expect(remote, greaterThan(local), reason: '连接桌面客户端最后构建（地址来自设置）');

    // Python runtime is gone from the client: no process spawn, no port file,
    // no fixed port, no env-var server discovery.
    for (final forbidden in [
      'ServerLauncher',
      'Process.start',
      'server/main.py',
      'NONDESIGN_SERVER',
      'NONDESIGN_PYTHON',
      'NONDESIGN_ROOT',
      'server.json',
      '--port',
    ]) {
      expect(store.contains(forbidden), isFalse, reason: 'store.dart 不得再出现 $forbidden');
      expect(api.contains(forbidden), isFalse, reason: 'api.dart 不得再出现 $forbidden');
    }

    // A configured desktop that cannot be reached is a visible boot error.
    expect(
      RegExp(r'if \(!status\.connected\)[\s\S]{0,600}bootError\s*=\s*mobileDegradedBootError\(')
          .hasMatch(store),
      isTrue,
      reason: '连不上必须显性报错，不能静默回落本地',
    );
    expect(store.contains('WasmRuntimeGate.mobileLocalEngineEnabled'), isTrue,
        reason: '移动端本地引擎受设备验证开关约束');
  });

  test('Mobile PLAN is cancellable and establishes a minimal project state', () {
    final store = _read('lib/core/store.dart');
    // 2026-11-17 chat-stream 改造：取消令牌从 _mobileCancel 泛化为内置
    // Dart 循环通用的 _dartAgentCancel（桌面 agentRuntime=dart 同路径）；
    // genkit 迁移后令牌经 CancellationController 创建（cooperative cancel
    // 透传 generate），cancelAgent 读控制器调用 cancel。行为契约不变：
    // 可取消 / docs-only recovery / PLAN 成功建最小项目态。
    expect(store.contains('CancellationController()'), isTrue);
    expect(store.contains('abortSignal: _dartAgentCancel?.token'), isTrue);
    expect(
      RegExp(r'final controller = _dartAgentCancel;[\s\S]{0,200}controller\.cancel\(\)').hasMatch(store),
      isTrue,
      reason: 'cancelAgent 必须读到控制器并真实调用 cancel（本地中断）',
    );
    expect(store.contains('docsOnly'), isTrue, reason: '移动端 docs-only recovery');
    expect(
      RegExp(r"if \(!orphaned && success && mode == 'plan' && !hasProject\)[\s\S]{0,400}hasProject = true")
          .hasMatch(store),
      isTrue,
      reason: '移动 PLAN 成功必须建最小项目态',
    );
    expect(store.contains('Platform.isIOS'), isTrue);
  });

  test('Video module is code animation: no render job surface can leave a spinner', () {
    // 用户裁决 2026-11-18：视频是**代码动画**，逐帧由算式生成、在应用内实时
    // 播放，不落 mp4；导出成片暂时屏蔽。渲染任务/轮询面整体删除，因此旧
    // 「死任务停轮询」的契约不再适用——这里锁的是「渲染面不会再回来」。
    final video = _read('lib/widgets/video_workspace.dart');
    final surface = _read('lib/widgets/video_animation_surface.dart');
    for (final banned in const [
      'startRender',
      '渲染（后台）',
      '_poll',
      'VideoRenderJob',
      'supportsVideoRender',
    ]) {
      expect(video.contains(banned), isFalse, reason: '$banned 不得留在视频工作台');
    }
    expect(video.contains('VideoAnimationSurface'), isTrue,
        reason: '视频工作台主面必须是代码动画播放器');
    expect(surface.contains('frameSvg'), isTrue,
        reason: '逐帧画面由算式生成（frameSvg），不是解码视频');
    expect(surface.contains('SvgPicture'), isTrue, reason: '帧用矢量绘制');
    // 旧存档里残留的渲染任务号没有对应界面：进工作台必须静默清掉。
    expect(video.contains("store.setVideoState(job: '')"), isTrue,
        reason: '旧渲染任务号不能继续占着设置');
  });

  test('Workspace-level shortcuts are not duplicated at app root', () {
    final main = _read('lib/main.dart');
    final ws = _read('lib/widgets/workspace.dart');
    for (final key in ['keyK', 'keyS', 'keyN', 'keyO', 'keyZ']) {
      expect(main.contains('LogicalKeyboardKey.$key'), isTrue, reason: '$key 应在根级');
      expect(ws.contains('LogicalKeyboardKey.$key'), isFalse, reason: '$key 不应在 workspace 重复绑定');
    }
  });
}
