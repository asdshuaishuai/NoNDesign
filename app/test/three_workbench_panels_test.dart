import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/widgets/three_workbench_panels.dart';

Widget _app(Widget child) => MaterialApp(
  theme: AppTheme.build(dark: true),
  home: Scaffold(body: child),
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

    testWidgets('检查器：组件/材质/相机只读属性；空态显示场景概览', (tester) async {
      final items = threeOutlinerItemsFromSpec(_spec());
      await tester.pumpWidget(
        _app(
          Row(
            children: <Widget>[
              Expanded(
                child: ThreeNodeInspector(
                  item: items.first,
                  sceneChars: 120,
                  currentPass: 'blockout',
                ),
              ),
              Expanded(
                child: ThreeNodeInspector(
                  item: items[2],
                  sceneChars: 0,
                  currentPass: '',
                ),
              ),
            ],
          ),
        ),
      );
      expect(find.text('球体'), findsOneWidget);
      expect(find.text('组件'), findsOneWidget);
      expect(find.text('size_scale'), findsOneWidget);
      expect(find.text('rock'), findsOneWidget);
      expect(find.text('材质'), findsOneWidget);
      expect(find.text('c9a06a'), findsNothing);
      expect(find.text('#c9a06a'), findsOneWidget);

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
