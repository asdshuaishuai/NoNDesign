/// 引擎短片（Phaser 4）预览面：WebView 宿主 + 控制条 + 显性失败面。
///
/// 与 `video3d_preview_surface.dart` 同族纪律（同一套 WebView 规则）：
///  * 舞台必须是**真 WebView**；测试注入 Fake 控制器，不构造 WebView；
///  * 页面自包含单文件（CSP 关网、Phaser/pixelfx 原文内联）；
///  * 宿主命令面 = 页面 `window.NONSHORT_PLAYER`，回传桥 = `window.NONSHORT`；
///  * 人话主文案 + 折叠「技术详情」；原始诊断不进主文案；
///  * WebView 宿主用 `ClipRRect`（RRect）裁剪，不用 `Container(clipBehavior)`
///    ——任意路径 ClipPath 会让 WebKitGTK 直接隐藏 WebView（2026-11-26 真机事故）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:material_ui/material_ui.dart';
import 'package:webview_all/webview_all.dart';

import '../core/platform_capabilities.dart';
import '../core/theme.dart';
import '../core/video/video_screenplay.dart';
import '../core/video/video_short_evidence.dart';
import '../core/video/video_short_player.dart';

/// 预览页内嵌的 Phaser 运行时（`build-manifest.json` 锁 sha256/字节）。
const String videoShortRuntimeAssetKey = videoShortPhaserAssetKey;

/// 预览页内嵌的 pixelfx 像素包（可选：缺失时页面如实降级为占位标记）。
const String videoShortPixelfxRuntimeAssetKey = videoShortPixelfxAssetKey;

/// 就绪等待上限 / 轮询间隔。
const Duration videoShortPreviewReadyTimeout = Duration(seconds: 5);
const Duration videoShortPreviewReadyPollInterval = Duration(milliseconds: 40);
const Duration videoShortPreviewStatePollInterval = Duration(milliseconds: 400);
const Duration videoShortPreviewFrameNotifyInterval = Duration(
  milliseconds: 33,
);

/// 页面桥通道名（与页面侧固定字符串一致）。
const String videoShortPreviewBridgeChannel = videoShortBridge;

/// 页面命令面（`window.NONSHORT_PLAYER`）。
const String videoShortPreviewHostObject = 'window.$videoShortController';

/// 测试机造不出「没有应用内 WebView」的真实环境；置 false 即走显性降级分支。
/// 生产路径始终读 [PlatformCapabilities.supportsInAppWebView]。
@visibleForTesting
bool? debugVideoShortPreviewWebViewSupported;

/// 这台主机能否在应用内打开引擎短片预览页。
bool videoShortPreviewWebViewSupported([PlatformCapabilities? host]) =>
    debugVideoShortPreviewWebViewSupported ??
    (host ?? PlatformCapabilities.current()).supportsInAppWebView;

/// 预览控制器（生产 = [VideoShortWebPreview]；测试注入 Fake）。
abstract class VideoShortPreviewController extends ChangeNotifier {
  bool get ready;
  bool get playing;
  int get frame;
  int get totalFrames;
  int get fps;

  /// 人话错误；空串 = 正常。
  String get loadError;

  /// 原始诊断：只进折叠的「技术详情」。
  String get technicalDetail;

  /// 页面如实回传的渲染器标识（`phaser4_canvas`）；就绪前为空串。
  String get renderer => '';

  /// VFX 渲染面标识：`pixelfx_pixels` / `placeholder_markers`。
  String get vfxRenderer => '';

  Future<void> start();
  Future<void> play();
  Future<void> pause();
  Future<void> stop();

  /// 按秒 seek（内部换算成整数帧）。
  Future<void> seek(double seconds);

  /// 按整数帧 seek（页面 `renderFrame` 只由帧号决定）。
  Future<void> seekFrame(int frame);

