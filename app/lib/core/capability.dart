/// Capability contract shared by every surface of the app.
///
/// Why this file exists: whole features can be missing depending on the host
/// (a phone without a local design engine, a desktop without an external
/// agent, a platform without a share sheet). Historically those features
/// degraded silently — `api == null` meant "do nothing", so 3D / hot-app /
/// video / portfolio entry points did not react at all. From now on every
/// surface asks [CapabilityHub] (see `capability_hub.dart`) first and renders
/// the [CapabilityAvailability] it gets back instead of guessing.
///
/// Rules for consumers:
///  * never treat `null` as "feature missing" — ask the hub;
///  * never show [CapabilityAvailability.technicalDetail] without putting it
///    behind a collapsed "技术详情" disclosure; the default [message] is the
///    only text that may be shown directly;
///  * never mention implementation names (engine, server, wasm, …) in
///    [message] — user-facing copy is governed by `docs/copy-glossary.md` and
///    enforced by `test/copy_guard_test.dart`.
library;

/// Stable identifiers for everything the app can offer that may be absent on
/// a given host. Keep this list small and user-meaningful: it doubles as the
/// verification checklist for [CapabilityHub].
enum CapabilityId {
  /// The in-process design engine (canvas gates, project read/write).
  localDesignEngine,

  /// Optional "连接桌面" runtime provided by a desktop host.
  connectedDesktop,

  /// External agent executables (desktop only by design).
  externalAgent,

  /// 3D scene workspace.
  threeStudio,

  /// Hot-app (生成 / 精修) workspace.
  hotApp,

  /// Video workspace.
  videoStudio,

  /// Portfolio / shelf media surface.
  portfolio,

  /// On-device semantic search models.
  mediaSearch,

  /// Local project database (app library, nonapp index).
  appDatabase,

  /// "在文件夹中显示" on desktop file managers.
  revealInFolder,

  /// System share sheet (no plugin is bundled yet).
  shareSheet,

  /// Video export / encoding (desktop render binaries only).
  videoRender,
}

/// The state of a single capability.
enum CapabilityState {
  /// Ready to use right now.
  available,

  /// Usable, but with a limitation the UI must disclose (e.g. read-only).
  degraded,

  /// Not usable on this host / in this configuration.
  unavailable,

  /// Not probed yet. Surfaces render this as unavailable but may retry.
  unknown,
}

/// Default user-facing copy for each capability.
///
/// These strings are deliberately plain speech: no implementation names, no
/// error codes, no host/port wording. Owners may override the wording through
/// [CapabilityAvailability.message] but must keep the same tone.
const Map<CapabilityId, String> defaultCapabilityMessages = {
  CapabilityId.localDesignEngine: '本地设计引擎暂时不可用',
  CapabilityId.connectedDesktop: '还没有连接桌面',
  CapabilityId.externalAgent: '外部智能体只在电脑上可用',
  CapabilityId.threeStudio: '3D 场景需要先连接桌面',
  CapabilityId.hotApp: '热应用需要先连接桌面',
  CapabilityId.videoStudio: '视频工作区需要先连接桌面',
  CapabilityId.portfolio: '还没有作品',
  CapabilityId.mediaSearch: '离线搜索模型还没有下载',
  CapabilityId.appDatabase: '应用数据暂时无法保存',
  CapabilityId.revealInFolder: '这台设备不支持在文件夹中显示',
  CapabilityId.shareSheet: '这台设备暂不支持系统分享',
  CapabilityId.videoRender: '视频导出只在电脑上可用',
};

/// Immutable snapshot of one capability at a point in time.
class CapabilityAvailability {
  /// Which capability this snapshot describes.
  final CapabilityId id;

  /// Current state.
  final CapabilityState state;

  /// Optional user-facing sentence overriding [defaultCapabilityMessages].
  final String? message;

  /// Raw diagnostic text (host errors, probes). Never displayed directly —
  /// it belongs inside a collapsed "技术详情" disclosure.
  final String? technicalDetail;

  /// Capabilities that can enable this one: **any** of them being usable is
  /// enough (local design engine *or* a connected desktop, for example).
  ///
  /// The hub upgrades/downgrades [state] accordingly, so surfaces only need to
  /// read the returned snapshot.
  final List<CapabilityId> requiresAny;

