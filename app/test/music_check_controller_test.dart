// 音乐工作台通用检查器（乐谱级 / 轨道 / 音符 → 右侧「检查」tab 属性表）回归测试。
//
// 覆盖：
//  * 无选中（项目已打开）→ 乐谱级属性表（标题/速度/拍号/调号）的字段与契约值；
//  * 选中轨道/音符 → 对应属性表，不回退到乐谱级；点「乐谱」条目回到乐谱级；
//  * 宽屏壳层在场时内容区旧检查器降级只读，标题/速度仍可从右栏检查写回
//    score.json（标题真的落盘变化）；
//  * 改标题/速度/拍号 → update true 且 score.json 真落盘；非法速度（0/999）等
//    → false 且文件逐字节不变；
//  * 调号只读（core/music 没有既有纯函数）；拍号与已有小节内容冲突 → 拒绝；
//  * 无项目/坏项目 → sheet 为 null；
//  * 独立工作台（无 provider）内容区检查器保持可编辑；
//  * 卸载只清自己的控制器注册，不误清别的工作台。
//
// 全部用临时目录 + fake 播放面，不构造真 WebView。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nondesign/core/inspect/check_field.dart';
import 'package:nondesign/core/music/music_compile.dart';
import 'package:nondesign/core/music/music_project.dart';
import 'package:nondesign/core/music/music_score.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/widgets/music_playback_surface.dart';
import 'package:nondesign/widgets/music_staff_view.dart';
import 'package:nondesign/widgets/music_workspace.dart';

// ---------------------------------------------------------------------------
// 测试乐谱：两轨（第一条整小节一个全音符 = 第 1 拍，第二条带静音）
// ---------------------------------------------------------------------------

MusicScore _score() => MusicScore(
  title: '检查器练习曲',
  tempo: 96,
  timeSig: const <int>[4, 4],
  keySig: 'C',
  tracks: <MusicTrack>[
    MusicTrack(
      id: 'track_0',
      name: '主旋律',
      instrument: 'piano',
      volume: 0.8,
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
    MusicTrack(
      id: 'track_1',
      name: '低音',
      instrument: 'bass',
      muted: true,
      measures: <MusicMeasure>[
        MusicMeasure(
          id: 'm1',
          events: <MusicEvent>[
            MusicEvent(
              id: 'n2',
              isRest: false,
              durNum: 1,
              durDen: 4,
              step: 'C',
              octave: 3,
            ),
            MusicEvent(id: 'r1', isRest: true, durNum: 3, durDen: 4),
          ],
        ),
      ],
    ),
  ],
);

/// 只有空小节（= 整小节休止）的乐谱：拍号改动不会被已有内容卡住，
/// 用来固化「拍号有既有纯函数、可写」。
MusicScore _emptyMeasureScore() => MusicScore(
  title: '空小节练习曲',
  tempo: 96,
  timeSig: const <int>[4, 4],
  keySig: 'C',
  tracks: <MusicTrack>[
    MusicTrack(
      id: 'track_0',
      name: '主旋律',
      instrument: 'piano',
      measures: <MusicMeasure>[MusicMeasure(id: 'm1', events: <MusicEvent>[])],
    ),
  ],
);

// ---------------------------------------------------------------------------
// 可注入 fake 播放面：不构造真 WebView
// ---------------------------------------------------------------------------

class _FakePlayback extends MusicPlaybackController {
  _FakePlayback({this.duration = 2.5});

  @override
  final double duration;

  bool _ready = false;

  @override
  bool get ready => _ready;

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
  Future<void> start() async {
    _ready = true;
    notifyListeners();
  }

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> seek(double seconds) async {}
}

/// 别的「工作台」登记的控制器：用来验证音乐工作台卸载时不会误清。
class _ForeignController extends WorkbenchCheckController {
  @override
  CheckSheet? get sheet => null;
}

// ---------------------------------------------------------------------------
// 宿主/几何 helper
// ---------------------------------------------------------------------------

Widget _host(AppStore? appStore, Widget child) {
  final Widget app = MaterialApp(
    theme: AppTheme.build(dark: true),
    home: Scaffold(body: child),
  );
  if (appStore == null) return app;
  return ChangeNotifierProvider<AppStore>.value(value: appStore, child: app);
}

/// 泵工作台：1440×900（宽屏，左右面板都可停靠）。
Future<void> _pumpWorkspace(
  WidgetTester tester,
  MusicProjectStore musicStore, {
  AppStore? appStore,
}) async {
  tester.view.physicalSize = const Size(1440, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    _host(
      appStore,
      MusicWorkspace(
        store: musicStore,
        // 生产播放面是 WebView；测试一律注入 fake，避免构造真 WebView。
        playbackFactory: (MusicScore score, MusicPlayPlan plan) =>
            _FakePlayback(duration: musicPlaybackDurationSeconds(plan)),
      ),
    ),
  );
  await _settle(tester);
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 50));
}

