/// 3D 视频预览面：把 [assembleVideo3dPreview] 组装的只读预览页接进
/// `webview_all`（与 3D 场景 / 热应用 / 视频 / 音乐播放面同一套 WebView 纪律）。
///
/// 纪律：
///
///  * 应用内 WebView 统一走 `webview_all`；平台判定只认
///    [PlatformCapabilities.supportsInAppWebView]，不在 widget 里写
///    `Platform.isX` 分叉。
///  * 预览页是**自包含单文件**：`assembleVideo3dPreview` 的 `runtimeSource`
///    由本层从应用资源读出（`assets/three/vendor/three-live.min.js` 文本），
///    经 `loadHtmlString` 注入，不落临时文件、不读本地其它资源、零外联。
///  * 读取运行时 / 组装页面失败**显性降级**：人话主文案 + 折叠的「技术详情」，
///    绝不静默产出一个少一块执行面的「降级页面」。
///  * 命令面走页面自身 API `window.NONVIDEO3D_PLAYER`（play / pause / stop /
///    seek / seekFrame）；出站桥只接 `window.NONVIDEO3D` 的
///    ready / frame / ended / error 四类消息（与契约层逐字对齐）。
///  * `loadHtmlString` 的 Future 只代表平台收下请求，**不等于页面脚本跑起来**：
///    就绪判据是 `window.NONVIDEO3D_PLAYER` 真的出现（轮询 `typeof`），超时/异常
///    一律落 [Video3dPreviewController.loadError]，不假装可播。
///  * 主帧加载失败才降级；子资源失败不整块替换（与 3D/热应用/音乐同纪律）。
///
/// 为测试提供可注入抽象 [Video3dPreviewController]：工作台可注入 Fake，走完整
/// 播放控制/错误面，而**不构造真 WebView**。生产实现是 [Video3dWebPreview]
/// （自建 `webview_all` 控制器 + 桥 + 就绪轮询 + 播放状态轮询）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:material_ui/material_ui.dart';
import 'package:webview_all/webview_all.dart';

import '../core/platform_capabilities.dart';
import '../core/theme.dart';
import '../core/video3d/video3d_compile.dart';
import '../core/video3d/video3d_contract.dart';
import '../core/video3d/video3d_player.dart';
import '../core/video3d/video3d_project.dart';

/// 页面桥通道名（`video3d_player.dart` 页面侧固定写死这个字符串，改它等于改契约）。
const String video3dPreviewBridgeChannel = video3dPreviewBridge;

/// 页面宿主命令面（`video3d_player.dart` 页面侧的 `window.NONVIDEO3D_PLAYER`）。
const String video3dPreviewHostObject = 'window.$video3dPreviewController';

/// 预览页内嵌的运行时文本资源（与 `three_service.dart` 的
/// `threeLiveAssetKey` 同一份资源；`.gitattributes` 对该目录做了 `-text`
/// 字节锁定）。本文件不依赖 3D 场景服务，只读这一份文本。
const String video3dRuntimeAssetKey = 'assets/three/vendor/three-live.min.js';

/// 预览页就绪等待上限：内联单文件页面很小（含运行时文本），3s 足够；超时按
/// 「没启动」处理（显性降级，不假装成功）。
const Duration video3dPreviewReadyTimeout = Duration(seconds: 3);

/// 就绪轮询间隔（与音乐播放页 / 离屏引擎宿主同族）。
const Duration video3dPreviewReadyPollInterval = Duration(milliseconds: 40);

/// 播放状态轮询间隔：页面自身也带运输条，用户可能在页面内播放/暂停；宿主
/// 状态以页面 `state()` 为准（只做低频率轮询，不是第二套播放实现）。
const Duration video3dPreviewStatePollInterval = Duration(milliseconds: 400);

/// 播放中 `frame` 回传的通知节流：页面 30fps 上报帧号，宿主不按 30Hz 重建
/// 预览面/运输条（帧号本身仍逐条落到控制器，最近一次刷新最多差 80ms）。
const Duration video3dPreviewFrameNotifyInterval = Duration(milliseconds: 80);

