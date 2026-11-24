/// genkit scripted 模型（测试基建）：逐轮脚本模型 + scriptText /
/// scriptReasoning / scriptToolCall 构造器，驱动工具循环与流式事件断言。
///
/// 与迁移前同形的语义：
/// - 每次模型调用依序取下一轮脚本；脚本耗尽后回 'done' 文本（防死循环）；
/// - 文本/reasoning part 以流式 chunk 吐出（驱动 onChunk 路径），
///   工具调用 part 只进最终 message（工具循环从 message 读请求）；
/// - 每次调用的 [ModelRequest] 记进 [calls]（prompt/tools 回喂面断言用）。
library;

import 'package:genkit/genkit.dart';

/// 一轮脚本：模型一次调用（一个 turn）要产出的 content parts。
typedef ScriptedTurn = List<Part>;

/// 文本 content part。
TextPart scriptText(String text) => TextPart(text: text);

/// reasoning content part。
ReasoningPart scriptReasoning(String text) => ReasoningPart(reasoning: text);

/// 工具调用 content part。
ToolRequestPart scriptToolCall({
  required String toolName,
  required Object input,
  String? toolCallId,
}) =>
    ToolRequestPart(
      toolRequest: ToolRequest(name: toolName, input: input, ref: toolCallId),
    );

/// 多轮脚本化 genkit 模型。经 [model] 注入 `runDartAgent(modelOverride:)`。
class ScriptedAgentModel {
  ScriptedAgentModel(this.script) {
    model = Model<dynamic>(
      name: 'scripted/scripted-model',
      fn: (ModelRequest req,
              ActionFnArg<ModelResponseChunk, ModelRequest, void> ctx) =>
          _turn(req, ctx),
    );
  }

  final List<ScriptedTurn> script;

  /// 每次模型调用收到的请求（断言 prompt / 工具清单 / 回喂面用）。
  final List<ModelRequest> calls = [];

  int _i = 0;

  late final Model<dynamic> model;

  Future<ModelResponse> _turn(
    ModelRequest req,
    ActionFnArg<ModelResponseChunk, ModelRequest, void> ctx,
  ) async {
    calls.add(req);
    final step =
        _i < script.length ? script[_i++] : <Part>[scriptText('done')];
    // 流式吐出文本/reasoning（驱动循环的 assistant_delta / thinking_delta）；
    // 工具调用 part 只进最终 message——工具循环从 message 读请求。
    for (final part in step) {
      if (part is ToolRequestPart) continue;
      ctx.sendChunk(ModelResponseChunk(content: [part], role: Role.model));
    }
    return ModelResponse(
      message: Message(role: Role.model, content: step),
      finishReason: FinishReason.stop,
    );
  }
}

/// 挂起模型：fn 阻塞直到取消令牌置位——取消路径的确定性复现。
/// genkit 的 cooperative cancel 观察同一个令牌：任一路径先到都能解除挂起。
class HangingAgentModel {
  HangingAgentModel(this.token)
    : model = Model<dynamic>(
        name: 'hanging/hanging-model',
        fn: (ModelRequest req,
                ActionFnArg<ModelResponseChunk, ModelRequest, void> ctx) =>
            token.whenCancelled.then(
              (_) => ModelResponse(finishReason: FinishReason.aborted),
            ),
      );

  final CancellationToken token;

  late final Model<dynamic> model;
}
