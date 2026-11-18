// Layout contract tests (batch 01).
//
// The four faces are intentionally different; this file pins the decision so a
// later shell refactor cannot silently unify them.
//
// Acceptance sizes: 390×844, 844×390, 768×1024, 1024×768, 1440×900.
// iPad portrait is the explicit ruling: chat-first + work-in-picture.

import 'package:flutter_test/flutter_test.dart';
import 'package:nondesign/core/layout.dart';
import 'package:nondesign/core/platform_capabilities.dart';

void main() {
  LayoutClass classify(double w, double h, HostOs os, {bool web = false}) =>
      LayoutSpec.classify(width: w, height: h, os: os, isWeb: web);

  group('acceptance sizes', () {
    test('390×844 phone portrait → chat + picture-in-picture', () {
      final layout = classify(390, 844, HostOs.ios);
      expect(layout, LayoutClass.phonePortrait);
      expect(layout.usesChatFirstShell, isTrue);
      expect(layout.usesWorkspaceShell, isFalse);
    });

    test('844×390 phone landscape → chat + picture-in-picture', () {
      final layout = classify(844, 390, HostOs.ios);
      expect(layout, LayoutClass.phoneLandscape);
      expect(layout.usesChatFirstShell, isTrue);
    });

    test('768×1024 iPad portrait → chat + picture-in-picture (documented ruling)', () {
      final layout = classify(768, 1024, HostOs.ios);
      expect(layout, LayoutClass.tabletPortrait);
      expect(layout.usesChatFirstShell, isTrue,
          reason: 'portrait iPad is too narrow for canvas + 320–420pt chat rail');
      expect(layout.usesWorkspaceShell, isFalse);
    });

    test('1024×768 iPad landscape → workspace + right chat rail', () {
      final layout = classify(1024, 768, HostOs.ios);
      expect(layout, LayoutClass.tabletLandscape);
      expect(layout.usesWorkspaceShell, isTrue);
      expect(layout.usesChatFirstShell, isFalse);
    });

    test('1440×900 macOS → workspace + right chat rail', () {
      final layout = classify(1440, 900, HostOs.macos);
      expect(layout, LayoutClass.desktop);
      expect(layout.usesWorkspaceShell, isTrue);
    });
  });

  group('host rules', () {
    test('native desktop is always the desktop shell, even in a small window', () {
      for (final size in [const (700.0, 520.0), const (1200.0, 500.0), const (400.0, 300.0)]) {
        expect(classify(size.$1, size.$2, HostOs.macos), LayoutClass.desktop);
        expect(classify(size.$1, size.$2, HostOs.windows), LayoutClass.desktop);
        expect(classify(size.$1, size.$2, HostOs.linux), LayoutClass.desktop);
      }
    });

    test('web uses the desktop shell from 900pt wide and falls back to touch classes below', () {
      expect(classify(900, 800, HostOs.web, web: true), LayoutClass.desktop);
      expect(classify(899, 800, HostOs.web, web: true), LayoutClass.tabletLandscape);
      expect(classify(500, 800, HostOs.web, web: true), LayoutClass.phonePortrait);
    });

    test('android tablets follow the same orientation ruling', () {
      expect(classify(800, 1280, HostOs.android), LayoutClass.tabletPortrait);
      expect(classify(1280, 800, HostOs.android), LayoutClass.tabletLandscape);
    });
  });

  group('breakpoints', () {
    test('short side 600 is the phone/tablet boundary', () {
      expect(classify(599, 900, HostOs.ios), LayoutClass.phonePortrait);
      expect(classify(600, 900, HostOs.ios), LayoutClass.tabletPortrait);
      // Landscape: the *short* side is the height, so 900×600 is the first
      // tablet-landscape size (900×599 is still a phone).
      expect(classify(900, 599, HostOs.ios), LayoutClass.phoneLandscape);
      expect(classify(900, 600, HostOs.ios), LayoutClass.tabletLandscape);
    });

    test('classification is DPR independent (logical pixels only)', () {
      for (final size in [
        const (390.0, 844.0),
        const (844.0, 390.0),
        const (768.0, 1024.0),
        const (1024.0, 768.0),
      ]) {
        final first = classify(size.$1, size.$2, HostOs.ios);
        final second = classify(size.$1, size.$2, HostOs.ios);
        expect(second, first);
      }
    });

    test('exactly one shell owns every class', () {
      for (final layout in LayoutClass.values) {
        expect(layout.usesChatFirstShell != layout.usesWorkspaceShell, isTrue,
            reason: '$layout must belong to exactly one shell');
      }
    });

    test('portrait and tablet getters agree with the enum', () {
      expect(LayoutClass.phonePortrait.isPhone, isTrue);
      expect(LayoutClass.tabletLandscape.isTablet, isTrue);
      expect(LayoutClass.tabletLandscape.isPortrait, isFalse);
      expect(LayoutClass.phonePortrait.isPortrait, isTrue);
      expect(LayoutClass.desktop.isPhone, isFalse);
      expect(LayoutClass.desktop.isTablet, isFalse);
    });
  });

  group('chat rail width', () {
    test('stays inside the 320–420pt product range', () {
      expect(LayoutSpec.chatRailWidth(1024), LayoutSpec.chatRailMinWidth);
      expect(LayoutSpec.chatRailWidth(1440), closeTo(403.2, 0.01));
      expect(LayoutSpec.chatRailWidth(2560), LayoutSpec.chatRailMaxWidth);
      expect(LayoutSpec.chatRailWidth(320), LayoutSpec.chatRailMinWidth);
    });

    test('uses the platform profile helper', () {
      final caps = PlatformCapabilities.forOs(HostOs.ios);
      expect(LayoutSpec.classifyHost(caps, width: 1024, height: 768), LayoutClass.tabletLandscape);
      final desktop = PlatformCapabilities.forOs(HostOs.macos);
      expect(LayoutSpec.classifyHost(desktop, width: 700, height: 500), LayoutClass.desktop);
    });
  });
}
