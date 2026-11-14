import 'package:flutter/material.dart';

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
    ink3: Color(0xFF737B8D),
    ink4: Color(0xFF4D5464),
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
    ink3: Color(0xFF7A8292),
    ink4: Color(0xFFA7ADBA),
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
  NonPalette get palette => Theme.of(this).extension<NonPalette>() ?? NonPalette.dark;
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
    final base = dark ? ThemeData.dark(useMaterial3: true) : ThemeData.light(useMaterial3: true);
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
      textTheme: base.textTheme.apply(bodyColor: p.ink, displayColor: p.ink).copyWith(
        bodyMedium: TextStyle(fontSize: 13, color: p.ink2, height: 1.45),
        bodySmall: TextStyle(fontSize: 11, color: p.ink3, height: 1.4),
        titleMedium: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: p.ink),
        titleLarge: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: p.ink, letterSpacing: -0.3),
        headlineMedium: TextStyle(fontSize: 34, fontWeight: FontWeight.w600, color: p.ink, letterSpacing: -1),
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
        decoration: BoxDecoration(color: p.panel3, borderRadius: BorderRadius.circular(6)),
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: p.line.withValues(alpha: 0.6))),
        textStyle: TextStyle(fontSize: 12, color: p.ink2),
        menuPadding: const EdgeInsets.symmetric(vertical: 4),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: p.panel,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: p.line.withValues(alpha: 0.7))),
        titleTextStyle: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: p.ink),
        contentTextStyle: TextStyle(fontSize: 12, color: p.ink2),
      ),
      extensions: [p],
    );
  }
}
