// 排版缩放硬化（Dynamic Type）回归门（2026-11-27 主题细节批）。
//
// 两个断言面：
//  1. **夹取语义**：全局字号缩放因子只在 [NonTextScale.min, NonTextScale.max]
//     之间生效（clampTextScale 是唯一实现）；系统 Dynamic Type 拉到 1.6 时渲染
//     期仍按 1.3 倍字号排版（见[系统字号超上限时被夹到 1.3]）。
//  2. **窄面板不破版**：左栏（画板/图层树行）、检查器（节点/画板两套长栈）、
//     命令面板（列表行）在 1.3 倍字号下渲染 + 滚动到底，不得出现任何渲染异常
//     （RenderFlex overflow 等）。行文本必须单行省略（maxLines: 1 + ellipsis），
//     避免长画板名/节点文案/模板名在 252 / 348 宽的面板里换行撑高。
//
// 与 copy_screen_test.dart 的分工：那边管**文案**（术语表），这里管**排版**
// （字号缩放上限与溢出）；两者共用同一套 store 夹具形状，但不重复断言。
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/models.dart' as m show Flow;
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/core/workbench_layout.dart';
import 'package:nondesign/widgets/command_palette.dart';
import 'package:nondesign/widgets/left_panel.dart';
import 'package:nondesign/widgets/right_panel.dart';

// ---------------------------------------------------------------------------
// 夹具
// ---------------------------------------------------------------------------

const ModelRegistry _registry = ModelRegistry(
  providers: {
    'deepseek': {
      'name': 'DeepSeek',
      'api': 'https://api.deepseek.com',
      'protocol': 'openai',
      'models': {
        'deepseek-v4.1-flash': {
          'name': 'DeepSeek V4.1 Flash',
          'tool_call': true,
          'context': 128000,
        },
      },
    },
  },
  fetchedAt: 'test',
);

/// 长文案故意拉满：1.3 倍字号下如果行内不做单行省略，这些名字会换行/横向溢出。
const String _longBoardName = '一个特别长的画板名称用来测试窄面板里的单行省略行为';
const String _longNodeText = '一个特别长的图层文案用来验证树行在大字号下不会溢出或换行';
const String _longTemplateName = '一个名字特别特别长的内置模板用来检查命令面板的行内省略';
const String _longRecentName = '最近打开过的项目名称也特别长用来检查面板行的省略行为';

AppStore _store() {
  final store = AppStore()
    ..ready = true
    ..registry = _registry
    ..settings = AppSettings(
      providerId: 'deepseek',
      modelId: 'deepseek-v4.1-flash',
    );
  store.toasts.blurEnabled = false;
  store
    ..hasProject = true
    ..projectName = '演示项目'
    ..projectPath = '/tmp/demo'
    ..activeBoard = 'home'
    ..selectedNode = 'title'
    ..mbt = '---\nmoonviz:\n  format: visual-document\n  revision: 1\n  entry: home\n---\n';
  store.render = RenderEnvelope(
    ok: true,
    entry: 'home',
    revision: 3,
    mbt: store.mbt,
    artboards: [
      Artboard(
        id: 'home',
        name: '首页',
        width: 390,
        height: 844,
        nodes: [
          CanvasNode(
            id: 'title',
            parent: 'root',
            kind: 'text',
            component: 'heading',
            name: 'title',
            text: _longNodeText,
            x: 24,
            y: 48,
            w: 300,
            h: 40,
            style: NodeStyle(fill: 'none', fontSize: 24),
          ),
          CanvasNode(
            id: 'cta',
            parent: 'root',
            kind: 'rect',
            component: 'button',
            name: 'cta',
            text: '开始',
            x: 24,
            y: 120,
            w: 160,
            h: 44,
            style: NodeStyle(fill: '#7C8CFF', radius: 8),
          ),
          CanvasNode(
            id: 'body',
            parent: 'title',
            kind: 'text',
            component: 'body_text',
            name: 'body',
            text: '欢迎回来，这是一段比较长的正文节点名称',
            x: 24,
            y: 200,
            w: 300,
            h: 60,
            style: NodeStyle(fill: 'none'),
          ),
        ],
      ),
      Artboard(
        id: 'detail',
        name: _longBoardName,
        width: 390,
        height: 844,
        nodes: [],
      ),
    ],
    flows: const [m.Flow(from: 'home', to: 'detail', trigger: 'tap:cta')],
  );
  store.history = [store.mbt, store.mbt];
  store.historyIndex = 1;
  store.templates = [
    {'id': 'long_template_id', 'name': _longTemplateName},
  ];
  store.recent = [
    {'name': _longRecentName, 'path': '/tmp/very/long/recent/project/path'},
  ];
  return store;
}

