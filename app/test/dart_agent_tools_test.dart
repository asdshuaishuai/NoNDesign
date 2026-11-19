// 内置智能体工具面锚点测试（批次 09）。
//
// 覆盖：
//  * 工具名全部经 toolLabel() 映射（不泄漏 snake_case 代码代号）；
//  * 失败结果按错误码映射（engine_unavailable / mbt_gate_block /
//    render_failed / download_failed / sha256_mismatch /
//    nonapp_unsupported_version …）；
//  * LocalEngineGate：design_op 走 AgentGate（gate='agent'），未就绪时
//    engine_unavailable，render 面供 Figma 导出；
//  * mock LLM 的 build 全链：design_op → read_mbt 分层 → generate_page →
//    critique → auto_fix（≤2 轮）→ 空板清扫；
//  * 工作区工具接线：three_* / hotapp_* / video_* / nonapp_* / figma_export
//    （服务信封形状与失败消息）；
//  * Figma 导出：本地逐板 SVG + manifest、节点 cap、不可见过滤、文件名清洗、
//    移动端明示不可用。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ai_sdk_dart/test.dart';
// ai_sdk_provider 是 ai_sdk_dart 的传递依赖；scripted mock 需要其流片段类型。
// ignore: depend_on_referenced_packages
import 'package:ai_sdk_provider/ai_sdk_provider.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nondesign/core/api.dart';
import 'package:nondesign/core/capability.dart';
import 'package:nondesign/core/dart_agent.dart';
import 'package:nondesign/core/figma_export.dart';
import 'package:nondesign/core/hotapp_service.dart' show PrototypeLinkSpec, PrototypeScreenSpec;
import 'package:nondesign/core/models.dart';

/// 多轮脚本化模型（与 dart_agent_test 的 _ScriptedModel 同构）。
class _ScriptedModel extends MockLanguageModelV4 {
  _ScriptedModel(this.script) : super(provider: 'scripted', modelId: 'scripted-model');

  final List<List<LanguageModelV4ContentPart>> script;
  final List<LanguageModelV4CallOptions> calls = <LanguageModelV4CallOptions>[];
  int _index = 0;

