import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import '../core/api.dart';
import '../core/api_nonapp.dart';
import '../core/store.dart';
import '../core/theme.dart';
import 'common.dart';
import 'nonapp_import.dart';
import 'nonapp_viewer.dart';

/// NoN 热应用工作台（灵闪/Dots 式自成一体应用）：一句话 → LLM 生成
/// **自包含动画 HTML**（全内联零外链，canvas/SVG/CSS keyframes）→
/// WebView 即运行时（离线可用）；对话式修改 = 覆盖文件 + reload 即热更新。
/// 业务数据经注入的 `window.NoN.db.exec` 落 SQLite（每应用一个 app.db）。
/// 生成的热应用自动登记进作品集。
///
/// v1 质量环 = 服务端结构/外链校验 + WebView onerror/unhandledrejection
/// 经 NONHOTAPP 桥回传（服务端在 `</body>` 前注入包装脚本）；视觉截图 v2。
///
/// 文件即应用 v2：`.nonapp` 包（html / a2ui 双载荷）可导入导出；无服务器时
/// html 载荷落本地缓存经 file:// 打开（SQLite 桥降级，横幅常驻明示）。
bool _wkRegistered = false;

/// 作品集「打开」直载：切视图前设置，HotAppWorkspace.initState 消费后清空
/// （registry builder 无参，跨实例传名的轻量通道）。
String? hotAppLoadOnOpen;

/// 离线 html 缓存文件路径（file:// 打开）：与 [hotAppLoadOnOpen] **两域分离**
/// ——后者只承载应用名（服务端托管），这里只承载本机缓存文件。
String? hotAppOfflinePath;

/// WebView 导航白名单（review nonapp-5）：只放行
///   ① 离线缓存 `file://`
///   ② `about:`（WebView 内部空页）
///   ③ 桌面服务同源页（`<baseUrl>/hotapp/page/*`，host+port 比对）
///
/// 其余 scheme/主机一律 prevent。离线页的静态「零外链」扫描覆盖不到 JS
/// 字符串拼接/编码的地址，CSP meta 挡请求与资源，这里挡的是整页导航
/// （页面脚本把 WebView 带到远端页面 = 跳出本应用的执行面）。
bool hotAppNavigationAllowed(String url, {String? baseUrl}) {
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  if (uri.scheme == 'file' || uri.scheme == 'about') return true;
  if (uri.scheme != 'http' && uri.scheme != 'https') return false;
  final base = (baseUrl ?? '').trim();
  if (base.isEmpty) return false;
  final origin = Uri.tryParse(base);
  if (origin == null || origin.host.isEmpty) return false;
  return uri.host == origin.host && uri.port == origin.port;
}

class HotAppWorkspace extends StatefulWidget {
  const HotAppWorkspace({super.key});

  @override
  State<HotAppWorkspace> createState() => _HotAppWorkspaceState();
}

class _HotAppWorkspaceState extends State<HotAppWorkspace> {
  String? _app;

  /// 离线缓存文件（file:// 打开的 html 载荷）；非空即离线模式。
  String? _offlinePath;
  String _title = '';
  bool _busy = false;
  WebViewController? _controller;
  final _refineCtl = TextEditingController();
  final List<String> _notes = [];
  /// 页面运行错误（window.onerror / unhandledrejection / 资源加载失败）：
  /// 显示为可读条，一键填入 refine 输入框（错误进入修改闭环）。
  String _lastError = '';

  /// didChangeDependencies 里绑定的 store（dispose 时解绑监听）。
  AppStore? _store;

