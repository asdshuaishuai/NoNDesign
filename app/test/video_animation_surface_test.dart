// 代码动画播放面（VideoAnimationSurface）的行为测试。
//
// 覆盖：
//  ① 打开即第一帧就绪：画面来自 document.frameSvg(t)，读数与帧号都从 0 起；
//  ② 播放推进时间与帧号（按文档帧率走表），暂停即停表；
//  ③ 时间条拖动立即换帧；回片头；循环开关；
//  ④ 不循环时播到片尾停住，再点播放从片头重来；
//  ⑤ 单帧生成失败只留一句人话，面板不崩、不抛异常。
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nondesign/core/theme.dart';
import 'package:nondesign/core/video_service.dart';
import 'package:nondesign/widgets/video_animation_surface.dart';

const _frameProblem = '这一帧没能画出来，检查脚本里这一段的算式';

VideoDocument _sampleDoc() => VideoService(host: VideoHost.macos).loadSample(0);

/// 一秒十帧的小文档（片尾行为测试用，避免长时间 pump）。
VideoDocument _shortDoc() => VideoDocument.build(
      timeline: <String, dynamic>{
        'fps': 10,
        'width': 320,
        'height': 180,
        'spec': 'spec.json',
        'scenes': <dynamic>[
          <String, dynamic>{
            'duration': 1.0,
            'elements': <dynamic>[
              <String, dynamic>{'type': 'rect', 'x': 10, 'y': 10, 'w': 50, 'h': 30, 'color': '#FFB65C'},
            ],
          },
        ],
      },
      spec: <String, dynamic>{
        'kind': 'science',
        'subject': '小样',
        'laws': <String>['a'],
        'assumptions': <String>['b'],
        'facts': <String>['c'],
      },
    );

/// 引用了一张不存在的图片：第一帧在生成阶段就失败（走到面板的兜底文案）。
VideoDocument _brokenFrameDoc() => VideoDocument.build(
      timeline: <String, dynamic>{
        'fps': 10,
        'width': 320,
        'height': 180,
        'spec': 'spec.json',
        'scenes': <dynamic>[
          <String, dynamic>{
            'duration': 1.0,
            'elements': <dynamic>[
              <String, dynamic>{
                'type': 'image',
                'path': 'definitely-no-such-frame-xyz.png',
                'x': 10,
                'y': 10,
                'w': 100,
                'h': 100,
              },
            ],
          },
        ],
      },
      spec: <String, dynamic>{
        'kind': 'science',
        'subject': '小样',
        'laws': <String>['a'],
        'assumptions': <String>['b'],
        'facts': <String>['c'],
      },
    );

/// 画面本身写坏了（这里用一个非法颜色值让整帧 XML 不成立）：
/// 兜底必须落在同一句人话上，而不是把异常抛给工作面。
VideoDocument _malformedSvgDoc() => VideoDocument.build(
      timeline: <String, dynamic>{
        'fps': 10,
        'width': 320,
        'height': 180,
        'spec': 'spec.json',
        'scenes': <dynamic>[
          <String, dynamic>{
            'duration': 1.0,
            'elements': <dynamic>[
              <String, dynamic>{'type': 'rect', 'x': 10, 'y': 10, 'w': 50, 'h': 30, 'color': '"><bad'},
            ],
          },
        ],
      },
      spec: <String, dynamic>{
        'kind': 'science',
        'subject': '小样',
        'laws': <String>['a'],
        'assumptions': <String>['b'],
        'facts': <String>['c'],
      },
    );

Widget _wrap(Widget child) => MaterialApp(
      theme: AppTheme.build(dark: true),
      home: Scaffold(
        body: Center(
          child: SizedBox(width: 960, height: 540, child: child),
        ),
      ),
    );

Future<void> _pump(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(1100, 760);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(_wrap(child));
  await tester.pumpAndSettle();
}

String _timeText(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const ValueKey('video-animation-time'))).data ?? '';

String _frameText(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const ValueKey('video-animation-frame'))).data ?? '';

