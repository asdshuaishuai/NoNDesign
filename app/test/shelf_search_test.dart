// 艺术架搜索框（M2 检索入口）widget 回归：
// ① 语义优先——命中集来自注入的 SearchIndex（**不是**子串），验证货架按命中 id 过滤；
// ② 降级——索引不可用时退回本地子串（标题/路径），并显式提示「已按关键词匹配」；
// ③ 检索抛错不炸货架（同样退子串）；
// ④ 清除恢复全量；无结果显示「没有匹配的作品」；
// ⑤ 无服务器（api==null）别人卡片仍可检索。
//
// 用假 SearchIndex（内存、零 IO）而不是真 EmbeddingIndex：向量索引本身的
// 行为在 test/embedding_index_test.dart 里单测，这里是 UI 接线。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nondesign/core/api.dart';
import 'package:nondesign/core/embedding_index.dart';
import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/widgets/portfolio_view.dart';

http.Response _json(Object body, [int status = 200]) => http.Response(
      body is String ? body : jsonEncode(body),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

const _items = [
  {
    'kind': 'hotapp',
    'ref': 'app-a',
    'title': '热应用甲',
    'path': '/tmp/hotapps/app-a/index.html',
    'detail': '热应用',
  },
  {
    'kind': 'video',
    'ref': '/v/job-1/frames.mp4',
    'title': '视频乙',
    'path': '/v/job-1/frames.mp4',
    'detail': '视频渲染产物',
  },
  {
    'kind': 'three',
    'ref': 'scene-c',
    'title': '3D 丙',
    'path': '/tmp/3d/scene-c/scene.js',
    'detail': 'three.js 场景',
  },
];

AppStore _store({NoNDesignApi? api}) {
  final store = AppStore();
  store.ready = true;
  store.settings = AppSettings(providerId: 'deepseek', modelId: 'deepseek-v4.1-flash');
  store.api = api;
  return store;
}

NoNDesignApi _api({List<Map<String, dynamic>> items = _items}) =>
    NoNDesignApi('http://mock.local', MockClient((request) async {
      switch (request.url.path) {
        case '/health':
          return _json({'ok': true});
        case '/project/list':
          return _json({'ok': true, 'projects': []});
        case '/portfolio':
          return _json({'ok': true, 'items': items});
      }
      return _json({'ok': false, 'detail': 'no_route'}, 404);
    }));

/// 内存假索引：语义命中的 id 由 [semanticIds] 决定；null = 明确降级。
final class _FakeIndex implements SearchIndex {
  _FakeIndex({this.semanticIds, this.degradeReason, this.throwError = false});

  final Set<String>? semanticIds;
  final String? degradeReason;
  final bool throwError;
  final List<String> queries = [];

  @override
  Future<SearchOutcome> search(String query, {int topK = 12}) async {
    queries.add(query);
    if (throwError) throw StateError('index exploded');
    final ids = semanticIds;
    if (ids == null) {
      return SearchOutcome(
        hits: const [],
        semantic: false,
        reason: degradeReason ?? '索引里没有可用向量',
      );
    }
    return SearchOutcome(
      hits: [
        for (final id in ids)
          SearchHit(
            EmbeddingEntry(
              id: id,
              kind: id.split(':').first,
              title: id,
              text: '',
              ref: id,
              hash: 'h',
            ),
            0.92,
            semantic: true,
          ),
      ],
      semantic: true,
    );
  }
}

Future<void> _pumpAt(
  WidgetTester tester,
  Widget child,
  double width, {
  required AppStore store,
}) async {
  tester.view.physicalSize = Size(width, 874);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(ChangeNotifierProvider<AppStore>.value(
    value: store,
    child: MaterialApp(
      theme: AppTheme.build(dark: true).copyWith(platform: TargetPlatform.iOS),
      builder: (context, child) =>
          withResponsiveTextScale(context, child ?? const SizedBox.shrink()),
      home: Scaffold(body: child),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 200));
  expect(tester.takeException(), isNull);
}

Future<void> _search(WidgetTester tester, String query) async {
  await tester.enterText(find.byKey(const ValueKey('shelf-search')), query);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 260));
  await tester.pump();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('语义命中优先：非字面词也能筛出对应卡片', (tester) async {
    // 查询「语义探针」在任何卡片标题/路径里都不存在——只有向量命中能筛出
    // app-a；如果实现退回子串，结果会是空货架（本断言即路径分流锚点）。
    final index = _FakeIndex(semanticIds: {'hotapp:app-a'});
    await _pumpAt(tester, PortfolioView(searchIndex: index), 402,
        store: _store(api: _api()));

    expect(find.text('热应用甲'), findsOneWidget);
    expect(find.text('视频乙'), findsOneWidget);
    expect(find.text('3D 丙'), findsOneWidget);

    await _search(tester, '语义探针');

    expect(index.queries, ['语义探针']);
    expect(find.text('热应用甲'), findsOneWidget);
    expect(find.text('视频乙'), findsNothing);
    expect(find.text('3D 丙'), findsNothing);
    // 语义路径成功时不该出现降级提示。
    expect(find.byKey(const ValueKey('shelf-search-note')), findsNothing);
  });

  testWidgets('索引不可用 → 退化本地子串并提示关键词匹配', (tester) async {
    final index = _FakeIndex(degradeReason: '索引里没有可用向量（模型未就绪或尚未建立索引）');
    await _pumpAt(tester, PortfolioView(searchIndex: index), 402,
        store: _store(api: _api()));

    await _search(tester, '视频');

    expect(find.byKey(const ValueKey('shelf-search-note')), findsOneWidget);
    expect(find.text('视频乙'), findsOneWidget);
    expect(find.text('热应用甲'), findsNothing);
    expect(find.text('3D 丙'), findsNothing);
  });

  testWidgets('检索抛错 → 不崩、退子串', (tester) async {
    final index = _FakeIndex(throwError: true);
    await _pumpAt(tester, PortfolioView(searchIndex: index), 402,
        store: _store(api: _api()));

    await _search(tester, '3D');

    expect(tester.takeException(), isNull);
    expect(find.text('3D 丙'), findsOneWidget);
    expect(find.text('热应用甲'), findsNothing);
    expect(find.byKey(const ValueKey('shelf-search-note')), findsOneWidget);
  });

  testWidgets('无匹配 → 空态文案与键位', (tester) async {
    final index = _FakeIndex(degradeReason: '降级');
    await _pumpAt(tester, PortfolioView(searchIndex: index), 402,
        store: _store(api: _api()));

    await _search(tester, '不存在的作品');

    expect(find.byKey(const ValueKey('shelf-search-empty')), findsOneWidget);
    expect(find.text('没有匹配的作品'), findsOneWidget);
    expect(find.text('热应用甲'), findsNothing);
  });

  testWidgets('清除按钮恢复全量', (tester) async {
    final index = _FakeIndex(semanticIds: {'video:/v/job-1/frames.mp4'});
    await _pumpAt(tester, PortfolioView(searchIndex: index), 402,
        store: _store(api: _api()));

    await _search(tester, '语义探针');
    expect(find.text('热应用甲'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('shelf-search-clear')));
    await tester.pump();

    expect(find.text('热应用甲'), findsOneWidget);
    expect(find.text('视频乙'), findsOneWidget);
    expect(find.text('3D 丙'), findsOneWidget);
  });

  testWidgets('无服务器：原型卡片仍可关键词检索（离线可用）', (tester) async {
    final store = _store()
      ..projectPath = '/tmp/projects/design-lab.ddp'
      ..projectName = 'design-lab';
    final index = _FakeIndex(degradeReason: '索引里没有可用向量');
    await _pumpAt(tester, PortfolioView(searchIndex: index), 402, store: store);

    // api==null：离线条 + 原型段仍然展示。
    expect(find.byKey(const ValueKey('shelf-offline')), findsOneWidget);
    expect(find.text('design-lab'), findsOneWidget);

    await _search(tester, 'design');
    expect(find.text('design-lab'), findsOneWidget);

    await _search(tester, 'hotapp');
    expect(find.text('design-lab'), findsNothing);
    expect(find.byKey(const ValueKey('shelf-search-empty')), findsOneWidget);
  });
}