/// 点左栏某条轨道（选中轨道 = 检查页换成轨道属性表）。
Future<void> _selectTrack(WidgetTester tester, String trackId) async {
  await tester.tap(find.byKey(ValueKey('music-track-$trackId')));
  await _settle(tester);
}

Finder _staffHitFinder() => find.byKey(const ValueKey('music-staff-hit'));

MusicStaffLayout _staffLayoutOf(WidgetTester tester, MusicScore score) =>
    musicStaffLayout(score, width: tester.getSize(_staffHitFinder()).width);

/// 谱面第一个音符符头中心的全局坐标（用来「点中已有音符」）。
Offset _staffPointOnFirstNote(WidgetTester tester, MusicStaffLayout layout) {
  final MusicStaffNote note = layout.rows.first.columns.first.notes.firstWhere(
    (MusicStaffNote candidate) => !candidate.isRest,
  );
  return tester.getTopLeft(_staffHitFinder()) +
      Offset(note.headX + kMusicStaffHeadWidth / 2, note.headY);
}

void main() {
  late Directory temp;
  late MusicProjectStore musicStore;
  late AppStore appStore;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    temp = await Directory.systemTemp.createTemp('nondesign-music-check-');
    musicStore = MusicProjectStore(root: temp);
    appStore = AppStore()
      ..ready = true
      ..view = 'plugin:music';
  });

  tearDown(() async {
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  WorkbenchCheckController controllerOf() {
    final WorkbenchCheckController? controller = appStore.checkController;
    expect(controller, isNotNull, reason: '工作台挂载后应把检查器注册到壳层');
    return controller!;
  }

  File scoreFile() => File('${temp.path}/study/score.json');

  testWidgets('无选中（项目已打开）→ 乐谱级属性表；选中轨道不回退；点「乐谱」条目回到乐谱级', (tester) async {
    await musicStore.save('study', _score());
    await _pumpWorkspace(tester, musicStore, appStore: appStore);
    final WorkbenchCheckController controller = controllerOf();

    // 项目刚打开、没有选中轨道/音符 → 乐谱级属性表。
    final CheckSheet? sheet = controller.sheet;
    expect(sheet, isNotNull);
    expect(sheet!.title, '乐谱「检查器练习曲」');
    expect(sheet.kindLabel, '乐谱');
    expect(sheet.subtitle, '来自 score.json');
    expect(sheet.fields.map((CheckField field) => field.key).toList(), <String>[
      'title',
      'tempo',
      'timeSigBeats',
      'timeSigBeatUnit',
      'keySig',
    ]);
    expect(sheet.field('title')!.value, '检查器练习曲');
    expect(sheet.field('tempo')!.value, 96);
    expect(sheet.field('tempo')!.min, 20);
    expect(sheet.field('tempo')!.max, 300);
    expect(sheet.field('tempo')!.unit, 'BPM');
    expect(sheet.field('timeSigBeats')!.value, 4);
    expect(sheet.field('timeSigBeats')!.min, 1);
    expect(sheet.field('timeSigBeats')!.max, 16);
    expect(sheet.field('timeSigBeatUnit')!.value, '4');
    expect(sheet.field('timeSigBeatUnit')!.options, <String>[
      '2',
      '4',
      '8',
      '16',
    ]);
    expect(sheet.field('keySig')!.value, 'C');
    expect(sheet.field('keySig')!.kind, CheckFieldKind.readOnly);
    expect(
      sheet.field('keySig')!.enabled,
      isFalse,
      reason: '调号没有既有纯函数/可枚举校验器允许值，字段显性只读',
    );
    expect(sheet.field('keySig')!.hint, isNotEmpty);

    // 宽屏 + 壳层在场：内容区旧检查器降级为只读摘要（编辑走右栏检查 tab）。
    expect(find.byKey(const ValueKey('music-inspector')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('music-inspector-readonly-hint')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('music-title-field')))
          .enabled,
      isFalse,
    );
    // 左栏「乐谱」条目在场（乐谱级选中态）。
    expect(find.byKey(const ValueKey('music-score-entry')), findsOneWidget);

    // 选中第二条轨道：检查 tab 换成轨道表，不回退到乐谱级。
    int notifications = 0;
    controller.addListener(() => notifications += 1);
    await _selectTrack(tester, 'track_1');
    expect(notifications, greaterThan(0), reason: '选中变化必须通知检查面板重取');
    final CheckSheet? trackSheet = controller.sheet;
    expect(trackSheet, isNotNull);
    expect(trackSheet!.title, '轨道「低音」');
    expect(trackSheet.kindLabel, '轨道');
    expect(trackSheet.subtitle, '来自 score.json');
    expect(trackSheet.field('instrument')!.value, 'bass');
    expect(trackSheet.field('muted')!.value, isTrue);

    // 轨道选中时乐谱级字段不可写（同一属性不会两处同时生效）。
    final String before = scoreFile().readAsStringSync();
    expect(await controller.update('title', '不该落盘'), isFalse);
    expect(scoreFile().readAsStringSync(), before);
    expect((await musicStore.read('study')).score.title, '检查器练习曲');

    // 点左栏「乐谱」条目 → 回到乐谱级属性表。
    await tester.tap(find.byKey(const ValueKey('music-score-entry')));
    await _settle(tester);
    expect(controller.sheet!.kindLabel, '乐谱');
    expect(controller.sheet!.title, '乐谱「检查器练习曲」');

    await _settle(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('宽屏：内容区检查器只读降级后，右栏检查仍可改标题 → score.json 真的变化', (tester) async {
    await musicStore.save('study', _score());
    await _pumpWorkspace(tester, musicStore, appStore: appStore);
    final WorkbenchCheckController controller = controllerOf();
    expect(controller.sheet!.kindLabel, '乐谱');

    // 内容区旧检查器（宽屏）只读：标题输入框禁用。
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('music-title-field')))
          .enabled,
      isFalse,
      reason: '宽屏下内容区检查器降级只读，主编辑入口是右栏检查 tab',
    );

    final String before = scoreFile().readAsStringSync();
    expect(await controller.update('title', '宽屏新标题'), isTrue);
    expect(scoreFile().readAsStringSync(), isNot(before), reason: '标题必须真的落盘');
    final Map<String, Object?> json =
        jsonDecode(scoreFile().readAsStringSync()) as Map<String, Object?>;
    expect(json['title'], '宽屏新标题');
    final MusicProjectSnapshot reread = await musicStore.read('study');
    expect(reread.score.title, '宽屏新标题');
    expect(reread.validation.verified, isTrue);
    expect(controller.sheet!.title, '乐谱「宽屏新标题」', reason: '成功后属性表刷新');
    expect(controller.sheet!.field('title')!.value, '宽屏新标题');

    // 非法标题（空/超长）→ 拒绝且不再写盘。
    final String after = scoreFile().readAsStringSync();
    expect(await controller.update('title', '   '), isFalse);
    expect(await controller.update('title', 'x' * 81), isFalse);
    expect(scoreFile().readAsStringSync(), after);

    await _settle(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('改速度 → 落盘；非法速度（0 / 999）→ update false 且文件逐字节不变', (tester) async {
    await musicStore.save('study', _score());
    await _pumpWorkspace(tester, musicStore, appStore: appStore);
    final WorkbenchCheckController controller = controllerOf();
    expect(controller.sheet!.kindLabel, '乐谱');
    expect(controller.sheet!.field('tempo')!.value, 96);

    final String before = scoreFile().readAsStringSync();
    expect(await controller.update('tempo', 0), isFalse, reason: '速度 0 越界');
    expect(await controller.update('tempo', 999), isFalse, reason: '速度 999 越界');
    expect(await controller.update('tempo', 19), isFalse);
    expect(await controller.update('tempo', 301), isFalse);
    expect(await controller.update('tempo', 'abc'), isFalse);
    expect(scoreFile().readAsStringSync(), before, reason: '任何非法速度都不写盘');

    expect(await controller.update('tempo', 120), isTrue);
    final Map<String, Object?> json =
        jsonDecode(scoreFile().readAsStringSync()) as Map<String, Object?>;
    expect(json['tempo'], 120);
    final MusicProjectSnapshot reread = await musicStore.read('study');
    expect(reread.score.tempo, 120);
    expect(reread.validation.verified, isTrue);
    expect(controller.sheet!.field('tempo')!.value, 120, reason: '成功后属性表刷新');

    await _settle(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('拍号：既有纯函数可写（空小节乐谱落盘）；非法分母/分子 → false 且文件不变', (tester) async {
    await musicStore.save('study', _emptyMeasureScore());
    await _pumpWorkspace(tester, musicStore, appStore: appStore);
    final WorkbenchCheckController controller = controllerOf();
    expect(controller.sheet!.kindLabel, '乐谱');
    expect(controller.sheet!.field('timeSigBeats')!.value, 4);
    expect(controller.sheet!.field('timeSigBeatUnit')!.value, '4');

    // 分子 4 → 3（空小节不冲突）→ 落盘。
    expect(await controller.update('timeSigBeats', 3), isTrue);
    final Map<String, Object?> first =
        jsonDecode(scoreFile().readAsStringSync()) as Map<String, Object?>;
    expect(first['timeSig'], <Object?>[3, 4]);
    expect((await musicStore.read('study')).score.timeSig, <int>[3, 4]);
    expect(controller.sheet!.field('timeSigBeats')!.value, 3);

    // 分母 4 → 8 → 落盘。
    expect(await controller.update('timeSigBeatUnit', '8'), isTrue);
    final Map<String, Object?> second =
        jsonDecode(scoreFile().readAsStringSync()) as Map<String, Object?>;
    expect(second['timeSig'], <Object?>[3, 8]);
    expect((await musicStore.read('study')).score.timeSig, <int>[3, 8]);
    expect(controller.sheet!.field('timeSigBeatUnit')!.value, '8');

    // 契约外分母 / 越界分子 → 拒绝且文件不变。
    final String before = scoreFile().readAsStringSync();
    expect(await controller.update('timeSigBeatUnit', '5'), isFalse);
    expect(await controller.update('timeSigBeatUnit', 1), isFalse);
    expect(await controller.update('timeSigBeats', 0), isFalse);
    expect(await controller.update('timeSigBeats', 17), isFalse);
    expect(scoreFile().readAsStringSync(), before, reason: '非法拍号不写盘');

    // 调号：没有既有纯函数 → 只读，update 显性拒绝且不写盘。
    expect(await controller.update('keySig', 'G'), isFalse);
    expect(scoreFile().readAsStringSync(), before);

    await _settle(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('拍号改动被已有内容的小节拒绝（time_sig_conflict）→ false 且文件不变', (tester) async {
    await musicStore.save('study', _score());
    await _pumpWorkspace(tester, musicStore, appStore: appStore);
    final WorkbenchCheckController controller = controllerOf();
    final String before = scoreFile().readAsStringSync();

    // 两轨小节都已写满 4/4，改成 3 拍会让已有小节时值对不上 → 显性拒绝。
    expect(await controller.update('timeSigBeats', 3), isFalse);
    expect(scoreFile().readAsStringSync(), before, reason: '冲突不写盘');
    await _settle(tester);
    expect(find.textContaining('对不上'), findsWidgets, reason: '失败原因要显性显示');
    expect(tester.takeException(), isNull);
  });

  testWidgets('选中轨道 → 轨道属性表；改音量/静音/名称 → update true 且落盘', (tester) async {
    await musicStore.save('study', _score());
    await _pumpWorkspace(tester, musicStore, appStore: appStore);
    final WorkbenchCheckController controller = controllerOf();
    await _selectTrack(tester, 'track_0');

    final CheckSheet? sheet = controller.sheet;
    expect(sheet, isNotNull);
    expect(sheet!.title, '轨道「主旋律」');
    expect(sheet.kindLabel, '轨道');
    expect(sheet.subtitle, '来自 score.json');
    expect(sheet.fields.map((CheckField field) => field.key).toList(), <String>[
      'name',
      'instrument',
      'volume',
      'muted',
      'clef',
    ]);
    expect(sheet.field('name')!.value, '主旋律');
    expect(sheet.field('instrument')!.value, 'piano');
    expect(sheet.field('instrument')!.options, contains('piano'));
    expect(sheet.field('volume')!.value, 0.8);
    expect(sheet.field('volume')!.min, 0);
    expect(sheet.field('volume')!.max, 1);
    expect(sheet.field('muted')!.value, isFalse);
    expect(sheet.field('clef')!.value, 'treble');
    expect(
      sheet.field('clef')!.enabled,
      isFalse,
      reason: '谱号没有既有纯函数/补丁路径，字段显性只读',
    );

    final String before = scoreFile().readAsStringSync();

    // 音量（既有纯函数 editTrackVolume）。
    expect(await controller.update('volume', 0.42), isTrue);
    expect(scoreFile().readAsStringSync(), isNot(before));
    final Map<String, Object?> volumeJson =
        jsonDecode(scoreFile().readAsStringSync()) as Map<String, Object?>;
    final List<Object?> tracks = volumeJson['tracks']! as List<Object?>;
    expect(
      (tracks.first! as Map<String, Object?>)['volume'],
      closeTo(0.42, 1e-9),
    );
    expect(
      (await musicStore.read('study')).score.tracks.first.volume,
      closeTo(0.42, 1e-9),
    );
    expect(
      controller.sheet!.field('volume')!.value,
      closeTo(0.42, 1e-9),
      reason: '成功后属性表刷新',
    );

    // 静音（既有纯函数 editTrackMuted）。
    expect(await controller.update('muted', true), isTrue);
    expect((await musicStore.read('study')).score.tracks.first.muted, isTrue);
    expect(controller.sheet!.field('muted')!.value, isTrue);

    // 名称（music_edit 没有纯函数，走既有确定性补丁 music_patch）。
    expect(await controller.update('name', '主题旋律'), isTrue);
    expect((await musicStore.read('study')).score.tracks.first.name, '主题旋律');
    expect(controller.sheet!.title, '轨道「主题旋律」');

    await _settle(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('非法轨道值/缺失能力 → update false 且文件不变', (tester) async {
    await musicStore.save('study', _score());
    await _pumpWorkspace(tester, musicStore, appStore: appStore);
    final WorkbenchCheckController controller = controllerOf();
    await _selectTrack(tester, 'track_0');
    final String before = scoreFile().readAsStringSync();

    expect(await controller.update('volume', 1.5), isFalse, reason: '音量 >1');
    expect(await controller.update('volume', -0.1), isFalse, reason: '音量 <0');
    expect(
      await controller.update('instrument', 'flute'),
      isFalse,
      reason: '契约外乐器',
    );
    expect(await controller.update('name', '   '), isFalse, reason: '空轨道名');
    expect(
      await controller.update('clef', 'bass'),
      isFalse,
      reason: '谱号：core/music 没有既有纯函数/补丁路径（缺失能力显性拒绝）',
    );

    expect(scoreFile().readAsStringSync(), before, reason: '任何失败都不写盘');
    await _settle(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('选中音符 → 音符属性表；改音高/八度 → 落盘；时值/附点显性拒绝', (tester) async {
    await musicStore.save('study', _score());
    await _pumpWorkspace(tester, musicStore, appStore: appStore);
    final WorkbenchCheckController controller = controllerOf();
    // 未选中任何轨道/音符时是乐谱级；点谱面音符后才是音符表。
    expect(controller.sheet!.kindLabel, '乐谱');

    final MusicStaffLayout layout = _staffLayoutOf(tester, _score());
    await tester.tapAt(_staffPointOnFirstNote(tester, layout));
    await _settle(tester);

    final CheckSheet? noteSheet = controller.sheet;
    expect(noteSheet, isNotNull);
    expect(noteSheet!.title, '音符 · 第 1 拍');
    expect(noteSheet.kindLabel, '音符');
    expect(
      noteSheet.fields.map((CheckField field) => field.key).toList(),
      <String>['step', 'octave', 'alter', 'dur', 'dot', 'isRest'],
    );
    expect(noteSheet.field('step')!.value, 'C');
    expect(noteSheet.field('step')!.options, <String>[
      'C',
      'D',
      'E',
      'F',
      'G',
      'A',
      'B',
    ]);
    expect(noteSheet.field('octave')!.value, 5);
    expect(noteSheet.field('octave')!.min, 1);
    expect(noteSheet.field('octave')!.max, 8);
    expect(noteSheet.field('alter')!.value, '0');
    expect(noteSheet.field('alter')!.options, <String>['-1', '0', '1']);
    expect(noteSheet.field('dur')!.value, '全音符');
    expect(noteSheet.field('dot')!.value, isFalse);
    expect(noteSheet.field('isRest')!.value, isFalse);

    final String before = scoreFile().readAsStringSync();
    expect(await controller.update('step', 'E'), isTrue);
    expect(scoreFile().readAsStringSync(), isNot(before));
    final MusicProjectSnapshot reread = await musicStore.read('study');
    final MusicEvent event =
        reread.score.tracks.first.measures.first.events.first;
    expect(event.step, 'E');
    expect(event.id, 'n1', reason: '补丁替换事件保留原 id（不破坏关系引用）');
    expect(reread.validation.verified, isTrue);
    expect(controller.sheet!.field('step')!.value, 'E', reason: '成功后属性表刷新');

    expect(await controller.update('octave', 4), isTrue);
    expect(
      (await musicStore.read('study'))
          .score
          .tracks
          .first
          .measures
          .first
          .events
          .first
          .octave,
      4,
    );

    // 时值/附点：没有能同时保持「小节时值和 == 拍号」的既有纯函数 → 拒绝且不写盘。
    final String after = scoreFile().readAsStringSync();
    expect(await controller.update('dur', '四分音符'), isFalse);
    expect(await controller.update('dot', true), isFalse);
    expect(scoreFile().readAsStringSync(), after);

    await _settle(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('坏项目 / 没有项目 → sheet 为 null（检查器不伪造选中对象）', (tester) async {
    Directory('${temp.path}/broken').createSync(recursive: true);
    File('${temp.path}/broken/score.json').writeAsStringSync('{not json');
    await _pumpWorkspace(tester, musicStore, appStore: appStore);
    final WorkbenchCheckController controller = controllerOf();
    expect(controller.sheet, isNull);
    expect(find.textContaining('乐谱还没有通过校验'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('空项目库：无选中元素 → sheet 为 null', (tester) async {
    await _pumpWorkspace(tester, musicStore, appStore: appStore);
    final WorkbenchCheckController controller = controllerOf();
    expect(controller.sheet, isNull);
    expect(find.text('还没有音乐项目'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('没有壳层 AppStore 的独立工作台：不注册、内容区检查器保持可编辑', (tester) async {
    await musicStore.save('study', _score());
    await _pumpWorkspace(tester, musicStore);
    // 没有 provider：检查控制器没有壳层可挂，内容区这份就是唯一入口。
    expect(find.byKey(const ValueKey('music-inspector')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('music-inspector-readonly-hint')),
      findsNothing,
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('music-title-field')))
          .enabled,
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('卸载只清自己的注册，别的工作台控制器不被误清', (tester) async {
    await musicStore.save('study', _score());
    await _pumpWorkspace(tester, musicStore, appStore: appStore);
    expect(appStore.checkController, isNotNull);

    // 别的控制器接手（模拟切换工作台时新实例已登记）。
    final WorkbenchCheckController other = _ForeignController();
    appStore.setCheckController(other);
    expect(appStore.checkController, same(other));

    // 音乐工作台卸载：不能把别人的控制器清掉。
    await tester.pumpWidget(const SizedBox.shrink());
    await _settle(tester);
    expect(appStore.checkController, same(other));

    // 再挂回音乐工作台 → 登记自己的；卸载后清成 null。
    await _pumpWorkspace(tester, musicStore, appStore: appStore);
    expect(appStore.checkController, isNotNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await _settle(tester);
    expect(appStore.checkController, isNull);
    expect(tester.takeException(), isNull);
  });
}
