// Welcome 宽屏双栏右列溢出回归（审查 ui-1）：右列是裸 Column，内容高随
// recent（≤6）+ 工作区/桌面（≤8）无上限增长——boot() 每次启动都填这两个
// 列表，macOS 默认窗口 1440×920 下装填真实数据实测溢出 450px、1024×768
// （iPad 横屏）溢出 326px。仓库自己的宽屏测试（welcome_mobile_test.dart）
// 用空 store，永远看不到真实内容量。这里按真实容量装填后断言无溢出。
//
// 批次 12 追加：桌面 / iPad 横版「无项目主面 = 经典 Welcome」的壳层回归，
// 以及手机 / iPad 竖屏保持聊天主面（Welcome 不得出现在主面）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/platform_capabilities.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/widgets/chat_pip_shell.dart';
import 'package:nondesign/widgets/desktop_shell.dart';
import 'package:nondesign/widgets/shell_host.dart';
import 'package:nondesign/widgets/welcome.dart';
import 'package:nondesign/widgets/workspace.dart';

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

  // 矮窗口（手机横屏 / 小窗）仍走宽屏双栏：左列必须可滚动，不能把
  // 「开始创作」丢到屏幕外（审查 layout-4：844×390 实测溢出 147px）。
  for (final size in const [
    Size(844, 390),
    Size(932, 430),
    Size(900, 500),
    Size(1024, 420),
  ]) {
    testWidgets(
        'Welcome wide left column scrolls at ${size.width.toInt()}x${size.height.toInt()}',
        (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_wrap(_filledStore()));
      await tester.pump(const Duration(milliseconds: 50));

      expect(tester.takeException(), isNull, reason: '矮窗口下左列不得纵向溢出');
      expect(find.byKey(const ValueKey('welcome-wide')), findsOneWidget);

      // 输入卡与「开始创作」必须能滚进视口（而不是落在屏幕外）。
      await tester.ensureVisible(find.text('开始创作'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      final rect = tester.getRect(find.text('开始创作'));
      expect(rect.bottom, lessThanOrEqualTo(size.height));
      expect(rect.top, greaterThanOrEqualTo(0));
    });
  }

  // ---- 批次 12：壳层里的 Welcome 主面 -------------------------------------

  Widget shellWrap(AppStore store, HostOs os) => ChangeNotifierProvider<AppStore>.value(
        value: store,
        child: MaterialApp(
          theme: AppTheme.build(dark: true),
          builder: (context, child) =>
              withResponsiveTextScale(context, child ?? const SizedBox.shrink()),
          home: ShellHost(capabilities: PlatformCapabilities.forOs(os)),
        ),
      );

  Future<void> pumpShell(
    WidgetTester tester,
    AppStore store,
    Size size, {
    HostOs os = HostOs.macos,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(shellWrap(store, os));
    await tester.pump(const Duration(milliseconds: 80));
  }

  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final entry in const [
    (Size(1440, 900), HostOs.macos),
    (Size(1194, 834), HostOs.ios),
    (Size(1024, 768), HostOs.ios),
  ]) {
    testWidgets('${entry.$1.width.toInt()}×${entry.$1.height.toInt()}：无项目主面是经典 Welcome',
        (tester) async {
      await pumpShell(tester, _filledStore(), entry.$1, os: entry.$2);
      expect(find.byType(DesktopShell), findsOneWidget);
      expect(find.byType(Welcome), findsOneWidget);
      expect(find.byKey(const ValueKey('welcome-wide')), findsOneWidget);
      // 四个招牌区块：最近项目 / 一句话起步 / 工作台 / 作品集。
      expect(find.text('最近项目'), findsOneWidget);
      expect(find.byKey(const ValueKey('welcome-brief')), findsOneWidget);
      expect(find.text('作品集'), findsOneWidget);
      expect(find.text('recent-project-5'), findsOneWidget);
      expect(find.byType(Workspace), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final size in const [Size(768, 1024), Size(834, 1194), Size(390, 844), Size(844, 390)]) {
    testWidgets('${size.width.toInt()}×${size.height.toInt()}：手机/iPad 竖屏保持聊天主面',
        (tester) async {
      await pumpShell(tester, _filledStore(), size, os: HostOs.ios);
      expect(find.byType(ChatPiPShell), findsOneWidget);
      expect(find.byType(Welcome), findsNothing,
          reason: '聊天优先壳的主面是聊天，不是 Welcome');
      expect(find.byKey(const ValueKey('chat-input')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('1024 桌面主页：不挂右栏、不挂折叠条、不显示聊天入口', (tester) async {
    await pumpShell(tester, _filledStore(), const Size(1024, 768), os: HostOs.ios);
    expect(find.byType(Welcome), findsOneWidget);
    expect(find.byKey(const ValueKey('desktop-chat-rail')), findsNothing,
        reason: '主页默认不显示右侧栏');
    expect(find.byKey(const ValueKey('desktop-chat-rail-strip')), findsNothing,
        reason: '折叠覆盖条也不应出现在主页');
    expect(find.byKey(const ValueKey('welcome-open-chat')), findsNothing,
        reason: '右栏不存在时聊天入口隐藏，避免死按钮');
    expect(find.byKey(const ValueKey('welcome-brief')), findsOneWidget,
        reason: '主页仍用一句话起步输入框');
    expect(tester.takeException(), isNull);
  });
}
