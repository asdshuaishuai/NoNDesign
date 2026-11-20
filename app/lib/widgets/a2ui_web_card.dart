// 官方 A2UI Web 渲染器的 WebView 承载（spike；决策记录见
// docs/plan-a2ui-web-spike.md）。
//
// ⚠ 当前无生产接线：仅 test/a2ui_web_spike_test.dart 引用本卡片，产品主路径
// 仍是原生 a2ui_card。保留作 .nonapp 跨端备选，启用前需补生产接入点。
//
// 页面来自 third_party/a2ui_web 的打包产物（app/assets/a2ui_web/index.html）：
// 官方 @a2ui/web_core + @a2ui/lit 把 A2UI v1.0 surface 画成自包含 HTML，
// CSP 只经 <meta> 注入、connect-src 'none'、零 CDN。本文件是 Dart 侧唯一
// 接入边界——WebView 生命周期、桥消息解码、消息下发都在这里。产品默认仍是
// 原生 a2ui_flutter（widgets/a2ui_card.dart），本卡片只作 .nonapp 跨端备选
// 的 spike，不与原生渲染器互相替换。
//
// 可测性：页面控制器抽象成 [A2uiWebPage]（装载 HTML / 执行脚本 / 消息回调 /
// 构建视图 / 释放）。flutter test 没有插件宿主，测试注入假实现即可验证
// 「装载的是打包页面」「ready 后下发消息」「动作经桥回流」；真实实现
// [WebViewA2uiPage] 只做参数搬运与导航白名单。
//
// 安全边界（与 .nonapp 的 file:// 预览同一纪律）：
// - 页面是 loadHtmlString 注入的 about:blank 文档，导航只放行
//   about/data/blob，外部 URL 一律 prevent；
// - 页面自身 CSP 封死连接（connect-src 'none'），构建期还有零外链扫描；
// - 宿主下发的 surface 消息是不可信输入：一律 jsonEncode 后作为 JS 表达式
//   传给页面，绝不拼进 HTML；页面里由官方渲染器按 zod schema 校验。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:webview_all/webview_all.dart';

import '../core/theme.dart';

/// 页面与 Dart 之间的 JS 通道名（页面里是 `window.A2uiBridge`）。
const String kA2uiWebBridgeChannel = 'A2uiBridge';

/// 打包产物在 Flutter asset 里的键。
const String kA2uiWebAssetKey = 'assets/a2ui_web/index.html';

/// 桥消息上限：通道消息无界，页面一条超大消息不该把宿主拖进无界内存。
const int kA2uiWebMaxMessageBytes = 1024 * 1024;

/// 打包页面不可用（asset 未声明、文件缺失或为空）。
///
/// 这是**能力缺失**而不是渲染失败：上层应显式提示，不得静默降级成空白卡。
class A2uiWebBundleException implements Exception {
  const A2uiWebBundleException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => 'A2uiWebBundleException: $message';
}

/// 桥消息解码失败（非 JSON / 结构不合法）。
class A2uiWebProtocolException implements Exception {
  const A2uiWebProtocolException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => 'A2uiWebProtocolException: $message';
}

/// 打包页面的装载器。
///
/// 正常路径是 `rootBundle`（要求 `pubspec.yaml` 的 `flutter.assets` 声明
/// `assets/a2ui_web/`）；未声明时回退到仓库内文件路径，只覆盖 debug/test
/// ——发布包必须靠 asset 声明，否则显式抛 [A2uiWebBundleException]。
class A2uiWebBundle {
  A2uiWebBundle._();

  static String? _cache;

  @visibleForTesting
  static List<String> fileCandidates = const [
    'assets/a2ui_web/index.html',
    'app/assets/a2ui_web/index.html',
  ];

  @visibleForTesting
  static void resetCache() {
    _cache = null;
  }

  /// 读取自包含页面（带进程内缓存：页面 ~0.5MB，不随卡片数量重复读盘）。
  static Future<String> loadHtml() async {
    final cached = _cache;
    if (cached != null) return cached;
    Object? bundleError;
    try {
      final html = await rootBundle.loadString(kA2uiWebAssetKey, cache: false);
      if (html.trim().isEmpty) {
        throw const A2uiWebBundleException('页面内容为空');
      }
      return _cache = html;
    } on Object catch (error) {
      // asset 未声明（FlutterError）或读取失败：落到文件回退，最终仍失败
      // 时把首个错误带出去，便于日志定位。
      bundleError = error;
    }
    for (final candidate in fileCandidates) {
      try {
        final file = File(candidate);
        if (!file.existsSync()) continue;
        final html = await file.readAsString();
        if (html.trim().isEmpty) continue;
        return _cache = html;
      } on Object {
        // 尝试下一个候选路径
      }
    }
    throw A2uiWebBundleException(
      '离线预览页面不可用：未在 asset 清单中找到 $kA2uiWebAssetKey',
      bundleError,
    );
  }
}