/// 走 main.dart 同一条缩放路径（[withResponsiveTextScale]）：先把系统 textScaler
/// 设成 [systemScale]（模拟 Dynamic Type），再让缩放层自己夹取。桌面宽度
/// （1440）响应式基数 = 1.0，所以有效字号 = clamp(systemScale)。
Widget _host(
  AppStore store,
  Widget child, {
  double systemScale = NonTextScale.max,
  ValueChanged<double>? probe,
}) => ChangeNotifierProvider<AppStore>.value(
  value: store,
  child: MaterialApp(
    theme: AppTheme.build(dark: true),
    builder: (context, appChild) {
      final mq = MediaQuery.of(context);
      return MediaQuery(
        data: mq.copyWith(textScaler: TextScaler.linear(systemScale)),
        child: Builder(
          builder: (context) => withResponsiveTextScale(
            context,
            probe == null
                ? (appChild ?? const SizedBox.shrink())
                : Builder(
                    builder: (inner) {
                      probe(MediaQuery.textScalerOf(inner).scale(14) / 14);
                      return appChild ?? const SizedBox.shrink();
                    },
                  ),
          ),
        ),
      );
    },
    home: child,
  ),
);

Widget _scaffold(Widget body) => Scaffold(body: body);

const Size _desktop = Size(1440, 900);

/// 任何挂起异常都算失败：布局溢出（RenderFlex overflow 等）与断言错误共用
/// 一个出口，面板必须在「界面真的画出来」的前提下才算通过。
void _drain(WidgetTester tester) {
  Object? e;
  while ((e = tester.takeException()) != null) {
    fail('渲染异常：$e');
  }
}

Future<void> _pump(WidgetTester tester, Widget app) async {
  tester.view.physicalSize = _desktop;
  tester.view.devicePixelRatio = 1.0;
  await tester.pumpWidget(app);
  await tester.pump(const Duration(milliseconds: 80));
  await tester.pump(const Duration(milliseconds: 80));
  _drain(tester);
}

/// 把列表从头滚到底：惰性构建的列表行只有进入视口才会布局，要逐段滚一遍才能
/// 证明「所有行」在 1.3 倍字号下都不溢出。直接操作 ScrollPosition（不用拖拽
/// 手势），避免被行内的 Slider/TextField 抢走手势。
Future<void> _scrollEveryRow(WidgetTester tester) async {
  final scrollable = find
      .descendant(
        of: find.byType(ListView).first,
        matching: find.byType(Scrollable),
      )
      .first;
  final position = tester.state<ScrollableState>(scrollable).position;
  final max = position.maxScrollExtent;
  for (var offset = 0.0; offset <= max; offset += 120) {
    position.jumpTo(offset);
    await tester.pump(const Duration(milliseconds: 16));
    _drain(tester);
  }
  position.jumpTo(max);
  await tester.pump(const Duration(milliseconds: 16));
  _drain(tester);
}

