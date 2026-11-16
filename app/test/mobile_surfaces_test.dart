// 手机宽度（402×874 / 390×844）下的全部主要界面回归：
// Welcome 之外的壳层与工作台 body 也曾有固定宽度（文档工具条右溢 246px、
// 空画布卡 520 宽、视频 300px 配置列、设置 860×600 被夹成 310 宽等）。
// 这里在手机尺寸渲染真实组件，断言无 RenderFlex 溢出。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/widgets/a2ui_workspace.dart';
import 'package:nondesign/widgets/play_view.dart';
import 'package:nondesign/widgets/portfolio_view.dart';
import 'package:nondesign/widgets/settings_dialog.dart';
import 'package:nondesign/widgets/three_workspace.dart';
import 'package:nondesign/widgets/video_workspace.dart';
import 'package:nondesign/widgets/workspace.dart';

const _phoneWidths = [402.0, 390.0];

AppStore _store({bool project = false}) {
  final store = AppStore();
  store.ready = true;
  store.hasProject = project;
  store.settings = AppSettings(providerId: 'deepseek', modelId: 'deepseek-v4.1-flash');
  return store;
}

Widget _wrap(AppStore store, Widget child) => ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(theme: AppTheme.build(dark: true), home: child),
    );

Future<void> _pumpAt(WidgetTester tester, Widget child, double width,
    {AppStore? store}) async {
  await tester.binding.setSurfaceSize(Size(width, 874));
  await tester.pumpWidget(_wrap(store ?? _store(), child));
  await tester.pump(const Duration(milliseconds: 150));
  expect(tester.takeException(), isNull);
  await tester.binding.setSurfaceSize(null);
}

void main() {
  for (final width in _phoneWidths) {
    testWidgets('video workspace body fits ${width.toInt()}px', (tester) async {
      await _pumpAt(tester, const Scaffold(body: VideoWorkspace()), width);
      expect(find.text('标杆示例'), findsOneWidget);
      expect(find.text('加载示例'), findsOneWidget);
    });

    testWidgets('3D workspace body fits ${width.toInt()}px', (tester) async {
      await _pumpAt(tester, const Scaffold(body: ThreeWorkspace()), width);
      expect(find.text('直接制作 3D'), findsOneWidget);
    });

    testWidgets('A2UI workspace body fits ${width.toInt()}px', (tester) async {
      await _pumpAt(tester, const Scaffold(body: A2uiWorkspace()), width);
      expect(find.text('A2UI 小应用'), findsWidgets);
    });

    testWidgets('portfolio fits ${width.toInt()}px', (tester) async {
      await _pumpAt(tester, const Scaffold(body: PortfolioView()), width);
      expect(find.text('作品集'), findsOneWidget);
    });

    testWidgets('workspace docs view fits ${width.toInt()}px', (tester) async {
      final store = _store(project: true)..view = 'docs';
      store.docs = Docs(prd: '# PRD\n\n一段产品需求文档正文。', ui: '');
      await _pumpAt(tester, const Workspace(), width, store: store);
      expect(find.text('产品需求'), findsOneWidget);
    });

    testWidgets('workspace design view fits ${width.toInt()}px', (tester) async {
      final store = _store(project: true)..view = 'design';
      await _pumpAt(tester, const Workspace(), width, store: store);
      expect(find.text('从一句话开始'), findsOneWidget);
    });

    testWidgets('settings dialog fits ${width.toInt()}px', (tester) async {
      await tester.binding.setSurfaceSize(Size(width, 874));
      final store = _store();
      await tester.pumpWidget(_wrap(
        store,
        Builder(builder: (context) {
          return Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showSettingsDialog(context),
                child: const Text('open'),
              ),
            ),
          );
        }),
      ));
      await tester.tap(find.text('open'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
      expect(find.text('设置'), findsOneWidget);
      expect(find.text('模型与端点'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('play view fits ${width.toInt()}px', (tester) async {
      final store = _store(project: true)..view = 'play';
      await _pumpAt(tester, const PlayView(), width, store: store);
    });

    testWidgets('workspace bottom sheets fit ${width.toInt()}px', (tester) async {
      final store = _store(project: true)..view = 'design';
      await tester.binding.setSurfaceSize(Size(width, 874));
      await tester.pumpWidget(_wrap(store, const Workspace()));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.text('项目面板'));
      await tester.pump(const Duration(milliseconds: 350));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());

      await tester.pumpWidget(_wrap(store, const Workspace()));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.text('NoN 面板'));
      await tester.pump(const Duration(milliseconds: 350));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.binding.setSurfaceSize(null);
    });
  }

  testWidgets('wide desktop keeps the two-column video workspace', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    await tester.pumpWidget(_wrap(_store(), const Scaffold(body: VideoWorkspace())));
    await tester.pump(const Duration(milliseconds: 150));
    expect(tester.takeException(), isNull);
    expect(find.text('标杆示例'), findsOneWidget);
    await tester.binding.setSurfaceSize(null);
  });
}
