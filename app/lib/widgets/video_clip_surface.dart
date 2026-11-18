/// 动效合成播放面（HTML/CSS/JS 短片 → 应用内 WebView）。
///
/// 一支短片 = 一个自包含 HTML 文件；[VideoClipSurface] 负责把运行时
/// （`engine.css` / `engine.js`）内联成单文件，落到本机临时目录，再用 WebView
/// 按 `file://` 打开——全程离线，不联网、不引 CDN、不需要任何端口。
///
/// 数据流：
///  * 页面（`engine.js`）每次 `render(t)` 后通过
///    `window.VideoClipBridge.postMessage(JSON.stringify(...))` 回传
///    `ready` / `state` 两种消息；
///  * [VideoClipWebPlayback] 解析消息，维护 [VideoClipPlayback] 的
///    `{t, duration, playing, loop}`，并把 `play/pause/seek/restart/setLoop`
///    翻译成页面侧 `window.__ndClip.*` 调用；
///  * [VideoClipTransport] 只读这份播放源，画播放/暂停、进度、时间、帧号、
///    循环开关——它不碰 WebView，因此测试可以注入 Fake 播放源。
///
/// 平台：WebView 判据只有一个来源 [PlatformCapabilities.supportsInAppWebView]
/// （与 3D 预览、既有视频播放面同一矩阵）；Linux/Windows 没有应用内 WebView，
/// 降级成一句人话 +「用电脑上的连接桌面查看」，绝不白屏。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import '../core/platform_capabilities.dart';
import '../core/theme.dart';
import '../core/video_clip.dart';
import '../core/video_service.dart' show formatVideoTime;

/// 测试注入：WebView 平台矩阵的确定性覆盖。
///
/// 测试机恒为 macOS，造不出 Linux/Windows 环境；置 false 即走「无 WebView
/// 平台」的降级分支（与真机同一条代码路）。生产路径始终读
/// [PlatformCapabilities.supportsInAppWebView]。
@visibleForTesting
bool? debugVideoClipWebViewSupported;

/// 这台主机能否在应用内播动效合成。
bool videoClipWebViewSupported([PlatformCapabilities? host]) =>
    debugVideoClipWebViewSupported ??
    (host ?? PlatformCapabilities.current()).supportsInAppWebView;

/// 桥通道名（页面侧固定写死这个字符串，改它等于改契约）。
const String videoClipBridgeChannel = 'VideoClipBridge';

/// 播放状态源。
///
/// 界面只依赖这个抽象：生产实现是 [VideoClipWebPlayback]（WebView + 桥），
/// 测试注入 Fake；[VideoClipTransport] 因此不需要真 WebView。
/// `fps` 固定 30（短片帧号读数口径），`frame` 是从 0 起算的时间换算成 1 基帧号：
/// `floor(t * 30) + 1`。
abstract class VideoClipPlayback extends ChangeNotifier {
  /// 动效合成的帧号口径（与矢量动画的可调帧率无关）。
  static const int clipFps = 30;

  /// 当前时刻（秒）。
  double get t;

  /// 片长（秒）；页面 `ready` 之前退回清单里的声明值。
  double get duration;

  bool get playing;

  bool get loop;

  /// 页面是否已经真的跑起来（收到 `ready`）。
  bool get ready;

  /// 人话错误；空串 = 正常。
  String get loadError;

  int get fps => clipFps;

  /// 1 基帧号（0 秒 = 第 1 帧）。
  int get frame {
    final value = (t * fps).floor() + 1;
    return value < 1 ? 1 : value;
  }

  Future<void> play();
  Future<void> pause();
  Future<void> seek(double seconds);
  Future<void> restart();
  Future<void> setLoop(bool value);
}

/// WebView 实现：创建控制器、挂桥、内联引擎、加载临时文件。
class VideoClipWebPlayback extends VideoClipPlayback {
  VideoClipWebPlayback({required this.clip, this.initialTime});

  /// 正在播放的短片（清单条目）。
  final VideoClipInfo clip;

  /// 逐帧审查：非 null 时按 `?t=` 加载，只画该帧、不自动播放。
  final double? initialTime;

  WebViewController? _controller;
  Timer? _readyTimer;
  bool _disposed = false;
  bool _ready = false;
  bool _playing = false;
  bool _loop = true;
  bool _attachStarted = false;
  double _t = 0;
  late double _duration = clip.duration;
  String _loadError = '';

  /// 页面就绪超时：1.5s 没有 `ready` 就按「没启动」处理（可重试）。
  static const Duration readyTimeout = Duration(milliseconds: 1500);

  final Stopwatch _notifyClock = Stopwatch()..start();

  WebViewController? get controller => _controller;

  @override
  double get t => _t;

  @override
  double get duration => _duration > 0 ? _duration : clip.duration;

