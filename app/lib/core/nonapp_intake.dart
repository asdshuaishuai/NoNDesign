// OS 文件关联的 Dart 侧入口：`nc/open` 通道 + 冷启动队列。
//
// 双向契约（三平台同一套，避免冷启动丢文件）：
//   native → Dart  `openPath`   {path: String}   热启动：系统把文件交给运行中的实例
//   Dart → native  `takePending` → List<String>  冷启动：Dart 就绪后拉取并清空队列
//
// 为什么需要 takePending：App 尚未启动完成时系统交付的打开事件（macOS 的
// openFiles/双击、iOS 的 launchOptions.url、Android 的冷启动 intent）没有
// Dart handler 可投递，native 侧只能先入队；Dart 就绪后必须主动来拉，否则
// 「先双击文件再等 App 起来」永远打不开（reviewer 指出的静默丢事件）。
//
// 去重：同一路径可能同时经「native 直投」与「takePending 队列」到达
// （native 入队后立刻直投，Dart 随后 drain 又拿到同一条）——用短窗口
// （2s）+ 在途集合去重，既避免重复打开，也不阻塞用户稍后重开同一文件。
// Linux/Windows 没有接线（无文件关联）：invokeMethod 抛 MissingPluginException，
// 静默降级为「只能用应用内打开」。
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../widgets/nonapp_import.dart';

typedef NonAppOpenHandler = Future<void> Function(String path);

class NonAppIntake {
  NonAppIntake._();

  static final NonAppIntake instance = NonAppIntake._();

  static const MethodChannel channel = MethodChannel('nc/open');

  /// 同一路径的去重窗口（native 直投 + 队列 drain 的正常间隔远小于此值）。
  static const Duration dedupeWindow = Duration(seconds: 2);

  bool _attached = false;
  NonAppOpenHandler? _handler;
  final Set<String> _inFlight = <String>{};
  final Map<String, DateTime> _recent = <String, DateTime>{};
  final List<String> _queued = <String>[];
  bool _draining = false;

  bool get attached => _attached;

  /// 测试钩子：清空去重窗口/排队/绑定（并解绑通道 handler）。
  ///
  /// 单例跨测试共享状态会让「冷启动队列被 drain 且不重复派发」这类断言
  /// 互相污染；生产代码不要调用。
  @visibleForTesting
  void resetForTest() {
    _attached = false;
    _handler = null;
    _inFlight.clear();
    _recent.clear();
    _queued.clear();
    _draining = false;
    channel.setMethodCallHandler(null);
  }

  /// 幂等注册通道 handler，随后拉取一次冷启动队列。
  ///
  /// 重复调用是安全的（native 侧 takePending 会清空队列，Dart 侧还有去重）。
  Future<void> attach() async {
    if (!_attached) {
      _attached = true;
      channel.setMethodCallHandler(_onCall);
    }
    await _drain();
  }

  /// 绑定打开处理器（宿主 widget 在 didChangeDependencies 里调用）。
  void bind(NonAppOpenHandler handler) {
    _handler = handler;
    if (_queued.isEmpty) return;
    final pending = List<String>.from(_queued);
    _queued.clear();
    for (final path in pending) {
      _dispatch(path);
    }
  }

  Future<dynamic> _onCall(MethodCall call) async {
    if (call.method != 'openPath') return null;
    final args = call.arguments;
    final path = args is Map ? (args['path'] ?? '').toString() : '';
    await _dispatch(path);
    // native 入队后直投的同一条还在队列里：顺手清掉（去重窗口吃掉重复）。
    await _drain();
    return null;
  }

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    try {
      List<Object?>? raw;
      try {
        raw = await channel.invokeMethod<List<Object?>>('takePending');
      } on MissingPluginException {
        return; // 未接线平台（Linux/Windows/测试宿主默认）
      } catch (e) {
        debugPrint('[nonapp] takePending failed: $e');
        return;
      }
      for (final path in (raw ?? const <Object?>[]).whereType<String>()) {
        await _dispatch(path);
      }
    } finally {
      _draining = false;
    }
  }

  Future<void> _dispatch(String rawPath) async {
    final path = rawPath.trim();
    if (path.isEmpty) return;
    if (_inFlight.contains(path)) return;

    final handler = _handler;
    if (handler == null) {
      // handler 未绑定（widget 尚未挂载）：先排队，**不占去重窗口**——否则
      // bind 后的补派发会被自己刚才的入队吃掉。
      if (!_queued.contains(path)) _queued.add(path);
      return;
    }

    final seenAt = _recent[path];
    final now = DateTime.now();
    if (seenAt != null && now.difference(seenAt) < dedupeWindow) return;
    _recent.removeWhere((_, t) => now.difference(t) >= dedupeWindow);
    _recent[path] = now;

    _inFlight.add(path);
    try {
      await handler(path);
    } catch (e) {
      debugPrint('[nonapp] open $path failed: $e');
    } finally {
      _inFlight.remove(path);
    }
  }
}

/// 把 `nc/open` 的接收接到 widget 树上（main.dart 的 `home:` 外层挂载）。
///
/// 这是原生关联与 Flutter UI 的唯一编译期耦合点：initState 里 attach（注册
/// 通道 + 拉冷启动队列），didChangeDependencies 里 bind（此时才拿得到
/// BuildContext 去导航）。
class NonAppIntakeHost extends StatefulWidget {
  const NonAppIntakeHost({super.key, required this.child});

  final Widget child;

  @override
  State<NonAppIntakeHost> createState() => _NonAppIntakeHostState();
}

class _NonAppIntakeHostState extends State<NonAppIntakeHost> {
  @override
  void initState() {
    super.initState();
    NonAppIntake.instance.attach();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    NonAppIntake.instance.bind((path) => openNonAppFromPath(context, path));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