/// 页面 controller 的最小抽象（生产实现见 [WebViewA2uiPage]）。
abstract class A2uiWebPage {
  /// 注入自包含页面（about:blank 文档，不允许外部导航）。
  Future<void> loadHtml(String html, {String? baseUrl});

  /// 在页面里执行一段脚本。
  Future<void> runJavaScript(String script);

  /// 注册桥消息回调（页面经 `A2uiBridge.postMessage` 发 JSON 字符串）。
  void setMessageHandler(void Function(String message) handler);

  /// 页面视图（放进卡片里）。
  Widget buildView();

  /// 释放页面资源。
  Future<void> dispose();
}

/// 注入页的导航白名单：只放行 about/data/blob 与空 scheme 的文档内导航。
///
/// 页面是 `loadHtmlString` 注入的 about:blank 文档；不受信载荷不能把 WebView
/// 导航到外部站点（与 .nonapp file:// 预览同一条纪律）。
bool a2uiWebNavigationAllowed(String url) {
  final scheme = Uri.tryParse(url)?.scheme.toLowerCase() ?? '';
  return scheme.isEmpty ||
      scheme == 'about' ||
      scheme == 'data' ||
      scheme == 'blob';
}

/// 生产实现：webview_all 的 WebViewController。
class WebViewA2uiPage implements A2uiWebPage {
  WebViewA2uiPage() {
    _controller
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..addJavaScriptChannel(
        kA2uiWebBridgeChannel,
        onMessageReceived: (message) => _handler?.call(message.message),
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) => a2uiWebNavigationAllowed(request.url)
              ? NavigationDecision.navigate
              : NavigationDecision.prevent,
          onWebResourceError: (error) {
            // 页面是自包含的：资源错误基本只来自注入失败，交宿主显式报错。
            debugPrint(
              '[a2ui-web] resource error: ${error.errorCode} '
              '${error.description}',
            );
          },
        ),
      );
  }

  final WebViewController _controller = WebViewController();
  void Function(String message)? _handler;

  @override
  void setMessageHandler(void Function(String message) handler) {
    _handler = handler;
  }

  @override
  Future<void> loadHtml(String html, {String? baseUrl}) =>
      _controller.loadHtmlString(html, baseUrl: baseUrl);

  @override
  Future<void> runJavaScript(String script) =>
      _controller.runJavaScript(script);

  @override
  Widget buildView() => WebViewWidget(controller: _controller);

  @override
  Future<void> dispose() async {
    _handler = null;
    try {
      await _controller.removeJavaScriptChannel(kA2uiWebBridgeChannel);
    } on Object {
      // controller 可能随视图一起被系统回收；释放失败不影响宿主。
    }
  }
}

/// 页面 → Dart 的桥事件。
sealed class A2uiWebEvent {
  const A2uiWebEvent();
}

/// 页面就绪：可以下发消息了。
class A2uiWebReady extends A2uiWebEvent {
  const A2uiWebReady({
    required this.protocol,
    required this.bridgeVersion,
    this.versions = const {},
  });

  final String protocol;
  final int bridgeVersion;
  final Map<String, Object?> versions;
}

/// 某个 surface 完成一次绘制（供宿主判断“画出来了”）。
class A2uiWebRendered extends A2uiWebEvent {
  const A2uiWebRendered({
    required this.surfaceId,
    required this.textLength,
    required this.text,
  });

  final String surfaceId;
  final int textLength;
  final String text;
}

/// surface 上的用户动作（context 已由官方渲染器从数据模型解析）。
class A2uiWebAction extends A2uiWebEvent {
  const A2uiWebAction({
    required this.name,
    required this.surfaceId,
    required this.sourceComponentId,
    required this.context,
    this.timestamp,
    this.catalogId,
    this.userMessage,
  });

  final String name;
  final String surfaceId;
  final String sourceComponentId;
  final Map<String, Object?> context;
  final String? timestamp;
  final String? catalogId;
  final String? userMessage;

  Map<String, Object?> toJson() => {
        'name': name,
        'surfaceId': surfaceId,
        'sourceComponentId': sourceComponentId,
        'context': context,
        if (timestamp != null) 'timestamp': timestamp,
        if (catalogId != null) 'catalogId': catalogId,
        if (userMessage != null) 'userMessage': userMessage,
      };
}

/// 页面/消息处理报错（code 只进日志，不直接给用户看）。
class A2uiWebPageError extends A2uiWebEvent {
  const A2uiWebPageError({required this.code, required this.message});

