import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/widgets/three_workbench_panels.dart';

Widget _app(Widget child) => MaterialApp(
  theme: AppTheme.build(dark: true),
  home: Scaffold(body: child),
);

Widget _inspector({
  required ThreeOutlinerItem? item,
  ValueChanged<ThreeInspectorEdit>? onSaveEdit,
}) => _app(
  SizedBox(
    width: 320,
    height: 720,
    child: ThreeNodeInspector(item: item, onSaveEdit: onSaveEdit),
  ),
);

Map<String, dynamic> _spec() => <String, dynamic>{
  'title': 'Saturn',
  'components': <Map<String, dynamic>>[
    <String, dynamic>{'id': 'planet', 'what': '球体', 'size_scale': 1.0},
    <String, dynamic>{'id': 'ring', 'what': '扁平圆环', 'size_scale': 1.8},
  ],
  'materials': <Map<String, dynamic>>[
    <String, dynamic>{'id': 'rock', 'color_hex': '#c9a06a', 'roughness': 0.8},
  ],
  'camera': <String, dynamic>{'view': '略高处斜看'},
};

String _fieldText(WidgetTester tester, String field) => tester
    .widget<TextField>(find.byKey(ValueKey('three-inspector-field-$field')))
    .controller!
    .text;

double _sliderValue(WidgetTester tester, String field) => tester
    .widget<Slider>(find.byKey(ValueKey('three-inspector-field-$field')))
    .value;

bool _buttonEnabled(WidgetTester tester, String key) {
  final Widget widget = tester.widget(find.byKey(ValueKey(key)));
  if (widget is FilledButton) return widget.onPressed != null;
  if (widget is TextButton) return widget.onPressed != null;
  throw StateError('not a button: $key');
}

Future<void> _tap(WidgetTester tester, String key) async {
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pump();
}

