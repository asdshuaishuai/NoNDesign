/// 3D 制作工作台（批次 06：全本地）。
///
/// 应用内 WebView 就是执行面：预览页与场景代码、渲染库**同目录**落盘，按
/// 文件直接加载（不走端口、不走内部路由、不引远端 CDN）。预览页回传三类
/// 反馈（执行错误 / 场景测量 / 截图），驱动分层修复轮。
///
/// 数据面全部由 [ThreeService] 承担：规范先行、六层推进、进度权威在磁盘、
/// 每步带证据。界面只做三件事：把状态画出来、把用户动作翻译成一次服务调用、
/// 把失败翻成一句人话（原始诊断进折叠的「技术详情」）。
///
/// 执行面有两条：预览页默认把场景脚本放进 vendored three-live 的
/// `allow-client-scripts` 沙箱 Worker（真实执行，非截图/外链）；沙箱被宿主拦掉
/// 或场景为空时，页面自动降到同一份 HTML 里的内联渲染库直跑（旧路径），
/// 两条路都经 `window.NON3D` 回传 error / metrics / screenshot 三类桥消息。
/// 空态另有一块「ThreeUI 组件」画廊：vendored 自包含页面由应用内 WebView
/// 按资源键读取渲染，点开即真实运行。
///
/// 平台矩阵（唯一判据是 [PlatformCapabilities]，不再自己嗅探平台）：
///  * 内嵌 3D 预览与 ThreeUI 组件画廊统一走 `webview_all`（macOS/iOS WKWebView、
///    Windows WebView2、Linux WebKitGTK、Android WebView）；移动端还额外受
///    [ThreeWebViewGate] 约束（file:// 模块脚本未验证前不启用）；
///  * 「在文件夹中显示」只在桌面三平台出现。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:webview_all/webview_all.dart';
import 'package:webview_all_wkwebview/webview_all_wkwebview.dart';

import '../core/platform_capabilities.dart';
import '../core/store.dart';
import '../core/theme.dart';
import '../core/three_kits.dart';
import '../core/three_lint.dart';
import '../core/three_service.dart';
import '../core/toast_service.dart';
import 'common.dart';

/// 移动端内嵌 3D 预览的启用门。
///
/// 预览页是**自包含**的（渲染库与场景在挂载时内联，见 `assembleThreePreview`）
/// ——实测 file:// 下的模块 import 会被 WKWebView/Chromium 双双按 CORS 拒绝，
/// 内联后 macOS WKWebView 与 Chromium 都能渲染出土星场景（metrics 与截图桥都
/// 通了）。但手机/平板的系统 WebView 版本与插件行为仍需真机验证：必须由
/// `integration_test/three_webview_test.dart` 跑通后才能放开。未通过前移动端
/// 不构造预览控制器——诚实降级为「用电脑上的连接桌面查看」，绝不让用户对着
/// 永远白屏的预览干等。
abstract final class ThreeWebViewGate {
  /// 构建期开关：验证通过后由批次负责人显式打开。
  static const bool mobileFileModulesVerified = bool.fromEnvironment(
    'NONDESIGN_MOBILE_THREE_VERIFIED',
    defaultValue: false,
  );

  /// 这台主机能否本地内嵌 3D 预览。
  static bool allowsLocalPreview(PlatformCapabilities host) =>
      !host.isMobile || mobileFileModulesVerified;
}

/// webview_all 的 WKWebView 平台在插件注册中自动就绪；测试环境保留幂等注册兜底。
bool _wkRegistered = false;

/// 测试注入：平台矩阵的确定性覆盖（测试机恒为 macOS，造不出 Linux/Windows
/// 环境——置 false 即走「无 WebView 平台」的降级分支，与真机同一条代码路）。
@visibleForTesting
bool? debugThreeWebViewSupported;

/// 作品集「打开」直载：切视图前设置，ThreeWorkspace.initState 消费后清空
/// （与 hotAppLoadOnOpen 同构的跨实例传名通道）。
String? threeLoadOnOpen;

class ThreeWorkspace extends StatefulWidget {
  const ThreeWorkspace({super.key, this.service});

  /// 本地面。生产为 null（[ThreeService.open] 解析用户文档目录）；测试注入
  /// 一个指向临时目录、模型调用与资源都可控的实例。
  final ThreeService? service;

  @override
  State<ThreeWorkspace> createState() => _ThreeWorkspaceState();
}

class _ThreeWorkspaceState extends State<ThreeWorkspace> {
  String? _project;
  ThreeService? _service;
  ThreeProjectSnapshot? _snapshot;
  // 面板三态：预览 / 源码 / 规范（规范手编 = 先改规范再要代码）。
  String _face = 'preview';
  final _specCtl = TextEditingController();
  // 规范编辑守卫：每条预览桥消息与每次生成都会刷新快照——用户在规范页
  // 未保存的编辑不能被静默覆盖；保存成功后重置守卫恢复正常同步。
  bool _specDirty = false;
  bool _busy = false;
  WebViewController? _controller;
  String _lastError = '';
  // 预览不可用/加载失败的可读占位（非空时预览区整块替换）。
  String _loadError = '';
  String _loadDetail = '';
  // 错误横幅：可读句子 + 折叠的技术详情。去重键用原始 detail，避免同一错误
  // 被每条桥反馈反复重置。
  String _errorText = '';
  String _errorDetail = '';
  String _errorKey = '';
  // 横幅来源：`refresh` 的失败由下一次成功刷新自愈；`action` 的失败留到用户
  // 下一次动作（或手动关闭）——成功刷新不得把动作失败静默抹掉。
  String _errorSource = '';
  // 服务本身不可用（目录解析失败等）：整块工作台退化为可读提示。
  String _serviceError = '';
  // 预览就绪态：截图 / 四方位取证只在页面**真的跑起来**后可用。判据是预览页
  // 自带的 metrics 桥（首帧后主动上报，此后每 2s 一次）。**不要换成
  // setOnPageFinished**：webview_all 平台接口基类的 setOnPageFinished 直接
  // throw UnimplementedError，而 NavigationDelegate 构造器会同步调用它。
  bool _previewReady = false;
  // ThreeUI 组件画廊：清单从应用资源读（失败不空屏，显示可重试的人话）。
  List<ThreeUiComponent>? _uiCatalog;
  String _uiCatalogError = '';
  bool _uiCatalogLoading = false;

  // -- store 同步（NaN 在工作台里生成之后，界面必须跟着磁盘/设置变化） -------
  //
  // 工作台视图切换即 dispose，唯一跨实例的状态源是 AppStore：`NaN` 的
  // `three_*` 工具成功后会写 `settings.threeProjectName` 并 notify（见
  // AppStore._adoptWorkspaceArtifact）。工作台**必须**订阅这个通知，否则运行
  // 结束只看到「3D 工作台已更新」，界面却停在旧项目/空项目/旧预览上——这
  // 就是「run 结束但工作台里没有东西」的根因。
  //
  // 同步水位：自己改 store 项目名时先推进水位，避免同一动作被通知回灌成
  // 「外部切换」重跑一遍（重复读盘 + 重复挂预览会闪）。
  String _lastStoreProject = '';
  bool _lastAgentBusy = false;

  /// boot 还没拿到 [ThreeService] 时收到的外部项目名，_boot 完成后接上。
  String _pendingStoreProject = '';

  /// 运行中的节流轮询：把磁盘进度（当前层 / 场景代码）拉进界面。
  Timer? _runPoll;

  /// 事件式刷新的 500ms 合并窗口（run 中流式正文每 80ms 就 notify，逐条
  /// 读盘会让界面抖动）。
  Timer? _autoRefreshDebounce;

  /// 当前项目的异步读盘序号：切项目后旧项目的迟到快照不得覆盖新项目。
  int _projectSeq = 0;

  /// 项目列表缓存：store 通知 / run 结束 / 打开项目时重扫；弹窗仍实时读一次
  /// （列表是磁盘权威，缓存只用于面板与测试观察）。
  List<ThreeProjectEntry> _projects = const [];

  late final AppStore _store = context.read<AppStore>();
  AppStore get store => _store;

  PlatformCapabilities get _host => store.capabilities.platform;

  ToastService get _toasts => store.toasts;

  Map<String, dynamic>? get _state => _snapshot?.state;

  String get _sceneJs => _snapshot?.sceneJs ?? '';

  /// webview_all 覆盖全部应用目标（WKWebView / WebView2 / WebKitGTK /
  /// Android WebView）；移动端另受 [ThreeWebViewGate] 约束。
  /// 测试用 [debugThreeWebViewSupported] 覆盖。
  bool get _webViewSupported =>
      debugThreeWebViewSupported ??
      (_host.supportsInAppWebView && ThreeWebViewGate.allowsLocalPreview(_host));

