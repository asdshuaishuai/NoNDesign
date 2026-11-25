import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nondesign/core/music/music_compile.dart';
import 'package:nondesign/core/music/music_score.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/widgets/music_playback_surface.dart';
import 'package:webview_all_wkwebview/webview_all_wkwebview.dart';
// 平台接口桩直接从平台接口库取（测试专用传递依赖，与 three_threeui_test 同形）。
// ignore: depend_on_referenced_packages
import 'package:webview_platform_interface/webview_platform_interface.dart';

// ---------------------------------------------------------------------------
// Fixtures：可直接编译成整数 tick 的 4/4 小谱（96 BPM → 总时长 2.5s）。
// ---------------------------------------------------------------------------

MusicScore _score() => MusicScore(
  title: '演奏测试',
  tempo: 96,
  timeSig: const <int>[4, 4],
  keySig: 'C',
  tracks: <MusicTrack>[
    MusicTrack(
      id: 'melody',
      name: '主旋律',
      instrument: 'piano',
      volume: 1.0,
      muted: false,
      measures: <MusicMeasure>[
        MusicMeasure(
          id: 'm1',
          events: <MusicEvent>[
            for (int i = 0; i < 4; i++)
              MusicEvent(
                id: 'n$i',
                isRest: false,
                durNum: 1,
                durDen: 4,
                step: const <String>['C', 'D', 'E', 'G'][i],
                octave: 5,
              ),
          ],
        ),
      ],
    ),
  ],
);

MusicPlayPlan _plan() => compileMusicScore(_score());

Widget _app(Widget child) => MaterialApp(
  theme: AppTheme.build(dark: true),
  home: Scaffold(body: child),
);

// ---------------------------------------------------------------------------
// 可注入 Fake 播放控制器：覆盖播放/暂停/停止/seek/错误状态变化，不构造 WebView。
// ---------------------------------------------------------------------------

class _FakePlayback extends MusicPlaybackController {
  _FakePlayback();

  @override
  double get duration => 2.5;
  bool _ready = false;
  bool _playing = false;
  double _position = 0;
  int _beat = -1;
  int _bar = 0;
  String _loadError = '';
  String _technicalDetail = '';

  int playCalls = 0;
  int pauseCalls = 0;
  int stopCalls = 0;
  final List<double> seekCalls = <double>[];

  void emitError(String message, [String detail = '']) {
    _ready = true;
    _playing = false;
    _loadError = message;
    _technicalDetail = detail;
    notifyListeners();
  }

  void advance(double position, {int beat = -1, int bar = 0}) {
    _position = position;
    _beat = beat;
    _bar = bar;
    notifyListeners();
  }

  @override
  bool get ready => _ready;

  @override
  bool get playing => _playing;

  @override
  double get position => _position;

  @override
  @override
  int get beat => _beat;

  @override
  int get bar => _bar;

  @override
  String get loadError => _loadError;

  @override
  String get technicalDetail => _technicalDetail;

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
    _position = 0;
    _beat = -1;
    _bar = 0;
    notifyListeners();
  }

  @override
  Future<void> seek(double seconds) async {
    seekCalls.add(seconds);
    _position = seconds;
    notifyListeners();
  }
}

// ---------------------------------------------------------------------------
// WebView 平台桩（不构造真 WebView；与 three_workspace_test / hobby 测试同形）：
// 捕获 loadHtmlString / JS 命令 / 桥回调 / 主帧资源错误。
// ---------------------------------------------------------------------------

class _FakeWebViewPlatform extends WebViewPlatform {
  _FakeController? lastController;

  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) => lastController = _FakeController(params);

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => _FakeNavigationDelegate(params);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) => _FakeWebViewWidget(params);
}

class _FakeController extends PlatformWebViewController {
  _FakeController(super.params) : super.implementation();

  String? loadedHtml;
  final List<String> jsCommands = <String>[];
  void Function(JavaScriptMessage)? bridgeCallback;
  _FakeNavigationDelegate? navigationDelegate;

  @override
  Future<void> setJavaScriptMode(JavaScriptMode mode) async {}

  @override
  Future<void> addJavaScriptChannel(dynamic params) async {
    if (params.name == musicPlaybackBridgeChannel) {
      bridgeCallback =
          params.onMessageReceived as void Function(JavaScriptMessage);
    }
  }

  @override
  Future<void> setPlatformNavigationDelegate(dynamic delegate) async {
    navigationDelegate = delegate as _FakeNavigationDelegate;
  }

  @override
  Future<void> loadHtmlString(String html, {String? baseUrl}) async {
    loadedHtml = html;
  }

  @override
  Future<void> runJavaScript(String javaScript) async {
    jsCommands.add(javaScript);
  }

