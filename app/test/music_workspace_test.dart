import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nondesign/core/music/music_compile.dart';
import 'package:nondesign/core/music/music_project.dart';
import 'package:nondesign/core/music/music_score.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/widgets/music_playback_surface.dart';
import 'package:nondesign/widgets/music_workspace.dart';
import 'package:nondesign/widgets/music_staff_view.dart';

MusicScore _score({String title = '练习曲', int tracks = 1}) => MusicScore(
  title: title,
  tempo: 96,
  timeSig: const <int>[4, 4],
  keySig: 'C',
  tracks: <MusicTrack>[
    for (int i = 0; i < tracks; i++)
      MusicTrack(
        id: 'track_$i',
        name: i == 0 ? '主旋律' : '低音',
        instrument: i == 0 ? 'piano' : 'bass',
        measures: <MusicMeasure>[
          MusicMeasure(
            id: 'm1',
            events: <MusicEvent>[
              MusicEvent(
                id: 'n1_$i',
                isRest: false,
                durNum: 1,
                durDen: 1,
                step: 'C',
                octave: i == 0 ? 5 : 3,
              ),
            ],
          ),
        ],
      ),
  ],
);

/// 空白小节（整小节休止）：点击谱面应在原小节内追加并休止补齐。
MusicScore _emptyScore() => MusicScore(
  title: '空白小节',
  tempo: 96,
  timeSig: const <int>[4, 4],
  keySig: 'C',
  tracks: <MusicTrack>[
    MusicTrack(
      id: 'track_0',
      name: '主旋律',
      instrument: 'piano',
      measures: <MusicMeasure>[
        MusicMeasure(id: 'm1', events: const <MusicEvent>[]),
      ],
    ),
  ],
);

Widget _app(Widget child) => MaterialApp(
  theme: AppTheme.build(dark: true),
  home: Scaffold(body: child),
);

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 50));
}

/// 点一次检查器动作按钮，并等保存 → 重读 → 重列这条异步链走完。
Future<void> _tapAction(WidgetTester tester, String key) async {
  final Finder finder = find.byKey(ValueKey<String>(key));
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await _settle(tester);
  await _settle(tester);
}

/// 保存返回「未通过校验」的注入 store：验证界面不会把未通过的保存伪装成成功。
class _UnverifiedSaveStore extends MusicProjectStore {
  _UnverifiedSaveStore({required Directory root}) : super(root: root);

  @override
  Future<MusicValidation> save(String name, MusicScore score) async {
    await super.save(name, score);
    return const MusicValidation(
      verified: false,
      issues: <MusicIssue>[MusicIssue('/tempo', 'score_invalid', '速度不在允许范围')],
    );
  }
}

// ---------------------------------------------------------------------------
// 播放面：可注入 Fake（不构造真 WebView）+ 读盘桩（构造不符合播放条件的快照）
// ---------------------------------------------------------------------------

class _FakePlayback extends MusicPlaybackController {
  _FakePlayback({this.duration = 2.5});

  @override
  final double duration;
  bool _ready = false;
  bool _playing = false;
  double _position = 0;
  int _beat = -1;
  int _bar = 0;
  final String _loadError = '';
  final String _technicalDetail = '';

  int playCalls = 0;
  int pauseCalls = 0;
  int stopCalls = 0;
  final List<double> seekCalls = <double>[];

  void advance(double position, {int beat = -1, int bar = 0}) {
    _position = position;
    _beat = beat;
    _bar = bar;
    notifyListeners();
  }

  @override
  bool get ready => _ready;

  @override
  bool get playing => _playing;

  @override
  double get position => _position;

  @override
  @override
  int get beat => _beat;

  @override
  int get bar => _bar;

  @override
  String get loadError => _loadError;

  @override
  String get technicalDetail => _technicalDetail;

  @override
  Future<void> start() async {
    _ready = true;
    notifyListeners();
  }

  @override
  Future<void> play() async {
    playCalls += 1;
    _playing = true;
    notifyListeners();
  }

  @override
  Future<void> pause() async {
    pauseCalls += 1;
    _playing = false;
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    stopCalls += 1;
    _playing = false;
    _position = 0;
    _beat = -1;
    _bar = 0;
    notifyListeners();
  }

  @override
  Future<void> seek(double seconds) async {
    seekCalls.add(seconds);
    _position = seconds;
    notifyListeners();
  }
}

