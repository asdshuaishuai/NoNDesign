// 引擎短片预览面：Fake 控制器下的状态/控制条/错误面；纯函数文案映射。
import 'package:material_ui/material_ui.dart';
import 'package:webview_all/webview_all.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nondesign/core/theme.dart';
import 'package:nondesign/core/video/video_screenplay.dart';
import 'package:nondesign/core/video/video_short_player.dart';
import 'package:nondesign/widgets/video_short_preview_surface.dart';

Widget _app(Widget child) => MaterialApp(
  theme: AppTheme.build(dark: true),
  home: Scaffold(body: child),
);

class _FakeShortPreview extends VideoShortPreviewController {
  @override
  int get totalFrames => 60;

  bool _ready = false;
  bool _playing = false;
  int _frame = 0;
  String _loadError = '';
  String _technicalDetail = '';
  final String _renderer = 'phaser4_canvas';
  final String _vfx = 'pixelfx_pixels';

  int playCalls = 0;
  int pauseCalls = 0;
  int stopCalls = 0;
  final List<int> seekFrameCalls = <int>[];

  @override
  bool get ready => _ready;

  @override
  bool get playing => _playing;

  @override
  int get frame => _frame;

  @override
  int get fps => 30;

  @override
  String get loadError => _loadError;

  @override
  String get technicalDetail => _technicalDetail;

  @override
  String get renderer => _renderer;

  @override
  String get vfxRenderer => _vfx;

  @override
  Future<void> start() async {
    _ready = true;
    notifyListeners();
  }

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
  Future<void> stop() async {
    stopCalls += 1;
    _playing = false;
    _frame = 0;
    notifyListeners();
  }

  @override
  Future<void> seek(double seconds) async {
    await seekFrame((seconds * 30).round());
  }

  @override
  Future<void> seekFrame(int frame) async {
    seekFrameCalls.add(frame);
    _frame = frame.clamp(0, totalFrames - 1);
    notifyListeners();
  }

  void failNow(String message, String detail) {
    _ready = false;
    _loadError = message;
    _technicalDetail = detail;
    notifyListeners();
  }
}

void main() {
  group('纯函数：文案映射', () {
    test('组装失败码 → 人话', () {
      expect(
        videoShortFailureMessage(videoShortPhaserMissingCode),
        contains('引擎运行文件'),
      );
      expect(
        videoShortFailureMessage(videoShortScreenplayInvalidCode),
        contains('剧本'),
      );
      expect(videoShortFailureMessage('unknown_code'), contains('可以重试'));
    });

    test('页面错误 → 人话（不直接上屏原始文本）', () {
      expect(
        videoShortPageErrorMessage('引擎启动失败：boom'),
        contains('引擎没有启动起来'),
      );
      expect(
        videoShortPageErrorMessage('vfx 渲染失败：cue missing'),
        contains('特效'),
      );
      expect(videoShortPageErrorMessage('未知炸裂'), contains('预览出错了'));
    });
  });

  group('预览面（Fake 控制器）', () {
    testWidgets('就绪后出控制条；播放/暂停/停止/seek 反映到控制器', (tester) async {
      final _FakeShortPreview fake = _FakeShortPreview();
      await tester.pumpWidget(_app(VideoShortPreviewSurface(preview: fake)));
      await tester.pump();

      expect(
        find.byKey(const ValueKey('video-short-preview-surface')),
        findsOneWidget,
      );
      expect(find.text('准备中'), findsAtLeastNWidgets(1));
      // Fake 不构造 WebView：舞台是「准备中」占位。
      expect(find.byType(WebViewWidget), findsNothing);

      await fake.start();
      await tester.pump();
      expect(find.text('可以预览'), findsOneWidget);
      // 渲染器/VFX 面如实展示。
      expect(
        find.byKey(const ValueKey('video-short-preview-renderer')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('video-short-preview-play')));
      await tester.pump();
      expect(fake.playCalls, 1);
      expect(find.text('播放中'), findsOneWidget);

      // 同一个按钮切换为暂停（不是只会 play 的假按钮）。
      await tester.tap(find.byKey(const ValueKey('video-short-preview-play')));
      await tester.pump();
      expect(fake.pauseCalls, 1);
      expect(fake.playCalls, 1);

      await tester.tap(find.byKey(const ValueKey('video-short-preview-stop')));
      await tester.pump();
      expect(fake.stopCalls, 1);
      expect(fake.frame, 0);

      // 时钟文案：0:00 / 0:02（60 帧 @30fps）。
      expect(find.text('0:00 / 0:02'), findsOneWidget);
      await fake.seekFrame(30);
      await tester.pump();
      expect(find.text('0:01 / 0:02'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('失败：人话主文案 + 折叠技术详情；Fake 不出重试按钮', (tester) async {
      final _FakeShortPreview fake = _FakeShortPreview();
      await tester.pumpWidget(_app(VideoShortPreviewSurface(preview: fake)));
      await tester.pump();
      fake.failNow('这台设备暂时不能内嵌预览引擎短片', 'raw-diagnostic');
      await tester.pump();

      expect(
        find.byKey(const ValueKey('video-short-preview-error')),
        findsOneWidget,
      );
      expect(find.text('这台设备暂时不能内嵌预览引擎短片'), findsOneWidget);
      expect(find.text('技术详情'), findsOneWidget);
      expect(find.text('raw-diagnostic'), findsNothing);
      await tester.tap(find.text('技术详情'));
      await tester.pumpAndSettle();
      expect(find.text('raw-diagnostic'), findsOneWidget);
      // 重试只对真实预览面出现（Fake 没有可重启的 WebView）。
      expect(
        find.byKey(const ValueKey('video-short-preview-retry')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('WebView 不可用：显性降级，不假装可播', (tester) async {
      debugVideoShortPreviewWebViewSupported = false;
      final VideoShortWebPreview preview = VideoShortWebPreview(
        screenplay: _smallScreenplay(),
      );
      await tester.pumpWidget(
        _app(VideoShortPreviewSurface(preview: preview)),
      );
      await preview.start();
      await tester.pump();
      expect(preview.ready, isFalse);
      expect(preview.loadError, '这台设备暂时不能内嵌预览引擎短片');
      expect(preview.technicalDetail, contains('WebView'));
      expect(
        find.byKey(const ValueKey('video-short-preview-error')),
        findsOneWidget,
      );
      preview.dispose();
      debugVideoShortPreviewWebViewSupported = null;
      expect(tester.takeException(), isNull);
    });
  });
}

VideoScreenplay _smallScreenplay() {
  final VideoScreenplayVerification result = verifyVideoScreenplay(
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
              'f': 10,
              'type': 'vfx',
              'cue': 'fire.campfire',
            },
          ],
        },
      ],
    },
  );
  expect(result.verified, isTrue, reason: '${result.toJson()}');
  return result.screenplay!;
}
