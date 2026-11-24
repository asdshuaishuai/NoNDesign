import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/widgets/video_workbench_panels.dart';

Widget _app(Widget child) => MaterialApp(
  theme: AppTheme.build(dark: true),
  home: Scaffold(body: child),
);

Map<String, dynamic> _timeline() => <String, dynamic>{
  'fps': 30,
  'scenes': <Map<String, dynamic>>[
    <String, dynamic>{
      'title': '开场',
      'duration': 2.0,
      'background': '#0B0D12',
      'elements': <Object?>[<String, Object?>{}, <String, Object?>{}],
    },
    <String, dynamic>{
      'duration': 3.5,
      'elements': <Object?>[<String, Object?>{}],
      'transition': 'dissolve',
    },
  ],
};

void main() {
  group('视频导演台专属面板', () {
    test('timeline → 镜头列表：累计起点/label 兜底/坏场景跳过', () {
      final shots = videoShotsFromTimeline(_timeline());
      expect(shots, hasLength(2));
      expect(shots[0].index, 0);
      expect(shots[0].label, '开场');
      expect(shots[0].start, 0);
      expect(shots[0].duration, 2.0);
      expect(shots[0].elementCount, 2);
      expect(shots[1].label, '镜头 2');
      expect(shots[1].start, 2.0);
      expect(shots[1].end, closeTo(5.5, 1e-9));
      expect(shots[1].data['transition'], 'dissolve');

      final withBad = videoShotsFromTimeline(<String, dynamic>{
        'scenes': <dynamic>[
          <String, dynamic>{'duration': 1.0},
          'bad',
          <String, dynamic>{'duration': 2.0, 'title': '二'},
        ],
      });
      expect(withBad, hasLength(2));
      expect(withBad[1].start, 1.0);
      expect(withBad[1].label, '二');
      expect(videoShotsFromTimeline(null), isEmpty);
      expect(
        videoShotsFromTimeline(<String, dynamic>{'scenes': 'bad'}),
        isEmpty,
      );
    });

    testWidgets('剧本树：镜头行/选中回调', (tester) async {
      VideoShotItem? selected;
      final shots = videoShotsFromTimeline(_timeline());
      await tester.pumpWidget(
        _app(
          SizedBox(
            width: 280,
            height: 600,
            child: VideoScriptTree(
              shots: shots,
              selectedIndex: 0,
              onSelect: (shot) => selected = shot,
            ),
          ),
        ),
      );
      expect(
        find.byKey(const ValueKey('video-workbench-script-tree')),
        findsOneWidget,
      );
      expect(find.text('剧本 / 镜头'), findsOneWidget);
      expect(find.text('开场'), findsOneWidget);
      expect(find.text('镜头 2'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('video-shot-1')));
      expect(selected?.index, 1);
    });

    testWidgets('镜头检查器：选中镜头属性 / 空态项目概览', (tester) async {
      final shots = videoShotsFromTimeline(_timeline());
      await tester.pumpWidget(
        _app(
          SizedBox(
            width: 320,
            height: 600,
            child: VideoShotInspector(
              shot: shots[1],
              title: '演示片',
              fps: 30,
              totalSeconds: 5.5,
              shotCount: 2,
            ),
          ),
        ),
      );
      expect(
        find.byKey(const ValueKey('video-workbench-inspector')),
        findsOneWidget,
      );
      expect(find.text('镜头 2'), findsOneWidget);
      expect(find.text('时长'), findsOneWidget);
      expect(find.text('3.50 秒'), findsOneWidget);
      expect(find.text('dissolve'), findsOneWidget);

      await tester.pumpWidget(
        _app(
          const SizedBox(
            width: 320,
            height: 600,
            child: VideoShotInspector(
              title: '演示片',
              fps: 30,
              totalSeconds: 5.5,
              shotCount: 2,
            ),
          ),
        ),
      );
      expect(find.text('项目概览'), findsOneWidget);
      expect(find.text('5.50 秒'), findsOneWidget);
      expect(find.text('30'), findsOneWidget);
    });

    testWidgets('底部时间线：片段比例/选中/总时长', (tester) async {
      VideoShotItem? selected;
      final shots = videoShotsFromTimeline(_timeline());
      await tester.pumpWidget(
        _app(
          SizedBox(
            width: 900,
            height: 92,
            child: VideoTimelineStrip(
              shots: shots,
              selectedIndex: 0,
              onSelect: (shot) => selected = shot,
              fps: 30,
            ),
          ),
        ),
      );
      expect(
        find.byKey(const ValueKey('video-workbench-timeline')),
        findsOneWidget,
      );
      expect(find.text('5.5s · 30 fps'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('video-timeline-shot-1')));
      expect(selected?.index, 1);
    });
  });
}
