import 'dart:io' show Platform;
import 'dart:math' as math;

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

  /// 深色主题（2026-11-26 活力化）：抬亮层级 + 提饱和强调色。
  ///
  /// 用户反馈"现在太暗"：整条明度阶整体上抬约 8–10 个 L 值，让层级靠明度而不是
  /// 靠黑影；accent 从偏灰的 #7C8CFF 换成更饱和的 #5B8CFF，accent2 同步提亮。
  static const dark = NonPalette(
    bg: Color(0xFF0E1015),
    bgElevated: Color(0xFF141821),
    panel: Color(0xFF171B24),
    panel2: Color(0xFF1D2230),
    panel3: Color(0xFF252B3A),
    line: Color(0x1FFFFFFF),
    lineStrong: Color(0x33FFFFFF),
    ink: Color(0xFFF0F2F8),
    ink2: Color(0xFFB3BAC9),
    ink3: Color(0xFF98A1B3),
    // 对比度修正：旧 #7C8698 在 panel2/panel3 上仅 4.32/3.85。
    ink4: Color(0xFF8C96A9),
    accent: Color(0xFF5B8CFF),
    accent2: Color(0xFFC07BFF),
    accentSoft: Color(0x2E5B8CFF),
    success: Color(0xFF34D399),
    warn: Color(0xFFFFB42D),
    danger: Color(0xFFFF5F7E),
    canvas: Color(0xFF0B0E13),
    canvasDot: Color(0x14FFFFFF),
  );

  /// 浅色 = **Aqua**（早期 Mac OS X 设计语言的现代化移植）。
  ///
  /// 用户裁决（2026-11-26）：不新增第三套主题，Aqua 就是浅色主题。
  /// 材质语言：细条纹（pinstripe）窗口底 + 糖果凝胶（candy-gel）控件 +
  /// 深色软阴影；文字在凝胶上用白色 + subtle down-shadow 保证 4.5:1 对比。
  /// 具体凝胶/条纹/口香糖按钮的实现见 `widgets/aqua.dart`。
  static const light = NonPalette(
    // 条纹窗口底：Aqua 的底色是浅灰，条纹由 AquaPinstripes 叠加。
    bg: Color(0xFFECECEF),
    bgElevated: Color(0xFFF6F6F8),
    panel: Color(0xFFFFFFFF),
    panel2: Color(0xFFF3F4F7),
    panel3: Color(0xFFE6E8EE),
    line: Color(0x1A0F172A),
    lineStrong: Color(0x330F172A),
    ink: Color(0xFF1B1D24),
    ink2: Color(0xFF475063),
    // 对比度修正（2026-11-27，WCAG 4.5:1 审计）：
    // 旧 ink3 #68718A 在 bg 上仅 4.13；旧 ink4 #8B93A8 在白面上仅 3.07。
    ink3: Color(0xFF5C6579),
    ink4: Color(0xFF5B6478),
    // Aqua 的经典水系蓝：凝胶渐变由它派生（#5F9FF5 → #1862D8）。
    accent: Color(0xFF1862D8),
    // 对比度修正：作为文字时在浅灰底上需 >=4.5（旧 #6E5AE0 仅 4.24）。
    accent2: Color(0xFF644FD3),
    accentSoft: Color(0x1F1862D8),
    success: Color(0xFF177A4E),
    warn: Color(0xFF945A00),
    danger: Color(0xFFC42B3E),
    canvas: Color(0xFFF4F5F8),
    canvasDot: Color(0x140F172A),
  );

  /// Aqua 凝胶高光/渐变端点（浅色主题专用；深色主题不使用）。
  /// 顶部高光偏白蓝，底部收敛到经典 Aqua 蓝。
  static const Color aquaGelTop = Color(0xFF9CC6FF);
  static const Color aquaGelBottom = Color(0xFF1862D8);
  static const Color aquaGelHighlight = Color(0xCCFFFFFF);

  /// 窗口控制「口香糖」三色（红/黄/绿），带玻璃球质感。
  static const Color aquaGumdropClose = Color(0xFFFF5F57);
  static const Color aquaGumdropMinimize = Color(0xFFFFBD2E);
  static const Color aquaGumdropZoom = Color(0xFF28C840);

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

