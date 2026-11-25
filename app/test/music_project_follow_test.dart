// 音乐项目跟随链路回归（task-9：作品集/顶栏菜单/工作台打开通道）。
//
// 覆盖：
//   * openMusicWorkspace(store, name) → musicLoadOnOpen + store.musicProjectName
//     + plugin:music（与 threeLoadOnOpen/hotAppLoadOnOpen 同一打开契约）；
//   * openPortfolioEntry(kind:'music') 走同一条路由；
//   * 工作台 initState 消费 musicLoadOnOpen：指定项目优先于列表首项，消费后清空；
//   * 工作台已挂载时 musicProjectSwitch 请求直接切项目（不用重挂载）；
//   * 顶栏「音乐」分区列出 kind=='music' 条目并可点开，_activeProject 显示
//     当前音乐项目名（空则回退「音乐工作台」）。
//
// 不构造真 WebView：注入临时目录的 MusicProjectStore + Fake 播放控制器。
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/music/music_compile.dart';
import 'package:nondesign/core/music/music_project.dart';
import 'package:nondesign/core/music/music_score.dart';
import 'package:nondesign/core/portfolio_entries.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/core/toast_service.dart';
import 'package:nondesign/widgets/music_playback_surface.dart';
import 'package:nondesign/widgets/music_workspace.dart';
import 'package:nondesign/widgets/title_bar.dart';
import 'package:nondesign/widgets/workspace_open.dart';

MusicScore _score({String title = '练习曲'}) => MusicScore(
  title: title,
  tempo: 96,
  timeSig: const <int>[4, 4],
  keySig: 'C',
  tracks: <MusicTrack>[
    MusicTrack(
      id: 'melody',
      name: '主旋律',
      instrument: 'piano',
      measures: <MusicMeasure>[
        MusicMeasure(
          id: 'm1',
          events: <MusicEvent>[
            MusicEvent(
              id: 'n1',
              isRest: false,
              durNum: 1,
              durDen: 1,
              step: 'C',
              octave: 5,
            ),
          ],
        ),
      ],
    ),
  ],
);

/// 播放面 Fake：不构造 `webview_all`（widget test 里没有真 WebView）。
class _FakePlayback extends MusicPlaybackController {
  @override
  double get duration => 2.0;

  @override
  bool get ready => true;

  @override
  bool get playing => false;

  @override
  double get position => 0;

  @override
  int get beat => -1;

  @override
  int get bar => 0;

  @override
  String get loadError => '';

  @override
  String get technicalDetail => '';

  @override
  Future<void> start() async {}

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> seek(double seconds) async {}
}

AppStore _store() {
  final store = AppStore(toasts: ToastService(autoDismiss: false))
    ..ready = true
    ..settings = AppSettings(
      providerId: 'deepseek',
      modelId: 'deepseek-v4.1-flash',
    )
    ..view = 'design';
  // 不碰真实用户目录（AppStore 其它异步路径只在 UI 外面才会用到）。
  store.recoveryDir = Directory.systemTemp
      .createTempSync('nd-music-follow-recovery')
      .path;
  return store;
}

Widget _app(Widget child) => MaterialApp(
  theme: AppTheme.build(dark: true),
  home: Scaffold(body: child),
);

Widget _titleBarApp(AppStore store) => ChangeNotifierProvider<AppStore>.value(
  value: store,
  child: _app(
    TitleBar(
      onCommand: () {},
      onSettings: () {},
      onNewProject: () {},
      onOpenProject: () {},
      onShortcuts: () {},
      onOpenRecent: (_) {},
    ),
  ),
);

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    });
  }
  await tester.pump(const Duration(milliseconds: 120));
}

