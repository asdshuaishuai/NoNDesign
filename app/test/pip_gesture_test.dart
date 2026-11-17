// 画中画工作区 S4（docs/plan-chat-stream-shell.md §2/§5）的手势优先级回归：
// - 窗容器先于内容（plan §6.4）：头部拖动 / 手柄缩放进行中，child 上盖
//   opaque 吸收层，画布/内容收不到指针；松手即撤除（漏撤 = 画布永久不可
//   交互，这是本文件的硬门）；
// - Workspace(embedded: true) 不渲染 TitleBar/StatusBar，默认构造函数仍
//   渲染（嵌入式只收紧壳，不改默认行为）。
//
// 两路指针用 tester.startGesture 显式构造（tester.drag 表达不了「拖动中
// 第二根手指点内容」的并发场景）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/widgets/left_panel.dart';
import 'package:nondesign/widgets/pip_window.dart';
import 'package:nondesign/widgets/rail.dart';
import 'package:nondesign/widgets/right_panel.dart';
import 'package:nondesign/widgets/status_bar.dart';
import 'package:nondesign/widgets/title_bar.dart';
import 'package:nondesign/widgets/workspace.dart';

AppStore _store({bool project = true, String view = 'design'}) {
  final store = AppStore();
  store.ready = true;
  store.settings = AppSettings(providerId: 'deepseek', modelId: 'deepseek-v4.1-flash');
  store.hasProject = project;
  store.projectName = '演示项目';
  store.view = view;
  if (project) {
    store.mbt = '---\nmoonviz:\n  format: visual-document\n  revision: 1\n  entry: home\n---\n';
    store.render = RenderEnvelope(
      ok: true,
      entry: 'home',
      revision: 1,
      mbt: store.mbt,
      artboards: const [
        Artboard(id: 'home', name: 'home', width: 390, height: 844, nodes: []),
      ],
    );
  }
  return store;
}

Widget _app(Widget child) => MaterialApp(
      theme: AppTheme.build(dark: true),
      home: child,
    );

void main() {
  /// 浮窗探针宿主：rect 受控、探针记录点按次数，供「拖动中不可点」断言。
  Future<(Rect Function(), int Function())> pumpPip(
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(800, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var rect = const Rect.fromLTWH(20, 20, 480, 420);
    var probeTaps = 0;
    await tester.pumpWidget(_app(
      Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => Stack(
            children: [
              Positioned.fromRect(
                rect: rect,
                child: PipWindow(
                  key: const ValueKey('pip'),
                  title: '工作区',
                  rect: rect,
                  onRect: (r) => setState(() => rect = r),
                  onClose: () {},
                  onToggleMax: () {},
                  child: Center(
                    child: InkWell(
                      key: const ValueKey('pip-probe'),
                      onTap: () => probeTaps++,
                      child: Container(
                        width: 120,
                        height: 60,
                        alignment: Alignment.center,
                        color: Colors.transparent,
                        child: const Text('探针'),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 50));
    return (() => rect, () => probeTaps);
  }

  testWidgets('头部拖动进行中 child 不可点；松手后恢复', (tester) async {
    final (rectOf, tapsOf) = await pumpPip(tester);

    final g1 = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('pip-header'))),
    );
    await g1.moveBy(const Offset(-36, -24));
    await tester.pump();
    expect(find.byKey(const ValueKey('pip-absorb')), findsOneWidget,
        reason: '拖动中窗口容器盖吸收层（手势优先给窗）');
    expect(rectOf().left, lessThan(20), reason: '拖动真实生效');

    // 第二根手指点 child 里的探针：被吸收层挡下。
    final g2 = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('pip-probe'))),
    );
    await tester.pump(const Duration(milliseconds: 30));
    await g2.up();
    await tester.pump(const Duration(milliseconds: 30));
    expect(tapsOf(), 0, reason: '拖动中 child 的 onTap 不得触发');

    await g1.up();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const ValueKey('pip-absorb')), findsNothing,
        reason: '松手即撤除吸收层');

    await tester.tap(find.byKey(const ValueKey('pip-probe')));
    await tester.pump();
    expect(tapsOf(), 1, reason: '吸收层不得泄漏到 onPanEnd 之后');
    expect(tester.takeException(), isNull);
  });

  testWidgets('缩放手柄拖动进行中 child 不可点；松手后恢复', (tester) async {
    final (rectOf, tapsOf) = await pumpPip(tester);
    final before = rectOf();

    final g1 = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('pip-resize'))),
    );
    await g1.moveBy(const Offset(30, 24));
    await tester.pump();
    expect(find.byKey(const ValueKey('pip-absorb')), findsOneWidget);
    expect(rectOf().width, greaterThan(before.width), reason: '缩放真实生效');

    final g2 = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('pip-probe'))),
    );
    await tester.pump(const Duration(milliseconds: 30));
    await g2.up();
    await tester.pump(const Duration(milliseconds: 30));
    expect(tapsOf(), 0, reason: '缩放中 child 的 onTap 不得触发');

    await g1.up();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const ValueKey('pip-absorb')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('pip-probe')));
    await tester.pump();
    expect(tapsOf(), 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Workspace(embedded: true) 去掉 TitleBar/StatusBar，默认仍渲染', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final store = _store();
    await tester.pumpWidget(ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: _app(const Workspace(embedded: true)),
    ));
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.byType(TitleBar), findsNothing);
    expect(find.byType(StatusBar), findsNothing);
    // 嵌入壳保留窄轨/面板/画布，但窄轨换成只做面板局部导航的嵌入式版本
    // （全局 Rail 的「文档/规范」会把聊天宿主整块换掉，review pip-1）。
    expect(find.byKey(const ValueKey('workspace-embedded-rail')), findsOneWidget);
    expect(find.byType(Rail), findsNothing, reason: '嵌入壳不得挂全局 Rail');
    expect(find.byType(LeftPanel), findsOneWidget);
    expect(find.byType(RightPanel), findsOneWidget, reason: '1200 ≥ 1100 三栏全开');
    expect(tester.takeException(), isNull);

    // 默认构造函数（全屏壳）行为不变：全局 Rail 回来。
    await tester.pumpWidget(ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: _app(const Workspace()),
    ));
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.byType(TitleBar), findsOneWidget);
    expect(find.byType(StatusBar), findsOneWidget);
    expect(find.byType(Rail), findsOneWidget);
    expect(find.byKey(const ValueKey('workspace-embedded-rail')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