/// 测试注入：WebView 平台矩阵的确定性覆盖（同 `debugMusicPlaybackWebViewSupported`）。
///
/// 测试机造不出「没有应用内 WebView」的真实环境；置 false 即走显性降级分支。
/// 生产路径始终读 [PlatformCapabilities.supportsInAppWebView]。
@visibleForTesting
bool? debugVideo3dPreviewWebViewSupported;

/// 这台主机能否在应用内打开 3D 视频预览页。
bool video3dPreviewWebViewSupported([PlatformCapabilities? host]) =>
    debugVideo3dPreviewWebViewSupported ??
    (host ?? PlatformCapabilities.current()).supportsInAppWebView;

/// 预览面失败的人话映射（内部错误码只进折叠的「技术详情」）。
String video3dPreviewFailureMessage(Object? error) {
  final String code = error is Video3dPlayerError ? error.code : '';
  return switch (code) {
    video3dRuntimeMissingCode => '预览需要的 3D 运行文件没有找到，请重新安装后再试',
    video3dTemplateInvalidCode => '预览页没有组装完整，可以先重试',
    video3dSceneCompileInvalidCode => '场景没能编译成预览画面，检查场景文件后再试',
    _ => '预览页没有准备好，可以重试',
  };
}

/// 页面回传的原始错误 → 人话（原始文本仍进 [Video3dPreviewController.technicalDetail]）。
String video3dPageErrorMessage(String raw) {
  if (raw.contains('画面数据') || raw.contains('帧表为空')) {
    return '这个项目的画面数据是空的，先修好镜头时长';
  }
  if (raw.contains('初始化失败') || raw.contains('画布')) {
    return '预览初始化没有完成，可以重试';
  }
  if (raw.contains('场景构建')) return '场景没能组装起来，检查场景文件后再试';
  return '预览出错了，可以再试一次';
}

/// 预览面状态源：工作台运输条只读这份状态 / 命令面。
///
/// 生产实现是 [Video3dWebPreview]（`webview_all` + 桥 + 就绪/状态轮询）；测试
/// 注入 Fake 即可覆盖播放/暂停/停止/seek/帧号/错误面，**不需要构造真 WebView**。
abstract class Video3dPreviewController extends ChangeNotifier {
  /// 预览页是否真的跑起来（能接受命令）。
  bool get ready;

  /// 是否正在播放（页面 `state()` 回报 / 命令被接受后为 true）。
  bool get playing;

  /// 播放头（0 基帧号）。
  int get frame;

  /// 整数总帧数（页面 `ready` 回报优先，之前用帧表派生）。
  int get totalFrames;

  /// 帧率（v1 固定 30）。
  int get fps;

  /// 人话错误；空串 = 正常。原始诊断在 [technicalDetail]。
  String get loadError;

  /// 原始诊断：只进折叠的「技术详情」，绝不作为主文案。
  String get technicalDetail;

  /// 挂载/启动预览面（WebView 实现在这里读运行时、组装页面、载入并等就绪）。
  Future<void> start();

  Future<void> play();

  Future<void> pause();

  Future<void> stop();

  /// 按秒 seek（内部换算成整数帧，页面帧号只由帧表决定）。
  Future<void> seek(double seconds);

  /// 按整数帧 seek（页面 `renderFrame` 只由帧号决定，确定性）。
  Future<void> seekFrame(int frame);
}

/// 生产实现：`webview_all` 控制器 + `NONVIDEO3D` 桥 + 就绪/状态轮询。
class Video3dWebPreview extends Video3dPreviewController {
  Video3dWebPreview({
    required this.scene,
    required this.screenplay,
    required this.timeline,
    this.host,
    this.runtimeLoader,
    this.readyTimeout = video3dPreviewReadyTimeout,
  });

  final Video3dScene scene;
  final Video3dScreenplay screenplay;

  /// 整数帧表（调用方已按契约校验并编译；本层不再重复校验语义）。
  final Video3dTimeline timeline;