  /// 3D 场景预览的内嵌执行面。
  bool get _scenePreviewSupported => _webViewSupported;

  @override
  void initState() {
    super.initState();
    // 移动端由插件注册自动完成；macOS 无 endorsed 实现才需要幂等注册。
    // 桌面 Windows/Linux 注册 WebKit 无意义；`instance == null` 守卫另兼测试
    // 卫生：fake 平台注入后不得被覆盖。
    if ((Platform.isMacOS || Platform.isIOS) && !_wkRegistered && WebViewPlatform.instance == null) {
      WebKitWebViewPlatform.registerWith();
      _wkRegistered = true;
    }
    _specCtl.addListener(() => _specDirty = true);
    // 视图切换会 dispose 本工作台——优先消费作品集直载的项目名，其次从
    // 持久化项目名续接（跨会话亦然）。
    final pending = threeLoadOnOpen;
    threeLoadOnOpen = null;
    final saved = pending ?? store.settings.threeProjectName;
    // 订阅 store：NaN 的 three_* 工具成功后会写 threeProjectName（跨实例的
    // 唯一通道），run 结束也会 notify——不订阅就永远看不到新项目/新层。
    _lastStoreProject = store.settings.threeProjectName.trim();
    _lastAgentBusy = store.agentBusy;
    store.addListener(_onStoreNotify);
    if (_lastAgentBusy) _ensureRunPoll();
    // 首帧后再落 store（initState 里 notifyListeners 会在构建期触发祖先重建）。
    WidgetsBinding.instance.addPostFrameCallback((_) => _boot(pending: pending, saved: saved));
  }

  @override
  void dispose() {
    // 未保存的规范编辑跨视图保留（按项目名持久化草稿）——工作台切换即
    // dispose，没有草稿 = 用户手编的内容静默丢失。持久化延后到帧末：
    // dispose 常发生在构建期，notifyListeners 会标记祖先脏。
    _stashDraft(defer: true);
    _runPoll?.cancel();
    _runPoll = null;
    _autoRefreshDebounce?.cancel();
    _autoRefreshDebounce = null;
    _store.removeListener(_onStoreNotify);
    _specCtl.dispose();
    super.dispose();
  }

  // -- store 同步 -----------------------------------------------------------

