import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nondesign/widgets/common.dart';

void main() {
  testWidgets('nonSelect opens compact menu without itemHeight assertion', (tester) async {
    String? picked;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Center(
              child: nonSelect<String>(
                ctx,
                value: 'a',
                items: const [
                  DropdownMenuItem(value: 'a', child: Text('Alpha')),
                  DropdownMenuItem(value: 'b', child: Text('Beta')),
                ],
                onChanged: (v) => picked = v,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(DropdownMenu<String>));
    await tester.pumpAndSettle();
    // 菜单展开且行高收敛（32px 形态来自 MenuItemButton style）
    expect(find.text('Beta').last, findsOneWidget);
    await tester.tap(find.text('Beta').last);
    await tester.pumpAndSettle();
    expect(picked, 'b');
  });
}
