import 'dart:io' show Platform;

import 'package:material_ui/material_ui.dart';

@immutable
class NonPalette extends ThemeExtension<NonPalette> {
  final Color bg;
  final Color bgElevated;
  final Color panel;
  final Color panel2;
  final Color panel3;
  final Color line;
  final Color lineStrong;
  final Color ink;
  final Color ink2;
  final Color ink3;
  final Color ink4;
  final Color accent;
  final Color accent2;
  final Color accentSoft;
  final Color success;
  final Color warn;
  final Color danger;
  final Color canvas;
  final Color canvasDot;

  const NonPalette({
    required this.bg,
    required this.bgElevated,
    required this.panel,
    required this.panel2,
    required this.panel3,
    required this.line,
    required this.lineStrong,
    required this.ink,
    required this.ink2,
    required this.ink3,
    required this.ink4,
    required this.accent,
    required this.accent2,
    required this.accentSoft,
    required this.success,
    required this.warn,
    required this.danger,
    required this.canvas,
    required this.canvasDot,
  });

  static const dark = NonPalette(
    bg: Color(0xFF08090C),
    bgElevated: Color(0xFF0C0E13),
    panel: Color(0xFF11141B),
    panel2: Color(0xFF171B24),
    panel3: Color(0xFF1D222D),
    line: Color(0x14FFFFFF),
    lineStrong: Color(0x24FFFFFF),
    ink: Color(0xFFECEEF5),
    ink2: Color(0xFFA6ADBD),
    ink3: Color(0xFF8A93A6),
    ink4: Color(0xFF6B7383),
    accent: Color(0xFF7C8CFF),
    accent2: Color(0xFFB58CFF),
    accentSoft: Color(0x247C8CFF),
    success: Color(0xFF3DDC97),
    warn: Color(0xFFFFB020),
    danger: Color(0xFFFF5C7A),
    canvas: Color(0xFF0A0B0F),
    canvasDot: Color(0x0FFFFFFF),
  );

  static const light = NonPalette(
    bg: Color(0xFFF3F4F7),
    bgElevated: Color(0xFFECEEF3),
    panel: Color(0xFFFFFFFF),
    panel2: Color(0xFFF7F8FA),
    panel3: Color(0xFFEEF0F4),
    line: Color(0x1410141E),
    lineStrong: Color(0x2410141E),
    ink: Color(0xFF12141A),
    ink2: Color(0xFF525A6A),
    ink3: Color(0xFF6B7383),
    ink4: Color(0xFF83899B),
    accent: Color(0xFF4F5DFF),
    accent2: Color(0xFF8B5CF6),
    accentSoft: Color(0x1A4F5DFF),
    success: Color(0xFF0F9D6B),
    warn: Color(0xFFB45309),
    danger: Color(0xFFDC2650),
    canvas: Color(0xFFE9EBF0),
    canvasDot: Color(0x1710141E),
  );

  @override
  NonPalette copyWith({
    Color? bg,
    Color? bgElevated,
    Color? panel,
    Color? panel2,
    Color? panel3,
    Color? line,
    Color? lineStrong,
    Color? ink,
    Color? ink2,
    Color? ink3,
    Color? ink4,
    Color? accent,
    Color? accent2,
    Color? accentSoft,
    Color? success,
    Color? warn,
    Color? danger,
    Color? canvas,
    Color? canvasDot,
  }) {
    return NonPalette(
      bg: bg ?? this.bg,
      bgElevated: bgElevated ?? this.bgElevated,
      panel: panel ?? this.panel,
      panel2: panel2 ?? this.panel2,
      panel3: panel3 ?? this.panel3,
      line: line ?? this.line,
      lineStrong: lineStrong ?? this.lineStrong,
      ink: ink ?? this.ink,
      ink2: ink2 ?? this.ink2,
      ink3: ink3 ?? this.ink3,
      ink4: ink4 ?? this.ink4,
      accent: accent ?? this.accent,
      accent2: accent2 ?? this.accent2,
      accentSoft: accentSoft ?? this.accentSoft,
      success: success ?? this.success,
      warn: warn ?? this.warn,
      danger: danger ?? this.danger,
      canvas: canvas ?? this.canvas,
      canvasDot: canvasDot ?? this.canvasDot,
    );
  }

