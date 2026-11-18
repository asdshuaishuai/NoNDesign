/// 通知服务（Toast）的唯一事实源。
///
/// 形态与时长（`docs/copy-glossary.md` §7 / 用户验收标准 H）：
///  * 圆角胶囊 + 毛玻璃、顶部左侧堆叠——渲染在 `widgets/toast_host.dart`；
///  * 分级时长：info 2s / success 2.5s / warn 4s / error 5s，可手动关闭，
///    调用方可传更短/更长的时长，但一律钳在 1–5s（错误 5s 不早退）；
///  * 历史保留最近 [ToastService.maxHistory] 条（时间与级别不丢），可回看、可重放；
///  * 连续相同通知只保留一条并刷新计时，重复次数记在 [ToastItem.repeatCount]。
///
/// 本文件不依赖页面级弹条组件、不依赖 BuildContext、不依赖任何路由：
/// store / agent / 各工作区持有一个 [ToastService]，界面由宿主渲染。
/// 历史只存在内存里（不落盘）——若要持久化，必须继续遵守「限长 + 脱敏」
/// 两条：[ToastService.maxHistory] 封顶、[ToastService.sanitize] 先行。
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

/// 通知级别。级别决定停留时长与视觉强调，不决定文案（文案走术语表）。
enum ToastLevel { info, success, warn, error }

extension ToastLevelX on ToastLevel {
  /// 分级时长：info 2s / success 2.5s / warn 4s / error 5s。
  ///
  /// 错误停留最久——用户要在提示消失前读完「发生了什么、下一步做什么」。
  Duration get duration => switch (this) {
        ToastLevel.info => const Duration(seconds: 2),
        ToastLevel.success => const Duration(milliseconds: 2500),
        ToastLevel.warn => const Duration(seconds: 4),
        ToastLevel.error => const Duration(seconds: 5),
      };
}

/// 一条通知的不可变快照。历史与当前显示共用同一对象（去重时整体替换）。
@immutable
class ToastItem {
  /// 进程内自增 id；用于关闭、去重、动画 key。
  final int id;

  /// 主句（已脱敏、已压平换行、已按 [ToastVisuals.titleMaxLength] 截断）。
  final String title;

  /// 次要说明（可空，已脱敏、已截断）。
  final String? detail;

  /// 级别。
  final ToastLevel level;

  /// 最近一次触发的时刻（连续相同去重时刷新为最新时间）。
  final DateTime createdAt;

  /// 本次停留时长（钳在 1–5s）。
  final Duration duration;

  /// 连续相同通知的出现次数（首次为 1）。
  final int repeatCount;

  const ToastItem({
    required this.id,
    required this.title,
    this.detail,
    required this.level,
    required this.createdAt,
    required this.duration,
    this.repeatCount = 1,
  });

  ToastItem copyWith({DateTime? createdAt, Duration? duration, int? repeatCount}) => ToastItem(
        id: id,
        title: title,
        detail: detail,
        level: level,
        createdAt: createdAt ?? this.createdAt,
        duration: duration ?? this.duration,
        repeatCount: repeatCount ?? this.repeatCount,
      );

  @override
  String toString() => 'ToastItem(#$id, ${level.name}, "$title"×$repeatCount)';
}

/// 通知视觉开关与尺寸（宿主与测试共用；改样式只改这里）。
abstract final class ToastVisuals {
  /// 毛玻璃默认开启。低端 Android 掉帧时两条降级入口：
  ///  * 构建期 `--dart-define=NONDESIGN_TOAST_BLUR=false`；
  ///  * 运行时 `ToastService.blurEnabled = false`（设置页/宿主探测可切）。
  /// 关闭后胶囊改为不透明实底，其余形态不变。
  static const bool blurDefault = bool.fromEnvironment('NONDESIGN_TOAST_BLUR', defaultValue: true);

  /// 胶囊圆角。
  static const double radius = 18;

  /// 胶囊最大宽度（手机上由可用宽度再收窄）。
  static const double maxWidth = 380;

  /// 毛玻璃模糊半径。
  static const double blurSigma = 18;

  /// 停留时长下限（1s）。
  static const Duration minDuration = Duration(seconds: 1);

  /// 停留时长上限（5s）——错误级正好取上限，不允许更长的静默停留。
  static const Duration maxDuration = Duration(seconds: 5);

  /// 主句截断长度：toast 是短提示，不是输出面板。
  static const int titleMaxLength = 40;

  /// 次要说明截断长度。
  static const int detailMaxLength = 90;
}