  /// 平台矩阵；缺省取 [PlatformCapabilities.current]（唯一平台事实源）。
  final PlatformCapabilities? host;

  /// 运行时文本读取器；生产为 null（[rootBundle] 读 [video3dRuntimeAssetKey]），
  /// 测试可注入失败/空白文本来覆盖显性降级路径。
  final Future<String> Function()? runtimeLoader;

  /// 就绪等待上限（测试可压短）。
  final Duration readyTimeout;

  WebViewController? _controller;
  bool _started = false;
  bool _disposed = false;
  bool _ready = false;
  bool _playing = false;
  int _frame = 0;
  int _totalFrames = 0;
  int _fps = 0;
  String _loadError = '';
  String _technicalDetail = '';
  Timer? _stateTimer;
  Future<void>? _startFuture;
  DateTime _lastFrameNotify = DateTime.fromMillisecondsSinceEpoch(0);

  /// 已组装的预览页 HTML（测试断言用；同一输入字节确定）。
  String? _html;

  /// 正在显示的 WebView 控制器（预览面 widget 用它挂 [WebViewWidget]）。
  WebViewController? get webView => _controller;

  /// 已组装的预览页（null = 还没组装成功）。
  @visibleForTesting
  String? get html => _html;

  @override
  bool get ready => !_disposed && _ready;

  @override
  bool get playing => !_disposed && _playing;

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

  /// 初始帧表口径：调用方已编译，先给出确定的帧数/帧率，就绪后由页面回传校正。
  void _primeFromTimeline() {
    if (_totalFrames <= 0 && timeline.totalFrames > 0) {
      _totalFrames = timeline.totalFrames;
    }
    if (_fps <= 0 && timeline.fps > 0) _fps = timeline.fps;
  }

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
    _primeFromTimeline();
    if (!video3dPreviewWebViewSupported(host)) {
      _fail('这台设备暂时不能内嵌预览 3D 视频', '当前环境没有应用内 WebView');
      return;
    }

    // 1) 运行时文本：读不到 / 空白 → 显性失败（不产出少一块执行面的页面）。
    String runtimeSource;
    try {
      final Future<String> Function() load =
          runtimeLoader ??
          () => rootBundle.loadString(video3dRuntimeAssetKey, cache: false);
      runtimeSource = await load();
    } catch (error) {
      _fail('预览需要的 3D 运行文件没有找到，请重新安装后再试', '$error');
      return;
    }
    if (_disposed) return;

    // 2) 组装页面：契约/模板/时间表问题都显性降级，不静默。
    String html;
    try {
      html = assembleVideo3dPreview(
        scene,
        screenplay,
        runtimeSource: runtimeSource,
      );
    } on Video3dPlayerError catch (error) {
      _fail(video3dPreviewFailureMessage(error), error.toString());
      return;
    } catch (error) {
      _fail('预览页没有准备好，可以重试', '$error');
      return;
    }
    if (_disposed) return;
    _html = html;

