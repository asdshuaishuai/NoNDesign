// 音乐模块 Agent 工具族锚点测试（task-5，契约见 docs/music-contract.md §7）。
//
// 覆盖：
//  * AgentWorkspaceServices 四件套（music_list / music_read / music_inspect /
//    music_create）的 LocalWorkspaceServices 实现，真实落盘到临时
//    MusicProjectStore（绝不写用户文档目录）；
//  * 「写谱后先过校验器再交付」：坏谱不落盘、失败码 `music_` 前缀 + 人话；
//  * 结果整形：music_read 超长 JSON 截断并标注，music_inspect 只回摘要；
//  * 脚本化 genkit 模型跑完整 create → list → inspect 工具循环；
//  * 工作区提示词：music 工作区说明 + 校验器纪律；
//  * 工作区产物认领：成功 music_create 记进 store 并 notify（失败不认领），
//    以及 store 的 `plugin:music` → `music` hint 映射。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:genkit/genkit.dart' show Part;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nondesign/core/app_paths.dart';
import 'package:nondesign/core/dart_agent.dart';
import 'package:nondesign/core/music/music_project.dart';
import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/project_service.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/toast_service.dart';

import 'helpers/genkit_test_model.dart';

/// 一份合法 score.json v1：4/4 拍，每个小节一个全音符（时值总和 = 1）。
///
/// 全音符 = 3840*4 = 15360 tick；tempo 120 时一小节 2 秒。
Map<String, dynamic> _score({String title = '晨光', int measures = 1}) =>
    <String, dynamic>{
      'schemaVersion': 1,
      'title': title,
      'tempo': 120,
      'timeSig': <int>[4, 4],
      'keySig': 'C',
      'tracks': <dynamic>[
        <String, dynamic>{
          'id': 'melody',
          'name': '旋律',
          'instrument': 'piano',
          'volume': 0.8,
          'muted': false,
          'clef': 'treble',
          'measures': <dynamic>[
            for (var i = 0; i < measures; i++)
              <String, dynamic>{
                'id': 'm${i + 1}',
                'events': <dynamic>[
                  <String, dynamic>{
                    'id': 'e${i + 1}',
                    'type': 'note',
                    'dur': <String, dynamic>{'num': 1, 'den': 1},
                    'pitch': <String, dynamic>{
                      'step': 'C',
                      'alter': 0,
                      'octave': 4,
                    },
                  },
                ],
              },
          ],
        },
      ],
    };

/// 4/4 小节只写半拍 → 小节时值总和 != 拍号（校验器硬门必拒）。
Map<String, dynamic> _invalidScore() {
  final score = _score();
  final track = (score['tracks'] as List).single as Map<String, dynamic>;
  final measure = (track['measures'] as List).single as Map<String, dynamic>;
  measure['events'] = <dynamic>[
    <String, dynamic>{
      'id': 'e1',
      'type': 'note',
      'dur': <String, dynamic>{'num': 1, 'den': 2},
      'pitch': <String, dynamic>{'step': 'C', 'alter': 0, 'octave': 4},
    },
  ];
  return score;
}

