/// 盲评通道：fresh context + brief/图 → judgment JSON → score。
///
/// 契约见 `docs/skills/creative-workbench/references/judging.md`：
/// * 评审只看到 `brief.md` + 渲染图，**看不到生成者代码/推理**，也不自己给总分；
/// * 总分由 [CreativeScore.compute]（rubric/penalty/floor/cap）算；caps 最后应用；
/// * 通道失败必须**显性降级**（`degraded` + 原因），不得静默冒充盲评分数。
///
/// 本文件不依赖 Flutter/IO：图片以 base64 字节传入，测试可用 scripted 模型注入。
library;

import 'dart:convert';

import 'package:genkit/genkit.dart';
import 'package:genkit_openai/genkit_openai.dart';

import 'creative_gates.dart';
import 'creative_judgment.dart';
import 'creative_schema.dart';
import 'creative_score.dart';

/// 一张评审图（渲染/拼图证据）。`bytes` 是 PNG/JPEG 原始字节。
final class CreativeJudgeImage {
  const CreativeJudgeImage({
    required this.label,
    required this.bytes,
    required this.mimeType,
  });

  final String label;
  final List<int> bytes;

  /// `image/png` / `image/jpeg` / `image/webp`。
  final String mimeType;

  String get dataUri => 'data:$mimeType;base64,${base64Encode(bytes)}';
}

/// 一次盲评请求：brief 文本 + 图 + （可选）门事实与 rubric 输入。
final class CreativeJudgeRequest {
  const CreativeJudgeRequest({
    required this.kind,
    required this.track,
    required this.brief,
    this.planDigest = '',
    this.acceptance = const <String>[],
    this.measuredFacts = const <String>[],
    this.gates,
    this.images = const <CreativeJudgeImage>[],
    this.weights,
    this.scoreConfig = const CreativeScoreConfig(),
  });

  final CreativeKind kind;
  final CreativeTrack track;
  final String brief;
  final String planDigest;
  final List<String> acceptance;

  /// 门/测量事实（`gates.json` 的摘要），judge 只读事实，不跑门。
  final List<String> measuredFacts;
  final CreativeGatesReport? gates;
  final List<CreativeJudgeImage> images;
  final Map<CreativeCriterion, double>? weights;
  final CreativeScoreConfig scoreConfig;

  /// 给 judge 的 brief.md 正文（不含图；图由多模态 part 承载）。
  String toBriefMarkdown() {
    final buffer = StringBuffer()
      ..writeln('# Blind judge brief')
      ..writeln()
      ..writeln('## Request')
      ..writeln('- kind: ${kind.wire}')
      ..writeln('- track: ${track.wire}')
      ..writeln('- brief: $brief')
      ..writeln();
    if (planDigest.trim().isNotEmpty) {
      buffer
        ..writeln('## Plan digest')
        ..writeln(planDigest.trim())
        ..writeln();
    }
    if (acceptance.isNotEmpty) {
      buffer
        ..writeln('## Acceptance')
        ..writeln(acceptance.map((item) => '- $item').join('\n'))
        ..writeln();
    }
    if (measuredFacts.isNotEmpty) {
      buffer
        ..writeln('## Measured facts (gates)')
        ..writeln(measuredFacts.map((fact) => '- $fact').join('\n'))
        ..writeln();
    }
    if (gates != null) {
      buffer
        ..writeln('## Gate verdicts')
        ..writeln('- overall: ${gates!.verdict.wire}')
        ..writeln(
          gates!.gates
              .map(
                (gate) =>
                    '- ${gate.id}: ${gate.verdict.wire}'
                    '${gate.fixHint.isEmpty ? '' : '（${gate.fixHint}）'}',
              )
              .join('\n'),
        )
        ..writeln();
    }
    buffer
      ..writeln('## Images')
      ..writeln(
        images.isEmpty
            ? '(NO IMAGES — this is a degraded run; do not invent visual evidence)'
            : images.map((image) => '- ${image.label}').join('\n'),
      )
      ..writeln()
      ..writeln('## Rubric')
      ..writeln(
        '维度：idea / composition / craft / motion / legibility / constraint_fit，'
        '每个 0–1 且必须写 why（引用可见证据）。',
      );
    return buffer.toString();
  }
}

