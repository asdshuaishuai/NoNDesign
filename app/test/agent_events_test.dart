// store 侧事件消费锚点（P1 新增事件）：内置 Dart 循环收尾的 review_round
// （RSI 修复轮）与 cleanup（空板清扫）必须同时进时间线与聊天进度卡。
//
// 驱动方式：真实 AppStore + 伪造 api（NoNDesignApi 子类，只覆写循环用到的
// 五个方法）+ scripted 模型；走 sendChat 的聊天流路径（_chatCard 才存在，
// cleanup 的聊天卡分支才有可能被覆盖）。断言同时覆盖「store.mbt 与循环
// ctx.mbt 锁步」——清扫/修复的 canonical 必须被 store 采纳，否则后续 op
// 会以陈旧文档提交。
import 'dart:convert';
import 'dart:io';

import 'package:ai_sdk_dart/test.dart';
// ai_sdk_provider 是 ai_sdk_dart 的传递依赖（pubspec 未声明）；scripted mock
// 需要其流片段/工具类型来覆写 doStream。
// ignore: depend_on_referenced_packages
import 'package:ai_sdk_provider/ai_sdk_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nondesign/core/api.dart';
import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/store.dart';

/// 多轮脚本化模型：每次 doStream 依序取下一步响应；脚本耗尽回纯文本。
class _ScriptedModel extends MockLanguageModelV4 {
  final List<List<LanguageModelV4ContentPart>> script;
  int _i = 0;
  _ScriptedModel(this.script) : super(provider: 'scripted', modelId: 'scripted-model');

  @override
  Future<LanguageModelV4StreamResult> doStream(LanguageModelV4CallOptions options) async {
    streamCalls.add(options);
    final step = _i < script.length ? script[_i++] : <LanguageModelV4ContentPart>[mockText('done')];
    var seq = 0;
    final parts = <LanguageModelV4StreamPart>[const StreamPartStreamStart(warnings: [])];
    for (final part in step) {
      if (part is LanguageModelV4ToolCallPart) {
        parts.add(StreamPartToolInputStart(id: 't$seq', toolName: part.toolName));
        parts.add(StreamPartToolInputDelta(id: 't$seq', delta: jsonEncode(part.input)));
        parts.add(StreamPartToolInputEnd(id: 't$seq'));
        parts.add(StreamPartToolCall(toolCall: part));
      }
      seq++;
    }
    parts.add(const StreamPartFinish(
      finishReason: LanguageModelV4FinishReason.stop,
      rawFinishReason: 'stop',
    ));
    return LanguageModelV4StreamResult(stream: Stream.fromIterable(parts));
  }
}

/// 伪造 api：只覆写内置循环消费的五条路径（session/apply/render/templates/
/// components）。引擎语义按真实信封形状回：变更信封带 canonical，检视
/// 信封带 data。critique 首轮 poor、auto_fix 后转 good（锚定 2 轮内收敛）。
class _FakeApi extends NoNDesignApi {
  _FakeApi(String mbt0)
      : canonical = mbt0,
        super('http://127.0.0.1:9');

  String canonical;
  List<Map<String, dynamic>> boards = [
    {'id': 'home', 'nodes': 3},
    {'id': '__seed', 'nodes': 1},
  ];
  String verdict = 'poor';
  final List<String> sessionNames = [];
  final List<String?> sessionArgs = [];
  final List<String> renderCalls = [];
  final List<String> generateMbts = [];
  final List<String> generateIntents = [];
  final List<Map<String, dynamic>> generateSpecs = [];

  @override
  Future<Map<String, dynamic>> generate(
      String mbt, String intent, String name, Map<String, dynamic> spec) async {
    generateMbts.add(mbt);
    generateIntents.add(intent);
    generateSpecs.add(spec);
    canonical = '$mbt\n<!-- generated: $intent -->';
    final artboard = name.isNotEmpty ? name : 'generated';
    return {
      'ok': true,
      'mbt': canonical,
      'artboard': artboard,
      'template': 'pc_app',
      'score': 90.0,
      'summary': '整屏生成',
    };
  }

