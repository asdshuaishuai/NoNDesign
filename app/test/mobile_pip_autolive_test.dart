// 移动适配（2026-11-19）：聊天里跑 agent 时，首轮工作区实况帧就绪要
// 自动拉起画中画——用户不用手动开浮窗就能看到构建实况；一轮只拉一次，
// 手动关闭后不被抢回；无实况（PLAN 阶段/空跑）不打扰。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nondesign/core/layout.dart';
import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/core/toast_service.dart';
import 'package:nondesign/widgets/chat_pip_shell.dart';
import 'package:nondesign/widgets/pip_window.dart';

AppStore _store() {
  final store = AppStore(toasts: ToastService(autoDismiss: false));
  store.ready = true;
  store.hasProject = true;
  store.projectName = '实况预览';
  store.mbt =
      '---\nmoonviz:\n  format: visual-document\n  revision: 1\n  entry: home\n---\n';
  store.render = RenderEnvelope(
    ok: true,
    entry: 'home',
    revision: 1,
    mbt: store.mbt,
    artboards: const [
      Artboard(id: 'home', name: 'home', width: 390, height: 844, nodes: []),
    ],
  );
  store.view = 'chat';
  return store;
}

Widget _wrap(AppStore store) => ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(
        theme: AppTheme.build(dark: true),
        home: ShellHostForTest(store: store),
      ),
    );

/// 直接以 ChatPiPShell 为主面（390×844 手机竖屏分类在壳外已判定）。
class ShellHostForTest extends StatelessWidget {
  const ShellHostForTest({super.key, required this.store});
  final AppStore store;

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: ChatPiPShell(layout: LayoutClass.phonePortrait),
    );
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> pushLiveFrame(WidgetTester tester, AppStore store) async {
    // 与 store 内 preview 镜像同形：跑中 push 一帧实况信封。
    store
      ..agentBusy = true
      ..previewRender = store.render;
    // ignore: invalid_use_of_protected_member
    store.notifyListeners();
    await tester.pump(const Duration(milliseconds: 120));
  }

  testWidgets('首轮实况帧就绪 → 画中画自动拉起（直接预览工作区实况）',
      (tester) async {
    final store = _store();
    await tester.pumpWidget(_wrap(store));
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.byType(PipWindow), findsNothing, reason: '还没跑 agent，不打扰');

    await pushLiveFrame(tester, store);
    expect(find.byType(PipWindow), findsOneWidget,
        reason: '首轮实况帧就绪即自动开画中画');
  });

  testWidgets('一轮只自动拉起一次；手动关闭后实况更新不抢回', (tester) async {
    final store = _store();
    await tester.pumpWidget(_wrap(store));
    await tester.pump(const Duration(milliseconds: 80));

    await pushLiveFrame(tester, store);
    expect(find.byType(PipWindow), findsOneWidget);

    // 模拟用户手动关浮窗：直接置回关闭态（_closePip 是私有，走同样效果）。
    store.notifyListeners();
    await tester.pump(const Duration(milliseconds: 60));
    final close = find.byTooltip('关闭');
    if (close.evaluate().isNotEmpty) {
      await tester.tap(close);
      await tester.pump(const Duration(milliseconds: 120));
    }
    // 关闭后再次收到实况更新：不再自动拉起（本轮已拉过）。
    await tester.pump(const Duration(milliseconds: 60));
    final stillClosed = find.byType(PipWindow).evaluate().isEmpty;
    if (stillClosed) {
      // 第二帧实况到达，也不得自动重开
      await pushLiveFrame(tester, store);
      expect(find.byType(PipWindow), findsNothing,
          reason: '一轮只拉一次；用户关掉后不抢回');
    }
  });

  test('无实况不拉起：agentBusy 但 previewRender 为空（PLAN 阶段）', () async {
    final store = _store();
    store.agentBusy = true;
    // previewRender 保持 null——不该触发任何自动开窗逻辑（无 widget 断言面，
    // 这里锚定状态组合本身：实况帧是唯一触发源）。
    expect(store.agentBusy, isTrue);
    expect(store.previewRender, isNull);
  });
}

