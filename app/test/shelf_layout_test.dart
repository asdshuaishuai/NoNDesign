// 艺术架（Art Shelf）布局与本地数据面回归（批次 07 重写）。
//
// 覆盖：
// ① 五个固定分类签（全部/热应用/原型/视频/3D）恒在场——空分类在架子上也
//    必须可见；手机 390/402 宽下分类签独立一行横向滚动（溢出断言是锚）。
// ② 分类签筛选生效（只留该分类的货架行）。
// ③ 本地来源：热应用库 / 3D 项目 / 视频产物全部来自本机扫描，不需要连接。
// ④ shelf-2：原型卡片**本地可打开**且不给「从艺术架移除」，行首明示它在
//    「最近项目」里管理——不再有一条点了必失败的出路。
// ⑤ 热应用可由艺术架删除（本地目录 + 数据一起移除）。
// ⑥ 加载失败显式呈现（错误条 + 重试），不伪装成「还没有作品」。
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/nonapp_library.dart';
import 'package:nondesign/core/nonapp_package.dart';
import 'package:nondesign/core/project_service.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/core/three_service.dart';
import 'package:nondesign/core/toast_service.dart';
import 'package:nondesign/widgets/art_shelf_card.dart';
import 'package:nondesign/widgets/portfolio_view.dart';
import 'package:nondesign/widgets/toast_host.dart';

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

/// 第一次 scan 失败、之后恢复（错误条 + 重试的恢复路径）。
class _FlakyLibrary extends NonAppLibrary {
  _FlakyLibrary({required super.root});

  var calls = 0;

  @override
  Future<List<LibraryApp>> scan() async {
    calls++;
    if (calls == 1) throw const FileSystemException('permission denied');
    return super.scan();
  }
}

Future<void> _settle(WidgetTester tester) async {
  // 本地扫描走 dart:io（目录枚举/文件 stat）：widget test 的假时钟只推进
  // 微任务，不推进真实 IO。交替 pump 与 runAsync 若干轮，让整条
  // 「项目发现 → 热应用库 → 3D → 视频」链路逐段完成。
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
      builder: (context, child) => ToastHost(
        service: store.toasts,
        child: withResponsiveTextScale(context, child ?? const SizedBox.shrink()),
      ),
      home: Scaffold(body: child),
    ),
  ));
  await _settle(tester);
  expect(tester.takeException(), isNull);
}

Finder _chip(String label) =>
    find.descendant(of: find.byType(SingleChildScrollView), matching: find.text(label));

