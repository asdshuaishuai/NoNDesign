// Welcome 主页布局回归（用户裁决：主页布局固定不变）。
//
// 新主页只有三层：居中的「标题 + 一句话输入卡（内含目标工作台选择器）」，
// 下面并排「作品集 / 最近项目」两张卡。插件工作台列表与「NON 的工作方式」
// 说明卡已从主页删除——工作台入口只剩输入卡选择器 + 顶栏/⌘5–7。
//
// 整页连续背景 + 自适应回归（用户实机验收）：1440 宽下原有两个角落径向光斑
// 在页面上划出两条浅色竖带，主页看起来像被切成左/中/右三块；之后又指出内容列
// 不能写死固定宽度。现在背景是「底色 + 一张铺满整页的居中极淡渐变 + 点噪」，
// 宽屏左右留白 = 窗口宽 6%（16–96 收敛）、内容列 = 窗口宽 - 2×留白（窗口变宽
// 内容跟着变宽），卡片间距/上下留白/标题字号也按视口比例缩放。这里断言：
// 背景渐变整页铺满（不存在局部色块）、内容列按比例自适应、两栏与输入卡同宽、
// 左右留白对称。
//
// 溢出回归：右列曾是裸 Column，内容高随 recent（≤6）+ 工作区/桌面（≤8）
// 无上限增长——boot() 每次启动都填这两个列表，macOS 默认窗口 1440×920 与
// 1024×768（iPad 横屏）都会溢出。这里按真实容量装填后断言无溢出且可滚动。
//
// 批次 12 追加：桌面 / iPad 横版「无项目主面 = 经典 Welcome」的壳层回归，
// 以及手机 / iPad 竖屏保持聊天主面（Welcome 不得出现在主面）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/platform_capabilities.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/widgets/chat_pip_shell.dart';
import 'package:nondesign/widgets/desktop_shell.dart';
import 'package:nondesign/widgets/shell_host.dart';
import 'package:nondesign/widgets/welcome.dart';
import 'package:nondesign/widgets/workspace.dart';

/// 宽屏左右留白比例（welcome.dart 的 `_wideGutterRatio` 镜像）：窗口宽的 6%，
/// 收敛到 16–96。测试用同一公式推算，布局不写死列宽。
const double _kWideGutterRatio = 0.06;

double _wideGutterFor(double viewportWidth) =>
    (viewportWidth * _kWideGutterRatio).clamp(16.0, 96.0).toDouble();

late Directory _mirror;

AppStore _filledStore() {
  final store = AppStore()
    ..ready = true
    ..hasProject = false
    ..settings = AppSettings(providerId: 'deepseek', modelId: 'deepseek-v4.1-flash')
    ..settingsMirrorDir = _mirror.path
    ..recent = [
      for (var i = 0; i < 6; i++)
        {'path': '/tmp/recent-$i.ddp', 'name': 'recent-project-$i', 'ts': 1760000000000 + i},
    ]
    ..serverProjects = [
      for (var i = 0; i < 8; i++)
        {
          'path': '/tmp/server-$i.ddp',
          'name': 'server-project-$i',
          'bytes': 123456,
          'modified': 1760000000 + i,
          'source': i < 4 ? 'workspace' : 'desktop',
        },
    ];
  return store;
}

Widget _wrap(AppStore store) => ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(
        theme: AppTheme.build(dark: true),
        builder: (context, child) => withResponsiveTextScale(context, child ?? const SizedBox.shrink()),
        home: Welcome(onNewProject: () {}, onOpenPath: (_) {}, onSettings: () {}),
      ),
    );

/// 主页**不再**列插件工作台，也不再有「工作方式」说明卡。
void _expectNoWorkbenchList() {
  expect(find.text('工作台'), findsNothing, reason: '主页不能有插件工作台栏目');
  expect(find.text('NON 的工作方式'), findsNothing, reason: '「工作方式」说明卡已删除');
  expect(find.text('3D 工作台'), findsNothing, reason: '主页不列插件工作台入口');
  expect(find.text('视频工作台'), findsNothing, reason: '主页不列插件工作台入口');
  expect(find.text('NaN 热应用'), findsNothing, reason: '主页不列插件工作台入口');
}

