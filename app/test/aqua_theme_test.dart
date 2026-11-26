// Aqua（浅色主题）组件与可达性守门。
//
// 用户裁决 2026-11-26：**浅色主题即 Aqua**，不新增第三套主题。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nondesign/core/theme.dart';
import 'package:nondesign/widgets/aqua.dart';

void main() {
  test('凝胶与面板文字对比度达到 4.5:1', () {
    // 白字压在凝胶最深处（底部蓝）——Aqua 默认按钮的 period-correct 组合。
    expect(
      AquaMetrics.contrastRatio(Colors.white, NonPalette.aquaGelBottom),
      greaterThanOrEqualTo(4.5),
    );
    // 正文/次级文字压在白面板上。
    expect(
      AquaMetrics.contrastRatio(NonPalette.light.ink, NonPalette.light.panel),
      greaterThanOrEqualTo(4.5),
    );
    expect(
      AquaMetrics.contrastRatio(NonPalette.light.ink2, NonPalette.light.panel),
      greaterThanOrEqualTo(4.5),
    );
  });

  testWidgets('AquaPinstripes 静态绘制：不产生持续动画帧', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AquaPinstripes(child: SizedBox(width: 200, height: 100)),
        ),
      ),
    );
    expect(find.byType(RepaintBoundary), findsWidgets);
    // 连续 pump 不应有待办帧（条纹是纯静态绘制）。
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('AquaGelButton：可点、禁用、焦点环', (WidgetTester tester) async {
    int tapped = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: AquaGelButton(label: '生成', onPressed: () => tapped++),
          ),
        ),
      ),
    );
    await tester.tap(find.text('生成'));
    await tester.pump();
    expect(tapped, 1);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(child: AquaGelButton(label: '禁用', onPressed: null)),
        ),
      ),
    );
    await tester.tap(find.text('禁用'));
    await tester.pump();
    expect(tapped, 1, reason: '禁用态不应触发回调');

    // 键盘焦点：聚焦后应出现焦点环（Container 带 boxShadow）。
    final FocusNode node = FocusNode();
    addTearDown(node.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: AquaGelButton(
              label: '焦点',
              onPressed: () {},
              focusNode: node,
            ),
          ),
        ),
      ),
    );
    node.requestFocus();
    await tester.pumpAndSettle();
    expect(node.hasFocus, isTrue);
    final Container withRing = tester
        .widgetList<Container>(find.byType(Container))
        .firstWhere(
          (Container c) =>
              c.decoration is BoxDecoration &&
              ((c.decoration! as BoxDecoration).boxShadow?.isNotEmpty ?? false),
        );
    expect(withRing, isNotNull, reason: '聚焦后必须可见焦点环');
  });

  testWidgets('脉冲在主按钮开启，但 prefers-reduced-motion 下静止', (
    WidgetTester tester,
  ) async {
    // 正常：脉冲会持续走帧。
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: AquaGelButton(label: '默认', onPressed: () {}, pulse: true),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      tester.binding.transientCallbackCount,
      greaterThan(0),
      reason: '正常模式下脉冲应有动画帧',
    );

    // 减动效：完全静止。
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: AquaGelButton(label: '默认', onPressed: () {}, pulse: true),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.binding.transientCallbackCount, 0, reason: '减少动效时脉冲必须静止');
  });

  testWidgets('口香糖窗口控件：三个球、可点、有语义标签', (WidgetTester tester) async {
    final List<String> taps = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: AquaGumdrops(
              onClose: () => taps.add('close'),
              onMinimize: () => taps.add('minimize'),
              onZoom: () => taps.add('zoom'),
            ),
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('aqua-gumdrop-close')), findsOneWidget);
    expect(find.byKey(const ValueKey('aqua-gumdrop-minimize')), findsOneWidget);
    expect(find.byKey(const ValueKey('aqua-gumdrop-zoom')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('aqua-gumdrop-close')));
    await tester.tap(find.byKey(const ValueKey('aqua-gumdrop-minimize')));
    await tester.tap(find.byKey(const ValueKey('aqua-gumdrop-zoom')));
    await tester.pump();
    expect(taps, <String>['close', 'minimize', 'zoom']);
    expect(find.bySemanticsLabel('关闭'), findsOneWidget);
  });

  test('浅色主题 = Aqua 调色板', () {
    final ThemeData theme = AppTheme.build(dark: false);
    final NonPalette? palette = theme.extension<NonPalette>();
    expect(palette, isNotNull);
    expect(palette!.accent, NonPalette.light.accent);
    expect(palette.accent, const Color(0xFF1862D8), reason: '浅色主题应使用 Aqua 水蓝');
    expect(theme.scaffoldBackgroundColor, NonPalette.light.bg);
    // 深色主题不受影响。
    final NonPalette darkPalette = AppTheme.build(dark: true)
        .extension<NonPalette>()!;
    expect(darkPalette.accent, NonPalette.dark.accent);
  });

  test('AquaMetrics 常量与令牌一致', () {
    expect(AquaMetrics.gumdropSize, 12);
    expect(AquaMetrics.buttonHeight, greaterThanOrEqualTo(26));
    expect(AquaMetrics.pulsePeriod, const Duration(milliseconds: 2400));
    expect(AquaMetrics.maxPanelRadius, NonRadius.lg);
  });
}