  final String code;
  final String message;
}

/// surface 被删除。
class A2uiWebSurfaceRemoved extends A2uiWebEvent {
  const A2uiWebSurfaceRemoved(this.surfaceId);

  final String surfaceId;
}

/// 页面已重置（surface 全部清空）。
class A2uiWebReset extends A2uiWebEvent {
  const A2uiWebReset();
}

/// 解码页面桥消息。
///
/// 未知类型返回 null（向前兼容：页面升级新增事件不会让旧宿主报错）；
/// 结构不合法抛 [A2uiWebProtocolException]。
A2uiWebEvent? decodeA2uiWebEvent(String raw) {
  if (raw.isEmpty) {
    throw const A2uiWebProtocolException('空消息');
  }
  if (raw.length > kA2uiWebMaxMessageBytes) {
    throw const A2uiWebProtocolException('消息超过大小上限');
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on Object catch (error) {
    throw A2uiWebProtocolException('消息不是合法 JSON', error);
  }
  if (decoded is! Map) {
    throw const A2uiWebProtocolException('消息不是对象');
  }
  final type = decoded['type'];
  switch (type) {
    case 'ready':
      final protocol = decoded['protocol'];
      final bridge = decoded['bridgeVersion'];
      return A2uiWebReady(
        protocol: protocol is String ? protocol : '',
        bridgeVersion: bridge is int ? bridge : 0,
        versions: _stringMap(decoded['versions']),
      );
    case 'rendered':
      return A2uiWebRendered(
        surfaceId: _string(decoded['surfaceId']),
        textLength: decoded['textLength'] is int
            ? decoded['textLength'] as int
            : 0,
        text: _string(decoded['text']),
      );
    case 'action':
      final name = decoded['name'];
      if (name is! String || name.isEmpty) {
        throw const A2uiWebProtocolException('动作缺少 name');
      }
      return A2uiWebAction(
        name: name,
        surfaceId: _string(decoded['surfaceId']),
        sourceComponentId: _string(decoded['sourceComponentId']),
        context: _stringMap(decoded['context']),
        timestamp: decoded['timestamp'] is String
            ? decoded['timestamp'] as String
            : null,
        catalogId:
            decoded['catalogId'] is String ? decoded['catalogId'] as String : null,
        userMessage: decoded['userMessage'] is String
            ? decoded['userMessage'] as String
            : null,
      );
    case 'error':
      return A2uiWebPageError(
        code: _string(decoded['code']),
        message: _string(decoded['message']),
      );
    case 'surface_removed':
      return A2uiWebSurfaceRemoved(_string(decoded['surfaceId']));
    case 'reset':
      return const A2uiWebReset();
    case 'render_accepted':
      // 宿主动作的回执：不单独建模，渲染完成由 rendered 事件表达。
      return null;
    default:
      return null;
  }
}

String _string(Object? value) => value is String ? value : '';

Map<String, Object?> _stringMap(Object? value) {
  if (value is! Map) return const {};
  return value.map((key, item) => MapEntry(key.toString(), item));
}

/// 官方 Web 渲染器的卡片式宿主（spike）。
///
/// [messages] 为 null 时页面渲染内置 fixture（装载成功即可自证）；非空时
/// 在页面就绪后先 reset 再整批下发（`.nonapp` 的 surface.json 打开路径）。
class A2uiWebCard extends StatefulWidget {
  const A2uiWebCard({
    super.key,
    this.messages,
    this.pageFactory,
    this.htmlLoader,
    this.onAction,
    this.onReady,
    this.onRendered,
    this.onError,
    this.bootTimeout = const Duration(seconds: 10),
    this.height = 360,
  });

  /// A2UI 消息序列（v1.0 信封数组）；null = 用页面内置 fixture。
  final List<Object?>? messages;

  /// 页面控制器工厂（测试注入假实现）。
  final A2uiWebPage Function()? pageFactory;

  /// 页面装载器（测试可替换）。
  final Future<String> Function()? htmlLoader;

  /// 用户动作回流。
  final void Function(A2uiWebAction action)? onAction;

  /// 页面就绪（可下发消息）。
  final void Function(A2uiWebReady ready)? onReady;

  /// 某次绘制完成。
  final void Function(A2uiWebRendered rendered)? onRendered;

  /// 错误（原始对象，只进日志/测试；界面文案是独立的人话）。
  final void Function(Object error)? onError;

  /// 页面迟迟不就绪时显式报错的时间上限。
  final Duration bootTimeout;

  /// 卡片高度（页面在内部滚动）。
  final double height;

  @override
  State<A2uiWebCard> createState() => _A2uiWebCardState();
}

class _A2uiWebCardState extends State<A2uiWebCard> {
  A2uiWebPage? _page;
  Timer? _bootTimer;
  bool _ready = false;
  bool _disposed = false;
  bool _dark = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 页面默认深色；跟随宿主明暗（页面侧 setTheme 只切根类，不重渲染）。
    final dark = Theme.of(context).brightness == Brightness.dark;
    if (dark == _dark) return;
    _dark = dark;
    if (_ready) _applyTheme();
  }

  @override
  void didUpdateWidget(covariant A2uiWebCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = widget.messages;
    if (next != null && !identical(next, oldWidget.messages) && _ready) {
      _push(next);
    }
  }

  Future<void> _boot() async {
    final page = widget.pageFactory?.call() ?? WebViewA2uiPage();
    _page = page;
    page.setMessageHandler(_onMessage);
    _bootTimer = Timer(widget.bootTimeout, () {
      if (!mounted || _ready) return;
      _fail(
        '离线预览没有启动，请重试',
        const A2uiWebProtocolException('页面在时限内未就绪'),
      );
    });
    try {
      final html = await (widget.htmlLoader ?? A2uiWebBundle.loadHtml)();
      if (_disposed) return;
      await page.loadHtml(html);
    } on Object catch (error) {
      _fail('离线预览还没有准备好，请稍后重试', error);
    }
  }

  void _onMessage(String raw) {
    final A2uiWebEvent? event;
    try {
      event = decodeA2uiWebEvent(raw);
    } on Object catch (error) {
      widget.onError?.call(error);
      return;
    }
    switch (event) {
      case A2uiWebReady ready:
        _bootTimer?.cancel();
        if (mounted) {
          setState(() {
            _ready = true;
            _error = null;
          });
        } else {
          _ready = true;
        }
        if (ready.protocol.isNotEmpty && ready.protocol != '1.0') {
          debugPrint('[a2ui-web] unexpected protocol: ${ready.protocol}');
        }
        if (ready.bridgeVersion != 1) {
          debugPrint('[a2ui-web] unexpected bridge version: ${ready.bridgeVersion}');
        }
        widget.onReady?.call(ready);
        _applyTheme();
        final messages = widget.messages;
        if (messages != null) _push(messages);
      case A2uiWebAction action:
        widget.onAction?.call(action);
      case A2uiWebRendered rendered:
        widget.onRendered?.call(rendered);
      case A2uiWebPageError error:
        debugPrint('[a2ui-web] page error: ${error.message}');
        if (mounted && _error == null) {
          setState(() => _error = '预览运行出错了');
        }
        widget.onError?.call(error);
      case A2uiWebSurfaceRemoved() || A2uiWebReset() || null:
        break;
    }
  }

  Future<void> _applyTheme() async {
    final page = _page;
    if (page == null) return;
    try {
      await page.runJavaScript(
        "window.A2uiWeb && window.A2uiWeb.setTheme('${_dark ? 'dark' : 'light'}');",
      );
    } on Object {
      // 主题是锦上添花；页面没就绪/已释放都不该升级成错误态。
    }
  }

  Future<void> _push(List<Object?> messages) async {
    final page = _page;
    if (page == null) return;
    // JSON 直接作为 JS 表达式参数（不是拼进 HTML）；U+2028/U+2029 在旧引擎
    // 的字符串字面量里会被当换行，统一转义掉。
    final payload = jsonEncode(messages)
        .replaceAll('\u2028', r'\u2028')
        .replaceAll('\u2029', r'\u2029');
    try {
      await page.runJavaScript(
        'window.A2uiWeb && window.A2uiWeb.render($payload, {reset:true});',
      );
    } on Object catch (error) {
      _fail('预览没有更新成功，请重试', error);
    }
  }

  void _fail(String message, Object error) {
    debugPrint('[a2ui-web] $message ($error)');
    widget.onError?.call(error);
    if (!mounted) return;
    setState(() => _error = message);
  }

  @override
  void dispose() {
    _disposed = true;
    _bootTimer?.cancel();
    final page = _page;
    _page = null;
    if (page != null) {
      unawaited(page.dispose());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final page = _page;
    return Container(
      height: widget.height,
      decoration: BoxDecoration(
        color: palette.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          if (page != null)
            Positioned.fill(child: page.buildView()),
          if (!_ready && _error == null)
            Positioned.fill(
              child: ColoredBox(
                color: palette.panel,
                child: Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: palette.accent,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '预览准备中…',
                        style: TextStyle(fontSize: 11, color: palette.ink3),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (_error != null)
            Positioned.fill(
              child: ColoredBox(
                color: palette.panel,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, color: palette.ink2),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
