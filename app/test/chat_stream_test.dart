// 聊天流主面（S1，docs/plan-chat-stream-shell.md §2）的测试面：
// - store 全链：sendChat → 进度卡（事件镜像步骤）→ 产物卡（原型），写路径
//   仍走引擎 AgentGate（复用 store_test 的本地 mock 模式，零外联）；
// - 卡片渲染：用户/进度/产物/A2UI 四类卡 + A2UI 动作回流续跑；进度步骤的
//   工具名（含无下划线的 inspect）一律经术语表；
// - 默认主面切换：chatStreamHome 开/关 ↔ 经典 Welcome；经典面下 Esc 经
//   view=='chat' 真正切到聊天主面；
// - 触屏项目入口：聊天顶栏与画中画工作区的项目菜单（名称/未保存点/保存/
//   另存/打开/新建），保存动作不依赖硬件快捷键；
// - NaN 窄栏：聊天里的 A2UI 卡（ask_user 选项）在桌面右栏可见；外部智能体
//   只显示产品名；
// - 会话持久化：chat.json 落盘 → 重启恢复（running 进度卡诚实降级）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ai_sdk_dart/test.dart';
// ai_sdk_provider 是 ai_sdk_dart 的传递依赖（pubspec 未声明）；scripted mock
// 需要其流片段/结果类型来覆写 doStream（store_test 同款注释与本文件副本）。
// ignore: depend_on_referenced_packages
import 'package:ai_sdk_provider/ai_sdk_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:nondesign/core/api.dart';
import 'package:nondesign/core/capability.dart';
import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/project_service.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/core/toast_service.dart';
import 'package:nondesign/main.dart';
import 'package:nondesign/widgets/chat_pip_shell.dart';
import 'package:nondesign/widgets/chat_stream.dart';
import 'package:nondesign/widgets/desktop_shell.dart';
import 'package:nondesign/widgets/right_panel.dart';
import 'package:nondesign/widgets/welcome.dart';
import 'package:nondesign/widgets/workspace.dart';

/// Build 循环的脚本化模型（store_test 同款副本）：每次 doStream 依序取脚本
/// 步；耗尽回纯文本。
class _ScriptedBuildModel extends MockLanguageModelV4 {
  final List<List<LanguageModelV4ContentPart>> script;
  int _i = 0;
  _ScriptedBuildModel(this.script) : super(provider: 'scripted', modelId: 'm');

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

/// 脚本化引擎（store_test `_FakeEngine` 的精简副本）：进程内宿主替身，
/// 记录 AgentGate 的 gate/op 并回 canonical。批次 05 起 store 的写路径是
/// `LocalCore`（进程内 wasm 宿主）→ `_StoreEngineGate` → `engine.apply`，
/// 不再是本地 HTTP 端口——测试替身必须落在同一层。
class _ChatEngine implements LocalEngine {
  final List<String> gates = [];
  final List<String> appliedOps = [];
  String canonical = 'MBT_0';

  Map<String, dynamic> _envelope(String mbt) => {
        'ok': true,
        'mbt': mbt,
        'entry': 'home',
        'revision': 1,
        'artboards': [
          {'id': 'home', 'name': 'home', 'width': 390, 'height': 844, 'nodes': <dynamic>[]},
        ],
        'flows': <dynamic>[],
      };

  @override
  bool get isReady => true;

  @override
  String? get startupError => null;

  @override
  CapabilityAvailability probeAvailability() =>
      const CapabilityAvailability.available(CapabilityId.localDesignEngine);

  @override
  Future<Map<String, dynamic>> render(String mbt) async {
    canonical = mbt;
    return _envelope(mbt);
  }

  @override
  Future<Map<String, dynamic>> validate(String mbt) async => {'ok': true, 'mbt': mbt};

  @override
  Future<Map<String, dynamic>> apply(String mbt, String op, {String gate = 'human'}) async {
    gates.add(gate);
    appliedOps.add(op);
    canonical = 'MBT_${appliedOps.length}';
    return _envelope(canonical);
  }

  @override
  Future<Map<String, dynamic>> session(String mbt, String name, [String? arg]) async {
    if (name == 'session_list_artboards') {
      return {
        'ok': true,
        'data': [
          {'id': 'home', 'nodes': 1, 'width': 390, 'height': 844},
        ],
      };
    }
    return {'ok': true, 'data': const <dynamic>[]};
  }