/// 盲评结果。`degraded == true` 时 [judgment] 为空或不可用于交付，
/// 调用方必须把原因显示出来（不能拿 degraded 当盲评分数）。
final class CreativeJudgeOutcome {
  const CreativeJudgeOutcome({
    this.judgment,
    this.score,
    this.degraded = false,
    this.reason = '',
    this.detail = '',
    this.rawText = '',
    this.issues = const <CreativeIssue>[],
  });

  static CreativeJudgeOutcome ok({
    required CreativeJudgment judgment,
    CreativeScoreResult? score,
    String rawText = '',
  }) =>
      CreativeJudgeOutcome(judgment: judgment, score: score, rawText: rawText);

  static CreativeJudgeOutcome degrade({
    required String reason,
    String detail = '',
    List<CreativeIssue> issues = const <CreativeIssue>[],
    String rawText = '',
  }) => CreativeJudgeOutcome(
    degraded: true,
    reason: reason,
    detail: detail,
    issues: issues,
    rawText: rawText,
  );

  final CreativeJudgment? judgment;
  final CreativeScoreResult? score;
  final bool degraded;

  /// 稳定机器码（`judge_no_images` / `judge_model_error` / `judge_invalid_json` /
  /// `judge_invalid_judgment` / `judge_no_output`）。
  final String reason;
  final String detail;
  final String rawText;
  final List<CreativeIssue> issues;

  Map<String, Object?> toJson() => <String, Object?>{
    'ok': judgment != null && !degraded,
    if (degraded) 'degraded': true,
    if (degraded) 'reason': reason,
    if (detail.isNotEmpty) 'detail': detail,
    if (judgment != null) 'judgment': judgment!.toJson(),
    if (score != null) 'score': score!.toJson(),
    if (issues.isNotEmpty)
      'issues': issues.map((issue) => issue.toJson()).toList(growable: false),
  };
}

/// 盲评通道（fresh context：不注册任何工具、不带历史消息）。
final class CreativeJudgeService {
  const CreativeJudgeService();

  /// 执行一次盲评。
  ///
  /// [modelOverride] 只用于测试（scripted 模型）；生产传
  /// `model/baseUrl/apiKey` 走 `genkit_openai`。
  Future<CreativeJudgeOutcome> judge({
    required CreativeJudgeRequest request,
    required String model,
    required String baseUrl,
    required String apiKey,
    String thinkingLevel = 'auto',
    Model? modelOverride,
  }) async {
    if (request.images.isEmpty) {
      return CreativeJudgeOutcome.degrade(
        reason: 'judge_no_images',
        detail: '盲评必须有渲染图证据；没有图片不能声称视觉分数。',
      );
    }
    final ai = Genkit(
      plugins: <GenkitPlugin>[
        if (modelOverride == null && apiKey.isNotEmpty)
          openAI(name: _judgePluginName, apiKey: apiKey, baseUrl: baseUrl),
      ],
    );
    try {
      if (modelOverride != null) ai.registry.register(modelOverride);
      final ModelRef<dynamic> ref =
          modelOverride ?? openAI.model(model, namespace: _judgePluginName);
      final List<Part> parts = <Part>[
        TextPart(text: request.toBriefMarkdown()),
        for (final CreativeJudgeImage image in request.images)
          MediaPart(
            media: Media(contentType: image.mimeType, url: image.dataUri),
          ),
      ];
      final GenerateResult<dynamic> result = await ai
          .generate<dynamic, dynamic>(
            model: ref,
            system: _judgeSystem,
            promptParts: parts,
            // 只读评审：不给工具、最多一轮，避免 judge 自己动手改东西。
            maxTurns: 1,
            config: _judgeConfig(thinkingLevel),
          );
      if (result.finishReason.value != 'stop' &&
          result.finishReason.value != 'length') {
        return CreativeJudgeOutcome.degrade(
          reason: 'judge_model_error',
          detail:
              result.cause?.toString() ??
              result.finishMessage ??
              result.error?.message ??
              'judge 未正常结束',
          rawText: result.text,
        );
      }
      final String text = result.text.trim();
      if (text.isEmpty) {
        return CreativeJudgeOutcome.degrade(
          reason: 'judge_no_output',
          detail: 'judge 返回空内容',
        );
      }
      final Object? decoded = _firstJsonObject(text);
      if (decoded == null) {
        return CreativeJudgeOutcome.degrade(
          reason: 'judge_invalid_json',
          detail: 'judge 输出不是可解析的 JSON 对象',
          rawText: text,
        );
      }
      final CreativeParseResult<CreativeJudgment> parsed =
          CreativeJudgment.parse(decoded);
      if (!parsed.ok) {
        return CreativeJudgeOutcome.degrade(
          reason: 'judge_invalid_judgment',
          detail: 'judge JSON 不符合评审契约',
          issues: parsed.validation.issues,
          rawText: text,
        );
      }
      CreativeScoreResult? score;
      if (request.gates != null) {
        try {
          score = CreativeScore.compute(
            judgment: parsed.value!,
            gates: request.gates!,
            weights: request.weights ?? CreativeRubrics.forKind(request.kind),
            config: request.scoreConfig,
          );
        } on ArgumentError catch (error) {
          return CreativeJudgeOutcome.degrade(
            reason: 'judge_invalid_judgment',
            detail: '$error',
            rawText: text,
          );
        }
      }
      return CreativeJudgeOutcome.ok(
        judgment: parsed.value!,
        score: score,
        rawText: text,
      );
    } catch (error) {
      return CreativeJudgeOutcome.degrade(
        reason: 'judge_model_error',
        detail: '$error',
      );
    }
  }

