/// 音乐演奏面：把 [assembleMusicPlayer] 组装出的自包含播放页接进工作台
/// （**只读播放**，不改 `score.json` 事实源）。
///
/// 纪律与项目内其它 WebView（3D 预览 / 热应用 / 视频播放面）一致：
///
///  * 所有应用内 WebView 统一走 `webview_all`；平台判定只认
///    [PlatformCapabilities.supportsInAppWebView]，不在 widget 里写死
///    `Platform.isX` 分叉。
///  * 页面经 `loadHtmlString` 直接注入（与离屏引擎宿主同一路径：不落临时
///    文件、不读本地资源、零外联；播放页自带固定 CSP）。
///  * 出站桥只接 `window.NONMUSIC` 的 `beat / ended / error` 三类消息
///    （与 `window.NON3D` 同模式：JavaScriptChannel + JSON 解析）。
///  * 命令面走页面自身 API `window.NONMUSIC_PLAYER.play() / pause() /
///    stop() / seek(sec)`（见 `core/music/music_player.dart` 的宿主接口）。
///  * `loadHtmlString` 的 Future 只代表平台收下请求，**不等于页面脚本跑起来**：
///    就绪判据是 `window.NONMUSIC_PLAYER` 真的出现（轮询 `typeof`），超时/异常
///    一律落 [MusicPlaybackController.loadError]——显性降级，绝不假装播放成功。
///  * 主帧加载失败才降级；子资源失败不整块替换（与 3D/热应用同纪律）。
///  * 人话主文案之外，原始诊断只放进折叠的「技术详情」。
///
/// 为测试提供可注入抽象 [MusicPlaybackController]：工作台可注入 Fake，
/// 走完整播放控制/错误面，而**不构造真 WebView**。生产实现是
/// [MusicWebPlayback]（自建控制器 + 桥 + 轮询就绪）；Fake 只需实现状态与
/// 命令面。
library;

import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:webview_all/webview_all.dart';
import 'package:webview_all_wkwebview/webview_all_wkwebview.dart';

import '../core/music/music_compile.dart';
import '../core/music/music_player.dart';
import '../core/music/music_score.dart';
import '../core/platform_capabilities.dart';
import '../core/theme.dart';

/// 页面桥通道名（`music_player.dart` 的页面侧固定写死这个字符串，改它等于改契约）。
const String musicPlaybackBridgeChannel = 'NONMUSIC';

/// 页面宿主命令面（`music_player.dart` 页面侧的 `window.NONMUSIC_PLAYER`）。
const String musicPlaybackHostObject = 'window.NONMUSIC_PLAYER';

/// 播放页就绪等待上限：内联单文件页面很小，2s 足够；超时按「没启动」处理。
const Duration musicPlaybackReadyTimeout = Duration(seconds: 2);

/// 就绪轮询间隔（与离屏引擎宿主的 25ms 轮询同族，播放页略放宽）。
const Duration musicPlaybackReadyPollInterval = Duration(milliseconds: 40);

/// 播放中播放头的刷新周期（页面自己 25ms 一个调度节拍；工作台 4Hz 足够跟手）。
const Duration musicPlaybackPositionPollInterval = Duration(milliseconds: 250);

/// 测试注入：WebView 平台矩阵的确定性覆盖（同 `debugVideoClipWebViewSupported`）。
///
/// 测试机造不出「没有应用内 WebView」的真实环境；置 false 即走显性降级分支。
/// 生产路径始终读 [PlatformCapabilities.supportsInAppWebView]。
@visibleForTesting
bool? debugMusicPlaybackWebViewSupported;

/// 这台主机能否在应用内播演奏页。
bool musicPlaybackWebViewSupported([PlatformCapabilities? host]) =>
    debugMusicPlaybackWebViewSupported ??
    (host ?? PlatformCapabilities.current()).supportsInAppWebView;