  @override
  Future<Map<String, dynamic>> generate(
      String mbt, String intent, String name, Map<String, dynamic> spec) async {
    canonical = '$mbt<!-- generated: $intent -->';
    return {'ok': true, 'mbt': canonical, 'artboard': name};
  }

  @override
  Future<Map<String, dynamic>> tap(String mbt, String artboard, double x, double y) async =>
      {'ok': true, 'current': artboard};

  @override
  Future<Map<String, dynamic>> constrainIntent(String mbt, String artboard, String intent) async =>
      {'ok': true, 'mbt': mbt};

  @override
  Future<Map<String, dynamic>> event(String mbt, String artboard, String spec) async =>
      {'ok': true, 'current': artboard};

  @override
  Future<Map<String, dynamic>> history(String mbt, String command) async => {'ok': true, 'mbt': mbt};

  @override
  Future<Map<String, dynamic>> exportHtml(String mbt) async => {'ok': true, 'html': '<html></html>'};

  @override
  Future<Map<String, dynamic>> tokens() async => {'ok': true, 'data': const <dynamic>[]};

  @override
  Future<Map<String, dynamic>> versionInfo() async => {'ok': true, 'version': 'fixture'};

  @override
  Future<List<dynamic>> templates() async => [
        {'id': 'pc_app', 'name': 'PC App', 'device': 'pc'},
      ];

  @override
  Future<List<dynamic>> components() async => ['button', 'text'];

  @override
  Future<List<dynamic>> themes() async => ['dark'];

  @override
  Future<List<dynamic>> ops() async => ['place'];
}

/// 只记录保存调用的 store：触屏项目菜单的接线测试用（真实写盘与移动端
/// 默认路径由 store 侧负责，store_test 覆盖）。
class _RecordingSaveStore extends AppStore {
  _RecordingSaveStore() : super(toasts: ToastService(autoDismiss: false));

  int saveCalls = 0;
  final List<String?> savePaths = [];

