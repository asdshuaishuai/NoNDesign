import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nondesign/core/music/music_compile.dart';
import 'package:nondesign/core/music/music_player.dart';
import 'package:nondesign/core/music/music_score.dart';

// ---------------------------------------------------------------------------
// Fixtures：构造器直接造模型（校验器语义不在本测试范围）。
// ---------------------------------------------------------------------------

MusicEvent _note(
  String id, {
  String step = 'C',
  int octave = 5,
  int num = 1,
  int den = 4,
}) => MusicEvent(
  id: id,
  isRest: false,
  durNum: num,
  durDen: den,
  step: step,
  octave: octave,
);

MusicEvent _drum(String id, String drum) => MusicEvent(
  id: id,
  isRest: false,
  durNum: 1,
  durDen: 4,
  extra: <String, Object?>{'drum': drum},
);

MusicTrack _track(
  String id,
  String instrument,
  List<MusicEvent> events, {
  String? name,
  double volume = 1.0,
  bool muted = false,
}) => MusicTrack(
  id: id,
  name: name ?? id,
  instrument: instrument,
  volume: volume,
  muted: muted,
  measures: <MusicMeasure>[MusicMeasure(id: 'm1', events: events)],
);

/// 可被 `parseMusicScore` 完整接受的 4/4 小谱（用于往返确定性）。
MusicScore _pianoScore({String title = '练习曲'}) => MusicScore(
  title: title,
  tempo: 96,
  timeSig: const <int>[4, 4],
  keySig: 'C',
  tracks: <MusicTrack>[
    _track('melody', 'piano', <MusicEvent>[
      _note('n1', step: 'C'),
      _note('n2', step: 'D'),
      _note('n3', step: 'E'),
      _note('n4', step: 'G'),
    ], name: '主旋律'),
  ],
  extra: const <String, Object?>{'dedication': 'for tests'},
);

/// 六音色 + 鼓组实例数据：只用于检查内嵌 plan 字面量与页面桥面。
MusicScore _mixedScore() => MusicScore(
  title: '混合练习',
  tempo: 120,
  timeSig: const <int>[4, 4],
  keySig: 'C',
  tracks: <MusicTrack>[
    _track('keys', 'piano', <MusicEvent>[
      _note('k1', step: 'C'),
      _note('k2', step: 'E', num: 1, den: 2),
    ], name: '钢琴'),
    _track('drums', 'drums', <MusicEvent>[
      _drum('d1', 'kick'),
      _drum('d2', 'snare'),
      _drum('d3', 'hihat'),
      _drum('d4', 'openhat'),
      _drum('d5', 'crash'),
      _drum('d6', 'ride'),
      _drum('d7', 'tom'),
    ], name: '鼓组'),
  ],
);

/// 从内联脚本里取出 `var NAME = <json>;` 的单行 JSON 字面量原文。
String _jsonLiteral(String html, String name) {
  final String marker = 'var $name = ';
  final int start = html.indexOf(marker);
  expect(start, isNot(-1), reason: '页面缺少 $name 字面量');
  final int begin = start + marker.length;
  final int end = html.indexOf(';\n', begin);
  expect(end, greaterThan(begin), reason: '$name 字面量没有结束分号');
  final String raw = html.substring(begin, end);
  expect(raw, isNot(contains('\n')), reason: '$name 应内联成单行 JSON');
  return raw;
}

String _html(MusicScore score) =>
    assembleMusicPlayer(score, compileMusicScore(score));