  @override
  bool get playing => _playing;

  @override
  bool get loop => _loop;

  @override
  bool get ready => _ready;

  @override
  String get loadError => _loadError;

  /// 准备并加载页面；失败只落到 [loadError]，不抛异常。
  Future<void> attach() async {
    if (_disposed || _attachStarted) return;
    _attachStarted = true;

    _loadError = '';
    _ready = false;
    _playing = false;
    _t = 0;

    try {
      final css = await rootBundle.loadString(videoClipEngineCssAsset);
      final js = await rootBundle.loadString(videoClipEngineJsAsset);
      final clipHtml = await rootBundle.loadString('$videoClipAssetDir${clip.file}');
      if (_disposed) return;

      final html = assembleVideoClipHtml(
        engineCss: css,
        engineJs: js,
        clipHtml: clipHtml,
      );
      final path = await _writeHtmlFile(html);
      if (_disposed) return;

      _ensureWebViewPlatform();
      final controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..addJavaScriptChannel(videoClipBridgeChannel, onMessageReceived: _onMessage)
        ..setNavigationDelegate(NavigationDelegate(
          onWebResourceError: (error) {
            // 子资源失败不整块替换；主帧失败才是「页面打不开」。
            if (error.isForMainFrame == false) return;
            _fail('动效合成没有启动，可重试');
          },
        ));
      _controller = controller;
      notifyListeners();
      // 就绪超时从「页面开始加载」算起：资源读取慢不算页面没启动。
      _armReadyTimer();

      final uri = Uri.file(path);
      if (initialTime != null) {
        await controller.loadRequest(
          uri.replace(queryParameters: <String, String>{
            't': '${initialTime!}',
          }),
        );
      } else {
        await controller.loadFile(path);
      }
    } catch (_) {
      _fail('动效合成没有启动，可重试');
    }
  }

  /// 失败后的重试：换一个新控制器重新加载（旧页可能卡在半初始化）。
  Future<void> retry() async {
    if (_disposed) return;
    _readyTimer?.cancel();
    _controller = null;
    _attachStarted = false;
    _loadError = '';
    notifyListeners();
    await attach();
  }

  // ---------------------------------------------------------------- 命令

  @override
  Future<void> play() async {
    if (!_ready) return;
    _playing = true;
    notifyListeners();
    await _run('window.__ndClip && window.__ndClip.play()');
  }

  @override
  Future<void> pause() async {
    if (!_ready) return;
    _playing = false;
    notifyListeners();
    await _run('window.__ndClip && window.__ndClip.pause()');
  }

  @override
  Future<void> seek(double seconds) async {
    if (!_ready) return;
    final total = duration;
    _t = seconds.isFinite ? seconds.clamp(0.0, total > 0 ? total : 0.0) : 0;
    notifyListeners();
    await _run('window.__ndClip && window.__ndClip.seek(${_t.toStringAsFixed(3)})');
  }

  @override
  Future<void> restart() async {
    if (!_ready) return;
    _t = 0;
    _playing = true;
    notifyListeners();
    await _run('window.__ndClip && window.__ndClip.restart()');
  }

  @override
  Future<void> setLoop(bool value) async {
    if (!_ready) return;
    _loop = value;
    notifyListeners();
    await _run('window.__ndClip && window.__ndClip.setLoop($value)');
  }

  Future<void> _run(String script) async {
    final controller = _controller;
    if (controller == null) return;
    try {
      await controller.runJavaScript(script);
    } catch (_) {
      // 桥调用是尽力而为：页面还没挂好时静默，下一帧状态会自愈。
    }
  }

  // ---------------------------------------------------------------- 桥

  void _onMessage(JavaScriptMessage message) {
    if (_disposed) return;
    Object? decoded;
    try {
      decoded = jsonDecode(message.message);
    } catch (_) {
      return;
    }
    if (decoded is! Map) return;
    final kind = decoded['type'];
    if (kind == 'ready') {
      _readyTimer?.cancel();
      _duration = _readSeconds(decoded['duration']) ?? duration;
      _t = 0;
      _ready = true;
      // 超时误判后页面又活过来：清掉「没启动」错误，别让画面对着错误面板。
      _loadError = '';
      _notify(force: true);
    } else if (kind == 'state') {
      final nextT = _readSeconds(decoded['t']);
      final nextDuration = _readSeconds(decoded['duration']);
      if (nextDuration != null && nextDuration > 0) _duration = nextDuration;
      if (nextT != null) {
        final total = duration;
        _t = nextT.clamp(0.0, total > 0 ? total : nextT);
      }
      _playing = decoded['playing'] == true;
      _loop = decoded['loop'] != false;
      _notify();
    }
  }