extension NonMotionX on BuildContext {
  /// 动画时长：用户开启「减少动效」时归零（WCAG 2.3.3 / prefers-reduced-motion）。
  ///
  /// 用法：`AnimatedContainer(duration: context.nonMotion(NonMotion.base), …)`。
  /// 只改时长、不改终态——单独归零后控件仍会立即到达目标状态。
  Duration nonMotion(Duration duration) =>
      MediaQuery.disableAnimationsOf(this) ? Duration.zero : duration;
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
      // 键盘焦点可见（WCAG 2.2 AA）：Material 默认 focus overlay 太弱，
      // 统一抬到 accent 22% 叠层；需要更强指示的控件（凝胶按钮/工具圆钮）
      // 另有 2px 实心焦点环。
      focusColor: p.accent.withValues(alpha: 0.22),
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
        // 用户裁决 2026-11-26：所有下拉列表收缩，不要过度宽泛。
        // 宽度上限在各菜单构造处统一夹（见 common.dart 的 nonMenuWidthCap）。
        color: dark ? p.panel2 : Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 14,
        shadowColor: Colors.black.withValues(alpha: dark ? 0.45 : 0.18),
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

/// 全局字号缩放因子的夹取范围（**唯一来源**）。
///
/// 系统 Dynamic Type / 浏览器字号可以远超 1.3；窄面板（左栏树行、检查器行、
/// 命令面板行）的行高与省略号只按 [max] 设计，越过上限就必须在缩放层夹住，
/// 而不是让每个行组件自己再算一遍——否则同一档字号在不同组件里被夹成不同值。
abstract final class NonTextScale {
  /// 下限：不跟随「调小字号」把正文压到 1 倍以下（与既有 1.0–1.3 约定一致）。
  static const double min = 1.0;

  /// 上限：1.3 倍是窄面板行不破版的验收上限。
  static const double max = 1.3;
}

/// 把任意字号缩放因子夹进 [NonTextScale] 区间——全局缩放层的唯一实现。
///
/// NaN 视为「没有可用缩放信息」，回落到下限（[NonTextScale.min]），避免
/// 非法浮点沿着 MediaQuery 往下传。
double clampTextScale(double scale) {
  if (scale.isNaN) return NonTextScale.min;
  return scale.clamp(NonTextScale.min, NonTextScale.max).toDouble();
}

/// 响应式字号缩放：手机 +10%、平板 +5%、桌面 1.0；与系统文字大小相乘后经
/// [clampTextScale] 夹在 [NonTextScale.min, NonTextScale.max]。字号声明保持
/// 既有 8 档字阶不变，渲染期统一缩放——新增文案仍按字阶表写，不为手机单独
/// 维护一套字号。
double responsiveTextScale(Size size, TextScaler system) {
  final base = size.width < 600
      ? 1.10
      : size.width < 1024
      ? 1.05
      : 1.0;
  final systemScale = system.scale(14) / 14;
  return clampTextScale(systemScale * base);
}

/// 固定高度行/输入行的 Dynamic Type 行高：以 [base]（1.0 倍字号下的既有行高）
/// 为基准，按当前**有效**字号倍率线性放大。
///
/// 用于树行、检查器数值行、取色行这类「行内只有一个单行文本 + 紧凑控件」的
/// 窄行：行高固定会把 1.3 倍字号的文本压进盒子里（行内换行/裁切），把高度
/// 直接放开又会改变 1.0 倍下既有密度。这里让行高跟着字号走——1.0 倍时与
/// [base] 完全一致（视觉零变化），放大字号时才变高。
double scaledRowHeight(BuildContext context, double base) {
  final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
  return base * math.max(1.0, scale);
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
