/// Windows 热应用应用内预览（WebView2，via webview_windows）。
///
/// 平台矩阵（AGENTS.md 能力矩阵）：`webview_flutter` 只覆盖 macOS/iOS/
/// Android；Windows 上的应用内预览此前是「用浏览器打开」的诚实占位。
/// 本组件补上 Windows 分支：系统自带 WebView2（Win11 预装 / Win10
/// Evergreen）承载同一个缓存 HTML 文件，行为与 macOS 预览一致。
///
/// 数据面：当前热应用家族全部 localStorage 自包含（file:// 源下 WebView2
/// 允许 localStorage）；`withDbBridge` 注入的数据库桥依赖 webview_flutter
/// 的 JS channel，WebView2 侧暂不桥接——需要数据库桥的应用回退占位
/// （见 [HotappWinPreview.supportsDbBridge]），绝不静默降级。
///
/// 失败面：WebView2 运行时缺失/初始化失败时**不白屏**——给出人话 + 重试 +
/// 浏览器打开 + 复制路径（回调由工作台提供，工作台才知道怎么开浏览器/提示）。
library;

import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:webview_windows/webview_windows.dart' as wv;

import '../core/theme.dart';

/// 数据库桥（webview_flutter JS channel 语义）在 WebView2 侧尚未桥接：
/// 当前全部已产热应用为 localStorage 自包含（实测 2026-11-20），此开关
/// 恒 false，占位分支继续给「用浏览器打开」。
const bool kWindowsDbBridgeSupported = false;

/// Windows 热应用预览面。`[htmlPath]` 是 NonAppCache 写出的预览文件。
class HotappWinPreview extends StatefulWidget {
  const HotappWinPreview({
    super.key,
    required this.htmlPath,
    this.onOpenExternal,
    this.onCopyPath,
    this.onRevealInFolder,
  });

  final String htmlPath;

  /// 降级出口：用系统浏览器打开同一份缓存文件（工作台提供）。
  final VoidCallback? onOpenExternal;

  /// 降级出口：复制预览文件路径（工作台提供，Toast 走工作台的通知面）。
  final VoidCallback? onCopyPath;

  /// 降级出口：在文件夹中显示（桌面才有；工作台按能力门传入）。
  final VoidCallback? onRevealInFolder;

  @override
  State<HotappWinPreview> createState() => _HotappWinPreviewState();
}

class _HotappWinPreviewState extends State<HotappWinPreview> {
  final wv.WebviewController _controller = wv.WebviewController();
  bool _initialized = false;
  String _error = '';
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      if (!_initialized) {
        await _controller.initialize();
        _initialized = true;
        await _controller.setPopupWindowPolicy(
          wv.WebviewPopupWindowPolicy.deny,
        );
      }
      await _controller.loadUrl(_fileUrl(widget.htmlPath));
      if (!mounted) return;
      setState(() {
        _ready = true;
        _error = '';
      });
    } catch (error) {
      debugPrint('[hotapp] webview2 init failed: $error');
      if (mounted) {
        setState(() => _error = 'WebView2 初始化失败');
      }
    }
  }

  /// 失败后重试：运行时刚装好/被禁用后恢复时不必退出工作台。
  Future<void> _retry() async {
    if (!mounted) return;
    setState(() {
      _error = '';
      _ready = false;
    });
    await _init();
  }

  /// WebView2 接受正斜杠的 file:/// URL；空格等字符交给 Uri 编码。
  String _fileUrl(String path) =>
      Uri.file(path, windows: Platform.isWindows).toString();

  @override
  void didUpdateWidget(covariant HotappWinPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.htmlPath != widget.htmlPath && _ready) {
      _controller.loadUrl(_fileUrl(widget.htmlPath));
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    if (_error.isNotEmpty) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.gpp_bad_outlined, size: 40, color: p.danger),
            const SizedBox(height: 12),
            Text(_error, style: TextStyle(fontSize: 14, color: p.ink)),
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Text(
                '系统缺少 WebView2 运行时，装好后可以点重试；也可以直接用浏览器打开应用文件，'
                '或复制文件路径在文件夹里打开——文件就在本机，不会上传。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: p.ink4, height: 1.6),
              ),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                FilledButton.icon(
                  onPressed: _retry,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('重试'),
                ),
                if (widget.onOpenExternal != null)
                  OutlinedButton.icon(
                    onPressed: widget.onOpenExternal,
                    icon: const Icon(Icons.open_in_browser_outlined, size: 16),
                    label: const Text('用浏览器打开'),
                  ),
                if (widget.onCopyPath != null)
                  OutlinedButton.icon(
                    onPressed: widget.onCopyPath,
                    icon: const Icon(Icons.copy_all_outlined, size: 16),
                    label: const Text('复制文件路径'),
                  ),
                if (widget.onRevealInFolder != null)
                  OutlinedButton.icon(
                    onPressed: widget.onRevealInFolder,
                    icon: const Icon(Icons.folder_open_outlined, size: 16),
                    label: const Text('在文件夹中显示'),
                  ),
              ],
            ),
          ]),
        ),
      );
    }
    if (!_ready) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(height: 10),
          Text(
            '正在加载应用内预览…',
            style: TextStyle(fontSize: 12, color: p.ink3),
          ),
        ]),
      );
    }
    return wv.Webview(_controller);
  }
}
