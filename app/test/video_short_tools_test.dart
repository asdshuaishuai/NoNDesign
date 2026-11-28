// 引擎短片工具面：真项目存储端到端（创建/查看/列表 + 失败码 + 不落半成品）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:nondesign/core/dart_agent.dart';
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

  test('非法项目名：video_short_invalid_name', () async {
    final Map<String, dynamic> result = await services.videoShortCreate(
      name: '../escape',
      screenplay: _screenplay(),
    );
    expect(result['ok'], isFalse);
    expect(result['error'], 'video_short_invalid_name');
  });
}
