// 画中画工作区 S4（docs/plan-chat-stream-shell.md §2/§5）的路由面回归：
// - view=='chat' 且宽 ≥1100：chat 与 workspace 同屏（常驻分栏）；
// - view=='design'（有项目）：只有全屏 Workspace、无 chat-input，Esc 回 chat
//   ——既有全屏语义不变（chat_stream_test 的同一锚点的 S4 复核）；
// - 折叠：只剩 chat；chat 顶栏「工作区」按钮切换折叠态；
// - 无项目空态用显式「新建空画板」建项目，且**不**隐式 setView('design')
//   （store.openWorkspace 的旧语义只在无宿主/产物卡路径保留）；
// - 嵌入宿主登记（review pip-1 的面板内路径 / pip-4）：Workspace(embedded:true)
//   的 initState/dispose 计入 AppStore，登记态下 runPlan/runBuild/runRefine 与
//   左栏「最近项目」openProjectFlow 都不把 view 切走——聊天宿主不被拆掉。
import 'dart:convert';
import 'dart:io';

import 'package:ai_sdk_dart/test.dart';
// ai_sdk_provider 是 ai_sdk_dart 的传递依赖（pubspec 未声明）；scripted mock
// 需要其流片段/结果类型来覆写 doStream（store_test 同款模式的本文件副本）。
// ignore: depend_on_referenced_packages
import 'package:ai_sdk_provider/ai_sdk_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nondesign/core/api.dart';
import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/main.dart';
import 'package:nondesign/widgets/right_panel.dart';
import 'package:nondesign/widgets/shell_host.dart';
import 'package:nondesign/widgets/workspace.dart';

AppStore _store({bool project = false}) {
  final store = AppStore();
  store.ready = true;
  store.settings = AppSettings(providerId: 'deepseek', modelId: 'deepseek-v4.1-flash');
  store.hasProject = project;
  store.projectName = '演示项目';
  store.view = 'chat';
  if (project) {
    store.mbt = '---\nmoonviz:\n  format: visual-document\n  revision: 1\n  entry: home\n---\n';
    store.render = RenderEnvelope(
      ok: true,
      entry: 'home',
      revision: 1,
      mbt: store.mbt,
      artboards: const [
        Artboard(id: 'home', name: 'home', width: 390, height: 844, nodes: []),
      ],
    );
  }
  return store;
}

Widget _wrap(AppStore store, Widget child) => ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(
        theme: AppTheme.build(dark: true),
        scaffoldMessengerKey: rootMessengerKey,
        builder: (context, child) =>
            withResponsiveTextScale(context, child ?? const SizedBox.shrink()),
        home: child,
      ),
    );

/// 走真实路由（NonApp）：view/hasProject 的分支判定与生产一致。
Widget _rootApp(AppStore store) => ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: const NonApp(),
    );

Future<void> _pumpAt(WidgetTester tester, Widget app, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(app);
  await tester.pump(const Duration(milliseconds: 150));
}