  /// 抓一帧证据（PNG）。默认实现 = 不支持抓帧（测试 Fake）；
  /// 生产实现走页面 `capture(frame)` + 桥 `evidence`。
  Future<List<VideoShortFrameEvidence>> captureFrames(List<int> frames) async {
    throw const VideoShortEvidenceError(
      videoShortCaptureUnavailableCode,
      '当前预览面不支持抓帧',
    );
  }

  /// 抓单帧；失败码与 [captureFrames] 相同。
  Future<VideoShortFrameEvidence> captureFrame(int frame) async {
    final List<VideoShortFrameEvidence> one = await captureFrames(<int>[frame]);
    return one.single;
  }
}

/// 生产实现：`webview_all` 控制器 + `NONSHORT` 桥 + 就绪/状态轮询。
class VideoShortWebPreview extends VideoShortPreviewController {
  VideoShortWebPreview({
    required this.screenplay,
    this.host,
    this.phaserLoader,
    this.pixelfxLoader,
    this.readyTimeout = videoShortPreviewReadyTimeout,
  });

  final VideoScreenplay screenplay;
  final PlatformCapabilities? host;

  /// Phaser 文本读取器；生产为 null（rootBundle 读 [videoShortRuntimeAssetKey]）。
  final Future<String> Function()? phaserLoader;

  /// pixelfx 文本读取器；生产为 null；缺失不致命（页面降级为占位标记）。
  final Future<String> Function()? pixelfxLoader;

  final Duration readyTimeout;

  bool _disposed = false;
  Future<void>? _startFuture;
  WebViewController? _controller;
  String? _html;

  bool _ready = false;
  bool _playing = false;
  int _frame = 0;
  int _totalFrames = 0;
  int _fps = videoScreenplayFps;
  String _loadError = '';
  String _technicalDetail = '';
  String _renderer = '';
  String _vfxRenderer = '';
  String _pixelfxNote = '';
  Completer<VideoShortFrameEvidence>? _captureWaiter;
  int _captureExpectedFrame = -1;
  Timer? _stateTimer;
  DateTime _lastFrameNotify = DateTime.now();

  @override
  bool get ready => !_disposed && _ready;

  @override
  bool get playing => _playing;

  @override
  int get frame => _frame;

  @override
  int get totalFrames => _totalFrames;

  @override
  int get fps => _fps;

  @override
  String get loadError => _loadError;

  @override
  String get technicalDetail => _technicalDetail;

  @override
  String get renderer => _renderer;

  @override
  String get vfxRenderer => _vfxRenderer;

  /// 已组装的页面（失败前为 null）。
  String? get html => _html;

  /// 舞台要挂的 WebView 控制器（未创建/已销毁为 null）。
  WebViewController? get webView => _disposed ? null : _controller;

  /// 启动（幂等：重复调用复用同一个 start Future）。
  Future<void> start() {
    final Future<void>? existing = _startFuture;
    if (existing != null) return existing;
    final Future<void> future = _start();
    _startFuture = future;
    return future;
  }