  @override
  Future<bool> saveProject({String? path}) async {
    saveCalls += 1;
    savePaths.add(path);
    dirty = false;
    notifyListeners();
    return true;
  }
}

/// chat 全链 harness：注入进程内 LocalCore（引擎替身录制 AgentGate 的
/// gate/op）；store 预置文档（sendChat 直接走 BUILD）与 dart 运行时。
Future<(AppStore, _ChatEngine, Future<void> Function())> _chatHarness() async {
  final dir = Directory.systemTemp.createTempSync('nondesign-chat-test');
  final engine = _ChatEngine();
  final store = AppStore(
    localCore: LocalCore(
      engine: engine,
      projects: ProjectService(root: () async => dir),
    ),
    toasts: ToastService(autoDismiss: false),
  );
  store.recoveryDir = dir.path;
  store.settingsMirrorDir = '${dir.path}/settings';
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
  store.settings.apiKey = 'test-key';
  store.settings.providerId = 'testp';
  store.settings.modelId = 'm1';
  store.settings.agentRuntime = agentRuntimeDart;
  // 预置端点：绕开 _runDartLoop 的「回退默认端点」分支（saveSettings 走
  // SharedPreferences 插件，测试环境无实现）。
  store.settings.baseUrl = 'http://mock.local/v1';
  store.hasProject = true;
  store.projectName = '仪表盘';
  store.view = 'chat';
  store.docs.prd = '已有的 PRD';
  return (store, engine, () async {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });
}

/// 静态 A2UI surface 消息（a2ui_card_test 同款夹具形状，纯 map 无 a2ui import）。
final List<Object?> _surfaceMessages = [
  {
    'version': '1.0',
    'createSurface': {
      'surfaceId': 'demo',
      'catalogId': 'https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json',
      'components': [
        {'id': 'root', 'component': 'Column', 'children': ['title', 'btn']},
        {'id': 'title', 'component': 'Text', 'text': '旅行偏好'},
        {
          'id': 'btn',
          'component': 'Button',
          'child': 'btnLabel',
          'action': {
            'event': {'name': 'submit', 'context': {'place': 'Tokyo'}},
          },
        },
        {'id': 'btnLabel', 'component': 'Text', 'text': '生成行程'},
      ],
    },
  },
];

void main() {
  // _toast 经 rootMessengerKey 需要已初始化 binding；flutter_test 默认把本
  // 进程 HttpClient 请求拦截为 400——与 loopback mock 冲突，还原真实
  // HttpOverrides（store_test 同一处理）。
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  group('sendChat 全链（store 级，dart 运行时 × 引擎门）', () {
    test('发消息→进度卡→产物卡：事件镜像步骤、原型卡追加、视图不被拽走', () async {
      final (store, engine, close) = await _chatHarness();
      store.debugAgentModelOverride = _ScriptedBuildModel([
        [mockToolCall(toolName: 'design_op', input: {'op': 'create home 390 844'})],
        [mockToolCall(toolName: 'finish', input: {'summary': '建好首页'})],
      ]);

      final ok = await store.sendChat('搭一个仪表盘');

      expect(ok, true);
      // 写路径仍是引擎 AgentGate（聊天流不改变引擎门纪律）。
      expect(engine.gates, ['agent']);
      expect(engine.appliedOps, ['create home 390 844']);
      // 卡片序：用户消息 → 进度卡 → 助手总结（finish 的 assistant_text）→
      // 产物卡（原型）。
      expect(store.chatMessages, hasLength(4));
      expect(store.chatMessages[0].kind, chatKindUser);
      expect(store.chatMessages[0].text, '搭一个仪表盘');
      final progress = store.chatMessages[1];
      expect(progress.kind, chatKindProgress);
      expect(progress.running, false, reason: '终态收尾后进度卡不再在跑');
      expect(progress.ok, true);
      expect(progress.text, '原型已生成');
      expect(progress.steps.map((s) => s.label), contains('design_op'),
          reason: 'design_op 工具调用镜像为进度卡步骤');
      // 阶段代号（build/plan/refine）不上屏：起始行是人话阶段 + 模型名。
      final startStep = progress.steps.firstWhere((s) => s.label == 'NaN 开始');
      expect(startStep.detail, contains('生成原型'));
      expect(startStep.detail, isNot(contains('build')));
      expect(store.chatMessages[2].kind, chatKindAssistant);
      expect(store.chatMessages[2].text, '建好首页', reason: 'finish 摘要独立成助手卡');
      final artifact = store.chatMessages[3];
      expect(artifact.kind, chatKindArtifact);
      expect(artifact.artifactKind, artifactPrototype);
      expect(artifact.artifactName, '仪表盘');
      // 聊天流驱动的 run 不跳视图（chatActive 门）。
      expect(store.view, 'chat');
      expect(store.agentBusy, false);
      await close();
    });

    test('ask_user 工具 → 聊天流出现真实 A2UI 交互卡（不是测试专用构造）', () async {
      final (store, _, close) = await _chatHarness();
      store.debugAgentModelOverride = _ScriptedBuildModel([
        [
          mockToolCall(toolName: 'ask_user', input: <String, dynamic>{
            'question': '导航放哪里？',
            'options': <String>['底部标签栏', '侧边抽屉'],
          }),
        ],
        [mockToolCall(toolName: 'finish', input: <String, dynamic>{'summary': '等你选择'})],
      ]);

      final ok = await store.sendChat('做一个记账应用');
      expect(ok, true);

      final cards = store.chatMessages.where((m) => m.kind == chatKindA2ui).toList();
      expect(cards, hasLength(1), reason: 'ask_user 的工具事件应生产一张 A2UI 卡');
      final payload = jsonEncode(cards.single.a2uiMessages);
      expect(payload, contains('ask-'));
      expect(payload, contains('导航放哪里？'));
      expect(payload, contains('底部标签栏'));
      await close();
    });

    test('tool_end.message → 聊天步骤与时间线都显示人话失败原因', () async {
      final (store, _, close) = await _chatHarness();
      store.debugAgentModelOverride = _ScriptedBuildModel([
        [
          mockToolCall(toolName: 'write_doc', input: <String, dynamic>{
            'kind': 'nope',
            'content': 'x',
          }),
        ],
        [mockToolCall(toolName: 'finish', input: <String, dynamic>{'summary': '完成'})],
      ]);

      final ok = await store.sendChat('改一下文档');
      expect(ok, true);

      final card = store.chatMessages.firstWhere((m) => m.kind == chatKindProgress);
      final step = card.steps.firstWhere((s) => s.label == 'write_doc');
      expect(step.ok, false);
      expect(step.detail, '文档类型不对，请重试');
      final tool = store.timeline.firstWhere((t) => t.kind == 'tool');
      expect(tool.ok, false);
      expect(tool.error, 'doc_kind_must_be_prd_or_ui');
      expect(tool.message, '文档类型不对，请重试');
      await close();
    });

    test('openWorkspace：无项目先建空项目再进设计视图', () async {
      final (store, _, close) = await _chatHarness();
      store.hasProject = false;
      store.view = 'chat';

      await store.openWorkspace();

      expect(store.hasProject, true, reason: '先建后用（generateFromBrief 同一纪律）');
      expect(store.view, 'design');
      await close();
    });
  });

  group('聊天卡渲染（widget）', () {
    AppStore seededStore() {
      // toasts: autoDismiss=false —— 失败收尾会发通知；默认服务带 5s 计时器，
      // 测试结束时会被判成「Timer is still pending」。
      final store = AppStore(toasts: ToastService(autoDismiss: false));
      store.ready = true;
      store.view = 'chat';
      // 产物卡点开语义依赖 hasProject（原型卡 → openWorkspace 的设计分支）。
      store.hasProject = true;
      store.appendChat(ChatMessage.user('做一个记账应用'));
      final progress = ChatMessage.progress('原型已生成');
      progress.running = false;
      progress.steps.addAll([
        ChatStep(label: '撰写产品文档', detail: '820 字'),
        ChatStep(label: 'design_op', ms: 42),
        ChatStep(label: 'design_op', ok: false, detail: 'mbt_gate_block'),
        // 无下划线的已知工具同样要经术语表（inspect → 检查）。
        ChatStep(label: 'inspect', ms: 7),
      ]);
      store.appendChat(progress);
      store.appendChat(ChatMessage.artifact(
          kind: artifactPrototype, title: '记账', detail: '可交互原型已生成，点开进入工作区'));
      store.appendChat(ChatMessage.artifact(kind: artifactVideo, title: '开场动画'));
      store.appendChat(ChatMessage.artifact(kind: artifactThree, title: '小场景'));
      store.appendChat(ChatMessage.artifact(kind: artifactHotapp, title: '发票计算器'));
      store.appendChat(ChatMessage.a2ui(_surfaceMessages));
      return store;
    }

    Widget host(AppStore store) => ChangeNotifierProvider<AppStore>.value(
          value: store,
          child: MaterialApp(
            theme: AppTheme.build(dark: true),
            scaffoldMessengerKey: rootMessengerKey,
            home: const ChatStreamView(),
          ),
        );

    testWidgets('四类卡渲染：用户气泡 / 进度步骤 / 产物卡 / A2UI surface', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      final store = seededStore();
      await tester.pumpWidget(host(store));
      await tester.pump(const Duration(milliseconds: 80));

      // 用户气泡与进度卡步骤。
      expect(find.text('做一个记账应用'), findsOneWidget);
      expect(find.text('原型已生成'), findsOneWidget);
      expect(find.text('撰写产品文档'), findsOneWidget);
      // 工具名必须经 toolLabel 映射（术语表：design_op → 设计变更），
      // 原始代号不得回显给用户。无下划线的 inspect 也不例外。
      expect(find.text('设计变更'), findsNWidgets(2));
      expect(find.text('design_op'), findsNothing);
      expect(find.text('42ms'), findsOneWidget);
      expect(find.text('检查'), findsOneWidget, reason: 'inspect → 检查（不按是否含下划线判断）');
      expect(find.text('inspect'), findsNothing);
      // 产物卡：标签与标题。
      expect(find.text('原型'), findsOneWidget);
      expect(find.text('视频'), findsOneWidget);
      expect(find.text('3D'), findsOneWidget);
      expect(find.text('热应用'), findsOneWidget);
      expect(find.text('记账'), findsOneWidget);
      // A2UI surface 组件（静态路径直灌）。
      expect(find.text('旅行偏好'), findsOneWidget);
      expect(find.text('生成行程'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('产物卡点开：原型→工作区；热应用→工作台并落 hotappApp', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      final store = seededStore();
      await tester.pumpWidget(host(store));
      await tester.pump(const Duration(milliseconds: 80));

      await tester.tap(find.text('记账'));
      await tester.pump(const Duration(milliseconds: 50));
      expect(store.view, 'design', reason: '原型卡进工作区');

      // 回聊天流再点热应用卡。
      store.setView('chat');
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('发票计算器'));
      await tester.pump(const Duration(milliseconds: 50));
      expect(store.view, 'plugin:hotapp');
      expect(store.settings.hotappApp, '发票计算器');
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('A2UI 动作回流：点按钮 → 摘要入列用户消息并续跑一轮', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      final store = seededStore();
      await tester.pumpWidget(host(store));
      await tester.pump(const Duration(milliseconds: 80));
      final before = store.chatMessages.length;

      await tester.tap(find.text('生成行程'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      expect(store.chatMessages.length, greaterThan(before));
      expect(
        store.chatMessages.any((m) => m.kind == chatKindUser && m.text.contains('submit')),
        isTrue,
        reason: '动作摘要作为用户消息入列（回流续跑）',
      );
      expect(store.chatMessages.last.kind, chatKindProgress,
          reason: '无 apiKey 的续跑诚实收尾为失败进度卡');
      expect(store.chatMessages.last.running, false);
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('输入框发送：用户消息 + 进度卡入列（无 Key 诚实失败收尾）', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      final store = AppStore(toasts: ToastService(autoDismiss: false))..ready = true;
      await tester.pumpWidget(host(store));
      await tester.pump(const Duration(milliseconds: 50));

      await tester.enterText(find.byKey(const ValueKey('chat-input')), '做个小工具');
      await tester.tap(find.byKey(const ValueKey('chat-send')));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      expect(store.chatMessages.first.kind, chatKindUser);
      expect(store.chatMessages.first.text, '做个小工具');
      expect(store.chatMessages.last.kind, chatKindProgress);
      expect(store.chatMessages.last.running, false, reason: '无 apiKey 的 run 立即失败收尾');
      expect(store.chatMessages.last.ok, false);
      await tester.binding.setSurfaceSize(null);
    });
  });

  group('NaN 面板（桌面 / iPad 横屏窄栏）', () {
    AppStore panelStore() {
      final store = AppStore(toasts: ToastService(autoDismiss: false));
      store.ready = true;
      store.hasProject = true;
      store.settings = AppSettings(providerId: 'deepseek', modelId: 'deepseek-v4.1-flash');
      return store;
    }

    /// 桌面主题：AgentPanel 用 Theme.platform 判移动端；测试默认平台是
    /// Android，显式钉 macOS 才走到「外部智能体」分支（与真机一致）。
    Widget host(AppStore store, {TargetPlatform platform = TargetPlatform.macOS}) =>
        ChangeNotifierProvider<AppStore>.value(
          value: store,
          child: MaterialApp(
            theme: AppTheme.build(dark: true).copyWith(platform: platform),
            home: const Scaffold(body: AgentPanel()),
          ),
        );

    testWidgets('聊天里的 A2UI 卡（ask_user 选项）在 NaN 面板可见', (tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final store = panelStore()..appendChat(ChatMessage.a2ui(_surfaceMessages));
      await tester.pumpWidget(host(store));
      await tester.pump(const Duration(milliseconds: 120));

      // 窄栏此前只渲染时间线/流式文本：ask_user 的问题只剩工具副标题，
      // 选项只能从展开的技术详情里看到。聊天卡必须直接可见。
      expect(find.text('旅行偏好'), findsOneWidget);
      expect(find.text('生成行程'), findsOneWidget);
      expect(find.byKey(const ValueKey('agent-input')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('外部智能体只显示产品名——不拼内部协议名', (tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final store = panelStore()
        ..settings.acpAgentId = 'claude-code'
        ..settings.acpAgentName = 'Claude Code';
      await tester.pumpWidget(host(store));
      await tester.pump(const Duration(milliseconds: 80));

      expect(find.text('Claude Code'), findsOneWidget);
      expect(find.textContaining('· ACP'), findsNothing);
      expect(
        find.byWidgetPredicate((w) => w is Tooltip && (w.message ?? '').contains('ACP')),
        findsNothing,
        reason: 'tooltip 也不得暴露协议名（docs/copy-glossary.md §2）',
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('项目入口（手机 / iPad 竖屏触屏）', () {
    /// 记录保存调用（真实写盘与移动端默认路径由 store 侧负责，store_test
    /// 覆盖；这里锚定触屏入口确实接上了保存动作）。
    _RecordingSaveStore touchStore() {
      final store = _RecordingSaveStore();
      store.ready = true;
      store.settings = AppSettings(providerId: 'deepseek', modelId: 'deepseek-v4.1-flash');
      store.hasProject = true;
      store.projectName = '手机项目';
      store.projectPath = '/tmp/手机项目.ddp';
      store.mbt = '---\nmoonviz:\n  format: visual-document\n  revision: 1\n  entry: home\n---\n';
      store.dirty = true;
      return store;
    }

    Widget host(AppStore store) => ChangeNotifierProvider<AppStore>.value(
          value: store,
          child: MaterialApp(
            theme: AppTheme.build(dark: true),
            scaffoldMessengerKey: rootMessengerKey,
            home: const ChatStreamView(),
          ),
        );

    testWidgets('聊天主面顶栏：项目名 + 未保存点 + 保存/另存/打开/新建', (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final store = touchStore();
      await tester.pumpWidget(host(store));
      await tester.pump(const Duration(milliseconds: 80));

      expect(find.byKey(const ValueKey('chat-project-menu')), findsOneWidget);
      expect(find.text('手机项目'), findsOneWidget, reason: '手机上必须看得到项目名');
      expect(find.byKey(const ValueKey('chat-project-dirty')), findsOneWidget,
          reason: '未保存点常驻可见');

      await tester.tap(find.byKey(const ValueKey('chat-project-menu')));
      await tester.pumpAndSettle();
      expect(find.text('保存'), findsOneWidget);
      expect(find.text('另存为…'), findsOneWidget);
      expect(find.text('打开项目…'), findsOneWidget);
      expect(find.text('新建项目'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('保存动作可在触屏完成：菜单 → 保存', (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final store = touchStore();
      await tester.pumpWidget(host(store));
      await tester.pump(const Duration(milliseconds: 80));

      await tester.tap(find.byKey(const ValueKey('chat-project-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(store.saveCalls, 1,
          reason: '手机没有系统保存对话框：触屏入口必须直接接上 store 的保存（应用内默认项目路径）');
      expect(store.dirty, false);
      expect(tester.takeException(), isNull);
    });

    testWidgets('另存为：应用内命名对话框，落点与当前项目同目录', (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final store = touchStore();
      await tester.pumpWidget(host(store));
      await tester.pump(const Duration(milliseconds: 80));

      await tester.tap(find.byKey(const ValueKey('chat-project-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('另存为…'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('chat-save-as-name')), findsOneWidget,
          reason: '无系统保存框时用应用内命名对话框');
      await tester.enterText(find.byKey(const ValueKey('chat-save-as-name')), '副本项目');
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();

      expect(store.saveCalls, 1);
      expect(store.savePaths.single, endsWith('/副本项目.ddp'));
      expect(tester.takeException(), isNull);
    });
  });

  group('默认主面与响应式壳（NonApp 路由）', () {
    AppStore rootStore() {
      final store = AppStore();
      store.ready = true;
      store.hasProject = false;
      store.view = 'design';
      store.settings = AppSettings(providerId: 'deepseek', modelId: 'deepseek-v4.1-flash');
      return store;
    }

    Widget rootApp(AppStore store) => ChangeNotifierProvider<AppStore>.value(
          value: store,
          child: const NonApp(),
        );

    Future<void> pumpAt(WidgetTester tester, AppStore store, Size size) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(rootApp(store));
      await tester.pump(const Duration(milliseconds: 100));
    }

    testWidgets('手机：chatStreamHome 默认 true → 聊天主面（画中画工作区）', (tester) async {
      final store = rootStore();
      expect(store.settings.chatStreamHome, true, reason: '默认开（用户决策）');
      await pumpAt(tester, store, const Size(390, 844));

      expect(find.byType(ChatPiPShell), findsOneWidget);
      expect(find.byKey(const ValueKey('chat-input')), findsOneWidget);
      expect(find.text('从一句话开始'), findsOneWidget);
      expect(find.byKey(const ValueKey('pip-edge-capsule')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('手机：关掉 chatStreamHome → 经典 Welcome；常驻聊天胶囊可切回',
        (tester) async {
      final store = rootStore();
      await pumpAt(tester, store, const Size(390, 844));

      store.settings.chatStreamHome = false;
      store.notifyListeners();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.textContaining('把想法变成'), findsOneWidget, reason: '经典 Welcome 回归');
      expect(find.byKey(const ValueKey('chat-input')), findsNothing);
      expect(find.byKey(const ValueKey('chat-first-fab')), findsOneWidget,
          reason: '关掉聊天主面不能把用户锁在没有聊天的界面');

      await tester.tap(find.byKey(const ValueKey('chat-first-fab')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(store.settings.chatStreamHome, isTrue);
      expect(find.byKey(const ValueKey('chat-input')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('桌面：chatStreamHome 不再决定主面——无项目是经典 Welcome，且主页无右栏',
        (tester) async {
      final store = rootStore();
      store.settings.chatStreamHome = true;
      await pumpAt(tester, store, const Size(1440, 900));

      expect(find.byType(DesktopShell), findsOneWidget);
      expect(find.byType(Welcome), findsOneWidget, reason: '桌面无项目主面 = Welcome');
      expect(find.byKey(const ValueKey('welcome-wide')), findsOneWidget);
      expect(find.byKey(const ValueKey('desktop-chat-rail')), findsNothing,
          reason: '主页默认不显示右侧栏');
      expect(find.byKey(const ValueKey('desktop-chat-rail-strip')), findsNothing,
          reason: '折叠覆盖条也不应出现在主页');
      expect(find.byKey(const ValueKey('welcome-open-chat')), findsNothing,
          reason: '右栏不存在时聊天入口隐藏');

      // 关掉手机主面偏好对桌面没有影响。
      store.settings.chatStreamHome = false;
      store.notifyListeners();
      await tester.pump(const Duration(milliseconds: 80));
      expect(find.byType(Welcome), findsOneWidget);
      expect(find.byKey(const ValueKey('desktop-chat-rail')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('桌面：有项目 → Workspace 主面；view==chat 不再整块路由；Esc 不抢工作区',
        (tester) async {
      final store = rootStore();
      store.hasProject = true;
      store.projectName = 'proj';
      store.mbt = '---\nmoonviz:\n  format: visual-document\n  revision: 1\n  entry: home\n---\n';
      store.render = RenderEnvelope(
        ok: true,
        entry: 'home',
        revision: 1,
        mbt: store.mbt,
        artboards: [Artboard(id: 'home', name: 'home', width: 390, height: 844, nodes: const [])],
      );
      store.view = 'chat';
      await pumpAt(tester, store, const Size(1440, 900));

      expect(find.byType(Workspace), findsOneWidget, reason: '有项目 → 工作区主面');
      expect(find.byKey(const ValueKey('desktop-chat-rail')), findsOneWidget);
      expect(find.byKey(const ValueKey('agent-input')), findsOneWidget,
          reason: '右侧栏默认落在 NaN（聊天 + 任务指令）');

      store.setView('design');
      await tester.pump(const Duration(milliseconds: 80));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 80));
      expect(store.view, 'design', reason: '桌面没有整块聊天路由，Esc 不切走工作区');
      expect(find.byType(Workspace), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('手机：Esc 从设计面回聊天主面', (tester) async {
      final store = rootStore();
      store.hasProject = true;
      store.projectName = 'proj';
      store.view = 'design';
      await pumpAt(tester, store, const Size(390, 844));
      expect(find.byType(ChatPiPShell), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 80));
      expect(store.view, 'chat');
      expect(find.byKey(const ValueKey('chat-input')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('手机：经典 Welcome 启动面下 Esc 真正切到聊天主面', (tester) async {
      final store = rootStore();
      store.settings.chatStreamHome = false;
      store.view = 'design';
      await pumpAt(tester, store, const Size(390, 844));

      // 经典 Welcome 在场（chatStreamHome 关闭），聊天主面不在。
      expect(find.textContaining('把想法变成'), findsOneWidget);
      expect(find.byKey(const ValueKey('chat-input')), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 80));

      // Esc 只置 store.view='chat'；壳消费该状态，界面必须真的切过去，
      // 不能停留在经典工作区而与隐藏状态不一致。
      expect(store.view, 'chat');
      expect(find.byKey(const ValueKey('chat-input')), findsOneWidget);
      expect(store.settings.chatStreamHome, isFalse,
          reason: 'Esc 不静默改写用户选择的启动主面');
      expect(tester.takeException(), isNull);
    });

    testWidgets('手机：画中画工作区自带项目入口（最大化时也能保存）', (tester) async {
      final store = rootStore();
      await pumpAt(tester, store, const Size(390, 844));

      await tester.tap(find.byKey(const ValueKey('chat-open-workspace')));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byKey(const ValueKey('pip-project-menu')), findsOneWidget,
          reason: '嵌入工作区隐藏了标题栏/状态栏，项目入口必须常驻浮窗');
      expect(find.byKey(const ValueKey('chat-shell-create-board')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('会话持久化（chat.json）', () {
    test('落盘→重启恢复：卡片类型/文本/A2UI 消息往返一致', () async {
      final dir = Directory.systemTemp.createTempSync('nondesign-chat-persist');
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      });

      final a = AppStore()..recoveryDir = dir.path;
      a.appendChat(ChatMessage.user('第一句话'));
      a.appendChat(ChatMessage.assistant('好的，开始规划。'));
      a.appendChat(ChatMessage.a2ui(_surfaceMessages));
      a.appendChat(ChatMessage.artifact(kind: artifactPrototype, title: '原型A'));
      await a.debugPersistChat();
      await a.chatWritesIdle;

      final b = AppStore()..recoveryDir = dir.path;
      await b.debugLoadChat();

      expect(b.chatMessages.map((m) => m.kind).toList(),
          [chatKindUser, chatKindAssistant, chatKindA2ui, chatKindArtifact]);
      expect(b.chatMessages[0].text, '第一句话');
      expect(b.chatMessages[1].text, '好的，开始规划。');
      expect(b.chatMessages[2].a2uiMessages, isNotNull);
      expect((b.chatMessages[2].a2uiMessages!.first as Map)['createSurface']['surfaceId'], 'demo');
      expect(b.chatMessages[3].artifactKind, artifactPrototype);
      expect(b.chatMessages[3].artifactName, '原型A');
    });

    test('重启后 running 进度卡诚实降级为失败卡（不伪装成仍在运行）', () async {
      final dir = Directory.systemTemp.createTempSync('nondesign-chat-persist2');
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      });

      final a = AppStore()..recoveryDir = dir.path;
      a.appendChat(ChatMessage.progress('理解 brief，撰写产品文档')..steps.add(ChatStep(label: '写入文档', running: true)));
      await a.debugPersistChat();
      await a.chatWritesIdle;

      final b = AppStore()..recoveryDir = dir.path;
      await b.debugLoadChat();

      final card = b.chatMessages.single;
      expect(card.kind, chatKindProgress);
      expect(card.running, false);
      expect(card.ok, false);
      expect(card.detail, '应用重启，运行中断');
    });

    test('clearChat 清内存并删落盘文件', () async {
      final dir = Directory.systemTemp.createTempSync('nondesign-chat-persist3');
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      });

      final store = AppStore()..recoveryDir = dir.path;
      store.appendChat(ChatMessage.user('x'));
      await store.debugPersistChat();
      await store.chatWritesIdle;
      expect(File('${dir.path}/chat.json').existsSync(), isTrue);

      await store.clearChat();
      expect(store.chatMessages, isEmpty);
      expect(File('${dir.path}/chat.json').existsSync(), isFalse, reason: '落盘记录一并删除');
    });

    test('boot 前置外：坏形状文件不毒化（catch-all 尽力而为）', () async {
      final dir = Directory.systemTemp.createTempSync('nondesign-chat-persist4');
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      });
      File('${dir.path}/chat.json').writeAsStringSync('{broken');

      final store = AppStore()..recoveryDir = dir.path;
      await store.debugLoadChat();
      expect(store.chatMessages, isEmpty);
    });
  });
}