  static OpenAIChatOptions _judgeConfig(String thinkingLevel) {
    final level = thinkingLevel.trim().toLowerCase();
    // 思考档位沿用主 agent 的方言表：MiniMax 自适应思考不能让 auto 落 disabled。
    final effort = switch (level) {
      'low' => 'low',
      'medium' => 'medium',
      'high' => 'high',
      'xhigh' => 'xhigh',
      'max' => 'max',
      _ => 'low',
    };
    return OpenAIChatOptions(reasoningEffort: effort);
  }
}

/// 从文本里提取第一个 JSON 对象（容忍 ```json 围栏 / 前后解释文字）。
Object? _firstJsonObject(String text) {
  var body = text.trim();
  final fence = RegExp(r'```(?:json|JSON)?\s*([\s\S]*?)```').firstMatch(body);
  if (fence != null) body = fence.group(1)!.trim();
  final start = body.indexOf('{');
  final end = body.lastIndexOf('}');
  if (start < 0 || end <= start) return null;
  try {
    final decoded = jsonDecode(body.substring(start, end + 1));
    return decoded is Map<String, dynamic> ? decoded : null;
  } catch (_) {
    return null;
  }
}

const String _judgePluginName = 'nan_judge';

const String _judgeSystem =
    '''You are a BLIND JUDGE for a code-generated creative artifact.

You see ONLY the brief, the plan digest/acceptance/measured gate facts above, and the attached
images. You do NOT see the builder's code, reasoning, or self-assessment, and you must not
pretend to. Your job is perceptual judgment, not gate re-measurement.

Return ONE JSON object exactly in this shape (no prose, no markdown):
{
  "criteria": {
    "idea": {"score": 0.0, "why": "..."},
    "composition": {"score": 0.0, "why": "..."},
    "craft": {"score": 0.0, "why": "..."},
    "motion": {"score": 0.0, "why": "..."},
    "legibility": {"score": 0.0, "why": "..."},
    "constraint_fit": {"score": 0.0, "why": "..."}
  },
  "summary": "one paragraph",
  "strengths": ["..."],
  "issues": [{"criterion": "craft", "tile": "m2", "evidence": "what is visible", "fix": "targeted fix"}],
  "improvement_plan": [{"priority": 1, "target": "part/zone", "action": "numeric/targeted action", "evidence": "..."}],
  "acceptance": [{"item": "...", "pass": true, "evidence": "..."}],
  "defects": [{"id": "floating_part", "present": false, "evidence": "..."}]
}

Rules:
- every criterion score in [0,1] with a non-empty "why" citing visible evidence;
- every issue must cite a numbered image tile and observable evidence;
- improvement_plan is the only input to the next refine round; give numeric fixes;
- if an image is unreadable/missing, report that as an issue, not as a high score;
- never write an overall score; the caller computes it from weights and gate caps.''';
