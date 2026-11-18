/// Runtime registry for [CapabilityAvailability] snapshots.
///
/// Surfaces (shell, store, workspaces, settings) ask the hub instead of
/// inferring availability from `api == null` or from the platform alone. The
/// hub merges three inputs:
///
///  1. the platform matrix ([PlatformCapabilities.baseAvailability]);
///  2. runtime updates pushed by integrations (`setConnectedDesktop`,
///     `update`) — e.g. the "连接桌面" pair succeeding;
///  3. optional async probes (`addProbe` + `refresh`) for expensive checks.
///
/// Dependency resolution (`requiresAny`) is applied on read, so a capability
/// that is enabled by "local engine *or* connected desktop" flips to available
/// the moment either becomes usable — and flips back when both go away.
///
/// This file deliberately imports no Flutter or `dart:io` code: it is pure
/// Dart and unit-testable without a widget binding.
library;

import 'capability.dart';
import 'platform_capabilities.dart';

/// Callback signature for [CapabilityHub.addListener].
typedef CapabilityListener = void Function(CapabilityAvailability availability);

/// Asynchronous capability probe. Return `null` to leave the state untouched.
typedef CapabilityProbe = Future<CapabilityAvailability?> Function(CapabilityId id);

/// Central capability registry. One instance per app (owned by the store);
/// tests construct isolated instances.
class CapabilityHub {
  CapabilityHub({
    required this.platform,
    Map<CapabilityId, CapabilityAvailability> initial = const {},
    List<CapabilityProbe> probes = const [],
  }) : _live = Map<CapabilityId, CapabilityAvailability>.from(initial),
       _probes = List<CapabilityProbe>.from(probes) {
    for (final id in CapabilityId.values) {
      _resolved[id] = _resolve(id);
    }
  }

  /// Convenience constructor for tests / tools that only know a host OS.
  factory CapabilityHub.forOs(HostOs os, {bool isWeb = false}) =>
      CapabilityHub(platform: PlatformCapabilities.forOs(os, isWeb: isWeb));

  final PlatformCapabilities platform;
  final Map<CapabilityId, CapabilityAvailability> _live;
  final List<CapabilityProbe> _probes;
  final Map<CapabilityId, CapabilityAvailability> _resolved = {};
  final List<CapabilityListener> _listeners = [];

  /// Current resolved snapshot for [id]. Never throws.
  CapabilityAvailability availability(CapabilityId id) =>
      _resolved[id] ??= _resolve(id);

  /// Whether the user may act on [id] right now.
  bool isUsable(CapabilityId id) => availability(id).isUsable;

  /// User-facing sentence for [id] (never an error code).
  String message(CapabilityId id) => availability(id).userMessage;

  /// Throws [CapabilityMissing] when [id] is not usable; returns the snapshot
  /// otherwise. Surfaces use this at the action boundary so a tap can never do
  /// nothing silently.
  CapabilityAvailability require(CapabilityId id) {
    final a = availability(id);
    if (!a.isUsable) throw CapabilityMissing(a);
    return a;
  }

  /// Every capability in stable [CapabilityId] order.
  Iterable<CapabilityAvailability> get all => CapabilityId.values.map(availability);

  /// Capabilities that are not usable right now (for diagnostics screens and
  /// the baseline copy report).
  List<CapabilityAvailability> get missing => all.where((a) => !a.isUsable).toList(growable: false);

  void addListener(CapabilityListener listener) => _listeners.add(listener);

  void removeListener(CapabilityListener listener) => _listeners.remove(listener);

  /// Push a runtime snapshot (probe result, workspace-specific override).
  void update(CapabilityAvailability availability) {
    _live[availability.id] = availability;
    _recompute(availability.id);
  }

  /// Drop a runtime override and fall back to the platform matrix.
  void reset(CapabilityId id) {
    if (_live.remove(id) == null) return;
    _recompute(id);
  }

  /// Record the outcome of the optional "连接桌面" pairing.
  ///
  /// [technicalDetail] is for the collapsed details section only (host, port,
  /// token errors); [message] is the user-facing sentence, if a custom one is
  /// needed.
  void setConnectedDesktop({
    required bool connected,
    String? message,
    String? technicalDetail,
  }) {
    update(
      CapabilityAvailability(
        id: CapabilityId.connectedDesktop,
        state: connected ? CapabilityState.available : CapabilityState.unavailable,
        message: message,
        technicalDetail: technicalDetail,
      ),
    );
  }

  /// Register an async probe used by [refresh].
  void addProbe(CapabilityProbe probe) => _probes.add(probe);

  /// Run the registered probes for [id] and apply the first non-null result.
  Future<CapabilityAvailability> refresh(CapabilityId id) async {
    for (final probe in _probes) {
      final result = await probe(id);
      if (result != null && result.id == id) {
        update(result);
        return availability(id);
      }
    }
    return availability(id);
  }

  // ---- internals ----

  CapabilityAvailability _resolve(CapabilityId id) {
    final stored = _live[id] ?? platform.baseAvailability(id);
    if (stored.requiresAny.isEmpty) return stored;

    final anyUsable = stored.requiresAny.any((req) {
      if (req == id) return false;
      final reqState = _resolved[req] ?? _live[req] ?? platform.baseAvailability(req);
      return reqState.isUsable;
    });

    if (anyUsable) {
      if (stored.state == CapabilityState.unavailable) {
        return stored.copyWith(state: CapabilityState.available);
      }
      return stored;
    }
    if (stored.isUsable) {
      // Was enabled by a dependency that just went away.
      return stored.copyWith(state: CapabilityState.unavailable);
    }
    return stored;
  }

  void _recompute(CapabilityId changed) {
    final changedBefore = _resolved[changed];
    _resolved[changed] = _resolve(changed);
    final dependents = <CapabilityId>[];
    for (final id in CapabilityId.values) {
      if (id == changed) continue;
      final cap = _live[id] ?? platform.baseAvailability(id);
      if (!cap.requiresAny.contains(changed)) continue;
      dependents.add(id);
      _resolved[id] = _resolve(id);
    }
    final notifications = <CapabilityAvailability>[
      if (_resolved[changed] != changedBefore) _resolved[changed]!,
      for (final id in dependents) _resolved[id]!,
    ];
    if (notifications.isEmpty) return;
    for (final listener in List<CapabilityListener>.from(_listeners)) {
      for (final availability in notifications) {
        listener(availability);
      }
    }
  }
}