  Future<void> _start() async {
    if (_disposed) return;
    if (!videoShortPreviewWebViewSupported(host)) {
      _fail('这台设备暂时不能内嵌预览引擎短片', '当前环境没有应用内 WebView');
      return;
    }

    // 1) Phaser 运行时（必需）。
    String phaserSource;
    try {
      final Future<String> Function() load =
          phaserLoader ??
          () => rootBundle.loadString(videoShortRuntimeAssetKey, cache: false);
      phaserSource = await load();
    } catch (error) {
      _fail('预览需要的引擎运行文件没有找到，请重新安装后再试', '$error');
      return;
    }
    if (_disposed) return;
    if (phaserSource.trim().isEmpty) {
      _fail('预览需要的引擎运行文件不完整，请重新安装后再试', 'phaser runtime is blank');
      return;
    }

    // 2) pixelfx 像素包（可选；缺失时页面如实降级，原因进技术详情）。
    String pixelfxSource = '';
    try {
      final Future<String> Function() load =
          pixelfxLoader ??
          () => rootBundle.loadString(
            videoShortPixelfxRuntimeAssetKey,
            cache: false,
          );
      final String loaded = await load();
      if (loaded.trim().isNotEmpty) pixelfxSource = loaded;
    } catch (error) {
      _pixelfxNote = 'pixelfx 像素包没有读到：$error';
    }
    if (_disposed) return;

    // 3) 组装页面。
    String html;
    try {
      html = assembleVideoShortPage(
        screenplay,
        phaserSource: phaserSource,
        pixelfxSource: pixelfxSource,
      );
    } on VideoShortPlayerError catch (error) {
      _fail(videoShortFailureMessage(error.code), error.detail);
      return;
    } catch (error) {
      _fail('预览页没有准备好，可以重试', '$error');
      return;
    }
    if (_disposed) return;
    _html = html;

    // 4) WebView 平台就绪后才构造控制器。
    final WebViewPlatform? platform = WebViewPlatform.instance;
    if (platform == null) {
      _fail('这台设备暂时不能内嵌预览引擎短片', '应用内 WebView 平台还没有就绪');
      return;
    }

    try {
      final WebViewController controller =
          WebViewController.fromPlatformCreationParams(
            const PlatformWebViewControllerCreationParams(),
          );
      _controller = controller;
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      if (_disposed) return;
      await controller.addJavaScriptChannel(
        videoShortPreviewBridgeChannel,
        onMessageReceived: _handleBridgeMessage,
      );
      if (_disposed) return;
      await controller.setNavigationDelegate(
        NavigationDelegate(
          onWebResourceError: (WebResourceError error) {
            if (_disposed || error.isForMainFrame == false) return;
            _fail(
              '预览页没有加载出来，可以重试',
              '${error.description} (${error.errorCode})',
            );
          },
        ),
      );
      if (_disposed) return;
      await controller.loadHtmlString(html);
      await _waitUntilPlayerReady();
      if (_disposed) return;
      // 命令面出现 ≠ bridge ready 已解析：渲染器/VFX/总帧数都在 ready 回执里，
      // 等它到达再置 ready（否则宿主会读到空字符串/0 帧，等于撒谎）。
      await _waitUntilBridgeReady();
      if (_disposed) return;
      if (_totalFrames <= 0) {
        // 桥没回执也不能永远 0：总帧数有事实源（已校验剧本），据实兜底并留痕。
        _totalFrames = screenplay.totalFrames;
        _pixelfxNote = _pixelfxNote.isEmpty
            ? '页面 ready 回执没有到达，帧数按剧本事实源兜底'
            : _pixelfxNote;
      }
      _ready = true;
      _playing = false;
      _loadError = '';
      _technicalDetail = _pixelfxNote;
      notifyListeners();
      _startStatePolling();
    } catch (error) {
      _fail('预览页没有启动起来，可以重试', '$error');
    }
  }

  Future<void> _waitUntilPlayerReady() async {
    final DateTime deadline = DateTime.now().add(readyTimeout);
    while (DateTime.now().isBefore(deadline)) {
      if (_disposed) return;
      try {
        final Object? value = await _evalRaw(
          'typeof $videoShortPreviewHostObject',
        );
        if (value == 'object' || value == 'function') return;
      } catch (_) {
        // 页面还在解析脚本时调用 JS 会失败：继续轮询。
      }
      await Future<void>.delayed(videoShortPreviewReadyPollInterval);
    }
    throw StateError('预览页脚本没有在限定时间内就绪');
  }

  /// 等桥的 `ready` 回执（渲染器/VFX 面/总帧数都由它携带）。
  Future<void> _waitUntilBridgeReady() async {
    final DateTime deadline = DateTime.now().add(readyTimeout);
    while (DateTime.now().isBefore(deadline)) {
      if (_disposed) return;
      if (_totalFrames > 0 || _renderer.isNotEmpty) return;
      await Future<void>.delayed(videoShortPreviewReadyPollInterval);
    }
  }