/// 全应用通知服务。
///
/// 使用方式（批次 05/06/07/08/11/12/13 集成）：
/// ```dart
/// toast.success('已保存', '当前项目');
/// toast.error('保存失败', '磁盘空间不足');
/// ```
/// 不要在调用点自己拼 `ScaffoldMessenger`/弹条——通知的呈现、时长、去重、
/// 历史全部由这里接管，宿主只负责画。
class ToastService extends ChangeNotifier {
  /// 未显式注入 service 的宿主/调用点默认落在它上面（与 `rootMessengerKey`
  /// 同级的全局出口）。测试请自建实例，避免共享状态。
  static final ToastService instance = ToastService();

  /// 历史条数上限（最近 100 条；超出丢最旧的）。
  final int maxHistory;

  /// 同时显示的条数上限（其余仍在历史里）。
  final int maxVisible;

  /// 是否自动消退。仅测试需要关掉（生产保持 true）。
  final bool autoDismiss;

  final List<ToastItem> _visible = <ToastItem>[];
  final List<ToastItem> _history = <ToastItem>[];
  final Map<int, Timer> _timers = <int, Timer>{};
  int _nextId = 1;
  bool _blurEnabled;
  bool _disposed = false;

  ToastService({
    this.maxHistory = 100,
    this.maxVisible = 3,
    this.autoDismiss = true,
    bool? blurEnabled,
  })  : assert(maxHistory > 0),
        assert(maxVisible > 0),
        _blurEnabled = blurEnabled ?? ToastVisuals.blurDefault;

  /// 毛玻璃开关（低端设备降级）。
  bool get blurEnabled => _blurEnabled;

  set blurEnabled(bool value) {
    if (_disposed || _blurEnabled == value) return;
    _blurEnabled = value;
    notifyListeners();
  }

  /// 当前显示中的通知，最新在前（宿主按此顺序自上而下堆叠）。
  List<ToastItem> get visible => List<ToastItem>.unmodifiable(_visible);

  /// 通知历史，最新在前（含仍在显示中的条目）。
  List<ToastItem> get history => List<ToastItem>.unmodifiable(_history);

  bool get hasVisible => _visible.isNotEmpty;

  /// 发一条普通提示（2s）。
  ToastItem? info(String title, [String? detail]) =>
      show(title, detail: detail, level: ToastLevel.info);

  /// 发一条成功提示（2.5s）。
  ToastItem? success(String title, [String? detail]) =>
      show(title, detail: detail, level: ToastLevel.success);

  /// 发一条提醒（4s）。
  ToastItem? warn(String title, [String? detail]) =>
      show(title, detail: detail, level: ToastLevel.warn);

  /// 发一条错误（5s，不早退）。
  ToastItem? error(String title, [String? detail]) =>
      show(title, detail: detail, level: ToastLevel.error);

  /// 发一条通知。
  ///
  /// [duration] 缺省按级别取；显式传入时钳在 1–5s。
  /// [dedupe] 为 true（默认）时，与**当前最上面那条**内容和级别都相同的新通知
  /// 不新增条目，而是刷新计时并把 [ToastItem.repeatCount] 加一。
  ToastItem? show(
    String title, {
    String? detail,
    ToastLevel level = ToastLevel.info,
    Duration? duration,
    bool dedupe = true,
  }) {
    if (_disposed) return null;
    var cleanTitle = sanitize(title, maxLength: ToastVisuals.titleMaxLength);
    var cleanDetail = _cleanDetail(detail);
    if (cleanTitle.isEmpty) {
      if (cleanDetail == null) return null;
      cleanTitle = cleanDetail;
      cleanDetail = null;
    }

    final resolved = resolveDuration(level, duration);
    final now = DateTime.now();

    if (dedupe && _visible.isNotEmpty) {
      final head = _visible.first;
      if (head.level == level && head.title == cleanTitle && head.detail == cleanDetail) {
        final refreshed = head.copyWith(
          createdAt: now,
          duration: resolved,
          repeatCount: head.repeatCount + 1,
        );
        _visible[0] = refreshed;
        final at = _history.indexWhere((t) => t.id == refreshed.id);
        if (at >= 0) _history[at] = refreshed;
        _schedule(refreshed);
        notifyListeners();
        return refreshed;
      }
    }

    final item = ToastItem(
      id: _nextId++,
      title: cleanTitle,
      detail: cleanDetail,
      level: level,
      createdAt: now,
      duration: resolved,
    );
    _history.insert(0, item);
    if (_history.length > maxHistory) {
      _history.removeRange(maxHistory, _history.length);
    }
    _visible.insert(0, item);
    while (_visible.length > maxVisible) {
      final dropped = _visible.removeLast();
      _timers.remove(dropped.id)?.cancel();
    }
    _schedule(item);
    notifyListeners();
    return item;
  }