  /// store 通知入口：判断「外部项目名变了 / run 结束了 / run 在飞」，真正
  /// 的读盘与界面更新交给下面的异步方法。构建期通知推到帧末再处理
  /// （构建期 setState 会抛「during build」）。
  void _onStoreNotify() {
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _applyStoreChange();
      });
      return;
    }
    _applyStoreChange();
  }

  void _applyStoreChange() {
    if (!mounted) return;
    final name = store.settings.threeProjectName.trim();
    final busy = store.agentBusy;
    final nameChanged = name != _lastStoreProject;
    final runEnded = _lastAgentBusy && !busy;
    _lastStoreProject = name;
    _lastAgentBusy = busy;
    if (busy) {
      _ensureRunPoll();
    } else {
      _stopRunPoll();
    }
    // NaN 在 run 里创建/切到另一个 3D 项目：工作台要跟过去（而不是停在旧
    // 项目/空态上），并重扫列表、按磁盘进度刷新、重挂预览。
    if (nameChanged && name.isNotEmpty && name != _project) {
      unawaited(_adoptProject(name));
      return;
    }
    if (runEnded) {
      // run 终态：强制再刷一次并重载预览——最后一层/最后一段代码可能在
      // done 之后才落盘，只靠运行中的节流刷新会漏掉「最后一次更新」。
      unawaited(_reloadCurrent(reloadPreview: true, force: true));
      return;
    }
    if (busy || nameChanged) unawaited(_reloadCurrent());
  }

  /// 外部指定的项目（NaN 生成成功 / 作品集直载）：切过去、恢复该项目自己
  /// 的规范草稿、按磁盘进度刷新并重挂预览。旧项目未保存的规范编辑先落草稿。
  Future<void> _adoptProject(String name) async {
    if (name.isEmpty) return;
    final service = _service;
    if (service == null) {
      // boot 还在解析服务：先记下，_boot 完成后接上（这次切换不能被吞掉）。
      _pendingStoreProject = name;
      return;
    }
    if (name == _project) {
      await _reloadCurrent(force: true);
      return;
    }
    final token = ++_projectSeq;
    // 旧项目未保存的规范编辑落草稿：帧末写回，避免在 store 通知回调里再次
    // notifyListeners（重入会让其它监听者收到嵌套通知）。
    _stashDraft(defer: true);
    final draft = store.threeSpecDraft(name);
    if (!mounted || token != _projectSeq) return;
    setState(() {
      _project = name;
      _snapshot = null;
      _controller = null;
      _previewReady = false;
      _lastError = '';
      _loadError = '';
      _loadDetail = '';
      _errorKey = '';
      _errorText = '';
      _errorDetail = '';
      _errorSource = '';
      // 项目边界复位规范编辑守卫：A 项目未保存的编辑不能带进 B；B 自己的
      // 未保存草稿要恢复（跨视图/跨 run 都不丢）。
      _specDirty = false;
      if (draft != null && draft.isNotEmpty) {
        _specCtl.text = draft;
        _specDirty = true;
      }
    });
    await _reloadProjects();
    if (!mounted || token != _projectSeq) return;
    await _refresh();
    if (!mounted || token != _projectSeq) return;
    await _mountPreview();
  }

  /// 当前项目按磁盘态刷新（节流）：run 中的通知很密（流式正文每 80ms 就
  /// 通知），每次都读盘会让界面抖动；500ms 合并窗口内只真正刷一次，定时
  /// 轮询负责兜底。run 结束用 [force] 立刻刷（最后一层不能被节流吞掉）。
  Future<void> _reloadCurrent({bool reloadPreview = false, bool force = false}) async {
    if (!mounted) return;
    if (!force) {
      _autoRefreshDebounce ??= Timer(const Duration(milliseconds: 500), () {
        _autoRefreshDebounce = null;
        unawaited(_reloadCurrent(force: true));
      });
      return;
    }
    _autoRefreshDebounce?.cancel();
    _autoRefreshDebounce = null;
    if (_service == null || _project == null) {
      await _reloadProjects();
      return;
    }
    await _refresh();
    await _reloadProjects();
    if (reloadPreview && mounted) await _mountPreview();
  }

  /// run 在飞时每 600ms 拉一次磁盘进度（当前层 / 场景代码），让工作台在
  /// 生成过程中就往前走，而不是等终态一次性跳变（也别永远转圈）。
  void _ensureRunPoll() {
    if (_runPoll != null) return;
    _runPoll = Timer.periodic(const Duration(milliseconds: 600), (_) {
      if (!mounted || !store.agentBusy) {
        _stopRunPoll();
        return;
      }
      unawaited(_reloadCurrent());
    });
  }

  void _stopRunPoll() {
    _runPoll?.cancel();
    _runPoll = null;
  }

  /// 重扫项目列表（缓存）：NaN 新建/删除项目后，「项目」菜单不能停在旧列表。
  Future<void> _reloadProjects() async {
    final service = _service;
    if (service == null) return;
    try {
      final items = await service.listProjects();
      if (!mounted) return;
      // 列表变了才 setState（运行中每 600ms 的轮询不该整树重建）。
      var same = items.length == _projects.length;
      if (same) {
        for (var i = 0; i < items.length; i++) {
          final a = items[i];
          final b = _projects[i];
          if (a.name != b.name || a.current != b.current || a.blocked != b.blocked) {
            same = false;
            break;
          }
        }
      }
      _projects = items;
      if (!same) setState(() {});
    } catch (error) {
      // 列表是旁路缓存：读失败不打断主流程（打开「项目」弹窗仍会实时再读）。
      debugPrint('[three] list projects failed: $error');
    }
  }

  /// 工作台自己改 store 的项目名：先推进水位，避免 store 通知把本次切换
  /// 当成外部切换再跑一遍（重复读盘 + 重复挂预览会闪）。
  void _setStoreProject(String name) {
    _lastStoreProject = name;
    store.setThreeProjectName(name);
  }

  Future<void> _boot({required String? pending, required String saved}) async {
    final ThreeService service;
    if (widget.service != null) {
      service = widget.service!;
    } else {
      try {
        service = await ThreeService.open();
      } catch (error) {
        if (!mounted) return;
        setState(() => _serviceError = '$error');
        return;
      }
    }
    if (!mounted) return;
    // 根目录允许尚不存在（首次运行/只有空项目），真正写入时自己建；
    // 只有「路径被一个文件占住」才是硬错误。
    if (File(service.root.path).existsSync()) {
      setState(() => _serviceError = 'root is not a directory: ${service.root.path}');
      return;
    }
    _service = service;
    unawaited(_loadUiCatalog());
    unawaited(_reloadProjects());
    // boot 期间 store 可能已经收到外部项目名（NaN 正在 run 并且刚建好项目）：
    // 打开工作台的瞬间就以它为准，不要停在旧项目上。作品集直载（pending）
    // 优先级最高。
    final external = _pendingStoreProject.isNotEmpty
        ? _pendingStoreProject
        : store.settings.threeProjectName.trim();
    _pendingStoreProject = '';
    final wanted = pending != null ? saved : (external.isNotEmpty ? external : saved);
    if (pending != null && store.settings.threeProjectName.trim() != pending) {
      _setStoreProject(pending);
    }
    if (wanted.isNotEmpty) {
      final token = ++_projectSeq;
      _project = wanted;
      final draft = store.threeSpecDraft(wanted);
      if (draft != null && draft.isNotEmpty) {
        _specCtl.text = draft;
        _specDirty = true; // listener 已置位；显式声明防快照覆盖
      }
      await _refresh();
      if (!mounted || token != _projectSeq) return;
      await _mountPreview();
    }
    _lastAgentBusy = store.agentBusy;
    if (store.agentBusy) _ensureRunPoll();
    if (mounted) setState(() {});
  }

  /// 把当前项目未保存的规范编辑落进草稿（项目切换/视图 dispose 边界）。
  void _stashDraft({bool defer = false}) {
    final project = _project;
    if (project == null || !_specDirty || _specCtl.text.trim().isEmpty) return;
    final text = _specCtl.text;
    if (defer) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _store.setThreeSpecDraft(project, text));
    } else {
      _store.setThreeSpecDraft(project, text);
    }
  }

  // -- 数据面 ---------------------------------------------------------------

  Future<void> _refresh() async {
    final service = _service;
    final project = _project;
    if (service == null || project == null) return;
    try {
      final snapshot = await service.readProject(project);
      // 切项目后迟到的旧快照不得覆盖新项目（异步读盘与通知会交错）。
      if (!mounted || project != _project) return;
      setState(() {
        if (_errorSource == 'refresh') {
          _errorKey = '';
          _errorText = '';
          _errorDetail = '';
          _errorSource = '';
        }
        _snapshot = snapshot;
        if (!_specDirty) {
          _specCtl.text = const JsonEncoder.withIndent('  ').convert(snapshot.spec);
          _specDirty = false; // 文本赋值时 listener 已置位，恢复未脏
        }
      });
    } on ThreeFailure catch (failure) {
      _showError(threeFailureMessage(failure), failure.detail,
          key: '${failure.code}|${failure.detail}', source: 'refresh', notify: false);
    } catch (error) {
      _showError(threeFailureMessage(null), '$error',
          key: '$error', source: 'refresh', notify: false);
    }
  }

  /// 错误横幅 + 一条可读提示。相同错误去重（桥反馈每条都跟一次刷新，
  /// 不重置同一条错误、不叠同文提示）。
  /// [notify] 为 false 时只更新常驻横幅、不发通知——状态类失败（刷新读不到
  /// 项目）用横幅表达就够，再叠一条通知是同一件事说两遍。
  void _showError(String text, String detail,
      {String? key, String source = 'action', bool notify = true}) {
    final resolvedKey = key ?? '$text|$detail';
    if (resolvedKey == _errorKey) return;
    if (!mounted) return;
    setState(() {
      _errorKey = resolvedKey;
      _errorText = text;
      _errorDetail = detail;
      _errorSource = source;
    });
    if (notify) _toasts.warn(text);
  }

  void _clearError() {
    if (_errorKey.isEmpty && _errorText.isEmpty) return;
    setState(() {
      _errorKey = '';
      _errorText = '';
      _errorDetail = '';
      _errorSource = '';
    });
  }

  /// 新动作开始：上一轮的动作失败退场（刷新失败保留，等刷新自愈）。
  void _beginAction() {
    if (_errorSource == 'action') _clearError();
  }

  // -- ThreeUI 组件画廊 -----------------------------------------------------

  /// 读取 vendored ThreeUI 组件清单（应用资源，离线）。
  ///
  /// 清单读不出来不影响 3D 主流程：画廊区显示一句人话 + 重试，不空屏、不
  /// 阻塞工作台其余部分。
  Future<void> _loadUiCatalog() async {
    final service = _service;
    if (service == null || _uiCatalogLoading) return;
    _uiCatalogLoading = true;
    try {
      final catalog = await service.loadUiCatalog();
      if (!mounted) return;
      setState(() {
        _uiCatalog = catalog;
        _uiCatalogError = '';
      });
    } on ThreeFailure {
      if (!mounted) return;
      setState(() => _uiCatalogError = '组件清单没有读出来，请重试');
    } catch (error) {
      if (!mounted) return;
      setState(() => _uiCatalogError = '组件清单没有读出来，请重试');
    } finally {
      _uiCatalogLoading = false;
    }
  }

  /// 打开一个 ThreeUI 组件页（应用内 WebView 真实渲染）。
  Future<void> _openThreeUi(ThreeUiComponent component) async {
    if (!_webViewSupported) {
      _toasts.warn('这台设备不支持内嵌组件预览', '可以在电脑上打开同一个应用查看。');
      return;
    }
    await showNonDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => _ThreeUiViewerDialog(
        component: component,
        webViewSupported: _webViewSupported,
      ),
    );
  }

  /// 已开项目时也能进画廊：弹一个可滚动的卡片面板，点开即渲染。
  Future<void> _openGalleryPicker() async {
    var catalog = _uiCatalog;
    if (catalog == null || catalog.isEmpty) {
      await _loadUiCatalog();
      if (!mounted) return;
      catalog = _uiCatalog;
    }
    if (catalog == null || catalog.isEmpty) {
      _toasts.warn('组件清单没有读出来', '可以先继续做场景，稍后再试。');
      return;
    }
    final choice = await showNonDialog<ThreeUiComponent>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: ctx.palette.panel,
        title: Text('ThreeUI 组件',
            style: TextStyle(
                fontSize: 15, fontWeight: FontWeight.w700, color: ctx.palette.ink)),
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620, maxHeight: 460),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: _ThreeUiGallery(
                catalog: catalog,
                onOpen: (component) => Navigator.pop(ctx, component),
              ),
            ),
          ),
        ],
      ),
    );
    if (choice != null && mounted) await _openThreeUi(choice);
  }

  // -- 场景质检 -------------------------------------------------------------

  ThreeLintReport? get _lint {
    final snapshot = _snapshot;
    if (snapshot == null) return null;
    return lintThreeProject(snapshot);
  }

  String _lintLabel() {
    final lint = _lint;
    if (lint == null) return '质检';
    if (lint.errors > 0) return '质检 ${lint.errors}';
    if (lint.warns > 0) return '质检 ${lint.warns}';
    return '质检 通过';
  }

  /// 只读质检面板：把「场景为什么看起来不对」拆成可修的条目，而不是一句
  /// 主观评价。数据全部来自磁盘快照，打开面板不产生任何变更。
  Future<void> _showLint() async {
    final lint = _lint;
    if (lint == null) return;
    final p = context.palette;
    await showNonDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.panel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Row(children: [
          Icon(Icons.rule_outlined, size: 18, color: p.accent),
          const SizedBox(width: 8),
          Text('场景质检',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: p.ink)),
          const Spacer(),
          Text(
            lint.clean
                ? '通过'
                : '${lint.errors} 必修 · ${lint.warns} 建议',
            style: TextStyle(
                fontSize: 11,
                color: lint.errors > 0 ? p.danger : (lint.warns > 0 ? p.warn : p.success)),
          ),
        ]),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: lint.clean
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    child: Text('场景没有可判定的问题：相机、灯光、材质与六层进度都成立。',
                        style: TextStyle(fontSize: 12, color: p.ink3)),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final issue in lint.issues)
                        Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: p.panel2.withValues(alpha: 0.4),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: p.line),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(children: [
                                Icon(
                                  issue.level == ThreeLintLevel.error
                                      ? Icons.error_outline
                                      : issue.level == ThreeLintLevel.warn
                                          ? Icons.warning_amber_outlined
                                          : Icons.info_outline,
                                  size: 14,
                                  color: issue.level == ThreeLintLevel.error
                                      ? p.danger
                                      : issue.level == ThreeLintLevel.warn
                                          ? p.warn
                                          : p.ink4,
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(issue.title,
                                      style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                          color: p.ink)),
                                ),
                              ]),
                              if (issue.detail.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text(issue.detail,
                                      style: TextStyle(fontSize: 11, height: 1.5, color: p.ink3)),
                                ),
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text('怎么修：${issue.fix}',
                                    style: TextStyle(fontSize: 11, color: p.accent)),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('知道了')),
        ],
      ),
    );
  }

  // -- 用户动作 -------------------------------------------------------------

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
              decoration: const InputDecoration(labelText: '项目名（字母、数字、短横线）', hintText: 'saturn-demo'),
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
    final name = nameCtl.text.trim();
    final brief = briefCtl.text.trim();
    // 控制器不 here 手动 dispose：弹窗的退场动画还在跑，TextField 仍然持有
    // 它们（dispose 后立即释放会在退场帧里抛「used after being disposed」）。
    // 弹窗是短命对象，交给 GC。
    if (ok != true) return;
    // 弹窗打开期间视图可能已被切走——await 之后必须先验 mounted 再 setState。
    if (!mounted) return;
    if (name.isEmpty || brief.isEmpty) return;
    _beginAction();
    final service = _service;
    final config = _llmConfig();
    if (service == null) {
      _toasts.warn('3D 场景的存储目录还没有准备好');
      return;
    }
    if (!config.isConfigured) {
      _toasts.warn('先在设置里配好模型连接', '3D 生成使用当前选中的模型。');
      return;
    }
    setState(() => _busy = true);
    try {
      final snapshot = await service.newProject(name: name, brief: brief, config: config);
      if (!mounted) return;
      _stashDraft(); // 旧项目未保存的规范编辑先存草稿
      setState(() {
        _project = name;
        _snapshot = snapshot;
        _lastError = '';
        _specDirty = false;
        _loadError = '';
        _loadDetail = '';
        _errorKey = '';
        _errorText = '';
        _errorDetail = '';
      });
      _setStoreProject(name);
      await _mountPreview();
      unawaited(_reloadProjects());
      final components = (snapshot.spec['components'] as List?)?.length ?? 0;
      _toasts.success('规范已生成（$components 组件）', '点「生成当前层」开始第一层。');
    } on ThreeFailure catch (failure) {
      _showError(threeFailureMessage(failure), failure.detail, key: '${failure.code}|${failure.detail}');
    } catch (error) {
      _showError(threeFailureMessage(null), '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 从一个场景套件直接新建项目：套件的 brief 就是规范阶段的一句话目标，
  /// 用户不用先想清楚构图（three-live Domain Kits 的用法）。
  Future<void> _createFromKit(ThreeKit kit) async {
    if (_busy) return;
    final service = _service;
    final config = _llmConfig();
    if (service == null) {
      _toasts.warn('3D 场景的存储目录还没有准备好');
      return;
    }
    if (!config.isConfigured) {
      _toasts.warn('先在设置里配好模型连接', '3D 生成使用当前选中的模型。');
      return;
    }
    setState(() => _busy = true);
    try {
      ThreeProjectSnapshot? snapshot;
      Object? lastError;
      for (var i = 0; i < 3 && snapshot == null; i++) {
        final name = i == 0 ? kit.id : '${kit.id}-${i + 1}';
        try {
          snapshot = await service.newProject(name: name, brief: kit.brief, config: config);
          _setStoreProject(name);
        } on ThreeFailure catch (failure) {
          if (failure.code != 'project_exists') rethrow;
          lastError = failure;
        }
      }
      if (snapshot == null) {
        throw lastError ?? const ThreeFailure('project_exists');
      }
      if (!mounted) return;
      setState(() {
        _project = snapshot!.name;
        _snapshot = snapshot;
        _lastError = '';
        _specDirty = false;
        _loadError = '';
        _loadDetail = '';
        _errorKey = '';
        _errorText = '';
        _errorDetail = '';
      });
      await _mountPreview();
      unawaited(_reloadProjects());
      final components = (snapshot.spec['components'] as List?)?.length ?? 0;
      _toasts.success('${kit.name}：规范已生成（$components 组件）', '点「生成当前层」开始第一层。');
    } on ThreeFailure catch (failure) {
      _showError(threeFailureMessage(failure), failure.detail, key: '${failure.code}|${failure.detail}');
    } catch (error) {
      _showError(threeFailureMessage(null), '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  ThreeLlmConfig _llmConfig() {
    final settings = store.settings;
    return ThreeLlmConfig(
      model: settings.modelId,
      baseUrl: settings.baseUrl,
      apiKey: settings.apiKey,
      thinkingLevel: settings.thinkingLevel,
    );
  }

  /// 挂载预览：先把三件套落到项目目录（同目录），再按文件加载。
  ///
  /// 生成的页面是**自包含**的：渲染库与场景源码在挂载时内联进同一个模块脚本
  /// ——file:// 下模块 import / fetch 会被 CORS 拦死（WKWebView 与 Chromium
  /// 都实测过），内联后页面零文件读取。每次重建控制器都重新组装（版本注释换新），
  /// 就绪态归零，等预览页的 metrics 桥重新点亮。
  Future<void> _mountPreview() async {
    if (!_scenePreviewSupported) return;
    final service = _service;
    final project = _project;
    if (service == null || project == null) return;
    _previewReady = false;
    final ThreePreviewBundle bundle;
    try {
      bundle = await service.preparePreview(project);
    } on ThreeFailure catch (failure) {
      if (!mounted || project != _project) return;
      _setLoadError(threeFailureMessage(failure), failure.detail);
      return;
    } catch (error) {
      if (!mounted || project != _project) return;
      _setLoadError(threeFailureMessage(null), '$error');
      return;
    }
    // 准备预览是异步写盘：期间切了项目就不再挂旧项目的页面（否则新项目
    // 的预览会闪回旧内容）。
    if (!mounted || project != _project) return;
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel('NON3D', onMessageReceived: _onBridgeMessage)
      ..setNavigationDelegate(NavigationDelegate(
        onWebResourceError: _onPreviewResourceError,
        onPageStarted: _onPreviewPageStarted,
      ))
      ..loadFile(bundle.htmlPath);
    setState(() {
      _controller = controller;
      _loadError = '';
      _loadDetail = '';
    });
  }

  void _onPreviewResourceError(WebResourceError error) {
    // 子资源（脚本/贴图）失败不整块替换——只有主帧失败才是「预览打不开」。
    if (error.isForMainFrame == false) return;
    _setLoadError('预览加载失败，请重试', '${error.description} (${error.errorCode})');
  }

  void _onPreviewPageStarted(String url) {
    // 新导航开始：旧页的就绪态作废（本次导航失败会经资源错误置占位）。
    final wasReady = _previewReady;
    _previewReady = false;
    if (!mounted) return;
    if (_loadError.isNotEmpty) {
      // 新导航开始：清旧占位，失败会再置。
      setState(() {
        _loadError = '';
        _loadDetail = '';
      });
    } else if (wasReady) {
      setState(() {}); // 就绪 → 未就绪：截图/四方位按钮要跟着变灰
    }
  }

  /// 截图 / 四方位取证：把脚本送进预览页。
  void _runPreviewScript(String script) {
    unawaited(_controller?.runJavaScript(script));
  }

  void _setLoadError(String message, [String detail = '']) {
    _previewReady = false; // 主帧失败：截图/四方位立即失效
    if (!mounted) return;
    setState(() {
      _loadError = message;
      _loadDetail = detail;
    });
  }

  /// 错误占位的重试：清占位并重新准备/加载预览。
  Future<void> _retryPreview() async {
    _previewReady = false;
    if (!mounted) return;
    setState(() {
      _loadError = '';
      _loadDetail = '';
    });
    await _mountPreview();
  }

  /// 预览页反馈桥：error 加修复轮、metrics 记录、screenshot 落证据。
  Future<void> _onBridgeMessage(JavaScriptMessage msg) async {
    final service = _service;
    final project = _project;
    if (service == null || project == null) return;
    final Map<String, dynamic> data;
    try {
      data = (jsonDecode(msg.message) as Map).cast<String, dynamic>();
    } catch (_) {
      return;
    }
    final kind = '${data['kind'] ?? ''}';
    try {
      if (kind == 'error') {
        final message = '${data['message'] ?? ''}';
        if (message == _lastError) return; // 同错误去重（onerror 每帧触发会刷屏）
        _lastError = message;
        await service.feedback(project, 'error', message);
      } else if (kind == 'metrics') {
        // 预览页活着的第一信号：只有此刻起截图 / 四方位取证才有真实执行面。
        // 错误占位在场时不点亮。
        if (_loadError.isEmpty && !_previewReady && mounted) {
          setState(() => _previewReady = true);
        }
        await service.feedback(project, 'metrics', data['payload']);
      } else if (kind == 'screenshot') {
        await service.feedback(project, 'screenshot', {
          'data': data['payload'],
          'tag': data['tag'] ?? 'shot',
        });
      } else if (kind == 'unsupported') {
        // 这台设备的 WebView 跑不了内嵌预览（模块脚本被拦 / 没有 WebGL）：
        // 这是宿主限制，不是生成失败，不计数、不推进。
        _setLoadError('这台设备不能内嵌显示 3D 预览', '${data['message'] ?? ''}');
        return;
      } else {
        return;
      }
      await _refresh();
    } on ThreeFailure catch (failure) {
      _showError(threeFailureMessage(failure), failure.detail, key: '${failure.code}|${failure.detail}');
    } catch (_) {
      // 桥是尽力而为的旁路：单条消息处理失败不打断预览。
    }
  }

  Future<void> _runPass() async {
    _beginAction();
    final service = _service;
    final project = _project;
    if (service == null || project == null) return;
    final config = _llmConfig();
    if (!config.isConfigured) {
      _toasts.warn('先在设置里配好模型连接', '3D 生成使用当前选中的模型。');
      return;
    }
    setState(() => _busy = true);
    try {
      final result = await service.runPass(project, config);
      if (!mounted) return;
      if (result.stale) {
        _toasts.warn('这一层已生成，但进度已经推进', '代码已更新；如需重做请切回该层再生成。');
      } else {
        _toasts.success('已生成「${threePassLabel(result.pass)}」层', '预览已刷新；出错会自动记修复轮。');
      }
      await _mountPreview(); // reload 即迭代（宿主页时间戳换新）
      await _refresh();
    } on ThreeFailure catch (failure) {
      _showError(threeFailureMessage(failure), failure.detail, key: '${failure.code}|${failure.detail}');
      await _refresh();
    } catch (error) {
      _showError(threeFailureMessage(null), '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _continue() async {
    _beginAction();
    final service = _service;
    final project = _project;
    if (service == null || project == null) return;
    try {
      final result = await service.continuePass(project, '客户端确认');
      if (!mounted) return;
      await _refresh();
      if (result.done) {
        _toasts.success('全部层通过 🎉', '场景完成。');
      } else {
        _toasts.info('进入「${threePassLabel(result.current)}」层', '点「生成当前层」继续。');
      }
    } on ThreeFailure catch (failure) {
      _showError(threeFailureMessage(failure), failure.detail, key: '${failure.code}|${failure.detail}');
    } catch (error) {
      _showError(threeFailureMessage(null), '$error');
    }
  }

  /// 项目新建/切换：列出本机 3D 场景（含当前标记），或新建覆盖当前会话项目。
  Future<void> _pickProject() async {
    _beginAction();
    final service = _service;
    if (service == null) return;
    List<ThreeProjectEntry> items;
    try {
      items = await service.listProjects();
    } on ThreeFailure catch (failure) {
      // 读盘失败（权限/占用）时用最近一次重扫的缓存兜底：NaN 新建/删除后
      // 列表已经刷过，不能让「项目」入口变成静默死路；没有缓存才显性报错。
      if (_projects.isEmpty) {
        _showError(threeFailureMessage(failure), failure.detail, key: '${failure.code}|${failure.detail}');
        return;
      }
      items = _projects;
    } catch (error) {
      if (_projects.isEmpty) {
        _showError('项目列表没有读出来', '$error');
        return;
      }
      items = _projects;
    }
    // 列表请求也是在飞窗口：期间视图可能已被切走，此时再 showNonDialog 就是
    // 死 context 弹窗。
    if (!mounted) return;
    _projects = items; // 缓存同步（NaN 新建/删除后弹窗里的列表就是这份磁盘态）
    final choice = await showNonDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: ctx.palette.panel,
        title: Text('3D 项目', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: ctx.palette.ink)),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, '__new__'),
            child: Row(children: [
              Icon(Icons.add, size: 16, color: ctx.palette.accent),
              const SizedBox(width: 8),
              const Text('新建项目…'),
            ]),
          ),
          for (final item in items)
            Row(children: [
              Expanded(
                child: SimpleDialogOption(
                  onPressed: () => Navigator.pop(ctx, item.name),
                  child: Row(children: [
                    Icon(
                      item.name == _project
                          ? Icons.check
                          : (item.blocked ? Icons.block : Icons.view_in_ar_outlined),
                      size: 15,
                      color: item.name == _project
                          ? ctx.palette.accent
                          : (item.blocked ? ctx.palette.warn : ctx.palette.ink3),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${item.name}（${item.current == 'corrupt' ? '进度需要修复' : threePassLabel(item.current)}）',
                        style: const TextStyle(fontSize: 13),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ]),
                ),
              ),
              IconButton(
                tooltip: '删除项目',
                icon: Icon(Icons.delete_outline, size: 16, color: ctx.palette.ink4),
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                onPressed: () => Navigator.pop(ctx, '__delete__:${item.name}'),
              ),
              const SizedBox(width: 8),
            ]),
        ],
      ),
    );
    if (choice == null) return;
    // 死 State 上 setState 会被外层 catch 吞成「切换静默失效」，先验 mounted。
    if (!mounted) return;
    if (choice == '__new__') {
      await _createProject();
      return;
    }
    if (choice.startsWith('__delete__:')) {
      await _deleteProject(choice.substring('__delete__:'.length));
      return;
    }
    if (choice == _project) return;
    _stashDraft(); // 旧项目未保存的规范编辑先存草稿
    final draft = store.threeSpecDraft(choice);
    setState(() {
      _project = choice;
      _lastError = '';
      _snapshot = null;
      _loadError = '';
      _loadDetail = '';
      // 项目边界复位规范编辑守卫：A 项目未保存的编辑不能带进 B。
      _specDirty = false;
      if (draft != null && draft.isNotEmpty) {
        _specCtl.text = draft;
        _specDirty = true;
      }
    });
    _setStoreProject(choice);
    await _mountPreview();
    await _refresh();
  }

  /// 删除 3D 场景：二次确认（不可恢复）→ 删项目目录。
  /// 删的是当前项目则整体回空态——否则工作台会停在一个盘上已不存在的项目上。
  Future<void> _deleteProject(String name) async {
    final service = _service;
    if (service == null) return;
    final ok = await showNonDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ctx.palette.panel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text('删除 3D 项目？',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: ctx.palette.ink)),
        content: Text(
          '将删除整个项目：规范、代码与全部截图证据，不可恢复。',
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
    _beginAction();
    try {
      await service.deleteProject(name);
      if (!mounted) return;
      if (_project == name) {
        _projectSeq++; // 作废在飞的旧项目读盘
        // 规范草稿随项目目录一起作废（留下就是幽灵草稿）。
        _specCtl.clear();
        _specDirty = false;
        setState(() {
          _project = null;
          _snapshot = null;
          _controller = null;
          _previewReady = false;
          _loadError = '';
          _loadDetail = '';
          _lastError = '';
          _face = 'preview';
        });
        store.setThreeSpecDraft(name, null);
        _setStoreProject('');
        _clearError();
      }
      await _reloadProjects();
      _toasts.success('已删除 3D 项目', name);
    } on ThreeFailure catch (failure) {
      _showError(threeFailureMessage(failure), failure.detail, key: '${failure.code}|${failure.detail}');
    } catch (error) {
      _showError(threeFailureMessage(null), '$error');
    }
  }

  /// 规范手编回灌（先验形状，服务再过 components/acceptance 门）。
  Future<void> _saveSpec() async {
    _beginAction();
    final service = _service;
    final project = _project;
    if (service == null || project == null) return;
    Map<String, dynamic> parsed;
    try {
      parsed = (jsonDecode(_specCtl.text) as Map).cast<String, dynamic>();
    } catch (_) {
      _toasts.error('规范格式不对', '请检查括号、引号与逗号。');
      return;
    }
    try {
      final result = await service.saveSpec(project, parsed);
      _specDirty = false; // 显式保存 = 期待磁盘态回灌，恢复同步
      store.setThreeSpecDraft(project, null); // 已落盘，草稿作废
      _toasts.success(
        '规范已保存',
        result.unblocked ? '这一层已解锁，可以重新生成。' : '后续生成会使用新规范。',
      );
      await _refresh();
    } on ThreeFailure catch (failure) {
      _showError(threeFailureMessage(failure), failure.detail, key: '${failure.code}|${failure.detail}');
    } catch (error) {
      _showError(threeFailureMessage(null), '$error');
    }
  }

  Future<void> _revealProject() async {
    final project = _project;
    final service = _service;
    if (project == null || service == null) return;
    final dir = service.projectDir(project).path;
    if (!Directory(dir).existsSync()) {
      _toasts.warn('项目目录不在本机', '可能已经被移动或删除。');
      return;
    }
    final ok = await revealThreeProject(dir, host: _host);
    if (!ok) _toasts.warn('这台设备不支持在文件夹中显示');
  }

  Future<void> _copy(String text, String done) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    _toasts.info(done);
  }

  // -- 构建 ----------------------------------------------------------------

  PopupMenuItem<String> _menuItem(BuildContext context, String value, IconData icon, String label,
      {bool enabled = true}) {
    final p = context.palette;
    final color = enabled ? p.ink3 : p.ink4;
    return PopupMenuItem<String>(
      value: value,
      height: 36,
      enabled: enabled,
      child: Row(children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 8),
        Text(label, style: TextStyle(fontSize: 13, color: enabled ? null : color)),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    if (_serviceError.isNotEmpty) {
      return _ServiceErrorPane(detail: _serviceError);
    }
    final current = _state?['current'] as String? ?? '';
    final passes = (_state?['passes'] as List?)?.cast<Map>() ?? const [];
    final size = MediaQuery.sizeOf(context);
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      final phone = width < 700;
      // 平板/窄高窗口走双行工具栏：状态一行、动作一行；横屏/桌面单行。
      final padPortrait = !phone && width < 1100 && size.height >= size.width;
      return Column(children: [
        _header(context, p, current, passes, width: width, phone: phone, padPortrait: padPortrait),
        if (_errorText.isNotEmpty) _ErrorBar(
          text: _errorText,
          detail: _errorDetail,
          palette: p,
          onDismiss: _clearError,
        ),
        Expanded(child: _body(context, p, width: width)),
      ]);
    });
  }

  Widget _header(BuildContext context, NonPalette p, String current, List<Map> passes,
      {required double width, required bool phone, required bool padPortrait}) {
    final decoration =
        BoxDecoration(color: p.bgElevated, border: Border(bottom: BorderSide(color: p.line)));
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
        tooltip: '返回主页',
        color: p.ink2,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        onPressed: () => store.setView('home'),
      );

  List<Widget> _titleBits(NonPalette p, double maxWidth) => [
        const SizedBox(width: 4),
        Icon(Icons.view_in_ar_outlined, size: 17, color: p.accent),
        const SizedBox(width: 8),
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Text(
            _project ?? '3D 工作台',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: p.ink),
          ),
        ),
      ];

  List<Widget> _busyBits(NonPalette p) => [
        SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.8, color: p.accent)),
        const SizedBox(width: 8),
      ];

  Widget _passScroll(NonPalette p, String current, List<Map> passes) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          for (final pass in passes)
            Padding(
              padding: const EdgeInsets.only(right: 5),
              child: _PassChip(
                label: threePassLabel(pass['id']),
                status: '${pass['status']}',
                active: pass['id'] == current,
                palette: p,
              ),
            ),
        ]),
      );

  /// 截图 / 四方位取证的启用判据（唯一一处）：预览页已就绪（metrics 桥到达）
  /// 且没有在飞生成、且项目在场。未就绪时 runJavaScript 是静默 no-op——
  /// 按钮亮着但点了没反应比禁用更糟（用户以为取证成功）。
  bool get _captureReady => _previewReady && !_busy && _project != null;

  List<Widget> _primaryActions(NonPalette p, {required bool includeAll}) => [
        _TopBtn(icon: Icons.folder_open_outlined, label: '项目', onTap: _busy ? null : _pickProject),
        _TopBtn(
          icon: Icons.auto_awesome_outlined,
          label: '生成当前层',
          onTap: _busy || _project == null ? null : _runPass,
        ),
        if (includeAll) ...[
          _TopBtn(
            icon: Icons.camera_alt_outlined,
            label: '截图',
            onTap: _captureReady
                ? () => _runPreviewScript(
                    'window.__non3d_screenshot && window.__non3d_screenshot()')
                : null,
          ),
          _TopBtn(
            icon: Icons.rotate_90_degrees_ccw_outlined,
            label: '四方位取证',
            onTap: _captureReady
                ? () => _runPreviewScript(
                    'window.__non3d_turntable && window.__non3d_turntable()')
                : null,
          ),
        ],
        _TopBtn(
          icon: Icons.widgets_outlined,
          label: '组件画廊',
          onTap: _openGalleryPicker,
        ),
        KeyedSubtree(
          key: const ValueKey('three-lint'),
          child: _TopBtn(
            icon: Icons.rule_outlined,
            label: _lintLabel(),
            onTap: _snapshot == null ? null : _showLint,
          ),
        ),
        _TopBtn(
          icon: Icons.check_rounded,
          label: '通过并继续',
          onTap: _busy || _project == null ? null : _continue,
        ),
        if (includeAll)
          _TopBtn(
            icon: Icons.refresh,
            label: '刷新预览',
            onTap: _busy || _project == null ? null : _mountPreview,
          ),
      ];

  List<Widget> _faceActions(NonPalette p) => [
        for (final face in const [
          ('preview', '预览', Icons.visibility_outlined),
          ('source', '源码', Icons.code_outlined),
          ('spec', '规范', Icons.rule_outlined),
        ])
          _TopBtn(
            icon: face.$3,
            label: face.$2,
            active: _face == face.$1,
            onTap: _project == null ? null : () => setState(() => _face = face.$1),
          ),
      ];

  Widget _menuButton(BuildContext context, NonPalette p, {required bool landscape}) {
    // 弹出菜单路径与 _TopBtn 路径共用同一 ready 判据（两条入口都要禁用）。
    final captureReady = _captureReady;
    return PopupMenuButton<String>(
      tooltip: '3D 操作',
      color: p.panel,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10), side: BorderSide(color: p.lineStrong)),
      onSelected: _handleAction,
      itemBuilder: (ctx) => [
        _menuItem(ctx, 'project', Icons.folder_open_outlined, '项目'),
        _menuItem(ctx, 'pass', Icons.auto_awesome_outlined, '生成当前层'),
        _menuItem(ctx, 'shot', Icons.camera_alt_outlined, '截图', enabled: captureReady),
        _menuItem(ctx, 'turntable', Icons.rotate_90_degrees_ccw_outlined, '四方位取证', enabled: captureReady),
        _menuItem(ctx, 'continue', Icons.check_rounded, '通过并继续'),
        _menuItem(ctx, 'reload', Icons.refresh, '刷新预览'),
        _menuItem(ctx, 'gallery', Icons.widgets_outlined, '组件画廊'),
        const PopupMenuDivider(),
        _menuItem(ctx, 'face:preview', Icons.visibility_outlined, landscape ? '预览（全屏）' : '预览'),
        _menuItem(ctx, 'face:source', Icons.code_outlined, landscape ? '源码（侧栏）' : '源码'),
        _menuItem(ctx, 'face:spec', Icons.rule_outlined, landscape ? '规范（侧栏）' : '规范'),
      ],
    );
  }

  void _handleAction(String value) {
    switch (value) {
      case 'project':
        _pickProject();
      case 'pass':
        _runPass();
      case 'shot':
        // 菜单项已 disabled，这里再挡一道：任何杂散调用都不得在未就绪页面上
        // 跑截图（按钮亮但无操作 = 静默失败）。
        if (!_captureReady) return;
        _runPreviewScript('window.__non3d_screenshot && window.__non3d_screenshot()');
      case 'turntable':
        if (!_captureReady) return;
        _runPreviewScript('window.__non3d_turntable && window.__non3d_turntable()');
      case 'continue':
        _continue();
      case 'reload':
        if (_project != null) _mountPreview();
      case 'gallery':
        _openGalleryPicker();
      case 'face:preview':
      case 'face:source':
      case 'face:spec':
        if (_project != null) setState(() => _face = value.substring('face:'.length));
    }
  }

  Widget _body(BuildContext context, NonPalette p, {required double width}) {
    if (_project == null) {
      return _EmptyNew(
        onCreate: _createProject,
        onCreateKit: _createFromKit,
        busy: _busy,
        catalog: _uiCatalog,
        catalogError: _uiCatalogError,
        onReloadCatalog: _loadUiCatalog,
        onOpenUi: _webViewSupported ? _openThreeUi : null,
      );
    }
    // 无内嵌执行面 / 未验证的移动端最先分流：不构造控制器，给可复制的路径与
    // 能力说明（不把「加载预览…」当作终态）。
    final Widget preview;
    if (!_scenePreviewSupported) {
      preview = _PreviewUnsupportedPane(
        projectDir: _service?.projectDir(_project!).path ?? '',
        previewPath: _service?.previewHtmlPath(_project!) ?? '',
        host: _host,
        preferred: '这台设备不能内嵌显示 3D 预览，可以在电脑上打开同一个项目查看。',
        onCopy: _copy,
        onReveal: _host.supportsRevealInFolder ? _revealProject : null,
      );
    } else if (_loadError.isNotEmpty) {
      preview = _PreviewErrorPane(
        message: _loadError,
        detail: _loadDetail,
        onRetry: _retryPreview,
      );
    } else if (_controller == null) {
      preview = Center(child: Text('准备预览…', style: TextStyle(fontSize: 12, color: p.ink3)));
    } else {
      preview = WebViewWidget(controller: _controller!);
    }
    final side = switch (_face) {
      'source' => SingleChildScrollView(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 场景代码长度随 run 转发刷新可见（NaN 每完成一层都会改写
              // 这份代码，用户能直接看到「有没有新东西进来」）。
              if (_sceneJs.isNotEmpty)
                Padding(
                  key: const ValueKey('three-scene-meta'),
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    '场景代码 · ${_sceneJs.length} 字符',
                    style: TextStyle(fontSize: 11, color: p.ink3),
                  ),
                ),
              SelectableText(
                _sceneJs.isEmpty ? '还没有场景代码——点「生成当前层」开始' : _sceneJs,
                style: TextStyle(fontSize: 12, fontFamily: 'monospace', color: p.ink2, height: 1.5),
              ),
            ],
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

/// 错误横幅：一句人话 + 折叠的技术详情（默认不展开）+ 关闭。
class _ErrorBar extends StatelessWidget {
  const _ErrorBar({
    required this.text,
    required this.detail,
    required this.palette,
    required this.onDismiss,
  });

  final String text;
  final String detail;
  final NonPalette palette;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final p = palette;
    return Container(
      key: const ValueKey('three-refresh-error'),
      width: double.infinity,
      color: p.danger.withValues(alpha: 0.10),
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.error_outline, size: 14, color: p.danger),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: p.danger),
            ),
          ),
          IconButton(
            tooltip: '关闭提示',
            icon: Icon(Icons.close, size: 14, color: p.danger),
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            onPressed: onDismiss,
          ),
        ]),
        if (detail.trim().isNotEmpty)
          _TechDetails(
            detail: detail,
            palette: p,
            dense: true,
            bodyKey: const ValueKey('three-tech-details-body'),
          ),
      ]),
    );
  }
}