  void _startStatePolling() {
    _stateTimer?.cancel();
    _stateTimer = Timer.periodic(videoShortPreviewStatePollInterval, (_) {
      unawaited(_syncState());
    });
  }

  Future<void> _syncState() async {
    if (_disposed || !_ready) return;
    try {
      final Object? raw = await _evalRaw(
        '$videoShortPreviewHostObject && '
        'typeof $videoShortPreviewHostObject.state === "function" '
        '? $videoShortPreviewHostObject.state() : ""',
      );
      final String state = raw is String ? raw : '${raw ?? ''}';
      final bool playing = state == 'playing';
      if (playing != _playing) {
        _playing = playing;
        notifyListeners();
      }
    } catch (_) {
      // 页面忙/切换中：下一次轮询再看，不把抖动当失败。
    }
  }

  @override
  Future<void> play() async {
    if (!_ready || _disposed) return;
    _playing = true;
    notifyListeners();
    await _run('$videoShortPreviewHostObject.play()');
  }

  @override
  Future<void> pause() async {
    if (!_ready || _disposed) return;
    _playing = false;
    notifyListeners();
    await _run('$videoShortPreviewHostObject.pause()');
  }

  @override
  Future<void> stop() async {
    if (!_ready || _disposed) return;
    _frame = 0;
    _playing = false;
    notifyListeners();
    await _run('$videoShortPreviewHostObject.stop()');
  }

  @override
  Future<void> seek(double seconds) async {
    if (!_ready || _disposed) return;
    final int total = _totalFrames > 0 ? _totalFrames : screenplay.totalFrames;
    final int target = (seconds * _fps).round().clamp(0, total - 1);
    await seekFrame(target);
  }

  @override
  Future<void> seekFrame(int frame) async {
    if (!_ready || _disposed) return;
    final int total = _totalFrames > 0 ? _totalFrames : screenplay.totalFrames;
    _frame = frame.clamp(0, total - 1);
    _playing = false;
    notifyListeners();
    await _run('$videoShortPreviewHostObject.seekFrame($_frame)');
  }

  @override
  Future<List<VideoShortFrameEvidence>> captureFrames(List<int> frames) async {
    if (frames.isEmpty) {
      throw const VideoShortEvidenceError(
        videoShortEvidenceEmptyCode,
        '没有要抓的帧',
      );
    }
    if (frames.length > videoShortEvidenceMaxFrames) {
      throw VideoShortEvidenceError(
        videoShortEvidenceLimitCode,
        '一次抓帧数量超过上限',
        '${frames.length} > $videoShortEvidenceMaxFrames',
      );
    }
    if (!ready || _controller == null) {
      throw const VideoShortEvidenceError(
        videoShortCaptureUnavailableCode,
        '预览还没有就绪，不能抓帧',
      );
    }
    final List<VideoShortFrameEvidence> collected = <VideoShortFrameEvidence>[];
    for (final int frame in frames) {
      collected.add(await _captureOne(frame));
    }
    checkVideoShortEvidenceBudget(collected);
    return collected;
  }

