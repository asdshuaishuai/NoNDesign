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

  test('boot loads settings before launching the server and degrades on mobile', () {
    final store = _read('lib/core/store.dart');
    final prefs = store.indexOf('SharedPreferences.getInstance()');
    final launch = store.indexOf('ServerLauncher.launch()');
    expect(prefs, greaterThan(0));
    expect(launch, greaterThan(prefs), reason: 'manualBaseUrl 必须先于 launch 就位');
    expect(store.contains('Platform.isIOS'), isTrue, reason: '移动端 launch 失败降级');
    expect(store.contains('manualBaseUrl = settings.serverUrl'), isTrue);
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
    final video = _read('lib/widgets/video_workspace.dart');
    expect(
      RegExp(r"res\['ok'\] != true[\s\S]{0,900}store\.setVideoState\(job: ''\)").hasMatch(video),
      isTrue,
      reason: '404/!ok 必须清 _job/_busy 与持久化 job',
    );
    expect(
      RegExp(r"_job = null;[\s\S]{0,400}_busy = false").hasMatch(video),
      isTrue,
      reason: '终态必须同时清在飞 job 与 spinner',
    );
    expect(
      RegExp(r"status.*== 'done'.*status.*== 'failed'[\s\S]{0,900}store\.setVideoState\(job: ''\)").hasMatch(video),
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