/// 播放计划的总时长（秒）：与播放页 `tickToSec` 同一口径（分段常数 BPM）。
///
/// 页面本身只在 `beat / ended` 桥消息里回报位置；工作台需要在页面就绪前就
/// 画出「总时长 / 进度」——这里用同一份整数 tick 计划派生，避免第二套时间源。
double musicPlaybackDurationSeconds(MusicPlayPlan plan) {
  final int ppq = plan.ppq > 0 ? plan.ppq : MusicPlayPlan.defaultPpq;
  final int totalTicks = plan.totalTicks;
  if (totalTicks <= 0) return 0;
  final List<(int, double)> tempo = <(int, double)>[];
  for (final Map<String, int> entry in plan.tempoMap) {
    final int tick = (entry['tick'] ?? 0) < 0 ? 0 : (entry['tick'] ?? 0);
    final int bpm = (entry['bpm'] ?? 0).clamp(20, 300);
    tempo.add((tick, bpm.toDouble()));
  }
  if (tempo.isEmpty) return 0;
  tempo.sort((a, b) => a.$1.compareTo(b.$1));
  double seconds = 0;
  int lastTick = 0;
  double currentBpm = tempo.first.$2;
  for (final (int tick, double bpm) in tempo) {
    if (tick <= 0) {
      currentBpm = bpm;
      continue;
    }
    if (tick >= totalTicks) break;
    seconds += _ticksToSeconds(tick - lastTick, currentBpm, ppq);
    lastTick = tick;
    currentBpm = bpm;
  }
  return seconds + _ticksToSeconds(totalTicks - lastTick, currentBpm, ppq);
}

double _ticksToSeconds(int ticks, double bpm, int ppq) =>
    ticks * 60.0 / (bpm * ppq);

/// 播放头时间文案（`m:ss`，与播放页 `formatTime` 同一口径）。
String formatMusicPlaybackTime(double seconds) {
  final int total = seconds.isFinite && seconds > 0 ? seconds.round() : 0;
  final int minutes = total ~/ 60;
  final int rest = total % 60;
  return '$minutes:${rest.toString().padLeft(2, '0')}';
}

/// 播放面状态源：工作台运输条只读这份状态 / 命令面。
///
/// 生产实现是 [MusicWebPlayback]（WebView + 桥）；测试注入 Fake 即可覆盖
/// 播放/暂停/停止/seek 与错误面，**不需要构造真 WebView**。
abstract class MusicPlaybackController extends ChangeNotifier {
  /// 播放页是否已经真的跑起来（能接受命令）；Fake 由测试决定。
  bool get ready;

  /// 是否正在播放（页面 `beat` 到达 / 命令被接受后为 true）。
  bool get playing;

  /// 播放头（秒）。
  double get position;

  /// 总时长（秒）；页面 `ended` 回报优先，之前用整数 tick 计划派生。
  double get duration;

  /// 最近一次回传的 0 基拍号；-1 = 还没收到 `beat`。
  int get beat;

  /// 最近一次回传的小节号（1 基）；0 = 还没收到 `beat`。
  int get bar;

  /// 人话错误；空串 = 正常。原始诊断在 [technicalDetail]。
  String get loadError;

  /// 原始诊断：只进折叠的「技术详情」，绝不作为主文案。
  String get technicalDetail;

  /// 挂载/启动播放面（WebView 实现创建控制器并载入页面；Fake 直接就绪）。
  Future<void> start();

  Future<void> play();

  Future<void> pause();

  Future<void> stop();

  Future<void> seek(double seconds);
}

/// 生产实现：`webview_all` 控制器 + `NONMUSIC` 桥 + 就绪轮询。
class MusicWebPlayback extends MusicPlaybackController {
  MusicWebPlayback({
    required this.score,
    required this.plan,
    this.host,
    this.readyTimeout = musicPlaybackReadyTimeout,
  }) : _duration = musicPlaybackDurationSeconds(plan);

  final MusicScore score;
  final MusicPlayPlan plan;

  /// 平台矩阵；缺省取 [PlatformCapabilities.current]（唯一平台事实源）。
  final PlatformCapabilities? host;

  /// 就绪等待上限（测试可压短）。
  final Duration readyTimeout;

  WebViewController? _controller;
  bool _started = false;
  bool _disposed = false;
  bool _ready = false;
  bool _playing = false;
  double _position = 0;
  double _duration;
  int _beat = -1;
  int _bar = 0;
  String _loadError = '';
  String _technicalDetail = '';
  Timer? _positionTimer;
  Future<void>? _startFuture;

  /// 正在显示的 WebView 控制器（播放面 widget 用它挂 [WebViewWidget]）。
  WebViewController? get controller => _controller;

  /// 已组装的播放页 HTML（测试断言用；同一 score+plan 字节确定）。
  @visibleForTesting
  String get html => assembleMusicPlayer(score, plan);

