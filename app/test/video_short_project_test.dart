// 引擎短片项目存储：先校验后落盘 / 拒绝同名覆盖 / 坏项目隔离 / 原子写。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:nondesign/core/video/video_screenplay.dart';
import 'package:nondesign/core/video/video_short_evidence.dart';
import 'package:nondesign/core/video/video_short_project.dart';
import 'package:nondesign/core/video/video_style_pack.dart';

Map<String, Object?> _screenplay({String cue = 'fire.campfire'}) =>
    <String, Object?>{
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
              'cue': cue,
              'x': 4,
              'y': 2,
            },
            <String, Object?>{'f': 20, 'type': 'caption'},
          ],
        },
      ],
    };

void main() {
  late Directory root;
  late VideoShortProjectStore store;

  setUp(() {
    root = Directory.systemTemp.createTempSync('video-short-project-');
    store = VideoShortProjectStore(root: root);
  });

  tearDown(() {
    if (root.existsSync()) {
      try {
        root.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  test('合法剧本：先校验后落盘，单文件事实源', () async {
    final VideoScreenplayVerification result = await store.save(
      'short',
      _screenplay(),
    );
    expect(result.verified, isTrue, reason: '${result.toJson()}');
    final File file = File('${root.path}/short/${VideoShortProjectStore.screenplayFile}');
    expect(file.existsSync(), isTrue);
    // 稳定 JSON：两空格缩进 + 末尾换行。
    final String text = file.readAsStringSync();
    expect(text, startsWith('{\n  "schema"'));
    expect(text.endsWith('\n'), isTrue);
    // 不留临时文件。
    final List<String> leftovers = Directory('${root.path}/short')
        .listSync()
        .whereType<File>()
        .map((File f) => f.path)
        .where((String p) => p.endsWith('.tmp'))
        .toList();
    expect(leftovers, isEmpty);
  });

  test('未通过校验：不落盘（目录都不出现）', () async {
    final Map<String, Object?> bad = _screenplay(cue: 'fire.unknown');
    final VideoScreenplayVerification result = await store.save('bad', bad);
    expect(result.verified, isFalse);
    expect(
      result.checks
          .where(
            (VideoScreenplayIssue issue) =>
                issue.code == videoScreenplayUnknownCue,
          )
          .length,
      greaterThan(0),
    );
    expect(Directory('${root.path}/bad').existsSync(), isFalse);
  });

  test('同名已存在：默认拒绝覆盖，磁盘逐字节不变', () async {
    await store.save('short', _screenplay());
    final File file = File('${root.path}/short/${VideoShortProjectStore.screenplayFile}');
    final String before = file.readAsStringSync();
    await expectLater(
      store.save('short', _screenplay()),
      throwsA(
        isA<VideoShortProjectFailure>().having(
          (VideoShortProjectFailure e) => e.code,
          'code',
          'exists',
        ),
      ),
    );
    expect(file.readAsStringSync(), before);
  });

  test('overwrite=true 才替换', () async {
    await store.save('short', _screenplay());
    final VideoScreenplayVerification result = await store.save(
      'short',
      _screenplay(),
      overwrite: true,
    );
    expect(result.verified, isTrue);
  });

  test('非法项目名：稳定失败码，不写盘', () async {
    await expectLater(
      store.save('../escape', _screenplay()),
      throwsA(
        isA<VideoShortProjectFailure>().having(
          (VideoShortProjectFailure e) => e.code,
          'code',
          'invalid_name',
        ),
      ),
    );
  });

  test('读取：回原始剧本 + 校验 + 整数帧', () async {
    await store.save('short', _screenplay());
    final VideoShortProjectSnapshot snapshot = await store.read('short');
    expect(snapshot.verification.verified, isTrue);
    expect(snapshot.screenplay!.totalFrames, 60);
    expect(snapshot.screenplay!.events, hasLength(2));
    expect(
      snapshot.screenplay!.events.first.cue,
      'fire.campfire',
    );
  });

  test('读取不存在：no_project', () async {
    await expectLater(
      store.read('nope'),
      throwsA(
        isA<VideoShortProjectFailure>().having(
          (VideoShortProjectFailure e) => e.code,
          'code',
          'no_project',
        ),
      ),
    );
  });

  test('坏 JSON：读抛 corrupt，列表标 corrupt 而不是整表失败', () async {
    Directory('${root.path}/broken').createSync(recursive: true);
    File(
      '${root.path}/broken/${VideoShortProjectStore.screenplayFile}',
    ).writeAsStringSync('{ not json');
    await store.save('good', _screenplay());
    final List<VideoShortProjectEntry> entries = await store.list();
    expect(entries, hasLength(2));
    final VideoShortProjectEntry broken = entries.firstWhere(
      (VideoShortProjectEntry e) => e.name == 'broken',
    );
    expect(broken.corrupt, isTrue);
    final VideoShortProjectEntry good = entries.firstWhere(
      (VideoShortProjectEntry e) => e.name == 'good',
    );
    expect(good.verified, isTrue);
    expect(good.frames, 60);
    expect(good.shots, 1);
    expect(good.width, 320);
    await expectLater(
      store.read('broken'),
      throwsA(
        isA<VideoShortProjectFailure>().having(
          (VideoShortProjectFailure e) => e.code,
          'code',
          'corrupt',
        ),
      ),
    );
  });

  group('风格包读写（style.json）', () {
    Map<String, Object?> style(String id) => <String, Object?>{
      'schema': 'nan.style_pack/1',
      'id': id,
      'palette': <String, Object?>{
        'background': '#101010',
        'band': '#202020',
        'accent': '#ff8800',
        'text': '#ffffff',
      },
    };

    test('没存过：readStyle 返回 null（用内置默认，不算错）', () async {
      await store.save('short', _screenplay());
      expect(await store.readStyle('short'), isNull);
    });

    test('存→读回环；列表带 styleId；只写 style.json', () async {
      await store.save('short', _screenplay());
      final VideoStylePackVerification saved = await store.saveStyle(
        'short',
        style('warm'),
      );
      expect(saved.verified, isTrue, reason: '${saved.toJson()}');
      final VideoStylePack? read = await store.readStyle('short');
      expect(read?.id, 'warm');
      final List<VideoShortProjectEntry> entries = await store.list();
      expect(entries.single.styleId, 'warm');
      // 事实源不动。
      final File screenplay = File(
        '${root.path}/short/${VideoShortProjectStore.screenplayFile}',
      );
      expect(screenplay.readAsStringSync(), contains('"schema": "nan.screenplay/1"'));
    });

    test('非法风格包：不落盘', () async {
      await store.save('short', _screenplay());
      final Map<String, Object?> bad = style('bad');
      (bad['palette'] as Map<String, Object?>)['accent'] = 'orange';
      final VideoStylePackVerification saved = await store.saveStyle(
        'short',
        bad,
      );
      expect(saved.verified, isFalse);
      expect(
        File(
          '${root.path}/short/${VideoShortProjectStore.styleFile}',
        ).existsSync(),
        isFalse,
      );
    });
  });

  group('帧证据落盘', () {
    const String pngBase64 =
        'iVBORw0KGgpJSERSAAAADQAAAAEAAAABCAIAAACQd1PeSURBVAAAAAx4nGNgYGAAAAAEAAH2FzhV'
        'SUVORAAAAACuQmCC';

    List<VideoShortFrameEvidence> evidenceAt(List<int> frames) => <VideoShortFrameEvidence>[
      for (final int frame in frames)
        VideoShortFrameEvidence(
          frame: frame,
          bytes: base64Decode(pngBase64),
          renderer: 'phaser4_canvas',
          vfx: 'pixelfx_pixels',
        ),
    ];

    test('PNG + 确定性清单；事实源逐字节不变；无临时残留', () async {
      await store.save('short', _screenplay());
      final File screenplay = File(
        '${root.path}/short/${VideoShortProjectStore.screenplayFile}',
      );
      final String before = screenplay.readAsStringSync();

      final VideoShortRendersManifest manifest = await store.writeRenders(
        'short',
        evidenceAt(<int>[20, 0]),
      );
      expect(manifest.count, 2);
      expect(manifest.renderer, 'phaser4_canvas');
      expect(manifest.vfx, 'pixelfx_pixels');
      expect(manifest.totalBytes, 138);
      // 升序 + 补零文件名。
      expect(manifest.frames.map((e) => e.file).toList(), <String>[
        'frame-0000.png',
        'frame-0020.png',
      ]);
      final File png = File(
        '${root.path}/short/artifacts/renders/frame-0020.png',
      );
      expect(png.readAsBytesSync(), base64Decode(pngBase64));
      final String manifestText = File(
        '${root.path}/short/artifacts/renders/renders.json',
      ).readAsStringSync();
      expect(manifestText, contains('"schema": "nan.video_short.renders/1"'));
      expect(manifestText, contains('"count": 2'));
      // 不写时间戳（确定性字节）。
      expect(RegExp(r'\d{4}-\d{2}-\d{2}T').hasMatch(manifestText), isFalse);
      // 事实源不动。
      expect(screenplay.readAsStringSync(), before);
      // 无临时残留。
      final List<String> leftovers = Directory('${root.path}/short')
          .listSync(recursive: true)
          .whereType<File>()
          .map((File f) => f.path)
          .where((String path) => path.endsWith('.tmp'))
          .toList();
      expect(leftovers, isEmpty);
    });

    test('同帧重复 / 渲染面混用：拒绝且不写文件', () async {
      await store.save('short', _screenplay());
      await expectLater(
        store.writeRenders('short', evidenceAt(<int>[1, 1])),
        throwsA(isA<VideoShortEvidenceError>()),
      );
      await expectLater(
        store.writeRenders('short', <VideoShortFrameEvidence>[
          evidenceAt(<int>[1]).first,
          VideoShortFrameEvidence(
            frame: 2,
            bytes: base64Decode(pngBase64),
            renderer: 'phaser4_canvas',
            vfx: 'placeholder_markers',
          ),
        ]),
        throwsA(isA<VideoShortEvidenceError>()),
      );
      expect(
        Directory('${root.path}/short/artifacts').existsSync(),
        isFalse,
        reason: '校验失败不应留下 artifacts 目录',
      );
    });

    test('项目不存在：no_project', () async {
      await expectLater(
        store.writeRenders('nope', evidenceAt(<int>[0])),
        throwsA(
          isA<VideoShortProjectFailure>().having(
            (VideoShortProjectFailure e) => e.code,
            'code',
            'no_project',
          ),
        ),
      );
    });
  });

  test('删除：递归删掉；不存在 = no_project', () async {
    await store.save('short', _screenplay());
    await store.delete('short');
    expect(Directory('${root.path}/short').existsSync(), isFalse);
    await expectLater(store.delete('short'), throwsA(isA<VideoShortProjectFailure>()));
  });
}
