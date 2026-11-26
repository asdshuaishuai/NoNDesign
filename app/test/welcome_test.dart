// 首页作品集卡：音乐 / 3D 视频封面跟进（task-17）。
//
// 覆盖：
// ① 首页作品集展开卡对 kind='music' / kind='video3d' 给**专用图标**
//    （Icons.music_note / Icons.movie_creation_outlined），不再落进「视频」
//    兜底图标（Icons.movie_outlined 仍留给 kind='video'）；
// ② 副标题保证类型词在前：音乐「音乐 · N 小节」、3D 视频「3D 视频 · N 镜头 /
//    M 帧」；数字来自 PortfolioEntry.detail（扫描层唯一来源），detail 已带
//    前缀时原样使用，缺前缀/为空时才补齐，首页不重算/猜数字；
// ③ 图标颜色全部取 NonPalette（音乐 accent2 / 3D 视频 accent），无硬编码色；
// ④ 点条目走既有打开路径：音乐 → musicLoadOnOpen + plugin:music；
//    3D 视频 → video3dLoadOnOpen + plugin:video3d（不构造真工作台/WebView）；
// ⑤ 窄屏（手机单列）同样渲染这两类卡片且不溢出。
//
// task-26 追加：新主题（浅色 = Aqua）与四工作台入口：
// ⑥ 浅色主输入卡 = 白面 + 软阴影（AquaPanelSurface）；唯一主 CTA「开始创作」
//    = AquaGelButton；深色保持既有面板 + FilledButton（不套 Aqua）；
// ⑦ 四工作台入口 Key：welcome-enter-design/three/video/music，点击分别走
//    store.setView('design') / 'plugin:three' / 'plugin:video' / 'plugin:music'，
//    不预置项目、不打开产物（不新增业务行为）；
// ⑧ 工作台选择器与设计示例 chips 宽度 ≤ 280（复用 common.dart 的
//    nonMenuWidthCap）；窄屏四入口可见且单列顺序（输入卡 → 入口 → 作品集）不变。
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/portfolio_entries.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/widgets/aqua.dart';
import 'package:nondesign/widgets/hotapp_workspace.dart';
import 'package:nondesign/widgets/music_workspace.dart';
import 'package:nondesign/widgets/three_workspace.dart';
import 'package:nondesign/widgets/video3d_workspace.dart';
import 'package:nondesign/widgets/video_workspace.dart';
import 'package:nondesign/widgets/welcome.dart';

late Directory _mirror;

AppStore _store({List<PortfolioEntry> entries = const []}) {
  final store = AppStore()
    ..ready = true
    ..hasProject = false
    ..settings = AppSettings(
      providerId: 'deepseek',
      modelId: 'deepseek-v4.1-flash',
    )
    ..settingsMirrorDir = _mirror.path
    // 非空工作区列表让 initState 不再调 refreshProjects（测试手工构造的 store
    // 不该去扫真实用户目录）。
    ..serverProjects = [
      {
        'path': '/tmp/keepalive.ddp',
        'name': 'keepalive',
        'modified': 1760000000,
        'source': 'workspace',
      },
    ]
    ..portfolioEntries = entries;
  return store;
}

Widget _wrap(AppStore store, {bool dark = true}) => ChangeNotifierProvider<AppStore>.value(
  value: store,
  child: MaterialApp(
    theme: AppTheme.build(dark: dark),
    builder: (context, child) =>
        withResponsiveTextScale(context, child ?? const SizedBox.shrink()),
    home: Welcome(onNewProject: () {}, onOpenPath: (_) {}, onSettings: () {}),
  ),
);