  PlatformCapabilities get _capabilities =>
      host ?? PlatformCapabilities.current();

  bool get _usesWebKit {
    final HostOs os = _capabilities.os;
    return os == HostOs.macos || os == HostOs.ios;
  }

  @override
  bool get ready => !_disposed && _ready;

  @override
  bool get playing => !_disposed && _playing;

  @override
  double get position => _position;

  @override
  double get duration => _duration;

  @override
  int get beat => _beat;

  @override
  int get bar => _bar;

  @override
  String get loadError => _loadError;

  @override
  String get technicalDetail => _technicalDetail;

  // -------------------------------------------------------------- 启动 / 降级

  @override
  Future<void> start() {
    final Future<void>? existing = _startFuture;
    if (existing != null) return existing;
    final Future<void> future = _start();
    _startFuture = future;
    return future;
  }

  Future<void> _start() async {
    if (_disposed) return;
    _started = true;
    // 不在这里「兜底注册」真实 WKWebView 平台：widget 测试没有平台通道，
    // 注册后构造真控制器只会把测试变成 MissingPluginException。生产由插件
    // 注册表自动就绪；没就绪就如实降级（同族的 video_clip_surface 也只在
    // 支持时才构造）。
    if (!musicPlaybackWebViewSupported(host)) {
      _fail('这台设备暂时不能内嵌播放音乐', '当前环境没有应用内 WebView');
      return;
    }
    final WebViewPlatform? platform = WebViewPlatform.instance;
    if (platform == null) {
      _fail('这台设备暂时不能内嵌播放音乐', '应用内 WebView 平台还没有就绪');
      return;
    }
    try {
      final String html = assembleMusicPlayer(score, plan);
      final WebViewController controller = _createController();
      _controller = controller;
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      if (_disposed) return;
      await controller.addJavaScriptChannel(
        musicPlaybackBridgeChannel,
        onMessageReceived: _onBridgeMessage,
      );
      if (_disposed) return;
      await controller.setNavigationDelegate(
        NavigationDelegate(
          // 主帧失败才是「页面打不开」；子资源失败不整块替换页面。
          onWebResourceError: (WebResourceError error) {
            if (_disposed || error.isForMainFrame == false) return;
            _fail(
              '演奏页没有加载出来，可以重试',
              '${error.description} (${error.errorCode})',
            );
          },
        ),
      );
      if (_disposed) return;
      // 内联单文件页面：零外联，不读任何本地文件。loadHtmlString 的 Future
      // 只代表平台收下请求，页面脚本是否跑起来由下面的 typeof 轮询判定。
      await controller.loadHtmlString(html);
      await _waitUntilPlayerReady();
      if (_disposed) return;
      _ready = true;
      _loadError = '';
      _technicalDetail = '';
      notifyListeners();
    } catch (error) {
      _fail('演奏页没有启动起来，可以重试', '$error');
    }
  }

  WebViewController _createController() {
    // AudioContext 需要用户手势才出声：宿主经 runJavaScript 发播放命令不是
    // WebView 内手势，因此显式放开媒体播放策略（与 video_player_surface
    // 同纪律）；真正的 WebAudio 手势解锁在桌面/Android 由该策略覆盖，
    // iOS 上仍可能需要用户点一下演奏页里的播放按钮（见「已知风险」）。
    PlatformWebViewControllerCreationParams params =
        PlatformWebViewControllerCreationParams(
          mediaPlaybackPolicy:
              WebViewMediaPlaybackPolicy.allowWithoutUserGesture,
        );
    if (_usesWebKit) {
      params = WebKitWebViewControllerCreationParams(
        mediaPlaybackPolicy: WebViewMediaPlaybackPolicy.allowWithoutUserGesture,
        mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
        allowsInlineMediaPlayback: true,
      );
    }
    return WebViewController.fromPlatformCreationParams(params);
  }

  Future<void> _waitUntilPlayerReady() async {
    final DateTime deadline = DateTime.now().add(readyTimeout);
    while (DateTime.now().isBefore(deadline)) {
      if (_disposed) return;
      try {
        final Object? value = await _evalRaw('typeof $musicPlaybackHostObject');
        if (value == 'object' || value == 'function') return;
      } catch (_) {
        // 页面还在解析脚本时调用 JS 会失败：继续轮询（超时前不算失败）。
      }
      await Future<void>.delayed(musicPlaybackReadyPollInterval);
    }
    throw StateError('播放页脚本没有在限定时间内就绪');
  }

