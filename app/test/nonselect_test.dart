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

  // 新建项目对话框（workspace.dart）的形态：空白画板条目 value=null。
  // 回归锚——M3 DropdownMenu 对 null 值条目：initialSelection 按
  // entry.value == null 命中首条、onSelected(null) 原样透传（真机红屏
  // 历史来自经典 DropdownButton 的 itemHeight 断言，这里顺带守住菜单
  // 打开不炸）。
  testWidgets('nonSelect maps null-value blank entry without runtime assert', (tester) async {
    String? picked;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Center(
              child: nonSelect<String?>(
                ctx,
                value: null,
                items: const [
                  DropdownMenuItem<String?>(value: null, child: Text('空白画板')),
                  DropdownMenuItem<String?>(value: 'tpl_pc', child: Text('桌面 · tpl_pc')),
                ],
                onChanged: (v) => picked = v,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 初始 null 命中首条：字段（EditableText）内容即「空白画板」。
    // （关闭态菜单也会预渲染同名 Text，故只锚字段不锚全文计数。）
    expect(find.widgetWithText(TextField, '空白画板'), findsOneWidget);
    await tester.tap(find.byType(DropdownMenu<String?>));
    await tester.pumpAndSettle();
    // 菜单展开且模板条目在场。
    expect(find.text('桌面 · tpl_pc').last, findsOneWidget);
    await tester.tap(find.text('桌面 · tpl_pc').last);
    await tester.pumpAndSettle();
    expect(picked, 'tpl_pc');
    // 重开选回空白画板：null 原样透传。
    await tester.tap(find.byType(DropdownMenu<String?>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('空白画板').last);
    await tester.pumpAndSettle();
    expect(picked, null);
  });
}
