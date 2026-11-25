// 音乐确定性补丁工具（music_patch）接线锚点（契约见 docs/music-contract.md §7）。
//
// 覆盖：
//  * LocalWorkspaceServices.musicPatch 的真实链路：读 store → 纯函数补丁 →
//    改后校验 → 原子落盘（临时 MusicProjectStore，绝不写用户文档目录）；
//  * 失败显性信封 `{ok, error, message, detail}`：`music_patch_` 码 + 人话，
//    非法路径/越界/坏值/改后校验失败都不写盘；
//  * 脚本化 genkit 模型跑完整 patch → inspect 工具循环（workspaceHint=music 收窄），
//    music_patch 成功计入交付水位（不被误判 text_only）；
//  * 工作区提示词含 music_patch 与「确定性补丁，改后自动校验」纪律。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:genkit/genkit.dart' show Part;

import 'package:nondesign/core/dart_agent.dart';
import 'package:nondesign/core/music/music_project.dart';
import 'package:nondesign/core/music/music_score.dart';

import 'helpers/genkit_test_model.dart';

/// 一份合法 score.json v1（4/4）：空小节（整小节休止）+ 全音符小节。
Map<String, dynamic> _score({
  String title = '晨光',
  int tempo = 120,
}) => <String, dynamic>{
  'schemaVersion': 1,
  'title': title,
  'tempo': tempo,
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
        <String, dynamic>{'id': 'm0'},
        <String, dynamic>{
          'id': 'm1',
          'events': <dynamic>[
            <String, dynamic>{
              'id': 'e1',
              'type': 'note',
              'dur': <String, dynamic>{'num': 1, 'den': 1},
              'pitch': <String, dynamic>{'step': 'C', 'alter': 0, 'octave': 4},
            },
          ],
        },
      ],
    },
  ],
};

Map<String, dynamic> _op(String op, String path, [Object? value]) =>
    op == 'remove'
    ? <String, dynamic>{'op': op, 'path': path}
    : <String, dynamic>{'op': op, 'path': path, 'value': value};

LocalWorkspaceServices _services(Directory root) => LocalWorkspaceServices(
  model: 'scripted-model',
  baseUrl: 'https://example.invalid/v1',
  apiKey: 'k',
  musicProjects: MusicProjectStore(root: root),
);

DartAgentRequest _workspaceRequest() => const DartAgentRequest(
  mode: 'workspace',
  instruction: '把乐谱标题改成暮色、速度改成 90',
  mbt: '',
  model: 'scripted-model',
  baseUrl: 'https://example.invalid/v1',
  apiKey: 'k',
  workspaceHint: 'music',
);

String _scoreFile(Directory root) => '${root.path}/dawn/score.json';

