/// The four-way shell decision, in one pure function.
///
/// Product ruling (must stay consistent with `docs/copy-glossary.md` and the
/// acceptance matrix):
///
/// | host + orientation            | shell                                   |
/// |-------------------------------|-----------------------------------------|
/// | phone portrait                | chat full screen + work-in-picture       |
/// | phone landscape               | chat full screen + work-in-picture       |
/// | tablet portrait (iPad too)    | chat full screen + work-in-picture       |
/// | tablet landscape              | workspace/welcome + right chat rail      |
/// | macOS / Windows / Linux       | workspace/welcome + right chat rail      |
///
/// The iPad-portrait decision is deliberate and tested: a 3:4 tablet is too
/// narrow to host the workspace *and* a 320–420pt chat rail without shrinking
/// the canvas below a usable size, so portrait iPads keep the chat-first shell
/// and get the workspace as picture-in-picture. Landscape flips to the desktop
/// shell. Do not unify the four faces into one layout.
library;

import 'platform_capabilities.dart';

/// Which of the four shells a viewport uses.
enum LayoutClass { phonePortrait, phoneLandscape, tabletPortrait, tabletLandscape, desktop }

extension LayoutClassX on LayoutClass {
  bool get isPhone => this == LayoutClass.phonePortrait || this == LayoutClass.phoneLandscape;

  bool get isTablet => this == LayoutClass.tabletPortrait || this == LayoutClass.tabletLandscape;

  bool get isPortrait => this == LayoutClass.phonePortrait || this == LayoutClass.tabletPortrait;

  /// Chat is the primary face; the workspace floats as picture-in-picture.
  bool get usesChatFirstShell => isPhone || this == LayoutClass.tabletPortrait;

  /// Workspace/welcome is the primary face; chat is a collapsible side rail.
  bool get usesWorkspaceShell => this == LayoutClass.tabletLandscape || this == LayoutClass.desktop;
}

/// Breakpoints and rail geometry.
///
/// Everything is expressed in logical pixels so the decision is independent of
/// device pixel ratio (a 390×844 phone is the same class at DPR 2 and 3).
class LayoutSpec {
  const LayoutSpec._();

  /// Shortest-side breakpoint between phones and tablets.
  static const double phoneMaxShortSide = 600.0;

  /// Web-only breakpoint for the desktop shell (native desktop is always
  /// `desktop`, no matter how small the window is).
  static const double webDesktopMinWidth = 900.0;

  /// Collapsible chat rail width bounds used by the desktop shell.
  static const double chatRailMinWidth = 320.0;
  static const double chatRailMaxWidth = 420.0;

  /// Classify a viewport for [os].
  ///
  /// Native desktop is intentionally not size-sensitive: the window is
  /// resizable and the workspace shell knows how to collapse its rail, so a
  /// 700pt-wide desktop window must not fall back to a phone shell.
  static LayoutClass classify({
    required double width,
    required double height,
    required HostOs os,
    bool isWeb = false,
  }) {
    if (!isWeb && (os == HostOs.macos || os == HostOs.windows || os == HostOs.linux)) {
      return LayoutClass.desktop;
    }
    if (isWeb && width >= webDesktopMinWidth) {
      return LayoutClass.desktop;
    }
    final shortSide = width < height ? width : height;
    final portrait = height >= width;
    if (shortSide >= phoneMaxShortSide) {
      return portrait ? LayoutClass.tabletPortrait : LayoutClass.tabletLandscape;
    }
    return portrait ? LayoutClass.phonePortrait : LayoutClass.phoneLandscape;
  }

  /// Classify using a host profile.
  static LayoutClass classifyHost(
    PlatformCapabilities caps, {
    required double width,
    required double height,
  }) => classify(width: width, height: height, os: caps.os, isWeb: caps.isWeb);

  /// Width of the collapsible chat rail for a workspace-shell viewport.
  ///
  /// 28% of the viewport clamped to 320–420pt, which keeps the canvas dominant
  /// on 1024-wide tablets and stops the rail from growing on 4K displays.
  static double chatRailWidth(double viewportWidth, {double fraction = 0.28}) {
    final raw = viewportWidth * fraction;
    if (raw.isNaN) return chatRailMinWidth;
    return raw.clamp(chatRailMinWidth, chatRailMaxWidth);
  }
}
