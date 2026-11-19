// 动效合成播放面（VideoClipSurface / VideoClipTransport）的行为测试。
//
// 覆盖：
//  ① 运输条只读 [VideoClipPlayback]：播放/暂停切换、拖动 seek、时间与时长
//     文案、`帧 N = floor(t*30)+1`、循环开关；
//  ② 320 宽窄屏不溢出、不抛异常；
//  ③ 注入 Fake 播放源时播放面不构造 WebView，16:9 画位仍在；
//  ④ 平台没有应用内 WebView 时是「一句人话 + 用电脑上的连接桌面查看」，
//     不是白屏；页面没启动时给「可重试」与重试按钮。
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nondesign/core/platform_capabilities.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/core/video_clip.dart';
import 'package:nondesign/widgets/video_clip_surface.dart';

VideoClipInfo _clip() => VideoClipInfo(
      id: 'sketch-friction',
      title: '摩擦力 · 简笔演示',
      subtitle: '手绘纸面 + 逐笔描线 + 数值滚动',
      style: 'hand',
      duration: 13.2,
      tags: const <String>['简笔', '物理'],
    );

/// 可编排的播放源：断言 UI 怎么调它，不需要真 WebView。
class _FakePlayback extends VideoClipPlayback {
  _FakePlayback({
    this._duration = 13.2,
    this.loadError = '',
  });

  final double _duration;
  bool _loop = true;

  double _t = 0;
  bool _playing = false;

  @override
  bool ready = true;

  @override
  String loadError;

  bool disposed = false;
  int playCalls = 0;
  int pauseCalls = 0;
  int restartCalls = 0;
  final List<double> seeks = <double>[];

  @override
  double get t => _t;

  @override
  double get duration => _duration;

  @override
  bool get playing => _playing;

  @override
  bool get loop => _loop;

  @override
  Future<void> play() async {
    playCalls += 1;
    _playing = true;
    notifyListeners();
  }

  @override
  Future<void> pause() async {
    pauseCalls += 1;
    _playing = false;
    notifyListeners();
  }

  @override
  Future<void> seek(double seconds) async {
    seeks.add(seconds);
    _t = seconds.clamp(0.0, _duration).toDouble();
    notifyListeners();
  }

  @override
  Future<void> restart() async {
    restartCalls += 1;
    _t = 0;
    _playing = true;
    notifyListeners();
  }

  @override
  Future<void> setLoop(bool value) async {
    _loop = value;
    notifyListeners();
  }

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}

Widget _wrap(Widget child) => MaterialApp(
      theme: AppTheme.build(dark: true),
      home: Scaffold(
        body: Center(child: child),
      ),
    );

String _time(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const ValueKey('video-clip-time'))).data!;

String _frame(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const ValueKey('video-clip-frame'))).data!;

Icon _playIcon(WidgetTester tester) => tester.widget<Icon>(find.descendant(
      of: find.byKey(const ValueKey('video-clip-play')),
      matching: find.byType(Icon),
    ));

Future<void> _pumpTransport(WidgetTester tester, VideoClipPlayback playback) async {
  tester.view.physicalSize = const Size(560, 260);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(_wrap(SizedBox(width: 520, child: VideoClipTransport(playback: playback))));
  await tester.pump();
}

