import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import '../core/store.dart';
import '../core/theme.dart';
import 'common.dart';

/// 轨道 C：3D 制作工作台。**应用内 WebView 即执行面**（不引外部浏览器）：
/// 服务器实时 serve 的 three.js 预览页经 JavaScriptChannel 回传三反馈
/// （执行错误 / 场景测量 / 截图），驱动 img2threejs 式分 pass 修复轮。
/// webview_flutter 无 endorsed macOS 实现——首次使用前幂等注册 WebKit。
bool _wkRegistered = false;

const _passLabels = {
  'blockout': '占位',
  'structure': '结构',
  'form': '造型',
  'material': '材质',
  'lighting': '灯光',
  'interaction': '交互',
  'done': '完成',
};

class ThreeWorkspace extends StatefulWidget {
  const ThreeWorkspace({super.key});

  @override
  State<ThreeWorkspace> createState() => _ThreeWorkspaceState();
}

class _ThreeWorkspaceState extends State<ThreeWorkspace> {
  String? _project;
  Map<String, dynamic>? _state;
  Map<String, dynamic>? _spec;
  String _sceneJs = '';
  bool _showSource = false;
  bool _busy = false;
  WebViewController? _controller;
  String _lastError = '';

  @override
  void initState() {
    super.initState();
    if (!_wkRegistered) {
      WebKitWebViewPlatform.registerWith();
      _wkRegistered = true;
    }
  }

  AppStore get store => context.read<AppStore>();

  Future<void> _refresh() async {
    if (_project == null) return;
    final api = store.api;
    if (api == null) return;
    try {
      final res = await api.threeProject(_project!);
      if (res['ok'] == true) {
        if (!mounted) return;
        setState(() {
          _state = (res['state'] as Map?)?.cast<String, dynamic>();
          _spec = (res['spec'] as Map?)?.cast<String, dynamic>();
          _sceneJs = (res['scene_js'] as String?) ?? '';
        });
      }
    } catch (_) {}
  }