  @override
  Future<Map<String, dynamic>> session(String mbt, String name, [String? arg]) async {
    sessionNames.add(name);
    sessionArgs.add(arg);
    switch (name) {
      case 'session_list_artboards':
        return {
          'ok': true,
          'data': [
            for (final b in boards)
              {'id': b['id'], 'nodes': b['nodes'], 'width': 390, 'height': 844},
          ],
        };
      case 'session_flows':
        return {'ok': true, 'data': []};
      case 'session_query_nodes':
        return {'ok': true, 'data': []};
      case 'session_critique':
        return {
          'ok': true,
          'data': {
            'results': [
              {
                'principle': 'contrast',
                'score': verdict == 'poor' ? 1 : 5,
                'verdict': verdict,
                'observation': 'x',
                'advice': '',
              },
            ],
          },
        };
      case 'session_auto_fix':
        verdict = 'good';
        canonical = '$mbt\n<!-- fixed: $arg -->';
        return {'ok': true, 'mbt': canonical};
      case 'session_apply_agent':
        final op = (arg ?? '').toString();
        if (op.startsWith('delete-artboard ')) {
          final bid = op.substring('delete-artboard '.length);
          boards = boards.where((b) => b['id'] != bid).toList();
          canonical = '$mbt\n<!-- deleted: $bid -->';
          return {'ok': true, 'mbt': canonical};
        }
        return {'ok': false, 'error': 'unsupported_op'};
    }
    return {'ok': true, 'data': []};
  }

  @override
  Future<Map<String, dynamic>> apply(String mbt, String op, {String gate = 'human'}) async {
    canonical = '$mbt\n<!-- applied: $op -->';
    return {'ok': true, 'mbt': canonical, 'op': op, 'gate': gate};
  }

  @override
  Future<Map<String, dynamic>> render(String mbt) async {
    renderCalls.add(mbt);
    return {
      'ok': true,
      'mbt': mbt,
      'revision': 1,
      'entry': 'home',
      'artboards': [
        {'id': 'home', 'width': 390, 'height': 844, 'nodes': <dynamic>[]},
      ],
      'flows': <dynamic>[],
    };
  }

  @override
  Future<List<dynamic>> templates() async => const [];

  @override
  Future<List<dynamic>> components() async => const [];
}

const String _mbt0 = '---\nrevision: 1\nentry: home\n---\n# doc';