void main() {
  group('VideoClipTransport', () {
    testWidgets('播放/暂停切换、时间、帧号与循环开关都跟随播放源', (tester) async {
      final playback = _FakePlayback();
      await _pumpTransport(tester, playback);

      expect(find.byKey(const ValueKey('video-clip-transport')), findsOneWidget);
      expect(_time(tester), '00:00.000 / 00:13.200');
      expect(_frame(tester), '帧 1');
      expect(_playIcon(tester).icon, Icons.play_arrow);

      await tester.tap(find.byKey(const ValueKey('video-clip-play')));
      await tester.pump();
      expect(playback.playCalls, 1);
      expect(playback.playing, isTrue);
      expect(_playIcon(tester).icon, Icons.pause);

      await tester.tap(find.byKey(const ValueKey('video-clip-play')));
      await tester.pump();
      expect(playback.pauseCalls, 1);
      expect(playback.playing, isFalse);
      expect(_playIcon(tester).icon, Icons.play_arrow);

      // 拖动进度：seek 会同步回播放源，时间与帧号立刻跟着换。
      tester
          .widget<Slider>(find.byKey(const ValueKey('video-clip-slider')))
          .onChanged!(3.2);
      await tester.pump();
      expect(playback.seeks, [3.2]);
      expect(_time(tester), '00:03.200 / 00:13.200');
      expect(_frame(tester), '帧 97', reason: 'floor(3.2 × 30) + 1 = 97');

      // 循环默认开；点一下关掉，再点回来。
      expect(playback.loop, isTrue);
      await tester.tap(find.byKey(const ValueKey('video-clip-loop')));
      await tester.pump();
      expect(playback.loop, isFalse);
      await tester.tap(find.byKey(const ValueKey('video-clip-loop')));
      await tester.pump();
      expect(playback.loop, isTrue);

      expect(tester.takeException(), isNull);
    });

    testWidgets('帧号按 30fps 换算（片尾不越界成负值）', (tester) async {
      final playback = _FakePlayback(duration: 2);
      await _pumpTransport(tester, playback);

      tester.widget<Slider>(find.byKey(const ValueKey('video-clip-slider'))).onChanged!(0.99);
      await tester.pump();
      expect(_frame(tester), '帧 30', reason: 'floor(0.99 × 30) + 1 = 30');

      tester.widget<Slider>(find.byKey(const ValueKey('video-clip-slider'))).onChanged!(2);
      await tester.pump();
      expect(_frame(tester), '帧 61', reason: '片尾帧号按 floor(t×30)+1 直接换算');
      expect(_time(tester), '00:02.000 / 00:02.000');
    });

    testWidgets('320 宽窄屏：运输条不溢出、不抛异常', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final playback = _FakePlayback();
      await tester.pumpWidget(_wrap(VideoClipTransport(playback: playback)));
      await tester.pump();

      expect(find.byKey(const ValueKey('video-clip-play')), findsOneWidget);
      expect(find.byKey(const ValueKey('video-clip-slider')), findsOneWidget);
      expect(find.byKey(const ValueKey('video-clip-time')), findsOneWidget);
      expect(find.byKey(const ValueKey('video-clip-frame')), findsOneWidget);
      expect(find.byKey(const ValueKey('video-clip-loop')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('VideoClipSurface', () {
    testWidgets('注入播放源：16:9 画位就位，不构造 WebView', (tester) async {
      final playback = _FakePlayback();
      await tester.pumpWidget(_wrap(
        SizedBox(
          width: 640,
          height: 360,
          child: VideoClipSurface(clip: _clip(), playback: playback),
        ),
      ));
      await tester.pump();

      expect(find.byKey(const ValueKey('video-clip-surface')), findsOneWidget);
      expect(find.byKey(const ValueKey('video-clip-stage')), findsOneWidget);
      final size = tester.getSize(find.byKey(const ValueKey('video-clip-surface')));
      expect(size.width / size.height, closeTo(16 / 9, 0.02));
      expect(tester.takeException(), isNull);
    });

    testWidgets('页面没启动：一句人话 + 重试按钮，不停在黑屏', (tester) async {
      final playback = _FakePlayback(loadError: '动效合成没有启动，可重试');
      await tester.pumpWidget(_wrap(
        SizedBox(
          width: 640,
          height: 360,
          child: VideoClipSurface(clip: _clip(), playback: playback),
        ),
      ));
      await tester.pump();

      expect(find.text('动效合成没有启动，可重试'), findsOneWidget);
      expect(find.byKey(const ValueKey('video-clip-retry')), findsOneWidget);
      expect(find.byKey(const ValueKey('video-clip-error')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('平台没有应用内 WebView：降级说明，不是白屏', (tester) async {
      await tester.pumpWidget(_wrap(
        SizedBox(
          width: 640,
          height: 360,
          child: VideoClipSurface(
            clip: _clip(),
            host: PlatformCapabilities.forOs(HostOs.linux),
          ),
        ),
      ));
      await tester.pump();

      expect(find.byKey(const ValueKey('video-clip-unsupported')), findsOneWidget);
      expect(find.text('这台设备不能内嵌播放动效合成'), findsOneWidget);
      expect(find.text('用电脑上的连接桌面查看'), findsOneWidget);
      expect(find.byKey(const ValueKey('video-clip-surface')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