  @override
  Future<LanguageModelV4StreamResult> doStream(LanguageModelV4CallOptions options) async {
    calls.add(options);
    final step = _index < script.length
        ? script[_index++]
        : <LanguageModelV4ContentPart>[mockText('done')];
    var seq = 0;
    String nextId() => 'id-${seq++}';
    final parts = <LanguageModelV4StreamPart>[const StreamPartStreamStart(warnings: [])];
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

/// 进程内假引擎：实现 [LocalEngine]，只记录调用与返回固定信封。
class _FakeEngine implements LocalEngine {
  _FakeEngine({this.ready = true});

  bool ready;

  final List<String> gates = <String>[];
  int applyCount = 0;
  int generateCount = 0;
  int autoFixCount = 0;
  final Map<String, int> autoFixPerBoard = <String, int>{};
  int deleteCount = 0;

  String mbt = '---\nmoonviz:\n  format: visual-document\n  revision: 1\n  entry: home\n---\n\n'
      '# home\n\n<!-- moonviz:artboard home -->\n```mbt\nfn visual_home() -> @decl.Prototype {\n'
      '  let page = @decl.prototype(name="home", width=390.0, height=844.0)\n  page\n}\n```\n';

  final List<Map<String, dynamic>> boards = <Map<String, dynamic>>[
    <String, dynamic>{'id': 'home', 'width': 390, 'height': 844, 'nodes': 5},
    <String, dynamic>{'id': '__seed', 'width': 24, 'height': 24, 'nodes': 0},
    <String, dynamic>{'id': 'empty', 'width': 390, 'height': 844, 'nodes': 1},
  ];

  /// session_flows 返回的跳转清单（默认空；from-prototype 测试会注入）。
  List<Map<String, dynamic>> flows = <Map<String, dynamic>>[];

  @override
  bool get isReady => ready;

  @override
  String? get startupError => ready ? null : 'not started';

  @override
  CapabilityAvailability probeAvailability() => CapabilityAvailability(
        id: CapabilityId.localDesignEngine,
        state: ready ? CapabilityState.available : CapabilityState.unavailable,
      );

  @override
  Future<Map<String, dynamic>> render(String mbt) async => <String, dynamic>{
        'ok': true,
        'revision': 1,
        'entry': 'home',
        'mbt': mbt,
        'artboards': <dynamic>[
          <String, dynamic>{
            'id': 'home',
            'name': '首页',
            'width': 390,
            'height': 844,
            'background': '#FFFFFF',
            'svg': '<svg xmlns="http://www.w3.org/2000/svg"></svg>',
            'nodes': <dynamic>[
              <String, dynamic>{
                'id': 'title',
                'kind': 'text',
                'component': 'body_text',
                'text': '你好',
                'rect': <String, dynamic>{'x': 20, 'y': 40, 'w': 120, 'h': 24},
                'style': <String, dynamic>{
                  'fill': '#FFFFFF',
                  'text_color': '#111827',
                  'font_size': 16,
                  'radius': 4,
                  'opacity': 1,
                  'visible': true,
                },
              },
            ],
          },
        ],
        'flows': <dynamic>[],
      };

  @override
  Future<Map<String, dynamic>> validate(String mbt) async => <String, dynamic>{'ok': true};

  @override
  Future<Map<String, dynamic>> apply(String mbt, String op, {String gate = 'human'}) async {
    gates.add(gate);
    applyCount += 1;
    if (op.contains('gate_me')) {
      return <String, dynamic>{
        'ok': false,
        'error': 'mbt_gate_block',
        'detail': 'no_sibling_overlap',
      };
    }
    this.mbt = '$mbt<!-- op:$op -->\n';
    return <String, dynamic>{'ok': true, 'mbt': this.mbt};
  }

  @override
  Future<Map<String, dynamic>> session(String mbt, String name, [String? arg]) async {
    switch (name) {
      case 'session_list_artboards':
        return <String, dynamic>{
          'ok': true,
          'data': boards.map((b) => Map<String, dynamic>.from(b)).toList(),
        };
      case 'session_flows':
        return <String, dynamic>{'ok': true, 'data': flows.map((f) => Map<String, dynamic>.from(f)).toList()};
      case 'session_query_nodes':
        return <String, dynamic>{
          'ok': true,
          'data': <dynamic>[
            <String, dynamic>{'id': 'title'},
            <String, dynamic>{'id': 'cta'},
          ],
        };
      case 'session_critique':
        return <String, dynamic>{
          'ok': true,
          'data': <String, dynamic>{
            'results': <dynamic>[
              <String, dynamic>{'principle': 'hierarchy', 'score': 2, 'verdict': 'poor'},
            ],
          },
        };
      case 'session_auto_fix':
        autoFixCount += 1;
        autoFixPerBoard[arg ?? ''] = (autoFixPerBoard[arg ?? ''] ?? 0) + 1;
        this.mbt = '$mbt<!-- autofix -->\n';
        return <String, dynamic>{'ok': true, 'mbt': this.mbt};
      case 'session_apply_agent':
        final op = arg ?? '';
        if (op.startsWith('delete-artboard ')) {
          deleteCount += 1;
          final id = op.substring('delete-artboard '.length).trim();
          boards.removeWhere((b) => b['id'] == id);
          this.mbt = '$mbt<!-- delete $id -->\n';
          return <String, dynamic>{'ok': true, 'mbt': this.mbt};
        }
        return <String, dynamic>{'ok': true, 'mbt': this.mbt};
      default:
        return <String, dynamic>{'ok': true, 'data': <dynamic>[]};
    }
  }

  @override
  Future<Map<String, dynamic>> generate(
    String mbt,
    String intent,
    String name,
    Map<String, dynamic> spec,
  ) async {
    generateCount += 1;
    boards.add(<String, dynamic>{'id': name, 'width': 390, 'height': 844, 'nodes': 4});
    this.mbt = '$mbt<!-- generate:$name -->\n';
    return <String, dynamic>{
      'ok': true,
      'mbt': this.mbt,
      'artboard': name,
      'template': 'mobile_app',
      'score': 88,
      'summary': intent,
    };
  }

  @override
  Future<Map<String, dynamic>> tap(String mbt, String artboard, double x, double y) async =>
      <String, dynamic>{'ok': true, 'data': <String, dynamic>{}};

  @override
  Future<Map<String, dynamic>> constrainIntent(
          String mbt, String artboard, String intent) async =>
      <String, dynamic>{'ok': true, 'mbt': mbt};

  @override
  Future<Map<String, dynamic>> event(String mbt, String artboard, String spec) async =>
      <String, dynamic>{'ok': true, 'mbt': mbt};

  @override
  Future<Map<String, dynamic>> history(String mbt, String command) async =>
      <String, dynamic>{'ok': true};

  @override
  Future<Map<String, dynamic>> exportHtml(String mbt) async =>
      <String, dynamic>{'ok': true, 'html': '<html></html>'};

  @override
  Future<Map<String, dynamic>> tokens() async => <String, dynamic>{'ok': true};

  @override
  Future<Map<String, dynamic>> versionInfo() async =>
      <String, dynamic>{'ok': true, 'engine': 'fake'};

  @override
  Future<List<dynamic>> templates() async =>
      <dynamic>[<String, dynamic>{'id': 'mobile_app', 'name': 'Mobile', 'device': 'mobile'}];

  @override
  Future<List<dynamic>> components() async => <dynamic>['button', 'body_text'];

  @override
  Future<List<dynamic>> themes() async => <dynamic>[];

  @override
  Future<List<dynamic>> ops() async => <dynamic>[];
}

/// 记录调用的假工作区服务。
class _FakeWorkspace implements AgentWorkspaceServices {
  final List<String> calls = <String>[];
  Map<String, dynamic> nonAppInspectResult = <String, dynamic>{
    'ok': true,
    'app': 'counter',
  };
  RenderEnvelope? lastRender;
  String? lastDirectory;

  @override
  Future<Map<String, dynamic>> threeList() async {
    calls.add('three_list');
    return <String, dynamic>{'ok': true, 'scenes': <dynamic>[]};
  }

  @override
  Future<Map<String, dynamic>> threeCreate({
    required String name,
    required String brief,
  }) async {
    calls.add('three_create:$name');
    return <String, dynamic>{'ok': true, 'scene': name};
  }

  @override
  Future<Map<String, dynamic>> threeStatus(String name) async {
    calls.add('three_status:$name');
    return <String, dynamic>{'ok': true, 'scene': name, 'current': 'spec'};
  }

  @override
  Future<Map<String, dynamic>> threePass(String name) async {
    calls.add('three_pass:$name');
    return <String, dynamic>{'ok': true, 'pass': 'spec', 'chars': 120};
  }

  @override
  Future<Map<String, dynamic>> threeContinue(String name, [String summary = '']) async {
    calls.add('three_continue:$name');
    return <String, dynamic>{'ok': true, 'current': 'scene', 'done': false};
  }

  @override
  Future<Map<String, dynamic>> threeFeedback({
    required String name,
    required String kind,
    required Object? payload,
  }) async {
    calls.add('three_feedback:$name:$kind');
    return <String, dynamic>{'ok': true, 'status': 'failed', 'attempts': 1};
  }

  @override
  Future<Map<String, dynamic>> hotAppList() async {
    calls.add('hotapp_list');
    return <String, dynamic>{'ok': true, 'apps': <dynamic>[]};
  }

  @override
  Future<Map<String, dynamic>> hotAppGenerate({
    required String name,
    required String brief,
  }) async {
    calls.add('hotapp_generate:$name');
    return <String, dynamic>{'ok': true, 'app': name, 'bytes': 100};
  }

  @override
  Future<Map<String, dynamic>> hotAppRefine({
    required String name,
    required String instruction,
  }) async {
    calls.add('hotapp_refine:$name');
    return <String, dynamic>{'ok': true, 'app': name, 'bytes': 120};
  }

  @override
  Future<Map<String, dynamic>> hotAppInspect(String name) async {
    calls.add('hotapp_inspect:$name');
    return <String, dynamic>{'ok': true, 'app': name};
  }

  List<PrototypeScreenSpec>? lastFromPrototypeScreens;
  List<PrototypeLinkSpec>? lastFromPrototypeFlows;
  String? lastFromPrototypeMbt;
  bool fromPrototypeVerified = true;

  @override
  Future<Map<String, dynamic>> hotAppFromPrototype({
    required String name,
    required String prototypeMbt,
    required List<PrototypeScreenSpec> screens,
    required List<PrototypeLinkSpec> flows,
  }) async {
    calls.add('hotapp_from_prototype:$name');
    lastFromPrototypeScreens = screens;
    lastFromPrototypeFlows = flows;
    lastFromPrototypeMbt = prototypeMbt;
    return <String, dynamic>{
      'ok': true,
      'app': name,
      'bytes': 140,
      'screens': screens.length,
      'flows': flows.length,
      'verified': fromPrototypeVerified,
    };
  }

  @override
  Future<Map<String, dynamic>> videoReview({
    required Map<String, dynamic> timeline,
    Map<String, dynamic>? spec,
  }) async {
    calls.add('video_review');
    return <String, dynamic>{'ok': true, 'summary': '对照检查通过', 'problems': <dynamic>[]};
  }

  @override
  Future<Map<String, dynamic>> videoRender({
    required Map<String, dynamic> timeline,
    Map<String, dynamic>? spec,
  }) async {
    calls.add('video_render');
    return <String, dynamic>{'ok': true, 'job': 'job-1'};
  }

  @override
  Future<Map<String, dynamic>> nonAppList() async {
    calls.add('nonapp_list');
    return <String, dynamic>{'ok': true, 'apps': <dynamic>[]};
  }

  @override
  Future<Map<String, dynamic>> nonAppInspect(String name) async {
    calls.add('nonapp_inspect:$name');
    return nonAppInspectResult;
  }

  @override
  Future<Map<String, dynamic>> figmaExport({
    required RenderEnvelope render,
    required String directory,
  }) async {
    calls.add('figma_export');
    lastRender = render;
    lastDirectory = directory;
    return <String, dynamic>{'ok': true, 'boards': render.artboards.length, 'dir': directory};
  }
}

DartAgentRequest _buildRequest(_FakeEngine engine) => DartAgentRequest(
      mode: 'build',
      instruction: '做原型',
      mbt: engine.mbt,
      model: 'scripted-model',
      baseUrl: 'https://example.invalid/v1',
      apiKey: 'k',
    );

Map<String, dynamic> _node({
  required String id,
  bool visible = true,
  String kind = 'rect',
  String text = '',
}) =>
    <String, dynamic>{
      'id': id,
      'kind': kind,
      'component': kind == 'text' ? 'body_text' : 'card',
      'text': text,
      'rect': <String, dynamic>{'x': 1, 'y': 2, 'w': 30, 'h': 40},
      'style': <String, dynamic>{
        'fill': '#FFFFFF',
        'text_color': '#111827',
        'font_size': 14,
        'radius': 8,
        'opacity': 1,
        'visible': visible,
      },
    };

RenderEnvelope _renderEnvelope({String boardId = 'home', List<Map<String, dynamic>>? nodes}) =>
    RenderEnvelope.fromJson(<String, dynamic>{
      'ok': true,
      'revision': 1,
      'entry': boardId,
      'artboards': <dynamic>[
        <String, dynamic>{
          'id': boardId,
          'name': '首页',
          'width': 390,
          'height': 844,
          'background': '#FFFFFF',
          'svg': '<svg xmlns="http://www.w3.org/2000/svg"></svg>',
          'nodes': nodes ?? <dynamic>[_node(id: 'title', kind: 'text', text: '你好')],
        },
      ],
      'flows': <dynamic>[],
    });

void main() {
  group('copy mapping', () {
    test('toolLabel 覆盖全部工具与家族，未知回落人话', () {
      const mapping = <String, String>{
        'design_op': '设计变更',
        'read_mbt': '读取设计稿',
        'inspect': '检查',
        'generate_page': '生成页面',
        'write_doc': '撰写文档',
        'write_design_spec': '更新设计规范',
        'ask_user': '向你确认',
        'three_create': '3D 场景 · 新建',
        'hotapp_refine': '热应用 · 精修',
        'video_review': '视频 · 对照检查',
        'nonapp_list': '应用包',
        'figma_export': '导出 Figma 包',
      };
      mapping.forEach((tool, label) => expect(toolLabel(tool), label, reason: tool));
      expect(toolLabel('three_future_tool'), '3D 场景');
      expect(toolLabel('hotapp_future_tool'), '热应用');
      expect(toolLabel('video_future_tool'), '视频');
      expect(toolLabel('nonapp_future_tool'), '应用包');
      expect(toolLabel('mystery_tool'), '智能体操作');
      // 任何工具标签都不许是裸 snake_case 代号。
      final bare = RegExp(r'^[a-z0-9]+(_[a-z0-9]+)+$');
      for (final tool in <String>[
        ...mapping.keys,
        'three_future_tool',
        'hotapp_future_tool',
        'video_future_tool',
        'nonapp_future_tool',
        'mystery_tool',
      ]) {
        expect(bare.hasMatch(toolLabel(tool)), isFalse, reason: tool);
      }
    });

    test('toolFailureMessage 按错误码映射（含复合码与未知码）', () {
      expect(toolFailureMessage('engine_unavailable'), '设计服务暂时不可用，请稍后重试');
      expect(toolFailureMessage('mbt_gate_block'), '这次改动未通过设计校验');
      expect(toolFailureMessage('render_failed'), '预览生成失败');
      expect(toolFailureMessage('download_failed'), '模型下载失败');
      expect(toolFailureMessage('sha256_mismatch'), '模型文件校验失败，已删除，请重试');
      expect(toolFailureMessage('nonapp_unsupported_version'), '应用版本过新，请更新本应用');
      expect(toolFailureMessage('engine_generate_failed: timeout'), '页面生成没有完成，请重试');
      expect(toolFailureMessage('unknown_artboard:home'), '找不到这个画板，请重试');
      expect(toolFailureMessage('canvas_empty'), '画布还是空的：先用 generate_page 生成第一屏，再做设计操作');
      expect(toolFailureMessage('unknown_component: polyline'), '这个组件名不存在：先用 list_components 查合法组件名');
      expect(toolFailureMessage('place_unknown_key:parent'), 'place 的 k=v 键不在编辑词表里（text/fill/stroke/radius/opacity/motion…）');
      expect(toolFailureMessage('id_exists: stat_v0'), '这个 id 已经存在：换一个新 id');
      expect(toolFailureMessage('generate_multi_too_many:4'), '一次生成的画板数超限：拆成多次 generate_page');
      expect(toolFailureMessage('something_else'), '这次操作没有成功，请重试');
      expect(toolFailureMessage(null), '这次操作没有成功，请重试');
      // 映射结果里不出现裸错误码。
      final bare = RegExp(r'^[a-z0-9]+(_[a-z0-9]+)+$');
      for (final code in <String>[
        'engine_unavailable',
        'mbt_gate_block',
        'render_failed',
        'download_failed',
        'sha256_mismatch',
        'nonapp_unsupported_version',
        'whatever_code',
      ]) {
        expect(bare.hasMatch(toolFailureMessage(code)), isFalse, reason: code);
      }
    });

    test('normalizedErrorCode 取复合码基码', () {
      expect(normalizedErrorCode('engine_generate_failed: boom'), 'engine_generate_failed');
      expect(normalizedErrorCode('unknown_artboard：home'), 'unknown_artboard');
      expect(normalizedErrorCode('  '), '');
    });
  });

  group('LocalEngineGate', () {
    test('design_op 走 AgentGate；未就绪 → engine_unavailable；render 面可用', () async {
      final engine = _FakeEngine();
      final gate = LocalEngineGate(engine);
      final applied = await gate.applyAgent(engine.mbt, 'place home button cta - 30 110 140 44');
      expect(applied['ok'], isTrue);
      expect(engine.gates, <String>['agent'], reason: '唯一写路径必须是 AgentGate');
      expect(await gate.templates(), isNotEmpty);
      expect(await gate.components(), isNotEmpty);
      final rendered = await gate.render(engine.mbt);
      expect(rendered['ok'], isTrue);
      expect((rendered['artboards'] as List), isNotEmpty);

      engine.ready = false;
      final off = await gate.applyAgent('', 'anything');
      expect(off['ok'], isFalse);
      expect(off['error'], 'engine_unavailable');
      expect((await gate.render('')).length, 2);
      expect(await gate.templates(), isEmpty);
    });
  });

  group('build 全链（mock LLM + LocalEngineGate）', () {
    test('design_op → read_mbt 分层 → generate_page → critique/auto_fix（≤2 轮）→ 清扫', () async {
      final engine = _FakeEngine();
      final events = <Map<String, dynamic>>[];
      final model = _ScriptedModel(<List<LanguageModelV4ContentPart>>[
        <LanguageModelV4ContentPart>[
          mockToolCall(
            toolName: 'design_op',
            input: <String, dynamic>{'op': 'place home button cta - 30 110 140 44'},
          ),
        ],
        <LanguageModelV4ContentPart>[
          mockToolCall(toolName: 'read_mbt', input: <String, dynamic>{}),
        ],
        <LanguageModelV4ContentPart>[
          mockToolCall(
            toolName: 'generate_page',
            input: <String, dynamic>{'intent': '设置页', 'name': 'settings'},
          ),
        ],
        <LanguageModelV4ContentPart>[
          mockToolCall(
            toolName: 'inspect',
            input: <String, dynamic>{'kind': 'critique', 'artboard': 'home'},
          ),
        ],
        <LanguageModelV4ContentPart>[
          mockToolCall(toolName: 'finish', input: <String, dynamic>{'summary': '完成'}),
        ],
      ]);

      final result = await runDartAgent(
        request: _buildRequest(engine),
        modelOverride: model,
        bridge: LocalEngineGate(engine),
        onEvent: events.add,
      );

      expect(result.ok, isTrue);
      expect(result.stopReason, 'done');
      // 写路径全部是 AgentGate，一次也没走 human。
      expect(engine.gates, isNotEmpty);
      expect(engine.gates.every((g) => g == 'agent'), isTrue);
      expect(engine.applyCount, 1);
      expect(engine.generateCount, 1);
      expect(result.ops, contains('place home button cta - 30 110 140 44'));
      expect(result.ops, contains('generate 设置页'));

      // read_mbt 分层：outline 是 PROJECT MAP（不是整篇文档）。
      final readStart = events.firstWhere(
        (e) => e['type'] == 'tool_start' && e['tool'] == 'read_mbt',
      );
      expect(readStart, isNotNull);
      final readEnd = events.firstWhere(
        (e) => e['type'] == 'tool_end' && e['tool'] == 'read_mbt',
      );
      expect(readEnd['ok'], isTrue);
      expect(readEnd['preview'].toString(), contains('PROJECT MAP'));
      expect(readEnd['preview'].toString(), contains('home'));

      // 空板清扫：__seed 与 only-root 空板被删，且经 session 变更面（AgentGate）。
      expect(engine.deleteCount, 2);
      final cleanup = events.where((e) => e['type'] == 'cleanup').toList();
      expect(cleanup, hasLength(1));
      expect((cleanup.single['removed'] as List), containsAll(<String>['__seed', 'empty']));

      // RSI：critique 恒 poor → 最多 2 轮；每轮对每块板最多一次 auto_fix，
      // 绝不无限重试（两轮后无论是否修好都必须收手）。
      expect(events.where((e) => e['type'] == 'review_round').length, 2);
      expect(engine.autoFixPerBoard.keys, containsAll(<String>['home', 'settings']));
      expect(
        engine.autoFixPerBoard.values.every((count) => count <= 2),
        isTrue,
        reason: '单板修复不得跨过 2 轮上限：${engine.autoFixPerBoard}',
      );
      expect(result.mbt, contains('autofix'));

      // 工具事件都带人话标签（toolLabel 可映射）。
      final bare = RegExp(r'^[a-z0-9]+(_[a-z0-9]+)+$');
      for (final event in events.where((e) => e['type'] == 'tool_start')) {
        expect(bare.hasMatch(toolLabel(event['tool'].toString())), isFalse);
      }

      // 无工作区服务 → 工作区工具不暴露给模型。
      final toolNames = model.calls.first.tools
          .whereType<LanguageModelV4FunctionTool>()
          .map((t) => t.name)
          .toSet();
      expect(toolNames, containsAll(<String>['design_op', 'read_mbt', 'generate_page']));
      expect(toolNames.contains('three_list'), isFalse);
      expect(toolNames.contains('figma_export'), isFalse);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('空画布上 design_op → canvas_empty 人话，不打引擎、不烧步数', () async {
      final engine = _FakeEngine()
        ..mbt = '---\nmoonviz:\n  format: visual-document\n  revision: 0\n---\n'
        ..boards.clear(); // 引擎真值面：空画布 = session_list_artboards 返回空表
      final events = <Map<String, dynamic>>[];
      final result = await runDartAgent(
        request: _buildRequest(engine),
        modelOverride: _ScriptedModel(<List<LanguageModelV4ContentPart>>[
          <LanguageModelV4ContentPart>[
            mockToolCall(
              toolName: 'design_op',
              input: <String, dynamic>{'op': 'place home card c1 10 10 100 40'},
            ),
          ],
          <LanguageModelV4ContentPart>[
            mockToolCall(toolName: 'finish', input: <String, dynamic>{'summary': '停'}),
          ],
        ]),
        bridge: LocalEngineGate(engine),
        onEvent: events.add,
      );
      expect(result.ok, isTrue);
      final end = events.firstWhere(
        (e) => e['type'] == 'tool_end' && e['tool'] == 'design_op',
      );
      expect(end['ok'], isFalse);
      expect(end['error'], 'canvas_empty');
      expect(end['message'], '画布还是空的：先用 generate_page 生成第一屏，再做设计操作');
      expect(engine.applyCount, 0, reason: '空画布守卫在前，引擎门一次都不该打');
    });

    test('门拒绝 → tool_end 同时给原始码与人话，ops 不追加', () async {
      final engine = _FakeEngine();
      final events = <Map<String, dynamic>>[];
      final result = await runDartAgent(
        request: _buildRequest(engine),
        modelOverride: _ScriptedModel(<List<LanguageModelV4ContentPart>>[
          <LanguageModelV4ContentPart>[
            mockToolCall(toolName: 'design_op', input: <String, dynamic>{'op': 'gate_me'}),
          ],
          <LanguageModelV4ContentPart>[
            mockToolCall(toolName: 'finish', input: <String, dynamic>{'summary': '停'}),
          ],
        ]),
        bridge: LocalEngineGate(engine),
        onEvent: events.add,
      );
      expect(result.ok, isTrue);
      final end = events.firstWhere(
        (e) => e['type'] == 'tool_end' && e['tool'] == 'design_op',
      );
      expect(end['ok'], isFalse);
      expect(end['error'], 'mbt_gate_block', reason: '原始码保留给技术详情');
      expect(end['message'], '这次改动未通过设计校验');
      expect(result.ops, isNot(contains('gate_me')));
    });

    test('引擎未就绪 → design_op 得 engine_unavailable 人话', () async {
      final engine = _FakeEngine(ready: false);
      final events = <Map<String, dynamic>>[];
      final result = await runDartAgent(
        request: _buildRequest(engine),
        modelOverride: _ScriptedModel(<List<LanguageModelV4ContentPart>>[
          <LanguageModelV4ContentPart>[
            mockToolCall(toolName: 'design_op', input: <String, dynamic>{'op': 'place a b c'}),
          ],
          <LanguageModelV4ContentPart>[
            mockToolCall(toolName: 'finish', input: <String, dynamic>{'summary': '停'}),
          ],
        ]),
        bridge: LocalEngineGate(engine),
        onEvent: events.add,
      );
      expect(result.ok, isTrue);
      final end = events.firstWhere(
        (e) => e['type'] == 'tool_end' && e['tool'] == 'design_op',
      );
      expect(end['error'], 'engine_unavailable');
      expect(end['message'], '设计服务暂时不可用，请稍后重试');
      expect(engine.applyCount, 0);
    });
  });

  group('workspace tools', () {
    test('three_* / hotapp_* / video_* / nonapp_* / figma_export 全部接线', () async {
      final engine = _FakeEngine();
      final workspace = _FakeWorkspace();
      final events = <Map<String, dynamic>>[];
      final exportDir = Directory.systemTemp.createTempSync('figma-tool-');
      addTearDown(() => exportDir.deleteSync(recursive: true));
      final model = _ScriptedModel(<List<LanguageModelV4ContentPart>>[
        <LanguageModelV4ContentPart>[
          mockToolCall(
            toolName: 'three_create',
            input: <String, dynamic>{'name': 'island', 'brief': '一座浮岛'},
          ),
          mockToolCall(
            toolName: 'hotapp_generate',
            input: <String, dynamic>{'name': 'counter', 'brief': '计数器'},
          ),
        ],
        <LanguageModelV4ContentPart>[
          mockToolCall(toolName: 'nonapp_list', input: <String, dynamic>{}),
          mockToolCall(
            toolName: 'nonapp_inspect',
            input: <String, dynamic>{'name': 'counter'},
          ),
        ],
        <LanguageModelV4ContentPart>[
          mockToolCall(
            toolName: 'video_review',
            input: <String, dynamic>{
              'timeline': <String, dynamic>{
                'width': 1280,
                'height': 720,
                'fps': 30,
                'scenes': <dynamic>[],
              },
              'spec': <String, dynamic>{'kind': 'screenplay'},
            },
          ),
        ],
        <LanguageModelV4ContentPart>[
          mockToolCall(
            toolName: 'figma_export',
            input: <String, dynamic>{'directory': exportDir.path},
          ),
        ],
        <LanguageModelV4ContentPart>[
          mockToolCall(toolName: 'finish', input: <String, dynamic>{'summary': '完成'}),
        ],
      ]);

      final result = await runDartAgent(
        request: _buildRequest(engine),
        modelOverride: model,
        bridge: LocalEngineGate(engine),
        workspace: workspace,
        onEvent: events.add,
      );

      expect(result.ok, isTrue);
      expect(workspace.calls, contains('three_create:island'));
      expect(workspace.calls, contains('hotapp_generate:counter'));
      expect(workspace.calls, contains('nonapp_list'));
      expect(workspace.calls, contains('nonapp_inspect:counter'));
      expect(workspace.calls, contains('video_review'));
      expect(workspace.calls, contains('figma_export'));
      expect(workspace.lastDirectory, exportDir.path);
      expect(workspace.lastRender?.artboards.length, 1,
          reason: 'Figma 导出消费本地渲染信封');
      for (final tool in <String>[
        'three_create',
        'hotapp_generate',
        'nonapp_list',
        'nonapp_inspect',
        'video_review',
        'figma_export',
      ]) {
        final end = events.firstWhere(
          (e) => e['type'] == 'tool_end' && e['tool'] == tool,
          orElse: () => <String, dynamic>{},
        );
        expect(end['ok'], isTrue, reason: tool);
      }
      // 有工作区服务 → 工作区工具暴露给模型。
      final toolNames = model.calls.first.tools
          .whereType<LanguageModelV4FunctionTool>()
          .map((t) => t.name)
          .toSet();
      expect(
        toolNames,
        containsAll(<String>[
          'three_list',
          'three_create',
          'hotapp_generate',
          'video_review',
          'nonapp_inspect',
          'figma_export',
        ]),
      );
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('hotapp_from_prototype：设计→热应用链路（提取屏/跳转 + 验证结果如实上报）', () async {
      final engine = _FakeEngine()
        ..flows = <Map<String, dynamic>>[
          <String, dynamic>{'from': 'home', 'to': 'empty', 'trigger': 'tap'},
        ];
      final workspace = _FakeWorkspace();
      final events = <Map<String, dynamic>>[];
      final result = await runDartAgent(
        request: _buildRequest(engine),
        modelOverride: _ScriptedModel(<List<LanguageModelV4ContentPart>>[
          <LanguageModelV4ContentPart>[
            mockToolCall(
              toolName: 'hotapp_from_prototype',
              input: <String, dynamic>{'name': 'proto-demo'},
            ),
          ],
          <LanguageModelV4ContentPart>[
            mockToolCall(toolName: 'finish', input: <String, dynamic>{'summary': '原型已转热应用'}),
          ],
        ]),
        bridge: LocalEngineGate(engine),
        workspace: workspace,
        onEvent: events.add,
      );

      expect(result.ok, isTrue);
      expect(workspace.calls, contains('hotapp_from_prototype:proto-demo'));
      // 屏提取：__seed 剔除，home + empty 保留；跳转来自 session_flows。
      final protoScreens = workspace.lastFromPrototypeScreens;
      expect(protoScreens?.map((s) => s.id).toList(), <String>['home', 'empty']);
      expect(workspace.lastFromPrototypeFlows, hasLength(1));
      expect(workspace.lastFromPrototypeFlows?.single.to, 'empty');
      // 原型文档随调用下发（截断上限 12000 与 store 路径一致）。
      expect(workspace.lastFromPrototypeMbt, isNotNull);
      expect(workspace.lastFromPrototypeMbt!.length, lessThanOrEqualTo(12000));

      final end = events.firstWhere(
        (e) => e['type'] == 'tool_end' && e['tool'] == 'hotapp_from_prototype',
      );
      expect(end['ok'], isTrue);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('hotapp_from_prototype：画布没有原型 → prototype_empty 人话，不打服务', () async {
      final engine = _FakeEngine()..boards.clear();
      final workspace = _FakeWorkspace();
      final events = <Map<String, dynamic>>[];
      await runDartAgent(
        request: _buildRequest(engine),
        modelOverride: _ScriptedModel(<List<LanguageModelV4ContentPart>>[
          <LanguageModelV4ContentPart>[
            mockToolCall(
              toolName: 'hotapp_from_prototype',
              input: <String, dynamic>{'name': 'proto-demo'},
            ),
          ],
          <LanguageModelV4ContentPart>[
            mockToolCall(toolName: 'finish', input: <String, dynamic>{'summary': '停'}),
          ],
        ]),
        bridge: LocalEngineGate(engine),
        workspace: workspace,
        onEvent: events.add,
      );

      final end = events.firstWhere(
        (e) => e['type'] == 'tool_end' && e['tool'] == 'hotapp_from_prototype',
      );
      expect(end['ok'], isFalse);
      expect(end['error'], 'prototype_empty');
      expect(end['message'], '画布上还没有原型，先生成原型再转热应用');
      expect(workspace.calls.where((c) => c.startsWith('hotapp_from_prototype')), isEmpty,
          reason: '没有原型就不该打到服务');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('服务失败码 → tool_end.message 人话（原始码保留）', () async {
      final engine = _FakeEngine();
      final workspace = _FakeWorkspace()
        ..nonAppInspectResult = <String, dynamic>{
          'ok': false,
          'error': 'nonapp_unsupported_version',
          'detail': 'formatVersion=9',
        };
      final events = <Map<String, dynamic>>[];
      await runDartAgent(
        request: _buildRequest(engine),
        modelOverride: _ScriptedModel(<List<LanguageModelV4ContentPart>>[
          <LanguageModelV4ContentPart>[
            mockToolCall(
              toolName: 'nonapp_inspect',
              input: <String, dynamic>{'name': 'future'},
            ),
          ],
          <LanguageModelV4ContentPart>[
            mockToolCall(toolName: 'finish', input: <String, dynamic>{'summary': '停'}),
          ],
        ]),
        bridge: LocalEngineGate(engine),
        workspace: workspace,
        onEvent: events.add,
      );
      final end = events.firstWhere(
        (e) => e['type'] == 'tool_end' && e['tool'] == 'nonapp_inspect',
      );
      expect(end['ok'], isFalse);
      expect(end['error'], 'nonapp_unsupported_version');
      expect(end['message'], '应用版本过新，请更新本应用');
      expect(end['detail'], 'formatVersion=9');
      expect(end['preview'].toString(), isNot(contains('应用版本过新')));
    });

    test('figma_export 无渲染面 → figma_unavailable 人话', () async {
      final engine = _FakeEngine();
      final workspace = _FakeWorkspace();
      final events = <Map<String, dynamic>>[];
      await runDartAgent(
        request: _buildRequest(engine),
        modelOverride: _ScriptedModel(<List<LanguageModelV4ContentPart>>[
          <LanguageModelV4ContentPart>[
            mockToolCall(
              toolName: 'figma_export',
              input: <String, dynamic>{'directory': '/tmp/x'},
            ),
          ],
          <LanguageModelV4ContentPart>[
            mockToolCall(toolName: 'finish', input: <String, dynamic>{'summary': '停'}),
          ],
        ]),
        // 只实现门、不实现渲染面的桥。
        bridge: _GateOnlyBridge(engine),
        workspace: workspace,
        onEvent: events.add,
      );
      final end = events.firstWhere(
        (e) => e['type'] == 'tool_end' && e['tool'] == 'figma_export',
      );
      expect(end['ok'], isFalse);
      expect(end['error'], 'figma_unavailable');
      expect(end['message'], '导出 Figma 包需要先打开一个设计稿');
      expect(workspace.calls.contains('figma_export'), isFalse);
    });
  });

  group('Figma 导出（本地渲染信封）', () {
    test('逐板 SVG + manifest；不可见节点过滤；文件名清洗', () async {
      final dir = Directory.systemTemp.createTempSync('figma-export-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final render = RenderEnvelope.fromJson(<String, dynamic>{
        'ok': true,
        'artboards': <dynamic>[
          <String, dynamic>{
            'id': 'home/v2',
            'name': '首页',
            'width': 390,
            'height': 844,
            'background': '#FAFAFA',
            'svg': '<svg id="home"></svg>',
            'nodes': <dynamic>[
              _node(id: 'title', kind: 'text', text: '你好'),
              _node(id: 'hidden', visible: false),
            ],
          },
        ],
        'flows': <dynamic>[],
      });
      final exporter = FigmaExporter(
        platform: FigmaExportPlatform.desktop,
        clock: () => DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );
      final result = await exporter.export(render: render, directory: dir.path);
      expect(result.ok, isTrue);
      expect(result.boards, 1);
      expect(result.files, containsAll(<String>['board-home_v2.svg', 'nondesign.json', 'README.txt']));
      expect(File('${dir.path}/board-home_v2.svg').readAsStringSync(), '<svg id="home"></svg>');

      final manifest = jsonDecode(File('${dir.path}/nondesign.json').readAsStringSync())
          as Map<String, dynamic>;
      expect(manifest['exportedAt'], 1700000000);
      final board = (manifest['boards'] as List).single as Map<String, dynamic>;
      expect(board['id'], 'home/v2', reason: 'manifest 保留原始 id');
      expect(board['name'], '首页');
      expect(board['background'], '#FAFAFA');
      final nodes = board['nodes'] as List;
      expect(nodes.length, 1, reason: '不可见节点不进清单');
      final node = nodes.single as Map<String, dynamic>;
      expect(node['id'], 'title');
      expect(node['component'], 'body_text');
      expect(node['rect'], <String, dynamic>{'x': 1.0, 'y': 2.0, 'w': 30.0, 'h': 40.0});
      expect((node['style'] as Map)['text_color'], '#111827');
    });

    test('节点 cap 300 + truncated 标记', () {
      final nodes = <Map<String, dynamic>>[
        for (var i = 0; i < 320; i++) _node(id: 'n$i'),
      ];
      final exporter = FigmaExporter(platform: FigmaExportPlatform.desktop);
      final manifest = exporter.buildManifest(_renderEnvelope(nodes: nodes));
      final board = (manifest['boards'] as List).single as Map<String, dynamic>;
      expect((board['nodes'] as List).length, FigmaExporter.nodeCapPerBoard);
      expect(board['truncated'], isTrue);
    });

    test('移动端无保存/分享通道 → 明示不可用（不写沙盒假装成功）', () async {
      final dir = Directory.systemTemp.createTempSync('figma-mobile-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final exporter = FigmaExporter(platform: FigmaExportPlatform.mobile);
      final result = await exporter.export(render: _renderEnvelope(), directory: dir.path);
      expect(result.ok, isFalse);
      expect(result.error, 'figma_mobile_unavailable');
      expect(result.message, '这台设备暂不支持导出 Figma 包，请在电脑上导出');
      expect(dir.listSync(), isEmpty, reason: '不可用时不得落任何文件');
    });

    test('渲染失败 → render_failed；空文档 → figma_nothing_to_export', () async {
      final dir = Directory.systemTemp.createTempSync('figma-fail-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final exporter = FigmaExporter(platform: FigmaExportPlatform.desktop);
      final failed = await exporter.export(
        render: const RenderEnvelope(ok: false, error: 'engine_unavailable'),
        directory: dir.path,
      );
      expect(failed.error, 'render_failed');
      expect(failed.message, '预览生成失败');
      final empty = await exporter.export(
        render: const RenderEnvelope(ok: true),
        directory: dir.path,
      );
      expect(empty.error, 'figma_nothing_to_export');
      expect(empty.message, '还没有可以导出的画板');
    });
  });
}

/// 只实现门接口的桥（用于验证 figma_export 的渲染面缺失分支）。
class _GateOnlyBridge implements EngineGateBridge {
  _GateOnlyBridge(this.engine);
  final _FakeEngine engine;

  @override
  Future<Map<String, dynamic>> applyAgent(String mbt, String op) =>
      engine.apply(mbt, op, gate: 'agent');

  @override
  Future<Map<String, dynamic>> session(String mbt, String name, [String? arg]) =>
      engine.session(mbt, name, arg);

  @override
  Future<List<dynamic>> templates() => engine.templates();

  @override
  Future<List<dynamic>> components() => engine.components();
}
