// 通用检查器（属性表驱动）框架测试。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nondesign/core/inspect/check_field.dart';
import 'package:nondesign/widgets/check_panel.dart';

/// 测试用控制器：记录写回。
class _FakeController extends WorkbenchCheckController {
  _FakeController(this._sheet);

  CheckSheet? _sheet;
  final List<(String, Object?)> writes = <(String, Object?)>[];

  @override
  CheckSheet? get sheet => _sheet;

  void replace(CheckSheet? s) {
    _sheet = s;
    notifySelectionChanged();
  }

  @override
  Future<bool> update(String key, Object? value) async {
    writes.add((key, value));
    return true;
  }
}

CheckSheet _sheet() => const CheckSheet(
  title: '节点「柱子」',
  subtitle: '网格节点 · 来自 scene.json',
  kindLabel: '节点',
  fields: <CheckField>[
    CheckField(
      key: 'name',
      label: '名称',
      kind: CheckFieldKind.text,
      value: '柱子',
    ),
    CheckField(
      key: 'height',
      label: '高度',
      kind: CheckFieldKind.number,
      value: 2,
      unit: 'm',
      min: 0.1,
      max: 10,
    ),
    CheckField(
      key: 'color',
      label: '颜色',
      kind: CheckFieldKind.color,
      value: 0xFF9A8C7A,
    ),
    CheckField(
      key: 'visible',
      label: '可见',
      kind: CheckFieldKind.toggle,
      value: true,
    ),
    CheckField(
      key: 'material',
      label: '材质',
      kind: CheckFieldKind.select,
      value: '木纹',
      options: <String>['木纹', '金属'],
    ),
    CheckField(
      key: 'source',
      label: '来源',
      kind: CheckFieldKind.readOnly,
      value: 'scene.json',
      hint: '事实源',
    ),
  ],
);

void main() {
  testWidgets('CheckPanel：无选中时给可行动提示', (WidgetTester tester) async {
    final _FakeController c = _FakeController(null);
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: CheckPanel(controller: c)),
      ),
    );
    expect(find.byKey(const ValueKey('check-panel-empty')), findsOneWidget);
    expect(find.text('选中一个元素'), findsOneWidget);
  });

  testWidgets('CheckPanel：渲染标题/类型徽标/各字段', (WidgetTester tester) async {
    final _FakeController c = _FakeController(_sheet());
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: CheckPanel(controller: c)),
      ),
    );
    expect(find.byKey(const ValueKey('check-panel')), findsOneWidget);
    expect(find.text('节点「柱子」'), findsOneWidget);
    expect(find.text('节点'), findsOneWidget);
    for (final String key in <String>[
      'name',
      'height',
      'color',
      'visible',
      'material',
      'source',
    ]) {
      expect(find.byKey(ValueKey('check-row:$key')), findsOneWidget);
    }
    expect(find.byKey(const ValueKey('check-input:name')), findsOneWidget);
    expect(find.byKey(const ValueKey('check-toggle:visible')), findsOneWidget);
    expect(find.byKey(const ValueKey('check-select:material')), findsOneWidget);
    expect(find.byKey(const ValueKey('check-value:source')), findsOneWidget);
    // 只读字段不应变成输入框
    expect(find.byKey(const ValueKey('check-input:source')), findsNothing);
  });

  testWidgets('CheckPanel：文本/数值写回（数值按范围夹取）', (WidgetTester tester) async {
    final _FakeController c = _FakeController(_sheet());
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: CheckPanel(controller: c)),
      ),
    );
    // 文本：失焦提交
    await tester.enterText(
      find.byKey(const ValueKey('check-input:name')),
      '柱子A',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(c.writes.any((w) => w.$1 == 'name' && w.$2 == '柱子A'), isTrue);

    // 数值：超上限被夹到 max
    await tester.enterText(
      find.byKey(const ValueKey('check-input:height')),
      '99',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(c.writes.any((w) => w.$1 == 'height' && w.$2 == 10), isTrue);
  });

  testWidgets('CheckPanel：开关与下拉写回', (WidgetTester tester) async {
    final _FakeController c = _FakeController(_sheet());
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: CheckPanel(controller: c)),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('check-toggle:visible')));
    await tester.pumpAndSettle();
    expect(c.writes.any((w) => w.$1 == 'visible' && w.$2 == false), isTrue);

    await tester.tap(find.byKey(const ValueKey('check-select:material')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('金属').last);
    await tester.pumpAndSettle();
    expect(c.writes.any((w) => w.$1 == 'material' && w.$2 == '金属'), isTrue);
  });

  testWidgets('CheckPanel：选中变化后重取属性表', (WidgetTester tester) async {
    final _FakeController c = _FakeController(_sheet());
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: CheckPanel(controller: c)),
      ),
    );
    expect(find.text('节点「柱子」'), findsOneWidget);
    c.replace(
      const CheckSheet(
        title: '镜头「开场」',
        kindLabel: '镜头',
        fields: <CheckField>[
          CheckField(
            key: 'duration',
            label: '时长',
            kind: CheckFieldKind.number,
            value: 3,
            unit: 's',
          ),
        ],
      ),
    );
    await tester.pump();
    expect(find.text('镜头「开场」'), findsOneWidget);
    expect(find.byKey(const ValueKey('check-row:duration')), findsOneWidget);

    // 清空选中 → 回到空态
    c.replace(null);
    await tester.pump();
    expect(find.byKey(const ValueKey('check-panel-empty')), findsOneWidget);
  });

  testWidgets('CheckPanel：1.3 倍字号下无溢出', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(348, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final _FakeController c = _FakeController(_sheet());
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
        child: MaterialApp(
          home: Scaffold(body: CheckPanel(controller: c)),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });
}
