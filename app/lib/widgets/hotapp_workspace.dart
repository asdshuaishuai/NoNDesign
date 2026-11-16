import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import '../core/store.dart';
import '../core/theme.dart';
import 'common.dart';

/// NoN 热应用工作台（灵闪/Dots 式自成一体应用）：一句话 → LLM 生成
/// **自包含动画 HTML**（全内联零外链，canvas/SVG/CSS keyframes）→
/// WebView 即运行时（离线可用）；对话式修改 = 覆盖文件 + reload 即热更新。
/// 业务数据经注入的 `window.NoN.db.exec` 落 SQLite（每应用一个 app.db）。
/// 生成的热应用自动登记进作品集。
///
/// v1 质量环 = 服务端结构/外链校验 + WebView onerror/unhandledrejection
/// 经 NONHOTAPP 桥回传（服务端在 `</body>` 前注入包装脚本）；视觉截图 v2。
bool _wkRegistered = false;

/// 作品集「打开」直载：切视图前设置，HotAppWorkspace.initState 消费后清空
/// （registry builder 无参，跨实例传名的轻量通道）。
String? hotAppLoadOnOpen;

class HotAppWorkspace extends StatefulWidget {
  const HotAppWorkspace({super.key});

  @override
  State<HotAppWorkspace> createState() => _HotAppWorkspaceState();
}

class _HotAppWorkspaceState extends State<HotAppWorkspace> {
  String? _app;
  String _title = '';
  bool _busy = false;
  WebViewController? _controller;
  final _refineCtl = TextEditingController();
  final List<String> _notes = [];
  /// 页面运行错误（window.onerror / unhandledrejection / 资源加载失败）：
  /// 显示为可读条，一键填入 refine 输入框（错误进入修改闭环）。
  String _lastError = '';

  @override
  void initState() {
    super.initState();
    if (!_wkRegistered) {
      WebKitWebViewPlatform.registerWith();
      _wkRegistered = true;
    }
    final pending = hotAppLoadOnOpen;
    hotAppLoadOnOpen = null;
    final saved = context.read<AppStore>().settings.hotappApp;
    final app = pending ?? (saved.isNotEmpty ? saved : null);
    if (app != null && app.isNotEmpty) {
      _app = app;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _app == null) return;
        // 持久化推迟到首帧后：initState 里 notifyListeners 会在构建期
        // 触发祖先重建（setState during build）。
        if (pending != null) store.setHotApp(app);
        _mount(_app!);
        setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _refineCtl.dispose();
    _controller = null;
    super.dispose();
  }

  AppStore get store => context.read<AppStore>();

  void _mount(String name) {
    final api = store.api;
    if (api == null) return;
    _lastError = '';
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel('NONHOTAPP', onMessageReceived: _onBridgeMessage)
      ..setNavigationDelegate(NavigationDelegate(
        onWebResourceError: (error) {
          if (!mounted) return;
          setState(() => _lastError =
              '页面加载失败：${error.description}（${error.errorCode}）');
        },
      ))
      ..loadRequest(Uri.parse(api.hotAppPageUrl(name)));
  }

  void _onBridgeMessage(JavaScriptMessage msg) {
    try {
      final data = jsonDecode(msg.message);
      if (data is Map && data['kind'] == 'error') {
        final m = (data['message'] ?? '').toString();
        if (m.isEmpty || m == _lastError) return;
        if (mounted) setState(() => _lastError = m);
      }
    } catch (_) {}
  }

  void _openApp(String name) {
    setState(() {
      _app = name;
      _lastError = '';
      _notes.add('切换到 $name');
    });
    store.setHotApp(name);
    _mount(name);
  }