http.Response _json(Object body) => http.Response(
      body is String ? body : jsonEncode(body),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

Map<String, dynamic> _envelope([String mbt = 'MBT_1']) => {
      'ok': true,
      'mbt': mbt,
      'entry': 'home',
      'revision': 1,
      'artboards': [
        {'id': 'home', 'name': 'home', 'width': 390, 'height': 844, 'nodes': <dynamic>[]},
      ],
      'flows': <dynamic>[],
    };

/// 引擎/检视面全离线 mock：Dart 循环 run 起点（PROJECT MAP / 模板 / 组件）
/// 与终态回灌都落在这几条路由上，全程 microtask，无需真实端口。
NoNDesignApi _engineApi() => NoNDesignApi('http://mock.local', MockClient((request) async {
      switch (request.url.path) {
        case '/engine/session':
          return _json({'ok': true, 'data': []});
        case '/engine/templates':
          return _json({'ok': true, 'templates': []});
        case '/engine/components':
          return _json({'ok': true, 'components': []});
        case '/engine/apply':
          return _json(_envelope());
        case '/engine/render':
          return _json(_envelope());
      }
      return _json({'ok': false, 'detail': 'no_route'});
    }));

/// 脚本化模型（store_test 同款副本，避免测试间共享可变状态）：每次
/// doStream 依序取脚本步；耗尽回纯文本。
class _ScriptedModel extends MockLanguageModelV4 {
  final List<List<LanguageModelV4ContentPart>> script;
  int _i = 0;
  _ScriptedModel(this.script) : super(provider: 'scripted', modelId: 'm');

  @override
  Future<LanguageModelV4StreamResult> doStream(LanguageModelV4CallOptions options) async {
    final step = _i < script.length ? script[_i++] : <LanguageModelV4ContentPart>[mockText('done')];
    var seq = 0;
    final parts = <LanguageModelV4StreamPart>[const StreamPartStreamStart(warnings: [])];
    for (final part in step) {
      if (part is LanguageModelV4ToolCallPart) {
        parts.add(StreamPartToolInputStart(id: 't$seq', toolName: part.toolName));
        parts.add(StreamPartToolInputDelta(id: 't$seq', delta: jsonEncode(part.input)));
        parts.add(StreamPartToolInputEnd(id: 't$seq'));
        parts.add(StreamPartToolCall(toolCall: part));
      }
      seq++;
    }
    parts.add(const StreamPartFinish(finishReason: LanguageModelV4FinishReason.stop, rawFinishReason: 'stop'));
    return LanguageModelV4StreamResult(stream: Stream.fromIterable(parts));
  }
}

/// Dart 运行时 store：MockClient 的 api 过 `_runAgent` 的能力门（BUILD 需要
/// 引擎桥存在），模型走 scripted 注入，recovery 落临时目录（不污染
/// ~/.nondesign）。
AppStore _dartStore() {
  final dir = Directory.systemTemp.createTempSync('nondesign-pip-routing');
  addTearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });
  final store = _store(project: true)
    ..api = _engineApi()
    ..recoveryDir = dir.path;
  store.settings.agentRuntime = agentRuntimeDart;
  store.settings.apiKey = 'test-key';
  store.settings.baseUrl = 'http://mock.local/v1';
  store.settings.providerId = 'testp';
  store.settings.modelId = 'm1';
  store.registry = ModelRegistry.fromJson({
    'providers': {
      'testp': {
        'api': 'http://mock.local',
        'protocol': 'openai',
        'models': {
          'm1': {'name': 'M1', 'tool_call': true, 'limit': {'context': 128000}},
        },
      },
    },
  });
  return store;
}

