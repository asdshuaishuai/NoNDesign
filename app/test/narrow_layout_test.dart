// 窄屏（手机 390×844）顶栏不溢出回归：mobile-3 修了 body 布局后，
// TitleBar 与三个插件顶栏曾分别溢出 64–528px（右侧按钮不可见）。
// 这里直接渲染真实顶栏组件，断言无 RenderFlex overflow 异常。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/widgets/a2ui_workspace.dart';
import 'package:nondesign/widgets/three_workspace.dart';
import 'package:nondesign/widgets/title_bar.dart';
import 'package:nondesign/widgets/video_workspace.dart';

AppStore _store({String projectName = '一个非常长的项目名称用于顶栏窄屏回归测试'}) {
  final store = AppStore();
  store.ready = true;
  store.hasProject = true;
  store.projectName = projectName;
  store.settings = AppSettings(providerId: 'deepseek', modelId: 'deepseek-v4.1-flash');
  return store;
}

Widget _wrap(AppStore store, Widget child) => ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(
        theme: AppTheme.build(dark: true),
        builder: (context, child) => withResponsiveTextScale(context, child ?? const SizedBox.shrink()),
        home: Scaffold(body: child),
      ),
    );

Future<void> _pumpWidth(WidgetTester tester, Widget child, double width) async {
  tester.view.physicalSize = Size(width, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(_wrap(_store(), child));
  await tester.pump(const Duration(milliseconds: 30));
  expect(tester.takeException(), isNull);
}

/// 审计实测 390 与 410 两个宽度都曾溢出，两个都守。
const _narrowWidths = [390.0, 410.0];

void main() {
  Widget titleBar() => SizedBox(
        height: 52,
        child: TitleBar(
          onCommand: () {},
          onSettings: () {},
          onNewProject: () {},
          onOpenProject: () {},
          onShortcuts: () {},
          onOpenRecent: (_) {},
        ),
      );

  testWidgets('TitleBar fits narrow widths with long and short names', (tester) async {
    for (final w in _narrowWidths) {
      await _pumpWidth(tester, titleBar(), w);
      // 短项目名路径曾让命令条自己溢出 221px；titleBar() 复用一个 store，
      // 这里单独再压一次短名。
      await tester.binding.setSurfaceSize(Size(w, 844));
      await tester.pumpWidget(_wrap(_store(projectName: 'demo'), titleBar()));
      await tester.pump(const Duration(milliseconds: 30));
      expect(tester.takeException(), isNull);
    }
  });

  for (final entry in const {
    'A2UI': A2uiWorkspace(),
    '3D': ThreeWorkspace(),
    'Video': VideoWorkspace(),
  }.entries) {
    testWidgets('${entry.key} top bar fits narrow widths', (tester) async {
      for (final w in _narrowWidths) {
        await _pumpWidth(tester, entry.value, w);
      }
    });
  }
}
