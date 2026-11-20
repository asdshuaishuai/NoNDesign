/// 流式工具名守护（StepFun step_plan 方言修复）。
///
/// 线上证据（2026-11-20 抓包 step-5-preview 流式）：工具调用只在第一个
/// delta 携带 `function.name`（如 `write_doc`），后续每个 delta 一律重复
/// `name: ""`（空串而非缺省）。`ai_sdk_openai_compatible` 3.1.0 的流式
/// 累积状态机按 `if (name != null) state.name = …` 逐 delta 覆盖——第二个
/// delta 就把真名覆盖成 `''`，流结束时以空名发出 `StreamPartToolCall`，
/// ai_sdk_dart 的 step 校验随即抛
/// `AiNoSuchToolError: Step 0 called unknown tool ""`，把整轮 run 打死
/// （用户可见面即「agent 执行异常结束」）。
///
/// 修复：记住每个 toolCallId 在 `StreamPartToolInputStart` 阶段的非空名，
/// 在 `StreamPartToolCall` 上回填被覆盖的空名。其余片段原样透传。
///
/// 说明：`ai_sdk_provider` 是 ai_sdk_dart 的传递依赖（pubspec 未声明），
/// 守护需要其流片段类型——与 `test/dart_agent_test.dart` 同一处理方式。
// ignore_for_file: depend_on_referenced_packages
library;

import 'dart:async';

import 'package:ai_sdk_dart/ai_sdk_dart.dart';
import 'package:ai_sdk_provider/ai_sdk_provider.dart';

/// 每个 doStream 调用一个作用域：id → 该工具流的首个非空名。
class StreamToolNameGuard extends LanguageModelMiddlewareBase {
  const StreamToolNameGuard({this.knownTools = const <String>{}});

  /// 本轮可用的工具名集合（dart_agent 的 ToolSet keys）。空集合 = 只做
  /// 空名回填，不做近名修复。
  final Set<String> knownTools;

  /// 近名修复：模型笔误的工具名（`finwork` → `finish`）改写回正确名，
  /// 免得一次手滑打死整轮 run。规则（保守，宁可不修不可修错）：
  /// 大小写/空白归一后，取编辑距离最近的已知名；要求（1）距离 ≤4 且
  /// （2）与该名公共前缀 ≥2（证明是真笔误而非天外飞仙）且（3）唯一
  /// 最近（避免 write_doc / write_design_spec 这类近亲二义）。
  ///
  /// 2026-11-20 扩展（线上真实笔误形态）：
  ///  * `namespace.tool`（`mcp.video_create` / `builtin.finish`）→ 逐段去前缀；
  ///  * `tool()` / `tool(args)` → 去调用括号；
  ///  * 结尾冒号/分号/逗号（`finish:`）；
  ///  * 前后空白、全角字符（`ｗｒｉｔｅ＿ｄｏｃ`）；
  ///  * 大小写变体（`Write_Doc` → `write_doc`，修复到规范名而不是放行）；
  ///  * 连字符/空格变体（`write-doc` / `write doc`）。
  /// 仍保持「唯一最近名 + 公共前缀 ≥2」的模糊修复门槛；返回 null = 无可修复
  /// （原名可用或找不到可信的近名）。
  String? repairToolName(String name) {
    final folded = _foldFullWidth(name).trim();
    if (folded.isEmpty || knownTools.isEmpty) return null;
    for (final candidate in _variantSpellings(folded)) {
      final hit = _matchKnown(candidate);
      if (hit == null) continue;
      // 原名已经是规范名（大小写/标点完全一致）→ 无需修复。
      if (hit == name) return null;
      return hit;
    }
    return null;
  }

  /// 一个工具名的候选写法（按可信度从高到低）。
  List<String> _variantSpellings(String name) {
    final out = <String>[];
    void add(String value) {
      final v = value.trim();
      if (v.isNotEmpty && !out.contains(v)) out.add(v);
    }

    add(name);
    // 调用语法与结尾标点：finish() / finish({...}) / finish: / finish;
    final noCall = name.replaceAll(RegExp(r'\s*[\(（][^\)）]*[\)）]'), '');
    add(noCall.replaceAll(RegExp(r'[\)）\]:：;,，。.]+$'), ''));
    // 命名空间前缀逐段剥离（mcp.foo.finish → foo.finish → finish）。
    var rest = noCall;
    while (true) {
      final dot = rest.indexOf('.');
      if (dot < 0) break;
      rest = rest.substring(dot + 1);
      add(rest);
    }
    return out;
  }