/// 读盘桩：让工作台拿到「校验未通过 / 没有播放计划」的真实 snapshot 形状。
class _StaleSnapshotStore extends MusicProjectStore {
  _StaleSnapshotStore({required Directory root, required this.snapshot})
    : super(root: root);

  final MusicProjectSnapshot snapshot;

  @override
  Future<MusicProjectSnapshot> read(String name) async => snapshot;
}

MusicProjectSnapshot _staleSnapshot({
  required Directory dir,
  bool verified = true,
  bool withPlan = true,
}) {
  final MusicScore score = _score();
  return MusicProjectSnapshot(
    name: 'stale',
    score: score,
    raw: score.toJson(),
    validation: verified
        ? const MusicValidation(issues: <MusicIssue>[], verified: true)
        : const MusicValidation(
            issues: <MusicIssue>[
              MusicIssue('/tempo', 'score_invalid', '速度不在允许范围'),
            ],
            verified: false,
          ),
    playPlan: withPlan ? compileMusicScore(score) : null,
    dir: dir.path,
  );
}

// ---------------------------------------------------------------------------
// 谱面点击几何：用 musicStaffLayout 的产出算点击点（不手写魔法数）
// ---------------------------------------------------------------------------

Finder _staffHitFinder() => find.byKey(const ValueKey('music-staff-hit'));

/// 谱面命中的排版几何（100% 缩放时 CustomPaint 宽 = 排版宽）。
MusicStaffLayout _staffLayoutOf(WidgetTester tester, MusicScore score) =>
    musicStaffLayout(score, width: tester.getSize(_staffHitFinder()).width);

/// 谱面第 [tick] 个细分槽中心的全局坐标（单行高音谱：y=50 是 C5 一带）。
Offset _staffPointAtTick(
  WidgetTester tester,
  MusicStaffLayout layout,
  int tick, {
  List<int> timeSig = const <int>[4, 4],
  double y = 50,
}) {
  final MusicStaffColumn column = layout.rows.first.columns.first;
  final int totalTicks = timeSig[0] * kMusicStaffSlotsPerBeat;
  final double x =
      column.contentLeft + column.contentWidth * ((tick + 0.5) / totalTicks);
  return tester.getTopLeft(_staffHitFinder()) + Offset(x, y);
}

/// 谱面第一个音符符头中心的全局坐标（用来「点中已有音符」）。
Offset _staffPointOnFirstNote(WidgetTester tester, MusicStaffLayout layout) {
  final MusicStaffNote note = layout.rows.first.columns.first.notes.firstWhere(
    (MusicStaffNote candidate) => !candidate.isRest,
  );
  final Offset headCenter = Offset(
    note.headX + kMusicStaffHeadWidth / 2,
    note.headY,
  );
  return tester.getTopLeft(_staffHitFinder()) + headCenter;
}

