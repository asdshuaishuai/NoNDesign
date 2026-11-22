/// 热应用工作台（批次 07：全本地）。
///
/// 一句话 → 模型产出单个自包含页面 → 落本地库 → WebView 即运行时。
/// 生成、精修、列表、删除、导入、导出全部在客户端完成；没有本地端口，
/// 也没有内部 HTTP 路由。
///
/// 执行面边界（review nonapp-5）：
///  * 预览文件只从**本机缓存** `file://` 加载；导航白名单只放行 `file:` 与
///    `about:`（远端整页导航一律 prevent——页面脚本带不走 WebView）；
///  * 预览文件由 [NonAppCache] 注入 CSP meta 与本地数据桥，两者都早于页面
///    第一个脚本；CSP 挡请求与资源，导航白名单挡整页跳转；
///  * 数据桥只碰当前应用自己的数据库（[HotAppDb] 的 SQL 门）。
///
/// 平台矩阵（唯一判据是 [PlatformCapabilities]）：
///  * 应用内预览走 `webview_all`（macOS/iOS/Windows/Linux/Android 全平台）；
///  * 「在文件夹中显示」只在桌面三平台出现；
///  * 导出需要保存对话框（桌面）；手机上明示需要电脑。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:provider/provider.dart';
import 'package:webview_all/webview_all.dart';
import 'package:webview_all_wkwebview/webview_all_wkwebview.dart';

import '../core/app_paths.dart';
import '../core/hotapp_db.dart';
import '../core/hotapp_service.dart';
import '../core/nonapp_cache.dart';
import '../core/nonapp_library.dart';
import '../core/nonapp_package.dart';
import '../core/platform_capabilities.dart';
import '../core/store.dart';
import '../core/theme.dart';
import '../core/toast_service.dart';
import 'common.dart';
import 'nonapp_import.dart';
import 'nonapp_viewer.dart';

/// webview_all 的 WKWebView 平台在插件注册中自动就绪；测试环境保留幂等注册兜底。
bool _wkRegistered = false;

/// 作品集「打开」直载：切视图前设置，工作台 initState/监听消费后清空
/// （registry builder 无参，跨实例传名的轻量通道）。
String? hotAppLoadOnOpen;

/// **兜底**预览文件路径：应用库不可用（磁盘异常/平台限制）时，导入的页面
/// 仍能临时打开，但不会保存。与 [hotAppLoadOnOpen] 两域分离——后者只承载
/// 应用名，这里只承载本机缓存文件。
String? hotAppOfflinePath;

/// WebView 导航白名单（review nonapp-5）：只放行
///   ① `file://`（本地预览）
///   ② `about:`（WebView 内部空页）
///   ③ 显式给出 [baseUrl] 时的同源页（连接桌面的兼容面；本地默认不传）
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
  const HotAppWorkspace({super.key, this.service, this.library});

  /// 本地面（测试注入临时目录/脚本化模型；生产为 null，首次动作时打开）。
  final HotAppService? service;

  /// 本地库（仅注入库时自动构造服务；与 [service] 二选一）。
  final NonAppLibrary? library;

  @override
  State<HotAppWorkspace> createState() => _HotAppWorkspaceState();
}

class _HotAppWorkspaceState extends State<HotAppWorkspace> {
  String? _app;
  LibraryApp? _entry;

  /// 兜底预览文件（应用库不可用时）；非空即「临时预览」。
  String? _offlinePath;

  String _title = '';
  bool _busy = false;
  bool _booting = false;
  String _serviceError = '';
  String _lastError = '';
  /// 原始诊断：只进折叠的「技术详情」与修改框预填，绝不作为主文案。
  String _lastErrorDetail = '';
  bool _dbUnavailable = false;
  /// 点亮 [_dbUnavailable] 横幅的那次数据门失败（其他失败路径为 null，
  /// 横幅回落到通用文案）。
  HotAppDbFailure? _dbFailure;

  WebViewController? _controller;
  HotAppDb? _db;
  String? _dbApp;
  HotAppService? _service;
  Future<HotAppService?>? _serviceLoading;

  /// 挂载队列：store 的「切到新应用」通知可能在已有挂载在飞时到达
  /// （tool_end 立刻 setHotApp，run 结束还会再刷新一次）。直接丢弃会把
  /// 新预览请求吞掉，工作台停在旧页面。只保留最近一个目标应用。
  String? _queuedMount;
  String? _mountingName;

  /// 应用列表缓存：run 结束/切应用时重扫；切换入口直接复用，不再二次扫盘。
  List<LibraryApp> _appList = const [];

  /// 最近一次写出的预览文件（内嵌预览 / 浏览器逃生口共用）。
  String? _previewPath;

  final _refineCtl = TextEditingController();
  final List<String> _notes = [];

  AppStore? _store;

  PlatformCapabilities get _host =>
      _store?.capabilities.platform ?? PlatformCapabilities.current();

  ToastService get _toasts => _store?.toasts ?? ToastService.instance;

  @override
  void initState() {
    super.initState();
    // 移动端由插件注册自动完成；macOS 无 endorsed 实现才需要幂等注册。
    // `instance == null` 守卫另兼测试卫生：fake 平台注入后不得被覆盖。
    if ((Platform.isMacOS || Platform.isIOS) &&
        !_wkRegistered &&
        WebViewPlatform.instance == null) {
      WebKitWebViewPlatform.registerWith();
      _wkRegistered = true;
    }
    final consumed = _consumeOpenRequests();
    final saved = _storeOf(context).settings.hotappApp;
    if (!consumed && saved.isNotEmpty) {
      _app = saved;
      WidgetsBinding.instance.addPostFrameCallback((_) => _requestMount(saved));
    }
  }

  @override
  void didUpdateWidget(covariant HotAppWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 视图不变时的「打开应用包」：workspace 用未加 key 的 const
    // HotAppWorkspace 渲染同一 view，setView 只触发重建、不重建 State——
    // 若只在 initState 消费，已挂载的工作台会静默吞掉导入/兜底打开。
    if (_consumeOpenRequests()) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 同一实例被父级复用（identical → 不触发 didUpdateWidget）时，跨实例
    // 打开请求只能靠 store 通知来消费（review nonapp-1）。
    final s = _storeOf(context);
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
    _db?.dispose();
    _db = null;
    _controller = null;
    super.dispose();
  }