void main() {
  test('dart 循环收尾事件：review_round + cleanup 同时进时间线与聊天卡，canonical 锁步',
      () async {
    final dir = Directory.systemTemp.createTempSync('nondesign-agent-events-');
    final store = AppStore();
    final api = _FakeApi(_mbt0);
    store.recoveryDir = dir.path;
    store.api = api;
    store.settings.agentRuntime = agentRuntimeDart;
    store.settings.apiKey = 'k';
    store.settings.baseUrl = 'http://127.0.0.1:9/v1';
    store.hasProject = true;
    store.projectName = 'demo';
    store.mbt = _mbt0;
    // 已有文档 → sendChat 直接走 BUILD（fresh=false），并建立聊天进度卡。
    store.docs = Docs(prd: '# PRD', ui: '## UI');
    store.debugAgentModelOverride = _ScriptedModel([
      [
        mockToolCall(toolName: 'design_op', input: {'op': 'create home 390 844'}),
      ],
      [mockToolCall(toolName: 'finish', input: {'summary': '首页已生成'})],
    ]);

    try {
      final ok = await store.sendChat('搭一个记账首页');
      expect(ok, isTrue, reason: 'done 终态 → run 成功');

      // 时间线：review_round → 「质量审查 · 第N轮」note；cleanup → 「清理空画板 …」。
      final notes = store.timeline.where((t) => t.kind == 'note').toList();
      final review = notes.where((t) => (t.title ?? '').contains('质量审查')).toList();
      expect(review, hasLength(1), reason: '第 1 轮 poor → 1 条时间线条目；第 2 轮收敛不再发');
      expect(review.single.title, '质量审查 · 第1轮');
      expect(review.single.text, contains('home:1项poor'));
      final cleaned = notes.where((t) => (t.title ?? '').contains('清理空画板')).toList();
      expect(cleaned, hasLength(1));
      expect(cleaned.single.title, contains('__seed'));

      // 聊天进度卡：review_round / cleanup 的镜像步骤。
      final card = store.chatMessages.firstWhere((m) => m.kind == chatKindProgress);
      final reviewStep = card.steps.where((s) => s.label.contains('质量审查')).toList();
      expect(reviewStep, hasLength(1));
      expect(reviewStep.single.label, '质量审查 第1轮');
      expect(reviewStep.single.detail, contains('home:1项poor'));
      final cleanStep = card.steps.where((s) => s.label.contains('清理空画板')).toList();
      expect(cleanStep, hasLength(1));
      expect(cleanStep.single.label, '清理空画板 __seed');

      // 锁步：清扫与 auto_fix 的 canonical 都被 store 采纳（后续 op 不会用旧文档）。
      expect(api.sessionNames, contains('session_apply_agent'));
      expect(api.sessionNames, contains('session_auto_fix'));
      expect(api.sessionArgs[api.sessionNames.indexOf('session_apply_agent')],
          'delete-artboard __seed');
      expect(api.sessionArgs[api.sessionNames.indexOf('session_auto_fix')], 'home');
      expect(store.mbt, contains('<!-- applied: create home 390 844 -->'));
      expect(store.mbt, contains('<!-- deleted: __seed -->'));
      expect(store.mbt, contains('<!-- fixed: home -->'));
      // 终态 done 的 render 采纳也发生（画面上有 home 板）。
      expect(api.renderCalls, isNotEmpty);
      expect(store.render.artboards.map((b) => b.id), contains('home'));
    } finally {
      store.dispose();
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  test('generate_page 经 store 桥：generate → render → _commit，store.mbt 与循环锁步', () async {
    final dir = Directory.systemTemp.createTempSync('nondesign-agent-generate-');
    final store = AppStore();
    final api = _FakeApi(_mbt0)..boards = [
      {'id': 'home', 'nodes': 3},
    ];
    api.verdict = 'good'; // 本用例只锚生成链路，不让 RSI 介入
    store.recoveryDir = dir.path;
    store.api = api;
    store.settings.agentRuntime = agentRuntimeDart;
    store.settings.apiKey = 'k';
    store.settings.baseUrl = 'http://127.0.0.1:9/v1';
    store.hasProject = true;
    store.projectName = 'demo';
    store.mbt = _mbt0;
    store.docs = Docs(prd: '# PRD', ui: '## UI');
    store.debugAgentModelOverride = _ScriptedModel([
      [
        mockToolCall(toolName: 'generate_page', input: {
          'intent': '登录首页',
          'name': 'home',
        }),
      ],
      [mockToolCall(toolName: 'finish', input: {'summary': '首页生成'})],
    ]);

    try {
      final ok = await store.sendChat('生成登录首页');
      expect(ok, isTrue);

      // 链内读新鲜 mbt（applyGeneratePage 不用入参）；spec 缺省取 ctx.designSpec。
      expect(api.generateMbts.single, _mbt0);
      expect(api.generateIntents.single, '登录首页');
      expect(api.generateSpecs.single['palette'], isA<Map>());
      // render + _commit 采纳：store.mbt 终态 == 循环 ctx.mbt（生成信封 canonical）。
      final canonical = '$_mbt0\n<!-- generated: 登录首页 -->';
      expect(api.renderCalls, contains(canonical), reason: '生成后必须 render 拿 RenderEnvelope');
      expect(store.mbt, canonical);
      expect(store.render.artboards.map((b) => b.id), contains('home'));

      // page_generated 同时进时间线与聊天卡（既有镜像分支 + 时间线分支）。
      expect(
        store.timeline.any((t) => t.kind == 'note' && (t.title ?? '') == '生成画板 home'),
        isTrue,
      );
      final card = store.chatMessages.firstWhere((m) => m.kind == chatKindProgress);
      expect(card.steps.any((s) => s.label == '生成画板 home'), isTrue);
    } finally {
      store.dispose();
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });
}
