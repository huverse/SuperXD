import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_glass_button.dart';

// 越界与 iOS、鸿蒙一致用弹性回弹，只平移内容。Android 默认的拉伸越界会给整个列表套图像滤镜，
// 列表里的玻璃在滤镜下取不到背景，拉到边缘或快速甩到边缘时就退成底色实板。显式指定夹紧的列表（今天页切日）不受影响。
class CampusScrollBehavior extends MaterialScrollBehavior {
  const CampusScrollBehavior();
  @override
  ScrollPhysics getScrollPhysics(BuildContext context) => const BouncingScrollPhysics();
  @override
  Widget buildOverscrollIndicator(BuildContext context, Widget child, ScrollableDetails details) => child;
}

ThemeData campusTheme({CampusPalette? palette, String fontFamily = 'Maple Mono NF CN'}) {
  final colors = palette ?? CampusPalette.values.first;
  final scheme = ColorScheme.fromSeed(
    seedColor: colors.primary,
    brightness: colors.brightness,
    primary: colors.primary,
    onPrimary: colors.onPrimary,
    secondary: colors.primary,
    onSecondary: colors.onPrimary,
    error: colors.danger,
    onError: colors.onDanger,
    surface: colors.surface,
    onSurface: colors.onSurface,
    onSurfaceVariant: colors.onSurfaceVariant,
    outline: colors.outline,
    outlineVariant: colors.outlineSubtle,
    surfaceContainerLow: colors.surface,
    surfaceContainer: colors.glassFallback,
    surfaceContainerHigh: colors.glassTint,
    surfaceContainerHighest: colors.surfaceSelected,
  );
  return ThemeData(
    useMaterial3: true,
    // [人工决策-2026-10-03 18:10:44] 按压反馈同 iOS：按下整块变暗（深色下按 iOS 惯例是浅一档的灰），松手淡出；不用 Material 3 在手指处扩散的水波（InkSparkle 呈一团模糊灰斑）。
    splashFactory: NoSplash.splashFactory,
    highlightColor: colors.onSurface.withValues(alpha: colors.isDark ? .12 : .10),
    extensions: [colors],
    // [人工决策-2026-09-25 17:43:48] Maple仍为默认，可选内置Noto Serif SC；全局字体和测量口径一致，不引入在线字体。
    fontFamily: fontFamily,
    dialogTheme: DialogThemeData(backgroundColor: colors.surface, surfaceTintColor: Colors.transparent, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)), titleTextStyle: TextStyle(fontFamily: fontFamily, fontSize: 20, fontWeight: FontWeight.w600, color: colors.onSurface), contentTextStyle: TextStyle(fontFamily: fontFamily, fontSize: 16, color: colors.onSurface)),
    datePickerTheme: DatePickerThemeData(locale: Locale('zh', 'CN'), backgroundColor: colors.surface, surfaceTintColor: Colors.transparent, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24))),
    bottomSheetTheme: BottomSheetThemeData(backgroundColor: colors.surface, shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24)))),
    popupMenuTheme: PopupMenuThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
    chipTheme: ChipThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), backgroundColor: colors.surface, selectedColor: colors.surfaceSelected, disabledColor: colors.glassFallback, checkmarkColor: colors.primary, side: BorderSide(color: colors.outline), labelStyle: TextStyle(fontFamily: fontFamily, fontSize: 14, fontWeight: FontWeight.w600, color: colors.onSurface)),
    checkboxTheme: CheckboxThemeData(checkColor: WidgetStatePropertyAll(colors.onPrimary), fillColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.selected) ? colors.primary : colors.surface), side: BorderSide(color: colors.outline, width: 1.5), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5))),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(minimumSize: Size(48, 48), textStyle: TextStyle(fontFamily: fontFamily, fontSize: 14))),
    colorScheme: scheme,
    scaffoldBackgroundColor: Colors.transparent,
    canvasColor: colors.surface,
    appBarTheme: AppBarTheme(backgroundColor: Colors.transparent, surfaceTintColor: Colors.transparent, elevation: 0, scrolledUnderElevation: 0, foregroundColor: colors.onSurface, systemOverlayStyle: campusSystemOverlay(colors)),
    cardTheme: CardThemeData(color: colors.surface.withValues(alpha: .91), surfaceTintColor: Colors.transparent, elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24), side: BorderSide(color: colors.surfaceBorder))),
    pageTransitionsTheme: PageTransitionsTheme(builders: {for (final platform in TargetPlatform.values) platform: CampusPageTransitions()}),
    snackBarTheme: SnackBarThemeData(behavior: SnackBarBehavior.floating, backgroundColor: colors.onSurface, contentTextStyle: TextStyle(color: colors.surface), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18))),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: colors.primary),
    textTheme: TextTheme(
      bodySmall: TextStyle(fontSize: 14, color: colors.onSurfaceVariant),
      labelMedium: TextStyle(fontSize: 14),
      labelSmall: TextStyle(fontSize: 14),
      titleLarge: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: colors.onSurface, height: 24 / 18),
      titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: colors.onSurface, height: 24 / 16),
      bodyLarge: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: colors.onSurface, height: 24 / 16),
      bodyMedium: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: colors.onSurfaceVariant, height: 20 / 14),
      labelLarge: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: colors.onSurface),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: Colors.transparent,
        foregroundColor: colors.primary,
        iconColor: colors.primary,
        disabledBackgroundColor: Colors.transparent,
        disabledForegroundColor: colors.onSurfaceVariant,
        disabledIconColor: colors.onSurfaceVariant,
        overlayColor: colors.primary.withValues(alpha: .08),
        elevation: 0,
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        alignment: Alignment.center,
        minimumSize: Size(40, 38),
        tapTargetSize: MaterialTapTargetSize.padded,
        visualDensity: VisualDensity.standard,
        shape: StadiumBorder(),
        textStyle: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, height: 1.25),
        backgroundBuilder: campusButtonBackground,
      ),
    ),
    // 描边框浮动标签凸出上边框且随字号增长：带标签的输入框/下拉框上方用campusFieldGap，选择标签换行行距8dp，固定高度容器不得裁切随字号变化的文字。
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colors.surface,
      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      hintStyle: TextStyle(fontSize: 16, color: colors.onSurfaceVariant),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: colors.outlineSubtle),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: colors.outlineSubtle),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: colors.primary),
      ),
    ),
  );
}

// [人工决策-2026-09-29 01:15:11] 导航栏全透明透出背景，三键导航也关闭系统半透明遮罩；内容避让导航栏，按键明暗随主题保证对比度。
// 带浮动标签的描边框上方间距：实测标签凸出约5.9dp×字号倍率，间距按同一字号放大，任何字号都留出余量。
double campusFieldGap(BuildContext context) => MediaQuery.textScalerOf(context).scale(16);

SystemUiOverlayStyle campusSystemOverlay(CampusPalette palette) => (palette.isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark).copyWith(
  statusBarColor: Colors.transparent,
  systemNavigationBarColor: Colors.transparent,
  systemNavigationBarIconBrightness: palette.isDark ? Brightness.light : Brightness.dark,
  systemNavigationBarContrastEnforced: false,
);

class CampusBackground extends StatelessWidget {
  const CampusBackground({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // 背景统一由MaterialApp上方的CampusAtmosphere绘制，避免各路由重复循环与遮挡。
    return child;
  }
}