  Future<VideoShortFrameEvidence> _captureOne(int frame) async {
    final WebViewController? controller = _controller;
    final int target = _clampFrame(frame);
    if (controller == null) {
      throw const VideoShortEvidenceError(
        videoShortCaptureUnavailableCode,
        '预览还没有就绪，不能抓帧',
      );
    }
    if (_captureWaiter != null && !_captureWaiter!.isCompleted) {
      throw const VideoShortEvidenceError(
        videoShortCaptureFailedCode,
        '上一帧还没抓完，不能并发抓帧',
      );
    }
    final Completer<VideoShortFrameEvidence> completer =
        Completer<VideoShortFrameEvidence>();
    // 页面可能同步回执：先标记已处理，真正的抛出仍走下面的 await。
    completer.future.ignore();
    _captureWaiter = completer;
    _captureExpectedFrame = target;
    try {
      await controller.runJavaScript(
        '$videoShortPreviewHostObject && '
        '$videoShortPreviewHostObject.capture && '
        '$videoShortPreviewHostObject.capture($target)',
      );
    } catch (error) {
      _clearCaptureWaiter();
      throw VideoShortEvidenceError(
        videoShortCaptureFailedCode,
        '抓帧命令没有发出去',
        '$error',
      );
    }
    try {
      return await completer.future.timeout(videoShortCaptureTimeout);
    } on TimeoutException {
      _clearCaptureWaiter();
      throw VideoShortEvidenceError(
        videoShortCaptureTimeoutCode,
        '这一帧等超时了，可以重试',
        'frame=$target',
      );
    }
  }

  void _clearCaptureWaiter() {
    _captureWaiter = null;
    _captureExpectedFrame = -1;
  }

  void _handleBridgeMessage(JavaScriptMessage message) {
    handleBridgePayload(message.message);
  }

  /// 桥回传解析（测试可直接调用）。
  void handleBridgePayload(String payload) {
    if (_disposed) return;
    Object? decoded;
    try {
      decoded = jsonDecode(payload);
    } catch (_) {
      return;
    }
    if (decoded is! Map) return;
    final String kind = '${decoded['kind'] ?? ''}';
    switch (kind) {
      case 'ready':
        final int? fps = _readInt(decoded['fps']);
        final int? total = _readInt(decoded['total_frames']);
        if (fps != null && fps > 0) _fps = fps;
        if (total != null && total > 0) _totalFrames = total;
        final String reportedRenderer = '${decoded['renderer'] ?? ''}'.trim();
        if (reportedRenderer.isNotEmpty) _renderer = reportedRenderer;
        final String reportedVfx = '${decoded['vfx'] ?? ''}'.trim();
        if (reportedVfx.isNotEmpty) _vfxRenderer = reportedVfx;
        _frame = 0;
        _playing = false;
        _ready = true;
        _loadError = '';
        _technicalDetail = _pixelfxNote;
        notifyListeners();
      case 'frame':
        final int? frame = _readInt(decoded['frame']);
        if (frame == null) return;
        final int next = _clampFrame(frame);
        if (next == _frame) return;
        _frame = next;
        final DateTime now = DateTime.now();
        if (now.difference(_lastFrameNotify) >=
            videoShortPreviewFrameNotifyInterval) {
          _lastFrameNotify = now;
          notifyListeners();
        }
      case 'ended':
        final int? frame = _readInt(decoded['frame']);
        if (frame != null) _frame = _clampFrame(frame);
        _playing = false;
        notifyListeners();
      case 'error':
        final String raw = '${decoded['message'] ?? ''}';
        // 抓帧等待中收到页面错误：立刻失败，不让工具侧干等到超时。
        final Completer<VideoShortFrameEvidence>? waiter = _captureWaiter;
        if (waiter != null && !waiter.isCompleted) {
          _clearCaptureWaiter();
          waiter.completeError(
            VideoShortEvidenceError(
              videoShortCaptureFailedCode,
              '页面没能给出这一帧',
              raw.isEmpty ? 'page error' : raw,
            ),
          );
        }
        _stateTimer?.cancel();
        _stateTimer = null;
        _playing = false;
        _loadError = videoShortPageErrorMessage(raw);
        _technicalDetail = raw.isEmpty ? '页面报告了未知错误' : raw;
        notifyListeners();
      case 'evidence':
        final int? frame = _readInt(decoded['frame']);
        final Completer<VideoShortFrameEvidence>? waiter = _captureWaiter;
        if (frame == null ||
            waiter == null ||
            waiter.isCompleted ||
            frame != _captureExpectedFrame) {
          // 没有等待者 / 帧号对不上（可能是超时后的迟到消息）：忽略，不猜。
          return;
        }
        final String renderer = '${decoded['renderer'] ?? ''}';
        final String vfx = '${decoded['vfx'] ?? ''}';
        _clearCaptureWaiter();
        try {
          waiter.complete(
            VideoShortFrameEvidence(
              frame: frame,
              bytes: decodeVideoShortEvidenceDataUrl(
                '${decoded['data_url'] ?? ''}',
              ),
              renderer: renderer,
              vfx: vfx,
            ),
          );
        } on VideoShortEvidenceError catch (error) {
          waiter.completeError(error);
        }
      default:
        return;
    }
  }

