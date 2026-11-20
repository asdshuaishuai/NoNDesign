// 内置 Dart Agent 循环（core/dart_agent.dart）的锚点测试。
//
// 覆盖（对应任务清单）：
// - 工具循环：PLAN write_doc ×2 + write_design_spec + finish（docs 归一/事件序/usage）；
// - doc_not_written / nudge 轮：server/agent.py:623-649 语义（恰好一轮 nudge、
//   仍无文档 → failed(doc_not_written)）；BUILD 无操作 → text_only done；
// - 取消：token 中断 → failed(cancelled) / stopReason=cancelled；
// - thinking 方言表：与 server/agent.py:543-547 的 Python 逻辑逐级对照
//   （fixture 由该 Python 逻辑生成，见 fixtures/thinking_dialect.json）；
// - design_op 引擎门：唯一写路径 = bridge.applyAgent（gate=agent 语义），
//   canonical 回写 + ops 记账 + preview + state 卡；拒绝 op 不入 ops。
// - models.dart agentRuntime 默认 local / 显式 server 保留 / 未知回落 local。
//
// 事件契约即 store._handleAgentEvent 的消费面——事件形状改动必须同步该函数。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ai_sdk_dart/ai_sdk_dart.dart';
import 'package:ai_sdk_dart/test.dart';
// ai_sdk_provider 是 ai_sdk_dart 的传递依赖（pubspec 未声明）；scripted mock
// 需要其流片段/结果类型来覆写 doStream。
// ignore: depend_on_referenced_packages
import 'package:ai_sdk_provider/ai_sdk_provider.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nondesign/core/dart_agent.dart';
import 'package:nondesign/core/models.dart';

/// 多轮脚本化模型：每次 doStream 依序取下一步响应；脚本耗尽后回 plain text
/// 'done'（防死循环）。片段序列仿 MockLanguageModelV4.doStream（text/tool call
/// 两类）。
class _ScriptedModel extends MockLanguageModelV4 {
  final List<List<LanguageModelV4ContentPart>> script;
  int _i = 0;
  _ScriptedModel(this.script) : super(provider: 'scripted', modelId: 'scripted-model');

  @override
  Future<LanguageModelV4StreamResult> doStream(LanguageModelV4CallOptions options) async {
    streamCalls.add(options);
    final step = _i < script.length ? script[_i++] : <LanguageModelV4ContentPart>[mockText('done')];
    var seq = 0;
    String nextId() => 'id-${seq++}';
    final parts = <LanguageModelV4StreamPart>[
      const StreamPartStreamStart(warnings: []),
    ];
    for (final part in step) {
      if (part is LanguageModelV4TextPart) {
        final id = nextId();
        parts.add(StreamPartTextStart(id: id));
        parts.add(StreamPartTextDelta(id: id, delta: part.text));
        parts.add(StreamPartTextEnd(id: id));
      } else if (part is LanguageModelV4ToolCallPart) {
        parts.add(StreamPartToolInputStart(id: part.toolCallId, toolName: part.toolName));
        parts.add(StreamPartToolInputDelta(id: part.toolCallId, delta: jsonEncode(part.input)));
        parts.add(StreamPartToolInputEnd(id: part.toolCallId));
        parts.add(StreamPartToolCall(toolCall: part));
      }
    }
    parts.add(const StreamPartFinish(
      finishReason: LanguageModelV4FinishReason.stop,
      rawFinishReason: 'stop',
    ));
    return LanguageModelV4StreamResult(stream: Stream.fromIterable(parts));
  }
}

/// 挂起模型：doStream 阻塞直到 token 取消——取消路径的确定性复现。
class _HangingModel extends MockLanguageModelV4 {
  final CancellationToken token;
  _HangingModel(this.token) : super(provider: 'hanging', modelId: 'hanging-model');

  @override
  Future<LanguageModelV4StreamResult> doStream(LanguageModelV4CallOptions options) async {
    streamCalls.add(options);
    await token.onCancelled; // 挂起直到取消
    throw const AiOperationCancelledError();
  }
}

/// 第一轮正常交付一半文档（write_doc prd），第二轮挂起：若 run 间隙的取消
/// 检查生效，第二轮永远不该开始（calls 恒为 1）。两轮间隙的确定性取消测试。
class _HangOnSecondRound extends MockLanguageModelV4 {
  final CancellationToken token;
  int calls = 0;
  _HangOnSecondRound(this.token) : super(provider: 'hang2', modelId: 'hang2-model');