void _resetOpenChannels() {
  musicLoadOnOpen = null;
  musicProjectSwitch.value = null;
  video3dLoadOnOpen = null;
  video3dNewOnOpen = false;
  threeLoadOnOpen = null;
  videoLoadOnOpen = null;
  hotAppLoadOnOpen = null;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _resetOpenChannels();
    _mirror = Directory.systemTemp.createTempSync('nd_welcome_cards');
  });

  tearDown(() {
    _resetOpenChannels();
    try {
      _mirror.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> pumpAt(WidgetTester tester, AppStore store, Size size, {bool dark = true}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(_wrap(store, dark: dark));
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);
  }

  Finder inPortfolio(Finder matching) => find.descendant(
    of: find.byKey(const ValueKey('welcome-portfolio-card')),
    matching: matching,
  );

  testWidgets('首页作品集卡：音乐 / 3D 视频有专用图标与类型开头的副标题', (tester) async {
    await pumpAt(
      tester,
      _store(
        entries: [
          const PortfolioEntry(
            kind: 'hotapp',
            ref: 'demo-app',
            title: 'demo-app',
            detail: '热应用',
          ),
          const PortfolioEntry(
            kind: 'three',
            ref: 'saturn',
            title: 'saturn',
            detail: '3D 场景',
          ),
          const PortfolioEntry(
            kind: 'video',
            ref: '/tmp/clip.mp4',
            title: 'clip.mp4',
            detail: '视频',
            path: '/tmp/clip.mp4',
          ),
          const PortfolioEntry(
            kind: 'music',
            ref: 'dawn',
            title: 'dawn',
            detail: '音乐 · 2 轨 / 4 小节',
          ),
          const PortfolioEntry(
            kind: 'video3d',
            ref: 'solo',
            title: 'solo',
            detail: '3D 视频 · 2 镜头 / 240 帧',
          ),
        ],
      ),
      const Size(1440, 920),
    );

    final card = find.byKey(const ValueKey('welcome-portfolio-card'));
    expect(card, findsOneWidget);
    // 五条全部渲染（作品集卡上限 5）。
    for (final title in ['demo-app', 'saturn', 'clip.mp4', 'dawn', 'solo']) {
      expect(
        inPortfolio(find.text(title)),
        findsOneWidget,
        reason: '作品集卡应列出 $title',
      );
    }

    // ① 专用图标：音乐 music_note，3D 视频 movie_creation_outlined；
    //    「视频」兜底图标 movie_outlined 仍只属于视频产物。
    expect(
      inPortfolio(find.byIcon(Icons.music_note)),
      findsOneWidget,
      reason: '音乐条目必须有专用图标，不能走视频兜底',
    );
    expect(
      inPortfolio(find.byIcon(Icons.movie_creation_outlined)),
      findsOneWidget,
      reason: '3D 视频条目必须有专用图标，不能走视频兜底',
    );
    expect(
      inPortfolio(find.byIcon(Icons.movie_outlined)),
      findsOneWidget,
      reason: '普通视频条目保持原图标',
    );

    // ② 副标题：类型词在前 + 数字来自 detail。
    expect(inPortfolio(find.text('音乐 · 2 轨 / 4 小节')), findsOneWidget);
    expect(inPortfolio(find.text('3D 视频 · 2 镜头 / 240 帧')), findsOneWidget);
    // 其余类型副标题保持原样（不破坏既有读法）。
    expect(inPortfolio(find.text('热应用')), findsWidgets);
    expect(inPortfolio(find.text('3D 场景')), findsOneWidget);

    // ③ 图标颜色全部取 NonPalette：音乐 accent2、3D 视频 accent。
    final p = tester.element(card).palette;
    expect(
      tester.widget<Icon>(inPortfolio(find.byIcon(Icons.music_note))).color,
      p.accent2,
      reason: '音乐图标颜色必须来自 NonPalette（accent2）',
    );
    expect(
      tester
          .widget<Icon>(inPortfolio(find.byIcon(Icons.movie_creation_outlined)))
          .color,
      p.accent,
      reason: '3D 视频图标颜色必须来自 NonPalette（accent）',
    );
  });

  testWidgets('副标题补齐前缀：detail 缺类型词或为空时不丢来源', (tester) async {
    await pumpAt(
      tester,
      _store(
        entries: [
          const PortfolioEntry(
            kind: 'hotapp',
            ref: 'demo-app',
            title: 'demo-app',
            detail: '热应用',
          ),
          const PortfolioEntry(
            kind: 'music',
            ref: 'bare',
            title: 'bare',
            detail: '2 轨 / 4 小节',
          ),
          const PortfolioEntry(
            kind: 'music',
            ref: 'blank',
            title: 'blank',
            detail: '',
          ),
          const PortfolioEntry(
            kind: 'video3d',
            ref: 'bare3d',
            title: 'bare3d',
            detail: '2 镜头 / 240 帧',
          ),
          const PortfolioEntry(
            kind: 'video3d',
            ref: 'blank3d',
            title: 'blank3d',
            detail: '',
          ),
        ],
      ),
      const Size(1440, 920),
    );

    // detail 缺前缀：补「音乐 · / 3D 视频 ·」；detail 为空：只给类型词。
    expect(inPortfolio(find.text('音乐 · 2 轨 / 4 小节')), findsOneWidget);
    expect(inPortfolio(find.text('音乐')), findsOneWidget);
    expect(inPortfolio(find.text('3D 视频 · 2 镜头 / 240 帧')), findsOneWidget);
    expect(inPortfolio(find.text('3D 视频')), findsOneWidget);
  });

  testWidgets('点音乐 / 3D 视频条目：走既有打开通道（不构造真工作台）', (tester) async {
    final store = _store(
      entries: [
        const PortfolioEntry(
          kind: 'music',
          ref: 'dawn',
          title: 'dawn',
          detail: '音乐 · 2 轨 / 4 小节',
        ),
        const PortfolioEntry(
          kind: 'video3d',
          ref: 'solo',
          title: 'solo',
          detail: '3D 视频 · 2 镜头 / 240 帧',
        ),
      ],
    );
    await pumpAt(tester, store, const Size(1440, 920));

    // 音乐：项目名一次性通道 + 音乐工作台视图 + 当前项目名。
    final musicRow = find.byKey(const ValueKey('welcome-shelf-music-dawn'));
    expect(musicRow, findsOneWidget);
    await tester.ensureVisible(musicRow);
    await tester.pump();
    await tester.tap(musicRow);
    await tester.pump(const Duration(milliseconds: 30));
    expect(musicLoadOnOpen, 'dawn');
    expect(musicProjectSwitch.value?.name, 'dawn');
    expect(store.musicProjectName, 'dawn');
    expect(store.view, 'plugin:music');

    // 3D 视频：项目名一次性通道 + 3D 视频工作台视图（普通打开，不是新建空态）。
    store.setView('home');
    await tester.pump(const Duration(milliseconds: 30));
    final video3dRow = find.byKey(const ValueKey('welcome-shelf-video3d-solo'));
    expect(video3dRow, findsOneWidget);
    await tester.ensureVisible(video3dRow);
    await tester.pump();
    await tester.tap(video3dRow);
    await tester.pump(const Duration(milliseconds: 30));
    expect(video3dLoadOnOpen, 'solo');
    expect(video3dNewOnOpen, isFalse);
    expect(store.view, 'plugin:video3d');
    expect(tester.takeException(), isNull);
  });

  testWidgets('手机窄屏：音乐 / 3D 视频卡片同样可见且不溢出', (tester) async {
    await pumpAt(
      tester,
      _store(
        entries: [
          const PortfolioEntry(
            kind: 'music',
            ref: 'dawn',
            title: 'dawn',
            detail: '音乐 · 2 轨 / 4 小节',
          ),
          const PortfolioEntry(
            kind: 'video3d',
            ref: 'solo',
            title: 'solo',
            detail: '3D 视频 · 2 镜头 / 240 帧',
          ),
        ],
      ),
      const Size(390, 844),
    );

    expect(find.byKey(const ValueKey('welcome-narrow')), findsOneWidget);
    final card = find.byKey(const ValueKey('welcome-portfolio-card'));
    expect(card, findsOneWidget);
    expect(
      find.descendant(of: card, matching: find.byIcon(Icons.music_note)),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: card,
        matching: find.byIcon(Icons.movie_creation_outlined),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: card, matching: find.text('音乐 · 2 轨 / 4 小节')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: card, matching: find.text('3D 视频 · 2 镜头 / 240 帧')),
      findsOneWidget,
    );
  });

  // ---- W1-C：新主题（浅色 = Aqua）+ 四工作台入口 -------------------------

  testWidgets('浅色 Aqua：主输入卡白面软阴影 + 唯一主 CTA 是 AquaGelButton', (tester) async {
    final store = _store();
    await pumpAt(tester, store, const Size(1440, 920), dark: false);

    final composer = find.byKey(const ValueKey('welcome-composer'));
    expect(composer, findsOneWidget);
    expect(isAquaTheme(tester.element(composer)), isTrue, reason: '浅色必须是 Aqua');
    // 主输入卡走 Aqua 材质：白面 + 发丝线 + 软阴影（不是深色半透明面板）。
    expect(tester.widget(composer), isA<AquaPanelSurface>());
    final panel = find.descendant(of: composer, matching: find.byType(Container)).first;
    final decoration = tester.widget<Container>(panel).decoration! as BoxDecoration;
    expect(decoration.color, Colors.white, reason: 'Aqua 主输入卡必须是白面');
    expect(decoration.boxShadow, isNotNull);
    expect(decoration.boxShadow!.isNotEmpty, isTrue, reason: 'Aqua 主输入卡要有软阴影');
    expect(decoration.border, isNotNull, reason: 'Aqua 面板保留发丝线边框');

    // 唯一主 CTA：浅色下「开始创作」= AquaGelButton，且不再有 FilledButton。
    final gel = find.byType(AquaGelButton);
    expect(gel, findsOneWidget, reason: '浅色唯一主 CTA 必须是糖果凝胶按钮');
    expect(find.descendant(of: gel, matching: find.text('开始创作')), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is FilledButton), findsNothing,
        reason: '浅色下主 CTA 不应再是 FilledButton');

    // 深色：主输入卡保持既有面板材质、CTA 保持 FilledButton（不套 Aqua）。
    await pumpAt(tester, store, const Size(1440, 920));
    // MaterialApp 的 AnimatedTheme 会在 200ms 内 lerp 主题；等它落定再断言，
    // 否则此刻 brightness 仍是浅色（会误判成 Aqua 分支）。
    await tester.pump(const Duration(milliseconds: 300));
    final darkComposer = find.byKey(const ValueKey('welcome-composer'));
    expect(tester.widget(darkComposer), isA<Container>());
    final darkDecoration =
        tester.widget<Container>(darkComposer).decoration! as BoxDecoration;
    expect(
      darkDecoration.color,
      tester.element(darkComposer).palette.panel.withValues(alpha: 0.9),
      reason: '深色主输入卡继续用面板色（提亮后的新调色板）',
    );
    expect(find.byType(AquaGelButton), findsNothing, reason: '深色不套 Aqua 凝胶');
    expect(find.byWidgetPredicate((w) => w is FilledButton), findsOneWidget);
  });

  testWidgets('四工作台入口：Key 齐全，点击走既有 setView 入口（不新增业务行为）', (tester) async {
    final store = _store();
    await pumpAt(tester, store, const Size(1440, 920), dark: false);

    const expected = <(String, String, String)>[
      ('welcome-enter-design', '设计', 'design'),
      ('welcome-enter-three', '3D', 'plugin:three'),
      ('welcome-enter-video', '视频', 'plugin:video'),
      ('welcome-enter-music', '音乐', 'plugin:music'),
    ];
    expect(find.byKey(const ValueKey('welcome-enter-workbenches')), findsOneWidget);
    for (final (key, label, _) in expected) {
      final card = find.byKey(ValueKey(key));
      expect(card, findsOneWidget, reason: '缺工作台入口 $key');
      expect(find.descendant(of: card, matching: find.text(label)), findsOneWidget,
          reason: '入口 $key 的文案应是「$label」');
      // 紧凑入口卡：一行高度，不占一大块版面。
      expect(tester.getSize(card).height, lessThanOrEqualTo(44.0),
          reason: '$key 应为紧凑入口卡');
    }

    // 点击只落既有视图：设计 = design、插件 = plugin:<id>。
    for (final (key, _, view) in expected) {
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pump(const Duration(milliseconds: 30));
      expect(store.view, view, reason: '$key 必须走既有 setView($view)');
    }
    // 不新增业务行为：不预置项目、不打开任何产物（一次性通道保持 null）。
    expect(threeLoadOnOpen, isNull, reason: '入口不得预置 3D 项目');
    expect(videoLoadOnOpen, isNull, reason: '入口不得打开视频产物');
    expect(hotAppLoadOnOpen, isNull);
    expect(musicLoadOnOpen, isNull, reason: '入口不得打开音乐项目');
    expect(tester.takeException(), isNull);
  });

  testWidgets('主页选择器/设计示例 chips 宽度 ≤ 280（宽屏与窄屏都夹取）', (tester) async {
    final store = _store();
    await pumpAt(tester, store, const Size(1440, 920), dark: false);

    final selector = find.byKey(const ValueKey('welcome-workspace-selector'));
    expect(selector, findsOneWidget);
    expect(tester.getSize(selector).width, lessThanOrEqualTo(280.0),
        reason: '工作台选择器宽度必须 ≤280');

    // 设计示例只在「设计」时出现；同样夹在 280 内（不随输入卡铺开）。
    await tester.tap(find.byKey(const ValueKey('welcome-workspace-design')));
    await tester.pump(const Duration(milliseconds: 30));
    final examples = find.byKey(const ValueKey('welcome-examples'));
    expect(examples, findsOneWidget, reason: '选设计后应出现设计示例');
    expect(tester.getSize(examples).width, lessThanOrEqualTo(280.0),
        reason: '示例 chips 宽度必须 ≤280');

    // 窄屏同样不超过上限。
    await pumpAt(tester, _store(), const Size(390, 844));
    expect(
      tester.getSize(find.byKey(const ValueKey('welcome-workspace-selector'))).width,
      lessThanOrEqualTo(280.0),
    );
  });

  testWidgets('浅色窄屏：四工作台入口与 Aqua 主 CTA 不溢出、单列顺序不变', (tester) async {
    await pumpAt(tester, _store(), const Size(390, 844), dark: false);

    expect(find.byKey(const ValueKey('welcome-narrow')), findsOneWidget);
    for (final key in const [
      'welcome-enter-design',
      'welcome-enter-three',
      'welcome-enter-video',
      'welcome-enter-music',
    ]) {
      expect(find.byKey(ValueKey(key)), findsOneWidget, reason: '窄屏缺入口 $key');
    }
    expect(find.byType(AquaGelButton), findsOneWidget);

    // 单列顺序：输入卡 → 四工作台入口 → 作品集。
    final composer = tester.getRect(find.byKey(const ValueKey('welcome-composer')));
    final entries =
        tester.getRect(find.byKey(const ValueKey('welcome-enter-workbenches')));
    final portfolio = tester.getRect(find.byKey(const ValueKey('welcome-portfolio-card')));
    expect(entries.top, greaterThan(composer.top));
    expect(portfolio.top, greaterThan(entries.bottom));
    expect(tester.takeException(), isNull);
  });
}
