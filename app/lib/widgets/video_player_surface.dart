/// 视频播放面（艺术架 → 视频产物 → 真播）。
///
/// 载体是 WebView：媒体文档由平台原生播放器承担（WKWebView macOS/iOS、
/// Android WebView）——不引入播放器依赖，也不需要把帧序列在 Dart 侧重放。
/// 播放的是**本机文件**（`file://`），不经任何端口或内部路由：进度条拖动
/// 由原生播放器的本地文件读取承担。
///
/// **只在构造时创建控制器**：视频工作台的默认渲染台模式根本不构造本 widget，
/// 既有工作台测试不设 WebViewPlatform 也不会炸。
///
/// 自动播放硬前提（真机黑屏的根因）：WebKitWebViewControllerCreationParams
/// 的默认值是 `mediaTypesRequiringUserAction = {audio, video}` +
/// `allowsInlineMediaPlayback = false`（webview_flutter_wkwebview
/// 3.27.2 webkit_webview_controller.dart:73-77）——不显式放开这两个参数，
/// 媒体会被自动播放策略静默拦住（页面加载成功但永远不播）。
library;

import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import '../core/platform_capabilities.dart';
import '../core/theme.dart';
import '../core/toast_service.dart';
import '../core/video_service.dart';

bool _wkRegistered = false;

class VideoPlayerSurface extends StatefulWidget {
  const VideoPlayerSurface({super.key, required this.path});

  /// mp4 绝对路径（`videos/<job>/frames.mp4`）。
  final String path;

  @override
  State<VideoPlayerSurface> createState() => _VideoPlayerSurfaceState();
}

class _VideoPlayerSurfaceState extends State<VideoPlayerSurface> {
  WebViewController? _controller;
  String _error = '';

  /// webview_flutter 只覆盖 android/ios/macos；Linux/Windows 没有 WebView
  /// 实现——那两平台降级为路径提示（信息行仍可复制路径/定位文件）。
  bool get _webViewSupported => PlatformCapabilities.current().supportsInAppWebView;

  ToastService get _toasts => ToastScope.of(context);

  @override
  void initState() {
    super.initState();
    if (!_webViewSupported) return;
    _controller = _createController();
    _loadMedia();
  }

  @override
  void dispose() {
    _controller = null;
    super.dispose();
  }

  WebViewController _createController() {
    // webview_flutter 无 endorsed macOS 实现：首次使用前幂等注册 WebKit。
    // 守卫同时看 instance——测试注入 fake 平台后不得被真注册覆盖
    //（真 WKWebView 控制器在 flutter test 里构造即 UnimplementedError）。
    if ((Platform.isMacOS || Platform.isIOS) && !_wkRegistered && WebViewPlatform.instance == null) {
      WebKitWebViewPlatform.registerWith();
      _wkRegistered = true;
    }
    PlatformWebViewControllerCreationParams params =
        const PlatformWebViewControllerCreationParams();
    if (Platform.isMacOS || Platform.isIOS) {
      params = WebKitWebViewControllerCreationParams(
        // 空集合 = AudiovisualMediaType.none：视频无需用户手势即可播放；
        // allowsInlineMediaPlayback 让播放不抢占全屏（保持工作台布局）。
        mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
        allowsInlineMediaPlayback: true,
      );
    }
    return WebViewController.fromPlatformCreationParams(params)
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        // 主帧加载失败在 WKWebView 上不进 onWebResourceError——用 onHttpError
        // 兜住 HTTP 形态的错误页（本地文件缺失通常走 onWebResourceError）。
        onHttpError: (error) {
          final code = error.response?.statusCode;
          if (code != null) _setError('无法播放：这个视频文件读不出来（$code）');
        },
        onWebResourceError: (error) {
          // 子资源失败不清播放面；只报主帧。
          if (error.isForMainFrame == false) return;
          _setError('无法播放：这个视频文件不在了或无法读取');
        },
      ));
  }

  void _loadMedia() {
    final controller = _controller;
    if (controller == null) return;
    // 本地文件：WK 默认 readAccessPath = 文件父目录
    //（webkit_webview_controller.dart:45-47），mp4 本体可读即可播。
    controller.loadFile(widget.path);
  }

  void _setError(String message) {
    if (!mounted || message == _error) return;
    setState(() => _error = message);
  }

  /// 失败可能是时序性的：渲染刚完成 mp4 还在落盘、或网络盘短暂掉线——
  /// 给一次手动重载，错误态不能是死端。
  void _retryLoad() {
    if (!mounted) return;
    setState(() => _error = '');
    _loadMedia();
  }

  Future<void> _copyPath() async {
    await Clipboard.setData(ClipboardData(text: widget.path));
    if (!mounted) return;
    _toasts.info('已复制路径');
  }

  Future<void> _reveal() async {
    if (!PlatformCapabilities.current().supportsRevealInFolder) {
      _toasts.warn('这台设备不支持在文件夹中显示');
      return;
    }
    final ok = await revealInSystemFileManager(widget.path);
    if (!mounted || ok) return;
    _toasts.warn('没能打开文件夹', '可以先用「复制路径」拿到文件位置。');
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    if (!_webViewSupported) {
      return Container(
        color: p.panel2,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.movie_outlined, size: 36, color: p.ink4),
          const SizedBox(height: 10),
          Text('当前平台不支持应用内视频播放',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: p.ink2)),
          const SizedBox(height: 6),
          Text('可复制路径后在系统播放器打开：\n${widget.path}',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: p.ink4, height: 1.5)),
        ]),
      );
    }
    if (_error.isNotEmpty) return _errorPane(p);
    final controller = _controller;
    if (controller == null) {
      return Center(child: CircularProgressIndicator(strokeWidth: 1.6, color: p.accent));
    }
    return Container(
      color: Colors.black,
      child: WebViewWidget(controller: controller),
    );
  }

  /// 播放失败覆盖层：路径 + 复制 +（桌面）在文件夹中显示——失败不是死端，
  /// 用户至少能拿到文件。
  Widget _errorPane(NonPalette p) {
    return Container(
      key: const ValueKey('video-error'),
      color: p.panel2,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(24),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.broken_image_outlined, size: 36, color: p.danger),
        const SizedBox(height: 10),
        Text(_error,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: p.ink2, height: 1.5)),
        const SizedBox(height: 8),
        SelectableText(widget.path,
            textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: p.ink4)),
        const SizedBox(height: 10),
        Wrap(spacing: 8, children: [
          FilledButton.icon(
            onPressed: _retryLoad,
            icon: const Icon(Icons.refresh_outlined, size: 14),
            label: const Text('重新加载', style: TextStyle(fontSize: 12)),
          ),
          OutlinedButton.icon(
            onPressed: _copyPath,
            icon: const Icon(Icons.copy_all_outlined, size: 14),
            label: const Text('复制路径', style: TextStyle(fontSize: 12)),
          ),
          if (PlatformCapabilities.current().supportsRevealInFolder)
            OutlinedButton.icon(
              onPressed: _reveal,
              icon: const Icon(Icons.folder_open_outlined, size: 14),
              label: const Text('在文件夹中显示', style: TextStyle(fontSize: 12)),
            ),
        ]),
      ]),
    );
  }
}
