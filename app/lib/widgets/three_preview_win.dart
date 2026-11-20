/// Windows 3D 场景预览（WebView2，via webview_windows）。
///
/// `webview_flutter` 没有 Windows 实现；3D 工作台的场景预览在 Windows 上
/// 由本组件承载，加载与 macOS 完全相同的本地宿主页 `preview.html`（同一份
/// 由 `ThreeService.preparePreview` 写出的自包含页面）。
///
/// 桥接：预览页最早的内联脚本就会调用 `window.NON3D.postMessage(...)`
/// （webview_flutter 的 JavaScriptChannel 语义）。WebView2 没有该通道，这里在
/// 文档创建时注入一个同名垫片，把消息转到 `window.chrome.webview`；控制器
/// 的 `webMessage` 流再把 JSON 原文交回工作台的同一条处理链（error / metrics /
/// screenshot）。
///
/// 兜底：系统缺 WebView2 运行时等初始化失败由 [onUnavailable] 上报，工作台
/// 换成「用浏览器打开 / 在文件夹中显示」的可操作面；加载失败由 [onLoadFailed]
/// 上报，走可重试的占位。
library;

import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:webview_windows/webview_windows.dart' as wv;

import '../core/theme.dart';

/// 预览页桥垫片：在页面任何脚本之前把 `NON3D` 接到 WebView2 宿主消息。
///
/// 消息必须是 JSON 文本——预览页本来就 `JSON.stringify(...)`；
/// `webview_windows` 收到后按 JSON 解码（解析失败会走流的 error，本组件忽略）。
const String _threeWindowsBridgeShim = '''
(function () {
  if (window.NON3D) return;
  window.NON3D = {
    postMessage: function (message) {
      try { window.chrome.webview.postMessage(message); } catch (e) {}
    }
  };
})();
''';

/// Windows 3D 预览面：持有 WebView2 控制器与宿主消息订阅。
class ThreeWinPreview extends StatefulWidget {
  const ThreeWinPreview({
    super.key,
    required this.htmlPath,
    required this.generation,
    required this.onBridge,
    required this.onUnavailable,
    required this.onLoadFailed,
  });

  /// `ThreeService.preparePreview` 写出的宿主页绝对路径。
  final String htmlPath;

  /// 每次挂载/刷新递增：同一路径也要重新加载（文件内容已被重写）。
  final int generation;

  /// 预览页桥消息（JSON 文本，与 webview_flutter 的 JavaScriptMessage 同形）。
  final ValueChanged<String> onBridge;

  /// WebView2 初始化失败（系统缺运行时等）——宿主应降级到浏览器兜底。
  final ValueChanged<String> onUnavailable;

  /// 页面加载失败——宿主展示可重试占位。
  final ValueChanged<String> onLoadFailed;

  @override
  State<ThreeWinPreview> createState() => ThreeWinPreviewState();
}

/// 公开 State 以便工作台通过 [GlobalKey] 发起截图 / 四方位取证脚本。
class ThreeWinPreviewState extends State<ThreeWinPreview> {
  final wv.WebviewController _controller = wv.WebviewController();
  late final Future<void> _boot = _initialize();
  StreamSubscription<dynamic>? _messages;
  StreamSubscription<wv.WebErrorStatus>? _loadErrors;

  bool _ready = false;
  bool _nativeReady = false;
  bool _controllerDisposed = false;
  int _loadToken = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_boot);
  }

  Future<void> _initialize() async {
    try {
      await _controller.initialize();
      _nativeReady = true;
      // 初始化完成时工作台可能已经切走：释放刚建好的原生纹理，不再导航。
      if (!mounted) {
        _disposeController();
        return;
      }
      await _controller.setPopupWindowPolicy(
        wv.WebviewPopupWindowPolicy.deny,
      );
      // 垫片必须早于页面任何脚本：addScriptToExecuteOnDocumentCreated 保证
      // 每个新文档的第一段脚本就是它。
      await _controller.addScriptToExecuteOnDocumentCreated(
        _threeWindowsBridgeShim,
      );
      if (!mounted) {
        _disposeController();
        return;
      }
      _messages = _controller.webMessage.listen(
        _onWebMessage,
        onError: (Object error) {
          debugPrint('[three] webview2 message dropped: $error');
        },
      );
      _loadErrors = _controller.onLoadError.listen(_onLoadError);
      await _load(widget.htmlPath);
    } catch (error) {
      debugPrint('[three] webview2 init failed: $error');
      if (_nativeReady) _disposeController();
      if (mounted) widget.onUnavailable('$error');
    }
  }

  void _onWebMessage(dynamic message) {
    final String text;
    if (message is String) {
      // webMessageReceived 走 WebMessageAsJson：字符串载荷由插件解码回字符串。
      text = message;
    } else if (message is Map || message is List) {
      text = jsonEncode(message);
    } else {
      text = '$message';
    }
    if (text.isEmpty) return;
    widget.onBridge(text);
  }

  void _onLoadError(wv.WebErrorStatus status) {
    debugPrint('[three] webview2 navigation failed: ${status.name}');
    if (!mounted) return;
    widget.onLoadFailed('navigation failed: ${status.name}');
  }

  Future<void> _load(String path) async {
    final token = ++_loadToken;
    try {
      await _controller.loadUrl(_fileUrl(path));
    } catch (error) {
      if (!mounted || token != _loadToken) return;
      widget.onLoadFailed('$error');
      return;
    }
    if (!mounted || token != _loadToken) return;
    setState(() => _ready = true);
  }

  /// 工作台发起的取证脚本（截图 / 四方位）。未就绪或已卸载时静默跳过——
  /// 工具栏已经按 metrics 桥禁用，这里是第二道保险。
  Future<void> runJavaScript(String script) async {
    await _boot;
    if (!mounted || !_nativeReady || !_controller.value.isInitialized) return;
    try {
      await _controller.executeScript(script);
    } catch (error) {
      debugPrint('[three] webview2 script failed: $error');
    }
  }

  @override
  void didUpdateWidget(covariant ThreeWinPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.generation != widget.generation ||
        oldWidget.htmlPath != widget.htmlPath) {
      unawaited(_reload());
    }
  }

  Future<void> _reload() async {
    await _boot;
    if (!mounted || !_nativeReady) return;
    await _load(widget.htmlPath);
  }

  /// WebView2 接受正斜杠的 file:/// URL；空格等字符交给 Uri 编码。
  /// 本组件只在 Windows 上挂载，按 Windows 路径规则编码（不受测试宿主影响）。
  String _fileUrl(String path) =>
      Uri.file(path, windows: true).toString();

  void _disposeController() {
    if (_controllerDisposed) return;
    _controllerDisposed = true;
    unawaited(
      _controller.dispose().catchError((Object error) {
        debugPrint('[three] webview2 dispose failed: $error');
      }),
    );
  }

  @override
  void dispose() {
    unawaited(_messages?.cancel() ?? Future<void>.value());
    unawaited(_loadErrors?.cancel() ?? Future<void>.value());
    // initialize 失败时控制器的 completer 永远不会完成，dispose 会一直挂起；
    // 只有真的初始化成功过才释放原生纹理。
    if (_nativeReady) _disposeController();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: context.palette.accent,
          ),
        ),
      );
    }
    return wv.Webview(_controller);
  }
}
