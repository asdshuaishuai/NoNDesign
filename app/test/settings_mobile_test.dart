// 手机端设置独立布局回归（2026-11-17 重做）：
// - 分组根页（无顶部横向 tab），下钻详情单列卡片；
// - 触控目标 ≥44/48，输入 ≥44，字号与卡片间距按移动端；
// - 手机横屏矮窗同样走移动端布局。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/widgets/settings_dialog.dart';

AppStore _store() {
  final store = AppStore();
  store.ready = true;
  store.hasProject = false;
  store.settings = AppSettings(providerId: 'deepseek', modelId: 'deepseek-v4.1-flash');
  return store;
}

Widget _wrap(AppStore store, Widget child) => ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(
        theme: AppTheme.build(dark: true).copyWith(platform: TargetPlatform.iOS),
        builder: (context, child) =>
            withResponsiveTextScale(context, child ?? const SizedBox.shrink()),
        home: child,
      ),
    );

Future<void> _open(WidgetTester tester, AppStore store, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(_wrap(
    store,
    Builder(builder: (context) {
      return Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () => showSettingsDialog(context),
            child: const Text('open'),
          ),
        ),
      );
    }),
  ));
  await tester.tap(find.text('open'));
  await tester.pump(const Duration(milliseconds: 320));
}

void main() {
  testWidgets('phone settings: 分组根页，无顶部 tab', (tester) async {
    final store = _store();
    await _open(tester, store, const Size(390, 844));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('settings-mobile-root')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-topnav')), findsNothing);
    expect(find.byKey(const ValueKey('settings-rail')), findsNothing);
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('模型与端点'), findsOneWidget);
    expect(find.text('外观与交互'), findsOneWidget);
    expect(find.text('上下文与缓存'), findsOneWidget);
    expect(find.text('关于'), findsOneWidget);
    // 移动端触控目标：分组行 ≥64。
    final tile = tester.getRect(find.byKey(const ValueKey('settings-m-models')));
    expect(tile.height, greaterThanOrEqualTo(64));
  });

  testWidgets('phone settings: 下钻单列 + 输入/触控尺寸 + 返回', (tester) async {
    final store = _store();
    await _open(tester, store, const Size(390, 844));
    await tester.tap(find.byKey(const ValueKey('settings-m-models')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('settings-m-detail-models')), findsOneWidget);
    expect(find.text('模型与端点'), findsOneWidget);

    // 单列：端点与 API Key 输入同左缘、同宽（不是桌面端的两列并排）。
    final endpoint = tester.getRect(find.byKey(const ValueKey('settings-m-endpoint')));
    final apiKey = tester.getRect(find.byKey(const ValueKey('settings-m-apikey')));
    expect(endpoint.left, closeTo(apiKey.left, 0.5));
    expect(endpoint.width, closeTo(apiKey.width, 0.5));
    expect(endpoint.height, greaterThanOrEqualTo(44));
    expect(apiKey.height, greaterThanOrEqualTo(44));

    // 服务商选择行与「桌面服务器」输入都是移动端高度。
    final provider = tester.getRect(find.byKey(const ValueKey('settings-m-provider')));
    expect(provider.height, greaterThanOrEqualTo(48));
    final server = tester.getRect(find.byKey(const ValueKey('settings-m-server')));
    expect(server.left, closeTo(endpoint.left, 0.5));
    expect(server.width, closeTo(endpoint.width, 0.5));

    await tester.tap(find.byKey(const ValueKey('settings-mobile-back')));
    await tester.pump(const Duration(milliseconds: 220));
    expect(find.byKey(const ValueKey('settings-mobile-root')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-m-detail-models')), findsNothing);
  });

  testWidgets('phone settings: 外观切换即时生效', (tester) async {
    final store = _store();
    await _open(tester, store, const Size(390, 844));
    await tester.tap(find.byKey(const ValueKey('settings-m-appearance')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('settings-m-detail-appearance')), findsOneWidget);
    await tester.tap(find.text('浅色'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(store.settings.theme, 'light');
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone landscape uses mobile layout', (tester) async {
    final store = _store();
    await _open(tester, store, const Size(844, 390));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('settings-mobile-root')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-topnav')), findsNothing);
  });
}