Future<void> _viewport(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1440, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// 工作台头部（`音乐工作台 | 标题 · 项目名`）里是否正在显示某个项目。
Finder _headerContaining(String text) => find.descendant(
  of: find.byKey(const ValueKey('music-header')),
  matching: find.textContaining(text),
);

void _resetGlobals() {
  musicLoadOnOpen = null;
  musicProjectSwitch.value = null;
}

void main() {
  late Directory temp;
  late MusicProjectStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _resetGlobals();
    temp = Directory.systemTemp.createTempSync('nd-music-follow');
    store = MusicProjectStore(root: temp);
    await store.save('alpha', _score(title: '阿尔法'));
    await store.save('beta', _score(title: '贝塔'));
  });

  tearDown(() {
    _resetGlobals();
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  // ---------------------------------------------------------------------------
  // 路由函数（不构造 UI）
  // ---------------------------------------------------------------------------

  test(
    'openMusicWorkspace(name)：写入一次性通道 + store 当前项目名 + plugin:music',
    () async {
      final appStore = _store();

      openMusicWorkspace(appStore, '  beta  ');

      expect(appStore.view, 'plugin:music');
      expect(musicLoadOnOpen, 'beta', reason: '项目名要 trim 后交给工作台');
      expect(appStore.musicProjectName, 'beta', reason: '顶栏据此显示当前音乐项目');
    },
  );

  test('openMusicWorkspace() 不带项目：清空通道与当前项目名，交给工作台首项逻辑', () async {
    final appStore = _store()..view = 'plugin:video';

    openMusicWorkspace(appStore);

    expect(appStore.view, 'plugin:music');
    expect(musicLoadOnOpen, isNull);
    expect(appStore.musicProjectName, isEmpty);
  });

  test('已在音乐工作台时 openMusicWorkspace() 不打断当前项目', () async {
    final appStore = _store()..setMusicProjectName('beta');
    appStore.view = 'plugin:music';

    openMusicWorkspace(appStore);

    expect(appStore.view, 'plugin:music');
    expect(appStore.musicProjectName, 'beta');
  });

  test('openPortfolioEntry(kind:music) 走同一条打开路由', () async {
    final appStore = _store();

    openPortfolioEntry(
      appStore,
      const PortfolioEntry(
        kind: 'music',
        ref: 'alpha',
        title: '阿尔法',
        detail: '音乐 · 1 轨 / 1 小节',
      ),
    );

    expect(appStore.view, 'plugin:music');
    expect(musicLoadOnOpen, 'alpha');
    expect(appStore.musicProjectName, 'alpha');
  });

  // ---------------------------------------------------------------------------
  // 工作台消费通道
  // ---------------------------------------------------------------------------

  testWidgets('initState 消费 musicLoadOnOpen：指定项目优先于列表首项，消费后清空', (tester) async {
    await _viewport(tester);
    musicLoadOnOpen = 'beta';

    await tester.pumpWidget(
      _app(
        MusicWorkspace(
          store: store,
          playbackFactory: (MusicScore score, MusicPlayPlan plan) =>
              _FakePlayback(),
        ),
      ),
    );
    await _settle(tester);

    expect(musicLoadOnOpen, isNull, reason: '开局通道是一次性的');
    expect(_headerContaining('贝塔'), findsOneWidget);
    expect(_headerContaining('阿尔法'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('musicLoadOnOpen 为空：保持现有「打开列表首项」逻辑', (tester) async {
    await _viewport(tester);

    await tester.pumpWidget(
      _app(
        MusicWorkspace(
          store: store,
          playbackFactory: (MusicScore score, MusicPlayPlan plan) =>
              _FakePlayback(),
        ),
      ),
    );
    await _settle(tester);

    expect(_headerContaining('阿尔法'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('工作台已挂载：musicProjectSwitch 请求直接切到另一个项目', (tester) async {
    await _viewport(tester);

    await tester.pumpWidget(
      _app(
        MusicWorkspace(
          store: store,
          playbackFactory: (MusicScore score, MusicPlayPlan plan) =>
              _FakePlayback(),
        ),
      ),
    );
    await _settle(tester);
    expect(_headerContaining('阿尔法'), findsOneWidget);

    musicProjectSwitch.value = const MusicProjectSwitch('beta');
    await _settle(tester);

    expect(_headerContaining('贝塔'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('指定项目不存在：如实报「没有找到」，不静默落回首项', (tester) async {
    await _viewport(tester);
    musicLoadOnOpen = 'ghost';

    await tester.pumpWidget(
      _app(
        MusicWorkspace(
          store: store,
          playbackFactory: (MusicScore score, MusicPlayPlan plan) =>
              _FakePlayback(),
        ),
      ),
    );
    await _settle(tester);

    expect(find.textContaining('没有找到这个音乐项目'), findsOneWidget);
    expect(musicLoadOnOpen, isNull);
    expect(tester.takeException(), isNull);
  });

  // ---------------------------------------------------------------------------
  // 顶栏「音乐」分区 + 当前项目名
  // ---------------------------------------------------------------------------

  testWidgets('顶栏音乐分区：列音乐项目，点击后路由到音乐工作台并带项目名', (tester) async {
    await _viewport(tester);
    final appStore = _store()
      ..portfolioEntries = const <PortfolioEntry>[
        PortfolioEntry(
          kind: 'music',
          ref: 'alpha',
          title: '阿尔法',
          detail: '音乐 · 1 轨 / 1 小节',
        ),
        PortfolioEntry(
          kind: 'music',
          ref: 'beta',
          title: '贝塔',
          detail: '音乐 · 1 轨 / 1 小节',
        ),
      ];

    await tester.pumpWidget(_titleBarApp(appStore));
    await tester.tap(find.byKey(const ValueKey('title-bar-project-menu')));
    await tester.pumpAndSettle();

    expect(find.text('音乐'), findsOneWidget, reason: '菜单有「音乐」分区标签');
    expect(find.text('阿尔法'), findsOneWidget);
    expect(find.text('贝塔'), findsOneWidget);
    expect(find.text('音乐工作台'), findsOneWidget);

    await tester.tap(find.text('贝塔'));
    await tester.pumpAndSettle();

    expect(appStore.view, 'plugin:music');
    expect(appStore.musicProjectName, 'beta');
    expect(musicLoadOnOpen, 'beta');
    // 当前项目名跟着进顶栏标识（不再是笼统的「音乐工作台」）。
    expect(find.text('beta'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('顶栏「音乐工作台」入口：不带项目进音乐工作台', (tester) async {
    await _viewport(tester);
    final appStore = _store();

    await tester.pumpWidget(_titleBarApp(appStore));
    await tester.tap(find.byKey(const ValueKey('title-bar-project-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('音乐工作台'));
    await tester.pumpAndSettle();

    expect(appStore.view, 'plugin:music');
    expect(appStore.musicProjectName, isEmpty);
    expect(musicLoadOnOpen, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('_activeProject 对 plugin:music：显示 musicProjectName，空则「音乐工作台」', (
    tester,
  ) async {
    await _viewport(tester);
    final appStore = _store()
      ..view = 'plugin:music'
      ..setMusicProjectName('beta');

    await tester.pumpWidget(_titleBarApp(appStore));
    expect(find.text('beta'), findsOneWidget);

    appStore.setMusicProjectName('');
    await tester.pump();
    expect(find.text('音乐工作台'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
