// 音乐工作台「生成文档」接线测试。
//
// 覆盖四栏目文档栏目的可行动作：按项目事实源确定性生成 `docs.md`
// （`core/workbench_docs.dart`），成功后立即刷新文档栏；无项目/坏项目不给入口。
// 全部用真实临时目录 + Fake 播放面，不构造真 WebView。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nondesign/core/music/music_compile.dart';
import 'package:nondesign/core/music/music_project.dart';
import 'package:nondesign/core/music/music_score.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/widgets/music_playback_surface.dart';
import 'package:nondesign/widgets/music_workspace.dart';

/// 合法乐谱：一个轨道 / 一个小节 / 全音符（校验通过，有播放计划）。
MusicScore _score({String title = '练习曲'}) => MusicScore(
  title: title,
  tempo: 96,
  timeSig: const <int>[4, 4],
  keySig: 'C',
  tracks: <MusicTrack>[
    MusicTrack(
      id: 'track_0',
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

/// 读盘桩：让工作台拿到「校验未通过」的 snapshot（真实项目目录 + 注入校验结果）。
///
/// 解析器对任何 blocking 问题都会把 score 置空（读失败），所以「能读出来但未
/// 通过校验」只能按既有测试同法注入（见 `music_workspace_test.dart` 的
/// `_StaleSnapshotStore`）。注入后文档生成照常可用，只是把校验状态写进文档。
class _UnverifiedReadStore extends MusicProjectStore {
  _UnverifiedReadStore({required Directory root}) : super(root: root);

  @override
  Future<MusicProjectSnapshot> read(String name) async {
    final MusicProjectSnapshot base = await super.read(name);
    return MusicProjectSnapshot(
      name: base.name,
      score: base.score,
      raw: base.raw,
      validation: const MusicValidation(
        issues: <MusicIssue>[MusicIssue('/tempo', 'score_invalid', '速度不在允许范围')],
        verified: false,
      ),
      playPlan: base.playPlan,
      dir: base.dir,
    );
  }
}

/// Fake 播放面：工作台有播放计划时必须构造控制器；测试不构造真 WebView。
class _FakePlayback extends MusicPlaybackController {
  @override
  double get duration => 2.5;

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

Widget _app(Widget child) => MaterialApp(
  theme: AppTheme.build(dark: true),
  home: Scaffold(body: child),
);

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _pumpWorkspace(
  WidgetTester tester,
  MusicProjectStore store,
) async {
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
}

/// 切到「文档」栏目（四栏目条的稳定 Key 见 `WorkbenchColumnLabel.tabKey`）。
Future<void> _openDocsColumn(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('workbench-column-docs')));
  await _settle(tester);
}

/// 点一次文档动作按钮（生成/重新生成），并等写盘 → 重读这条异步链走完。
Future<void> _tapDocsAction(WidgetTester tester, String key) async {
  final Finder finder = find.byKey(ValueKey<String>(key));
  expect(finder, findsOneWidget, reason: '文档动作按钮 $key 必须出现');
  await tester.tap(finder);
  await _settle(tester);
  await _settle(tester);
}

File _docsFile(Directory root, String name) =>
    File('${root.path}/$name/docs.md');

void main() {
  late Directory temp;
  late MusicProjectStore store;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('nondesign-music-docs-');
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

  testWidgets('没有音乐项目：文档栏显示空态，不出现生成按钮', (tester) async {
    await viewport(tester, const Size(1440, 900));
    await _pumpWorkspace(tester, store);
    await _openDocsColumn(tester);

    expect(find.byKey(const ValueKey('workbench-docs-empty')), findsOneWidget);
    expect(find.text('还没有文档'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('workbench-docs-generate')),
      findsNothing,
      reason: '无项目（无事实源）时不给生成入口',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('点生成：写出 docs.md（含「## 轨道表」）并立即在文档栏显示正文', (tester) async {
    await viewport(tester, const Size(1440, 900));
    await store.save('study', _score());
    await _pumpWorkspace(tester, store);
    await _openDocsColumn(tester);

    // 生成前：可行动空态 + 生成按钮。
    expect(find.byKey(const ValueKey('workbench-docs-empty')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('workbench-docs-generate')),
      findsOneWidget,
    );

    await _tapDocsAction(tester, 'workbench-docs-generate');

    final File docs = _docsFile(temp, 'study');
    expect(docs.existsSync(), isTrue, reason: '生成后 docs.md 必须存在');
    final String text = docs.readAsStringSync();
    expect(text, startsWith('本文档由项目事实源自动生成'));
    expect(text, contains('# 练习曲'));
    expect(text, contains('## 项目概览'));
    expect(text, contains('速度：每分钟 96 拍'));
    expect(text, contains('拍号：4/4'));
    expect(text, contains('调号：C'));
    expect(text, contains('## 轨道表'));
    expect(
      text,
      contains('| 1 | 主旋律 | 钢琴 | 100% | 1 |'),
      reason: '轨道表要按 name/instrument/volume/measures 组装',
    );
    expect(text, contains('- 状态：校验通过'));

    // 文档栏立即显示正文；空态消失；动作换成「重新生成」。
    expect(find.byKey(const ValueKey('workbench-docs-body')), findsOneWidget);
    expect(find.byKey(const ValueKey('workbench-docs-empty')), findsNothing);
    expect(
      find.byKey(const ValueKey('workbench-docs-regenerate')),
      findsOneWidget,
    );
    expect(find.text('轨道表'), findsOneWidget);
    expect(find.textContaining('本文档由项目事实源自动生成'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('重新生成：两次生成 docs.md 字节相同（确定性）且内容仍然正确', (tester) async {
    await viewport(tester, const Size(1440, 900));
    await store.save('study', _score());
    await _pumpWorkspace(tester, store);
    await _openDocsColumn(tester);

    await _tapDocsAction(tester, 'workbench-docs-generate');
    final File docs = _docsFile(temp, 'study');
    final List<int> first = docs.readAsBytesSync();

    await _tapDocsAction(tester, 'workbench-docs-regenerate');
    final List<int> second = docs.readAsBytesSync();
    expect(second, orderedEquals(first), reason: '同一份事实源两次生成必须字节相同');
    expect(docs.readAsStringSync(), contains('## 轨道表'));
    expect(
      find.byKey(const ValueKey('workbench-docs-regenerate')),
      findsOneWidget,
      reason: '重新生成后入口保持可用',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('坏项目（读不出乐谱）：文档栏空态，不出现生成按钮', (tester) async {
    await viewport(tester, const Size(1440, 900));
    // 坏项目：目录列不出来乐谱 → 读失败 → 没有快照 = 没有事实源。
    final Directory bad = Directory('${temp.path}/bad');
    bad.createSync(recursive: true);
    File('${bad.path}/score.json').writeAsStringSync('{ 这不是 JSON');

    await _pumpWorkspace(tester, store);
    await _openDocsColumn(tester);

    expect(find.byKey(const ValueKey('workbench-docs-empty')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('workbench-docs-generate')),
      findsNothing,
      reason: '坏项目不提供生成入口',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('校验未通过的项目仍可生成，文档如实写「校验未通过（N 处问题）」', (tester) async {
    await viewport(tester, const Size(1440, 900));
    await store.save('stale', _score(title: '待修谱'));
    final MusicProjectStore unverified = _UnverifiedReadStore(root: temp);
    await _pumpWorkspace(tester, unverified);
    await _openDocsColumn(tester);

    expect(
      find.byKey(const ValueKey('workbench-docs-generate')),
      findsOneWidget,
      reason: '能读到乐谱快照的项目就提供入口（校验状态写进文档，不由此禁用）',
    );

    await _tapDocsAction(tester, 'workbench-docs-generate');

    final File docs = _docsFile(temp, 'stale');
    expect(docs.existsSync(), isTrue);
    final String text = docs.readAsStringSync();
    expect(text, contains('# 待修谱'));
    expect(text, contains('## 轨道表'));
    expect(text, contains('- 状态：校验未通过（1 处问题）'));

    expect(find.byKey(const ValueKey('workbench-docs-body')), findsOneWidget);
    expect(find.textContaining('校验未通过（1 处问题）'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('已有旧简介（brief.md）：生成 docs.md 后文档栏优先显示生成内容', (tester) async {
    await viewport(tester, const Size(1440, 900));
    await store.save('study', _score());
    File('${temp.path}/study/brief.md').writeAsStringSync('旧的简介：先看这里。\n');

    await _pumpWorkspace(tester, store);
    await _openDocsColumn(tester);

    // 旧简介存在 = 已有文档 → 显示正文 + 重新生成入口（不是空态）。
    expect(find.byKey(const ValueKey('workbench-docs-body')), findsOneWidget);
    expect(find.textContaining('旧的简介'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('workbench-docs-regenerate')),
      findsOneWidget,
    );

    await _tapDocsAction(tester, 'workbench-docs-regenerate');

    expect(_docsFile(temp, 'study').existsSync(), isTrue);
    expect(find.byKey(const ValueKey('workbench-docs-body')), findsOneWidget);
    expect(
      find.textContaining('旧的简介'),
      findsNothing,
      reason: 'docs.md 优先于 brief.md，生成后显示生成内容',
    );
    expect(find.text('轨道表'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
