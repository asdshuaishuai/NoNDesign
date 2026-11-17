// 画中画工作区 S4（docs/plan-chat-stream-shell.md §2/§5）的布局面回归：
// - 900 宽（<1100）不并排，右缘出现常驻胶囊/手势条带；
// - 点胶囊 → PipWindow 浮窗，内含 Workspace(embedded: true)；
// - 头部拖动改位置；右下手柄缩放改尺寸且钳在 320×280 下限；
// - 『全屏』铺满堆叠区、『✕』收回浮窗；
// - 平板竖屏 768 与手机 390 打开浮窗后均无 RenderFlex 溢出。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/widgets/pip_window.dart';
import 'package:nondesign/widgets/shell_host.dart';
import 'package:nondesign/widgets/workspace.dart';

AppStore _store({bool project = true}) {
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

Widget _app(AppStore store) => ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(
        theme: AppTheme.build(dark: true),
        scaffoldMessengerKey: rootMessengerKey,
        builder: (context, child) =>
            withResponsiveTextScale(context, child ?? const SizedBox.shrink()),
        home: const ChatWorkspaceHost(),
      ),
    );

Future<void> _pumpAt(WidgetTester tester, AppStore store, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(_app(store));
  await tester.pump(const Duration(milliseconds: 150));
}

Rect _pipRect(WidgetTester tester) =>
    tester.widget<PipWindow>(find.byType(PipWindow)).rect;