  @override
  void initState() {
    super.initState();
    // WebKit 实现只有 macOS/iOS 有（webview_flutter 4.14.1 平台声明）：
    // 无条件 registerWith 会把 Android 的全局 WebViewPlatform 换成 WebKit，
    // 而 Android 只有 webview_flutter_android——平台错配。
    if (!_wkRegistered && (Platform.isMacOS || Platform.isIOS)) {
      WebKitWebViewPlatform.registerWith();
      _wkRegistered = true;
    }
    if (_consumeOpenRequests()) return;
    final saved = context.read<AppStore>().settings.hotappApp;
    if (saved.isNotEmpty) {
      _app = saved;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _app == null) return;
        _mount(_app!);
        setState(() {});
      });
    }
  }

  @override
  void didUpdateWidget(covariant HotAppWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 视图不变时的「打开 .nonapp」：workspace.dart 用未加 key 的 const
    // HotAppWorkspace 渲染同一 view，setView 只触发重建、不重建 State——
    // 全局通道若只在 initState 消费，已挂载的工作台会静默吞掉导入/离线打开
    // （工作台停在旧应用或空态）。这里补一次消费。
    if (_consumeOpenRequests()) setState(() {});
  }

  /// 消费跨实例的直载通道（hotAppLoadOnOpen / hotAppOfflinePath）。
  ///
  /// 返回 true = 有通道被消费（调用方据此决定是否 setState / 不再播种紧接的
  /// 设置恢复）。两个通道语义分离：名字走服务端托管，路径走 file:// 离线。
  bool _consumeOpenRequests() {
    final offline = hotAppOfflinePath;
    final pending = hotAppLoadOnOpen;
    if (offline == null && pending == null) return false;
    hotAppOfflinePath = null;
    hotAppLoadOnOpen = null;
    if (offline != null && offline.isNotEmpty) {
      _app = null;
      _offlinePath = offline;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _mountOffline(offline);
        setState(() {});
      });
      return true;
    }
    if (pending != null && pending.isNotEmpty) {
      _app = pending;
      _offlinePath = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _app == null) return;
        // 持久化推迟到首帧后：构建期 notifyListeners 会触发祖先重建。
        store.setHotApp(pending);
        _mount(_app!);
        setState(() {});
      });
      return true;
    }
    return false;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 监听 store：workspace.dart / registry 用**未加 key 的 const**
    // HotAppWorkspace 渲染同一 view，父级重建时控件实例 identical → Flutter
    // 直接跳过 updateChild，didUpdateWidget 根本不会触发。所以「视图不变时
    // 打开 .nonapp」只能靠 store 通知来消费通道（review nonapp-1）。
    final s = context.read<AppStore>();
    if (!identical(s, _store)) {
      _store?.removeListener(_onStoreNotify);
      _store = s;
      s.addListener(_onStoreNotify);
    }
  }

  @override
  void dispose() {
    _store?.removeListener(_onStoreNotify);
    _store = null;
    _refineCtl.dispose();
    _controller = null;
    super.dispose();
  }

  /// store 变化（setView / setHotApp …）：有跨实例打开请求就消费。
  void _onStoreNotify() {
    if (!mounted) return;
    // 构建/布局期回调里 setState 会抛「during build」：推到帧末。
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _consumeOpenRequests()) setState(() {});
      });
      return;
    }
    if (_consumeOpenRequests()) setState(() {});
  }

  AppStore get store => context.read<AppStore>();

  WebViewController _newController() => WebViewController()
    ..setJavaScriptMode(JavaScriptMode.unrestricted)
    ..addJavaScriptChannel('NONHOTAPP', onMessageReceived: _onBridgeMessage)
    ..setNavigationDelegate(NavigationDelegate(
      // 导航白名单：离线 file:// 与服务端同源页之外一律拦下（loadRequest /
      // loadFile 自身也过这里）。页面脚本仍可跑，但带不走 WebView
      // （review nonapp-5）。
      onNavigationRequest: (request) => hotAppNavigationAllowed(
              request.url, baseUrl: store.api?.baseUrl)
          ? NavigationDecision.navigate
          : NavigationDecision.prevent,
      onWebResourceError: (error) {
        if (!mounted) return;
        setState(() => _lastError =
            '页面加载失败：${error.description}（${error.errorCode}）');
      },
    ));

  /// 服务端托管路径：a2ui 载荷走原生 viewer（零 WebView），html 走 HTTP。
  Future<void> _mount(String name) async {
    final api = store.api;
    if (api == null) return;
    _lastError = '';
    try {
      final info = await api.hotAppInfo(name);
      // 回包晚于下一次 build：期间用户可能已切到别的应用/离线。只认当前
      // 目标，避免迟到回包把旧应用塞回控制器。
      if (!mounted || _app != name) return;
      if (info['exists'] == false) {
        setState(() => _lastError = '服务器上没有这个应用：$name');
        return;
      }
      if (info['renderer'] == 'a2ui') {
        await _openA2ui(name, info['title']?.toString() ?? name);
        return;
      }
    } catch (_) {
      // 老服务端没有 /hotapp/info：按 html 继续（向后兼容）
    }
    if (!mounted || _app != name) return;
    _offlinePath = null;
    _controller = _newController()..loadRequest(Uri.parse(api.hotAppPageUrl(name)));
    // 本方法自 async 化后赋值发生在 await 之后：没有这次 setState，回包
    // 晚于 build 时 UI 会停在「加载中…」或继续显示上一个应用的控制器。
    setState(() {});
  }

  /// 离线路径：本地缓存文件经 file:// 打开（无注入桥，SQLite 不可用）。
  void _mountOffline(String path) {
    _lastError = '';
    _controller = _newController()..loadFile(path);
  }

  Future<void> _openA2ui(String name, String title) async {
    final api = store.api;
    if (api == null) return;
    Map<String, dynamic> res;
    try {
      res = await api.hotAppA2ui(name);
    } catch (e) {
      if (mounted) _toast('读取 a2ui 应用失败', '$e');
      return;
    }
    final raw = res['messages'];
    if (res['ok'] != true || raw is! List) {
      if (mounted) _toast('读取 a2ui 应用失败', '${res['detail'] ?? res['error'] ?? '无消息序列'}');
      return;
    }
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => NonAppA2uiViewer(
        title: (res['title'] ?? title).toString(),
        messages: raw,
      ),
    ));
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
      _offlinePath = null;
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

  /// 导入 `.nonapp`：应用内打开入口（OS 关联/拖拽走同一条 openNonAppFromPath）。
  Future<void> _importApp() => pickAndOpenNonApp(context);

  /// 导出当前应用为 `.nonapp`（桌面端；移动端无保存对话框/分享面板 → 禁用）。
  Future<void> _exportApp() async {
    final api = store.api;
    final app = _app;
    if (api == null || app == null || _busy) return;
    setState(() => _busy = true);
    try {
      final res = await api.hotAppExport(app);
      if (!mounted) return;
      if (res.bytes == null) {
        _toast('导出被拒', res.error ?? '未知错误');
        return;
      }
      final location = await getSaveLocation(
        suggestedName: res.filename ?? '$app.nonapp',
        acceptedTypeGroups: const [
          XTypeGroup(label: 'NoNDesign 应用包', extensions: ['nonapp']),
        ],
      );
      if (location == null) return; // 用户取消
      await File(location.path).writeAsBytes(res.bytes!, flush: true);
      if (mounted) _toast('已导出', location.path);
    } catch (e) {
      if (mounted) _toast('导出失败', '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 退出离线：清空缓存通道并回到设计视图（离线实例不持久化）。
  void _exitOffline() {
    setState(() {
      _offlinePath = null;
      _controller = null;
      _lastError = '';
    });
    store.setView('design');
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

  /// 导出能力：桌面端才有保存对话框（iOS/Android 无 share-sheet 插件）。
  bool _canExport(NoNDesignApi? api) =>
      api != null && !Platform.isIOS && !Platform.isAndroid;

  /// 窄屏收进「⋯」的次要动作（宽屏同语义直接铺在顶栏）。
  List<_TopBtn> _secondaryActions(NoNDesignApi? api, {required bool narrow}) => [
        if (api != null)
          _TopBtn(
            icon: Icons.list,
            label: '应用',
            compact: narrow,
            onTap: _busy ? null : _showAppList,
          ),
        _TopBtn(
          icon: Icons.file_open_outlined,
          label: '导入',
          compact: narrow,
          onTap: _busy ? null : _importApp,
        ),
        if (_app != null)
          _TopBtn(
            icon: Icons.save_alt,
            label: '导出',
            compact: narrow,
            tip: _canExport(api) ? '导出为 .nonapp 单文件包' : '导出需要桌面端',
            onTap: (_canExport(api) && !_busy) ? _exportApp : null,
          ),
        if (_app != null)
          _TopBtn(
            icon: Icons.delete_outline,
            label: '删除',
            compact: narrow,
            onTap: _busy ? null : _deleteApp,
          ),
      ];

  /// 离线常驻横幅：file:// 下没有服务端注入的 SQLite 桥——必须显式告知。
  Widget _offlineBanner(NonPalette p) => Container(
        width: double.infinity,
        color: p.accent.withValues(alpha: 0.12),
        padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
        child: Row(children: [
          Icon(Icons.cloud_off_outlined, size: 15, color: p.accent),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '离线运行：SQLite 桥不可用（连接桌面服务后可用）；修改/保存需要服务器',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: p.ink2),
            ),
          ),
          TextButton(
            onPressed: _exitOffline,
            child: const Text('退出离线', style: TextStyle(fontSize: 11)),
          ),
        ]),
      );

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
            // 标题/副标题必须可压缩：6 个文字按钮在 ~700-900 宽会把 Row 撑爆
            // （776 宽实测右溢 171px）。Flexible + ellipsis 让标题先让位，
            // 而不是溢出。
            Flexible(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: narrow ? 110 : 400),
                child: Text(_app == null ? 'NoN 热应用' : '热应用 · $_app',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: p.ink)),
              ),
            ),
            const SizedBox(width: 10),
            if (!narrow)
              Flexible(
                child: Tooltip(
                  message: _title.isEmpty ? 'HTML + SQLite · 覆盖即热更新' : _title,
                  child: Text(_title.isEmpty ? 'HTML + SQLite · 覆盖即热更新' : '$_title · 覆盖即热更新',
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: p.ink4)),
                ),
              ),
            const Spacer(),
            if (_busy) SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.8, color: p.accent)),
            const SizedBox(width: 8),
            // 主操作常驻；其余动作在窄屏收进「⋯」菜单——390 宽下 6 个文字
            // 按钮会右溢（mobile_surfaces_test 的 402/390 覆盖）。
            if (narrow) ...[
              _TopBtn(icon: Icons.add, label: '新建', compact: true, onTap: _busy ? null : _create),
              if (_app != null)
                _TopBtn(
                  icon: Icons.refresh,
                  label: '重载',
                  compact: true,
                  onTap: (_busy || _offlinePath != null || api == null)
                      ? null
                      : () => _controller?.loadRequest(Uri.parse(api.hotAppPageUrl(_app!))),
                ),
              _TopMenu(items: _secondaryActions(api, narrow: true)),
            ] else ...[
              if (api != null)
                _TopBtn(icon: Icons.list, label: '应用', onTap: _busy ? null : _showAppList),
              _TopBtn(icon: Icons.add, label: '新建', onTap: _busy ? null : _create),
              if (_app != null)
                _TopBtn(
                  icon: Icons.delete_outline,
                  label: '删除',
                  onTap: _busy ? null : _deleteApp,
                ),
              if (_app != null)
                _TopBtn(
                  icon: Icons.refresh,
                  label: '重载',
                  onTap: (_busy || api == null)
                      ? null
                      : () => _controller?.loadRequest(Uri.parse(api.hotAppPageUrl(_app!))),
                ),
              // 文件即应用 v2：导入/导出紧随「重载」。
              _TopBtn(
                icon: Icons.file_open_outlined,
                label: '导入',
                onTap: _busy ? null : _importApp,
              ),
              if (_app != null)
                _TopBtn(
                  icon: Icons.save_alt,
                  label: '导出',
                  tip: _canExport(api) ? '导出为 .nonapp 单文件包' : '导出需要桌面端',
                  onTap: (_canExport(api) && !_busy) ? _exportApp : null,
                ),
            ],
          ]);
          }),
        ),
        if (_offlinePath != null) _offlineBanner(p),
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
          child: (_app == null && _offlinePath == null)
              ? _EmptyHotApp(
                  onCreate: _busy ? null : _create,
                  onOpenPackage: _busy ? null : _importApp,
                )
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
                  // 对话式修改条（快速热更新的入口）：离线没有服务端，隐藏。
                  if (_offlinePath == null)
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
  const _EmptyHotApp({required this.onCreate, this.onOpenPackage});
  final VoidCallback? onCreate;

  /// 打开本地 `.nonapp` 包（应用内打开入口；OS 关联与拖拽走同一函数）。
  final VoidCallback? onOpenPackage;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.auto_fix_high_outlined, size: 44, color: p.ink4),
          const SizedBox(height: 14),
          Text('NoN 热应用', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: p.ink)),
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Text(
              '一句话生成自成一体的热应用：动画、演示、可玩的交互。\n'
              '自包含单 HTML + SQLite——离线可用、覆盖即热更新、生成即进作品集。\n'
              '也可以打开别人分享的 .nonapp 单文件包（html / a2ui 双载荷）。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: p.ink3, height: 1.7),
            ),
          ),
          const SizedBox(height: 18),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 10,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: onCreate, // 生成中禁点：否则可并发触发两次生成
                icon: const Icon(Icons.add, size: 16),
                label: const Text('生成第一个热应用'),
              ),
              OutlinedButton.icon(
                onPressed: onOpenPackage,
                icon: const Icon(Icons.file_open_outlined, size: 16),
                label: const Text('打开 .nonapp…'),
              ),
            ],
          ),
        ]),
      ),
    );
  }
}