  @override
  Future<LanguageModelV4StreamResult> doStream(LanguageModelV4CallOptions options) async {
    calls += 1;
    streamCalls.add(options);
    if (calls > 1) {
      await token.onCancelled;
      throw const AiOperationCancelledError();
    }
    final parts = <LanguageModelV4StreamPart>[
      const StreamPartStreamStart(warnings: []),
      StreamPartToolInputStart(id: 't0', toolName: 'write_doc'),
      StreamPartToolInputDelta(
          id: 't0', delta: jsonEncode({'kind': 'prd', 'content': '# PRD\n一半'})),
      const StreamPartToolInputEnd(id: 't0'),
      StreamPartToolCall(toolCall: mockToolCall(
        toolCallId: 't0',
        toolName: 'write_doc',
        input: {'kind': 'prd', 'content': '# PRD\n一半'},
      )),
      const StreamPartFinish(finishReason: LanguageModelV4FinishReason.stop, rawFinishReason: 'stop'),
    ];
    return LanguageModelV4StreamResult(stream: Stream.fromIterable(parts));
  }
}

/// 引擎门 fake：记录 (mbt, op) 调用面；可配置拒绝。只读 session 面返回
/// 最小真实形状（list_artboards / flows / query_nodes）。canonical 链内
/// 递增（applied 注释 + create home 时补引擎标记块，供本地 artboard 切段）。
class _FakeGate implements EngineGateBridge {
  final List<String> ops = [];
  final List<String> mbts = [];
  String canonical;
  final Set<String> rejectOps;
  final List<String> sessionNames = [];
  final List<String?> sessionArgs = [];
  int templatesCalls = 0;
  int componentsCalls = 0;
  _FakeGate({this.rejectOps = const {}, this.canonical = ''});

  @override
  Future<Map<String, dynamic>> applyAgent(String mbt, String op) async {
    if (rejectOps.contains(op)) {
      return {'ok': false, 'error': 'mbt_gate_block:lg:no_sibling_overlap:welcome_title'};
    }
    ops.add(op);
    mbts.add(mbt);
    canonical = '$mbt\n<!-- applied: $op -->';
    if (op.startsWith('create home')) {
      canonical += '\n<!-- moonviz:artboard home -->\n```mbt\n'
          'fn visual_home() -> @decl.Prototype { 1 }\n```\n';
    }
    return {'ok': true, 'mbt': canonical, 'op': op};
  }

  @override
  Future<Map<String, dynamic>> session(String mbt, String name, [String? arg]) async {
    sessionNames.add(name);
    sessionArgs.add(arg);
    switch (name) {
      case 'session_list_artboards':
        return {'ok': true, 'data': [
          {'id': 'home', 'nodes': 3, 'width': 390, 'height': 844},
        ]};
      case 'session_flows':
        return {'ok': true, 'data': [
          {'from': 'home', 'to': 'detail', 'trigger': 'tap:card'},
        ]};
      case 'session_query_nodes':
        return {'ok': true, 'data': [
          {'id': 'title'},
          {'id': 'card'},
        ]};
      case 'session_critique':
        return {'ok': true, 'data': {'results': [
          {'principle': 'contrast', 'score': 4, 'verdict': 'good', 'observation': 'ok', 'advice': ''},
        ]}};
    }
    return {'ok': true, 'data': []};
  }

  @override
  Future<List<dynamic>> templates() async {
    templatesCalls += 1;
    return const [
      {'id': 'pc_app', 'name': 'PC App', 'device': 'pc'},
    ];
  }

  @override
  Future<List<dynamic>> components() async {
    componentsCalls += 1;
    return const ['button', 'text'];
  }
}

DartAgentRequest _planReq({String instruction = '做一个记账 App'}) => DartAgentRequest(
      mode: 'plan',
      instruction: instruction,
      model: 'scripted-model',
      baseUrl: 'https://example.invalid/v1',
      apiKey: 'k',
      docs: const {},
    );

