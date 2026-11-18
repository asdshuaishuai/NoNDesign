// 响应式壳的路由面回归（批次 12）。
//
// 手机 / iPad 竖屏（ChatPiPShell）：
//  * 聊天是主面；工作区只在画中画里（不常驻、不换路由）；
//  * 浮窗里的嵌入窄轨只切面板，不改 store.view；
//  * 产物卡把工作区面板「打开」成画中画，而不是 setView('design')；
//  * 嵌入宿主登记期间 run/打开项目都不把聊天主面拆掉。
//
// 桌面 / iPad 横屏（DesktopShell）：
//  * 主面是 Workspace / Welcome，聊天只在右侧窄栏（view=='chat' 不再整块路由）；
//  * play / portfolio / plugin:* 先于壳路由，全幅无窄栏；
//  * Esc 不抢工作区（桌面没有整块聊天路由可回）。
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
import 'package:nondesign/main.dart';
import 'package:nondesign/widgets/chat_pip_shell.dart';
import 'package:nondesign/widgets/desktop_shell.dart';
import 'package:nondesign/widgets/pip_window.dart';
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

/// 走真实路由（NonApp）：壳判定与生产一致（测试宿主 defaultTargetPlatform
/// 是 android，按视口短边分类）。
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

/// 脚本化模型（store_test 同款副本）：每次 doStream 依序取脚本步。
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