/// 落盘一份合法乐谱作为补丁目标（临时根，不碰用户文档目录）。
Future<void> _seed(Directory root) async {
  final MusicScore? score = parseMusicScore(_score()).score;
  expect(score, isNotNull, reason: 'fixture 必须是合法 score.json v1');
  await MusicProjectStore(root: root).save('dawn', score!);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LocalWorkspaceServices.musicPatch（真实落盘）', () {
    late Directory root;
    late LocalWorkspaceServices services;

    setUp(() {
      root = Directory.systemTemp.createTempSync('music-patch-');
      services = _services(root);
    });

    tearDown(() {
      try {
        root.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('patch → inspect：改动落盘，摘要是新真值（verified 如实）', () async {
      await _seed(root);
      final patched = await services.musicPatch(
        name: 'dawn',
        ops: <Map<String, dynamic>>[
          _op('replace', '/title', '暮色'),
          _op('replace', '/tempo', 90),
          _op('replace', '/tracks/0/volume', 0.5),
        ],
      );
      expect(patched['ok'], isTrue);
      expect(patched['project'], 'dawn');
      expect(patched['applied'], 3);
      expect(patched['verified'], isTrue);
      expect(patched['issues'], 0);
      expect(patched['title'], '暮色');
      expect(patched['tracks'], 1);
      expect(patched['measures'], 2);
      // 落盘真值：工作台/下一次 run 读的是同一份 score.json（唯一事实源）。
      final stored = await MusicProjectStore(root: root).read('dawn');
      expect(stored.score.title, '暮色');
      expect(stored.score.tempo, 90);
      expect(stored.score.tracks.single.volume, closeTo(0.5, 1e-9));
      expect(stored.validation.verified, isTrue);
      expect(parsedTitleFromFile(root), '暮色');

      final inspect = await services.musicInspect('dawn');
      expect(inspect['ok'], isTrue);
      expect(inspect['name'], 'dawn');
      expect(inspect['title'], '暮色');
      expect(inspect['tempo'], 90);
      expect(inspect['measures'], 2);
      expect(inspect['totalTicks'], 15360);
      expect((inspect['seconds'] as num).toDouble(), 2.67);
      expect(inspect['compiled'], isTrue);
      expect(inspect['verified'], isTrue);
      expect(inspect['issues'], 0);
      // patch 之后读谱仍是同一份：未知字段/事件结构没被补丁搞坏。
      expect(inspect.containsKey('scoreJson'), isFalse);
    });

    test('非法路径：music_patch_invalid_path + 人话 + detail，且不写盘', () async {
      await _seed(root);
      final before = File(_scoreFile(root)).readAsStringSync();
      final failure = await services.musicPatch(
        name: 'dawn',
        ops: <Map<String, dynamic>>[_op('replace', '/schemaVersion', 2)],
      );
      expect(failure['ok'], isFalse);
      expect(failure['error'], 'music_patch_invalid_path');
      expect(failure['message'], contains('版本'));
      expect(failure['message'], isNotEmpty);
      // 信封固定形状：detail 只进折叠的技术详情（可为空）。
      expect(failure.containsKey('detail'), isTrue);
      expect(
        File(_scoreFile(root)).readAsStringSync(),
        before,
        reason: '失败不写盘',
      );
    });

    test('越界 / 坏值：out_of_range / invalid_value 各有可执行人话', () async {
      await _seed(root);
      final before = File(_scoreFile(root)).readAsStringSync();

      final outOfRange = await services.musicPatch(
        name: 'dawn',
        ops: <Map<String, dynamic>>[_op('replace', '/tracks/9/volume', 0.5)],
      );
      expect(outOfRange['ok'], isFalse);
      expect(outOfRange['error'], 'music_patch_out_of_range');
      expect(outOfRange['message'], contains('越界'));

      final badValue = await services.musicPatch(
        name: 'dawn',
        ops: <Map<String, dynamic>>[_op('replace', '/tracks/0/volume', 1.5)],
      );
      expect(badValue['ok'], isFalse);
      expect(badValue['error'], 'music_patch_invalid_value');
      expect(badValue['message'], contains('音量'));

      expect(
        File(_scoreFile(root)).readAsStringSync(),
        before,
        reason: '失败不写盘',
      );
    });

    test('改后校验失败：music_patch_score_invalid + detail 指针，且不写盘', () async {
      await _seed(root);
      final before = File(_scoreFile(root)).readAsStringSync();
      final failure = await services.musicPatch(
        name: 'dawn',
        ops: <Map<String, dynamic>>[_op('replace', '/tempo', 500)],
      );
      expect(failure['ok'], isFalse);
      expect(failure['error'], 'music_patch_score_invalid');
      expect(failure['message'], contains('没有通过校验'));
      expect(failure['detail'], contains('/tempo'));
      expect(
        File(_scoreFile(root)).readAsStringSync(),
        before,
        reason: '失败不写盘',
      );
      // 文件仍是原谱：标题没被上一次成功改动的幻觉带走。
      expect(parsedTitleFromFile(root), '晨光');
    });

    test('事件级补丁：空小节追加整小节音符 → 落盘且 verify 通过', () async {
      await _seed(root);
      final result = await services.musicPatch(
        name: 'dawn',
        ops: <Map<String, dynamic>>[
          _op('add', '/tracks/0/measures/0/events', <String, dynamic>{
            'id': 'e0',
            'type': 'rest',
            'dur': <String, dynamic>{'num': 1, 'den': 1},
          }),
        ],
      );
      expect(result['ok'], isTrue);
      expect(result['applied'], 1);
      final stored = await MusicProjectStore(root: root).read('dawn');
      expect(stored.score.tracks.single.measures.first.events, hasLength(1));
      expect(stored.validation.verified, isTrue);
    });

    test('项目不存在：沿用项目库的人话（music_no_project），不静默成功', () async {
      final failure = await services.musicPatch(
        name: 'ghost',
        ops: <Map<String, dynamic>>[_op('replace', '/title', '暮色')],
      );
      expect(failure['ok'], isFalse);
      expect(failure['error'], 'music_no_project');
      expect(failure['message'], '没有找到这个音乐项目');
      expect(toolFailureMessage('music_no_project'), '没有找到这个音乐项目');
      expect(Directory('${root.path}/ghost').existsSync(), isFalse);
    });
  });

  group('脚本化工具循环（patch → inspect）', () {
    late Directory root;
    late LocalWorkspaceServices services;

    setUp(() {
      root = Directory.systemTemp.createTempSync('music-patch-loop-');
      services = _services(root);
    });

    tearDown(() {
      try {
        root.deleteSync(recursive: true);
      } catch (_) {}
    });

    test(
      'workspaceHint=music：music_patch → music_inspect 真执行，成功计入交付水位',
      () async {
        await _seed(root);
        final events = <Map<String, dynamic>>[];
        final model = ScriptedAgentModel(<List<Part>>[
          <Part>[
            scriptToolCall(
              toolName: 'music_patch',
              input: <String, dynamic>{
                'name': 'dawn',
                'ops': <dynamic>[
                  <String, dynamic>{
                    'op': 'replace',
                    'path': '/title',
                    'value': '暮色',
                  },
                  <String, dynamic>{
                    'op': 'replace',
                    'path': '/tempo',
                    'value': 90,
                  },
                ],
              },
            ),
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
              input: <String, dynamic>{'summary': '乐谱已改并通过校验'},
            ),
          ],
        ]);
        final result = await runDartAgent(
          request: _workspaceRequest(),
          modelOverride: model.model,
          workspace: services,
          onEvent: events.add,
        );

        expect(result.ok, isTrue);
        expect(result.stopReason, 'done');
        expect(
          result.remoteCalls,
          greaterThanOrEqualTo(1),
          reason: '成功的确定性补丁是真实交付，不能被当成 text_only',
        );

        // 工作区收窄：music run 看得见 music_patch，看不见其他模块。
        final toolNames =
            model.calls.first.tools?.map((t) => t.name).toSet() ?? <String>{};
        expect(toolNames, contains('music_patch'));
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

        // 事件面：patch 与 inspect 都有成对的 tool_start/tool_end 且成功。
        for (final tool in <String>['music_patch', 'music_inspect']) {
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
        final patchEnd = events.firstWhere(
          (e) => e['type'] == 'tool_end' && e['tool'] == 'music_patch',
        );
        expect(patchEnd['preview'], contains('applied'));
        expect(patchEnd['preview'], contains('verified'));
        final patchStart = events.firstWhere(
          (e) => e['type'] == 'tool_start' && e['tool'] == 'music_patch',
        );
        expect((patchStart['args'] as Map)['ops'], '<list 2>');

        // 落盘真值：run 结束后临时库读回的是补丁后的谱（不是「说改完了」）。
        final stored = await MusicProjectStore(root: root).read('dawn');
        expect(stored.score.title, '暮色');
        expect(stored.score.tempo, 90);
        expect(stored.validation.verified, isTrue);
      },
    );

    test('补丁失败 run：tool_end 显性失败（码 + 人话）、不入水位、原谱不变', () async {
      await _seed(root);
      final before = File(_scoreFile(root)).readAsStringSync();
      final events = <Map<String, dynamic>>[];
      final model = ScriptedAgentModel(<List<Part>>[
        <Part>[
          scriptToolCall(
            toolName: 'music_patch',
            input: <String, dynamic>{
              'name': 'dawn',
              'ops': <dynamic>[
                <String, dynamic>{
                  'op': 'replace',
                  'path': '/schemaVersion',
                  'value': 2,
                },
              ],
            },
          ),
        ],
        <Part>[
          scriptToolCall(
            toolName: 'finish',
            input: <String, dynamic>{'summary': '版本字段不能改'},
          ),
        ],
      ]);
      final result = await runDartAgent(
        request: _workspaceRequest(),
        modelOverride: model.model,
        workspace: services,
        onEvent: events.add,
      );
      expect(result.ok, isTrue);
      expect(result.remoteCalls, 0, reason: '被拒绝的补丁不是交付，不能移动水位');
      final end = events.firstWhere(
        (e) => e['type'] == 'tool_end' && e['tool'] == 'music_patch',
      );
      expect(end['ok'], isFalse);
      expect(end['error'], 'music_patch_invalid_path');
      expect(end['message'], contains('版本'));
      expect(end['message'], isNot(contains('operation')));
      expect(
        File(_scoreFile(root)).readAsStringSync(),
        before,
        reason: '失败不写盘',
      );
    });

    test('workspace 提示词：music_patch + 确定性补丁纪律，且不列其他工作台工具', () {
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
      expect(instructions, contains('music_patch'));
      expect(instructions, contains('确定性补丁，改后自动校验'));
      expect(instructions, contains('写谱后先过校验器再交付'));
      expect(instructions, isNot(contains('video_list')));
      expect(instructions, isNot(contains('three_list')));
      expect(instructions, isNot(contains('hotapp_list')));
    });
  });
}

/// 从落盘文件里读回标题（绕过 store 模型，直接锚定磁盘字节真值）。
String parsedTitleFromFile(Directory root) {
  final parsed = parseMusicScore(
    jsonDecode(File(_scoreFile(root)).readAsStringSync()),
  );
  expect(parsed.score, isNotNull, reason: '落盘的 score.json 必须可解析');
  return parsed.score!.title;
}
