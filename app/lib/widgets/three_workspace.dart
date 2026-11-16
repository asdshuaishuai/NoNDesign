import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import '../core/keys.dart';
import '../core/store.dart';
import '../core/theme.dart';
import 'common.dart';

/// 轨道 C：3D 制作工作台。**应用内 WebView 即执行面**（不引外部浏览器）：
/// 服务器实时 serve 的 three.js 预览页经 JavaScriptChannel 回传三反馈
/// （执行错误 / 场景测量 / 截图），驱动 img2threejs 式分 pass 修复轮。
/// webview_flutter 无 endorsed macOS 实现——首次使用前幂等注册 WebKit。
bool _wkRegistered = false;

/// 作品集「打开」直载：切视图前设置，ThreeWorkspace.initState 消费后清空
/// （与 hotAppLoadOnOpen 同构的跨实例传名通道）。
String? threeLoadOnOpen;

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
  // 面板三态：预览 / 源码 / 规范（规范手编 = img2threejs 的 refine-spec 面）。
  String _face = 'preview';
  final _specCtl = TextEditingController();
  // 规范编辑守卫：_refresh 被每条桥消息与每次 _runPass 调用——用户在
  // refine-spec 面未保存的 JSON 编辑不能被服务器 spec 静默覆盖；保存
  // 成功（用户显式期待服务器态回灌）后重置守卫恢复正常同步。
  bool _specDirty = false;
  bool _busy = false;
  WebViewController? _controller;
  String _lastError = '';
  // 缓存 store：dispose 里保存规范草稿时不能再 context.read（元素已停用）。
  late final AppStore _store = context.read<AppStore>();

  @override
  void dispose() {
    // 未保存的规范编辑跨视图保留（按项目名持久化草稿）——工作台切换即
    // dispose，没有草稿 = 用户手编的 JSON 静默丢失。持久化延后到帧末：
    // dispose 常发生在构建期，notifyListeners 会标记祖先脏。
    _stashDraft(defer: true);
    _specCtl.dispose();
    super.dispose();
  }

  /// 把当前项目未保存的规范编辑落进草稿（项目切换/视图 dispose 边界）。
  void _stashDraft({bool defer = false}) {
    final p = _project;
    if (p == null || !_specDirty || _specCtl.text.trim().isEmpty) return;
    final text = _specCtl.text;
    if (defer) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _store.setThreeSpecDraft(p, text));
    } else {
      _store.setThreeSpecDraft(p, text);
    }
  }

  @override
  void initState() {
    super.initState();
    if (!_wkRegistered) {
      WebKitWebViewPlatform.registerWith();
      _wkRegistered = true;
    }
    _specCtl.addListener(() => _specDirty = true);
    // 视图切换会 dispose 本工作台——优先消费作品集直载的项目名，其次
    // 从持久化项目名续接（跨会话亦然）。
    // 续接路径必须挂载 WebView（与创建路径同路）：否则预览永久停在
    // 「加载预览…」，截图/四方位/刷新全是 _controller?. 空安全无操作，
    // error/metrics/screenshot 三反馈桥断链。
    final pending = threeLoadOnOpen;
    threeLoadOnOpen = null;
    final saved = pending ?? store.settings.threeProjectName;
    if (saved.isNotEmpty) {
      _project = saved;
      final draft = store.threeSpecDraft(saved);
      if (draft != null && draft.isNotEmpty) {
        _specCtl.text = draft;
        _specDirty = true; // listener 已置位；显式声明防 _refresh 覆盖
      }
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        // 持久化推迟到首帧后：initState 里 notifyListeners 会在构建期
        // 触发祖先重建（setState during build）。
        if (pending != null) store.setThreeProjectName(pending);
        await _refresh();
        if (!mounted || _controller != null) return; // 创建路径已挂载不双挂
        _mountPreview();
        setState(() {});
      });
    }
  }

  AppStore get store => _store;

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
          if (!_specDirty) {
            _specCtl.text = const JsonEncoder.withIndent('  ').convert(_spec);
            _specDirty = false; // listener 在文本赋值时已置位，恢复未脏
          }
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
    // 弹窗打开期间视图可能已被切走（根级 ⌘1–⌘7 不让位浮层，Workspace
    // 重建即 dispose 本 State）——await 之后必须先验 mounted 再 setState。
    if (!mounted) return;
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
        _stashDraft(); // 旧项目未保存的规范编辑先存草稿
        setState(() {
          _project = name;
          _spec = (res['spec'] as Map?)?.cast<String, dynamic>();
          _state = (res['state'] as Map?)?.cast<String, dynamic>();
          _lastError = '';
          _specDirty = false;
        });
        store.setThreeProjectName(name);
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
        await api.threeFeedback(_project!, 'screenshot',
            {'data': data['payload'], 'tag': data['tag'] ?? 'shot'});
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

  /// 项目新建/切换：列出服务器 3D 项目（含当前标记），或新建覆盖当前会话项目。
  Future<void> _pickProject() async {
    final api = store.api;
    if (api == null) return;
    try {
      final res = await api.threeProjects();
      final items = ((res['projects'] as List?) ?? []).cast<Map>();
      final choice = await showNonDialog<String>(
        context: context,
        builder: (ctx) => SimpleDialog(
          backgroundColor: ctx.palette.panel,
          title: Text('3D 项目', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: ctx.palette.ink)),
          children: [
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, '__new__'),
              child: Row(children: [Icon(Icons.add, size: 16, color: ctx.palette.accent), const SizedBox(width: 8), const Text('新建项目…')]),
            ),
            for (final it in items)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, it['name'] as String),
                child: Row(children: [
                  Icon(it['name'] == _project ? Icons.check : (it['blocked'] == true ? Icons.block : Icons.view_in_ar_outlined),
                      size: 15, color: it['name'] == _project ? ctx.palette.accent : (it['blocked'] == true ? ctx.palette.warn : ctx.palette.ink3)),
                  const SizedBox(width: 8),
                  Text('${it['name']}（${_passLabels[it['current']] ?? it['current']}）', style: const TextStyle(fontSize: 13)),
                ]),
              ),
          ],
        ),
      );
      if (choice == null) return;
      // 弹窗打开期间视图可能已被切走（根级 ⌘1–⌘7 不让位浮层）——await
      // showNonDialog 之后先验 mounted：死 State 上 setState 在 debug 抛
      // FlutterError 且被外层 catch 吞成「项目切换静默失效」。__new__ 分支
      // 同样要挡（_createProject 会再 showNonDialog(context)，死 context 崩）。
      if (!mounted) return;
      if (choice == '__new__') {
        await _createProject();
        return;
      }
      if (choice == _project) return;
      _stashDraft(); // 旧项目未保存的规范编辑先存草稿
      final draft = store.threeSpecDraft(choice);
      setState(() {
        _project = choice;
        _lastError = '';
        // 项目边界复位规范编辑守卫：A 项目未保存的规范编辑不能带进 B——
        // 不复位会让 _refresh 跳过回灌，编辑器停在 A 的 JSON，_saveSpec
        // 却把 A 内容以 B 的名义落盘（标题已显示 B，全程无提示）。
        // B 自己的草稿（若有）显式回灌，无草稿则等 _refresh 回服务器态。
        _specDirty = false;
        if (draft != null && draft.isNotEmpty) {
          _specCtl.text = draft;
          _specDirty = true;
        }
      });
      store.setThreeProjectName(choice);
      _mountPreview();
      await _refresh();
    } catch (e) {
      _toast('项目列表失败', '$e');
    }
  }

  /// 规范手编回灌（客户端先验 JSON，服务器再过 components/acceptance 门）。
  Future<void> _saveSpec() async {
    final api = store.api;
    if (api == null || _project == null) return;
    Map<String, dynamic> parsed;
    try {
      parsed = (jsonDecode(_specCtl.text) as Map).cast<String, dynamic>();
    } catch (e) {
      _toast('JSON 解析失败', '$e');
      return;
    }
    try {
      final res = await api.postJson('/three/spec/save', {'name': _project, 'spec': parsed});
      if (res['ok'] == true) {
        _toast('规范已回灌', '后续生成层将使用新规范（refine-spec）');
        _specDirty = false; // 显式保存 = 期待服务器态回灌，恢复同步
        store.setThreeSpecDraft(_project!, null); // 服务器已收下，草稿作废
        await _refresh();
      } else {
        _toast('保存被拒', '${res['detail']}');
      }
    } catch (e) {
      _toast('保存失败', '$e');
    }
  }

  PopupMenuItem<String> _menuItem(BuildContext context, String value, IconData icon, String label) {
    final p = context.palette;
    return PopupMenuItem<String>(
      value: value,
      height: 36,
      child: Row(children: [
        Icon(icon, size: 16, color: p.ink3),
        const SizedBox(width: 8),
        Text(label, style: const TextStyle(fontSize: 13)),
      ]),
    );
  }

  void _toast(String title, String detail) {
    // 失败原因必须可见（此前 detail 形参被丢弃，错误只弹标题无法诊断）。
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
    final current = _state?['current'] as String? ?? '';
    final passes = (_state?['passes'] as List?)?.cast<Map>() ?? const [];
    final size = MediaQuery.sizeOf(context);
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      final phone = width < 700;
      // iPad 竖屏（及窄高窗口）走双行工具栏：状态一行、动作一行，
      // 动作行横向滚动；横屏/桌面单行，主操作保留文字，次操作收进菜单。
      final padPortrait = !phone && width < 1100 && size.height >= size.width;
      return Column(children: [
        _header(context, p, current, passes,
            width: width, phone: phone, padPortrait: padPortrait),
        Expanded(child: _body(context, p, width: width)),
      ]);
    });
  }

  Widget _header(BuildContext context, NonPalette p, String current, List<Map> passes,
      {required double width, required bool phone, required bool padPortrait}) {
    final decoration = BoxDecoration(
        color: p.bgElevated, border: Border(bottom: BorderSide(color: p.line)));
    if (phone) {
      return Container(
        key: const ValueKey('three-header-phone'),
        height: 46,
        decoration: decoration,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(children: [
          _backButton(p),
          ..._titleBits(p, 110),
          const Spacer(),
          if (_busy) ..._busyBits(p),
          _menuButton(context, p, landscape: false),
        ]),
      );
    }
    if (padPortrait) {
      return Container(
        key: const ValueKey('three-header-portrait'),
        decoration: decoration,
        child: Column(children: [
          SizedBox(
            height: 44,
            child: Row(children: [
              Padding(padding: const EdgeInsets.only(left: 8), child: _backButton(p)),
              ..._titleBits(p, 230),
              const SizedBox(width: 10),
              Expanded(
                child: passes.isEmpty ? const SizedBox.shrink() : _passScroll(p, current, passes),
              ),
              if (_busy) ..._busyBits(p),
              const SizedBox(width: 8),
            ]),
          ),
          Container(
            height: 44,
            decoration: BoxDecoration(border: Border(top: BorderSide(color: p.line))),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(children: [
                ..._primaryActions(p, includeAll: true),
                ..._faceActions(p),
              ]),
            ),
          ),
        ]),
      );
    }
    final all = width >= 1100;
    return Container(
      key: const ValueKey('three-header-landscape'),
      height: 46,
      decoration: decoration,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(children: [
        _backButton(p),
        ..._titleBits(p, all ? 260 : 220),
        const SizedBox(width: 12),
        Expanded(
          child: passes.isEmpty ? const SizedBox.shrink() : _passScroll(p, current, passes),
        ),
        if (_busy) ..._busyBits(p),
        if (all) ...[
          ..._primaryActions(p, includeAll: true),
          ..._faceActions(p),
        ] else ...[
          ..._primaryActions(p, includeAll: false),
          _menuButton(context, p, landscape: true),
        ],
      ]),
    );
  }

  Widget _backButton(NonPalette p) => IconButton(
        icon: const Icon(Icons.arrow_back, size: 18),
        tooltip: '返回设计 ${modCombo('⌘1')}',
        color: p.ink2,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        onPressed: () => store.setView('design'),
      );

  List<Widget> _titleBits(NonPalette p, double maxWidth) => [
        const SizedBox(width: 4),
        Icon(Icons.view_in_ar_outlined, size: 17, color: p.accent),
        const SizedBox(width: 8),
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Text(_project ?? '3D 工作台',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: p.ink)),
        ),
      ];

  List<Widget> _busyBits(NonPalette p) => [
        SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.8, color: p.accent)),
        const SizedBox(width: 8),
      ];

  Widget _passScroll(NonPalette p, String current, List<Map> passes) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
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
        ]),
      );

  List<Widget> _primaryActions(NonPalette p, {required bool includeAll}) => [
        _TopBtn(icon: Icons.folder_open_outlined, label: '项目', onTap: _busy ? null : () => _pickProject()),
        _TopBtn(icon: Icons.auto_awesome_outlined, label: '生成当前层', onTap: _busy || _project == null ? null : _runPass),
        if (includeAll) ...[
          _TopBtn(
              icon: Icons.camera_alt_outlined,
              label: '截图',
              onTap: _project == null
                  ? null
                  : () => _controller?.runJavaScript('window.__non3d_screenshot && window.__non3d_screenshot()')),
          _TopBtn(
              icon: Icons.rotate_90_degrees_ccw_outlined,
              label: '四方位取证',
              onTap: _project == null
                  ? null
                  : () => _controller?.runJavaScript('window.__non3d_turntable && window.__non3d_turntable()')),
        ],
        _TopBtn(icon: Icons.check_rounded, label: '通过并继续', onTap: _busy || _project == null ? null : _continue),
        if (includeAll)
          _TopBtn(
              icon: Icons.refresh,
              label: '刷新预览',
              onTap: _project == null
                  ? null
                  : () => _controller?.loadRequest(Uri.parse(store.api!.threePreviewUrl(_project!)))),
      ];

  List<Widget> _faceActions(NonPalette p) => [
        for (final f in const [
          ('preview', '预览', Icons.visibility_outlined),
          ('source', '源码', Icons.code_outlined),
          ('spec', '规范', Icons.rule_outlined),
        ])
          _TopBtn(
            icon: f.$3,
            label: f.$2,
            active: _face == f.$1,
            onTap: _project == null ? null : () => setState(() => _face = f.$1),
          ),
      ];

  Widget _menuButton(BuildContext context, NonPalette p, {required bool landscape}) {
    return PopupMenuButton<String>(
      tooltip: '3D 操作',
      color: p.panel,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10), side: BorderSide(color: p.lineStrong)),
      onSelected: _handleAction,
      itemBuilder: (ctx) => [
        _menuItem(ctx, 'project', Icons.folder_open_outlined, '项目'),
        _menuItem(ctx, 'pass', Icons.auto_awesome_outlined, '生成当前层'),
        _menuItem(ctx, 'shot', Icons.camera_alt_outlined, '截图'),
        _menuItem(ctx, 'turntable', Icons.rotate_90_degrees_ccw_outlined, '四方位取证'),
        _menuItem(ctx, 'continue', Icons.check_rounded, '通过并继续'),
        _menuItem(ctx, 'reload', Icons.refresh, '刷新预览'),
        const PopupMenuDivider(),
        _menuItem(ctx, 'face:preview', Icons.visibility_outlined, landscape ? '预览（全屏）' : '预览'),
        _menuItem(ctx, 'face:source', Icons.code_outlined, landscape ? '源码（侧栏）' : '源码'),
        _menuItem(ctx, 'face:spec', Icons.rule_outlined, landscape ? '规范（侧栏）' : '规范'),
      ],
    );
  }

  void _handleAction(String v) {
    switch (v) {
      case 'project':
        _pickProject();
      case 'pass':
        _runPass();
      case 'shot':
        _controller?.runJavaScript('window.__non3d_screenshot && window.__non3d_screenshot()');
      case 'turntable':
        _controller?.runJavaScript('window.__non3d_turntable && window.__non3d_turntable()');
      case 'continue':
        _continue();
      case 'reload':
        if (_project != null) {
          _controller?.loadRequest(Uri.parse(store.api!.threePreviewUrl(_project!)));
        }
      case 'face:preview':
      case 'face:source':
      case 'face:spec':
        if (_project != null) setState(() => _face = v.substring('face:'.length));
    }
  }

  Widget _body(BuildContext context, NonPalette p, {required double width}) {
    if (_project == null) {
      return _EmptyNew(onCreate: _createProject, busy: _busy);
    }
    final preview = _controller == null
        ? const Center(child: Text('加载预览…'))
        : WebViewWidget(controller: _controller!);
    final side = switch (_face) {
      'source' => SingleChildScrollView(
          padding: const EdgeInsets.all(14),
          child: SelectableText(
            _sceneJs.isEmpty ? '// 尚无 scene.js——点「生成当前层」' : _sceneJs,
            style: TextStyle(fontSize: 12, fontFamily: 'monospace', color: p.ink2, height: 1.5),
          ),
        ),
      'spec' => _SpecPane(controller: _specCtl, onSave: _saveSpec),
      _ => null,
    };
    // 横屏/桌面：源码/规范是预览的侧栏，不把预览整块替换掉；
    // 竖屏/手机：保持单面切换（宽度不足，并排会两张都不可读）。
    if (width >= 900 && side != null) {
      final sideWidth = (width * 0.36).clamp(320.0, 460.0).toDouble();
      return Row(
        key: const ValueKey('three-body-split'),
        children: [
          Expanded(child: preview),
          Container(width: 1, color: p.line),
          SizedBox(width: sideWidth, child: side),
        ],
      );
    }
    return side ?? preview;
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
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Text(
              '一句话目标 → 规范先行（组件/材质/相机/验收标准）→ 分层生成\n'
              '占位 → 结构 → 造型 → 材质 → 灯光 → 交互，应用内实时预览，\n'
              '执行错误/测量/截图三反馈自动驱动修复轮。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: p.ink3, height: 1.7),
            ),
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
  const _TopBtn({required this.icon, required this.label, this.onTap, this.active = false});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final color = onTap == null ? p.ink4 : (active ? p.accent : p.ink2);
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: active
              ? BoxDecoration(color: p.accentSoft, borderRadius: BorderRadius.circular(7))
              : null,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(fontSize: 12, color: color)),
          ]),
        ),
      ),
    );
  }
}


/// 规范手编面板：编辑 three-spec.json → 回灌（refine-spec 纪律面）。
class _SpecPane extends StatelessWidget {
  const _SpecPane({required this.controller, required this.onSave});
  final TextEditingController controller;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
        child: Row(children: [
          Text('three-spec.json', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: p.ink2, fontFamily: 'monospace')),
          const Spacer(),
          OutlinedButton.icon(
            onPressed: onSave,
            icon: const Icon(Icons.save_outlined, size: 14),
            label: const Text('回灌规范', style: TextStyle(fontSize: 12)),
          ),
        ]),
      ),
      Expanded(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: TextField(
            controller: controller,
            maxLines: null,
            expands: true,
            style: TextStyle(fontSize: 12, fontFamily: 'monospace', color: p.ink2, height: 1.5),
            decoration: InputDecoration(
              filled: true,
              fillColor: p.panel2,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: p.line)),
            ),
          ),
        ),
      ),
    ]);
  }
}
