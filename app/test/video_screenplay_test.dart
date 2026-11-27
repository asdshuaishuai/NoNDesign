// 常规视频剧本 v1（nan.screenplay/1）的契约硬门：
// schema / 扁平 shots / 整数帧 / 事件 allowlist / VFX cue allowlist / JSON Pointer。
import 'package:flutter_test/flutter_test.dart';

import 'package:nondesign/core/video/video_screenplay.dart';

Map<String, Object?> _base() => <String, Object?>{
  'schema': 'nan.screenplay/1',
  'width': 320,
  'height': 180,
  'shots': <Object?>[
    <String, Object?>{
      'id': 's1',
      'start': 0,
      'duration': 2.0,
      'events': <Object?>[],
    },
  ],
};

Map<String, Object?> _withEvents(List<Object?> events) => <String, Object?>{
  'schema': 'nan.screenplay/1',
  'width': 320,
  'height': 180,
  'shots': <Object?>[
    <String, Object?>{
      'id': 's1',
      'start': 0,
      'duration': 2.0,
      'events': events,
    },
  ],
};

void main() {
  group('schema 与镜头', () {
    test('合法剧本：verified + 整数帧时间表', () {
      final VideoScreenplayVerification result = verifyVideoScreenplay(_base());
      expect(result.verified, isTrue, reason: '${result.toJson()}');
      final VideoScreenplay screenplay = result.screenplay!;
      expect(screenplay.totalFrames, 60, reason: '2.0s @30fps = 60 帧');
      expect(screenplay.shots.single.frameCount, 60);
      expect(screenplay.width, 320);
      expect(screenplay.height, 180);
    });

    test('schema 不对：拒绝并给 /schema 指针', () {
      final Map<String, Object?> raw = _base()..['schema'] = 'nan.screenplay/2';
      final VideoScreenplayVerification result = verifyVideoScreenplay(raw);
      expect(result.verified, isFalse);
      expect(result.screenplay, isNull);
      expect(result.checks.single.pointer, '/schema');
      expect(result.checks.single.code, videoScreenplayInvalidSchema);
    });

    test('画布不在预设：拒绝', () {
      final Map<String, Object?> raw = _base()
        ..['width'] = 1000
        ..['height'] = 1000;
      final VideoScreenplayVerification result = verifyVideoScreenplay(raw);
      expect(result.verified, isFalse);
      expect(result.checks.first.pointer, '/width');
    });

    test('shots 为空：拒绝', () {
      final Map<String, Object?> raw = _base()..['shots'] = <Object?>[];
      final VideoScreenplayVerification result = verifyVideoScreenplay(raw);
      expect(result.verified, isFalse);
      expect(result.checks.first.pointer, '/shots');
    });

    test('镜头重叠：拒绝并指向 start', () {
      final Map<String, Object?> raw = <String, Object?>{
        'schema': 'nan.screenplay/1',
        'shots': <Object?>[
          <String, Object?>{
            'id': 's1',
            'start': 0,
            'duration': 2.0,
            'events': <Object?>[],
          },
          <String, Object?>{
            'id': 's2',
            'start': 1.0,
            'duration': 2.0,
            'events': <Object?>[],
          },
        ],
      };
      final VideoScreenplayVerification result = verifyVideoScreenplay(raw);
      expect(result.verified, isFalse);
      final VideoScreenplayIssue issue = result.checks.firstWhere(
        (VideoScreenplayIssue it) => it.code == videoScreenplayInvalidShot,
      );
      expect(issue.pointer, '/shots/1/start');
    });

    test('镜头 id 重复：拒绝', () {
      final Map<String, Object?> raw = <String, Object?>{
        'schema': 'nan.screenplay/1',
        'shots': <Object?>[
          <String, Object?>{
            'id': 's1',
            'start': 0,
            'duration': 1.0,
            'events': <Object?>[],
          },
          <String, Object?>{
            'id': 's1',
            'start': 1.0,
            'duration': 1.0,
            'events': <Object?>[],
          },
        ],
      };
      final VideoScreenplayVerification result = verifyVideoScreenplay(raw);
      expect(result.verified, isFalse);
      expect(result.checks.first.code, videoScreenplayDuplicateId);
    });

    test('duration 太短（不足 1 帧）：拒绝', () {
      final Map<String, Object?> raw = _base();
      (raw['shots'] as List<Object?>)[0] =
          <String, Object?>{
            'id': 's1',
            'start': 0,
            'duration': 0.001,
            'events': <Object?>[],
          };
      final VideoScreenplayVerification result = verifyVideoScreenplay(raw);
      expect(result.verified, isFalse);
    });
  });

  group('事件与 allowlist', () {
    test('合法 VFX 事件：编译成全局整数帧', () {
      final VideoScreenplayVerification result = verifyVideoScreenplay(
        _withEvents(<Object?>[
          <String, Object?>{
            'f': 15,
            'type': 'vfx',
            'cue': 'fire.campfire',
            'x': 4,
            'y': 2,
          },
        ]),
      );
      expect(result.verified, isTrue, reason: '${result.toJson()}');
      final VideoScreenplayEvent event = result.screenplay!.events.single;
      expect(event.frame, 15, reason: '镜头 start=0，相对帧 15 = 全局 15');
      expect(event.cue, 'fire.campfire');
      expect(event.layer, 'front', reason: 'layer 缺省 front');
      expect(event.seed, isNot(0), reason: 'seed 缺省由稳定 hash 派生');
    });

    test('未知 cue：拒绝并指向 /cue（不允许静默丢弃）', () {
      final VideoScreenplayVerification result = verifyVideoScreenplay(
        _withEvents(<Object?>[
          <String, Object?>{
            'f': 1,
            'type': 'vfx',
            'cue': 'fire.unknown-effect',
          },
        ]),
      );
      expect(result.verified, isFalse);
      expect(result.screenplay, isNull);
      expect(result.checks.first.code, videoScreenplayUnknownCue);
      expect(result.checks.first.pointer, '/shots/0/events/0/cue');
    });

    test('未知事件类型：拒绝', () {
      final VideoScreenplayVerification result = verifyVideoScreenplay(
        _withEvents(<Object?>[
          <String, Object?>{'f': 1, 'type': 'mystery'},
        ]),
      );
      expect(result.verified, isFalse);
      expect(result.checks.first.code, videoScreenplayUnknownEventType);
    });

    test('事件帧越界（超出镜头帧数）：拒绝', () {
      final VideoScreenplayVerification result = verifyVideoScreenplay(
        _withEvents(<Object?>[
          <String, Object?>{
            'f': 60,
            'type': 'vfx',
            'cue': 'fire.campfire',
          },
        ]),
      );
      expect(result.verified, isFalse);
      expect(
        result.checks.first.code,
        videoScreenplayInvalidEvent,
        reason: '镜头只有 60 帧（0..59），f=60 越界',
      );
    });

    test('layer 不在 allowlist：拒绝', () {
      final VideoScreenplayVerification result = verifyVideoScreenplay(
        _withEvents(<Object?>[
          <String, Object?>{
            'f': 1,
            'type': 'vfx',
            'cue': 'fire.campfire',
            'layer': 'middle',
          },
        ]),
      );
      expect(result.verified, isFalse);
      expect(result.checks.first.pointer, '/shots/0/events/0/layer');
    });

    test('scale ≤ 0：拒绝', () {
      final VideoScreenplayVerification result = verifyVideoScreenplay(
        _withEvents(<Object?>[
          <String, Object?>{
            'f': 1,
            'type': 'vfx',
            'cue': 'fire.campfire',
            'scale': 0,
          },
        ]),
      );
      expect(result.verified, isFalse);
    });

    test('seed 缺省由稳定 hash 派生：同输入两次同值', () {
      final Map<String, Object?> raw = _withEvents(<Object?>[
        <String, Object?>{'f': 3, 'type': 'vfx', 'cue': 'ice.ice-crystal'},
      ]);
      final VideoScreenplay a = verifyVideoScreenplay(raw).screenplay!;
      final VideoScreenplay b = verifyVideoScreenplay(raw).screenplay!;
      expect(a.events.single.seed, b.events.single.seed);
    });

    test('非 VFX 事件（sfx/caption/camera.shake）在 allowlist 内可用', () {
      final VideoScreenplayVerification result = verifyVideoScreenplay(
        _withEvents(<Object?>[
          <String, Object?>{'f': 1, 'type': 'sfx'},
          <String, Object?>{'f': 2, 'type': 'caption'},
          <String, Object?>{'f': 3, 'type': 'camera.shake'},
        ]),
      );
      expect(result.verified, isTrue, reason: '${result.toJson()}');
      expect(result.screenplay!.events.map((e) => e.type).toSet(), <String>{
        'sfx',
        'caption',
        'camera.shake',
      });
    });

    test('allowlist 与 pixelfx 入库特效一致（11 个，含火焰/冰霜/闪电/爆炸/风土）', () {
      expect(videoVfxCueAllowlist, hasLength(11));
      expect(videoVfxCueAllowlist, contains('fire.campfire'));
      expect(videoVfxCueAllowlist, contains('ice.frost-breath'));
      expect(videoVfxCueAllowlist, contains('lightning.lightning-strike'));
      expect(videoVfxCueAllowlist, contains('explosions.big-explosion'));
      expect(videoVfxCueAllowlist, contains('nature.earth-spike'));
      // 人物/on-body 特效绝不在 allowlist（裁决边界）。
      expect(videoVfxCueAllowlist, isNot(contains('ice.frost-nova')));
    });
  });

  test('未知字段保留（前向兼容）', () {
    final Map<String, Object?> raw = _base()..['future_field'] = <String, Object?>{'x': 1};
    final VideoScreenplayVerification result = verifyVideoScreenplay(raw);
    expect(result.verified, isTrue);
    expect(result.screenplay!.raw['future_field'], isNotNull);
  });
}