void _expectWorkspaceSelector() {
  for (final mode in kWorkspaceModes) {
    expect(find.byKey(ValueKey('welcome-workspace-$mode')), findsOneWidget,
        reason: '目标工作台选择器缺 $mode');
  }
  expect(find.text('自动'), findsOneWidget);
  expect(find.text('设计'), findsOneWidget);
  expect(find.text('3D'), findsOneWidget);
  expect(find.text('视频'), findsOneWidget);
  expect(find.text('热应用'), findsOneWidget);
}

BoxDecoration _chipDecoration(WidgetTester tester, String mode) {
  final container = find.descendant(
    of: find.byKey(ValueKey('welcome-workspace-$mode')),
    matching: find.byType(Container),
  );
  expect(container, findsOneWidget);
  return tester.widget<Container>(container).decoration! as BoxDecoration;
}

/// 整页必须是一张连续背景：背景层铺满整页；除品牌标这类小渐变外，
/// 不允许任何「局部大面积渐变」——旧的左右角落光斑（560/640px 圆）
/// 会在页面上划出两条浅色竖带，把主页切成左/中/右三块。
void _expectContinuousBackdrop(WidgetTester tester, Size size) {
  final backdrop = find.byKey(const ValueKey('welcome-backdrop'));
  expect(backdrop, findsOneWidget, reason: '主页必须有一个整页背景层');
  final rect = tester.getRect(backdrop);
  expect(rect.left.abs(), lessThanOrEqualTo(0.5));
  expect(rect.top.abs(), lessThanOrEqualTo(0.5));
  expect((rect.width - size.width).abs(), lessThanOrEqualTo(0.5),
      reason: '背景必须横向铺满（否则两侧出现竖色带）');
  expect((rect.height - size.height).abs(), lessThanOrEqualTo(0.5),
      reason: '背景必须纵向铺满');

  final partialGradients = <String>[];
  for (final renderObject in tester.allRenderObjects) {
    if (renderObject is! RenderDecoratedBox) continue;
    final decoration = renderObject.decoration;
    if (decoration is! BoxDecoration || decoration.gradient == null) continue;
    final box = renderObject;
    final origin = box.localToGlobal(Offset.zero);
    final fullBleed = origin.dx.abs() <= 0.5 && (box.size.width - size.width).abs() <= 0.5;
    // 品牌标（NonLogo 26px 左右的渐变方块）是唯一允许的小面积渐变。
    final brandMark = box.size.width <= 96 && box.size.height <= 96;
    if (!fullBleed && !brandMark) {
      partialGradients.add('${box.size.width}x${box.size.height} @ $origin');
    }
  }
  expect(partialGradients, isEmpty,
      reason: '出现局部大面积渐变（角落光斑/色块），会在页面上形成竖直色带: $partialGradients');
}

