// 模拟器/真机 UI 冒烟：手机聊天主面 → 经典主页 → 3D 工作台 → 返回主页。
//
// 批次 12 后的手机裁决：默认主面是**聊天全屏 + 工作区画中画**（ChatPiPShell）；
// 经典 Welcome 仍可通过「启动主面 = 欢迎页」偏好进入（这里直接翻转偏好模拟
// 用户选择），并且无项目时作品集/工作台入口必须仍能路由、全屏插件视图必须
// 有可见返回出口。
//
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

  testWidgets('mobile: chat home -> welcome -> 3D workbench -> back', (tester) async {
    final store = AppStore();
    store.ready = true;
    store.hasProject = false;
    store.settings = AppSettings(providerId: 'deepseek', modelId: 'deepseek-v4.1-flash');

    await tester.pumpWidget(
      ChangeNotifierProvider<AppStore>.value(value: store, child: const NonApp()),
    );
    await tester.pump(const Duration(milliseconds: 400));

    // 手机默认主面：聊天全屏 + 右缘工作区胶囊（工作区是画中画，不常驻）。
    expect(find.byKey(const ValueKey('chat-input')), findsOneWidget);
    expect(find.byKey(const ValueKey('pip-edge-capsule')), findsOneWidget);

    // 经典主页偏好：主面切回 Welcome（聊天入口保留为右下角胶囊）。
    store.settings.chatStreamHome = false;
    store.notifyListeners();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('把想法变成\n能用的作品'), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-first-fab')), findsOneWidget);

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
