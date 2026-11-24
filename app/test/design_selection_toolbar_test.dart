import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/widgets/design_selection_toolbar.dart';

Widget _app(Widget child) => MaterialApp(
  theme: AppTheme.build(dark: true),
  home: Scaffold(body: Center(child: child)),
);

void main() {
  testWidgets('选区浮条：复制/删除/取消选中都可点，不出现全局工具', (tester) async {
    var duplicated = 0;
    var deleted = 0;
    var dismissed = 0;
    await tester.pumpWidget(
      _app(
        DesignSelectionToolbar(
          onDuplicate: () => duplicated++,
          onDelete: () => deleted++,
          onDismiss: () => dismissed++,
        ),
      ),
    );
    expect(
      find.byKey(const ValueKey('design-selection-toolbar')),
      findsOneWidget,
    );
    expect(find.byTooltip('复制节点'), findsOneWidget);
    expect(find.byTooltip('删除节点'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('design-selection-duplicate')));
    await tester.tap(find.byKey(const ValueKey('design-selection-delete')));
    await tester.tap(find.byKey(const ValueKey('design-selection-dismiss')));
    expect(duplicated, 1);
    expect(deleted, 1);
    expect(dismissed, 1);
  });
}