  @override
  Future<Object> runJavaScriptReturningResult(String javaScript) async {
    if (javaScript.contains('typeof')) return 'object';
    if (javaScript.contains('position()')) return 2.5;
    return 'undefined';
  }

  void fireBridge(String json) =>
      bridgeCallback?.call(JavaScriptMessage(message: json));
}

class _FakeNavigationDelegate extends PlatformNavigationDelegate {
  _FakeNavigationDelegate(super.params) : super.implementation();

  void Function(WebResourceError)? onResourceError;

  @override
  Future<void> setOnWebResourceError(WebResourceErrorCallback cb) async =>
      onResourceError = cb;

  void fireMainFrameError() => onResourceError?.call(
    const WebResourceError(
      errorCode: -1009,
      description: 'offline',
      isForMainFrame: true,
    ),
  );
}

class _FakeWebViewWidget extends PlatformWebViewWidget {
  _FakeWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

Future<_FakeWebViewPlatform> _installFakePlatform() async {
  final _FakeWebViewPlatform fake = _FakeWebViewPlatform();
  WebViewPlatform.instance = fake;
  addTearDown(() => WebViewPlatform.instance = WebKitWebViewPlatform());
  return fake;
}

void main() {
  group('时长派生（与播放页 tick→秒同口径）', () {
    test('96 BPM / 4 个四分音符 = 2.5s；空计划 = 0', () {
      expect(musicPlaybackDurationSeconds(_plan()), closeTo(2.5, 1e-9));
      expect(
        musicPlaybackDurationSeconds(
          const MusicPlayPlan(
            ppq: 3840,
            tempoMap: <Map<String, int>>[
              <String, int>{'tick': 0, 'bpm': 96},
            ],
            tracks: <String>[],
            events: <MusicPlayEvent>[],
            totalTicks: 0,
          ),
        ),
        0,
      );
    });

    test('播放头时间文案与页面 formatTime 一致', () {
      expect(formatMusicPlaybackTime(0), '0:00');
      expect(formatMusicPlaybackTime(2.5), '0:03');
      expect(formatMusicPlaybackTime(125.4), '2:05');
      expect(formatMusicPlaybackTime(double.nan), '0:00');
    });
  });

  group('Fake 控制器（不构造 WebView）', () {
    testWidgets('就绪/播放/暂停/停止/seek 状态变化反映到演奏面', (tester) async {
      final _FakePlayback fake = _FakePlayback();
      await tester.pumpWidget(_app(MusicPlaybackSurface(playback: fake)));
      await tester.pump();

      expect(
        find.byKey(const ValueKey('music-playback-surface')),
        findsOneWidget,
      );
      // Fake 的舞台占位（真 WebView 只在生产控制器里挂）。
      expect(
        find.byKey(const ValueKey('music-playback-stage')),
        findsOneWidget,
      );
      expect(find.text('准备中'), findsOneWidget);

      // start 后就绪；Fake 的命令仍是这一份状态源。
      await fake.start();
      await tester.pump();
      expect(find.text('可以播放'), findsOneWidget);

      await fake.play();
      await tester.pump();
      expect(fake.playCalls, 1);
      expect(find.text('播放中'), findsOneWidget);

      await fake.pause();
      await tester.pump();
      expect(fake.pauseCalls, 1);
      expect(find.text('可以播放'), findsOneWidget);

      await fake.seek(1.25);
      await tester.pump();
      expect(fake.seekCalls, <double>[1.25]);
      expect(fake.position, 1.25);

      await fake.stop();
      await tester.pump();
      expect(fake.stopCalls, 1);
      expect(fake.position, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('错误回调 → 人话主文案 + 折叠技术详情，Fake 不显示重试', (tester) async {
      final _FakePlayback fake = _FakePlayback();
      await tester.pumpWidget(_app(MusicPlaybackSurface(playback: fake)));
      await tester.pump();
      fake.emitError('这台设备暂时放不出声音，可以重试或换个设备', 'audio-raw-diagnostic');
      await tester.pump();

      expect(
        find.byKey(const ValueKey('music-playback-error')),
        findsOneWidget,
      );
      // 主文案是人话，原始诊断不直接出现在主区（折叠在「技术详情」里）。
      expect(find.text('这台设备暂时放不出声音，可以重试或换个设备'), findsOneWidget);
      expect(find.text('技术详情'), findsOneWidget);
      // 原始诊断折叠在「技术详情」里：展开后才出现，不作为主文案。
      await tester.tap(find.text('技术详情'));
      await tester.pumpAndSettle();
      expect(find.text('audio-raw-diagnostic'), findsOneWidget);
      // Fake 没有重试语义：重试按钮只对真实播放面出现。
      expect(find.byKey(const ValueKey('music-playback-retry')), findsNothing);
      expect(find.text('不可用'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('生产播放面（WebView 平台桩）', () {
    test('loadHtmlString 载入组装页；命令走 window.NONMUSIC_PLAYER；桥消息回传', () async {
      final _FakeWebViewPlatform platform = await _installFakePlatform();
      final MusicWebPlayback playback = MusicWebPlayback(
        score: _score(),
        plan: _plan(),
      );
      addTearDown(playback.dispose);

      await playback.start();
      final _FakeController controller = platform.lastController!;
      expect(playback.ready, isTrue, reason: '页面 API 出现即就绪');
      expect(controller.loadedHtml, isNotNull);
      expect(controller.loadedHtml, contains('<!doctype html>'));
      expect(controller.loadedHtml, contains('window.NONMUSIC_PLAYER'));
      expect(controller.bridgeCallback, isNotNull, reason: 'NONMUSIC 桥必须挂上');

      // 命令面：页面自身 API（不是宿主伪造状态）。
      await playback.play();
      expect(
        controller.jsCommands.last,
        contains('window.NONMUSIC_PLAYER.play()'),
      );
      expect(playback.playing, isTrue);
      await playback.pause();
      expect(
        controller.jsCommands.last,
        contains('window.NONMUSIC_PLAYER.pause()'),
      );
      expect(playback.playing, isFalse);
      await playback.seek(1.25);
      expect(
        controller.jsCommands.last,
        contains('window.NONMUSIC_PLAYER.seek(1.250)'),
      );
      expect(playback.position, closeTo(1.25, 1e-9));
      await playback.stop();
      expect(
        controller.jsCommands.last,
        contains('window.NONMUSIC_PLAYER.stop()'),
      );
      expect(playback.position, 0);

      // beat：播放头/拍位/总时长回传；ended：回到片头、停止播放。
      controller.fireBridge(
        jsonEncode(<String, Object?>{
          'kind': 'beat',
          'beat': 2,
          'bar': 1,
          'tick': 7680,
          'position': 1.25,
          'total': 2.5,
        }),
      );
      expect(playback.beat, 2);
      expect(playback.bar, 1);
      expect(playback.position, closeTo(1.25, 1e-9));
      expect(playback.playing, isTrue);
      controller.fireBridge(
        jsonEncode(<String, Object?>{
          'kind': 'ended',
          'position': 2.5,
          'total': 2.5,
        }),
      );
      expect(playback.playing, isFalse);
      expect(playback.position, 0);

      // error：人话主文案 + 原始诊断进 technicalDetail，绝不冒充成功。
      controller.fireBridge(
        jsonEncode(<String, Object?>{
          'kind': 'error',
          'message': '当前环境不支持音频上下文',
        }),
      );
      expect(playback.playing, isFalse);
      expect(playback.loadError, isNotEmpty);
      expect(playback.loadError, contains('声音'));
      expect(playback.technicalDetail, contains('音频上下文'));
    });

    testWidgets('就绪后在演奏面挂出真舞台；主帧加载失败显性降级', (tester) async {
      final _FakeWebViewPlatform platform = await _installFakePlatform();
      final MusicWebPlayback playback = MusicWebPlayback(
        score: _score(),
        plan: _plan(),
      );
      addTearDown(playback.dispose);
      await playback.start();

      await tester.pumpWidget(_app(MusicPlaybackSurface(playback: playback)));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('music-playback-stage')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('music-playback-error')), findsNothing);
      expect(find.text('可以播放'), findsOneWidget);

      // 主帧资源错误（导航失败）→ 错误占位 + 重试 + 技术详情；
      // 子资源错误不整块替换（这里只触发主帧）。
      platform.lastController!.navigationDelegate!.fireMainFrameError();
      await tester.pump();
      expect(
        find.byKey(const ValueKey('music-playback-error')),
        findsOneWidget,
      );
      expect(find.text('演奏页没有加载出来，可以重试'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('music-playback-retry')),
        findsOneWidget,
      );
      expect(playback.ready, isFalse);
      expect(tester.takeException(), isNull);
    });

    test('WebView 不可用：显性降级，不假装可播', () async {
      debugMusicPlaybackWebViewSupported = false;
      addTearDown(() => debugMusicPlaybackWebViewSupported = null);
      final MusicWebPlayback playback = MusicWebPlayback(
        score: _score(),
        plan: _plan(),
      );
      addTearDown(playback.dispose);
      await playback.start();
      expect(playback.ready, isFalse);
      expect(playback.loadError, '这台设备暂时不能内嵌播放音乐');
      // 不可用时命令是空操作：不会把 playing 伪装成 true。
      await playback.play();
      expect(playback.playing, isFalse);
    });
  });
}
