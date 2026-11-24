import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:genkit/genkit.dart';
import 'package:nondesign/core/creative/creative_judge.dart';
import 'package:nondesign/core/creative/creative_gates.dart';
import 'package:nondesign/core/creative/creative_schema.dart';

import 'helpers/creative_fixtures.dart';
import 'helpers/genkit_test_model.dart';

final Uint8List _pixel = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
);

CreativeJudgeImage _image() =>
    CreativeJudgeImage(label: 'm1', bytes: _pixel, mimeType: 'image/png');

CreativeJudgeRequest _request({
  List<CreativeJudgeImage>? images,
  int? gatesRound,
}) {
  final Map<String, dynamic> gatesRaw = creativeFixture(
    'gates_3d_floating.json',
  );
  if (gatesRound != null) gatesRaw['round'] = gatesRound;
  return CreativeJudgeRequest(
    kind: CreativeKind.threeD,
    track: CreativeTrack.staticObject,
    brief: '一把中世纪橡木餐椅',
    planDigest: 'seat 0.45m; four legs; oak',
    acceptance: const <String>['座高 0.45m', '四腿落地 ≤2mm'],
    measuredFacts: const <String>['connectivity: 1 floating part'],
    gates: CreativeGatesReport.parse(gatesRaw).value,
    images: images ?? <CreativeJudgeImage>[_image()],
  );
}

String _validJudgmentJson() =>
    jsonEncode(creativeFixture('judgment_3d_ok.json'));

void main() {
  group('creative judge', () {
    test('合法盲评：解析 judgment 并用 gates caps 算分', () async {
      final scripted = ScriptedAgentModel(<ScriptedTurn>[
        <Part>[scriptText(_validJudgmentJson())],
      ]);
      final outcome = await CreativeJudgeService().judge(
        request: _request(),
        model: 'scripted-model',
        baseUrl: '',
        apiKey: 'k',
        modelOverride: scripted.model,
      );
      expect(outcome.degraded, isFalse, reason: outcome.detail);
      expect(outcome.judgment, isNotNull);
      expect(outcome.judgment!.criteria, hasLength(6));
      expect(outcome.score, isNotNull);
      // connectivity ERROR + caps.floating 0.60 最后应用。
      expect(outcome.score!.overall, closeTo(0.6, 1e-9));
      expect(
        outcome.score!.caps.firstWhere((c) => c.id == 'floating').applied,
        isTrue,
      );
      // fresh context：judge 请求不带任何工具。
      expect((scripted.calls.first.tools ?? const <ToolDefinition>[]), isEmpty);
      // brief 与图一起进入多模态请求。
      expect(
        scripted.calls.first.messages.any(
          (m) => m.content.any((part) => part.toJson().containsKey('media')),
        ),
        isTrue,
      );
    });

    test('无图片：显性降级，不得冒充盲评分', () async {
      final outcome = await CreativeJudgeService().judge(
        request: _request(images: const <CreativeJudgeImage>[]),
        model: 'scripted-model',
        baseUrl: '',
        apiKey: 'k',
      );
      expect(outcome.degraded, isTrue);
      expect(outcome.reason, 'judge_no_images');
      expect(outcome.judgment, isNull);
    });

    test('JSON 围栏容忍：```json 包裹的 judgment 仍可解析', () async {
      final scripted = ScriptedAgentModel(<ScriptedTurn>[
        <Part>[scriptText('这里是评审：\n```json\n${_validJudgmentJson()}\n```')],
      ]);
      final outcome = await CreativeJudgeService().judge(
        request: _request(),
        model: 'scripted-model',
        baseUrl: '',
        apiKey: 'k',
        modelOverride: scripted.model,
      );
      expect(outcome.degraded, isFalse, reason: outcome.detail);
      expect(outcome.judgment, isNotNull);
    });

    test('坏 JSON → degraded judge_invalid_json（保留 raw 供技术详情）', () async {
      final scripted = ScriptedAgentModel(<ScriptedTurn>[
        <Part>[scriptText('not json at all')],
      ]);
      final outcome = await CreativeJudgeService().judge(
        request: _request(),
        model: 'scripted-model',
        baseUrl: '',
        apiKey: 'k',
        modelOverride: scripted.model,
      );
      expect(outcome.degraded, isTrue);
      expect(outcome.reason, 'judge_invalid_json');
      expect(outcome.rawText, 'not json at all');
      expect(outcome.toJson()['degraded'], isTrue);
    });

    test('不符合评审契约的 JSON → degraded judge_invalid_judgment + issues', () async {
      final scripted = ScriptedAgentModel(<ScriptedTurn>[
        <Part>[
          scriptText(
            '{"criteria":{"idea":{"score":1,"why":"x"}},"summary":"s"}',
          ),
        ],
      ]);
      final outcome = await CreativeJudgeService().judge(
        request: _request(),
        model: 'scripted-model',
        baseUrl: '',
        apiKey: 'k',
        modelOverride: scripted.model,
      );
      expect(outcome.degraded, isTrue);
      expect(outcome.reason, 'judge_invalid_judgment');
      expect(outcome.issues, isNotEmpty);
    });

    test('模型异常 → degraded judge_model_error（不抛给调用方）', () async {
      final model = Model<dynamic>(
        name: 'broken/broken-judge',
        fn:
            (
              ModelRequest req,
              ActionFnArg<ModelResponseChunk, ModelRequest, void> ctx,
            ) async {
              throw GenkitException(
                'vision unsupported',
                status: StatusCode.invalidArgument,
              );
            },
      );
      final outcome = await CreativeJudgeService().judge(
        request: _request(),
        model: 'broken',
        baseUrl: '',
        apiKey: 'k',
        modelOverride: model,
      );
      expect(outcome.degraded, isTrue);
      expect(outcome.reason, 'judge_model_error');
      expect(outcome.detail, contains('vision unsupported'));
    });

    test('brief 含 measured facts 与缺口标注（无图时告知不能编造证据）', () {
      final request = _request(images: const <CreativeJudgeImage>[]);
      final brief = request.toBriefMarkdown();
      expect(brief, contains('connectivity: 1 floating part'));
      expect(brief, contains('NO IMAGES'));
      expect(brief, contains('## Rubric'));
    });
  });
}