  void _fail(String message, [String detail = '']) {
    if (_disposed) return;
    _ready = false;
    _playing = false;
    _positionTimer?.cancel();
    _positionTimer = null;
    _loadError = message;
    _technicalDetail = detail;
    notifyListeners();
  }

  /// 失败后的重试：换一个新控制器重新加载（旧页可能卡在半初始化）。
  Future<void> retry() async {
    if (_disposed) return;
    _positionTimer?.cancel();
    _positionTimer = null;
    _started = false;
    _startFuture = null;
    _ready = false;
    _playing = false;
    _position = 0;
    _beat = -1;
    _bar = 0;
    _loadError = '';
    _technicalDetail = '';
    _controller = null;
    notifyListeners();
    await start();
  }

  // -------------------------------------------------------------- 命令面

  @override
  Future<void> play() async {
    if (!ready) return;
    final bool sent = await _run(
      '$musicPlaybackHostObject && $musicPlaybackHostObject.play && '
      '$musicPlaybackHostObject.play()',
    );
    if (!sent || _disposed) return;
    _playing = true;
    _loadError = '';
    _technicalDetail = '';
    _startPositionTimer();
    notifyListeners();
  }

  @override
  Future<void> pause() async {
    if (!ready) return;
    _positionTimer?.cancel();
    _positionTimer = null;
    await _run(
      '$musicPlaybackHostObject && $musicPlaybackHostObject.pause && '
      '$musicPlaybackHostObject.pause()',
    );
    if (_disposed) return;
    _playing = false;
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    if (!ready) return;
    _positionTimer?.cancel();
    _positionTimer = null;
    await _run(
      '$musicPlaybackHostObject && $musicPlaybackHostObject.stop && '
      '$musicPlaybackHostObject.stop()',
    );
    if (_disposed) return;
    _playing = false;
    _position = 0;
    _beat = -1;
    _bar = 0;
    notifyListeners();
  }

  @override
  Future<void> seek(double seconds) async {
    if (!ready) return;
    final double total = duration > 0 ? duration : 0;
    final double target = seconds.isFinite
        ? seconds.clamp(0.0, total).toDouble()
        : 0.0;
    final bool sent = await _run(
      '$musicPlaybackHostObject && $musicPlaybackHostObject.seek && '
      '$musicPlaybackHostObject.seek(${target.toStringAsFixed(3)})',
    );
    if (!sent || _disposed) return;
    _position = target;
    notifyListeners();
  }

  Future<bool> _run(String script) async {
    final WebViewController? controller = _controller;
    if (controller == null) return false;
    try {
      await controller.runJavaScript(script);
      return true;
    } catch (error) {
      if (!_disposed) {
        _playing = false;
        _positionTimer?.cancel();
        _positionTimer = null;
        _loadError = '播放命令没有送到演奏页，可以重试';
        _technicalDetail = '$error';
        notifyListeners();
      }
      return false;
    }
  }

  void _startPositionTimer() {
    _positionTimer?.cancel();
    _positionTimer = Timer.periodic(musicPlaybackPositionPollInterval, (_) {
      unawaited(_syncPosition());
    });
  }

  /// 播放中按 4Hz 读页面播放头（页面自己 25ms 调度，工作台的进度条因此
  /// 不会只在 `beat` 消息（最慢 3s 一拍）时才跳一格）。
  Future<void> _syncPosition() async {
    if (!_ready || !_playing || _disposed) {
      _positionTimer?.cancel();
      _positionTimer = null;
      return;
    }
    try {
      final Object? raw = await _evalRaw('$musicPlaybackHostObject.position()');
      final double? seconds = _readSeconds(raw);
      if (seconds == null || _disposed || !_playing) return;
      final double total = _duration;
      _position = total > 0 ? seconds.clamp(0.0, total).toDouble() : seconds;
      notifyListeners();
    } catch (_) {
      // 页面正在切状态时读位置失败是暂时的；下个节拍会自愈。
    }
  }

  // -------------------------------------------------------------- 桥消息