void main() {
  testWidgets('900 宽：不并排、右缘条带与胶囊在场，无浮窗', (tester) async {
    await _pumpAt(tester, _store(), const Size(900, 800));

    expect(find.byKey(const ValueKey('chat-input')), findsOneWidget);
    expect(find.byType(Workspace), findsNothing, reason: '<1100 不常驻分栏');
    expect(find.byKey(const ValueKey('chat-shell-workspace-pane')), findsNothing);
    expect(find.byType(PipWindow), findsNothing);
    expect(find.byKey(const ValueKey('pip-edge-handle')), findsOneWidget);
    expect(find.byKey(const ValueKey('pip-edge-capsule')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('点胶囊 → PipWindow 出现且内含嵌入工作区', (tester) async {
    await _pumpAt(tester, _store(), const Size(900, 800));

    await tester.tap(find.byKey(const ValueKey('pip-edge-capsule')));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(PipWindow), findsOneWidget);
    expect(find.byKey(const ValueKey('pip-edge-handle')), findsNothing,
        reason: '开窗后条带让位（收回即恢复）');
    expect(find.byType(Workspace), findsOneWidget);
    expect(tester.widget<Workspace>(find.byType(Workspace)).embedded, isTrue);
    expect(find.byKey(const ValueKey('chat-pip-workspace-pane')), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-input')), findsOneWidget,
        reason: '浮窗覆盖在聊天之上，聊天仍在下层');
    expect(tester.takeException(), isNull);
  });

  testWidgets('头部拖动改位置；右下手柄缩放且不小于 320×280', (tester) async {
    await _pumpAt(tester, _store(), const Size(900, 800));
    await tester.tap(find.byKey(const ValueKey('pip-edge-capsule')));
    await tester.pump(const Duration(milliseconds: 100));

    final before = _pipRect(tester);
    await tester.drag(find.byKey(const ValueKey('pip-header')), const Offset(-120, -90));
    await tester.pump(const Duration(milliseconds: 50));
    final moved = _pipRect(tester);
    expect(moved.left, lessThan(before.left), reason: '头部拖动改 left');
    expect(moved.top, lessThan(before.top), reason: '头部拖动改 top');
    expect(moved.size, before.size, reason: '拖动不改尺寸');

    await tester.drag(find.byKey(const ValueKey('pip-resize')), const Offset(90, 60));
    await tester.pump(const Duration(milliseconds: 50));
    final resized = _pipRect(tester);
    expect(resized.width, greaterThan(moved.width));
    expect(resized.height, greaterThan(moved.height));

    // 反向大幅拖 → 钳在最小 320×280（host 收口）。
    await tester.drag(find.byKey(const ValueKey('pip-resize')), const Offset(-900, -900));
    await tester.pump(const Duration(milliseconds: 50));
    final min = _pipRect(tester);
    // Rect 的 width/height getter 由 LTRB 反推，left 为小数时可能有 1e-13 级
    // 误差（8.0 + 320.0 - 8.0 在二进制里不总是精确）——断言语义是「不小于
    // 320×280」，用容差而不是按位相等。
    expect(min.width, greaterThanOrEqualTo(kPipMinSize.width - 0.001));
    expect(min.height, greaterThanOrEqualTo(kPipMinSize.height - 0.001));
    expect(tester.takeException(), isNull);
  });

  testWidgets('右缘左划（向窗内）也能拉出浮窗', (tester) async {
    await _pumpAt(tester, _store(), const Size(900, 800));
    expect(find.byType(PipWindow), findsNothing);

    // kPipOpensFromRightEdge=true：从右缘向左划超过阈值即开（方向常量若
    // 反转，只改 pip_window.dart 的常量，这条断言随之反向）。
    await tester.drag(find.byKey(const ValueKey('pip-edge-handle')), const Offset(-80, 0));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(PipWindow), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('『全屏』铺满堆叠区 → 再点还原；『✕』收回浮窗', (tester) async {
    await _pumpAt(tester, _store(), const Size(900, 800));
    await tester.tap(find.byKey(const ValueKey('pip-edge-capsule')));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.byKey(const ValueKey('pip-max')));
    await tester.pump(const Duration(milliseconds: 80));
    expect(_pipRect(tester), const Rect.fromLTWH(0, 0, 900, 800));

    await tester.tap(find.byKey(const ValueKey('pip-max')));
    await tester.pump(const Duration(milliseconds: 80));
    expect(_pipRect(tester).width, lessThan(900), reason: '还原回浮窗尺寸');

    await tester.tap(find.byKey(const ValueKey('pip-close')));
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.byType(PipWindow), findsNothing);
    expect(find.byKey(const ValueKey('pip-edge-handle')), findsOneWidget,
        reason: '收回后常驻条带恢复');
    expect(tester.takeException(), isNull);
  });

  testWidgets('分栏『全屏工作区』在宿主内铺满，再点还原（view 不变）', (tester) async {
    await _pumpAt(tester, _store(), const Size(1280, 860));
    expect(find.byKey(const ValueKey('chat-input')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('chat-shell-fullscreen')));
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.byKey(const ValueKey('chat-input')), findsNothing,
        reason: '工作区铺满宿主（宿主内全屏，不是换路由）');
    expect(find.byType(Workspace), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-shell-workspace-pane')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('chat-shell-fullscreen')));
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.byKey(const ValueKey('chat-input')), findsOneWidget,
        reason: '还原回分栏');
    expect(tester.takeException(), isNull);
  });

  testWidgets('浮窗内『全屏工作区』= 最大化浮窗（不换路由）', (tester) async {
    await _pumpAt(tester, _store(), const Size(900, 800));
    await tester.tap(find.byKey(const ValueKey('pip-edge-capsule')));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.byKey(const ValueKey('chat-shell-fullscreen')));
    await tester.pump(const Duration(milliseconds: 80));
    expect(_pipRect(tester), const Rect.fromLTWH(0, 0, 900, 800));
    expect(find.byKey(const ValueKey('chat-pip-window')), findsOneWidget,
        reason: '浮窗仍在（宿主内最大化，review pip-1）');

    await tester.tap(find.byKey(const ValueKey('chat-shell-fullscreen')));
    await tester.pump(const Duration(milliseconds: 80));
    expect(_pipRect(tester).width, lessThan(900), reason: '还原回浮窗尺寸');
    expect(tester.takeException(), isNull);
  });

  for (final size in const [Size(768, 1024), Size(390, 844)]) {
    testWidgets('${size.width.toInt()}×${size.height.toInt()}：聊天流 + 浮窗无溢出', (tester) async {
      await _pumpAt(tester, _store(), size);
      expect(tester.takeException(), isNull, reason: '聊天流单列');

      await tester.tap(find.byKey(const ValueKey('pip-edge-capsule')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(PipWindow), findsOneWidget);
      expect(tester.takeException(), isNull, reason: '浮窗在工作区面板内不溢出');
    });
  }
}
