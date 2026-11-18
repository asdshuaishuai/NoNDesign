// 全屏视图/启动路径的源码契约测试（widget 化全屏 WebView 在测试环境
// 依赖平台通道，这里断言结构不变量——与仓库 test_studio 的静态防线同法）。
//
// 覆盖 nav-1/nav-2/tests-5/mobile-1 的回归点：
//  - 无项目时 portfolio / plugin:<id> 仍路由到 Workspace；
//  - 全屏视图在 Scaffold 内（其 SnackBar 才有 ScaffoldMessenger 宿主）；
//  - 热应用/作品集顶栏有返回设计出口；
//  - boot 先读设置再 launch（连接桌面地址赶得上本次启动）；
//  - ⌘N/⌘O/⌘S/⌘Z/⌘K 只在根级绑定，不在 workspace 重复。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  test('Workspace routes portfolio/plugin views without a project, inside Scaffold', () {
    final ws = _read('lib/widgets/workspace.dart');
    expect(ws.contains("store.view == 'portfolio'"), isTrue);
    expect(
      RegExp(r"store\.view == 'portfolio'[\s\S]{0,200}Scaffold").hasMatch(ws),
      isTrue,
      reason: 'portfolio 早退必须包 Scaffold（SnackBar 宿主）',
    );
    expect(
      RegExp(r"pluginView != null[\s\S]{0,160}Scaffold").hasMatch(ws),
      isTrue,
      reason: '插件工作台早退必须包 Scaffold',
    );
    expect(ws.contains('LayoutBuilder'), isTrue, reason: '窄屏断点');
  });

  test('App routes portfolio/plugin views even without hasProject', () {
    final main = _read('lib/main.dart');
    expect(main.contains("store.view == 'portfolio'"), isTrue);
    expect(main.contains("store.view.startsWith('plugin:')"), isTrue);
    // Esc 也覆盖作品集（不只 plugin:）
    expect(
      RegExp(r"store\.view == 'portfolio' \|\| store\.view\.startsWith\('plugin:'\)").hasMatch(main),
      isTrue,
    );
  });

  test('All full-screen views expose a visible back control', () {
    for (final path in [
      'lib/widgets/hotapp_workspace.dart',
      'lib/widgets/portfolio_view.dart',
      'lib/widgets/three_workspace.dart',
      'lib/widgets/video_workspace.dart',
    ]) {
      final source = _read(path);
      expect(source.contains('Icons.arrow_back'), isTrue, reason: path);
      expect(source.contains("setView('design')"), isTrue, reason: path);
    }
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
      RegExp(r'if \(!status\.connected\)[\s\S]{0,400}bootError = mobileDegradedBootError\(')
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
    // 取消即本地中断（token 透传 streamText abortSignal + cancelAgent 读
    // 令牌调用 cancel）。行为契约不变：可取消 / docs-only recovery /
    // PLAN 成功建最小项目态。
    expect(store.contains('CancellationToken()'), isTrue);
    expect(store.contains('abortSignal: _dartAgentCancel'), isTrue);
    expect(
      RegExp(r'final token = _dartAgentCancel;[\s\S]{0,200}token\.cancel\(\)').hasMatch(store),
      isTrue,
      reason: 'cancelAgent 必须读到令牌并真实调用 cancel（本地中断）',
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

  test('Restored dead video job is treated as terminal (no permanent spinner)', () {
    // 批次 08：任务从「服务端 job 号 + HTTP 轮询」改为进程内本地任务。
    // 语义不变：查无此任务/进入终态都必须停轮询、清持久化 job，绝不留下
    // 永真的 spinner。
    final video = _read('lib/widgets/video_workspace.dart');
    expect(
      RegExp(r"snapshot == null[\s\S]{0,400}store\.setVideoState\(job: ''\)").hasMatch(video),
      isTrue,
      reason: '未知任务（进程重启）必须清持久化 job',
    );
    expect(
      RegExp(r"_service\.job\(id\)[\s\S]{0,400}_poll\?\.cancel\(\)[\s\S]{0,300}_jobId = null")
          .hasMatch(video),
      isTrue,
      reason: '任务消失必须停轮询并清在飞 job',
    );
    expect(
      RegExp(r"if \(snapshot\.isRunning\) return;[\s\S]{0,300}store\.setVideoState\(job: ''\)")
          .hasMatch(video),
      isTrue,
      reason: 'done/failed 也要清持久化 videoJob',
    );
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
