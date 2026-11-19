// 移动适配方向门（2026-11-19 裁决）：
//  * 手机：锁定竖屏（不允许横竖切换）；
//  * 平板：四向跟随系统——横屏落桌面壳、竖屏落聊天优先壳（裁决 C 不变）。
// 决策纯函数 + 平板判定（600 短边，与 LayoutSpec 同源）+ 壳分类验收行。
import 'dart:ui' show FlutterView;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nondesign/core/layout.dart';
import 'package:nondesign/core/orientation.dart';
import 'package:nondesign/core/platform_capabilities.dart';

void main() {
  group('方向门决策', () {
    test('手机：只允许竖屏（不允许横竖切换）', () {
      expect(
        preferredOrientationsFor(tablet: false),
        [DeviceOrientation.portraitUp],
      );
    });

    test('平板：四向跟随系统旋转', () {
      expect(
        preferredOrientationsFor(tablet: true),
        const <DeviceOrientation>[
          DeviceOrientation.portraitUp,
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
          DeviceOrientation.portraitDown,
        ],
      );
    });
  });

  group('平板判定（600 短边，与 LayoutSpec 同源）', () {
    testWidgets('手机竖屏 390×844@1：不是平板', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final view = tester.view;
      expect(isTabletViewport(view), isFalse);
    });

    testWidgets('iPad 竖屏 834×1194@2：是平板', (tester) async {
      tester.view.physicalSize = const Size(1668, 2388);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final view = tester.view;
      expect(isTabletViewport(view), isTrue);
    });

    testWidgets('小屏手机 320×640@1（短边 320）：仍是手机', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final view = tester.view;
      expect(isTabletViewport(view), isFalse);
    });
  });

  group('方向门与壳分类必须指向同一个世界（验收矩阵锚定）', () {
    test('手机竖屏：锁竖屏 + 聊天优先壳', () {
      final cls = LayoutSpec.classify(
          width: 390, height: 844, os: HostOs.ios);
      expect(cls, LayoutClass.phonePortrait);
      expect(cls.usesChatFirstShell, isTrue);
      expect(preferredOrientationsFor(tablet: cls.isTablet),
          [DeviceOrientation.portraitUp]);
    });

    test('iPad 竖屏：四向 + 聊天优先壳', () {
      final cls = LayoutSpec.classify(
          width: 834, height: 1194, os: HostOs.ios);
      expect(cls, LayoutClass.tabletPortrait);
      expect(cls.usesChatFirstShell, isTrue);
      expect(preferredOrientationsFor(tablet: cls.isTablet).length, 4);
    });

    test('iPad 横屏：四向 + 桌面壳（与 macOS/Windows/Linux 同一面）', () {
      final cls = LayoutSpec.classify(
          width: 1194, height: 834, os: HostOs.ios);
      expect(cls, LayoutClass.tabletLandscape);
      expect(cls.usesWorkspaceShell, isTrue);
      expect(preferredOrientationsFor(tablet: cls.isTablet).length, 4);
    });

    test('桌面宿主：分类恒为 desktop（方向 API 对其是 no-op）', () {
      final cls = LayoutSpec.classify(
          width: 700, height: 500, os: HostOs.macos);
      expect(cls, LayoutClass.desktop);
      expect(cls.usesWorkspaceShell, isTrue);
    });
  });
}

// FlutterView 在 flutter_test 里的具体类型随 SDK 演进；这里只借测试视图的
// 尺寸/DPR 面，用动态转发保持测试与实现解耦。
// ignore: unused_element
class _Unused {
  // 占位：禁止 tree-shaking 误删 FlutterView 引用（dart:ui 导入面）。
  final FlutterView? v = null;
}