/// 宽屏版式（用户裁决 2026-11-19，验收图）：
///   * hero 文案（badge/标题/副标题）占左侧，左对齐内容列左边界；
///   * 聊天框缩小后占右侧一块（340–520 宽），右对齐内容列右边界；
///   * 「作品集 / 最近项目」两栏在下方，吃满内容列并左右对称。
/// 内容列 = 窗口宽 - 2×留白（留白按窗口宽 6%，16–96 收敛）。
void _expectAdaptiveContentColumn(WidgetTester tester, Size size) {
  final composer = tester.getRect(find.byKey(const ValueKey('welcome-composer')));
  final cards = tester.getRect(find.byKey(const ValueKey('welcome-cards')));
  final title = tester.getRect(find.text('把想法变成\n能用的作品'));
  final gutter = _wideGutterFor(size.width);
  final expectedContent = size.width - gutter * 2;
  expect((cards.width - expectedContent).abs(), lessThanOrEqualTo(1),
      reason: '下方两栏应吃满内容列（期望 $expectedContent，实际 ${cards.width}）');
  expect((cards.left - gutter).abs(), lessThanOrEqualTo(1), reason: '内容列左边距应按窗口比例');
  expect((size.width - cards.right - gutter).abs(), lessThanOrEqualTo(1),
      reason: '内容列右边距应按窗口比例');
  // 聊天框：右侧一块，不是通栏大框。
  expect(composer.width, lessThanOrEqualTo(520.0),
      reason: '聊天框不得再占满通栏（用户要求缩小、占右侧）');
  expect(composer.width, greaterThanOrEqualTo(300.0), reason: '聊天框不能窄到不可用');
  expect((size.width - composer.right - gutter).abs(), lessThanOrEqualTo(1),
      reason: '聊天框必须右对齐内容列右边界');
  // hero 在左、聊天框在右；hero 左对齐内容列。
  expect((title.left - gutter).abs(), lessThanOrEqualTo(1), reason: 'hero 文案左对齐内容列');
  expect(title.right, lessThan(composer.left), reason: 'hero 文案在左，聊天框在右');
  // 左右两块都在视口内。
  expect(composer.left, greaterThan(0));
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _mirror = Directory.systemTemp.createTempSync('nd_welcome_wide');
  });
  tearDown(() {
    try {
      _mirror.deleteSync(recursive: true);
    } catch (_) {}
  });

  // 真实容量装填：1440×920（macOS 默认窗）与 1024×768（iPad 横屏）。
  for (final size in const [Size(1440, 920), Size(1024, 768)]) {
    testWidgets(
        'Welcome wide fits real data at ${size.width.toInt()}x${size.height.toInt()}',
        (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_wrap(_filledStore()));
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull, reason: '主页不得溢出');
      expect(find.byKey(const ValueKey('welcome-wide')), findsOneWidget);
      // 真实容量装填：6 条最近项目 + 8 条工作区/桌面都必须渲染。
      expect(find.text('recent-project-5'), findsOneWidget);
      expect(find.text('server-project-7'), findsOneWidget);

      // 主页固定布局：没有插件工作台列表 / 工作方式卡。
      _expectNoWorkbenchList();
      // 目标工作台选择器在输入卡内。
      _expectWorkspaceSelector();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('welcome-composer')),
          matching: find.byKey(const ValueKey('welcome-workspace-auto')),
        ),
        findsOneWidget,
        reason: '选择器必须在输入卡内',
      );

      // 整页一张连续背景 + 内容列按窗口比例自适应（左右留白对称）。
      _expectContinuousBackdrop(tester, size);
      _expectAdaptiveContentColumn(tester, size);

      // 版式：hero 文案在左、聊天框在右（不再整列居中）。
      final titleRect = tester.getRect(find.text('把想法变成\n能用的作品'));
      expect(titleRect.left, lessThan(size.width / 2), reason: 'hero 文案必须在左半区');

      // 作品集 / 最近项目并排且位于输入卡下方（左右两栏）。
      final titleBottom = titleRect.bottom;
      final portfolio = tester.getRect(find.byKey(const ValueKey('welcome-portfolio-card')));
      final recent = tester.getRect(find.byKey(const ValueKey('welcome-recent-card')));
      expect(portfolio.left, lessThan(recent.left), reason: '作品集在左，最近项目在右');
      expect(portfolio.top, greaterThan(titleBottom), reason: '两张卡在输入区下方');
      expect((portfolio.top - recent.top).abs(), lessThan(1), reason: '两栏同一行、顶对齐');
    });
  }

  // 矮窗口（手机横屏 / 小窗）仍走宽屏布局：整页可滚，不能把「开始创作」
  // 丢到屏幕外（审查 layout-4：844×390 曾实测溢出 147px）。
  for (final size in const [
    Size(844, 390),
    Size(932, 430),
    Size(900, 500),
    Size(1024, 420),
  ]) {
    testWidgets(
        'Welcome wide scrolls at ${size.width.toInt()}x${size.height.toInt()}',
        (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_wrap(_filledStore()));
      await tester.pump(const Duration(milliseconds: 50));

      expect(tester.takeException(), isNull, reason: '矮窗口下整页不得纵向溢出');
      expect(find.byKey(const ValueKey('welcome-wide')), findsOneWidget);
      // 背景仍是整页连续的一张（矮窗口也不出现局部色块/色带）。
      _expectContinuousBackdrop(tester, size);
      _expectAdaptiveContentColumn(tester, size);

      // 输入卡与「开始创作」必须能滚进视口（而不是落在屏幕外）。
      await tester.ensureVisible(find.text('开始创作'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      final rect = tester.getRect(find.text('开始创作'));
      expect(rect.bottom, lessThanOrEqualTo(size.height));
      expect(rect.top, greaterThanOrEqualTo(0));

      // 最近项目同理（在输入区下方，需要滚动）。
      await tester.ensureVisible(find.text('最近项目'));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  }

  // 空数据（首次启动）时，居中的「标题 + 输入卡」列应落在视口垂直中段，
  // 而不是贴着顶栏。内容变长后靠滚动兜住（上一组用例覆盖）。
  testWidgets('1440×920 空主页：标题区垂直居中', (tester) async {
    tester.view.physicalSize = const Size(1440, 920);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final empty = AppStore()
      ..ready = true
      ..hasProject = false
      ..settings = AppSettings(providerId: 'deepseek', modelId: 'deepseek-v4.1-flash')
      ..settingsMirrorDir = _mirror.path;
    await tester.pumpWidget(_wrap(empty));
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);

    final title = tester.getRect(find.text('把想法变成\n能用的作品'));
    // 顶栏 60 + 24 padding ≈ 84 起算；左右两块整体垂直居中，标题落在上半区。
    expect(title.top, greaterThan(100));
    expect(title.top, lessThan(920 * 0.5));
    _expectWorkspaceSelector();
    _expectContinuousBackdrop(tester, const Size(1440, 920));
    _expectAdaptiveContentColumn(tester, const Size(1440, 920));
    expect(find.text('还没有项目。上面输入一句话，马上开始。'), findsOneWidget);
  });

  // 自适应回归：内容列随窗口变宽；聊天框按比例收缩到上限后定宽 520，
  // 但 hero 阅读宽永远 ≥ 300（窗口变宽先让 hero 变宽）。
  testWidgets('宽屏：内容列自适应，聊天框右侧收缩且有上限', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Future<(double, double)> at(Size size) async {
      tester.view.physicalSize = size;
      await tester.pumpWidget(_wrap(_filledStore()));
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull);
      return (
        tester.getRect(find.byKey(const ValueKey('welcome-cards'))).width,
        tester.getRect(find.byKey(const ValueKey('welcome-composer'))).width,
      );
    }

    final (cards1024, composer1024) = await at(const Size(1024, 768));
    final (cards1440, composer1440) = await at(const Size(1440, 920));
    final (cards1920, composer1920) = await at(const Size(1920, 1080));

    // 内容列（两栏）随窗口变宽。
    expect(cards1440, greaterThan(cards1024 + 100), reason: '1440 内容列必须比 1024 宽');
    expect(cards1920, greaterThan(cards1440 + 100), reason: '1920 内容列必须比 1440 宽');
    // 聊天框：不随窗口无限变宽，收敛在 340–520。
    expect(composer1024, greaterThanOrEqualTo(300.0));
    expect(composer1440, lessThanOrEqualTo(520.0));
    expect(composer1920, lessThanOrEqualTo(520.0));
    expect(composer1920, greaterThanOrEqualTo(composer1024 - 1));
    // hero 阅读宽 ≥ 300：1920 下聊天框定宽后，剩余全部给 hero。
    final sectionGap = (1920 * 0.022).clamp(18.0, 40.0).toDouble();
    final heroWidth = cards1920 - composer1920 - sectionGap;
    expect(heroWidth, greaterThan(500), reason: '宽窗口下 hero 文案列应显著宽于聊天框');
  });

  // 目标工作台选择器：点「视频」→ 高亮切换 + store 持久化。
  testWidgets('1024×768：点视频 chip 高亮切换并持久化到设置', (tester) async {
    tester.view.physicalSize = const Size(1024, 768);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final store = _filledStore();
    await tester.pumpWidget(_wrap(store));
    await tester.pump(const Duration(milliseconds: 50));

    final p = tester.element(find.byKey(const ValueKey('welcome-workspace-auto'))).palette;
    // 默认：auto 高亮，视频未选。
    expect(store.chatWorkspaceMode, workspaceModeAuto);
    expect(_chipDecoration(tester, workspaceModeAuto).color, p.accentSoft);
    expect(_chipDecoration(tester, workspaceModeVideo).color, isNot(p.accentSoft));
    expect(find.text('NaN 会按任务自己选工作台'), findsOneWidget);

    final videoChip = find.byKey(const ValueKey('welcome-workspace-video'));
    await tester.ensureVisible(videoChip);
    await tester.pump();
    await tester.tap(videoChip);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));

    // 高亮状态切换 + 说明句子跟着换。
    expect(store.chatWorkspaceMode, workspaceModeVideo);
    expect(_chipDecoration(tester, workspaceModeVideo).color, p.accentSoft);
    expect(_chipDecoration(tester, workspaceModeAuto).color, isNot(p.accentSoft));
    expect(find.text('这次先在视频工作台做代码动画'), findsOneWidget);
    expect(find.text('NaN 会按任务自己选工作台'), findsNothing);
    expect(tester.takeException(), isNull);

    // 持久化：写进了设置存档（下次启动/发送时仍是「视频」）。
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('nondesign.settings');
    expect(raw, isNotNull, reason: '选择必须落盘');
    final saved = jsonDecode(raw!) as Map<String, dynamic>;
    expect(saved['chatWorkspaceMode'], workspaceModeVideo);
  });

  // ---- 批次 12：壳层里的 Welcome 主面 -------------------------------------

  Widget shellWrap(AppStore store, HostOs os) => ChangeNotifierProvider<AppStore>.value(
        value: store,
        child: MaterialApp(
          theme: AppTheme.build(dark: true),
          builder: (context, child) =>
              withResponsiveTextScale(context, child ?? const SizedBox.shrink()),
          home: ShellHost(capabilities: PlatformCapabilities.forOs(os)),
        ),
      );

  Future<void> pumpShell(
    WidgetTester tester,
    AppStore store,
    Size size, {
    HostOs os = HostOs.macos,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(shellWrap(store, os));
    await tester.pump(const Duration(milliseconds: 80));
  }

  for (final entry in const [
    (Size(1440, 900), HostOs.macos),
    (Size(1194, 834), HostOs.ios),
    (Size(1024, 768), HostOs.ios),
  ]) {
    testWidgets('${entry.$1.width.toInt()}×${entry.$1.height.toInt()}：无项目主面是经典 Welcome',
        (tester) async {
      await pumpShell(tester, _filledStore(), entry.$1, os: entry.$2);
      expect(find.byType(DesktopShell), findsOneWidget);
      expect(find.byType(Welcome), findsOneWidget);
      expect(find.byKey(const ValueKey('welcome-wide')), findsOneWidget);
      // 固定布局的招牌区块：一句话起步（含工作台选择器）/ 最近项目 / 作品集。
      expect(find.text('最近项目'), findsOneWidget);
      expect(find.byKey(const ValueKey('welcome-brief')), findsOneWidget);
      expect(find.text('作品集'), findsOneWidget);
      expect(find.text('recent-project-5'), findsOneWidget);
      _expectWorkspaceSelector();
      _expectNoWorkbenchList();
      expect(find.byType(Workspace), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final size in const [Size(768, 1024), Size(834, 1194), Size(390, 844), Size(844, 390)]) {
    testWidgets('${size.width.toInt()}×${size.height.toInt()}：手机/iPad 竖屏保持聊天主面',
        (tester) async {
      await pumpShell(tester, _filledStore(), size, os: HostOs.ios);
      expect(find.byType(ChatPiPShell), findsOneWidget);
      expect(find.byType(Welcome), findsNothing,
          reason: '聊天优先壳的主面是聊天，不是 Welcome');
      expect(find.byKey(const ValueKey('chat-input')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('1024 桌面主页：不挂右栏、不挂折叠条、不显示聊天入口', (tester) async {
    await pumpShell(tester, _filledStore(), const Size(1024, 768), os: HostOs.ios);
    expect(find.byType(Welcome), findsOneWidget);
    expect(find.byKey(const ValueKey('desktop-chat-rail')), findsNothing,
        reason: '主页默认不显示右侧栏');
    expect(find.byKey(const ValueKey('desktop-chat-rail-strip')), findsNothing,
        reason: '折叠覆盖条也不应出现在主页');
    expect(find.byKey(const ValueKey('welcome-open-chat')), findsNothing,
        reason: '右栏不存在时聊天入口隐藏，避免死按钮');
    expect(find.byKey(const ValueKey('welcome-brief')), findsOneWidget,
        reason: '主页仍用一句话起步输入框');
    _expectNoWorkbenchList();
    expect(tester.takeException(), isNull);
  });

  // 用户裁决 2026-11-19（验收图）：聊天框左下角 = 工作台类型选择；原来左下角
  // 的设计示例只在选择「设计」时出现，其他工作台不摆设计示例。
  testWidgets('聊天框左下角是工作台类型选择；设计示例只随「设计」出现', (tester) async {
    tester.view.physicalSize = const Size(1440, 920);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final store = _filledStore();
    await tester.pumpWidget(_wrap(store));
    await tester.pump(const Duration(milliseconds: 50));

    final composer = tester.getRect(find.byKey(const ValueKey('welcome-composer')));
    final chip = tester.getRect(find.byKey(const ValueKey('welcome-workspace-auto')));
    // 选择器在聊天框内部，落在左下角（下半部、左半边）。
    expect(composer.contains(chip.center), isTrue, reason: '工作台选择必须在聊天框内');
    expect(chip.center.dx, lessThan(composer.center.dx), reason: '选择器在聊天框左侧');
    expect(chip.center.dy, greaterThan(composer.center.dy), reason: '选择器在聊天框下半部');

    // 默认「自动」：不摆设计示例（示例是设计任务的写法）。
    expect(find.byKey(const ValueKey('welcome-example-电商 App')), findsNothing,
        reason: '非设计工作台不出现设计示例');

    // 切到「设计」：示例出现，且仍在聊天框内。
    await tester.tap(find.byKey(const ValueKey('welcome-workspace-design')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    expect(store.chatWorkspaceMode, workspaceModeDesign);
    final example = find.byKey(const ValueKey('welcome-example-电商 App'));
    expect(example, findsOneWidget, reason: '选择设计后出现设计示例');
    expect(composer.contains(tester.getRect(example).center), isTrue);

    // 切到「视频」：设计示例收回。
    await tester.tap(find.byKey(const ValueKey('welcome-workspace-video')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    expect(store.chatWorkspaceMode, workspaceModeVideo);
    expect(find.byKey(const ValueKey('welcome-example-电商 App')), findsNothing,
        reason: '切到视频后设计示例收回');
    expect(tester.takeException(), isNull);
  });
}