void main() {
  group('3D 工作台专属面板', () {
    test('legacy spec → 大纲条目：组件/材质/相机，坏项跳过', () {
      final items = threeOutlinerItemsFromSpec(_spec());
      expect(items, hasLength(4));
      expect(items.first.kind, ThreeOutlinerKind.component);
      expect(items.first.label, '球体');
      expect(items[2].kind, ThreeOutlinerKind.material);
      expect(items[2].label, 'rock');
      expect(items.last.kind, ThreeOutlinerKind.camera);
      expect(threeOutlinerItemsFromSpec(null), isEmpty);

      final bad = threeOutlinerItemsFromSpec(<String, dynamic>{
        'components': <dynamic>[
          <String, dynamic>{'what': 'no-id'},
          'bad',
        ],
      });
      expect(bad, isEmpty);
    });

    test('v2 scene.json → 大纲节点投影：坏节点跳过、无 nodes 返回空', () {
      final items = threeOutlinerItemsFromScene(<String, Object?>{
        'v': 1,
        'nodes': <Object?>[
          <String, Object?>{'id': 'floor', 'type': 'box'},
          <String, Object?>{'id': 'table', 'type': 'box'},
          <String, Object?>{'id': '', 'type': 'box'},
          'bad',
        ],
      });
      expect(items, hasLength(2));
      expect(items.first.kind, ThreeOutlinerKind.node);
      expect(items.first.label, 'floor');
      expect(items.first.detail, 'box');
      expect(threeOutlinerItemsFromScene(null), isEmpty);
      expect(
        threeOutlinerItemsFromScene(<String, Object?>{'nodes': 'bad'}),
        isEmpty,
      );
    });

    testWidgets('大纲列表：标题/条目/选中回调', (tester) async {
      ThreeOutlinerItem? selected;
      final items = threeOutlinerItemsFromSpec(_spec());
      await tester.pumpWidget(
        _app(
          SizedBox(
            width: 236,
            height: 600,
            child: ThreeOutlinerPanel(
              items: items,
              selectedId: items.first.id,
              onSelect: (item) => selected = item,
            ),
          ),
        ),
      );
      expect(
        find.byKey(const ValueKey('three-workbench-outliner')),
        findsOneWidget,
      );
      expect(find.text('场景大纲'), findsOneWidget);
      expect(find.text('球体'), findsOneWidget);
      expect(find.text('rock'), findsOneWidget);
      await tester.tap(find.byKey(ValueKey('three-outliner-${items[2].id}')));
      expect(selected?.kind, ThreeOutlinerKind.material);
    });

    testWidgets('检查器：组件字段预填 + 编辑后保存回调（只带改动字段）', (tester) async {
      ThreeInspectorEdit? saved;
      final items = threeOutlinerItemsFromSpec(_spec());
      await tester.pumpWidget(
        _inspector(item: items.first, onSaveEdit: (edit) => saved = edit),
      );
      expect(
        find.byKey(const ValueKey('three-workbench-inspector')),
        findsOneWidget,
      );
      expect(find.text('组件'), findsOneWidget);
      expect(find.text('size_scale'), findsOneWidget);
      expect(_fieldText(tester, 'what'), '球体');
      expect(_fieldText(tester, 'size_scale'), '1.0');
      expect(_fieldText(tester, 'material'), '');
      expect(_buttonEnabled(tester, 'three-inspector-save'), isFalse);
      expect(_buttonEnabled(tester, 'three-inspector-reset'), isFalse);

      await tester.enterText(
        find.byKey(const ValueKey('three-inspector-field-what')),
        '带环行星',
      );
      await tester.enterText(
        find.byKey(const ValueKey('three-inspector-field-size_scale')),
        '1.25',
      );
      await tester.enterText(
        find.byKey(const ValueKey('three-inspector-field-material')),
        'rock',
      );
      await tester.pump();
      expect(_buttonEnabled(tester, 'three-inspector-save'), isTrue);
      expect(_buttonEnabled(tester, 'three-inspector-reset'), isTrue);

      await _tap(tester, 'three-inspector-save');
      expect(saved, isNotNull);
      expect(saved!.kind, ThreeOutlinerKind.component);
      expect(saved!.id, 'planet');
      expect(saved!.fields, <String, Object?>{
        'what': '带环行星',
        'size_scale': 1.25,
        'material': 'rock',
      });
      expect(
        find.byKey(const ValueKey('three-inspector-error')),
        findsNothing,
      );
    });

    testWidgets('检查器：材质颜色/滑块编辑 → 保存回调（未动字段不写入）', (tester) async {
      ThreeInspectorEdit? saved;
      final items = threeOutlinerItemsFromSpec(_spec());
      await tester.pumpWidget(
        _inspector(item: items[2], onSaveEdit: (edit) => saved = edit),
      );
      expect(find.text('材质'), findsOneWidget);
      expect(_fieldText(tester, 'color_hex'), '#c9a06a');
      expect(find.text('#c9a06a'), findsOneWidget);
      expect(find.text('c9a06a'), findsNothing);
      expect(_sliderValue(tester, 'roughness'), 0.8);
      expect(_sliderValue(tester, 'metalness'), 0.0);

      await tester.enterText(
        find.byKey(const ValueKey('three-inspector-field-color_hex')),
        '#112233',
      );
      tester
          .widget<Slider>(
            find.byKey(const ValueKey('three-inspector-field-roughness')),
          )
          .onChanged!(0.35);
      await tester.pump();
      expect(_buttonEnabled(tester, 'three-inspector-save'), isTrue);

      await _tap(tester, 'three-inspector-save');
      expect(saved, isNotNull);
      expect(saved!.kind, ThreeOutlinerKind.material);
      expect(saved!.id, 'rock');
      expect(saved!.fields['color_hex'], '#112233');
      expect(saved!.fields['roughness'], closeTo(0.35, 1e-9));
      // 没动过的金属感不写进补丁（避免把面板默认值当成用户修改）。
      expect(saved!.fields.containsKey('metalness'), isFalse);
    });

    testWidgets('检查器：重置恢复磁盘值且不发保存回调', (tester) async {
      ThreeInspectorEdit? saved;
      final items = threeOutlinerItemsFromSpec(_spec());
      await tester.pumpWidget(
        _inspector(item: items.first, onSaveEdit: (edit) => saved = edit),
      );
      await tester.enterText(
        find.byKey(const ValueKey('three-inspector-field-what')),
        '临时名字',
      );
      await tester.enterText(
        find.byKey(const ValueKey('three-inspector-field-size_scale')),
        '2.5',
      );
      await tester.pump();
      expect(_buttonEnabled(tester, 'three-inspector-save'), isTrue);

      await _tap(tester, 'three-inspector-reset');
      expect(saved, isNull);
      expect(_fieldText(tester, 'what'), '球体');
      expect(_fieldText(tester, 'size_scale'), '1.0');
      expect(_buttonEnabled(tester, 'three-inspector-save'), isFalse);
      expect(_buttonEnabled(tester, 'three-inspector-reset'), isFalse);
    });

    testWidgets('检查器：非法颜色本地报错、不发保存回调；修正后可保存', (tester) async {
      ThreeInspectorEdit? saved;
      final items = threeOutlinerItemsFromSpec(_spec());
      await tester.pumpWidget(
        _inspector(item: items[2], onSaveEdit: (edit) => saved = edit),
      );
      await tester.enterText(
        find.byKey(const ValueKey('three-inspector-field-color_hex')),
        'c9a06a',
      );
      await tester.pump();
      await _tap(tester, 'three-inspector-save');
      expect(saved, isNull);
      expect(
        find.byKey(const ValueKey('three-inspector-error')),
        findsOneWidget,
      );
      expect(find.text('颜色要写成 #RRGGBB（例如 #c9a06a）'), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('three-inspector-field-color_hex')),
        '#123456',
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('three-inspector-error')),
        findsNothing,
      );
      await _tap(tester, 'three-inspector-save');
      expect(saved, isNotNull);
      expect(saved!.fields, <String, Object?>{'color_hex': '#123456'});
    });

    testWidgets('检查器：相机视角编辑 → 保存回调', (tester) async {
      ThreeInspectorEdit? saved;
      final items = threeOutlinerItemsFromSpec(_spec());
      await tester.pumpWidget(
        _inspector(item: items.last, onSaveEdit: (edit) => saved = edit),
      );
      expect(find.text('相机'), findsOneWidget);
      expect(_fieldText(tester, 'view'), '略高处斜看');
      await tester.enterText(
        find.byKey(const ValueKey('three-inspector-field-view')),
        '正面平视',
      );
      await tester.pump();
      await _tap(tester, 'three-inspector-save');
      expect(saved, isNotNull);
      expect(saved!.kind, ThreeOutlinerKind.camera);
      expect(saved!.id, 'camera');
      expect(saved!.fields, <String, Object?>{'view': '正面平视'});
    });

    testWidgets('检查器：scene 节点保持只读（不做 scene.json 编辑）', (tester) async {
      ThreeInspectorEdit? saved;
      final items = threeOutlinerItemsFromScene(<String, Object?>{
        'v': 1,
        'nodes': <Object?>[
          <String, Object?>{'id': 'floor', 'type': 'box'},
        ],
      });
      await tester.pumpWidget(
        _inspector(item: items.single, onSaveEdit: (edit) => saved = edit),
      );
      expect(find.text('节点'), findsOneWidget);
      expect(find.text('type'), findsOneWidget);
      expect(find.text('box'), findsOneWidget);
      expect(find.byKey(const ValueKey('three-inspector-save')), findsNothing);
      expect(find.byKey(const ValueKey('three-inspector-reset')), findsNothing);
      expect(
        find.textContaining('场景节点属性编辑在场景编辑器批次接入'),
        findsOneWidget,
      );
      expect(saved, isNull);
    });

    testWidgets('检查器：无选中项时显示场景概览', (tester) async {
      await tester.pumpWidget(
        _app(
          const SizedBox(
            width: 300,
            height: 600,
            child: ThreeNodeInspector(sceneChars: 42, currentPass: 'structure'),
          ),
        ),
      );
      expect(find.text('场景概览'), findsOneWidget);
      expect(find.text('structure'), findsOneWidget);
      expect(find.text('42 字符'), findsOneWidget);
      expect(
        find.textContaining('查看并编辑属性'),
        findsOneWidget,
      );
    });

    test('检查器补丁合并：只改目标对象、不改原规范、找不到对象返回 null', () {
      final spec = _spec();
      final merged = applyThreeInspectorEdit(
        spec,
        const ThreeInspectorEdit(
          kind: ThreeOutlinerKind.component,
          id: 'planet',
          fields: <String, Object?>{
            'what': '大球',
            'size_scale': 1.5,
            'material': 'rock',
          },
        ),
      );
      expect(merged, isNotNull);
      final components = merged!['components'] as List;
      final planet = components.first as Map;
      expect(planet['what'], '大球');
      expect(planet['size_scale'], 1.5);
      expect(planet['material'], 'rock');
      expect((components[1] as Map)['what'], '扁平圆环');
      // 原规范一个字段都不改（纯函数，深拷贝目标项）。
      final untouched = (spec['components'] as List).first as Map;
      expect(untouched['what'], '球体');
      expect(untouched['size_scale'], 1.0);

      final materialMerged = applyThreeInspectorEdit(
        spec,
        const ThreeInspectorEdit(
          kind: ThreeOutlinerKind.material,
          id: 'rock',
          fields: <String, Object?>{'metalness': 0.25},
        ),
      );
      expect(
        ((materialMerged!['materials'] as List).first as Map)['metalness'],
        0.25,
      );
      expect(
        ((materialMerged['materials'] as List).first as Map)['color_hex'],
        '#c9a06a',
      );

      final cameraMerged = applyThreeInspectorEdit(
        spec,
        const ThreeInspectorEdit(
          kind: ThreeOutlinerKind.camera,
          id: 'camera',
          fields: <String, Object?>{'view': '正面平视'},
        ),
      );
      expect(cameraMerged!['camera'], <String, Object?>{'view': '正面平视'});

      expect(
        applyThreeInspectorEdit(
          spec,
          const ThreeInspectorEdit(
            kind: ThreeOutlinerKind.component,
            id: 'ghost',
            fields: <String, Object?>{'what': '幽灵'},
          ),
        ),
        isNull,
      );
      // 场景节点不走 legacy 规范编辑。
      expect(
        applyThreeInspectorEdit(
          spec,
          const ThreeInspectorEdit(
            kind: ThreeOutlinerKind.node,
            id: 'floor',
            fields: <String, Object?>{'x': 1},
          ),
        ),
        isNull,
      );
      expect(
        () => applyThreeInspectorEdit(
          spec,
          const ThreeInspectorEdit(
            kind: ThreeOutlinerKind.component,
            id: 'planet',
            fields: <String, Object?>{'shape': 'sphere'},
          ),
        ),
        throwsArgumentError,
      );
    });

    test('检查器补丁校验：字段白名单 + 数值/颜色/文本边界', () {
      expect(
        validateThreeInspectorEdit(
          const ThreeInspectorEdit(
            kind: ThreeOutlinerKind.component,
            id: 'planet',
            fields: <String, Object?>{},
          ),
        ),
        '还没有要保存的修改',
      );
      expect(
        validateThreeInspectorEdit(
          const ThreeInspectorEdit(
            kind: ThreeOutlinerKind.component,
            id: 'planet',
            fields: <String, Object?>{'what': '  '},
          ),
        ),
        '组件名称不能为空',
      );
      expect(
        validateThreeInspectorEdit(
          const ThreeInspectorEdit(
            kind: ThreeOutlinerKind.component,
            id: 'planet',
            fields: <String, Object?>{'size_scale': 0},
          ),
        ),
        contains('大于 0'),
      );
      expect(
        validateThreeInspectorEdit(
          const ThreeInspectorEdit(
            kind: ThreeOutlinerKind.component,
            id: 'planet',
            fields: <String, Object?>{'size_scale': 'big'},
          ),
        ),
        contains('大于 0'),
      );
      expect(
        validateThreeInspectorEdit(
          const ThreeInspectorEdit(
            kind: ThreeOutlinerKind.component,
            id: 'planet',
            fields: <String, Object?>{'shape': 'sphere'},
          ),
        ),
        contains('不支持'),
      );
      expect(
        validateThreeInspectorEdit(
          const ThreeInspectorEdit(
            kind: ThreeOutlinerKind.material,
            id: 'rock',
            fields: <String, Object?>{'color_hex': 'red'},
          ),
        ),
        contains('#RRGGBB'),
      );
      expect(
        validateThreeInspectorEdit(
          const ThreeInspectorEdit(
            kind: ThreeOutlinerKind.material,
            id: 'rock',
            fields: <String, Object?>{'roughness': 1.5},
          ),
        ),
        contains('0 到 1'),
      );
      expect(
        validateThreeInspectorEdit(
          const ThreeInspectorEdit(
            kind: ThreeOutlinerKind.camera,
            id: 'camera',
            fields: <String, Object?>{'view': ''},
          ),
        ),
        '相机视角不能为空',
      );
      expect(
        validateThreeInspectorEdit(
          const ThreeInspectorEdit(
            kind: ThreeOutlinerKind.node,
            id: 'floor',
            fields: <String, Object?>{'x': 1},
          ),
        ),
        contains('场景编辑器批次'),
      );
      expect(
        validateThreeInspectorEdit(
          const ThreeInspectorEdit(
            kind: ThreeOutlinerKind.component,
            id: 'planet',
            fields: <String, Object?>{'what': '大球', 'size_scale': 1.5},
          ),
        ),
        isNull,
      );
      expect(
        validateThreeInspectorEdit(
          const ThreeInspectorEdit(
            kind: ThreeOutlinerKind.material,
            id: 'rock',
            fields: <String, Object?>{
              'color_hex': '#112233',
              'roughness': 0.35,
              'metalness': 0.0,
            },
          ),
        ),
        isNull,
      );
      expect(
        validateThreeInspectorEdit(
          const ThreeInspectorEdit(
            kind: ThreeOutlinerKind.camera,
            id: 'camera',
            fields: <String, Object?>{'view': '正面平视'},
          ),
        ),
        isNull,
      );
    });

    testWidgets('底部状态条：正常/阻塞/门 verdict', (tester) async {
      await tester.pumpWidget(
        _app(
          SizedBox(
            width: 900,
            height: 30,
            child: ThreeWorkbenchStatusBar(
              currentPass: 'materials',
              blocked: false,
              attempts: 1,
              gateVerdict: 'ERROR',
            ),
          ),
        ),
      );
      expect(
        find.byKey(const ValueKey('three-workbench-status')),
        findsOneWidget,
      );
      expect(find.text('当前层 · materials'), findsOneWidget);
      expect(find.text('尝试 1'), findsOneWidget);
      expect(find.text('门 · ERROR'), findsOneWidget);
    });
  });
}
