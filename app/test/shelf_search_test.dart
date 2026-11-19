// 艺术架搜索框（M2 检索入口）widget 回归：
// ① 语义优先——命中集来自注入的 SearchIndex（**不是**子串），验证货架按命中 id 过滤；
// ② 降级——索引不可用时退回本地子串（标题/路径/说明），并显式提示「已按关键词匹配」；
// ③ 检索抛错不炸货架（同样退子串）；
// ④ 清除恢复全量；无结果显示「没有匹配的作品」；
// ⑤ 没有连接桌面（api==null）时本机卡片仍可检索——艺术架是全本地数据面。
//
// 用假 SearchIndex（内存、零 IO）而不是真 EmbeddingIndex：向量索引本身的
// 行为在 test/embedding_index_test.dart 里单测，这里是 UI 接线。
//
// 数据来源（批次 07 起）：热应用/3D/视频都是本机目录扫描，条目 id 形如
// `<kind>:<ref>`（PortfolioView._itemKey），因此夹具落在临时目录里。
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nondesign/core/embedding_index.dart';
import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/nonapp_library.dart';
import 'package:nondesign/core/nonapp_package.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/core/three_service.dart';
import 'package:nondesign/core/toast_service.dart';
import 'package:nondesign/widgets/portfolio_view.dart';

String _html({String marker = 'shelf-marker'}) =>
    '<!doctype html><html><head><meta charset="utf-8"><style>'
    'body{background:#111;color:#eee;font:14px system-ui;padding:12px}'
    '</style></head><body><div>$marker</div>'
    '<script>document.body.dataset.ready="1";</script></body></html>';

List<int> _package({required String name, required String title}) {
  final archive = Archive();
  void add(String entry, List<int> bytes) =>
      archive.addFile(ArchiveFile(entry, bytes.length, bytes));
  add('manifest.json', utf8.encode(jsonEncode({
    'formatVersion': 1,
    'id': name,
    'name': name,
    'title': title,
    'renderer': 'html',
    'createdAt': 1700000000,
    'minAppVersion': '0.1.0',
  })));
  add('payload/index.html', utf8.encode(_html(marker: title)));
  return ZipEncoder().encode(archive);
}

AppStore _store() {
  final store = AppStore(toasts: ToastService(autoDismiss: false));
  store.ready = true;
  store.settings = AppSettings(providerId: 'deepseek', modelId: 'deepseek-v4.1-flash');
  return store;
}

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

late Directory _temp;
late Directory _threeDir;
late Directory _videoDir;
late NonAppLibrary _library;
late String _videoPath;

/// 本地扫描走 dart:io：假时钟只推进微任务，交替 pump 与 runAsync 让整条
/// 「项目发现 → 热应用库 → 3D → 视频」链路逐段完成。
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 25; i++) {
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
  }
  await tester.pump(const Duration(milliseconds: 120));
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
  await _settle(tester);
  expect(tester.takeException(), isNull);
}

/// 有内容的货架视图（热应用 / 3D / 视频各一条；原型由 store 提供）。
PortfolioView _view({SearchIndex? searchIndex}) => PortfolioView(
      searchIndex: searchIndex,
      library: _library,
      threeService: ThreeService(root: _threeDir),
      videoRoot: _videoDir,
    );

/// 空货架视图（只留原型段，用来锚「无连接桌面仍可检索本机项目」）。
PortfolioView _emptyView({SearchIndex? searchIndex}) => PortfolioView(
      searchIndex: searchIndex,
      library: NonAppLibrary(root: Directory('${_temp.path}/empty-hotapps')),
      threeService: ThreeService(root: Directory('${_temp.path}/empty-3d')),
      videoRoot: Directory('${_temp.path}/empty-videos'),
    );