  const CapabilityAvailability({
    required this.id,
    required this.state,
    this.message,
    this.technicalDetail,
    this.requiresAny = const [],
  });

  /// Convenience constructors used by probes and integrations.
  const CapabilityAvailability.available(
    CapabilityId id, {
    String? message,
    String? technicalDetail,
    List<CapabilityId> requiresAny = const [],
  }) : this(
         id: id,
         state: CapabilityState.available,
         message: message,
         technicalDetail: technicalDetail,
         requiresAny: requiresAny,
       );

  const CapabilityAvailability.unavailable(
    CapabilityId id, {
    String? message,
    String? technicalDetail,
    List<CapabilityId> requiresAny = const [],
  }) : this(
         id: id,
         state: CapabilityState.unavailable,
         message: message,
         technicalDetail: technicalDetail,
         requiresAny: requiresAny,
       );

  /// True when a surface may let the user act.
  bool get isUsable =>
      state == CapabilityState.available || state == CapabilityState.degraded;

  /// User-facing sentence: the override when present, otherwise the default.
  String get userMessage => message ?? defaultCapabilityMessages[id] ?? '暂时不可用';

  CapabilityAvailability copyWith({
    CapabilityState? state,
    String? message,
    String? technicalDetail,
    List<CapabilityId>? requiresAny,
  }) {
    return CapabilityAvailability(
      id: id,
      state: state ?? this.state,
      message: message ?? this.message,
      technicalDetail: technicalDetail ?? this.technicalDetail,
      requiresAny: requiresAny ?? this.requiresAny,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CapabilityAvailability &&
      other.id == id &&
      other.state == state &&
      other.message == message &&
      other.technicalDetail == technicalDetail &&
      _listEquals(other.requiresAny, requiresAny);

  @override
  int get hashCode => Object.hash(id, state, message, technicalDetail, Object.hashAll(requiresAny));

  @override
  String toString() => 'CapabilityAvailability($id, $state, "$userMessage")';
}

/// Thrown by [CapabilityHub.require] when a surface acts on a missing feature.
///
/// The UI should catch this and show [availability.userMessage] — the raw
/// message is never an error code.
class CapabilityMissing implements Exception {
  final CapabilityAvailability availability;

  const CapabilityMissing(this.availability);

  @override
  String toString() => 'CapabilityMissing(${availability.id}: ${availability.userMessage})';
}

/// Budgets that gate enabling the in-process design engine on phones/tablets.
///
/// The engine runs through a third-party wasm host on mobile; it may only be
/// switched on after `integration_test/wasm_spike_test.dart` proves these
/// budgets on a real device. Desktop is exempt: it ships the host that is
/// already proven by the Python/Rust hosts.
///
/// `NONDESIGN_MOBILE_LOCAL_ENGINE` stays false until the spike passes on iOS
/// *and* Android. Android is currently unbuildable/unverifiable (batch 00
/// N3), so mobile stays on "连接桌面" and this flag must not be flipped.
class WasmRuntimeGate {
  const WasmRuntimeGate._();

  /// p95 of one engine call (render / apply / session op) on the device.
  static const Duration callP95Budget = Duration(milliseconds: 250);

  /// p95 of a full document render (SVG) on the device.
  static const Duration renderP95Budget = Duration(milliseconds: 400);

  /// Cold start: module compile + instantiate + first render.
  static const Duration coldStartBudget = Duration(seconds: 3);

  /// Peak linear memory the engine may hold before recycling.
  static const int peakMemoryBudgetBytes = 192 * 1024 * 1024;

  /// Fuel allowed per engine call when the runtime supports it.
  ///
  /// Measured on wasmtime 14.0.4 with the 0.2-dev engine (spike, 2026-11-18):
  /// render ≈ 2.3M, apply ≈ 1.3M, generate ≈ 135.7M fuel units. 500M keeps a
  /// ~3.7× headroom over generative UI while still trapping a runaway call.
  static const int fuelPerCallBudget = 500000000;

  /// Whether phones/tablets may run the engine locally.
  ///
  /// Hard default: false. Flip only with recorded spike evidence
  /// (`docs/wasm-run-vendoring.md` § verification).
  static const bool mobileLocalEngineEnabled = bool.fromEnvironment(
    'NONDESIGN_MOBILE_LOCAL_ENGINE',
    defaultValue: false,
  );
}

bool _listEquals(List<CapabilityId> a, List<CapabilityId> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
