// 艺术架「3D 视频」来源回归（task-17）。
//
// 覆盖：
// ① 艺术架把 `store.portfolioEntries` 里 kind='video3d' 的条目并进「视频」
//    货架行（详情文案「3D 视频 · N 镜头 / M 帧」区分来源），不在视图里另写
//    一份 `<项目目录>/portfolio/video3d` 目录扫描——与首页作品集卡同一来源；
// ② 3D 视频卡片点击走 `openPortfolioEntry` 既有路径：项目名一次性通道
//    `video3dLoadOnOpen` + `plugin:video3d`（不构造真 WebView / 真工作台）；
// ③ 视频行排序：mp4 产物与 3D 视频项目按修改时间倒序（读不到时间排最后）；
// ④ 空态不被新来源破坏：「还没有作品」仍是统一空态，不出现错误条；
// ⑤ 音乐条目保持既有（首页作品集卡路径），艺术架不新增音乐行。
//
// 测试用 fake store（手工构造、不走 boot）+ 临时目录：热应用库 / 3D / 视频
// 全部注入临时目录，作品集条目直接写进 store，不碰真实用户目录。
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/nonapp_library.dart';
import 'package:nondesign/core/portfolio_entries.dart';
import 'package:nondesign/core/project_service.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/core/three_service.dart';
import 'package:nondesign/core/toast_service.dart';
import 'package:nondesign/widgets/art_shelf_card.dart';
import 'package:nondesign/widgets/portfolio_view.dart';
import 'package:nondesign/widgets/video3d_workspace.dart';

/// 本地扫描走 dart:io（目录枚举 / 文件 stat）：widget test 的假时钟只推进
/// 微任务，不推进真实 IO。交替 pump 与 runAsync 若干轮，让整条
/// 「项目发现 → 热应用库 → 3D → 视频 → 作品集条目过滤」链路逐段完成。
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 25; i++) {
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
  }
  await tester.pump(const Duration(milliseconds: 120));
}

/// 分类签（头部横向滚动行里的文字；货架行标题不在 SingleChildScrollView 里，
/// 所以这个 finder 不会同时命中行标题）。
Finder _chip(String label) => find.descendant(
  of: find.byType(SingleChildScrollView),
  matching: find.text(label),
);