void main() {
  late Directory temp;
  late Directory projectsDir;
  late Directory threeDir;
  late Directory videoDir;
  late NonAppLibrary library;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    temp = Directory.systemTemp.createTempSync('shelf_');
    projectsDir = Directory('${temp.path}/projects')..createSync(recursive: true);
    threeDir = Directory('${temp.path}/3d')..createSync(recursive: true);
    videoDir = Directory('${temp.path}/videos/job-1')..createSync(recursive: true);
    library = await NonAppLibrary.open(root: Directory('${temp.path}/hotapps'));
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  AppStore makeStore({
    List<Map<String, dynamic>>? recent,
    List<Map<String, dynamic>>? serverProjects,
  }) {
    final store = AppStore(
      projects: ProjectService(root: () async => projectsDir),
      toasts: ToastService(autoDismiss: false),
    );
    store.ready = true;
    store.settings = AppSettings(providerId: 'deepseek', modelId: 'deepseek-v4.1-flash');
    store.recent = recent ?? const [];
    store.serverProjects = serverProjects ?? const [];
    return store;
  }

  PortfolioView makeView({
    NonAppLibrary? appLibrary,
    List<Map<String, dynamic>> projectEntries = const [],
  }) =>
      PortfolioView(
        library: appLibrary ?? library,
        threeService: ThreeService(root: threeDir),
        videoRoot: videoDir,
        // 测试永远不扫真实 Desktop（refreshProjects 会带上它）。
        projectEntries: projectEntries,
      );

  for (final width in const [402.0, 390.0]) {
    testWidgets('五个固定分类签在 ${width.toInt()}px 下恒在场且不溢出', (tester) async {
      await _pumpAt(tester, makeView(), width, store: makeStore());
      expect(find.text('作品集'), findsOneWidget);
      for (final label in const ['全部', '热应用', '原型', '视频', '3D']) {
        expect(_chip(label), findsOneWidget, reason: '分类签 $label 必须固定存在');
      }
      // 空态是统一措辞，不是「连不上」。
      expect(find.text('还没有作品'), findsOneWidget);
    });
  }

  testWidgets('分类签筛选只留对应货架行', (tester) async {
    await library.install(NonAppPackage.parse(_package(name: 'app-a', title: '热应用甲')));
    final store = makeStore();
    await _pumpAt(
      tester,
      makeView(projectEntries: [
        {'path': '${projectsDir.path}/proto-a.ddp', 'name': 'proto-a'},
      ]),
      402,
      store: store,
    );

    expect(find.text('热应用甲'), findsOneWidget);
    expect(find.text('proto-a'), findsOneWidget);

    await tester.tap(_chip('热应用'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('热应用甲'), findsOneWidget);
    expect(find.text('proto-a'), findsNothing);

    await tester.tap(_chip('原型'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('proto-a'), findsOneWidget);
    expect(find.text('热应用甲'), findsNothing);
  });

  testWidgets('本地来源：3D 项目与视频产物都从本机目录扫出来', (tester) async {
    final project = Directory('${threeDir.path}/scene-c')..createSync(recursive: true);
    File('${project.path}/build-state.json').writeAsStringSync(jsonEncode({
      'current': 'blockout',
      'blocked': false,
      'passes': <Object>[],
    }));
    File('${videoDir.path}/frames.mp4').writeAsBytesSync([0, 0, 0, 0]);
    final store = makeStore();
    await _pumpAt(tester, makeView(), 402, store: store);

    expect(find.text('scene-c'), findsOneWidget);
    expect(find.text('frames.mp4'), findsOneWidget);
    expect(find.byKey(const ValueKey('shelf-error')), findsNothing);
    expect(find.text('还没有作品'), findsNothing);
  });

  testWidgets('shelf-2：原型卡片不给移除动作，行首明示在「最近项目」里管理', (tester) async {
    final store = makeStore();
    await _pumpAt(
      tester,
      makeView(projectEntries: [
        {'path': '${projectsDir.path}/proto-a.ddp', 'name': 'proto-a'},
      ]),
      1440,
      store: store,
    );

    expect(find.textContaining('原型项目在「最近项目」里管理'), findsOneWidget);

    final card = find.ancestor(of: find.text('proto-a'), matching: find.byType(ArtShelfCard));
    await tester.tap(find.descendant(of: card, matching: find.byTooltip('更多操作')));
    await tester.pumpAndSettle();
    expect(find.text('复制路径'), findsOneWidget);
    expect(find.text('从艺术架移除'), findsNothing,
        reason: '原型不归艺术架所有：不提供点了必失败的移除');
  });

  testWidgets('热应用可由艺术架删除：确认后本地目录与数据一起移除', (tester) async {
    final entry = await library.install(
      NonAppPackage.parse(_package(name: 'gone-app', title: '要删的热应用')),
    );
    final store = makeStore();
    await _pumpAt(tester, makeView(), 1440, store: store);

    final card = find.ancestor(of: find.text('要删的热应用'), matching: find.byType(ArtShelfCard));
    await tester.tap(find.descendant(of: card, matching: find.byTooltip('更多操作')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('从艺术架移除'));
    await tester.pumpAndSettle();
    expect(find.textContaining('会同时删除它在本机的数据'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await _settle(tester);

    expect(Directory(entry.dir).existsSync(), isFalse);
    expect(
      find.descendant(of: find.byType(ArtShelfCard), matching: find.text('要删的热应用')),
      findsNothing,
      reason: '通知里可以保留标题，但货架上不得再有这张卡',
    );
    expect(find.text('还没有作品'), findsOneWidget);
  });

  testWidgets('作品集加载失败：错误条 + 重试可恢复', (tester) async {
    final flaky = _FlakyLibrary(root: Directory('${temp.path}/hotapps'));
    await flaky.install(NonAppPackage.parse(_package(name: 'app-b', title: '恢复后的应用')));
    final store = makeStore();
    await _pumpAt(tester, PortfolioView(library: flaky, threeService: ThreeService(root: threeDir), videoRoot: videoDir),
        402, store: store);

    expect(find.byKey(const ValueKey('shelf-error')), findsOneWidget);
    expect(find.text('作品集暂时打不开，请稍后重试'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await _settle(tester);

    expect(find.byKey(const ValueKey('shelf-error')), findsNothing);
    expect(find.text('恢复后的应用'), findsOneWidget);
  });

  testWidgets('搜索无结果与「还没有作品」区分', (tester) async {
    await _pumpAt(tester, makeView(), 402, store: makeStore());
    await tester.enterText(find.byKey(const ValueKey('shelf-search')), 'zzz');
    await tester.pump(const Duration(milliseconds: 260));

    expect(find.byKey(const ValueKey('shelf-search-empty')), findsOneWidget);
    expect(find.text('还没有作品'), findsNothing);
  });
}