  int _clampFrame(int frame) {
    final int total = _totalFrames > 0 ? _totalFrames : screenplay.totalFrames;
    if (total <= 0) return 0;
    return frame.clamp(0, total - 1);
  }

  static int? _readInt(Object? raw) {
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw);
    return null;
  }

  Future<Object?> _evalRaw(String script) async {
    final WebViewController? controller = _controller;
    if (controller == null) throw StateError('预览页还没有创建');
    final Object result = await controller.runJavaScriptReturningResult(
      script,
    );
    // 有些平台把字符串结果再包一层 JSON 引号。
    if (result is String &&
        result.length >= 2 &&
        result.startsWith('"') &&
        result.endsWith('"')) {
      try {
        final Object? decoded = jsonDecode(result);
        if (decoded is String) return decoded;
      } catch (_) {}
    }
    return result;
  }

  Future<void> _run(String script) async {
    final WebViewController? controller = _controller;
    if (controller == null) return;
    try {
      await controller.runJavaScript(script);
    } catch (error) {
      _fail('预览页没有响应，可以重试', '$error');
    }
  }

  void _fail(String message, String detail) {
    _ready = false;
    _loadError = message;
    _technicalDetail = detail;
    _stateTimer?.cancel();
    _stateTimer = null;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _stateTimer?.cancel();
    _stateTimer = null;
    super.dispose();
  }
}

/// 组装失败码 → 人话。
String videoShortFailureMessage(String code) {
  switch (code) {
    case videoShortPhaserMissingCode:
      return '预览需要的引擎运行文件没有找到，请重新安装后再试';
    case videoShortScreenplayInvalidCode:
      return '剧本时间表不完整，预览页没有组装出来';
    default:
      return '预览页没有准备好，可以重试';
  }
}

/// 页面错误 → 人话（原始文本只进技术详情）。
String videoShortPageErrorMessage(String raw) {
  final String text = raw.trim();
  if (text.isEmpty) return '预览页出错了，可以重试';
  if (text.contains('引擎启动失败') || text.contains('Phaser')) {
    return '引擎没有启动起来，可以重试';
  }
  if (text.contains('vfx 渲染失败')) return '特效没有渲染出来，可以重试';
  if (text.contains('画布') || text.contains('canvas')) {
    return '预览画布没有准备好，可以重试';
  }
  return '预览出错了，可以重试';
}

/// 预览面（舞台 + 控制条 + 错误面）。测试可注入 Fake 控制器。
class VideoShortPreviewSurface extends StatelessWidget {
  const VideoShortPreviewSurface({super.key, required this.preview});

  final VideoShortPreviewController preview;