  void _onBridgeMessage(JavaScriptMessage message) {
    if (_disposed) return;
    Object? decoded;
    try {
      decoded = jsonDecode(message.message);
    } catch (_) {
      return;
    }
    if (decoded is! Map) return;
    final String kind = '${decoded['kind'] ?? ''}';
    switch (kind) {
      case 'beat':
        final double? position = _readSeconds(decoded['position']);
        final double? total = _readSeconds(decoded['total']);
        if (total != null && total > 0) _duration = total;
        if (position != null) {
          _position = _duration > 0
              ? position.clamp(0.0, _duration).toDouble()
              : position;
        }
        _beat = _readInt(decoded['beat']) ?? _beat;
        _bar = _readInt(decoded['bar']) ?? _bar;
        _playing = true;
        _loadError = '';
        _technicalDetail = '';
        notifyListeners();
      case 'ended':
        final double? total = _readSeconds(decoded['total']);
        if (total != null && total > 0) _duration = total;
        _positionTimer?.cancel();
        _positionTimer = null;
        _playing = false;
        _position = 0;
        _beat = -1;
        _bar = 0;
        notifyListeners();
      case 'error':
        final String raw = '${decoded['message'] ?? ''}';
        _positionTimer?.cancel();
        _positionTimer = null;
        _playing = false;
        _loadError = _humanPlaybackError(raw);
        _technicalDetail = raw.isEmpty ? '页面报告了未知错误' : raw;
        notifyListeners();
      default:
        return;
    }
  }

  /// 页面原始错误 → 人话（原始文本仍进 [technicalDetail]）。
  String _humanPlaybackError(String raw) {
    if (raw.contains('没有可播放的内容')) return '乐谱里还没有可播放的音符';
    if (raw.contains('音频')) return '这台设备暂时放不出声音，可以重试或换个设备';
    if (raw.contains('初始化失败')) return '演奏页没有准备好，可以重试';
    if (raw.contains('调度失败')) return '播放中断了，可以再试一次';
    return '播放出错了，请再试一次';
  }

  // -------------------------------------------------------------- 内部工具

  Future<Object?> _evalRaw(String script) async {
    final WebViewController? controller = _controller;
    if (controller == null) throw StateError('演奏页还没有创建');
    final Object result = await controller.runJavaScriptReturningResult(script);
    // 有些平台把字符串结果再包一层 JSON 引号（同引擎宿主 `_evalRaw` 口径）。
    if (result is String &&
        result.length >= 2 &&
        result.startsWith('"') &&
        result.endsWith('"')) {
      try {
        final Object? decoded = jsonDecode(result);
        if (decoded is String) return decoded;
      } catch (_) {
        // 不是双编码字符串：原样返回。
      }
    }
    return result;
  }

  static double? _readSeconds(Object? raw) {
    if (raw is num) {
      final double value = raw.toDouble();
      return value.isFinite ? value : null;
    }
    if (raw is String) {
      final double? parsed = double.tryParse(raw);
      if (parsed != null && parsed.isFinite) return parsed;
    }
    return null;
  }

  static int? _readInt(Object? raw) {
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw);
    return null;
  }

  @override
  void dispose() {
    _disposed = true;
    _positionTimer?.cancel();
    _positionTimer = null;
    _controller = null;
    super.dispose();
  }

  /// 是否已经尝试过启动（调试/测试只读）。
  @visibleForTesting
  bool get started => _started;
}

/// 生产播放面控制器工厂（工作台默认注入；测试可换成 Fake）。
MusicPlaybackController createDefaultMusicPlayback(
  MusicScore score,
  MusicPlayPlan plan, {
  PlatformCapabilities? host,
}) => MusicWebPlayback(score: score, plan: plan, host: host);

/// 演奏面 widget：只显示 WebView 舞台 + 就绪/错误占位，运输条在工作台底部。
///
/// 播放头与错误经 [MusicPlaybackController]（[ChangeNotifier]）回调给工作台，
/// 这里不另造第二套回调通道。
class MusicPlaybackSurface extends StatefulWidget {
  const MusicPlaybackSurface({super.key, required this.playback});

  /// 播放控制器（生产 = [MusicWebPlayback]；测试可注入 Fake，不构造 WebView）。
  final MusicPlaybackController playback;

  @override
  State<MusicPlaybackSurface> createState() => _MusicPlaybackSurfaceState();
}