/// Dart 运行时 store：MockClient 过能力门，模型走 scripted 注入，recovery 落
/// 临时目录（不污染 ~/.nondesign）。
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

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('手机 / iPad 竖屏：聊天全屏 + 工作区画中画', () {
    testWidgets('390×844 view=chat + 项目：聊天主面，工作区只在画中画', (tester) async {
      final store = _store(project: true);
      await _pumpAt(tester, _rootApp(store), const Size(390, 844));

      expect(find.byType(ChatPiPShell), findsOneWidget);
      expect(find.byType(DesktopShell), findsNothing);
      expect(find.byKey(const ValueKey('chat-input')), findsOneWidget);
      expect(find.byType(Workspace), findsNothing, reason: '工作区不常驻手机主面');
      expect(find.byKey(const ValueKey('pip-edge-capsule')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('点胶囊 → 画中画含嵌入工作区；嵌入窄轨不切 store.view', (tester) async {
      final store = _store(project: true);
      await _pumpAt(tester, _rootApp(store), const Size(390, 844));

      await tester.tap(find.byKey(const ValueKey('pip-edge-capsule')));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byKey(const ValueKey('chat-pip-window')), findsOneWidget);
      expect(find.byType(Workspace), findsOneWidget);
      expect(tester.widget<Workspace>(find.byType(Workspace)).embedded, isTrue);
      expect(find.byKey(const ValueKey('workspace-embedded-rail')), findsOneWidget);
      expect(find.byKey(const ValueKey('chat-input')), findsOneWidget,
          reason: '聊天仍在浮窗下层存活');

      await tester.tap(find.byKey(const ValueKey('embedded-rail-history')));
      await tester.pump(const Duration(milliseconds: 80));
      expect(store.view, 'chat', reason: '浮窗里的窄轨不得把聊天主面换掉');
      expect(store.panel, 'history');
      expect(find.byKey(const ValueKey('chat-pip-window')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('产物卡（原型）在宿主内打开画中画，不换路由', (tester) async {
      final store = _store(project: true);
      store.appendChat(ChatMessage.artifact(kind: artifactPrototype, title: '原型A'));
      await _pumpAt(tester, _rootApp(store), const Size(390, 844));
      expect(find.byKey(const ValueKey('chat-pip-window')), findsNothing);

      await tester.tap(find.text('原型A'));
      await tester.pump(const Duration(milliseconds: 100));

      expect(store.view, 'chat', reason: '产物卡不得 setView(design) 拆掉聊天主面');
      expect(find.byKey(const ValueKey('chat-pip-window')), findsOneWidget);
      expect(find.byType(Workspace), findsOneWidget);
      expect(find.byKey(const ValueKey('chat-input')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('无项目空态：新建空画板后 hasProject=true 且 view 仍为 chat', (tester) async {
      final store = _store();
      // newProject(empty:) 的空路径不触网，但入口要求 api 非空（先建后用纪律）。
      store.api = NoNDesignApi('http://127.0.0.1:9');
      await _pumpAt(tester, _rootApp(store), const Size(390, 844));

      await tester.tap(find.byKey(const ValueKey('pip-edge-capsule')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('工作区 · 等待第一块画板'), findsOneWidget);
      expect(find.byType(Workspace), findsNothing);

      await tester.tap(find.byKey(const ValueKey('chat-shell-create-board')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));

      expect(store.hasProject, isTrue);
      expect(store.view, 'chat', reason: '面板内建板不隐式 setView(design)');
      expect(find.byKey(const ValueKey('chat-input')), findsOneWidget);
      expect(find.byType(Workspace), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('离线（api==null）点新建空画板：给提示，不静默', (tester) async {
      final store = _store(); // api 保持 null（离线/移动端未启用本地引擎）
      await _pumpAt(tester, _rootApp(store), const Size(390, 844));
      await tester.tap(find.byKey(const ValueKey('pip-edge-capsule')));
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.byKey(const ValueKey('chat-shell-create-board')));
      await tester.pump(const Duration(milliseconds: 80));

      expect(store.hasProject, isFalse);
      expect(store.view, 'chat');
      expect(find.byKey(const ValueKey('chat-shell-pane-hint')), findsOneWidget,
          reason: 'store.newProject 在 api==null 时静默 false，空态必须自证');
      expect(find.textContaining('离线预览'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('嵌入宿主登记：开浮窗计数、关浮窗归零', (tester) async {
      final store = _store(project: true);
      await _pumpAt(tester, _rootApp(store), const Size(390, 844));
      expect(store.embeddedHostActive, isFalse);

      await tester.tap(find.byKey(const ValueKey('pip-edge-capsule')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(store.embeddedHostActive, isTrue, reason: '画中画里的嵌入 Workspace 已登记');

      await tester.tap(find.byKey(const ValueKey('pip-close')));
      await tester.pump(const Duration(milliseconds: 80));
      expect(find.byType(Workspace), findsNothing);
      expect(store.embeddedHostActive, isFalse);

      await tester.tap(find.byKey(const ValueKey('pip-edge-capsule')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(store.embeddedHostActive, isTrue);

      await tester.pumpWidget(const SizedBox.shrink());
      expect(store.embeddedHostActive, isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('嵌入宿主期间 runBuild / runRefine 不拆聊天主面', (tester) async {
      final store = _dartStore();
      store.debugAgentModelOverride = _ScriptedModel([
        [mockText('完成')],
        [mockText('完成')],
      ]);
      await _pumpAt(tester, _rootApp(store), const Size(390, 844));
      await tester.tap(find.byKey(const ValueKey('pip-edge-capsule')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(store.embeddedHostActive, isTrue);

      expect(await tester.runAsync(() => store.runBuild('生成首页')), isTrue);
      expect(store.view, 'chat', reason: 'BUILD 不把聊天主面切走');
      expect(await tester.runAsync(() => store.runRefine('调整圆角')), isTrue);
      expect(store.view, 'chat', reason: 'REFINE 不把聊天主面切走');
      await tester.pump(const Duration(milliseconds: 120));

      expect(find.byKey(const ValueKey('chat-input')), findsOneWidget);
      expect(find.byKey(const ValueKey('chat-pip-window')), findsOneWidget);
      expect(tester.takeException(), isNull);
      // 只是防止 helper 被误删；真实断言在上面的 run 结果里。
      expect(store.timeline.isNotEmpty || store.agentBusy, isTrue);
    });

    testWidgets('iPad 竖屏 768×1024：同一套 Chat+PiP（裁决 C）', (tester) async {
      final store = _store(project: true);
      await _pumpAt(tester, _rootApp(store), const Size(768, 1024));
      expect(find.byType(ChatPiPShell), findsOneWidget);
      expect(find.byKey(const ValueKey('chat-input')), findsOneWidget);
      expect(find.byKey(const ValueKey('desktop-chat-rail')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('pip-edge-capsule')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(PipWindow), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('桌面 / iPad 横屏：Workspace 主面 + 右侧窄栏', () {
    testWidgets('1440 view=design：Workspace + 聊天窄栏，Esc 不抢工作区', (tester) async {
      final store = _store(project: true)..view = 'design';
      await _pumpAt(tester, _rootApp(store), const Size(1440, 900));

      expect(find.byType(DesktopShell), findsOneWidget);
      expect(find.byType(Workspace), findsOneWidget);
      expect(tester.widget<Workspace>(find.byType(Workspace)).embedded, isFalse);
      expect(tester.widget<Workspace>(find.byType(Workspace)).showRightPanel, isFalse,
          reason: '右侧只能有一个窄栏');
      expect(find.byKey(const ValueKey('desktop-chat-rail')), findsOneWidget);
      expect(find.byKey(const ValueKey('agent-input')), findsOneWidget,
          reason: 'NaN（聊天 + 任务指令）在窄栏里，而不是整块路由');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 80));
      expect(store.view, 'design', reason: '桌面壳没有整块聊天路由，Esc 不切走工作区');
      expect(tester.takeException(), isNull);
    });

    testWidgets('view=chat 在桌面不再整块路由：仍是 Workspace + 窄栏（有项目）', (tester) async {
      final store = _store(project: true)..view = 'chat';
      await _pumpAt(tester, _rootApp(store), const Size(1440, 900));

      expect(find.byType(Workspace), findsOneWidget);
      expect(find.byKey(const ValueKey('desktop-chat-rail')), findsOneWidget);
      expect(find.byKey(const ValueKey('chat-open-workspace')), findsNothing,
          reason: '窄栏形态没有「工作区」入口（工作区就是主面）');
      expect(tester.takeException(), isNull);
    });

    testWidgets('1024×768（iPad 横版）：Workspace 优先，窄栏折叠成 44px', (tester) async {
      final store = _store(project: true)..view = 'design';
      await _pumpAt(tester, _rootApp(store), const Size(1024, 768));

      expect(find.byType(DesktopShell), findsOneWidget);
      expect(find.byType(Workspace), findsOneWidget);
      final strip = find.byKey(const ValueKey('desktop-chat-rail-strip'));
      expect(strip, findsOneWidget);
      expect(tester.getSize(strip).width, 44);
      expect(find.byKey(const ValueKey('desktop-chat-rail')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    for (final view in const ['play', 'portfolio']) {
      testWidgets('view=$view 全幅无窄栏；Esc 回 design', (tester) async {
        final store = _store(project: true)..view = view;
        await _pumpAt(tester, _rootApp(store), const Size(1440, 900));

        expect(find.byType(DesktopShell), findsNothing);
        expect(find.byType(Workspace), findsOneWidget);
        expect(find.byKey(const ValueKey('desktop-chat-rail')), findsNothing);
        expect(find.byKey(const ValueKey('desktop-chat-rail-strip')), findsNothing);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump(const Duration(milliseconds: 80));
        expect(store.view, 'design');
        expect(tester.takeException(), isNull);
      });
    }

    // 用户裁决 2026-11-18：3D / 视频 / 热应用在桌面壳里也不能丢掉右侧 NaN
    // 窄栏——左侧是固定工作区，右侧是常驻的 NaN（所有工作都经它下发）。
    for (final view in const ['plugin:three', 'plugin:video', 'plugin:hotapp']) {
      testWidgets('view=$view 仍在桌面壳内、右侧 NaN 常驻；Esc 回主页', (tester) async {
        final store = _store(project: true)..view = view;
        await _pumpAt(tester, _rootApp(store), const Size(1440, 900));

        expect(find.byType(DesktopShell), findsOneWidget);
        expect(find.byType(Workspace), findsOneWidget);
        expect(find.byKey(const ValueKey('desktop-chat-rail')), findsOneWidget);
        // 工作区切换条常驻（手动切换四个工作区的唯一入口）。
        expect(find.byKey(const ValueKey('rail-workspace-three')), findsOneWidget);
        expect(tester.takeException(), isNull);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump(const Duration(milliseconds: 80));
        expect(store.view, 'home');
        expect(tester.takeException(), isNull);
      });
    }
  });
}
