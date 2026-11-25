// 音乐确定性补丁（music_patch）纯函数锚点（契约见 docs/music-contract.md §7）。
//
// 锚定：
//  * RFC6902 风格 add / remove / replace 在安全路径上的最小改动；
//  * 白名单之外的路径（版本字段/未知字段/相对层级/坏转义）与越界下标一律拒绝；
//  * 补丁值类型/范围显性校验，改后必须过 parseMusicScore 才返回（verified）；
//  * 失败抛 MusicPatchFailure(code, 人话)，入参永远不被修改（成功也不改）。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:nondesign/core/music/music_patch.dart';
import 'package:nondesign/core/music/music_score.dart';

/// 一份合法 score.json v1（4/4）：一个空小节（整小节休止）+ 一个全音符小节。
///
/// 故意带未知字段（top/track/measure/event 各一层）：补丁只改白名单字段，
/// 未知字段必须原样保留（契约 §1）。
Map<String, dynamic> _score({
  String? title = '晨光',
  int tempo = 120,
  double volume = 0.8,
  bool muted = false,
}) {
  final doc = <String, dynamic>{
    'schemaVersion': 1,
    'title': ?title,
    'tempo': tempo,
    'timeSig': <int>[4, 4],
    'keySig': 'C',
    'owner': <String, dynamic>{'agent': 'scripted'},
    'tracks': <dynamic>[
      <String, dynamic>{
        'id': 'melody',
        'name': '旋律',
        'instrument': 'piano',
        'volume': volume,
        'muted': muted,
        'clef': 'treble',
        'origin': 'unknown-track-field',
        'measures': <dynamic>[
          <String, dynamic>{'id': 'm0', 'memo': '空小节'},
          <String, dynamic>{
            'id': 'm1',
            'events': <dynamic>[
              <String, dynamic>{
                'id': 'e1',
                'type': 'note',
                'dur': <String, dynamic>{'num': 1, 'den': 1},
                'pitch': <String, dynamic>{
                  'step': 'C',
                  'alter': 0,
                  'octave': 4,
                },
                'label': 'unknown-event-field',
              },
            ],
          },
        ],
      },
    ],
  };
  return doc;
}

Map<String, dynamic> _op(String op, String path, [Object? value]) =>
    op == 'remove'
    ? <String, dynamic>{'op': op, 'path': path}
    : <String, dynamic>{'op': op, 'path': path, 'value': value};

MusicPatchFailure _catchFailure(Map<String, Object?> score, List<Object?> ops) {
  try {
    applyMusicPatch(score, ops);
  } on MusicPatchFailure catch (error) {
    return error;
  }
  throw StateError('expected MusicPatchFailure, got none');
}

