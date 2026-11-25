import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nondesign/core/music/music_project.dart';
import 'package:nondesign/core/music/music_score.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/widgets/music_workspace.dart';

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

  testWidgets('桌面：项目/轨道/只读谱面/检查器/运输条同一内容布局', (tester) async {
    await viewport(tester, const Size(1440, 900));
    await store.save('study', _score(tracks: 2));
    await tester.pumpWidget(_app(MusicWorkspace(store: store)));
    await _settle(tester);

    expect(find.byKey(const ValueKey('music-header')), findsOneWidget);
    expect(find.text('音乐工作台'), findsOneWidget);
    expect(find.byKey(const ValueKey('music-project-list')), findsOneWidget);
    expect(find.byKey(const ValueKey('music-track-list')), findsOneWidget);
    expect(find.byKey(const ValueKey('music-piano-roll')), findsOneWidget);
    expect(find.byKey(const ValueKey('music-inspector')), findsOneWidget);
    expect(find.byKey(const ValueKey('music-transport')), findsOneWidget);
    expect(find.text('主旋律'), findsWidgets);
    expect(find.text('乐谱校验通过'), findsOneWidget);
    expect(find.byKey(const ValueKey('music-transport-time')), findsOneWidget);
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
}