  AppStore get store => _storeOf(context);

  AppStore _storeOf(BuildContext context) => context.read<AppStore>();

  /// 消费跨实例直载通道。返回 true = 有通道被消费。
  bool _consumeOpenRequests() {
    final offline = hotAppOfflinePath;
    final pending = hotAppLoadOnOpen;
    if (offline == null && pending == null) return false;
    hotAppOfflinePath = null;
    hotAppLoadOnOpen = null;
    if (offline != null && offline.isNotEmpty) {
      _app = null;
      _entry = null;
      _offlinePath = offline;
      _queuedMount = null;
      _lastError = '';
      _lastErrorDetail = '';
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
        if (!mounted) return;
        // 持久化推迟到首帧后：构建期 notifyListeners 会触发祖先重建。
        store.setHotApp(pending);
        _requestMount(pending);
      });
      return true;
    }
    return false;
  }

  /// 上次渲染用到的跨模块状态：由原型生成的在飞标记 + 当前应用名。
  /// 变了必须重建顶栏（进度/「生成中…」），否则点了按钮界面没有任何反馈。
  bool _lastFromPrototypeBusy = false;
  String _lastHotappApp = '';

  /// NaN 的聊天/智能体 run 在飞标记：`agentBusy` true→false 是一次 run 的
  /// 终态，run 期间可能由 `hotapp_refine` 原地改写了当前应用的页面（应用名
  /// 不变），只有 run 结束才看得到——必须重挂预览刷新内容。
  bool _lastAgentBusy = false;
  bool _lastHotappToolRunning = false;

  /// NaN 当前是否正在通过工具生成/精修热应用（tool_start 到 tool_end 之间）。
  bool get _agentHotappRunning {
    if (!store.agentBusy) return false;
    for (final item in store.timeline) {
      if (item.kind == 'tool' &&
          item.running &&
          (item.tool ?? '').startsWith('hotapp_')) {
        return true;
      }
    }
    return false;
  }

  void _onStoreNotify() {
    if (!mounted) return;
    final busy = store.hotappFromPrototypeBusy;
    final app = store.settings.hotappApp;
    final agentBusy = store.agentBusy;
    final hotappToolRunning = _agentHotappRunning;
    final visualChange = busy != _lastFromPrototypeBusy ||
        app != _lastHotappApp ||
        agentBusy != _lastAgentBusy ||
        hotappToolRunning != _lastHotappToolRunning;
    final runEnded = _lastAgentBusy && !agentBusy;
    final prototypeEnded = _lastFromPrototypeBusy && !busy;
    _lastFromPrototypeBusy = busy;
    _lastHotappApp = app;
    _lastAgentBusy = agentBusy;
    _lastHotappToolRunning = hotappToolRunning;
    if (visualChange) setState(() {});

    // 帧内通知不能同步 setState/mount：统一推到帧末。
    void applySignals() {
      if (!mounted) return;
      // 智能体/原型生成把工作台当前应用换成了新名字 → 自动切过去。
      final switched = app.isNotEmpty && app != _app;
      if (switched) {
        _requestMount(app);
      } else if (app.isEmpty && _app != null && _offlinePath == null) {
        // 外部清空（应用在别处被删除）：回到空态，不留旧页面。
        _queuedMount = null;
        _closeDb();
        _dropPreviewPath();
        setState(() {
          _app = null;
          _entry = null;
          _title = '';
          _controller = null;
          _lastError = '';
          _lastErrorDetail = '';
        });
      }
      if (switched || runEnded || prototypeEnded) {
        // 重扫应用列表（切换入口不接受旧列表）；run/原型生成结束还要
        // 刷新当前应用的类型/来源徽标并重挂预览。切到新应用时新挂载本身
        // 就会读入口 + 写预览文件，不用再重载一次。
        unawaited(_refreshAppList());
        if (!switched) {
          final current = _app;
          if (current != null && _offlinePath == null) _requestMount(current);
        }
      }
      if (_consumeOpenRequests()) setState(() {});
    }

    // 构建/布局期回调里 setState 会抛「during build」：推到帧末。
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => applySignals());
      return;
    }
    applySignals();
  }

  // -- 数据面 ---------------------------------------------------------------

  Future<HotAppService?> _ensureService() async {
    final ready = _service;
    if (ready != null) return ready;
    final inFlight = _serviceLoading;
    if (inFlight != null) return inFlight;
    final future = _openService();
    _serviceLoading = future;
    try {
      return await future;
    } finally {
      _serviceLoading = null;
    }
  }

  Future<HotAppService?> _openService() async {
    try {
      final service = widget.service ??
          HotAppService(
            library: widget.library ?? await NonAppLibrary.open(),
          );
      if (!mounted) return service;
      setState(() {
        _service = service;
        _serviceError = '';
      });
      return service;
    } catch (error) {
      debugPrint('[hotapp] library open failed: $error');
      if (mounted) {
        setState(() => _serviceError = '应用库暂时打不开，请稍后重试');
      }
      return null;
    }
  }

  /// 挂载持久库里的应用（异步读页面 → 写预览 → 建控制器）。
  ///
  /// 赋值发生在 await 之后，**必须**自己 setState：迟到回包不重建会停在
  /// 「加载中…」（res-2 回归，测试 nonapp_hotapp_mount_test 锚定）。
  Future<void> _mountSaved(String name) async {
    if (_booting) return;
    _booting = true;
    // 切应用先断旧库：页面桥在新页面挂载前若收到旧页迟到消息，绝不能
    // 落到上一个应用的数据上。
    _closeDb();
    final service = await _ensureService();
    if (!mounted) {
      _booting = false;
      return;
    }
    if (service == null) {
      _booting = false;
      setState(() {});
      return;
    }
    setState(() {
      _booting = true;
      _app = name;
      _offlinePath = null;
      _lastError = '';
      _lastErrorDetail = '';
      _dbUnavailable = false;
      _dbFailure = null;
    });
    try {
      final entry = await service.read(name);
      if (!mounted || _app != name) return;
      if (entry == null) {
        setState(() {
          _entry = null;
          _controller = null;
          _lastError = '这个应用已经不在了，可能在作品集里被删除了';
        });
        return;
      }
      final messages = entry.isA2ui ? await service.surface(name) : null;
      if (!mounted || _app != name) return;
      if (entry.isA2ui) {
        if (messages == null) {
          setState(() {
            _entry = entry;
            _lastError = '这个应用的内容读不出来';
          });
          return;
        }
        setState(() => _entry = entry);
        // 导航跳帧：mount 可能在 async 期间与会话恢复/其它 push 同帧发生，
        // 直接 push 会撞 Navigator 的 `_debugLocked` 断言（debug 红屏）。
        await _pushAfterFrame(
          MaterialPageRoute<void>(
            builder: (_) => NonAppA2uiViewer(title: entry.title, messages: messages),
          ),
        );
        return;
      }

      final html = await service.html(name);
      if (!mounted || _app != name) return;
      if (html == null) {
        setState(() {
          _entry = entry;
          _lastError = '这个应用的内容读不出来';
        });
        return;
      }
      final path = await NonAppCache.writeHtml(
        name: name,
        htmlBytes: utf8.encode(html),
        withDbBridge: true,
      );
      if (!mounted || _app != name) return;
      _closeDb();
      _entry = entry;
      _title = entry.brief?.isNotEmpty == true ? entry.brief! : entry.title;
      _dbUnavailable = false;
      _dbFailure = null;
      _previewPath = path;
      if (_host.supportsInAppWebView) {
        _controller = _newController()..loadFile(path);
      } else {
        _controller = null;
      }
      // 同一缓存路径被原地重写（精修/重新生成）时，预览组件看不出路径变化；
      // 刷新控制器实例，避免停在旧页面。
      setState(() {});
    } on NonAppException catch (error) {
      debugPrint('[hotapp] mount rejected: $error');
      if (mounted) {
        setState(() {
          _controller = null;
          _lastError = nonAppExceptionMessage(error);
        });
      }
    } catch (error) {
      debugPrint('[hotapp] mount failed: $error');
      if (mounted) {
        setState(() {
          _controller = null;
          _lastError = '这个应用没有打开，请重试';
        });
      }
    } finally {
      _booting = false;
      if (mounted) setState(() {});
    }
  }

  /// 排队挂载：只保留最近一次目标应用，并等当前挂载结束后再消化。
  ///
  /// store 的「切到新应用」通知可能在已有挂载在飞时到达；旧的
  /// `_mountSaved` 开头 `if (_booting) return` 会把这个请求丢掉，工作台就停在
  /// 旧应用上——这正是「生成完工作台里没有东西」的断点之一。
  void _requestMount(String name) {
    if (name.isEmpty) return;
    if (_mountingName == name) return; // 同一应用已在挂载：等它完成即可
    _queuedMount = name;
    unawaited(_drainMountQueue());
  }

  Future<void> _drainMountQueue() async {
    if (_booting) return;
    final name = _queuedMount;
    if (name == null) return;
    _queuedMount = null;
    _mountingName = name;
    try {
      await _mountSaved(name);
    } finally {
      _mountingName = null;
      if (mounted && _queuedMount != null) {
        unawaited(_drainMountQueue());
      }
    }
  }

  /// 重扫本地应用列表（工作台「应用」切换入口的数据面）。
  ///
  /// 失败不打断工作台（run 结束是后台刷新）：保留旧列表并记控制台，下一次
  /// 用户主动打开列表时仍会重新扫。
  Future<void> _refreshAppList() async {
    final service = await _ensureService();
    if (!mounted || service == null) return;
    try {
      final apps = await service.list();
      if (!mounted) return;
      setState(() => _appList = apps);
    } catch (error) {
      debugPrint('[hotapp] list rescan failed: $error');
    }
  }

  /// 下一帧再 push：async 回调里直接导航可能落在 Navigator 锁定帧内
  /// （`!_debugLocked` 断言、debug 红屏）。导航前重查 mounted。
  Future<void> _pushAfterFrame(Route<void> route) async {
    final nav = Navigator.of(context);
    final completer = Completer<void>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !nav.mounted) {
        if (!completer.isCompleted) completer.complete();
        return;
      }
      nav.push(route).whenComplete(() {
        if (!completer.isCompleted) completer.complete();
      });
    });
    WidgetsBinding.instance.scheduleFrame();
    await completer.future;
  }

  /// 兜底路径：只打开本机缓存文件（没有应用库/数据库）。
  void _mountOffline(String path) {
    _closeDb();
    _entry = null;
    _previewPath = path;
    _dbUnavailable = true;
    _dbFailure = null;
    if (_host.supportsInAppWebView) {
      _controller = _newController()..loadFile(path);
    } else {
      _controller = null;
    }
  }

  WebViewController _newController() => WebViewController()
    ..setJavaScriptMode(JavaScriptMode.unrestricted)
    ..addJavaScriptChannel(hotAppPageErrorChannel, onMessageReceived: _onPageMessage)
    ..addJavaScriptChannel(hotAppDbChannel, onMessageReceived: _onDbMessage)
    ..setNavigationDelegate(NavigationDelegate(
      // 导航白名单：本地预览只放行 file/about（review nonapp-5）。
      onNavigationRequest: (request) =>
          hotAppNavigationAllowed(request.url)
              ? NavigationDecision.navigate
              : NavigationDecision.prevent,
      onWebResourceError: (error) {
        if (!mounted) return;
        setState(() {
          _lastError = '页面加载失败';
          _lastErrorDetail = '${error.description} (${error.errorCode})';
        });
      },
    ));

  void _onPageMessage(JavaScriptMessage msg) {
    try {
      final data = jsonDecode(msg.message);
      if (data is Map && data['kind'] == 'error') {
        final m = (data['message'] ?? '').toString();
        if (m.isEmpty || m == _lastErrorDetail) return;
        debugPrint('[hotapp] page error: $m');
        if (mounted) {
          setState(() {
            _lastError = '页面运行出错了';
            _lastErrorDetail = m;
          });
        }
      }
    } catch (_) {}
  }

  /// 页面数据桥：一条 SQL 一次往返。
  ///
  /// 只认当前应用：应答前再校验一次 `_app`，避免切应用后旧页面把结果写进
  /// 新应用的 UI；SQL 门与体积上限在 [HotAppDb] 里。
  void _onDbMessage(JavaScriptMessage msg) {
    final controller = _controller;
    final service = _service;
    final app = _app;
    if (controller == null ||
        service == null ||
        app == null ||
        _offlinePath != null ||
        _booting) {
      return;
    }
    // 切应用窗口期：页面还是上一个应用的（_entry 尚未更新），它的 SQL 不
    // 得落到新应用的数据上。
    if (_entry != null && _entry!.name != app) return;
    String id = '';
    Map<String, dynamic> reply;
    if (msg.message.length > 2 * 1024 * 1024) {
      // 通道消息无界：页面侧一条超大 SQL/参数不该把宿主拖进无界内存。
      debugPrint('[hotapp] db message too large: ${msg.message.length}');
      return;
    }
    try {
      final decoded = jsonDecode(msg.message);
      if (decoded is! Map) return;
      id = (decoded['id'] ?? '').toString();
      final sql = (decoded['sql'] ?? '').toString();
      final rawParams = decoded['params'];
      final params = <Object?>[];
      if (rawParams is List) {
        for (final value in rawParams) {
          params.add(value);
        }
      }
      if (id.isEmpty) return;
      try {
        if (_db == null || _dbApp != app) {
          _closeDb();
          _db = service.openDb(app);
          _dbApp = app;
        }
        reply = _db!.exec(sql, params);
        if (_dbUnavailable && mounted) {
          setState(() {
            _dbUnavailable = false;
            _dbFailure = null;
          });
        }
      } on HotAppDbFailure catch (failure) {
        debugPrint('[hotapp] db rejected: $failure');
        if (failure.code == 'db_unavailable' && mounted) {
          _dbFailure = failure;
          setState(() => _dbUnavailable = true);
        }
        reply = {'ok': false, 'error': 'unavailable'};
      } catch (error) {
        debugPrint('[hotapp] db failed: $error');
        _dbFailure = null;
        if (mounted) setState(() => _dbUnavailable = true);
        reply = {'ok': false, 'error': 'unavailable'};
      }
    } catch (error) {
      debugPrint('[hotapp] db message invalid: $error');
      reply = {'ok': false, 'error': 'invalid'};
    }
    if (id.isEmpty) return;
    // 页面侧 Promise 必须收到回填（无论成败），否则页面永远 pending。
    unawaited(controller.runJavaScript(
      'window.$hotAppDbResultFunction(${jsonEncode(id)}, ${jsonEncode(reply)})',
    ));
  }

  void _closeDb() {
    _db?.dispose();
    _db = null;
    _dbApp = null;
  }

  /// 丢弃当前预览文件引用（删除/外部清空/退出临时预览）。
  void _dropPreviewPath() {
    _previewPath = null;
  }

  // -- 用户动作 -------------------------------------------------------------

  /// 当前设计项目是否已有可转成热应用的原型（画板 ≥ 1）。
  bool get _prototypeReady =>
      store.hasProject && store.render.artboards.any((a) => a.id != '__seed');

  bool get _fromPrototypeBusy => store.hotappFromPrototypeBusy;

  /// 工作台处于「有产出在路上」的状态：本地生成/精修、原型生成、或 NaN
  /// 正在用热应用工具。转圈只在其中任一为真时显示，终态一到全部收掉。
  bool get _generating => _busy || _fromPrototypeBusy || _agentHotappRunning;

  Future<void> _generateFromPrototype() async {
    await store.generateHotAppFromPrototype();
  }

  Future<void> _openApp(String name) async {
    setState(() {
      _app = name;
      _offlinePath = null;
      _lastError = '';
      _lastErrorDetail = '';
      _notes.add('切换到 $name');
    });
    store.setHotApp(name);
    // 走挂载队列：切换过程中若 store 再发通知（run 收尾）不会被丢弃。
    _requestMount(name);
  }

  /// 热应用类型徽标：可用应用 / 原型验证（颜色取主题令牌，浅色主题也可读）。
  Widget _originBadge(NonPalette p, String origin) {
    final prototype = origin == nonAppOriginPrototype;
    final color = prototype ? p.warn : p.accent;
    return Container(
      key: ValueKey('hotapp-origin-badge-${prototype ? 'prototype' : 'app'}'),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Text(
        prototype ? '原型验证' : '可用应用',
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }

  /// 应用列表/切换入口（本地库扫描）；列表里可新建或删除。
  Future<void> _showAppList() async {
    final service = await _ensureService();
    if (!mounted) return;
    if (service == null) {
      _toasts.warn(_serviceError.isEmpty ? '应用库暂时打不开' : _serviceError);
      return;
    }
    List<LibraryApp> apps;
    try {
      apps = await service.list();
      if (mounted) _appList = apps;
    } catch (error) {
      debugPrint('[hotapp] list failed: $error');
      if (mounted) _toasts.error('应用列表没有加载出来', '请稍后重试');
      return;
    }
    if (!mounted) return;
    final picked = await showNonDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: ctx.palette.panel,
        title: Text('热应用',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: ctx.palette.ink)),
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
              child: Text('还没有热应用：可以直接描述一个可用应用，或由当前原型生成一个验证式 demo。',
                  style: TextStyle(fontSize: 12, height: 1.5, color: ctx.palette.ink4)),
            ),
          for (final group in [
            ('可用应用', apps.where((a) => !a.isPrototypeDemo).toList(), nonAppOriginApp),
            ('原型验证 demo', apps.where((a) => a.isPrototypeDemo).toList(), nonAppOriginPrototype),
          ])
            if (group.$2.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
                child: Text(group.$1,
                    style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.6,
                        color: ctx.palette.ink4)),
              ),
              for (final a in group.$2)
                SimpleDialogOption(
                  key: ValueKey('hotapp-list-${a.name}'),
                  onPressed: () => Navigator.pop(ctx, a.name),
                  child: Row(children: [
                    Icon(
                      a.isPrototypeDemo ? Icons.science_outlined : Icons.widgets_outlined,
                      size: 16,
                      color: a.isPrototypeDemo ? ctx.palette.warn : ctx.palette.accent,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        a.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    _originBadge(ctx.palette, a.origin),
                    const SizedBox(width: 6),
                    if (a.name == _app)
                      Icon(Icons.check, size: 15, color: ctx.palette.accent),
                  ]),
                ),
            ],
        ],
      ),
    );
    if (!mounted || picked == null || picked.isEmpty) return;
    if (picked == '__new__') {
      await _create();
      return;
    }
    await _openApp(picked);
  }

  Future<void> _deleteApp() async {
    final service = _service;
    final app = _app;
    if (service == null || app == null || _busy) return;
    final ok = await showNonDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ctx.palette.panel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text('删除这个热应用？',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: ctx.palette.ink)),
        content: Text(
          '会同时删除它在本机的数据，无法恢复。',
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
      await service.delete(app);
      if (!mounted) return;
      _closeDb();
      _dropPreviewPath();
      setState(() {
        _app = null;
        _entry = null;
        _title = '';
        _controller = null;
        _offlinePath = null;
        _lastError = '';
        _lastErrorDetail = '';
        _notes.add('已删除 $app');
      });
      store.setHotApp('');
      _toasts.success('已删除', '这个应用和它的本地数据都已移除。');
    } on NonAppException catch (error) {
      debugPrint('[hotapp] delete failed: $error');
      if (mounted) _toasts.error('删除没有完成', '请稍后重试');
    } catch (error) {
      debugPrint('[hotapp] delete failed: $error');
      if (mounted) _toasts.error('删除没有完成', '请稍后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 导入应用包：应用内打开入口（系统关联/拖拽走同一条 openNonAppFromPath）。
  Future<void> _importApp() => pickAndOpenNonApp(context);

  /// 导出当前应用为一个应用包文件。
  ///
  /// 桌面走保存对话框；手机没有分享面板（无插件），落到应用自己的文档目录
  /// （iOS 的文件 App 可见），并在通知里给出位置——不假装能调起系统分享。
  Future<void> _exportApp() async {
    final service = _service;
    final app = _app;
    if (service == null || app == null || _busy) return;
    setState(() => _busy = true);
    try {
      final bytes = await service.exportPackage(app);
      final String target;
      if (_host.isMobile) {
        final root = await AppPaths.projectsRoot();
        final dir = Directory('${root.path}/exports');
        if (!dir.existsSync()) dir.createSync(recursive: true);
        target = '${dir.path}/$app.nonapp';
      } else {
        final location = await getSaveLocation(
          suggestedName: '$app.nonapp',
          acceptedTypeGroups: const [
            XTypeGroup(label: 'NaN 应用包', extensions: ['nonapp']),
          ],
        );
        if (location == null) return; // 用户取消
        target = location.path;
      }
      await File(target).writeAsBytes(bytes, flush: true);
      if (mounted) _toasts.success('已导出', target);
    } on NonAppException catch (error) {
      debugPrint('[hotapp] export rejected: $error');
      if (mounted) _toasts.error('导出没有完成', '请稍后重试');
    } catch (error) {
      debugPrint('[hotapp] export failed: $error');
      if (mounted) _toasts.error('导出没有完成', '请检查保存位置后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _create() async {
    if (_busy) return;
    final service = await _ensureService();
    if (!mounted) return;
    if (service == null) {
      _toasts.warn(_serviceError.isEmpty ? '应用库暂时打不开' : _serviceError);
      return;
    }
    final s = store.settings;
    if (!HotAppLlmConfig(
      model: s.modelId,
      baseUrl: s.baseUrl,
      apiKey: s.apiKey,
      thinkingLevel: s.thinkingLevel,
    ).isConfigured) {
      _toasts.warn('先在设置里配好模型连接', '热应用生成使用当前选中的模型。');
      return;
    }
    final nameCtl = TextEditingController();
    final briefCtl = TextEditingController();
    final ok = await showNonDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ctx.palette.panel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text('生成热应用',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: ctx.palette.ink)),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: nameCtl,
              decoration: const InputDecoration(
                labelText: '应用名（小写字母、数字、短横线或下划线）',
                hintText: 'bounce-demo',
              ),
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: briefCtl,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: '一句话需求（动画 / 演示 / 可玩的交互）',
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
    // 控制器不在 here dispose：退场动画期间 TextField 仍持有它们。
    if (!mounted || ok != true) return;
    if (name.isEmpty || brief.isEmpty) return;
    setState(() => _busy = true);
    try {
      final entry = await service.generate(
        name: name,
        brief: brief,
        config: HotAppLlmConfig(
          model: s.modelId,
          baseUrl: s.baseUrl,
          apiKey: s.apiKey,
          thinkingLevel: s.thinkingLevel,
        ),
      );
      if (!mounted) return;
      setState(() {
        _app = entry.name;
        _entry = entry;
        _title = brief;
        _offlinePath = null;
        _lastError = '';
        _notes.add('已生成（${entry.payloadBytes} 字节）');
      });
      store.setHotApp(entry.name);
      _requestMount(entry.name);
      _toasts.success('热应用已生成', '页面就在本机运行；下方输入框可以继续修改。');
    } on HotAppFailure catch (failure) {
      debugPrint('[hotapp] generate failed: $failure');
      if (mounted) _toasts.error(hotAppFailureMessage(failure));
    } on TimeoutException {
      if (mounted) _toasts.warn('生成没有在预期时间内完成', '模型可能仍在工作，请稍后重试。');
    } catch (error) {
      debugPrint('[hotapp] generate failed: $error');
      if (mounted) _toasts.error('生成没有完成', '请稍后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refine(String instruction) async {
    if (_busy) return;
    final service = _service;
    final app = _app;
    if (service == null || app == null || instruction.trim().isEmpty) return;
    final s = store.settings;
    if (!HotAppLlmConfig(
      model: s.modelId,
      baseUrl: s.baseUrl,
      apiKey: s.apiKey,
      thinkingLevel: s.thinkingLevel,
    ).isConfigured) {
      _toasts.warn('先在设置里配好模型连接', '修改热应用使用当前选中的模型。');
      return;
    }
    setState(() => _busy = true);
    try {
      final entry = await service.refine(
        name: app,
        instruction: instruction.trim(),
        config: HotAppLlmConfig(
          model: s.modelId,
          baseUrl: s.baseUrl,
          apiKey: s.apiKey,
          thinkingLevel: s.thinkingLevel,
        ),
      );
      if (!mounted) return;
      final html = await service.html(entry.name);
      if (!mounted) return;
      if (html != null) {
        final path = await NonAppCache.writeHtml(
          name: entry.name,
          htmlBytes: utf8.encode(html),
          withDbBridge: true,
        );
        if (!mounted) return;
        setState(() {
          _entry = entry;
          _previewPath = path;
          if (_host.supportsInAppWebView) {
            _controller = _newController()..loadFile(path);
          }
          _notes.add('已修改：${instruction.trim()}');
        });
        _toasts.success('已更新', '预览已重新加载。');
      } else {
        _toasts.error('修改没有完成', '请稍后重试');
      }
    } on HotAppFailure catch (failure) {
      debugPrint('[hotapp] refine failed: $failure');
      if (mounted) _toasts.error(hotAppFailureMessage(failure));
    } on TimeoutException {
      if (mounted) _toasts.warn('修改没有在预期时间内完成', '模型可能仍在工作，请稍后重试。');
    } catch (error) {
      debugPrint('[hotapp] refine failed: $error');
      if (mounted) _toasts.error('修改没有完成', '请稍后重试');
    } finally {
      if (mounted) {
        _refineCtl.clear();
        setState(() => _busy = false);
      }
    }
  }

  /// 退出临时预览：回到设计视图（临时打开不持久化）。
  void _exitOffline() {
    _dropPreviewPath();
    setState(() {
      _offlinePath = null;
      _controller = null;
      _lastError = '';
      _lastErrorDetail = '';
    });
    store.setView('design');
  }

  Future<void> _reloadPreview() async {
    final app = _app;
    if (app == null || _offlinePath != null) return;
    _requestMount(app);
  }

  /// 没有应用内预览的桌面（Linux/Windows）：用系统浏览器打开预览文件。
  Future<void> _openExternally() async {
    final path = _offlinePath ??
        (await _previewPathFor(_app));
    if (path == null) {
      _toasts.warn('预览还没有准备好');
      return;
    }
    try {
      if (_host.os == HostOs.macos) {
        await Process.run('open', [path]);
      } else if (_host.os == HostOs.windows) {
        await Process.run('cmd', ['/c', 'start', '', path]);
      } else if (_host.os == HostOs.linux) {
        await Process.run('xdg-open', [path]);
      } else {
        _toasts.warn('这台设备暂时不能打开外部预览');
      }
    } catch (error) {
      debugPrint('[hotapp] open externally failed: $error');
      _toasts.warn('没能打开预览', '请检查系统默认浏览器。');
    }
  }

  Future<String?> _previewPathFor(String? app) async {
    if (app == null) return _offlinePath;
    final service = _service;
    if (service == null) return _offlinePath;
    final html = await service.html(app);
    if (html == null) return _offlinePath;
    try {
      return await NonAppCache.writeHtml(
        name: app,
        htmlBytes: utf8.encode(html),
        withDbBridge: true,
      );
    } catch (_) {
      return _offlinePath;
    }
  }

  /// 复制预览文件路径（内嵌预览不可用时的降级出口之一：不白屏，
  /// 用户至少能把文件拿到浏览器/文件夹里打开）。
  Future<void> _copyPreviewPath() async {
    final path = _previewPath ??
        _offlinePath ??
        (await _previewPathFor(_app));
    if (path == null) {
      _toasts.warn('预览还没有准备好');
      return;
    }
    try {
      await Clipboard.setData(ClipboardData(text: path));
      if (!mounted) return;
      _toasts.info('已复制预览路径', path);
    } catch (error) {
      debugPrint('[hotapp] copy path failed: $error');
      if (mounted) _toasts.warn('没能复制路径', '可以在应用文件夹里直接打开预览文件。');
    }
  }

  Future<void> _revealApp() async {
    if (!_host.supportsRevealInFolder) {
      _toasts.warn('这台设备不支持在文件夹中显示');
      return;
    }
    final entry = _entry;
    if (entry == null) {
      _toasts.warn('还没有可以显示的文件夹');
      return;
    }
    try {
      final dir = Directory(entry.dir);
      if (!dir.existsSync()) {
        _toasts.warn('应用文件夹不在了');
        return;
      }
      if (_host.os == HostOs.macos) {
        await Process.run('open', ['-R', entry.dir]);
      } else if (_host.os == HostOs.windows) {
        await Process.run('explorer', ['/select,${entry.dir}']);
      } else {
        await Process.run('xdg-open', [entry.dir]);
      }
    } catch (error) {
      debugPrint('[hotapp] reveal failed: $error');
      _toasts.warn('没能打开文件夹');
    }
  }

  bool get _canExport => _app != null;

  List<_TopBtn> _secondaryActions({required bool narrow}) => [
        _TopBtn(
          icon: Icons.list,
          label: '应用',
          compact: narrow,
          onTap: _generating ? null : _showAppList,
        ),
        _TopBtn(
          icon: Icons.file_open_outlined,
          label: '导入',
          compact: narrow,
          tip: nonAppOpenHint(_host) ?? '打开一个应用包',
          onTap: _generating ? null : _importApp,
        ),
        if (_app != null)
          _TopBtn(
            icon: Icons.save_alt,
            label: '导出',
            compact: narrow,
            tip: _host.isMobile ? '导出到应用文件夹' : '导出为一个应用包文件',
            onTap: (_canExport && !_generating) ? _exportApp : null,
          ),
        if (_entry != null && _host.supportsRevealInFolder)
          _TopBtn(
            icon: Icons.folder_open_outlined,
            label: '在文件夹中显示',
            compact: narrow,
            onTap: _revealApp,
          ),
        if (_app != null)
          _TopBtn(
            icon: Icons.delete_outline,
            label: '删除',
            compact: narrow,
            onTap: _generating ? null : _deleteApp,
          ),
      ];

  // -- 视图 ----------------------------------------------------------------

  Widget _banner(NonPalette p, {required String text, required VoidCallback? onExit, String? exitLabel}) =>
      Container(
        width: double.infinity,
        color: p.accent.withValues(alpha: 0.12),
        padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
        child: Row(children: [
          Icon(Icons.info_outline, size: 15, color: p.accent),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: p.ink2),
            ),
          ),
          if (onExit != null)
            TextButton(
              onPressed: onExit,
              child: Text(exitLabel ?? '知道了', style: const TextStyle(fontSize: 11)),
            ),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Column(
      children: [
        _topBar(p),
        if (_serviceError.isNotEmpty)
          _banner(p, text: _serviceError, onExit: null),
        // NaN 正在用工具生成/精修热应用：给出可见进度，避免界面看起来
        // 「点了没反应」；run 终态后横幅与转圈一起消失，不留无终态转圈。
        if (_agentHotappRunning && !_fromPrototypeBusy)
          _banner(
            p,
            text: 'NaN 正在生成或修改热应用，完成后会自动刷新预览。',
            onExit: null,
          ),
        if (_offlinePath != null)
          _banner(
            p,
            text: '临时预览：这个应用没有保存到本机，重新打开需要再导入一次。',
            onExit: _exitOffline,
            exitLabel: '退出预览',
          ),
        if (_dbUnavailable && _offlinePath == null && _app != null)
          _banner(
            p,
            // db 门失败用 [hotAppDbFailureMessage] 翻成人话；其余打不开路径
            //（离线兜底/非门异常）没有失败对象，用通用文案。
            text: _dbFailure != null
                ? '${hotAppDbFailureMessage(_dbFailure)}，其他功能照常。'
                : '这个应用暂时无法保存数据，其他功能照常。',
            onExit: null,
          ),
        if (_lastError.isNotEmpty) _errorBar(p),
        Expanded(child: _body(p)),
      ],
    );
  }

  Widget _topBar(NonPalette p) {
    return Container(
      height: 46,
      decoration:
          BoxDecoration(color: p.bgElevated, border: Border(bottom: BorderSide(color: p.line))),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      // 窄屏断点：副标题隐藏、标题省略号、动作按钮图标化（390 宽曾溢出）。
      child: LayoutBuilder(builder: (context, constraints) {
        final narrow = constraints.maxWidth < 700;
        return Row(children: [
          // 全屏工作台的可见出口（对齐 3D/视频工作台与 Esc）。
          IconButton(
            icon: const Icon(Icons.arrow_back, size: 18),
            tooltip: '返回主页',
            color: p.ink2,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            onPressed: () => store.setView('home'),
          ),
          const SizedBox(width: 4),
          Icon(Icons.auto_fix_high_outlined, size: 17, color: p.accent),
          const SizedBox(width: 8),
          // 标题可压缩：窄屏先让标题省略，别把 Row 撑爆。
          Flexible(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: narrow ? 120 : 400),
              child: Text(_app == null ? 'NaN 热应用' : '热应用 · $_app',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: p.ink)),
            ),
          ),
          if (_entry != null) ...[
            const SizedBox(width: 6),
            _originBadge(p, _entry!.origin),
          ],
          const SizedBox(width: 10),
          if (!narrow)
            Flexible(
              child: Tooltip(
                message: _title.isEmpty ? '一句话生成 · 在本机运行 · 随时修改' : _title,
                child: Text(
                  _title.isEmpty ? '一句话生成 · 在本机运行 · 随时修改' : '$_title · 随时修改',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: p.ink4),
                ),
              ),
            ),
          const Spacer(),
          // 「由原型生成热应用」的唯一入口（设计工具条上不再重复挂两个一样
          // 的图标）：有原型才可用；生成中显示进度，避免看起来「点了没反应」。
          if (_prototypeReady)
            _TopBtn(
              key: const ValueKey('hotapp-from-prototype'),
              icon: Icons.fact_check_outlined,
              label: _fromPrototypeBusy ? '生成中…' : '由原型生成',
              tip: _fromPrototypeBusy ? '正在生成，完成会自动切到新应用' : '由当前设计原型生成「原型验证 demo」（逐屏逐跳转验证覆盖）',
              onTap: _generating ? null : _generateFromPrototype,
            ),
          if (_generating)
            SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 1.8, color: p.accent)),
          const SizedBox(width: 8),
          if (narrow) ...[
            _TopBtn(icon: Icons.add, label: '新建', compact: true, onTap: _generating ? null : _create),
            if (_app != null)
              _TopBtn(
                icon: Icons.refresh,
                label: '重载',
                compact: true,
                onTap: (_generating || _offlinePath != null) ? null : _reloadPreview,
              ),
            _TopMenu(items: _secondaryActions(narrow: true)),
          ] else ...[
            _TopBtn(icon: Icons.add, label: '新建', onTap: _generating ? null : _create),
            if (_app != null)
              _TopBtn(
                icon: Icons.refresh,
                label: '重载',
                onTap: (_generating || _offlinePath != null) ? null : _reloadPreview,
              ),
            if (_app != null)
              _TopBtn(
                icon: Icons.delete_outline,
                label: '删除',
                onTap: _generating ? null : _deleteApp,
              ),
            _TopBtn(
              icon: Icons.file_open_outlined,
              label: '导入',
              tip: nonAppOpenHint(_host) ?? '打开一个应用包',
              onTap: _busy ? null : _importApp,
            ),
            if (_app != null)
              _TopBtn(
                icon: Icons.save_alt,
                label: '导出',
                tip: _host.isMobile ? '导出到应用文件夹' : '导出为一个应用包文件',
                onTap: (_canExport && !_generating) ? _exportApp : null,
              ),
            if (_app != null)
              _TopBtn(
                icon: Icons.list,
                label: '应用',
                tip: _appList.isEmpty ? '打开应用列表' : '打开应用列表（${_appList.length} 个）',
                onTap: _generating ? null : _showAppList,
              ),
          ],
        ]);
      }),
    );
  }

  Widget _errorBar(NonPalette p) => Container(
        width: double.infinity,
        color: p.danger.withValues(alpha: 0.12),
        padding: const EdgeInsets.fromLTRB(12, 6, 6, 2),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.error_outline, size: 15, color: p.danger),
            const SizedBox(width: 6),
            Expanded(
              child: Text(_lastError,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: p.danger)),
            ),
            if (_app != null && _offlinePath == null && _entry?.isA2ui != true)
              TextButton(
                onPressed: () {
                  final raw = _lastErrorDetail.isEmpty ? _lastError : _lastErrorDetail;
                  setState(() => _refineCtl.text = '修复这个运行错误：$raw');
                },
                child: const Text('填入修改框', style: TextStyle(fontSize: 11)),
              ),
            IconButton(
              tooltip: '忽略',
              visualDensity: VisualDensity.compact,
              onPressed: () => setState(() {
                _lastError = '';
                _lastErrorDetail = '';
              }),
              icon: Icon(Icons.close, size: 14, color: p.ink4),
            ),
          ]),
          if (_lastErrorDetail.trim().isNotEmpty)
            Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: const EdgeInsets.symmetric(horizontal: 20),
                childrenPadding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                dense: true,
                title: Text('技术详情', style: TextStyle(fontSize: 11, color: p.ink4)),
                iconColor: p.ink4,
                collapsedIconColor: p.ink4,
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: SelectableText(
                      _lastErrorDetail,
                      style: TextStyle(fontSize: 10.5, color: p.ink4, height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
        ]),
      );

  Widget _body(NonPalette p) {
    if (_app == null && _offlinePath == null) {
      return _EmptyHotApp(
        onCreate: _generating ? null : _create,
        onOpenPackage: _generating ? null : _importApp,
        hint: nonAppOpenHint(_host),
      );
    }
    final ready = _controller != null;
    return Column(children: [
      Expanded(
        child: ready
            ? WebViewWidget(controller: _controller!)
            : _previewFallback(p),
      ),
      // 对话式修改条：临时预览没有应用可改；卡片型应用没有页面源码可改。
      if (_offlinePath == null && _app != null && _entry?.isA2ui != true)
        _refineBar(p),
    ]);
  }

  /// 浏览器兜底占位（Web 构建 / 路径解析失败时）。
  Widget _browserFallbackBox(NonPalette p) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.open_in_browser_outlined, size: 40, color: p.ink4),
          const SizedBox(height: 12),
          Text('这台电脑暂时不能在应用内预览', style: TextStyle(fontSize: 14, color: p.ink2)),
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Text(
              '可以用系统浏览器打开预览；文件就在本机，不会上传。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: p.ink4, height: 1.6),
            ),
          ),
          const SizedBox(height: 14),
          Wrap(spacing: 10, runSpacing: 8, alignment: WrapAlignment.center, children: [
            FilledButton.icon(
              onPressed: _openExternally,
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('用浏览器打开'),
            ),
            OutlinedButton.icon(
              onPressed: _copyPreviewPath,
              icon: const Icon(Icons.copy_all_outlined, size: 16),
              label: const Text('复制文件路径'),
            ),
            if (_host.supportsRevealInFolder)
              OutlinedButton.icon(
                onPressed: _revealApp,
                icon: const Icon(Icons.folder_open_outlined, size: 16),
                label: const Text('在文件夹中显示'),
              ),
          ]),
        ]),
      ),
    );
  }

  /// 没有应用内预览时的诚实占位：可执行的两条出路（浏览器 / 文件夹）。
  Widget _previewFallback(NonPalette p) {
    if (_booting && _lastError.isEmpty) {
      return Center(
        child: Text('正在打开…', style: TextStyle(fontSize: 12, color: p.ink3)),
      );
    }
    if (!_host.supportsInAppWebView) {
      return _browserFallbackBox(p);
    }
    if (_entry?.isA2ui == true) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.dashboard_customize_outlined, size: 38, color: p.ink4),
          const SizedBox(height: 10),
          Text('这个应用以卡片方式打开', style: TextStyle(fontSize: 13, color: p.ink2)),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () => _requestMount(_app!),
            child: const Text('再次打开'),
          ),
        ]),
      );
    }
    return Center(
      child: Text(
        _serviceError.isNotEmpty ? _serviceError : '还没有打开应用',
        style: TextStyle(fontSize: 12, color: p.ink3),
      ),
    );
  }

  Widget _refineBar(NonPalette p) => Container(
        decoration:
            BoxDecoration(color: p.bgElevated, border: Border(top: BorderSide(color: p.line))),
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
        child: Row(children: [
          Expanded(
            child: TextField(
              controller: _refineCtl,
              style: TextStyle(fontSize: 12.5, color: p.ink),
              onSubmitted: _generating ? null : _refine,
              decoration: InputDecoration(
                hintText: '告诉它怎么改：换成绿色 / 加一个重置按钮 / 动画再快一点…',
                hintStyle: TextStyle(fontSize: 12, color: p.ink4),
                isDense: true,
                filled: true,
                fillColor: p.panel2,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: p.line)),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            onPressed: _generating ? null : () => _refine(_refineCtl.text),
            icon: const Icon(Icons.arrow_upward, size: 17),
            style: IconButton.styleFrom(backgroundColor: p.accent),
          ),
        ]),
      );
}

