/// 设备方向门（移动适配裁决 2026-11-19，用户明示）：
///
/// * **手机：锁定竖屏**——不允许横竖切换（横屏手机壳只是防御性兜底，
///   真机上到不了）；
/// * **平板：跟随系统旋转**——横屏与桌面壳一致（工作区优先），竖屏与
///   手机一致（聊天优先 + 工作区画中画），裁决 C 不变；
/// * **桌面：无方向概念**——方向 API 在 macOS/Windows/Linux 是 no-op，
///   行为与引入前完全一致。
///
/// 决策是纯函数（可单测）；应用动作走 [SystemChrome]。判定与
/// `LayoutSpec.phoneMaxShortSide`（600 短边）同源：手机/平板的壳分类与
/// 方向门必须永远指向同一个世界。
library;

import 'dart:ui' show FlutterView;

import 'package:flutter/services.dart';

import 'layout.dart';

/// 视口短边（逻辑像素）≥ 600 视为平板。
bool isTabletViewport(FlutterView view) {
  final dpr = view.devicePixelRatio;
  if (dpr <= 0) return false;
  final w = view.physicalSize.width / dpr;
  final h = view.physicalSize.height / dpr;
  final short = w < h ? w : h;
  return short >= LayoutSpec.phoneMaxShortSide;
}

/// 方向门决策（纯函数）。
///
/// 手机：只有竖屏——裁决原文「手机端不允许横竖切换」。
/// 平板：四向跟随系统，横竖屏分别落桌面壳 / 聊天优先壳。
List<DeviceOrientation> preferredOrientationsFor({required bool tablet}) => tablet
    ? const <DeviceOrientation>[
        DeviceOrientation.portraitUp,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
        DeviceOrientation.portraitDown,
      ]
    : const <DeviceOrientation>[DeviceOrientation.portraitUp];

/// 对给定视图应用方向门。桌面宿主调用是 no-op，不影响桌面行为。
void applyDeviceOrientationFor(FlutterView view) {
  SystemChrome.setPreferredOrientations(
      preferredOrientationsFor(tablet: isTabletViewport(view)));
}
