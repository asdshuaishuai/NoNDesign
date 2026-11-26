// 工作台四栏目（呈现效果/文档/规范/源码）的框架测试。
//
// 用户裁决 2026-11-27：所有工作台统一四栏目；源码以项目结构展示。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nondesign/core/theme.dart';
import 'package:nondesign/widgets/workbench_views.dart';

void main() {
  WorkbenchColumnData fullData() => const WorkbenchColumnData(
    docsMarkdown: '# 需求\n\n一句话定位。\n\n## 结构\n- 第一段\n- 第二段\n',
    specJson: <String, Object?>{
      'v': 1,
      'kind': 'three',
      'nodes': <String>['floor'],
    },
    specSummary: '已通过校验 · 1 节点',
    sourceFiles: <WorkbenchSourceFile>[
      WorkbenchSourceFile(path: 'src/scene.js', content: 'export default 1'),
      WorkbenchSourceFile(
        path: 'src/lib/util.js',
        content: 'export const x = 1',
      ),
    ],
  );

  Future<void> pumpColumns(
    WidgetTester tester, {
    required WorkbenchColumn column,
    required ValueChanged<WorkbenchColumn> onChanged,
    required WorkbenchColumnData data,
    ThemeData? theme,
    Size size = const Size(1280, 800),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: theme ?? AppTheme.build(dark: true),
        home: Scaffold(
          body: WorkbenchColumns(
            column: column,
            onColumnChanged: onChanged,
            data: data,
            present: const Center(
              child: SizedBox(
                key: ValueKey('fake-present'),
                width: 10,
                height: 10,
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('四栏目条固定四项，切到呈现效果时渲染原呈现面', (WidgetTester tester) async {
    WorkbenchColumn current = WorkbenchColumn.docs;
    await pumpColumns(
      tester,
      column: current,
      onChanged: (WorkbenchColumn c) => current = c,
      data: fullData(),
    );
    for (final WorkbenchColumn c in WorkbenchColumn.values) {
      expect(
        find.byKey(ValueKey(c.tabKey)),
        findsOneWidget,
        reason: '栏目 ${c.label} 的稳定 Key 必须存在',
      );
      expect(find.text(c.label), findsOneWidget);
    }
    await tester.tap(find.byKey(const ValueKey('workbench-column-present')));
    await tester.pump();
    expect(current, WorkbenchColumn.present);
    // 由调用方重渲染 → 呈现面出现
    await pumpColumns(
      tester,
      column: current,
      onChanged: (WorkbenchColumn c) => current = c,
      data: fullData(),
    );
    expect(find.byKey(const ValueKey('fake-present')), findsOneWidget);
  });

  testWidgets('文档栏目：有 markdown 时渲染正文，无文档时给可行动空态', (WidgetTester tester) async {
    await pumpColumns(
      tester,
      column: WorkbenchColumn.docs,
      onChanged: (WorkbenchColumn _) {},
      data: fullData(),
    );
    expect(find.byKey(const ValueKey('workbench-docs-body')), findsOneWidget);
    expect(find.text('需求'), findsOneWidget);
    expect(find.text('第一段'), findsOneWidget);

    await pumpColumns(
      tester,
      column: WorkbenchColumn.docs,
      onChanged: (WorkbenchColumn _) {},
      data: const WorkbenchColumnData(),
    );
    expect(find.byKey(const ValueKey('workbench-docs-empty')), findsOneWidget);
    expect(find.text('还没有文档'), findsOneWidget);
  });

  testWidgets('规范栏目：摘要 + JSON；无规范时空态', (WidgetTester tester) async {
    await pumpColumns(
      tester,
      column: WorkbenchColumn.spec,
      onChanged: (WorkbenchColumn _) {},
      data: fullData(),
    );
    expect(find.byKey(const ValueKey('workbench-spec-body')), findsOneWidget);
    expect(find.textContaining('已通过校验'), findsOneWidget);
    expect(find.textContaining('"kind": "three"'), findsOneWidget);

    await pumpColumns(
      tester,
      column: WorkbenchColumn.spec,
      onChanged: (WorkbenchColumn _) {},
      data: const WorkbenchColumnData(),
    );
    expect(find.byKey(const ValueKey('workbench-spec-empty')), findsOneWidget);
    expect(find.text('还没有规范'), findsOneWidget);
  });

  testWidgets('源码栏目：按结构列出文件，点选切换内容；无源码时空态', (WidgetTester tester) async {
    await pumpColumns(
      tester,
      column: WorkbenchColumn.source,
      onChanged: (WorkbenchColumn _) {},
      data: fullData(),
    );
    expect(find.byKey(const ValueKey('workbench-source-body')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('workbench-source-file:src/scene.js')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('workbench-source-file:src/lib/util.js')),
      findsOneWidget,
    );
    // 默认显示第一个文件内容
    expect(find.textContaining('export default 1'), findsOneWidget);
    // 点击第二个文件 → 内容切换
    await tester.tap(
      find.byKey(const ValueKey('workbench-source-file:src/lib/util.js')),
    );
    await tester.pump();
    expect(find.textContaining('export const x = 1'), findsOneWidget);

    await pumpColumns(
      tester,
      column: WorkbenchColumn.source,
      onChanged: (WorkbenchColumn _) {},
      data: const WorkbenchColumnData(),
    );
    expect(
      find.byKey(const ValueKey('workbench-source-empty')),
      findsOneWidget,
    );
    expect(find.text('还没有源码'), findsOneWidget);
  });

  testWidgets('浅色（Aqua）下栏目条用白面且不溢出（1280 与 900）', (WidgetTester tester) async {
    for (final Size size in <Size>[
      const Size(1280, 800),
      const Size(900, 700),
    ]) {
      await pumpColumns(
        tester,
        column: WorkbenchColumn.present,
        onChanged: (WorkbenchColumn _) {},
        data: fullData(),
        theme: AppTheme.build(dark: false),
        size: size,
      );
      expect(tester.takeException(), isNull, reason: '尺寸 $size 不应溢出');
      expect(
        find.byKey(const ValueKey('workbench-columns-bar')),
        findsOneWidget,
      );
    }
  });
}
