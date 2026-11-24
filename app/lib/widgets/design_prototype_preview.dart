/// 验证原型的应用内预览：把项目内自包含 HTML 交给 `webview_all` 渲染。
///
/// 只是查看面：事实源仍是 canonical `.mbt.md`，关掉窗口不改变项目；原型若
/// 含网络引用会被离屏/在线 WebView 拦截（覆盖门已在落盘时做过自包含检查）。
library;

import 'package:material_ui/material_ui.dart';
import 'package:webview_all/webview_all.dart';

import '../core/theme.dart';

class DesignPrototypePreviewDialog extends StatefulWidget {
  const DesignPrototypePreviewDialog({
    super.key,
    required this.title,
    required this.html,
  });

  final String title;
  final String html;

  static Future<void> show(
    BuildContext context, {
    required String title,
    required String html,
  }) {
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.4),
      builder: (_) => DesignPrototypePreviewDialog(title: title, html: html),
    );
  }

  @override
  State<DesignPrototypePreviewDialog> createState() =>
      _DesignPrototypePreviewDialogState();
}

class _DesignPrototypePreviewDialogState
    extends State<DesignPrototypePreviewDialog> {
  late final WebViewController _controller;
  bool _failed = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _controller = WebViewController();
    _load();
  }

  Future<void> _load() async {
    try {
      await _controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await _controller.loadHtmlString(widget.html);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _error = '$error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final media = MediaQuery.of(context).size;
    return Dialog(
      backgroundColor: p.panel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      insetPadding: const EdgeInsets.all(20),
      child: SizedBox(
        width: media.width * 0.9,
        height: media.height * 0.85,
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 8, 8),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: p.ink,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('design-prototype-preview-close'),
                    onPressed: () => Navigator.pop(context),
                    icon: Icon(Icons.close, size: 18, color: p.ink3),
                    tooltip: '关闭',
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: p.line),
            Expanded(
              child: _failed
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Icon(Icons.public_off, size: 28, color: p.warn),
                            const SizedBox(height: 8),
                            Text(
                              '本机暂时不能打开原型预览',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: p.ink,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '原型已存在项目里；可以在电脑上用浏览器打开导出的 HTML。',
                              textAlign: TextAlign.center,
                              style: TextStyle(fontSize: 12, color: p.ink4),
                            ),
                            const SizedBox(height: 8),
                            ExpansionTile(
                              title: Text(
                                '技术详情',
                                style: TextStyle(fontSize: 11, color: p.ink4),
                              ),
                              children: <Widget>[
                                Padding(
                                  padding: const EdgeInsets.all(8),
                                  child: Text(
                                    _error,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: p.ink4,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    )
                  : WebViewWidget(controller: _controller),
            ),
          ],
        ),
      ),
    );
  }
}