/// 折叠的「技术详情」：原始诊断默认不可见（用户只看人话）。
class _TechDetails extends StatelessWidget {
  const _TechDetails({
    required this.detail,
    required this.palette,
    this.dense = false,
    this.bodyKey,
  });

  final String detail;
  final NonPalette palette;
  final bool dense;
  final Key? bodyKey;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: dense ? const EdgeInsets.symmetric(horizontal: 2) : EdgeInsets.zero,
          childrenPadding: EdgeInsets.only(bottom: dense ? 6 : 4),
          dense: true,
          visualDensity: VisualDensity.compact,
          title: Text(
            '技术详情',
            style: TextStyle(
              fontSize: 11,
              color: palette.ink3,
              fontWeight: FontWeight.w600,
            ),
          ),
          children: [
            SelectableText(
              detail,
              key: bodyKey,
              style: TextStyle(
                fontSize: 10.5,
                fontFamily: 'monospace',
                color: palette.ink3,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyNew extends StatelessWidget {
  const _EmptyNew({
    required this.onCreate,
    this.onCreateKit,
    required this.busy,
    this.catalog,
    this.catalogError = '',
    this.onReloadCatalog,
    this.onOpenUi,
  });
  final VoidCallback onCreate;
  final void Function(ThreeKit kit)? onCreateKit;
  final bool busy;

  /// vendored ThreeUI 组件清单（null = 还在读）。
  final List<ThreeUiComponent>? catalog;
  final String catalogError;
  final Future<void> Function()? onReloadCatalog;

  /// 打开组件首页（WebView 不可用的平台为 null）。
  final void Function(ThreeUiComponent component)? onOpenUi;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Center(
      // 手机横屏（844×390——2026-11-19 起真机到不了，仅方向门兜底/web 矮窗
      // 可达）放不下「说明 + 新建 + 六个套件」：空态整体可滚，
      // 不靠裁掉套件来适配小屏。
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 20),
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
              '一句话目标 → 先出项目规范（组件 / 材质 / 相机 / 验收标准）→ 分层生成\n'
              '占位 → 结构 → 造型 → 材质 → 灯光 → 交互，应用内实时预览，\n'
              '执行错误 / 测量 / 截图三类反馈自动驱动修复轮。',
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
        if (onCreateKit != null) ...[
          const SizedBox(height: 26),
          Text('或从一个场景套件开始',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: p.ink3)),
          const SizedBox(height: 4),
          Text('套件已经想好构图与材质方向，可直接进入分层细化',
              style: TextStyle(fontSize: 11, color: p.ink4)),
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: Wrap(
              alignment: WrapAlignment.center,
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final kit in threeKits)
                  InkWell(
                    key: ValueKey('three-kit-${kit.id}'),
                    borderRadius: BorderRadius.circular(12),
                    onTap: busy ? null : () => onCreateKit!(kit),
                    child: Container(
                      width: 186,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: p.panel.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: p.line),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            Icon(Icons.view_in_ar_outlined, size: 14, color: p.accent),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(kit.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 12, fontWeight: FontWeight.w600, color: p.ink)),
                            ),
                          ]),
                          const SizedBox(height: 6),
                          Text(kit.hint,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 10.5, height: 1.45, color: p.ink4)),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 4,
                            children: [
                              for (final tag in kit.tags.take(2))
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                  decoration: BoxDecoration(
                                    color: p.accent.withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(tag, style: TextStyle(fontSize: 9, color: p.accent)),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 30),
        _ThreeUiGallery(
          catalog: catalog,
          error: catalogError,
          onReload: onReloadCatalog,
          onOpen: onOpenUi,
          padHorizontal: 24,
          maxWidth: 620,
        ),
        ]),
      ),
    );
  }
}