  /// 手动关闭一条（历史保留）。
  void dismiss(int id) {
    if (_disposed) return;
    _timers.remove(id)?.cancel();
    final at = _visible.indexWhere((t) => t.id == id);
    if (at < 0) return;
    _visible.removeAt(at);
    notifyListeners();
  }

  /// 重放一条历史通知（通知中心点按行）——按新通知处理，时长重新计时。
  ToastItem? replay(ToastItem item) =>
      show(item.title, detail: item.detail, level: item.level);

  /// 清空历史与当前显示（通知中心的「清空」）。
  void clearHistory() {
    if (_disposed) return;
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    final had = _history.isNotEmpty || _visible.isNotEmpty;
    _history.clear();
    _visible.clear();
    if (had) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    super.dispose();
  }

  void _schedule(ToastItem item) {
    _timers.remove(item.id)?.cancel();
    if (!autoDismiss || item.duration <= Duration.zero) return;
    _timers[item.id] = Timer(item.duration, () {
      _timers.remove(item.id);
      if (_disposed) return;
      final at = _visible.indexWhere((t) => t.id == item.id);
      if (at < 0) return;
      _visible.removeAt(at);
      notifyListeners();
    });
  }

  String? _cleanDetail(String? detail) {
    if (detail == null) return null;
    final clean = sanitize(detail, maxLength: ToastVisuals.detailMaxLength);
    return clean.isEmpty ? null : clean;
  }

  /// 把显式时长（或级别默认值）钳进 1–5s。
  static Duration resolveDuration(ToastLevel level, Duration? override) {
    final raw = override ?? level.duration;
    if (raw < ToastVisuals.minDuration) return ToastVisuals.minDuration;
    if (raw > ToastVisuals.maxDuration) return ToastVisuals.maxDuration;
    return raw;
  }

  static final RegExp _whitespace = RegExp(r'\s+');
  static final RegExp _homeDir = RegExp(
    r'(/Users/[^/\s]+|/home/[^/\s]+|[A-Za-z]:\\Users\\[^\\\s]+|/var/folders/[^\s]+)',
  );
  static final RegExp _bearer = RegExp(r'\bBearer\s+[A-Za-z0-9._\-]+', caseSensitive: false);
  static final RegExp _namedToken = RegExp(
    r'\b(?:sk|pk|rk|api|key|token|secret)[-_][A-Za-z0-9_\-]{8,}',
    caseSensitive: false,
  );
  static final RegExp _opaqueToken = RegExp(r'\b[A-Za-z0-9_\-]{40,}\b');

  /// 通知文案整形：压平换行、截断、脱敏。
  ///
  /// 历史会长期留在内存并被用户回看，所以敏感内容（密钥、令牌、家目录路径）
  /// 必须在**进入服务之前**就被替换掉——不要指望调用点自己记得清理。
  /// 规则保守：只替换明确的密钥形态、`Bearer` 头、家目录前缀与超长不透明串。
  static String sanitize(String raw, {int maxLength = 120}) {
    var out = raw.replaceAll(_whitespace, ' ').trim();
    if (out.isEmpty) return '';
    out = out.replaceAll(_homeDir, '~');
    out = out.replaceAll(_bearer, '••••');
    out = out.replaceAll(_namedToken, '••••');
    out = out.replaceAll(_opaqueToken, '••••');
    if (out.length > maxLength) out = '${out.substring(0, maxLength)}…';
    return out;
  }
}

/// 把 [ToastService] 挂到子树上的注入点（可选）。
///
/// 宿主与全局出口已经够用；需要按页面替换实例（多窗口、测试）时再包一层：
/// ```dart
/// ToastScope(service: myService, child: ...)
/// ```
class ToastScope extends InheritedNotifier<ToastService> {
  const ToastScope({super.key, required ToastService service, required super.child})
      : super(notifier: service);

  /// 取当前子树的服务；没有注入时回落到 [ToastService.instance]。
  ///
  /// 不建立依赖（不订阅变更）——订阅由宿主负责，调用点只发通知。
  static ToastService of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ToastScope>()?.notifier ?? ToastService.instance;

  static ToastService? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ToastScope>()?.notifier;
}
