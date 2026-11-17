// 聊天流主面（S1，docs/plan-chat-stream-shell.md §2）的测试面：
// - store 全链：sendChat → 进度卡（事件镜像步骤）→ 产物卡（原型），写路径
//   仍走引擎 AgentGate（复用 store_test 的本地 mock 模式，零外联）；
// - 卡片渲染：用户/进度/产物/A2UI 四类卡 + A2UI 动作回流续跑；
// - 默认主面切换：chatStreamHome 开/关 ↔ 经典 Welcome；view=='chat' 恒路由；
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
import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/main.dart';
import 'package:nondesign/widgets/chat_stream.dart';
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

/// 启一个按请求路径分发响应的本地 HTTP mock（store_test 同款副本）。
Future<(String, Future<void> Function())> _mockServer(
  Map<String, FutureOr<Map<String, dynamic>> Function(Map<String, dynamic> body)> routes,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final chunks = await request.fold<List<int>>([], (a, b) => a..addAll(b));
    final body = chunks.isEmpty ? <String, dynamic>{} : jsonDecode(utf8.decode(chunks)) as Map<String, dynamic>;
    final handler = routes[request.uri.path];
    final out = handler == null ? {'ok': false, 'error': 'no_route'} : await handler(body);
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(out));
    await request.response.close();
  });
  return ('http://127.0.0.1:${server.port}', () => server.close(force: true));
}

Map<String, dynamic> _envelope({required String mbt, String entry = 'home'}) => {
      'ok': true,
      'mbt': mbt,
      'entry': entry,
      'revision': 1,
      'artboards': [
        {'id': entry, 'name': entry, 'width': 390, 'height': 844, 'nodes': []},
      ],
      'flows': [],
    };

/// chat 全链 harness：/engine/apply 可录制（gate/op）、/engine/render 齐
/// 备；store 预置文档（sendChat 直接走 BUILD）与 dart 运行时。
Future<(AppStore, Map<String, dynamic>, Future<void> Function())> _chatHarness() async {
  final rec = <String, dynamic>{'gates': <String>[], 'ops': <String>[], 'renderCalls': 0};
  final (base, close) = await _mockServer({
    '/engine/apply': (body) {
      (rec['gates'] as List<String>).add((body['gate'] ?? 'human').toString());
      (rec['ops'] as List<String>).add((body['op'] ?? '').toString());
      return {
        ..._envelope(mbt: 'MBT_HOME'),
        'artboards': [
          {'id': 'home', 'name': 'home', 'width': 390, 'height': 844, 'nodes': []},
        ],
      };
    },
    '/engine/render': (body) {
      rec['renderCalls'] = (rec['renderCalls'] as int) + 1;
      return _envelope(mbt: (body['mbt'] ?? '').toString());
    },
  });
  final dir = Directory.systemTemp.createTempSync('nondesign-chat-test');
  final store = AppStore();
  store.api = NoNDesignApi(base);
  store.recoveryDir = dir.path;
  store.registry = ModelRegistry.fromJson({
    'providers': {
      'testp': {
        'api': base,
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
  store.settings.baseUrl = base;
  store.hasProject = true;
  store.projectName = '仪表盘';
  store.view = 'chat';
  store.docs.prd = '已有的 PRD';
  return (store, rec, () async {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
    await close();
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
      final (store, rec, close) = await _chatHarness();
      store.debugAgentModelOverride = _ScriptedBuildModel([
        [mockToolCall(toolName: 'design_op', input: {'op': 'create home 390 844'})],
        [mockToolCall(toolName: 'finish', input: {'summary': '建好首页'})],
      ]);

      final ok = await store.sendChat('搭一个仪表盘');

      expect(ok, true);
      // 写路径仍是引擎 AgentGate（聊天流不改变引擎门纪律）。
      expect(rec['gates'], ['agent']);
      expect(rec['ops'], ['create home 390 844']);
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
      final store = AppStore();
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
      expect(find.text('design_op'), findsNWidgets(2));
      expect(find.text('42ms'), findsOneWidget);
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
      final store = AppStore()..ready = true;
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

  group('默认主面切换（NonApp 路由）', () {
    AppStore rootStore() {
      final store = AppStore();
      store.ready = true;
      store.hasProject = false;
      store.view = 'design';
      return store;
    }

    Widget rootApp(AppStore store) => ChangeNotifierProvider<AppStore>.value(
          value: store,
          child: const NonApp(),
        );

    testWidgets('chatStreamHome 默认 true：无项目主面是聊天流', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 860));
      final store = rootStore();
      expect(store.settings.chatStreamHome, true, reason: '默认开（用户决策）');
      await tester.pumpWidget(rootApp(store));
      await tester.pump(const Duration(milliseconds: 80));

      expect(find.byKey(const ValueKey('chat-input')), findsOneWidget);
      expect(find.text('从一句话开始'), findsOneWidget);
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('设置关掉 chatStreamHome → 经典 Welcome；再开 → 聊天流', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 860));
      final store = rootStore();
      await tester.pumpWidget(rootApp(store));
      await tester.pump(const Duration(milliseconds: 80));

      store.settings.chatStreamHome = false;
      store.notifyListeners();
      await tester.pump(const Duration(milliseconds: 80));

      expect(find.textContaining('把想法变成'), findsOneWidget, reason: '经典 Welcome 回归');
      expect(find.byKey(const ValueKey('chat-input')), findsNothing);

      store.settings.chatStreamHome = true;
      store.notifyListeners();
      await tester.pump(const Duration(milliseconds: 80));
      expect(find.byKey(const ValueKey('chat-input')), findsOneWidget);
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('有项目走 Workspace；view==chat 恒路由聊天流；Esc 从工作区回聊天流', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 860));
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
      await tester.pumpWidget(rootApp(store));
      await tester.pump(const Duration(milliseconds: 120));

      expect(find.byType(Workspace), findsOneWidget, reason: '有项目 → 现有设计视图');
      expect(find.byKey(const ValueKey('chat-input')), findsNothing);

      // 聊天主面下，设计壳内 Esc 返回聊天流。
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 80));
      expect(store.view, 'chat');
      expect(find.byKey(const ValueKey('chat-input')), findsOneWidget);

      // view=='chat' 是显式视图：有项目也路由聊天流；切回 design 再进 Workspace。
      store.setView('design');
      await tester.pump(const Duration(milliseconds: 80));
      expect(find.byType(Workspace), findsOneWidget);
      await tester.binding.setSurfaceSize(null);
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