void main() {
  group('PLAN 工具循环（write_doc ×2 + write_design_spec + finish）', () {
    test('两份文档 + 规范归一 + 事件序 + usage', () async {
      final events = <Map<String, dynamic>>[];
      final result = await runDartAgent(
        request: _planReq(),
        modelOverride: _ScriptedModel([
          [
            mockToolCall(toolName: 'write_doc', input: {'kind': 'prd', 'content': '# PRD\n目标：记账'}),
            mockToolCall(toolName: 'write_doc', input: {'kind': 'ui', 'content': '## UI\n首页清单'}),
          ],
          [
            mockToolCall(toolName: 'write_design_spec', input: {
              'palette': {'primary': '#3366FF'},
              'typography': {'h1': 30, 'h2': 22, 'body': 15},
              'spacing': [4, 8, 16],
              'radius': {'sm': 6, 'md': 10, 'lg': 14},
            }),
          ],
          [mockToolCall(toolName: 'finish', input: {'summary': '完成 PRD/UI，建议首屏首页'})],
        ]),
        onEvent: events.add,
      );

      expect(result.ok, isTrue, reason: '两份齐 + finish → done');
      expect(result.stopReason, 'done');
      expect(result.docs['prd'], contains('PRD'));
      expect(result.docs['ui'], contains('UI'));
      // 设计规范归一（server normalize_design 语义）：补缺省键、spacing 取整、v=1。
      final design = result.docs['design'] as Map;
      expect(design['palette']['primary'], '#3366FF');
      expect(design['palette']['muted'], '#6B7280', reason: '未给的调色键补默认');
      expect(design['typography']['h1'], 30);
      expect(design['spacing'], [4, 8, 16]);
      expect(design['v'], 1);
      // designSpec（design_for_agent 面）不带 rules/notes。
      expect(result.designSpec.containsKey('rules'), isFalse);
      expect(result.designSpec['palette'], isA<Map>());

      // 事件序：两份 doc_written + design_spec_written + final 文本 + usage + done。
      final docWrites = events.where((e) => e['type'] == 'doc_written').toList();
      expect(docWrites.length, 2);
      expect(docWrites[0]['kind'], 'prd');
      expect(docWrites[1]['kind'], 'ui');
      expect(docWrites[0]['content'], contains('记账'));
      expect(events.any((e) => e['type'] == 'design_spec_written'), isTrue);
      expect(
          events.any((e) => e['type'] == 'assistant_text' && e['final'] == true && e['text'] == '完成 PRD/UI，建议首屏首页'),
          isTrue);
      expect(events.last['type'], 'done');
      // requests = LLM 步数（server raw_responses 同语义）；脚本化模型在
      // finish 后还会补一次纯文本调用，故 >=3 而非精确值。
      expect(events.any((e) => e['type'] == 'usage' && (e['requests'] as int) >= 3), isTrue);
      // PLAN 全程零 nudge（交付齐全）。
      expect(events.any((e) => e['type'] == 'note' && e['label'] == 'NaN 继续执行'), isFalse);
      // PLAN 不暴露引擎面工具（事件里也不该有 design_op 的 tool_start）。
      expect(events.any((e) => e['type'] == 'tool_start' && e['tool'] == 'design_op'), isFalse);
    });

    test('write_doc 非法 kind / 空正文 → doc_kind_must_be_prd_or_ui（server 同门）', () async {
      final events = <Map<String, dynamic>>[];
      final result = await runDartAgent(
        request: _planReq(),
        modelOverride: _ScriptedModel([
          [
            mockToolCall(toolName: 'write_doc', input: {'kind': 'spec', 'content': 'x'}),
            mockToolCall(toolName: 'write_doc', input: {'kind': 'prd', 'content': '   '}),
            mockToolCall(toolName: 'write_doc', input: {'kind': 'prd', 'content': '# 真文档'}),
            mockToolCall(toolName: 'write_doc', input: {'kind': 'ui', 'content': '## 首页'}),
          ],
        ]),
        onEvent: events.add,
      );
      expect(result.ok, isTrue);
      expect(result.docs['prd'], '# 真文档');
      final ends = events.where((e) => e['type'] == 'tool_end' && e['tool'] == 'write_doc').toList();
      expect(ends[0]['ok'], isFalse);
      expect(ends[0]['error'], 'doc_kind_must_be_prd_or_ui');
      expect(ends[1]['ok'], isFalse, reason: '空白正文同样拒绝');
      expect(ends[2]['ok'], isTrue);
      expect(ends[3]['ok'], isTrue);
    });
  });

  group('doc_not_written / nudge 轮（server/agent.py:623-649 语义）', () {
    test('两轮纯散文：恰好一轮 nudge → failed(doc_not_written)', () async {
      final events = <Map<String, dynamic>>[];
      final result = await runDartAgent(
        request: _planReq(),
        modelOverride: _ScriptedModel([
          [mockText('需要先确认配色偏好吗？')],
          [mockText('好的，那我不问了。')],
        ]),
        onEvent: events.add,
      );
      expect(result.ok, isFalse);
      expect(result.stopReason, 'doc_not_written');
      expect(result.error, 'doc_not_written');
      final nudges = events.where((e) => e['type'] == 'note' && e['label'] == 'NaN 继续执行').toList();
      expect(nudges, hasLength(1), reason: 'nudge 恰好一轮（server 同构）');
      final failed = events.where((e) => e['type'] == 'failed' && e['error'] == 'doc_not_written').toList();
      expect(failed, hasLength(1));
      expect(failed.single['stopReason'], 'failed');
      expect(failed.single['docs'], isA<Map>());
      expect(failed.single['designSpec'], isA<Map>());
      expect((failed.single['text'] as String), contains('配色'));
    });

    test('BUILD 无工具调用：nudge 后仍无操作 → done(text_only)（不报 doc_not_written）', () async {
      final events = <Map<String, dynamic>>[];
      final result = await runDartAgent(
        request: DartAgentRequest(
          mode: 'build',
          instruction: '把首页标题改大',
          mbt: '---\nrevision: 1\n---\n# doc',
          docs: const {},
          model: 'm',
          apiKey: 'k',
        ),
        modelOverride: _ScriptedModel([
          [mockText('我先看一下现状。')],
          [mockText('建议直接用 inspector 调整。')],
        ]),
        onEvent: events.add,
      );
      expect(result.ok, isTrue);
      expect(result.stopReason, 'text_only');
      expect(events.any((e) => e['type'] == 'note' && e['label'] == 'NaN 继续执行'), isTrue);
      expect(events.any((e) => e['type'] == 'failed'), isFalse);
      expect(events.last['type'], 'done');
    });
  });

  group('design_op 引擎门（唯一写路径）', () {
    test('提交 → AgentGate 桥调用 + canonical 回写 + ops + preview + state 卡', () async {
      final events = <Map<String, dynamic>>[];
      final gate = _FakeGate();
      final result = await runDartAgent(
        request: DartAgentRequest(
          mode: 'build',
          instruction: '加一个详情页',
          mbt: '---\nrevision: 3\n---\n# doc',
          docs: const {},
          model: 'm',
          apiKey: 'k',
        ),
        modelOverride: _ScriptedModel([
          [mockToolCall(toolName: 'design_op', input: {'op': 'create detail 390 844'})],
          [mockToolCall(toolName: 'finish', input: {'summary': '建了详情页'})],
        ]),
        bridge: gate,
        onEvent: events.add,
      );
      // 桥被调用且收到的是 op 原文（引擎门语义，客户端不拼 mbt）。
      expect(gate.ops, ['create detail 390 844']);
      expect(gate.mbts.single, '---\nrevision: 3\n---\n# doc');
      // canonical 回写（引擎门回传的 mbt 被采纳为唯一事实源）。
      expect(result.mbt, contains('<!-- applied: create detail 390 844 -->'));
      expect(result.ops, ['create detail 390 844']);
      expect(result.remoteCalls, 1);
      // preview 事件（b64 + 单调 seq）。
      final previews = events.where((e) => e['type'] == 'preview').toList();
      expect(previews, hasLength(1));
      expect(previews.single['seq'], 1);
      expect(String.fromCharCodes(base64Decode(previews.single['mbt_b64'] as String)), contains('applied'));
      // tool_end 成功面 + state 卡（rev 从 frontmatter 解析）。
      final toolEnd = events.firstWhere((e) => e['type'] == 'tool_end' && e['tool'] == 'design_op');
      expect(toolEnd['ok'], isTrue);
      // 结果对象本身（工具返回给模型的面）带 state——经 compactEnvelope 剥 mbt。
      expect(events.any((e) => e['type'] == 'done'), isTrue);
      expect(result.stopReason, 'done');
    });

    test('门拒绝（ok:false）→ ops 不追加、canonical 不变、tool_end ok=false', () async {
      final events = <Map<String, dynamic>>[];
      const rejected = 'place home rect x 0 0 100 100';
      final gate = _FakeGate(rejectOps: {rejected});
      final result = await runDartAgent(
        request: DartAgentRequest(
          mode: 'build',
          instruction: '摆放矩形',
          mbt: '---\nrevision: 1\n---\n# doc',
          docs: const {},
          model: 'm',
          apiKey: 'k',
        ),
        modelOverride: _ScriptedModel([
          [mockToolCall(toolName: 'design_op', input: {'op': rejected})],
          [mockToolCall(toolName: 'finish', input: {'summary': '已尝试'})],
        ]),
        bridge: gate,
        onEvent: events.add,
      );
      expect(gate.ops, isEmpty, reason: '拒绝的 op 不进成功记录');
      expect(result.ops, isEmpty);
      expect(result.mbt, '---\nrevision: 1\n---\n# doc', reason: 'canonical 保持原样');
      final toolEnd = events.firstWhere((e) => e['type'] == 'tool_end' && e['tool'] == 'design_op');
      expect(toolEnd['ok'], isFalse);
      expect(toolEnd['error'], contains('mbt_gate_block'));
      expect(events.any((e) => e['type'] == 'preview'), isFalse, reason: '无变更不推 preview');
    });

    test('REFINE 无桥（纯移动端）：design_op → engine_unavailable，文档改写仍可完成', () async {
      final events = <Map<String, dynamic>>[];
      final result = await runDartAgent(
        request: DartAgentRequest(
          mode: 'refine',
          instruction: '把 PRD 的非目标补一条',
          mbt: '---\nrevision: 2\n---\n# doc',
          docs: {'prd': '# PRD\n目标', 'ui': '', 'design': {}},
          model: 'm',
          apiKey: 'k',
        ),
        modelOverride: _ScriptedModel([
          [
            mockToolCall(toolName: 'design_op', input: {'op': 'update home title text=新标题'}),
            mockToolCall(toolName: 'read_docs', input: {'kind': 'prd'}),
          ],
          [
            mockToolCall(toolName: 'write_doc', input: {'kind': 'prd', 'content': '# PRD\n目标\n\n## 非目标\n不做协作'}),
            mockToolCall(toolName: 'finish', input: {'summary': '补了非目标'}),
          ],
        ]),
        bridge: null,
        onEvent: events.add,
      );
      expect(result.ok, isTrue);
      expect(result.remoteCalls, 1, reason: 'engine_unavailable 也计一次远端调用尝试');
      expect(result.docs['prd'], contains('非目标'));
      final toolEnd = events.firstWhere((e) => e['type'] == 'tool_end' && e['tool'] == 'design_op');
      expect(toolEnd['ok'], isFalse);
      expect(toolEnd['error'], 'engine_unavailable');
      // read_docs 不发 tool 事件（server/agent.py 同构：只有 write_doc /
      // design_op / generate_page 显式发 tool_start/tool_end）。
      expect(events.any((e) => e['type'] == 'tool_start' && e['tool'] == 'read_docs'), isFalse);
    });
  });

  group('取消', () {
    test('token 中断在飞请求 → failed(cancelled) / stopReason=cancelled', () async {
      final events = <Map<String, dynamic>>[];
      final token = CancellationToken();
      final runFuture = runDartAgent(
        request: _planReq(instruction: '做一个长任务'),
        modelOverride: _HangingModel(token),
        abortSignal: token,
        onEvent: events.add,
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));
      token.cancel();
      final result = await runFuture;
      expect(result.ok, isFalse);
      expect(result.stopReason, 'cancelled');
      final failed = events.where((e) => e['type'] == 'failed').toList();
      expect(failed, hasLength(1));
      expect(failed.single['error'], 'cancelled');
      expect(failed.single['stopReason'], 'cancelled');
      // 取消后不再有 done / nudge。
      expect(events.any((e) => e['type'] == 'done'), isFalse);
      expect(events.any((e) => e['type'] == 'note' && e['label'] == 'NaN 继续执行'), isFalse);
    });

    test('两轮之间取消：不再进入 nudge 轮（确定性：第二轮挂起探测）', () async {
      final events = <Map<String, dynamic>>[];
      final token = CancellationToken();
      final model = _HangOnSecondRound(token);
      // 等第一轮的 doc_written 落地（确定性同步点，替代 sleep 竞态）。
      final firstDoc = Completer<void>();
      final runFuture = runDartAgent(
        request: _planReq(),
        modelOverride: model,
        abortSignal: token,
        onEvent: (ev) {
          events.add(ev);
          if (ev['type'] == 'doc_written' && !firstDoc.isCompleted) firstDoc.complete();
        },
      );
      await firstDoc.future.timeout(const Duration(seconds: 5));
      token.cancel();
      final result = await runFuture;
      expect(result.stopReason, 'cancelled');
      expect(model.calls, 1, reason: '取消检查先于 nudge：第二轮不应开始');
      expect(events.any((e) => e['type'] == 'note' && e['label'] == 'NaN 继续执行'), isFalse,
          reason: 'run 间隙取消检查先于 nudge');
    });
  });

  group('thinking 方言表对照（server/agent.py:543-547 为权威）', () {
    test('fixture 逐级对照：白名单注入 / 空与 auto / off-on-垃圾值丢弃', () {
      final fixture = jsonDecode(File('test/fixtures/thinking_dialect.json').readAsStringSync()) as Map;
      final cases = fixture['cases'] as Map<String, dynamic>;
      expect(cases, isNotEmpty);
      cases.forEach((level, expected) {
        final want = expected as String?;
        expect(reasoningEffortForLevel(level), want, reason: 'level="$level"');
        final options = thinkingProviderOptions(level);
        if (want == null) {
          expect(options, isNull, reason: 'level="$level" 不应注入 reasoning');
        } else {
          expect(options, {'openai': {'reasoning_effort': want}}, reason: 'level="$level"');
        }
      });
    });
  });

  group('文本工具与信封（server context.py / engine.py 移植）', () {
    test('artboardSection：按引擎标记切板源码段，越界板返回 null', () {
      const mbt = '---\nrevision: 1\n---\n'
          '<!-- moonviz:artboard home -->\n```mbt\nfn visual_home() -> @decl.Prototype {\n  let page = 1\n  page\n}\n```\n'
          '<!-- moonviz:artboard detail -->\n```mbt\nfn visual_detail() -> @decl.Prototype { 2 }\n```\n';
      expect(artboardSection(mbt, 'home'), contains('fn visual_home'));
      expect(artboardSection(mbt, 'detail'), contains('fn visual_detail'));
      expect(artboardSection(mbt, 'nope'), isNull);
      expect(parseRevision(mbt), 1);
    });

    test('compactEnvelope：剥 mbt/render、节点剥 style、data 截 40', () {
      final out = compactEnvelope({
        'ok': true,
        'mbt': 'canonical...',
        'render': {'svg': '<svg/>'},
        'artboards': [
          {
            'id': 'home',
            'svg': '<svg/>',
            'nodes': [
              {'id': 'title', 'style': {'fill': '#fff'}},
            ],
          },
        ],
        'data': List.generate(45, (i) => i),
      });
      expect(out.containsKey('mbt'), isFalse);
      expect(out.containsKey('render'), isFalse);
      final board = (out['artboards'] as List).single as Map;
      expect(board.containsKey('svg'), isFalse);
      expect((board['nodes'] as List).single, {'id': 'title'});
      expect(out['data'], hasLength(40));
      expect(out['data_truncated'], isTrue);
    });

    test('composeDartInstructions：层序与截断（PLAN/BUILD 静态段 + footer）', () {
      final plan = composeDartInstructions(
        mode: 'plan',
        projectMap: '',
        designSpec: const {},
        docs: const {},
        templates: const [],
        components: const [],
      );
      expect(plan, contains('PLAN mode'));
      expect(plan, contains('## PROJECT MAP'));
      expect(plan, contains('(empty project)'));
      expect(plan, contains('(engine registry unavailable)'));
      expect(plan, contains('## Engine facts'));
      final build = composeDartInstructions(
        mode: 'build',
        projectMap: 'PROJECT MAP · x',
        designSpec: const {'v': 1},
        docs: const {'prd': 'P', 'ui': 'U'},
        templates: const [
          {'id': 'pc_app', 'name': 'PC App', 'device': 'pc'},
        ],
        components: const ['button'],
      );
      expect(build, contains('PROJECT MAP · x'));
      expect(build, contains('pc_app(PC App)[pc]'));
      expect(build, contains('PRD (1 chars)'));
      expect(build.startsWith('You are NaN'), isTrue);
      // 列表/条目区域的硬性规范（分割线或 ≥12px 间距、图标文字不压盖、容器内边距）
      // 必须随 BUILD 静态提示词下发，防止生成出来的一整页列表糊成一片。
      expect(build, contains('must read row-by-row'));
      expect(build, contains('icon overlap its label'));
      // autofix 能力必须随 BUILD 提示词下发（迁移前 deepDesign 的「AI 自动修复」，
      // 迁移不能丢）：生成信封 autofix/missing/skipped 的读法、收尾 fix/lint
      // 复核、以及 autofill 补缺入口。
      expect(build, contains('autofix{fixes,detail}'));
      expect(build, contains('autofill <ab>'));
      expect(build, contains('BATCH YOUR TURNS'));
      expect(build, contains('`fix <ab>`'));
      // 页面体检只读面：missing / page_type 必须出现在工具说明里。
      expect(build, contains('missing (what the page type lacks)'));
      expect(dartUserMessage('refine', '改标题'), contains('REFINE the existing document.'));
      expect(dartUserMessage('build', ''), contains('(empty)'));
    });

    test('composeDartInstructions：workspace 模式是精简上下文（不带设计文档/画板地图）', () {
      final out = composeDartInstructions(
        mode: 'workspace',
        projectMap: 'PROJECT MAP · should not appear',
        designSpec: const {'v': 1},
        docs: const {'prd': 'P', 'ui': 'U', 'design': {}},
        templates: const [
          {'id': 'pc_app', 'name': 'PC App', 'device': 'pc'},
        ],
        components: const ['button'],
        hasWorkspaceTools: true,
        workspaceHint: 'three',
      );
      expect(out, contains('WORKSPACE mode'));
      expect(out, contains('## TARGET WORKSPACE'));
      expect(out, contains('mode: three'));
      expect(out, contains('three_create'));
      // 视频「生成有落地」的三件套必须在提示词里：模型要知道先取示例格式、
      // 再落盘、最后对照检查；成片导出不存在也要明说。
      expect(out, contains('video_sample'));
      expect(out, contains('video_create'));
      expect(out, contains('video_list'));
      expect(out, contains('NO video-file export'));
      // 答题卡纪律与常规 agent 循环一致：ask_user 在所有模式可用，钉死
      // 工作台时只对「真要换工作台」用 switch_to。
      expect(out, contains('ask_user works in every run'));
      expect(out, contains('switch_to'));
      expect(out, isNot(contains('ask_user is not available')));
      expect(out, isNot(contains('ask_user_unavailable')));
      expect(out, isNot(contains('## PROJECT MAP')));
      expect(out, isNot(contains('PRD (1 chars)')));
      expect(out, isNot(contains('pc_app(PC App)[pc]')));
      expect(out, contains('## Engine facts'));

      // 没有工作区工具时必须明说，不能让模型假装有工具。
      final none = composeDartInstructions(
        mode: 'workspace',
        projectMap: '',
        designSpec: const {},
        docs: const {},
        templates: const [],
        components: const [],
        hasWorkspaceTools: false,
        workspaceHint: 'video',
      );
      expect(none, contains('this host exposes none'));

      expect(
        dartUserMessage('workspace', '做个场景', workspaceHint: 'three'),
        contains('WORKSPACE: act inside the three workspace'),
      );
      expect(
        dartUserMessage('workspace', '做个场景', workspaceHint: 'three'),
        contains('Do not touch the design canvas.'),
      );
    });
  });

  group('AppSettings.agentRuntime（默认 local / 显式 server）', () {
    test('默认内置本机，与平台无关', () {
      expect(defaultAgentRuntime(), agentRuntimeLocal);
      expect(AppSettings().agentRuntime, agentRuntimeLocal);
    });

    test('toJson/fromJson 往返与容错', () {
      expect(AppSettings.fromJson(AppSettings().toJson()).agentRuntime, agentRuntimeLocal);
      // 旧存档的 dart 等同内置；显式 server（连接桌面）保留。
      expect(AppSettings.fromJson({'agentRuntime': 'dart'}).agentRuntime, agentRuntimeLocal);
      expect(AppSettings.fromJson({'agentRuntime': 'server'}).agentRuntime, agentRuntimeServer);
      // 旧存档无键 → 默认 local；未知值静默回落 local，绝不当成远程。
      expect(AppSettings.fromJson({}).agentRuntime, defaultAgentRuntime());
      expect(AppSettings.fromJson({'agentRuntime': 'bogus'}).agentRuntime, agentRuntimeLocal);
      // 赋值同样归一：未知值不留在存档里。
      final s = AppSettings()..agentRuntime = 'bogus';
      expect(s.agentRuntime, agentRuntimeLocal);
      s.agentRuntime = agentRuntimeServer;
      expect(s.toJson()['agentRuntime'], agentRuntimeServer);
    });
  });

  group('BUILD 全链（design_op 引擎门 + 检视路由）', () {
    /// 汇总模型收到的全部工具结果文本（tool result 回喂面断言用）。
    String toolResultsText(MockLanguageModelV4 model) {
      final buf = StringBuffer();
      for (final call in model.streamCalls) {
        for (final msg in call.prompt.messages) {
          for (final part in msg.content) {
            if (part is LanguageModelV4ToolResultPart) {
              final out = part.output;
              if (out is ToolResultOutputText) {
                buf.write(out.text);
              } else if (out is ToolResultOutputJson) {
                buf.write(out.value.toString());
              }
            }
          }
        }
      }
      return buf.toString();
    }

    test('design_op canonical 线程化 + inspect/read_mbt/list_* 路由 + state 卡回喂', () async {
      const mbt0 = '---\nrevision: 1\n---\n# doc';
      final gate = _FakeGate(canonical: mbt0);
      final events = <Map<String, dynamic>>[];
      final model = _ScriptedModel([
        [mockToolCall(toolName: 'design_op', input: {'op': 'create home 390 844'})],
        [mockToolCall(toolName: 'design_op', input: {'op': 'place home text t1 10 10 100 30'})],
        [mockToolCall(toolName: 'inspect', input: {'kind': 'critique', 'artboard': 'home'})],
        [mockToolCall(toolName: 'read_mbt', input: {})],
        [mockToolCall(toolName: 'read_mbt', input: {'artboard': 'home'})],
        [mockToolCall(toolName: 'list_templates', input: {})],
        [mockToolCall(toolName: 'list_components', input: {})],
        [mockToolCall(toolName: 'read_docs', input: {'kind': 'prd'})],
        [mockToolCall(toolName: 'finish', input: {'summary': '首页成型'})],
      ]);
      final result = await runDartAgent(
        request: DartAgentRequest(
          mode: 'build',
          instruction: '搭一个首页',
          mbt: mbt0,
          docs: const {'prd': '# PRD\n目标：记账', 'ui': '', 'design': {}},
          model: 'm',
          apiKey: 'k',
        ),
        modelOverride: model,
        bridge: gate,
        onEvent: events.add,
      );
      expect(result.ok, isTrue, reason: '全链跑通 → done（无 nudge：remoteCalls>0）');
      expect(result.stopReason, 'done');
      expect(events.any((e) => e['type'] == 'note' && e['label'] == 'NaN 继续执行'), isFalse);

      // canonical 线程化：第二条 op 的基底必须是第一条回传的 canonical。
      expect(gate.ops, ['create home 390 844', 'place home text t1 10 10 100 30']);
      expect(gate.mbts[0], mbt0);
      expect(gate.mbts[1], contains('applied: create home 390 844'));
      expect(result.mbt, gate.canonical);
      expect(result.ops, gate.ops);

      // 检视路由：inspect(critique) → session_critique(artboard)；
      // read_mbt outline → list_artboards + flows（+逐板 query_nodes）。
      expect(gate.sessionNames.contains('session_critique'), isTrue);
      expect(gate.sessionArgs[gate.sessionNames.indexOf('session_critique')], 'home');
      expect(gate.sessionNames.contains('session_list_artboards'), isTrue);
      expect(gate.sessionNames.contains('session_flows'), isTrue);
      expect(gate.sessionNames.contains('session_query_nodes'), isTrue);
      // 注册表路由：run 起点合成 instructions 取一次 + list_* 工具各一次（≥2）。
      expect(gate.templatesCalls, greaterThanOrEqualTo(2));
      expect(gate.componentsCalls, greaterThanOrEqualTo(2));

      // 单板源码段（本地切）真的回喂给了模型：read_mbt(home) 的结果含板源码。
      final fed = toolResultsText(model);
      expect(fed, contains('fn visual_home'), reason: 'read_mbt(artboard) 本地段回喂模型');
      expect(fed, contains('pc_app'), reason: 'list_templates 注册表回喂模型');
      expect(fed, contains('# PRD'), reason: 'read_docs 回喂模型');
      // state 卡（rev=1 boards=[home:3] flows=1）随 design_op 结果回喂。
      expect(fed, contains('rev=1'), reason: 'design_op 结果携带 state 卡');
      expect(fed, contains('boards=[home:3]'));

      // preview 单调序号：两次成功提交各一帧。
      final seqs = events
          .where((e) => e['type'] == 'preview')
          .map((e) => e['seq'])
          .toList();
      expect(seqs, [1, 2]);

      // inspect 结果回喂 critique 面（verdict 形状与 server 信封一致）。
      expect(fed, contains('contrast'));
    });

    test('inspect 面守门：缺 artboard → artboard_required；未知 kind → unknown_inspect_kind', () async {
      const mbt0 = '---\nrevision: 1\n---\n# doc';
      final gate = _FakeGate(canonical: mbt0);
      final model = _ScriptedModel([
        [
          mockToolCall(toolName: 'inspect', input: {'kind': 'critique'}),
          mockToolCall(toolName: 'inspect', input: {'kind': 'bogus_kind'}),
          mockToolCall(toolName: 'read_mbt', input: {'artboard': 'nope'}),
        ],
        [mockToolCall(toolName: 'finish', input: {'summary': '校验完'})],
      ]);
      final result = await runDartAgent(
        request: DartAgentRequest(
          mode: 'build',
          instruction: 'x',
          mbt: mbt0,
          docs: const {},
          model: 'm',
          apiKey: 'k',
        ),
        modelOverride: model,
        bridge: gate,
        onEvent: (_) {},
      );
      expect(result.ok, isTrue);
      // 三个错误信封都回喂给了模型（错误即文档，server 同构）。
      final fed = toolResultsText(model);
      expect(fed, contains('artboard_required'));
      expect(fed, contains('unknown_inspect_kind:bogus_kind'));
      expect(fed, contains('unknown_artboard:nope'));
      // 守门路径零引擎调用（critique 缺板被本地拦下）。
      expect(gate.sessionNames.contains('session_critique'), isFalse);
    });

    test('inspect 面补齐页面体检：missing/page_type 路由到引擎只读会话面', () async {
      const mbt0 = '---\nrevision: 1\n---\n# doc';
      final gate = _FakeGate(canonical: mbt0);
      final model = _ScriptedModel([
        [
          mockToolCall(toolName: 'inspect', input: {'kind': 'missing', 'artboard': 'home'}),
          mockToolCall(toolName: 'inspect', input: {'kind': 'page_type', 'artboard': 'home'}),
        ],
        [mockToolCall(toolName: 'finish', input: {'summary': '查缺完成'})],
      ]);
      final result = await runDartAgent(
        request: DartAgentRequest(
          mode: 'build',
          instruction: 'x',
          mbt: mbt0,
          docs: const {},
          model: 'm',
          apiKey: 'k',
        ),
        modelOverride: model,
        bridge: gate,
        onEvent: (_) {},
      );
      expect(result.ok, isTrue);
      // 迁移前 deepDesign 的 missing <ab> / 页型判定（查缺 → autofill 的前置）：
      // 只读 session 面，绝不进写门（ops 为空）。
      expect(gate.sessionNames, contains('session_infer_missing'));
      expect(gate.sessionNames, contains('session_infer_page_type'));
      expect(gate.ops, isEmpty);
    });
  });
}
