// 画中画工作区 S4（docs/plan-chat-stream-shell.md §2/§5）的路由面回归：
// - view=='chat' 且宽 ≥1100：chat 与 workspace 同屏（常驻分栏）；
// - view=='design'（有项目）：只有全屏 Workspace、无 chat-input，Esc 回 chat
//   ——既有全屏语义不变（chat_stream_test 的同一锚点的 S4 复核）；
// - 折叠：只剩 chat；chat 顶栏「工作区」按钮切换折叠态；
// - 无项目空态用显式「新建空画板」建项目，且**不**隐式 setView('design')
//   （store.openWorkspace 的旧语义只在无宿主/产物卡路径保留）。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:nondesign/core/api.dart';
import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/main.dart';
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

void main() {
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
