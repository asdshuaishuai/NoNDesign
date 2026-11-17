import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import '../core/api_shelf.dart';
import '../core/theme.dart';

/// 视频播放面（艺术架 → 视频产物 → 真播）。
///
/// 载体是 WebView：媒体文档由平台原生播放器承担（WKWebView macOS/iOS、
/// Android WebView）——不引入播放器依赖，也不需要把帧序列在 Dart 侧重放。
/// **只在构造时创建控制器**：视频工作台的默认渲染台模式根本不构造本 widget，
/// 既有 video_workspace_test 不设 WebViewPlatform 也不会炸。
///
/// 自动播放硬前提（真机黑屏的根因）：WebKitWebViewControllerCreationParams
/// 的默认值是 `mediaTypesRequiringUserAction = {audio, video}` +
/// `allowsInlineMediaPlayback = false`（webview_flutter_wkwebview
/// 3.27.2 webkit_webview_controller.dart:73-77）——不显式放开这两个参数，
/// 媒体会被自动播放策略静默拦住（页面加载成功但永远不播）。
bool _wkRegistered = false;

class VideoPlayerSurface extends StatefulWidget {
  const VideoPlayerSurface({super.key, required this.path, this.baseUrl});

  /// mp4 绝对路径（`videos/<job>/frames.mp4`，或回退的
  /// `video/<job>/frames.mp4`）。
  final String path;

  /// 服务器地址：有则经 /video/mp4?path=… 走 HTTP（Range/seek 由服务端
  /// FileResponse 承担）；无服务器（离线）用 file:// 本地打开。
  final String? baseUrl;

  @override
  State<VideoPlayerSurface> createState() => _VideoPlayerSurfaceState();
}

class _VideoPlayerSurfaceState extends State<VideoPlayerSurface> {
  WebViewController? _controller;
  String _error = '';

  /// webview_flutter 只覆盖 android/ios/macos；Linux/Windows 没有 WebView
  /// 插件——那两平台降级为路径提示（工作台信息行仍可复制路径/定位文件）。
  static bool get _webViewSupported => Platform.isMacOS || Platform.isIOS || Platform.isAndroid;

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
    PlatformWebViewControllerCreationParams params = const PlatformWebViewControllerCreationParams();
    if (Platform.isMacOS || Platform.isIOS) {
      params = WebKitWebViewControllerCreationParams(
        // 空集合 = AudiovisualMediaType.none：视频无需用户手势即可播放；
        // allowsInlineMediaPlayback 让播放不抢占全屏（保持工作台布局）。
        mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
        allowsInlineMediaPlayback: true,
      );
    }
    final c = WebViewController.fromPlatformCreationParams(params)
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        // 主帧 HTTP ≥400（/video/mp4 的 400 invalid_video_path / 404 no_video）
        // 在 WKWebView 上不进 onWebResourceError——必须用 onHttpError。
        onHttpError: (error) {
          final code = error.response?.statusCode;
          if (code != null) _setError('无法播放：HTTP $code（产物不存在或路径越界）');
        },
        onWebResourceError: (error) {
          // 子资源失败不清播放面；只报主帧。
          if (error.isForMainFrame == false) return;
          _setError('无法播放：${error.description}（${error.errorCode}）');
        },
      ));
    return c;
  }

  void _loadMedia() {
    final c = _controller;
    if (c == null) return;
    final base = widget.baseUrl?.trim() ?? '';
    if (base.isNotEmpty) {
      c.loadRequest(Uri.parse(videoMp4UrlFor(base, widget.path)));
    } else {
      // 离线：WK 默认 readAccessPath = 文件父目录（webkit_webview_controller
      // .dart:45-47），mp4 本体可读即可播。
      c.loadFile(widget.path);
    }
  }

  void _setError(String msg) {
    if (!mounted || msg == _error) return;
    setState(() => _error = msg);
  }

  Future<void> _copyPath() async {
    await Clipboard.setData(ClipboardData(text: widget.path));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已复制路径')));
  }

  Future<void> _reveal() async {
    final ok = await revealInFolder(widget.path);
    if (!mounted || ok) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('无法在文件夹中显示')));
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
    final c = _controller;
    if (c == null) {
      return Center(child: CircularProgressIndicator(strokeWidth: 1.6, color: p.accent));
    }
    return Container(
      color: Colors.black,
      child: WebViewWidget(controller: c),
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
          OutlinedButton.icon(
            onPressed: _copyPath,
            icon: const Icon(Icons.copy_all_outlined, size: 14),
            label: const Text('复制路径', style: TextStyle(fontSize: 12)),
          ),
          if (revealSupported)
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