    // 3) WebView 平台就绪后才构造控制器（测试环境没装真平台时如实降级）。
    final WebViewPlatform? platform = WebViewPlatform.instance;
    if (platform == null) {
      _fail('这台设备暂时不能内嵌预览 3D 视频', '应用内 WebView 平台还没有就绪');
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
        video3dPreviewBridgeChannel,
        onMessageReceived: _handleBridgeMessage,
      );
      if (_disposed) return;
      await controller.setNavigationDelegate(
        NavigationDelegate(
          // 主帧失败才是「页面打不开」；子资源失败不整块替换页面。
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
      // 内联单文件页面：零外联，不读任何本地文件。loadHtmlString 的 Future
      // 只代表平台收下请求，页面脚本是否跑起来由下面的 typeof 轮询判定。
      await controller.loadHtmlString(html);
      await _waitUntilPlayerReady();
      if (_disposed) return;
      _ready = true;
      _playing = false;
      _loadError = '';
      _technicalDetail = '';
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
          'typeof $video3dPreviewHostObject',
        );
        if (value == 'object' || value == 'function') return;
      } catch (_) {
        // 页面还在解析脚本时调用 JS 会失败：继续轮询（超时前不算失败）。
      }
      await Future<void>.delayed(video3dPreviewReadyPollInterval);
    }
    throw StateError('预览页脚本没有在限定时间内就绪');
  }

  void _startStatePolling() {
    _stateTimer?.cancel();
    _stateTimer = Timer.periodic(video3dPreviewStatePollInterval, (_) {
      unawaited(_syncState());
    });
  }

  /// 页面内运输条也能起播：宿主播放状态以页面 `state()` 为准（低频轮询）。
  Future<void> _syncState() async {
    if (_disposed || !_ready) return;
    try {
      final Object? raw = await _evalRaw(
        '$video3dPreviewHostObject && '
        'typeof $video3dPreviewHostObject.state === "function" '
        '? $video3dPreviewHostObject.state() : ""',
      );
      final String state = raw is String ? raw : '${raw ?? ''}';
      final bool playing = state == 'playing';
      if (playing != _playing) {
        _playing = playing;
        notifyListeners();
      }
    } catch (_) {
      // 页面切换状态时读状态失败是暂时的；下个节拍会自愈。
    }
  }

  void _fail(String message, [String detail = '']) {
    if (_disposed) return;
    _stateTimer?.cancel();
    _stateTimer = null;
    _ready = false;
    _playing = false;
    _loadError = message;
    _technicalDetail = detail;
    notifyListeners();
  }

  /// 失败后的重试：换一个新控制器重新加载（旧页可能卡在半初始化）。
  Future<void> retry() async {
    if (_disposed) return;
    _stateTimer?.cancel();
    _stateTimer = null;
    _started = false;
    _startFuture = null;
    _ready = false;
    _playing = false;
    _frame = 0;
    _loadError = '';
    _technicalDetail = '';
    _controller = null;
    _html = null;
    notifyListeners();
    await start();
  }

  /// 是否已经尝试过启动（调试/测试只读）。
  @visibleForTesting
  bool get started => _started;

  // -------------------------------------------------------------- 命令面

  @override
  Future<void> play() async {
    if (!_ready || _disposed) return;
    _playing = true;
    _loadError = '';
    _technicalDetail = '';
    notifyListeners();
    final bool sent = await _run(
      '$video3dPreviewHostObject && $video3dPreviewHostObject.play && '
      '$video3dPreviewHostObject.play()',
    );
    if (!sent && !_disposed) {
      _playing = false;
      notifyListeners();
    }
  }

  @override
  Future<void> pause() async {
    if (!_ready || _disposed) return;
    _playing = false;
    notifyListeners();
    await _run(
      '$video3dPreviewHostObject && $video3dPreviewHostObject.pause && '
      '$video3dPreviewHostObject.pause()',
    );
  }

  @override
  Future<void> stop() async {
    if (!_ready || _disposed) return;
    _playing = false;
    _frame = 0;
    notifyListeners();
    await _run(
      '$video3dPreviewHostObject && $video3dPreviewHostObject.stop && '
      '$video3dPreviewHostObject.stop()',
    );
  }

  @override
  Future<void> seek(double seconds) async {
    if (!_ready || _disposed) return;
    final double safe = seconds.isFinite && seconds > 0 ? seconds : 0;
    final int fpsNow = _fps > 0 ? _fps : (timeline.fps > 0 ? timeline.fps : 30);
    _frame = _clampFrame((safe * fpsNow).floor());
    notifyListeners();
    await _run(
      '$video3dPreviewHostObject && $video3dPreviewHostObject.seek && '
      '$video3dPreviewHostObject.seek(${safe.toStringAsFixed(3)})',
    );
  }

  @override
  Future<void> seekFrame(int frame) async {
    if (!_ready || _disposed) return;
    _frame = _clampFrame(frame);
    notifyListeners();
    await _run(
      '$video3dPreviewHostObject && $video3dPreviewHostObject.seekFrame && '
      '$video3dPreviewHostObject.seekFrame($_frame)',
    );
  }

  int _clampFrame(int frame) {
    final int total = _totalFrames > 0
        ? _totalFrames
        : (timeline.totalFrames > 0 ? timeline.totalFrames : 0);
    if (total <= 0) return 0;
    if (frame < 0) return 0;
    if (frame > total - 1) return total - 1;
    return frame;
  }

  Future<bool> _run(String script) async {
    final WebViewController? controller = _controller;
    if (controller == null) return false;
    try {
      await controller.runJavaScript(script);
      return true;
    } catch (error) {
      if (!_disposed) {
        _stateTimer?.cancel();
        _stateTimer = null;
        _playing = false;
        _loadError = '播放命令没有送到预览页，可以重试';
        _technicalDetail = '$error';
        notifyListeners();
      }
      return false;
    }
  }

  // -------------------------------------------------------------- 桥消息

  void _handleBridgeMessage(JavaScriptMessage message) =>
      handleBridgePayload(message.message);

  /// 桥消息入口（暴露给测试；生产由 `window.NONVIDEO3D` 通道回调进入）。
  ///
  /// 只认契约四类：ready / frame / ended / error；未知种类忽略（不猜）。
  @visibleForTesting
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
        _frame = 0;
        _playing = false;
        _ready = true;
        _loadError = '';
        _technicalDetail = '';
        notifyListeners();
      case 'frame':
        final int? frame = _readInt(decoded['frame']);
        if (frame == null) return;
        final int next = _clampFrame(frame);
        if (next == _frame) return;
        _frame = next;
        final DateTime now = DateTime.now();
        if (now.difference(_lastFrameNotify) >=
            video3dPreviewFrameNotifyInterval) {
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
        _stateTimer?.cancel();
        _stateTimer = null;
        _playing = false;
        _loadError = video3dPageErrorMessage(raw);
        _technicalDetail = raw.isEmpty ? '页面报告了未知错误' : raw;
        notifyListeners();
      default:
        return;
    }
  }

  static int? _readInt(Object? raw) {
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw);
    return null;
  }

  // -------------------------------------------------------------- 内部工具

  Future<Object?> _evalRaw(String script) async {
    final WebViewController? controller = _controller;
    if (controller == null) throw StateError('预览页还没有创建');
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

  @override
  void dispose() {
    _disposed = true;
    _stateTimer?.cancel();
    _stateTimer = null;
    _controller = null;
    super.dispose();
  }
}

