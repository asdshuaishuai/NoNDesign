// 设计 → 热应用（唯一允许的模块间关联）：
//  - 生成入口**只保留一个**，放在热应用工作台顶栏（「由原型生成」），带进度与
//    结果反馈；设计画布工具条上不再叠两个看起来一样、点了没动静的图标。
//  - 未配模型 / 没有原型时诚实早退：不崩溃、不换视图。
import 'package:material_ui/material_ui.dart' hide Flow;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/platform_capabilities.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/core/toast_service.dart';
import 'package:nondesign/widgets/shell_host.dart';

AppStore _storeWithPrototype({String view = 'plugin:hotapp'}) {
  final store = AppStore(toasts: ToastService(autoDismiss: false));
  store.ready = true;
  store.settings = AppSettings(providerId: 'deepseek', modelId: 'deepseek-v4.1-flash');
  store.hasProject = true;
  store.projectName = '演示项目';
  store.view = view;
  store.mbt = '---\nmoonviz:\n  format: visual-document\n  revision: 1\n  entry: home\n---\n';
  store.render = RenderEnvelope(
    ok: true,
    entry: 'home',
    revision: 1,
    mbt: store.mbt,
    artboards: const [
      Artboard(id: 'home', name: 'home', width: 390, height: 844, nodes: []),
    ],
    flows: const [Flow(from: 'home', to: 'settings', trigger: 'tap:to-settings')],
  );
  return store;
}

Widget _wrap(AppStore store) => ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(
        theme: AppTheme.build(dark: true),
        builder: (context, child) =>
            withResponsiveTextScale(context, child ?? const SizedBox.shrink()),
        home: ShellHost(capabilities: PlatformCapabilities.forOs(HostOs.macos)),
      ),
    );

Future<void> _pump(WidgetTester tester, AppStore store) async {
  tester.view.physicalSize = const Size(1440, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  await tester.pumpWidget(_wrap(store));
  await tester.pump(const Duration(milliseconds: 60));
  await tester.pump(const Duration(milliseconds: 60));
}

void main() {
  testWidgets('设计工具条不再重复挂「生成热应用」图标（入口只有一个）', (tester) async {
    final store = _storeWithPrototype(view: 'design');
    await _pump(tester, store);
    expect(find.byKey(const ValueKey('design-to-hotapp')), findsNothing,
        reason: '生成入口已收进热应用工作台顶栏，设计工具条不再重复');
    expect(find.byKey(const ValueKey('hotapp-from-prototype')), findsNothing,
        reason: '设计视图里不应出现热应用工作台的动作');
  });

  testWidgets('热应用工作台有唯一的「由原型生成」入口', (tester) async {
    final store = _storeWithPrototype();
    await _pump(tester, store);
    expect(find.byKey(const ValueKey('hotapp-from-prototype')), findsOneWidget,
        reason: '设计 → 热应用是唯一允许的模块间关联，入口必须在热应用工作台');
    expect(find.text('由原型生成'), findsOneWidget);
  });

  testWidgets('点击入口：未配模型时诚实早退，不崩溃、不换视图', (tester) async {
    final store = _storeWithPrototype();
    await _pump(tester, store);
    await tester.tap(find.byKey(const ValueKey('hotapp-from-prototype')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(store.view, 'plugin:hotapp', reason: '早退不换视图');
    expect(tester.takeException(), isNull);
  });
}
