import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nondesign/core/music/music_project.dart';
import 'package:nondesign/core/music/music_score.dart';

MusicScore _score({String title = '练习曲'}) => MusicScore(
  title: title,
  tempo: 96,
  timeSig: const <int>[4, 4],
  keySig: 'C',
  tracks: <MusicTrack>[
    MusicTrack(
      id: 'melody',
      name: '主旋律',
      instrument: 'piano',
      measures: <MusicMeasure>[
        MusicMeasure(
          id: 'm1',
          events: <MusicEvent>[
            MusicEvent(
              id: 'n1',
              isRest: false,
              durNum: 1,
              durDen: 1,
              step: 'C',
              octave: 5,
            ),
          ],
        ),
      ],
    ),
  ],
);

void main() {
  late Directory temp;
  late MusicProjectStore store;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('nondesign-music-');
    store = MusicProjectStore(root: temp);
  });

  tearDown(() async {
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  test('save → list/read：score.json 落盘，元数据/verified 可读', () async {
    final validation = await store.save('study', _score());
    expect(validation.verified, isTrue);
    expect(File('${temp.path}/study/score.json').existsSync(), isTrue);

    final entries = await store.list();
    expect(entries.single.name, 'study');
    expect(entries.single.title, '练习曲');
    expect(entries.single.tracks, 1);
    expect(entries.single.verified, isTrue);

    final snapshot = await store.read('study');
    expect(snapshot.score.title, '练习曲');
    expect(snapshot.validation.verified, isTrue);
    expect(snapshot.playPlan, isNotNull);
    expect(
      snapshot.playPlan!.events.single.durationTicks,
      3840 * 4,
      reason: '一个全音符 = 4 个四分 tick',
    );
  });

  test('坏名/缺项目/坏文件：显性失败，不静默', () async {
    await expectLater(
      () => store.read('../escape'),
      throwsA(
        isA<MusicProjectFailure>().having(
          (f) => f.code,
          'code',
          'invalid_name',
        ),
      ),
    );
    await expectLater(
      () => store.read('ghost'),
      throwsA(
        isA<MusicProjectFailure>().having((f) => f.code, 'code', 'no_project'),
      ),
    );
    Directory('${temp.path}/broken').createSync(recursive: true);
    File('${temp.path}/broken/score.json').writeAsStringSync('{not json');
    await expectLater(
      () => store.read('broken'),
      throwsA(
        isA<MusicProjectFailure>().having(
          (f) => f.code,
          'code',
          'score_invalid',
        ),
      ),
    );
  });

  test('delete 移除项目；缺失项目删除失败', () async {
    await store.save('study', _score());
    await store.delete('study');
    await expectLater(
      () => store.delete('study'),
      throwsA(
        isA<MusicProjectFailure>().having((f) => f.code, 'code', 'no_project'),
      ),
    );
  });
}