/// ThreeUI 组件画廊（空态区块 + 已开项目时的弹出面板共用）。
///
/// 卡片只给名称 / 一句说明 / 缩略提示——不截假图、不外链。点开由调用方在
/// 应用内 WebView 里真实渲染 vendored 页面（[_ThreeUiViewerDialog]）。
class _ThreeUiGallery extends StatelessWidget {
  const _ThreeUiGallery({
    required this.catalog,
    this.error = '',
    this.onReload,
    this.onOpen,
    this.padHorizontal = 0,
    this.maxWidth = 620,
  });

  final List<ThreeUiComponent>? catalog;
  final String error;
  final Future<void> Function()? onReload;
  final void Function(ThreeUiComponent component)? onOpen;
  final double padHorizontal;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final items = catalog;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: padHorizontal),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Column(
          key: const ValueKey('threeui-gallery'),
          children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.widgets_outlined, size: 14, color: p.accent),
              const SizedBox(width: 6),
              Text('ThreeUI 组件',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: p.ink3)),
            ]),
            const SizedBox(height: 4),
            Text('组件库里选一个真实页面，在应用内打开看效果',
                style: TextStyle(fontSize: 11, color: p.ink4)),
            const SizedBox(height: 12),
            if (items == null)
              if (error.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 1.8, color: p.accent),
                  ),
                )
              else
                _ThreeUiCatalogError(message: error, onReload: onReload)
            else if (items.isEmpty)
              _ThreeUiCatalogError(message: '组件清单是空的', onReload: onReload)
            else
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final component in items)
                    InkWell(
                      key: ValueKey('threeui-${component.id}'),
                      borderRadius: BorderRadius.circular(12),
                      onTap: onOpen == null || items.isEmpty
                          ? null
                          : () => onOpen!(component),
                      child: Container(
                        width: 186,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: p.panel.withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: p.line),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(children: [
                              Icon(Icons.auto_awesome_mosaic_outlined, size: 14, color: p.accent),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(component.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: p.ink)),
                              ),
                            ]),
                            const SizedBox(height: 6),
                            Text(component.description,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 10.5, height: 1.45, color: p.ink3)),
                            const SizedBox(height: 6),
                            Text(component.hint,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 9.5, color: p.ink4)),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// 组件清单读不出来：一句人话 + 重试，不空屏。
