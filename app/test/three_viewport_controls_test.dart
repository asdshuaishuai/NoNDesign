// 3D 视口控制浮层（批次 15 第一批）纯 UI 契约。
//
// 组件不依赖 WebView / ThreeService：这里只验证三件事：
//  1. 可用时，视角预设 / 网格开关 / 重置各自回传正确语义（网格回传的是
//     「目标状态」，不是「反转了什么」）；
//  2. 网格激活态可见（图标 + 激活色由 gridVisible 驱动，组件不自己翻转）；
//  3. 禁用时所有入口 onPressed 为 null、点击零回调，且每个入口的 tooltip
//     说明真实原因（不是一句没有信息量的通用话）。
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nondesign/core/theme.dart';
import 'package:nondesign/widgets/three_viewport_controls.dart';

Widget _host(ThreeViewportControls controls) => MaterialApp(
  theme: AppTheme.build(dark: true),
  home: Scaffold(body: Center(child: controls)),
);

ThreeViewportControls _controls({
  bool enabled = true,
  bool gridVisible = false,
  List<ThreeViewPreset>? presets,
  List<bool>? grids,
  VoidCallback? onReset,
  String disabledHint = '预览还没就绪，视角控制暂不可用',
}) => ThreeViewportControls(
  enabled: enabled,
  gridVisible: gridVisible,
  disabledHint: disabledHint,
  onViewPreset: (preset) => presets?.add(preset),
  onGridChanged: (visible) => grids?.add(visible),
  onReset: onReset ?? () {},
);

void main() {
  testWidgets('可用时：视角预设 / 网格 / 重置依次回传语义', (tester) async {
    final presets = <ThreeViewPreset>[];
    final grids = <bool>[];
    var resets = 0;
    await tester.pumpWidget(
      _host(
        ThreeViewportControls(
          enabled: true,
          gridVisible: false,
          onViewPreset: presets.add,
          onGridChanged: grids.add,
          onReset: () => resets++,
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('three-viewport-controls')),
      findsOneWidget,
    );
    for (final preset in ThreeViewPreset.values) {
      await tester.tap(find.byKey(ValueKey('three-view-${preset.id}')));
    }
    await tester.tap(find.byKey(const ValueKey('three-view-grid')));
    await tester.tap(find.byKey(const ValueKey('three-view-reset')));
    await tester.pump();

    expect(presets, <ThreeViewPreset>[
      ThreeViewPreset.front,
      ThreeViewPreset.top,
      ThreeViewPreset.iso,
    ]);
    expect(grids, <bool>[true], reason: '关闭 → 点击回传目标状态 true');
    expect(resets, 1);
    // 组件不自己翻转网格状态：入参 false 时仍显示「未开启」图标。
    expect(find.byIcon(Icons.grid_4x4_outlined), findsOneWidget);
  });

  testWidgets('网格激活态：显示激活图标，点击回传目标状态 false', (tester) async {
    final grids = <bool>[];
    await tester.pumpWidget(_host(_controls(gridVisible: true, grids: grids)));

    expect(find.byIcon(Icons.grid_on), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('three-view-grid')));
    await tester.pump();

    expect(grids, <bool>[false]);
  });

  testWidgets('禁用时：入口全部禁用、点击零回调、tooltip 说明真实原因', (tester) async {
    final presets = <ThreeViewPreset>[];
    final grids = <bool>[];
    var resets = 0;
    const hint = '预览还没就绪，视角控制暂不可用';
    await tester.pumpWidget(
      _host(
        _controls(
          enabled: false,
          presets: presets,
          grids: grids,
          onReset: () => resets++,
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('three-viewport-controls')),
      findsOneWidget,
    );
    final keys = <Key>[
      for (final preset in ThreeViewPreset.values)
        ValueKey('three-view-${preset.id}'),
      const ValueKey('three-view-grid'),
      const ValueKey('three-view-reset'),
    ];
    for (final key in keys) {
      final button = tester.widget<TextButton>(find.byKey(key));
      expect(button.onPressed, isNull, reason: '$key 必须禁用');
      await tester.tap(find.byKey(key));
    }
    await tester.pump();

    expect(presets, isEmpty);
    expect(grids, isEmpty);
    expect(resets, 0);
    // 每个入口都有 tooltip，且文案是真实原因（不是通用空话）。
    expect(find.byTooltip(hint), findsNWidgets(keys.length));
  });
}