void main() {
  late Directory temp;
  late Directory projectsDir;
  late Directory threeDir;
  late Directory videoDir;
  late NonAppLibrary library;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    video3dLoadOnOpen = null;
    video3dNewOnOpen = false;
    temp = Directory.systemTemp.createTempSync('shelf_video3d_');
    projectsDir = Directory('${temp.path}/projects')
      ..createSync(recursive: true);
    threeDir = Directory('${temp.path}/3d')..createSync(recursive: true);
    videoDir = Directory('${temp.path}/videos')..createSync(recursive: true);
    library = NonAppLibrary(root: Directory('${temp.path}/hotapps'));
  });

  tearDown(() {
    video3dLoadOnOpen = null;
    video3dNewOnOpen = false;
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  AppStore makeStore({List<PortfolioEntry> entries = const []}) {
    final store = AppStore(
      projects: ProjectService(root: () async => projectsDir),
      toasts: ToastService(autoDismiss: false),
    );
    store.ready = true;
    store.settings = AppSettings(
      providerId: 'deepseek',
      modelId: 'deepseek-v4.1-flash',
    );
    // 手工构造的 store 不走 boot：`portfolioAutoRefreshEnabled == false`，
    // 艺术架不会去扫真实用户目录；条目直接注入，和首页作品集卡同一数据面。
    store.portfolioEntries = entries;
    store.portfolioLoadedAt = DateTime.now().millisecondsSinceEpoch;
    return store;
  }

  Future<void> pumpShelf(WidgetTester tester, AppStore store) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStore>.value(
        value: store,
        child: MaterialApp(
          theme: AppTheme.build(dark: true),
          builder: (context, child) => withResponsiveTextScale(
            context,
            child ?? const SizedBox.shrink(),
          ),
          home: Scaffold(
            body: PortfolioView(
              library: library,
              threeService: ThreeService(root: threeDir),
              videoRoot: videoDir,
              // 测试永远不扫真实 Desktop / 最近项目（refreshProjects 会带上它们）。
              projectEntries: const [],
            ),
          ),
        ),
      ),
    );
    await _settle(tester);
  }

  PortfolioEntry video3dEntry(
    String name, {
    required String detail,
    required int modified,
  }) => PortfolioEntry(
    kind: 'video3d',
    ref: name,
    title: name,
    detail: detail,
    path: '${videoDir.path}/../portfolio/video3d/$name',
    modified: modified,
  );

  testWidgets('3D 视频条目并入「视频」货架行：文案含镜头/帧数，排序按修改时间', (tester) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    // mp4 产物（最旧）证明两来源同列且合并排序。
    final mp4 = File('${videoDir.path}/frames.mp4')
      ..writeAsBytesSync([0, 0, 0]);
    mp4.setLastModifiedSync(DateTime.fromMillisecondsSinceEpoch(now - 60000));

    final store = makeStore(
      entries: [
        video3dEntry('solo', detail: '3D 视频 · 2 镜头 / 240 帧', modified: now),
        video3dEntry(
          'old',
          detail: '3D 视频 · 1 镜头 / 150 帧',
          modified: now - 30000,
        ),
        // 音乐条目保持既有：首页作品集卡路径，艺术架本次不新增音乐行。
        PortfolioEntry(
          kind: 'music',
          ref: 'dawn',
          title: 'dawn',
          detail: '音乐 · 2 轨 / 4 小节',
          modified: now - 10000,
        ),
      ],
    );
    await pumpShelf(tester, store);

    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('shelf-error')), findsNothing);
    expect(find.byType(ArtShelfCard), findsNWidgets(3));

    // 3D 视频项目与 mp4 都在「视频」货架行（行标题 + 分类签）。
    expect(_chip('视频'), findsOneWidget);
    expect(find.text('3D 视频 · 2 镜头 / 240 帧'), findsOneWidget);
    expect(find.text('3D 视频 · 1 镜头 / 150 帧'), findsOneWidget);
    expect(find.text('frames.mp4'), findsOneWidget);

    // 排序：修改时间倒序（solo > old > frames.mp4）。
    final titles = tester
        .widgetList<ArtShelfCard>(find.byType(ArtShelfCard))
        .map((card) => '${card.item['title']}')
        .toList();
    expect(titles, [
      'solo',
      'old',
      'frames.mp4',
    ], reason: '视频行按修改时间倒序，3D 视频项目与 mp4 产物同列');

    // 音乐条目保持既有：艺术架不新增音乐行（音乐走首页作品集卡）。
    expect(find.text('dawn'), findsNothing);
  });

  testWidgets('点 3D 视频卡片 = 项目名通道 + 3D 视频工作台（不构造真 WebView）', (tester) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final store = makeStore(
      entries: [
        video3dEntry('solo', detail: '3D 视频 · 2 镜头 / 240 帧', modified: now),
      ],
    );
    await pumpShelf(tester, store);

    final card = find.ancestor(
      of: find.text('solo'),
      matching: find.byType(ArtShelfCard),
    );
    expect(card, findsOneWidget);
    await tester.tap(find.descendant(of: card, matching: find.text('打开')));
    await tester.pump(const Duration(milliseconds: 80));

    // 与首页作品集卡 / 顶栏同一条路由：一次性通道 + 切视图。
    expect(video3dLoadOnOpen, 'solo');
    expect(video3dNewOnOpen, isFalse, reason: '按项目打开不是「新建空态」请求');
    expect(store.view, 'plugin:video3d');
  });

  testWidgets('分类签筛选不破坏：3D 视频归「视频」，切「热应用」时整行收起', (tester) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final store = makeStore(
      entries: [
        video3dEntry('solo', detail: '3D 视频 · 2 镜头 / 240 帧', modified: now),
      ],
    );
    await pumpShelf(tester, store);

    await tester.tap(_chip('视频'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(ArtShelfCard), findsOneWidget);
    expect(find.text('solo'), findsOneWidget);

    await tester.tap(_chip('热应用'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(ArtShelfCard), findsNothing, reason: '热应用类目下没有 3D 视频卡');
  });

  testWidgets('空态不被新来源破坏：没有作品时仍是「还没有作品」', (tester) async {
    final store = makeStore();
    await pumpShelf(tester, store);

    expect(find.text('还没有作品'), findsOneWidget);
    expect(find.byKey(const ValueKey('shelf-error')), findsNothing);
    expect(find.byType(ArtShelfCard), findsNothing);
  });
}
