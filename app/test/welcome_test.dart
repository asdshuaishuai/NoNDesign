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
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/portfolio_entries.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/widgets/music_workspace.dart';
import 'package:nondesign/widgets/video3d_workspace.dart';
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

Widget _wrap(AppStore store) => ChangeNotifierProvider<AppStore>.value(
  value: store,
  child: MaterialApp(
    theme: AppTheme.build(dark: true),
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

  Future<void> pumpAt(WidgetTester tester, AppStore store, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(_wrap(store));
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
}