  @override
  NonPalette lerp(ThemeExtension<NonPalette>? other, double t) {
    if (other is! NonPalette) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t)!;
    return NonPalette(
      bg: mix(bg, other.bg),
      bgElevated: mix(bgElevated, other.bgElevated),
      panel: mix(panel, other.panel),
      panel2: mix(panel2, other.panel2),
      panel3: mix(panel3, other.panel3),
      line: mix(line, other.line),
      lineStrong: mix(lineStrong, other.lineStrong),
      ink: mix(ink, other.ink),
      ink2: mix(ink2, other.ink2),
      ink3: mix(ink3, other.ink3),
      ink4: mix(ink4, other.ink4),
      accent: mix(accent, other.accent),
      accent2: mix(accent2, other.accent2),
      accentSoft: mix(accentSoft, other.accentSoft),
      success: mix(success, other.success),
      warn: mix(warn, other.warn),
      danger: mix(danger, other.danger),
      canvas: mix(canvas, other.canvas),
      canvasDot: mix(canvasDot, other.canvasDot),
    );
  }
}

extension NonThemeX on BuildContext {
  NonPalette get palette =>
      Theme.of(this).extension<NonPalette>() ?? NonPalette.dark;
}

/// 统一动效语言：所有动画时长/曲线只从这里取，不要散落裸 Duration。
abstract final class NonMotion {
  static const fast = Duration(milliseconds: 120);
  static const base = Duration(milliseconds: 180);
  static const slow = Duration(milliseconds: 240);
  static const Curve curve = Curves.easeOutCubic;
}

class AppTheme {
  /// 按 dark 布尔 memo 化：根组件 NonApp 每次 store.notifyListeners 都会
  /// build——agent 运行期逐条事件全树广播，ThemeData 整段 copyWith 每次重算
  /// 令 MaterialApp/Theme 层级全部失效。dark 只有两个取值，各自构造一次。
  static final ThemeData _dark = _build(dark: true);
  static final ThemeData _light = _build(dark: false);

  static ThemeData build({bool dark = true}) => dark ? _dark : _light;

