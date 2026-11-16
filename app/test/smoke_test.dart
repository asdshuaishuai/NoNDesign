import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/widgets/canvas_view.dart';
import 'package:nondesign/widgets/docs_view.dart';
import 'package:nondesign/widgets/welcome.dart';
import 'package:nondesign/widgets/workspace.dart';

AppStore _store() {
  final store = AppStore();
  store.ready = true;
  store.settings = AppSettings(providerId: 'deepseek', modelId: 'deepseek-v4.1-flash');
  store.registry = const ModelRegistry(providers: {}, fetchedAt: '');
  return store;
}

Widget _wrap(AppStore store, Widget child) {
  return ChangeNotifierProvider<AppStore>.value(
    value: store,
    child: MaterialApp(
      theme: AppTheme.build(dark: true),
      scaffoldMessengerKey: rootMessengerKey,
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  testWidgets('welcome renders hero and input', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    final store = _store();
    await tester.pumpWidget(_wrap(
      store,
      Welcome(
        onNewProject: () {},
        onOpenPath: (_) {},
        onSettings: () {},
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('NoNDesign'), findsWidgets);
    expect(find.textContaining('把想法变成'), findsOneWidget);
    expect(find.text('开始创作'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('canvas paints an artboard and nodes', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    final store = _store();
    store.hasProject = true;
    store.projectName = 'smoke';
    store.activeBoard = 'home';
    store.mbt = '---\nmoonviz:\n  format: visual-document\n  revision: 1\n  entry: home\n---\n';
    store.render = RenderEnvelope(
      ok: true,
      entry: 'home',
      revision: 1,
      mbt: store.mbt,
      artboards: [
        Artboard(
          id: 'home',
          name: 'home',
          width: 390,
          height: 844,
          nodes: [
            CanvasNode(
              id: 'title',
              parent: 'root',
              kind: 'text',
              component: 'heading',
              name: 'title',
              text: '欢迎回来',
              x: 24,
              y: 48,
              w: 300,
              h: 40,
              style: const NodeStyle(fill: 'none', textColor: '#111827', fontSize: 24),
            ),
            CanvasNode(
              id: 'cta',
              parent: 'root',
              kind: 'rect',
              component: 'button',
              name: 'cta',
              text: '开始',
              x: 24,
              y: 120,
              w: 160,
              h: 44,
              style: const NodeStyle(fill: '#7C8CFF', textColor: '#FFFFFF', radius: 8),
            ),
          ],
        ),
      ],
    );
    await tester.pumpWidget(_wrap(store, const CanvasView()));
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.byType(CanvasView), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('workspace shell renders titlebar, rail, canvas and agent dock', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    final store = _store();
    store.hasProject = true;
    store.projectName = 'smoke';
    store.activeBoard = 'home';
    store.mbt = '---\nmoonviz:\n  format: visual-document\n  revision: 1\n  entry: home\n---\n';
    store.render = RenderEnvelope(
      ok: true,
      entry: 'home',
      revision: 1,
      mbt: store.mbt,
      artboards: [
        Artboard(id: 'home', name: 'home', width: 390, height: 844, nodes: const []),
      ],
    );
    await tester.pumpWidget(ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(
        theme: AppTheme.build(dark: true),
        scaffoldMessengerKey: rootMessengerKey,
        home: const Workspace(),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('smoke'), findsWidgets);
    expect(find.text('NoN'), findsWidgets);
    expect(find.textContaining('问 NoN'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('docs view renders tabs and empty state', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    final store = _store();
    store.hasProject = true;
    store.projectName = 'smoke';
    await tester.pumpWidget(_wrap(store, const DocsView()));
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.text('产品需求'), findsOneWidget);
    expect(find.text('UI 说明'), findsOneWidget);
    expect(find.text('设计规范'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.binding.setSurfaceSize(null);
  });
}