class _MusicPlaybackSurfaceState extends State<MusicPlaybackSurface> {
  Future<void> _retry() async {
    final MusicPlaybackController playback = widget.playback;
    if (playback is MusicWebPlayback) await playback.retry();
  }

  @override
  Widget build(BuildContext context) {
    final NonPalette p = context.palette;
    return Container(
      key: const ValueKey('music-playback-surface'),
      decoration: BoxDecoration(
        color: p.panel2,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: p.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: ListenableBuilder(
        listenable: widget.playback,
        builder: (BuildContext context, Widget? _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _header(context, p),
            Divider(height: 1, color: p.line),
            Expanded(child: _stage(context)),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context, NonPalette p) {
    final MusicPlaybackController playback = widget.playback;
    final bool ready = playback.ready;
    final bool failed = playback.loadError.isNotEmpty;
    final String status = failed
        ? '不可用'
        : ready
        ? (playback.playing ? '播放中' : '可以播放')
        : '准备中';
    final Color statusColor = failed
        ? p.warn
        : ready
        ? (playback.playing ? p.accent : p.ink3)
        : p.ink4;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
      child: Row(
        children: <Widget>[
          Icon(Icons.music_note_outlined, size: 13, color: p.ink4),
          const SizedBox(width: 6),
          Text(
            '演奏页',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: p.ink,
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              '只读播放，不影响乐谱内容',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10, color: p.ink4),
            ),
          ),
          const Spacer(),
          Text(
            status,
            key: const ValueKey('music-playback-status'),
            style: TextStyle(fontSize: 10, color: statusColor),
          ),
        ],
      ),
    );
  }

  Widget _stage(BuildContext context) {
    final MusicPlaybackController playback = widget.playback;
    // 错误面先判：Fake 注入也要能测「错误回调 → 人话 + 技术详情」。
    final String error = playback.loadError;
    if (error.isNotEmpty) return _errorPane(context, playback, error);
    // 注入的 Fake（测试/外部托管）：只占住画位，不构造 WebView。
    if (playback is! MusicWebPlayback) {
      return const ColoredBox(
        key: ValueKey('music-playback-stage'),
        color: Color(0xFF0B0D12),
      );
    }
    final WebViewController? controller = playback.controller;
    if (!playback.ready || controller == null) return _loadingPane(context);
    return Container(
      key: const ValueKey('music-playback-stage'),
      color: const Color(0xFF0B0D12),
      child: WebViewWidget(controller: controller),
    );
  }

  Widget _loadingPane(BuildContext context) {
    final NonPalette p = context.palette;
    return Center(
      key: const ValueKey('music-playback-loading'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2, color: p.accent),
          ),
          const SizedBox(height: 10),
          Text('演奏页准备中…', style: TextStyle(fontSize: 11, color: p.ink3)),
        ],
      ),
    );
  }

  Widget _errorPane(
    BuildContext context,
    MusicPlaybackController playback,
    String message,
  ) {
    final NonPalette p = context.palette;
    return Center(
      key: const ValueKey('music-playback-error'),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.music_off_outlined, size: 30, color: p.ink4),
            const SizedBox(height: 10),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: p.ink2,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '乐谱和播放计划都还在，可以继续看谱面；修好后重试。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: p.ink4, height: 1.5),
            ),
            const SizedBox(height: 10),
            if (playback is MusicWebPlayback)
              TextButton.icon(
                key: const ValueKey('music-playback-retry'),
                onPressed: _retry,
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 30),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                ),
                icon: const Icon(Icons.refresh, size: 15),
                label: const Text('重试', style: TextStyle(fontSize: 11)),
              ),
            if (playback.technicalDetail.isNotEmpty)
              Theme(
                data: Theme.of(context)
                    .copyWith(dividerColor: Colors.transparent),
                child: Material(
                  type: MaterialType.transparency,
                  child: ExpansionTile(
                    tilePadding: const EdgeInsets.symmetric(horizontal: 12),
                    childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    dense: true,
                    title: Text(
                      '技术详情',
                      style: TextStyle(fontSize: 11, color: p.ink4),
                    ),
                    iconColor: p.ink4,
                    collapsedIconColor: p.ink4,
                    children: <Widget>[
                      Align(
                        alignment: Alignment.centerLeft,
                        child: SelectableText(
                          playback.technicalDetail,
                          style: TextStyle(
                            fontSize: 10.5,
                            color: p.ink4,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
