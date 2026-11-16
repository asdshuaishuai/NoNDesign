// 3D 工作台 await 弹窗返回后的 mounted 守卫回归（审查 ui-2）。
// 触发链：根级 ⌘1–⌘7 绑定不让位浮层（main.dart 无 _overlayRouteActive 守卫），
// 对话框打开期间切走视图 → workspace.dart 重建并 dispose ThreeWorkspace →
// 弹窗里继续操作即在死 State 上继续执行：
// - _createProject 的 setState 在 try 之外 → 未处理异常（本测试的红/绿锚点）；
// - _pickProject 的 setState 被外层 catch 吞掉 → 项目切换静默失效（语义锚点：
//   死工作台不得推进项目切换/挂预览）。
// 对照同型正确实现：hotapp_workspace.dart 的 `if (!mounted || ...) return;`。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:nondesign/core/api.dart';
import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/widgets/three_workspace.dart';

AppStore _store(NoNDesignApi api) {
  final store = AppStore()
    ..ready = true
    ..view = 'plugin:three'
    ..settings = AppSettings(
      providerId: 'deepseek',
      modelId: 'deepseek-v4.1-flash',
      baseUrl: 'https://api.example.com/v1',
      apiKey: 'test-key',
    );
  store.api = api;
  return store;
}

NoNDesignApi _api() => NoNDesignApi(
      'http://mock.local',
      MockClient((request) async {
        if (request.url.path == '/three/projects') {
          return http.Response(
            '{"ok":true,"projects":[{"name":"saturn-demo","current":"blockout"}]}',
            200,
          );
        }
        return http.Response('{"ok":false,"detail":"no_route"}', 404);
      }),
    );

/// 镜像 workspace.dart 的插件视图路由：watch store → view 变化即重建/dispose。
Widget _host(AppStore store) => ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(
        theme: AppTheme.build(dark: true),
        home: Consumer<AppStore>(
          builder: (context, s, _) => s.view == 'plugin:three'
              ? const Scaffold(body: ThreeWorkspace())
              : const Scaffold(body: SizedBox.expand()),
        ),
      ),
    );

Future<void> _pumpAt(WidgetTester tester, Widget child, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(child);
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  testWidgets('pickProject：弹窗期间切走视图后选项目不复活死 State', (tester) async {
    final store = _store(_api());
    await _pumpAt(tester, _host(store), const Size(1440, 900));

    await tester.tap(find.text('项目'));
    await tester.pumpAndSettle();
    expect(find.text('3D 项目'), findsOneWidget);

    // 对话框在场时切走视图（⌘1 的等价动作）：ThreeWorkspace 被 dispose，
    // 弹窗路由独立存活。
    store.setView('design');
    await tester.pumpAndSettle();
    expect(store.view, 'design');

    // 在仍开着的弹窗里选项目 → await showNonDialog 之后的续体在死 State 上跑。
    // （Navigator.pop 能成功走通依赖 showNonDialog 把路由 context 传给
    // builder——推入方 context 已死时 dialog 动作会先在这里崩。）
    await tester.tap(find.text('saturn-demo（占位）'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.takeException(), isNull);
    // 死工作台不得推进项目切换/写全局设置。
    expect(store.settings.threeProjectName, isEmpty);
  });

  testWidgets('createProject：弹窗期间切走视图后确认新建不触发 setState-after-dispose', (tester) async {
    final store = _store(_api());
    await _pumpAt(tester, _host(store), const Size(1440, 900));

    await tester.tap(find.text('新建 3D 项目'));
    await tester.pumpAndSettle();
    expect(find.text('生成规范'), findsOneWidget);
    await tester.enterText(find.byType(TextField).at(0), 'demo');
    await tester.enterText(find.byType(TextField).at(1), '带环行星自转');

    store.setView('design');
    await tester.pumpAndSettle();

    // 点「生成规范」→ pop(true) → 续体在 try 之外直接 setState(_busy=true)：
    // 无守卫时是未处理异常（debug 抛 FlutterError），守卫后安静返回。
    await tester.tap(find.text('生成规范'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.takeException(), isNull);
    expect(store.settings.threeProjectName, isEmpty);
  });
}