void main() {
  group('add / replace 安全字段（最小改动 + 未知字段保留）', () {
    test('replace 标题/速度/音量/静音：全部落地且补丁后仍 verified', () {
      final doc = _score();
      final before = jsonEncode(doc);
      final result = applyMusicPatch(doc, <Object?>[
        _op('replace', '/title', '暮色'),
        _op('replace', '/tempo', 90),
        _op('replace', '/tracks/0/volume', 0.6),
        _op('replace', '/tracks/0/muted', true),
      ]);

      expect(result.applied, 4);
      expect(result.score.title, '暮色');
      expect(result.score.tempo, 90);
      expect(result.score.tracks.single.volume, closeTo(0.6, 1e-9));
      expect(result.score.tracks.single.muted, isTrue);
      expect(verifyMusicScore(result.raw).verified, isTrue);
      expect(verifyMusicScore(result.score.toJson()).verified, isTrue);
      expect(result.score.schemaVersion, 1);
      expect(result.score.measureCount, 2);

      // 未知字段原样保留（原文与解析后的模型都要保留）。
      final Map<String, Object?> raw = result.raw;
      expect(raw['owner'], <String, dynamic>{'agent': 'scripted'});
      final track = (raw['tracks'] as List).single as Map;
      expect(track['origin'], 'unknown-track-field');
      final measure = (track['measures'] as List).last as Map;
      expect(measure['id'], 'm1');
      final event = (measure['events'] as List).single as Map;
      expect(event['label'], 'unknown-event-field');
      expect(result.score.extra['owner'], <String, dynamic>{
        'agent': 'scripted',
      });
      expect(
        result.score.tracks.single.measures.last.events.single.extra['label'],
        'unknown-event-field',
      );

      // 绝不改入参：成功路径同样不共享引用。
      expect(jsonEncode(doc), before, reason: 'applyMusicPatch 不能修改入参');
      expect(identical(result.raw, doc), isFalse);
    });

    test('add 与 replace 对对象成员同语义；标题缺失时 add 可补齐', () {
      final doc = _score(title: null)..remove('title');
      final result = applyMusicPatch(doc, <Object?>[
        _op('add', '/title', '新标题'),
        _op('add', '/tracks/0/name', '主旋律'),
        _op('add', '/tracks/0/volume', 0.25),
      ]);
      expect(result.applied, 3);
      expect(result.score.title, '新标题');
      expect(result.score.tracks.single.name, '主旋律');
      expect(result.score.tracks.single.volume, closeTo(0.25, 1e-9));
      expect(verifyMusicScore(result.raw).verified, isTrue);
      expect(doc.containsKey('title'), isFalse, reason: '入参不能被改');
    });

    test('事件级 add：空小节追加整小节音符 → verified；再 remove 回到空小节', () {
      final doc = _score();
      final before = jsonEncode(doc);
      final add = applyMusicPatch(doc, <Object?>[
        _op('add', '/tracks/0/measures/0/events', <String, dynamic>{
          'id': 'e0',
          'type': 'note',
          'dur': <String, dynamic>{'num': 1, 'den': 1},
          'pitch': <String, dynamic>{'step': 'E', 'alter': 0, 'octave': 4},
        }),
      ]);
      expect(add.applied, 1);
      expect(add.score.tracks.single.measures.first.events, hasLength(1));
      expect(add.score.tracks.single.measures.first.events.single.step, 'E');
      expect(verifyMusicScore(add.raw).verified, isTrue);

      final remove = applyMusicPatch(add.raw, <Object?>[
        _op('remove', '/tracks/0/measures/0/events/0'),
      ]);
      expect(remove.applied, 1);
      expect(remove.score.tracks.single.measures.first.events, isEmpty);
      expect(verifyMusicScore(remove.raw).verified, isTrue);
      // 原始输入（第一份）仍没有被改。
      expect(jsonEncode(doc), before);
    });

    test('事件级 add 支持 - 追加与数字下标插入', () {
      final doc = _score();
      final appended = applyMusicPatch(doc, <Object?>[
        _op('add', '/tracks/0/measures/0/events/-', <String, dynamic>{
          'id': 'e0',
          'type': 'note',
          'dur': <String, dynamic>{'num': 1, 'den': 1},
          'pitch': <String, dynamic>{'step': 'G', 'alter': 0, 'octave': 4},
        }),
      ]);
      expect(appended.score.tracks.single.measures.first.events, hasLength(1));
      final inserted = applyMusicPatch(doc, <Object?>[
        _op('add', '/tracks/0/measures/0/events/0', <String, dynamic>{
          'id': 'e0',
          'type': 'rest',
          'dur': <String, dynamic>{'num': 1, 'den': 1},
        }),
      ]);
      expect(
        inserted.score.tracks.single.measures.first.events.single.isRest,
        isTrue,
      );
    });

    test('事件级 replace：同音长换音高仍 verified；值深拷贝不共享引用', () {
      final doc = _score();
      final replacement = <String, dynamic>{
        'id': 'e1',
        'type': 'note',
        'dur': <String, dynamic>{'num': 1, 'den': 1},
        'pitch': <String, dynamic>{'step': 'D', 'alter': 0, 'octave': 4},
      };
      final result = applyMusicPatch(doc, <Object?>[
        _op('replace', '/tracks/0/measures/1/events/0', replacement),
      ]);
      expect(result.applied, 1);
      expect(result.score.tracks.single.measures.last.events.single.step, 'D');
      expect(verifyMusicScore(result.raw).verified, isTrue);
      // 补丁值进文档前深拷贝：改原值不影响结果。
      replacement['id'] = 'mutated';
      final rawEvent =
          ((result.raw['tracks'] as List).single
                  as Map)['measures'][1]['events'][0]
              as Map;
      expect(rawEvent['id'], 'e1');
    });

    test('remove 事件让非空小节变空（整小节休止）仍 verified', () {
      final doc = _score();
      final result = applyMusicPatch(doc, <Object?>[
        _op('remove', '/tracks/0/measures/1/events/0'),
      ]);
      expect(result.score.tracks.single.measures.last.events, isEmpty);
      expect(result.score.tracks.single.measures.first.events, isEmpty);
      expect(verifyMusicScore(result.raw).verified, isTrue);
    });
  });

  group('路径白名单 / 危险路径显性拒绝', () {
    final cases = <({String op, String path, Object? value})>[
      (op: 'replace', path: '/schemaVersion', value: 2),
      (op: 'replace', path: '/owner', value: 'x'),
      (op: 'replace', path: '/unknownField', value: true),
      (op: 'replace', path: '/tracks', value: <dynamic>[]),
      (op: 'replace', path: '/tracks/0/tempo', value: 120),
      (op: 'replace', path: '/tracks/0/measures/0/foo', value: 1),
      (
        op: 'replace',
        path: '/tracks/0/measures/0/events/0/pitch',
        value: <dynamic>{},
      ),
      (op: 'replace', path: 'title', value: 'x'),
      (op: 'replace', path: '/', value: 1),
      (op: 'replace', path: '/tracks//volume', value: 0.5),
      (op: 'replace', path: '/tracks/0/../volume', value: 0.5),
      (op: 'replace', path: '/tracks/0/volume~2', value: 0.5),
      (op: 'replace', path: '/tracks/-1/volume', value: 0.5),
      (op: 'replace', path: '/tracks/01/volume', value: 0.5),
      (op: 'remove', path: '/tracks/0/measures/0/events/x', value: null),
      (op: 'remove', path: '/tracks/0/measures/0/measures', value: null),
    ];
    for (final item in cases) {
      test('${item.op} ${item.path} 被拒（invalid_path）', () {
        final doc = _score();
        final before = jsonEncode(doc);
        final failure = _catchFailure(doc, <Object?>[
          _op(item.op, item.path, item.value),
        ]);
        expect(failure.code, 'invalid_path', reason: item.path);
        expect(failure.message, isNotEmpty);
        expect(jsonEncode(doc), before);
      });
    }

    test('schemaVersion 的拒绝人话明确说版本只读', () {
      final failure = _catchFailure(_score(), <Object?>[
        _op('replace', '/schemaVersion', 2),
      ]);
      expect(failure.message, contains('版本'));
    });
  });

  group('越界下标（out_of_range）', () {
    test('轨道 / 小节 / 事件下标越界', () {
      final doc = _score();
      final cases = <List<Object?>>[
        <Object?>[_op('replace', '/tracks/1/volume', 0.5)],
        <Object?>[_op('replace', '/tracks/0/measures/9/events', <dynamic>[])],
        <Object?>[_op('remove', '/tracks/0/measures/1/events/2')],
        <Object?>[
          _op('add', '/tracks/0/measures/1/events/2', <String, dynamic>{
            'id': 'x',
          }),
        ],
        <Object?>[_op('remove', '/tracks/0/measures/0/events/0')],
        <Object?>[
          _op('replace', '/tracks/0/measures/0/events/0', <String, dynamic>{}),
        ],
      ];
      for (final ops in cases) {
        final failure = _catchFailure(doc, ops);
        expect(failure.code, 'out_of_range', reason: ops.toString());
        expect(failure.message, contains('越界'));
      }
      expect(jsonEncode(doc), jsonEncode(_score()));
    });
  });

  group('非法补丁值（invalid_value）', () {
    final cases = <({String path, Object? value})>[
      (path: '/tempo', value: 'fast'),
      (path: '/tempo', value: 120.5),
      (path: '/tempo', value: double.nan),
      (path: '/tempo', value: 1e30),
      (path: '/tracks/0/volume', value: '0.5'),
      (path: '/tracks/0/volume', value: 1.5),
      (path: '/tracks/0/volume', value: double.nan),
      (path: '/tracks/0/muted', value: 'true'),
      (path: '/title', value: ''),
      (path: '/title', value: 42),
      (path: '/tracks/0/name', value: '   '),
      (path: '/tracks/0/instrument', value: 'guitar'),
      (path: '/tracks/0/measures/0/events', value: 'note'),
      (path: '/tracks/0/measures/0/events', value: null),
    ];
    for (final item in cases) {
      test('${item.path} ← ${item.value} 被拒（invalid_value）', () {
        final doc = _score();
        final failure = _catchFailure(doc, <Object?>[
          _op('add', item.path, item.value),
        ]);
        expect(failure.code, 'invalid_value', reason: item.path);
        expect(failure.message, isNotEmpty);
      });
    }

    test('音色白名单与音量范围的人话可执行', () {
      final instrument = _catchFailure(_score(), <Object?>[
        _op('replace', '/tracks/0/instrument', 'guitar'),
      ]);
      expect(instrument.message, contains('音色'));
      final volume = _catchFailure(_score(), <Object?>[
        _op('replace', '/tracks/0/volume', 2),
      ]);
      expect(volume.message, contains('音量'));
    });
  });

  group('非法操作 / 入参形状（invalid_operation）', () {
    test('空补丁 / 动作未知 / 未知字段 / remove 带 value', () {
      final doc = _score();
      expect(_catchFailure(doc, const <Object?>[]).code, 'invalid_operation');

      final unknownAction = _catchFailure(doc, <Object?>[
        _op('move', '/title', 'x'),
      ]);
      expect(unknownAction.code, 'invalid_operation');
      expect(unknownAction.message, contains('add'));

      final extraField = _catchFailure(doc, <Object?>[
        <String, dynamic>{
          'op': 'add',
          'path': '/title',
          'value': 'x',
          'from': '/y',
        },
      ]);
      expect(extraField.code, 'invalid_operation');

      final removeWithValue = _catchFailure(doc, <Object?>[
        <String, dynamic>{'op': 'remove', 'path': '/title', 'value': 'x'},
      ]);
      expect(removeWithValue.code, 'invalid_operation');
      expect(removeWithValue.message, contains('value'));
    });

    test('remove 不能删安全标量字段（只允许删事件）', () {
      for (final path in <String>[
        '/title',
        '/tempo',
        '/tracks/0/volume',
        '/tracks/0/muted',
        '/tracks/0/name',
      ]) {
        final failure = _catchFailure(_score(), <Object?>[_op('remove', path)]);
        expect(failure.code, 'invalid_operation', reason: path);
        expect(failure.message, contains('不能删除'), reason: path);
      }
    });

    test('补丁缺 path / 缺 value / 不是对象', () {
      final doc = _score();
      expect(
        _catchFailure(doc, <Object?>[
          <String, dynamic>{'op': 'replace'},
        ]).code,
        'invalid_path',
      );
      expect(
        _catchFailure(doc, <Object?>[
          <String, dynamic>{'op': 'replace', 'path': ''},
        ]).code,
        'invalid_path',
      );
      expect(
        _catchFailure(doc, <Object?>[
          <String, dynamic>{'op': 'replace', 'path': '/title'},
        ]).code,
        'invalid_value',
      );
      expect(_catchFailure(doc, <Object?>['not-an-op']).code, 'invalid_value');
    });

    test('一次超过补丁条数上限 → too_many_ops（不开始应用）', () {
      final ops = List<Object?>.generate(
        musicMaxPatchOps + 1,
        (index) => _op('replace', '/title', '标题$index'),
      );
      final failure = _catchFailure(_score(), ops);
      expect(failure.code, 'too_many_ops');
      expect(failure.message, contains('$musicMaxPatchOps'));
    });
  });

  group('改后必须过 parseMusicScore 才返回', () {
    test('tempo 越界 → score_invalid，detail 带指针，入参不变', () {
      final doc = _score();
      final before = jsonEncode(doc);
      final failure = _catchFailure(doc, <Object?>[
        _op('replace', '/tempo', 500),
      ]);
      expect(failure.code, 'score_invalid');
      expect(failure.message, contains('没有通过校验'));
      expect(failure.detail, contains('/tempo'));
      expect(failure.detail, contains('tempo'));
      expect(jsonEncode(doc), before);
    });

    test('事件改动破坏小节时值 → score_invalid，detail 带小节指针', () {
      final doc = _score();
      final failure = _catchFailure(doc, <Object?>[
        _op('replace', '/tracks/0/measures/1/events/0', <String, dynamic>{
          'id': 'e1',
          'type': 'note',
          'dur': <String, dynamic>{'num': 1, 'den': 2},
          'pitch': <String, dynamic>{'step': 'C', 'alter': 0, 'octave': 4},
        }),
      ]);
      expect(failure.code, 'score_invalid');
      expect(failure.detail, contains('/tracks/0/measures/1/events'));
    });

    test('事件缺 id/dur → score_invalid，detail 带事件指针', () {
      final failure = _catchFailure(_score(), <Object?>[
        _op('add', '/tracks/0/measures/1/events', <String, dynamic>{
          'type': 'note',
        }),
      ]);
      expect(failure.code, 'score_invalid');
      expect(failure.detail, contains('/tracks/0/measures/1/events/1'));
    });

    test('原谱本身不合法时，合法补丁也会被硬门拦住（不静默返回）', () {
      final broken = _score(tempo: 500);
      final failure = _catchFailure(broken, <Object?>[
        _op('replace', '/title', '暮色'),
      ]);
      expect(failure.code, 'score_invalid');
      expect(failure.detail, contains('/tempo'));
    });

    test('成功结果的 raw 与模型都通过校验（verified 不是口头声明）', () {
      final result = applyMusicPatch(_score(), <Object?>[
        _op('replace', '/title', '暮色'),
      ]);
      expect(verifyMusicScore(result.raw).verified, isTrue);
      expect(verifyMusicScore(result.score.toJson()).verified, isTrue);
      expect(result.score.title, '暮色');
    });

    test('失败结果绝不返回半成品（异常路径没有可观察的部分结果）', () {
      final doc = _score();
      MusicPatchResult? partial;
      try {
        partial = applyMusicPatch(doc, <Object?>[
          _op('replace', '/title', '暮色'),
          _op('replace', '/tempo', 500),
        ]);
      } on MusicPatchFailure {
        partial = null;
      }
      expect(partial, isNull);
      expect(jsonEncode(doc), jsonEncode(_score()));
    });
  });

  group('失败码人话表', () {
    test('每个 MusicPatchFailure 细分码都有人话且不是裸代号', () {
      for (final code in <String>[
        'invalid_path',
        'invalid_operation',
        'out_of_range',
        'invalid_value',
        'score_invalid',
        'too_many_ops',
      ]) {
        final message = musicPatchFailureMessage(code);
        expect(message, isNotEmpty, reason: code);
        const bareCode = r'^[a-z0-9]+(_[a-z0-9]+)+$';
        expect(
          RegExp(bareCode).hasMatch(message),
          isFalse,
          reason: '人话不能是裸错误码：$code',
        );
      }
      expect(musicPatchFailureMessage('unknown-code'), '乐谱补丁没有完成，请稍后再试');
    });

    test('MusicPatchFailure.toString 带 code 与 detail（技术详情用）', () {
      const failure = MusicPatchFailure(
        'invalid_path',
        '补丁路径不可用',
        detail: '/schemaVersion: readonly',
      );
      expect(failure.toString(), contains('invalid_path'));
      expect(failure.toString(), contains('/schemaVersion: readonly'));
    });
  });
}