/// 生产预览面控制器工厂（工作台默认注入；测试可换成 Fake）。
///
/// 调用前必须已通过 `verifyVideo3d` 并编译出 [timeline]（工作台负责）；
/// 输入不合格时显性抛 [StateError]，不产出半成品预览。
Video3dPreviewController createDefaultVideo3dPreview(
  Video3dProjectSnapshot snapshot,
  Video3dTimeline timeline, {
  PlatformCapabilities? host,
  Future<String> Function()? runtimeLoader,
}) {
  final Video3dScene? scene = snapshot.scene;
  final Video3dScreenplay? screenplay = snapshot.screenplay;
  if (scene == null || screenplay == null) {
    throw StateError('3D 视频预览需要已通过校验的项目快照');
  }
  return Video3dWebPreview(
    scene: scene,
    screenplay: screenplay,
    timeline: timeline,
    host: host,
    runtimeLoader: runtimeLoader,
  );
}

/// 预览面：只显示 WebView 舞台 + 就绪/错误占位，运输条在工作台底部。
///
/// 播放头与错误经 [Video3dPreviewController]（[ChangeNotifier]）回调给工作台，
/// 这里不另造第二套回调通道。
class Video3dPreviewSurface extends StatelessWidget {
  const Video3dPreviewSurface({super.key, required this.preview});

  /// 预览控制器（生产 = [Video3dWebPreview]；测试可注入 Fake，不构造 WebView）。
  final Video3dPreviewController preview;

