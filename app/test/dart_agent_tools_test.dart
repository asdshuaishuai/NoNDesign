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

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:nondesign/core/api.dart';
import 'package:nondesign/core/capability.dart';
import 'package:nondesign/core/dart_agent.dart';

import 'package:genkit/genkit.dart';

import 'helpers/genkit_test_model.dart';

import 'package:nondesign/core/figma_export.dart';
import 'package:nondesign/core/hotapp_service.dart'
    show PrototypeLinkSpec, PrototypeScreenSpec;
import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/video_project.dart';
import 'package:nondesign/core/video_samples.dart';

/// 多轮脚本化模型（与 dart_agent_test 的 _ScriptedModel 同构）。

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

  String mbt =
      '---\nmoonviz:\n  format: visual-document\n  revision: 1\n  entry: home\n---\n\n'
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
  Future<Map<String, dynamic>> validate(String mbt) async => <String, dynamic>{
    'ok': true,
  };

  @override
  Future<Map<String, dynamic>> apply(
    String mbt,
    String op, {
    String gate = 'human',
  }) async {
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
  Future<Map<String, dynamic>> session(
    String mbt,
    String name, [
    String? arg,
  ]) async {
    switch (name) {
      case 'session_list_artboards':
        return <String, dynamic>{
          'ok': true,
          'data': boards.map((b) => Map<String, dynamic>.from(b)).toList(),
        };
      case 'session_flows':
        return <String, dynamic>{
          'ok': true,
          'data': flows.map((f) => Map<String, dynamic>.from(f)).toList(),
        };
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
              <String, dynamic>{
                'principle': 'hierarchy',
                'score': 2,
                'verdict': 'poor',
              },
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
    boards.add(<String, dynamic>{
      'id': name,
      'width': 390,
      'height': 844,
      'nodes': 4,
    });
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
  Future<Map<String, dynamic>> tap(
    String mbt,
    String artboard,
    double x,
    double y,
  ) async => <String, dynamic>{'ok': true, 'data': <String, dynamic>{}};

  @override
  Future<Map<String, dynamic>> constrainIntent(
    String mbt,
    String artboard,
    String intent,
  ) async => <String, dynamic>{'ok': true, 'mbt': mbt};

  @override
  Future<Map<String, dynamic>> event(
    String mbt,
    String artboard,
    String spec,
  ) async => <String, dynamic>{'ok': true, 'mbt': mbt};

  @override
  Future<Map<String, dynamic>> history(String mbt, String command) async =>
      <String, dynamic>{'ok': true};

  @override
  Future<Map<String, dynamic>> exportHtml(String mbt) async =>
      <String, dynamic>{'ok': true, 'html': '<html></html>'};

  @override
  Future<Map<String, dynamic>> tokens() async => <String, dynamic>{'ok': true};

  @override
  Future<Map<String, dynamic>> versionInfo() async => <String, dynamic>{
    'ok': true,
    'engine': 'fake',
  };

  @override
  Future<List<dynamic>> templates() async => <dynamic>[
    <String, dynamic>{'id': 'mobile_app', 'name': 'Mobile', 'device': 'mobile'},
  ];

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

  // -- 视频生成落盘（video_sample / video_list / video_create）--
  String? lastVideoName;
  Map<String, dynamic>? lastVideoTimeline;
  Map<String, dynamic>? lastVideoSpec;
  String? lastVideoTitle;
  int? lastVideoSampleIndex;
  Map<String, dynamic> videoCreateResult = <String, dynamic>{
    'ok': true,
    'video': 'demo',
    'title': '示例动画',
    'seconds': 6.0,
    'frames': 180,
  };
  Map<String, dynamic> videoListResult = <String, dynamic>{
    'ok': true,
    'videos': <dynamic>[
      <String, dynamic>{
        'name': 'demo',
        'title': '示例动画',
        'seconds': 6.0,
        'builtin': false,
      },
      <String, dynamic>{
        'name': 'physics-friction',
        'title': '物理 · 斜面摩擦力',
        'seconds': 8.0,
        'builtin': true,
        'index': 0,
      },
    ],
  };
  Map<String, dynamic> videoSampleResult = <String, dynamic>{
    'ok': true,
    'index': 0,
    'count': 3,
    'name': 'physics-friction',
    'timeline': <String, dynamic>{'fps': 30, 'scenes': <dynamic>[]},
    'spec': <String, dynamic>{'kind': 'science'},
  };

  // -- 3D 视频（video3d_list / video3d_status / video3d_create）--
  String? lastVideoShortName;
  Map<String, dynamic>? lastVideoShortScreenplay;
  Map<String, dynamic> videoShortListResult = <String, dynamic>{
    'ok': true,
    'count': 0,
    'projects': <dynamic>[],
  };
  Map<String, dynamic> videoShortStatusResult = <String, dynamic>{
    'ok': true,
    'project': 'short',
    'verified': true,
    'shots': 1,
    'frames': 60,
    'events': 2,
    'vfx_events': 1,
  };
  Map<String, dynamic> videoShortCreateResult = <String, dynamic>{
    'ok': true,
    'project': 'short',
    'shots': 1,
    'frames': 60,
    'events': 2,
    'vfx_events': 1,
    'verified': true,
  };
  String? lastVideo3dName;
  Map<String, dynamic>? lastVideo3dScene;
  Map<String, dynamic>? lastVideo3dScreenplay;
  List<int>? lastVideo3dFrames;
  Map<String, dynamic> video3dRenderFramesResult = <String, dynamic>{
    'ok': true,
    'project': 'stage',
    'renderer': 'webgl_three_r160',
    'count': 1,
    'total_bytes': 69,
    'manifest': 'artifacts/renders/renders.json',
    'frames': <dynamic>[
      <String, dynamic>{'frame': 0, 'file': 'frame-0000.png', 'bytes': 69},
    ],
  };
  Map<String, dynamic> video3dCreateResult = <String, dynamic>{
    'ok': true,
    'project': 'stage',
    'verified': true,
    'nodes': 3,
    'shots': 1,
    'seconds': 5.0,
    'frames': 150,
  };
  Map<String, dynamic> video3dStatusResult = <String, dynamic>{
    'ok': true,
    'project': 'stage',
    'verified': true,
    'checks': <dynamic>[],
    'nodes': 3,
    'shots': 1,
    'seconds': 5.0,
    'frames': 150,
  };
  Map<String, dynamic> video3dListResult = <String, dynamic>{
    'ok': true,
    'projects': <dynamic>[
      <String, dynamic>{
        'name': 'stage',
        'nodes': 3,
        'shots': 1,
        'seconds': 5.0,
        'frames': 150,
        'verified': true,
      },
    ],
    'count': 1,
  };

  // -- 音乐工具（music_list / music_read / music_inspect / music_create / music_patch）--
  String? lastMusicName;
  Map<String, dynamic>? lastMusicScore;
  String? lastMusicPatchName;
  List<Map<String, dynamic>>? lastMusicPatchOps;
  Map<String, dynamic> musicCreateResult = <String, dynamic>{
    'ok': true,
    'project': 'dawn',
    'title': '晨光',
    'tracks': 1,
    'measures': 1,
    'verified': true,
    'issues': 0,
  };
  Map<String, dynamic> musicPatchResult = <String, dynamic>{
    'ok': true,
    'project': 'dawn',
    'title': '暮色',
    'tracks': 1,
    'measures': 2,
    'applied': 2,
    'verified': true,
    'issues': 0,
  };
  Map<String, dynamic> musicListResult = <String, dynamic>{
    'ok': true,
    'projects': <dynamic>[
      <String, dynamic>{
        'name': 'dawn',
        'title': '晨光',
        'tracks': 1,
        'measures': 8,
        'verified': true,
        'corrupt': false,
      },
    ],
    'count': 1,
  };
  Map<String, dynamic> musicReadResult = <String, dynamic>{
    'ok': true,
    'name': 'dawn',
    'title': '晨光',
    'verified': true,
    'issues': 0,
    'chars': 220,
    'scoreJson': '{"schemaVersion": 1, "title": "晨光"}',
    'truncated': false,
  };
  Map<String, dynamic> musicInspectResult = <String, dynamic>{
    'ok': true,
    'name': 'dawn',
    'title': '晨光',
    'tracks': 1,
    'measures': 8,
    'totalTicks': 122880,
    'seconds': 32.0,
    'verified': true,
    'issues': 0,
  };

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
  Future<Map<String, dynamic>> threeContinue(
    String name, [
    String summary = '',
  ]) async {
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
  Future<Map<String, dynamic>> threeWorkspaceMigrate(String name) async {
    calls.add('three_workspace_migrate:$name');
    return <String, dynamic>{
      'ok': true,
      'name': name,
      'already_migrated': false,
      'wrote_spec': true,
      'wrote_plan': true,
      'copied_scene': true,
      'mode': 'code',
    };
  }

  @override
  Future<Map<String, dynamic>> threePlanValidate(String name) async {
    calls.add('three_plan_validate:$name');
    return <String, dynamic>{
      'ok': true,
      'name': name,
      'valid': true,
      'issues': <dynamic>[],
      'fix_hints': <dynamic>[],
      'warnings': <dynamic>[],
    };
  }

  Map<String, dynamic>? lastCheckMeasurement;

  @override
  Future<Map<String, dynamic>> threeCheckPlacement({
    required String name,
    Map<String, dynamic>? measurement,
  }) async {
    calls.add('three_check_placement:$name');
    return <String, dynamic>{
      'ok': true,
      'name': name,
      'verdict': 'PASS',
      'caps': <String, dynamic>{},
      'fix_hints': <dynamic>[],
      'gates': <dynamic>[],
      'saved': 'artifacts/placement-gates.json',
    };
  }

  @override
  Future<Map<String, dynamic>> threeBuild(String name) async {
    calls.add('three_build:$name');
    return <String, dynamic>{
      'ok': true,
      'name': name,
      'mode': 'scene',
      'status': 'built',
      'source': 'src/scene.js',
      'plan_warnings': <dynamic>[],
      'saved': 'artifacts/build.json',
    };
  }

  @override
  Future<Map<String, dynamic>> threeMeasure(String name) async {
    calls.add('three_measure:$name');
    return <String, dynamic>{
      'ok': true,
      'name': name,
      'part_count': 1,
      'triangles': 120,
      'parts': <dynamic>[
        <String, Object?>{
          'id': 'seat',
          'bbox': <String, Object?>{
            'min': <double>[0, 0.4, 0],
            'max': <double>[0.5, 0.45, 0.5],
          },
          'triangles': 120,
        },
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> threeCheck({
    required String name,
    Map<String, dynamic>? measurement,
  }) async {
    calls.add('three_check:$name');
    lastCheckMeasurement = measurement;
    return <String, dynamic>{
      'ok': true,
      'name': name,
      'verdict': 'ERROR',
      'caps': <String, dynamic>{'floating': 0.6},
      'fix_hints': <String>['connectivity: 沿 y 平移 -0.050 m 落地'],
      'gates': <dynamic>[
        <String, Object?>{
          'id': 'connectivity',
          'verdict': 'ERROR',
          'metrics': <String, double>{'floating_parts': 1},
        },
      ],
      'saved': true,
    };
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

  List<PrototypeScreenSpec>? lastVerifyScreens;
  List<PrototypeLinkSpec>? lastVerifyFlows;
  String? lastVerifyMbt;
  bool verifyOk = true;

  bool judgeDegraded = false;
  Map<String, dynamic>? lastJudgeArgs;

  @override
  Future<Map<String, dynamic>> creativeJudge({
    required String brief,
    required String kind,
    required String track,
    required List<String> imagePaths,
    String planDigest = '',
    List<String> acceptance = const <String>[],
    List<String> measuredFacts = const <String>[],
    Map<String, dynamic>? gates,
  }) async {
    calls.add('creative_judge');
    lastJudgeArgs = <String, dynamic>{
      'brief': brief,
      'kind': kind,
      'track': track,
      'imagePaths': imagePaths,
      'gates': gates,
    };
    if (judgeDegraded) {
      return <String, dynamic>{
        'ok': false,
        'degraded': true,
        'reason': 'judge_no_images',
        'detail': 'no evidence',
      };
    }
    return <String, dynamic>{
      'ok': true,
      'judgment': <String, dynamic>{'summary': 'stub judgment'},
      'score': <String, dynamic>{'overall': 0.8},
    };
  }

  @override
  Future<Map<String, dynamic>> designVerifyPrototype({
    required String mbt,
    required List<PrototypeScreenSpec> screens,
    required List<PrototypeLinkSpec> flows,
  }) async {
    calls.add('design_verify_prototype');
    lastVerifyScreens = screens;
    lastVerifyFlows = flows;
    lastVerifyMbt = mbt;
    return <String, dynamic>{
      'ok': true,
      'verified': verifyOk,
      'saved': true,
      'screens': screens.length,
      'flows': flows.length,
      if (!verifyOk) 'failures': '缺少画板 empty',
    };
  }

  @override
  Future<Map<String, dynamic>> videoReview({
    required Map<String, dynamic> timeline,
    Map<String, dynamic>? spec,
  }) async {
    calls.add('video_review');
    return <String, dynamic>{
      'ok': true,
      'summary': '对照检查通过',
      'problems': <dynamic>[],
    };
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
  Future<Map<String, dynamic>> videoCreate({
    required String name,
    required Map<String, dynamic> timeline,
    Map<String, dynamic>? spec,
    String title = '',
  }) async {
    calls.add('video_create:$name');
    lastVideoName = name;
    lastVideoTimeline = timeline;
    lastVideoSpec = spec;
    lastVideoTitle = title;
    if (videoCreateResult['ok'] == true) {
      return <String, dynamic>{
        ...videoCreateResult,
        'video': videoCreateResult['video'] ?? name,
      };
    }
    return Map<String, dynamic>.from(videoCreateResult);
  }

  @override
  Future<Map<String, dynamic>> videoList() async {
    calls.add('video_list');
    return Map<String, dynamic>.from(videoListResult);
  }

  @override
  Future<Map<String, dynamic>> videoSample({int index = 0}) async {
    calls.add('video_sample:$index');
    lastVideoSampleIndex = index;
    return Map<String, dynamic>.from(videoSampleResult);
  }

  @override
  Future<Map<String, dynamic>> video3dList() async {
    calls.add('video3d_list');
    return Map<String, dynamic>.from(video3dListResult);
  }

  @override
  Future<Map<String, dynamic>> video3dStatus(String name) async {
    calls.add('video3d_status:$name');
    lastVideo3dName = name;
    return Map<String, dynamic>.from(video3dStatusResult);
  }

  @override
  Future<Map<String, dynamic>> video3dCreate({
    required String name,
    required Map<String, dynamic> scene,
    required Map<String, dynamic> screenplay,
  }) async {
    calls.add('video3d_create:$name');
    lastVideo3dName = name;
    lastVideo3dScene = scene;
    lastVideo3dScreenplay = screenplay;
    return Map<String, dynamic>.from(video3dCreateResult);
  }

  @override
  Future<Map<String, dynamic>> videoShortList() async {
    calls.add('video_short_list');
    return Map<String, dynamic>.from(videoShortListResult);
  }

  @override
  Future<Map<String, dynamic>> videoShortStatus(String name) async {
    calls.add('video_short_status:$name');
    return Map<String, dynamic>.from(videoShortStatusResult);
  }

  @override
  Future<Map<String, dynamic>> videoShortCreate({
    required String name,
    required Map<String, dynamic> screenplay,
  }) async {
    calls.add('video_short_create:$name');
    lastVideoShortName = name;
    lastVideoShortScreenplay = screenplay;
    return Map<String, dynamic>.from(videoShortCreateResult);
  }

  @override
  Future<Map<String, dynamic>> video3dRenderFrames({
    required String name,
    required List<int> frames,
  }) async {
    calls.add('video3d_render_frames:$name:${frames.join(',')}');
    lastVideo3dName = name;
    lastVideo3dFrames = List<int>.from(frames);
    return Map<String, dynamic>.from(video3dRenderFramesResult);
  }

  @override
  Future<Map<String, dynamic>> musicList() async {
    calls.add('music_list');
    return Map<String, dynamic>.from(musicListResult);
  }

  @override
  Future<Map<String, dynamic>> musicRead(String name) async {
    calls.add('music_read:$name');
    lastMusicName = name;
    return Map<String, dynamic>.from(musicReadResult);
  }

  @override
  Future<Map<String, dynamic>> musicInspect(String name) async {
    calls.add('music_inspect:$name');
    lastMusicName = name;
    return Map<String, dynamic>.from(musicInspectResult);
  }

  @override
  Future<Map<String, dynamic>> musicCreate({
    required String name,
    required Map<String, dynamic> score,
  }) async {
    calls.add('music_create:$name');
    lastMusicName = name;
    lastMusicScore = score;
    if (musicCreateResult['ok'] == true) {
      return <String, dynamic>{
        ...musicCreateResult,
        'project': musicCreateResult['project'] ?? name,
      };
    }
    return Map<String, dynamic>.from(musicCreateResult);
  }

  @override
  Future<Map<String, dynamic>> musicPatch({
    required String name,
    required List<Map<String, dynamic>> ops,
  }) async {
    calls.add('music_patch:$name');
    lastMusicPatchName = name;
    lastMusicPatchOps = ops;
    if (musicPatchResult['ok'] == true) {
      return <String, dynamic>{
        ...musicPatchResult,
        'project': musicPatchResult['project'] ?? name,
      };
    }
    return Map<String, dynamic>.from(musicPatchResult);
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
    return <String, dynamic>{
      'ok': true,
      'boards': render.artboards.length,
      'dir': directory,
    };
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
}) => <String, dynamic>{
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

RenderEnvelope _renderEnvelope({
  String boardId = 'home',
  List<Map<String, dynamic>>? nodes,
}) => RenderEnvelope.fromJson(<String, dynamic>{
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
        'video_create': '视频 · 新建',
        'video_list': '视频',
        'video_sample': '视频 · 示例',
        'video_review': '视频 · 对照检查',
        'nonapp_list': '应用包',
        'figma_export': '导出 Figma 包',
        'music_list': '音乐',
        'music_read': '音乐 · 读谱',
        'music_inspect': '音乐 · 查看',
        'music_create': '音乐 · 新建',
        'music_patch': '音乐 · 修改',
      };
      mapping.forEach(
        (tool, label) => expect(toolLabel(tool), label, reason: tool),
      );
      expect(toolLabel('three_future_tool'), '3D 场景');
      expect(toolLabel('hotapp_future_tool'), '热应用');
      expect(toolLabel('video_future_tool'), '视频');
      expect(toolLabel('video_create'), '视频 · 新建');
      expect(toolLabel('nonapp_future_tool'), '应用包');
      expect(toolLabel('music_future_tool'), '音乐');
      expect(toolLabel('mystery_tool'), '智能体操作');
      // 任何工具标签都不许是裸 snake_case 代号。
      final bare = RegExp(r'^[a-z0-9]+(_[a-z0-9]+)+$');
      for (final tool in <String>[
        ...mapping.keys,
        'three_future_tool',
        'hotapp_future_tool',
        'video_future_tool',
        'video_create',
        'video_list',
        'video_sample',
        'video_review',
        'nonapp_future_tool',
        'mystery_tool',
        'music_future_tool',
        'music_create',
        'music_patch',
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
      expect(
        toolFailureMessage('engine_generate_failed: timeout'),
        '页面生成没有完成，请重试',
      );
      expect(toolFailureMessage('unknown_artboard:home'), '找不到这个画板，请重试');
      expect(
        toolFailureMessage('canvas_empty'),
        '画布还是空的：先用 generate_page 生成第一屏，再做设计操作',
      );
      expect(
        toolFailureMessage('unknown_component: polyline'),
        '这个组件名不存在：先用 list_components 查合法组件名',
      );
      expect(
        toolFailureMessage('place_unknown_key:parent'),
        'place 的 k=v 键不在编辑词表里（text/fill/stroke/radius/opacity/motion…）',
      );
      expect(toolFailureMessage('id_exists: stat_v0'), '这个 id 已经存在：换一个新 id');
      expect(
        toolFailureMessage('generate_multi_too_many:4'),
        '一次生成的画板数超限：拆成多次 generate_page',
      );
      expect(toolFailureMessage('something_else'), '这次操作没有成功，请重试');
      expect(toolFailureMessage(null), '这次操作没有成功，请重试');
      // 视频生成落盘（video_create）的失败码：每一码都有人话，无裸代号。
      expect(toolFailureMessage('video_invalid_name'), '视频名只能用字母、数字、下划线和连字符');
      expect(
        toolFailureMessage('video_project_exists'),
        '已经有同名视频了，换一个名字再新建（已生成的视频不会被覆盖）',
      );
      expect(toolFailureMessage('video_spec_missing'), '这份脚本还缺一份说明规范，先补齐规范再新建');
      expect(toolFailureMessage('video_spec_invalid'), '说明规范不完整，请按模板补齐后再试');
      expect(
        toolFailureMessage('video_timeline_invalid'),
        '脚本格式不对，请检查括号、引号与逗号',
      );
      expect(toolFailureMessage('video_no_scenes'), '脚本里还没有任何场景');
      expect(toolFailureMessage('video_no_frames'), '所有场景的时长都是 0，算不出画面');
      expect(toolFailureMessage('video_io_error'), '视频项目没有保存成功，请检查磁盘空间后重试');
      expect(
        toolFailureMessage('video_export_disabled'),
        '视频现在是代码动画，直接在工作台里播放；暂不导出成片',
      );
      // 细分码按模块自己的人话表分派（three_/hotapp_ 前缀不再落回通用句）。
      expect(toolFailureMessage('three_invalid_name'), '场景名只能用字母、数字和短横线');
      expect(
        toolFailureMessage('three_project_exists'),
        '已经有同名的 3D 项目了，换个名字再试',
      );
      expect(toolFailureMessage('hotapp_name_taken'), '已经有同名应用了，换一个名字');
      expect(toolFailureMessage('hotapp_brief_empty'), '先写一句想要的动画或玩法');
      // 音乐项目落盘（music_create / read / inspect）的失败码：模块人话表。
      expect(
        toolFailureMessage('music_score_invalid'),
        '乐谱还没有通过校验：先修好小节/时值/关系再保存',
      );
      expect(
        toolFailureMessage('music_score_unsupported_version'),
        '这份乐谱版本太新，暂时读不了',
      );
      expect(toolFailureMessage('music_no_project'), '没有找到这个音乐项目');
      expect(toolFailureMessage('music_invalid_name'), '音乐项目名只能用字母、数字、下划线和短横线');
      expect(toolFailureMessage('music_project_exists'), '已经有同名音乐项目了，换一个名字再试');
      expect(toolFailureMessage('music_io_error'), '乐谱文件没能读写，请稍后再试');
      // 确定性补丁（music_patch）细分码：路径/越界/值/校验失败各有可执行人话。
      expect(
        toolFailureMessage('music_patch_invalid_path'),
        '补丁路径不可用：只能改标题、速度、轨道的安全字段或小节事件',
      );
      expect(
        toolFailureMessage('music_patch_out_of_range'),
        '补丁路径的下标越界了，先刷新乐谱再试',
      );
      expect(
        toolFailureMessage('music_patch_invalid_value'),
        '补丁值格式不对，请按乐谱字段要求填写',
      );
      expect(
        toolFailureMessage('music_patch_score_invalid'),
        '补丁后的乐谱没有通过校验，改动没有保存',
      );
      expect(toolFailureMessage('music_patch_too_many_ops'), '一次补丁条数太多，拆成几次再试');
      // 映射结果里不出现裸错误码。
      final bare = RegExp(r'^[a-z0-9]+(_[a-z0-9]+)+$');
      for (final code in <String>[
        'engine_unavailable',
        'mbt_gate_block',
        'render_failed',
        'download_failed',
        'sha256_mismatch',
        'nonapp_unsupported_version',
        'video_invalid_name',
        'video_project_exists',
        'video_io_error',
        'three_invalid_name',
        'hotapp_name_taken',
        'music_score_invalid',
        'music_no_project',
        'music_patch_invalid_path',
        'music_patch_score_invalid',
        'whatever_code',
      ]) {
        expect(bare.hasMatch(toolFailureMessage(code)), isFalse, reason: code);
      }
    });

    test('normalizedErrorCode 取复合码基码', () {
      expect(
        normalizedErrorCode('engine_generate_failed: boom'),
        'engine_generate_failed',
      );
      expect(normalizedErrorCode('unknown_artboard：home'), 'unknown_artboard');
      expect(normalizedErrorCode('  '), '');
    });
  });

  group('LocalEngineGate', () {
    test('design_op 走 AgentGate；未就绪 → engine_unavailable；render 面可用', () async {
      final engine = _FakeEngine();
      final gate = LocalEngineGate(engine);
      final applied = await gate.applyAgent(
        engine.mbt,
        'place home button cta - 30 110 140 44',
      );
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
    test(
      'design_op → read_mbt 分层 → generate_page → critique/auto_fix（≤2 轮）→ 清扫',
      () async {
        final engine = _FakeEngine();
        final events = <Map<String, dynamic>>[];
        final model = ScriptedAgentModel(<List<Part>>[
          <Part>[
            scriptToolCall(
              toolName: 'design_op',
              input: <String, dynamic>{
                'op': 'place home button cta - 30 110 140 44',
              },
            ),
          ],
          <Part>[
            scriptToolCall(toolName: 'read_mbt', input: <String, dynamic>{}),
          ],
          <Part>[
            scriptToolCall(
              toolName: 'generate_page',
              input: <String, dynamic>{'intent': '设置页', 'name': 'settings'},
            ),
          ],
          <Part>[
            scriptToolCall(
              toolName: 'inspect',
              input: <String, dynamic>{'kind': 'critique', 'artboard': 'home'},
            ),
          ],
          <Part>[
            scriptToolCall(
              toolName: 'finish',
              input: <String, dynamic>{'summary': '完成'},
            ),
          ],
        ]);

        final result = await runDartAgent(
          request: _buildRequest(engine),
          modelOverride: model.model,
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
        expect(
          (cleanup.single['removed'] as List),
          containsAll(<String>['__seed', 'empty']),
        );

        // RSI：critique 恒 poor → 最多 2 轮；每轮对每块板最多一次 auto_fix，
        // 绝不无限重试（两轮后无论是否修好都必须收手）。
        expect(events.where((e) => e['type'] == 'review_round').length, 2);
        expect(
          engine.autoFixPerBoard.keys,
          containsAll(<String>['home', 'settings']),
        );
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
        final toolNames = (model.calls.first.tools ?? const <ToolDefinition>[])
            .map((t) => t.name)
            .toSet();
        expect(
          toolNames,
          containsAll(<String>['design_op', 'read_mbt', 'generate_page']),
        );
        expect(toolNames.contains('three_list'), isFalse);
        expect(toolNames.contains('figma_export'), isFalse);
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test('空画布上 design_op → canvas_empty 人话，不打引擎、不烧步数', () async {
      final engine = _FakeEngine()
        ..mbt = '---\nmoonviz:\n  format: visual-document\n  revision: 0\n---\n'
        ..boards.clear(); // 引擎真值面：空画布 = session_list_artboards 返回空表
      final events = <Map<String, dynamic>>[];
      final result = await runDartAgent(
        request: _buildRequest(engine),
        modelOverride: ScriptedAgentModel(<List<Part>>[
          <Part>[
            scriptToolCall(
              toolName: 'design_op',
              input: <String, dynamic>{'op': 'place home card c1 10 10 100 40'},
            ),
          ],
          <Part>[
            scriptToolCall(
              toolName: 'finish',
              input: <String, dynamic>{'summary': '停'},
            ),
          ],
        ]).model,
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
        modelOverride: ScriptedAgentModel(<List<Part>>[
          <Part>[
            scriptToolCall(
              toolName: 'design_op',
              input: <String, dynamic>{'op': 'gate_me'},
            ),
          ],
          <Part>[
            scriptToolCall(
              toolName: 'finish',
              input: <String, dynamic>{'summary': '停'},
            ),
          ],
        ]).model,
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
        modelOverride: ScriptedAgentModel(<List<Part>>[
          <Part>[
            scriptToolCall(
              toolName: 'design_op',
              input: <String, dynamic>{'op': 'place a b c'},
            ),
          ],
          <Part>[
            scriptToolCall(
              toolName: 'finish',
              input: <String, dynamic>{'summary': '停'},
            ),
          ],
        ]).model,
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
    test(
      'three_* / hotapp_* / video_* / nonapp_* / figma_export 全部接线',
      () async {
        final engine = _FakeEngine();
        final workspace = _FakeWorkspace();
        final events = <Map<String, dynamic>>[];
        final exportDir = Directory.systemTemp.createTempSync('figma-tool-');
        addTearDown(() => exportDir.deleteSync(recursive: true));
        final model = ScriptedAgentModel(<List<Part>>[
          <Part>[
            scriptToolCall(
              toolName: 'three_create',
              input: <String, dynamic>{'name': 'island', 'brief': '一座浮岛'},
            ),
            scriptToolCall(
              toolName: 'hotapp_generate',
              input: <String, dynamic>{'name': 'counter', 'brief': '计数器'},
            ),
          ],
          <Part>[
            scriptToolCall(toolName: 'nonapp_list', input: <String, dynamic>{}),
            scriptToolCall(
              toolName: 'nonapp_inspect',
              input: <String, dynamic>{'name': 'counter'},
            ),
          ],
          <Part>[
            scriptToolCall(
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
          <Part>[
            scriptToolCall(
              toolName: 'figma_export',
              input: <String, dynamic>{'directory': exportDir.path},
            ),
          ],
          <Part>[
            scriptToolCall(
              toolName: 'finish',
              input: <String, dynamic>{'summary': '完成'},
            ),
          ],
        ]);

        final result = await runDartAgent(
          request: _buildRequest(engine),
          modelOverride: model.model,
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
        expect(
          workspace.lastRender?.artboards.length,
          1,
          reason: 'Figma 导出消费本地渲染信封',
        );
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
        final toolNames = (model.calls.first.tools ?? const <ToolDefinition>[])
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
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test('design_verify_prototype：提取屏/跳转并调用项目内验证（不调模型）', () async {
      final engine = _FakeEngine()
        ..flows = <Map<String, dynamic>>[
          <String, dynamic>{'from': 'home', 'to': 'empty', 'trigger': 'tap'},
        ];
      final workspace = _FakeWorkspace();
      final events = <Map<String, dynamic>>[];
      final result = await runDartAgent(
        request: _buildRequest(engine),
        modelOverride: ScriptedAgentModel(<List<Part>>[
          <Part>[
            scriptToolCall(
              toolName: 'design_verify_prototype',
              input: <String, dynamic>{},
            ),
          ],
          <Part>[
            scriptToolCall(
              toolName: 'finish',
              input: <String, dynamic>{'summary': '原型已过覆盖门'},
            ),
          ],
        ]).model,
        bridge: LocalEngineGate(engine),
        workspace: workspace,
        onEvent: events.add,
      );

      expect(result.ok, isTrue);
      expect(workspace.calls, contains('design_verify_prototype'));
      // 屏提取：__seed 剔除，home + empty 保留；跳转来自 session_flows。
      expect(workspace.lastVerifyScreens?.map((s) => s.id).toList(), <String>[
        'home',
        'empty',
      ]);
      expect(workspace.lastVerifyFlows, hasLength(1));
      expect(workspace.lastVerifyFlows?.single.to, 'empty');
      expect(workspace.lastVerifyMbt, isNotNull);

      final end = events.firstWhere(
        (e) =>
            e['type'] == 'tool_end' && e['tool'] == 'design_verify_prototype',
      );
      expect(end['ok'], isTrue);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('design_verify_prototype：画布没有原型 → prototype_empty 人话，不打服务', () async {
      final engine = _FakeEngine()..boards.clear();
      final workspace = _FakeWorkspace();
      final events = <Map<String, dynamic>>[];
      await runDartAgent(
        request: _buildRequest(engine),
        modelOverride: ScriptedAgentModel(<List<Part>>[
          <Part>[
            scriptToolCall(
              toolName: 'design_verify_prototype',
              input: <String, dynamic>{},
            ),
          ],
          <Part>[
            scriptToolCall(
              toolName: 'finish',
              input: <String, dynamic>{'summary': '停'},
            ),
          ],
        ]).model,
        bridge: LocalEngineGate(engine),
        workspace: workspace,
        onEvent: events.add,
      );

      final end = events.firstWhere(
        (e) =>
            e['type'] == 'tool_end' && e['tool'] == 'design_verify_prototype',
      );
      expect(end['ok'], isFalse);
      expect(end['error'], 'prototype_empty');
      expect(end['message'], '画布上还没有原型，先生成原型再验证');
      expect(workspace.calls, isEmpty, reason: '没有原型就不该打到服务');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('three_plan_validate / three_check：v2 工作区校验与门评估接线', () async {
      final workspace = _FakeWorkspace();
      final events = <Map<String, dynamic>>[];
      final result = await runDartAgent(
        request: DartAgentRequest(
          mode: 'workspace',
          instruction: '校验计划并跑门',
          model: 'scripted-model',
          baseUrl: 'https://example.invalid/v1',
          apiKey: 'k',
          workspaceHint: 'three',
        ),
        modelOverride: ScriptedAgentModel(<List<Part>>[
          <Part>[
            scriptToolCall(
              toolName: 'three_plan_validate',
              input: <String, dynamic>{'name': 'chair'},
            ),
          ],
          <Part>[
            scriptToolCall(
              toolName: 'three_measure',
              input: <String, dynamic>{'name': 'chair'},
            ),
          ],
          <Part>[
            scriptToolCall(
              toolName: 'three_build',
              input: <String, dynamic>{'name': 'chair'},
            ),
          ],
          <Part>[
            scriptToolCall(
              toolName: 'three_check_placement',
              input: <String, dynamic>{'name': 'chair'},
            ),
          ],
          <Part>[
            scriptToolCall(
              toolName: 'three_check',
              input: <String, dynamic>{'name': 'chair'},
            ),
          ],
          <Part>[
            scriptToolCall(
              toolName: 'finish',
              input: <String, dynamic>{'summary': '门跑完'},
            ),
          ],
        ]).model,
        workspace: workspace,
        onEvent: events.add,
      );
      expect(result.ok, isTrue);
      expect(
        workspace.calls,
        containsAll(<String>['three_plan_validate:chair', 'three_check:chair']),
      );
      final end = events.firstWhere(
        (e) => e['type'] == 'tool_end' && e['tool'] == 'three_check',
      );
      expect(end['ok'], isTrue);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('creative_judge：盲评走 fresh context 回调，成功返回 judgment/score', () async {
      final workspace = _FakeWorkspace();
      final events = <Map<String, dynamic>>[];
      final result = await runDartAgent(
        request: DartAgentRequest(
          mode: 'workspace',
          instruction: '盲评',
          model: 'scripted-model',
          baseUrl: 'https://example.invalid/v1',
          apiKey: 'k',
          workspaceHint: 'three',
        ),
        modelOverride: ScriptedAgentModel(<List<Part>>[
          <Part>[
            scriptToolCall(
              toolName: 'creative_judge',
              input: <String, dynamic>{
                'brief': '一把橡木餐椅',
                'kind': '3d',
                'track': 'static_object',
                'image_paths': <String>['/projects/3d/chair/artifacts/m1.png'],
                'plan_digest': 'seat 0.45m',
                'acceptance': <String>['座高 0.45m'],
                'measured_facts': <String>['connectivity: PASS'],
              },
            ),
          ],
          <Part>[
            scriptToolCall(
              toolName: 'finish',
              input: <String, dynamic>{'summary': '盲评完成'},
            ),
          ],
        ]).model,
        workspace: workspace,
        onEvent: events.add,
      );
      expect(result.ok, isTrue);
      expect(workspace.calls, contains('creative_judge'));
      expect(workspace.lastJudgeArgs?['kind'], '3d');
      expect(workspace.lastJudgeArgs?['imagePaths'], hasLength(1));
      final end = events.firstWhere(
        (e) => e['type'] == 'tool_end' && e['tool'] == 'creative_judge',
      );
      expect(end['ok'], isTrue);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('creative_judge：通道降级 → 显性错误码与人话，不冒充分数', () async {
      final workspace = _FakeWorkspace()..judgeDegraded = true;
      final events = <Map<String, dynamic>>[];
      final result = await runDartAgent(
        request: DartAgentRequest(
          mode: 'workspace',
          instruction: '盲评',
          model: 'scripted-model',
          baseUrl: 'https://example.invalid/v1',
          apiKey: 'k',
          workspaceHint: 'video',
        ),
        modelOverride: ScriptedAgentModel(<List<Part>>[
          <Part>[
            scriptToolCall(
              toolName: 'creative_judge',
              input: <String, dynamic>{
                'brief': '15s 片头',
                'kind': 'video',
                'track': 'silly_skit',
                'image_paths': <String>['/projects/video/x/artifacts/f1.png'],
              },
            ),
          ],
          <Part>[
            scriptToolCall(
              toolName: 'finish',
              input: <String, dynamic>{'summary': '停'},
            ),
          ],
        ]).model,
        workspace: workspace,
        onEvent: events.add,
      );
      expect(result.ok, isTrue);
      final end = events.firstWhere(
        (e) => e['type'] == 'tool_end' && e['tool'] == 'creative_judge',
      );
      expect(end['ok'], isFalse);
      expect(end['error'], 'judge_no_images');
      expect(end['message'], '没有渲染图证据，不能做盲评');
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
        modelOverride: ScriptedAgentModel(<List<Part>>[
          <Part>[
            scriptToolCall(
              toolName: 'nonapp_inspect',
              input: <String, dynamic>{'name': 'future'},
            ),
          ],
          <Part>[
            scriptToolCall(
              toolName: 'finish',
              input: <String, dynamic>{'summary': '停'},
            ),
          ],
        ]).model,
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
        modelOverride: ScriptedAgentModel(<List<Part>>[
          <Part>[
            scriptToolCall(
              toolName: 'figma_export',
              input: <String, dynamic>{'directory': '/tmp/x'},
            ),
          ],
          <Part>[
            scriptToolCall(
              toolName: 'finish',
              input: <String, dynamic>{'summary': '停'},
            ),
          ],
        ]).model,
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

  // 视频「生成有落地」（用户裁决 2026-11-20）：工作台 run 必须能从
  // video_sample 学到格式 → video_create 落盘 → video_list 看到项目，
  // 而不是只有内存里的 video_review 校验（关掉 run 什么都不剩）。
  group('视频生成工具（video_sample → video_create → video_list 接线）', () {
    test('三个工具进工具面并真执行；video_create 带 name/timeline/spec/title', () async {
      final engine = _FakeEngine();
      final workspace = _FakeWorkspace();
      final events = <Map<String, dynamic>>[];
      final model = ScriptedAgentModel(<List<Part>>[
        <Part>[
          scriptToolCall(
            toolName: 'video_sample',
            input: <String, dynamic>{'index': 1},
          ),
        ],
        <Part>[
          scriptToolCall(
            toolName: 'video_create',
            input: <String, dynamic>{
              'name': 'tagline-6s',
              'timeline': <String, dynamic>{
                'fps': 30,
                'width': 1280,
                'height': 720,
                'scenes': <dynamic>[
                  <String, dynamic>{'duration': 6, 'elements': <dynamic>[]},
                ],
              },
              'spec': <String, dynamic>{
                'kind': 'screenplay',
                'style': '扁平矢量',
                'beats': <dynamic>['起', '承'],
              },
              'title': '六秒标题动画',
            },
          ),
        ],
        <Part>[
          scriptToolCall(toolName: 'video_list', input: <String, dynamic>{}),
        ],
        <Part>[
          scriptToolCall(
            toolName: 'finish',
            input: <String, dynamic>{'summary': '视频已生成'},
          ),
        ],
      ]);

      final result = await runDartAgent(
        request: _buildRequest(engine),
        modelOverride: model.model,
        bridge: LocalEngineGate(engine),
        workspace: workspace,
        onEvent: events.add,
      );

      expect(result.ok, isTrue);
      expect(result.stopReason, 'done', reason: '成功落地的工作区调用不是 text_only');
      expect(
        workspace.calls,
        containsAll(<String>[
          'video_sample:1',
          'video_create:tagline-6s',
          'video_list',
        ]),
      );
      expect(workspace.lastVideoSampleIndex, 1);
      expect(workspace.lastVideoName, 'tagline-6s');
      expect(workspace.lastVideoTimeline?['fps'], 30);
      expect(workspace.lastVideoSpec?['kind'], 'screenplay');
      expect(workspace.lastVideoTitle, '六秒标题动画');
      // video_create 成功信封照常回给模型（片长/帧数是「生成有落地」的证据）。
      final createEnd = events.firstWhere(
        (e) => e['type'] == 'tool_end' && e['tool'] == 'video_create',
      );
      expect(createEnd['ok'], isTrue);
      // 轨迹里的入参整形：整份时间线/规范不进 tool_start 事件（防事件流被撑爆）。
      final createStart = events.firstWhere(
        (e) => e['type'] == 'tool_start' && e['tool'] == 'video_create',
      );
      expect(createStart['args']['name'], 'tagline-6s');
      expect(createStart['args']['timeline'], '<object 4 keys>');
      expect(createStart['args']['spec'], '<object 3 keys>');
      for (final tool in <String>[
        'video_sample',
        'video_create',
        'video_list',
      ]) {
        final end = events.firstWhere(
          (e) => e['type'] == 'tool_end' && e['tool'] == tool,
          orElse: () => <String, dynamic>{},
        );
        expect(end['ok'], isTrue, reason: tool);
      }
      final names = (model.calls.first.tools ?? const <ToolDefinition>[])
          .map((t) => t.name)
          .toSet();
      expect(
        names,
        containsAll(<String>['video_create', 'video_list', 'video_sample']),
      );
    });

    test('video_create 失败码 → tool_end.message 人话（原始码保留）', () async {
      final engine = _FakeEngine();
      final workspace = _FakeWorkspace()
        ..videoCreateResult = <String, dynamic>{
          'ok': false,
          'error': 'video_project_exists',
          'detail': 'tagline-6s',
        };
      final events = <Map<String, dynamic>>[];
      await runDartAgent(
        request: _buildRequest(engine),
        modelOverride: ScriptedAgentModel(<List<Part>>[
          <Part>[
            scriptToolCall(
              toolName: 'video_create',
              input: <String, dynamic>{
                'name': 'tagline-6s',
                'timeline': <String, dynamic>{'scenes': <dynamic>[]},
                'spec': <String, dynamic>{'kind': 'screenplay'},
              },
            ),
          ],
          <Part>[
            scriptToolCall(
              toolName: 'finish',
              input: <String, dynamic>{'summary': '停'},
            ),
          ],
        ]).model,
        bridge: LocalEngineGate(engine),
        workspace: workspace,
        onEvent: events.add,
      );
      final end = events.firstWhere(
        (e) => e['type'] == 'tool_end' && e['tool'] == 'video_create',
      );
      expect(end['ok'], isFalse);
      expect(end['error'], 'video_project_exists');
      expect(end['message'], '已经有同名视频了，换一个名字再新建（已生成的视频不会被覆盖）');
      expect(end['detail'], 'tagline-6s');
    });

    test('video_create 的 timeline 不是对象 → invalid_args 人话，不打服务', () async {
      final engine = _FakeEngine();
      final workspace = _FakeWorkspace();
      final events = <Map<String, dynamic>>[];
      await runDartAgent(
        request: _buildRequest(engine),
        modelOverride: ScriptedAgentModel(<List<Part>>[
          <Part>[
            scriptToolCall(
              toolName: 'video_create',
              input: <String, dynamic>{
                'name': 'bad',
                'timeline': 'not-an-object',
              },
            ),
          ],
          <Part>[
            scriptToolCall(
              toolName: 'finish',
              input: <String, dynamic>{'summary': '停'},
            ),
          ],
        ]).model,
        bridge: LocalEngineGate(engine),
        workspace: workspace,
        onEvent: events.add,
      );
      final end = events.firstWhere(
        (e) => e['type'] == 'tool_end' && e['tool'] == 'video_create',
      );
      expect(end['ok'], isFalse);
      expect(end['error'], 'invalid_args');
      expect(end['message'], '时间线格式不对：先看一份完整示例，再按同样结构填写');
      expect(
        workspace.calls.where((c) => c.startsWith('video_create')),
        isEmpty,
        reason: '参数不对就不该打到服务',
      );
    });
  });

  // 真实落地面：LocalWorkspaceServices → VideoProjectStore（先校验后落盘）。
  group('LocalWorkspaceServices 视频生成（真实项目库）', () {
    Map<String, dynamic> sampleTimeline(int index) => Map<String, dynamic>.from(
      jsonDecode(videoSamples[index].timelineJson) as Map,
    );
    Map<String, dynamic> sampleSpec(int index) => Map<String, dynamic>.from(
      jsonDecode(videoSamples[index].specJson) as Map,
    );

    test('video_sample 给完整示例；video_create 落盘三件套；video_list 含内置+生成', () async {
      final root = Directory.systemTemp.createTempSync('video-agent-');
      addTearDown(() {
        try {
          root.deleteSync(recursive: true);
        } catch (_) {}
      });
      final services = LocalWorkspaceServices(
        model: 'm',
        baseUrl: 'https://example.invalid/v1',
        apiKey: 'k',
        videoProjects: VideoProjectStore(root: root),
      );

      final sampleOut = await services.videoSample(index: 1);
      expect(sampleOut['ok'], isTrue);
      expect(sampleOut['count'], videoSamples.length);
      expect(sampleOut['timeline'], isA<Map>());
      expect(sampleOut['spec'], isA<Map>());
      expect((sampleOut['seconds'] as num).toDouble(), greaterThan(0));
      expect((sampleOut['fps'] as num).toInt(), greaterThan(0));

      final created = await services.videoCreate(
        name: 'cell-division',
        timeline: sampleTimeline(1),
        spec: sampleSpec(1),
        title: '细胞分裂',
      );
      expect(created['ok'], isTrue);
      expect(created['video'], 'cell-division');
      expect(created['title'], '细胞分裂');
      expect((created['seconds'] as num).toDouble(), greaterThan(0));
      expect((created['frames'] as num).toInt(), greaterThan(0));
      // 落盘：目录成立且三份文件齐全（关掉 run 之后工作台还能播放）。
      final dir = Directory('${root.path}/cell-division');
      expect(dir.existsSync(), isTrue);
      for (final file in <String>['timeline.json', 'spec.json', 'video.json']) {
        expect(File('${dir.path}/$file').existsSync(), isTrue, reason: file);
      }

      final listed = await services.videoList();
      expect(listed['ok'], isTrue);
      final videos = (listed['videos'] as List).cast<Map>();
      expect(
        videos.any(
          (v) => v['name'] == 'cell-division' && v['builtin'] == false,
        ),
        isTrue,
      );
      expect(
        videos.where((v) => v['builtin'] == true),
        hasLength(videoSamples.length),
      );
      expect(videos.map((v) => v['name']), contains('cell-division'));
    });

    test('失败码稳定：同名 / 非法名 / 缺规范 / 空场景 都是 video_ 前缀 + 人话', () async {
      final root = Directory.systemTemp.createTempSync('video-agent-');
      addTearDown(() {
        try {
          root.deleteSync(recursive: true);
        } catch (_) {}
      });
      final services = LocalWorkspaceServices(
        model: 'm',
        baseUrl: 'https://example.invalid/v1',
        apiKey: 'k',
        videoProjects: VideoProjectStore(root: root),
      );

      final first = await services.videoCreate(
        name: 'demo',
        timeline: sampleTimeline(2),
        spec: sampleSpec(2),
      );
      expect(first['ok'], isTrue);

      final duplicate = await services.videoCreate(
        name: 'demo',
        timeline: sampleTimeline(2),
        spec: sampleSpec(2),
      );
      expect(duplicate['ok'], isFalse);
      expect(duplicate['error'], 'video_project_exists');
      expect(duplicate['message'], contains('同名视频'));

      final badName = await services.videoCreate(
        name: '有 空格',
        timeline: sampleTimeline(0),
        spec: sampleSpec(0),
      );
      expect(badName['ok'], isFalse);
      expect(badName['error'], 'video_invalid_name');
      expect(badName['message'], contains('视频名只能用字母'));

      final noSpec = await services.videoCreate(
        name: 'no-spec',
        timeline: sampleTimeline(0),
      );
      expect(noSpec['ok'], isFalse);
      expect(noSpec['error'], 'video_spec_missing');

      final noScenes = await services.videoCreate(
        name: 'empty-scenes',
        timeline: <String, dynamic>{'fps': 30, 'scenes': <dynamic>[]},
        spec: sampleSpec(0),
      );
      expect(noScenes['ok'], isFalse);
      expect(noScenes['error'], 'video_no_scenes');
      expect(noScenes['message'], contains('没有任何场景'));
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
      expect(
        result.files,
        containsAll(<String>[
          'board-home_v2.svg',
          'nondesign.json',
          'README.txt',
        ]),
      );
      expect(
        File('${dir.path}/board-home_v2.svg').readAsStringSync(),
        '<svg id="home"></svg>',
      );

      final manifest = jsonDecode(
        File('${dir.path}/nondesign.json').readAsStringSync(),
      ) as Map<String, dynamic>;
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
      expect(node['rect'], <String, dynamic>{
        'x': 1.0,
        'y': 2.0,
        'w': 30.0,
        'h': 40.0,
      });
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
      final result = await exporter.export(
        render: _renderEnvelope(),
        directory: dir.path,
      );
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

  // 回归（Windows 实测日志 `Step 0 called unknown tool "video_review"`）：
  // workspace 模式的 run 曾经把工作区工具整块漏注册——设计画布工具块与
  // 工作区工具块嵌套在同一层 `if`，`mode == 'workspace'` 一刀把两者都关了，
  // 模型只剩 finish/ask_user/read_docs，调 three_*/video_review 必然
  // AiNoSuchToolError 打死整轮（3D / 视频两个工作台同时「无工具 → 失败」）。
  // 这里锚定工作区 run 的工具面：工作区工具在、画布/文档工具不在。
  group('workspace mode tool surface', () {
    DartAgentRequest workspaceRequest(String hint) => DartAgentRequest(
      mode: 'workspace',
      instruction: '在工作台里做东西',
      mbt: '',
      model: 'scripted-model',
      baseUrl: 'https://example.invalid/v1',
      apiKey: 'k',
      workspaceHint: hint,
    );

    Set<String> toolsOf(ModelRequest request) =>
        (request.tools ?? const <ToolDefinition>[]).map((t) => t.name).toSet();

    Future<Set<String>> surfaceFor(String hint) async {
      final workspace = _FakeWorkspace();
      final model = ScriptedAgentModel(<List<Part>>[
        <Part>[
          scriptToolCall(
            toolName: 'finish',
            input: <String, dynamic>{'summary': '看工具面'},
          ),
        ],
      ]);
      final result = await runDartAgent(
        request: workspaceRequest(hint),
        modelOverride: model.model,
        workspace: workspace,
      );
      expect(result.ok, isTrue);
      return (model.calls.first.tools ?? const <ToolDefinition>[])
          .map((t) => t.name)
          .toSet();
    }

    test('three 收窄：只暴露 three_*，其他工作台/画布/文档工具不可见', () async {
      final names = await surfaceFor('three');
      expect(
        names,
        containsAll(<String>[
          'three_list',
          'three_create',
          'three_status',
          'three_pass',
          'three_continue',
          'three_feedback',
          'three_workspace_migrate',
          'three_plan_validate',
          'three_measure',
          'three_build',
          'three_check',
          'three_check_placement',
        ]),
      );
      for (final other in <String>[
        'video_create',
        'video_list',
        'hotapp_generate',
        'nonapp_list',
        'figma_export',
        'design_verify_prototype',
      ]) {
        expect(names.contains(other), isFalse, reason: 'three run 不该暴露 $other');
      }
      for (final canvas in <String>[
        'design_op',
        'generate_page',
        'read_mbt',
        'inspect',
        'write_doc',
        'write_design_spec',
      ]) {
        expect(names.contains(canvas), isFalse, reason: '工作区 run 不该暴露 $canvas');
      }
    });

    test('video 收窄：只暴露 video_*', () async {
      final names = await surfaceFor('video');
      expect(
        names,
        containsAll(<String>[
          'video_list',
          'video_sample',
          'video_create',
          'video_review',
          // 引擎短片（nan.screenplay/1）也是 `video_` 前缀：同属视频工作区。
          'video_short_list',
          'video_short_status',
          'video_short_create',
        ]),
      );
      expect(
        names.where(
          (n) =>
              n.startsWith('three_') ||
              n.startsWith('hotapp_') ||
              n.startsWith('nonapp_'),
        ),
        isEmpty,
      );
    });

    test('video3d 收窄：只暴露 video3d_*，不混入视频/3D 工具', () async {
      final names = await surfaceFor('video3d');
      expect(
        names,
        containsAll(<String>[
          'video3d_list',
          'video3d_status',
          'video3d_create',
          'video3d_render_frames',
        ]),
      );
      // `video3d_…` 不以 `video_` 开头：`video` 收窄不会误纳它，反过来
      // `video3d` 收窄也不该混入 v1 视频 / 3D / 热应用 / 音乐的工具。
      expect(
        names.where(
          (n) =>
              n.startsWith('video_') ||
              n.startsWith('three_') ||
              n.startsWith('hotapp_') ||
              n.startsWith('nonapp_') ||
              n.startsWith('music_'),
        ),
        isEmpty,
      );
    });

    test('hotapp 收窄：热应用 + 应用包，不暴露 3D/视频', () async {
      final names = await surfaceFor('hotapp');
      expect(
        names,
        containsAll(<String>[
          'hotapp_list',
          'hotapp_generate',
          'hotapp_refine',
          'hotapp_inspect',
          'nonapp_list',
          'nonapp_inspect',
        ]),
      );
      expect(
        names.where((n) => n.startsWith('three_') || n.startsWith('video_')),
        isEmpty,
      );
    });

    test('music 收窄：只暴露 music_* + 通用只读，其他工作台前缀不可见', () async {
      final names = await surfaceFor('music');
      expect(
        names,
        containsAll(<String>[
          'music_list',
          'music_read',
          'music_inspect',
          'music_create',
          'music_patch',
        ]),
      );
      expect(
        names.where(
          (n) =>
              n.startsWith('three_') ||
              n.startsWith('video_') ||
              n.startsWith('hotapp_') ||
              n.startsWith('nonapp_') ||
              n.startsWith('figma_') ||
              n.startsWith('design_'),
        ),
        isEmpty,
        reason: 'music run 不该暴露其他模块工具',
      );
      // 与 three/video/hotapp 同法：通用工具（ask_user / finish / read_docs）
      // 不受模块收窄影响；画布/文档写工具不可见。
      expect(names, containsAll(<String>['ask_user', 'finish', 'read_docs']));
      for (final canvas in <String>[
        'design_op',
        'generate_page',
        'read_mbt',
        'inspect',
        'write_doc',
        'write_design_spec',
      ]) {
        expect(names.contains(canvas), isFalse, reason: '工作区 run 不该暴露 $canvas');
      }
    });

    test('音乐工作台 run：music_create 真执行且算真实交付（remoteCalls 水位）', () async {
      final workspace = _FakeWorkspace();
      final events = <Map<String, dynamic>>[];
      final model = ScriptedAgentModel(<List<Part>>[
        <Part>[
          scriptToolCall(
            toolName: 'music_create',
            input: <String, dynamic>{
              'name': 'dawn',
              'score': <String, dynamic>{
                'schemaVersion': 1,
                'tracks': <dynamic>[],
              },
            },
          ),
        ],
        <Part>[
          scriptToolCall(
            toolName: 'finish',
            input: <String, dynamic>{'summary': '完成'},
          ),
        ],
      ]);
      final result = await runDartAgent(
        request: workspaceRequest('music'),
        modelOverride: model.model,
        workspace: workspace,
        onEvent: events.add,
      );
      expect(result.ok, isTrue);
      expect(workspace.calls, contains('music_create:dawn'));
      expect(workspace.lastMusicScore, isNotNull);
      final end = events.firstWhere(
        (e) => e['type'] == 'tool_end' && e['tool'] == 'music_create',
      );
      expect(end['ok'], isTrue);
      expect(
        result.remoteCalls,
        greaterThanOrEqualTo(1),
        reason: '成功的音乐新建必须移动交付水位（不能被当成「工作台里没有东西」）',
      );
      // 工具标签必须是人话（出货文案门）。
      expect(toolLabel('music_create'), '音乐 · 新建');
    });

    test('音乐工作台 run：music_patch 真执行且算真实交付（remoteCalls 水位）', () async {
      final workspace = _FakeWorkspace();
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
            toolName: 'finish',
            input: <String, dynamic>{'summary': '乐谱已改并通过校验'},
          ),
        ],
      ]);
      final result = await runDartAgent(
        request: workspaceRequest('music'),
        modelOverride: model.model,
        workspace: workspace,
        onEvent: events.add,
      );
      expect(result.ok, isTrue);
      expect(workspace.calls, contains('music_patch:dawn'));
      expect(workspace.lastMusicPatchName, 'dawn');
      expect(workspace.lastMusicPatchOps, hasLength(2));
      expect(workspace.lastMusicPatchOps!.first['op'], 'replace');
      expect(workspace.lastMusicPatchOps!.first['path'], '/title');
      final end = events.firstWhere(
        (e) => e['type'] == 'tool_end' && e['tool'] == 'music_patch',
      );
      expect(end['ok'], isTrue);
      expect(end['preview'], contains('applied'));
      expect(end['preview'], contains('verified'));
      expect(
        result.remoteCalls,
        greaterThanOrEqualTo(1),
        reason: '成功的确定性补丁也是真实交付（不能被当成 text_only）',
      );
      // 工具标签必须是人话；长 ops 数组进轨迹前压成形状摘要。
      expect(toolLabel('music_patch'), '音乐 · 修改');
      final start = events.firstWhere(
        (e) => e['type'] == 'tool_start' && e['tool'] == 'music_patch',
      );
      expect((start['args'] as Map)['ops'], '<list 2>');
    });

    test('音乐补丁入参形状：ops 不是数组 → invalid_args（不调用服务）', () async {
      final workspace = _FakeWorkspace();
      final events = <Map<String, dynamic>>[];
      final model = ScriptedAgentModel(<List<Part>>[
        <Part>[
          scriptToolCall(
            toolName: 'music_patch',
            input: <String, dynamic>{'name': 'dawn', 'ops': 'not-a-list'},
          ),
        ],
        <Part>[
          scriptToolCall(
            toolName: 'finish',
            input: <String, dynamic>{'summary': '参数不对'},
          ),
        ],
      ]);
      final result = await runDartAgent(
        request: workspaceRequest('music'),
        modelOverride: model.model,
        workspace: workspace,
        onEvent: events.add,
      );
      expect(result.ok, isTrue);
      // 工具层先挡住坏形状：服务层不会被调到，事件面给出人话。
      expect(
        workspace.calls.where((c) => c.startsWith('music_patch')),
        isEmpty,
      );
      final end = events.firstWhere(
        (e) => e['type'] == 'tool_end' && e['tool'] == 'music_patch',
      );
      expect(end['ok'], isFalse);
      expect(end['error'], 'invalid_args');
      expect(end['message'], contains('ops'));
      expect(result.remoteCalls, 0, reason: '被工具层拒绝的补丁不是交付，不能移动水位');
    });

    test('3D 工作台 run：three_create 真执行（不再 unknown tool）', () async {
      final workspace = _FakeWorkspace();
      final events = <Map<String, dynamic>>[];
      final model = ScriptedAgentModel(<List<Part>>[
        <Part>[
          scriptToolCall(
            toolName: 'three_create',
            input: <String, dynamic>{'name': 'island', 'brief': '一座浮岛'},
          ),
        ],
        <Part>[
          scriptToolCall(
            toolName: 'finish',
            input: <String, dynamic>{'summary': '完成'},
          ),
        ],
      ]);
      final result = await runDartAgent(
        request: workspaceRequest('three'),
        modelOverride: model.model,
        workspace: workspace,
        onEvent: events.add,
      );
      expect(result.ok, isTrue);
      expect(workspace.calls, contains('three_create:island'));
      final end = events.firstWhere(
        (e) => e['type'] == 'tool_end' && e['tool'] == 'three_create',
      );
      expect(end['ok'], isTrue);
    });

    test('视频工作台 run：video_review 真执行（不再 unknown tool）', () async {
      final workspace = _FakeWorkspace();
      final events = <Map<String, dynamic>>[];
      final model = ScriptedAgentModel(<List<Part>>[
        <Part>[
          scriptToolCall(
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
        <Part>[
          scriptToolCall(
            toolName: 'finish',
            input: <String, dynamic>{'summary': '完成'},
          ),
        ],
      ]);
      final result = await runDartAgent(
        request: workspaceRequest('video'),
        modelOverride: model.model,
        workspace: workspace,
        onEvent: events.add,
      );
      expect(result.ok, isTrue);
      expect(workspace.calls, contains('video_review'));
      final end = events.firstWhere(
        (e) => e['type'] == 'tool_end' && e['tool'] == 'video_review',
      );
      expect(end['ok'], isTrue);
    });

    test('3D 视频工作台 run：video3d_create 真执行（不再 unknown tool）', () async {
      final workspace = _FakeWorkspace();
      final events = <Map<String, dynamic>>[];
      final model = ScriptedAgentModel(<List<Part>>[
        <Part>[
          scriptToolCall(
            toolName: 'video3d_create',
            input: <String, dynamic>{
              'name': 'stage',
              'scene': <String, dynamic>{'v': 1, 'units': 'm'},
              'screenplay': <String, dynamic>{
                'v': 1,
                'fps': 30,
                'shots': <dynamic>[],
              },
            },
          ),
        ],
        <Part>[
          scriptToolCall(
            toolName: 'finish',
            input: <String, dynamic>{'summary': '完成'},
          ),
        ],
      ]);
      final result = await runDartAgent(
        request: workspaceRequest('video3d'),
        modelOverride: model.model,
        workspace: workspace,
        onEvent: events.add,
      );
      expect(result.ok, isTrue);
      expect(workspace.calls, contains('video3d_create:stage'));
      // 两份事实源按对象原样传给服务（不是被字符串化的 JSON）。
      expect(workspace.lastVideo3dScene, isNotNull);
      expect(workspace.lastVideo3dScreenplay, isNotNull);
      final end = events.firstWhere(
        (e) => e['type'] == 'tool_end' && e['tool'] == 'video3d_create',
      );
      expect(end['ok'], isTrue);
    });

    test('3D 视频工作台 run：video3d_render_frames 真执行（抓帧取证）', () async {
      final workspace = _FakeWorkspace();
      final events = <Map<String, dynamic>>[];
      final model = ScriptedAgentModel(<List<Part>>[
        <Part>[
          scriptToolCall(
            toolName: 'video3d_render_frames',
            input: <String, dynamic>{
              'name': 'stage',
              'frames': <int>[0, 90],
            },
          ),
        ],
        <Part>[
          scriptToolCall(
            toolName: 'finish',
            input: <String, dynamic>{'summary': '完成'},
          ),
        ],
      ]);
      final result = await runDartAgent(
        request: workspaceRequest('video3d'),
        modelOverride: model.model,
        workspace: workspace,
        onEvent: events.add,
      );
      expect(result.ok, isTrue);
      expect(
        workspace.calls,
        contains('video3d_render_frames:stage:0,90'),
      );
      expect(workspace.lastVideo3dFrames, <int>[0, 90]);
      final end = events.firstWhere(
        (e) => e['type'] == 'tool_end' && e['tool'] == 'video3d_render_frames',
      );
      expect(end['ok'], isTrue);
    });

    test('video 工作台 run：video_short_create 真执行（剧本先校验后落盘）', () async {
      final workspace = _FakeWorkspace();
      final events = <Map<String, dynamic>>[];
      final model = ScriptedAgentModel(<List<Part>>[
        <Part>[
          scriptToolCall(
            toolName: 'video_short_create',
            input: <String, dynamic>{
              'name': 'short',
              'screenplay': <String, dynamic>{
                'schema': 'nan.screenplay/1',
                'width': 320,
                'height': 180,
                'shots': <dynamic>[
                  <String, dynamic>{
                    'id': 's1',
                    'start': 0.0,
                    'duration': 2.0,
                    'events': <dynamic>[
                      <String, dynamic>{
                        'f': 15,
                        'type': 'vfx',
                        'cue': 'fire.campfire',
                      },
                    ],
                  },
                ],
              },
            },
          ),
        ],
        <Part>[
          scriptToolCall(
            toolName: 'finish',
            input: <String, dynamic>{'summary': '完成'},
          ),
        ],
      ]);
      final result = await runDartAgent(
        request: workspaceRequest('video'),
        modelOverride: model.model,
        workspace: workspace,
        onEvent: events.add,
      );
      expect(result.ok, isTrue);
      expect(workspace.calls, contains('video_short_create:short'));
      expect(
        workspace.lastVideoShortScreenplay,
        containsPair('schema', 'nan.screenplay/1'),
      );
      final end = events.firstWhere(
        (e) => e['type'] == 'tool_end' && e['tool'] == 'video_short_create',
      );
      expect(end['ok'], isTrue);
    });

    test('plan 模式工具面不变：注入工作区服务也不暴露工作区/画布写工具', () async {
      final workspace = _FakeWorkspace();
      final model = ScriptedAgentModel(<List<Part>>[
        <Part>[
          scriptToolCall(
            toolName: 'finish',
            input: <String, dynamic>{'summary': '看工具面'},
          ),
        ],
      ]);
      final planRequest = DartAgentRequest(
        mode: 'plan',
        instruction: '写文档',
        mbt: '',
        model: 'scripted-model',
        baseUrl: 'https://example.invalid/v1',
        apiKey: 'k',
        workspaceHint: 'video',
      );
      await runDartAgent(
        request: planRequest,
        modelOverride: model.model,
        workspace: workspace,
        // 工作区工具只在非 plan 暴露（runDartAgent 对 plan 置 null）。
      );
      final names = toolsOf(model.calls.first);
      expect(names, contains('write_doc'));
      expect(names, contains('write_design_spec'));
      expect(names, contains('ask_user'));
      for (final name in <String>[
        'video_create',
        'video_list',
        'video_sample',
        'video_review',
        'three_create',
        'three_list',
        'design_op',
        'generate_page',
      ]) {
        expect(names.contains(name), isFalse, reason: 'plan 模式不该有 $name');
      }
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
  Future<Map<String, dynamic>> session(
    String mbt,
    String name, [
    String? arg,
  ]) => engine.session(mbt, name, arg);

  @override
  Future<List<dynamic>> templates() => engine.templates();

  @override
  Future<List<dynamic>> components() => engine.components();
}