  void _notify({bool force = false}) {
    if (_disposed) return;
    // 页面每帧一条 state：30Hz 节流就够界面读数跟手，不必 60 次/秒重建。
    if (!force && _notifyClock.elapsedMilliseconds < 33) return;
    _notifyClock
      ..reset()
      ..start();
    notifyListeners();
  }

  void _armReadyTimer() {
    _readyTimer?.cancel();
    _readyTimer = Timer(readyTimeout, () {
      if (_disposed || _ready) return;
      _fail('动效合成没有启动，可重试');
    });
  }

  void _fail(String message) {
    if (_disposed) return;
    _readyTimer?.cancel();
    _ready = false;
    _playing = false;
    _loadError = message;
    notifyListeners();
  }

  // ---------------------------------------------------------------- 落盘

  /// 单文件页面写到本机临时目录，按 `file://` 加载。
  ///
  /// 不走 `loadHtmlString`：macOS WKWebView 下 `file://` 的读取权限按文件父
  /// 目录授予，临时文件最稳；同时 `?t=` 逐帧审查也能通过 URL query 传进去。
  Future<String> _writeHtmlFile(String html) async {
    final dir = Directory('${Directory.systemTemp.path}/nondesign-video-clip');
    if (!await dir.exists()) await dir.create(recursive: true);
    final safeId = clip.id.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final file = File('${dir.path}/$safeId.html');
    await file.writeAsString(html, flush: true);
    return file.path;
  }

  void _ensureWebViewPlatform() {
    // webview_flutter 无 endorsed macOS 实现：首次使用前幂等注册 WebKit。
    // 守卫同时看 instance——测试注入 fake 平台后不得被真注册覆盖。
    if ((Platform.isMacOS || Platform.isIOS) && WebViewPlatform.instance == null) {
      WebKitWebViewPlatform.registerWith();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _readyTimer?.cancel();
    _readyTimer = null;
    _controller = null;
    super.dispose();
  }
}

double? _readSeconds(Object? raw) {
  if (raw is! num) return null;
  final value = raw.toDouble();
  return value.isFinite ? value : null;
}

/// 动效合成播放面：16:9 居中、圆角、留边由外层负责。
class VideoClipSurface extends StatefulWidget {
  const VideoClipSurface({
    super.key,
    required this.clip,
    this.host,
    this.playback,
    this.initialTime,
    this.onPlaybackChanged,
  });

  /// 要播放的短片。
  final VideoClipInfo clip;

  /// 平台矩阵；缺省取 [PlatformCapabilities.current]。测试可显式注入。
  final PlatformCapabilities? host;

  /// 测试注入的播放源（也用于宿主自行托管的播放源）。
  ///
  /// 传了就不构造 WebView、不负责 dispose（生命周期归注入方）。
  final VideoClipPlayback? playback;

  /// 逐帧审查起点（秒）；非 null 时页面按 `?t=` 加载且不自动播放。
  final double? initialTime;

  /// 本播放面自己创建 WebView 播放源后回调一次（工作台用它接运输条）。
  final ValueChanged<VideoClipPlayback?>? onPlaybackChanged;

  @override
  State<VideoClipSurface> createState() => _VideoClipSurfaceState();
}

class _VideoClipSurfaceState extends State<VideoClipSurface> {
  VideoClipPlayback? _playback;
  VideoClipWebPlayback? _owned;