  @override
  Widget build(BuildContext context) {
    final NonPalette p = context.palette;
    return Container(
      key: const ValueKey('video3d-preview-surface'),
      decoration: BoxDecoration(
        color: p.panel2,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: p.line),
      ),
      // WebKitGTK/WebView2 的原生 Overlay 只能表示矩形/RRect/椭圆裁剪；
      // Container(decoration+clipBehavior) 生成的是任意路径 ClipPath，真机
      // （Linux WebKitGTK）会把 WebView 直接隐藏（2026-11-26 集成冒烟实测）。
      // 用 ClipRRect（RRect）保留圆角，外框 Container 不裁剪。
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: ListenableBuilder(
          listenable: preview,
          builder: (BuildContext context, Widget? _) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _header(context, p),
              Divider(height: 1, color: p.line),
              Expanded(child: _stage(context, p)),
            ],
          ),
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
        ? (preview.playing ? '预览中' : '可以预览')
        : '准备中';
    final Color statusColor = failed
        ? p.warn
        : ready
        ? (preview.playing ? p.accent : p.ink3)
        : p.ink4;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
      child: Row(
        children: <Widget>[
          Icon(Icons.movie_creation_outlined, size: 13, color: p.ink4),
          const SizedBox(width: 6),
          Text(
            '3D 视频预览',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: p.ink,
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              '只读预览，不改项目文件',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10, color: p.ink4),
            ),
          ),
          const Spacer(),
          Text(
            status,
            key: const ValueKey('video3d-preview-status'),
            style: TextStyle(fontSize: 10, color: statusColor),
          ),
        ],
      ),
    );
  }

  Widget _stage(BuildContext context, NonPalette p) {
    // 错误面先判：Fake 注入也要能测「错误回调 → 人话 + 技术详情」。
    final Video3dPreviewController preview = this.preview;
    final String error = preview.loadError;
    if (error.isNotEmpty) return _errorPane(context, p, error);
    // 注入的 Fake（测试/外部托管）：只占住画位，不构造 WebView。
    final Video3dWebPreview? web = preview is Video3dWebPreview
        ? preview
        : null;
    if (web == null) {
      return const ColoredBox(
        key: ValueKey('video3d-preview-stage'),
        color: Color(0xFF0B0D12),
      );
    }
    final WebViewController? controller = web.webView;
    if (!web.ready || controller == null) return _loadingPane(p);
    return Container(
      key: const ValueKey('video3d-preview-stage'),
      color: const Color(0xFF0B0D12),
      child: WebViewWidget(controller: controller),
    );
  }

  Widget _loadingPane(NonPalette p) {
    return Center(
      key: const ValueKey('video3d-preview-loading'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2, color: p.accent),
          ),
          const SizedBox(height: 10),
          Text('预览页准备中…', style: TextStyle(fontSize: 11, color: p.ink3)),
        ],
      ),
    );
  }

  Widget _errorPane(BuildContext context, NonPalette p, String message) {
    final Video3dPreviewController preview = this.preview;
    return Center(
      key: const ValueKey('video3d-preview-error'),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.movie_filter_outlined, size: 30, color: p.ink4),
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
              '场景和镜头文件都还在，可以继续检查；修好后重试预览。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: p.ink4, height: 1.5),
            ),
            const SizedBox(height: 10),
            if (preview is Video3dWebPreview)
              TextButton.icon(
                key: const ValueKey('video3d-preview-retry'),
                onPressed: () => preview.retry(),
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 30),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                ),
                icon: const Icon(Icons.refresh, size: 15),
                label: const Text('重试', style: TextStyle(fontSize: 11)),
              ),
            if (preview.technicalDetail.isNotEmpty)
              Theme(
                data: Theme.of(context)
                    .copyWith(dividerColor: Colors.transparent),
                child: Material(
                  type: MaterialType.transparency,
                  child: ExpansionTile(
                    key: const ValueKey('video3d-preview-technical'),
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
                          preview.technicalDetail,
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