LocalWorkspaceServices _services(Directory root) => LocalWorkspaceServices(
  model: 'scripted-model',
  baseUrl: 'https://example.invalid/v1',
  apiKey: 'k',
  musicProjects: MusicProjectStore(root: root),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LocalWorkspaceServices 音乐项目库（真实落盘）', () {
    late Directory root;
    late LocalWorkspaceServices services;

    setUp(() {
      root = Directory.systemTemp.createTempSync('music-agent-');
      services = _services(root);
    });

    tearDown(() {
      try {
        root.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('create → list → read → inspect 全链一致（先校验后落盘）', () async {
      final created = await services.musicCreate(name: 'dawn', score: _score());
      expect(created['ok'], isTrue);
      expect(created['project'], 'dawn');
      expect(created['title'], '晨光');
      expect(created['tracks'], 1);
      expect(created['measures'], 1);
      expect(created['totalTicks'], 15360);
      expect((created['seconds'] as num).toDouble(), 2.0);
      expect(created['verified'], isTrue);
      expect(created['issues'], 0);
      // 真实落盘：score.json 是唯一事实源（工作台关掉 run 后还能读）。
      expect(File('${root.path}/dawn/score.json').existsSync(), isTrue);

      final listed = await services.musicList();
      expect(listed['ok'], isTrue);
      expect(listed['count'], 1);
      final project = (listed['projects'] as List).single as Map;
      expect(project['name'], 'dawn');
      expect(project['title'], '晨光');
      expect(project['tracks'], 1);
      expect(project['measures'], 1);
      expect(project['totalTicks'], 15360);
      expect((project['seconds'] as num).toDouble(), 2.0);
      expect(project['verified'], isTrue);
      expect(project['corrupt'], isFalse);

      final read = await services.musicRead('dawn');
      expect(read['ok'], isTrue);
      expect(read['truncated'], isFalse);
      expect(read['verified'], isTrue);
      expect(read['issues'], 0);
      final text = read['scoreJson'] as String;
      expect(read['chars'], text.length);
      expect(text, contains('晨光'));
      expect(text, contains('"schemaVersion": 1'));
      expect(text, contains('"instrument": "piano"'));
      expect(read.containsKey('score'), isFalse, reason: '读谱只回整形后的 JSON 文本');

      final inspect = await services.musicInspect('dawn');
      expect(inspect['ok'], isTrue);
      expect(inspect['name'], 'dawn');
      expect(inspect['title'], '晨光');
      expect(inspect['tracks'], 1);
      expect(inspect['trackNames'], <dynamic>['旋律']);
      expect(inspect['measures'], 1);
      expect(inspect['totalTicks'], 15360);
      expect((inspect['seconds'] as num).toDouble(), 2.0);
      expect(inspect['compiled'], isTrue);
      expect(inspect['verified'], isTrue);
      expect(inspect['issues'], 0);
      // 摘要面：绝不回全谱。
      expect(inspect.containsKey('score'), isFalse);
      expect(inspect.containsKey('scoreJson'), isFalse);
    });

    test('校验失败不落盘：music_score_invalid + issue 指针', () async {
      final rejected = await services.musicCreate(
        name: 'broken',
        score: _invalidScore(),
      );
      expect(rejected['ok'], isFalse);
      expect(rejected['error'], 'music_score_invalid');
      expect(rejected['message'], contains('乐谱还没有通过校验'));
      expect(rejected['detail'], contains('/tracks/0/measures/0/events'));
      final issues = rejected['issues'] as List;
      expect(issues, isNotEmpty);
      expect((issues.single as Map)['code'], 'score_invalid');
      // 硬门在前：坏谱不写半成品目录。
      expect(Directory('${root.path}/broken').existsSync(), isFalse);
      expect((await services.musicList())['count'], 0);
    });

    test('同名 / 非法名 / 不存在：稳定 music_ 码 + 人话', () async {
      final first = await services.musicCreate(name: 'dawn', score: _score());
      expect(first['ok'], isTrue);

      final duplicate = await services.musicCreate(
        name: 'dawn',
        score: _score(),
      );
      expect(duplicate['ok'], isFalse);
      expect(duplicate['error'], 'music_project_exists');
      expect(duplicate['message'], contains('同名音乐项目'));

      final badName = await services.musicCreate(name: '有 空格', score: _score());
      expect(badName['ok'], isFalse);
      expect(badName['error'], 'music_invalid_name');
      expect(badName['message'], contains('音乐项目名只能用字母'));

      final missingRead = await services.musicRead('ghost');
      expect(missingRead['ok'], isFalse);
      expect(missingRead['error'], 'music_no_project');
      expect(missingRead['message'], '没有找到这个音乐项目');

      final missingInspect = await services.musicInspect('ghost');
      expect(missingInspect['ok'], isFalse);
      expect(missingInspect['error'], 'music_no_project');
      // 失败码必须有人话（不做「点了没反应」的静默）。
      expect(toolFailureMessage('music_no_project'), '没有找到这个音乐项目');
    });

    test('music_read 超长截断（>4000 chars）并标注；inspect 仍只回摘要', () async {
      const measures = 40;
      final created = await services.musicCreate(
        name: 'big',
        score: _score(title: '长曲', measures: measures),
      );
      expect(created['ok'], isTrue);
      expect(created['totalTicks'], 40 * 15360);
      expect((created['seconds'] as num).toDouble(), 80.0);

      final read = await services.musicRead('big');
      expect(read['ok'], isTrue);
      expect(read['truncated'], isTrue);
      expect(
        (read['chars'] as int),
        greaterThan(LocalWorkspaceServices.musicReadJsonLimit),
      );
      final capped = read['scoreJson'] as String;
      expect(capped, endsWith('\n…[truncated]'));
      expect(
        capped.length,
        LocalWorkspaceServices.musicReadJsonLimit + '\n…[truncated]'.length,
        reason: 'music_read 必须是有上限的整形结果，不是整谱爆量',
      );

      final inspect = await services.musicInspect('big');
      expect(inspect['ok'], isTrue);
      expect(inspect['measures'], measures);
      expect(inspect['totalTicks'], 40 * 15360);
      expect((inspect['seconds'] as num).toDouble(), 80.0);
      expect(inspect.containsKey('scoreJson'), isFalse);
      expect(inspect.containsKey('score'), isFalse);
    });
  });

  group('脚本化工具循环（create → list → inspect）', () {
    late Directory root;
    late LocalWorkspaceServices services;

    setUp(() {
      root = Directory.systemTemp.createTempSync('music-agent-loop-');
      services = _services(root);
    });

    tearDown(() {
      try {
        root.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('workspaceHint=music 时四件套真执行（不再 unknown tool）', () async {
      final events = <Map<String, dynamic>>[];
      final model = ScriptedAgentModel(<List<Part>>[
        <Part>[
          scriptToolCall(
            toolName: 'music_create',
            input: <String, dynamic>{'name': 'dawn', 'score': _score()},
          ),
        ],
        <Part>[
          scriptToolCall(toolName: 'music_list', input: <String, dynamic>{}),
        ],
        <Part>[
          scriptToolCall(
            toolName: 'music_inspect',
            input: <String, dynamic>{'name': 'dawn'},
          ),
        ],
        <Part>[
          scriptToolCall(
            toolName: 'finish',
            input: <String, dynamic>{'summary': '乐谱已创建并通过校验'},
          ),
        ],
      ]);
      final result = await runDartAgent(
        request: const DartAgentRequest(
          mode: 'workspace',
          instruction: '写一段 4/4 的简单旋律',
          mbt: '',
          model: 'scripted-model',
          baseUrl: 'https://example.invalid/v1',
          apiKey: 'k',
          workspaceHint: 'music',
        ),
        modelOverride: model.model,
        workspace: services,
        onEvent: events.add,
      );

      expect(result.ok, isTrue);
      expect(result.stopReason, 'done');
      expect(
        result.remoteCalls,
        greaterThanOrEqualTo(1),
        reason: '成功的 music_create 是真实交付，不能被当成 text_only',
      );

      // 工具面收窄：只看见 music_*，其他模块前缀不可见。
      final toolNames =
          model.calls.first.tools?.map((t) => t.name).toSet() ?? <String>{};
      expect(
        toolNames,
        containsAll(<String>[
          'music_list',
          'music_read',
          'music_inspect',
          'music_create',
        ]),
      );
      expect(
        toolNames.where(
          (n) =>
              n.startsWith('three_') ||
              n.startsWith('video_') ||
              n.startsWith('hotapp_') ||
              n.startsWith('nonapp_'),
        ),
        isEmpty,
      );

      // 事件面：每一件都有 tool_start/tool_end，且成功。
      for (final tool in <String>[
        'music_create',
        'music_list',
        'music_inspect',
      ]) {
        expect(
          events.where((e) => e['type'] == 'tool_start' && e['tool'] == tool),
          hasLength(1),
          reason: tool,
        );
        final end = events.firstWhere(
          (e) => e['type'] == 'tool_end' && e['tool'] == tool,
          orElse: () => <String, dynamic>{},
        );
        expect(end['ok'], isTrue, reason: tool);
        expect((end['preview'] as String).isNotEmpty, isTrue, reason: tool);
      }

      // 落盘真值：run 结束后临时库仍能读回同一份乐谱。
      final stored = await MusicProjectStore(root: root).read('dawn');
      expect(stored.score.title, '晨光');
      expect(stored.score.tracks, hasLength(1));
      expect(stored.validation.verified, isTrue);
    });

    test('workspace 提示词：music 工作区说明 + 校验器纪律，且不列其他工作台工具', () {
      final instructions = composeDartInstructions(
        mode: 'workspace',
        projectMap: '',
        designSpec: const <String, dynamic>{},
        docs: const <String, dynamic>{},
        templates: const <dynamic>[],
        components: const <dynamic>[],
        hasWorkspaceTools: true,
        workspaceHint: 'music',
      );
      expect(instructions, contains('## TARGET WORKSPACE'));
      expect(instructions, contains('mode: music'));
      expect(instructions, contains('music_list'));
      expect(instructions, contains('music_read'));
      expect(instructions, contains('music_inspect'));
      expect(instructions, contains('music_create'));
      expect(instructions, contains('写谱后先过校验器再交付'));
      expect(instructions, isNot(contains('video_list')));
      expect(instructions, isNot(contains('three_list')));
      expect(instructions, isNot(contains('hotapp_list')));
    });
  });

  group('工作区产物认领 + 视图映射（store）', () {
    late Directory temp;
    late AppStore store;
    var notifies = 0;

    setUp(() {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      temp = Directory.systemTemp.createTempSync('music-adopt-');
      AppPaths.projectsRootOverride = temp;
      store = AppStore(
        projects: ProjectService(
          root: () async => Directory('${temp.path}/projects'),
        ),
        toasts: ToastService(autoDismiss: false),
      );
      store.recoveryDir = '${temp.path}/recovery';
      store.settingsMirrorDir = '${temp.path}/settings';
      notifies = 0;
      store.addListener(() => notifies++);
    });

    tearDown(() {
      AppPaths.projectsRootOverride = null;
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });

    Future<void> start(String tool, Map<String, dynamic> args) =>
        store.debugHandleAgentEvent(<String, dynamic>{
          'type': 'tool_start',
          'tool': tool,
          'args': args,
        });

    Future<void> end(String tool, {bool ok = true}) =>
        store.debugHandleAgentEvent(<String, dynamic>{
          'type': 'tool_end',
          'tool': tool,
          'ok': ok,
        });

    test('视图 → workspaceHint：plugin:music 映射到 music', () {
      expect(AppStore.workspaceHintForView('plugin:music'), 'music');
      expect(AppStore.workspaceHintForView('plugin:three'), workspaceModeThree);
      expect(AppStore.workspaceHintForView('plugin:video'), workspaceModeVideo);
      expect(
        AppStore.workspaceHintForView('plugin:hotapp'),
        workspaceModeHotapp,
      );
      expect(AppStore.workspaceHintForView('design'), '');
      expect(AppStore.workspaceHintForView('home'), '');
    });

    test('music_create 成功 → 认领 + notify（不再是「工作台里没有东西」）', () async {
      await start('music_create', <String, dynamic>{
        'name': 'dawn',
        'score': <String, dynamic>{'schemaVersion': 1},
      });
      await end('music_create');
      expect(store.musicProjectName, 'dawn');
      expect(notifies, greaterThan(0), reason: '工作台靠 notifyListeners 才能刷新');
    });

    test('music_create 失败 → 不认领（失败的项目不存在）', () async {
      await start('music_create', <String, dynamic>{
        'name': 'ghost',
        'score': <String, dynamic>{},
      });
      await end('music_create', ok: false);
      expect(store.musicProjectName, isEmpty);
    });

    test('music_inspect 不是产出工具 → 不抢当前音乐项目', () async {
      await start('music_inspect', <String, dynamic>{'name': 'dawn'});
      await end('music_inspect');
      expect(store.musicProjectName, isEmpty);
    });
  });
}