class _TopBtn extends StatelessWidget {
  const _TopBtn({
    required this.icon,
    required this.label,
    this.onTap,
    this.compact = false,
    this.tip,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool compact;

  /// 覆盖默认 tooltip（如「导出需要桌面端」的禁用原因）。
  final String? tip;

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
    if (compact) return Tooltip(message: tip ?? label, child: button);
    return tip == null ? button : Tooltip(message: tip!, child: button);
  }
}

/// 窄屏的「⋯」动作菜单：顶栏在 390 宽放不下 6 个文字按钮，次要动作收进来。
class _TopMenu extends StatelessWidget {
  const _TopMenu({required this.items});

  final List<_TopBtn> items;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    if (items.isEmpty) return const SizedBox.shrink();
    return PopupMenuButton<int>(
      tooltip: '更多操作',
      padding: EdgeInsets.zero,
      icon: Icon(Icons.more_horiz, size: 18, color: p.ink2),
      onSelected: (i) => items[i].onTap?.call(),
      itemBuilder: (ctx) => [
        for (var i = 0; i < items.length; i++)
          PopupMenuItem<int>(
            value: i,
            enabled: items[i].onTap != null,
            child: Row(children: [
              Icon(items[i].icon, size: 16, color: items[i].onTap == null ? p.ink4 : p.ink2),
              const SizedBox(width: 8),
              Text(
                items[i].label,
                style: TextStyle(fontSize: 13, color: items[i].onTap == null ? p.ink4 : p.ink),
              ),
            ]),
          ),
      ],
    );
  }
}


/// JSON 调试辅助（notes 序列化）。
String hotAppNotesJson(List<String> notes) => jsonEncode(notes.map((n) => {'note': n}).toList());