  /// 应用列表/切换入口（api.hotAppList）；列表里可新建或删除。
  Future<void> _showAppList() async {
    final api = store.api;
    if (api == null) return;
    Map<String, dynamic> res;
    try {
      res = await api.hotAppList();
    } catch (e) {
      if (mounted) _toast('应用列表失败', '$e');
      return;
    }
    if (!mounted) return;
    if (res['ok'] != true) {
      _toast('应用列表失败', '${res['detail'] ?? res['error']}');
      return;
    }
    final apps = ((res['apps'] as List?) ?? const []).whereType<Map>().toList();
    final picked = await showNonDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: ctx.palette.panel,
        title: Text('NoN 热应用', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: ctx.palette.ink)),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, '__new__'),
            child: Row(children: [
              Icon(Icons.add, size: 16, color: ctx.palette.accent),
              const SizedBox(width: 8),
              const Text('新建热应用…'),
            ]),
          ),
          if (apps.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Text('还没有热应用', style: TextStyle(fontSize: 12, color: ctx.palette.ink4)),
            ),
          for (final a in apps)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, (a['name'] ?? '').toString()),
              child: Row(children: [
                Icon(Icons.auto_fix_high_outlined, size: 16, color: ctx.palette.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${a['title'] ?? a['name']}（${a['name']}）',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if ('${a['name']}' == _app)
                  Icon(Icons.check, size: 15, color: ctx.palette.accent),
              ]),
            ),
        ],
      ),
    );
    if (!mounted || picked == null || picked.isEmpty) return;
    if (picked == '__new__') {
      await _create();
      return;
    }
    _openApp(picked);
  }

  Future<void> _deleteApp() async {
    final api = store.api;
    final app = _app;
    if (api == null || app == null || _busy) return;
    final ok = await showNonDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ctx.palette.panel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text('删除热应用？', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: ctx.palette.ink)),
        content: Text(
          '将删除源码目录与数据库 ~/Documents/NoNDesign/hotapps/$app，不可恢复。',
          style: TextStyle(fontSize: 13, height: 1.5, color: ctx.palette.ink2),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: ctx.palette.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (!mounted || ok != true) return;
    setState(() => _busy = true);
    try {
      final res = await api.hotAppDelete(app);
      if (!mounted) return;
      if (res['ok'] == true) {
        setState(() {
          _app = null;
          _title = '';
          _controller = null;
          _lastError = '';
          _notes.add('已删除 $app');
        });
        store.setHotApp('');
        _toast('已删除', '源码目录已移除（不可恢复）。');
      } else {
        _toast('删除被拒', '${res['detail'] ?? res['error']}');
      }
    } catch (e) {
      if (mounted) _toast('删除失败', '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _create() async {
    if (_busy) return;
    final api = store.api;
    final s = store.settings;
    if (api == null) return;
    if (s.apiKey.isEmpty) {
      _toast('先配置模型', '热应用生成需要 API Key。');
      return;
    }
    final nameCtl = TextEditingController();
    final briefCtl = TextEditingController();
    final ok = await showNonDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ctx.palette.panel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text('生成热应用', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: ctx.palette.ink)),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: nameCtl,
              decoration: const InputDecoration(labelText: '应用名（字母数字-下划线）', hintText: 'bounce-demo'),
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: briefCtl,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: '一句话需求（动画/演示/可玩的交互）',
                hintText: '做一个可点击加速的弹跳小球动画，彩色渐变背景',
                alignLabelWithHint: true,
              ),
              style: const TextStyle(fontSize: 13),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('生成')),
        ],
      ),
    );
    final name = nameCtl.text.trim();
    final brief = briefCtl.text.trim();
    // 不在这里 dispose 对话框控制器：showNonDialog 的 future 在 pop 时
    // 完成，但退场动画期间输入框仍挂载——立即 dispose 会被仍在渲染的
    // TextField 使用（已释放控制器异常）。局部控制器交给 GC。
    if (!mounted || ok != true) return;
    if (name.isEmpty || brief.isEmpty) return;
    setState(() => _busy = true);
    try {
      final res = await api.hotAppGenerate(
        name: name, brief: brief,
        model: s.modelId, baseUrl: s.baseUrl, apiKey: s.apiKey,
      );
      if (!mounted) return; // 视图已 dispose：不得 setState/丢服务端成果静默
      if (res['ok'] == true) {
        setState(() {
          _app = name;
          _title = brief;
          _lastError = '';
          _notes.add('已生成（${res['bytes']} 字节）');
        });
        store.setHotApp(name);
        _mount(name);
        _toast('热应用已生成', '点动画可以加速；下方输入框可继续修改。');
      } else {
        _toast('生成被拒', '${res['detail'] ?? res['error']}');
      }
    } on TimeoutException {
      if (mounted) {
        _toast('生成超时', '服务端可能仍在生成，稍后重载或去作品集查看。');
      }
    } catch (e) {
      if (mounted) _toast('生成失败', '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refine(String instruction) async {
    if (_busy) return;
    final api = store.api;
    final s = store.settings;
    final app = _app;
    if (api == null || app == null || instruction.trim().isEmpty) return;
    setState(() => _busy = true);
    try {
      final res = await api.hotAppRefine(
        name: app, instruction: instruction.trim(),
        model: s.modelId, baseUrl: s.baseUrl, apiKey: s.apiKey,
      );
      if (!mounted) return; // dispose 后不得 setState（旧代码异常被吞导致静默丢失）
      if (res['ok'] == true) {
        _controller?.loadRequest(Uri.parse(api.hotAppPageUrl(app))); // reload = 热更新
        setState(() => _notes.add('已修改：${instruction.trim()}'));
        _toast('已热更新', '预览已重载（${res['bytes']} 字节）。');
      } else {
        // fail-closed：覆盖被拒时旧版仍在（热更新无损坏风险）。
        _toast('修改被拒', '${res['detail'] ?? res['error']}');
      }
    } on TimeoutException {
      if (mounted) {
        _toast('修改超时', '服务端可能仍在生成，稍后重载或去作品集查看。');
      }
    } catch (e) {
      if (mounted) _toast('修改失败', '$e');
    } finally {
      if (mounted) {
        _refineCtl.clear();
        setState(() => _busy = false);
      }
    }
  }

  void _toast(String title, String detail) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        if (detail.trim().isNotEmpty)
          Text(detail.trim(), style: const TextStyle(fontSize: 11), maxLines: 2, overflow: TextOverflow.ellipsis),
      ]),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final api = store.api;
    return Column(
      children: [
        Container(
          height: 46,
          decoration: BoxDecoration(color: p.bgElevated, border: Border(bottom: BorderSide(color: p.line))),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          // 窄屏断点：副标题隐藏、标题省略号、动作按钮图标化（390 宽曾
          // 溢出 113px）。
          child: LayoutBuilder(builder: (context, constraints) {
            final narrow = constraints.maxWidth < 700;
            return Row(children: [
            // 全屏工作台的可见出口（对齐 3D/视频工作台与 Esc）。
            IconButton(
              icon: const Icon(Icons.arrow_back, size: 18),
              tooltip: '返回设计 ⌘1',
              color: p.ink2,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              onPressed: () => store.setView('design'),
            ),
            const SizedBox(width: 4),
            Icon(Icons.auto_fix_high_outlined, size: 17, color: p.accent),
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: narrow ? 110 : 400),
              child: Text(_app == null ? 'NoN 热应用' : '热应用 · $_app',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: p.ink)),
            ),
            const SizedBox(width: 10),
            if (!narrow)
              Tooltip(
                message: _title.isEmpty ? 'HTML + SQLite · 覆盖即热更新' : _title,
                child: Text(_title.isEmpty ? 'HTML + SQLite · 覆盖即热更新' : '$_title · 覆盖即热更新',
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: p.ink4)),
              ),
            const Spacer(),
            if (_busy) SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.8, color: p.accent)),
            const SizedBox(width: 8),
            if (api != null)
              _TopBtn(icon: Icons.list, label: '应用', compact: narrow, onTap: _busy ? null : _showAppList),
            _TopBtn(icon: Icons.add, label: '新建', compact: narrow, onTap: _busy ? null : _create),
            if (_app != null)
              _TopBtn(
                icon: Icons.delete_outline,
                label: '删除',
                compact: narrow,
                onTap: _busy ? null : _deleteApp,
              ),
            if (_app != null)
              _TopBtn(
                icon: Icons.refresh,
                label: '重载',
                compact: narrow,
                onTap: () => _controller?.loadRequest(Uri.parse(store.api!.hotAppPageUrl(_app!))),
              ),
          ]);
          }),
        ),
        if (_lastError.isNotEmpty)
          Container(
            width: double.infinity,
            color: p.danger.withValues(alpha: 0.12),
            padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
            child: Row(children: [
              Icon(Icons.error_outline, size: 15, color: p.danger),
              const SizedBox(width: 6),
              Expanded(
                child: Text(_lastError,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: p.danger)),
              ),
              TextButton(
                onPressed: () {
                  setState(() => _refineCtl.text = '修复这个运行错误：$_lastError');
                },
                child: const Text('填入修改框', style: TextStyle(fontSize: 11)),
              ),
              IconButton(
                tooltip: '忽略',
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(() => _lastError = ''),
                icon: Icon(Icons.close, size: 14, color: p.ink4),
              ),
            ]),
          ),
        Expanded(
          child: _app == null
              ? _EmptyHotApp(onCreate: _busy ? null : _create)
              : Column(children: [
                  Expanded(
                    child: _controller == null
                        ? Center(
                            child: Text(
                              api == null ? '未连接桌面服务器——热应用需要服务端生成与托管' : '加载中…',
                              style: TextStyle(fontSize: 12, color: p.ink3),
                            ),
                          )
                        : WebViewWidget(controller: _controller!),
                  ),
                  // 对话式修改条（快速热更新的入口）
                  Container(
                    decoration: BoxDecoration(color: p.bgElevated, border: Border(top: BorderSide(color: p.line))),
                    padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                    child: Row(children: [
                      Expanded(
                        child: TextField(
                          controller: _refineCtl,
                          style: TextStyle(fontSize: 12.5, color: p.ink),
                          onSubmitted: _busy ? null : _refine,
                          decoration: InputDecoration(
                            hintText: '告诉它怎么改：换成绿色 / 加一个重置按钮 / 动画再快一点…',
                            hintStyle: TextStyle(fontSize: 12, color: p.ink4),
                            isDense: true,
                            filled: true,
                            fillColor: p.panel2,
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: p.line)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filled(
                        onPressed: _busy ? null : () => _refine(_refineCtl.text),
                        icon: const Icon(Icons.arrow_upward, size: 17),
                        style: IconButton.styleFrom(backgroundColor: p.accent),
                      ),
                    ]),
                  ),
                ]),
        ),
      ],
    );
  }
}