class _EmptyHotApp extends StatelessWidget {
  const _EmptyHotApp({required this.onCreate, this.onOpenPackage, this.hint});
  final VoidCallback? onCreate;

  /// 打开本地应用包（应用内打开入口；系统关联与拖拽走同一函数）。
  final VoidCallback? onOpenPackage;

  /// 平台提示（Linux/Windows 没有文件关联时明示「从应用内打开」）。
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.auto_fix_high_outlined, size: 44, color: p.ink4),
          const SizedBox(height: 14),
          Text('NaN 热应用',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: p.ink)),
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Text(
              '用一句话生成动画、演示或可玩的小应用。\n'
              '生成的内容就在本机运行，随时可以继续修改，也会收进作品集。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: p.ink3, height: 1.7),
            ),
          ),
          if (hint != null) ...[
            const SizedBox(height: 10),
            Text(
              hint!,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: p.ink4, height: 1.5),
            ),
          ],
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
                label: const Text('打开应用包…'),
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
    super.key,
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

  /// 覆盖默认 tooltip（如导出目标在手机上不是保存对话框）。
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
                  Text(label,
                      style:
                          TextStyle(fontSize: 12, color: onTap == null ? p.ink4 : p.ink2)),
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
                style:
                    TextStyle(fontSize: 13, color: items[i].onTap == null ? p.ink4 : p.ink),
              ),
            ]),
          ),
      ],
    );
  }
}