/// 行文本的硬化契约：单行 + 省略号（换行会把固定行高撑破）。
void _expectSingleLineEllipsis(WidgetTester tester, String data) {
  final text = tester.widget<Text>(find.text(data));
  expect(text.maxLines, 1, reason: '「$data」必须 maxLines: 1');
  expect(text.overflow, TextOverflow.ellipsis, reason: '「$data」必须 ellipsis');
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('clampTextScale（全局字号缩放夹取）', () {
    test('区间端点与边界值', () {
      expect(NonTextScale.min, 1.0);
      expect(NonTextScale.max, 1.3);
      expect(clampTextScale(1.0), 1.0);
      expect(clampTextScale(1.15), 1.15);
      expect(clampTextScale(1.3), 1.3);
    });

    test('超过上限被夹到 1.3（系统 Dynamic Type / 浏览器字号可以更大）', () {
      expect(clampTextScale(1.6), 1.3);
      expect(clampTextScale(2.0), 1.3);
      expect(clampTextScale(3.0), 1.3);
    });

    test('低于下限被抬到 1.0（不跟随调小把正文压到不可读；与既有约定一致）', () {
      // 任务允许「按实现语义」断言：既有约定是夹在 1.0–1.3（theme.dart 注释与
      // CLAUDE 约定），所以 0.8 的实现语义 = 抬到下限 1.0，而不是原样透传。
      expect(clampTextScale(0.8), 1.0);
      expect(clampTextScale(0.5), 1.0);
      expect(clampTextScale(-1.0), 1.0);
    });

    test('NaN 回落到下限（非法浮点不往下传）', () {
      expect(clampTextScale(double.nan), NonTextScale.min);
    });

    test('responsiveTextScale 与 clampTextScale 是同一条夹取（唯一实现）', () {
      // 桌面 1440：响应式基数 1.0，只剩系统缩放。
      expect(responsiveTextScale(_desktop, TextScaler.linear(1.6)), 1.3);
      // 手机 390：响应式 +10%，系统 1.2 → 1.32，越过上限仍夹到 1.3。
      expect(
        responsiveTextScale(const Size(390, 844), TextScaler.linear(1.2)),
        1.3,
      );
      // 手机 +10% × 系统 1.0 = 1.1（未触发夹取）。
      expect(
        responsiveTextScale(const Size(390, 844), TextScaler.noScaling),
        closeTo(1.1, 1e-9),
      );
    });
  });

  group('1.3 倍字号下窄面板不溢出', () {
    testWidgets('左栏画板/图层树行（252 宽）', (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = _store();
      double? seen;
      await _pump(
        tester,
        _host(store, _scaffold(const LeftPanel()), probe: (v) => seen = v),
      );
      expect(seen, closeTo(NonTextScale.max, 1e-9), reason: '左栏必须在 1.3 倍字号下验证');
      _expectSingleLineEllipsis(tester, _longBoardName);
      _expectSingleLineEllipsis(tester, _longNodeText);
      // 树行不是「固定 27px 把字压扁」：行高跟着有效字号走（27 → 35.1），
      // 1.0 倍时仍是 27（既有密度不变）。两种倍率都就地量一次。
      final rowFinder = find
          .ancestor(of: find.text(_longNodeText), matching: find.byType(Row))
          .first;
      final ctx13 = tester.element(find.text(_longNodeText));
      final want13 = scaledRowHeight(ctx13, 27);
      expect(want13, closeTo(27 * NonTextScale.max, 1e-9));
      expect(tester.getSize(rowFinder).height, closeTo(want13, 0.01));
      await _scrollEveryRow(tester);

      await _pump(
        tester,
        _host(
          _store(),
          _scaffold(const LeftPanel()),
          systemScale: NonTextScale.min,
        ),
      );
      final ctx10 = tester.element(find.text(_longNodeText));
      expect(
        scaledRowHeight(ctx10, 27),
        closeTo(27, 1e-9),
        reason: '1.0 倍行高必须保持 27',
      );
      expect(
        tester
            .getSize(
              find
                  .ancestor(
                    of: find.text(_longNodeText),
                    matching: find.byType(Row),
                  )
                  .first,
            )
            .height,
        closeTo(27, 0.01),
        reason: '1.0 倍字号下树行视觉密度不能变',
      );
    });

    testWidgets('检查器节点行（348 宽）', (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final width = workbenchLayoutSpecs[WorkbenchKind.design]!.rightWidth;
      final store = _store();
      double? seen;
      await _pump(
        tester,
        _host(
          store,
          _scaffold(SizedBox(width: width, child: const Inspector())),
          probe: (v) => seen = v,
        ),
      );
      expect(
        seen,
        closeTo(NonTextScale.max, 1e-9),
        reason: '检查器必须在 1.3 倍字号下验证',
      );
      await _scrollEveryRow(tester);
    });

    testWidgets('检查器画板行（348 宽）', (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final width = workbenchLayoutSpecs[WorkbenchKind.design]!.rightWidth;
      final store = _store()..selectNode(null);
      await _pump(
        tester,
        _host(
          store,
          _scaffold(SizedBox(width: width, child: const Inspector())),
        ),
      );
      await _scrollEveryRow(tester);
    });

    testWidgets('命令面板列表行（620 宽）', (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = _store();
      await _pump(
        tester,
        _host(
          store,
          _scaffold(
            Builder(
              builder: (ctx) => Center(
                child: TextButton(
                  onPressed: () => showCommandPalette(
                    ctx,
                    onNewProject: () {},
                    onOpenPath: (_) {},
                    onSettings: () {},
                    onShortcuts: () {},
                  ),
                  child: const Text('打开命令面板'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开命令面板'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 320));
      _drain(tester);
      expect(find.byType(Dialog), findsOneWidget);
      // 模板行在 19 条固定命令之后，惰性列表默认不构建；用查询把它筛到首行，
      // 才能断言长模板名的单行省略契约。
      final search = find
          .descendant(of: find.byType(Dialog), matching: find.byType(TextField))
          .first;
      await tester.enterText(search, '模板');
      await tester.pump(const Duration(milliseconds: 16));
      _drain(tester);
      _expectSingleLineEllipsis(tester, '新建模板：$_longTemplateName');
      // 清空查询回到全量列表，逐段滚动证明每一条命令行都不溢出。
      await tester.enterText(search, '');
      await tester.pump(const Duration(milliseconds: 16));
      _drain(tester);
      await _scrollEveryRow(tester);
    });
  });

  testWidgets('系统字号超上限时被夹到 1.3（端到端，含溢出证明）', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    double? seen;
    await _pump(
      tester,
      _host(
        _store(),
        _scaffold(const LeftPanel()),
        systemScale: 1.6,
        probe: (v) => seen = v,
      ),
    );
    // 系统 1.6 → 缩放层夹到 1.3：MediaQuery 里看到的有效倍率就是 1.3。
    expect(seen, closeTo(NonTextScale.max, 1e-9));
    await _scrollEveryRow(tester);
  });
}
