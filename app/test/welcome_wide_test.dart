// Welcome 宽屏双栏右列溢出回归（审查 ui-1）：右列是裸 Column，内容高随
// recent（≤6）+ 工作区/桌面（≤8）无上限增长——boot() 每次启动都填这两个
// 列表，macOS 默认窗口 1440×920 下装填真实数据实测溢出 450px、1024×768
// （iPad 横屏）溢出 326px。仓库自己的宽屏测试（welcome_mobile_test.dart）
// 用空 store，永远看不到真实内容量。这里按真实容量装填后断言无溢出。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/widgets/welcome.dart';

AppStore _filledStore() {
  final store = AppStore()
    ..ready = true
    ..hasProject = false
    ..settings = AppSettings(providerId: 'deepseek', modelId: 'deepseek-v4.1-flash')
    ..recent = [
      for (var i = 0; i < 6; i++)
        {'path': '/tmp/recent-$i.ddp', 'name': 'recent-project-$i', 'ts': 1760000000000 + i},
    ]
    ..serverProjects = [
      for (var i = 0; i < 8; i++)
        {
          'path': '/tmp/server-$i.ddp',
          'name': 'server-project-$i',
          'bytes': 123456,
          'modified': 1760000000 + i,
          'source': i < 4 ? 'workspace' : 'desktop',
        },
    ];
  return store;
}

Widget _wrap(AppStore store) => ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(
        theme: AppTheme.build(dark: true),
        builder: (context, child) => withResponsiveTextScale(context, child ?? const SizedBox.shrink()),
        home: Welcome(onNewProject: () {}, onOpenPath: (_) {}, onSettings: () {}),
      ),
    );

void main() {
  for (final size in const [Size(1440, 920), Size(1024, 768)]) {
    testWidgets('Welcome wide right column fits real data at ${size.width}x${size.height}',
        (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_wrap(_filledStore()));
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('welcome-wide')), findsOneWidget);
      // 真实容量装填：6 条最近项目 + 8 条工作区/桌面都必须渲染。
      expect(find.text('recent-project-5'), findsOneWidget);
      expect(find.text('server-project-7'), findsOneWidget);
    });
  }
}
