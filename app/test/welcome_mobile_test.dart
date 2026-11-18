// 移动端 Welcome 页回归：真机实测（iPhone 17 / 402×874）桌面双栏在手机宽度下
// 右溢 198px、底溢 327px（右列被压成单字竖排、开始按钮叠到作品集卡上）。
// 窄屏必须走单列滚动路径；这里直接在手机尺寸渲染真实 Welcome 组件并断言无异常。
// 注意：setSurfaceSize 只改渲染表面，MediaQuery 仍是 800×600——必须改
// view.physicalSize，断点才会真正走到 narrow/wide 分支。
//
// 主页布局（用户裁决：固定不变）：标题/副标题 → 一句话输入卡（含目标工作台
// 选择器）→ 作品集 → 最近项目，单列滚动；页面不再列插件工作台。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/widgets/welcome.dart';

late Directory _mirror;

AppStore _store() {
  final store = AppStore();
  store.ready = true;
  store.hasProject = false;
  store.settings = AppSettings(providerId: 'deepseek', modelId: 'deepseek-v4.1-flash');
  store.settingsMirrorDir = _mirror.path;
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

/// 主页背景必须是一张铺满整页的连续背景：背景层铺满整页；除品牌标这类
/// 小渐变外，不允许任何局部大面积渐变（角落光斑会在页面上形成竖直色带）。
void _expectContinuousBackdrop(WidgetTester tester, Size size) {
  final backdrop = find.byKey(const ValueKey('welcome-backdrop'));
  expect(backdrop, findsOneWidget);
  final rect = tester.getRect(backdrop);
  expect((rect.width - size.width).abs(), lessThanOrEqualTo(0.5));
  expect((rect.height - size.height).abs(), lessThanOrEqualTo(0.5));

  final partialGradients = <String>[];
  for (final renderObject in tester.allRenderObjects) {
    if (renderObject is! RenderDecoratedBox) continue;
    final decoration = renderObject.decoration;
    if (decoration is! BoxDecoration || decoration.gradient == null) continue;
    final box = renderObject;
    final origin = box.localToGlobal(Offset.zero);
    final fullBleed = origin.dx.abs() <= 0.5 && (box.size.width - size.width).abs() <= 0.5;
    final brandMark = box.size.width <= 96 && box.size.height <= 96;
    if (!fullBleed && !brandMark) {
      partialGradients.add('${box.size.width}x${box.size.height} @ $origin');
    }
  }
  expect(partialGradients, isEmpty, reason: '出现局部大面积渐变（角落光斑/色块）');
}

void _expectWorkspaceSelector() {
  for (final mode in kWorkspaceModes) {
    expect(find.byKey(ValueKey('welcome-workspace-$mode')), findsOneWidget,
        reason: '目标工作台选择器缺 $mode');
  }
  expect(find.text('NaN 会按任务自己选工作台'), findsOneWidget);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _mirror = Directory.systemTemp.createTempSync('nd_welcome_mobile');
  });
  tearDown(() {
    try {
      _mirror.deleteSync(recursive: true);
    } catch (_) {}
  });

  for (final size in const [Size(402, 874), Size(390, 844), Size(375, 667)]) {
    testWidgets('Welcome fits ${size.width.toInt()}x${size.height.toInt()} without overflow',
        (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_wrap(_store()));
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('welcome-narrow')), findsOneWidget);
      expect(find.text('把想法变成\n能用的作品'), findsOneWidget);
      expect(find.text('开始创作'), findsOneWidget);
      _expectWorkspaceSelector();
      // 窄屏也是同一张整页背景（主页是一个整体）。
      _expectContinuousBackdrop(tester, size);

      // 主页不再列插件工作台 / 工作方式说明卡。
      expect(find.text('工作台'), findsNothing);
      expect(find.text('NON 的工作方式'), findsNothing);
      expect(find.text('3D 工作台'), findsNothing);
      expect(find.text('视频工作台'), findsNothing);
      expect(find.text('NaN 热应用'), findsNothing);

      // 单列顺序：标题 → 输入卡 → 作品集 → 最近项目（自下而上可滚）。
      final title = tester.getRect(find.text('把想法变成\n能用的作品'));
      final composer = tester.getRect(find.byKey(const ValueKey('welcome-brief')));
      final portfolio = tester.getRect(find.text('作品集'));
      final recent = tester.getRect(find.text('最近项目'));
      expect(composer.top, greaterThan(title.top));
      expect(portfolio.top, greaterThan(composer.top));
      expect(recent.top, greaterThan(portfolio.top));
    });
  }

  testWidgets('Welcome keeps the two-column layout on a wide desktop surface', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_wrap(_store()));
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('welcome-wide')), findsOneWidget);
    expect(find.text('最近项目'), findsOneWidget);
    expect(find.text('作品集'), findsOneWidget);
    _expectWorkspaceSelector();
    _expectContinuousBackdrop(tester, const Size(1440, 900));

    // 宽屏内容列自适应：留白 = 窗口宽 6%，输入卡与下方两栏同宽、左右对称。
    final composer = tester.getRect(find.byKey(const ValueKey('welcome-composer')));
    final cards = tester.getRect(find.byKey(const ValueKey('welcome-cards')));
    final gutter = (1440 * 0.06).clamp(16.0, 96.0).toDouble();
    expect((composer.width - (1440 - gutter * 2)).abs(), lessThanOrEqualTo(1),
        reason: '内容列应随窗口自适应（不是固定列宽）');
    expect((cards.width - composer.width).abs(), lessThanOrEqualTo(1));
    expect((composer.left - gutter).abs(), lessThanOrEqualTo(1));
    expect((composer.left - (1440 - composer.right)).abs(), lessThanOrEqualTo(1));

    // 宽屏：作品集 / 最近项目并排（左右两栏），不是单列堆叠。
    final portfolio = tester.getRect(find.text('作品集'));
    final recent = tester.getRect(find.text('最近项目'));
    expect(portfolio.left, lessThan(recent.left));
    expect((portfolio.top - recent.top).abs(), lessThan(40));
  });
}