class _ThreeUiCatalogError extends StatelessWidget {
  const _ThreeUiCatalogError({required this.message, this.onReload});

  final String message;
  final Future<void> Function()? onReload;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: p.panel2.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: p.line),
      ),
      child: Row(children: [
        Icon(Icons.info_outline, size: 14, color: p.warn),
        const SizedBox(width: 8),
        Expanded(
          child: Text(message, style: TextStyle(fontSize: 11, color: p.ink3)),
        ),
        if (onReload != null)
          TextButton(
            key: const ValueKey('threeui-catalog-retry'),
            onPressed: () => onReload!(),
            child: const Text('重试'),
          ),
      ]),
    );
  }
}

/// 组件预览弹窗：应用内 WebView 按资源键加载自包含 HTML，失败有人话 + 重试。
///
/// 为什么不发外链、不截图：用户要看的是「组件真的在这个应用里跑起来」。
/// 页面本身自包含（零网络请求），`loadFlutterAsset` 直接读应用包内文件。
class _ThreeUiViewerDialog extends StatefulWidget {
  const _ThreeUiViewerDialog({
    required this.component,
    required this.webViewSupported,
  });

  final ThreeUiComponent component;
  final bool webViewSupported;

  @override
  State<_ThreeUiViewerDialog> createState() => _ThreeUiViewerDialogState();
}

