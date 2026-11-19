// 手机端设置独立布局回归（2026-11-17 重做）：
// - 分组根页（无顶部横向 tab），下钻详情单列卡片；
// - 触控目标 ≥44/48，输入 ≥44，字号与卡片间距按移动端；
// - 手机横屏矮窗同样走移动端布局。
import 'package:material_ui/material_ui.dart';
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
  // 入场是 fade+scale（0.965→1.0，240ms）：单次 pump 落在首个动画帧，
  // 量到的尺寸会整体缩水 3.5%（44→42.46）。再泵一帧等动画收束。
  await tester.pump(const Duration(milliseconds: 300));
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
    expect(find.text('智能体'), findsOneWidget);
    expect(find.text('关于'), findsOneWidget);
    // 移动端触控目标：分组行 ≥64。
    final tile = tester.getRect(find.byKey(const ValueKey('settings-m-models')));
    expect(tile.height, greaterThanOrEqualTo(64));
    // 关闭按钮 44×44（settings-1 的同一触控标准）。
    final close = tester.getRect(find.byKey(const ValueKey('settings-mobile-close')));
    expect(close.width, greaterThanOrEqualTo(44));
    expect(close.height, greaterThanOrEqualTo(44));
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

    // 服务商选择行与模型行都是移动端高度（模型行点按打开底部选择面板）。
    final provider = tester.getRect(find.byKey(const ValueKey('settings-m-provider')));
    expect(provider.height, greaterThanOrEqualTo(48));
    final modelRow = tester.getRect(find.byKey(const ValueKey('settings-m-model-row')));
    expect(modelRow.left, closeTo(endpoint.left, 0.5));
    expect(modelRow.width, closeTo(endpoint.width, 0.5));
    expect(modelRow.height, greaterThanOrEqualTo(48));

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

  testWidgets('phone settings: 系统返回先回分组根页，再按才关设置（settings-2）', (tester) async {
    final store = _store();
    await _open(tester, store, const Size(390, 844));
    await tester.tap(find.byKey(const ValueKey('settings-m-appearance')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('settings-m-detail-appearance')), findsOneWidget);

    // Android 系统返回键（PopScope）：详情页 → 分组根页，弹窗仍在。
    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 220));
    expect(find.byKey(const ValueKey('settings-mobile-root')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-m-detail-appearance')), findsNothing);

    // 根页再按一次才关闭整个设置。
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings-mobile-root')), findsNothing);
    expect(find.byKey(const ValueKey('settings-mobile-close')), findsNothing,
        reason: '设置弹窗已被第二次 back 关掉');
    expect(find.text('open'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone settings: 思考等级 chip ≥44 触控目标（settings-3）', (tester) async {
    final store = _store();
    // 思考等级卡只在有当前模型时出现：给注册表播种一个同 id 的模型。
    store.registry = ModelRegistry.fromJson({
      'providers': {
        'deepseek': {
          'api': 'https://api.deepseek.com',
          'protocol': 'openai',
          'models': {
            'deepseek-v4.1-flash': {
              'name': 'DeepSeek V4.1 Flash',
              'tool_call': true,
              'limit': {'context': 128000},
            },
          },
        },
      },
    });
    await _open(tester, store, const Size(390, 844));
    await tester.tap(find.byKey(const ValueKey('settings-m-models')));
    await tester.pump(const Duration(milliseconds: 300));

    // 详情页底部的思考等级 chips：滚到可见再量高度（此前 34）。
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('settings-m-thinking-auto')),
      260,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('settings-m-detail-models')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pump(const Duration(milliseconds: 120));
    final chip = tester.getRect(find.byKey(const ValueKey('settings-m-thinking-auto')));
    expect(chip.height, greaterThanOrEqualTo(44), reason: '移动端最小触控目标 44');
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
