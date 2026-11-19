// 手机 / iPad 竖屏的「聊天全屏 + 工作区画中画」布局面回归（批次 12）。
//
//  * 聊天是主面，右缘常驻胶囊/手势条带；点胶囊才出现 PipWindow；
//  * 浮窗内含 Workspace(embedded: true)，头部拖动改位置、右下手柄缩放，
//    下限 320×280；
//  * 『全屏』铺满堆叠区、『✕』收回浮窗，最大化态不记忆到下一次打开；
//  * 浮窗 rect 持久化到 SharedPreferences：重启恢复（含拖动后的新几何）；
//  * 390×844 / 844×390 / 768×1024 三档开浮窗都没有 RenderFlex 溢出。
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/widgets/chat_pip_shell.dart';
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
        builder: (context, child) =>
            withResponsiveTextScale(context, child ?? const SizedBox.shrink()),
        home: const ShellHost(),
      ),
    );

Future<void> _pumpAt(WidgetTester tester, AppStore store, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(_app(store));
  // 壳层持久化读取是异步的（SharedPreferences），一帧让它落地。
  await tester.pump(const Duration(milliseconds: 80));
}

Rect _pipRect(WidgetTester tester) =>
    tester.widget<PipWindow>(find.byType(PipWindow)).rect;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('390×844：聊天全屏、无工作区；右缘条带与胶囊在场', (tester) async {
    await _pumpAt(tester, _store(), const Size(390, 844));

    expect(find.byType(ChatPiPShell), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-input')), findsOneWidget);
    expect(find.byType(Workspace), findsNothing, reason: '手机不常驻工作区');
    expect(find.byType(PipWindow), findsNothing);
    expect(find.byKey(const ValueKey('pip-edge-handle')), findsOneWidget);
    expect(find.byKey(const ValueKey('pip-edge-capsule')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('点胶囊 → PipWindow 出现且内含嵌入工作区', (tester) async {
    await _pumpAt(tester, _store(), const Size(390, 844));

    await tester.tap(find.byKey(const ValueKey('pip-edge-capsule')));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(PipWindow), findsOneWidget);
    expect(find.byKey(const ValueKey('pip-edge-handle')), findsNothing,
        reason: '开窗后条带让位（收回即恢复）');
    expect(find.byType(Workspace), findsOneWidget);
    expect(tester.widget<Workspace>(find.byType(Workspace)).embedded, isTrue);
    expect(find.byKey(const ValueKey('chat-input')), findsOneWidget,
        reason: '浮窗覆盖在聊天之上，聊天仍在下层');
    expect(tester.takeException(), isNull);
  });

  testWidgets('头部拖动改位置；右下手柄缩放且不小于 320×280', (tester) async {
    await _pumpAt(tester, _store(), const Size(390, 844));
    await tester.tap(find.byKey(const ValueKey('pip-edge-capsule')));
    await tester.pump(const Duration(milliseconds: 100));

    final before = _pipRect(tester);
    await tester.drag(find.byKey(const ValueKey('pip-header')), const Offset(-120, -90));
    await tester.pump(const Duration(milliseconds: 50));
    final moved = _pipRect(tester);
    expect(moved.left, lessThan(before.left), reason: '头部拖动改 left');
    expect(moved.top, lessThan(before.top), reason: '头部拖动改 top');
    expect(moved.size, before.size, reason: '拖动不改尺寸');

    await tester.drag(find.byKey(const ValueKey('pip-resize')), const Offset(40, 20));
    await tester.pump(const Duration(milliseconds: 50));
    final resized = _pipRect(tester);
    expect(resized.width, greaterThan(moved.width));
    expect(resized.height, greaterThan(moved.height));

    // 反向大幅拖 → 钳在最小 320×280（宿主收口）。
    await tester.drag(find.byKey(const ValueKey('pip-resize')), const Offset(-900, -900));
    await tester.pump(const Duration(milliseconds: 50));
    final min = _pipRect(tester);
    // Rect 的 width/height getter 由 LTRB 反推，left 为小数时可能有 1e-13 级
    // 误差——断言语义是「不小于 320×280」，用容差而不是按位相等。
    expect(min.width, greaterThanOrEqualTo(kPipMinSize.width - 0.001));
    expect(min.height, greaterThanOrEqualTo(kPipMinSize.height - 0.001));
    expect(tester.takeException(), isNull);
  });

  testWidgets('右缘左划（向窗内）也能拉出浮窗', (tester) async {
    await _pumpAt(tester, _store(), const Size(390, 844));
    expect(find.byType(PipWindow), findsNothing);

    // kPipOpensFromRightEdge=true：从右缘向左划超过阈值即开（方向常量若
    // 反转，只改 pip_window.dart 的常量，这条断言随之反向）。
    await tester.drag(find.byKey(const ValueKey('pip-edge-handle')), const Offset(-80, 0));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(PipWindow), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('『全屏』铺满堆叠区 → 再点还原；『✕』收回浮窗', (tester) async {
    await _pumpAt(tester, _store(), const Size(390, 844));
    await tester.tap(find.byKey(const ValueKey('pip-edge-capsule')));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.byKey(const ValueKey('pip-max')));
    await tester.pump(const Duration(milliseconds: 80));
    expect(_pipRect(tester), const Rect.fromLTWH(0, 0, 390, 844));

    await tester.tap(find.byKey(const ValueKey('pip-max')));
    await tester.pump(const Duration(milliseconds: 80));
    expect(_pipRect(tester).width, lessThan(390), reason: '还原回浮窗尺寸');

    await tester.tap(find.byKey(const ValueKey('pip-close')));
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.byType(PipWindow), findsNothing);
    expect(find.byKey(const ValueKey('pip-edge-handle')), findsOneWidget,
        reason: '收回后常驻条带恢复');
    expect(tester.takeException(), isNull);
  });

  testWidgets('最大化下关闭 → 重开回到原浮窗尺寸（_pipMax 复位）', (tester) async {
    await _pumpAt(tester, _store(), const Size(390, 844));
    await tester.tap(find.byKey(const ValueKey('pip-edge-capsule')));
    await tester.pump(const Duration(milliseconds: 100));

    final original = _pipRect(tester);
    expect(original.width, lessThan(390), reason: '起点是普通浮窗，不是最大化');

    await tester.tap(find.byKey(const ValueKey('pip-max')));
    await tester.pump(const Duration(milliseconds: 80));
    expect(_pipRect(tester), const Rect.fromLTWH(0, 0, 390, 844));

    await tester.tap(find.byKey(const ValueKey('pip-close')));
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.byType(PipWindow), findsNothing);

    await tester.tap(find.byKey(const ValueKey('pip-edge-capsule')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(PipWindow), findsOneWidget);
    expect(_pipRect(tester), original, reason: '重开回到原浮窗 rect（尺寸与位置）');
    expect(tester.widget<PipWindow>(find.byType(PipWindow)).maximized, isFalse,
        reason: '最大化态随关闭复位');
    expect(tester.takeException(), isNull);
  });

  testWidgets('浮窗 rect 持久化：预置几何在重启后恢复', (tester) async {
    const stored = Rect.fromLTWH(24, 96, 340, 500);
    SharedPreferences.setMockInitialValues({
      ShellStorage.pipRectKey: '${stored.left},${stored.top},${stored.width},${stored.height}',
    });
    await _pumpAt(tester, _store(), const Size(390, 844));
    await tester.tap(find.byKey(const ValueKey('pip-edge-capsule')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(_pipRect(tester), stored, reason: '重启恢复到持久化的浮窗 rect');
    expect(tester.takeException(), isNull);
  });

  testWidgets('拖动后的几何写回 SharedPreferences，重建壳后恢复', (tester) async {
    await _pumpAt(tester, _store(), const Size(390, 844));
    await tester.tap(find.byKey(const ValueKey('pip-edge-capsule')));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.drag(find.byKey(const ValueKey('pip-header')), const Offset(-60, -40));
    await tester.pump(const Duration(milliseconds: 60));
    final dragged = _pipRect(tester);
    await tester.tap(find.byKey(const ValueKey('pip-close')));
    await tester.pump(const Duration(milliseconds: 80));

    // 「重启」：销毁并重建壳（同一份 SharedPreferences）。
    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpAt(tester, _store(), const Size(390, 844));
    await tester.tap(find.byKey(const ValueKey('pip-edge-capsule')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(_pipRect(tester), dragged, reason: '拖动后的 rect 被持久化并恢复');
    expect(tester.takeException(), isNull);
  });

  for (final size in const [Size(390, 844), Size(844, 390), Size(768, 1024), Size(834, 1194)]) {
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
