// 移动适配（2026-11-19）：chat agent 跑起来时，实况预览直接长在**聊天流的
// 框里**（genUI 形态的内嵌工作区卡）——不是画中画浮窗；桌面窄栏不受影响。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/core/toast_service.dart';
import 'package:nondesign/widgets/chat_live_preview.dart';
import 'package:nondesign/widgets/chat_stream.dart';
import 'package:nondesign/widgets/workspace.dart';

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

Widget _wrap(AppStore store, {bool railMode = false}) =>
    ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(
        theme: AppTheme.build(dark: true),
        home: ChatStreamView(railMode: railMode),
      ),
    );

Future<void> _pump(WidgetTester tester, AppStore store,
    {bool railMode = false}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(_wrap(store, railMode: railMode));
  await tester.pump(const Duration(milliseconds: 80));
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('跑起来且有实况帧 → 聊天流里出现内嵌实况预览卡（内嵌工作区）',
      (tester) async {
    final store = _store();
    await _pump(tester, store);
    expect(find.byType(ChatLivePreviewCard), findsNothing,
        reason: '没跑 agent 时不出现');

    // 跑起来 + 首轮实况帧（与 store 内 preview 镜像同形）。
    store
      ..agentBusy = true
      ..previewRender = store.render;
    // ignore: invalid_use_of_protected_member
    store.notifyListeners();
    await tester.pump(const Duration(milliseconds: 120));

    expect(find.byType(ChatLivePreviewCard), findsOneWidget);
    expect(find.byType(Workspace), findsOneWidget,
        reason: '卡内内嵌的是桌面同一个 Workspace（底层完全一致）');
    expect(find.text('实况预览 · 正在构建工作区'), findsOneWidget);
  });

  testWidgets('折叠开关：收起后只剩标题行，再点展开', (tester) async {
    final store = _store();
    await _pump(tester, store);
    store
      ..agentBusy = true
      ..previewRender = store.render;
    // ignore: invalid_use_of_protected_member
    store.notifyListeners();
    await tester.pump(const Duration(milliseconds: 120));

    expect(find.byType(Workspace), findsOneWidget, reason: '默认展开');
    await tester.tap(find.text('实况预览 · 正在构建工作区'));
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.byType(Workspace), findsNothing, reason: '收起后只剩标题行');
    expect(find.text('实况预览 · 正在构建工作区'), findsOneWidget);

    await tester.tap(find.text('实况预览 · 正在构建工作区'));
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.byType(Workspace), findsOneWidget, reason: '再点展开');
  });

  testWidgets('运行结束 → 实况卡自动消失（终稿回落画布与产物卡）', (tester) async {
    final store = _store();
    await _pump(tester, store);
    store
      ..agentBusy = true
      ..previewRender = store.render;
    // ignore: invalid_use_of_protected_member
    store.notifyListeners();
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.byType(ChatLivePreviewCard), findsOneWidget);

    store
      ..agentBusy = false
      ..previewRender = null;
    // ignore: invalid_use_of_protected_member
    store.notifyListeners();
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.byType(ChatLivePreviewCard), findsNothing);
  });

  testWidgets('桌面窄栏（railMode）不出现实况卡——桌面主面本身就是实况',
      (tester) async {
    final store = _store();
    await _pump(tester, store, railMode: true);
    store
      ..agentBusy = true
      ..previewRender = store.render;
    // ignore: invalid_use_of_protected_member
    store.notifyListeners();
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.byType(ChatLivePreviewCard), findsNothing,
        reason: '实况卡只挂在聊天主面，不影响桌面');
  });
}