void main() {
  late Directory temp;
  late MusicProjectStore store;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('nondesign-music-ws-');
    store = MusicProjectStore(root: temp);
  });

  tearDown(() async {
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  Future<void> viewport(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('桌面：项目/轨道/谱面/检查器/运输条同一内容布局', (tester) async {
    await viewport(tester, const Size(1440, 900));
    await store.save('study', _score(tracks: 2));
    await tester.pumpWidget(_app(MusicWorkspace(store: store)));
    await _settle(tester);

    expect(find.byKey(const ValueKey('music-header')), findsOneWidget);
    expect(find.text('音乐工作台'), findsOneWidget);
    expect(find.byKey(const ValueKey('music-project-list')), findsOneWidget);
    expect(find.byKey(const ValueKey('music-track-list')), findsOneWidget);
    expect(find.byKey(const ValueKey('music-staff-view')), findsOneWidget);
    expect(find.byKey(const ValueKey('music-view-toggle')), findsOneWidget);
    expect(find.byKey(const ValueKey('music-inspector')), findsOneWidget);
    expect(find.byKey(const ValueKey('music-transport')), findsOneWidget);
    expect(find.text('主旋律'), findsWidgets);
    expect(find.text('乐谱校验通过'), findsOneWidget);
    expect(find.byKey(const ValueKey('music-transport-time')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('中部谱面默认五线谱（可点击插入音符），可切到钢琴卷帘再切回；缩放夹在 50–150%', (tester) async {
    await viewport(tester, const Size(1440, 900));
    await store.save('study', _score());
    await tester.pumpWidget(_app(MusicWorkspace(store: store)));
    await _settle(tester);

    // 默认 = 五线谱（工作台里可点击插入音符）；钢琴卷帘不并存（切换是替换，不是叠层）。
    expect(find.byKey(const ValueKey('music-staff-view')), findsOneWidget);
    expect(find.byKey(const ValueKey('music-piano-roll')), findsNothing);
    expect(find.byKey(const ValueKey('music-view-toggle')), findsOneWidget);
    expect(find.byKey(const ValueKey('music-staff-zoom')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('music-staff-zoom'))).data,
      '100%',
    );

    // 切换到钢琴卷帘：卷帘出现、五线谱退场。
    await tester.tap(find.byKey(const ValueKey('music-view-roll')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('music-piano-roll')), findsOneWidget);
    expect(find.byKey(const ValueKey('music-staff-view')), findsNothing);

    // 切回五线谱：只读视图回来（默认仍是五线谱）。
    await tester.tap(find.byKey(const ValueKey('music-view-staff')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('music-staff-view')), findsOneWidget);
    expect(find.byKey(const ValueKey('music-piano-roll')), findsNothing);

    // 缩放：默认 100%，5 步缩到 50%，10 步放大回 150%（夹紧边界）。
    for (int i = 0; i < 5; i++) {
      await tester.tap(find.byKey(const ValueKey('music-staff-zoom-out')));
      await tester.pump();
    }
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('music-staff-zoom'))).data,
      '50%',
    );
    for (int i = 0; i < 10; i++) {
      await tester.tap(find.byKey(const ValueKey('music-staff-zoom-in')));
      await tester.pump();
    }
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('music-staff-zoom'))).data,
      '150%',
    );
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('music-staff-zoom-in')))
          .onPressed,
      isNull,
      reason: '到 150% 上限后放大按钮禁用',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('切换项目：列表选中另一个后标题/检查器更新', (tester) async {
    await viewport(tester, const Size(1440, 900));
    await store.save('alpha', _score(title: '阿尔法'));
    await store.save('beta', _score(title: '贝塔'));
    await tester.pumpWidget(_app(MusicWorkspace(store: store)));
    await _settle(tester);
    expect(find.textContaining('阿尔法'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('music-project-beta')));
    await _settle(tester);
    expect(find.textContaining('贝塔'), findsWidgets);
  });

  testWidgets('空项目库：给出可行动空态，不画假谱面', (tester) async {
    await viewport(tester, const Size(1440, 900));
    await tester.pumpWidget(_app(MusicWorkspace(store: store)));
    await _settle(tester);
    expect(find.text('还没有音乐项目'), findsOneWidget);
    expect(find.byKey(const ValueKey('music-piano-roll')), findsNothing);
    expect(find.byKey(const ValueKey('music-staff-view')), findsNothing);
    expect(find.byKey(const ValueKey('music-view-toggle')), findsNothing);
  });

  testWidgets('坏项目：读取失败给人话，不空白', (tester) async {
    await viewport(tester, const Size(1440, 900));
    Directory('${temp.path}/broken').createSync(recursive: true);
    File('${temp.path}/broken/score.json').writeAsStringSync('{not json');
    await tester.pumpWidget(_app(MusicWorkspace(store: store)));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('music-project-broken')));
    await _settle(tester);
    expect(find.textContaining('乐谱还没有通过校验'), findsOneWidget);
    expect(find.textContaining('score_invalid'), findsOneWidget);
  });

  testWidgets('编辑标题/速度 → 保存 → 重读：改动落盘，界面刷新并显示校验结果', (tester) async {
    await viewport(tester, const Size(1440, 900));
    await store.save('study', _score());
    await tester.pumpWidget(_app(MusicWorkspace(store: store)));
    await _settle(tester);

    await tester.enterText(
      find.byKey(const ValueKey('music-title-field')),
      '新练习曲',
    );
    await tester.enterText(
      find.byKey(const ValueKey('music-tempo-field')),
      '120',
    );
    await tester.tap(find.byKey(const ValueKey('music-save')));
    await _settle(tester);
    await _settle(tester);

    final MusicProjectSnapshot reread = await store.read('study');
    expect(reread.score.title, '新练习曲');
    expect(reread.score.tempo, 120);
    expect(reread.validation.verified, isTrue);
    expect(reread.playPlan, isNotNull);

    expect(find.text('标题与速度已保存 · 乐谱校验通过'), findsOneWidget);
    expect(find.textContaining('新练习曲'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('小节/音符/休止按钮 → 保存 → 重读：模型与校验结果一致', (tester) async {
    await viewport(tester, const Size(1440, 900));
    await store.save('study', _score());
    await tester.pumpWidget(_app(MusicWorkspace(store: store)));
    await _settle(tester);

    await _tapAction(tester, 'music-append-measure');
    MusicProjectSnapshot snapshot = await store.read('study');
    expect(snapshot.score.tracks.single.measures.length, 2);
    expect(snapshot.score.tracks.single.measures.last.events, isEmpty);
    expect(find.text('已追加空小节 · 乐谱校验通过'), findsOneWidget);

    await _tapAction(tester, 'music-append-measure');
    await _tapAction(tester, 'music-remove-measure');
    snapshot = await store.read('study');
    expect(snapshot.score.tracks.single.measures.length, 2);

    await _tapAction(tester, 'music-append-quarter');
    snapshot = await store.read('study');
    final MusicMeasure last = snapshot.score.tracks.single.measures.last;
    expect(
      snapshot.score.tracks.single.measures.length,
      2,
      reason: '追加音符落在空小节内，不新开小节',
    );
    expect(last.events, hasLength(2));
    expect(last.events.first.isRest, isFalse);
    expect(last.events.first.step, 'C');
    expect(last.events.first.octave, 4);
    expect(last.durationValue, closeTo(1.0, 1e-9));

    await _tapAction(tester, 'music-append-rest');
    snapshot = await store.read('study');
    expect(snapshot.score.tracks.single.measures.length, 3);
    expect(snapshot.score.tracks.single.measures.last.events, hasLength(2));
    expect(snapshot.validation.verified, isTrue);
    expect(snapshot.playPlan, isNotNull);

    // 末小节已有内容：删除要显性拒绝，而不是静默不改。
    await _tapAction(tester, 'music-remove-measure');
    expect(find.textContaining('只能删空小节'), findsOneWidget);
    final MusicProjectSnapshot afterRejected = await store.read('study');
    expect(afterRejected.score.tracks.single.measures.length, 3);
    expect(tester.takeException(), isNull);
  });

  testWidgets('轨道静音切换 → 保存 → 重读', (tester) async {
    await viewport(tester, const Size(1440, 900));
    await store.save('study', _score());
    await tester.pumpWidget(_app(MusicWorkspace(store: store)));
    await _settle(tester);

    await tester.tap(find.byKey(const ValueKey('music-track-mute')));
    await _settle(tester);
    await _settle(tester);
    expect((await store.read('study')).score.tracks.single.muted, isTrue);
    expect(find.text('轨道静音状态已保存 · 乐谱校验通过'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('music-track-mute')));
    await _settle(tester);
    await _settle(tester);
    expect((await store.read('study')).score.tracks.single.muted, isFalse);
  });

  testWidgets('保存返回未通过校验：检查器如实显示未通过与原因，不冒充成功', (tester) async {
    await viewport(tester, const Size(1440, 900));
    final _UnverifiedSaveStore unverifiedStore = _UnverifiedSaveStore(
      root: temp,
    );
    await unverifiedStore.save('study', _score());
    await tester.pumpWidget(_app(MusicWorkspace(store: unverifiedStore)));
    await _settle(tester);

    await _tapAction(tester, 'music-append-quarter');

    expect(find.byKey(const ValueKey('music-edit-status')), findsOneWidget);
    expect(find.textContaining('乐谱校验未通过'), findsWidgets);
    expect(find.textContaining('速度不在允许范围'), findsOneWidget);
    expect(find.textContaining('已追加四分音符'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('非法编辑输入：显性提示，文件保持原值', (tester) async {
    await viewport(tester, const Size(1440, 900));
    await store.save('study', _score());
    await tester.pumpWidget(_app(MusicWorkspace(store: store)));
    await _settle(tester);

    await tester.enterText(
      find.byKey(const ValueKey('music-tempo-field')),
      '999',
    );
    await tester.tap(find.byKey(const ValueKey('music-save')));
    await _settle(tester);
    await _settle(tester);

    expect(find.byKey(const ValueKey('music-edit-status')), findsOneWidget);
    expect(find.textContaining('速度必须在 20–300 之间'), findsOneWidget);
    final MusicProjectSnapshot reread = await store.read('study');
    expect(reread.score.tempo, 96);
    expect(reread.score.title, '练习曲');
    expect(tester.takeException(), isNull);
  });

  testWidgets('有播放计划且校验通过：运输条出现播放/暂停/停止与播放头，并驱动播放面', (tester) async {
    await viewport(tester, const Size(1440, 900));
    await store.save('study', _score());
    _FakePlayback fake = _FakePlayback();
    await tester.pumpWidget(
      _app(
        MusicWorkspace(
          store: store,
          playbackFactory: (MusicScore score, MusicPlayPlan plan) => fake =
              _FakePlayback(duration: musicPlaybackDurationSeconds(plan)),
        ),
      ),
    );
    await _settle(tester);

    // 演奏面与运输条播放控件都在（不是旧的「待批次」只读条）。
    expect(
      find.byKey(const ValueKey('music-playback-surface')),
      findsOneWidget,
    );
    for (final String key in <String>[
      'music-transport-play',
      'music-transport-pause',
      'music-transport-stop',
      'music-transport-seek',
      'music-transport-time',
    ]) {
      expect(find.byKey(ValueKey<String>(key)), findsOneWidget);
    }
    expect(find.textContaining('待批次'), findsNothing);

    Future<void> settle() async {
      await _settle(tester);
    }

    // 就绪后可播；播放中暂停可用、播放禁用。
    await settle();
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const ValueKey('music-transport-play')),
          )
          .onPressed,
      isNotNull,
    );
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const ValueKey('music-transport-pause')),
          )
          .onPressed,
      isNull,
    );

    await tester.tap(find.byKey(const ValueKey('music-transport-play')));
    await settle();
    expect(fake.playCalls, 1);
    expect(fake.playing, isTrue);
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const ValueKey('music-transport-pause')),
          )
          .onPressed,
      isNotNull,
    );

    await tester.tap(find.byKey(const ValueKey('music-transport-pause')));
    await settle();
    expect(fake.pauseCalls, 1);
    expect(fake.playing, isFalse);

    // seek 拖到 1.5s：运输条只发命令，播放头来自控制器回调。
    tester
        .widget<Slider>(find.byKey(const ValueKey('music-transport-seek')))
        .onChanged!(1.5);
    await settle();
    expect(fake.seekCalls, <double>[1.5]);
    expect(fake.position, closeTo(1.5, 1e-9));

    await tester.tap(find.byKey(const ValueKey('music-transport-stop')));
    await settle();
    expect(fake.stopCalls, 1);
    expect(fake.position, 0);

    // 播放头/拍位回传 → 运输条读数联动。
    fake.advance(1.25, beat: 5, bar: 2);
    await settle();
    expect(find.textContaining(' 第 2 小节'), findsOneWidget);
    expect(find.textContaining('/ 0:03'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('没有播放计划：播放控件禁用并如实说明原因，不创建播放面', (tester) async {
    await viewport(tester, const Size(1440, 900));
    await store.save('stale', _score());
    final _StaleSnapshotStore staleStore = _StaleSnapshotStore(
      root: temp,
      snapshot: _staleSnapshot(dir: temp, withPlan: false),
    );
    int factoryCalls = 0;
    await tester.pumpWidget(
      _app(
        MusicWorkspace(
          store: staleStore,
          playbackFactory: (MusicScore score, MusicPlayPlan plan) {
            factoryCalls += 1;
            return _FakePlayback();
          },
        ),
      ),
    );
    await _settle(tester);

    for (final String key in <String>[
      'music-transport-play',
      'music-transport-pause',
      'music-transport-stop',
    ]) {
      expect(
        tester.widget<IconButton>(find.byKey(ValueKey<String>(key))).onPressed,
        isNull,
      );
    }
    expect(
      find.byKey(const ValueKey('music-transport-reason')),
      findsOneWidget,
    );
    expect(find.text('乐谱还没有编译出播放计划，先通过校验'), findsOneWidget);
    expect(find.byKey(const ValueKey('music-playback-surface')), findsNothing);
    expect(factoryCalls, 0, reason: '没有编译产物时不得构造播放面');
    expect(tester.takeException(), isNull);
  });

  testWidgets('五线谱点击第 2 拍 → 按拍位插入 → 保存 → 重读确认真在第 2 拍', (tester) async {
    await viewport(tester, const Size(1440, 900));
    await store.save('study', _emptyScore());
    await tester.pumpWidget(_app(MusicWorkspace(store: store)));
    await _settle(tester);

    final Finder staffHit = _staffHitFinder();
    expect(staffHit, findsOneWidget, reason: '有可编辑回调时谱面应可点');
    final MusicStaffLayout layout = _staffLayoutOf(tester, _emptyScore());
    expect(layout.rows.single.columns.single.notes, isEmpty);
    // tick 4..7 = 第 2 拍（0 起拍下标 1）：点第 5 个槽的中心。
    final Offset tapPoint = _staffPointAtTick(tester, layout, 5);
    await tester.tapAt(tapPoint);
    await _settle(tester);
    await _settle(tester);

    final MusicProjectSnapshot reread = await store.read('study');
    final MusicTrack track = reread.score.tracks.single;
    expect(track.measures, hasLength(1), reason: '按拍位插入在原小节内完成，不新开小节');
    final MusicMeasure measure = track.measures.single;
    expect(measure.events, hasLength(3));
    expect(measure.events[0].isRest, isTrue);
    expect(measure.events[0].durationValue, closeTo(0.25, 1e-9));
    final MusicEvent note = measure.events[1];
    expect(note.isRest, isFalse);
    expect(note.step, 'C');
    expect(note.octave, 5);
    expect(note.durNum, 1, reason: '默认四分音符');
    expect(note.durDen, 4);
    expect(measure.events[2].isRest, isTrue);
    // 起始拍 = 前面休止时值 × 拍号分母（4/4 里 1/4 → 第 2 拍），不是「追加到末尾」。
    final double startBeatValue = measure.events[0].durationValue;
    expect(startBeatValue, closeTo(0.25, 1e-9));
    expect((startBeatValue * 4).round(), 1, reason: '0 起拍下标 1 = 第 2 拍');
    expect(
      measure.events.fold<double>(
        0,
        (double sum, MusicEvent event) => sum + event.durationValue,
      ),
      closeTo(1.0, 1e-9),
    );
    expect(reread.validation.verified, isTrue);
    expect(reread.playPlan, isNotNull);
    // 成功状态行如实写拍位，不伪造播放。
    expect(find.text('已在第 2 拍插入 C5 · 乐谱校验通过'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('五线谱点击已有音符 → 选中 → Delete 删除 → 保存 → 重读', (tester) async {
    await viewport(tester, const Size(1440, 900));
    await store.save('study', _score());
    await tester.pumpWidget(_app(MusicWorkspace(store: store)));
    await _settle(tester);

    final MusicStaffLayout layout = _staffLayoutOf(tester, _score());
    final Offset headPoint = _staffPointOnFirstNote(tester, layout);
    await tester.tapAt(headPoint);
    await _settle(tester);
    // 点音符只选中、不插入：状态行给选中提示。
    expect(find.text('已选中音符，按键盘 Delete 或 Backspace 删除。'), findsOneWidget);
    final MusicProjectSnapshot afterSelect = await store.read('study');
    expect(
      afterSelect.score.tracks.single.measures.single.events,
      hasLength(1),
      reason: '点已有音符不应插入新事件',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await _settle(tester);
    await _settle(tester);

    final MusicProjectSnapshot reread = await store.read('study');
    final MusicMeasure measure = reread.score.tracks.single.measures.single;
    expect(measure.events, hasLength(1));
    expect(measure.events.single.isRest, isTrue, reason: '删除后用等长休止占原拍位');
    expect(measure.events.single.durationValue, closeTo(1.0, 1e-9));
    expect(measure.events.single.id, isNot('n1_0'), reason: '被删事件 id 退场');
    expect(reread.validation.verified, isTrue);
    expect(find.text('已删除音符 · 乐谱校验通过'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('选中音符后 Backspace 也能删除', (tester) async {
    await viewport(tester, const Size(1440, 900));
    await store.save('study', _emptyScore());
    await tester.pumpWidget(_app(MusicWorkspace(store: store)));
    await _settle(tester);

    // 先在空小节第 1 拍插一个音，再点它选中。
    final MusicStaffLayout layout = _staffLayoutOf(tester, _emptyScore());
    await tester.tapAt(_staffPointAtTick(tester, layout, 1));
    await _settle(tester);
    await _settle(tester);
    final MusicProjectSnapshot inserted = await store.read('study');
    final MusicMeasure insertedMeasure =
        inserted.score.tracks.single.measures.single;
    expect(insertedMeasure.events.first.isRest, isFalse);
    final MusicStaffLayout afterInsert = _staffLayoutOf(tester, inserted.score);
    await tester.tapAt(_staffPointOnFirstNote(tester, afterInsert));
    await _settle(tester);
    expect(find.text('已选中音符，按键盘 Delete 或 Backspace 删除。'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await _settle(tester);
    await _settle(tester);
    final MusicProjectSnapshot reread = await store.read('study');
    final MusicMeasure measure = reread.score.tracks.single.measures.single;
    expect(measure.events.every((MusicEvent event) => event.isRest), isTrue);
    expect(reread.validation.verified, isTrue);
    expect(find.text('已删除音符 · 乐谱校验通过'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('五线谱点击空白小节第 1 拍 → 原地插入并休止补齐（不新开小节）', (tester) async {
    await viewport(tester, const Size(1440, 900));
    await store.save('study', _emptyScore());
    await tester.pumpWidget(_app(MusicWorkspace(store: store)));
    await _settle(tester);

    final MusicStaffLayout layout = _staffLayoutOf(tester, _emptyScore());
    final Offset tapPoint = _staffPointAtTick(tester, layout, 1);
    await tester.tapAt(tapPoint);
    await _settle(tester);
    await _settle(tester);

    final MusicProjectSnapshot reread = await store.read('study');
    final MusicTrack track = reread.score.tracks.single;
    expect(track.measures, hasLength(1), reason: '空小节放得下，不新开');
    final MusicMeasure measure = track.measures.single;
    expect(measure.events, hasLength(2));
    expect(measure.events.first.step, 'C');
    expect(measure.events.first.octave, 5);
    expect(measure.events.first.durationValue, closeTo(0.25, 1e-9));
    expect(measure.events.last.isRest, isTrue);
    expect(measure.events.last.durationValue, closeTo(0.75, 1e-9));
    expect(reread.validation.verified, isTrue, reason: '休止补齐后小节时值等于拍号');
    expect(find.text('已在第 1 拍插入 C5 · 乐谱校验通过'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('五线谱点击已被音符占用的拍位 → 显性失败，不写盘（不伪造成功）', (tester) async {
    await viewport(tester, const Size(1440, 900));
    await store.save('study', _score());
    await tester.pumpWidget(_app(MusicWorkspace(store: store)));
    await _settle(tester);

    final MusicStaffLayout layout = _staffLayoutOf(tester, _score());
    // 整小节被一个全音符占满：点第 2 拍（已在音符内）必须显性失败。
    await tester.tapAt(_staffPointAtTick(tester, layout, 5));
    await _settle(tester);
    await _settle(tester);

    expect(find.textContaining('第 2 拍已经有音符了'), findsOneWidget);
    expect(find.textContaining('已插入'), findsNothing, reason: '失败不伪造成功');
    final MusicProjectSnapshot reread = await store.read('study');
    final MusicMeasure measure = reread.score.tracks.single.measures.single;
    expect(measure.events, hasLength(1), reason: '失败不改动文件');
    expect(reread.score.tracks.single.measures, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('校验未通过：播放控件禁用并说明「先修好」', (tester) async {
    await viewport(tester, const Size(1440, 900));
    await store.save('stale', _score());
    final _StaleSnapshotStore staleStore = _StaleSnapshotStore(
      root: temp,
      snapshot: _staleSnapshot(dir: temp, verified: false),
    );
    int factoryCalls = 0;
    await tester.pumpWidget(
      _app(
        MusicWorkspace(
          store: staleStore,
          playbackFactory: (MusicScore score, MusicPlayPlan plan) {
            factoryCalls += 1;
            return _FakePlayback();
          },
        ),
      ),
    );
    await _settle(tester);

    expect(
      tester
          .widget<IconButton>(
            find.byKey(const ValueKey('music-transport-play')),
          )
          .onPressed,
      isNull,
    );
    expect(find.textContaining('先修好再播放'), findsOneWidget);
    expect(factoryCalls, 0, reason: '校验未通过时不得构造播放面');
    expect(tester.takeException(), isNull);
  });
}
