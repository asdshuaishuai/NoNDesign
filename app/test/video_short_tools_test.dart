// 引擎短片工具面：真项目存储端到端（创建/查看/列表 + 失败码 + 不落半成品）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:nondesign/core/dart_agent.dart';
import 'package:nondesign/core/video/video_short_evidence.dart';
import 'package:nondesign/core/video/video_short_project.dart';

Map<String, Object?> _screenplay() => <String, Object?>{
  'schema': 'nan.screenplay/1',
  'width': 320,
  'height': 180,
  'shots': <Object?>[
    <String, Object?>{
      'id': 's1',
      'start': 0.0,
      'duration': 2.0,
      'events': <Object?>[
        <String, Object?>{
          'f': 15,
          'type': 'vfx',
          'cue': 'ice.frost-breath',
        },
      ],
    },
  ],
};

void main() {
  late Directory root;
  late VideoShortProjectStore store;
  late LocalWorkspaceServices services;

  setUp(() {
    root = Directory.systemTemp.createTempSync('video-short-tools-');
    store = VideoShortProjectStore(root: root);
    services = LocalWorkspaceServices(
      model: 'scripted-model',
      baseUrl: 'https://example.invalid/v1',
      apiKey: 'k',
      videoShortProjects: store,
    );
  });

  tearDown(() {
    if (root.existsSync()) {
      try {
        root.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  test('创建：先校验后落盘，回镜头/帧/事件摘要', () async {
    final Map<String, dynamic> result = await services.videoShortCreate(
      name: 'short',
      screenplay: _screenplay(),
    );
    expect(result['ok'], isTrue);
    expect(result['project'], 'short');
    expect(result['shots'], 1);
    expect(result['frames'], 60);
    expect(result['events'], 1);
    expect(result['vfx_events'], 1);
    expect(
      File('${root.path}/short/screenplay.json').existsSync(),
      isTrue,
    );
  });

  test('未知 cue：不落盘 + 回问题清单（不静默丢事件）', () async {
    final Map<String, Object?> bad = _screenplay();
    (bad['shots'] as List<Object?>)[0] =
        <String, Object?>{
          'id': 's1',
          'start': 0.0,
          'duration': 2.0,
          'events': <Object?>[
            <String, Object?>{'f': 1, 'type': 'vfx', 'cue': 'fire.unknown'},
          ],
        };
    final Map<String, dynamic> result = await services.videoShortCreate(
      name: 'bad',
      screenplay: bad,
    );
    expect(result['ok'], isFalse);
    expect(result['error'], 'video_short_unverified');
    expect(result['checks'], isNotNull);
    expect(Directory('${root.path}/bad').existsSync(), isFalse);
  });

  test('同名已存在：拒绝覆盖（稳定失败码）', () async {
    await services.videoShortCreate(
      name: 'short',
      screenplay: _screenplay(),
    );
    final Map<String, dynamic> second = await services.videoShortCreate(
      name: 'short',
      screenplay: _screenplay(),
    );
    expect(second['ok'], isFalse);
    expect(second['error'], 'video_short_exists');
    expect(second['message'], toolFailureMessage('video_short_exists'));
  });

  test('查看：回原始剧本 + 校验 + 帧/事件计数', () async {
    await services.videoShortCreate(
      name: 'short',
      screenplay: _screenplay(),
    );
    final Map<String, dynamic> status = await services.videoShortStatus('short');
    expect(status['ok'], isTrue);
    expect(status['verified'], isTrue);
    expect(status['frames'], 60);
    expect(status['vfx_events'], 1);
    expect(status['screenplay'], isNotNull);
  });

  test('查看不存在：video_short_no_project', () async {
    final Map<String, dynamic> status = await services.videoShortStatus('nope');
    expect(status['ok'], isFalse);
    expect(status['error'], 'video_short_no_project');
  });

  test('列表：包含已建项目与元数据', () async {
    await services.videoShortCreate(
      name: 'short',
      screenplay: _screenplay(),
    );
    final Map<String, dynamic> list = await services.videoShortList();
    expect(list['ok'], isTrue);
    expect(list['count'], 1);
    final List<dynamic> projects = list['projects'] as List<dynamic>;
    final Map<String, dynamic> first =
        (projects.first as Map<Object?, Object?>).cast<String, dynamic>();
    expect(first['name'], 'short');
    expect(first['frames'], 60);
    expect(first['verified'], isTrue);
  });

  group('抓帧工具（video_short_render_frames）', () {
    const String pngBase64 =
        'iVBORw0KGgpJSERSAAAADQAAAAEAAAABCAIAAACQd1PeSURBVAAAAAx4nGNgYGAAAAAEAAH2FzhV'
        'SUVORAAAAACuQmCC';

    LocalWorkspaceServices withRunner(
      VideoShortCaptureRunner? runner,
    ) => LocalWorkspaceServices(
      model: 'scripted-model',
      baseUrl: 'https://example.invalid/v1',
      apiKey: 'k',
      videoShortProjects: store,
      videoShortCaptureRunner: runner,
    );

    VideoShortCaptureRunner okRunner(List<int>? seen) =>
        (String project, List<int> frames) async {
          seen?.addAll(frames);
          return <VideoShortFrameEvidence>[
            for (final int frame in frames)
              VideoShortFrameEvidence(
                frame: frame,
                bytes: base64Decode(pngBase64),
                renderer: 'phaser4_canvas',
                vfx: 'pixelfx_pixels',
              ),
          ];
        };

    test('预览已打开：抓帧 → 落 artifacts/renders + 确定性清单', () async {
      await services.videoShortCreate(
        name: 'short',
        screenplay: _screenplay(),
      );
      final List<int> seen = <int>[];
      final LocalWorkspaceServices withCapture = withRunner(okRunner(seen));
      final Map<String, dynamic> result = await withCapture
          .videoShortRenderFrames(name: 'short', frames: <int>[20, 0, 20]);
      expect(result['ok'], isTrue);
      // 去重 + 升序。
      expect(seen, <int>[0, 20]);
      expect(result['count'], 2);
      expect(result['vfx'], 'pixelfx_pixels');
      expect(result['manifest'], 'artifacts/renders/renders.json');
      expect(
        File('${root.path}/short/artifacts/renders/frame-0020.png').existsSync(),
        isTrue,
      );
    });

    test('预览没打开（没有 runner）：显性失败，不写文件', () async {
      await services.videoShortCreate(
        name: 'short',
        screenplay: _screenplay(),
      );
      final Map<String, dynamic> result = await withRunner(null)
          .videoShortRenderFrames(name: 'short', frames: <int>[0]);
      expect(result['ok'], isFalse);
      expect(result['error'], 'video_short_capture_unavailable');
      expect(
        Directory('${root.path}/short/artifacts').existsSync(),
        isFalse,
      );
    });

    test('帧号越界：拒绝且不调用抓帧', () async {
      await services.videoShortCreate(
        name: 'short',
        screenplay: _screenplay(),
      );
      bool called = false;
      final LocalWorkspaceServices withCapture = withRunner((
        String project,
        List<int> frames,
      ) async {
        called = true;
        return <VideoShortFrameEvidence>[];
      });
      final Map<String, dynamic> result = await withCapture
          .videoShortRenderFrames(name: 'short', frames: <int>[60]);
      expect(result['ok'], isFalse);
      expect(result['error'], 'video_short_frames_out_of_range');
      expect(called, isFalse);
    });

    test('抓帧超时：error.code 原样映射到信封', () async {
      await services.videoShortCreate(
        name: 'short',
        screenplay: _screenplay(),
      );
      final LocalWorkspaceServices withCapture = withRunner((
        String project,
        List<int> frames,
      ) async {
        throw const VideoShortEvidenceError(
          videoShortCaptureTimeoutCode,
          '这一帧等超时了',
        );
      });
      final Map<String, dynamic> result = await withCapture
          .videoShortRenderFrames(name: 'short', frames: <int>[0]);
      expect(result['ok'], isFalse);
      expect(result['error'], videoShortCaptureTimeoutCode);
      expect(
        result['message'],
        toolFailureMessage(videoShortCaptureTimeoutCode),
      );
    });
  });

  test('非法项目名：video_short_invalid_name', () async {
    final Map<String, dynamic> result = await services.videoShortCreate(
      name: '../escape',
      screenplay: _screenplay(),
    );
    expect(result['ok'], isFalse);
    expect(result['error'], 'video_short_invalid_name');
  });
}