  Future<void> _createProject() async {
    final nameCtl = TextEditingController();
    final briefCtl = TextEditingController();
    final ok = await showNonDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ctx.palette.panel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text('新建 3D 项目', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: ctx.palette.ink)),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: nameCtl,
              decoration: InputDecoration(labelText: '项目名（字母数字-下划线）', hintText: 'saturn-demo'),
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: briefCtl,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: '一句话目标',
                hintText: '做一个带环行星自转的演示场景',
                alignLabelWithHint: true,
              ),
              style: const TextStyle(fontSize: 13),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('生成规范')),
        ],
      ),
    );
    if (ok != true) return;
    final name = nameCtl.text.trim();
    final brief = briefCtl.text.trim();
    if (name.isEmpty || brief.isEmpty) return;
    final api = store.api;
    final s = store.settings;
    if (api == null || s.baseUrl.isEmpty || s.apiKey.isEmpty) {
      _toast('先在设置里配好模型连接', '3D 生成使用当前选中的模型。');
      return;
    }
    setState(() => _busy = true);
    try {
      final res = await api.threeNewProject(
        name: name, brief: brief,
        model: s.modelId, baseUrl: s.baseUrl, apiKey: s.apiKey, thinkingLevel: s.thinkingLevel,
      );
      if (res['ok'] == true) {
        if (!mounted) return;
        setState(() {
          _project = name;
          _spec = (res['spec'] as Map?)?.cast<String, dynamic>();
          _state = (res['state'] as Map?)?.cast<String, dynamic>();
          _lastError = '';
        });
        _mountPreview();
        _toast('规范已生成（${(_spec?['components'] as List?)?.length ?? 0} 组件）', '点「生成当前层」开始 blockout。');
      } else {
        _toast('创建失败', '${res['detail']}');
      }
    } catch (e) {
      _toast('创建失败', e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _mountPreview() {
    final api = store.api;
    if (api == null || _project == null) return;
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel('NON3D', onMessageReceived: _onBridgeMessage)
      ..loadRequest(Uri.parse(api.threePreviewUrl(_project!)));
  }

  /// 三反馈桥（WebView → 服务器 → build-state）：error 加修复轮、
  /// metrics 记录、screenshot 落盘 evidence/。
  Future<void> _onBridgeMessage(JavaScriptMessage msg) async {
    final api = store.api;
    if (api == null || _project == null) return;
    try {
      final data = jsonDecode(msg.message) as Map<String, dynamic>;
      final kind = data['kind'] as String? ?? '';
      if (kind == 'error') {
        final m = data['message']?.toString() ?? '';
        if (m == _lastError) return; // 同错误去重（onerror 每帧触发会刷屏）
        _lastError = m;
        await api.threeFeedback(_project!, 'error', m);
      } else if (kind == 'metrics') {
        await api.threeFeedback(_project!, 'metrics', data['payload']);
      } else if (kind == 'screenshot') {
        await api.threeFeedback(_project!, 'screenshot', data['payload']);
      }
      await _refresh();
    } catch (_) {}
  }

  Future<void> _runPass() async {
    final api = store.api;
    final s = store.settings;
    if (api == null || _project == null) return;
    setState(() => _busy = true);
    try {
      final res = await api.threeRunPass(
        name: _project!, model: s.modelId, baseUrl: s.baseUrl,
        apiKey: s.apiKey, thinkingLevel: s.thinkingLevel,
      );
      if (res['ok'] == true) {
        _controller?.loadRequest(Uri.parse(api.threePreviewUrl(_project!))); // reload 即迭代
        await _refresh();
        _toast('已生成「${_passLabels[res['pass']] ?? res['pass']}」层', '预览已刷新；出错会自动记修复轮。');
      } else {
        _toast('生成被拒', '${res['detail']}');
        await _refresh();
      }
    } catch (e) {
      _toast('生成失败', e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _continue() async {
    final api = store.api;
    if (api == null || _project == null) return;
    try {
      final res = await api.threeContinue(_project!, '客户端确认');
      if (res['ok'] == true) {
        await _refresh();
        if (res['done'] == true) {
          _toast('全部层通过 🎉', '项目完成。');
        } else {
          _toast('进入「${_passLabels[res['current']] ?? res['current']}」层', '点「生成当前层」继续。');
        }
      }
    } catch (e) {
      _toast('推进被拒', e.toString());
    }
  }

  void _toast(String title, String detail) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(title)));
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final current = _state?['current'] as String? ?? '';
    final passes = (_state?['passes'] as List?)?.cast<Map>() ?? const [];
    return Column(
      children: [
        // 顶栏：pass 状态机 + 操作
        Container(
          height: 46,
          decoration: BoxDecoration(color: p.bgElevated, border: Border(bottom: BorderSide(color: p.line))),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(children: [
            Icon(Icons.view_in_ar_outlined, size: 17, color: p.accent),
            const SizedBox(width: 8),
            Text(_project ?? '3D 工作台', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: p.ink)),
            const SizedBox(width: 14),
            if (passes.isNotEmpty)
              for (final ps in passes)
                Padding(
                  padding: const EdgeInsets.only(right: 5),
                  child: _PassChip(
                    label: _passLabels[ps['id']] ?? '${ps['id']}',
                    status: '${ps['status']}',
                    active: ps['id'] == current,
                    palette: p,
                  ),
                ),
            const Spacer(),
            if (_busy) SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.8, color: p.accent)),
            const SizedBox(width: 8),
            _TopBtn(icon: Icons.auto_awesome_outlined, label: '生成当前层', onTap: _busy || _project == null ? null : _runPass),
            _TopBtn(icon: Icons.camera_alt_outlined, label: '截图', onTap: _project == null ? null : () => _controller?.runJavaScript('window.__non3d_screenshot && window.__non3d_screenshot()')),
            _TopBtn(icon: Icons.check_rounded, label: '通过并继续', onTap: _busy || _project == null ? null : _continue),
            _TopBtn(icon: Icons.refresh, label: '刷新预览', onTap: _project == null ? null : () => _controller?.loadRequest(Uri.parse(store.api!.threePreviewUrl(_project!)))),
            _TopBtn(
              icon: _showSource ? Icons.visibility_outlined : Icons.code_outlined,
              label: _showSource ? '预览' : '源码',
              onTap: _project == null ? null : () => setState(() => _showSource = !_showSource),
            ),
          ]),
        ),
        Expanded(
          child: _project == null
              ? _EmptyNew(onCreate: _createProject, busy: _busy)
              : _showSource
                  ? SingleChildScrollView(
                      padding: const EdgeInsets.all(14),
                      child: SelectableText(
                        _sceneJs.isEmpty ? '// 尚无 scene.js——点「生成当前层」' : _sceneJs,
                        style: TextStyle(fontSize: 12, fontFamily: 'monospace', color: p.ink2, height: 1.5),
                      ),
                    )
                  : (_controller == null
                      ? const Center(child: Text('加载预览…'))
                      : WebViewWidget(controller: _controller!)),
        ),
      ],
    );
  }
}

class _EmptyNew extends StatelessWidget {
  const _EmptyNew({required this.onCreate, required this.busy});
  final VoidCallback onCreate;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.view_in_ar_outlined, size: 44, color: p.ink4),
        const SizedBox(height: 14),
        Text('直接制作 3D', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: p.ink)),
        const SizedBox(height: 6),
        SizedBox(
          width: 380,
          child: Text(
            '一句话目标 → 规范先行（组件/材质/相机/验收标准）→ 分层生成\n'
            '占位 → 结构 → 造型 → 材质 → 灯光 → 交互，应用内实时预览，\n'
            '执行错误/测量/截图三反馈自动驱动修复轮。',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: p.ink3, height: 1.7),
          ),
        ),
        const SizedBox(height: 18),
        FilledButton.icon(
          onPressed: busy ? null : onCreate,
          icon: const Icon(Icons.add, size: 16),
          label: const Text('新建 3D 项目'),
        ),
      ]),
    );
  }
}

class _PassChip extends StatelessWidget {
  const _PassChip({required this.label, required this.status, required this.active, required this.palette});
  final String label;
  final String status;
  final bool active;
  final NonPalette palette;

  @override
  Widget build(BuildContext context) {
    final (color, bg) = switch (status) {
      'verified' => (palette.success, palette.success.withValues(alpha: 0.15)),
      'failed' || 'blocked' => (palette.warn, palette.warn.withValues(alpha: 0.15)),
      'generated' => (palette.accent, palette.accentSoft),
      _ => (palette.ink4, palette.panel2),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: active ? bg : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: active ? color : palette.line),
      ),
      child: Text(label, style: TextStyle(fontSize: 11, fontWeight: active ? FontWeight.w700 : FontWeight.w500, color: active ? color : palette.ink4)),
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