void main() {
  group('CSP 与自包含', () {
    test('CSP 固定为四指令，且先于第一个脚本', () {
      final String html = _html(_pianoScore());
      expect(
        musicPlayerCsp,
        "default-src 'none'; script-src 'unsafe-inline'; "
        "connect-src 'none'; frame-ancestors 'none'",
      );
      expect(
        html,
        contains(
          '<meta http-equiv="Content-Security-Policy" '
          'content="$musicPlayerCsp">',
        ),
      );
      // 策略必须早于第一个脚本生效（离线页只能靠 meta，没有响应头）。
      expect(
        html.indexOf('Content-Security-Policy'),
        lessThan(html.indexOf('<script')),
      );
      expect(
        '<meta http-equiv="Content-Security-Policy"'.allMatches(html).length,
        1,
      );
      expect(html, isNot(contains('unsafe-eval')));
      expect(html, isNot(contains('worker-src')));
      expect(html, isNot(contains('style-src')));
      expect(html, isNot(contains('img-src')));
      expect(html, isNot(contains('font-src')));
      expect(html, isNot(contains('media-src')));
    });

    test('零外联：无 http(s) 地址、无外链脚本、无网络 API、无采样文件', () {
      final String html = _html(_mixedScore());
      expect(RegExp(r'https?://').hasMatch(html), isFalse);
      expect(
        RegExp(r'<script[^>]*\bsrc\s*=', caseSensitive: false).hasMatch(html),
        isFalse,
      );
      expect(RegExp(r'<link\b', caseSensitive: false).hasMatch(html), isFalse);
      expect(RegExp(r'@import\b').hasMatch(html), isFalse);
      expect(RegExp(r'\bcrossorigin\b').hasMatch(html), isFalse);
      for (final String forbidden in <String>[
        'fetch(',
        'XMLHttpRequest',
        'WebSocket',
        'sendBeacon',
        'importScripts',
        'new Worker',
        'localStorage',
        'indexedDB',
        'new Function',
        'eval(',
        'Tone',
        'tonejs',
        'Sampler',
        '.mp3',
        '.wav',
        '.ogg',
        '.m4a',
        '.flac',
        'data:audio',
      ]) {
        expect(html, isNot(contains(forbidden)), reason: '不应出现 $forbidden');
      }
    });

    test('内联脚本只有一段；页面不依赖任何本地文件', () {
      final String html = _html(_pianoScore());
      expect(html.startsWith('<!doctype html>'), isTrue);
      expect(html, contains('<meta charset="utf-8">'));
      expect('<script'.allMatches(html).length, 1);
      expect('</script>'.allMatches(html).length, 1);
      expect(html, isNot(contains('<base')));
      // 自包含页的主体必须真有调度器与合成器代码，而不是只塞了 JSON。
      expect(html.length, greaterThan(20000));
    });
  });

  group('确定性', () {
    test('同输入两次组装字节相同（含 JSON 重解析后重建）', () {
      final MusicScore score = _pianoScore();
      final MusicPlayPlan plan = compileMusicScore(score);
      final String first = assembleMusicPlayer(score, plan);
      final String second = assembleMusicPlayer(score, plan);
      expect(first, second);
      expect(first.length, second.length);

      final MusicScore? reparsed = parseMusicScore(score.toJson()).score;
      expect(reparsed, isNotNull, reason: 'fixture 必须能被契约解析器接受');
      expect(reparsed!.toJson(), score.toJson());
      expect(
        assembleMusicPlayer(reparsed, compileMusicScore(reparsed)),
        first,
        reason: '重建后的同一事实源必须产出同一字节页面',
      );
    });

    test('内嵌 score / playplan JSON 字面量可还原原文', () {
      final MusicScore score = _mixedScore();
      final MusicPlayPlan plan = compileMusicScore(score);
      final String html = assembleMusicPlayer(score, plan);
      final Object? rawScore = jsonDecode(_jsonLiteral(html, 'SCORE'));
      final Object? rawPlan = jsonDecode(_jsonLiteral(html, 'PLAN'));
      expect(rawScore, score.toJson());
      expect(rawPlan, jsonDecode(plan.toJsonString()));

      final Map<String, Object?> planMap = Map<String, Object?>.from(
        rawPlan! as Map,
      );
      expect(planMap['schema'], 'nan.music.playplan/1');
      expect(planMap['ppq'], 3840);
      final List<Object?> events = (planMap['events']! as List<Object?>);
      final List<Map<String, Object?>> eventMaps = events
          .map((Object? event) => Map<String, Object?>.from(event! as Map))
          .toList(growable: false);
      expect(
        eventMaps.any((event) => event['drum'] == 'kick'),
        isTrue,
        reason: '鼓组事件必须进页面计划',
      );
      expect(
        eventMaps.any((event) => event['midi'] == 72),
        isTrue,
        reason: 'C5 = MIDI 72 必须进页面计划',
      );
    });

    test('标题里的 HTML 结束标签与行终止符被转义（不破坏内联脚本）', () {
      final String evilTitle =
          '</script><script>alert(1)</script>\u2028second line';
      final MusicScore score = _pianoScore(title: evilTitle);
      final String html = _html(score);
      final String raw = _jsonLiteral(html, 'SCORE');
      expect(raw, isNot(contains('</script>')));
      expect(raw, isNot(contains('<script')));
      expect(raw, contains(r'\u003c'));
      expect(raw, contains(r'\u2028'));
      expect(raw.contains('\u2028'), isFalse);
      final Map<String, Object?> decoded = Map<String, Object?>.from(
        jsonDecode(raw)! as Map,
      );
      expect(decoded['title'], evilTitle);
      // 页面自身仍然只有一段脚本，注入没有多开/提前关闭。
      expect('<script'.allMatches(html).length, 1);
      expect('</script>'.allMatches(html).length, 1);
    });
  });

  group('lookahead 调度与运输条', () {
    test('25ms 定时器 / 100ms 提前量 / 2s 后台窗口按常量注入', () {
      final String html = _html(_pianoScore());
      expect(musicPlayerLookaheadTimerMs, 25);
      expect(musicPlayerLookaheadAheadSeconds, 0.1);
      expect(musicPlayerBackgroundAheadSeconds, 2.0);
      expect(html, contains('var LOOKAHEAD_MS = 25;'));
      expect(html, contains('var AHEAD_SEC = 0.1;'));
      expect(html, contains('var AHEAD_BG_SEC = 2.0;'));
      expect(html, contains('setInterval(schedulerTick, LOOKAHEAD_MS)'));
      expect(html, contains('AHEAD_BG_SEC'));
      expect(html, contains('document.hidden'));
      // AudioContext.currentTime 是唯一时钟：不出现墙钟/帧钟。
      expect(html, contains('audioCtx.currentTime'));
      expect(html, isNot(contains('Date.now')));
      expect(html, isNot(contains('performance.now')));
      expect(html, isNot(contains('requestAnimationFrame')));
      // 定时器回调只把事件排进音频时钟（start(when)），不直接同步播放。
      expect(html, contains('osc.start(when)'));
      expect(html, contains('source.start(when, offset)'));
    });

    test('播放/暂停/停止/seek 与手势启动 AudioContext', () {
      final String html = _html(_pianoScore());
      expect(html, contains('function play()'));
      expect(html, contains('function pause()'));
      expect(html, contains('function stopPlayback()'));
      expect(html, contains('function seek('));
      expect(html, contains("playButton.addEventListener('click'"));
      expect(
        html,
        contains('window.AudioContext || window.webkitAudioContext'),
      );
      expect(html, contains('new Ctor()'));
      expect(html, contains('audioCtx.resume()'));
      // 暂停/seek：cancelScheduledValues + 短淡出 + stop + generation 代际号。
      expect(html, contains('cancelScheduledValues'));
      expect(html, contains('linearRampToValueAtTime(0, now + FADE_SEC)'));
      expect(html, contains('stopVoices()'));
      expect(html, contains('generation'));
      // seek 进度条与轨道音量/静音控制面存在。
      expect(html, contains('id="music-seek"'));
      expect(html, contains('setTrackVolume'));
      expect(html, contains('setTrackMuted'));
    });
  });

  group('NONMUSIC 桥与合成器', () {
    test('只回传 beat / ended / error 三类桥消息', () {
      final String html = _html(_pianoScore());
      expect(musicPlayerBridgeMessages, <String>['beat', 'ended', 'error']);
      expect(html, contains('window.NONMUSIC'));
      expect(
        html,
        contains('window.NONMUSIC.postMessage(JSON.stringify(obj))'),
      );
      final Set<String> kinds = RegExp(r"postMessage\('([a-z]+)'")
          .allMatches(html)
          .map((RegExpMatch match) => match.group(1)!)
          .toSet();
      expect(kinds, musicPlayerBridgeMessages.toSet());
      expect(html, contains('window.addEventListener(\'error\''));
      expect(html, contains('unhandledrejection'));
      expect(html, contains('window.NONMUSIC_PLAYER'));
    });

    test('六音色与鼓组是页面内纯代码合成器（名字对齐契约注册表）', () {
      final String html = _html(_mixedScore());
      for (final String name in <String>[
        'voicePiano',
        'voiceStrings',
        'voiceBass',
        'voiceBell',
        'voiceOrgan',
        'voicePluck',
      ]) {
        expect(html, contains('function $name('), reason: '缺少音色 $name');
      }
      for (final String name in <String>[
        'drumKick',
        'drumSnare',
        'drumHihat',
        'drumOpenhat',
        'drumCrash',
        'drumRide',
        'drumTom',
      ]) {
        expect(html, contains('function $name('), reason: '缺少鼓件 $name');
      }
      expect(musicPlayerTimbres, <String>[
        'piano',
        'strings',
        'bass',
        'bell',
        'organ',
        'pluck',
      ]);
      expect(musicPlayerDrumPieces, <String>[
        'kick',
        'snare',
        'hihat',
        'openhat',
        'crash',
        'ride',
        'tom',
      ]);
      // 合成器名字必须命中 score 契约注册表（防两边漂移）。
      expect(musicPlayerTimbres.every(musicInstruments.contains), isTrue);
      expect(musicPlayerDrumPieces.every(musicDrumNames.contains), isTrue);
      // 鼓组来自固定种子噪声（同一页面每次启动字节一致）。
      expect(html, contains('makeNoiseBuffer'));
      expect(html, contains('noiseBuffer'));
    });
  });
}
