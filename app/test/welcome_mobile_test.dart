// 移动端 Welcome 页回归：真机实测（iPhone 17 / 402×874）桌面双栏在手机宽度下
// 右溢 198px、底溢 327px（右列被压成单字竖排、开始按钮叠到作品集卡上）。
// 窄屏必须走单列滚动路径；这里直接在手机尺寸渲染真实 Welcome 组件并断言无异常。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/widgets/welcome.dart';

AppStore _store() {
  final store = AppStore();
  store.ready = true;
  store.hasProject = false;
  store.settings = AppSettings(providerId: 'deepseek', modelId: 'deepseek-v4.1-flash');
  return store;
}

Widget _wrap(AppStore store) => ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(
        theme: AppTheme.build(dark: true),
        home: Welcome(onNewProject: () {}, onOpenPath: (_) {}, onSettings: () {}),
      ),
    );

void main() {
  for (final size in const [Size(402, 874), Size(390, 844), Size(375, 667)]) {
    testWidgets('Welcome fits ${size.width.toInt()}x${size.height.toInt()} without overflow',
        (tester) async {
      await tester.binding.setSurfaceSize(size);
      await tester.pumpWidget(_wrap(_store()));
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull);
      expect(find.text('把想法变成\n可以点的产品'), findsOneWidget);
      expect(find.text('开始设计'), findsOneWidget);
      await tester.binding.setSurfaceSize(null);
    });
  }

  testWidgets('Welcome keeps the two-column layout on a wide desktop surface', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    await tester.pumpWidget(_wrap(_store()));
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);
    expect(find.text('最近项目'), findsOneWidget);
    expect(find.text('作品集'), findsOneWidget);
    await tester.binding.setSurfaceSize(null);
  });
}