Future<void> _search(WidgetTester tester, String query) async {
  await tester.enterText(find.byKey(const ValueKey('shelf-search')), query);
  await tester.pump();
  // 180ms 防抖 + 一次异步检索（假索引也要过一帧）。CI 慢机上只 pump 一次
  // 260ms 偶尔赶不上：断言会撞见还没被过滤的旧列表（flaky）。这里多给若干
  // 帧让「检索完成 → setState」落定，不用 pumpAndSettle（货架有常驻动效）。
  await tester.pump(const Duration(milliseconds: 260));
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

/// 断言侧同样轮询，且必须给真实异步让路（2026-11-19 CI 实证）：条目装载
/// 是真实 IO（zip 解压/目录扫描），假时钟 pump 推进不了它；装载回调完成
/// 时还会 `setState(_hitIds = null)` 重置一次过滤。runAsync 把控制权交还
/// 真实事件循环让 IO 落定，再 pump 让 UI 消化——finder 消失或预算耗尽，
/// 耗尽后由调用处的 expect 报出终态，不在 helper 里吞失败。
Future<void> _waitForGone(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 30; i++) {
    if (finder.evaluate().isEmpty) return;
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
  }
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // 夹具根目录必须可控且完全确定（2026-11-19 CI 实证根因）：检索走条目
    // 绝对路径的子串匹配，而 Directory.systemTemp 的 TMPDIR 带 33 位随机
    // 串——串里恰好含「3d」时（概率极高），检索词「3D」就会命中热应用卡
    // 的路径字段，列表「正确地」保留它，断言随之偶红。固定路径消掉一切
    // 随机性（createTempSync 的随机后缀同理，故不用它）。
    _temp = Directory('/tmp/nondesign_shelf_tests/fixture');
    if (_temp.existsSync()) _temp.deleteSync(recursive: true);
    _temp.createSync(recursive: true);
    _threeDir = Directory('${_temp.path}/3d')..createSync(recursive: true);
    _videoDir = Directory('${_temp.path}/videos/job-1')..createSync(recursive: true);
    _library = await NonAppLibrary.open(root: Directory('${_temp.path}/hotapps'));
    _videoPath = '${_videoDir.path}/frames.mp4';

    await _library.install(NonAppPackage.parse(_package(name: 'app-a', title: '热应用甲')));
    final project = Directory('${_threeDir.path}/scene-c')..createSync(recursive: true);
    File('${project.path}/build-state.json').writeAsStringSync(jsonEncode({
      'current': 'blockout',
      'blocked': false,
      'passes': <Object>[],
    }));
    File('${project.path}/three-spec.json').writeAsStringSync(jsonEncode({
      'title': 'scene-c',
      'summary': '',
      'components': <Object>[],
      'acceptance': <Object>[],
    }));
    File('${project.path}/scene.js').writeAsStringSync('// scene\n');
    File(_videoPath).writeAsBytesSync([0, 0, 0, 0]);
  });

  tearDown(() {
    if (_temp.existsSync()) _temp.deleteSync(recursive: true);
  });

  testWidgets('语义命中优先：非字面词也能筛出对应卡片', (tester) async {
    // 查询「语义探针」在任何卡片标题/路径里都不存在——只有向量命中能筛出
    // app-a；如果实现退回子串，结果会是空货架（本断言即路径分流锚点）。
    final index = _FakeIndex(semanticIds: {'hotapp:app-a'});
    await _pumpAt(tester, _view(searchIndex: index), 402, store: _store());

    expect(find.text('热应用甲'), findsOneWidget);
    expect(find.text('frames.mp4'), findsOneWidget);
    expect(find.text('scene-c'), findsOneWidget);

    await _search(tester, '语义探针');
    await _waitForGone(tester, find.text('frames.mp4'));

    expect(index.queries, ['语义探针']);
    expect(find.text('热应用甲'), findsOneWidget);
    expect(find.text('frames.mp4'), findsNothing);
    expect(find.text('scene-c'), findsNothing);
    // 语义路径成功时不该出现降级提示。
    expect(find.byKey(const ValueKey('shelf-search-note')), findsNothing);
  });

  testWidgets('索引不可用 → 退化本地子串并提示关键词匹配', (tester) async {
    final index = _FakeIndex(degradeReason: '索引里没有可用向量（模型未就绪或尚未建立索引）');
    await _pumpAt(tester, _view(searchIndex: index), 402, store: _store());

    // 视频条目的说明是「视频」：子串兜底要连说明一起匹配。
    await _search(tester, '视频');
    await _waitForGone(tester, find.text('热应用甲'));

    expect(find.byKey(const ValueKey('shelf-search-note')), findsOneWidget);
    expect(find.text('frames.mp4'), findsOneWidget);
    expect(find.text('热应用甲'), findsNothing);
    expect(find.text('scene-c'), findsNothing);
  });

  testWidgets('检索抛错 → 不崩、退子串', (tester) async {
    final index = _FakeIndex(throwError: true);
    await _pumpAt(tester, _view(searchIndex: index), 402, store: _store());

    await _search(tester, '3D');
    await _waitForGone(tester, find.text('热应用甲'));

    expect(tester.takeException(), isNull);
    expect(find.text('scene-c'), findsOneWidget);
    expect(find.text('热应用甲'), findsNothing);
    expect(find.byKey(const ValueKey('shelf-search-note')), findsOneWidget);
  });

  testWidgets('无匹配 → 空态文案与键位', (tester) async {
    final index = _FakeIndex(degradeReason: '降级');
    await _pumpAt(tester, _view(searchIndex: index), 402, store: _store());

    await _search(tester, '不存在的作品');
    await _waitForGone(tester, find.text('热应用甲'));

    expect(find.byKey(const ValueKey('shelf-search-empty')), findsOneWidget);
    expect(find.text('没有匹配的作品'), findsOneWidget);
    expect(find.text('热应用甲'), findsNothing);
  });

  testWidgets('清除按钮恢复全量', (tester) async {
    final index = _FakeIndex(semanticIds: {'video:$_videoPath'});
    await _pumpAt(tester, _view(searchIndex: index), 402, store: _store());

    await _search(tester, '语义探针');
    await _waitForGone(tester, find.text('热应用甲'));
    expect(find.text('热应用甲'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('shelf-search-clear')));
    await tester.pump();

    expect(find.text('热应用甲'), findsOneWidget);
    expect(find.text('frames.mp4'), findsOneWidget);
    expect(find.text('scene-c'), findsOneWidget);
  });

  testWidgets('无连接桌面：原型卡片仍可关键词检索（离线可用）', (tester) async {
    final store = _store()
      ..projectPath = '/tmp/projects/design-lab.ddp'
      ..projectName = 'design-lab';
    final index = _FakeIndex(degradeReason: '索引里没有可用向量');
    await _pumpAt(tester, _emptyView(searchIndex: index), 402, store: store);

    // api==null：本地原型段仍然展示（艺术架没有「离线」态——数据都在本机）。
    expect(find.text('design-lab'), findsOneWidget);

    await _search(tester, 'design');
    expect(find.text('design-lab'), findsOneWidget);

    await _search(tester, 'hotapp');
    await _waitForGone(tester, find.text('design-lab'));
    expect(find.text('design-lab'), findsNothing);
    expect(find.byKey(const ValueKey('shelf-search-empty')), findsOneWidget);
  });
}