class _EmptyHotApp extends StatelessWidget {
  const _EmptyHotApp({required this.onCreate});
  final VoidCallback? onCreate;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.auto_fix_high_outlined, size: 44, color: p.ink4),
        const SizedBox(height: 14),
        Text('NoN 热应用', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: p.ink)),
        const SizedBox(height: 6),
        SizedBox(
          width: 400,
          child: Text(
            '一句话生成自成一体的热应用：动画、演示、可玩的交互。\n'
            '自包含单 HTML + SQLite——离线可用、覆盖即热更新、生成即进作品集。\n'
            '适合快速做出可分享的动画小件、演示组件与轻量工具。',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: p.ink3, height: 1.7),
          ),
        ),
        const SizedBox(height: 18),
        FilledButton.icon(
          onPressed: onCreate, // 生成中禁点：否则可并发触发两次生成
          icon: const Icon(Icons.add, size: 16),
          label: const Text('生成第一个热应用'),
        ),
      ]),
    );
  }
}

class _TopBtn extends StatelessWidget {
  const _TopBtn({required this.icon, required this.label, this.onTap, this.compact = false});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final button = Padding(
      padding: EdgeInsets.only(left: compact ? 4 : 6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: compact ? 6 : 8, vertical: 5),
          child: compact
              ? Icon(icon, size: 16, color: onTap == null ? p.ink4 : p.ink2)
              : Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(icon, size: 14, color: onTap == null ? p.ink4 : p.ink2),
                  const SizedBox(width: 4),
                  Text(label, style: TextStyle(fontSize: 12, color: onTap == null ? p.ink4 : p.ink2)),
                ]),
        ),
      ),
    );
    return compact ? Tooltip(message: label, child: button) : button;
  }
}

/// JSON 调试辅助（notes 序列化）。
String hotAppNotesJson(List<String> notes) => jsonEncode(notes.map((n) => {'note': n}).toList());