  static ThemeData _build({bool dark = true}) {
    final p = dark ? NonPalette.dark : NonPalette.light;
    final base = dark
        ? ThemeData.dark(useMaterial3: true)
        : ThemeData.light(useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: p.bg,
      canvasColor: p.bg,
      dividerColor: p.line,
      // hover 与 IconAction 手写 hover 收敛为同一令牌强度（p.line），
      // 消除「手写 32% 白 vs InkWell 默认 4% 白」的两套语言。
      hoverColor: p.line,
      colorScheme: base.colorScheme.copyWith(
        brightness: dark ? Brightness.dark : Brightness.light,
        primary: p.accent,
        secondary: p.accent2,
        surface: p.panel,
        error: p.danger,
        onPrimary: Colors.white,
        onSurface: p.ink,
      ),
      splashFactory: InkRipple.splashFactory,
      textTheme: _withPlatformFont(
        base.textTheme
            .apply(bodyColor: p.ink, displayColor: p.ink)
            .copyWith(
              bodyMedium: TextStyle(fontSize: 13, color: p.ink2, height: 1.45),
              bodySmall: TextStyle(fontSize: 11, color: p.ink3, height: 1.4),
              titleMedium: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: p.ink,
              ),
              titleLarge: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: p.ink,
                letterSpacing: -0.3,
              ),
              headlineMedium: TextStyle(
                fontSize: 34,
                fontWeight: FontWeight.w600,
                color: p.ink,
                letterSpacing: -1,
              ),
            ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        filled: true,
        fillColor: p.panel2,
        hintStyle: TextStyle(color: p.ink4, fontSize: 12),
        labelStyle: TextStyle(color: p.ink3, fontSize: 11),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: p.line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: p.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: p.accent.withValues(alpha: 0.7)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: p.ink,
          foregroundColor: p.bg,
          textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: p.ink2,
          side: BorderSide(color: p.lineStrong),
          textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: p.ink3,
          textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(foregroundColor: p.ink3),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: p.panel3,
          borderRadius: BorderRadius.circular(6),
        ),
        textStyle: TextStyle(color: p.ink, fontSize: 11),
        waitDuration: const Duration(milliseconds: 500),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStatePropertyAll(p.lineStrong),
        radius: const Radius.circular(8),
        thickness: const WidgetStatePropertyAll(6),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: p.accent,
        selectionColor: p.accent.withValues(alpha: 0.25),
        selectionHandleColor: p.accent,
      ),
      // 右键菜单 / PopupMenuButton：统一深色浮层（画布右键、面板菜单共用）。
      popupMenuTheme: PopupMenuThemeData(
        color: p.panel2,
        surfaceTintColor: Colors.transparent,
        elevation: 14,
        shadowColor: Colors.black.withValues(alpha: 0.45),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: p.line.withValues(alpha: 0.6)),
        ),
        textStyle: TextStyle(fontSize: 12, color: p.ink2),
        menuPadding: const EdgeInsets.symmetric(vertical: 4),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: p.panel,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: p.line.withValues(alpha: 0.7)),
        ),
        titleTextStyle: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: p.ink,
        ),
        contentTextStyle: TextStyle(fontSize: 12, color: p.ink2),
      ),
      extensions: [p],
    );
  }
}

/// 响应式字号缩放：手机 +10%、平板 +5%、桌面 1.0；与系统文字大小相乘并
/// 钳在 [1.0, 1.3]。字号声明保持既有 8 档字阶不变，渲染期统一缩放——
/// 新增文案仍按字阶表写，不为手机单独维护一套字号。
double responsiveTextScale(Size size, TextScaler system) {
  final base = size.width < 600
      ? 1.10
      : size.width < 1024
      ? 1.05
      : 1.0;
  final systemScale = system.scale(14) / 14;
  return (systemScale * base).clamp(1.0, 1.3).toDouble();
}

/// 把响应式 textScaler 注入子树（main.dart 与测试共用同一条路径）。
Widget withResponsiveTextScale(BuildContext context, Widget child) {
  final mq = MediaQuery.of(context);
  return MediaQuery(
    data: mq.copyWith(
      textScaler: TextScaler.linear(
        responsiveTextScale(mq.size, mq.textScaler),
      ),
    ),
    child: child,
  );
}

/// 平台字体解析（Windows 中文观感优化，2026-11-19）：
///
/// Flutter 在 Windows 上的西文默认对 CJK 的系统回退链会落到宋体（点阵观感，
/// 用户实测「字体太难看」）。显式给 CJK 挂微软雅黑回退、西文主字体挂
/// Segoe UI；非 Windows 返回空 = 行为与引入前完全一致。
String? get platformPrimaryFont => Platform.isWindows ? 'Segoe UI' : null;

List<String> get platformFontFallback => Platform.isWindows
    ? const <String>['Microsoft YaHei UI', 'Microsoft YaHei', 'PingFang SC']
    : const <String>[];

TextStyle get platformDefaultTextStyle => TextStyle(
  fontFamily: platformPrimaryFont,
  fontFamilyFallback: platformFontFallback,
);

