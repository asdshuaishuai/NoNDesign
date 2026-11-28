// 引擎短片项目存储：先校验后落盘 / 拒绝同名覆盖 / 坏项目隔离 / 原子写。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:nondesign/core/video/video_screenplay.dart';
import 'package:nondesign/core/video/video_short_project.dart';

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

  test('删除：递归删掉；不存在 = no_project', () async {
    await store.save('short', _screenplay());
    await store.delete('short');
    expect(Directory('${root.path}/short').existsSync(), isFalse);
    await expectLater(store.delete('short'), throwsA(isA<VideoShortProjectFailure>()));
  });
}