class _ThreeUiViewerDialogState extends State<_ThreeUiViewerDialog> {
  WebViewController? _controller;
  String _error = '';
  String _detail = '';

  @override
  void initState() {
    super.initState();
    if (widget.webViewSupported) unawaited(_load());
  }

  Future<void> _load() async {
    if (!widget.webViewSupported) return;
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onWebResourceError: _onResourceError,
      ));
    try {
      await controller.loadFlutterAsset(widget.component.assetKey);
    } catch (error) {
      if (!mounted) return;
      _setError('组件没能打开，请重试', '$error');
      return;
    }
    if (!mounted) return;
    setState(() {
      _controller = controller;
      _error = '';
      _detail = '';
    });
  }

  void _onResourceError(WebResourceError error) {
    // 子资源失败不整块替换：只有主帧失败才是「组件打不开」。
    if (error.isForMainFrame == false) return;
    _setError('组件没能打开，请重试', '${error.description} (${error.errorCode})');
  }

  void _setError(String message, [String detail = '']) {
    if (!mounted) return;
    setState(() {
      _error = message;
      _detail = detail;
      _controller = null;
    });
  }

  Future<void> _retry() async {
    if (!mounted) return;
    setState(() {
      _error = '';
      _detail = '';
    });
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final component = widget.component;
    return Dialog(
      key: const ValueKey('threeui-viewer'),
      backgroundColor: p.panel,
      insetPadding: const EdgeInsets.all(18),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1040, maxHeight: 760),
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 10),
            child: Row(children: [
              Icon(Icons.auto_awesome_mosaic_outlined, size: 16, color: p.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(component.name,
                        style: TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w700, color: p.ink)),
                    const SizedBox(height: 2),
                    Text(component.description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: p.ink3)),
                  ],
                ),
              ),
              IconButton(
                tooltip: '重试',
                icon: const Icon(Icons.refresh, size: 17),
                color: p.ink3,
                onPressed: _retry,
              ),
              IconButton(
                tooltip: '关闭',
                icon: const Icon(Icons.close, size: 17),
                color: p.ink3,
                onPressed: () => Navigator.pop(context),
              ),
            ]),
          ),
          Container(height: 1, color: p.line),
          Expanded(
            child: Container(
              color: p.bg,
              child: !widget.webViewSupported
                  ? Center(
                      child: Text('这台设备不能内嵌显示组件预览',
                          style: TextStyle(fontSize: 12, color: p.ink3)),
                    )
                  : _error.isNotEmpty
                      ? _ThreeUiViewError(
                          message: _error,
                          detail: _detail,
                          onRetry: _retry,
                        )
                      : _controller == null
                          ? Center(
                              child: SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: p.accent),
                              ),
                            )
                          : WebViewWidget(controller: _controller!),
            ),
          ),
        ]),
      ),
    );
  }
}

