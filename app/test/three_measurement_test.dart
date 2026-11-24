import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nondesign/core/three_service.dart';

const Map<String, dynamic> _spec = <String, dynamic>{
  'title': 'Saturn',
  'summary': '带环行星',
  'components': <Map<String, dynamic>>[
    <String, dynamic>{'id': 'planet', 'what': '球体', 'size_scale': 1.0},
    <String, dynamic>{'id': 'ring', 'what': '扁平圆环', 'size_scale': 1.8},
  ],
  'materials': <Map<String, dynamic>>[
    <String, dynamic>{'id': 'rock'},
  ],
  'acceptance': <String>['行星在场', '环可见 ≤2mm'],
};

ThreeService _service(Directory root) => ThreeService(
  root: root,
  llm: (_) async => '```json\n${jsonEncode(_spec)}\n```',
  assets: (_) async => Uint8List(0),
);

const ThreeLlmConfig _config = ThreeLlmConfig(
  model: 'm',
  baseUrl: 'https://example.invalid/v1',
  apiKey: 'k',
);

Map<String, dynamic> _measurement({bool includeParts = true}) =>
    <String, dynamic>{
      'path': 'legacy',
      'meshes': 2,
      'triangles': 240,
      'bounds': <String, double>{'x': 1.8, 'y': 1.8, 'z': 1.8},
      if (includeParts)
        'parts': <dynamic>[
          <String, dynamic>{
            'id': 'planet',
            'bbox': <String, dynamic>{
              'min': <double>[-0.5, 0, -0.5],
              'max': <double>[0.5, 1, 0.5],
            },
            'triangles': 120,
          },
          <String, dynamic>{
            'id': 'ring',
            'bbox': <String, dynamic>{
              'min': <double>[-0.9, 0.4, -0.9],
              'max': <double>[0.9, 0.5, 0.9],
            },
            'triangles': 120,
          },
        ],
    };

void main() {
  late Directory temp;
  late ThreeService service;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('nondesign-3dmeasure-');
    service = _service(temp);
    await service.newProject(name: 'saturn', brief: '带环行星', config: _config);
  });

  tearDown(() async {
    await temp.delete(recursive: true);
  });

  test('metrics 反馈落 artifacts/measurement.json，latestMeasurement 可读', () async {
    await service.feedback('saturn', 'metrics', _measurement());
    final file = File('${temp.path}/saturn/artifacts/measurement.json');
    expect(file.existsSync(), isTrue);
    final decoded = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    expect(decoded['v'], 1);
    expect((decoded['parts'] as List), hasLength(2));

    final latest = await service.latestMeasurement('saturn');
    expect(latest['ok'], isTrue);
    expect(latest['part_count'], 2);
    expect(latest['triangles'], 240);
    final parts = latest['parts'] as List;
    expect((parts.first as Map)['id'], 'planet');
    expect(((parts.first as Map)['bbox'] as Map)['min'], <double>[
      -0.5,
      0,
      -0.5,
    ]);
  });

  test('没有测量 → three_measure_missing；坏文件 → corrupt', () async {
    final missing = await service.latestMeasurement('saturn');
    expect(missing['ok'], isFalse);
    expect(missing['error'], 'three_measure_missing');

    final file = File('${temp.path}/saturn/artifacts/measurement.json');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('{not json');
    final corrupt = await service.latestMeasurement('saturn');
    expect(corrupt['ok'], isFalse);
    expect(corrupt['error'], 'three_measure_corrupt');
  });

  test('迁移后 three_check 省略 measurement 时自动读最新测量并落 gates.json', () async {
    final migration = await service.workspaceMigrate('saturn');
    expect(migration['ok'], isTrue);
    await service.feedback('saturn', 'metrics', _measurement());
    final check = await service.workspaceCheckGates('saturn', null);
    expect(check['ok'], isTrue, reason: '$check');
    expect(check['verdict'], isA<String>());
    expect(check['gates'], isA<List>());
    expect(
      File('${temp.path}/saturn/artifacts/gates.json').existsSync(),
      isTrue,
    );
    final gates = jsonDecode(
      File('${temp.path}/saturn/artifacts/gates.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    expect(gates['verdict'], isA<String>());
    expect(gates['gates'], isA<List>());
  });

  test('没有测量时 three_check 报 three_measure_missing，不伪造 PASS', () async {
    await service.workspaceMigrate('saturn');
    final check = await service.workspaceCheckGates('saturn', null);
    expect(check['ok'], isFalse);
    expect(check['error'], 'three_measure_missing');
  });
}
