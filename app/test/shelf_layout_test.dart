// 艺术架（Art Shelf）布局与数据面回归（2026-11-17 S2）：
// ① 五个固定分类签（全部/热应用/原型/视频/3D）恒在场——旧实现按当前条目
//    动态拼 chip，空分类在架子上不可见；手机 390/402 宽下五个签与标题同排
//    必溢出，故分类签独立一行横向滚动（本文件的溢出断言就是那条约束的锚）。
// ② 分类签筛选生效（只留该分类的货架行）。
// ③ 加载失败显式呈现（错误条 + 重试）——旧实现的空 catch 把「加载失败」
//    伪装成「还没有作品」。
// ④ api==null 时原型段仍展示，且「未连接服务器」与「没有作品」是两种文案。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nondesign/core/api.dart';
import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/widgets/art_shelf_card.dart';
import 'package:nondesign/widgets/portfolio_view.dart';

http.Response _json(Object body, [int status = 200]) => http.Response(
      body is String ? body : jsonEncode(body),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

AppStore _store({NoNDesignApi? api, List<Map<String, dynamic>>? recent}) {
  final store = AppStore();
  store.ready = true;
  store.settings = AppSettings(providerId: 'deepseek', modelId: 'deepseek-v4.1-flash');
  store.api = api;
  if (recent != null) store.recent = recent;
  return store;
}

/// /portfolio 假服务器（health / project/list 走最小成功信封，refreshProjects
/// 不会覆盖测试自己播种的 serverProjects）。
NoNDesignApi _api({
  List<Map<String, dynamic>> items = const [],
  bool failPortfolio = false,
}) =>
    NoNDesignApi('http://mock.local', MockClient((request) async {
      switch (request.url.path) {
        case '/health':
          return _json({'ok': true});
        case '/project/list':
          return _json({'ok': true, 'projects': []});
        case '/portfolio':
          if (failPortfolio) return _json({'detail': 'portfolio_index_corrupt'}, 500);
          return _json({'ok': true, 'items': items});
      }
      return _json({'ok': false, 'detail': 'no_route'}, 404);
    }));

Future<void> _pumpAt(WidgetTester tester, Widget child, double width, {required AppStore store}) async {
  tester.view.physicalSize = Size(width, 874);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(ChangeNotifierProvider<AppStore>.value(
    value: store,
    child: MaterialApp(
      theme: AppTheme.build(dark: true).copyWith(platform: TargetPlatform.iOS),
      builder: (context, child) => withResponsiveTextScale(context, child ?? const SizedBox.shrink()),
      home: Scaffold(body: child),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 150));
  expect(tester.takeException(), isNull);
}

Finder _chip(String label) =>
    find.descendant(of: find.byType(SingleChildScrollView), matching: find.text(label));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final width in const [402.0, 390.0]) {
    testWidgets('五个固定分类签在 ${width.toInt()}px 下恒在场且不溢出', (tester) async {
      await _pumpAt(tester, const PortfolioView(), width, store: _store());
      // 「作品集」标题仍是独立一处 Text（mobile_surfaces_test 的锚）。
      expect(find.text('作品集'), findsOneWidget);
      for (final label in const ['全部', '热应用', '原型', '视频', '3D']) {
        expect(_chip(label), findsOneWidget, reason: '分类签 $label 必须固定存在');
      }
    });
  }

  testWidgets('分类签筛选只留对应货架行', (tester) async {
    final items = [
      {'kind': 'hotapp', 'ref': 'app-a', 'title': '热应用甲', 'path': '/tmp/hotapps/app-a/index.html', 'detail': '热应用'},
      {'kind': 'video', 'ref': '/v/job-1/frames.mp4', 'title': '视频乙', 'path': '/v/job-1/frames.mp4', 'detail': '视频渲染产物'},
      {'kind': 'three', 'ref': 'scene-c', 'title': '3D 丙', 'path': '/tmp/3d/scene-c/scene.js', 'detail': 'three.js 场景'},
    ];
    await _pumpAt(tester, const PortfolioView(), 402, store: _store(api: _api(items: items)));

    expect(find.text('热应用甲'), findsOneWidget);
    expect(find.text('视频乙'), findsOneWidget);
    expect(find.text('3D 丙'), findsOneWidget);

    await tester.tap(_chip('视频'));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('视频乙'), findsOneWidget);
    expect(find.text('热应用甲'), findsNothing);
    expect(find.text('3D 丙'), findsNothing);
  });

  testWidgets('作品集加载失败：错误条 + 重试可恢复', (tester) async {
    var fail = true;
    final api = NoNDesignApi('http://mock.local', MockClient((request) async {
      switch (request.url.path) {
        case '/health':
          return _json({'ok': true});
        case '/project/list':
          return _json({'ok': true, 'projects': []});
        case '/portfolio':
          if (fail) return _json({'detail': 'portfolio_index_corrupt'}, 500);
          return _json({
            'ok': true,
            'items': [
              {'kind': 'hotapp', 'ref': 'app-a', 'title': '热应用甲', 'path': '/tmp/hotapps/app-a/index.html', 'detail': '热应用'},
            ],
          });
      }
      return _json({'ok': false, 'detail': 'no_route'}, 404);
    }));
    await _pumpAt(tester, const PortfolioView(), 402, store: _store(api: api));

    expect(find.byKey(const ValueKey('shelf-error')), findsOneWidget);
    expect(find.textContaining('portfolio_index_corrupt'), findsOneWidget);

    fail = false;
    await tester.tap(find.text('重试'));
    await tester.pump(const Duration(milliseconds: 120));

    expect(find.byKey(const ValueKey('shelf-error')), findsNothing);
    expect(find.text('热应用甲'), findsOneWidget);
  });

  testWidgets('未连接服务器：原型段仍展示，离线提示条与「没作品」区分', (tester) async {
    final store = _store()
      ..serverProjects = [
        {'path': '/tmp/proto-a.ddp', 'name': 'proto-a', 'bytes': 1, 'modified': 1},
      ];
    await _pumpAt(tester, const PortfolioView(), 402, store: store);

    // 原型项目来自 store.serverProjects（客户端聚合，不需要服务器 portfolio）。
    expect(find.byType(ArtShelfCard), findsOneWidget);
    expect(find.text('proto-a'), findsOneWidget);
    // 离线是显式状态，不是空态。
    expect(find.byKey(const ValueKey('shelf-offline')), findsOneWidget);
    expect(find.textContaining('未连接服务器'), findsWidgets);
    expect(find.text('还没有作品'), findsNothing);

    // shelf-2：提示条文案与 _open / store.openProjectPath 的门一致——原型
    // 同样需要桌面服务（api==null 时 openProjectPath 直接 failed），不再
    // 承诺「原型项目仍可打开」。
    expect(find.text('未连接服务器：热应用 / 视频 / 3D / 原型都需要桌面服务，连接后可打开。'), findsOneWidget);
    expect(find.textContaining('原型项目仍可打开'), findsNothing);

    // 行为锚：离线点原型 → 明确提示需要桌面服务，不切视图（文案=行为）。
    final viewBefore = store.view;
    final card = find.ancestor(of: find.text('proto-a'), matching: find.byType(ArtShelfCard));
    await tester.tap(find.descendant(of: card, matching: find.text('打开')));
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.text('打开 DDP 项目需要桌面服务。'), findsOneWidget);
    expect(store.view, viewBefore, reason: '离线打开失败不得切视图');
    expect(store.hasProject, isFalse);
    await tester.pumpAndSettle(); // 收掉 toast 的展示定时器
  });

  testWidgets('未连接且无产物：空态文案是「未连接服务器」而不是「还没有作品」', (tester) async {
    await _pumpAt(tester, const PortfolioView(), 402, store: _store());
    expect(find.text('未连接服务器'), findsOneWidget);
    expect(find.text('还没有作品'), findsNothing);
  });

  testWidgets('原型卡片不提供「从艺术架移除」（服务端 kind 白名单无 prototype）', (tester) async {
    final store = _store(api: _api(items: [
      {'kind': 'hotapp', 'ref': 'app-a', 'title': '热应用甲', 'path': '/tmp/hotapps/app-a/index.html', 'detail': '热应用'},
    ]))
      ..recent = [
        {'path': '/tmp/proto-a.ddp', 'name': 'proto-a', 'ts': 1},
      ];
    await _pumpAt(tester, const PortfolioView(), 1440, store: store);

    Future<void> openMenuOf(String title) async {
      final card = find.ancestor(of: find.text(title), matching: find.byType(ArtShelfCard));
      await tester.tap(find.descendant(of: card, matching: find.byTooltip('更多操作')));
      await tester.pumpAndSettle();
    }

    // 原型项目不在服务端作品集里：显示「移除」就是一条点必 400 的死路。
    await openMenuOf('proto-a');
    expect(find.text('复制路径'), findsOneWidget);
    expect(find.text('从艺术架移除'), findsNothing);

    await tester.tapAt(const Offset(10, 860)); // 点屏障外关菜单
    await tester.pumpAndSettle();

    // 服务端条目照常提供移除动作（对照）。
    await openMenuOf('热应用甲');
    expect(find.text('从艺术架移除'), findsOneWidget);
  });

  testWidgets('移除被服务端拒绝：显式 toast，卡片保留（不再静默吞掉 res.ok）', (tester) async {
    final api = NoNDesignApi('http://mock.local', MockClient((request) async {
      switch (request.url.path) {
        case '/health':
          return _json({'ok': true});
        case '/project/list':
          return _json({'ok': true, 'projects': []});
        case '/portfolio':
          return _json({
            'ok': true,
            'items': [
              {'kind': 'video', 'ref': '/v/job-1/frames.mp4', 'title': '视频乙', 'path': '/v/job-1/frames.mp4', 'detail': '视频渲染产物'},
            ],
          });
        case '/portfolio/delete':
          return _json({'detail': 'invalid_kind:video'}, 400);
      }
      return _json({'ok': false, 'detail': 'no_route'}, 404);
    }));
    await _pumpAt(tester, const PortfolioView(), 1440, store: _store(api: api));

    final card = find.ancestor(of: find.text('视频乙'), matching: find.byType(ArtShelfCard));
    await tester.tap(find.descendant(of: card, matching: find.byTooltip('更多操作')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('从艺术架移除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '隐藏'));
    await tester.pumpAndSettle();

    expect(find.text('移除失败'), findsOneWidget);
    expect(find.textContaining('invalid_kind:video'), findsOneWidget);
    expect(find.text('视频乙'), findsOneWidget); // 服务端拒绝 = 条目仍在
  });
}