  @override
  Widget build(BuildContext context) {
    final NonPalette p = context.palette;
    return Container(
      key: const ValueKey('video-short-preview-surface'),
      decoration: BoxDecoration(
        color: p.panel2,
        borderRadius: BorderRadius.circular(NonRadius.md),
        border: Border.all(color: p.line),
      ),
      // WebView 宿主一律 ClipRRect（RRect 可表示）；见文件头注释。
      child: ClipRRect(
        borderRadius: BorderRadius.circular(NonRadius.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            ListenableBuilder(
              listenable: preview,
              builder: (BuildContext context, Widget? _) => _header(context, p),
            ),
            Divider(height: 1, color: p.line),
            Expanded(child: _VideoShortPreviewStage(surface: this)),
            Divider(height: 1, color: p.line),
            ListenableBuilder(
              listenable: preview,
              builder: (BuildContext context, Widget? _) =>
                  _transport(context, p),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context, NonPalette p) {
    final bool ready = preview.ready;
    final bool failed = preview.loadError.isNotEmpty;
    final String status = failed
        ? '不可用'
        : ready
        ? (preview.playing ? '播放中' : '可以预览')
        : '准备中';
    final Color statusColor = failed
        ? p.warn
        : ready
        ? (preview.playing ? p.accent : p.ink3)
        : p.ink4;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NonSpace.md,
        NonSpace.sm,
        NonSpace.md,
        NonSpace.sm,
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.auto_awesome_motion_outlined, size: 13, color: p.ink4),
          const SizedBox(width: NonSpace.sm),
          Text(
            '引擎短片预览',
            style: TextStyle(
              fontSize: NonType.body,
              fontWeight: FontWeight.w600,
              color: p.ink,
            ),
          ),
          const SizedBox(width: NonSpace.sm),
          Text(
            status,
            key: const ValueKey('video-short-preview-status'),
            style: TextStyle(fontSize: NonType.caption, color: statusColor),
          ),
          const Spacer(),
          if (preview.renderer.isNotEmpty)
            Text(
              preview.renderer,
              key: const ValueKey('video-short-preview-renderer'),
              style: TextStyle(fontSize: NonType.micro, color: p.ink4),
            ),
        ],
      ),
    );
  }

  Widget _transport(BuildContext context, NonPalette p) {
    final bool ready = preview.ready;
    final int total = preview.totalFrames > 0
        ? preview.totalFrames
        : 0;
    final double seconds = total == 0 ? 0 : preview.frame / preview.fps;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NonSpace.sm,
        NonSpace.xs,
        NonSpace.md,
        NonSpace.xs,
      ),
      child: Row(
        children: <Widget>[
          IconButton(
            key: const ValueKey('video-short-preview-play'),
            // 播放/暂停是同一个按钮（语义切换，不是一个只会 play 的假按钮）。
            onPressed: ready
                ? (preview.playing ? preview.pause : preview.play)
                : null,
            icon: Icon(
              preview.playing ? Icons.pause : Icons.play_arrow,
              size: 18,
            ),
            tooltip: preview.playing ? '暂停' : '播放',
          ),
          IconButton(
            key: const ValueKey('video-short-preview-stop'),
            onPressed: ready ? preview.stop : null,
            icon: const Icon(Icons.stop, size: 16),
            tooltip: '停止',
          ),
          Expanded(
            child: Slider(
              key: const ValueKey('video-short-preview-seek'),
              value: (preview.frame.toDouble()).clamp(
                0,
                (total > 0 ? total - 1 : 0).toDouble(),
              ),
              max: (total > 0 ? total - 1 : 0).toDouble(),
              onChanged: ready && total > 0
                  ? (double value) => preview.seekFrame(value.round())
                  : null,
            ),
          ),
          Text(
            '${_clock(seconds)} / ${_clock(total == 0 ? 0 : total / preview.fps)}',
            key: const ValueKey('video-short-preview-clock'),
            style: TextStyle(fontSize: NonType.caption, color: p.ink3),
          ),
        ],
      ),
    );
  }

  Widget _stage(BuildContext context, NonPalette p) {
    final bool failed = preview.loadError.isNotEmpty;
    if (failed) return _errorPane(context, p);
    final WebViewController? controller = preview is VideoShortWebPreview
        ? (preview as VideoShortWebPreview).webView
        : null;
    if (controller == null) {
      return Center(
        child: Text(
          '准备中',
          style: TextStyle(fontSize: NonType.body, color: p.ink4),
        ),
      );
    }
    return WebViewWidget(controller: controller);
  }

  Widget _errorPane(BuildContext context, NonPalette p) {
    final String detail = preview.technicalDetail;
    return Center(
      key: const ValueKey('video-short-preview-error'),
      child: Padding(
        padding: const EdgeInsets.all(NonSpace.md),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(Icons.error_outline, size: 22, color: p.warn),
            const SizedBox(height: NonSpace.sm),
            Text(
              preview.loadError,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: NonType.body, color: p.ink2),
            ),
            if (detail.isNotEmpty) ...<Widget>[
              const SizedBox(height: NonSpace.xs),
              _TechnicalDetails(detail: detail),
            ],
            if (preview is VideoShortWebPreview)
              FilledButton.tonal(
                key: const ValueKey('video-short-preview-retry'),
                onPressed: () {
                  unawaited(preview.start());
                },
                child: const Text('重试'),
              ),
          ],
        ),
      ),
    );
  }

  static String _clock(double seconds) {
    final int total = seconds.isFinite && seconds > 0
        ? seconds.floor()
        : 0;
    final int minutes = total ~/ 60;
    final int secs = total % 60;
    return '$minutes:${secs < 10 ? '0' : ''}$secs';
  }
}

