// 模拟器/真机 UI 冒烟：移动端主页 → 3D 工作台 → 返回设计。
// 覆盖两个真实回归点：
//  - 无项目时作品集/工作台入口仍能路由（nav-2 修复：主页卡片不再点了没反应）；
//  - 插件全屏视图有可见返回出口且能回到 Welcome（nav-1 修复）。
// 运行：flutter test integration_test/mobile_smoke_test.dart -d <simulator-id>
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';

import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/main.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('mobile: welcome -> 3D workbench -> back', (tester) async {
    final store = AppStore();
    store.ready = true;
    store.hasProject = false;
    store.settings = AppSettings(providerId: 'deepseek', modelId: 'deepseek-v4.1-flash');

    await tester.pumpWidget(
      ChangeNotifierProvider<AppStore>.value(value: store, child: const NonApp()),
    );
    await tester.pump(const Duration(milliseconds: 400));

    // 移动端启动降级后的主页（无服务器、无项目）。
    expect(find.text('把想法变成\n能用的作品'), findsOneWidget);

    // 主页工作台卡 → 插件视图（无项目也必须能路由）。
    await tester.tap(find.text('3D 工作台'));
    await tester.pump(const Duration(milliseconds: 600));
    expect(store.view, 'plugin:three');
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);

    // 可见返回出口 → 回到设计（Welcome）。
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pump(const Duration(milliseconds: 400));
    expect(store.view, 'design');
    expect(find.text('把想法变成\n能用的作品'), findsOneWidget);
  });
}
