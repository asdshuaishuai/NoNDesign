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
}