/// 等面板触发的 run 收尾（scripted 模型 + MockClient 全程 microtask）。
/// 只 pump 不 settle：宿主里的常驻组件不适合 pumpAndSettle 的超时语义。
Future<void> _waitRunIdle(WidgetTester tester, AppStore store) async {
  bool idle() => !store.agentBusy && store.timeline.isNotEmpty;
  for (var i = 0; i < 100; i++) {
    await tester.pump(const Duration(milliseconds: 20));
    if (idle()) return;
    // SDK 的流管道里混有真实事件循环的 await（fake async 不驱动）；
    // runAsync 让出真实时间片，两栖推进。
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 2)));
    if (idle()) return;
  }
  fail('run 未在预期时间内收尾（agentBusy=${store.agentBusy} phase=${store.agentPhase} '
      'timeline=${store.timeline.map((t) => '${t.kind}:${t.title ?? t.tool ?? t.text}').join(' | ')} '
      'error=${store.agentError}）');
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('1280 宽 view=chat：chat 与 workspace 同屏（常驻分栏）', (tester) async {
    final store = _store(project: true);
    await _pumpAt(tester, _wrap(store, const ChatWorkspaceHost()), const Size(1280, 860));

    expect(find.byKey(const ValueKey('chat-input')), findsOneWidget);
    expect(find.byType(Workspace), findsOneWidget);
    expect(tester.widget<Workspace>(find.byType(Workspace)).embedded, isTrue,
        reason: '分栏内是嵌入式 Workspace（无 TitleBar/StatusBar）');
    expect(find.byKey(const ValueKey('chat-shell-workspace-pane')), findsOneWidget);
    expect(find.byKey(const ValueKey('pip-edge-handle')), findsNothing,
        reason: '宽屏走分栏，不出画中画条带');
    expect(tester.takeException(), isNull);
  });

  testWidgets('1280 宽 view=design：只有全屏 Workspace、无 chat-input；Esc 回 chat', (tester) async {
    final store = _store(project: true)..view = 'design';
    await _pumpAt(tester, _rootApp(store), const Size(1280, 860));

    expect(find.byType(Workspace), findsOneWidget);
    expect(tester.widget<Workspace>(find.byType(Workspace)).embedded, isFalse,
        reason: 'design 仍是全屏工作区（S4 不改既有语义）');
    expect(find.byKey(const ValueKey('chat-input')), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 80));
    expect(store.view, 'chat');
    expect(find.byKey(const ValueKey('chat-input')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('折叠与顶栏「工作区」：只剩 chat / 再展开 / 再折叠', (tester) async {
    final store = _store(project: true);
    await _pumpAt(tester, _wrap(store, const ChatWorkspaceHost()), const Size(1280, 860));
    expect(find.byType(Workspace), findsOneWidget);

    // 面板 SlimHeader 的折叠键 → 只剩 chat（右侧留窄轨）。
    await tester.tap(find.byKey(const ValueKey('chat-shell-collapse')));
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.byType(Workspace), findsNothing);
    expect(find.byKey(const ValueKey('chat-input')), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-shell-expand')), findsOneWidget);

    // chat 顶栏「工作区」→ 展开。
    await tester.tap(find.byKey(const ValueKey('chat-open-workspace')));
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.byType(Workspace), findsOneWidget);

    // 再点一次 → 折叠（同一按钮切换折叠态）。
    await tester.tap(find.byKey(const ValueKey('chat-open-workspace')));
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.byType(Workspace), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('无项目空态：新建空画板后 hasProject=true 且 view 仍为 chat', (tester) async {
    final store = _store()..view = 'chat';
    // newProject(empty:) 的空路径不触网，但入口要求 api 非空（先建后用纪律）。
    store.api = NoNDesignApi('http://127.0.0.1:9');
    await _pumpAt(tester, _rootApp(store), const Size(1280, 860));

    expect(find.text('工作区 · 等待第一块画板'), findsOneWidget);
    expect(find.byType(Workspace), findsNothing);

    await tester.tap(find.byKey(const ValueKey('chat-shell-create-board')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    expect(store.hasProject, isTrue);
    expect(store.view, 'chat', reason: '面板内建板不隐式 setView(design)');
    expect(find.byKey(const ValueKey('chat-input')), findsOneWidget,
        reason: '宿主未被拆掉（仍是聊天流分栏）');
    expect(find.byType(Workspace), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('嵌入窄轨不拆宿主：点设计/历史只切面板，不切 store.view', (tester) async {
    final store = _store(project: true);
    await _pumpAt(tester, _wrap(store, const ChatWorkspaceHost()), const Size(1280, 860));

    expect(find.byKey(const ValueKey('workspace-embedded-rail')), findsOneWidget);
    // 全局 Rail 的「文档/规范」在宿主里不存在（点一下就是一次不可逆退出）。
    expect(find.byKey(const ValueKey('embedded-rail-docs')), findsNothing);
    expect(find.byKey(const ValueKey('embedded-rail-spec')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('embedded-rail-history')));
    await tester.pump(const Duration(milliseconds: 80));
    expect(store.view, 'chat', reason: 'review pip-1：窄轨不得切视图');
    expect(store.panel, 'history');
    expect(find.byKey(const ValueKey('chat-input')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('embedded-rail-project')));
    await tester.pump(const Duration(milliseconds: 80));
    expect(store.view, 'chat');
    expect(store.panel, 'project');
    expect(find.byKey(const ValueKey('chat-input')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('移动浮窗里的嵌入窄轨同样不切视图（390×844，review pip-1 复现位）', (tester) async {
    final store = _store(project: true);
    // 真实 NonApp 路由（复现位与探针一致：view=chat 且有项目 → 聊天宿主）。
    await _pumpAt(tester, _rootApp(store), const Size(390, 844));

    await tester.tap(find.byKey(const ValueKey('pip-edge-capsule')));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byKey(const ValueKey('workspace-embedded-rail')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('embedded-rail-history')));
    await tester.pump(const Duration(milliseconds: 80));
    expect(store.view, 'chat', reason: '浮窗里的窄轨不得把宿主拆成全屏视图');
    expect(store.panel, 'history');
    expect(find.byKey(const ValueKey('chat-pip-window')), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-input')), findsOneWidget,
        reason: '聊天流仍在浮窗下层存活');
    expect(tester.takeException(), isNull);
  });

  testWidgets('产物卡（原型）在宿主内展开工作区，不换路由', (tester) async {
    final store = _store(project: true);
    store.appendChat(ChatMessage.artifact(kind: artifactPrototype, title: '原型A'));
    await _pumpAt(tester, _wrap(store, const ChatWorkspaceHost()), const Size(1280, 860));

    // 先折叠，验证产物卡是「展开」而不是「切换」。
    await tester.tap(find.byKey(const ValueKey('chat-shell-collapse')));
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.byType(Workspace), findsNothing);

    await tester.tap(find.text('原型A'));
    await tester.pump(const Duration(milliseconds: 80));
    expect(store.view, 'chat', reason: 'review pip-2：产物卡不得 setView(design)');
    expect(find.byType(Workspace), findsOneWidget, reason: '工作区面板被展开');
    expect(find.byKey(const ValueKey('chat-input')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('嵌入宿主登记：Workspace(embedded:true) 挂载计数、卸载归零', (tester) async {
    final store = _store(project: true);
    await _pumpAt(tester, _wrap(store, const ChatWorkspaceHost()), const Size(1280, 860));
    expect(store.embeddedHostActive, isTrue, reason: '分栏里的嵌入 Workspace 已登记');

    // 折叠 = 嵌入 Workspace 卸载 → 注销（登记是计数不是常开布尔）。
    await tester.tap(find.byKey(const ValueKey('chat-shell-collapse')));
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.byType(Workspace), findsNothing);
    expect(store.embeddedHostActive, isFalse);

    // 重新展开 → 重新登记。
    await tester.tap(find.byKey(const ValueKey('chat-shell-expand')));
    await tester.pump(const Duration(milliseconds: 80));
    expect(store.embeddedHostActive, isTrue);

    // 宿主整块销毁（回全屏视图/关窗）→ 计数归零，不把下一个宿主误锁。
    await tester.pumpWidget(const SizedBox.shrink());
    expect(store.embeddedHostActive, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('嵌入面板发送不拆宿主：runPlan/runBuild/runRefine 都保持 view=chat', (tester) async {
    // 宽窗（≥1100 分栏 + 嵌入 Workspace 三栏全开）：右栏 AgentPanel 直接可点。
    final store = _dartStore();
    store.debugAgentModelOverride = _ScriptedModel([
      [mockToolCall(toolName: 'write_doc', input: {'kind': 'prd', 'content': '# PRD'})],
      [mockToolCall(toolName: 'write_doc', input: {'kind': 'ui', 'content': '## UI'})],
      [
        mockToolCall(toolName: 'write_design_spec', input: {
          'palette': {'primary': '#4F7CFF'},
          'typography': {'body': 13},
          'spacing': [4, 8, 12],
          'radius': {'button': 8},
        })
      ],
      [mockToolCall(toolName: 'finish', input: {'summary': '文档完成'})],
    ]);
    await _pumpAt(tester, _rootApp(store), const Size(2400, 1200));
    expect(store.embeddedHostActive, isTrue);

    // 面板「文档」芯片 = agent_panel.dart:82-88 的 runPlan 分支。
    await tester.tap(find.descendant(of: find.byType(AgentPanel), matching: find.text('文档')));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.enterText(
        find.descendant(of: find.byType(AgentPanel), matching: find.byType(TextField)), '做一个仪表盘');
    // 发送按钮的启用态挂在输入 controller 的 ListenableBuilder 上，必须让
    // 输入后的重建落地再点（否则 onPressed 仍是 null，点击静默无效）。
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.widgetWithText(FilledButton, '发送'));
    await _waitRunIdle(tester, store);

    expect(store.docs.prd, contains('PRD'), reason: 'run 真的跑完了（不是提前失败）');
    expect(store.view, 'chat', reason: 'review pip-1：面板发送不得把 view 切去 docs');
    expect(find.byKey(const ValueKey('chat-input')), findsOneWidget, reason: '聊天宿主未被拆掉');
    expect(find.byType(Workspace), findsOneWidget, reason: '嵌入工作区仍在');

    // 同一登记态下 BUILD / REFINE 两条 store 入口（面板其余两个模式芯片）。
    store.debugAgentModelOverride = _ScriptedModel([
      [mockText('完成')],
      [mockText('完成')],
    ]);
    expect(await tester.runAsync(() => store.runBuild('生成首页')), isTrue);
    expect(store.view, 'chat', reason: 'BUILD 不把 view 切去 design');
    expect(await tester.runAsync(() => store.runRefine('调整圆角')), isTrue);
    expect(store.view, 'chat', reason: 'REFINE 不把 view 切去 design');
    await tester.pump(const Duration(milliseconds: 120));

    expect(find.byKey(const ValueKey('chat-input')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('左栏最近项目打开项目不拆宿主：openProjectFlow 后 view 仍是 chat', (tester) async {
    final store = _store(project: true)
      ..recent = [
        {'path': '/tmp/pip-proto.ddp', 'name': 'pip-proto', 'ts': 1},
      ];
    store.api = NoNDesignApi('http://mock.local', MockClient((request) async {
      switch (request.url.path) {
        case '/project/open':
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          return _json({'ok': true, 'path': body['path'], 'mbt': 'MBT_OPEN', 'docs': {}});
        case '/engine/render':
          return _json(_envelope('MBT_OPEN'));
      }
      return _json({'ok': false, 'detail': 'no_route'});
    }));
    final dir = Directory.systemTemp.createTempSync('nondesign-pip-open');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
    store.recoveryDir = dir.path;

    await _pumpAt(tester, _rootApp(store), const Size(2400, 1200));
    expect(store.embeddedHostActive, isTrue);
    expect(find.text('最近项目'), findsOneWidget);

    // 左栏「最近项目」行 → openProjectFlow → store.openProjectPath
    // （left_panel.dart:110-126 的真实入口）。
    await tester.tap(find.text('pip-proto'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(store.projectName, 'pip-proto');
    expect(store.view, 'chat', reason: 'review pip-1：最近项目不得把聊天宿主拆成全屏设计');
    expect(find.byKey(const ValueKey('chat-input')), findsOneWidget, reason: '聊天宿主未被拆掉');
    expect(find.byType(Workspace), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('离线（api==null）点新建空画板：给提示，不静默', (tester) async {
    final store = _store()..view = 'chat'; // api 保持 null（boot 降级路径）
    await _pumpAt(tester, _rootApp(store), const Size(1280, 860));
    expect(find.text('工作区 · 等待第一块画板'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('chat-shell-create-board')));
    await tester.pump(const Duration(milliseconds: 80));

    expect(store.hasProject, isFalse);
    expect(store.view, 'chat');
    expect(find.byKey(const ValueKey('chat-shell-pane-hint')), findsOneWidget,
        reason: 'review pip-3：store.newProject 在 api==null 时静默 false，空态必须自证');
    expect(find.textContaining('离线模式'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