void main() {
  testWidgets('第一帧就绪：画面、时间读数与帧号都在，且停在片头', (tester) async {
    await _pump(tester, VideoAnimationSurface(document: _sampleDoc()));

    expect(find.byKey(const ValueKey('video-animation-surface')), findsOneWidget);
    expect(find.byType(SvgPicture), findsOneWidget);
    expect(_timeText(tester), '00:00.000 / 00:08.000');
    expect(_frameText(tester), 'frame 1/240');
    expect(tester.takeException(), isNull);
  });

  testWidgets('播放推进时间与帧号；暂停即停表', (tester) async {
    final frames = <int>[];
    await _pump(
      tester,
      VideoAnimationSurface(
        document: _sampleDoc(),
        onFrame: (seconds, frameIndex) => frames.add(frameIndex),
      ),
    );
    expect(_timeText(tester), '00:00.000 / 00:08.000');

    await tester.tap(find.byKey(const ValueKey('video-animation-play')));
    await tester.pump(const Duration(milliseconds: 300));

    final playing = _timeText(tester);
    expect(playing, isNot('00:00.000 / 00:08.000'), reason: '播放后读数必须前进');
    expect(frames.last, greaterThan(0), reason: '播放后帧号必须前进');
    expect(_frameText(tester), isNot('frame 1/240'));

    // 暂停：再等一段时间，读数不动。
    await tester.tap(find.byKey(const ValueKey('video-animation-play')));
    await tester.pump(const Duration(milliseconds: 50));
    final paused = _timeText(tester);
    await tester.pump(const Duration(milliseconds: 300));
    expect(_timeText(tester), paused);

    // 回片头：读数与帧号归零。
    await tester.tap(find.byKey(const ValueKey('video-animation-restart')));
    await tester.pump(const Duration(milliseconds: 50));
    expect(_timeText(tester), '00:00.000 / 00:08.000');
    expect(_frameText(tester), 'frame 1/240');
    expect(tester.takeException(), isNull);
  });

  testWidgets('拖动时间条立即换帧（暂停态也能逐帧看）', (tester) async {
    await _pump(tester, VideoAnimationSurface(document: _sampleDoc()));

    final slider = tester.widget<Slider>(find.byKey(const ValueKey('video-animation-slider')));
    expect(slider.max, 8.0);
    slider.onChanged!(4.0);
    await tester.pump();

    expect(_timeText(tester), '00:04.000 / 00:08.000');
    expect(_frameText(tester), 'frame 121/240');
    // 拖动不自动开播。
    await tester.pump(const Duration(milliseconds: 200));
    expect(_timeText(tester), '00:04.000 / 00:08.000');

    // 真的用手指拖：读数跟着跳，帧号跟着换。
    final beforeDrag = _timeText(tester);
    await tester.drag(
      find.byKey(const ValueKey('video-animation-slider')),
      const Offset(160, 0),
    );
    await tester.pump();
    expect(_timeText(tester), isNot(beforeDrag));
    expect(_frameText(tester), isNot('frame 121/240'));
  });

  testWidgets('循环开关：图标切换 + 状态不抛；开循环时播到片尾回绕', (tester) async {
    await _pump(tester, VideoAnimationSurface(document: _shortDoc()));

    Icon loopIcon() => tester.widget<Icon>(find.descendant(
          of: find.byKey(const ValueKey('video-animation-loop')),
          matching: find.byType(Icon),
        ));
    final before = loopIcon().icon;
    await tester.tap(find.byKey(const ValueKey('video-animation-loop')));
    await tester.pump();
    expect(loopIcon().icon, isNot(before));
    expect(tester.takeException(), isNull);

    // 循环关掉：播到片尾停住，再点播放从片头重来。
    await tester.tap(find.byKey(const ValueKey('video-animation-play')));
    await tester.pump(const Duration(seconds: 2));
    expect(_timeText(tester), '00:01.000 / 00:01.000');

    await tester.tap(find.byKey(const ValueKey('video-animation-play')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(_timeText(tester), isNot('00:01.000 / 00:01.000'));
    // 收尾：暂停，别把计时器留到测试结束。
    await tester.tap(find.byKey(const ValueKey('video-animation-play')));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('画面本身画不出来：同样落到那句人话，不崩不抛', (tester) async {
    await _pump(tester, VideoAnimationSurface(document: _malformedSvgDoc()));
    expect(find.text(_frameProblem), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('单帧生不出来：面板给一句人话，不崩不抛', (tester) async {
    await _pump(tester, VideoAnimationSurface(document: _brokenFrameDoc()));

    expect(find.text(_frameProblem), findsOneWidget);
    // 播放也不会崩（每一帧都失败也只是同一个提示）。
    await tester.tap(find.byKey(const ValueKey('video-animation-play')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(_frameProblem), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('video-animation-play')));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