  @override
  void initState() {
    super.initState();
    final injected = widget.playback;
    if (injected != null) {
      _playback = injected;
      return;
    }
    if (!videoClipWebViewSupported(widget.host)) return;

    final owned = VideoClipWebPlayback(
      clip: widget.clip,
      initialTime: widget.initialTime,
    );
    _owned = owned;
    _playback = owned;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onPlaybackChanged?.call(owned);
      owned.attach();
    });
  }

  @override
  void dispose() {
    // 只释放自己创建的播放源；注入的归注入方。
    _owned?.dispose();
    _owned = null;
    _playback = null;
    super.dispose();
  }

  void _retry() {
    final owned = _owned;
    if (owned != null) {
      owned.retry();
      return;
    }
    // 注入的 Fake 没有重试语义：交给注入方重建实例。
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Container(
            key: const ValueKey('video-clip-surface'),
            decoration: BoxDecoration(
              color: const Color(0xFF0B0D12),
              border: Border.all(color: context.palette.line),
              borderRadius: BorderRadius.circular(10),
            ),
            clipBehavior: Clip.antiAlias,
            child: _stage(context),
          ),
        ),
      ),
    );
  }

  Widget _stage(BuildContext context) {
    final playback = _playback;
    if (playback == null) return _unsupported(context);

    return ListenableBuilder(
      listenable: playback,
      builder: (context, _) {
        final error = playback.loadError;
        if (error.isNotEmpty) return _errorPane(context, error);

        final owned = _owned;
        if (owned == null) {
          // 注入的播放源（测试/外托管）：只占住 16:9 的画位，不构造 WebView。
          return const ColoredBox(
            key: ValueKey('video-clip-stage'),
            color: Color(0xFF0B0D12),
          );
        }

        final controller = owned.controller;
        if (!playback.ready || controller == null) return _loading(context);
        return Container(
          key: const ValueKey('video-clip-stage'),
          color: const Color(0xFF0B0D12),
          child: WebViewWidget(controller: controller),
        );
      },
    );
  }

  Widget _loading(BuildContext context) {
    final p = context.palette;
    return Container(
      key: const ValueKey('video-clip-loading'),
      alignment: Alignment.center,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2, color: p.accent),
        ),
        const SizedBox(height: 10),
        Text('动效合成准备中…', style: TextStyle(fontSize: 11, color: p.ink3)),
      ]),
    );
  }

  Widget _errorPane(BuildContext context, String message) {
    final p = context.palette;
    return Container(
      key: const ValueKey('video-clip-error'),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(20),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.movie_outlined, size: 34, color: p.ink4),
        const SizedBox(height: 10),
        Text(
          message,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: p.ink2, height: 1.5),
        ),
        const SizedBox(height: 10),
        TextButton.icon(
          key: const ValueKey('video-clip-retry'),
          onPressed: _retry,
          style: TextButton.styleFrom(
            minimumSize: const Size(0, 30),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            padding: const EdgeInsets.symmetric(horizontal: 10),
          ),
          icon: const Icon(Icons.refresh, size: 15),
          label: const Text('重试', style: TextStyle(fontSize: 11)),
        ),
      ]),
    );
  }

  Widget _unsupported(BuildContext context) {
    final p = context.palette;
    return Container(
      key: const ValueKey('video-clip-unsupported'),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(20),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.movie_outlined, size: 34, color: p.ink4),
        const SizedBox(height: 10),
        Text(
          '这台设备不能内嵌播放动效合成',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: p.ink2),
        ),
        const SizedBox(height: 6),
        Text(
          '用电脑上的连接桌面查看',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 11, color: p.ink4, height: 1.5),
        ),
      ]),
    );
  }
}

/// 运输条：播放/暂停、可拖动进度、时间/时长、帧号、循环开关。
///
/// 只读 [VideoClipPlayback]，因此 Fake 播放源就能完整测试它，不需要 WebView。
class VideoClipTransport extends StatelessWidget {
  const VideoClipTransport({super.key, required this.playback, this.padding});

  final VideoClipPlayback playback;

  /// 外层留边（工作台按主区边距传入；单测默认 0）。
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: padding ?? EdgeInsets.zero,
      child: Container(
        key: const ValueKey('video-clip-transport'),
        padding: const EdgeInsets.fromLTRB(8, 2, 8, 6),
        decoration: BoxDecoration(
          color: p.panel2,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: p.line),
        ),
        child: ListenableBuilder(
          listenable: playback,
          builder: (context, _) {
            final total = playback.duration > 0 ? playback.duration : 0.001;
            final value = playback.t.isFinite
                ? playback.t.clamp(0.0, total).toDouble()
                : 0.0;
            return Column(mainAxisSize: MainAxisSize.min, children: [
              SizedBox(
                height: 22,
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 2,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
                  ),
                  child: Slider(
                    key: const ValueKey('video-clip-slider'),
                    value: value,
                    max: total,
                    activeColor: p.accent,
                    onChanged: (v) => playback.seek(v),
                  ),
                ),
              ),
              Row(children: [
                IconButton(
                  key: const ValueKey('video-clip-play'),
                  tooltip: playback.playing ? '暂停' : '播放',
                  onPressed: playback.playing ? playback.pause : playback.play,
                  icon: Icon(
                    playback.playing ? Icons.pause : Icons.play_arrow,
                    size: 20,
                    color: p.ink2,
                  ),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    '${formatVideoTime(playback.t)} / ${formatVideoTime(playback.duration)}',
                    key: const ValueKey('video-clip-time'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10, color: p.ink3, fontFeatures: const [
                      FontFeature.tabularFigures(),
                    ]),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '帧 ${playback.frame}',
                  key: const ValueKey('video-clip-frame'),
                  maxLines: 1,
                  style: TextStyle(fontSize: 10, color: p.ink3),
                ),
                IconButton(
                  key: const ValueKey('video-clip-loop'),
                  tooltip: '循环播放',
                  onPressed: () => playback.setLoop(!playback.loop),
                  icon: Icon(
                    Icons.repeat,
                    size: 17,
                    color: playback.loop ? p.accent : p.ink4,
                  ),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                ),
              ]),
            ]);
          },
        ),
      ),
    );
  }
}