TextTheme _withPlatformFont(TextTheme theme) {
  if (!Platform.isWindows) return theme;
  TextStyle map(TextStyle style) => style.copyWith(
    fontFamily: style.fontFamily ?? 'Segoe UI',
    fontFamilyFallback: <String>[
      'Microsoft YaHei UI',
      'Microsoft YaHei',
      ...?style.fontFamilyFallback,
    ],
  );
  return TextTheme(
    displayLarge: map(theme.displayLarge ?? const TextStyle()),
    displayMedium: map(theme.displayMedium ?? const TextStyle()),
    displaySmall: map(theme.displaySmall ?? const TextStyle()),
    headlineLarge: map(theme.headlineLarge ?? const TextStyle()),
    headlineMedium: map(theme.headlineMedium ?? const TextStyle()),
    headlineSmall: map(theme.headlineSmall ?? const TextStyle()),
    titleLarge: map(theme.titleLarge ?? const TextStyle()),
    titleMedium: map(theme.titleMedium ?? const TextStyle()),
    titleSmall: map(theme.titleSmall ?? const TextStyle()),
    bodyLarge: map(theme.bodyLarge ?? const TextStyle()),
    bodyMedium: map(theme.bodyMedium ?? const TextStyle()),
    bodySmall: map(theme.bodySmall ?? const TextStyle()),
    labelLarge: map(theme.labelLarge ?? const TextStyle()),
    labelMedium: map(theme.labelMedium ?? const TextStyle()),
    labelSmall: map(theme.labelSmall ?? const TextStyle()),
  );
}

/// 排版尺度（**唯一来源**）：widget 里不要再写裸 `fontSize`/行高/字重。
///
/// 现状背景（2026-11-26 盘点）：`lib/` 里曾有 884 处硬编码 `fontSize`，横跨
/// 10/10.5/11/11.5/12/12.5/13/14/15/16/17/18/22/34 等 16 个档位，导致同一层级
/// 的标签在不同工作台里看起来「大小不一致」。收敛为下面 8 个档位，新增档位前先
/// 在这里讨论。
abstract final class NonType {
  /// 单位/角标（e.g. 「BPM」「秒」）。
  static const double micro = 10;

  /// 次要说明、工具条提示。
  static const double caption = 11;

  /// 列表正文、面板键值。
  static const double body = 12;

  /// 强调正文、面板区块标题、表单标签。
  static const double bodyStrong = 13;

  /// 卡片标题、次级页面标题。
  static const double subtitle = 15;

  /// 区块大标题。
  static const double title = 18;

  /// 页面标题、空态主标题。
  static const double display = 22;

  /// 首屏主标题（仅欢迎页/作品集主视觉使用）。
  static const double hero = 34;

  /// 正文行高（多行文本统一 1.45，避免逐处手写）。
  static const double lineBody = 1.45;

  /// 说明文字行高。
  static const double lineCaption = 1.4;

  /// 常用样式快捷出口。`size` 必须取自本类常量，禁止字面量。
  static TextStyle of(
    double size, {
    Color? color,
    FontWeight? weight,
    double? height,
    double? letterSpacing,
  }) => TextStyle(
    fontSize: size,
    color: color,
    fontWeight: weight,
    height: height,
    letterSpacing: letterSpacing,
  );
}

/// 间距尺度（**唯一来源**）：面板内边距、区块间隔、控件间隙统一用这套刻度，
/// 不再出现 3/5/6/7/9/10/11 之类的随手值。
abstract final class NonSpace {
  /// 2 — 图标与文字之间的最小缝。
  static const double xxs = 2;

  /// 4 — 紧凑控件内部间距。
  static const double xs = 4;

  /// 8 — 常规间隙。
  static const double sm = 8;

  /// 12 — 面板内边距/块间距。
  static const double md = 12;

  /// 16 — 区块之间。
  static const double lg = 16;

  /// 24 — 大区块/空态留白。
  static const double xl = 24;

  /// 32 — 页面级留白。
  static const double xxl = 32;
}

/// 圆角尺度（唯一来源）。
abstract final class NonRadius {
  /// 6 — 小控件（标签、输入内层）。
  static const double sm = 6;

  /// 10 — 面板/卡片。
  static const double md = 10;

  /// 14 — 大卡片/悬浮面。
  static const double lg = 14;
}