/// 组件渲染失败占位：一句人话 + 折叠的技术详情 + 重试。
class _ThreeUiViewError extends StatelessWidget {
  const _ThreeUiViewError({
    required this.message,
    required this.detail,
    required this.onRetry,
  });

  final String message;
  final String detail;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.broken_image_outlined, size: 30, color: p.warn),
          const SizedBox(height: 10),
          Text(message,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: p.ink)),
          const SizedBox(height: 4),
          Text('可以重试；如果一直打不开，换一个组件看看。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: p.ink3)),
          if (detail.isNotEmpty)
            _TechDetails(detail: detail, palette: p),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: () => onRetry(),
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('重试'),
          ),
        ]),
      ),
    );
  }
}

/// 没有内嵌预览时的降级面：路径可复制、桌面可定位，绝不给假预览。
class _PreviewUnsupportedPane extends StatelessWidget {
  const _PreviewUnsupportedPane({
    required this.projectDir,
    required this.previewPath,
    required this.host,
    required this.preferred,
    required this.onCopy,
    required this.onReveal,
  });

  final String projectDir;
  final String previewPath;
  final PlatformCapabilities host;
  final String preferred;
  final Future<void> Function(String text, String done) onCopy;
  final Future<void> Function()? onReveal;

  /// 设备本身没有内嵌预览时的固定标题。
  String get title => '这台设备不能内嵌显示 3D 预览';

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      key: const ValueKey('three-preview-unsupported'),
      color: p.panel2,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(24),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.view_in_ar_outlined, size: 36, color: p.ink4),
          const SizedBox(height: 10),
          Text(title,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: p.ink2)),
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Text(
              '$preferred\n项目与预览文件都在本机，复制路径就能在文件管理器里找到；'
              '桌面版还能直接在文件夹中定位。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: p.ink4, height: 1.6),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
            OutlinedButton.icon(
              key: const ValueKey('three-preview-copy-path'),
              onPressed: projectDir.isEmpty ? null : () => onCopy(projectDir, '已复制项目路径'),
              icon: const Icon(Icons.copy, size: 14),
              label: const Text('复制项目路径'),
            ),
            OutlinedButton.icon(
              key: const ValueKey('three-preview-copy-url'),
              onPressed: previewPath.isEmpty ? null : () => onCopy(previewPath, '已复制预览文件路径'),
              icon: const Icon(Icons.link, size: 14),
              label: const Text('复制预览文件路径'),
            ),
            if (onReveal != null)
              OutlinedButton.icon(
                key: const ValueKey('three-preview-reveal'),
                onPressed: () => onReveal!(),
                icon: const Icon(Icons.folder_open_outlined, size: 14),
                label: const Text('在文件夹中显示'),
              ),
          ]),
          if (projectDir.isNotEmpty) ...[
            const SizedBox(height: 10),
            SelectableText('项目目录：$projectDir',
                key: const ValueKey('three-preview-path'),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: p.ink3, height: 1.5)),
          ],
        ]),
      ),
    );
  }
}

/// 预览加载失败占位：整块替换 WebView 区域，重试按钮重新准备并加载。
class _PreviewErrorPane extends StatelessWidget {
  const _PreviewErrorPane({required this.message, required this.detail, required this.onRetry});
  final String message;
  final String detail;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.error_outline, size: 36, color: p.danger),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Text(message,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: p.ink3, height: 1.6)),
          ),
        ),
        if (detail.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 6, 24, 0),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: _TechDetails(
                detail: detail,
                palette: p,
                bodyKey: const ValueKey('three-preview-tech-details-body'),
              ),
            ),
          ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () => onRetry(),
          icon: const Icon(Icons.refresh, size: 14),
          label: const Text('重试加载'),
        ),
      ]),
    );
  }
}

/// 本地存储目录都解析不出来时的整块退化面（不静默空着）。
class _ServiceErrorPane extends StatelessWidget {
  const _ServiceErrorPane({required this.detail});
  final String detail;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      key: const ValueKey('three-service-unavailable'),
      color: p.bg,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(24),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.folder_off_outlined, size: 36, color: p.warn),
        const SizedBox(height: 10),
        Text('3D 项目的存储目录打不开',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: p.ink2)),
        const SizedBox(height: 6),
        Text('检查一下应用的数据目录权限，然后重新进入这个工作台。',
            textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: p.ink4, height: 1.6)),
        const SizedBox(height: 10),
        _TechDetails(
          detail: detail,
          palette: p,
          bodyKey: const ValueKey('three-service-tech-details-body'),
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
    final (color, background) = switch (status) {
      'verified' => (palette.success, palette.success.withValues(alpha: 0.15)),
      'failed' || 'blocked' => (palette.warn, palette.warn.withValues(alpha: 0.15)),
      'generated' => (palette.accent, palette.accentSoft),
      _ => (palette.ink4, palette.panel2),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: active ? background : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: active ? color : palette.line),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: active ? FontWeight.w700 : FontWeight.w500,
          color: active ? color : palette.ink4,
        ),
      ),
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

/// 规范手编面板：编辑场景规范 → 回灌（先改规范再要代码）。
class _SpecPane extends StatelessWidget {
  const _SpecPane({required this.controller, required this.onSave});
  final TextEditingController controller;
  final Future<void> Function() onSave;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
        child: Row(children: [
          Text('项目规范',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: p.ink2)),
          const Spacer(),
          OutlinedButton.icon(
            onPressed: () => onSave(),
            icon: const Icon(Icons.save_outlined, size: 14),
            label: const Text('保存规范', style: TextStyle(fontSize: 12)),
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
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: p.line)),
            ),
          ),
        ),
      ),
    ]);
  }
}
