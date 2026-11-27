// 帧证据落盘：`artifacts/renders/` 的 PNG + 确定性清单。
//
// 覆盖：文件名派生 / 清单字节确定 / 事实源不动 / 去重 / 渲染器混用拒绝 /
// 项目不存在 / 不留临时文件。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nondesign/core/video3d/video3d_evidence.dart';
import 'package:nondesign/core/video3d/video3d_project.dart';

/// 69 字节的合法 1×1 PNG。
const String _pngBase64 =
    'iVBORw0KGgpJSERSAAAADQAAAAEAAAABCAIAAACQd1PeSURBVAAAAAx4nGNgYGAAAAAEAAH2FzhV'
    'SUVORAAAAACuQmCC';

Uint8List _png() => base64Decode(_pngBase64);

Map<String, Object?> _validScene() => <String, Object?>{
  'v': 1,
  'units': 'm',
  'nodes': <Object?>[
    <String, Object?>{
      'id': 'floor',
      'type': 'box',
      'size': <double>[4, 0.1, 4],
      'position': <double>[0, -0.05, 0],
    },
    <String, Object?>{
      'id': 'box',
      'type': 'box',
      'size': <double>[1, 1, 1],
      'position': <double>[0, 0.5, 0],
    },
  ],
  'lights': <Object?>[
    <String, Object?>{
      'id': 'key',
      'type': 'directional',
      'intensity': 1.0,
      'color': '#ffffff',
      'position': <double>[4, 6, 4],
      'target': <double>[0, 0, 0],
    },
  ],
  'cameras': <Object?>[
    <String, Object?>{
      'id': 'hero',
      'position': <double>[3, 2, 3],
      'target': <double>[0, 1, 0],
      'fov': 45,
    },
  ],
};

Map<String, Object?> _validScreenplay() => <String, Object?>{
  'v': 1,
  'fps': 30,
  'format': <String, Object?>{'width': 320, 'height': 180},
  'seed': 0,
  'shots': <Object?>[
    <String, Object?>{
      'id': 's1',
      'duration': 5.0,
      'camera': <String, Object?>{'id': 'hero'},
    },
  ],
};

Video3dFrameEvidence _frame(int index, {String renderer = 'webgl_three_r160'}) =>
    Video3dFrameEvidence(frame: index, bytes: _png(), renderer: renderer);

void main() {
  late Directory root;
  late Video3dProjectStore store;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('video3d-renders-');
    store = Video3dProjectStore(root: root);
    await store.save('stage', scene: _validScene(), screenplay: _validScreenplay());
  });

  tearDown(() {
    if (root.existsSync()) {
      try {
        root.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  test('写 PNG + 清单：文件名按帧号补零，清单字节确定且无时间戳', () async {
    final Video3dRendersManifest manifest = await store.writeRenders(
      'stage',
      <Video3dFrameEvidence>[_frame(90), _frame(0)],
    );
    expect(manifest.count, 2);
    expect(manifest.renderer, 'webgl_three_r160');
    expect(manifest.totalBytes, 138);
    // 升序 + 补零文件名。
    expect(manifest.frames.map((e) => e.file).toList(), <String>[
      'frame-0000.png',
      'frame-0090.png',
    ]);

    final Directory renders = Directory('${root.path}/stage/artifacts/renders');
    expect(File('${renders.path}/frame-0000.png').existsSync(), isTrue);
    expect(File('${renders.path}/frame-0090.png').existsSync(), isTrue);
    expect(File('${renders.path}/frame-0000.png').readAsBytesSync(), _png());

    final String first =
        File('${renders.path}/renders.json').readAsStringSync();
    final Map<String, Object?> decoded =
        jsonDecode(first) as Map<String, Object?>;
    expect(decoded['schema'], video3dRendersSchema);
    expect(decoded['count'], 2);
    expect(decoded['total_bytes'], 138);
    // 清单里不许出现 ISO 时间戳（确定性字节，可复验、可 diff）。
    expect(
      RegExp(r'\d{4}-\d{2}-\d{2}T').hasMatch(first),
      isFalse,
      reason: 'renders.json 含时间戳，破坏字节确定性',
    );
    expect(first.endsWith('\n'), isTrue);

    // 同输入再写一次：清单字节完全相同（可复验、可 diff）。
    await store.writeRenders('stage', <Video3dFrameEvidence>[
      _frame(0),
      _frame(90),
    ]);
    expect(
      File('${renders.path}/renders.json').readAsStringSync(),
      first,
    );
  });

  test('只动 artifacts/：两份事实源逐字节不变', () async {
    final File scene = File('${root.path}/stage/scene3d.json');
    final File screenplay = File('${root.path}/stage/screenplay3d.json');
    final String sceneBefore = scene.readAsStringSync();
    final String screenplayBefore = screenplay.readAsStringSync();
    await store.writeRenders('stage', <Video3dFrameEvidence>[_frame(12)]);
    expect(scene.readAsStringSync(), sceneBefore);
    expect(screenplay.readAsStringSync(), screenplayBefore);
  });

  test('同一帧出现两次 → 拒绝（清单不能自相矛盾），且不写任何文件', () async {
    expect(
      () => store.writeRenders('stage', <Video3dFrameEvidence>[
        _frame(5),
        _frame(5),
      ]),
      throwsA(
        isA<Video3dEvidenceError>().having(
          (e) => e.code,
          'code',
          video3dEvidenceFormatCode,
        ),
      ),
    );
    expect(
      Directory('${root.path}/stage/artifacts/renders').existsSync(),
      isFalse,
    );
  });

  test('渲染器混用 → 拒绝（一批证据只能来自一档渲染器）', () async {
    await expectLater(
      store.writeRenders('stage', <Video3dFrameEvidence>[
        _frame(1),
        _frame(2, renderer: 'canvas2d_deterministic'),
      ]),
      throwsA(
        isA<Video3dEvidenceError>().having(
          (e) => e.code,
          'code',
          video3dEvidenceFormatCode,
        ),
      ),
    );
  });

  test('空列表 → 显性失败（不产出空清单）', () async {
    await expectLater(
      store.writeRenders('stage', const <Video3dFrameEvidence>[]),
      throwsA(
        isA<Video3dEvidenceError>().having(
          (e) => e.code,
          'code',
          video3dEvidenceEmptyCode,
        ),
      ),
    );
    expect(
      File('${root.path}/stage/artifacts/renders/renders.json').existsSync(),
      isFalse,
    );
  });

  test('项目不存在 → no_project', () async {
    await expectLater(
      store.writeRenders('nope', <Video3dFrameEvidence>[_frame(0)]),
      throwsA(
        isA<Video3dProjectFailure>().having(
          (e) => e.code,
          'code',
          'no_project',
        ),
      ),
    );
  });

  test('写完后不留临时文件（原子写收尾干净）', () async {
    await store.writeRenders('stage', <Video3dFrameEvidence>[
      _frame(0),
      _frame(7),
    ]);
    final List<String> leftovers = <String>[];
    for (final FileSystemEntity entity in Directory(
      '${root.path}/stage/artifacts/renders',
    ).listSync(recursive: true)) {
      if (entity.path.endsWith('.tmp')) leftovers.add(entity.path);
    }
    expect(leftovers, isEmpty);
  });
}
