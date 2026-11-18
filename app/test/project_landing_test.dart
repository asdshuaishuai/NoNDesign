// 项目落地回归（用户裁决 2026-11-19）：
//
// 「已经带了一个项目，就应该直接进入它所属的工作区、展示内容，而不是停在
// 选择界面」——模块选择入口（旧 hub）已删除。项目（DDP）的内容就是文档 +
// 画板，属于设计工作区，所以打开/新建后一律落 `design`；3D / 视频 / 热应用
// 是独立工作区，各有自己的入口，不参与项目落地。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/platform_capabilities.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/core/toast_service.dart';
import 'package:nondesign/widgets/shell_host.dart';
import 'package:nondesign/widgets/workspace.dart';

AppStore _store() {
  final store = AppStore(toasts: ToastService(autoDismiss: false));
  store.ready = true;
  store.settings = AppSettings(providerId: 'deepseek', modelId: 'deepseek-v4.1-flash');
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
  await tester.pumpWidget(_wrap(store));
  await tester.pump(const Duration(milliseconds: 60));
}

/// 模块选择界面（旧 hub）不允许再出现——它的任何一处痕迹都是回归。
void _expectNoModuleChooser() {
  expect(find.text('选择一个模块开始；右侧 NaN 可以替你操作任何一个模块。'), findsNothing,
      reason: '选择界面不该存在：项目落地必须直接展示内容');
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('桌面：新建项目直接进设计工作区（不是选择界面）', (tester) async {
    final store = _store();
    await _pump(tester, store);

    final ok = await store.newProject(empty: true);
    expect(ok, isTrue);
    await tester.pump(const Duration(milliseconds: 120));

    expect(store.view, 'design', reason: '项目落地 = 项目内容所在的工作区');
    _expectNoModuleChooser();
    // 设计工作区必须在场：画布区/画板条属于 Workspace 主面。
    expect(find.byType(Workspace), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('桌面：打开已有项目同样直接进设计工作区', (tester) async {
    final store = _store();
    await _pump(tester, store);
    // 打开失败也不许落到选择界面：视图必须在设计工作区。
    await store.openProjectPath('/tmp/does-not-exist-${DateTime.now().microsecondsSinceEpoch}.ddp');
    await tester.pump(const Duration(milliseconds: 120));
    expect(store.view, 'design');
    _expectNoModuleChooser();
  });

  testWidgets('设计工作区里项目名可见（内容面而不是入口面）', (tester) async {
    final store = _store();
    await _pump(tester, store);
    await store.newProject(name: '番茄钟', empty: true);
    await tester.pump(const Duration(milliseconds: 120));
    expect(store.view, 'design');
    expect(store.projectName, '番茄钟');
  });

  test('移动端落地同样是设计工作面', () {
    final store = _store();
    store.newProject(empty: true);
    expect(store.view, 'design');
  });
}
