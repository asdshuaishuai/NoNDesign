import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import '../core/store.dart';
import '../core/theme.dart';
import 'common.dart';

/// A2UI 小应用工作台（灵闪/Dots 式自成一体应用）：一句话 → LLM 生成
/// **自包含动画 HTML**（全内联零外链，canvas/SVG/CSS keyframes）→
/// WebView 即运行时（离线可用）；对话式修改 = 覆盖文件 + reload 即热更新。
/// 生成的小应用自动登记进作品集。
bool _wkRegistered = false;

/// 作品集「打开」直载：切视图前设置，A2uiWorkspace.initState 消费后清空
/// （registry builder 无参，跨实例传名的轻量通道）。
String? a2uiLoadOnOpen;

class A2uiWorkspace extends StatefulWidget {
  const A2uiWorkspace({super.key});

  @override
  State<A2uiWorkspace> createState() => _A2uiWorkspaceState();
}

class _A2uiWorkspaceState extends State<A2uiWorkspace> {
  String? _app;
  String _title = '';
  bool _busy = false;
  WebViewController? _controller;
  final _refineCtl = TextEditingController();
  final List<String> _notes = [];

  @override
  void initState() {
    super.initState();
    if (!_wkRegistered) {
      WebKitWebViewPlatform.registerWith();
      _wkRegistered = true;
    }
    if (a2uiLoadOnOpen != null) {
      _app = a2uiLoadOnOpen;
      a2uiLoadOnOpen = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _mount(_app!);
        setState(() {});
      });
    }
  }

  AppStore get store => context.read<AppStore>();

  void _mount(String name) {
    final api = store.api;
    if (api == null) return;
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..loadRequest(Uri.parse(api.a2uiPageUrl(name)));
  }

  Future<void> _create() async {
    final nameCtl = TextEditingController();
    final briefCtl = TextEditingController();
    final ok = await showNonDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ctx.palette.panel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text('生成小应用', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: ctx.palette.ink)),
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
    if (ok != true) return;
    final name = nameCtl.text.trim();
    final brief = briefCtl.text.trim();
    final api = store.api;
    final s = store.settings;
    if (name.isEmpty || brief.isEmpty || api == null) return;
    if (s.apiKey.isEmpty) {
      _toast('先配置模型', 'A2UI 生成需要 API Key。');
      return;
    }
    setState(() => _busy = true);
    try {
      final res = await api.a2uiGenerate(
        name: name, brief: brief,
        model: s.modelId, baseUrl: s.baseUrl, apiKey: s.apiKey,
      );
      if (res['ok'] == true) {
        setState(() {
          _app = name;
          _title = brief;
          _notes.add('已生成（${res['bytes']} 字节）');
        });
        _mount(name);
        _toast('小应用已生成', '点动画可以加速；下方输入框可继续修改。');
      } else {
        _toast('生成被拒', '${res['detail']}');
      }
    } catch (e) {
      _toast('生成失败', '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refine(String instruction) async {
    final api = store.api;
    final s = store.settings;
    if (api == null || _app == null || instruction.trim().isEmpty) return;
    setState(() => _busy = true);
    try {
      final res = await api.a2uiRefine(
        name: _app!, instruction: instruction.trim(),
        model: s.modelId, baseUrl: s.baseUrl, apiKey: s.apiKey,
      );
      if (res['ok'] == true) {
        _controller?.loadRequest(Uri.parse(api.a2uiPageUrl(_app!))); // reload = 热更新
        setState(() => _notes.add('已修改：${instruction.trim()}'));
        _toast('已热更新', '预览已重载（${res['bytes']} 字节）。');
      } else {
        // fail-closed：覆盖被拒时旧版仍在（热更新无损坏风险）。
        _toast('修改被拒', '${res['detail']}');
      }
    } catch (e) {
      _toast('修改失败', '$e');
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
    return Column(
      children: [
        Container(
          height: 46,
          decoration: BoxDecoration(color: p.bgElevated, border: Border(bottom: BorderSide(color: p.line))),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(children: [
            Icon(Icons.auto_fix_high_outlined, size: 17, color: p.accent),
            const SizedBox(width: 8),
            Text(_app == null ? 'A2UI 小应用' : 'A2UI · $_app', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: p.ink)),
            const SizedBox(width: 10),
            Text('自包含动画 HTML · 覆盖即热更新', style: TextStyle(fontSize: 11, color: p.ink4)),
            const Spacer(),
            if (_busy) SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.8, color: p.accent)),
            const SizedBox(width: 8),
            _TopBtn(icon: Icons.add, label: '新建', onTap: _busy ? null : _create),
            if (_app != null)
              _TopBtn(
                icon: Icons.refresh,
                label: '重载',
                onTap: () => _controller?.loadRequest(Uri.parse(store.api!.a2uiPageUrl(_app!))),
              ),
          ]),
        ),
        Expanded(
          child: _app == null
              ? _EmptyA2ui(onCreate: _create)
              : Column(children: [
                  Expanded(child: _controller == null ? const Center(child: Text('加载中…')) : WebViewWidget(controller: _controller!)),
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

class _EmptyA2ui extends StatelessWidget {
  const _EmptyA2ui({required this.onCreate});
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.auto_fix_high_outlined, size: 44, color: p.ink4),
        const SizedBox(height: 14),
        Text('A2UI 小应用', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: p.ink)),
        const SizedBox(height: 6),
        SizedBox(
          width: 400,
          child: Text(
            '一句话生成自成一体的小应用：动画、演示、可玩的交互。\n'
            '自包含单 HTML——离线可用、覆盖即热更新、生成即进作品集。\n'
            '适合快速做出可分享的动画小件与演示组件。',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: p.ink3, height: 1.7),
          ),
        ),
        const SizedBox(height: 18),
        FilledButton.icon(
          onPressed: onCreate,
          icon: const Icon(Icons.add, size: 16),
          label: const Text('生成第一个小应用'),
        ),
      ]),
    );
  }
}

class _TopBtn extends StatelessWidget {
  const _TopBtn({required this.icon, required this.label, this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 14, color: onTap == null ? p.ink4 : p.ink2),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(fontSize: 12, color: onTap == null ? p.ink4 : p.ink2)),
          ]),
        ),
      ),
    );
  }
}

/// JSON 调试辅助（notes 序列化）。
String a2uiNotesJson(List<String> notes) => jsonEncode(notes.map((n) => {'note': n}).toList());