/// 折叠的技术详情：默认收起，点开才显示原始诊断（主文案永远是 huuamn 文案）。
class _TechnicalDetails extends StatefulWidget {
  const _TechnicalDetails({required this.detail});

  final String detail;

  @override
  State<_TechnicalDetails> createState() => _TechnicalDetailsState();
}

class _TechnicalDetailsState extends State<_TechnicalDetails> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final NonPalette p = context.palette;
    return Column(
      key: const ValueKey('video-short-preview-technical'),
      children: <Widget>[
        TextButton.icon(
          onPressed: () => setState(() => _expanded = !_expanded),
          icon: Icon(
            _expanded ? Icons.expand_less : Icons.expand_more,
            size: 14,
          ),
          label: Text(
            '技术详情',
            style: TextStyle(fontSize: NonType.caption, color: p.ink4),
          ),
        ),
        if (_expanded)
          Padding(
            padding: const EdgeInsets.only(bottom: NonSpace.sm),
            child: SelectableText(
              widget.detail,
              style: TextStyle(fontSize: NonType.micro, color: p.ink4),
            ),
          ),
      ],
    );
  }
}

class _VideoShortPreviewStage extends StatefulWidget {
  const _VideoShortPreviewStage({required this.surface});

  final VideoShortPreviewSurface surface;

  @override
  State<_VideoShortPreviewStage> createState() => _VideoShortPreviewStageState();
}

class _VideoShortPreviewStageState extends State<_VideoShortPreviewStage> {
  VideoShortPreviewController get _preview => widget.surface.preview;

  late bool _ready;
  late String _error;
  late bool _hasWebView;

  @override
  void initState() {
    super.initState();
    _capture();
    _preview.addListener(_onPreviewChanged);
  }

  @override
  void didUpdateWidget(covariant _VideoShortPreviewStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final VideoShortPreviewController previous = oldWidget.surface.preview;
    if (identical(previous, _preview)) return;
    previous.removeListener(_onPreviewChanged);
    _preview.addListener(_onPreviewChanged);
    _capture();
  }

  void _capture() {
    _ready = _preview.ready;
    _error = _preview.loadError;
    _hasWebView =
        _preview is VideoShortWebPreview &&
        (_preview as VideoShortWebPreview).webView != null;
  }

  void _onPreviewChanged() {
    if (!mounted) return;
    final bool ready = _preview.ready;
    final String error = _preview.loadError;
    final bool hasWebView =
        _preview is VideoShortWebPreview &&
        (_preview as VideoShortWebPreview).webView != null;
    if (ready == _ready && error == _error && hasWebView == _hasWebView) return;
    setState(_capture);
  }

  @override
  void dispose() {
    _preview.removeListener(_onPreviewChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.surface._stage(context, context.palette);
  }
}