  /// 候选名 → 规范工具名：严格同名 → 归一化（大小写/分隔符）→ 保守近名。
  String? _matchKnown(String candidate) {
    if (knownTools.contains(candidate)) return candidate;
    final norm = _normalizeName(candidate.toLowerCase());
    if (norm.isNotEmpty) {
      for (final k in knownTools) {
        if (norm == _normalizeName(k)) return k;
      }
    }
    final n = candidate.toLowerCase();
    String? best;
    var bestDist = 1 << 30;
    var tied = false;
    for (final k in knownTools) {
      final d = _levenshtein(n, k.toLowerCase());
      if (d < bestDist) {
        bestDist = d;
        best = k;
        tied = false;
      } else if (d == bestDist) {
        tied = true;
      }
    }
    if (best == null || tied || bestDist > 4) return null;
    final bl = best.toLowerCase();
    var common = 0;
    while (common < n.length &&
        common < bl.length &&
        n.codeUnitAt(common) == bl.codeUnitAt(common)) {
      common++;
    }
    if (common >= 2) return best;
    return null;
  }

  @override
  Future<LanguageModelV4StreamResult> wrapStream({
    required Future<LanguageModelV4StreamResult> Function(
      LanguageModelV4CallOptions options,
    )
    doStream,
    required LanguageModelV4CallOptions options,
    required LanguageModelV4 model,
  }) async {
    final result = await doStream(options);
    final names = <String, String>{};
    final Stream<LanguageModelV4StreamPart> fixed =
        result.stream.map((LanguageModelV4StreamPart part) {
      if (part is StreamPartToolInputStart) {
        var toolName = part.toolName;
        if (toolName.isEmpty) {
          // StepFun step_plan 方言：首 delta 即名，此时为空说明模型真没给。
        } else {
          final repaired = repairToolName(toolName);
          if (repaired != null) toolName = repaired;
        }
        if (toolName.isNotEmpty) names[part.id] = toolName;
        if (toolName != part.toolName) {
          return StreamPartToolInputStart(
            id: part.id,
            toolName: toolName,
            providerMetadata: part.providerMetadata,
          );
        }
        return part;
      }
      if (part is StreamPartToolCall) {
        final call = part.toolCall;
        var toolName = call.toolName;
        if (toolName.isEmpty) {
          final remembered = names[call.toolCallId];
          if (remembered != null && remembered.isNotEmpty) toolName = remembered;
        } else {
          final repaired = repairToolName(toolName);
          if (repaired != null) toolName = repaired;
        }
        if (toolName != call.toolName) {
          return StreamPartToolCall(
            toolCall: LanguageModelV4ToolCallPart(
              toolCallId: call.toolCallId,
              toolName: toolName,
              input: call.input,
              providerExecuted: call.providerExecuted,
            ),
          );
        }
        return part;
      }
      return part;
    });
    return LanguageModelV4StreamResult(
      stream: fixed,
      warnings: result.warnings,
      request: result.request,
      response: result.response,
    );
  }
}

/// 全角 → 半角折叠（含全角空格与 U+3000）：模型偶尔用全角字符拼工具名
/// （`ｗｒｉｔｅ＿ｄｏｃ`），折叠后才能和已知名对齐。
String _foldFullWidth(String s) {
  final buffer = StringBuffer();
  for (final rune in s.runes) {
    if (rune >= 0xFF01 && rune <= 0xFF5E) {
      buffer.writeCharCode(rune - 0xFEE0);
    } else if (rune == 0x3000) {
      buffer.write(' ');
    } else {
      buffer.writeCharCode(rune);
    }
  }
  return buffer.toString();
}

/// 命名规范归一：去掉分隔符（_ / - / 空格 / . / ·）后比较（驼峰在
/// toLowerCase 时已摊平）。点号也当分隔符：`write.doc` 与 `write_doc` 同义。
String _normalizeName(String s) => s.replaceAll(RegExp(r'[_\- .·]'), '');

/// 经典 DP 编辑距离（输入都是短工具名，O(mn) 无所谓）。
int _levenshtein(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  var prev = List<int>.generate(b.length + 1, (i) => i);
  var cur = List<int>.filled(b.length + 1, 0);
  for (var i = 0; i < a.length; i++) {
    cur[0] = i + 1;
    for (var j = 0; j < b.length; j++) {
      final cost = a.codeUnitAt(i) == b.codeUnitAt(j) ? 0 : 1;
      var v = prev[j + 1] + 1; // 删
      final ins = cur[j] + 1; // 增
      if (ins < v) v = ins;
      final sub = prev[j] + cost; // 换
      if (sub < v) v = sub;
      cur[j + 1] = v;
    }
    final t = prev;
    prev = cur;
    cur = t;
  }
  return prev[b.length];
}
