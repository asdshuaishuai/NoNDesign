/// Host facts used by the shell split and the capability hub.
///
/// This file is the only place that inspects the host platform. Everything
/// else receives a [PlatformCapabilities] value, which keeps the rest of the
/// contract layer pure and unit-testable without a Flutter binding (see
/// `test/layout_classifier_test.dart` and `test/architecture_guard_test.dart`).
///
/// The capability matrix below encodes decisions that are already recorded in
/// `docs/copy-glossary.md` and the migration plan:
///  * external agents and video export are desktop-only (phones cannot spawn
///    arbitrary executables);
///  * no share sheet is bundled, so the capability is honestly unavailable;
///  * phones/tablets only get a local design engine after the wasm spike
///    passes ([WasmRuntimeGate.mobileLocalEngineEnabled] defaults to false).
library;

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;

import 'capability.dart';

/// The operating-system family the current shell runs on.
enum HostOs { macos, windows, linux, ios, android, fuchsia, web, other }

/// Immutable host profile plus the seeded capability matrix.
class PlatformCapabilities {
  final HostOs os;

  /// Whether this is a web build (Flutter web has no desktop plugins).
  final bool isWeb;

  const PlatformCapabilities({required this.os, this.isWeb = false});

  /// Profile for the host the process is running on.
  factory PlatformCapabilities.current() =>
      PlatformCapabilities(os: currentHostOs(), isWeb: kIsWeb);

  /// Profile for an explicitly named host (tests, remote shells).
  factory PlatformCapabilities.forOs(HostOs os, {bool isWeb = false}) =>
      PlatformCapabilities(os: isWeb ? HostOs.web : os, isWeb: isWeb);

  /// Maps [defaultTargetPlatform] onto [HostOs]; web always wins.
  static HostOs currentHostOs() {
    if (kIsWeb) return HostOs.web;
    switch (defaultTargetPlatform) {
      case TargetPlatform.macOS:
        return HostOs.macos;
      case TargetPlatform.windows:
        return HostOs.windows;
      case TargetPlatform.linux:
        return HostOs.linux;
      case TargetPlatform.iOS:
        return HostOs.ios;
      case TargetPlatform.android:
        return HostOs.android;
      case TargetPlatform.fuchsia:
        return HostOs.fuchsia;
    }
  }

  bool get isDesktop => os == HostOs.macos || os == HostOs.windows || os == HostOs.linux;

  bool get isMobile => os == HostOs.ios || os == HostOs.android;

  /// Desktop file managers can reveal a path ("在文件夹中显示").
  bool get supportsRevealInFolder => isDesktop;

  /// Spawning external agent executables is a desktop-only ability.
  bool get supportsExternalAgent => isDesktop;

  /// Encoding/exporting video needs local render binaries.
  bool get supportsVideoRender => isDesktop;

  /// No share plugin is bundled — do not pretend otherwise.
  bool get supportsShareSheet => false;

  /// `webview_all` covers every app target: Android WebView, WKWebView
  /// (iOS/macOS), WebView2 (Windows), WebKitGTK (Linux), ArkWeb (OHOS).
  /// Only a Web build has no native WebView.
  bool get supportsInAppWebView => !isWeb;

  /// `sqlite3_flutter_libs` ships native libraries for the five app targets.
  bool get supportsAppDatabase => !isWeb;

  /// The in-process design engine.
  ///
  /// Desktop ships the proven host. Phones/tablets are gated behind the wasm
  /// spike budgets ([WasmRuntimeGate]) and stay disabled by default.
  bool get supportsLocalDesignEngine => isDesktop || (isMobile && WasmRuntimeGate.mobileLocalEngineEnabled);

  /// Features that need either the local engine or a connected desktop.
  static const List<CapabilityId> _designDependents = [CapabilityId.localDesignEngine, CapabilityId.connectedDesktop];

  /// Seed snapshot for [id] on this host.
  ///
  /// The hub applies dependency resolution on top (see
  /// `CapabilityHub.resolve`), so this matrix only states platform facts.
  CapabilityAvailability baseAvailability(CapabilityId id) {
    switch (id) {
      case CapabilityId.localDesignEngine:
        return CapabilityAvailability(
          id: id,
          state: supportsLocalDesignEngine ? CapabilityState.available : CapabilityState.unavailable,
          technicalDetail: supportsLocalDesignEngine ? null : 'local wasm host not enabled on ${os.name}',
        );
      case CapabilityId.connectedDesktop:
        // Opt-in by definition; the hub upgrades it when a desktop is paired.
        return const CapabilityAvailability(id: CapabilityId.connectedDesktop, state: CapabilityState.unavailable);
      case CapabilityId.externalAgent:
        return CapabilityAvailability(
          id: id,
          state: supportsExternalAgent ? CapabilityState.available : CapabilityState.unavailable,
          technicalDetail: supportsExternalAgent ? null : 'no process spawning on ${os.name}',
        );
      case CapabilityId.threeStudio:
      case CapabilityId.hotApp:
      case CapabilityId.videoStudio:
        return CapabilityAvailability(
          id: id,
          state: supportsLocalDesignEngine ? CapabilityState.available : CapabilityState.unavailable,
          requiresAny: _designDependents,
        );
      case CapabilityId.portfolio:
        return const CapabilityAvailability(id: CapabilityId.portfolio, state: CapabilityState.available);
      case CapabilityId.mediaSearch:
        return const CapabilityAvailability(id: CapabilityId.mediaSearch, state: CapabilityState.available);
      case CapabilityId.appDatabase:
        return CapabilityAvailability(
          id: id,
          state: supportsAppDatabase ? CapabilityState.available : CapabilityState.unavailable,
        );
      case CapabilityId.revealInFolder:
        return CapabilityAvailability(
          id: id,
          state: supportsRevealInFolder ? CapabilityState.available : CapabilityState.unavailable,
        );
      case CapabilityId.shareSheet:
        return CapabilityAvailability(
          id: id,
          state: supportsShareSheet ? CapabilityState.available : CapabilityState.unavailable,
        );
      case CapabilityId.videoRender:
        return CapabilityAvailability(
          id: id,
          state: supportsVideoRender ? CapabilityState.available : CapabilityState.unavailable,
        );
    }
  }
}
